// The Cinematic shaders add-on's grade (one full-screen pass, Zenith's api.shaders): local contrast
// and sharpening, colour (vibrance, split toning: cool shadows, warm highlights), a soft vignette,
// a touch of chromatic aberration at the edges and film grain. Bloom, soft shadows, ambient
// occlusion and haze are the look's environment settings (main.gd).
//
// Distance: sharpening and local contrast boost whatever is finer than a pixel, and far away that is
// most of the picture, so it shimmered as the camera moved. They are full on what the camera looks
// at and fade out further back, measured against the distance at the middle of the screen (so a
// view from high up or Factorio's flat view keeps them everywhere), and the far distance is softened
// a little, as a lens focused on the factory would.
shader_type spatial;
#include "res://shaders/look_pass.gdshaderinc"

uniform float clarity = 0.35;       // local contrast: the scene against a blurred copy of itself
uniform float sharpen = 0.25;       // fine detail against a slightly blurred copy
uniform float vibrance = 0.25;      // more colour where there is little
uniform float contrast = 1.15;      // a film curve round mid grey, in stops (AgX alone is flat)
uniform float saturation = 1.1;
uniform float split_tone = 0.5;     // cool shadows, warm highlights
uniform vec3 shadow_tint : source_color = vec3(0.36, 0.5, 0.62);
uniform vec3 highlight_tint : source_color = vec3(1.0, 0.82, 0.62);
uniform float vignette = 0.35;
uniform float aberration = 0.0015;  // of the screen's width, at the corners
uniform float grain = 0.02;
uniform float night_cool = 1.0;     // the blue hour's cold colours carried on through the night
uniform float soften = 0.5;         // how much the far distance is softened (0 off)
// Against the distance at the middle of the screen: sharpening fades out between these two...
uniform float sharp_until = 1.15;
uniform float sharp_gone = 2.2;
// ...and the far distance softens between these.
uniform float soft_from = 1.8;
uniform float soft_full = 4.0;

// Clouds: a layer of soft, shaded clouds in the sky and their shadows drifting over the ground, both from
// the same pattern, so a shadow is under its cloud as the sun sees it (Zenith's own cartoon clouds are off
// while this look is on; main.gd). Tiles, metres in Godot's units; heights over the ground.
uniform float clouds = 1.0;             // 0: none
uniform float cloud_cover = 0.58;       // how much of the sky they cover
uniform float cloud_shadow = 0.45;      // how dark their shadows are on lit ground
uniform float cloud_low = 230.0;        // the layer's bottom and top
uniform float cloud_high = 300.0;
uniform float cloud_scale = 0.009;      // pattern per tile (about 110 tiles a cloud)
uniform vec2 wind = vec2(3.2, 1.1);     // tiles a second
// The pattern, drawn once into a texture (cloud_field.gdshader, main.gd): red, green and blue are it to
// 3, 4 and 5 octaves. It repeats every cloud_period of the pattern (about 1,800 tiles). Black (no
// clouds) until it is drawn.
uniform sampler2D cloud_field : hint_default_black, filter_linear, repeat_enable;
uniform float cloud_period = 16.0;
uniform float fast_night_clouds = 1.0;
uniform float cloud_volumetric = 1.0;
uniform float cloud_steps = 40.0;
uniform float cloud_ray_opt = 1.0;
uniform sampler3D cloud_shape_3d : filter_linear, repeat_enable;
uniform sampler3D cloud_detail_3d : filter_linear, repeat_enable;
global uniform vec4 f3d_weather_clouds;
global uniform vec4 f3d_weather_wind;

float eff_cloud_cover() {
	return clamp(mix(cloud_cover, f3d_weather_clouds.x, f3d_weather_clouds.z), 0.0, 1.0);
}

vec2 eff_cloud_drift() {
	return f3d_weather_wind.w > 0.5 ? f3d_weather_wind.xy : wind * TIME;
}

float wx_dark() {
	return clamp(f3d_weather_clouds.y * f3d_weather_clouds.z, 0.0, 1.0);
}

float wx_flash() {
	return max(f3d_weather_clouds.w, 0.0);
}

// Lightning (the weather's flash, f3d_weather_clouds.w): a stormy night's clouds lit by it about as much
// as the Factorio look's sky is (1.6-3.4 times), its light in proportion to theirs and capped. It added
// 0.75-0.8 to clouds of about 0.05 before (0.6.1), which the look's exposure, AgX and film curve made a
// white sky (flash_old 1, --cinematic-flash=old).
uniform float flash_old = 0.0;
uniform float flash_lift = 1.6;    // of the cloud's own brightness, per unit of flash
uniform float flash_add = 0.05;    // and a little on top, so the darkest clouds still show it
uniform float flash_cap = 0.25;    // at most this much light per unit of flash (by day it barely shows)
const vec3 FLASH_TINT = vec3(0.75, 0.84, 1.0);

vec3 flash_light(vec3 base, float flash, float old_k) {
	if (flash_old > 0.5)
		return FLASH_TINT * flash * old_k;
	return FLASH_TINT * flash * min(flash_lift * luma(base) + flash_add, flash_cap);
}

float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// The pattern at a point in the world, drifting with the wind: (3, 4, 5 octaves), each about 0-1. One
// read where the noise was worked out before (up to 48 sines and cosines for one point).
vec3 cloud_pattern(vec2 xz) {
	return textureLod(cloud_field, (xz - eff_cloud_drift()) * cloud_scale / cloud_period, 0.0).rgb;
}

// The clouds' density (0 clear, 1 thick) for the pattern's `shape` at height y, thinning to the layer's
// top and bottom.
float cloud_density(float shape, float y) {
	float h = clamp((y - cloud_low) / (cloud_high - cloud_low), 0.0, 1.0);
	// Each cloud is widest a third of the way up and narrows to its flat base and rounded top, so seen
	// from low down it is a cloud, not a column of the pattern stretched up through the layer.
	float narrow = 0.5 * pow(abs(h - 0.32) / 0.68, 1.6);
	float cov = eff_cloud_cover();
	float cover = 1.0 - cov;
	float overcast_floor = smoothstep(0.68, 1.0, cov) * 0.35;
	return clamp((shape + overcast_floor - cover * 0.8 - 0.2 - narrow) * 2.6, 0.0, 1.0);
}

// The sky seen along a ray from the camera: clouds over what is there (Zenith's clear sky), lit from the
// sun's side, blue-grey underneath, thinning to the horizon.
vec4 sky_clouds(vec3 from, vec3 dir, float night, float jitter) {
	if (dir.y < 0.015)
		return vec4(0.0);
	float t0 = (cloud_low - from.y) / dir.y;
	float t1 = (cloud_high - from.y) / dir.y;
	t0 = max(t0, 0.0);
	if (t1 <= t0)
		return vec4(0.0);
	bool fast_night = fast_night_clouds > 0.5 && night > 0.85 && look_twilight < 0.01;
	int STEPS = fast_night ? 6 : 14;
	float dt = (t1 - t0) / float(STEPS);
	// Clouds keep the sun a few degrees after the ground has lost it, and their shaded sides take the
	// sky's colour as it goes.
	float sun_on = smoothstep(-0.08, 0.07, look_sun_height);
	vec3 lit_color = mix(look_ambient_color * 0.75, look_sun_color, mix(1.0, sun_on, step(0.001, look_twilight)));
	// At dusk the sky is lit from one side: away from the sun clouds stay dim.
	float toward = clamp(0.5 + 0.5 * dot(normalize(dir.xz + vec2(1e-5)), normalize(look_sun_dir.xz + vec2(1e-5))), 0.0, 1.0);
	float dark = wx_dark();
	float flash = wx_flash();
	vec3 lit = lit_color * mix(0.06, 1.35 - 0.9 * look_twilight, mix(1.0 - night, sun_on, step(0.001, look_twilight)))
		* mix(1.0, mix(0.3, 1.0, toward * toward), look_twilight) * look_scene_light.y * (1.0 - 0.65 * dark);
	vec3 shade = mix(mix(vec3(0.46, 0.53, 0.64), look_ambient_color * 0.3, look_twilight), vec3(0.03, 0.04, 0.07), night)
		* look_scene_light.x * (1.0 - 0.52 * dark);
	// Looking towards a low sun, its light rims them.
	float rim = pow(max(dot(dir, normalize(look_sun_dir)), 0.0), 6.0) * look_twilight * (1.0 - 0.8 * dark);
	vec3 col = vec3(0.0);
	float trans = 1.0;
	for (int i = 0; i < STEPS; i++) {
		vec3 p = from + dir * (t0 + (float(i) + jitter) * dt);
		float d = cloud_density(cloud_pattern(p.xz).b, p.y);
		if (d > 0.001) {
			float light = 0.0;
			if (!fast_night) {
				// How much cloud lies towards the sun from here: the lit side's brightness.
				vec3 near_sun = p + look_sun_dir * 40.0;
				vec3 far_sun = p + look_sun_dir * 90.0;
				float towards = cloud_density(cloud_pattern(near_sun.xz).r, near_sun.y) + cloud_density(cloud_pattern(far_sun.xz).r, far_sun.y);
				light = exp(-towards * 1.6);
			}
			float h = clamp((p.y - cloud_low) / (cloud_high - cloud_low), 0.0, 1.0);
			// With the sun low the light reaches their bases too.
			vec3 c = mix(shade, lit, light * mix(0.55 + 0.45 * h, 1.0 - 0.15 * h, look_twilight) + rim * 0.35);
			c += flash_light(c, flash, 0.75);
			float a = 1.0 - exp(-d * dt * 0.025);
			col += trans * a * c;
			trans *= 1.0 - a;
			if (trans < 0.03)
				break;
		}
	}
	// Far away, near the horizon, the clouds fade into the sky's haze.
	float fade = smoothstep(0.015, 0.12, dir.y);
	return vec4(col, 1.0 - trans) * fade;
}

float cloud_ign(vec2 px) {
	return fract(52.9829189 * fract(dot(px, vec2(0.06711056, 0.00583715))));
}

float cloud_hg(float cos_theta, float g) {
	float gg = g * g;
	return (1.0 - gg) / (4.0 * 3.14159265 * pow(max(1.0 + gg - 2.0 * g * cos_theta, 0.01), 1.5));
}

// Camera-centered ray-sphere intersection roots (t_near, t_far) against a shell of radius `rad`.
vec2 cloud_sphere_hits(float r0, float dy, float rad) {
	float b = r0 * dy;
	float c = r0 * r0 - rad * rad;
	float disc = b * b - c;
	if (disc < 0.0) {
		return vec2(-1.0);
	}
	float s = sqrt(disc);
	return vec2(-b - s, -b + s);
}

vec4 cloud_weather(vec2 xz) {
	return textureLod(cloud_field, (xz - eff_cloud_drift()) * cloud_scale / cloud_period, 0.0);
}

float cloud_alt_norm(vec3 p, vec3 from, float planet_r) {
	vec3 rel = vec3(p.x - from.x, p.y + planet_r, p.z - from.z);
	return clamp((length(rel) - planet_r - cloud_low) / max(cloud_high - cloud_low, 1.0), 0.0, 1.0);
}

// Sculpted 3D cloud density combining the 2D weather/type field with seamless 3D Worley lobes
// and wind-sheared detail erosion.
float volumetric_cloud_density(vec3 p, float h, bool with_detail) {
	vec4 w = cloud_weather(p.xz);
	float ctype = clamp(w.a > 0.01 ? w.a : 0.65, 0.25, 1.0);
	float top_h = mix(0.46, 1.0, ctype);
	float h_grad = smoothstep(0.0, 0.14, h) * smoothstep(top_h, top_h * 0.44, h);
	float cov = eff_cloud_cover();
	float cover = 1.0 - cov;
	float overcast_floor = smoothstep(0.68, 1.0, cov) * 0.42;
	float base_d = (mix(w.g, w.b, 0.45) + overcast_floor) * h_grad - (cover * 0.56 + 0.12);
	if (base_d <= 0.0) {
		return 0.0;
	}
	vec2 drift2 = eff_cloud_drift();
	vec3 wind3 = vec3(drift2.x, 0.0, drift2.y);
	float shear_k = f3d_weather_wind.w > 0.5 ? clamp(f3d_weather_wind.z, 0.2, 2.0) : 1.0;
	vec3 shear = vec3(wind.x, 0.0, wind.y) * (h * 16.0 * shear_k);
	vec3 sp = (p - wind3 * 0.85 - shear) * 0.0046 + vec3(0.0, -TIME * 0.008, 0.0);
	float s3d = textureLod(cloud_shape_3d, sp, 0.0).r;
	float d = clamp((base_d - (1.0 - s3d) * mix(0.24, 0.42, h)) * 3.1, 0.0, 1.0);
	if (d <= 0.001) {
		return 0.0;
	}
	if (with_detail && d < 0.85) {
		vec3 dp = (p - wind3 * 1.15 - shear * 1.4) * 0.0155 + vec3(0.0, -TIME * 0.022, 0.0);
		float d3d = textureLod(cloud_detail_3d, dp, 0.0).r;
		float erode = (1.0 - d3d) * mix(0.16, 0.34, h) * (1.0 - d * 0.65);
		d = clamp((d - erode) / max(1.0 - erode, 0.25), 0.0, 1.0);
	}
	return d * smoothstep(0.0, 0.08, h);
}

// 3D volumetric cloud raymarch on a curved horizon shell with empty-space skipping, 4-step sun
// self-shadowing, Beer-Powder multiple scattering, dual-lobe silver lining, and aerial perspective.
vec4 sky_clouds_volumetric(vec3 from, vec3 dir, float night, float jitter, vec3 sky_bg) {
	if (from.y < cloud_low && dir.y < -0.02) {
		return vec4(0.0);
	}
	const float PLANET_R = 45000.0;
	float r0 = PLANET_R + from.y;
	float r_in = PLANET_R + cloud_low;
	float r_out = PLANET_R + cloud_high;
	vec2 h_in = cloud_sphere_hits(r0, dir.y, r_in);
	vec2 h_out = cloud_sphere_hits(r0, dir.y, r_out);
	if (h_out.y <= 0.0) {
		return vec4(0.0);
	}
	float t0 = 0.0;
	float t1 = 0.0;
	if (r0 < r_in) {
		if (h_in.y <= 0.0) {
			return vec4(0.0);
		}
		t0 = max(h_in.y, 0.0);
		t1 = h_out.y;
	} else if (r0 <= r_out) {
		t0 = 0.0;
		t1 = h_in.x > 0.0 ? h_in.x : h_out.y;
	} else {
		if (h_out.x <= 0.0) {
			return vec4(0.0);
		}
		t0 = h_out.x;
		t1 = h_in.x > 0.0 ? h_in.x : h_out.y;
	}
	t0 = min(t0, 6500.0);
	t1 = min(t1, t0 + 4800.0);
	if (t1 <= t0) {
		return vec4(0.0);
	}

	bool fast_night = fast_night_clouds > 0.5 && night > 0.85 && look_twilight < 0.01;
	int max_steps = fast_night ? 10 : clamp(int(round(cloud_steps)), 12, 48);
	vec3 sd = normalize(look_sun_dir);
	float sun_on = smoothstep(-0.08, 0.07, look_sun_height);
	float sun_gate = mix(1.0 - night, sun_on, step(0.001, look_twilight));
	vec3 lit_color = mix(look_ambient_color * 0.75, look_sun_color, mix(1.0, sun_on, step(0.001, look_twilight)));
	float dark = wx_dark();
	float flash = wx_flash();
	vec3 sun_col = lit_color * mix(0.08, 1.55 - 0.65 * look_twilight, sun_gate) * look_scene_light.y * (1.0 - 0.68 * dark);
	vec3 amb_top = mix(mix(vec3(0.68, 0.76, 0.88), look_ambient_color * 0.85 + look_sun_color * 0.25, look_twilight), vec3(0.04, 0.055, 0.095), night) * look_scene_light.x * (1.0 - 0.52 * dark);
	vec3 amb_bot = mix(mix(vec3(0.36, 0.43, 0.54), look_ambient_color * 0.34, look_twilight), vec3(0.02, 0.028, 0.05), night) * look_scene_light.x * (1.0 - 0.55 * dark);
	float cos_th = dot(dir, sd);
	float phase = clamp(mix(cloud_hg(cos_th, -0.25), cloud_hg(cos_th, 0.78), 0.68) * 3.8, 0.22, 3.2);
	float silver = pow(max(cos_th, 0.0), 10.0) * (0.45 + 0.85 * look_twilight) * sun_gate * (1.0 - 0.78 * dark);

	float base_dt = (t1 - t0) / float(max_steps);
	bool opt_on = cloud_ray_opt > 0.5;
	float empty_dt = opt_on ? base_dt * 2.0 : base_dt * 1.85;
	float back_dt = opt_on ? base_dt : base_dt * 0.85;
	float t = t0 + jitter * base_dt;
	bool in_cloud = false;
	int empty_run = 0;
	vec3 col = vec3(0.0);
	float trans = 1.0;
	float t_weighted = 0.0;
	float w_sum = 0.0;
	const float SUN_DISTS[4] = float[4](18.0, 44.0, 96.0, 195.0);
	const float SUN_WEIGHTS[4] = float[4](22.0, 36.0, 62.0, 110.0);

	for (int i = 0; i < max_steps; i++) {
		if (t >= t1) {
			break;
		}
		vec3 p = from + dir * t;
		float h = cloud_alt_norm(p, from, PLANET_R);
		if (!in_cloud) {
			if (volumetric_cloud_density(p, h, false) > 0.001) {
				t = max(t0, t - back_dt);
				in_cloud = true;
				empty_run = 0;
				continue;
			}
			t += empty_dt;
			continue;
		}
		bool use_detail = !fast_night && (!opt_on || (trans > 0.22 && t < 2400.0));
		float d = volumetric_cloud_density(p, h, use_detail);
		if (d > 0.001) {
			empty_run = 0;
			float sun_od = 0.0;
			if (!fast_night) {
				for (int s_idx = 0; s_idx < 4; s_idx++) {
					vec3 sp = p + sd * SUN_DISTS[s_idx];
					float sh = cloud_alt_norm(sp, from, PLANET_R);
					if (sh > 0.0 && sh < 1.0) {
						sun_od += volumetric_cloud_density(sp, sh, false) * (SUN_WEIGHTS[s_idx] * 0.011);
					}
				}
			}
			float beer = exp(-sun_od * 1.35);
			float ms = exp(-sun_od * 0.30) * 0.42;
			float powder = 1.0 - exp(-sun_od * 2.2);
			float scatter = mix(beer, beer * mix(0.62, 1.50, powder), 0.52) + ms;
			vec3 amb = mix(amb_bot, amb_top, smoothstep(0.0, 0.85, h)) * mix(0.68, 1.0, exp(-d * 1.2));
			vec3 direct = sun_col * (scatter * phase * mix(0.65 + 0.35 * h, 1.05 - 0.15 * h, look_twilight) + silver * exp(-sun_od * 0.75) * 0.55);
			vec3 c_step = amb + direct;
			c_step += flash_light(c_step, flash, 0.8) * (0.45 + 0.55 * (1.0 - h));
			float a = 1.0 - exp(-d * base_dt * 0.022);
			float step_w = trans * a;
			col += step_w * c_step;
			t_weighted += t * step_w;
			w_sum += step_w;
			trans *= 1.0 - a;
			if (trans < 0.02) {
				break;
			}
		} else {
			empty_run += 1;
			if (empty_run >= 3) {
				in_cloud = false;
			}
		}
		t += base_dt;
	}

	float alpha = 1.0 - trans;
	if (alpha < 0.002) {
		return vec4(0.0);
	}
	float avg_t = w_sum > 1e-4 ? (t_weighted / w_sum) : t0;
	float aerial = 1.0 - exp(-max(avg_t - 900.0, 0.0) * 0.00028);
	float horizon_fade = smoothstep(-0.01, 0.045, dir.y);
	vec3 out_rgb = mix(col / max(alpha, 1e-4), sky_bg, aerial * 0.75);
	return vec4(out_rgb * alpha, alpha) * horizon_fade;
}

// How much of the sun's light the clouds take at a point on the ground.
float ground_cloud_shadow(vec3 p) {
	// Fades out with the sun instead of cutting off; from no lower than the light itself comes.
	float fade = smoothstep(0.0, 0.22, look_sun_height);
	if (fade <= 0.0)
		return 0.0;
	vec3 sd = normalize(vec3(look_sun_dir.x, max(look_sun_dir.y, 0.24), look_sun_dir.z));
	float mid = 0.5 * (cloud_low + cloud_high);
	vec3 at = p + sd * ((mid - p.y) / sd.y);
	float d = cloud_density(cloud_pattern(at.xz).g, mid);
	return smoothstep(0.03, 0.45, d) * fade;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 from_mid = uv - 0.5;
	float edge = dot(from_mid, from_mid) * 2.0;  // 0 in the middle, 1 at the corners

	// How far this pixel is against what the camera looks at (the sky counts as far).
	float focus = look_focus_dist > 0.0 ? look_focus_dist : clamp(scene_distance(vec2(0.5), INV_PROJECTION_MATRIX), 4.0, 600.0);
	float raw = scene_depth_raw(uv);
	float dist = raw <= 0.0 ? 1e6 : scene_distance(uv, INV_PROJECTION_MATRIX);
	float rel = dist / focus;
	float near = 1.0 - smoothstep(sharp_until, sharp_gone, rel);
	float far = smoothstep(soft_from, soft_full, rel) * soften;
	// Space behind a platform stays black with sharp stars: softening smeared each star into a grey
	// glow over the backdrop, and local contrast lifted the dark round them.
	float space_sky = step(0.5, look_space) * (1.0 - step(1e-6, raw));
	far *= 1.0 - space_sky;

	// Chromatic aberration: red and blue a little apart towards the corners (on what is near). Their
	// two reads only where they land a quarter of a pixel or more apart from green: nearer the middle
	// (most of the screen) they read what green does. Skipped under FSR 2.2 so sub-native RGB splits
	// don't fight temporal reconstruction.
	vec2 shift = from_mid * aberration * edge * 2.0 * near * (1.0 - look_fsr2);
	vec3 c = scene_color(uv);
	vec2 shift_px = shift * VIEWPORT_SIZE;
	if (dot(shift_px, shift_px) >= 0.0625) {
		c = vec3(scene_color_fast(uv + shift).r, c.g, scene_color_fast(uv - shift).b);
	}

	// The far distance softened: a smaller copy of the screen, which also hides what shimmers there.
	// Not read where nothing is softened (from above, nearly the whole screen).
	if (far > 0.0) {
		c = mix(c, scene_color_blurred(uv, 1.6), far);
	}

	// Clouds: in the sky where nothing was drawn, their shadows on everything else (on what the sun lights:
	// the brightest parts lose most). Skip unprojecting ground pixels at night or when cloud shadows are off.
	// None in space: a platform's sky is stars, and its deck has no cloud over it (look_space).
	float eff_cov = eff_cloud_cover();
	bool wx_clouds_off = f3d_weather_clouds.z > 0.5 && eff_cov <= 0.005;
	if (clouds > 0.0 && !wx_clouds_off && look_space < 0.5 && (raw <= 0.0 || (look_night < 1.0 && look_sun_height > 0.0 && cloud_shadow > 0.0))) {
		vec3 ndc = vec3(uv * 2.0 - 1.0, raw <= 0.0 ? 1.0 : raw);
		vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		view.xyz /= view.w;
		vec3 world = (INV_VIEW_MATRIX * vec4(view.xyz, 1.0)).xyz;
		if (raw <= 0.0) {
			vec3 dir = normalize(world - CAMERA_POSITION_WORLD);
			float fl = wx_flash();
			if (flash_old < 0.5 && fl > 0.0) {
				// Zenith's sky adds the flash as a fixed amount too (planet_sky.gdshader): taken back out
				// and given again in proportion to the sky, as on the clouds.
				vec3 sky_add = vec3(0.75, 0.8, 1.0) * fl * (0.4 + 0.6 * smoothstep(-0.1, 0.5, dir.y));
				vec3 bare = max(c - sky_add, c * 0.1);
				c = bare + flash_light(bare, fl, 0.0);
			}
			vec4 cl = cloud_volumetric >= 0.5
				? sky_clouds_volumetric(CAMERA_POSITION_WORLD, dir, look_night, cloud_ign(FRAGCOORD.xy), c)
				: sky_clouds(CAMERA_POSITION_WORLD, dir, look_night, hash(FRAGCOORD.xy + fract(TIME * 7.3) * 811.0));
			c = mix(c, cl.rgb / max(cl.a, 1e-4), cl.a * clouds);
		} else {
			float sh_scale = mix(1.0, clamp(1.2 - f3d_weather_clouds.y * 0.85, 0.15, 1.3), f3d_weather_clouds.z);
			float sh = ground_cloud_shadow(world) * cloud_shadow * clouds * sh_scale * (1.0 - look_night);
			float bright = smoothstep(0.02, 0.5, luma(c));
			c *= 1.0 - sh * mix(0.45, 1.0, bright);
			// In the shade of a cloud at dusk only the sky lights it.
			c *= mix(vec3(1.0), look_ambient_color / max(luma(look_ambient_color), 1e-3), sh * look_twilight * 0.5);
		}
	}

	// Local contrast and sharpening on the brightness only, so colours don't fringe; sharpening only
	// near, local contrast kept a little further. Normalized by local luminance with HDR-spike halo
	// suppression so bright sub-pixel emitters (rail signals, water glints, fires) never carve dark
	// boxes into surrounding night terrain or tracks.
	float l = luma(c);
	float clarity_w = clarity * mix(0.3, 1.0, near) * (1.0 - space_sky);
	float sharpen_w = sharpen * near * (1.0 - space_sky) * (1.0 - look_fsr2);
	if (clarity_w > 0.0 || sharpen_w > 0.0) {
		vec2 texel = 1.0 / max(VIEWPORT_SIZE, vec2(1.0));
		float dL = scene_depth_raw(uv + vec2(-texel.x, 0.0));
		float dR = scene_depth_raw(uv + vec2(texel.x, 0.0));
		float dU = scene_depth_raw(uv + vec2(0.0, -texel.y));
		float dD = scene_depth_raw(uv + vec2(0.0, texel.y));
		float max_dd = max(max(abs(dL - raw), abs(dR - raw)), max(abs(dU - raw), abs(dD - raw))) / max(raw, 1e-4);
		float sil_keep = 1.0 - smoothstep(0.03, 0.14, max_dd);
		sharpen_w *= sil_keep;
		clarity_w *= mix(0.35, 1.0, sil_keep);
	}
	if (clarity_w > 0.0 || sharpen_w > 0.0) {
		float scale = max(l, 0.02);
		float gain = 0.0;
		if (clarity_w > 0.0) {
			float wide = luma(scene_color_blurred(uv, 3.0));
			float diff = (l - wide) / (scale + wide + 0.08);
			float halo = diff < 0.0 ? (1.0 - smoothstep(1.6, 3.5, wide / max(l, 1e-4))) : 1.0;
			gain += clarity_w * diff * halo;
		}
		if (sharpen_w > 0.0) {
			float fine = luma(scene_color_blurred(uv, 1.0));
			float diff = (l - fine) / (scale + fine + 0.04);
			float halo = diff < 0.0 ? (1.0 - smoothstep(1.6, 3.5, fine / max(l, 1e-4))) : 1.0;
			gain += sharpen_w * diff * halo;
		}
		float mult = clamp(1.0 + gain, 0.72, 1.45);
		c *= mult;
		l *= mult;
	}

	// Film contrast: brightness pushed away from mid grey in stops, colour kept.
	float graded = 0.18 * pow(max(l, 1e-5) / 0.18, contrast);
	c *= graded / max(l, 1e-5);
	l = graded;

	// Saturation, and vibrance: lifts the colour of dull things more than of bright ones.
	float mx = max(c.r, max(c.g, c.b));
	float mn = min(c.r, min(c.g, c.b));
	float sat = (mx - mn) / max(mx, 1e-4);
	c = mix(vec3(l), c, saturation + vibrance * (1.0 - sat));

	// Split toning, worked out in a perceptual brightness so it reads the same in shade and sun.
	float p = l / (l + 0.18);
	// At dusk the highlights lean to the sun's colour and the shadows to the sky's (the sky has its own).
	float lean = look_twilight * 0.7 * step(1e-6, raw);
	vec3 tone = mix(mix(shadow_tint, look_ambient_color, lean), mix(highlight_tint, look_sun_color, lean), smoothstep(0.2, 0.8, p));
	c *= mix(vec3(1.0), tone / max(luma(tone), 1e-4), split_tone * 0.35);

	// The blue hour: with the sun gone, colours lose their saturation and go to the sky's.
	// Bright self-lit emitters (rail signals, lamps, fire) keep their hue instead of washing white.
	float blue_hour = max(look_twilight * smoothstep(0.1, -0.03, look_sun_height), night_cool * smoothstep(0.75, 0.95, look_night)) * step(1e-6, raw);  // not the sky
	float emissive_keep = 1.0 - smoothstep(0.35, 1.1, l);
	c = mix(c, vec3(l) * look_ambient_color / max(luma(look_ambient_color), 1e-3), blue_hour * 0.55 * emissive_keep);

	// Vignette and grain (fine, and mostly in the shade, as film's). Animated grain is skipped under
	// FSR 2.2 because per-frame random noise before temporal accumulation fights variance clamping.
	c *= 1.0 - vignette * smoothstep(0.15, 1.0, edge);
	if (look_fsr2 < 0.5 && grain > 0.0) {
		float n = hash(FRAGCOORD.xy + fract(TIME * 7.3) * 811.0) - 0.5;
		c += c * n * grain * 2.0 * (1.0 - smoothstep(0.3, 1.5, l));
	}

	ALBEDO = max(c, vec3(0.0));
}
