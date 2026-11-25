// The clouds' pattern, drawn once into a texture when the add-on starts (main.gd _cloud_field): the
// grade (cinematic_grade.gdshader) reads it in place of working the noise out on every pixel of the
// ground and on every step of its march through the sky, up to about 150 noise calls a sky pixel.
//
// The same pattern as the grade worked out before (0.4.4): its gradient noise, warped by itself, in five
// octaves of the same strengths, at the same sizes to within 1.5%. It is made to repeat every `period`
// of the pattern (16: about 1,800 tiles at the grade's cloud_scale) so one texture holds all of it: each
// octave has a whole number of cells across the period and its lattice wraps there. That leaves out
// the turn the octaves had (a turned lattice can't wrap on a square), so the clouds are new shapes of
// the same kind. Red, green and blue: the pattern to 3, 4 and 5 octaves (the sky's light samples, the
// shadows on the ground, the sky's clouds), each 0 to about 1 (Viewport.use_hdr_2d: 16-bit floats).
shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform float period = 16.0;

float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// The grade's gradient noise (about 0-1), its lattice wrapped every `cells` cells; p is never negative.
float gnoise_wrapped(vec2 p, float cells, vec2 seed) {
	vec2 i = floor(p);
	vec2 f = p - i;
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	// Wrapped in integers: a float mod's division can land a hair under a whole number at the
	// period's edge and pick the wrong cell, a seam.
	ivec2 n = ivec2(int(cells));
	ivec2 a = ivec2(i) % n;
	ivec2 b = (ivec2(i) + ivec2(1)) % n;
	float ga = hash(vec2(a) + seed) * 6.2831853;
	float gb = hash(vec2(float(b.x), float(a.y)) + seed) * 6.2831853;
	float gc = hash(vec2(float(a.x), float(b.y)) + seed) * 6.2831853;
	float gd = hash(vec2(b) + seed) * 6.2831853;
	float va = dot(vec2(cos(ga), sin(ga)), f);
	float vb = dot(vec2(cos(gb), sin(gb)), f - vec2(1.0, 0.0));
	float vc = dot(vec2(cos(gc), sin(gc)), f - vec2(0.0, 1.0));
	float vd = dot(vec2(cos(gd), sin(gd)), f - vec2(1.0, 1.0));
	return 0.5 + 0.75 * mix(mix(va, vb, u.x), mix(vc, vd, u.x), u.y);
}

void fragment() {
	// The pattern's coordinates (the grade's (world - wind * time) * cloud_scale), one period across.
	vec2 q0 = UV * period;
	// A little warp of the pattern by itself, so clouds billow instead of lying in even blobs (0.7 cells
	// a unit before; the offsets keep every lattice coordinate positive).
	float warp_cells = max(round(0.7 * period), 1.0);
	vec2 w = q0 * (warp_cells / period);
	vec2 q = q0 + 0.55 * vec2(gnoise_wrapped(w + 3.1, warp_cells, vec2(0.0)), gnoise_wrapped(w + 8.7, warp_cells, vec2(0.0))) - 0.275;
	// Five octaves, each about 2.03 times finer and half as strong (0.5 * 2.03^(k+1) cells a unit before).
	float v = 0.0;
	float amp = 0.5;
	float three = 0.0;
	float four = 0.0;
	for (int k = 0; k < 5; k++) {
		float cells = max(round(0.5 * pow(2.03, float(k + 1)) * period), 1.0);
		vec2 offset = vec2(8.55, 8.55) + float(k) * vec2(5.37, 11.71);
		v += amp * gnoise_wrapped(q * (cells / period) + offset, cells, vec2(float(k) * 41.0, float(k) * 17.0));
		amp *= 0.5;
		if (k == 2) {
			three = v;
		} else if (k == 3) {
			four = v;
		}
	}
	// Cloud-type height map in alpha (2 low-frequency wrapped octaves, [0.25, 1.0]) while RGB stays unchanged.
	float tc1 = max(round(0.35 * period), 1.0);
	float tc2 = max(round(0.70 * period), 1.0);
	float ctype = 0.65 * gnoise_wrapped(q0 * (tc1 / period) + vec2(17.3, 4.9), tc1, vec2(91.0, 23.0))
		+ 0.35 * gnoise_wrapped(q0 * (tc2 / period) + vec2(3.7, 29.1), tc2, vec2(137.0, 59.0));
	ctype = clamp(smoothstep(0.18, 0.84, ctype) * 0.75 + 0.25, 0.25, 1.0);
	// Each sum over its octaves' strengths, as the grade's fbm() divided it.
	COLOR = vec4(three / 0.875, four / 0.9375, v / 0.96875, ctype);
}
