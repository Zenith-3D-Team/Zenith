extends SceneTree
## The stall watchdog (scripts/debug/stall_watchdog.gd) says where the main thread stands when frames
## stop: a 2.5 s block after a crumb must be reported with that crumb, and the thread must stop.
## godot --headless --audio-driver Dummy --path client --script res://tests/stall_watchdog_test.gd -- --stall-watchdog=1

const StallWatchdog := preload("res://scripts/debug/stall_watchdog.gd")

var _frames := 0


func _initialize() -> void:
	StallWatchdog.start()


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 3:
		StallWatchdog.mark("test: blocking")
		OS.delay_msec(2500)
		StallWatchdog.mark("test: after")
	if _frames == 8:
		StallWatchdog.stop()
		print("STALL_WATCHDOG_TEST done")
		return true
	return false
