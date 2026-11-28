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
// Godot's Math::is_equal_approx / wrapf (doubles), as GDScript's wrapf works.
inline bool equal_approx_d(double a, double b) {
	if (a == b) {
		return true;
	}
	double tol = 0.00001 * std::fabs(a);
	if (tol < 0.00001) {
		tol = 0.00001;
	}
	return std::fabs(a - b) < tol;
}
inline double wrapf_g(double value, double mn, double mx) {
	double range = mx - mn;
	if (std::fabs(range) < 0.00001) {
		return mn;
	}
	double result = value - (range * std::floor((value - mn) / range));
	if (equal_approx_d(result, mx)) {
		return mn;
	}
	return result;
}

// MoverRecords.position (GDScript: doubles, Vector2/Vector3 are float32: every place a Vector is made
// or added to rounds to float, as here).
Vector3 position_of(const float *d, double c_even, double c_odd, double rate) {
	int flags = (int)d[12];
	double now = (flags & F_ODD) ? c_odd : c_even;
	if (flags & F_SIMULATED) {
		double r = std::max(rate, 1.0);
		double since = std::max(now - d[15], 0.0) / r;
		Vector2 at;
		if (flags & F_SIM_ORBIT) {
			double ang = (double)d[23] + std::max(now - d[8], 0.0) * d[22];
			at = Vector2(d[2], d[3]) + Vector2((float)std::cos(ang), (float)std::sin(ang)) * (float)d[21];
		} else if (now < d[9] && d[9] > d[8] + 1e-4) {
			double f = std::clamp((now - d[8]) / ((double)d[9] - d[8]), 0.0, 1.0);
			at = Vector2((float)lerp_d(d[0], d[2], f), (float)lerp_d(d[1], d[3], f));
		} else if (d[10] > d[9] + 1e-4 && now < d[10]) {
			double f = std::clamp((now - d[9]) / ((double)d[10] - d[9]), 0.0, 1.0);
			at = Vector2((float)lerp_d(d[2], d[4], f), (float)lerp_d(d[3], d[5], f));
		} else {
			bool had_leg2 = d[10] > d[9] + 1e-4;
			at = had_leg2 ? Vector2(d[4], d[5]) : Vector2(d[2], d[3]);
		}
		at += Vector2(d[6], d[7]) * (float)std::exp(-(double)d[24] * since);
		return Vector3(at.x, d[13], at.y);
	}
	double drawn = now - lag_after(d, std::max(now - d[15], 0.0));
	if (drawn <= d[8]) {
		return Vector3(d[0], d[13], d[1]);
	}
	for (int i = 0; i < 3; i++) {
		if (drawn <= d[9 + i]) {
			double span = (double)d[9 + i] - d[8 + i];
			double f = span > 1e-4 ? (drawn - d[8 + i]) / span : 1.0;
			return Vector3((float)lerp_d(d[i * 2], d[i * 2 + 2], f), d[13], (float)lerp_d(d[i * 2 + 1], d[i * 2 + 3], f));
		}
	}
	double span = (double)d[11] - d[10];
	if (span <= 1e-4) {
		return Vector3(d[6], d[13], d[7]);
	}
	double f = std::min((drawn - d[10]) / span, (double)d[23]);
	return Vector3((float)lerp_d(d[4], d[6], f), d[13], (float)lerp_d(d[5], d[7], f));
}

// robot_swarm.gd _slot_active for a record with all its floats (the caller checks the size).
bool slot_active(const float *d, double c_even, double c_odd, double inv_rate) {
	int flags = (int)d[12];
	double now = (flags & F_ODD) ? c_odd : c_even;
	double after = std::max(now - d[15], 0.0);
	if (after < 2.0) {
		return true;
	}
	if (flags & F_SIMULATED) {
		if (flags & F_SIM_ORBIT) {
			return true;
		}
		if (now < std::max((double)d[9], (double)d[10])) {
			return true;
		}
		double since = after * inv_rate;
		if (std::fabs((double)d[6]) + std::fabs((double)d[7]) > 1e-4 && std::exp(-(double)d[24] * since) > 1e-4) {
			return true;
		}
		bool had_leg2 = d[10] > d[9] + 1e-4;
		double since_yaw = had_leg2 ? std::max(now - std::max((double)d[15], (double)d[9]), 0.0) * inv_rate : since;
		double yaw_from = had_leg2 ? d[14] : d[16];
		double yaw_to = had_leg2 ? d[17] : d[14];
		return std::fabs(wrapf_g(yaw_from - yaw_to, -PI_D, PI_D)) * std::exp(-TURN_RATE * since_yaw) > 1e-4;
	}
	double since3 = after * inv_rate;
	if (std::fabs(wrapf_g((double)d[16] - d[17], -PI_D, PI_D)) * std::exp(-TURN_RATE * since3) > 1e-4) {
		return true;
	}
	double drawn = now - lag_after(d, after);
	double span3 = (double)d[11] - d[10];
	double end_drawn = span3 > 1e-4 ? (double)d[10] + (double)d[23] * span3 : (double)d[11];
	return drawn < end_drawn;
}

inline int64_t key_of(int64_t x, int64_t y) {
	return (x << 32) ^ (y & 0xffffffffLL);
}
inline int64_t floor_div(double v, double by) {
	return (int64_t)std::floor(v / by);
}
} // namespace

PackedVector3Array MoversNative::positions(const PackedFloat32Array &p_data, const PackedInt32Array &p_slots, int p_count,
		double p_c_even, double p_c_odd, double p_rate) {
	int n = std::min((int)p_slots.size(), p_count);
	PackedVector3Array out;
	if (n <= 0) {
		return out;
	}
	out.resize(n);
	Vector3 *o = out.ptrw();
	const float *data = p_data.ptr();
	const int64_t dsize = p_data.size();
	const int32_t *slots = p_slots.ptr();
	for (int i = 0; i < n; i++) {
		int slot = slots[i];
		if (slot < 0 || (int64_t)(slot + 1) * FLOATS > dsize) {
			o[i] = Vector3();
			continue;
		}
		o[i] = position_of(data + (int64_t)slot * FLOATS, p_c_even, p_c_odd, p_rate);
	}
	return out;
}

bool MoversNative::any_active(const PackedFloat32Array &p_data, const PackedInt32Array &p_slots, int p_count,
		double p_c_even, double p_c_odd, double p_inv_rate) {
	int n = std::min((int)p_slots.size(), p_count);
	const float *data = p_data.ptr();
	const int64_t dsize = p_data.size();
	const int32_t *slots = p_slots.ptr();
	for (int i = 0; i < n; i++) {
		int slot = slots[i];
		if (slot < 0) {
			continue;
		}
		int64_t o = (int64_t)slot * FLOATS;
		if (o + 28 >= dsize) {
			return true;
		}
		if (slot_active(data + o, p_c_even, p_c_odd, p_inv_rate)) {
			return true;
		}
	}
	return false;
}

void MoversNative::set_rail_params(double p_ramp_length, double p_elevation, double p_elevated_track, double p_cell, double p_chunk) {
	ramp_length = p_ramp_length;
	elevation = p_elevation;
	elevated_track = p_elevated_track;
	rail_cell = p_cell > 0.0 ? p_cell : 4.0;
	chunk_size = p_chunk > 0.0 ? p_chunk : 32.0;
}

void MoversNative::set_rail_chunk(const Vector2i &p_coord, const PackedInt32Array &p_cells, const PackedFloat64Array &p_entries) {
	RailChunk ch;
	const int32_t *cells = p_cells.ptr();
	const double *e = p_entries.ptr();
	const int64_t ne = p_entries.size() / 4;
	ch.entries.reserve((size_t)ne);
	for (int64_t i = 0; i < ne; i++) {
		RailEntry r;
		r.kind = (int)e[i * 4];
		r.at = Vector2((float)e[i * 4 + 1], (float)e[i * 4 + 2]);
		r.third = e[i * 4 + 3];
		ch.entries.push_back(r);
	}
	const int64_t nc = p_cells.size() / 4;
	for (int64_t i = 0; i < nc; i++) {
		int start = cells[i * 4 + 2];
		int count = cells[i * 4 + 3];
		if (start < 0 || count <= 0 || (int64_t)start + count > ne) {
			continue;
		}
		ch.cells[key_of(cells[i * 4], cells[i * 4 + 1])] = std::make_pair(start, count);
	}
	rail_chunks[key_of(p_coord.x, p_coord.y)] = std::move(ch);
}

void MoversNative::clear_rail_chunk(const Vector2i &p_coord) {
	rail_chunks.erase(key_of(p_coord.x, p_coord.y));
}

// The chunks world.gd rail_height reads for each point: its own and the neighbours whose rect grown by
// half a ramp and a tile holds it (the same test as there). Unique, as x, y pairs.
PackedInt32Array MoversNative::rail_chunks_for(const PackedVector2Array &p_points) const {
	PackedInt32Array out;
	std::unordered_map<int64_t, bool> seen;
	const float grow = (float)(ramp_length * 0.5 + 1.0);
	const float cs = (float)chunk_size;
	const Vector2 *pts = p_points.ptr();
	for (int64_t i = 0; i < p_points.size(); i++) {
		const Vector2 p = pts[i];
		int64_t cx = floor_div(p.x, chunk_size);
		int64_t cy = floor_div(p.y, chunk_size);
		for (int dy = -1; dy <= 1; dy++) {
			for (int dx = -1; dx <= 1; dx++) {
				int64_t x = cx + dx;
				int64_t y = cy + dy;
				if (dx != 0 || dy != 0) {
					float px = (float)(x * (int64_t)chunk_size) - grow;
					float py = (float)(y * (int64_t)chunk_size) - grow;
					float sz = cs + grow * 2.0f;
					if (p.x < px || p.y < py || p.x >= px + sz || p.y >= py + sz) {
						continue;
					}
				}
				int64_t k = key_of(x, y);
				if (seen.emplace(k, true).second) {
					out.push_back((int32_t)x);
					out.push_back((int32_t)y);
				}
			}
		}
	}
	return out;
}

double MoversNative::rail_height_of(const Vector2 &p_point, double p_was) const {
	bool ground = false;
	bool elevated = false;
	const int64_t cell = key_of(floor_div(p_point.x, rail_cell), floor_div(p_point.y, rail_cell));
	const int64_t cx = floor_div(p_point.x, chunk_size);
	const int64_t cy = floor_div(p_point.y, chunk_size);
	const float grow = (float)(ramp_length * 0.5 + 1.0);
	const float cs = (float)chunk_size;
	const double half = ramp_length * 0.5;
	for (int dy = -1; dy <= 1; dy++) {
		for (int dx = -1; dx <= 1; dx++) {
			int64_t x = cx + dx;
			int64_t y = cy + dy;
			auto it = rail_chunks.find(key_of(x, y));
			if (it == rail_chunks.end()) {
				continue;
			}
			if (dx != 0 || dy != 0) {
				// Rect2(c * CHUNK, (CHUNK, CHUNK)).grow(...).has_point(point)
				float px = (float)(x * (int64_t)chunk_size) - grow;
				float py = (float)(y * (int64_t)chunk_size) - grow;
				float sz = cs + grow * 2.0f;
				if (p_point.x < px || p_point.y < py || p_point.x >= px + sz || p_point.y >= py + sz) {
					continue;
				}
			}
			const RailChunk &ch = it->second;
			auto ci = ch.cells.find(cell);
			if (ci == ch.cells.end()) {
				continue;
			}
			const int end = ci->second.first + ci->second.second;
			for (int k = ci->second.first; k < end; k++) {
				const RailEntry &e = ch.entries[(size_t)k];
				if (e.kind == 2) {
					double a = -(-(double)(int)e.third / 16.0 * (PI_D * 2.0)); // -Wire.direction_yaw
					Vector2 uphill((float)std::sin(a), (float)-std::cos(a));
					Vector2 d = p_point - e.at;
					float along = d.dot(uphill);
					if (std::fabs((double)along) <= half && std::fabs((double)d.dot(Vector2(-uphill.y, uphill.x))) < 1.0) {
						// world.gd ramp_track_height
						double t = std::clamp((double)along / ramp_length + 0.5, 0.0, 1.0);
						t = std::clamp((t - 0.04) / 0.8, 0.0, 1.0);
						return elevation * (0.4 * t + 0.6 * t * t * (3.0 - 2.0 * t));
					}
				} else if ((double)p_point.distance_squared_to(e.at) <= e.third) {
					if (e.kind == 1) {
						elevated = true;
					} else {
						ground = true;
					}
				}
			}
		}
	}
	if (elevated && (!ground || p_was > elevated_track * 0.5)) {
		return elevated_track;
	}
	if (ground) {
		return 0.0;
	}
	return p_was;
}

PackedFloat64Array MoversNative::rail_heights(const PackedVector2Array &p_points, const PackedFloat64Array &p_was) const {
	PackedFloat64Array out;
	const int64_t n = p_points.size();
	out.resize(n);
	double *o = out.ptrw();
	const Vector2 *pts = p_points.ptr();
	const double *was = p_was.ptr();
	const int64_t nw = p_was.size();
	for (int64_t i = 0; i < n; i++) {
		o[i] = rail_height_of(pts[i], i < nw ? was[i] : 0.0);
	}
	return out;
}

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
	ClassDB::bind_method(D_METHOD("positions", "data", "slots", "count", "c_even", "c_odd", "rate"), &MoversNative::positions);
	ClassDB::bind_method(D_METHOD("any_active", "data", "slots", "count", "c_even", "c_odd", "inv_rate"), &MoversNative::any_active);
	ClassDB::bind_method(D_METHOD("set_rail_params", "ramp_length", "elevation", "elevated_track", "cell", "chunk"), &MoversNative::set_rail_params);
	ClassDB::bind_method(D_METHOD("set_rail_chunk", "coord", "cells", "entries"), &MoversNative::set_rail_chunk);
	ClassDB::bind_method(D_METHOD("clear_rail_chunk", "coord"), &MoversNative::clear_rail_chunk);
	ClassDB::bind_method(D_METHOD("clear_rails"), &MoversNative::clear_rails);
	ClassDB::bind_method(D_METHOD("rail_chunk_count"), &MoversNative::rail_chunk_count);
	ClassDB::bind_method(D_METHOD("rail_chunks_for", "points"), &MoversNative::rail_chunks_for);
	ClassDB::bind_method(D_METHOD("rail_heights", "points", "was"), &MoversNative::rail_heights);
	ClassDB::bind_method(D_METHOD("xform_of", "data", "slot", "c_even", "c_odd", "inv_rate"), &MoversNative::xform_of);
}
