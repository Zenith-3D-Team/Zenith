shader_type spatial;
// belt_lanes.gd: one item icon per belt lane, lying on the belt, cut out by the icon's alpha. Left
// out on the belts whose items belt_items.gd draws (the belt's centre, in the instance's custom data,
// inside the square the items were read round) and past the chosen distance.
render_mode world_vertex_coords, cull_disabled, shadows_disabled;

#include "res://shaders/icon_lod.gdshaderinc"
#include "res://shaders/ground_height.gdshaderinc"
#include "res://shaders/lamp_light.gdshaderinc"

uniform sampler2D icon : source_color, filter_linear_mipmap_anisotropic;
uniform vec2 focus = vec2(0.0);
uniform float near = 22.0;
uniform float far = 160.0;
uniform bool vcull = true;

varying vec2 world_xz;
varying flat vec2 belt;

void vertex() {
	world_xz = VERTEX.xz;
	belt = INSTANCE_CUSTOM.xy;
	vec2 d_belt = abs(belt - focus);
	if (vcull && (max(d_belt.x, d_belt.y) < near || length(belt - focus) > far + 1.0)) {
		VERTEX = vec3(0.0, -1e6, 0.0);
	} else {
		VERTEX.y += ground_h(VERTEX.xz);  // world coordinates here
	}
}

void fragment() {
	vec2 d = abs(belt - focus);
	// The near area is a square of belts, as the mod reads them: a belt is in it or not, whole.
	if (max(d.x, d.y) < near || length(world_xz - focus) > far) {
		discard;
	}
	vec4 c = icon_texel(icon, UV);
	ALBEDO = c.rgb;
	EMISSION = lamp_light_emission(ALBEDO, world_xz, 0.25, 1.0);
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 0.9;
}
