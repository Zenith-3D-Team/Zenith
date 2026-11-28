// sl_init_probe: a headless check of Zenith's Streamline build (tools/dlss/README.md). Loads sl.interposer.dll from
// the folder given, runs slInit exactly as Zenith's ZenithDlssUpscaler does (manual hooking, no OTA flags, DLSS, engine
// type custom with Zenith's project id, no log file), reports what Streamline logs and whether DLSS's plugin loaded,
// then slShutdown. No device, no window. sl_init_probe.ps1 builds and runs it, watching for child processes (NVIDIA's
// updater nvngx_update.exe) and network connections.
//   sl_init_probe.exe <folder with sl.interposer.dll, sl.common.dll, sl.dlss.dll, zenith-sl-manifest.txt>
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <d3d12.h>
#include <dxgi.h>

#include <cstdio>
#include <cstring>
#include <string>

#include <sl.h>

static int g_plugins_loaded = 0;
static int g_errors = 0;

static void on_log(sl::LogType p_type, const char *p_message) {
	const char *kind = p_type == sl::LogType::eError ? "error" : (p_type == sl::LogType::eWarn ? "warn" : "info");
	if (p_type == sl::LogType::eError) {
		g_errors++;
	}
	if (p_message && strstr(p_message, "Loaded plugin")) {
		g_plugins_loaded++;
	}
	printf("[sl %s] %s", kind, p_message ? p_message : "");
	const size_t n = p_message ? strlen(p_message) : 0;
	if (n == 0 || p_message[n - 1] != '\n') {
		printf("\n");
	}
	fflush(stdout);
}

template <typename T>
static T *proc(HMODULE p_module, const char *p_name) {
	return reinterpret_cast<T *>(reinterpret_cast<void *>(GetProcAddress(p_module, p_name)));
}

int wmain(int argc, wchar_t **argv) {
	if (argc < 2) {
		printf("usage: sl_init_probe <folder>\n");
		return 2;
	}
	std::wstring dir = argv[1];
	while (!dir.empty() && (dir.back() == L'\\' || dir.back() == L'/')) {
		dir.pop_back();
	}
	const std::wstring interposer = dir + L"\\sl.interposer.dll";
	HMODULE mod = LoadLibraryExW(interposer.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
	if (!mod) {
		printf("probe: sl.interposer.dll doesn't load (error %lu)\n", GetLastError());
		return 3;
	}
	auto *sl_init = proc<PFun_slInit>(mod, "slInit");
	auto *sl_shutdown = proc<PFun_slShutdown>(mod, "slShutdown");
	auto *sl_is_loaded = proc<PFun_slIsFeatureLoaded>(mod, "slIsFeatureLoaded");
	if (!sl_init || !sl_shutdown || !sl_is_loaded) {
		printf("probe: entry points missing\n");
		return 3;
	}
	const wchar_t *paths[] = { dir.c_str() };
	static const sl::Feature features[] = { sl::kFeatureDLSS };
	sl::Preferences pref{};
	pref.showConsole = false;
	pref.logLevel = sl::LogLevel::eVerbose;
	pref.pathsToPlugins = paths;
	pref.numPathsToPlugins = 1;
	pref.pathToLogsAndData = nullptr;
	pref.logMessageCallback = on_log;
	pref.flags = sl::PreferenceFlags::eUseManualHooking | sl::PreferenceFlags::eDisableCLStateTracking;
	pref.featuresToLoad = features;
	pref.numFeaturesToLoad = 1;
	pref.applicationId = 0;
	pref.engine = sl::EngineType::eCustom;
	pref.engineVersion = "4.7.2";
	pref.projectId = "3b835fc5-7679-42e6-b254-3a2ffe82bfb6";
	pref.renderAPI = sl::RenderAPI::eD3D12;
	const sl::Result init = sl_init(pref, sl::kSDKVersion);
	printf("probe: slInit result %d\n", int(init));
	bool dlss_loaded = false;
	const sl::Result loaded = sl_is_loaded(sl::kFeatureDLSS, dlss_loaded);
	printf("probe: slIsFeatureLoaded(DLSS) result %d, loaded %d\n", int(loaded), dlss_loaded ? 1 : 0);
	// Give anything Streamline might have started (an updater thread) time to show up for the watcher.
	Sleep(3000);
	const sl::Result down = init == sl::Result::eOk ? sl_shutdown() : sl::Result::eOk;
	printf("probe: slShutdown result %d; plugins loaded %d, errors logged %d\n", int(down), g_plugins_loaded, g_errors);
	printf("probe: %s\n", init == sl::Result::eOk && dlss_loaded ? "OK" : "FAILED");
	return init == sl::Result::eOk && dlss_loaded ? 0 : 1;
}
