// See chunk_build_native.h. GPL-3.0-or-later, like the rest of Zenith.
#include "chunk_build_native.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <cstdint>

using namespace godot;

void ChunkBuildNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("pack_buffer", "xforms", "colors", "custom", "upright"), &ChunkBuildNative::pack_buffer);
	ClassDB::bind_method(D_METHOD("box_bounds", "box", "xforms"), &ChunkBuildNative::box_bounds);
	ClassDB::bind_method(D_METHOD("collect_rows", "recs", "from", "to", "ctx", "keep", "merge", "far"), &ChunkBuildNative::collect_rows);
	ClassDB::bind_method(D_METHOD("shape_base", "rec"), &ChunkBuildNative::shape_base);
	ClassDB::bind_method(D_METHOD("shape_key", "rec", "count"), &ChunkBuildNative::shape_key);
}

// --walk-shape: a record's shape key, an exact packed int of what picks its model and its transform
// (chunk_view.gd _walk_rec, model_library.gd model_name / turn_dir / placed / pick_variant). Bits:
// proto id 0-19, dir 20-23, s 24-25, u 26-27, pc 28-34, pw 35, wc 36-41, wg 42-46, el 47, zv 48, and the
// variant index 49-55 (shape_key). Any value it can't pack exactly, or an extra key not on the list of those
// known not to change the model, leaves the record to GDScript (-1).
namespace {
const int SHAPE_VIDX_SHIFT = 49;
const int64_t SHAPE_HAS_ZV = int64_t(1) << 48;

// An int extra value as GDScript's int() reads it (an int, or a float from JSON), or false.
bool shape_int(const Variant &v, int64_t &out) {
	if (v.get_type() == Variant::INT) {
		out = v;
		return true;
	}
	if (v.get_type() == Variant::FLOAT) {
		const double d = v;
		if (!(d > -1e15 && d < 1e15)) {
			return false;
		}
		out = (int64_t)d; // truncated, as int(float)
		return true;
	}
	return false;
}

// The base key (all but the variant index), -1 when not packable; `seed` set when it has a VARIANT_KEY.
int64_t shape_base_of(int64_t pid, int64_t dir, const Dictionary &extra, bool &has_zv, int64_t &seed) {
	has_zv = false;
	seed = 0;
	if (pid < 0 || pid >= (int64_t(1) << 20) || dir < 0 || dir > 15) {
		return -1;
	}
	int64_t key = pid | (dir << 20);
	if (extra.is_empty()) {
		return key;
	}
	const Array ks = extra.keys();
	for (int i = 0; i < (int)ks.size(); i++) {
		const Variant kv = ks[i];
		if (kv.get_type() != Variant::STRING) {
			return -1;
		}
		const String k = kv;
		// Keys known not to change the model, its transform, rings or belt kind (docs/PROTOCOL.md "entity
		// record"; model_library.gd / chunk_view.gd read none of them for those): quality, wires, the
		// deconstruct / upgrade marks, a stop's name, Alt-mode icons, fluid arrows, lamp and signal hints, and
		// world.gd's own `pc_mod` (set on every bridge record with `pc`: pipeline_marks.gd reads it, no model
		// does). Checked before the length test, so a longer ignored key keeps the shape path.
		if (k == "q" || k == "w" || k == "r" || k == "g" || k == "d" || k == "up" || k == "n" || k == "ai" || k == "fa"
				|| k == "fc" || k == "lp" || k == "lc" || k == "sg" || k == "pc_mod") {
			continue;
		}
		if (k.length() < 1 || k.length() > 3) {
			return -1;
		}
		const Variant v = extra[kv];
		int64_t n = 0;
		if (k == "s") {
			if (v.get_type() != Variant::STRING) {
				return -1;
			}
			const String s = v;
			const int64_t c = s == "s" ? 1 : (s == "l" ? 2 : (s == "r" ? 3 : 0));
			if (c == 0) {
				return -1;
			}
			key |= c << 24;
		} else if (k == "u") {
			if (v.get_type() != Variant::STRING) {
				return -1;
			}
			const String s = v;
			const int64_t c = s == "i" ? 1 : (s == "o" ? 2 : 0);
			if (c == 0) {
				return -1;
			}
			key |= c << 26;
		} else if (k == "pc") {
			if (!shape_int(v, n) || n < 0 || n > 126) {
				return -1;
			}
			key |= (n + 1) << 28;
		} else if (k == "pw") {
			key |= int64_t(1) << 35;
		} else if (k == "wc") {
			if (!shape_int(v, n) || n < 0 || n > 62) {
				return -1;
			}
			key |= (n + 1) << 36;
		} else if (k == "wg") {
			if (!shape_int(v, n) || n < 0 || n > 30) {
				return -1;
			}
			key |= (n + 1) << 42;
		} else if (k == "el") {
			key |= int64_t(1) << 47;
		} else if (k == "zv") {
			if (v.get_type() != Variant::INT) {
				return -1;
			}
			seed = v;
			has_zv = true;
			key |= SHAPE_HAS_ZV;
		} else {
			return -1; // unknown: GDScript
		}
	}
	return key;
}

// The full key from a base and the variant count (ModelPacks.variant_pick), -1 when it doesn't fit.
int64_t shape_full(int64_t base, bool has_zv, int64_t seed, int64_t count) {
	if (base < 0) {
		return -1;
	}
	if (!has_zv) {
		return base;
	}
	const int64_t vidx = count < 2 ? 0 : ((seed >> 4) & 0xffff) % count;
	if (vidx < 0 || vidx > 127) {
		return -1;
	}
	return base | (vidx << SHAPE_VIDX_SHIFT);
}
} // namespace

int64_t ChunkBuildNative::shape_base(Object *rec) const {
	if (rec == nullptr) {
		return -1;
	}
	const Variant pid_v = rec->get("proto_id");
	const Variant dir_v = rec->get("dir");
	const Variant ex_v = rec->get("extra");
	if (pid_v.get_type() != Variant::INT || dir_v.get_type() != Variant::INT || ex_v.get_type() != Variant::DICTIONARY) {
		return -1;
	}
	bool has_zv;
	int64_t seed;
	return shape_base_of(pid_v, dir_v, ex_v, has_zv, seed);
}

int64_t ChunkBuildNative::shape_key(Object *rec, int64_t count) const {
	if (rec == nullptr) {
		return -1;
	}
	const Variant pid_v = rec->get("proto_id");
	const Variant dir_v = rec->get("dir");
	const Variant ex_v = rec->get("extra");
	if (pid_v.get_type() != Variant::INT || dir_v.get_type() != Variant::INT || ex_v.get_type() != Variant::DICTIONARY) {
		return -1;
	}
	bool has_zv;
	int64_t seed;
	const int64_t base = shape_base_of(pid_v, dir_v, ex_v, has_zv, seed);
	return shape_full(base, has_zv, seed, count);
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

// collect_rows' proto row flags (chunk_view.gd _proto_row).
static const int64_t ROW_SKIP = 1; // no prototype, or hidden: not drawn by the chunk
static const int64_t ROW_SLOW = 2; // cliffs, remnants, staged ores: GDScript
static const int64_t ROW_SWITCHABLE = 4; // Anim.SWITCHABLE_TYPES
static const int64_t ROW_PIPE_GROUND = 8; // pipe-to-ground (an open end has covers drawn)
static const int64_t ROW_DRILL = 16; // mining-drill (wet drills have their own pieces)
static const int64_t SWITCHED_OFF = 5; // Anim.SWITCHED_OFF

namespace {
struct ProtoRow {
	int64_t flags = ROW_SLOW;
	Variant type;
};
// A model's lists on one side, held for the call (the Dictionaries asked once, not per record).
struct MeshSlot {
	Array xs;
	Array rs;
	bool far_known = false;
	Variant far_type;
	Variant far_parts;
	Array far_x;
};

// A shape template's ring (ContactShade.collect, made at the template's origin) moved to the record's place:
// its centre (x, z) and, for a mask's ring, its quad's origin; float maths as the GDScript's Vector2 / Rect2.
Array shape_ring(const Array &g0, const Vector2 &pos) {
	Array g = g0.duplicate();
	if (g.size() >= 2) {
		const real_t cx = (real_t)(double)g0[0] + pos.x;
		const real_t cz = (real_t)(double)g0[1] + pos.y;
		g[0] = (double)cx;
		g[1] = (double)cz;
	}
	if (g.size() >= 9 && g[8].get_type() == Variant::TRANSFORM3D) {
		Transform3D q = g[8];
		q.origin.x += pos.x;
		q.origin.z += pos.y;
		g[8] = q;
	}
	return g;
}

// --walk-shape (collect_rows): the record's row from its shape's template, the record cache filled as
// chunk_view.gd _walk_rec fills it; false (nothing written) when it has none or _walk_rec must see it
// (cargo, a wet drill, covers, belt ends, an open underground pipe, its model not known warm).
bool shape_row(Object *rec, int64_t pid, int64_t flags, const Dictionary &extra, bool bare, int64_t generation,
		const Dictionary &seen, const Dictionary &shapes, const Dictionary &counts, Array &crow) {
	static const StringName s_covers("covers"), s_belt_ends("belt_ends"), s_dir("dir"), s_pos("pos"), s_cache_gen("cache_gen"),
			s_cache_mesh("cache_mesh"), s_cache_parts("cache_parts"), s_cache_xform("cache_xform"), s_cache_is_belt("cache_is_belt"),
			s_cache_belt_kind("cache_belt_kind"), s_cache_rings("cache_rings"), s_cache_row("cache_row");
	static const Variant k_cb("cb"), k_fa("fa"), k_pc("pc");
	if (shapes.is_empty()) {
		return false;
	}
	if (!bare && (extra.has(k_cb) || ((flags & ROW_DRILL) && extra.has(k_fa)))) {
		return false;
	}
	if ((int64_t)rec->get(s_covers) != 0 || (int64_t)rec->get(s_belt_ends) != 0) {
		return false;
	}
	const Variant dir_v = rec->get(s_dir);
	if (dir_v.get_type() != Variant::INT) {
		return false;
	}
	const int64_t dir = dir_v;
	if (flags & ROW_PIPE_GROUND) {
		const int64_t pc = extra.get(k_pc, 0);
		if ((pc & (int64_t(1) << ((dir >> 2) & 3))) == 0) {
			return false;
		}
	}
	bool has_zv;
	int64_t seed;
	const int64_t base = shape_base_of(pid, dir, extra, has_zv, seed);
	if (base < 0) {
		return false;
	}
	int64_t count = 0;
	if (has_zv) {
		const Variant c = counts.get(base, Variant());
		if (c.get_type() != Variant::INT) {
			return false;
		}
		count = c;
	}
	const int64_t key = shape_full(base, has_zv, seed, count);
	if (key < 0) {
		return false;
	}
	const Variant t_v = shapes.get(key, Variant());
	if (t_v.get_type() != Variant::ARRAY) {
		return false;
	}
	const Array t = t_v; // [mesh, parts, xform at the origin, is_belt, belt kind, rings at the origin]
	if (t.size() < 6 || t[2].get_type() != Variant::TRANSFORM3D || t[5].get_type() != Variant::ARRAY) {
		return false;
	}
	const Variant mesh_v = t[0];
	if ((Object *)mesh_v == nullptr || !seen.has(mesh_v)) {
		return false;
	}
	const Variant pos_v = rec->get(s_pos);
	if (pos_v.get_type() != Variant::VECTOR2) {
		return false;
	}
	const Vector2 pos = pos_v;
	// ModelLibrary.placed at Vector3(pos.x, 0, pos.y): the origin's y is the template's (0 + offset, then the
	// elevated track), x and z the position plus the template's offset, each one float add as there.
	const Transform3D t0 = t[2];
	const Transform3D xf(t0.basis, Vector3(pos.x + t0.origin.x, t0.origin.y, pos.y + t0.origin.z));
	const Array rings0 = t[5];
	Array rings;
	rings.resize(rings0.size());
	for (int r = 0; r < (int)rings0.size(); r++) {
		const Variant g_v = rings0[r];
		rings[r] = g_v.get_type() == Variant::ARRAY ? Variant(shape_ring(g_v, pos)) : g_v;
	}
	crow.resize(6);
	crow[0] = mesh_v;
	crow[1] = t[1];
	crow[2] = xf;
	crow[3] = t[3];
	crow[4] = t[4];
	crow[5] = rings;
	rec->set(s_cache_gen, generation);
	rec->set(s_cache_mesh, mesh_v);
	rec->set(s_cache_parts, t[1]);
	rec->set(s_cache_xform, xf);
	rec->set(s_cache_is_belt, t[3]);
	rec->set(s_cache_belt_kind, t[4]);
	rec->set(s_cache_rings, rings);
	rec->set(s_cache_row, crow);
	return true;
}
} // namespace

PackedInt32Array ChunkBuildNative::collect_rows(const Array &recs, int from, int to, const Array &ctx, const Array &keep,
		const Array &merge, const Array &far) const {
	PackedInt32Array slow;
	if (ctx.size() < 6 || keep.size() < 8 || merge.size() < 8 || far.size() < 5) {
		for (int i = from; i < to; i++) {
			slow.push_back(i);
		}
		return slow;
	}
	static const StringName s_cache_gen("cache_gen"), s_cache_row("cache_row"), s_proto_id("proto_id"), s_extra("extra"), s_covers("covers"),
			s_belt_ends("belt_ends"), s_dir("dir"), s_unit("unit"), s_key("key"), s_pos("pos");
	static const Variant k_gh("gh"), k_tg("tg"), k_hid("hid"), k_cb("cb"), k_fa("fa"), k_pc("pc"), k_r("r"), k_g("g");
	const int64_t generation = ctx[0];
	const Dictionary working = ctx[1];
	const Dictionary seen = ctx[2];
	Dictionary proto_memo = ctx[3];
	const Callable proto_row = ctx[4];
	const Callable merges_of = ctx[5];
	// --walk-shape: ctx[6] shape key -> template, ctx[7] base key -> variant count, ctx[8] hits (added to).
	const bool shapes_on = ctx.size() >= 9 && ctx[6].get_type() == Variant::DICTIONARY && ctx[7].get_type() == Variant::DICTIONARY;
	const Dictionary shapes = shapes_on ? Dictionary(ctx[6]) : Dictionary();
	const Dictionary shape_counts = shapes_on ? Dictionary(ctx[7]) : Dictionary();
	int64_t shape_hits = 0;
	Array sides[2] = { keep, merge };
	Dictionary by_model[2], recs_by_model[2], parts_by_model[2], switchable[2], belt_kinds[2];
	Array rings[2];
	Vector2 lo[2], hi[2];
	for (int s = 0; s < 2; s++) {
		by_model[s] = sides[s][0];
		recs_by_model[s] = sides[s][1];
		parts_by_model[s] = sides[s][2];
		switchable[s] = sides[s][3];
		belt_kinds[s] = sides[s][4];
		rings[s] = sides[s][5];
		lo[s] = sides[s][6];
		hi[s] = sides[s][7];
	}
	Dictionary w_off = far[0];
	Dictionary far_xf = far[1];
	Dictionary far_type = far[2];
	Dictionary far_parts = far[3];
	Array far_slow = far[4];
	HashMap<int64_t, ProtoRow> protos;
	HashMap<uint64_t, bool> merges_memo; // mesh id ^ type hash -> FarChunks.merges
	HashMap<uint64_t, MeshSlot> slots[2]; // mesh id -> its lists on that side, looked up once a call
	if (to > (int)recs.size()) {
		to = (int)recs.size();
	}
	for (int i = from; i < to; i++) {
		Object *rec = recs[i];
		if (rec == nullptr) {
			slow.push_back(i);
			continue;
		}
		const Variant pid_v = rec->get(s_proto_id);
		if (pid_v.get_type() != Variant::INT) {
			slow.push_back(i);
			continue;
		}
		const int64_t pid = pid_v;
		ProtoRow *row = protos.getptr(pid);
		if (row == nullptr) {
			ProtoRow r;
			Variant got = proto_memo.get(pid, Variant());
			if (got.get_type() != Variant::ARRAY) {
				got = proto_row.call(pid);
				proto_memo[pid] = got;
			}
			const Array a = got;
			if (a.size() >= 2) {
				r.flags = a[0];
				r.type = a[1];
			}
			protos.insert(pid, r);
			row = protos.getptr(pid);
		}
		const int64_t flags = row->flags;
		if (flags & ROW_SKIP) {
			continue;
		}
		const Dictionary extra = rec->get(s_extra);
		const bool bare = extra.is_empty();
		if (!bare && (extra.has(k_gh) || extra.has(k_tg) || extra.has(k_hid))) {
			continue; // ghosts (ghosts.gd), a belt the build of an underground pair mines
		}
		if (flags & ROW_SLOW) {
			slow.push_back(i);
			continue;
		}
		const Variant gen_v = rec->get(s_cache_gen);
		Array crow; // [mesh, parts, xform, is_belt, belt kind, rings] (world.gd Rec.cache_row)
		bool have_row = false;
		if (gen_v.get_type() == Variant::INT && (int64_t)gen_v == generation) {
			const Variant row_v = rec->get(s_cache_row);
			if (row_v.get_type() == Variant::ARRAY) {
				crow = row_v;
				have_row = crow.size() >= 6;
			}
		}
		if (!have_row && shapes_on && gen_v.get_type() == Variant::INT) {
			// --walk-shape: a record not in the record cache whose shape a build resolved already (this
			// generation): its row made from the shape's template, the record cache filled as _walk_rec does.
			have_row = shape_row(rec, pid, flags, extra, bare, generation, seen, shapes, shape_counts, crow);
			if (have_row) {
				shape_hits++;
			}
		}
		if (!have_row) {
			slow.push_back(i);
			continue;
		}
		const Variant mesh_v = crow[0];
		Object *mesh = mesh_v;
		if (mesh == nullptr || (!bare && (extra.has(k_cb) || ((flags & ROW_DRILL) && extra.has(k_fa))))
				|| (int64_t)rec->get(s_covers) != 0 || (int64_t)rec->get(s_belt_ends) != 0) {
			slow.push_back(i);
			continue;
		}
		if (flags & ROW_PIPE_GROUND) {
			const int64_t dir = rec->get(s_dir);
			const int64_t pc = extra.get(k_pc, 0);
			if ((pc & (int64_t(1) << ((dir >> 2) & 3))) == 0) {
				slow.push_back(i);
				continue;
			}
		}
		const Variant rings_v = crow[5];
		if (rings_v.get_type() != Variant::ARRAY || !seen.has(mesh_v)) {
			slow.push_back(i); // no rings kept, or its pipelines not known warm: PipelineWarm.model_ready
			continue;
		}
		const uint64_t mkey = mesh->get_instance_id() ^ ((uint64_t)row->type.hash() << 1);
		bool *mm = merges_memo.getptr(mkey);
		bool merges;
		if (mm != nullptr) {
			merges = *mm;
		} else {
			merges = merges_of.call(row->type, mesh_v);
			merges_memo.insert(mkey, merges);
		}
		const int s = merges ? 1 : 0;
		const Variant parts_v = crow[1];
		MeshSlot *slot = slots[s].getptr(mesh->get_instance_id());
		if (slot == nullptr) {
			MeshSlot m;
			if (!by_model[s].has(mesh_v)) {
				by_model[s][mesh_v] = m.xs;
				recs_by_model[s][mesh_v] = m.rs;
				parts_by_model[s][mesh_v] = parts_v;
			} else {
				m.xs = by_model[s][mesh_v];
				m.rs = recs_by_model[s][mesh_v];
			}
			slots[s].insert(mesh->get_instance_id(), m);
			slot = slots[s].getptr(mesh->get_instance_id());
		}
		const Variant xform_v = crow[2];
		slot->xs.push_back(xform_v);
		Array pair;
		pair.resize(2);
		pair[0] = Variant(rec);
		pair[1] = row->type;
		slot->rs.push_back(pair);
		rings[s].append_array(rings_v);
		if (flags & ROW_SWITCHABLE) {
			const Variant key = rec->get(s_key);
			if (bare || (!extra.has(k_r) && !extra.has(k_g))) {
				const Variant unit = rec->get(s_unit);
				const bool off = (int64_t)working.get(unit, 0) == SWITCHED_OFF;
				w_off[unit] = off;
				if (off) {
					switchable[s][key] = true;
				}
			} else {
				switchable[s][key] = true;
			}
		}
		if ((bool)crow[3]) {
			belt_kinds[s][mesh_v] = crow[4];
			const Vector2 pos = rec->get(s_pos);
			lo[s] = lo[s].min(pos);
			hi[s] = hi[s].max(pos);
		}
		if (s == 1) { // DrawLists.far_note: the far gather reads only what merges
			if (!slot->far_known) {
				slot->far_known = true;
				const Variant t = far_type.get(mesh_v, Variant());
				if (t.get_type() == Variant::NIL) {
					far_type[mesh_v] = row->type;
					far_xf[mesh_v] = slot->far_x;
					far_parts[mesh_v] = parts_v;
					slot->far_type = row->type;
					slot->far_parts = parts_v;
				} else {
					slot->far_type = t;
					slot->far_parts = far_parts[mesh_v];
					slot->far_x = far_xf[mesh_v];
				}
			}
			if (slot->far_type == row->type && slot->far_parts == parts_v) {
				slot->far_x.push_back(xform_v);
			} else {
				far_slow.push_back(Variant(rec));
			}
		}
	}
	for (int s = 0; s < 2; s++) {
		sides[s][6] = lo[s];
		sides[s][7] = hi[s];
	}
	if (shapes_on && shape_hits > 0) {
		Array c = ctx;
		c[8] = (int64_t)c[8] + shape_hits;
	}
	return slow;
}
