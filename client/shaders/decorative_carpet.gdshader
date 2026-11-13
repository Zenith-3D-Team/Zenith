shader_type spatial;
// Carpet grass near the character in 3D (decoratives.gd): Factorio's wide patches of short blades
// (green-carpet-grass and the like, about 4 tiles across) stood up as clumps of blades, the way shipped
// games draw grass: one shared mesh of crossed cards, instanced, shaped here. Each instance is one patch,
// as its flat picture; the mesh is a row of clumps, two crossed cards each, and which piece of the
// picture each clump shows is in `cells` (a row per variant, made from the picture's plant by
// decoratives.gd). A clump is a band of the picture about half a tile wide and tall, stood up on its
// southern edge: a pixel d tiles north of that edge rises d / cot(48 degrees), so from Factorio's camera
// the east-west card covers what the flat picture showed and from any lower angle the blades stand.
// The north-south card, edge-on from Factorio's angle, is the clump seen from the side.
// Cut out with alpha to coverage (smooth edges under MSAA, held still by TAA) and written to depth, so
// clumps hide each other in the right order. Further from the character fewer clumps stand (each its own
// threshold), the rest lie back onto the picture, and past the range they are gone: the flat picture
// under them is all there is. Wind bends the tops by a scrolling noise texture; normals bent up, so the
// blades light softly, like the ground they grow from; no shadows cast (decoratives.gd).
// INSTANCE_CUSTOM is the patch's (u start, u width, v height, 1 + its root): its variant is
// u start * `variants`. A clump's slot past the variant's last is empty and makes no triangle.
render_mode cull_disabled;

#include "res://shaders/ground_height.gdshaderinc"
#include "res://shaders/decorative_grass.gdshaderinc"
#include "res://shaders/decor_mask.gdshaderinc"

uniform sampler2D atlas : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
// Per variant (row) and clump (column): (u, v, width, height) of its piece of the picture, 0 to 1.
uniform sampler2D cells : filter_nearest, repeat_disable;
uniform float variants = 1.0;
// How much taller than Factorio's own picture implies the blades stand (1: exactly).
uniform float stretch = 1.1;
// Seamless noise (decoratives.gd): gusts drift over the meadow as it scrolls.
uniform sampler2D wind_noise : filter_linear, repeat_enable;

// cot(FACTORIO_PITCH 48 degrees), as decorative_grass.gdshader: height h shows h * this north.
const float RAY_SOUTH = 0.9;
// Of the range (f3d_grass.z): every clump stands inside DENSE, a third of them at the range's end.
const float DENSE = 0.45;
const float SPARSE = 0.35;
// Tiles a noise texel spans, and how fast the gusts travel (texture widths a second), and which way.
const float WIND_SCALE = 0.02;
const vec2 WIND_DRIFT = vec2(0.035, 0.02);
// How much of a blade's height the wind may push its top over.
const float WIND_BEND = 0.35;
// Tiles round a clump's piece that its blades may lean or bend over: a clump within this of concrete or
// a building (decor_mask.gdshaderinc) isn't stood up, so none pokes over the edge.
const float CLEAR = 0.25;

varying float rise;  // 0 at the root, 1 at the card's top
varying float fade;  // 1 standing, down to 0 as it lies back and goes
varying float level;  // as decorative_flat.gdshader: fades out on steep ground
varying vec4 region;  // the clump's piece of the atlas, so mipmaps don't pull in its neighbours
varying vec3 face;  // the card's normal, world space

float carpet_hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void vertex() {
	vec2 at = MODEL_MATRIX[3].xz;
	float grow = grass_grow(at);
	rise = 0.0;
	fade = 0.0;
	level = 1.0;
	region = vec4(0.0);
	face = vec3(0.0, 0.0, 1.0);
	int variant = clamp(int(INSTANCE_CUSTOM.x * variants + 0.5), 0, int(variants) - 1);
	vec4 cell = texelFetch(cells, ivec2(int(UV.x + 0.5), variant), 0);
	vec2 size = vec2(MODEL_MATRIX[0].x, MODEL_MATRIX[2].z);  // the picture in tiles
	vec2 root = vec2(cell.x + 0.5 * cell.z, cell.y + cell.w) - 0.5;  // in the picture, -0.5 to 0.5
	vec2 seed = at + root * size;
	// Distance-based density: further out fewer clumps stand, each dropping out at its own distance.
	float reach = distance(seed, f3d_grass.xy) / max(f3d_grass.z, 1.0);
	float keep = mix(1.0, SPARSE, smoothstep(DENSE, 1.0, reach));
	float r0 = carpet_hash(seed + 1.93);
	// The clump's piece of ground, with room to lean: its corners, each under a tile at most apart.
	vec2 half_w = vec2(0.5 * cell.z * size.x + CLEAR, 0.0);
	vec2 north = vec2(0.0, cell.w * size.y + CLEAR);
	vec2 south = vec2(0.0, CLEAR);
	bool blocked = grow > 0.0 && cell.z > 0.0 && (decor_blocked(seed)
		|| decor_blocked(seed - half_w + south) || decor_blocked(seed + half_w + south)
		|| decor_blocked(seed - half_w - north) || decor_blocked(seed + half_w - north));
	if (grow <= 0.0 || cell.z <= 0.0 || r0 > keep || blocked) {
		VERTEX = vec3(0.0);  // past the range, thinned out, an empty slot or by a building: nothing to rasterise
	} else {
		float s = VERTEX.x;  // across the card, 0 to 1
		float t = VERTEX.y;  // down the picture, 0 the cell's north edge, 1 its southern (the root)
		bool crossed = VERTEX.z > 0.5;
		float across = (s - 0.5) * cell.z * size.x;
		float d = (1.0 - t) * cell.w * size.y;  // tiles north of the root in the flat picture
		float r1 = carpet_hash(seed);
		float r2 = carpet_hash(seed + 7.31);
		float r3 = carpet_hash(seed + 3.17);
		// A clump about to drop out lies down first, so none pops.
		float g = grow * smoothstep(0.0, 0.08, keep - r0);
		float h = d / RAY_SOUTH * stretch * (0.75 + 0.5 * r1) * g;
		vec2 off = crossed ? vec2(0.0, across) : vec2(across, 0.0);
		off.y -= d * (1.0 - g);  // lying back onto its place in the picture
		off += (vec2(r2, r3) - 0.5) * 0.5 * h;  // each clump leans its own way a little
		if (f3d_grass_wind > 0.5) {
			// Gusts from the noise drifting over the meadow, mostly with the wind's way, a flutter on top.
			vec2 p = seed * WIND_SCALE + TIME * WIND_DRIFT;
			float gust = textureLod(wind_noise, p, 0.0).r;
			float cross_gust = textureLod(wind_noise, p * 1.7 + vec2(0.37, 0.71), 0.0).r - 0.5;
			vec2 way = normalize(WIND_DRIFT);
			vec2 push = way * gust + vec2(-way.y, way.x) * 0.8 * cross_gust;
			push += 0.15 * vec2(sin(TIME * 4.1 + r1 * 6.28), cos(TIME * 3.3 + r2 * 6.28));
			off += push * WIND_BEND * h * (1.0 - t);
		}
		VERTEX = vec3(root.x + off.x / size.x, h + 0.004, root.y + off.y / size.y);
		rise = 1.0 - t;
		fade = g;
		face = crossed ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 0.0, 1.0);
		float u = crossed ? 1.0 - s : s;
		vec2 q = vec2(cell.x + u * cell.z, cell.y + t * cell.w);
		UV = vec2(INSTANCE_CUSTOM.x + q.x * INSTANCE_CUSTOM.y, q.y * INSTANCE_CUSTOM.z);
		region = vec4(INSTANCE_CUSTOM.x + cell.x * INSTANCE_CUSTOM.y, cell.y * INSTANCE_CUSTOM.z,
			INSTANCE_CUSTOM.x + (cell.x + cell.z) * INSTANCE_CUSTOM.y, (cell.y + cell.w) * INSTANCE_CUSTOM.z);
		level = ground_n((MODEL_MATRIX * vec4(VERTEX, 1.0)).xz).y;
		VERTEX = ground_lift(VERTEX, MODEL_MATRIX);
	}
}

global uniform float f3d_look_ground_specular;  // looks.gd "ground_specular"

void fragment() {
	vec2 half_texel = 0.5 / vec2(textureSize(atlas, 0));
	vec4 c = texture(atlas, clamp(UV, region.xy + half_texel, region.zw - half_texel));
	// The pictures' baked shadows are pure black; they stay on the ground with the flat picture. The
	// plant itself is never that dark.
	float blade = c.a * smoothstep(0.002, 0.016, max(c.r, max(c.g, c.b)));
	// Darker at the root, a little lighter at the tips: the height reads from any angle.
	ALBEDO = c.rgb * mix(0.65, 1.12, clamp(rise, 0.0, 1.0));
	SPECULAR = 0.5 * f3d_look_ground_specular;
	ROUGHNESS = 0.9;
	// Bent up: lit nearly as the ground is, with a little of the card's own facing, on either side.
	vec3 n = face * (FRONT_FACING ? 1.0 : -1.0);
	NORMAL = normalize((VIEW_MATRIX * vec4(normalize(mix(n, vec3(0.0, 1.0, 0.0), 0.8)), 0.0)).xyz);
	// Lying back or on steep ground the blades thin out under the cut, rather than fading.
	ALPHA = blade * smoothstep(0.0, 0.5, fade) * smoothstep(0.75, 0.9, level);
	ALPHA_SCISSOR_THRESHOLD = 0.35;
	// Alpha to coverage with MSAA: thin blades' edges spread over the pixel's samples instead of
	// switching on or off, so they shimmer less as the camera moves.
	ALPHA_ANTIALIASING_EDGE = 0.35;
	ALPHA_TEXTURE_COORDINATE = UV * vec2(textureSize(atlas, 0));
}
