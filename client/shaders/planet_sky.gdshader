// A planet's sky (scripts/world/sky.gd sets the colours for the planet and the time of day): a
// gradient from the horizon up, the sun with a glow, stars at night, the clouds whose shadows cross
// the ground (shaders/clouds.gdshaderinc), haze at the horizon and, on Fulgora, lightning flashes.
// Stars and clouds are skipped in the radiance pass that lights reflections, which stays cheap.
shader_type sky;

#include "res://shaders/clouds.gdshaderinc"
#include "res://shaders/sky_view.gdshaderinc"

uniform vec3 zenith_color : source_color = vec3(0.3, 0.5, 0.78);
uniform vec3 horizon_color : source_color = vec3(0.7, 0.8, 0.88);
uniform vec3 ground_color : source_color = vec3(0.32, 0.3, 0.26);
// Towards the sun, and how bright its disc and glow are (0 below the horizon).
uniform vec3 sun_dir = vec3(0.0, 0.7, -0.7);
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.85);
uniform float sun_strength = 1.0;
// A setting sun (sky.gd; 0 in a look without one, and all of this does nothing): 1 with the sun at the
// horizon. The horizon's colour towards the sun, and the pink band over the Earth's shadow opposite it.
uniform float twilight = 0.0;
uniform vec3 horizon_sun_color : source_color = vec3(0.7, 0.8, 0.88);
uniform vec3 belt_color : source_color = vec3(0.86, 0.5, 0.58);
uniform float belt = 0.0;
uniform float stars = 0.0;
uniform vec3 cloud_color : source_color = vec3(1.0);
uniform vec3 cloud_shade : source_color = vec3(0.62, 0.66, 0.72);
uniform float cloud_alpha = 0.85;
uniform float cloud_height = 70.0;
uniform vec3 haze_color : source_color = vec3(0.8, 0.85, 0.9);
uniform float haze = 0.0;
uniform float flash = 0.0;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

vec3 star_layer(vec3 d, float scale, float threshold, float size, float salt) {
	vec3 p = d * scale;
	vec3 cell = floor(p);
	vec3 f = fract(p) - 0.5;
	float h = hash13(cell + salt);
	if (h < threshold) {
		return vec3(0.0);
	}
	vec3 offset = vec3(hash13(cell + salt + 1.7), hash13(cell + salt + 3.1), hash13(cell + salt + 5.3)) - 0.5;
	float b = smoothstep(size, 0.0, length(f - offset * 0.6)) * (0.4 + 0.6 * (h - threshold) / (1.0 - threshold));
	return mix(vec3(0.75, 0.82, 1.0), vec3(1.0, 0.88, 0.72), hash13(cell + salt + 7.9)) * b;
}

void sky() {
	vec3 d = sky_view_dir(EYEDIR, SCREEN_UV, AT_CUBEMAP_PASS);
	float up = d.y;
	vec3 sd = normalize(sun_dir);
	// 1 looking towards the sun round the horizon, 0 away.
	float side = clamp(0.5 + 0.5 * dot(normalize(d.xz + vec2(1e-5)), normalize(sd.xz + vec2(1e-5))), 0.0, 1.0);
	vec3 horizon = mix(horizon_color, horizon_sun_color, twilight * pow(side, 1.6));
	float low = max(up, 0.0);
	vec3 col = mix(horizon, zenith_color, pow(clamp(up, 0.0, 1.0), mix(0.45, 0.62, twilight)));
	// The band of colour lies low on the sun's side, and wider the closer to it.
	col = mix(col, horizon_sun_color, twilight * pow(side, 3.0) * exp(-low * mix(16.0, 4.5, side)));
	if (belt > 0.0) {
		float away = pow(max(1.0 - side, 0.0), 2.0);
		col = mix(col, belt_color, belt * away * 0.75 * smoothstep(0.03, 0.09, up) * (1.0 - smoothstep(0.1, 0.3, up)));
		col = mix(col, zenith_color * 0.8, belt * away * 0.65 * (1.0 - smoothstep(0.0, 0.06, up)));
	}
	col = mix(col, ground_color, smoothstep(0.0, -0.12, up));
	float s = max(dot(d, sd), 0.0);
	// The glow around the sun warms the horizon on its side, wider as it sinks; the ground hides what
	// is below the horizon.
	float above = mix(1.0, smoothstep(-0.015, 0.004, up), step(0.001, twilight));
	col += sun_color * sun_strength * above * (pow(s, mix(6.0, 4.0, twilight)) * 0.18
		+ pow(s, mix(48.0, 32.0, twilight)) * mix(0.35, 0.55, twilight));
	col += sun_color * sun_strength * above * smoothstep(mix(0.9993, 0.9988, twilight), mix(0.9997, 0.9993, twilight), s) * 6.0;
	if (!AT_CUBEMAP_PASS) {
		if (stars > 0.0 && up > -0.05) {
			col += (star_layer(d, 90.0, 0.97, 0.22, 0.0) * 1.8 + star_layer(d, 200.0, 0.965, 0.25, 11.0) * 0.8)
				* stars * smoothstep(-0.05, 0.25, up);
		}
		if (cloud_alpha > 0.0 && up > 0.015) {
			vec2 p = POSITION.xz + d.xz / up * max(cloud_height - POSITION.y, 10.0);
			float c = cloud_density(p);
			// Lit on the sun's side; thin out towards the horizon, where they would shimmer.
			vec3 cc = mix(cloud_shade, cloud_color, 0.55 + 0.45 * s);
			// With the sun low the light reaches their undersides, and they glow on its side.
			cc = mix(cc, cloud_color * (0.7 + 0.5 * pow(s, 8.0)), twilight * 0.6 * side);
			col = mix(col, cc, c * cloud_alpha * smoothstep(0.015, 0.2, up));
			// Clouds hide the stars behind them (added above), mostly.
		}
	}
	col = mix(col, haze_color, haze * exp(-max(up, 0.0) * 7.0));
	col += vec3(0.75, 0.8, 1.0) * flash * (0.4 + 0.6 * smoothstep(-0.1, 0.5, up));
	COLOR = col;
}
