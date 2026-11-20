// What BeltDrawNative (belt_draw_native.cpp) and BeltLatticeNative (belt_lattice_native.cpp) share: the
// GPU records' pages (belt_records.gd), a map in GDScript's insertion order, and the small helpers that
// round where GDScript does (float32 in Vector2/3/4 and the records, double elsewhere).
#pragma once

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <unordered_map>
#include <vector>

namespace godot {
namespace beltn {

typedef int64_t i64;

// belt_records.gd
static constexpr int TEXELS = 4;
static constexpr int ROW = 1024;
static constexpr int PAGE_ROWS = 16;  // (--belt-draw-small-pages=off)
static constexpr int SMALL_ROWS = 4;
static constexpr int START_PAGES = 8;  // (small) the pages the array starts with
static constexpr int FLOATS = TEXELS * 4;
static constexpr int MIN_RUN = 64;
static constexpr float HIDDEN = -1.0f;
static constexpr double MAX_YAW = 0.35;  // item_cards.gd

inline i64 now_us() {
	return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

inline double clampd(double v, double lo, double hi) {
	return v < lo ? lo : (v > hi ? hi : v);
}

inline double lerpd(double a, double b, double t) {
	return a + (b - a) * t;
}

// Math::wrapf
inline double wrapd(double value, double min, double max) {
	double range = max - min;
	return std::fabs(range) < 1e-15 ? min : value - (range * std::floor((value - min) / range));
}

// GDScript's hash(int): Variant::hash() -> hash_one_uint64, a uint32. Godot 4.7's hashfuncs.h (the
// shifts and multiplier changed from 4.5's 21/24/3,8/14/2,4/28/31: on 4.7.2 every item's turn drawn by
// the C++ paths differed from the GDScript paths' until this followed; checked against hash() of
// 0, -1, 12345, 257790904, -93708885 and -190439571 on 4.7.2).
inline uint32_t hash_int(i64 x) {
	uint64_t v = (uint64_t)x;
	v = (~v) + (v << 18);
	v = v ^ (v >> 31);
	v = v * 21;
	v = v ^ (v >> 11);
	v = v + (v << 6);
	v = v ^ (v >> 22);
	return (uint32_t)v;
}

inline i64 posmod(i64 a, i64 b) {
	i64 r = a % b;
	if (r != 0 && ((r < 0) != (b < 0))) {
		r += b;
	}
	return r;
}

// Math::round (as roundi)
inline i64 roundi(double x) {
	return (i64)std::round(x);
}

// item_cards.gd yaw_for
inline double yaw_for(i64 seed) {
	return ((double)posmod((i64)hash_int(seed), 2001) / 1000.0 - 1.0) * MAX_YAW;
}

// item_cards.gd lattice_turn (belt_path.gdshaderinc belt_lattice_turn): a packed lane's item's turn from who
// it is along its run (its low 20 bits) and the run's seed, without a pile's copies.
inline uint32_t lattice_hash(i64 who, i64 run) {
	uint32_t x = (uint32_t)(who & 0xFFFFF) + (uint32_t)run * 2654435769u;
	x = x ^ (x >> 16);
	x = x * 2146121005u;
	x = x ^ (x >> 15);
	x = x * 2221713035u;
	x = x ^ (x >> 16);
	return x;
}

inline double lattice_turn(i64 who, i64 run) {
	return ((double)(lattice_hash(who, run) % 2001u) / 1000.0 - 1.0) * MAX_YAW;
}

// item_cards.gd lattice_variant (belt_path.gdshaderinc belt_lattice_variant): which of `count` model variants.
inline i64 lattice_variant(i64 who, i64 run, i64 count) {
	return count < 2 ? 0 : (i64)((lattice_hash(who, run) >> 8) % (uint32_t)count);
}

template <class P, class T>
inline P to_packed(const std::vector<T> &v) {
	P a;
	a.resize((int64_t)v.size());
	if (!v.empty()) {
		memcpy(a.ptrw(), v.data(), v.size() * sizeof(T));
	}
	return a;
}

// A map in insertion order (GDScript's Dictionary), erasures leaving holes compacted now and then.
template <class K, class V>
struct Ordered {
	std::unordered_map<K, size_t> idx;
	std::vector<K> keys;
	std::vector<V> vals;
	std::vector<uint8_t> live;
	size_t count = 0;

	V *get(const K &k) {
		auto f = idx.find(k);
		return f == idx.end() ? nullptr : &vals[f->second];
	}
	bool has(const K &k) const { return idx.count(k) != 0; }
	// Sets (an existing key keeps its place).
	void set(const K &k, const V &v) {
		auto f = idx.find(k);
		if (f != idx.end()) {
			vals[f->second] = v;
			return;
		}
		idx[k] = keys.size();
		keys.push_back(k);
		vals.push_back(v);
		live.push_back(1);
		count++;
	}
	bool erase(const K &k) {
		auto f = idx.find(k);
		if (f == idx.end()) {
			return false;
		}
		live[f->second] = 0;
		idx.erase(f);
		count--;
		if (keys.size() > 64 && count * 2 < keys.size()) {
			compact();
		}
		return true;
	}
	void compact() {
		std::vector<K> nk;
		std::vector<V> nv;
		nk.reserve(count);
		nv.reserve(count);
		for (size_t i = 0; i < keys.size(); i++) {
			if (live[i]) {
				nk.push_back(keys[i]);
				nv.push_back(vals[i]);
			}
		}
		keys.swap(nk);
		vals.swap(nv);
		live.assign(keys.size(), 1);
		idx.clear();
		for (size_t i = 0; i < keys.size(); i++) {
			idx[keys[i]] = i;
		}
	}
	std::vector<K> key_list() const {
		std::vector<K> r;
		r.reserve(count);
		for (size_t i = 0; i < keys.size(); i++) {
			if (live[i]) {
				r.push_back(keys[i]);
			}
		}
		return r;
	}
	std::vector<V> val_list() const {
		std::vector<V> r;
		r.reserve(count);
		for (size_t i = 0; i < keys.size(); i++) {
			if (live[i]) {
				r.push_back(vals[i]);
			}
		}
		return r;
	}
	size_t size() const { return count; }
	void clear() {
		idx.clear();
		keys.clear();
		vals.clear();
		live.clear();
		count = 0;
	}
};

// belt_records.gd: the records' pages, the ones written since take_pages() handed to the main thread.
struct Records {
	// A page's rows, records and floats, and the pages the array starts with (set_small, before any alloc).
	int rows = PAGE_ROWS;
	int per_page = ROW * PAGE_ROWS / TEXELS;
	int page_floats = ROW * PAGE_ROWS / TEXELS * FLOATS;
	int start_pages = 1;
	std::vector<float> data;
	int pages = 0;
	std::vector<int> dirty;  // pages written since take_pages, in order
	std::vector<uint8_t> dirty_f;
	bool all_dirty = false;
	int top = 0;
	std::unordered_map<int, std::vector<int>> free;

	void set_small(bool small);
	int alloc(int n);
	void release(int start, int size);
	void copy(int from, int to, int n);
	void grow(int records);
	void mark(int page);
	void mark_range(int start, int n);
	void hide(int r);
	Dictionary take_pages();
};

} // namespace beltn
} // namespace godot
