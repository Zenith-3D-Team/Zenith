#pragma once
// InserterIngestNative: the inserter arms' `ih` hands and `ie` events taken in whole (GPL-3.0, like the rest of
// Zenith), perf A5, --native-inserter-ingest. A twin of scripts/world/inserter_arms.gd's handle (the list loop and
// _update for a known, bound arm), handle_events (the event loop for one), _end_frame (the missing count) and the
// stale sweep's last_heard, for arms whose InserterPoseNative slot keeps their samples and events. GDScript binds an
// arm (bind_arm) once it has been through _update and _bind with its record and ends known; from then on its hands
// and events are applied here straight into the pose object (its C++ add_sample, add_event, backdate). Every hand
// checks that the arm (inserter_arms.gd _arms) and its record (world.entities) are still the objects it was bound
// with: anything else (unknown, unbound, a new record, a gone event) goes back to GDScript as decoded, plain rows,
// which runs them through the same code as before. forget_chunk drops a chunk's arms (world.entities_changed: a
// record's pack can change in place); clear drops all (ModelLibrary's generation or packs' version changed, reset).

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include "inserter_pose_native.h"

#include <cstdint>
#include <unordered_map>

namespace godot {

class InserterIngestNative : public RefCounted {
	GDCLASS(InserterIngestNative, RefCounted)

public:
	// inserter_arms.gd's MISSING_FRAMES, Swing.Ev and EV_PLACED.
	static constexpr int MISSING_FRAMES = 2;
	static constexpr int EV_PICKED = 1;
	static constexpr int EV_DROPPED = 2;
	static constexpr int EV_SYNC = 4;
	static constexpr int EV_GONE = 5;
	static constexpr int EV_PLACED = 6;

private:
	struct Entry {
		int slot = -1;
		uint64_t arm = 0;  // the Arm's and the record's instance ids when bound
		uint64_t rec = 0;
		Vector2 base;
		Vector2i chunk;
		bool live = true;  // bound: its hands and events taken here (false: forgotten, kept for its seen flag)
		bool seen = false;  // a hand applied since the last end_frame
		bool ev_any = false;
		double last_heard = -1.0;
		double synced = -1.0;  // last_heard as the Arm was last told (heard)
	};

	Ref<InserterPoseNative> pose;
	std::unordered_map<int64_t, Entry> arms;
	// (--native-inserter-ingest2) The GDScript tells drop() of every arm it drops, so an entry's arm is always the one
	// bound: bound() skips the arm map's lookup.
	bool trust = false;
	PackedInt64Array first_events;
	int64_t hands_native = 0;
	int64_t hands_back = 0;
	int64_t events_native = 0;
	int64_t events_back = 0;

	// The bound entry for this unit when its arm and record are still the ones bound, else nullptr.
	Entry *bound(int64_t unit, const Dictionary &arm_map, const Dictionary *entities);

protected:
	static void _bind_methods();

public:
	void set_pose(const Ref<InserterPoseNative> &p_pose) { pose = p_pose; }
	void bind_arm(int64_t unit, int slot, Object *arm, Object *rec, const Vector2 &base, const Vector2i &chunk, bool ev_any,
			double last_heard);
	void forget(int64_t unit);
	void forget_chunk(const Vector2i &chunk);
	// Every arm back to GDScript for its next hand (each binds again); what end_frame needs is kept.
	void unbind_all();
	void clear();
	bool has(int64_t unit) const {
		auto it = arms.find(unit);
		return it != arms.end() && it->second.live;
	}
	int size() const { return (int)arms.size(); }
	// One `ih` part's list (Array, PackedInt32Array or PackedInt64Array; deltas: z = 1) at tick k: the hands of bound
	// arms applied (a sample each, into the preplan queue), the rest returned as plain [unit, x, y, item, ...].
	PackedInt64Array add_hands(const Variant &list, bool deltas, int64_t k, const Dictionary &entities, const Dictionary &arm_map);
	// One `ie` message's list: bound arms' picks, drops, statuses and syncs applied (placed skipped), the rest (gone,
	// unknown or unbound arms) returned as plain [kind, unit, tick, a, b, c, x, y, belt, ...]. first_events() then
	// says which bound arms had their first event (Arm.ev_any).
	PackedInt64Array add_events(const Variant &list, bool deltas, const Dictionary &arm_map);
	PackedInt64Array take_first_events();
	// inserter_arms.gd _end_frame's loop over every arm (arm_map, with the GDScript's `seen` and `missing`): returns
	// the units to drop (missing MISSING_FRAMES updates in a row, no events); `missing` is kept as the GDScript keeps it.
	PackedInt64Array end_frame(const Dictionary &arm_map, const Dictionary &seen, Dictionary missing);
	// [unit, last_heard, ...] for bound arms heard here since the last call (the stale sweep reads Arm.last_heard).
	PackedFloat64Array heard(const Dictionary &arm_map);
	// (tests) [hands applied here, hands returned, events applied here, events returned].
	PackedInt64Array counts() const;

	// (--native-inserter-ingest2, perf wave 4 T3) inserter_arms.gd's _drop_arm tells of each arm it drops (gone,
	// stale, missing): with set_trust(true) an entry's arm is the one bound, and bound() reads only the record.
	void set_trust(bool p_trust) { trust = p_trust; }
	void drop(int64_t unit) { arms.erase(unit); }
	// end_frame's twin without the arms' map: this object's own entries (a forgotten one asks its Arm for events),
	// then `unbound` (unit -> Arm: the arms with no entry, kept by the GDScript); `missing` touched only for arms not
	// kept, or kept ones while it isn't empty. Returns the units to drop.
	PackedInt64Array end_frame2(const Dictionary &seen, Dictionary missing, const Dictionary &unbound);
	// The stale sweep's half for the entries: the units last heard before `threshold` (a live entry by its own
	// last_heard; a forgotten one by the larger of it and its Arm's, its Arm told the native's). The GDScript sweeps
	// the unbound arms itself.
	PackedInt64Array sweep(double threshold);
};

} // namespace godot
