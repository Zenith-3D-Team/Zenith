// ChunkBuildNative: the per-instance loops of chunk_view.gd's ChunkPrepJob (pack_buffer, box_bounds) in C++,
// and the records' pass of a build for records whose model is already resolved (collect_rows, main thread).
// Stateless: one instance may be called from the worker threads at once.
// GPL-3.0-or-later, like the rest of Zenith.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include <cstdint>

namespace godot {

class ChunkBuildNative : public RefCounted {
	GDCLASS(ChunkBuildNative, RefCounted)

public:
	// ChunkPrepJob.pack_buffer: xforms (Transform3D), colors (Color, or empty), custom (room for zeroed
	// custom data), upright (identity basis at each origin).
	PackedFloat32Array pack_buffer(const Array &xforms, const Array &colors, bool custom, bool upright) const;
	// ChunkPrepJob.box_bounds: the merged bounds of box under each transform.
	AABB box_bounds(const AABB &box, const Array &xforms) const;
	// chunk_view.gd _walk_records' cached path for recs[from, to) (perf-rd-world task 4b, --native-collect):
	// each record whose model the record cache holds (cache_gen == generation, ...) is put in its side's
	// lists as the GDScript does; the indices of the others (and of those it can't decide) come back for
	// _walk_rec, in order. ctx = [generation, working, PipelineWarm's seen meshes, proto rows memo,
	// proto_row Callable (id -> [flags, type]), merges Callable (type, mesh -> bool)]; keep / merge = a
	// DrawPart as [by_model, recs_by_model, parts_by_model, switchable, belt_kinds, rings, belt_lo, belt_hi];
	// far = [w_off, far_xf, far_type, far_parts, far_slow].
	// --walk-shape (perf-w4-walk): with ctx[6] (shape key -> [mesh, parts, xform at the origin, is_belt, belt kind,
	// rings at the origin]), ctx[7] (base key -> variant count) and ctx[8] (an int, the hits added to it), a record
	// the record cache doesn't hold whose shape key has a template gets its row (and record cache) from it.
	PackedInt32Array collect_rows(const Array &recs, int from, int to, const Array &ctx, const Array &keep,
			const Array &merge, const Array &far) const;
	// --walk-shape: a record's shape key without its variant index (proto id, dir and the extra values that pick its
	// model), or -1 when it can't be packed exactly or has an extra key that may change its model.
	int64_t shape_base(Object *rec) const;
	// The full shape key: shape_base with the variant index `count` variants give its VARIANT_KEY seed, or -1.
	int64_t shape_key(Object *rec, int64_t count) const;

protected:
	static void _bind_methods();
};

} // namespace godot
