// SPDX-License-Identifier: GPL-3.0-or-later
#include "terrain_field_native.h"

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <thread>
#include <vector>

using namespace godot;

namespace {

// heights.gd's constants (the cliffs' and tint's; the grid's own come as arguments).
constexpr double CLIFF_REACH = 96.0;
constexpr double CLIFF_NEAR = 24.0;
constexpr double CLIFF_END_RAMP = 16.0;
constexpr double CLIFF_STEP_FROM = -0.2;
constexpr double CLIFF_STEP_TO = 0.2;
constexpr double CLIFF_STEP_OLD_FROM = -1.2;
constexpr double CLIFF_STEP_OLD_TO = -0.2;
constexpr double TINT_NEAR = 1.5;
constexpr double TINT_LOW_REACH = 6.0;
constexpr double TINT_HIGH_REACH = 3.5;
constexpr int CLIFF_BLUR = 6;
constexpr double GAP_SLOPE = 10.0;
constexpr double GAP_SOFTEN = 6.0;
constexpr double CLIFF_NEAREST_FALLOFF = 0.5;
constexpr int CHUNK = 32;
constexpr int CLIFF_FLOATS = 11;

// GDScript's smoothstep, clampf, lerpf (doubles; `from` and `to` never equal here).
inline double ss(double from, double to, double x) {
	double s = (x - from) / (to - from);
	s = s < 0.0 ? 0.0 : (s > 1.0 ? 1.0 : s);
	return s * s * (3.0 - 2.0 * s);
}
inline double clampd(double v, double lo, double hi) {
	return v < lo ? lo : (v > hi ? hi : v);
}
inline double lerpd(double a, double b, double t) {
	return a + (b - a) * t;
}

// heights.gd _centre: float32, as GDScript's Vector2.
inline Vector2 centre(const Vector2 &origin, double step, int i, int j) {
	return origin + Vector2((real_t)(i + 0.5), (real_t)(j + 0.5)) * (real_t)step;
}

struct Cliff {
	Vector2 at, up;
	int kind; // 0 straight, 1 quarter circle
	Vector2 a, b, c;
};

// heights.gd line_offset.
Vector2 line_offset(const Cliff &l, const Vector2 &p) {
	if (l.kind == 0) {
		const Vector2 p0 = l.a;
		const Vector2 p1 = l.b;
		const real_t len = p0.distance_to(p1);
		const Vector2 dir = (p1 - p0) / len;
		const double t = (p - p0).dot(dir);
		return Vector2((real_t)std::max(std::max(-t, t - (double)len), 0.0), (p - p0).dot(Vector2(dir.y, -dir.x)));
	}
	const Vector2 c = l.a;
	const Vector2 e0 = l.b;
	const Vector2 e1 = l.c;
	const Vector2 d0 = (e0 - c) * (real_t)0.5;
	const Vector2 d1 = (e1 - c) * (real_t)0.5;
	const Vector2 v = p - c;
	const double a0 = v.dot(d0);
	const double a1 = v.dot(d1);
	const Vector2 up0(d1.y, -d1.x);
	if (a0 >= 0.0 && a1 >= 0.0) {
		const double r = v.length();
		return Vector2(0.0f, (real_t)(up0.dot(d0) > 0.0f ? (r - 2.0) : (2.0 - r)));
	}
	const double past0 = -a1;
	const double past1 = -a0;
	if (a1 < 0.0 && (a0 >= 0.0 || past0 <= past1)) {
		return Vector2((real_t)past0, (p - e0).dot(up0));
	}
	const Vector2 up1(-d0.y, d0.x);
	return Vector2((real_t)past1, (p - e1).dot(up1));
}

// heights.gd _box_blur.
std::vector<float> box_blur(const std::vector<float> &src, int size, int r) {
	std::vector<float> tmp(src.size());
	std::vector<float> out(src.size());
	const double span = double(2 * r + 1);
	for (int jj = 0; jj < size; jj++) {
		const int row = jj * size;
		double acc = 0.0;
		for (int ii = -r; ii <= r; ii++) {
			acc += src[row + std::clamp(ii, 0, size - 1)];
		}
		for (int ii = 0; ii < size; ii++) {
			tmp[row + ii] = (float)(acc / span);
			acc += (double)src[row + std::min(ii + r + 1, size - 1)] - (double)src[row + std::max(ii - r, 0)];
		}
	}
	for (int ii = 0; ii < size; ii++) {
		double acc = 0.0;
		for (int jj = -r; jj <= r; jj++) {
			acc += tmp[std::clamp(jj, 0, size - 1) * size + ii];
		}
		for (int jj = 0; jj < size; jj++) {
			out[jj * size + ii] = (float)(acc / span);
			acc += (double)tmp[std::min(jj + r + 1, size - 1) * size + ii] - (double)tmp[std::max(jj - r, 0) * size + ii];
		}
	}
	return out;
}

inline int floor_div(double v, double step) {
	return (int)std::floor(v / step);
}

} // namespace

void TerrainFieldNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("version"), &TerrainFieldNative::version);
	ClassDB::bind_method(D_METHOD("hills", "h", "size", "origin", "step", "noise_seed", "height", "hill_size", "detail",
								 "i0", "i1", "j0", "j1"),
			&TerrainFieldNative::hills);
	ClassDB::bind_method(D_METHOD("cliffs", "size", "origin", "step", "cliffs", "seat", "trace", "cliff_height"),
			&TerrainFieldNative::cliffs);
	ClassDB::bind_method(D_METHOD("water_distance", "size", "origin", "step", "wet"), &TerrainFieldNative::water_distance);
	ClassDB::bind_method(D_METHOD("base", "hills", "raise", "water", "size", "step", "shore", "edge", "with_cliffs"),
			&TerrainFieldNative::base);
	ClassDB::bind_method(D_METHOD("pads", "f", "size", "origin", "step", "pads", "margin"), &TerrainFieldNative::pads);
	ClassDB::bind_method(D_METHOD("interleave", "full", "ground", "tint", "channels"), &TerrainFieldNative::interleave);
}

PackedFloat32Array TerrainFieldNative::hills(const PackedFloat32Array &h, int size, Vector2 origin, double step,
		int noise_seed, double height, double hill_size, double detail, int i0, int i1, int j0, int j1) const {
	PackedFloat32Array out = h;
	if (out.size() != (int64_t)size * size) {
		out.resize((int64_t)size * size);
	}
	i0 = std::max(i0, 0);
	j0 = std::max(j0, 0);
	i1 = std::min(i1, size);
	j1 = std::min(j1, size);
	if (i1 <= i0 || j1 <= j0) {
		return out;
	}
	float *dst = out.ptrw();
	const double bumps = detail * 0.15 * height;
	// Rows shared out among threads, each with its own pair of Godot's noise (set as heights.gd sets them).
	auto work = [&](int ja, int jb) {
		Ref<FastNoiseLite> big;
		big.instantiate();
		big->set_noise_type(FastNoiseLite::TYPE_PERLIN);
		big->set_seed(noise_seed);
		big->set_frequency((float)(1.0 / std::max(hill_size, 8.0)));
		big->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
		big->set_fractal_octaves(3);
		big->set_fractal_gain(0.45f);
		Ref<FastNoiseLite> small;
		small.instantiate();
		small->set_noise_type(FastNoiseLite::TYPE_PERLIN);
		small->set_seed(noise_seed + 7919);
		small->set_frequency((float)(1.0 / 22.0));
		small->set_fractal_type(FastNoiseLite::FRACTAL_NONE);
		for (int j = ja; j < jb; j++) {
			const int row = j * size;
			for (int i = i0; i < i1; i++) {
				const Vector2 p = centre(origin, step, i, j);
				const double b = clampd((double)big->get_noise_2d(p.x, p.y) * 0.85 + 0.5, 0.0, 1.0);
				double v = height * b * b * (3.0 - 2.0 * b);
				if (bumps > 0.0) {
					v += bumps * (double)small->get_noise_2d(p.x, p.y);
				}
				dst[row + i] = (float)v;
			}
		}
	};
	const int rows = j1 - j0;
	const int64_t texels = (int64_t)rows * (i1 - i0);
	int threads = (int)std::min<unsigned>(std::max(std::thread::hardware_concurrency(), 1u), 8u);
	threads = (int)std::min<int64_t>(threads, std::max<int64_t>(texels / 16384, 1));
	threads = std::min(threads, rows);
	if (threads <= 1) {
		work(j0, j1);
		return out;
	}
	std::vector<std::thread> pool;
	for (int t = 0; t < threads; t++) {
		const int ja = j0 + rows * t / threads;
		const int jb = j0 + rows * (t + 1) / threads;
		pool.emplace_back(work, ja, jb);
	}
	for (std::thread &t : pool) {
		t.join();
	}
	return out;
}

Array TerrainFieldNative::cliffs(int size, Vector2 origin, double step, const PackedFloat32Array &cliffs_in, bool seat,
		bool trace, double cliff_height) const {
	const int n = size * size;
	PackedFloat32Array raise_out;
	raise_out.resize(n);
	PackedFloat32Array near_arr;
	near_arr.resize(n);
	float *raise = raise_out.ptrw();
	float *near_out = near_arr.ptrw();
	std::fill(raise, raise + n, 0.0f);
	std::fill(near_out, near_out + n, 0.0f);

	std::vector<Cliff> list;
	const float *cf = cliffs_in.ptr();
	const int count = (int)(cliffs_in.size() / CLIFF_FLOATS);
	list.reserve(count);
	for (int k = 0; k < count; k++) {
		const float *c = cf + k * CLIFF_FLOATS;
		list.push_back({ Vector2(c[0], c[1]), Vector2(c[2], c[3]), (int)c[4], Vector2(c[5], c[6]), Vector2(c[7], c[8]),
				Vector2(c[9], c[10]) });
	}

	std::vector<float> wsum(n, 0.0f), ssum(n, 0.0f), near(n, 1.0e9f), cover(n, 0.0f), inside, nearest;
	const int rad = (int)std::ceil(CLIFF_NEAR / step);
	const double step_from = seat ? CLIFF_STEP_FROM : CLIFF_STEP_OLD_FROM;
	const double step_to = seat ? CLIFF_STEP_TO : CLIFF_STEP_OLD_TO;
	std::vector<std::vector<Vector2>> offsets(trace ? list.size() : 0);
	if (trace) {
		nearest.assign(n, 1.0e9f);
	}
	auto in_reach = [&](int ci, int cj) {
		return !(ci < -rad || cj < -rad || ci >= size + rad || cj >= size + rad);
	};
	if (seat || trace) {
		inside.assign(n, 0.0f);
		for (size_t ck = 0; ck < list.size(); ck++) {
			const Cliff &c = list[ck];
			const Vector2 run(-c.up.y, c.up.x);
			const int ci = floor_div((double)c.at.x - (double)origin.x, step);
			const int cj = floor_div((double)c.at.y - (double)origin.y, step);
			if (!in_reach(ci, cj)) {
				continue;
			}
			std::vector<Vector2> *offs = trace ? &offsets[ck] : nullptr;
			for (int j2 = std::max(cj - rad, 0); j2 < std::min(cj + rad + 1, size); j2++) {
				for (int i2 = std::max(ci - rad, 0); i2 < std::min(ci + rad + 1, size); i2++) {
					const Vector2 p = centre(origin, step, i2, j2);
					double ins = 0.0;
					const int idx = j2 * size + i2;
					if (trace) {
						const Vector2 off = line_offset(c, p);
						offs->push_back(off);
						if (std::fabs((double)off.y) <= CLIFF_NEAR) {
							ins = 1.0 - clampd(off.x, 0.0, 1.0);
						}
						const double dd0 = off.length();
						if (dd0 < nearest[idx]) {
							nearest[idx] = (float)dd0;
						}
					} else {
						const Vector2 rel = p - c.at;
						ins = 1.0 - clampd(std::fabs((double)rel.dot(run)) - 2.0, 0.0, 1.0);
					}
					if (ins > inside[idx]) {
						inside[idx] = (float)ins;
					}
				}
			}
		}
	}
	for (size_t ck = 0; ck < list.size(); ck++) {
		const Cliff &c = list[ck];
		const Vector2 run(-c.up.y, c.up.x);
		const int ci = floor_div((double)c.at.x - (double)origin.x, step);
		const int cj = floor_div((double)c.at.y - (double)origin.y, step);
		if (!in_reach(ci, cj)) {
			continue;
		}
		size_t at_off = 0;
		for (int j2 = std::max(cj - rad, 0); j2 < std::min(cj + rad + 1, size); j2++) {
			for (int i2 = std::max(ci - rad, 0); i2 < std::min(ci + rad + 1, size); i2++) {
				double past = 0.0;
				double side = 0.0;
				double along = 0.0;
				if (trace) {
					const Vector2 off = offsets[ck][at_off++];
					past = off.x;
					side = off.y;
					along = past + 2.0;
				} else {
					const Vector2 rel = centre(origin, step, i2, j2) - c.at;
					along = std::fabs((double)rel.dot(run));
					side = rel.dot(c.up);
				}
				const double dd = Vector2((real_t)std::max(along - 2.0, 0.0), (real_t)side).length();
				if (dd > CLIFF_NEAR) {
					continue;
				}
				double open = clampd((along - 2.0) / GAP_SOFTEN, 0.0, 1.0);
				const int idx = j2 * size + i2;
				if (seat || trace) {
					open *= 1.0 - inside[idx];
				}
				const double widen = open * GAP_SLOPE * 0.5;
				const double k = ss(step_from - widen, step_to + widen, side);
				double w = 1.0 / (1.0 + dd * dd * 0.25);
				if (trace) {
					w *= std::max(1.0 - clampd(past, 0.0, 1.0), 1.0 - inside[idx]);
					w *= std::exp(-(dd - nearest[idx]) * CLIFF_NEAREST_FALLOFF * inside[idx]);
				}
				wsum[idx] = (float)(wsum[idx] + w);
				ssum[idx] = (float)(ssum[idx] + w * k);
				const double cv = 1.0 - ss(0.0, CLIFF_END_RAMP, along - 2.0);
				if (cv > cover[idx]) {
					cover[idx] = (float)cv;
				}
				const double reach = side > 0.0 ? TINT_HIGH_REACH : TINT_LOW_REACH;
				const double tint = (1.0 - ss(TINT_NEAR, reach, dd)) * cv;
				if (tint > near_out[idx]) {
					near_out[idx] = (float)tint;
				}
				if (dd < near[idx]) {
					near[idx] = (float)dd;
				}
			}
		}
	}
	// The near band's blended side, carried outwards (a two-pass chamfer).
	std::vector<float> val(n, 0.0f), d(n, 1.0e9f);
	for (int idx = 0; idx < n; idx++) {
		if (wsum[idx] > 0.0f) {
			val[idx] = (float)((double)ssum[idx] / (double)wsum[idx] * (double)cover[idx]);
			d[idx] = 0.0f;
		}
	}
	constexpr double A = 1.0;
	constexpr double B = 1.4142;
	auto take = [&](int idx, int from, double cost) {
		const double s = (double)d[from] + cost;
		if (s < d[idx]) {
			d[idx] = (float)s;
			val[idx] = val[from];
		}
	};
	for (int jj = 0; jj < size; jj++) {
		for (int ii = 0; ii < size; ii++) {
			const int idx = jj * size + ii;
			if (ii > 0) {
				take(idx, idx - 1, A);
			}
			if (jj > 0) {
				take(idx, idx - size, A);
				if (ii > 0) {
					take(idx, idx - size - 1, B);
				}
				if (ii < size - 1) {
					take(idx, idx - size + 1, B);
				}
			}
		}
	}
	for (int jj = size - 1; jj >= 0; jj--) {
		for (int ii = size - 1; ii >= 0; ii--) {
			const int idx = jj * size + ii;
			if (ii < size - 1) {
				take(idx, idx + 1, A);
			}
			if (jj < size - 1) {
				take(idx, idx + size, A);
				if (ii < size - 1) {
					take(idx, idx + size + 1, B);
				}
				if (ii > 0) {
					take(idx, idx + size - 1, B);
				}
			}
		}
	}
	const std::vector<float> soft = box_blur(val, size, CLIFF_BLUR);
	for (int idx = 0; idx < n; idx++) {
		const double tiles = d[idx] == 0.0f ? (double)near[idx] : CLIFF_NEAR + (double)d[idx] * step;
		if (tiles > CLIFF_REACH) {
			continue;
		}
		const double t = ss(CLIFF_NEAR, CLIFF_NEAR * 2.0, tiles);
		double v = lerpd(val[idx], soft[idx], t);
		v *= 1.0 - ss(CLIFF_REACH * 0.6, CLIFF_REACH, tiles);
		raise[idx] = (float)(cliff_height * v);
	}
	Array result;
	result.append(raise_out);
	result.append(near_arr);
	return result;
}

PackedFloat32Array TerrainFieldNative::water_distance(int size, Vector2 origin, double step, const Dictionary &wet) const {
	const int n = size * size;
	PackedFloat32Array out;
	out.resize(n);
	float *d = out.ptrw();
	std::fill(d, d + n, 1.0e9f);
	bool any = false;
	const Array keys = wet.keys();
	for (int64_t k = 0; k < keys.size(); k++) {
		const Variant key = keys[k];
		if (key.get_type() != Variant::VECTOR2I) {
			continue;
		}
		const Vector2i chunk = key;
		const PackedByteArray kinds = wet[key];
		if (kinds.size() < CHUNK * CHUNK) {
			continue;
		}
		const uint8_t *kp = kinds.ptr();
		const Vector2 base((real_t)(chunk.x * CHUNK), (real_t)(chunk.y * CHUNK));
		for (int ty = 0; ty < CHUNK; ty++) {
			for (int tx = 0; tx < CHUNK; tx++) {
				if (kp[ty * CHUNK + tx] == 0) {
					continue;
				}
				const int i = floor_div((double)base.x + tx + 0.5 - (double)origin.x, step);
				const int j = floor_div((double)base.y + ty + 0.5 - (double)origin.y, step);
				if (i < 0 || j < 0 || i >= size || j >= size) {
					continue;
				}
				d[j * size + i] = 0.0f;
				any = true;
			}
		}
	}
	if (!any) {
		return PackedFloat32Array();
	}
	constexpr double A = 1.0;
	constexpr double B = 1.4142;
	for (int j = 0; j < size; j++) {
		for (int i = 0; i < size; i++) {
			const int idx = j * size + i;
			double v = d[idx];
			if (i > 0) {
				v = std::min(v, d[idx - 1] + A);
			}
			if (j > 0) {
				v = std::min(v, d[idx - size] + A);
				if (i > 0) {
					v = std::min(v, d[idx - size - 1] + B);
				}
				if (i < size - 1) {
					v = std::min(v, d[idx - size + 1] + B);
				}
			}
			d[idx] = (float)v;
		}
	}
	for (int j = size - 1; j >= 0; j--) {
		for (int i = size - 1; i >= 0; i--) {
			const int idx = j * size + i;
			double v = d[idx];
			if (i < size - 1) {
				v = std::min(v, d[idx + 1] + A);
			}
			if (j < size - 1) {
				v = std::min(v, d[idx + size] + A);
				if (i < size - 1) {
					v = std::min(v, d[idx + size + 1] + B);
				}
				if (i > 0) {
					v = std::min(v, d[idx + size - 1] + B);
				}
			}
			d[idx] = (float)v;
		}
	}
	return out;
}

Array TerrainFieldNative::base(const PackedFloat32Array &hills_in, const PackedFloat32Array &raise_in,
		const PackedFloat32Array &water, int size, double step, double shore, int edge, bool with_cliffs) const {
	const int n = size * size;
	PackedFloat32Array h = hills_in;
	PackedFloat32Array r = raise_in;
	h.resize(n);
	r.resize(n);
	float *hp = h.ptrw();
	float *rp = r.ptrw();
	if (water.size() == n) {
		const float *wd = water.ptr();
		for (int idx = 0; idx < n; idx++) {
			const double tiles = std::max((double)wd[idx] - 1.0, 0.0) * step;
			const double k = ss(0.0, shore, tiles);
			hp[idx] = (float)(hp[idx] * k);
			rp[idx] = (float)(rp[idx] * k);
		}
	}
	// The edges: faded to 0 over the last `edge` texels (heights.gd _edges).
	for (int j = 0; j < size; j++) {
		const int fj = std::min(j, size - 1 - j);
		for (int i = 0; i < size; i++) {
			const int f = std::min(std::min(i, size - 1 - i), fj);
			if (f >= edge) {
				i = size - 1 - edge; // skip to the row's right-hand border
				continue;
			}
			const double k = ss(0.0, (double)edge, (double)f);
			const int idx = j * size + i;
			hp[idx] = (float)(hp[idx] * k);
			rp[idx] = (float)(rp[idx] * k);
		}
	}
	PackedFloat32Array sum = h;
	double lo = 0.0;
	double hi = 0.0;
	for (int idx = 0; idx < n; idx++) {
		lo = std::min(lo, (double)hp[idx]);
		hi = std::max(hi, (double)hp[idx]);
	}
	if (with_cliffs) {
		sum = PackedFloat32Array();
		sum.resize(n);
		float *sp = sum.ptrw();
		for (int idx = 0; idx < n; idx++) {
			sp[idx] = (float)((double)hp[idx] + (double)rp[idx]);
			lo = std::min(lo, (double)sp[idx]);
			hi = std::max(hi, (double)sp[idx]);
		}
	}
	Array result;
	result.append(h);
	result.append(sum);
	result.append(Vector2((real_t)lo, (real_t)hi));
	return result;
}

PackedFloat32Array TerrainFieldNative::pads(const PackedFloat32Array &f_in, int size, Vector2 origin, double step,
		const PackedVector2Array &pads_in, double margin) const {
	const int n = size * size;
	PackedFloat32Array out = f_in;
	out.resize(n);
	float *f = out.ptrw();
	const int count = (int)(pads_in.size() / 2);
	if (count == 0) {
		return out;
	}
	const Vector2 *pp = pads_in.ptr();
	std::vector<float> wsum(n, 0.0f), hsum(n, 0.0f), levels(count);
	for (int k = 0; k < count; k++) {
		const Vector2 at = pp[k * 2];
		const int i = std::clamp(floor_div((double)at.x - (double)origin.x, step), 0, size - 1);
		const int j = std::clamp(floor_div((double)at.y - (double)origin.y, step), 0, size - 1);
		levels[k] = f[j * size + i];
	}
	for (int k = 0; k < count; k++) {
		const Vector2 at = pp[k * 2];
		const Vector2 half = pp[k * 2 + 1];
		const Vector2 reach = half + Vector2((real_t)margin, (real_t)margin);
		const int i0 = std::max(floor_div((double)at.x - (double)reach.x - (double)origin.x, step), 0);
		const int i1 = std::min(floor_div((double)at.x + (double)reach.x - (double)origin.x, step), size - 1);
		const int j0 = std::max(floor_div((double)at.y - (double)reach.y - (double)origin.y, step), 0);
		const int j1 = std::min(floor_div((double)at.y + (double)reach.y - (double)origin.y, step), size - 1);
		for (int j = j0; j <= j1; j++) {
			for (int i = i0; i <= i1; i++) {
				const Vector2 c = centre(origin, step, i, j);
				const double o = Vector2((real_t)std::max(std::fabs((double)c.x - (double)at.x) - (double)half.x, 0.0),
						(real_t)std::max(std::fabs((double)c.y - (double)at.y) - (double)half.y, 0.0))
										 .length();
				const double w = 1.0 - ss(0.0, margin, o);
				if (w <= 0.0) {
					continue;
				}
				const int idx = j * size + i;
				wsum[idx] = (float)(wsum[idx] + w);
				hsum[idx] = (float)(hsum[idx] + w * levels[k]);
			}
		}
	}
	for (int idx = 0; idx < n; idx++) {
		const double w = wsum[idx];
		if (w > 0.0) {
			f[idx] = (float)lerpd(f[idx], (double)hsum[idx] / w, std::min(w, 1.0));
		}
	}
	return out;
}

PackedFloat32Array TerrainFieldNative::interleave(const PackedFloat32Array &full, const PackedFloat32Array &ground,
		const PackedFloat32Array &tint, int channels) const {
	const int64_t n = std::min(full.size(), ground.size());
	const int ch = channels >= 3 ? 3 : 2;
	PackedFloat32Array out;
	out.resize(n * ch);
	float *o = out.ptrw();
	const float *fp = full.ptr();
	const float *gp = ground.ptr();
	const float *tp = (ch == 3 && tint.size() == n) ? tint.ptr() : nullptr;
	for (int64_t idx = 0; idx < n; idx++) {
		o[idx * ch] = fp[idx];
		o[idx * ch + 1] = gp[idx];
		if (ch == 3) {
			o[idx * ch + 2] = tp ? tp[idx] : 0.0f;
		}
	}
	return out;
}
