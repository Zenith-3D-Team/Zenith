// Items on belts are placed on the GPU from their records (belt_records.gd, belt_items.gd): record
// `belt_base` + INSTANCE_ID of the global `f3d_belt_records`, on the drawn clock `f3d_belt_clock`.
// A record is where the item is at t0, how far it goes by t1 (in a straight line, or along its lane's
// path: points from `belt_paths`, an offset from its place and 1 where it shows, 0 under the ground),
// its turn and lift. Other loose items (on the ground, in hands: belt_base < 0) stay where their
// instance puts them.
// Lanes full of one kind (belt_lattice.gd, --belt-draw-lattice) are drawn as a lattice: its kinds read
// `f3d_belt_lattice` (belt_tex 1), each slot sliding a gap a period (texel 3: z 1, w the period in
// ticks; the drawn clock taken modulo it), and every other item whose place falls in a cell of those
// lanes' mask (`f3d_belt_mask`, 4 cells a tile, wrapping) isn't drawn.
instance uniform int belt_base = -1;
instance uniform int belt_tex = 0;
global uniform sampler2DArray f3d_belt_records;
global uniform sampler2DArray f3d_belt_lattice;
global uniform sampler2D f3d_belt_mask;
global uniform float f3d_belt_lattice_on;
global uniform float f3d_belt_clock;
uniform sampler2D belt_paths : filter_nearest, repeat_disable;

// Along a path: code = first point × 64 + points - 2; g, 0 to 1.
vec4 belt_path_at(int code, float g) {
	int first = code / 64;
	int pieces = code - first * 64 + 1;
	float f = clamp(g, 0.0, 1.0) * float(pieces);
	int i = min(int(f), pieces - 1);
	int width = textureSize(belt_paths, 0).x;
	int a = first + i;
	vec4 p0 = texelFetch(belt_paths, ivec2(a % width, a / width), 0);
	vec4 p1 = texelFetch(belt_paths, ivec2((a + 1) % width, (a + 1) / width), 0);
	return mix(p0, p1, f - float(i));
}

// Record layout as belt_records.gd: 4 texels, 1024 texels a row, 16 rows a layer.
vec4 belt_texel(int r, int k) {
	int t = r * 4 + k;
	int layer = t / 16384;
	int within = t - layer * 16384;
	if (belt_tex == 1) {
		return texelFetch(f3d_belt_lattice, ivec3(within % 1024, within / 1024, layer), 0);
	}
	return texelFetch(f3d_belt_records, ivec3(within % 1024, within / 1024, layer), 0);
}

// Moves a vertex (world coordinates; a belt item's instance is unmoved) where its item is drawn now,
// turned, and its normal with it; not drawn: nowhere. A pile's copy (texel 3: k > 0) is drawn from
// its item's record, k pile steps higher, with its own turn (its texel 2: every copy turns, cards and
// blocks too; belt_items.gd). A lattice slot's copies (belt_lattice.gd) slide with their slot (its texel
// 3) and, as it, aren't masked.
void belt_place(inout vec3 vertex, inout vec3 normal, int id) {
	if (belt_base < 0) {
		return;
	}
	int r = belt_base + id;
	vec4 d = belt_texel(r, 3);
	vec4 e = d;  // the drawn record's texel 3 (a copy's item's or slot's)
	vec2 own = vec2(1.0, 0.0);
	if (d.y > 0.5) {
		own = belt_texel(r, 2).xy;
		r += int(round(d.x));
		e = belt_texel(r, 3);
	}
	vec4 a = belt_texel(r, 0);
	vec4 b = belt_texel(r, 1);
	vec4 c = belt_texel(r, 2);
	if (c.w < -0.5) {
		vertex = vec3(0.0);
		return;
	}
	if (d.y > 0.5) {
		c.z += d.z * d.y;
		c.xy = own;
	}
	float g = b.w > a.w ? clamp((f3d_belt_clock - a.w) / (b.w - a.w), 0.0, 1.0) : 1.0;
	bool lattice = e.y < 0.5 && e.z > 0.5;
	if (lattice && e.w > 0.0) {
		g = fract((f3d_belt_clock - a.w) / e.w);
	}
	vec3 at = a.xyz;
	if (c.w < 0.5) {
		at += b.xyz * g;
	} else {
		vec4 o = belt_path_at(int(c.w + 0.5) - 1, g);
		if (o.w < 0.5) {
			vertex = vec3(0.0);
			return;
		}
		at += o.xyz;
	}
	if (!lattice && f3d_belt_lattice_on > 0.5) {
		vec2 size = vec2(textureSize(f3d_belt_mask, 0));
		vec2 cell = mod(floor(at.xz * 4.0), size);
		if (texelFetch(f3d_belt_mask, ivec2(cell), 0).r > 0.5) {
			vertex = vec3(0.0);
			return;
		}
	}
	vertex = vec3(c.x * vertex.x + c.y * vertex.z, vertex.y + c.z, -c.y * vertex.x + c.x * vertex.z) + at;
	normal = vec3(c.x * normal.x + c.y * normal.z, normal.y, -c.y * normal.x + c.x * normal.z);
}
