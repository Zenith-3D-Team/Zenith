shader_type spatial;
// Additive camera-facing glow beacons for rail signals and chain signals (`signal_lights.gd`).
// Drawn in the transparent pass after screen-space grading so signals glow cleanly at any
// distance without sharpening ringing boxes or night blue-hour washout.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled;

uniform float forward_bias = 0.28;

varying vec4 glow_color;

void vertex() {
	glow_color = COLOR;
	vec4 at = MODEL_MATRIX[3];
	vec3 to_cam = INV_VIEW_MATRIX[3].xyz - at.xyz;
	float dist = length(to_cam);
	if (dist > 1e-4) {
		at.xyz += (to_cam / dist) * min(forward_bias, dist * 0.25);
	}
	vec2 size = vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
	float dist_scale = mix(1.0, 2.0, smoothstep(64.0, 320.0, dist));
	VERTEX = vec3(VERTEX.xy * size * dist_scale, 0.0);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], at);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r2 = dot(p, p);
	if (r2 >= 1.0) {
		discard;
	}
	float core = exp(-r2 * 14.0);
	float halo = exp(-r2 * 4.5) * 0.16;
	float edge = 1.0 - r2;
	float glow = (core + halo) * edge * edge;
	ALBEDO = glow_color.rgb * glow;
	ALPHA = clamp(glow, 0.0, 1.0);
}
