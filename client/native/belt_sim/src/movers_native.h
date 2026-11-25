#pragma once
// Native twin of MoverRecords.write_xform (scripts/world/mover_records.gd): the 3x4 transform of
// each robot / walking creature from its record, for a whole batch in one call (the motion-vector
// path of robot_swarm.gd and creatures.gd). GPL-3.0, like the other natives here.

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

namespace godot {

class MoversNative : public RefCounted {
	GDCLASS(MoversNative, RefCounted)

public:
	static constexpr int FLOATS = 32; // MoverRecords.FLOATS
	static constexpr int STRIDE = 16; // MultiMesh floats an instance

private:
	int last_skipped = 0;

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
	// Debug/test: one record's transform (12 floats).
	PackedFloat32Array xform_of(const PackedFloat32Array &p_data, int p_slot, double p_c_even, double p_c_odd, double p_inv_rate);
};

} // namespace godot
