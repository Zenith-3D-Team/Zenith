extends CanvasLayer
## On-screen info around the Factorio-style UI (scripts/ui/factorio/): the connection and debug
## line (F4), help (F1), messages from the server, the mining progress and the character's health
## over the quickbar, and what the character is driving. All text is Factorio's font, white with
## a dark border like Factorio's in-game text.
##
## Over the health bar, as in Factorio, the armour's shield (purple) and its batteries' charge,
## each while not full. Taking damage flashes the screen's edges red, and low health tints it red
## (damage_overlay.gd).

const MachineScreen := preload("res://scripts/ui/factorio/machine_screen.gd")
const FactorioUi := preload("res://scripts/ui/factorio/factorio_ui.gd")
const Kit := preload("res://scripts/ui/factorio/kit.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const DamageOverlay := preload("res://scripts/ui/damage_overlay.gd")
const Controls := preload("res://scripts/player/controls.gd")

## Short names for keys in the help (OS.get_keycode_string's are long).
const KEY_SHORT := {"QuoteLeft": "`", "Comma": ",", "Period": ".", "Slash": "/", "PageUp": "PgUp", "PageDown": "PgDn"}
## Factorio's health bar goes from green through yellow to red.
const HEALTH_COLORS := [Color(0.9, 0.1, 0.1), Color(1.0, 0.85, 0.1), Color(0.1, 0.9, 0.1)]
## style.lua's shield_progressbar colour, and the batteries' charge.
const SHIELD_COLOR := Color(0.8, 0.2, 0.8)
const ENERGY_COLOR := Color(0.95, 0.8, 0.15)

var status := Label.new()
var cursor_label := Label.new()
var help := Label.new()
var mining_bar := ProgressBar.new()
var health_bar := ProgressBar.new()
var shield_bar := ProgressBar.new()
var energy_bar := ProgressBar.new()
var damage := DamageOverlay.new()
## [[gun, ammo, magazines], ...] per gun slot ("" when empty), and the selected slot (1-based).
var guns: Array = []
var selected_gun := 1
var screen := MachineScreen.new()

var _messages := VBoxContainer.new()
var _health_color := -1.0
## The Factorio-style inventory, crafting, machine screens and quickbar (scripts/ui/factorio/).
var ui := FactorioUi.new()


func _ready() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = Kit.theme()  # themes don't pass through the CanvasLayer from the window
	root.texture_filter = Kit.FILTER
	add_child(root)
	# Under everything else: the red of damage and low health over the world.
	root.add_child(damage)

	status.position = Kit.pxv(12, 8)
	status.theme_type_variation = "FSmallLabel"
	root.add_child(status)

	# Messages appear top centre, like Factorio's flying "Out of reach" / "Inventory full" text.
	_messages.anchor_left = 0.5
	_messages.anchor_right = 0.5
	_messages.offset_left = -Kit.px(400)
	_messages.offset_right = Kit.px(400)
	_messages.offset_top = Kit.px(48)
	_messages.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_messages)

	# Factorio has no help text: a small panel in the free space on the left, wrapped to its width.
	# factorio_ui.gd's layout places it, smaller and then cut short when the window is crowded, so
	# the first line is the one to keep.
	refresh_help()
	Settings.listen(_on_setting)
	help.theme_type_variation = "FSmallLabel"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var back := StyleBoxFlat.new()
	back.bg_color = Color(0.0, 0.0, 0.0, 0.45)
	back.set_content_margin_all(Kit.px(6))
	back.set_corner_radius_all(Kit.px(3))
	help.add_theme_stylebox_override("normal", back)
	help.add_theme_font_size_override("font_size", Kit.px(13))
	help.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(help)

	ui.screen = screen
	ui.status_label = status
	ui.help_label = help
	ui.cursor_label = cursor_label
	root.add_child(ui)
	root.move_child(_messages, -1)  # over the map view and windows ("Can't put a tag there")

	# Above the quickbar: mining progress (orange), then the character's health when hurt.
	mining_bar = Kit.progress_bar(Kit.BAR_ORANGE)
	mining_bar.custom_minimum_size.y = Kit.px(8)
	mining_bar.visible = false
	ui.quickbar.add_bar(mining_bar)
	# The armour's batteries (yellow) and shield (shield_progressbar's purple) over the health bar.
	energy_bar = Kit.progress_bar(ENERGY_COLOR)
	energy_bar.custom_minimum_size.y = Kit.px(8)
	energy_bar.visible = false
	energy_bar.mouse_filter = Control.MOUSE_FILTER_PASS
	ui.quickbar.add_bar(energy_bar)
	shield_bar = Kit.progress_bar(SHIELD_COLOR)
	shield_bar.custom_minimum_size.y = Kit.px(8)
	shield_bar.visible = false
	shield_bar.mouse_filter = Control.MOUSE_FILTER_PASS
	ui.quickbar.add_bar(shield_bar)
	var on_grid := func(kind: String) -> void:
		if kind == "char":
			_show_energy()
	ui.model.equipment_changed.connect(on_grid)
	health_bar = Kit.progress_bar(HEALTH_COLORS[2])
	health_bar.custom_minimum_size.y = Kit.px(8)
	health_bar.max_value = 250
	health_bar.value = 250
	health_bar.visible = false
	health_bar.mouse_filter = Control.MOUSE_FILTER_PASS
	ui.quickbar.add_bar(health_bar)

	# Driving: speed and the way out, bottom left above the weapon slots (factorio_ui.gd places it).
	cursor_label.theme_type_variation = "FSmallLabel"
	cursor_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(cursor_label)


func _exit_tree() -> void:
	Settings.unlisten(_on_setting)


func _on_setting(section: String, key: String) -> void:
	# Rebound in Settings → Controls, or Factorio's own keys switched on or off (read after this).
	if section == "controls" or (section == "factorio" and key == "use_factorio_keys"):
		refresh_help.call_deferred()


## The help with the keys bound now; factorio_ui.gd fits it to its room again (`full_text`).
func refresh_help() -> void:
	var text := help_text()
	help.text = text
	help.set_meta("full_text", text)


## The help's lines, each control under the key bound to it now (Settings → Controls, or Factorio's
## own keys); a control with no key is left out. The mouse's are fixed.
static func help_text() -> String:
	var lines: Array = [
		_say([[_keys(["toggle_help"]), "hide help"]]),
		_say([[_keys(["move_up", "move_left", "move_down", "move_right"], ""), "walk"], "Right mouse: mine",
			[_keys(["pick_up"]), "pick up"], "Left mouse: build or open", [_keys(["rotate"]), "rotate"],
			[_keys(["pipette"]), "pipette / put away"], [_keys(["drop_item"]), "drop"]]),
		_say(["Shift+click: ghost / paste settings", "Shift+right: copy settings", "Ctrl+click: fast transfer",
			[_keys(["copy", "cut", "paste"]), "copy, cut, paste"], [_keys(["undo"]), "undo"]]),
		_say([[_keys(["shoot_enemies"]), "shoot nearby enemies"], [_keys(["shoot_cursor"]), "shoot at the cursor"],
			[_keys(["next_gun"]), "next weapon"], [_keys(["enter_vehicle"]), "get in or out"]]),
		_say([[_keys(["camera_left", "camera_right"]), "turn camera (or middle drag)"],
			[_keys(["camera_tilt_up", "camera_tilt_down"]), "tilt"], "Wheel: zoom",
			[_keys(["factorio_view"]), "Factorio view"], [_keys(["first_person"]), "first person"]]),
		_say([[_keys(["open_screen"]), "inventory"], [_keys(["open_technology"]), "technologies"],
			[_keys(["toggle_map"]), "map"], [_keys(["production_statistics", "kill_statistics"]), "statistics"],
			[_keys(["logistic_networks"]), "logistic networks"], [_keys(["toggle_factoriopedia"]), "Factoriopedia (or Alt+click)"],
			[_keys(["toggle_console"]), "chat"], [_keys(["alt_mode"]), "Alt-mode"],
			[_keys(["quickbar_1", "quickbar_10"], "-"), "quickbar (inventory open: pin the hovered item)"],
			[_keys(["debug_line"]), "debug info"]]),
	]
	return "\n".join(lines.filter(func(l: String) -> bool: return l != ""))


## "keys: what · text · ..." from [keys, what] pairs and fixed texts; a pair without keys is left out.
static func _say(items: Array) -> String:
	var out: Array = []
	for item in items:
		if item is String:
			out.append(item)
		elif str(item[0]) != "":
			out.append("%s: %s" % [item[0], item[1]])
	return " · ".join(out)


## The first key bound to an action, short ("" when none).
static func _key(action: String) -> String:
	var k := Controls.keys_text(action).get_slice(" / ", 0)
	return str(KEY_SHORT.get(k, k))


## Several actions' first keys joined (WASD with "", "1-0" with "-"); "" unless all have one.
static func _keys(actions: Array, sep := " / ") -> String:
	var keys: Array = actions.map(func(a: String) -> String: return _key(a))
	return "" if keys.has("") else sep.join(keys)


func reset() -> void:
	set_inventory([])
	set_recipes([])
	set_guns(1, [])
	mining_bar.visible = false
	shield_bar.visible = false
	damage.reset()
	screen.close_local()


func count_of(item: String) -> int:
	return ui.model.count_of(item)


## [[name, count], ...]
func set_inventory(list: Array) -> void:
	ui.model.set_inventory_totals(list)


## Recipe names.
func set_recipes(list: Array) -> void:
	ui.model.set_recipe_list(list)


func show_message(text: String) -> void:
	if text == "":
		return
	# The same message again restarts its timer instead of stacking up.
	for child in _messages.get_children():
		if child is Label and (child as Label).text == text and not child.is_queued_for_deletion():
			_messages.remove_child(child)
			child.queue_free()
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.theme_type_variation = "FGameLabel"
	_messages.add_child(label)
	while _messages.get_child_count() > 5:
		var oldest := _messages.get_child(0)
		_messages.remove_child(oldest)
		oldest.queue_free()
	var id := label.get_instance_id()  # not the label itself: it may be gone by then
	var expire := func() -> void:
		var old := instance_from_id(id)
		if old != null:
			old.queue_free()
	# Factorio's "Chat message delay" (Settings → Interface).
	get_tree().create_timer(clampf(float(Settings.get_value("interface", "message_delay")), 1.0, 60.0)).timeout.connect(expire)


## Factorio shows the character's health over the quickbar while it is hurt.
func set_health(hp: int, max_hp: int) -> void:
	damage.set_health(hp, max_hp)
	ui.weapons.set_health(hp, max_hp)  # Factorio's bar beside the armour slot
	health_bar.max_value = maxi(1, max_hp)
	health_bar.value = hp
	health_bar.visible = hp > 0 and hp < max_hp
	health_bar.tooltip_text = "Health: %d / %d" % [hp, max_hp]
	var f := clampf(float(hp) / maxi(1, max_hp), 0.0, 1.0)
	if absf(f - _health_color) > 0.02:
		_health_color = f
		var c: Color = HEALTH_COLORS[0].lerp(HEALTH_COLORS[1], f * 2.0) if f < 0.5 else HEALTH_COLORS[1].lerp(HEALTH_COLORS[2], f * 2.0 - 1.0)
		health_bar.add_theme_stylebox_override("fill", Kit.bar_style(Color(snappedf(c.r, 0.05), snappedf(c.g, 0.05), snappedf(c.b, 0.05))))


## The armour's shield (`me.sd`, `me.msd`; max 0 without shields), shown over the health bar
## while it isn't full. Shield lost counts as damage taken for the red flash.
func set_shield(shield: int, max_shield: int) -> void:
	damage.set_shield(shield, max_shield)
	shield_bar.visible = max_shield > 0 and shield < max_shield
	shield_bar.max_value = maxi(1, max_shield)
	shield_bar.value = shield
	shield_bar.tooltip_text = "Shield: %d / %d" % [shield, max_shield]


## The armour's batteries (`eq` bat / mbat), shown while they aren't full.
func _show_energy() -> void:
	var g: Dictionary = ui.model.grid("char")
	var full := float(g.get("max_battery", 0))
	var now := float(g.get("battery", 0))
	energy_bar.visible = full > 0.0 and now < full * 0.999
	energy_bar.max_value = maxf(1.0, full)
	energy_bar.value = now
	energy_bar.tooltip_text = "Energy: %d%%" % roundi(now * 100.0 / maxf(1.0, full))


## {t: "guns", sel, l}: the weapon slots beside the quickbar show them.
func set_guns(sel: int, list: Array) -> void:
	guns = list
	selected_gun = sel
	ui.model.set_guns(sel, list)


func set_mining(progress: int) -> void:
	mining_bar.visible = progress >= 0
	mining_bar.value = progress
