// A look's full-screen pass (scripts/world/looks.gd; add-ons: api.shaders, docs/ADDONS.md).
// Include it at the top of a spatial shader and write only fragment():
//
//   shader_type spatial;
//   #include "res://shaders/look_pass.gdshaderinc"
//   uniform float strength = 1.0;
//   void fragment() {
//       vec3 c = scene_color(SCREEN_UV);            // the solid scene, linear HDR, before tonemapping
//       ALBEDO = mix(c, vec3(luma(c)), strength);   // what goes on screen instead
//   }
//
// scene_normal_roughness() is there only with `#define LOOK_PASS_NORMALS` before the #include: it costs
// the depth pre-pass writing normals for every pixel (see below).
//
// The pass covers the screen in Godot's transparent pass, before every other see-through thing, and
// reads the scene as it was then (Godot copies the screen once a frame): smoke, ghosts and icons
// drawn after it aren't graded. Colours are linear and may go over 1; tonemapping and Factorio's
// colour lookup come after it. Zenith sets these every frame: look_daytime (0 noon, 0.5 midnight),
// look_night (0-1), and for the sun (add-on API 1.5): look_sun_height (the sine of its elevation, -1
// to 1), look_twilight (0-1: 1 with the sun at the horizon, in a look that has a sunset),
// look_morning (1 past midnight), look_sun_dir (towards the sun), look_sun_color, look_ambient_color,
// and look_space (1 on a space platform, where there is no weather: a pass's clouds or rain stay off).

render_mode unshaded, fog_disabled, depth_test_disabled, depth_draw_never, cull_disabled, shadows_disabled;

uniform sampler2D look_screen : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D look_depth : hint_depth_texture, filter_nearest, repeat_disable;
#ifdef LOOK_PASS_NORMALS
// Only for a pass that defines LOOK_PASS_NORMALS before including this: a shader that merely declares
// a normal-roughness texture makes Godot's depth pre-pass write every pixel's normal and roughness
// (as SSAO does), about half a millisecond at a busy base on a desktop GPU whether it is read or not.
uniform sampler2D look_normal_roughness : hint_normal_roughness_texture, filter_nearest, repeat_disable;
#endif
uniform float look_daytime = 0.0;
uniform float look_night = 0.0;
uniform float look_sun_height = 0.87;
uniform float look_twilight = 0.0;
uniform float look_morning = 0.0;
uniform vec3 look_sun_dir = vec3(0.25, 0.87, 0.43);
uniform vec3 look_sun_color : source_color = vec3(1.0, 0.95, 0.88);
uniform vec3 look_ambient_color : source_color = vec3(0.7, 0.76, 0.85);
uniform float look_space = 0.0;
// The scene's light against what the game set (the debug menu's sliders): x the ambient's share, y the sun's.
uniform vec2 look_scene_light = vec2(1.0);
uniform float look_focus_dist = 0.0;
uniform float look_pre_aa = 0.0;
// 1.0 while AMD FSR 2.2 is active (with fixes enabled): passes skip pre-resolve sharpen/grain/aberration.
uniform float look_fsr2 = 0.0;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

// The brightest a pass reads, many times anything lit: a sun glint can come out of the screen as
// thousands, or as inf where the half-float screen overflows, and as NaN from bad maths upstream.
// Either spreads through the blurred mips into whole blocks (B-roll: white specks in black boxes on
// Aquilo's and Gleba's water), so every read is made finite here: NaN reads as black, inf as this.
const float LOOK_HDR_MAX = 64.0;

vec3 finite_hdr(vec3 c) {
	c = vec3(isnan(c.r) ? 0.0 : c.r, isnan(c.g) ? 0.0 : c.g, isnan(c.b) ? 0.0 : c.b);
	return clamp(c, vec3(0.0), vec3(LOOK_HDR_MAX));
}

vec3 scene_color_fast(vec2 uv) {
	return finite_hdr(textureLod(look_screen, uv, 0.0).rgb);
}

float _look_aa_luma(vec3 c) {
	float y = dot(c, vec3(0.299, 0.587, 0.114));
	return sqrt(max(y, 0.0) / (1.0 + max(y, 0.0)));
}

// The solid scene's colour (linear, HDR, finite); when look_pre_aa > 0 (FXAA/SMAA active under a
// look pass), smooths high-contrast edges in perceptual luma before sharpening, grading and grain run.
vec3 scene_color(vec2 uv) {
	vec3 rgbM = finite_hdr(textureLod(look_screen, uv, 0.0).rgb);
	if (look_pre_aa <= 0.01) {
		return rgbM;
	}
	vec2 inv_sz = 1.0 / max(vec2(textureSize(look_screen, 0)), vec2(1.0));
	float lM = _look_aa_luma(rgbM);
	float lN = _look_aa_luma(finite_hdr(textureLod(look_screen, uv + vec2(0.0, -inv_sz.y), 0.0).rgb));
	float lS = _look_aa_luma(finite_hdr(textureLod(look_screen, uv + vec2(0.0, inv_sz.y), 0.0).rgb));
	float lW = _look_aa_luma(finite_hdr(textureLod(look_screen, uv + vec2(-inv_sz.x, 0.0), 0.0).rgb));
	float lE = _look_aa_luma(finite_hdr(textureLod(look_screen, uv + vec2(inv_sz.x, 0.0), 0.0).rgb));
	float lMax = max(lM, max(max(lN, lS), max(lW, lE)));
	float lMin = min(lM, min(min(lN, lS), min(lW, lE)));
	float lRange = lMax - lMin;
	if (lRange < max(0.0312, lMax * 0.0833)) {
		return rgbM;
	}
	float lNW = _look_aa_luma(finite_hdr(textureLod(look_screen, uv + vec2(-inv_sz.x, -inv_sz.y), 0.0).rgb));
	float lNE = _look_aa_luma(finite_hdr(textureLod(look_screen, uv + vec2(inv_sz.x, -inv_sz.y), 0.0).rgb));
	float lSW = _look_aa_luma(finite_hdr(textureLod(look_screen, uv + vec2(-inv_sz.x, inv_sz.y), 0.0).rgb));
	float lSE = _look_aa_luma(finite_hdr(textureLod(look_screen, uv + vec2(inv_sz.x, inv_sz.y), 0.0).rgb));
	float lNS = lN + lS;
	float lEW = lE + lW;
	float lAvg = (2.0 * (lNS + lEW) + (lNW + lNE) + (lSW + lSE)) * (1.0 / 12.0);
	float subpix = smoothstep(0.0, 1.0, clamp(abs(lAvg - lM) / lRange, 0.0, 1.0));
	subpix = subpix * subpix * mix(0.55, 0.80, clamp((look_pre_aa - 0.75) * 4.0, 0.0, 1.0));
	float edgeH = abs(lNW + lNE - 2.0 * lN) + abs(lW + lE - 2.0 * lM) * 2.0 + abs(lSW + lSE - 2.0 * lS);
	float edgeV = abs(lNW + lSW - 2.0 * lW) + abs(lN + lS - 2.0 * lM) * 2.0 + abs(lNE + lSE - 2.0 * lE);
	bool is_h = edgeH >= edgeV;
	float l1 = is_h ? lN : lW;
	float l2 = is_h ? lS : lE;
	float g1 = abs(l1 - lM);
	float g2 = abs(l2 - lM);
	bool p1 = g1 >= g2;
	float lSteep = p1 ? l1 : l2;
	float grad_max = 0.25 * max(g1, g2);
	vec2 step_dir = is_h ? vec2(0.0, p1 ? -inv_sz.y : inv_sz.y) : vec2(p1 ? -inv_sz.x : inv_sz.x, 0.0);
	vec2 tangent = is_h ? vec2(inv_sz.x, 0.0) : vec2(0.0, inv_sz.y);
	vec2 uv_edge = uv + step_dir * 0.5;
	float lEdge = 0.5 * (lM + lSteep);
	const float AA_STEPS[5] = float[5](1.0, 1.5, 2.0, 2.5, 4.0);
	vec2 uvP = uv_edge + tangent;
	vec2 uvN = uv_edge - tangent;
	float dP = _look_aa_luma(finite_hdr(textureLod(look_screen, uvP, 0.0).rgb)) - lEdge;
	float dN = _look_aa_luma(finite_hdr(textureLod(look_screen, uvN, 0.0).rgb)) - lEdge;
	bool doneP = abs(dP) >= grad_max;
	bool doneN = abs(dN) >= grad_max;
	for (int i = 1; i < 5; i++) {
		if (doneP && doneN) {
			break;
		}
		if (!doneP) {
			uvP += tangent * AA_STEPS[i];
			dP = _look_aa_luma(finite_hdr(textureLod(look_screen, uvP, 0.0).rgb)) - lEdge;
			doneP = abs(dP) >= grad_max;
		}
		if (!doneN) {
			uvN -= tangent * AA_STEPS[i];
			dN = _look_aa_luma(finite_hdr(textureLod(look_screen, uvN, 0.0).rgb)) - lEdge;
			doneN = abs(dN) >= grad_max;
		}
	}
	float distP = is_h ? (uvP.x - uv.x) : (uvP.y - uv.y);
	float distN = is_h ? (uv.x - uvN.x) : (uv.y - uvN.y);
	bool min_is_N = distN < distP;
	float min_dist = min(distP, distN);
	float span = max(distP + distN, 1e-6);
	float dEnd = min_is_N ? dN : dP;
	bool good_span = (lM < lEdge) ? (dEnd >= 0.0) : (dEnd < 0.0);
	float edge_blend = good_span ? max(0.0, 0.5 - min_dist / span) : 0.0;
	float final_blend = max(subpix, edge_blend) * clamp(look_pre_aa, 0.0, 1.0);
	if (final_blend <= 0.001) {
		return rgbM;
	}
	return finite_hdr(textureLod(look_screen, uv + step_dir * final_blend, 0.0).rgb);
}

vec3 scene_color_blurred(vec2 uv, float blur) {
	return finite_hdr(textureLod(look_screen, uv, blur).rgb);
}

// The depth buffer's value (reversed-Z: 1 near, 0 far, as Godot's Vulkan renderer writes it).
float scene_depth_raw(vec2 uv) {
	return texture(look_depth, uv).r;
}

// How far the scene is from the camera at uv, in tiles along the view (needs INV_PROJECTION_MATRIX).
float scene_distance(vec2 uv, mat4 inv_projection) {
	vec4 v = inv_projection * vec4(uv * 2.0 - 1.0, scene_depth_raw(uv), 1.0);
	return -v.z / v.w;
}

#ifdef LOOK_PASS_NORMALS
// The scene's normal (view space, unit length) and roughness at uv (with LOOK_PASS_NORMALS).
vec4 scene_normal_roughness(vec2 uv) {
	vec4 nr = texture(look_normal_roughness, uv);
	return vec4(normalize(nr.xyz * 2.0 - 1.0), nr.w);
}
#endif

float luma(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

vec3 to_srgb(vec3 c) {
	return mix(12.92 * c, 1.055 * pow(max(c, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

vec3 to_linear(vec3 c) {
	return mix(c / 12.92, pow((max(c, vec3(0.0)) + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}
