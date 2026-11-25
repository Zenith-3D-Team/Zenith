// SPDX-License-Identifier: GPL-3.0-or-later
#include "decor_native.h"

#include <godot_cpp/variant/vector2.hpp>

#include <algorithm>
#include <cmath>
#include <vector>

using namespace godot;

// Godot's hash(Vector2i / Vector3i): murmur3 per component, then fmix32 (core/templates/hashfuncs.h).
static inline uint32_t rotl(uint32_t x, int r) { return (x << r) | (x >> (32 - r)); }
static inline uint32_t murmur_one(uint32_t p_in, uint32_t p_seed) {
	p_in *= 0xcc9e2d51u;
	p_in = rotl(p_in, 15);
	p_in *= 0x1b873593u;
	p_seed ^= p_in;
	p_seed = rotl(p_seed, 13);
	return p_seed * 5u + 0xe6546b64u;
}
static inline uint32_t fmix(uint32_t h) {
	h ^= h >> 16;
	h *= 0x85ebca6bu;
	h ^= h >> 13;
	h *= 0xc2b2ae35u;
	h ^= h >> 16;
	return h;
}
static const uint32_t SEED = 0x7F07C65u;
static inline uint32_t h2(int x, int y) {
	uint32_t h = murmur_one((uint32_t)x, SEED);
	h = murmur_one((uint32_t)y, h);
	return fmix(h);
}
static inline uint32_t h3(int x, int y, int z) {
	uint32_t h = murmur_one((uint32_t)x, SEED);
	h = murmur_one((uint32_t)y, h);
	h = murmur_one((uint32_t)z, h);
	return fmix(h);
}
static inline int posmod_i(int64_t a, int b) {
	int64_t m = a % b;
	return (int)(m < 0 ? m + b : m);
}
static inline int floor_div(int a, int b) {
	int q = a / b;
	return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q;
}

int64_t DecorNative::hash2(int p_x, int p_y) const { return h2(p_x, p_y); }
int64_t DecorNative::hash3(int p_x, int p_y, int p_z) const { return h3(p_x, p_y, p_z); }

Dictionary DecorNative::place(const PackedInt32Array &p_list, int p_cx, int p_cy, const PackedInt32Array &p_mask, double p_density) const {
	std::vector<int32_t> ids;
	std::vector<std::vector<int32_t>> tiles;
	std::vector<int32_t> slot_of; // linear search is fine: a chunk has few kinds
	const int32_t *l = p_list.ptr();
	const int n = p_list.size();
	const int32_t *mask = p_mask.ptr();
	const bool mask_ok = p_mask.size() >= CHUNK;
	const int dens = (int)(p_density * 1000.0);
	const bool thin = p_density < 1.0;
	for (int i = 0; i + 3 < n; i += 4) {
		int id = l[i], lx = l[i + 1], ly = l[i + 2];
		if (lx >= 0 && lx < CHUNK && ly >= 0 && ly < CHUNK && mask_ok && ((mask[ly] >> lx) & 1) == 1) {
			continue;
		}
		int x = p_cx * CHUNK + lx;
		int y = p_cy * CHUNK + ly;
		if (thin && posmod_i(h2(x, y), 1000) >= dens) {
			continue;
		}
		size_t s = 0;
		for (; s < ids.size(); s++) {
			if (ids[s] == id) {
				break;
			}
		}
		if (s == ids.size()) {
			ids.push_back(id);
			tiles.emplace_back();
		}
		tiles[s].push_back(x);
		tiles[s].push_back(y);
	}
	PackedInt32Array out_ids;
	Array out_tiles;
	for (size_t s = 0; s < ids.size(); s++) {
		out_ids.push_back(ids[s]);
		PackedInt32Array t;
		t.resize((int64_t)tiles[s].size());
		std::copy(tiles[s].begin(), tiles[s].end(), t.ptrw());
		out_tiles.push_back(t);
	}
	Dictionary d;
	d["ids"] = out_ids;
	d["tiles"] = out_tiles;
	return d;
}

Dictionary DecorNative::fill_group(const PackedInt32Array &p_tiles, const Dictionary &p_cfg, const PackedFloat32Array &p_uvs,
		const PackedFloat32Array &p_sizes, const PackedFloat32Array &p_shifts, const Array &p_blocks) const {
	const int cx = p_cfg["cx"];
	const int cy = p_cfg["cy"];
	const bool upright = p_cfg["upright"];
	const bool has_flat = p_cfg["has_flat"];
	const double lift0 = p_cfg["lift"];
	const double grass_height = p_cfg["grass_height"];
	const bool carpet = p_cfg["grass_carpet"];
	int rising = p_cfg["rising"];
	const bool flat_near = p_cfg["flat_near"];
	const int model_count = p_cfg["model_count"];
	const double model_scale = p_cfg["model_scale"];
	const double model_hs = p_cfg["model_hs"];
	const Vector2 model_shift = p_cfg["model_shift"];
	const bool has_models = model_count > 0;
	const int count = p_tiles.size() / 2;
	const int32_t *tl = p_tiles.ptr();
	const float *uvs = p_uvs.ptr();
	const float *sizes = p_sizes.ptr();
	const float *shifts = p_shifts.ptr();
	const int nuv = p_uvs.size() / 4;
	const int nsize = p_sizes.size() / 2;
	const int nshift = p_shifts.size() / 2;
	const int vmod = std::max(nuv, 1);

	std::vector<int> order(count);
	for (int i = 0; i < count; i++) {
		order[i] = i;
	}
	std::vector<uint32_t> key(count);
	for (int i = 0; i < count; i++) {
		key[i] = h3(tl[i * 2], tl[i * 2 + 1], 5);
	}
	std::stable_sort(order.begin(), order.end(), [&](int a, int b) { return key[a] < key[b]; });

	// Blocked-tile masks, 9 of them.
	PackedInt32Array bm[9];
	for (int i = 0; i < 9 && i < p_blocks.size(); i++) {
		bm[i] = p_blocks[i];
	}
	auto blocked = [&](int x, int y) -> bool {
		int dx = floor_div(x, CHUNK) - cx;
		int dy = floor_div(y, CHUNK) - cy;
		if (dx < -1 || dx > 1 || dy < -1 || dy > 1) {
			return false;
		}
		const PackedInt32Array &m = bm[(dy + 1) * 3 + (dx + 1)];
		return m.size() == CHUNK && ((m[posmod_i(y, CHUNK)] >> posmod_i(x, CHUNK)) & 1) == 1;
	};

	PackedInt32Array edge_tiles;
	if (grass_height > 0.0 && flat_near && !carpet) {
		std::vector<int> clear, edge;
		const double lean = grass_height * 0.9 + 0.1;
		for (int k : order) {
			int x = tl[k * 2], y = tl[k * 2 + 1];
			int v = posmod_i(h3(x, y, 11), vmod);
			float sx = v < nsize ? sizes[v * 2] : 1.0f, sy = v < nsize ? sizes[v * 2 + 1] : 1.0f;
			float hx = sx * 0.5f, hy = sy * 0.5f;
			float shx = v < nshift ? shifts[v * 2] : 0.0f, shy = v < nshift ? shifts[v * 2 + 1] : 0.0f;
			float ox = (float)(x + 0.5) + shx, oy = (float)(y + 0.5) + shy;
			bool hit = false;
			int ty0 = (int)std::floor((double)oy - (double)hy);
			int ty1 = (int)std::floor((double)oy + (double)hy + lean);
			int tx0 = (int)std::floor((double)ox - (double)hx);
			int tx1 = (int)std::floor((double)ox + (double)hx);
			for (int ty = ty0; ty <= ty1 && !hit; ty++) {
				for (int tx = tx0; tx <= tx1; tx++) {
					if (blocked(tx, ty)) {
						hit = true;
						break;
					}
				}
			}
			if (hit) {
				edge.push_back(k);
				edge_tiles.push_back(x);
				edge_tiles.push_back(y);
			} else {
				clear.push_back(k);
			}
		}
		if (!edge.empty()) {
			order = clear;
			order.insert(order.end(), edge.begin(), edge.end());
			rising = std::min(rising, (int)clear.size());
		}
	}

	PackedFloat32Array buffer;
	buffer.resize((int64_t)count * STRIDE);
	float *buf = buffer.ptrw();
	std::vector<float> edge_floats;
	int edge_mask = 0;
	const double x0c = (double)(cx * CHUNK), z0c = (double)(cy * CHUNK);
	const double x1c = x0c + CHUNK, z1c = z0c + CHUNK;
	std::vector<std::vector<float>> buckets(has_models ? model_count : 0);
	const double TAU_ = 6.283185307179586476925286766559;

	for (int j = 0; j < count; j++) {
		const int k = order[j];
		const int x = tl[k * 2], y = tl[k * 2 + 1];
		const int v = posmod_i(h3(x, y, 11), vmod);
		float sizex = 1.0f, sizey = 1.0f;
		if (v < nsize) {
			sizex = sizes[v * 2];
			sizey = sizes[v * 2 + 1];
		}
		float shx = 0.0f, shy = 0.0f;
		if (v < nshift) {
			shx = shifts[v * 2];
			shy = shifts[v * 2 + 1];
		}
		double lift = lift0 + 0.0012 * posmod_i(h2(x, y), 4);
		float ox = (float)(x + 0.5 + (double)shx), oy = (float)lift, oz = (float)(y + 0.5 + (double)shy);
		float sx = sizex, sy = 1.0f, sz = sizey;
		if (upright) {
			ox = (float)(x + 0.5 + (double)shx);
			oy = 0.0f;
			oz = (float)(y + 0.5);
			sx = sizex;
			sy = sizey;
			sz = 1.0f;
		}
		float *o = buf + (int64_t)j * STRIDE;
		o[0] = sx;
		o[3] = ox;
		o[5] = sy;
		o[7] = oy;
		o[10] = sz;
		o[11] = oz;
		float u0 = 0, u1 = 0, u2 = 0, u3 = 0;
		if (v < nuv) {
			u0 = uvs[v * 4];
			u1 = uvs[v * 4 + 1];
			u2 = uvs[v * 4 + 2];
			u3 = uvs[v * 4 + 3];
		}
		o[12] = u0;
		o[13] = u1;
		o[14] = u2;
		o[15] = j < rising ? (float)(1.0 + (double)u3) : 0.0f;
		if (has_models && (upright || j < rising)) {
			int mv = posmod_i(h3(x, y, 19), model_count);
			double ang = (double)(h3(x, y, 23) & 0xffff) / 65536.0 * TAU_;
			double cs = std::cos(ang), sn = std::sin(ang);
			double js = (0.86 + 0.28 * ((double)(h3(x, y, 29) & 0xffff) / 65536.0)) * model_scale;
			double jy = js * model_hs;
			double phase = (double)(h3(x, y, 31) & 0xffff) / 65536.0;
			double mox = (double)x + 0.5 + (double)model_shift.x;
			double moz = (double)y + 0.5 + (double)model_shift.y;
			std::vector<float> &b = buckets[mv];
			const float vals[16] = { (float)(cs * js), 0.0f, (float)(sn * js), (float)mox,
				0.0f, (float)jy, 0.0f, 0.0f,
				(float)(-sn * js), 0.0f, (float)(cs * js), (float)moz,
				(float)phase, 0.0f, 0.0f, 0.0f };
			b.insert(b.end(), vals, vals + 16);
		}
		if (!upright && has_flat) {
			double min_x = (double)ox - (double)sx * 0.5, max_x = (double)ox + (double)sx * 0.5;
			double min_z = (double)oz - (double)sz * 0.5, max_z = (double)oz + (double)sz * 0.5;
			int ddx0 = min_x < x0c ? -1 : 0;
			int ddx1 = max_x > x1c ? 1 : 0;
			int ddy0 = min_z < z0c ? -1 : 0;
			int ddy1 = max_z > z1c ? 1 : 0;
			if (ddx0 != 0 || ddx1 != 0 || ddy0 != 0 || ddy1 != 0) {
				for (int dy = ddy0; dy <= ddy1; dy++) {
					for (int dx = ddx0; dx <= ddx1; dx++) {
						if (dx != 0 || dy != 0) {
							edge_mask |= 1 << ((dy + 1) * 3 + (dx + 1));
						}
					}
				}
				const float ev[16] = { sx, 0.0f, 0.0f, ox, 0.0f, sy, 0.0f, oy, 0.0f, 0.0f, sz, oz, o[12], o[13], o[14], o[15] };
				edge_floats.insert(edge_floats.end(), ev, ev + 16);
			}
		}
	}

	Dictionary d;
	d["buffer"] = buffer;
	d["rising"] = rising;
	d["edge_tiles"] = edge_tiles;
	PackedFloat32Array ef;
	ef.resize((int64_t)edge_floats.size());
	if (!edge_floats.empty()) {
		std::copy(edge_floats.begin(), edge_floats.end(), ef.ptrw());
	}
	d["edge_floats"] = ef;
	d["edge_mask"] = edge_mask;
	Array out_buckets;
	for (auto &b : buckets) {
		PackedFloat32Array pb;
		pb.resize((int64_t)b.size());
		if (!b.empty()) {
			std::copy(b.begin(), b.end(), pb.ptrw());
		}
		out_buckets.push_back(pb);
	}
	d["buckets"] = out_buckets;
	return d;
}

void DecorNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("place", "list", "cx", "cy", "mask", "density"), &DecorNative::place);
	ClassDB::bind_method(D_METHOD("fill_group", "tiles", "cfg", "uvs", "sizes", "shifts", "blocks"), &DecorNative::fill_group);
	ClassDB::bind_method(D_METHOD("hash2", "x", "y"), &DecorNative::hash2);
	ClassDB::bind_method(D_METHOD("hash3", "x", "y", "z"), &DecorNative::hash3);
}
