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

#include <cmath>
#include <cstdint>
#include <unordered_map>
#include <unordered_set>
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
	static constexpr double PILE_TURN = 0.45;  // item_cards.gd PILE_TURN (turn_for)
	static constexpr double CAP_SLACK = 1.5;
	// belt_items.gd VIEW_STEP, VIEW_TURN; view_priority.gd MARGIN
	static constexpr double CAM_STEP = 2.0;
	static constexpr double CAM_TURN = 0.996;
	static constexpr double CAM_MARGIN = 3.0;
	static constexpr i64 ASK_AGAIN_MSEC = 3000;
	static constexpr double VIEW_MARGIN = 4.0;
	static constexpr double VIEW_KEEP = 10.0;
	static constexpr double MAX_YAW = 0.35;  // item_cards.gd
	// belt_records.gd
	static constexpr int TEXELS = 4;
	static constexpr int ROW = 1024;
	static constexpr int PAGE_ROWS = 16;
	static constexpr int FLOATS = TEXELS * 4;
	static constexpr int PER_PAGE = ROW * PAGE_ROWS / TEXELS;
	static constexpr int PAGE_FLOATS = PER_PAGE * FLOATS;
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
	};
	// What happened after the drawn tick, for the next job (belt_items.gd State.later).
	struct Later {
		int what;  // 0 a change, 1 gone
		i64 uid, tick, item, stack, key, pos, speed, reach, run;
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

	// --- the job (belt_items.gd Job)
	double fold_tick = 0.0;
	double lead = 2.0;
	i64 now_msec = 0;
	bool full = false;
	std::unordered_map<i64, Look> known;
	int model_cap = -1;
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
	bool view_cull = true;
	bool lead_on = true;
	bool gone_order = true;
	bool pile_one = true;  // --belt-draw-pile: a copy's record points at its item's (else its own, as before)
	bool dumping = false;
	std::unordered_set<i64> dropped;  // lanes dropped in this job's messages
	int plan_depth = 0;
	// Results
	Array written;
	Array unknown;
	i64 records_written = 0, changes = 0, coalesced = 0, early_n = 0, renewed = 0, gone_n = 0, parked = 0, unparked = 0;
	std::vector<i64> resend;
	Ref<Image> paths;
	std::vector<i64> dump_ids;
	std::vector<float> dump_recs;
	std::vector<i64> dump_gone;

	static i64 _chunk_key(int cx, int cz) { return (i64)(((uint64_t)(uint32_t)cx << 32) ^ (uint64_t)(uint32_t)cz); }
	static double _yaw_for(i64 seed);
	static Arc _arc(const int32_t *m);
	Vector4 _point(i64 key, double pos) const;
	Vector2i _advance(i64 key, i64 pos, i64 d);
	bool _straight_kind(i64 key) const;
	Vector2 _dir(i64 key) const;
	Vector3 _at(const Item *it, double t) const;
	bool _set_view();
	bool _in_view(i64 key, i64 pos, i64 reach) const;
	void _park(Item *it);
	void _unpark(Item *it);
	void _replan_parked();
	void _apply_changes(const Dictionary &ch);
	void _go_or_hold(i64 uid, i64 t, i64 now, std::unordered_set<i64> &held);
	void _go(i64 uid);
	void _apply_one(i64 uid, i64 item, i64 stack, i64 key, i64 pos, i64 t0, i64 v, i64 reach, i64 run);
	bool _apply_early(i64 uid, i64 item, i64 stack, i64 key, i64 pos, i64 t0, i64 v, i64 reach, i64 run, i64 now);
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
	void set_lane(i64 key, const PackedInt32Array &meta);
	void drop_lane(i64 key);
	Dictionary run_job(const Dictionary &changes, const Dictionary &params);
	Array drawn(i64 key, double t);
	bool has_item(i64 uid) const { return items.has(uid); }
	Dictionary stats() const;

	BeltDrawNative();
	~BeltDrawNative();
};

} // namespace godot
