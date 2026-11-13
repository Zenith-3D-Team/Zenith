// BeltSimNative: belt_sim.gd in C++ (see belt_sim_native.h). Function for function the same as the
// GDScript, in the same order, so a change there is easy to mirror here.
#include "belt_sim_native.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <map>

using namespace godot;

typedef BeltSimNative::i64 i64;

static inline i64 mini(i64 a, i64 b) { return a < b ? a : b; }
static inline i64 maxi(i64 a, i64 b) { return a > b ? a : b; }
static inline i64 absi(i64 a) { return a < 0 ? -a : a; }
static inline i64 signi(i64 a) { return a > 0 ? 1 : (a < 0 ? -1 : 0); }
static inline i64 clampi(i64 v, i64 lo, i64 hi) { return v < lo ? lo : (v > hi ? hi : v); }

static i64 now_usec() {
	return std::chrono::duration_cast<std::chrono::microseconds>(
			std::chrono::steady_clock::now().time_since_epoch())
			.count();
}

// PackedInt32Array.bsearch(value, false): the index after the last element <= value.
template <typename T>
static int upper_index(const std::vector<T> &a, i64 v) {
	return int(std::upper_bound(a.begin(), a.end(), v, [](i64 x, const T &e) { return x < (i64)e; }) - a.begin());
}

template <typename T>
static void erase_value(std::vector<T> &a, T v) {
	auto it = std::find(a.begin(), a.end(), v);
	if (it != a.end()) {
		a.erase(it);
	}
}

bool BeltSimNative::Line::holds_has(i64 u) const {
	for (i64 x : holds) {
		if (x == u) {
			return true;
		}
	}
	return false;
}

void BeltSimNative::Line::holds_add(i64 u) {
	if (!holds_has(u)) {
		holds.push_back(u);
	}
}

void BeltSimNative::Line::holds_erase(i64 u) {
	for (size_t k = 0; k < holds.size(); k++) {
		if (holds[k] == u) {
			holds.erase(holds.begin() + k);
			return;
		}
	}
}

i64 BeltSimNative::Line::find_uid(i64 u) const {
	for (size_t k = 0; k < uid.size(); k++) {
		if (uid[k] == u) {
			return (i64)k;
		}
	}
	return -1;
}

BeltSimNative::BeltSimNative() {}

// ======================================================================== API

void BeltSimNative::set_lane(i64 key, i64 kind, i64 length, i64 step, Vector2i p0, Vector2i pm, Vector2i p1,
		i64 extra, i64 next_key) {
	_marking = "set_lane";
	int i = _lane_index(key);
	if (i >= 0) {
		if (l_kind[i] == kind && l_len[i] == length && l_step[i] == step && l_x0[i] == p0.x && l_y0[i] == p0.y &&
				l_x1[i] == p1.x && l_y1[i] == p1.y && l_extra[i] == extra && l_xnext[i] == next_key) {
			return;
		}
		_marking = vformat("set_lane changed k%d n%d", (int)(l_kind[i] != kind), (int)(l_xnext[i] != next_key));
		_mark_near(i);
		_grid_remove(i);
	} else {
		_marking = "set_lane new";
		i = _new_lane();
		_key_idx[key] = i;
		l_key[i] = key;
		l_seq[i] = _seq;
		_seq += 1;
		l_line[i] = -1;
		l_next[i] = -1;
		l_side[i] = -1;
		l_sp0[i] = -1;
		l_sp1[i] = -1;
		l_feeders[i].clear();
		l_sideins[i].clear();
		auto w = _xnext_wait.find(key);
		if (w != _xnext_wait.end()) {
			std::vector<int> lst = w->second;
			for (int j : lst) {
				_mark(j);
			}
		}
	}
	l_kind[i] = (int32_t)kind;
	l_len[i] = (int32_t)length;
	l_step[i] = (int32_t)step;
	l_extra[i] = (int32_t)extra;
	l_x0[i] = p0.x;
	l_y0[i] = p0.y;
	l_x1[i] = p1.x;
	l_y1[i] = p1.y;
	if (l_xnext[i] != next_key) {
		_wait_remove(i);
		l_xnext[i] = next_key;
		if (next_key != 0) {
			_xnext_wait[next_key].push_back(i);
		}
	}
	l_off[i] = _units_off.count(_unit(key)) ? 1 : 0;
	l_alive[i] = 1;
	_grid_add(i);
	_mark_near(i);
}

// A lane's meta as of at_tick, the tick of its first read in the same update (belt_sim.gd's set_lane_at).
void BeltSimNative::set_lane_at(i64 at_tick, i64 key, i64 kind, i64 length, i64 step, Vector2i p0, Vector2i pm, Vector2i p1,
		i64 extra, i64 next_key, bool out_edge) {
	if (out_edge) {
		set_out_edge(key, true);
	}
	if (at_tick <= tick) {
		set_lane(key, kind, length, step, p0, pm, p1, extra, next_key);
		set_out_edge(key, out_edge);
		return;
	}
	std::vector<i64> v = { kind, length, step, p0.x, p0.y, pm.x, pm.y, p1.x, p1.y, extra, next_key, out_edge ? 1 : 0 };
	_enqueue(at_tick, 3, key, 0, 0, 0, &v);
}

void BeltSimNative::drop_lane(i64 key) {
	_marking = "drop_lane";
	int i = _lane_index(key);
	if (i < 0) {
		return;
	}
	_mark_near(i);
	_dissolve_line(l_line[i]);
	std::vector<Pending> keep;
	for (const Pending &p : _pending) {
		if (p.lane == i) {
			_uid_line.erase(p.uid);
			_gone(p.uid);
		} else {
			keep.push_back(p);
		}
	}
	_pending.swap(keep);
	_grid_remove(i);
	_wait_remove(i);
	_unlink(i);
	_out_keys.erase(key);
	_walls.erase(key);
	_in_holds.erase(i);
	l_alive[i] = 0;
	_key_idx.erase(key);
	_free_lanes.push_back(i);
	if (i < (int)_dirty_f.size() && _dirty_f[i]) {
		_dirty_f[i] = 0;
		erase_value(_dirty_v, i);
	}
}

void BeltSimNative::load_lane(i64 key, i64 at_tick, const PackedInt64Array &items) {
	std::vector<i64> v(items.size());
	const int64_t *p = items.ptr();
	for (int64_t k = 0; k < items.size(); k++) {
		v[k] = p[k];
	}
	_enqueue(at_tick, 0, key, 0, 0, 0, &v);
}

// `sh`: at at_tick the bridge found splitter input `key` as its last read left it (`items`): put back so
// where the simulation has it otherwise, and held until its next read (belt_sim.gd's hold_input).
void BeltSimNative::hold_input(i64 key, i64 at_tick, const PackedInt64Array &items) {
	if (!hold_inputs) {
		return;
	}
	std::vector<i64> v(items.size());
	const int64_t *p = items.ptr();
	for (int64_t k = 0; k < items.size(); k++) {
		v[k] = p[k];
	}
	_enqueue(at_tick, 4, key, 0, 0, 0, &v);
}

void BeltSimNative::check_lane(i64 key, i64 at_tick, i64 count, i64 front, i64 back, i64 front_uid, i64 back_uid) {
	std::vector<i64> ids = { front_uid, back_uid };
	_enqueue(at_tick, 1, key, count, front, back, &ids);
}

void BeltSimNative::set_out_edge(i64 key, bool on) {
	if (on) {
		_out_keys.insert(key);
	} else {
		_out_keys.erase(key);
		_walls.erase(key);
	}
}

void BeltSimNative::set_wall(i64 key, i64 at_tick, i64 uid, i64 pos) {
	if (!_out_keys.count(key)) {
		return;
	}
	std::vector<Wall> &w = _walls[key];
	size_t j = w.size();
	while (j > 0 && w[j - 1].tick > at_tick) {
		j--;
	}
	if (j > 0 && w[j - 1].tick == at_tick) {
		w[j - 1] = Wall{ at_tick, uid, pos };
	} else {
		w.insert(w.begin() + j, Wall{ at_tick, uid, pos });
	}
	int i = _lane_index(key);
	if (i >= 0 && l_line[i] >= 0) {
		Line *L = _lneg(l_line[i]);
		if (L != nullptr) {
			_wake(L);
		}
	}
}

const BeltSimNative::Wall *BeltSimNative::_wall_at(i64 key, i64 t) {
	auto it = _walls.find(key);
	if (it == _walls.end() || it->second.empty()) {
		return nullptr;
	}
	std::vector<Wall> &a = it->second;
	size_t drop = 0;
	while (a.size() - drop > 1 && a[drop + 1].tick <= t) {
		drop++;
	}
	if (drop > 0) {
		a.erase(a.begin(), a.begin() + drop);
	}
	if (a[0].tick >= t || a.size() == 1) {
		return &a[0];
	}
	return &a[1];
}

bool BeltSimNative::_wall_settled(i64 key, i64 t) const {
	auto it = _walls.find(key);
	return it == _walls.end() || it->second.empty() || it->second.back().tick <= t;
}

void BeltSimNative::set_off(i64 unit, bool off, i64 at_tick) {
	_enqueue(at_tick >= 0 ? at_tick : tick, 2, unit, off ? 1 : 0, 0, 0, nullptr);
}

void BeltSimNative::step_to(i64 to_tick) {
	if (tick < 0) {
		tick = to_tick;
		_apply_queue(tick);
		_relink();
		return;
	}
	i64 c0 = now_usec();
	_apply_queue(tick);
	us_queue += now_usec() - c0;
	while (tick < to_tick) {
		c0 = now_usec();
		_step_tick();
		i64 c1 = now_usec();
		us_step += c1 - c0;
		_apply_queue(tick);
		us_queue += now_usec() - c1;
	}
	c0 = now_usec();
	_relink();
	us_relink += now_usec() - c0;
}

void BeltSimNative::skip_to(i64 to_tick) {
	if (tick < 0 || to_tick <= tick) {
		step_to(to_tick);
		return;
	}
	_relink();
	for (auto &up : _lines) {
		Line *L = up.get();
		if (L == nullptr) {
			continue;
		}
		_materialize(L, tick);
		L->mode = 0;
		L->ft = to_tick;
		L->due = -1;
		if (!L->uid.empty()) {
			_rec_set_range(L, 0, (int)L->uid.size(), -1);
		}
	}
	_bucket.clear();
	tick = to_tick;
	_apply_queue(tick);
	for (auto &up : _lines) {
		Line *L = up.get();
		if (L != nullptr && !L->uid.empty()) {
			L->pr_t = tick;
			L->pr_v = 0;
			_set_due(L, tick + 1);
		}
	}
}

i64 BeltSimNative::run_of(i64 key) {
	_relink();
	int i = _lane_index(key);
	if (i < 0 || l_kind[i] != STRAIGHT || l_run[i] < 0) {
		return 0;
	}
	return l_run[i];
}

void BeltSimNative::put_item(i64 key, i64 uid, i64 item, i64 stack, i64 pos) {
	if (_uid_line.count(uid)) {
		take_item(uid, false);
	}
	_relink();
	int i = _lane_index(key);
	if (i < 0) {
		return;
	}
	Line *L = _lneg(l_line[i]);
	if (L == nullptr) {
		return;
	}
	_materialize(L, tick);
	_insert(L, l_base[i] + pos, uid, item, stack, -1);
	_touched(L);
}

void BeltSimNative::take_item(i64 uid, bool gone) {
	auto it = _uid_line.find(uid);
	if (it == _uid_line.end() || it->second < 0) {
		return;
	}
	_relink();
	it = _uid_line.find(uid);
	if (it == _uid_line.end() || it->second < 0) {
		return;
	}
	Line *L = _line(it->second);
	if (L == nullptr) {
		return;
	}
	_materialize(L, tick);
	i64 j = L->find_uid(uid);
	if (j >= 0) {
		_remove_at(L, (int)j);
	}
	_uid_line.erase(uid);
	L->holds_erase(uid);
	if (gone) {
		_gone(uid);
	}
	_touched(L);
}

template <typename P, typename T>
static P to_packed(std::vector<T> &v) {
	P p;
	p.resize((int64_t)v.size());
	if (!v.empty()) {
		auto *w = p.ptrw();
		for (size_t k = 0; k < v.size(); k++) {
			w[k] = v[k];
		}
	}
	v.clear();
	return p;
}

Dictionary BeltSimNative::take_changes() {
	Dictionary d;
	d["uid"] = to_packed<PackedInt64Array>(out_uid);
	d["item"] = to_packed<PackedInt32Array>(out_item);
	d["stack"] = to_packed<PackedInt32Array>(out_stack);
	d["key"] = to_packed<PackedInt64Array>(out_key);
	d["pos"] = to_packed<PackedInt32Array>(out_pos);
	d["tick"] = to_packed<PackedInt64Array>(out_tick);
	d["speed"] = to_packed<PackedInt32Array>(out_speed);
	d["reach"] = to_packed<PackedInt32Array>(out_reach);
	d["run"] = to_packed<PackedInt32Array>(out_run);
	d["gone"] = to_packed<PackedInt64Array>(out_gone);
	d["gone_tick"] = to_packed<PackedInt64Array>(out_gone_tick);
	d["gone_at"] = to_packed<PackedInt32Array>(out_gone_at);
	d["mismatch"] = to_packed<PackedInt64Array>(out_mismatch);
	return d;
}

i64 BeltSimNative::next_of(i64 key) {
	_relink();
	int i = _lane_index(key);
	if (i < 0 || l_next[i] < 0) {
		return 0;
	}
	return l_key[l_next[i]];
}

// belt_sim.gd's lane_fronts.
PackedInt32Array BeltSimNative::lane_fronts(const PackedInt64Array &keys) {
	_relink();
	int nk = (int)keys.size();
	PackedInt32Array out;
	out.resize(nk * 3);
	int32_t *o = out.ptrw();
	std::map<int, std::vector<int>> by_line;  // line id -> q, lane index, ...
	for (int q = 0; q < nk; q++) {
		o[q * 3] = -1;
		o[q * 3 + 1] = 0;
		o[q * 3 + 2] = 0;
		int i = _lane_index(keys[q]);
		if (i < 0 || l_line[i] < 0) {
			continue;
		}
		std::vector<int> &want = by_line[l_line[i]];
		want.push_back(q);
		want.push_back(i);
	}
	std::vector<i64> first, fv, cnt;
	for (auto &e : by_line) {
		Line *L = _lines[e.first].get();
		if (L == nullptr || L->uid.empty()) {
			continue;
		}
		size_t nl = L->lanes.size();
		first.assign(nl, 0);
		fv.assign(nl, 0);
		cnt.assign(nl, 0);
		i64 d = std::max<i64>(tick - L->ft, 0);
		i64 pos = L->f - (L->mode == 1 ? L->s * d : 0);
		size_t li = 0;
		size_t r = 0;
		int n = (int)L->uid.size();
		for (int j = 0; j < n; j++) {
			if (j > 0) {
				pos += L->gap[j];
				if (L->mode == 2 && j == L->ck) {
					pos -= L->s * d;
				}
			}
			while (li + 1 < nl && pos >= L->base[li + 1]) {
				li += 1;
			}
			cnt[li] += 1;
			if (cnt[li] == 1) {
				first[li] = pos - L->base[li];
				i64 v = 0;
				if (L->mode == 1) {
					v = L->s;
				} else if (L->mode == 2) {
					v = j >= L->ck ? L->s : 0;
				} else {
					while (r + 1 < L->rs.size() && L->rs[r + 1] <= j) {
						r += 1;
					}
					v = r < L->rv.size() ? std::max<i64>(L->rv[r], 0) : 0;
				}
				fv[li] = v;
			}
		}
		const std::vector<int> &want = e.second;
		for (size_t w = 0; w + 1 < want.size(); w += 2) {
			int q = want[w];
			auto it = std::find(L->lanes.begin(), L->lanes.end(), want[w + 1]);
			if (it == L->lanes.end()) {
				continue;
			}
			size_t li2 = (size_t)(it - L->lanes.begin());
			if (cnt[li2] == 0) {
				continue;
			}
			o[q * 3] = (int32_t)first[li2];
			o[q * 3 + 1] = (int32_t)fv[li2];
			o[q * 3 + 2] = (int32_t)cnt[li2];
		}
	}
	return out;
}

Array BeltSimNative::items_state() {
	_relink();
	std::vector<i64> u, k;
	std::vector<int32_t> p;
	for (auto &up : _lines) {
		Line *L = up.get();
		if (L == nullptr || L->uid.empty()) {
			continue;
		}
		int n = (int)L->uid.size();
		_materialize(L, tick);
		i64 pos = L->f;
		size_t li = 0;
		for (int i = 0; i < n; i++) {
			if (i > 0) {
				pos += L->gap[i];
			}
			while (li + 1 < L->lanes.size() && pos >= L->base[li + 1]) {
				li += 1;
			}
			u.push_back(L->uid[i]);
			k.push_back(l_key[L->lanes[li]]);
			p.push_back((int32_t)(pos - L->base[li]));
		}
	}
	Array r;
	r.append(to_packed<PackedInt64Array>(u));
	r.append(to_packed<PackedInt64Array>(k));
	r.append(to_packed<PackedInt32Array>(p));
	return r;
}

Dictionary BeltSimNative::stats() {
	i64 lines = 0, asleep = 0, flowing = 0, items = 0;
	for (auto &up : _lines) {
		Line *L = up.get();
		if (L == nullptr) {
			continue;
		}
		lines += 1;
		items += (i64)L->uid.size();
		if (L->due < 0) {
			asleep += 1;
		} else if (L->mode == 1) {
			flowing += 1;
		}
	}
	Dictionary d;
	d["lanes"] = (i64)_key_idx.size();
	d["lines"] = lines;
	d["items"] = items;
	d["asleep"] = asleep;
	d["flowing"] = flowing;
	if (profile) {
		d["q_us_load"] = q_us[0];
		d["q_us_check"] = q_us[1];
		d["q_us_other"] = q_us[2];
		d["q_loads"] = q_loads;
		d["q_loads_same"] = q_loads_same;
		d["q_load_n"] = q_load_n;
		d["step_us_edge"] = step_us[0];
		d["step_us_other"] = step_us[1];
		Array lp;
		for (i64 v : load_us) {
			lp.push_back(v);
		}
		d["load_us"] = lp;
	}
	return d;
}

// ======================================================================== queue

void BeltSimNative::_enqueue(i64 at_tick, int kind, i64 a, i64 b, i64 c, i64 d, const std::vector<i64> *items) {
	QItem q;
	q.tick = at_tick;
	q.seq = _qseq;
	q.kind = kind;
	q.a = a;
	q.b = b;
	q.c = c;
	q.d = d;
	if (items != nullptr) {
		q.items = *items;
	}
	_queue[at_tick].push_back(std::move(q));
	_qseq += 1;
}

void BeltSimNative::_apply_queue(i64 now) {
	if (_queue.empty()) {
		return;
	}
	std::vector<QItem> due;
	while (!_queue.empty() && _queue.begin()->first <= now) {
		std::vector<QItem> &at = _queue.begin()->second;
		for (QItem &q : at) {
			due.push_back(std::move(q));
		}
		_queue.erase(_queue.begin());
	}
	if (due.empty()) {
		return;
	}
	std::stable_sort(due.begin(), due.end(), [](const QItem &x, const QItem &y) { return x.seq < y.seq; });
	for (QItem &q : due) {
		i64 c0 = profile ? now_usec() : 0;
		switch (q.kind) {
			case 0:
				if (profile) {
					q_loads += 1;
					int li = _lane_index(q.a);
					if (li >= 0) {
						_relink();
						if (l_line[li] >= 0 && _line(l_line[li]) != nullptr) {
							q_load_n += (i64)_line(l_line[li])->uid.size();
						}
						if (_lane_is(li, q.items)) {
							q_loads_same += 1;
						}
					}
				}
				_apply_load(q.a, q.items);
				break;
			case 1:
				_apply_check(q.a, q.b, q.c, q.d, q.items.size() > 0 ? q.items[0] : 0, q.items.size() > 1 ? q.items[1] : 0);
				break;
			case 2:
				_apply_off(q.a, q.b != 0);
				break;
			case 3: {
				const std::vector<i64> &m = q.items;
				set_lane(q.a, m[0], m[1], m[2], Vector2i((int32_t)m[3], (int32_t)m[4]), Vector2i((int32_t)m[5], (int32_t)m[6]),
						Vector2i((int32_t)m[7], (int32_t)m[8]), m[9], m[10]);
				set_out_edge(q.a, m[11] != 0);
				break;
			}
			case 4:
				_apply_hold(q.a, q.items);
				break;
		}
		if (profile) {
			q_us[q.kind == 0 ? 0 : (q.kind == 1 ? 1 : 2)] += now_usec() - c0;
		}
	}
}

// (hold_input) Put back as its last read had it, if the simulation has it otherwise; then held.
void BeltSimNative::_apply_hold(i64 key, const std::vector<i64> &items) {
	int i = _lane_index(key);
	if (i < 0 || l_kind[i] != SPLIT_IN) {
		return;
	}
	if (!items.empty() && !_lane_is(i, items)) {
		_apply_load(key, items);
	}
	_in_holds[i] = tick;
}

// Whether lane i holds exactly these items ([uid, item, pos, stack, ...]) at their places now.
bool BeltSimNative::_lane_is(int i, const std::vector<i64> &items) {
	_relink();
	if (l_line[i] < 0) {
		return false;
	}
	Line *L = _line(l_line[i]);
	if (L == nullptr) {
		return false;
	}
	_materialize(L, tick);
	i64 lo = l_base[i];
	i64 hi = lo + l_len[i];
	int nl = (int)items.size() / 4;
	i64 pos = L->f;
	int m = 0;
	for (int j = 0; j < (int)L->uid.size(); j++) {
		if (j > 0) {
			pos += L->gap[j];
		}
		if (pos < lo) {
			continue;
		}
		if (pos >= hi) {
			break;
		}
		if (m >= nl || L->uid[j] != items[m * 4] || pos - lo != items[m * 4 + 2]) {
			return false;
		}
		m += 1;
	}
	return m == nl;
}

// A read replaces the lane's items; the packed items either side of it that the read doesn't cover
// move with them (belt_sim.gd's _apply_load).
void BeltSimNative::_apply_load(i64 key, const std::vector<i64> &items) {
	_relink();
	int i = _lane_index(key);
	if (i < 0) {
		return;
	}
	if (!_in_holds.empty() && _in_holds.erase(i) > 0 && l_line[i] >= 0 && _line(l_line[i]) != nullptr) {
		_wake(_line(l_line[i]));
	}
	Line *L = _lneg(l_line[i]);
	if (L == nullptr) {
		return;
	}
	_materialize(L, tick);
	if (_fresh_tick != tick) {
		_fresh.clear();
		_fresh_tick = tick;
	}
	i64 pc = profile ? now_usec() : 0;
	auto part = [&](int k) {
		if (profile) {
			i64 c = now_usec();
			load_us[k] += c - pc;
			pc = c;
		}
	};
	if (read_skip_same && _lane_is(i, items)) {
		n_same += 1;
		for (size_t k = 0; k + 3 < items.size(); k += 4) {
			_fresh.insert(items[k]);
		}
		if (l_kind[i] == SPLIT_OUT) {
			for (size_t jj = 1; jj < L->uid.size(); jj++) {
				if (L->gap[jj] < GAP) {
					L->holds_add(L->uid[jj]);
				}
			}
		}
		part(0);
		return;
	}
	i64 lo = l_base[i];
	i64 hi = lo + l_len[i];
	int n = (int)L->uid.size();
	i64 total = read_bound ? L->base.back() + l_len[L->lanes.back()] : -1;
	std::vector<i64> P(n);
	std::vector<int32_t> RV(n);
	// (idx: the line's index of each of the read's items that it has; only those are ever looked up.)
	std::unordered_map<i64, int> idx;
	std::unordered_set<i64> in_read;
	for (size_t k = 0; k + 3 < items.size(); k += 4) {
		in_read.insert(items[k]);
	}
	i64 pos = L->f;
	for (int j = 0; j < n; j++) {
		if (j > 0) {
			pos += L->gap[j];
		}
		P[j] = pos;
		if (in_read.count(L->uid[j])) {
			idx[L->uid[j]] = j;
		}
	}
	for (size_t r = 0; r < L->rs.size(); r++) {
		int en = r + 1 < L->rs.size() ? L->rs[r + 1] : n;
		for (int j = L->rs[r]; j < en; j++) {
			RV[j] = L->rv[r];
		}
	}
	int nl = (int)(items.size() / 4);
	part(0);
	std::vector<int> between;
	if (nl > 0 && n > 1) {
		between = _shift_packed(L, P, RV, idx, items, lo, hi);
	}
	if (nl > 0 && n > 0) {
		std::vector<int> pb = _push_back(L, P, RV, idx, items, lo, hi);
		between.insert(between.end(), pb.begin(), pb.end());
	}
	part(1);
	std::vector<uint8_t> gone_between(n, 0);
	for (int j : between) {
		gone_between[j] = 1;
	}
	if (read_conserve && n > 0) {
		_rescue(L, P, RV, idx, items, lo, hi, gone_between);
	}
	std::vector<Carried> past;  // (read_bound) carried back (_carry_back)
	if (total >= 0) {
		for (int j = 0; j < n; j++) {
			if (P[j] > total && !gone_between[j]) {
				past.push_back({ L->uid[j], L->itm[j], L->stk[j], P[j] - total });
			}
		}
	}
	std::unordered_set<i64> loaded;
	for (int k = 0; k < nl; k++) {
		loaded.insert(items[k * 4]);
	}
	// (read_forward) The items _rescue put out past the line's front: carried on (_carry_forward).
	std::vector<Carried> fwd;
	std::vector<uint8_t> fwd_j(n, 0);
	if (read_forward && read_conserve && lo == 0 && nl > 0) {
		for (int j = 0; j < n; j++) {
			if (P[j] < 0 && !gone_between[j] && !loaded.count(L->uid[j])) {
				fwd.push_back({ L->uid[j], L->itm[j], L->stk[j], -P[j] });
				fwd_j[j] = 1;
			}
		}
	}
	std::vector<i64> drop;
	std::vector<int> keep;
	for (int j = 0; j < n; j++) {
		i64 q = P[j];
		if (fwd_j[j]) {
			continue;  // (in `fwd`)
		}
		if (total >= 0 && q > total && !gone_between[j]) {
			continue;  // (in `past`, or read)
		}
		if ((q < hi && (q >= lo || (lo == 0 && q < 0))) || gone_between[j]) {
			drop.push_back(L->uid[j]);
		} else if (!loaded.count(L->uid[j])) {
			keep.push_back(j);
		}
	}
	std::vector<i64> U, Q;
	std::vector<int32_t> I, S, V;
	for (int j : keep) {
		U.push_back(L->uid[j]);
		I.push_back(L->itm[j]);
		S.push_back(L->stk[j]);
		Q.push_back(P[j]);
		V.push_back(RV[j]);
	}
	part(2);
	// (The line's items not kept leave the uid -> line map; the kept ones are already mapped to this line.)
	{
		std::vector<uint8_t> kept_f(n, 0);
		for (int j : keep) {
			kept_f[j] = 1;
		}
		for (int j = 0; j < n; j++) {
			if (!kept_f[j]) {
				_uid_line.erase(L->uid[j]);
			}
		}
	}
	part(3);
	if (l_kind[i] == SPLIT_OUT) {
		_turns_from_read(i, items);
	}
	for (int k = 0; k < nl; k++) {
		i64 u = items[k * 4];
		auto it = _uid_line.find(u);
		int other = it == _uid_line.end() ? -1 : it->second;
		if (other >= 0 && other != L->id) {
			Line *O = _line(other);
			if (O != nullptr) {
				_materialize(O, tick);
				i64 m = O->find_uid(u);
				if (m >= 0) {
					_remove_at(O, (int)m);
				}
				_uid_line.erase(u);
				_touched(O);
			}
		}
		U.push_back(u);
		I.push_back((int32_t)items[k * 4 + 1]);
		S.push_back((int32_t)items[k * 4 + 3]);
		Q.push_back(lo + items[k * 4 + 2]);
		V.push_back(-1);
		_uid_line[u] = L->id;
		_fresh.insert(u);
	}
	part(4);
	std::vector<i64> crowded = _space_out(U, I, S, Q, V, total, past);
	part(5);
	_rebuild(L, U, I, S, Q, V);
	part(6);
	for (i64 u : crowded) {
		_uid_line.erase(u);
		_gone(u);
		L->holds_erase(u);
	}
	for (i64 u : drop) {
		if (!loaded.count(u)) {
			_gone(u);
			L->holds_erase(u);
		}
	}
	if (!past.empty()) {
		std::vector<Carried> carry;
		for (const Carried &e : past) {
			L->holds_erase(e.uid);
			if (!loaded.count(e.uid)) {
				carry.push_back(e);
			}
		}
		std::sort(carry.begin(), carry.end(), [](const Carried &x, const Carried &y) {
			return x.over < y.over || (x.over == y.over && x.uid < y.uid);
		});
		_carry_back(L->lanes.back(), carry, L->id);
	}
	if (!fwd.empty()) {
		for (const Carried &e : fwd) {
			L->holds_erase(e.uid);
		}
		// (The furthest past the exit first: it was in front.)
		std::sort(fwd.begin(), fwd.end(), [](const Carried &x, const Carried &y) {
			return x.over > y.over || (x.over == y.over && x.uid < y.uid);
		});
		_carry_forward(L->lanes[0], fwd);
	}
	if (l_kind[i] == SPLIT_OUT) {
		for (size_t jj = 1; jj < L->uid.size(); jj++) {
			if (L->gap[jj] < GAP) {
				L->holds_add(L->uid[jj]);
			}
		}
	}
	_touched(L);
	part(7);
}

// (_apply_load, read_forward) Items a read of lane l0, its line's first, left past its exit (the furthest
// first): in the game they went on. Across a splitter into the output its turn says where there is room,
// else the other; into a plain next lane behind its hindmost item. Else they go (belt_sim.gd's
// _carry_forward).
void BeltSimNative::_carry_forward(int l0, std::vector<Carried> ex) {
	int nx = l_next[l0];
	Splitter *sp = nullptr;
	if (l_kind[l0] == SPLIT_IN) {
		auto it = _splitters.find(_unit(l_key[l0]));
		if (it != _splitters.end()) {
			sp = &it->second;
		}
	}
	for (const Carried &e : ex) {
		bool ok = false;
		if (sp != nullptr) {
			ok = _forward_split(sp, l0, e.uid, e.item, e.stack, e.over);
		} else if (l_side[l0] < 0 && nx >= 0 && l_line[nx] >= 0 && _lneg(l_line[nx]) != nullptr) {
			Line *X = _lneg(l_line[nx]);
			_materialize(X, tick);
			i64 en = (i64)l_base[nx] + l_len[nx];
			i64 at = en - e.over;
			if (!X->uid.empty()) {
				at = maxi(at, X->f + X->span + GAP);
			}
			if (at < en) {
				int jj = _insert(X, at, e.uid, e.item, e.stack, -1);
				if (jj == (int)X->uid.size() - 1) {
					X->bp = at;
					X->bp_tick = tick;
				}
				_wake(X);
				_promise(X, tick);
				ok = true;
			}
		}
		if (ok) {
			n_forward += 1;
		} else {
			_uid_line.erase(e.uid);
			_gone(e.uid);
			n_forward_gone += 1;
		}
	}
}

// (_carry_forward) An item `over` past splitter input l0's exit goes into an output as _split_put would
// put it, held by nothing: the game made the crossing (belt_sim.gd's _forward_split).
bool BeltSimNative::_forward_split(Splitter *sp, int l0, i64 uid, i64 item, i64 stk, i64 over) {
	int half = l_sp0[l0];
	int side = l_sp1[l0];
	int tries[2];
	int nt = 0;
	if (sp->filter != 0) {
		int fh = sp->out_prio >= 0 ? sp->out_prio : 0;
		tries[nt++] = sp->outs[(item == sp->filter ? fh : 1 - fh) * 2 + side];
	} else if (sp->out_prio >= 0) {
		tries[nt++] = sp->outs[sp->out_prio * 2 + side];
		tries[nt++] = sp->outs[(1 - sp->out_prio) * 2 + side];
	} else {
		int tt = (int)maxi(sp->out_turn[side], 0);
		tries[nt++] = sp->outs[tt * 2 + side];
		tries[nt++] = sp->outs[(1 - tt) * 2 + side];
	}
	for (int ti = 0; ti < nt; ti++) {
		int o = tries[ti];
		if (o < 0 || l_line[o] < 0) {
			continue;
		}
		Line *X = _lneg(l_line[o]);
		if (X == nullptr) {
			continue;
		}
		_materialize(X, tick);
		i64 olen = l_len[o];
		i64 at = maxi(olen - SPLIT_BUFFER - over, (i64)0);
		if (!X->uid.empty()) {
			at = maxi(at, X->f + X->span - l_base[o] + GAP);
		}
		if (at >= olen) {
			continue;
		}
		int jj = _insert(X, l_base[o] + at, uid, item, stk, -1);
		if (jj == (int)X->uid.size() - 1) {
			X->bp = l_base[o] + at;
			X->bp_tick = tick;
		}
		sp->crossed += 1;
		_side_x[sp->unit * 2 + side] = tick;
		sp->out_turn[side] = 1 - (o == sp->outs[side] ? 0 : 1);
		sp->in_turn[side] = 1 - half;
		_wake(X);
		_promise(X, tick);
		return true;
	}
	return false;
}

// (_apply_load, read_conserve) The items the line has in the read lane that the read hasn't: those behind
// the read's items in the line's order (all, when none of them is in the line) go out of the lane behind
// it, those ahead of them out of it in front, in their order (belt_sim.gd's _rescue).
void BeltSimNative::_rescue(Line *L, std::vector<i64> &P, std::vector<int32_t> &RV, const std::unordered_map<i64, int> &idx,
		const std::vector<i64> &items, i64 lo, i64 hi, const std::vector<uint8_t> &skip) {
	int nl = (int)(items.size() / 4);
	int n = (int)L->uid.size();
	int rmin = n;
	int rmax = -1;
	std::unordered_set<i64> loaded;
	for (int k = 0; k < nl; k++) {
		loaded.insert(items[k * 4]);
		auto it = idx.find(items[k * 4]);
		if (it != idx.end()) {
			rmin = std::min(rmin, it->second);
			rmax = std::max(rmax, it->second);
		}
	}
	std::vector<int> ahead;
	i64 r = 0;
	for (int j = 0; j < n; j++) {
		i64 q = P[j];
		if (skip[j] || loaded.count(L->uid[j]) || !(q < hi && (q >= lo || (lo == 0 && q < 0)))) {
			continue;
		}
		if (rmax < 0 || j > rmax) {
			P[j] = std::max(q, hi + r);
			RV[j] = -1;
			r += 1;
		} else if (j < rmin && nl > 0) {
			ahead.push_back(j);
		}
	}
	if (ahead.empty()) {
		return;
	}
	i64 front = lo + items[2];
	i64 m = (i64)ahead.size();
	for (i64 x = 0; x < m; x++) {
		int j = ahead[x];
		i64 t = std::min(front - GAP * (m - x), lo - 1 - GAP * (m - 1 - x));
		if (t < P[j]) {
			P[j] = t;
			RV[j] = -1;
		}
	}
}

// When none of a read's items are on the lane's line and some are on another (the simulation ran them
// on ahead), the items the line has in the lane are pushed back behind the read's last item and out of
// the lane, with the packed run behind them, rather than dropped (belt_sim.gd's _push_back).
std::vector<int> BeltSimNative::_push_back(Line *L, std::vector<i64> &P, std::vector<int32_t> &RV,
		const std::unordered_map<i64, int> &idx, const std::vector<i64> &items, i64 lo, i64 hi) {
	int nl = (int)(items.size() / 4);
	int pulled = 0;
	i64 back = lo;
	for (int k = 0; k < nl; k++) {
		i64 u = items[k * 4];
		if (idx.count(u)) {
			return {};
		}
		auto it = _uid_line.find(u);
		if (it != _uid_line.end() && it->second >= 0 && it->second != L->id) {
			pulled += 1;
		}
		back = std::max(back, lo + items[k * 4 + 2]);
	}
	std::vector<int> moved;
	if (pulled == 0) {
		return moved;
	}
	i64 prev = back;
	bool started = false;
	int n = (int)L->uid.size();
	for (int j = 0; j < n; j++) {
		i64 q = P[j];
		bool inside = q < hi && (q >= lo || (lo == 0 && q < 0));
		if (!started) {
			if (!inside) {
				continue;
			}
			started = true;
		}
		if (_fresh.count(L->uid[j])) {
			std::vector<int> drop;
			for (int m = (int)moved.size() - 1; m >= 0; m--) {
				if (P[moved[m]] + GAP <= P[j]) {
					break;
				}
				drop.push_back(moved[m]);
			}
			return drop;
		}
		i64 np = std::max(q, prev + GAP);
		if (inside) {
			np = std::max(np, hi);
		}
		if (np == q) {
			break;
		}
		P[j] = np;
		RV[j] = -1;
		prev = np;
		moved.push_back(j);
		n_shifted += 1;
	}
	return {};
}

// A read of a splitter's output with an item the simulation still had on one of that splitter's inputs
// sets the side's turns as that crossing did (belt_sim.gd's _turns_from_read).
void BeltSimNative::_turns_from_read(int o, const std::vector<i64> &items) {
	auto it = _splitters.find(_unit(l_key[o]));
	if (it == _splitters.end()) {
		return;
	}
	Splitter &sp = it->second;
	int oi = -1;
	for (int k = 0; k < 4; k++) {
		if (sp.outs[k] == o) {
			oi = k;
			break;
		}
	}
	if (oi < 0) {
		return;
	}
	i64 best = -1;
	int best_half = -1;
	std::vector<int> other;
	int x0 = sp.outs[(1 - oi / 2) * 2 + oi % 2];
	if (read_bound) {
		for (int n = 0; n < TURN_FOLLOW; n++) {
			if (x0 < 0 || std::find(other.begin(), other.end(), x0) != other.end()) {
				break;
			}
			other.push_back(x0);
			x0 = l_next[x0];
		}
	}
	int nl = (int)(items.size() / 4);
	for (int k = 0; k < nl; k++) {
		i64 u = items[k * 4];
		auto ul = _uid_line.find(u);
		if (ul == _uid_line.end() || ul->second < 0 || ul->second == l_line[o]) {
			continue;
		}
		Line *O = _line(ul->second);
		if (O == nullptr) {
			continue;
		}
		_materialize(O, tick);
		i64 m = O->find_uid(u);
		if (m < 0) {
			continue;
		}
		i64 q = O->f;
		for (i64 x = 1; x <= m; x++) {
			q += O->gap[x];
		}
		int lane = O->lanes[_lane_at(O, q)];
		int half = -1;
		if (l_kind[lane] == SPLIT_IN && _unit(l_key[lane]) == sp.unit) {
			half = l_sp0[lane];
		} else if (std::find(other.begin(), other.end(), lane) != other.end()) {
			half = 2;  // (crossed into the other output: the input not known)
		} else {
			continue;
		}
		i64 p = items[k * 4 + 2];
		if (p > best) {
			best = p;
			best_half = half;
		}
	}
	if (best_half < 0) {
		return;
	}
	if (best_half < 2) {
		sp.in_turn[oi % 2] = 1 - best_half;
	}
	sp.out_turn[oi % 2] = 1 - oi / 2;
}

// No two items closer than a gap after a read (belt_sim.gd's _space_out): items a read set this tick
// stay; any other item closer than a gap behind the one in front goes back to a gap behind it, unless
// that brings it within a gap of a fixed item behind: then it goes. Returns the items that go.
std::vector<i64> BeltSimNative::_space_out(std::vector<i64> &U, std::vector<int32_t> &I, std::vector<int32_t> &S,
		std::vector<i64> &Q, std::vector<int32_t> &V, i64 bound, std::vector<Carried> &past) {
	int n = (int)U.size();
	std::vector<i64> out;
	if (n < 2) {
		return out;
	}
	std::vector<int> order(n);
	for (int k = 0; k < n; k++) {
		order[k] = k;
	}
	std::sort(order.begin(), order.end(), [&](int x, int y) { return Q[x] < Q[y] || (Q[x] == Q[y] && U[x] < U[y]); });
	std::vector<i64> nf(n);
	i64 f = i64(1) << 30;
	for (int r = n - 1; r >= 0; r--) {
		nf[r] = f;
		if (_fresh.count(U[order[r]])) {
			f = Q[order[r]];
		}
	}
	std::vector<uint8_t> gone(n, 0);
	bool any = false;
	bool have = false;
	i64 prev = 0;
	for (int r = 0; r < n; r++) {
		int o = order[r];
		if (_fresh.count(U[o])) {
			prev = Q[o];
			have = true;
			continue;
		}
		if (have && Q[o] < prev + GAP) {
			i64 np = prev + GAP;
			if (np + GAP > nf[r]) {
				gone[o] = 1;
				any = true;
				out.push_back(U[o]);
				continue;
			}
			if (bound >= 0 && np > bound) {
				gone[o] = 1;  // (carried back: _carry_back)
				any = true;
				past.push_back({ U[o], I[o], S[o], np - bound });
				continue;
			}
			Q[o] = np;
			V[o] = -1;
		}
		prev = Q[o];
		have = true;
	}
	if (!any) {
		return out;
	}
	int w = 0;
	for (int k = 0; k < n; k++) {
		if (gone[k]) {
			continue;
		}
		U[w] = U[k];
		I[w] = I[k];
		S[w] = S[k];
		Q[w] = Q[k];
		V[w] = V[k];
		w++;
	}
	U.resize(w);
	I.resize(w);
	S.resize(w);
	Q.resize(w);
	V.resize(w);
	return out;
}

// Items a read leaves past the back end of lane z's line go back onto the feeder's line in front of its
// own items (which go back to a gap behind them as far as needed), on up to CARRY_HOPS lines; past a
// splitter's output onto the input on that side with more room, its turns put back; else they go
// (belt_sim.gd's _carry_back).
void BeltSimNative::_carry_back(int z, std::vector<Carried> ex, int origin) {
	std::unordered_set<int> seen = { origin };
	int hops = 0;
	while (!ex.empty()) {
		int f = -1;
		i64 add = 0;
		bool split = false;
		if (hops < (read_conserve ? CARRY_HOPS_CONSERVE : CARRY_HOPS)) {
			const std::vector<int> &fe = l_feeders[z];
			if (fe.size() == 1) {
				f = fe[0];
			} else if (fe.empty() && l_kind[z] == SPLIT_OUT) {
				f = _carry_input(z);
				add = SPLIT_BUFFER;
				split = true;
			}
		}
		Line *F = nullptr;
		if (f >= 0 && l_line[f] >= 0) {
			F = _line(l_line[f]);
			if (F == nullptr || seen.count(F->id) || F->lanes[0] != f || F->off) {
				F = nullptr;
			}
		}
		if (F == nullptr) {
			for (const Carried &e : ex) {
				_uid_line.erase(e.uid);
				_gone(e.uid);
				n_past_back += 1;
			}
			return;
		}
		if (split) {
			auto it = _splitters.find(_unit(l_key[z]));
			if (it != _splitters.end()) {
				Splitter &sp = it->second;
				int oi = -1;
				for (int k = 0; k < 4; k++) {
					if (sp.outs[k] == z) {
						oi = k;
						break;
					}
				}
				if (oi >= 0 && sp.out_prio < 0 && sp.filter == 0) {
					sp.out_turn[oi % 2] = oi / 2;
				}
				if (oi >= 0 && sp.in_prio < 0) {
					sp.in_turn[oi % 2] = l_sp0[f];
				}
			}
		}
		seen.insert(F->id);
		hops += 1;
		_materialize(F, tick);
		i64 ftotal = F->base.back() + l_len[F->lanes.back()];
		std::vector<i64> U, Q;
		std::vector<int32_t> I, S, V;
		std::vector<uint8_t> fresh;
		for (const Carried &e : ex) {
			U.push_back(e.uid);
			I.push_back(e.item);
			S.push_back(e.stack);
			Q.push_back(e.over + add);
			V.push_back(-1);
			fresh.push_back(0);
		}
		i64 pos = F->f;
		size_t r = 0;
		for (size_t j = 0; j < F->uid.size(); j++) {
			if (j > 0) {
				pos += F->gap[j];
			}
			while (r + 1 < F->rs.size() && F->rs[r + 1] <= (int32_t)j) {
				r += 1;
			}
			U.push_back(F->uid[j]);
			I.push_back(F->itm[j]);
			S.push_back(F->stk[j]);
			Q.push_back(pos);
			V.push_back(F->rv[r]);
			fresh.push_back(_fresh.count(F->uid[j]) ? 1 : 0);
		}
		int m = (int)U.size();
		std::vector<i64> nf(m);
		i64 fpos = i64(1) << 30;
		for (int x = m - 1; x >= 0; x--) {
			nf[x] = fpos;
			if (fresh[x]) {
				fpos = Q[x];
			}
		}
		std::vector<uint8_t> keep(m, 1);
		bool have = false;
		i64 prev = 0;
		for (int x = 0; x < m; x++) {
			if (!fresh[x]) {
				i64 q = Q[x];
				if (have && q < prev + GAP) {
					q = prev + GAP;
				}
				if (q + GAP > nf[x]) {
					keep[x] = 0;
					continue;
				}
				if (q != Q[x]) {
					Q[x] = q;
					V[x] = -1;
				}
			}
			prev = Q[x];
			have = true;
		}
		std::vector<Carried> nex;
		std::vector<i64> KU, KQ;
		std::vector<int32_t> KI, KS, KV;
		for (int x = 0; x < m; x++) {
			if (!keep[x]) {
				_uid_line.erase(U[x]);
				_gone(U[x]);
				F->holds_erase(U[x]);
				n_past_back += 1;
			} else if (Q[x] > ftotal) {
				_uid_line.erase(U[x]);
				F->holds_erase(U[x]);
				nex.push_back({ U[x], I[x], S[x], Q[x] - ftotal });
			} else {
				KU.push_back(U[x]);
				KI.push_back(I[x]);
				KS.push_back(S[x]);
				KQ.push_back(Q[x]);
				KV.push_back(V[x]);
				_uid_line[U[x]] = F->id;
			}
		}
		_rebuild(F, KU, KI, KS, KQ, KV);
		_touched(F);
		n_carried += (i64)ex.size();
		ex.swap(nex);
		z = F->lanes.back();
	}
}

// (_carry_back) Of the inputs on a splitter output's side, the one with more room in front.
int BeltSimNative::_carry_input(int o) {
	std::vector<int> ins;
	_split_inputs_of(o, ins);
	int best = -1;
	i64 room = -1;
	bool fed = false;
	if (read_conserve) {
		for (int x : ins) {
			if (!l_feeders[x].empty() || !l_sideins[x].empty()) {
				fed = true;
			}
		}
	}
	for (int x : ins) {
		if (l_line[x] < 0) {
			continue;
		}
		if (fed && l_feeders[x].empty() && l_sideins[x].empty()) {
			continue;  // (an input nothing feeds: none of the game's items came from it)
		}
		Line *X = _line(l_line[x]);
		if (X == nullptr) {
			continue;
		}
		_materialize(X, tick);
		i64 fr = X->uid.empty() ? (i64(1) << 30) : X->f;
		if (fr > room) {
			room = fr;
			best = x;
		}
	}
	return best;
}

i64 BeltSimNative::_stays_at(const std::vector<i64> &P, const std::unordered_map<int, i64> &gp, int j, i64 lo, i64 hi) const {
	auto it = gp.find(j);
	if (it != gp.end()) {
		return it->second;
	}
	if (P[j] < hi && (P[j] >= lo || (lo == 0 && P[j] < 0))) {
		return FAR;
	}
	return P[j];
}

std::vector<int> BeltSimNative::_shift_packed(Line *L, std::vector<i64> &P, std::vector<int32_t> &RV,
		const std::unordered_map<i64, int> &idx, const std::vector<i64> &items, i64 lo, i64 hi) {
	int nl = (int)(items.size() / 4);
	int n = (int)L->uid.size();
	std::unordered_map<int, i64> dj, gp;
	std::vector<std::pair<i64, int>> cnt;  // (in first-seen order, as belt_sim.gd's Dictionary)
	for (int k = 0; k < nl; k++) {
		auto it = idx.find(items[k * 4]);
		if (it == idx.end()) {
			continue;
		}
		int j = it->second;
		gp[j] = lo + items[k * 4 + 2];
		if (_fresh.count(items[k * 4])) {
			continue;
		}
		i64 d = lo + items[k * 4 + 2] - P[j];
		dj[j] = d;
		bool found = false;
		for (auto &c : cnt) {
			if (c.first == d) {
				c.second += 1;
				found = true;
				break;
			}
		}
		if (!found) {
			cnt.push_back({ d, 1 });
		}
	}
	i64 d = 0;
	int best = 0;
	for (auto &c : cnt) {
		if (c.second > best || (c.second == best && std::llabs(c.first) < std::llabs(d))) {
			best = c.second;
			d = c.first;
		}
	}
	std::vector<int> between;
	if (best == 0) {
		return between;
	}
	int a = n;
	int b = -1;
	for (auto &e : dj) {
		if (e.second == d) {
			a = std::min(a, e.first);
			b = std::max(b, e.first);
		}
	}
	for (int j = a + 1; j < b; j++) {
		if (!gp.count(j)) {
			between.push_back(j);
		}
	}
	if (d == 0) {
		return between;
	}
	auto is_d = [&](int j) {
		auto it = dj.find(j);
		return it != dj.end() && it->second == d;
	};
	// In front.
	std::vector<int> front;
	i64 prev = P[a];
	int j = a - 1;
	while (j >= 0) {
		if (is_d(j)) {
			prev = P[j];
			j -= 1;
			continue;
		}
		if (gp.count(j) || _fresh.count(L->uid[j])) {
			break;
		}
		i64 np = P[j] + d;
		if (np < hi && (np >= lo || lo == 0)) {
			// The game hasn't it where the move puts it: if it lies outside the lane it goes too (shift_keep:
			// the run ends at it, and it stays).
			if (_stays_at(P, gp, j, lo, hi) == FAR || shift_keep) {
				break;
			}
			between.push_back(j);
			j -= 1;
			continue;
		}
		if (prev - P[j] <= GAP + PACK_SLACK || (d < 0 && prev + d - P[j] < GAP)) {
			front.push_back(j);
			prev = P[j];
			j -= 1;
		} else {
			break;
		}
	}
	i64 df = d;
	if (!front.empty() && j >= 0) {
		i64 sp = _stays_at(P, gp, j, lo, hi);
		if (sp != FAR && d < 0) {
			df = std::min(std::max(d, sp + GAP - P[front.back()]), (i64)0);
		}
	}
	if (df != 0) {
		for (int f : front) {
			P[f] += df;
			RV[f] = -1;
		}
	}
	// Behind.
	std::vector<int> back;
	prev = P[b];
	j = b + 1;
	while (j < n) {
		if (is_d(j)) {
			prev = P[j];
			j += 1;
			continue;
		}
		if (gp.count(j) || _fresh.count(L->uid[j])) {
			break;
		}
		i64 np = P[j] + d;
		if (np < hi && (np >= lo || lo == 0)) {
			if (_stays_at(P, gp, j, lo, hi) == FAR || shift_keep) {
				break;
			}
			between.push_back(j);
			j += 1;
			continue;
		}
		if (P[j] - prev <= GAP + PACK_SLACK || (d > 0 && P[j] - prev - d < GAP)) {
			back.push_back(j);
			prev = P[j];
			j += 1;
		} else {
			break;
		}
	}
	i64 db = d;
	if (!back.empty() && j < n) {
		i64 sp = _stays_at(P, gp, j, lo, hi);
		if (sp != FAR && d > 0) {
			db = std::max(std::min(d, sp - GAP - P[back.back()]), (i64)0);
		}
	}
	if (db != 0) {
		for (int f : back) {
			P[f] += db;
			RV[f] = -1;
		}
	}
	n_shifted += (i64)(front.size() + back.size());
	return between;
}

// A line's items set anew from parallel arrays (any order), records kept per item.
void BeltSimNative::_rebuild(Line *L, std::vector<i64> &U, std::vector<int32_t> &I, std::vector<int32_t> &S,
		std::vector<i64> &Q, std::vector<int32_t> &V) {
	int n = (int)U.size();
	std::vector<int> order(n);
	for (int k = 0; k < n; k++) {
		order[k] = k;
	}
	std::sort(order.begin(), order.end(), [&](int x, int y) { return Q[x] < Q[y] || (Q[x] == Q[y] && U[x] < U[y]); });
	L->uid.clear();
	L->itm.clear();
	L->stk.clear();
	L->gap.clear();
	L->rs.clear();
	L->rv.clear();
	L->span = 0;
	L->lp = 1;
	L->lp2_from = i64(1) << 30;
	if (L->mode == 2) {
		L->mode = 0;
	}
	i64 last = 0;
	for (int k = 0; k < n; k++) {
		int o = order[k];
		L->uid.push_back(U[o]);
		L->itm.push_back(I[o]);
		L->stk.push_back(S[o]);
		if (k == 0) {
			L->f = Q[o];
			L->gap.push_back(0);
		} else {
			L->gap.push_back((int32_t)(Q[o] - last));
			L->span += Q[o] - last;
		}
		last = Q[o];
		if (L->rv.empty() || L->rv.back() != V[o]) {
			L->rs.push_back(k);
			L->rv.push_back(V[o]);
		}
	}
}

void BeltSimNative::_apply_check(i64 key, i64 count, i64 front, i64 back, i64 front_uid, i64 back_uid) {
	_relink();
	int i = _lane_index(key);
	if (i < 0) {
		return;
	}
	Line *L = _lneg(l_line[i]);
	if (L == nullptr) {
		return;
	}
	i64 lo = l_base[i];
	i64 hi = lo + l_len[i];
	_materialize(L, tick);
	i64 pos = L->f;
	i64 c = 0, f = -1, b = -1, fu = 0, bu = 0;
	for (size_t j = 0; j < L->uid.size(); j++) {
		if (j > 0) {
			pos += L->gap[j];
		}
		if (pos >= hi) {
			break;
		}
		if (pos >= lo || (lo == 0 && pos < 0)) {
			if (c == 0) {
				f = pos - lo;
				fu = L->uid[j];
			}
			b = pos - lo;
			bu = L->uid[j];
			c += 1;
		}
	}
	// (A packed lane a whole gap off has the same count, front and back: its items' ids tell.)
	if (c != count || f != front || b != back || (front_uid != 0 && (fu != front_uid || bu != back_uid))) {
		out_mismatch.push_back(key);
	}
}

void BeltSimNative::_apply_off(i64 unit, bool off) {
	_marking = "set_off";
	if (off) {
		_units_off.insert(unit);
	} else {
		_units_off.erase(unit);
	}
	for (int line = 1; line < 9; line++) {
		int i = _lane_index(unit * 8 + line);
		if (i >= 0 && (l_off[i] == 1) != off) {
			l_off[i] = off ? 1 : 0;
			// (No link changes: only the lines round it are made again.)
			_relines.add(i);
			_dirty_any = true;
		}
	}
}

// ======================================================================== lanes and topology

int BeltSimNative::_lane_index(i64 key) const {
	auto it = _key_idx.find(key);
	return it == _key_idx.end() ? -1 : it->second;
}

int BeltSimNative::_new_lane() {
	if (!_free_lanes.empty()) {
		int i = _free_lanes.back();
		_free_lanes.pop_back();
		l_xnext[i] = 0;
		l_off[i] = 0;
		l_run[i] = -1;
		l_base[i] = 0;
		return i;
	}
	int i = (int)l_key.size();
	l_key.push_back(0);
	l_seq.push_back(0);
	l_xnext.push_back(0);
	l_kind.push_back(0);
	l_len.push_back(0);
	l_step.push_back(0);
	l_extra.push_back(0);
	l_x0.push_back(0);
	l_y0.push_back(0);
	l_x1.push_back(0);
	l_y1.push_back(0);
	l_next.push_back(0);
	l_side.push_back(0);
	l_side_at.push_back(0);
	l_sp0.push_back(0);
	l_sp1.push_back(0);
	l_line.push_back(0);
	l_base.push_back(0);
	l_run.push_back(-1);
	l_off.push_back(0);
	l_alive.push_back(0);
	l_feeders.emplace_back();
	l_sideins.emplace_back();
	_dirty_f.push_back(0);
	return i;
}

i64 BeltSimNative::_floordiv(i64 a, i64 b) {
	i64 q = a / b;
	if ((a % b != 0) && ((a < 0) != (b < 0))) {
		q -= 1;
	}
	return q;
}

void BeltSimNative::_grid_add(int i) {
	_entry_grid[_cell(_floordiv(l_x1[i], 32), _floordiv(l_y1[i], 32))].push_back(i);
	_exit_grid[_cell(_floordiv(l_x0[i], 1024), _floordiv(l_y0[i], 1024))].push_back(i);
	if (((l_kind[i] == STRAIGHT || l_kind[i] == CURVE) && l_len[i] == 256) || l_kind[i] == UG_VISIBLE) {
		_side_grid[_cell(_floordiv(l_x1[i], 512), _floordiv(l_y1[i], 512))].push_back(i);
	}
}

static void grid_take(std::unordered_map<i64, std::vector<int>> &grid, i64 c, int i) {
	auto it = grid.find(c);
	if (it == grid.end()) {
		return;
	}
	auto &arr = it->second;
	auto f = std::find(arr.begin(), arr.end(), i);
	if (f != arr.end()) {
		arr.erase(f);
		if (arr.empty()) {
			grid.erase(it);
		}
	}
}

void BeltSimNative::_grid_remove(int i) {
	grid_take(_entry_grid, _cell(_floordiv(l_x1[i], 32), _floordiv(l_y1[i], 32)), i);
	grid_take(_exit_grid, _cell(_floordiv(l_x0[i], 1024), _floordiv(l_y0[i], 1024)), i);
	grid_take(_side_grid, _cell(_floordiv(l_x1[i], 512), _floordiv(l_y1[i], 512)), i);
}

void BeltSimNative::_wait_remove(int i) {
	i64 k = l_xnext[i];
	if (k == 0) {
		return;
	}
	auto it = _xnext_wait.find(k);
	if (it == _xnext_wait.end()) {
		return;
	}
	erase_value(it->second, i);
	if (it->second.empty()) {
		_xnext_wait.erase(it);
	}
}

void BeltSimNative::_mark(int i) {
	if (!_dirty_f[i]) {
		why_mark[_marking] = (i64)why_mark.get(_marking, 0) + 1;
		_dirty_f[i] = 1;
		_dirty_v.push_back(i);
	}
	_dirty_any = true;
}

void BeltSimNative::_mark_near(int i) {
	_mark(i);
	i64 pts[2][2] = { { l_x0[i], l_y0[i] }, { l_x1[i], l_y1[i] } };
	for (auto &p : pts) {
		i64 cx = _floordiv(p[0], 1024);
		i64 cy = _floordiv(p[1], 1024);
		for (int dx = -1; dx < 2; dx++) {
			for (int dy = -1; dy < 2; dy++) {
				auto it = _exit_grid.find(_cell(cx + dx, cy + dy));
				if (it == _exit_grid.end()) {
					continue;
				}
				for (int j : it->second) {
					if (absi(l_x0[j] - p[0]) <= 700 && absi(l_y0[j] - p[1]) <= 700) {
						_mark(j);
					}
				}
			}
		}
	}
	auto w = _xnext_wait.find(l_key[i]);
	if (w != _xnext_wait.end()) {
		for (int j : w->second) {
			_mark(j);
		}
	}
	i64 u = _unit(l_key[i]);
	for (int line = 1; line < 9; line++) {
		int j = _lane_index(u * 8 + line);
		if (j >= 0) {
			_mark(j);
		}
	}
	for (int j : l_feeders[i]) {
		_mark(j);
	}
}

void BeltSimNative::_unlink(int i) {
	int n = l_next[i];
	if (n >= 0) {
		erase_value(l_feeders[n], i);
	}
	int s = l_side[i];
	if (s >= 0) {
		erase_value(l_sideins[s], i);
	}
	l_next[i] = -1;
	l_side[i] = -1;
	l_sp0[i] = -1;
	l_sp1[i] = -1;
}

bool BeltSimNative::_near(i64 ax, i64 ay, i64 bx, i64 by) {
	return absi(ax - bx) <= 4 && absi(ay - by) <= 4;
}

// An underground exit's lines 3-4, unused by the belt: linked to nothing (belt_sim.gd's _ug_back_half).
bool BeltSimNative::_ug_back_half(int i) const {
	if (l_kind[i] != OTHER) {
		return false;
	}
	int v = _lane_index(_unit(l_key[i]) * 8 + 1);
	return v >= 0 && l_kind[v] == UG_VISIBLE;
}

void BeltSimNative::_link(int a) {
	int nxt = -1;
	int kind = l_kind[a];
	if (_ug_back_half(a)) {
		l_next[a] = -1;
		return;
	}
	if (l_xnext[a] != 0) {
		nxt = _lane_index(l_xnext[a]);
	} else {
		i64 cx = _floordiv(l_x0[a], 32);
		i64 cy = _floordiv(l_y0[a], 32);
		for (int dx = -1; dx < 2; dx++) {
			for (int dy = -1; dy < 2; dy++) {
				auto it = _entry_grid.find(_cell(cx + dx, cy + dy));
				if (it == _entry_grid.end()) {
					continue;
				}
				for (int b : it->second) {
					if (b != a && l_kind[b] != UG_HIDDEN && !_ug_back_half(b) && _near(l_x0[a], l_y0[a], l_x1[b], l_y1[b])) {
						nxt = b;
					}
				}
			}
		}
	}
	if (kind == SPLIT_IN) {
		nxt = -1;
	}
	l_next[a] = nxt;
	if (nxt >= 0) {
		l_feeders[nxt].push_back(a);
	}
	if (nxt >= 0 || kind == SPLIT_IN) {
		return;
	}
	double best_d = 0.0;
	int best = -1;
	i64 best_at = 0;
	std::vector<int> cands;
	i64 sx = _floordiv(l_x0[a], 512);
	i64 sy = _floordiv(l_y0[a], 512);
	for (int dx = -1; dx < 2; dx++) {
		for (int dy = -1; dy < 2; dy++) {
			auto it = _side_grid.find(_cell(sx + dx, sy + dy));
			if (it != _side_grid.end()) {
				cands.insert(cands.end(), it->second.begin(), it->second.end());
			}
		}
	}
	if (cands.size() > 1) {
		std::stable_sort(cands.begin(), cands.end(), [this](int x, int y) { return l_seq[x] < l_seq[y]; });
	}
	i64 unit = _unit(l_key[a]);
	for (int b : cands) {
		if (_unit(l_key[b]) == unit || !((l_len[b] == 256 && l_kind[b] <= CURVE) || l_kind[b] == UG_VISIBLE)) {
			continue;
		}
		i64 ex = l_x0[b];
		i64 ey = l_y0[b];
		i64 nx = l_x1[b];
		i64 ny = l_y1[b];
		i64 vx = ex - nx;
		i64 vy = ey - ny;
		i64 n2 = vx * vx + vy * vy;
		if (n2 == 0) {
			continue;
		}
		double u = double((l_x0[a] - nx) * vx + (l_y0[a] - ny) * vy) / double(n2);
		if (!(0.05 < u && u < 0.95)) {
			continue;
		}
		double px = double(nx) + double(vx) * u;
		double py = double(ny) + double(vy) * u;
		double d = std::sqrt(std::pow(double(l_x0[a]) - px, 2.0) + std::pow(double(l_y0[a]) - py, 2.0));
		if (d < 140.0 && (best < 0 || d < best_d)) {
			best_d = d;
			best = b;
			best_at = _round_half_even(double(l_len[b] - 1) * (1.0 - u));
		}
	}
	if (best >= 0) {
		l_side[a] = best;
		l_side_at[a] = (int32_t)best_at;
		l_sideins[best].push_back(a);
	}
}

i64 BeltSimNative::_round_half_even(double x) {
	double r = std::round(x);
	if (std::fabs(x - std::floor(x) - 0.5) < 1e-12) {
		i64 fl = (i64)std::floor(x);
		return fl % 2 == 0 ? fl : fl + 1;
	}
	return (i64)r;
}

void BeltSimNative::_build_splitters() {
	std::vector<i64> units;
	std::unordered_set<i64> useen;
	for (size_t i = 0; i < l_key.size(); i++) {
		if (l_alive[i] == 1 && (l_kind[i] == SPLIT_IN || l_kind[i] == SPLIT_OUT)) {
			i64 u = _unit(l_key[i]);
			if (useen.insert(u).second) {
				units.push_back(u);
			}
		}
	}
	std::unordered_map<i64, Splitter> old;
	old.swap(_splitters);
	for (i64 u : units) {
		Splitter sp;
		auto o = old.find(u);
		if (o != old.end()) {
			sp = o->second;
		}
		sp.unit = u;
		for (int k = 0; k < 4; k++) {
			sp.ins[k] = -1;
			sp.outs[k] = -1;
		}
		bool lane_split = false;
		for (int line = 1; line < 9; line++) {
			int j = _lane_index(u * 8 + line);
			if (j >= 0 && l_kind[j] == SPLIT_OUT && line <= 4) {
				lane_split = true;
			}
		}
		int slots[9] = { -1, -1, -1, -1, -1, -1, -1, -1, -1 };
		int first_slot = -1;
		for (int line = 1; line < 9; line++) {
			int j = _lane_index(u * 8 + line);
			if (j < 0) {
				continue;
			}
			int k = line;
			if (lane_split) {
				static const int m[9] = { 0, 1, 3, 5, 7, 0, 0, 0, 0 };
				k = m[line];
				if (k == 0) {
					continue;
				}
			}
			if (slots[k] < 0 && first_slot < 0) {
				first_slot = j;
			}
			slots[k] = j;
			if (k <= 4) {
				sp.ins[((k - 1) / 2) * 2 + (k - 1) % 2] = j;
				l_sp0[j] = (k - 1) / 2;
				l_sp1[j] = (k - 1) % 2;
			} else {
				sp.outs[((k - 5) / 2) * 2 + (k - 5) % 2] = j;
			}
		}
		int any_lane = first_slot;
		i64 ex = any_lane >= 0 ? (i64)l_extra[any_lane] : 0;
		i64 inp = ex % 3;
		i64 outp = (ex / 3) % 3;
		sp.filter = ex / 9;
		int left = 0;
		int o5 = slots[5];
		int o7 = slots[7];
		if (o5 >= 0 && o7 >= 0) {
			i64 vx = (i64)l_x0[o5] - l_x1[o5];
			i64 vy = (i64)l_y0[o5] - l_y1[o5];
			i64 lx = vy;
			i64 ly = -vx;
			left = ((i64)l_x0[o5] * lx + (i64)l_y0[o5] * ly) > ((i64)l_x0[o7] * lx + (i64)l_y0[o7] * ly) ? 0 : 1;
		}
		sp.in_prio = inp == 0 ? -1 : (inp == 1 ? left : 1 - left);
		sp.out_prio = outp == 0 ? -1 : (outp == 1 ? left : 1 - left);
		_splitters[u] = sp;
	}
}

void BeltSimNative::_split_inputs_of(int out_lane, std::vector<int> &r) {
	r.clear();
	auto it = _splitters.find(_unit(l_key[out_lane]));
	if (it == _splitters.end()) {
		return;
	}
	Splitter &sp = it->second;
	for (int k = 0; k < 4; k++) {
		if (sp.outs[k] == out_lane) {
			int side = k % 2;
			int xs[2] = { sp.ins[side], sp.ins[2 + side] };
			for (int x : xs) {
				if (x >= 0) {
					r.push_back(x);
				}
			}
		}
	}
}

void BeltSimNative::_relink() {
	if (!_dirty_any) {
		return;
	}
	_dirty_any = false;
	if (_dirty_v.empty()) {
		_reline();
		return;
	}
	for (int i : _relines.v) {
		if (!_dirty_f[i]) {
			_dirty_f[i] = 1;
			_dirty_v.push_back(i);
		}
	}
	_relines.clear();
	std::vector<int> lanes;
	lanes.swap(_dirty_v);
	for (int i : lanes) {
		_dirty_f[i] = 0;
	}
	OrderedSet touched;
	for (int i : lanes) {
		if (l_alive[i] == 0) {
			continue;
		}
		touched.add(i);
		if (l_next[i] >= 0) {
			touched.add(l_next[i]);
		}
		if (l_side[i] >= 0) {
			touched.add(l_side[i]);
		}
	}
	OrderedSet was_open;
	for (int i : lanes) {
		if (l_alive[i] == 1) {
			if (l_next[i] < 0 && l_side[i] < 0 && l_kind[i] != SPLIT_IN) {
				was_open.add(i);
			}
			_unlink(i);
		}
	}
	std::vector<int> alive;
	for (int i : lanes) {
		if (l_alive[i] == 1) {
			alive.push_back(i);
		}
	}
	std::stable_sort(alive.begin(), alive.end(), [this](int x, int y) { return l_seq[x] < l_seq[y]; });
	for (int i : alive) {
		_link(i);
		if (l_next[i] >= 0) {
			touched.add(l_next[i]);
		}
		if (l_side[i] >= 0) {
			touched.add(l_side[i]);
		}
	}
	_build_splitters();
	OrderedSet dis;
	for (int i : touched.v) {
		if (l_alive[i] == 0) {
			continue;
		}
		dis.add(l_line[i]);
		for (int f : l_feeders[i]) {
			dis.add(l_line[f]);
		}
		for (int f : l_sideins[i]) {
			dis.add(l_line[f]);
		}
	}
	for (int id : dis.v) {
		_dissolve_line(id);
	}
	_order_dirty = true;
	_run_dirty = true;
	_order();
	_build_lines();
	for (auto &up : _lines) {
		if (up) {
			up->ord = _lane_pos[up->lanes[0]];
		}
	}
	if (_run_dirty) {
		_runs();
	}
	if (ask_on_link) {
		std::unordered_set<int> asked;
		for (int i : was_open.v) {
			if (l_alive[i] == 0 || (l_next[i] < 0 && l_side[i] < 0) || l_line[i] < 0) {
				continue;
			}
			Line *L = _line(l_line[i]);
			if (L == nullptr || L->uid.empty() || asked.count(L->id)) {
				continue;
			}
			asked.insert(L->id);
			for (int x : L->lanes) {
				out_mismatch.push_back(l_key[x]);
			}
		}
	}
}

void BeltSimNative::_reline() {
	OrderedSet dis;
	for (int i : _relines.v) {
		if (l_alive[i] == 0) {
			continue;
		}
		dis.add(l_line[i]);
		for (int f : l_feeders[i]) {
			dis.add(l_line[f]);
		}
		int nx = l_next[i];
		if (nx >= 0) {
			dis.add(l_line[nx]);
		}
	}
	_relines.clear();
	for (int id : dis.v) {
		_dissolve_line(id);
	}
	_build_lines();
	for (auto &up : _lines) {
		Line *L = up.get();
		if (L != nullptr && L->due == maxi(tick, 0) + 1 && !L->lanes.empty()) {
			L->ord = _lane_pos[L->lanes[0]];
		}
	}
}

void BeltSimNative::_dissolve_line(int id) {
	if (id < 0 || id >= (int)_lines.size() || !_lines[id]) {
		return;
	}
	Line *L = _lines[id].get();
	i64 t = tick;
	_materialize(L, maxi(t, L->ft));
	i64 pos = L->f;
	size_t li = 0;
	for (size_t j = 0; j < L->uid.size(); j++) {
		if (j > 0) {
			pos += L->gap[j];
		}
		while (li + 1 < L->lanes.size() && pos >= L->base[li + 1]) {
			li += 1;
		}
		int lane = L->lanes[li];
		_pending.push_back({ lane, pos - L->base[li], L->uid[j], L->itm[j], L->stk[j], L->holds_has(L->uid[j]) });
		_uid_line.erase(L->uid[j]);
	}
	for (int lane : L->lanes) {
		l_line[lane] = -1;
	}
	_lines[id].reset();
	_free_lines.push_back(id);
}

bool BeltSimNative::_joinable(int a, int b) {
	if (b < 0 || a == b || l_next[a] != b) {
		return false;
	}
	if (l_kind[a] > UG_HIDDEN || l_kind[b] > UG_HIDDEN || l_step[a] != l_step[b]) {
		return false;
	}
	if (l_off[a] == 1 || l_off[b] == 1) {
		return false;
	}
	return l_feeders[b].size() == 1 && l_sideins[b].empty();
}

void BeltSimNative::_build_lines() {
	std::vector<int> free_lanes;
	for (size_t i = 0; i < l_key.size(); i++) {
		if (l_alive[i] == 1 && l_line[i] < 0) {
			free_lanes.push_back((int)i);
		}
	}
	// (Twice over: a ring is cut into two lines below, and when the lane past the cut was walked
	// already, the second pass gives it its line.)
	size_t nfree = free_lanes.size();
	for (size_t q = 0; q < 2 * nfree; q++) {
		int i = free_lanes[q % nfree];
		if (l_line[i] >= 0) {
			continue;
		}
		int front = i;
		int guard = 0;
		while (_joinable(front, l_next[front]) && l_line[l_next[front]] < 0 && guard < 100000) {
			front = l_next[front];
			guard += 1;
			if (front == i) {
				int x0 = l_next[i];
				while (x0 != i) {
					if (_lane_pos[x0] < _lane_pos[front]) {
						front = x0;
					}
					x0 = l_next[x0];
				}
				break;
			}
		}
		Line *L = _new_line();
		L->s = l_step[front];
		int x = front;
		i64 b = 0;
		while (true) {
			L->lanes.push_back(x);
			L->base.push_back((int)b);
			l_line[x] = L->id;
			l_base[x] = (int32_t)b;
			if (l_off[x] == 1) {
				L->off = true;
			}
			b += l_len[x];
			int nb = -1;
			for (int f : l_feeders[x]) {
				if (_joinable(f, x) && l_line[f] < 0) {
					nb = f;
				}
			}
			if (nb < 0 || nb == l_next[front]) {
				break;
			}
			x = nb;
		}
		L->total = b;
	}
	// Their items back, by line.
	std::vector<int> per_order;
	std::unordered_map<int, std::vector<Pending>> per;
	for (const Pending &p : _pending) {
		int lane = p.lane;
		if (l_alive[lane] == 0 || l_line[lane] < 0) {
			_gone(p.uid);
			continue;
		}
		int id = l_line[lane];
		auto it = per.find(id);
		if (it == per.end()) {
			per_order.push_back(id);
			it = per.emplace(id, std::vector<Pending>()).first;
		}
		Pending q = p;
		q.pos = l_base[lane] + p.pos;
		it->second.push_back(q);
	}
	_pending.clear();
	for (int id : per_order) {
		Line *L = _line(id);
		std::vector<Pending> &lst = per[id];
		std::stable_sort(lst.begin(), lst.end(), [](const Pending &a, const Pending &c) {
			return a.pos < c.pos || (a.pos == c.pos && a.uid < c.uid);
		});
		for (const Pending &e : lst) {
			_append_sorted_build(L, e.pos, e.uid, e.item, e.stack);
			if (e.hold) {
				L->holds_add(e.uid);
			}
		}
	}
}

BeltSimNative::Line *BeltSimNative::_new_line() {
	std::unique_ptr<Line> up(new Line());
	Line *L = up.get();
	if (!_free_lines.empty()) {
		L->id = _free_lines.back();
		_free_lines.pop_back();
		_lines[L->id] = std::move(up);
	} else {
		L->id = (int)_lines.size();
		_lines.push_back(std::move(up));
	}
	L->ft = maxi(tick, 0);
	L->due = -1;
	L->done_tick = _in_step ? _cur_t : -1;
	_set_due(L, maxi(tick, 0) + 1);
	return L;
}

void BeltSimNative::_append_sorted_build(Line *L, i64 pos, i64 uid, i64 item, i64 stack) {
	if (L->uid.empty()) {
		L->f = pos;
		L->span = 0;
		L->gap.push_back(0);
	} else {
		i64 g = pos - (L->f + L->span);
		L->gap.push_back((int32_t)g);
		L->span += g;
	}
	L->uid.push_back(uid);
	L->itm.push_back((int32_t)item);
	L->stk.push_back((int32_t)stack);
	_rec_append(L, -1);
	_uid_line[uid] = L->id;
	L->lp = 1;
}

void BeltSimNative::_order() {
	if (!_order_dirty) {
		return;
	}
	_order_dirty = false;
	int nl = (int)l_key.size();
	std::vector<int> all;
	for (int i = 0; i < nl; i++) {
		if (l_alive[i] == 1) {
			all.push_back(i);
		}
	}
	std::stable_sort(all.begin(), all.end(), [this](int x, int y) { return l_seq[x] < l_seq[y]; });
	std::vector<Splitter *> sps;
	std::unordered_set<i64> seen;
	std::unordered_map<i64, std::vector<int>> outs;
	for (int i : all) {
		if (l_kind[i] == SPLIT_IN || l_kind[i] == SPLIT_OUT) {
			i64 u = _unit(l_key[i]);
			auto it = _splitters.find(u);
			if (!seen.count(u) && it != _splitters.end()) {
				seen.insert(u);
				Splitter *sp = &it->second;
				sp->node = nl + (i64)sps.size();
				sps.push_back(sp);
			}
			if (l_kind[i] == SPLIT_OUT) {
				outs[u].push_back(i);
			}
		}
	}
	std::vector<int> roots = all;
	for (Splitter *sp : sps) {
		roots.push_back((int)sp->node);
	}
	std::vector<uint8_t> state(nl + sps.size(), 0);
	std::vector<int> order;
	std::vector<int> stack_x, stack_i;
	static const std::vector<int> none;
	for (int r : roots) {
		if (state[r] != 0) {
			continue;
		}
		stack_x.push_back(r);
		stack_i.push_back(0);
		while (!stack_x.empty()) {
			int x = stack_x.back();
			int k = stack_i.back();
			stack_x.pop_back();
			stack_i.pop_back();
			if (k == 0) {
				if (state[x] != 0) {
					continue;
				}
				state[x] = 1;
			}
			int one = -1;
			const std::vector<int> *deps = &none;
			int ndeps = 0;
			if (x >= nl) {
				auto it = outs.find(sps[x - nl]->unit);
				if (it != outs.end()) {
					deps = &it->second;
					ndeps = (int)deps->size();
				}
			} else if (l_next[x] >= 0) {
				one = l_next[x];
				ndeps = 1;
			} else if (l_side[x] >= 0) {
				one = l_side[x];
				ndeps = 1;
			} else if (l_kind[x] == SPLIT_IN && _splitters.count(_unit(l_key[x]))) {
				one = (int)_splitters[_unit(l_key[x])].node;
				ndeps = 1;
			}
			if (k < ndeps) {
				stack_x.push_back(x);
				stack_i.push_back(k + 1);
				int y = one >= 0 ? one : (*deps)[k];
				if (state[y] == 0) {
					stack_x.push_back(y);
					stack_i.push_back(0);
				}
			} else {
				state[x] = 2;
				order.push_back(x);
			}
		}
	}
	std::vector<int> pos(nl, 0);
	int n = 0;
	for (int x : order) {
		if (x >= nl) {
			Splitter *sp2 = sps[x - nl];
			for (int j : sp2->ins) {
				if (j >= 0) {
					pos[j] = n;
				}
			}
			n += 1;
		} else if (l_kind[x] != SPLIT_IN) {
			pos[x] = n;
			n += 1;
		}
	}
	_lane_pos.swap(pos);
}

void BeltSimNative::_runs() {
	_run_dirty = false;
	size_t nl = l_key.size();
	for (size_t i = 0; i < nl; i++) {
		l_run[i] = -1;
	}
	std::vector<int> chain;
	std::vector<uint8_t> in_chain(nl, 0);
	for (size_t i = 0; i < nl; i++) {
		if (l_alive[i] == 0 || l_run[i] >= 0) {
			continue;
		}
		chain.clear();
		int x = (int)i;
		while (true) {
			chain.push_back(x);
			in_chain[x] = 1;
			int nx = l_next[x];
			if (l_kind[x] != STRAIGHT || nx < 0 || l_kind[nx] != STRAIGHT || l_step[nx] != l_step[x] ||
					l_off[nx] == 1 || signi((i64)l_x0[x] - l_x1[x]) != signi((i64)l_x0[nx] - l_x1[nx]) ||
					signi((i64)l_y0[x] - l_y1[x]) != signi((i64)l_y0[nx] - l_y1[nx]) || chain.size() > 100000) {
				break;
			}
			if (l_run[nx] >= 0) {
				break;
			}
			if (in_chain[nx]) {
				break;
			}
			x = nx;
		}
		for (int c : chain) {
			in_chain[c] = 0;
		}
		int last = chain.back();
		i64 acc = 0;
		int nl2 = l_next[last];
		bool cont = nl2 >= 0 && l_kind[last] == STRAIGHT && l_kind[nl2] == STRAIGHT && l_step[nl2] == l_step[last] &&
				l_off[nl2] == 0 && l_run[nl2] >= 0 &&
				signi((i64)l_x0[last] - l_x1[last]) == signi((i64)l_x0[nl2] - l_x1[nl2]) &&
				signi((i64)l_y0[last] - l_y1[last]) == signi((i64)l_y0[nl2] - l_y1[nl2]);
		if (cont) {
			acc = (i64)l_run[nl2] + l_len[nl2];
		}
		for (int k = (int)chain.size() - 1; k >= 0; k--) {
			int c = chain[k];
			l_run[c] = l_kind[c] == STRAIGHT ? (int32_t)acc : 0;
			acc = l_kind[c] == STRAIGHT ? (i64)l_run[c] + l_len[c] : 0;
		}
	}
}

// ======================================================================== stepping

void BeltSimNative::_set_due(Line *L, i64 d) {
	L->due = d;
	if (d < 0) {
		return;
	}
	if (_in_step && d == _cur_t) {
		_heap_push((L->ord << 24) | L->id);
		return;
	}
	_bucket[d].push_back(L->id);
}

void BeltSimNative::_wake(Line *L) {
	if (_in_step) {
		i64 t = _cur_t;
		if (L->done_tick != t && L->ord > _cur_ord) {
			if (L->due != t) {
				_set_due(L, t);
			}
		} else if (L->due < 0 || L->due > t + 1) {
			_set_due(L, t + 1);
		}
	} else {
		i64 t2 = tick + 1;
		if (L->due < 0 || L->due > t2) {
			_set_due(L, t2);
		}
	}
}

void BeltSimNative::_heap_push(i64 v) {
	std::vector<i64> &h = _heap;
	h.push_back(v);
	size_t i = h.size() - 1;
	while (i > 0) {
		size_t p = (i - 1) >> 1;
		if (h[p] <= v) {
			break;
		}
		h[i] = h[p];
		i = p;
	}
	h[i] = v;
}

i64 BeltSimNative::_heap_pop() {
	std::vector<i64> &h = _heap;
	i64 top = h[0];
	i64 last = h.back();
	h.pop_back();
	size_t n = h.size();
	if (n == 0) {
		return top;
	}
	size_t i = 0;
	while (true) {
		size_t c = 2 * i + 1;
		if (c >= n) {
			break;
		}
		if (c + 1 < n && h[c + 1] < h[c]) {
			c += 1;
		}
		if (h[c] >= last) {
			break;
		}
		h[i] = h[c];
		i = c;
	}
	h[i] = last;
	return top;
}

void BeltSimNative::_step_tick() {
	i64 r0 = now_usec();
	_relink();
	us_relink += now_usec() - r0;
	i64 t = tick + 1;
	if (!given.is_empty()) {
		given.clear();
	}
	if (split_wake && !_splitters.empty()) {
		_note_outputs();
	}
	_in_step = true;
	_cur_t = t;
	_cur_ord = -1;
	auto b = _bucket.find(t);
	if (b != _bucket.end()) {
		std::vector<int> ids;
		ids.swap(b->second);
		_bucket.erase(b);
		for (int id : ids) {
			Line *L = _line(id);
			if (L != nullptr && L->due == t) {
				_heap_push((L->ord << 24) | id);
			}
		}
	}
	while (!_heap.empty()) {
		i64 v = _heap_pop();
		int id = (int)(v & 0xFFFFFF);
		Line *L = _line(id);
		if (L == nullptr || L->due != t || L->done_tick == t) {
			continue;
		}
		_cur_ord = L->ord;
		int l0 = L->lanes[0];
		if (l_kind[l0] == SPLIT_IN) {
			auto it = _splitters.find(_unit(l_key[l0]));
			if (it != _splitters.end()) {
				Splitter *sp = &it->second;
				if (sp->done_tick != t) {
					sp->done_tick = t;
					i64 c1 = profile ? now_usec() : 0;
					_step_side(sp, 0, t);
					_step_side(sp, 1, t);
					if (profile) {
						step_us[1] += now_usec() - c1;
					}
				}
				continue;
			}
		}
		L->done_tick = t;
		if (profile) {
			i64 c0 = now_usec();
			_step_line(L, t);
			bool edge = l_next[l0] < 0 && !_is_sidesplit(l0) && edge_mode == EDGE_ORACLE;
			step_us[edge ? 0 : 1] += now_usec() - c0;
		} else {
			_step_line(L, t);
		}
	}
	_in_step = false;
	tick = t;
}

void BeltSimNative::_step_input(int lane, i64 t) {
	if (lane < 0 || l_line[lane] < 0) {
		return;
	}
	Line *L = _line(l_line[lane]);
	if (L == nullptr || L->due != t || L->done_tick == t) {
		return;
	}
	L->done_tick = t;
	_step_line(L, t);
}

bool BeltSimNative::_oracle_get(i64 uid, i64 &key, i64 &pos) const {
	if (oracle.is_empty()) {
		return false;
	}
	Variant g = oracle.get(uid, Variant());
	if (g.get_type() == Variant::NIL) {
		return false;
	}
	Array a = g;
	key = a[0];
	pos = a[1];
	return true;
}

void BeltSimNative::_step_side(Splitter *sp, int side, i64 t) {
	if (sp->in_turn[side] >= 0 || sp->in_prio >= 0 || edge_mode != EDGE_ORACLE) {
		int first = sp->in_prio >= 0 ? sp->in_prio : (int)maxi(sp->in_turn[side], 0);
		_step_input(sp->ins[first * 2 + side], t);
		_step_input(sp->ins[(1 - first) * 2 + side], t);
		return;
	}
	int lanes[4] = { sp->ins[side], sp->ins[2 + side], sp->outs[side], sp->outs[2 + side] };
	std::vector<int> lines;
	for (int x : lanes) {
		if (x >= 0 && l_line[x] >= 0 && std::find(lines.begin(), lines.end(), (int)l_line[x]) == lines.end()) {
			lines.push_back(l_line[x]);
		}
	}
	std::vector<Line> saved;
	for (int id : lines) {
		saved.push_back(*_lines[id]);
	}
	int out_turn[2] = { sp->out_turn[0], sp->out_turn[1] };
	size_t outs_n = out_uid.size();
	size_t gone_n = out_gone.size();
	i64 before = sp->crossed;
	for (int first = 0; first < 2; first++) {
		if (first == 1) {
			for (size_t k = 0; k < lines.size(); k++) {
				Line *L = _lines[lines[k]].get();
				const Line &a = saved[k];
				L->uid = a.uid;
				L->itm = a.itm;
				L->stk = a.stk;
				L->gap = a.gap;
				L->f = a.f;
				L->span = a.span;
				L->ft = a.ft;
				L->mode = a.mode;
				L->ck = a.ck;
				L->due = a.due;
				L->lp = a.lp;
				L->lp2_from = a.lp2_from;
				L->lp2 = a.lp2;
				L->bp = a.bp;
				L->bp_tick = a.bp_tick;
				L->arr = a.arr;
				L->arr_tick = a.arr_tick;
				L->done_tick = a.done_tick;
				L->rs = a.rs;
				L->rv = a.rv;
				L->pr_has = a.pr_has;
				L->pr_pos = a.pr_pos;
				L->pr_t = a.pr_t;
				L->pr_v = a.pr_v;
				L->holds = a.holds;
				for (i64 u : L->uid) {
					_uid_line[u] = L->id;
				}
			}
			sp->out_turn[0] = out_turn[0];
			sp->out_turn[1] = out_turn[1];
			_trim_out(outs_n, gone_n);
		}
		sp->in_turn[side] = first;
		before = sp->crossed;
		_step_input(sp->ins[first * 2 + side], t);
		_step_input(sp->ins[(1 - first) * 2 + side], t);
		bool ok = true;
		for (int id : lines) {
			Line *L = _lines[id].get();
			_materialize(L, t);
			i64 q = L->f;
			for (size_t j = 0; j < L->uid.size(); j++) {
				if (j > 0) {
					q += L->gap[j];
				}
				i64 gk, gp;
				if (_oracle_get(L->uid[j], gk, gp)) {
					int li = _lane_at(L, q);
					if (gk != l_key[L->lanes[li]] || gp != q - L->base[li]) {
						ok = false;
						break;
					}
				}
			}
			if (!ok) {
				break;
			}
		}
		if (ok) {
			break;
		}
	}
	if (sp->crossed == before) {
		sp->in_turn[side] = -1;
	}
}

void BeltSimNative::_trim_out(size_t n, size_t ng) {
	auto trim = [](auto &v, size_t k) {
		if (v.size() > k) {
			v.resize(k);
		}
	};
	trim(out_uid, n);
	trim(out_item, n);
	trim(out_stack, n);
	trim(out_key, n);
	trim(out_pos, n);
	trim(out_tick, n);
	trim(out_speed, n);
	trim(out_reach, n);
	trim(out_run, n);
	trim(out_gone, ng);
	trim(out_gone_tick, ng);
	trim(out_gone_at, ng);
}

void BeltSimNative::mark_split_holds() {
	_relink();
	for (auto &up : _lines) {
		Line *L = up.get();
		if (L == nullptr || l_kind[L->lanes[0]] != SPLIT_OUT) {
			continue;
		}
		for (size_t j = 1; j < L->uid.size(); j++) {
			if (L->gap[j] < GAP) {
				L->holds_add(L->uid[j]);
			}
		}
	}
}

void BeltSimNative::_materialize(Line *L, i64 t) {
	if (t <= L->ft) {
		return;
	}
	i64 d = t - L->ft;
	if (L->mode == 1) {
		L->f -= L->s * d;
	} else if (L->mode == 2) {
		L->gap[L->ck] = (int32_t)(L->gap[L->ck] - L->s * d);
		L->span -= L->s * d;
	}
	L->ft = t;
}

i64 BeltSimNative::_back_at(Line *L, i64 t) {
	i64 b = L->f + L->span;
	if (L->mode != 0 && t > L->ft) {
		b -= L->s * (t - L->ft);
	}
	return b;
}

bool BeltSimNative::_done(Line *X, i64 t) {
	return X->done_tick == t || X->ord < _cur_ord;
}

int BeltSimNative::_ahead(Line *A, i64 t) {
	int x = l_next[A->lanes[0]];
	i64 off = 0;
	while (x >= 0 && off <= WALK) {
		if (l_off[x] == 1) {
			_ah_new = -off;
			return 1;
		}
		Line *X = _lneg(l_line[x]);
		if (X == nullptr) {
			return 2;
		}
		if (!X->uid.empty()) {
			i64 bn, bo;
			if (_done(X, t)) {
				bn = _back_at(X, t);
				if (X->bp_tick == t) {
					bo = X->bp;
				} else if (X->mode != 0) {
					bo = bn + X->s;
				} else {
					bo = bn;
				}
			} else {
				bo = _back_at(X, t - 1);
				bn = bo - X->s;
			}
			i64 e = (i64)l_base[x] + l_len[x];
			_ah_new = bn - e - off;
			_ah_old = bo - e - off;
			return 0;
		}
		off += (i64)l_base[x] + l_len[x];
		x = l_next[X->lanes[0]];
	}
	if (x < 0) {
		_ah_new = -off;
		return 1;
	}
	return 2;
}

bool BeltSimNative::_is_sidesplit(int l0) {
	return l_side[l0] >= 0 || l_kind[l0] == SPLIT_IN;
}

void BeltSimNative::_step_line(Line *A, i64 t) {
	n_line_steps += 1;
	_materialize(A, t - 1);
	i64 n = (i64)A->uid.size();
	if (n == 0) {
		A->mode = 0;
		A->due = -1;
		A->ft = t;
		_promise(A, t);
		return;
	}
	if (A->off) {
		A->mode = 0;
		A->ft = t;
		A->bp = A->f + A->span;
		A->bp_tick = t;
		_emit_pattern(A, t, 0);
		A->due = -1;
		_promise(A, t);
		return;
	}
	i64 s = A->s;
	int l0 = A->lanes[0];
	i64 len0 = l_len[l0];
	int nx = l_next[l0];
	bool sidesplit = _is_sidesplit(l0);
	i64 n_eff = n;
	if (A->arr_tick == t) {
		n_eff = n - A->arr;
	}
	i64 F = A->f;
	i64 back_old = F + A->span;
	int lk = 0;
	i64 la = 0;
	i64 lo = 0;
	bool in0 = F < len0;
	// A lane leading out: its wall (set_wall). wall_i: the wall item's index when items run off ahead of it.
	i64 wall_i = -1;
	i64 wall_p = 0;
	bool wall_on = nx < 0 && !sidesplit && !_out_keys.empty() && _out_keys.count(l_key[l0]);
	if (wall_on) {
		lk = 1;
		const Wall *w = _wall_at(l_key[l0], t);
		if (w == nullptr) {
			la = F;
		} else if (w->uid == 0) {
			la = FAR;
		} else {
			i64 iw = -1;
			for (size_t q = 0; q < A->uid.size(); q++) {
				if (A->uid[q] == w->uid) {
					iw = (i64)q;
					break;
				}
			}
			if (iw > 0) {
				la = FAR;
				wall_i = iw;
				wall_p = w->pos;
			} else {
				la = w->pos;
			}
		}
	} else if (in0 && sidesplit) {
		lk = 1;
		la = FAR;
	} else if (in0 && nx < 0) {
		lk = 1;
		if (edge_mode == EDGE_ORACLE) {
			i64 u = A->uid[0];
			given[u] = true;
			i64 gk, gp;
			if (_oracle_get(u, gk, gp) && gk == l_key[l0]) {
				la = gp;
			} else {
				la = FAR;
			}
		} else if (edge_mode == EDGE_STOP) {
			la = 0;
		} else {
			la = FAR;
		}
	} else {
		int r = _ahead(A, t);
		if (r == 0) {
			la = _ah_new;
			lo = _ah_old;
		} else if (r == 1) {
			lk = 1;
			la = _ah_new;
		} else {
			lk = 1;
			la = FAR;
		}
	}
	bool spd_change = nx >= 0 && l_step[nx] != s;
	i64 ns = nx >= 0 ? (i64)l_step[nx] : s;
	_seg_i.clear();
	_seg_v.clear();
	// --- the head ---
	i64 hb = s;
	if (sidesplit) {
		hb = maxi(hb, len0);
	}
	bool held = !A->holds.empty();
	if (held) {
		hb = i64(1) << 40;
	}
	bool open_front = nx < 0 && !sidesplit && edge_mode == EDGE_ORACLE;
	std::vector<int32_t> &hp = _hp;
	std::vector<int32_t> &hm = _hm;
	hp.clear();
	hm.clear();
	i64 p = F;
	i64 m_prev = 0;
	i64 i = 0;
	while (i < n_eff) {
		bool follow = false;
		if (i > 0) {
			p += A->gap[i];
			follow = open_front && p < len0 && (i64)hp[i - 1] - hm[i - 1] < 0;
			if (p >= hb && !follow && i > wall_i) {
				break;
			}
		}
		i64 mf = s;
		if (p - s < 0 && spd_change && s > 0) {
			mf = p + ((s - p) * ns) / s;
		}
		i64 m;
		if (i == 0) {
			if (lk == 1) {
				m = la == FAR ? mf : maxi(0, mini(mf, p - la));
			} else if (held && A->holds_has(A->uid[0])) {
				m = maxi(0, mini(mf, (lo - la) + (p - lo) - GAP));
			} else {
				m = maxi(0, mini(mf, (lo - la) + maxi(0, (p - lo) - GAP)));
			}
		} else if (held && A->holds_has(A->uid[i])) {
			m = maxi(0, mini(mf, m_prev + A->gap[i] - GAP));
		} else {
			m = maxi(0, mini(mf, m_prev + maxi(0, A->gap[i] - GAP)));
		}
		if (i == wall_i) {
			m = maxi(0, mini(m, p - wall_p));
		}
		if (follow) {
			i64 gk, gp;
			if (_oracle_get(A->uid[i], gk, gp) && gk == l_key[l0]) {
				m = maxi(0, mini(mf, p - gp));
				given[A->uid[i]] = true;
			}
		}
		hp.push_back((int32_t)p);
		hm.push_back((int32_t)m);
		m_prev = m;
		i += 1;
	}
	int h = (int)i;
	std::vector<int32_t> &hn = _hn;
	hn.resize(h);
	for (int k = 0; k < h; k++) {
		hn[k] = hp[k] - hm[k];
	}
	std::vector<uint8_t> &keep = _keep;
	keep.assign(h, 1);
	int removed = 0;
	if (sidesplit) {
		for (int k = 0; k < h; k++) {
			if (hn[k] < 0) {
				bool ok;
				if (l_side[l0] >= 0) {
					ok = _side_put(A, k, l0, hn[k], t);
				} else {
					ok = _split_put(A, k, l0, hn[k], t, h);
				}
				if (ok) {
					keep[k] = 0;
					removed += 1;
				} else {
					hn[k] = 0;
				}
			}
		}
		i64 lim = FAR;
		for (int k = 0; k < h; k++) {
			if (keep[k] == 0) {
				continue;
			}
			if (lim > FAR && hn[k] < lim) {
				hn[k] = (int32_t)lim;
			}
			lim = (i64)hn[k] + GAP;
		}
	} else {
		for (int k = 0; k < h; k++) {
			if (hn[k] >= 0) {
				break;
			}
			if (nx >= 0) {
				if (head_move) {
					_emit_left(A, k, t);
				}
				_transfer(A, k, nx, hn[k], hp[k], t);
				keep[k] = 0;
				removed += 1;
			} else if (edge_mode == EDGE_RUN_OFF || wall_on) {
				if (head_move) {
					_emit_left(A, k, t);
				}
				keep[k] = 0;
				removed += 1;
				_uid_line.erase(A->uid[k]);
				A->holds_erase(A->uid[k]);
				_gone(A->uid[k]);
			}
		}
	}
	// --- the tail ---
	i64 m_tail = s;
	i64 tail_first_new = 0;
	if (h < n_eff) {
		i64 p_h = p;
		i64 m_h;
		if (sidesplit) {
			int lastk = -1;
			for (int k = h - 1; k >= 0; k--) {
				if (keep[k] == 1) {
					lastk = k;
					break;
				}
			}
			i64 mf2 = s;
			if (lastk >= 0) {
				m_h = maxi(0, mini(mf2, ((i64)hp[lastk] - hn[lastk]) + maxi(0, (p_h - hp[lastk]) - GAP)));
			} else {
				m_h = clampi(p_h - 0, 0, mf2);
			}
		} else if (h == 0) {
			m_h = 0;
		} else {
			m_h = maxi(0, mini(s, hm[h - 1] + maxi(0, A->gap[h] - GAP)));
		}
		_seg_push(h, (int)m_h);
		tail_first_new = p_h - m_h;
		m_tail = _tail(A, h + 1, m_h, n_eff);
	} else if (h < n) {
		tail_first_new = p + A->gap[h];
	}
	// (No head when every item arrived this tick, into a ring's line not stepped yet: they stand.)
	i64 m_last = h < n_eff ? m_tail : (h > 0 ? (i64)hm[h - 1] : 0);
	// --- write the line back ---
	_emit_head(A, t, h);
	std::vector<i64> &new_head = _new_head;
	std::vector<int> &idx_keep = _idx_keep;
	new_head.clear();
	idx_keep.clear();
	for (int k = 0; k < h; k++) {
		if (keep[k] == 1) {
			new_head.push_back(hn[k]);
			idx_keep.push_back(k);
		}
	}
	bool arrived = A->arr_tick == t && A->arr > 0;
	_compact_head(A, h, idx_keep, new_head, tail_first_new, n_eff);
	n = (i64)A->uid.size();
	A->ft = t;
	A->mode = 0;
	if (n == 0) {
		A->due = -1;
		_promise(A, t);
		_put_self_side(A, t);
		return;
	}
	if (arrived) {
		A->span = back_old - A->f;
	} else if (h < n_eff) {
		A->span = back_old - m_last - A->f;
	} else {
		A->span = new_head.back() - A->f;
	}
	if (arrived) {
		i64 fa = n - A->arr;
		if (h < n_eff && fa >= 1) {
			A->gap[fa] = (int32_t)(A->gap[fa] + m_last);
		}
	} else if (h < n_eff) {
		A->bp = back_old;
		A->bp_tick = t;
	} else {
		A->bp = hp[idx_keep.back()];
		A->bp_tick = t;
	}
	_emit_tail(A, t, h - removed);
	bool moved = removed > 0;
	if (!moved) {
		for (int k = 0; k < h; k++) {
			if (hn[k] != hp[k]) {
				moved = true;
				break;
			}
		}
	}
	if (!moved) {
		for (int v : _seg_v) {
			if (v != 0) {
				moved = true;
				break;
			}
		}
	}
	if (moved) {
		_wake_waiting(A);
	}
	_still = !moved;
	_schedule(A, t);
	_put_self_side(A, t);
}

void BeltSimNative::_wake_waiting(Line *A) {
	int back = A->lanes.back();
	std::vector<int> si = l_sideins[back];
	for (int f : si) {
		int id = l_line[f];
		Line *X = _line(id);
		if (X != nullptr) {
			_wake(X);
		}
	}
	if (l_kind[back] == SPLIT_OUT) {
		std::vector<int> ins;
		_split_inputs_of(back, ins);
		for (int j : ins) {
			Line *X = _line(l_line[j]);
			if (l_line[j] >= 0 && X != nullptr) {
				_wake(X);
			}
		}
	}
}

bool BeltSimNative::_split_outs_asleep(int in_lane) {
	auto it = _splitters.find(_unit(l_key[in_lane]));
	if (it == _splitters.end()) {
		return true;
	}
	int side = l_sp1[in_lane];
	// (GDScript's outs[-1] is outs[3].)
	return _asleep(it->second.outs[(side + 4) % 4]) && _asleep(it->second.outs[(2 + side + 4) % 4]);
}

bool BeltSimNative::_asleep(int lane) {
	if (lane < 0 || l_line[lane] < 0) {
		return true;
	}
	Line *X = _line(l_line[lane]);
	return X == nullptr || (X->mode == 0 && X->due < 0);
}

i64 BeltSimNative::_min_gap(Line *A) {
	i64 m = i64(1) << 30;
	for (size_t j = 1; j < A->gap.size(); j++) {
		if (A->gap[j] < m) {
			m = A->gap[j];
		}
	}
	return m;
}

void BeltSimNative::_seg_push(int i, int v) {
	size_t n = _seg_v.size();
	if (n > 0 && _seg_v[n - 1] == v) {
		return;
	}
	_seg_i.push_back(i);
	_seg_v.push_back(v);
}

i64 BeltSimNative::_tail(Line *A, i64 i0, i64 m, i64 n_eff) {
	i64 s = A->s;
	i64 i = i0;
	while (m < s) {
		i64 k = _next_loose(A, i, n_eff);
		if (k >= n_eff) {
			break;
		}
		i64 mk = mini(s, m + A->gap[k] - GAP);
		A->gap[k] = (int32_t)(A->gap[k] - (mk - m));
		A->span -= mk - m;
		_seg_push((int)k, (int)mk);
		m = mk;
		i = k + 1;
	}
	return m;
}

i64 BeltSimNative::_next_loose(Line *A, i64 from, i64 lim) {
	const std::vector<int32_t> &g = A->gap;
	i64 k = from;
	if (from <= A->lp) {
		k = A->lp;
		while (k < lim && g[k] <= GAP) {
			k += 1;
		}
		A->lp = k;
		return k;
	}
	if (from >= A->lp2_from && from <= A->lp2) {
		k = A->lp2;
		while (k < lim && g[k] <= GAP) {
			k += 1;
		}
		A->lp2 = k;
		return k;
	}
	while (k < lim && g[k] <= GAP) {
		k += 1;
	}
	A->lp2_from = from;
	A->lp2 = k;
	return k;
}

void BeltSimNative::_compact_head(Line *A, int h, const std::vector<int> &idx_keep, const std::vector<i64> &new_head,
		i64 tail_first_new, i64 n_eff) {
	i64 n = (i64)A->uid.size();
	int removed = h - (int)idx_keep.size();
	if (removed == 0 && h == 1) {
		A->f = new_head[0];
		if (n > 1) {
			A->gap[1] = (int32_t)(tail_first_new - new_head[0]);
			if (A->gap[1] > GAP) {
				A->lp = 1;
			}
		}
		return;
	}
	bool has_tail = h < n;
	if (removed > 0) {
		std::vector<int> drop;
		size_t kk = 0;
		for (int k = 0; k < h; k++) {
			if (kk < idx_keep.size() && idx_keep[kk] == k) {
				kk += 1;
			} else {
				drop.push_back(k);
			}
		}
		for (int k = (int)drop.size() - 1; k >= 0; k--) {
			_rec_remove(A, drop[k]);
		}
		// (In place: the kept head items move to just before item h, the rest of the front goes.)
		int hk0 = (int)idx_keep.size();
		for (int q = hk0 - 1; q >= 0; q--) {
			int from = idx_keep[q];
			int to = h - hk0 + q;
			A->uid[to] = A->uid[from];
			A->itm[to] = A->itm[from];
			A->stk[to] = A->stk[from];
		}
		A->uid.erase(A->uid.begin(), A->uid.begin() + removed);
		A->itm.erase(A->itm.begin(), A->itm.begin() + removed);
		A->stk.erase(A->stk.begin(), A->stk.begin() + removed);
		A->gap.erase(A->gap.begin(), A->gap.begin() + removed);
		for (int q = 0; q < hk0; q++) {
			A->gap[q] = 0;
		}
		A->lp = maxi(1, A->lp - removed);
		if (A->lp2_from < (i64(1) << 29)) {
			A->lp2_from = maxi(1, A->lp2_from - removed);
			A->lp2 = maxi(A->lp2_from, A->lp2 - removed);
		}
	}
	int hk = (int)idx_keep.size();
	n = (i64)A->uid.size();
	if (n == 0) {
		A->f = 0;
		A->span = 0;
		return;
	}
	if (hk > 0) {
		A->f = new_head[0];
		for (int k = 1; k < hk; k++) {
			A->gap[k] = (int32_t)(new_head[k] - new_head[k - 1]);
			if (A->gap[k] > GAP && k < A->lp) {
				A->lp = k;
			}
		}
		if (has_tail) {
			A->gap[hk] = (int32_t)(tail_first_new - new_head[hk - 1]);
			if (A->gap[hk] > GAP && hk < A->lp) {
				A->lp = hk;
			}
		}
	} else {
		A->f = tail_first_new;
	}
	A->gap[0] = 0;
	A->lp = maxi(1, mini(A->lp, n));
}

// ---------------------------------------------------------------- moving items between lines

void BeltSimNative::_transfer(Line *A, int k, int nx, i64 new_pos, i64 old_pos, i64 t) {
	Line *X = _lneg(l_line[nx]);
	if (X == nullptr) {
		return;
	}
	i64 u = A->uid[k];
	i64 e = (i64)l_base[nx] + l_len[nx];
	bool done = _done(X, t);
	_materialize(X, done ? t : t - 1);
	i64 at = e + new_pos;
	int j = _insert(X, at, u, A->itm[k], A->stk[k], -1);
	if (A->holds_has(u)) {
		A->holds_erase(u);
		X->holds_add(u);
	}
	if (!done && j == (int)X->uid.size() - 1) {
		if (X->arr_tick != t) {
			X->arr_tick = t;
			X->arr = 0;
		}
		X->arr += 1;
	}
	if (j == (int)X->uid.size() - 1) {
		X->bp = e + old_pos;
		X->bp_tick = t;
	}
	if (X->mode != 0 && done) {
		_rec_set_one(X, j, (int)X->s);
		_emit_one(u, X->itm[j], X->stk[j], nx, at - l_base[nx], t, X->s, at);
	}
	if (X->mode == 0 || !done) {
		_wake(X);
	}
	_promise(X, t);
}

bool BeltSimNative::_side_put(Line *A, int k, int l0, i64 new_pos, i64 t) {
	int b = l_side[l0];
	Line *X = _lneg(l_line[b]);
	if (X == nullptr) {
		return false;
	}
	i64 jj0 = l_side_at[l0];
	i64 at = jj0 - 1 + new_pos;
	i64 u = A->uid[k];
	if (X == A) {
		// Onto its own back lane (belt_sim.gd's _side_put: a loop whose end side-loads onto its start; one
		// on Aquilo crashed here, reading past _idx_keep): put in once the step has written the line back.
		i64 fit = _side_at(A, b, at);
		if (fit > jj0 + 60 || fit >= l_len[b]) {
			return false;
		}
		_self_side.push_back({ A, u, A->itm[k], A->stk[k], A->holds_has(u), b, at });
		A->holds_erase(u);
		return true;
	}
	bool done = _done(X, t);
	_materialize(X, done ? t : t - 1);
	at = _side_at(X, b, at);
	if (at > jj0 + 60 || at >= l_len[b]) {
		return false;
	}
	_side_insert(X, b, at, u, A->itm[k], A->stk[k], A->holds_has(u), t);
	A->holds_erase(u);
	return true;
}

i64 BeltSimNative::_side_at(Line *X, int b, i64 at) {
	i64 lo = l_base[b];
	i64 hi = lo + l_len[b];
	i64 n = (i64)X->uid.size();
	if (n > 0) {
		i64 q = X->f + X->span;
		i64 j = n - 1;
		while (j > 0 && q - X->gap[j] >= lo) {
			q -= X->gap[j];
			j -= 1;
		}
		if (q >= lo || lo == 0) {
			while (j < n) {
				if (q >= hi) {
					break;
				}
				i64 ql = q - lo;
				if (at - GAP < ql && ql < at + GAP - 3) {
					at = ql + GAP;
				}
				j += 1;
				if (j < n) {
					q += X->gap[j];
				}
			}
		}
	}
	return at;
}

void BeltSimNative::_side_insert(Line *X, int b, i64 at, i64 u, i64 item, i64 stack, bool held, i64 t) {
	i64 lo = l_base[b];
	int jj = _insert(X, lo + at, u, item, stack, -1);
	if (held) {
		X->holds_add(u);
	}
	if (jj == (int)X->uid.size() - 1) {
		X->bp = lo + at;
		X->bp_tick = t;
	}
	_wake(X);
	_promise(X, t);
}

void BeltSimNative::_put_self_side(Line *A, i64 t) {
	if (_self_side.empty()) {
		return;
	}
	std::vector<SelfSide> puts;
	puts.swap(_self_side);
	for (const SelfSide &e : puts) {
		if (e.line != A) {
			_self_side.push_back(e);  // (another line's: left for the end of its own step)
			continue;
		}
		i64 at = mini(_side_at(A, e.lane, e.at), (i64)l_len[e.lane] - 1);
		_side_insert(A, e.lane, at, e.uid, e.item, e.stack, e.held, t);
	}
}

// (split_wake) Each splitter output's hindmost item where it is now (the end of the tick before the one
// about to be stepped), the last one's kept.
void BeltSimNative::_note_outputs() {
	for (auto &kv : _splitters) {
		const Splitter &sp = kv.second;
		for (int q = 0; q < 4; q++) {
			int o = sp.outs[q];
			if (o < 0) {
				continue;
			}
			auto f1 = _ob1.find(o);
			_ob2[o] = f1 != _ob1.end() ? f1->second : -1;
			i64 b = -1;
			int id = l_line[o];
			if (id >= 0) {
				Line *X = _line(id);
				if (X != nullptr && !X->uid.empty()) {
					_materialize(X, tick);
					i64 qq = X->f + X->span - l_base[o];
					if (qq >= 0 && qq < l_len[o]) {
						b = qq;
					}
				}
			}
			_ob1[o] = b;
		}
	}
}

bool BeltSimNative::_split_put(Line *A, int k, int l0, i64 new_pos, i64 t, int h) {
	_sp_newpos = new_pos;
	auto it = _splitters.find(_unit(l_key[l0]));
	if (it == _splitters.end()) {
		return false;
	}
	if (!_in_holds.empty()) {
		auto hh = _in_holds.find(l0);
		if (hh != _in_holds.end() && t > hh->second) {
			n_held += 1;
			return false;
		}
	}
	Splitter *sp = &it->second;
	int half = l_sp0[l0];
	int side = l_sp1[l0];
	i64 uid = A->uid[k];
	i64 item = A->itm[k];
	if (sp->out_turn[side] < 0 && sp->out_prio < 0 && sp->filter == 0) {
		i64 gk, gp;
		if (_oracle_get(uid, gk, gp)) {
			for (int hh = 0; hh < 2; hh++) {
				int o0 = sp->outs[hh * 2 + side];
				if (o0 >= 0 && l_key[o0] == gk) {
					sp->out_turn[side] = hh;
				}
			}
		}
	}
	int tries[2];
	int nt = 0;
	if (sp->filter != 0) {
		int fh = sp->out_prio >= 0 ? sp->out_prio : 0;
		tries[nt++] = sp->outs[(item == sp->filter ? fh : 1 - fh) * 2 + side];
	} else if (sp->out_prio >= 0) {
		tries[nt++] = sp->outs[sp->out_prio * 2 + side];
		tries[nt++] = sp->outs[(1 - sp->out_prio) * 2 + side];
	} else {
		int tt = (int)maxi(sp->out_turn[side], 0);
		tries[nt++] = sp->outs[tt * 2 + side];
		tries[nt++] = sp->outs[(1 - tt) * 2 + side];
	}
	for (int ti = 0; ti < nt; ti++) {
		int o = tries[ti];
		if (o < 0) {
			continue;
		}
		if (ti == 1 && sp->out_prio >= 0 && tries[0] >= 0 && !_fallback_ok(A, k, l0, tries[0], h, t)) {
			break;
		}
		Line *X = _lneg(l_line[o]);
		if (X == nullptr) {
			continue;
		}
		_materialize(X, t);
		i64 olen = l_len[o];
		bool empty = X->uid.empty();
		i64 back_l = X->f + X->span - l_base[o];
		i64 at = olen - SPLIT_BUFFER + _sp_newpos;
		if (!empty) {
			at = maxi(at, back_l + GAP);
			if (split_wake && at < olen && sp->in_prio < 0 && sp->out_prio < 0 && sp->filter == 0) {
				auto g1 = _ob1.find(o);
				i64 b1 = g1 != _ob1.end() ? g1->second : -1;
				auto g2 = _ob2.find(o);
				i64 b2 = g2 != _ob2.end() ? g2->second : -1;
				if (b1 >= 0 && b1 + GAP >= olen && b1 == b2) {
					auto sx = _side_x.find(sp->unit * 2 + side);
					i64 lx = t - (sx != _side_x.end() ? sx->second : -100);
					int oo = sp->outs[(o == sp->outs[side] ? 1 : 0) * 2 + side];
					bool om = false;
					if (oo >= 0) {
						auto h1 = _ob1.find(oo);
						auto h2 = _ob2.find(oo);
						om = (h1 != _ob1.end() ? h1->second : -1) != (h2 != _ob2.end() ? h2->second : -1);
					}
					if (lx >= 1 && (lx <= 2 || (lx == 3 && om))) {
						n_woke += 1;
						continue;
					}
				}
			}
		}
		bool hold = false;
		if (at >= olen && sp->in_prio == half && (empty || back_l < olen - 1)) {
			at = olen - 1;
			hold = true;
		}
		if (at < olen) {
			int jj = _insert(X, l_base[o] + at, uid, item, A->stk[k], -1);
			A->holds_erase(uid);
			if (hold) {
				X->holds_add(uid);
			}
			if (jj == (int)X->uid.size() - 1) {
				X->bp = l_base[o] + at;
				X->bp_tick = t;
			}
			sp->crossed += 1;
			_side_x[sp->unit * 2 + side] = t;
			sp->out_turn[side] = 1 - (o == sp->outs[side] ? 0 : 1);
			sp->in_turn[side] = 1 - half;
			_wake(X);
			_promise(X, t);
			return true;
		}
	}
	return false;
}

bool BeltSimNative::_fallback_ok(Line *A, int k, int l0, int prio, int h, i64 t) {
	if (h > 1 && k != 1) {
		if ((i64)_hp[1] - _hp[k] <= GAP) {
			return true;
		}
		Line *X = _lneg(l_line[prio]);
		if (X == nullptr) {
			return false;
		}
		_materialize(X, t);
		if (!X->uid.empty() && X->f + X->span - l_base[prio] + GAP > l_len[prio] && (i64)_hn[1] - GAP < 0) {
			_sp_newpos = (i64)_hn[1] - GAP;
			return true;
		}
		return false;
	}
	int x = l0;
	for (int ii = 0; ii < 64; ii++) {
		const std::vector<int> &f = l_feeders[x];
		if (f.size() != 1) {
			break;
		}
		x = f[0];
		if (_lane_has_items(x, t)) {
			return false;
		}
	}
	return true;
}

bool BeltSimNative::_lane_has_items(int x, i64 t) {
	int id = l_line[x];
	Line *L = _line(id);
	if (id < 0 || L == nullptr) {
		return false;
	}
	if (L->uid.empty()) {
		return false;
	}
	_materialize(L, !_done(L, t) ? maxi(L->ft, t - 1) : t);
	i64 lo = l_base[x];
	i64 hi = lo + l_len[x];
	i64 q = L->f;
	for (size_t j = 0; j < L->uid.size(); j++) {
		if (j > 0) {
			q += L->gap[j];
		}
		if (q >= hi) {
			return false;
		}
		if (q >= lo || lo == 0) {
			return true;
		}
	}
	return false;
}

int BeltSimNative::_insert(Line *X, i64 pos, i64 uid, i64 item, i64 stack, int rv) {
	int n = (int)X->uid.size();
	_uid_line[uid] = X->id;
	if (n == 0) {
		X->uid.push_back(uid);
		X->itm.push_back((int32_t)item);
		X->stk.push_back((int32_t)stack);
		X->gap.push_back(0);
		X->f = pos;
		X->span = 0;
		X->lp = 1;
		X->rs.assign(1, 0);
		X->rv.assign(1, rv);
		return 0;
	}
	i64 back = X->f + X->span;
	if (pos > back || (pos == back && uid > X->uid[n - 1])) {
		X->uid.push_back(uid);
		X->itm.push_back((int32_t)item);
		X->stk.push_back((int32_t)stack);
		X->gap.push_back((int32_t)(pos - back));
		X->span += pos - back;
		_rec_append(X, rv);
		if (pos - back > GAP && n < X->lp) {
			X->lp = n;
		}
		return n;
	}
	i64 q = X->f;
	int j = 0;
	while (j < n) {
		if (j > 0) {
			q += X->gap[j];
		}
		if (q > pos || (q == pos && X->uid[j] > uid)) {
			break;
		}
		j += 1;
	}
	if (j == 0) {
		X->uid.insert(X->uid.begin(), uid);
		X->itm.insert(X->itm.begin(), (int32_t)item);
		X->stk.insert(X->stk.begin(), (int32_t)stack);
		X->gap.insert(X->gap.begin() + 1, (int32_t)(q - pos));
		X->gap[0] = 0;
		X->f = pos;
		X->span += q - pos;
	} else {
		i64 prev = q - X->gap[j];
		X->uid.insert(X->uid.begin() + j, uid);
		X->itm.insert(X->itm.begin() + j, (int32_t)item);
		X->stk.insert(X->stk.begin() + j, (int32_t)stack);
		X->gap.insert(X->gap.begin() + j, (int32_t)(pos - prev));
		X->gap[j + 1] = (int32_t)(q - pos);
	}
	_rec_insert(X, j, rv);
	X->lp = 1;
	X->lp2_from = i64(1) << 30;
	if (X->mode == 2) {
		X->mode = 0;
	}
	return j;
}

void BeltSimNative::_remove_at(Line *X, int j) {
	int n = (int)X->uid.size();
	if (n == 1) {
		X->uid.clear();
		X->itm.clear();
		X->stk.clear();
		X->gap.clear();
		X->span = 0;
		X->rs.clear();
		X->rv.clear();
		return;
	}
	if (j == 0) {
		X->f += X->gap[1];
		X->span -= X->gap[1];
		X->gap.erase(X->gap.begin() + 1);
		X->gap[0] = 0;
	} else if (j == n - 1) {
		X->span -= X->gap[j];
		X->gap.erase(X->gap.begin() + j);
	} else {
		X->gap[j + 1] += X->gap[j];
		X->gap.erase(X->gap.begin() + j);
	}
	X->uid.erase(X->uid.begin() + j);
	X->itm.erase(X->itm.begin() + j);
	X->stk.erase(X->stk.begin() + j);
	_rec_remove(X, j);
	X->lp = 1;
	X->lp2_from = i64(1) << 30;
	if (X->mode == 2 && X->ck >= j) {
		X->mode = 0;
	}
}

void BeltSimNative::_touched(Line *L) {
	L->mode = 0;
	L->ft = tick;
	_wake(L);
	_wake_waiting(L);
	_promise(L, tick);
}

// ---------------------------------------------------------------- scheduling and promises

void BeltSimNative::_schedule(Line *A, i64 t) {
	i64 n = (i64)A->uid.size();
	i64 s = A->s;
	i64 F = A->f;
	A->ft = t;
	int l0 = A->lanes[0];
	i64 len0 = l_len[l0];
	int nx = l_next[l0];
	bool sidesplit = _is_sidesplit(l0);
	if (s <= 0) {
		_enter_mode(A, t, 0, 0);
		A->due = -1;
		_promise(A, t);
		return;
	}
	i64 K = NEVER;
	if (F < 0) {
		K = 0;
	} else {
		K = F / s;
	}
	if (nx < 0 && edge_mode == EDGE_ORACLE && !sidesplit) {
		K = mini(K, F >= len0 ? (F - len0) / s + 1 : 0);
	} else if (sidesplit && F < len0 && (!A->holds.empty() || _min_gap(A) < GAP)) {
		// (Its last lane's gaps under 64 are put back to 64 every tick: stepped every tick then.)
		K = 0;
	} else if (sidesplit) {
		K = mini(K, F >= len0 ? (F - len0) / s + 1 : NEVER);
	}
	if (A->arr_tick == t && A->arr > 0) {
		K = 0;
	}
	bool has = false;
	i64 D0 = 0;
	i64 v = 0;
	bool ahead_ok = true;
	if (!(F < len0 && (sidesplit || nx < 0))) {
		int x = nx;
		i64 off = 0;
		while (x >= 0 && off <= WALK) {
			if (l_off[x] == 1) {
				break;
			}
			Line *X = _lneg(l_line[x]);
			if (X == nullptr) {
				break;
			}
			if (!X->uid.empty()) {
				if (!_done(X, t)) {
					ahead_ok = false;
					break;
				}
				i64 e = (i64)l_base[x] + l_len[x];
				i64 a = X->pr_pos - X->pr_v * (t - X->pr_t) - e - off;
				has = true;
				D0 = F - a;
				v = X->pr_v;
				break;
			}
			off += (i64)l_base[x] + l_len[x];
			x = l_next[X->lanes[0]];
		}
	}
	if (!ahead_ok) {
		K = 0;
		prof[6] += 1;
	} else if (has) {
		i64 Ka = NEVER;
		if (D0 >= GAP) {
			if (D0 + v < GAP + s) {
				Ka = 0;
			} else if (v >= s) {
				Ka = NEVER;
			} else {
				Ka = (D0 + v - GAP - s) / (s - v) + 1;
			}
		} else {
			Ka = v >= s ? NEVER : 0;
		}
		K = mini(K, Ka);
	}
	// A lane leading out (set_wall): stepped every tick until its front stands at a wall no later one moves.
	bool wall_lane = nx < 0 && !sidesplit && !_out_keys.empty() && _out_keys.count(l_key[l0]);
	bool wall_blocked = false;
	if (wall_lane) {
		K = 0;
		const Wall *w = _wall_at(l_key[l0], t + 1);
		wall_blocked = n > 0 && _wall_settled(l_key[l0], t) && (w == nullptr || (w->uid == A->uid[0] && F == w->pos));
	}
	if (K >= 1) {
		_enter_mode(A, t, 1, 0);
		_set_due(A, K < NEVER ? t + K + 1 : -1);
	} else {
		bool blocked = false;
		if (has && v == 0 && D0 <= GAP) {
			blocked = true;
		} else if (wall_lane) {
			blocked = wall_blocked;
		} else if (F == 0 && nx < 0 && !sidesplit && edge_mode == EDGE_STOP) {
			blocked = true;
		}
		if (blocked && !sidesplit && !(nx < 0 && edge_mode == EDGE_ORACLE && F < len0) &&
				!(A->arr_tick == t && A->arr > 0)) {
			i64 k = _next_loose(A, 1, n);
			if (k >= n) {
				_enter_mode(A, t, 0, 0);
				A->due = -1;
			} else {
				i64 K2 = (A->gap[k] - GAP) / s;
				if (K2 >= 1) {
					_enter_mode(A, t, 2, k);
					_set_due(A, t + K2 + 1);
				} else {
					why_tick[8] += 1;
					A->mode = 0;
					_set_due(A, t + 1);
				}
			}
		} else if (sidesplit && _still && F < len0 &&
				((l_side[l0] >= 0 && _asleep(l_side[l0])) || (l_kind[l0] == SPLIT_IN && _split_outs_asleep(l0)))) {
			// (Its items' records standing too: belt_sim.gd.)
			_enter_mode(A, t, 0, 0);
			A->due = -1;
		} else {
			prof[5] += 1;
			int why = 6;
			if (A->arr_tick == t && A->arr > 0) {
				why = 4;
			} else if (sidesplit) {
				why = 1;
			} else if (F < s) {
				why = 5;
			} else if (has && v > 0) {
				why = 3;
			} else if (has) {
				why = 7;
			}
			why_tick[why] += 1;
			A->mode = 0;
			_set_due(A, t + 1);
		}
	}
	_promise(A, t);
}

void BeltSimNative::_enter_mode(Line *A, i64 t, int mode, i64 ck) {
	A->mode = mode;
	A->ck = ck;
	A->ft = t;
	if (mode == 1) {
		_emit_pattern(A, t, (int)A->s);
	} else if (mode == 2) {
		_emit_pattern2(A, t, ck);
	} else {
		_emit_pattern(A, t, 0);
	}
}

void BeltSimNative::_promise(Line *A, i64 t) {
	bool has = !A->uid.empty();
	i64 pos = 0;
	i64 v = 0;
	if (has) {
		pos = _back_at(A, t);
		if (A->mode != 0) {
			v = A->s;
		} else if (A->due == t + 1 && A->bp_tick == t) {
			v = maxi(0, A->bp - pos);
		}
	}
	bool worse = false;
	bool changed = false;
	if (has != A->pr_has) {
		changed = true;
		worse = has;
	} else if (has) {
		i64 pred = A->pr_pos - A->pr_v * (t - A->pr_t);
		if (pos > pred || v < A->pr_v) {
			worse = true;
		}
		if (pos != pred || v != A->pr_v) {
			changed = true;
		}
	}
	A->pr_has = has;
	A->pr_pos = pos;
	A->pr_t = t;
	A->pr_v = v;
	if (changed) {
		_wake_readers(A, worse, 0);
	}
}

void BeltSimNative::_wake_readers(Line *A, bool worse, int depth) {
	int back = A->lanes.back();
	// (Copies: waking only reschedules, but stay safe against the lists changing.)
	for (int f : l_feeders[back]) {
		_wake_one(l_line[f], worse, depth);
	}
	for (int f : l_sideins[back]) {
		_wake_one(l_line[f], worse, depth);
	}
	if (l_kind[back] == SPLIT_OUT) {
		std::vector<int> ins;
		_split_inputs_of(back, ins);
		for (int j : ins) {
			_wake_one(l_line[j], worse, depth);
		}
	}
}

void BeltSimNative::_wake_one(int id, bool worse, int depth) {
	if (id < 0) {
		return;
	}
	Line *R = _line(id);
	if (R == nullptr) {
		return;
	}
	if (R->uid.empty()) {
		if (depth < 12) {
			_wake_readers(R, worse, depth + 1);
		}
		return;
	}
	if (!worse && R->mode == 1) {
		return;
	}
	_wake(R);
}

// ---------------------------------------------------------------- records (output)

void BeltSimNative::_gone(i64 uid) {
	if (emit_changes) {
		out_gone.push_back(uid);
		out_gone_tick.push_back(_in_step ? _cur_t : tick);
		out_gone_at.push_back((int32_t)out_uid.size());
	}
}

void BeltSimNative::_emit_one(i64 uid, i64 item, i64 stack, int lane, i64 pos, i64 t, i64 v, i64 line_pos) {
	if (!emit_changes) {
		return;
	}
	out_uid.push_back(uid);
	out_item.push_back((int32_t)item);
	out_stack.push_back((int32_t)stack);
	out_key.push_back(l_key[lane]);
	out_pos.push_back((int32_t)pos);
	out_tick.push_back(t);
	out_speed.push_back((int32_t)v);
	out_reach.push_back((int32_t)(v > 0 ? line_pos : 0));
	out_run.push_back((int32_t)(v > 0 ? pos + ((l_kind[lane] == STRAIGHT && l_run[lane] >= 0) ? l_run[lane] : 0) : 0));
}

int BeltSimNative::_lane_at(Line *L, i64 pos) {
	if (L->lanes.size() == 1 || pos < 0) {
		return 0;
	}
	int k = upper_index(L->base, pos) - 1;
	return (int)clampi(k, 0, (i64)L->lanes.size() - 1);
}

void BeltSimNative::_rec_append(Line *X, int v) {
	int n = (int)X->uid.size() - 1;
	size_t r = X->rv.size();
	if (r > 0 && X->rv[r - 1] == v) {
		return;
	}
	X->rs.push_back(n);
	X->rv.push_back(v);
}

int BeltSimNative::_rec_index(Line *X, i64 j) {
	int k = upper_index(X->rs, j) - 1;
	return k > 0 ? k : 0;
}

void BeltSimNative::_rec_insert(Line *X, int j, int v) {
	int old_n = (int)X->uid.size() - 1;
	std::vector<int32_t> &nrs = _nrs;
	std::vector<int32_t> &nrv = _nrv;
	nrs.clear();
	nrv.clear();
	bool placed = false;
	size_t R = X->rs.size();
	for (size_t k = 0; k < R; k++) {
		int st = X->rs[k];
		int en = k + 1 < R ? X->rs[k + 1] : old_n;
		int vv = X->rv[k];
		if (en <= j) {
			nrs.push_back(st);
			nrv.push_back(vv);
		} else if (st >= j) {
			if (!placed) {
				nrs.push_back(j);
				nrv.push_back(v);
				placed = true;
			}
			nrs.push_back(st + 1);
			nrv.push_back(vv);
		} else {
			nrs.push_back(st);
			nrv.push_back(vv);
			nrs.push_back(j);
			nrv.push_back(v);
			nrs.push_back(j + 1);
			nrv.push_back(vv);
			placed = true;
		}
	}
	if (!placed) {
		nrs.push_back(j);
		nrv.push_back(v);
	}
	X->rs.swap(nrs);
	X->rv.swap(nrv);
	_rec_norm(X);
}

void BeltSimNative::_rec_remove(Line *X, int j) {
	std::vector<int32_t> &nrs = _nrs;
	std::vector<int32_t> &nrv = _nrv;
	nrs.clear();
	nrv.clear();
	int n = (int)X->uid.size();
	size_t R = X->rs.size();
	for (size_t k = 0; k < R; k++) {
		int st = X->rs[k];
		int en = k + 1 < R ? X->rs[k + 1] : n + 1;
		int ns = st <= j ? st : st - 1;
		int ne = en <= j ? en : en - 1;
		if (ne > ns) {
			nrs.push_back(ns);
			nrv.push_back(X->rv[k]);
		}
	}
	X->rs.swap(nrs);
	X->rv.swap(nrv);
	_rec_norm(X);
}

void BeltSimNative::_rec_set_one(Line *X, int j, int v) {
	int r = _rec_index(X, j);
	if (X->rv[r] == v) {
		return;
	}
	int st = X->rs[r];
	int en = (size_t)r + 1 < X->rs.size() ? X->rs[r + 1] : (int)X->uid.size();
	int old_v = X->rv[r];
	std::vector<int32_t> &nrs = _nrs;
	std::vector<int32_t> &nrv = _nrv;
	nrs.assign(X->rs.begin(), X->rs.begin() + r);
	nrv.assign(X->rv.begin(), X->rv.begin() + r);
	if (st < j) {
		nrs.push_back(st);
		nrv.push_back(old_v);
	}
	nrs.push_back(j);
	nrv.push_back(v);
	if (j + 1 < en) {
		nrs.push_back(j + 1);
		nrv.push_back(old_v);
	}
	nrs.insert(nrs.end(), X->rs.begin() + r + 1, X->rs.end());
	nrv.insert(nrv.end(), X->rv.begin() + r + 1, X->rv.end());
	X->rs.swap(nrs);
	X->rv.swap(nrv);
	_rec_norm(X);
}

void BeltSimNative::_rec_norm(Line *X) {
	int n = (int)X->uid.size();
	std::vector<int32_t> &rs = X->rs;
	std::vector<int32_t> &rv = X->rv;
	// In place: the write index never passes the read index.
	size_t w = 0;
	for (size_t k = 0; k < rs.size(); k++) {
		int st = rs[k];
		if (st >= n) {
			break;
		}
		if (w > 0 && rv[w - 1] == rv[k]) {
			continue;
		}
		if (w > 0 && rs[w - 1] == st) {
			rv[w - 1] = rv[k];
			continue;
		}
		rs[w] = st;
		rv[w] = rv[k];
		w += 1;
	}
	rs.resize(w);
	rv.resize(w);
	if (w == 0 && n > 0) {
		rs.push_back(0);
		rv.push_back(-1);
	} else if (w > 0) {
		rs[0] = 0;
	}
}

void BeltSimNative::_emit_head(Line *A, i64 t, int h) {
	for (int k = 0; k < h; k++) {
		if (!head_move) {
			// (As before: the step it was given, items that left not emitted.)
			if (_keep[k] == 0) {
				continue;
			}
			int r = _rec_index(A, k);
			if (A->rv[r] != _hm[k]) {
				int li = _lane_at(A, _hp[k]);
				_emit_one(A->uid[k], A->itm[k], A->stk[k], A->lanes[li], (i64)_hp[k] - A->base[li], t - 1, _hm[k], _hp[k]);
				_rec_set_one(A, k, _hm[k]);
			}
			continue;
		}
		_emit_left(A, k, t);
	}
}

// (The move is where it went, hn, not the step it was given: waiting items move less. Items that
// leave the line too, emitted before they go: as far as its exit.)
void BeltSimNative::_emit_left(Line *A, int k, i64 t) {
	int32_t m = _hp[k] - _hn[k];
	int r = _rec_index(A, k);
	if (m < 0) {
		// Pushed back (a gap behind an item waiting at a splitter or side-load): standing where it went.
		int lb = _lane_at(A, _hn[k]);
		_emit_one(A->uid[k], A->itm[k], A->stk[k], A->lanes[lb], (i64)_hn[k] - A->base[lb], t, 0, _hn[k]);
		_rec_set_one(A, k, 0);
		return;
	}
	if (A->rv[r] != m) {
		int li = _lane_at(A, _hp[k]);
		int lane = A->lanes[li];
		_emit_one(A->uid[k], A->itm[k], A->stk[k], lane, (i64)_hp[k] - A->base[li], t - 1, m, _hp[k]);
		_rec_set_one(A, k, m);
	}
}

void BeltSimNative::_emit_tail(Line *A, i64 t, int hk) {
	if (_seg_i.empty()) {
		return;
	}
	i64 n = (i64)A->uid.size();
	int h_old = _seg_i[0];
	int removed_shift = h_old - hk;
	i64 pos = -1;
	i64 pos_i = -1;
	for (size_t si = 0; si < _seg_i.size(); si++) {
		i64 a = _seg_i[si] - removed_shift;
		i64 b = si + 1 < _seg_i.size() ? (i64)(_seg_i[si + 1] - removed_shift) : n;
		if (A->arr_tick == t) {
			b = mini(b, n - A->arr);
		}
		i64 v = _seg_v[si];
		if (a >= b) {
			continue;
		}
		int r = _rec_index(A, a);
		i64 j = a;
		bool differs = false;
		while (j < b) {
			i64 en = (size_t)r + 1 < A->rs.size() ? (i64)A->rs[r + 1] : n;
			i64 e2 = mini(en, b);
			if (A->rv[r] != v) {
				differs = true;
				if (pos_i < 0 || pos_i > j) {
					pos = A->f;
					pos_i = 0;
				}
				while (pos_i < j) {
					pos_i += 1;
					pos += A->gap[pos_i];
				}
				i64 q = pos;
				i64 qi = pos_i;
				while (qi < e2) {
					i64 old = q + v;
					int li = _lane_at(A, old);
					int lane = A->lanes[li];
					_emit_one(A->uid[qi], A->itm[qi], A->stk[qi], lane, old - A->base[li], t - 1, v, old);
					qi += 1;
					if (qi < n) {
						q += A->gap[qi];
					}
				}
			}
			j = e2;
			r += 1;
		}
		if (differs) {
			_rec_set_range(A, (int)a, (int)b, (int)v);
		}
	}
}

void BeltSimNative::_rec_set_range(Line *X, int a, int b, int v) {
	if (a >= b) {
		return;
	}
	int n = (int)X->uid.size();
	std::vector<int32_t> &nrs = _nrs;
	std::vector<int32_t> &nrv = _nrv;
	nrs.clear();
	nrv.clear();
	bool placed = false;
	size_t R = X->rs.size();
	for (size_t k = 0; k < R; k++) {
		int st = X->rs[k];
		int en = k + 1 < R ? X->rs[k + 1] : n;
		if (en <= a || st >= b) {
			if (st >= b && !placed) {
				nrs.push_back(a);
				nrv.push_back(v);
				placed = true;
			}
			nrs.push_back(st);
			nrv.push_back(X->rv[k]);
			continue;
		}
		if (st < a) {
			nrs.push_back(st);
			nrv.push_back(X->rv[k]);
		}
		if (!placed) {
			nrs.push_back(a);
			nrv.push_back(v);
			placed = true;
		}
		if (en > b) {
			nrs.push_back(b);
			nrv.push_back(X->rv[k]);
		}
	}
	if (!placed) {
		nrs.push_back(a);
		nrv.push_back(v);
	}
	X->rs.swap(nrs);
	X->rv.swap(nrv);
	_rec_norm(X);
}

void BeltSimNative::_emit_pattern(Line *A, i64 t, int v) {
	_emit_range_if(A, t, 0, (i64)A->uid.size(), v);
}

void BeltSimNative::_emit_pattern2(Line *A, i64 t, i64 ck) {
	_emit_range_if(A, t, 0, ck, 0);
	_emit_range_if(A, t, ck, (i64)A->uid.size(), A->s);
}

void BeltSimNative::_emit_range_if(Line *A, i64 t, i64 a, i64 b, i64 v) {
	if (a >= b || (A->rv.size() == 1 && A->rv[0] == v)) {
		return;
	}
	i64 n = (i64)A->uid.size();
	int r = _rec_index(A, a);
	i64 j = a;
	i64 pos = A->f;
	i64 pi = 0;
	bool any = false;
	while (j < b) {
		i64 en = (size_t)r + 1 < A->rs.size() ? (i64)A->rs[r + 1] : n;
		i64 e2 = mini(en, b);
		if (A->rv[r] != v) {
			any = true;
			while (pi < j) {
				pi += 1;
				pos += A->gap[pi];
			}
			i64 q = pos;
			i64 qi = pi;
			while (qi < e2) {
				int li = _lane_at(A, q);
				_emit_one(A->uid[qi], A->itm[qi], A->stk[qi], A->lanes[li], q - A->base[li], t, v, q);
				qi += 1;
				if (qi < n) {
					q += A->gap[qi];
				}
			}
		}
		j = e2;
		r += 1;
	}
	if (any) {
		_rec_set_range(A, (int)a, (int)b, (int)v);
	}
}

Dictionary BeltSimNative::debug_links() {
	_relink();
	i64 nxt = 0, side = 0, split = 0, none = 0;
	for (size_t i = 0; i < l_key.size(); i++) {
		if (l_alive[i] == 0) {
			continue;
		}
		if (l_next[i] >= 0) {
			nxt += 1;
		} else if (l_side[i] >= 0) {
			side += 1;
		} else if (l_kind[i] == SPLIT_IN) {
			split += 1;
		} else {
			none += 1;
		}
	}
	Dictionary d;
	d["next"] = nxt;
	d["side"] = side;
	d["split"] = split;
	d["none"] = none;
	return d;
}

Dictionary BeltSimNative::debug_item(i64 uid) {
	auto it = _uid_line.find(uid);
	if (it == _uid_line.end() || it->second < 0) {
		return Dictionary();
	}
	Line *L = _line(it->second);
	if (L == nullptr) {
		return Dictionary();
	}
	PackedInt64Array keys;
	for (int x : L->lanes) {
		keys.append(l_key[x]);
	}
	PackedInt32Array base;
	for (int b : L->base) {
		base.append(b);
	}
	PackedInt32Array gap;
	for (int32_t g : L->gap) {
		gap.append(g);
	}
	PackedInt64Array uids;
	for (i64 u : L->uid) {
		uids.append(u);
	}
	Array pr;
	pr.append(L->pr_has);
	pr.append(L->pr_pos);
	pr.append(L->pr_t);
	pr.append(L->pr_v);
	Dictionary d;
	d["lanes"] = keys;
	d["base"] = base;
	d["mode"] = L->mode;
	d["due"] = L->due;
	d["ft"] = L->ft;
	d["f"] = L->f;
	d["span"] = L->span;
	d["gap"] = gap;
	d["uid"] = uids;
	d["lp"] = L->lp;
	d["ck"] = L->ck;
	d["ord"] = L->ord;
	d["pr"] = pr;
	d["done"] = L->done_tick;
	return d;
}

PackedInt64Array BeltSimNative::get_prof() const {
	PackedInt64Array a;
	for (i64 v : prof) {
		a.append(v);
	}
	return a;
}

void BeltSimNative::set_prof(const PackedInt64Array &a) {
	for (int k = 0; k < 8; k++) {
		prof[k] = k < a.size() ? a[k] : 0;
	}
}

PackedInt64Array BeltSimNative::get_why_tick() const {
	PackedInt64Array a;
	for (i64 v : why_tick) {
		a.append(v);
	}
	return a;
}

void BeltSimNative::set_why_tick(const PackedInt64Array &a) {
	for (int k = 0; k < 10; k++) {
		why_tick[k] = k < a.size() ? a[k] : 0;
	}
}

PackedInt64Array BeltSimNative::get_step_us() const {
	PackedInt64Array a;
	a.append(step_us[0]);
	a.append(step_us[1]);
	return a;
}

void BeltSimNative::set_step_us(const PackedInt64Array &a) {
	step_us[0] = a.size() > 0 ? a[0] : 0;
	step_us[1] = a.size() > 1 ? a[1] : 0;
}

void BeltSimNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_lane", "key", "kind", "length", "step", "p0", "pm", "p1", "extra", "next_key"),
			&BeltSimNative::set_lane, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("set_lane_at", "at_tick", "key", "kind", "length", "step", "p0", "pm", "p1", "extra", "next_key",
			"out_edge"), &BeltSimNative::set_lane_at);
	ClassDB::bind_method(D_METHOD("drop_lane", "key"), &BeltSimNative::drop_lane);
	ClassDB::bind_method(D_METHOD("load_lane", "key", "at_tick", "items"), &BeltSimNative::load_lane);
	ClassDB::bind_method(D_METHOD("check_lane", "key", "at_tick", "count", "front", "back", "front_uid", "back_uid"), &BeltSimNative::check_lane, DEFVAL(0), DEFVAL(0));
	ClassDB::bind_method(D_METHOD("set_out_edge", "key", "on"), &BeltSimNative::set_out_edge);
	ClassDB::bind_method(D_METHOD("set_wall", "key", "at_tick", "uid", "pos"), &BeltSimNative::set_wall);
	ClassDB::bind_method(D_METHOD("set_off", "unit", "off", "at_tick"), &BeltSimNative::set_off, DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("step_to", "to_tick"), &BeltSimNative::step_to);
	ClassDB::bind_method(D_METHOD("skip_to", "to_tick"), &BeltSimNative::skip_to);
	ClassDB::bind_method(D_METHOD("run_of", "key"), &BeltSimNative::run_of);
	ClassDB::bind_method(D_METHOD("put_item", "key", "uid", "item", "stack", "pos"), &BeltSimNative::put_item);
	ClassDB::bind_method(D_METHOD("take_item", "uid", "gone"), &BeltSimNative::take_item, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("take_changes"), &BeltSimNative::take_changes);
	ClassDB::bind_method(D_METHOD("next_of", "key"), &BeltSimNative::next_of);
	ClassDB::bind_method(D_METHOD("items_state"), &BeltSimNative::items_state);
	ClassDB::bind_method(D_METHOD("lane_fronts", "keys"), &BeltSimNative::lane_fronts);
	ClassDB::bind_method(D_METHOD("stats"), &BeltSimNative::stats);
	ClassDB::bind_method(D_METHOD("mark_split_holds"), &BeltSimNative::mark_split_holds);
	ClassDB::bind_method(D_METHOD("debug_links"), &BeltSimNative::debug_links);
	ClassDB::bind_method(D_METHOD("debug_item", "uid"), &BeltSimNative::debug_item);

	ClassDB::bind_method(D_METHOD("set_edge_mode", "v"), &BeltSimNative::set_edge_mode);
	ClassDB::bind_method(D_METHOD("get_edge_mode"), &BeltSimNative::get_edge_mode);
	ClassDB::bind_method(D_METHOD("set_oracle", "v"), &BeltSimNative::set_oracle);
	ClassDB::bind_method(D_METHOD("get_oracle"), &BeltSimNative::get_oracle);
	ClassDB::bind_method(D_METHOD("set_given", "v"), &BeltSimNative::set_given);
	ClassDB::bind_method(D_METHOD("get_given"), &BeltSimNative::get_given);
	ClassDB::bind_method(D_METHOD("set_emit_changes", "v"), &BeltSimNative::set_emit_changes);
	ClassDB::bind_method(D_METHOD("get_emit_changes"), &BeltSimNative::get_emit_changes);
	ClassDB::bind_method(D_METHOD("set_ask_on_link", "v"), &BeltSimNative::set_ask_on_link);
	ClassDB::bind_method(D_METHOD("get_ask_on_link"), &BeltSimNative::get_ask_on_link);
	ClassDB::bind_method(D_METHOD("set_head_move", "v"), &BeltSimNative::set_head_move);
	ClassDB::bind_method(D_METHOD("get_head_move"), &BeltSimNative::get_head_move);
	ClassDB::bind_method(D_METHOD("set_tick", "v"), &BeltSimNative::set_tick);
	ClassDB::bind_method(D_METHOD("get_tick"), &BeltSimNative::get_tick);
	ClassDB::bind_method(D_METHOD("set_n_shifted", "v"), &BeltSimNative::set_n_shifted);
	ClassDB::bind_method(D_METHOD("get_n_shifted"), &BeltSimNative::get_n_shifted);
	ClassDB::bind_method(D_METHOD("set_read_bound", "v"), &BeltSimNative::set_read_bound);
	ClassDB::bind_method(D_METHOD("get_read_bound"), &BeltSimNative::get_read_bound);
	ClassDB::bind_method(D_METHOD("set_read_conserve", "v"), &BeltSimNative::set_read_conserve);
	ClassDB::bind_method(D_METHOD("get_read_conserve"), &BeltSimNative::get_read_conserve);
	ClassDB::bind_method(D_METHOD("set_read_forward", "v"), &BeltSimNative::set_read_forward);
	ClassDB::bind_method(D_METHOD("get_read_forward"), &BeltSimNative::get_read_forward);
	ClassDB::bind_method(D_METHOD("set_n_forward", "v"), &BeltSimNative::set_n_forward);
	ClassDB::bind_method(D_METHOD("get_n_forward"), &BeltSimNative::get_n_forward);
	ClassDB::bind_method(D_METHOD("set_n_forward_gone", "v"), &BeltSimNative::set_n_forward_gone);
	ClassDB::bind_method(D_METHOD("get_n_forward_gone"), &BeltSimNative::get_n_forward_gone);
	ClassDB::bind_method(D_METHOD("set_read_skip_same", "v"), &BeltSimNative::set_read_skip_same);
	ClassDB::bind_method(D_METHOD("get_read_skip_same"), &BeltSimNative::get_read_skip_same);
	ClassDB::bind_method(D_METHOD("set_n_same", "v"), &BeltSimNative::set_n_same);
	ClassDB::bind_method(D_METHOD("get_n_same"), &BeltSimNative::get_n_same);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "read_skip_same"), "set_read_skip_same", "get_read_skip_same");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "n_same"), "set_n_same", "get_n_same");
	ClassDB::bind_method(D_METHOD("set_shift_keep", "v"), &BeltSimNative::set_shift_keep);
	ClassDB::bind_method(D_METHOD("get_shift_keep"), &BeltSimNative::get_shift_keep);
	ClassDB::bind_method(D_METHOD("set_split_wake", "v"), &BeltSimNative::set_split_wake);
	ClassDB::bind_method(D_METHOD("get_split_wake"), &BeltSimNative::get_split_wake);
	ClassDB::bind_method(D_METHOD("set_n_woke", "v"), &BeltSimNative::set_n_woke);
	ClassDB::bind_method(D_METHOD("get_n_woke"), &BeltSimNative::get_n_woke);
	ClassDB::bind_method(D_METHOD("set_hold_inputs", "v"), &BeltSimNative::set_hold_inputs);
	ClassDB::bind_method(D_METHOD("get_hold_inputs"), &BeltSimNative::get_hold_inputs);
	ClassDB::bind_method(D_METHOD("set_n_held", "v"), &BeltSimNative::set_n_held);
	ClassDB::bind_method(D_METHOD("get_n_held"), &BeltSimNative::get_n_held);
	ClassDB::bind_method(D_METHOD("hold_input", "key", "at_tick", "items"), &BeltSimNative::hold_input, DEFVAL(PackedInt64Array()));
	ClassDB::bind_method(D_METHOD("set_n_past_back", "v"), &BeltSimNative::set_n_past_back);
	ClassDB::bind_method(D_METHOD("get_n_past_back"), &BeltSimNative::get_n_past_back);
	ClassDB::bind_method(D_METHOD("set_n_carried", "v"), &BeltSimNative::set_n_carried);
	ClassDB::bind_method(D_METHOD("get_n_carried"), &BeltSimNative::get_n_carried);
	ClassDB::bind_method(D_METHOD("set_n_line_steps", "v"), &BeltSimNative::set_n_line_steps);
	ClassDB::bind_method(D_METHOD("get_n_line_steps"), &BeltSimNative::get_n_line_steps);
	ClassDB::bind_method(D_METHOD("set_profile", "v"), &BeltSimNative::set_profile);
	ClassDB::bind_method(D_METHOD("get_profile"), &BeltSimNative::get_profile);
	ClassDB::bind_method(D_METHOD("set_prof", "v"), &BeltSimNative::set_prof);
	ClassDB::bind_method(D_METHOD("get_prof"), &BeltSimNative::get_prof);
	ClassDB::bind_method(D_METHOD("set_step_us", "v"), &BeltSimNative::set_step_us);
	ClassDB::bind_method(D_METHOD("get_step_us"), &BeltSimNative::get_step_us);
	ClassDB::bind_method(D_METHOD("set_why_tick", "v"), &BeltSimNative::set_why_tick);
	ClassDB::bind_method(D_METHOD("get_why_tick"), &BeltSimNative::get_why_tick);
	ClassDB::bind_method(D_METHOD("set_us_relink", "v"), &BeltSimNative::set_us_relink);
	ClassDB::bind_method(D_METHOD("get_us_relink"), &BeltSimNative::get_us_relink);
	ClassDB::bind_method(D_METHOD("set_us_queue", "v"), &BeltSimNative::set_us_queue);
	ClassDB::bind_method(D_METHOD("get_us_queue"), &BeltSimNative::get_us_queue);
	ClassDB::bind_method(D_METHOD("set_us_step", "v"), &BeltSimNative::set_us_step);
	ClassDB::bind_method(D_METHOD("get_us_step"), &BeltSimNative::get_us_step);
	ClassDB::bind_method(D_METHOD("set_why_mark", "v"), &BeltSimNative::set_why_mark);
	ClassDB::bind_method(D_METHOD("get_why_mark"), &BeltSimNative::get_why_mark);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "edge_mode"), "set_edge_mode", "get_edge_mode");
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "oracle"), "set_oracle", "get_oracle");
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "given"), "set_given", "get_given");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "emit_changes"), "set_emit_changes", "get_emit_changes");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "ask_on_link"), "set_ask_on_link", "get_ask_on_link");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "head_move"), "set_head_move", "get_head_move");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "tick"), "set_tick", "get_tick");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "n_line_steps"), "set_n_line_steps", "get_n_line_steps");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "n_shifted"), "set_n_shifted", "get_n_shifted");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "read_bound"), "set_read_bound", "get_read_bound");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "read_conserve"), "set_read_conserve", "get_read_conserve");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "read_forward"), "set_read_forward", "get_read_forward");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "n_forward"), "set_n_forward", "get_n_forward");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "n_forward_gone"), "set_n_forward_gone", "get_n_forward_gone");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "shift_keep"), "set_shift_keep", "get_shift_keep");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "hold_inputs"), "set_hold_inputs", "get_hold_inputs");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "split_wake"), "set_split_wake", "get_split_wake");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "n_woke"), "set_n_woke", "get_n_woke");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "n_held"), "set_n_held", "get_n_held");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "n_past_back"), "set_n_past_back", "get_n_past_back");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "n_carried"), "set_n_carried", "get_n_carried");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "profile"), "set_profile", "get_profile");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_INT64_ARRAY, "prof"), "set_prof", "get_prof");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_INT64_ARRAY, "step_us"), "set_step_us", "get_step_us");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_INT64_ARRAY, "why_tick"), "set_why_tick", "get_why_tick");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "us_relink"), "set_us_relink", "get_us_relink");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "us_queue"), "set_us_queue", "get_us_queue");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "us_step"), "set_us_step", "get_us_step");
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "why_mark"), "set_why_mark", "get_why_mark");

	const StringName cls = get_class_static();
	ClassDB::bind_integer_constant(cls, "", "GAP", GAP);
	ClassDB::bind_integer_constant(cls, "", "SPLIT_BUFFER", SPLIT_BUFFER);
	ClassDB::bind_integer_constant(cls, "", "STRAIGHT", STRAIGHT);
	ClassDB::bind_integer_constant(cls, "", "CURVE", CURVE);
	ClassDB::bind_integer_constant(cls, "", "UG_VISIBLE", UG_VISIBLE);
	ClassDB::bind_integer_constant(cls, "", "UG_HIDDEN", UG_HIDDEN);
	ClassDB::bind_integer_constant(cls, "", "SPLIT_IN", SPLIT_IN);
	ClassDB::bind_integer_constant(cls, "", "SPLIT_OUT", SPLIT_OUT);
	ClassDB::bind_integer_constant(cls, "", "LOADER", LOADER);
	ClassDB::bind_integer_constant(cls, "", "OTHER", OTHER);
	ClassDB::bind_integer_constant(cls, "", "EDGE_RUN_OFF", EDGE_RUN_OFF);
	ClassDB::bind_integer_constant(cls, "", "EDGE_STOP", EDGE_STOP);
	ClassDB::bind_integer_constant(cls, "", "EDGE_ORACLE", EDGE_ORACLE);
}
