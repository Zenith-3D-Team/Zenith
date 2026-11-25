shader_type spatial;
// Cut-out / fragment-culled twin of belt_lane_model.gdshader: used for alpha-cut or dithered
// own-look surfaces, and when --belt-lane-vcull=off keeps near/far lane culling in fragment().
render_mode world_vertex_coords, shadows_disabled;

#define LANE_FRAG_CULL
#define ITEM_CUT
#include "res://shaders/belt_lane_model.gdshaderinc"
