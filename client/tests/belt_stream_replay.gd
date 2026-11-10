extends Node
## Replays a stream of `bi` messages captured from a real server (tools/belt_bench.py --capture)
## through belt_items.gd and writes where each item is drawn every tick, for
## tools/belt_path_check.py check to measure against the game's own places, recorded meanwhile
## (belt_path_check.py record) over part of the same square. No server: the recording has the belts
## (indexed for the items' paths as world.gd's records would be); the messages come on their ticks,
## the clock runs at 60 ticks a second.
##
##   godot --headless --path client res://tests/belt_stream_replay.tscn -- --truth=<truth.json>
##       --stream=<bi.jsonl> --out=<drawn.json> [--within=x0,y0,x1,y1]
##
## --within: only items drawn inside it are written (the recorded area).
## --batch=<ticks>: the messages handed over that many ticks at a time (a job holding several updates,
## as a live client's whose jobs take longer than the updates' interval).
## --job-delay=<ms>: each job takes that much longer (with --realtime: several updates to a job).
## --margin-jobs=<n>: belt_items.gd's margin_jobs.
## --realtime: the jobs run on a worker as in the game and each tick takes a 60th of a second (the
## result waiting for the drawn clock, jobs folding several updates: what a live client's timing does).

const BeltItems := preload("res://scripts/world/belt_items.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const WorldMirror := preload("res://scripts/world/world.gd")


func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var truth = JSON.parse_string(FileAccess.get_file_as_string(str(args.get("truth", ""))))
	var text := FileAccess.get_file_as_string(str(args.get("stream", "")))
	if not (truth is Dictionary) or text.is_empty():
		push_error("belt-stream-replay: no truth or stream file")
		get_tree().quit(1)
		return
	var within := PackedFloat64Array()
	if args.has("within"):
		for v in str(args["within"]).split(","):
			within.append(float(v))
	# The messages by tick, in the order they came.
	var by_tick := {}
	var ids := {}
	for line in text.split("\n"):
		if line.strip_edges().is_empty():
			continue
		var m = JSON.parse_string(line)
		if not (m is Dictionary) or str(m.get("t", "")) != "bi":
			continue
		var k := int(m.get("k", 0))
		if not by_tick.has(k):
			by_tick[k] = []
		(by_tick[k] as Array).append(m)
		var l: Array = m.get("l", [])
		var deltas := int(m.get("z", 0)) == 1
		var item_id := 0
		for i in range(1, l.size(), 4):
			item_id = item_id + int(l[i]) if deltas else int(l[i])
			ids[item_id] = true
	var ticks: Array = by_tick.keys()
	ticks.sort()
	var protos := ProtoDB.new()
	var names := {}
	var list: Array = []
	for b in truth["belts"]:
		var name := str(b[0])
		if not names.has(name):
			names[name] = names.size() + 1
			list.append([names[name], name, str(b[1]), -0.5, -0.5, 0.5, 0.5, 128, 128, 128, 1, 1])
	protos.add_entities(list)
	var items_list: Array = []
	for id in ids:
		items_list.append([int(id), ""])
	protos.add_items(items_list)
	var items := BeltItems.new()
	items.protos = protos
	add_child(items)
	var realtime := args.has("realtime")
	var batch := int(args.get("batch", "1"))
	var waiting: Array = []
	BeltItems.margin_jobs = float(args.get("margin-jobs", "1.5"))
	BeltItems.Job.debug_delay_usec = int(args.get("job-delay", "0")) * 1000
	items._sync = not realtime
	items.watch_all = true
	var by_chunk := {}
	var unit := 1
	for b in truth["belts"]:
		var r := WorldMirror.Rec.new()
		r.unit = unit
		unit += 1
		r.proto_id = names[str(b[0])]
		r.pos = Vector2(float(b[2]), float(b[3]))
		r.fixed = Vector2i(roundi(r.pos.x * 256), roundi(r.pos.y * 256))
		r.dir = int(b[4])
		var t := str(b[1])
		if t == "transport-belt":
			r.extra = {"s": str(b[5])}
		elif t == "underground-belt":
			r.extra = {"u": str(b[5])}
		r.chunk = WorldMirror.chunk_of(r.pos)
		r.key = r.unit
		if not by_chunk.has(r.chunk):
			by_chunk[r.chunk] = []
		by_chunk[r.chunk].append(r)
	for c in by_chunk:
		items.index_chunk(c, by_chunk[c])
	# The ticks the recording covers.
	var first := 1 << 40
	var last := 0
	for tr in truth["tracks"]:
		var l: Array = tr[1]
		if l.size() >= 4:
			first = mini(first, int(l[0]))
			last = maxi(last, int(l[l.size() - 4]))
	var frames: Array = []
	var t0 := Time.get_ticks_msec()
	var start := int(ticks[0])
	print("belt-stream-replay: %d updates from tick %d, the recording %d to %d" % [ticks.size(), start, first, last])
	for tick in range(start, mini(int(ticks[-1]), last) + 1):
		for m in by_tick.get(tick, []):
			if batch > 1:
				waiting.append(m)
			else:
				items.handle(m)
		if batch > 1 and tick % batch == 0:
			for m in waiting:
				items.handle(m)
			waiting.clear()
		var frame_start := Time.get_ticks_usec()
		items._process(1.0 / 60.0)
		if realtime:
			OS.delay_usec(maxi(0, 16667 - (Time.get_ticks_usec() - frame_start)))
		if tick < first:
			continue
		var row: Array = [tick, items._drawn]
		for uid in items._positions:
			var at = items.position_of(uid)
			if at == null:
				continue
			var p: Vector3 = at
			if within.size() == 4 and (p.x < within[0] or p.x > within[2] or p.z < within[1] or p.z > within[3]):
				continue
			row.append_array([uid, snappedf(p.x, 0.0001), snappedf(p.z, 0.0001), 1])
		frames.append(row)
		if (tick - first) % 300 == 0:
			print("  tick %d, %d ms, %d items" % [tick - first, Time.get_ticks_msec() - t0, items.count()])
	var stats: Dictionary = items.stats
	var f := FileAccess.open(str(args.get("out", "user://belt_drawn.json")), FileAccess.WRITE)
	f.store_string(JSON.stringify({"period": 0, "frames": frames, "stats": stats}))
	f.close()
	print("belt-stream-replay: %d frames, worker %.1f ms over %d jobs (worst %.1f), %d moved along plain lanes (%.1f ms)" % [
		frames.size(), stats["worker_usec"] / 1000.0, stats["jobs"], stats["worst_job_usec"] / 1000.0, stats["plain_moved"], stats["plain_usec"] / 1000.0])
	get_tree().quit(0)
