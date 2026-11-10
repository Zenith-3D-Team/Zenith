extends Node
## Two versions of belt_items.gd fed the same updates, jobs run one by one with the same fold
## ticks, compared by where every item is drawn (its record, at several ticks round each update):
##   godot --headless --path client res://tests/belt_cost_check.tscn -- --old=res://...gd
##       [--new=res://scripts/world/belt_items.gd] [--updates=60] [--every=1] [--period=6]
##       [--speed=0.03125] [--creep=0.67]
## --old: a copy of the version to compare with, put under client/ (not committed; `git show
## <rev>:client/scripts/world/belt_items.gd`). A field of straight belts: half the columns packed
## groups (bg/bm; --creep of them creeping, still or at half or whole pace by turns, the rest at the
## belt's pace --speed, stacks of 1-4), half lanes sent as items (bi ln, some stacks of 3); an update
## every --period ticks; --every: updates per job (a job behind the game holds several). Prints each
## version's cost a job by part, how many items differ by more than 0.001 tile and the largest
## difference (and up to each update's tick, where they are drawn while the next is on its way).

const ProtoDB := preload("res://scripts/world/protos.gd")
const WorldMirror := preload("res://scripts/world/world.gd")

const ROWS := 60
const COLS := 12
var SPEED := 0.03125  # --speed (tiles a tick)
var PERIOD := 6  # --period
var _creep := 0.67  # --creep: the share of group columns that creep (the rest move at the pace)
const PARTS := ["usec", "handle_usec", "route_usec", "end_usec", "groups_usec", "missing_usec", "adopt_usec",
	"carry_usec", "write_usec", "records_written", "kept_records", "fresh", "missing", "adopted"]


func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var updates := int(args.get("updates", "60"))
	PERIOD = int(args.get("period", "6"))
	SPEED = float(args.get("speed", "0.03125"))
	_creep = float(args.get("creep", "0.67"))
	var every := int(args.get("every", "1"))
	var paths := [str(args.get("old", "")), str(args.get("new", "res://scripts/world/belt_items.gd"))]
	var runs: Array = []
	for p in paths:
		runs.append(_run(p, updates, every))
	var a: Array = runs[0][0]
	var b: Array = runs[1][0]
	var worst := 0.0
	var worst_by := 0.0  # up to the update's tick (later, an item waits for the next update)
	var off := 0
	var total := 0
	var missing := 0
	for j in mini(a.size(), b.size()):
		var da: Dictionary = a[j]
		var db: Dictionary = b[j]
		for uid in da:
			total += 1
			if not db.has(uid):
				missing += 1
				continue
			var pa: PackedVector3Array = da[uid]
			var pb: PackedVector3Array = db[uid]
			var differs := false
			for q in pa.size():
				var d := pa[q].distance_to(pb[q])
				worst = maxf(worst, d)
				if q < 3:
					worst_by = maxf(worst_by, d)
				differs = differs or d > 0.001
			if differs:
				off += 1
		for uid in db:
			if not da.has(uid):
				missing += 1
	print("belt-cost-check: %d item-updates, %d differ by over 0.001 tile, %d in one only, worst %.4f (%.4f up to the update's tick); old %.1f ms, new %.1f ms (%d jobs)" % [
		total, off, missing, worst, worst_by, runs[0][1] / 1000.0, runs[1][1] / 1000.0, updates / every])
	get_tree().quit()


func _run(path: String, updates: int, every: int) -> Array:
	var protos := ProtoDB.new()
	protos.add_entities([[1, "transport-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 170, 50, 1, 1]])
	protos.add_items([[1, ""], [2, ""], [3, ""], [4, ""]])
	var script: GDScript = load(path)
	var layer = script.new()
	layer.protos = protos
	var st = layer._state
	var recs: Array = []
	for c in COLS:
		for r in ROWS:
			var rec := WorldMirror.Rec.new()
			rec.unit = c * ROWS + r + 1
			rec.key = rec.unit
			rec.proto_id = 1
			rec.pos = Vector2(c + 0.5, r + 0.5)
			rec.dir = 0
			rec.extra = {"s": "straight"}
			rec.chunk = WorldMirror.chunk_of(rec.pos)
			recs.append(rec)
	var fronts := PackedFloat32Array()
	fronts.resize(COLS * ROWS * 2)
	for i in fronts.size():
		fronts[i] = (i * 37 % 64) / 256.0
	# Item lanes (half the columns): [x, ys, ids]
	var lanes: Array = []
	var next_uid := 1
	for c in range(COLS / 2, COLS):
		for side in 2:
			var ys: Array = []
			var ids: Array = []
			var y := 0.125
			while y < ROWS:
				ys.append(y)
				ids.append(next_uid)
				next_uid += 1
				y += 0.25
			lanes.append([c + 0.5 + (0.234 if side == 1 else -0.234), ys, ids])
	var out: Array = []
	var usec := 0
	var jobs := 0
	var parts := {}
	var tick := 1000
	var msgs: Array = []
	var known := {}
	for id in [1, 2, 3, 4]:
		known[id] = [Vector3(0.0, 0.05, 0.0), false, 0.07]
	for u in updates:
		msgs.append(_message(u, tick, fronts, lanes, next_uid))
		next_uid = int(msgs[-1]["next"])
		tick += PERIOD
		if msgs.size() < every:
			continue
		var job = script.Job.new()
		job.state = st
		job.msgs = msgs
		job.known = known
		if u < every:
			job.kinds = {1: script.BeltPaths.TYPES["transport-belt"]}
			job.index.append([Vector2i(0, 0), recs, true])
		# Drawn about an update behind the newest, as the client draws them (a gap and a margin).
		job.fold_tick = float(tick - PERIOD * (every + 1) - 2)
		job.model_cap = -1
		var t0 := Time.get_ticks_usec()
		job.run()
		if u >= updates / 4:
			usec += Time.get_ticks_usec() - t0
			jobs += 1
			for k in PARTS:
				if k in job:
					parts[k] = int(parts.get(k, 0)) + int(job.get(k))
		msgs = []
		var drawn := {}
		var last := tick - PERIOD
		for uid in st.items:
			var it = st.items[uid]
			var ps := PackedVector3Array()
			for t in [last - PERIOD - 2, last - PERIOD / 2, last, last + 4, last + 12, last + 30]:
				var p: Vector3 = script.Job._at(it, float(t))
				ps.append(p)
			ps.append(Vector3(it.count, it.slot >= 0, 0))
			drawn[uid] = ps
		out.append(drawn)
	layer.free()
	var line := ""
	for k in PARTS:
		if parts.has(k):
			line += " %s %.2f" % [k.trim_suffix("_usec"), parts[k] / (1000.0 if k.ends_with("_usec") else 1.0) / maxi(jobs, 1)]
	print("belt-cost-check: %s, %d items, a job:%s" % [path.get_file(), st.items.size(), line])
	return [out, usec]


## One update: groups (the first half of the columns, creeping: still, half or whole pace, by turns;
## stacks of 1-4 by column) and item lanes (the other half, every item moving at the belt's pace).
func _message(u: int, tick: int, fronts: PackedFloat32Array, lanes: Array, next_uid: int) -> Dictionary:
	var bg: Array = []
	var bm: Array = []
	for c in COLS / 2:
		for r in ROWS:
			for side in 2:
				var i := (c * ROWS + r) * 2 + side
				var key := 1000000 + i
				if u > 0:
					var h := (i * 2654435761 + u * 40503) % 10
					var frac := 1.0 if (c * 7 % 10) >= _creep * 10.0 else (0.0 if h < 3 else (0.5 if h < 6 else 1.0))
					if frac > 0.0:
						fronts[i] = fposmod(fronts[i] - SPEED * PERIOD * frac, 0.25)
						bm.append_array([key, int(fronts[i] * 256), PERIOD])
				if u == 0 or (u + i) % 64 == 0:
					var x := c + 0.5 + (0.234 if side == 1 else -0.234)
					bg.append_array([key, 1 + c % 4, int(x * 256), r * 256, int(x * 256), (r + 1) * 256,
						int(fronts[i] * 256), 64, int(SPEED * 65536), 1 + c % 4])
	var l: Array = []
	var ln: Array = []
	var st: Array = []
	var prev := [0, 0, 0, 0]
	for li in lanes.size():
		var lane: Array = lanes[li]
		var ys: Array = lane[1]
		var ids: Array = lane[2]
		if u > 0:
			for k in ys.size():
				ys[k] = ys[k] - SPEED * PERIOD
				if ys[k] < 0.0:
					ys[k] += ROWS
					ids[k] = next_uid
					next_uid += 1
		ln.append_array([li + 1, ys.size()])
		for k in ys.size():
			var row := [int(ids[k]), 1 + li % 4, int(float(lane[0]) * 256), int(float(ys[k]) * 256)]
			if li % 3 == 1:
				st.append_array([int(ids[k]), 3])
			for q in 4:
				l.append(row[q] - prev[q])
			prev = row
	return {"t": "bi", "k": tick, "p": PERIOD, "z": 1, "fx": COLS * 128, "fy": ROWS * 128, "fr": maxi(COLS, ROWS) / 2 + 1,
		"l": l, "ln": ln, "st": st, "bg": bg, "bm": bm, "next": next_uid}
