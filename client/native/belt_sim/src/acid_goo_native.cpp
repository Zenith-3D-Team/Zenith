#include "acid_goo_native.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>

using namespace godot;

namespace {
constexpr float GRAVITY = -15.5f;

struct V3 {
	float x, y, z;
};
inline V3 operator*(const V3 &a, float s) { return { a.x * s, a.y * s, a.z * s }; }
inline V3 cross(const V3 &a, const V3 &b) { return { a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x }; }
inline V3 normalized(const V3 &a) {
	float l2 = a.x * a.x + a.y * a.y + a.z * a.z;
	if (l2 == 0.0f) {
		return { 0, 0, 0 };
	}
	float inv = 1.0f / std::sqrt(l2);
	return { a.x * inv, a.y * inv, a.z * inv };
}
inline float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }
inline float lerpf(float a, float b, float t) { return a + (b - a) * t; }
inline float smoothstepf(float from, float to, float x) {
	if (from == to) {
		return x < from ? 0.0f : 1.0f;
	}
	float s = clampf((x - from) / (to - from), 0.0f, 1.0f);
	return s * s * (3.0f - 2.0f * s);
}

// Writes basis columns (x, y, z) and origin as a MultiMesh transform: 12 floats, rows of [x.c, y.c, z.c, o.c].
inline void put_xf(float *o, const V3 &bx, const V3 &by, const V3 &bz, const float *pos) {
	o[0] = bx.x; o[1] = by.x; o[2] = bz.x; o[3] = pos[0];
	o[4] = bx.y; o[5] = by.y; o[6] = bz.y; o[7] = pos[1];
	o[8] = bx.z; o[9] = by.z; o[10] = bz.z; o[11] = pos[2];
}
inline void put_col(float *o, const float *c, float a) {
	o[12] = c[0]; o[13] = c[1]; o[14] = c[2]; o[15] = a;
}
// Frame around a direction, as the script builds it (right = up_ref x fwd, up = fwd x right).
inline void frame(const V3 &fwd, V3 &right, V3 &up) {
	V3 up_ref = std::fabs(fwd.y) < 0.94f ? V3{ 0, 1, 0 } : V3{ 1, 0, 0 };
	right = normalized(cross(up_ref, fwd));
	up = normalized(cross(fwd, right));
}
} // namespace

void AcidGooNative::size_buffers() {
	for (int g = 0; g < GROUPS; g++) {
		buf[g].resize((int64_t)cap[g] * STRIDE);
		buf[g].fill(0.0f);
	}
}

void AcidGooNative::set_caps(int p_globs, int p_drops, int p_rings, int p_mist, int p_pools) {
	cap[GLOBS] = std::max(p_globs, 1);
	cap[DROPS] = std::max(p_drops, 1);
	cap[RINGS] = std::max(p_rings, 1);
	cap[MIST] = std::max(p_mist, 1);
	cap[POOLS] = std::max(p_pools, 1);
	size_buffers();
}

void AcidGooNative::add_glob(const Vector3 &p_from, const Vector3 &p_to, double p_dur, double p_age, double p_arc_h,
		double p_scale, double p_tier, bool p_primary, double p_seed, double p_trail_cd, const Color &p_color) {
	if ((int)globs.size() >= cap[GLOBS]) {
		globs.erase(globs.begin());
	}
	Glob g;
	g.from[0] = p_from.x; g.from[1] = p_from.y; g.from[2] = p_from.z;
	g.to[0] = p_to.x; g.to[1] = p_to.y; g.to[2] = p_to.z;
	g.dur = p_dur; g.age = p_age; g.arc_h = p_arc_h; g.scale = p_scale; g.tier = p_tier; g.seed = p_seed;
	g.trail_cd = p_trail_cd; g.primary = p_primary;
	g.col[0] = p_color.r; g.col[1] = p_color.g; g.col[2] = p_color.b; g.col[3] = p_color.a;
	globs.push_back(g);
}

void AcidGooNative::add_drop(const Vector3 &p_pos, const Vector3 &p_vel, double p_size, double p_life, const Color &p_color, bool p_make_mist) {
	if ((int)drops.size() >= cap[DROPS]) {
		drops.erase(drops.begin());
	}
	Drop d;
	d.pos[0] = p_pos.x; d.pos[1] = p_pos.y; d.pos[2] = p_pos.z;
	d.vel[0] = p_vel.x; d.vel[1] = p_vel.y; d.vel[2] = p_vel.z;
	d.size = p_size; d.age = 0.0f; d.life = p_life; d.make_mist = p_make_mist;
	d.col[0] = p_color.r; d.col[1] = p_color.g; d.col[2] = p_color.b; d.col[3] = p_color.a;
	drops.push_back(d);
}

void AcidGooNative::add_ring(const Vector3 &p_pos, const Basis &p_basis, double p_scale, double p_life, const Color &p_color) {
	if ((int)rings.size() >= cap[RINGS]) {
		rings.erase(rings.begin());
	}
	Ring r;
	r.pos[0] = p_pos.x; r.pos[1] = p_pos.y; r.pos[2] = p_pos.z;
	for (int c = 0; c < 3; c++) {
		Vector3 col = p_basis.get_column(c);
		r.basis[c * 3] = col.x; r.basis[c * 3 + 1] = col.y; r.basis[c * 3 + 2] = col.z;
	}
	r.scale = p_scale; r.age = 0.0f; r.life = p_life;
	r.col[0] = p_color.r; r.col[1] = p_color.g; r.col[2] = p_color.b; r.col[3] = p_color.a;
	rings.push_back(r);
}

void AcidGooNative::add_mist(const Vector3 &p_pos, const Vector3 &p_vel, double p_size, double p_life, const Color &p_color, double p_yaw, double p_spin) {
	if ((int)mist.size() >= cap[MIST]) {
		mist.erase(mist.begin());
	}
	Mist m;
	m.pos[0] = p_pos.x; m.pos[1] = p_pos.y; m.pos[2] = p_pos.z;
	m.vel[0] = p_vel.x; m.vel[1] = p_vel.y; m.vel[2] = p_vel.z;
	m.size = p_size; m.age = 0.0f; m.life = p_life; m.base_alpha = p_color.a; m.yaw = p_yaw; m.spin = p_spin;
	m.col[0] = p_color.r; m.col[1] = p_color.g; m.col[2] = p_color.b; m.col[3] = p_color.a;
	mist.push_back(m);
}

void AcidGooNative::set_pool(int p_id, const Vector3 &p_pos, const Basis &p_basis, double p_radius, double p_fade_in,
		double p_fade_out, double p_seed, double p_pulse, double p_bubble_cd, double p_mist_cd) {
	Pool *slot = nullptr;
	for (Pool &p : pools) {
		if (p.id == p_id) {
			slot = &p;
			break;
		}
	}
	Pool np;
	np.id = p_id;
	np.pos[0] = p_pos.x; np.pos[1] = p_pos.y; np.pos[2] = p_pos.z;
	for (int c = 0; c < 3; c++) {
		Vector3 col = p_basis.get_column(c);
		np.basis[c * 3] = col.x; np.basis[c * 3 + 1] = col.y; np.basis[c * 3 + 2] = col.z;
	}
	np.radius = p_radius; np.age = 0.0f; np.fade_in = p_fade_in; np.fade_out = p_fade_out; np.gone = -1.0f;
	np.seed = p_seed; np.pulse = p_pulse; np.bubble_cd = p_bubble_cd; np.mist_cd = p_mist_cd;
	if (slot != nullptr) {
		*slot = np; // same place in the order, as a Dictionary keeps it
		return;
	}
	if ((int)pools.size() >= cap[POOLS]) {
		size_t oldest = 0;
		float max_age = -1.0f;
		for (size_t i = 0; i < pools.size(); i++) {
			if (pools[i].age > max_age) {
				max_age = pools[i].age;
				oldest = i;
			}
		}
		pools.erase(pools.begin() + oldest);
	}
	pools.push_back(np);
}

void AcidGooNative::end_pool(int p_id) {
	for (Pool &p : pools) {
		if (p.id == p_id) {
			if (p.gone < 0.0f) {
				p.gone = 0.0f;
			}
			return;
		}
	}
}

bool AcidGooNative::has_pool(int p_id) const {
	for (const Pool &p : pools) {
		if (p.id == p_id) {
			return true;
		}
	}
	return false;
}

void AcidGooNative::set_pool_cd(int p_id, int p_kind, double p_value) {
	for (Pool &p : pools) {
		if (p.id == p_id) {
			(p_kind == 0 ? p.bubble_cd : p.mist_cd) = p_value;
			return;
		}
	}
}

void AcidGooNative::clear() {
	globs.clear();
	drops.clear();
	rings.clear();
	mist.clear();
	pools.clear();
	for (int g = 0; g < GROUPS; g++) {
		vis[g] = 0;
	}
}

void AcidGooNative::clear_pools() {
	pools.clear();
	vis[POOLS] = 0;
}

PackedFloat32Array AcidGooNative::drop_xz() const {
	PackedFloat32Array out;
	out.resize((int64_t)drops.size() * 2);
	float *w = out.ptrw();
	for (size_t i = 0; i < drops.size(); i++) {
		w[i * 2] = drops[i].pos[0];
		w[i * 2 + 1] = drops[i].pos[2];
	}
	return out;
}

PackedFloat32Array AcidGooNative::buffer(int p_group) const {
	if (p_group < 0 || p_group >= GROUPS) {
		return PackedFloat32Array();
	}
	return buf[p_group];
}

PackedInt32Array AcidGooNative::counts() const {
	PackedInt32Array out;
	out.resize(GROUPS);
	for (int g = 0; g < GROUPS; g++) {
		out.set(g, vis[g]);
	}
	return out;
}

PackedInt32Array AcidGooNative::sizes() const {
	PackedInt32Array out;
	out.resize(GROUPS);
	out.set(0, (int)globs.size());
	out.set(1, (int)drops.size());
	out.set(2, (int)rings.size());
	out.set(3, (int)mist.size());
	out.set(4, (int)pools.size());
	return out;
}

int AcidGooNative::step(double p_dt, const PackedFloat32Array &p_drop_gh) {
	const float dt = (float)p_dt;
	ev_landed.resize(0);
	ev_trails.resize(0);
	ev_drop_ends.resize(0);
	ev_pool_fires.resize(0);
	if (buf[0].size() == 0) {
		size_buffers();
	}

	// --- globs ---
	{
		float *out = buf[GLOBS].ptrw();
		int vis_n = 0;
		size_t keep = 0;
		for (size_t i = 0; i < globs.size(); i++) {
			Glob g = globs[i];
			g.age += dt;
			if (g.age < 0.0f) {
				globs[keep++] = g;
				continue;
			}
			float dur = std::max(g.dur, 0.05f);
			float t = g.age / dur;
			if (t >= 1.0f) {
				float e[7] = { g.to[0], g.to[1], g.to[2], g.tier, g.primary ? 1.0f : 0.0f, 0.0f, 0.0f };
				for (float v : e) {
					ev_landed.push_back(v);
				}
				continue; // dropped
			}
			float pos[3];
			for (int k = 0; k < 3; k++) {
				pos[k] = g.from[k] + (g.to[k] - g.from[k]) * t;
			}
			pos[1] += g.arc_h * 4.0f * t * (1.0f - t);
			V3 vel = { (g.to[0] - g.from[0]) / dur, (g.to[1] - g.from[1]) / dur, (g.to[2] - g.from[2]) / dur };
			vel.y += g.arc_h * 4.0f * (1.0f - 2.0f * t) / dur;

			float trail_cd = g.trail_cd - dt;
			if (trail_cd <= 0.0f) {
				g.trail_cd = g.primary ? 0.045f : 0.075f;
				float e[12] = { pos[0], pos[1], pos[2], vel.x, vel.y, vel.z, g.scale, g.primary ? 1.0f : 0.0f, 0, 0, 0, 0 };
				for (float v : e) {
					ev_trails.push_back(v);
				}
			} else {
				g.trail_cd = trail_cd;
			}

			if (vis_n < cap[GLOBS]) {
				float spd = std::sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z);
				V3 fwd = spd > 0.05f ? V3{ vel.x / spd, vel.y / spd, vel.z / spd } : V3{ 0, 0, -1 };
				V3 right, up;
				frame(fwd, right, up);
				float stretch = clampf(1.12f + spd * 0.018f, 1.12f, 1.38f);
				float squash = 1.0f / std::sqrt(stretch);
				float wob_x = 1.0f + 0.14f * std::sin(g.age * 16.0f + g.seed);
				float wob_y = 1.0f + 0.14f * std::cos(g.age * 14.0f + g.seed * 1.7f);
				float *o = out + (int64_t)vis_n * STRIDE;
				put_xf(o, right * (g.scale * squash * wob_x * 0.62f), up * (g.scale * squash * wob_y * 0.62f),
						fwd * (g.scale * stretch * 0.68f), pos);
				put_col(o, g.col, g.col[3]);
				vis_n++;
			}
			globs[keep++] = g;
		}
		globs.resize(keep);
		vis[GLOBS] = vis_n;
	}

	// --- drops ---
	{
		const float *ghs = p_drop_gh.ptr();
		const int64_t gh_n = p_drop_gh.size();
		size_t keep = 0;
		for (size_t i = 0; i < drops.size(); i++) {
			Drop d = drops[i];
			d.age += dt;
			d.vel[1] += GRAVITY * dt;
			for (int k = 0; k < 3; k++) {
				d.pos[k] += d.vel[k] * dt;
			}
			float gh = (int64_t)i < gh_n ? ghs[i] : 0.0f;
			if (d.pos[1] <= gh + 0.02f || d.age >= d.life) {
				float e[5] = { d.pos[0], gh, d.pos[2], d.size, (d.make_mist && d.pos[1] <= gh + 0.05f) ? 1.0f : 0.0f };
				for (float v : e) {
					ev_drop_ends.push_back(v);
				}
				continue;
			}
			drops[keep++] = d;
		}
		drops.resize(keep);
		float *out = buf[DROPS].ptrw();
		int vis_n = std::min((int)drops.size(), cap[DROPS]);
		for (int k = 0; k < vis_n; k++) {
			const Drop &d = drops[k];
			float life_t = clampf(d.age / std::max(d.life, 0.05f), 0.0f, 1.0f);
			float sz = d.size * (1.0f - life_t * 0.45f);
			float spd = std::sqrt(d.vel[0] * d.vel[0] + d.vel[1] * d.vel[1] + d.vel[2] * d.vel[2]);
			V3 bx = { sz, 0, 0 }, by = { 0, sz, 0 }, bz = { 0, 0, sz };
			if (spd > 0.25f) {
				V3 fwd = { d.vel[0] / spd, d.vel[1] / spd, d.vel[2] / spd };
				V3 right, up;
				frame(fwd, right, up);
				float stretch = clampf(1.0f + spd * 0.14f, 1.0f, 2.5f);
				bx = right * sz;
				by = up * sz;
				bz = fwd * (sz * stretch);
			}
			float *o = out + (int64_t)k * STRIDE;
			put_xf(o, bx, by, bz, d.pos);
			put_col(o, d.col, d.col[3]);
		}
		vis[DROPS] = vis_n;
	}

	// --- rings ---
	{
		size_t keep = 0;
		for (size_t i = 0; i < rings.size(); i++) {
			Ring r = rings[i];
			r.age += dt;
			if (r.age >= r.life) {
				continue;
			}
			rings[keep++] = r;
		}
		rings.resize(keep);
		float *out = buf[RINGS].ptrw();
		int vis_n = std::min((int)rings.size(), cap[RINGS]);
		for (int k = 0; k < vis_n; k++) {
			const Ring &r = rings[k];
			float t = clampf(r.age / std::max(r.life, 0.05f), 0.0f, 1.0f);
			float xz_sc = r.scale * lerpf(0.32f, 1.32f, 1.0f - (1.0f - t) * (1.0f - t));
			float y_sc = r.scale * std::max(0.05f, std::sin(clampf(t / 0.85f, 0.0f, 1.0f) * 3.14159265358979f)) * 0.85f;
			V3 bx = { r.basis[0], r.basis[1], r.basis[2] };
			V3 by = { r.basis[3], r.basis[4], r.basis[5] };
			V3 bz = { r.basis[6], r.basis[7], r.basis[8] };
			float *o = out + (int64_t)k * STRIDE;
			put_xf(o, bx * xz_sc, by * y_sc, bz * xz_sc, r.pos);
			put_col(o, r.col, clampf(0.78f * (1.0f - t * t), 0.0f, 0.85f));
		}
		vis[RINGS] = vis_n;
	}

	// --- mist ---
	{
		size_t keep = 0;
		for (size_t i = 0; i < mist.size(); i++) {
			Mist m = mist[i];
			m.age += dt;
			float life = std::max(m.life, 0.05f);
			if (m.age >= life) {
				continue;
			}
			m.vel[1] += 0.4f * dt;
			float damp = std::max(0.0f, 1.0f - 1.8f * dt);
			for (int k = 0; k < 3; k++) {
				m.vel[k] *= damp;
				m.pos[k] += m.vel[k] * dt;
			}
			m.yaw += m.spin * dt;
			mist[keep++] = m;
		}
		mist.resize(keep);
		float *out = buf[MIST].ptrw();
		int vis_n = std::min((int)mist.size(), cap[MIST]);
		for (int k = 0; k < vis_n; k++) {
			const Mist &m = mist[k];
			float t = clampf(m.age / std::max(m.life, 0.05f), 0.0f, 1.0f);
			float sz = m.size * lerpf(0.60f, 1.85f, t);
			float fade = smoothstepf(0.0f, 0.16f, t) * (1.0f - t) * (1.0f - t);
			float cy = std::cos(m.yaw), sy = std::sin(m.yaw);
			float *o = out + (int64_t)k * STRIDE;
			put_xf(o, V3{ cy, 0, -sy } * sz, V3{ 0, 1, 0 } * (sz * 0.72f), V3{ sy, 0, cy } * sz, m.pos);
			put_col(o, m.col, m.base_alpha * fade);
		}
		vis[MIST] = vis_n;
	}

	// --- pools ---
	{
		size_t keep = 0;
		for (size_t i = 0; i < pools.size(); i++) {
			Pool p = pools[i];
			p.age += dt;
			if (p.gone >= 0.0f) {
				p.gone += dt;
				if (p.gone >= std::max(p.fade_out, 0.05f)) {
					continue;
				}
				pools[keep++] = p;
				continue;
			}
			float b_cd = p.bubble_cd - dt;
			if (b_cd <= 0.0f) {
				p.bubble_cd = 0.7f; // the script sets the real one
				float e[6] = { (float)p.id, 0, p.pos[0], p.pos[1], p.pos[2], p.radius };
				for (float v : e) {
					ev_pool_fires.push_back(v);
				}
			} else {
				p.bubble_cd = b_cd;
			}
			float m_cd = p.mist_cd - dt;
			if (m_cd <= 0.0f) {
				p.mist_cd = 1.0f;
				float e[6] = { (float)p.id, 1, p.pos[0], p.pos[1], p.pos[2], p.radius };
				for (float v : e) {
					ev_pool_fires.push_back(v);
				}
			} else {
				p.mist_cd = m_cd;
			}
			pools[keep++] = p;
		}
		pools.resize(keep);
		float *out = buf[POOLS].ptrw();
		int vis_n = 0;
		for (const Pool &p : pools) {
			if (vis_n >= cap[POOLS]) {
				break;
			}
			float fade_in = std::max(p.fade_in, 0.18f);
			float fi = clampf(p.age / fade_in, 0.0f, 1.0f);
			float ease_fi = 1.0f - (1.0f - fi) * (1.0f - fi);
			float spread = lerpf(0.25f, 1.0f, ease_fi);
			float alpha = clampf(fi / 0.35f, 0.0f, 1.0f);
			if (p.gone >= 0.0f) {
				float fo = clampf(1.0f - p.gone / std::max(p.fade_out, 0.05f), 0.0f, 1.0f);
				alpha *= fo;
				spread *= lerpf(0.72f, 1.0f, fo);
			}
			V3 bx = { p.basis[0], p.basis[1], p.basis[2] };
			V3 by = { p.basis[3], p.basis[4], p.basis[5] };
			V3 bz = { p.basis[6], p.basis[7], p.basis[8] };
			float *o = out + (int64_t)vis_n * STRIDE;
			put_xf(o, bx * spread, by, bz * spread, p.pos);
			o[12] = p.seed; o[13] = alpha; o[14] = spread; o[15] = p.pulse;
			vis_n++;
		}
		vis[POOLS] = vis_n;
	}

	return (int)((ev_landed.size() + ev_trails.size() + ev_drop_ends.size() + ev_pool_fires.size()) > 0);
}

void AcidGooNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_caps", "globs", "drops", "rings", "mist", "pools"), &AcidGooNative::set_caps);
	ClassDB::bind_method(D_METHOD("add_glob", "from", "to", "dur", "age", "arc_h", "scale", "tier", "primary", "seed", "trail_cd", "color"), &AcidGooNative::add_glob);
	ClassDB::bind_method(D_METHOD("add_drop", "pos", "vel", "size", "life", "color", "make_mist"), &AcidGooNative::add_drop);
	ClassDB::bind_method(D_METHOD("add_ring", "pos", "basis", "scale", "life", "color"), &AcidGooNative::add_ring);
	ClassDB::bind_method(D_METHOD("add_mist", "pos", "vel", "size", "life", "color", "yaw", "spin"), &AcidGooNative::add_mist);
	ClassDB::bind_method(D_METHOD("set_pool", "id", "pos", "basis", "radius", "fade_in", "fade_out", "seed", "pulse", "bubble_cd", "mist_cd"), &AcidGooNative::set_pool);
	ClassDB::bind_method(D_METHOD("end_pool", "id"), &AcidGooNative::end_pool);
	ClassDB::bind_method(D_METHOD("has_pool", "id"), &AcidGooNative::has_pool);
	ClassDB::bind_method(D_METHOD("set_pool_cd", "id", "kind", "value"), &AcidGooNative::set_pool_cd);
	ClassDB::bind_method(D_METHOD("clear"), &AcidGooNative::clear);
	ClassDB::bind_method(D_METHOD("clear_pools"), &AcidGooNative::clear_pools);
	ClassDB::bind_method(D_METHOD("drop_xz"), &AcidGooNative::drop_xz);
	ClassDB::bind_method(D_METHOD("step", "dt", "drop_gh"), &AcidGooNative::step);
	ClassDB::bind_method(D_METHOD("buffer", "group"), &AcidGooNative::buffer);
	ClassDB::bind_method(D_METHOD("counts"), &AcidGooNative::counts);
	ClassDB::bind_method(D_METHOD("sizes"), &AcidGooNative::sizes);
	ClassDB::bind_method(D_METHOD("landed"), &AcidGooNative::landed);
	ClassDB::bind_method(D_METHOD("trails"), &AcidGooNative::trails);
	ClassDB::bind_method(D_METHOD("drop_ends"), &AcidGooNative::drop_ends);
	ClassDB::bind_method(D_METHOD("pool_fires"), &AcidGooNative::pool_fires);
}
