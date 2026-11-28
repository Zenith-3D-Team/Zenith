#pragma once
// InserterSwingNative: scripts/world/inserter_swing.gd's functions bound for GDScript (GPL-3.0, like the rest of
// Zenith), on inserter_swing_core.h. Plans come back as PackedFloat64Array, 4 numbers a keyframe (tick, angle,
// reach, item); an end pose is a PackedFloat64Array [angle, reach] or empty (unknown); an event [tick, kind,
// count, item, angle, reach, status code]. inserter_arms.gd's _plan_pair uses `plan` (--native-inserter-swing);
// tests/inserter_swing_native_test.gd checks every function against the GDScript.

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/vector2.hpp>

namespace godot {

class InserterSwingNative : public RefCounted {
	GDCLASS(InserterSwingNative, RefCounted)

protected:
	static void _bind_methods();

public:
	int travel_ticks(double d_angle, double d_reach, double omega, double v, bool complete_rot, bool complete_ext) const;
	int part_ticks(double way, double speed, bool complete) const;
	double part_at(double from, double to, double speed, double j) const;
	PackedFloat64Array leg(double k0, double a0, double r0, double k1, double a1, double r1, int item, double omega, double v,
			bool complete, int end_item) const;
	Vector2 hand_pos(double angle, double reach) const;
	bool near(double angle, double reach, const PackedFloat64Array &e, double tol) const;
	double delta(double from, double to, double side, double ambiguous) const;
	bool on_side(double angle, const PackedFloat64Array &pick, const PackedFloat64Array &drop) const;
	// s: [ka, aa, ra, ia, kb, ab, rb, ib].
	PackedFloat64Array plan(const PackedFloat64Array &s, const PackedFloat64Array &pick, const PackedFloat64Array &drop,
			double omega, double v, double side, bool belt_pick, int last_item, double reach_slack) const;
	// [angle, reach, item].
	PackedFloat64Array at(const PackedFloat64Array &keys, double t) const;
	PackedFloat64Array plan_events(const PackedFloat64Array &e0, const PackedFloat64Array &e1, const PackedFloat64Array &pick,
			const PackedFloat64Array &drop, double omega, double v, double side) const;
	// [angle, reach, item].
	PackedFloat64Array extrapolate(double an, double rn, int item, bool still, const PackedFloat64Array &pick,
			const PackedFloat64Array &drop, double omega, double v, double side, double ticks) const;
};

} // namespace godot
