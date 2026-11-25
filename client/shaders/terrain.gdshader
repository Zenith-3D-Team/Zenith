shader_type spatial;
// Interior ground: land tiles and the banks down to the water (and the whole ground without the Factorio
// install), with no `discard` at all, so the hardware's early depth test and a cheap depth pre-pass work
// on the ~98% of the ground that is not coast. The coast's quads (the wet rim, the shelf under the land and
// over the water) are terrain_shore.gdshader. Everything else is in terrain_common.gdshaderinc.
// --terrain-opt=old draws the original single shader, terrain_old.gdshader, for all of it.

render_mode cull_back;

#include "res://shaders/terrain_common.gdshaderinc"
