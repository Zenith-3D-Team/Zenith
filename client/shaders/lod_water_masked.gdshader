shader_type spatial;
// Distant Horizon LOD 0 opaque water (discards chunks inside loaded_mask).

render_mode blend_mix, depth_draw_opaque, cull_back, specular_schlick_ggx;

#define LOD_WATER
#define LOD_MASKED
#include "res://shaders/lod_common.gdshaderinc"
