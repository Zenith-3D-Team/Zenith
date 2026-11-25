#pragma once
// Native twin of the hot loops in the Immersive Enemies add-on's biter_ragdoll.gd: the 6/12-leg
// damped-spring limb solver (_step_limbs) and the pairwise separation of active ragdolls
// (_step_active's first loop). The rigid-body integration keeps asking the game for ground height and
// walls, so it stays GDScript. GPL-3.0, like the other natives here.

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

class BiterRagdollNative : public RefCounted {
	GDCLASS(BiterRagdollNative, RefCounted)

public:
	static constexpr int LS = 8; // floats a limb: swing, swing_v, lift, lift_v, knee, knee_v, twist, twist_v
	static constexpr int SEP = 8; // floats a body in separate(): x, y, z, radius, vx, vy, vz, (unused)

private:
	PackedVector3Array out_limbs;
	PackedFloat32Array out_twists;

protected:
	static void _bind_methods();

public:
	// One limb-state array (LS floats a limb) from the script's eight per-limb arrays.
	PackedFloat32Array make_state(const PackedFloat32Array &p_swing, const PackedFloat32Array &p_swing_v,
			const PackedFloat32Array &p_lift, const PackedFloat32Array &p_lift_v, const PackedFloat32Array &p_knee,
			const PackedFloat32Array &p_knee_v, const PackedFloat32Array &p_twists, const PackedFloat32Array &p_twists_v);
	// BiterRagdoll._step_limbs for one body. Returns the new state (a packed array passed in is
	// copy-on-write, so it cannot be written in place); last_limbs() / last_twists() give what the
	// script hands to set_ragdoll_limbs (a severed limb's twist is the 100.0 sentinel).
	PackedFloat32Array step_limbs(const PackedFloat32Array &p_state, const PackedByteArray &p_severed, int p_limb_count,
			double p_dt, const Vector3 &p_lin_acc, const Vector3 &p_ang, const Quaternion &p_quat,
			const Vector3 &p_normal, bool p_grounded, double p_bounce_kick);
	PackedVector3Array last_limbs() const { return out_limbs; }
	PackedFloat32Array last_twists() const { return out_twists; }
	// Pairwise separation of n bodies (SEP floats each), in the script's order; returns the data with
	// x, z and vx, vy, vz updated.
	PackedFloat32Array separate(const PackedFloat32Array &p_data, int p_count, double p_dt);
};

} // namespace godot
