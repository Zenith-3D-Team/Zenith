#pragma once
// BeltItemsNative: the steady-state fast path of ItemCards.put_mv (scripts/world/item_cards.gd).
// BeltMvNative already fills the MultiMesh buffers; what ran in GDScript each frame was the per-kind
// bookkeeping around handing one over (dictionary reads, state arrays, visibility checks). For a kind
// whose state did not change since the GDScript path last set it up, try_put() does just what that
// path ends with (RenderingServer.multimesh_set_buffer, visible count) and says so; any change
// (hidden, loading, new cap/bounds/band mask, variants epoch) returns 0 and GDScript runs as before.
// GPL-3.0.

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include <cstdint>
#include <unordered_map>

namespace godot {

class BeltItemsNative : public RefCounted {
	GDCLASS(BeltItemsNative, RefCounted)

	struct Reg {
		uint64_t object_id = 0; // the kind's MultiMeshInstance3D
		int cap = 0;
		int mask = 0;
		bool nonzero = false;
		AABB bounds;
	};
	std::unordered_map<int64_t, Reg> regs;
	int64_t epoch = 0;

protected:
	static void _bind_methods();

public:
	// Remembers a kind the GDScript path just brought to its steady state.
	void register_kind(int64_t key, int64_t object_id, int cap, int mask, bool nonzero, const AABB &bounds, int64_t p_epoch);
	void unregister_kind(int64_t key);
	void clear();
	// 0: not handled (run the GDScript path); 1: handled; 2: handled and the buffer was uploaded.
	int try_put(int64_t key, const PackedFloat32Array &buf, int visible_count, int cap, const AABB &bounds, int mask, int64_t p_epoch);
	int registered_count() const { return (int)regs.size(); }
};

} // namespace godot
