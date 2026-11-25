shader_type spatial;
render_mode cull_disabled, depth_draw_never, blend_mix;

// Lit PBR 3D ballistic vehicle splash sheets, droplet clusters, and wet spray mist
// for the Immersive Weather add-on (weather_puddles.gd).
//
// Instance layout (MODEL_MATRIX uses orthonormal Basis.IDENTITY so normals stay valid):
// - MODEL_MATRIX[3].xyz: spawn world position (x, ground_y, z)
// - COLOR.rgb: encoded initial velocity (vel / 24.0 + 0.5)
// - COLOR.a: intensity weight (0..1)
// - INSTANCE_CUSTOM: (spawn_time, life, size, kind + seed)
//   kind = floor(w): 0.0 liquid fan sheet, 1.0 droplet cluster, 2.0 spray mist

uniform float now = 0.0;
uniform vec2 wind = vec2(0.0);
uniform float visibility : hint_range(0.0, 2.0) = 1.0;
uniform float day_factor : hint_range(0.0, 1.0) = 1.0;
uniform vec3 splash_tint : source_color = vec3(0.76, 0.82, 0.89);

varying vec2 v_local;
varying float v_age;
varying float v_alive;
varying float v_kind;
varying float v_seed;
varying float v_weight;
varying float v_dist_fade;
varying vec3 v_axis_x;
varying vec3 v_axis_y;
varying vec3 v_cam_back;

float hash12(vec2 p) {
	p = mod(p, 4096.0);
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 x) {
	vec2 i = floor(x);
	vec2 f = fract(x);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void vertex() {
	vec4 c = INSTANCE_CUSTOM;
	float age = mod(now - c.x + 1000.0, 1000.0);
	float life = max(c.y, 0.001);
	float alive = (c.y > 0.001 && age >= 0.0 && age < life && c.z > 0.0001 && COLOR.a > 0.001) ? 1.0 : 0.0;
	v_alive = alive;

	float t_norm = clamp(age / life, 0.0, 1.0);
	v_age = t_norm;
	float kind = floor(c.w);
	float seed = fract(c.w);
	v_kind = kind;
	v_seed = seed;
	v_weight = COLOR.a;
	v_local = VERTEX.xy * 2.0;

	if (alive < 0.5) {
		v_dist_fade = 0.0;
		v_axis_x = vec3(1.0, 0.0, 0.0);
		v_axis_y = vec3(0.0, 1.0, 0.0);
		v_cam_back = vec3(0.0, 0.0, 1.0);
		VERTEX = vec3(0.0);
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	} else {
		vec3 origin = MODEL_MATRIX[3].xyz;
		vec3 v0 = (COLOR.rgb - 0.5) * 24.0;
		float drag = kind > 1.5 ? 2.6 : (kind > 0.5 ? 0.65 : 1.10);
		float g = kind > 1.5 ? -1.6 : (kind > 0.5 ? -13.5 : -10.2);
		float e_drag = exp(-drag * age);
		float h_exp = (1.0 - e_drag) / drag;
		vec2 wind_eff = wind * (kind > 1.5 ? 0.52 : (kind > 0.5 ? 0.12 : 0.22));

		vec3 pos = origin;
		pos.x += v0.x * h_exp + wind_eff.x * (age - h_exp);
		pos.z += v0.z * h_exp + wind_eff.y * (age - h_exp);
		pos.y += v0.y * age + 0.5 * g * age * age;
		pos.y = max(pos.y, origin.y - 0.04);

		vec3 v_now = vec3(
			v0.x * e_drag + wind_eff.x * (1.0 - e_drag),
			v0.y + g * age,
			v0.z * e_drag + wind_eff.y * (1.0 - e_drag)
		);

		vec3 cam_right = normalize(vec3(VIEW_MATRIX[0][0], VIEW_MATRIX[1][0], VIEW_MATRIX[2][0]));
		vec3 cam_up = normalize(vec3(VIEW_MATRIX[0][1], VIEW_MATRIX[1][1], VIEW_MATRIX[2][1]));
		vec3 cam_back = normalize(vec3(VIEW_MATRIX[0][2], VIEW_MATRIX[1][2], VIEW_MATRIX[2][2]));

		vec2 v_screen = vec2(dot(v_now, cam_right), dot(v_now, cam_up));
		float v_len = length(v_screen);
		vec3 axis_x = cam_right;
		vec3 axis_y = cam_up;
		if (kind < 1.5 && v_len > 0.05) {
			vec2 dir2 = v_screen / v_len;
			axis_y = cam_right * dir2.x + cam_up * dir2.y;
			axis_x = cam_right * dir2.y - cam_up * dir2.x;
		} else if (kind > 1.5) {
			float ang = (seed - 0.5) * 6.2831853 + t_norm * (seed > 0.5 ? 0.55 : -0.55);
			float ca = cos(ang);
			float sa = sin(ang);
			axis_x = cam_right * ca + cam_up * sa;
			axis_y = -cam_right * sa + cam_up * ca;
		}

		float base_size = c.z;
		float width = base_size;
		float stretch = base_size;
		if (kind < 0.5) {
			float expand = mix(0.58, 1.72, pow(t_norm, 0.62));
			width = base_size * expand * 1.22;
			stretch = base_size * expand * (1.28 + clamp(v_len * 0.09, 0.0, 1.40));
		} else if (kind < 1.5) {
			float spread_k = mix(0.80, 1.24, pow(t_norm, 0.72));
			width = base_size * spread_k;
			stretch = base_size * spread_k * (1.05 + clamp(v_len * 0.075, 0.0, 0.85));
		} else {
			float mist_scale = base_size * mix(0.76, 2.48, pow(t_norm, 0.68));
			width = mist_scale;
			stretch = mist_scale;
		}

		vec3 world = pos + axis_x * (VERTEX.x * width) + axis_y * (VERTEX.y * stretch);
		float cam_dist = length(CAMERA_POSITION_WORLD - pos);
		v_dist_fade = smoothstep(1.2, 2.8, cam_dist) * (1.0 - smoothstep(42.0, 64.0, cam_dist));
		v_axis_x = axis_x;
		v_axis_y = axis_y;
		v_cam_back = cam_back;

		// Update local VERTEX alongside POSITION so view-space VERTEX is accurate for SpotLight/OmniLight shading.
		VERTEX = world - origin;
		NORMAL = normalize(mix(cam_back, vec3(0.0, 1.0, 0.0), 0.32));
		POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(world, 1.0));
	}
}

void fragment() {
	if (v_alive < 0.5 || v_dist_fade <= 0.001) {
		discard;
	}

	float alpha_shape = 0.0;
	float foam = 0.0;
	float rough = 0.20;
	float spec = 0.85;
	vec2 n_xy = v_local * 0.55;

	if (v_kind < 0.5) {
		// Kind 0: Curved dramatic water-wall curtain with 2-octave liquid-filament tearing,
		// thick frothy base tapering into ragged tendrils and separated outer tip beads.
		vec2 q = v_local;
		float curve_y = q.y + 0.24 * q.x * q.x;
		float fan_w = mix(0.48, 1.02, smoothstep(-0.95, 0.55, q.y));
		float lat = q.x / fan_w;
		float env_x = 1.0 - smoothstep(0.32, 1.0, abs(lat));
		float env_y = smoothstep(-0.98, -0.35, q.y) * (1.0 - smoothstep(0.28, 0.96, curve_y));
		float sheet_env = env_x * env_y;

		vec2 fuv = vec2(lat * 4.2 + v_seed * 19.3, q.y * 1.55 - v_age * 2.4 + v_seed * 11.7);
		float fil = vnoise(fuv) * 0.62 + vnoise(fuv * 2.35 + vec2(3.7, -5.1)) * 0.38;
		float base_fill = smoothstep(0.35, -0.55, q.y) * 0.38;
		float tear_lo = mix(0.22, 0.54, v_age) + smoothstep(-0.10, 0.85, q.y) * 0.24;
		float tear = smoothstep(tear_lo, tear_lo + 0.28, fil + base_fill + sheet_env * 0.35);

		float tip_mask = smoothstep(0.10, 0.55, q.y) * (1.0 - smoothstep(0.68, 0.98, curve_y)) * env_x;
		float tip_n = vnoise(vec2(lat * 9.5 + v_seed * 31.1, q.y * 5.0 - v_age * 3.2));
		float tip_beads = smoothstep(0.66, 0.82, tip_n) * tip_mask * (1.0 - smoothstep(0.55, 1.0, v_age));

		float shape = max(sheet_env * tear, tip_beads * 0.90);
		float life_fade = smoothstep(0.0, 0.08, v_age) * (1.0 - smoothstep(0.46, 1.0, v_age));
		alpha_shape = clamp(shape * life_fade * 0.62, 0.0, 0.68);

		float rim_band = smoothstep(0.08, 0.66, curve_y) * smoothstep(0.96, 0.40, curve_y);
		float base_froth = smoothstep(0.08, -0.75, q.y) * 0.48;
		foam = clamp(rim_band * 0.52 + smoothstep(0.58, 0.88, fil) * 0.35 + base_froth + tip_beads * 0.55, 0.0, 1.0);
		rough = mix(0.13, 0.24, base_froth);
		spec = 0.90;
		n_xy = vec2(q.x * 0.68, q.y * 0.52);
	} else if (v_kind < 1.5) {
		// Kind 1: 12 crisp, fine, motion-streaked micro-droplets with per-drop domed sparkle.
		float drops = 0.0;
		float glint = 0.0;
		vec2 drop_n = vec2(0.0);
		float spread = mix(0.64, 0.90, v_age);
		for (int i = 0; i < 12; i++) {
			float fi = float(i);
			float h0 = fract(v_seed * 17.31 + fi * 0.75487766);
			float h1 = fract(v_seed * 31.73 + fi * 0.56984029);
			float h2 = fract(v_seed * 53.19 + fi * 0.38196601);
			vec2 dp = vec2((h0 - 0.5) * 1.68 * spread, (h1 - 0.5) * 1.56 * spread);
			vec2 d = (v_local - dp) * vec2(1.45, 0.58);
			float r = mix(0.024, 0.056, h2);
			float dd = length(d);
			if (dd < r) {
				float bead = 1.0 - smoothstep(r * 0.56, r, dd);
				if (bead > drops) {
					drops = bead;
					drop_n = d / r;
					float spec_pt = 1.0 - smoothstep(0.0, r * 0.46, length(d - vec2(-0.16, 0.20) * r));
					float edge_fres = smoothstep(r * 0.35, r * 0.85, dd);
					glint = clamp(spec_pt * 0.85 + edge_fres * 0.65, 0.0, 1.0);
				}
			}
		}
		if (drops <= 0.001) {
			discard;
		}
		float bound = 1.0 - smoothstep(0.84, 0.99, max(abs(v_local.x), abs(v_local.y)));
		float life_fade = smoothstep(0.0, 0.06, v_age) * (1.0 - smoothstep(0.64, 1.0, v_age));
		alpha_shape = drops * bound * life_fade * mix(0.70, 0.94, glint);
		foam = glint * 0.62;
		rough = 0.07;
		spec = 0.95;
		n_xy = drop_n * vec2(0.82, 0.62);
	} else {
		// Kind 2: Billowing ground-hugging water-vapor and splash-collar mist around tracks/wheels.
		float r = length(v_local);
		float radial = 1.0 - smoothstep(0.10, 0.98, r);
		vec2 muv = v_local * 2.1 + vec2(v_seed * 19.1, -v_age * 1.25 + v_seed * 7.3);
		float wisp = vnoise(muv) * 0.60 + vnoise(muv * 2.15 + vec2(3.3 + v_age * 0.6, 5.7 - v_age * 0.5)) * 0.40;
		float life_fade = smoothstep(0.0, 0.14, v_age) * (1.0 - smoothstep(0.32, 1.0, v_age));
		alpha_shape = radial * radial * smoothstep(0.20, 0.82, wisp) * life_fade * 0.24;
		foam = clamp(0.32 + wisp * 0.28, 0.0, 0.65);
		rough = 0.48;
		spec = 0.32;
		n_xy = v_local * 0.42;
	}

	// Smoothly domed view-space normal facing the camera with upward sky bias so sun,
	// tank headlights, firelight, and lightning shade droplets and sheets naturally.
	vec3 world_n = normalize(
		v_axis_x * n_xy.x +
		v_axis_y * n_xy.y +
		v_cam_back * 0.90 +
		vec3(0.0, 0.40, 0.0)
	);
	NORMAL = normalize((VIEW_MATRIX * vec4(world_n, 0.0)).xyz);
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.6);
	if (v_kind < 0.5) {
		foam = clamp(foam + fresnel * 0.38, 0.0, 1.0);
	} else if (v_kind < 1.5) {
		foam = clamp(foam + fresnel * 0.72, 0.0, 1.0);
		alpha_shape = min(alpha_shape * (1.0 + fresnel * 0.22), 0.96);
	}

	vec3 water_col = splash_tint * vec3(0.84, 0.90, 0.96);
	vec3 col = mix(water_col, vec3(0.96, 0.99, 1.0), foam * 0.70);
	ALBEDO = col;
	ROUGHNESS = rough;
	SPECULAR = spec;
	EMISSION = col * (0.02 + 0.065 * day_factor);
	ALPHA = clamp(alpha_shape * v_weight * visibility * v_dist_fade, 0.0, 1.0);
	if (ALPHA <= 0.002) {
		discard;
	}
}
