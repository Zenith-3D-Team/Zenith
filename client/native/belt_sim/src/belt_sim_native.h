// BeltSimNative: client/scripts/world/belt_sim.gd in C++, the same API and the same results item for
// item (belt_items.gd uses it when this extension is loaded). Every rule, comment and order of
// iteration that can decide a result follows belt_sim.gd; read that file for the why.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <cstdint>
#include <memory>
#include <unordered_map>
#include <map>
#include <unordered_set>
#include <vector>

namespace godot {

class BeltSimNative : public RefCounted {
	GDCLASS(BeltSimNative, RefCounted)

public:
	typedef int64_t i64;

	static const i64 GAP = 64;
	static const i64 SPLIT_BUFFER = 51;
	static const i64 FAR = -1000000000;
	static const i64 WALK = 4096;
	static const i64 NEVER = i64(1) << 40;

	enum Kind { STRAIGHT = 1, CURVE = 2, UG_VISIBLE = 3, UG_HIDDEN = 4, SPLIT_IN = 5, SPLIT_OUT = 6, LOADER = 7, OTHER = 8 };
	enum Edge { EDGE_RUN_OFF = 0, EDGE_STOP = 1, EDGE_ORACLE = 2 };

private:
	struct Line {
		int id = 0;
		bool alive = true;
		std::vector<int> lanes;
		std::vector<int> base;
		i64 total = 0;
		i64 s = 8;
		i64 ord = 0;
		bool off = false;
		std::vector<i64> uid;
		std::vector<int32_t> itm;
		std::vector<int32_t> stk;
		std::vector<int32_t> gap;
		i64 f = 0;
		i64 span = 0;
		i64 ft = 0;
		int mode = 0;
		i64 ck = 0;
		i64 due = -1;
		i64 lp = 1;
		i64 lp2_from = i64(1) << 30;
		i64 lp2 = 0;
		i64 bp = 0;
		i64 bp_tick = -1;
		i64 arr = 0;
		i64 arr_tick = -1;
		i64 done_tick = -1;
		std::vector<int32_t> rs;
		std::vector<int32_t> rv;
		bool pr_has = false;
		i64 pr_pos = 0;
		i64 pr_t = 0;
		i64 pr_v = 0;
		std::vector<i64> holds;  // (a set: few items, if any)

		bool holds_has(i64 u) const;
		void holds_add(i64 u);
		void holds_erase(i64 u);
		i64 find_uid(i64 u) const;
	};

	struct Splitter {
		i64 unit = 0;
		int ins[4] = { -1, -1, -1, -1 };
		int outs[4] = { -1, -1, -1, -1 };
		int out_turn[2] = { -1, -1 };
		int in_turn[2] = { -1, -1 };
		int in_prio = -1;
		int out_prio = -1;
		i64 filter = 0;
		i64 crossed = 0;
		i64 node = 0;
		i64 done_tick = -1;
	};

	struct Pending {
		int lane;
		i64 pos;
		i64 uid;
		int32_t item;
		int32_t stack;
		bool hold;
	};

	struct SelfSide {  // a side-load onto the line's own back lane, put in after its step (_put_self_side)
		Line *line;
		i64 uid;
		int32_t item;
		int32_t stack;
		bool held;
		int lane;
		i64 at;
	};

	struct Carried {  // an item a read leaves past its line's back end (_carry_back)
		i64 uid;
		int32_t item;
		int32_t stack;
		i64 over;
	};

	struct QItem {
		i64 tick;
		i64 seq;
		int kind;
		i64 a, b, c, d;
		std::vector<i64> items;
	};

	// An ordered set of small ints (GDScript's Dictionary used as one keeps insertion order).
	struct OrderedSet {
		std::vector<int> v;
		std::unordered_set<int> s;
		bool add(int x) {
			if (s.insert(x).second) {
				v.push_back(x);
				return true;
			}
			return false;
		}
		bool has(int x) const { return s.count(x) != 0; }
		void clear() {
			v.clear();
			s.clear();
		}
	};

	typedef std::unordered_map<i64, std::vector<int>> Grid;

	// Settings and state seen from GDScript.
	int edge_mode = EDGE_RUN_OFF;
	Dictionary oracle;
	Dictionary given;
	bool emit_changes = true;
	bool ask_on_link = false;
	// Off: a head item's change says the step it was given and items leaving a line aren't emitted
	// (the records as before --belt-draw-head-move; belt_sim.gd's head_move).
	bool head_move = true;
	i64 tick = -1;
	i64 n_line_steps = 0;
	i64 n_shifted = 0;  // (probes) items moved with a read of a lane beside them
	// A read never leaves an item past its line's back end (belt_sim.gd's read_bound); n_past_back: those
	// that went so (probes).
	bool read_bound = true;
	i64 n_past_back = 0;
	i64 n_carried = 0;
	static constexpr int CARRY_HOPS = 8;
	// A read takes off only what the game no longer has between its own items (belt_sim.gd's
	// read_conserve: _rescue, CARRY_HOPS_CONSERVE, no carry onto an input nothing feeds).
	bool read_conserve = true;
	static constexpr int CARRY_HOPS_CONSERVE = 32;
	// A read's items ahead of its own in its line's first lane went on in the game: carried on into the
	// next line (belt_sim.gd's read_forward: _carry_forward); n_forward / n_forward_gone (probes).
	bool read_forward = true;
	i64 n_forward = 0;
	i64 n_forward_gone = 0;
	// A read's packed-run shift stops at an item outside the lane the shift would bring into it where the
	// read hasn't it; the item stays (belt_sim.gd's shift_keep). Off: it goes, the shift going on past it.
	bool shift_keep = true;
	bool read_skip_same = true;  // belt_sim.gd read_skip_same
	i64 n_same = 0;
	// Splitter inputs the bridge saw stand as their last read left them (`sh`): lane index -> the tick
	// from which their items don't cross into the outputs, until the lane's next read (belt_sim.gd's
	// _in_holds, hold_inputs).
	std::unordered_map<int, i64> _in_holds;
	bool hold_inputs = true;
	i64 n_held = 0;
	// split_wake: a splitter side that let an item through a tick or two ago (three, while its other
	// output moves) takes its turn before the belts that start moving this tick (belt_sim.gd's
	// split_wake): _ob1/_ob2 each output's hindmost item's position in it at the end of the tick before
	// and the one before that (-1 none), _side_x unit * 2 + side -> the tick an item last crossed there.
	bool split_wake = true;
	std::unordered_map<int, i64> _ob1, _ob2;
	std::unordered_map<i64, i64> _side_x;
	i64 n_woke = 0;
	void _note_outputs();
	static constexpr int TURN_FOLLOW = 8;
	i64 prof[8] = { 0, 0, 0, 0, 0, 0, 0, 0 };
	bool profile = false;
	i64 step_us[2] = { 0, 0 };
	// (profile) The queue's work: usec applying loads, checks and the rest; loads applied, loads that found the
	// lane exactly as read (a no-op in effect), line items walked by loads.
	i64 q_us[3] = { 0, 0, 0 };
	i64 q_loads = 0, q_loads_same = 0, q_load_n = 0;
	i64 load_us[8] = { 0, 0, 0, 0, 0, 0, 0, 0 };  // (profile) _apply_load by part
	i64 why_tick[10] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
	i64 us_relink = 0;
	i64 us_queue = 0;
	i64 us_step = 0;
	Dictionary why_mark;  // (probes) what marked lanes for relinking: name -> count
	String _marking;

	// Lanes.
	std::unordered_map<i64, int> _key_idx;
	std::vector<i64> l_key, l_seq, l_xnext;
	std::vector<int32_t> l_kind, l_len, l_step, l_extra, l_x0, l_y0, l_x1, l_y1;
	std::vector<int32_t> l_next, l_side, l_side_at, l_sp0, l_sp1, l_line, l_base, l_run;
	std::vector<uint8_t> l_off, l_alive;
	std::vector<std::vector<int>> l_feeders, l_sideins;
	std::vector<int> _free_lanes;
	i64 _seq = 0;
	Grid _entry_grid, _side_grid, _exit_grid;
	std::unordered_map<i64, std::vector<int>> _xnext_wait;
	std::unordered_set<i64> _units_off;
	// Lanes leading out of what the bridge sends (lm next < 0), and their walls: [tick, front uid (0:
	// none), position], oldest first (belt_sim.gd's _out_keys, _walls).
	std::unordered_set<i64> _out_keys;
	struct Wall {
		i64 tick, uid, pos;
	};
	std::unordered_map<i64, std::vector<Wall>> _walls;
	const Wall *_wall_at(i64 key, i64 t);
	bool _wall_settled(i64 key, i64 t) const;

	// Splitters (unit -> its state; node-based, so pointers stay valid while the unit stays).
	std::unordered_map<i64, Splitter> _splitters;

	// Lines.
	std::vector<std::unique_ptr<Line>> _lines;
	std::vector<int> _free_lines;
	std::unordered_map<i64, int> _uid_line;
	std::unordered_map<i64, std::vector<int>> _bucket;
	std::vector<i64> _heap;
	i64 _cur_t = -1;
	i64 _cur_ord = -1;
	bool _in_step = false;

	std::vector<int> _dirty_v;
	std::vector<uint8_t> _dirty_f;
	OrderedSet _relines;  // lanes whose lines are made again (switched off or on: no link changes)
	bool _dirty_any = false;
	bool _order_dirty = false;
	std::vector<int> _lane_pos;
	bool _run_dirty = false;
	std::vector<Pending> _pending;
	// Queued by the tick they apply at: _apply_queue once scanned (and moved) the whole queue every tick
	// (thousands of lane reads queued for later ticks during a first load). Same order as before: due
	// items by seq. (us_queue, mostly applying the reads, went from 25.3 to 23.2-23.8 s of a 90 s join
	// at -62,-26.)
	std::map<i64, std::vector<QItem>> _queue;
	i64 _qseq = 0;

	// Output.
	std::vector<i64> out_uid, out_key, out_tick, out_gone, out_mismatch;
	std::vector<i64> out_gone_tick;  // the tick each item went on
	std::vector<int32_t> out_gone_at;  // the changes before it (in out_uid)
	std::vector<int32_t> out_item, out_stack, out_pos, out_speed, out_reach, out_run;

	std::vector<int> _seg_i, _seg_v;
	i64 _ah_new = 0;
	i64 _ah_old = 0;
	bool _still = false;
	i64 _sp_newpos = 0;

	// Scratch for _step_line.
	std::vector<int32_t> _hp, _hm, _hn;
	std::vector<uint8_t> _keep;
	std::vector<i64> _new_head;
	std::vector<int> _idx_keep;
	std::vector<int32_t> _nrs, _nrv;  // (records being rebuilt: swapped with a line's)
	std::vector<SelfSide> _self_side;

	// --- queue
	void _enqueue(i64 at_tick, int kind, i64 a, i64 b, i64 c, i64 d, const std::vector<i64> *items);
	void _apply_queue(i64 now);
	void _apply_load(i64 key, const std::vector<i64> &items);
	void _apply_hold(i64 key, const std::vector<i64> &items);
	bool _lane_is(int i, const std::vector<i64> &items);
	// Items a read set this tick: another read at the same tick doesn't move them (_shift_packed).
	std::unordered_set<i64> _fresh;
	i64 _fresh_tick = -1;
	static const i64 PACK_SLACK = 8;
	std::vector<int> _shift_packed(Line *L, std::vector<i64> &P, std::vector<int32_t> &RV,
			const std::unordered_map<i64, int> &idx, const std::vector<i64> &items, i64 lo, i64 hi);
	void _turns_from_read(int o, const std::vector<i64> &items);
	std::vector<i64> _space_out(std::vector<i64> &U, std::vector<int32_t> &I, std::vector<int32_t> &S,
			std::vector<i64> &Q, std::vector<int32_t> &V, i64 bound, std::vector<Carried> &past);
	void _carry_back(int z, std::vector<Carried> ex, int origin);
	int _carry_input(int o);
	void _carry_forward(int l0, std::vector<Carried> ex);
	bool _forward_split(Splitter *sp, int l0, i64 uid, i64 item, i64 stk, i64 over);
	void _rescue(Line *L, std::vector<i64> &P, std::vector<int32_t> &RV, const std::unordered_map<i64, int> &idx,
			const std::vector<i64> &items, i64 lo, i64 hi, const std::vector<uint8_t> &skip);
	std::vector<int> _push_back(Line *L, std::vector<i64> &P, std::vector<int32_t> &RV,
			const std::unordered_map<i64, int> &idx, const std::vector<i64> &items, i64 lo, i64 hi);
	i64 _stays_at(const std::vector<i64> &P, const std::unordered_map<int, i64> &gp, int j, i64 lo, i64 hi) const;
	void _rebuild(Line *L, std::vector<i64> &U, std::vector<int32_t> &I, std::vector<int32_t> &S,
			std::vector<i64> &Q, std::vector<int32_t> &V);
	void _apply_check(i64 key, i64 count, i64 front, i64 back, i64 front_uid, i64 back_uid);
	void _apply_off(i64 unit, bool off);

	// --- lanes and topology
	static i64 _unit(i64 key) { return (key - 1) >> 3; }
	static i64 _floordiv(i64 a, i64 b);
	static i64 _cell(i64 x, i64 y) { return (i64)(((uint64_t)x << 32) ^ (uint64_t)(uint32_t)y); }
	int _lane_index(i64 key) const;
	int _new_lane();
	void _grid_add(int i);
	void _grid_remove(int i);
	void _wait_remove(int i);
	void _mark(int i);
	void _mark_near(int i);
	void _unlink(int i);
	static bool _near(i64 ax, i64 ay, i64 bx, i64 by);
	bool _ug_back_half(int i) const;
	void _link(int a);
	static i64 _round_half_even(double x);
	void _build_splitters();
	void _split_inputs_of(int out_lane, std::vector<int> &r);
	void _relink();
	void _reline();
	i64 _min_gap(Line *A);
	void _dissolve_line(int id);
	bool _joinable(int a, int b);
	void _build_lines();
	Line *_new_line();
	void _append_sorted_build(Line *L, i64 pos, i64 uid, i64 item, i64 stack);
	void _order();
	void _runs();

	// --- stepping
	Line *_line(int id) const { return (id >= 0 && id < (int)_lines.size()) ? _lines[id].get() : nullptr; }
	// belt_sim.gd's `_lines[l_line[x]]` where it doesn't check for -1: GDScript would read the last line
	// (every alive lane has a line after _build_lines, so it shouldn't happen; kept the same if it does).
	Line *_lneg(int id) const { return _line(id < 0 ? id + (int)_lines.size() : id); }
	void _set_due(Line *L, i64 d);
	void _wake(Line *L);
	void _heap_push(i64 v);
	i64 _heap_pop();
	void _step_tick();
	void _step_input(int lane, i64 t);
	void _step_side(Splitter *sp, int side, i64 t);
	void _trim_out(size_t n, size_t ng);
	void _materialize(Line *L, i64 t);
	i64 _back_at(Line *L, i64 t);
	bool _done(Line *X, i64 t);
	int _ahead(Line *A, i64 t);
	bool _is_sidesplit(int l0);
	void _step_line(Line *A, i64 t);
	void _wake_waiting(Line *A);
	bool _split_outs_asleep(int in_lane);
	bool _asleep(int lane);
	void _seg_push(int i, int v);
	i64 _tail(Line *A, i64 i0, i64 m, i64 n_eff);
	i64 _next_loose(Line *A, i64 from, i64 lim);
	void _compact_head(Line *A, int h, const std::vector<int> &idx_keep, const std::vector<i64> &new_head,
			i64 tail_first_new, i64 n_eff);
	void _transfer(Line *A, int k, int nx, i64 new_pos, i64 old_pos, i64 t);
	bool _side_put(Line *A, int k, int l0, i64 new_pos, i64 t);
	i64 _side_at(Line *X, int b, i64 at);
	void _side_insert(Line *X, int b, i64 at, i64 u, i64 item, i64 stack, bool held, i64 t);
	void _put_self_side(Line *A, i64 t);
	bool _split_put(Line *A, int k, int l0, i64 new_pos, i64 t, int h);
	bool _fallback_ok(Line *A, int k, int l0, int prio, int h, i64 t);
	bool _lane_has_items(int x, i64 t);
	int _insert(Line *X, i64 pos, i64 uid, i64 item, i64 stack, int rv);
	void _remove_at(Line *X, int j);
	void _touched(Line *L);
	void _schedule(Line *A, i64 t);
	void _enter_mode(Line *A, i64 t, int mode, i64 ck);
	void _promise(Line *A, i64 t);
	void _wake_readers(Line *A, bool worse, int depth);
	void _wake_one(int id, bool worse, int depth);

	// --- records (output)
	void _gone(i64 uid);
	void _emit_one(i64 uid, i64 item, i64 stack, int lane, i64 pos, i64 t, i64 v, i64 line_pos);
	int _lane_at(Line *L, i64 pos);
	void _rec_append(Line *X, int v);
	int _rec_index(Line *X, i64 j);
	void _rec_insert(Line *X, int j, int v);
	void _rec_remove(Line *X, int j);
	void _rec_set_one(Line *X, int j, int v);
	void _rec_norm(Line *X);
	void _emit_head(Line *A, i64 t, int h);
	void _emit_left(Line *A, int k, i64 t);
	void _emit_tail(Line *A, i64 t, int hk);
	void _rec_set_range(Line *X, int a, int b, int v);
	void _emit_pattern(Line *A, i64 t, int v);
	void _emit_pattern2(Line *A, i64 t, i64 ck);
	void _emit_range_if(Line *A, i64 t, i64 a, i64 b, i64 v);

	bool _oracle_get(i64 uid, i64 &key, i64 &pos) const;

protected:
	static void _bind_methods();

public:
	void set_lane(i64 key, i64 kind, i64 length, i64 step, Vector2i p0, Vector2i pm, Vector2i p1, i64 extra, i64 next_key);
	void set_lane_at(i64 at_tick, i64 key, i64 kind, i64 length, i64 step, Vector2i p0, Vector2i pm, Vector2i p1, i64 extra,
			i64 next_key, bool out_edge);
	void drop_lane(i64 key);
	void load_lane(i64 key, i64 at_tick, const PackedInt64Array &items);
	void check_lane(i64 key, i64 at_tick, i64 count, i64 front, i64 back, i64 front_uid, i64 back_uid);
	void set_out_edge(i64 key, bool on);
	void set_wall(i64 key, i64 at_tick, i64 uid, i64 pos);
	void hold_input(i64 key, i64 at_tick, const PackedInt64Array &items);
	void set_off(i64 unit, bool off, i64 at_tick);
	void step_to(i64 to_tick);
	void skip_to(i64 to_tick);
	i64 run_of(i64 key);
	void put_item(i64 key, i64 uid, i64 item, i64 stack, i64 pos);
	void take_item(i64 uid, bool gone);
	Dictionary take_changes();
	i64 next_of(i64 key);
	Array items_state();
	PackedInt32Array lane_fronts(const PackedInt64Array &keys);
	Dictionary stats();
	void mark_split_holds();
	Dictionary debug_links();
	Dictionary debug_item(i64 uid);

	void set_edge_mode(int v) { edge_mode = v; }
	int get_edge_mode() const { return edge_mode; }
	void set_oracle(const Dictionary &d) { oracle = d; }
	Dictionary get_oracle() const { return oracle; }
	void set_given(const Dictionary &d) { given = d; }
	Dictionary get_given() const { return given; }
	void set_emit_changes(bool v) { emit_changes = v; }
	bool get_emit_changes() const { return emit_changes; }
	void set_ask_on_link(bool v) { ask_on_link = v; }
	bool get_ask_on_link() const { return ask_on_link; }
	void set_head_move(bool v) { head_move = v; }
	bool get_head_move() const { return head_move; }
	void set_tick(i64 v) { tick = v; }
	i64 get_tick() const { return tick; }
	void set_n_shifted(i64 v) { n_shifted = v; }
	i64 get_n_shifted() const { return n_shifted; }
	void set_read_bound(bool v) { read_bound = v; }
	bool get_read_bound() const { return read_bound; }
	void set_read_conserve(bool v) { read_conserve = v; }
	bool get_read_conserve() const { return read_conserve; }
	void set_read_forward(bool v) { read_forward = v; }
	bool get_read_forward() const { return read_forward; }
	void set_n_forward(i64 v) { n_forward = v; }
	i64 get_n_forward() const { return n_forward; }
	void set_n_forward_gone(i64 v) { n_forward_gone = v; }
	i64 get_n_forward_gone() const { return n_forward_gone; }
	void set_shift_keep(bool v) { shift_keep = v; }
	bool get_shift_keep() const { return shift_keep; }
	void set_read_skip_same(bool v) { read_skip_same = v; }
	bool get_read_skip_same() const { return read_skip_same; }
	void set_n_same(i64 v) { n_same = v; }
	i64 get_n_same() const { return n_same; }
	void set_split_wake(bool v) { split_wake = v; }
	bool get_split_wake() const { return split_wake; }
	void set_n_woke(i64 v) { n_woke = v; }
	i64 get_n_woke() const { return n_woke; }
	void set_hold_inputs(bool v) { hold_inputs = v; }
	bool get_hold_inputs() const { return hold_inputs; }
	void set_n_held(i64 v) { n_held = v; }
	i64 get_n_held() const { return n_held; }
	void set_n_past_back(i64 v) { n_past_back = v; }
	i64 get_n_past_back() const { return n_past_back; }
	void set_n_carried(i64 v) { n_carried = v; }
	i64 get_n_carried() const { return n_carried; }
	void set_n_line_steps(i64 v) { n_line_steps = v; }
	i64 get_n_line_steps() const { return n_line_steps; }
	void set_profile(bool v) { profile = v; }
	bool get_profile() const { return profile; }
	PackedInt64Array get_prof() const;
	void set_prof(const PackedInt64Array &a);
	PackedInt64Array get_step_us() const;
	PackedInt64Array get_why_tick() const;
	void set_why_tick(const PackedInt64Array &a);
	i64 get_us_relink() const { return us_relink; }
	void set_us_relink(i64 v) { us_relink = v; }
	i64 get_us_queue() const { return us_queue; }
	void set_us_queue(i64 v) { us_queue = v; }
	i64 get_us_step() const { return us_step; }
	void set_us_step(i64 v) { us_step = v; }
	Dictionary get_why_mark() const { return why_mark; }
	void set_why_mark(const Dictionary &d) { why_mark = d; }
	void set_step_us(const PackedInt64Array &a);

	BeltSimNative();
};

} // namespace godot
