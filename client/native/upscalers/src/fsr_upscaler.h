// ZenithFsrUpscaler: AMD FSR Upscaling (FSR 4.1 or FSR 3.1, AMD FSR SDK 2.4.0) drawing a viewport through Zenith's
// engine hook (FSR 4 plan, step 4). It is ZenithHookUpscaler with AMD's upscaler in place of the plain copy: the
// custom scaling mode (patch 0001) calls it at FSR 2.2's place in the frame, it hands colour, depth, motion vectors
// (and exposure when there is one) to the native callback (patch 0002) with the upscale inputs (patch 0003), and the
// native side records AMD's dispatch into Godot's own Direct3D 12 command list.
//
// AMD's runtime is never linked: amd_fidelityfx_loader_dx12.dll is loaded at run time from the vendor/amd folder
// Zenith is given (LoadLibrary), and the loader finds amd_fidelityfx_upscaler_dx12.dll next to itself. No AMD file is
// in the repo; AMD's API headers come from the git-ignored SDK folder at build time (SConstruct, ffx_sdk=). A build
// without them still has this class, with available() false. Everything of the engine is reached by name through
// ClassDB, so the library also loads on stock Godot (attach refuses there).
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

class Viewport;

class ZenithFsrUpscaler : public RefCounted {
	GDCLASS(ZenithFsrUpscaler, RefCounted)

	RID upscaler; // RenderingServer's viewport upscaler.
	RID viewport; // The viewport it is attached to.

	String version = "3.1"; // The FSR version asked for: "4.1" (fsr4) or "3.1" (fsr3), Upscalers.FSR_VERSION.
	float sharpness = 0.575f; // Upscaler sharpness, 0 none .. 1 most (the setting as it is saved).
	bool driver_version = false; // --fsr-driver-version=on: let AMD's driver supply a newer FSR than vendor/amd's.
	bool debug_checking = false; // AMD's runtime checks the inputs and reports to the log (window test).
	int barrier_mode = 0; // Enhanced barriers: 0 bridge through COMMON, 1 hand the layouts over as states.
	// Godot's unwritten (-1, -1) motion vectors derived from depth and the camera first (motion_fill.h), as its own
	// FSR 2.2 does; false (--upscaler-mv=raw) hands the velocity buffer over as it is (before alt/upscaler-fix).
	bool fill_motion_vectors = true;

	void _render(Object *p_render_data);
	void _release_state();

protected:
	static void _bind_methods();

public:
	struct State; // AMD's context, the run-time state the native callback uses (fsr_upscaler.cpp).

private:
	State *state = nullptr;

public:
	// Whether this library was built with AMD's API headers (otherwise nothing here can run).
	static bool built_with_sdk();
	// Whether AMD's runtime in amd_dir (a vendor/amd folder) loads: the loader DLL loads with its five entry points
	// and the upscaler DLL is a loadable image beside it. Loaded once and kept for the run.
	static bool runtime_loads(const String &amd_dir);
	// Why the runtime in amd_dir doesn't load ("" when it does).
	static String runtime_problem(const String &amd_dir);
	// The shipped upscaler DLL's file version ("4.1.2.4555"), "" when it can't be read.
	static String runtime_file_version(const String &amd_dir);
	// Whether AMD FSR can draw now: built with the SDK, the engine hook active (our Godot on Direct3D 12).
	static bool available();

	// Loads AMD's runtime from amd_dir, puts the viewport in the custom scaling mode and draws it through AMD FSR;
	// false (and the viewport untouched) when the hook, the SDK or the runtime is missing.
	bool attach(Viewport *p_viewport, const String &amd_dir);
	// Gives the viewport back (the caller sets its next scaling mode) and frees AMD's context once the GPU is done.
	void detach();
	bool is_attached() const { return upscaler.is_valid(); }

	void set_version(const String &p_version);
	String get_version() const { return version; }
	void set_sharpness(float p_sharpness);
	float get_sharpness() const { return sharpness; }
	void set_driver_version(bool p_on) { driver_version = p_on; }
	bool get_driver_version() const { return driver_version; }
	void set_debug_checking(bool p_on) { debug_checking = p_on; }
	bool get_debug_checking() const { return debug_checking; }
	void set_barrier_mode(int p_mode) { barrier_mode = p_mode; }
	int get_barrier_mode() const { return barrier_mode; }
	void set_fill_motion_vectors(bool p_on) { fill_motion_vectors = p_on; }
	bool get_fill_motion_vectors() const { return fill_motion_vectors; }
	// The render scale the viewport draws at: sets the jitter phase count (AMD's 8 x ratio squared), read by the
	// engine when it configures the render buffers. Call it before changing scaling_3d_scale.
	void set_render_scale(float p_scale);

	// {frames, dispatched, failures, creates, destroys, resets, api, barrier_model, version_asked, version_created,
	// last_error, render_size, output_size, mv_fill, mv_fill_passes, mv_fill_problem} for tests and the window test.
	Dictionary stats() const;

	~ZenithFsrUpscaler();
};

} // namespace godot
