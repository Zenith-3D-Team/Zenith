extends Node
## --belt-path-probe=<out.json>[@seconds[@settle]]: where the client draws each item on belts every
## frame, for tools/belt_path_check.py to measure against the lanes the server records meanwhile
## (`belt_path_check.py record`), and what belt_items.gd costs: its main-thread time a frame, its
## jobs' time on the worker, how items glided. Waits `settle` seconds (default 10) after the world
## is ready, records for `seconds` (default 20), writes the file, prints the summary and quits.
## With an out path of "-" it records no positions (cost only).

const MAX_ITEMS := 4000

var main: Node  # main.gd: its belt_items
var out_path := ""

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
		belt.watch_all = true  # items new in an update too (belt groups' take new ids along)
	_t += delta
	if _t < _settle:
		return
	if not _started:
		_started = true
		_base = belt.stats.duplicate(true) if "stats" in belt else {}
		print("belt-path-probe: recording %.0f s" % _seconds)
	_dt.append(delta)
	if belt._progress() >= 0.999:
		_waited += 1
	if out_path != "-":
		# (Not while a finished job's result waits for the drawn clock (belt_items.gd _held_job): its
		# state has the next update's items, what is drawn still the last one's, and items handed over
		# to a new id meanwhile would be counted as missing.)
		if belt._task < 0 and ("_held_job" not in belt or belt._held_job == null):
			# Ids gone from the layer go (belt groups' items take new ids as they move along).
			for uid in _uids.keys():
				if not belt._state.items.has(uid):
					_uids.erase(uid)
				elif _area.size() == 4:
					# (And those that left the area: walking, the area's items change.)
					var at: Vector3 = belt._state.items[uid].target
					if at.x < _area[0] or at.x > _area[2] or at.z < _area[1] or at.z > _area[3]:
						_uids.erase(uid)
			for uid in belt._state.items:
				if _uids.size() >= MAX_ITEMS:
					break
				# (-- --belt-path-area=x0,y0,x1,y1: only items there, the area being recorded, so a
				# square of more than MAX_ITEMS items isn't measured on whichever it happened to take.)
				if _area.size() == 4:
					var at: Vector3 = belt._state.items[uid].target
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
	for k in ["frames", "main_usec", "jobs", "worker_usec", "indexed", "index_usec", "write_usec", "cached", "fresh", "missing"]:
		d[k] = int(st.get(k, 0)) - int(_base.get(k, 0))
	d["worst_job_usec"] = st["worst_job_usec"]
	var routes: Array = []
	for k in 5:
		routes.append(int(st["routes"][k]) - int(_base["routes"][k]))
	d["routes"] = routes
	var summary := "belt-path-probe: %d items now, belt items %.3f ms a frame on the main thread, %.2f ms a job on a worker (%.1f jobs a second, worst %.1f ms; indexing belts %d chunks, %.2f ms a job, writing %.2f ms a job, %d glides on a known run, %d new items, %d missing), glides %s (not known, straight, path, snapped, too far); %s" % [
		belt.count(), d["main_usec"] / 1000.0 / maxi(d["frames"], 1), d["worker_usec"] / 1000.0 / maxi(d["jobs"], 1),
		d["jobs"] / _seconds, d["worst_job_usec"] / 1000.0, d["indexed"], d["index_usec"] / 1000.0 / maxi(d["jobs"], 1), d["write_usec"] / 1000.0 / maxi(d["jobs"], 1), d["cached"], d["fresh"], d["missing"], routes, frames]
	print(summary)
	print("belt-path-probe: of a job, routing items not on a known run %.2f ms, folding glides %.2f ms (since the start); routes found without a walk %d, walked by the kind of belt they began on (straight, left, right, entrance, exit, splitter, other) %s" % [
		st.get("route_usec", 0) / 1000.0 / maxi(st["jobs"], 1), st.get("fold_usec", 0) / 1000.0 / maxi(st["jobs"], 1), st.get("runs", 0), st.get("walks", [])])
	var parts := ""
	var per := float(maxi(d["jobs"], 1))
	for k in ["handle_usec", "route_usec", "end_usec", "groups_usec", "missing_usec", "adopt_usec", "carry_usec", "cap_usec", "write_usec", "upload_usec",
			"kept_records", "records_written", "pages"]:
		d[k] = int(st.get(k, 0)) - int(_base.get(k, 0))
		parts += "%s %.2f, " % [k, d[k] / per / (1000.0 if k.ends_with("_usec") else 1.0)]
	print("belt-path-probe: a job (ms, or counts): %s" % parts)
	print("belt-path-probe: plain items let go (sent again without it, chain full, into a group, stuck) %s; drift checks that asked again %d (since the start)" % [st.get("let_go", []), st.get("drifted", 0)])
	var late := int(st.get("late", 0)) - int(_base.get("late", 0))
	print("belt-path-probe: jobs drawn after their fold tick %d of %d, %.2f ticks late on average" % [late, d["jobs"],
		(float(st.get("late_ticks", 0.0)) - float(_base.get("late_ticks", 0.0))) / maxi(late, 1)])
	_write({"period": 0, "frames": _frames, "stats": d, "summary": summary, "clock": _clock_rows, "squares": _squares, "waited": _waited, "frames_n": _dt.size()})


func _write(data: Dictionary) -> void:
	if out_path != "-" and out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		f.store_string(JSON.stringify(data))
		f.close()
	get_tree().quit(0)
