extends SceneTree
## A live join watched from outside the main thread: runs the client (scenes/main.tscn, with the
## command line's options: --factorio-port=... --port=...) while a watchdog thread reads the main
## thread's heartbeat (the frame counter) every 10 ms. It reports when the world was ready, the
## longest gaps between frames (from start, and from the world being ready), what sound_bank.gd had
## decoding then, and quits `--watch-stay=<s>` (default 60) after the world is ready. A heartbeat gone
## for `--watch-freeze=<s>` (default 30) is a freeze: the watchdog prints FREEZE and crashes the client
## (non-zero exit), as sound_decode_test.gd does for the deadlock the owner's game had joining a big save.
##   godot --headless --audio-driver Dummy --path client -s res://tests/join_watch.gd -- --factorio-port=<udp> --port=<client>
## Prints "JOIN WATCH: ok" when the world was reached and kept going; quits with 1 otherwise.

const SoundBank := preload("res://scripts/fx/sound_bank.gd")

var _stay := 60.0
var _freeze := 30.0
var _limit := 600.0  # the world must be ready within this, or the run fails
var _watch := Thread.new()
var _done := false
var _beat := 0  # the frame counter as the main thread last wrote it
var _t0 := 0
var _ready_at := -1  # ms since start, the world ready
var _decoding_now := 0
var _peak := 0  # the most sound decodes in flight at once
var _first_decode := -1  # ms since start
var _drained := -1  # ms since start: none in flight again after the first
var _gaps: Array = []  # [gap ms, at ms since start, decodes in flight then], the watchdog's, longest first
var _gap_mutex := Mutex.new()


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--watch-stay="):
			_stay = float(arg.get_slice("=", 1))
		elif arg.begins_with("--watch-freeze="):
			_freeze = float(arg.get_slice("=", 1))
	_t0 = Time.get_ticks_msec()
	root.add_child.call_deferred((load("res://scenes/main.tscn") as PackedScene).instantiate())
	_watch.start(_watchdog)


func _process(_delta: float) -> bool:
	_beat += 1
	var bank: Script = SoundBank
	var d = bank.get("_decoding")
	_decoding_now = (d as Dictionary).size() if d is Dictionary else 0
	var now := Time.get_ticks_msec() - _t0
	_peak = maxi(_peak, _decoding_now)
	if _first_decode < 0 and _decoding_now > 0:
		_first_decode = now
	elif _first_decode >= 0 and _drained < 0 and _decoding_now == 0:
		_drained = now
	var bridge := root.get_node_or_null("Bridge")
	if _ready_at < 0 and bridge != null and bridge.world_ready:
		_ready_at = now
		print("WATCH: world ready at %.1f s (frame %d)" % [now / 1000.0, _beat])
	if _ready_at < 0 and now > _limit * 1000:
		print("WATCH: FAIL: the world wasn't ready in %d s" % _limit)
		return _finish(false)
	if _ready_at >= 0 and now - _ready_at > _stay * 1000:
		return _finish(true)
	return false


func _finish(ok: bool) -> bool:
	_done = true
	_watch.wait_to_finish()
	_gap_mutex.lock()
	var gaps := _gaps.duplicate()
	_gap_mutex.unlock()
	var after_ready := gaps.filter(func(g: Array) -> bool: return _ready_at >= 0 and g[1] >= _ready_at)
	print("WATCH: frames %d in %.1f s; longest main-thread gaps (ms, at s, sound decodes in flight):" % [_beat, (Time.get_ticks_msec() - _t0) / 1000.0])
	for g in gaps.slice(0, 8):
		print("  %6d ms at %6.1f s  decodes %d%s" % [g[0], g[1] / 1000.0, g[2], "  (after ready)" if _ready_at >= 0 and g[1] >= _ready_at else ""])
	print("WATCH: longest gap %d ms; after the world was ready %d ms; within 10 s of ready %d ms"
		% [gaps[0][0] if gaps.size() > 0 else 0, after_ready[0][0] if after_ready.size() > 0 else 0,
			_max_in(gaps, _ready_at, _ready_at + 10000)])
	var bank: Script = SoundBank
	print("WATCH: sound decodes: at most %d in flight, first at %.1f s, all in by %.1f s; %d streams cached"
		% [_peak, _first_decode / 1000.0, _drained / 1000.0, (bank.get("_streams") as Dictionary).size()])
	print("JOIN WATCH: ", "ok" if ok else "FAIL")
	quit(0 if ok else 1)
	return true


static func _max_in(gaps: Array, from: int, to: int) -> int:
	var m := 0
	for g in gaps:
		if from >= 0 and g[1] >= from and g[1] <= to:
			m = maxi(m, g[0])
	return m


## Off the main thread: the time between the heartbeat's changes. A gap is noted when the beat moves
## again (its start, its length); one still open past _freeze is a freeze.
func _watchdog() -> void:
	var last := _beat
	var since := Time.get_ticks_msec()
	var decodes := 0
	while not _done:
		OS.delay_msec(10)
		var now := Time.get_ticks_msec()
		var beat := _beat
		if beat != last:
			var gap := now - since
			if gap >= 50:
				_gap_mutex.lock()
				_gaps.append([gap, since - _t0, decodes])
				_gaps.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
				_gaps.resize(mini(_gaps.size(), 32))
				_gap_mutex.unlock()
			last = beat
			since = now
			decodes = _decoding_now
		elif now - since > _freeze * 1000:
			print("WATCH: FREEZE: no frame for %.1f s at %.1f s (world ready: %s, sound decodes in flight: %d)"
				% [(now - since) / 1000.0, (since - _t0) / 1000.0, _ready_at >= 0, decodes])
			print("JOIN WATCH: FAIL")
			OS.crash("main thread frozen")
