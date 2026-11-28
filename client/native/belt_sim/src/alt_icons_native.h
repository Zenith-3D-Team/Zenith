#pragma once
// SPDX-License-Identifier: GPL-3.0-or-later
// Native twin of the card path's sort, pack and join in scripts/ui/factorio/alt_overlay.gd (_gpu_fill,
// _gpu_sort_chunks, _gpu_join): each chunk's Alt-mode icon instances held here, sorted farthest first along
// the view and packed 16 floats an instance, the chunks joined farthest first. Same keys, ties and layout as
// the GDScript, which stays the fallback (--alt-native=off).

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace godot {

class AltIconsNative : public RefCounted {
	GDCLASS(AltIconsNative, RefCounted)

public:
	static constexpr int FLOATS = 16;

	// One chunk's icons: per entity anchors, refs, cell_start, cell_count, skip (1 = hover-only, not on the
	// card); per cell offset, side, pic (layer + 4096 * (mark layer + 1)). Returns whether anything differs
	// from what this chunk held.
	bool set_chunk(Vector2i p_c, const PackedVector3Array &p_anchors, const PackedFloat32Array &p_refs,
			const PackedInt32Array &p_cell_start, const PackedInt32Array &p_cell_count, const PackedByteArray &p_skip,
			const PackedVector2Array &p_cell_offset, const PackedFloat32Array &p_cell_side,
			const PackedFloat32Array &p_cell_pic);
	bool erase_chunk(Vector2i p_c);
	bool has_chunk(Vector2i p_c) const;
	void clear();
	int chunk_count() const;
	// Instances in the last build().
	int instance_count() const;
	// Every chunk's instances, farthest chunk first, each chunk's farthest first.
	PackedFloat32Array build(Vector3 p_fwd);
	// One chunk's sorted block for `fwd` (tests).
	PackedFloat32Array chunk_data(Vector2i p_c, Vector3 p_fwd);
	// --alt-relift: the ground's height field as ground_height.gd's sample_state() gives it (once a version()).
	void set_field(const Array &p_state);
	// Each anchor's y set to its flat height plus the ground under its x, z: GroundHeight.at's sum in doubles,
	// the same steps in the same order (ground_height.gd's at and _at_in), `mix` its fade's mix now.
	PackedVector3Array lift(const PackedVector3Array &p_anchors, const PackedFloat64Array &p_flat, double p_mix) const;

protected:
	static void _bind_methods();

private:
	struct Chunk {
		int x = 0;
		int y = 0;
		PackedVector3Array anchors;
		PackedFloat32Array refs;
		PackedInt32Array cell_start;
		PackedInt32Array cell_count;
		PackedByteArray skip;
		PackedVector2Array cell_offset;
		PackedFloat32Array cell_side;
		PackedFloat32Array cell_pic;
		std::vector<float> block;
		bool block_ok = false;
		float bfx = 0.0f, bfy = 0.0f, bfz = 0.0f;
	};

	struct Field {
		PackedByteArray data;
		int64_t channels = 1;
		double ox = 0.0, oz = 0.0, step = 1.0;
		int64_t sx = 0, sz = 0;
		bool ok = false;
	};
	static double at_in(const Field &p_f, double p_x, double p_z);
	Field field;
	Field prev;
	bool field_on = false;

	static int64_t key_of(int p_x, int p_y) { return ((int64_t)p_x << 32) | (int64_t)(uint32_t)p_y; }
	void fill(Chunk &p_ch, const Vector3 &p_fwd);

	std::unordered_map<int64_t, Chunk> chunks;
	std::vector<int64_t> sort_keys;
	std::vector<int32_t> inst_ent;
	std::vector<int32_t> inst_cell;
	int last_count = 0;
};

} // namespace godot
