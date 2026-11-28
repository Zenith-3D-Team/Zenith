extends Node
## NVIDIA DLSS Super Resolution ("NVIDIA DLSS", dlss) drawing a window's 3D through Zenith's engine hook with Zenith's
## own Streamline build and the player's own nvngx_dlss.dll (client/native/upscalers/src/dlss_upscaler.*, FSR 4 plan
## step 7, tools/dlss/README.md). Settings.apply_window_scales asks for it (use / stop); everything else about
## Upscaling (the menu, greyed reasons, FSR 2.2 fallback) is upscalers.gd's. One host per window, a child of it, so
## DLSS's resources are freed with the scene tree at exit, before the renderer goes; the last host shuts Streamline down.
##
## Zenith never passes Streamline's OTA flags and its Streamline has the update check taken out (tools/dlss/patches),
## but NVIDIA's driver NGX runtime starts its own updater (nvngx_update.exe, may go online) once DLSS asks NGX
## anything (tools/dlss/README.md). So nothing here loads or asks Streamline/NVIDIA anything until the player has said
## yes (Upscalers.dlss_consent, the Upscaling prompt in settings_window.gd; --dlss-consent=yes for scripted runs):
## before that only the files' presence is looked at. native_asks counts the calls into the runtime (tests).
##
## Switches: --dlss-jitter=flip / flip-y hands DLSS the jitter negated (both / y only) in case Godot's sign differs
## from NVIDIA's (window-test fallback); --dlss-barriers=direct hands Godot's enhanced-barrier layouts over as
## states instead of the COMMON bridge; --upscaler-mv=raw hands Godot's velocity buffer over as it is (its unwritten
## (-1, -1) pixels not filled in, motion_fill.h); --dlss-fit=off draws at the render scale as asked even above DLSS's
## size for the mode (DLSS drew black while upscaling, perhaps for that: fit_scale()).

const Upscalers := preload("res://scripts/menu/upscalers.gd")
const Switches := preload("res://scripts/switches.gd")

const NODE_NAME := "ZenithDlssHost"
## The native class (client/native/upscalers/src/dlss_upscaler.*).
const DLSS_CLASS := "ZenithDlssUpscaler"
## Viewport.SCALING_3D_MODE_CUSTOM (patch 0001): by number, stock Godot has no such constant.
const SCALING_3D_MODE_CUSTOM := 6
## Frames after which a host that hasn't evaluated once gives up (FSR 2.2 for the rest of the run).
const GIVE_UP_FRAMES := 120
## Nodes told when DLSS's fitted render scale changes (_show_used_scale(); Settings' window).
const SCALE_WATCHERS := "dlss_scale_watchers"
## The files DLSS needs in the nvidia folder (vendor/nvidia): Zenith's Streamline build with its manifest, and
## NVIDIA's own DLSS the player puts there.
const FILES := ["sl.interposer.dll", "sl.common.dll", "sl.dlss.dll", "zenith-sl-manifest.txt", "nvngx_dlss.dll"]

## Set once DLSS failed this run (attach, Streamline or evaluate): Settings draws with FSR 2.2 until restart.
static var broken := false
static var broken_why := ""

## The hosts by their window's instance id (a host joins its window's children deferred: the window may be busy).
static var _hosts: Dictionary = {}

var upscaler: Object = null
var _vp: Viewport = null
var _frames := 0
## The render scale Settings asked for (before fit_scale()).
var _asked := 1.0
## The window's size last seen, and frames left to refit every frame after it changed (DLSS's output follows a frame
## or two later, then DLSS's own sizes for it).
var _seen_size := Vector2i()
var _refit_left := 0


## Calls into DLSS's runtime this run (runtime_loads / runtime_problem reaching the native side, use): 0 until
## the player's OK. Tests read it to prove nothing was loaded before.
static var native_asks := 0


## The vendor folder (holding nvidia/): Upscalers.vendor_dir (--vendor-dir, vendor/ beside the program, or the
## git-ignored dev folder in a project run). "" when there is none.
static func vendor_dir() -> String:
	return Upscalers.vendor_dir()


## The folder NVIDIA's DLSS and Zenith's Streamline build are loaded from ("" when there is none).
static func nvidia_dir() -> String:
	var v := vendor_dir()
	return v.path_join("nvidia") if v != "" else ""


## Whether the extension was built with Streamline's headers (the DLSS class can run at all).
static func built() -> bool:
	return ClassDB.class_exists(DLSS_CLASS) and bool(ClassDB.class_call_static(DLSS_CLASS, "built_with_sl"))


## Whether every file DLSS needs is in nvidia_dir() (not yet whether they load).
static func files_there() -> bool:
	var dir := nvidia_dir()
	if OS.get_name() != "Windows" or dir == "":
		return false
	for f: String in FILES:
		if not FileAccess.file_exists(dir.path_join(f)):
			return false
	return true


## Whether DLSS's runtime loads from nvidia_dir(): the player's OK given, the files there, our Streamline matching its
## manifest, NVIDIA's nvngx_dlss.dll signed by NVIDIA, sl.interposer.dll loading (no slInit yet). Without the OK it
## is false and nothing is loaded.
static func runtime_loads() -> bool:
	if not built() or not files_there() or not Upscalers.dlss_consent():
		return false
	native_asks += 1
	return bool(ClassDB.class_call_static(DLSS_CLASS, "runtime_loads", nvidia_dir()))


## Why the runtime doesn't load ("" when it does), for the log.
static func runtime_problem() -> String:
	if not built():
		return "this build has no DLSS (Streamline's headers)"
	if nvidia_dir() == "":
		return "no vendor/nvidia folder"
	if not Upscalers.dlss_consent():
		return "the player hasn't said yes to NVIDIA's updater (nothing loaded)"
	native_asks += 1
	return str(ClassDB.class_call_static(DLSS_CLASS, "runtime_problem", nvidia_dir()))


## Whether Streamline is loaded in this process (the native side's own record; false on a build without DLSS).
static func runtime_loaded() -> bool:
	return built() and ClassDB.class_has_method(DLSS_CLASS, "runtime_loaded") and bool(ClassDB.class_call_static(DLSS_CLASS, "runtime_loaded"))


## Whether DLSS can draw this run: built with Streamline's headers, the engine hook active (Zenith's Godot on
## Direct3D 12 with a rendering device) and vendor/nvidia's files loading.
static func can_run() -> bool:
	if broken or not built() or not Upscalers.dlss_consent():
		return false
	return bool(ClassDB.class_call_static(DLSS_CLASS, "available")) and runtime_loads()


## Draws root's 3D through DLSS at render `scale` (its mode from the Upscaling quality that scale is); true when it
## does. Call before setting root.scaling_3d_scale (the jitter phase count follows the scale).
static func use(root: Viewport, scale: float) -> bool:
	if root == null or not can_run():
		return false
	var host = _host(root, true)
	return host._use(root, scale)


## The render scale DLSS draws root at for the asked `scale`: DLSS's own size for the mode. Streamline makes DLSS's
## feature at the mode's optimal render size (sl.dlss dlssEntry.cpp); Upscalers' 0.67 Quality (above DLSS's 2/3) or a
## Custom scale between modes drew black, perhaps for that (unconfirmed until the window test). Presets aim at DLSS's
## optimal size on both axes; a Custom scale may go up to the maximum of DLSS's range when DLSS reports one above its
## optimal (NVIDIA's contract: any render size in [minimum, maximum]). DLSS's exact sizes once it has said them for this
## output (stats optimal_size), else NVIDIA's ratio. As asked with --dlss-fit=off.
static func fit_scale(root: Viewport, scale: float) -> float:
	if scale <= 0.0 or Switches.value("--dlss-fit") == "off" or not ClassDB.class_exists(DLSS_CLASS):
		return scale
	var quality := Upscalers.quality_for_scale(scale)
	var mode := int(ClassDB.class_call_static(DLSS_CLASS, "mode_for", quality, scale))
	var ratio := float(ClassDB.class_call_static(DLSS_CLASS, "mode_ratio", mode))
	var s := stats(root)
	var output: Vector2i = s.get("output_size", Vector2i())
	var known: bool = int(s.get("optimal_mode", -1)) == mode and s.get("optimal_for", Vector2i()) == output
	var none := Vector2i()
	return fit(scale, ratio, output, s.get("optimal_size", none) if known else none,
		s.get("min_size", none) if known else none, s.get("max_size", none) if known else none, quality == "custom")


## The 3D render size Godot draws for `output` at `scale`: the viewport keeps a 32-bit scale and truncates a 32-bit
## side x scale (renderer_viewport.cpp, int(float32(output) * float32(scale))).
static func drawn_size(output: Vector2i, scale: float) -> Vector2i:
	var f := PackedFloat32Array([scale, float(output.x), float(output.y)])
	# Two 24-bit mantissas multiply exactly in 64 bits; storing the product rounds it as a 32-bit multiply does.
	var p := PackedFloat32Array([f[0] * f[1], f[0] * f[2]])
	return Vector2i(int(p[0]), int(p[1]))


## fit_scale()'s arithmetic: the largest scale Godot draws at or under DLSS's size (`optimal`, or `max_size` for a
## Custom scale when DLSS's range goes above it) for `output`, the asked scale when that's smaller, raised to DLSS's
## minimum when it can be without going over; a 32-bit value (what the viewport keeps). Without DLSS's sizes, NVIDIA's
## `ratio` (a hair under it with no output known either).
static func fit(scale: float, ratio: float, output: Vector2i, optimal: Vector2i, min_size: Vector2i,
		max_size := Vector2i(), custom := false) -> float:
	if output.x <= 0 or output.y <= 0:
		return _f32(minf(scale, 1.0 if ratio >= 1.0 else ratio - 0.001))
	var cap := optimal
	if cap.x <= 0 or cap.y <= 0:
		cap = output if ratio >= 1.0 else Vector2i(int(float(output.x) * ratio), int(float(output.y) * ratio))
	elif custom and max_size.x >= cap.x and max_size.y >= cap.y and max_size != cap:
		cap = max_size
	var top := _scale_at_most(output, cap)
	var fitted := _f32(minf(scale, top))
	if min_size.x > 0 and min_size.y > 0 and _under(drawn_size(output, fitted), min_size):
		# Raised to DLSS's minimum on both axes if that stays at or under the cap; else at or under (the cap's scale).
		var low := _scale_at_least(output, min_size)
		fitted = low if not _over(drawn_size(output, low), cap) else top
	return fitted


## The largest 32-bit scale drawing at or under `cap` on both axes, exactly `cap` on both when one scale can.
static func _scale_at_most(output: Vector2i, cap: Vector2i) -> float:
	if cap.x >= output.x and cap.y >= output.y:
		return 1.0
	var lo := maxf(float(cap.x) / float(output.x), float(cap.y) / float(output.y))
	var hi := minf(float(cap.x + 1) / float(output.x), float(cap.y + 1) / float(output.y))
	if lo < hi:
		for c: float in [lo, (lo + hi) * 0.5]:
			if drawn_size(output, _f32(c)) == cap:
				return _f32(c)
	# No scale hits both: the tighter axis at its cap, the other under; stepped down while an axis is over.
	var s := _f32(minf(hi, 1.0))
	for _i in 64:
		if not _over(drawn_size(output, s), cap):
			break
		s = _f32(s * (1.0 - 1.0 / 8388608.0))
	return s


## The smallest 32-bit scale drawing at least `low` on both axes.
static func _scale_at_least(output: Vector2i, low: Vector2i) -> float:
	var s := _f32(maxf(float(low.x) / float(output.x), float(low.y) / float(output.y)))
	for _i in 64:
		if not _under(drawn_size(output, s), low):
			break
		s = _f32(s * (1.0 + 1.0 / 8388608.0))
	return s


static func _over(size: Vector2i, cap: Vector2i) -> bool:
	return size.x > cap.x or size.y > cap.y


static func _under(size: Vector2i, low: Vector2i) -> bool:
	return size.x < low.x or size.y < low.y


static func _f32(v: float) -> float:
	return PackedFloat32Array([v])[0]


## The Game render scaling DLSS draws at when it isn't the asked one (Settings shows it beside the slider): "" when
## they round to the same percentage.
static func scale_note(asked: float, used: float) -> String:
	if asked <= 0.0 or used <= 0.0 or roundi(asked * 100.0) == roundi(used * 100.0):
		return ""
	return "NVIDIA DLSS draws %d%%" % roundi(used * 100.0)


## Stops DLSS on root (the caller sets the next scaling mode).
static func stop(root: Viewport) -> void:
	var host = _host(root, false)
	if host != null:
		host._stop()


## Whether DLSS draws root now.
static func running(root: Viewport) -> bool:
	var host = _host(root, false)
	return host != null and host.upscaler != null and bool(host.upscaler.call("is_attached"))


## The native side's counters ({} when not running): frames, evaluated, failures, presents, problem...
static func stats(root: Viewport) -> Dictionary:
	var host = _host(root, false)
	if host == null or host.upscaler == null:
		return {}
	var s: Variant = host.upscaler.call("stats")
	return s if s is Dictionary else {}


static func _host(root: Viewport, make: bool) -> Node:
	if root == null:
		return null
	var id := root.get_instance_id()
	var host: Node = _hosts.get(id) if _hosts.has(id) and is_instance_valid(_hosts[id]) else null
	if host == null and make:
		host = (load("res://scripts/menu/dlss_host.gd") as GDScript).new()
		host.name = NODE_NAME
		_hosts[id] = host
		root.add_child.call_deferred(host)
	return host


func _use(vp: Viewport, scale: float) -> bool:
	if upscaler == null:
		upscaler = ClassDB.instantiate(DLSS_CLASS)
		if upscaler == null:
			return false
	upscaler.call("set_quality", Upscalers.quality_for_scale(scale))
	var jitter := Switches.value("--dlss-jitter")
	upscaler.call("set_jitter_sign", 1 if jitter == "flip" else (2 if jitter == "flip-y" else 0))
	upscaler.call("set_barrier_mode", 1 if Switches.value("--dlss-barriers") == "direct" else 0)
	upscaler.call("set_fill_motion_vectors", Switches.value("--upscaler-mv") != "raw")
	upscaler.call("set_fit_render_size", Switches.value("--dlss-fit") != "off")
	if not bool(upscaler.call("is_attached")):
		if vp == null or not bool(upscaler.call("attach", vp, nvidia_dir())):
			_fail("NVIDIA DLSS couldn't attach to the window (%s)" % runtime_problem())
			return false
		_frames = 0
		print("Upscaling: NVIDIA DLSS through the engine hook (Zenith's Streamline and NVIDIA's DLSS %s from %s)"
			% [str(ClassDB.class_call_static(DLSS_CLASS, "dlss_file_version", nvidia_dir())), nvidia_dir()])
	_asked = scale
	_vp = vp
	upscaler.call("set_render_scale", fit_scale(vp, scale))
	set_process(true)
	return true


func _stop() -> void:
	if upscaler != null and bool(upscaler.call("is_attached")):
		upscaler.call("detach")
	set_process(false)


func _fail(why: String) -> void:
	if not broken:
		broken = true
		broken_why = why
		print("Upscaling: %s: FSR 2.2 this run" % why)


## Gives up (FSR 2.2 for the run) when Streamline couldn't start or nothing has been evaluated for a while; keeps
## the render scale fitted to DLSS's exact sizes once it has said them (and after a resize or a mode change).
func _process(_delta: float) -> void:
	if upscaler == null or not bool(upscaler.call("is_attached")):
		set_process(false)
		return
	_frames += 1
	if _vp != null and is_instance_valid(_vp):
		var size_now := Vector2i(_vp.get_visible_rect().size)
		if size_now != _seen_size:
			_seen_size = size_now
			_refit_left = 15
	if _refit_left > 0:
		_refit_left -= 1
		_refit()
	if _frames % 30 != 0:
		return
	var s: Dictionary = upscaler.call("stats")
	var evaluated := int(s.get("evaluated", 0))
	if bool(s.get("gave_up", false)) or (evaluated == 0 and _frames >= GIVE_UP_FRAMES and int(s.get("frames", 0)) > 0):
		_fail("NVIDIA DLSS stopped (%s)" % str(s.get("problem", "nothing drawn")))
		_stop()
		var settings: GDScript = load("res://scripts/menu/settings.gd")
		if _vp is Window:
			settings.apply_window_scales(_vp as Window)
		return
	_refit()


## The render scale fitted to DLSS's sizes as they are now (fit_scale's are 32-bit values: compared exactly); Settings'
## window hears of a change (its "NVIDIA DLSS draws n%" note).
func _refit() -> void:
	if _vp == null or not is_instance_valid(_vp):
		return
	var want := fit_scale(_vp, _asked)
	if _vp.scaling_3d_scale != want:
		upscaler.call("set_render_scale", want)
		_vp.scaling_3d_scale = want
		if is_inside_tree():
			get_tree().call_group(SCALE_WATCHERS, "_show_used_scale")


func _exit_tree() -> void:
	_stop()
	upscaler = null
	for id: Variant in _hosts.keys():
		if _hosts[id] == self:
			_hosts.erase(id)
	# The last window's host: Streamline goes down while the renderer is still there.
	if _hosts.is_empty() and ClassDB.class_exists(DLSS_CLASS):
		ClassDB.class_call_static(DLSS_CLASS, "shutdown")
