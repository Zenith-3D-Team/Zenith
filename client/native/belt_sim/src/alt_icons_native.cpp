// SPDX-License-Identifier: GPL-3.0-or-later
#include "alt_icons_native.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>

using namespace godot;

// alt_overlay.gd's _order_key: the depth along the view, in 64-bit floats from the 32-bit components, summed
// left to right as GDScript does (no contraction: MSVC's /fp:precise does not fuse).
static inline double order_key(double p_fx, double p_fy, double p_fz, double p_ax, double p_ay, double p_az) {
	double a = p_fx * p_ax;
	double b = p_fy * p_ay;
	double c = p_fz * p_az;
	double s = a + b;
	return s + c;
}

template <typename T>
static inline bool same_bytes(const T &p_a, const T &p_b) {
	const int64_t n = p_a.size();
	if (n != p_b.size()) {
		return false;
	}
	if (n == 0) {
		return true;
	}
	return std::memcmp(p_a.ptr(), p_b.ptr(), (size_t)n * sizeof(*p_a.ptr())) == 0;
}

bool AltIconsNative::set_chunk(Vector2i p_c, const PackedVector3Array &p_anchors, const PackedFloat32Array &p_refs,
		const PackedInt32Array &p_cell_start, const PackedInt32Array &p_cell_count, const PackedByteArray &p_skip,
		const PackedVector2Array &p_cell_offset, const PackedFloat32Array &p_cell_side,
		const PackedFloat32Array &p_cell_pic) {
	const int64_t ne = p_anchors.size();
	const int64_t nc = p_cell_offset.size();
	bool valid = p_refs.size() == ne && p_cell_start.size() == ne && p_cell_count.size() == ne && p_skip.size() == ne
			&& p_cell_side.size() == nc && p_cell_pic.size() == nc;
	if (valid) {
		const int32_t *st = p_cell_start.ptr();
		const int32_t *cn = p_cell_count.ptr();
		for (int64_t i = 0; i < ne && valid; i++) {
			valid = st[i] >= 0 && cn[i] >= 0 && (int64_t)st[i] + cn[i] <= nc;
		}
	}
	ERR_FAIL_COND_V_MSG(!valid, false, "AltIconsNative.set_chunk: arrays of mismatched sizes or cells out of range");
	const int64_t k = key_of(p_c.x, p_c.y);
	auto it = chunks.find(k);
	if (it != chunks.end()) {
		Chunk &ch = it->second;
		if (same_bytes(ch.anchors, p_anchors) && same_bytes(ch.refs, p_refs) && same_bytes(ch.cell_start, p_cell_start)
				&& same_bytes(ch.cell_count, p_cell_count) && same_bytes(ch.skip, p_skip)
				&& same_bytes(ch.cell_offset, p_cell_offset) && same_bytes(ch.cell_side, p_cell_side)
				&& same_bytes(ch.cell_pic, p_cell_pic)) {
			return false;
		}
	}
	Chunk &ch = chunks[k];
	ch.x = p_c.x;
	ch.y = p_c.y;
	ch.anchors = p_anchors;
	ch.refs = p_refs;
	ch.cell_start = p_cell_start;
	ch.cell_count = p_cell_count;
	ch.skip = p_skip;
	ch.cell_offset = p_cell_offset;
	ch.cell_side = p_cell_side;
	ch.cell_pic = p_cell_pic;
	ch.block_ok = false;
	return true;
}

bool AltIconsNative::erase_chunk(Vector2i p_c) {
	return chunks.erase(key_of(p_c.x, p_c.y)) > 0;
}

bool AltIconsNative::has_chunk(Vector2i p_c) const {
	return chunks.find(key_of(p_c.x, p_c.y)) != chunks.end();
}

void AltIconsNative::clear() {
	chunks.clear();
	last_count = 0;
}

int AltIconsNative::chunk_count() const {
	return (int)chunks.size();
}

int AltIconsNative::instance_count() const {
	return last_count;
}

// _gpu_fill: key = ((1 << 30) - clamp(floor(order_key * 256), +-2^30)) << 21 | n, sorted ascending.
void AltIconsNative::fill(Chunk &p_ch, const Vector3 &p_fwd) {
	if (p_ch.block_ok && p_ch.bfx == p_fwd.x && p_ch.bfy == p_fwd.y && p_ch.bfz == p_fwd.z) {
		return;
	}
	const double fx = (double)p_fwd.x, fy = (double)p_fwd.y, fz = (double)p_fwd.z;
	const int64_t ne = p_ch.anchors.size();
	const Vector3 *anc = p_ch.anchors.ptr();
	const int32_t *st = p_ch.cell_start.ptr();
	const int32_t *cn = p_ch.cell_count.ptr();
	const uint8_t *sk = p_ch.skip.ptr();
	sort_keys.clear();
	inst_ent.clear();
	inst_cell.clear();
	int64_t n = 0;
	const int64_t lim = (int64_t)1 << 30;
	for (int64_t ei = 0; ei < ne; ei++) {
		if (sk[ei] != 0) {
			continue;  // a beacon's modules: on the CPU while hovered
		}
		const Vector3 at = anc[ei];
		double f = std::floor(order_key(fx, fy, fz, (double)at.x, (double)at.y, (double)at.z) * 256.0);
		int64_t q = (int64_t)f;
		q = std::min(std::max(q, -lim), lim);
		const int64_t hi = (lim - q) << 21;
		for (int32_t ci = st[ei]; ci < st[ei] + cn[ei]; ci++) {
			sort_keys.push_back(hi | n);
			inst_ent.push_back((int32_t)ei);
			inst_cell.push_back(ci);
			n++;
		}
	}
	std::sort(sort_keys.begin(), sort_keys.end());
	p_ch.block.assign((size_t)n * FLOATS, 0.0f);
	const float *rf = p_ch.refs.ptr();
	const Vector2 *off = p_ch.cell_offset.ptr();
	const float *sd = p_ch.cell_side.ptr();
	const float *pc = p_ch.cell_pic.ptr();
	float *d = p_ch.block.data();
	const int64_t mask = ((int64_t)1 << 21) - 1;
	for (int64_t k = 0; k < n; k++) {
		const int64_t i = sort_keys[(size_t)k] & mask;
		const int32_t ei = inst_ent[(size_t)i];
		const int32_t ci = inst_cell[(size_t)i];
		const Vector3 at = anc[ei];
		float *o = d + k * FLOATS;
		o[0] = 1.0f;
		o[5] = 1.0f;
		o[8] = off[ci].x;
		o[9] = off[ci].y;
		o[10] = sd[ci];
		o[11] = pc[ci];
		o[12] = at.x;
		o[13] = at.y;
		o[14] = at.z;
		o[15] = rf[ei];
	}
	p_ch.block_ok = true;
	p_ch.bfx = p_fwd.x;
	p_ch.bfy = p_fwd.y;
	p_ch.bfz = p_fwd.z;
}

namespace {
struct Order {
	double key;
	int x;
	int y;
	void *ch;
};
} // namespace

// _gpu_sort_chunks: by -order_key(fwd, chunk centre) ascending, ties by x then y; then each chunk's block.
PackedFloat32Array AltIconsNative::build(Vector3 p_fwd) {
	const double fx = (double)p_fwd.x, fy = (double)p_fwd.y, fz = (double)p_fwd.z;
	std::vector<Order> list;
	list.reserve(chunks.size());
	int64_t total = 0;
	for (auto &kv : chunks) {
		Chunk &ch = kv.second;
		// Vector3(c.x * 32.0 + 16.0, 0.0, c.y * 32.0 + 16.0): 32-bit components.
		const float cx = (float)(ch.x * 32.0 + 16.0);
		const float cz = (float)(ch.y * 32.0 + 16.0);
		list.push_back({ -order_key(fx, fy, fz, (double)cx, 0.0, (double)cz), ch.x, ch.y, &ch });
		fill(ch, p_fwd);
		total += (int64_t)ch.block.size();
	}
	std::sort(list.begin(), list.end(), [](const Order &a, const Order &b) {
		if (a.key != b.key) {
			return a.key < b.key;
		}
		if (a.x != b.x) {
			return a.x < b.x;
		}
		return a.y < b.y;
	});
	PackedFloat32Array out;
	out.resize(total);
	float *w = out.ptrw();
	int64_t at = 0;
	for (const Order &e : list) {
		const Chunk &ch = *(const Chunk *)e.ch;
		const size_t sz = ch.block.size();
		if (sz > 0) {
			std::memcpy(w + at, ch.block.data(), sz * sizeof(float));
			at += (int64_t)sz;
		}
	}
	last_count = (int)(total / FLOATS);
	return out;
}

PackedFloat32Array AltIconsNative::chunk_data(Vector2i p_c, Vector3 p_fwd) {
	PackedFloat32Array out;
	auto it = chunks.find(key_of(p_c.x, p_c.y));
	if (it == chunks.end()) {
		return out;
	}
	fill(it->second, p_fwd);
	const std::vector<float> &b = it->second.block;
	out.resize((int64_t)b.size());
	if (!b.empty()) {
		std::memcpy(out.ptrw(), b.data(), b.size() * sizeof(float));
	}
	return out;
}

// Image.FORMAT_RF / RGF / RGBF: 1, 2 or 3 32-bit floats a texel (ground_height.gd keeps no other format).
static int64_t channels_of(int64_t p_format) {
	if (p_format == Image::FORMAT_RGBF) {
		return 3;
	}
	return p_format == Image::FORMAT_RGF ? 2 : 1;
}

void AltIconsNative::set_field(const Array &p_state) {
	field = Field();
	prev = Field();
	field_on = false;
	ERR_FAIL_COND_MSG(p_state.size() < 11, "AltIconsNative.set_field: a sample_state() of 11 entries expected");
	if (!(bool)p_state[0]) {
		return;
	}
	auto take = [](Field &f, const Variant &p_data, const Variant &p_format, const Variant &p_origin,
						const Variant &p_step, const Variant &p_size) {
		f.data = p_data;
		f.channels = channels_of((int64_t)p_format);
		const Vector2 o = p_origin;
		f.ox = (double)o.x;
		f.oz = (double)o.y;
		f.step = (double)p_step;
		const Vector2i sz = p_size;
		f.sx = sz.x;
		f.sz = sz.y;
		f.ok = f.sx > 0 && f.sz > 0 && f.data.size() >= f.sx * f.sz * f.channels * (int64_t)sizeof(float);
	};
	take(field, p_state[1], p_state[2], p_state[3], p_state[4], p_state[5]);
	take(prev, p_state[6], p_state[7], p_state[8], p_state[9], p_state[10]);
	field_on = field.ok;
}

// Godot's Math::lerp (GDScript's lerpf): from + (to - from) * weight, in doubles.
static inline double lerp_d(double p_from, double p_to, double p_weight) {
	return p_from + (p_to - p_from) * p_weight;
}

static inline int64_t clamp_i(int64_t p_v, int64_t p_lo, int64_t p_hi) {
	return p_v < p_lo ? p_lo : (p_v > p_hi ? p_hi : p_v);
}

// ground_height.gd's _at_in, channel 0: bilinear between texel centres at origin + (i + 0.5) * step, 0 outside.
double AltIconsNative::at_in(const Field &p_f, double p_x, double p_z) {
	const double gx = (p_x - p_f.ox) / p_f.step - 0.5;
	const double gz = (p_z - p_f.oz) / p_f.step - 0.5;
	if (gx < -0.5 || gz < -0.5 || gx > (double)p_f.sx - 0.5 || gz > (double)p_f.sz - 0.5) {
		return 0.0;
	}
	const int64_t ix = (int64_t)std::floor(gx);
	const int64_t iz = (int64_t)std::floor(gz);
	const double fx = gx - (double)ix;
	const double fz = gz - (double)iz;
	const int64_t x0 = clamp_i(ix, 0, p_f.sx - 1);
	const int64_t x1 = clamp_i(ix + 1, 0, p_f.sx - 1);
	const int64_t z0 = clamp_i(iz, 0, p_f.sz - 1);
	const int64_t z1 = clamp_i(iz + 1, 0, p_f.sz - 1);
	const float *d = (const float *)p_f.data.ptr();
	const int64_t ch = p_f.channels;
	const double a = lerp_d((double)d[(z0 * p_f.sx + x0) * ch], (double)d[(z0 * p_f.sx + x1) * ch], fx);
	const double b = lerp_d((double)d[(z1 * p_f.sx + x0) * ch], (double)d[(z1 * p_f.sx + x1) * ch], fx);
	return lerp_d(a, b, fz);
}

PackedVector3Array AltIconsNative::lift(const PackedVector3Array &p_anchors, const PackedFloat64Array &p_flat,
		double p_mix) const {
	PackedVector3Array out = p_anchors;
	const int64_t n = p_anchors.size();
	ERR_FAIL_COND_V_MSG(p_flat.size() != n, out, "AltIconsNative.lift: anchors and flat heights of different sizes");
	if (n == 0) {
		return out;
	}
	Vector3 *w = out.ptrw();
	const double *fl = p_flat.ptr();
	for (int64_t i = 0; i < n; i++) {
		const double x = (double)w[i].x;
		const double z = (double)w[i].z;
		double h = 0.0;
		if (field_on) {
			h = at_in(field, x, z);
			if (p_mix < 1.0) {
				const double p = prev.ok ? at_in(prev, x, z) : 0.0;
				h = lerp_d(p, h, p_mix);
			}
		}
		w[i].y = (real_t)(fl[i] + h);
	}
	return out;
}

void AltIconsNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_chunk", "c", "anchors", "refs", "cell_start", "cell_count", "skip",
								 "cell_offset", "cell_side", "cell_pic"),
			&AltIconsNative::set_chunk);
	ClassDB::bind_method(D_METHOD("erase_chunk", "c"), &AltIconsNative::erase_chunk);
	ClassDB::bind_method(D_METHOD("has_chunk", "c"), &AltIconsNative::has_chunk);
	ClassDB::bind_method(D_METHOD("clear"), &AltIconsNative::clear);
	ClassDB::bind_method(D_METHOD("chunk_count"), &AltIconsNative::chunk_count);
	ClassDB::bind_method(D_METHOD("instance_count"), &AltIconsNative::instance_count);
	ClassDB::bind_method(D_METHOD("build", "fwd"), &AltIconsNative::build);
	ClassDB::bind_method(D_METHOD("chunk_data", "c", "fwd"), &AltIconsNative::chunk_data);
	ClassDB::bind_method(D_METHOD("set_field", "state"), &AltIconsNative::set_field);
	ClassDB::bind_method(D_METHOD("lift", "anchors", "flat", "mix"), &AltIconsNative::lift);
}
