// addon_test.gd's pass: the scene in grey, by `strength`.
shader_type spatial;
#include "res://shaders/look_pass.gdshaderinc"
uniform float strength = 1.0;
void fragment() {
	vec3 c = scene_color(SCREEN_UV);
	ALBEDO = mix(c, vec3(luma(c)), strength);
}
