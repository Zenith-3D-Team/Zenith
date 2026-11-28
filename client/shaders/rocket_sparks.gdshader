shader_type spatial;
// Velocity-stretched incandescent spark & slag ember MultiMesh shader (rocket_vfx.gd).
//   MODEL_MATRIX[3].xyz: world position
//   COLOR:               hot spark rgb + alpha
//   INSTANCE_CUSTOM:     rgb = world velocity, a = base width
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

#include "res://shaders/ground_height.gdshaderinc"

varying vec2 v_uv;

void vertex() {
	v_uv = UV;
	vec3 world_pos = MODEL_MATRIX[3].xyz;
	world_pos.y += ground_h(world_pos.xz);

	vec3 vel = INSTANCE_CUSTOM.rgb;
	float speed = length(vel);
	vec3 dir = speed > 0.05 ? (vel / speed) : vec3(0.0, 1.0, 0.0);

	vec3 cam_pos = INV_VIEW_MATRIX[3].xyz;
	vec3 to_cam = normalize(cam_pos - world_pos);
	vec3 side = cross(dir, to_cam);
	if (dot(side, side) < 1e-5) {
		side = INV_VIEW_MATRIX[0].xyz;
	} else {
		side = normalize(side);
	}

	float width = INSTANCE_CUSTOM.a;
	float streak = max(width * 2.0, min(speed * 0.055, 2.2));
	vec3 p_world = world_pos + side * (VERTEX.x * width) + dir * (VERTEX.y * streak);
	MODELVIEW_MATRIX = VIEW_MATRIX;
	VERTEX = p_world;
}

void fragment() {
	float across = 1.0 - abs(v_uv.x * 2.0 - 1.0);
	float along = smoothstep(0.0, 0.35, v_uv.y) * smoothstep(1.0, 0.45, v_uv.y);
	float core = pow(max(across, 0.0), 3.0) * along;
	vec3 c = mix(COLOR.rgb, vec3(3.2, 2.9, 2.2), core * 0.65);
	ALBEDO = c * (across * along * 1.4 + core * 1.5) * COLOR.a;
	ALPHA = clamp((across * along + core) * COLOR.a, 0.0, 1.0);
}
