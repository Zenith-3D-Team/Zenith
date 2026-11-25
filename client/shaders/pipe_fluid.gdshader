shader_type spatial;
// Fluid inside windowed straight pipes (fluids_power.gd): draws a clipped horizontal fluid column
// from INSTANCE_CUSTOM.r fill level and COLOR.rgb linear fluid colour, animating flow bands along
// the pipe's world axis and riding terrain hills with ground_lift().
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/ground_height.gdshaderinc"

global uniform float f3d_anim_time;
global uniform float f3d_look_model_fill;

varying vec3 fluid_color;
varying float flow_u;
varying float cross_v;
varying float is_surface;

void vertex() {
	fluid_color = COLOR.rgb;
	float fill = clamp(INSTANCE_CUSTOM.r, 0.02, 1.0);
	float top_y = mix(-0.88, 1.0, fill);
	bool is_cap = abs(NORMAL.z) > 0.5;
	is_surface = (!is_cap && VERTEX.y >= top_y - 0.04) ? 1.0 : 0.0;
	if (VERTEX.y > top_y) {
		VERTEX.y = top_y;
		float max_x = sqrt(max(0.0, 1.0 - top_y * top_y));
		VERTEX.x = clamp(VERTEX.x, -max_x, max_x);
		if (!is_cap) {
			NORMAL = vec3(0.0, 1.0, 0.0);
		}
	}
	vec2 axis = normalize(MODEL_MATRIX[2].xz + vec2(1e-6, 0.0));
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	flow_u = dot(wp.xz, axis);
	cross_v = VERTEX.x;
	VERTEX = ground_lift(VERTEX, MODEL_MATRIX);
}

void fragment() {
	float t = f3d_anim_time;
	float w1 = sin(flow_u * 9.0 - t * 3.2 + sin(cross_v * 4.5 + flow_u * 2.5) * 0.65);
	float w2 = sin(flow_u * 17.0 - t * 5.1 - cross_v * 5.0);
	float band = clamp(0.5 + 0.34 * w1 + 0.16 * w2, 0.0, 1.0);
	float streak = smoothstep(0.55, 0.95, band);
	float lum = dot(fluid_color, vec3(0.299, 0.587, 0.114));
	vec3 base = max(fluid_color, vec3(0.025, 0.025, 0.03));
	vec3 hi = mix(base * 1.55 + vec3(0.08), base + vec3(0.25, 0.27, 0.30), 0.35);
	if (lum < 0.03) {
		hi = vec3(0.16, 0.15, 0.14);
	}
	float wall_shade = mix(0.82, 1.08, clamp(1.0 - abs(cross_v) * 0.45, 0.0, 1.0));
	vec3 col = mix(base, hi, streak * (0.45 + 0.20 * is_surface)) * wall_shade;
	ALBEDO = col;
	ROUGHNESS = mix(0.22, 0.11, streak * 0.5 + is_surface * 0.5);
	METALLIC = 0.0;
	SPECULAR = 0.7;
	EMISSION = col * f3d_look_model_fill * 0.55;
}
