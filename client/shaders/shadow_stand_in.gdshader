shader_type spatial;
// The shadow stand-ins (model_lods.gd, chunk_view.gd _shadow_proxy): drawn only into the sun's shadow
// map, in place of a model's own shadow. Lifted by the hills (ground_height.gdshaderinc) as the model
// they stand in for is: with a plain material they cast from y = 0 while the model and the ground
// stood on hills, so everything lower than the hills there (belts, pipes, inserters, assemblers) cast
// its shadow under the ground and only tall buildings' tops showed one (Terrain Elevation).

render_mode unshaded;

#include "res://shaders/ground_height.gdshaderinc"

void vertex() {
	VERTEX = ground_lift(VERTEX, MODEL_MATRIX);
}

void fragment() {
	ALBEDO = vec3(0.0);
}
