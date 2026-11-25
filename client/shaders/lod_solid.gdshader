shader_type spatial;
// Distant Horizon LOD 1-4 solid terrain, buildings, and trees (no discard -> Early-Z preserved).

render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

#define LOD_SOLID
#include "res://shaders/lod_common.gdshaderinc"
