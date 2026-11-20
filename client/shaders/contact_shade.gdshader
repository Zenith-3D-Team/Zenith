shader_type spatial;
// The dark rim on the ground round a building's foot (scripts/world/contact_shade.gd): Factorio's
// sprites have one painted in under every machine, near-black and speckled at the edge, about 45-50%
// dark there, 20% 0.05 tiles out, 10% at 0.1, gone by 0.15-0.25 (measured at 64 px a tile); big
// machines (drills, labs, radars, centrifuges) also sit in a faint patch, on their own tiles. The sun's shadow alone
// left Zenith's buildings standing on the ground rather than in it.
//
// One ring per building, a MultiMesh per chunk: the ring's corners are placed here round the
// building's ground-contact rectangle (INSTANCE_CUSTOM: half width x, half depth z, its corners'
// radius, the patch's strength; a round foot has round corners), the rim's strength per side in the
// instance colour (east, west, south, north; COLOR in vertex()): contact_shade.gd halves a side that
// faces a neighbour close by, so two rims meeting in a narrow gap darken it about as much as one would
// instead of stacking towards black. Multiplied over what is drawn there (in linear light: the
// profile's on-screen darkness converted, below); no light, depth or shadows of its own. Lifted by
// the hills.
render_mode unshaded, blend_mul, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

#include "res://shaders/ground_height.gdshaderinc"

// The rim: darkness at the contact edge, its falloff (tiles) and where it has gone.
uniform float rim_dark = 0.47;
uniform float rim_falloff = 0.06;
uniform float rim_end = 0.25;
// How far the rim reaches under the building's edge (its lowest vertices' box is the edge).
uniform float inset = 0.05;
// Under the foot the rim and patch fade out over this much (tiles) and are gone before the ring's hole.
// The band between the hole and the foot's box used to be drawn at full darkness, cut off hard at the hole
// (0.38 tiles deep on Wube3DP's drill, whose round foot's corners are 1.1 tiles). That is hidden under a
// solid base, but where the body doesn't fill its feet's box (between a drill's rear legs, a side with only a
// pipe stub reaching out to its edge) it lay on the bare ground as a dark band with a sharp inner edge
// (owner: "a dark rectangular band ... past the body, over the ore"). contact_shade.gd sets it (INNER_FADE);
// 0 under --contact-inner=hard: as before.
uniform float inner_fade = 0.05;
// The speckle: cells a tile, and how much it varies the rim near the edge.
uniform float speckle_cells = 22.0;
uniform float speckle = 0.45;
// The rim is drawn while a pixel covers less than fade_from tiles, gone past fade_to (the patch,
// wider, lasts twice as far): far off it would be under a pixel and shimmer. contact_shade.gd sets
// them from ao_zoom.gd (RIM_FULL, RIM_GONE), where every ambient occlusion fade's thresholds are.
uniform float fade_from = 0.07;
uniform float fade_to = 0.16;
// The patch's reach past the edge (tiles), and how far out the ring goes with and without a patch
// (contact_shade.gd sets them: PATCH_EDGE, REACH, patch_ring_reach(); 0.5 and 0.55 under
// --contact-patch=wide, which drew a dark band round every drill).
uniform float patch_reach = 0.1;
uniform float ring_reach = 0.27;
uniform float ring_patch_reach = 0.27;
// The profile above is on-screen (sRGB) darkness; the multiply is in linear light: this turns one
// into the other (fragment()).
uniform float profile_gamma = 2.2;
// How high over the ground it lies (no fighting with the terrain).
uniform float lift = 0.015;
// A model's own contact map instead of a ring (contact_shade.gd mask_of(): INSTANCE_CUSTOM.x is -1 - its slot): the
// distance to where the model meets the ground, 0 to mask_range tiles, in an atlas of mask_cell-texel masks,
// mask_cols a row, drawn on a quad over the contact plus mask_margin. The same profile is drawn from that distance.
uniform sampler2D mask_atlas : filter_linear, repeat_disable, hint_default_white;
uniform float mask_cell = 64.0;
uniform float mask_cols = 16.0;
uniform float mask_range = 0.4;
uniform float mask_margin = 0.3;

varying vec2 local;      // from the rectangle's middle, world-aligned (tiles)
varying vec2 world_xz;
varying flat vec2 half_size;
varying flat float patch;
varying flat float corner;
varying flat vec4 sides;
varying flat float fade_in;
varying flat float mask_slot;  // -1: a ring
varying vec2 mask_uv;

void vertex() {
	if (INSTANCE_CUSTOM.x < -0.5) {
		// A mask: the quad's -1..1 is the mask's whole square (its instance transform places, turns and mirrors it).
		mask_slot = floor(-INSTANCE_CUSTOM.x - 1.0 + 0.5);
		mask_uv = VERTEX.xz * 0.5 + 0.5;
		vec3 mv = vec3(VERTEX.x, lift, VERTEX.z);
		world_xz = (MODEL_MATRIX * vec4(mv, 1.0)).xz;
		local = world_xz - MODEL_MATRIX[3].xz;
		// The contact's world-aligned half size (side halving): the quad's, less the margin.
		vec2 hw = vec2(abs(MODEL_MATRIX[0].x) + abs(MODEL_MATRIX[2].x), abs(MODEL_MATRIX[0].z) + abs(MODEL_MATRIX[2].z));
		half_size = max(hw - vec2(mask_margin), vec2(0.02));
		patch = INSTANCE_CUSTOM.w;
		corner = 0.0;
		sides = COLOR;
		fade_in = 0.0;
		VERTEX = ground_lift(mv, MODEL_MATRIX);
	} else {
		mask_slot = -1.0;
		mask_uv = vec2(0.0);
		vec2 h = max(INSTANCE_CUSTOM.xy, vec2(0.02));
		float reach = INSTANCE_CUSTOM.w > 0.0 ? ring_patch_reach : ring_reach;
		float r = clamp(INSTANCE_CUSTOM.z, 0.0, min(h.x, h.y));
		// The inner edge stays inside the rounded foot, round corners and all (1 - 1/sqrt(2) of the radius).
		vec2 in_h = max(h - vec2(inset + r * 0.2929), h * 0.3);
		// No wider than the band down to the hole, so the fade always ends before it.
		fade_in = min(inner_fade, min(h.x - in_h.x, h.y - in_h.y));
		// VERTEX.xz: where along the inner ring (-1 to 1); UV: -1 or 1 on the outer ring's columns and
		// rows, 0 elsewhere (contact_shade.gd ring_mesh()).
		vec2 p = VERTEX.xz * in_h;
		p = mix(p, sign(UV) * (h + vec2(reach)), abs(UV));
		local = p;
		half_size = h;
		patch = INSTANCE_CUSTOM.w;
		corner = r;
		sides = COLOR;  // the instance colour (the ring has no vertex colours)
		vec3 v = vec3(p.x, lift, p.y);
		world_xz = (MODEL_MATRIX * vec4(v, 1.0)).xz;
		VERTEX = ground_lift(v, MODEL_MATRIX);
	}
}

float speckle_hash(vec2 c) {
	return fract(sin(dot(c, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	// Distance outside the rounded rectangle (negative under the building).
	vec2 q = abs(local) - (half_size - vec2(corner));
	float d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - corner;
	// A mask's patch reaches as far past its contact as a ring's past its foot, with it at full strength on it.
	float patch_d = d;
	if (mask_slot >= 0.0) {
		vec2 cell = vec2(mod(mask_slot, mask_cols), floor(mask_slot / mask_cols));
		vec2 at = cell * mask_cell + clamp(mask_uv * mask_cell, vec2(0.5), vec2(mask_cell - 0.5));
		d = texture(mask_atlas, at / vec2(textureSize(mask_atlas, 0))).r * mask_range;
		patch_d = d - 0.05;
	}
	// Which side's strength: the x sides near the x edges, the z sides near the z edges.
	float sx = local.x > 0.0 ? sides.r : sides.g;
	float sz = local.y > 0.0 ? sides.b : sides.a;
	float s = mix(sz, sx, clamp(0.5 + (q.x - q.y) * 6.0, 0.0, 1.0));
	// A pixel's size on the ground: the falloff never sharper than about a pixel (its darkness spread,
	// not lost), and it fades out where it would be under one.
	vec2 wx = dFdx(world_xz);
	vec2 wy = dFdy(world_xz);
	float px = max(length(wx), length(wy));
	float k = max(rim_falloff, px * 0.7);
	float dd = max(d, 0.0);
	float rim = rim_dark * (rim_falloff / k) * exp(-dd / k) * (1.0 - smoothstep(rim_end * 0.6, rim_end, dd));
	// Near-black speckle at the edge, fixed to the world, faded once a cell is under a pixel.
	float cell = speckle_hash(floor(world_xz * speckle_cells));
	float sp = 1.0 + speckle * (cell * 2.0 - 1.0) * (1.0 - smoothstep(0.5, 1.0, px * speckle_cells))
		* (1.0 - smoothstep(0.0, 0.08, dd));
	rim = clamp(rim * sp, 0.0, 0.85) * s * (1.0 - smoothstep(fade_from, fade_to, px));
	// The big machines' patch: a faint darkening under them, fading out just past their foot.
	float pa = patch * (1.0 - smoothstep(-0.05, patch_reach, patch_d)) * (1.0 - smoothstep(fade_from * 2.0, fade_to * 2.0, px));
	// Under the foot: faded out before the hole (inner_fade), no hard inner edge where the ground shows.
	float inner = fade_in > 0.0 ? smoothstep(-fade_in, 0.0, d) : 1.0;
	float dark = 1.0 - (1.0 - rim * inner) * (1.0 - pa * inner);
	// The profile is how dark Factorio's sprites are there, on screen (sRGB); this multiplies the scene's
	// linear light before the tone mapping, so it is turned into linear here. Used as it was, a 47% rim
	// showed as about 25% and a belt's band as about 15%, which no one could see.
	ALBEDO = vec3(pow(1.0 - dark, profile_gamma));
}
