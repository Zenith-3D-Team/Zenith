shader_type canvas_item;
// Additive 2D HDR light splats into `lamp_lights.gd`'s world-space far lightmap (`f3d_lamp_light`).
// `INSTANCE_CUSTOM.rgb` carries raw linear HDR light tint * energy * gain (bypassing Godot's
// `use_hdr_2d` sRGB->linear vertex-color conversion). `INSTANCE_CUSTOM.a` carries signed
// `range_tiles`: positive = full disk splat (far lights), negative = outer ground-spread ring
// (near lamps/signals, center-damped so the real OmniLight3D owns the foot without double-brightening).
render_mode blend_add, unshaded;

uniform float atten_power = 0.42;

varying flat vec4 splat_data;

void vertex() {
	splat_data = INSTANCE_CUSTOM;
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r2 = dot(p, p);
	if (r2 >= 1.0) {
		discard;
	}
	float rng = max(abs(splat_data.a), 0.5);
	float r = sqrt(r2) * rng;
	float d = sqrt(r * r + 2.25);
	float nd = clamp(d / rng, 0.0, 1.0);
	float w = 1.0 - nd * nd * nd * nd;
	float atten = w * w * pow(max(d, 1.5), -max(atten_power, 0.01));
	if (splat_data.a < 0.0) {
		// Near-lamp/signal outer ground spread: soft fill beyond the OmniLight3D grazing dropoff.
		atten *= smoothstep(rng * 0.06, rng * 0.25, r);
	}
	COLOR = vec4(splat_data.rgb * atten, 1.0);
}
