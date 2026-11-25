// BeltItemsNative: see the header. GPL-3.0.
#include "belt_items_native.h"

#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/multi_mesh_instance3d.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

static const int STRIDE = 16; // item_cards.gd STRIDE

void BeltItemsNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("register_kind", "key", "object_id", "cap", "mask", "nonzero", "bounds", "epoch"), &BeltItemsNative::register_kind);
	ClassDB::bind_method(D_METHOD("unregister_kind", "key"), &BeltItemsNative::unregister_kind);
	ClassDB::bind_method(D_METHOD("clear"), &BeltItemsNative::clear);
	ClassDB::bind_method(D_METHOD("try_put", "key", "buf", "visible_count", "cap", "bounds", "mask", "epoch"), &BeltItemsNative::try_put);
	ClassDB::bind_method(D_METHOD("registered_count"), &BeltItemsNative::registered_count);
}

void BeltItemsNative::register_kind(int64_t key, int64_t object_id, int cap, int mask, bool nonzero, const AABB &bounds, int64_t p_epoch) {
	if (p_epoch != epoch) {
		regs.clear();
		epoch = p_epoch;
	}
	Reg r;
	r.object_id = (uint64_t)object_id;
	r.cap = cap;
	r.mask = mask;
	r.nonzero = nonzero;
	r.bounds = bounds;
	regs[key] = r;
}

void BeltItemsNative::unregister_kind(int64_t key) {
	regs.erase(key);
}

void BeltItemsNative::clear() {
	regs.clear();
}

int BeltItemsNative::try_put(int64_t key, const PackedFloat32Array &buf, int visible_count, int cap, const AABB &bounds, int mask, int64_t p_epoch) {
	if (p_epoch != epoch) {
		regs.clear();
		epoch = p_epoch;
		return 0;
	}
	auto it = regs.find(key);
	if (it == regs.end()) {
		return 0;
	}
	const Reg &r = it->second;
	if (r.cap != cap || r.mask != mask || r.nonzero != (visible_count > 0) || r.bounds != bounds || cap <= 0) {
		return 0;
	}
	Object *o = UtilityFunctions::instance_from_id((int64_t)r.object_id);
	MultiMeshInstance3D *mmi = Object::cast_to<MultiMeshInstance3D>(o);
	if (mmi == nullptr || !mmi->is_visible()) {
		return 0;
	}
	Ref<MultiMesh> mm = mmi->get_multimesh();
	if (mm.is_null() || mm->get_instance_count() != cap || mm->get_custom_aabb() != bounds) {
		return 0;
	}
	int res = 1;
	if (buf.size() == (int64_t)cap * STRIDE) {
		RenderingServer::get_singleton()->multimesh_set_buffer(mm->get_rid(), buf);
		res = 2;
	}
	if (mm->get_visible_instance_count() != visible_count) {
		mm->set_visible_instance_count(visible_count);
	}
	return res;
}
