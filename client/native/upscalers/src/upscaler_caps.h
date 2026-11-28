// ZenithUpscalerCaps: what this PC and build offer the vendor upscalers (AMD FSR 4.1, AMD FSR 3.1, NVIDIA DLSS).
// Capability checks only (FSR 4 plan, step 3): no vendor code, no vendor headers, nothing loaded from vendor/.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

class ZenithUpscalerCaps : public RefCounted {
	GDCLASS(ZenithUpscalerCaps, RefCounted)

protected:
	static void _bind_methods();

public:
	// {renderer, vendor, adapter, rtx, fsr4_gpu, amd_files, nvidia_files, engine_hook, engine_hook_active}
	// (upscalers.gd's caps()); engine_hook_active: the hook can run now (our build on Direct3D 12).
	// exe_dir: Zenith's program folder, where a download's vendor/ sits.
	Dictionary capabilities(const String &exe_dir) const;
	String renderer_name() const;
	String gpu_vendor() const;
	// Whether an AMD adapter name is a Radeon RX 6000 / PRO W6000 / Ryzen iGPU or newer (FSR 4.1 ML). A best
	// guess from the driver's name, same rule as upscalers.gd radeon_fsr4_capable.
	bool radeon_fsr4_capable(const String &adapter) const;
	// Step 4: the FSR version to request from AMD's SDK per entry ("4.1" fsr4, "3.1" fsr3): FSR_VERSION in upscalers.gd.
	bool vendor_files(const String &exe_dir, const String &vendor) const;
	// Whether the engine has the native upscaler hook (plan step 2): Zenith's patched Godot, not stock.
	bool engine_hook() const;
	int api_version() const { return 1; }
};

} // namespace godot
