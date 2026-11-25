shader_type spatial;
// One chunk's baked flat decoratives (decoratives.gd, decor_sheet_baker.gd): every overlapping decal,
// ground layer, floor and carpet flattened into one texture in Factorio's render order, then lit
// once here with hills, concrete/building cuts (decor_mask.gdshaderinc) and 3D grass darkening
// applied live.
render_mode blend_mix, depth_draw_never, cull_back, specular_disabled;

#include "res://shaders/ground_height.gdshaderinc"
#include "res://shaders/decorative_grass.gdshaderinc"
#include "res://shaders/decor_mask.gdshaderinc"
#include "res://shaders/lamp_light.gdshaderinc"

uniform sampler2D sheet : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float raised_shade = 0.35;

varying float level;
varying vec2 ground_at;

void vertex() {
	ground_at = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	level = ground_n(ground_at).y;
	VERTEX = ground_lift(VERTEX, MODEL_MATRIX);
}

void fragment() {
	if (decor_blocked(ground_at)) {
		discard;
	}
	vec4 c = texture(sheet, UV);
	if (c.a < 0.004) {
		discard;
	}
	float grown = raised_shade > 0.0 ? grass_grow(ground_at) : 0.0;
	ALBEDO = c.rgb * (1.0 - raised_shade * grown);
	EMISSION = lamp_light_emission(ALBEDO, ground_at, 0.0, 1.0);
	ALPHA = c.a * smoothstep(0.75, 0.9, level);
}
