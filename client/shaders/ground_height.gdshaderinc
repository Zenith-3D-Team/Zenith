// The ground's height under a world point, drawn only (scripts/world/ground_height.gd). Off
// (f3d_ground_on 0) everything stays at y = 0. The same sum as GroundHeight.at(): bilinear
// between texel centres, read with texelFetch so no sampler setting can change it, 0 outside.

global uniform sampler2D f3d_ground;
// The first texel's corner (x, z), tiles a texel, and 1 when green holds the low ground (the
// ground without its cliffs' terraces, which cliff models sit on).
global uniform vec4 f3d_ground_rect;
global uniform float f3d_ground_on;

float ground_texel(ivec2 i, ivec2 size, bool low) {
	vec4 t = texelFetch(f3d_ground, clamp(i, ivec2(0), size - 1), 0);
	return low && f3d_ground_rect.w > 0.5 ? t.g : t.r;
}

float ground_h_of(vec2 xz, bool low) {
	if (f3d_ground_on < 0.5) {
		return 0.0;
	}
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

float ground_h(vec2 xz) {
	return ground_h_of(xz, false);
}

// The ground's upward normal at a world point (world space), from the height's slope.
vec3 ground_n(vec2 xz) {
	if (f3d_ground_on < 0.5) {
		return vec3(0.0, 1.0, 0.0);
	}
	float e = max(f3d_ground_rect.z, 0.5);
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
