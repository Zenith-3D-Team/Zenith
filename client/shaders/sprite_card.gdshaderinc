// A Factorio picture on a card (sprite_standins.gd), shared by sprite_card.gdshader (the world's, lit) and
// sprite_card_unlit.gdshader (the Model packs window's preview, as Factorio's screen draws it). The picture is
// sRGB (source_color: decoded to linear when read, so the output's encoding gives back the file's values) and
// mipmapped. The card is lifted whole by the ground's height under the entity's centre
// (ground_height.gdshaderinc), so on an add-on's hills it stands on the slope rather than under it, and stays
// upright. An animated one steps through its moving part's frames (an atlas over `frames_rect` of the picture)
// while its instance's colour says it runs (red), each at its own phase (green); a mover's card (movers.gd), a
// node of its own, says so in f3d_card_run instead.

#include "res://shaders/ground_height.gdshaderinc"

uniform sampler2D picture : source_color, filter_linear_mipmap;
uniform bool animated = false;
uniform sampler2D frames : source_color, filter_linear_mipmap;
// The moving part in the picture's UVs (x, y, width, height); the atlas' columns, rows and frames;
// the loop in seconds.
uniform vec4 frames_rect = vec4(0.0);
uniform vec3 frames_grid = vec3(1.0);
uniform float frames_loop = 1.0;
// A mover's card: (runs, phase); below 0, the instance colour's (chunks' MultiMeshes).
instance uniform vec2 f3d_card_run = vec2(-1.0);

varying vec2 run;
varying vec2 card_xz;

void vertex() {
	card_xz = MODEL_MATRIX[3].xz;
	float h = ground_h(card_xz);
	if (h != 0.0) {
		VERTEX += ground_up_in(MODEL_MATRIX, h);
	}
	run = f3d_card_run.x >= 0.0 ? f3d_card_run : COLOR.rg;
}

vec4 card_colour(vec2 uv, float time) {
	vec4 c = texture(picture, uv);
	if (animated && run.x > 0.5) {
		vec2 local = (uv - frames_rect.xy) / frames_rect.zw;
		if (local.x >= 0.0 && local.y >= 0.0 && local.x <= 1.0 && local.y <= 1.0) {
			float n = frames_grid.z;
			float f = min(floor(fract(time / max(frames_loop, 0.001) + run.y) * n), n - 1.0);
			vec2 cell = vec2(mod(f, frames_grid.x), floor(f / frames_grid.x));
			c = texture(frames, (cell + clamp(local, vec2(0.001), vec2(0.999))) / frames_grid.xy);
		}
	}
	return c;
}
