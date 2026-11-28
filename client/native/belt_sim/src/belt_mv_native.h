#pragma once
// Native C++ evaluator for BeltMv (scripts/world/belt_mv.gd): populates PackedFloat32Array
// MultiMesh instance buffers for moving belt items (band <= max_band) with ping-pong pre-roll
// pairs on packed lattice lanes so Godot 4.7 Forward+ generates exact per-instance motion vectors
// under TAA / FSR 2.2 without GDScript or camera-pan overhead.

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/vector4.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace godot {

class BeltMvNative : public RefCounted {
	GDCLASS(BeltMvNative, RefCounted)

public:
	static constexpr int STRIDE = 16;
	static constexpr float HIDE_CLOCK = 1.0e20f;
	static constexpr float SHOW_CLOCK = -1.0e20f;
	static constexpr float MAX_YAW = 0.35f;
	static constexpr float PILE_TURN = 0.45f;
	static constexpr float VRECT_MARGIN = 6.0f;
	static constexpr int64_t BAND_STEP = (int64_t)1 << 28;

	struct KindState {
		int64_t item_id = 0;
		int base = -1;
		int n = 0;
		int cap = 0;
		int inst_cap = 0;
		bool is_lattice = false;
		int variants = 0;
		PackedFloat32Array buf;
		std::vector<int> moving;
		bool dirty = true;
		int last_visible = -1;
		bool on_records = true;
		bool has_written = false;
		// Buffer content changed since the last update this kind emitted (a slot written with new
		// values, or the buffer resized): BeltMv's change flag, in place of hashing the buffer.
		bool changed = true;
		// (--belt-mv-page-dirty) A page update touched some of this kind's records: re-evaluate only
		// those slots (and copies pointing into a touched page) plus the moving ones, not the whole kind.
		bool page_dirty = false;
		// (--belt-mv-tight-cap) Steps in a row the tight size would have been a quarter smaller.
		int low_steps = 0;
		// (--belt-mv-native-put) The last put BeltMv's GDScript made for this kind went through
		// BeltItemsNative's fast path with this visible count, size and bounds: the next like it may be
		// done here (see step).
		bool put_known = false;
		int put_vis = -1;
		int put_cap = -1;
		AABB put_bnds;
	};

	// A record page held as the Image's own bytes (copy-on-write, no copy made): read-only.
	struct Page {
		PackedByteArray bytes;
		const float *f = nullptr;
		size_t n = 0;
		size_t size() const { return n; }
		const float *data() const { return f; }
	};

	// (--belt-mv-tight-cap) Buffers sized to the kind's items: rounded up to TIGHT_STEP with a quarter
	// of slack when growing, shrunk after TIGHT_SHRINK_STEPS steps where the size would be a quarter smaller.
	static constexpr int TIGHT_STEP = 256;
	static constexpr int TIGHT_SHRINK_STEPS = 120;

	// Kinds evaluated on the engine's worker pool when at least this many are due with this many
	// slots between them (`--belt-mv-threads`); below it the step runs inline as before.
	static constexpr int THREAD_MIN_KINDS = 2;
	static constexpr int64_t THREAD_MIN_SLOTS = 4096;
	enum Emit : int { EMIT_NONE = 0, EMIT_RESTORE = 1, EMIT_EMPTY = 2, EMIT_PUT = 3 };
	// One kind's share of a step: decided on the calling thread, evaluated by _eval_job (maybe on a
	// pool thread, touching only this kind), emitted on the calling thread in kind order.
	struct StepJob {
		KindState *ks = nullptr;
		float *dst = nullptr;
		int nw = 0;
		int target_vis = 0;
		bool need_vis_sync = false;
		bool was_on_records = false;
		bool page_part = false;
		int evaluated = 0;
		int emit = EMIT_NONE;
	};

	void _eval_job(StepJob &j, float clock, float min_x, float max_x, float min_z, float max_z) const;

private:
	std::vector<Page> rec_pages;
	int rec_per_page = 0;
	std::vector<Page> lat_pages;
	int lat_per_page = 0;
	std::vector<float> paths;
	int paths_w = 0;
	std::vector<std::vector<uint8_t>> mask_tiles;
	int mask_w = 0;
	int mask_h = 0;
	bool mask_on = false;
	int max_band = 0;

	std::unordered_map<int64_t, KindState> rec_kinds;
	std::unordered_map<int64_t, KindState> lat_kinds;
	std::vector<int64_t> rec_order;
	std::vector<int64_t> lat_order;
	float last_clock = -1.0e20f;
	bool threads = true;
	int threaded_steps = 0;
	std::vector<StepJob> step_jobs;
	std::vector<int> step_due;
	// (--belt-mv-page-dirty) Pages touched since the last step, per records texture.
	bool page_dirty_on = true;
	std::vector<uint8_t> rec_touched;
	std::vector<uint8_t> lat_touched;
	int page_steps = 0;
	int64_t page_slots = 0;
	// (--belt-mv-tight-cap)
	bool tight_on = true;
	// (--belt-mv-native-put) ItemCards' BeltItemsNative fast paths, their band mask and epoch, and the
	// step's bounds; puts done here since the last take_put_counts().
	bool native_put_on = false;
	uint64_t put_fast_id[2] = { 0, 0 };
	int put_mask[2] = { 0, 0 };
	int64_t put_epoch[2] = { 0, 0 };
	AABB put_bounds;
	bool put_ready = false;
	int put_done = 0;
	int put_uploads[2] = { 0, 0 };
	int put_skips = 0;
	uint64_t put_usec = 0;

	void _update_pages(const Dictionary &p, std::vector<Page> &pages,
			std::unordered_map<int64_t, KindState> &kinds, int &per_page, std::vector<uint8_t> &touched_acc);
	int _tight_size(const KindState &ks, int need) const;
	void _fit_buffer(KindState &ks, int size);
	bool _touched_slot(const KindState &ks, int s) const;
	void _set_kind(std::unordered_map<int64_t, KindState> &kinds, std::vector<int64_t> &order,
			int64_t item_id, int base, int n, int cap, bool is_lat);
	int _eval_sim_slot(const KindState &ks, float *buf, int s, float clock) const;
	int _eval_lat_slot(const KindState &ks, float *buf, int s, float clock) const;
	Vector4 _path_at(int code, float g) const;
	bool _mask_hit(float at_x, float at_z) const;
	bool _sim_slot_outside(const KindState &ks, int s, float min_x, float max_x, float min_z, float max_z) const;
	bool _lat_slot_outside(const KindState &ks, int s, float min_x, float max_x, float min_z, float max_z) const;

protected:
	static void _bind_methods();

public:
	BeltMvNative() = default;
	~BeltMvNative() = default;

	void reset();
	void invalidate_all();
	void invalidate_kind(bool is_lattice, int64_t item_id);
	void set_max_band(int p_max_band);
	void set_lat_variants(int64_t item_id, int variants);
	void update_rec_pages(const Dictionary &p);
	void update_lat_pages(const Dictionary &p);
	void update_paths(const Ref<Image> &img);
	void update_mask(const Array &tiles, bool on);
	void set_mask_on(bool on);
	void set_rec_kind(int64_t item_id, int base, int n, int cap);
	void set_lat_kind(int64_t item_id, int base, int n, int cap);
	PackedFloat32Array get_buf(bool is_lattice, int64_t item_id) const;
	int get_moving_count(bool is_lattice, int64_t item_id) const;
	Array step(float clock, const Vector4 &vrect);
	void set_threads(bool on);
	bool get_threads() const;
	int get_threaded_steps() const;
	void set_page_dirty(bool on);
	bool get_page_dirty() const;
	// [steps that re-evaluated only touched pages' slots, slots evaluated by them]
	Array get_page_stats() const;
	void set_tight_cap(bool on);
	bool get_tight_cap() const;
	int get_inst_cap(bool is_lattice, int64_t item_id) const;
	void set_native_put(bool on);
	bool get_native_put() const;
	void set_put_targets(const Variant &rec_fast, int rec_mask, int64_t rec_epoch,
			const Variant &lat_fast, int lat_mask, int64_t lat_epoch, const AABB &bounds);
	void mark_put(bool is_lattice, int64_t item_id, int vis, int cap);
	void forget_puts();
	// [puts done, uploads to records' cards, uploads to lattice cards, puts skipped unchanged]; resets them.
	Array take_put_counts();
};

} // namespace godot
