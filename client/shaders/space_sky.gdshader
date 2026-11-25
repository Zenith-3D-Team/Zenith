// The backdrop on a space platform: black space with two layers of stars, a faint band of
// nebula, and, while the platform is at a planet (or near one on a route), that planet below the
// platform, big enough that its curve shows past the deck's edges from the default view (50
// degrees down, a narrow field of view).
// Stars are fixed to directions, so they stay put as the camera moves, like distant stars.
// Space is near black, as Factorio's own behind a platform: about 3/3/7 of 255 before the look's
// exposure, the nebula barely there, the stars faint points.
// The planet turns once per its day (planet_spin, from the game's time of day there: planet_spin.gd),
// lit from the sun that lights the deck (planet_sun).
shader_type sky;

#include "res://shaders/sky_view.gdshaderinc"

uniform vec3 planet_color = vec3(0.25, 0.42, 0.55);
uniform float planet_on = 0.0;
// Where the planet is and how big it looks (radians). Straight below a stopped platform, as Factorio
// draws the planet under it; ahead of one coming to it, behind one leaving. Fixed in the sky, so it
// looks the same whichever way the camera turns (F4).
uniform vec3 planet_dir = vec3(0.0, -1.0, 0.0);
uniform float planet_radius = 0.2;
// Fades it out at the far end of its way, instead of it popping out of the sky.
uniform float planet_alpha = 1.0;
// Factorio's own picture of the planet (its star map sprite, from the player's install), drawn
// over the disc; without one, the procedural sphere below (owner's #15).
uniform sampler2D planet_tex : source_color, filter_linear_mipmap;
uniform float planet_tex_on = 0.0;
// Factorio's own maps of the planet's whole surface (space-age/graphics/space/<planet>*.png, 2048 x
// 1024, longitude across, latitude down), wrapped round a lit sphere: the surface, its clouds
// (luminance and alpha) turning a little faster than the ground, and what glows on the night side
// (Vulcanus' lava). Used once loaded (main.gd); the star map picture above until then.
uniform sampler2D planet_map : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D planet_clouds : filter_linear_mipmap, repeat_enable;
uniform sampler2D planet_emission : source_color, filter_linear_mipmap, repeat_enable;
uniform float planet_map_on = 0.0;
uniform float planet_clouds_on = 0.0;
// How far round the planet has turned (0-1): 0 when the map's middle meridian faces the sun, its noon;
// a full turn east each day there. Its clouds' turn, a little ahead.
uniform float planet_spin = 0.0;
uniform float planet_cloud_spin = 0.0;
// Towards the sun (the scene's sun, so the planet's day side is the side the deck is lit from).
uniform vec3 planet_sun = vec3(0.5, 0.8, 0.3);
uniform float planet_emission_on = 0.0;
// The layered cloud look (on unless --planet-clouds=old): Factorio's own cloud flow and relief maps
// (<planet>-cloud-flow.png, -cloud-normal.png, from the install) move and light the cloud map; the
// clouds' own colour and alpha (the old look read luminance as alpha), each planet's coverage and
// character (planet_cloud_style), edges broken up by a little domain-warped noise on the sphere
// (no seam, no pinch at the poles, faded out where it would be finer than a pixel), lit with a soft,
// warm terminator a little past the ground's, a shadow cast on the surface below, thinner at the
// limb, and an atmosphere rim on the lit side.
uniform float planet_cloud_look = 1.0;
uniform sampler2D planet_cloud_flow : filter_linear_mipmap, repeat_enable;
uniform sampler2D planet_cloud_normal : filter_linear_mipmap, repeat_enable;
uniform float planet_cloud_flow_on = 0.0;
uniform float planet_cloud_normal_on = 0.0;
// Where the clouds are in their flow cycle (0-1, the game's ticks: planet_spin.gd cloud_flow()).
uniform float planet_cloud_flow_t = 0.0;
// x: alpha where cover starts, y: where it is full, z: opacity, w: edge breakup.
uniform vec4 planet_cloud_cover = vec4(0.45, 1.0, 0.9, 0.5);
// rgb: multiplies the map's colour, a: its saturation (0 grey).
uniform vec4 planet_cloud_tint = vec4(1.0, 1.0, 1.0, 1.0);
// x: shadow on the ground, y: flow distance (map widths a cycle), z: relief strength, w: limb thinning.
uniform vec4 planet_cloud_style = vec4(0.35, 0.006, 0.8, 0.5);

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float value_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x), mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y);
	float b = mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x), mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y);
	return mix(a, b, f.z);
}

float fbm(vec3 p) {
	return value_noise(p) * 0.55 + value_noise(p * 2.1) * 0.28 + value_noise(p * 4.3) * 0.17;
}

vec3 stars(vec3 d, float scale, float threshold, float size, float salt) {
	vec3 p = d * scale;
	vec3 cell = floor(p);
	vec3 f = fract(p) - 0.5;
	float h = hash13(cell + salt);
	if (h < threshold) {
		return vec3(0.0);
	}
	vec3 offset = vec3(hash13(cell + salt + 1.7), hash13(cell + salt + 3.1), hash13(cell + salt + 5.3)) - 0.5;
	float dist = length(f - offset * 0.6);
	float b = smoothstep(size, 0.0, dist) * (0.4 + 0.6 * (h - threshold) / (1.0 - threshold));
	float warm = hash13(cell + salt + 7.9);
	return mix(vec3(0.75, 0.82, 1.0), vec3(1.0, 0.88, 0.72), warm) * b;
}

void sky() {
	vec3 d = sky_view_dir(EYEDIR, SCREEN_UV, AT_CUBEMAP_PASS);
	vec3 col = vec3(0.0009, 0.0009, 0.0021);
	float band = exp(-pow(dot(d, normalize(vec3(0.4, 0.7, -0.6))), 2.0) * 6.0);
	col += vec3(0.0035, 0.0024, 0.006) * band * (0.4 + 0.6 * fbm(d * 6.0));
	col += stars(d, 150.0, 0.975, 0.14, 0.0) * 1.1;
	col += stars(d, 380.0, 0.97, 0.2, 11.0) * 0.4;
	vec3 space = col;
	if (planet_on > 0.5) {
		vec3 pd = normalize(planet_dir);
		float ang = acos(clamp(dot(d, pd), -1.0, 1.0));
		if (planet_map_on > 0.5 && ang < planet_radius * 1.25) {
			float r = ang / planet_radius;
			vec3 ref = vec3(0.0, 0.0, -1.0);  // its way runs north and south, so it is never along this
			vec3 right = normalize(cross(pd, ref));
			vec3 up = cross(right, pd);
			vec3 sun = normalize(planet_sun);
			// The sun's longitude in the sphere's frame: the map turns from there, so the meridian at
			// its noon faces the sun whichever way the planet lies in the sky.
			float sun_lon = atan(dot(sun, right), dot(sun, -pd) + 1e-5);
			if (r < 1.0) {
				vec3 side = normalize(d - pd * dot(d, pd));
				vec3 n = normalize(pd * -sqrt(1.0 - r * r) + side * r);
				// The sphere's own frame: its pole towards the picture's top (north), facing us.
				vec3 local = vec3(dot(n, right), dot(n, up), dot(n, -pd));
				float lat = asin(clamp(local.y, -1.0, 1.0));
				float lon = atan(local.x, local.z) - sun_lon;
				float spin = -planet_spin;  // east: what faces the sun moves west on the map
				vec2 uv = vec2(lon / TAU + 0.5 + spin, 0.5 - lat / PI);
				// Mip level from a longitude without the wrap's jump, so the seam shows no line.
				vec2 uv_alt = vec2(fract(lon / TAU + 1.0 + spin), uv.y);
				vec2 gx = dFdx(uv);
				vec2 gy = dFdy(uv);
				vec2 gx2 = dFdx(uv_alt);
				vec2 gy2 = dFdy(uv_alt);
				if (abs(gx2.x) + abs(gy2.x) < abs(gx.x) + abs(gy.x)) {
					gx = gx2;
					gy = gy2;
				}
				vec3 surface = textureGrad(planet_map, uv, gx, gy).rgb;
				float day = dot(n, sun);
				float light = smoothstep(-0.15, 0.35, day);
				vec3 lit = surface * (0.03 + 1.05 * light);
				float mu = sqrt(1.0 - r * r);
				if (planet_clouds_on > 0.5 && planet_cloud_look > 0.5) {
					vec2 cuv = uv + vec2(planet_spin - planet_cloud_spin, 0.0);
					// The surface's frame at this point: east and north, in the sky's directions.
					float lon0 = atan(local.x, local.z);
					float cl = cos(lat);
					vec3 east = right * cos(lon0) + pd * sin(lon0);
					vec3 north = right * (-sin(lat) * sin(lon0)) + up * cl + pd * (sin(lat) * cos(lon0));
					// A point on the sphere turning with the clouds: noise there has no seam or pole.
					float clon = lon - planet_cloud_spin * TAU;
					vec3 q = vec3(cl * sin(clon), sin(lat), cl * cos(clon));
					float n_low = value_noise(q * 5.0 + 3.7);
					vec3 qh = q * 26.0 + vec3(n_low * 2.5);
					float n_hi = value_noise(qh);
					float fine = 1.0 - smoothstep(0.35, 0.9, length(fwidth(qh)));
					// Factorio's flow: two phases a half cycle apart, faded across, the phase shifted
					// by the slow noise so no wide pulse shows.
					vec2 flow = vec2(0.0);
					if (planet_cloud_flow_on > 0.5) {
						flow = textureGrad(planet_cloud_flow, cuv, gx, gy).rg * 2.0 - 1.0;
					}
					float t0 = fract(planet_cloud_flow_t + n_low);
					float t1 = fract(t0 + 0.5);
					float wa = 1.0 - abs(t0 * 2.0 - 1.0);
					vec2 fd = flow * planet_cloud_style.y;
					vec4 ca = textureGrad(planet_clouds, cuv - fd * (t0 - 0.5), gx, gy);
					vec4 cb = textureGrad(planet_clouds, cuv - fd * (t1 - 0.5), gx, gy);
					vec4 c = mix(cb, ca, wa);
					float a = smoothstep(planet_cloud_cover.x, planet_cloud_cover.y, c.a);
					// Edges broken up, the middles left whole.
					a = clamp(a + (n_hi - 0.5) * planet_cloud_cover.w * 4.0 * a * (1.0 - a) * fine, 0.0, 1.0);
					a *= planet_cloud_cover.z * mix(1.0 - planet_cloud_style.w, 1.0, smoothstep(0.0, 0.45, mu));
					vec3 cc = c.rgb;
					cc = mix(vec3(dot(cc, vec3(0.299, 0.587, 0.114))), cc, planet_cloud_tint.a) * planet_cloud_tint.rgb;
					// Relief from Factorio's cloud normals; the clouds sit higher, so they stay lit a
					// little past the ground's terminator, going warm there.
					vec3 cn = n;
					if (planet_cloud_normal_on > 0.5) {
						vec3 tn = textureGrad(planet_cloud_normal, cuv, gx, gy).rgb * 2.0 - 1.0;
						tn.xy *= planet_cloud_style.z;
						cn = normalize(east * tn.x + north * tn.y + n * max(tn.z, 0.05));
					}
					float cday = dot(n, sun);
					float clight = smoothstep(-0.12, 0.3, cday) * mix(1.0, clamp(0.55 + 0.6 * dot(cn, sun) / max(abs(cday), 0.25), 0.35, 1.25), smoothstep(-0.1, 0.2, cday));
					vec3 warm = mix(vec3(1.0, 0.74, 0.58), vec3(1.0), smoothstep(-0.05, 0.16, cday));
					vec3 cloud = cc * warm * (0.035 + 1.1 * clight);
					// The cloud above the ground towards the sun shades it.
					vec2 sd = vec2(dot(sun, east), dot(sun, north)) * (0.012 / max(cday, 0.2));
					vec2 suv = cuv + vec2(sd.x / (TAU * max(cl, 0.15)), -sd.y / PI);
					float sa = smoothstep(planet_cloud_cover.x, planet_cloud_cover.y, textureGrad(planet_clouds, suv, gx, gy).a) * planet_cloud_cover.z;
					lit *= 1.0 - planet_cloud_style.x * sa * smoothstep(0.0, 0.25, cday);
					lit = mix(lit, cloud, a);
				} else if (planet_clouds_on > 0.5) {
					vec2 cuv = uv + vec2(planet_spin - planet_cloud_spin, 0.0);
					vec4 c = textureGrad(planet_clouds, cuv, gx, gy);
					lit = mix(lit, vec3(c.r) * (0.04 + 1.1 * light), c.g * 0.85);
				}
				if (planet_emission_on > 0.5) {
					vec3 glow = textureGrad(planet_emission, uv, gx, gy).rgb;
					lit += glow * (1.0 - light) * 1.4;
				}
				// The limb darkens a little, as a ball does.
				col = lit * mix(0.75, 1.0, mu);
				if (planet_cloud_look > 0.5) {
					// Air seen edge-on, where the sun reaches it.
					col += planet_color * pow(1.0 - mu, 3.0) * 0.35 * smoothstep(-0.25, 0.35, dot(n, sun));
				}
			}
			// Atmosphere: a thin glow of the planet's colour round the lit edge.
			float rim = smoothstep(1.12, 1.0, r) * smoothstep(0.86, 1.0, r);
			if (planet_cloud_look > 0.5 && rim > 0.0) {
				vec3 edge = normalize(d - pd * dot(d, pd));
				rim *= 0.3 + 0.9 * smoothstep(-0.35, 0.45, dot(edge, sun));
			}
			col += planet_color * rim * 0.45;
		} else if (planet_tex_on > 0.5 && ang < planet_radius * 1.05) {
			// The picture's top towards north (-Z) when the planet is straight below.
			vec3 ref = vec3(0.0, 0.0, -1.0);  // its way runs north and south, so it is never along this
			vec3 right = normalize(cross(pd, ref));
			vec3 up = cross(right, pd);
			vec2 off = vec2(dot(d, right), dot(d, up)) / sin(planet_radius);
			vec2 uv = vec2(0.5, 0.5) + vec2(off.x, -off.y) * 0.5;
			if (uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0) {
				vec4 t = texture(planet_tex, uv);
				col = mix(col, t.rgb, t.a);
			}
		} else if (planet_tex_on < 0.5 && ang < planet_radius * 1.25) {
			// A lit sphere: the sun comes from above, so its top is day and its underside night.
			float r = ang / planet_radius;
			if (r < 1.0) {
				vec3 side = normalize(d - pd * dot(d, pd));
				vec3 n = normalize(pd * -sqrt(1.0 - r * r) + side * r);
				float light = clamp(dot(n, normalize(planet_sun)) * 0.6 + 0.4, 0.0, 1.0);
				// The sphere turned about its pole (north, as the map's), so its land turns as the
				// planet's day goes.
				vec3 ref = vec3(0.0, 0.0, -1.0);
				vec3 right = normalize(cross(pd, ref));
				vec3 up = cross(right, pd);
				vec3 local = vec3(dot(n, right), dot(n, up), dot(n, -pd));
				float a = -planet_spin * TAU;
				vec3 q = vec3(local.x * cos(a) + local.z * sin(a), local.y, -local.x * sin(a) + local.z * cos(a));
				// Land and sea from noise on the sphere, and a few lighter clouds over them.
				float land = smoothstep(0.45, 0.55, fbm(q * 3.0));
				float clouds = smoothstep(0.55, 0.75, fbm(q * 5.0 + 9.0));
				vec3 surface = mix(planet_color * 0.55, planet_color * 1.15, land);
				surface = mix(surface, vec3(0.85), clouds * 0.6);
				col = surface * (0.04 + 0.6 * light * light);
			}
			// Atmosphere glow at the rim.
			float rim = smoothstep(1.25, 1.0, r) * smoothstep(0.8, 1.0, r);
			col += planet_color * rim * 0.25;
		}
		col = mix(space, col, planet_alpha);
	}
	COLOR = col;
}
