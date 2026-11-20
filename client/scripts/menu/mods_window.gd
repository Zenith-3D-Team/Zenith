extends PanelContainer
## Factorio's Mods window for the server the menu starts: the game's own mods (base and the DLC
## from the install's data folder) and the mods in the server's mods folder (zips and folders),
## each with its version (the highest, when the folder has several) and an on/off box. Changes are
## kept as the player's choices (mod_choices.gd), which apply the next time a server starts: a new
## game gets them, a loaded save gets them added to its own. The bridge mod is always on. Space Age
## needs Quality and Elevated rails, as in Factorio; turning one on or off carries the others along.
## In a game it shows what the server runs, read-only.

signal closed

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const MenuKit := preload("res://scripts/menu/menu_kit.gd")
const Paths := preload("res://scripts/menu/paths.gd")
const Sfx := preload("res://scripts/fx/sfx.gd")
const ModChoices := preload("res://scripts/menu/mod_choices.gd")

const BRIDGE := "factorio-3d-bridge"
const DLC := ["base", "elevated-rails", "quality", "space-age"]
## mod -> the mods it needs (Factorio's DLC dependencies).
const NEEDS := {"space-age": ["quality", "elevated-rails"]}

## While a game runs the list is shown but not changed (Factorio's own window does the same).
var read_only := false
## Zenith's add-ons (scripts/addons/addon_host.gd), listed after the mods with their own switches,
## which apply at once, in a game too; null leaves them out.
var addons = null

var _mods: Array = []  # [{name, title, version, source, enabled}]
var _list: VBoxContainer
var _boxes := {}  # name -> CheckBox


func _ready() -> void:
	theme_type_variation = "FFrame"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Kit.px(8))
	add_child(box)
	var bar := Kit.title_bar("Mods", true)
	box.add_child(bar)
	(bar.get_child(bar.get_child_count() - 1) as Button).pressed.connect(func() -> void: closed.emit())
	var where := MenuKit.paragraph(("The mods this game runs (%s)." if read_only else
		"The server's mods (%s). The mods turned on here are in every new game and are added to a game you load (Load game's Sync mods with save leaves them out); a loaded game keeps its own Space Age and DLC.") % Paths.server_data_dir().path_join("mods"), 560)
	where.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	box.add_child(where)
	var deep: Array = Kit.deep_scroll(Kit.pxv(560, 360))
	box.add_child(deep[0])
	_list = VBoxContainer.new()
	_list.name = "List"
	_list.add_theme_constant_override("separation", Kit.px(2))
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	deep[1].add_child(_list)
	var row: Array = MenuKit.dialog_buttons("Back", "")
	box.add_child(row[0])
	(row[1] as Button).pressed.connect(func() -> void:
		Sfx.play_ui("gui-back")
		closed.emit())
	_mods = scan(read_only)
	_fill()


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.physical_keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		closed.emit()


## Every mod the server could load, once each (a folder holding several versions shows the highest,
## which Factorio runs unless a save asks for another), on or off as the player chose
## (mod_choices.gd); `running`: as the server's mod-list.json has them, the mods a game runs (on
## when not listed, as Factorio does).
static func scan(running := false) -> Array:
	var choices := _list_states() if running else ModChoices.states()
	var out: Array = []
	var data := Paths.read_data_dir(Paths.factorio_exe())
	for name in DLC:
		var info := ModChoices.info_at(data.path_join(name))
		if not info.is_empty():
			out.append(_entry(name, info, "game", choices, running))
	var mods_dir := Paths.server_data_dir().path_join("mods")
	var found := ModChoices.folder(mods_dir)
	var names := found.keys()
	names.sort_custom(func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0)
	var bridge := ModChoices.info_at(mods_dir.path_join(BRIDGE))
	if not bridge.is_empty():
		out.append(_entry(BRIDGE, bridge, "folder", choices, running))
	for name in names:
		var versions: Dictionary = found[name]
		var at := str(versions[ModChoices.highest(versions.keys())])
		var info := ModChoices.info_of(at)
		if not info.is_empty():
			out.append(_entry(name, info, "zip" if at.to_lower().ends_with(".zip") else "folder", choices, running))
	return out


static func _entry(name: String, info: Dictionary, source: String, choices: Dictionary, running: bool) -> Dictionary:
	var on := bool(choices.get(name, true)) if running else ModChoices.is_on(name, choices)
	return {"name": name, "title": str(info.get("title", name)), "version": str(info.get("version", "")),
		"source": source, "enabled": name == BRIDGE or on}


## The server's mod-list.json as name -> enabled: what the server last ran.
static func _list_states() -> Dictionary:
	var out := {}
	var file := Paths.server_data_dir().path_join("mods/mod-list.json")
	if not FileAccess.file_exists(file):
		return out
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(file))
	if parsed is Dictionary:
		for m in parsed.get("mods", []):
			if m is Dictionary:
				out[str(m.get("name", ""))] = bool(m.get("enabled", true))
	return out


## Keeps the window's states as the player's choices, with those of mods not found here.
static func write_states(mods: Array) -> void:
	var choices := ModChoices.states()
	for m in mods:
		choices[m["name"]] = bool(m["enabled"])
	ModChoices.write(choices)


## Turns a mod on or off, with the DLC that go with it.
func set_enabled(name: String, on: bool) -> void:
	var change := {name: on}
	if on:
		for need in NEEDS.get(name, []):
			change[need] = true
	else:
		for other in NEEDS:
			if (NEEDS[other] as Array).has(name):
				change[other] = false
	for m in _mods:
		if change.has(m["name"]) and m["name"] != BRIDGE and m["name"] != "base":
			m["enabled"] = change[m["name"]]
	write_states(_mods)
	_fill()


func _fill() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	_boxes.clear()
	var last := ""
	for m in _mods:
		var group := "Factorio" if m["source"] == "game" else "Mods"
		if group != last:
			last = group
			_list.add_child(Kit.label(group, "FHeading"))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", Kit.px(8))
		var c := MenuKit.checkbox("", bool(m["enabled"]))
		c.name = str(m["name"])
		c.disabled = read_only or m["name"] in [BRIDGE, "base"]
		if m["name"] == BRIDGE:
			c.tooltip_text = "The bridge to the 3D client is always on."
		var name: String = m["name"]
		c.toggled.connect(func(on: bool) -> void:
			Sfx.play_ui("gui-checkbox-click")
			set_enabled(name, on))
		row.add_child(c)
		var title := Kit.label(str(m["title"]))
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(title)
		var version := Kit.label(str(m["version"]))
		version.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		row.add_child(version)
		_list.add_child(row)
		_boxes[name] = c
	if read_only:
		var n := MenuKit.paragraph("Leave the game to change the mods.", 520)
		n.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		_list.add_child(n)
	if addons != null:
		_fill_addons()


## Zenith's add-ons: each with its switch (at once, in a game too), version, and why it isn't
## running when it can't; Options shows a running add-on's own settings under it.
func _fill_addons() -> void:
	_list.add_child(Kit.label("Zenith add-ons", "FHeading"))
	var found: Array = addons.addons
	if found.is_empty():
		var n := MenuKit.paragraph("None installed. An add-on is a folder put in %s (docs/ADDONS.md)." % ProjectSettings.globalize_path("user://addons"), 520)
		n.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		_list.add_child(n)
		return
	for m: Dictionary in found:
		var id := str(m["id"])
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", Kit.px(8))
		var c := MenuKit.checkbox("", m.has("object"))
		c.name = "addon-" + id
		c.disabled = not bool(m["ok"]) or str(m["source"]) == "command line"
		if str(m["source"]) == "command line":
			c.tooltip_text = "Given with --addons: always on."
		c.toggled.connect(func(on: bool) -> void:
			Sfx.play_ui("gui-checkbox-click")
			addons.set_enabled(id, on)
			_fill())
		row.add_child(c)
		var title := Kit.label(str(m["name"]))
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		title.tooltip_text = "%s\n%s" % [str(m["description"]), str(m["dir"])]
		title.mouse_filter = Control.MOUSE_FILTER_PASS
		row.add_child(title)
		var options: Callable = m["object"].ui._options_builder() if m.has("object") else Callable()
		var holder := VBoxContainer.new()
		if options.is_valid():
			var b := MenuKit.button("Options")
			b.name = "addon-options-" + id
			b.pressed.connect(func() -> void:
				Sfx.play_ui("gui-click")
				if holder.get_child_count() > 0:
					for ch in holder.get_children():
						ch.queue_free()
				else:
					options.call(holder))
			row.add_child(b)
		var version := Kit.label(str(m["version"]))
		version.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		row.add_child(version)
		_list.add_child(row)
		var why := str(m.get("error", m["problem"]))
		if why != "":
			var n := Kit.label("Not loaded: " + why)
			n.name = "addon-problem-" + id
			n.add_theme_color_override("font_color", Kit.RED_TEXT)
			_list.add_child(n)
		_list.add_child(holder)
