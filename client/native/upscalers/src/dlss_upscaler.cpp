#include "dlss_upscaler.h"

#include "hook_upscaler.h"
#include "motion_fill.h"

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/projection.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <string>
#include <vector>

#if defined(_WIN32) && defined(ZENITH_SL)
#define ZENITH_DLSS 1
#endif

#ifdef ZENITH_DLSS
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <bcrypt.h>
#include <d3d12.h>
#include <dxgi.h>
#include <wincrypt.h>
#include <wintrust.h>
#include <softpub.h>

#include <cwchar>
#include <fstream>

// Streamline's MIT headers (NVIDIA-RTX/Streamline v2.14.16, include/): declarations only, nothing linked.
#include <sl.h>
#include <sl_dlss.h>

#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "crypt32.lib")
#pragma comment(lib, "version.lib")
#pragma comment(lib, "wintrust.lib")
#endif

using namespace godot;

// The patched engine's values (0001, 0002): Viewport's custom scaling mode and RenderingDevice's callback usages.
static const int SCALING_3D_MODE_CUSTOM = 6;
static const int USAGE_TEXTURE_SAMPLE = 13;
static const int USAGE_STORAGE_IMAGE_READ_WRITE = 15;

// sl::DLSSMode's values (sl_dlss.h), so mode_for() is there without Streamline's headers too.
enum {
	MODE_OFF = 0,
	MODE_MAX_PERFORMANCE = 1,
	MODE_BALANCED = 2,
	MODE_MAX_QUALITY = 3,
	MODE_ULTRA_PERFORMANCE = 4,
	MODE_DLAA = 6,
};

// The files DLSS needs in the nvidia folder: our Streamline build (and the manifest it wrote) and NVIDIA's own DLSS.
static const char *SL_DLLS[] = { "sl.interposer.dll", "sl.common.dll", "sl.dlss.dll" };
static const char *MANIFEST = "zenith-sl-manifest.txt";
static const char *NGX_DLSS = "nvngx_dlss.dll";

// Zenith's own project id for Streamline/NGX (a self-made GUID; engine type custom). No NVIDIA application id.
static const char *PROJECT_ID = "3b835fc5-7679-42e6-b254-3a2ffe82bfb6";
static const char *ENGINE_VERSION = "4.7.2";

// RenderingDeviceDriver::NativeCallbackInfo (patch 0002), as hook_upscaler.cpp has it: plain C, append-only.
struct DlssNativeInfo {
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

// The textures handed over, in this order.
enum {
	RES_COLOR,
	RES_DEPTH,
	RES_VELOCITY,
	RES_OUTPUT,
	RES_COUNT
};

#ifdef ZENITH_DLSS
using PFun_HookPresent = HRESULT(IDXGISwapChain *swap_chain, UINT sync_interval, UINT flags, bool &skip);
using PFun_HookAfterPresent = HRESULT(UINT flags);

// Streamline for the run: our sl.interposer.dll and the entry points Zenith calls. Loaded on the main thread
// (runtime_loads); slInit, slSetD3DDevice and the per-frame calls run on the render thread, in the native callback.
struct SlRuntime {
	HMODULE interposer = nullptr;
	std::wstring dir;
	PFun_slInit *init = nullptr;
	PFun_slShutdown *shutdown = nullptr;
	PFun_slIsFeatureSupported *is_supported = nullptr;
	PFun_slSetD3DDevice *set_device = nullptr;
	PFun_slGetNewFrameToken *new_frame = nullptr;
	PFun_slSetConstants *set_constants = nullptr;
	PFun_slEvaluateFeature *evaluate = nullptr;
	PFun_slFreeResources *free_resources = nullptr;
	PFun_slGetFeatureFunction *get_function = nullptr;
	// After slSetD3DDevice: DLSS's own and the common plugin's present hooks.
	PFun_slDLSSSetOptions *dlss_set_options = nullptr;
	PFun_slDLSSGetOptimalSettings *dlss_optimal = nullptr;
	PFun_HookPresent *hook_present = nullptr;
	PFun_HookAfterPresent *hook_after_present = nullptr;
	bool initialized = false; // slInit succeeded (and slShutdown not yet called).
	bool init_failed = false; // slInit, slSetD3DDevice or the feature check failed: not retried this run.
	bool supported = false; // DLSS is supported on Godot's adapter (slIsFeatureSupported).
	uint64_t device = 0;
	std::string init_problem;
	bool ok() const { return interposer && init && shutdown && is_supported && set_device && new_frame && set_constants && evaluate && free_resources && get_function; }
};
static SlRuntime g_sl;
static std::mutex g_sl_lock;
static std::atomic<uint32_t> g_next_viewport{ 1 };

static std::wstring wide(const String &s) {
	std::wstring w;
	CharString u = s.utf8();
	int n = MultiByteToWideChar(CP_UTF8, 0, u.get_data(), -1, nullptr, 0);
	if (n > 0) {
		w.resize(size_t(n));
		MultiByteToWideChar(CP_UTF8, 0, u.get_data(), -1, &w[0], n);
		w.resize(size_t(n - 1));
	}
	for (wchar_t &c : w) {
		if (c == L'/') {
			c = L'\\';
		}
	}
	while (!w.empty() && w.back() == L'\\') {
		w.pop_back();
	}
	return w;
}

static std::wstring wide_ascii(const char *s) {
	std::wstring w;
	for (; *s; s++) {
		w += wchar_t(*s);
	}
	return w;
}

static bool file_exists(const std::wstring &path) {
	DWORD a = GetFileAttributesW(path.c_str());
	return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

// The SHA-256 of an open file, lower-case hex ("" on failure).
static std::string sha256_of(HANDLE p_file) {
	BCRYPT_ALG_HANDLE alg = nullptr;
	BCRYPT_HASH_HANDLE hash = nullptr;
	if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0))) {
		return "";
	}
	bool ok = BCRYPT_SUCCESS(BCryptCreateHash(alg, &hash, nullptr, 0, nullptr, 0, 0));
	std::vector<unsigned char> buffer(1 << 16);
	while (ok) {
		DWORD got = 0;
		if (!ReadFile(p_file, buffer.data(), DWORD(buffer.size()), &got, nullptr)) {
			ok = false;
			break;
		}
		if (got == 0) {
			break;
		}
		ok = BCRYPT_SUCCESS(BCryptHashData(hash, buffer.data(), got, 0));
	}
	unsigned char digest[32] = {};
	if (ok) {
		ok = BCRYPT_SUCCESS(BCryptFinishHash(hash, digest, sizeof(digest), 0));
	}
	if (hash) {
		BCryptDestroyHash(hash);
	}
	BCryptCloseAlgorithmProvider(alg, 0);
	if (!ok) {
		return "";
	}
	static const char *digits = "0123456789abcdef";
	std::string hex;
	for (unsigned char c : digest) {
		hex += digits[c >> 4];
		hex += digits[c & 15];
	}
	return hex;
}

static std::string lower_ascii(std::string s) {
	for (char &c : s) {
		if (c >= 'A' && c <= 'Z') {
			c = char(c - 'A' + 'a');
		}
	}
	return s;
}

// The manifest our build wrote: file name (lower case) -> SHA-256, from "<sha256 hex>  <file name>" lines.
static bool read_manifest(const std::wstring &p_path, std::vector<std::pair<std::string, std::string>> &r_entries) {
	std::ifstream f(p_path);
	if (!f.is_open()) {
		return false;
	}
	std::string line;
	while (std::getline(f, line)) {
		if (!line.empty() && line.back() == '\r') {
			line.pop_back();
		}
		if (line.size() < 66 || line[0] == '#' || line[64] != ' ') {
			continue;
		}
		size_t at = line.find_first_not_of(" *", 64);
		if (at != std::string::npos) {
			r_entries.emplace_back(lower_ascii(line.substr(at)), lower_ascii(line.substr(0, 64)));
		}
	}
	return !r_entries.empty();
}

// Opens a file without write sharing (it can't change while held), "" or why not.
static HANDLE open_locked(const std::wstring &p_path) {
	return CreateFileW(p_path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
}

static std::string narrow(const std::wstring &w) {
	int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0, nullptr, nullptr);
	std::string s(n > 0 ? size_t(n - 1) : 0, '\0');
	if (n > 1) {
		WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, &s[0], n, nullptr, nullptr);
	}
	return s;
}

// "" when the file carries a valid Authenticode signature whose signer's organisation is NVIDIA Corporation; else
// why not. Windows' own check (WinVerifyTrust) with no network: no revocation check, URLs from the cache only.
// (Streamline's sl::security::verifyEmbeddedSignature isn't for this file: it wants a second signature made with
// Streamline's own key, which only Streamline's DLLs carry; nvngx_dlss.dll has one, NVIDIA Corporation's.)
static std::string nvidia_signature_problem(const std::wstring &p_path) {
	WINTRUST_FILE_INFO file = {};
	file.cbStruct = sizeof(file);
	file.pcwszFilePath = p_path.c_str();
	GUID policy = WINTRUST_ACTION_GENERIC_VERIFY_V2;
	WINTRUST_DATA data = {};
	data.cbStruct = sizeof(data);
	data.dwUIChoice = WTD_UI_NONE;
	data.fdwRevocationChecks = WTD_REVOKE_NONE;
	data.dwUnionChoice = WTD_CHOICE_FILE;
	data.pFile = &file;
	data.dwStateAction = WTD_STATEACTION_VERIFY;
	data.dwProvFlags = WTD_CACHE_ONLY_URL_RETRIEVAL | WTD_REVOCATION_CHECK_NONE;
	const LONG status = WinVerifyTrust(static_cast<HWND>(INVALID_HANDLE_VALUE), &policy, &data);
	std::string problem;
	if (status != ERROR_SUCCESS) {
		char code[16];
		snprintf(code, sizeof(code), "0x%08lx", (unsigned long)status);
		problem = std::string("isn't validly signed (WinVerifyTrust ") + code + ")";
	} else {
		CRYPT_PROVIDER_DATA *prov = WTHelperProvDataFromStateData(data.hWVTStateData);
		CRYPT_PROVIDER_SGNR *signer = prov ? WTHelperGetProvSignerFromChain(prov, 0, FALSE, 0) : nullptr;
		PCCERT_CONTEXT cert = signer && signer->csCertChain > 0 && signer->pasCertChain ? signer->pasCertChain[0].pCert : nullptr;
		wchar_t org[256] = {};
		if (cert) {
			CertGetNameStringW(cert, CERT_NAME_ATTR_TYPE, 0, (void *)szOID_ORGANIZATION_NAME, org, 256);
		}
		if (wcscmp(org, L"NVIDIA Corporation") != 0) {
			problem = "isn't signed by NVIDIA (signer organisation '" + narrow(org) + "')";
		}
	}
	data.dwStateAction = WTD_STATEACTION_CLOSE;
	WinVerifyTrust(static_cast<HWND>(INVALID_HANDLE_VALUE), &policy, &data);
	return problem;
}

template <typename T>
static bool proc(HMODULE p_module, const char *p_name, T *&r_fn) {
	r_fn = reinterpret_cast<T *>(reinterpret_cast<void *>(GetProcAddress(p_module, p_name)));
	return r_fn != nullptr;
}

// "" when the runtime in nvidia_dir loads (kept for the run); else why not. Main thread.
static std::string load_runtime(const String &p_dir) {
	std::lock_guard<std::mutex> lock(g_sl_lock);
	const std::wstring dir = wide(p_dir);
	if (g_sl.interposer) {
		return dir == g_sl.dir ? std::string() : "Streamline is already loaded from another folder this run";
	}
	if (dir.empty()) {
		return "no nvidia folder";
	}
	for (const char *f : SL_DLLS) {
		if (!file_exists(dir + L"\\" + wide_ascii(f))) {
			return std::string(f) + " is missing (Zenith's Streamline build, tools/dlss/build_streamline.ps1)";
		}
	}
	if (!file_exists(dir + L"\\" + wide_ascii(MANIFEST))) {
		return std::string(MANIFEST) + " is missing (written by tools/dlss/build_streamline.ps1)";
	}
	if (!file_exists(dir + L"\\" + wide_ascii(NGX_DLSS))) {
		return std::string(NGX_DLSS) + " is missing (NVIDIA's DLSS, from github.com/NVIDIA/DLSS)";
	}
	// NVIDIA's own DLSS must carry a valid NVIDIA signature; NGX in the driver loads it (and checks it too).
	const std::wstring ngx = dir + L"\\" + wide_ascii(NGX_DLSS);
	const std::string signature = nvidia_signature_problem(ngx);
	if (!signature.empty()) {
		return std::string(NGX_DLSS) + " " + signature;
	}
	// Our Streamline: each DLL must match the manifest our build wrote, held open from hashing to loading.
	std::vector<std::pair<std::string, std::string>> manifest;
	if (!read_manifest(dir + L"\\" + wide_ascii(MANIFEST), manifest)) {
		return std::string(MANIFEST) + " can't be read";
	}
	HANDLE held[3] = { INVALID_HANDLE_VALUE, INVALID_HANDLE_VALUE, INVALID_HANDLE_VALUE };
	std::string problem;
	for (int i = 0; i < 3 && problem.empty(); i++) {
		held[i] = open_locked(dir + L"\\" + wide_ascii(SL_DLLS[i]));
		if (held[i] == INVALID_HANDLE_VALUE) {
			problem = std::string(SL_DLLS[i]) + " can't be opened";
			break;
		}
		const std::string hex = sha256_of(held[i]);
		bool listed = false;
		for (const auto &e : manifest) {
			listed = listed || (e.first == SL_DLLS[i] && e.second == hex);
		}
		if (hex.empty() || !listed) {
			problem = std::string(SL_DLLS[i]) + " doesn't match " + MANIFEST + " (not Zenith's Streamline build)";
		}
	}
	HMODULE mod = nullptr;
	if (problem.empty()) {
		const std::wstring path = dir + L"\\" + wide_ascii(SL_DLLS[0]);
		mod = LoadLibraryExW(path.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
		if (!mod) {
			problem = "sl.interposer.dll doesn't load (error " + std::to_string(GetLastError()) + ")";
		}
	}
	for (HANDLE h : held) {
		if (h != INVALID_HANDLE_VALUE) {
			CloseHandle(h);
		}
	}
	if (!problem.empty()) {
		return problem;
	}
	SlRuntime r;
	r.interposer = mod;
	r.dir = dir;
	proc(mod, "slInit", r.init);
	proc(mod, "slShutdown", r.shutdown);
	proc(mod, "slIsFeatureSupported", r.is_supported);
	proc(mod, "slSetD3DDevice", r.set_device);
	proc(mod, "slGetNewFrameToken", r.new_frame);
	proc(mod, "slSetConstants", r.set_constants);
	proc(mod, "slEvaluateFeature", r.evaluate);
	proc(mod, "slFreeResources", r.free_resources);
	proc(mod, "slGetFeatureFunction", r.get_function);
	if (!r.ok()) {
		FreeLibrary(mod);
		return "sl.interposer.dll lacks Streamline's entry points";
	}
	g_sl = r;
	return "";
}

static std::mutex g_log_lock;
static std::vector<std::string> g_log_seen; // Distinct messages printed (g_log_lock).
static bool g_log_full = false;
// Streamline's log: its warnings and errors to Godot's log (nothing written to disk). Streamline repeats some every
// frame and puts the time and thread in front, so a message prints once (its header's [time][..] groups taken off)
// and only the first 40 different ones do: a frame's repeated warning can't crowd out a later one (the owner's black
// screen test reads them).
static void on_sl_log(sl::LogType p_type, const char *p_message) {
	if (p_type == sl::LogType::eInfo || !p_message) {
		return;
	}
	std::string text(p_message);
	size_t at = 0;
	while (at < text.size() && text[at] == '[') {
		const size_t close = text.find(']', at);
		if (close == std::string::npos) {
			break;
		}
		at = close + 1;
	}
	std::string key = text.substr(at);
	while (!key.empty() && (key.back() == '\n' || key.back() == '\r' || key.back() == ' ')) {
		key.pop_back();
	}
	{
		std::lock_guard<std::mutex> lock(g_log_lock);
		for (const std::string &seen : g_log_seen) {
			if (seen == key) {
				return;
			}
		}
		if (g_log_seen.size() >= 40) {
			if (!g_log_full) {
				g_log_full = true;
				UtilityFunctions::print("NVIDIA DLSS (Streamline): more warnings not shown (40 different ones above)");
			}
			return;
		}
		g_log_seen.push_back(key);
	}
	UtilityFunctions::print(String("NVIDIA DLSS (Streamline) ") + (p_type == sl::LogType::eError ? "error: " : "warning: ") + String::utf8(key.c_str()));
}

// slInit + slSetD3DDevice + the DLSS feature check, once for the run, on the render thread (first frame drawn).
static bool ensure_sl(uint64_t p_device) {
	std::lock_guard<std::mutex> lock(g_sl_lock);
	if (g_sl.initialized) {
		return g_sl.supported && g_sl.device == p_device;
	}
	if (g_sl.init_failed || !g_sl.ok()) {
		return false;
	}
	const wchar_t *paths[] = { g_sl.dir.c_str() };
	static const sl::Feature features[] = { sl::kFeatureDLSS };
	sl::Preferences pref{};
	pref.showConsole = false;
	pref.logLevel = sl::LogLevel::eDefault;
	pref.pathsToPlugins = paths;
	pref.numPathsToPlugins = 1;
	pref.pathToLogsAndData = nullptr; // No log file.
	pref.logMessageCallback = on_sl_log;
	// Never eAllowOTA, never eLoadDownloadedPlugins (and our Streamline has the update check taken out).
	pref.flags = sl::PreferenceFlags::eUseManualHooking | sl::PreferenceFlags::eDisableCLStateTracking;
	pref.featuresToLoad = features;
	pref.numFeaturesToLoad = 1;
	pref.applicationId = 0;
	pref.engine = sl::EngineType::eCustom;
	pref.engineVersion = ENGINE_VERSION;
	pref.projectId = PROJECT_ID;
	pref.renderAPI = sl::RenderAPI::eD3D12;
	sl::Result res = g_sl.init(pref, sl::kSDKVersion);
	if (res != sl::Result::eOk) {
		g_sl.init_failed = true;
		g_sl.init_problem = "slInit failed (Streamline result " + std::to_string(int(res)) + ")";
		return false;
	}
	g_sl.initialized = true;
	res = g_sl.set_device((void *)p_device);
	if (res != sl::Result::eOk) {
		g_sl.init_failed = true;
		g_sl.init_problem = "slSetD3DDevice failed (Streamline result " + std::to_string(int(res)) + ")";
		return false;
	}
	g_sl.device = p_device;
	ID3D12Device *device = (ID3D12Device *)p_device;
	LUID luid = device->GetAdapterLuid();
	sl::AdapterInfo adapter{};
	adapter.deviceLUID = (uint8_t *)&luid;
	adapter.deviceLUIDSizeInBytes = sizeof(LUID);
	res = g_sl.is_supported(sl::kFeatureDLSS, adapter);
	if (res != sl::Result::eOk) {
		g_sl.init_failed = true;
		g_sl.init_problem = "DLSS isn't supported on this graphics card or driver (Streamline result " + std::to_string(int(res)) + ")";
		return false;
	}
	void *fn = nullptr;
	if (g_sl.get_function(sl::kFeatureDLSS, "slDLSSSetOptions", fn) == sl::Result::eOk) {
		g_sl.dlss_set_options = (PFun_slDLSSSetOptions *)fn;
	}
	fn = nullptr;
	if (g_sl.get_function(sl::kFeatureDLSS, "slDLSSGetOptimalSettings", fn) == sl::Result::eOk) {
		g_sl.dlss_optimal = (PFun_slDLSSGetOptimalSettings *)fn;
	}
	// The common plugin's per-frame bookkeeping (Streamline's presentCommon), normally run from a wrapped swap
	// chain, which manual hooking on Godot's own swap chain doesn't have: called once a frame after the evaluate.
	fn = nullptr;
	if (g_sl.get_function(sl::kFeatureCommon, "slHookPresent", fn) == sl::Result::eOk) {
		g_sl.hook_present = (PFun_HookPresent *)fn;
	}
	fn = nullptr;
	if (g_sl.get_function(sl::kFeatureCommon, "slHookAfterPresent", fn) == sl::Result::eOk) {
		g_sl.hook_after_present = (PFun_HookAfterPresent *)fn;
	}
	if (!g_sl.dlss_set_options) {
		g_sl.init_failed = true;
		g_sl.init_problem = "sl.dlss.dll didn't load (slDLSSSetOptions missing)";
		return false;
	}
	g_sl.supported = true;
	return true;
}
#endif

struct ZenithDlssUpscaler::State {
	uint32_t viewport_id = 0; // Streamline's viewport handle.
	uint64_t device = 0;
	uint64_t queue = 0;
#ifdef ZENITH_DLSS
	ID3D12Fence *fence = nullptr;
	uint64_t fence_value = 0;
	sl::DLSSOptions options{};
	bool options_set = false;
#endif
	uint32_t frame_index = 0;
	int64_t frame = 0; // Native callbacks run.

	std::atomic<int64_t> frames{ 0 }, evaluated{ 0 }, failures{ 0 }, resets{ 0 }, presents{ 0 };
	std::atomic<uint32_t> api{ 0 }, barrier_model{ 0 };
	std::atomic<int32_t> mode{ 0 }, last_result{ 0 };
	std::atomic<bool> sl_ready{ false }, gave_up{ false };
	std::atomic<int64_t> render_w{ 0 }, render_h{ 0 }, output_w{ 0 }, output_h{ 0 }, optimal_w{ 0 }, optimal_h{ 0 };
	// DLSS's sizes for the current mode and output (slDLSSGetOptimalSettings): the output they were asked for, and the
	// render-size range (dynamic resolution); 0 until known.
	std::atomic<int32_t> optimal_mode{ -1 };
	std::atomic<int64_t> optimal_for_w{ 0 }, optimal_for_h{ 0 }, min_w{ 0 }, min_h{ 0 }, max_w{ 0 }, max_h{ 0 };
	std::atomic<int64_t> oversized{ 0 }; // Frames not evaluated: the render size above DLSS's range for the mode.
	int skipped_in_a_row = 0; // Render thread only.
	std::string size_note; // The last size line printed (text_lock), so each prints once.
	std::mutex text_lock;
	std::string problem; // The last failure, for stats().
	MotionFill fill; // Godot's unwritten motion vectors filled in (render thread).
};

// One frame's inputs, from the render callback to the native one (freed by it).
struct DlssFrameParams {
	ZenithDlssUpscaler::State *state;
	float jitter_x, jitter_y;
	uint32_t render_w, render_h, output_w, output_h;
	bool reset;
	float z_near, z_far, fovy_rad;
	int mode;
	int barrier_mode;
	bool fit_render_size;
	float reprojection[16]; // Current clip -> previous clip, Godot's columns (= Streamline's row-major rows).
	float view_to_clip[16];
};

static void fail(ZenithDlssUpscaler::State *s, int32_t p_code, const std::string &p_why) {
	s->failures++;
	s->last_result = p_code;
	std::lock_guard<std::mutex> lock(s->text_lock);
	if (s->problem != p_why) {
		s->problem = p_why;
		UtilityFunctions::print(String("NVIDIA DLSS: ") + String::utf8(p_why.c_str()));
	}
}

#ifdef ZENITH_DLSS
// Waits until the GPU has run everything submitted to Godot's queue so far.
static void wait_queue(ZenithDlssUpscaler::State *s) {
	if (!s->queue || !s->device) {
		return;
	}
	ID3D12Device *device = (ID3D12Device *)s->device;
	ID3D12CommandQueue *queue = (ID3D12CommandQueue *)s->queue;
	if (!s->fence && FAILED(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, __uuidof(ID3D12Fence), (void **)&s->fence))) {
		s->fence = nullptr;
		return;
	}
	s->fence_value++;
	if (SUCCEEDED(queue->Signal(s->fence, s->fence_value)) && s->fence->GetCompletedValue() < s->fence_value) {
		s->fence->SetEventOnCompletion(s->fence_value, nullptr); // Blocks until done.
	}
}

static D3D12_BARRIER_ACCESS access_for_layout(uint32_t p_layout) {
	switch (p_layout) {
		case D3D12_BARRIER_LAYOUT_SHADER_RESOURCE:
		case D3D12_BARRIER_LAYOUT_DIRECT_QUEUE_SHADER_RESOURCE:
			return D3D12_BARRIER_ACCESS_SHADER_RESOURCE;
		case D3D12_BARRIER_LAYOUT_UNORDERED_ACCESS:
		case D3D12_BARRIER_LAYOUT_DIRECT_QUEUE_UNORDERED_ACCESS:
			return D3D12_BARRIER_ACCESS_UNORDERED_ACCESS;
		case D3D12_BARRIER_LAYOUT_COPY_SOURCE:
		case D3D12_BARRIER_LAYOUT_DIRECT_QUEUE_COPY_SOURCE:
			return D3D12_BARRIER_ACCESS_COPY_SOURCE;
		case D3D12_BARRIER_LAYOUT_COPY_DEST:
		case D3D12_BARRIER_LAYOUT_DIRECT_QUEUE_COPY_DEST:
			return D3D12_BARRIER_ACCESS_COPY_DEST;
		default:
			return D3D12_BARRIER_ACCESS_COMMON;
	}
}

// The legacy state an enhanced-barrier layout stands for (barrier mode 1, "hand the layouts over as states").
static int64_t state_from_layout(uint32_t p_layout) {
	switch (p_layout) {
		case D3D12_BARRIER_LAYOUT_COMMON:
			return D3D12_RESOURCE_STATE_COMMON;
		case D3D12_BARRIER_LAYOUT_SHADER_RESOURCE:
		case D3D12_BARRIER_LAYOUT_DIRECT_QUEUE_SHADER_RESOURCE:
			return D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE | D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
		case D3D12_BARRIER_LAYOUT_UNORDERED_ACCESS:
		case D3D12_BARRIER_LAYOUT_DIRECT_QUEUE_UNORDERED_ACCESS:
			return D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
		case D3D12_BARRIER_LAYOUT_COPY_SOURCE:
		case D3D12_BARRIER_LAYOUT_DIRECT_QUEUE_COPY_SOURCE:
			return D3D12_RESOURCE_STATE_COPY_SOURCE;
		case D3D12_BARRIER_LAYOUT_COPY_DEST:
		case D3D12_BARRIER_LAYOUT_DIRECT_QUEUE_COPY_DEST:
			return D3D12_RESOURCE_STATE_COPY_DEST;
		default:
			return -1;
	}
}

// Enhanced barriers, barrier mode 0: Streamline records legacy ResourceBarrier()s, so the handed-over textures go
// from Godot's layouts to COMMON (D3D12's bridge between the two models) for the evaluate and back (as AMD FSR's).
static bool bridge_layouts(ID3D12GraphicsCommandList *p_list, const DlssNativeInfo *p_info, bool p_to_common) {
	ID3D12GraphicsCommandList7 *list7 = nullptr;
	if (FAILED(p_list->QueryInterface(__uuidof(ID3D12GraphicsCommandList7), (void **)&list7)) || !list7) {
		return false;
	}
	D3D12_TEXTURE_BARRIER barriers[RES_COUNT] = {};
	for (uint32_t i = 0; i < RES_COUNT; i++) {
		D3D12_TEXTURE_BARRIER &b = barriers[i];
		const D3D12_BARRIER_LAYOUT layout = D3D12_BARRIER_LAYOUT(p_info->states[i]);
		b.SyncBefore = D3D12_BARRIER_SYNC_ALL;
		b.SyncAfter = D3D12_BARRIER_SYNC_ALL;
		b.AccessBefore = p_to_common ? access_for_layout(layout) : D3D12_BARRIER_ACCESS_COMMON;
		b.AccessAfter = p_to_common ? D3D12_BARRIER_ACCESS_COMMON : access_for_layout(layout);
		b.LayoutBefore = p_to_common ? layout : D3D12_BARRIER_LAYOUT_COMMON;
		b.LayoutAfter = p_to_common ? D3D12_BARRIER_LAYOUT_COMMON : layout;
		b.pResource = (ID3D12Resource *)p_info->resources[i];
		b.Subresources.IndexOrFirstMipLevel = 0xffffffff; // All subresources.
		b.Flags = D3D12_TEXTURE_BARRIER_FLAG_NONE;
	}
	D3D12_BARRIER_GROUP group = {};
	group.Type = D3D12_BARRIER_TYPE_TEXTURE;
	group.NumBarriers = RES_COUNT;
	group.pTextureBarriers = barriers;
	list7->Barrier(1, &group);
	list7->Release();
	return true;
}

static void to_float4x4(const float *p_columns, sl::float4x4 &r_m) {
	for (int i = 0; i < 4; i++) {
		r_m.row[i] = sl::float4(p_columns[i * 4 + 0], p_columns[i * 4 + 1], p_columns[i * 4 + 2], p_columns[i * 4 + 3]);
	}
}
#endif

static void columns_of(const Projection &p, float *r_out) {
	for (int i = 0; i < 4; i++) {
		for (int j = 0; j < 4; j++) {
			r_out[i * 4 + j] = float(p.columns[i][j]);
		}
	}
}

// Inside Godot's command list, at the upscale point: Streamline's DLSS evaluate on the handed-over textures.
static void native_evaluate(const DlssNativeInfo *p_info, void *p_userdata) {
	DlssFrameParams *p = (DlssFrameParams *)p_userdata;
	if (!p) {
		return;
	}
	ZenithDlssUpscaler::State *s = p->state;
	struct Free {
		DlssFrameParams *p;
		~Free() { delete p; }
	} free_params{ p };
	s->frame++;
	if (!p_info || p_info->struct_size < sizeof(DlssNativeInfo)) {
		s->failures++;
		return;
	}
	s->api = p_info->api;
	s->barrier_model = p_info->barrier_model;
	s->render_w = p->render_w;
	s->render_h = p->render_h;
	s->output_w = p->output_w;
	s->output_h = p->output_h;
	s->mode = p->mode;
	if (p_info->api != 1 || p_info->resource_count < RES_COUNT || !p_info->command_list || !p_info->device) {
		s->failures++;
		return;
	}
	for (uint32_t i = 0; i < RES_COUNT; i++) {
		if (!p_info->resources[i]) {
			s->failures++;
			return;
		}
	}
#ifdef ZENITH_DLSS
	s->device = p_info->device;
	s->queue = p_info->command_queue;
	if (!ensure_sl(p_info->device)) {
		std::string why;
		{
			std::lock_guard<std::mutex> lock(g_sl_lock);
			why = g_sl.init_problem.empty() ? "Streamline isn't ready" : g_sl.init_problem;
		}
		s->gave_up = true;
		fail(s, -1, why);
		return;
	}
	s->sl_ready = true;
	const sl::ViewportHandle vp(s->viewport_id);
	sl::FrameToken *token = nullptr;
	const uint32_t index = s->frame_index++;
	sl::Result res = g_sl.new_frame(token, &index);
	if (res != sl::Result::eOk || !token) {
		fail(s, int32_t(res), "slGetNewFrameToken failed");
		return;
	}

	// Options: the mode for this quality, the output size; Godot's colour is HDR (before tonemapping), DLSS works
	// out the exposure itself (sharpening is gone from DLSS: nothing to set).
	sl::DLSSOptions o{};
	o.mode = sl::DLSSMode(p->mode);
	o.outputWidth = p->output_w;
	o.outputHeight = p->output_h;
	o.colorBuffersHDR = sl::Boolean::eTrue;
	o.useAutoExposure = sl::Boolean::eTrue;
	o.preExposure = 1.0f;
	o.exposureScale = 1.0f;
	if (!s->options_set || o.mode != s->options.mode || o.outputWidth != s->options.outputWidth || o.outputHeight != s->options.outputHeight) {
		res = g_sl.dlss_set_options(vp, o);
		if (res != sl::Result::eOk) {
			fail(s, int32_t(res), "slDLSSSetOptions failed (Streamline result " + std::to_string(int(res)) + ")");
			return;
		}
		s->options = o;
		s->options_set = true;
		s->optimal_w = s->optimal_h = s->min_w = s->min_h = s->max_w = s->max_h = 0;
		s->skipped_in_a_row = 0; // A new mode or output gets its own bounded run.
		s->optimal_mode = p->mode;
		s->optimal_for_w = p->output_w;
		s->optimal_for_h = p->output_h;
		if (g_sl.dlss_optimal) {
			sl::DLSSOptimalSettings best{};
			if (g_sl.dlss_optimal(o, best) == sl::Result::eOk) {
				s->optimal_w = best.optimalRenderWidth;
				s->optimal_h = best.optimalRenderHeight;
				s->min_w = best.renderWidthMin;
				s->min_h = best.renderHeightMin;
				s->max_w = best.renderWidthMax;
				s->max_h = best.renderHeightMax;
			}
		}
		UtilityFunctions::print(String("NVIDIA DLSS: mode ") + String::num_int64(p->mode) + ", " + String::num_int64(p->render_w) + "x" +
				String::num_int64(p->render_h) + " -> " + String::num_int64(p->output_w) + "x" + String::num_int64(p->output_h) +
				" (DLSS's optimal " + String::num_int64(s->optimal_w.load()) + "x" + String::num_int64(s->optimal_h.load()) + ", range " +
				String::num_int64(s->min_w.load()) + "x" + String::num_int64(s->min_h.load()) + " .. " + String::num_int64(s->max_w.load()) + "x" +
				String::num_int64(s->max_h.load()) + ")");
	}

	// Streamline makes DLSS's feature at the optimal render size (sl.dlss's dlssEntry.cpp, NGX Width/Height); NVIDIA's
	// contract takes any render size in DLSS's [minimum, maximum]. One above that may draw nothing (perhaps the black
	// screen of every upscaling mode: Godot's 0.67 is above DLSS Quality's 2/3; unconfirmed until the window test), so
	// such frames are skipped while the host fits the scale (dlss_host.gd), but never more than SKIP_RUN in a row: a
	// size the fit can't reach is then evaluated anyway. Below the minimum (one pixel under where minimum = optimal) is
	// only logged. Each size line prints once.
	if (p->fit_render_size && s->optimal_w > 0 && s->optimal_h > 0) {
		const Vector2i render(int32_t(p->render_w), int32_t(p->render_h));
		const Vector2i optimal(int32_t(s->optimal_w.load()), int32_t(s->optimal_h.load()));
		const Vector2i low(int32_t(s->min_w.load()), int32_t(s->min_h.load()));
		const Vector2i high(int32_t(s->max_w.load()), int32_t(s->max_h.load()));
		const int action = ZenithDlssUpscaler::size_action(render, optimal, low, high, s->skipped_in_a_row);
		if (action != 0) {
			const bool use_max = high.x >= optimal.x && high.y >= optimal.y && high.x > 0;
			const std::string size = std::to_string(render.x) + "x" + std::to_string(render.y);
			const std::string mode = " for mode " + std::to_string(p->mode);
			std::string why;
			if (action == 1) {
				const bool under = low.x > 0 && low.y > 0 && (render.x < low.x || render.y < low.y);
				why = under ? "render size " + size + " below DLSS's minimum " + std::to_string(low.x) + "x" + std::to_string(low.y) + mode + ": evaluated"
							: "render size " + size + " above DLSS's optimal " + std::to_string(optimal.x) + "x" + std::to_string(optimal.y) +
								" within its range up to " + std::to_string(high.x) + "x" + std::to_string(high.y) + mode + ": evaluated";
			} else {
				const Vector2i top = use_max ? high : optimal;
				why = "render size " + size + " above DLSS's " + (use_max ? "maximum " : "optimal ") + std::to_string(top.x) + "x" + std::to_string(top.y) + mode +
						(action == 2 ? ": frames skipped until the scale is fitted" : ": evaluated anyway after " + std::to_string(ZenithDlssUpscaler::SKIP_RUN) + " skipped frames");
			}
			std::lock_guard<std::mutex> lock(s->text_lock);
			if (s->size_note != why) {
				s->size_note = why;
				UtilityFunctions::print(String("NVIDIA DLSS: ") + String::utf8(why.c_str()));
			}
			if (action == 2) {
				s->problem = why;
			}
		}
		if (action == 2) {
			s->skipped_in_a_row++;
			s->oversized++;
			// Streamline's frame bookkeeping as on an evaluated frame.
			if (g_sl.hook_present && g_sl.hook_after_present) {
				bool skip = false;
				g_sl.hook_present(nullptr, 0, 0, skip);
				g_sl.hook_after_present(0);
				s->presents++;
			}
			return;
		}
		if (action != 3) {
			s->skipped_in_a_row = 0;
		}
	}

	// Constants: Godot's motion vectors are previous minus current in UV units with the camera's motion in them
	// and the jitter taken out (as Godot's FSR 2.2 gets them), so mvecScale 1 (Streamline multiplies by the render
	// size); the pixels Godot's motion pass didn't write are filled in first (MotionFill); depth is reversed-Z. Matrices: Godot's columns are Streamline's row-major rows (row vectors).
	sl::Constants c{};
	to_float4x4(p->view_to_clip, c.cameraViewToClip);
	{
		Projection v2c;
		for (int i = 0; i < 4; i++) {
			for (int j = 0; j < 4; j++) {
				v2c.columns[i][j] = p->view_to_clip[i * 4 + j];
			}
		}
		float inv[16];
		columns_of(v2c.inverse(), inv);
		to_float4x4(inv, c.clipToCameraView);
		Projection rep;
		for (int i = 0; i < 4; i++) {
			for (int j = 0; j < 4; j++) {
				rep.columns[i][j] = p->reprojection[i * 4 + j];
			}
		}
		columns_of(rep.inverse(), inv);
		to_float4x4(inv, c.prevClipToClip);
	}
	to_float4x4(p->reprojection, c.clipToPrevClip);
	const float identity[16] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
	to_float4x4(identity, c.clipToLensClip);
	c.jitterOffset = sl::float2(p->jitter_x, p->jitter_y);
	c.mvecScale = sl::float2(1.0f, 1.0f);
	c.cameraPinholeOffset = sl::float2(0.0f, 0.0f);
	// Not handed over by the hook and not used by DLSS Super Resolution: the camera in its own space.
	c.cameraPos = sl::float3(0.0f, 0.0f, 0.0f);
	c.cameraUp = sl::float3(0.0f, 1.0f, 0.0f);
	c.cameraRight = sl::float3(1.0f, 0.0f, 0.0f);
	c.cameraFwd = sl::float3(0.0f, 0.0f, -1.0f);
	c.cameraNear = p->z_near;
	c.cameraFar = p->z_far;
	c.cameraFOV = p->fovy_rad;
	c.cameraAspectRatio = float(p->render_w) / float(p->render_h);
	c.motionVectorsInvalidValue = 0.0f;
	c.depthInverted = sl::Boolean::eTrue;
	c.cameraMotionIncluded = sl::Boolean::eTrue;
	c.motionVectors3D = sl::Boolean::eFalse;
	c.reset = p->reset ? sl::Boolean::eTrue : sl::Boolean::eFalse;
	c.orthographicProjection = sl::Boolean::eFalse;
	c.motionVectorsDilated = sl::Boolean::eFalse;
	c.motionVectorsJittered = sl::Boolean::eFalse;
	res = g_sl.set_constants(c, *token, vp);
	if (res != sl::Result::eOk) {
		fail(s, int32_t(res), "slSetConstants failed (Streamline result " + std::to_string(int(res)) + ")");
		return;
	}

	// The textures, tagged for this evaluate only, in the state each is in (COMMON when bridged).
	ID3D12GraphicsCommandList *list = (ID3D12GraphicsCommandList *)p_info->command_list;
	const bool enhanced = p_info->barrier_model == 1;
	const bool bridge = enhanced && p->barrier_mode == 0;
	uint32_t states[RES_COUNT];
	for (uint32_t i = 0; i < RES_COUNT; i++) {
		int64_t st = bridge ? int64_t(D3D12_RESOURCE_STATE_COMMON) : (enhanced ? state_from_layout(p_info->states[i]) : int64_t(p_info->states[i]));
		if (st < 0) {
			fail(s, -2, "texture " + std::to_string(i) + " is in a layout with no legacy state (" + std::to_string(p_info->states[i]) + ")");
			return;
		}
		states[i] = uint32_t(st);
	}
	sl::Resource color(sl::ResourceType::eTex2d, (void *)p_info->resources[RES_COLOR], states[RES_COLOR]);
	sl::Resource depth(sl::ResourceType::eTex2d, (void *)p_info->resources[RES_DEPTH], states[RES_DEPTH]);
	sl::Resource mvec(sl::ResourceType::eTex2d, (void *)p_info->resources[RES_VELOCITY], states[RES_VELOCITY]);
	sl::Resource output(sl::ResourceType::eTex2d, (void *)p_info->resources[RES_OUTPUT], states[RES_OUTPUT]);
	const sl::Extent render_extent{ 0, 0, p->render_w, p->render_h };
	const sl::Extent output_extent{ 0, 0, p->output_w, p->output_h };
	sl::ResourceTag tag_color(&color, sl::kBufferTypeScalingInputColor, sl::ResourceLifecycle::eValidUntilEvaluate, &render_extent);
	sl::ResourceTag tag_depth(&depth, sl::kBufferTypeDepth, sl::ResourceLifecycle::eValidUntilEvaluate, &render_extent);
	sl::ResourceTag tag_mvec(&mvec, sl::kBufferTypeMotionVectors, sl::ResourceLifecycle::eValidUntilEvaluate, &render_extent);
	sl::ResourceTag tag_output(&output, sl::kBufferTypeScalingOutputColor, sl::ResourceLifecycle::eValidUntilEvaluate, &output_extent);
	const sl::BaseStructure *inputs[] = { &vp, &tag_color, &tag_depth, &tag_mvec, &tag_output };

	if (bridge && !bridge_layouts(list, p_info, true)) {
		fail(s, -3, "the command list has no enhanced barriers (ID3D12GraphicsCommandList7)");
		return;
	}
	res = g_sl.evaluate(sl::kFeatureDLSS, *token, inputs, uint32_t(sizeof(inputs) / sizeof(inputs[0])), (sl::CommandBuffer *)list);
	if (bridge) {
		bridge_layouts(list, p_info, false);
	}
	// Streamline's once-a-frame bookkeeping (frame counting, freeing what frames in flight let go).
	if (g_sl.hook_present && g_sl.hook_after_present) {
		bool skip = false;
		g_sl.hook_present(nullptr, 0, 0, skip);
		g_sl.hook_after_present(0);
		s->presents++;
	}
	if (res != sl::Result::eOk) {
		fail(s, int32_t(res), "slEvaluateFeature failed (Streamline result " + std::to_string(int(res)) + ")");
		return;
	}
	if (p->reset) {
		s->resets++;
	}
	s->last_result = 0;
	s->evaluated++;
	{
		// The skipped frames' note goes once the scale fits.
		std::lock_guard<std::mutex> lock(s->text_lock);
		if (s->problem.rfind("render size ", 0) == 0) {
			s->problem.clear();
		}
	}
#else
	s->failures++;
#endif
}

void ZenithDlssUpscaler::_bind_methods() {
	ClassDB::bind_static_method("ZenithDlssUpscaler", D_METHOD("built_with_sl"), &ZenithDlssUpscaler::built_with_sl);
	ClassDB::bind_static_method("ZenithDlssUpscaler", D_METHOD("runtime_loads", "nvidia_dir"), &ZenithDlssUpscaler::runtime_loads);
	ClassDB::bind_static_method("ZenithDlssUpscaler", D_METHOD("runtime_problem", "nvidia_dir"), &ZenithDlssUpscaler::runtime_problem);
	ClassDB::bind_static_method("ZenithDlssUpscaler", D_METHOD("dlss_file_version", "nvidia_dir"), &ZenithDlssUpscaler::dlss_file_version);
	ClassDB::bind_static_method("ZenithDlssUpscaler", D_METHOD("available"), &ZenithDlssUpscaler::available);
	ClassDB::bind_static_method("ZenithDlssUpscaler", D_METHOD("runtime_loaded"), &ZenithDlssUpscaler::runtime_loaded);
	ClassDB::bind_static_method("ZenithDlssUpscaler", D_METHOD("ngx_modules_loaded"), &ZenithDlssUpscaler::ngx_modules_loaded);
	ClassDB::bind_static_method("ZenithDlssUpscaler", D_METHOD("mode_for", "quality", "scale"), &ZenithDlssUpscaler::mode_for);
	ClassDB::bind_static_method("ZenithDlssUpscaler", D_METHOD("shutdown"), &ZenithDlssUpscaler::shutdown);
	ClassDB::bind_method(D_METHOD("attach", "viewport", "nvidia_dir"), &ZenithDlssUpscaler::attach);
	ClassDB::bind_method(D_METHOD("detach"), &ZenithDlssUpscaler::detach);
	ClassDB::bind_method(D_METHOD("is_attached"), &ZenithDlssUpscaler::is_attached);
	ClassDB::bind_method(D_METHOD("set_quality", "quality"), &ZenithDlssUpscaler::set_quality);
	ClassDB::bind_method(D_METHOD("get_quality"), &ZenithDlssUpscaler::get_quality);
	ClassDB::bind_method(D_METHOD("set_jitter_sign", "sign"), &ZenithDlssUpscaler::set_jitter_sign);
	ClassDB::bind_method(D_METHOD("get_jitter_sign"), &ZenithDlssUpscaler::get_jitter_sign);
	ClassDB::bind_method(D_METHOD("set_barrier_mode", "mode"), &ZenithDlssUpscaler::set_barrier_mode);
	ClassDB::bind_method(D_METHOD("get_barrier_mode"), &ZenithDlssUpscaler::get_barrier_mode);
	ClassDB::bind_method(D_METHOD("set_fill_motion_vectors", "on"), &ZenithDlssUpscaler::set_fill_motion_vectors);
	ClassDB::bind_method(D_METHOD("get_fill_motion_vectors"), &ZenithDlssUpscaler::get_fill_motion_vectors);
	ClassDB::bind_method(D_METHOD("set_fit_render_size", "on"), &ZenithDlssUpscaler::set_fit_render_size);
	ClassDB::bind_method(D_METHOD("get_fit_render_size"), &ZenithDlssUpscaler::get_fit_render_size);
	ClassDB::bind_static_method("ZenithDlssUpscaler", D_METHOD("mode_ratio", "mode"), &ZenithDlssUpscaler::mode_ratio);
	ClassDB::bind_static_method("ZenithDlssUpscaler", D_METHOD("size_action", "render_size", "optimal", "min_size", "max_size", "skipped_in_a_row"), &ZenithDlssUpscaler::size_action);
	ClassDB::bind_method(D_METHOD("set_render_scale", "scale"), &ZenithDlssUpscaler::set_render_scale);
	ClassDB::bind_method(D_METHOD("stats"), &ZenithDlssUpscaler::stats);
}

bool ZenithDlssUpscaler::built_with_sl() {
#ifdef ZENITH_DLSS
	return true;
#else
	return false;
#endif
}

String ZenithDlssUpscaler::runtime_problem(const String &nvidia_dir) {
#ifdef ZENITH_DLSS
	return String::utf8(load_runtime(nvidia_dir).c_str());
#else
	return "built without Streamline's headers (sl_sdk=)";
#endif
}

bool ZenithDlssUpscaler::runtime_loads(const String &nvidia_dir) {
	return runtime_problem(nvidia_dir).is_empty();
}

String ZenithDlssUpscaler::dlss_file_version(const String &nvidia_dir) {
#ifdef ZENITH_DLSS
	const std::wstring path = wide(nvidia_dir) + L"\\" + wide_ascii(NGX_DLSS);
	DWORD ignored = 0;
	DWORD size = GetFileVersionInfoSizeW(path.c_str(), &ignored);
	if (size == 0) {
		return "";
	}
	std::vector<unsigned char> data(size);
	VS_FIXEDFILEINFO *info = nullptr;
	UINT len = 0;
	if (!GetFileVersionInfoW(path.c_str(), 0, size, data.data()) || !VerQueryValueW(data.data(), L"\\", (void **)&info, &len) || !info) {
		return "";
	}
	char text[64];
	snprintf(text, sizeof(text), "%u.%u.%u.%u", unsigned(HIWORD(info->dwFileVersionMS)), unsigned(LOWORD(info->dwFileVersionMS)),
			unsigned(HIWORD(info->dwFileVersionLS)), unsigned(LOWORD(info->dwFileVersionLS)));
	return String(text);
#else
	return "";
#endif
}

bool ZenithDlssUpscaler::available() {
	return built_with_sl() && ZenithHookUpscaler::hook_active();
}

bool ZenithDlssUpscaler::runtime_loaded() {
#ifdef ZENITH_DLSS
	std::lock_guard<std::mutex> lock(g_sl_lock);
	return g_sl.interposer != nullptr;
#else
	return false;
#endif
}

PackedStringArray ZenithDlssUpscaler::ngx_modules_loaded() {
	PackedStringArray found;
#ifdef ZENITH_DLSS
	static const wchar_t *NAMES[] = { L"sl.interposer.dll", L"sl.common.dll", L"sl.dlss.dll", L"nvngx_dlss.dll", L"_nvngx.dll", L"nvngx.dll" };
	for (const wchar_t *n : NAMES) {
		if (GetModuleHandleW(n) != nullptr) {
			found.push_back(String(n));
		}
	}
#endif
	return found;
}

int ZenithDlssUpscaler::mode_for(const String &p_quality, float p_scale) {
	if (p_quality == "native") {
		return MODE_DLAA;
	}
	if (p_quality == "quality") {
		return MODE_MAX_QUALITY;
	}
	if (p_quality == "balanced") {
		return MODE_BALANCED;
	}
	if (p_quality == "performance") {
		return MODE_MAX_PERFORMANCE;
	}
	if (p_quality == "ultra_performance") {
		return MODE_ULTRA_PERFORMANCE;
	}
	// Custom: the mode whose ratio is nearest below the scale (DLSS takes any render size in its mode's range).
	if (p_scale >= 0.95f) {
		return MODE_DLAA;
	}
	if (p_scale >= 0.63f) {
		return MODE_MAX_QUALITY;
	}
	if (p_scale >= 0.545f) {
		return MODE_BALANCED;
	}
	if (p_scale >= 0.415f) {
		return MODE_MAX_PERFORMANCE;
	}
	return MODE_ULTRA_PERFORMANCE;
}

float ZenithDlssUpscaler::mode_ratio(int p_mode) {
	switch (p_mode) {
		case MODE_MAX_QUALITY:
			return 2.0f / 3.0f;
		case MODE_BALANCED:
			return 0.58f;
		case MODE_MAX_PERFORMANCE:
			return 0.5f;
		case MODE_ULTRA_PERFORMANCE:
			return 1.0f / 3.0f;
		default:
			return 1.0f; // DLAA (and off).
	}
}

int ZenithDlssUpscaler::size_action(Vector2i p_render, Vector2i p_optimal, Vector2i p_min, Vector2i p_max, int p_skipped_in_a_row) {
	if (p_optimal.x <= 0 || p_optimal.y <= 0) {
		return 0;
	}
	const bool use_max = p_max.x >= p_optimal.x && p_max.y >= p_optimal.y && p_max.x > 0;
	const Vector2i top = use_max ? p_max : p_optimal;
	if (p_render.x > top.x || p_render.y > top.y) {
		return p_skipped_in_a_row < SKIP_RUN ? 2 : 3;
	}
	const bool under = p_min.x > 0 && p_min.y > 0 && (p_render.x < p_min.x || p_render.y < p_min.y);
	const bool above_optimal = p_render.x > p_optimal.x || p_render.y > p_optimal.y;
	return (under || above_optimal) ? 1 : 0;
}

void ZenithDlssUpscaler::shutdown() {
#ifdef ZENITH_DLSS
	std::lock_guard<std::mutex> lock(g_sl_lock);
	if (g_sl.initialized && g_sl.shutdown) {
		g_sl.shutdown();
	}
	g_sl.initialized = false;
	g_sl.supported = false;
	g_sl.device = 0;
	g_sl.dlss_set_options = nullptr;
	g_sl.dlss_optimal = nullptr;
	g_sl.hook_present = nullptr;
	g_sl.hook_after_present = nullptr;
	// sl.interposer.dll stays loaded: freeing it while Streamline's threads may run is unsafe; the run is ending.
#endif
}

void ZenithDlssUpscaler::set_render_scale(float p_scale) {
	if (p_scale <= 0.0f) {
		return;
	}
	render_scale = p_scale;
	if (!upscaler.is_valid()) {
		return;
	}
	// NVIDIA's guide: a Halton sequence of at least 8 x (display / render) squared phases.
	const float ratio = p_scale >= 1.0f ? 1.0f : 1.0f / p_scale;
	const int64_t phases = int64_t(std::ceil(8.0f * ratio * ratio));
	RenderingServer::get_singleton()->call("viewport_upscaler_set_jitter_phase_count", upscaler, phases);
}

bool ZenithDlssUpscaler::attach(Viewport *p_viewport, const String &nvidia_dir) {
	ERR_FAIL_NULL_V(p_viewport, false);
	if (!available() || !runtime_loads(nvidia_dir)) {
		return false;
	}
	detach();
	RenderingServer *rs = RenderingServer::get_singleton();
	upscaler = rs->call("viewport_upscaler_create");
	ERR_FAIL_COND_V(!upscaler.is_valid(), false);
	state = new State;
	state->viewport_id = g_next_viewport.fetch_add(1);
	rs->call("viewport_upscaler_set_requires_motion_vectors", upscaler, true);
	set_render_scale(float(p_viewport->get_scaling_3d_scale()));
	rs->call("viewport_upscaler_set_render_callback", upscaler, callable_mp(this, &ZenithDlssUpscaler::_render));
	viewport = p_viewport->get_viewport_rid();
	p_viewport->set("scaling_3d_mode", SCALING_3D_MODE_CUSTOM);
	rs->call("viewport_set_scaling_3d_custom_upscaler", viewport, upscaler);
	return true;
}

void ZenithDlssUpscaler::detach() {
	if (!upscaler.is_valid()) {
		return;
	}
	RenderingServer *rs = RenderingServer::get_singleton();
	if (rs) {
		if (viewport.is_valid()) {
			rs->call("viewport_set_scaling_3d_custom_upscaler", viewport, RID());
		}
		rs->free_rid(upscaler);
	}
	upscaler = RID();
	viewport = RID();
	_release_state();
}

// After the last frame that drew through it: every native callback has run (the render thread is synced) and the
// GPU is done, so DLSS's resources for this viewport and the state go. Streamline itself stays up for the run.
void ZenithDlssUpscaler::_release_state() {
	if (!state) {
		return;
	}
	RenderingServer *rs = RenderingServer::get_singleton();
	if (rs) {
		rs->force_sync();
	}
	state->fill.release();
#ifdef ZENITH_DLSS
	if (state->sl_ready) {
		wait_queue(state);
		std::lock_guard<std::mutex> lock(g_sl_lock);
		if (g_sl.initialized && g_sl.free_resources) {
			g_sl.free_resources(sl::kFeatureDLSS, sl::ViewportHandle(state->viewport_id));
		}
	}
	if (state->fence) {
		state->fence->Release();
		state->fence = nullptr;
	}
#endif
	delete state;
	state = nullptr;
}

ZenithDlssUpscaler::~ZenithDlssUpscaler() {
	detach();
}

// Render thread, at the upscale point: this frame's inputs to the native evaluate.
void ZenithDlssUpscaler::_render(Object *p_render_data) {
	State *s = state;
	ERR_FAIL_NULL(s);
	s->frames++;
	ERR_FAIL_NULL(p_render_data);
	if (s->gave_up) {
		return; // Streamline couldn't start (stats say why); the host goes back to FSR 2.2.
	}
	Dictionary in = p_render_data->call("get_upscale_inputs");
	RID color = in.get("color", RID());
	RID depth = in.get("depth", RID());
	RID velocity = in.get("velocity", RID());
	RID output = in.get("output", RID());
	RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
	if (!rd || !color.is_valid() || !depth.is_valid() || !velocity.is_valid() || !output.is_valid()) {
		s->failures++;
		return;
	}
	if (bool(in.get("orthogonal", false))) {
		// Zenith falls back to FSR 1 / bilinear for orthographic views before it gets here (Settings).
		s->failures++;
		return;
	}
	Vector2i render_size = in.get("render_size", Vector2i());
	Vector2i output_size = in.get("output_size", Vector2i());
	Vector2 jitter = in.get("jitter", Vector2());
	DlssFrameParams *p = new DlssFrameParams{};
	p->state = s;
	p->jitter_x = float(jitter.x) * (jitter_sign == 1 ? -1.0f : 1.0f);
	p->jitter_y = float(jitter.y) * (jitter_sign == 1 || jitter_sign == 2 ? -1.0f : 1.0f);
	p->render_w = uint32_t(render_size.x > 0 ? render_size.x : 1);
	p->render_h = uint32_t(render_size.y > 0 ? render_size.y : 1);
	p->output_w = uint32_t(output_size.x > 0 ? output_size.x : 1);
	p->output_h = uint32_t(output_size.y > 0 ? output_size.y : 1);
	p->reset = bool(in.get("reset", false));
	p->z_near = float(in.get("z_near", 0.05));
	p->z_far = float(in.get("z_far", 4000.0));
	const double fovy = double(in.get("fovy", 60.0));
	p->fovy_rad = float(Math::deg_to_rad(fovy));
	p->mode = mode_for(quality, render_scale);
	p->barrier_mode = barrier_mode;
	p->fit_render_size = fit_render_size;
	Projection reprojection = in.get("reprojection", Projection());
	columns_of(reprojection, p->reprojection);
	// The camera's projection as the hook's reprojection has it (Godot's depth correction: y flipped, reversed Z).
	Projection correction;
	correction.set_depth_correction(true, true, false);
	const real_t aspect = real_t(p->render_w) / real_t(p->render_h);
	columns_of(correction * Projection::create_perspective(real_t(fovy), aspect, real_t(p->z_near), real_t(p->z_far)), p->view_to_clip);
	// Godot's unwritten motion vectors filled in (a compute pass recorded here, before the evaluate reads it).
	const RID motion = fill_motion_vectors ? s->fill.process(rd, in) : velocity;
	TypedArray<RID> textures;
	PackedInt32Array usages;
	textures.push_back(color);
	usages.push_back(USAGE_TEXTURE_SAMPLE);
	textures.push_back(depth);
	usages.push_back(USAGE_TEXTURE_SAMPLE);
	textures.push_back(motion);
	usages.push_back(USAGE_TEXTURE_SAMPLE);
	textures.push_back(output);
	usages.push_back(USAGE_STORAGE_IMAGE_READ_WRITE);
	int64_t err = rd->call("native_callback_add", int64_t(intptr_t(&native_evaluate)), int64_t(intptr_t(p)), textures, usages);
	if (err != 0) {
		delete p;
		s->failures++;
	}
}

Dictionary ZenithDlssUpscaler::stats() const {
	Dictionary d;
	d["quality"] = quality;
	d["mode"] = mode_for(quality, render_scale);
	d["mv_fill"] = fill_motion_vectors;
	d["fit_render_size"] = fit_render_size;
	if (!state) {
		d["frames"] = 0;
		d["evaluated"] = 0;
		d["failures"] = 0;
		return d;
	}
	const State &k = *state;
	d["frames"] = k.frames.load();
	d["evaluated"] = k.evaluated.load();
	d["failures"] = k.failures.load();
	d["resets"] = k.resets.load();
	d["presents"] = k.presents.load();
	d["api"] = int64_t(k.api.load());
	d["barrier_model"] = int64_t(k.barrier_model.load());
	d["last_result"] = int64_t(k.last_result.load());
	d["sl_ready"] = k.sl_ready.load();
	d["gave_up"] = k.gave_up.load();
	{
		std::lock_guard<std::mutex> lock(state->text_lock);
		d["problem"] = String::utf8(k.problem.c_str());
	}
	d["render_size"] = Vector2i(int32_t(k.render_w.load()), int32_t(k.render_h.load()));
	d["output_size"] = Vector2i(int32_t(k.output_w.load()), int32_t(k.output_h.load()));
	d["optimal_size"] = Vector2i(int32_t(k.optimal_w.load()), int32_t(k.optimal_h.load()));
	d["optimal_mode"] = int64_t(k.optimal_mode.load());
	d["optimal_for"] = Vector2i(int32_t(k.optimal_for_w.load()), int32_t(k.optimal_for_h.load()));
	d["min_size"] = Vector2i(int32_t(k.min_w.load()), int32_t(k.min_h.load()));
	d["max_size"] = Vector2i(int32_t(k.max_w.load()), int32_t(k.max_h.load()));
	d["oversized"] = k.oversized.load();
	d["mv_fill_passes"] = state->fill.passes();
	d["mv_fill_problem"] = String::utf8(state->fill.problem().c_str());
	return d;
}
