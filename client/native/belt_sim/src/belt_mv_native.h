#pragma once
// Native C++ evaluator for BeltMv (scripts/world/belt_mv.gd): populates PackedFloat32Array
// MultiMesh instance buffers for moving belt items (band <= max_band) with ping-pong pre-roll
// pairs on packed lattice lanes so Godot 4.7 Forward+ generates exact per-instance motion vectors
// under TAA / FSR 2.2 without GDScript or camera-pan overhead.

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
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
	};

private:
	std::vector<std::vector<float>> rec_pages;
	int rec_per_page = 0;
	std::vector<std::vector<float>> lat_pages;
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

	void _update_pages(const Dictionary &p, std::vector<std::vector<float>> &pages,
			std::unordered_map<int64_t, KindState> &kinds, int &per_page);
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
};

} // namespace godot
