shader_type spatial;
// belt_lanes.gd with Items on belts set to 3D models (and Items in 3D at All): far belts' items as
// their small models instead of icons, placed as the icons are. Colours in the vertices, as
// item.gdshader's; left out on the belts belt_items.gd draws and past the distance, as
// belt_lane_icon.gdshader's (the belt's centre in the instance's custom data).
render_mode world_vertex_coords, shadows_disabled;

#include "res://shaders/ground_height.gdshaderinc"

uniform float exposure = 0.75;
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
	ALBEDO = COLOR.rgb * exposure;
	ROUGHNESS = 0.8;
}
