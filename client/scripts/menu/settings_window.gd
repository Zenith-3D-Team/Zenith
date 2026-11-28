extends PanelContainer
## Factorio-style settings window: the tabs of Factorio's Settings menu (Graphics, Sound,
## Controls, Interface, Other, Mod settings) and ours (Camera, Factorio), rows of "name: control"
## grouped under headings in a light pane, Back at the bottom. Every row is wired to what it
## changes: settings.gd saves and tells its listeners, so most apply at once; the few that need a
## restart or a new server say so. Each control is named "<section>-<key>" for tests (map switches "map-show_tags", bindings "controls-<action>-<slot>").

signal closed
## Confirm in a single page (page_mode): the settings window and the list it came from close.
signal confirmed

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const MenuKit := preload("res://scripts/menu/menu_kit.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const DlssHost := preload("res://scripts/menu/dlss_host.gd")
const Upscalers := preload("res://scripts/menu/upscalers.gd")
const RenderStats := preload("res://scripts/debug/render_stats.gd")
const Paths := preload("res://scripts/menu/paths.gd")
const FxSettings := preload("res://scripts/fx/fx_settings.gd")
const Sfx := preload("res://scripts/fx/sfx.gd")
const GameSwap := preload("res://scripts/menu/game_swap.gd")
const UiSettings := preload("res://scripts/ui/ui_settings.gd")
const ColorFilter := preload("res://scripts/menu/color_filter.gd")
const Looks := preload("res://scripts/world/looks.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const ControlsInfo := preload("res://scripts/menu/controls_info.gd")
const Controls := preload("res://scripts/player/controls.gd")
const FactorioKeys := preload("res://scripts/player/factorio_keys.gd")
const NightVisionOverlay := preload("res://scripts/ui/night_vision_overlay.gd")
const PerfWarning := preload("res://scripts/ui/factorio/perf_warning.gd")
const RenderDistance := preload("res://scripts/world/render_distance.gd")

const TABS := ["Graphics", "Sound", "Controls", "Interface", "Other", "Mod settings", "Camera", "Factorio"]
## Factorio's sound sliders ([gui-sound-settings]) the client has a bus for, in its order (Master,
## Music, Game effects, GUI effects, Walking, Environment, Alerts, Ambient, Wind), then the client's own
## three. Factorio's Simulations has no bus here (there are no tips simulations).
const SOUND := [
	["Master", "master"], ["Music", "music"], ["Game effects", "effects"], ["GUI effects", "ui"], ["Walking", "walking"],
	["Environment", "environment", "Sounds of machines and vehicles."], ["Ambient", "ambient", "Local ambient sounds of entities and terrain."],
	["Wind", "wind", "Global persistent and semi-persistent ambient sounds."], ["Alerts", "alerts"],
	["Weapons", "weapons"], ["Explosions", "explosions"], ["Enemies", "enemies"],
]
## The bridge mod's runtime-global settings (mod/factorio-3d-bridge/settings.lua):
## [name, label, type, default, min, max].
const MOD_SETTINGS := [
	["f3d-surface", "Surface to stream", "string", "nauvis"],
	["f3d-chunks-per-tick", "Chunk snapshots per tick", "int", 1, 1, 16],
	["f3d-bytes-per-tick", "Bytes sent per tick", "int", 131072, 4096, 1048576],
	["f3d-max-focus-radius", "Max live-update radius", "int", 192, 16, 256],
	["f3d-mover-interval", "Moving entity update interval (ticks)", "int", 2, 1, 30],
	["f3d-mover-rescan", "Longest wait between searches for movers (ticks)", "int", 32, 8, 300],
	["f3d-detail-radius", "Detail radius (belt items, hands)", "int", 24, 0, 64],
	["f3d-detail-interval", "Detail update interval (ticks)", "int", 6, 1, 60],
	["f3d-spread-jobs", "Spread the periodic jobs over several ticks", "bool", true],
	["f3d-binary-messages", "Binary messages", "bool", true],
	["f3d-starter-kit", "Starter kit for the bridge's character", "bool", true],
	["f3d-character-corpses", "Character corpses", "bool", true],
	["f3d-player", "Player to play as", "string", ""],
	["f3d-act-as-player", "Act as the player for other mods", "bool", true],
]

const DEFAULT_PANE_SIZE := Vector2(780, 500)
const GRAPHICS_PANE_SIZE := Vector2(1080, 880)

static var old_graphics_layout_override := -1

var in_game := false
var start_tab := ""
## Factorio's way: one page at a time ("Graphics settings", ...), opened from the Settings list
## (front_end.gd), without the tab row, with Back (to the list) and Confirm (close).
var page_mode := false
## The launched server's RCON (rcon.gd) while in a game started from the menu, for Mod settings.
var rcon = null
## Add-on host (addon_host.gd), used to surface the selected look's shader settings in Graphics.
var addons = null

var _tab_buttons: Array[Button] = []
var _pane: VBoxContainer
var _pane_frame: PanelContainer
var _tab := 0
var _capturing := ""  # "<action>/<slot>" waiting for a key
var _preset: OptionButton  # Graphics > Preset, following the settings it covers
var _scroll: ScrollContainer
var _graphics_expanded: Dictionary = {}
var _graphics_cards: Dictionary = {}
var _row_inline_notes := true


static func use_old_graphics_layout() -> bool:
	if old_graphics_layout_override >= 0:
		return old_graphics_layout_override == 1
	return Settings.arg_value("--graphics-layout=") == "old"


func _ready() -> void:
	theme_type_variation = "FFrame"
	Settings.listen(_on_setting)
	add_to_group(DlssHost.SCALE_WATCHERS)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Kit.px(8))
	add_child(box)
	var bar := Kit.title_bar("Settings", not page_mode)
	box.add_child(bar)
	if not page_mode:
		var close: Button = bar.get_child(bar.get_child_count() - 1)
		close.pressed.connect(_close)

	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 0)
	box.add_child(tabs)
	for i in TABS.size():
		var b := Button.new()
		b.text = TABS[i]
		b.name = "Tab" + TABS[i].replace(" ", "")
		b.theme_type_variation = "FTab"
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Kit.pxv(92, 32)
		b.add_theme_font_override("font", Kit.font("bold"))
		var index := i
		b.pressed.connect(func() -> void:
			Sfx.play_ui("gui-tab")
			_open_tab(index))
		tabs.add_child(b)
		_tab_buttons.append(b)
	tabs.visible = not page_mode

	_pane_frame = Kit.panel("FShallowFrame")
	_pane_frame.custom_minimum_size = Kit.pxv(DEFAULT_PANE_SIZE.x, DEFAULT_PANE_SIZE.y)
	box.add_child(_pane_frame)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_pane_frame.add_child(_scroll)
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "top", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, Kit.px(12))
	_scroll.add_child(pad)
	_pane = VBoxContainer.new()
	_pane.name = "Pane"
	_pane.add_theme_constant_override("separation", Kit.px(10))
	pad.add_child(_pane)

	var row: Array = MenuKit.dialog_buttons("Back", "Confirm" if page_mode else "")
	box.add_child(row[0])
	(row[1] as Button).pressed.connect(func() -> void:
		Sfx.play_ui("gui-back")
		_close())
	if page_mode:
		(row[2] as Button).name = "Confirm"
		(row[2] as Button).pressed.connect(func() -> void:
			Sfx.play_ui("gui-green-confirm")
			_capturing = ""
			confirmed.emit())
	var wanted := start_tab.replace("_", " ").to_lower()
	var start := 0
	for i in TABS.size():
		if TABS[i].to_lower() == wanted or TABS[i].to_lower().replace(" ", "") == wanted.replace(" ", ""):
			start = i
	_open_tab(start)
	if page_mode:
		(bar.get_child(0) as Label).text = page_title(TABS[start])
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_viewport_resized):
		vp.size_changed.connect(_on_viewport_resized)
	# --settings-scroll-to=<control name> (screenshots): that setting scrolled into view.
	var to := Settings.arg_value("--settings-scroll-to=")
	if to != "":
		await get_tree().process_frame
		await get_tree().process_frame
		if not is_inside_tree() or not is_instance_valid(_pane):
			return
		var c := _pane.find_child(to, true, false) as Control
		if c != null:
			var p: Node = c.get_parent()
			while p != null and p != _pane:
				if p is Control and p.has_meta("graphics_more_category") and not (p as Control).visible:
					_set_graphics_category_expanded(str(p.get_meta("graphics_more_category")), true)
					await get_tree().process_frame
					break
				p = p.get_parent()
			if is_inside_tree() and is_instance_valid(c):
				_scroll.ensure_control_visible(c)


## Factorio's page titles: "Graphics settings", "Sound settings", "Mod settings".
static func page_title(tab: String) -> String:
	return tab if tab == "Mod settings" else tab + " settings"


func _input(event: InputEvent) -> void:
	if _capturing == "":
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	get_viewport().set_input_as_handled()
	if key.physical_keycode in [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]:
		return  # a modifier on its own: wait for the key it goes with
	var target := _capturing
	_capturing = ""
	if key.physical_keycode != KEY_ESCAPE:
		capture(target, Settings.event_code(key))
	_open_tab(_tab)


## Binds "<action>/<slot>" to a key code with modifiers (what a key press while capturing does).
func capture(target: String, code: int) -> void:
	Settings.bind_slot(target.get_slice("/", 0), int(target.get_slice("/", 1)), code)
	Sfx.play_ui("gui-click")


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.physical_keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		if is_instance_valid(_dlss_prompt):
			_dlss_prompt_answer("", false)  # Esc on DLSS's prompt is Cancel
			return
		_close()


func _close() -> void:
	_capturing = ""
	closed.emit()


func current_tab() -> String:
	return TABS[_tab]


func open_tab(tab_name: String) -> void:
	var i := TABS.find(tab_name)
	if i >= 0:
		_open_tab(i)


func _open_tab(index: int) -> void:
	_tab = index
	_row_inline_notes = true
	_graphics_cards.clear()
	for i in _tab_buttons.size():
		_tab_buttons[i].button_pressed = i == index
	for c in _pane.get_children():
		_pane.remove_child(c)
		c.queue_free()
	_update_pane_size()
	match TABS[index]:
		"Graphics":
			_graphics()
		"Sound":
			_sound()
		"Controls":
			_controls()
		"Interface":
			_interface()
		"Other":
			_other()
		"Mod settings":
			_mod_settings()
		"Camera":
			_camera()
		"Factorio":
			_factorio()
	reset_size()


func _on_viewport_resized() -> void:
	_update_pane_size()


func _update_pane_size() -> void:
	if not is_instance_valid(_pane_frame):
		return
	var is_graphics: bool = _tab >= 0 and _tab < TABS.size() and str(TABS[_tab]) == "Graphics" and not use_old_graphics_layout()
	var want := GRAPHICS_PANE_SIZE if is_graphics else DEFAULT_PANE_SIZE
	var target := Kit.pxv(want.x, want.y)
	var vp := get_viewport()
	if vp != null:
		var avail := vp.get_visible_rect().size
		if avail.x >= Kit.px(400) and avail.y >= Kit.px(300):
			var chrome_h := Kit.px(116 if page_mode else 156)
			var max_w := maxf(Kit.px(640), avail.x - Kit.px(36))
			var max_h := maxf(Kit.px(360), avail.y - chrome_h - Kit.px(24))
			target.x = minf(target.x, max_w)
			target.y = minf(target.y, max_h)
	_pane_frame.custom_minimum_size = target
	reset_size()


func _exit_tree() -> void:
	Settings.unlisten(_on_setting)
	var vp := get_viewport()
	if vp != null and vp.size_changed.is_connected(_on_viewport_resized):
		vp.size_changed.disconnect(_on_viewport_resized)


## The preset shows what the settings match as they change (Custom once one is set by hand).
func _on_setting(section: String, key: String) -> void:
	if section == "graphics" and key == "pack_tiles":
		ModelPacks.set_tiles_on(ModelPacks.arg_on("--pack-tiles") and bool(Settings.get_value("graphics", "pack_tiles")))
	if section == "graphics" and key == "pack_decoratives":
		ModelPacks.set_decor_on(ModelPacks.arg_on("--pack-decoratives") and bool(Settings.get_value("graphics", "pack_decoratives")))
	if section == "graphics" and key == "decor_models":
		ModelPacks.set_decor_models_on(ModelPacks.arg_on("--decor-models") and bool(Settings.get_value("graphics", "decor_models")))
	if section == "camera":
		_show_choice(section, key)  # F7 in the game while the window is open (owner's I19)
		return
	if section != "graphics" or not is_instance_valid(_preset):
		return
	# The upscaler or the scale it works at changed: Anti-aliasing greys out for FSR 2.2 (or comes back).
	if key in ["upscaler", "render_scale", "resolution", "window_mode"]:
		_refresh_look_overrides()
		_show_used_scale.call_deferred()
	var now := Settings.preset_now()
	for i in _preset.item_count:
		if str(_preset.get_item_metadata(i)) == now:
			_preset.select(i)


# --- tabs ------------------------------------------------------------------------------------

## What the Recommended button last chose (its text), kept across the tab being rebuilt.
var _recommended := ""


## Recommended (Graphics): the preset for this PC's hardware, and in a game what it measured over
## RECOMMEND_SECONDS (the slowest tenth of frames, the game's ticks a second); see
## Settings.recommended_preset.
const RECOMMEND_SECONDS := 6.0


func _recommend(button: Button) -> void:
	Sfx.play_ui("gui-click")
	var fps := 0.0
	var ups := 0.0
	var frame_ms := 0.0
	var gpu_ms := 0.0
	if Bridge.world_ready:
		button.disabled = true
		button.text = "Measuring..."
		var frames: Array[float] = []
		var started := Time.get_ticks_usec()
		var tick := Bridge.server_tick
		var last := started
		# The GPU's share of the frame too: merged materials help only where the CPU holds it up.
		var vp := get_viewport().get_viewport_rid()
		RenderingServer.viewport_set_measure_render_time(vp, true)
		var gpu: Array[float] = []
		while Time.get_ticks_usec() - started < RECOMMEND_SECONDS * 1e6:
			await get_tree().process_frame
			var now := Time.get_ticks_usec()
			frames.append((now - last) / 1000.0)
			# On the render thread when it runs on its own (RenderStats): a read from here would wait for it
			# every frame and spoil the measurement. Frames before the first answer are left out.
			var rs := RenderStats.read(vp)
			if rs.has("gpu_ms"):
				gpu.append(float(rs["gpu_ms"]))
			last = now
		RenderingServer.viewport_set_measure_render_time(vp, false)
		ups = (Bridge.server_tick - tick) / ((last - started) / 1e6)
		frames.sort()
		gpu.sort()
		frame_ms = frames[frames.size() / 2] if not frames.is_empty() else 0.0
		gpu_ms = gpu[gpu.size() / 2] if not gpu.is_empty() else 0.0
		fps = 1000.0 / maxf(frames[int(frames.size() * 0.9)] if not frames.is_empty() else 16.7, 0.1)
		if not is_instance_valid(button):
			return
		button.disabled = false
	var preset := Settings.recommended_preset(OS.get_processor_count(), RenderingServer.get_video_adapter_name(), fps, ups, Settings.preset_now())
	Settings.set_value("graphics", "hold_ups", true, false)
	Settings.set_value("graphics", "belt_smooth", true, false)
	# Not part of any preset: Low to Ultra leave it as the player set it.
	Settings.set_value("graphics", "merged_materials",
		Settings.recommended_merged_materials(RenderingServer.get_video_adapter_name(), frame_ms, gpu_ms), false)
	Settings.apply_preset(preset)
	_recommended = "Recommended: %s" % preset.capitalize()
	if fps > 0.0:
		_recommended += " (measured %d fps, %d UPS)" % [roundi(fps), roundi(ups)]
	button.text = _recommended
	_open_tab.call_deferred(_tab)


const PRESET_ITEMS := [["Low", "low"], ["Medium", "medium"], ["High", "high"], ["Ultra", "ultra"], ["Custom", "custom"]]


func _graphics() -> void:
	if use_old_graphics_layout():
		_graphics_legacy()
		return
	var reopen := func(_i: int) -> void: _open_tab.call_deferred(_tab)

	# Top bar: Preset, For this PC, Look across 3 equal slots above the category grid.
	var top_frame := Kit.panel("FDeepFrame")
	top_frame.name = "GraphicsTopBar"
	top_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pane.add_child(top_frame)
	var top_pad := MarginContainer.new()
	for side in ["left", "right"]:
		top_pad.add_theme_constant_override("margin_" + side, Kit.px(10))
	for side in ["top", "bottom"]:
		top_pad.add_theme_constant_override("margin_" + side, Kit.px(8))
	top_frame.add_child(top_pad)
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", Kit.px(14))
	top_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_pad.add_child(top_row)
	var top_slots: Array[VBoxContainer] = []
	for i in 3:
		var slot := VBoxContainer.new()
		slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slot.size_flags_stretch_ratio = 1.0
		top_row.add_child(slot)
		top_slots.append(slot)

	_preset = MenuKit.dropdown(PRESET_ITEMS, Settings.preset_now())
	_preset.name = "graphics-preset"
	_preset.fit_to_longest_item = false
	_preset.clip_text = true
	_preset.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_preset.custom_minimum_size = Kit.pxv(140, 26)
	_preset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var on_preset := func(i: int) -> void:
		Sfx.play_ui("gui-click")
		var preset := str(_preset.get_item_metadata(i))
		if preset == "custom":
			_on_setting("graphics", "")
		else:
			Settings.apply_preset(preset)
			_open_tab.call_deferred(_tab)
	_preset.item_selected.connect(on_preset)
	_card_row(top_slots[0], "Preset", _preset,
		"Sets shadows, ambient occlusion, level of detail, distances, grass, clouds, and god rays together.")

	var recommend := MenuKit.button(_recommended if _recommended != "" else "Recommended")
	recommend.name = "graphics-recommended"
	recommend.clip_text = true
	recommend.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	recommend.custom_minimum_size = Kit.pxv(140, 26)
	recommend.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	recommend.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	recommend.pressed.connect(_recommend.bind(recommend))
	_card_row(top_slots[1], "For this PC", recommend,
		"Tests hardware (and frame times in-game) to pick a preset aiming for steady 60 UPS/FPS.")

	_card_dropdown(top_slots[2], "Look", "graphics", "look", Looks.choices(),
		"Sets world lighting and color grading. Add-ons can add looks with custom cards below.").item_selected.connect(reopen)

	# 3 equal columns of category cards.
	var cols_box := HBoxContainer.new()
	cols_box.name = "GraphicsColumns"
	cols_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols_box.add_theme_constant_override("separation", Kit.px(10))
	_pane.add_child(cols_box)
	var cols: Array[VBoxContainer] = []
	for i in 3:
		var col := VBoxContainer.new()
		col.name = "GraphicsCol%d" % i
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.size_flags_stretch_ratio = 1.0
		col.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		col.add_theme_constant_override("separation", Kit.px(10))
		cols_box.add_child(col)
		cols.append(col)

	var pct := func(v: float) -> String: return "%d%%" % roundi(v * 100.0)
	var lod_items := [["Low", "low"], ["Medium", "medium"], ["High", "high"], ["Ultra", "ultra"]]
	var manual_split := RenderDistance.is_manual_split()
	var unified_text := func(v: float, lod_q: String) -> String:
		var r := int(v)
		var rd := RenderDistance.resolve(r, lod_q, false)
		if bool(rd["dh_enabled"]):
			return "%d chunks (%d full + LOD)" % [int(rd["total_radius"]), int(rd["real_radius"])]
		var n := r * 2 + 1
		return "%d chunks (%d × %d)" % [r, n, n]
	var lod_note := "Controls how quickly distant 3D models, shadows, and merged chunks simplify."

	# Column 0: Display + Performance
	var c_display := _category_card(cols[0], "display", "Display")
	var dp: VBoxContainer = c_display["primary"]
	var da: VBoxContainer = c_display["advanced"]
	_card_dropdown(dp, "Full screen", "graphics", "window_mode", [["Windowed", "windowed"], ["Borderless full screen", "borderless"], ["Exclusive full screen", "fullscreen"]],
		"Switches between windowed, borderless fullscreen, and exclusive fullscreen.", true).item_selected.connect(reopen)
	var full_screen := str(Settings.get_value("graphics", "window_mode")) != "windowed"
	var resolution := _card_dropdown(dp, "Resolution", "graphics", "resolution", Settings.resolution_choices(DisplayServer.screen_get_size(Settings.chosen_screen()), full_screen),
		"Render size scaled to fill the monitor. Game render scaling multiplies on top." if full_screen else
		"Window size in windowed mode.", true)
	var on_resolution := func(i: int) -> void:
		if str(resolution.get_item_metadata(i)) == "":
			Settings.restore_default_window_size()
	resolution.item_selected.connect(on_resolution)
	_card_check(dp, "Wait for VSync", "graphics", "vsync",
		"Syncs frames with your monitor refresh rate to prevent tearing.", true)
	_card_dropdown(dp, "FPS limit", "graphics", "fps_cap", [["Unlimited", 0], ["30", 30], ["60", 60], ["120", 120], ["144", 144], ["240", 240]],
		"Caps the client frame rate.", true)
	_card_slider(dp, "Game render scaling", "graphics", "render_scale", 0.33, 2.0, 0.01, pct, true, false,
		"Scales the 3D world resolution while keeping menus and UI sharp.", Callable(), 100.0)
	_ask_before_dlss(_card_dropdown(dp, "Upscaling", "graphics", "upscaler", UPSCALER_ITEMS, UPSCALER_NOTE, true))
	_upscaling_quality(dp, true)
	_dlss_consent_row(dp)
	var screens: Array = [["Primary screen (%d)" % (DisplayServer.get_primary_screen() + 1), -1]]
	for i in DisplayServer.get_screen_count():
		var s := DisplayServer.screen_get_size(i)
		screens.append(["Screen %d (%d × %d)" % [i + 1, s.x, s.y], i])
	_card_dropdown(da, "Preferred screen", "graphics", "screen", screens,
		"Chooses which monitor the game window opens and fullscreens on.", true).item_selected.connect(reopen)
	_card_slider(da, "Upscaler sharpness", "graphics", "upscaler_sharpness", 0.0, 1.0, 0.05, pct, true, false,
		UPSCALER_SHARPNESS_NOTE, Callable(), 100.0)
	_grey_upscaler_rows()
	_card_check(da, "Minimize on focus loss", "graphics", "minimize_on_focus_loss",
		"Minimizes fullscreen windows when switching to another app.")
	_finish_category_card(c_display)

	var c_perf := _category_card(cols[0], "performance", "Performance")
	var pp: VBoxContainer = c_perf["primary"]
	var pa: VBoxContainer = c_perf["advanced"]
	var lod_dd := _card_dropdown(pp, "Level of detail", "graphics", "lod_quality", lod_items, lod_note)
	var on_lod_selected := func(idx: int) -> void:
		# The unified Render distance's value reads "N chunks (R full + LOD)": it follows the Level of detail.
		if manual_split or not is_instance_valid(_pane):
			return
		var rs := _pane.find_child("graphics-view_radius", true, false) as HSlider
		var rl := _pane.find_child("graphics-view_radius-value", true, false) as Button
		if rs != null and rl != null:
			rl.text = unified_text.call(rs.value, str(lod_dd.get_item_metadata(idx)))
	lod_dd.item_selected.connect(on_lod_selected)
	_card_check(pp, "Hold the game at 60 UPS", "graphics", "hold_ups",
		"Temporarily trims bridge updates and distances whenever UPS drops below 60.")
	var item_format := func(v: float) -> String:
		if int(v) <= 0:
			return "Icons only"
		return "All" if int(v) >= Settings.ITEM_MODELS_ALL else "%d" % int(v)
	_card_slider(pp, "Items in 3D", "graphics", "item_models_max", 0, Settings.ITEM_MODELS_ALL, 500, item_format, false, false,
		"Max belt items drawn as 3D models (nearest first); the rest show 2D icons.", Callable(), 1.0, true)
	_card_dropdown(pp, "Moving belt items", "graphics", "belt_updates",
		[["Automatic", -1], ["1,000 items", 1000], ["2,000 items", 2000], ["4,000 items", 4000], ["6,000 items", 6000], ["12,000 items", 12000],
		["24,000 items", 24000], ["Unlimited", 0]],
		"Max moving belt items updated per tick; farther items stay static. Automatic scales with frame time.")
	var lod_dist_fmt := func(v: float) -> String:
		if int(v) <= 0:
			return "Auto"
		return "%d tiles" % int(v)
	_card_slider(pa, "LOD falloff distance", "graphics", "lod_distance", 0, 160, 4, lod_dist_fmt, false, false,
		"Custom distance where LODs start falling off; models, belts, items, merged chunks, and lights auto-adjust from it. 0 follows Level of detail.")
	_card_check(pa, "Give the server the CPU first", "graphics", "server_first",
		"Lowers client priority when hosting locally so Factorio ticks stay responsive.")
	_card_check(pa, "Merge far buildings", "graphics", "merge_far",
		"Combines distant chunks' static buildings into simplified meshes to cut draw calls.")
	_card_check(pa, "Merged materials (may help when CPU-bound)", "graphics", "merged_materials",
		"Combines model surfaces to reduce CPU draw calls at slight GPU cost. Needs restart.")
	_card_check(pa, "Animate modded buildings", "graphics", "animate_mod_buildings",
		"Animates Factorio sprite stand-ins for modded buildings without 3D models.")
	_card_check(pa, "Chunk disk cache", "graphics", "chunk_disk_cache",
		"Caches visited 16×16 chunk regions on disk so revisiting areas loads faster.")
	_card_check(pa, "Render on a separate thread", "graphics", "render_thread",
		"Godot's renderer on its own thread: smoother on busy bases. Off: the main thread draws, as before. Needs restart.")
	if OS.get_name() == "Windows":
		_card_dropdown(pa, "Renderer", "graphics", "renderer", RENDERER_ITEMS, _renderer_note())
	_finish_category_card(c_perf)

	# Column 1: View & Distances + World & Atmosphere
	var c_dist := _category_card(cols[1], "distances", "View & Distances")
	var vp_box: VBoxContainer = c_dist["primary"]
	var va_box: VBoxContainer = c_dist["advanced"]
	var view_format := func(v: float) -> String:
		var n := int(v) * 2 + 1
		return "%d chunks (%d × %d)" % [int(v), n, n]
	var dh_format := func(v: float) -> String:
		if int(v) <= 0:
			return "Off"
		return "%d chunks (%d tiles)" % [int(v), int(v) * 32]
	var view_tiles := float(maxi(32, int(Settings.get_value("graphics", "view_radius")) * 32))
	var dist_refs := {"entity": {}, "belt": {}}
	var on_view_committed := func(v: float) -> void:
		_sync_distance_caps(v, dist_refs["entity"] as Dictionary, dist_refs["belt"] as Dictionary)
	if manual_split:
		_card_slider(vp_box, "View distance (full)", "graphics", "view_radius", 2, Settings.VIEW_RADIUS_SLIDER_MAX, 1, view_format, false, false,
			"Full 3D chunk radius around the camera. Click value to type up to %d (red past %d)." % [Settings.VIEW_RADIUS_MAX, Settings.VIEW_RADIUS_SLIDER_MAX],
			view_distance_tint, 1.0, false, Settings.VIEW_RADIUS_MAX, on_view_committed)
		_card_slider(vp_box, "Distant horizon", "graphics", "distant_horizon", 0, Settings.DISTANT_HORIZON_SLIDER_MAX, 16, dh_format, false, false,
			"Draws cached 2.5D terrain and factory silhouettes past View distance. Click value to type up to %d (red past %d)." % [Settings.RENDER_DISTANCE_MAX, Settings.DISTANT_HORIZON_SLIDER_MAX],
			distant_horizon_tint, 1.0, false, Settings.RENDER_DISTANCE_MAX)
	else:
		var unified_fmt := func(v: float) -> String:
			return unified_text.call(v, str(Settings.get_value("graphics", "lod_quality")))
		_card_slider(vp_box, "Render distance", "graphics", "view_radius", 2, Settings.RENDER_DISTANCE_MAX, 1, unified_fmt, false, false,
			"One distance across full 3D chunks and the distant horizon; Level of detail balances how many stay full 3D. Click value to type.",
			distant_horizon_tint, 1.0, false, Settings.RENDER_DISTANCE_MAX, on_view_committed)
	dist_refs["entity"] = _card_slider(vp_box, "Entity distance", "graphics", "entity_radius", 32, view_tiles, 16, func(v: float) -> String: return "%d tiles" % int(v),
		false, false, "Radius around the character for active entities and animations, up to View distance (server may cap).")
	dist_refs["belt"] = _card_slider(vp_box, "Belt item distance", "graphics", "belt_distance", 0, view_tiles, 32,
		func(v: float) -> String: return "Off" if int(v) == 0 else "%d tiles" % int(v), false, false,
		"How far out belt items are drawn, up to View distance (moving near you, static beyond).")
	if manual_split:
		_card_dropdown(va_box, "Distant horizon detail", "graphics", "distant_horizon_quality",
			[["Minimal", "minimal"], ["Low", "low"], ["Medium", "medium"], ["High", "high"], ["Ultra", "ultra"]],
			"Controls terrain grid detail and silhouette density across distant horizon rings.")
		_card_dropdown(va_box, "Distant horizon LOD dropoff", "graphics", "distant_horizon_dropoff",
			[["Near", "near"], ["Balanced", "balanced"], ["Far", "far"]],
			"Controls how quickly distant horizon rings step down in detail with distance.")
	_card_check(va_box, "Distant horizon night glow", "graphics", "distant_horizon_glow",
		"Adds a subtle warm glow to powered factory blocks on the horizon at night.")
	_card_check(va_box, "Distant horizon for wide screenshots", "graphics", "distant_horizon_shots",
		"Uses Distant horizon for the far background in wide screenshots instead of loading full chunks.")
	var manual_cb := _card_check(va_box, "Manual horizon split", "graphics", "distant_horizon_manual",
		"On (default): separate View distance (full) and Distant horizon sliders. Off: one unified Render distance slider up to 512 chunks, balanced by Level of detail. --render-distance-split=unified|manual overrides it.")
	var on_manual_split := func(_on: bool) -> void: _open_tab.call_deferred(_tab)
	manual_cb.toggled.connect(on_manual_split)
	_finish_category_card(c_dist)

	var c_world := _category_card(cols[1], "world", "World & Atmosphere")
	var wp: VBoxContainer = c_world["primary"]
	var wa: VBoxContainer = c_world["advanced"]
	_card_check(wp, "Clouds", "graphics", "clouds", "Draws overhead clouds, ground shadows, and atmospheric haze.")
	_grey_for_look("graphics-clouds", "clouds", "use its Clouds slider below")
	_card_check(wp, "Decoratives", "graphics", "decoratives", "Draws Factorio grass, flowers, and small rocks on the ground.")
	_card_dropdown(wp, "3D grass", "graphics", "grass_3d", [["Off", "off"], ["30 tiles, still", "short"], ["40 tiles, with wind", "normal"],
		["50 tiles, with wind", "far"]], "Raises nearby grass and plants into 3D meshes with optional wind sway. Needs Decoratives.")
	_card_check(wp, "Cliffs as one wall", "graphics", "cliff_wall",
		"Draws Nauvis's cliffs as one generated wall along each chain instead of the model pack's pieces (a pack with its own cliffs keeps them).")
	_card_check(wp, "Show all smoke and particles", "graphics", "effects", "Shows smoke, dust, sparks, and explosion particle effects.")
	_card_check(wp, "Bullet tracers", "graphics", "bullet_tracers",
		"Draws a short streak from the muzzle to the hit for each bullet and shotgun shot, in the ammo's colour (Factorio draws none).")
	_card_slider(wp, "Combat light strength", "graphics", "combat_light_strength", 0.0, 2.0, 0.05, func(v: float) -> String: return "Off" if v <= 0.0 else "%d%%" % roundi(v * 100.0), false, true,
		"How brightly muzzle flashes, explosions, flamethrowers and their fires light the area round them. 0% turns these lights off.", Callable(), 100.0)
	_card_slider(wp, "Smog", "graphics", "smog", 0.0, 1.0, 0.05, func(v: float) -> String: return "Off" if v <= 0.0 else "%d%%" % roundi(v * 100.0), false, true,
		"Volumetric haze over polluted chunks. 0% disables the pass.", Callable(), 100.0)
	_card_slider(wp, "God rays", "graphics", "god_rays", 0.0, 1.0, 0.05, func(v: float) -> String: return "Off" if v <= 0.0 else "%d%%" % roundi(v * 100.0), false, true,
		"Volumetric sunlight shafts through clouds, trees, and smog. 0% disables the pass.", Callable(), 100.0)
	_card_slider(wa, "Decorative density", "graphics", "decorative_density", 0.1, 1.0, 0.05, pct, false, false,
		"Controls how densely ground decoratives are scattered.", Callable(), 100.0)
	_card_slider(wa, "Decorative distance", "graphics", "decorative_distance", 64, 320, 16, func(v: float) -> String: return "%d tiles" % int(v),
		false, false, "How far out ground decoratives are drawn before thinning and fading.")
	_card_check(wa, "Step onto belts", "graphics", "belt_step",
		"Visually raises your character onto belts when walking across them.")
	_finish_category_card(c_world)

	# Column 2: Lighting & Quality + Picture & Accessibility
	var c_light := _category_card(cols[2], "lighting", "Lighting & Quality")
	var lp: VBoxContainer = c_light["primary"]
	var la: VBoxContainer = c_light["advanced"]
	if Settings._addons_started and Settings.switch_msaa_for_look():
		Settings.apply_antialiasing(get_tree().root)
	var under_look := Settings.antialiasing_look_note()
	var aa_note := "Smooths jagged edges. SMAA stays sharp; TAA softens motion; MSAA costs the most GPU."
	if under_look != "":
		aa_note = "MSAA is off under this look because its shader passes read depth. SMAA is used instead."
	var aa := _card_dropdown(lp, "Anti-aliasing", "graphics", "antialiasing", [["Off", "off"], ["FXAA", "fxaa"], ["SMAA", "smaa"], ["TAA", "taa"], ["MSAA 2×", "msaa2"], ["MSAA 4×", "msaa4"], ["MSAA 8×", "msaa8"]],
		aa_note, true)
	_grey_msaa(aa)
	_grey_aa_for_fsr2(aa)
	_card_dropdown(lp, "Shadows", "graphics", "shadows", [["Off", "off"], ["Low", "low"], ["Medium", "medium"], ["High", "high"], ["Ultra", "ultra"]],
		"Sets shadow sharpness, cascade count, and default shadow range.")
	_card_check(lp, "Ambient occlusion", "graphics", "ssao",
		"Adds soft contact shadows in tight corners when zoomed in.")
	_grey_for_look("graphics-ssao", "ssao", "use its Ambient occlusion toggle below")
	_card_check(lp, "Contact shading", "graphics", "contact_shading",
		"Draws a dark grounding rim around building bases, matching Factorio sprites.")
	_card_check(lp, "Far lamp lighting", "graphics", "far_lights",
		"Ties detailed 3D lamp and furnace/lab lights to Level of detail and draws a cheap 2D lightmap for distant lamps out to View distance. Off: fewer detailed lights with no far light pools.")
	_card_dropdown(la, "Shadow distance", "graphics", "shadow_distance",
		[["Automatic", 0], ["60 tiles", 60], ["100 tiles", 100], ["150 tiles", 150], ["200 tiles", 200], ["300 tiles", 300], ["400 tiles", 400]],
		"Max distance shadows reach from the camera. Automatic follows Shadows quality.")
	_card_dropdown(la, "Packs' own shading", "graphics", "pack_shading", [["As each pack says", "pack"], ["Factorio's everywhere", "factorio"]],
		"Uses each PBR model pack's lighting rules, or forces Factorio's lighting on all packs.")
	_card_check(la, "Ground textures from model packs", "graphics", "pack_tiles",
		"Uses ground tile pictures from enabled model packs in place of Factorio's.")
	_card_check(la, "Decoratives from model packs", "graphics", "pack_decoratives",
		"Uses decorative and 3D grass pictures from enabled model packs in place of Factorio's.")
	_card_check(la, "3D decorative models", "graphics", "decor_models",
		"Uses 3D models from model packs (including Placeholders) for grass, bushes, and tall plants instead of 2D sprites.")
	_finish_category_card(c_light)

	var c_access := _category_card(cols[2], "accessibility", "Picture & Accessibility")
	var ap: VBoxContainer = c_access["primary"]
	_card_slider(ap, "Brightness", "graphics", "brightness", 0.5, 1.5, 0.05, pct, false, true,
		"Adjusts overall image brightness.", Callable(), 100.0)
	_card_slider(ap, "Contrast", "graphics", "contrast", 0.5, 1.5, 0.05, pct, false, true,
		"Adjusts light-to-dark image contrast.", Callable(), 100.0)
	_card_slider(ap, "Saturation", "graphics", "saturation", 0.0, 2.0, 0.05, pct, false, true,
		"Adjusts color intensity (0% is grayscale).", Callable(), 100.0)
	_card_dropdown(ap, "Color filter", "graphics", "color_filter", ColorFilter.FILTERS.map(func(f: Array) -> Array: return [f[1], f[0]]),
		"Applies a colorblindness accessibility filter over the screen.")
	_finish_category_card(c_access)

	_add_shader_cards()


func _graphics_legacy() -> void:
	_row_inline_notes = false
	_heading("General")
	var grid := _grid()
	# The preset sets shadows, ambient occlusion, level of detail and the distances below together.
	_preset = MenuKit.dropdown(PRESET_ITEMS, Settings.preset_now())
	_preset.name = "graphics-preset"
	var on_preset := func(i: int) -> void:
		Sfx.play_ui("gui-click")
		var preset := str(_preset.get_item_metadata(i))
		if preset == "custom":
			_on_setting("graphics", "")  # nothing to set: back to what the settings match
		else:
			Settings.apply_preset(preset)
			_open_tab.call_deferred(_tab)
	_preset.item_selected.connect(on_preset)
	_row(grid, "Preset", _preset,
		"Sets shadows, ambient occlusion, level of detail, distances, grass, clouds, and god rays together.")
	var recommend := MenuKit.button(_recommended if _recommended != "" else "Recommended")
	recommend.name = "graphics-recommended"
	recommend.pressed.connect(_recommend.bind(recommend))
	_row(grid, "For this PC", recommend,
		"Tests hardware (and frame times in-game) to pick a preset aiming for steady 60 UPS/FPS.")
	# The resolution's list and note follow the mode and the screen.
	var reopen := func(_i: int) -> void: _open_tab.call_deferred(_tab)
	_dropdown(grid, "Full screen", "graphics", "window_mode", [["Windowed", "windowed"], ["Borderless full screen", "borderless"], ["Exclusive full screen", "fullscreen"]],
		"Switches between windowed, borderless fullscreen, and exclusive fullscreen.", true).item_selected.connect(reopen)
	var full_screen := str(Settings.get_value("graphics", "window_mode")) != "windowed"
	var resolution := _dropdown(grid, "Resolution", "graphics", "resolution", Settings.resolution_choices(DisplayServer.screen_get_size(Settings.chosen_screen()), full_screen),
		"Render size scaled to fill the monitor. Game render scaling multiplies on top." if full_screen else
		"Window size in windowed mode.", true)
	var on_resolution := func(i: int) -> void:
		if str(resolution.get_item_metadata(i)) == "":
			Settings.restore_default_window_size()
	resolution.item_selected.connect(on_resolution)
	var screens: Array = [["Primary screen (%d)" % (DisplayServer.get_primary_screen() + 1), -1]]
	for i in DisplayServer.get_screen_count():
		var s := DisplayServer.screen_get_size(i)
		screens.append(["Screen %d (%d × %d)" % [i + 1, s.x, s.y], i])
	_dropdown(grid, "Preferred screen", "graphics", "screen", screens,
		"Chooses which monitor the game window opens and fullscreens on.", true).item_selected.connect(reopen)
	_check(grid, "Minimize on focus loss", "graphics", "minimize_on_focus_loss",
		"Minimizes fullscreen windows when switching to another app.")
	_check(grid, "Wait for VSync", "graphics", "vsync",
		"Syncs frames with your monitor refresh rate to prevent tearing.", true)
	_dropdown(grid, "FPS limit", "graphics", "fps_cap", [["Unlimited", 0], ["30", 30], ["60", 60], ["120", 120], ["144", 144], ["240", 240]],
		"Caps the client frame rate.", true)
	_slider(grid, "Game render scaling", "graphics", "render_scale", 0.33, 2.0, 0.01, func(v: float) -> String: return "%d%%" % roundi(v * 100.0), true, false,
		"Scales the 3D world resolution while keeping menus and UI sharp.", Callable(), 100.0)
	_ask_before_dlss(_dropdown(grid, "Upscaling", "graphics", "upscaler", UPSCALER_ITEMS, UPSCALER_NOTE, true))
	_upscaling_quality(grid, false)
	_dlss_consent_row(grid)
	_slider(grid, "Upscaler sharpness", "graphics", "upscaler_sharpness", 0.0, 1.0, 0.05, func(v: float) -> String: return "%d%%" % roundi(v * 100.0), true, false,
		UPSCALER_SHARPNESS_NOTE, Callable(), 100.0)
	_grey_upscaler_rows()
	var lod_items := [["Low", "low"], ["Medium", "medium"], ["High", "high"], ["Ultra", "ultra"]]
	var lod_note := "Controls how quickly distant 3D models, shadows, and merged chunks simplify."
	var view_tiles := float(maxi(32, int(Settings.get_value("graphics", "view_radius")) * 32))
	var dist_refs := {"entity": {}, "belt": {}}
	var on_view_committed := func(v: float) -> void:
		_sync_distance_caps(v, dist_refs["entity"] as Dictionary, dist_refs["belt"] as Dictionary)
	var view_format := func(v: float) -> String:
		var n := int(v) * 2 + 1
		return "%d chunks around (%d × %d)" % [int(v), n, n]
	_slider(grid, "View distance (full)", "graphics", "view_radius", 2, Settings.VIEW_RADIUS_SLIDER_MAX, 1, view_format, false, false,
		"Full 3D chunk radius around the camera. Click value to type up to %d (red past %d)." % [Settings.VIEW_RADIUS_MAX, Settings.VIEW_RADIUS_SLIDER_MAX],
		view_distance_tint, 1.0, false, Settings.VIEW_RADIUS_MAX, on_view_committed)
	var dh_format := func(v: float) -> String:
		if int(v) <= 0:
			return "Off"
		return "%d chunks (%d tiles)" % [int(v), int(v) * 32]
	_slider(grid, "Distant horizon", "graphics", "distant_horizon", 0, Settings.DISTANT_HORIZON_SLIDER_MAX, 16, dh_format, false, false,
		"Draws cached 2.5D terrain and factory silhouettes past View distance. Click value to type up to %d (red past %d)." % [Settings.RENDER_DISTANCE_MAX, Settings.DISTANT_HORIZON_SLIDER_MAX],
		distant_horizon_tint, 1.0, false, Settings.RENDER_DISTANCE_MAX)
	_dropdown(grid, "Distant horizon detail", "graphics", "distant_horizon_quality",
		[["Minimal", "minimal"], ["Low", "low"], ["Medium", "medium"], ["High", "high"], ["Ultra", "ultra"]],
		"Controls terrain grid detail and silhouette density across distant horizon rings.")
	_dropdown(grid, "Distant horizon LOD dropoff", "graphics", "distant_horizon_dropoff",
		[["Near", "near"], ["Balanced", "balanced"], ["Far", "far"]],
		"Controls how quickly distant horizon rings step down in detail with distance.")
	dist_refs["entity"] = _slider(grid, "Entity distance", "graphics", "entity_radius", 32, view_tiles, 16, func(v: float) -> String: return "%d tiles" % int(v),
		false, false, "Radius around the character for active entities and animations, up to View distance (server may cap).")
	dist_refs["belt"] = _slider(grid, "Belt item distance", "graphics", "belt_distance", 0, view_tiles, 32,
		func(v: float) -> String: return "Off" if int(v) == 0 else "%d tiles" % int(v), false, false,
		"How far out belt items are drawn, up to View distance (moving near you, static beyond).")
	_dropdown(grid, "Moving belt items", "graphics", "belt_updates",
		[["Automatic", -1], ["1,000 items", 1000], ["2,000 items", 2000], ["4,000 items", 4000], ["6,000 items", 6000], ["12,000 items", 12000],
		["24,000 items", 24000], ["Unlimited", 0]],
		"Max moving belt items updated per tick; farther items stay static. Automatic scales with frame time.")
	# Smooth belt items (belt_smooth) and item icons (item_icons) are no longer shown (owner: too
	# many belt settings): both stay on (Hold 60 UPS has no step for belt_smooth; only an add-on's lighter updates ease it).
	_check(grid, "Hold the game at 60 UPS", "graphics", "hold_ups",
		"Temporarily trims bridge updates and distances whenever UPS drops below 60.")
	_check(grid, "Give the server the CPU first", "graphics", "server_first",
		"Lowers client priority when hosting locally so Factorio ticks stay responsive.")
	_check(grid, "Show all smoke and particles", "graphics", "effects",
		"Shows smoke, dust, sparks, and explosion particle effects.")
	_check(grid, "Bullet tracers", "graphics", "bullet_tracers",
		"Draws a short streak from the muzzle to the hit for each bullet and shotgun shot, in the ammo's colour (Factorio draws none).")
	_slider(grid, "Combat light strength", "graphics", "combat_light_strength", 0.0, 2.0, 0.05, func(v: float) -> String: return "Off" if v <= 0.0 else "%d%%" % roundi(v * 100.0), false, true,
		"How brightly muzzle flashes, explosions, flamethrowers and their fires light the area round them. 0% turns these lights off.", Callable(), 100.0)
	_check(grid, "Step onto belts", "graphics", "belt_step",
		"Visually raises your character onto belts when walking across them.")
	var legacy_item_fmt := func(v: float) -> String:
		if int(v) <= 0:
			return "Icons only"
		return "All" if int(v) >= Settings.ITEM_MODELS_ALL else "%d" % int(v)
	_slider(grid, "Items in 3D", "graphics", "item_models_max", 0, Settings.ITEM_MODELS_ALL, 500, legacy_item_fmt, false, false,
		"Max belt items drawn as 3D models (nearest first); the rest show 2D icons.", Callable(), 1.0, true)
	_check(grid, "Clouds", "graphics", "clouds", "Draws overhead clouds, ground shadows, and atmospheric haze.")
	_grey_for_look("graphics-clouds", "clouds", "use its Clouds slider in the Add-ons menu")
	_check(grid, "Decoratives", "graphics", "decoratives", "Draws Factorio grass, flowers, and small rocks on the ground.")
	_slider(grid, "Decorative density", "graphics", "decorative_density", 0.1, 1.0, 0.05, func(v: float) -> String: return "%d%%" % roundi(v * 100.0), false, false,
		"Controls how densely ground decoratives are scattered.", Callable(), 100.0)
	_slider(grid, "Decorative distance", "graphics", "decorative_distance", 64, 320, 16, func(v: float) -> String: return "%d tiles" % int(v),
		false, false, "How far out ground decoratives are drawn before thinning and fading.")
	_dropdown(grid, "3D grass", "graphics", "grass_3d", [["Off", "off"], ["30 tiles, still", "short"], ["40 tiles, with wind", "normal"],
		["50 tiles, with wind", "far"]], "Raises nearby grass and plants into 3D meshes with optional wind sway. Needs Decoratives.")
	_slider(grid, "Smog", "graphics", "smog", 0.0, 1.0, 0.05, func(v: float) -> String: return "Off" if v <= 0.0 else "%d%%" % roundi(v * 100.0), false, true,
		"Volumetric haze over polluted chunks. 0% disables the pass.", Callable(), 100.0)
	_slider(grid, "God rays", "graphics", "god_rays", 0.0, 1.0, 0.05, func(v: float) -> String: return "Off" if v <= 0.0 else "%d%%" % roundi(v * 100.0), false, true,
		"Volumetric sunlight shafts through clouds, trees, and smog. 0% disables the pass.", Callable(), 100.0)
	_dropdown(grid, "Look", "graphics", "look", Looks.choices(),
		"Sets world lighting and color grading. Add-ons can add looks here.").item_selected.connect(reopen)  # rows a look sets itself grey out

	_heading("Advanced")
	grid = _grid()
	# A saved MSAA under such a look is shown as the SMAA drawn (normally switched at the start already).
	if Settings._addons_started and Settings.switch_msaa_for_look():
		Settings.apply_antialiasing(get_tree().root)
	var under_look := Settings.antialiasing_look_note()
	var aa_note := "Smooths jagged edges. SMAA stays sharp; TAA softens motion; MSAA costs the most GPU."
	if under_look != "":
		aa_note = "MSAA is off under this look because its shader passes read depth. SMAA is used instead."
	var aa := _dropdown(grid, "Anti-aliasing", "graphics", "antialiasing", [["Off", "off"], ["FXAA", "fxaa"], ["SMAA", "smaa"], ["TAA", "taa"], ["MSAA 2×", "msaa2"], ["MSAA 4×", "msaa4"], ["MSAA 8×", "msaa8"]],
		aa_note, true)
	_grey_msaa(aa)
	_grey_aa_for_fsr2(aa)
	_dropdown(grid, "Shadows", "graphics", "shadows", [["Off", "off"], ["Low", "low"], ["Medium", "medium"], ["High", "high"], ["Ultra", "ultra"]],
		"Sets shadow sharpness, cascade count, and default shadow range.")
	_dropdown(grid, "Shadow distance", "graphics", "shadow_distance",
		[["Automatic", 0], ["60 tiles", 60], ["100 tiles", 100], ["150 tiles", 150], ["200 tiles", 200], ["300 tiles", 300], ["400 tiles", 400]],
		"Max distance shadows reach from the camera. Automatic follows Shadows quality.")
	_dropdown(grid, "Level of detail", "graphics", "lod_quality", lod_items, lod_note)
	var lod_dist_fmt := func(v: float) -> String:
		if int(v) <= 0:
			return "Auto"
		return "%d tiles" % int(v)
	_slider(grid, "LOD falloff distance", "graphics", "lod_distance", 0, 160, 4, lod_dist_fmt, false, false,
		"Custom distance where LODs start falling off; models, belts, items, merged chunks, and lights auto-adjust from it. 0 follows Level of detail.")
	_check(grid, "Distant horizon night glow", "graphics", "distant_horizon_glow",
		"Adds a subtle warm glow to powered factory blocks on the horizon at night.")
	_check(grid, "Distant horizon for wide screenshots", "graphics", "distant_horizon_shots",
		"Uses Distant horizon for the far background in wide screenshots instead of loading full chunks.")
	_check(grid, "Merge far buildings", "graphics", "merge_far",
		"Combines distant chunks' static buildings into simplified meshes to cut draw calls.")
	_check(grid, "Cliffs as one wall", "graphics", "cliff_wall",
		"Draws Nauvis's cliffs as one generated wall along each chain instead of the model pack's pieces (a pack with its own cliffs keeps them).")
	_check(grid, "Animate modded buildings", "graphics", "animate_mod_buildings",
		"Animates Factorio sprite stand-ins for modded buildings without 3D models.")
	_check(grid, "Merged materials (may help when CPU-bound)", "graphics", "merged_materials",
		"Combines model surfaces to reduce CPU draw calls at slight GPU cost. Needs restart.")
	_check(grid, "Ambient occlusion", "graphics", "ssao",
		"Adds soft contact shadows in tight corners when zoomed in.")
	_grey_for_look("graphics-ssao", "ssao", "use its Ambient occlusion toggle in the Add-ons menu")
	_dropdown(grid, "Packs' own shading", "graphics", "pack_shading", [["As each pack says", "pack"], ["Factorio's everywhere", "factorio"]],
		"Uses each PBR model pack's lighting rules, or forces Factorio's lighting on all packs.")
	_check(grid, "Ground textures from model packs", "graphics", "pack_tiles",
		"Zenith's own|Uses ground tile pictures from enabled model packs in place of Factorio's, by the packs' order in Model packs. Off: Factorio's own ground only.")
	_check(grid, "Decoratives from model packs", "graphics", "pack_decoratives",
		"Zenith's own|Uses decorative and 3D grass pictures from enabled model packs in place of Factorio's, by the packs' order in Model packs. Off: Factorio's own decoratives only.")
	_check(grid, "3D decorative models", "graphics", "decor_models",
		"Zenith's own|Draws 3D models for raised grass, bushes, and upright plants when enabled packs provide them. Off: uses 2D pictures and procedural grass instead.")
	_check(grid, "Contact shading", "graphics", "contact_shading",
		"Draws a dark grounding rim around building bases, matching Factorio sprites.")
	_check(grid, "Far lamp lighting", "graphics", "far_lights",
		"Ties detailed 3D lamp and furnace/lab lights to Level of detail and draws a cheap 2D lightmap for distant lamps out to View distance. Off: fewer detailed lights with no far light pools.")
	_check(grid, "Render on a separate thread", "graphics", "render_thread",
		"Godot's renderer on its own thread: smoother on busy bases. Off: the main thread draws, as before. Needs restart.")
	if OS.get_name() == "Windows":
		_dropdown(grid, "Renderer", "graphics", "renderer", RENDERER_ITEMS, _renderer_note())

	_heading("Accessibility")
	grid = _grid()
	var pct := func(v: float) -> String: return "%d%%" % roundi(v * 100.0)
	_slider(grid, "Brightness", "graphics", "brightness", 0.5, 1.5, 0.05, pct, false, true,
		"Adjusts overall image brightness.", Callable(), 100.0)
	_slider(grid, "Contrast", "graphics", "contrast", 0.5, 1.5, 0.05, pct, false, true,
		"Adjusts light-to-dark image contrast.", Callable(), 100.0)
	_slider(grid, "Saturation", "graphics", "saturation", 0.0, 2.0, 0.05, pct, false, true,
		"Adjusts color intensity (0% is grayscale).", Callable(), 100.0)
	_dropdown(grid, "Color filter", "graphics", "color_filter", ColorFilter.FILTERS.map(func(f: Array) -> Array: return [f[1], f[0]]),
		"Applies a colorblindness accessibility filter over the screen.")


func _sound() -> void:
	_heading("Output")
	var grid := _grid()
	var devices: Array = []
	for d in AudioServer.get_output_device_list():
		devices.append(["Default device" if d == "Default" else d, d])
	_dropdown(grid, "Preferred output", "sound", "output_device", devices)
	_slider(grid, "Machine sounds at once", "sound", "max_voices", 4, 64, 1, func(v: float) -> String: return "%d" % int(v), false, false, "from the next game")
	_check(grid, "Sounds from model packs", "sound", "pack_sounds", "Zenith's own|Sounds a model pack carries play in place of Factorio's, by the packs' order in Model packs. Off: Factorio's own sounds only.")
	_heading("Volume")
	grid = _grid()
	for entry in SOUND:
		var key: String = entry[1]
		var holder := _hbox()
		var on := MenuKit.checkbox("", bool(FxSettings.enabled.get(key, true)))
		on.name = "sound-%s_on" % key
		on.tooltip_text = wrap_tooltip("Enable/Disable (Mute) all sounds of this category.")
		var on_toggled := func(v: bool) -> void:
			Sfx.play_ui("gui-checkbox-click")
			FxSettings.set_enabled(key, v)
		on.toggled.connect(on_toggled)
		holder.add_child(on)
		var s := MenuKit.slider(0.0, 1.0, 0.01, float(FxSettings.volumes.get(key, 1.0)))
		s.name = "sound-" + key
		var sound_fmt := func(v: float) -> String: return "%d%%" % roundi(v * 100.0)
		var on_sound_changed := func(v: float) -> void: FxSettings.set_volume(key, v, false)
		s.value_changed.connect(on_sound_changed)
		var on_sound_commit := func(v: float) -> void:
			FxSettings.set_volume(key, v, true)
			Sfx.play_ui("gui-slider")
		var on_sound_drag := func(_changed: bool) -> void: on_sound_commit.call(s.value)
		s.drag_ended.connect(on_sound_drag)
		var val_ed := make_slider_value_editor(s, sound_fmt, on_sound_commit, {
			"name": s.name + "-value",
			"display_scale": 100.0,
			"min_width": Kit.px(48),
		})
		holder.add_child(s)
		holder.add_child(val_ed["box"])
		if entry.size() > 2:
			s.tooltip_text = wrap_tooltip(entry[2])
		_row(grid, entry[0], holder)
	_note("Music is Factorio's soundtrack, read from your install. The game effects slider also turns down walking, environment, weapons, explosions and enemies.")


func _controls() -> void:
	_note("Click a binding, then press the key (with Shift, Ctrl or Alt if you like). Right click clears it, Esc cancels. Bindings that clash are red.")
	# Issue #14: the keys changed in Factorio's own controls are the defaults here.
	var top := _grid()
	var use := MenuKit.checkbox("", bool(Settings.get_value("factorio", "use_factorio_keys")))
	use.name = "factorio-use_factorio_keys"
	use.toggled.connect(func(on: bool) -> void:
		Sfx.play_ui("gui-checkbox-click")
		Settings.set_value("factorio", "use_factorio_keys", on)
		Settings.reload_factorio_keys()
		_open_tab.call_deferred(_tab))
	var found: String = load("res://scripts/player/factorio_keys.gd").config_path()
	var changed := Settings.factorio_keys_changed
	var where := ("%d changed there, from %s" % [changed, found]) if found != "" else "Factorio's config.ini wasn't found"
	_row(top, "Use the keys set in Factorio", use, "Factorio's Settings > Controls; %s|Factorio's keys are the defaults here: the ones you changed in Factorio's own controls, and Factorio's own defaults for the rest (both from its config.ini; with Zenith 0.2.2's keys on, only the ones you changed), so Factorio and Zenith answer the same keys. A binding changed on this page still wins; Default puts Factorio's back. Off, or without a config.ini: Zenith's built-in keys. Read when Zenith starts, when its window comes back from another, and when this is switched: %s" % [where, where])
	# Issue #26: the switch back to Zenith 0.2.2's keys, from before Zenith followed Factorio 2.1's defaults.
	var old := MenuKit.checkbox("", Controls.old_defaults())
	old.name = "factorio-" + Controls.OLD_KEYS_SETTING
	old.disabled = Controls.old_defaults_forced()
	old.toggled.connect(func(on: bool) -> void:
		Sfx.play_ui("gui-checkbox-click")
		Settings.set_value("factorio", Controls.OLD_KEYS_SETTING, on)
		_open_tab.call_deferred(_tab))
	_row(top, "Zenith 0.2.2's keys", old, ("On for this run (--keys-defaults=old)|" if Controls.old_defaults_forced() else "|") + "The keys Zenith had before it followed Factorio 2.1's defaults: the arrow keys walk and pan the map, / opens the console, Keypad Enter gets in and out of vehicles, M opens the map (not Tab), Tab is Next weapon and C is Shoot selected. Of Factorio's controls only the keys you changed there are used, not its defaults. A binding changed on this page still wins.")
	# Issue #26: Factorio's keys over the ones saved here, with what was copied and what wasn't.
	var copy := MenuKit.button("Copy keys from Factorio")
	copy.name = "CopyFactorioKeys"
	copy.tooltip_text = wrap_tooltip("Reads Factorio's config.ini again and drops the bindings changed on this page for every control Factorio has, so each follows Factorio's key: the one changed there, else Factorio's default. Zenith's own controls (camera, views) keep theirs.")
	copy.pressed.connect(func() -> void:
		Sfx.play_ui("gui-click")
		copy_factorio_keys())
	_row(top, "Factorio's keys over these", copy)
	var by_group := {}
	for action in Settings.bindable_actions():
		var group := ControlsInfo.group_of(action)
		if not by_group.has(group):
			by_group[group] = []
		by_group[group].append(action)
	var named := {}
	for action in Settings.bindable_actions():
		named[ControlsInfo.name_of(action)] = true
	for group in ControlsInfo.groups():  # Zenith's groups, then each add-on's (scripts/addons/)
		var fixed: Array = ControlsInfo.FIXED.filter(func(f: Array) -> bool: return f[0] == group and not named.has(f[1]))
		if not by_group.has(group) and fixed.is_empty():
			continue
		_heading(group)
		var grid := GridContainer.new()
		grid.columns = 4
		grid.add_theme_constant_override("h_separation", Kit.px(12))
		grid.add_theme_constant_override("v_separation", Kit.px(4))
		_pane.add_child(grid)
		for action in by_group.get(group, []):
			_binding_row(grid, action)
		for f in fixed:
			var l := Kit.label(f[1])
			l.custom_minimum_size.x = Kit.px(260)
			grid.add_child(l)
			var key := Kit.label(f[2])
			key.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
			key.tooltip_text = "Not rebindable yet"
			grid.add_child(key)
			grid.add_child(Control.new())
			grid.add_child(Control.new())
	var reset_all := MenuKit.button("Reset all to defaults")
	reset_all.name = "ResetControls"
	reset_all.custom_minimum_size.x = Kit.px(200)
	reset_all.pressed.connect(func() -> void:
		Sfx.play_ui("gui-click")
		for action in Settings.bindable_actions():
			Settings.bind(action, [])
		_open_tab(_tab))
	_pane.add_child(reset_all)


## Settings.copy_factorio_keys, then Factorio's style of message: what was copied, what wasn't and
## why, and the config.ini read. Returns the message's text (tests).
func copy_factorio_keys() -> String:
	var r: Dictionary = Settings.copy_factorio_keys()
	_open_tab(_tab)
	var text := copy_report_text(r)
	_show_message("Copy keys from Factorio", text)
	return text


## "Copy keys from Factorio"'s message: the keys as Factorio shows them (factorio_keys.gd's key_label),
## controls by Zenith's names where it has them, Factorio's own otherwise.
static func copy_report_text(r: Dictionary, os_name := OS.get_name()) -> String:
	var file := str(r.get("file", ""))
	if file == "":
		return "Factorio's config.ini wasn't found, so nothing was copied. Zenith looks where the Factorio install in Settings > Factorio install keeps it (its config-path.cfg), then in %s. Start Factorio once and change a key there, or choose the install." % FactorioKeys.system_config_text(os_name)
	var lines: Array = []
	if bool(r.get("old_keys", false)):
		lines.append("With Zenith 0.2.2's keys on: only the keys changed in Factorio are copied, Zenith 0.2.2's keys for the rest.")
	else:
		lines.append("With Factorio's keys: the keys changed in Factorio, and Factorio's defaults for the rest.")
	var copied: Array = r.get("copied", [])
	var defaults: Array = r.get("defaults", [])
	if copied.is_empty():
		lines.append("None of Factorio's controls were changed there." + (" Its defaults are used here." if not defaults.is_empty() else ""))
	else:
		lines.append("Copied (%d):" % copied.size())
		for c in copied:
			var key := FactorioKeys.key_label(int(c[3]))
			lines.append("  %s: %s" % [_slot_name(str(c[1]), int(c[2])), key if key != "" else "unbound, as in Factorio"])
	var skipped: Array = r.get("skipped", [])
	if not skipped.is_empty():
		lines.append("Not copied (%d):" % skipped.size())
		for c in skipped:
			var control := str(c[0])
			var base := control.trim_suffix("-alternative").trim_suffix("-controller")
			var label := control
			if FactorioKeys.ACTIONS.has(base):
				label = ControlsInfo.name_of(FactorioKeys.ACTIONS[base])
				if control.contains("-controller"):
					label += " (controller)"
				elif control.ends_with("-alternative"):
					label += " (alternative)"
			lines.append("  %s: %s (%s)" % [label, FactorioKeys.value_label(str(c[1])), c[2]])
	var clashes: Array = r.get("clashes", [])
	if not clashes.is_empty():
		lines.append("Also on one of Zenith's own controls (both act; change either in this tab):")
		for c in clashes:
			var own: Array = (c[2] as Array).map(func(a: String) -> String: return ControlsInfo.name_of(a))
			lines.append("  %s: %s, also %s" % [FactorioKeys.key_label(int(c[1])), ControlsInfo.name_of(str(c[0])), ", ".join(own)])
	if not defaults.is_empty():
		lines.append("Factorio's defaults taken for the rest: %d." % defaults.size())
	var reset: Array = r.get("reset", [])
	if not reset.is_empty():
		# Without Factorio's default lines (an old or hand-written config.ini) the rest are Zenith's own.
		lines.append(("Bindings changed here put back to Factorio's: %d." if not defaults.is_empty()
			else "Bindings changed here put back to the defaults (Factorio's changed keys, Zenith's own otherwise): %d.") % reset.size())
	lines.append("Read from: " + file)
	return "\n".join(lines)


static func _slot_name(action: String, slot: int) -> String:
	return ControlsInfo.name_of(action) + (" (alternative)" if slot == 1 else "")


## A message over the settings with Factorio's OK button (MenuKit.message, scrolling).
func _show_message(title: String, text: String) -> void:
	var parts: Array = MenuKit.message(title, text, true)
	var o: Control = parts[0]
	(parts[1] as Button).pressed.connect(func() -> void:
		Sfx.play_ui("gui-click")
		o.queue_free())
	add_child(o)
	print("settings: %s: %s" % [title, text.replace("\n", " | ")])


func _binding_row(grid: GridContainer, action: String) -> void:
	var l := Kit.label(ControlsInfo.name_of(action))
	l.custom_minimum_size.x = Kit.px(260)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	grid.add_child(l)
	var keys := Settings.keys_for(action)
	for slot in 2:
		var target := "%s/%d" % [action, slot]
		var b := MenuKit.button(Settings.key_name(action, slot))
		b.name = "controls-" + target.replace("/", "-")
		b.custom_minimum_size.x = Kit.px(150)
		var clash := Settings.conflicts(action, int(keys[slot]))
		if not clash.is_empty():
			b.add_theme_color_override("font_color", Kit.RED_TEXT)
			b.tooltip_text = wrap_tooltip("Also bound to: " + ", ".join(clash.map(func(a: String) -> String: return ControlsInfo.name_of(a))))
		if _capturing == target:
			b.text = "Press a key…"
		b.pressed.connect(func() -> void:
			Sfx.play_ui("gui-click")
			_capturing = target
			b.text = "Press a key…")
		b.gui_input.connect(func(ev: InputEvent) -> void:
			var mb := ev as InputEventMouseButton
			if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
				capture(target, 0)
				_open_tab(_tab))
		grid.add_child(b)
	if keys != Settings.default_keys(action):
		var reset := MenuKit.button("Default")
		reset.custom_minimum_size.x = Kit.px(72)
		reset.tooltip_text = wrap_tooltip("Back to " + " / ".join(Settings.default_keys(action).filter(func(c: int) -> bool: return c != 0).map(func(c: int) -> String: return Settings.key_text(c))))
		reset.pressed.connect(func() -> void:
			Sfx.play_ui("gui-click")
			Settings.bind(action, [])
			_open_tab(_tab))
		grid.add_child(reset)
	else:
		grid.add_child(Control.new())


## Laid out under Factorio's headings (Visualization, Alt-mode, Interaction, UI scale, Tooltips,
## Other) with its wording; the client's own switches and the minimap's size follow.
func _interface() -> void:
	_heading("Visualization")
	var grid := _grid()
	_ui_check(grid, "Show minimap", "map/minimap", "M opens the map")
	_check(grid, "Show mouse and keyboard control hints", "interface", "show_help", "F1; the client's help panel, hidden while a window is open")
	_check(grid, "Show fluid pipeline visualization", "interface", "fluid_vis", "When holding a fluid-related entity, show all fluid pipelines in view (in Alt-mode).")
	_check(grid, "Show fluid pipeline visualization when selected", "interface", "fluid_vis_selected", "When hovering over an entity, show that entity's fluid pipelines.")

	_heading("Alt-mode")
	grid = _grid()
	_check(grid, "Alt-mode", "interface", "alt_mode", "Alt toggles it; kept between games")
	_check(grid, "Show inserter arrows in \"Alt-mode\"", "interface", "alt_inserter_arrows", "where each inserter picks up and drops")
	_check(grid, "Show pump arrows in \"Alt-mode\"", "interface", "alt_pump_arrows", "the way each pump moves its fluid")
	_check(grid, "Show machine arrows in \"Alt-mode\"", "interface", "alt_machine_arrows", "machines' fluid inputs and outputs, a recycler's output side")

	_check(grid, "Auto check for updates on open", "interface", "update_check",
		"off by default: nothing is requested until you click \"Check for updates\" in the main menu. On: asks GitHub's public release page when the menu opens, at most once in 6 hours; sends nothing about you; --update-check=off")

	_heading("Interaction")
	grid = _grid()
	_check(grid, "Smart belt building", "interface", "smart_belt_building", "dragged belts jump obstacles with undergrounds")
	_check(grid, "Lock belt building to straight line", "interface", "lock_belt_straight",
		"dragged belts keep to the held belt's line, as in Factorio (R turns it); off, they follow the cursor round corners")
	_check(grid, "Vehicle: opposite key brakes and holds", "interface", "vehicle_brake_hold",
		"driving: S while going forward (W while reversing) brakes to a stop and stays stopped until let go|Not Factorio's way: there the opposite key brakes and then reverses. With this on, the key brakes the car, tank or locomotive to a stop and holds it there until you let go; pressing it again from a stop drives that way. Off by default; --vehicle-brake-hold=on|off sets it for one run.")
	_check(grid, "Always keep player's main inventory sorted", "interface", "auto_sort_inventory",
		"sorts and merges stacks in the character's main inventory automatically")
	_check(grid, "Always keep other inventories sorted", "interface", "auto_sort_containers",
		"sorts and merges stacks in open chests, cargo wagons, vehicle trunks and trash slots")

	_heading("UI scale")
	grid = _grid()
	_dropdown(grid, "UI scale", "interface", "ui_scale", [["Automatic", "auto"], ["75%", "0.75"], ["100%", "1.0"], ["125%", "1.25"], ["150%", "1.5"], ["175%", "1.75"], ["200%", "2.0"]], " / ".join(["increase_ui_scale", "decrease_ui_scale", "reset_ui_scale"].map(func(a: String) -> String: return Settings.key_names(a))))

	_heading("Tooltips")
	grid = _grid()
	_slider(grid, "Tooltip delay", "interface", "tooltip_delay", 0.0, 2.0, 0.05, func(v: float) -> String: return "%d ms" % roundi(v * 1000.0), false, false, "", Callable(), 1000.0)
	_check(grid, "Entity tooltip on the side", "interface", "entity_info", "the panel for what the mouse is over, on the right")
	_check(grid, "Show mods' windows (experimental)", "interface", "mod_windows", "off: use them in Factorio (Ctrl+F9)|Mods' windows (Informatron, Factory Planner...) drawn in Zenith from your Factorio, live. Experimental: their layout and buttons don't match Factorio's yet, so for now they are off and Ctrl+F9 (or the Factorio button at the top left) is the way to use them.")
	_check(grid, "Click mods' buttons in Factorio", "interface", "mod_clicks", "pressing a mod's button clicks it in your own Factorio window (hybrid)|A mod hears only clicks made in Factorio itself. With this on, pressing a mod's button in Zenith brings Factorio to the front for a moment, clicks the button there and comes back to Zenith (a minimised Factorio is minimised again). Needs Factorio's window on this PC: hybrid single-player, or joined to the server as yourself. Off: the button says to use it in Factorio (Ctrl+F9).")

	_heading("Other")
	grid = _grid()
	_slider(grid, "Chat message delay", "interface", "message_delay", 1.0, 20.0, 0.5, func(v: float) -> String: return ("%d s" % roundi(v)) if is_equal_approx(v, roundf(v)) else "%.1f s" % v)

	_heading("3D client")
	grid = _grid()
	_check(grid, "Shortcut bar", "interface", "shortcut_bar", "right of the quickbar")
	_check(grid, "Research progress", "interface", "research_progress", "top right")
	_check(grid, "Alerts", "interface", "alerts", "over the shortcut bar")
	_check(grid, "Night vision indicator", "interface", "night_vision_indicator", "the equipment's icon over the shortcut bar while it is on")
	_check(grid, "Night vision screen edge", "interface", "night_vision_edge", "a soft green vignette at the screen's edges while it is on")
	for key in ["night_vision_indicator", "night_vision_edge"]:  # --night-vision-fx=off holds both (and the sound) off, unsaved
		(grid.find_child("interface-" + key, true, false) as CheckBox).set_pressed_no_signal(not NightVisionOverlay.forced_off and bool(Settings.get_value("interface", key)))
	_check(grid, "Performance warnings", "interface", "perf_warning", "an icon top left while settings are held back for UPS|A yellow warning icon at the top left while Hold the game at 60 UPS holds settings back, with how many; click it for the log of what was held back, when and why. The log fills with this off too.")
	# --perf-warning=off holds it off until changed, unsaved: the box shows that, so one click turns it on.
	(grid.find_child("interface-perf_warning", true, false) as CheckBox).set_pressed_no_signal(PerfWarning.enabled())
	# Its key as bound now: F4 in dev builds, none by default in a public one (issue #26).
	var debug_key := Settings.key_names("debug_line")
	_check(grid, "Debug line" if debug_key == "(none)" else "Debug line (%s)" % debug_key, "interface", "debug_overlay", "tick, chunks, packets, FPS")
	_ui_slider(grid, "Minimap size", "map/minimap_size", 120.0, 480.0, 20.0, func(v: float) -> String: return "%d px" % roundi(v))
	_ui_slider(grid, "Minimap zoom", "map/minimap_zoom", 0.25, 4.0, 0.25, func(v: float) -> String: return "%.2f px per tile" % v)
	_ui_check(grid, "Show tags on the minimap", "map/minimap_tags")

	_heading("Map view")
	grid = _grid()
	for layer in UiSettings.MAP_LAYERS:
		_ui_check(grid, layer[1], layer[0])
	_note("The map view's switches are also on the map itself (M). The minimap, as Factorio's, shows none of them.")


func _other() -> void:
	_heading("Server")
	var grid := _grid()
	var intervals: Array = [["Never", 0]]
	for m in [1, 2, 5, 10, 15, 20, 30, 60]:
		intervals.append(["%d min" % m, m])
	# An interval set in Factorio's own settings (use_factorio_settings) may be none of these: show it, not "Never".
	var interval := int(Settings.get_value("factorio", "autosave_interval"))
	if interval > 0 and not [1, 2, 5, 10, 15, 20, 30, 60].has(interval):
		intervals.append(["%d min" % interval, interval])
		intervals.sort_custom(func(a: Array, b: Array) -> bool: return int(a[1]) < int(b[1]))
	_dropdown(grid, "Autosave interval", "factorio", "autosave_interval", intervals, "servers started from the menu")
	_slider(grid, "Autosave slots", "factorio", "autosave_slots", 1, 20, 1, func(v: float) -> String: return "%d" % int(v))
	_check(grid, "Verbose logging", "factorio", "verbose_logging", "the server's factorio-current.log")
	_note("These go into the server-settings.json the menu writes in the server's data folder when it starts a server, and apply from the next start.")
	_heading("Switching with Factorio (Ctrl+F9)")
	var swap := _grid()
	_check(swap, "Minimise Factorio in Zenith", "factorio", "minimize_factorio", "spares its drawing while Zenith shows the game")
	var copy := MenuKit.button("Copy launch options")
	copy.name = "factorio-copy-launch"
	var on_copy := func() -> void:
		Sfx.play_ui("gui-click")
		DisplayServer.clipboard_set(launch_options())
		copy.text = "Copied"
	copy.pressed.connect(on_copy)
	_row(swap, "Start Zenith from Factorio", copy,
		"for Factorio's launch options in Steam|Ctrl+F9 in Factorio starts Zenith only when Factorio was started through Zenith's launcher. Paste this in Steam: Factorio > Properties > Launch options, in place of what is there, and restart Factorio. It opens the bridge's UDP port too, and it is the same line on every PC: Zenith keeps the launcher in Windows' ProgramData folder (its Zenith folder) and updates it each time it starts.")


func _mod_settings() -> void:
	_heading("Map")
	if rcon == null or not rcon.is_open():
		_note("The bridge mod's map settings can be changed here while you play a game started from this menu. In other games, type them in the server's console, for example /c settings.global[\"f3d-chunks-per-tick\"] = {value = 2}.")
		return
	var grid := _grid()
	var status := Kit.label("Reading the server's settings…")
	status.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	_pane.add_child(status)
	var names: Array = MOD_SETTINGS.map(func(m: Array) -> String: return "\"%s\"" % m[0])
	var reply: String = await rcon.run(get_tree(), "/sc local o = {} for _, n in pairs({%s}) do o[n] = settings.global[n].value end rcon.print(helpers.table_to_json(o))" % ", ".join(names))
	if not is_inside_tree() or TABS[_tab] != "Mod settings":
		return
	var values = JSON.parse_string(reply.strip_edges())
	if not values is Dictionary:
		status.text = "The server didn't answer: " + reply.strip_edges()
		return
	status.text = "Changes are sent to the server at once (settings.global)."
	for m in MOD_SETTINGS:
		var name: String = m[0]
		var current = values.get(name, m[3])
		var control: Control
		match str(m[2]):
			"bool":
				var c := MenuKit.checkbox("", bool(current))
				c.toggled.connect(func(on: bool) -> void:
					Sfx.play_ui("gui-checkbox-click")
					_set_mod_setting(name, "true" if on else "false"))
				control = c
			"int":
				var spin := SpinBox.new()
				spin.min_value = m[4]
				spin.max_value = m[5]
				spin.value = int(current)
				spin.custom_minimum_size = Kit.pxv(160, 28)
				spin.value_changed.connect(func(v: float) -> void: _set_mod_setting(name, str(int(v))))
				control = spin
			_:
				var e := MenuKit.textbox(str(current))
				e.set_meta("sent", str(current))
				var send_text := func() -> void:
					var t := e.text.strip_edges()
					if t != str(e.get_meta("sent")):
						e.set_meta("sent", t)
						_set_mod_setting(name, JSON.stringify(t))
				e.text_submitted.connect(func(_t: String) -> void: send_text.call())
				# Leaving the box applies it too (Factorio applies a text setting when you confirm).
				e.focus_exited.connect(send_text)
				control = e
		control.name = "mod-" + name
		_row(grid, m[1], control, "default %s" % str(m[3]))


func _set_mod_setting(name: String, lua_value: String) -> void:
	if rcon != null and rcon.is_open():
		await rcon.run(get_tree(), "/sc settings.global[\"%s\"] = {value = %s}" % [name, lua_value])


func _camera() -> void:
	var grid := _grid()
	_dropdown(grid, "View when a game starts", "camera", "default_view", [["Angled view", "angled"], ["Factorio's view", "factorio"], ["First person", "first_person"]], "F6 and F5 switch in the game")
	_dropdown(grid, "Projection", "camera", "orthographic", [["Perspective", false], ["Orthographic", true]], "for the angled view; Factorio's view (F6) is always orthographic; F7 switches")
	_dropdown(grid, "Projection on the map", "camera", "map_orthographic", [["Perspective", false], ["Orthographic", true]], "the remote view, zoomed in from the map; F7 there switches it")
	_dropdown(grid, "Projection in first person", "camera", "first_person_orthographic", [["Perspective", false], ["Orthographic", true]], "F7 in first person switches it")
	_slider(grid, "Furthest zoom", "camera", "max_zoom", 60.0, 400.0, 10.0, func(v: float) -> String: return "%d tiles" % int(v), false, false, "the default is 140; far out, more of the world must be drawn")
	_check(grid, "Auto-swap map between 2D and 3D on zoom", "camera", "map_auto_swap", "zooming all the way in on the 2D map drops into 3D, and zooming out past the distance below goes back to 2D; off uses the 2D/3D button in the top bar")
	_slider(grid, "Zoom out to the map at", "camera", "map_zoom_out", 80.0, 480.0, 10.0, func(v: float) -> String: return "%d tiles" % int(v), false, false, "the view zoomed in from the map goes back to the map when zoomed out this far; the default is 240")
	_slider(grid, "Mouse sensitivity", "camera", "look_sensitivity", 0.25, 3.0, 0.05, func(v: float) -> String: return "%.2f×" % v)
	_check(grid, "Invert mouse look", "camera", "invert_y", "first person and middle-drag tilt")
	_slider(grid, "Add-ons' camera motion", "camera", "addon_motion", 0.0, 100.0, 5.0, func(v: float) -> String: return "%d%%" % int(v), false, true, "scales the bob, sway and shake add-ons put on the camera; 0% for none")


func _factorio() -> void:
	var grid := _grid()
	var found := Paths.find_factorio_exe(true)  # the player may have just installed it
	var exe := MenuKit.textbox(str(Settings.get_value("factorio", "executable")), "Automatic: " + (found if found != "" else "not found"))
	exe.custom_minimum_size.x = Kit.px(420)
	_on_text(exe, "factorio", "executable")
	_row(grid, "Factorio (factorio.exe or its folder)", exe)
	var in_use := Paths.factorio_exe()
	var ok := in_use != "" and FileAccess.file_exists(in_use)
	var status := Kit.label(("Using " + in_use) if ok else "Factorio not found: set the path above")
	status.add_theme_color_override("font_color", Kit.DISABLED_TEXT if ok else Kit.RED_TEXT)
	_row(grid, "", status)
	var graphics := Kit.label("")
	graphics.name = "factorio-graphics"
	_row(grid, "", graphics)
	# The graphics and sounds come from the data folder found at start-up (ItemIcons); a path
	# typed here takes effect after a restart, so say so as soon as it is entered.
	var show := func() -> void:
		var loaded := Paths.ItemIcons.factorio_data_dir()
		var exe_now := Paths.factorio_exe()
		var wanted := Paths.read_data_dir(exe_now) if exe_now != "" else ""
		if loaded != "" and (wanted == "" or wanted == loaded or not DirAccess.dir_exists_absolute(wanted)):
			graphics.text = "Graphics and sounds from " + loaded
			graphics.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		elif wanted != "" and DirAccess.dir_exists_absolute(wanted.path_join("base/graphics")):
			graphics.text = "Restart Zenith to load the graphics and sounds from " + wanted
			graphics.add_theme_color_override("font_color", Kit.RED_TEXT)
		else:
			graphics.text = "Factorio's graphics not found: set factorio.exe above"
			graphics.add_theme_color_override("font_color", Kit.RED_TEXT)
	show.call()
	exe.text_submitted.connect(func(_t: String) -> void: show.call())
	exe.focus_exited.connect(show)
	var data := MenuKit.textbox(str(Settings.get_value("factorio", "server_data")), Paths.default_server_data_dir())
	data.custom_minimum_size.x = Kit.px(420)
	_on_text(data, "factorio", "server_data")
	_row(grid, "Server data folder", data)
	var saves := MenuKit.textbox(str(Settings.get_value("factorio", "saves")), Paths.default_saves_dir())
	saves.custom_minimum_size.x = Kit.px(420)
	_on_text(saves, "factorio", "saves")
	_row(grid, "Saves folder", saves)
	var port := SpinBox.new()
	port.name = "factorio-port_base"
	port.min_value = 1024
	port.max_value = 65000
	port.value = int(Settings.get_value("factorio", "port_base"))
	port.custom_minimum_size = Kit.pxv(160, 28)
	port.value_changed.connect(func(v: float) -> void: Settings.set_value("factorio", "port_base", int(v)))
	_row(grid, "First port for servers", port, "four free ports from here up")
	# Factorio's own settings (its config.ini) are the defaults in the other tabs (factorio_settings.gd).
	var use := MenuKit.checkbox("", bool(Settings.get_value("factorio", "use_factorio_settings")))
	use.name = "factorio-use_factorio_settings"
	use.toggled.connect(func(on: bool) -> void:
		Sfx.play_ui("gui-checkbox-click")
		Settings.set_value("factorio", "use_factorio_settings", on)
		Settings.reload_factorio_settings()
		Settings.apply_window(get_tree().root)
		_open_tab.call_deferred(_tab))
	var config: String = load("res://scripts/player/factorio_keys.gd").config_path()
	var count := 0
	for section in Settings.factorio_values:
		count += (Settings.factorio_values[section] as Dictionary).size()
	var where := ("%d set there, from %s" % [count, config]) if config != "" else "Factorio's config.ini wasn't found"
	_row(grid, "Use the settings set in Factorio", use, "sound, graphics, interface, language; %s|The volumes, v-sync, full screen, clouds, smoke, decoratives, colour filter, UI scale, belt building, alt-mode arrows, minimap, autosave interval and language you set in Factorio's own Settings are the defaults here. A setting changed in Zenith still wins, and its Default puts Factorio's back. The language needs a restart. Read when Zenith starts and when this is switched: %s" % [where, where])
	_note("The server keeps its config, logs, mods and RCON password in the data folder, apart from your normal game, so both can run at once. Leave a field empty for the default.")


# --- rows ------------------------------------------------------------------------------------

func _heading(text: String) -> void:
	var l := Kit.label(text, "FHeading")
	_pane.add_child(l)


func _hbox() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", Kit.px(8))
	return h


func _grid() -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", Kit.px(24))
	grid.add_theme_constant_override("v_separation", Kit.px(8))
	_pane.add_child(grid)
	return grid


func _row(grid: GridContainer, text: String, control: Control, note := "") -> void:
	var l := Kit.label(text)
	l.custom_minimum_size.x = Kit.px(260)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	grid.add_child(l)
	# In a box, so every control keeps its own width instead of filling the column.
	var holder := _hbox()
	holder.add_child(control)
	grid.add_child(holder)
	control.set_meta(&"row_title", l)
	if not _row_inline_notes:
		var wrapped := wrap_tooltip(note)
		control.set_meta(&"base_tooltip", wrapped)
		if wrapped != "":
			l.tooltip_text = wrapped
			if control.tooltip_text == "":
				control.tooltip_text = wrapped
		return
	if note == "":
		control.set_meta(&"base_tooltip", "")
		return
	# "short|full": the short line shows, and a (?) after it gives the full text when hovered (owner).
	var short := note.get_slice("|", 0).strip_edges()
	var full := note.get_slice("|", 1).strip_edges() if note.contains("|") else ""
	var wrapped_full := wrap_tooltip(full)
	control.set_meta(&"base_tooltip", wrapped_full if wrapped_full != "" else wrap_tooltip(short))
	if wrapped_full != "":
		l.tooltip_text = wrapped_full
	var n := Kit.label(short)
	n.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	n.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	holder.add_child(n)
	if full != "":
		var more := Kit.label("(?)")
		more.name = "more"
		more.tooltip_text = wrapped_full
		more.mouse_filter = Control.MOUSE_FILTER_STOP
		more.mouse_default_cursor_shape = Control.CURSOR_HELP
		more.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		holder.add_child(more)


## Factorio's Steam launch options for Ctrl+F9 in Factorio (game_swap.gd).
static func launch_options() -> String:
	return GameSwap.launch_options()


func _note(text: String) -> void:
	var n := MenuKit.paragraph(text, 740)
	n.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	_pane.add_child(n)


func _check(grid: GridContainer, text: String, section: String, key: String, note := "", window := false) -> CheckBox:
	var c := MenuKit.checkbox("", bool(Settings.get_value(section, key)))
	c.name = section + "-" + key
	var on_toggled := func(on: bool) -> void:
		Sfx.play_ui("gui-checkbox-click")
		Settings.set_value(section, key, on)
		if window:
			Settings.apply_window(get_tree().root)
	c.toggled.connect(on_toggled)
	_row(grid, text, c, note)
	return c


## View distance's value in Factorio's warning colour: red past VIEW_RADIUS_SLIDER_MAX (10)
## when a custom higher value is typed; transparent (the theme's colour) up to it.
static func view_distance_tint(v: float) -> Color:
	if v > Settings.VIEW_RADIUS_SLIDER_MAX:
		return Kit.RED_TEXT
	return Color(0, 0, 0, 0)


## Distant horizon's value in Factorio's warning colour: red past DISTANT_HORIZON_SLIDER_MAX (256)
## when a custom higher value is typed; transparent (the theme's colour) up to it.
static func distant_horizon_tint(v: float) -> Color:
	if v > Settings.DISTANT_HORIZON_SLIDER_MAX:
		return Kit.RED_TEXT
	return Color(0, 0, 0, 0)


## Updates Entity distance and Belt item distance caps when View distance changes, clamping
## any higher value down to View distance in tiles.
static func _sync_distance_caps(vr: float, entity_ed: Dictionary, belt_ed: Dictionary) -> void:
	var view_tiles := float(maxi(32, int(roundi(vr)) * 32))
	var entries := [["entity_radius", entity_ed], ["belt_distance", belt_ed]]
	for entry: Array in entries:
		var key: String = entry[0]
		var ed: Dictionary = entry[1]
		if ed.is_empty():
			continue
		var cur := float((ed["get_value"] as Callable).call())
		(ed["set_max"] as Callable).call(view_tiles, view_tiles)
		if cur > view_tiles:
			Settings.set_value("graphics", key, int(view_tiles))


## `live`: applied while dragging (saved on release); otherwise set on release. `tint`, if given,
## colours the value's text for the value (a Color; a transparent one leaves the theme's).
func _slider(grid: GridContainer, text: String, section: String, key: String, from: float, to: float, step: float, fmt: Callable, window := false, live := false, note := "", tint := Callable(), display_scale := 1.0, allow_all := false, type_max := -1.0, on_committed := Callable()) -> Dictionary:
	var holder := _hbox()
	var initial := float(Settings.get_value(section, key))
	var max_typed := type_max if type_max >= to else to
	var s := MenuKit.slider(from, to, step, clampf(initial, from, to))
	s.name = section + "-" + key
	var as_value := func(v: float) -> Variant: return int(roundi(v)) if step >= 1.0 else v
	var on_changed := func(v: float) -> void:
		if live:
			Settings.set_value(section, key, as_value.call(v), false)
	s.value_changed.connect(on_changed)
	var on_commit := func(v: float) -> void:
		Sfx.play_ui("gui-slider")
		Settings.set_value(section, key, as_value.call(v))
		if window:
			Settings.apply_window(get_tree().root)
		if on_committed.is_valid():
			on_committed.call(v)
	var val_ed := make_slider_value_editor(s, fmt, on_commit, {
		"name": s.name + "-value",
		"display_scale": display_scale,
		"allow_all": allow_all,
		"tint": tint,
		"initial_value": initial,
		"type_max": max_typed,
	})
	var on_drag := func(_changed: bool) -> void:
		(val_ed["set_value"] as Callable).call(s.value)
		on_commit.call(s.value)
	s.drag_ended.connect(on_drag)
	if not _row_inline_notes and note != "":
		s.tooltip_text = wrap_tooltip(note)
	holder.add_child(s)
	holder.add_child(val_ed["box"])
	_row(grid, text, holder, note)
	return val_ed


func _dropdown(grid: GridContainer, text: String, section: String, key: String, items: Array, note := "", window := false) -> OptionButton:
	var o := MenuKit.dropdown(items, Settings.get_value(section, key))
	o.name = section + "-" + key
	var on_selected := func(i: int) -> void:
		Sfx.play_ui("gui-click")
		Settings.set_value(section, key, o.get_item_metadata(i))
		if window:
			Settings.apply_window(get_tree().root)
	o.item_selected.connect(on_selected)
	_row(grid, text, o, note)
	return o


## A dropdown (`_dropdown`, named section-key) shows the setting's value again, when it was changed
## elsewhere (F7's projection).
func _show_choice(section: String, key: String) -> void:
	if not is_instance_valid(_pane):
		return
	var o := _pane.find_child(section + "-" + key, true, false) as OptionButton
	if o == null:
		return
	var value = Settings.get_value(section, key)
	for i in o.item_count:
		if o.get_item_metadata(i) == value and o.selected != i:
			o.select(i)


## A row the look in use sets itself (Settings.look_overrides): greyed out, its tooltip saying where to
## change it instead. The value stays, for when the look goes.
func _grey_for_look(name: String, what: String, where: String) -> void:
	var c := _pane.find_child(name, true, false) as BaseButton
	if c == null:
		return
	var look := Settings.look_overrides(what)
	var title_lbl := c.get_meta(&"row_title", null) as Label
	if look == "":
		c.disabled = false
		var base_tip := str(c.get_meta(&"base_tooltip", ""))
		c.tooltip_text = base_tip
		if title_lbl != null:
			title_lbl.tooltip_text = base_tip
			title_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
		return
	c.disabled = true
	var tip := wrap_tooltip("Set by the %s look: %s." % [look, where])
	c.tooltip_text = tip
	if title_lbl != null:
		title_lbl.tooltip_text = tip
		title_lbl.mouse_filter = Control.MOUSE_FILTER_PASS


## Settings > Graphics > Upscaling's choices and tooltips (Settings.scaling_mode_for). FSR 2.2 is AMD's
## temporal upscaler: Godot 4.7 ships it as Viewport.SCALING_3D_MODE_FSR2, the upgraded drop-in
## successor of FSR 2.1 (so --upscaler=fsr2.1 is the same thing).
## AMD FSR 4.1, AMD FSR 3.1 and NVIDIA DLSS come from the vendors' runtimes (upscalers.gd): greyed out with the
## reason where this PC or build can't run them, never hidden.
const UPSCALER_ITEMS := [["Bilinear", "bilinear"], ["FSR 1.0", "fsr1"], ["FSR 2.2 (Temporal)", "fsr2"],
	["AMD FSR 4.1", "fsr4"], ["AMD FSR 3.1", "fsr3"], ["NVIDIA DLSS", "dlss"], ["Automatic", "auto"]]
const UPSCALER_NOTE := "Scales 3D rendering to your monitor. FSR 1.0 is fast spatial sharpening; FSR 2.2 is sharper temporal reconstruction (at 100% it runs as Native AA, lower Game render scaling below 100% for FPS gains; replaces TAA/MSAA, and falls back in orthographic views). AMD FSR 4.1 (Radeon RX 6000 or newer), AMD FSR 3.1 (any GPU) and NVIDIA DLSS need Direct3D 12 and their runtime; Automatic picks the best this PC can run."
const UPSCALER_SHARPNESS_NOTE := "Sharpening strength for FSR 1.0, FSR 2.2, AMD FSR 4.1 and AMD FSR 3.1."
const UPSCALER_QUALITY_NOTE := "Sets Game render scaling for AMD FSR 4.1, AMD FSR 3.1 and NVIDIA DLSS. Custom keeps the slider's own value."
const UPSCALER_NAMES := {"bilinear": "Bilinear", "fsr1": "FSR 1.0", "fsr2": "FSR 2.2", "fsr4": "AMD FSR 4.1", "fsr3": "AMD FSR 3.1",
	"dlss": "NVIDIA DLSS", "auto": "Automatic"}


## Upscaling's entries this PC or build can't run, greyed out, each saying why (Upscalers.unavailable_reason).
## The button says what runs instead when the saved choice can't run, or what Automatic picked.
func _grey_upscalers(o: OptionButton) -> void:
	if o == null:
		return
	for i in o.item_count:
		var why := Upscalers.unavailable_reason(str(o.get_item_metadata(i)))
		# Only the player's OK missing: not greyed, picking it asks first (_ask_dlss_consent).
		var asks := why == Upscalers.REASON_CONSENT
		o.set_item_disabled(i, why != "" and not asks)
		o.set_item_tooltip(i, wrap_tooltip(DLSS_ASKS_TIP if asks else (why + ".")) if why != "" else "")
	var choice := Settings.upscaler_choice()
	var now := Settings.upscaler_in_effect()
	var tip := str(o.get_meta(&"base_tooltip", ""))
	var why_not := Upscalers.unavailable_reason(choice)
	if why_not != "":
		tip = wrap_tooltip("%s: %s. %s is drawing instead; the choice stays for when it can run."
			% [UPSCALER_NAMES.get(choice, choice), why_not, UPSCALER_NAMES.get(now, now)])
	elif choice == "auto":
		tip = wrap_tooltip("Automatic picks %s on this PC. %s" % [UPSCALER_NAMES.get(now, now), UPSCALER_NOTE])
	o.tooltip_text = tip
	var title_lbl := o.get_meta(&"row_title", null) as Label
	if title_lbl != null:
		title_lbl.tooltip_text = tip


## NVIDIA DLSS's prompt (alt/dlss-s7c, the owner's decision: no hidden traffic). NVIDIA's graphics driver starts its
## own updater as soon as DLSS asks it anything, and Zenith can't turn that off, so the player is told and asked
## before anything of NVIDIA's is loaded (Upscalers.REASON_CONSENT, DlssHost). Plain words, both ways.
const DLSS_PROMPT_TITLE := "NVIDIA DLSS"
const DLSS_PROMPT_TEXT := "NVIDIA DLSS uses your NVIDIA graphics driver. When DLSS starts, the driver runs NVIDIA's own updater (nvngx_update.exe), which may connect to NVIDIA's servers to check for DLSS updates. Zenith sends nothing itself and can't turn this off.\n\nYou can withdraw this later under Settings > Graphics > Upscaling.\n\nUse DLSS?"
const DLSS_ASKS_TIP := "Asks first: NVIDIA's graphics driver runs NVIDIA's own updater (nvngx_update.exe) when DLSS starts, which may connect to NVIDIA's servers."
const DLSS_CONSENT_NOTE := "You allowed NVIDIA DLSS, so NVIDIA's graphics driver may run NVIDIA's updater (nvngx_update.exe), which may connect to NVIDIA's servers. Withdraw turns DLSS off (FSR 3.1 or FSR 2.2 draws instead) and Zenith asks again next time DLSS is picked. NVIDIA's files already loaded stay loaded until Zenith closes."

## The prompt while it is open (Esc cancels it).
var _dlss_prompt: CanvasLayer = null


## Upscaling's dropdown asks before NVIDIA DLSS (or Automatic, when it would pick DLSS) is saved without the player's
## OK; every other choice saves and applies as any dropdown does. Greys its entries (_grey_upscalers).
func _ask_before_dlss(o: OptionButton) -> void:
	if o == null:
		return
	for c: Dictionary in o.item_selected.get_connections():
		o.item_selected.disconnect(c["callable"])
	var on_selected := func(i: int) -> void:
		Sfx.play_ui("gui-click")
		var value := str(o.get_item_metadata(i))
		if Upscalers.needs_consent(value):
			_ask_dlss_consent(value)
			return
		Settings.set_value("graphics", "upscaler", value)
		Settings.apply_window(get_tree().root)
	o.item_selected.connect(on_selected)
	_grey_upscalers(o)


## The prompt: "Use DLSS" saves the OK and the choice; Cancel (or Esc) keeps the previous choice.
func _ask_dlss_consent(value: String) -> void:
	_close_dlss_prompt()
	var layer := CanvasLayer.new()
	layer.layer = 110  # over the menus and the game's UI
	layer.name = "DlssConsentPrompt"
	var o := MenuKit.overlay(0.35)
	layer.add_child(o)
	var parts := MenuKit.window(DLSS_PROMPT_TITLE)
	MenuKit.overlay_center(o).add_child(parts[0])
	var box: VBoxContainer = parts[1]
	box.add_child(MenuKit.paragraph(DLSS_PROMPT_TEXT, 460))
	var row: Array = MenuKit.dialog_buttons("Cancel", "Use DLSS")
	box.add_child(row[0])
	(row[1] as Button).name = "Cancel"
	(row[2] as Button).name = "UseDlss"
	(row[1] as Button).pressed.connect(_dlss_prompt_answer.bind(value, false))
	(row[2] as Button).pressed.connect(_dlss_prompt_answer.bind(value, true))
	add_child(layer)
	_dlss_prompt = layer


## The prompt's answer: yes saves the OK, then the choice (both applied); no puts the dropdown back.
func _dlss_prompt_answer(value: String, yes: bool) -> void:
	Sfx.play_ui("gui-click" if yes else "gui-back")
	_close_dlss_prompt()
	if yes:
		Settings.set_dlss_consent(true)
		Settings.set_value("graphics", "upscaler", value)
		Settings.apply_window(get_tree().root)
		_open_tab.call_deferred(_tab)  # the "NVIDIA updater: allowed" row shows
	else:
		_show_choice("graphics", "upscaler")
		_grey_upscaler_rows()


func _close_dlss_prompt() -> void:
	if is_instance_valid(_dlss_prompt):
		_dlss_prompt.queue_free()
	_dlss_prompt = null


## Under Upscaling, once the player said yes to NVIDIA's updater: "NVIDIA updater: allowed" and Withdraw, which
## clears the OK and turns DLSS off (the saved choice then falls back as any it can't run). Not there before the OK.
## With --dlss-consent on the command line the switch decides for the run: the button is greyed.
func _dlss_consent_row(parent: Container) -> void:
	if not Upscalers.dlss_consent():
		return
	var b := MenuKit.button("Withdraw")
	b.name = "graphics-dlss_consent"
	var from_switch := Upscalers.dlss_consent_from_switch()
	b.disabled = from_switch
	if from_switch:
		b.tooltip_text = wrap_tooltip("Set by --dlss-consent for this run.")
	b.pressed.connect(func() -> void:
		Sfx.play_ui("gui-click")
		Settings.set_dlss_consent(false)
		_open_tab.call_deferred(_tab))
	if parent is VBoxContainer:
		_card_row(parent as VBoxContainer, "NVIDIA updater: allowed", b, DLSS_CONSENT_NOTE)
	else:
		_row(parent as GridContainer, "NVIDIA updater: allowed", b, DLSS_CONSENT_NOTE)


## Upscaling quality (for AMD FSR 4.1, AMD FSR 3.1 and NVIDIA DLSS): a choice sets Game render scaling; it shows
## the one the slider matches, Custom when none does. It saves nothing of its own.
func _upscaling_quality(parent: Control, card: bool) -> OptionButton:
	var o := MenuKit.dropdown(Upscalers.quality_items(), Upscalers.quality_for_scale(float(Settings.get_value("graphics", "render_scale"))))
	o.name = "graphics-upscaler_quality"
	if card:
		o.fit_to_longest_item = false
		o.clip_text = true
		o.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		o.custom_minimum_size = Kit.pxv(140, 26)
		o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		o.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var on_selected := func(i: int) -> void:
		Sfx.play_ui("gui-click")
		var scale := Upscalers.quality_scale(str(o.get_item_metadata(i)))
		if scale > 0.0:
			Settings.set_value("graphics", "render_scale", scale)
			Settings.apply_window(get_tree().root)
			_open_tab.call_deferred(_tab)  # the Game render scaling slider shows it
	o.item_selected.connect(on_selected)
	if card:
		_card_row(parent as VBoxContainer, "Upscaling quality", o, UPSCALER_QUALITY_NOTE)
	else:
		_row(parent as GridContainer, "Upscaling quality", o, UPSCALER_QUALITY_NOTE)
	return o


## Upscaling's rows after a change: its greyed entries, Upscaling quality (only for AMD FSR 4.1/3.1, NVIDIA
## DLSS and Automatic; it follows the slider) and Upscaler sharpness (greyed under DLSS, which sharpens itself).
func _grey_upscaler_rows() -> void:
	if not is_instance_valid(_pane):
		return
	_grey_upscalers(_pane.find_child("graphics-upscaler", true, false) as OptionButton)
	var choice := Settings.upscaler_choice()
	var q := _pane.find_child("graphics-upscaler_quality", true, false) as OptionButton
	if q != null:
		var want := Upscalers.quality_for_scale(float(Settings.get_value("graphics", "render_scale")))
		for i in q.item_count:
			if str(q.get_item_metadata(i)) == want and q.selected != i:
				q.select(i)
		var off := not (Upscalers.VENDOR.has(choice) or choice == "auto")
		q.disabled = off
		var tip := wrap_tooltip("Only for AMD FSR 4.1, AMD FSR 3.1 and NVIDIA DLSS: use Game render scaling with the other upscalers." if off else UPSCALER_QUALITY_NOTE)
		q.tooltip_text = tip
		var title_lbl := q.get_meta(&"row_title", null) as Label
		if title_lbl != null:
			title_lbl.tooltip_text = tip
	var sharp := _pane.find_child("graphics-upscaler_sharpness", true, false) as HSlider
	if sharp != null:
		if not sharp.has_meta(&"own_tooltip"):
			sharp.set_meta(&"own_tooltip", sharp.tooltip_text)
		var dlss := Settings.upscaler_in_effect() == "dlss"
		sharp.editable = not dlss
		sharp.tooltip_text = wrap_tooltip("Off under NVIDIA DLSS: it does its own sharpening.") if dlss else str(sharp.get_meta(&"own_tooltip"))
	_show_used_scale()


## Beside Game render scaling: the scale NVIDIA DLSS really draws at when it fits the asked one to its mode's size
## (DlssHost.fit_scale, e.g. a Custom 80% drawn at DLSS Quality's 67%); hidden otherwise. DlssHost calls it again
## when it refits (DlssHost.SCALE_WATCHERS).
func _show_used_scale() -> void:
	if not is_instance_valid(_pane) or not is_inside_tree():
		return
	var slider := _pane.find_child("graphics-render_scale", true, false) as Control
	if slider == null or slider.get_parent() == null:
		return
	var holder := slider.get_parent()
	var lbl := holder.get_node_or_null("graphics-render_scale-used") as Label
	var root := get_tree().root
	var text := ""
	if DlssHost.running(root):
		var asked := clampf(float(Settings.get_value("graphics", "render_scale")), 0.25, 2.0)
		text = DlssHost.scale_note(asked, root.scaling_3d_scale / maxf(Settings.full_screen_ratio(), 0.0001))
	if text == "":
		if lbl != null:
			lbl.visible = false
		return
	if lbl == null:
		lbl = Label.new()
		lbl.name = "graphics-render_scale-used"
		lbl.mouse_filter = Control.MOUSE_FILTER_PASS
		lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		lbl.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		lbl.tooltip_text = wrap_tooltip("NVIDIA DLSS takes only its own render sizes for each quality mode, so the 3D world is drawn at this scale. The slider keeps the one you set for the other upscalers.")
		holder.add_child(lbl)
	lbl.text = text
	lbl.visible = true


## A temporal upscaler (FSR 2.2, AMD FSR 4.1/3.1 or NVIDIA DLSS, at Game render scaling 100% or below) does
## its own temporal anti-aliasing, so the Anti-aliasing row greys out while it is on, its tooltip saying why. The saved choice stays for when
## another upscaler (or a scale above 100%) is picked.
func _grey_aa_for_fsr2(o: OptionButton) -> void:
	if o == null:
		return
	var title_lbl := o.get_meta(&"row_title", null) as Label
	if not Settings.temporal_upscaler_wanted():
		o.disabled = false
		var base_tip := str(o.get_meta(&"base_tooltip", ""))
		o.tooltip_text = base_tip
		if title_lbl != null:
			title_lbl.tooltip_text = base_tip
		return
	o.disabled = true
	var now := Settings.upscaler_in_effect()
	var tip := wrap_tooltip("Off while %s is the upscaler: it does its own temporal anti-aliasing, replacing TAA, SMAA, FXAA and MSAA. Pick Bilinear or FSR 1.0 in Upscaling (or Game render scaling above 100%%) to use these again." % str(UPSCALER_NAMES.get(now, now)))
	o.tooltip_text = tip
	if title_lbl != null:
		title_lbl.tooltip_text = tip


## Under a look that draws its own passes the MSAA choices are greyed out, each saying why
## (Settings.MSAA_UNDER_LOOK); a saved MSAA was switched to SMAA by then (Settings.switch_msaa_for_look).
func _grey_msaa(o: OptionButton) -> void:
	var off := Settings.look_draws_passes()
	var tip := wrap_tooltip("Off under the look in use: its full-screen passes read a depth MSAA blurs at every edge. SMAA is drawn instead.")
	for i in o.item_count:
		if Settings.MSAA.has(str(o.get_item_metadata(i))):
			o.set_item_disabled(i, off)
			o.set_item_tooltip(i, tip if off else "")


func _ui_check(grid: GridContainer, text: String, key: String, note := "") -> void:
	var ui = UiSettings.shared()
	var c := MenuKit.checkbox("", bool(ui.get_value(key)))
	c.name = key.replace("/", "-")
	var on_toggled := func(on: bool) -> void:
		Sfx.play_ui("gui-checkbox-click")
		ui.set_value(key, on)
	c.toggled.connect(on_toggled)
	_row(grid, text, c, note)


func _ui_slider(grid: GridContainer, text: String, key: String, from: float, to: float, step: float, fmt: Callable) -> void:
	var ui = UiSettings.shared()
	var holder := _hbox()
	var s := MenuKit.slider(from, to, step, float(ui.get_value(key)))
	s.name = key.replace("/", "-")
	var on_changed := func(v: float) -> void: ui.set_value(key, v, false)
	s.value_changed.connect(on_changed)
	var on_commit := func(v: float) -> void:
		Sfx.play_ui("gui-slider")
		ui.set_value(key, v)
	var on_drag := func(_changed: bool) -> void: on_commit.call(s.value)
	s.drag_ended.connect(on_drag)
	var val_ed := make_slider_value_editor(s, fmt, on_commit, {
		"name": s.name + "-value",
	})
	holder.add_child(s)
	holder.add_child(val_ed["box"])
	_row(grid, text, holder)


func _on_text(e: LineEdit, section: String, key: String) -> void:
	e.name = section + "-" + key
	var commit := func() -> void:
		if str(Settings.get_value(section, key)) != e.text.strip_edges():
			Settings.set_value(section, key, e.text.strip_edges())
	e.text_submitted.connect(func(_t: String) -> void: commit.call())
	e.focus_exited.connect(commit)


# --- tooltips & editable slider values -------------------------------------------------------

## Extracts the clean description from "short|full" strings and word-wraps to max_chars per line.
static func wrap_tooltip(text: String, max_chars := 46) -> String:
	var s := text.strip_edges()
	if s == "":
		return ""
	if s.contains("|"):
		var short := s.get_slice("|", 0).strip_edges()
		var full := s.get_slice("|", 1).strip_edges()
		s = full if full != "" else short
	if s == "":
		return ""
	var out: PackedStringArray = []
	for para in s.split("\n"):
		var clean := para.strip_edges()
		if clean == "":
			continue
		var line := ""
		for word in clean.split(" ", false):
			if line == "":
				line = word
			elif line.length() + 1 + word.length() <= max_chars:
				line += " " + word
			else:
				out.append(line)
				line = word
		if line != "":
			out.append(line)
	return "\n".join(out)


static func _format_numeric(v: float, step: float) -> String:
	var clean_v := 0.0 if absf(v) < 0.000001 else v
	var decs := 0
	if step > 0.0:
		while decs < 4 and absf(step * pow(10.0, decs) - roundf(step * pow(10.0, decs))) > 0.001:
			decs += 1
	else:
		decs = 3
	if decs == 0:
		return str(roundi(clean_v))
	var txt := ("%." + str(decs) + "f") % clean_v
	if txt.contains("."):
		txt = txt.rstrip("0").rstrip(".")
	return "0" if txt == "-0" or txt == "" else txt


static func _parse_slider_input(raw: String, from: float, to: float, step: float, display_scale: float, allow_all: bool) -> float:
	var lower := raw.strip_edges().to_lower()
	if lower == "":
		return NAN
	if from <= 0.0 and (lower == "off" or lower == "icons" or lower == "icons only"):
		return from
	if allow_all and lower == "all":
		return to
	var cleaned := lower
	var suffixes := ["px per tile", "chunks", "chunk", "tiles", "tile", "°/s", "ms", "%", "°", "×", "px", "x", "s"]
	var stripped := true
	while stripped:
		stripped = false
		cleaned = cleaned.strip_edges()
		for suf in suffixes:
			if cleaned.ends_with(suf):
				cleaned = cleaned.substr(0, cleaned.length() - suf.length()).strip_edges()
				stripped = true
				break
	cleaned = cleaned.replace(",", "")
	if cleaned == "" or not cleaned.is_valid_float():
		return NAN
	var scale := display_scale if display_scale > 0.0 else 1.0
	var val := clampf(cleaned.to_float() / scale, from, to)
	if step > 0.0:
		val = clampf(from + snappedf(val - from, step), from, to)
	return val


static func addon_unit_scaled(def: Dictionary) -> bool:
	var unit := str(def.get("unit", ""))
	var smax := float(def.get("max", 100.0))
	var sstep := float(def.get("step", 1.0))
	return unit == "%" and smax <= 1.0 and sstep < 1.0


static func addon_number_text(v: Variant, def: Dictionary) -> String:
	var f := float(v)
	var step := float(def.get("step", 1.0))
	var unit := str(def.get("unit", ""))
	if addon_unit_scaled(def):
		return "%d%%" % roundi(f * 100.0)
	var snap := maxf(step, 0.001) if step > 0.0 else 0.001
	var text := _format_numeric(snappedf(f, snap), step)
	if unit == "":
		return text
	return text + (unit if unit.begins_with("°") or unit.begins_with("×") or unit.begins_with("%") else " " + unit)


## Builds a compact clickable value Button + hidden LineEdit for click-to-type editing on any slider.
static func make_slider_value_editor(s: HSlider, fmt: Callable, commit_cb: Callable, options := {}) -> Dictionary:
	var val_name := str(options.get("name", ""))
	var display_scale := float(options.get("display_scale", 1.0))
	var allow_all := bool(options.get("allow_all", false))
	var tint: Callable = options.get("tint", Callable())
	var font_size := int(options.get("font_size", Kit.px(14)))
	var min_width := int(options.get("min_width", 0))

	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if min_width > 0:
		box.custom_minimum_size.x = min_width

	var btn := Button.new()
	if val_name != "":
		btn.name = val_name
	btn.flat = true
	btn.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_IBEAM
	btn.tooltip_text = "Click to type a value"
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if min_width > 0:
		btn.custom_minimum_size.x = min_width
	var empty := StyleBoxEmpty.new()
	empty.content_margin_left = Kit.px(3)
	empty.content_margin_right = Kit.px(2)
	empty.content_margin_top = 0
	empty.content_margin_bottom = 0
	for sb in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		btn.add_theme_stylebox_override(sb, empty)
	btn.add_theme_font_override("font", Kit.font("regular"))
	btn.add_theme_font_size_override("font_size", font_size)
	btn.add_theme_color_override("font_focus_color", Kit.WHITE)
	btn.add_theme_color_override("font_disabled_color", Kit.DISABLED_TEXT)

	var edit := LineEdit.new()
	edit.name = (val_name + "-edit") if val_name != "" else "value-edit"
	edit.custom_minimum_size = Kit.pxv(68, 22)
	if min_width > 0:
		edit.custom_minimum_size.x = maxi(Kit.px(68), min_width)
	edit.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	edit.select_all_on_focus = true
	edit.visible = false
	edit.add_theme_font_size_override("font_size", font_size)
	edit.tooltip_text = wrap_tooltip("Type a number and press Enter, or Esc to cancel.")

	var paint := func(v: float) -> void:
		var tinted := false
		if tint.is_valid():
			var c: Color = tint.call(v)
			if c.a > 0.0:
				tinted = true
				btn.add_theme_color_override("font_color", c)
				btn.add_theme_color_override("font_hover_color", c.lightened(0.15))
				btn.add_theme_color_override("font_pressed_color", c)
		if not tinted:
			btn.add_theme_color_override("font_color", Kit.WHITE)
			btn.add_theme_color_override("font_hover_color", Kit.ORANGE)
			btn.add_theme_color_override("font_pressed_color", Kit.ORANGE)

	var type_max := float(options.get("type_max", s.max_value))
	var init_val := float(options.get("initial_value", s.value))
	var state := {
		"committing": false,
		"cancelled": false,
		"syncing": false,
		"type_max": type_max,
		"value": clampf(init_val, s.min_value, maxf(s.max_value, type_max)),
	}

	var refresh := func() -> void:
		var v := float(state["value"])
		btn.text = str(fmt.call(v))
		paint.call(v)

	refresh.call()
	var on_slider_changed := func(_v: float) -> void:
		if bool(state["syncing"]):
			return
		state["value"] = s.value
		refresh.call()
	s.value_changed.connect(on_slider_changed)

	var set_value := func(v: float) -> void:
		var hi := maxf(s.max_value, float(state["type_max"]))
		var clamped := clampf(v, s.min_value, hi)
		state["value"] = clamped
		state["syncing"] = true
		s.value = clampf(clamped, s.min_value, s.max_value)
		state["syncing"] = false
		refresh.call()

	var set_max := func(new_max: float, new_type_max := -1.0) -> void:
		s.max_value = new_max
		state["type_max"] = new_type_max if new_type_max >= 0.0 else new_max
		var hi := maxf(s.max_value, float(state["type_max"]))
		if float(state["value"]) > hi:
			set_value.call(hi)

	var get_value := func() -> float:
		return float(state["value"])

	var on_btn_pressed := func() -> void:
		if not s.editable:
			return
		state["committing"] = false
		state["cancelled"] = false
		btn.visible = false
		edit.text = _format_numeric(float(state["value"]) * display_scale, s.step * display_scale)
		edit.visible = true
		edit.grab_focus()
		edit.select_all()
	btn.pressed.connect(on_btn_pressed)

	var finish_edit := func(apply: bool, force_commit: bool) -> void:
		if bool(state["committing"]):
			return
		state["committing"] = true
		if not is_instance_valid(edit) or not is_instance_valid(btn) or not is_instance_valid(s):
			return
		edit.visible = false
		btn.visible = true
		if not apply or bool(state["cancelled"]):
			refresh.call()
			return
		var hi := maxf(s.max_value, float(state["type_max"]))
		var parsed := _parse_slider_input(edit.text, s.min_value, hi, s.step, display_scale, allow_all)
		if not is_nan(parsed):
			var changed := not is_equal_approx(float(state["value"]), parsed)
			set_value.call(parsed)
			if (changed or force_commit) and commit_cb.is_valid():
				commit_cb.call(parsed)
		else:
			refresh.call()

	var on_submitted := func(_t: String) -> void:
		finish_edit.call(true, true)
	edit.text_submitted.connect(on_submitted)

	var on_focus_exited := func() -> void:
		finish_edit.call(true, false)
	edit.focus_exited.connect(on_focus_exited)

	var on_edit_input := func(ev: InputEvent) -> void:
		var key := ev as InputEventKey
		if key != null and key.pressed and not key.echo and key.physical_keycode == KEY_ESCAPE:
			state["cancelled"] = true
			edit.accept_event()
			var vp := edit.get_viewport()
			if vp != null:
				vp.set_input_as_handled()
			finish_edit.call(false, false)
	edit.gui_input.connect(on_edit_input)

	box.add_child(btn)
	box.add_child(edit)
	return {"box": box, "button": btn, "edit": edit, "slider": s, "refresh": refresh, "set_value": set_value, "get_value": get_value, "set_max": set_max}


# --- graphics cards --------------------------------------------------------------------------

func _category_card(col: VBoxContainer, id: String, title: String) -> Dictionary:
	var frame := Kit.panel("FDeepFrame")
	frame.name = "graphics-cat-" + id
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(frame)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 0)
	frame.add_child(outer)

	var header := Kit.panel("FSubheader")
	outer.add_child(header)
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", Kit.px(6))
	header.add_child(hbox)
	var heading := Kit.label(title, "FHeading")
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	heading.clip_text = true
	heading.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	hbox.add_child(heading)

	var more_btn := Button.new()
	more_btn.name = "graphics-more-" + id
	more_btn.toggle_mode = true
	more_btn.focus_mode = Control.FOCUS_NONE
	more_btn.custom_minimum_size = Kit.pxv(78, 22)
	more_btn.add_theme_font_size_override("font_size", Kit.px(12))
	more_btn.visible = false
	hbox.add_child(more_btn)

	var body_pad := MarginContainer.new()
	for side in ["left", "right"]:
		body_pad.add_theme_constant_override("margin_" + side, Kit.px(10))
	for side in ["top", "bottom"]:
		body_pad.add_theme_constant_override("margin_" + side, Kit.px(8))
	outer.add_child(body_pad)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", Kit.px(7))
	body_pad.add_child(body)

	var primary := VBoxContainer.new()
	primary.name = "graphics-primary-" + id
	primary.add_theme_constant_override("separation", Kit.px(6))
	body.add_child(primary)

	var adv_wrap := VBoxContainer.new()
	adv_wrap.name = "graphics-advanced-" + id
	adv_wrap.add_theme_constant_override("separation", Kit.px(6))
	adv_wrap.visible = false
	adv_wrap.set_meta("graphics_more_category", id)
	body.add_child(adv_wrap)

	var sep := HSeparator.new()
	sep.modulate = Color(1, 1, 1, 0.35)
	adv_wrap.add_child(sep)
	var sub := Kit.label("Fine-tune")
	sub.add_theme_font_size_override("font_size", Kit.px(11))
	sub.add_theme_color_override("font_color", Kit.CAPTION)
	sub.modulate = Color(1, 1, 1, 0.85)
	adv_wrap.add_child(sub)

	var advanced := VBoxContainer.new()
	advanced.add_theme_constant_override("separation", Kit.px(6))
	adv_wrap.add_child(advanced)

	return {
		"id": id,
		"title": title,
		"frame": frame,
		"button": more_btn,
		"primary": primary,
		"advanced": advanced,
		"wrap": adv_wrap,
	}


func _finish_category_card(card: Dictionary) -> void:
	var adv_box: VBoxContainer = card["advanced"]
	var count := adv_box.get_child_count()
	var btn: Button = card["button"]
	var wrap: VBoxContainer = card["wrap"]
	if count <= 0:
		btn.visible = false
		wrap.visible = false
		return
	var id: String = card["id"]
	var title: String = card["title"]
	var expanded := bool(_graphics_expanded.get(id, false))
	btn.visible = true
	btn.tooltip_text = wrap_tooltip("Show or hide more granular %s settings." % title.to_lower())
	_graphics_cards[id] = {"button": btn, "wrap": wrap, "count": count}
	wrap.visible = expanded
	btn.set_pressed_no_signal(expanded)
	btn.text = "Less" if expanded else "More (%d)" % count
	var on_more := func(on: bool) -> void:
		Sfx.play_ui("gui-click")
		_set_graphics_category_expanded(id, on)
	btn.toggled.connect(on_more)


func _set_graphics_category_expanded(id: String, on: bool) -> void:
	_graphics_expanded[id] = on
	var entry: Dictionary = _graphics_cards.get(id, {})
	if entry.is_empty():
		return
	var wrap: VBoxContainer = entry["wrap"]
	var btn: Button = entry["button"]
	var count := int(entry["count"])
	wrap.visible = on
	btn.set_pressed_no_signal(on)
	btn.text = "Less" if on else "More (%d)" % count


func _card_row(parent: VBoxContainer, text: String, control: Control, note := "", value_ctrl: Control = null) -> void:
	var wrapped := wrap_tooltip(note)
	if control is CheckBox and value_ctrl == null:
		var line := HBoxContainer.new()
		line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_theme_constant_override("separation", Kit.px(6))
		var l := Kit.label(text)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 0
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		if wrapped != "":
			l.tooltip_text = wrapped
			if control.tooltip_text == "":
				control.tooltip_text = wrapped
		control.set_meta(&"row_title", l)
		control.set_meta(&"base_tooltip", wrapped)
		line.add_child(l)
		var holder := HBoxContainer.new()
		holder.add_theme_constant_override("separation", Kit.px(6))
		holder.add_child(control)
		line.add_child(holder)
		parent.add_child(line)
		return

	var item := VBoxContainer.new()
	item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	item.add_theme_constant_override("separation", Kit.px(2))
	var head := HBoxContainer.new()
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_theme_constant_override("separation", Kit.px(6))
	var l := Kit.label(text)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if value_ctrl != null:
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	else:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 0
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	if wrapped != "":
		l.tooltip_text = wrapped
		if control.tooltip_text == "":
			control.tooltip_text = wrapped
	control.set_meta(&"row_title", l)
	control.set_meta(&"base_tooltip", wrapped)
	head.add_child(l)
	if value_ctrl != null:
		head.add_child(value_ctrl)
	item.add_child(head)

	var holder := HBoxContainer.new()
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.add_theme_constant_override("separation", Kit.px(6))
	holder.add_child(control)
	item.add_child(holder)
	parent.add_child(item)


func _card_check(parent: VBoxContainer, text: String, section: String, key: String, note := "", window := false) -> CheckBox:
	var c := MenuKit.checkbox("", bool(Settings.get_value(section, key)))
	c.name = section + "-" + key
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var on_toggled := func(on: bool) -> void:
		Sfx.play_ui("gui-checkbox-click")
		Settings.set_value(section, key, on)
		if window:
			Settings.apply_window(get_tree().root)
	c.toggled.connect(on_toggled)
	_card_row(parent, text, c, note)
	return c


func _card_slider(parent: VBoxContainer, text: String, section: String, key: String, from: float, to: float, step: float, fmt: Callable, window := false, live := false, note := "", tint := Callable(), display_scale := 1.0, allow_all := false, type_max := -1.0, on_committed := Callable()) -> Dictionary:
	var initial := float(Settings.get_value(section, key))
	var max_typed := type_max if type_max >= to else to
	var s := MenuKit.slider(from, to, step, clampf(initial, from, to))
	s.name = section + "-" + key
	s.custom_minimum_size = Kit.pxv(160, 20)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var as_value := func(v: float) -> Variant: return int(roundi(v)) if step >= 1.0 else v
	var on_changed := func(v: float) -> void:
		if live:
			Settings.set_value(section, key, as_value.call(v), false)
	s.value_changed.connect(on_changed)
	var on_commit := func(v: float) -> void:
		Sfx.play_ui("gui-slider")
		Settings.set_value(section, key, as_value.call(v))
		if window:
			Settings.apply_window(get_tree().root)
		if on_committed.is_valid():
			on_committed.call(v)
	var val_ed := make_slider_value_editor(s, fmt, on_commit, {
		"name": s.name + "-value",
		"display_scale": display_scale,
		"allow_all": allow_all,
		"tint": tint,
		"font_size": Kit.px(12),
		"initial_value": initial,
		"type_max": max_typed,
	})
	var on_drag_end := func(_changed: bool) -> void:
		(val_ed["set_value"] as Callable).call(s.value)
		on_commit.call(s.value)
	s.drag_ended.connect(on_drag_end)
	_card_row(parent, text, s, note, val_ed["box"] as Control)
	return val_ed


func _card_dropdown(parent: VBoxContainer, text: String, section: String, key: String, items: Array, note := "", window := false) -> OptionButton:
	var o := MenuKit.dropdown(items, Settings.get_value(section, key))
	o.name = section + "-" + key
	o.fit_to_longest_item = false
	o.clip_text = true
	o.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	o.custom_minimum_size = Kit.pxv(140, 26)
	o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	o.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var on_selected := func(i: int) -> void:
		Sfx.play_ui("gui-click")
		Settings.set_value(section, key, o.get_item_metadata(i))
		if window:
			Settings.apply_window(get_tree().root)
	o.item_selected.connect(on_selected)
	_card_row(parent, text, o, note)
	return o


## Settings > Graphics > Renderer (Windows only): Godot's rendering driver for the next start.
const RENDERER_ITEMS := [["Direct3D 12", "d3d12"], ["Vulkan", "vulkan"]]


func _renderer_note() -> String:
	var now := RenderingServer.get_current_rendering_driver_name()
	var names := {"d3d12": "Direct3D 12", "vulkan": "Vulkan", "opengl3": "OpenGL", "dummy": "none (headless)"}
	return ("Direct3D 12 (default) used about half the memory of Vulkan on big bases; Vulkan draws as before 0.3.1. "
		+ "Falls back to Vulkan if Direct3D 12 can't start. Drawing now with: %s. Needs restart.") % str(names.get(now, now))


func _addons_host() -> Variant:
	if addons != null:
		return addons
	var tree := get_tree()
	if tree == null or tree.root == null:
		return null
	var main := tree.root.get_node_or_null("Main")
	return main.get("addons") if main != null else null


func _refresh_look_overrides() -> void:
	if not is_instance_valid(_pane):
		return
	var legacy := use_old_graphics_layout()
	_grey_for_look("graphics-clouds", "clouds", "use its Clouds slider in the Add-ons menu" if legacy else "use its Clouds slider below")
	_grey_for_look("graphics-ssao", "ssao", "use its Ambient occlusion toggle in the Add-ons menu" if legacy else "use its Ambient occlusion toggle below")
	var aa := _pane.find_child("graphics-antialiasing", true, false) as OptionButton
	if aa != null:
		_grey_msaa(aa)
		_grey_aa_for_fsr2(aa)
	_grey_upscaler_rows()


static func _slug(text: String) -> String:
	var s := text.strip_edges().to_lower()
	var out := ""
	for i in s.length():
		var ch := s.substr(i, 1)
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "-" or ch == "_":
			out += ch
		elif ch == " " or ch == "/" or ch == ":":
			out += "_"
	return out if out != "" else "general"


func _add_shader_cards() -> void:
	var look_id := str(Settings.get_value("graphics", "look"))
	var spec: Dictionary = Looks.looks.get(look_id, {})
	var owner_id := str(spec.get("owner", ""))
	if owner_id == "":
		return
	var host = _addons_host()
	if host == null:
		return
	var addon_list: Variant = host if host is Array else host.get("addons")
	if not addon_list is Array:
		return
	var found_m: Dictionary = {}
	for item in (addon_list as Array):
		if item is Dictionary and str(item.get("id", "")) == owner_id:
			found_m = item
			break
	if found_m.is_empty():
		return
	var api = found_m.get("object", found_m.get("api", null))
	if api == null or api.get("settings") == null:
		return
	var defs: Array = api.settings.list()
	if defs.is_empty():
		return

	var look_name := str(spec.get("name", found_m.get("name", owner_id)))
	var groups: Array[Dictionary] = []
	var group_idx := {}
	for item in defs:
		if not item is Dictionary:
			continue
		var def: Dictionary = item
		var sec_name := str(def.get("section", "")).strip_edges()
		if sec_name == "":
			sec_name = look_name
		if not group_idx.has(sec_name):
			group_idx[sec_name] = groups.size()
			groups.append({"name": sec_name, "defs": []})
		var idx := int(group_idx[sec_name])
		(groups[idx]["defs"] as Array).append(def)
	if groups.is_empty():
		return

	var row_count := ceili(groups.size() / 3.0)
	var group_pos := 0
	for row_i in row_count:
		var shader_cols := HBoxContainer.new()
		shader_cols.name = "GraphicsShaderColumns" if row_i == 0 else "GraphicsShaderColumns%d" % row_i
		shader_cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		shader_cols.add_theme_constant_override("separation", Kit.px(10))
		_pane.add_child(shader_cols)
		var row_cols: Array[VBoxContainer] = []
		for col_i in 3:
			var col := VBoxContainer.new()
			col.name = "GraphicsShaderCol%d" % (row_i * 3 + col_i)
			col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			col.size_flags_stretch_ratio = 1.0
			col.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			col.add_theme_constant_override("separation", Kit.px(10))
			shader_cols.add_child(col)
			row_cols.append(col)
		for col_i in 3:
			if group_pos >= groups.size():
				break
			var group: Dictionary = groups[group_pos]
			group_pos += 1
			_build_shader_card(row_cols[col_i], owner_id, look_name, api, group)


func _build_shader_card(col: VBoxContainer, owner_id: String, look_name: String, api, group: Dictionary) -> void:
	var sec_name := str(group["name"])
	var sec_defs: Array = group["defs"]
	var sec_key := _slug(sec_name)
	var card_title := sec_name if sec_name.to_lower() == look_name.to_lower() or sec_name.to_lower().begins_with(look_name.to_lower()) else "%s: %s" % [look_name, sec_name]
	var card := _category_card(col, "shader-%s-%s" % [owner_id, sec_key], card_title)
	var sp: VBoxContainer = card["primary"]

	var reset_btn := MenuKit.button("Reset defaults")
	reset_btn.name = "graphics-shader-reset-%s-%s" % [owner_id, sec_key]
	reset_btn.custom_minimum_size = Kit.pxv(120, 24)
	reset_btn.add_theme_font_size_override("font_size", Kit.px(12))
	reset_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	reset_btn.tooltip_text = wrap_tooltip("Restore defaults for %s." % card_title)

	var update_reset := func() -> void:
		var all_default := true
		for item in sec_defs:
			var d: Dictionary = item
			if not api.settings.is_default(str(d["id"])):
				all_default = false
				break
		reset_btn.disabled = all_default

	for item in sec_defs:
		var def: Dictionary = item
		var sid := str(def["id"])
		var label_text := str(def["label"])
		var note := str(def.get("note", ""))
		var ctrl_name := "shader-%s-%s" % [owner_id, sid]
		var val = api.settings.value(sid)
		match str(def["type"]):
			"bool":
				var c := MenuKit.checkbox("", bool(val))
				c.name = ctrl_name
				c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				var on_toggled := func(on: bool) -> void:
					Sfx.play_ui("gui-checkbox-click")
					api.settings.set_value(sid, on)
					update_reset.call()
					_refresh_look_overrides()
				c.toggled.connect(on_toggled)
				_card_row(sp, label_text, c, note)
			"number":
				var smin := float(def["min"])
				var smax := float(def["max"])
				var raw_step := float(def["step"])
				var sstep := raw_step if raw_step > 0.0 else 0.001
				var s := MenuKit.slider(smin, smax, sstep, float(val))
				s.name = ctrl_name
				s.custom_minimum_size = Kit.pxv(160, 20)
				s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				var d_scale := 100.0 if addon_unit_scaled(def) else 1.0
				var num_fmt := func(v: float) -> String: return addon_number_text(v, def)
				var on_num_changed := func(v: float) -> void:
					api.settings.set_value(sid, v, false)
					update_reset.call()
					_refresh_look_overrides()
				s.value_changed.connect(on_num_changed)
				var on_num_commit := func(v: float) -> void:
					Sfx.play_ui("gui-slider")
					api.settings.set_value(sid, v, true)
					update_reset.call()
					_refresh_look_overrides()
				var on_num_drag := func(_changed: bool) -> void: on_num_commit.call(s.value)
				s.drag_ended.connect(on_num_drag)
				var val_ed := make_slider_value_editor(s, num_fmt, on_num_commit, {
					"name": ctrl_name + "-value",
					"display_scale": d_scale,
					"font_size": Kit.px(12),
				})
				_card_row(sp, label_text, s, note, val_ed["box"] as Control)
			"choice":
				var o := MenuKit.dropdown(def["choices"], val)
				o.name = ctrl_name
				o.fit_to_longest_item = false
				o.clip_text = true
				o.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
				o.custom_minimum_size = Kit.pxv(140, 26)
				o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				o.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				var on_choice := func(i: int) -> void:
					Sfx.play_ui("gui-click")
					api.settings.set_value(sid, o.get_item_metadata(i))
					update_reset.call()
					_refresh_look_overrides()
				o.item_selected.connect(on_choice)
				_card_row(sp, label_text, o, note)
			"text":
				var e := MenuKit.textbox(str(val), str(def.get("placeholder", "")))
				e.name = ctrl_name
				e.custom_minimum_size = Kit.pxv(140, 26)
				e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				e.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				var commit_text := func(t: String) -> void:
					if str(api.settings.value(sid)) != t:
						api.settings.set_value(sid, t)
						update_reset.call()
				var on_submit := func(t: String) -> void: commit_text.call(t)
				var on_focus := func() -> void: commit_text.call(e.text)
				e.text_submitted.connect(on_submit)
				e.focus_exited.connect(on_focus)
				_card_row(sp, label_text, e, note)

	var reset_row := HBoxContainer.new()
	reset_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_row.alignment = BoxContainer.ALIGNMENT_END
	reset_row.add_child(reset_btn)
	var on_reset := func() -> void:
		Sfx.play_ui("gui-click")
		for item in sec_defs:
			var d: Dictionary = item
			api.settings.reset(str(d["id"]))
		_open_tab.call_deferred(_tab)
	reset_btn.pressed.connect(on_reset)
	update_reset.call()
	sp.add_child(reset_row)
	_finish_category_card(card)
