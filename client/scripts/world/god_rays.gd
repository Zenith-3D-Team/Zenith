extends Node3D
## Volumetric God rays (Settings > Graphics > God rays, shaders/god_rays.gdshader): an additive
## full-screen pass at priority 4 (over volumetric Smog at 3, under RemoteFog at 5) that casts
## sunbeams through gaps in the active cloud layer (Zenith's built-in clouds or a look's
## `cloud_field`), trees, buildings, and polluted smog. Hidden with no GPU cost when turned off,
## in deep night, with zero sun strength, or on a space platform.

const Settings := preload("res://scripts/menu/settings.gd")
const PlanetSky := preload("res://scripts/world/sky.gd")
const SHADER := preload("res://shaders/god_rays.gdshader")
const Switches := preload("res://scripts/switches.gd")
const PRIORITY := 4

var _quad := MeshInstance3D.new()
var _material := ShaderMaterial.new()
var _setting_strength := 0.5
var _forced_strength := -1.0
var _strength := 0.5
var _cloud_cache := {}


func _ready() -> void:
	_material.shader = SHADER
	_material.render_priority = PRIORITY
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	_quad.mesh = quad
	_quad.material_override = _material
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad.extra_cull_margin = 16384.0
	_quad.name = "GodRays"
	_quad.visible = false
	add_child(_quad)
	_forced_strength = _forced_arg()
	_read_setting()
	Settings.listen(_on_setting)


func _exit_tree() -> void:
	PlanetSky.clear_cloud_uniforms(_material, _cloud_cache)


static func _forced_arg() -> float:
	for arg in Switches.args():
		if arg == "--clean-shot" or arg.begins_with("--review-shots="):
			return 0.0
		if arg == "--god-rays=off":
			return 0.0
		if arg.begins_with("--god-rays="):
			return clampf(float(arg.get_slice("=", 1)), 0.0, 1.0)
	return -1.0


## Updates visibility and uniforms from the frame's atmosphere snapshot (PlanetSky.atmosphere()
## merged with Looks.cloud_source(), `space`, `ambient_color`, `scene_light`).
func update(atmo: Dictionary, smog_strength := 0.0) -> void:
	var space := bool(atmo.get("space", false))
	var sun_strength := float(atmo.get("sun_strength", 0.0))
	var raw_sun: Variant = atmo.get("sun_dir", Vector3(0.0, 0.7, -0.7))
	var sun_dir: Vector3 = raw_sun if raw_sun is Vector3 else Vector3(0.0, 0.7, -0.7)
	var raw_sky_sun: Variant = atmo.get("sky_sun_dir", sun_dir)
	var sky_sun_dir: Vector3 = raw_sky_sun if raw_sky_sun is Vector3 else sun_dir
	var raw_scene_light: Variant = atmo.get("scene_light", Vector2.ONE)
	var scene_light: Vector2 = raw_scene_light if raw_scene_light is Vector2 else Vector2.ONE
	var eff_strength := _strength * clampf(float(atmo.get("god_rays_scale", 1.0)), 0.0, 2.0)
	_quad.visible = eff_strength > 0.001 and not space and sun_strength > 0.01 and maxf(sun_dir.y, sky_sun_dir.y) > 0.02 and scene_light.y > 0.001
	if not _quad.visible:
		return
	var raw_sun_color: Variant = atmo.get("sun_color", Color.WHITE)
	var sun_color: Color = raw_sun_color if raw_sun_color is Color else Color.WHITE
	var raw_haze_color: Variant = atmo.get("haze_color", Color(1.0, 0.92, 0.78))
	var haze_color: Color = raw_haze_color if raw_haze_color is Color else Color(1.0, 0.92, 0.78)
	_material.set_shader_parameter("strength", eff_strength)
	_material.set_shader_parameter("smog_strength", clampf(smog_strength, 0.0, 1.0))
	_material.set_shader_parameter("sun_dir", sun_dir)
	_material.set_shader_parameter("sky_sun_dir", sky_sun_dir)
	_material.set_shader_parameter("sun_color", sun_color)
	_material.set_shader_parameter("sun_strength", sun_strength)
	_material.set_shader_parameter("twilight", float(atmo.get("twilight", 0.0)))
	_material.set_shader_parameter("planet_haze", float(atmo.get("haze", 0.0)))
	_material.set_shader_parameter("planet_haze_color", haze_color)
	_material.set_shader_parameter("scene_light", scene_light)
	PlanetSky.apply_cloud_uniforms(_material, atmo, _cloud_cache)


func strength() -> float:
	return _strength


## Overrides the Settings slider for tests (`v < 0.0` restores Settings' value).
func set_forced_strength(v: float) -> void:
	_forced_strength = clampf(v, 0.0, 1.0) if v >= 0.0 else -1.0
	_apply_strength()


func _on_setting(section: String, key: String) -> void:
	if section == "graphics" and key == "god_rays":
		_read_setting()


func _read_setting() -> void:
	var val: Variant = Settings.get_value("graphics", "god_rays")
	_setting_strength = clampf(float(val) if val != null else 0.5, 0.0, 1.0)
	_apply_strength()


func _apply_strength() -> void:
	_strength = _forced_strength if _forced_strength >= 0.0 else _setting_strength
	_material.set_shader_parameter("strength", _strength)
