// LodMesherNative: the vertex/index building loops of scripts/world/lod_mesher.gd (Distant Horizon's
// section meshes: greedy terrain, coast banks, boxes, forest blocks, trees, poles) in C++.
// lod_mesher.gd's run() gives build() its inputs as one Dictionary of Packed*Arrays and scalars and
// makes the ArrayMesh from what comes back; it stays on its worker thread. build() has no state, so
// one instance per call is fine from any thread. Every step follows lod_mesher.gd, down to where it
// rounds to float32 (vertices, colours and the trees' corner offsets are float32, the rest double),
// so both paths give the same arrays (client/tests/lod_mesher_native_test.gd).
// It also holds far_chunks.gd's merge builder (merge()).
// GPL-3.0, like the rest of Zenith.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

class LodMesherNative : public RefCounted {
	GDCLASS(LodMesherNative, RefCounted)

protected:
	static void _bind_methods();

public:
	// p: n, cell_tiles, section_origin, max_quad_tiles, detail_tier, tiles, protos, flags, tile_colors,
	// tile_kind, tile_rough, ent_top, ent_side, ent_heights, ent_metal, ent_rough, ent_cat, ent_glow, seat.
	// Returns {sv, sc, su, si, wv, wc, wi} (PackedVector3/Color/Vector2/Int32 arrays).
	Dictionary build(const Dictionary &p) const;

	// far_chunks.gd's Merge.run(): every instance's baked model moved into place, in one pass.
	// groups: Array of [bv, bc, bi, crown_v, crown_c, crown_i, leaf_tints, kind (0 solid, 1 trees' and
	// plants', 2 low ground), xforms (Array of Transform3D), tint (Color, or null)], in Merge.run()'s order
	// (the groups' instances, then the tinted ones one group each). Returns {v, c, i, nv, nc, ni, lv, lc,
	// li, cv, cc, cu, ci}.
	Dictionary merge(const Array &groups) const;
};

} // namespace godot
