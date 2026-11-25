// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
// TerrainFieldNative: the hot loops of the Terrain Elevation add-on's height field (its
// scripts/heights.gd) in C++, for add-ons through api.terrain.native() (addon_terrain.gd).
// Stateless: every method takes its inputs and returns new arrays, so one object serves any
// number of worker threads at once. Each method gives the same floats as the GDScript it stands
// for: Godot's own FastNoiseLite for the noise, float32 where GDScript has a Vector2 or a packed
// array, double where it has a float.

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/vector2.hpp>

namespace godot {

class TerrainFieldNative : public RefCounted {
	GDCLASS(TerrainFieldNative, RefCounted)

protected:
	static void _bind_methods();

public:
	// The interface's version: an add-on can check it before using a later method.
	int version() const { return 1; }
	// heights.gd _hills_rows over rows j0..j1-1, columns i0..i1-1 of `h` (size x size), returned.
	PackedFloat32Array hills(const PackedFloat32Array &h, int size, Vector2 origin, double step, int noise_seed,
			double height, double hill_size, double detail, int i0, int i1, int j0, int j1) const;
	// heights.gd _cliffs: `cliffs` 11 floats a cliff: at.x, at.y, up.x, up.y, line kind (0 straight,
	// 1 quarter circle, -1 none: as without `trace`), then the line's points (cliff_line: start, end;
	// or corner, start, end). Returns [raise, near].
	Array cliffs(int size, Vector2 origin, double step, const PackedFloat32Array &cliffs, bool seat, bool trace,
			double cliff_height) const;
	// heights.gd _water_distance: `wet` Vector2i chunk -> PackedByteArray of its 32 x 32 kinds.
	// Empty when no water lies in the grid.
	PackedFloat32Array water_distance(int size, Vector2 origin, double step, const Dictionary &wet) const;
	// heights.gd's "ground" stage: the shores (`water` empty: none), the edges, the sum with the
	// terraces and the range. Returns [ground, full (the ground itself without cliffs), lift].
	Array base(const PackedFloat32Array &hills, const PackedFloat32Array &raise, const PackedFloat32Array &water,
			int size, double step, double shore, int edge, bool with_cliffs) const;
	// heights.gd _pads over `f`: `pads` pairs of (position, half size). Returned.
	PackedFloat32Array pads(const PackedFloat32Array &f, int size, Vector2 origin, double step,
			const PackedVector2Array &pads, double margin) const;
	// The image's floats: red `full`, green `ground`, with `channels` 3 blue `tint` (empty: 0).
	PackedFloat32Array interleave(const PackedFloat32Array &full, const PackedFloat32Array &ground,
			const PackedFloat32Array &tint, int channels) const;
};

} // namespace godot
