shader_type canvas_item;
// Alt-mode's icons on the graphics card (alt_overlay.gd, --alt-icons=gpu, the default): one quad an
// icon in a 2D MultiMesh, placed here the way _emit_chunk_cache and _push_icon place it on the CPU
// (the anchor projected like Camera3D.unproject_position, its size from the projected width of the
// entity's `ref` tiles clamped to 4-40 UI px, the cell's offset and side, under 3 px not drawn), and
// drawn as one picture: the soft shadow (1.3 times the side), the icon over it, the quality mark over
// that at the bottom left (0.4 of the side). The instances come sorted farthest first, so each
// icon's shadow and picture cover the farther icons under them, as the CPU path's layers do.
// Per instance: COLOR = (cell offset x, y in tiles, cell side in tiles, icon layer + 4096 * (mark layer + 1)),
// INSTANCE_CUSTOM = (anchor x, y, z, ref tiles).

uniform sampler2DArray icons : filter_linear_mipmap, repeat_disable;
uniform sampler2D shadow_tex : filter_linear, repeat_disable;
uniform mat4 proj_view;  // the camera's projection times its rotation (positions relative to cam_pos)
uniform vec3 cam_pos;
uniform vec3 cam_right;
uniform vec3 cam_fwd;
uniform vec3 eye_pos;  // the camera's own position (is_position_behind)
uniform float cam_near = 0.05;
uniform vec2 vp_size = vec2(1152.0, 648.0);
uniform vec2 px_clamp = vec2(4.0, 40.0);
uniform float min_side_px = 3.0;

varying flat float v_icon;
varying flat float v_mark;

vec2 to_screen(vec3 rel) {
	vec4 clip = proj_view * vec4(rel, 1.0);
	vec2 ndc = clip.xy / clip.w;
	return vec2((ndc.x * 0.5 + 0.5) * vp_size.x, (-ndc.y * 0.5 + 0.5) * vp_size.y);
}

void vertex() {
	vec4 a = INSTANCE_CUSTOM;
	vec4 d = COLOR;
	vec2 corner = VERTEX;
	vec3 rel = a.xyz - cam_pos;
	bool hide = dot(cam_fwd, a.xyz - eye_pos) < cam_near;
	vec2 p = to_screen(rel);
	vec2 e = to_screen(rel + cam_right * a.w * 0.5);
	float half_px = clamp(distance(p, e), px_clamp.x, px_clamp.y);
	float per_tile = half_px * 2.0 / max(a.w, 0.0001);
	float side = d.z * per_tile;
	hide = hide || side < min_side_px;
	vec2 mid = p + d.xy * per_tile;
	float s = side * 0.65;
	VERTEX = hide ? vec2(-100000.0) : mid + corner * s;
	float pk = floor(d.w + 0.5);
	float mk = floor(pk / 4096.0);
	v_icon = pk - mk * 4096.0;
	v_mark = mk - 1.0;
	COLOR = vec4(1.0);
}

// Straight-alpha "src over dst", as drawing src after dst on the canvas.
vec4 over(vec4 src, vec4 dst) {
	float a = src.a + dst.a * (1.0 - src.a);
	vec3 rgb = a > 0.0 ? (src.rgb * src.a + dst.rgb * dst.a * (1.0 - src.a)) / a : vec3(0.0);
	return vec4(rgb, a);
}

void fragment() {
	// q: this pixel in icon sides from the icon's centre (the quad is the shadow's 1.3 sides).
	vec2 q = UV * 1.3 - vec2(0.65);
	vec4 c = texture(shadow_tex, UV);
	vec2 iuv = q + vec2(0.5);
	vec4 ic = texture(icons, vec3(iuv, v_icon));
	float inside = step(0.0, iuv.x) * step(iuv.x, 1.0) * step(0.0, iuv.y) * step(iuv.y, 1.0);
	ic.a *= inside;
	c = over(ic, c);
	vec2 muv = (q - vec2(-0.5, 0.1)) / 0.4;
	vec4 mc = texture(icons, vec3(muv, max(v_mark, 0.0)));
	float m_in = step(0.0, muv.x) * step(muv.x, 1.0) * step(0.0, muv.y) * step(muv.y, 1.0);
	mc.a *= m_in * step(0.0, v_mark);
	c = over(mc, c);
	COLOR = c;
}
