shader_type spatial;
// Far chunks' tree crowns (far_chunks.gd): each puff is a low-poly opaque octahedron whose baked
// leaf colour is stored in COLOR (sqrt-encoded linear RGB; a = part-colour share), tinted per
// tree in Merge.run() and shaped by pollution_at(UV) so dying trees grey, brown and drop their
// crowns just like Factorio's and the near leaf shader's.

render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

global uniform float f3d_tree_matte;  // looks.gd: 0 = --tree-sheen=old

#include "res://shaders/noise.gdshaderinc"
#include "res://shaders/ground_height.gdshaderinc"
#include "res://shaders/pollution.gdshaderinc"
#include "res://shaders/lamp_light.gdshaderinc"

uniform vec2 part_light = vec2(0.95, 0.6);

global uniform float f3d_look_model_fill;

varying flat float leaf_dying;
varying vec3 world_pos;

void vertex() {
	vec2 origin = UV;
	float seed = hash12(origin * 3.17 + 0.5);
	leaf_dying = clamp(pollution_at(origin).x * 1.3 - 0.3 * seed, 0.0, 1.0);
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX = leaf_dying >= 0.85 ? vec3(0.0) : ground_lift(VERTEX, MODEL_MATRIX);
}

void fragment() {
	vec3 col = clamp(COLOR.rgb, 0.0, 1.0);
	col *= col;
	if (leaf_dying > 0.0) {
		float lum = dot(col, vec3(0.3, 0.59, 0.11));
		vec3 grey = mix(col, vec3(lum), smoothstep(0.0, 0.45, leaf_dying));
		col = mix(grey, lum * vec3(1.2, 0.98, 0.66), smoothstep(0.3, 0.8, leaf_dying));
	}
	vec3 face = cross(dFdx(VERTEX), dFdy(VERTEX));
	vec3 n = dot(face, face) > 1e-20 ? normalize(face) : vec3(0.0, 0.0, 1.0);
	NORMAL = dot(n, VERTEX) > 0.0 ? -n : n;
	float up = clamp((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y, 0.0, 1.0);
	float pc = clamp(COLOR.a, 0.0, 1.0);
	ALBEDO = col * mix(1.0, mix(part_light.x, part_light.y, up), pc);
	EMISSION = ALBEDO * f3d_look_model_fill * (0.35 + 0.65 * max(dot(NORMAL, VIEW), 0.0));
	EMISSION += lamp_light_emission(ALBEDO, world_pos.xz, world_pos.y, up);
	ROUGHNESS = mix(0.85, 1.0, f3d_tree_matte);
	METALLIC = 0.0;
	SPECULAR = mix(0.2, 0.05, f3d_tree_matte);
}
