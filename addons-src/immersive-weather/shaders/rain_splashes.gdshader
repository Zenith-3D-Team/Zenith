shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, fog_disabled;

// Rain splashes of Zenith's Immersive Weather add-on (weather_rain.gd): a flat quad per splash laid
// on the ground or a roof (its instance transform's origin), drawn as an expanding ring with a
// small crown of droplets. INSTANCE_CUSTOM = (spawn time, life, crown size 0.16..0.28, seed). A
// splash whose age is past its life is collapsed off-screen.

uniform float now = 0.0;           // the add-on's clock, wrapped every 1000 s
uniform float visibility : hint_range(0.0, 2.0) = 1.0;
uniform float day_factor : hint_range(0.0, 1.0) = 1.0;
uniform vec3 splash_tint : source_color = vec3(0.80, 0.86, 0.94);

varying vec2 v_local;     // -1..1 across the quad
varying float v_age;      // 0..1 of the life
varying float v_alive;
varying float v_size;
varying float v_seed;
varying float v_fade;

void vertex() {
	vec4 c = INSTANCE_CUSTOM;
	float age = mod(now - c.x + 1000.0, 1000.0);
	float life = max(c.y, 0.001);
	v_age = clamp(age / life, 0.0, 1.0);
	float alive = age < life ? 1.0 : 0.0;
	v_alive = alive;
	v_size = c.z;
	v_seed = c.w;
	v_local = VERTEX.xy * 2.0;

	vec3 origin = MODEL_MATRIX[3].xyz;
	float half_extent = c.z * 1.35;
	vec3 world = origin + vec3(VERTEX.x, 0.0, VERTEX.y) * (2.0 * half_extent);
	// A hair toward the camera so the ring never z-fights with the surface it sits on.
	vec3 to_cam = CAMERA_POSITION_WORLD - origin;
	float d = length(to_cam);
	world += to_cam / max(d, 0.001) * 0.035;
	v_fade = 1.0 - smoothstep(26.0, 40.0, d);
	POSITION = alive > 0.5 ? PROJECTION_MATRIX * (VIEW_MATRIX * vec4(world, 1.0)) : vec4(2.0, 2.0, 2.0, 1.0);
}

void fragment() {
	// The quad spans +-1.35 crown sizes; keep droplets subtle and feathery.
	vec2 q = v_local * 1.35;
	float r = length(q);
	float t = v_age;
	float ease = 1.0 - (1.0 - t) * (1.0 - t);
	float ring_r = mix(0.10, 1.05, ease);
	float ring_w = mix(0.14, 0.06, t);
	float ring = 1.0 - smoothstep(0.0, ring_w, abs(r - ring_r));
	float crown = 0.0;
	for (int i = 0; i < 6; i++) {
		float fi = float(i);
		float a0 = (fi + fract(v_seed * 5.3 + fi * 0.37) * 0.85) * 1.0471976;
		float dr = mix(0.08, 0.72, ease) * (0.78 + 0.44 * fract(v_seed * 3.1 + fi * 0.71));
		vec2 dp = vec2(cos(a0), sin(a0)) * dr;
		float lift = 4.0 * t * (1.0 - t);
		float dot_r = 0.08 + 0.045 * lift;
		crown += (1.0 - smoothstep(dot_r * 0.35, dot_r, length(q - dp))) * mix(0.30, 1.0, lift);
	}
	crown *= 1.0 - smoothstep(0.50, 1.0, t);
	float fade = (1.0 - t) * (1.0 - t * 0.55);
	float a = (ring * 0.28 + clamp(crown, 0.0, 1.0) * 0.42) * fade;
	a *= 1.0 - smoothstep(1.05, 1.35, r);
	ALBEDO = splash_tint * mix(0.22, 0.86, day_factor);
	ALPHA = clamp(a * visibility * v_fade, 0.0, 1.0) * v_alive;
}
