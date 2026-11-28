#include "upscaler_caps.h"

#include "fsr_upscaler.h"
#include "hook_upscaler.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>

using namespace godot;

// The runtime files each vendor needs beside the program (plan 4.8); keep in step with upscalers.gd.
static const char *AMD_FILES[] = { "vendor/amd/amd_fidelityfx_loader_dx12.dll", "vendor/amd/amd_fidelityfx_upscaler_dx12.dll" };
static const char *NVIDIA_FILES[] = { "vendor/nvidia/sl.interposer.dll", "vendor/nvidia/sl.common.dll", "vendor/nvidia/sl.dlss.dll",
	"vendor/nvidia/zenith-sl-manifest.txt", "vendor/nvidia/nvngx_dlss.dll" };

void ZenithUpscalerCaps::_bind_methods() {
	ClassDB::bind_method(D_METHOD("capabilities", "exe_dir"), &ZenithUpscalerCaps::capabilities);
	ClassDB::bind_method(D_METHOD("renderer_name"), &ZenithUpscalerCaps::renderer_name);
	ClassDB::bind_method(D_METHOD("gpu_vendor"), &ZenithUpscalerCaps::gpu_vendor);
	ClassDB::bind_method(D_METHOD("radeon_fsr4_capable", "adapter"), &ZenithUpscalerCaps::radeon_fsr4_capable);
	ClassDB::bind_method(D_METHOD("vendor_files", "exe_dir", "vendor"), &ZenithUpscalerCaps::vendor_files);
	ClassDB::bind_method(D_METHOD("engine_hook"), &ZenithUpscalerCaps::engine_hook);
	ClassDB::bind_method(D_METHOD("api_version"), &ZenithUpscalerCaps::api_version);
}

String ZenithUpscalerCaps::renderer_name() const {
	RenderingServer *rs = RenderingServer::get_singleton();
	return rs ? rs->get_current_rendering_driver_name() : String();
}

// "amd", "nvidia", "intel" or "other", as upscalers.gd's vendor_from.
String ZenithUpscalerCaps::gpu_vendor() const {
	RenderingServer *rs = RenderingServer::get_singleton();
	if (!rs) {
		return "other";
	}
	String v = (rs->get_video_adapter_vendor() + " " + rs->get_video_adapter_name()).to_lower();
	if (v.contains("nvidia")) {
		return "nvidia";
	}
	if (v.contains("amd") || v.contains("advanced micro") || v.contains("ati ") || v.contains("radeon")) {
		return "amd";
	}
	if (v.contains("intel")) {
		return "intel";
	}
	return "other";
}

// Radeon RX nnnn / PRO Wnnnn with nnnn >= 6000, or a Ryzen iGPU "Radeon 6xxM".."9xxM" / "8050S" / "8060S".
// Mirrors upscalers.gd radeon_fsr4_capable (keep in step); compile-only so far.
static int number_after(const String &s, const String &tag, int digits) {
	int at = s.find(tag);
	while (at >= 0) {
		int i = at + tag.length();
		while (i < s.length() && s[i] == ' ') {
			i++;
		}
		String n;
		while (i < s.length() && s[i] >= '0' && s[i] <= '9') {
			n += String::chr(s[i]);
			i++;
		}
		if (n.length() == digits) {
			return n.to_int();
		}
		at = s.find(tag, at + 1);
	}
	return -1;
}

bool ZenithUpscalerCaps::radeon_fsr4_capable(const String &adapter) const {
	String a = adapter.to_upper();
	int rx = number_after(a, "RX", 4);
	if (rx >= 0) {
		return rx >= 6000;
	}
	int w = a.contains("RADEON") ? number_after(a, " W", 4) : -1;
	if (w >= 0) {
		return w >= 6000;
	}
	if (a.contains("8050S") || a.contains("8060S")) {
		return true;
	}
	int m = number_after(a, "RADEON ", 3);
	return m >= 600 && a.contains(String::num_int64(m) + "M");
}

bool ZenithUpscalerCaps::vendor_files(const String &exe_dir, const String &vendor) const {
	if (OS::get_singleton()->get_name() != "Windows") {
		return false;
	}
	const char **files = vendor == "amd" ? AMD_FILES : NVIDIA_FILES;
	const int count = vendor == "amd" ? 2 : 5;
	for (int i = 0; i < count; i++) {
		if (!FileAccess::file_exists(exe_dir.path_join(files[i]))) {
			return false;
		}
	}
	return true;
}

bool ZenithUpscalerCaps::engine_hook() const {
	// Zenith's patched Godot (tools/godot-patches) has the native upscaler hook; stock Godot doesn't.
	return ZenithHookUpscaler::hook_in_build();
}

Dictionary ZenithUpscalerCaps::capabilities(const String &exe_dir) const {
	Dictionary d;
	RenderingServer *rs = RenderingServer::get_singleton();
	String adapter = rs ? rs->get_video_adapter_name() : String();
	String vendor = gpu_vendor();
	d["renderer"] = renderer_name();
	d["vendor"] = vendor;
	d["adapter"] = adapter;
	d["rtx"] = vendor == "nvidia" && adapter.to_upper().contains("RTX");
	d["fsr4_gpu"] = vendor == "amd" && radeon_fsr4_capable(adapter);
	// AMD's files count only when its runtime loads (step 4): vendor/amd beside the program.
	d["amd_files"] = vendor_files(exe_dir, "amd") && ZenithFsrUpscaler::runtime_loads(exe_dir.path_join("vendor/amd"));
	// NVIDIA's: files only, nothing loaded here. Whether they load (our Streamline build by its manifest, NVIDIA's DLSS
	// signed) upscalers.gd asks through dlss_host.gd, which knows --vendor-dir, and only after the player's OK
	// (dlss_consent): Streamline loads from one folder a run.
	d["nvidia_files"] = vendor_files(exe_dir, "nvidia");
	d["engine_hook"] = engine_hook();
	d["engine_hook_active"] = ZenithHookUpscaler::hook_active();
	d["api_version"] = api_version();
	return d;
}
