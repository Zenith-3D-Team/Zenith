// ZenithDlssUpscaler: NVIDIA DLSS Super Resolution drawing a viewport through Zenith's engine hook (FSR 4 plan, step 7),
// with NVIDIA Streamline built by Zenith itself from its MIT source without the updater (tools/dlss/README.md). It is
// ZenithHookUpscaler with DLSS in place of the plain copy: the custom scaling mode (patch 0001) calls it at FSR 2.2's
// place in the frame, it hands colour, depth, motion vectors and the output to the native callback (patch 0002) with
// the upscale inputs (patch 0003), and the native side records Streamline's DLSS evaluate into Godot's own Direct3D 12
// command list (Streamline's manual hooking: slSetD3DDevice on Godot's device, nothing of Godot's is wrapped).
//
// Nothing of NVIDIA's is linked or in the repo. At run time, from the nvidia folder Zenith is given (vendor/nvidia):
// our three Streamline DLLs (sl.interposer, sl.common, sl.dlss), loaded only when their SHA-256s match the
// zenith-sl-manifest.txt our build wrote beside them, and the player's own nvngx_dlss.dll, only when it carries
// a valid NVIDIA Corporation signature (Windows' Authenticode check, no network). slInit never gets eAllowOTA or eLoadDownloadedPlugins, and our
// Streamline has the update check taken out, so Streamline itself never starts NVIDIA's updater. NVIDIA's driver NGX
// runtime still starts its own (nvngx_update.exe, network) once Streamline asks NGX about DLSS (tools/dlss/README.md).
// Streamline's MIT headers come from the git-ignored art-src/vendor-runtimes/streamline/ folder at build time
// (SConstruct, sl_sdk=); a build without them still has this class, with built_with_sl() false. Everything of the
// engine is reached by name through ClassDB, so the library also loads on stock Godot (attach refuses there).
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

class Viewport;

class ZenithDlssUpscaler : public RefCounted {
	GDCLASS(ZenithDlssUpscaler, RefCounted)

	RID upscaler; // RenderingServer's viewport upscaler.
	RID viewport; // The viewport it is attached to.

	String quality = "quality"; // Upscaling quality (Upscalers.QUALITY's values); "custom" picks a mode by scale.
	float render_scale = 0.67f;
	int jitter_sign = 0; // --dlss-jitter: 0 as Godot hands it (as FSR), 1 negated, 2 y negated.
	int barrier_mode = 0; // Enhanced barriers: 0 bridge through COMMON, 1 hand the layouts over as states.
	// Godot's unwritten (-1, -1) motion vectors derived from depth and the camera first (motion_fill.h), as its own
	// FSR 2.2 does; false (--upscaler-mv=raw) hands the velocity buffer over as it is (before alt/upscaler-fix).
	bool fill_motion_vectors = true;
	// Streamline makes DLSS's feature at its mode's optimal render size; a render size above DLSS's range may draw
	// nothing (black). True skips such frames (stats "oversized"), at most SKIP_RUN in a row, while the host fits the
	// scale (dlss_host.gd); one below DLSS's minimum is only logged; false (--dlss-fit=off) evaluates every frame and
	// logs nothing about sizes (before alt/upscaler-fix).
	bool fit_render_size = true;

	void _render(Object *p_render_data);
	void _release_state();

protected:
	static void _bind_methods();

public:
	struct State; // Streamline's per-viewport state the native callback uses (dlss_upscaler.cpp).

private:
	State *state = nullptr;

public:
	// Whether this library was built with Streamline's API headers (otherwise nothing here can run).
	static bool built_with_sl();
	// Whether DLSS's runtime in nvidia_dir (a vendor/nvidia folder) loads: our three Streamline DLLs match the
	// manifest beside them, the player's nvngx_dlss.dll is signed by NVIDIA, and sl.interposer.dll loads with the
	// entry points Zenith uses. Loaded once and kept for the run (slInit only runs once DLSS draws).
	static bool runtime_loads(const String &nvidia_dir);
	// Why the runtime in nvidia_dir doesn't load ("" when it does).
	static String runtime_problem(const String &nvidia_dir);
	// The player's nvngx_dlss.dll's file version ("310.4.0.0"), "" when it can't be read.
	static String dlss_file_version(const String &nvidia_dir);
	// Whether DLSS can draw now: built with Streamline's headers and the engine hook active (our Godot on D3D12).
	static bool available();
	// Whether Streamline (sl.interposer.dll) was loaded this run by runtime_loads (Zenith's own record).
	static bool runtime_loaded();
	// The Streamline / NVIDIA NGX modules this process has loaded, whoever loaded them (GetModuleHandle on
	// sl.interposer/sl.common/sl.dlss, nvngx_dlss.dll and the driver's _nvngx.dll / nvngx.dll): the test hook that
	// nothing of NVIDIA's is loaded before the player's OK for NVIDIA's updater (alt/dlss-s7c). Empty off Windows.
	static PackedStringArray ngx_modules_loaded();
	// Streamline's DLSS mode for an Upscaling quality ("native" DLAA .. "ultra_performance"; "custom" by scale).
	static int mode_for(const String &p_quality, float p_scale);
	// Shuts Streamline down for the run (after the last viewport let go; the host calls it at exit).
	static void shutdown();

	// Loads the runtime from nvidia_dir, puts the viewport in the custom scaling mode and draws it through DLSS;
	// false (and the viewport untouched) when the hook, the headers or the runtime is missing.
	bool attach(Viewport *p_viewport, const String &nvidia_dir);
	// Gives the viewport back (the caller sets its next scaling mode) and frees DLSS's resources once the GPU is done.
	void detach();
	bool is_attached() const { return upscaler.is_valid(); }

	void set_quality(const String &p_quality) { quality = p_quality; }
	String get_quality() const { return quality; }
	void set_jitter_sign(int p_sign) { jitter_sign = p_sign; }
	int get_jitter_sign() const { return jitter_sign; }
	void set_barrier_mode(int p_mode) { barrier_mode = p_mode; }
	int get_barrier_mode() const { return barrier_mode; }
	void set_fill_motion_vectors(bool p_on) { fill_motion_vectors = p_on; }
	bool get_fill_motion_vectors() const { return fill_motion_vectors; }
	void set_fit_render_size(bool p_on) { fit_render_size = p_on; }
	bool get_fit_render_size() const { return fit_render_size; }
	// NVIDIA's render-size ratio for a DLSS mode (DLAA 1, Quality 2/3, Balanced 0.58, Performance 0.5, Ultra
	// Performance 1/3): the host's first guess before DLSS has said its exact optimal size.
	static float mode_ratio(int p_mode);
	// Frames skipped in a row at most for a render size above DLSS's range; then evaluated anyway (one log line).
	static constexpr int SKIP_RUN = 60;
	// What the native side does with a frame of `p_render` for DLSS's sizes (0 = not known): 0 evaluate, 1 evaluate
	// (below the minimum or between optimal and the range's maximum: logged), 2 skip (above the range, fewer than
	// SKIP_RUN skipped in a row), 3 evaluate anyway (above the range after SKIP_RUN skipped). The upper limit is the
	// range's maximum when DLSS reports one at or above its optimal, else the optimal.
	static int size_action(Vector2i p_render, Vector2i p_optimal, Vector2i p_min, Vector2i p_max, int p_skipped_in_a_row);
	// The render scale the viewport draws at: sets the jitter phase count (8 x ratio squared, as NVIDIA's guide asks)
	// and the mode for "custom". Call it before changing scaling_3d_scale.
	void set_render_scale(float p_scale);

	// {frames, evaluated, failures, resets, presents, api, barrier_model, mode, last_result, problem, sl_ready,
	// supported, render_size, output_size, optimal_size, optimal_mode, optimal_for, min_size, max_size, oversized, mv_fill,
	// mv_fill_passes, mv_fill_problem} for tests and the window test.
	Dictionary stats() const;

	~ZenithDlssUpscaler();
};

} // namespace godot
