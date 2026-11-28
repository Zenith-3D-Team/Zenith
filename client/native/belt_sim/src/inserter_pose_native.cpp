#include "inserter_pose_native.h"
#include "inserter_arms_native.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

int InserterPoseNative::add_arm() {
	int s;
	if (!free_slots.empty()) {
		s = free_slots.back();
		free_slots.pop_back();
		uint32_t gen = slots[s].gen + 1;
		slots[s] = Slot();
		slots[s].gen = gen;
	} else {
		s = (int)slots.size();
		slots.emplace_back();
	}
	slots[s].used = true;
	return s;
}

void InserterPoseNative::remove_arm(int slot) {
	if (!valid(slot)) {
		return;
	}
	// (Its queued preplans stay in the queue, dead, as the GDScript's Arm objects do: they count against a
	// frame's share there too.)
	uint32_t gen = slots[slot].gen + 1;
	slots[slot] = Slot();
	slots[slot].gen = gen;
	free_slots.push_back(slot);
}

void InserterPoseNative::clear() {
	slots.clear();
	free_slots.clear();
	preplan.clear();
}

void InserterPoseNative::set_base(int slot, const Vector2 &base) {
	if (valid(slot)) {
		slots[slot].base = base;
	}
}

void InserterPoseNative::set_ends(int slot, double pick_a, double pick_r, double drop_a, double drop_r, double omega, double v, bool belt_pick) {
	if (!valid(slot)) {
		return;
	}
	Slot &a = slots[slot];
	a.ends_tried = true;
	a.pick = { true, pick_a, pick_r };
	a.drop = { true, drop_a, drop_r };
	a.omega = omega;
	a.v = v;
	a.belt_pick = belt_pick;
}

bool InserterPoseNative::add_sample(int slot, double k, double ang, double r, int item, bool queue) {
	if (!valid(slot)) {
		return false;
	}
	Slot &a = slots[slot];
	size_t n = a.ticks.size();
	if (n > 0 && k <= a.ticks[n - 1]) {
		return false;
	}
	bool clear = zswing::on_side(ang, a.pick, a.drop);
	// (Arm.add_sample)
	a.ticks.push_back(k);
	a.angles.push_back((float)ang);
	a.reaches.push_back((float)r);
	a.items.push_back(item);
	a.side_out.push_back(clear && item != 0 ? (float)ang : (n > 0 ? a.side_out[n - 1] : NAN));
	a.side_any.push_back(clear ? (float)ang : (n > 0 ? a.side_any[n - 1] : NAN));
	if (item != 0) {
		a.last_item = item;
	}
	size_t drop = 0;
	while (a.ticks.size() - drop > 1 && a.ticks[drop] < k - RING_TICKS) {
		a.plans.erase(a.ticks[drop]);
		drop++;
	}
	if (drop > 0) {
		a.ticks.erase(a.ticks.begin(), a.ticks.begin() + drop);
		a.angles.erase(a.angles.begin(), a.angles.begin() + drop);
		a.reaches.erase(a.reaches.begin(), a.reaches.begin() + drop);
		a.items.erase(a.items.begin(), a.items.begin() + drop);
		a.side_out.erase(a.side_out.begin(), a.side_out.begin() + drop);
		a.side_any.erase(a.side_any.begin(), a.side_any.begin() + drop);
	}
	// (_add_sample)
	if (clear) {
		a.side = ang;
	}
	// (_update) Into the preplan queue.
	if (queue && a.ticks.size() >= 2 && !a.preplanned) {
		a.preplanned = true;
		preplan.push_back({ slot, a.gen });
	}
	return true;
}

bool InserterPoseNative::add_event(int slot, double k, int kind, int count, int item, int c, double x, double y, int belt) {
	if (!valid(slot)) {
		return false;
	}
	Slot &a = slots[slot];
	size_t n = a.ev_ticks.size();
	size_t i = n;
	while (i > 0 && a.ev_ticks[i - 1] >= k) {
		if (a.ev_ticks[i - 1] == k && a.ev_kind[i - 1] == kind && a.ev_count[i - 1] == count) {
			return false;
		}
		i--;
	}
	int code = i > 0 ? a.ev_code[i - 1] : 0;
	if (kind == zswing::STATUS || kind == zswing::SYNC) {
		code = c;
	}
	a.ev_ticks.insert(a.ev_ticks.begin() + i, k);
	a.ev_kind.insert(a.ev_kind.begin() + i, kind);
	a.ev_count.insert(a.ev_count.begin() + i, count);
	a.ev_item.insert(a.ev_item.begin() + i, item);
	a.ev_c.insert(a.ev_c.begin() + i, c);
	a.ev_x.insert(a.ev_x.begin() + i, (float)x);
	a.ev_y.insert(a.ev_y.begin() + i, (float)y);
	a.ev_belt.insert(a.ev_belt.begin() + i, belt);
	a.ev_code.insert(a.ev_code.begin() + i, code);
	uint8_t starts = kind == zswing::PICKED && (i == 0 || a.ev_count[i - 1] == 0) ? 1 : 0;
	a.ev_start.insert(a.ev_start.begin() + i, starts);
	a.cycles += starts;
	if (i < n) {
		for (size_t j = i + 1; j < n + 1; j++) {
			if (a.ev_kind[j] != zswing::STATUS && a.ev_kind[j] != zswing::SYNC) {
				a.ev_code[j] = a.ev_code[j - 1];
			}
		}
	}
	if (item != 0 && count > 0) {
		a.last_item = item;
	}
	while (a.ev_ticks.size() > 2 && a.ev_ticks[0] < k - RING_TICKS && a.cycles > KEEP_CYCLES) {
		a.cycles -= a.ev_start[0];
		a.ev_start.erase(a.ev_start.begin());
		a.ev_ticks.erase(a.ev_ticks.begin());
		a.ev_kind.erase(a.ev_kind.begin());
		a.ev_count.erase(a.ev_count.begin());
		a.ev_item.erase(a.ev_item.begin());
		a.ev_c.erase(a.ev_c.begin());
		a.ev_x.erase(a.ev_x.begin());
		a.ev_y.erase(a.ev_y.begin());
		a.ev_belt.erase(a.ev_belt.begin());
		a.ev_code.erase(a.ev_code.begin());
	}
	return true;
}

void InserterPoseNative::backdate(int slot, double k) {
	if (!valid(slot)) {
		return;
	}
	Slot &a = slots[slot];
	int n = (int)a.ev_ticks.size();
	int i = (int)(std::lower_bound(a.ev_ticks.begin(), a.ev_ticks.end(), k) - a.ev_ticks.begin());
	while (i < n && a.ev_ticks[i] == k && a.ev_kind[i] != zswing::PICKED && a.ev_kind[i] != zswing::DROPPED) {
		i++;
	}
	if (i >= n || a.ev_ticks[i] != k) {
		return;
	}
	int j = i - 1;
	while (j >= 0 && a.ev_kind[j] != zswing::PICKED && a.ev_kind[j] != zswing::DROPPED) {
		j--;
	}
	if (j < 0 || a.ev_c[j] <= 0 || std::isnan(a.ev_x[j]) || std::isnan(a.ev_x[i])) {
		return;
	}
	Vector2 from = Vector2(a.ev_x[j], a.ev_y[j]) - a.base;
	Vector2 to = Vector2(a.ev_x[i], a.ev_y[i]) - a.base;
	int t = zswing::travel_ticks(zswing::delta((double)from.angle(), (double)to.angle(), a.side),
			(double)to.length() - (double)from.length(), a.omega, a.v);
	double kj = a.ev_ticks[j];
	double moved = zswing::clampf(k - t, kj - a.ev_c[j], kj);
	a.ev_c[j] = 0;
	if (moved < kj && (j == 0 || a.ev_ticks[j - 1] < moved)) {
		a.ev_ticks[j] = moved;
	}
}

double InserterPoseNative::side_at(const Slot &a, int i) const {
	if (!std::isnan(a.side_out[i])) {
		return a.side_out[i];
	}
	return !std::isnan(a.side_any[i]) ? (double)a.side_any[i] : a.side;
}

zswing::Plan InserterPoseNative::plan_pair(Slot &a, int i, double reach_slack) {
	double side = side_at(a, i);
	zswing::Plan plan = zswing::plan(a.ticks[i], a.angles[i], a.reaches[i], a.items[i], a.ticks[i + 1], a.angles[i + 1],
			a.reaches[i + 1], a.items[i + 1], a.pick, a.drop, a.omega, a.v, side, a.belt_pick, a.last_item, reach_slack);
	if (std::isnan(side) && std::isnan(a.side) && plan.size() >= 2) {
		const zswing::Key &first = plan[0];
		const zswing::Key &last = plan.back();
		if (std::fabs(last.a - first.a) > zswing::AMBIGUOUS) {
			a.side = zswing::wrapf((first.a + last.a) * 0.5, -zswing::PI, zswing::PI);
		}
	}
	return plan;
}

void InserterPoseNative::preplan_some(double reach_slack) {
	int size = (int)preplan.size();
	int n = std::min(size, std::max(PREPLAN_MIN, size / 4));
	for (int q = 0; q < n; q++) {
		Queued e = preplan.front();
		preplan.pop_front();
		if (!valid(e.slot) || slots[e.slot].gen != e.gen) {
			continue;  // (gone since: the GDScript plans a dropped arm's pair, which nothing draws)
		}
		Slot &a = slots[e.slot];
		a.preplanned = false;
		int m = (int)a.ticks.size();
		if (m < 2 || !a.ends_tried) {
			continue;
		}
		double ka = a.ticks[m - 2];
		if (a.plans.find(ka) == a.plans.end()) {
			a.plans[ka] = plan_pair(a, m - 2, reach_slack);
		}
	}
}

bool InserterPoseNative::item_from_events(const Slot &a, double t, int &item, int &count) const {
	int n = (int)a.ev_ticks.size();
	if (n == 0 || t < a.ev_ticks[0]) {
		return false;
	}
	int i = (int)(std::upper_bound(a.ev_ticks.begin(), a.ev_ticks.end(), t) - a.ev_ticks.begin()) - 1;
	if (a.ev_kind[i] == zswing::GONE) {
		return false;
	}
	int j = i + 1;
	while (j < n && a.ev_kind[j] != zswing::PICKED && a.ev_kind[j] != zswing::DROPPED) {
		j++;
	}
	if (j < n && a.ev_c[j] > 0 && t >= a.ev_ticks[j] - a.ev_c[j]) {
		return false;
	}
	item = a.ev_count[i] > 0 ? a.ev_item[i] : 0;
	count = item > 0 ? a.ev_count[i] : 0;
	return true;
}

int InserterPoseNative::count_for_sample(const Slot &a, double t, int sample_item) const {
	if (sample_item <= 0) {
		return 0;
	}
	int n = (int)a.ev_ticks.size();
	if (n == 0 || t < a.ev_ticks[0]) {
		return 1;
	}
	int i = (int)(std::upper_bound(a.ev_ticks.begin(), a.ev_ticks.end(), t) - a.ev_ticks.begin()) - 1;
	if (a.ev_kind[i] == zswing::GONE) {
		return 1;
	}
	if (a.ev_count[i] > 0 && a.ev_item[i] == sample_item) {
		return a.ev_count[i];
	}
	int j = i + 1;
	while (j < n && a.ev_kind[j] != zswing::PICKED && a.ev_kind[j] != zswing::DROPPED) {
		j++;
	}
	if (j < n && a.ev_c[j] > 0 && t >= a.ev_ticks[j] - a.ev_c[j] && a.ev_count[j] > 0 && a.ev_item[j] == sample_item) {
		return a.ev_count[j];
	}
	return 1;
}

uint8_t InserterPoseNative::pose_slot(Slot &a, double t, bool items_from_events, double reach_slack, double &oa, double &orr, int &oi, int &oc) {
	int n = (int)a.ticks.size();
	if (!a.used || n == 0) {
		return 0;
	}
	int item = 0;
	int cnt = 0;
	if (t < a.plan_still_until && t >= a.plan_ka) {
		// Standing: the pose set when the plan was made holds.
		if (items_from_events && item_from_events(a, t, item, cnt)) {
			oi = item;
			oc = cnt;
			return 2;
		}
		return 0;
	}
	double pa, pr;
	int pi;
	if (t <= a.ticks[0]) {
		pa = a.angles[0];
		pr = a.reaches[0];
		pi = a.items[0];
	} else {
		int i = (int)(std::lower_bound(a.ticks.begin(), a.ticks.end(), t) - a.ticks.begin());
		int k = i < n && a.ticks[i] == t ? i : i - 1;
		if (k >= n - 1) {
			bool still = n >= 2 && (double)zswing::hand_pos(a.angles[n - 2], a.reaches[n - 2]).distance_to(
					zswing::hand_pos(a.angles[n - 1], a.reaches[n - 1])) < zswing::STILL;
			zswing::extrapolate(a.angles[n - 1], a.reaches[n - 1], a.items[n - 1], still, a.pick, a.drop, a.omega, a.v, a.side,
					t - a.ticks[n - 1], pa, pr, pi);
		} else {
			if (a.plan_ka != a.ticks[k] || a.plan.empty()) {
				auto it = a.plans.find(a.ticks[k]);
				if (it != a.plans.end()) {
					a.plan = it->second;
				} else {
					a.plan.clear();
				}
				if (a.plan.empty()) {
					a.plan = plan_pair(a, k, reach_slack);
				}
				a.plan_ka = a.ticks[k];
				const zswing::Key &k0 = a.plan[0];
				const zswing::Key &kn = a.plan.back();
				a.plan_still_until = a.plan.size() == 2 && k0.a == kn.a && k0.r == kn.r && k0.item == kn.item ? kn.k : -1.0;
			}
			zswing::at(a.plan, t, pa, pr, pi);
		}
	}
	oa = zswing::wrapf(pa, -zswing::PI, zswing::PI);
	orr = pr;
	oi = pi;
	if (items_from_events) {
		if (item_from_events(a, t, item, cnt)) {
			oi = item;
			oc = cnt;
		} else {
			oc = count_for_sample(a, t, oi);
		}
	} else {
		oc = oi > 0 ? 1 : 0;
	}
	return 1;
}

int InserterPoseNative::pose_all(double t, bool items_from_events, double reach_slack) {
	int64_t count = (int64_t)slots.size();
	if (out_flags.size() != count) {
		out_angles.resize(count);
		out_reaches.resize(count);
		out_items.resize(count);
		out_counts.resize(count);
		out_flags.resize(count);
	}
	double *oa = out_angles.ptrw();
	double *orr = out_reaches.ptrw();
	int32_t *oi = out_items.ptrw();
	int32_t *oc = out_counts.ptrw();
	uint8_t *of = out_flags.ptrw();
	int posed = 0;
	for (int s = 0; s < (int)count; s++) {
		int item = oi[s];
		int cnt = oc[s];
		of[s] = pose_slot(slots[s], t, items_from_events, reach_slack, oa[s], orr[s], item, cnt);
		oi[s] = item;
		oc[s] = cnt;
		posed += of[s] == 1 ? 1 : 0;
	}
	return posed;
}

PackedFloat64Array InserterPoseNative::pose_one(int slot, double t, bool items_from_events, double reach_slack) {
	PackedFloat64Array out;
	out.resize(5);
	double a = 0.0, r = 0.0;
	int item = 0, cnt = 0;
	uint8_t f = valid(slot) ? pose_slot(slots[slot], t, items_from_events, reach_slack, a, r, item, cnt) : 0;
	out.set(0, (double)f);
	out.set(1, a);
	out.set(2, r);
	out.set(3, (double)item);
	out.set(4, (double)cnt);
	return out;
}

Dictionary InserterPoseNative::arm_state(int slot) const {
	Dictionary d;
	if (!valid(slot)) {
		return d;
	}
	const Slot &a = slots[slot];
	PackedFloat64Array ticks, ev_ticks;
	PackedInt32Array ev_c, ev_code;
	for (double k : a.ticks) {
		ticks.push_back(k);
	}
	for (double k : a.ev_ticks) {
		ev_ticks.push_back(k);
	}
	for (int32_t c : a.ev_c) {
		ev_c.push_back(c);
	}
	for (int32_t c : a.ev_code) {
		ev_code.push_back(c);
	}
	d["ticks"] = ticks;
	d["ev_ticks"] = ev_ticks;
	d["ev_c"] = ev_c;
	d["ev_code"] = ev_code;
	d["cycles"] = a.cycles;
	d["side"] = a.side;
	d["last_item"] = a.last_item;
	d["plans"] = (int)a.plans.size();
	d["plan_ka"] = a.plan_ka;
	d["plan_still_until"] = a.plan_still_until;
	d["ends_tried"] = a.ends_tried;
	d["belt_pick"] = a.belt_pick;
	return d;
}

// ---- (--native-inserter-loop) the rest of the per-arm loop (inserter_arms.gd _process, A4) ----

namespace {

int64_t chunk_key(int32_t x, int32_t y) {
	return ((int64_t)x << 32) | (int64_t)(uint32_t)y;
}

// Godot's angle_difference and move_toward (core/math/math_funcs.h), as the GDScript calls them.
double angle_diff(double from, double to) {
	double d = std::fmod(to - from, 6.283185307179586);
	return std::fmod(2.0 * d, 6.283185307179586) - d;
}

double move_toward(double from, double to, double delta) {
	return std::fabs(to - from) <= delta ? to : from + (to - from > 0.0 ? 1.0 : (to - from < 0.0 ? -1.0 : 0.0)) * delta;
}

} // namespace

void InserterPoseNative::set_draw(int slot, int64_t unit, const Vector2i &chunk, bool bound, int mode, int key,
		const PackedFloat32Array &placed, const Color &color, double card_lift) {
	if (!valid(slot)) {
		return;
	}
	Slot &a = slots[slot];
	a.unit = unit;
	a.cx = chunk.x;
	a.cy = chunk.y;
	a.bound = bound;
	a.mode = mode;
	a.key = key;
	if (placed.size() >= 12) {
		for (int i = 0; i < 12; i++) {
			a.placed[i] = placed[i];
		}
	}
	a.color[0] = color.r;
	a.color[1] = color.g;
	a.color[2] = color.b;
	a.color[3] = color.a;
	a.card_lift = card_lift;
}

void InserterPoseNative::set_pose(int slot, double ang, double r) {
	if (valid(slot)) {
		slots[slot].cur_angle = ang;
		slots[slot].cur_reach = r;
	}
}

PackedFloat64Array InserterPoseNative::get_pose(int slot) const {
	PackedFloat64Array out;
	if (valid(slot)) {
		const Slot &a = slots[slot];
		out.resize(4);
		out.set(0, a.cur_angle);
		out.set(1, a.cur_reach);
		out.set(2, (double)a.cur_item);
		out.set(3, (double)a.cur_count);
	}
	return out;
}

void InserterPoseNative::set_state(int slot, const PackedFloat64Array &st) {
	if (!valid(slot) || st.size() < 10) {
		return;
	}
	Slot &a = slots[slot];
	a.cur_angle = st[0];
	a.cur_reach = st[1];
	a.cur_item = (int)st[2];
	a.close = st[3];
	a.seen_angle = st[4];
	a.seen_reach = st[5];
	a.moved_at = st[6];
	a.held_was = (int)st[7];
	a.grabs = (int)st[8];
	a.was_live = st[9] != 0.0;
	a.cur_count = st.size() >= 11 ? (int)st[10] : (a.cur_item > 0 ? 1 : 0);
	a.reported = -1;
}

PackedFloat64Array InserterPoseNative::draw_state(int slot) const {
	PackedFloat64Array out;
	if (!valid(slot)) {
		return out;
	}
	const Slot &a = slots[slot];
	double v[15] = { a.cur_angle, a.cur_reach, (double)a.cur_item, a.close, a.seen_angle, a.seen_reach, a.moved_at, (double)a.held_was,
		(double)a.grabs, a.was_live ? 1.0 : 0.0, (double)a.reported, (double)a.mode, (double)a.key, a.bound ? 1.0 : 0.0, (double)a.cur_count };
	out.resize(15);
	for (int i = 0; i < 15; i++) {
		out.set(i, v[i]);
	}
	return out;
}

void InserterPoseNative::clear_modes() {
	for (Slot &a : slots) {
		a.mode = -1;
		a.key = -1;
	}
}

void InserterPoseNative::forget_reports() {
	for (Slot &a : slots) {
		a.reported = -1;
	}
}

int InserterPoseNative::moving_count() const {
	int n = 0;
	for (const Slot &a : slots) {
		n += a.used && a.was_live && a.reported == 1 ? 1 : 0;
	}
	return n;
}

void InserterPoseNative::set_hidden(const PackedInt32Array &hidden) {
	hidden_chunks.clear();
	for (int64_t i = 0; i + 1 < hidden.size(); i += 2) {
		hidden_chunks.push_back(chunk_key(hidden[i], hidden[i + 1]));
	}
	std::sort(hidden_chunks.begin(), hidden_chunks.end());
}

PackedInt32Array InserterPoseNative::frame_check(const Dictionary &entities, const PackedInt32Array &hidden) {
	set_hidden(hidden);
	PackedInt32Array want;
	for (int s = 0; s < (int)slots.size(); s++) {
		Slot &a = slots[s];
		if (!a.used) {
			continue;
		}
		a.present = entities.has(a.unit);
		if (!a.present) {
			continue;
		}
		if (!a.bound) {
			want.push_back(s); // (its pose applied once it is bound: apply_pose)
			continue;
		}
		if (is_hidden(a)) {
			continue; // (behind the view: neither posed nor its mode decided, as in the GDScript loop)
		}
		apply_pose(s);
		if (a.mode < 0) {
			want.push_back(s);
		}
	}
	return want;
}

bool InserterPoseNative::is_hidden(const Slot &a) const {
	return !hidden_chunks.empty() && std::binary_search(hidden_chunks.begin(), hidden_chunks.end(), chunk_key(a.cx, a.cy));
}

void InserterPoseNative::apply_pose(int slot) {
	if (!valid(slot) || slot >= out_flags.size()) {
		return;
	}
	// The pose drawn, as the GDScript loop puts it on Arm: 1 pose and item, 2 the item alone, 0 it keeps what it had.
	Slot &a = slots[slot];
	const uint8_t f = out_flags[slot];
	if (f == 1) {
		a.cur_angle = out_angles[slot];
		a.cur_reach = out_reaches[slot];
		a.cur_item = out_items[slot];
		a.cur_count = out_counts[slot];
	} else if (f == 2) {
		a.cur_item = out_items[slot];
		a.cur_count = out_counts[slot];
	}
}

Array InserterPoseNative::frame_draw(const PackedFloat64Array &p, const Array &keys) {
	const double now = p.size() > 0 ? p[0] : 0.0;
	const double close_step = p.size() > 1 ? p[1] : 0.0;
	const bool animator = p.size() > 2 && p[2] != 0.0;
	const double still = p.size() > 3 ? p[3] : 1e-4;
	const double hold = p.size() > 4 ? p[4] : 30.0;
	const int nk = (int)keys.size();
	std::vector<int> kmode(nk, -1);
	for (int k = 0; k < nk; k++) {
		if (keys[k].get_type() == Variant::ARRAY) {
			Array e = keys[k];
			if (e.size() >= 3) {
				kmode[k] = (int)e[0];
			}
		}
	}
	std::vector<std::vector<float>> inp(nk);
	std::vector<std::vector<int>> members(nk);
	PackedInt32Array moving, came, left;
	for (int s = 0; s < (int)slots.size(); s++) {
		Slot &a = slots[s];
		if (!a.used) {
			continue;
		}
		if (!a.present) {
			if (a.was_live) {
				left.push_back(s);
				a.was_live = false;
				a.reported = a.reported == 1 ? 0 : a.reported;
			}
			continue;
		}
		if (a.bound && is_hidden(a)) {
			if (!a.was_live) {
				came.push_back(s);
				a.was_live = true;
			}
			continue; // (behind the view: live, not drawn)
		}
		if (!a.bound || a.mode < 0 || a.key < 0 || a.key >= nk || kmode[a.key] != a.mode) {
			if (a.was_live) {
				left.push_back(s);
				a.was_live = false;
				a.reported = a.reported == 1 ? 0 : a.reported;
			}
			continue; // (its model still being read)
		}
		const bool holding = a.cur_item > 0;
		std::vector<float> &in = inp[a.key];
		in.push_back(a.base.x);
		in.push_back(a.base.y);
		in.push_back((float)a.cur_angle);
		in.push_back((float)a.cur_reach);
		switch (a.mode) {
			case 0:
				in.push_back(holding ? 1.0f : 0.0f);
				in.push_back((float)a.card_lift);
				break;
			case 1:
				a.close = move_toward(a.close, holding ? 1.0 : 0.0, close_step);
				in.push_back((float)a.close);
				for (int i = 0; i < 12; i++) {
					in.push_back(a.placed[i]);
				}
				break;
			case 2:
				in.push_back(holding ? 1.0f : 0.0f);
				break;
			default:
				for (int i = 0; i < 4; i++) {
					in.push_back(a.color[i]);
				}
				break;
		}
		members[a.key].push_back(s);
		if (!a.was_live) {
			came.push_back(s);
			a.was_live = true;
		}
		if (animator) {
			// (L4) inserter_arms.gd _moving.
			if (std::fabs(angle_diff(a.seen_angle, a.cur_angle)) > still || std::fabs(a.cur_reach - a.seen_reach) > still) {
				a.moved_at = now;
			}
			a.seen_angle = a.cur_angle;
			a.seen_reach = a.cur_reach;
			const int8_t m = now - a.moved_at < hold && now >= a.moved_at ? 1 : 0;
			if (m != a.reported) {
				moving.push_back(s);
				moving.push_back(m);
				a.reported = m;
			}
		}
		if (a.cur_item != a.held_was) {
			a.held_was = a.cur_item;
			if (a.cur_item > 0) {
				a.grabs += 1;
			}
		}
	}
	Array results;
	results.resize(nk);
	PackedFloat64Array held;
	for (int k = 0; k < nk; k++) {
		if (members[k].empty()) {
			continue;
		}
		Array e = keys[k];
		PackedInt32Array caps = e[1];
		PackedFloat32Array params = e[2];
		const int m = kmode[k];
		PackedFloat32Array pin;
		pin.resize((int64_t)inp[k].size());
		std::copy(inp[k].begin(), inp[k].end(), pin.ptrw());
		Array r;
		switch (m) {
			case 0:
				r = InserterArmsNative::sprite_arms_impl(pin, caps, params);
				break;
			case 1:
				r = InserterArmsNative::rig_arms_impl(pin, caps, params);
				break;
			case 2:
				r = InserterArmsNative::model_arms_impl(pin, caps, params);
				break;
			default:
				r = InserterArmsNative::basic_arms_impl(pin, caps, params);
				break;
		}
		results[k] = r;
		PackedFloat32Array wr = r[2];
		PackedFloat32Array gr = r[3];
		const double gripped = (bool)r[4] ? 1.0 : 0.0;
		const std::vector<int> &mem = members[k];
		for (int i = 0; i < (int)mem.size(); i++) {
			const Slot &a = slots[mem[i]];
			if (a.cur_item <= 0) {
				continue;
			}
			double v[12] = { (double)mem[i], a.cur_angle, (double)a.cur_item, (double)a.grabs, wr[i * 3], wr[i * 3 + 1], wr[i * 3 + 2],
				gr[i * 3], gr[i * 3 + 1], gr[i * 3 + 2], gripped, (double)a.cur_count };
			for (double x : v) {
				held.push_back(x);
			}
		}
	}
	Array out;
	out.push_back(results);
	out.push_back(held);
	out.push_back(moving);
	out.push_back(came);
	out.push_back(left);
	return out;
}

void InserterPoseNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("add_arm"), &InserterPoseNative::add_arm);
	ClassDB::bind_method(D_METHOD("remove_arm", "slot"), &InserterPoseNative::remove_arm);
	ClassDB::bind_method(D_METHOD("clear"), &InserterPoseNative::clear);
	ClassDB::bind_method(D_METHOD("slot_count"), &InserterPoseNative::slot_count);
	ClassDB::bind_method(D_METHOD("preplan_size"), &InserterPoseNative::preplan_size);
	ClassDB::bind_method(D_METHOD("set_base", "slot", "base"), &InserterPoseNative::set_base);
	ClassDB::bind_method(D_METHOD("set_ends", "slot", "pick_a", "pick_r", "drop_a", "drop_r", "omega", "v", "belt_pick"), &InserterPoseNative::set_ends);
	ClassDB::bind_method(D_METHOD("add_sample", "slot", "k", "a", "r", "item", "queue"), &InserterPoseNative::add_sample);
	ClassDB::bind_method(D_METHOD("add_event", "slot", "k", "kind", "count", "item", "c", "x", "y", "belt"), &InserterPoseNative::add_event);
	ClassDB::bind_method(D_METHOD("backdate", "slot", "k"), &InserterPoseNative::backdate);
	ClassDB::bind_method(D_METHOD("preplan_some", "reach_slack"), &InserterPoseNative::preplan_some);
	ClassDB::bind_method(D_METHOD("pose_all", "t", "items_from_events", "reach_slack"), &InserterPoseNative::pose_all);
	ClassDB::bind_method(D_METHOD("pose_one", "slot", "t", "items_from_events", "reach_slack"), &InserterPoseNative::pose_one);
	ClassDB::bind_method(D_METHOD("angles"), &InserterPoseNative::angles);
	ClassDB::bind_method(D_METHOD("reaches"), &InserterPoseNative::reaches);
	ClassDB::bind_method(D_METHOD("items"), &InserterPoseNative::items);
	ClassDB::bind_method(D_METHOD("counts"), &InserterPoseNative::counts);
	ClassDB::bind_method(D_METHOD("flags"), &InserterPoseNative::flags);
	ClassDB::bind_method(D_METHOD("arm_state", "slot"), &InserterPoseNative::arm_state);
	ClassDB::bind_method(D_METHOD("set_draw", "slot", "unit", "chunk", "bound", "mode", "key", "placed", "color", "card_lift"), &InserterPoseNative::set_draw);
	ClassDB::bind_method(D_METHOD("set_pose", "slot", "a", "r"), &InserterPoseNative::set_pose);
	ClassDB::bind_method(D_METHOD("get_pose", "slot"), &InserterPoseNative::get_pose);
	ClassDB::bind_method(D_METHOD("set_state", "slot", "st"), &InserterPoseNative::set_state);
	ClassDB::bind_method(D_METHOD("draw_state", "slot"), &InserterPoseNative::draw_state);
	ClassDB::bind_method(D_METHOD("clear_modes"), &InserterPoseNative::clear_modes);
	ClassDB::bind_method(D_METHOD("forget_reports"), &InserterPoseNative::forget_reports);
	ClassDB::bind_method(D_METHOD("moving_count"), &InserterPoseNative::moving_count);
	ClassDB::bind_method(D_METHOD("frame_check", "entities", "hidden"), &InserterPoseNative::frame_check);
	ClassDB::bind_method(D_METHOD("apply_pose", "slot"), &InserterPoseNative::apply_pose);
	ClassDB::bind_method(D_METHOD("set_hidden", "hidden"), &InserterPoseNative::set_hidden);
	ClassDB::bind_method(D_METHOD("frame_draw", "p", "keys"), &InserterPoseNative::frame_draw);
}
