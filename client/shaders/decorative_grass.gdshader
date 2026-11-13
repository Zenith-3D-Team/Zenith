shader_type spatial;
// Grass and low plants near the character in 3D (decoratives.gd): the decorative's own flat picture on
// a small grid, shaped here, so there is no mesh or data per picture. A tuft is a fountain: the grid's
// middle point sits on the plant's root and the rest rises round it and droops, as blades arch out of
// a clump. A bush or carpet rises where the picture has most plant (a blurred read of its alpha, from
// the atlas's own mipmaps). Points rise along Factorio's camera ray, so from Factorio's angle the plant
// covers exactly what the picture shows and from any other it has height. It is one sheet that doesn't
// overlap itself, so from above each pixel is drawn once. Blended, written to no depth and in a fixed
// order, like the flat pictures: hard cut-outs crawled and sparkled as the view moved.
// INSTANCE_CUSTOM is (u start, u width, v height, 1 + the root packed by decoratives.gd).
render_mode blend_mix, depth_draw_never, cull_disabled;

#include "res://shaders/ground_height.gdshaderinc"
#include "res://shaders/decorative_grass.gdshaderinc"

uniform sampler2D atlas : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float height = 0.3;  // tiles, where the picture is thickest
uniform float mass_lod = 3.0;  // the mipmap as coarse as the grid
uniform bool tuft = true;  // a fountain from its root, or lumps where the plant is thick

// cot(FACTORIO_PITCH 48 degrees): a point raised h moves this far south along Factorio's camera ray.
const float RAY_SOUTH = 0.9;

varying float level;  // as decorative_flat.gdshader: fades out on steep ground
varying float rise;  // 0 at the ground, 1 at the top
varying float grow;

void vertex() {
	vec2 at = MODEL_MATRIX[3].xz;
	grow = grass_grow(at);
	level = 1.0;
	rise = 0.0;
	if (grow <= 0.0) {
		VERTEX = vec3(0.0);  // past the range: nothing to rasterise, the flat picture is there
	} else {
		vec2 mesh_uv = UV;
		if (tuft) {
			// The grid bent so its middle point falls on the root, then a ring at half way, then the edge.
			float packed = fract(INSTANCE_CUSTOM.w) * 64.0;
			vec2 root = vec2(floor(packed), floor(fract(packed) * 64.0 + 0.5)) / 63.0;
			vec2 side = step(0.5, UV);
			vec2 ring = abs(UV - 0.5) * 2.0;
			mesh_uv = mix(root * (1.0 - ring), root + (1.0 - root) * ring, side);
			VERTEX.xz = mesh_uv - 0.5;
			float r = max(ring.x, ring.y);
			rise = smoothstep(0.0, 0.5, r) * (1.0 - 0.3 * smoothstep(0.5, 1.0, r));
		}
		UV = vec2(INSTANCE_CUSTOM.x + mesh_uv.x * INSTANCE_CUSTOM.y, mesh_uv.y * INSTANCE_CUSTOM.z);
		if (!tuft) {
			float mass = textureLod(atlas, UV, mass_lod).a;
			vec2 edge = min(mesh_uv, 1.0 - mesh_uv);
			rise = (1.0 - exp(-5.0 * mass)) * smoothstep(0.0, 0.16, min(edge.x, edge.y));
		}
		// Grid points aren't all the same height, so no two clumps are the same shape.
		float lump = fract(sin(dot(mesh_uv * 13.0 + at, vec2(12.9898, 78.233))) * 43758.5453);
		rise *= 0.75 + 0.5 * lump;
		float h = height * rise * grow;
		vec2 size = vec2(MODEL_MATRIX[0].x, MODEL_MATRIX[2].z);
		vec2 sway = vec2(0.0);
		if (f3d_grass_wind > 0.5) {
			float t = TIME * 1.6 + at.x * 0.35 + at.y * 0.21 + mesh_uv.x * 1.3;
			sway = vec2(sin(t), sin(t * 0.73 + 1.7)) * (0.07 * h * rise);
		}
		VERTEX.x += sway.x / size.x;
		VERTEX.z += (h * RAY_SOUTH + sway.y) / size.y;
		VERTEX.y += h + 0.004;
		level = ground_n((MODEL_MATRIX * vec4(VERTEX, 1.0)).xz).y;
		VERTEX = ground_lift(VERTEX, MODEL_MATRIX);
	}
}

global uniform float f3d_look_ground_specular;  // looks.gd "ground_specular"

void fragment() {
	vec4 c = texture(atlas, UV);
	// The pictures' baked shadows are pure black and part see-through; they stay on the ground with
	// the flat picture. The plant itself is never that dark.
	float blade = c.a * smoothstep(0.002, 0.016, max(c.r, max(c.g, c.b)));
	if (blade < 0.02) {
		discard;
	}
	// Darker at the root, a little lighter at the tips: the height reads from any angle.
	ALBEDO = c.rgb * mix(1.0, mix(0.7, 1.12, clamp(rise, 0.0, 1.0)), grow);
	SPECULAR = 0.5 * f3d_look_ground_specular;
	// Lit as the flat picture, from straight up, on whichever side the view sees.
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	ALPHA = blade * smoothstep(0.0, 0.4, grow) * smoothstep(0.75, 0.9, level);
}
