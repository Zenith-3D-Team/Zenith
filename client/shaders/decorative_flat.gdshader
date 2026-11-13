shader_type spatial;
// Factorio's flat decoratives (decoratives.gd): grass, flowers, bushes, small rocks and decals lying on
// the ground, blended as Factorio draws them. As hard cut-outs their thin leaves crawled and sparkled
// whenever the view moved less than a pixel. They write no depth and are drawn in a fixed order (each
// decorative a render priority by Factorio's layer), so overlapping ones never swap. The atlas's
// colours are spread into its see-through pixels before its mipmaps are made (fix_alpha_edges), so far
// away they fade evenly instead of darkening at their edges. INSTANCE_CUSTOM is (u start, u width,
// v height, unused). They take the sun's shadows (trees' and buildings' fall over them, as in Factorio)
// but cast none (decoratives.gd turns casting off).
render_mode blend_mix, depth_draw_never, cull_disabled;

#include "res://shaders/ground_height.gdshaderinc"
#include "res://shaders/decorative_grass.gdshaderinc"
#include "res://shaders/decor_mask.gdshaderinc"

uniform sampler2D atlas : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
// How much darker a plant with a raised copy gets near the character: less for carpets, whose clumps
// thin out further from it (decorative_carpet.gdshader) and leave the picture showing between them.
uniform float raised_shade = 0.55;

// How level the hills are where the picture lies (ground_height.gdshaderinc): flat pictures
// lying across a terrace's step would stretch down its side, so they fade out on steep ground.
varying float level;
// Near the character a plant with a raised copy over it (INSTANCE_CUSTOM.w, decorative_grass.gdshader)
// darkens into that copy's shadow on the ground: left in full colour it reads as a second plant.
varying float grown;
// Where on the map the pixel lies: a picture reaching over concrete or under a building is cut at that
// tile's edge (decor_mask.gdshaderinc; decoratives.gd leaves out those rooted there).
varying vec2 ground_at;

void vertex() {
	UV = vec2(INSTANCE_CUSTOM.x + UV.x * INSTANCE_CUSTOM.y, UV.y * INSTANCE_CUSTOM.z);
	ground_at = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	level = ground_n(ground_at).y;
	grown = INSTANCE_CUSTOM.w > 0.5 ? grass_grow(MODEL_MATRIX[3].xz) : 0.0;
	VERTEX = ground_lift(VERTEX, MODEL_MATRIX);
}

global uniform float f3d_look_ground_specular;  // looks.gd "ground_specular"

void fragment() {
	if (decor_blocked(ground_at)) {
		discard;
	}
	vec4 c = texture(atlas, UV);
	ALBEDO = c.rgb * (1.0 - raised_shade * grown);
	SPECULAR = 0.5 * f3d_look_ground_specular;
	ALPHA = c.a * smoothstep(0.75, 0.9, level);
}
