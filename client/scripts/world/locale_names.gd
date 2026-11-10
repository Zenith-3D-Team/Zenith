extends RefCounted
## Names as the player sees them ("Iron gear wheel"), read from the locale files in the player's
## own Factorio install (<data>/<mod>/locale/<language>/*.cfg). The mod can only send internal
## names: a headless server has no player to translate for. Without an install, internal names
## are tidied up instead ("iron-gear-wheel" -> "Iron gear wheel").
##
## Command-line option (after `--`): --factorio-locale=<language> (default en).

const ItemIcons := preload("res://scripts/world/item_icons.gd")
const ModFiles := preload("res://scripts/world/mod_files.gd")

static var language := "en"
static var _sections := {}  # "item-name" -> {key: text}
static var _loaded := false
static var _mods_loaded := -1  # ModFiles.generation whose mods' locale is in _sections


static func configure_from_command_line() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--factorio-locale="):
			language = arg.get_slice("=", 1)


static func item(name: String) -> String:
	return _first(name, ["item-name", "entity-name", "equipment-name", "fluid-name"])


static func entity(name: String) -> String:
	return _first(name, ["entity-name", "item-name"])


static func recipe(name: String) -> String:
	return _first(name, ["recipe-name", "item-name", "fluid-name", "entity-name"])


## Planets and other places in space ("Vulcanus", "Solar system edge").
static func space_location(name: String) -> String:
	return _first(name, ["space-location-name"])


## Levelled technologies ("logistics-2") are their base name plus the level.
static func technology(name: String) -> String:
	_load()
	var text := _lookup("technology-name", name)
	if text != "":
		return text
	var m := RegEx.create_from_string("^(.*)-(\\d+)$").search(name)
	if m != null:
		var base := _lookup("technology-name", m.get_string(1))
		if base != "":
			return "%s %s" % [base, m.get_string(2)]
	return _tidy(name)


## A LocalisedString as Factorio writes it: a plain string, or [key, params...] where the key is
## "section.name" ("" joins the params, "?" takes the first that resolves) and __1__, __2__... take
## the params. Mods' windows send their captions this way (mod_gui.gd).
static func localise(v) -> String:
	if v == null:
		return ""
	if v is String:
		return v
	if v is float or v is int:
		var f := float(v)
		return str(int(f)) if f == floorf(f) else str(f)
	if v is bool:
		return "true" if v else "false"
	if not (v is Array) or (v as Array).is_empty():
		return ""
	var a: Array = v
	var key := str(a[0])
	var params := a.slice(1)
	if key == "":
		var joined := ""
		for p in params:
			joined += localise(p)
		return joined
	if key == "?":
		for p in params:
			var text := localise(p)
			if text != "" and not text.begins_with("Unknown key"):
				return text
		return ""
	_load()
	var dot := key.find(".")
	var text := _lookup(key.substr(0, dot), key.substr(dot + 1)) if dot > 0 else ""
	if text == "":
		return "Unknown key: \"%s\"" % key
	text = _plurals(text, params)
	for i in params.size():
		text = text.replace("__%d__" % (i + 1), localise(params[i]))
	return _macros(text.replace("\\n", "\n"))


## Factorio's __plural_for_parameter__N__{1=day|rest=days}__: the form whose condition the Nth
## parameter meets (a number or comma-separated numbers, "ends in N", or "rest").
static func _plurals(text: String, params: Array) -> String:
	if not text.contains("__plural_for_parameter"):
		return text
	var re := RegEx.create_from_string("__plural_for_parameter__(\\d+)__\\{([^}]*)\\}__")
	for m in re.search_all(text):
		var n := int(m.get_string(1))
		var value := localise(params[n - 1]) if n >= 1 and n <= params.size() else ""
		var chosen := ""
		for option in m.get_string(2).split("|"):
			var eq := option.find("=")
			if eq < 0:
				continue
			var hit := false
			for cond in option.substr(0, eq).split(","):
				cond = cond.strip_edges()
				if cond == "rest" or cond == value or (cond.begins_with("ends in ") and value.ends_with(cond.substr(8))):
					hit = true
			if hit:
				chosen = option.substr(eq + 1)
				break
		text = text.replace(m.get_string(0), chosen)
	return text


## Factorio's __CONTROL__name__ (the key bound to a control) as the control's name in brackets:
## which key the player bound lives in Factorio's own settings, not the locale.
static func _macros(text: String) -> String:
	if not text.contains("__CONTROL"):
		return text
	var re := RegEx.create_from_string("__CONTROL(?:_STYLE_BEGIN|_STYLE_END|_LEFT_CLICK|_RIGHT_CLICK|_MOVE)?__([^_]+(?:_[^_]+)*)__")
	for m in re.search_all(text):
		var control := m.get_string(1)
		var shown := _lookup("controls", control)
		text = text.replace(m.get_string(0), shown if shown != "" else control)
	return text


static func _first(name: String, sections: Array) -> String:
	_load()
	for section in sections:
		var text := _lookup(section, name)
		if text != "":
			return text
	return _tidy(name)


## References like __ITEM__iron-plate__ are replaced by that name.
static func _lookup(section: String, key: String) -> String:
	var table: Dictionary = _sections.get(section, {})
	var text := str(table.get(key, ""))
	if text.contains("__"):
		var re := RegEx.create_from_string("__(ITEM|ENTITY|FLUID|RECIPE|TILE)__([^_]+(?:_[^_]+)*)__")
		for m in re.search_all(text):
			var kind := m.get_string(1).to_lower() + "-name"
			var other := str((_sections.get(kind, {}) as Dictionary).get(m.get_string(2), m.get_string(2)))
			text = text.replace(m.get_string(0), other)
	return text


static func _tidy(name: String) -> String:
	var words := name.replace("-", " ")
	return words.substr(0, 1).to_upper() + words.substr(1)


## The built-in mods' locale, then each of the game's other mods' (the bridge's welcome names them;
## mod_files.gd reads them from their folders or zips) once they have been found: English first and
## the chosen language over it, as Factorio falls back to English. Read again when the mods change.
static func _load() -> void:
	var key := ModFiles.generation if ModFiles.is_ready() and not ModFiles.active_mods().is_empty() else -1
	if _loaded and (key == -1 or key == _mods_loaded):
		return
	if _loaded:
		_sections = {}
	_loaded = true
	_mods_loaded = key
	var data := ItemIcons.factorio_data_dir()
	if data != "":
		for mod in ItemIcons.MODS:
			var dir := data.path_join(mod).path_join("locale").path_join(language)
			if not DirAccess.dir_exists_absolute(dir):
				continue
			for file in DirAccess.get_files_at(dir):
				if file.ends_with(".cfg"):
					_parse(FileAccess.get_file_as_string(dir.path_join(file)))
	if key == -1:
		return
	# After the built-in mods, so a mod's own names for the game's things win, as in Factorio.
	var names: Array = ModFiles.active_mods().keys()
	names.sort()
	for mod: String in names:
		if mod in ItemIcons.MODS or mod == "core" or ModFiles.locate(mod).get("built_in", false):
			continue
		for lang in (["en", language] if language != "en" else ["en"]):
			for path in ModFiles.files_in(mod, "locale/" + lang):
				if path.ends_with(".cfg"):
					_parse(ModFiles.read(path).get_string_from_utf8())


## [section] headers, key=value lines; anything before the first header is skipped.
static func _parse(text: String) -> void:
	var section := ""
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line == "" or line.begins_with(";") or line.begins_with("#"):
			continue
		if line.begins_with("[") and line.ends_with("]"):
			section = line.substr(1, line.length() - 2)
			if not _sections.has(section):
				_sections[section] = {}
			continue
		var eq := line.find("=")
		if section != "" and eq > 0:
			_sections[section][line.substr(0, eq)] = line.substr(eq + 1)
