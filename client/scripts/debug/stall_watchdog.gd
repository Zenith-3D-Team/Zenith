extends RefCounted
## A thread that notices the main thread standing still (no new frame for STALL_SEC) and says in the
## log where it last was: the crumb the main thread left (mark()), e.g. a step of main.gd's start, a
## part of world.gd's frame, or "frame end" (every script of the frame done: then the engine itself,
## drawing or the GPU, is what waits). Written for a start that hung after the add-ons with nothing in
## the log; the log flushes each line, so the line is there even if the window is then closed.
## --stall-watchdog=off: no thread. --stall-watchdog=<seconds>: the wait before it speaks (default 5).

const Switches := preload("res://scripts/switches.gd")

const STALL_SEC := 5.0
const REPEAT_SEC := 15.0

static var crumb := "start"
static var _thread: Thread
static var _quit := false
static var _wait_sec := STALL_SEC


## The main thread's whereabouts, for the watchdog's line (cheap: one string kept).
static func mark(where: String) -> void:
	crumb = where


static func start() -> void:
	if _thread != null:
		return
	for arg in Switches.args():
		if arg == "--stall-watchdog=off":
			return
		if arg.begins_with("--stall-watchdog=") and arg.get_slice("=", 1).is_valid_float():
			_wait_sec = maxf(1.0, float(arg.get_slice("=", 1)))
	_quit = false
	_thread = Thread.new()
	_thread.start(_watch, Thread.PRIORITY_LOW)


static func stop() -> void:
	if _thread == null:
		return
	_quit = true
	_thread.wait_to_finish()
	_thread = null


static func _watch() -> void:
	var last_frame := Engine.get_process_frames()
	var since := Time.get_ticks_msec()
	var told := 0.0
	while not _quit:
		OS.delay_msec(250)
		var frame := Engine.get_process_frames()
		var now := Time.get_ticks_msec()
		if frame != last_frame:
			if told > 0.0:
				print("[stall-watchdog] the main thread moved again after %.1f s (frame %d)" % [(now - since) / 1000.0, frame])
			last_frame = frame
			since = now
			told = 0.0
			continue
		var stood := (now - since) / 1000.0
		if stood >= _wait_sec and (told == 0.0 or stood - told >= REPEAT_SEC):
			told = stood
			print("[stall-watchdog] no new frame for %.0f s (frame %d), the main thread last at: %s" % [stood, frame, crumb])

