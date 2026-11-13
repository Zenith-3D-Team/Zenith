extends RefCounted
## api.shaders (1.3): looks and full-screen shader passes, drawn only (docs/ADDONS.md).
##
## A look is how the world is lit, tonemapped and graded (scripts/world/looks.gd has every key):
## an add-on adds its own, and the player picks it in Settings > Graphics > Look beside Zenith's
## Factorio and Classic looks (or the add-on puts it on with use_look). A pass is a spatial shader
## covering the screen that reads the solid scene and draws over it (include
## res://shaders/look_pass.gdshaderinc); a look can carry its own, and add_pass shows one over
## whichever look is on. Everything goes when the add-on is switched off.
##
##   api.shaders.add_look("my-addon/sunset", {
##       "name": "Sunset", "tonemap": Environment.TONE_MAPPER_AGX, "exposure": 1.1,
##       "environment": {"glow_enabled": true},
##       "passes": [{"shader": "shaders/grade.gdshader", "params": {"warmth": 0.3}}],
##   })

const Looks := preload("res://scripts/world/looks.gd")
const Settings := preload("res://scripts/menu/settings.gd")

var _host
var _api
var _passes: Array[int] = []


func _init(host, api) -> void:
	_host = host
	_api = api


## Adds (or replaces, if the add-on added it before) a look. A pass's shader may be a Shader or a
## path; a relative path is in the add-on's folder. False when the id is someone else's.
func add_look(id: String, look: Dictionary) -> bool:
	var spec := look.duplicate(true)
	var passes: Array = []
	for p in spec.get("passes", []):
		var q: Dictionary = (p as Dictionary).duplicate()
		q["shader"] = _resolve(q.get("shader"))
		passes.append(q)
	spec["passes"] = passes
	return Looks.register(id, spec, _api.id)


func remove_look(id: String) -> void:
	if Looks.looks.has(id) and str(Looks.looks[id].get("owner", "")) == _api.id:
		Looks.looks.erase(id)
		Looks.order.erase(id)
		if str(Settings.get_value("graphics", "look")) == id:
			_go_back()
		elif Looks.active != null and Looks.active.current == id:
			Looks.active.use("factorio")


## Puts a look on, as if the player had picked it in Settings (it is kept for the next start). An
## add-on's own look remembers the one it replaced, which comes back when the add-on is switched off.
func use_look(id: String) -> bool:
	if not Looks.looks.has(id):
		return false
	var was := str(Settings.get_value("graphics", "look"))
	if _mine(id) and not _mine(was):
		Settings.set_value("graphics", "look_before", was)
	Settings.set_value("graphics", "look", id)
	if Looks.active != null:
		Looks.active.use_setting(id)
	return true


## The sun now, for add-ons that want the numbers in script (1.5): {elevation (degrees), height (its
## sine), twilight (0-1, what the look asked for), morning, direction (towards the sun), color,
## ambient, fog}; empty without a game.
func sun() -> Dictionary:
	return Looks.active.sun_state.duplicate() if Looks.active != null else {}


## The look in use now ("factorio" without a game).
func current_look() -> String:
	return Looks.active.current if Looks.active != null else str(Settings.get_value("graphics", "look"))


## [[name, id]...] of every look, Zenith's and add-ons'.
func looks() -> Array:
	return Looks.choices()


## A pass over whichever look is on, in every game until removed: `shader` a Shader or a path
## (relative: in the add-on's folder), `params` its uniforms. Its id, or 0 when the shader isn't a
## spatial shader.
func add_pass(shader: Variant, params := {}, order := 0) -> int:
	var id := Looks.add_pass({"shader": _resolve(shader), "params": params, "order": order}, _api.id)
	if id != 0:
		_passes.append(id)
	return id


## A uniform of one of the add-on's passes; with id 0, of every pass of the look in use (when the
## look is the add-on's own).
func set_parameter(pass_id: int, param: String, value: Variant) -> void:
	if pass_id == 0:
		var cur := current_look()
		if not Looks.looks.has(cur) or str(Looks.looks[cur].get("owner", "")) != _api.id:
			return
	elif not _passes.has(pass_id):
		return
	Looks.set_parameter(pass_id, param, value)


func remove_pass(pass_id: int) -> void:
	if _passes.has(pass_id):
		Looks.remove_pass(pass_id)
		_passes.erase(pass_id)


## Everything the add-on added, gone (it was switched off).
func clear() -> void:
	var was_on := _mine(str(Settings.get_value("graphics", "look")))
	Looks.remove_owner(_api.id)
	_passes.clear()
	if was_on:
		_go_back()


func _mine(id: String) -> bool:
	return Looks.looks.has(id) and str(Looks.looks[id].get("owner", "")) == _api.id


## The look the player had before this add-on's, back in Settings and on screen.
func _go_back() -> void:
	Looks.choices()  # Zenith's own are listed even before a game
	var back := str(Settings.get_value("graphics", "look_before"))
	if not Looks.looks.has(back):
		back = "factorio"
	Settings.set_value("graphics", "look", back)
	if Looks.active != null:
		Looks.active.use_setting(back)


func _resolve(shader: Variant) -> Variant:
	if shader is String and not (shader as String).begins_with("res://") and not (shader as String).is_absolute_path():
		return str(_api.dir).path_join(shader)
	return shader
