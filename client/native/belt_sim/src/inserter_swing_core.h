#pragma once
// Native twin of scripts/world/inserter_swing.gd (GPL-3.0, like the rest of Zenith): an inserter hand's swing
// between two samples of it, as Factorio moves it (read that file's comments: every function here is one of its
// functions, line for line). Plain functions on doubles, as GDScript's floats; the hand's place is a Vector2 of
// real_t (32-bit) as there, so `near` and the still checks agree to the bit. A plan is keyframes {tick, angle,
// reach, item}. Used by InserterSwingNative (the bound twin, for tests and the fallback's plans) and by
// InserterPoseNative (the arms' samples, events and pose).

#include <godot_cpp/variant/vector2.hpp>

#include <algorithm>
#include <cmath>
#include <vector>

namespace zswing {

using godot::real_t;
using godot::Vector2;

constexpr double END_NEAR = 0.35;
constexpr double STILL = 0.02;
constexpr double AMBIGUOUS = 2.88;
constexpr double SIDE_CLEAR = 0.44;
constexpr double PI = 3.1415926535897932384626433833;
constexpr double TAU = 6.2831853071795864769252867666;
constexpr double EPS_APPROX = 0.00001;

enum Ev { PICKED = 1, DROPPED = 2, STATUS = 3, SYNC = 4, GONE = 5 };
enum Code { WORKING = 0, LOW = 4, NO_POWER = 5, FROZEN = 6, DISABLED = 7 };

struct Key {
	double k;
	double a;
	double r;
	int item;
};
using Plan = std::vector<Key>;

// An end pose [angle, reach]; known false for GDScript's [] (unknown).
struct End {
	bool known = false;
	double a = 0.0;
	double r = 0.0;
};

// An event as plan_events takes it: [tick, kind, count, item, angle, reach, status code].
struct Event {
	double k = 0.0;
	int kind = 0;
	int count = 0;
	int item = 0;
	double a = NAN;
	double r = NAN;
	int code = WORKING;
};

// GDScript's own helpers (Godot's math_funcs.h / VariantUtilityFunctions), exactly.
inline double signf(double x) { return x > 0.0 ? 1.0 : (x < 0.0 ? -1.0 : 0.0); }
inline double minf(double a, double b) { return a < b ? a : b; }
inline double maxf(double a, double b) { return a > b ? a : b; }
inline int maxi(int a, int b) { return a > b ? a : b; }
inline double clampf(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }
inline double lerpf(double a, double b, double t) { return a + (b - a) * t; }
inline bool is_equal_approx(double a, double b) {
	if (a == b) {
		return true;
	}
	double tolerance = EPS_APPROX * std::fabs(a);
	if (tolerance < EPS_APPROX) {
		tolerance = EPS_APPROX;
	}
	return std::fabs(a - b) < tolerance;
}
inline double wrapf(double value, double min, double max) {
	double range = max - min;
	if (std::fabs(range) < EPS_APPROX) {
		return min;
	}
	double result = value - (range * std::floor((value - min) / range));
	if (is_equal_approx(result, max)) {
		return min;
	}
	return result;
}

inline Vector2 hand_pos(double angle, double reach) {
	return Vector2((real_t)std::cos(angle), (real_t)std::sin(angle)) * (real_t)reach;
}

inline bool near_end(double angle, double reach, const End &e, double tol = END_NEAR) {
	return e.known && (double)hand_pos(angle, reach).distance_to(hand_pos(e.a, e.r)) < tol;
}

inline double delta(double from, double to, double side, double ambiguous = AMBIGUOUS) {
	double d = wrapf(to - from, -PI, PI);
	if (std::fabs(d) > ambiguous && !std::isnan(side)) {
		double other = d != 0.0 ? d - signf(d) * TAU : TAU;
		double mid_short = wrapf(from + d * 0.5 - side, -PI, PI);
		double mid_other = wrapf(from + other * 0.5 - side, -PI, PI);
		if (std::fabs(mid_other) < std::fabs(mid_short)) {
			return other;
		}
	}
	return d;
}

inline bool on_side(double angle, const End &pick, const End &drop) {
	if (!pick.known || !drop.known) {
		return false;
	}
	return std::fabs(wrapf(angle - pick.a, -PI, PI)) > SIDE_CLEAR && std::fabs(wrapf(angle - drop.a, -PI, PI)) > SIDE_CLEAR;
}

inline int part_ticks(double way, double speed, bool complete) {
	if (way <= 1e-9 || speed <= 0.0) {
		return 0;
	}
	return maxi(1, (int)std::ceil(way / speed - (complete ? 1.0 : 0.0) - 1e-6));
}

inline int travel_ticks(double d_angle, double d_reach, double omega, double v, bool complete_rot = true, bool complete_ext = true) {
	return maxi(part_ticks(std::fabs(d_angle), omega * TAU, complete_rot), part_ticks(std::fabs(d_reach), v, complete_ext));
}

inline double part_at(double from, double to, double speed, double j) {
	double d = to - from;
	return from + signf(d) * minf(std::fabs(d), j * speed);
}

// Appends one leg's keyframes (the first, k0's, is the caller's).
inline void leg(Plan &out, double k0, double a0, double r0, double k1, double a1, double r1, int item, double omega, double v,
		bool complete, int end_item = -1) {
	double span = k1 - k0;
	double w = omega * TAU;
	if (span > 1.0) {
		int t_ext = part_ticks(std::fabs(r1 - r0), v, true);
		int t_rot = complete ? part_ticks(std::fabs(a1 - a0), w, true) : (int)span;
		int marks[2];
		int nm = 0;
		if (t_ext > 0 && t_ext < span) {
			marks[nm++] = t_ext;
		}
		if (complete && t_rot >= 2 && t_rot - 1 < span && !(nm == 1 && marks[0] == t_rot - 1)) {
			marks[nm++] = t_rot - 1;
		}
		if (nm == 2 && marks[1] < marks[0]) {
			std::swap(marks[0], marks[1]);
		}
		for (int m = 0; m < nm; m++) {
			int j = marks[m];
			double a = complete && j >= t_rot ? a1 : (complete ? part_at(a0, a1, w, j) : lerpf(a0, a1, j / span));
			double r = j >= t_ext ? r1 : part_at(r0, r1, v, j);
			out.push_back({ k0 + j, a, r, item });
		}
	}
	out.push_back({ k1, a1, r1, end_item < 0 ? item : end_item });
}

inline Plan plan(double ka, double aa, double ra, int ia, double kb, double ab, double rb, int ib, const End &pick, const End &drop,
		double omega, double v, double side, bool belt_pick, int last_item, double reach_slack) {
	Plan out;
	double dt = kb - ka;
	if (dt <= 0.0) {
		out.push_back({ ka, aa, ra, ib });
		return out;
	}
	double moved = (double)hand_pos(aa, ra).distance_to(hand_pos(ab, rb));
	bool changed = ia != ib;
	double ab_u = aa + delta(aa, ab, side);
	out.push_back({ ka, aa, ra, ia });
	if (moved < STILL) {
		out.push_back({ kb, ab_u, rb, ib });
		return out;
	}
	if (changed) {
		const End &e = ib != 0 ? pick : drop;
		const End &other = ib != 0 ? drop : pick;
		if (!e.known) {
			out.push_back({ ka + dt * 0.5, lerpf(aa, ab_u, 0.5), lerpf(ra, rb, 0.5), ib });
			out.push_back({ kb, ab_u, rb, ib });
			return out;
		}
		if (belt_pick && ib != 0 && pick.known && drop.known) {
			double w = omega * TAU;
			double dirn = signf(delta(pick.a, drop.a, side));
			double tg = std::round((ka + kb) * 0.5 - dirn * (ab_u - aa) / (2.0 * w));
			double to_nominal = std::fabs(delta(aa, pick.a, side));
			if (tg >= ka && tg <= kb && (tg - ka) * w <= to_nominal + 0.5 * w) {
				double ag = aa - dirn * w * (tg - ka);
				double back = (kb - tg) * v;
				double rg = std::fabs(rb - drop.r) < 1e-4 ? clampf(pick.r, drop.r - back - v, drop.r) : rb - signf(drop.r - rb) * back;
				if (std::fabs(rg - pick.r) <= 0.6) {
					bool parked = near_end(ab, rb, drop, STILL);
					if (tg > ka) {
						leg(out, ka, aa, ra, tg, ag, rg, ia, omega, v, false, ib);
					} else {
						out[0].item = ib;
					}
					if (kb > tg) {
						leg(out, tg, ag, rg, kb, ab_u, rb, ib, omega, v, parked);
					}
					return out;
				}
			}
		}
		double d1 = delta(aa, e.a, side);
		double ae_u = aa + d1;
		double d2 = delta(e.a, ab, side);
		bool b_parked = near_end(ab, rb, other, STILL);
		int t1 = travel_ticks(d1, e.r - ra, omega, v);
		int t2 = travel_ticks(d2, rb - e.r, omega, v, b_parked, b_parked || (other.known && std::fabs(rb - other.r) < 1e-4));
		if (t1 + t2 <= dt) {
			double ta = ka + t1;
			double tl = kb - t2;
			if (t1 > 0) {
				leg(out, ka, aa, ra, ta, ae_u, e.r, ia, omega, v, true, tl > ta ? ia : ib);
			}
			if (tl > ta) {
				out.push_back({ tl, ae_u, e.r, ib });
			}
			if (t2 > 0) {
				leg(out, tl, ae_u, e.r, kb, ae_u + d2, rb, ib, omega, v, b_parked);
			}
			return out;
		}
		double tm = t1 + t2 > 0 ? ka + dt * ((double)t1 / (double)(t1 + t2)) : ka + dt * 0.5;
		if (t1 + t2 <= dt * reach_slack + 1.0) {
			leg(out, ka, aa, ra, tm, ae_u, e.r, ia, omega, v, false, ib);
			leg(out, tm, ae_u, e.r, kb, ae_u + d2, rb, ib, omega, v, false);
			return out;
		}
		if (belt_pick && ib != 0) {
			int j = (int)dt - 1;
			while (j >= 1) {
				double aj = part_at(aa, ae_u, omega * TAU, j);
				double rj = part_at(ra, e.r, v, j);
				if (travel_ticks(delta(wrapf(aj, -PI, PI), ab, side), rb - rj, omega, v, b_parked, b_parked) <= dt - j) {
					break;
				}
				j -= 1;
			}
			tm = ka + maxi(j, 1);
		}
		double way = tm - ka;
		double am = part_at(aa, ae_u, omega * TAU, way);
		double rm = part_at(ra, e.r, v, way);
		leg(out, ka, aa, ra, tm, am, rm, ib, omega, v, false);
		leg(out, tm, am, rm, kb, am + delta(wrapf(am, -PI, PI), ab, side), rb, ib, omega, v, b_parked);
		return out;
	}
	if ((near_end(aa, ra, pick) && near_end(ab, rb, drop) && ia == 0) || (near_end(aa, ra, drop) && near_end(ab, rb, pick) && ia != 0)) {
		int t_leg = travel_ticks(ab_u - aa, rb - ra, omega, v);
		double tl = maxf(ka, kb - t_leg);
		int carried = ia == 0 ? last_item : 0;
		if (tl > ka) {
			out.push_back({ tl, aa, ra, carried });
		} else {
			out[0].item = carried;
		}
		leg(out, tl, aa, ra, kb, ab_u, rb, carried, omega, v, true);
		out.push_back({ kb, ab_u, rb, ib });
		return out;
	}
	const End &bound = ib != 0 ? drop : pick;
	bool a_zone = near_end(aa, ra, pick) || near_end(aa, ra, drop);
	bool b_zone = near_end(ab, rb, pick) || near_end(ab, rb, drop);
	bool b_parked = near_end(ab, rb, bound, STILL);
	int t_ab = travel_ticks(ab_u - aa, rb - ra, omega, v, b_parked, b_parked || (bound.known && std::fabs(rb - bound.r) < 1e-4));
	if (t_ab >= dt - 0.5) {
		leg(out, ka, aa, ra, kb, ab_u, rb, ib, omega, v, b_parked);
		return out;
	}
	double w = dt - t_ab;
	if (a_zone && !b_zone) {
		out.push_back({ ka + w, aa, ra, ia });
		leg(out, ka + w, aa, ra, kb, ab_u, rb, ib, omega, v, b_parked);
		return out;
	}
	if (b_parked) {
		leg(out, ka, aa, ra, ka + t_ab, ab_u, rb, ib, omega, v, true);
		out.push_back({ kb, ab_u, rb, ib });
		return out;
	}
	leg(out, ka, aa, ra, kb, ab_u, rb, ib, omega, v, false);
	return out;
}

// The pose a plan gives at tick t: angle, reach, item.
inline void at(const Plan &keys, double t, double &a, double &r, int &item) {
	const Key &first = keys[0];
	if (t <= first.k) {
		a = first.a;
		r = first.r;
		item = first.item;
		return;
	}
	for (size_t i = 1; i < keys.size(); i++) {
		const Key &k1 = keys[i];
		if (t <= k1.k) {
			const Key &k0 = keys[i - 1];
			double u = k1.k > k0.k ? (t - k0.k) / (k1.k - k0.k) : 1.0;
			a = lerpf(k0.a, k1.a, u);
			r = lerpf(k0.r, k1.r, u);
			item = t >= k1.k ? k1.item : k0.item;
			return;
		}
	}
	const Key &last = keys.back();
	a = last.a;
	r = last.r;
	item = last.item;
}

inline bool slow_code(int code) {
	return code == LOW || code == NO_POWER || code == FROZEN || code == DISABLED;
}

// e1 null: none (on past e0).
inline Plan plan_events(const Event &e0, const Event *e1, const End &pick, const End &drop, double omega, double v, double side) {
	double k0 = e0.k;
	int kind0 = e0.kind;
	int c0 = e0.count;
	int item0 = c0 > 0 ? e0.item : 0;
	bool holding = c0 > 0;
	const End &bound = holding ? drop : pick;
	double a0 = e0.a;
	double r0 = e0.r;
	int code0 = e0.code;
	double amb = std::isnan(side) ? AMBIGUOUS : PI * 0.5;
	Plan out;
	if (std::isnan(a0)) {
		if (!bound.known) {
			out.push_back({ k0, 0.0, 1.0, item0 });
			return out;
		}
		a0 = bound.a;
		r0 = bound.r;
	}
	out.push_back({ k0, a0, r0, item0 });
	if (code0 != WORKING && !slow_code(code0) && near_end(a0, r0, bound, 0.7)) {
		if (e1 != nullptr) {
			out.push_back({ e1->k, a0, r0, item0 });
		}
		return out;
	}
	if (e1 == nullptr) {
		if (!bound.known || near_end(a0, r0, bound)) {
			return out;
		}
		double d = delta(a0, bound.a, side, amb);
		leg(out, k0, a0, r0, k0 + travel_ticks(d, bound.r - r0, omega, v), a0 + d, bound.r, item0, omega, v, true);
		return out;
	}
	double k1 = e1->k;
	int kind1 = e1->kind;
	int c1 = e1->count;
	double a1 = e1->a;
	double r1 = e1->r;
	if (k1 <= k0) {
		return out;
	}
	bool known1 = !std::isnan(a1);
	bool arrival = (holding && kind1 == DROPPED) || (!holding && kind1 == PICKED);
	if ((holding && kind1 == PICKED && c1 > c0) || (holding && kind0 == DROPPED && kind1 == DROPPED)) {
		out.push_back({ k1, a0 + (known1 ? delta(a0, a1, side, amb) : 0.0), known1 ? r1 : r0, item0 });
		return out;
	}
	End target;
	if (arrival && known1) {
		target = { true, a1, r1 };
	} else if (bound.known) {
		target = bound;
	} else if (known1) {
		target = { true, a1, r1 };
	} else {
		out.push_back({ k1, a0, r0, item0 });
		return out;
	}
	if (!holding && arrival && known1 && pick.known && !near_end(a1, r1, pick, STILL) && near_end(a1, r1, pick, 1.0)) {
		double d1 = delta(a0, pick.a, side, amb);
		int t1 = travel_ticks(d1, pick.r - r0, omega, v);
		double ap = a0 + d1;
		double d2 = delta(pick.a, a1, side, amb);
		int tc = travel_ticks(d2, r1 - pick.r, omega, v, false, false);
		if (k0 + t1 + tc <= k1) {
			if (t1 > 0) {
				leg(out, k0, a0, r0, k0 + t1, ap, pick.r, item0, omega, v, true);
			}
			if (k1 - tc > k0 + t1) {
				out.push_back({ k1 - tc, ap, pick.r, item0 });
			}
			leg(out, k1 - tc, ap, pick.r, k1, ap + d2, r1, item0, omega, v, false);
			return out;
		}
	}
	if (!arrival && known1 && !near_end(a1, r1, target)) {
		leg(out, k0, a0, r0, k1, a0 + delta(a0, a1, side, amb), r1, item0, omega, v, false);
		return out;
	}
	double d = delta(a0, target.a, side, amb);
	int t = travel_ticks(d, target.r - r0, omega, v);
	if (t == 0) {
		out.push_back({ k1, a0, r0, item0 });
	} else if (k0 + t < k1) {
		leg(out, k0, a0, r0, k0 + t, a0 + d, target.r, item0, omega, v, true);
		out.push_back({ k1, a0 + d, target.r, item0 });
	} else {
		leg(out, k0, a0, r0, k1, a0 + d, target.r, item0, omega, v, true);
	}
	return out;
}

inline void extrapolate(double an, double rn, int item, bool still, const End &pick, const End &drop, double omega, double v,
		double side, double ticks, double &a, double &r, int &it) {
	const End &e = item != 0 ? drop : pick;
	it = item;
	if (still || !e.known || ticks <= 0.0 || near_end(an, rn, e)) {
		a = an;
		r = rn;
		return;
	}
	double d = delta(an, e.a, side);
	a = part_at(an, an + d, omega * TAU, ticks);
	r = part_at(rn, e.r, v, ticks);
}

} // namespace zswing
