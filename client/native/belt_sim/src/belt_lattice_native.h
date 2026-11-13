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
		std::vector<int> cells;
		int stack = 1;
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

	// --- this update
	bool on = true;
	bool world = true;
	bool piles = true;
	bool unison = true;  // belt_lattice.gd unison
	bool dump_on = false;
	std::unordered_map<i64, Look> known;
	std::vector<i64> dump_ids;
	std::vector<float> dump_recs;
	std::vector<i64> dump_gone;
	Array written;

	static i64 _uid(i64 key, i64 k) { return -(key * 8 + k + 1); }
	static bool _drawn_kind(int kind);
	static i64 _kind_key(i64 item, int model_cap) { return model_cap < 0 ? item : -item - 1; }
	static i64 _world_phase(const int32_t *m);
	Vector4 _point(i64 key, double pos) const;
	Ends _ends(i64 key, i64 length) const;
	Vector4 _along(i64 key, double pos, i64 length, const Ends &ends) const;
	i64 _wanted(i64 key);
	int _stack_of(i64 key);
	void _remove(i64 key);
	void _write_lane(i64 key, Lane *ln, const int32_t *m, const Look &look, int stack);
	void _drop_slot(i64 key, Lane *ln, LKind *kd);
	void _mark(i64 key, Lane *ln);
	void _unmark(Lane *ln);

protected:
	static void _bind_methods();

public:
	void set_sim(Object *p_sim);
	void set_lane(i64 key, const PackedInt32Array &meta, const PackedFloat64Array &arc);
	void note_read(i64 key, i64 length, const PackedInt64Array &items);
	void note_check(i64 key, i64 length, i64 count, i64 front, i64 back);
	void drop(i64 key);
	Dictionary update(i64 tick, const Rect2 &view, bool view_all, const Dictionary &known_looks, int model_cap, bool full,
			bool dump, double records_base, double items_height, bool lattice_on, bool world_phase, bool pile_slots, bool unison_on);
	PackedInt64Array clear();
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
