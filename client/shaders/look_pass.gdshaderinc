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

// The solid scene's colour (linear, HDR, finite); `blur` > 0 reads a mip that much smaller (a soft copy).
vec3 scene_color(vec2 uv) {
	return finite_hdr(textureLod(look_screen, uv, 0.0).rgb);
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
