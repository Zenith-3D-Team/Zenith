// Fulgora's lightning bolts (scripts/fx/lightning.gd): camera-facing ribbons, added to what is behind
// them. UV.x runs across a ribbon (0 to 1), so it is brightest along its middle; COLOR.a is the bolt's
// strength now (flickering out). Brighter than 1 so a look's bloom picks it up.
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform float energy = 4.0;

void fragment() {
	float across = 1.0 - abs(UV.x * 2.0 - 1.0);
	ALBEDO = COLOR.rgb * energy * COLOR.a * across * across;
	ALPHA = 1.0;
}
