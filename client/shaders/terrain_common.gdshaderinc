// Land tiles and the banks down to the water: everything terrain.gdshader (interior ground) and
// terrain_shore.gdshader (the coast) share. terrain_shore.gdshader defines TERRAIN_SHORE before including this.
//
// With a Factorio install (`textured`): each tile shows its variant of Factorio's own tile picture
// (a layer of `tiles`, slot in UV; see terrain_textures.gd), and up to two higher neighbouring
// tile types spread over its edges with a ragged, noisy mask, like Factorio's transitions. CUSTOM0
// = (own layer or -1, lower spreading layer, upper spreading layer, mask A + 256 * mask B), the
// masks being which of the 8 neighbours carry that type (bits: E W S N SE SW NE NW). CUSTOM1.x is
// the same kind of mask for water neighbours (a wet rim along the bank), CUSTOM1.z 1 on a player's
// floor (smoother than natural ground). COLOR tints the texture.
//
// Without (or for a tile with no picture): the tile's map colour (COLOR) broken up by
// world-space noise, so any tile type gets detail without a texture.
//
// Why two shaders: the coast is cut back with `discard` (a wet rim, the shelf under the land, the shelf
// over the water). A shader that can discard cannot use hardware early depth, and its depth pre-pass has
// to run the whole fragment shader to know what is cut. About 98% of the ground never touches the coast, so
// terrain_mesher.gd puts the coast's quads in a surface of their own (TerrainMesher.shore, drawn with
// terrain_shore.gdshader) and everything else here has no `discard` at all. --terrain-opt=old: one
// surface and the single terrain_old.gdshader (with the original value noise) for all of it.
//
// The noise is worked out where it is used and no earlier: a textured tile's albedo needs one octave, its
// bump one gradient (the two a bare tile's grit needs are only worked out there), a transition's ragged edge
// two octaves. (Measured: reading it from a noise texture instead cost more than the arithmetic.)

#include "res://shaders/noise.gdshaderinc"
#include "res://shaders/ground_height.gdshaderinc"
#include "res://shaders/lamp_light.gdshaderinc"
#include "res://shaders/decor_mask.gdshaderinc"
#include "res://shaders/decorative_grass.gdshaderinc"
#include "res://shaders/weather_surface.gdshaderinc"

uniform float detail = 1.0;
uniform float bump = 1.0;
// How dark the joins between tiles are. Kept faint: Factorio's ground has no visible grid, but a
// hint of one helps read distances in 3D. Not drawn on textured ground, whose variants show it.
uniform float tile_edge = 0.04;
// How much of SSAO darkens the ground's direct (sun) light (Godot's AO_LIGHT_AFFECT; SSAO always
// darkens its ambient light). The ground's own occlusion is only its picture's crevices (`crevice`).
uniform float ssao_on_sunlight = 0.85;

// The look's share of the ground's specular (looks.gd "ground_specular"): the sky's reflection on
// the ground is what washed its colours out, so the Factorio look leaves it out.
global uniform float f3d_look_ground_specular;
// The look's share of SSAO and the ground's crevices on its sunlight (looks.gd "ao_direct"; 1: ssao_on_sunlight).
global uniform float f3d_look_ao_direct;
uniform bool textured = false;
// The chunk's baked flat decoratives (decoratives.gd, decor_sheet_baker.gd) drawn into the ground itself
// instead of a blended sheet over it: a surface of the chunk's own material (chunk_view.gd
// set_decor_sheet). The sheet is the chunk's 32 x 32 tiles, straight alpha, sRGB colour; it is skipped
// where `has_decor_sheet` is off (no sheet, out of Decoratives' range, behind the camera) or the
// `f3d_decor_composite_on` global is 0 (Settings > Decoratives off). --decor-composite=off: sheets over the
// ground, as before.
global uniform float f3d_decor_composite_on;
uniform bool has_decor_sheet = false;
uniform sampler2D decor_sheet : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec2 decor_chunk_origin = vec2(0.0);  // the chunk's north-west corner, world tiles
uniform float decor_raised_shade = 0.0;  // how much darker the pictures lie under their raised 3D grass
uniform sampler2DArray tiles : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
// Per layer: first slot row, variant width and height in tiles, variant count.
uniform vec4 tile_info[96];  // terrain_textures.gd MAX_LAYERS
// Companion linear PBR maps packed per active PBR tile: RG = XY normal, B = roughness, A = height.
uniform bool has_tile_pbr = false;
uniform sampler2DArray tiles_pbr : filter_linear_mipmap_anisotropic, repeat_disable;
// Per albedo layer: (pbr_layer or -1, flags: 1=normal 2=height 4=roughness, normal_strength, height_strength)
uniform vec4 tile_pbr[96];
uniform float pbr_normal_scale = 0.75;
uniform float pbr_parallax = 0.025;
// Factorio shows its tile pictures unlit; under this scene's sun and sky they come out brighter,
// so they are toned down to match (the models' sprites use the same 0.8).
uniform float texture_gain = 0.8;
// How far (in tiles) a higher tile's edge reaches into its neighbour, and how soft it is.
uniform float reach = 0.4;
uniform float softness = 0.07;
uniform float raggedness = 1.0;
// The shore (textured only): how far the coast strays from the tile edge, and the width of the
// wet rim between the ground and the water.
uniform float coast_wander = 0.55;
uniform float rim = 0.14;

// How rough the ground is: natural ground fully matte, so the sky and a low sun don't glaze it
// (owner's I8), a player's floor (concrete, paths) a little smoother, with some sheen.
uniform float ground_roughness = 1.0;
uniform float floor_roughness = 0.8;
uniform float ground_specular = 0.15;
uniform float floor_specular = 0.3;
// Each tile's own roughness and specular by family (terrain_textures.gd SURFACES, CUSTOM1.w); off
// (--ground-rough=off) the two values above. surface_roughness_add shifts every tile's roughness (the
// debug menu's Lighting slider "Ground roughness").
uniform bool per_tile_surface = true;
uniform float surface_roughness_add = 0.0;
// The tile picture's brightness as height (tiles per unit of linear luminance): its stones and
// clods tilt the normal. Floors get floor_relief of it (concrete's joints and pits, not rubble).
uniform float relief_height = 0.03;
uniform float floor_relief = 0.4;
// Micro-shadowing: how much darker a pixel in the picture's crevices gets, sky light and (through
// AO_LIGHT_AFFECT) sunlight both. Godot takes the darker of this and SSAO, so round buildings,
// where SSAO is darker, nothing changes.
uniform float crevice = 0.3;
// The relief and crevices at all (visuals.gd set_ground_relief: off at Level of detail Low), and
// whether they stop where the mipmaps have already blurred them away (RELIEF_SHARP, RELIEF_GONE).
uniform bool ground_relief = true;
uniform bool relief_fades = true;

const vec2 SLOT = vec2(1.0 / 32.0, 1.0 / 16.0);
// One texel of a tile picture, in tiles (terrain_textures.gd: 64 pixels a tile).
const float RELIEF_TEXEL = 1.0 / 64.0;
// The picture's texels a pixel covers (along its finer direction) where the relief starts to fade and
// where it is gone. Its slope is two neighbouring texels' difference: once a pixel spans a few texels
// the mip it reads has averaged them, so the slope and the crevices are nearly flat anyway, and the
// three extra reads (paid again in the depth pre-pass with SSAO) are skipped there. Faded, not cut, so
// no line shows across the ground where they stop.
const float RELIEF_SHARP = 1.5;
const float RELIEF_GONE = 3.0;

float luma(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

varying vec3 world_pos;
varying vec3 world_normal;
varying flat vec4 layers;
varying flat vec4 masks;
varying flat vec2 tile_origin;
// The hills' slope here (ground_height.gdshaderinc), world space; straight up on flat ground.
varying vec3 hill_normal;
// How near a cliff the ground is, 0-1 (ground_height.gdshaderinc's third channel, from an add-on such as
// Terrain Elevation), times |f3d_cliff_tint|: bare rock and dirt there (--cliff-ground-tint=off: 0; negative,
// --cliff-scree-look=old: the even band, not ragged).
varying float cliff_near;
global uniform float f3d_cliff_tint;
// Factorio's cliffs' lower layer (the scree at their foot): its mean colour #61492f, linear.
const vec3 CLIFF_SCREE = vec3(0.120, 0.0666, 0.0284);

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	layers = CUSTOM0;
	masks = CUSTOM1;
	tile_origin = UV2;
	// Hills: the vertex lifted by the ground under it. world_pos stays flat, so the tile pictures,
	// noise and banks are worked out as before.
	hill_normal = ground_n(world_pos.xz);
	VERTEX = ground_lift(VERTEX, MODEL_MATRIX);
	cliff_near = f3d_cliff_tint != 0.0 && f3d_ground_on > 0.5 ? ground_cliff_near(world_pos.xz) * abs(f3d_cliff_tint) : 0.0;
}

// Distance from `f` (position in the tile) to the nearest neighbour named in `mask`.
float mask_distance(int mask, vec2 f) {
	float d = 9.0;
	if ((mask & 1) != 0) d = min(d, 1.0 - f.x);
	if ((mask & 2) != 0) d = min(d, f.x);
	if ((mask & 4) != 0) d = min(d, 1.0 - f.y);
	if ((mask & 8) != 0) d = min(d, f.y);
	if ((mask & 16) != 0) d = min(d, length(1.0 - f));
	if ((mask & 32) != 0) d = min(d, length(vec2(f.x, 1.0 - f.y)));
	if ((mask & 64) != 0) d = min(d, length(vec2(1.0 - f.x, f.y)));
	if ((mask & 128) != 0) d = min(d, length(f));
	return d;
}

// How much of a higher neighbour shows d tiles from it, with the ragged offset n. Always all
// of it at the shared edge and none a tile away, so it joins up with the tiles on either side.
float spread_weight(float d, float n) {
	float wgt = 1.0 - smoothstep(reach - softness, reach + softness, d + n);
	wgt = max(wgt, 1.0 - smoothstep(0.0, 0.08, d));
	return wgt * (1.0 - smoothstep(0.85, 0.98, d));
}

// A layer's texture at a world position, for where it spreads beyond its own tiles: the variant
// for each block of the world from a hash, so it doesn't repeat every few tiles.
vec3 layer_color(int layer, vec2 w, vec2 dx, vec2 dy) {
	vec4 info = tile_info[layer];
	vec2 size = max(info.yz, vec2(1.0));
	vec2 block = floor(w / size);
	float v = floor(hash12(block + float(layer) * 37.0) * max(info.w, 1.0));
	float per_row = floor(32.0 / size.x);
	vec2 slot = vec2(mod(v, per_row) * size.x, info.x + floor(v / per_row) * size.y);
	vec2 uv = (slot + (w - block * size)) * SLOT;
	return textureGrad(tiles, vec3(uv, float(layer)), dx * SLOT, dy * SLOT).rgb;
}


vec4 layer_pbr(int layer, int pbr_idx, vec2 w, vec2 dx, vec2 dy) {
	vec4 info = tile_info[layer];
	vec2 size = max(info.yz, vec2(1.0));
	vec2 block = floor(w / size);
	float v = floor(hash12(block + float(layer) * 37.0) * max(info.w, 1.0));
	float per_row = floor(32.0 / size.x);
	vec2 slot = vec2(mod(v, per_row) * size.x, info.x + floor(v / per_row) * size.y);
	vec2 uv = (slot + (w - block * size)) * SLOT;
	return textureGrad(tiles_pbr, vec3(uv, float(pbr_idx)), dx * SLOT, dy * SLOT);
}

#ifdef TERRAIN_SHORE
// Where the coast runs, as an offset from the tiles' land/water edge (see the fragment).
float coast(vec2 w) {
	return coast_wander * (2.0 * fbm3(w * 0.45 + 11.3) - 1.0) + 0.1 * (vnoise(w * 3.1 + 2.9) - 0.5);
}

// Polynomial smooth minimum: rounds the corners where two edges' distances meet.
float smin(float a, float b, float k) {
	float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
	return mix(b, a, h) - k * h * (1.0 - h);
}

// Like mask_distance, but with rounded corners: for the outline of a shore.
float smooth_distance(int mask, vec2 f) {
	float d = 9.0;
	float k = 0.45;
	if ((mask & 1) != 0) d = smin(d, 1.0 - f.x, k);
	if ((mask & 2) != 0) d = smin(d, f.x, k);
	if ((mask & 4) != 0) d = smin(d, 1.0 - f.y, k);
	if ((mask & 8) != 0) d = smin(d, f.y, k);
	// A corner next to a side that is already in counts for nothing more, and would only dent the
	// outline at every tile corner through smin.
	if ((mask & 16) != 0 && (mask & 5) == 0) d = smin(d, length(1.0 - f), k);
	if ((mask & 32) != 0 && (mask & 6) == 0) d = smin(d, length(vec2(f.x, 1.0 - f.y)), k);
	if ((mask & 64) != 0 && (mask & 9) == 0) d = smin(d, length(vec2(1.0 - f.x, f.y)), k);
	if ((mask & 128) != 0 && (mask & 10) == 0) d = smin(d, length(f), k);
	return d;
}
#endif

void fragment() {
	// Banks are vertical, so height goes into the noise coordinates or the noise would streak.
	vec2 p = world_pos.xz + world_pos.y * vec2(1.7, -1.3);
	float top = step(0.5, world_normal.y);
	vec2 w = world_pos.xz;
	vec2 dx = dFdx(w);
	vec2 dy = dFdy(w);
	// Position within the tile, from the tile's own corner: fract(w) would put a column of pixels
	// on each tile edge into the neighbouring tile and draw a line there.
	vec2 f = clamp(w - tile_origin, 0.0, 1.0);
	vec2 wt = tile_origin + clamp(f, 0.001, 0.999);
	// Where the chunk's decorative sheet is read: PlaneMesh's UV, (world - chunk corner) / 32, derivatives
	// taken here where the control flow is uniform.
	vec2 sheet_uv = (w - decor_chunk_origin) / 32.0;
	vec2 sheet_dx = dFdx(sheet_uv);
	vec2 sheet_dy = dFdy(sheet_uv);

	int own = int(round(layers.x));
#ifdef TERRAIN_SHORE
	int kind = int(round(masks.y));  // 0 ground or bank, 1 shelf under ground, 2 shelf over water
	bool shore = textured && top > 0.5 && kind > 0;
#endif
	// A player's floor (concrete, stone path, refined concrete, platform foundations: terrain_mesher.gd
	// FLOOR), which stays smoother and shinier than natural ground.
	float is_floor = step(0.5, masks.z);
	vec2 duv_x = dFdx(UV);
	vec2 duv_y = dFdy(UV);
	vec3 albedo;
	float bump_scale = bump;
	// The tile picture's own relief (luminance per tile, east and south) and how deep in a crevice of
	// it this pixel is (0 to 1): see below.
	vec2 relief = vec2(0.0);
	vec2 pbr_grad = vec2(0.0);
	float pbr_rough = -1.0;
	float pbr_rough_w = 0.0;
	float cavity = 0.0;
	// The noise's tilt of the normal (the picture's relief is added to it at the end).
	vec2 noise_grad = vec2(0.0);
	if (textured && own >= 0) {
#ifdef TERRAIN_SHORE
		if (kind == 2) {
			albedo = layer_color(own, wt, dx, dy) * texture_gain;
		} else
#endif
		{
			// Kept half a texel inside the tile's slot, so filtering doesn't reach the next one.
			vec2 uv = top > 0.5 ? UV + (clamp(f, 0.5 / 64.0, 1.0 - 0.5 / 64.0) - f) * SLOT : UV;
			float sharp = 1.0;
			if (relief_fades) {
				sharp = 1.0 - smoothstep(RELIEF_SHARP, RELIEF_GONE, min(length(dx), length(dy)) / RELIEF_TEXEL);
			}
			vec4 pm = (has_tile_pbr && top > 0.5) ? tile_pbr[own] : vec4(-1.0);
			int pbr_idx = int(round(pm.x));
			int pbr_flags = int(round(pm.y));
			if (pbr_idx >= 0 && (pbr_flags & 2) != 0 && ground_relief && sharp > 0.0) {
				float h0 = textureGrad(tiles_pbr, vec3(uv, float(pbr_idx)), duv_x, duv_y).a;
				vec3 vdir = normalize(INV_VIEW_MATRIX[3].xyz - world_pos);
				vec2 shift = clamp(vdir.xz / max(vdir.y, 0.35), vec2(-1.5), vec2(1.5)) * (h0 - 0.5) * pbr_parallax * pm.w * sharp;
				vec2 f_pom = clamp(f + shift, 0.5 / 64.0, 1.0 - 0.5 / 64.0);
				uv = UV + (f_pom - f) * SLOT;
			}
			vec3 c0 = textureGrad(tiles, vec3(uv, float(own)), duv_x, duv_y).rgb;
			albedo = c0 * texture_gain;
			if (pbr_idx >= 0) {
				vec4 ps = textureGrad(tiles_pbr, vec3(uv, float(pbr_idx)), duv_x, duv_y);
				if ((pbr_flags & 1) != 0) {
					vec2 nxy = ps.rg * 2.0 - 1.0;
					float nz = sqrt(max(1.0 - dot(nxy, nxy), 0.04));
					pbr_grad = vec2(-nxy.x, nxy.y) / nz * pbr_normal_scale * pm.z * sharp;
				}
				if ((pbr_flags & 2) != 0 && ground_relief && sharp > 0.0) {
					if ((pbr_flags & 1) == 0) {
						vec2 sgn = vec2(f.x < 0.5 ? 1.0 : -1.0, f.y < 0.5 ? 1.0 : -1.0);
						vec2 step_uv = sgn * RELIEF_TEXEL * SLOT;
						float hx = textureGrad(tiles_pbr, vec3(uv + vec2(step_uv.x, 0.0), float(pbr_idx)), duv_x, duv_y).a;
						float hy = textureGrad(tiles_pbr, vec3(uv + vec2(0.0, step_uv.y), float(pbr_idx)), duv_x, duv_y).a;
						relief = sharp * sgn * vec2(hx - ps.a, hy - ps.a) / RELIEF_TEXEL * pm.w;
					}
					float h_around = textureGrad(tiles_pbr, vec3(uv, float(pbr_idx)), duv_x * 8.0, duv_y * 8.0).a;
					cavity = sharp * smoothstep(0.01, 0.14, (h_around - ps.a) * pm.w);
				}
				if ((pbr_flags & 4) != 0) {
					pbr_rough = ps.b;
					pbr_rough_w = 1.0;
				}
			} else if (top > 0.5 && ground_relief && (relief_height > 0.0 || crevice > 0.0) && sharp > 0.0) {
				// Micro detail from the picture itself, no textures of our own (owner's I8: the ground
				// looked too shiny and flat): its brightness taken as height, light stones raised and
				// dark gaps sunk, as Factorio paints them. One texel east and south (inwards, so the
				// samples stay in the tile's slot) give the slope; mipmapping blurs it away as the
				// view zooms out, so it fades by itself and never shimmers (and past RELIEF_GONE isn't
				// read). Three mips up is the neighbourhood's average brightness: a pixel darker than
				// that lies in a crevice.
				vec2 sgn = vec2(f.x < 0.5 ? 1.0 : -1.0, f.y < 0.5 ? 1.0 : -1.0);
				vec2 step_uv = sgn * RELIEF_TEXEL * SLOT;
				float l0 = luma(c0);
				float lx = luma(textureGrad(tiles, vec3(uv + vec2(step_uv.x, 0.0), float(own)), duv_x, duv_y).rgb);
				float ly = luma(textureGrad(tiles, vec3(uv + vec2(0.0, step_uv.y), float(own)), duv_x, duv_y).rgb);
				relief = sharp * sgn * vec2(lx - l0, ly - l0) / RELIEF_TEXEL;
				float around = luma(textureGrad(tiles, vec3(uv, float(own)), duv_x * 8.0, duv_y * 8.0).rgb);
				cavity = sharp * smoothstep(0.01, 0.12, around - l0);
			}
		}
		// A whisper of broad variation keeps large fields from looking printed (patches a few tiles across).
		albedo *= 1.0 + detail * 0.12 * (vnoise(p * 0.06) - 0.5);
		bump_scale *= 0.35 * mix(1.0, 0.5, is_floor);
		if (top > 0.5 && bump_scale > 0.001) {
			// Height = 0.065 * noise, one octave where a bare tile's has two: its gradient tilts the normal
			// (chain rule: the noise is sampled at p * 1.3, so its gradient scales too).
			noise_grad = bump_scale * noised(p * 1.3).yz * (1.3 * 0.065);
		}
	} else {
		float broad = fbm3(p * 0.06);  // patches a few tiles across
		vec3 mid = noised(p * 0.9);
		vec3 fine = noised(p * 4.3 + 31.7);
		// Height = 0.06 * mid + 0.015 * fine; the gradient tilts the normal. Chain rule: the
		// noise is sampled at p * scale, so its gradient scales too.
		noise_grad = bump_scale * (mid.yz * 0.9 * 0.06 + fine.yz * 4.3 * 0.015);
		// Grit: small dark and light specks where the finest noise is at its extremes.
		float grit = vnoise(p * 11.0 + 5.1);
		float shade = 1.0 + detail * (0.36 * (broad - 0.5) + 0.16 * (mid.x - 0.5) + 0.12 * (fine.x - 0.5)
			+ 0.10 * (smoothstep(0.7, 0.95, grit) - 1.0 + smoothstep(0.05, 0.3, grit)));
		// A slight warm/cool drift over large areas, like dry and damp ground.
		vec3 tint = mix(vec3(0.95, 1.0, 1.06), vec3(1.06, 1.0, 0.92), vnoise(p * 0.018 + 7.3));
		tint = mix(vec3(1.0), tint, detail);
		if (!textured) {
			vec2 e = abs(fract(world_pos.xz) - 0.5);
			shade *= 1.0 - tile_edge * top * smoothstep(0.43, 0.5, max(e.x, e.y));
		}
		albedo = vec3(shade) * tint;
	}
	albedo *= COLOR.rgb;

	float roughness = 0.95;
#ifdef TERRAIN_SHORE
	// The coast (textured only): a line wandering up to `coast_wander` tiles either side of the
	// tiles' land/water edge, so it doesn't follow the grid. `t` is the signed distance across
	// that edge, negative on the land side; the coast is where t = c. The ground stops `rim`
	// short of it, a wet shelf just above the water fills the rim, and water (also drawn under
	// the land tiles along the shore) the rest.
	if (shore) {
		float c = coast(w);
		float d = smooth_distance(int(round(masks.x)), f);
		float t = kind == 2 ? d : -d;
		if (t > c) discard;
		float wet = smoothstep(c - rim, c, t);
		albedo *= mix(vec3(0.68, 0.66, 0.62), vec3(0.45, 0.47, 0.47), wet);
		roughness = mix(0.75, 0.4, wet);
	} else if (textured && top > 0.5) {
#else
	if (textured && top > 0.5) {
#endif
#ifdef TERRAIN_SHORE
		// The ragged line Factorio's transition masks draw: blotches about a tile across with
		// a finer fringe.
		int wet_mask = int(round(masks.x));
		if (wet_mask != 0) {
			float c = coast(w);
			float t = -smooth_distance(wet_mask, f);
			if (t > c - rim) discard;
			// Damp ground along the edge.
			albedo *= 1.0 - 0.25 * (1.0 - smoothstep(0.0, 0.3, c - rim - t));
		}
#endif
		int packed = int(round(layers.w));
		int mask_a = packed & 255;
		int mask_b = (packed >> 8) & 255;
		int la = int(round(layers.y));
		int lb = int(round(layers.z));
		float n = 0.0;
		if (packed != 0) {
			// Two octaves (not fbm3's three and a fringe) about as wide, centred on 0.
			n = raggedness * (0.65 * vnoise(w * 1.5 + 3.7) + 0.35 * vnoise(w * 4.2 + 9.2) - 0.5);
		}
		// The own picture's relief and crevices fade where a neighbour's picture covers it.
		float own_share = 1.0;
		float edge_sharp = relief_fades ? (1.0 - smoothstep(RELIEF_SHARP, RELIEF_GONE, min(length(dx), length(dy)) / RELIEF_TEXEL)) : 1.0;
		if (la >= 0 && mask_a != 0) {
			float wa = spread_weight(mask_distance(mask_a, f), n);
			if (wa > 0.0) {
				albedo = mix(albedo, layer_color(la, wt, dx, dy) * texture_gain, wa);
				if (has_tile_pbr) {
					vec4 pma = tile_pbr[la];
					int pia = int(round(pma.x));
					int pfa = int(round(pma.y));
					if (pia >= 0) {
						vec4 psa = layer_pbr(la, pia, wt, dx, dy);
						if ((pfa & 1) != 0) {
							vec2 nxya = psa.rg * 2.0 - 1.0;
							float nza = sqrt(max(1.0 - dot(nxya, nxya), 0.04));
							pbr_grad = mix(pbr_grad, vec2(-nxya.x, nxya.y) / nza * pbr_normal_scale * pma.z * edge_sharp, wa);
						} else {
							pbr_grad *= 1.0 - wa;
						}
						if ((pfa & 4) != 0) {
							pbr_rough = mix(pbr_rough < 0.0 ? psa.b : pbr_rough, psa.b, wa);
							pbr_rough_w = mix(pbr_rough_w, 1.0, wa);
						} else {
							pbr_rough_w *= 1.0 - wa;
						}
					} else {
						pbr_grad *= 1.0 - wa;
						pbr_rough_w *= 1.0 - wa;
					}
				}
			}
			own_share -= wa * own_share;
		}
		if (lb >= 0 && mask_b != 0) {
			float wb = spread_weight(mask_distance(mask_b, f), n);
			if (wb > 0.0) {
				albedo = mix(albedo, layer_color(lb, wt, dx, dy) * texture_gain, wb);
				if (has_tile_pbr) {
					vec4 pmb = tile_pbr[lb];
					int pib = int(round(pmb.x));
					int pfb = int(round(pmb.y));
					if (pib >= 0) {
						vec4 psb = layer_pbr(lb, pib, wt, dx, dy);
						if ((pfb & 1) != 0) {
							vec2 nxyb = psb.rg * 2.0 - 1.0;
							float nzb = sqrt(max(1.0 - dot(nxyb, nxyb), 0.04));
							pbr_grad = mix(pbr_grad, vec2(-nxyb.x, nxyb.y) / nzb * pbr_normal_scale * pmb.z * edge_sharp, wb);
						} else {
							pbr_grad *= 1.0 - wb;
						}
						if ((pfb & 4) != 0) {
							pbr_rough = mix(pbr_rough < 0.0 ? psb.b : pbr_rough, psb.b, wb);
							pbr_rough_w = mix(pbr_rough_w, 1.0, wb);
						} else {
							pbr_rough_w *= 1.0 - wb;
						}
					} else {
						pbr_grad *= 1.0 - wb;
						pbr_rough_w *= 1.0 - wb;
					}
				}
			}
			own_share -= wb * own_share;
		}
		relief *= own_share;
		cavity *= own_share;
		// Natural ground's matte, a floor's smoother (the wet shore above keeps its own).
		roughness = mix(ground_roughness, floor_roughness, is_floor);
	} else if (top > 0.5) {
		roughness = mix(ground_roughness, floor_roughness, is_floor);
	}
	float specular = mix(ground_specular, floor_specular, is_floor);
	// The tile family's own (the wet shore keeps its own roughness above).
#ifdef TERRAIN_SHORE
	if (per_tile_surface && masks.w > 0.5 && !shore) {
#else
	if (per_tile_surface && masks.w > 0.5) {
#endif
		roughness = clamp(floor(masks.w) * 0.01 + surface_roughness_add, 0.0, 1.0);
		specular = fract(masks.w);
	}
#ifdef TERRAIN_SHORE
	if (pbr_rough_w > 0.001 && !shore) {
#else
	if (pbr_rough_w > 0.001) {
#endif
		roughness = mix(roughness, clamp(pbr_rough + surface_roughness_add, 0.0, 1.0), pbr_rough_w);
	}

	// Bare rock and dirt by a cliff, as Factorio's cliffs' lower layer lies pale on the ground at their
	// foot: towards the scree's colour, keeping the picture's light and dark; not on a player's floor.
	float scree_near = cliff_near;
	vec3 scree_rgb = CLIFF_SCREE;
	if (f3d_cliff_tint > 0.0 && cliff_near > 0.001) {
		// Ragged scree, not an even band: patches with a broken edge where the channel fades (it is
		// smooth over the field's 2-tile texels), stones' light and dark, and the colour between the
		// sprites' scree and the wall's apron (#7a6040).
		float n1 = vnoise(world_pos.xz * 0.9 + 4.1);
		float n2 = vnoise(world_pos.xz * 3.7 + 17.3);
		float near_r = cliff_near / f3d_cliff_tint;
		scree_near = f3d_cliff_tint * smoothstep(0.2, 0.75, near_r + (0.65 * n1 + 0.35 * n2 - 0.5) * 0.9);
		scree_rgb = mix(CLIFF_SCREE, vec3(0.195, 0.117, 0.051), n1) * (0.8 + 0.4 * n2);
	}
	float scree_k = top * scree_near * (1.0 - is_floor);
#ifdef TERRAIN_SHORE
	scree_k *= kind == 0 ? 1.0 : 0.0;
#endif
	if (scree_k > 0.001) {
		float lum = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
		albedo = mix(albedo, scree_rgb * clamp(lum / 0.073, 0.6, 1.5), scree_k);
		roughness = mix(roughness, 1.0, scree_k);
	}

	// The decoratives lying on the ground (not on banks or the shelves under and over the water): over the
	// ground's picture, cut where a floor or building covers them, faded out on steep hills, darkened under
	// their raised 3D copies, as decorative_sheet.gdshader draws them, but lit with the ground (the plants'
	// own roughness and specular where they cover it, and no relief or crevices of the picture below).
	bool decor_here = top > 0.5;
#ifdef TERRAIN_SHORE
	decor_here = decor_here && kind == 0;
#endif
	if (decor_here && has_decor_sheet && f3d_decor_composite_on > 0.5 && !decor_blocked(w)) {
		vec4 ds = textureGrad(decor_sheet, sheet_uv, sheet_dx, sheet_dy);
		float da = ds.a * smoothstep(0.75, 0.9, hill_normal.y);
		float grown = decor_raised_shade > 0.0 ? grass_grow(w) : 0.0;
		albedo = mix(albedo, ds.rgb * (1.0 - decor_raised_shade * grown), da);
		roughness = mix(roughness, 1.0, da);
		specular = mix(specular, plant_specular(), da);
		relief *= 1.0 - da;
		pbr_grad *= 1.0 - da;
		cavity *= 1.0 - da;
		noise_grad *= 1.0 - da;
	}

	ALBEDO = albedo;
	EMISSION = lamp_light_emission(ALBEDO, world_pos.xz, max(world_pos.y, 0.0), top);
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = specular * f3d_look_ground_specular;
	// SSAO darkens the ground's sunlight too, not only the sky's light: Factorio paints the shade
	// round a building's foot whatever the light. Without it Godot took a quarter of SSAO to direct
	// light here (the environment's light affect times its AO channel affect, 0.5 x 0.5), and the
	// ground round the buildings, nearly all lit by the sun, showed almost none. The picture's own
	// crevices are the ground's occlusion (Godot takes the darker of it and SSAO).
	AO = 1.0 - crevice * mix(1.0, 0.5, is_floor) * cavity;
	AO_LIGHT_AFFECT = ssao_on_sunlight * f3d_look_ao_direct;

	if (top > 0.5) {
		// The noise's tilt, then the picture's own relief.
		vec2 grad = noise_grad + pbr_grad;
		grad += relief * relief_height * mix(1.0, floor_relief, is_floor);
		if (f3d_weather_wet.x > 0.001 || f3d_weather_wet.z > 0.001) {
			weather_apply_ground(w, hill_normal, cavity, is_floor, length(VERTEX), ALBEDO, ROUGHNESS, SPECULAR, grad, EMISSION, vec3(0.45, 0.52, 0.62));
		}
		vec3 nrm = normalize(hill_normal + vec3(-grad.x, 0.0, -grad.y));
		NORMAL = normalize((VIEW_MATRIX * vec4(nrm, 0.0)).xyz);
	}
}
