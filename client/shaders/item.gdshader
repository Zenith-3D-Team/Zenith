// Loose items (item_cards.gd): 3D item models, whose colours are in the vertices (linear, from
// glTF), and plain coloured blocks (no vertex colours: COLOR is white). Items on belts glide on
// the GPU along their lanes (belt_path.gdshaderinc), so a frame doesn't touch their transforms.
// A modeller's item model with a base-colour picture has a material of its own with it (use_picture,
// item_models.gd material_for): the picture times the vertex colours (its material's colour).
shader_type spatial;
render_mode world_vertex_coords;

#include "res://shaders/item_body.gdshaderinc"
