extends RefCounted
## The vendor upscalers behind Settings > Graphics > Upscaling's "AMD FSR 4.1" (fsr4), "AMD FSR 3.1" (fsr3) and
## "NVIDIA DLSS" (dlss), and "Automatic" (auto): what this PC and this build can run, why an entry is greyed out, and the
## Upscaling quality list (FSR 4 plan, art-src vendor-upscalers report, steps 3-4). The AMD entries draw through
## Zenith's engine hook with AMD's own runtime (ZenithFsrUpscaler, fsr_host.gd) when the build has the hook and
## vendor/amd's DLLs load; on stock Godot, or without vendor/amd, they are greyed "Not in this build" and a saved
## fsr4/fsr3/dlss draws with FSR 2.2 for the run (Settings.upscaler_in_effect), the saved choice kept.
##
## The capability checks are in client/native/upscalers (ZenithUpscalerCaps, its own GDExtension, never part
## of belt_sim), loaded here when its library is there; Zenith starts the same without it, the checks below
## standing in (the engine hook too, by its class and methods: engine_hook_in_build).

const NativeLibrary := preload("res://scripts/native_library.gd")
const Switches := preload("res://scripts/switches.gd")

## The extension's .gdextension and one of its classes (there once it is loaded).
const CONFIG := "res://native/upscalers.gdextension"
const PROBE := "ZenithUpscalerCaps"

## The values Settings > Graphics > Upscaling saves; the first three are Godot's own, as before.
const VALUES := ["bilinear", "fsr1", "fsr2", "fsr4", "fsr3", "dlss", "auto"]
## Temporal upscalers: they do their own anti-aliasing (the Anti-aliasing row greys out) and need motion vectors.
const TEMPORAL := ["fsr2", "fsr4", "fsr3", "dlss"]
## The upscalers that come from a vendor's runtime, not from Godot.
const VENDOR := ["fsr4", "fsr3", "dlss"]

## Which FSR version each AMD entry asks AMD's runtime for (plan 4.6-4.7: both live in the same signed DLLs, the
## SDK's version query/override picks): fsr_host.gd hands it to ZenithFsrUpscaler, which pins it to vendor/amd's
## version (FSR 4.1.2, 3.1.6) unless --fsr-driver-version=on lets AMD's driver supply a newer one.
const FSR_VERSION := {"fsr4": "4.1", "fsr3": "3.1"}

## NVIDIA DLSS (step 7, dlss_host.gd): drawn through the engine hook with Zenith's own Streamline build (no updater)
## and the player's own nvngx_dlss.dll in vendor/nvidia; nothing of NVIDIA's is in the repo or the download. Whether
## this build has it is caps()'s "dlss_build" (the extension built with Streamline's headers); this stands in when
## the capabilities don't say (faked ones in tests).
static var dlss_in_build := false

## The runtime files each vendor entry needs beside Zenith's program (vendor/amd, vendor/nvidia, plan 4.8). DLSS's:
## Zenith's Streamline build (tools/dlss/build_streamline.ps1) with its manifest, and NVIDIA's own nvngx_dlss.dll the
## player puts there (docs/USER-GUIDE.md); DlssHost.FILES the same.
const AMD_FILES := ["vendor/amd/amd_fidelityfx_loader_dx12.dll", "vendor/amd/amd_fidelityfx_upscaler_dx12.dll"]
const NVIDIA_FILES := ["vendor/nvidia/sl.interposer.dll", "vendor/nvidia/sl.common.dll", "vendor/nvidia/sl.dlss.dll",
	"vendor/nvidia/zenith-sl-manifest.txt", "vendor/nvidia/nvngx_dlss.dll"]

## Greyed-out reasons, shown as the entry's tooltip (never hidden).
const REASON_D3D12 := "Needs Direct3D 12 (Graphics > Renderer)"
const REASON_BUILD := "Not in this build"
const REASON_RTX := "Needs an NVIDIA RTX graphics card"
const REASON_RADEON := "Needs an AMD Radeon RX 6000 or newer"
const REASON_NVIDIA_FILES := "NVIDIA's DLSS files aren't installed (vendor/nvidia/)"
## DLSS could run but the player hasn't said yes to NVIDIA's updater yet (dlss_consent): the menu asks first
## (settings_window.gd's prompt), and until then nothing of Streamline or NVIDIA's is loaded or asked anything.
const REASON_CONSENT := "Needs your OK for NVIDIA's updater"

## The player's OK for DLSS (alt/dlss-s7c): when DLSS starts, NVIDIA's graphics driver runs NVIDIA's own updater
## (nvngx_update.exe), which may go online; Zenith can't turn it off, so it asks first. Saved as [graphics]
## dlss_consent; --dlss-consent=yes / no overrides it for one run (tests, scripted runs).
const CONSENT_SWITCH := "--dlss-consent"

## Upscaling quality (for fsr4, fsr3 and dlss): [label, value, render scale]. AMD's ratios; "custom" leaves
## Game render scaling as it is set.
const QUALITY := [
	["Native AA", "native", 1.0],
	["Quality", "quality", 0.67],
	["Balanced", "balanced", 0.59],
	["Performance", "performance", 0.5],
	["Ultra Performance", "ultra_performance", 0.33],
	["Custom", "custom", -1.0],
]

## Tests set this to a capability dictionary (see caps()) to fake a PC; empty: this PC's.
static var fake_caps: Dictionary = {}
static var _caps: Dictionary = {}
static var _tried := false


## A saved or typed upscaler name as one of VALUES: fsr4 (and fsr4.x, "amd") is FSR 4.1, fsr3 (and fsr3.x) is
## FSR 3.1, fsr2.x is fsr2, fsr is FSR 1; anything unknown is fsr1, as before.
static func normalize(value: String) -> String:
	var v := value.strip_edges().to_lower()
	if v == "bilinear" or v == "dlss" or v == "auto":
		return v
	if v == "fsr2" or v.begins_with("fsr2."):
		return "fsr2"
	if v == "fsr4" or v.begins_with("fsr4.") or v == "amd":
		return "fsr4"
	if v == "fsr3" or v.begins_with("fsr3."):
		return "fsr3"
	return "fsr1"


## Loads the extension once if its library is there (main thread only); whether its class is there.
static func ensure_native() -> bool:
	if not _tried and OS.get_thread_caller_id() == OS.get_main_thread_id():
		_tried = true
		if not ClassDB.class_exists(PROBE):
			var config := config_path()
			if config != "" and NativeLibrary.library_path(config) != "":
				GDExtensionManager.load_extension(config)
	return ClassDB.class_exists(PROBE)


## The extension's .gdextension: the project's, or the one beside an exported game's program.
static func config_path() -> String:
	if FileAccess.file_exists(CONFIG):
		return CONFIG
	var beside := OS.get_executable_path().get_base_dir().path_join(CONFIG.get_file())
	return beside if FileAccess.file_exists(beside) else ""


## What this PC and build offer, asked once: {extension, renderer ("d3d12", "vulkan"...), vendor ("amd",
## "nvidia", "intel", "other"), adapter, rtx, fsr4_gpu, amd_files, nvidia_files, engine_hook, dlss_build,
## dlss_runtime_asked}. fake_caps wins (tests); missing keys there count as no, but for dlss_consent (asked live,
## dlss_consent(), unless a test fakes it). Detected again once the player's OK changes: before it nvidia_files is
## only whether DLSS's files are there, after it whether its runtime loads (dlss_runtime_asked says which).
static func caps() -> Dictionary:
	if not fake_caps.is_empty():
		return fake_caps
	if _caps.is_empty() or (bool(_caps.get("extension", false)) and bool(_caps.get("dlss_runtime_asked", false)) != dlss_consent()):
		_caps = _detect()
	return _caps


## Forgets the cached capabilities (a test, or the extension loaded later).
static func reset() -> void:
	_caps = {}


## Whether the player has said yes to NVIDIA's updater (see REASON_CONSENT): --dlss-consent=yes / no for this run,
## else the saved [graphics] dlss_consent (off by default). Settings is loaded here, not preloaded (it preloads us).
static func dlss_consent() -> bool:
	var given := Switches.value(CONSENT_SWITCH).strip_edges().to_lower()
	if given == "yes" or given == "no":
		return given == "yes"
	var settings: GDScript = load("res://scripts/menu/settings.gd")
	return bool(settings.call("get_value", "graphics", "dlss_consent"))


## Whether the consent comes from --dlss-consent (the menu can't change it then).
static func dlss_consent_from_switch() -> bool:
	return Switches.value(CONSENT_SWITCH).strip_edges().to_lower() in ["yes", "no"]


static func _detect() -> Dictionary:
	var c := {"extension": ensure_native()}
	if c["extension"]:
		var native: Object = ClassDB.instantiate(PROBE)
		var d: Variant = native.call("capabilities", exe_dir())
		if d is Dictionary:
			c.merge(d as Dictionary, true)
		if not (native is RefCounted):
			native.free()
		# AMD's files count only when its runtime loads (vendor_dir(): --vendor-dir, beside the program, or
		# the git-ignored art-src/vendor-runtimes in a project run).
		c["fsr_sdk"] = ClassDB.class_exists(FSR_CLASS) and bool(ClassDB.class_call_static(FSR_CLASS, "built_with_sdk"))
		c["amd_files"] = amd_runtime_loads()
		# DLSS: the extension built with Streamline's headers. Its files count when they are there; whether they load
		# (sl.interposer.dll) is asked only after the player's OK for NVIDIA's updater (dlss_consent): before that
		# nothing of Streamline or NVIDIA's is loaded (dlss_host.gd).
		var dlss_host: GDScript = load("res://scripts/menu/dlss_host.gd")
		c["dlss_build"] = dlss_host.built()
		c["dlss_runtime_asked"] = dlss_consent()
		c["nvidia_files"] = dlss_host.runtime_loads() if c["dlss_runtime_asked"] else dlss_host.files_there()
		if c["dlss_build"] and not c["dlss_runtime_asked"]:
			print("Upscaling: NVIDIA DLSS waits for the player's OK for NVIDIA's updater: nothing of Streamline or NVIDIA's DLSS loaded (files %s)"
				% ("there" if c["nvidia_files"] else "not there"))
		return c
	# No extension: the same checks from here, all but the engine hook.
	var adapter := RenderingServer.get_video_adapter_name()
	c["renderer"] = RenderingServer.get_current_rendering_driver_name()
	c["vendor"] = vendor_from(RenderingServer.get_video_adapter_vendor(), adapter)
	c["adapter"] = adapter
	c["rtx"] = c["vendor"] == "nvidia" and adapter.to_upper().contains("RTX")
	c["fsr4_gpu"] = c["vendor"] == "amd" and radeon_fsr4_capable(adapter)
	# AMD FSR's runtime and DLSS are drawn by the extension: without it they can't run.
	c["amd_files"] = false
	c["dlss_build"] = false
	c["nvidia_files"] = false
	c["engine_hook"] = engine_hook_in_build()
	return c


## Whether this Godot has Zenith's upscaler hook (tools/godot-patches: the custom scaling mode, native
## callbacks and upscaler inputs); stock Godot doesn't.
static func engine_hook_in_build() -> bool:
	return ClassDB.class_exists("ViewportUpscaler") 			and ClassDB.class_has_method("RenderingDevice", "native_callback_add") 			and ClassDB.class_has_method("RenderData", "get_upscale_inputs")


## Zenith's program folder (where vendor/ sits in a download).
static func exe_dir() -> String:
	return OS.get_executable_path().get_base_dir()


## The native class that draws AMD FSR through the engine hook (client/native/upscalers/src/fsr_upscaler.*).
const FSR_CLASS := "ZenithFsrUpscaler"


## The vendor folder (holding amd/ and nvidia/): --vendor-dir=<dir> ("none": no vendor upscalers), else vendor/
## beside the program, else, in a project run (not an exported game), the main checkout's git-ignored
## art-src/vendor-runtimes (tools/release/fetch_vendor_runtimes.py fills amd/; nvidia/ is tools/dlss's build and the
## player's own nvngx_dlss.dll). "" when there is none. DlssHost.vendor_dir is this.
static func vendor_dir() -> String:
	var given := Switches.value("--vendor-dir").strip_edges()
	if given != "":
		return "" if given == "none" else given.replace("\\", "/")
	var beside := exe_dir().path_join("vendor")
	if DirAccess.dir_exists_absolute(beside):
		return beside
	if OS.has_feature("template"):
		return ""
	var dir := ProjectSettings.globalize_path("res://").rstrip("/")
	while dir != "" and dir != dir.get_base_dir():
		var dev := dir.path_join("art-src/vendor-runtimes")
		if DirAccess.dir_exists_absolute(dev.path_join("amd")) or DirAccess.dir_exists_absolute(dev.path_join("nvidia")):
			return dev
		dir = dir.get_base_dir()
	return ""


## The folder AMD's DLLs are loaded from ("" when there is none).
static func amd_dir() -> String:
	var v := vendor_dir()
	return v.path_join("amd") if v != "" else ""


## Whether AMD FSR's runtime loads from amd_dir() (the extension built with AMD's SDK, both DLLs there and loading).
static func amd_runtime_loads() -> bool:
	var dir := amd_dir()
	if OS.get_name() != "Windows" or dir == "" or not ClassDB.class_exists(FSR_CLASS):
		return false
	return bool(ClassDB.class_call_static(FSR_CLASS, "runtime_loads", dir))


static func files_there(files: Array) -> bool:
	if OS.get_name() != "Windows":
		return false
	for f: String in files:
		if not FileAccess.file_exists(exe_dir().path_join(f)):
			return false
	return true


## A GPU vendor name (Godot's adapter vendor, or its name) as "amd", "nvidia", "intel" or "other".
static func vendor_from(vendor: String, adapter := "") -> String:
	var v := (vendor + " " + adapter).to_lower()
	if v.contains("nvidia"):
		return "nvidia"
	if v.contains("amd") or v.contains("advanced micro") or v.contains("ati ") or v.contains("radeon"):
		return "amd"
	if v.contains("intel"):
		return "intel"
	return "other"


## Whether an AMD adapter name is a GPU AMD's FSR 4.1 (ML) runs on: Radeon RX 6000/7000/9000 (RDNA 2 and
## newer, "AMD Radeon RX 7800 XT"), Radeon PRO W6000 and newer ("W7900"), and the Ryzen iGPUs "Radeon 6xxM"-
## "9xxM" / "8050S/8060S" (RDNA 2 and newer; Ryzen AI). It reads the name Godot gets from the driver, so it is
## a best guess: RDNA 1 (RX 5000), Vega and older read false; an unusual or renamed OEM card may be wrong
## either way (the number is all there is: Godot exposes no device id). Wrong "no" means FSR 3.1 is used, which
## runs on every GPU, so the cost of a miss is small.
static func radeon_fsr4_capable(adapter: String) -> bool:
	var a := adapter.to_upper()
	var rx := RegEx.create_from_string("\\bRX\\s*(\\d{4})")
	var m := rx.search(a)
	if m != null:
		return int(m.get_string(1)) >= 6000
	var pro := RegEx.create_from_string("\\bW(\\d{4})")
	m = pro.search(a)
	if m != null and a.contains("RADEON"):
		return int(m.get_string(1)) >= 6000
	var igpu := RegEx.create_from_string("RADEON(?:\\(TM\\))?\\s+(?:GRAPHICS\\s+)?([6-9]\\d{2}M|80[56]0S)\\b")
	return igpu.search(a) != null


## Why `value` can't run on this PC and build ("" when it can, and for Godot's own upscalers). The build comes
## first: a stock Godot or a download without vendor/ can't run it whatever the renderer.
static func unavailable_reason(value: String, c: Dictionary = {}) -> String:
	var v := normalize(value)
	if not VENDOR.has(v):
		return ""
	if c.is_empty():
		c = caps()
	if v == "fsr4" or v == "fsr3":
		if not bool(c.get("engine_hook", false)) or not bool(c.get("amd_files", false)):
			return REASON_BUILD
		if str(c.get("renderer", "")) != "d3d12":
			return REASON_D3D12
		# FSR 3.1 runs on any D3D12 card; FSR 4.1's ML needs a Radeon RX 6000 or newer.
		if v == "fsr4" and not bool(c.get("fsr4_gpu", false)):
			return REASON_RADEON
		return ""
	# DLSS: the build (our engine hook, the extension with Streamline's headers), then the card, then NVIDIA's files
	# in vendor/nvidia (the player's own), then the renderer.
	if not bool(c.get("dlss_build", dlss_in_build)) or not bool(c.get("engine_hook", false)):
		return REASON_BUILD
	if not bool(c.get("rtx", false)):
		return REASON_RTX
	if not bool(c.get("nvidia_files", false)):
		return REASON_NVIDIA_FILES
	if str(c.get("renderer", "")) != "d3d12":
		return REASON_D3D12
	# Everything else is there: the last thing is the player's OK (asked now, not cached with the capabilities).
	if not bool(c.get("dlss_consent", dlss_consent())):
		return REASON_CONSENT
	return ""


## Whether picking `value` in Upscaling must ask the player about NVIDIA's updater first: NVIDIA DLSS, or Automatic,
## when DLSS's only missing piece is their OK (Automatic would then pick it).
static func needs_consent(value: String, c: Dictionary = {}) -> bool:
	var v := normalize(value)
	if v != "dlss" and v != "auto":
		return false
	return unavailable_reason("dlss", c) == REASON_CONSENT


## Automatic: DLSS on an RTX card on Direct3D 12 with its files and the player's OK for NVIDIA's updater, else
## FSR 4.1 on a supported Radeon, else FSR 3.1 (Direct3D 12 with AMD's files), else FSR 2.2.
static func auto_pick(c: Dictionary = {}) -> String:
	if c.is_empty():
		c = caps()
	if unavailable_reason("dlss", c) == "":
		return "dlss"
	if unavailable_reason("fsr4", c) == "":
		return "fsr4"
	if unavailable_reason("fsr3", c) == "":
		return "fsr3"
	return "fsr2"


## The upscaler that runs for a choice: auto picked; FSR 4.1 or NVIDIA DLSS on a PC that can't run it (DLSS also
## without the player's OK for NVIDIA's updater) is FSR 3.1 when that can run, and a vendor one that can't run here
## is otherwise FSR 2.2 (the saved choice is never changed).
static func resolve(choice: String, c: Dictionary = {}) -> String:
	var v := normalize(choice)
	if v == "auto":
		return auto_pick(c)
	if VENDOR.has(v) and unavailable_reason(v, c) != "":
		if (v == "fsr4" or v == "dlss") and unavailable_reason("fsr3", c) == "":
			return "fsr3"
		return "fsr2"
	return v


## Upscaling quality's render scale (-1 for custom or unknown).
static func quality_scale(quality: String) -> float:
	for q: Array in QUALITY:
		if str(q[1]) == quality:
			return float(q[2])
	return -1.0


## The quality a Game render scaling matches ("custom" when none does).
static func quality_for_scale(scale: float) -> String:
	for q: Array in QUALITY:
		if float(q[2]) > 0.0 and absf(float(q[2]) - scale) < 0.005:
			return str(q[1])
	return "custom"


## Upscaling quality's menu choices [label, value]: "Native AA (100%)" .. "Ultra Performance (33%)", "Custom".
static func quality_items() -> Array:
	var items: Array = []
	for q: Array in QUALITY:
		var scale := float(q[2])
		items.append([("%s (%d%%)" % [str(q[0]), roundi(scale * 100.0)]) if scale > 0.0 else str(q[0]), str(q[1])])
	return items
