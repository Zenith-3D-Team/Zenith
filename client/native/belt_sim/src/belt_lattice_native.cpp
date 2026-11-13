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
	bool full = n >= std::max<i64>(1, length / GAP);
	int counts[MAX_STACK + 1] = { 0, 0, 0, 0, 0 };
	for (i64 j = 0; j < n; j++) {
		counts[std::clamp<i64>(it[j * 4 + 3], 1, MAX_STACK)] += 1;
		if (j == 0) {
			continue;
		}
		if (it[j * 4 + 1] != item) {
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
	info.set(key, e);
}

void BeltLatticeNative::note_check(i64 key, i64 length, i64 count, i64 front, i64 back) {
	Info e;
	Info *have = info.get(key);
	if (have != nullptr) {
		e = *have;
	}
	e.full = count >= std::max<i64>(1, length / GAP) && count <= length / GAP + 2 && back - front <= (GAP + 2) * (count - 1);
	info.set(key, e);
	dirty.set(key, true);
}

void BeltLatticeNative::drop(i64 key) {
	info.erase(key);
	mids.erase(key);
	dirty.set(key, true);
	lanes.erase(key);
	arcs.erase(key);
}

// ---------------------------------------------------------------- the update

Dictionary BeltLatticeNative::update(i64 tick, const Rect2 &view, bool view_all, const Dictionary &known_looks, int model_cap,
		bool full, bool dump, double records_base, double items_height, bool lattice_on, bool world_phase, bool pile_slots, bool unison_on) {
	on = lattice_on;
	unison = unison_on;
	world = world_phase;
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
		bool wl = world && (m[0] == STRAIGHT || m[0] == UG_VISIBLE);
		int st = (ln == nullptr || replan || heard.count(key)) ? _stack_of(key) : ln->stack;
		// (A lane whose stacks changed is made again with its new piles, its phase as a new lane's.)
		if (ln != nullptr && ln->stack == st) {
			if (!has) {
				continue;  // (the simulation has none there: the lattice goes on as it was)
			}
			i64 pred = posmod(ln->r0 - ln->v * (tick - ln->t0), GAP);
			if (v != ln->v) {
				if (v == ln->pend_v) {
					ln->pend_n += 1;
				} else {
					ln->pend_v = v;
					ln->pend_n = 1;
				}
				if (ln->pend_n < (unison ? 1 : SPEED_CHECKS)) {
					continue;
				}
				// (Its new speed from where it is drawn now; the map's phase at it, world.)
				ln->pend_n = 0;
				ln->r0 = wl ? posmod(_world_phase(m) - v * tick, GAP) : pred;
				ln->v = v;
				ln->t0 = tick;
				_write_lane(key, ln, m, lk->second, st);
				continue;
			}
			ln->pend_n = 0;
			if (wl) {
				continue;  // (the map's phase: nothing drifts)
			}
			i64 off = std::abs(pred - posmod(f, GAP));
			if (std::min(off, GAP - off) <= DRIFT) {
				continue;
			}
		} else if (ln == nullptr) {
			ln = new Lane();
			ln->item = item;
			ln->kind_key = kk;
			drawn.set(key, ln);
			undrawn.erase(key);
			_mark(key, ln);
		}
		if (wl) {
			ln->v = has ? v : 0;
			ln->r0 = posmod(_world_phase(m) - ln->v * tick, GAP);
		} else if (has) {
			ln->r0 = posmod(f, GAP);
			ln->v = v;
		} else {
			ln->r0 = _world_phase(m);
			ln->v = 0;
		}
		ln->t0 = tick;
		_write_lane(key, ln, m, lk->second, st);
	}
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
	return res;
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
	i64 dx = (i64)m[3] - m[5];
	i64 dy = (i64)m[4] - m[6];
	i64 tau;
	if (std::abs(dx) >= std::abs(dy)) {
		tau = dx > 0 ? m[3] : -(i64)m[3];
	} else {
		tau = dy > 0 ? m[4] : -(i64)m[4];
	}
	return posmod(tau, GAP);
}

void BeltLatticeNative::_remove(i64 key) {
	Lane *ln = *drawn.get(key);
	drawn.erase(key);
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
	double period = moving ? (double)GAP / (double)ln->v : 0.0;
	Ends ends = _ends(key, length);
	// (Its clock from where slot k is at 64k + r0 on tick t0: the shader's fract() starts at (64 - r0) / 64.)
	double t_start = (double)ln->t0 - base;
	if (moving) {
		t_start -= (double)(GAP - ln->r0) / (double)GAP * period;
	}
	float *d = records.data.data();
	for (i64 k = 0; k < n; k++) {
		double top = moving ? (double)(GAP * (k + 1)) : (double)(ln->r0 + GAP * k);
		Vector4 p = _along(key, top, length, ends);
		Vector4 to = moving ? _along(key, (double)(GAP * k), length, ends) : p;
		i64 uid = _uid(key, k);
		// Turned as every item is (item_cards.gd turn_for), icon cards too.
		double a = yaw_for(uid);
		double c = std::cos(a);
		double s = std::sin(a);
		int r = kd->base + ln->slots[(size_t)(k * st)];
		size_t o = (size_t)r * FLOATS;
		d[o] = p.x;
		d[o + 1] = p.y;
		d[o + 2] = p.z;
		d[o + 3] = (float)t_start;
		if (period > 0.0) {
			d[o + 4] = (float)((double)to.x - (double)p.x);
			d[o + 5] = 0.0f;
			d[o + 6] = (float)((double)to.z - (double)p.z);
		} else {
			d[o + 4] = 0.0f;
			d[o + 5] = 0.0f;
			d[o + 6] = 0.0f;
		}
		d[o + 7] = (float)t_start;
		d[o + 8] = (float)c;
		d[o + 9] = (float)s;
		d[o + 10] = (float)((double)lift.y + LAYER_STEP * (double)posmod(uid, LAYERS));
		d[o + 11] = p.w >= 0.5f ? 0.0f : HIDDEN;
		d[o + 12] = 0.0f;
		d[o + 13] = 0.0f;
		d[o + 14] = 1.0f;  // a lattice slot (not masked)
		d[o + 15] = (float)period;
		records.mark(r / PER_PAGE);
		// Its pile's copies, when placed: the slot's yaw and PILE_TURN more each, k pile steps up, read
		// from the slot's record by the shader.
		for (int j = 1; j < st; j++) {
			i64 i = k * st + j;
			if (i < placed) {
				continue;
			}
			int rc = kd->base + ln->slots[(size_t)i];
			size_t oc = (size_t)rc * FLOATS;
			double a = yaw_for(uid) + PILE_TURN * (double)j;
			for (int q = 0; q < FLOATS; q++) {
				d[oc + q] = 0.0f;
			}
			d[oc + 8] = (float)std::cos(a);
			d[oc + 9] = (float)std::sin(a);
			d[oc + 12] = (float)(r - rc);
			d[oc + 13] = (float)j;
			d[oc + 14] = (float)pile_step;
			records.mark(rc / PER_PAGE);
		}
		if (dump_on) {
			i64 row[8] = { uid, ln->item, (i64)st, key, ln->r0 + GAP * k, ln->t0, ln->v, 0 };
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
	for (i64 j = 0; j <= steps; j++) {
		Vector4 p = _point(key, (double)length * (double)j / (double)steps);
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
	return to_packed<PackedInt64Array>(dump_gone);
}

// belt_items.gd drawn_lattice(): what the shaders draw of a kind's lattice at the drawn clock `t` (from
// `base`): per record [where (with its lift), cosine of its turn], or null where nothing is drawn (tests).
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
		if (d[o + 13] < 0.5f && d[o + 14] > 0.5f && d[o + 15] > 0.0f) {
			g = wrapd((t - d[o + 3]) / d[o + 15], 0.0, 1.0);
		}
		Vector3 at = Vector3(d[o], d[o + 1], d[o + 2]) + Vector3(d[o + 4], d[o + 5], d[o + 6]) * (real_t)g;
		Array e;
		e.push_back(at + Vector3(0.0f, (real_t)((double)d[o + 10] + lift_k), 0.0f));
		e.push_back(k > 0.5 ? own_c : (double)d[o + 8]);
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
	ClassDB::bind_method(D_METHOD("set_lane", "key", "meta", "arc"), &BeltLatticeNative::set_lane);
	ClassDB::bind_method(D_METHOD("note_read", "key", "length", "items"), &BeltLatticeNative::note_read);
	ClassDB::bind_method(D_METHOD("note_check", "key", "length", "count", "front", "back"), &BeltLatticeNative::note_check);
	ClassDB::bind_method(D_METHOD("drop", "key"), &BeltLatticeNative::drop);
	ClassDB::bind_method(D_METHOD("update", "tick", "view", "view_all", "known", "model_cap", "full", "dump", "base", "height", "on",
							  "world", "piles", "unison"),
			&BeltLatticeNative::update);
	ClassDB::bind_method(D_METHOD("clear"), &BeltLatticeNative::clear);
	ClassDB::bind_method(D_METHOD("drawn_lattice", "kind_key", "t"), &BeltLatticeNative::drawn_lattice);
	ClassDB::bind_method(D_METHOD("kind_keys"), &BeltLatticeNative::kind_keys);
	ClassDB::bind_method(D_METHOD("drawn_speed", "key"), &BeltLatticeNative::drawn_speed);
	ClassDB::bind_method(D_METHOD("has_drawn"), &BeltLatticeNative::has_drawn);
	ClassDB::bind_method(D_METHOD("get_lanes_n"), &BeltLatticeNative::get_lanes_n);
	ClassDB::bind_method(D_METHOD("set_lanes_n", "v"), &BeltLatticeNative::set_lanes_n);
	ClassDB::bind_method(D_METHOD("get_slots_n"), &BeltLatticeNative::get_slots_n);
	ClassDB::bind_method(D_METHOD("set_slots_n", "v"), &BeltLatticeNative::set_slots_n);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "lanes_n"), "set_lanes_n", "get_lanes_n");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "slots_n"), "set_slots_n", "get_slots_n");
}
