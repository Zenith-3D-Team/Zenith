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

float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Gradient noise (smooth, no grid showing the way value noise does when seen in perspective), about 0-1.
float gnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float ga = hash(i) * 6.2831853;
	float gb = hash(i + vec2(1.0, 0.0)) * 6.2831853;
	float gc = hash(i + vec2(0.0, 1.0)) * 6.2831853;
	float gd = hash(i + vec2(1.0, 1.0)) * 6.2831853;
	float a = dot(vec2(cos(ga), sin(ga)), f);
	float b = dot(vec2(cos(gb), sin(gb)), f - vec2(1.0, 0.0));
	float c = dot(vec2(cos(gc), sin(gc)), f - vec2(0.0, 1.0));
	float d = dot(vec2(cos(gd), sin(gd)), f - vec2(1.0, 1.0));
	return 0.5 + 0.75 * mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p, int octaves) {
	float v = 0.0;
	float a = 0.5;
	mat2 turn = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));
	for (int i = 0; i < octaves; i++) {
		p = turn * p * 2.03 + 17.1;
		v += a * gnoise(p * 0.5);
		a *= 0.5;
	}
	return v / (1.0 - pow(0.5, float(octaves)));
}

// The clouds' density at a point in the world (0 clear, 1 thick), thinning to the layer's top and bottom.
float cloud_density(vec3 p, int octaves) {
	vec2 q = (p.xz - wind * TIME) * cloud_scale;
	// A little warp of the pattern by itself, so clouds billow instead of lying in even blobs.
	q += 0.55 * vec2(gnoise(q * 0.7 + 3.1), gnoise(q * 0.7 + 8.7)) - 0.275;
	float shape = fbm(q, octaves);
	float h = clamp((p.y - cloud_low) / (cloud_high - cloud_low), 0.0, 1.0);
	// Each cloud is widest a third of the way up and narrows to its flat base and rounded top, so seen
	// from low down it is a cloud, not a column of the pattern stretched up through the layer.
	float narrow = 0.5 * pow(abs(h - 0.32) / 0.68, 1.6);
	float cover = 1.0 - cloud_cover;
	return clamp((shape - cover * 0.8 - 0.2 - narrow) * 2.6, 0.0, 1.0);
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
	const int STEPS = 14;
	float dt = (t1 - t0) / float(STEPS);
	// Clouds keep the sun a few degrees after the ground has lost it, and their shaded sides take the
	// sky's colour as it goes.
	float sun_on = smoothstep(-0.08, 0.07, look_sun_height);
	vec3 lit_color = mix(look_ambient_color * 0.75, look_sun_color, mix(1.0, sun_on, step(0.001, look_twilight)));
	// At dusk the sky is lit from one side: away from the sun clouds stay dim.
	float toward = clamp(0.5 + 0.5 * dot(normalize(dir.xz + vec2(1e-5)), normalize(look_sun_dir.xz + vec2(1e-5))), 0.0, 1.0);
	vec3 lit = lit_color * mix(0.06, 1.35 - 0.9 * look_twilight, mix(1.0 - night, sun_on, step(0.001, look_twilight)))
		* mix(1.0, mix(0.3, 1.0, toward * toward), look_twilight);
	vec3 shade = mix(mix(vec3(0.46, 0.53, 0.64), look_ambient_color * 0.3, look_twilight), vec3(0.03, 0.04, 0.07), night);
	// Looking towards a low sun, its light rims them.
	float rim = pow(max(dot(dir, normalize(look_sun_dir)), 0.0), 6.0) * look_twilight;
	vec3 col = vec3(0.0);
	float trans = 1.0;
	for (int i = 0; i < STEPS; i++) {
		vec3 p = from + dir * (t0 + (float(i) + jitter) * dt);
		float d = cloud_density(p, 5);
		if (d > 0.001) {
			// How much cloud lies towards the sun from here: the lit side's brightness.
			float towards = cloud_density(p + look_sun_dir * 40.0, 3) + cloud_density(p + look_sun_dir * 90.0, 3);
			float light = exp(-towards * 1.6);
			float h = clamp((p.y - cloud_low) / (cloud_high - cloud_low), 0.0, 1.0);
			// With the sun low the light reaches their bases too.
			vec3 c = mix(shade, lit, light * mix(0.55 + 0.45 * h, 1.0 - 0.15 * h, look_twilight) + rim * 0.35);
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

// How much of the sun's light the clouds take at a point on the ground.
float ground_cloud_shadow(vec3 p) {
	// Fades out with the sun instead of cutting off; from no lower than the light itself comes.
	float fade = smoothstep(0.0, 0.22, look_sun_height);
	if (fade <= 0.0)
		return 0.0;
	vec3 sd = normalize(vec3(look_sun_dir.x, max(look_sun_dir.y, 0.24), look_sun_dir.z));
	vec3 at = p + sd * ((0.5 * (cloud_low + cloud_high) - p.y) / sd.y);
	float d = cloud_density(vec3(at.x, 0.5 * (cloud_low + cloud_high), at.z), 4);
	return smoothstep(0.03, 0.45, d) * fade;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 from_mid = uv - 0.5;
	float edge = dot(from_mid, from_mid) * 2.0;  // 0 in the middle, 1 at the corners

	// How far this pixel is against what the camera looks at (the sky counts as far).
	float focus = clamp(scene_distance(vec2(0.5), INV_PROJECTION_MATRIX), 4.0, 600.0);
	float raw = scene_depth_raw(uv);
	float dist = raw <= 0.0 ? 1e6 : scene_distance(uv, INV_PROJECTION_MATRIX);
	float rel = dist / focus;
	float near = 1.0 - smoothstep(sharp_until, sharp_gone, rel);
	float far = smoothstep(soft_from, soft_full, rel) * soften;
	// Space behind a platform stays black with sharp stars: softening smeared each star into a grey
	// glow over the backdrop, and local contrast lifted the dark round them.
	float space_sky = step(0.5, look_space) * (1.0 - step(1e-6, raw));
	far *= 1.0 - space_sky;

	// Chromatic aberration: red and blue a little apart towards the corners (on what is near).
	vec2 shift = from_mid * aberration * edge * 2.0 * near;
	vec3 c = vec3(scene_color(uv + shift).r, scene_color(uv).g, scene_color(uv - shift).b);

	// The far distance softened: a smaller copy of the screen, which also hides what shimmers there.
	c = mix(c, scene_color_blurred(uv, 1.6), far);

	// Clouds: in the sky where nothing was drawn, their shadows on everything else (on what the sun lights:
	// the brightest parts lose most).
	// None in space: a platform's sky is stars, and its deck has no cloud over it (look_space).
	if (clouds > 0.0 && look_space < 0.5) {
		vec3 ndc = vec3(uv * 2.0 - 1.0, raw <= 0.0 ? 1.0 : raw);
		vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		view.xyz /= view.w;
		vec3 world = (INV_VIEW_MATRIX * vec4(view.xyz, 1.0)).xyz;
		if (raw <= 0.0) {
			vec3 dir = normalize(world - CAMERA_POSITION_WORLD);
			vec4 cl = sky_clouds(CAMERA_POSITION_WORLD, dir, look_night, hash(FRAGCOORD.xy + fract(TIME * 7.3) * 811.0));
			c = mix(c, cl.rgb / max(cl.a, 1e-4), cl.a * clouds);
		} else {
			float sh = ground_cloud_shadow(world) * cloud_shadow * clouds * (1.0 - look_night);
			float bright = smoothstep(0.02, 0.5, luma(c));
			c *= 1.0 - sh * mix(0.45, 1.0, bright);
			// In the shade of a cloud at dusk only the sky lights it.
			c *= mix(vec3(1.0), look_ambient_color / max(luma(look_ambient_color), 1e-3), sh * look_twilight * 0.5);
		}
	}

	// Local contrast and sharpening on the brightness only, so colours don't fringe; sharpening only
	// near, local contrast kept a little further.
	float l = luma(c);
	float wide = luma(scene_color_blurred(uv, 3.0));
	float fine = luma(scene_color_blurred(uv, 1.0));
	float boosted = l + (clarity * mix(0.3, 1.0, near) * (l - wide) / (1.0 + abs(l - wide) * 2.0)
		+ sharpen * near * (l - fine)) * (1.0 - space_sky);
	// Never darker than a quarter of itself: beside something far brighter (a sun glint on water) the
	// difference to the blurred copies dwarfs the pixel, and it went black in blocks the size of the
	// blurred mips (B-roll: black boxes round specks on Aquilo's and Gleba's water).
	boosted = max(boosted, l * 0.25);
	c *= boosted / max(l, 1e-4);
	l = boosted;

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
	float blue_hour = max(look_twilight * smoothstep(0.1, -0.03, look_sun_height), night_cool * smoothstep(0.75, 0.95, look_night)) * step(1e-6, raw);  // not the sky
	c = mix(c, vec3(l) * look_ambient_color / max(luma(look_ambient_color), 1e-3), blue_hour * 0.55);

	// Vignette and grain (fine, and mostly in the shade, as film's).
	c *= 1.0 - vignette * smoothstep(0.15, 1.0, edge);
	float n = hash(FRAGCOORD.xy + fract(TIME * 7.3) * 811.0) - 0.5;
	c += c * n * grain * 2.0 * (1.0 - smoothstep(0.3, 1.5, l));

	ALBEDO = max(c, vec3(0.0));
}
