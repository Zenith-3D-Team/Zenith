// Volumetric God rays (scripts/world/god_rays.gd, Settings > Graphics > God rays): additive
// full-screen pass at priority 4 (over volumetric Smog at 3, under RemoteFog at 5). Combines:
//   1. 3D volumetric sun shafts beneath whichever cloud layer is visible (cloud_shadow_sample)
//      and inside smog/planet haze, tinted warm through pollution and attenuated by optical depth.
//   2. Perspective screen-space crepuscular rays cast from sky gaps and cloud edges around the sun.
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled, shadows_disabled;

#include "res://shaders/ground_height.gdshaderinc"
#include "res://shaders/pollution.gdshaderinc"
#include "res://shaders/cloud_shadow_sample.gdshaderinc"

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform float strength = 0.5;
uniform float smog_strength = 0.5;
uniform vec3 sun_dir = vec3(0.0, 0.7, -0.7);
uniform vec3 sky_sun_dir = vec3(0.0, 0.7, -0.7);
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.85);
uniform float sun_strength = 1.0;
uniform float twilight = 0.0;
uniform float planet_haze = 0.0;
uniform vec3 planet_haze_color : source_color = vec3(1.0, 0.92, 0.78);
uniform vec2 scene_light = vec2(1.0);
uniform vec3 smog_tint : source_color = vec3(0.85, 0.68, 0.42);
uniform float far = 640.0;
uniform float sky_height = 175.0;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

vec3 view_point(vec2 uv, float depth, mat4 inv_projection) {
	vec4 p = inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	return p.xyz / p.w;
}

float hg(float cos_theta, float g) {
	float gg = g * g;
	return (1.0 - gg) / (4.0 * 3.14159265 * pow(max(1.0 + gg - 2.0 * g * cos_theta, 0.01), 1.5));
}

void fragment() {
	if (strength <= 0.001 || sun_strength <= 0.01 || scene_light.y <= 0.001) {
		discard;
	}
	float sun_elev = smoothstep(0.02, 0.16, max(sun_dir.y, sky_sun_dir.y));
	if (sun_elev <= 0.001) {
		discard;
	}

	vec3 near_v = view_point(SCREEN_UV, 1.0, INV_PROJECTION_MATRIX);
	vec3 dir = normalize(mat3(INV_VIEW_MATRIX) * (view_point(SCREEN_UV, 0.5, INV_PROJECTION_MATRIX) - near_v));
	vec3 origin = (INV_VIEW_MATRIX * vec4(near_v, 1.0)).xyz;
	float depth = texture(depth_texture, SCREEN_UV).r;
	float scene_dist = far;
	if (depth > 0.0) {
		vec3 hit = (INV_VIEW_MATRIX * vec4(view_point(SCREEN_UV, depth, INV_PROJECTION_MATRIX), 1.0)).xyz;
		scene_dist = min(distance(origin, hit), far);
	}

	vec3 sd = normalize(sun_dir);
	float low_sun_boost = mix(1.0, 1.8, twilight) * mix(1.4, 0.85, smoothstep(0.16, 0.72, max(sd.y, 0.0)));
	float view_comfort = mix(1.0, 0.28, smoothstep(-0.55, -0.92, dir.y));
	float jitter = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	vec3 total = vec3(0.0);

	// 1. 3D volumetric cloud-gap & smog shafts.
	if (cloud_mode > 0.5 || smog_strength > 0.001 || planet_haze > 0.001) {
		float y_ceil = cloud_ceiling_y();
		float t_start = 2.0;
		float t_end = min(scene_dist, far);
		if (abs(dir.y) > 1e-5) {
			float tc = (y_ceil - origin.y) / dir.y;
			if (dir.y > 0.0) {
				t_end = min(t_end, tc);
			} else {
				t_start = max(t_start, tc);
			}
		} else if (origin.y > y_ceil) {
			t_end = t_start;
		}
		if (t_end > t_start) {
			float c_pres = cloud_presence();
			float air_base = 0.0022 * smoothstep(0.04, 0.35, c_pres) + planet_haze * 0.032;
			float vol_phase = 0.22 + 0.78 * clamp(hg(dot(dir, sd), 0.64) * 1.4, 0.0, 3.0);
			vec3 vol_col = vec3(0.0);
			float smog_opt = 0.0;
			const int VOL_STEPS = 12;
			for (int i = 0; i < VOL_STEPS; i++) {
				float u0 = float(i) / float(VOL_STEPS);
				float u1 = float(i + 1) / float(VOL_STEPS);
				float um = (float(i) + jitter) / float(VOL_STEPS);
				float t_lo = mix(t_start, t_end, mix(u0, u0 * u0, 0.45));
				float t_hi = mix(t_start, t_end, mix(u1, u1 * u1, 0.45));
				float t = mix(t_start, t_end, mix(um, um * um, 0.45));
				float dt = t_hi - t_lo;
				vec3 p = origin + dir * t;
				float h = p.y - ground_h(p.xz);
				float air_h = exp(-max(h, 0.0) / 55.0) * smoothstep(y_ceil, y_ceil * 0.70, p.y);
				vec3 pv = smog_strength > 0.001 ? pollution_vol_at(p.xz) : vec3(0.0);
				float pol_l = pv.g;
				float pol_a = pv.b;
				float pol_max = max(pol_l, pol_a);
				float smog_v = 0.0;
				if (pol_max > 0.002) {
					float low_band = 0.36 * pol_l * exp(-max(h, 0.0) / 9.0) * smoothstep(-1.0, 1.5, h);
					float plume_h = smoothstep(2.5, 16.0, h) * exp(-max(h - 16.0, 0.0) / mix(28.0, 58.0, pol_l));
					float plume_band = 0.92 * pow(max(pol_l, 1e-4), 0.72) * step(0.002, pol_l) * plume_h;
					float deck_h = smoothstep(14.0, 46.0, h) * exp(-max(h - 48.0, 0.0) / mix(34.0, 64.0, pol_a)) * smoothstep(sky_height, sky_height * 0.68, h);
					float deck_band = 0.85 * pow(max(pol_a, 1e-4), 0.68) * step(0.002, pol_a) * deck_h;
					smog_v = clamp(low_band + plume_band + deck_band, 0.0, 1.45);
				}
				float medium = air_base * air_h + 0.0115 * smog_v * smog_strength;
				if (medium > 1e-5) {
					float c_occ = cloud_shadow_at(p, sd);
					float sun_gap = cloud_mode > 0.5 ? pow(clamp(1.0 - c_occ * 1.15, 1e-4, 1.0), 1.6) : 1.0;
					float overhead_smog = exp(-pol_max * smog_strength * (1.0 - clamp(h / 75.0, 0.0, 1.0)) * 0.85);
					float trans = exp(-smog_opt);
					vec3 base_beam = mix(sun_color, planet_haze_color, clamp(planet_haze * 6.0, 0.0, 0.45));
					vec3 beam_col = mix(base_beam, mix(base_beam, smog_tint, 0.45), clamp(pol_max * smog_strength * 1.4, 0.0, 1.0));
					vol_col += beam_col * (medium * sun_gap * overhead_smog * trans * dt);
				}
				smog_opt += smog_v * smog_strength * 0.022 * dt;
				if (smog_opt > 3.5) {
					break;
				}
			}
			total += vol_col * (vol_phase * sun_elev * sun_strength * low_sun_boost * view_comfort * strength);
		}
	}

	// 2. Screen-space silhouette & cloud-edge crepuscular rays (perspective view).
	bool is_ortho = abs(PROJECTION_MATRIX[3][3] - 1.0) < 0.01;
	vec3 sky_sd = normalize(sky_sun_dir);
	float sky_dot = max(dot(dir, sky_sd), 0.0);
	if (!is_ortho && sky_sd.y > 0.01 && sky_dot > 0.05) {
		vec3 sun_view = mat3(VIEW_MATRIX) * sky_sd;
		if (sun_view.z < -0.15) {
			vec4 sun_clip = PROJECTION_MATRIX * vec4(sun_view, 0.0);
			vec2 sun_uv = (sun_clip.xy / max(sun_clip.w, 1e-4)) * 0.5 + 0.5;
			float off_screen = max(max(-sun_uv.x, sun_uv.x - 1.0), max(-sun_uv.y, sun_uv.y - 1.0));
			float screen_vis = smoothstep(0.65, 0.0, off_screen) * smoothstep(0.15, 0.45, -sun_view.z);
			if (screen_vis > 0.001) {
				vec2 delta_uv = sun_uv - SCREEN_UV;
				float dist_uv = length(delta_uv);
				float span = min(dist_uv, 0.65);
				vec2 step_uv = delta_uv * (span / max(dist_uv, 1e-4)) / 14.0;
				float frac_scale = (span / max(dist_uv, 1e-4)) / 14.0;
				float radial_sum = 0.0;
				float weight = 1.0;
				float weight_sum = 0.0;
				for (int k = 0; k < 14; k++) {
					float fk = float(k) + jitter;
					vec2 suv = SCREEN_UV + step_uv * fk;
					if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) {
						break;
					}
					float open_sky = step(textureLod(depth_texture, suv, 0.0).r, 0.0);
					if (open_sky > 0.5 && cloud_mode > 0.5) {
						vec3 sdir = normalize(mix(dir, sky_sd, clamp(fk * frac_scale, 0.0, 1.0)));
						open_sky *= clamp(1.0 - sky_cloud_at(origin, sdir) * 0.92, 0.08, 1.0);
					}
					radial_sum += open_sky * weight;
					weight_sum += weight;
					weight *= 0.91;
				}
				float radial = radial_sum / max(weight_sum, 1e-4);
				float cone = pow(sky_dot, mix(4.2, 2.6, twilight));
				vec3 pv_cam = smog_strength > 0.001 ? pollution_vol_at(origin.xz) : vec3(0.0);
				vec3 pv_mid = smog_strength > 0.001 ? pollution_vol_at((origin + sky_sd * 45.0).xz) : vec3(0.0);
				float s_cam = max(pv_cam.g, pv_cam.b);
				float s_mid = max(pv_mid.g, pv_mid.b);
				float s_avg = 0.5 * (s_cam + s_mid) * smog_strength;
				float smog_radial_mod = (1.0 + 0.7 * s_avg) * exp(-s_avg * 1.15);
				vec3 rcol = mix(sun_color, mix(sun_color, smog_tint, 0.4), clamp(s_avg * 1.3, 0.0, 1.0));
				total += rcol * (radial * cone * screen_vis * sun_elev * sun_strength * low_sun_boost * smog_radial_mod * 0.30 * strength);
			}
		}
	}

	total *= scene_light.y;
	total = min(max(total, vec3(0.0)), vec3(1.1));
	if (max(total.r, max(total.g, total.b)) < 0.0005) {
		discard;
	}
	ALBEDO = total;
	// Premultiplied alpha with ALPHA = 0.0 adds `total` cleanly (`total + dst_rgb`) while preserving
	// `dst_a` so Godot Forward+ does not feed 1.0 across the sunlit screen into FSR 2.2's reactive mask.
	ALPHA = 0.0;
}
