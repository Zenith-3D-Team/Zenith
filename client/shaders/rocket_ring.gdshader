shader_type spatial;
// Radial ground/trench impingement plasma ring & liftoff shockwave flash at the silo mouth.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

#include "res://shaders/noise.gdshaderinc"
#include "res://shaders/ground_height.gdshaderinc"

uniform float intensity = 0.0;
uniform float shock = 0.0;  // 0..1 liftoff expansion pulse

varying vec2 v_local_xz;

void vertex() {
	v_local_xz = VERTEX.xz;
	VERTEX = ground_lift_origin(VERTEX, MODEL_MATRIX);
}

void fragment() {
	if (intensity <= 0.005 && shock <= 0.005) {
		discard;
	}
	float r = length(v_local_xz);  // normalized [0.15 .. 1.0] across disc radius
	float angle = atan(v_local_xz.y, v_local_xz.x);

	// Outward-rushing turbulent flame tongues spilling over the concrete lip.
	float radial_noise = fbm3(vec2(angle * 4.5, r * 4.5 - TIME * 12.0));
	float fine_streaks = vnoise(vec2(angle * 11.0, r * 7.0 - TIME * 19.0));
	float tongues = smoothstep(0.32, 0.85, radial_noise * 0.7 + fine_streaks * 0.3);

	float core_ring = smoothstep(0.18, 0.36, r) * (1.0 - smoothstep(0.42, 0.92, r));
	float lick = (1.0 - smoothstep(0.35, 0.98, r)) * tongues;
	float base_glow = (core_ring * 0.95 + lick * 0.85) * intensity;

	// Liftoff radial shockwave wave ring sweeping outward.
	float shock_r = mix(0.28, 0.96, shock);
	float shock_band = exp(-pow((r - shock_r) * 14.0, 2.0)) * (1.0 - shock) * 1.4;

	float total = base_glow + shock_band;
	vec3 col = mix(vec3(1.8, 0.48, 0.06), vec3(3.0, 1.9, 0.85), clamp(core_ring + shock_band * 0.7, 0.0, 1.0));
	ALBEDO = col * total;
	ALPHA = clamp(total, 0.0, 1.0);
}
