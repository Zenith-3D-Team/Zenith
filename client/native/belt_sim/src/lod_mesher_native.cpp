// LodMesherNative: see lod_mesher_native.h. Read scripts/world/lod_mesher.gd beside this.
#include "lod_mesher_native.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

using namespace godot;

namespace {

const int CAT_NONE = 0, CAT_BUILDING = 1, CAT_TREE = 2, CAT_CLIFF = 3, CAT_LOW = 4, CAT_ORE = 5, CAT_POLE = 6;
const int TILE_LAND = 0, TILE_WATER = 1, TILE_VOID = 2, TILE_LAVA = 3;
const double WATER_Y = -0.2, BANK_BOTTOM = -0.25, DECK_BOTTOM = -0.55;
const int DETAIL_FULL = 0, DETAIL_MID = 1, DETAIL_FAR = 2, DETAIL_HORIZON = 3;
const double HEIGHT_STEPS[4] = { 0.25, 0.50, 1.00, 1.50 };
const double KIND_NORMAL = 0.0, KIND_LAVA = 0.25, KIND_TREE = 0.50, KIND_GROUND = 0.75, KIND_CLIFF = 1.0;
const double PI_D = 3.14159265358979323846;

inline double clampd(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }
inline int clampi_(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
inline double snapped(double v, double step) { return step != 0.0 ? std::floor(v / step + 0.5) * step : v; }
inline double fposmod_(double x, double y) {
	double v = std::fmod(x, y);
	if ((v < 0 && y > 0) || (v > 0 && y < 0)) {
		v += y;
	}
	if (v == 0.0) {
		v = 0.0;
	}
	return v;
}

// GDScript's _hash12 (the Vector2's components are float32 there).
double hash12(float px_in, float py_in) {
	double px = fposmod_((double)px_in, 4096.0);
	double py = fposmod_((double)py_in, 4096.0);
	double x = fposmod_(px * 0.1031, 1.0);
	double y = fposmod_(py * 0.1031, 1.0);
	double z = x;
	double d = x * (y + 33.33) + y * (z + 33.33) + z * (x + 33.33);
	x += d;
	y += d;
	z += d;
	return fposmod_((x + y) * z, 1.0);
}

Color encode_color(const Color &c, double rough, double metal) {
	int rs = clampi_((int)std::llround(rough * 15.0), 0, 15);
	int ms = clampi_((int)std::llround(metal * 15.0), 0, 15);
	return Color(
			(float)std::sqrt((double)clampd(c.r, 0.0, 1.0)),
			(float)std::sqrt((double)clampd(c.g, 0.0, 1.0)),
			(float)std::sqrt((double)clampd(c.b, 0.0, 1.0)),
			(float)((double)(rs + 16 * ms) / 255.0));
}

struct V3 {
	float x, y, z;
};

struct Layer {
	std::vector<V3> v;
	std::vector<Color> c;
	std::vector<Vector2> uv;
	std::vector<int32_t> i;
};

void emit_top(Layer &L, double x0, double z0, double x1, double z1, double y, const Color &col, bool has_uv, const Vector2 &uv) {
	int32_t v = (int32_t)L.v.size();
	L.v.push_back({ (float)x0, (float)y, (float)z0 });
	L.v.push_back({ (float)x1, (float)y, (float)z0 });
	L.v.push_back({ (float)x1, (float)y, (float)z1 });
	L.v.push_back({ (float)x0, (float)y, (float)z1 });
	for (int k = 0; k < 4; k++) {
		L.c.push_back(col);
		if (has_uv) {
			L.uv.push_back(uv);
		}
	}
	L.i.insert(L.i.end(), { v, v + 1, v + 2, v, v + 2, v + 3 });
}

void emit_quad(Layer &L, const V3 &a, const V3 &b, const V3 &c, const V3 &d, const Color &ct, const Color &cb, const Vector2 &uv) {
	int32_t v = (int32_t)L.v.size();
	L.v.push_back(a);
	L.v.push_back(b);
	L.v.push_back(c);
	L.v.push_back(d);
	L.c.push_back(ct);
	L.c.push_back(ct);
	L.c.push_back(cb);
	L.c.push_back(cb);
	for (int k = 0; k < 4; k++) {
		L.uv.push_back(uv);
	}
	L.i.insert(L.i.end(), { v, v + 1, v + 2, v, v + 2, v + 3 });
}

inline V3 vv(double x, double y, double z) { return { (float)x, (float)y, (float)z }; }

struct Mesher {
	int n = 0;
	double ct = 4.0;
	Vector2 origin;
	int max_cells = 0;
	int tier = 0;
	const int32_t *tiles = nullptr;
	const int32_t *protos = nullptr;
	const uint8_t *flags = nullptr;
	int64_t flags_n = 0;
	bool has_flags = false;
	const Color *tile_colors = nullptr;
	int64_t tile_colors_n = 0;
	const uint8_t *tile_kind = nullptr;
	int64_t tile_kind_n = 0;
	const float *tile_rough = nullptr;
	int64_t tile_rough_n = 0;
	const Color *ent_top = nullptr;
	int64_t ent_top_n = 0;
	const Color *ent_side = nullptr;
	int64_t ent_side_n = 0;
	const float *ent_heights = nullptr;
	int64_t ent_heights_n = 0;
	const float *ent_metal = nullptr;
	int64_t ent_metal_n = 0;
	const float *ent_rough = nullptr;
	int64_t ent_rough_n = 0;
	const uint8_t *ent_cat = nullptr;
	int64_t ent_cat_n = 0;
	const uint8_t *ent_glow = nullptr;
	int64_t ent_glow_n = 0;
	const uint8_t *seat = nullptr;
	int64_t seat_n = 0;
	Layer S, W;

	Color tile_color(int tid) const { return (tid >= 0 && tid < tile_colors_n) ? tile_colors[tid] : Color(0.35f, 0.35f, 0.3f); }
	double box_kind(int pid) const { return (pid > 0 && pid < seat_n && seat[pid] != 0) ? KIND_CLIFF : KIND_NORMAL; }
	double rough_of(int tid) const { return (tid >= 0 && tid < tile_rough_n) ? (double)tile_rough[tid] : 0.95; }

	void terrain(const std::vector<int32_t> &flat_pid, const std::vector<uint8_t> &flat_kind, bool has_flat);
	void coast_banks(const std::vector<uint8_t> &kinds);
	void entities(const std::vector<int32_t> &flat_pid, bool has_flat);
	void poles(const std::vector<uint8_t> &cats);
	void forest_blocks(const std::vector<uint8_t> &cats);
	void box_layer(const std::vector<uint8_t> &cats, const std::vector<float> &heights, const std::vector<int32_t> &qkeys, bool is_forest);
	void box_walls(const std::vector<uint8_t> &cats, const std::vector<float> &heights, const std::vector<int32_t> &qkeys, bool is_forest, bool is_ns);
	void trees(const std::vector<uint8_t> &cats);
};

void Mesher::terrain(const std::vector<int32_t> &flat_pid, const std::vector<uint8_t> &flat_kind, bool has_flat) {
	std::vector<uint8_t> kinds(n * n);
	for (int i = 0; i < n * n; i++) {
		int tid = tiles[i];
		if (tid < 0) {
			kinds[i] = TILE_VOID;
		} else if (tid < tile_kind_n) {
			kinds[i] = tile_kind[tid];
		} else {
			kinds[i] = TILE_LAND;
		}
	}
	std::vector<uint8_t> visited(n * n, 0);
	for (int y = 0; y < n; y++) {
		for (int x = 0; x < n; x++) {
			int idx = y * n + x;
			if (visited[idx]) {
				continue;
			}
			int k = kinds[idx];
			if (k == TILE_VOID) {
				visited[idx] = 1;
				continue;
			}
			int tid = tiles[idx];
			bool check_flat = has_flat && k == TILE_LAND;
			int fpid = check_flat ? flat_pid[idx] : 0;
			int w = 1;
			while (x + w < n && w < max_cells) {
				int nidx = y * n + (x + w);
				if (visited[nidx] || tiles[nidx] != tid) {
					break;
				}
				if (check_flat && flat_pid[nidx] != fpid) {
					break;
				}
				w++;
			}
			int h = 1;
			while (y + h < n && h < max_cells) {
				bool row_ok = true;
				int row_base = (y + h) * n + x;
				for (int dx = 0; dx < w; dx++) {
					int ridx = row_base + dx;
					if (visited[ridx] || tiles[ridx] != tid) {
						row_ok = false;
						break;
					}
					if (check_flat && flat_pid[ridx] != fpid) {
						row_ok = false;
						break;
					}
				}
				if (!row_ok) {
					break;
				}
				h++;
			}
			for (int dy = 0; dy < h; dy++) {
				int r = (y + dy) * n + x;
				for (int dx = 0; dx < w; dx++) {
					visited[r + dx] = 1;
				}
			}
			double x0 = (double)x * ct, z0 = (double)y * ct;
			double x1 = (double)(x + w) * ct, z1 = (double)(y + h) * ct;
			Color raw_col = tile_color(tid);
			if (k == TILE_WATER) {
				emit_top(W, x0, z0, x1, z1, WATER_Y, encode_color(raw_col, 0.2, 0.0), false, Vector2());
			} else if (k == TILE_LAVA) {
				emit_top(S, x0, z0, x1, z1, WATER_Y, encode_color(raw_col, 0.6, 0.0), true, Vector2(1.0f, (float)KIND_LAVA));
			} else {
				double rough = rough_of(tid);
				double ukind = KIND_GROUND;
				double uglow = 0.0;
				if (fpid > 0) {
					double dens_f = has_flags ? clampd((double)(flags[idx] & 15) / 15.0, 0.25, 1.0) : 1.0;
					Color etop = fpid < ent_top_n ? ent_top[fpid] : raw_col;
					double erough = fpid < ent_rough_n ? (double)ent_rough[fpid] : rough;
					int fk = flat_kind[idx];
					double blend = fk == 2 ? clampd(0.45 + 0.40 * dens_f, 0.45, 0.85) : clampd(0.35 + 0.45 * dens_f, 0.35, 0.80);
					raw_col = raw_col.lerp(etop, (float)blend);
					rough = rough + (erough - rough) * blend;
					if (fk == 2) {
						ukind = KIND_TREE;
					} else {
						double fglow = fpid < ent_glow_n ? ((double)ent_glow[fpid] / 3.0) * dens_f * 0.55 : 0.0;
						if (fglow > 0.0) {
							uglow = fglow;
							ukind = KIND_NORMAL;
						}
					}
				}
				emit_top(S, x0, z0, x1, z1, 0.0, encode_color(raw_col, rough, 0.0), true, Vector2((float)uglow, (float)ukind));
			}
		}
	}
	if (tier < DETAIL_HORIZON) {
		coast_banks(kinds);
	}
}

void Mesher::coast_banks(const std::vector<uint8_t> &kinds) {
	const Vector2 uv(0.0f, (float)KIND_GROUND);
	for (int y = 0; y < n; y++) {
		for (int dir = -1; dir <= 1; dir += 2) {
			int ny = y + dir;
			if (ny < 0 || ny >= n) {
				continue;
			}
			int x = 0;
			while (x < n) {
				int idx = y * n + x;
				if (kinds[idx] != TILE_LAND) {
					x++;
					continue;
				}
				int nk = kinds[ny * n + x];
				if (nk == TILE_LAND) {
					x++;
					continue;
				}
				int tid = tiles[idx];
				int run = 1;
				while (x + run < n && run < max_cells) {
					int cidx = y * n + x + run;
					if (kinds[cidx] != TILE_LAND || tiles[cidx] != tid || kinds[ny * n + x + run] != nk) {
						break;
					}
					run++;
				}
				double x0 = (double)x * ct, x1 = (double)(x + run) * ct;
				double z = (double)(dir < 0 ? y : y + 1) * ct;
				double bot = nk == TILE_VOID ? DECK_BOTTOM : BANK_BOTTOM;
				Color bcol = encode_color(tile_color(tid).darkened(0.35f), rough_of(tid), 0.0);
				if (dir < 0) {
					emit_quad(S, vv(x1, 0.0, z), vv(x0, 0.0, z), vv(x0, bot, z), vv(x1, bot, z), bcol, bcol, uv);
				} else {
					emit_quad(S, vv(x0, 0.0, z), vv(x1, 0.0, z), vv(x1, bot, z), vv(x0, bot, z), bcol, bcol, uv);
				}
				x += run;
			}
		}
	}
	for (int x = 0; x < n; x++) {
		for (int dir = -1; dir <= 1; dir += 2) {
			int nx = x + dir;
			if (nx < 0 || nx >= n) {
				continue;
			}
			int y = 0;
			while (y < n) {
				int idx = y * n + x;
				if (kinds[idx] != TILE_LAND) {
					y++;
					continue;
				}
				int nk = kinds[y * n + nx];
				if (nk == TILE_LAND) {
					y++;
					continue;
				}
				int tid = tiles[idx];
				int run = 1;
				while (y + run < n && run < max_cells) {
					int cidx = (y + run) * n + x;
					if (kinds[cidx] != TILE_LAND || tiles[cidx] != tid || kinds[(y + run) * n + nx] != nk) {
						break;
					}
					run++;
				}
				double z0 = (double)y * ct, z1 = (double)(y + run) * ct;
				double wx = (double)(dir < 0 ? x : x + 1) * ct;
				double bot = nk == TILE_VOID ? DECK_BOTTOM : BANK_BOTTOM;
				Color bcol = encode_color(tile_color(tid).darkened(0.35f), rough_of(tid), 0.0);
				if (dir < 0) {
					emit_quad(S, vv(wx, 0.0, z0), vv(wx, 0.0, z1), vv(wx, bot, z1), vv(wx, bot, z0), bcol, bcol, uv);
				} else {
					emit_quad(S, vv(wx, 0.0, z1), vv(wx, 0.0, z0), vv(wx, bot, z0), vv(wx, bot, z1), bcol, bcol, uv);
				}
				y += run;
			}
		}
	}
}

void Mesher::entities(const std::vector<int32_t> &flat_pid, bool has_flat) {
	std::vector<uint8_t> cats(n * n, 0);
	std::vector<float> heights(n * n, 0.0f);
	std::vector<int32_t> qkeys(n * n, 0);
	double hstep = HEIGHT_STEPS[clampi_(tier, 0, 3)];
	bool has_trees = false, has_boxes = false, has_poles = false;
	for (int i = 0; i < n * n; i++) {
		int pid = protos[i];
		if (pid <= 0 || pid >= ent_cat_n) {
			continue;
		}
		if (has_flat && flat_pid[i] > 0) {
			continue;
		}
		int cat = ent_cat[pid];
		if (cat == CAT_NONE) {
			continue;
		}
		if (cat == CAT_POLE) {
			if (tier == DETAIL_FULL) {
				cats[i] = CAT_POLE;
				has_poles = true;
			}
			continue;
		}
		cats[i] = (uint8_t)cat;
		if (cat == CAT_TREE) {
			has_trees = true;
			continue;
		}
		has_boxes = true;
		double raw_h = pid < ent_heights_n ? (double)ent_heights[pid] : 1.0;
		int density = has_flags ? (flags[i] & 15) : 15;
		double scaled = raw_h * (0.6 + 0.4 * (double)density / 15.0);
		double qh;
		if (cat == CAT_ORE) {
			qh = clampd(snapped(scaled, 0.05), 0.10, 0.35);
		} else if (cat == CAT_LOW) {
			double s = snapped(scaled, 0.15);
			qh = s > 0.15 ? s : 0.15;
		} else {
			double s = snapped(scaled, hstep);
			qh = s > hstep ? s : hstep;
		}
		heights[i] = (float)qh; // PackedFloat32Array in GDScript
		qkeys[i] = (int32_t)std::llround(qh * 100.0);
	}
	if (has_boxes) {
		box_layer(cats, heights, qkeys, false);
	}
	if (has_trees) {
		if (tier == DETAIL_FULL) {
			trees(cats);
		} else {
			forest_blocks(cats);
		}
	}
	if (has_poles) {
		poles(cats);
	}
}

void Mesher::poles(const std::vector<uint8_t> &cats) {
	double half = clampd(ct * 0.13, 0.18, 0.42);
	const Vector2 uv(0.0f, (float)KIND_NORMAL);
	for (int y = 0; y < n; y++) {
		for (int x = 0; x < n; x++) {
			int idx = y * n + x;
			if (cats[idx] != CAT_POLE) {
				continue;
			}
			int pid = protos[idx];
			double raw_h = pid < ent_heights_n ? (double)ent_heights[pid] : 1.7;
			int density = has_flags ? (flags[idx] & 15) : 15;
			double top_h = clampd(raw_h * (0.7 + 0.3 * (double)density / 15.0), 0.9, 2.2);
			double rough = pid < ent_rough_n ? (double)ent_rough[pid] : 0.75;
			double metal = pid < ent_metal_n ? (double)ent_metal[pid] : 0.35;
			Color raw_top = pid < ent_top_n ? ent_top[pid] : Color(0.03f, 0.03f, 0.035f);
			Color raw_side = pid < ent_side_n ? ent_side[pid] : raw_top * 0.72f;
			Color tcol = encode_color(raw_top, rough, metal);
			Color scol = encode_color(raw_side, rough, metal);
			double lx = ((double)x + 0.5) * ct, lz = ((double)y + 0.5) * ct;
			double x0 = lx - half, x1 = lx + half, z0 = lz - half, z1 = lz + half;
			emit_top(S, x0, z0, x1, z1, top_h, tcol, true, uv);
			emit_quad(S, vv(x1, top_h, z0), vv(x0, top_h, z0), vv(x0, 0.0, z0), vv(x1, 0.0, z0), scol, scol, uv);
			emit_quad(S, vv(x0, top_h, z1), vv(x1, top_h, z1), vv(x1, 0.0, z1), vv(x0, 0.0, z1), scol, scol, uv);
			emit_quad(S, vv(x0, top_h, z0), vv(x0, top_h, z1), vv(x0, 0.0, z1), vv(x0, 0.0, z0), scol, scol, uv);
			emit_quad(S, vv(x1, top_h, z1), vv(x1, top_h, z0), vv(x1, 0.0, z0), vv(x1, 0.0, z1), scol, scol, uv);
		}
	}
}

void Mesher::forest_blocks(const std::vector<uint8_t> &cats) {
	std::vector<float> heights(n * n, 0.0f);
	std::vector<int32_t> qkeys(n * n, 0);
	for (int i = 0; i < n * n; i++) {
		if (cats[i] != CAT_TREE) {
			continue;
		}
		int pid = protos[i];
		double raw_h = pid < ent_heights_n ? (double)ent_heights[pid] : 3.5;
		int density = has_flags ? (flags[i] & 15) : 15;
		double scaled_h = raw_h * (0.65 + 0.35 * (double)density / 15.0);
		double qh = clampd(snapped(scaled_h, 0.75), 1.25, 4.5);
		heights[i] = (float)qh;
		qkeys[i] = (int32_t)std::llround(qh * 100.0);
	}
	box_layer(cats, heights, qkeys, true);
}

void Mesher::box_layer(const std::vector<uint8_t> &cats, const std::vector<float> &heights, const std::vector<int32_t> &qkeys, bool is_forest) {
	std::vector<uint8_t> visited(n * n, 0);
	for (int y = 0; y < n; y++) {
		for (int x = 0; x < n; x++) {
			int idx = y * n + x;
			if (visited[idx] || heights[idx] <= 0.0f) {
				continue;
			}
			int pid = protos[idx];
			int qk = qkeys[idx];
			int w = 1;
			while (x + w < n && w < max_cells) {
				int nidx = y * n + (x + w);
				if (visited[nidx] || protos[nidx] != pid || qkeys[nidx] != qk) {
					break;
				}
				w++;
			}
			int h = 1;
			while (y + h < n && h < max_cells) {
				bool row_ok = true;
				int row_base = (y + h) * n + x;
				for (int dx = 0; dx < w; dx++) {
					int ridx = row_base + dx;
					if (visited[ridx] || protos[ridx] != pid || qkeys[ridx] != qk) {
						row_ok = false;
						break;
					}
				}
				if (!row_ok) {
					break;
				}
				h++;
			}
			for (int dy = 0; dy < h; dy++) {
				int r = (y + dy) * n + x;
				for (int dx = 0; dx < w; dx++) {
					visited[r + dx] = 1;
				}
			}
			double rough = pid < ent_rough_n ? (double)ent_rough[pid] : (is_forest ? 0.95 : 0.75);
			double metal = is_forest ? 0.0 : (pid < ent_metal_n ? (double)ent_metal[pid] : 0.0);
			double dens_f = (is_forest || !has_flags) ? 1.0 : clampd((double)(flags[idx] & 15) / 15.0, 0.2, 1.0);
			double glow = pid < ent_glow_n ? ((double)ent_glow[pid] / 3.0) * dens_f : 0.0;
			double kflag = is_forest ? KIND_TREE : (cats[idx] == CAT_ORE ? KIND_GROUND : box_kind(pid));
			Color default_top = is_forest ? Color(0.16f, 0.34f, 0.12f) : Color(0.55f, 0.55f, 0.55f);
			Color raw_top = pid < ent_top_n ? ent_top[pid] : default_top;
			Color tcol = encode_color(raw_top, rough, metal);
			emit_top(S, (double)x * ct, (double)y * ct, (double)(x + w) * ct, (double)(y + h) * ct, (double)heights[idx], tcol, true,
					Vector2((float)glow, (float)kflag));
		}
	}
	box_walls(cats, heights, qkeys, is_forest, true);
	box_walls(cats, heights, qkeys, is_forest, false);
}

void Mesher::box_walls(const std::vector<uint8_t> &cats, const std::vector<float> &heights, const std::vector<int32_t> &qkeys, bool is_forest, bool is_ns) {
	for (int a = 0; a < n; a++) {
		for (int dir = -1; dir <= 1; dir += 2) {
			int na = a + dir;
			bool has_nb = na >= 0 && na < n;
			int b = 0;
			while (b < n) {
				int idx = is_ns ? (a * n + b) : (b * n + a);
				double top_h = heights[idx];
				if (top_h <= 0.0) {
					b++;
					continue;
				}
				int nb_idx = is_ns ? (na * n + b) : (b * n + na);
				double nb_h = has_nb ? (double)heights[nb_idx] : 0.0;
				if (top_h <= nb_h) {
					b++;
					continue;
				}
				int pid = protos[idx];
				int qk = qkeys[idx];
				int nb_qk = has_nb ? qkeys[nb_idx] : 0;
				int run = 1;
				while (b + run < n && run < max_cells) {
					int cidx = is_ns ? (a * n + b + run) : ((b + run) * n + a);
					int cnb_idx = is_ns ? (na * n + b + run) : ((b + run) * n + na);
					int cnb_qk = has_nb ? qkeys[cnb_idx] : 0;
					if (protos[cidx] != pid || qkeys[cidx] != qk || cnb_qk != nb_qk) {
						break;
					}
					run++;
				}
				double rough = pid < ent_rough_n ? (double)ent_rough[pid] : (is_forest ? 0.95 : 0.75);
				double metal = is_forest ? 0.0 : (pid < ent_metal_n ? (double)ent_metal[pid] : 0.0);
				double dens_f = (is_forest || !has_flags) ? 1.0 : clampd((double)(flags[idx] & 15) / 15.0, 0.2, 1.0);
				double glow = pid < ent_glow_n ? ((double)ent_glow[pid] / 3.0) * dens_f : 0.0;
				double kflag = is_forest ? KIND_TREE : (cats[idx] == CAT_ORE ? KIND_GROUND : box_kind(pid));
				Color raw_side(0.45f, 0.45f, 0.45f);
				if (is_forest) {
					Color raw_top = pid < ent_top_n ? ent_top[pid] : Color(0.16f, 0.34f, 0.12f);
					raw_side = raw_top * 0.72f;
				} else {
					raw_side = pid < ent_side_n ? ent_side[pid] : (pid < ent_top_n ? ent_top[pid] : Color(0.45f, 0.45f, 0.45f));
				}
				Color scol = encode_color(raw_side, rough, metal);
				Vector2 uv((float)glow, (float)kflag);
				double b0 = (double)b * ct, b1 = (double)(b + run) * ct;
				double plane = (double)(dir < 0 ? a : a + 1) * ct;
				if (is_ns) {
					if (dir < 0) {
						emit_quad(S, vv(b1, top_h, plane), vv(b0, top_h, plane), vv(b0, nb_h, plane), vv(b1, nb_h, plane), scol, scol, uv);
					} else {
						emit_quad(S, vv(b0, top_h, plane), vv(b1, top_h, plane), vv(b1, nb_h, plane), vv(b0, nb_h, plane), scol, scol, uv);
					}
				} else {
					if (dir < 0) {
						emit_quad(S, vv(plane, top_h, b0), vv(plane, top_h, b1), vv(plane, nb_h, b1), vv(plane, nb_h, b0), scol, scol, uv);
					} else {
						emit_quad(S, vv(plane, top_h, b1), vv(plane, top_h, b0), vv(plane, nb_h, b0), vv(plane, nb_h, b1), scol, scol, uv);
					}
				}
				b += run;
			}
		}
	}
}

void Mesher::trees(const std::vector<uint8_t> &cats) {
	for (int y = 0; y < n; y++) {
		for (int x = 0; x < n; x++) {
			int idx = y * n + x;
			if (cats[idx] != CAT_TREE) {
				continue;
			}
			int pid = protos[idx];
			double lx = ((double)x + 0.5) * ct, lz = ((double)y + 0.5) * ct;
			double wx = (double)origin.x + lx, wz = (double)origin.y + lz;
			double h0 = hash12((float)(wx * 0.37), (float)(wz * 0.37));
			double h1 = hash12((float)(wx * 0.73 + 19.1), (float)(wz * 0.73 - 7.3));
			double h2 = hash12((float)(wx * 1.13 - 41.7), (float)(wz * 1.13 + 23.9));
			double h3 = hash12((float)(wx * 1.57 + 5.3), (float)(wz * 1.57 + 61.1));
			double h4 = hash12((float)(wx * 2.11 - 11.9), (float)(wz * 2.11 - 31.7));
			int density = has_flags ? (flags[idx] & 15) : 15;
			double raw_h = pid < ent_heights_n ? (double)ent_heights[pid] : 3.5;
			double y_base = 0.25;
			double y_top_c = raw_h * (0.65 + 0.35 * (double)density / 15.0) * (0.82 + 0.36 * h0);
			double y_top = y_base + 0.6 > y_top_c ? y_base + 0.6 : y_top_c;
			double half = ct * (0.50 + 0.08 * h2);
			double angle = h1 * (PI_D * 0.5);
			double ca = std::cos(angle), sa = std::sin(angle);
			double ox = (h3 - 0.5) * ct * 0.16;
			double oz = (h4 - 0.5) * ct * 0.16;
			Color base_col = pid < ent_top_n ? ent_top[pid] : Color(0.16f, 0.34f, 0.12f);
			double col_mod = 0.86 + 0.26 * h2;
			double rough = pid < ent_rough_n ? (double)ent_rough[pid] : 0.95;
			double glow = pid < ent_glow_n ? (double)ent_glow[pid] / 3.0 : 0.0;
			Color top_col = encode_color(base_col * (float)(col_mod * 1.08), rough, 0.0);
			Color bot_col = encode_color(base_col * (float)(col_mod * 0.76), rough, 0.0);
			Vector2 uv((float)glow, (float)KIND_TREE);
			Vector2 r0((float)(-half * ca + half * sa), (float)(-half * sa - half * ca));
			Vector2 r1((float)(half * ca + half * sa), (float)(half * sa - half * ca));
			Vector2 r2 = -r0;
			Vector2 r3 = -r1;
			int32_t v = (int32_t)S.v.size();
			S.v.push_back(vv(lx + ox, y_top, lz + oz));
			S.v.push_back(vv(lx + r0.x, y_base, lz + r0.y));
			S.v.push_back(vv(lx + r1.x, y_base, lz + r1.y));
			S.v.push_back(vv(lx + r2.x, y_base, lz + r2.y));
			S.v.push_back(vv(lx + r3.x, y_base, lz + r3.y));
			S.c.push_back(top_col);
			for (int k = 0; k < 4; k++) {
				S.c.push_back(bot_col);
			}
			for (int k = 0; k < 5; k++) {
				S.uv.push_back(uv);
			}
			S.i.insert(S.i.end(), { v, v + 1, v + 2, v, v + 2, v + 3, v, v + 3, v + 4, v, v + 4, v + 1 });
		}
	}
}

} // namespace

void LodMesherNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("build", "p"), &LodMesherNative::build);
	ClassDB::bind_method(D_METHOD("merge", "groups"), &LodMesherNative::merge);
}

Dictionary LodMesherNative::build(const Dictionary &p) const {
	Dictionary out;
	Mesher m;
	m.n = (int)(int64_t)p["n"];
	m.ct = (double)p["cell_tiles"];
	m.origin = p["section_origin"];
	double max_quad = (double)p["max_quad_tiles"];
	m.max_cells = m.n;
	if (std::isfinite(max_quad) && max_quad > 0.0) {
		double d = m.ct > 0.001 ? m.ct : 0.001;
		int mc = (int)std::floor(max_quad / d);
		m.max_cells = mc > 1 ? mc : 1;
	}
	int tier = clampi_((int)(int64_t)p["detail_tier"], DETAIL_FULL, DETAIL_HORIZON);
	m.tier = tier;
	int n = m.n;
	PackedInt32Array tiles = p["tiles"];
	PackedInt32Array protos = p["protos"];
	PackedByteArray flags = p["flags"];
	PackedColorArray tile_colors = p["tile_colors"];
	PackedByteArray tile_kind = p["tile_kind"];
	PackedFloat32Array tile_rough = p["tile_rough"];
	PackedColorArray ent_top = p["ent_top"];
	PackedColorArray ent_side = p["ent_side"];
	PackedFloat32Array ent_heights = p["ent_heights"];
	PackedFloat32Array ent_metal = p["ent_metal"];
	PackedFloat32Array ent_rough = p["ent_rough"];
	PackedByteArray ent_cat = p["ent_cat"];
	PackedByteArray ent_glow = p["ent_glow"];
	PackedByteArray seat = p["seat"];
	if (n <= 0 || tiles.size() != (int64_t)n * n) {
		return out;
	}
	m.tiles = tiles.ptr();
	m.has_flags = flags.size() == (int64_t)n * n;
	m.flags = flags.ptr();
	m.tile_colors = tile_colors.ptr();
	m.tile_colors_n = tile_colors.size();
	m.tile_kind = tile_kind.ptr();
	m.tile_kind_n = tile_kind.size();
	m.tile_rough = tile_rough.ptr();
	m.tile_rough_n = tile_rough.size();
	m.ent_top = ent_top.ptr();
	m.ent_top_n = ent_top.size();
	m.ent_side = ent_side.ptr();
	m.ent_side_n = ent_side.size();
	m.ent_heights = ent_heights.ptr();
	m.ent_heights_n = ent_heights.size();
	m.ent_metal = ent_metal.ptr();
	m.ent_metal_n = ent_metal.size();
	m.ent_rough = ent_rough.ptr();
	m.ent_rough_n = ent_rough.size();
	m.ent_cat = ent_cat.ptr();
	m.ent_cat_n = ent_cat.size();
	m.ent_glow = ent_glow.ptr();
	m.ent_glow_n = ent_glow.size();
	m.seat = seat.ptr();
	m.seat_n = seat.size();
	bool have_protos = protos.size() == (int64_t)n * n && m.ent_cat_n > 0;
	m.protos = protos.ptr();

	std::vector<int32_t> flat_pid;
	std::vector<uint8_t> flat_kind;
	bool has_flat = false;
	if (tier > DETAIL_FULL && have_protos) {
		has_flat = true;
		flat_pid.assign((size_t)n * n, 0);
		flat_kind.assign((size_t)n * n, 0);
		for (int i = 0; i < n * n; i++) {
			int pid = m.protos[i];
			if (pid <= 0 || pid >= m.ent_cat_n) {
				continue;
			}
			int cat = m.ent_cat[pid];
			if (cat == CAT_NONE || cat == CAT_POLE) {
				continue;
			}
			if (cat == CAT_LOW || cat == CAT_ORE) {
				if (tier >= DETAIL_MID) {
					flat_pid[i] = pid;
					flat_kind[i] = 1;
				}
			} else if (cat == CAT_TREE) {
				if (tier >= DETAIL_FAR) {
					flat_pid[i] = pid;
					flat_kind[i] = 2;
				}
			} else if (tier >= DETAIL_HORIZON) {
				double raw_h = pid < m.ent_heights_n ? (double)m.ent_heights[pid] : 1.0;
				int dens = m.has_flags ? (m.flags[i] & 15) : 15;
				if (raw_h < 1.5 || dens < 3) {
					flat_pid[i] = pid;
					flat_kind[i] = 1;
				}
			}
		}
	}
	m.terrain(flat_pid, flat_kind, has_flat);
	if (have_protos) {
		m.entities(flat_pid, has_flat);
	}

	PackedVector3Array sv;
	PackedColorArray sc;
	PackedVector2Array su;
	PackedInt32Array si;
	PackedVector3Array wv;
	PackedColorArray wc;
	PackedInt32Array wi;
	auto fill = [](const Layer &L, PackedVector3Array &v, PackedColorArray &c, PackedVector2Array *uv, PackedInt32Array &idx) {
		v.resize((int64_t)L.v.size());
		if (!L.v.empty()) {
			std::memcpy(v.ptrw(), L.v.data(), L.v.size() * sizeof(V3));
		}
		c.resize((int64_t)L.c.size());
		if (!L.c.empty()) {
			std::memcpy(c.ptrw(), L.c.data(), L.c.size() * sizeof(Color));
		}
		if (uv) {
			uv->resize((int64_t)L.uv.size());
			if (!L.uv.empty()) {
				std::memcpy(uv->ptrw(), L.uv.data(), L.uv.size() * sizeof(Vector2));
			}
		}
		idx.resize((int64_t)L.i.size());
		if (!L.i.empty()) {
			std::memcpy(idx.ptrw(), L.i.data(), L.i.size() * sizeof(int32_t));
		}
	};
	fill(m.S, sv, sc, &su, si);
	fill(m.W, wv, wc, nullptr, wi);
	out["sv"] = sv;
	out["sc"] = sc;
	out["su"] = su;
	out["si"] = si;
	out["wv"] = wv;
	out["wc"] = wc;
	out["wi"] = wi;
	return out;
}

namespace {

struct MLayer {
	std::vector<Vector3> v;
	std::vector<Color> c;
	std::vector<int32_t> i;
};

void fill_v3(const std::vector<Vector3> &s, PackedVector3Array &d) {
	d.resize((int64_t)s.size());
	if (!s.empty()) {
		std::memcpy(d.ptrw(), s.data(), s.size() * sizeof(Vector3));
	}
}
void fill_c(const std::vector<Color> &s, PackedColorArray &d) {
	d.resize((int64_t)s.size());
	if (!s.empty()) {
		std::memcpy(d.ptrw(), s.data(), s.size() * sizeof(Color));
	}
}
void fill_i(const std::vector<int32_t> &s, PackedInt32Array &d) {
	d.resize((int64_t)s.size());
	if (!s.empty()) {
		std::memcpy(d.ptrw(), s.data(), s.size() * sizeof(int32_t));
	}
}

} // namespace

Dictionary LodMesherNative::merge(const Array &groups) const {
	MLayer sol, nat, low;
	std::vector<Vector3> cv;
	std::vector<Color> cc;
	std::vector<Vector2> cu;
	std::vector<int32_t> ci;
	const int64_t group_count = groups.size();
	for (int64_t gi = 0; gi < group_count; gi++) {
		Array g = groups[gi];
		PackedVector3Array bv = g[0];
		PackedColorArray bc = g[1];
		PackedInt32Array bi = g[2];
		PackedVector3Array crv = g[3];
		PackedColorArray crc = g[4];
		PackedInt32Array cri = g[5];
		PackedVector3Array leaf = g[6];
		int kind = (int)(int64_t)g[7];
		Array xforms = g[8];
		Variant tint_v = g[9];
		bool has_tint = tint_v.get_type() == Variant::COLOR;
		Color tint = has_tint ? (Color)tint_v : Color();
		const double tr = has_tint ? std::sqrt((double)tint.r) : 0.0;
		const double tg = has_tint ? std::sqrt((double)tint.g) : 0.0;
		const double tb = has_tint ? std::sqrt((double)tint.b) : 0.0;
		const int64_t nb = bv.size();
		const int64_t xn = xforms.size();
		const Vector3 *bvp = bv.ptr();
		const Color *bcp = bc.ptr();
		const Vector3 *crvp = crv.ptr();
		const Color *crcp = crc.ptr();
		for (int64_t xi = 0; xi < xn; xi++) {
			Transform3D xf = xforms[xi];
			if (bi.size() > 0) {
				MLayer &L = kind == 2 ? low : (kind == 1 ? nat : sol);
				int32_t base = (int32_t)L.v.size();
				size_t at = L.v.size();
				L.v.resize(at + (size_t)nb);
				for (int64_t k = 0; k < nb; k++) {
					L.v[at + k] = xf.xform(bvp[k]);
				}
				size_t cat = L.c.size();
				L.c.resize(cat + (size_t)bc.size());
				if (has_tint && kind != 2) {
					for (int64_t k = 0; k < bc.size(); k++) {
						const Color &c = bcp[k];
						L.c[cat + k] = Color((float)((double)c.r * tr), (float)((double)c.g * tg), (float)((double)c.b * tb), c.a);
					}
				} else {
					for (int64_t k = 0; k < bc.size(); k++) {
						L.c[cat + k] = bcp[k];
					}
				}
				const int32_t *bip = bi.ptr();
				size_t iat = L.i.size();
				L.i.resize(iat + (size_t)bi.size());
				for (int64_t k = 0; k < bi.size(); k++) {
					L.i[iat + k] = bip[k] + base;
				}
			}
			if (!has_tint && cri.size() > 0) {
				int32_t c_base = (int32_t)cv.size();
				size_t at = cv.size();
				cv.resize(at + (size_t)crv.size());
				for (int64_t k = 0; k < crv.size(); k++) {
					cv[at + k] = xf.xform(crvp[k]);
				}
				float ox = xf.origin.x, oz = xf.origin.z;
				size_t cat = cc.size();
				cc.resize(cat + (size_t)crc.size());
				if (leaf.size() == 0) {
					for (int64_t k = 0; k < crc.size(); k++) {
						cc[cat + k] = crcp[k];
					}
				} else {
					float hx = ox * 3.17f + 0.5f, hz = oz * 3.17f + 0.5f;
					double seed = hash12(hx, hz);
					int ti = (int)(fposmod_(seed * 13.37 + 0.21, 1.0) * (double)leaf.size());
					ti = clampi_(ti, 0, (int)leaf.size() - 1);
					Vector3 lt = leaf[ti];
					double sr = std::sqrt(std::fmax((double)lt.x, 0.0));
					double sg = std::sqrt(std::fmax((double)lt.y, 0.0));
					double sb = std::sqrt(std::fmax((double)lt.z, 0.0));
					for (int64_t k = 0; k < crc.size(); k++) {
						const Color &c = crcp[k];
						cc[cat + k] = Color((float)((double)c.r * sr), (float)((double)c.g * sg), (float)((double)c.b * sb), c.a);
					}
				}
				cu.insert(cu.end(), (size_t)crv.size(), Vector2(ox, oz));
				const int32_t *crip = cri.ptr();
				size_t iat = ci.size();
				ci.resize(iat + (size_t)cri.size());
				for (int64_t k = 0; k < cri.size(); k++) {
					ci[iat + k] = crip[k] + c_base;
				}
			}
		}
	}
	Dictionary out;
	PackedVector3Array a_v, a_nv, a_lv, a_cv;
	PackedColorArray a_c, a_nc, a_lc, a_cc;
	PackedInt32Array a_i, a_ni, a_li, a_ci;
	PackedVector2Array a_cu;
	fill_v3(sol.v, a_v); fill_c(sol.c, a_c); fill_i(sol.i, a_i);
	fill_v3(nat.v, a_nv); fill_c(nat.c, a_nc); fill_i(nat.i, a_ni);
	fill_v3(low.v, a_lv); fill_c(low.c, a_lc); fill_i(low.i, a_li);
	fill_v3(cv, a_cv); fill_c(cc, a_cc); fill_i(ci, a_ci);
	a_cu.resize((int64_t)cu.size());
	if (!cu.empty()) {
		std::memcpy(a_cu.ptrw(), cu.data(), cu.size() * sizeof(Vector2));
	}
	out["v"] = a_v; out["c"] = a_c; out["i"] = a_i;
	out["nv"] = a_nv; out["nc"] = a_nc; out["ni"] = a_ni;
	out["lv"] = a_lv; out["lc"] = a_lc; out["li"] = a_li;
	out["cv"] = a_cv; out["cc"] = a_cc; out["cu"] = a_cu; out["ci"] = a_ci;
	return out;
}
