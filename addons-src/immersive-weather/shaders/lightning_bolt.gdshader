shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

// Jagged 3D lightning bolts for Immersive Weather (scripts/weather_lightning.gd): camera-facing
// ribbons added over the sky and scene. UV.x runs 0..1 across the ribbon width; COLOR.a carries
// the instantaneous flicker envelope.

uniform float energy = 4.5;

void fragment() {
	float across = 1.0 - abs(UV.x * 2.0 - 1.0);
	ALBEDO = COLOR.rgb * energy * COLOR.a * across * across;
	ALPHA = 1.0;
}
