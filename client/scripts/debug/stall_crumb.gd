extends Node
## Leaves its crumb for the stall watchdog (stall_watchdog.gd) each frame at its process_priority
## (main.gd: one first and one last in the frame).

const StallWatchdog := preload("res://scripts/debug/stall_watchdog.gd")

var where := ""


func _init(at: String = "", priority: int = 0) -> void:
	where = at
	name = "StallCrumb_" + at.replace(" ", "_")
	process_priority = priority
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	StallWatchdog.crumb = where
