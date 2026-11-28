#pragma once
// Native twin of MoverRecords.write_xform (scripts/world/mover_records.gd): the 3x4 transform of
// each robot / walking creature from its record, for a whole batch in one call (the motion-vector
// path of robot_swarm.gd and creatures.gd). GPL-3.0, like the other natives here.

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace godot {

class MoversNative : public RefCounted {
	GDCLASS(MoversNative, RefCounted)

public:
	static constexpr int FLOATS = 32; // MoverRecords.FLOATS
	static constexpr int STRIDE = 16; // MultiMesh floats an instance

private:
	int last_skipped = 0;

	// M2: world.gd's rail index (_rail_grid) per chunk, as movers.gd last copied it.
	struct RailEntry {
		int kind = 0; // 0 ground, 1 elevated, 2 ramp
		Vector2 at;
		double third = 0.0; // reach squared, or a ramp's direction
	};
	struct RailChunk {
		std::unordered_map<int64_t, std::pair<int, int>> cells; // cell -> (start, count) in entries
		std::vector<RailEntry> entries;
	};
	std::unordered_map<int64_t, RailChunk> rail_chunks;
	double ramp_length = 16.0;
	double elevation = 4.5;
	double elevated_track = 4.45;
	double rail_cell = 4.0;
	double chunk_size = 32.0;
	double rail_height_of(const Vector2 &p, double was) const;

protected:
	static void _bind_methods();

public:
	// For slots[i] >= 0 writes instance i of `buf` (transform, then INSTANCE_CUSTOM: mode 0 robots
	// (slot, 1, 0, 0 as the script left 14-15), mode 1 walkers (0, 1, slot + 1, 1)).
	// Returns the buffer (a copy: a packed array passed in is copy-on-write, writing it in place would
	// not reach the caller); slots < 0 are left as they were and counted by skipped().
	PackedFloat32Array write_xforms(const PackedFloat32Array &p_data, const PackedInt32Array &p_slots, int p_count,
			const PackedFloat32Array &p_buf, double p_c_even, double p_c_odd, double p_inv_rate, int p_mode);
	int skipped() const { return last_skipped; }
	// M3: MoverRecords.position for slots[0..count) (records' clocks c_even / c_odd as float32, rate).
	PackedVector3Array positions(const PackedFloat32Array &p_data, const PackedInt32Array &p_slots, int p_count,
			double p_c_even, double p_c_odd, double p_rate);
	// M3: robot_swarm.gd _any_bot_active over slots[0..count) (_slot_active for each).
	bool any_active(const PackedFloat32Array &p_data, const PackedInt32Array &p_slots, int p_count,
			double p_c_even, double p_c_odd, double p_inv_rate);

	// M2: world.gd rail_height for a batch. set_rail_params(ramp_length, elevation, elevated_track, cell, chunk);
	// set_rail_chunk(coord, cells [cx, cy, start, count]..., entries [kind, x, y, third]...) copies one
	// chunk's _rail_grid; rail_chunks_for(points) lists the chunks rail_height reads for them (x, y pairs).
	void set_rail_params(double p_ramp_length, double p_elevation, double p_elevated_track, double p_cell, double p_chunk);
	void set_rail_chunk(const Vector2i &p_coord, const PackedInt32Array &p_cells, const PackedFloat64Array &p_entries);
	void clear_rail_chunk(const Vector2i &p_coord);
	void clear_rails() { rail_chunks.clear(); }
	int rail_chunk_count() const { return (int)rail_chunks.size(); }
	PackedInt32Array rail_chunks_for(const PackedVector2Array &p_points) const;
	PackedFloat64Array rail_heights(const PackedVector2Array &p_points, const PackedFloat64Array &p_was) const;

	// Debug/test: one record's transform (12 floats).
	PackedFloat32Array xform_of(const PackedFloat32Array &p_data, int p_slot, double p_c_even, double p_c_odd, double p_inv_rate);
};

} // namespace godot
