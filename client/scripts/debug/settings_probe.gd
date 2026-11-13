extends Node
## --settings-probe=<folder>[@seconds]: walks every row of the Settings window in a running game, the
## way a player changes it (a dropdown's item picked, a box ticked, a slider let go), and reads back
## what the setting should have changed: the property in the game, the value in settings.cfg. Visible
## ones get a screenshot before and after (<folder>/<key>-<value>.png). Each setting goes back to what
## it was before the next. Writes <folder>/report.txt (PASS / FAIL / NOTE lines) and quits.
##
## --settings-probe-restart: then writes a set of values that differ from the defaults into the
## settings file and quits; the next run with --settings-probe-verify reads each in the game after the
## restart (<folder>/verify.txt), the settings that apply "after a restart" among them.
##
## Run against the mock or a server, with a settings file and user folder of the probe's own
## (APPDATA pointed elsewhere, --settings-file=), never the player's.

const Settings := preload("res://scripts/menu/settings.gd")
const SettingsWindow := preload("res://scripts/menu/settings_window.gd")
const FxSettings := preload("res://scripts/fx/fx_settings.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ContactShade := preload("res://scripts/world/contact_shade.gd")
const SpriteStandins := preload("res://scripts/world/sprite_standins.gd")
const UiSettings := preload("res://scripts/ui/ui_settings.gd")
const Kit := preload("res://scripts/ui/factorio/kit.gd")

var main: Node
var out_dir := ""
var seconds := 25.0

var _lines := PackedStringArray()
var _fails := 0
var _window: Control
var _layer: CanvasLayer


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	await get_tree().create_timer(seconds).timeout
	if "--settings-probe-verify" in OS.get_cmdline_user_args():
		await _verify()
		_write("verify.txt")
		get_tree().quit()
		return
	# Close enough for ambient occlusion and contact shading to show (ao_zoom.gd fades them out).
	if main.rig != null:
		main.rig.distance = 14.0
		main.rig.set("_distance_goal", 14.0)
	await _frames(60)
	await _walk()
	_write("report.txt")
	if "--settings-probe-restart" in OS.get_cmdline_user_args():
		_write_restart_values()
	get_tree().quit()


func _write(file: String) -> void:
	var f := FileAccess.open(out_dir.path_join(file), FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines) + "\nFAILS: %d\n" % _fails)
	print("settings probe: %d lines, %d failed -> %s" % [_lines.size(), _fails, out_dir.path_join(file)])


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	if _layer != null:
		_layer.visible = false
	await _frames(30)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out_dir.path_join(name + ".png"))
	if _layer != null:
		_layer.visible = true


func _check(label: String, ok: bool, detail := "") -> void:
	if not ok:
		_fails += 1
	_lines.append("%s %s%s" % ["PASS" if ok else "FAIL", label, (": " + detail) if detail != "" else ""])


func _note(text: String) -> void:
	_lines.append("NOTE " + text)


# --- the window ----------------------------------------------------------------------------------

func _open(tab: String) -> void:
	if _layer == null:
		_layer = CanvasLayer.new()
		_layer.layer = 90
		add_child(_layer)
	if _window != null and is_instance_valid(_window):
		_window.queue_free()
		await get_tree().process_frame
	_window = SettingsWindow.new()
	_window.in_game = true
	_window.start_tab = tab
	_layer.add_child(_window)
	await _frames(2)


func _control(name: String) -> Control:
	return _window.find_child(name, true, false) as Control


## Changes a control as a player would; false when the window has no such control or value.
func _set_control(name: String, value: Variant) -> bool:
	var c := _control(name)
	if c == null:
		return false
	if c is OptionButton:
		var o := c as OptionButton
		for i in o.item_count:
			if str(o.get_item_metadata(i)) == str(value):
				o.select(i)
				o.item_selected.emit(i)
				return true
		return false
	if c is CheckBox:
		(c as CheckBox).button_pressed = bool(value)  # emits toggled
		return true
	if c is HSlider:
		var s := c as HSlider
		s.value = float(value)
		s.drag_ended.emit(true)
		return true
	return false


## One row: changes it through the window, waits, checks `read` gives `want` (a Callable taking the
## read value, or a value) and that settings.cfg has it; `shot` saves a picture before and after.
## The setting goes back to what it was afterwards (through the window too).
func _row(tab: String, section: String, key: String, value: Variant, read: Callable, want: Variant = null, shot := false, frames := 20) -> void:
	await _open(tab)
	var name := section + "-" + key
	var before: Variant = Settings.get_value(section, key)
	var had := Settings.has_value(section, key)
	var c := _control(name)
	if c is BaseButton and (c as BaseButton).disabled:
		_note("%s/%s: greyed out (%s)" % [section, key, Settings.look_overrides(key)])
		return
	if shot:
		await _shot("%s-before" % key)
	if not _set_control(name, value):
		_check("%s/%s = %s" % [section, key, value], false, "no control %s with that value in the window" % name)
		return
	await _frames(frames)
	var got: Variant = read.call()
	var ok: bool
	var expected: Variant = value if want == null else want
	if expected is Callable:
		ok = bool((expected as Callable).call(got))
	elif expected is float:
		ok = got is float or got is int
		ok = ok and is_equal_approx(float(got), float(expected))
	else:
		ok = str(got) == str(expected)
	var cfg := ConfigFile.new()
	cfg.load(Settings.path)
	var saved: Variant = cfg.get_value(section, key, null)
	var saved_ok := saved != null and str(saved) == str(Settings.get_value(section, key))
	_check("%s/%s = %s" % [section, key, value], ok and saved_ok, "read %s%s" % [str(got), "" if saved_ok else ", NOT SAVED (file has %s)" % str(saved)])
	if shot:
		await _shot("%s-%s" % [key, str(value).replace(".", "_")])
	# Back as it was, the way the window would.
	await _open(tab)
	if not _set_control(name, before):
		Settings.set_value(section, key, before)
	if not had:
		Settings.reset_value(section, key)
	await _frames(5)


# --- the rows ------------------------------------------------------------------------------------

func _walk() -> void:
	var root := get_tree().root
	_note("look %s, presets: %s" % [str(Settings.get_value("graphics", "look")), Settings.preset_now()])
	# Presets: each sets its values together.
	for preset in ["low", "medium", "high", "ultra"]:
		await _open("Graphics")
		_set_control("graphics-preset", preset)
		await _frames(30)
		var values: Dictionary = Settings.PRESETS[preset]
		var wrong: Array = []
		for k in values:
			if str(Settings.get_value("graphics", k)) != str(values[k]):
				wrong.append("%s=%s" % [k, Settings.get_value("graphics", k)])
		_check("preset %s sets its values" % preset, wrong.is_empty() and Settings.preset_now() == preset, ", ".join(wrong))
		_check("preset %s reaches the game" % preset, main.world.view_radius == int(values["view_radius"])
			and main.sun_shadows.quality == str(values["shadows"]) and main.decoratives.distance == float(values["decorative_distance"])
			and is_equal_approx(main.decoratives.density, float(values["decorative_density"])),
			"view %d shadows %s decor %.0f density %.2f" % [main.world.view_radius, main.sun_shadows.quality, main.decoratives.distance, main.decoratives.density])
		await _shot("preset-" + preset)
	await _open("Graphics")
	_set_control("graphics-preset", "high")
	await _frames(30)

	# General
	await _row("Graphics", "graphics", "window_mode", "borderless", func() -> int: return DisplayServer.window_get_mode(),
		func(m: int) -> bool: return m == DisplayServer.WINDOW_MODE_FULLSCREEN, false, 60)
	await _frames(60)
	_check("window back to windowed", DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED, str(DisplayServer.window_get_mode()))
	# Minimize on focus loss: in full screen, losing the focus minimises the window, getting it back restores it.
	await _open("Graphics")
	_set_control("graphics-minimize_on_focus_loss", true)
	Settings.set_value("graphics", "window_mode", "borderless", false)
	Settings.apply_window(root)
	await _frames(30)
	main.front_end.notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	await _frames(30)
	var minimised := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MINIMIZED
	main.front_end.notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	await _frames(30)
	_check("graphics/minimize_on_focus_loss: minimised on focus loss in full screen, back on focus", minimised
		and DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN, "now %d" % DisplayServer.window_get_mode())
	Settings.set_value("graphics", "window_mode", "windowed", false)
	Settings.apply_window(root)
	Settings.reset_value("graphics", "minimize_on_focus_loss")
	Settings.reset_value("graphics", "window_mode")
	await _frames(30)
	await _row("Graphics", "graphics", "resolution", "1280x720", func() -> Vector2i: return DisplayServer.window_get_size(),
		func(s: Vector2i) -> bool: return s == Vector2i(1280, 720), false, 30)
	await _open("Graphics")
	_set_control("graphics-resolution", "")
	await _frames(30)
	_check("graphics/resolution Default gives the default window", DisplayServer.window_get_size() == Settings.default_window_size(),
		str(DisplayServer.window_get_size()))
	await _row("Graphics", "graphics", "vsync", false, func() -> int: return DisplayServer.window_get_vsync_mode(),
		func(m: int) -> bool: return m == DisplayServer.VSYNC_DISABLED)
	await _row("Graphics", "graphics", "fps_cap", 30, func() -> int: return Engine.max_fps, 30)
	await _row("Graphics", "graphics", "render_scale", 0.5, func() -> float: return root.scaling_3d_scale, 0.5, true)
	await _row("Graphics", "graphics", "view_radius", 4, func() -> int: return main.world.view_radius, 4, true, 120)
	await _row("Graphics", "graphics", "entity_radius", 64, func() -> int: return main.world.focus_radius, 64)
	await _row("Graphics", "graphics", "belt_distance", 32, func() -> int: return main.belt_lanes.distance, 32, true, 90)
	await _row("Graphics", "graphics", "belt_updates", 1000, func() -> String: return "%s %s" % [main.belt_lanes.cap, main.belt_lanes.auto],
		func(s: String) -> bool: return s.ends_with("false") and int(s.get_slice(" ", 0)) <= 1000)
	await _row("Graphics", "graphics", "hold_ups", false, func() -> bool: return main.ups_governor.enabled, false)
	await _row("Graphics", "graphics", "effects", false, func() -> bool: return FxSettings.effects_enabled, false)
	await _row("Graphics", "graphics", "item_models_max", 0, func() -> String: return "%s %s" % [ItemCards.use_models, ItemCards.model_cap],
		"false 0", true, 60)
	await _row("Graphics", "graphics", "clouds", false, func() -> bool: return main._planet_sky.clouds_on, false, true)
	await _row("Graphics", "graphics", "decoratives", false, func() -> bool: return main.decoratives.enabled and main.decoratives.visible, false, true)
	await _row("Graphics", "graphics", "decorative_density", 0.3, func() -> float: return main.decoratives.density, 0.3, true, 90)
	await _row("Graphics", "graphics", "decorative_distance", 64, func() -> float: return main.decoratives.distance, 64.0, true, 90)
	await _row("Graphics", "graphics", "grass_3d", "off", func() -> float: return main.decoratives.grass_range, 0.0, true)
	await _row("Graphics", "graphics", "grass_3d", "far", func() -> float: return main.decoratives.grass_range, func(r: float) -> bool: return r >= 50.0, true)
	await _row("Graphics", "graphics", "look", "classic", func() -> String: return main.looks.current, "classic", true, 60)
	# Advanced
	for aa in ["off", "fxaa", "smaa", "taa", "msaa4"]:
		await _row("Graphics", "graphics", "antialiasing", aa, func() -> String: return "%d %d %s" % [root.msaa_3d, root.screen_space_aa, root.use_taa],
			func(s: String) -> bool: return s == {"off": "0 0 false", "fxaa": "0 1 false", "smaa": "0 2 false", "taa": "0 0 true", "msaa4": "2 0 false"}[aa])
	for q in ["off", "low", "ultra"]:
		await _row("Graphics", "graphics", "shadows", q, func() -> String: return "%s %s %d" % [main._sun.shadow_enabled, main.sun_shadows.quality, RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)],
			func(s: String) -> bool: return s.begins_with("false") if q == "off" else s.begins_with("true " + q), true)
	await _row("Graphics", "graphics", "shadow_distance", 60, func() -> float: return main.sun_shadows.distance_cap, 60.0)
	for q in ["low", "high"]:
		await _row("Graphics", "graphics", "lod_quality", q, func() -> float: return ModelLods.lod_bias, float(ModelLods.QUALITY[q][1]), true, 60)
	await _row("Graphics", "graphics", "merge_far", false, func() -> bool: return main.world.far_chunks.enabled, false)
	await _row("Graphics", "graphics", "animate_mod_buildings", true, func() -> bool: return SpriteStandins.animate, true)
	await _row("Graphics", "graphics", "merged_materials", true, func() -> bool: return ModelLibrary.merge_materials,
		func(v: bool) -> bool: return not v)  # after a restart: the running game keeps its surfaces
	await _row("Graphics", "graphics", "ssao", false, func() -> bool: return main._env.ssao_enabled, false, true)
	await _row("Graphics", "graphics", "contact_shading", false, func() -> String: return "%s %d" % [ContactShade.enabled, _visible_contact()],
		"false 0", true)
	var thread_model := func() -> int:
		var cfg := ConfigFile.new()
		cfg.load(Settings.ENGINE_OVERRIDES)
		return int(cfg.get_value("rendering", "driver/threads/thread_model", 0))
	await _row("Graphics", "graphics", "render_thread", true, thread_model, Settings.THREAD_SEPARATE)
	# Accessibility (sliders applied while dragging, saved on release)
	await _row("Graphics", "graphics", "brightness", 1.4, func() -> float: return main._env.adjustment_brightness, 1.4, true)
	await _row("Graphics", "graphics", "contrast", 1.4, func() -> float: return main._env.adjustment_contrast, 1.4, true)
	await _row("Graphics", "graphics", "saturation", 0.2, func() -> float: return main._env.adjustment_saturation, 0.2, true)
	await _row("Graphics", "graphics", "color_filter", "deuteranopia", func() -> bool: return _color_filter_on(), true, true)

	# Camera
	await _row("Camera", "camera", "orthographic", true, func() -> bool: return main.rig.orthographic, true, true)
	await _row("Camera", "camera", "map_orthographic", false, func() -> bool: return main.rig.remote_orthographic, false)
	await _row("Camera", "camera", "max_zoom", 60.0, func() -> float: return main.rig.max_distance, 60.0)
	await _row("Camera", "camera", "map_zoom_out", 100.0, func() -> float: return float(Settings.get_value("camera", "map_zoom_out")), 100.0)
	await _row("Camera", "camera", "look_sensitivity", 2.0, func() -> float: return main.rig.look_speed, 2.0)
	await _row("Camera", "camera", "invert_y", true, func() -> float: return main.rig.look_sign, -1.0)
	await _row("Camera", "camera", "follow_hills", true, func() -> bool: return bool(Settings.get_value("camera", "follow_hills")), true)
	await _row("Camera", "camera", "default_view", "first_person", func() -> String: return str(Settings.get_value("camera", "default_view")), "first_person")

	# Interface
	var ui = main.hud.ui
	await _row("Interface", "interface", "show_help", true, func() -> bool: return main.hud.help.visible, true, true)
	await _row("Interface", "interface", "alt_mode", true, func() -> bool: return ui.alt_mode, true, true)
	await _row("Interface", "interface", "alt_inserter_arrows", true, func() -> bool: return bool(Settings.get_value("interface", "alt_inserter_arrows")), true)
	await _row("Interface", "interface", "smart_belt_building", false, func() -> bool: return bool(Settings.get_value("interface", "smart_belt_building")), false)
	await _row("Interface", "interface", "lock_belt_straight", true, func() -> bool: return bool(Settings.get_value("interface", "lock_belt_straight")), true)
	await _row("Interface", "interface", "ui_scale", "1.5", func() -> float: return Settings.chosen_ui_scale(), 1.5, true, 30)
	await _row("Interface", "interface", "tooltip_delay", 1.5, func() -> float: return float(ProjectSettings.get_setting("gui/timers/tooltip_delay_sec")), 1.5)
	await _row("Interface", "interface", "entity_info", false, func() -> bool: return bool(ui.entity_info.get_meta("enabled", true)), false)
	await _row("Interface", "interface", "mod_windows", true, func() -> bool: return Bridge.mod_windows, true)
	await _row("Interface", "interface", "message_delay", 10.0, func() -> float: return float(Settings.get_value("interface", "message_delay")), 10.0)
	await _row("Interface", "interface", "shortcut_bar", false, func() -> bool: return ui.shortcuts.visible, false, true)
	await _row("Interface", "interface", "research_progress", false, func() -> bool: return bool(ui.research_hud.get_meta("enabled", true)), false)
	await _row("Interface", "interface", "alerts", false, func() -> bool: return ui.alerts.visible, false)
	await _row("Interface", "interface", "debug_overlay", true, func() -> bool: return ui.debug_overlay, true, true)
	await _ui_rows(ui)

	# Sound
	await _row("Sound", "sound", "max_voices", 6, func() -> int: return FxSettings.max_voices, 6)
	await _open("Sound")
	var s := _control("sound-master") as HSlider
	if s != null:
		var was := s.value
		s.value = 0.3
		s.drag_ended.emit(true)
		await _frames(5)
		var db := AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Master"))
		_check("sound/master = 0.3", is_equal_approx(float(Settings.get_value("sound", "master")), 0.3) and absf(db - linear_to_db(0.3)) < 0.5, "bus %.1f dB" % db)
		s.value = was
		s.drag_ended.emit(true)
	var mute := _control("sound-music_on") as CheckBox
	if mute != null:
		mute.button_pressed = not mute.button_pressed
		await _frames(5)
		_check("sound/music_on switched", AudioServer.is_bus_mute(AudioServer.get_bus_index("Music")) != mute.button_pressed,
			"mute %s" % AudioServer.is_bus_mute(AudioServer.get_bus_index("Music")))
		mute.button_pressed = not mute.button_pressed
	# Other
	await _row("Other", "factorio", "autosave_interval", 5, func() -> int: return int(Settings.get_value("factorio", "autosave_interval")), 5)
	await _row("Other", "factorio", "verbose_logging", true, func() -> bool: return bool(Settings.get_value("factorio", "verbose_logging")), true)
	await _row("Other", "factorio", "minimize_factorio", false, func() -> bool: return bool(Settings.get_value("factorio", "minimize_factorio")), false)
	await _controls()
	await _addons()
	if _window != null:
		_window.queue_free()


## Settings > Controls: a binding's button clicked and a key pressed, as a player rebinds it.
func _controls() -> void:
	await _open("Controls")
	var action := "toggle_map"
	var b := _control("controls-%s-0" % action) as Button
	if b == null:
		_check("controls: rebind %s" % action, false, "no button")
		return
	b.pressed.emit()
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_J
	ev.keycode = KEY_J
	ev.pressed = true
	_window._input(ev)
	await _frames(3)
	var bound := false
	for e in InputMap.action_get_events(action):
		if e is InputEventKey and (e as InputEventKey).physical_keycode == KEY_J:
			bound = true
	var cfg := ConfigFile.new()
	cfg.load(Settings.path)
	_check("controls: %s rebound to J" % action, bound and str(cfg.get_value("controls", action, "")).begins_with("J"),
		"saved %s" % str(cfg.get_value("controls", action, "")))
	await _open("Controls")
	var reset := _control("ResetControls") as Button
	if reset != null:
		reset.pressed.emit()
	await _frames(3)
	var back := false
	for e in InputMap.action_get_events(action):
		if e is InputEventKey and (e as InputEventKey).physical_keycode == KEY_M:
			back = true
	_check("controls: Reset all puts %s back on M" % action, back and not Settings.has_value("controls", action), "")


## The add-ons' own pages (Add-ons menu): each setting changed through api.settings as that page
## does, then whether the add-on heard (its own `options` / `_values`) and how much the picture moved.
func _addons() -> void:
	if main.addons == null:
		return
	for m: Dictionary in main.addons.running():
		var api = m["object"]
		var node: Node = m["node"]
		_note("add-on %s %s: %d settings" % [m["id"], m["version"], api.settings.list().size()])
		for def: Dictionary in api.settings.list():
			var id := str(def["id"])
			var was: Variant = api.settings.value(id)
			var other: Variant = _other_value(def, was)
			if other == null:
				_note("%s/%s: no other value to try" % [m["id"], id])
				continue
			var visible := str(m["id"]) != "cinematic-camera"
			var before: Image = null
			if visible and DisplayServer.get_name() != "headless":
				await _frames(20)
				await RenderingServer.frame_post_draw
				before = get_viewport().get_texture().get_image()
			var heard := [false]
			var on_changed := func(k: String, _v: Variant) -> void:
				if k == id:
					heard[0] = true
			api.settings.changed.connect(on_changed)
			api.settings.set_value(id, other)
			await _frames(40 if str(m["id"]) == "cinematic-camera" else 180)  # hills are rebuilt on a worker
			api.settings.changed.disconnect(on_changed)
			var own: Variant = null
			for field in ["options", "_values"]:
				var d: Variant = node.get(field)
				if d is Dictionary and (d as Dictionary).has(id):
					own = d[id]
			var diff := -1.0
			if before != null:
				await RenderingServer.frame_post_draw
				diff = _diff(before, get_viewport().get_texture().get_image())
				if diff >= 0.0:
					get_viewport().get_texture().get_image().save_png(out_dir.path_join("addon-%s-%s.png" % [m["id"], id]))
			var cfg := ConfigFile.new()
			cfg.load(Settings.path)
			var saved: Variant = cfg.get_value(api.settings.section(), id, null)
			var ok: bool = bool(heard[0]) and saved != null and (own == null or str(own) == str(api.settings.value(id)))
			_check("%s/%s = %s" % [m["id"], id, str(other)], ok, "heard %s, add-on has %s, saved %s, picture moved %.2f" % [heard[0], str(own), str(saved), diff])
			api.settings.set_value(id, was)
			await _frames(10)
		if str(m["id"]) == "cinematic-camera":
			await _camera_addon(m)


## The Cinematic camera's Shot settings while its free camera films: the field of view reaches the camera.
func _camera_addon(m: Dictionary) -> void:
	var api = m["object"]
	var node: Node = m["node"]
	if not node.has_method("begin") or node.get("free_cam") == null:
		return
	if not node.begin(node.free_cam):
		_note("cinematic-camera: its free camera couldn't start")
		return
	await _frames(30)
	var was: Variant = api.settings.value("fov")
	api.settings.set_value("fov", 30.0)
	await _frames(30)
	var cam := get_viewport().get_camera_3d()
	_check("cinematic-camera/fov = 30 while filming", cam != null and absf(cam.fov - 30.0) < 1.0, "camera fov %.1f" % (cam.fov if cam != null else -1.0))
	await _shot("addon-cinematic-camera-fov30")
	api.settings.set_value("fov", was)
	node.stop(false)
	await _frames(30)


func _other_value(def: Dictionary, was: Variant) -> Variant:
	match str(def["type"]):
		"bool":
			return not bool(was)
		"number":
			var lo := float(def["min"])
			var hi := float(def["max"])
			var v := lo if absf(float(was) - lo) > absf(float(was) - hi) else hi
			return int(v) if bool(def.get("integer", false)) else v
		"choice":
			for c in def["choices"]:
				if str(c[1]) != str(was):
					return c[1]
		"text":
			return "probe"
	return null


func _diff(a: Image, b: Image) -> float:
	if a.get_size() != b.get_size():
		return -1.0
	var sa := a.duplicate() as Image
	var sb := b.duplicate() as Image
	sa.resize(160, 90)
	sb.resize(160, 90)
	var total := 0.0
	for y in 90:
		for x in 160:
			var ca := sa.get_pixel(x, y)
			var cb := sb.get_pixel(x, y)
			total += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
	return total / (160.0 * 90.0 * 3.0) * 255.0


func _ui_rows(_ui) -> void:
	var ui_settings = UiSettings.shared()
	await _open("Interface")
	for key in ["map/minimap", "map/minimap_tags"]:
		var c := _control(key.replace("/", "-")) as CheckBox
		if c == null:
			_check(key, false, "no control")
			continue
		var was := c.button_pressed
		c.button_pressed = not was
		await _frames(10)
		var mm = main.hud.ui.minimap
		_check("%s = %s" % [key, not was], bool(ui_settings.get_value(key)) == (not was)
			and (key != "map/minimap" or mm.visible == (not was)), "minimap visible %s" % mm.visible)
		if key == "map/minimap":
			await _shot("minimap-off")
		c.button_pressed = was
		await _frames(5)
	var size := _control("map-minimap_size") as HSlider
	if size != null:
		var was := size.value
		size.value = 400.0
		size.drag_ended.emit(true)
		await _frames(10)
		var mm = main.hud.ui.minimap
		_check("map/minimap_size = 400", is_equal_approx(float(ui_settings.get_value("map/minimap_size")), 400.0) and mm.size.x >= Kit.px(300),
			"minimap %s" % str(mm.size))
		await _shot("minimap_size-400")
		size.value = was
		size.drag_ended.emit(true)


func _visible_contact() -> int:
	var n := 0
	for node in get_tree().root.find_children("ContactShade", "MultiMeshInstance3D", true, false):
		if (node as Node3D).is_visible_in_tree():
			n += 1
	return n


func _color_filter_on() -> bool:
	for node in get_tree().root.find_children("*", "CanvasLayer", true, false):
		if node.get_script() != null and str(node.get_script().resource_path).ends_with("color_filter.gd"):
			return (node as CanvasLayer).visible
	return false


# --- after a restart -----------------------------------------------------------------------------

## Values unlike the defaults, written for the next start to read (--settings-probe-verify).
const RESTART := {
	"graphics": {"render_scale": 0.75, "view_radius": 6, "shadows": "low", "lod_quality": "low", "merge_far": false,
		"ssao": false, "contact_shading": false, "decoratives": false, "grass_3d": "short", "clouds": false, "brightness": 1.2,
		"look": "classic", "antialiasing": "fxaa", "merged_materials": true, "render_thread": true, "item_models_max": 0,
		"fps_cap": 60, "vsync": false, "effects": false, "entity_radius": 96, "belt_distance": 96, "decorative_distance": 96},
	"camera": {"default_view": "factorio", "orthographic": true, "max_zoom": 80, "look_sensitivity": 1.5, "invert_y": true},
	"interface": {"ui_scale": "1.25", "show_help": true, "shortcut_bar": false, "debug_overlay": true, "tooltip_delay": 1.0,
		"alt_mode": true},
	"sound": {"max_voices": 8},
}


func _write_restart_values() -> void:
	for section in RESTART:
		for key in RESTART[section]:
			Settings.set_value(section, key, RESTART[section][key])
	_note("restart values written to %s" % Settings.path)
	_write("report.txt")


func _verify() -> void:
	var root := get_tree().root
	var g: Dictionary = RESTART["graphics"]
	var ui = main.hud.ui
	var reads := {
		"render_scale": root.scaling_3d_scale, "view_radius": main.world.view_radius, "shadows": main.sun_shadows.quality,
		"lod_quality": ModelLods.lod_bias, "merge_far": main.world.far_chunks.enabled, "ssao": main._env.ssao_enabled,
		"contact_shading": ContactShade.enabled, "decoratives": main.decoratives.enabled, "grass_3d": main.decoratives.grass_range,
		"clouds": main._planet_sky.clouds_on, "brightness": main._env.adjustment_brightness, "look": main.looks.current,
		"antialiasing": root.screen_space_aa, "merged_materials": ModelLibrary.merge_materials,
		"render_thread": int(ProjectSettings.get_setting("rendering/driver/threads/thread_model")), "item_models_max": ItemCards.model_cap,
		"fps_cap": Engine.max_fps, "vsync": DisplayServer.window_get_vsync_mode(), "effects": FxSettings.effects_enabled,
		"entity_radius": main.world.focus_radius, "belt_distance": main.belt_lanes.distance, "decorative_distance": main.decoratives.distance,
	}
	var wants := {
		"lod_quality": float(ModelLods.QUALITY["low"][1]), "grass_3d": func(r: float) -> bool: return r > 0.0 and r <= 30.0,
		"antialiasing": Viewport.SCREEN_SPACE_AA_FXAA, "render_thread": Settings.THREAD_SEPARATE,
		"vsync": DisplayServer.VSYNC_DISABLED,
	}
	for key in g:
		var want: Variant = wants.get(key, g[key])
		var got: Variant = reads[key]
		var ok: bool = bool((want as Callable).call(got)) if want is Callable else (is_equal_approx(float(got), float(want)) if want is float else str(got) == str(want))
		_check("after restart graphics/%s = %s" % [key, g[key]], ok, "read %s" % str(got))
	var c: Dictionary = RESTART["camera"]
	_check("after restart camera/default_view = factorio", main.rig.in_factorio_view(), "")
	_check("after restart camera/orthographic", main.rig.orthographic or main.rig.in_factorio_view(), str(main.rig.orthographic))
	_check("after restart camera/max_zoom", is_equal_approx(main.rig.max_distance, float(c["max_zoom"])), str(main.rig.max_distance))
	_check("after restart camera/look_sensitivity", is_equal_approx(main.rig.look_speed, 1.5), str(main.rig.look_speed))
	_check("after restart camera/invert_y", main.rig.look_sign < 0.0, str(main.rig.look_sign))
	_check("after restart interface/ui_scale", is_equal_approx(Settings.chosen_ui_scale(), 1.25), str(Settings.chosen_ui_scale()))
	_check("after restart interface/show_help", main.hud.help.visible, "")
	_check("after restart interface/shortcut_bar", not ui.shortcuts.visible, "")
	_check("after restart interface/debug_overlay", ui.debug_overlay, "")
	_check("after restart interface/tooltip_delay", is_equal_approx(float(ProjectSettings.get_setting("gui/timers/tooltip_delay_sec")), 1.0), "")
	_check("after restart interface/alt_mode", ui.alt_mode, "")
	_check("after restart sound/max_voices", FxSettings.max_voices == 8, str(FxSettings.max_voices))
	await _shot("after-restart")
