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
uniform vec4 color : source_color = vec4(1.0);
uniform vec2 focus = vec2(0.0);
uniform float near = 22.0;
uniform float far = 160.0;

varying vec2 world_xz;
varying flat vec2 belt;

void vertex() {
	world_xz = VERTEX.xz;
	belt = INSTANCE_CUSTOM.xy;
	VERTEX.y += ground_h(VERTEX.xz);  // world coordinates here
}

void fragment() {
	vec2 d = abs(belt - focus);
	if (max(d.x, d.y) < near || length(world_xz - focus) > far) {
		discard;
	}
	vec3 albedo = COLOR.rgb;
	if (own) {
		vec4 tex = use_picture ? texture(picture, UV) : vec4(1.0);
		float own_a = color.a * COLOR.a * tex.a;
#ifdef ITEM_BLEND
		ALPHA = own_a;
#else
		if (item_own_cut(own_a, FRAGCOORD.xy)) {
			discard;
		}
#endif
		albedo *= color.rgb * tex.rgb;
	} else if (use_picture) {
		albedo *= texture(picture, UV).rgb;
	}
	ALBEDO = albedo * exposure;
	ROUGHNESS = max(0.8, f3d_look_roughness_min);
	if (own) {
		NORMAL = item_pbr_normal(NORMAL, VERTEX, UV);
		vec2 own_rm = item_pbr_surface(UV);
		ROUGHNESS = own_rm.x;
		METALLIC = own_rm.y;
		EMISSION = item_own_emission(UV);
	}
	if (item_pbr_on()) {
		if (!own) {
			NORMAL = item_pbr_normal(NORMAL, VERTEX, UV);
		}
		vec2 rm = item_pbr_surface(UV);
		ALBEDO = item_pbr_albedo(ALBEDO, clamp((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y, 0.0, 1.0));
		ROUGHNESS = rm.x;
		METALLIC = rm.y;
		SPECULAR = 0.5;
		EMISSION = (own ? EMISSION : vec3(0.0)) + item_pbr_fill(ALBEDO, NORMAL, VIEW);
#ifdef SHADER_LIGHT_ENV
		if (f3d_light_env < 0.5) {
			RADIANCE = pbr_env_radiance(VIEW, normalize(NORMAL), ROUGHNESS, INV_VIEW_MATRIX);
			IRRADIANCE = pbr_irradiance(normalize(NORMAL), INV_VIEW_MATRIX);
		}
#endif
	}
}
