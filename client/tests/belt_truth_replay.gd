extends Node
## The truth test's replay (tools/belt_truth.py): a stream of `bi` messages a stand-in client got
## from a real server (belt_truth.py record) goes through belt_items.gd on the ticks it was sent,
## and where each item is near the recorded runs is written out two ways:
##   model.json: at each update's tick, once the update is worked out, where each item's record has
##     it at that tick: what the client's model of the belts (plain lanes moved here, the rest as
##     the mod sent them) says the game holds then;
##   drawn.json: every frame, where each item is drawn at the drawn clock (one update behind).
## belt_truth.py compare measures both against the game's items, recorded every tick meanwhile.
## No server: the recording has the belts round the runs (indexed for the items' paths as world.gd's
## records would be); the clock runs at 60 ticks a second.
##
##   godot --headless --path client res://tests/belt_truth_replay.tscn -- --dir=<recording dir>
##       [--stream=<file in dir>] [--items-script=res://...] [--out=<name>] [--trace=uid,uid,...]
## --items-script: another belt_items.gd to replay through (a change tried out against the same
## recording); --out: model_<name>.json and drawn_<name>.json; --trace: what the stream said of
## those items and what the client made of them, each update.

const BeltItems := preload("res://scripts/world/belt_items.gd")
const BeltPaths := preload("res://scripts/world/belt_paths.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const WorldMirror := preload("res://scripts/world/world.gd")

## Tiles round the recorded lanes whose items are written.
const MARGIN := 1.5


func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var dir := str(args.get("dir", ""))
	var belts = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("belts.json")))
	var lanes = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("lanes.json")))
	var text := FileAccess.get_file_as_string(dir.path_join(str(args.get("stream", "stream.jsonl"))))
	if not (belts is Dictionary) or not (lanes is Dictionary) or text.is_empty():
		push_error("belt-truth-replay: no belts.json, lanes.json or stream.jsonl in %s" % dir)
		get_tree().quit(1)
		return
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
		var bg = m.get("bg")
		if bg is Array:
			for i in range(1, (bg as Array).size(), 10):
				ids[int(bg[i])] = true
	var ticks: Array = by_tick.keys()
	ticks.sort()
	if ticks.is_empty():
		push_error("belt-truth-replay: no bi messages")
		get_tree().quit(1)
		return
	var protos := ProtoDB.new()
	var names := {}
	var list: Array = []
	for b in belts["belts"]:
		var name := str(b[0])
		if not names.has(name):
			names[name] = names.size() + 1
			list.append([names[name], name, str(b[1]), -0.5, -0.5, 0.5, 0.5, 128, 128, 128, 1, 1])
	protos.add_entities(list)
	var items_list: Array = []
	for id in ids:
		items_list.append([int(id), ""])
	protos.add_items(items_list)
	var script: Script = load(str(args.get("items-script", "res://scripts/world/belt_items.gd")))
	var items = script.new()
	items.protos = protos
	add_child(items)
	items._sync = true
	var by_chunk := {}
	var unit := 1
	for b in belts["belts"]:
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
	# The recorded lanes' box: only items there are written.
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for ln in lanes["lanes"]:
		var pts: Array = ln[7]
		for i in range(0, pts.size() - 1, 2):
			var p := Vector2(float(pts[i]) / 256.0, float(pts[i + 1]) / 256.0)
			lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
			hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	lo -= Vector2(MARGIN, MARGIN)
	hi += Vector2(MARGIN, MARGIN)
	var first := int(lanes["from"])
	var last := mini(int(lanes["to"]), int(ticks[-1]))
	var start := int(ticks[0])
	print("belt-truth-replay: %d updates from tick %d, the recording %d to %d" % [ticks.size(), start, first, last])
	var updates: Array = []
	var frames: Array = []
	var plains := {}
	# The recorded lanes' keys (unit * 8 + line), for what the client made of each at each update.
	var keys: Array = []
	for ln in lanes["lanes"]:
		keys.append(int(ln[1]) * 8 + int(ln[2]))
	var lane_log: Array = []
	# --trace=uid,uid,...: each update, what the stream said of those items and what the client made of them.
	var trace := {}
	for v in str(args.get("trace", "")).split(",", false):
		trace[int(v)] = true
	var t0 := Time.get_ticks_msec()
	for tick in range(start, last + 1):
		var got := by_tick.has(tick)
		var said := {}
		for m in by_tick.get(tick, []):
			items.handle(m)
			if not trace.is_empty():
				_said(m, trace, said)
		items._process(1.0 / 60.0)
		if got and not trace.is_empty():
			var st = items._state
			for uid in trace:
				var it = st.items.get(uid)
				var line := "trace t%d %d: sent %s" % [tick, uid, str(said.get(uid, "-"))]
				if it != null:
					var c = st.chain_of.get(it.lane)
					line += " | lane %d%s target (%.3f, %.3f) @%d seen %s missed %d stuck %d chain %s" % [it.lane,
						" plain" if st.plains.has(it.lane) else "", it.target.x, it.target.z, it.target_tick,
						"now" if it.seen == st.frame else str(it.seen - st.frame), it.missed, it.stuck, str(c)]
				else:
					line += " | gone"
				print(line)
		if tick < first:
			continue
		var state = items._state
		if got:
			# What the model says the game holds on this tick (the update's): each item's record then.
			var row: Array = []
			for uid in state.items:
				var it = state.items[uid]
				var p = _place(it, float(tick))
				if p == null:
					continue
				var at: Vector3 = p
				if at.x < lo.x or at.x > hi.x or at.z < lo.y or at.z > hi.y:
					continue
				row.append_array([int(uid), roundi(at.x * 1024.0), roundi(at.z * 1024.0), int(it.count)])
			var sq: Vector3 = state.square
			updates.append([tick, row, sq.x, sq.y, sq.z])
			for key in state.plains:
				plains[int(key)] = true
			# Per recorded lane: [key, sent this update (1) or not, plain (its chain, its place in it, the
			# chain asleep) or -1], for the lanes the client knows.
			var info: Array = []
			for key in keys:
				var sent := 1 if int(state.lane_frame.get(key, -1)) == state.frame else 0
				var c = state.chain_of.get(key)
				if state.plains.has(key) and c != null:
					info.append_array([key, sent, int(c[0]), int(c[1]), 1 if state.asleep.has(int(c[0])) else 0])
				elif state.plains.has(key):
					info.append_array([key, sent, -2, 0, 0])
				else:
					info.append_array([key, sent, -1, 0, 0])
			lane_log.append([tick, info])
		var drawn: Array = [tick, items._drawn]
		for uid in state.items:
			var it = state.items[uid]
			var p = _place(it, items._drawn)
			if p == null:
				continue
			var at: Vector3 = p
			if at.x < lo.x or at.x > hi.x or at.z < lo.y or at.z > hi.y:
				continue
			drawn.append_array([int(uid), roundi(at.x * 1024.0), roundi(at.z * 1024.0), int(it.count)])
		frames.append(drawn)
		if (tick - first) % 300 == 0:
			print("  tick %d, %d ms, %d items" % [tick - first, Time.get_ticks_msec() - t0, items.count()])
	var stats: Dictionary = items.stats
	var suffix := ("_" + str(args["out"])) if args.has("out") else ""
	var f := FileAccess.open(dir.path_join("model%s.json" % suffix), FileAccess.WRITE)
	f.store_string(JSON.stringify({"updates": updates, "plains": plains.keys(), "lanes": lane_log, "stats": stats}))
	f.close()
	f = FileAccess.open(dir.path_join("drawn%s.json" % suffix), FileAccess.WRITE)
	f.store_string(JSON.stringify({"frames": frames}))
	f.close()
	print("belt-truth-replay: %d updates and %d frames written, %d plain lanes seen, %d moved along plain lanes" % [
		updates.size(), frames.size(), plains.size(), stats["plain_moved"]])
	get_tree().quit(0)


## The traced items a `bi` part sends: uid -> [lane key, x, y] (1/256 tile).
static func _said(m: Dictionary, trace: Dictionary, said: Dictionary) -> void:
	var l = m.get("l")
	if not (l is Array):
		return
	var deltas := int(m.get("z", 0)) == 1
	var ln = m.get("ln")
	var runs: Array = ln if ln is Array else []
	var run := 0
	var left := 0
	var lane := 0
	var uid := 0
	var x := 0
	var y := 0
	for i in range(0, (l as Array).size() - 3, 4):
		if deltas:
			uid += int(l[i])
			x += int(l[i + 2])
			y += int(l[i + 3])
		else:
			uid = int(l[i])
			x = int(l[i + 2])
			y = int(l[i + 3])
		while left == 0 and run + 1 < runs.size():
			lane = int(runs[run])
			left = int(runs[run + 1])
			run += 2
		if left > 0:
			left -= 1
		else:
			lane = 0
		if trace.has(uid):
			said[uid] = [lane, x, y]


## Where an item's record has it at tick t, or null under the ground (as the shader draws it).
## (belt_items.gd's Job._at(), written out so another items script can be replayed.)
static func _place(it, t: float) -> Variant:
	if it.t_to < 0.0 or (it.step == Vector3.ZERO and it.path.is_empty()):
		return it.from if it.path.is_empty() or it.path[it.path.size() - 1] >= 0.5 else null
	var g := 1.0 if it.t_to <= it.t_from else clampf((t - it.t_from) / (it.t_to - it.t_from), 0.0, 1.0)
	if it.path.is_empty():
		return it.from + it.step * g
	var o := BeltPaths.path_at(it.path, g)
	if o.w < 0.5:
		return null
	return it.from + Vector3(o.x, o.y, o.z)
