extends RefCounted
## The settings the player set in Factorio's own Settings window, read from Factorio's config.ini
## (the file factorio_keys.gd finds), so Zenith starts out the way the player's Factorio is:
## settings.gd takes them as its defaults. A setting changed in Zenith's Settings still wins, and
## its Default goes back to Factorio's. Off with Settings → Factorio install → "Use the settings
## set in Factorio".
##
## config.ini writes every setting left at Factorio's default as a "; key=value" comment, and a
## changed one without the "; ", under its section: [general] locale=de, [sound]
## master-volume=0.300000, [graphics] show-clouds=false, [interface] ui-scale-mode=custom with
## custom-ui-scale=1.25 (before config version 12: automatic-ui-scale=false with ui-scale=1.25),
## [other] autosave-interval=5. Only the changed lines are taken. Factorio settings Zenith has no
## counterpart for are left out, as are those whose values don't mean the same in both (brightness,
## contrast and saturation, the tooltip delay).

## Factorio's "section/key" -> [Zenith's section, key, kind]. Kinds: "volume" (0 to 1), "bool",
## "minutes" (an int, 0: never).
const MAP := {
	"sound/master-volume": ["sound", "master", "volume"],
	"sound/game-effects-volume": ["sound", "effects", "volume"],
	"sound/music-volume": ["sound", "music", "volume"],
	"sound/gui-effects-volume": ["sound", "ui", "volume"],
	"sound/walking-sound-volume": ["sound", "walking", "volume"],
	"sound/environment-sounds-volume": ["sound", "environment", "volume"],
	"sound/weapons-volume": ["sound", "weapons", "volume"],
	"sound/explosions-volume": ["sound", "explosions", "volume"],
	"sound/enemies-volume": ["sound", "enemies", "volume"],
	"sound/world-ambient-volume": ["sound", "ambient", "volume"],
	"graphics/v-sync": ["graphics", "vsync", "bool"],
	"graphics/minimize-on-focus-loss": ["graphics", "minimize_on_focus_loss", "bool"],
	"graphics/show-clouds": ["graphics", "clouds", "bool"],
	"graphics/show-decoratives": ["graphics", "decoratives", "bool"],
	"interface/smart-belt-building": ["interface", "smart_belt_building", "bool"],
	"interface/lock-belt-building-to-straight-line": ["interface", "lock_belt_straight", "bool"],
	"interface/show-inserter-arrows-when-detailed-info-is-on": ["interface", "alt_inserter_arrows", "bool"],
	"interface/show-pump-arrows-when-detailed-info-is-on": ["interface", "alt_pump_arrows", "bool"],
	"interface/show-machine-arrows-when-detailed-info-is-on": ["interface", "alt_machine_arrows", "bool"],
	"interface/show-minimap": ["map", "minimap", "bool"],
	"other/autosave-interval": ["factorio", "autosave_interval", "minutes"],
}

## Zenith's UI scale choices (settings_window.gd); Factorio's custom scale goes to the nearest.
const UI_SCALES := ["0.75", "1.0", "1.25", "1.5", "1.75", "2.0"]
## Factorio's colour filters, by the names Zenith's color_filter.gd uses too.
const COLOR_FILTERS := ["protanopia", "deuteranopia", "tritanopia", "protanopia-correction",
	"deuteranopia-correction", "tritanopia-correction"]


## {Zenith section: {key: value}} for what is set in Factorio's config.ini, or {} without one.
## The language is under "general": "locale" (not a Zenith setting: locale_names.gd's).
static func read() -> Dictionary:
	var file: String = load("res://scripts/player/factorio_keys.gd").config_path()
	if file == "":
		return {}
	return values_from(FileAccess.get_file_as_string(file))


## The same from config.ini's text.
static func values_from(text: String) -> Dictionary:
	var lines := parse(text)
	var out := {}
	for name in lines:
		if not MAP.has(name):
			continue
		var to: Array = MAP[name]
		var raw: String = lines[name]
		var value: Variant
		match str(to[2]):
			"volume":
				if not raw.is_valid_float():
					continue
				value = clampf(raw.to_float(), 0.0, 1.0)
			"bool":
				if raw != "true" and raw != "false":
					continue
				value = raw == "true"
			"minutes":
				if not raw.is_valid_int():
					continue
				value = maxi(0, raw.to_int())
		_put(out, to[0], to[1], value)
	# Factorio's "Show all smoke" and "Show particles" are Zenith's one effects switch.
	if lines.get("graphics/show-smoke", "") == "false" or lines.get("graphics/show-particles", "") == "false":
		_put(out, "graphics", "effects", false)
	elif lines.get("graphics/show-smoke", "") == "true" or lines.get("graphics/show-particles", "") == "true":
		_put(out, "graphics", "effects", true)
	if lines.has("graphics/full-screen"):
		_put(out, "graphics", "window_mode", "fullscreen" if lines["graphics/full-screen"] == "true" else "windowed")
	var filter: String = lines.get("graphics/color-filter", "")
	if lines.has("graphics/color-filter"):
		_put(out, "graphics", "color_filter", filter if filter in COLOR_FILTERS else "none")
	var scale := _ui_scale(lines)
	if scale != "":
		_put(out, "interface", "ui_scale", scale)
	var locale: String = lines.get("general/locale", "")
	if locale != "" and locale != "auto":
		_put(out, "general", "locale", locale)
	return out


## Zenith's ui_scale from Factorio's interface lines: "auto", one of UI_SCALES, or "" (not set).
static func _ui_scale(lines: Dictionary) -> String:
	var custom := ""
	if lines.has("interface/ui-scale-mode"):  # config version 12 on
		if lines["interface/ui-scale-mode"] != "custom":
			return "auto"
		custom = lines.get("interface/custom-ui-scale", "1")
	elif lines.has("interface/automatic-ui-scale"):
		if lines["interface/automatic-ui-scale"] == "true":
			return "auto"
		custom = lines.get("interface/ui-scale", "1")
	else:
		return ""
	if not custom.is_valid_float():
		return ""
	var best := ""
	for s in UI_SCALES:
		if best == "" or absf(s.to_float() - custom.to_float()) < absf(best.to_float() - custom.to_float()):
			best = s
	return best


## config.ini's set lines (not "; " comments) as "section/key" -> value, [controls] left out.
static func parse(text: String) -> Dictionary:
	var out := {}
	var section := ""
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("["):
			section = line.trim_prefix("[").trim_suffix("]").strip_edges()
			continue
		if section == "controls" or section == "path" or line == "" or line.begins_with(";") or line.begins_with("#"):
			continue
		var eq := line.find("=")
		if eq <= 0:
			continue
		out[section + "/" + line.substr(0, eq).strip_edges()] = line.substr(eq + 1).strip_edges()
	return out


static func _put(out: Dictionary, section: String, key: String, value: Variant) -> void:
	if not out.has(section):
		out[section] = {}
	out[section][key] = value
