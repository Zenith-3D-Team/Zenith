// The ground's height under a world point, drawn only (scripts/world/ground_height.gd). Off
// (f3d_ground_on 0) everything stays at y = 0. The same sum as GroundHeight.at(): bilinear
// between texel centres, read with texelFetch so no sampler setting can change it, 0 outside;
// while a new field fades in, mixed with the one before it.

global uniform sampler2D f3d_ground;
// The first texel's corner (x, z), tiles a texel, and 1 when green holds the low ground (the
// ground without its cliffs' terraces, which cliff models sit on).
global uniform vec4 f3d_ground_rect;
global uniform float f3d_ground_on;

// While a new field fades in (ground_height.gd, an add-on's `fade_in`): the field before it, its
// rect (step 0: flat ground before it), and how far the new one has come (1: the new one alone).
global uniform sampler2D f3d_ground_prev;
global uniform vec4 f3d_ground_prev_rect;
global uniform float f3d_ground_mix;

float ground_texel(ivec2 i, ivec2 size, bool low) {
	vec4 t = texelFetch(f3d_ground, clamp(i, ivec2(0), size - 1), 0);
	return low && f3d_ground_rect.w > 0.5 ? t.g : t.r;
}

float ground_prev_texel(ivec2 i, ivec2 size, bool low) {
	vec4 t = texelFetch(f3d_ground_prev, clamp(i, ivec2(0), size - 1), 0);
	return low && f3d_ground_prev_rect.w > 0.5 ? t.g : t.r;
}

float ground_h_now(vec2 xz, bool low) {
	ivec2 size = textureSize(f3d_ground, 0);
	vec2 g = (xz - f3d_ground_rect.xy) / f3d_ground_rect.z - 0.5;
	if (g.x < -0.5 || g.y < -0.5 || g.x > float(size.x) - 0.5 || g.y > float(size.y) - 0.5) {
		return 0.0;
	}
	ivec2 i = ivec2(floor(g));
	vec2 f = g - vec2(i);
	float a = mix(ground_texel(i, size, low), ground_texel(i + ivec2(1, 0), size, low), f.x);
	float b = mix(ground_texel(i + ivec2(0, 1), size, low), ground_texel(i + ivec2(1, 1), size, low), f.x);
	return mix(a, b, f.y);
}

float ground_h_prev(vec2 xz, bool low) {
	if (f3d_ground_prev_rect.z <= 0.0) {
		return 0.0;
	}
	ivec2 size = textureSize(f3d_ground_prev, 0);
	vec2 g = (xz - f3d_ground_prev_rect.xy) / f3d_ground_prev_rect.z - 0.5;
	if (g.x < -0.5 || g.y < -0.5 || g.x > float(size.x) - 0.5 || g.y > float(size.y) - 0.5) {
		return 0.0;
	}
	ivec2 i = ivec2(floor(g));
	vec2 f = g - vec2(i);
	float a = mix(ground_prev_texel(i, size, low), ground_prev_texel(i + ivec2(1, 0), size, low), f.x);
	float b = mix(ground_prev_texel(i + ivec2(0, 1), size, low), ground_prev_texel(i + ivec2(1, 1), size, low), f.x);
	return mix(a, b, f.y);
}

float ground_h_of(vec2 xz, bool low) {
	if (f3d_ground_on < 0.5) {
		return 0.0;
	}
	float h = ground_h_now(xz, low);
	if (f3d_ground_mix < 1.0) {
		h = mix(ground_h_prev(xz, low), h, f3d_ground_mix);
	}
	return h;
}

float ground_h(vec2 xz) {
	return ground_h_of(xz, false);
}

// --- Cliffs seated in their terrace (--cliff-fit), and how near a cliff the ground is (blue) ---
// A field's three channels at a point: (the ground, the ground without its cliffs' terraces, how
// near a cliff 0-1). An RF field gives its height for the first two; RF and RGF fields read 0 blue.
global uniform float f3d_cliff_fit;  // 1: cliffs seated (ground_lift_cliff); 0: --cliff-fit=off, on the low ground as before

vec3 ground3_texel(ivec2 i, ivec2 size) {
	vec4 t = texelFetch(f3d_ground, clamp(i, ivec2(0), size - 1), 0);
	return vec3(t.r, f3d_ground_rect.w > 0.5 ? t.g : t.r, t.b);
}

vec3 ground3_prev_texel(ivec2 i, ivec2 size) {
	vec4 t = texelFetch(f3d_ground_prev, clamp(i, ivec2(0), size - 1), 0);
	return vec3(t.r, f3d_ground_prev_rect.w > 0.5 ? t.g : t.r, t.b);
}

vec3 ground3_now(vec2 xz) {
	ivec2 size = textureSize(f3d_ground, 0);
	vec2 g = (xz - f3d_ground_rect.xy) / f3d_ground_rect.z - 0.5;
	if (g.x < -0.5 || g.y < -0.5 || g.x > float(size.x) - 0.5 || g.y > float(size.y) - 0.5) {
		return vec3(0.0);
	}
	ivec2 i = ivec2(floor(g));
	vec2 f = g - vec2(i);
	vec3 a = mix(ground3_texel(i, size), ground3_texel(i + ivec2(1, 0), size), f.x);
	vec3 b = mix(ground3_texel(i + ivec2(0, 1), size), ground3_texel(i + ivec2(1, 1), size), f.x);
	return mix(a, b, f.y);
}

vec3 ground3_prev(vec2 xz) {
	if (f3d_ground_prev_rect.z <= 0.0) {
		return vec3(0.0);
	}
	ivec2 size = textureSize(f3d_ground_prev, 0);
	vec2 g = (xz - f3d_ground_prev_rect.xy) / f3d_ground_prev_rect.z - 0.5;
	if (g.x < -0.5 || g.y < -0.5 || g.x > float(size.x) - 0.5 || g.y > float(size.y) - 0.5) {
		return vec3(0.0);
	}
	ivec2 i = ivec2(floor(g));
	vec2 f = g - vec2(i);
	vec3 a = mix(ground3_prev_texel(i, size), ground3_prev_texel(i + ivec2(1, 0), size), f.x);
	vec3 b = mix(ground3_prev_texel(i + ivec2(0, 1), size), ground3_prev_texel(i + ivec2(1, 1), size), f.x);
	return mix(a, b, f.y);
}

vec3 ground3_of(vec2 xz) {
	if (f3d_ground_on < 0.5) {
		return vec3(0.0);
	}
	vec3 g = ground3_now(xz);
	if (f3d_ground_mix < 1.0) {
		g = mix(ground3_prev(xz), g, f3d_ground_mix);
	}
	return g;
}

// How near a cliff the ground is, 0-1 (an add-on's third channel; 0 without one).
float ground_cliff_near(vec2 xz) {
	return ground3_of(xz).z;
}


// 1: the terraces' slope read where it is (ground_n); 0: --cliff-ground-normal=old, across a texel's width.
global uniform float f3d_cliff_normal;
// How far either side of a point the terraces' slope is read (tiles).
const float GROUND_N_TERRACE = 0.5;

// The ground's upward normal at a world point (world space), from the height's slope: the hills' across
// a texel either side, so they shade smoothly. With a field's low ground (cliffs' terraces), the
// terraces' part (the ground less the low ground) half a tile either side: read a whole 2-tile texel out,
// the flat ground a tile or two in front of a cliff took the step's slope (33 degrees for a 2.5-tile
// terrace) and was shaded as a slope, bare of the decoratives that fade out on steep ground.
vec3 ground_n(vec2 xz) {
	if (f3d_ground_on < 0.5) {
		return vec3(0.0, 1.0, 0.0);
	}
	float e = max(f3d_ground_rect.z, 0.5);
	if (f3d_cliff_normal > 0.5 && f3d_ground_rect.w > 0.5) {
		float s = GROUND_N_TERRACE;
		vec3 xp = ground3_of(xz + vec2(e, 0.0));
		vec3 xm = ground3_of(xz - vec2(e, 0.0));
		vec3 zp = ground3_of(xz + vec2(0.0, e));
		vec3 zm = ground3_of(xz - vec2(0.0, e));
		vec3 xps = ground3_of(xz + vec2(s, 0.0));
		vec3 xms = ground3_of(xz - vec2(s, 0.0));
		vec3 zps = ground3_of(xz + vec2(0.0, s));
		vec3 zms = ground3_of(xz - vec2(0.0, s));
		float sx = (xp.y - xm.y) / (2.0 * e) + ((xps.x - xps.y) - (xms.x - xms.y)) / (2.0 * s);
		float sz = (zp.y - zm.y) / (2.0 * e) + ((zps.x - zps.y) - (zms.x - zms.y)) / (2.0 * s);
		return normalize(vec3(-sx, 1.0, -sz));
	}
	float dx = ground_h(xz + vec2(e, 0.0)) - ground_h(xz - vec2(e, 0.0));
	float dz = ground_h(xz + vec2(0.0, e)) - ground_h(xz - vec2(0.0, e));
	return normalize(vec3(-dx, 2.0 * e, -dz));
}

// A world "up" of h in a model's own space: inverse(mat3(model)) * (0, h, 0), the one column of the
// inverse that needs, from cross products. Not from the columns' lengths: legs stretched between two
// joints (vehicle_anim.gd) and flattened drop shadows (movers.gd) are sheared. An instance hidden by
// scaling it to nothing has no inverse and stays put.
vec3 ground_up_in(mat4 model, float h) {
	vec3 a = model[0].xyz;
	vec3 b = model[1].xyz;
	vec3 c = model[2].xyz;
	vec3 bc = cross(b, c);
	float det = dot(a, bc);
	if (det == 0.0) {
		return vec3(0.0);
	}
	return vec3(bc.y, c.z * a.x - c.x * a.z, a.z * b.x - a.x * b.z) * (h / det);
}

// A vertex in model space lifted by the ground under its world position: the lift is a world
// "up", turned back into the model's own space (a MultiMesh instance's turn and scale included).
// `low`: by the ground without its cliffs' terraces (cliff models: the rock on the low ground).
vec3 ground_lift_of(vec3 v, mat4 model, bool low) {
	if (f3d_ground_on < 0.5) {
		return v;
	}
	vec3 w = (model * vec4(v, 1.0)).xyz;
	float h = ground_h_of(w.xz, low);
	if (h == 0.0) {
		return v;
	}
	return v + ground_up_in(model, h);
}

vec3 ground_lift(vec3 v, mat4 model) {
	return ground_lift_of(v, model, false);
}

// The same lift for something placed by its origin alone (icons, effect cards): the height
// under the model's origin.
vec3 ground_lift_origin(vec3 v, mat4 model) {
	if (f3d_ground_on < 0.5) {
		return v;
	}
	float h = ground_h(model[3].xz);
	if (h == 0.0) {
		return v;
	}
	return v + ground_up_in(model, h);
}

// The terrace's height near a point: the most of (ground - low ground) at 8 points 3 tiles round it
// (GroundHeight.terrace_near).
const vec2 CLIFF_TAPS[8] = vec2[](vec2(3.0, 0.0), vec2(2.1213, 2.1213), vec2(0.0, 3.0), vec2(-2.1213, 2.1213),
	vec2(-3.0, 0.0), vec2(-2.1213, -2.1213), vec2(0.0, -3.0), vec2(2.1213, -2.1213));

float cliff_terrace_near(vec2 xz) {
	float d = 0.0;
	for (int k = 0; k < 8; k++) {
		vec3 g = ground3_of(xz + CLIFF_TAPS[k]);
		d = max(d, g.x - g.y);
	}
	return d;
}

// Where a cliff's vertex `y` tiles over its model's ground stands (GroundHeight.cliff_seat): on the
// low ground, the rock grown with a terrace taller than 2 tiles (never smaller than Factorio's), and
// never under the high ground (no more than 0.1 tile into it). Flat ground: low + y, as before.
float cliff_seat(float y, float high, float low, float terrace) {
	float f = max(1.0, terrace * 0.5);
	return max(low + y * f, high - 0.1);
}

// A cliff's vertex lifted (cliff models, their shadow stand-ins and far merges: ground_low; the
// distant horizon's cliff blocks). --cliff-fit=off: on the low ground, as before.
vec3 ground_lift_cliff(vec3 v, mat4 model) {
	if (f3d_ground_on < 0.5) {
		return v;
	}
	if (f3d_cliff_fit < 0.5) {
		return ground_lift_of(v, model, true);
	}
	vec3 w = (model * vec4(v, 1.0)).xyz;
	vec3 g = ground3_of(w.xz);
	float h = cliff_seat(w.y, g.x, g.y, cliff_terrace_near(w.xz)) - w.y;
	if (h == 0.0) {
		return v;
	}
	return v + ground_up_in(model, h);
}

// The generated cliff wall's seat (cliff_wall.gd, a material's cliff_wall): as cliff_seat, but its foot
// (0 to 0.4 tiles over its model's ground: the scree apron, its stones) rides just over the ground, so a
// terrace's ramp in front of the face stays under the apron; below 0 (block bases, the apron's outer edge,
// the deck's back lip) tucks 0.1 into it as before.
float cliff_wall_seat(float y, float high, float low, float terrace) {
	float f = max(1.0, terrace * 0.5);
	float over = (y >= 0.0 && y <= 0.4) ? 0.04 + 0.3 * y : -0.1;
	return max(low + y * f, high + over);
}

vec3 ground_lift_cliff_wall(vec3 v, mat4 model) {
	if (f3d_ground_on < 0.5) {
		return v;
	}
	if (f3d_cliff_fit < 0.5) {
		return ground_lift_of(v, model, true);
	}
	vec3 w = (model * vec4(v, 1.0)).xyz;
	vec3 g = ground3_of(w.xz);
	float h = cliff_wall_seat(w.y, g.x, g.y, cliff_terrace_near(w.xz)) - w.y;
	if (h == 0.0) {
		return v;
	}
	return v + ground_up_in(model, h);
}

// `low`: a cliff's rock (a material's ground_low), seated by ground_lift_cliff; else by the ground.
vec3 ground_lift_low(vec3 v, mat4 model, bool low) {
	return low ? ground_lift_cliff(v, model) : ground_lift_of(v, model, false);
}
