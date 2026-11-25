// Shared shader logic for Distant Horizon quadtree LOD sections (lod_mesher.gd, distant_horizon.gd).
// Defines LOD_SOLID or LOD_WATER, plus optional LOD_MASKED (discarding chunks already drawn in full
// detail so LOD 1-4 keep zero `discard` instructions and preserve hardware Early-Z).
//
// Vertex layout:
//   COLOR.rgb  sqrt-encoded linear albedo
//   COLOR.a    (round(roughness * 15) + 16 * round(metallic * 15)) / 255.0
//   UV.x       glow in [0, 1]
//   UV.y       kind flag * 0.25 (0: normal solid, 1: lava/always-lit, 2: tree/matte, 3: ground/ore,
//              4: a cliff, shaded as 0 and seated as the near cliffs are)

#include "res://shaders/noise.gdshaderinc"
#include "res://shaders/ground_height.gdshaderinc"
#include "res://shaders/pollution.gdshaderinc"
#include "res://shaders/lamp_light.gdshaderinc"

global uniform float f3d_tree_matte;
global uniform float f3d_look_model_fill;
global uniform float f3d_look_ground_specular;

uniform vec3 horizon_color : source_color = vec3(0.7, 0.8, 0.88);
uniform float fade_start = 4096.0;
uniform float fade_end = 8192.0;
uniform float night_level = 0.0;
uniform float glow_strength = 1.0;
uniform float is_space = 0.0;
uniform sampler2D lod_far_pollution : filter_nearest, repeat_disable;
uniform vec4 lod_far_pollution_rect = vec4(0.0, 0.0, 128.0, 0.0);

#ifdef LOD_MASKED
uniform sampler2D loaded_mask : filter_nearest, repeat_disable;
uniform vec2 mask_origin_chunk = vec2(0.0);
uniform float mask_size = 128.0;
#endif

#ifdef LOD_WATER
uniform vec3 sky_tint : source_color = vec3(0.50, 0.62, 0.72);
#endif

varying vec2 world_xz;
varying float world_y;

#ifdef LOD_MASKED
float lod_mask_level(vec2 xz) {
	vec2 c = floor(xz / 32.0);
	vec2 p = c - mask_origin_chunk;
	if (p.x >= 0.0 && p.y >= 0.0 && p.x < mask_size && p.y < mask_size) {
		return texelFetch(loaded_mask, ivec2(p), 0).r;
	}
	return 0.0;
}

float lod_bayer4(vec2 frag_xy) {
	int bx = int(frag_xy.x) & 3;
	int by = int(frag_xy.y) & 3;
	int ba = bx ^ by;
	int bayer = ((ba & 1) << 3) | ((by & 1) << 2) | (ba & 2) | ((by & 2) >> 1);
	return (float(bayer) + 0.5) / 16.0;
}
#endif

float lod_horizon_fade(vec2 xz, vec2 cam_xz) {
	float d = length(xz - cam_xz);
	return (1.0 - step(0.5, is_space)) * smoothstep(fade_start, max(fade_end, fade_start + 1.0), d);
}

float lod_far_pol_texel(ivec2 i, ivec2 size) {
	if (i.x < 0 || i.y < 0 || i.x >= size.x || i.y >= size.y) {
		return 0.0;
	}
	return texelFetch(lod_far_pollution, i, 0).r;
}

float lod_pollution_dying(vec2 xz) {
	if (f3d_pollution_rect.w > 0.5) {
		ivec2 nsize = textureSize(f3d_pollution, 0);
		vec2 ng = (xz - f3d_pollution_rect.xy) / f3d_pollution_rect.z - 0.5;
		if (ng.x >= 0.0 && ng.y >= 0.0 && ng.x <= float(nsize.x - 1) && ng.y <= float(nsize.y - 1)) {
			return clamp(pollution_at(xz).x, 0.0, 1.0);
		}
	}
	if (lod_far_pollution_rect.w > 0.5) {
		ivec2 fsize = textureSize(lod_far_pollution, 0);
		vec2 fg = (xz - lod_far_pollution_rect.xy) / lod_far_pollution_rect.z - 0.5;
		if (fg.x >= -1.0 && fg.y >= -1.0 && fg.x <= float(fsize.x) && fg.y <= float(fsize.y)) {
			ivec2 fi = ivec2(floor(fg));
			vec2 ff = fg - vec2(fi);
			float a = mix(lod_far_pol_texel(fi, fsize), lod_far_pol_texel(fi + ivec2(1, 0), fsize), ff.x);
			float b = mix(lod_far_pol_texel(fi + ivec2(0, 1), fsize), lod_far_pol_texel(fi + ivec2(1, 1), fsize), ff.x);
			return clamp(mix(a, b, ff.y), 0.0, 1.0);
		}
	}
	return 0.0;
}

#ifdef LOD_SOLID
void vertex() {
	vec3 local_v = VERTEX;
	vec3 world_pre = (MODEL_MATRIX * vec4(local_v, 1.0)).xyz;
	int vkind = int(round(clamp(UV.y, 0.0, 1.0) * 4.0));
	if (vkind == 2 && local_v.y > 0.01) {
		float p = lod_pollution_dying(world_pre.xz);
		if (p > 0.0) {
			float tseed = hash12(floor(world_pre.xz * 0.25) * 3.17 + 0.5);
			float tdying = clamp(p * 1.3 - 0.3 * tseed, 0.0, 1.0);
			local_v.y *= mix(1.0, 0.30, smoothstep(0.20, 0.98, tdying));
		}
	}
	world_xz = world_pre.xz;
	world_y = (MODEL_MATRIX * vec4(local_v, 1.0)).y;
	// A cliff's block (kind 4) seated as the near cliff models are (ground_lift_cliff): its foot on the low
	// ground, its top at the near rock's, never under the high ground. Lifted by the terraced ground it
	// stood a whole block over the plateau's edge. --cliff-fit=off: by the ground, as before.
	if (vkind == 4 && f3d_cliff_fit > 0.5) {
		VERTEX = ground_lift_cliff(local_v, MODEL_MATRIX);
	} else {
		VERTEX = ground_lift(local_v, MODEL_MATRIX);
	}
#ifdef LOD_MASKED
	if (vkind == 3 || local_v.y <= 0.02) {
		VERTEX.y -= 0.015;
	}
#endif
}

void fragment() {
#ifdef LOD_MASKED
	float ml = lod_mask_level(world_xz);
	if (ml >= 0.995) {
		discard;
	}
#endif
	vec3 col = clamp(COLOR.rgb, 0.0, 1.0);
	col *= col;

	float packed = floor(clamp(COLOR.a, 0.0, 1.0) * 255.0 + 0.5);
	float rough = mod(packed, 16.0) / 15.0;
	float metal = floor(packed / 16.0) / 15.0;

	float glow = clamp(UV.x, 0.0, 1.0);
	int kind = int(round(clamp(UV.y, 0.0, 1.0) * 4.0));

#ifdef LOD_MASKED
	if (ml > 0.01) {
		if (kind == 3 || world_y <= 0.02) {
			discard;
		} else if (lod_bayer4(FRAGCOORD.xy) < ml) {
			discard;
		}
	}
#endif

	vec3 face = cross(dFdx(VERTEX), dFdy(VERTEX));
	vec3 n = dot(face, face) > 1e-20 ? normalize(face) : vec3(0.0, 0.0, 1.0);
	NORMAL = dot(n, VIEW) < 0.0 ? -n : n;
	float up = clamp((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y, 0.0, 1.0);
	if (kind == 3 && up > 0.5) {
		vec3 gn = ground_n(world_xz);
		NORMAL = normalize((VIEW_MATRIX * vec4(gn, 0.0)).xyz);
		up = clamp(gn.y, 0.0, 1.0);
	}

	float spec = mix(0.5, 0.25, rough);
	vec3 em = vec3(0.0);

	if (kind == 1) {
		// Lava / always-lit molten rock (glows day and night)
		float n_lava = vnoise(world_xz * 0.12);
		col *= 0.85 + 0.3 * n_lava;
		rough = 0.6;
		metal = 0.0;
		spec = 0.2;
		em = col * (1.1 + 0.5 * n_lava) * max(glow, 0.5);
	} else if (kind == 2) {
		// Trees / matte foliage with pollution dying tint
		float pol = lod_pollution_dying(world_xz);
		if (pol > 0.0) {
			float tseed = hash12(floor(world_xz * 0.25) * 3.17 + 0.5);
			float dying = clamp(pol * 1.3 - 0.3 * tseed, 0.0, 1.0);
			if (dying > 0.0) {
				float lum = dot(col, vec3(0.3, 0.59, 0.11));
				vec3 grey = mix(col, vec3(lum), smoothstep(0.0, 0.45, dying));
				col = mix(grey, lum * vec3(1.05, 0.88, 0.62) * mix(1.0, 0.72, smoothstep(0.45, 1.0, dying)), smoothstep(0.3, 0.8, dying));
			}
		}
		rough = mix(max(rough, 0.85), 1.0, f3d_tree_matte);
		metal = 0.0;
		spec = mix(0.2, 0.05, f3d_tree_matte);
	} else if (kind == 3) {
		// Ground & ore patches: subtle broad organic variation + Factorio ground specular
		float broad = vnoise(world_xz * 0.045);
		float mid = vnoise(world_xz * 0.22 + 13.7);
		col *= 1.0 + 0.14 * (broad - 0.5) + 0.07 * (mid - 0.5);
		spec = 0.15 * f3d_look_ground_specular;
	} else {
		// Buildings, cliffs, low structures
		float grime = (1.0 - up) * (1.0 - smoothstep(0.0, 0.45, world_y));
		col = mix(col, vec3(0.13, 0.11, 0.09), 0.25 * grime);
		em = col * f3d_look_model_fill * (0.35 + 0.65 * max(dot(NORMAL, VIEW), 0.0));
		if (glow > 0.0 && night_level > 0.01 && glow_strength > 0.0) {
			float pin = 0.45 + 0.55 * smoothstep(0.30, 0.85, vnoise(world_xz * 0.25 + 3.1));
			vec3 glow_col = mix(col, vec3(1.0, 0.78, 0.45), 0.55);
			em += glow_col * (glow * 0.34 * pin) * night_level * glow_strength;
		}
	}
	if (kind != 1) {
		em += lamp_light_emission(col, world_xz, max(world_y, 0.0), up);
	}

	float fade = lod_horizon_fade(world_xz, CAMERA_POSITION_WORLD.xz);
	ALBEDO = col * (1.0 - fade);
	ROUGHNESS = rough;
	METALLIC = metal;
	SPECULAR = spec * (1.0 - fade);
	EMISSION = em * (1.0 - fade) + horizon_color * fade;
}
#endif

#ifdef LOD_WATER
void vertex() {
	vec3 world_pre = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_xz = world_pre.xz;
	world_y = world_pre.y;
#ifdef LOD_MASKED
	VERTEX.y -= 0.015;
#endif
}

void fragment() {
#ifdef LOD_MASKED
	if (lod_mask_level(world_xz) > 0.01) {
		discard;
	}
#endif
	vec3 water = clamp(COLOR.rgb, 0.0, 1.0);
	water *= water;

	float dist = length(world_xz - CAMERA_POSITION_WORLD.xz);
	float ripple_att = 1.0 - smoothstep(150.0, 800.0, dist);
	float t = TIME * 0.8;
	vec3 a = noised(world_xz * 0.35 + vec2(t * 0.11, t * 0.07));
	vec3 b = noised(world_xz * 1.1 + vec2(-t * 0.16, t * 0.11) + 13.1);
	vec2 grad = ripple_att * (a.yz * 0.35 * 0.22 + b.yz * 1.1 * 0.07);
	vec3 n = normalize(vec3(-grad.x, 1.0, -grad.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);

	float fouled = lod_pollution_dying(world_xz);
	float sky_share = 1.0;
	if (fouled > 0.0) {
		float lum = dot(water, vec3(0.3, 0.59, 0.11));
		vec3 algae = lum * vec3(0.8, 1.25, 0.45) + vec3(0.015, 0.04, 0.0);
		water = mix(water, algae, 0.8 * smoothstep(0.0, 0.7, fouled));
		sky_share *= 1.0 - 0.5 * fouled;
	}

	float wobble = 0.85 + 0.15 * (a.x * 0.6 + b.x * 0.4) * ripple_att;
	vec3 base = water * wobble;
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = 0.08 + 0.92 * pow(1.0 - facing, 4.0);
	vec3 col = mix(base, sky_tint, clamp(fresnel * mix(0.42, 0.60, ripple_att), 0.0, mix(0.28, 0.40, ripple_att)) * sky_share);
	vec3 water_em = lamp_light_emission(col, world_xz, 0.0, 1.0) * 0.85;
	float fade = lod_horizon_fade(world_xz, CAMERA_POSITION_WORLD.xz);
	ALBEDO = col * (1.0 - fade);
	ROUGHNESS = mix(0.46, 0.18, ripple_att);
	METALLIC = 0.0;
	SPECULAR = mix(0.42, 0.60, ripple_att) * (1.0 - fade);
	EMISSION = water_em * (1.0 - fade) + horizon_color * fade;
}
#endif
