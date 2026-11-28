// ZenithHookUpscaler: the do-nothing upscaler that proves the engine hook (FSR 4 plan, step 2). It uses Zenith's
// Godot patches (tools/godot-patches/4.7.2): the custom scaling mode (0001), the native command-list callback
// (0002) and the upscaler's inputs (0003). Each frame it copies the 3D picture into the upscaled texture with a
// plain D3D12 CopyTextureRegion recorded into Godot's own command list: the whole picture at render scale 1.0,
// the top-left corner of the output below it. No vendor code; AMD FSR and DLSS later take its place.
// Everything is reached through ClassDB by name, so the library also loads on stock Godot (hook_in_build false).
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/string.hpp>

#include <atomic>
#include <cstdint>

namespace godot {

class Viewport;

class ZenithHookUpscaler : public RefCounted {
	GDCLASS(ZenithHookUpscaler, RefCounted)

	RID upscaler; // RenderingServer's viewport upscaler.
	RID viewport; // The viewport it is attached to.

	// Written on the render thread, read by stats(). Kept apart from the object and never freed once
	// attached: a frame the render thread is still recording may hold it after the object is gone.
	struct Counters {
		std::atomic<int64_t> frames{ 0 }; // Render callbacks run.
		std::atomic<int64_t> recorded{ 0 }; // Native callbacks the engine ran (copies recorded).
		std::atomic<int64_t> failures{ 0 }; // Render callbacks that couldn't add the native callback.
		std::atomic<int64_t> resets{ 0 };
		std::atomic<uint32_t> api{ 0 };
		std::atomic<uint32_t> barrier_model{ 0 };
		std::atomic<uint32_t> resource_count{ 0 };
		std::atomic<uint32_t> null_resources{ 0 };
		std::atomic<uint32_t> states[4] = {};
		std::atomic<int64_t> render_w{ 0 }, render_h{ 0 }, output_w{ 0 }, output_h{ 0 };
	};
	Counters *counters = new Counters;
	bool ever_attached = false;

	void _render(Object *p_render_data);

protected:
	static void _bind_methods();

public:
	struct NativeInfo; // RenderingDeviceDriver::NativeCallbackInfo's layout (patch 0002).
	static void native_copy(const NativeInfo *p_info, void *p_userdata);

	// Whether this Godot build has the hook (Zenith's patched template): ClassDB, no device needed.
	static bool hook_in_build();
	// Whether the running renderer can run it now (our build on Direct3D 12 with a rendering device).
	static bool hook_active();

	// Sets the viewport to the custom scaling mode and draws it through this upscaler; false without the hook.
	bool attach(Viewport *p_viewport);
	void detach();
	bool is_attached() const { return upscaler.is_valid(); }
	// {frames, recorded, failures, resets, api, barrier_model, resource_count, null_resources, states,
	// render_size, output_size} for the window test.
	Dictionary stats() const;

	~ZenithHookUpscaler();
};

} // namespace godot
