shader_type spatial;
// Clears the 3D color buffer's alpha channel (Godot 4 Forward+'s FSR 2.2 reactive mask)
// back to 0.0 immediately after full-screen look passes, while leaving RGB bit-exact
// via BLEND_MODE_MUL (out.rgb = 1.0 * dst.rgb, out.a = 0.0 * dst.a).
render_mode unshaded, blend_mul, depth_test_disabled, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	ALBEDO = vec3(1.0);
	ALPHA = 0.0;
}
