shader_type spatial;
// Volumetric supersonic rocket exhaust plume (rocket_vfx.gd): inner cyan-white Mach shock-diamond
// core + outer turbulent fiery combustion mantle with soft Fresnel edges and HDR bloom.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

#include "res://shaders/noise.gdshaderinc"
#include "res://shaders/ground_height.gdshaderinc"

uniform float throttle = 0.0;
uniform float plume_length = 16.0;
uniform float is_core = 1.0;
uniform float time_offset = 0.0;

varying vec2 v_uv;
varying vec3 v_obj_n;
varying vec3 v_obj_pos;

void vertex() {
	v_uv = UV;
	float y_frac = clamp(-VERTEX.y, 0.0, 1.0);
	float t = TIME + time_offset;
	// Supersonic acoustic flutter & shear expansion along the plume tail.
	float flutter = (0.04 + 0.14 * y_frac) * throttle * (1.0 - 0.45 * is_core);
	float angle = atan(VERTEX.z, VERTEX.x);
	float wave = sin(y_frac * 22.0 - t * 44.0 + angle * 2.0) + 0.5 * cos(y_frac * 35.0 - t * 61.0 - angle * 3.0);
	vec3 pos = VERTEX;
	pos.y *= plume_length;
	float radial_grow = 1.0 + wave * flutter + (1.0 - is_core) * 0.22 * pow(y_frac, 1.3);
	pos.xz *= radial_grow;
	v_obj_pos = pos;
	v_obj_n = NORMAL;
	VERTEX = ground_lift_origin(pos, MODEL_MATRIX);
}

void fragment() {
	if (throttle <= 0.005) {
		discard;
	}
	float t = TIME + time_offset;
	float y_frac = clamp(v_uv.y, 0.0, 1.0);
	float angle = atan(v_obj_pos.z, v_obj_pos.x);

	// Soft view-angle Fresnel edge falloff: eliminates hard cone silhouettes from every angle.
	float ndotv = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float edge_soft = pow(ndotv, mix(1.45, 2.15, is_core));

	// Fast downward-scrolling combustion turbulence.
	vec2 flow_uv = vec2(angle * 2.5, y_frac * 5.2 - t * 18.0);
	float turb_a = fbm3(flow_uv);
	float turb_b = vnoise(flow_uv * 2.4 + vec2(3.7, -t * 24.0));
	float turb = turb_a * 0.65 + turb_b * 0.35;

	// Ignition sputtering below ~35% throttle, locking into steady supersonic roar above.
	float sputter = mix(0.45 + 0.55 * smoothstep(0.25, 0.8, vnoise(vec2(t * 21.0, y_frac * 3.0))), 1.0,
		smoothstep(0.15, 0.65, throttle));

	// Lengthwise taper & turbulent flame breakup near the tail.
	float head_in = smoothstep(0.0, 0.05, y_frac);
	float tail_cut = 1.0 - smoothstep(mix(0.45, 0.62, is_core) - 0.18 * (1.0 - turb), 1.0, y_frac);
	float density = edge_soft * head_in * tail_cut * sputter * throttle;

	vec3 col;
	if (is_core > 0.5) {
		// 5 pulsating Mach shock diamonds down the supersonic core.
		float shock_wave = pow(0.5 + 0.5 * cos(y_frac * 28.0 - t * 20.0), 4.5);
		float shock_mask = smoothstep(0.03, 0.16, y_frac) * (1.0 - smoothstep(0.55, 0.92, y_frac));
		float diamond = shock_wave * shock_mask;
		vec3 throat = vec3(2.9, 3.0, 3.5);
		vec3 mid = vec3(3.0, 2.25, 1.05);
		vec3 tip = vec3(2.1, 0.65, 0.12);
		col = mix(throat, mid, smoothstep(0.0, 0.35, y_frac));
		col = mix(col, tip, smoothstep(0.35, 0.95, y_frac));
		col += vec3(1.6, 1.5, 1.8) * diamond;
		density *= (0.78 + 0.45 * diamond + 0.25 * turb);
	} else {
		// Outer roaring combustion mantle.
		vec3 hot = vec3(2.3, 1.35, 0.36);
		vec3 warm = vec3(1.75, 0.55, 0.08);
		vec3 tail = vec3(1.05, 0.18, 0.02);
		col = mix(hot, warm, smoothstep(0.05, 0.45, y_frac));
		col = mix(col, tail, smoothstep(0.45, 0.95, y_frac));
		density *= (0.45 + 0.85 * turb) * 0.72;
	}

	ALBEDO = col * clamp(density, 0.0, 1.5);
	ALPHA = clamp(density, 0.0, 1.0);
}
