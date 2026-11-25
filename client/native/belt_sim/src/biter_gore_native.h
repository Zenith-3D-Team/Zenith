#pragma once
// SPDX-License-Identifier: GPL-3.0-or-later
// Native twin of the per-frame loops in addons-src/immersive-enemies/scripts/biter_gore.gd: ballistic droplets,
// the decal ring's ageing and fade, and bouncing gibs, each with its MultiMesh buffer filled in one go.
// The object owns the particle state in packed vectors. Ground heights stay with the GDScript (the height
// field lives there): begin() integrates and lists the points to sample, the script reads the heights into
// one array, finish() resolves the landings and fills the buffers. Spawning, decal placement (it needs the
// ground normal) and materials stay GDScript. The GDScript stays the fallback (--enemies-native=off).

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <vector>

namespace godot {

class BiterGoreNative : public RefCounted {
	GDCLASS(BiterGoreNative, RefCounted)

	struct Droplet {
		Vector3 pos, vel;
		float size, age, life, gravity, drag, decal_chance;
		bool fade_shrink;
		Color color;
	};
	struct Gib {
		int kind;
		Vector3 pos, vel, ang, size;
		Quaternion quat;
		Color color;
		float age;
		int bounces;
		bool settled;
	};
	struct Decal {
		Color color;
		float age = 0.0f;
		bool alive = false;
	};

	int max_droplets = 512, max_decals = 600, max_gibs = 192;
	std::vector<Droplet> droplets;
	std::vector<Gib> gibs;
	std::vector<Decal> decals;
	PackedFloat32Array droplet_buf, decal_buf, gib_buf[3];
	int droplet_n = 0, gib_n[3] = { 0, 0, 0 };
	bool decal_dirty = false;
	PackedFloat32Array sample_buf;
	std::vector<int> gib_sample; // gib index of each gib sample point
	int droplet_samples = 0;
	float last_dt = 0.0f;
	uint64_t rng_state = 0x9E3779B97F4A7C15ULL;

	float randf();
	void fill_droplets();
	void fill_gibs();

public:
	void setup(int p_max_droplets, int p_max_decals, int p_max_gibs);
	void clear();
	void set_seed(int64_t p_seed);

	void add_droplet(const Vector3 &p_pos, const Vector3 &p_vel, float p_size, float p_life, const Color &p_color,
			float p_decal_chance, float p_gravity, float p_drag, bool p_fade_shrink);
	void add_gib(int p_kind, const Vector3 &p_pos, const Vector3 &p_vel, const Quaternion &p_quat, const Vector3 &p_ang,
			const Vector3 &p_size, const Color &p_color);
	int droplet_count() const { return (int)droplets.size(); }
	int gib_count() const { return (int)gibs.size(); }

	// Ages and moves the droplets and the gibs in flight; drops expired gibs. Returns the sample points'
	// number; sample_xz() holds their (x, z) pairs, droplets first.
	int begin(double p_dt);
	PackedFloat32Array sample_xz() const { return sample_buf; }
	// heights: the ground under each sample point. Resolves landings and bounces, fills the droplet and gib
	// buffers. Returns decal events, 11 floats each: kind (0 droplet landing, 1 gib smear), x, ground y, z,
	// size, stretch, yaw (NaN: pick one), r, g, b, a.
	PackedFloat32Array finish(const PackedFloat32Array &p_heights, double p_blood_amount);
	// Writes the gib buffers (after a spawn, with no step).
	void sync_gibs() { fill_gibs(); }

	PackedFloat32Array droplet_buffer() const { return droplet_buf; }
	int droplet_visible() const { return droplet_n; }
	PackedFloat32Array gib_buffer(int p_kind) const { return gib_buf[p_kind]; }
	int gib_visible(int p_kind) const { return gib_n[p_kind]; }

	void set_decal(int p_idx, const Transform3D &p_xf, const Color &p_color);
	// 0: none alive, nothing changed; 1: alive, nothing changed; 2: alive and the buffer changed;
	// 3: none alive left, the buffer changed.
	int step_decals(double p_dt, double p_life, double p_fade, int p_count);
	PackedFloat32Array decal_buffer() const { return decal_buf; }

protected:
	static void _bind_methods();
};

} // namespace godot
