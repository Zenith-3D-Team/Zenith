shader_type spatial;
// Per-limb ragdoll & organic corpse decay variant of factorio_material.gdshader (api.creatures).

render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

#define RAGDOLL_DECAY
#include "res://shaders/factorio_material.gdshaderinc"
