// Items drawn as Factorio's icon (item_cards.gd): a card lying face up, cut out by the icon's
// alpha. Glides like item.gdshader.
shader_type spatial;

#include "res://shaders/belt_path.gdshaderinc"
#include "res://shaders/ground_height.gdshaderinc"
#include "res://shaders/icon_lod.gdshaderinc"

uniform sampler2D icon : source_color, filter_linear_mipmap_anisotropic;
global uniform vec3 f3d_item_lod_cam;
uniform vec3 lod_cam = vec3(1.0e9);
uniform float lod_min_sq = 0.0;
uniform float lod_max_sq = 0.0;
uniform vec2 lod_jitter = vec2(0.0);

void vertex() {
	if (belt_base == -2) {
		bool hide = (f3d_belt_clock < INSTANCE_CUSTOM.w);
		vec3 o = MODEL_MATRIX[3].xyz;
		if (!hide && !belt_lod_all_variants && belt_variants > 1
				&& int(floor(mod(INSTANCE_CUSTOM.x, 128.0) + 0.5)) != belt_variant) {
			hide = true;
		}
#ifndef BELT_NO_VIEW_CULL
		if (!hide && (o.x < f3d_item_view_rect.x || o.x > f3d_item_view_rect.z
				|| o.z < f3d_item_view_rect.y || o.z > f3d_item_view_rect.w)) {
			hide = true;
		}
#endif
		if (!hide && (lod_min_sq > 0.0 || lod_max_sq > 0.0)) {
			vec3 active_lod_cam = lod_cam.x < 1.0e8 ? lod_cam : f3d_item_lod_cam;
			float jitter = INSTANCE_CUSTOM.y;
			float dist = length(o - active_lod_cam);
			float d_min = max(dist + jitter * lod_jitter.x, 0.0);
			float d_max = max(dist + jitter * lod_jitter.y, 0.0);
			if ((lod_min_sq > 0.0 && d_min * d_min < lod_min_sq)
					|| (lod_max_sq > 0.0 && d_max * d_max >= lod_max_sq)) {
				hide = true;
			}
		}
		if (hide) {
			VERTEX = vec3(0.0);
		} else {
			VERTEX = ground_lift_origin(VERTEX, MODEL_MATRIX);
		}
	} else if (lod_min_sq > 0.0 || lod_max_sq > 0.0) {
		vec3 active_lod_cam = lod_cam.x < 1.0e8 ? lod_cam : f3d_item_lod_cam;
		vec3 o = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
		vec3 ax = (MODEL_MATRIX * vec4(1.0, 0.0, 0.0, 0.0)).xyz;
		bool hide = false;
		float jitter = 0.0;
		if (belt_base >= 0) {
			vec3 local_v = VERTEX;
			vec3 local_n = NORMAL;
			belt_place_lod(o, ax, jitter, INSTANCE_ID);
			if (o == vec3(0.0)) {
				hide = true;
			} else {
				float dist = length(o - active_lod_cam);
				float d_min = max(dist + jitter * lod_jitter.x, 0.0);
				float d_max = max(dist + jitter * lod_jitter.y, 0.0);
				if ((lod_min_sq > 0.0 && d_min * d_min < lod_min_sq) || (lod_max_sq > 0.0 && d_max * d_max >= lod_max_sq)) {
					hide = true;
				} else {
					VERTEX = vec3(ax.x * local_v.x - ax.z * local_v.z, local_v.y, ax.z * local_v.x + ax.x * local_v.z) + o;
					NORMAL = vec3(ax.x * local_n.x - ax.z * local_n.z, local_n.y, ax.z * local_n.x + ax.x * local_n.z);
				}
			}
		} else {
			uint lh = belt_lattice_hash(int(round(ax.z * 100000.0)), mod(round(o.x * 16.0) + round(o.z * 16.0) * 131.0, 1048576.0));
			jitter = float((lh >> 16u) & 65535u) / 32767.5 - 1.0;
			float dist = length(o - active_lod_cam);
			float d_min = max(dist + jitter * lod_jitter.x, 0.0);
			float d_max = max(dist + jitter * lod_jitter.y, 0.0);
			if ((lod_min_sq > 0.0 && d_min * d_min < lod_min_sq) || (lod_max_sq > 0.0 && d_max * d_max >= lod_max_sq)) {
				hide = true;
			}
		}
		if (hide) {
			VERTEX = vec3(0.0);
		} else {
			if (belt_base >= 0) {
				VERTEX.y += ground_h(o.xz);
			} else {
				VERTEX = ground_lift_origin(VERTEX, MODEL_MATRIX);
			}
		}
	} else {
		if (belt_base >= 0) {
			belt_place(VERTEX, NORMAL, INSTANCE_ID);
			VERTEX.y += ground_h(VERTEX.xz);  // world coordinates here
		} else {
			VERTEX = ground_lift(VERTEX, MODEL_MATRIX);
		}
	}
}

void fragment() {
	vec4 c = icon_texel(icon, UV);
	ALBEDO = c.rgb;
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 0.9;
}
