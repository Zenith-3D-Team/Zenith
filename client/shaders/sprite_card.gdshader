shader_type spatial;
// A building's own Factorio picture on a card in the world (sprite_standins.gd): seen from both sides, lit as
// the world is (Factorio darkens its pictures by night, so an unlit card would glow), its edges the picture's
// own alpha: alpha to coverage where the view has MSAA (smooth, as Factorio's blended edges), else cut at half.
// The picture, the hills and the animation: sprite_card.gdshaderinc.
render_mode cull_disabled, depth_draw_opaque;

#include "res://shaders/sprite_card.gdshaderinc"
#include "res://shaders/lamp_light.gdshaderinc"

void fragment() {
	vec4 c = card_colour(UV, TIME);
	ALBEDO = c.rgb;
	EMISSION = lamp_light_emission(ALBEDO, card_xz, 0.5, 0.5);
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ALPHA_ANTIALIASING_EDGE = 0.45;
	ALPHA_TEXTURE_COORDINATE = UV * vec2(textureSize(picture, 0));
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
