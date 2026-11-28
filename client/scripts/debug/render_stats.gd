extends RefCounted
## The renderer's numbers for the debug overlay, the debug menu's Render tab and Settings' Recommend (draw
## calls, triangles, objects, video memory, a viewport's view and shadow passes, its measured CPU and GPU
## times), read without making the main thread wait for the render thread.
##
## With "Render on a separate thread" (thread model 2) every RenderingServer read from the main thread
## (get_rendering_info, viewport_get_render_info, Performance's RENDER_* monitors) waits for the render thread
## to finish its frame: 15 -> 76 ms frames (art-src stutter-live). Then the numbers are read ON the render thread
## (call_on_render_thread, where those calls answer at once) into a shared copy the main thread reads: a frame
## or two old. Otherwise (one thread) they are read directly, as before.
## `--render-reads=old`: read directly whatever the thread model (the old waits).

const Switches := preload("res://scripts/switches.gd")

static var old := Switches.has("--render-reads=old")
static var _mutex := Mutex.new()
## [values (Dictionary), whether a read is queued (Array of one bool)]: shared with the render thread's lambda.
static var _last := {}
static var _queued := [false]
static var _asked_usec := 0


## Whether the renderer runs on its own thread (reads from the main thread wait for it).
static func threaded() -> bool:
	return int(ProjectSettings.get_setting("rendering/driver/threads/thread_model", 1)) == 2


## The numbers: keys draws, prims, objects, vmem (bytes), view_draws, view_prims, shadow_draws, shadow_prims,
## gpu_ms, cpu_ms (the last four only with a valid `vp`). Threaded: the last ones read on the render thread
## (empty at first: use .get(key, 0)), a new read asked at most every `every` seconds.
static func read(vp: RID = RID(), every := 0.0) -> Dictionary:
	if old or not threaded():
		return _read_now(vp)
	_mutex.lock()
	var out := _last.duplicate()
	var queued := bool(_queued[0])
	_mutex.unlock()
	var now := Time.get_ticks_usec()
	if not queued and now - _asked_usec >= int(every * 1.0e6):
		_asked_usec = now
		_queued[0] = true
		var last := _last
		var flag := _queued
		var mutex := _mutex
		var fn := func() -> void:
			var v := _read_now(vp)
			mutex.lock()
			last.merge(v, true)
			flag[0] = false
			mutex.unlock()
		RenderingServer.call_on_render_thread(fn)
	return out


static func _read_now(vp: RID) -> Dictionary:
	var v := {
		"draws": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		"prims": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
		"objects": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
		"vmem": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED),
	}
	if vp.is_valid():
		v["view_draws"] = RenderingServer.viewport_get_render_info(vp,
			RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
		v["view_prims"] = RenderingServer.viewport_get_render_info(vp,
			RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
		v["shadow_draws"] = RenderingServer.viewport_get_render_info(vp,
			RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
		v["shadow_prims"] = RenderingServer.viewport_get_render_info(vp,
			RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
		v["gpu_ms"] = RenderingServer.viewport_get_measured_render_time_gpu(vp)
		v["cpu_ms"] = RenderingServer.viewport_get_measured_render_time_cpu(vp)
	return v


# --- The renderer's own steps (the spike log's render stages) ----------------------------------------------

## The stages a spike line names, in this order, and the renderer's step names (lower case, Godot 4.7's
## RENDER_TIMESTAMP marks, render_forward_clustered.cpp) that fall in each; a step in none is "rest" (setup,
## sky, GI, the 2D canvas, between viewports; the "screen space" steps, SSAO/SSIL/SSR's, count as post).
const STAGES := ["shadows", "pre-pass", "opaque", "motion", "transparent", "post", "rest"]
const STAGE_WORDS := [
	["shadows", ["shadow"]],
	["pre-pass", ["pre-pass", "depth pre"]],
	["opaque", ["opaque pass"]],
	["motion", ["motion"]],
	["transparent", ["transparent pass"]],
	["post", ["tonemap", "fsr", "taa", "resolve", "copy", "merge specular", "sub-surface", "post transparent",
		"upscal", "dlss", "glow", "dof", "luminance", "screen space"]],
]
static var _steps_last: Array = []  # [[{step: gpu ms}, {step: cpu ms}, frame]], shared with the render thread
static var _steps_queued := [false]


## The renderer's steps of the last frame the GPU finished (a frame or two behind): [{step: gpu ms},
## {step: cpu ms}], each step named by the mark that starts it and summed over the frame's viewports;
## [] when Godot wasn't started with --gpu-profile (no marks), headless (no RenderingDevice), or nothing new.
## Threaded: read on the render thread (the RenderingDevice belongs to it) into a shared copy, one frame old.
static func steps() -> Array:
	if old or not threaded():
		return _steps_now()
	_mutex.lock()
	var out: Array = _steps_last[0] if not _steps_last.is_empty() else []
	var queued := bool(_steps_queued[0])
	_mutex.unlock()
	if not queued:
		_steps_queued[0] = true
		var last := _steps_last
		var flag := _steps_queued
		var mutex := _mutex
		var fn := func() -> void:
			var v := _steps_now()
			mutex.lock()
			if not v.is_empty():
				last.clear()
				last.append(v)
			flag[0] = false
			mutex.unlock()
		RenderingServer.call_on_render_thread(fn)
	return out


static var _steps_frame := -1


static func _steps_now() -> Array:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return []
	var n := rd.get_captured_timestamps_count()
	if n <= 2 or int(rd.get_captured_timestamps_frame()) == _steps_frame:
		return []
	_steps_frame = int(rd.get_captured_timestamps_frame())
	var gpu := {}
	var cpu := {}
	for i in range(1, n):
		var step := rd.get_captured_timestamp_name(i - 1)
		var g := (rd.get_captured_timestamp_gpu_time(i) - rd.get_captured_timestamp_gpu_time(i - 1)) / 1.0e6  # ns
		var c := (rd.get_captured_timestamp_cpu_time(i) - rd.get_captured_timestamp_cpu_time(i - 1)) / 1.0e3  # µs
		gpu[step] = float(gpu.get(step, 0.0)) + g
		cpu[step] = float(cpu.get(step, 0.0)) + c
	return [gpu, cpu]


## A step's stage (STAGES).
static func stage_of(step: String) -> String:
	var s := step.to_lower()
	for entry: Array in STAGE_WORDS:
		for w: String in entry[1]:
			if s.contains(w):
				return str(entry[0])
	return "rest"


## `steps()`'s two tables summed by stage: [[stage, cpu ms, gpu ms]] in STAGES' order, every stage listed.
static func stages(gpu: Dictionary, cpu: Dictionary) -> Array:
	var sums := {}
	for st: String in STAGES:
		sums[st] = [0.0, 0.0]
	for step: String in gpu:
		var pair: Array = sums[stage_of(step)]
		pair[1] = float(pair[1]) + float(gpu[step])
	for step: String in cpu:
		var pair: Array = sums[stage_of(step)]
		pair[0] = float(pair[0]) + float(cpu[step])
	var out: Array = []
	for st: String in STAGES:
		out.append([st, float(sums[st][0]), float(sums[st][1])])
	return out
