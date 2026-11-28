#include "inserter_swing_native.h"

#include "inserter_swing_core.h"

#include <godot_cpp/core/class_db.hpp>

#include <cstdint>

using namespace godot;

namespace {

zswing::End end_of(const PackedFloat64Array &e) {
	zswing::End out;
	if (e.size() >= 2) {
		out.known = true;
		out.a = e[0];
		out.r = e[1];
	}
	return out;
}

zswing::Event event_of(const PackedFloat64Array &e) {
	zswing::Event out;
	out.k = e[0];
	out.kind = (int)e[1];
	out.count = (int)e[2];
	out.item = (int)e[3];
	out.a = e[4];
	out.r = e[5];
	out.code = e.size() > 6 ? (int)e[6] : zswing::WORKING;
	return out;
}

PackedFloat64Array packed(const zswing::Plan &p) {
	PackedFloat64Array out;
	out.resize((int64_t)p.size() * 4);
	double *w = out.ptrw();
	for (size_t i = 0; i < p.size(); i++) {
		w[i * 4] = p[i].k;
		w[i * 4 + 1] = p[i].a;
		w[i * 4 + 2] = p[i].r;
		w[i * 4 + 3] = (double)p[i].item;
	}
	return out;
}

} // namespace

int InserterSwingNative::travel_ticks(double d_angle, double d_reach, double omega, double v, bool complete_rot, bool complete_ext) const {
	return zswing::travel_ticks(d_angle, d_reach, omega, v, complete_rot, complete_ext);
}

int InserterSwingNative::part_ticks(double way, double speed, bool complete) const {
	return zswing::part_ticks(way, speed, complete);
}

double InserterSwingNative::part_at(double from, double to, double speed, double j) const {
	return zswing::part_at(from, to, speed, j);
}

PackedFloat64Array InserterSwingNative::leg(double k0, double a0, double r0, double k1, double a1, double r1, int item, double omega,
		double v, bool complete, int end_item) const {
	zswing::Plan out;
	zswing::leg(out, k0, a0, r0, k1, a1, r1, item, omega, v, complete, end_item);
	return packed(out);
}

Vector2 InserterSwingNative::hand_pos(double angle, double reach) const {
	return zswing::hand_pos(angle, reach);
}

bool InserterSwingNative::near(double angle, double reach, const PackedFloat64Array &e, double tol) const {
	return zswing::near_end(angle, reach, end_of(e), tol);
}

double InserterSwingNative::delta(double from, double to, double side, double ambiguous) const {
	return zswing::delta(from, to, side, ambiguous);
}

bool InserterSwingNative::on_side(double angle, const PackedFloat64Array &pick, const PackedFloat64Array &drop) const {
	return zswing::on_side(angle, end_of(pick), end_of(drop));
}

PackedFloat64Array InserterSwingNative::plan(const PackedFloat64Array &s, const PackedFloat64Array &pick, const PackedFloat64Array &drop,
		double omega, double v, double side, bool belt_pick, int last_item, double reach_slack) const {
	if (s.size() < 8) {
		return PackedFloat64Array();
	}
	return packed(zswing::plan(s[0], s[1], s[2], (int)s[3], s[4], s[5], s[6], (int)s[7], end_of(pick), end_of(drop), omega, v, side,
			belt_pick, last_item, reach_slack));
}

PackedFloat64Array InserterSwingNative::at(const PackedFloat64Array &keys, double t) const {
	PackedFloat64Array out;
	int64_t n = keys.size() / 4;
	if (n == 0) {
		return out;
	}
	zswing::Plan p((size_t)n);
	for (int64_t i = 0; i < n; i++) {
		p[i] = { keys[i * 4], keys[i * 4 + 1], keys[i * 4 + 2], (int)keys[i * 4 + 3] };
	}
	double a, r;
	int item;
	zswing::at(p, t, a, r, item);
	out.resize(3);
	out.set(0, a);
	out.set(1, r);
	out.set(2, (double)item);
	return out;
}

PackedFloat64Array InserterSwingNative::plan_events(const PackedFloat64Array &e0, const PackedFloat64Array &e1, const PackedFloat64Array &pick,
		const PackedFloat64Array &drop, double omega, double v, double side) const {
	if (e0.size() < 6) {
		return PackedFloat64Array();
	}
	zswing::Event a = event_of(e0);
	if (e1.size() >= 6) {
		zswing::Event b = event_of(e1);
		return packed(zswing::plan_events(a, &b, end_of(pick), end_of(drop), omega, v, side));
	}
	return packed(zswing::plan_events(a, nullptr, end_of(pick), end_of(drop), omega, v, side));
}

PackedFloat64Array InserterSwingNative::extrapolate(double an, double rn, int item, bool still, const PackedFloat64Array &pick,
		const PackedFloat64Array &drop, double omega, double v, double side, double ticks) const {
	double a, r;
	int it;
	zswing::extrapolate(an, rn, item, still, end_of(pick), end_of(drop), omega, v, side, ticks, a, r, it);
	PackedFloat64Array out;
	out.resize(3);
	out.set(0, a);
	out.set(1, r);
	out.set(2, (double)it);
	return out;
}

void InserterSwingNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("travel_ticks", "d_angle", "d_reach", "omega", "v", "complete_rot", "complete_ext"), &InserterSwingNative::travel_ticks);
	ClassDB::bind_method(D_METHOD("part_ticks", "way", "speed", "complete"), &InserterSwingNative::part_ticks);
	ClassDB::bind_method(D_METHOD("part_at", "from", "to", "speed", "j"), &InserterSwingNative::part_at);
	ClassDB::bind_method(D_METHOD("leg", "k0", "a0", "r0", "k1", "a1", "r1", "item", "omega", "v", "complete", "end_item"), &InserterSwingNative::leg);
	ClassDB::bind_method(D_METHOD("hand_pos", "angle", "reach"), &InserterSwingNative::hand_pos);
	ClassDB::bind_method(D_METHOD("near", "angle", "reach", "e", "tol"), &InserterSwingNative::near);
	ClassDB::bind_method(D_METHOD("delta", "from", "to", "side", "ambiguous"), &InserterSwingNative::delta);
	ClassDB::bind_method(D_METHOD("on_side", "angle", "pick", "drop"), &InserterSwingNative::on_side);
	ClassDB::bind_method(D_METHOD("plan", "s", "pick", "drop", "omega", "v", "side", "belt_pick", "last_item", "reach_slack"), &InserterSwingNative::plan);
	ClassDB::bind_method(D_METHOD("at", "keys", "t"), &InserterSwingNative::at);
	ClassDB::bind_method(D_METHOD("plan_events", "e0", "e1", "pick", "drop", "omega", "v", "side"), &InserterSwingNative::plan_events);
	ClassDB::bind_method(D_METHOD("extrapolate", "an", "rn", "item", "still", "pick", "drop", "omega", "v", "side", "ticks"), &InserterSwingNative::extrapolate);
}
