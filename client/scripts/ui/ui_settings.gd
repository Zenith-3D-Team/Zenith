extends RefCounted
## The UI's options with their limits, as keys "section/key" (e.g. "map/minimap"), and a `changed`
## signal for whoever uses them. They are kept with every other setting in settings.gd's file
## (`user://settings.cfg`, section [map]); this is the view the HUD uses. One shared instance:
## `UiSettings.shared()`. The Settings window and the map view's own switches change them;
## `changed` fires however they were changed.
##
##   [map]
##   minimap=true          show the minimap in the top-right corner
##   minimap_size=240      its side in Factorio GUI pixels (times the UI scale), 120 to 480
##   minimap_zoom=1.0      screen (GUI) pixels per tile, 0.25 to 4; Shift + wheel over the minimap changes it
##   minimap_tags=true     map tags on the minimap
##   show_tags=true        map view switches (Factorio's map view settings), on the map view only
##   show_electric=true      (Factorio's minimap shows none of them): tags, electric networks,
##   show_logistic=true      logistic networks, turret coverage, train stop names, worker robots,
##   show_turrets=false      rail signal states, recipe icons
##   show_stops=true
##   show_robots=true
##   show_signals=false
##   show_recipes=false
##   show_pollution=false  pollution over the map, red as in Factorio
##
## docs/RUNNING.md lists them too.

signal changed(key: String)

const Settings := preload("res://scripts/menu/settings.gd")

## Default, minimum, maximum (no range for booleans).
const OPTIONS := {
	"map/minimap": [true],
	"map/minimap_size": [240, 120, 480],
	"map/minimap_zoom": [1.0, 0.25, 4.0],
	"map/minimap_tags": [true],
	"map/show_tags": [true],
	"map/show_electric": [true],
	"map/show_logistic": [true],
	"map/show_turrets": [false],
	"map/show_stops": [true],
	"map/show_robots": [true],
	"map/show_signals": [false],
	"map/show_recipes": [false],
	"map/show_pollution": [false],
}
## The map view switches in Factorio's order, with Factorio's names ([gui-map-view-settings]).
const MAP_LAYERS := [
	["map/show_tags", "Tags"],
	["map/show_electric", "Electric networks"],
	["map/show_logistic", "Logistic networks"],
	["map/show_turrets", "Turret coverage"],
	["map/show_stops", "Train stop names"],
	["map/show_robots", "Worker robots"],
	["map/show_signals", "Rail signal states"],
	["map/show_recipes", "Recipe icons"],
	["map/show_pollution", "Pollution"],
]

static var _shared = null


static func shared():
	if _shared == null:
		_shared = new()
		Settings.listen(_shared._on_settings_changed)
	return _shared


func _on_settings_changed(section: String, key: String) -> void:
	changed.emit(section + "/" + key)


func get_value(key: String) -> Variant:
	var fallback = OPTIONS[key][0] if OPTIONS.has(key) else null
	var section := key.get_slice("/", 0)
	var name := key.get_slice("/", 1)
	if not Settings.has_value(section, name) and Settings.DEFAULTS.get(section, {}).get(name) == null and Settings.factorio_default(section, name) == null:
		return fallback
	return _clean(key, Settings.get_value(section, name)) if OPTIONS.has(key) else Settings.get_value(section, name)


## Changes an option now; `persist` writes the file too (a slider can wait for its release).
func set_value(key: String, value: Variant, persist := true) -> void:
	if not OPTIONS.has(key):
		push_warning("ui settings: no option %s" % key)
		return
	var v = _clean(key, value)
	if v == get_value(key):
		if persist:
			Settings.save()
		return
	Settings.set_value(key.get_slice("/", 0), key.get_slice("/", 1), v, persist)


func _clean(key: String, value: Variant) -> Variant:
	var spec: Array = OPTIONS[key]
	var default = spec[0]
	if default is bool:
		return bool(value)
	if default is int:
		return clampi(int(value), spec[1], spec[2])
	return clampf(float(value), spec[1], spec[2])
