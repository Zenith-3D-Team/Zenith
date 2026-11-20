extends SceneTree
## sound_bank.gd's cache of decoded sounds, with the decodes on workers and the cache the main
## thread's alone (taken in when a sound is next asked for, _take_decoded): every sound asked for lands once, under the
## loop flag asked for; asking again while it decodes starts no second decode; clear_cache() while
## decodes are in flight loses none and leaves nothing stuck; the cache refills after a clear (a game
## left and another joined). Needs the player's Factorio install for the real files (skips without).
##   godot --headless --path client -s res://tests/sound_cache_test.gd
## Prints "SOUND CACHE FAILS: 0" when all pass; quits with 1 otherwise.
## With `-- --quit-in-flight` it only asks for many decodes and quits in the same frame, for a log
## check that quitting with decodes in flight neither hangs nor complains.

const SoundBank := preload("res://scripts/fx/sound_bank.gd")
const LIMIT_MSEC := 20000

var _fails := 0
var _files: Array[String] = []
var _phase := 0
var _until := 0
var _first := {}  # path -> the stream first handed out after its decode
var _quitting := false  # quit() asked for in _initialize: _process still runs a frame


func _check(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("FAIL: ", what)


func _pending() -> Dictionary:
	var script: Script = SoundBank
	return script.get("_decoding")


func _cached() -> Dictionary:
	var script: Script = SoundBank
	return script.get("_streams")


func _initialize() -> void:
	var dir := SoundBank.data_dir()
	if dir != "":
		for sub in ["base/sound", "core/sound"]:
			for f in DirAccess.get_files_at(dir.path_join(sub)):
				if f.ends_with(".ogg") and _files.size() < 40:
					_files.append(sub.path_join(f))
	if _files.size() < 8:
		print("skip: no Factorio install (", dir, ")")
		print("SOUND CACHE FAILS: 0")
		_quitting = true
		quit(0)
		return
	if "--quit-in-flight" in OS.get_cmdline_user_args():
		for f in _files:
			SoundBank.stream_soon(f)
			SoundBank.stream_soon(f, true)
		print("quitting with %d decodes in flight" % _pending().size())
		SoundBank.clear_cache()
		_quitting = true
		quit(0)
		return
	# Every file asked for many times in one frame, both loop flags: one decode per key. A decode that
	# finishes meanwhile is taken in at the next ask (then answered from the cache), so a key is either
	# still pending or cached, never both.
	for i in 5:
		for f in _files:
			var s := SoundBank.stream_soon(f)
			if i == 0:
				_check(s == null, "a sound's first ask is null (it decodes on a worker): " + f)
	SoundBank.stream_soon(_files[0], true)
	_check(_pending().size() + _cached().size() == _files.size() + 1, "one decode per sound and loop flag, however often asked: %d pending and %d done for %d"
		% [_pending().size(), _cached().size(), _files.size() + 1])
	_until = Time.get_ticks_msec() + LIMIT_MSEC


func _settled() -> bool:
	SoundBank.stream_soon(_files[0])  # the main thread takes finished decodes in when asked
	return _pending().is_empty() or Time.get_ticks_msec() > _until


func _process(_delta: float) -> bool:
	if _quitting:
		return true
	match _phase:
		0:
			if not _settled():
				return false
			_check(_pending().is_empty(), "every decode finished and taken in")
			var all := true
			for f in _files:
				var s := SoundBank.stream_soon(f)
				all = all and s is AudioStreamOggVorbis and not (s as AudioStreamOggVorbis).loop
				_first[f] = s
			_check(all, "every sound decoded, not looping")
			var l := SoundBank.stream_soon(_files[0], true)
			_check(l is AudioStreamOggVorbis and (l as AudioStreamOggVorbis).loop and l != _first[_files[0]],
				"the looping one is its own stream, looping")
			_check(SoundBank.stream(_files[1]) == _first[_files[1]], "stream() hands out the stream decoded on the worker")
			# Left a game with decodes in flight: clear_cache() (fx.gd's _exit_tree) right after asking.
			SoundBank.clear_cache()
			_check(_cached().is_empty(), "clear_cache() empties the cache")
			for f in _files:
				SoundBank.stream_soon(f)
			SoundBank.clear_cache()
			for f in _files:
				SoundBank.stream_soon(f)  # asked again while in flight: no second decode
			_check(_pending().size() + _cached().size() == _files.size(), "a clear mid-flight keeps one decode per sound: %d pending and %d done for %d"
				% [_pending().size(), _cached().size(), _files.size()])
			_until = Time.get_ticks_msec() + LIMIT_MSEC
			_phase = 1
		1:
			if not _settled():
				return false
			_check(_pending().is_empty(), "every decode cleared mid-flight still finished and was taken in")
			var all := true
			for f in _files:
				all = all and SoundBank.stream_soon(f) is AudioStreamOggVorbis
			_check(all, "the next game's sounds are all there after the clear")
			# stream() on a sound still decoding on a worker: decoded on the spot (a second decode);
			# what it hands out should stay the one handed out next time.
			SoundBank.clear_cache()
			var f := _files[2]
			SoundBank.stream_soon(f)
			var now := SoundBank.stream(f)
			_check(now is AudioStreamOggVorbis, "stream() on a sound still decoding hands out a stream at once")
			_first[f] = now
			_until = Time.get_ticks_msec() + LIMIT_MSEC
			_phase = 2
		2:
			if not _settled():
				return false
			var f := _files[2]
			var later := SoundBank.stream(f)
			if later != _first[f]:
				print("NOTE: stream() on a sound still decoding: decoded twice, and the worker's copy replaced it in the cache once done")
			SoundBank.clear_cache()
			print("SOUND CACHE FAILS: ", _fails)
			quit(1 if _fails > 0 else 0)
			return true
	return false
