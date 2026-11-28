#include "hook_upscaler.h"

#include <godot_cpp/classes/class_db_singleton.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#ifdef _WIN32
#include <d3d12.h>
#endif

#include <algorithm>

using namespace godot;

// RenderingDeviceDriver::NativeCallbackInfo (tools/godot-patches/4.7.2/0002-native-callback.patch): plain C,
// append-only; struct_size says how much of it the engine filled.
struct ZenithHookUpscaler::NativeInfo {
	uint32_t struct_size;
	uint32_t api; // 1 = Direct3D 12.
	uint64_t device; // ID3D12Device*.
	uint64_t command_queue; // ID3D12CommandQueue*.
	uint64_t command_list; // ID3D12GraphicsCommandList* being recorded.
	uint32_t barrier_model; // 0 = legacy D3D12_RESOURCE_STATES, 1 = enhanced D3D12_BARRIER_LAYOUT.
	uint32_t resource_count;
	const uint64_t *resources; // ID3D12Resource*, in the order handed over.
	const uint32_t *states; // The state or layout each is in; leave it there.
};

// The patched engine's names and values (0001-0003); Viewport's custom scaling mode and RenderingDevice's
// callback resource usages.
static const int SCALING_3D_MODE_CUSTOM = 6;
static const int USAGE_COPY_FROM = 1;
static const int USAGE_COPY_TO = 2;
static const int USAGE_TEXTURE_SAMPLE = 13;

void ZenithHookUpscaler::_bind_methods() {
	ClassDB::bind_static_method("ZenithHookUpscaler", D_METHOD("hook_in_build"), &ZenithHookUpscaler::hook_in_build);
	ClassDB::bind_static_method("ZenithHookUpscaler", D_METHOD("hook_active"), &ZenithHookUpscaler::hook_active);
	ClassDB::bind_method(D_METHOD("attach", "viewport"), &ZenithHookUpscaler::attach);
	ClassDB::bind_method(D_METHOD("detach"), &ZenithHookUpscaler::detach);
	ClassDB::bind_method(D_METHOD("is_attached"), &ZenithHookUpscaler::is_attached);
	ClassDB::bind_method(D_METHOD("stats"), &ZenithHookUpscaler::stats);
}

bool ZenithHookUpscaler::hook_in_build() {
	ClassDBSingleton *db = ClassDBSingleton::get_singleton();
	return db && db->class_exists("ViewportUpscaler") &&
			db->class_has_method("RenderingDevice", "native_callback_add") &&
			db->class_has_method("RenderData", "get_upscale_inputs");
}

bool ZenithHookUpscaler::hook_active() {
	if (!hook_in_build()) {
		return false;
	}
	RenderingServer *rs = RenderingServer::get_singleton();
	RenderingDevice *rd = rs ? rs->get_rendering_device() : nullptr;
	return rd && int64_t(rd->call("native_callback_get_version")) > 0;
}

bool ZenithHookUpscaler::attach(Viewport *p_viewport) {
	ERR_FAIL_NULL_V(p_viewport, false);
	if (!hook_active()) {
		return false;
	}
	detach();
	RenderingServer *rs = RenderingServer::get_singleton();
	upscaler = rs->call("viewport_upscaler_create");
	ERR_FAIL_COND_V(!upscaler.is_valid(), false);
	rs->call("viewport_upscaler_set_requires_motion_vectors", upscaler, true);
	// A plain copy wants no jitter (a real upscaler sets its phase count here).
	rs->call("viewport_upscaler_set_jitter_phase_count", upscaler, 0);
	rs->call("viewport_upscaler_set_render_callback", upscaler, callable_mp(this, &ZenithHookUpscaler::_render));
	viewport = p_viewport->get_viewport_rid();
	ever_attached = true;
	p_viewport->set("scaling_3d_mode", SCALING_3D_MODE_CUSTOM);
	rs->call("viewport_set_scaling_3d_custom_upscaler", viewport, upscaler);
	return true;
}

void ZenithHookUpscaler::detach() {
	if (!upscaler.is_valid()) {
		return;
	}
	RenderingServer *rs = RenderingServer::get_singleton();
	if (rs) {
		if (viewport.is_valid()) {
			// Only if it is still ours: a viewport set to another mode has already let go.
			rs->call("viewport_set_scaling_3d_custom_upscaler", viewport, RID());
		}
		rs->free_rid(upscaler);
	}
	upscaler = RID();
	viewport = RID();
}

ZenithHookUpscaler::~ZenithHookUpscaler() {
	detach();
	if (!ever_attached) {
		delete counters;
	}
}

// Render thread, at the upscale point: hand the textures to the native copy.
void ZenithHookUpscaler::_render(Object *p_render_data) {
	Counters *k = counters;
	k->frames++;
	ERR_FAIL_NULL(p_render_data);
	Dictionary in = p_render_data->call("get_upscale_inputs");
	if (bool(in.get("reset", false))) {
		k->resets++;
	}
	RID color = in.get("color", RID());
	RID output = in.get("output", RID());
	RID depth = in.get("depth", RID());
	RID velocity = in.get("velocity", RID());
	RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
	if (!rd || !color.is_valid() || !output.is_valid()) {
		k->failures++;
		return;
	}
	TypedArray<RID> textures;
	PackedInt32Array usages;
	textures.push_back(color);
	usages.push_back(USAGE_COPY_FROM);
	textures.push_back(output);
	usages.push_back(USAGE_COPY_TO);
	// Not used by the copy: handed over to check what a real upscaler will get.
	if (depth.is_valid()) {
		textures.push_back(depth);
		usages.push_back(USAGE_TEXTURE_SAMPLE);
	}
	if (velocity.is_valid()) {
		textures.push_back(velocity);
		usages.push_back(USAGE_TEXTURE_SAMPLE);
	}
	int64_t err = rd->call("native_callback_add", int64_t(intptr_t(&ZenithHookUpscaler::native_copy)), int64_t(intptr_t(k)), textures, usages);
	if (err != 0) {
		k->failures++;
	}
}

// Inside Godot's command list: copy the 3D picture into the output (top-left corner when it is smaller).
// The engine has put colour in COPY_SOURCE and the output in COPY_DEST, so no barriers are needed here.
void ZenithHookUpscaler::native_copy(const NativeInfo *p_info, void *p_userdata) {
	Counters *self = (Counters *)p_userdata;
	if (!p_info || !self || p_info->struct_size < sizeof(NativeInfo)) {
		return;
	}
	self->recorded++;
	self->api = p_info->api;
	self->barrier_model = p_info->barrier_model;
	self->resource_count = p_info->resource_count;
	uint32_t nulls = 0;
	for (uint32_t i = 0; i < p_info->resource_count; i++) {
		if (p_info->resources[i] == 0) {
			nulls++;
		}
		if (i < 4) {
			self->states[i] = p_info->states[i];
		}
	}
	self->null_resources = nulls;
	if (p_info->api != 1 || p_info->resource_count < 2 || nulls || p_info->command_list == 0) {
		return;
	}
#ifdef _WIN32
	ID3D12GraphicsCommandList *list = (ID3D12GraphicsCommandList *)p_info->command_list;
	ID3D12Resource *src = (ID3D12Resource *)p_info->resources[0];
	ID3D12Resource *dst = (ID3D12Resource *)p_info->resources[1];
	D3D12_RESOURCE_DESC src_desc = src->GetDesc();
	D3D12_RESOURCE_DESC dst_desc = dst->GetDesc();
	self->render_w = int64_t(src_desc.Width);
	self->render_h = int64_t(src_desc.Height);
	self->output_w = int64_t(dst_desc.Width);
	self->output_h = int64_t(dst_desc.Height);

	D3D12_TEXTURE_COPY_LOCATION from = {};
	from.pResource = src;
	from.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
	from.SubresourceIndex = 0;
	D3D12_TEXTURE_COPY_LOCATION to = {};
	to.pResource = dst;
	to.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
	to.SubresourceIndex = 0;
	D3D12_BOX box = {};
	box.right = UINT(std::min<uint64_t>(src_desc.Width, dst_desc.Width));
	box.bottom = std::min(src_desc.Height, dst_desc.Height);
	box.back = 1;
	list->CopyTextureRegion(&to, 0, 0, 0, &from, &box);
#endif
}

Dictionary ZenithHookUpscaler::stats() const {
	const Counters &k = *counters;
	Dictionary d;
	d["frames"] = k.frames.load();
	d["recorded"] = k.recorded.load();
	d["failures"] = k.failures.load();
	d["resets"] = k.resets.load();
	d["api"] = int64_t(k.api.load());
	d["barrier_model"] = int64_t(k.barrier_model.load());
	d["resource_count"] = int64_t(k.resource_count.load());
	d["null_resources"] = int64_t(k.null_resources.load());
	Array s;
	for (int i = 0; i < 4; i++) {
		s.push_back(int64_t(k.states[i].load()));
	}
	d["states"] = s;
	d["render_size"] = Vector2i(int32_t(k.render_w.load()), int32_t(k.render_h.load()));
	d["output_size"] = Vector2i(int32_t(k.output_w.load()), int32_t(k.output_h.load()));
	return d;
}
