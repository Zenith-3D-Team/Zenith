shader_type spatial;
// 3D decorative placeholder & custom .glb/.gltf models (decoratives.gd): supports Vertex-colored
// Placeholders (COLOR_0 linear) and optional base-colour textures (use_picture), gentle root-pinned
// wind sway, and gradual grass_grow() rising near the character when used on grass/carpet layers.
render_mode cull_disabled;

#include "res://shaders/ground_height.gdshaderinc"
#include "res://shaders/decorative_grass.gdshaderinc"
#include "res://shaders/lamp_light.gdshaderinc"

uniform bool grass_mode = false;
uniform bool sway_enabled = true;
uniform bool follow_slope = false;
uniform bool use_picture = false;
uniform sampler2D picture : source_color, filter_linear_mipmap, repeat_enable;
uniform float exposure = 0.85;
uniform float wind_amount = 0.08;

varying float v_height;
varying vec2 world_xz;

void vertex() {
	vec2 at = MODEL_MATRIX[3].xz;
	float sx = max(length(MODEL_MATRIX[0].xyz), 0.001);
	float local_y = max(VERTEX.y, 0.0);
	v_height = local_y;

	if (grass_mode) {
		float grow = grass_grow(at);
		if (grow <= 0.001) {
			VERTEX = vec3(0.0);
		} else {
			VERTEX.y *= grow;
			VERTEX.xz *= mix(0.65, 1.0, grow);
			local_y *= grow;
			v_height = local_y;
		}
	}

	if (sway_enabled && f3d_grass_wind > 0.01 && local_y > 0.001) {
		float w = clamp(f3d_grass_wind, 0.0, 3.0);
		float phase = INSTANCE_CUSTOM.x * 6.2831853 + at.x * 0.35 + at.y * 0.21;
		float t = TIME * 1.6 + phase;
		float gust = max(w - 1.0, 0.0) * 0.28 * sin(t * 2.1 + at.x * 0.12 - at.y * 0.09);
		vec2 sway = (vec2(sin(t), sin(t * 0.73 + 1.7)) * w + vec2(gust, gust * 0.6)) * (wind_amount * local_y);
		VERTEX.x += sway.x / sx;
		VERTEX.z += sway.y / sx;
	}

	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	VERTEX = follow_slope ? ground_lift(VERTEX, MODEL_MATRIX) : ground_lift_origin(VERTEX, MODEL_MATRIX);
}

void fragment() {
	vec3 base = COLOR.rgb;
	if (use_picture) {
		vec4 t = texture(picture, UV);
		base *= t.rgb;
		ALPHA = t.a;
		ALPHA_SCISSOR_THRESHOLD = 0.4;
	}
	float ao = mix(0.84, 1.05, clamp(v_height * 2.2, 0.0, 1.0));
	ALBEDO = base * ao * exposure;
	ROUGHNESS = plant_roughness(0.92);
	SPECULAR = plant_specular();
	METALLIC = 0.0;
	EMISSION = lamp_light_emission(ALBEDO, world_xz, v_height, 0.8);
}
