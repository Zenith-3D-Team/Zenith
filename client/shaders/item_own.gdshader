// A surface of a modeller's item model drawn with its file's own material (item_models.gd dressed): as
// item.gdshader, its picture's alpha, roughness and metal, normal map and emission too (item_pbr.gdshaderinc).
// Opaque Early-Z shader (no discard; cut-out/dithered surfaces use item_own_cut.gdshader).
shader_type spatial;

#define ITEM_OWN
#include "res://shaders/item_body.gdshaderinc"
