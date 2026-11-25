// The body of belt_lane_model.gdshader and belt_lane_model_blend.gdshader (ITEM_BLEND: an own-look item
// model's see-through surface, blended in the transparent pass; item_models.gd dressed).
#include "res://shaders/ground_height.gdshaderinc"
#include "res://shaders/item_pbr.gdshaderinc"

uniform float exposure = 0.75;
// A modeller's item model's base-colour picture (item_models.gd material_for), as item.gdshader's.
uniform bool use_picture = false;
uniform sampler2D picture : source_color, filter_linear_mipmap, repeat_enable;
// A surface of a modeller's item model with its file's own material (item_models.gd dressed), as
// item_own.gdshader's.
uniform bool own = false;
uniform bool use_own_rm = false;
uniform vec4 color : source_color = vec4(1.0);
uniform vec2 focus = vec2(0.0);
uniform float near = 22.0;
uniform float far = 160.0;
uniform bool vcull = true;
uniform float lod_fade_start = 0.0;
uniform float lod_fade_end = 0.0;
uniform bool lod_fade_albedo = false;
uniform vec3 lod_albedo_mean = vec3(1.0);

varying vec2 world_xz;
varying flat vec2 belt;
varying float v_lod_detail;

void vertex() {
	v_lod_detail = 1.0;
	world_xz = VERTEX.xz;
	belt = INSTANCE_CUSTOM.xy;
	vec2 d_belt = abs(belt - focus);
	if (vcull && (max(d_belt.x, d_belt.y) < near || length(belt - focus) > far)) {
		VERTEX = vec3(0.0, -1e6, 0.0);
	} else {
		if (lod_fade_end > lod_fade_start) {
			v_lod_detail = 1.0 - smoothstep(lod_fade_start, lod_fade_end, length(belt - focus));
		}
		VERTEX.y += ground_h(VERTEX.xz);  // world coordinates here
	}
}

void fragment() {
#ifdef LANE_FRAG_CULL
	vec2 d = abs(belt - focus);
	if (max(d.x, d.y) < near || length(world_xz - focus) > far) {
		discard;
	}
#elif defined(ITEM_BLEND)
	if (!vcull) {
		vec2 d = abs(belt - focus);
		if (max(d.x, d.y) < near || length(world_xz - focus) > far) {
			discard;
		}
	}
#endif
	vec3 albedo = COLOR.rgb;
	if (own) {
		vec4 tex = use_picture ? texture(picture, UV) : vec4(1.0);
		float own_a = color.a * COLOR.a * tex.a;
#ifdef ITEM_BLEND
		ALPHA = own_a;
#elif defined(ITEM_CUT)
		if (item_own_cut(own_a, FRAGCOORD.xy)) {
			discard;
		}
#endif
		if (use_picture && lod_fade_albedo && v_lod_detail < 0.999) {
			tex.rgb = mix(lod_albedo_mean, tex.rgb, v_lod_detail);
		}
		albedo *= color.rgb * tex.rgb;
	} else if (use_picture) {
		vec3 pic = texture(picture, UV).rgb;
		if (lod_fade_albedo && v_lod_detail < 0.999) {
			pic = mix(lod_albedo_mean, pic, v_lod_detail);
		}
		albedo *= pic;
	}
	ALBEDO = albedo * exposure;
	ROUGHNESS = max(0.8, f3d_look_roughness_min);
	if (own) {
		NORMAL = item_pbr_normal_tan(NORMAL, VERTEX, UV, TANGENT, BINORMAL);
		vec2 own_rm = item_pbr_surface(UV);
		ROUGHNESS = own_rm.x;
		METALLIC = own_rm.y;
		EMISSION = item_own_emission(UV);
	} else if (use_own_rm) {
		vec2 own_rm = item_pbr_surface(UV);
		ROUGHNESS = own_rm.x;
		METALLIC = own_rm.y;
		EMISSION = emission.rgb * emission_energy;
	}
	if (item_pbr_on()) {
		if (!own) {
			NORMAL = item_pbr_normal_tan(NORMAL, VERTEX, UV, TANGENT, BINORMAL);
		}
		vec2 rm = item_pbr_surface(UV);
		ALBEDO = item_pbr_albedo(ALBEDO, clamp((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y, 0.0, 1.0));
		ROUGHNESS = rm.x;
		METALLIC = rm.y;
		SPECULAR = 0.5;
		EMISSION = ((own || use_own_rm) ? EMISSION : vec3(0.0)) + item_pbr_fill(ALBEDO, NORMAL, VIEW);
#ifdef SHADER_LIGHT_ENV
		if (f3d_light_env < 0.5) {
			RADIANCE = pbr_env_radiance(VIEW, normalize(NORMAL), ROUGHNESS, INV_VIEW_MATRIX);
			IRRADIANCE = pbr_irradiance(normalize(NORMAL), INV_VIEW_MATRIX);
		}
#endif
	}
}
