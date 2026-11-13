extends Node
## Stops a headless test that would otherwise never end. A child of each test scene's root, in a
## script of its own, so it still runs when the test's script (or anything it preloads) doesn't
## compile: Godot prints the parse error and then sits there with an empty node, which held
## runs up for up to 10 minutes. It also ends a test that has run longer than its limit: 300
## seconds (a UI test takes 40 alone, 150 on a loaded PC), or `-- --time-limit=<seconds>`.
##
## At the limit it asks the tree to quit with exit code 1; a main thread that never gets back to
## the loop can't answer, so a thread of its own crashes the process HARD_STOP seconds later (a
## crash exits non-zero, OS.kill would exit 0).

const DEFAULT_LIMIT := 300.0
const HARD_STOP := 20.0

var _limit := DEFAULT_LIMIT
var _thread := Thread.new()
var _stop := false


func _ready() -> void:
	if get_parent().get_script() == null:
		print("FAIL the test's script didn't compile: its error is printed above")
		print("FAILS: 1")
		get_tree().quit(1)
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--time-limit="):
			_limit = float(arg.get_slice("=", 1))
	get_tree().create_timer(_limit, true, false, true).timeout.connect(_time_up)
	_thread.start(_watch)


func _exit_tree() -> void:
	_stop = true
	if _thread.is_started():
		_thread.wait_to_finish()


func _time_up() -> void:
	print("FAIL the test ran past its time limit of %d seconds" % _limit)
	print("FAILS: 1")
	get_tree().quit(1)


func _watch() -> void:
	var end := Time.get_ticks_msec() + int((_limit + HARD_STOP) * 1000.0)
	while not _stop:
		if Time.get_ticks_msec() > end:
			print("FAIL the test's main thread stopped answering past its time limit of %d seconds" % _limit)
			OS.crash("test time limit")
		OS.delay_msec(200)
