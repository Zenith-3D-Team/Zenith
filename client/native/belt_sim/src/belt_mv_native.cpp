#include "belt_mv_native.h"
#include "belt_native_common.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>

using namespace godot;

namespace {

inline int band_of_key(int64_t key) {
	return key >= 0 ? (int)(key / BeltMvNative::BAND_STEP) : 0;
}

inline void write_slot(float *dst, float cx, float cy, float px, float py, float pz,
		float c0, float c1, float c2, float c3) {
	dst[0] = cx;
	dst[1] = 0.0f;
	dst[2] = cy;
	dst[3] = px;
	dst[4] = 0.0f;
	dst[5] = 1.0f;
	dst[6] = 0.0f;
	dst[7] = py;
	dst[8] = -cy;
	dst[9] = 0.0f;
	dst[10] = cx;
	dst[11] = pz;
	dst[12] = c0;
	dst[13] = c1;
	dst[14] = c2;
	dst[15] = c3;
}

inline void hide_slot(float *dst) {
	dst[0] = 1.0f;
	dst[1] = 0.0f;
	dst[2] = 0.0f;
	dst[3] = 0.0f;
	dst[4] = 0.0f;
	dst[5] = 1.0f;
	dst[6] = 0.0f;
	dst[7] = 0.0f;
	dst[8] = 0.0f;
	dst[9] = 0.0f;
	dst[10] = 1.0f;
	dst[11] = 0.0f;
	dst[12] = 0.0f;
	dst[13] = 0.0f;
	dst[14] = 0.0f;
	dst[15] = BeltMvNative::HIDE_CLOCK;
}

inline float clamp01(float v) {
	return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
}

inline void push_update(Array &out, int64_t item_id, bool is_lattice,
		const PackedFloat32Array &buf, int vis, int inst_cap, bool restore_to_records) {
	Array entry;
	entry.resize(6);
	entry[0] = item_id;
	entry[1] = is_lattice;
	entry[2] = buf;
	entry[3] = vis;
	entry[4] = inst_cap;
	entry[5] = restore_to_records;
	out.append(entry);
}

} // namespace

void BeltMvNative::reset() {
	rec_pages.clear();
	rec_per_page = 0;
	lat_pages.clear();
	lat_per_page = 0;
	paths.clear();
	paths_w = 0;
	mask_tiles.clear();
	mask_w = 0;
	mask_h = 0;
	mask_on = false;
	rec_kinds.clear();
	lat_kinds.clear();
	rec_order.clear();
	lat_order.clear();
	last_clock = -1.0e20f;
}

void BeltMvNative::invalidate_all() {
	for (auto &kv : rec_kinds) {
		kv.second.dirty = true;
	}
	for (auto &kv : lat_kinds) {
		kv.second.dirty = true;
	}
}

void BeltMvNative::invalidate_kind(bool is_lattice, int64_t item_id) {
	auto &kinds = is_lattice ? lat_kinds : rec_kinds;
	auto it = kinds.find(item_id);
	if (it != kinds.end()) {
		it->second.dirty = true;
	}
}

void BeltMvNative::set_max_band(int p_max_band) {
	if (p_max_band == max_band) {
		return;
	}
	max_band = p_max_band;
	invalidate_all();
}

void BeltMvNative::set_lat_variants(int64_t item_id, int variants) {
	auto it = lat_kinds.find(item_id);
	if (it != lat_kinds.end() && it->second.variants != variants) {
		it->second.variants = variants;
		it->second.dirty = true;
	}
}

void BeltMvNative::update_rec_pages(const Dictionary &p) {
	_update_pages(p, rec_pages, rec_kinds, rec_per_page);
}

void BeltMvNative::update_lat_pages(const Dictionary &p) {
	_update_pages(p, lat_pages, lat_kinds, lat_per_page);
}

void BeltMvNative::_update_pages(const Dictionary &p, std::vector<std::vector<float>> &pages,
		std::unordered_map<int64_t, KindState> &kinds, int &per_page) {
	Variant list_v = p.get("pages", Array());
	if (list_v.get_type() != Variant::ARRAY) {
		return;
	}
	Array list = list_v;
	if (list.is_empty()) {
		return;
	}
	bool all = (bool)p.get("all", false);
	if (all) {
		pages.clear();
	}
	std::vector<bool> touched;
	for (int64_t li = 0; li < list.size(); li++) {
		Variant e_v = list[li];
		if (e_v.get_type() != Variant::ARRAY) {
			continue;
		}
		Array e = e_v;
		if (e.size() < 2) {
			continue;
		}
		int idx = (int)(int64_t)e[0];
		Ref<Image> img = e[1];
		if (idx < 0 || img.is_null()) {
			continue;
		}
		int p_cap = (img->get_width() * img->get_height()) / 4;
		if (p_cap > 0) {
			per_page = p_cap;
		}
		PackedByteArray data = img->get_data();
		size_t nfloats = (size_t)data.size() / sizeof(float);
		if ((size_t)idx >= pages.size()) {
			pages.resize((size_t)idx + 1);
		}
		pages[idx].resize(nfloats);
		if (nfloats > 0) {
			std::memcpy(pages[idx].data(), data.ptr(), nfloats * sizeof(float));
		}
		if ((size_t)idx >= touched.size()) {
			touched.resize((size_t)idx + 1, false);
		}
		touched[idx] = true;
	}
	if (all || per_page <= 0) {
		for (auto &kv : kinds) {
			if (band_of_key(kv.second.item_id) <= max_band) {
				kv.second.dirty = true;
			}
		}
		return;
	}
	for (auto &kv : kinds) {
		KindState &ks = kv.second;
		if (band_of_key(ks.item_id) > max_band) {
			continue;
		}
		if (ks.base < 0 || ks.n <= 0) {
			ks.dirty = true;
			continue;
		}
		int p_lo = ks.base / per_page;
		int p_hi = (ks.base + ks.n - 1) / per_page;
		for (int pi = p_lo; pi <= p_hi; pi++) {
			if (pi >= 0 && (size_t)pi < touched.size() && touched[pi]) {
				ks.dirty = true;
				break;
			}
		}
	}
}

void BeltMvNative::update_paths(const Ref<Image> &img) {
	if (img.is_null()) {
		return;
	}
	paths_w = img->get_width();
	PackedByteArray data = img->get_data();
	size_t nfloats = (size_t)data.size() / sizeof(float);
	paths.resize(nfloats);
	if (nfloats > 0) {
		std::memcpy(paths.data(), data.ptr(), nfloats * sizeof(float));
	}
	for (auto &kv : rec_kinds) {
		kv.second.dirty = true;
	}
}

void BeltMvNative::update_mask(const Array &tiles, bool on) {
	bool changed = (on != mask_on);
	mask_on = on;
	if (!tiles.is_empty()) {
		if (mask_tiles.size() != 16) {
			mask_tiles.resize(16);
		}
		for (int64_t i = 0; i < tiles.size(); i++) {
			Variant e_v = tiles[i];
			if (e_v.get_type() != Variant::ARRAY) {
				continue;
			}
			Array e = e_v;
			if (e.size() < 2) {
				continue;
			}
			int ti = (int)(int64_t)e[0];
			Ref<Image> img = e[1];
			if (img.is_null() || ti < 0 || ti >= 16) {
				continue;
			}
			mask_w = img->get_width();
			mask_h = img->get_height();
			PackedByteArray data = img->get_data();
			mask_tiles[ti].resize((size_t)data.size());
			if (!data.is_empty()) {
				std::memcpy(mask_tiles[ti].data(), data.ptr(), (size_t)data.size());
			}
			changed = true;
		}
	}
	if (changed) {
		for (auto &kv : rec_kinds) {
			kv.second.dirty = true;
		}
	}
}

void BeltMvNative::set_mask_on(bool on) {
	if (on == mask_on) {
		return;
	}
	mask_on = on;
	for (auto &kv : rec_kinds) {
		kv.second.dirty = true;
	}
}

void BeltMvNative::set_rec_kind(int64_t item_id, int base, int n, int cap) {
	_set_kind(rec_kinds, rec_order, item_id, base, n, cap, false);
}

void BeltMvNative::set_lat_kind(int64_t item_id, int base, int n, int cap) {
	_set_kind(lat_kinds, lat_order, item_id, base, n, cap, true);
}

void BeltMvNative::_set_kind(std::unordered_map<int64_t, KindState> &kinds, std::vector<int64_t> &order,
		int64_t item_id, int base, int n, int cap, bool is_lat) {
	auto it = kinds.find(item_id);
	if (it == kinds.end()) {
		KindState fresh;
		fresh.item_id = item_id;
		fresh.is_lattice = is_lat;
		it = kinds.emplace(item_id, std::move(fresh)).first;
		order.push_back(item_id);
	}
	KindState &ks = it->second;
	int inst_cap = is_lat ? cap * 2 : cap;
	if (ks.base != base || ks.n != n || ks.cap != cap) {
		ks.base = base;
		ks.n = n;
		ks.cap = cap;
		ks.dirty = true;
	}
	if (ks.inst_cap != inst_cap && band_of_key(item_id) <= max_band) {
		int old_cap = ks.inst_cap;
		ks.inst_cap = inst_cap;
		ks.buf.resize((int64_t)inst_cap * STRIDE);
		if (inst_cap > old_cap) {
			float *dst = ks.buf.ptrw();
			for (int i = old_cap; i < inst_cap; i++) {
				hide_slot(dst + (int64_t)i * STRIDE);
			}
		}
		ks.dirty = true;
	} else {
		ks.inst_cap = inst_cap;
	}
}

PackedFloat32Array BeltMvNative::get_buf(bool is_lattice, int64_t item_id) const {
	const auto &kinds = is_lattice ? lat_kinds : rec_kinds;
	auto it = kinds.find(item_id);
	if (it == kinds.end()) {
		return PackedFloat32Array();
	}
	return it->second.buf;
}

int BeltMvNative::get_moving_count(bool is_lattice, int64_t item_id) const {
	const auto &kinds = is_lattice ? lat_kinds : rec_kinds;
	auto it = kinds.find(item_id);
	if (it == kinds.end()) {
		return 0;
	}
	return (int)it->second.moving.size();
}

Vector4 BeltMvNative::_path_at(int code, float g) const {
	int texels = (int)(paths.size() / 4);
	if (code < 0 || texels <= 0) {
		return Vector4(0.0f, 0.0f, 0.0f, 0.0f);
	}
	int first = code / 64;
	int pieces = code - first * 64 + 1;
	float f = clamp01(g) * (float)pieces;
	int i = std::min((int)f, pieces - 1);
	float frac = f - (float)i;
	int a = first + i;
	if (a < 0 || a >= texels) {
		return Vector4(0.0f, 0.0f, 0.0f, 0.0f);
	}
	int oa = a * 4;
	int ob = std::min(a + 1, texels - 1) * 4;
	return Vector4(
			paths[oa] + (paths[ob] - paths[oa]) * frac,
			paths[oa + 1] + (paths[ob + 1] - paths[oa + 1]) * frac,
			paths[oa + 2] + (paths[ob + 2] - paths[oa + 2]) * frac,
			paths[oa + 3] + (paths[ob + 3] - paths[oa + 3]) * frac);
}

bool BeltMvNative::_mask_hit(float at_x, float at_z) const {
	if (mask_w <= 0 || mask_h <= 0 || mask_tiles.size() != 16) {
		return false;
	}
	int side = mask_w * 4;
	int cx = (int)beltn::posmod((beltn::i64)std::floor(at_x * 4.0f), side);
	int side_z = mask_h * 4;  // (a tile that isn't square must not index past the 4x4)
	int cz = (int)beltn::posmod((beltn::i64)std::floor(at_z * 4.0f), side_z);
	if (cx < 0) cx = 0;
	if (cx >= side) cx = side - 1;
	if (cz < 0) cz = 0;
	if (cz >= side_z) cz = side_z - 1;
	int tx = cx / mask_w;
	int tz = cz / mask_h;
	const std::vector<uint8_t> &tile = mask_tiles[(size_t)(tz * 4 + tx)];
	if (tile.empty()) {
		return false;
	}
	int idx = (cz - tz * mask_h) * mask_w + (cx - tx * mask_w);
	return idx >= 0 && (size_t)idx < tile.size() && tile[(size_t)idx] > 127;
}

bool BeltMvNative::_sim_slot_outside(const KindState &ks, int s, float min_x, float max_x, float min_z, float max_z) const {
	int per = rec_per_page;
	if (per <= 0) {
		return false;
	}
	int r = ks.base + s;
	int p0 = r / per;
	if (r < 0 || (size_t)p0 >= rec_pages.size() || (size_t)((r - p0 * per) * 16 + 16) > rec_pages[(size_t)p0].size()) {
		return false;
	}
	const float *pg = rec_pages[(size_t)p0].data();
	int ro = (r - p0 * per) * 16;
	float dy = pg[ro + 13];
	if (dy > 0.5f) {
		int r_src = r + (int)beltn::roundi((double)pg[ro + 12]);
		int ps = r_src / per;
		if (r_src < 0 || (size_t)ps >= rec_pages.size() || (size_t)((r_src - ps * per) * 16 + 16) > rec_pages[(size_t)ps].size()) {
			return false;
		}
		pg = rec_pages[(size_t)ps].data();
		ro = (r_src - ps * per) * 16;
	}
	if (pg[ro + 11] >= 0.5f) {
		return false;  // curved path: evaluate normally
	}
	float ax = pg[ro + 0], az = pg[ro + 2];
	float bx = pg[ro + 4], bz = pg[ro + 6];
	float lo_x = std::min(ax, ax + bx), hi_x = std::max(ax, ax + bx);
	float lo_z = std::min(az, az + bz), hi_z = std::max(az, az + bz);
	return hi_x < min_x || lo_x > max_x || hi_z < min_z || lo_z > max_z;
}

bool BeltMvNative::_lat_slot_outside(const KindState &ks, int s, float min_x, float max_x, float min_z, float max_z) const {
	int per = lat_per_page;
	if (per <= 0) {
		return false;
	}
	int r = ks.base + s;
	int p0 = r / per;
	if (r < 0 || (size_t)p0 >= lat_pages.size() || (size_t)((r - p0 * per) * 16 + 16) > lat_pages[(size_t)p0].size()) {
		return false;
	}
	const float *pg = lat_pages[(size_t)p0].data();
	int ro = (r - p0 * per) * 16;
	if (pg[ro + 13] > 0.5f) {
		int r_src = r + (int)beltn::roundi((double)pg[ro + 12]);
		int ps = r_src / per;
		if (r_src < 0 || (size_t)ps >= lat_pages.size() || (size_t)((r_src - ps * per) * 16 + 16) > lat_pages[(size_t)ps].size()) {
			return false;
		}
		pg = lat_pages[(size_t)ps].data();
		ro = (r_src - ps * per) * 16;
	}
	if (pg[ro + 11] >= 0.5f) {
		return false;
	}
	float ax = pg[ro + 0], az = pg[ro + 2];
	float bx = pg[ro + 4], bz = pg[ro + 6];
	// Union of active [a, a + b] and pre-roll [a - b, a]
	float lo_x = std::min({ax - bx, ax, ax + bx});
	float hi_x = std::max({ax - bx, ax, ax + bx});
	float lo_z = std::min({az - bz, az, az + bz});
	float hi_z = std::max({az - bz, az, az + bz});
	return hi_x < min_x || lo_x > max_x || hi_z < min_z || lo_z > max_z;
}

int BeltMvNative::_eval_sim_slot(const KindState &ks, float *buf, int s, float clock) const {
	int bo = s * STRIDE;
	int per = rec_per_page;
	if (per <= 0) {
		hide_slot(buf + bo);
		return 0;
	}
	int r = ks.base + s;
	int p0 = r / per;
	if (r < 0 || (size_t)p0 >= rec_pages.size() || (size_t)((r - p0 * per) * 16 + 16) > rec_pages[(size_t)p0].size()) {
		hide_slot(buf + bo);
		return 0;
	}
	const float *pg0 = rec_pages[(size_t)p0].data();
	int ro0 = (r - p0 * per) * 16;
	float dx = pg0[ro0 + 12];
	float dy = pg0[ro0 + 13];
	float dz = pg0[ro0 + 14];
	float dw = pg0[ro0 + 15];
	bool is_copy = dy > 0.5f;
	float own_cx = 1.0f;
	float own_cy = 0.0f;
	const float *pg = pg0;
	int ro = ro0;
	float ew = dw;
	if (is_copy) {
		own_cx = pg0[ro0 + 8];
		own_cy = pg0[ro0 + 9];
		int r_src = r + (int)beltn::roundi((double)dx);
		int ps = r_src / per;
		if (r_src < 0 || (size_t)ps >= rec_pages.size() || (size_t)((r_src - ps * per) * 16 + 16) > rec_pages[(size_t)ps].size()) {
			hide_slot(buf + bo);
			return 0;
		}
		pg = rec_pages[(size_t)ps].data();
		ro = (r_src - ps * per) * 16;
		ew = pg[ro + 15];
	}
	float cw = pg[ro + 11];
	if (cw < -0.5f) {
		hide_slot(buf + bo);
		return 0;
	}
	float ax = pg[ro + 0];
	float ay = pg[ro + 1];
	float az = pg[ro + 2];
	float aw = pg[ro + 3];
	float bx = pg[ro + 4];
	float by = pg[ro + 5];
	float bz = pg[ro + 6];
	float bw = pg[ro + 7];
	float base_cx = pg[ro + 8];
	float base_cy = pg[ro + 9];
	float cz = pg[ro + 10];
	float cx = base_cx;
	float cy = base_cy;
	if (is_copy) {
		cz += dz * dy;
		cx = own_cx;
		cy = own_cy;
	}
	uint32_t lh = beltn::lattice_hash(beltn::roundi((double)base_cy * 100000.0), beltn::roundi(((double)base_cx + 2.0) * 100000.0));
	float jit = (float)((lh >> 16) & 65535u) / 32767.5f - 1.0f;
	bool still_moving = (bw > aw && bw > clock) || (ew > 0.0f && ew > clock) || (ew < 0.0f && -ew > clock);
	bool handoff_hide = (ew > 0.0f && clock >= ew) || (ew < 0.0f && clock < -ew);
	float g = bw > aw ? clamp01((clock - aw) / (bw - aw)) : 1.0f;
	float at_x = ax;
	float at_y = ay;
	float at_z = az;
	bool vis = !handoff_hide;
	if (cw < 0.5f) {
		at_x += bx * g;
		at_y += by * g;
		at_z += bz * g;
	} else {
		Vector4 po = _path_at((int)beltn::roundi((double)cw) - 1, g);
		if (po.w < 0.5f) {
			vis = false;
		} else {
			at_x += po.x;
			at_y += po.y;
			at_z += po.z;
		}
	}
	if (vis && mask_on && _mask_hit(at_x, at_z)) {
		vis = false;
	}
	write_slot(buf + bo, cx, cy, at_x, at_y + cz, at_z, is_copy ? 128.0f : 0.0f, jit, 0.0f, vis ? SHOW_CLOCK : HIDE_CLOCK);
	return still_moving ? 1 : 0;
}

int BeltMvNative::_eval_lat_slot(const KindState &ks, float *buf, int s, float clock) const {
	int bo0 = s * 2 * STRIDE;
	int bo1 = bo0 + STRIDE;
	int per = lat_per_page;
	if (per <= 0) {
		hide_slot(buf + bo0);
		hide_slot(buf + bo1);
		return 0;
	}
	int r = ks.base + s;
	int p0 = r / per;
	if (r < 0 || (size_t)p0 >= lat_pages.size() || (size_t)((r - p0 * per) * 16 + 16) > lat_pages[(size_t)p0].size()) {
		hide_slot(buf + bo0);
		hide_slot(buf + bo1);
		return 0;
	}
	const float *pg0 = lat_pages[(size_t)p0].data();
	int ro0 = (r - p0 * per) * 16;
	float dx = pg0[ro0 + 12];
	float dy = pg0[ro0 + 13];
	float dz = pg0[ro0 + 14];
	float dw = pg0[ro0 + 15];
	bool is_copy = dy > 0.5f;
	float own_cx = 1.0f;
	float own_cy = 0.0f;
	const float *pg = pg0;
	int ro = ro0;
	float ex = dx;
	float ey = dy;
	float ez = dz;
	float ew = dw;
	if (is_copy) {
		own_cx = pg0[ro0 + 8];
		own_cy = pg0[ro0 + 9];
		int r_src = r + (int)beltn::roundi((double)dx);
		int ps = r_src / per;
		if (r_src < 0 || (size_t)ps >= lat_pages.size() || (size_t)((r_src - ps * per) * 16 + 16) > lat_pages[(size_t)ps].size()) {
			hide_slot(buf + bo0);
			hide_slot(buf + bo1);
			return 0;
		}
		pg = lat_pages[(size_t)ps].data();
		ro = (r_src - ps * per) * 16;
		ex = pg[ro + 12];
		ey = pg[ro + 13];
		ez = pg[ro + 14];
		ew = pg[ro + 15];
	}
	float cw = pg[ro + 11];
	if (cw < -0.5f) {
		hide_slot(buf + bo0);
		hide_slot(buf + bo1);
		return 0;
	}
	float ax = pg[ro + 0];
	float ay = pg[ro + 1];
	float az = pg[ro + 2];
	float aw = pg[ro + 3];
	float bx = pg[ro + 4];
	float by = pg[ro + 5];
	float bz = pg[ro + 6];
	float bw = pg[ro + 7];
	float base_cx = pg[ro + 8];
	float base_cy = pg[ro + 9];
	float cz = pg[ro + 10];
	if (is_copy) {
		cz += dz * dy;
	}
	bool lattice = ey < 0.5f && ez > 0.5f;
	int variants = ks.variants;
	float copy_flag = is_copy ? 128.0f : 0.0f;
	int pile_k = is_copy ? (int)beltn::roundi((double)dy) : 0;

	if (!lattice || ew <= 0.0f) {
		float g = bw > aw ? clamp01((clock - aw) / (bw - aw)) : 1.0f;
		float at_x = ax + (!lattice ? bx * g : 0.0f);
		float at_y = ay + (!lattice ? by * g : 0.0f) + cz;
		float at_z = az + (!lattice ? bz * g : 0.0f);
		float cx = is_copy ? own_cx : base_cx;
		float cy = is_copy ? own_cy : base_cy;
		int ivar = 0;
		float jit = 0.0f;
		if (lattice && ez > 1.5f) {
			beltn::i64 who = beltn::roundi((double)base_cx);
			beltn::i64 run = beltn::roundi((double)base_cy);
			uint32_t lh = beltn::lattice_hash(who, run);
			float turn = ((float)(lh % 2001u) / 1000.0f - 1.0f) * MAX_YAW + PILE_TURN * (float)pile_k;
			cx = std::cosf(turn);
			cy = std::sinf(turn);
			if (variants > 1) {
				ivar = (int)((lh >> 8) % (uint32_t)variants);
			}
			jit = (float)((lh >> 16) & 65535u) / 32767.5f - 1.0f;
		} else {
			uint32_t lh2 = beltn::lattice_hash(beltn::roundi((double)base_cy * 100000.0), beltn::roundi(((double)base_cx + 2.0) * 100000.0));
			jit = (float)((lh2 >> 16) & 65535u) / 32767.5f - 1.0f;
		}
		bool vis = true;
		if (lattice && ex > 0.0f && clock >= ex) {
			vis = false;
		}
		if (vis && !lattice && ((ew > 0.0f && clock >= ew) || (ew < 0.0f && clock < -ew))) {
			vis = false;
		}
		write_slot(buf + bo0, cx, cy, at_x, at_y, at_z, (float)ivar + copy_flag, jit, 0.0f, vis ? SHOW_CLOCK : HIDE_CLOCK);
		hide_slot(buf + bo1);
		bool need_mv = (!lattice && ((bw > aw && bw > clock) || (ew > 0.0f && ew > clock) || (ew < 0.0f && -ew > clock)))
				|| (lattice && ex > 0.0f && ex > clock);
		return need_mv ? 1 : 0;
	}

	bool has_hi = bw > aw && by > 0.0f;
	float hi = has_hi ? (bw + by * ew) : 1.0e30f;
	float lclock = bw > aw ? std::max(bw, std::min(clock, hi)) : clock;
	float hclock = bw > aw ? std::max(bw, std::min(ex, hi)) : ex;
	float q = (lclock - aw) / ew;
	int slid = (int)std::floor(q);
	float g = q - (float)slid;
	int act_p = slid & 1;
	int pre_p = 1 - act_p;
	int act_bo = bo0 + act_p * STRIDE;
	int pre_bo = bo0 + pre_p * STRIDE;
	bool after_stop = has_hi && clock >= hi;

	// Active instance at (slid, g)
	float at_x = ax + bx * g;
	float at_y = ay + cz;
	float at_z = az + bz * g;
	float cx = is_copy ? own_cx : base_cx;
	float cy = is_copy ? own_cy : base_cy;
	int ivar = 0;
	float jit = 0.0f;
	if (ez > 1.5f) {
		beltn::i64 who = beltn::roundi((double)base_cx) + slid;
		beltn::i64 run = beltn::roundi((double)base_cy);
		uint32_t lh = beltn::lattice_hash(who, run);
		float turn = ((float)(lh % 2001u) / 1000.0f - 1.0f) * MAX_YAW + PILE_TURN * (float)pile_k;
		cx = std::cosf(turn);
		cy = std::sinf(turn);
		if (variants > 1) {
			ivar = (int)((lh >> 8) % (uint32_t)variants);
		}
		jit = (float)((lh >> 16) & 65535u) / 32767.5f - 1.0f;
	} else {
		uint32_t lh2 = beltn::lattice_hash(beltn::roundi((double)base_cy * 100000.0), beltn::roundi(((double)base_cx + 2.0) * 100000.0));
		jit = (float)((lh2 >> 16) & 65535u) / 32767.5f - 1.0f;
	}

	bool vis_act = true;
	if (ex > 0.0f && clock >= ex && (int)std::floor((lclock - aw) / ew) == (int)std::floor((hclock - aw) / ew)) {
		vis_act = false;
	}
	if (vis_act && ey < -0.5f) {
		float hy = -ey;
		if ((hy < 2.5f && g >= hy - 1.0f) || (hy >= 2.5f && g < hy - 3.0f)) {
			vis_act = false;
		}
	}
	write_slot(buf + act_bo, cx, cy, at_x, at_y, at_z, (float)ivar + copy_flag, jit, 0.0f, vis_act ? SHOW_CLOCK : HIDE_CLOCK);

	if (after_stop) {
		hide_slot(buf + pre_bo);
		return (ex > 0.0f && ex > clock) ? 1 : 0;
	}

	int next_slid = slid + 1;
	float at_pre_x = ax + bx * (g - 1.0f);
	float at_pre_y = ay + cz;
	float at_pre_z = az + bz * (g - 1.0f);
	float cx_p = cx;
	float cy_p = cy;
	int ivar_p = 0;
	float jit_p = jit;
	if (ez > 1.5f) {
		beltn::i64 who_p = beltn::roundi((double)base_cx) + next_slid;
		beltn::i64 run_p = beltn::roundi((double)base_cy);
		uint32_t lh_p = beltn::lattice_hash(who_p, run_p);
		float turn_p = ((float)(lh_p % 2001u) / 1000.0f - 1.0f) * MAX_YAW + PILE_TURN * (float)pile_k;
		cx_p = std::cosf(turn_p);
		cy_p = std::sinf(turn_p);
		if (variants > 1) {
			ivar_p = (int)((lh_p >> 8) % (uint32_t)variants);
		}
		jit_p = (float)((lh_p >> 16) & 65535u) / 32767.5f - 1.0f;
	}
	write_slot(buf + pre_bo, cx_p, cy_p, at_pre_x, at_pre_y, at_pre_z, (float)ivar_p + copy_flag, jit_p, 0.0f, HIDE_CLOCK);
	return 1;
}

Array BeltMvNative::step(float clock, const Vector4 &vrect) {
	if (clock < last_clock) {
		invalidate_all();
	}
	last_clock = clock;

	float min_x = vrect.x - VRECT_MARGIN;
	float min_z = vrect.y - VRECT_MARGIN;
	float max_x = vrect.z + VRECT_MARGIN;
	float max_z = vrect.w + VRECT_MARGIN;

	Array out;
	auto process_group = [&](std::unordered_map<int64_t, KindState> &kinds, const std::vector<int64_t> &order) {
		for (int64_t id : order) {
			KindState &ks = kinds.at(id);
			if (ks.base < 0) {
				continue;
			}
			if (band_of_key(id) > max_band) {
				if (ks.has_written && !ks.on_records) {
					ks.on_records = true;
					ks.dirty = true;
					ks.last_visible = -1;
					push_update(out, ks.item_id, ks.is_lattice, PackedFloat32Array(), 0, 0, true);
				}
				continue;
			}
			// Never more slots than the buffer holds (a lattice slot is two instances): a caller
			// passing n past cap must not write or read past the end (the GDScript twin does the same).
			int target_vis = std::min(ks.is_lattice ? ks.n * 2 : ks.n, ks.inst_cap);
			int nw = std::min(ks.n, ks.is_lattice ? ks.inst_cap / 2 : ks.inst_cap);
			bool need_vis_sync = (ks.last_visible != target_vis);
			if (!ks.dirty && ks.moving.empty() && !need_vis_sync) {
				continue;
			}
			if ((int64_t)ks.buf.size() != (int64_t)ks.inst_cap * STRIDE) {
				int old_cap = (int)(ks.buf.size() / STRIDE);
				ks.buf.resize((int64_t)ks.inst_cap * STRIDE);
				if (ks.inst_cap > old_cap) {
					float *dst = ks.buf.ptrw();
					for (int i = old_cap; i < ks.inst_cap; i++) {
						hide_slot(dst + (int64_t)i * STRIDE);
					}
				}
				ks.dirty = true;
			}
			if (ks.n <= 0) {
				ks.moving.clear();
				ks.dirty = false;
				if (ks.last_visible != 0 || !ks.on_records) {
					ks.last_visible = 0;
					ks.on_records = true;
					push_update(out, ks.item_id, ks.is_lattice, ks.buf, 0, ks.inst_cap, false);
				}
				continue;
			}

			bool emit = false;
			bool restore_to_rec = false;
			if (ks.dirty) {
				ks.moving.clear();
				float *dst = ks.buf.ptrw();
				if (ks.is_lattice) {
					for (int s = 0; s < nw; s++) {
						if (_eval_lat_slot(ks, dst, s, clock) != 0) {
							ks.moving.push_back(s);
						}
					}
				} else {
					for (int s = 0; s < nw; s++) {
						if (_eval_sim_slot(ks, dst, s, clock) != 0) {
							ks.moving.push_back(s);
						}
					}
				}
				ks.dirty = false;
				ks.has_written = true;
				if (ks.moving.empty() && ks.n > 0) {
					restore_to_rec = true;
					emit = !ks.on_records || ks.last_visible != ks.n;
					ks.on_records = true;
					ks.last_visible = ks.n;
				} else {
					ks.on_records = false;
					ks.last_visible = target_vis;
					emit = true;
				}
			} else {
				float *dst = nullptr;
				std::vector<int> keep;
				keep.reserve(ks.moving.size());
				bool shrunk = false;
				bool wrote_any = false;
				if (ks.is_lattice) {
					for (int s : ks.moving) {
						if (s < 0 || s >= nw) {
							shrunk = true;
							continue;
						}
						if (_lat_slot_outside(ks, s, min_x, max_x, min_z, max_z)) {
							keep.push_back(s);
							continue;
						}
						if (dst == nullptr) {
							dst = ks.buf.ptrw();
						}
						wrote_any = true;
						if (_eval_lat_slot(ks, dst, s, clock) != 0) {
							keep.push_back(s);
						} else {
							shrunk = true;
						}
					}
				} else {
					for (int s : ks.moving) {
						if (s < 0 || s >= nw) {
							shrunk = true;
							continue;
						}
						if (_sim_slot_outside(ks, s, min_x, max_x, min_z, max_z)) {
							keep.push_back(s);
							continue;
						}
						if (dst == nullptr) {
							dst = ks.buf.ptrw();
						}
						wrote_any = true;
						if (_eval_sim_slot(ks, dst, s, clock) != 0) {
							keep.push_back(s);
						} else {
							shrunk = true;
						}
					}
				}
				if (shrunk) {
					ks.moving.swap(keep);
				}
				if (ks.moving.empty() && ks.n > 0) {
					restore_to_rec = true;
					emit = !ks.on_records || ks.last_visible != ks.n;
					ks.on_records = true;
					ks.last_visible = ks.n;
				} else if (wrote_any || ks.on_records || need_vis_sync) {
					ks.on_records = false;
					ks.last_visible = target_vis;
					emit = true;
				}
			}

			if (emit) {
				if (restore_to_rec) {
					push_update(out, ks.item_id, ks.is_lattice, PackedFloat32Array(), 0, 0, true);
				} else {
					push_update(out, ks.item_id, ks.is_lattice, ks.buf, target_vis, ks.inst_cap, false);
				}
			}
		}
	};

	process_group(rec_kinds, rec_order);
	process_group(lat_kinds, lat_order);
	return out;
}

void BeltMvNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("reset"), &BeltMvNative::reset);
	ClassDB::bind_method(D_METHOD("invalidate_all"), &BeltMvNative::invalidate_all);
	ClassDB::bind_method(D_METHOD("invalidate_kind", "is_lattice", "item_id"), &BeltMvNative::invalidate_kind);
	ClassDB::bind_method(D_METHOD("set_max_band", "max_band"), &BeltMvNative::set_max_band);
	ClassDB::bind_method(D_METHOD("set_lat_variants", "item_id", "variants"), &BeltMvNative::set_lat_variants);
	ClassDB::bind_method(D_METHOD("update_rec_pages", "pages"), &BeltMvNative::update_rec_pages);
	ClassDB::bind_method(D_METHOD("update_lat_pages", "pages"), &BeltMvNative::update_lat_pages);
	ClassDB::bind_method(D_METHOD("update_paths", "img"), &BeltMvNative::update_paths);
	ClassDB::bind_method(D_METHOD("update_mask", "tiles", "on"), &BeltMvNative::update_mask);
	ClassDB::bind_method(D_METHOD("set_mask_on", "on"), &BeltMvNative::set_mask_on);
	ClassDB::bind_method(D_METHOD("set_rec_kind", "item_id", "base", "n", "cap"), &BeltMvNative::set_rec_kind);
	ClassDB::bind_method(D_METHOD("set_lat_kind", "item_id", "base", "n", "cap"), &BeltMvNative::set_lat_kind);
	ClassDB::bind_method(D_METHOD("get_buf", "is_lattice", "item_id"), &BeltMvNative::get_buf);
	ClassDB::bind_method(D_METHOD("get_moving_count", "is_lattice", "item_id"), &BeltMvNative::get_moving_count);
	ClassDB::bind_method(D_METHOD("step", "clock", "vrect"), &BeltMvNative::step);
}
