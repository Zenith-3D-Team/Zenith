shader_type spatial;
// Volumetric 3D-lit billowing smoke & steam MultiMesh shader (rocket_vfx.gd): spherical-normal
// cumulus lighting, organic FBM cauliflower lobes, internal engine firelight incandescence,
// and soft ground intersection fade.
//   COLOR:          base smoke rgb, alpha
//   INSTANCE_CUSTOM: r = seed (0..1), g = internal firelight heat (0..1), b = spin (rad), a = age_t (0..1)
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

#include "res://shaders/noise.gdshaderinc"
#include "res://shaders/ground_height.gdshaderinc"

uniform float brightness = 1.0;

varying vec2 v_uv;
varying float v_seed;
varying float v_heat;
varying float v_age;
varying float v_world_y;

void vertex() {
	v_uv = UV;
	v_seed = INSTANCE_CUSTOM.r;
	v_heat = INSTANCE_CUSTOM.g;
	v_age = INSTANCE_CUSTOM.a;

	vec2 size = vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
	float c = cos(INSTANCE_CUSTOM.b);
	float s = sin(INSTANCE_CUSTOM.b);
	vec2 v = VERTEX.xy * size;
	VERTEX = vec3(v.x * c - v.y * s, v.x * s + v.y * c, 0.0);

	vec4 at = MODEL_MATRIX[3];
	float gh = ground_h(at.xz);
	at.y += gh;
	v_world_y = at.y - gh + VERTEX.y;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], at);
}

void fragment() {
	vec2 p = v_uv * 2.0 - 1.0;
	float r2 = dot(p, p);
	if (r2 > 1.0) {
		discard;
	}
	float r = sqrt(r2);

	// Billowing cauliflower lobes that curl & evolve as the puff ages.
	vec2 n_uv = p * 1.9 + vec2(v_seed * 37.0, v_seed * 19.0 - v_age * 1.35);
	vec3 nd = noised(n_uv);
	float detail = vnoise(n_uv * 2.3 + vec2(5.1, v_age * 1.9));
	float fbm = nd.x * 0.68 + detail * 0.32;

	// Sculpted soft cloud silhouette (ragged cumulus edges instead of a plain circle).
	float radial_mask = smoothstep(0.98, 0.32, r + (fbm - 0.5) * 0.42);
	if (radial_mask <= 0.005) {
		discard;
	}

	// Pseudo-3D spherical cloud normal perturbed by FBM gradient for sunlit tops & dark folds.
	float nz = sqrt(max(1.0 - r2, 0.0));
	vec3 sph_n = normalize(vec3(p.x + nd.y * 0.45, -p.y + nd.z * 0.45, nz));
	vec3 sun_dir = normalize(vec3(0.45, 0.78, 0.42));
	float ndotl = clamp(dot(sph_n, sun_dir) * 0.5 + 0.5, 0.0, 1.0);
	float shade = mix(0.44, 1.08, ndotl) * (0.84 + 0.28 * fbm);

	// Soft ground contact fade so ground-hugging billows don't show hard quad cuts.
	float ground_fade = smoothstep(-0.35, 0.65, v_world_y);
	float alpha = radial_mask * COLOR.a * ground_fade;

	// Base sunlit/night-dimmed cloud color + un-dimmed internal firelight incandescence!
	vec3 lit_smoke = COLOR.rgb * shade * brightness;
	float core_glow = smoothstep(0.95, 0.08, r) * (0.45 + 0.55 * fbm) * v_heat;
	vec3 fire_light = mix(vec3(1.65, 0.42, 0.06), vec3(2.65, 1.25, 0.36), clamp(core_glow * 1.2, 0.0, 1.0));

	ALBEDO = lit_smoke + fire_light * core_glow;
	ALPHA = clamp(alpha, 0.0, 1.0);
}
