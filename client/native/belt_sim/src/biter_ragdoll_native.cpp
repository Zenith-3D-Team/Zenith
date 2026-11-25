#include "biter_ragdoll_native.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

namespace {
constexpr float SEVERED_SENTINEL = 100.0f;
inline float clampf_(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }
} // namespace

void BiterRagdollNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("make_state", "swing", "swing_v", "lift", "lift_v", "knee", "knee_v", "twists", "twists_v"),
			&BiterRagdollNative::make_state);
	ClassDB::bind_method(D_METHOD("step_limbs", "state", "severed", "limb_count", "dt", "lin_acc", "ang", "quat", "normal",
								 "grounded", "bounce_kick"),
			&BiterRagdollNative::step_limbs);
	ClassDB::bind_method(D_METHOD("last_limbs"), &BiterRagdollNative::last_limbs);
	ClassDB::bind_method(D_METHOD("last_twists"), &BiterRagdollNative::last_twists);
	ClassDB::bind_method(D_METHOD("separate", "data", "count", "dt"), &BiterRagdollNative::separate);
}

PackedFloat32Array BiterRagdollNative::make_state(const PackedFloat32Array &p_swing, const PackedFloat32Array &p_swing_v,
		const PackedFloat32Array &p_lift, const PackedFloat32Array &p_lift_v, const PackedFloat32Array &p_knee,
		const PackedFloat32Array &p_knee_v, const PackedFloat32Array &p_twists, const PackedFloat32Array &p_twists_v) {
	int n = (int)p_swing.size();
	n = std::min({ n, (int)p_swing_v.size(), (int)p_lift.size(), (int)p_lift_v.size(), (int)p_knee.size(),
			(int)p_knee_v.size(), (int)p_twists.size(), (int)p_twists_v.size() });
	PackedFloat32Array out;
	out.resize((int64_t)n * LS);
	float *o = out.ptrw();
	for (int i = 0; i < n; i++) {
		o[i * LS + 0] = p_swing[i];
		o[i * LS + 1] = p_swing_v[i];
		o[i * LS + 2] = p_lift[i];
		o[i * LS + 3] = p_lift_v[i];
		o[i * LS + 4] = p_knee[i];
		o[i * LS + 5] = p_knee_v[i];
		o[i * LS + 6] = p_twists[i];
		o[i * LS + 7] = p_twists_v[i];
	}
	return out;
}

PackedFloat32Array BiterRagdollNative::step_limbs(const PackedFloat32Array &p_state, const PackedByteArray &p_severed,
		int p_limb_count, double p_dt, const Vector3 &p_lin_acc, const Vector3 &p_ang, const Quaternion &p_quat,
		const Vector3 &p_normal, bool p_grounded, double p_bounce_kick) {
	PackedFloat32Array state = p_state;
	int n = std::min({ p_limb_count, (int)(state.size() / LS), (int)p_severed.size() });
	if (n < 0) {
		n = 0;
	}
	out_limbs.resize(n);
	out_twists.resize(n);
	float *s = state.ptrw();
	Vector3 *ol = out_limbs.ptrw();
	float *ot = out_twists.ptrw();
	const uint8_t *sev = p_severed.ptr();

	const float dt = (float)p_dt;
	const float bounce_kick = (float)p_bounce_kick;
	const bool is_spitter = n > 6;

	Quaternion inv_q = p_quat.inverse();
	Vector3 local_acc = inv_q.xform(p_lin_acc);
	Vector3 local_ang = inv_q.xform(p_ang);
	Vector3 local_grav = inv_q.xform(Vector3(0.0f, -1.0f, 0.0f));
	float up_dot = p_quat.xform(Vector3(0.0f, 1.0f, 0.0f)).dot(p_normal);

	const float stiffness = p_grounded ? 4.5f : 2.2f;
	const float damping = p_grounded ? 4.2f : 2.0f;

	for (int i = 0; i < n; i++) {
		float *l = s + i * LS;
		if (sev[i] != 0) {
			l[6] = SEVERED_SENTINEL;
			ol[i] = Vector3(l[0], l[2], l[4]);
			ot[i] = SEVERED_SENTINEL;
			continue;
		}
		float side;
		int pair_idx;
		float fore_bias;
		if (is_spitter) {
			side = i < 6 ? -1.0f : 1.0f;
			pair_idx = i % 6;
			fore_bias = (2.5f - (float)pair_idx) * 0.16f;
		} else {
			side = (i % 2) == 0 ? -1.0f : 1.0f;
			pair_idx = i / 2;
			fore_bias = (1.0f - (float)pair_idx) * 0.35f;
		}

		float t_swing = fore_bias + local_grav.z * 0.9f;
		float t_lift = -local_grav.y * 0.85f + local_grav.x * side * 0.75f;
		float t_knee = 0.0f;
		float t_twist = local_grav.z * side * 0.45f;
		if (p_grounded) {
			if (up_dot >= 0.0f) {
				t_lift += 0.45f + (float)pair_idx * (is_spitter ? 0.06f : 0.12f);
				t_knee = -0.45f;
			} else {
				t_lift -= 0.55f;
				t_knee = 1.05f;
			}
		} else {
			t_knee = clampf_(-local_grav.y * 0.65f, -1.4f, 1.4f);
		}

		float acc_swing = stiffness * (t_swing - l[0]) - damping * l[1];
		acc_swing += clampf_(-local_acc.z * 0.16f + local_ang.y * side * 1.4f, -26.0f, 26.0f);

		float acc_lift = stiffness * (t_lift - l[2]) - damping * l[3];
		acc_lift += clampf_(-local_acc.y * 0.16f + local_ang.z * side * 1.3f + bounce_kick * 1.5f, -28.0f, 28.0f);

		float acc_knee = stiffness * (t_knee - l[4]) - damping * l[5];
		acc_knee += clampf_(local_acc.x * side * 0.15f + local_ang.x * 1.2f - bounce_kick * 0.9f, -26.0f, 26.0f);

		float acc_twist = stiffness * (t_twist - l[6]) - damping * l[7];
		acc_twist += clampf_(local_ang.y * 0.9f + local_ang.z * side * 0.75f + bounce_kick * side * 0.6f, -24.0f, 24.0f);

		l[1] += acc_swing * dt;
		l[3] += acc_lift * dt;
		l[5] += acc_knee * dt;
		l[7] += acc_twist * dt;

		l[0] = clampf_(l[0] + l[1] * dt, -2.3f, 2.3f);
		l[2] = clampf_(l[2] + l[3] * dt, -2.0f, 2.0f);
		l[4] = clampf_(l[4] + l[5] * dt, -2.1f, 2.1f);
		l[6] = clampf_(l[6] + l[7] * dt, -1.8f, 1.8f);

		ol[i] = Vector3(l[0], l[2], l[4]);
		ot[i] = l[6];
	}
	return state;
}

PackedFloat32Array BiterRagdollNative::separate(const PackedFloat32Array &p_data, int p_count, double p_dt) {
	PackedFloat32Array data = p_data;
	int n = std::min(p_count, (int)(data.size() / SEP));
	float *d = data.ptrw();
	const float dt = (float)p_dt;
	for (int i = 0; i < n; i++) {
		float *bi = d + i * SEP;
		for (int j = i + 1; j < n; j++) {
			float *bj = d + j * SEP;
			float min_d = bi[3] + bj[3];
			float dx = bj[0] - bi[0];
			float dz = bj[2] - bi[2];
			float d2 = dx * dx + dz * dz;
			if (d2 > 0.00001f && d2 < min_d * min_d) {
				float dist = std::sqrt(d2);
				float nx = dx / dist;
				float nz = dz / dist;
				float overlap = (min_d - dist) * 0.5f;
				float push = std::min(overlap * 6.0f, 2.5f) * dt;
				bi[0] -= nx * (overlap * 0.35f);
				bi[2] -= nz * (overlap * 0.35f);
				bj[0] += nx * (overlap * 0.35f);
				bj[2] += nz * (overlap * 0.35f);
				bi[4] -= nx * push;
				bi[6] -= nz * push;
				bj[4] += nx * push;
				bj[6] += nz * push;
			}
		}
	}
	return data;
}
