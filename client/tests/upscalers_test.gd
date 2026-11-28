extends SceneTree
## FSR 4 step 3 (branch alt/fsr4-s3-settings): Upscaling's new values (fsr4 "AMD FSR 4.1", fsr3 "AMD FSR 3.1" (split
## into two entries on alt/fsr-split-entries), dlss "NVIDIA DLSS", auto) and the old three unchanged; the greyed-out reasons from faked capabilities; Upscaling
## quality to Game render scaling; Automatic's pick table; a saved fsr4/dlss falling back to FSR 2.2 for the run
## with the saved choice kept; the temporal-upscaler gates (anti-aliasing, motion vectors); and the upscalers
## extension missing (or present, never with the engine hook on stock Godot). Step 4 (alt/fsr-s4-amd): AMD FSR's
## host (fsr_host.gd) refusing headless, the vendor folder (--vendor-dir, the git-ignored dev folder), and
## ZenithFsrUpscaler's runtime checks (AMD's DLLs load or not; attach refuses without a rendering device).
## Step 7 (alt/dlss-s7b): DLSS's reasons (build, card, NVIDIA's files, renderer), its host (dlss_host.gd) refusing
## headless, the nvidia folder, and ZenithDlssUpscaler's runtime checks (files missing, not our Streamline build, mode
## table; attach refuses headless). alt/dlss-s7c: the player's OK for NVIDIA's updater (dlss_consent): without it
## DLSS asks (the menu's prompt), Automatic skips it, a saved dlss falls back, and nothing of NVIDIA's is loaded.
## Passes on the official Godot and on Zenith's own build (with --vendor-dir=<art-src/vendor-runtimes>).
##   godot --headless --audio-driver Dummy --path client -s res://tests/upscalers_test.gd

const Settings := preload("res://scripts/menu/settings.gd")
const Upscalers := preload("res://scripts/menu/upscalers.gd")
const TestEnv := preload("res://tests/test_env.gd")
const DlssHost := preload("res://scripts/menu/dlss_host.gd")
const FsrHost := preload("res://scripts/menu/fsr_host.gd")
const Switches := preload("res://scripts/switches.gd")

## A PC as far as the vendor upscalers go.
const STOCK := {"extension": false, "renderer": "d3d12", "vendor": "amd", "rtx": false, "amd_files": false,
	"nvidia_files": false, "engine_hook": false}
const AMD_D3D12 := {"extension": true, "renderer": "d3d12", "vendor": "amd", "rtx": false, "fsr4_gpu": true, "amd_files": true,
	"nvidia_files": false, "engine_hook": true}
const AMD_VULKAN := {"extension": true, "renderer": "vulkan", "vendor": "amd", "rtx": false, "fsr4_gpu": true, "amd_files": true,
	"nvidia_files": false, "engine_hook": true}
const NO_VENDOR_DIR := {"extension": true, "renderer": "d3d12", "vendor": "amd", "rtx": false, "fsr4_gpu": true, "amd_files": false,
	"nvidia_files": false, "engine_hook": true}
const RADEON_OLD := {"extension": true, "renderer": "d3d12", "vendor": "amd", "rtx": false, "fsr4_gpu": false,
	"amd_files": true, "nvidia_files": false, "engine_hook": true}
const RADEON_VULKAN_OLD := {"extension": true, "renderer": "vulkan", "vendor": "amd", "rtx": false, "fsr4_gpu": false,
	"amd_files": true, "nvidia_files": false, "engine_hook": true}
const RTX_D3D12 := {"extension": true, "renderer": "d3d12", "vendor": "nvidia", "rtx": true, "amd_files": true,
	"nvidia_files": true, "engine_hook": true}
const GTX_D3D12 := {"extension": true, "renderer": "d3d12", "vendor": "nvidia", "rtx": false, "amd_files": true,
	"nvidia_files": true, "engine_hook": true}
const RTX_VULKAN := {"extension": true, "renderer": "vulkan", "vendor": "nvidia", "rtx": true, "amd_files": true,
	"nvidia_files": true, "engine_hook": true}
## An RTX PC on D3D12 with DLSS built, its files there and the player's OK for NVIDIA's updater (or not).
const RTX_OK := {"extension": true, "renderer": "d3d12", "vendor": "nvidia", "rtx": true, "amd_files": true,
	"nvidia_files": true, "engine_hook": true, "dlss_build": true, "dlss_consent": true}
const RTX_NO_OK := {"extension": true, "renderer": "d3d12", "vendor": "nvidia", "rtx": true, "amd_files": true,
	"nvidia_files": true, "engine_hook": true, "dlss_build": true, "dlss_consent": false}

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _initialize() -> void:
	TestEnv.isolate("upscalers-test")
	Settings.load_settings()
	_test_values()
	_test_reasons()
	_test_auto_pick()
	_test_gpu_names()
	_test_quality()
	_test_fallback()
	_test_consent()
	_test_extension()
	_test_upscale_inputs()
	Upscalers.fake_caps = {}
	print("UPSCALERS FAILS: %d" % fails)
	TestEnv.clean()
	quit(1 if fails > 0 else 0)


func _test_values() -> void:
	check(str(Settings.DEFAULTS["graphics"]["upscaler"]) == "fsr2", "FSR 2.2 stays the default")
	var cases := {"bilinear": "bilinear", "fsr1": "fsr1", "fsr": "fsr1", "fsr2": "fsr2", "fsr2.1": "fsr2",
		"FSR2.2": "fsr2", "fsr4": "fsr4", "fsr4.1": "fsr4", "amd": "fsr4", "fsr3": "fsr3", "fsr3.1": "fsr3", "fsr3.x": "fsr3", " FSR4 ": "fsr4", "dlss": "dlss",
		"DLSS": "dlss", "auto": "auto", "nonsense": "fsr1", "": "fsr1"}
	for k: String in cases:
		check(Upscalers.normalize(k) == str(cases[k]), "normalize(%s) -> %s, got %s" % [k, cases[k], Upscalers.normalize(k)])
	for v: String in Upscalers.VALUES:
		check(Upscalers.normalize(v) == v, "every saved value is its own: %s" % v)
	# (The menu's entries and their greying: ui_area_pbr_looks.gd; the window needs the game's autoloads.)
	# The three old values behave as before.
	Upscalers.fake_caps = STOCK
	for v: String in ["bilinear", "fsr1", "fsr2"]:
		Settings.set_value("graphics", "upscaler", v, false)
		check(Settings.upscaler_in_effect() == v, "%s runs as itself" % v)
	check(Settings.scaling_mode_for(0.67, "fsr1") == Viewport.SCALING_3D_MODE_FSR, "fsr1 below 1.0: FSR")
	check(Settings.scaling_mode_for(1.0, "fsr1") == Viewport.SCALING_3D_MODE_BILINEAR, "fsr1 at 1.0: bilinear")
	check(Settings.scaling_mode_for(0.67, "bilinear") == Viewport.SCALING_3D_MODE_BILINEAR, "bilinear")
	check(Settings.scaling_mode_for(0.67, "fsr2") == Viewport.SCALING_3D_MODE_FSR2, "fsr2 below 1.0: FSR2")
	check(Settings.scaling_mode_for(1.2, "fsr2") == Viewport.SCALING_3D_MODE_BILINEAR, "fsr2 above 1.0: bilinear")
	Settings.reset_value("graphics", "upscaler")


func _test_reasons() -> void:
	for v: String in ["bilinear", "fsr1", "fsr2", "auto"]:
		check(Upscalers.unavailable_reason(v, STOCK) == "", "%s is never greyed" % v)
	check(Upscalers.unavailable_reason("fsr4", STOCK) == Upscalers.REASON_BUILD, "stock Godot: AMD FSR 4.1 not in this build")
	check(Upscalers.unavailable_reason("fsr3", STOCK) == Upscalers.REASON_BUILD, "stock Godot: AMD FSR 3.1 not in this build")
	check(Upscalers.unavailable_reason("fsr3", NO_VENDOR_DIR) == Upscalers.REASON_BUILD, "FSR 3.1: no vendor/ folder, not in this build")
	check(Upscalers.unavailable_reason("fsr3", AMD_VULKAN) == Upscalers.REASON_D3D12, "FSR 3.1: Vulkan needs Direct3D 12")
	check(Upscalers.unavailable_reason("fsr4", NO_VENDOR_DIR) == Upscalers.REASON_BUILD, "no vendor/ folder: not in this build")
	check(Upscalers.unavailable_reason("fsr4", AMD_VULKAN) == Upscalers.REASON_D3D12, "Vulkan: needs Direct3D 12")
	check(Upscalers.unavailable_reason("fsr4", AMD_D3D12) == "", "AMD runtime on D3D12 with the hook: runs")
	check(Upscalers.unavailable_reason("fsr3", AMD_D3D12) == "" and Upscalers.unavailable_reason("fsr3", GTX_D3D12) == "", "FSR 3.1 runs on any D3D12 card")
	check(Upscalers.unavailable_reason("fsr4", GTX_D3D12) == Upscalers.REASON_RADEON, "FSR 4.1 on a GeForce: needs a Radeon RX 6000 or newer")
	check(Upscalers.unavailable_reason("fsr4", RADEON_OLD) == Upscalers.REASON_RADEON, "FSR 4.1 on an old Radeon: needs RX 6000 or newer")
	check(Upscalers.unavailable_reason("fsr4", RADEON_VULKAN_OLD) == Upscalers.REASON_D3D12, "FSR 4.1: Vulkan reason before the card reason")
	check(Upscalers.unavailable_reason("fsr4", NO_VENDOR_DIR) == Upscalers.REASON_BUILD and Upscalers.unavailable_reason("fsr4", {}) != "x", "FSR 4.1: build reason first")
	# DLSS: a build without it (no "dlss_build" in the capabilities and dlss_in_build off) whatever the PC.
	check(not Upscalers.dlss_in_build, "faked PCs: DLSS not in the build unless they say so")
	check(Upscalers.unavailable_reason("dlss", RTX_D3D12) == Upscalers.REASON_BUILD, "DLSS: not in this build even on an RTX card")
	var rtx_built := RTX_D3D12.duplicate()
	rtx_built["dlss_build"] = true
	rtx_built["dlss_consent"] = true
	check(Upscalers.unavailable_reason("dlss", rtx_built) == "", "DLSS built (caps say so) with the player's OK: RTX on D3D12 runs")
	rtx_built["engine_hook"] = false
	check(Upscalers.unavailable_reason("dlss", rtx_built) == Upscalers.REASON_BUILD, "DLSS built but stock Godot (no hook): not in this build")
	# With it in the build, the card, NVIDIA's files and renderer reasons in order.
	Upscalers.dlss_in_build = true
	check(Upscalers.unavailable_reason("dlss", RTX_D3D12) == Upscalers.REASON_CONSENT, "DLSS built: RTX on D3D12 with NVIDIA's files, no OK yet: asks")
	check(Upscalers.unavailable_reason("dlss", RTX_OK) == "", "DLSS built: RTX on D3D12 with NVIDIA's files and the OK runs")
	check(Upscalers.unavailable_reason("dlss", GTX_D3D12) == Upscalers.REASON_RTX, "DLSS built: non-RTX card")
	check(Upscalers.unavailable_reason("dlss", AMD_D3D12) == Upscalers.REASON_RTX, "DLSS built: a Radeon needs an RTX card first")
	var rtx_no_files := RTX_D3D12.duplicate()
	rtx_no_files["nvidia_files"] = false
	check(Upscalers.unavailable_reason("dlss", rtx_no_files) == Upscalers.REASON_NVIDIA_FILES, "DLSS built, RTX, no vendor/nvidia: NVIDIA's files aren't installed")
	check(Upscalers.REASON_NVIDIA_FILES.contains("vendor/nvidia"), "the files reason says where they go")
	rtx_no_files["renderer"] = "vulkan"
	check(Upscalers.unavailable_reason("dlss", rtx_no_files) == Upscalers.REASON_NVIDIA_FILES, "DLSS: the files reason before the renderer")
	check(Upscalers.unavailable_reason("dlss", RTX_VULKAN) == Upscalers.REASON_D3D12, "DLSS built: Vulkan needs D3D12")
	var vulkan_ok := RTX_VULKAN.duplicate()
	vulkan_ok["dlss_consent"] = true
	check(Upscalers.unavailable_reason("dlss", vulkan_ok) == Upscalers.REASON_D3D12, "DLSS: the OK doesn't skip the renderer")
	Upscalers.dlss_in_build = false
	check(Upscalers.vendor_from("NVIDIA") == "nvidia" and Upscalers.vendor_from("Advanced Micro Devices, Inc.") == "amd"
		and Upscalers.vendor_from("", "AMD Radeon RX 7600") == "amd" and Upscalers.vendor_from("Intel") == "intel"
		and Upscalers.vendor_from("Microsoft") == "other", "GPU vendor names")


func _test_auto_pick() -> void:
	var table := [[STOCK, "fsr2"], [NO_VENDOR_DIR, "fsr2"], [AMD_VULKAN, "fsr2"], [AMD_D3D12, "fsr4"],
		[GTX_D3D12, "fsr3"], [RTX_D3D12, "fsr3"], [RADEON_OLD, "fsr3"], [RTX_VULKAN, "fsr2"]]
	for row: Array in table:
		var got := Upscalers.auto_pick(row[0] as Dictionary)
		check(got == str(row[1]), "auto with DLSS off: %s -> %s, got %s" % [row[0], row[1], got])
	Upscalers.dlss_in_build = true
	var table2 := [[RTX_OK, "dlss"], [RTX_NO_OK, "fsr3"], [RTX_D3D12, "fsr3"], [GTX_D3D12, "fsr3"], [RTX_VULKAN, "fsr2"],
		[AMD_D3D12, "fsr4"], [STOCK, "fsr2"]]
	for row: Array in table2:
		var got := Upscalers.auto_pick(row[0] as Dictionary)
		check(got == str(row[1]), "auto with DLSS in the build: %s -> %s, got %s" % [row[0], row[1], got])
	Upscalers.dlss_in_build = false


func _test_gpu_names() -> void:
	var yes := ["AMD Radeon RX 6600", "AMD Radeon RX 7800 XT", "AMD Radeon RX 9070 XT", "AMD Radeon(TM) RX 6700M",
		"AMD Radeon PRO W7900", "AMD Radeon 780M Graphics", "AMD Radeon 890M Graphics", "AMD Radeon(TM) 8060S Graphics", "AMD Radeon 680M", "AMD Radeon 610M"]
	var no := ["AMD Radeon RX 580 Series", "AMD Radeon RX 5700 XT", "AMD Radeon RX Vega 64", "AMD Radeon(TM) Vega 8 Graphics",
		"AMD Radeon R9 380", "AMD Radeon PRO W5700", "NVIDIA GeForce RTX 4070", "Intel(R) Arc(TM) A770", ""]
	for n: String in yes:
		check(Upscalers.radeon_fsr4_capable(n), "FSR 4.1 capable: %s" % n)
	for n: String in no:
		check(not Upscalers.radeon_fsr4_capable(n), "not FSR 4.1 capable: %s" % n)
	check(Upscalers.FSR_VERSION["fsr4"] == "4.1" and Upscalers.FSR_VERSION["fsr3"] == "3.1", "the FSR version each entry requests (step 4)")


func _test_quality() -> void:
	var want := {"native": 1.0, "quality": 0.67, "balanced": 0.59, "performance": 0.5, "ultra_performance": 0.33, "custom": -1.0}
	for q: String in want:
		check(is_equal_approx(Upscalers.quality_scale(q), float(want[q])), "quality %s -> %s" % [q, want[q]])
		if float(want[q]) > 0.0:
			check(Upscalers.quality_for_scale(float(want[q])) == q, "scale %s shows %s" % [want[q], q])
	check(Upscalers.quality_for_scale(0.8) == "custom" and Upscalers.quality_for_scale(0.75) == "custom", "other scales show Custom")
	check(Upscalers.quality_scale("nonsense") < 0.0, "unknown quality sets nothing")
	var items := Upscalers.quality_items()
	check(items.size() == 6 and str(items[0][0]) == "Native AA (100%)" and str(items[2][0]) == "Balanced (59%)"
		and str(items[4][0]) == "Ultra Performance (33%)" and str(items[5][0]) == "Custom", "quality list labels: %s" % [items])
	# The scale a quality sets is what the 3D buffer gets (windowed: ratio 1).
	check(is_equal_approx(Settings.render_scale_for(Upscalers.quality_scale("ultra_performance"), 1.0), 0.33), "Ultra Performance reaches the viewport at 33%")


func _test_fallback() -> void:
	var rs_was: Variant = Settings.get_value("graphics", "render_scale")
	Settings.set_value("graphics", "render_scale", 1.0, false)
	Upscalers.fake_caps = STOCK
	for v: String in ["fsr4", "fsr3", "dlss"]:
		Settings.set_value("graphics", "upscaler", v, false)
		check(Settings.upscaler_choice() == v, "%s is the choice" % v)
		check(Settings.upscaler_in_effect() == "fsr2", "%s can't run on stock Godot: FSR 2.2 this run" % v)
		check(str(Settings.get_value("graphics", "upscaler")) == v, "the saved %s stays" % v)
		check(Settings.scaling_mode_for(1.0) == Viewport.SCALING_3D_MODE_FSR2, "%s falls back to FSR 2.2's mode" % v)
		check(Settings.temporal_upscaler_wanted() and Settings.fsr2_wanted(), "%s: anti-aliasing greyed (temporal)" % v)
	Settings.set_value("graphics", "upscaler", "auto", false)
	check(Settings.upscaler_in_effect() == "fsr2", "auto on stock Godot: FSR 2.2")
	# A saved fsr4 on a card that can't run FSR 4.1: FSR 3.1 when that can run (saved value kept), else FSR 2.2.
	Upscalers.fake_caps = GTX_D3D12
	Settings.set_value("graphics", "upscaler", "fsr4", false)
	check(Settings.upscaler_in_effect() == "fsr3" and str(Settings.get_value("graphics", "upscaler")) == "fsr4", "fsr4 on a GeForce: FSR 3.1, saved fsr4 kept")
	check(Settings.temporal_upscaler_wanted(), "the fallback is temporal too")
	Upscalers.fake_caps = RADEON_VULKAN_OLD
	check(Settings.upscaler_in_effect() == "fsr2" and str(Settings.get_value("graphics", "upscaler")) == "fsr4", "fsr4 where FSR 3.1 can't run either: FSR 2.2, saved kept")
	Upscalers.fake_caps = AMD_D3D12
	Settings.set_value("graphics", "upscaler", "fsr3", false)
	check(Settings.upscaler_in_effect() == "fsr3", "fsr3 runs as itself where it can")
	check(not FsrHost.can_run(), "headless: AMD FSR can't draw (no rendering device)")
	check(Settings.scaling_mode_for(0.67, "fsr3") == Viewport.SCALING_3D_MODE_FSR2, "fsr3 takes FSR 2.2's slot where AMD FSR can't draw")
	check(not FsrHost.use(get_root(), "fsr3", 0.67, 0.5) and not FsrHost.running(get_root()), "headless: the host refuses, nothing attached")
	check(FsrHost.stats(get_root()).is_empty(), "headless: no host stats")
	FsrHost.stop(get_root())
	Upscalers.fake_caps = STOCK
	# Once a build can run it (faked), fsr4 is itself; until step 4's engine mode it takes FSR 2.2's slot,
	# temporal (anti-aliasing greyed, motion vectors on), and orthographic views keep today's fallback.
	Upscalers.fake_caps = AMD_D3D12
	Settings.set_value("graphics", "upscaler", "fsr4", false)
	check(Settings.upscaler_in_effect() == "fsr4", "fsr4 runs where it can")
	check(Settings.temporal_upscaler_wanted(), "fsr4 is temporal")
	Settings.set_value("graphics", "upscaler", "auto", false)
	check(Settings.upscaler_in_effect() == "fsr4", "auto picks fsr4 on AMD D3D12")
	var ortho_was: bool = Settings.camera_orthographic
	Settings.camera_orthographic = true
	check(Settings.scaling_mode_for(0.67, "fsr4") == Viewport.SCALING_3D_MODE_FSR
		and Settings.scaling_mode_for(1.0, "fsr4") == Viewport.SCALING_3D_MODE_BILINEAR, "orthographic views: fsr4 falls back as FSR 2.2 does")
	Settings.camera_orthographic = ortho_was
	# Bilinear / FSR 1 aren't temporal; above 100% nothing is.
	Settings.set_value("graphics", "upscaler", "fsr1", false)
	check(not Settings.temporal_upscaler_wanted(), "FSR 1.0 is not temporal")
	Settings.set_value("graphics", "upscaler", "fsr4", false)
	Settings.set_value("graphics", "render_scale", 1.2, false)
	check(not Settings.temporal_upscaler_wanted(), "above 100% no temporal upscaler")
	# The active gate (motion vectors: belt_mv.gd, creatures, robots) follows the viewport, and the vendor flag.
	var vp := SubViewport.new()
	root.add_child(vp)
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	check(not Settings.temporal_upscaler_active(vp) and not Settings.fsr2_active(vp), "bilinear viewport: no temporal upscaler")
	Settings.vendor_upscaler_running = true
	check(Settings.temporal_upscaler_active(vp) and Settings.fsr2_active(vp), "a vendor upscaler drawing counts as temporal")
	Settings.temporal_mv_override = -1
	Settings._mv_arg = -1
	check(Settings.temporal_aa_active(vp), "motion vectors on under a vendor upscaler")
	Settings.vendor_upscaler_running = false
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	check(Settings.temporal_upscaler_active(vp) and Settings.temporal_aa_active(vp), "FSR 2.2 viewport: temporal, motion vectors on")
	vp.queue_free()
	Settings.set_value("graphics", "render_scale", rs_was, false)
	Settings.reset_value("graphics", "upscaler")


func _test_extension() -> void:
	Upscalers.fake_caps = {}
	Upscalers.reset()
	var c := Upscalers.caps()
	var has_lib := Upscalers.config_path() != "" and preload("res://scripts/native_library.gd").library_path(Upscalers.config_path()) != ""
	print("upscalers extension: %s, caps %s" % ["loaded" if c.get("extension", false) else "missing", c])
	check(bool(c.get("extension", false)) == (has_lib and ClassDB.class_exists(Upscalers.PROBE)), "the extension loads exactly when its library is there")
	var patched := ClassDB.class_exists("ViewportUpscaler")
	check(Upscalers.engine_hook_in_build() == (patched and ClassDB.class_has_method("RenderingDevice", "native_callback_add")),
		"the engine hook is asked by its class and methods")
	check(bool(c.get("engine_hook", not patched)) == Upscalers.engine_hook_in_build(), "engine hook exactly in Zenith's patched Godot")
	if not patched:
		check(not bool(c.get("engine_hook", true)), "no engine hook on stock Godot")
	check(c.has("renderer") and c.has("vendor") and c.has("fsr4_gpu") and c.has("amd_files") and c.has("nvidia_files"), "every capability is asked")
	# AMD's files count exactly when the extension (built with AMD's SDK) loads them from the vendor folder.
	check(bool(c.get("amd_files", true)) == Upscalers.amd_runtime_loads(), "amd_files is whether AMD's runtime loads")
	if not ClassDB.class_exists(Upscalers.FSR_CLASS):
		check(not bool(c.get("amd_files", true)), "no FSR class: AMD's files can't count")
	# What this build and the headless renderer allow (stock Godot: no hook; ours: the hook, maybe AMD's files).
	var amd_reason := Upscalers.REASON_BUILD
	if bool(c.get("engine_hook", false)) and bool(c.get("amd_files", false)):
		amd_reason = Upscalers.REASON_D3D12 if str(c.get("renderer", "")) != "d3d12" else ""
	check(Upscalers.unavailable_reason("fsr3") == amd_reason, "headless: AMD FSR 3.1 greyed \"%s\"" % amd_reason)
	var fsr4_reason := amd_reason if amd_reason != "" else (Upscalers.REASON_RADEON if not bool(c.get("fsr4_gpu", false)) else "")
	check(Upscalers.unavailable_reason("fsr4") == fsr4_reason, "headless: AMD FSR 4.1 greyed \"%s\"" % fsr4_reason)
	# DLSS: in the build when the extension has Streamline's headers and the engine hook is there; headless there is
	# no RTX adapter, so the card reason comes next.
	check(c.has("dlss_build") and bool(c.get("dlss_build", true)) == DlssHost.built(), "dlss_build is whether the DLSS class was built with Streamline")
	check(c.has("dlss_runtime_asked") == bool(c.get("extension", false)), "the capabilities say whether DLSS's runtime was asked")
	var dlss_reason := Upscalers.REASON_BUILD if not (bool(c.get("dlss_build", false)) and bool(c.get("engine_hook", false))) else Upscalers.REASON_RTX
	check(Upscalers.unavailable_reason("dlss") == dlss_reason, "headless: DLSS greyed \"%s\"" % dlss_reason)
	_test_dlss_no_load(c)
	_test_vendor_dir()
	_test_dlss_host()
	# A saved fsr4 here: FSR 3.1 where this build and renderer run it (ours, Direct3D 12), else FSR 2.2.
	Settings.set_value("graphics", "upscaler", "fsr4", false)
	var fsr4_now := "fsr4" if fsr4_reason == "" else ("fsr3" if amd_reason == "" else "fsr2")
	check(Settings.upscaler_in_effect() == fsr4_now, "a saved fsr4 draws with %s here" % fsr4_now)
	Settings.reset_value("graphics", "upscaler")
	if c.get("extension", false):
		var n: Object = ClassDB.instantiate(Upscalers.PROBE)
		check(int(n.call("api_version")) == 1 and bool(n.call("engine_hook")) == patched, "native: api 1, hook only in the patched build")
		check(ClassDB.class_exists("ZenithHookUpscaler"), "native: the do-nothing hook upscaler is there")
		if ClassDB.class_exists("ZenithHookUpscaler"):
			var h: Object = ClassDB.instantiate("ZenithHookUpscaler")
			check(bool(h.call("hook_in_build")) == patched, "native: hook_in_build matches the build")
			# Headless: no rendering device, so the hook can't run and attach says no without touching the viewport.
			check(not bool(h.call("hook_active")) and not bool(h.call("attach", get_root())), "native: no hook to run headless")
			check(not bool(h.call("is_attached")), "native: not attached")

		check(ClassDB.class_exists(Upscalers.FSR_CLASS), "native: the AMD FSR upscaler is there")
		if ClassDB.class_exists(Upscalers.FSR_CLASS):
			var f: Object = ClassDB.instantiate(Upscalers.FSR_CLASS)
			var nowhere := OS.get_user_data_dir().path_join("no-vendor-here/amd")
			check(not bool(ClassDB.class_call_static(Upscalers.FSR_CLASS, "runtime_loads", nowhere))
				and str(ClassDB.class_call_static(Upscalers.FSR_CLASS, "runtime_problem", nowhere)) != "", "native: no AMD runtime in an empty folder, with a reason")
			check(not bool(ClassDB.class_call_static(Upscalers.FSR_CLASS, "available")), "native: AMD FSR not available headless")
			check(not bool(f.call("attach", get_root(), Upscalers.amd_dir())) and not bool(f.call("is_attached")), "native: attach refuses headless")
			f.call("set_version", "4.1")
			check(str(f.call("get_version")) == "4.1", "native: FSR 4.1 asked for")
			f.call("set_version", "3.1.6")
			check(str(f.call("get_version")) == "3.1", "native: other versions ask for 3.1")
			f.call("set_sharpness", 3.0)
			check(is_equal_approx(float(f.call("get_sharpness")), 1.0), "native: sharpness clamped to 0..1")
			var st: Dictionary = f.call("stats")
			check(int(st.get("frames", -1)) == 0 and str(st.get("version_asked", "")) == "3.1", "native: idle stats")
			var dir := Upscalers.amd_dir()
			var sdk := bool(ClassDB.class_call_static(Upscalers.FSR_CLASS, "built_with_sdk"))
			if dir != "" and sdk and FileAccess.file_exists(dir.path_join("amd_fidelityfx_loader_dx12.dll")):
				var problem := str(ClassDB.class_call_static(Upscalers.FSR_CLASS, "runtime_problem", dir))
				check(problem == "", "native: AMD's runtime loads from %s (%s)" % [dir, problem])
				var ver := str(ClassDB.class_call_static(Upscalers.FSR_CLASS, "runtime_file_version", dir))
				print("upscalers: AMD runtime in %s, upscaler DLL %s" % [dir, ver])
				check(ver.begins_with("4.1."), "native: the shipped upscaler DLL is FSR 4.1.x (SDK 2.4.0)")

		check(ClassDB.class_exists(DlssHost.DLSS_CLASS), "native: the DLSS upscaler is there")
		if ClassDB.class_exists(DlssHost.DLSS_CLASS):
			_test_dlss_native()



## DLSS's host: headless it can't run and refuses; the nvidia folder follows --vendor-dir.
func _test_dlss_host() -> void:
	check(not DlssHost.can_run(), "headless: DLSS can't draw (no rendering device)")
	Upscalers.fake_caps = RTX_OK
	Upscalers.dlss_in_build = true
	Settings.set_value("graphics", "upscaler", "dlss", false)
	check(Settings.upscaler_in_effect() == "dlss", "dlss runs as itself where the capabilities say it can")
	check(Settings.scaling_mode_for(0.67, "dlss") == Viewport.SCALING_3D_MODE_FSR2, "dlss takes FSR 2.2's slot where DLSS can't draw")
	check(Settings.scaling_mode_for(1.2, "dlss") == Viewport.SCALING_3D_MODE_BILINEAR, "dlss above 100%: bilinear")
	Settings.reset_value("graphics", "upscaler")
	Upscalers.dlss_in_build = false
	Upscalers.fake_caps = {}
	check(not DlssHost.use(get_root(), 0.67) and not DlssHost.running(get_root()), "headless: the DLSS host refuses, nothing attached")
	check(DlssHost.stats(get_root()).is_empty(), "headless: no DLSS host stats")
	DlssHost.stop(get_root())
	Switches.set_test_args(PackedStringArray(["--vendor-dir=none"]))
	check(DlssHost.vendor_dir() == "" and DlssHost.nvidia_dir() == "" and not DlssHost.files_there() and not DlssHost.runtime_loads(), "--vendor-dir=none: no nvidia folder")
	Switches.set_test_args(PackedStringArray(["--vendor-dir=C:\\somewhere\\vendor"]))
	check(DlssHost.nvidia_dir() == "C:/somewhere/vendor/nvidia", "--vendor-dir=<dir>: that folder's nvidia/")
	check(not DlssHost.files_there(), "no DLSS files in a folder that isn't there")
	Switches.reset_cache()
	check(Switches.is_known("--dlss-jitter=flip") and Switches.is_known("--dlss-barriers=direct") and Switches.is_known("--vendor-dir=x"), "DLSS's switches are registered")


## alt/upscaler-fix: DLSS's render size fitted to the mode (a larger one drew black), the motion-vector fill and
## the fit's switches; the native setters and stats when the library is there.
func _test_upscale_inputs() -> void:
	# [asked scale, NVIDIA's ratio, output, DLSS's optimal (0: not known yet), DLSS's minimum, DLSS's maximum, custom]
	var none := Vector2i()
	var rows := [
		[0.67, 2.0 / 3.0, Vector2i(2560, 1440), none, none, none, false],
		[0.67, 2.0 / 3.0, Vector2i(2560, 1440), Vector2i(1707, 960), Vector2i(853, 480), Vector2i(2560, 1440), false],
		[0.67, 2.0 / 3.0, Vector2i(2559, 1377), Vector2i(1706, 918), none, none, false],
		[0.59, 0.58, Vector2i(3840, 2160), Vector2i(2227, 1253), none, none, false],
		[0.5, 0.5, Vector2i(1920, 1080), Vector2i(960, 540), none, none, false],
		[0.8, 2.0 / 3.0, Vector2i(1920, 1080), none, none, none, true],
		[0.3, 1.0 / 3.0, Vector2i(2560, 1440), Vector2i(853, 480), Vector2i(800, 450), none, false],
		[1.0, 1.0, Vector2i(2560, 1440), none, none, none, false],
		# Minimum = optimal (no dynamic range: Ultra Performance, DLAA): the review's 853x479 latch.
		[0.33, 1.0 / 3.0, Vector2i(2560, 1440), Vector2i(853, 480), Vector2i(853, 480), Vector2i(853, 480), false],
		[0.33, 1.0 / 3.0, Vector2i(1366, 768), Vector2i(455, 256), Vector2i(455, 256), Vector2i(455, 256), false],
		[0.33, 1.0 / 3.0, Vector2i(1517, 853), Vector2i(506, 284), Vector2i(506, 284), Vector2i(506, 284), false],
		[1.0, 1.0, Vector2i(1517, 853), Vector2i(1517, 853), Vector2i(1517, 853), Vector2i(1517, 853), false],
	]
	for row: Array in rows:
		var asked := float(row[0])
		var ratio := float(row[1])
		var out: Vector2i = row[2]
		var opt: Vector2i = row[3]
		var low: Vector2i = row[4]
		var f := DlssHost.fit(asked, ratio, out, opt, low, row[5], bool(row[6]))
		# Godot's own arithmetic (renderer_viewport.cpp): int(float32(output) x float32(scale)).
		var d := DlssHost.drawn_size(out, f)
		var cap := opt if opt.x > 0 else Vector2i(int(float(out.x) * ratio), int(float(out.y) * ratio))
		var want := DlssHost.drawn_size(out, asked)
		# Never above DLSS's size; at it on an axis when asked for more; at least the minimum where one scale can be.
		var ok := d.x <= cap.x and d.y <= cap.y and f == PackedFloat32Array([f])[0]
		if want.x >= cap.x and want.y >= cap.y:
			ok = ok and (d.x == cap.x or d.y == cap.y)
		else:
			ok = ok and d.x >= mini(want.x, cap.x) - 1
		check(ok, "DLSS fit: %s at %s -> %s (scale %s) within %s (min %s)" % [asked, out, d, f, cap, low])
	# The review's case exactly: 2560x1440 Ultra Performance, minimum = optimal = 853x480: drawn at 853x480, not 853x479.
	var up := DlssHost.drawn_size(Vector2i(2560, 1440), DlssHost.fit(0.33, 1.0 / 3.0, Vector2i(2560, 1440), Vector2i(853, 480), Vector2i(853, 480), Vector2i(853, 480)))
	check(up == Vector2i(853, 480), "DLSS fit: 2560x1440 Ultra Performance drawn at DLSS's 853x480 (%s)" % up)
	# Many outputs x modes with minimum = optimal (three roundings of DLSS's optimal): never over it, both axes on it
	# whenever one scale can, else the tighter axis on it and the other at most one pixel under.
	var outputs := [Vector2i(3840, 2160), Vector2i(2560, 1440), Vector2i(1920, 1080), Vector2i(1366, 768), Vector2i(1600, 900),
		Vector2i(2559, 1377), Vector2i(1517, 853), Vector2i(1280, 720), Vector2i(3440, 1440), Vector2i(1279, 719), Vector2i(1023, 767)]
	var exact := 0
	var total := 0
	var bad := []
	for o: Vector2i in outputs:
		for r: float in [2.0 / 3.0, 0.58, 0.5, 1.0 / 3.0]:
			for rounding in 3:
				var ox := float(o.x) * r
				var oy := float(o.y) * r
				var opt := Vector2i(roundi(ox), roundi(oy)) if rounding == 0 else (Vector2i(floori(ox), floori(oy)) if rounding == 1 else Vector2i(ceili(ox), ceili(oy)))
				var d := DlssHost.drawn_size(o, DlssHost.fit(1.0 / 3.0 if r < 0.4 else r + 0.01, r, o, opt, opt, opt))
				total += 1
				var lo := maxf(float(opt.x) / float(o.x), float(opt.y) / float(o.y))
				var hi := minf(float(opt.x + 1) / float(o.x), float(opt.y + 1) / float(o.y))
				if d == opt:
					exact += 1
				elif d.x > opt.x or d.y > opt.y or lo < hi or (d.x != opt.x and d.y != opt.y) or d.x < opt.x - 1 or d.y < opt.y - 1:
					bad.append("%s r%s %s -> %s" % [o, r, opt, d])
	print("DLSS fit, minimum = optimal: %d of %d output/mode/rounding cases drawn exactly at DLSS's size" % [exact, total])
	check(bad.is_empty(), "DLSS fit, minimum = optimal over %d output/mode/rounding cases: %d drawn exactly at DLSS's size, the rest one axis on it (%s)" % [total, exact, bad])
	# A Custom scale between modes: up to DLSS's maximum when its range goes above the optimal; a preset stays at optimal.
	var custom := DlssHost.drawn_size(Vector2i(1920, 1080), DlssHost.fit(0.8, 2.0 / 3.0, Vector2i(1920, 1080), Vector2i(1280, 720), Vector2i(960, 540), Vector2i(1920, 1080), true))
	check(custom == Vector2i(1536, 864), "DLSS fit: Custom 80% drawn at 80% within DLSS's range up to its maximum (%s)" % custom)
	var preset := DlssHost.drawn_size(Vector2i(1920, 1080), DlssHost.fit(0.8, 2.0 / 3.0, Vector2i(1920, 1080), Vector2i(1280, 720), Vector2i(960, 540), Vector2i(1920, 1080), false))
	check(preset == Vector2i(1280, 720), "DLSS fit: a preset stays at DLSS's optimal (%s)" % preset)
	var no_max := DlssHost.drawn_size(Vector2i(1920, 1080), DlssHost.fit(0.8, 2.0 / 3.0, Vector2i(1920, 1080), Vector2i(1280, 720), Vector2i(960, 540), Vector2i(1280, 720), true))
	check(no_max == Vector2i(1280, 720), "DLSS fit: Custom at DLSS's optimal when its maximum is no larger (%s)" % no_max)
	check(DlssHost.scale_note(0.8, 0.6666667) == "NVIDIA DLSS draws 67%" and DlssHost.scale_note(0.67, 0.6666667) == "" and DlssHost.scale_note(0.8, 0.8) == "",
		"Settings' note: the scale DLSS draws at when it isn't the asked one")
	check(DlssHost.fit(1.0, 1.0, Vector2i(2560, 1440), Vector2i(), Vector2i()) == 1.0, "DLSS fit: DLAA draws at the output size")
	check(DlssHost.fit(0.5, 2.0 / 3.0, Vector2i(2560, 1440), Vector2i(1707, 960), Vector2i()) == 0.5, "DLSS fit: a scale already within is kept")
	check(Switches.is_known("--dlss-fit=off") and Switches.is_known("--upscaler-mv=raw"), "the fix's switches are registered")
	Switches.set_test_args(PackedStringArray(["--dlss-fit=off"]))
	check(is_equal_approx(DlssHost.fit_scale(get_root(), 0.67), 0.67), "--dlss-fit=off: the scale as asked")
	Switches.reset_cache()
	if ClassDB.class_exists(DlssHost.DLSS_CLASS):
		var cls := DlssHost.DLSS_CLASS
		check(is_equal_approx(float(ClassDB.class_call_static(cls, "mode_ratio", 3)), 2.0 / 3.0)
			and is_equal_approx(float(ClassDB.class_call_static(cls, "mode_ratio", 2)), 0.58)
			and is_equal_approx(float(ClassDB.class_call_static(cls, "mode_ratio", 1)), 0.5)
			and is_equal_approx(float(ClassDB.class_call_static(cls, "mode_ratio", 4)), 1.0 / 3.0)
			and is_equal_approx(float(ClassDB.class_call_static(cls, "mode_ratio", 6)), 1.0), "native: NVIDIA's ratio per DLSS mode")
		# The native skip never goes on for ever: above the range skipped at most 60 frames in a row, then evaluated;
		# below the minimum (the review's 853x479 with minimum = optimal) evaluated and logged.
		var opt := Vector2i(853, 480)
		var act := func(render: Vector2i, low: Vector2i, high: Vector2i, run: int) -> int:
			return int(ClassDB.class_call_static(cls, "size_action", render, opt, low, high, run))
		check(act.call(Vector2i(853, 479), opt, opt, 0) == 1 and act.call(Vector2i(853, 479), opt, opt, 500) == 1, "native: below DLSS's minimum is evaluated (logged), not skipped")
		check(act.call(Vector2i(853, 480), opt, opt, 0) == 0, "native: DLSS's own size evaluated")
		check(act.call(Vector2i(860, 484), opt, opt, 0) == 2 and act.call(Vector2i(860, 484), opt, opt, 59) == 2
			and act.call(Vector2i(860, 484), opt, opt, 60) == 3 and act.call(Vector2i(860, 484), opt, opt, 1000) == 3,
			"native: above DLSS's range skipped for 60 frames in a row at most, then evaluated anyway")
		check(act.call(Vector2i(1200, 700), Vector2i(640, 360), Vector2i(2560, 1440), 0) == 1, "native: above the optimal but within DLSS's range evaluated (logged)")
		check(int(ClassDB.class_call_static(cls, "size_action", Vector2i(2000, 2000), Vector2i(), Vector2i(), Vector2i(), 0)) == 0, "native: nothing skipped before DLSS has said its sizes")
		var fitted := DlssHost.fit_scale(get_root(), 0.67)
		check(fitted < 2.0 / 3.0 and fitted > 0.66, "fit_scale: Quality's 0.67 drawn just under DLSS's 2/3 (%s)" % fitted)
		var d: Object = ClassDB.instantiate(cls)
		check(bool(d.call("get_fill_motion_vectors")) and bool(d.call("get_fit_render_size")), "native: DLSS fills motion vectors and fits by default")
		d.call("set_fill_motion_vectors", false)
		d.call("set_fit_render_size", false)
		var st: Dictionary = d.call("stats")
		check(not bool(d.call("get_fill_motion_vectors")) and not bool(st.get("mv_fill", true)) and not bool(st.get("fit_render_size", true)), "native: DLSS's old behaviour behind the switches")
	if ClassDB.class_exists(Upscalers.FSR_CLASS):
		var f: Object = ClassDB.instantiate(Upscalers.FSR_CLASS)
		check(bool(f.call("get_fill_motion_vectors")) and bool((f.call("stats") as Dictionary).get("mv_fill", false)), "native: AMD FSR fills motion vectors by default")
		f.call("set_fill_motion_vectors", false)
		check(not bool(f.call("get_fill_motion_vectors")), "native: AMD FSR's old behaviour behind --upscaler-mv=raw")


## ZenithDlssUpscaler headless: the mode table, the runtime checks (missing files; a manifest that doesn't match),
## and attach refusing without a rendering device.
func _test_dlss_native() -> void:
	var cls := DlssHost.DLSS_CLASS
	var modes := {"native": 6, "quality": 3, "balanced": 2, "performance": 1, "ultra_performance": 4}
	for q: String in modes:
		check(int(ClassDB.class_call_static(cls, "mode_for", q, 0.5)) == int(modes[q]), "native: DLSS mode for %s" % q)
	var by_scale := [[1.0, 6], [0.67, 3], [0.59, 2], [0.5, 1], [0.33, 4]]
	for row: Array in by_scale:
		check(int(ClassDB.class_call_static(cls, "mode_for", "custom", float(row[0]))) == int(row[1]), "native: custom scale %s -> mode %d" % [row[0], row[1]])
	check(not bool(ClassDB.class_call_static(cls, "available")), "native: DLSS not available headless")
	var d: Object = ClassDB.instantiate(cls)
	check(not bool(d.call("attach", get_root(), DlssHost.nvidia_dir())) and not bool(d.call("is_attached")), "native: attach refuses headless")
	d.call("set_quality", "balanced")
	check(str(d.call("get_quality")) == "balanced", "native: quality kept")
	var st: Dictionary = d.call("stats")
	check(int(st.get("frames", -1)) == 0 and int(st.get("mode", -1)) == 2, "native: idle stats")
	if not bool(ClassDB.class_call_static(cls, "built_with_sl")):
		check(str(ClassDB.class_call_static(cls, "runtime_problem", "C:/nowhere")) != "", "native: no Streamline headers, a reason")
		return
	# A folder with nothing in it, then fake files that aren't our Streamline build: never loaded. Once a real
	# runtime loaded this run (the dev folder's, now with the OK given for the run), any other folder is refused outright.
	Switches.set_test_args(PackedStringArray(["--dlss-consent=yes"] + (["--vendor-dir=" + Switches.value("--vendor-dir")] if Switches.value("--vendor-dir") != "" else [])))
	var loaded := DlssHost.runtime_loads()
	Switches.reset_cache()
	check(DlssHost.native_asks > 0 or not DlssHost.files_there(), "with the OK: the runtime is asked")
	if loaded:
		print("upscalers: DLSS runtime loaded from %s (nvngx_dlss.dll %s)" % [DlssHost.nvidia_dir(),
			str(ClassDB.class_call_static(cls, "dlss_file_version", DlssHost.nvidia_dir()))])
		var mods: PackedStringArray = ClassDB.class_call_static(cls, "ngx_modules_loaded")
		check(DlssHost.runtime_loaded() and mods.has("sl.interposer.dll"), "with the OK: Streamline loaded (the test hook sees it: %s)" % [mods])
	var dir := OS.get_user_data_dir().path_join("dlss-test-nvidia")
	DirAccess.make_dir_recursive_absolute(dir)
	var empty := str(ClassDB.class_call_static(cls, "runtime_problem", dir))
	check(empty.contains("another folder") if loaded else empty.contains("missing"), "native: empty nvidia folder refused (%s)" % empty)
	for f: String in DlssHost.FILES:
		var w := FileAccess.open(dir.path_join(f), FileAccess.WRITE)
		w.store_string("# not a real file\n" if f.ends_with(".txt") else "MZ not a real DLL")
		w.close()
	var fake := str(ClassDB.class_call_static(cls, "runtime_problem", dir))
	check(fake.contains("another folder") if loaded else (fake.contains("signed") or fake.contains("doesn't match") or fake.contains("can't be read")),
		"native: fake files refused (%s)" % fake)
	check(not bool(ClassDB.class_call_static(cls, "runtime_loads", dir)), "native: fake files never load")
	for f: String in DlssHost.FILES:
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)


## The player's OK for NVIDIA's updater (alt/dlss-s7c): without it DLSS asks (not greyed: the menu's prompt), Automatic
## skips it and a saved dlss falls back with the reason; with it (saved or --dlss-consent=yes) DLSS is itself;
## withdrawing turns it off again; --dlss-consent=no wins over a saved yes.
func _test_consent() -> void:
	check(Settings.DEFAULTS["graphics"]["dlss_consent"] == false, "DLSS's OK is off by default")
	check(not Upscalers.dlss_consent(), "a fresh settings file: no OK")
	check(Switches.is_known("--dlss-consent=yes"), "--dlss-consent is registered")
	var rs_was: Variant = Settings.get_value("graphics", "render_scale")
	Settings.set_value("graphics", "render_scale", 0.67, false)
	# No OK (asked live: the faked PC doesn't say).
	var live := RTX_NO_OK.duplicate()
	live.erase("dlss_consent")
	Upscalers.fake_caps = live
	check(Upscalers.unavailable_reason("dlss") == Upscalers.REASON_CONSENT, "no OK: DLSS needs it")
	check(Upscalers.needs_consent("dlss") and Upscalers.needs_consent("auto") and Upscalers.needs_consent("DLSS"), "no OK: picking DLSS or Automatic asks first")
	for v: String in ["bilinear", "fsr1", "fsr2", "fsr3", "fsr4"]:
		check(not Upscalers.needs_consent(v), "%s never asks" % v)
	check(Upscalers.auto_pick() == "fsr3", "no OK: Automatic skips DLSS (FSR 3.1 here)")
	Settings.set_value("graphics", "upscaler", "dlss", false)
	check(Settings.upscaler_in_effect() == "fsr3" and str(Settings.get_value("graphics", "upscaler")) == "dlss", "no OK: a saved dlss draws with FSR 3.1, the choice kept")
	check(Settings.scaling_mode_for(0.67) == Viewport.SCALING_3D_MODE_FSR2, "no OK: FSR 2.2's slot, never DLSS's custom mode")
	check(not DlssHost.can_run() and not DlssHost.use(get_root(), 0.67), "no OK: the DLSS host refuses")
	var no_amd := live.duplicate()
	no_amd["amd_files"] = false
	Upscalers.fake_caps = no_amd
	check(Settings.upscaler_in_effect() == "fsr2", "no OK and no AMD runtime: a saved dlss draws with FSR 2.2")
	# Not asked where DLSS can't run anyway: the real reason greys it.
	var no_files := live.duplicate()
	no_files["nvidia_files"] = false
	Upscalers.fake_caps = no_files
	check(not Upscalers.needs_consent("dlss") and not Upscalers.needs_consent("auto")
		and Upscalers.unavailable_reason("dlss") == Upscalers.REASON_NVIDIA_FILES, "no files: greyed for that, never asked")
	# The OK given in the menu (saved), then withdrawn.
	Upscalers.fake_caps = live
	Settings.set_dlss_consent(true)
	check(bool(Settings.get_value("graphics", "dlss_consent")) and Upscalers.dlss_consent(), "the OK is saved as [graphics] dlss_consent")
	var saved := ConfigFile.new()
	check(saved.load(Settings.path) == OK and bool(saved.get_value("graphics", "dlss_consent", false)), "the OK is in the settings file")
	check(Upscalers.unavailable_reason("dlss") == "" and not Upscalers.needs_consent("dlss"), "with the OK: DLSS runs, nothing asked")
	check(Settings.upscaler_in_effect() == "dlss" and Upscalers.auto_pick() == "dlss", "with the OK: a saved dlss is itself, Automatic picks it")
	check(Settings.scaling_mode_for(0.67, "dlss") == Viewport.SCALING_3D_MODE_FSR2, "with the OK, headless: FSR 2.2's slot (DLSS can't draw without a device)")
	Switches.set_test_args(PackedStringArray(["--dlss-consent=no"]))
	check(not Upscalers.dlss_consent() and Upscalers.dlss_consent_from_switch(), "--dlss-consent=no wins over a saved yes")
	check(Settings.upscaler_in_effect() == "fsr3", "--dlss-consent=no: a saved dlss falls back")
	Switches.reset_cache()
	Settings.set_dlss_consent(false)
	check(not bool(Settings.get_value("graphics", "dlss_consent")) and not Upscalers.dlss_consent(), "withdrawn: the OK is cleared")
	check(Settings.upscaler_in_effect() == "fsr3" and str(Settings.get_value("graphics", "upscaler")) == "dlss", "withdrawn: DLSS off (FSR 3.1 here), the saved choice kept")
	check(Upscalers.needs_consent("dlss"), "withdrawn: picking DLSS asks again")
	# --dlss-consent=yes for a scripted run, nothing saved.
	Switches.set_test_args(PackedStringArray(["--dlss-consent=yes"]))
	check(Upscalers.dlss_consent() and Upscalers.dlss_consent_from_switch() and not bool(Settings.get_value("graphics", "dlss_consent")),
		"--dlss-consent=yes: OK for the run, not saved")
	check(Settings.upscaler_in_effect() == "dlss", "--dlss-consent=yes: a saved dlss is itself")
	Switches.reset_cache()
	Upscalers.fake_caps = STOCK
	Settings.set_value("graphics", "render_scale", rs_was, false)
	Settings.reset_value("graphics", "upscaler")


## Before the OK nothing of Streamline or NVIDIA's is loaded or asked (the live capabilities of this build, with
## whatever vendor folder the run has): the runtime counted as "files there" only, no call into it, and none of
## sl.*.dll / nvngx*.dll in this process (ZenithDlssUpscaler.ngx_modules_loaded, GetModuleHandle).
func _test_dlss_no_load(c: Dictionary) -> void:
	check(not Upscalers.dlss_consent(), "no OK in this run")
	check(not bool(c.get("dlss_runtime_asked", false)), "the capabilities didn't ask DLSS's runtime")
	if c.has("dlss_runtime_asked"):
		check(bool(c.get("nvidia_files", true)) == DlssHost.files_there(), "no OK: nvidia_files is only whether the files are there")
	check(DlssHost.runtime_problem().begins_with("the player hasn't said yes") or not DlssHost.built() or DlssHost.nvidia_dir() == "",
		"no OK: the runtime says why it isn't asked")
	check(not DlssHost.runtime_loads(), "no OK: runtime_loads is no, without asking")
	check(DlssHost.native_asks == 0, "no OK: nothing asked of DLSS's runtime (%d calls)" % DlssHost.native_asks)
	check(not DlssHost.runtime_loaded(), "no OK: Streamline not loaded")
	if ClassDB.class_exists(DlssHost.DLSS_CLASS) and ClassDB.class_has_method(DlssHost.DLSS_CLASS, "ngx_modules_loaded"):
		var mods: PackedStringArray = ClassDB.class_call_static(DlssHost.DLSS_CLASS, "ngx_modules_loaded")
		print("upscalers: NVIDIA modules in this process before the OK: %s (vendor folder %s, files %s)"
			% [mods, DlssHost.vendor_dir(), "there" if DlssHost.files_there() else "not there"])
		check(mods.is_empty(), "no OK: no Streamline or NGX module in this process (%s)" % [mods])


## The vendor folder: --vendor-dir wins ("none": no vendor upscalers), else vendor/ beside the program, else the
## git-ignored dev folder in a project run.
func _test_vendor_dir() -> void:
	Switches.set_test_args(PackedStringArray(["--vendor-dir=none"]))
	check(Upscalers.vendor_dir() == "" and Upscalers.amd_dir() == "" and not Upscalers.amd_runtime_loads(), "--vendor-dir=none: no vendor folder")
	Switches.set_test_args(PackedStringArray(["--vendor-dir=C:\\somewhere\\vendor"]))
	check(Upscalers.vendor_dir() == "C:/somewhere/vendor" and Upscalers.amd_dir() == "C:/somewhere/vendor/amd", "--vendor-dir=<dir>: that folder's amd/")
	Switches.reset_cache()
	var v := Upscalers.vendor_dir()
	if v != "":
		check(DirAccess.dir_exists_absolute(v), "the vendor folder found exists (%s)" % v)
