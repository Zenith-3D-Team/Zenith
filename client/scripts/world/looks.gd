extends Node3D
## Looks: how the 3D world is lit, tonemapped and graded, picked in Settings > Graphics > Look and
## open to add-ons (api.shaders, docs/ADDONS.md).
##
## A look is a Dictionary (every key optional):
##   name, description          for the settings' list
##   tonemap                    Environment.TONE_MAPPER_*; exposure, white: its exposure and white point
##   sun_energy, ambient_energy multipliers on the planet's light for the time of day (sky.gd)
##   ambient_tint               Color the planet's ambient colour moves towards, by ambient_tint_amount
##   sun_angle                  Vector2(pitch, yaw) in degrees: the sun held there (Factorio's shadows
##                              don't move), or absent for sky.gd's sun that crosses the sky
##   factorio_lut               true: Factorio's own colour lookup for the planet and time of day
##   model_fill                 light from the camera's side on models only (Factorio's sprites are lit
##                              so), faded out by night
##   ground_specular            0-1: how much the ground, decals and grass reflect (1: as Zenith draws them)
##   roughness_min              0-1: no model's surface shinier than this (small shiny parts, bolts,
##                              arms, belt rollers, flash highlights smaller than a pixel as they move)
##   roughness_limiter          Vector2(amount, limit): Godot's screen-space roughness limiter while the
##                              look is on (absent: as the project has it)
##   taa                        true: temporal anti-aliasing while the look is on, whatever Settings says
##   own_clouds                 false: Zenith's own clouds are off while the look is on (it draws its own)
##   twilight                   0-1: how much of a real sunrise and sunset it gets (sky.gd's sun that
##                              sets, its colour through the air, the ambient, the sky); absent or 0:
##                              the old sun that never sets
##   sky_twilight               0-1: the same for the sky alone (a look may hold its light still and
##                              still see the sun set); absent: as twilight
##   at_twilight, at_dawn       {environment: {}, sun: {}, params: {}}: values of those three that the
##                              look moves towards as the sun nears the horizon (at_dawn in the
##                              morning, over at_twilight's); numbers and colours only
##   fog_from_sky               0-1: how far the fog's colour takes the sky's on the sun's side at twilight
##   environment                {Environment property: value} set while the look is on
##   sun                        {DirectionalLight3D property: value}, only SUN_KEYS
##   passes                     [{shader: Shader or "res://..."/add-on path, params: {}}] full-screen passes
##
## The look in use is applied every frame after sky.gd has set the planet's light (main.gd), so its
## multipliers act on the light of that moment. Passes are full-screen quads in the transparent pass
## (shaders/look_pass.gdshaderinc): each reads the scene as it was before see-through things were
## drawn (Godot copies the screen once), so smoke, ghosts and icons stay ungraded.

const LookLuts := preload("res://scripts/world/look_luts.gd")
const Settings := preload("res://scripts/menu/settings.gd")

signal look_changed(id: String)

## On a space platform, whatever the look: no air, so no haze or fog (a look's fog, lit and seen
## against the sky, turned black space grey-blue) and no sky lighting the shade. The look's own
## values come back on the ground.
const SPACE_ENV := {"fog_enabled": false, "ambient_light_sky_contribution": 0.0}

## Properties of the sun a look may set (the rest belong to sun_shadows.gd and sky.gd).
const SUN_KEYS := ["light_angular_distance", "shadow_opacity", "light_specular", "light_indirect_energy",
	"shadow_bias", "shadow_normal_bias"]

## Measured against Factorio's own picture of the same scene at noon (tools/look/factorio_reference.py,
## a seed-123456 map in 2.1.24, Zenith's default settings): the open ground's colour 92.5/68.7/28.8
## against Factorio's 89.8/68.4/28.5, saturation 0.689 against 0.688 (Classic: 129.6/100.7/54.3,
## 0.573). What had washed the picture out: the sky's reflection on every surface (a grey-blue sheen
## on the ground, saturation 0.54 -> 0.69 without it) and the filmic tonemapper's shoulder; the
## sun's glare is a quarter of Godot's. Factorio's shadows are about half as bright as lit ground
## on screen (0.51, a quarter of its light), so the ambient is lower and the sun stronger, and they
## fall to the east, a little south, as long as the thing is tall: the sun held there.
const FACTORIO := {
	"name": "Factorio",
	"description": "Lit and coloured to match Factorio's own pictures: its shadows' angle and darkness, its colours unwashed, its colour grading per planet and time of day.",
	"tonemap": Environment.TONE_MAPPER_LINEAR, "exposure": 0.9, "white": 1.0,
	"sun_energy": 1.45, "ambient_energy": 0.36,
	"ambient_tint": Color(0.8, 0.8, 0.82), "ambient_tint_amount": 0.5,
	"sun_angle": Vector2(-42.0, -112.0),
	"factorio_lut": true,
	# Factorio draws no sky, so seen from low down the sun may set, restrained, while the light stays.
	"twilight": 0.0, "sky_twilight": 0.35,
	"ground_specular": 0.45, "model_fill": 1.1,
	"sun": {"light_specular": 0.25},
}
## Zenith's look before 0.1.4: filmic tonemapping, the sun crossing the sky.
const CLASSIC := {
	"name": "Classic Zenith",
	"description": "Zenith's look before: filmic tonemapping, a sun that crosses the sky.",
	"tonemap": Environment.TONE_MAPPER_FILMIC, "exposure": 1.0, "white": 1.0,
	"sun_energy": 1.0, "ambient_energy": 1.0,
}

## Every look, shared by the menu's settings and the game: id -> look Dictionary (add-ons' looks
## carry "owner", their add-on id), in the order they were added.
static var looks := {}
static var order: Array[String] = []
## The node drawing the game's look, while a game is on.
static var active: Node = null

var env: Environment
var sun: DirectionalLight3D
var current := "factorio"

var _base_env := {}  # property -> value before the current look set it
var _base_sun := {}
var _set_env: Array = []  # properties the current look set
var _set_sun: Array = []
var _pass_nodes: Array = []  # [MeshInstance3D] of the current look
## Passes over any look (api.shaders.add_pass), kept between games: id -> {spec, owner}; their
## nodes while a game is on in _extra_nodes (id -> MeshInstance3D).
static var extras := {}
static var _next_pass := 1
var _extra_nodes := {}
var _luts := LookLuts.new()
## What at_twilight and at_dawn move between: key -> [the look's own value, at_twilight's, at_dawn's]
## (a null target leaves it to the other one). _tw_params per pass node.
var _tw_env := {}
var _tw_sun := {}
var _tw_params := {}  # MeshInstance3D -> {param: [own, at_twilight's, at_dawn's]}
var _tw_last := -1.0
var _tw_morning := false
var _fog_base = null  # the look's own fog colour, with fog_from_sky
## This frame's sun (sky.gd), for api.shaders.sun().
var sun_state := {}


var _forced := ""
## What SPACE_ENV replaced, while in space: property -> the value it had.
var _space_saved := {}


static func _builtins() -> void:
	if not looks.has("factorio"):
		register("factorio", FACTORIO)
		register("classic", CLASSIC)


func _init() -> void:
	_builtins()


func _ready() -> void:
	name = "Looks"
	active = self
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--look="):
			_forced = arg.get_slice("=", 1)
		elif arg.begins_with("--look-file="):
			load_file(arg.get_slice("=", 1))


func _exit_tree() -> void:
	if active == self:
		active = null
	if env != null:
		_restore()
		_luts.clear(env)
	RenderingServer.global_shader_parameter_set(&"f3d_look_ground_specular", 1.0)
	RenderingServer.global_shader_parameter_set(&"f3d_look_model_fill", 0.0)
	RenderingServer.global_shader_parameter_set(&"f3d_look_roughness_min", 0.0)
	_apply_limiter({})
	_apply_taa({})


## Starts using the scene's environment and sun (main.gd, once both are made).
func attach(e: Environment, s: DirectionalLight3D) -> void:
	env = e
	sun = s
	use(_forced if _forced != "" and looks.has(_forced) else current, true)
	for id in extras:
		_show_extra(int(id))


## Adds or replaces a look. Its id must be new or the owner's own; built-in ones can't be replaced.
static func register(id: String, spec: Dictionary, owner := "") -> bool:
	if id == "" or (looks.has(id) and str(looks[id].get("owner", "")) != owner):
		return false
	var s := spec.duplicate(true)
	s["owner"] = owner
	looks[id] = s
	if not order.has(id):
		order.append(id)
	if active != null and id == active.current and active.env != null:
		active.use(id, true)
	return true


## Takes away an add-on's looks and passes (it was switched off); the look in use goes back to
## Factorio's if it was one of them.
static func remove_owner(owner: String) -> void:
	for id in order.duplicate():
		if str(looks[id].get("owner", "")) == owner:
			looks.erase(id)
			order.erase(id)
			if active != null and id == active.current:
				active.use("factorio")
	for pid in extras.keys():
		if str(extras[pid]["owner"]) == owner:
			remove_pass(int(pid))


## Looks from a JSON file ({id: look}; colours and angles as arrays, a pass's shader as a path), for
## trying looks out without an add-on: `--look-file=<file.json>` (tools/look/factorio_reference.py).
static func load_file(path: String) -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary:
		push_warning("looks: %s isn't a JSON object of looks" % path)
		return
	for id in data:
		var spec: Dictionary = data[id]
		register(str(id), from_json(spec), "file")


## A look written in JSON: arrays of 2 become Vector2, of 3 or 4 Color; the rest as written.
static func from_json(v: Variant) -> Variant:
	if v is Dictionary:
		var out := {}
		for k in v:
			out[k] = from_json(v[k])
		if out.has("tonemap"):
			out["tonemap"] = int(out["tonemap"])
		return out
	if v is Array:
		if v.size() == 2 and (v[0] is float or v[0] is int):
			return Vector2(v[0], v[1])
		if (v.size() == 3 or v.size() == 4) and (v[0] is float or v[0] is int):
			return Color(v[0], v[1], v[2], v[3] if v.size() == 4 else 1.0)
		return v.map(func(x): return from_json(x))
	return v


## [[name, id]...] for the settings' list.
static func choices() -> Array:
	_builtins()
	var out: Array = []
	for id in order:
		out.append([str(looks[id].get("name", id)), id])
	return out


## The player's choice in Settings (a `--look=` on the command line wins over it).
func use_setting(id: String) -> void:
	if _forced == "":
		use(id)


## Puts a look on: the environment and sun properties it sets, its passes, its tonemapping.
func use(id: String, force := false) -> void:
	if not looks.has(id):
		id = "factorio"
	if id == current and not force:
		return
	current = id
	if env == null:
		return
	_space_back()  # the old look's own values first, so it comes off cleanly; apply() puts space back
	_restore()
	var L: Dictionary = looks[id]
	_put_on(L)
	for p in L.get("passes", []):
		var node := _make_pass(p, str(L.get("owner", "")))
		if node != null:
			_pass_nodes.append(node)
			_key_params(node, L)
	if not L.get("factorio_lut", false):
		_luts.clear(env)
	look_changed.emit(id)


## What a look sets on the environment, the sun and the renderer. Each property's value before it
## is kept for _take_off.
func _put_on(L: Dictionary) -> void:
	env.tonemap_mode = int(L.get("tonemap", Environment.TONE_MAPPER_LINEAR))
	env.tonemap_exposure = float(L.get("exposure", 1.0))
	env.tonemap_white = float(L.get("white", 1.0))
	RenderingServer.global_shader_parameter_set(&"f3d_look_ground_specular", float(L.get("ground_specular", 1.0)))
	var e: Dictionary = L.get("environment", {})
	for key in e:
		if not str(key) in env:
			continue
		_base_env[key] = env.get(key)
		env.set(key, e[key])
		_set_env.append(key)
	var s: Dictionary = L.get("sun", {})
	for key in s:
		if not SUN_KEYS.has(str(key)):
			continue
		_base_sun[key] = sun.get(key)
		sun.set(key, s[key])
		_set_sun.append(key)
	_key_values(L)
	_apply_limiter(L)
	_apply_taa(L)


## Notes what at_twilight and at_dawn move, and from what: the look's own value (now on the
## environment and sun) or, for a property it doesn't set, what it was.
func _key_values(L: Dictionary) -> void:
	_tw_env = _keyed(L, "environment", env, _base_env, _set_env)
	_tw_sun = _keyed(L, "sun", sun, _base_sun, _set_sun, SUN_KEYS)
	_fog_base = null
	if float(L.get("fog_from_sky", 0.0)) > 0.0:
		if not _set_env.has("fog_light_color"):
			_base_env["fog_light_color"] = env.fog_light_color
			_set_env.append("fog_light_color")
		_fog_base = env.fog_light_color
	_tw_last = -1.0


func _keyed(L: Dictionary, group: String, target: Object, base: Dictionary, set_keys: Array, allowed: Array = []) -> Dictionary:
	var dusk: Dictionary = L.get("at_twilight", {}).get(group, {})
	var dawn: Dictionary = L.get("at_dawn", {}).get(group, {})
	var out := {}
	for key in dusk.keys() + dawn.keys():
		if out.has(key) or not str(key) in target or (not allowed.is_empty() and not allowed.has(str(key))):
			continue
		if not set_keys.has(key):
			base[key] = target.get(key)
			set_keys.append(key)
		out[key] = [target.get(key), dusk.get(key), dawn.get(key)]
	return out


## The same for a pass's uniforms; one the look doesn't give starts from the shader's own default.
func _key_params(node: MeshInstance3D, L: Dictionary) -> void:
	var dusk: Dictionary = L.get("at_twilight", {}).get("params", {})
	var dawn: Dictionary = L.get("at_dawn", {}).get("params", {})
	var m := node.material_override as ShaderMaterial
	var out := {}
	for key in dusk.keys() + dawn.keys():
		var own = m.get_shader_parameter(key)
		if own == null:
			own = RenderingServer.shader_get_parameter_default(m.shader.get_rid(), key)
		if own != null:
			out[key] = [own, dusk.get(key), dawn.get(key)]
	if not out.is_empty():
		_tw_params[node] = out


static func _blended(row: Array, t: float, morning: bool) -> Variant:
	var target = row[2] if morning and row[2] != null else row[1]
	# A dawn-only key has nothing to go to at dusk.
	return row[0] if target == null else lerp(row[0], target, t)


## Moves what the look keyed to the sun, when the sun has moved enough to show.
func _blend_keyed(L: Dictionary, t: float, morning: bool) -> void:
	t = snappedf(t, 0.005)
	if t == _tw_last and morning == _tw_morning:
		return
	_tw_last = t
	_tw_morning = morning
	for key in _tw_env:
		env.set(key, _blended(_tw_env[key], t, morning))
	for key in _tw_sun:
		sun.set(key, _blended(_tw_sun[key], t, morning))
	for node: MeshInstance3D in _tw_params:
		if is_instance_valid(node):
			var m := node.material_override as ShaderMaterial
			var rows: Dictionary = _tw_params[node]
			for key in rows:
				m.set_shader_parameter(key, _blended(rows[key], t, morning))
	if _fog_base != null and sun_state.has("fog"):
		env.fog_light_color = (_fog_base as Color).lerp(sun_state["fog"], t * float(L.get("fog_from_sky", 0.0)))


func _apply_limiter(L: Dictionary) -> void:
	var limiter = L.get("roughness_limiter")
	if limiter is Vector2:
		RenderingServer.screen_space_roughness_limiter_set_active(true, limiter.x, limiter.y)
	else:
		RenderingServer.screen_space_roughness_limiter_set_active(
			bool(ProjectSettings.get_setting("rendering/anti_aliasing/screen_space_roughness_limiter/enabled", true)),
			float(ProjectSettings.get_setting("rendering/anti_aliasing/screen_space_roughness_limiter/amount", 0.25)),
			float(ProjectSettings.get_setting("rendering/anti_aliasing/screen_space_roughness_limiter/limit", 0.18)))


func _apply_taa(L: Dictionary) -> void:
	Settings.look_taa = bool(L.get("taa", false))
	var vp := get_viewport()
	if vp != null:
		vp.use_taa = Settings.taa_on()


## How much of a sunset the look in use has, for its light and for its sky (sky.gd).
func twilight() -> float:
	return float(looks.get(current, {}).get("twilight", 0.0))


func sky_twilight() -> float:
	var L: Dictionary = looks.get(current, {})
	return float(L.get("sky_twilight", L.get("twilight", 0.0)))


## Whether Zenith's own clouds are drawn under this look (the Clouds setting decides if they are).
func own_clouds() -> bool:
	return bool(looks.get(current, {}).get("own_clouds", true))


func _take_off() -> void:
	for key in _set_env:
		env.set(key, _base_env[key])
	for key in _set_sun:
		sun.set(key, _base_sun[key])
	_set_env.clear()
	_set_sun.clear()


func _restore() -> void:
	_take_off()
	for n in _pass_nodes:
		n.queue_free()
	_pass_nodes.clear()
	_tw_params.clear()


## Before Settings writes what a look may also set (ambient occlusion, brightness...): the look's
## own values come off, so what Settings writes is what comes back when the look goes. `settle` after.
func lift() -> void:
	if env != null:
		_space_back()
		_take_off()


## After Settings wrote: the look the player picked, its own values winning again.
func settle(id: String) -> void:
	if env == null:
		return
	var want := id if looks.has(id) else "factorio"
	if _forced == "" and want != current:
		use(want)
	else:
		_put_on(looks.get(current, {}))
	_luts.reapply(env)


## Once a frame, after sky.gd lit the scene for the time of day: the look's light on top.
## `daytime` 0 is noon, 0.5 midnight; `night` 0-1; `planet` the surface's planet ("" in space);
## `state` the sun now (sky.gd).
func apply(daytime: float, night: float, planet: String, space: bool, state := {}) -> void:
	if env == null:
		return
	var L: Dictionary = looks.get(current, {})
	sun_state = state
	var low := float(state.get("twilight", 0.0))
	sun.light_energy *= float(L.get("sun_energy", 1.0))
	env.ambient_light_energy *= float(L.get("ambient_energy", 1.0))
	if L.has("ambient_tint"):
		# A fixed tint would mute the colours of a sunset, which has its own.
		env.ambient_light_color = env.ambient_light_color.lerp(L["ambient_tint"], float(L.get("ambient_tint_amount", 1.0)) * (1.0 - low))
	_blend_keyed(L, low, bool(state.get("morning", false)))
	_space_env(space)
	if L.has("sun_angle"):
		var a: Vector2 = L["sun_angle"]
		sun.rotation_degrees = Vector3(a.x, a.y, 0.0)
	RenderingServer.global_shader_parameter_set(&"f3d_look_model_fill", float(L.get("model_fill", 0.0)) * (1.0 - night))
	RenderingServer.global_shader_parameter_set(&"f3d_look_roughness_min", float(L.get("roughness_min", 0.0)))
	if L.get("factorio_lut", false):
		_luts.update(env, "" if space else planet, daytime, night)
	for n: MeshInstance3D in _pass_nodes + _extra_nodes.values():
		var m := n.material_override as ShaderMaterial
		m.set_shader_parameter("look_daytime", daytime)
		m.set_shader_parameter("look_night", night)
		m.set_shader_parameter("look_space", 1.0 if space else 0.0)
		if not state.is_empty():
			m.set_shader_parameter("look_sun_height", state["height"])
			m.set_shader_parameter("look_twilight", low)
			m.set_shader_parameter("look_morning", 1.0 if state["morning"] else 0.0)
			m.set_shader_parameter("look_sun_dir", state["direction"])
			m.set_shader_parameter("look_sun_color", state["color"])
			m.set_shader_parameter("look_ambient_color", env.ambient_light_color)


## SPACE_ENV on in space (each frame: a look's twilight keys may have set one since), off again on
## the ground.
func _space_env(space: bool) -> void:
	if space:
		for key in SPACE_ENV:
			if env.get(key) != SPACE_ENV[key]:
				_space_saved[key] = env.get(key)
				env.set(key, SPACE_ENV[key])
	elif not _space_saved.is_empty():
		_space_back()


func _space_back() -> void:
	for key in _space_saved:
		env.set(key, _space_saved[key])
	_space_saved.clear()


## A full-screen pass over every look (api.shaders.add_pass), shown in every game until removed:
## its id for set_parameter and remove_pass, or 0 when the shader can't be used.
static func add_pass(spec: Dictionary, owner := "") -> int:
	if _shader_of(spec) == null:
		return 0
	var id := _next_pass
	_next_pass += 1
	extras[id] = {"spec": spec.duplicate(), "owner": owner}
	if active != null and active.env != null:
		active._show_extra(id)
	return id


static func remove_pass(id: int) -> void:
	extras.erase(id)
	if active != null and active._extra_nodes.has(id):
		(active._extra_nodes[id] as Node).queue_free()
		active._extra_nodes.erase(id)


## A uniform of a pass over every look (kept for the next game too), or with id 0 of every pass of
## the look in use that declares it.
static func set_parameter(id: int, param: String, value: Variant) -> void:
	if extras.has(id):
		var params: Dictionary = extras[id]["spec"].get("params", {})
		params[param] = value
		extras[id]["spec"]["params"] = params
	if active == null:
		return
	var nodes: Array = [active._extra_nodes[id]] if active._extra_nodes.has(id) else ([] if id != 0 else active._pass_nodes)
	for n: MeshInstance3D in nodes:
		(n.material_override as ShaderMaterial).set_shader_parameter(param, value)
		# A keyed uniform goes on from its new value.
		if active._tw_params.has(n) and active._tw_params[n].has(param):
			active._tw_params[n][param][0] = value
			active._tw_last = -1.0


func _show_extra(id: int) -> void:
	if _extra_nodes.has(id) or not extras.has(id):
		return
	var node := _make_pass(extras[id]["spec"], str(extras[id]["owner"]), 16)
	if node != null:
		_extra_nodes[id] = node


static func _shader_of(spec: Dictionary) -> Shader:
	var shader = spec.get("shader")
	if shader is String:
		shader = load(shader) if ResourceLoader.exists(shader) or FileAccess.file_exists(shader) else null
	if not shader is Shader or (shader as Shader).get_mode() != Shader.MODE_SPATIAL:
		return null
	return shader


## A pass's quad. `base` orders it: a look's own passes first (0 up), then those over every look (16
## up), each list in its order.
func _make_pass(spec: Dictionary, owner: String, base := 0) -> MeshInstance3D:
	var shader := _shader_of(spec)
	if shader == null:
		push_warning("looks: a pass from %s has no spatial shader" % (owner if owner != "" else "Zenith"))
		return null
	var m := ShaderMaterial.new()
	m.shader = shader
	# Before every other see-through thing (cloud shadows are at -100), so it reads and replaces
	# only the solid scene; later passes in a list draw after earlier ones.
	var n := _pass_nodes.size() if base == 0 else _extra_nodes.size()
	m.render_priority = clampi(-128 + base + int(spec.get("order", n)), -128, -101)
	var params: Dictionary = spec.get("params", {})
	for k in params:
		m.set_shader_parameter(k, params[k])
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 16384.0  # it covers the screen wherever it is
	mi.name = "LookPass"
	add_child(mi)
	return mi
