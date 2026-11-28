extends Node
## AMD FSR Upscaling ("AMD FSR 4.1" fsr4, "AMD FSR 3.1" fsr3) drawing a window's 3D through Zenith's engine hook with
## AMD's own runtime (client/native/upscalers/src/fsr_upscaler.*, FSR 4 plan step 4). Settings.apply_window_scales
## asks for it (use / stop); everything else about Upscaling (the menu, greyed reasons, FSR 2.2 fallback) is
## upscalers.gd's. One host per window, a child of it, so AMD's context is freed with the scene tree at exit,
## before the renderer goes.
##
## Switches: --fsr-driver-version=on lets AMD's driver supply a newer FSR than vendor/amd's (off: pinned to the
## shipped 4.1.2 / 3.1.6); --fsr-debug turns on AMD's input checking (messages in the log); --fsr-barriers=direct
## hands Godot's enhanced-barrier layouts to AMD as states instead of the COMMON bridge (window-test fallback);
## --upscaler-mv=raw hands Godot's velocity buffer over as it is, its unwritten (-1, -1) pixels (everything that
## didn't move) not filled in from depth and the camera first (motion_fill.h; before alt/upscaler-fix: blur, flicker).

const Upscalers := preload("res://scripts/menu/upscalers.gd")
const Switches := preload("res://scripts/switches.gd")

const NODE_NAME := "ZenithFsrHost"
## Viewport.SCALING_3D_MODE_CUSTOM (patch 0001): by number, stock Godot has no such constant.
const SCALING_3D_MODE_CUSTOM := 6
## Frames after which a host that hasn't dispatched once gives up (FSR 2.2 for the rest of the run).
const GIVE_UP_FRAMES := 120

## Set once AMD FSR failed this run (attach, context or dispatch): Settings draws with FSR 2.2 until restart.
static var broken := false
static var broken_why := ""

## The hosts by their window's instance id (a host joins its window's children deferred: the window may be busy).
static var _hosts: Dictionary = {}

var upscaler: Object = null
var _vp: Viewport = null
var _frames := 0


## Whether AMD FSR can draw this run: the extension built with AMD's SDK, the engine hook active (Zenith's Godot on
## Direct3D 12 with a rendering device) and vendor/amd's DLLs loading.
static func can_run() -> bool:
	if broken or not ClassDB.class_exists(Upscalers.FSR_CLASS):
		return false
	return bool(ClassDB.class_call_static(Upscalers.FSR_CLASS, "available")) and Upscalers.amd_runtime_loads()


## Draws root's 3D through AMD FSR `value` (fsr4 / fsr3) at render `scale`, `sharpness` 0..1; true when it does.
## Call before setting root.scaling_3d_scale (the jitter phase count follows the scale).
static func use(root: Viewport, value: String, scale: float, sharpness: float) -> bool:
	if root == null or not can_run():
		return false
	var host = _host(root, true)
	return host._use(root, value, scale, sharpness)


## Stops AMD FSR on root (the caller sets the next scaling mode).
static func stop(root: Viewport) -> void:
	var host = _host(root, false)
	if host != null:
		host._stop()


## Whether AMD FSR draws root now.
static func running(root: Viewport) -> bool:
	var host = _host(root, false)
	return host != null and host.upscaler != null and bool(host.upscaler.call("is_attached"))


## The native side's counters ({} when not running): frames, dispatched, failures, version_created...
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
		host = (load("res://scripts/menu/fsr_host.gd") as GDScript).new()
		host.name = NODE_NAME
		_hosts[id] = host
		root.add_child.call_deferred(host)
	return host


func _use(vp: Viewport, value: String, scale: float, sharpness: float) -> bool:
	var version := str(Upscalers.FSR_VERSION.get(value, "3.1"))
	if upscaler == null:
		upscaler = ClassDB.instantiate(Upscalers.FSR_CLASS)
		if upscaler == null:
			return false
	upscaler.call("set_version", version)
	upscaler.call("set_sharpness", clampf(sharpness, 0.0, 1.0))
	upscaler.call("set_driver_version", Switches.on("--fsr-driver-version", false))
	upscaler.call("set_debug_checking", Switches.has("--fsr-debug"))
	upscaler.call("set_barrier_mode", 1 if Switches.value("--fsr-barriers") == "direct" else 0)
	upscaler.call("set_fill_motion_vectors", Switches.value("--upscaler-mv") != "raw")
	if not bool(upscaler.call("is_attached")):
		if vp == null or not bool(upscaler.call("attach", vp, Upscalers.amd_dir())):
			_fail("AMD FSR couldn't attach to the window")
			return false
		_frames = 0
		print("Upscaling: AMD FSR %s through the engine hook (AMD's runtime from %s)" % [version, Upscalers.amd_dir()])
	upscaler.call("set_render_scale", scale)
	_vp = vp
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


## Gives up (FSR 2.2 for the run) when AMD's context can't be made or nothing has been dispatched for a while.
func _process(_delta: float) -> void:
	if upscaler == null or not bool(upscaler.call("is_attached")):
		set_process(false)
		return
	_frames += 1
	if _frames % 30 != 0:
		return
	var s: Dictionary = upscaler.call("stats")
	var dispatched := int(s.get("dispatched", 0))
	if bool(s.get("create_failed", false)) or (dispatched == 0 and _frames >= GIVE_UP_FRAMES and int(s.get("frames", 0)) > 0):
		_fail("AMD FSR stopped (%s)" % str(s.get("problem", "nothing drawn")))
		_stop()
		var settings: GDScript = load("res://scripts/menu/settings.gd")
		if _vp is Window:
			settings.apply_window_scales(_vp as Window)
	elif dispatched > 0:
		set_process(false)


func _exit_tree() -> void:
	_stop()
	upscaler = null
	for id: Variant in _hosts.keys():
		if _hosts[id] == self:
			_hosts.erase(id)
