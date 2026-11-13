// Ground no decorative may cover (decoratives.gd): player-laid floors (concrete, stone path, landfill,
// foundations, artificial soils) and every building's footprint, a bit per tile. The texture wraps
// round 1024 tiles (32 chunks) each way; a texel is one chunk's row of 32 tiles, its four bytes 8 tiles
// each, lowest bit west. Flat pictures are cut along those tiles' edges, and carpet clumps standing on
// or leaning over them are left out.

global uniform sampler2D f3d_decor_mask;
global uniform float f3d_decor_mask_on;  // 0 until decoratives.gd has made the texture

bool decor_blocked(vec2 xz) {
	if (f3d_decor_mask_on < 0.5) {
		return false;
	}
	ivec2 t = ivec2(floor(xz));
	vec4 row = texelFetch(f3d_decor_mask, ivec2((t.x >> 5) & 31, t.y & 1023), 0);
	int b = t.x & 31;
	float byte_f = b < 8 ? row.r : (b < 16 ? row.g : (b < 24 ? row.b : row.a));
	int bits = int(byte_f * 255.0 + 0.5);
	return ((bits >> (b & 7)) & 1) != 0;
}
