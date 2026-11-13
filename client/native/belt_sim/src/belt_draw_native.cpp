// BeltDrawNative: belt_items.gd's Job (the records' side) in C++. Function for function after
// belt_items.gd and belt_records.gd; each comment there says why. Here only what differs: where GDScript
// rounds to float32 (Vector2/3/4 components, PackedFloat32Array) this casts at the same point, and the
// rest is double, so both paths write identical records.
#include "belt_draw_native.h"

#include "belt_sim_native.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

using namespace godot;

namespace {

typedef BeltDrawNative::i64 i64;

inline i64 now_us() {
	return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

inline double clampd(double v, double lo, double hi) {
	return v < lo ? lo : (v > hi ? hi : v);
}

inline double lerpd(double a, double b, double t) {
	return a + (b - a) * t;
}

// Math::wrapf
inline double wrapd(double value, double min, double max) {
	double range = max - min;
	return std::fabs(range) < 1e-15 ? min : value - (range * std::floor((value - min) / range));
}

// GDScript's hash(int): Variant::hash() -> hash_one_uint64 (core/templates/hashfuncs.h), a uint32.
// (It had the 64-bit Wang hash, so a model's turn differed from GDScript's; unseen until every item
// turned and tools/belt_draw_diff.py compared the turns.)
inline uint32_t hash_int(i64 x) {
	uint64_t v = (uint64_t)x;
	v = (~v) + (v << 18);
	v = v ^ (v >> 31);
	v = v * 21;
	v = v ^ (v >> 11);
	v = v + (v << 6);
	v = v ^ (v >> 22);
	return (uint32_t)v;
}

inline i64 posmod(i64 a, i64 b) {
	i64 r = a % b;
	if (r != 0 && ((r < 0) != (b < 0))) {
		r += b;
	}
	return r;
}

// Math::round (as roundi)
inline i64 roundi(double x) {
	return (i64)std::round(x);
}

template <class P, class T>
static P to_packed(const std::vector<T> &v) {
	P a;
	a.resize((int64_t)v.size());
	if (!v.empty()) {
		memcpy(a.ptrw(), v.data(), v.size() * sizeof(T));
	}
	return a;
}

} // namespace

// (Records: belt_records_native.cpp.)

// ---------------------------------------------------------------- lanes

BeltDrawNative::BeltDrawNative() {
}

BeltDrawNative::~BeltDrawNative() {
	for (Item *it : items.val_list()) {
		delete it;
	}
	for (Kind *k : kinds.val_list()) {
		delete k;
	}
}

void BeltDrawNative::set_sim(Object *p_sim) {
	sim = Object::cast_to<BeltSimNative>(p_sim);
	sim_ref = Ref<RefCounted>(Object::cast_to<RefCounted>(p_sim));
}

// belt_items.gd _arc
BeltDrawNative::Arc BeltDrawNative::_arc(const int32_t *m) {
	Arc r;
	double ax = (double)m[3], ay = (double)m[4], bx = (double)m[5], by = (double)m[6], cx = (double)m[7], cy = (double)m[8];
	double d = 2.0 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by));
	if (std::fabs(d) < 1e-6) {
		return r;
	}
	double a2 = ax * ax + ay * ay;
	double b2 = bx * bx + by * by;
	double c2 = cx * cx + cy * cy;
	double ux = (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d;
	double uy = (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d;
	double a0 = std::atan2(ay - uy, ax - ux);
	double a1 = std::atan2(cy - uy, cx - ux);
	r.ok = true;
	r.a[0] = ux;
	r.a[1] = uy;
	r.a[2] = (double)Vector2((float)(ax - ux), (float)(ay - uy)).length();
	r.a[3] = a0;
	r.a[4] = wrapd(a1 - a0, -Math_PI, Math_PI);
	return r;
}

void BeltDrawNative::set_lane(i64 key, const PackedInt32Array &meta) {
	if (meta.size() < 9) {
		return;
	}
	Meta mt;
	for (int i = 0; i < 9; i++) {
		mt.m[i] = meta[i];
	}
	lanes[key] = mt;
	if (mt.m[0] == CURVE) {
		arcs[key] = _arc(mt.m);
	}
}

void BeltDrawNative::drop_lane(i64 key) {
	dropped.insert(key);
	lanes.erase(key);
	arcs.erase(key);
}

Vector4 BeltDrawNative::_point(i64 key, double pos) const {
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

Vector2i BeltDrawNative::_advance(i64 key, i64 pos, i64 d) {
	i64 k = key;
	i64 p = pos;
	i64 left = d;
	int guard = 0;
	while (left > p && guard < 4096) {
		left -= p;
		i64 nx = sim->next_of(k);
		auto f = (nx == 0) ? lanes.end() : lanes.find(nx);
		if (nx == 0 || f == lanes.end()) {
			return Vector2i((int32_t)k, 0);
		}
		k = nx;
		p = f->second.m[1];
		guard++;
	}
	return Vector2i((int32_t)k, (int32_t)(p - left));
}

bool BeltDrawNative::_straight_kind(i64 key) const {
	auto f = lanes.find(key);
	return f != lanes.end() && f->second.m[0] != CURVE && f->second.m[0] != UG_HIDDEN;
}

Vector2 BeltDrawNative::_dir(i64 key) const {
	auto f = lanes.find(key);
	if (f == lanes.end()) {
		return Vector2();
	}
	const int32_t *m = f->second.m;
	return Vector2((float)(m[3] - m[7]), (float)(m[4] - m[8])).normalized();
}

// belt_paths.gd path_at, then belt_items.gd _at
Vector3 BeltDrawNative::_at(const Item *it, double t) const {
	double g = it->t_to <= it->t_from ? 1.0 : clampd((t - it->t_from) / (it->t_to - it->t_from), 0.0, 1.0);
	if (it->path.empty()) {
		return it->from + it->step * (float)g;
	}
	int pieces = (int)(it->path.size() / 4) - 1;
	double f = clampd(g, 0.0, 1.0) * pieces;
	int i = std::min((int)f, pieces - 1);
	double u = f - i;
	int a = i * 4;
	const float *p = it->path.data();
	Vector4 o((float)lerpd(p[a], p[a + 4], u), (float)lerpd(p[a + 1], p[a + 5], u), (float)lerpd(p[a + 2], p[a + 6], u),
			(float)lerpd(p[a + 3], p[a + 7], u));
	return it->from + Vector3(o.x, o.y, o.z);
}

// item_cards.gd yaw_for (turn_for(seed) for a lone item or a pile's bottom)
double BeltDrawNative::_yaw_for(i64 seed) {
	return ((double)posmod((i64)hash_int(seed), 2001) / 1000.0 - 1.0) * MAX_YAW;
}

// ---------------------------------------------------------------- view

bool BeltDrawNative::_set_view() {
	if (!view_cull || view_all) {
		return false;
	}
	if (planned_any && planned_view.encloses(view)) {
		return false;
	}
	planned_view = view.grow((float)VIEW_KEEP);
	planned_any = true;
	return true;
}

bool BeltDrawNative::_in_view(i64 key, i64 pos, i64 reach) const {
	if (!view_cull || view_all) {
		return true;
	}
	Vector4 p = _point(key, (double)pos);
	Rect2 r = planned_view.grow((float)(VIEW_MARGIN + (double)std::max<i64>(reach, 0) / 256.0));
	return r.has_point(Vector2(p.x, p.z));
}

void BeltDrawNative::_park(Item *it) {
	if (it->slot >= 0) {
		_unplace(it);
	}
	it->parked = true;
	it->renew = -1.0;
	renewing.erase(it);
	it->path.clear();
	_mark(it);
}

void BeltDrawNative::_unpark(Item *it) {
	it->parked = false;
	_place(it);
	i64 n = it->count;
	it->count = 1;
	_set_count(it, n);
}

void BeltDrawNative::_replan_parked() {
	i64 now = (i64)std::floor(fold_tick);
	for (Item *it : items.val_list()) {
		if (!it->parked) {
			continue;
		}
		i64 d = (it->v > 0 && now > it->t0) ? std::min<i64>(it->v * (now - it->t0), it->reach) : 0;
		Vector2i at = d > 0 ? _advance(it->lane, it->pos, d) : Vector2i((int32_t)it->lane, (int32_t)it->pos);
		if (!_in_view(at.x, at.y, it->reach - d)) {
			continue;
		}
		if (d > 0) {
			it->lane = at.x;
			it->pos = at.y;
			it->reach -= d;
			auto f = lanes.find(it->lane);
			it->run = (f != lanes.end() && f->second.m[0] == STRAIGHT) ? it->pos + sim->run_of(it->lane) : 0;
			it->t0 = now;
		}
		_unpark(it);
		_plan(it);
		unparked++;
	}
}

// ---------------------------------------------------------------- changes

void BeltDrawNative::_apply_changes(const Dictionary &ch) {
	PackedInt64Array uids = ch["uid"];
	changes = uids.size();
	PackedInt32Array itemsa = ch["item"];
	PackedInt32Array stacks = ch["stack"];
	PackedInt64Array keys = ch["key"];
	PackedInt32Array poss = ch["pos"];
	PackedInt64Array ticks = ch["tick"];
	PackedInt32Array speeds = ch["speed"];
	PackedInt32Array reaches = ch["reach"];
	PackedInt32Array runs = ch["run"];
	PackedInt64Array gone = ch["gone"];
	PackedInt64Array gone_ticks = ch.has("gone_tick") ? (PackedInt64Array)ch["gone_tick"] : PackedInt64Array();
	PackedInt32Array gone_at = ch.has("gone_at") ? (PackedInt32Array)ch["gone_at"] : PackedInt32Array();
	gone_n = gone.size();
	// (take_changes() fills the lists in lockstep; a shorter one, from any other caller of run_job,
	// is never read past its end.)
	i64 n_ch = uids.size();
	for (i64 n : { (i64)itemsa.size(), (i64)stacks.size(), (i64)keys.size(), (i64)poss.size(), (i64)ticks.size(),
				 (i64)speeds.size(), (i64)reaches.size(), (i64)runs.size() }) {
		n_ch = std::min(n_ch, n);
	}
	changes = n_ch;
	const i64 *U = uids.ptr();
	const int32_t *I = itemsa.ptr();
	const int32_t *S = stacks.ptr();
	const i64 *K = keys.ptr();
	const int32_t *P = poss.ptr();
	const i64 *T = ticks.ptr();
	const int32_t *V = speeds.ptr();
	const int32_t *R = reaches.ptr();
	const int32_t *RN = runs.ptr();
	i64 now = (i64)std::floor(fold_tick);
	std::unordered_set<i64> held;
	std::vector<i64> idx;
	if (coalesce) {
		std::unordered_map<i64, i64> last_i;
		last_i.reserve((size_t)n_ch);
		for (i64 i = 0; i < n_ch; i++) {
			if (T[i] > now) {
				idx.push_back(i);
			} else {
				last_i[U[i]] = i;
			}
		}
		coalesced = n_ch - (i64)idx.size() - (i64)last_i.size();
		for (auto &kv : last_i) {
			idx.push_back(kv.second);
		}
		std::sort(idx.begin(), idx.end());
	}
	if (!later.empty()) {
		std::vector<Later> lt;
		lt.swap(later);
		for (const Later &e : lt) {
			if (e.tick > now || held.count(e.uid)) {
				if (early && e.what == 0 && !held.count(e.uid) && _apply_early(e.uid, e.item, e.stack, e.key, e.pos, e.tick, e.speed, e.reach, e.run, now)) {
					continue;
				}
				held.insert(e.uid);
				later.push_back(e);
			} else if (e.what == 0) {
				_apply_one(e.uid, e.item, e.stack, e.key, e.pos, e.tick, e.speed, e.reach, e.run);
			} else {
				_go(e.uid);
			}
		}
	}
	i64 gi = 0;
	i64 ng = gone.size();
	bool timed = gone_order && gone_ticks.size() == ng && gone_at.size() == ng;
	const i64 *G = gone.ptr();
	const i64 *GT = gone_ticks.ptr();
	const int32_t *GA = gone_at.ptr();
	i64 n_walk = coalesce ? (i64)idx.size() : n_ch;
	for (i64 w = 0; w < n_walk; w++) {
		i64 i = coalesce ? idx[(size_t)w] : w;
		while (timed && gi < ng && GA[gi] <= i) {
			_go_or_hold(G[gi], GT[gi], now, held);
			gi++;
		}
		i64 uid = U[i];
		if (T[i] > now || (!held.empty() && held.count(uid))) {
			if (early && !held.count(uid) && _apply_early(uid, I[i], S[i], K[i], P[i], T[i], V[i], R[i], RN[i], now)) {
				continue;
			}
			held.insert(uid);
			later.push_back(Later{ 0, uid, T[i], I[i], S[i], K[i], P[i], V[i], R[i], RN[i] });
			continue;
		}
		_apply_one(uid, I[i], S[i], K[i], P[i], T[i], V[i], R[i], RN[i]);
	}
	while (gi < ng) {
		_go_or_hold(G[gi], timed ? GT[gi] : now, now, held);
		gi++;
	}
	PackedInt64Array mism = ch["mismatch"];
	for (i64 i = 0; i < mism.size(); i++) {
		i64 key = mism[i];
		auto f = asked.find(key);
		i64 last = f == asked.end() ? -ASK_AGAIN_MSEC : f->second;
		if (now_msec - last >= ASK_AGAIN_MSEC) {
			asked[key] = now_msec;
			resend.push_back(key);
		}
	}
}

void BeltDrawNative::_go_or_hold(i64 uid, i64 t, i64 now, std::unordered_set<i64> &held) {
	if (t > now && !dropped.empty()) {
		Item **pit = items.get(uid);
		if (pit != nullptr && dropped.count((*pit)->lane)) {
			t = now;
		}
	}
	if (t > now || (!held.empty() && held.count(uid))) {
		held.insert(uid);
		later.push_back(Later{ 1, uid, t, 0, 0, 0, 0, 0, 0, 0 });
		return;
	}
	_go(uid);
}

void BeltDrawNative::_go(i64 uid) {
	Item **pit = items.get(uid);
	if (pit == nullptr) {
		return;
	}
	Item *it = *pit;
	if (it->parked) {
		_remove(uid);
		return;
	}
	Vector3 at = _at(it, fold_tick);
	Vector3 sq = square;
	bool outside = sq.z >= 0.0f && (std::fabs((double)at.x - (double)sq.x) > (double)sq.z || std::fabs((double)at.z - (double)sq.y) > (double)sq.z);
	if ((dropped.count(it->lane) || outside) && far_given) {
		int cx = (int)std::floor((double)at.x / 32.0);
		int cz = (int)std::floor((double)at.z / 32.0);
		if (!far_built.count(_chunk_key(cx, cz))) {
			it->v = 0;
			it->from = at;
			it->step = Vector3();
			it->path.clear();
			it->t_from = fold_tick;
			it->t_to = fold_tick;
			it->renew = -1.0;
			renewing.erase(it);
			kept.set(it, Vector2i(cx, cz));
			_mark(it);
			return;
		}
	}
	_remove(uid);
}

// belt_items.gd's _apply_early: a change after the drawn tick taken now when nothing shows early (a start
// of a standing item, or a continuation of a moving item's record across a line's end).
bool BeltDrawNative::_apply_early(i64 uid, i64 item, i64 stack, i64 key, i64 pos, i64 t0, i64 v, i64 reach, i64 run, i64 now) {
	Item **pit = items.get(uid);
	if (pit == nullptr) {
		return false;
	}
	Item *it = *pit;
	i64 n = std::max<i64>(1, std::min<i64>(stack, MAX_STACK));
	if (it->parked || it->item_id != item || (i64)it->count != n || kept.has(it)) {
		return false;
	}
	if (it->v <= 0) {
		if (v > 0 && it->lane == key && it->pos == pos && it->t0 <= now) {
			_apply_one(uid, item, stack, key, pos, t0, v, reach, run);
			early_n++;
			return true;
		}
		return false;
	}
	if (v != it->v) {
		return false;
	}
	i64 d = it->v * (t0 - it->t0);
	if (d <= 0) {
		return false;
	}
	Vector2i at = _advance(it->lane, it->pos, d);
	if ((i64)at.x != key || (i64)at.y != pos) {
		return false;
	}
	i64 d0 = std::max<i64>(0, std::min<i64>(it->v * (now - it->t0), d));
	Vector2i from = _advance(it->lane, it->pos, d0);
	it->lane = from.x;
	it->pos = from.y;
	it->t0 = d0 > 0 ? std::max<i64>(it->t0, now) : it->t0;
	it->reach = (d - d0) + reach;
	auto f = lanes.find(it->lane);
	it->run = (f != lanes.end() && f->second.m[0] == STRAIGHT) ? it->pos + sim->run_of(it->lane) : 0;
	if (!_in_view(it->lane, it->pos, it->reach)) {
		_park(it);
		parked++;
		return true;
	}
	_plan(it);
	early_n++;
	return true;
}

void BeltDrawNative::_apply_one(i64 uid, i64 item, i64 stack, i64 key, i64 pos, i64 t0, i64 v, i64 reach, i64 run) {
	Item **pit = items.get(uid);
	Item *it;
	if (pit == nullptr) {
		it = new Item();
		it->uid = uid;
		it->item_id = item;
		it->key = item;
		double a = _yaw_for(uid);
		it->c = std::cos(a);
		it->s = std::sin(a);
		it->parked = true;
		items.set(uid, it);
	} else {
		it = *pit;
		if (it->item_id != item) {
			it->item_id = item;
			_rekey(it, item);
		}
	}
	kept.erase(it);
	_set_count(it, stack);
	it->lane = key;
	it->pos = pos;
	it->t0 = t0;
	it->v = v;
	it->reach = reach;
	it->run = run;
	if (!_in_view(key, pos, reach)) {
		if (!it->parked) {
			_park(it);
		}
		parked++;
		return;
	}
	if (it->parked) {
		_unpark(it);
	}
	_plan(it);
}

// ---------------------------------------------------------------- records of motion

void BeltDrawNative::_plan(Item *it) {
	Vector4 p0 = _point(it->lane, (double)it->pos);
	it->from = Vector3(p0.x, p0.y, p0.z);
	it->t_from = (double)it->t0;
	it->renew = -1.0;
	renewing.erase(it);
	it->path.clear();
	it->hidden = p0.w < 0.5f;
	_mark(it);
	auto lf = lanes.find(it->lane);
	if (lf != lanes.end() && it->pos > lf->second.m[1]) {
		it->hidden = true;
		it->step = Vector3();
		i64 behind = it->pos - lf->second.m[1];
		if (it->v <= 0 || it->reach <= behind) {
			it->t_to = it->t_from;
			return;
		}
		if (!lead_on) {
			it->t_to = it->t_from + (double)behind / (double)it->v;
			it->renew = it->t_to;
			renewing.set(it, true);
			return;
		}
		_plan_path(it, std::min<i64>(it->reach, behind + (i64)std::ceil((double)it->v * 2.0 * lead)));
		return;
	}
	if (it->v <= 0 || it->reach <= 0) {
		it->step = Vector3();
		it->t_to = it->t_from;
		return;
	}
	if (!it->hidden && it->run >= it->reach && _straight_kind(it->lane)) {
		Vector2 dir = _dir(it->lane);
		double d = (double)it->reach / 256.0;
		it->step = Vector3((float)((double)dir.x * d), 0.0f, (float)((double)dir.y * d));
		it->t_to = it->t_from + (double)it->reach / (double)it->v;
		return;
	}
	int kind = lf != lanes.end() ? lf->second.m[0] : OTHER;
	i64 d;
	if (!it->hidden && it->run > 0 && kind == STRAIGHT) {
		d = std::min<i64>(it->run, it->reach);
	} else {
		d = std::min<i64>(it->pos, it->reach);
	}
	if (lead_on && d > 0 && d < it->reach && (double)d / (double)it->v < lead) {
		_plan_path(it, std::min<i64>(it->reach, std::max<i64>(d + (i64)std::ceil((double)it->v * lead), (i64)std::ceil((double)it->v * 2.0 * lead))));
		return;
	}
	if (d <= 0) {
		i64 nx = sim->next_of(it->lane);
		auto nf = (nx == 0) ? lanes.end() : lanes.find(nx);
		if (nx == 0 || nf == lanes.end() || plan_depth > 8) {
			it->step = Vector3();
			it->t_to = it->t_from;
			return;
		}
		it->lane = nx;
		it->pos = nf->second.m[1];
		plan_depth++;
		_plan(it);
		plan_depth--;
		return;
	}
	it->t_to = it->t_from + (double)d / (double)it->v;
	if (kind == CURVE && !it->hidden) {
		int n = (int)std::ceil((double)d / (SPACING * 256.0));
		n = std::max(1, std::min(n, MAX_POINTS - 1));
		it->path.assign((size_t)(n + 1) * 4, 0.0f);
		for (int j = 0; j <= n; j++) {
			Vector4 q = _point(it->lane, (double)it->pos - (double)d * j / n);
			it->path[j * 4] = (float)((double)q.x - (double)it->from.x);
			it->path[j * 4 + 1] = 0.0f;
			it->path[j * 4 + 2] = (float)((double)q.z - (double)it->from.z);
			it->path[j * 4 + 3] = q.w;
		}
		it->step = Vector3();
	} else {
		Vector2 dir = _dir(it->lane);
		double dd = (double)d / 256.0;
		it->step = Vector3((float)((double)dir.x * dd), 0.0f, (float)((double)dir.y * dd));
	}
	if (d < it->reach) {
		it->renew = it->t_to;
		renewing.set(it, true);
	}
}

void BeltDrawNative::_plan_path(Item *it, i64 dist) {
	int n = (int)std::ceil((double)dist / (SPACING * 256.0));
	n = std::max(1, std::min(n, MAX_POINTS - 1));
	double piece = (double)dist / n;
	std::vector<float> path((size_t)(n + 1) * 4, 0.0f);
	std::vector<uint8_t> shows(n + 1, 0);
	std::vector<i64> at(n + 1, 0);
	std::vector<i64> keys(n + 1, 0);
	bool any = false;
	for (int j = 0; j <= n; j++) {
		Vector2i q = _advance(it->lane, it->pos, roundi(piece * j));
		auto mf = lanes.find(q.x);
		bool has_m = mf != lanes.end();
		Vector4 w = _point(q.x, (double)q.y);
		bool on = w.w > 0.5f && has_m && q.y <= mf->second.m[1];
		if (has_m && q.y > mf->second.m[1]) {
			Vector4 inner = _point(q.x, (double)std::max(mf->second.m[1] - 32, 0));
			Vector2 back = Vector2((float)((double)w.x - (double)inner.x), (float)((double)w.z - (double)inner.z)).normalized() *
					(float)((double)(q.y - mf->second.m[1]) / 256.0);
			w.x = (float)((double)w.x + (double)back.x);
			w.z = (float)((double)w.z + (double)back.y);
		}
		path[j * 4] = (float)((double)w.x - (double)it->from.x);
		path[j * 4 + 1] = 0.0f;
		path[j * 4 + 2] = (float)((double)w.z - (double)it->from.z);
		path[j * 4 + 3] = on ? 1.0f : 0.0f;
		shows[j] = on ? 1 : 0;
		at[j] = q.y;
		keys[j] = q.x;
		any = any || on;
	}
	for (int j = 0; j < n; j++) {
		if (shows[j] == shows[j + 1]) {
			continue;
		}
		auto mf = lanes.find(keys[j]);
		double b = (mf != lanes.end() && at[j] > mf->second.m[1]) ? (double)(at[j] - mf->second.m[1]) : (double)at[j];
		double f = clampd(b / piece, 0.0, 1.0);
		if (shows[j] == 1) {
			path[j * 4 + 3] = (float)(0.5 + f);
			path[(j + 1) * 4 + 3] = (float)(f - 0.5);
		} else {
			path[j * 4 + 3] = (float)(0.5 - f);
			path[(j + 1) * 4 + 3] = (float)(1.5 - f);
		}
	}
	it->t_to = it->t_from + (double)dist / (double)it->v;
	it->step = Vector3();
	it->hidden = !any;
	if (any) {
		it->path.swap(path);
	} else {
		it->path.clear();
	}
	if (dist < it->reach) {
		it->renew = it->t_to;
		renewing.set(it, true);
	}
}

void BeltDrawNative::_renew() {
	if (renewing.size() == 0) {
		return;
	}
	i64 now = (i64)std::floor(fold_tick);
	for (Item *it : renewing.key_list()) {
		if (it->renew < 0.0 || fold_tick + (lead_on ? lead : 0.0) < it->renew) {
			continue;
		}
		i64 d = it->v * (now - it->t0);
		if (d >= it->reach || it->v <= 0) {
			renewing.erase(it);
			continue;
		}
		if (d <= 0) {
			continue;
		}
		Vector2i at = _advance(it->lane, it->pos, d);
		it->lane = at.x;
		it->pos = at.y;
		it->reach -= d;
		auto f = lanes.find(it->lane);
		it->run = (f != lanes.end() && f->second.m[0] == STRAIGHT) ? it->pos + sim->run_of(it->lane) : 0;
		it->t0 = now;
		_plan(it);
		renewed++;
	}
}

void BeltDrawNative::_keep_or_drop() {
	held_chunks.clear();
	if (kept.size() == 0) {
		return;
	}
	for (Item *it : kept.key_list()) {
		Vector2i c = *kept.get(it);
		it->kept++;
		if (it->kept > KEEP_UPDATES || !far_given || far_built.count(_chunk_key(c.x, c.y))) {
			kept.erase(it);
			_remove(it->uid);
		} else {
			held_chunks.insert(_chunk_key(c.x, c.y));
		}
	}
}

void BeltDrawNative::_remove(i64 uid) {
	Item **pit = items.get(uid);
	if (pit == nullptr) {
		return;
	}
	Item *it = *pit;
	if (dumping) {
		dump_gone.push_back(uid);
	}
	_unplace(it);
	items.erase(uid);
	pathed.erase(it);
	_free_path(it);
	renewing.erase(it);
	kept.erase(it);
	// (GDScript's Item lives on while anything refers to it; here only `dirty` can, and _write lets it go.)
	if (it->dirty) {
		it->uid = -1;
	} else {
		delete it;
	}
}

void BeltDrawNative::_free_path(Item *it) {
	if (it->path_at < 0) {
		return;
	}
	path_free[it->path_cap].push_back(it->path_at);
	it->path_at = -1;
	it->path_cap = 0;
}

void BeltDrawNative::_mark(Item *it) {
	if (!it->dirty) {
		it->dirty = true;
		dirty.push_back(it);
	}
}

BeltDrawNative::Kind *BeltDrawNative::_kind_of(i64 key) {
	Kind **pk = kinds.get(key);
	return pk == nullptr ? nullptr : *pk;
}

void BeltDrawNative::_set_count(Item *it, i64 n) {
	n = std::max<i64>(1, std::min<i64>(n, MAX_STACK));
	it->count = (int)n;
	if (it->slot < 0 || (i64)it->layers.size() == n - 1) {
		return;
	}
	Kind *kind = _kind_of(it->key);
	while ((i64)it->layers.size() > n - 1) {
		int gone = it->layers.back();
		it->layers.pop_back();
		it->layer_stamp.pop_back();
		kind->slots[gone] = SlotRef();
		kind->free.push_back(gone);
		kind->emptied.push_back(gone);
	}
	while ((i64)it->layers.size() < n - 1) {
		int k = (int)it->layers.size() + 1;
		it->layers.push_back(-1);
		it->layer_stamp.push_back(0);
		it->layers[k - 1] = _put(kind, SlotRef{ it, k });
	}
}

void BeltDrawNative::_place(Item *it) {
	Kind *kind = _kind_of(it->key);
	if (kind == nullptr) {
		kind = new Kind();
		kinds.set(it->key, kind);
	}
	it->slot = _put(kind, SlotRef{ it, 0 });
}

void BeltDrawNative::_cap_models() {
	if (model_cap < 0) {
		for (Item *it : items.val_list()) {
			if (it->key != it->item_id) {
				_rekey(it, it->item_id);
			}
		}
		return;
	}
	Vector2 c(square.x, square.y);
	std::vector<Item *> sel;
	std::vector<float> dists;
	std::vector<char> models;
	for (Item *it : items.val_list()) {
		auto lk = known.find(it->item_id);
		if (lk != known.end() && !lk->second.turns) {
			if (it->key != it->item_id) {
				_rekey(it, it->item_id);
			}
			continue;
		}
		bool model = it->key == it->item_id;
		sel.push_back(it);
		models.push_back(model ? 1 : 0);
		if (cam_led) {
			// view_priority.gd view_distance_sq: within the margin of every plane, else INF (never counted).
			// A model already keeps its look a little further outside the view too.
			double margin = CAM_MARGIN + (model ? CAP_SLACK : 0.0);
			float d = cam_pos.distance_squared_to(it->from);
			for (const Plane &pl : cam_planes) {
				if ((double)pl.distance_to(it->from) > margin) {
					d = INFINITY;
					break;
				}
			}
			dists.push_back(d);
		} else {
			dists.push_back(c.distance_squared_to(Vector2(it->from.x, it->from.z)));
		}
	}
	if (sel.empty()) {
		return;
	}
	// view_priority.gd choose(): the cap nearest first among the counted (finite) ones.
	std::vector<float> order;
	order.reserve(dists.size());
	for (float d : dists) {
		if (d < INFINITY) {
			order.push_back(d);
		}
	}
	double limit = INFINITY;
	if (model_cap < (int)order.size()) {
		std::sort(order.begin(), order.end());
		limit = model_cap > 0 ? (double)order[std::max(model_cap - 1, 0)] : -1.0;
	}
	double keep = (limit == INFINITY || limit < 0.0) ? limit : std::pow(std::sqrt(limit) + CAP_SLACK, 2.0);
	for (size_t i = 0; i < sel.size(); i++) {
		Item *it = sel[i];
		bool model = models[i] == 1;
		double d = (double)dists[i];
		bool want = d < INFINITY && d <= (model ? keep : limit);
		if (want != model) {
			_rekey(it, want ? it->item_id : -it->item_id - 1);
		}
	}
}

// belt_items.gd Job._cam_moved
bool BeltDrawNative::_cam_moved() const {
	if (cam_led != capped_cam) {
		return true;
	}
	return cam_led && ((double)cam_pos.distance_squared_to(capped_cam_pos) > CAM_STEP * CAM_STEP || (double)cam_dir.dot(capped_cam_dir) < CAM_TURN);
}

void BeltDrawNative::_rekey(Item *it, i64 key) {
	if (it->parked) {
		it->key = key;
		return;
	}
	i64 n = it->count;
	_unplace(it);
	it->key = key;
	_place(it);
	it->count = 1;
	_set_count(it, n);
	_mark(it);
}

int BeltDrawNative::_put(Kind *kind, SlotRef e) {
	int slot;
	if (kind->free.empty()) {
		slot = (int)kind->slots.size();
		kind->slots.push_back(e);
	} else {
		slot = kind->free.back();
		kind->free.pop_back();
		kind->slots[slot] = e;
	}
	kind->fresh.push_back(e);
	return slot;
}

void BeltDrawNative::_unplace(Item *it) {
	Kind *kind = _kind_of(it->key);
	if (kind == nullptr) {
		return;
	}
	if (it->slot >= 0) {
		kind->slots[it->slot] = SlotRef();
		kind->free.push_back(it->slot);
		kind->emptied.push_back(it->slot);
		it->slot = -1;
	}
	for (int s : it->layers) {
		if (s < 0) {
			continue;
		}
		kind->slots[s] = SlotRef();
		kind->free.push_back(s);
		kind->emptied.push_back(s);
	}
	it->layers.clear();
	it->layer_stamp.clear();
}

// ---------------------------------------------------------------- writing

void BeltDrawNative::_write() {
	writes++;
	int writing = writes;
	std::vector<SlotRef> batch;
	for (Item *it : dirty) {
		if (it->path.empty() || it->uid < 0) {
			pathed.erase(it);
			_free_path(it);
			continue;
		}
		pathed.insert(it);
		int k = (int)(it->path.size() / 4);
		if (it->path_at < 0 || it->path_cap < k) {
			_free_path(it);
			int cap = 8;
			while (cap < k) {
				cap *= 2;
			}
			auto fl = path_free.find(cap);
			if (fl != path_free.end() && !fl->second.empty()) {
				it->path_at = fl->second.back();
				fl->second.pop_back();
			} else if (path_top + cap <= PATH_WIDTH * MAX_ROWS) {
				it->path_at = path_top;
				path_top += cap;
				if ((int)path_tex.size() < path_top * 4) {
					int rows = 1;
					while (rows * PATH_WIDTH < path_top) {
						rows *= 2;
					}
					path_tex.resize((size_t)rows * PATH_WIDTH * 4, 0.0f);
				}
			}
			it->path_cap = it->path_at >= 0 ? cap : 0;
		}
		it->code = 0.0;
		if (it->path_at >= 0) {
			size_t o = (size_t)it->path_at * 4;
			for (size_t q = 0; q < it->path.size(); q++) {
				path_tex[o + q] = it->path[q];
			}
			it->code = 1.0 + (double)it->path_at * 64 + (k - 2);
			path_dirty = true;
		}
		it->code_at = writing;
	}
	for (i64 item_id : kinds.key_list()) {
		Kind *kind = *kinds.get(item_id);
		auto lk = known.find(item_id);
		if (full) {
			kind->known = false;
		}
		if (!kind->known && lk != known.end()) {
			kind->known = true;
			kind->lift = lk->second.lift;
			kind->pile = lk->second.pile;
			kind->fresh.clear();
			for (const SlotRef &e : kind->slots) {
				if (e.it != nullptr) {
					kind->fresh.push_back(e);
				}
			}
		}
		_compact(kind);
		int n = (int)kind->slots.size();
		if (n > kind->cap || kind->base < 0) {
			int cap = MIN_RUN;
			while (cap < std::max(n, kind->cap * 2)) {
				cap *= 2;
			}
			int nb = records.alloc(cap);
			if (kind->base >= 0) {
				records.copy(kind->base, nb, kind->cap);
				records.release(kind->base, kind->cap);
			}
			for (int i = kind->cap; i < cap; i++) {
				records.hide(nb + i);
			}
			kind->base = nb;
			kind->cap = cap;
		}
		if (!kind->known) {
			unknown.push_back(item_id);
			continue;
		}
		for (int i : kind->emptied) {
			if (i < kind->cap) {
				records.hide(kind->base + i);
			}
		}
		kind->emptied.clear();
		for (const SlotRef &e : kind->fresh) {
			int slot = e.k == 0 ? e.it->slot : ((int)e.it->layers.size() >= e.k ? e.it->layers[e.k - 1] : -1);
			if (slot >= 0) {
				batch.push_back(e);
			}
		}
		kind->fresh.clear();
		Vector3i told(kind->base, n, kind->cap);
		if (full || told != kind->told) {
			kind->told = told;
			Array w;
			w.push_back(item_id);
			w.push_back(kind->base);
			w.push_back(n);
			w.push_back(kind->cap);
			written.push_back(w);
		}
	}
	std::vector<Item *> gone_items;
	for (Item *it : dirty) {
		it->dirty = false;
		if (it->uid < 0) {
			gone_items.push_back(it);
			continue;
		}
		if (it->slot < 0) {
			continue;
		}
		Kind *kind = _kind_of(it->key);
		if (kind == nullptr || !kind->known) {
			continue;
		}
		batch.push_back(SlotRef{ it, 0 });
		if (!pile_one) {
			for (size_t k = 0; k < it->layers.size(); k++) {
				batch.push_back(SlotRef{ it, (int)k + 1 });
			}
		}
	}
	dirty.clear();
	_records(batch, writing);
	for (Item *it : gone_items) {
		delete it;
	}
	if (path_dirty && !path_tex.empty()) {
		path_dirty = false;
		PackedByteArray bytes;
		bytes.resize((int64_t)path_tex.size() * 4);
		memcpy(bytes.ptrw(), path_tex.data(), path_tex.size() * 4);
		paths = Image::create_from_data(PATH_WIDTH, (int)(path_tex.size() / 4 / PATH_WIDTH), false, Image::FORMAT_RGBAF, bytes);
	}
}

void BeltDrawNative::_records(const std::vector<SlotRef> &batch, int writing) {
	float *d = records.data.data();
	i64 n = 0;
	for (const SlotRef &e : batch) {
		Item *it = e.it;
		int slot;
		int *stamp;
		if (e.k == 0) {
			slot = it->slot;
			stamp = &it->stamp;
		} else {
			if ((int)it->layers.size() < e.k) {
				continue;
			}
			slot = it->layers[e.k - 1];
			stamp = &it->layer_stamp[e.k - 1];
		}
		if (slot < 0 || *stamp == writing) {
			continue;
		}
		*stamp = writing;
		n++;
		Kind *kind = _kind_of(it->key);
		int r = kind->base + slot;
		size_t o = (size_t)r * FLOATS;
		if (e.k > 0 && pile_one) {
			// (Its own turn in texel 2: item_cards.gd turn_for(uid, k), cards and blocks too.)
			for (int q = 0; q < FLOATS; q++) {
				d[o + q] = 0.0f;
			}
			double a = std::atan2(it->s, it->c) + PILE_TURN * (double)e.k;
			d[o + 8] = (float)std::cos(a);
			d[o + 9] = (float)std::sin(a);
			d[o + 12] = (float)(it->slot - slot);
			d[o + 13] = (float)e.k;
			d[o + 14] = (float)kind->pile;
			records.mark(r / PER_PAGE);
			continue;
		}
		// Every item turns, models, icon cards and blocks alike (item_cards.gd turn_for).
		double c = it->c;
		double s = it->s;
		double lift = (double)kind->lift.y + LAYER_STEP * (double)(it->uid % LAYERS);
		if (e.k > 0) {
			// (--belt-draw-pile=off: the copy's own record, a step higher and turned PILE_TURN more each.)
			lift += kind->pile * (double)e.k;
			double a = std::atan2(it->s, it->c) + PILE_TURN * (double)e.k;
			c = std::cos(a);
			s = std::sin(a);
		}
		double code = 0.0;
		if (it->hidden) {
			code = (double)HIDDEN;
		} else if (!it->path.empty()) {
			code = it->code;
		}
		d[o] = it->from.x;
		d[o + 1] = it->from.y;
		d[o + 2] = it->from.z;
		d[o + 3] = (float)(it->t_from - base);
		d[o + 4] = it->step.x;
		d[o + 5] = it->step.y;
		d[o + 6] = it->step.z;
		d[o + 7] = (float)(it->t_to - base);
		d[o + 8] = (float)c;
		d[o + 9] = (float)s;
		d[o + 10] = (float)lift;
		d[o + 11] = (float)code;
		d[o + 12] = 0.0f;
		d[o + 13] = 0.0f;
		d[o + 14] = 0.0f;
		d[o + 15] = 0.0f;
		records.mark(r / PER_PAGE);
		if (dumping && e.k == 0) {
			i64 ids[8] = { it->uid, it->item_id, it->count, it->lane, it->pos, it->t0, it->v, it->reach };
			dump_ids.insert(dump_ids.end(), ids, ids + 8);
			dump_recs.insert(dump_recs.end(), d + o, d + o + FLOATS);
		}
	}
	records_written += n;
}

void BeltDrawNative::_compact(Kind *kind) {
	while (!kind->slots.empty() && kind->slots.back().it == nullptr) {
		kind->slots.pop_back();
	}
	int n = (int)kind->slots.size();
	if (kind->free.size() > 64 && kind->free.size() * 2 > (size_t)n) {
		std::vector<SlotRef> packed;
		for (const SlotRef &e : kind->slots) {
			if (e.it != nullptr) {
				int s = (int)packed.size();
				if (e.k == 0) {
					e.it->slot = s;
				} else {
					e.it->layers[e.k - 1] = s;
				}
				packed.push_back(e);
			}
		}
		kind->slots = packed;
		kind->fresh = packed;
		kind->free.clear();
		kind->emptied.clear();
		return;
	}
	if (!kind->free.empty()) {
		std::vector<int> keep;
		for (int i : kind->free) {
			if (i < n) {
				keep.push_back(i);
			}
		}
		kind->free = keep;
	}
}

// ---------------------------------------------------------------- the job

Dictionary BeltDrawNative::run_job(const Dictionary &ch, const Dictionary &params) {
	Dictionary res;
	if (sim == nullptr) {
		return res;
	}
	fold_tick = (double)params.get("fold", 0.0);
	lead = (double)params.get("lead", 2.0);
	now_msec = (i64)params.get("now_msec", 0);
	full = (bool)params.get("full", false);
	model_cap = (int)params.get("model_cap", -1);
	square = (Vector3)params.get("square", Vector3(0.0f, 0.0f, -1.0f));
	base = (double)params.get("base", -1.0);
	height = (double)params.get("height", 0.16);
	dumping = (bool)params.get("dump", false);
	coalesce = (bool)params.get("coalesce", true);
	early = (bool)params.get("early", true);
	view_cull = (bool)params.get("view_cull", true);
	lead_on = (bool)params.get("lead_on", true);
	gone_order = (bool)params.get("gone_order", true);
	pile_one = (bool)params.get("pile_one", true);
	view_all = (bool)params.get("view_all", true);
	view = (Rect2)params.get("view", Rect2());
	cam_led = (bool)params.get("cam_led", false);
	cam_pos = (Vector3)params.get("cam_pos", Vector3());
	cam_dir = (Vector3)params.get("cam_dir", Vector3(0.0f, 0.0f, -1.0f));
	cam_planes.clear();
	Array cpl = params.get("cam_planes", Array());
	for (int i = 0; i < cpl.size(); i++) {
		cam_planes.push_back((Plane)cpl[i]);
	}
	known.clear();
	Dictionary kn = params.get("known", Dictionary());
	Array kk = kn.keys();
	for (int i = 0; i < kk.size(); i++) {
		Array look = kn[kk[i]];
		Look l;
		if (look.size() >= 2) {
			l.lift = (Vector3)look[0];
			l.turns = (bool)look[1];
			l.pile = look.size() > 2 ? (double)look[2] : 0.07;
			known[(i64)kk[i]] = l;
		}
	}
	far_built.clear();
	Variant fb = params.get("far_built", Variant());
	far_given = fb.get_type() == Variant::DICTIONARY;
	if (far_given) {
		Dictionary fbd = fb;
		Array fk = fbd.keys();
		for (int i = 0; i < fk.size(); i++) {
			Vector2i c = fk[i];
			far_built.insert(_chunk_key(c.x, c.y));
		}
	}
	written = Array();
	unknown = Array();
	records_written = changes = coalesced = early_n = renewed = gone_n = parked = unparked = 0;
	resend.clear();
	paths = Ref<Image>();
	dump_ids.clear();
	dump_recs.clear();
	dump_gone.clear();

	i64 ta = now_us();
	bool view_moved = _set_view();
	_apply_changes(ch);
	if (view_moved) {
		_replan_parked();
	}
	i64 tr = now_us();
	_renew();
	i64 tk = now_us();
	_keep_or_drop();
	i64 cap_us = 0;
	if (model_cap != capped_at || (model_cap >= 0 && (square != capped_square || cap_jobs >= CAP_EVERY || _cam_moved()))) {
		capped_square = square;
		capped_at = model_cap;
		capped_cam = cam_led;
		capped_cam_pos = cam_pos;
		capped_cam_dir = cam_dir;
		cap_jobs = 0;
		i64 tc = now_us();
		_cap_models();
		cap_us = now_us() - tc;
	}
	cap_jobs++;
	i64 tw = now_us();
	_write();
	i64 te = now_us();
	dropped.clear();

	// Positions of the watched items (position_of).
	Dictionary positions;
	bool watch_all = (bool)params.get("watch_all", false);
	Array watch = params.get("watch", Array());
	std::vector<i64> wl;
	if (watch_all) {
		wl = items.key_list();
	} else {
		for (int i = 0; i < watch.size(); i++) {
			wl.push_back((i64)watch[i]);
		}
	}
	for (i64 uid : wl) {
		Item **pit = items.get(uid);
		if (pit == nullptr) {
			continue;
		}
		Item *it = *pit;
		Array p;
		p.push_back(it->from);
		p.push_back(it->step);
		p.push_back(to_packed<PackedFloat32Array>(it->path));
		p.push_back(it->t_from);
		p.push_back(it->t_to);
		p.push_back(it->hidden);
		positions[uid] = p;
	}
	Dictionary hc;
	for (i64 k : held_chunks) {
		hc[Vector2i((int32_t)(k >> 32), (int32_t)(k & 0xffffffff))] = true;
	}
	res["apply_usec"] = tr - ta;
	res["renew_usec"] = tk - tr;
	res["cap_usec"] = cap_us;
	res["write_usec"] = te - tw;
	res["written"] = written;
	res["unknown"] = unknown;
	res["records_written"] = records_written;
	res["changes"] = changes;
	res["coalesced"] = coalesced;
	res["early"] = early_n;
	res["renewed"] = renewed;
	res["gone_n"] = gone_n;
	res["parked"] = parked;
	res["unparked"] = unparked;
	res["resend"] = to_packed<PackedInt64Array>(resend);
	res["positions"] = positions;
	res["held_chunks"] = hc;
	res["count"] = (i64)items.size();
	res["kept"] = (i64)kept.size();
	res["later"] = (i64)later.size();
	res["lanes"] = (i64)lanes.size();
	if (paths.is_valid()) {
		res["paths"] = paths;
		if (dumping) {
			res["path_tex"] = to_packed<PackedFloat32Array>(path_tex);
		}
	}
	res["pages"] = records.take_pages();
	if (dumping) {
		res["dump_ids"] = to_packed<PackedInt64Array>(dump_ids);
		res["dump_recs"] = to_packed<PackedFloat32Array>(dump_recs);
		res["dump_gone"] = to_packed<PackedInt64Array>(dump_gone);
	}
	return res;
}

// belt_items.gd drawn(): what the shaders draw for a kind at the drawn clock `t` (from `base`).
Array BeltDrawNative::drawn(i64 key, double t) {
	Array out;
	Kind *kind = _kind_of(key);
	if (kind == nullptr || kind->base < 0) {
		return out;
	}
	const float *d = records.data.data();
	for (size_t slot = 0; slot < kind->slots.size(); slot++) {
		size_t o = ((size_t)kind->base + slot) * FLOATS;
		double k = d[o + 13];
		double lift_k = 0.0;
		float own_c = 0.0f;
		if (k > 0.5) {
			lift_k = (double)d[o + 14] * k;
			own_c = d[o + 8];
			o += (size_t)((i64)(int)d[o + 12] * FLOATS);
		}
		float code = d[o + 11];
		if (code < -0.5f) {
			out.push_back(Variant());
			continue;
		}
		double g = d[o + 7] > d[o + 3] ? clampd((t - (double)d[o + 3]) / ((double)d[o + 7] - (double)d[o + 3]), 0.0, 1.0) : 1.0;
		Vector3 at(d[o], d[o + 1], d[o + 2]);
		if (code < 0.5f) {
			at += Vector3(d[o + 4], d[o + 5], d[o + 6]) * (float)g;
		} else if (!path_tex.empty()) {
			int c = (int)((double)code + 0.5) - 1;
			int first = c / 64;
			int pieces = c - first * 64 + 1;
			double f = clampd(g, 0.0, 1.0) * pieces;
			int i = std::min((int)f, pieces - 1);
			size_t a = ((size_t)first + i) * 4;
			if (a + 8 > path_tex.size()) {
				out.push_back(Variant());
				continue;
			}
			double u = f - i;
			double px = lerpd(path_tex[a], path_tex[a + 4], u);
			double py = lerpd(path_tex[a + 1], path_tex[a + 5], u);
			double pz = lerpd(path_tex[a + 2], path_tex[a + 6], u);
			double pw = lerpd(path_tex[a + 3], path_tex[a + 7], u);
			if (pw < 0.5) {
				out.push_back(Variant());
				continue;
			}
			at += Vector3((float)px, (float)py, (float)pz);
		}
		Array e;
		e.push_back(at + Vector3(0.0f, (float)((double)d[o + 10] + lift_k), 0.0f));
		e.push_back(k > 0.5 ? own_c : d[o + 8]);
		out.push_back(e);
	}
	return out;
}

Dictionary BeltDrawNative::stats() const {
	Dictionary d;
	d["items"] = (i64)items.size();
	d["kinds"] = (i64)kinds.size();
	d["lanes"] = (i64)lanes.size();
	d["pages"] = records.pages;
	d["path_top"] = path_top;
	d["renewing"] = (i64)renewing.size();
	d["later"] = (i64)later.size();
	d["kept"] = (i64)kept.size();
	return d;
}

void BeltDrawNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_sim", "sim"), &BeltDrawNative::set_sim);
	ClassDB::bind_method(D_METHOD("set_lane", "key", "meta"), &BeltDrawNative::set_lane);
	ClassDB::bind_method(D_METHOD("drop_lane", "key"), &BeltDrawNative::drop_lane);
	ClassDB::bind_method(D_METHOD("run_job", "changes", "params"), &BeltDrawNative::run_job);
	ClassDB::bind_method(D_METHOD("drawn", "key", "t"), &BeltDrawNative::drawn);
	ClassDB::bind_method(D_METHOD("has_item", "uid"), &BeltDrawNative::has_item);
	ClassDB::bind_method(D_METHOD("stats"), &BeltDrawNative::stats);
}
