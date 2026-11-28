shader_type spatial;
// Deep 3D subterranean rocket launch shaft (rocket_vfx.gd): riveted concrete & scorched steel
// rings, vertical umbilical rails, recessed warning strips, blast deflector pit floor, and
// dynamic engine firelight + post-launch cooling embers.
render_mode cull_back;

#include "res://shaders/noise.gdshaderinc"
#include "res://shaders/ground_height.gdshaderinc"

uniform float fire_glow = 0.0;
uniform float ember_glow = 0.0;
uniform float alarm_glow = 0.0;
uniform float work_glow = 0.0;
uniform float shaft_depth = 26.0;
uniform float shaft_radius = 2.6;

varying vec3 local_pos;
varying vec3 local_n;

void vertex() {
	local_pos = VERTEX;
	local_n = NORMAL;
	VERTEX = ground_lift_origin(VERTEX, MODEL_MATRIX);
}

void fragment() {
	float angle = atan(local_pos.z, local_pos.x);
	float depth = max(-local_pos.y, 0.0);
	bool is_floor = local_n.y > 0.75 && local_pos.y < -shaft_depth + 1.5;

	// Cylindrical coordinates mapped cleanly onto the pit wall (tiles around circumference, depth).
	vec2 wall_uv = vec2(angle * shaft_radius, local_pos.y);
	float n_broad = fbm3(wall_uv * 0.9 + 3.1);
	float n_fine = vnoise(wall_uv * 6.5 + 11.7);

	// Horizontal structural rings every 2.4 tiles + 12 vertical steel ribs.
	float ring_phase = fract(depth / 2.4);
	float seam = smoothstep(0.0, 0.06, ring_phase) * (1.0 - smoothstep(0.92, 1.0, ring_phase));
	float ring_ridge = smoothstep(0.42, 0.48, ring_phase) * (1.0 - smoothstep(0.52, 0.58, ring_phase));
	float rib_phase = abs(fract(angle / 0.52359877) - 0.5) * 2.0;  // 12 ribs around shaft
	float rib = smoothstep(0.84, 0.94, rib_phase);

	// Base industrial concrete / scorched steel palette.
	vec3 concrete = vec3(0.11, 0.105, 0.10) * (0.78 + 0.38 * n_broad + 0.14 * (n_fine - 0.5));
	vec3 steel = vec3(0.085, 0.09, 0.095) * (0.85 + 0.25 * n_fine);
	vec3 albedo = mix(concrete, steel, max(ring_ridge * 0.8, rib * 0.85));
	albedo *= mix(0.45, 1.0, seam);

	// Exhaust soot darkening down the lower half & deflector floor.
	float soot = smoothstep(1.5, 11.0, depth);
	albedo *= mix(1.0, 0.35, soot);
	if (is_floor) {
		float rad = length(local_pos.xz);
		float grate = smoothstep(0.15, 0.25, abs(fract(rad * 1.4) - 0.5));
		float spokes = smoothstep(0.82, 0.92, abs(fract(angle / 0.392699) - 0.5) * 2.0);
		albedo = vec3(0.025, 0.023, 0.022) * (0.7 + 0.3 * n_broad) * mix(0.55, 1.0, grate * (1.0 - 0.35 * spokes));
	}

	// Vertical shaft ambient occlusion: plunges rapidly into subterranean darkness.
	float shaft_ao = mix(0.85, 0.06, smoothstep(0.0, 14.0, depth));
	if (is_floor) {
		shaft_ao = 0.05;
	}

	// Subtle amber industrial service galleries near the top (-2.2 and -5.6), brighter on reload, crimson on alarm.
	float strip_a = exp(-pow((depth - 2.15) * 9.0, 2.0));
	float strip_b = exp(-pow((depth - 5.55) * 9.0, 2.0));
	float strip_c = exp(-pow((depth - 9.0) * 9.0, 2.0));
	float strip_mask = (strip_a + strip_b * 0.7 + strip_c * work_glow * 0.65) * (1.0 - rib * 0.9) * (0.65 + 0.35 * step(0.15, fract(angle * 3.82)));
	vec3 strip_col = mix(vec3(0.42, 0.24, 0.07), vec3(2.2, 0.18, 0.06), clamp(alarm_glow, 0.0, 1.0));
	vec3 emission = strip_col * strip_mask * (0.25 + 1.2 * alarm_glow + 0.9 * work_glow);
	vec3 work_lit = vec3(0.65, 0.42, 0.18) * work_glow * (0.3 + 0.5 * max(rib, ring_ridge)) * mix(1.0, 0.35, soot);
	emission += work_lit * (0.35 + 0.65 * exp(-depth * 0.07));

	// Engine firelight illumination climbing from the bottom of the pit.
	float fire_flicker = 0.84 + 0.16 * sin(TIME * 37.0 + local_pos.y * 0.6) * cos(TIME * 23.0 + angle * 2.0);
	float up_catch = mix(0.6, 1.25, clamp(-local_n.y, 0.0, 1.0));
	float heat_reach = exp(-depth * 0.065) * 0.55 + exp(-max(shaft_depth - depth, 0.0) * 0.12) * 0.85;
	float wall_detail = 0.75 + 0.35 * n_broad + 0.3 * rib + 0.25 * ring_ridge;
	vec3 fire_col = mix(vec3(1.8, 0.45, 0.06), vec3(2.8, 1.45, 0.45), clamp(fire_glow * 0.85, 0.0, 1.0));
	if (is_floor) {
		fire_col = vec3(3.2, 1.85, 0.75);
		heat_reach = 1.4;
	}
	emission += fire_col * fire_glow * fire_flicker * heat_reach * wall_detail * up_catch;

	// Post-launch glowing scorched steel & deflector embers cooling slowly.
	float ember_noise = smoothstep(0.42, 0.82, n_broad * 0.7 + n_fine * 0.3);
	float ember_reach = is_floor ? 1.0 : smoothstep(7.0, shaft_depth - 2.0, depth) * 0.65;
	emission += vec3(1.6, 0.32, 0.04) * ember_glow * ember_noise * ember_reach;

	ALBEDO = albedo;
	EMISSION = emission;
	ROUGHNESS = mix(0.88, 0.52, max(rib, ring_ridge));
	METALLIC = mix(0.08, 0.55, max(rib, ring_ridge));
	AO = shaft_ao;
	AO_LIGHT_AFFECT = 0.9;
}
