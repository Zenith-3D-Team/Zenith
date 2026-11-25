shader_type spatial;
// Distant Horizon LOD 0 solid terrain, buildings, and trees (discards chunks inside loaded_mask).

render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

#define LOD_SOLID
#define LOD_MASKED
#include "res://shaders/lod_common.gdshaderinc"
