// A surface of a modeller's item model drawn with its file's own material (item_models.gd dressed): as
// item.gdshader, its picture's alpha, roughness and metal, normal map and emission too (item_pbr.gdshaderinc).
// Its own shader so the cut-out's discard stays out of every other item's.
shader_type spatial;
render_mode world_vertex_coords;

#define ITEM_OWN
#include "res://shaders/item_body.gdshaderinc"
