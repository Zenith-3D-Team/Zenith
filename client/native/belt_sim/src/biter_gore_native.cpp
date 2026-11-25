// SPDX-License-Identifier: GPL-3.0-or-later
#include "biter_gore_native.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>
#include <limits>

using namespace godot;

namespace {
constexpr int STRIDE = 16; // 3x4 transform + colour
constexpr float GRAVITY = -16.5f;
constexpr float GIB_LIFE = 12.0f;
constexpr float GIB_FADE = 2.0f;
constexpr int KIND_MEAT = 1;
constexpr int KIND_SPIKE = 2;
constexpr int EV = 11;

inline void put_color(float *o, const Color &c) {
	o[12] = c.r;
	o[13] = c.g;
	o[14] = c.b;
	o[15] = c.a;
}
// Columns x, y, z and the origin into Godot's row-major 3x4 buffer.
inline void put_cols(float *o, const Vector3 &cx, const Vector3 &cy, const Vector3 &cz, const Vector3 &org) {
	o[0] = cx.x; o[1] = cy.x; o[2] = cz.x; o[3] = org.x;
	o[4] = cx.y; o[5] = cy.y; o[6] = cz.y; o[7] = org.y;
	o[8] = cx.z; o[9] = cy.z; o[10] = cz.z; o[11] = org.z;
}
} // namespace

float BiterGoreNative::randf() {
	rng_state ^= rng_state << 13;
	rng_state ^= rng_state >> 7;
	rng_state ^= rng_state << 17;
	return (float)((rng_state >> 40) & 0xFFFFFF) / 16777216.0f;
}

void BiterGoreNative::set_seed(int64_t p_seed) {
	rng_state = (uint64_t)p_seed * 0x9E3779B97F4A7C15ULL + 0x1234567ULL;
	if (rng_state == 0) {
		rng_state = 0x9E3779B97F4A7C15ULL;
	}
}

void BiterGoreNative::setup(int p_max_droplets, int p_max_decals, int p_max_gibs) {
	max_droplets = p_max_droplets;
	max_decals = p_max_decals;
	max_gibs = p_max_gibs;
	droplets.clear();
	droplets.reserve(max_droplets);
	gibs.clear();
	gibs.reserve(max_gibs);
	decals.assign(max_decals, Decal());
	droplet_buf.resize((int64_t)max_droplets * STRIDE);
	droplet_buf.fill(0.0f);
	decal_buf.resize((int64_t)max_decals * STRIDE);
	decal_buf.fill(0.0f);
	for (int k = 0; k < 3; k++) {
		gib_buf[k].resize((int64_t)max_gibs * STRIDE);
		gib_buf[k].fill(0.0f);
		gib_n[k] = 0;
	}
	droplet_n = 0;
	decal_dirty = false;
}

void BiterGoreNative::clear() {
	droplets.clear();
	gibs.clear();
	decals.assign(max_decals, Decal());
	droplet_n = 0;
	for (int k = 0; k < 3; k++) {
		gib_n[k] = 0;
	}
	decal_dirty = false;
}

void BiterGoreNative::add_droplet(const Vector3 &p_pos, const Vector3 &p_vel, float p_size, float p_life, const Color &p_color,
		float p_decal_chance, float p_gravity, float p_drag, bool p_fade_shrink) {
	if ((int)droplets.size() >= max_droplets) {
		droplets.erase(droplets.begin());
	}
	droplets.push_back({ p_pos, p_vel, p_size, 0.0f, p_life, p_gravity, p_drag, p_decal_chance, p_fade_shrink, p_color });
}

void BiterGoreNative::add_gib(int p_kind, const Vector3 &p_pos, const Vector3 &p_vel, const Quaternion &p_quat, const Vector3 &p_ang,
		const Vector3 &p_size, const Color &p_color) {
	if ((int)gibs.size() >= max_gibs) {
		gibs.erase(gibs.begin());
	}
	gibs.push_back({ p_kind, p_pos, p_vel, p_ang, p_size, p_quat, p_color, 0.0f, 0, false });
}

int BiterGoreNative::begin(double p_dt) {
	const float dt = (float)p_dt;
	last_dt = dt;
	droplet_samples = (int)droplets.size();
	gib_sample.clear();
	for (Droplet &d : droplets) {
		d.age += dt;
		d.vel.y += d.gravity * dt;
		if (d.drag > 0.0f) {
			d.vel *= std::max(0.0f, 1.0f - d.drag * dt);
		}
		d.pos += d.vel * dt;
	}
	// Expired gibs go; the rest in flight move. Order is kept.
	size_t w = 0;
	for (size_t r = 0; r < gibs.size(); r++) {
		Gib g = gibs[r];
		g.age += dt;
		if (g.age >= GIB_LIFE + GIB_FADE) {
			continue;
		}
		if (!g.settled) {
			g.vel.y += GRAVITY * dt;
			g.pos += g.vel * dt;
			gib_sample.push_back((int)w);
		}
		gibs[w++] = g;
	}
	gibs.resize(w);
	int n = droplet_samples + (int)gib_sample.size();
	sample_buf.resize((int64_t)n * 2);
	float *s = sample_buf.ptrw();
	for (int i = 0; i < droplet_samples; i++) {
		s[i * 2] = droplets[i].pos.x;
		s[i * 2 + 1] = droplets[i].pos.z;
	}
	for (size_t j = 0; j < gib_sample.size(); j++) {
		const Gib &g = gibs[gib_sample[j]];
		s[(droplet_samples + j) * 2] = g.pos.x;
		s[(droplet_samples + j) * 2 + 1] = g.pos.z;
	}
	return n;
}

PackedFloat32Array BiterGoreNative::finish(const PackedFloat32Array &p_heights, double p_blood_amount) {
	PackedFloat32Array ev;
	const float blood = (float)p_blood_amount;
	const float *h = p_heights.ptr();
	const int64_t hn = p_heights.size();
	auto push = [&](float kind, float x, float y, float z, float size, float stretch, float yaw, const Color &c) {
		int64_t at = ev.size();
		ev.resize(at + EV);
		float *e = ev.ptrw() + at;
		e[0] = kind; e[1] = x; e[2] = y; e[3] = z; e[4] = size; e[5] = stretch; e[6] = yaw;
		e[7] = c.r; e[8] = c.g; e[9] = c.b; e[10] = c.a;
	};
	const float nan = std::numeric_limits<float>::quiet_NaN();

	// Droplets: a landing or the end of life removes one; a landing may leave a decal.
	size_t w = 0;
	for (int i = 0; i < droplet_samples; i++) {
		Droplet &d = droplets[i];
		float gh = i < hn ? h[i] : 0.0f;
		if (d.pos.y <= gh || d.age >= d.life) {
			if (d.pos.y <= gh && randf() < d.decal_chance) {
				float sz = d.size * (0.28f + randf() * 0.24f);
				float hl2 = d.vel.x * d.vel.x + d.vel.z * d.vel.z;
				float stretch = std::clamp(1.0f + std::sqrt(hl2) * 0.14f, 1.0f, 2.2f);
				float yaw = hl2 > 0.04f ? std::atan2(d.vel.x, d.vel.z) : nan;
				push(0.0f, d.pos.x, gh, d.pos.z, sz, stretch, yaw, d.color);
			}
			continue;
		}
		droplets[w++] = d;
	}
	droplets.resize(w);
	fill_droplets();

	// Gibs in flight: floor, bounce, spin.
	for (size_t j = 0; j < gib_sample.size(); j++) {
		Gib &g = gibs[gib_sample[j]];
		float gh = (droplet_samples + (int64_t)j) < hn ? h[droplet_samples + j] : 0.0f;
		const Vector3 &sz = g.size;
		float rest_h = std::clamp(std::min(sz.x, std::min(sz.y, sz.z)) * 0.36f, 0.025f, 0.14f);
		float floor_y = gh + rest_h;
		if (g.pos.y <= floor_y) {
			g.pos.y = floor_y;
			int bounces = g.bounces;
			if (g.kind == KIND_MEAT && bounces == 0 && std::fabs(g.vel.y) > 1.4f && blood > 0.001f) {
				float smear = std::clamp(std::max(sz.x, sz.z) * 1.45f * std::clamp(0.5f + 0.5f * blood, 0.4f, 1.5f), 0.22f, 0.52f);
				float hl2 = g.vel.x * g.vel.x + g.vel.z * g.vel.z;
				push(1.0f, g.pos.x, gh, g.pos.z, smear, 1.45f, hl2 > 0.04f ? std::atan2(g.vel.x, g.vel.z) : nan, Color(0, 0, 0, 0));
			}
			float bounce_e = g.kind == KIND_MEAT ? 0.20f : (g.kind == KIND_SPIKE ? 0.34f : 0.30f);
			float h_fric = g.kind == KIND_MEAT ? 0.42f : (g.kind == KIND_SPIKE ? 0.54f : 0.50f);
			float a_damp = g.kind == KIND_MEAT ? 0.40f : 0.48f;
			g.vel.y = -g.vel.y * bounce_e;
			g.vel.x *= h_fric;
			g.vel.z *= h_fric;
			g.ang *= a_damp;
			g.bounces = bounces + 1;
			if (bounces >= 2 || g.vel.length_squared() < 0.35f) {
				g.vel = Vector3();
				g.ang = Vector3();
				g.settled = true;
			}
		}
		float ang_spd = g.ang.length();
		if (ang_spd > 0.001f) {
			g.quat = (Quaternion(g.ang / ang_spd, std::min(ang_spd * last_dt, 0.9f)) * g.quat).normalized();
		}
	}
	fill_gibs();
	return ev;
}

void BiterGoreNative::fill_droplets() {
	float *buf = droplet_buf.ptrw();
	int count = std::min((int)droplets.size(), max_droplets);
	for (int k = 0; k < count; k++) {
		const Droplet &d = droplets[k];
		float sz = d.size;
		if (d.fade_shrink) {
			float lf = std::clamp(d.age / std::max(d.life, 0.05f), 0.0f, 1.0f);
			sz *= (1.0f - lf * 0.85f);
		}
		float spd = d.vel.length();
		float *o = buf + (int64_t)k * STRIDE;
		if (spd > 0.25f) {
			Vector3 fwd = d.vel / spd;
			Vector3 up = std::fabs(fwd.y) < 0.95f ? Vector3(0, 1, 0) : Vector3(1, 0, 0);
			Vector3 right = up.cross(fwd).normalized();
			Vector3 ortho_up = fwd.cross(right).normalized();
			float stretch = std::clamp(1.0f + spd * 0.18f, 1.0f, 3.2f);
			put_cols(o, right * sz, ortho_up * sz, fwd * (sz * stretch), d.pos);
		} else {
			put_cols(o, Vector3(sz, 0, 0), Vector3(0, sz, 0), Vector3(0, 0, sz), d.pos);
		}
		put_color(o, d.color);
	}
	droplet_n = count;
}

void BiterGoreNative::fill_gibs() {
	int n[3] = { 0, 0, 0 };
	float *buf[3] = { gib_buf[0].ptrw(), gib_buf[1].ptrw(), gib_buf[2].ptrw() };
	for (const Gib &g : gibs) {
		int k = g.kind == KIND_MEAT ? 1 : (g.kind == KIND_SPIKE ? 2 : 0);
		if (n[k] >= max_gibs) {
			continue;
		}
		float shrink = 1.0f;
		if (g.age > GIB_LIFE) {
			float t = std::clamp(1.0f - (g.age - GIB_LIFE) / GIB_FADE, 0.0f, 1.0f);
			shrink = t * t * (3.0f - 2.0f * t);
		}
		// Basis(quat).scaled(size * shrink): the rotation's rows scaled.
		Basis b(g.quat);
		Vector3 s = g.size * shrink;
		float *o = buf[k] + (int64_t)n[k] * STRIDE;
		for (int r = 0; r < 3; r++) {
			o[r * 4 + 0] = b.rows[r][0] * s[r];
			o[r * 4 + 1] = b.rows[r][1] * s[r];
			o[r * 4 + 2] = b.rows[r][2] * s[r];
			o[r * 4 + 3] = g.pos[r];
		}
		put_color(o, g.color);
		n[k]++;
	}
	for (int k = 0; k < 3; k++) {
		gib_n[k] = n[k];
	}
}

void BiterGoreNative::set_decal(int p_idx, const Transform3D &p_xf, const Color &p_color) {
	if (p_idx < 0 || p_idx >= max_decals) {
		return;
	}
	Decal &d = decals[p_idx];
	d.color = p_color;
	d.age = 0.0f;
	d.alive = true;
	float *o = decal_buf.ptrw() + (int64_t)p_idx * STRIDE;
	const Basis &b = p_xf.basis;
	for (int r = 0; r < 3; r++) {
		o[r * 4 + 0] = b.rows[r][0];
		o[r * 4 + 1] = b.rows[r][1];
		o[r * 4 + 2] = b.rows[r][2];
		o[r * 4 + 3] = p_xf.origin[r];
	}
	put_color(o, p_color);
	decal_dirty = true;
}

int BiterGoreNative::step_decals(double p_dt, double p_life, double p_fade, int p_count) {
	bool any_alive = false;
	bool changed = decal_dirty;
	decal_dirty = false;
	float *buf = decal_buf.ptrw();
	int n = std::min(p_count, max_decals);
	for (int idx = 0; idx < n; idx++) {
		Decal &d = decals[idx];
		if (!d.alive) {
			continue;
		}
		d.age += (float)p_dt;
		float *o = buf + (int64_t)idx * STRIDE;
		if (d.age >= p_life + p_fade) {
			d.alive = false;
			for (int i = 0; i < 12; i++) {
				o[i] = 0.0f;
			}
			changed = true;
		} else if (d.age > p_life) {
			any_alive = true;
			o[15] = std::clamp(1.0f - (d.age - (float)p_life) / (float)p_fade, 0.0f, 1.0f);
			changed = true;
		} else {
			any_alive = true;
		}
	}
	if (!any_alive) {
		return changed ? 3 : 0;
	}
	return changed ? 2 : 1;
}

void BiterGoreNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("setup", "max_droplets", "max_decals", "max_gibs"), &BiterGoreNative::setup);
	ClassDB::bind_method(D_METHOD("clear"), &BiterGoreNative::clear);
	ClassDB::bind_method(D_METHOD("set_seed", "seed"), &BiterGoreNative::set_seed);
	ClassDB::bind_method(D_METHOD("add_droplet", "pos", "vel", "size", "life", "color", "decal_chance", "gravity", "drag", "fade_shrink"), &BiterGoreNative::add_droplet);
	ClassDB::bind_method(D_METHOD("add_gib", "kind", "pos", "vel", "quat", "ang", "size", "color"), &BiterGoreNative::add_gib);
	ClassDB::bind_method(D_METHOD("droplet_count"), &BiterGoreNative::droplet_count);
	ClassDB::bind_method(D_METHOD("gib_count"), &BiterGoreNative::gib_count);
	ClassDB::bind_method(D_METHOD("begin", "dt"), &BiterGoreNative::begin);
	ClassDB::bind_method(D_METHOD("sample_xz"), &BiterGoreNative::sample_xz);
	ClassDB::bind_method(D_METHOD("finish", "heights", "blood_amount"), &BiterGoreNative::finish);
	ClassDB::bind_method(D_METHOD("sync_gibs"), &BiterGoreNative::sync_gibs);
	ClassDB::bind_method(D_METHOD("droplet_buffer"), &BiterGoreNative::droplet_buffer);
	ClassDB::bind_method(D_METHOD("droplet_visible"), &BiterGoreNative::droplet_visible);
	ClassDB::bind_method(D_METHOD("gib_buffer", "kind"), &BiterGoreNative::gib_buffer);
	ClassDB::bind_method(D_METHOD("gib_visible", "kind"), &BiterGoreNative::gib_visible);
	ClassDB::bind_method(D_METHOD("set_decal", "idx", "xf", "color"), &BiterGoreNative::set_decal);
	ClassDB::bind_method(D_METHOD("step_decals", "dt", "life", "fade", "count"), &BiterGoreNative::step_decals);
	ClassDB::bind_method(D_METHOD("decal_buffer"), &BiterGoreNative::decal_buffer);
}
