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
// lod_max_sq is > 0, instances outside [lod_min_sq, lod_max_sq) from active_lod_cam collapse in vertex()
// using one belt_place() call per vertex, so detailed glass/multi-surface meshes only rasterize close up.
// Reads global f3d_item_lod_cam by default; standalone shader tests can override via lod_cam.
global uniform vec3 f3d_item_lod_cam;
uniform vec3 lod_cam = vec3(1.0e9);
uniform float lod_min_sq = 0.0;
uniform float lod_max_sq = 0.0;
uniform vec2 lod_jitter = vec2(0.0);
uniform float lod_fade_start = 0.0;
uniform float lod_fade_end = 0.0;
uniform float lod_roughness = -1.0;
uniform float lod_metallic = 0.0;
uniform bool lod_fade_albedo = false;
uniform vec3 lod_albedo_mean = vec3(1.0);
uniform bool use_own_rm = false;

varying float v_lod_detail;

void vertex() {
	v_lod_detail = 1.0;
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
		if (!hide && (lod_min_sq > 0.0 || lod_max_sq > 0.0 || lod_fade_end > lod_fade_start)) {
			vec3 active_lod_cam = lod_cam.x < 1.0e8 ? lod_cam : f3d_item_lod_cam;
			float jitter = INSTANCE_CUSTOM.y;
			float dist = length(o - active_lod_cam);
			float d_min = max(dist + jitter * lod_jitter.x, 0.0);
			float d_max = max(dist + jitter * lod_jitter.y, 0.0);
			if ((lod_min_sq > 0.0 && d_min * d_min < lod_min_sq)
					|| (lod_max_sq > 0.0 && d_max * d_max >= lod_max_sq)) {
				hide = true;
			} else if (lod_fade_end > lod_fade_start) {
				v_lod_detail = 1.0 - smoothstep(lod_fade_start, lod_fade_end, d_max);
			}
		}
		if (hide) {
			VERTEX = vec3(0.0);
		} else {
			VERTEX = ground_lift_origin(VERTEX, MODEL_MATRIX);
		}
	} else if (lod_min_sq > 0.0 || lod_max_sq > 0.0 || lod_fade_end > lod_fade_start) {
		vec3 active_lod_cam = lod_cam.x < 1.0e8 ? lod_cam : f3d_item_lod_cam;
		vec3 o = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
		vec3 ax = (MODEL_MATRIX * vec4(1.0, 0.0, 0.0, 0.0)).xyz;
		bool hide = false;
		float jitter = 0.0;
		float d_max = 0.0;
		if (belt_base >= 0) {
			vec3 local_v = VERTEX;
			vec3 local_n = NORMAL;
			vec3 local_t = TANGENT;
			vec3 local_b = BINORMAL;
			belt_place_lod(o, ax, jitter, INSTANCE_ID);
			if (o == vec3(0.0)) {
				hide = true;
			} else {
				float dist = length(o - active_lod_cam);
				float d_min = max(dist + jitter * lod_jitter.x, 0.0);
				d_max = max(dist + jitter * lod_jitter.y, 0.0);
				if ((lod_min_sq > 0.0 && d_min * d_min < lod_min_sq) || (lod_max_sq > 0.0 && d_max * d_max >= lod_max_sq)) {
					hide = true;
				} else {
					VERTEX = vec3(ax.x * local_v.x - ax.z * local_v.z, local_v.y, ax.z * local_v.x + ax.x * local_v.z) + o;
					NORMAL = vec3(ax.x * local_n.x - ax.z * local_n.z, local_n.y, ax.z * local_n.x + ax.x * local_n.z);
					TANGENT = vec3(ax.x * local_t.x - ax.z * local_t.z, local_t.y, ax.z * local_t.x + ax.x * local_t.z);
					BINORMAL = vec3(ax.x * local_b.x - ax.z * local_b.z, local_b.y, ax.z * local_b.x + ax.x * local_b.z);
				}
			}
		} else {
			uint lh = belt_lattice_hash(int(round(ax.z * 100000.0)), mod(round(o.x * 16.0) + round(o.z * 16.0) * 131.0, 1048576.0));
			jitter = float((lh >> 16u) & 65535u) / 32767.5 - 1.0;
			float dist = length(o - active_lod_cam);
			float d_min = max(dist + jitter * lod_jitter.x, 0.0);
			d_max = max(dist + jitter * lod_jitter.y, 0.0);
			if ((lod_min_sq > 0.0 && d_min * d_min < lod_min_sq) || (lod_max_sq > 0.0 && d_max * d_max >= lod_max_sq)) {
				hide = true;
			}
		}
		if (hide) {
			VERTEX = vec3(0.0);
		} else {
			if (lod_fade_end > lod_fade_start) {
				v_lod_detail = 1.0 - smoothstep(lod_fade_start, lod_fade_end, d_max);
			}
			if (belt_base >= 0) {
				VERTEX.y += ground_h(o.xz);
			} else {
				VERTEX = ground_lift_origin(VERTEX, MODEL_MATRIX);
			}
		}
	} else {
		if (belt_base >= 0) {
			belt_place_basis(VERTEX, NORMAL, TANGENT, BINORMAL, INSTANCE_ID);
			VERTEX.y += ground_h(VERTEX.xz);  // world coordinates here
		} else {
			VERTEX = ground_lift(VERTEX, MODEL_MATRIX);
		}
	}
}

void fragment() {
#ifdef ITEM_OWN
	// A surface of a modeller's item model with its file's own material (item_own.gdshader).
	vec4 tex = use_picture ? texture(picture, UV) : vec4(1.0);
	float own_a = color.a * COLOR.a * tex.a;
#ifdef ITEM_BLEND
	ALPHA = own_a;  // item_own_blend.gdshader: blended in the transparent pass
#elif defined(ITEM_CUT)
	if (item_own_cut(own_a, FRAGCOORD.xy)) {
		discard;
	}
#endif
	if (use_picture && lod_fade_albedo && v_lod_detail < 0.999) {
		tex.rgb = mix(lod_albedo_mean, tex.rgb, v_lod_detail);
	}
	ALBEDO = color.rgb * COLOR.rgb * tex.rgb * exposure;
	NORMAL = item_pbr_normal_scale(NORMAL, VERTEX, UV, TANGENT, BINORMAL, v_lod_detail);
	vec2 own_rm = item_pbr_surface(UV);
	if (lod_roughness >= 0.0 && v_lod_detail < 0.999) {
		vec2 lod_rm = vec2(max(lod_roughness, f3d_look_roughness_min_pbr), lod_metallic * f3d_look_pbr_metal);
		own_rm = mix(lod_rm, own_rm, v_lod_detail);
	}
	ROUGHNESS = own_rm.x;
	METALLIC = own_rm.y;
	EMISSION = item_own_emission(UV);
#else
	vec3 albedo = color.rgb * COLOR.rgb;
	if (use_picture) {
		vec3 pic = texture(picture, UV).rgb;
		if (lod_fade_albedo && v_lod_detail < 0.999) {
			pic = mix(lod_albedo_mean, pic, v_lod_detail);
		}
		albedo *= pic;
	}
	ALBEDO = albedo * exposure;
	ROUGHNESS = max(roughness, f3d_look_roughness_min);
	if (use_own_rm) {
		vec2 own_rm = item_pbr_surface(UV);
		ROUGHNESS = own_rm.x;
		METALLIC = own_rm.y;
		EMISSION = emission.rgb * emission_energy;
	}
#endif
	if (item_pbr_on()) {
#ifndef ITEM_OWN
		NORMAL = item_pbr_normal_scale(NORMAL, VERTEX, UV, TANGENT, BINORMAL, v_lod_detail);
#endif
		vec2 rm = item_pbr_surface(UV);
		if (lod_roughness >= 0.0 && v_lod_detail < 0.999) {
			vec2 lod_rm = vec2(max(lod_roughness, f3d_look_roughness_min_pbr), lod_metallic * f3d_look_pbr_metal);
			rm = mix(lod_rm, rm, v_lod_detail);
		}
		ALBEDO = item_pbr_albedo(ALBEDO, clamp((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y, 0.0, 1.0));
		ROUGHNESS = rm.x;
		METALLIC = rm.y;
		SPECULAR = 0.5;
#ifdef ITEM_OWN
		EMISSION += item_pbr_fill(ALBEDO, NORMAL, VIEW);
#else
		EMISSION = (use_own_rm ? EMISSION : vec3(0.0)) + item_pbr_fill(ALBEDO, NORMAL, VIEW);
#endif
#ifdef SHADER_LIGHT_ENV
		if (f3d_light_env < 0.5) {
			RADIANCE = pbr_env_radiance(VIEW, normalize(NORMAL), ROUGHNESS, INV_VIEW_MATRIX);
			IRRADIANCE = pbr_irradiance(normalize(NORMAL), INV_VIEW_MATRIX);
		}
#endif
	}
}
