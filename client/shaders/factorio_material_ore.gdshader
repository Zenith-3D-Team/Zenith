shader_type spatial;
// A "pbr" pack's ore rocks on the ground (model_library.gd _factorio, ore_look): factorio_material's own path, drawn
// with Lambert diffuse as belt ore is (item.gdshader has Godot's default; Burley, as buildings have, brightens
// rough surfaces at grazing angles, which read as a pale sheen on the patch).

render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_schlick_ggx;

#include "res://shaders/factorio_material.gdshaderinc"
