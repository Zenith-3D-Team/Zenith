#pragma once
// SPDX-License-Identifier: GPL-3.0-or-later
// Native twin of the per-decorative loops in scripts/world/decoratives.gd's _run_job (placement filter
// and grouping; per kind: order, flat/raised split, instance buffer fill, edge list, model buckets).
// Same algorithm and ordering as the GDScript, which stays the fallback (--native-decor=off).

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <cstdint>

namespace godot {

class DecorNative : public RefCounted {
	GDCLASS(DecorNative, RefCounted)

public:
	static constexpr int STRIDE = 16;
	static constexpr int CHUNK = 32;

	// list: [id, lx, ly, _] * n. Returns {ids: PackedInt32Array (first-appearance order),
	// tiles: Array of PackedInt32Array (x, y pairs per id)}.
	Dictionary place(const PackedInt32Array &p_list, int p_cx, int p_cy, const PackedInt32Array &p_mask, double p_density) const;

	// One kind's instances. cfg keys: cx, cy, upright, has_flat, lift, grass_height, grass_carpet,
	// rising (instances raised), flat_near, model_count, model_scale, model_hs, model_shift (Vector2).
	// uvs: 4 floats a variant, sizes/shifts: 2. blocks: 9 PackedInt32Array (row-major dy+1, dx+1; the
	// middle is the chunk's own mask).
	// Returns {buffer, edge_tiles (x, y pairs, tufts reaching a blocked tile), edge_floats, edge_mask,
	// rising, buckets (Array of PackedFloat32Array)}.
	Dictionary fill_group(const PackedInt32Array &p_tiles, const Dictionary &p_cfg, const PackedFloat32Array &p_uvs,
			const PackedFloat32Array &p_sizes, const PackedFloat32Array &p_shifts, const Array &p_blocks) const;

	int64_t hash2(int p_x, int p_y) const;
	int64_t hash3(int p_x, int p_y, int p_z) const;

protected:
	static void _bind_methods();
};

} // namespace godot
