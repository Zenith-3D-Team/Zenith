shader_type spatial;
// A Factorio picture on a card as Factorio's own screen draws it (the Model packs window's preview,
// model_preview.gd): unshaded, at full brightness, blended by the picture's own alpha (no cut-out edge), the
// file's sRGB colours given back unchanged through the preview's linear tone mapping. The picture, the hills
// and the animation: sprite_card.gdshaderinc.
render_mode unshaded, cull_disabled, blend_mix, depth_draw_always, shadows_disabled;

#include "res://shaders/sprite_card.gdshaderinc"

void fragment() {
	vec4 c = card_colour(UV, TIME);
	ALBEDO = c.rgb;
	ALPHA = c.a;
}
