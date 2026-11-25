// See chunk_build_native.h. GPL-3.0-or-later, like the rest of Zenith.
#include "chunk_build_native.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/transform3d.hpp>

using namespace godot;

void ChunkBuildNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("pack_buffer", "xforms", "colors", "custom", "upright"), &ChunkBuildNative::pack_buffer);
	ClassDB::bind_method(D_METHOD("box_bounds", "box", "xforms"), &ChunkBuildNative::box_bounds);
}

PackedFloat32Array ChunkBuildNative::pack_buffer(const Array &xforms, const Array &colors, bool custom, bool upright) const {
	int n = (int)xforms.size();
	PackedFloat32Array out;
	if (n == 0) {
		return out;
	}
	bool with_colors = !colors.is_empty();
	int stride = 12 + (with_colors ? 4 : 0) + (custom ? 4 : 0);
	out.resize((int64_t)n * stride);
	float *w = out.ptrw();
	for (int i = 0; i < n; i++) {
		Transform3D t = xforms[i];
		float *p = w + (int64_t)i * stride;
		if (upright) {
			p[0] = 1.0f;
			p[3] = t.origin.x;
			p[5] = 1.0f;
			p[7] = t.origin.y;
			p[10] = 1.0f;
			p[11] = t.origin.z;
		} else {
			for (int r = 0; r < 3; r++) {
				p[r * 4 + 0] = t.basis.rows[r][0];
				p[r * 4 + 1] = t.basis.rows[r][1];
				p[r * 4 + 2] = t.basis.rows[r][2];
				p[r * 4 + 3] = t.origin[r];
			}
		}
		if (with_colors) {
			Color c = colors[i];
			p[12] = c.r;
			p[13] = c.g;
			p[14] = c.b;
			p[15] = c.a;
		}
	}
	return out;
}

AABB ChunkBuildNative::box_bounds(const AABB &box, const Array &xforms) const {
	int n = (int)xforms.size();
	AABB out;
	Vector3 mn = box.position;
	Vector3 mx = box.position + box.size;
	for (int i = 0; i < n; i++) {
		Transform3D t = xforms[i];
		// Transform3D * AABB (Godot's xform of an AABB).
		Vector3 tmin, tmax;
		for (int r = 0; r < 3; r++) {
			tmin[r] = tmax[r] = t.origin[r];
			for (int c = 0; c < 3; c++) {
				float e = t.basis.rows[r][c] * mn[c];
				float f = t.basis.rows[r][c] * mx[c];
				if (e < f) {
					tmin[r] += e;
					tmax[r] += f;
				} else {
					tmin[r] += f;
					tmax[r] += e;
				}
			}
		}
		AABB b(tmin, tmax - tmin);
		out = (i == 0) ? b : out.merge(b);
	}
	return out;
}
