shader_type spatial;
// A ghost (or the build preview) of a building Zenith draws as its picture card (sprite_standins.gd):
// the picture's shape in the ghost's translucent tint (ghost.gdshader), its light and dark kept so
// the building still reads, cut out where the picture is see-through, seen from both sides and
// lifted onto an add-on's hills as the card itself is (sprite_card.gdshader).
render_mode unshaded, blend_mix, depth_draw_always, cull_disabled, shadows_disabled;

#include "res://shaders/ground_height.gdshaderinc"

uniform sampler2D picture : source_color, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(0.58, 0.68, 1.0, 0.42);

void vertex() {
	float h = ground_h(MODEL_MATRIX[3].xz);
	if (h != 0.0) {
		VERTEX += inverse(mat3(MODEL_MATRIX)) * vec3(0.0, h, 0.0);
	}
}

void fragment() {
	vec4 c = texture(picture, UV);
	if (c.a < 0.5) {
		discard;
	}
	float shade = dot(c.rgb, vec3(0.299, 0.587, 0.114));
	ALBEDO = tint.rgb * (0.6 + 0.6 * shade);
	ALPHA = tint.a;
}
