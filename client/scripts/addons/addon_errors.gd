extends Logger
## Catches the script errors of add-ons (docs/ADDONS.md, "Testing") for their pages in the Add-ons window:
## a downloaded Zenith has no console to show them in. Logger came with Godot 4.5, so addon_host.gd
## loads this file with load() only when ClassDB has it, never with a preload (on 4.4 it wouldn't parse,
## and the feature is simply absent there).
##
## Godot calls _log_error from any thread, for every error in Zenith: it only keeps the ones whose file
## (or, for push_error, the calling script's) starts with an add-on folder, under a mutex, and never
## prints (that would come back here). addon_host.gd takes them on the main thread (take()).

## Kept between two take()s at most: an error every frame from many places can't grow it without end.
const MOST := 200

var _mutex := Mutex.new()
var _prefixes := PackedStringArray()
var _pending: Array = []  # [file, line, message]
var _none: Array = []  # take()'s answer when nothing is pending (never changed)


## The add-on folders errors are kept for, ending with "/" (each as loaded and absolute: a script's
## file is the path it was loaded by, user://... for a zip's cache), set by the host as add-ons start.
func set_prefixes(list: PackedStringArray) -> void:
	_mutex.lock()
	_prefixes = list
	_mutex.unlock()


## The errors kept since the last call, oldest first: [file, line, message] each.
func take() -> Array:
	_mutex.lock()
	if _pending.is_empty():  # most frames: no new array
		_mutex.unlock()
		return _none
	var out := _pending
	_pending = []
	_mutex.unlock()
	return out


func _log_error(_function: String, file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, script_backtrace: Array[ScriptBacktrace]) -> void:
	if error_type == ERROR_TYPE_WARNING:  # push_warning and the engine's warnings: not script errors
		return
	# push_error and engine errors raised from a script name a C++ file: the script is the backtrace's top.
	if not (file.begins_with("/") or file.contains(":")) and not script_backtrace.is_empty() \
			and script_backtrace[0] != null and script_backtrace[0].get_frame_count() > 0:
		file = script_backtrace[0].get_frame_file(0)
		line = script_backtrace[0].get_frame_line(0)
	_mutex.lock()
	for p in _prefixes:
		if file.begins_with(p):
			if _pending.size() < MOST:
				_pending.append([file, line, rationale if rationale != "" else code])
			break
	_mutex.unlock()
