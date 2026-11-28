#pragma once
// InserterPoseNative: the live inserter arms' samples, events and pose (GPL-3.0, like the rest of Zenith), a twin of
// scripts/world/inserter_arms.gd's Arm (add_sample, add_event), _add_sample, _backdate, _preplan_some, _plan_pair,
// _side_at, _pose_at (the samples' pose, belt clock) and _item_from_events, on inserter_swing_core.h. One slot an
// arm; inserter_arms.gd keeps the binding, steering and drawing, and reads each frame's pose from pose_all's arrays
// (--native-inserter-pose). Not covered (the GDScript stays): the pose from events (--inserter-events=on) and the
// wall clock.

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include "inserter_swing_core.h"

#include <cstdint>
#include <deque>
#include <map>
#include <vector>

namespace godot {

class InserterPoseNative : public RefCounted {
	GDCLASS(InserterPoseNative, RefCounted)

public:
	// inserter_arms.gd's RING_TICKS and KEEP_CYCLES.
	static constexpr double RING_TICKS = 300.0;
	static constexpr int KEEP_CYCLES = 6;
	static constexpr int PREPLAN_MIN = 4;

private:
	struct Slot {
		bool used = false;
		uint32_t gen = 0;
		Vector2 base;
		zswing::End pick, drop;
		bool ends_tried = false;
		bool belt_pick = false;
		double omega = 0.014;
		double v = 0.035;
		double side = NAN;
		int last_item = 0;
		bool preplanned = false;
		// Samples, oldest first.
		std::vector<double> ticks;
		std::vector<float> angles, reaches, side_out, side_any;
		std::vector<int32_t> items;
		std::map<double, zswing::Plan> plans;
		zswing::Plan plan;
		double plan_ka = -1.0;
		double plan_still_until = -1.0;
		// Events, by tick.
		std::vector<double> ev_ticks;
		std::vector<int32_t> ev_kind, ev_count, ev_item, ev_c, ev_belt, ev_code;
		std::vector<float> ev_x, ev_y;
		std::vector<uint8_t> ev_start;
		int cycles = 0;
		// (--native-inserter-loop) What drawing needs, set by set_draw when the arm is bound or its mode decided, and
		// the per-frame state the GDScript loop kept on Arm: the pose drawn (pose_all, steering), the pincers, the
		// moving state (L4), the held item's grabs, whether it was live last frame and the moving last told.
		int64_t unit = 0;
		int32_t cx = 0, cy = 0;
		bool bound = false;
		int mode = -1; // 0 sprite, 1 rig, 2 model, 3 basic; -1 not decided
		int key = -1;
		float placed[12] = { 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0 };
		float color[4] = { 1, 1, 1, 1 };
		double card_lift = NAN;
		double cur_angle = 0.0, cur_reach = 0.0;
		int cur_item = 0;
		int cur_count = 0;
		double close = 0.0;
		double seen_angle = NAN, seen_reach = NAN, moved_at = -INFINITY;
		int held_was = 0, grabs = 0;
		bool present = false, was_live = false;
		int8_t reported = -1;
	};
	struct Queued {
		int slot;
		uint32_t gen;
	};

	std::vector<Slot> slots;
	std::vector<int> free_slots;
	std::deque<Queued> preplan;
	PackedFloat64Array out_angles, out_reaches;
	PackedInt32Array out_items, out_counts;
	PackedByteArray out_flags;
	std::vector<int64_t> hidden_chunks; // (frame_check) sorted

	bool valid(int s) const { return s >= 0 && s < (int)slots.size() && slots[s].used; }
	double side_at(const Slot &a, int i) const;
	zswing::Plan plan_pair(Slot &a, int i, double reach_slack);
	bool item_from_events(const Slot &a, double t, int &item, int &count) const;
	int count_for_sample(const Slot &a, double t, int sample_item) const;
	// One arm's pose at t (_pose_at): 1 pose and item set, 2 the item alone, 0 nothing.
	uint8_t pose_slot(Slot &a, double t, bool items_from_events, double reach_slack, double &oa, double &orr, int &oi, int &oc);
	bool is_hidden(const Slot &a) const;

protected:
	static void _bind_methods();

public:
	int add_arm();
	void remove_arm(int slot);
	void clear();
	int slot_count() const { return (int)slots.size(); }
	int preplan_size() const { return (int)preplan.size(); }
	void set_base(int slot, const Vector2 &base);
	void set_ends(int slot, double pick_a, double pick_r, double drop_a, double drop_r, double omega, double v, bool belt_pick);
	// A sample (angle and reach about the base, as rel.angle() and rel.length()); true when it was new. queue: an
	// `ih` hand's (into the preplan queue once there are two).
	bool add_sample(int slot, double k, double a, double r, int item, bool queue);
	bool add_event(int slot, double k, int kind, int count, int item, int c, double x, double y, int belt);
	void backdate(int slot, double k);
	void preplan_some(double reach_slack);
	// Every arm's pose at tick t: angles(), reaches(), items(), counts(), flags() by slot (flags 1: pose and item set,
	// 2: the item alone, 0: nothing, the arm keeps what it had). Returns how many arms were posed.
	int pose_all(double t, bool items_from_events, double reach_slack);
	// One arm's: [flags, angle, reach, item, count] (inserter_arms.gd _pose_at for one arm, as the tests call it).
	PackedFloat64Array pose_one(int slot, double t, bool items_from_events, double reach_slack);
	PackedFloat64Array angles() const { return out_angles; }
	PackedFloat64Array reaches() const { return out_reaches; }
	PackedInt32Array items() const { return out_items; }
	PackedInt32Array counts() const { return out_counts; }
	PackedByteArray flags() const { return out_flags; }
	Dictionary arm_state(int slot) const;

	// (--native-inserter-loop: the rest of inserter_arms.gd's per-arm loop, A4.)
	// The arm's record and drawing: its unit, chunk, whether bound, batch mode (0 sprite, 1 rig, 2 model, 3 basic, -1
	// none yet) and key index, the base model's transform (basis columns x, y, z, origin: 12), colour, card lift.
	void set_draw(int slot, int64_t unit, const Vector2i &chunk, bool bound, int mode, int key, const PackedFloat32Array &placed,
			const Color &color, double card_lift);
	void set_pose(int slot, double a, double r);
	// [angle, reach, item, count] drawn now (pose_all's, or what it kept).
	PackedFloat64Array get_pose(int slot) const;
	// Arm's state into the slot (as the GDScript loop left it): [angle, reach, item, close, seen angle, seen reach, moved at,
	// held was, grabs, was live, count?]; the moving told is forgotten (told again next frame).
	void set_state(int slot, const PackedFloat64Array &st);
	// The slot's: set_state's first ten, then the moving told (-1 unknown), mode, key, bound, count.
	PackedFloat64Array draw_state(int slot) const;
	void clear_modes();
	void forget_reports();
	// Live arms whose moving was last told as moving (anim.gd arm_working's count, when nothing else changed it).
	int moving_count() const;
	// Which arms' records are in `entities` (world.gd's, unit -> record); `hidden`: the chunks behind the view (cx, cy
	// pairs). The pose_all pose applied to the bound arms there not behind the view (as the GDScript loop poses them).
	// Returns the slots there that are unbound or have no mode yet (the GDScript binds them, decides the mode).
	PackedInt32Array frame_check(const Dictionary &entities, const PackedInt32Array &hidden);
	// This frame's pose_all pose applied to the slot (an arm frame_check found unbound, once bound and not hidden).
	void apply_pose(int slot);
	// The chunks behind the view again (frame_check's `hidden`: one more found while binding).
	void set_hidden(const PackedInt32Array &hidden);
	// The frame: p = [now (tick), close step (delta / CLOSE_TIME), animator (0/1), still, moving hold]; keys[k] = null or
	// [mode, caps, params] (as inserter_arms.gd _native_batches gives InserterArmsNative). Returns [results (Array per key:
	// InserterArmsNative's result or null), holding (PackedFloat64Array, 12 an arm: slot, angle, item, grabs, wrist xyz,
	// grip xyz, gripped, count), moving (PackedInt32Array: slot, 0/1 pairs, the changes), came (slots), left (slots)].
	Array frame_draw(const PackedFloat64Array &p, const Array &keys);
};

} // namespace godot
