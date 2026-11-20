// item_own.gdshader for an own-look item model's see-through (glTF BLEND) surfaces: blended at its alpha
// in the transparent pass; the item's other surfaces stay in the opaque pass (item_models.gd dressed).
// With a depth pre-pass, as Godot draws glTF's BLEND (the Model packs preview): a modeller's flask is often one
// surface whose glass is in its picture's alpha, and its opaque pixels (the liquid, the cap) still write depth and
// cast shadow, only the see-through ones blend. `--item-glass=dither`: not used.
shader_type spatial;
render_mode world_vertex_coords, blend_mix, depth_prepass_alpha, cull_back;

#define ITEM_OWN
#define ITEM_BLEND
#include "res://shaders/item_body.gdshaderinc"
