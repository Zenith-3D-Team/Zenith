shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, fog_disabled;

// Rain streaks of Zenith's Immersive Weather add-on (weather_rain.gd): one camera-facing quad per
// drop, all placed and moved on the GPU. Each drop's INSTANCE_CUSTOM holds four fixed randoms
// (x, y, z, seed); the drop falls through a box round the focus and wraps (the box follows the
// player, the rain stays put in the world).

uniform vec3 volume_center = vec3(0.0);       // x/z: focus; y: ground under the focus
uniform vec3 box_size = vec3(48.0, 26.0, 48.0);
uniform vec2 wind = vec2(0.0);                // tiles/s the air pushes the drops (world x, z)
uniform vec2 wind_offset = vec2(0.0);         // how far the wind has carried the rain so far (kept by the script, so gusts don't jump it)
uniform float ground_y = 0.0;                 // drops fade out as they reach the ground here
uniform float visibility : hint_range(0.0, 2.0) = 1.0;
uniform float intensity : hint_range(0.0, 1.0) = 1.0;
uniform float day_factor : hint_range(0.0, 1.0) = 1.0;
uniform vec3 rain_tint : source_color = vec3(0.74, 0.80, 0.88);
uniform float far_scale = 1.0;                // the box grown for a far camera: streaks lengthen with it
uniform float fall_min = 22.0;
uniform float fall_max = 32.0;

varying float v_fade;
varying vec2 v_uv;

void vertex() {
	vec4 rnd = INSTANCE_CUSTOM;
	float speed = mix(fall_min, fall_max, fract(rnd.w * 7.31 + rnd.x * 3.7));
	vec3 vel = vec3(wind.x, -speed, wind.y);
	vec3 start = vec3(rnd.x * box_size.x, rnd.y * box_size.y, rnd.z * box_size.z);
	vec3 p = start + vec3(wind_offset.x, -speed * TIME, wind_offset.y);
	// Wrap round the focus: x/z relative to the box centred on it, y from just under the ground.
	vec2 rel_xz = mod(p.xz - volume_center.xz + box_size.xz * 0.5, box_size.xz);
	float y_rel = mod(p.y, box_size.y);
	vec3 pos = vec3(volume_center.x - box_size.x * 0.5 + rel_xz.x,
			ground_y - 1.0 + y_rel,
			volume_center.z - box_size.z * 0.5 + rel_xz.y);

	vec3 dir = normalize(vel);
	float streak = clamp(speed * 0.024, 0.3, 0.9) * far_scale;
	vec3 to_cam = CAMERA_POSITION_WORLD - pos;
	float cam_dist = length(to_cam);
	vec3 side = cross(dir, to_cam);
	float sl = length(side);
	side = sl > 0.0001 ? side / sl : vec3(1.0, 0.0, 0.0);

	// Thin with distance a little so far streaks don't alias away to nothing.
	float width = 0.020 + cam_dist * 0.0011;
	float s = VERTEX.y + 0.5;  // 0 head (lower end) .. 1 tail
	vec3 world = pos - dir * (streak * s) + side * (VERTEX.x * width);
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(world, 1.0));

	// Fades: near the camera, near the box's edge, at the ground, and by how many drops are asked.
	float near_fade = smoothstep(1.8, 4.5, cam_dist);
	vec2 edge2 = abs(rel_xz / box_size.xz - 0.5) * 2.0;
	float edge_fade = 1.0 - smoothstep(0.62, 0.98, max(edge2.x, edge2.y));
	float top_fade = 1.0 - smoothstep(0.80, 1.0, y_rel / box_size.y);
	float ground_fade = smoothstep(ground_y, ground_y + 0.7, pos.y);
	float thin = mix(0.55, 1.0, fract(rnd.w * 13.7));
	v_fade = near_fade * edge_fade * top_fade * ground_fade * thin * visibility * mix(0.6, 1.0, intensity);
	v_uv = vec2(VERTEX.x * 2.0, s);
}

void fragment() {
	float across = 1.0 - clamp(v_uv.x * v_uv.x, 0.0, 1.0);
	float along = pow(1.0 - v_uv.y, 1.3) * smoothstep(0.0, 0.06, v_uv.y + 0.04);
	float a = across * across * along * v_fade * 0.55;
	// Dimmer at night so the rain isn't neon-white in the dark.
	ALBEDO = rain_tint * mix(0.22, 1.0, day_factor);
	ALPHA = clamp(a, 0.0, 1.0);
}
