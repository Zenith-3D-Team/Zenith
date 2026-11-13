extends Node
## --belt-path-probe=<out.json>[@seconds[@settle]]: where the client draws each item on belts every
## frame, for tools/belt_path_check.py to measure against the lanes the server records meanwhile
## (`belt_path_check.py record`), and what belt_items.gd costs: its main-thread time a frame, its
## jobs' time on the worker, how items glided. Waits `settle` seconds (default 10) after the world
## is ready, records for `seconds` (default 20), writes the file, prints the summary and quits.
## With an out path of "-" it records no positions (cost only).

const MAX_ITEMS := 4000

## The summary line, as printed (the debug menu shows it).
signal reported(text: String)

var main: Node  # main.gd: its belt_items
var out_path := ""
## False when the debug menu started it: the game goes on after, belt_items.gd watching as before.
var quit_when_done := true
var _watch_all_before = null

var _seconds := 20.0
var _area := PackedFloat64Array()
var _settle := 10.0
var _t := 0.0
var _started := false
var _frames: Array = []
var _uids := {}
var _dt: Array[float] = []
var _base := {}
## Every 30 frames: [server tick, bi p, clock gap, ticks drawn behind the server, bridge backlog].
var _clock_rows: Array = []
## Each frame's square (the update's fx, fy, fr) the items drawn were read in: [tick, x, y, half side].
var _squares: Array = []
## Each frame's square of the items drawn in it (belt_items.gd covered(): the update drawn, which
## while walking is behind the newest) and where the character stood: [tick, x, y, half side, char x,
## char y]. belt_path_check.py counts the game's items only inside it.
var _covered: Array = []
## Frames whose glide had reached the newest update's places (items stood waiting for the next).
var _waited := 0


func _ready() -> void:
	process_priority = 1000  # after the layers have drawn this frame
	var spec := out_path.split("@")
	out_path = spec[0]
	if spec.size() > 1:
		_seconds = float(spec[1])
	if spec.size() > 2:
		_settle = float(spec[2])
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--belt-path-area="):
			for v in a.substr(17).split(","):
				_area.append(float(v) - 1.0 if _area.size() < 2 else float(v) + 1.0)


func _process(delta: float) -> void:
	if main == null or not Bridge.world_ready or main.belt_items == null:
		return
	var belt = main.belt_items
	if "watch_all" in belt:
		if _watch_all_before == null:
			_watch_all_before = belt.watch_all
		belt.watch_all = true  # items new in an update too (belt groups' take new ids along)
	_t += delta
	if _t < _settle:
		return
	if not _started:
		_started = true
		_base = belt.stats.duplicate(true) if "stats" in belt else {}
		print("belt-path-probe: recording %.0f s" % _seconds)
	_dt.append(delta)
	if out_path != "-":
		# (Not while a finished job's result waits for the drawn clock (belt_items.gd _held_job): its
		# state has the next update's items, what is drawn still the last one's, and items handed over
		# to a new id meanwhile would be counted as missing.)
		# Items to follow: from what the main thread has of them (positions of every item: watch_all),
		# as jobs now run nearly every frame.
		var known_now: Dictionary = belt._positions
		for uid in _uids.keys():
			if not known_now.has(uid):
				_uids.erase(uid)
		for uid in known_now:
			if _uids.size() >= MAX_ITEMS:
				break
			if _uids.has(uid):
				continue
			if _area.size() == 4:
				var at: Vector3 = (known_now[uid] as Array)[0]
				if at.x < _area[0] or at.x > _area[2] or at.z < _area[1] or at.z > _area[3]:
					continue
			_uids[uid] = true
		if _frames.size() % 30 == 0:
			# How the updates come: the mod's period (bi p), the drawn clock's gap and how far it is
			# behind the newest message handled, and the bridge's backlog of messages.
			_clock_rows.append([Bridge.server_tick, belt._state.period, snappedf(belt._clock.gap, 0.1),
				snappedf(Bridge.server_tick - belt._drawn, 0.1), Bridge.waiting_count()])
		var sq: Vector3 = belt._state.square
		_squares.append([Bridge.server_tick, sq.x, sq.y, sq.z])
		var cov: Vector3 = belt.covered() if belt.has_method("covered") else Vector3(0.0, 0.0, -1.0)
		var me := Vector2.ZERO
		if "avatar" in main and main.avatar != null:
			me = main.avatar.ground_position()
		_covered.append([Bridge.server_tick, cov.x, cov.y, cov.z, snappedf(me.x, 0.01), snappedf(me.y, 0.01)])
		var row: Array = [Bridge.server_tick, belt._drawn]
		for uid in _uids:
			var known: bool = belt._positions.has(uid)
			var at = belt.position_of(uid)
			if not known:
				continue
			if at == null:
				row.append_array([uid, 0, 0, 0])
			else:
				row.append_array([uid, snappedf(at.x, 0.0001), snappedf(at.z, 0.0001), 1])
		_frames.append(row)
	if _t >= _settle + _seconds:
		_finish(belt)


func _finish(belt) -> void:
	set_process(false)
	var times := _dt.duplicate()
	times.sort()
	var frames := "frames p50 %.1f ms, p99 %.1f ms" % [times[times.size() / 2] * 1000.0, times[mini(times.size() - 1, int(times.size() * 0.99))] * 1000.0]
	if not ("stats" in belt):  # belt_items.gd from before it kept them: where items are drawn only
		print("belt-path-probe: %d items now; %s" % [belt.count(), frames])
		_write({"period": 0, "frames": _frames})
		return
	var st: Dictionary = belt.stats
	var d := {}
	for k in st:
		if st[k] is int:
			d[k] = int(st[k]) - int(_base.get(k, 0))
	d["worst_job_usec"] = st["worst_job_usec"]
	var per := float(maxi(d["jobs"], 1))
	var summary := "belt-path-probe: %d items now, belt items %.3f ms a frame on the main thread, %.2f ms a job on a worker (%.1f jobs a second, worst %.1f ms; simulating %.2f ms, writing %.2f ms a job), %.1f changes and %.1f records a job, %d lanes asked again; %s" % [
		belt.count(), d["main_usec"] / 1000.0 / maxi(d["frames"], 1), d["worker_usec"] / 1000.0 / per,
		d["jobs"] / _seconds, d["worst_job_usec"] / 1000.0, d["sim_usec"] / 1000.0 / per, d["write_usec"] / 1000.0 / per,
		d["changes"] / per, d["records_written"] / per, d["asked"], frames]
	print(summary)
	var nt := maxf(1.0, float(d.get("ticks", 0)))
	print("belt-path-probe: a job: handling %.2f, simulating %.2f (relinking %.2f, loads and checks %.2f, stepping %.2f), records %.2f, renewing %.2f, cap %.2f, writing %.2f ms; %.1f ticks a job, %.1f line steps a tick; why stepped every tick %s" % [
		d.get("handle_usec", 0) / 1000.0 / per, d["sim_usec"] / 1000.0 / per, d.get("sim_relink_usec", 0) / 1000.0 / per,
		d.get("sim_queue_usec", 0) / 1000.0 / per, d.get("sim_step_usec", 0) / 1000.0 / per, d.get("apply_usec", 0) / 1000.0 / per,
		d.get("renew_usec", 0) / 1000.0 / per, d.get("cap_usec", 0) / 1000.0 / per, d["write_usec"] / 1000.0 / per, nt / per,
		d.get("line_steps", 0) / nt, st.get("why_tick", [])])
	_write({"period": 0, "frames": _frames, "stats": d, "summary": summary, "clock": _clock_rows, "squares": _squares, "covered": _covered, "waited": _waited, "frames_n": _dt.size()})


func _write(data: Dictionary) -> void:
	if out_path != "-" and out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		f.store_string(JSON.stringify(data))
		f.close()
	reported.emit(str(data.get("summary", "belt-path-probe: %d frames recorded" % _frames.size())))
	if quit_when_done:
		get_tree().quit(0)
		return
	if _watch_all_before != null and main.belt_items != null:
		main.belt_items.watch_all = _watch_all_before
	queue_free()
