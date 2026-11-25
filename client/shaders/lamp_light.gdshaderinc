// Shared sampler for Zenith's far lamp & machine lightmap (`lamp_lights.gd`): 2D HDR light grid
// centred around the camera, sampled once per world fragment in surface shaders so distant lit
// areas glow warmly onto terrain and buildings at O(1) GPU cost without spending clustered light slots.

global uniform sampler2D f3d_lamp_light;
// xy = world origin (x, z) of UV (0, 0); z = tiles per texel; w = strength scale (<= 0.001 off).
global uniform vec4 f3d_lamp_light_rect;

vec3 lamp_light_sample(vec2 xz) {
	if (f3d_lamp_light_rect.w <= 0.001) {
		return vec3(0.0);
	}
	vec2 span = max(f3d_lamp_light_rect.z * vec2(textureSize(f3d_lamp_light, 0)), vec2(1.0));
	vec2 uv = (xz - f3d_lamp_light_rect.xy) / span;
	if (uv.x <= 0.0 || uv.y <= 0.0 || uv.x >= 1.0 || uv.y >= 1.0) {
		return vec3(0.0);
	}
	vec3 raw = max(texture(f3d_lamp_light, uv).rgb, vec3(0.0)) * f3d_lamp_light_rect.w;
	// Soft shoulder keeps overlapping lamp grids warm without blowing out to solid white.
	return raw / (vec3(1.0) + raw * 0.22);
}

vec3 lamp_light_emission(vec3 albedo, vec2 xz, float height, float up) {
	vec3 l = lamp_light_sample(xz);
	if (dot(l, vec3(1.0)) <= 1e-5) {
		return vec3(0.0);
	}
	float h_fade = 1.0 / (1.0 + max(height, 0.0) * 0.42);
	float dir_weight = mix(1.05, 1.0, clamp(up, 0.0, 1.0));
	return albedo * l * h_fade * dir_weight;
}
