extends Control
## The performance warning (owner: "a warning icon in the top left but to the right of the zenith logo
## showing any hold 60 ups or performance automatic downgrading of settings ... clickable to show a
## log"): Factorio's yellow alert triangle in a slot button right of the Show in Factorio button
## (factorio_ui.gd places it, and in that button's place while it is hidden), with how many settings
## the UPS governor holds back now. Hovering lists them; a click opens the log (perf_log.gd), newest
## first, with Copy. Shown while something is held and LINGER_MSEC after, so it doesn't blink.
##
## Settings > Interface > Performance warnings (`interface/perf_warning`, on; the debug menu's row flips
## the same setting): off hides the icon, the log still fills. `--perf-warning=off` starts with it off
## until the setting is changed. Redrawn only when the log changes; a timer for the linger, no _process.

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const Alerts := preload("res://scripts/ui/factorio/alerts.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const PerfLog := preload("res://scripts/world/perf_log.gd")
const Sfx := preload("res://scripts/fx/sfx.gd")

const NOTE := "Settings held back to keep the game at 60 UPS light the icon. The bridge's work budget, Automatic moving belt items and the bridge's belt square are logged here too, but don't light it."

## --perf-warning=off: off at launch, until the setting is changed; not saved. Settings > Interface and the
## debug row show enabled(), so they read off meanwhile and one click turns it on.
static var forced_off := Settings.arg_value("--perf-warning=") == "off"

var button: Button
var panel: PanelContainer
var _rows: VBoxContainer
var _linger: Timer
## A refill of the open panel is queued for the end of the frame (several log changes in a frame, one refill).
var _dirty := false
## PerfLog.version the rows were filled from: an unchanged log isn't drawn again.
var _filled := -1


func _ready() -> void:
	name = "PerfWarning"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Kit.pxv(Kit.SLOT, Kit.SLOT)
	size = custom_minimum_size
	button = Alerts.AlertButton.new()
	button.name = "PerfWarningButton"
	button.theme_type_variation = "FSlotButton"
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Kit.pxv(Kit.SLOT, Kit.SLOT)
	button.picture = Alerts.texture("fire")  # Factorio's warning-icon.png
	button.texture_filter = Kit.ICON_FILTER
	button.tooltip_text = "Performance warnings"
	button.pressed.connect(func() -> void:
		Sfx.play_ui("gui-click")
		set_open(not is_open()))
	add_child(button)
	_linger = Timer.new()
	_linger.one_shot = true
	_linger.timeout.connect(refresh)
	add_child(_linger)
	_build_panel()
	PerfLog.listen(_on_log)
	Settings.listen(_on_setting)
	refresh()


func _exit_tree() -> void:
	PerfLog.unlisten(_on_log)
	Settings.unlisten(_on_setting)


func _on_setting(section: String, key: String) -> void:
	if section == "interface" and key == "perf_warning":
		forced_off = false
		refresh()


func _on_log() -> void:
	refresh()


static func enabled() -> bool:
	return not forced_off and bool(Settings.get_value("interface", "perf_warning"))


## How many settings are held back now (the icon's count).
func count() -> int:
	return PerfLog.active().size()


## The icon, its count and tooltip, the linger timer and the open panel, from the log now.
func refresh() -> void:
	var active := PerfLog.active()
	button.count = active.size()
	button.queue_redraw()
	var lines: Array = []
	for e: Dictionary in active:
		lines.append([PerfLog.what(e) + " (since " + str(e["time"]) + ")"])
	if lines.is_empty():
		lines.append(["Nothing held back now"])
	lines.append(["Click| for the log.", "", null, "keys"])
	button.set_meta("tip", ["Held back for UPS", lines])
	var want := enabled() and PerfLog.lit()
	if active.is_empty() and PerfLog.last_lit_end >= 0:
		var left := PerfLog.LINGER_MSEC - (PerfLog.now() - PerfLog.last_lit_end)
		if left > 0 and is_inside_tree():
			_linger.start(left / 1000.0 + 0.05)
	if want != visible:
		visible = want
		if not want:
			set_open(false)
	if is_open() and PerfLog.version != _filled and not _dirty:
		_dirty = true
		_fill.call_deferred()


func is_open() -> bool:
	return panel != null and panel.visible


func set_open(on: bool) -> void:
	if panel == null or panel.visible == on:
		return
	panel.visible = on
	if on:
		_fill()


func _build_panel() -> void:
	panel = Kit.panel("FFrame")
	panel.name = "PerfWarningPanel"
	panel.visible = false
	panel.position = Vector2(0.0, Kit.px(Kit.SLOT + 4))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Kit.px(8))
	panel.add_child(box)
	var bar := Kit.title_bar("Performance warnings", true)
	(bar.get_child(bar.get_child_count() - 1) as Button).pressed.connect(func() -> void: set_open(false))
	box.add_child(bar)
	var note := Kit.label(NOTE)
	note.name = "Note"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = Kit.px(520)
	note.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	box.add_child(note)
	var deep: Array = Kit.deep_scroll(Kit.pxv(520, 260))
	box.add_child(deep[0])
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "top", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, Kit.px(6))
	(deep[1] as ScrollContainer).add_child(pad)
	_rows = VBoxContainer.new()
	_rows.name = "Rows"
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", Kit.px(6))
	pad.add_child(_rows)
	var foot := HBoxContainer.new()
	var space := Control.new()
	space.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(space)
	var copy := Button.new()
	copy.name = "Copy"
	copy.text = "Copy"
	copy.focus_mode = Control.FOCUS_NONE
	copy.pressed.connect(func() -> void:
		Sfx.play_ui("gui-click")
		DisplayServer.clipboard_set(PerfLog.text()))
	foot.add_child(copy)
	box.add_child(foot)
	add_child(panel)


## The rows, newest first: the clock time, "entity distance 192 → 128", why, and held or when it ended.
func _fill() -> void:
	_dirty = false
	if not is_open():
		return
	_filled = PerfLog.version
	for c in _rows.get_children():
		_rows.remove_child(c)
		c.queue_free()
	if PerfLog.entries.is_empty():
		_rows.add_child(Kit.label("Nothing held back this game"))
		return
	for i in range(PerfLog.entries.size() - 1, -1, -1):
		var e: Dictionary = PerfLog.entries[i]
		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 0)
		var head := Kit.label("%s   %s" % [e["time"], PerfLog.what(e)])
		head.add_theme_font_override("font", Kit.font("bold"))
		if not e["lights"]:
			head.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		row.add_child(head)
		var why := str(e["why"]) + ("   (logged only)" if not e["lights"] else "")
		var line := Kit.label(why)
		line.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		row.add_child(line)
		var state: Label
		if e.has("ended_msec"):
			state = Kit.label("%s at %s, after %s" % [e["ended"], e["ended_time"], PerfLog.span(int(e["ended_msec"]) - int(e["msec"]))])
			state.add_theme_color_override("font_color", Kit.GREEN_TEXT)
		else:
			state = Kit.label("held")
			state.add_theme_color_override("font_color", Kit.YELLOW_TEXT)
		row.add_child(state)
		_rows.add_child(row)


## The panel's rows as text (tests).
func rows_text() -> String:
	var lines: Array = []
	for row in _rows.get_children():
		for l in row.get_children():
			if l is Label:
				lines.append((l as Label).text)
		if row is Label:
			lines.append((row as Label).text)
	return "\n".join(lines)
