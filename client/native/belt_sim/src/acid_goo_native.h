#pragma once
// SPDX-License-Identifier: GPL-3.0-or-later
// Native twin of the per-particle loops in the Immersive Enemies add-on's scripts/acid_goo.gd: the flying globs,
// droplets, splash crowns, mist wisps and ground pools are kept here as plain arrays, stepped and written into
// the five MultiMesh instance buffers (16 floats an instance: transform, then colour or custom data) in one call.
// Randomness, ground heights, sounds and node/material setup stay in GDScript: step() reports what needs them
// (trail drops, landings, drops that ended, pools whose bubble/mist timer ran out) as arrays, and the script
// adds the new particles back with add_*(). The GDScript path stays the fallback (--enemies-native=off).

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <vector>

namespace godot {

class AcidGooNative : public RefCounted {
	GDCLASS(AcidGooNative, RefCounted)

public:
	enum Group { GLOBS = 0, DROPS = 1, RINGS = 2, MIST = 3, POOLS = 4, GROUPS = 5 };
	static constexpr int STRIDE = 16;

	struct Glob {
		float from[3], to[3], dur, age, arc_h, scale, tier, seed, trail_cd, col[4];
		bool primary;
	};
	struct Drop {
		float pos[3], vel[3], size, age, life, col[4];
		bool make_mist;
	};
	struct Ring {
		float pos[3], basis[9], scale, age, life, col[4];
	};
	struct Mist {
		float pos[3], vel[3], size, age, life, col[4], base_alpha, yaw, spin;
	};
	struct Pool {
		int id;
		float pos[3], basis[9], radius, age, fade_in, fade_out, gone, seed, pulse, bubble_cd, mist_cd;
	};

	// Capacities (the script's MAX_*): each add_* drops the oldest when full, as the GDScript's pop_front.
	void set_caps(int p_globs, int p_drops, int p_rings, int p_mist, int p_pools);

	void add_glob(const Vector3 &p_from, const Vector3 &p_to, double p_dur, double p_age, double p_arc_h, double p_scale,
			double p_tier, bool p_primary, double p_seed, double p_trail_cd, const Color &p_color);
	void add_drop(const Vector3 &p_pos, const Vector3 &p_vel, double p_size, double p_life, const Color &p_color, bool p_make_mist);
	void add_ring(const Vector3 &p_pos, const Basis &p_basis, double p_scale, double p_life, const Color &p_color);
	void add_mist(const Vector3 &p_pos, const Vector3 &p_vel, double p_size, double p_life, const Color &p_color, double p_yaw, double p_spin);
	void set_pool(int p_id, const Vector3 &p_pos, const Basis &p_basis, double p_radius, double p_fade_in, double p_fade_out,
			double p_seed, double p_pulse, double p_bubble_cd, double p_mist_cd);
	void end_pool(int p_id);
	bool has_pool(int p_id) const;
	// kind 0: bubble timer, 1: mist timer.
	void set_pool_cd(int p_id, int p_kind, double p_value);
	void clear();
	void clear_pools();

	// Drops' x, z (pairs), for the script to read ground heights where there are hills.
	PackedFloat32Array drop_xz() const;
	// drop_gh: one ground height per drop in drop order (empty = flat ground, 0). Returns the event count.
	int step(double p_dt, const PackedFloat32Array &p_drop_gh);

	// Instance buffer of a group (capacity * 16 floats), valid for counts()[group] instances.
	PackedFloat32Array buffer(int p_group) const;
	PackedInt32Array counts() const;
	// 7 floats each: x, y, z of the target, tier scale, primary (0/1), then 2 spare.
	PackedFloat32Array landed() const { return ev_landed; }
	// 12 floats each: pos xyz, vel xyz, scale, primary, 4 spare.
	PackedFloat32Array trails() const { return ev_trails; }
	// 5 floats each: x, ground y, z, size, wants a mist roll (0/1).
	PackedFloat32Array drop_ends() const { return ev_drop_ends; }
	// 6 floats each: pool id, kind (0 bubble, 1 mist), pos xyz, radius.
	PackedFloat32Array pool_fires() const { return ev_pool_fires; }
	// globs, drops, rings, mist, pools alive.
	PackedInt32Array sizes() const;

protected:
	static void _bind_methods();

private:
	int cap[GROUPS] = { 160, 320, 32, 96, 96 };
	std::vector<Glob> globs;
	std::vector<Drop> drops;
	std::vector<Ring> rings;
	std::vector<Mist> mist;
	std::vector<Pool> pools;
	PackedFloat32Array buf[GROUPS];
	int vis[GROUPS] = { 0, 0, 0, 0, 0 };
	PackedFloat32Array ev_landed, ev_trails, ev_drop_ends, ev_pool_fires;

	void size_buffers();
};

} // namespace godot
