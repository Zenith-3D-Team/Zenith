#include "fsr_upscaler.h"

#include "hook_upscaler.h"
#include "motion_fill.h"

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
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

#if defined(_WIN32) && defined(ZENITH_FFX)
#define ZENITH_FSR 1
#endif

#ifdef ZENITH_FSR
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#pragma comment(lib, "version.lib") // GetFileVersionInfoW

#include <d3d12.h>

// AMD FSR SDK 2.4.0's API headers (MIT), from the git-ignored SDK folder (SConstruct ffx_sdk=).
#include <dx12/ffx_api_dx12.h>
#include <ffx_api.h>
#include <ffx_upscale.h>
#endif

using namespace godot;

// The patched engine's values (tools/godot-patches/4.7.2): Viewport's custom scaling mode (0001) and
// RenderingDevice's callback resource usages (0002).
static const int SCALING_3D_MODE_CUSTOM = 6;
static const int USAGE_TEXTURE_SAMPLE = 13;
static const int USAGE_STORAGE_IMAGE_READ_WRITE = 15;

// The FSR version each entry pins to: the ones in AMD FSR SDK 2.4.0's signed amd_fidelityfx_upscaler_dx12.dll
// (FSR Upscaling 4.1.2, FSR 3.1.6). Another (newer) one is used only with --fsr-driver-version=on, or when the
// shipped one isn't offered (a different DLL in vendor/amd), said in the log.
struct PinnedVersion {
	int major, minor, patch;
};
static const PinnedVersion PINNED[] = { { 4, 1, 2 }, { 3, 1, 6 } };

// Frames a replaced AMD context waits before it is freed (more than Godot's frames in flight).
static const int64_t RETIRE_FRAMES = 4;

#ifdef ZENITH_FSR
// AMD's loader, loaded once for the run and never unloaded (contexts may live until exit).
struct FfxRuntime {
	HMODULE module = nullptr;
	PfnFfxCreateContext create = nullptr;
	PfnFfxDestroyContext destroy = nullptr;
	PfnFfxConfigure configure = nullptr;
	PfnFfxQuery query = nullptr;
	PfnFfxDispatch dispatch = nullptr;
	std::wstring dir; // The folder it was loaded from.
	bool ok() const { return module && create && destroy && configure && query && dispatch; }
};
static FfxRuntime g_runtime;
static std::mutex g_runtime_lock;

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
	return w;
}

static bool file_exists(const std::wstring &path) {
	DWORD a = GetFileAttributesW(path.c_str());
	return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

// "" when the runtime in amd_dir loads; else why not. Loads the loader for the run on success.
static String load_runtime(const String &amd_dir) {
	std::lock_guard<std::mutex> lock(g_runtime_lock);
	std::wstring dir = wide(amd_dir);
	while (!dir.empty() && dir.back() == L'\\') {
		dir.pop_back();
	}
	if (g_runtime.ok()) {
		return _wcsicmp(g_runtime.dir.c_str(), dir.c_str()) == 0 ? String() : String("AMD's runtime is already loaded from another folder");
	}
	std::wstring loader = dir + L"\\amd_fidelityfx_loader_dx12.dll";
	std::wstring upscaler = dir + L"\\amd_fidelityfx_upscaler_dx12.dll";
	if (!file_exists(loader) || !file_exists(upscaler)) {
		return "AMD's DLLs are not in " + amd_dir;
	}
	// The upscaler is loaded by the loader on first use; here it only has to be a loadable image.
	HMODULE image = LoadLibraryExW(upscaler.c_str(), nullptr, LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_AS_IMAGE_RESOURCE);
	if (!image) {
		return "amd_fidelityfx_upscaler_dx12.dll doesn't load (error " + String::num_int64(int64_t(GetLastError())) + ")";
	}
	FreeLibrary(image);
	HMODULE module = LoadLibraryExW(loader.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
	if (!module) {
		return "amd_fidelityfx_loader_dx12.dll doesn't load (error " + String::num_int64(int64_t(GetLastError())) + ")";
	}
	FfxRuntime r;
	r.module = module;
	r.create = (PfnFfxCreateContext)GetProcAddress(module, "ffxCreateContext");
	r.destroy = (PfnFfxDestroyContext)GetProcAddress(module, "ffxDestroyContext");
	r.configure = (PfnFfxConfigure)GetProcAddress(module, "ffxConfigure");
	r.query = (PfnFfxQuery)GetProcAddress(module, "ffxQuery");
	r.dispatch = (PfnFfxDispatch)GetProcAddress(module, "ffxDispatch");
	r.dir = dir;
	if (!r.ok()) {
		FreeLibrary(module);
		return "amd_fidelityfx_loader_dx12.dll lacks the AMD FSR API's entry points";
	}
	g_runtime = r;
	return String();
}

// AMD's messages (debug checking, warnings, errors) into Godot's log, the first 50.
static std::atomic<int> g_messages{ 0 };
static void on_message(uint32_t p_type, const wchar_t *p_message) {
	if (!p_message || g_messages.fetch_add(1) >= 50) {
		return;
	}
	char buf[1024];
	WideCharToMultiByte(CP_UTF8, 0, p_message, -1, buf, sizeof(buf), nullptr, nullptr);
	buf[sizeof(buf) - 1] = 0;
	UtilityFunctions::print(String("AMD FSR ") + (p_type == FFX_API_MESSAGE_TYPE_ERROR ? "error: " : "warning: ") + String::utf8(buf));
}
#endif

// RenderingDeviceDriver::NativeCallbackInfo (patch 0002), as hook_upscaler.cpp has it: plain C, append-only.
struct NativeCallbackInfo {
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

struct ZenithFsrUpscaler::State {
	// The device and queue Godot draws with (from the hook), for creating and freeing AMD's contexts.
	uint64_t device = 0;
	uint64_t queue = 0;
#ifdef ZENITH_FSR
	ID3D12Fence *fence = nullptr;
	uint64_t fence_value = 0;
	ffxContext context = nullptr;
	struct Retired {
		ffxContext context;
		int64_t frame;
	};
	std::vector<Retired> retired;
#endif
	// What the live context was made for.
	uint32_t ctx_render_w = 0, ctx_render_h = 0, ctx_output_w = 0, ctx_output_h = 0;
	uint32_t ctx_flags = 0;
	std::string ctx_version; // "4.1" or "3.1" asked for.
	bool ctx_driver = false;
	bool create_failed = false; // The last create failed for these sizes and settings: don't retry each frame.
	int64_t frame = 0; // Native callbacks run.

	std::atomic<int64_t> frames{ 0 }, dispatched{ 0 }, failures{ 0 }, creates{ 0 }, destroys{ 0 }, resets{ 0 };
	std::atomic<uint32_t> api{ 0 }, barrier_model{ 0 };
	std::atomic<int32_t> last_error{ 0 };
	std::atomic<int64_t> render_w{ 0 }, render_h{ 0 }, output_w{ 0 }, output_h{ 0 };
	std::mutex text_lock;
	std::string version_created; // AMD's provider name, e.g. "FSR 4.1.2".
	std::string version_logged;
	std::string problem; // The last failure, for stats().
	MotionFill fill; // Godot's unwritten motion vectors filled in (render thread).
};

// One frame's inputs, from the render callback to the native one (freed by it).
struct FrameParams {
	ZenithFsrUpscaler::State *state;
	float jitter_x, jitter_y;
	uint32_t render_w, render_h, output_w, output_h;
	bool reset;
	float z_near, z_far, fovy, delta_ms;
	float sharpness;
	char version[8];
	bool driver_version;
	bool debug_checking;
	int barrier_mode;
};

#ifdef ZENITH_FSR
// Waits until the GPU has run everything submitted to Godot's queue so far.
static void wait_queue(ZenithFsrUpscaler::State *s) {
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

static void destroy_context(ZenithFsrUpscaler::State *s, ffxContext &ctx) {
	if (ctx && g_runtime.ok()) {
		g_runtime.destroy(&ctx, nullptr);
		s->destroys++;
	}
	ctx = nullptr;
}

// Frees replaced contexts old enough that no frame in flight still uses them (all of them with p_all).
static void free_retired(ZenithFsrUpscaler::State *s, bool p_all) {
	bool due = false;
	for (const auto &r : s->retired) {
		due = due || p_all || s->frame - r.frame >= RETIRE_FRAMES;
	}
	if (!due) {
		return;
	}
	wait_queue(s);
	for (size_t i = 0; i < s->retired.size();) {
		if (p_all || s->frame - s->retired[i].frame >= RETIRE_FRAMES) {
			destroy_context(s, s->retired[i].context);
			s->retired.erase(s->retired.begin() + i);
		} else {
			i++;
		}
	}
}

static bool parse_version(const char *p_name, int &r_major, int &r_minor, int &r_patch) {
	for (const char *c = p_name; c && *c; c++) {
		if (*c >= '0' && *c <= '9' && sscanf(c, "%d.%d.%d", &r_major, &r_minor, &r_patch) == 3) {
			return true;
		}
	}
	return false;
}

// The version id to create for "4.1" / "3.1" (0: AMD's default), from what the runtime offers this device.
// Pinned to the shipped DLL's version unless p_driver; FSR 4.1 not offered (an older GPU) falls back to 3.1.
static uint64_t pick_version(ID3D12Device *p_device, const char *p_asked, bool p_driver, std::string &r_note) {
	uint64_t count = 0;
	ffxQueryDescGetVersions q = {};
	q.header.type = FFX_API_QUERY_DESC_TYPE_GET_VERSIONS;
	q.createDescType = FFX_API_CREATE_CONTEXT_DESC_TYPE_UPSCALE;
	q.device = p_device;
	q.outputCount = &count;
	if (g_runtime.query(nullptr, &q.header) != FFX_API_RETURN_OK || count == 0) {
		r_note = "no version list";
		return 0;
	}
	std::vector<uint64_t> ids(size_t(count), 0);
	std::vector<const char *> names(size_t(count), nullptr);
	q.versionIds = ids.data();
	q.versionNames = names.data();
	if (g_runtime.query(nullptr, &q.header) != FFX_API_RETURN_OK) {
		r_note = "no version list";
		return 0;
	}
	std::string offered;
	std::vector<int> major(size_t(count), -1), minor(size_t(count), -1), patch(size_t(count), -1);
	for (size_t i = 0; i < size_t(count); i++) {
		// Copied at once: some runtimes reuse the names' memory (AMD's docs).
		std::string name = names[i] ? names[i] : "?";
		offered += (offered.empty() ? "" : ", ") + name;
		parse_version(name.c_str(), major[i], minor[i], patch[i]);
	}
	int want_major = 3, want_minor = 1;
	sscanf(p_asked, "%d.%d", &want_major, &want_minor);
	for (int attempt = 0; attempt < 2; attempt++) {
		int pin = -1;
		for (const PinnedVersion &v : PINNED) {
			if (v.major == want_major && v.minor == want_minor) {
				pin = v.patch;
			}
		}
		int best = -1;
		for (size_t i = 0; i < size_t(count); i++) {
			if (major[i] != want_major || minor[i] != want_minor) {
				continue;
			}
			if (!p_driver && patch[i] == pin) {
				best = int(i);
				break;
			}
			if (best < 0 || patch[i] > patch[best]) {
				best = int(i);
			}
		}
		if (best >= 0) {
			char pinned[32];
			snprintf(pinned, sizeof(pinned), "%d.%d.%d", want_major, want_minor, pin);
			r_note = std::string(p_driver ? "newest offered, --fsr-driver-version=on" : (patch[best] == pin ? "pinned to vendor/amd's" : std::string("pinned ") + pinned + " not offered")) +
					(attempt ? "; FSR 4.1 not offered for this GPU" : "") + "; offered: " + offered;
			return ids[size_t(best)];
		}
		// FSR 4.1 isn't offered on this GPU (AMD's runtime picks 3.1 there too).
		want_major = 3;
		want_minor = 1;
	}
	r_note = "nothing matching offered: AMD's default; offered: " + offered;
	return 0;
}

// The FFX state for a legacy D3D12 state the hook reports, or -1 if FFX can't name it.
static int64_t ffx_state_from_d3d12(uint32_t p_state) {
	switch (p_state) {
		case D3D12_RESOURCE_STATE_COMMON:
			return FFX_API_RESOURCE_STATE_COMMON;
		case D3D12_RESOURCE_STATE_UNORDERED_ACCESS:
			return FFX_API_RESOURCE_STATE_UNORDERED_ACCESS;
		case D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE:
			return FFX_API_RESOURCE_STATE_COMPUTE_READ;
		case D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE:
			return FFX_API_RESOURCE_STATE_PIXEL_READ;
		case D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE | D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE:
			return FFX_API_RESOURCE_STATE_PIXEL_COMPUTE_READ;
		case D3D12_RESOURCE_STATE_COPY_SOURCE:
			return FFX_API_RESOURCE_STATE_COPY_SRC;
		case D3D12_RESOURCE_STATE_COPY_DEST:
			return FFX_API_RESOURCE_STATE_COPY_DEST;
		default:
			return -1;
	}
}

// The FFX state an enhanced-barrier layout stands for (barrier mode 1, "hand the layouts over as states").
static int64_t ffx_state_from_layout(uint32_t p_layout) {
	switch (p_layout) {
		case D3D12_BARRIER_LAYOUT_COMMON:
			return FFX_API_RESOURCE_STATE_COMMON;
		case D3D12_BARRIER_LAYOUT_SHADER_RESOURCE:
		case D3D12_BARRIER_LAYOUT_DIRECT_QUEUE_SHADER_RESOURCE:
			return FFX_API_RESOURCE_STATE_PIXEL_COMPUTE_READ;
		case D3D12_BARRIER_LAYOUT_UNORDERED_ACCESS:
		case D3D12_BARRIER_LAYOUT_DIRECT_QUEUE_UNORDERED_ACCESS:
			return FFX_API_RESOURCE_STATE_UNORDERED_ACCESS;
		case D3D12_BARRIER_LAYOUT_COPY_SOURCE:
		case D3D12_BARRIER_LAYOUT_DIRECT_QUEUE_COPY_SOURCE:
			return FFX_API_RESOURCE_STATE_COPY_SRC;
		case D3D12_BARRIER_LAYOUT_COPY_DEST:
		case D3D12_BARRIER_LAYOUT_DIRECT_QUEUE_COPY_DEST:
			return FFX_API_RESOURCE_STATE_COPY_DEST;
		default:
			return -1;
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

// Enhanced barriers, barrier mode 0: AMD's runtime records legacy ResourceBarrier()s, so the handed-over
// textures go from Godot's layouts to COMMON (D3D12's bridge between the two models) for the dispatch and back.
static bool bridge_layouts(ID3D12GraphicsCommandList *p_list, const NativeCallbackInfo *p_info, bool p_to_common) {
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

// Godot's D3D12 textures are typeless (one resource, many views): name the format AMD's shaders read.
static void typed_format(FfxApiResource &r) {
	switch (r.description.format) {
		case FFX_API_SURFACE_FORMAT_R16G16B16A16_TYPELESS:
			r.description.format = FFX_API_SURFACE_FORMAT_R16G16B16A16_FLOAT;
			break;
		case FFX_API_SURFACE_FORMAT_R16G16_TYPELESS:
			r.description.format = FFX_API_SURFACE_FORMAT_R16G16_FLOAT;
			break;
		case FFX_API_SURFACE_FORMAT_R32_TYPELESS:
			r.description.format = FFX_API_SURFACE_FORMAT_R32_FLOAT;
			break;
		case FFX_API_SURFACE_FORMAT_R8G8B8A8_TYPELESS:
			r.description.format = FFX_API_SURFACE_FORMAT_R8G8B8A8_UNORM;
			break;
		case FFX_API_SURFACE_FORMAT_R10G10B10A2_TYPELESS:
			r.description.format = FFX_API_SURFACE_FORMAT_R10G10B10A2_UNORM;
			break;
		case FFX_API_SURFACE_FORMAT_R32G32B32A32_TYPELESS:
			r.description.format = FFX_API_SURFACE_FORMAT_R32G32B32A32_FLOAT;
			break;
		default:
			break;
	}
}

static void fail(ZenithFsrUpscaler::State *s, int32_t p_code, const std::string &p_why) {
	s->failures++;
	s->last_error = p_code;
	std::lock_guard<std::mutex> lock(s->text_lock);
	if (s->problem != p_why) {
		s->problem = p_why;
		UtilityFunctions::print(String("AMD FSR: ") + String::utf8(p_why.c_str()));
	}
}

// (Re)creates AMD's context when the sizes, version or flags changed; false when there is none to use.
static bool ensure_context(ZenithFsrUpscaler::State *s, const FrameParams *p, ID3D12Device *p_device) {
	uint32_t flags = FFX_UPSCALE_ENABLE_HIGH_DYNAMIC_RANGE | FFX_UPSCALE_ENABLE_DEPTH_INVERTED | FFX_UPSCALE_ENABLE_AUTO_EXPOSURE;
	if (p->debug_checking) {
		flags |= FFX_UPSCALE_ENABLE_DEBUG_CHECKING;
	}
	const bool same = s->ctx_render_w == p->render_w && s->ctx_render_h == p->render_h && s->ctx_output_w == p->output_w &&
			s->ctx_output_h == p->output_h && s->ctx_flags == flags && s->ctx_version == p->version && s->ctx_driver == p->driver_version;
	if (same && (s->context || s->create_failed)) {
		return s->context != nullptr;
	}
	if (s->context) {
		s->retired.push_back({ s->context, s->frame });
		s->context = nullptr;
	}
	s->ctx_render_w = p->render_w;
	s->ctx_render_h = p->render_h;
	s->ctx_output_w = p->output_w;
	s->ctx_output_h = p->output_h;
	s->ctx_flags = flags;
	s->ctx_version = p->version;
	s->ctx_driver = p->driver_version;
	s->create_failed = true;

	std::string note;
	const uint64_t version_id = pick_version(p_device, p->version, p->driver_version, note);
	ffxOverrideVersion over = {};
	over.header.type = FFX_API_DESC_TYPE_OVERRIDE_VERSION;
	over.versionId = version_id;
	ffxCreateBackendDX12Desc backend = {};
	backend.header.type = FFX_API_CREATE_CONTEXT_DESC_TYPE_BACKEND_DX12;
	backend.header.pNext = version_id ? &over.header : nullptr;
	backend.device = p_device;
	ffxCreateContextDescUpscale desc = {};
	desc.header.type = FFX_API_CREATE_CONTEXT_DESC_TYPE_UPSCALE;
	desc.header.pNext = &backend.header;
	desc.flags = flags;
	desc.maxRenderSize = { p->render_w, p->render_h };
	desc.maxUpscaleSize = { p->output_w, p->output_h };
	desc.fpMessage = on_message;
	ffxContext ctx = nullptr;
	const ffxReturnCode_t rc = g_runtime.create(&ctx, &desc.header, nullptr);
	if (rc != FFX_API_RETURN_OK || !ctx) {
		fail(s, int32_t(rc), "creating the upscaler failed (AMD code " + std::to_string(rc) + "; " + note + ")");
		return false;
	}
	s->context = ctx;
	s->create_failed = false;
	s->creates++;
	ffxQueryGetProviderVersion provider = {};
	provider.header.type = FFX_API_QUERY_DESC_TYPE_GET_PROVIDER_VERSION;
	std::string created = "?";
	if (g_runtime.query(&s->context, &provider.header) == FFX_API_RETURN_OK && provider.versionName) {
		created = provider.versionName;
	}
	std::lock_guard<std::mutex> lock(s->text_lock);
	s->version_created = created;
	// Said once per version (resizes make new contexts of the same one).
	if (s->version_logged != created) {
		s->version_logged = created;
		UtilityFunctions::print(String("AMD FSR: running ") + String::utf8(created.c_str()) + " (asked for " + String(p->version) + "; " +
				String::utf8(note.c_str()) + "), " + String::num_int64(p->render_w) + "x" + String::num_int64(p->render_h) + " -> " +
				String::num_int64(p->output_w) + "x" + String::num_int64(p->output_h));
	}
	return true;
}
#endif

// Inside Godot's command list, at the upscale point: AMD's dispatch on the handed-over textures.
static void native_dispatch(const NativeCallbackInfo *p_info, void *p_userdata) {
	FrameParams *p = (FrameParams *)p_userdata;
	if (!p) {
		return;
	}
	ZenithFsrUpscaler::State *s = p->state;
	struct Free {
		FrameParams *p;
		~Free() { delete p; }
	} free_params{ p };
	s->frame++;
	if (!p_info || p_info->struct_size < sizeof(NativeCallbackInfo)) {
		s->failures++;
		return;
	}
	s->api = p_info->api;
	s->barrier_model = p_info->barrier_model;
	s->render_w = p->render_w;
	s->render_h = p->render_h;
	s->output_w = p->output_w;
	s->output_h = p->output_h;
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
#ifdef ZENITH_FSR
	if (!g_runtime.ok()) {
		s->failures++;
		return;
	}
	ID3D12Device *device = (ID3D12Device *)p_info->device;
	s->device = p_info->device;
	s->queue = p_info->command_queue;
	free_retired(s, false);
	if (!ensure_context(s, p, device)) {
		return;
	}
	ID3D12GraphicsCommandList *list = (ID3D12GraphicsCommandList *)p_info->command_list;
	const bool enhanced = p_info->barrier_model == 1;
	const bool bridge = enhanced && p->barrier_mode == 0;
	uint32_t ffx_states[RES_COUNT];
	for (uint32_t i = 0; i < RES_COUNT; i++) {
		int64_t st = bridge ? int64_t(FFX_API_RESOURCE_STATE_COMMON) : (enhanced ? ffx_state_from_layout(p_info->states[i]) : ffx_state_from_d3d12(p_info->states[i]));
		if (st < 0) {
			fail(s, -1, "texture " + std::to_string(i) + " is in a state AMD's API can't name (" + std::to_string(p_info->states[i]) + ")");
			return;
		}
		ffx_states[i] = uint32_t(st);
	}
	if (bridge && !bridge_layouts(list, p_info, true)) {
		fail(s, -2, "the command list has no enhanced barriers (ID3D12GraphicsCommandList7)");
		return;
	}
	ffxDispatchDescUpscale d = {};
	d.header.type = FFX_API_DISPATCH_DESC_TYPE_UPSCALE;
	d.commandList = list;
	d.color = ffxApiGetResourceDX12((ID3D12Resource *)p_info->resources[RES_COLOR], ffx_states[RES_COLOR]);
	d.depth = ffxApiGetResourceDX12((ID3D12Resource *)p_info->resources[RES_DEPTH], ffx_states[RES_DEPTH]);
	d.motionVectors = ffxApiGetResourceDX12((ID3D12Resource *)p_info->resources[RES_VELOCITY], ffx_states[RES_VELOCITY]);
	d.output = ffxApiGetResourceDX12((ID3D12Resource *)p_info->resources[RES_OUTPUT], ffx_states[RES_OUTPUT], FFX_API_RESOURCE_USAGE_UAV);
	typed_format(d.color);
	typed_format(d.depth);
	typed_format(d.motionVectors);
	typed_format(d.output);
	// Godot's motion vectors are previous minus current in UV units (scene_forward_clustered.glsl), jitter
	// already taken out, as Godot's own FSR 2.2 hands them over (effects/fsr2.cpp): scale by the render size. The
	// pixels Godot's motion pass didn't write (static objects: most of the screen) are filled in by MotionFill
	// first; FSR 2.2 does that inside its shaders, AMD's runtime can't.
	d.jitterOffset = { p->jitter_x, p->jitter_y };
	d.motionVectorScale = { float(p->render_w), float(p->render_h) };
	d.renderSize = { p->render_w, p->render_h };
	d.upscaleSize = { p->output_w, p->output_h };
	d.enableSharpening = p->sharpness > 1e-6f;
	d.sharpness = p->sharpness;
	d.frameTimeDelta = p->delta_ms;
	d.preExposure = 1.0f;
	d.reset = p->reset;
	d.cameraNear = p->z_near;
	d.cameraFar = p->z_far;
	d.cameraFovAngleVertical = p->fovy;
	d.viewSpaceToMetersFactor = 1.0f;
	d.flags = 0;
	const ffxReturnCode_t rc = g_runtime.dispatch(&s->context, &d.header);
	if (bridge) {
		bridge_layouts(list, p_info, false);
	}
	if (rc != FFX_API_RETURN_OK) {
		fail(s, int32_t(rc), "dispatch failed (AMD code " + std::to_string(rc) + ")");
		return;
	}
	if (p->reset) {
		s->resets++;
	}
	s->dispatched++;
#else
	s->failures++;
#endif
}

void ZenithFsrUpscaler::_bind_methods() {
	ClassDB::bind_static_method("ZenithFsrUpscaler", D_METHOD("built_with_sdk"), &ZenithFsrUpscaler::built_with_sdk);
	ClassDB::bind_static_method("ZenithFsrUpscaler", D_METHOD("runtime_loads", "amd_dir"), &ZenithFsrUpscaler::runtime_loads);
	ClassDB::bind_static_method("ZenithFsrUpscaler", D_METHOD("runtime_problem", "amd_dir"), &ZenithFsrUpscaler::runtime_problem);
	ClassDB::bind_static_method("ZenithFsrUpscaler", D_METHOD("runtime_file_version", "amd_dir"), &ZenithFsrUpscaler::runtime_file_version);
	ClassDB::bind_static_method("ZenithFsrUpscaler", D_METHOD("available"), &ZenithFsrUpscaler::available);
	ClassDB::bind_method(D_METHOD("attach", "viewport", "amd_dir"), &ZenithFsrUpscaler::attach);
	ClassDB::bind_method(D_METHOD("detach"), &ZenithFsrUpscaler::detach);
	ClassDB::bind_method(D_METHOD("is_attached"), &ZenithFsrUpscaler::is_attached);
	ClassDB::bind_method(D_METHOD("set_version", "version"), &ZenithFsrUpscaler::set_version);
	ClassDB::bind_method(D_METHOD("get_version"), &ZenithFsrUpscaler::get_version);
	ClassDB::bind_method(D_METHOD("set_sharpness", "sharpness"), &ZenithFsrUpscaler::set_sharpness);
	ClassDB::bind_method(D_METHOD("get_sharpness"), &ZenithFsrUpscaler::get_sharpness);
	ClassDB::bind_method(D_METHOD("set_driver_version", "on"), &ZenithFsrUpscaler::set_driver_version);
	ClassDB::bind_method(D_METHOD("get_driver_version"), &ZenithFsrUpscaler::get_driver_version);
	ClassDB::bind_method(D_METHOD("set_debug_checking", "on"), &ZenithFsrUpscaler::set_debug_checking);
	ClassDB::bind_method(D_METHOD("get_debug_checking"), &ZenithFsrUpscaler::get_debug_checking);
	ClassDB::bind_method(D_METHOD("set_barrier_mode", "mode"), &ZenithFsrUpscaler::set_barrier_mode);
	ClassDB::bind_method(D_METHOD("get_barrier_mode"), &ZenithFsrUpscaler::get_barrier_mode);
	ClassDB::bind_method(D_METHOD("set_fill_motion_vectors", "on"), &ZenithFsrUpscaler::set_fill_motion_vectors);
	ClassDB::bind_method(D_METHOD("get_fill_motion_vectors"), &ZenithFsrUpscaler::get_fill_motion_vectors);
	ClassDB::bind_method(D_METHOD("set_render_scale", "scale"), &ZenithFsrUpscaler::set_render_scale);
	ClassDB::bind_method(D_METHOD("stats"), &ZenithFsrUpscaler::stats);
}

bool ZenithFsrUpscaler::built_with_sdk() {
#ifdef ZENITH_FSR
	return true;
#else
	return false;
#endif
}

String ZenithFsrUpscaler::runtime_problem(const String &amd_dir) {
#ifdef ZENITH_FSR
	return load_runtime(amd_dir);
#else
	return "this library was built without AMD's FSR SDK";
#endif
}

bool ZenithFsrUpscaler::runtime_loads(const String &amd_dir) {
	return runtime_problem(amd_dir).is_empty();
}

String ZenithFsrUpscaler::runtime_file_version(const String &amd_dir) {
#ifdef ZENITH_FSR
	std::wstring path = wide(amd_dir) + L"\\amd_fidelityfx_upscaler_dx12.dll";
	DWORD ignored = 0;
	DWORD size = GetFileVersionInfoSizeW(path.c_str(), &ignored);
	if (size == 0) {
		return String();
	}
	std::vector<char> data(size);
	VS_FIXEDFILEINFO *info = nullptr;
	UINT len = 0;
	if (!GetFileVersionInfoW(path.c_str(), 0, size, data.data()) || !VerQueryValueW(data.data(), L"\\", (void **)&info, &len) || !info) {
		return String();
	}
	char text[64];
	snprintf(text, sizeof(text), "%u.%u.%u.%u", unsigned(HIWORD(info->dwFileVersionMS)), unsigned(LOWORD(info->dwFileVersionMS)),
			unsigned(HIWORD(info->dwFileVersionLS)), unsigned(LOWORD(info->dwFileVersionLS)));
	return String(text);
#else
	return String();
#endif
}

bool ZenithFsrUpscaler::available() {
	return built_with_sdk() && ZenithHookUpscaler::hook_active();
}

void ZenithFsrUpscaler::set_version(const String &p_version) {
	version = p_version.begins_with("4") ? "4.1" : "3.1";
}

void ZenithFsrUpscaler::set_sharpness(float p_sharpness) {
	sharpness = p_sharpness < 0.0f ? 0.0f : (p_sharpness > 1.0f ? 1.0f : p_sharpness);
}

void ZenithFsrUpscaler::set_render_scale(float p_scale) {
	if (!upscaler.is_valid() || p_scale <= 0.0f) {
		return;
	}
	// AMD's own phase count (ffxQueryDescUpscaleGetJitterPhaseCount): 8 x (display / render) squared.
	const float ratio = p_scale >= 1.0f ? 1.0f : 1.0f / p_scale;
	const int64_t phases = int64_t(8.0f * ratio * ratio);
	RenderingServer::get_singleton()->call("viewport_upscaler_set_jitter_phase_count", upscaler, phases);
}

bool ZenithFsrUpscaler::attach(Viewport *p_viewport, const String &amd_dir) {
	ERR_FAIL_NULL_V(p_viewport, false);
	if (!available() || !runtime_loads(amd_dir)) {
		return false;
	}
	detach();
	RenderingServer *rs = RenderingServer::get_singleton();
	upscaler = rs->call("viewport_upscaler_create");
	ERR_FAIL_COND_V(!upscaler.is_valid(), false);
	state = new State;
	rs->call("viewport_upscaler_set_requires_motion_vectors", upscaler, true);
	set_render_scale(float(p_viewport->get_scaling_3d_scale()));
	rs->call("viewport_upscaler_set_render_callback", upscaler, callable_mp(this, &ZenithFsrUpscaler::_render));
	viewport = p_viewport->get_viewport_rid();
	p_viewport->set("scaling_3d_mode", SCALING_3D_MODE_CUSTOM);
	rs->call("viewport_set_scaling_3d_custom_upscaler", viewport, upscaler);
	return true;
}

void ZenithFsrUpscaler::detach() {
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
// GPU has finished with AMD's contexts, so they and the state go.
void ZenithFsrUpscaler::_release_state() {
	if (!state) {
		return;
	}
	RenderingServer *rs = RenderingServer::get_singleton();
	if (rs) {
		rs->force_sync();
	}
	state->fill.release();
#ifdef ZENITH_FSR
	free_retired(state, true);
	if (state->context) {
		wait_queue(state);
		destroy_context(state, state->context);
	}
	if (state->fence) {
		state->fence->Release();
		state->fence = nullptr;
	}
#endif
	delete state;
	state = nullptr;
}

ZenithFsrUpscaler::~ZenithFsrUpscaler() {
	detach();
}

// Render thread, at the upscale point: this frame's inputs to the native dispatch.
void ZenithFsrUpscaler::_render(Object *p_render_data) {
	State *s = state;
	ERR_FAIL_NULL(s);
	s->frames++;
	ERR_FAIL_NULL(p_render_data);
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
	FrameParams *p = new FrameParams{};
	p->state = s;
	p->jitter_x = float(jitter.x);
	p->jitter_y = float(jitter.y);
	p->render_w = uint32_t(render_size.x > 0 ? render_size.x : 1);
	p->render_h = uint32_t(render_size.y > 0 ? render_size.y : 1);
	p->output_w = uint32_t(output_size.x > 0 ? output_size.x : 1);
	p->output_h = uint32_t(output_size.y > 0 ? output_size.y : 1);
	p->reset = bool(in.get("reset", false));
	p->z_near = float(in.get("z_near", 0.05));
	p->z_far = float(in.get("z_far", 4000.0));
	p->fovy = float(Math::deg_to_rad(double(in.get("fovy", 60.0))));
	// Godot hands its own FSR 2.2 seconds here; AMD's API wants milliseconds.
	p->delta_ms = float(double(in.get("delta_time", 1.0 / 60.0)) * 1000.0);
	p->sharpness = sharpness;
	CharString v = version.utf8();
	snprintf(p->version, sizeof(p->version), "%s", v.get_data());
	p->driver_version = driver_version;
	p->debug_checking = debug_checking;
	p->barrier_mode = barrier_mode;
	// Godot's unwritten motion vectors filled in (a compute pass recorded here, before the dispatch reads it).
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
	int64_t err = rd->call("native_callback_add", int64_t(intptr_t(&native_dispatch)), int64_t(intptr_t(p)), textures, usages);
	if (err != 0) {
		delete p;
		s->failures++;
	}
}

Dictionary ZenithFsrUpscaler::stats() const {
	Dictionary d;
	d["version_asked"] = version;
	d["mv_fill"] = fill_motion_vectors;
	if (!state) {
		d["frames"] = 0;
		d["dispatched"] = 0;
		d["failures"] = 0;
		return d;
	}
	const State &k = *state;
	d["frames"] = k.frames.load();
	d["dispatched"] = k.dispatched.load();
	d["failures"] = k.failures.load();
	d["creates"] = k.creates.load();
	d["destroys"] = k.destroys.load();
	d["resets"] = k.resets.load();
	d["api"] = int64_t(k.api.load());
	d["barrier_model"] = int64_t(k.barrier_model.load());
	d["last_error"] = int64_t(k.last_error.load());
	d["create_failed"] = k.create_failed;
	d["mv_fill_passes"] = state->fill.passes();
	d["mv_fill_problem"] = String::utf8(state->fill.problem().c_str());
	{
		std::lock_guard<std::mutex> lock(state->text_lock);
		d["version_created"] = String::utf8(k.version_created.c_str());
		d["problem"] = String::utf8(k.problem.c_str());
	}
	d["render_size"] = Vector2i(int32_t(k.render_w.load()), int32_t(k.render_h.load()));
	d["output_size"] = Vector2i(int32_t(k.output_w.load()), int32_t(k.output_h.load()));
	return d;
}
