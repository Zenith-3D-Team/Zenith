// How far a decorative near the character has risen into 3D (decoratives.gd, decorative_grass.gdshader):
// 1 inside Settings > Graphics > 3D grass's range, 0 past it, easing over its last GRASS_EASE tiles and
// as the camera zooms out. The flat picture and its raised copy read the same number, so one melts
// into the other with no pop. A per-instance value, from the instance's own place.

global uniform vec4 f3d_grass;  // the character's x, z, the range (tiles; 0: off), the zoom's fade
global uniform float f3d_grass_wind;  // 1 with wind, 0 still

const float GRASS_EASE = 10.0;

float grass_grow(vec2 xz) {
	if (f3d_grass.z <= 0.0 || f3d_grass.w <= 0.0) {
		return 0.0;
	}
	return f3d_grass.w * (1.0 - smoothstep(f3d_grass.z - GRASS_EASE, f3d_grass.z, distance(xz, f3d_grass.xy)));
}
