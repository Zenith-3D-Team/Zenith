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
// A packed lane's kind drawn as one of its item's model variants (item_cards.gd put_records): of `belt_variants`
// (2 or more), only the slots whose item is variant `belt_variant` (belt_lattice_variant) are drawn by it.
instance uniform int belt_variant = 0;
instance uniform int belt_variants = 0;
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

// item_cards.gd MAX_YAW and PILE_TURN.
const float BELT_MAX_YAW = 0.35;
const float BELT_PILE_TURN = 0.45;

// A packed lane's item's turn (belt_lattice.gd, K14): `who` it is along its run and the run's seed, hashed
// into the range every item turns in (item_cards.gd lattice_turn, the same integer steps).
uint belt_lattice_hash(int who, float run) {
	uint x = uint(who & 1048575) + uint(round(run)) * 2654435769u;
	x = x ^ (x >> 16u);
	x = x * 2146121005u;
	x = x ^ (x >> 15u);
	x = x * 2221713035u;
	x = x ^ (x >> 16u);
	return x;
}

float belt_lattice_turn(int who, float run) {
	return (float(belt_lattice_hash(who, run) % 2001u) / 1000.0 - 1.0) * BELT_MAX_YAW;
}

// Which of `count` model variants that item is (item_cards.gd lattice_variant, the same steps).
int belt_lattice_variant(int who, float run, int count) {
	return int((belt_lattice_hash(who, run) >> 8u) % uint(count));
}

// Texels a layer (a page of belt_records.gd: 1024 a row, 4 rows, or 16 with --belt-draw-small-pages=off),
// from the records' texture itself.
int belt_layer_texels() {
	ivec3 s = belt_tex == 1 ? textureSize(f3d_belt_lattice, 0) : textureSize(f3d_belt_records, 0);
	return max(s.x * s.y, 1);
}

// Record layout as belt_records.gd: 4 texels, 1024 texels a row, `per` texels a layer.
vec4 belt_texel(int r, int k, int per) {
	int t = r * 4 + k;
	int layer = t / per;
	int within = t - layer * per;
	if (belt_tex == 1) {
		return texelFetch(f3d_belt_lattice, ivec3(within % 1024, within / 1024, layer), 0);
	}
	return texelFetch(f3d_belt_records, ivec3(within % 1024, within / 1024, layer), 0);
}

// Moves a vertex (world coordinates; a belt item's instance is unmoved) where its item is drawn now,
// turned, and its normal with it; not drawn: nowhere (also from the tick in an item's texel 3 w on). A pile's copy (texel 3: k > 0) is drawn from
// its item's record, k pile steps higher, with its own turn (its texel 2: every copy turns, cards and
// blocks too; belt_items.gd). A lattice slot's copies (belt_lattice.gd) slide with their slot (its texel
// 3) and, as it, aren't masked. A lattice slot whose texel 3 z is 2 holds who its item is in texel 2 (x:
// on its record's clock, y: its run's seed): each period slid, the item there is the one that was a slot
// behind, so who it is goes up by one and its turn goes on with it. A slot's own texel 3 y below 0 says where in its
// period it hides at its lane's open end (belt_lattice.gd handover).
void belt_place(inout vec3 vertex, inout vec3 normal, int id) {
	if (belt_base < 0) {
		return;
	}
	int r = belt_base + id;
	int per = belt_layer_texels();
	vec4 d = belt_texel(r, 3, per);
	vec4 e = d;  // the drawn record's texel 3 (a copy's item's or slot's)
	vec2 own = vec2(1.0, 0.0);
	if (d.y > 0.5) {
		own = belt_texel(r, 2, per).xy;
		r += int(round(d.x));
		e = belt_texel(r, 3, per);
	}
	vec4 a = belt_texel(r, 0, per);
	vec4 b = belt_texel(r, 1, per);
	vec4 c = belt_texel(r, 2, per);
	if (c.w < -0.5) {
		vertex = vec3(0.0);
		return;
	}
	vec2 who = c.xy;  // (a lattice slot's item, below)
	if (d.y > 0.5) {
		c.z += d.z * d.y;
		c.xy = own;
	}
	float g = b.w > a.w ? clamp((f3d_belt_clock - a.w) / (b.w - a.w), 0.0, 1.0) : 1.0;
	bool lattice = e.y < 0.5 && e.z > 0.5;
	float slid = 0.0;
	// (A held clock, belt_lattice.gd close and start: texel 1 w its start, after texel 0 w, and texel 1 y how many
	// periods it runs from then, 0 on and on: the lattice stands before and after. A slot never moves up: texel 1
	// y says nothing of where it is.)
	float lclock = f3d_belt_clock;
	float hclock = e.x;
	if (lattice && e.w > 0.0) {
		if (b.w > a.w) {
			float hi = b.y > 0.0 ? b.w + b.y * e.w : 1.0e30;
			lclock = clamp(f3d_belt_clock, b.w, hi);
			hclock = clamp(e.x, b.w, hi);
		}
		float q = (lclock - a.w) / e.w;
		g = fract(q);
		slid = floor(q);
	}
	if (lattice && e.z > 1.5) {
		float turn = belt_lattice_turn(int(round(who.x)) + int(slid), who.y) + BELT_PILE_TURN * max(d.y, 0.0);
		c.xy = vec2(cos(turn), sin(turn));
	}
	// The slot's item is another variant: that variant's kind draws it (slot turns: no one to pick by, the first).
	if (lattice && belt_variants > 1 && (e.z > 1.5 ? belt_lattice_variant(int(round(who.x)) + int(slid), who.y, belt_variants) : 0) != belt_variant) {
		vertex = vec3(0.0);
		return;
	}
	// A slot at a lane's open end hides while its item is the simulation's to draw there (belt_lattice.gd handover:
	// its own texel 3 y -(1 + h), hidden from g h on; -(3 + h), hidden before g h).
	if (lattice && e.y < -0.5) {
		float hy = -e.y;
		if (hy < 2.5 ? g >= hy - 1.0 : g < hy - 3.0) {
			vertex = vec3(0.0);
			return;
		}
	}
	// An item an inserter's hand took (--inserter-handoff: texel 3 w, the take's tick) isn't drawn from
	// that tick: the hand holds it; one a hand puts (w negative, minus the put's tick) not before it.
	if (!lattice && (e.w > 0.0 && f3d_belt_clock >= e.w || e.w < 0.0 && f3d_belt_clock < -e.w)) {
		vertex = vec3(0.0);
		return;
	}
	// The hole such a take leaves in a lattice (texel 3 x of the slot's own record: hidden from then to the
	// end of that period; belt_lattice.gd hole).
	if (lattice && e.x > 0.0 && f3d_belt_clock >= e.x && (e.w <= 0.0 || floor((lclock - a.w) / e.w) == floor((hclock - a.w) / e.w))) {
		vertex = vec3(0.0);
		return;
	}
	vec3 at = a.xyz;
	if (c.w < 0.5) {
		at += (lattice ? vec3(b.x, 0.0, b.z) : b.xyz) * g;
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
