// BeltLatticeNative: belt_lattice.gd in C++. Function for function after belt_lattice.gd; each comment
// there says why. Here only what differs: where GDScript rounds to float32 (Vector2/3/4 components, the
// records) this casts at the same point, and the rest is double, so both write identical records.
#include "belt_lattice_native.h"

#include "belt_sim_native.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <unordered_set>

using namespace godot;
using namespace godot::beltn;

BeltLatticeNative::BeltLatticeNative() {
}

BeltLatticeNative::~BeltLatticeNative() {
	for (Lane *ln : drawn.val_list()) {
		delete ln;
	}
	for (LKind *kd : kinds.val_list()) {
		delete kd;
	}
}

void BeltLatticeNative::set_sim(Object *p_sim) {
	sim = Object::cast_to<BeltSimNative>(p_sim);
	sim_ref = Ref<RefCounted>(Object::cast_to<RefCounted>(p_sim));
}

// belt_items.gd's State.lanes[key] = meta (and arcs[key] for a curve, as belt_items.gd's _arc made it).
void BeltLatticeNative::set_lane(i64 key, const PackedInt32Array &meta, const PackedFloat64Array &arc) {
	if (meta.size() < 9) {
		return;
	}
	Meta mt;
	for (int i = 0; i < 9; i++) {
		mt.m[i] = meta[i];
	}
	lanes[key] = mt;
	if (mt.m[0] == CURVE && arc.size() >= 5) {
		Arc a;
		a.ok = true;
		for (int i = 0; i < 5; i++) {
			a.a[i] = arc[i];
		}
		arcs[key] = a;
	} else {
		arcs.erase(key);
	}
}

// ---------------------------------------------------------------- what the bridge said

void BeltLatticeNative::note_read(i64 key, i64 length, const PackedInt64Array &items) {
	i64 n = items.size() / 4;
	Info none;
	if (n == 0) {
		info.set(key, none);
		dirty.set(key, true);
		return;
	}
	dirty.set(key, true);
	const i64 *it = items.ptr();
	i64 item = it[1];
	i64 front = it[2];
	bool full = n >= std::max<i64>(1, length / GAP);
	int counts[MAX_STACK + 1] = { 0, 0, 0, 0, 0 };
	for (i64 j = 0; j < n; j++) {
		counts[std::clamp<i64>(it[j * 4 + 3], 1, MAX_STACK)] += 1;
		if (j == 0) {
			continue;
		}
		if (it[j * 4 + 1] != item) {
			none.front = front;
			info.set(key, none);
			return;
		}
		if (it[j * 4 + 2] - it[j * 4 - 2] > GAP + 2) {
			full = false;
		}
	}
	int stack = 1;
	for (int c = 2; c <= MAX_STACK; c++) {
		if (counts[c] > counts[stack]) {
			stack = c;
		}
	}
	Info e;
	e.full = full;
	e.item = item;
	e.stack = stack;
	e.front = front;
	info.set(key, e);
}

void BeltLatticeNative::note_check(i64 key, i64 length, i64 count, i64 front, i64 back) {
	Info e;
	Info *have = info.get(key);
	if (have != nullptr) {
		e = *have;
	}
	e.full = count >= std::max<i64>(1, length / GAP) && count <= length / GAP + 2 && back - front <= (GAP + 2) * (count - 1);
	e.front = count > 0 ? front : -1;
	info.set(key, e);
	dirty.set(key, true);
}

// (standing_obs) The front item's position at the bridge's last read or check of the lane, -1 none.
i64 BeltLatticeNative::_obs_front(i64 key) {
	Info *e = info.get(key);
	return e == nullptr ? -1 : e->front;
}

void BeltLatticeNative::drop(i64 key) {
	fed_gone.erase(key);
	info.erase(key);
	mids.erase(key);
	moving_since.erase(key);
	dirty.set(key, true);
	lanes.erase(key);
	arcs.erase(key);
}

// ---------------------------------------------------------------- the update

Dictionary BeltLatticeNative::update(i64 tick, const Rect2 &view, bool view_all, const Dictionary &known_looks, int model_cap,
		bool full, bool dump, double records_base, double items_height, bool lattice_on, bool world_phase, bool pile_slots, bool unison_on,
		bool world_all_phase, bool standing_from_obs) {
	on = lattice_on;
	unison = unison_on;
	world = world_phase;
	world_all = world_all_phase;
	standing_obs = standing_from_obs;
	piles = pile_slots;
	dump_on = dump;
	height = items_height;
	base = records_base;
	known.clear();
	Array kk_list = known_looks.keys();
	for (int i = 0; i < kk_list.size(); i++) {
		Array look = known_looks[kk_list[i]];
		if (look.size() >= 2) {
			Look l;
			l.lift = (Vector3)look[0];
			l.turns = (bool)look[1];
			l.pile = look.size() > 2 ? (double)look[2] : 0.07;
			known[(i64)kk_list[i]] = l;
		}
	}
	written = Array();
	dump_ids.clear();
	dump_recs.clear();
	dump_gone.clear();
	removed_keys.clear();
	added_keys.clear();
	// Which lanes to draw: all again when the planned ground or the look changed, else only those the
	// bridge said something about.
	bool replan = full || view_all != planned_all || !planned_any || (!view_all && !planned.encloses(view)) || model_cap != planned_cap;
	std::vector<i64> look_at;
	if (replan) {
		planned_cap = model_cap;
		planned = view.grow((real_t)VIEW_KEEP);
		planned_all = view_all;
		planned_any = true;
		want.clear();
		undrawn.clear();
		look_at = info.key_list();
		for (i64 key : drawn.key_list()) {
			if (!info.has(key)) {
				look_at.push_back(key);
			}
		}
	} else {
		look_at = dirty.key_list();
	}
	// (A lane's stacks change only with a read: a drawn lane checked for its phase alone keeps its own.)
	std::unordered_set<i64> heard(dirty.idx.size());
	for (i64 key : dirty.key_list()) {
		heard.insert(key);
	}
	dirty.clear();
	Ordered<i64, bool> check;  // lanes to draw or check now
	for (i64 key : look_at) {
		i64 item = _wanted(key);
		if (item < 0) {
			want.erase(key);
			undrawn.erase(key);
		} else {
			want.set(key, item);
			check.set(key, true);
			if (!drawn.has(key)) {
				undrawn.set(key, true);
			}
		}
	}
	Ordered<i64, bool> unknown;
	for (i64 key : (replan ? drawn.key_list() : look_at)) {
		Lane **pln = drawn.get(key);
		if (pln == nullptr) {
			continue;
		}
		Lane *ln = *pln;
		i64 *w = want.get(key);
		if (w == nullptr || *w != ln->item || ln->kind_key != _kind_key(*w, model_cap)) {
			_remove(key);
			if (w != nullptr) {
				undrawn.set(key, true);
			}
		}
	}
	// A slice of the drawn lanes has its phase checked against the simulation's each update.
	round_no += 1;
	i64 slice = round_no % SLICES;
	for (i64 key : drawn.key_list()) {
		if (unison || posmod(key >> 3, SLICES) == slice) {
			check.set(key, true);
		}
	}
	for (i64 key : undrawn.key_list()) {
		check.set(key, true);
	}
	PackedInt64Array keys;
	for (i64 key : check.key_list()) {
		if (want.has(key)) {
			keys.push_back(key);
		}
	}
	PackedInt32Array fronts;
	if (keys.size() > 0 && sim != nullptr) {
		fronts = sim->lane_fronts(keys);
	}
	// (turn_id) Each lane's front item's number.
	PackedInt32Array nums;
	if (turn_id && item_turns && keys.size() > 0 && sim != nullptr) {
		nums = sim->lane_fronts(keys, 3);
	}
	// (tail) Whether a packed block's tail has gone onto each lane, nothing close behind it.
	PackedInt32Array tails;
	if (tail && keys.size() > 0 && sim != nullptr) {
		tails = sim->lane_tails(keys, (int)TAIL_NEED);
	}
	// (creep) The speed most of each lane's items move at.
	PackedInt32Array lane_v;
	if ((creep || creep_step) && keys.size() > 0 && sim != nullptr) {
		lane_v = sim->lane_fronts(keys, creep_flow || creep_step ? 2 : 1);
	}
	// (mask_open) The simulation's front item on each lane it has one on: where its items are.
	std::unordered_map<i64, i64> front_at;
	if (mask_open && mask_own) {
		for (i64 q = 0; q < keys.size() && q * 3 + 2 < fronts.size(); q++) {
			if (fronts[q * 3 + 2] > 0) {
				front_at[keys[q]] = fronts[q * 3];
			}
		}
	}
	// (start) The simulation's links changed (lane_fronts linked them): a drawn lane whose next lane is new lets its
	// run back go (belt_lattice.gd).
	if (start && settle && sim != nullptr && sim->get_links_ver() != links_seen) {
		links_seen = sim->get_links_ver();
		for (i64 key2 : drawn.key_list()) {
			Lane *l2 = *drawn.get(key2);
			i64 nx = sim->next_of(key2);
			if (nx == l2->next) {
				continue;
			}
			if (l2->next != 0) {
				auto ff = feeds.find(l2->next);
				if (ff != feeds.end() && ff->second == key2) {
					feeds.erase(ff);
				}
			}
			l2->next = nx;
			if (nx != 0) {
				feeds[nx] = key2;
				_release_behind(key2, tick);
			}
		}
	}
	const int32_t *fr = fronts.ptr();
	int nk = (int)keys.size();
	if (fronts.size() < nk * 3) {
		nk = (int)(fronts.size() / 3);
	}
	for (int q = 0; q < nk; q++) {
		i64 key = keys[q];
		i64 item = *want.get(key);
		i64 kk = _kind_key(item, model_cap);
		auto lk = known.find(kk);
		if (lk == known.end()) {
			unknown.set(kk, true);
			continue;
		}
		auto lf = lanes.find(key);
		if (lf == lanes.end()) {
			continue;
		}
		const int32_t *m = lf->second.m;
		i64 f = fr[q * 3];
		i64 v = fr[q * 3 + 1];
		bool has = fr[q * 3 + 2] > 0;
		Lane **pln = drawn.get(key);
		Lane *ln = pln == nullptr ? nullptr : *pln;
		bool wl = world && (m[0] == STRAIGHT || m[0] == UG_VISIBLE || (world_all && (m[0] == CURVE || m[0] == SPLIT_IN || m[0] == SPLIT_OUT)));
		// (standing_obs: the game's front on the lane at its last read or check, -1 none.)
		i64 obs = standing_obs ? _obs_front(key) : -1;
		int st = (ln == nullptr || replan || heard.count(key)) ? _stack_of(key) : ln->stack;
		bool short_ = (i64)fr[q * 3 + 2] < std::max<i64>(1, (i64)m[1] / GAP);
		if ((sim_full && ln != nullptr && ln->v > 0 && has && short_ && fed_gone.count(key) && tick - fed_gone[key] <= FED_GONE_TICKS)
				|| (tail && q < (i64)tails.size() && tails[q] == 1 && (!has || (short_ && (ln == nullptr || ln->v > 0))))) {
			// (sim_full) Moving, and the simulation has it short of full; (tail) or a packed block's tail went onto it
			// (or past it) with nothing close behind (belt_lattice.gd).
			Info *e = info.get(key);
			if (e != nullptr) {
				e->full = false;
			}
			want.erase(key);
			if (ln != nullptr) {
				_remove(key);
			}
			continue;
		}
		// (creep_step sees the lanes in this update's check: all of them with unison on, the default.)
		if (creep_step && close && settle && ln != nullptr && q * 3 + 2 < (int)lane_v.size()) {
			_creep_step(ln, lane_v[q * 3 + 2], m[2], f, v, has, tick);
		}
		if (close && settle && ln != nullptr && ln->slide_at >= 0) {
			// (close) A slide a take ahead asked for: written at its belt's speed; once over, standing a gap on.
			if (ln->v > 0) {
				_slide_clear(ln);
			} else if (ln->slide_v == 0) {
				i64 n_stand = 0;
				for (i64 qs = ln->r0; qs < (i64)m[1]; qs += GAP) {
					n_stand += 1;
				}
				if (m[2] <= 0 || n_stand != std::max<i64>(1, (i64)std::ceil((double)m[1] / (double)GAP))) {
					_slide_clear(ln);
				} else {
					ln->slide_v = m[2];
					_write_lane(key, ln, m, lk->second, ln->stack);
				}
			} else if (drawn_tick >= ln->slide_at + _slide_ticks(ln)) {
				_slide_done(ln);
				_write_lane(key, ln, m, lk->second, ln->stack);
			}
		}
		if (start && settle && ln != nullptr) {
			if (ln->release_t >= 0 && tick - ln->release_t > RELEASE_TICKS) {
				ln->release_t = -1;
			}
			if (ln->go_hi >= 0) {
				// (start) Stopping on go_hi: standing on its phase then, once the drawn clock is there; moving again
				// before, on from go_next (belt_lattice.gd).
				if (has && v > 0 && ln->go_next < 0) {
					i64 t_next = tick - roundi((double)posmod(_phase_at(ln, ln->go_hi) - f, GAP) / (double)v);
					if (t_next <= ln->go_hi + 1 && v == ln->v) {
						ln->go_hi = -1;
						_write_lane(key, ln, m, lk->second, ln->stack);
					} else {
						ln->go_next = std::max(t_next, ln->go_hi + 1);
					}
				}
				if (ln->go_hi >= 0) {
					if (drawn_tick >= ln->go_hi) {
						i64 hi = ln->go_hi;
						i64 nxt = ln->go_next;
						_set_motion(ln, _phase_at(ln, hi), 0, hi);
						ln->go_next = -1;
						if (nxt >= 0 && has && v > 0) {
							_set_motion(ln, ln->r0, v, nxt);
							ln->go_lo = nxt;
							ln->pend_n = 0;
							ln->pend_v = -1;
						}
						_write_lane(key, ln, m, lk->second, ln->stack);
						if (nxt >= 0 && has && v > 0) {
							continue;
						}
					} else {
						continue;
					}
				}
			}
		}
		if (settle && ln != nullptr && ln->hole_at >= 0) {
			// (The hole a take left: closed once the drawn clock is a gap's time past it.)
			if (has && v > 0) {
				ln->hole_v = v;
			}
			if (ln->v > 0) {
				ln->hole_at = -1;  // (a moving lane's holes end with their slots' periods)
			} else if (drawn_tick >= ln->hole_at + (ln->hole_v > 0 ? (i64)std::ceil((double)GAP / (double)ln->hole_v) : HOLE_TICKS)) {
				ln->hole_at = -1;
				_write_lane(key, ln, m, lk->second, ln->stack);
			}
		}
		if (close && settle && ln != nullptr && ln->v == 0 && ln->slide_at >= 0) {
			continue;  // (close) Sliding: the simulation's front (or a read) mid-way through the closing says nothing new.
		}
		// (A lane whose stacks changed is made again with its new piles, its phase as a new lane's.)
		if (ln != nullptr && ln->stack == st) {
			if (creep && creep_flow) {
				// (creep_flow) A moving lane the simulation has had none on for NONE_TICKS (at once, creeping)
				// stands where it is drawn (belt_lattice.gd).
				if (has) {
					ln->none_t = -1;
				} else if (ln->v > 0) {
					if (ln->none_t < 0) {
						ln->none_t = tick;
					}
					if (tick - ln->none_t >= NONE_TICKS || (!has && ln->creeping)) {
						i64 td1 = _t_draw(tick);
						_creep_stop(ln, _phase_at(ln, td1), td1);
						_write_lane(key, ln, m, lk->second, st);
						continue;
					}
				}
			}
			if (!has) {
				// (The simulation has none there: the lattice goes on as it was; a standing one is set to a
				// new observation of the lane.)
				if (!(obs >= 0 && ln->v == 0 && heard.count(key) && posmod(obs, GAP) != ln->r0)) {
					continue;
				}
			} else {
				i64 pred = posmod(ln->r0 - ln->v * (tick - ln->t0), GAP);
				if (creep && q * 3 + 2 < (int)lane_v.size()) {
					if (creep_flow ? _creep_flow(ln, lane_v[q * 3 + 1], lane_v[q * 3 + 2], m[2], tick, pred, f)
								   : _creep(ln, lane_v[q * 3 + 1], m[2], tick, pred, f)) {
						_write_lane(key, ln, m, lk->second, st);
						continue;
					}
					if (ln->creeping) {
						continue;  // (sliding at its share: the simulation's stops and starts aren't taken)
					}
					if (creep_flow && ln->v > 0 && tick - ln->t0 >= FLOW_GATE_TICKS && ln->flow_q < FLOW_GATE) {
						// (creep_flow) At the simulation's speed this long, its items hardly went on past its exit
						// (belt_lattice.gd).
						i64 td3 = _t_draw(tick);
						_set_motion(ln, _phase_at(ln, td3), 0, td3);
						ln->pend_v = -1;
						ln->pend_n = 0;
						ln->gated = true;
						_write_lane(key, ln, m, lk->second, st);
						continue;
					}
				}
				if (v != ln->v) {
					if (v == ln->pend_v) {
						ln->pend_n += 1;
					} else {
						ln->pend_v = v;
						ln->pend_n = 1;
						ln->pend_t = tick;
					}
					if (ln->pend_n < (unison ? 1 : SPEED_CHECKS)) {
						continue;
					}
					bool released = start && settle && ln->v == 0 && v > 0 && ln->release_t >= 0 && ln->slide_at < 0;
					if (settle && ln->v == 0 && !released && (tick - ln->pend_t) * v <= SETTLE_GAPS * GAP) {
						continue;  // (a line closing a hole: a gap on it stands again, the same picture)
					}
					if (start && start_stops && settle && ln->v > 0 && v == 0 && !ln->creeping) {
						// (start) Stopping: on to the tick its lattice comes to the simulation's standing front's phase.
						i64 over = posmod(ln->v * (tick - ln->t0) - (ln->r0 - f), GAP);
						i64 t_stop = tick - roundi((double)over / (double)ln->v);
						if (t_stop > drawn_tick && t_stop > std::max(ln->t0, ln->go_lo)) {
							ln->pend_n = 0;
							ln->pend_v = -1;
							if (ln->go_lo < 0) {
								ln->go_lo = ln->t0;
							}
							ln->go_hi = t_stop;
							_write_lane(key, ln, m, lk->second, st);
							continue;
						}
					}
					if (ln->gated && ln->flow_q >= FLOW_GATE) {
						ln->gated = false;
					}
					if (ln->v == 0 && ln->gated) {
						continue;  // (creep_flow: stood for want of net flow; moves again with it)
					}
					if (released) {
						// (start) Its run in front extended: on from where it stands, from the tick its items started.
						i64 t_go = tick - roundi((double)posmod(ln->r0 - f, GAP) / (double)v);
						ln->pend_n = 0;
						ln->pend_v = -1;
						ln->release_t = -1;
						_set_motion(ln, ln->r0, v, t_go);
						ln->go_lo = t_go;
						_write_lane(key, ln, m, lk->second, st);
						continue;
					}
					// (Its new speed from where it is drawn now; the map's phase at it, world. Stopping, it
					// keeps where it is drawn: the game's standing phase comes with the lane's next read or
					// check, obs; settle: it stands on the simulation's standing front at once.)
					ln->pend_n = 0;
					ln->pend_v = -1;
					_set_motion(ln, (wl && v > 0) ? posmod(_world_phase(m) - v * tick, GAP) : ((settle && v == 0) ? posmod(f, GAP) : pred),
							v, tick);
					_write_lane(key, ln, m, lk->second, st);
					continue;
				}
				ln->pend_n = 0;
				ln->pend_v = -1;
				if (settle && ln->v == 0) {
					obs = f;  // (the simulation's front stands on the lane: its phase, not a read's mid-way)
				}
				if (ln->v == 0 && obs >= 0) {
					if (posmod(obs, GAP) == ln->r0) {
						continue;  // (standing at the game's phase)
					}
				} else {
					i64 off = std::abs(pred - posmod(f, GAP));
					bool in_step = std::min(off, GAP - off) <= DRIFT;
					if (wl || in_step) {  // (wl: the map's phase, nothing drifts)
						in_step = std::min(off, GAP - off) <= (wl ? SEED_WL : DRIFT);  // (belt_lattice.gd)
						// (turn_id) Moving in step, who its items are off the simulation's: seeded again (belt_lattice.gd).
						if (in_step && ln->v > 0 && tick - ln->t0 >= SEED_AFTER && q * 3 + 2 < (int)nums.size() && has && nums[q * 3 + 2] >= 0
								&& _seed_who(ln, f, nums[q * 3 + 2], tick) != ln->who && !_ring(key)
								&& _seed(ln, f, nums[q * 3 + 2], tick)) {
							_write_lane(key, ln, m, lk->second, st);
						}
						continue;
					}
				}
			}
		}
		bool fresh = ln == nullptr;
		if (fresh) {
			if (settle) {
				// (Moving: drawn only once it has moved for longer than a line closing a hole does.)
				if (has && v > 0) {
					auto ms = moving_since.find(key);
					if (ms == moving_since.end()) {
						moving_since[key] = tick;
						continue;
					}
					if ((tick - ms->second) * v <= SETTLE_GAPS * GAP) {
						continue;
					}
				}
				moving_since.erase(key);
			}
			ln = new Lane();
			ln->item = item;
			ln->kind_key = kk;
			drawn.set(key, ln);
			undrawn.erase(key);
			_mark(key, ln);
			added_keys[key] = true;
		}
		i64 nv = 0;
		i64 nr0 = 0;
		if (wl) {
			nv = has ? v : 0;
			nr0 = posmod(_world_phase(m) - nv * tick, GAP);
		} else if (has) {
			nr0 = posmod(f, GAP);
			nv = v;
		} else {
			nr0 = _world_phase(m);
		}
		if (settle && has && v == 0) {
			obs = f;
		}
		if (nv == 0 && obs >= 0) {
			nr0 = posmod(obs, GAP);  // (standing: where the game last showed the lane's items)
		}
		if (fresh) {
			ln->r0 = nr0;
			ln->v = nv;
			ln->t0 = tick;
			_identify(key, ln, m, tick);
		} else {
			_set_motion(ln, nr0, nv, tick);
		}
		// (turn_id: from the simulation's front item, but on a ring as before, carried from lane to lane.)
		if (q * 3 + 2 < (int)nums.size() && has && nums[q * 3 + 2] >= 0 && !_ring(key)) {
			_seed(ln, f, nums[q * 3 + 2], tick);
		}
		_write_lane(key, ln, m, lk->second, st);
	}
	_open_ends(front_at, tick);
	for (i64 kk : kinds.key_list()) {
		LKind *kd = *kinds.get(kk);
		Vector3i told(kd->base, kd->top, kd->cap);
		if (full || told != kd->told) {
			kd->told = told;
			Array w;
			w.push_back(kk);
			w.push_back(kd->base);
			w.push_back(kd->top);
			w.push_back(kd->cap);
			written.push_back(w);
		}
	}
	Dictionary res;
	res["written"] = written;
	Array unk;
	for (i64 kk : unknown.key_list()) {
		unk.push_back(kk);
	}
	res["unknown"] = unk;
	res["pages"] = records.take_pages();
	if (mask_dirty) {
		mask_dirty = false;
		res["mask"] = mask;
	} else {
		res["mask"] = Variant();
	}
	lanes_n = (i64)drawn.size();
	slots_n = 0;
	for (LKind *kd : kinds.val_list()) {
		slots_n += kd->top - (i64)kd->free.size();
	}
	res["dump_ids"] = to_packed<PackedInt64Array>(dump_ids);
	res["dump_recs"] = to_packed<PackedFloat32Array>(dump_recs);
	res["dump_gone"] = to_packed<PackedInt64Array>(dump_gone);
	// (A lane removed and drawn again in the same update, its kind changed, neither.)
	PackedInt64Array del;
	std::unordered_set<i64> removed_set;
	for (i64 k : removed_keys) {
		if (removed_set.insert(k).second && !drawn.has(k)) {
			del.push_back(k);
		}
	}
	PackedInt64Array add;
	for (const auto &kv : added_keys) {
		if (!removed_set.count(kv.first) && drawn.has(kv.first)) {
			add.push_back(kv.first);
		}
	}
	res["removed"] = del;
	res["added"] = add;
	return res;
}

// (mask_open) Each drawn lane's ends left unmarked for the lanes beside it now (belt_lattice.gd _open_ends).
void BeltLatticeNative::_open_ends(const std::unordered_map<i64, i64> &front_at, i64 tick) {
	for (i64 key : drawn.key_list()) {
		Lane *ln = *drawn.get(key);
		i64 o = 0;
		auto fa = front_at.find(key);
		if (mask_open && mask_own && ln->v > 0 && fa != front_at.end()) {
			// (Its slots less the simulation's items, -32..31: below 0 its slots are ahead, nearer the exit.)
			i64 off = posmod(_phase_at(ln, tick) - fa->second + GAP / 2, GAP) - GAP / 2;
			if (off < -OPEN_TOL) {
				Lane **pd = ln->next != 0 && ln->next != key ? drawn.get(ln->next) : nullptr;
				if ((pd == nullptr || (*pd)->v != ln->v) && (!edge_shut || sim == nullptr || sim->leads_on(key))) {
					o = OPEN_EXIT;
				}
			} else if (off > OPEN_TOL) {
				auto ff = feeds.find(key);
				i64 up_key = ff != feeds.end() ? ff->second : 0;
				Lane **pu = up_key != 0 && up_key != key ? drawn.get(up_key) : nullptr;
				if (pu == nullptr || (*pu)->v != ln->v) {
					o = OPEN_ENTRY;
				}
			}
		}
		// (handover) The phases' difference the open end's slot hides by.
		i64 od = 0;
		if (handover && o != 0) {
			od = posmod(_phase_at(ln, tick) - fa->second + GAP / 2, GAP) - GAP / 2;
			od = o == OPEN_EXIT ? -od : od;
		}
		auto lf = lanes.find(key);
		if ((o == ln->open && od == ln->open_d) || lf == lanes.end()) {
			continue;
		}
		ln->open_d = od;
		if (o != ln->open) {
			_unmark(ln);
			ln->open = o;
			_mark(key, ln);
		}
		auto lk = known.find(ln->kind_key);
		if (lk != known.end()) {
			_write_lane(key, ln, lf->second.m, lk->second, ln->stack);
		}
	}
}

// (handover) A moving lane's slot k's texel 3 y: where in its period it hides at its lane's open end
// (belt_lattice.gd _hand_code).
double BeltLatticeNative::_hand_code(const Lane *ln, i64 k, i64 length) {
	if (ln->open_d <= 0 || ln->v <= 0) {
		return 0.0;
	}
	if (ln->open & OPEN_EXIT) {
		return k == 0 ? -(1.0 + std::min(1.0, (double)(ln->open_d + HAND_SLACK) / GAP)) : 0.0;
	}
	if (ln->open & OPEN_ENTRY) {
		double h = (double)(GAP * (k + 2) - length - ln->open_d - HAND_SLACK) / GAP;
		return h > 0.0 ? -(3.0 + std::min(h, 1.0)) : 0.0;
	}
	return 0.0;
}

// How high a lane's piles are drawn: its last read's most common stack (1 with --belt-draw-lattice-pile=off).
int BeltLatticeNative::_stack_of(i64 key) {
	if (!piles) {
		return 1;
	}
	Info *e = info.get(key);
	return e == nullptr ? 1 : (int)std::clamp<i64>(e->stack, 1, MAX_STACK);
}

// The item a lane is drawn as a lattice of, or -1.
i64 BeltLatticeNative::_wanted(i64 key) {
	if (!on) {
		return -1;
	}
	Info *e = info.get(key);
	if (e == nullptr || !e->full || e->item < 0) {
		return -1;
	}
	auto lf = lanes.find(key);
	if (lf == lanes.end() || !_drawn_kind(lf->second.m[0]) || lf->second.m[1] <= 0 || lf->second.m[1] > MAX_LENGTH) {
		return -1;
	}
	if (!planned_all) {
		Vector2 mid;
		auto mf = mids.find(key);
		if (mf != mids.end()) {
			mid = mf->second;
		} else {
			Vector4 p = _point(key, (double)lf->second.m[1] * 0.5);
			mid = Vector2(p.x, p.z);
			mids[key] = mid;
		}
		if (!planned.has_point(mid)) {
			return -1;
		}
	}
	return e->item;
}

bool BeltLatticeNative::_drawn_kind(int kind) {
	return kind == STRAIGHT || kind == CURVE || kind == UG_VISIBLE || kind == SPLIT_IN || kind == SPLIT_OUT;
}

// A lane the simulation has no item on: a lattice fixed to the map along its exit's direction.
i64 BeltLatticeNative::_world_phase(const int32_t *m) {
	return posmod(_world_tau(m), GAP);
}

// Where a lane's exit is along the way its items leave (belt_lattice.gd _world_tau).
i64 BeltLatticeNative::_world_tau(const int32_t *m) {
	i64 dx = (i64)m[3] - m[5];
	i64 dy = (i64)m[4] - m[6];
	if (std::abs(dx) >= std::abs(dy)) {
		return dx > 0 ? (i64)m[3] : -(i64)m[3];
	}
	return dy > 0 ? (i64)m[4] : -(i64)m[4];
}

// A run's seed from the map (belt_lattice.gd _world_run).
i64 BeltLatticeNative::_world_run(const int32_t *m) {
	i64 dx = (i64)m[3] - m[5];
	i64 dy = (i64)m[4] - m[6];
	if (std::abs(dx) >= std::abs(dy)) {
		return posmod((i64)m[4] * 4 + (dx > 0 ? 0 : 1), IDS);
	}
	return posmod((i64)m[3] * 4 + (dy > 0 ? 2 : 3), IDS);
}

// A drawn lane's new motion from `tick`, who its items are carried over (belt_lattice.gd _set_motion).
// belt_lattice.gd _creep.
bool BeltLatticeNative::_creep(Lane *ln, i64 lv, i64 step, i64 tick, i64 pred, i64 f) {
	if (ln->flow_t >= 0 && tick > ln->flow_t) {
		i64 dt = tick - ln->flow_t;
		ln->flow_q += ((lv > 0 ? FLOW_ONE : 0) - ln->flow_q) * dt / (dt + CREEP_TAU);
	}
	ln->flow_t = tick;
	if (lv <= 0) {
		ln->run_t = -1;
	} else if (ln->run_t < 0) {
		ln->run_t = tick;
	}
	i64 cv = std::max<i64>(1, (ln->flow_q * std::max<i64>(1, step) + FLOW_ONE / 2) / FLOW_ONE);
	if (ln->creeping) {
		if (ln->run_t >= 0 && (tick - ln->run_t) * lv > CREEP_RUN_GAPS * GAP) {
			ln->creeping = false;
			ln->pend_v = -1;
			ln->pend_n = 0;
			return false;
		}
		if (ln->flow_q < CREEP_OFF) {
			if (lv > 0) {
				return false;  // (its items moving now: it stops once they stand)
			}
			if (posmod(pred - f, GAP) > ln->v) {
				return false;  // (on to the standing front's phase)
			}
			ln->creeping = false;
			ln->pend_v = -1;
			ln->pend_n = 0;
			_set_motion(ln, posmod(f, GAP), 0, tick);
			return true;
		}
		if (std::abs(cv - ln->v) * 4 > ln->v) {
			_set_motion(ln, pred, cv, tick);
			return true;
		}
		return false;
	}
	if (ln->v == 0 && ln->flow_q >= CREEP_ON && !(ln->run_t >= 0 && (tick - ln->run_t) * lv > SETTLE_GAPS * GAP)) {
		ln->creeping = true;
		_set_motion(ln, pred, cv, tick);
		return true;
	}
	return false;
}

// belt_lattice.gd _front_flow.
i64 BeltLatticeNative::_front_flow(Lane *ln, i64 u, i64 tick) {
	i64 dd = 0;
	int n = (int)ln->fu.size();
	if (n == 0 || ln->fu[n - 1] != (int32_t)u) {
		int back = -1;
		for (int j = n - 2; j >= 0; j--) {
			if (ln->fu[j] == (int32_t)u) {
				back = j;
				break;
			}
		}
		if (back >= 0) {
			dd = -GAP * (n - 1 - back);  // (a front it had: a read put the items back)
			ln->fu.resize(back + 1);
		} else {
			if (n > 0) {
				dd = GAP;
			}
			ln->fu.push_back((int32_t)u);
			if ((int)ln->fu.size() > FLOW_HIST) {
				ln->fu.erase(ln->fu.begin());
			}
		}
	}
	if (ln->flow_t >= 0 && tick > ln->flow_t) {
		i64 dt = tick - ln->flow_t;
		ln->flow_q = std::max<i64>(0, ln->flow_q + _fdiv(dd * FLOW_ONE - ln->flow_q * dt, dt + CREEP_TAU));
	} else if (ln->flow_t < 0 || tick == ln->flow_t) {
		ln->flow_q = std::max<i64>(0, ln->flow_q + _fdiv(dd * FLOW_ONE, CREEP_TAU));
	}
	ln->flow_t = tick;
	return dd;
}

// belt_lattice.gd _creep_step.
void BeltLatticeNative::_creep_step(Lane *ln, i64 u, i64 step, i64 f, i64 fv, bool has, i64 tick) {
	if (!has) {
		return;
	}
	i64 prev_t = ln->flow_t;
	i64 dd = _front_flow(ln, u, tick);
	if (dd < 0) {
		// (A read put the simulation's items back: slides not written yet dropped; belt_lattice.gd.)
		i64 nb = _fdiv(-dd, GAP);
		while (nb > 0 && ln->slide_more > 0) {
			ln->slide_more -= 1;
			ln->step_bal = std::max<i64>(ln->step_bal - 1, 0);
			nb -= 1;
		}
		if (nb > 0 && ln->slide_at >= 0 && ln->slide_v == 0) {
			_slide_clear(ln);
			ln->step_bal = std::max<i64>(ln->step_bal - 1, 0);
			nb -= 1;
		}
		return;
	}
	if (dd == 0 || ln->v != 0 || ln->creeping || step <= 0) {
		return;
	}
	if (ln->flow_q * 2 >= step * FLOW_ONE) {
		return;  // (at half the belt's speed or more: the usual rules)
	}
	if (ln->bal_t >= 0 && std::llabs(tick - ln->bal_t) > STEP_BAL_TICKS) {
		ln->step_bal = 0;
	}
	ln->bal_t = tick;
	// Gaps the line went on since the last update (belt_lattice.gd).
	i64 k = 1;
	i64 moved = beltn::posmod(ln->r0 - f, GAP);
	if (fv > 0 && f > ln->r0) {
		k = std::clamp<i64>(_fdiv(f - ln->r0 - 1, GAP) + 1, 1, CLOSE_MORE + 1);
		moved = ln->r0 + k * GAP - f;
	}
	while (k > 0 && ln->step_bal < 0) {
		ln->step_bal += 1;  // (close slid it for this take)
		k -= 1;
		moved = std::max<i64>(0, moved - GAP);
	}
	if (k <= 0) {
		return;
	}
	ln->step_bal = std::min<i64>(ln->step_bal + k, CLOSE_MORE);
	i64 t_s = 0;
	if (fv > 0) {
		t_s = tick - _fdiv(2 * moved + fv, 2 * fv);
	} else {
		t_s = tick - _fdiv(GAP + step - 1, step);
		if (prev_t >= 0 && prev_t < t_s) {
			t_s = _fdiv(prev_t + t_s, 2);
		}
	}
	if (ln->slide_at < 0) {
		ln->slide_at = t_s;
		ln->slide_v = 0;
		ln->slide_more = std::min<i64>(k - 1, CLOSE_MORE);
	} else {
		ln->slide_more = std::min<i64>(ln->slide_more + k, CLOSE_MORE);
	}
}

// belt_lattice.gd _creep_flow.
bool BeltLatticeNative::_creep_flow(Lane *ln, i64 lv, i64 u, i64 step, i64 tick, i64 pred, i64 f) {
	_front_flow(ln, u, tick);
	if (lv <= 0) {
		ln->run_t = -1;
	} else if (ln->run_t < 0) {
		ln->run_t = tick;
	}
	i64 cv = std::min<i64>(std::max<i64>(1, step), std::max<i64>(1, _fdiv(ln->flow_q + FLOW_ONE / 2, FLOW_ONE)));
	// (Its new motion from the drawn clock's tick, where it is drawn then.)
	i64 td = _t_draw(tick);
	i64 pd = _phase_at(ln, td);
	if (ln->creeping) {
		if (ln->run_t >= 0 && (tick - ln->run_t) * lv > CREEP_RUN_GAPS * GAP) {
			ln->creeping = false;
			ln->pend_v = -1;
			ln->pend_n = 0;
			return false;
		}
		if (ln->flow_q < CREEP_FLOW_OFF) {
			if (lv > 0) {
				return false;  // (its items moving now: it stops once they stand)
			}
			if (posmod(pd - f, GAP) > ln->v) {
				return false;  // (on to the standing front's phase)
			}
			ln->creeping = false;
			ln->pend_v = -1;
			ln->pend_n = 0;
			_set_motion(ln, posmod(f, GAP), 0, td);
			return true;
		}
		if (std::abs(cv - ln->v) * 4 > ln->v) {
			_set_motion(ln, pd, cv, td);
			return true;
		}
		return false;
	}
	if (ln->v == 0 && ln->flow_q >= CREEP_FLOW_ON && !(ln->run_t >= 0 && (tick - ln->run_t) * lv > SETTLE_GAPS * GAP)) {
		ln->creeping = true;
		_set_motion(ln, pd, cv, td);
		return true;
	}
	return false;
}

// belt_lattice.gd _t_draw.
i64 BeltLatticeNative::_t_draw(i64 tick) const {
	return creep_flow && drawn_tick >= 0 && drawn_tick <= tick ? drawn_tick : tick;
}

// belt_lattice.gd _creep_stop.
void BeltLatticeNative::_creep_stop(Lane *ln, i64 r0, i64 tick) {
	ln->creeping = false;
	ln->pend_v = -1;
	ln->pend_n = 0;
	ln->flow_q = 0;
	ln->flow_t = -1;
	ln->run_t = -1;
	ln->fu.clear();
	_set_motion(ln, r0, 0, tick);
}

void BeltLatticeNative::_set_motion(Lane *ln, i64 r0, i64 v, i64 tick) {
	// (close: a slide's way so far counts as moved; the new motion replaces what is left of it.)
	ln->who = posmod(ln->who + _fdiv(r0 + ln->v * (_held_t(ln, tick) - ln->t0) + _slide_moved(ln, tick) - ln->r0 + _lag(ln->v - v, tick)
			+ GAP / 2, GAP), IDS);
	_slide_clear(ln);
	ln->go_lo = -1;
	ln->go_hi = -1;
	ln->go_next = -1;
	ln->r0 = r0;
	ln->v = v;
	ln->t0 = tick;
}

// (close) A slide over: standing a gap on, each slot the item that was behind it; the next queued, if any.
void BeltLatticeNative::_slide_done(Lane *ln) {
	ln->who = posmod(ln->who + 1, IDS);
	if (ln->slide_more > 0) {
		ln->slide_more -= 1;
		ln->slide_at += _slide_ticks(ln);
	} else {
		_slide_clear(ln);
	}
}

// (start) Lane `key`'s next lane is new: it and its straight run back (feeds), each released (belt_lattice.gd).
void BeltLatticeNative::_release_behind(i64 key, i64 tick) {
	i64 k = key;
	for (int i = 0; i < 4096; i++) {
		Lane **pl = drawn.get(k);
		if (pl == nullptr) {
			return;
		}
		(*pl)->release_t = tick;
		auto ff = feeds.find(k);
		i64 up = ff == feeds.end() ? 0 : ff->second;
		if (up == 0 || up == key) {
			return;
		}
		Lane **pu = drawn.get(up);
		if (pu == nullptr || (*pu)->next != k) {
			return;
		}
		k = up;
	}
}

// (close) A take on tick `at` from lane `key` (standing, or not drawn): the drawn standing lanes behind it
// (feeds), each a slide of a gap from then, or one more after the slide it has (belt_lattice.gd).
void BeltLatticeNative::_close_behind(i64 key, i64 at) {
	i64 down = key;
	for (int i = 0; i < 4096; i++) {
		auto ff = feeds.find(down);
		i64 up_key = ff == feeds.end() ? 0 : ff->second;
		if (up_key == 0 || up_key == key) {
			return;
		}
		Lane **pu = drawn.get(up_key);
		Lane *up = pu == nullptr ? nullptr : *pu;
		if (up == nullptr || up->next != down || up->v != 0 || up->creeping) {
			return;
		}
		if (creep_step) {
			// (creep_step) Its front's change already slid it for this take: not again.
			if (up->bal_t >= 0 && std::llabs(at - up->bal_t) > STEP_BAL_TICKS) {
				up->step_bal = 0;
			}
			up->bal_t = at;
			if (up->step_bal > 0) {
				up->step_bal -= 1;
				down = up_key;
				continue;
			}
			up->step_bal = std::max<i64>(up->step_bal - 1, -CLOSE_MORE);
		}
		if (up->slide_at >= 0 && up->slide_v > 0 && up->slide_more == 0 && at >= up->slide_at + _slide_ticks(up)) {
			_slide_done(up);  // (its slide over by the take: standing a gap on)
		}
		if (up->slide_at < 0) {
			up->slide_at = at;
			up->slide_v = 0;
			up->slide_more = 0;
		} else {
			up->slide_more = std::min<i64>(up->slide_more + 1, CLOSE_MORE);
		}
		dirty.set(up_key, true);
		down = up_key;
	}
}

// Who a new lane's items are: its next drawn lane's, the drawn lane feeding it, else the map's
// (belt_lattice.gd _identify).
void BeltLatticeNative::_identify(i64 key, Lane *ln, const int32_t *m, i64 tick) {
	ln->next = sim != nullptr ? sim->next_of(key) : 0;
	Lane *down = nullptr;
	const int32_t *dm = nullptr;
	if (ln->next != 0 && ln->next != key) {
		Lane **pd = drawn.get(ln->next);
		auto lf = lanes.find(ln->next);
		if (pd != nullptr && lf != lanes.end()) {
			down = *pd;
			dm = lf->second.m;
		}
	}
	Lane *up = nullptr;
	auto ff = feeds.find(key);
	if (ff != feeds.end() && ff->second != 0 && ff->second != key) {
		Lane **pu = drawn.get(ff->second);
		up = pu == nullptr ? nullptr : *pu;
	}
	if (down != nullptr) {
		ln->who = posmod(down->who + _fdiv((i64)dm[1] + ln->r0 + down->v * (tick - down->t0) + _slide_moved(down, tick) - down->r0
				+ _lag(down->v - ln->v, tick) + GAP / 2, GAP), IDS);
		ln->run = down->run;
	} else if (up != nullptr) {
		ln->who = posmod(up->who + _fdiv(up->v * (tick - up->t0) + _slide_moved(up, tick) - up->r0 - (i64)m[1] + ln->r0
				+ _lag(up->v - ln->v, tick) + GAP / 2, GAP), IDS);
		ln->run = up->run;
	} else {
		ln->who = posmod(_fdiv(ln->r0 - _world_tau(m) + ln->v * tick + GAP / 2, GAP), IDS);
		ln->run = _world_run(m);
	}
	if (ln->next != 0) {
		feeds[ln->next] = key;
	}
}

// (turn_id) belt_lattice.gd _seed: who a lane's items are from the simulation's front item on it.
i64 BeltLatticeNative::_seed_who(const Lane *ln, i64 at, i64 num, i64 tick) {
	return posmod(num - _fdiv(at + ln->v * (_held_t(ln, tick) - ln->t0) + _slide_moved(ln, tick) - ln->r0 + GAP / 2, GAP), IDS);
}

// (turn_id) belt_lattice.gd _ring: whether lane `key` is on a ring of lanes (the simulation's links).
bool BeltLatticeNative::_ring(i64 key) {
	if (sim == nullptr) {
		return false;
	}
	i64 k = sim->next_of(key);
	for (int i = 0; i < 256; i++) {
		if (k == key) {
			return true;
		}
		if (k == 0) {
			return false;
		}
		k = sim->next_of(k);
	}
	return false;
}

bool BeltLatticeNative::_seed(Lane *ln, i64 at, i64 num, i64 tick) {
	i64 w = _seed_who(ln, at, num, tick);
	if (w == ln->who && ln->run == TURN_RUN) {
		return false;
	}
	ln->who = w;
	ln->run = TURN_RUN;
	return true;
}

void BeltLatticeNative::_remove(i64 key) {
	Lane *ln = *drawn.get(key);
	drawn.erase(key);
	if (ln->next != 0) {
		auto ff = feeds.find(ln->next);
		if (ff != feeds.end() && ff->second == key) {
			feeds.erase(ff);
		}
	}
	removed_keys.push_back(key);
	LKind **pkd = kinds.get(ln->kind_key);
	LKind *kd = pkd == nullptr ? nullptr : *pkd;
	for (size_t i = 0; i < ln->slots.size(); i++) {
		if (kd != nullptr) {
			records.hide(kd->base + ln->slots[i]);
			kd->free.push_back(ln->slots[i]);
		}
		if ((i64)i % ln->stack == 0) {
			dump_gone.push_back(_uid(key, (i64)i / ln->stack));
		}
	}
	_unmark(ln);
	delete ln;
}

// The lane's slots: one record each, every GAP from its phase; sliding a gap a period, or standing
// (belt_lattice.gd _write_lane). With stacks, each slot is a pile: its record and stack - 1 copies
// pointing at it.
void BeltLatticeNative::_write_lane(i64 key, Lane *ln, const int32_t *m, const Look &look, int stack) {
	i64 length = m[1];
	if (length <= 0 || length > MAX_LENGTH) {
		return;
	}
	bool moving = ln->v > 0;
	if (mask_inner && !mask_own && moving != ln->mark_moving && !ln->cells.empty()) {
		// (mask_inner) Started or stopped moving: its mask cells a moving or a standing lane's (belt_lattice.gd).
		_unmark(ln);
		ln->mark_moving = moving;
		_mark(key, ln);
	}
	i64 n = 0;
	if (moving) {
		n = std::max<i64>(1, (i64)std::ceil((double)length / (double)GAP));
	} else {
		i64 q = ln->r0;
		while (q < length) {
			n += 1;
			q += GAP;
		}
	}
	// (close) Sliding a gap: a moving lane's slots on a clock held to the slide (belt_lattice.gd).
	bool sliding = !moving && close && ln->slide_at >= 0 && ln->slide_v > 0
			&& n == std::max<i64>(1, (i64)std::ceil((double)length / (double)GAP));
	LKind **pkd = kinds.get(ln->kind_key);
	LKind *kd;
	if (pkd == nullptr) {
		kd = new LKind();
		kinds.set(ln->kind_key, kd);
	} else {
		kd = *pkd;
	}
	if (stack != ln->stack) {
		// (Its piles' height changed: every slot placed again.)
		while (!ln->slots.empty()) {
			_drop_slot(key, ln, kd);
		}
		ln->stack = stack;
	}
	int st = ln->stack;
	while ((i64)ln->slots.size() > n * st) {
		_drop_slot(key, ln, kd);
	}
	i64 placed = (i64)ln->slots.size();
	while ((i64)ln->slots.size() < n * st) {
		int s;
		if (!kd->free.empty()) {
			s = kd->free.back();
			kd->free.pop_back();
		} else {
			s = kd->top;
			kd->top += 1;
			if (kd->top > kd->cap || kd->base < 0) {
				int cap = MIN_RUN;
				while (cap < kd->top) {
					cap *= 2;
				}
				int nb = records.alloc(cap);
				if (kd->base >= 0) {
					records.copy(kd->base, nb, kd->cap);
					records.release(kd->base, kd->cap);
				}
				for (int i = kd->cap; i < cap; i++) {
					records.hide(nb + i);
				}
				kd->base = nb;
				kd->cap = cap;
			}
		}
		ln->slots.push_back(s);
	}
	Vector3 lift = look.lift;
	double pile_step = look.pile;
	double period = moving ? (double)GAP / (double)ln->v : (sliding ? (double)GAP / (double)ln->slide_v : 0.0);
	Ends ends = _ends(key, length);
	// (Its clock from where slot k is at 64k + r0 on tick t0: the shader's fract() starts at (64 - r0) / 64.)
	double t_start = (double)ln->t0 - base;
	double t_hold = 0.0;
	double periods = 0.0;  // (close, start) how long the held clock runs from t_hold (texel 1 y), 0: on and on
	// (start) A motion that started at once or stops: its clock held (belt_lattice.gd).
	bool held = moving && start && (ln->go_lo >= 0 || ln->go_hi >= 0);
	if (moving) {
		t_start -= (double)(GAP - ln->r0) / (double)GAP * period;
		if (held) {
			i64 lo = ln->go_lo >= 0 ? ln->go_lo : ln->t0;
			t_start += period / 256.0;
			t_hold = (double)lo - base;
			if (ln->go_hi >= 0) {
				periods = (double)(ln->go_hi - lo) / period;
			}
		}
	} else if (sliding) {
		// (close) From the slide's start, a 256th of a period on; held from then to a period after (texel 1 w, y).
		t_hold = (double)ln->slide_at - base;
		t_start = t_hold - (double)(GAP - ln->r0) / (double)GAP * period + period / 256.0;
		periods = 1.0;
	}
	float *d = records.data.data();
	for (i64 k = 0; k < n; k++) {
		double top = (moving || sliding) ? (double)(GAP * (k + 1)) : (double)(ln->r0 + GAP * k);
		Vector4 p = _along(key, top, length, ends);
		Vector4 to = (moving || sliding) ? _along(key, (double)(GAP * k), length, ends) : p;
		i64 uid = _uid(key, k);
		// Turned as every item is, icon cards too: by who its item is (the shader adds the periods slid,
		// item_cards.gd lattice_turn), or (slot turns) by the slot (turn_for).
		double c = item_turns ? (double)posmod(ln->who + k, IDS) : std::cos(yaw_for(uid));
		double s = item_turns ? (double)ln->run : std::sin(yaw_for(uid));
		int r = kd->base + ln->slots[(size_t)(k * st)];
		size_t o = (size_t)r * FLOATS;
		d[o] = p.x;
		d[o + 1] = p.y;
		d[o + 2] = p.z;
		d[o + 3] = (float)t_start;
		if (period > 0.0) {
			d[o + 4] = (float)((double)to.x - (double)p.x);
			d[o + 5] = (float)periods;  // (a slot slides on the ground: texel 1 y is its held clock's run)
			d[o + 6] = (float)((double)to.z - (double)p.z);
		} else {
			d[o + 4] = 0.0f;
			d[o + 5] = 0.0f;
			d[o + 6] = 0.0f;
		}
		d[o + 7] = (float)((sliding || held) ? t_hold : t_start);
		d[o + 8] = (float)c;
		d[o + 9] = (float)s;
		d[o + 10] = (float)((double)lift.y + LAYER_STEP * (double)posmod(uid, LAYERS));
		d[o + 11] = p.w >= 0.5f ? 0.0f : HIDDEN;
		d[o + 12] = 0.0f;
		d[o + 13] = moving ? (float)_hand_code(ln, k, length) : 0.0f;  // (handover) where it hides at an open end
		d[o + 14] = item_turns ? 2.0f : 1.0f;  // a lattice slot (not masked); 2: texel 2 says who its item is
		d[o + 15] = (float)period;
		records.mark(r / records.per_page);
		// Its pile's copies, when placed: the slot's yaw and PILE_TURN more each, k pile steps up, read
		// from the slot's record by the shader.
		for (int j = 1; j < st; j++) {
			i64 i = k * st + j;
			if (i < placed) {
				continue;
			}
			int rc = kd->base + ln->slots[(size_t)i];
			size_t oc = (size_t)rc * FLOATS;
			for (int q = 0; q < FLOATS; q++) {
				d[oc + q] = 0.0f;
			}
			if (!item_turns) {
				double a = yaw_for(uid) + PILE_TURN * (double)j;
				d[oc + 8] = (float)std::cos(a);
				d[oc + 9] = (float)std::sin(a);
			}
			d[oc + 12] = (float)(r - rc);
			d[oc + 13] = (float)j;
			d[oc + 14] = (float)pile_step;
			records.mark(rc / records.per_page);
		}
		if (dump_on) {
			i64 row[8] = { uid, ln->item, (i64)st, key, ln->r0 + GAP * k, ln->t0, ln->v, ln->open };
			dump_ids.insert(dump_ids.end(), row, row + 8);
			dump_recs.insert(dump_recs.end(), d + o, d + o + FLOATS);
		}
	}
}

// The lane's last record let go (hidden, its slot free); a slot's own record's going is dumped.
void BeltLatticeNative::_drop_slot(i64 key, Lane *ln, LKind *kd) {
	i64 i = (i64)ln->slots.size() - 1;
	int s = ln->slots[(size_t)i];
	records.hide(kd->base + s);
	kd->free.push_back(s);
	if (i % ln->stack == 0) {
		dump_gone.push_back(_uid(key, i / ln->stack));
	}
	ln->slots.resize((size_t)i);
}

// A lane's exit and entry and the way items go there.
BeltLatticeNative::Ends BeltLatticeNative::_ends(i64 key, i64 length) const {
	Ends e;
	Vector4 exit = _point(key, 0.0);
	Vector4 ahead = _point(key, std::min(32.0, (double)length));
	Vector4 entry = _point(key, (double)length);
	Vector4 behind = _point(key, std::max(0.0, (double)length - 32.0));
	e.exit = exit;
	e.entry = entry;
	e.d_exit = Vector2((real_t)((double)exit.x - (double)ahead.x), (real_t)((double)exit.z - (double)ahead.z)).normalized();
	e.d_entry = Vector2((real_t)((double)behind.x - (double)entry.x), (real_t)((double)behind.z - (double)entry.z)).normalized();
	return e;
}

// _point, carried on straight past either end.
Vector4 BeltLatticeNative::_along(i64 key, double pos, i64 length, const Ends &ends) const {
	if (pos < 0.0) {
		const Vector4 &e = ends.exit;
		const Vector2 &dv = ends.d_exit;
		return Vector4((real_t)((double)e.x - (double)dv.x * pos / 256.0), e.y, (real_t)((double)e.z - (double)dv.y * pos / 256.0), e.w);
	}
	if (pos > (double)length) {
		const Vector4 &e = ends.entry;
		const Vector2 &dv = ends.d_entry;
		double past = (pos - (double)length) / 256.0;
		return Vector4((real_t)((double)e.x - (double)dv.x * past), e.y, (real_t)((double)e.z - (double)dv.y * past), e.w);
	}
	return _point(key, pos);
}

// Where line position `pos` of lane `key` is: belt_items.gd's Job._point.
Vector4 BeltLatticeNative::_point(i64 key, double pos) const {
	auto f = lanes.find(key);
	if (f == lanes.end()) {
		return Vector4(0.0f, (float)height, 0.0f, 0.0f);
	}
	const int32_t *m = f->second.m;
	double fr = clampd(pos / (double)std::max(m[1], 1), 0.0, 1.0);
	double x, y;
	auto ar = arcs.end();
	if (m[0] == CURVE) {
		ar = arcs.find(key);
	}
	if (m[0] == CURVE && ar != arcs.end() && ar->second.ok) {
		const double *a = ar->second.a;
		double ang = a[3] + a[4] * fr;
		x = a[0] + std::cos(ang) * a[2];
		y = a[1] + std::sin(ang) * a[2];
	} else {
		x = lerpd((double)m[3], (double)m[7], fr);
		y = lerpd((double)m[4], (double)m[8], fr);
	}
	return Vector4((float)(x / 256.0), (float)height, (float)(y / 256.0), m[0] == UG_HIDDEN ? 0.0f : 1.0f);
}

// The mask's cells along a lane's centre line (sampled every 1/32 tile).
void BeltLatticeNative::_mark(i64 key, Lane *ln) {
	if (mask.is_null()) {
		mask = Image::create(MASK, MASK, false, Image::FORMAT_R8);
		mask_n.assign((size_t)(MASK * MASK), 0);
	}
	auto lf = lanes.find(key);
	if (lf == lanes.end()) {
		return;
	}
	const int32_t *m = lf->second.m;
	i64 length = std::clamp<i64>(m[1], 0, MAX_LENGTH);
	std::unordered_set<i64> seen;
	i64 steps = std::max<i64>(1, length / 8);
	bool inner = mask_own || (mask_inner && !ln->mark_moving);
	// (mask_open) Its open ends' cells left out; a lane too short for both keeps its middle's.
	double lo = (ln->open & OPEN_EXIT) ? (double)GAP + 4.0 : 4.0;
	double hi = (double)length - ((ln->open & OPEN_ENTRY) ? (double)GAP + 4.0 : 4.0);
	if (ln->open != 0 && lo > hi) {
		lo = (double)length * 0.5;
		hi = lo;
	}
	for (i64 j = 0; j <= steps; j++) {
		// (mask_inner, standing: its entry end's point a 64th of a tile inside; mask_own: its exit's too, belt_lattice.gd)
		double at = (double)length * (double)j / (double)steps;
		if (inner) {
			at = std::min(at, (double)length - 4.0);
		}
		if (mask_own) {
			at = std::clamp(at, lo, std::max(hi, lo));
		}
		Vector4 p = _point(key, at);
		i64 cx = posmod((i64)std::floor((double)p.x * (double)CELLS), MASK);
		i64 cz = posmod((i64)std::floor((double)p.z * (double)CELLS), MASK);
		i64 c = cz * MASK + cx;
		if (seen.count(c)) {
			continue;
		}
		seen.insert(c);
		ln->cells.push_back((int)c);
		if (mask_n[(size_t)c] < 255) {
			mask_n[(size_t)c] += 1;
		}
		if (mask_n[(size_t)c] == 1) {
			mask->set_pixel((int32_t)cx, (int32_t)cz, Color(1.0f, 0.0f, 0.0f));
			mask_dirty = true;
		}
	}
}

void BeltLatticeNative::_unmark(Lane *ln) {
	for (int c : ln->cells) {
		if (mask_n[(size_t)c] > 0) {
			mask_n[(size_t)c] -= 1;
			if (mask_n[(size_t)c] == 0) {
				mask->set_pixel(c % MASK, c / MASK, Color(0.0f, 0.0f, 0.0f));
				mask_dirty = true;
			}
		}
	}
	ln->cells.clear();
}

// Every lane given up (the lattice switched off, a reset): records hidden, the mask cleared; the slots'
// uids gone.
PackedInt64Array BeltLatticeNative::clear() {
	dump_gone.clear();
	for (i64 key : drawn.key_list()) {
		_remove(key);
	}
	feeds.clear();
	return to_packed<PackedInt64Array>(dump_gone);
}

// belt_items.gd drawn_lattice(): what the shaders draw of a kind's lattice at the drawn clock `t` (from
// `base`): per record [where (with its lift), cosine of its turn], or null where nothing is drawn (tests).
// (--inserter-handoff) belt_lattice.gd hole: the hole a hand's take leaves in a drawn lane's lattice.
Dictionary BeltLatticeNative::hole(i64 key, i64 at, i64 pos, bool dump) {
	Dictionary res;
	PackedInt64Array ids;
	PackedFloat32Array recs;
	Lane **pln = drawn.get(key);
	if (close && settle && (pln == nullptr || (*pln)->v <= 0)) {
		// (close) The standing line behind closes the hole up; the take's lane, short of full now, is drawn from
		// the simulation until a read finds it full again (belt_lattice.gd).
		_close_behind(key, at);
		if (pln != nullptr) {
			Info *e = info.get(key);
			if (e != nullptr) {
				e->full = false;
			}
			dirty.set(key, true);
		}
		pln = drawn.get(key);
	}
	if (pln != nullptr && base >= 0.0) {
		Lane *ln = *pln;
		LKind **pkd = kinds.get(ln->kind_key);
		LKind *kd = pkd != nullptr ? *pkd : nullptr;
		i64 n = ln->stack > 0 ? (i64)ln->slots.size() / ln->stack : 0;
		if (kd != nullptr && kd->base >= 0 && n > 0) {
			auto slot = [&](i64 k, double h) {
				int r = kd->base + ln->slots[(size_t)(k * ln->stack)];
				size_t o = (size_t)r * FLOATS;
				records.data[o + 12] = (float)h;
				records.mark(r / records.per_page);
				if (dump) {
					i64 row[8] = { _uid(key, k), ln->item, ln->stack, key, ln->r0 + GAP * k, ln->t0, ln->v, ln->open };
					for (int q = 0; q < 8; q++) {
						ids.append(row[q]);
					}
					for (int q = 0; q < FLOATS; q++) {
						recs.append(records.data[o + q]);
					}
				}
			};
			double sp = 0.0;  // (close) the period of the slide it is in at the take, 0: none
			if (close && ln->v <= 0 && ln->slide_at >= 0 && ln->slide_v > 0 && at >= ln->slide_at
					&& (double)at < (double)ln->slide_at + (double)GAP / (double)ln->slide_v) {
				sp = (double)GAP / (double)ln->slide_v;
			}
			if (ln->v <= 0 && sp <= 0.0) {
				i64 k = (i64)std::llround((double)(pos - ln->r0) / (double)GAP);
				if (k >= 0 && k < n) {
					slot(k, (double)at - base);
					ln->hole_at = std::max(ln->hole_at, at);
					ln->hole_v = 0;
				}
			} else if (ln->v <= 0) {
				// (close) Taken while it slides: slot k until the slots wrap, then the one ahead (belt_lattice.gd).
				double ts = (double)ln->slide_at - (double)(GAP - ln->r0) / (double)GAP * sp + sp / 256.0;
				double q = ((double)at - ts) / sp;
				double idx = std::floor(q);
				i64 k = (i64)std::llround(((double)pos - (double)GAP * (1.0 - (q - idx))) / (double)GAP);
				for (i64 j = std::min(k, n - 1); j > std::max<i64>(-1, k - 2 + (i64)idx); j--) {
					double h = j == k ? (double)at : ts + (idx + (double)(k - j)) * sp + 0.01;
					slot(j, h - base);
				}
				ln->hole_at = std::max(ln->hole_at, at);
				ln->hole_v = 0;
			} else {
				double period = (double)GAP / (double)ln->v;
				double ts = (double)ln->t0 - (double)(GAP - ln->r0) / (double)GAP * period;
				double q = ((double)at - ts) / period;
				double idx = std::floor(q);
				i64 k = (i64)std::llround(((double)pos - (double)GAP * (1.0 - (q - idx))) / (double)GAP);
				for (i64 j = std::min(k, n - 1); j >= 0; j--) {
					double h = j == k ? (double)at : ts + (idx + (double)(k - j)) * period + 0.01;
					slot(j, h - base);
				}
			}
		}
	}
	res["dump_ids"] = ids;
	res["dump_recs"] = recs;
	return res;
}

Array BeltLatticeNative::drawn_lattice(i64 kind_key, double t) {
	Array out;
	LKind **pkd = kinds.get(kind_key);
	if (pkd == nullptr || (*pkd)->base < 0) {
		return out;
	}
	LKind *kd = *pkd;
	const float *d = records.data.data();
	for (int slot = 0; slot < kd->top; slot++) {
		size_t o = (size_t)(kd->base + slot) * FLOATS;
		double k = d[o + 13];
		double lift_k = 0.0;
		double own_c = 0.0;
		if (k > 0.5) {
			lift_k = (double)d[o + 14] * k;
			own_c = d[o + 8];
			o += (size_t)(roundi(d[o + 12]) * FLOATS);
		}
		if (d[o + 11] < -0.5f) {
			out.push_back(Variant());
			continue;
		}
		double g = d[o + 7] > d[o + 3] ? clampd((t - d[o + 3]) / ((double)d[o + 7] - d[o + 3]), 0.0, 1.0) : 1.0;
		i64 slid = 0;
		if (d[o + 13] < 0.5f && d[o + 14] > 0.5f && d[o + 15] > 0.0f) {
			// (A held clock, belt_lattice.gd close and start: from texel 1 w, texel 1 y periods on, 0 on and on.)
			double hi = d[o + 5] > 0.0f ? (double)d[o + 7] + (double)d[o + 5] * (double)d[o + 15] : INFINITY;
			double tq = d[o + 7] > d[o + 3] ? clampd(t, (double)d[o + 7], hi) : t;
			double q = (tq - d[o + 3]) / d[o + 15];
			g = q - std::floor(q);
			slid = (i64)std::floor(q);
			// (handover) Hidden where its item is the simulation's to draw (texel 3 y: _hand_code).
			double hy = -(double)d[o + 13];
			if (hy > 0.5 && (hy < 2.5 ? g >= hy - 1.0 : g < hy - 3.0)) {
				out.push_back(Variant());
				continue;
			}
		}
		bool on_ground = d[o + 13] < 0.5f && d[o + 14] > 0.5f;  // (a lattice slot slides on the ground: texel 1 y its held clock's run)
		Vector3 at = Vector3(d[o], d[o + 1], d[o + 2]) + Vector3(d[o + 4], on_ground ? 0.0f : d[o + 5], d[o + 6]) * (real_t)g;
		double c = k > 0.5 ? own_c : (double)d[o + 8];
		i64 who = -1;
		i64 run = 0;
		if (d[o + 13] < 0.5f && d[o + 14] > 1.5f) {
			// (Who the slot's item is now: belt_path.gdshaderinc's belt_lattice_turn.)
			who = roundi(d[o + 8]) + slid;
			run = roundi(d[o + 9]);
			c = std::cos(lattice_turn(who, run) + (k > 0.5 ? PILE_TURN * (double)roundi(k) : 0.0));
		}
		Array e;
		e.push_back(at + Vector3(0.0f, (real_t)((double)d[o + 10] + lift_k), 0.0f));
		e.push_back(c);
		e.push_back(who);
		e.push_back(run);
		out.push_back(e);
	}
	return out;
}

// The speed a drawn lane's lattice slides at (ui_test's unison check reads belt_lattice.gd's drawn[key].v).
int64_t BeltLatticeNative::drawn_speed(i64 key) {
	Lane **pln = drawn.get(key);
	return pln == nullptr ? -1 : (*pln)->v;
}

Array BeltLatticeNative::kind_keys() {
	Array out;
	for (i64 kk : kinds.key_list()) {
		out.push_back(kk);
	}
	return out;
}

void BeltLatticeNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_sim", "sim"), &BeltLatticeNative::set_sim);
	ClassDB::bind_method(D_METHOD("set_small_pages", "on"), &BeltLatticeNative::set_small_pages);
	ClassDB::bind_method(D_METHOD("set_settle", "on"), &BeltLatticeNative::set_settle);
	ClassDB::bind_method(D_METHOD("set_creep", "on"), &BeltLatticeNative::set_creep);
	ClassDB::bind_method(D_METHOD("set_creep_flow", "on"), &BeltLatticeNative::set_creep_flow);
	ClassDB::bind_method(D_METHOD("set_creep_step", "on"), &BeltLatticeNative::set_creep_step);
	ClassDB::bind_method(D_METHOD("set_close", "on"), &BeltLatticeNative::set_close);
	ClassDB::bind_method(D_METHOD("set_mask_inner", "on"), &BeltLatticeNative::set_mask_inner);
	ClassDB::bind_method(D_METHOD("set_mask_own", "on"), &BeltLatticeNative::set_mask_own);
	ClassDB::bind_method(D_METHOD("set_mask_open", "on"), &BeltLatticeNative::set_mask_open);
	ClassDB::bind_method(D_METHOD("set_handover", "on"), &BeltLatticeNative::set_handover);
	ClassDB::bind_method(D_METHOD("set_sim_full", "on"), &BeltLatticeNative::set_sim_full);
	ClassDB::bind_method(D_METHOD("set_tail", "on"), &BeltLatticeNative::set_tail);
	ClassDB::bind_method(D_METHOD("set_start", "on"), &BeltLatticeNative::set_start);
	ClassDB::bind_method(D_METHOD("set_start_stops", "on"), &BeltLatticeNative::set_start_stops);
	ClassDB::bind_method(D_METHOD("feed_gone", "key", "tick"), &BeltLatticeNative::feed_gone);
	ClassDB::bind_method(D_METHOD("set_drawn_tick", "t"), &BeltLatticeNative::set_drawn_tick);
	ClassDB::bind_method(D_METHOD("set_item_turns", "on"), &BeltLatticeNative::set_item_turns);
	ClassDB::bind_method(D_METHOD("set_turn_id", "on"), &BeltLatticeNative::set_turn_id);
	ClassDB::bind_method(D_METHOD("set_edge_shut", "on"), &BeltLatticeNative::set_edge_shut);
	ClassDB::bind_method(D_METHOD("set_shown", "t"), &BeltLatticeNative::set_shown);
	ClassDB::bind_method(D_METHOD("set_lane", "key", "meta", "arc"), &BeltLatticeNative::set_lane);
	ClassDB::bind_method(D_METHOD("note_read", "key", "length", "items"), &BeltLatticeNative::note_read);
	ClassDB::bind_method(D_METHOD("note_check", "key", "length", "count", "front", "back"), &BeltLatticeNative::note_check);
	ClassDB::bind_method(D_METHOD("drop", "key"), &BeltLatticeNative::drop);
	ClassDB::bind_method(D_METHOD("update", "tick", "view", "view_all", "known", "model_cap", "full", "dump", "base", "height", "on",
							  "world", "piles", "unison", "world_all", "standing_obs"),
			&BeltLatticeNative::update);
	ClassDB::bind_method(D_METHOD("clear"), &BeltLatticeNative::clear);
	ClassDB::bind_method(D_METHOD("drawn_lattice", "kind_key", "t"), &BeltLatticeNative::drawn_lattice);
	ClassDB::bind_method(D_METHOD("kind_keys"), &BeltLatticeNative::kind_keys);
	ClassDB::bind_method(D_METHOD("drawn_speed", "key"), &BeltLatticeNative::drawn_speed);
	ClassDB::bind_method(D_METHOD("hole", "key", "at", "pos", "dump"), &BeltLatticeNative::hole);
	ClassDB::bind_method(D_METHOD("has_drawn"), &BeltLatticeNative::has_drawn);
	ClassDB::bind_method(D_METHOD("get_lanes_n"), &BeltLatticeNative::get_lanes_n);
	ClassDB::bind_method(D_METHOD("set_lanes_n", "v"), &BeltLatticeNative::set_lanes_n);
	ClassDB::bind_method(D_METHOD("get_slots_n"), &BeltLatticeNative::get_slots_n);
	ClassDB::bind_method(D_METHOD("set_slots_n", "v"), &BeltLatticeNative::set_slots_n);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "lanes_n"), "set_lanes_n", "get_lanes_n");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "slots_n"), "set_slots_n", "get_slots_n");
}
