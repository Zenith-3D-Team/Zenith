// BeltLatticeNative: client/scripts/world/belt_lattice.gd in C++ (--belt-draw-lattice-native, on by
// default when this extension is loaded and the simulation is BeltSimNative). Lanes the game has packed
// are drawn as a sliding lattice of their one kind: this keeps what the bridge said of each lane
// (note_read, note_check, drop), the lanes' meta (set_lane, as belt_items.gd's State.lanes), the drawn
// lanes' slots in its own records (f3d_belt_lattice) and the mask of their centre lines, and update()
// after each job's simulation decides which lanes join or leave and writes their records. Function for
// function after belt_lattice.gd, rounding to float32 where GDScript does, so both write the same
// records (tools/belt_draw_diff.py: 0 differences). Read belt_lattice.gd for the why.
#pragma once

#include "belt_native_common.h"

#include <algorithm>

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>
#include <godot_cpp/variant/vector4.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace godot {

class BeltSimNative;

class BeltLatticeNative : public RefCounted {
	GDCLASS(BeltLatticeNative, RefCounted)

public:
	typedef int64_t i64;

	// belt_lattice.gd
	static constexpr i64 GAP = 64;
	static constexpr i64 CELLS = 4;
	static constexpr i64 MASK = 2048;
	static constexpr i64 DRIFT = 24;
	static constexpr i64 SPEED_CHECKS = 2;
	static constexpr double LAYER_STEP = 0.006;
	static constexpr i64 LAYERS = 4;
	static constexpr i64 MAX_LENGTH = 1024;
	static constexpr double VIEW_KEEP = 12.0;
	static constexpr i64 SLICES = 2;
	static constexpr i64 MAX_STACK = 4;
	static constexpr double PILE_TURN = 0.45;
	static constexpr i64 IDS = (i64)1 << 20;
	static constexpr i64 TURN_RUN = 40503;  // (turn_id) belt_lattice.gd TURN_RUN
	static constexpr i64 SEED_AFTER = 120;  // (turn_id) belt_lattice.gd SEED_AFTER
	static constexpr i64 SEED_WL = 28;  // (turn_id) belt_lattice.gd SEED_WL
	// belt_sim.gd's lane kinds
	enum Kinds { STRAIGHT = 1, CURVE = 2, UG_VISIBLE = 3, UG_HIDDEN = 4, SPLIT_IN = 5, SPLIT_OUT = 6, LOADER = 7, OTHER = 8 };

private:
	struct Lane {
		i64 item = 0;
		i64 kind_key = 0;
		std::vector<int> slots;  // records a slot: slots[k * stack + j] is slot k's copy j (0: its own record)
		i64 r0 = 0;  // its phase: the front slot's line position on tick t0
		i64 t0 = 0;
		i64 v = 0;
		i64 pend_v = -1;  // a new speed seen at pend_n checks in a row
		i64 pend_n = 0;
		i64 pend_t = 0;  // (settle) the tick pend_v was first seen at
		i64 hole_at = -1;  // (settle) the tick of the newest hole cut in it while it stands (-1: none open)
		i64 hole_v = 0;  // (settle) the speed the simulation has had the lane at since
		std::vector<int> cells;
		int stack = 1;
		i64 who = 0;  // who the item at line position r0 is on tick t0 (modulo IDS)
		i64 run = 0;  // its run's seed (modulo IDS)
		i64 next = 0;  // the lane its items go on into when it was drawn, 0 none
		i64 flow_q = 0;  // (creep) the running share of the time most of its items move, of FLOW_ONE
		i64 flow_t = -1;  // (creep) the tick of its last share's update
		i64 run_t = -1;  // (creep) the tick most of its items started moving, -1 while they stand
		bool creeping = false;  // (creep) sliding at its share of the belt's speed
		std::vector<int32_t> fu;  // (creep_flow) its recent front items' ids (low 31 bits), oldest first
		i64 none_t = -1;  // (creep_flow) the tick the simulation was first seen with none on it, -1 while it has
		bool gated = false;  // (creep_flow) stood for want of net flow: takes the simulation's speed again only with it
		i64 slide_at = -1;  // (close) the tick a one-gap slide starts (-1: none)
		i64 slide_v = 0;  // (close) its speed (1/256 a tick; 0: set and written with the next update)
		i64 slide_more = 0;  // (close) slides queued after it (takes ahead while it slides)
		i64 step_bal = 0;  // (creep_step) slides its fronts queued (+) less those close queued (-), not yet matched
		i64 bal_t = -1;  // (creep_step) the tick step_bal last changed
		i64 go_lo = -1;  // (start) the tick its motion started from, its record's clock held there before (-1: none)
		i64 go_hi = -1;  // (start) the tick its motion stops, its record's clock held there after (-1: none)
		i64 release_t = -1;  // (start) the tick its run in front was extended (-1: none): its next start is at once
		bool mark_moving = false;  // (mask_inner) whether its mask cells are a moving lane's (end to end)
		i64 open = 0;  // (mask_open) its end cells left unmarked: OPEN_EXIT, OPEN_ENTRY
		i64 open_d = 0;  // (handover) how far its slots are off its items at its open end (0: none)
		i64 go_next = -1;  // (start) stopping on go_hi: the tick it goes on again from there (-1: none)
	};
	struct LKind {
		int base = -1;
		int cap = 0;
		int top = 0;
		std::vector<int> free;
		Vector3i told = Vector3i(-1, -1, -1);
	};
	struct Info {
		bool full = false;
		i64 item = -1;  // -1: none or mixed
		int stack = 1;  // the read's most common
		i64 front = -1;  // the front item's position at the last read or check (-1: none)
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
	struct Ends {
		Vector4 exit, entry;
		Vector2 d_exit, d_entry;
	};

	// --- the simulation (lane_fronts)
	Ref<RefCounted> sim_ref;
	BeltSimNative *sim = nullptr;

	// --- belt_items.gd State.lanes / arcs / height, as the job gives them
	std::unordered_map<i64, Meta> lanes;
	std::unordered_map<i64, Arc> arcs;
	double height = 0.16;

	// --- belt_lattice.gd's state
	beltn::Ordered<i64, Info> info;
	beltn::Ordered<i64, Lane *> drawn;
	beltn::Ordered<i64, LKind *> kinds;
	beltn::Records records;
	double base = -1.0;
	Ref<Image> mask;
	std::vector<uint8_t> mask_n;  // lanes marking each cell
	bool mask_dirty = false;
	i64 lanes_n = 0;  // lanes drawn after the last update
	i64 slots_n = 0;
	beltn::Ordered<i64, i64> want;  // lane key -> item: lanes to draw
	beltn::Ordered<i64, bool> undrawn;  // wanted but not drawn yet (their look not known yet)
	beltn::Ordered<i64, bool> dirty;  // read, checked or dropped since the last update
	std::unordered_map<i64, Vector2> mids;  // lane key -> its middle (tiles)
	Rect2 planned;
	bool planned_all = false;
	bool planned_any = false;
	i64 round_no = 0;
	int planned_cap = -2;
	std::unordered_map<i64, i64> feeds;  // lane key -> the drawn lane whose items go on into it
	bool item_turns = true;  // belt_lattice.gd item_turns (set_item_turns)
	bool turn_id = true;  // belt_lattice.gd turn_id (set_turn_id)
	bool edge_shut = true;  // belt_lattice.gd edge_shut (set_edge_shut)
	double shown = -1.0;  // belt_lattice.gd shown (set_shown): the drawn clock when the update is first drawn

	// --- this update
	bool on = true;
	bool world = true;
	bool world_all = true;  // belt_lattice.gd world_all
	bool standing_obs = true;  // belt_lattice.gd standing_obs
	bool piles = true;
	bool unison = true;  // belt_lattice.gd unison
	bool settle = true;  // belt_lattice.gd settle (K19)
	static constexpr i64 SETTLE_GAPS = 2;
	static constexpr i64 HOLE_TICKS = 8;
	i64 drawn_tick = -1;  // belt_lattice.gd drawn_tick
	std::unordered_map<i64, i64> moving_since;  // belt_lattice.gd moving_since
	void set_settle(bool v) { settle = v; }
	bool creep = false;  // belt_lattice.gd creep
	static constexpr i64 FLOW_ONE = 1024;
	static constexpr i64 CREEP_TAU = 120;
	static constexpr i64 CREEP_ON = 256;
	static constexpr i64 CREEP_OFF = 102;
	static constexpr i64 CREEP_RUN_GAPS = 4;
	void set_creep(bool v) { creep = v; }
	bool _creep(Lane *ln, i64 lv, i64 step, i64 tick, i64 pred, i64 f);
	bool creep_flow = true;  // belt_lattice.gd creep_flow
	static constexpr int FLOW_HIST = 16;
	static constexpr i64 CREEP_FLOW_ON = 300;
	static constexpr i64 CREEP_FLOW_OFF = 100;
	static constexpr i64 NONE_TICKS = 30;
	static constexpr i64 FLOW_GATE = 1000;
	static constexpr i64 FLOW_GATE_TICKS = 120;
	i64 _t_draw(i64 tick) const;
	static i64 _phase_at(const Lane *ln, i64 t) {
		return beltn::posmod(ln->r0 - ln->v * (_held_t(ln, t) - ln->t0) - _slide_moved(ln, t), GAP);
	}
	// (start) belt_lattice.gd's.
	bool start = true;
	static constexpr i64 RELEASE_TICKS = 120;
	i64 links_seen = -1;
	void set_start(bool v) { start = v; }
	bool start_stops = false;  // (start) belt_lattice.gd start_stops
	void set_start_stops(bool v) { start_stops = v; }
	static i64 _held_t(const Lane *ln, i64 t) {
		i64 c = t;
		if (ln->go_hi >= 0) {
			c = std::min(c, ln->go_hi);
		}
		if (ln->go_lo >= 0) {
			c = std::max(c, ln->go_lo);
		}
		return c;
	}
	void _release_behind(i64 key, i64 tick);
	// (close, mask_inner, sim_full) belt_lattice.gd's.
	bool close = true;
	bool mask_inner = true;
	bool mask_own = true;  // (mask_own) belt_lattice.gd's
	bool mask_open = true;  // (mask_open) belt_lattice.gd's
	static constexpr i64 OPEN_EXIT = 1;
	static constexpr i64 OPEN_ENTRY = 2;
	static constexpr i64 OPEN_TOL = 4;
	void _open_ends(const std::unordered_map<i64, i64> &front_at, i64 tick);
	bool sim_full = true;
	static constexpr i64 CLOSE_MORE = 4;
	void set_close(bool v) { close = v; }
	void set_mask_inner(bool v) { mask_inner = v; }
	void set_mask_own(bool v) { mask_own = v; }
	void set_mask_open(bool v) { mask_open = v; }
	bool handover = true;  // (handover) belt_lattice.gd's
	static constexpr i64 HAND_SLACK = 3;
	void set_handover(bool v) { handover = v; }
	static double _hand_code(const Lane *ln, i64 k, i64 length);
	void set_sim_full(bool v) { sim_full = v; }
	bool tail = true;  // (tail) belt_lattice.gd's
	static constexpr i64 TAIL_NEED = 2 * GAP;
	void set_tail(bool v) { tail = v; }
	std::unordered_map<i64, i64> fed_gone;  // (sim_full) belt_lattice.gd fed_gone
	static constexpr i64 FED_GONE_TICKS = 1800;
	void feed_gone(i64 key, i64 tick) { fed_gone[key] = tick; }
	static i64 _slide_moved(const Lane *ln, i64 t) {
		if (ln->slide_at < 0 || ln->slide_v <= 0) {
			return 0;
		}
		return std::clamp<i64>(ln->slide_v * (t - ln->slide_at), 0, GAP);
	}
	static i64 _slide_ticks(const Lane *ln) { return (i64)std::ceil((double)GAP / (double)std::max<i64>(1, ln->slide_v)); }
	void _slide_done(Lane *ln);
	static void _slide_clear(Lane *ln) {
		ln->slide_at = -1;
		ln->slide_v = 0;
		ln->slide_more = 0;
	}
	void _close_behind(i64 key, i64 at);
	void set_creep_flow(bool v) { creep_flow = v; }
	bool creep_step = false;  // belt_lattice.gd creep_step
	static constexpr i64 STEP_BAL_TICKS = 90;
	void set_creep_step(bool v) { creep_step = v; }
	i64 _front_flow(Lane *ln, i64 u, i64 tick);
	void _creep_step(Lane *ln, i64 u, i64 step, i64 f, i64 fv, bool has, i64 tick);
	bool _creep_flow(Lane *ln, i64 lv, i64 u, i64 step, i64 tick, i64 pred, i64 f);
	void _creep_stop(Lane *ln, i64 r0, i64 tick);
	void set_drawn_tick(i64 t) { drawn_tick = t; }
	bool dump_on = false;
	std::unordered_map<i64, Look> known;
	std::vector<i64> dump_ids;
	std::vector<float> dump_recs;
	std::vector<i64> dump_gone;
	Array written;
	// Lanes this update removed from the drawn ones and added to them (the drawing's lattice lanes: it parks
	// and counts the items they hide, belt_draw_native.cpp _relattice).
	std::vector<i64> removed_keys;
	std::unordered_map<i64, bool> added_keys;

	static i64 _uid(i64 key, i64 k) { return -(key * 8 + k + 1); }
	static bool _drawn_kind(int kind);
	static i64 _kind_key(i64 item, int model_cap) { return model_cap < 0 ? item : -item - 1; }
	static i64 _world_phase(const int32_t *m);
	static i64 _world_tau(const int32_t *m);
	static i64 _world_run(const int32_t *m);
	static i64 _fdiv(i64 a, i64 b) { return (a - beltn::posmod(a, b)) / b; }
	void _set_motion(Lane *ln, i64 r0, i64 v, i64 tick);
	i64 _lag(i64 dv, i64 tick) const { return shown >= 0.0 && dv != 0 ? beltn::roundi((double)dv * (shown - (double)tick)) : 0; }
	void _identify(i64 key, Lane *ln, const int32_t *m, i64 tick);
	bool _seed(Lane *ln, i64 at, i64 num, i64 tick);
	static i64 _seed_who(const Lane *ln, i64 at, i64 num, i64 tick);
	bool _ring(i64 key);
	Vector4 _point(i64 key, double pos) const;
	Ends _ends(i64 key, i64 length) const;
	Vector4 _along(i64 key, double pos, i64 length, const Ends &ends) const;
	i64 _wanted(i64 key);
	int _stack_of(i64 key);
	i64 _obs_front(i64 key);
	void _remove(i64 key);
	void _write_lane(i64 key, Lane *ln, const int32_t *m, const Look &look, int stack);
	void _drop_slot(i64 key, Lane *ln, LKind *kd);
	void _mark(i64 key, Lane *ln);
	void _unmark(Lane *ln);

protected:
	static void _bind_methods();

public:
	void set_sim(Object *p_sim);
	void set_small_pages(bool on) { records.set_small(on); }
	void set_item_turns(bool on) { item_turns = on; }
	void set_turn_id(bool on) { turn_id = on; }
	void set_edge_shut(bool on) { edge_shut = on; }
	void set_shown(double t) { shown = t; }
	void set_lane(i64 key, const PackedInt32Array &meta, const PackedFloat64Array &arc);
	void note_read(i64 key, i64 length, const PackedInt64Array &items);
	void note_check(i64 key, i64 length, i64 count, i64 front, i64 back);
	void drop(i64 key);
	Dictionary update(i64 tick, const Rect2 &view, bool view_all, const Dictionary &known_looks, int model_cap, bool full,
			bool dump, double records_base, double items_height, bool lattice_on, bool world_phase, bool pile_slots, bool unison_on,
			bool world_all_phase, bool standing_from_obs);
	PackedInt64Array clear();
	Dictionary hole(i64 key, i64 at, i64 pos, bool dump);  // (--inserter-handoff) belt_lattice.gd hole
	Array drawn_lattice(i64 kind_key, double t);
	Array kind_keys();
	i64 drawn_speed(i64 key);  // a drawn lane's lattice speed (1/256 a tick), -1 when not drawn (tests)
	bool has_drawn() const { return drawn.size() > 0; }
	i64 get_lanes_n() const { return lanes_n; }
	void set_lanes_n(i64 v) { lanes_n = v; }
	i64 get_slots_n() const { return slots_n; }
	void set_slots_n(i64 v) { slots_n = v; }

	BeltLatticeNative();
	~BeltLatticeNative();
};

} // namespace godot
