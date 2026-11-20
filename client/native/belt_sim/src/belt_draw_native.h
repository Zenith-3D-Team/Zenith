// BeltDrawNative: belt_items.gd's Job in C++, from the simulation's changes to the GPU records: the
// items' motions (_apply_changes, _plan, _plan_path, _renew), their slots in each kind's MultiMesh, the
// paths' texture and the records' pages (belt_records.gd). belt_items.gd uses it (--belt-draw-native,
// on by default) when this extension is loaded and the simulation is BeltSimNative: it gives the job's
// messages' lanes (set_lane, drop_lane), then run_job() with the changes, and uploads what comes back.
// Every computation follows belt_items.gd, down to where it rounds to float32 (Vector3, Vector4 and
// the records are float32, the rest double), so that both paths write the same records
// (tools/belt_draw_diff.py: 0 differences on a capture). Read belt_items.gd for the why.
#pragma once

#include "belt_native_common.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/plane.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>
#include <godot_cpp/variant/vector4.hpp>

#include <climits>
#include <cmath>
#include <cstdint>
#include <map>
#include <unordered_map>
#include <unordered_set>
#include <map>
#include <vector>

namespace godot {

class BeltSimNative;

class BeltDrawNative : public RefCounted {
	GDCLASS(BeltDrawNative, RefCounted)

public:
	typedef int64_t i64;

	// belt_items.gd
	static constexpr double LAYER_STEP = 0.006;
	static constexpr int LAYERS = 4;
	static constexpr int PATH_WIDTH = 1024;
	static constexpr int MAX_ROWS = 256;
	static constexpr double SPACING = 0.15;
	static constexpr int MAX_POINTS = 64;
	static constexpr int KEEP_UPDATES = 40;
	static constexpr int CAP_EVERY = 30;
	static constexpr int MAX_STACK = 4;
	static constexpr i64 TURN_RUN = 40503;  // (turn_id) belt_lattice.gd TURN_RUN
	static constexpr i64 VARIANT_STEP = 1 << 20;  // item_cards.gd VARIANT_STEP
	static constexpr double PILE_TURN = 0.45;  // item_cards.gd PILE_TURN (turn_for)
	static constexpr double CAP_SLACK = 1.5;
	// belt_items.gd VIEW_STEP, VIEW_TURN; view_priority.gd MARGIN
	static constexpr double CAM_STEP = 2.0;
	static constexpr double CAM_TURN = 0.996;
	static constexpr double CAM_MARGIN = 3.0;
	static constexpr i64 ASK_AGAIN_MSEC = 3000;
	// (--belt-sim-ask=view) A lattice lane whose count is wrong, at most this often; one out of the
	// planned view this often at first, doubling to the most while it keeps failing.
	static constexpr i64 ASK_LATTICE_MSEC = 30000;
	static constexpr i64 ASK_OUT_MSEC = 12000;
	static constexpr i64 ASK_OUT_MAX_MSEC = 60000;
	// (park_lat) How far lattice lanes go on past a ring of them (no end ahead).
	static constexpr i64 LAT_FAR = (i64)1 << 40;
	// The counters that walk every slot (slots, slots_hidden, parked by why) are taken every this many jobs.
	static constexpr int GAUGE_EVERY = 16;
	static constexpr double VIEW_MARGIN = 4.0;
	static constexpr double VIEW_KEEP = 10.0;
	static constexpr double MAX_YAW = 0.35;  // item_cards.gd
	// belt_records.gd (a page's size: records.per_page)
	static constexpr int TEXELS = 4;
	static constexpr int ROW = 1024;
	static constexpr int FLOATS = TEXELS * 4;
	static constexpr int MIN_RUN = 64;
	static constexpr float HIDDEN = -1.0f;
	// belt_sim.gd's lane kinds
	enum Kinds { STRAIGHT = 1, CURVE = 2, UG_VISIBLE = 3, UG_HIDDEN = 4, SPLIT_IN = 5, SPLIT_OUT = 6, LOADER = 7, OTHER = 8 };

private:
	struct Item;

	// A slot of a kind: an item (k 0) or the k'th copy of its pile (belt_items.gd Layer).
	struct SlotRef {
		Item *it = nullptr;
		int k = 0;
	};

	struct Item {
		i64 uid = 0;
		i64 item_id = 0;
		i64 key = 0;
		double c = 1.0, s = 0.0;
		i64 num = -1;  // (turn_id) the number its turn is from (-1: its uid's)
		Vector3 from, step;
		double t_from = 0.0, t_to = 0.0;
		std::vector<float> path;
		bool hidden = false;
		int slot = -1;
		int count = 1;
		std::vector<int> layers;  // its pile's copies' slots: k = index + 1
		std::vector<int> layer_stamp;
		double code = 0.0;
		int code_at = -1;
		int path_at = -1;
		int path_cap = 0;
		bool dirty = false;
		int stamp = 0;
		i64 lane = 0, pos = 0, t0 = 0, v = 0, reach = 0, run = 0;
		double renew = -1.0;
		int kept = 0;
		bool parked = false;
		bool lat = false;  // (park_lat) parked because its motion lies on lanes the lattice draws
		bool waits = false;  // (later_tick) changes of it wait in `waiting`
		i64 ver = 0;  // (later_tick) changed whenever anything _apply_early reads of it may have
		double hide_at = -1.0;  // (--inserter-handoff) the tick a hand took it: texel 3 w (belt_items.gd Item.hide_at)
		double show_at = -1.0;  // the tick a hand put it on its belt: texel 3 w, negative (Item.show_at)
	};

	struct Kind {
		std::vector<SlotRef> slots;
		std::vector<int> free;
		std::vector<SlotRef> fresh;
		std::vector<int> emptied;
		int base = -1;
		int cap = 0;
		Vector3i told = Vector3i(-1, -1, -1);
		Vector3 lift;
		double pile = 0.07;
		bool known = false;
	};

	struct Meta {
		int32_t m[9];
	};
	struct Arc {
		bool ok = false;
		double a[5] = { 0, 0, 0, 0, 0 };
	};
	struct Look {
		Vector3 lift;
		bool turns = false;
		double pile = 0.07;
		i64 variants = 0;  // how many variants its model has (belt_items.gd _look's 4th)
	};
	// What happened after the drawn tick, for the next job (belt_items.gd State.later).
	struct Later {
		int what;  // 0 a change, 1 gone
		i64 uid, tick, item, stack, key, pos, speed, reach, run;
	};
	// (later_tick) One item's waiting changes in order (from `head`), and when the first was last tried
	// early: an item's held changes are taken in its own order, as the list does.
	struct Waiting {
		std::vector<Later> q;
		size_t head = 0;
		i64 tried = -2;  // the item's ver at the first's last failed try (-1: no item then; -2: not tried)
		i64 retry_at = INT64_MAX;  // (a start waiting for the item's t0) tried again once the drawn tick is there
		i64 filed = INT64_MIN;  // the tick it was last filed under in `due`
	};

	// belt_native_common.h: the records' pages and a map in GDScript's insertion order.
	template <class K, class V>
	using Ordered = beltn::Ordered<K, V>;
	typedef beltn::Records Records;

	// --- the simulation (BeltSimNative: next_of, run_of)
	Ref<RefCounted> sim_ref;
	BeltSimNative *sim = nullptr;

	// --- State (belt_items.gd State)
	Ordered<i64, Item *> items;
	Ordered<i64, Kind *> kinds;
	double height = 0.16;
	Vector3 square = Vector3(0.0f, 0.0f, -1.0f);
	std::unordered_map<i64, Meta> lanes;
	std::unordered_map<i64, Arc> arcs;
	Records records;
	double base = -1.0;
	std::vector<Item *> dirty;
	std::unordered_set<Item *> pathed;
	std::vector<float> path_tex;
	int path_top = 0;
	std::unordered_map<int, std::vector<int>> path_free;
	bool path_dirty = false;
	Ordered<Item *, bool> renewing;
	std::vector<Later> later;
	// (later_tick, --belt-draw-later-tick) `later` kept by item and by tick instead: a job takes only the
	// items whose first waiting change is due, whose item changed since its last early try, or (the lanes'
	// links moved) all of them, where the list walked every waiting change every job.
	std::unordered_map<i64, Waiting> waiting;
	std::map<i64, std::vector<i64>> due;  // tick -> uids whose first change takes effect (or is tried again) then
	std::vector<i64> retry;  // uids whose item changed while changes of it wait
	i64 ver_seq = 0;
	i64 later_n = 0;  // changes waiting (either way)
	bool lanes_moved = true;  // set_lane changed a lane, or drop_lane, since the last job
	i64 links_seen = -1;
	bool graph_now = true;  // this job: the lanes' links may have moved since the last

	std::unordered_map<i64, i64> last_i;  // (coalesce) kept between jobs for its buckets
	std::unordered_map<i64, i64> puts;  // (--inserter-handoff) belt_items.gd Job._puts
	std::map<std::pair<i64, i64>, std::vector<i64>> peeks;  // (inserter, tick) -> uids: belt_items.gd State.peeks
	Ordered<Item *, Vector2i> kept;
	std::unordered_set<i64> held_chunks;  // packed chunk coordinates
	std::unordered_map<i64, i64> asked;
	Vector3 capped_square = Vector3(0.0f, 0.0f, -2.0f);
	int cap_jobs = 0;
	int capped_at = -2;
	bool capped_cam = false;  // and whether the camera led it, from where, facing which way
	Vector3 capped_cam_pos = Vector3(INFINITY, INFINITY, INFINITY);
	Vector3 capped_cam_dir;
	Rect2 planned_view;
	bool planned_any = false;
	int writes = 0;
	// The lanes the lattice draws (its update's lanes added and removed, given each job), and for each how
	// far lattice lanes go on past its exit (1/256): an item whose motion ends within that is hidden by the
	// lattice's mask all along (park_lat parks it; the counters count it).
	std::unordered_set<i64> lat;
	std::unordered_map<i64, i64> lat_ahead;
	bool lat_ahead_dirty = false;
	// (park_lat) Items parked for the lattice, in GDScript's order (the order they are planned again in hands
	// out slots: both twins alike, so a kind is compacted in the same job in each).
	Ordered<Item *, bool> lat_items;
	// Lanes dropped in this job's messages, as they were (an item parked on one stands where it is for the
	// far icons' hand-over).
	std::unordered_map<i64, Meta> dropped_meta;
	std::unordered_map<i64, Arc> dropped_arcs;
	// (ask view) Lattice lanes whose checks failed in places or ids alone since last asked (asked the moment
	// they leave the lattice), and out-of-view lanes' intervals now (ms).
	std::unordered_set<i64> lat_pend;
	std::unordered_map<i64, i64> out_every;
	int jobs_n = 0;
	i64 g_slots = 0, g_hidden = 0, g_parked_view = 0, g_parked_lat = 0;  // the counters last taken

	// --- the job (belt_items.gd Job)
	double fold_tick = 0.0;
	double lead = 2.0;
	i64 now_msec = 0;
	bool full = false;
	std::unordered_map<i64, Look> known;
	int model_cap = -1;
	bool known_given = false;  // this job's params gave the looks (they changed)
	// The camera drawing, when it leads Items in 3D's cap (belt_items.gd Job.cam_led, view_priority.gd).
	bool cam_led = false;
	Vector3 cam_pos;
	Vector3 cam_dir = Vector3(0.0f, 0.0f, -1.0f);
	std::vector<Plane> cam_planes;
	bool far_given = false;
	std::unordered_set<i64> far_built;
	Rect2 view;
	bool view_all = true;
	bool coalesce = true;
	bool early = true;  // --belt-draw-early: changes after the drawn tick taken now when nothing shows early
	bool early_stop = true;  // --belt-draw-early-stop: a record cut to end at a stop waiting that it runs into
	bool view_cull = true;
	bool lead_on = true;
	bool gone_order = true;
	bool pile_one = true;  // --belt-draw-pile: a copy's record points at its item's (else its own, as before)
	bool dump_parks = true;  // --belt-draw-dump-parks: a park dumped as the record's going (belt_items.gd)
	bool later_tick = true;  // --belt-draw-later-tick
	bool park_lat = false;  // --belt-draw-park-lattice
	bool turn_id = false;  // (turn_id) belt_lattice.gd turn_id (with item_turns): an item turned by its number
	std::unordered_map<i64, i64> nums_of;  // (turn_id) uid -> the simulation's number for it (belt_items.gd nums)
	int ask_mode = 0;  // --belt-sim-ask: 0 all (every failing lane every 3 s, as before), 1 view
	bool ask_near = true;  // --belt-sim-ask-near: a job's asks nearest the view first
	bool dumping = false;
	std::unordered_set<i64> dropped;  // lanes dropped in this job's messages
	int plan_depth = 0;
	// Results
	Array written;
	Array unknown;
	i64 records_written = 0, changes = 0, coalesced = 0, early_n = 0, early_stop_n = 0, renewed = 0, gone_n = 0, parked = 0, unparked = 0;
	i64 early_tries = 0, ask_view = 0, ask_lat = 0, ask_out = 0, ask_held = 0, lat_parks = 0, lat_unparks = 0, drained = 0;
	std::vector<i64> resend;
	Ref<Image> paths;
	std::vector<i64> dump_ids;
	std::vector<float> dump_recs;
	std::vector<i64> dump_gone;

	static i64 _chunk_key(int cx, int cz) { return (i64)(((uint64_t)(uint32_t)cx << 32) ^ (uint64_t)(uint32_t)cz); }
	static double _yaw_for(i64 seed);
	static Arc _arc(const int32_t *m);
	Vector4 _point(i64 key, double pos) const;
	static Vector4 _point_m(const int32_t *m, const Arc *arc, double pos, double height);
	Vector2i _advance(i64 key, i64 pos, i64 d);
	bool _straight_kind(i64 key) const;
	Vector2 _dir(i64 key) const;
	Vector3 _at(const Item *it, double t) const;
	bool _set_view();
	bool _in_view(i64 key, i64 pos, i64 reach) const;
	bool _on_lat(i64 key, i64 pos, i64 reach) const;
	int _hide_why(i64 key, i64 pos, i64 reach, i64 v) const;
	void _set_lat(Item *it, bool on);
	void _park(Item *it);
	void _unpark(Item *it);
	void _replan_parked();
	void _relattice(const PackedInt64Array &add, const PackedInt64Array &del, bool graph);
	void _lat_ahead();
	bool _stand_dropped(Item *it, i64 now);
	void _touch(Item *it);
	void _apply_changes(const Dictionary &ch);
	bool _held(i64 uid, const std::unordered_set<i64> &held) const;
	void _hold(const Later &e, std::unordered_set<i64> &held, bool tried, i64 retry_at);
	void _file(i64 uid, Waiting &w);
	void _drain_due(i64 now);
	void _drain(i64 uid, i64 now, bool all);
	void _ask_mismatches(const Dictionary &ch);
	void _gauges();
	void _go_or_hold(i64 uid, i64 t, i64 now, std::unordered_set<i64> &held);
	void _go(i64 uid);
	void _apply_one(i64 uid, i64 item, i64 stack, i64 key, i64 pos, i64 t0, i64 v, i64 reach, i64 run);
	void _cut_at_stop(Item *it, i64 key, i64 pos, i64 t0, i64 now);
	bool _apply_early(i64 uid, i64 item, i64 stack, i64 key, i64 pos, i64 t0, i64 v, i64 reach, i64 run, i64 now,
			i64 *retry_at = nullptr);
	void _plan(Item *it);
	void _plan_path(Item *it, i64 dist);
	void _renew();
	void _keep_or_drop();
	void _remove(i64 uid);
	void _free_path(Item *it);
	void _mark(Item *it);
	void _set_count(Item *it, i64 n);
	void _place(Item *it);
	void _cap_models();
	bool _cam_moved() const;
	void _rekey(Item *it, i64 key);
	i64 _model_key(const Item *it) const;
	int _put(Kind *kind, SlotRef e);
	void _unplace(Item *it);
	void _write();
	void _records(const std::vector<SlotRef> &batch, int writing);
	void _compact(Kind *kind);
	Kind *_kind_of(i64 key);

protected:
	static void _bind_methods();

public:
	void set_sim(Object *p_sim);
	void set_small_pages(bool on) { records.set_small(on); }
	void set_lane(i64 key, const PackedInt32Array &meta);
	void drop_lane(i64 key);
	Dictionary run_job(const Dictionary &changes, const Dictionary &params);
	Array drawn(i64 key, double t);
	bool has_item(i64 uid) const { return items.has(uid); }
	// (tests) The kind item `uid` is drawn as (belt_items.gd Item.key), 0 for none.
	i64 key_of(i64 uid) {
		Item **p = items.get(uid);
		return p == nullptr ? 0 : (*p)->key;
	}
	// An item's hide_at (the tick its record hides from on the drawn clock), -1 none or no such item (tests).
	double hide_of(i64 uid) {
		Item **it = items.get(uid);
		return it == nullptr ? -1.0 : (*it)->hide_at;
	}
	Dictionary stats() const;

	BeltDrawNative();
	~BeltDrawNative();
};

} // namespace godot
