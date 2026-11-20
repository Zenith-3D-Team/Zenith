extends ColorRect
## A soft green vignette at the screen's edges while night vision is on (owner: "add some effects around
## the edges of the screen"), one fullscreen canvas pass that fades with main.gd's `_night_vision` (0..1).
## hud.gd holds it under everything else, as the damage overlay. Settings > Interface > Night vision
## screen edge (`interface/night_vision_edge`, on) turns it off; `--night-vision-fx=off` turns it, the
## indicator and the sound off until the command line changes (not saved).

const Settings := preload("res://scripts/menu/settings.gd")

const SHADER := """
shader_type canvas_item;
uniform float level = 0.0;
uniform float lo = 0.8;
uniform float strength = 0.12;
void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float edge = smoothstep(lo, 1.35, length(p));
	COLOR = vec4(0.25, 0.85, 0.3, edge * strength * level);
}
"""

## `--night-vision-fx=off`: no indicator, edge or sound at all.
static var forced_off := Settings.arg_value("--night-vision-fx=") == "off"

## 0..1: how far night vision is on (what main.gd feeds).
var level := 0.0:
	set(v):
		level = v
		_update()

var _material := ShaderMaterial.new()


static func indicator_enabled() -> bool:
	return not forced_off and bool(Settings.get_value("interface", "night_vision_indicator"))


static func edge_enabled() -> bool:
	return not forced_off and bool(Settings.get_value("interface", "night_vision_edge"))


static func sound_enabled() -> bool:
	return not forced_off


func _init() -> void:
	name = "NightVisionOverlay"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = SHADER
	_material.shader = shader
	if Settings.arg_value("--night-vision-fx=") == "old":
		_material.set_shader_parameter("lo", 0.55)
		_material.set_shader_parameter("strength", 0.42)
	material = _material
	color = Color.WHITE
	visible = false


func _ready() -> void:
	Settings.listen(_on_setting)


func _exit_tree() -> void:
	Settings.unlisten(_on_setting)


func _on_setting(section: String, key: String) -> void:
	if section == "interface" and key == "night_vision_edge":
		_update()


## What is drawn now: the level while the setting allows it, nothing (and not drawn) otherwise.
func shown_level() -> float:
	return level if edge_enabled() else 0.0


func _update() -> void:
	var v := shown_level()
	visible = v > 0.0
	_material.set_shader_parameter("level", v)
