// Shared cloud sampling for volumetric passes (shaders/smog.gdshader, shaders/god_rays.gdshader):
// samples whichever cloud layer is currently visible (0: none, 1: Zenith's built-in clouds from
// clouds.gdshaderinc, 2: a look's cloud_field such as Cinematic Shaders). Set via
// PlanetSky.apply_cloud_uniforms() so both shadows inside the air and sky occluders stay locked to
// the clouds on screen.

#include "res://shaders/clouds.gdshaderinc"

// 0.0 none, 1.0 Zenith's clouds, 2.0 a look's cloud_field.
uniform float cloud_mode = 0.0;
uniform float cloud_height = 70.0;
uniform float cloud_alpha = 0.85;

uniform sampler2D look_cloud_field : hint_default_black, filter_linear, repeat_enable;
uniform float look_cloud_cover = 0.58;
uniform float look_cloud_strength = 1.0;
uniform float look_cloud_low = 230.0;
uniform float look_cloud_high = 300.0;
uniform float look_cloud_scale = 0.009;
uniform float look_cloud_period = 16.0;
uniform vec2 look_cloud_wind = vec2(3.2, 1.1);

float cloud_ceiling_y() {
	return cloud_mode > 1.5 ? look_cloud_low : (cloud_mode > 0.5 ? cloud_height : 120.0);
}

float cloud_presence() {
	if (cloud_mode > 1.5) {
		return clamp(look_cloud_cover * look_cloud_strength, 0.0, 1.0);
	}
	if (cloud_mode > 0.5) {
		return clamp((1.0 - cloud_cover) * cloud_alpha, 0.0, 1.0);
	}
	return 0.0;
}

float look_cloud_density_at(vec2 xz, float y) {
	vec2 drift = f3d_weather_wind.w > 0.5 ? f3d_weather_wind.xy : look_cloud_wind * TIME;
	vec3 pat = textureLod(look_cloud_field, (xz - drift) * look_cloud_scale / max(look_cloud_period, 0.001), 0.0).rgb;
	float h = clamp((y - look_cloud_low) / max(look_cloud_high - look_cloud_low, 1.0), 0.0, 1.0);
	float narrow = 0.5 * pow(abs(h - 0.32) / 0.68, 1.6);
	float cover = 1.0 - look_cloud_cover;
	return clamp((pat.g - cover * 0.8 - 0.2 - narrow) * 2.6, 0.0, 1.0);
}

// How dark the cloud layer shadows a 3D point `p` along sun direction `sd` (0 clear, ~1 dark).
float cloud_shadow_at(vec3 p, vec3 sd) {
	if (cloud_mode < 0.5) {
		return 0.0;
	}
	vec3 s = normalize(vec3(sd.x, max(sd.y, 0.16), sd.z));
	if (cloud_mode > 1.5) {
		float mid = 0.5 * (look_cloud_low + look_cloud_high);
		if (p.y >= mid) {
			return 0.0;
		}
		vec2 at_xz = p.xz + s.xz * ((mid - p.y) / s.y);
		return smoothstep(0.03, 0.45, look_cloud_density_at(at_xz, mid)) * look_cloud_strength;
	}
	if (p.y >= cloud_height) {
		return 0.0;
	}
	vec2 at_xz = p.xz + s.xz * ((cloud_height - p.y) / s.y);
	return cloud_density(at_xz) * cloud_alpha;
}

// Cloud opacity seen in the sky along `ray_dir` from `cam_pos` (0 clear sky, ~1 opaque cloud).
float sky_cloud_at(vec3 cam_pos, vec3 ray_dir) {
	if (cloud_mode < 0.5 || ray_dir.y <= 0.015) {
		return 0.0;
	}
	float horizon_fade = smoothstep(0.015, 0.14, ray_dir.y);
	if (cloud_mode > 1.5) {
		float mid = 0.5 * (look_cloud_low + look_cloud_high);
		vec2 xz = cam_pos.xz + ray_dir.xz / ray_dir.y * max(mid - cam_pos.y, 10.0);
		return smoothstep(0.03, 0.52, look_cloud_density_at(xz, mid)) * look_cloud_strength * horizon_fade;
	}
	vec2 xz = cam_pos.xz + ray_dir.xz / ray_dir.y * max(cloud_height - cam_pos.y, 10.0);
	return cloud_density(xz) * cloud_alpha * horizon_fade;
}
