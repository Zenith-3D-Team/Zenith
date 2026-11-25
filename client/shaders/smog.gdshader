// Volumetric smog over polluted ground and rising into the sky (scripts/world/pollution.gd,
// Settings > Graphics > Smog), in one full-screen premultiplied-alpha pass after opaque geometry
// and transparent FX. Lifts into convective plumes and a cached aloft smog deck above polluted
// chunks, samples pre-baked mipmapped billow noise, forward-scatters sunlight, catches cloud
// shadows, and extends to the far horizon via a cheap cached far band.
// `--smog-look=old` (`volumetric = 0.0`) restores the thin ground-hugging layer.
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled, shadows_disabled;

#include "res://shaders/noise.gdshaderinc"
#include "res://shaders/ground_height.gdshaderinc"
#include "res://shaders/pollution.gdshaderinc"
#include "res://shaders/cloud_shadow_sample.gdshaderinc"

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform sampler2D smog_noise : hint_default_white, filter_linear_mipmap, repeat_enable;
// The Smog setting, 0 to 1 (0.5 by default).
uniform float strength = 0.5;
// How deep the legacy ground layer sits over the ground, in tiles (`volumetric = 0.0`).
uniform float height = 5.0;
// Haze per tile of view ray through it, at the worst pollution.
uniform float density = 0.08;
// Factorio's pollution is a brownish grey (its map's pollution overlay, its smoke).
uniform vec3 smog_color : source_color = vec3(0.37, 0.34, 0.27);
// The day's light on it (pollution.gd, from the game's darkness): unshaded, so it dims by hand.
uniform float light = 1.0;
// Where nothing was drawn (the sky), how far the ray is taken.
uniform float far = 1600.0;
// 1.0: volumetric ground-to-sky raymarch; 0.0: legacy 5-tile ground layer (--smog-look=old).
uniform float volumetric = 1.0;
uniform float sky_height = 175.0;
uniform vec2 ground_range = vec2(0.0, 0.0);
uniform vec3 sun_dir = vec3(0.0, 0.7, -0.7);
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.85);
uniform vec3 ambient_color : source_color = vec3(0.75, 0.78, 0.82);
uniform float sun_strength = 1.0;
uniform float twilight = 0.0;
uniform vec2 scene_light = vec2(1.0);

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

vec3 view_point(vec2 uv, float depth, mat4 inv_projection) {
	vec4 p = inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	return p.xyz / p.w;
}

float smog_ign(vec2 px) {
	return fract(52.9829189 * fract(dot(px, vec2(0.06711056, 0.00583715))));
}

float smog_hg(float cos_theta, float g) {
	float gg = g * g;
	return (1.0 - gg) / (4.0 * 3.14159265 * pow(max(1.0 + gg - 2.0 * g * cos_theta, 0.01), 1.5));
}

float smog_billow(vec3 p, float h, float lod) {
	vec2 wind = TIME * vec2(2.6, 1.1);
	vec2 drift = vec2(h * 0.35, h * 0.15);
	vec2 uv1 = (p.xz - wind * 0.65 - drift) * 0.0048;
	float base_n = textureLod(smog_noise, uv1, lod).r;
	vec2 rot_xz = vec2(p.x * 0.8 - p.z * 0.6, p.x * 0.6 + p.z * 0.8);
	vec2 uv2 = (rot_xz - wind * 1.15 + vec2(-h * 0.25, h * 0.32)) * 0.011 + vec2(base_n * 0.22, -base_n * 0.16);
	float det_n = textureLod(smog_noise, uv2, lod).r;
	float strata = 0.5 + 0.5 * sin(h * 0.095 + base_n * 5.4 - TIME * 0.18);
	float shape = base_n * 0.56 + det_n * 0.28 + strata * 0.16;
	return smoothstep(0.16, 0.86, shape);
}

float smog_vertical(float h, float pol_l, float pol_a, float high_view) {
	float low_band = 0.36 * pol_l * exp(-max(h, 0.0) / 9.0) * smoothstep(-1.0, 1.5, h);
	float plume_h = smoothstep(2.5, 16.0, h) * exp(-max(h - 16.0, 0.0) / mix(28.0, 58.0, pol_l));
	float plume_band = 0.92 * pow(max(pol_l, 1e-4), 0.72) * step(0.002, pol_l) * plume_h;
	float deck_h = smoothstep(14.0, 46.0, h) * exp(-max(h - 48.0, 0.0) / mix(34.0, 64.0, pol_a)) * smoothstep(sky_height, sky_height * 0.68, h);
	float deck_band = 0.85 * pow(max(pol_a, 1e-4), 0.68) * step(0.002, pol_a) * deck_h;
	return clamp(low_band + (plume_band + deck_band) * high_view, 0.0, 1.45);
}

vec3 smog_step_color(float h, float pol_m, float sun_vis, float phase) {
	float h_norm = clamp(h / 70.0, 0.0, 1.0);
	float self_lit = exp(-pol_m * (1.0 - h_norm) * 0.95);
	vec3 base_col = mix(smog_color * 0.88, smog_color * 1.24 + vec3(0.06, 0.05, 0.03), h_norm * 0.75);
	vec3 amb_term = base_col * mix(vec3(light), ambient_color * light, 0.55) * mix(0.45, 0.95, h_norm) * scene_light.x;
	vec3 sun_term = mix(base_col * 1.35, sun_color, 0.52) * sun_vis * self_lit * (0.30 + 1.25 * phase) * mix(1.0, 1.35, twilight) * scene_light.y;
	return amb_term + sun_term;
}

void fragment() {
	if (strength <= 0.001) {
		discard;
	}
	// The ray worked out in view space and then turned into the world (remote_fog.gdshader: two
	// points near the camera subtracted in world space lose precision far from the map's origin).
	// Reverse depth: 1 is the near plane.
	vec3 near_v = view_point(SCREEN_UV, 1.0, INV_PROJECTION_MATRIX);
	vec3 dir = normalize(mat3(INV_VIEW_MATRIX) * (view_point(SCREEN_UV, 0.5, INV_PROJECTION_MATRIX) - near_v));
	vec3 origin = (INV_VIEW_MATRIX * vec4(near_v, 1.0)).xyz;
	float depth = texture(depth_texture, SCREEN_UV).r;

	if (volumetric < 0.5) {
		vec3 end = origin + dir * far;
		if (depth > 0.0) {
			end = (INV_VIEW_MATRIX * vec4(view_point(SCREEN_UV, depth, INV_PROJECTION_MATRIX), 1.0)).xyz;
		}
		float ground = ground_h(end.xz);
		float y0 = ground - 1.0;
		float y1 = ground + height;
		vec3 d = end - origin;
		float t0 = 0.0;
		float t1 = 1.0;
		if (abs(d.y) > 1e-5) {
			float ta = (y0 - origin.y) / d.y;
			float tb = (y1 - origin.y) / d.y;
			t0 = max(t0, min(ta, tb));
			t1 = min(t1, max(ta, tb));
		} else if (origin.y < y0 || origin.y > y1) {
			discard;
		}
		if (t1 <= t0) {
			discard;
		}
		vec3 a = origin + d * t0;
		vec3 b = origin + d * t1;
		float s = 0.5 * (pollution_at(a.xz).g + pollution_at(b.xz).g);
		if (s < 0.002) {
			discard;
		}
		vec2 mid = 0.5 * (a.xz + b.xz);
		float n = fbm3(mid * 0.035 + TIME * vec2(0.012, 0.005));
		float k = density * s * (0.55 + 0.9 * n);
		float thick = 1.0 - exp(-k * distance(a, b));
		float alpha = clamp(thick * strength * 1.6, 0.0, 0.85);
		ALBEDO = smog_color * light * alpha;
		ALPHA = alpha;
	} else {
		float max_dist = far;
		if (depth > 0.0) {
			vec3 hit = (INV_VIEW_MATRIX * vec4(view_point(SCREEN_UV, depth, INV_PROJECTION_MATRIX), 1.0)).xyz;
			max_dist = min(distance(origin, hit), max_dist);
		}
		float y0 = ground_range.x - 1.5;
		float y1 = ground_range.y + sky_height;
		float t_start = 0.0;
		float t_end = max_dist;
		if (abs(dir.y) > 1e-5) {
			float ta = (y0 - origin.y) / dir.y;
			float tb = (y1 - origin.y) / dir.y;
			t_start = max(t_start, min(ta, tb));
			t_end = min(t_end, max(ta, tb));
		} else if (origin.y < y0 || origin.y > y1) {
			discard;
		}
		if (t_end <= t_start) {
			discard;
		}
		// Keep top-down F6 factory views crisp while giving angled, horizon, and first-person views full plumes.
		float high_view = mix(1.0, 0.35, smoothstep(-0.72, -0.96, dir.y));
		vec3 sd = normalize(sun_dir);
		float sun_above = smoothstep(-0.02, 0.14, sd.y) * clamp(sun_strength, 0.0, 1.5);
		float phase = clamp(smog_hg(dot(dir, sd), 0.56) * 1.45, 0.0, 3.0);
		float jitter = smog_ign(FRAGCOORD.xy);

		vec3 accum = vec3(0.0);
		float trans = 1.0;
		const float DETAIL_DIST = 420.0;
		float t_mid = min(t_end, DETAIL_DIST);
		if (t_mid > t_start) {
			const int NEAR_STEPS = 10;
			for (int i = 0; i < NEAR_STEPS; i++) {
				float u0 = float(i) / float(NEAR_STEPS);
				float u1 = float(i + 1) / float(NEAR_STEPS);
				float um = (float(i) + jitter) / float(NEAR_STEPS);
				float t_lo = mix(t_start, t_mid, mix(u0, u0 * u0, 0.40));
				float t_hi = mix(t_start, t_mid, mix(u1, u1 * u1, 0.40));
				float t = mix(t_start, t_mid, mix(um, um * um, 0.40));
				float dt = t_hi - t_lo;
				vec3 p = origin + dir * t;
				vec3 pv = pollution_vol_at(p.xz);
				if (max(pv.g, pv.b) < 0.002) {
					continue;
				}
				float h = p.y - ground_h(p.xz);
				if (h < -1.5 || h > sky_height) {
					continue;
				}
				float vertical = smog_vertical(h, pv.g, pv.b, high_view);
				if (vertical < 0.002) {
					continue;
				}
				float billow = smog_billow(p, h, clamp(t / 220.0, 0.0, 3.0));
				float sigma = density * 0.78 * vertical * (0.34 + 1.16 * billow) * clamp(strength * 1.4, 0.0, 1.5);
				if (sigma <= 1e-5) {
					continue;
				}
				float c_sh = cloud_shadow_at(p, sd);
				float sun_vis = (1.0 - c_sh * 0.85) * sun_above;
				vec3 step_col = smog_step_color(h, max(pv.g, pv.b), sun_vis, phase);
				float step_trans = exp(-sigma * dt);
				float step_a = 1.0 - step_trans;
				accum += trans * step_a * step_col;
				trans *= step_trans;
				if (trans < 0.08) {
					break;
				}
			}
		}

		float t_far0 = max(t_start, DETAIL_DIST);
		if (t_end > t_far0 && trans > 0.12) {
			float g_mid = 0.5 * (ground_range.x + ground_range.y);
			float far_sun_vis = (1.0 - cloud_presence() * 0.35) * sun_above;
			const int FAR_STEPS = 4;
			float far_dt = (t_end - t_far0) / float(FAR_STEPS);
			for (int j = 0; j < FAR_STEPS; j++) {
				float t = t_far0 + (float(j) + jitter) * far_dt;
				vec3 p = origin + dir * t;
				float pol_a = pollution_vol_at(p.xz).b;
				if (pol_a < 0.002) {
					continue;
				}
				float h = p.y - g_mid;
				if (h < -1.5 || h > sky_height) {
					continue;
				}
				float vertical = smog_vertical(h, pol_a * 0.7, pol_a, high_view);
				if (vertical < 0.002) {
					continue;
				}
				float far_n = textureLod(smog_noise, (p.xz - TIME * vec2(1.7, 0.7) - vec2(h * 0.25, h * 0.1)) * 0.0038, 3.0).r;
				float billow = smoothstep(0.15, 0.88, far_n);
				float dist_fade = smoothstep(far, far - 250.0, t);
				float sigma = density * 0.68 * vertical * (0.45 + 0.90 * billow) * clamp(strength * 1.4, 0.0, 1.5) * dist_fade;
				if (sigma <= 1e-5) {
					continue;
				}
				vec3 step_col = smog_step_color(h, pol_a, far_sun_vis, phase);
				float step_trans = exp(-sigma * far_dt);
				float step_a = 1.0 - step_trans;
				accum += trans * step_a * step_col;
				trans *= step_trans;
				if (trans < 0.08) {
					break;
				}
			}
		}

		float alpha = 1.0 - trans;
		if (alpha < 0.002) {
			discard;
		}
		float cap = clamp(0.86 * clamp(strength * 1.25, 0.0, 1.0), 0.0, 0.86);
		float sc = min(alpha, cap) / max(alpha, 1e-4);
		ALBEDO = max(accum * sc, vec3(0.0));
		ALPHA = alpha * sc;
	}
}
