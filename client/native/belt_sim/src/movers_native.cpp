#include "movers_native.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

namespace {
constexpr double PI_D = 3.14159265358979323846;
constexpr double TURN_RATE = 15.0;
constexpr int F_ODD = 1;
constexpr int F_SIMULATED = 32;
constexpr int F_SIM_ORBIT = 128;

inline double move_toward_d(double from, double to, double delta) {
	return std::fabs(to - from) <= delta ? to : from + (to > from ? 1.0 : (to < from ? -1.0 : 0.0)) * delta;
}
inline double wrapf_d(double x, double mn, double mx) {
	double range = mx - mn;
	if (std::fabs(range) < 1e-5) {
		return mn;
	}
	double r = x - range * std::floor((x - mn) / range);
	if (r == mx) {
		r = mn; // Godot's wrapf
	}
	return r;
}
inline double lerp_d(double a, double b, double f) { return a + (b - a) * f; }

// MoverRecords._lag_after
inline double lag_after(const float *d, double ticks) {
	double l0 = d[24];
	double g0 = d[25];
	double gg = d[26];
	double gap = move_toward_d(g0, gg, ticks * (gg > g0 ? (double)d[28] : 1.0));
	double want = std::max(2.0 * gap, (double)d[27] + gap);
	return want >= l0 ? std::min(l0 + 0.5 * ticks, want) : std::max(l0 - ticks, want);
}

// MoverRecords.write_xform
void xform(const float *d, double c_even, double c_odd, double inv_rate, float *out) {
	int flags = (int)d[12];
	double now = (flags & F_ODD) ? c_odd : c_even;
	double px, pz, yaw;
	if (flags & F_SIMULATED) {
		double since = std::max(now - d[15], 0.0) * inv_rate;
		if (flags & F_SIM_ORBIT) {
			double ang = (double)d[23] + std::max(now - d[8], 0.0) * d[22];
			px = d[2] + std::cos(ang) * d[21];
			pz = d[3] + std::sin(ang) * d[21];
			double sgn = d[22] >= 0.0f ? 1.0 : -1.0;
			double tang = std::atan2(std::sin(ang) * sgn, -std::cos(ang) * sgn);
			yaw = tang + wrapf_d(d[16] - tang, -PI_D, PI_D) * std::exp(-TURN_RATE * since);
		} else if (now < d[9] && d[9] > d[8] + 1e-4) {
			double f = std::clamp((now - d[8]) / ((double)d[9] - d[8]), 0.0, 1.0);
			px = lerp_d(d[0], d[2], f);
			pz = lerp_d(d[1], d[3], f);
			yaw = d[14] + wrapf_d((double)d[16] - d[14], -PI_D, PI_D) * std::exp(-TURN_RATE * since);
		} else if (d[10] > d[9] + 1e-4 && now < d[10]) {
			double f = std::clamp((now - d[9]) / ((double)d[10] - d[9]), 0.0, 1.0);
			px = lerp_d(d[2], d[4], f);
			pz = lerp_d(d[3], d[5], f);
			double since2 = std::max(now - std::max((double)d[15], (double)d[9]), 0.0) * inv_rate;
			yaw = d[17] + wrapf_d((double)d[14] - d[17], -PI_D, PI_D) * std::exp(-TURN_RATE * since2);
		} else {
			bool had_leg2 = d[10] > d[9] + 1e-4;
			if (had_leg2) {
				px = d[4];
				pz = d[5];
				double since2 = std::max(now - std::max((double)d[15], (double)d[9]), 0.0) * inv_rate;
				yaw = d[17] + wrapf_d((double)d[14] - d[17], -PI_D, PI_D) * std::exp(-TURN_RATE * since2);
			} else {
				px = d[2];
				pz = d[3];
				yaw = d[14] + wrapf_d((double)d[16] - d[14], -PI_D, PI_D) * std::exp(-TURN_RATE * since);
			}
		}
		double blend = std::exp(-(double)d[24] * since);
		px += d[6] * blend;
		pz += d[7] * blend;
	} else {
		double after = std::max(now - d[15], 0.0);
		double lag = lag_after(d, after);
		double drawn = now - lag;
		px = d[0];
		pz = d[1];
		if (drawn > d[8]) {
			bool found = false;
			for (int i = 0; i < 3; i++) {
				if (drawn <= d[9 + i]) {
					double span = (double)d[9 + i] - d[8 + i];
					double f = span > 1e-4 ? (drawn - d[8 + i]) / span : 1.0;
					px = lerp_d(d[i * 2], d[i * 2 + 2], f);
					pz = lerp_d(d[i * 2 + 1], d[i * 2 + 3], f);
					found = true;
					break;
				}
			}
			if (!found) {
				double span = (double)d[11] - d[10];
				if (span > 1e-4) {
					double f = std::min((drawn - d[10]) / span, (double)d[23]);
					px = lerp_d(d[4], d[6], f);
					pz = lerp_d(d[5], d[7], f);
				} else {
					px = d[6];
					pz = d[7];
				}
			}
		}
		double since3 = after * inv_rate;
		yaw = d[17] + wrapf_d((double)d[16] - d[17], -PI_D, PI_D) * std::exp(-TURN_RATE * since3);
	}
	double c = std::cos(yaw);
	double s = std::sin(yaw);
	out[0] = (float)c;
	out[1] = 0.0f;
	out[2] = (float)s;
	out[3] = (float)px;
	out[4] = 0.0f;
	out[5] = 1.0f;
	out[6] = 0.0f;
	out[7] = d[13];
	out[8] = (float)-s;
	out[9] = 0.0f;
	out[10] = (float)c;
	out[11] = (float)pz;
}
} // namespace

PackedFloat32Array MoversNative::write_xforms(const PackedFloat32Array &p_data, const PackedInt32Array &p_slots, int p_count,
		const PackedFloat32Array &p_buf, double p_c_even, double p_c_odd, double p_inv_rate, int p_mode) {
	int n = std::min((int)p_slots.size(), p_count);
	last_skipped = 0;
	PackedFloat32Array out = p_buf;
	if (n <= 0 || out.size() < n * STRIDE) {
		return out;
	}
	const float *data = p_data.ptr();
	const int64_t dsize = p_data.size();
	const int32_t *slots = p_slots.ptr();
	float *buf = out.ptrw();
	int skipped = 0;
	for (int i = 0; i < n; i++) {
		int slot = slots[i];
		if (slot < 0 || (int64_t)(slot + 1) * FLOATS > dsize) {
			skipped++;
			continue;
		}
		float *o = buf + (int64_t)i * STRIDE;
		xform(data + (int64_t)slot * FLOATS, p_c_even, p_c_odd, p_inv_rate, o);
		if (p_mode == 1) {
			o[12] = 0.0f;
			o[13] = 1.0f;
			o[14] = (float)(slot + 1);
			o[15] = 1.0f;
		} else {
			o[12] = (float)slot;
			o[13] = 1.0f;
		}
	}
	last_skipped = skipped;
	return out;
}

PackedFloat32Array MoversNative::xform_of(const PackedFloat32Array &p_data, int p_slot, double p_c_even, double p_c_odd, double p_inv_rate) {
	PackedFloat32Array out;
	out.resize(12);
	if (p_slot < 0 || (int64_t)(p_slot + 1) * FLOATS > p_data.size()) {
		return out;
	}
	xform(p_data.ptr() + (int64_t)p_slot * FLOATS, p_c_even, p_c_odd, p_inv_rate, out.ptrw());
	return out;
}

void MoversNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("write_xforms", "data", "slots", "count", "buf", "c_even", "c_odd", "inv_rate", "mode"), &MoversNative::write_xforms);
	ClassDB::bind_method(D_METHOD("skipped"), &MoversNative::skipped);
	ClassDB::bind_method(D_METHOD("xform_of", "data", "slot", "c_even", "c_odd", "inv_rate"), &MoversNative::xform_of);
}
