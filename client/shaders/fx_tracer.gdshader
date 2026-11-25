shader_type spatial;
// Bullet tracers (weapon_fx.gd): a camera-facing streak per shot, one MultiMesh of quads, each
// instance's colour the ammo's. UV.x runs along the streak (1 at its head, towards the hit), UV.y
// across it. Added on, depth-tested, no depth written.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

void fragment() {
	float across = 1.0 - abs(UV.y * 2.0 - 1.0);
	float core = pow(across, 6.0);
	float glow = across * across;
	float along = smoothstep(0.0, 1.0, UV.x) * smoothstep(1.0, 0.92, UV.x);
	vec3 c = mix(COLOR.rgb, vec3(1.0), core * 0.6);
	ALBEDO = c * (glow * 1.6 + core * 1.2) * along * COLOR.a;
}
