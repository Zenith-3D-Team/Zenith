shader_type spatial;
// Persistent ground tread tracks for tanks (ribbed caterpillar cleats) and cars (chevron rubber
// tire treads), rendered in one MultiMeshInstance3D draw call. Hugs hills via ground_height and
// adapts automatically to surface wetness (f3d_weather_wet.x).
render_mode cull_disabled, depth_draw_never, blend_mix;

#include "res://shaders/ground_height.gdshaderinc"

global uniform vec4 f3d_weather_wet;

uniform float now = 0.0;

const float CLOCK_WRAP = 10000.0;

varying vec2 v_uv;
varying vec4 v_color;
varying float v_fade;
varying float v_is_tank;
varying float v_seed;
varying vec2 v_world_xz;

float _hash21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float _vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = _hash21(i);
	float b = _hash21(i + vec2(1.0, 0.0));
	float c = _hash21(i + vec2(0.0, 1.0));
	float d = _hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	vec4 c = INSTANCE_CUSTOM;
	float life = c.y;
	float age = mod(now - c.x + CLOCK_WRAP, CLOCK_WRAP);
	if (age > CLOCK_WRAP * 0.5) {
		age = 0.0;
	}
	if (life <= 0.001 || age >= life) {
		v_uv = UV;
		v_color = vec4(0.0);
		v_fade = 0.0;
		v_is_tank = 0.0;
		v_seed = 0.0;
		v_world_xz = vec2(0.0);
		VERTEX = vec3(0.0);
		NORMAL = vec3(0.0, 1.0, 0.0);
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	} else {
		float width = c.z;
		float length_tiles = abs(c.w);
		v_is_tank = c.w >= 0.0 ? 1.0 : 0.0;
		v_uv = UV;
		v_color = COLOR;
		float life_t = clamp(age / life, 0.0, 1.0);
		v_fade = 1.0 - smoothstep(0.65, 1.0, life_t);
		v_seed = fract(c.x * 19.37 + MODEL_MATRIX[3].x * 2.17 + MODEL_MATRIX[3].z * 4.91);

		vec3 local = vec3(VERTEX.x * width, 0.0, VERTEX.y * length_tiles);
		vec3 world = (MODEL_MATRIX * vec4(local, 1.0)).xyz;
		v_world_xz = world.xz;

		world.y = ground_h(world.xz) + 0.022;
		vec3 cam_diff = INV_VIEW_MATRIX[3].xyz - world;
		float cam_len = length(cam_diff);
		if (cam_len > 0.001) {
			world += (cam_diff / cam_len) * 0.018;
		}

		mat3 inv_rot = transpose(mat3(MODEL_MATRIX));
		VERTEX = inv_rot * (world - MODEL_MATRIX[3].xyz);
		NORMAL = normalize(inv_rot * ground_n(world.xz));
		POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(world, 1.0));
	}
}

void fragment() {
	if (v_fade <= 0.001 || v_color.a <= 0.001) {
		discard;
	}

	float x = v_uv.x * 2.0 - 1.0;
	float abs_x = abs(x);
	float grit = _vnoise(v_world_xz * 14.0) * 2.0 - 1.0;
	float fine = _vnoise(v_world_xz * 34.0);
	float end_taper = smoothstep(0.0, 0.18, v_uv.y) * smoothstep(1.0, 0.82, v_uv.y);

	float wet = clamp(f3d_weather_wet.x, 0.0, 1.0);
	float mask = 0.0;
	float depth_shade = 0.0;
	float berm_weight = 0.0;

	if (v_is_tank > 0.5) {
		// Heavy caterpillar cleat treads: 5+ transverse bars aligned to 0.14-tile pitch (3 per 0.42 stride),
		// subtle central guide-horn groove, dark pressed rut core, and displaced outer soil berms.
		float inside = smoothstep(0.95, 0.72, abs_x + grit * 0.045);
		float berm = smoothstep(0.68, 0.84, abs_x) * smoothstep(1.0, 0.87, abs_x) * (0.60 + 0.40 * fine);
		float cleat_wave = cos((v_uv.y - 0.5) * 5.142857 * 6.2831853);
		float cleat = smoothstep(-0.18, 0.52, cleat_wave);
		float guide = 1.0 - 0.52 * smoothstep(0.18, 0.04, abs_x);
		float core_press = inside * (0.44 + 0.56 * cleat * guide);
		mask = max(core_press, berm * 0.58) * end_taper;
		depth_shade = clamp(0.45 + 0.55 * cleat * guide, 0.0, 1.0) * inside;
		berm_weight = berm * (1.0 - inside * 0.65);
	} else {
		// Car rubber tire treads: chevron ribs, twin longitudinal water grooves, soft shoulders.
		float inside = smoothstep(0.94, 0.68, abs_x + grit * 0.04);
		float shoulder = smoothstep(0.70, 0.86, abs_x) * smoothstep(1.0, 0.88, abs_x) * (0.55 + 0.45 * fine);
		float groove = 1.0 - 0.48 * exp(-pow((abs_x - 0.30) / 0.11, 2.0));
		float chev_wave = cos(((v_uv.y - 0.5) * 5.714286 + abs_x * 0.45) * 6.2831853);
		float chev = smoothstep(-0.22, 0.48, chev_wave);
		float core_press = inside * (0.36 + 0.56 * chev * groove);
		mask = max(core_press, shoulder * 0.36) * end_taper;
		depth_shade = clamp(0.35 + 0.55 * chev * groove, 0.0, 1.0) * inside;
		berm_weight = shoulder * (1.0 - inside * 0.6);
	}

	vec3 base = v_color.rgb;
	vec3 rut_col = base * mix(0.66, 0.36, depth_shade) * (0.90 + 0.18 * fine);
	vec3 berm_col = base * (0.86 + 0.12 * fine);
	vec3 col = mix(rut_col, berm_col, clamp(berm_weight, 0.0, 0.75));

	// Wet terrain turns pressed ruts into deeper, darker, glossy churned mud.
	col = mix(col, col * vec3(0.46, 0.42, 0.38), wet);
	float rough = mix(0.92, mix(0.34, 0.22, depth_shade), wet);
	float spec = mix(0.15, 0.52, wet);
	float alpha = clamp(mask * v_color.a * v_fade * (1.0 + wet * 0.22), 0.0, 0.92);
	if (alpha < 0.01) {
		discard;
	}

	ALBEDO = col;
	ALPHA = alpha;
	ROUGHNESS = rough;
	SPECULAR = spec;
	METALLIC = 0.0;
}
