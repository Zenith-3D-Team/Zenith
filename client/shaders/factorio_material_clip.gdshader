shader_type spatial;
// The cut-out variant of factorio_material.gdshader: a material set to Alpha Clip in Blender (glTF
// alphaMode MASK) drops every pixel whose alpha (its base colour's, times its texture's) is under its
// cutoff, shadows too; the rest is drawn solid. Both sides are drawn, as fences, grilles and leaves want.

render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

#define ALPHA_CLIP
#include "res://shaders/factorio_material.gdshaderinc"
