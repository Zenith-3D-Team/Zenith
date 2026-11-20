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

// The ground plants' surface (owner: grass turned white with the sun low behind it). Godot's Fresnel
// brings most of the sun's highlight back at grazing angles unless F0 (0.16 x specular^2) is tiny, and
// a back-lit plant's half vector points straight up its bent-up normal, so specular 0.5 lit the blades
// with a white sheen brighter than their own colour. Kept low and fully rough, as the ground under them
// (terrain_textures.gd SURFACES). --grass-backlight=old (decoratives.gd): 0.2.2's.
uniform bool old_sheen = false;
const float PLANT_SPECULAR = 0.05;

float plant_specular() {
	return old_sheen ? 0.5 : PLANT_SPECULAR;
}

float plant_roughness(float old_roughness) {
	return old_sheen ? old_roughness : 1.0;
}
