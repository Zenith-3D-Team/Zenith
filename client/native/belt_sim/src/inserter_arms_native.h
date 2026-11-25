#pragma once
// Native twin of the per-arm geometry in scripts/world/inserter_arms.gd (GPL-3.0, like the rest of Zenith):
// _draw_sprite_arm / sprite_cards, _draw_model_arm, _draw_arm and _draw_rig_arm (with _elbow, _piece, _segment,
// aim, along) for a whole batch of arms at once, written straight into MultiMesh instance buffers (12 floats an
// instance, 16 with a colour), so the GDScript builds no Transform3D per piece and copies none into a buffer.
// The pose (angle, reach, item: the swing model) stays in GDScript; this class takes the drawn pose in.
// Every method returns [pieces: Array of PackedFloat32Array, counts: PackedInt32Array, wrists: PackedFloat32Array
// (xyz per arm, where a held item hangs from), grips: PackedFloat32Array (xyz per arm), gripped: bool, stretch: float
// (rig only: the biggest stretch, 1 = none)]. Pieces are in arm order; each buffer holds at least `caps[p]`
// instances (so it can go to RenderingServer.multimesh_set_buffer as it is).

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

namespace godot {

class InserterArmsNative : public RefCounted {
	GDCLASS(InserterArmsNative, RefCounted)

protected:
	static void _bind_methods();

public:
	// inp, 6 floats an arm: base x, base y (tiles), angle, reach, hand (0 open, 1 closed), card lift (NAN: 0).
	// params: [0] grip height, [1] shoulder height, [2] upper arm, [3] forearm, [4] stretch, [5] claw default,
	// [6] camera pitch (degrees), [7] hand tip, [8] picture depth, [9] hand picture depth, [10..12] widths (base,
	// open, closed), [13] item drop. Pieces: base, open, closed.
	Array sprite_arms(const PackedFloat32Array &inp, const PackedInt32Array &caps, const PackedFloat32Array &params) const;
	// inp, 5 floats an arm: base x, base y, angle, reach, holding (0/1).
	// params: [0] shoulder height, [1] wrist height, [2] upper arm (stretched), [3] forearm (stretched), [4] upper arm
	// as modelled, [5] forearm as modelled, [6] held_grip (0/1), [7] grip height, [8] claw, [9] item drop.
	// Pieces: upper, open, closed.
	Array model_arms(const PackedFloat32Array &inp, const PackedInt32Array &caps, const PackedFloat32Array &params) const;
	// inp, 8 floats an arm: base x, base y, angle, reach, colour r, g, b, a. Buffers of 16 floats an instance.
	// params: [0] base top, [1] shoulder height, [2] wrist height, [3] upper arm, [4] forearm, [5..7] turntable size,
	// [8..10] shoulder size, [11..13] hand size, [14..16] finger size, [17] arm thickness, [18..20] steel colour,
	// [21..23] dark steel colour. Pieces: turntable, shoulder, upper, forearm, hand, fingers (two an arm).
	Array basic_arms(const PackedFloat32Array &inp, const PackedInt32Array &caps, const PackedFloat32Array &params) const;
	// inp, 17 floats an arm: base x, base y, angle, reach, close (0..1), the base model's transform (basis columns
	// x, y, z, origin). params: [0..2] hinge, [3..5] pivot, [6..8] shoulder, [9..11] elbow, [12..14] grip (all rest
	// pose), [15] upper length, [16] fore length, [17] held_grip, [18] grip height, [19] item drop, [20] rig reach,
	// [21] has turntable, then per pincer (A at 22, B at 30): present, head (3), axis (3), closed angle.
	// Pieces: turntable, lower, upper, pincer A, pincer B.
	Array rig_arms(const PackedFloat32Array &inp, const PackedInt32Array &caps, const PackedFloat32Array &params) const;
};

} // namespace godot
