// The body of item.gdshader and item_own.gdshader (ITEM_OWN: a surface of a modeller's item model drawn
// with its file's own material, item_models.gd dressed) and item_own_blend.gdshader (ITEM_BLEND too: its
// see-through surfaces, blended).
#include "res://shaders/belt_path.gdshaderinc"
#include "res://shaders/ground_height.gdshaderinc"
#include "res://shaders/item_pbr.gdshaderinc"

uniform vec4 color : source_color = vec4(1.0);
uniform float roughness = 0.8;
// The colours were picked from icons drawn already lit; this keeps the sun from lighting them twice.
uniform float exposure = 1.0;
uniform bool use_picture = false;
uniform sampler2D picture : source_color, filter_linear_mipmap, repeat_enable;
// Multi-surface item LOD band (item_models.gd dressed_lod, item_cards.gd): when lod_min_sq or
// lod_max_sq is > 0, instances outside [lod_min_sq, lod_max_sq) from lod_cam collapse in vertex()
// using one belt_place() call per vertex, so detailed glass/multi-surface meshes only rasterize close up.
uniform vec3 lod_cam = vec3(0.0);
uniform float lod_min_sq = 0.0;
uniform float lod_max_sq = 0.0;

void vertex() {
	if (lod_min_sq > 0.0 || lod_max_sq > 0.0) {
		vec3 o = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
		vec3 ax = (MODEL_MATRIX * vec4(1.0, 0.0, 0.0, 0.0)).xyz;
		bool hide = false;
		if (belt_base >= 0) {
			vec3 local_v = VERTEX;
			vec3 local_n = NORMAL;
			belt_place(o, ax, INSTANCE_ID);
			if (o == vec3(0.0)) {
				hide = true;
			} else {
				vec3 d = o - lod_cam;
				float d2 = dot(d, d);
				if ((lod_min_sq > 0.0 && d2 < lod_min_sq) || (lod_max_sq > 0.0 && d2 >= lod_max_sq)) {
					hide = true;
				} else {
					VERTEX = vec3(ax.x * local_v.x - ax.z * local_v.z, local_v.y, ax.z * local_v.x + ax.x * local_v.z) + o;
					NORMAL = vec3(ax.x * local_n.x - ax.z * local_n.z, local_n.y, ax.z * local_n.x + ax.x * local_n.z);
				}
			}
		} else {
			vec3 d = o - lod_cam;
			float d2 = dot(d, d);
			if ((lod_min_sq > 0.0 && d2 < lod_min_sq) || (lod_max_sq > 0.0 && d2 >= lod_max_sq)) {
				hide = true;
			}
		}
		if (hide) {
			VERTEX = vec3(0.0);
		} else {
			VERTEX.y += ground_h(o.xz);
		}
	} else {
		belt_place(VERTEX, NORMAL, INSTANCE_ID);
		VERTEX.y += ground_h(VERTEX.xz);  // world coordinates here
	}
}

void fragment() {
#ifdef ITEM_OWN
	// A surface of a modeller's item model with its file's own material (item_own.gdshader).
	vec4 tex = use_picture ? texture(picture, UV) : vec4(1.0);
	float own_a = color.a * COLOR.a * tex.a;
#ifdef ITEM_BLEND
	ALPHA = own_a;  // item_own_blend.gdshader: blended in the transparent pass
#else
	if (item_own_cut(own_a, FRAGCOORD.xy)) {
		discard;
	}
#endif
	ALBEDO = color.rgb * COLOR.rgb * tex.rgb * exposure;
	NORMAL = item_pbr_normal(NORMAL, VERTEX, UV);
	vec2 own_rm = item_pbr_surface(UV);
	ROUGHNESS = own_rm.x;
	METALLIC = own_rm.y;
	EMISSION = item_own_emission(UV);
#else
	vec3 albedo = color.rgb * COLOR.rgb;
	if (use_picture) {
		albedo *= texture(picture, UV).rgb;
	}
	ALBEDO = albedo * exposure;
	ROUGHNESS = max(roughness, f3d_look_roughness_min);
#endif
	if (item_pbr_on()) {
#ifndef ITEM_OWN
		NORMAL = item_pbr_normal(NORMAL, VERTEX, UV);
#endif
		vec2 rm = item_pbr_surface(UV);
		ALBEDO = item_pbr_albedo(ALBEDO, clamp((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y, 0.0, 1.0));
		ROUGHNESS = rm.x;
		METALLIC = rm.y;
		SPECULAR = 0.5;
#ifdef ITEM_OWN
		EMISSION += item_pbr_fill(ALBEDO, NORMAL, VIEW);
#else
		EMISSION = item_pbr_fill(ALBEDO, NORMAL, VIEW);
#endif
#ifdef SHADER_LIGHT_ENV
		if (f3d_light_env < 0.5) {
			RADIANCE = pbr_env_radiance(VIEW, normalize(NORMAL), ROUGHNESS, INV_VIEW_MATRIX);
			IRRADIANCE = pbr_irradiance(normalize(NORMAL), INV_VIEW_MATRIX);
		}
#endif
	}
}
