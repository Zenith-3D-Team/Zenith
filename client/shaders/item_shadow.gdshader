// Shadow-only stand-in shader for belt items (item_cards.gd, item_models.gd shadow_box_mesh):
// places the lightweight AABB proxy on the GPU via belt_place() without reading variants,
// collapsing instances hidden by belt_place() or beyond shadow_max_sq from shadow_cam.
shader_type spatial;
render_mode world_vertex_coords;

#define BELT_IGNORE_VARIANTS
#define BELT_NO_VIEW_CULL
#include "res://shaders/belt_path.gdshaderinc"
#include "res://shaders/ground_height.gdshaderinc"

uniform vec3 shadow_cam = vec3(0.0);
uniform float shadow_max_sq = 0.0;

void vertex() {
	if (belt_base >= 0) {
		vec3 o = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
		vec3 ax = (MODEL_MATRIX * vec4(1.0, 0.0, 0.0, 0.0)).xyz;
		vec3 local_v = VERTEX;
		belt_place(o, ax, INSTANCE_ID);
		float d2 = dot(o - shadow_cam, o - shadow_cam);
		if (o == vec3(0.0) || (shadow_max_sq > 0.0 && d2 > shadow_max_sq)) {
			VERTEX = vec3(0.0);
		} else {
			if (shadow_max_sq > 0.0) {
				float max_d = sqrt(shadow_max_sq);
				local_v *= 1.0 - smoothstep(max_d * 0.78, max_d, sqrt(d2));
			}
			VERTEX = vec3(ax.x * local_v.x - ax.z * local_v.z, local_v.y, ax.z * local_v.x + ax.x * local_v.z) + o;
			VERTEX.y += ground_h(o.xz);
		}
	} else {
		VERTEX.y += ground_h(VERTEX.xz);
	}
}

void fragment() {
}
