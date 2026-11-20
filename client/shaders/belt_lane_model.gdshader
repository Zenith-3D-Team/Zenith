shader_type spatial;
// belt_lanes.gd with Items on belts set to 3D models (and Items in 3D at All): far belts' items as
// their small models instead of icons, placed as the icons are. Colours in the vertices, as
// item.gdshader's; left out on the belts belt_items.gd draws and past the distance, as
// belt_lane_icon.gdshader's (the belt's centre in the instance's custom data).
render_mode world_vertex_coords, shadows_disabled;

#include "res://shaders/belt_lane_model.gdshaderinc"
