shader_type spatial;
// Unshaded top-down pass of decorative_flat.gdshader used to bake a chunk's flat decoratives into
// one RGBA sheet (decor_sheet_baker.gd). Keeps the exact atlas sampling, alpha cut and per-layer
// render priority sorting without lighting, shadows, hills or the live mask.
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled;

uniform sampler2D atlas : source_color, filter_linear_mipmap_anisotropic, repeat_disable;

void vertex() {
	UV = vec2(INSTANCE_CUSTOM.x + UV.x * INSTANCE_CUSTOM.y, UV.y * INSTANCE_CUSTOM.z);
}

void fragment() {
	vec4 c = texture(atlas, UV);
	if (c.a < 0.004) {
		discard;
	}
	ALBEDO = c.rgb;
	ALPHA = c.a;
}
