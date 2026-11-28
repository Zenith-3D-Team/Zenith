#include "belt_mv_native.h"
#include "belt_items_native.h"
#include "belt_native_common.h"

#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/worker_thread_pool.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
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

// Builds the slot's 16 floats locally and copies them only when they differ from what the buffer
// holds; returns whether the slot changed (BeltMv's change flag, `--belt-mv-change-flag`).
inline bool put_slot(float *dst, const float (&v)[BeltMvNative::STRIDE]) {
	if (std::memcmp(dst, v, sizeof(v)) == 0) {
		return false;
	}
	std::memcpy(dst, v, sizeof(v));
	return true;
}

inline bool write_slot(float *dst, float cx, float cy, float px, float py, float pz,
		float c0, float c1, float c2, float c3) {
	const float v[BeltMvNative::STRIDE] = {
		cx, 0.0f, cy, px,
		0.0f, 1.0f, 0.0f, py,
		-cy, 0.0f, cx, pz,
		c0, c1, c2, c3,
	};
	return put_slot(dst, v);
}

inline bool hide_slot(float *dst) {
	static const float v[BeltMvNative::STRIDE] = {
		1.0f, 0.0f, 0.0f, 0.0f,
		0.0f, 1.0f, 0.0f, 0.0f,
		0.0f, 0.0f, 1.0f, 0.0f,
		0.0f, 0.0f, 0.0f, BeltMvNative::HIDE_CLOCK,
	};
	return put_slot(dst, v);
}

inline float clamp01(float v) {
	return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
}

inline void push_update(Array &out, int64_t item_id, bool is_lattice,
		const PackedFloat32Array &buf, int vis, int inst_cap, bool restore_to_records, bool changed) {
	Array entry;
	entry.resize(7);
	entry[0] = item_id;
	entry[1] = is_lattice;
	entry[2] = buf;
	entry[3] = vis;
	entry[4] = inst_cap;
	entry[5] = restore_to_records;
	entry[6] = changed;
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
	rec_touched.clear();
	lat_touched.clear();
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
	_update_pages(p, rec_pages, rec_kinds, rec_per_page, rec_touched);
}

void BeltMvNative::update_lat_pages(const Dictionary &p) {
	_update_pages(p, lat_pages, lat_kinds, lat_per_page, lat_touched);
}

void BeltMvNative::_update_pages(const Dictionary &p, std::vector<Page> &pages,
		std::unordered_map<int64_t, KindState> &kinds, int &per_page, std::vector<uint8_t> &touched_acc) {
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
		touched_acc.clear();
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
		if ((size_t)idx >= pages.size()) {
			pages.resize((size_t)idx + 1);
		}
		// The Image's bytes are kept as they are (copy-on-write: a later write to that Image copies
		// on its side), so a page costs no copy here; steps only read them.
		Page &pg = pages[idx];
		pg.bytes = img->get_data();
		pg.n = (size_t)pg.bytes.size() / sizeof(float);
		pg.f = pg.n > 0 ? reinterpret_cast<const float *>(pg.bytes.ptr()) : nullptr;
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
	if (page_dirty_on) {
		if (touched_acc.size() < touched.size()) {
			touched_acc.resize(touched.size(), 0);
		}
		for (size_t i = 0; i < touched.size(); i++) {
			if (touched[i]) {
				touched_acc[i] = 1;
			}
		}
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
				// (A pile's copy points at its item's record in the same kind, so the kind's own pages
				// cover every record its slots read.)
				if (page_dirty_on) {
					ks.page_dirty = true;
				} else {
					ks.dirty = true;
				}
				break;
			}
		}
	}
}

// (--belt-mv-page-dirty) Whether slot s reads a record on a page touched since the last step: its own
// record, or for a pile's copy the item's record it points at.
bool BeltMvNative::_touched_slot(const KindState &ks, int s) const {
	const std::vector<Page> &pages = ks.is_lattice ? lat_pages : rec_pages;
	const std::vector<uint8_t> &touched = ks.is_lattice ? lat_touched : rec_touched;
	const int per = ks.is_lattice ? lat_per_page : rec_per_page;
	if (per <= 0) {
		return true;
	}
	int r = ks.base + s;
	if (r < 0) {
		return true;
	}
	int p0 = r / per;
	if ((size_t)p0 >= pages.size()) {
		// (No page there: the slot hides, as a full pass would make it.)
		return true;
	}
	if ((size_t)p0 < touched.size() && touched[(size_t)p0]) {
		return true;
	}
	const Page &pg = pages[(size_t)p0];
	int ro = (r - p0 * per) * 16;
	if ((size_t)ro + 16 > pg.size()) {
		return true;
	}
	if (pg.data()[ro + 13] > 0.5f) {
		int r_src = r + (int)beltn::roundi((double)pg.data()[ro + 12]);
		if (r_src < 0) {
			return true;
		}
		int ps = r_src / per;
		return (size_t)ps < touched.size() && touched[(size_t)ps] != 0;
	}
	return false;
}

// (--belt-mv-tight-cap) The instances a kind's buffer holds for `need` drawn: a quarter more, rounded up
// to TIGHT_STEP, never past the records' capacity.
int BeltMvNative::_tight_size(const KindState &ks, int need) const {
	int full = ks.is_lattice ? ks.cap * 2 : ks.cap;
	if (full <= 0) {
		return 0;
	}
	if (need < 0) {
		need = 0;
	}
	int64_t want = (int64_t)need + need / 4;
	want = ((want + TIGHT_STEP - 1) / TIGHT_STEP) * TIGHT_STEP;
	if (want < TIGHT_STEP) {
		want = TIGHT_STEP;
	}
	return (int)std::min<int64_t>(want, full);
}

void BeltMvNative::_fit_buffer(KindState &ks, int size) {
	int old_cap = (int)(ks.buf.size() / STRIDE);
	ks.inst_cap = size;
	if (old_cap == size) {
		return;
	}
	ks.buf.resize((int64_t)size * STRIDE);
	if (size > old_cap) {
		float *dst = ks.buf.ptrw();
		for (int i = old_cap; i < size; i++) {
			hide_slot(dst + (int64_t)i * STRIDE);
		}
	}
	ks.dirty = true;
	ks.changed = true;
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
	if (tight_on) {
		// Grown at once to hold every item (a quarter more), kept while it fits (shrunk in step).
		int need = std::min(is_lat ? n * 2 : n, inst_cap);
		if (ks.inst_cap < need || ks.inst_cap > inst_cap || ks.inst_cap <= 0) {
			inst_cap = _tight_size(ks, need);
			ks.low_steps = 0;
		} else {
			inst_cap = ks.inst_cap;
		}
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
		ks.changed = true;
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
		return hide_slot(buf + bo) ? 2 : 0;
	}
	int r = ks.base + s;
	int p0 = r / per;
	if (r < 0 || (size_t)p0 >= rec_pages.size() || (size_t)((r - p0 * per) * 16 + 16) > rec_pages[(size_t)p0].size()) {
		return hide_slot(buf + bo) ? 2 : 0;
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
			return hide_slot(buf + bo) ? 2 : 0;
		}
		pg = rec_pages[(size_t)ps].data();
		ro = (r_src - ps * per) * 16;
		ew = pg[ro + 15];
	}
	float cw = pg[ro + 11];
	if (cw < -0.5f) {
		return hide_slot(buf + bo) ? 2 : 0;
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
	bool ch = write_slot(buf + bo, cx, cy, at_x, at_y + cz, at_z, is_copy ? 128.0f : 0.0f, jit, 0.0f, vis ? SHOW_CLOCK : HIDE_CLOCK);
	return (still_moving ? 1 : 0) | (ch ? 2 : 0);
}

int BeltMvNative::_eval_lat_slot(const KindState &ks, float *buf, int s, float clock) const {
	int bo0 = s * 2 * STRIDE;
	int bo1 = bo0 + STRIDE;
	int per = lat_per_page;
	if (per <= 0) {
		bool ch = hide_slot(buf + bo0);
		ch = hide_slot(buf + bo1) || ch;
		return ch ? 2 : 0;
	}
	int r = ks.base + s;
	int p0 = r / per;
	if (r < 0 || (size_t)p0 >= lat_pages.size() || (size_t)((r - p0 * per) * 16 + 16) > lat_pages[(size_t)p0].size()) {
		bool ch = hide_slot(buf + bo0);
		ch = hide_slot(buf + bo1) || ch;
		return ch ? 2 : 0;
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
			bool ch = hide_slot(buf + bo0);
			ch = hide_slot(buf + bo1) || ch;
			return ch ? 2 : 0;
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
		bool ch = hide_slot(buf + bo0);
		ch = hide_slot(buf + bo1) || ch;
		return ch ? 2 : 0;
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
			cx = std::cos(turn);
			cy = std::sin(turn);
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
		bool ch = write_slot(buf + bo0, cx, cy, at_x, at_y, at_z, (float)ivar + copy_flag, jit, 0.0f, vis ? SHOW_CLOCK : HIDE_CLOCK);
		ch = hide_slot(buf + bo1) || ch;
		bool need_mv = (!lattice && ((bw > aw && bw > clock) || (ew > 0.0f && ew > clock) || (ew < 0.0f && -ew > clock)))
				|| (lattice && ex > 0.0f && ex > clock);
		return (need_mv ? 1 : 0) | (ch ? 2 : 0);
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
		cx = std::cos(turn);
		cy = std::sin(turn);
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
	bool ch = write_slot(buf + act_bo, cx, cy, at_x, at_y, at_z, (float)ivar + copy_flag, jit, 0.0f, vis_act ? SHOW_CLOCK : HIDE_CLOCK);

	if (after_stop) {
		ch = hide_slot(buf + pre_bo) || ch;
		return ((ex > 0.0f && ex > clock) ? 1 : 0) | (ch ? 2 : 0);
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
		cx_p = std::cos(turn_p);
		cy_p = std::sin(turn_p);
		if (variants > 1) {
			ivar_p = (int)((lh_p >> 8) % (uint32_t)variants);
		}
		jit_p = (float)((lh_p >> 16) & 65535u) / 32767.5f - 1.0f;
	}
	ch = write_slot(buf + pre_bo, cx_p, cy_p, at_pre_x, at_pre_y, at_pre_z, (float)ivar_p + copy_flag, jit_p, 0.0f, HIDE_CLOCK) || ch;
	return 1 | (ch ? 2 : 0);
}

// One kind's evaluation (phase 2 of step): writes only this kind's buffer, `moving` list and change
// flag; reads the shared pages, paths and mask, which nothing writes while a step runs. Safe to run
// for different kinds at once on the engine's worker pool (`--belt-mv-threads`).
void BeltMvNative::_eval_job(StepJob &j, float clock, float min_x, float max_x, float min_z, float max_z) const {
	KindState &ks = *j.ks;
	const int nw = j.nw;
	if (ks.dirty) {
		ks.moving.clear();
		float *dst = j.dst;
		if (ks.is_lattice) {
			for (int s = 0; s < nw; s++) {
				int ev = _eval_lat_slot(ks, dst, s, clock);
				if (ev & 1) {
					ks.moving.push_back(s);
				}
				if (ev & 2) {
					ks.changed = true;
				}
			}
		} else {
			for (int s = 0; s < nw; s++) {
				int ev = _eval_sim_slot(ks, dst, s, clock);
				if (ev & 1) {
					ks.moving.push_back(s);
				}
				if (ev & 2) {
					ks.changed = true;
				}
			}
		}
		ks.dirty = false;
		ks.page_dirty = false;
		ks.has_written = true;
		if (ks.moving.empty() && ks.n > 0) {
			j.emit = (!ks.on_records || ks.last_visible != ks.n) ? EMIT_RESTORE : EMIT_NONE;
			ks.on_records = true;
			ks.last_visible = ks.n;
		} else {
			ks.on_records = false;
			ks.last_visible = j.target_vis;
			j.emit = EMIT_PUT;
		}
		return;
	}
	if (j.page_part) {
		// (--belt-mv-page-dirty) As a dirty kind's pass, but only for the slots whose records a page
		// update touched (the rest read what they read when last evaluated); moving slots as every step.
		// `moving` stays in slot order.
		ks.page_dirty = false;
		float *dst = ks.buf.ptrw();
		std::vector<int> keep;
		keep.reserve(ks.moving.size() + 64);
		const std::vector<int> &mv = ks.moving;
		size_t mi = 0;
		int evaluated = 0;
		for (int s = 0; s < nw; s++) {
			while (mi < mv.size() && mv[mi] < s) {
				mi++;
			}
			bool was_moving = mi < mv.size() && mv[mi] == s;
			bool touched = _touched_slot(ks, s);
			if (!touched && !was_moving) {
				continue;
			}
			if (!touched && (ks.is_lattice ? _lat_slot_outside(ks, s, min_x, max_x, min_z, max_z)
										   : _sim_slot_outside(ks, s, min_x, max_x, min_z, max_z))) {
				keep.push_back(s);
				continue;
			}
			evaluated++;
			int ev = ks.is_lattice ? _eval_lat_slot(ks, dst, s, clock) : _eval_sim_slot(ks, dst, s, clock);
			if (ev & 2) {
				ks.changed = true;
			}
			if (ev & 1) {
				keep.push_back(s);
			}
		}
		ks.moving.swap(keep);
		j.evaluated = evaluated;
		ks.has_written = true;
		if (ks.moving.empty() && ks.n > 0) {
			j.emit = (!ks.on_records || ks.last_visible != ks.n) ? EMIT_RESTORE : EMIT_NONE;
			ks.on_records = true;
			ks.last_visible = ks.n;
		} else {
			ks.on_records = false;
			ks.last_visible = j.target_vis;
			j.emit = EMIT_PUT;
		}
		return;
	}
	float *dst = nullptr;
	std::vector<int> keep;
	keep.reserve(ks.moving.size());
	bool shrunk = false;
	bool wrote_any = false;
	for (int s : ks.moving) {
		if (s < 0 || s >= nw) {
			shrunk = true;
			continue;
		}
		bool outside = ks.is_lattice ? _lat_slot_outside(ks, s, min_x, max_x, min_z, max_z)
									 : _sim_slot_outside(ks, s, min_x, max_x, min_z, max_z);
		if (outside) {
			keep.push_back(s);
			continue;
		}
		if (dst == nullptr) {
			// Lazy, as before: a kind whose moving slots are all off-screen keeps its shared buffer
			// (no copy-on-write). The task owns this kind's array while the step runs.
			dst = ks.buf.ptrw();
		}
		wrote_any = true;
		int ev = ks.is_lattice ? _eval_lat_slot(ks, dst, s, clock) : _eval_sim_slot(ks, dst, s, clock);
		if (ev & 2) {
			ks.changed = true;
		}
		if (ev & 1) {
			keep.push_back(s);
		} else {
			shrunk = true;
		}
	}
	if (shrunk) {
		ks.moving.swap(keep);
	}
	if (ks.moving.empty() && ks.n > 0) {
		j.emit = (!ks.on_records || ks.last_visible != ks.n) ? EMIT_RESTORE : EMIT_NONE;
		ks.on_records = true;
		ks.last_visible = ks.n;
	} else if (wrote_any || ks.on_records || j.need_vis_sync) {
		ks.on_records = false;
		ks.last_visible = j.target_vis;
		j.emit = EMIT_PUT;
	}
}

namespace {

struct StepGroupData {
	const BeltMvNative *self;
	std::vector<BeltMvNative::StepJob> *jobs;
	const std::vector<int> *due;
	float clock, min_x, max_x, min_z, max_z;
};

void step_group_task(void *p_userdata, uint32_t p_index) {
	StepGroupData *d = static_cast<StepGroupData *>(p_userdata);
	BeltMvNative::StepJob &j = (*d->jobs)[(size_t)(*d->due)[p_index]];
	d->self->_eval_job(j, d->clock, d->min_x, d->max_x, d->min_z, d->max_z);
}

} // namespace

Array BeltMvNative::step(float clock, const Vector4 &vrect) {
	if (clock < last_clock) {
		invalidate_all();
	}
	last_clock = clock;

	float min_x = vrect.x - VRECT_MARGIN;
	float min_z = vrect.y - VRECT_MARGIN;
	float max_x = vrect.z + VRECT_MARGIN;
	float max_z = vrect.w + VRECT_MARGIN;

	// Phase 1 (this thread): per kind, in today's order, decide the work, resize, take the buffer.
	std::vector<StepJob> &jobs = step_jobs;
	jobs.clear();
	std::vector<int> &due = step_due;
	due.clear();
	int64_t due_slots = 0;
	auto plan_group = [&](std::unordered_map<int64_t, KindState> &kinds, const std::vector<int64_t> &order) {
		for (int64_t id : order) {
			KindState &ks = kinds.at(id);
			if (ks.base < 0) {
				continue;
			}
			StepJob j;
			j.ks = &ks;
			if (band_of_key(id) > max_band) {
				if (ks.has_written && !ks.on_records) {
					ks.on_records = true;
					ks.dirty = true;
					ks.last_visible = -1;
					j.emit = EMIT_RESTORE;
					jobs.push_back(j);
				}
				continue;
			}
			// Never more slots than the buffer holds (a lattice slot is two instances): a caller
			// passing n past cap must not write or read past the end (the GDScript twin does the same).
			j.target_vis = std::min(ks.is_lattice ? ks.n * 2 : ks.n, ks.inst_cap);
			j.nw = std::min(ks.n, ks.is_lattice ? ks.inst_cap / 2 : ks.inst_cap);
			j.need_vis_sync = (ks.last_visible != j.target_vis);
			if (!ks.dirty && !ks.page_dirty && ks.moving.empty() && !j.need_vis_sync) {
				continue;
			}
			if (tight_on && ks.n > 0) {
				// Shrunk after TIGHT_SHRINK_STEPS steps in a row where the tight size is a quarter smaller.
				int need = ks.is_lattice ? ks.n * 2 : ks.n;
				int t = _tight_size(ks, need);
				if (t >= need && (int64_t)t * 4 <= (int64_t)ks.inst_cap * 3) {
					if (++ks.low_steps >= TIGHT_SHRINK_STEPS) {
						ks.low_steps = 0;
						ks.inst_cap = t;
						j.target_vis = std::min(need, ks.inst_cap);
						j.nw = std::min(ks.n, ks.is_lattice ? ks.inst_cap / 2 : ks.inst_cap);
						j.need_vis_sync = (ks.last_visible != j.target_vis);
					}
				} else {
					ks.low_steps = 0;
				}
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
				ks.changed = true;
			}
			if (ks.n <= 0) {
				ks.moving.clear();
				ks.dirty = false;
				ks.page_dirty = false;
				if (ks.last_visible != 0 || !ks.on_records) {
					ks.last_visible = 0;
					ks.on_records = true;
					j.emit = EMIT_EMPTY;
					jobs.push_back(j);
				}
				continue;
			}
			j.was_on_records = ks.on_records;
			if (ks.dirty) {
				j.dst = ks.buf.ptrw();
				due_slots += j.nw;
			} else if (ks.page_dirty) {
				j.page_part = true;
				due_slots += (int64_t)ks.moving.size() + j.nw / 8;
			} else {
				due_slots += (int64_t)ks.moving.size();
			}
			due.push_back((int)jobs.size());
			jobs.push_back(j);
		}
	};
	plan_group(rec_kinds, rec_order);
	plan_group(lat_kinds, lat_order);

	// Phase 2: evaluate the due kinds, one task a kind on the engine's pool when there is enough work.
	WorkerThreadPool *pool = threads ? WorkerThreadPool::get_singleton() : nullptr;
	if (pool != nullptr && (int)due.size() >= THREAD_MIN_KINDS && due_slots >= THREAD_MIN_SLOTS) {
		StepGroupData d{ this, &jobs, &due, clock, min_x, max_x, min_z, max_z };
		WorkerThreadPool::GroupID gid = pool->add_native_group_task(&step_group_task, &d, (int)due.size(),
				-1, true, String("BeltMvNative.step"));
		pool->wait_for_group_task_completion(gid);
		threaded_steps++;
	} else {
		for (int i : due) {
			_eval_job(jobs[(size_t)i], clock, min_x, max_x, min_z, max_z);
		}
	}

	// Phase 3 (this thread): the result in today's kind order.
	Array out;
	BeltItemsNative *fast[2] = { nullptr, nullptr };
	if (put_ready) {
		for (int side = 0; side < 2; side++) {
			if (put_fast_id[side] != 0) {
				fast[side] = Object::cast_to<BeltItemsNative>(UtilityFunctions::instance_from_id((int64_t)put_fast_id[side]));
			}
		}
	}
	for (StepJob &j : jobs) {
		KindState &ks = *j.ks;
		if (j.page_part) {
			page_steps++;
			page_slots += j.evaluated;
		}
		switch (j.emit) {
			case EMIT_RESTORE:
				ks.put_known = false;
				push_update(out, ks.item_id, ks.is_lattice, PackedFloat32Array(), 0, 0, true, false);
				break;
			case EMIT_EMPTY:
				ks.put_known = false;
				push_update(out, ks.item_id, ks.is_lattice, ks.buf, 0, ks.inst_cap, false, true);
				ks.changed = false;
				break;
			case EMIT_PUT: {
				// Changed: new slot values, a resize, or leaving record mode / a new visible count
				// (the caller still checks its own synced state; this only replaces the hash).
				bool changed = ks.changed || j.was_on_records || j.need_vis_sync;
				int side = ks.is_lattice ? 1 : 0;
				if (fast[side] != nullptr && ks.put_known && ks.put_vis == j.target_vis && ks.put_cap == ks.inst_cap
						&& ks.put_bnds == put_bounds && !j.was_on_records) {
					// (--belt-mv-native-put) What BeltMv._emit_put_mv and ItemCards.put_mv would do with the
					// same synced state: skip an unchanged buffer, or hand it to the fast path.
					if (!changed) {
						put_skips++;
						break;
					}
					uint64_t t0 = Time::get_singleton()->get_ticks_usec();
					int r = fast[side]->try_put(ks.item_id, ks.buf, j.target_vis, ks.inst_cap, put_bounds, put_mask[side], put_epoch[side]);
					put_usec += Time::get_singleton()->get_ticks_usec() - t0;
					if (r != 0) {
						put_done++;
						if (r == 2) {
							put_uploads[side]++;
						}
						ks.changed = false;
						break;
					}
				}
				ks.put_known = false;
				push_update(out, ks.item_id, ks.is_lattice, ks.buf, j.target_vis, ks.inst_cap, false, changed);
				ks.changed = false;
			} break;
			default:
				break;
		}
	}
	jobs.clear();
	due.clear();
	put_ready = false;
	if (!rec_touched.empty() || !lat_touched.empty()) {
		// Every kind a touched page reached was stepped above; one that was not (none expected) falls back
		// to a whole pass next time rather than losing the touch.
		for (auto *kinds : { &rec_kinds, &lat_kinds }) {
			for (auto &kv : *kinds) {
				if (kv.second.page_dirty) {
					kv.second.page_dirty = false;
					kv.second.dirty = true;
				}
			}
		}
		rec_touched.clear();
		lat_touched.clear();
	}
	return out;
}

void BeltMvNative::set_threads(bool on) {
	threads = on;
}

bool BeltMvNative::get_threads() const {
	return threads;
}

int BeltMvNative::get_threaded_steps() const {
	return threaded_steps;
}

void BeltMvNative::set_page_dirty(bool on) {
	if (on == page_dirty_on) {
		return;
	}
	page_dirty_on = on;
	invalidate_all();
}

bool BeltMvNative::get_page_dirty() const {
	return page_dirty_on;
}

Array BeltMvNative::get_page_stats() const {
	Array a;
	a.append(page_steps);
	a.append(page_slots);
	return a;
}

void BeltMvNative::set_tight_cap(bool on) {
	if (on == tight_on) {
		return;
	}
	tight_on = on;
	// Every kind sized again: the records' capacity (off) or its items (on); buffers fit in the next step.
	for (auto *kinds : { &rec_kinds, &lat_kinds }) {
		for (auto &kv : *kinds) {
			KindState &ks = kv.second;
			int full = ks.is_lattice ? ks.cap * 2 : ks.cap;
			ks.inst_cap = on ? _tight_size(ks, std::min(ks.is_lattice ? ks.n * 2 : ks.n, full)) : full;
			ks.low_steps = 0;
			ks.dirty = true;
		}
	}
}

bool BeltMvNative::get_tight_cap() const {
	return tight_on;
}

int BeltMvNative::get_inst_cap(bool is_lattice, int64_t item_id) const {
	const auto &kinds = is_lattice ? lat_kinds : rec_kinds;
	auto it = kinds.find(item_id);
	return it == kinds.end() ? -1 : it->second.inst_cap;
}

void BeltMvNative::set_native_put(bool on) {
	native_put_on = on;
	if (!on) {
		forget_puts();
	}
}

bool BeltMvNative::get_native_put() const {
	return native_put_on;
}

void BeltMvNative::set_put_targets(const Variant &rec_fast, int rec_mask, int64_t rec_epoch,
		const Variant &lat_fast, int lat_mask, int64_t lat_epoch, const AABB &bounds) {
	const Variant *v[2] = { &rec_fast, &lat_fast };
	for (int side = 0; side < 2; side++) {
		Object *o = v[side]->get_type() == Variant::OBJECT ? (Object *)(*v[side]) : nullptr;
		put_fast_id[side] = Object::cast_to<BeltItemsNative>(o) != nullptr ? o->get_instance_id() : 0;
	}
	put_mask[0] = rec_mask;
	put_mask[1] = lat_mask;
	put_epoch[0] = rec_epoch;
	put_epoch[1] = lat_epoch;
	put_bounds = bounds;
	put_ready = native_put_on;
}

void BeltMvNative::mark_put(bool is_lattice, int64_t item_id, int vis, int cap) {
	if (!native_put_on) {
		return;
	}
	auto &kinds = is_lattice ? lat_kinds : rec_kinds;
	auto it = kinds.find(item_id);
	if (it == kinds.end()) {
		return;
	}
	KindState &ks = it->second;
	ks.put_known = true;
	ks.put_vis = vis;
	ks.put_cap = cap;
	ks.put_bnds = put_bounds;
}

void BeltMvNative::forget_puts() {
	for (auto *kinds : { &rec_kinds, &lat_kinds }) {
		for (auto &kv : *kinds) {
			kv.second.put_known = false;
		}
	}
}

Array BeltMvNative::take_put_counts() {
	Array a;
	a.append(put_done);
	a.append(put_uploads[0]);
	a.append(put_uploads[1]);
	a.append(put_skips);
	a.append((int64_t)put_usec);
	put_done = 0;
	put_uploads[0] = 0;
	put_uploads[1] = 0;
	put_skips = 0;
	put_usec = 0;
	return a;
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
	ClassDB::bind_method(D_METHOD("set_threads", "on"), &BeltMvNative::set_threads);
	ClassDB::bind_method(D_METHOD("get_threads"), &BeltMvNative::get_threads);
	ClassDB::bind_method(D_METHOD("get_threaded_steps"), &BeltMvNative::get_threaded_steps);
	ClassDB::bind_method(D_METHOD("set_page_dirty", "on"), &BeltMvNative::set_page_dirty);
	ClassDB::bind_method(D_METHOD("get_page_dirty"), &BeltMvNative::get_page_dirty);
	ClassDB::bind_method(D_METHOD("get_page_stats"), &BeltMvNative::get_page_stats);
	ClassDB::bind_method(D_METHOD("set_tight_cap", "on"), &BeltMvNative::set_tight_cap);
	ClassDB::bind_method(D_METHOD("get_tight_cap"), &BeltMvNative::get_tight_cap);
	ClassDB::bind_method(D_METHOD("get_inst_cap", "is_lattice", "item_id"), &BeltMvNative::get_inst_cap);
	ClassDB::bind_method(D_METHOD("set_native_put", "on"), &BeltMvNative::set_native_put);
	ClassDB::bind_method(D_METHOD("get_native_put"), &BeltMvNative::get_native_put);
	ClassDB::bind_method(D_METHOD("set_put_targets", "rec_fast", "rec_mask", "rec_epoch", "lat_fast", "lat_mask", "lat_epoch", "bounds"), &BeltMvNative::set_put_targets);
	ClassDB::bind_method(D_METHOD("mark_put", "is_lattice", "item_id", "vis", "cap"), &BeltMvNative::mark_put);
	ClassDB::bind_method(D_METHOD("forget_puts"), &BeltMvNative::forget_puts);
	ClassDB::bind_method(D_METHOD("take_put_counts"), &BeltMvNative::take_put_counts);
}
