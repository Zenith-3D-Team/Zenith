// A "pbr" pack's pictured item model (model_packs.gd shading(), item_models.gd set_pbr), for item.gdshader
// and belt_lane_model.gdshader: drawn as its file says, as a "pbr" pack's buildings are
// (factorio_material.gdshaderinc modeller_tex), not with the flat icon look: its roughness and metal
// pictures (metal at the look's pbr_metal share), its normal map, Godot's SPECULAR 0.5, the look's balance of
// light on its picture, the look's fill on models (its pbr_fill share) and the neutral reflection and ambient
// (pbr_env.gdshaderinc, RADIANCE and IRRADIANCE).
// Off with packs' own shading off (f3d_pack_shading 0).
uniform bool pbr = false;
uniform float pbr_roughness = 1.0;
uniform float pbr_metallic = 0.0;
uniform bool use_orm = false;
uniform sampler2D orm_picture : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform bool use_normal = false;
uniform sampler2D normal_picture : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_scale = 1.0;

global uniform float f3d_pack_shading;
global uniform float f3d_look_pbr_metal;
// The look's roughness floor, as on buildings (factorio_material.gdshaderinc): the look's on icon-coloured items,
// none on a modeller's (looks.gd roughness_min; --pbr-rough=floor puts it on theirs too).
global uniform float f3d_look_roughness_min;
global uniform float f3d_look_roughness_min_pbr;
#include "res://shaders/pbr_env.gdshaderinc"
global uniform float f3d_look_model_fill;
global uniform vec2 f3d_look_texture_light;

bool item_pbr_on() {
	return pbr && f3d_pack_shading > 0.5;
}

// glTF's metallic-roughness picture: G roughness, B metal (times the factors); x roughness, y metal.
vec2 item_pbr_surface(vec2 uv) {
	vec2 rm = vec2(pbr_roughness, pbr_metallic * f3d_look_pbr_metal);
	if (use_orm) {
		vec3 orm = texture(orm_picture, uv).rgb;
		rm *= vec2(orm.g, orm.b);
	}
	rm.x = max(rm.x, f3d_look_roughness_min_pbr);
	return rm;
}

// The normal map in a cotangent frame from the UVs' screen slopes (the meshes carry no real tangents),
// its handedness from the slopes themselves, as factorio_material's modeller_tex path.
vec3 item_pbr_normal(vec3 n_in, vec3 vertex, vec2 uv) {
	if (!use_normal) {
		return n_in;
	}
	vec3 nm = texture(normal_picture, uv).rgb * 2.0 - 1.0;
	nm.xy *= normal_scale;
	vec3 n0 = normalize(n_in);
	vec3 dp1 = dFdx(vertex);
	vec3 dp2 = dFdy(vertex);
	vec2 duv1 = dFdx(uv);
	vec2 duv2 = dFdy(uv);
	vec3 dp2perp = cross(dp2, n0);
	vec3 dp1perp = cross(n0, dp1);
	vec3 t = dp2perp * duv1.x + dp1perp * duv2.x;
	vec3 b = dp2perp * duv1.y + dp1perp * duv2.y;
	float hand = dot(dp1, dp2perp) < 0.0 ? -1.0 : 1.0;
	float inv = inversesqrt(max(max(dot(t, t), dot(b, b)), 1e-20));
	vec3 n = normalize(mat3(t * inv * hand, -b * inv * hand, n0) * nm);
	return any(isnan(n)) ? n0 : n;
}

// The look's balance of light on the picture by the way the surface faces (world up 0-1).
vec3 item_pbr_albedo(vec3 albedo, float up) {
	return albedo * mix(f3d_look_texture_light.x, f3d_look_texture_light.y, up);
}

vec3 item_pbr_fill(vec3 albedo, vec3 n, vec3 view) {
	return albedo * f3d_look_model_fill * pbr_fill_share() * (0.35 + 0.65 * max(dot(n, view), 0.0));
}

// A modeller's item model drawn by its file's own materials, one per surface (item_models.gd own_look,
// dressed; item_own.gdshader, belt_lane_model.gdshader's `own`), whatever its pack's shading: its colour
// and picture with their alpha, roughness and metal, normal map (above) and emission. See-through
// surfaces (alpha_mode 2) are blended in the transparent pass by the _blend twins (item_models.gd dressed);
// with `--item-glass=dither` they are dithered in the opaque pass here instead.
uniform int alpha_mode = 0;  // 0 opaque, 1 cut out at alpha_clip (glTF MASK), 2 see-through (BLEND)
uniform float alpha_clip = 0.5;
uniform vec4 emission : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy = 1.0;
uniform bool use_emission_picture = false;
uniform sampler2D emission_picture : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;

// glTF's emission: its factor times its picture.
vec3 item_own_emission(vec2 uv) {
	vec3 e = emission.rgb * emission_energy;
	if (use_emission_picture) {
		e *= texture(emission_picture, uv).rgb;
	}
	return e;
}

// Whether the pixel at `frag` is left out at alpha `a`.
bool item_own_cut(float a, vec2 frag) {
	if (alpha_mode == 1) {
		return a < alpha_clip;
	}
	if (alpha_mode == 2) {
		return a < fract(52.9829189 * fract(dot(frag, vec2(0.06711056, 0.00583715))));
	}
	return false;
}
