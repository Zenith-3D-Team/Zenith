shader_type spatial;
// A building's own Factorio picture on a card (sprite_standins.gd): cut out at half alpha, seen from
// both sides, lit as the world is, and lifted whole by the ground's height under the entity's
// centre (ground_height.gdshaderinc), so on an add-on's hills it stands on the slope rather than
// under it, and stays upright. An animated one steps through its moving part's frames (an atlas over
// `frames_rect` of the picture) while its instance's colour says it runs (red), each at its own
// phase (green); a mover's card (movers.gd), a node of its own, says so in f3d_card_run instead.
render_mode cull_disabled, depth_draw_opaque;

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

void vertex() {
	float h = ground_h(MODEL_MATRIX[3].xz);
	if (h != 0.0) {
		VERTEX += inverse(mat3(MODEL_MATRIX)) * vec3(0.0, h, 0.0);
	}
	run = f3d_card_run.x >= 0.0 ? f3d_card_run : COLOR.rg;
}

void fragment() {
	vec4 c = texture(picture, UV);
	if (animated && run.x > 0.5) {
		vec2 local = (UV - frames_rect.xy) / frames_rect.zw;
		if (local.x >= 0.0 && local.y >= 0.0 && local.x <= 1.0 && local.y <= 1.0) {
			float n = frames_grid.z;
			float f = min(floor(fract(TIME / max(frames_loop, 0.001) + run.y) * n), n - 1.0);
			vec2 cell = vec2(mod(f, frames_grid.x), floor(f / frames_grid.x));
			c = texture(frames, (cell + clamp(local, vec2(0.001), vec2(0.999))) / frames_grid.xy);
		}
	}
	ALBEDO = c.rgb;
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 1.0;
}
