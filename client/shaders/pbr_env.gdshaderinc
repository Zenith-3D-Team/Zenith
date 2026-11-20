// The neutral reflection a "pbr" pack's surfaces see (pbr-standard step 3), for factorio_material.gdshaderinc's
// modeller_tex path and item_pbr.gdshaderinc: instead of the planet's blue sky (which left full metal dark and
// blue), an upper half lit as the moment is lit (ambient plus k of the sun, looks.gd pbr_env), a lower half at
// 0.45 of it, blended across the horizon over a width that grows with roughness. Written to Godot's RADIANCE,
// which replaces the sky's sample before its split-sum BRDF, multiscatter compensation and specular occlusion
// (Godot 4.7 scene_forward_clustered.glsl), so metal reflects it as it would a grey world. Built-in packs never
// write it. A gradient, not a picture: mirror-smooth metal shows it bland.
//
// Lit by direction (pbr-light-balance, looks.gd pbr_fill / pbr_ambient, on unless --pbr-light=flat): the sun's
// k share comes from a broad lobe towards the sun (PBR_SUN_LOBE t^2, t = (1 + cos) / 2: about the whole sphere's
// mean as before, none from straight opposite) and the ambient's from the sky above to PBR_GROUND of it below, so the side away
// from the sun reflects little more than the dim sky; and the ambient light (IRRADIANCE) the same sky-to-ground
// gradient by the way the surface faces, at the look's pbr_ambient share. Flat: as before, uniform all round.
//
// Since lighting-fixes step 1 the game lights every material from the sky's cubemap instead (planet_sky.gdshader's
// lighting environment, looks.gd put_light_env): f3d_light_env 1 and both functions return alpha 0, so Godot's own
// ambient and reflection are used. --light-env=shader (and the menu and model preview, f3d_light_env 0) keeps this.
#ifndef PBR_ENV_INC
#define PBR_ENV_INC

// 1: the scene's lighting environment (the sky's cubemap) lights "pbr" surfaces too; 0: the terms below.
global uniform float f3d_light_env;

// rgb: the upper half's light; a: 1 on, 0 off (--pbr-env=off: the sky's reflection, as in 0.2.2).
global uniform vec4 f3d_pbr_env;
// x: 1 lit by direction, 0 flat (--pbr-light=flat, and outside a game); y: the share of the look's fill;
// z: the share of the ambient; w: the fill's share for the scene's ambient (the debug menu's slider over the game's,
// 1 untouched; looks.gd _put_pbr_scene, pbr_fill_scene), already in f3d_look_model_fill, so not read here.
global uniform vec4 f3d_pbr_light;
// rgb: the ambient light now, linear (the part of f3d_pbr_env that isn't the sun's).
global uniform vec4 f3d_pbr_sky;
// xyz: towards the sun, world space.
global uniform vec4 f3d_pbr_sun;

// x: the sun lobe's height (3 keeps the sphere's mean, times 0.42 / 0.45, the k where rough metal meets paint lit by
// direction (ui_test.gd _pbr_look: 0.38 at roughness 0.7, 0.45 at 1) over the look's default, looks.gd PBR_ENV);
// y: the ambient and reflection straight below, as a share of the sky's (the ground, lit by both, reflects about
// this). Defaults looks.gd PBR_SUN_LOBE and PBR_GROUND; the debug menu's Lighting tab moves them.
global uniform vec4 f3d_pbr_tune;
#define PBR_SUN_LOBE (f3d_pbr_tune.x)
#define PBR_GROUND (f3d_pbr_tune.y)

bool pbr_directional() {
	return f3d_pbr_light.x > 0.5;
}

// The share of the look's fill a "pbr" surface gets: pbr_fill lit by direction, all of it flat. The fill itself
// already follows the scene's ambient (looks.gd puts f3d_look_model_fill times f3d_pbr_light.w).
float pbr_fill_share() {
	return pbr_directional() ? clamp(f3d_pbr_light.y, 0.0, 2.0) : 1.0;
}

// RADIANCE for a surface (view space `view` towards the eye, `normal`, `rough` its roughness), bent towards the
// normal by roughness squared as Godot bends its own sky lookup.
vec4 pbr_env_radiance(vec3 view, vec3 normal, float rough, mat4 inv_view) {
	vec3 r = normalize(mix(reflect(-view, normal), normal, rough * rough));
	vec3 rw = (inv_view * vec4(r, 0.0)).xyz;
	float w = 0.1 + 0.5 * rough;
	float h = smoothstep(-w, w, rw.y);
	vec3 up = max(f3d_pbr_env.rgb, vec3(0.0));
	float on = clamp(f3d_pbr_env.a, 0.0, 1.0) * step(f3d_light_env, 0.5);
	if (!pbr_directional()) {
		return vec4(mix(up * 0.45, up, h), on);
	}
	vec3 sky = min(max(f3d_pbr_sky.rgb, vec3(0.0)), up);
	float t = 0.5 + 0.5 * dot(rw, normalize(f3d_pbr_sun.xyz));
	vec3 col = sky * clamp(f3d_pbr_light.z, 0.0, 2.0) * mix(PBR_GROUND, 1.0, h) + (up - sky) * (PBR_SUN_LOBE * t * t) * mix(0.45, 1.0, h);
	return vec4(col, on);
}

// IRRADIANCE for a surface (view space `normal`): lit by direction, the ambient from the sky above to PBR_GROUND of
// it below at the pbr_ambient share; flat, alpha 0 (the scene's ambient, as before).
vec4 pbr_irradiance(vec3 normal, mat4 inv_view) {
	float y = (inv_view * vec4(normal, 0.0)).y;
	vec3 sky = max(f3d_pbr_sky.rgb, vec3(0.0)) * clamp(f3d_pbr_light.z, 0.0, 2.0);
	return vec4(sky * mix(PBR_GROUND, 1.0, 0.5 + 0.5 * y), pbr_directional() && f3d_light_env < 0.5 ? 1.0 : 0.0);
}

#endif
