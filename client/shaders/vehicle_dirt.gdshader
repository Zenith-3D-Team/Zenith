shader_type spatial;
// Ballistic tumbling dirt/mud clods and churning ground-tinted dust plumes kicked up by moving
// and pivoting vehicles, simulated purely on the GPU in one MultiMeshInstance3D draw call.
render_mode cull_disabled, depth_draw_never, blend_mix;

global uniform vec4 f3d_weather_wet;

uniform float now = 0.0;

const float CLOCK_WRAP = 10000.0;

varying vec2 v_uv;
varying vec4 v_color;
varying float v_alpha;
varying float v_kind;
varying float v_seed;
varying float v_life_t;

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
		v_alpha = 0.0;
		v_kind = 0.0;
		v_seed = 0.0;
		v_life_t = 1.0;
		VERTEX = vec3(0.0);
		NORMAL = vec3(0.0, 1.0, 0.0);
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	} else {
		vec3 origin = MODEL_MATRIX[3].xyz;
		float size = c.z;
		float kind = floor(c.w * 0.01);
		float speed = mod(c.w, 100.0);
		float seed = fract(c.x * 37.13 + origin.x * 3.1 + origin.z * 7.3);
		bool is_dust = kind > 0.5;
		float u = clamp(age / life, 0.0, 1.0);

		// MODEL_MATRIX uses Basis.looking_at(vel.normalized(), up), so -MODEL_MATRIX[2] is unit launch dir.
		vec3 v0 = (-MODEL_MATRIX[2].xyz) * speed;
		float grav = is_dust ? -1.6 : -15.5;
		float drag = is_dust ? 2.6 : 0.55;

		float t_eff = age;
		float disp_y = 0.0;
		if (!is_dust) {
			float raw_y = v0.y * age + 0.5 * grav * age * age;
			if (raw_y < -0.03) {
				float disc = max(v0.y * v0.y - 2.0 * grav * 0.03, 0.0);
				t_eff = min(age, (-v0.y - sqrt(disc)) / grav);
				disp_y = -0.03;
			} else {
				disp_y = raw_y;
			}
		} else {
			float exp_d = (1.0 - exp(-drag * age)) / drag;
			disp_y = max(v0.y * exp_d + 0.5 * grav * age * age * 0.35, -0.03);
		}

		float exp_h = (1.0 - exp(-drag * t_eff)) / drag;
		vec2 disp_xz = v0.xz * exp_h;
		vec3 center = origin + vec3(disp_xz.x, disp_y, disp_xz.y);

		float cur_size = is_dust
			? size * (0.55 + 1.40 * pow(u, 0.65))
			: size * (0.90 + 0.20 * (1.0 - u));
		float dir_sign = seed > 0.5 ? 1.0 : -1.0;
		float spin_rate = is_dust ? (1.3 + seed * 1.5) : (7.5 + seed * 8.5);
		float ang = seed * 6.2831853 + dir_sign * spin_rate * t_eff;
		float ca = cos(ang);
		float sa = sin(ang);

		vec2 q = VERTEX.xy * cur_size;
		vec2 qr = vec2(q.x * ca - q.y * sa, q.x * sa + q.y * ca);
		vec3 cam_right = INV_VIEW_MATRIX[0].xyz;
		vec3 cam_up = INV_VIEW_MATRIX[1].xyz;
		vec3 cam_fwd = INV_VIEW_MATRIX[2].xyz;
		vec3 world = center + cam_right * qr.x + cam_up * qr.y;

		mat3 inv_rot = transpose(mat3(MODEL_MATRIX));
		VERTEX = inv_rot * (world - origin);
		vec2 quad_n = UV - vec2(0.5);
		vec3 dome_w = normalize(cam_fwd * 0.50 + vec3(0.0, 0.72, 0.0) + (cam_right * quad_n.x + cam_up * quad_n.y) * 0.90);
		NORMAL = normalize(inv_rot * dome_w);
		POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(world, 1.0));

		float fade = is_dust
			? smoothstep(0.0, 0.14, u) * (1.0 - smoothstep(0.30, 1.0, u))
			: smoothstep(0.0, 0.05, u) * (1.0 - smoothstep(0.66, 1.0, u));
		v_uv = UV;
		v_color = COLOR;
		v_alpha = COLOR.a * fade;
		v_kind = kind;
		v_seed = seed;
		v_life_t = u;
	}
}

void fragment() {
	if (v_alpha <= 0.005) {
		discard;
	}

	vec2 p = v_uv - vec2(0.5);
	float wet = clamp(f3d_weather_wet.x, 0.0, 1.0);

	if (v_kind < 0.5) {
		// Chunky tumbling dirt/mud clod cluster: 5 angular rocky soil lumps per billboard.
		float best = 0.0;
		float shade = 0.5;
		for (int i = 0; i < 5; i++) {
			float fi = float(i);
			float h0 = fract(sin(v_seed * 91.7 + fi * 17.31) * 43758.5453);
			float h1 = fract(sin(v_seed * 53.1 + fi * 31.17 + 4.1) * 28461.9123);
			float h2 = fract(sin(v_seed * 127.3 + fi * 11.89 + 9.7) * 19384.4217);
			float ang_c = h0 * 6.2831853;
			float dist_c = (i == 0) ? 0.05 * h1 : (0.14 + 0.19 * h1);
			vec2 cpos = vec2(cos(ang_c), sin(ang_c)) * dist_c;
			vec2 d = p - cpos;
			float r = length(d);
			float theta = atan(d.y, d.x);
			float jag = 0.78 + 0.22 * cos(theta * 3.0 + h2 * 6.2831853) + 0.14 * sin(theta * 5.0 - h0 * 6.2831853);
			float n_edge = _vnoise(d * 18.0 + vec2(v_seed * 11.0, fi * 7.0)) * 0.18;
			float rad = ((i == 0) ? 0.175 : mix(0.085, 0.145, h2)) * (jag + n_edge);
			float m = smoothstep(rad + 0.025, rad - 0.025, r);
			if (m > best) {
				best = m;
				// Subtle top-lit directional chunk relief.
				float lit = clamp(0.58 - d.y * 2.4 - d.x * 1.1, 0.22, 1.0);
				shade = lit * (0.76 + 0.24 * h2);
			}
		}

		float alpha = clamp(best * v_alpha, 0.0, 1.0);
		if (alpha < 0.02) {
			discard;
		}
		float tex = 0.84 + 0.28 * _vnoise(p * 24.0 + vec2(v_seed * 17.0, v_seed * 29.0));
		vec3 col = v_color.rgb * mix(0.42, 0.92, shade) * tex;
		col = mix(col, col * vec3(0.46, 0.42, 0.38), wet);
		ALBEDO = col;
		ALPHA = alpha;
		ROUGHNESS = mix(0.90, 0.35, smoothstep(0.15, 0.75, wet));
		SPECULAR = mix(0.16, 0.45, smoothstep(0.15, 0.75, wet));
		METALLIC = 0.0;
	} else {
		// Swirling ground-tinted dust/soil billow, attenuated on wet ground.
		float r = length(p);
		float n1 = _vnoise(p * 6.5 + vec2(v_seed * 13.7, v_life_t * 1.4));
		float n2 = _vnoise(p * 13.5 - vec2(v_life_t * 1.1, v_seed * 23.1));
		float fbm = n1 * 0.65 + n2 * 0.35;
		float shape = smoothstep(0.50, 0.14, r + (fbm - 0.5) * 0.24);
		float wet_atten = 1.0 - wet * 0.55;
		float alpha = clamp(shape * (0.55 + 0.45 * fbm) * v_alpha * wet_atten, 0.0, 0.72);
		if (alpha < 0.01) {
			discard;
		}
		vec3 col = mix(v_color.rgb, vec3(0.76, 0.70, 0.60), 0.26) * (0.85 + 0.22 * fbm);
		col = mix(col, col * 0.68, wet);
		ALBEDO = col;
		ALPHA = alpha;
		ROUGHNESS = 0.95;
		SPECULAR = 0.08;
		METALLIC = 0.0;
	}
}
