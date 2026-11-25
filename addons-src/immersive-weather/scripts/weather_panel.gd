extends RefCounted
## Optional compact in-game Weather Control panel (toggled via Alt+F9 or Add-ons menu button).

const Presets := preload("weather_presets.gd")

var api
var director
var lightning
var win: Dictionary = {}
var _status_label: Label
var _mode_btn: OptionButton
var _weather_btn: OptionButton
var _syncing := false


func _init(a, d, l = null) -> void:
	api = a
	director = d
	lightning = l


func build() -> void:
	if not win.is_empty():
		return
	var ui = api.ui
	win = ui.window("Immersive Weather")
	var box: VBoxContainer = win["box"]
	box.add_theme_constant_override("separation", 6)

	_status_label = ui.label("Current: Fair")
	box.add_child(_status_label)

	var on_mode := func(val: Variant) -> void:
		if _syncing:
			return
		api.settings.set_value("mode", str(val))
	_mode_btn = ui.dropdown([["Dynamic cycle", "dynamic"], ["Locked", "locked"]], api.settings.value("mode"), on_mode)
	box.add_child(ui.row("Cycle mode", _mode_btn))

	var on_pick := func(val: Variant) -> void:
		if _syncing:
			return
		var wid := str(val)
		if str(api.settings.value("mode")) == "locked":
			api.settings.set_value("locked_weather", wid)
		else:
			director.transition_to(wid)
		refresh()
	_weather_btn = ui.dropdown(Presets.choices(), director.target_id, on_pick)
	box.add_child(ui.row("Weather", _weather_btn))

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)
	var on_jump := func() -> void:
		var wid := str(_weather_btn.get_selected_metadata())
		if str(api.settings.value("mode")) == "locked":
			api.settings.set_value("locked_weather", wid)
		director.jump_to(wid)
		refresh()
	var on_next := func() -> void:
		if str(api.settings.value("mode")) == "locked":
			api.settings.set_value("mode", "dynamic")
		director.next_weather()
		refresh()
	var on_dry := func() -> void:
		director.dry_now()
		refresh()
	var on_strike := func() -> void:
		if lightning != null and director.is_nauvis():
			lightning.trigger_strike("bolt")
			director.flash_level = lightning.current_flash()
			director.step(0.0)
		refresh()
	btn_row.add_child(ui.button("Apply now", on_jump))
	btn_row.add_child(ui.button("Next weather", on_next))
	btn_row.add_child(ui.button("Dry now", on_dry))
	btn_row.add_child(ui.button("Strike", on_strike))
	box.add_child(btn_row)

	var hint_text: String = str(api.keys.text("panel"))
	if hint_text != "":
		box.add_child(ui.note("Toggle panel: %s. All 12 Nauvis weather states ready." % hint_text, 280))
	refresh()


func toggle() -> void:
	build()
	api.ui.toggle(win["frame"])
	refresh()


func is_open() -> bool:
	return not win.is_empty() and api.ui.is_open(win["frame"])


func refresh() -> void:
	if win.is_empty():
		return
	_syncing = true
	if _status_label != null:
		_status_label.text = "Status: %s" % director.status_text()
	if _mode_btn != null:
		var mode := str(api.settings.value("mode"))
		for i in _mode_btn.item_count:
			if str(_mode_btn.get_item_metadata(i)) == mode:
				_mode_btn.select(i)
				break
	if _weather_btn != null:
		var wid: String = str(api.settings.value("locked_weather")) if str(api.settings.value("mode")) == "locked" else str(director.target_id)
		for i in _weather_btn.item_count:
			if str(_weather_btn.get_item_metadata(i)) == wid:
				_weather_btn.select(i)
				break
	_syncing = false
