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
