// Weather surface hooks (add-on API 1.8, scripts/world/weather_state.gd): wetness, puddles,
// raindrop ripples, and side drips on terrain, water, and models. Zero cost / unchanged output
// when f3d_weather_wet is zero. Requires noise.gdshaderinc (`vnoise`, `fbm3`, `hash12`).

// Its clock: TIME, or factorio_material.gdshaderinc's F3D_TIME (static buildings, --static-mv).
#ifndef F3D_TIME
#define F3D_TIME TIME
#endif

// x: ground_wetness (0..1), y: model_wetness (0..1), z: puddle_amount (0..1), w: rain_ripples (0..1)
global uniform vec4 f3d_weather_wet;
// x: puddle_scale, y: puddle_reflect (0..1.5), z: wet_darken (0..1), w: model_puddles (0..1)
global uniform vec4 f3d_weather_puddle;
// 64x2 RGBAF puddle impulse buffer: row 0 = (x, z, spawn_t, max_r), row 1 = (dir_x, dir_z, amp, life).
global uniform sampler2D f3d_weather_impulses;
// x: active impulse count, y: wrapped clock (0..10000), z: strength multiplier, w: active flag (>0).
global uniform vec4 f3d_weather_impulse_info;
// Tight world XZ AABB enclosing all active impulses: (min_x, min_z, max_x, max_z).
global uniform vec4 f3d_weather_impulse_bounds;
// 1: cliffs and rocks (factorio_material wet_rock) wet like rough stone; 0: --wet-rock=old, as any model.
global uniform float f3d_wet_rock;
// 1: wet metal dampened under water film with gentler roughness/pools/drips; 0: --wet-metal=old, previous wetness.
global uniform float f3d_wet_metal;

// Single staggered grid layer of expanding concentric raindrop ring gradients (XZ normal tilt).
vec2 _weather_ripple_layer(vec2 p, float t, float salt) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	vec2 grad = vec2(0.0);
	for (int dy = 0; dy <= 1; dy++) {
		for (int dx = 0; dx <= 1; dx++) {
			vec2 c = cell + vec2(float(dx), float(dy));
			float h0 = hash12(c + salt);
			float h1 = hash12(c + salt + 19.31);
			float h2 = hash12(c + salt + 43.71);
			float phase = fract(t * (0.85 + 0.45 * h0) + h1);
			// Active ~65% of each cell's cycle so rings come and go organically.
			float life = clamp(phase / 0.72, 0.0, 1.0);
			if (phase < 0.72) {
				vec2 center = vec2(float(dx), float(dy)) + 0.2 + 0.6 * vec2(h1, h2);
				vec2 diff = f - center;
				float d = length(diff);
				float radius = life * 0.62;
				float ring_dist = d - radius;
				if (abs(ring_dist) < 0.14 && d > 1e-4) {
					float env = sin(life * 3.14159265) * smoothstep(0.14, 0.0, abs(ring_dist));
					float wave = cos(ring_dist * 46.0);
					grad += (diff / d) * (wave * env * 0.28);
				}
			}
		}
	}
	return grad;
}

// Combined two-layer raindrop ripple normal tilt, attenuated smoothly by distance.
vec2 weather_ripple_grad(vec2 pos, float rain, float time, float dist_cam) {
	if (rain <= 0.005) {
		return vec2(0.0);
	}
	float px_fade = 1.0 - smoothstep(45.0, 110.0, dist_cam);
	if (px_fade <= 0.001) {
		return vec2(0.0);
	}
	vec2 g0 = _weather_ripple_layer(pos * 1.85, time * 1.35, 3.1);
	vec2 g1 = _weather_ripple_layer(pos * 2.75 + vec2(11.7, 5.3), time * 1.65, 29.7);
	return (g0 + g1 * 0.7) * clamp(rain, 0.0, 1.0) * px_fade;
}

// Expanding directional wakes and dispersive wave packets from vehicles driving through puddles.
vec2 _weather_puddle_impulses(vec2 world_xz, float dist_cam, out float churn_out) {
	churn_out = 0.0;
	if (f3d_weather_impulse_info.w <= 0.001 || dist_cam > 110.0) {
		return vec2(0.0);
	}
	vec4 b = f3d_weather_impulse_bounds;
	if (world_xz.x < b.x || world_xz.x > b.z || world_xz.y < b.y || world_xz.y > b.w) {
		return vec2(0.0);
	}
	int count = clamp(int(f3d_weather_impulse_info.x + 0.5), 0, 64);
	float now_t = f3d_weather_impulse_info.y;
	float str_k = f3d_weather_impulse_info.z;
	vec2 grad = vec2(0.0);
	float churn = 0.0;
	for (int i = 0; i < count; i++) {
		vec4 r0 = texelFetch(f3d_weather_impulses, ivec2(i, 0), 0);
		vec4 r1 = texelFetch(f3d_weather_impulses, ivec2(i, 1), 0);
		float age = mod(now_t - r0.z + 10000.0, 10000.0);
		if (age < 0.0 || age >= r1.w || r0.w <= 0.01) {
			continue;
		}
		vec2 diff = world_xz - r0.xy;
		float d2 = dot(diff, diff);
		if (d2 > r0.w * r0.w) {
			continue;
		}
		float d = sqrt(d2);
		vec2 radial = d > 1e-4 ? diff / d : vec2(0.0);
		float t = age / r1.w;
		float start_r = min(0.32, r0.w * 0.2);
		float r_front = start_r + (r0.w - start_r) * pow(max(t, 0.0001), 0.72);
		float ring_dist = d - r_front;
		float trail_w = mix(0.68, 1.45, t);
		float packet = ring_dist > 0.0
			? (1.0 - smoothstep(0.0, 0.20, ring_dist))
			: smoothstep(-trail_w, 0.0, ring_dist);
		float k = mix(28.0, 15.0, t);
		// Crisp leading bow crest aligned with 3-4 dispersive trailing ripple rings.
		float bow_crest = -sin(clamp(ring_dist / 0.15, -1.0, 1.0) * 3.14159265)
			* smoothstep(0.17, 0.0, abs(ring_dist)) * (1.0 - t * 0.42);
		float wave = -sin(ring_dist * k) * packet + bow_crest * 0.65;
		float env = sin(pow(clamp(t, 0.0, 1.0), 0.72) * 3.14159265) * (1.0 - t * 0.30);
		float dir_w = 1.0;
		if (dot(r1.xy, r1.xy) > 0.01) {
			vec2 dir_n = normalize(r1.xy);
			dir_w = 0.60 + 0.55 * clamp(1.0 - abs(dot(radial, dir_n) + 0.30), 0.0, 1.0);
		}
		grad += radial * (wave * env * r1.z * dir_w * 1.48);
		float churn_rad = min(max(start_r * 2.5, 0.82), r0.w * 0.55);
		if (d < churn_rad && t < 0.76) {
			float churn_r = 1.0 - smoothstep(0.0, churn_rad, d);
			float churn_t = 1.0 - smoothstep(0.0, 0.76, t);
			float churn_mask = churn_r * churn_t * clamp(r1.z, 0.0, 2.2);
			vec3 cn = noised(world_xz * 10.5 - r1.xy * age * 3.5);
			grad += cn.yz * (churn_mask * 0.46);
			float c = churn_mask * (0.40 + 0.60 * cn.x) * 0.68;
			churn = clamp(churn + c, 0.0, 1.0);
		}
	}
	float px_fade = 1.0 - smoothstep(50.0, 110.0, dist_cam);
	churn_out = clamp(churn * px_fade * str_k, 0.0, 1.0);
	vec2 out_grad = grad * px_fade * str_k;
	float g_len = length(out_grad);
	if (g_len > 2.6) {
		out_grad *= (2.6 / g_len);
	}
	return out_grad;
}

void weather_apply_ground(
	vec2 world_xz,
	vec3 hill_nrm,
	float cavity,
	float is_floor,
	float dist_cam,
	inout vec3 albedo,
	inout float roughness,
	inout float specular,
	inout vec2 normal_grad,
	inout vec3 emission,
	vec3 sky_hint
) {
	float wet = clamp(f3d_weather_wet.x, 0.0, 1.0);
	float puddle_amt = clamp(f3d_weather_wet.z, 0.0, 1.0);
	if (wet <= 0.001 && puddle_amt <= 0.001) {
		return;
	}
	float dark_k = clamp(f3d_weather_puddle.z, 0.0, 1.0);
	float reflect_k = clamp(f3d_weather_puddle.y, 0.0, 1.5);
	float darken = dark_k * mix(0.46, 0.30, is_floor) * wet;
	albedo *= (1.0 - darken);
	roughness = mix(roughness, mix(0.48, 0.26, is_floor), wet * 0.78);
	specular = max(specular, mix(0.22, 0.42, is_floor) * wet);

	if (puddle_amt <= 0.001) {
		return;
	}
	float dist_fade = 1.0 - smoothstep(140.0, 320.0, dist_cam);
	if (dist_fade <= 0.001) {
		return;
	}
	float flat_mask = smoothstep(0.92, 0.985, hill_nrm.y);
	float scale = max(f3d_weather_puddle.x, 0.02);
	// Multi-scale organic basins: fbm3 (~0.5 mean) + fine breakup + low-ground bias.
	float n = fbm3(world_xz * scale + vec2(3.7, 11.3)) + (vnoise(world_xz * scale * 2.9 + vec2(17.1, -9.4)) - 0.5) * 0.14 + cavity * 0.10 + is_floor * 0.05;
	// ~8% coverage at drizzle, ~25% steady rain, ~38% downpour.
	float thresh = mix(0.73, 0.51, puddle_amt);
	float p = smoothstep(thresh, thresh + 0.045, n) * flat_mask * smoothstep(0.0, 0.08, puddle_amt) * dist_fade;
	// Dark damp meniscus just outside the puddle border.
	float rim = smoothstep(thresh - 0.065, thresh + 0.008, n) * (1.0 - p) * flat_mask * dist_fade;
	albedo *= (1.0 - 0.24 * rim * dark_k);
	if (p <= 0.001) {
		return;
	}
	// sky_hint is intentionally not added to albedo (it washed out grass and glowed at night).
	albedo *= mix(1.0, 0.40, p);
	normal_grad *= (1.0 - p * 0.96);
	roughness = mix(roughness, 0.045, p);
	specular = mix(specular, clamp(0.48 * reflect_k, 0.0, 0.85), p);
	emission *= mix(1.0, 1.0 + 0.35 * reflect_k, p);
	float churn = 0.0;
	if (f3d_weather_impulse_info.w > 0.001) {
		vec2 imp_grad = _weather_puddle_impulses(world_xz, dist_cam, churn);
		normal_grad += imp_grad * p * dist_fade;
		roughness = mix(roughness, 0.34, churn * p * 0.85);
		albedo += vec3(0.085, 0.095, 0.105) * churn * p * dist_fade;
	}
	if (f3d_weather_wet.w > 0.005) {
		float rain_keep = 1.0 - clamp(churn * 1.4, 0.0, 0.92);
		normal_grad += weather_ripple_grad(world_xz, f3d_weather_wet.w, F3D_TIME, dist_cam) * p * dist_fade * rain_keep;
	}
}

void weather_apply_model(
	vec2 world_xz,
	float world_y,
	vec3 world_nrm,
	float covered,
	float dist_cam,
	int surface_kind,
	inout vec3 albedo,
	inout float roughness,
	inout float specular,
	inout float metallic,
	inout vec3 normal_view,
	mat4 view_mat
) {
	float wet_raw = clamp(f3d_weather_wet.y, 0.0, 1.0);
	if (wet_raw <= 0.001) {
		return;
	}
	float wet = wet_raw * (1.0 - clamp(covered, 0.0, 1.0) * 0.85);
	float up = clamp(world_nrm.y, 0.0, 1.0);
	float expose = mix(0.55, 1.0, smoothstep(0.1, 0.8, up));
	float dark_k = clamp(f3d_weather_puddle.z, 0.0, 1.0);
	float reflect_k = clamp(f3d_weather_puddle.y, 0.0, 1.5);
	if (surface_kind == 1) {
		// Rough stone (cliffs' big flat facets mirrored the sky whole): mostly darker, a little glossier,
		// never shiny; no puddles, ripple rings or drips.
		float k = wet * expose;
		albedo *= 1.0 - (0.10 + 0.12 * dark_k) * k;
		roughness = mix(roughness, min(roughness, max(roughness * 0.75, 0.55)), k);
		specular = mix(specular, max(min(specular, 0.3), 0.22), k);
		return;
	}
	if (surface_kind == 2) {
		// Organic creatures (chitin, flesh): rain-dampened without roof puddles, ripple rings,
		// or mirror-plastic glare; preserves surface roughness variation and tier colour.
		float k = wet * expose;
		albedo *= 1.0 - (0.06 + 0.10 * dark_k) * k;
		float wet_rough = max(roughness * 0.68, mix(0.52, 0.44, up));
		roughness = mix(roughness, min(roughness, wet_rough), k * 0.80);
		specular = mix(specular, clamp(max(specular, 0.34), 0.24, 0.38), k);
		return;
	}
	bool wet_metal_new = f3d_wet_metal > 0.5;
	float metal_k = wet_metal_new ? clamp(metallic, 0.0, 1.0) : 0.0;
	if (wet_metal_new) {
		// Dielectric water film over metal: dampens conductor reflectance so wet armor keeps readable
		// diffuse shading at night, and keeps wet roughness gentle instead of mirror chrome.
		float film = wet * expose;
		albedo *= 1.0 - dark_k * mix(0.24, 0.14, metal_k) * film;
		metallic *= mix(1.0, 0.52, film);
		float target_rough = mix(mix(0.34, 0.24, up), mix(0.42, 0.32, up), metal_k);
		roughness = mix(roughness, min(roughness, target_rough), film * mix(0.78, 0.65, metal_k));
		specular = max(specular, mix(0.48, 0.40, metal_k) * film);
	} else {
		albedo *= 1.0 - dark_k * 0.24 * wet * expose;
		roughness = mix(roughness, mix(0.24, 0.16, up), wet * expose * 0.82);
		specular = max(specular, 0.52 * wet * expose);
	}

	float dist_fade = 1.0 - smoothstep(100.0, 220.0, dist_cam);
	if (dist_fade <= 0.001) {
		return;
	}
	vec2 tilt = vec2(0.0);
	float mod_puddle = clamp(f3d_weather_puddle.w, 0.0, 1.0);
	if (mod_puddle > 0.001 && up > 0.84) {
		float pn = vnoise(world_xz * 1.35 + vec2(world_y * 2.1, -world_y * 1.7));
		float p_thresh = mix(0.75, 0.48, mod_puddle);
		float pool = smoothstep(p_thresh, p_thresh + 0.09, pn) * smoothstep(0.84, 0.94, up) * wet * dist_fade;
		if (pool > 0.001) {
			albedo *= mix(1.0, 0.62, pool);
			if (wet_metal_new) {
				metallic *= mix(1.0, 0.65, pool);
				roughness = mix(roughness, min(roughness, mix(0.14, 0.22, metal_k)), pool);
				specular = mix(specular, clamp(0.48 * reflect_k, 0.0, 0.65), pool);
			} else {
				roughness = mix(roughness, 0.05, pool);
				specular = mix(specular, clamp(0.55 * reflect_k, 0.0, 0.90), pool);
			}
			if (f3d_weather_wet.w > 0.01 && dist_cam < 80.0) {
				tilt = weather_ripple_grad(world_xz * 1.4, f3d_weather_wet.w, F3D_TIME, dist_cam) * pool * 0.7;
			}
		}
	}
	float side = clamp(1.0 - abs(world_nrm.y), 0.0, 1.0);
	if (f3d_weather_wet.w > 0.1 && side > 0.3 && dist_cam < 60.0) {
		// Streaks scroll downward (pattern phase advances with F3D_TIME at fixed world_y).
		float streak = smoothstep(0.50, 0.82, vnoise(vec2((world_xz.x + world_xz.y) * 9.0, world_y * 4.0 + F3D_TIME * 2.2)));
		float drip = streak * side * wet * clamp(f3d_weather_wet.w, 0.0, 1.0);
		if (wet_metal_new) {
			roughness = mix(roughness, min(roughness, mix(0.18, 0.28, metal_k)), drip * 0.55);
		} else {
			roughness = mix(roughness, 0.07, drip * 0.65);
		}
		albedo *= (1.0 - 0.06 * drip * dark_k);
	}
	if (dot(tilt, tilt) > 1e-7) {
		vec3 perturbed = normalize(world_nrm + vec3(-tilt.x, 0.0, -tilt.y));
		normal_view = normalize((view_mat * vec4(perturbed, 0.0)).xyz);
	}
}

vec2 weather_water_ripples(vec2 world_xz, float dist_cam) {
	if (f3d_weather_wet.w <= 0.001 || dist_cam > 160.0) {
		return vec2(0.0);
	}
	return weather_ripple_grad(world_xz * 0.9, f3d_weather_wet.w, F3D_TIME, dist_cam);
}
