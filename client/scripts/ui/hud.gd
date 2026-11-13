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
const ControlsInfo := preload("res://scripts/menu/controls_info.gd")

## Short names for keys in the help (OS.get_keycode_string's are long).
const KEY_SHORT := {"QuoteLeft": "`", "Comma": ",", "Period": ".", "Slash": "/", "PageUp": "PgUp", "PageDown": "PgDn",
	"Equal": "=", "Minus": "-", "BracketLeft": "[", "BracketRight": "]", "Semicolon": ";", "Apostrophe": "'",
	"BackSlash": "\\", "Backslash": "\\", "Escape": "Esc", "Kp Add": "Numpad +", "Kp Subtract": "Numpad -",
	"Kp Multiply": "Numpad *", "Kp Divide": "Numpad /", "Kp Enter": "Numpad Enter"}
## Factorio's health bar goes from green through yellow to red.
const HEALTH_COLORS := [Color(0.9, 0.1, 0.1), Color(1.0, 0.85, 0.1), Color(0.1, 0.9, 0.1)]
## style.lua's shield_progressbar colour, and the batteries' charge.
const SHIELD_COLOR := Color(0.8, 0.2, 0.8)
const ENERGY_COLOR := Color(0.95, 0.8, 0.15)

var status := Label.new()
var cursor_label := Label.new()
var help := RichTextLabel.new()
var _help_queued := false
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

	# Factorio has no help text: a panel in the free space on the left in Factorio's tooltip frame,
	# headings in its caption colour and keys in the blue its hints use. factorio_ui.gd's layout
	# places it, smaller when the window is crowded, and scrolled by the mouse wheel over it when
	# even that doesn't fit. The mouse passes through it to the world (its scroll bar excepted).
	help.bbcode_enabled = true
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.fit_content = false
	help.scroll_active = false
	help.add_theme_stylebox_override("normal", Kit.style("tooltip"))
	help.add_theme_color_override("default_color", Kit.WHITE)
	for weight in ["normal", "bold"]:
		var f := Kit.font("regular" if weight == "normal" else "bold")
		if f != null:
			help.add_theme_font_override("%s_font" % weight, f)
		help.add_theme_font_size_override("%s_font_size" % weight, Kit.px(13))
	help.mouse_filter = Control.MOUSE_FILTER_IGNORE
	refresh_help()
	Settings.listen(_on_setting)
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
	# Rebound in Settings → Controls, an add-on's controls added or taken away, or Factorio's own
	# keys switched on or off (read after this). An add-on adds its controls one by one: once for all.
	if section == "controls" or (section == "factorio" and key == "use_factorio_keys"):
		if not _help_queued:
			_help_queued = true
			refresh_help.call_deferred()


## The help with the keys bound now; factorio_ui.gd fits it to its room again (`full_bbcode`, or
## `scroll_bbcode` when it has to scroll). `full_text` is the same without the colours.
func refresh_help() -> void:
	_help_queued = false
	var sections := help_sections()
	var bbcode := _bbcode(sections, false)
	if str(help.get_meta("full_bbcode", "")) == bbcode:
		return  # as fitted already (the fit may show the scrolling one)
	help.set_meta("full_text", help_text(sections))
	help.set_meta("full_bbcode", bbcode)
	help.set_meta("scroll_bbcode", _bbcode(sections, true))
	help.text = bbcode


## What F1 shows: [[heading, [item, ...]], ...]. An item is {a: its actions, w: what it does}, its
## keys the ones bound to them now (Settings → Controls, or Factorio's own keys) and left out when
## none of them has one; {k: fixed keys, w: ...} for the mouse and keys that can't be rebound.
## `r` shows the actions' keys as a range (1-0), `j` joins them otherwise (" / " by default), `all`
## takes each action's alternative key too (the first only otherwise).
## Add-ons' controls come last, under each add-on loaded now (api.keys, ControlsInfo.extra).
static func help_sections() -> Array:
	var quickbar: Array = range(1, 11).map(func(i: int) -> String: return "quickbar_%d" % i)
	var pages: Array = range(1, 11).map(func(i: int) -> String: return "quickbar_page_%d" % i)
	var out: Array = [
		["", [
			{"a": ["toggle_help"], "w": "hide help"},
			{"k": "Keys", "w": "Settings → Controls"}]],
		["Moving and camera", [
			{"a": ["move_up", "move_left", "move_down", "move_right"], "j": "", "w": "walk, or drive"},
			{"a": ["enter_vehicle"], "w": "get in or out (beside a silo: its rocket)"},
			{"k": "Wheel", "w": "zoom"},
			{"k": "Middle mouse drag", "w": "turn and tilt"},
			{"a": ["camera_left", "camera_right"], "w": "turn"},
			{"a": ["camera_tilt_up", "camera_tilt_down"], "w": "tilt"},
			{"a": ["first_person"], "w": "first person"},
			{"a": ["factorio_view"], "w": "Factorio's view"},
			{"a": ["toggle_projection"], "w": "perspective or orthographic"}]],
		["Fighting", [
			{"a": ["shoot_enemies"], "w": "shoot nearby enemies"},
			{"a": ["shoot_cursor"], "w": "shoot at the cursor"},
			{"a": ["next_gun"], "w": "next weapon"}]],
		["Building and mining", [
			{"k": "Left mouse", "w": "build, or open what's under it"},
			{"k": "Right mouse", "w": "mine"},
			{"k": "Shift+left", "w": "ghost"},
			{"k": "Ctrl+Shift+left", "w": "super-forced"},
			{"a": ["rotate", "reverse_rotate"], "w": "rotate"},
			{"a": ["flip_horizontal", "flip_vertical"], "w": "flip"},
			{"a": ["pipette", "clear_cursor"], "w": "pipette, or put away what you hold"},
			{"a": ["drop_item"], "w": "drop one"},
			{"a": ["pick_up"], "w": "pick up from the ground"},
			{"k": "Shift+right / Shift+left", "w": "copy / paste settings"},
			{"k": "Ctrl+left / right", "w": "fast transfer / half"},
			{"k": "Ctrl+wheel", "w": "quality"},
			{"a": ["cycle_quality_up", "cycle_quality_down"], "w": "quality"},
			{"a": ["larger_tile_area", "smaller_tile_area"], "w": "tile area"}]],
		["Blueprints, planners and wires", [
			{"a": ["copy", "cut", "paste"], "w": "copy, cut, paste"},
			{"a": ["undo", "redo"], "w": "undo, redo"},
			{"a": ["give_blueprint"], "w": "blueprint"},
			{"a": ["blueprint_library"], "w": "blueprint library"},
			{"k": "Shift+wheel", "w": "book page"},
			{"a": ["cycle_blueprint_forwards", "cycle_blueprint_backwards"], "w": "book page"},
			{"a": ["give_deconstruction_planner"], "w": "deconstruction planner"},
			{"a": ["give_upgrade_planner"], "w": "upgrade planner"},
			{"k": "Shift+drag", "w": "cancel marks"},
			{"a": ["give_red_wire", "give_green_wire", "give_copper_wire"], "w": "red, green, copper wire"},
			{"a": ["toggle_rail_layer"], "w": "rail layer (rails in hand)"}]],
		["Inventory and crafting", [
			{"a": ["open_screen"], "w": "inventory, or close windows"},
			{"a": ["focus_search"], "w": "search"},
			{"a": quickbar, "r": true, "w": "quickbar (inventory open: pin the hovered item)"},
			{"a": pages, "r": true, "w": "quickbar page"},
			{"a": ["rotate_quickbars"], "w": "swap the quickbars"},
			{"k": "Click a recipe", "w": "craft 1 (right: 5, Shift: all)"},
			{"k": "Shift / Ctrl+click a stack", "w": "move it / all of the kind"},
			{"k": "Middle click a slot", "w": "filter"},
			{"a": ["toggle_personal_logistics", "toggle_personal_roboport", "toggle_equipment_movement_bonus"],
				"w": "logistic requests, roboport, exoskeletons on or off"}]],
		["Windows", [
			{"a": ["open_technology"], "w": "technologies"},
			{"a": ["toggle_map"], "w": "map"},
			{"a": ["production_statistics", "kill_statistics"], "w": "production, kill statistics"},
			{"a": ["logistic_networks"], "w": "logistic networks"},
			{"a": ["toggle_factoriopedia"], "w": "Factoriopedia"},
			{"k": "Alt+click", "w": "its page"},
			{"a": ["toggle_console"], "all": true, "j": " or ", "w": "chat and console"},
			{"a": ["toggle_players"], "w": "players"},
			{"a": ["alt_mode"], "w": "Alt-mode"},
			{"k": "Esc", "w": "close, or the game menu"},
			{"a": ["increase_ui_scale", "decrease_ui_scale", "reset_ui_scale"], "w": "UI scale"}]],
		["Map and remote view", [
			{"a": ["move_up", "move_left", "move_down", "move_right"], "j": "", "w": "move (or drag; Shift: faster)"},
			{"k": "Wheel", "w": "zoom; in past the closest: the 3D remote view there, out again: the map"},
			{"k": "Right click", "w": "remove a ghost, or a tag"},
			{"k": "Double click", "w": "tag"},
			{"k": "Esc", "w": "close the map, or end the remote view"}]],
		["Zenith's own", [
			{"a": ["show_factorio"], "w": "the same game in Factorio"},
			{"a": ["debug_line"], "w": "status line"}]],
	]
	if Settings.dev_tools():
		(out[-1][1] as Array).append({"a": ["debug_menu"], "w": "debug menu (testing tools, dev builds)"})
	for addon in _addon_sections():
		out.append(addon)
	return out


## Each add-on loaded now with its controls (api.keys): its own keys, then those that work only
## while it has the camera (they may be Zenith's own keys, WASD to fly).
static func _addon_sections() -> Array:
	var names: Array = []
	var own := {}
	var camera := {}
	for action in ControlsInfo.extra:
		var name := str(ControlsInfo.extra[action][0])
		if not names.has(name):
			names.append(name)
			own[name] = []
			camera[name] = []
		var item := {"a": [action], "w": _short_label(str(ControlsInfo.extra[action][1]))}
		(camera[name] if str(Settings.contexts.get(action, "global")).ends_with(":camera") else own[name]).append(item)
	var out: Array = []
	for name in names:
		var items: Array = own[name]
		if not (camera[name] as Array).is_empty():
			items.append({"k": "With its camera", "w": ""})
			items.append_array(camera[name])
		out.append(["%s (add-on)" % name, items])
	return out


## An add-on's label for Settings → Controls without its explanation in brackets, lower case after
## the key as the rest of the help ("Free camera on/off (also ends any shot)": "free camera on/off").
static func _short_label(label: String) -> String:
	var cut := label.find(" (")
	var s := label.substr(0, cut) if cut > 0 else label
	if s.length() > 1 and s[1] == s[1].to_lower():  # not an acronym ("UI scale")
		s = s[0].to_lower() + s.substr(1)
	return s


## The keys of an item as shown, "" when none of its actions has a key.
static func _item_keys(item: Dictionary) -> String:
	if item.has("k"):
		return str(item["k"])
	var actions: Array = item["a"]
	if item.get("r", false) and _in_a_row(actions):
		return _range(str(actions[0]), str(actions[-1]))
	var keys: Array = []
	for a in actions:
		for k in (_all_keys(str(a)) if item.get("all", false) else [_key(str(a))]):
			if k != "" and not keys.has(k):
				keys.append(k)
	return str(item.get("j", " / ")).join(keys)


## Every action the help names (the UI test checks each bound one is there).
static func help_actions(sections: Array = []) -> Array:
	var out: Array = []
	for section in (sections if not sections.is_empty() else help_sections()):
		for item: Dictionary in section[1]:
			for a in item.get("a", []):
				if not out.has(a):
					out.append(a)
	return out


## The help as plain text: a heading per line, then "keys: what · keys: what"; an item without keys
## is left out, and so is a heading with nothing under it.
static func help_text(sections: Array = []) -> String:
	var lines: Array = []
	for section in (sections if not sections.is_empty() else help_sections()):
		var parts: Array = []
		for item: Dictionary in section[1]:
			var keys := _item_keys(item)
			if keys != "":
				parts.append(("%s: %s" % [keys, item["w"]]) if str(item["w"]) != "" else keys + ":")
		if parts.is_empty():
			continue
		if str(section[0]) != "":
			lines.append(str(section[0]))
		lines.append(" · ".join(parts))
	return "\n".join(lines)


## The same in Factorio's colours: headings bold in its caption colour, keys in its hints' blue.
## `scrolls`: the first line also says the wheel scrolls it.
static func _bbcode(sections: Array, scrolls: bool) -> String:
	var lines: Array = []
	var key_color := Kit.KEY_TEXT.to_html(false)
	for section in sections:
		var parts: Array = []
		for item: Dictionary in section[1]:
			var keys := _item_keys(item)
			if keys == "":
				continue
			var what := str(item["w"])
			parts.append("[color=#%s]%s[/color]%s" % [key_color, _escape(keys), (": " + _escape(what)) if what != "" else ":"])
		if parts.is_empty():
			continue
		if str(section[0]) == "" and scrolls:
			parts.append("[color=#%s]Wheel here[/color]: scroll" % key_color)
		if str(section[0]) != "":
			lines.append("[b][color=#%s]%s[/color][/b]" % [Kit.CAPTION.to_html(false), _escape(str(section[0]))])
		lines.append(" · ".join(parts))
	return "\n".join(lines)


static func _escape(s: String) -> String:
	return s.replace("[", "[lb]")


## The first key bound to an action, short ("" when none): the last part of "Ctrl+Comma" shortened.
static func _key(action: String) -> String:
	return _short(Controls.keys_text(action).get_slice(" / ", 0))


## Both keys bound to an action (the primary and the alternative), short.
static func _all_keys(action: String) -> Array:
	return Array(Controls.keys_text(action).split(" / ", false)).map(func(k: String) -> String: return _short(k))


static func _short(k: String) -> String:
	var plus := k.rfind("+")
	var last := k.substr(plus + 1)
	return k.substr(0, plus + 1) + str(KEY_SHORT.get(last, last))


## The ten quickbar actions are on 1, 2, ... 9, 0 with the same modifiers (as by default): then the
## help writes "1-0"; rebound otherwise, it lists their keys.
static func _in_a_row(actions: Array) -> bool:
	var first := _key(str(actions[0]))
	var prefix := first.substr(0, first.rfind("+") + 1)
	for i in actions.size():
		if _key(str(actions[i])) != prefix + str((i + 1) % 10):
			return false
	return true


## Two actions' first keys as a range: "1-0", "Shift+1-0" when they share their modifiers.
static func _range(first: String, last: String) -> String:
	var a := _key(first)
	var b := _key(last)
	if a == "" or b == "":
		return a + b
	var pa := a.rfind("+")
	var pb := b.rfind("+")
	if pa >= 0 and pa == pb and a.substr(0, pa) == b.substr(0, pb):
		return a + "-" + b.substr(pb + 1)
	return a + "-" + b


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
