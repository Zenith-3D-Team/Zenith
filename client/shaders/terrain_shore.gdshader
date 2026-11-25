shader_type spatial;
// The coast: the quads terrain_mesher.gd puts in TerrainMesher.shore (a land tile with a water neighbour, the
// wet shelf under it and the shelf over the water beside it). Ragged coast, wet rim and shelf are cut with
// `discard`, which is why they are a surface of their own: the interior ground, terrain.gdshader, has none.
// The same code as the interior with the coast's parts in (terrain_common.gdshaderinc, TERRAIN_SHORE).

render_mode cull_back;

#define TERRAIN_SHORE
#include "res://shaders/terrain_common.gdshaderinc"
