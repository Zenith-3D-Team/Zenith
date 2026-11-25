shader_type spatial;
// Distant Horizon LOD 1-4 opaque water (no discard -> Early-Z preserved).

render_mode blend_mix, depth_draw_opaque, cull_back, specular_schlick_ggx;

#define LOD_WATER
#include "res://shaders/lod_common.gdshaderinc"
