#include "inserter_arms_native.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <algorithm>
#include <cmath>
#include <limits>

using namespace godot;

namespace {

const Vector3 RIGHT(1, 0, 0);
const Vector3 UP(0, 1, 0);
const Vector3 BACK(0, 0, 1);

// One MultiMesh buffer being filled: `stride` floats an instance.
struct Out {
	PackedFloat32Array buf;
	float *p = nullptr;
	int stride = 12;
	int n = 0;

	void init(int cap, int max_n, int s) {
		stride = s;
		buf.resize((int64_t)std::max(cap, max_n) * s);
		p = buf.ptrw();
	}
	void xf(const Basis &b, const Vector3 &o) {
		float *q = p + (int64_t)n * stride;
		q[0] = b.rows[0][0];
		q[1] = b.rows[0][1];
		q[2] = b.rows[0][2];
		q[3] = o.x;
		q[4] = b.rows[1][0];
		q[5] = b.rows[1][1];
		q[6] = b.rows[1][2];
		q[7] = o.y;
		q[8] = b.rows[2][0];
		q[9] = b.rows[2][1];
		q[10] = b.rows[2][2];
		q[11] = o.z;
	}
	void push(const Basis &b, const Vector3 &o) {
		xf(b, o);
		n++;
	}
	void push_color(const Basis &b, const Vector3 &o, float r, float g, float bl, float a) {
		xf(b, o);
		float *q = p + (int64_t)n * stride;
		q[12] = r;
		q[13] = g;
		q[14] = bl;
		q[15] = a;
		n++;
	}
};

int cap_of(const PackedInt32Array &caps, int i) {
	return i < caps.size() ? caps[i] : 0;
}

// _elbow: two-bone IK in the arm's vertical plane, bending upwards.
Vector3 elbow_of(const Vector3 &shoulder, const Vector3 &wrist, const Vector3 &out, double upper, double fore) {
	Vector3 to_wrist = wrist - shoulder;
	double d = std::clamp((double)to_wrist.length(), 0.05, upper + fore - 0.001);
	double horizontal = (double)to_wrist.x * out.x + (double)to_wrist.z * out.z;
	double dir_angle = std::atan2((double)to_wrist.y, horizontal);
	double cos_a = (upper * upper + d * d - fore * fore) / (2.0 * upper * d);
	double lift = dir_angle + std::acos(std::clamp(cos_a, -1.0, 1.0));
	return shoulder + out * (real_t)(std::cos(lift) * upper) + UP * (real_t)(std::sin(lift) * upper);
}

// _piece: a model piece from joint a to b, stretched from its modelled `length`.
void piece_of(const Vector3 &a, const Vector3 &b, const Basis &turn, double length, Basis &bs, Vector3 &o) {
	Vector3 along = b - a;
	double d = std::max((double)along.length(), 0.01);
	Vector3 z = -along / (real_t)d;
	Vector3 x = turn.xform(BACK);
	Vector3 y = z.cross(x).normalized();
	if (y.y < 0.0f) {
		y = -y;
	}
	x = y.cross(z).normalized();
	bs = Basis(x, y, z * (real_t)(d / length));
	o = a - y * 0.05f;
}

// _segment: a box from a to b, `thickness` square, turned with the arm.
void segment_of(const Vector3 &a, const Vector3 &b, const Basis &turn, double thickness, Basis &bs, Vector3 &o) {
	Vector3 along = b - a;
	double length = std::max((double)along.length(), 0.01);
	Vector3 x = along / (real_t)length;
	Vector3 z = turn.xform(BACK);
	Vector3 y = z.cross(x).normalized();
	z = x.cross(y);
	bs = Basis(x * (real_t)length, y * (real_t)thickness, z * (real_t)thickness);
	o = (a + b) * 0.5f;
}

// _across / _card_xf / _on_card (sprite cards).
Vector3 across_of(const Vector3 &along, const Vector3 &facing) {
	Vector3 a = along.cross(facing);
	return a.length() > 1e-5f ? a.normalized() : RIGHT;
}

void card_xf(const Vector3 &a, const Vector3 &b, double width, const Vector3 &facing, double depth, Basis &bs, Vector3 &o) {
	Vector3 along = b - a;
	if (along.length() < 0.01f) {
		along = Vector3(0.0f, 0.01f, 0.0f);
	}
	bs = Basis(across_of(along, facing) * (real_t)width, along, facing);
	o = (a + b) * 0.5f + facing * (real_t)depth;
}

Vector3 on_card(const Vector3 &p, const Vector3 &centre, const Vector3 &up) {
	Vector3 d = p - centre;
	return centre + Vector3(d.x, 0.0f, 0.0f) + up * d.dot(up);
}

// _frame / aim / along (rigs).
Basis frame_of(const Vector3 &dir, const Vector3 &hinge) {
	Vector3 y = dir.normalized();
	Vector3 z = (hinge - y * hinge.dot(y)).normalized();
	return Basis(y.cross(z), y, z);
}

Basis aim_of(const Vector3 &rest_dir, const Vector3 &rest_hinge, const Vector3 &dir, const Vector3 &hinge) {
	return frame_of(dir, hinge) * frame_of(rest_dir, rest_hinge).inverse();
}

Basis along_of(const Vector3 &dir, double s) {
	if (std::abs(s - 1.0) <= 1e-5 * std::max(1.0, std::abs(s))) { // is_equal_approx(s, 1.0)
		return Basis();
	}
	Vector3 d = dir.normalized();
	real_t k = (real_t)(s - 1.0);
	return Basis(RIGHT + d * (d.x * k), UP + d * (d.y * k), BACK + d * (d.z * k));
}

Vector3 vec3(const PackedFloat32Array &a, int i) {
	return Vector3(a[i], a[i + 1], a[i + 2]);
}

Array result(Out *outs, int count, const PackedFloat32Array &wr, const PackedFloat32Array &gr, bool gripped, double stretch) {
	Array pieces;
	PackedInt32Array counts;
	for (int i = 0; i < count; i++) {
		pieces.push_back(outs[i].buf);
		counts.push_back(outs[i].n);
	}
	Array r;
	r.push_back(pieces);
	r.push_back(counts);
	r.push_back(wr);
	r.push_back(gr);
	r.push_back(gripped);
	r.push_back(stretch);
	return r;
}

} // namespace

Array InserterArmsNative::sprite_arms(const PackedFloat32Array &inp, const PackedInt32Array &caps, const PackedFloat32Array &params) const {
	const int n = inp.size() / 6;
	Out outs[3];
	for (int i = 0; i < 3; i++) {
		outs[i].init(cap_of(caps, i), n, 12);
	}
	PackedFloat32Array wr, gr;
	wr.resize(n * 3);
	gr.resize(n * 3);
	float *w = wr.ptrw();
	float *g = gr.ptrw();
	const float *in = inp.ptr();
	const double grip_h = params[0], shoulder_h = params[1], upper_len = params[2], fore_len = params[3];
	const double stretch = params[4], claw_default = params[5], hand_tip = params[7];
	const double depth = params[8], hand_depth = params[9], drop = params[13];
	const double w_base = params[10];
	const double widths[3] = { params[10], params[11], params[12] };
	const double pitch = params[6] * (3.14159265358979323846 / 180.0);
	const Vector3 up(0.0f, (real_t)std::cos(pitch), (real_t)-std::sin(pitch));
	const Vector3 facing(0.0f, (real_t)std::sin(pitch), (real_t)std::cos(pitch));
	for (int i = 0; i < n; i++) {
		const float *a = in + i * 6;
		Vector3 base2(a[0], 0.0f, a[1]);
		Vector3 out_dir = Basis(UP, -a[2]).xform(RIGHT);
		Vector3 grip = Vector3(a[0], (real_t)grip_h, a[1]) + out_dir * a[3];
		int hand = a[4] > 0.5f ? 2 : 1;
		double lift = std::isnan(a[5]) ? 0.0 : a[5];
		// sprite_cards
		Vector3 shoulder(a[0], (real_t)shoulder_h, a[1]);
		Vector3 flat = grip - shoulder;
		Vector3 out = (std::sqrt((double)flat.x * flat.x + (double)flat.z * flat.z) > 0.001) ? Vector3(flat.x, 0.0f, flat.z).normalized() : RIGHT;
		Vector3 elbow = elbow_of(shoulder, grip, out, upper_len * stretch, fore_len * stretch * claw_default);
		Vector3 s = on_card(shoulder, base2, up);
		Vector3 e = on_card(elbow, base2, up);
		Vector3 gg = on_card(grip, base2, up);
		Vector3 tip = gg + (gg - e) * (real_t)(hand_tip / (1.0 - hand_tip));
		double low = std::numeric_limits<double>::infinity();
		const Vector3 *ends[2][2] = { { &s, &e }, { &e, &tip } };
		const double pw[2] = { widths[0], widths[hand] };
		for (int k = 0; k < 2; k++) {
			Vector3 across = across_of(*ends[k][1] - *ends[k][0], facing) * (real_t)(pw[k] * 0.5);
			for (int m = 0; m < 2; m++) {
				const Vector3 &end = *ends[k][m];
				low = std::min(low, (double)std::min((end + across).y, (end - across).y));
			}
		}
		double d = std::max(lift, (0.02 - low) / std::sin(pitch));
		Basis b0, b1;
		Vector3 o0, o1;
		card_xf(s, e, w_base, facing, d + depth, b0, o0);
		card_xf(e, tip, widths[hand], facing, d + hand_depth, b1, o1);
		outs[0].push(b0, o0);
		outs[hand].push(b1, o1);
		Vector3 wrist = grip + Vector3(0.0f, (real_t)drop, 0.0f);
		w[i * 3] = wrist.x;
		w[i * 3 + 1] = wrist.y;
		w[i * 3 + 2] = wrist.z;
		g[i * 3] = grip.x;
		g[i * 3 + 1] = grip.y;
		g[i * 3 + 2] = grip.z;
	}
	return result(outs, 3, wr, gr, true, 1.0);
}

Array InserterArmsNative::model_arms(const PackedFloat32Array &inp, const PackedInt32Array &caps, const PackedFloat32Array &params) const {
	const int n = inp.size() / 5;
	Out outs[3];
	for (int i = 0; i < 3; i++) {
		outs[i].init(cap_of(caps, i), n, 12);
	}
	PackedFloat32Array wr, gr;
	wr.resize(n * 3);
	gr.resize(n * 3);
	float *w = wr.ptrw();
	float *g = gr.ptrw();
	const float *in = inp.ptr();
	const double shoulder_h = params[0], hand_h = params[1], upper = params[2], fore = params[3];
	const double len0 = params[4], len1 = params[5], claw = params[8];
	const bool held_grip = params[6] > 0.5f;
	const double grip_h = params[7];
	for (int i = 0; i < n; i++) {
		const float *a = in + i * 5;
		Basis turn(UP, -a[2]);
		Vector3 out = turn.xform(RIGHT);
		Vector3 shoulder(a[0], (real_t)shoulder_h, a[1]);
		Vector3 wrist = Vector3(a[0], (real_t)hand_h, a[1]) + out * a[3];
		Vector3 elbow;
		Vector3 grip(0, 0, 0);
		if (held_grip) {
			grip = Vector3(a[0], (real_t)grip_h, a[1]) + out * a[3];
			elbow = elbow_of(shoulder, grip, out, upper, fore * claw);
			wrist = elbow + (grip - elbow) / (real_t)claw;
		} else {
			elbow = elbow_of(shoulder, wrist, out, upper, fore);
		}
		Basis bs;
		Vector3 o;
		piece_of(shoulder, elbow, turn, len0, bs, o);
		outs[0].push(bs, o);
		piece_of(elbow, wrist, turn, len1, bs, o);
		outs[a[4] > 0.5f ? 2 : 1].push(bs, o);
		w[i * 3] = wrist.x;
		w[i * 3 + 1] = wrist.y;
		w[i * 3 + 2] = wrist.z;
		g[i * 3] = grip.x;
		g[i * 3 + 1] = grip.y;
		g[i * 3 + 2] = grip.z;
	}
	return result(outs, 3, wr, gr, held_grip, 1.0);
}

Array InserterArmsNative::basic_arms(const PackedFloat32Array &inp, const PackedInt32Array &caps, const PackedFloat32Array &params) const {
	const int n = inp.size() / 8;
	Out outs[6];
	for (int i = 0; i < 6; i++) {
		outs[i].init(cap_of(caps, i), i == 5 ? n * 2 : n, 16);
	}
	PackedFloat32Array wr, gr;
	wr.resize(n * 3);
	gr.resize(n * 3);
	float *w = wr.ptrw();
	const float *in = inp.ptr();
	const double base_top = params[0], shoulder_h = params[1], hand_h = params[2], upper = params[3], fore = params[4];
	const Vector3 turntable = vec3(params, 5), post_size = vec3(params, 8), hand_size = vec3(params, 11), finger = vec3(params, 14);
	const double thickness = params[17];
	const float *steel = params.ptr() + 18;
	const float *dark = params.ptr() + 21;
	for (int i = 0; i < n; i++) {
		const float *a = in + i * 8;
		Basis turn(UP, -a[2]);
		Vector3 out = turn.xform(RIGHT);
		Vector3 shoulder(a[0], (real_t)shoulder_h, a[1]);
		Vector3 wrist = Vector3(a[0], (real_t)hand_h, a[1]) + out * a[3];
		Vector3 elbow = elbow_of(shoulder, wrist, out, upper, fore);
		float r = a[4], gg = a[5], b = a[6], al = a[7];
		double table_y = base_top + turntable.y * 0.5;
		outs[0].push_color(turn * Basis::from_scale(turntable), Vector3(a[0], (real_t)table_y, a[1]), r * 0.8f, gg * 0.8f, b * 0.8f, al);
		Vector3 post(post_size.x, (real_t)(shoulder_h - base_top), post_size.z);
		outs[1].push_color(turn * Basis::from_scale(post), Vector3(a[0], (real_t)((base_top + shoulder_h) * 0.5 + 0.02), a[1]), dark[0], dark[1], dark[2], 1.0f);
		Basis bs;
		Vector3 o;
		segment_of(shoulder, elbow, turn, thickness * 1.3, bs, o);
		outs[2].push_color(bs, o, r * 0.9f, gg * 0.9f, b * 0.9f, al);
		segment_of(elbow, wrist, turn, thickness, bs, o);
		outs[3].push_color(bs, o, steel[0], steel[1], steel[2], 1.0f);
		Vector3 hand_at = wrist + Vector3(0.0f, hand_size.y * 0.5f, 0.0f);
		outs[4].push_color(turn * Basis::from_scale(hand_size), hand_at, r * 0.65f, gg * 0.65f, b * 0.65f, al);
		Vector3 across = turn.xform(BACK);
		for (int sd = 0; sd < 2; sd++) {
			float side = sd == 0 ? -1.0f : 1.0f;
			Vector3 f = wrist + across * (side * (hand_size.z * 0.5f - finger.z * 0.5f)) - Vector3(0.0f, finger.y * 0.5f, 0.0f);
			outs[5].push_color(turn * Basis::from_scale(finger), f, dark[0], dark[1], dark[2], 1.0f);
		}
		w[i * 3] = wrist.x;
		w[i * 3 + 1] = wrist.y;
		w[i * 3 + 2] = wrist.z;
	}
	return result(outs, 6, wr, gr, false, 1.0);
}

Array InserterArmsNative::rig_arms(const PackedFloat32Array &inp, const PackedInt32Array &caps, const PackedFloat32Array &params) const {
	const int n = inp.size() / 17;
	Out outs[5];
	for (int i = 0; i < 5; i++) {
		outs[i].init(cap_of(caps, i), n, 12);
	}
	PackedFloat32Array wr, gr;
	wr.resize(n * 3);
	gr.resize(n * 3);
	float *w = wr.ptrw();
	float *g = gr.ptrw();
	const float *in = inp.ptr();
	const Vector3 hinge = vec3(params, 0), pivot_rest = vec3(params, 3), shoulder_rest = vec3(params, 6);
	const Vector3 elbow_rest = vec3(params, 9), grip_rest = vec3(params, 12);
	const double upper = params[15], fore = params[16], grip_h = params[18], drop = params[19], reach_k = params[20];
	const bool held_grip = params[17] > 0.5f, has_table = params[21] > 0.5f;
	struct Pincer {
		bool present;
		Vector3 head, axis;
		double angle;
	} pincers[2];
	for (int k = 0; k < 2; k++) {
		int o = 22 + k * 8;
		pincers[k] = { params[o] > 0.5f, vec3(params, o + 1), vec3(params, o + 4), params[o + 7] };
	}
	const Vector3 lower_dir = elbow_rest - shoulder_rest;
	const Vector3 upper_dir = grip_rest - elbow_rest;
	double max_stretch = 1.0;
	for (int i = 0; i < n; i++) {
		const float *a = in + i * 17;
		Basis turn(UP, -a[2]);
		Vector3 out = turn.xform(RIGHT);
		Vector3 across = turn.xform(BACK);
		Basis table = aim_of(UP, hinge, UP, across);
		Basis placed_b(Vector3(a[5], a[6], a[7]), Vector3(a[8], a[9], a[10]), Vector3(a[11], a[12], a[13]));
		Vector3 placed_o(a[14], a[15], a[16]);
		Vector3 pivot = placed_b.xform(pivot_rest) + placed_o;
		Vector3 shoulder = pivot + table.xform(shoulder_rest - pivot_rest);
		Vector3 grip = Vector3(a[0], (real_t)grip_h, a[1]) + out * a[3];
		double stretch = 1.0;
		double need = shoulder.distance_to(grip);
		if (need > (upper + fore) * reach_k) {
			stretch = need / ((upper + fore) * reach_k);
			max_stretch = std::max(max_stretch, stretch);
		}
		Vector3 elbow = elbow_of(shoulder, grip, out, upper * stretch, fore * stretch);
		Basis lower_turn = aim_of(lower_dir, hinge, elbow - shoulder, across) * along_of(lower_dir, stretch);
		Basis upper_turn = aim_of(upper_dir, hinge, grip - elbow, across) * along_of(upper_dir, stretch);
		if (has_table) {
			outs[0].push(table, pivot);
		}
		outs[1].push(lower_turn, shoulder);
		outs[2].push(upper_turn, elbow);
		for (int k = 0; k < 2; k++) {
			if (!pincers[k].present) {
				continue;
			}
			Basis shut(pincers[k].axis, (real_t)(pincers[k].angle * a[4]));
			outs[3 + k].push(upper_turn * shut, elbow + upper_turn.xform(pincers[k].head - elbow_rest));
		}
		Vector3 wrist = grip + Vector3(0.0f, (real_t)drop, 0.0f);
		w[i * 3] = wrist.x;
		w[i * 3 + 1] = wrist.y;
		w[i * 3 + 2] = wrist.z;
		g[i * 3] = grip.x;
		g[i * 3 + 1] = grip.y;
		g[i * 3 + 2] = grip.z;
	}
	return result(outs, 5, wr, gr, held_grip, max_stretch);
}

void InserterArmsNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("sprite_arms", "inp", "caps", "params"), &InserterArmsNative::sprite_arms);
	ClassDB::bind_method(D_METHOD("model_arms", "inp", "caps", "params"), &InserterArmsNative::model_arms);
	ClassDB::bind_method(D_METHOD("basic_arms", "inp", "caps", "params"), &InserterArmsNative::basic_arms);
	ClassDB::bind_method(D_METHOD("rig_arms", "inp", "caps", "params"), &InserterArmsNative::rig_arms);
}
