// ChunkBuildNative: the per-instance loops of chunk_view.gd's ChunkPrepJob (pack_buffer, box_bounds) in C++.
// Stateless: one instance may be called from the worker threads at once.
// GPL-3.0-or-later, like the rest of Zenith.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

namespace godot {

class ChunkBuildNative : public RefCounted {
	GDCLASS(ChunkBuildNative, RefCounted)

public:
	// ChunkPrepJob.pack_buffer: xforms (Transform3D), colors (Color, or empty), custom (room for zeroed
	// custom data), upright (identity basis at each origin).
	PackedFloat32Array pack_buffer(const Array &xforms, const Array &colors, bool custom, bool upright) const;
	// ChunkPrepJob.box_bounds: the merged bounds of box under each transform.
	AABB box_bounds(const AABB &box, const Array &xforms) const;

protected:
	static void _bind_methods();
};

} // namespace godot
