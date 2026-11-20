shader_type canvas_item;
// Straightens premultiplied colours rendered onto a transparent SubViewport (decor_sheet_baker.gd),
// dilates opaque pixels by one texel into empty neighbours so bilinear/mipmap filtering keeps no
// dark halo, and encodes linear HDR output back into sRGB for an RGBA8 chunk sheet.
render_mode blend_premul_alpha;

uniform sampler2D src : filter_nearest, repeat_disable;
uniform bool encode_srgb = true;
uniform bool swap_rb = false;

vec3 lin_to_srgb(vec3 c) {
	vec3 v = max(c, vec3(0.0));
	return mix(v * 12.92, 1.055 * pow(v, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), v));
}

void fragment() {
	vec4 c = texture(src, UV);
	vec4 out_col;
	if (c.a > 0.004) {
		vec3 straight = clamp(c.rgb / c.a, 0.0, 1.0);
		out_col = vec4(encode_srgb ? lin_to_srgb(straight) : straight, c.a);
	} else {
		vec2 px = 1.0 / vec2(textureSize(src, 0));
		vec3 sum = vec3(0.0);
		float wsum = 0.0;
		for (int dy = -1; dy <= 1; dy++) {
			for (int dx = -1; dx <= 1; dx++) {
				if (dx == 0 && dy == 0) {
					continue;
				}
				vec2 suv = UV + vec2(float(dx), float(dy)) * px;
				if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) {
					continue;
				}
				vec4 n = texture(src, suv);
				if (n.a > 0.004) {
					vec3 n_straight = clamp(n.rgb / n.a, 0.0, 1.0);
					sum += n_straight * n.a;
					wsum += n.a;
				}
			}
		}
		vec3 fill = wsum > 0.0 ? sum / wsum : vec3(0.0);
		out_col = vec4(encode_srgb ? lin_to_srgb(fill) : fill, 0.0);
	}
	COLOR = swap_rb ? vec4(out_col.b, out_col.g, out_col.r, out_col.a) : out_col;
}
