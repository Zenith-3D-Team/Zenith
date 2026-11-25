// Cut-out / dithered twin of item_own.gdshader (item_models.gd dressed): draws own-look surfaces
// with glTF MASK alpha clip or --item-glass=dither without adding discard() to opaque item_own.gdshader.
shader_type spatial;

#define ITEM_OWN
#define ITEM_CUT
#include "res://shaders/item_body.gdshaderinc"
