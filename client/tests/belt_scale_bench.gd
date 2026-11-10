extends Node
## How the belt items layer's cost grows with the number of items (docs/PERFORMANCE-PLAN.md item 7):
## `godot --path client res://tests/belt_scale_bench.tscn -- --items=20000 [--moving=0.3]
## [--updates=40] [--layer=res://...belt_items.gd]`. A field of straight belts facing north, eight
## items a belt, fed as the mod sends them (`bi` every 6 ticks, lanes that didn't change not sent,
## `bl`): a share of the columns moves at a yellow belt's speed (items leaving the field come back at
## its far end with new ids), the rest stand. Prints the job's time on the worker and the layer's
## main-thread time an update (the job's result given to the MultiMeshes and the GPU), averaged after
## the first few updates. Windowed, so uploads go to a real GPU.
## --groups: every belt's two lanes are packed groups as the mod sends them (`bg` once, then `bm`
## when they move, `bg` again every 64 updates as its refresh), as on a busy base; the moving
## columns creep (each group moves most updates, by a varying part of the belt's pace).
## --stack=N: stacks of N (`st`, a group's stack).

const ProtoDB := preload("res://scripts/world/protos.gd")
const WorldMirror := preload("res://scripts/world/world.gd")

const ROWS := 100
const SPEED := 0.03125
const PERIOD := 6


func _ready() -> void:
	var n := 20000
	var moving := 0.3
	var updates := 40
	var layer_path := "res://scripts/world/belt_items.gd"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--items="):
			n = int(a.get_slice("=", 1))
		elif a.begins_with("--moving="):
			moving = float(a.get_slice("=", 1))
		elif a.begins_with("--updates="):
			updates = int(a.get_slice("=", 1))
		elif a.begins_with("--layer="):
			layer_path = a.get_slice("=", 1)
		elif a == "--steady":
			_steady = true
		elif a == "--groups":
			_groups = true
		elif a.begins_with("--stack="):
			_stack = clampi(int(a.get_slice("=", 1)), 1, 4)
	var protos := ProtoDB.new()
	protos.add_entities([[1, "transport-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 170, 50, 1, 1]])
	protos.add_items([[1, ""], [2, ""], [3, ""], [4, ""]])
	var layer = load(layer_path).new()
	layer.protos = protos
	add_child(layer)
	var cols := maxi(1, ceili(n / 8.0 / ROWS))
	var by_chunk := {}
	for c in cols:
		for r in ROWS:
			var rec := WorldMirror.Rec.new()
			rec.unit = c * ROWS + r + 1
			rec.key = rec.unit
			rec.proto_id = 1
			rec.pos = Vector2(c + 0.5, r + 0.5)
			rec.dir = 0
			rec.extra = {"s": "straight"}
			rec.chunk = WorldMirror.chunk_of(rec.pos)
			var list: Array = by_chunk.get(rec.chunk, [])
			list.append(rec)
			by_chunk[rec.chunk] = list
	for ch in by_chunk:
		layer.index_chunk(ch, by_chunk[ch])
	# Lanes: [x, items' y list, uid list, moving]
	var lanes: Array = []
	var next_uid := 1
	var made := 0
	for c in cols:
		var moves: bool = (c * 7919 % 1000) / 1000.0 < moving
		for side in 2:
			var ys: Array = []
			var ids: Array = []
			var y := 0.125
			while y < ROWS and made < n:
				ys.append(y)
				ids.append(next_uid)
				next_uid += 1
				made += 1
				y += 0.25
			lanes.append([c + 0.5 + (0.234 if side == 1 else -0.234), ys, ids, moves, 1 + c % 4])
	var half := maxf(cols, ROWS) * 0.5 + 1.0
	_next_uid = next_uid
	var fx := int(cols * 0.5 * 256)
	var fy := int(ROWS * 0.5 * 256)
	var worker := 0
	var main := 0
	var jobs := 0
	var written := 0
	var counted := 0
	var tick := 1000
	var sent := 0
	var start := Time.get_ticks_usec()
	var base := {}
	# Updates come in real time, one every PERIOD ticks at 60 UPS (100 ms) as from a game; the layer
	# runs on the frames between as in the client (its jobs on a worker, a job taking every update
	# that came while the last ran). Its own stats give the costs, from the 6th update on.
	while sent < updates:
		if Time.get_ticks_usec() - start >= sent * PERIOD * 1000000.0 / 60.0:
			layer.handle(_message_groups(cols, moving, sent, tick, fx, fy, half) if _groups else _message(lanes, sent, tick, fx, fy, half))
			sent += 1
			tick += PERIOD
			if sent == maxi(6, updates / 3):
				base = layer.stats.duplicate(true)
		await get_tree().process_frame
	for f in 30:
		await get_tree().process_frame
	var st: Dictionary = layer.stats
	jobs = int(st["jobs"]) - int(base.get("jobs", 0))
	worker = int(st["worker_usec"]) - int(base.get("worker_usec", 0))
	var frames := int(st["frames"]) - int(base.get("frames", 0))
	main = int(st["main_usec"]) - int(base.get("main_usec", 0))
	written = int(st.get("records_written", 0)) - int(base.get("records_written", 0))
	var kept := int(st.get("kept_records", 0)) - int(base.get("kept_records", 0))
	if OS.get_cmdline_user_args().has("--debug"):
		for uid in [1, 2, 50]:
			var it = layer._state.items.get(uid)
			if it != null:
				print("dbg uid %d open %s t %.1f..%.1f vel %s step %s from %s target %s@%d" % [uid, it.open, it.t_from, it.t_to, it.vel, it.step, it.from, it.target, it.target_tick])
	print("belt-scale-bench: %s, %d items (%d tracked), %.0f%% of lanes moving: %d jobs for %d updates, worker %.2f ms a job (worst %.1f), main thread %.3f ms a frame (%d frames)%s" % [
		layer_path.get_file(), made, layer.count(), moving * 100.0, jobs, sent - maxi(6, updates / 3), worker / 1000.0 / maxi(jobs, 1), int(st["worst_job_usec"]) / 1000.0,
		main / 1000.0 / maxi(frames, 1), frames, (", %.0f records written and %.0f kept a job" % [written / float(maxi(jobs, 1)), kept / float(maxi(jobs, 1))]) if "records_written" in st else ""])
	var parts := ""
	for k in ["handle_usec", "route_usec", "end_usec", "groups_usec", "missing_usec", "adopt_usec", "carry_usec", "write_usec"]:
		if st.has(k):
			parts += " %s %.2f" % [k.trim_suffix("_usec"), (int(st[k]) - int(base.get(k, 0))) / 1000.0 / maxi(jobs, 1)]
	print("belt-scale-bench: a job (ms):%s" % parts)
	get_tree().quit()


## One update as the mod sends it: every lane the first time, then only the moving ones (`bl`).
func _message(lanes: Array, u: int, tick: int, fx: int, fy: int, half: float) -> Dictionary:
	var l: Array = []
	var ln: Array = []
	var prev := [0, 0, 0, 0]
	for li in lanes.size():
		var lane: Array = lanes[li]
		if u > 0 and not lane[3]:
			continue  # held: unchanged lanes aren't sent
		var ys: Array = lane[1]
		var ids: Array = lane[2]
		if u > 0:
			for k in ys.size():
				ys[k] = ys[k] - SPEED * PERIOD
				if ys[k] < 0.0:
					ys[k] += ROWS
					ids[k] = _next_uid
					_next_uid += 1
		ln.append_array([li + 1, ys.size()])
		for k in ys.size():
			var row := [int(ids[k]), int(lane[4]), int(float(lane[0]) * 256), int(float(ys[k]) * 256)]
			for q in 4:
				l.append(row[q] - prev[q])
			prev = row
	return {"t": "bi", "k": tick, "p": PERIOD, "z": 1, "fx": fx, "fy": fy, "fr": int(half), "l": l, "ln": ln}


var _next_uid := 0
var _groups := false
var _steady := false  # --steady: groups move at the belt's pace every update
var _stack := 1
var _fronts := PackedFloat32Array()


## --groups: one update with every belt's lanes as groups, the first time and as each one's
## refresh (`bg`), and their moves (`bm`).
func _message_groups(cols: int, moving: float, u: int, tick: int, fx: int, fy: int, half: float) -> Dictionary:
	if _fronts.is_empty():
		_fronts.resize(cols * ROWS * 2)
		for i in _fronts.size():
			_fronts[i] = (i * 37 % 64) / 256.0
	var bg: Array = []
	var bm: Array = []
	for c in cols:
		var moves: bool = (c * 7919 % 1000) / 1000.0 < moving
		for r in ROWS:
			for side in 2:
				var i := (c * ROWS + r) * 2 + side
				var key := 1000000 + i
				if u > 0 and moves:
					# Creeping: still, half the pace or the whole, by turns.
					var h := (i * 2654435761 + u * 40503) % 10
					var frac := 1.0 if _steady else (0.0 if h < 3 else (0.5 if h < 6 else 1.0))
					if frac > 0.0:
						_fronts[i] = fposmod(_fronts[i] - SPEED * PERIOD * frac, 0.25)
						bm.append_array([key, int(_fronts[i] * 256), PERIOD])
				if u == 0 or (u + i) % 64 == 0:
					var x := c + 0.5 + (0.234 if side == 1 else -0.234)
					bg.append_array([key, 1 + c % 4, int(x * 256), r * 256, int(x * 256), (r + 1) * 256,
						int(_fronts[i] * 256), 64, int(SPEED * 65536), _stack])
	return {"t": "bi", "k": tick, "p": PERIOD, "z": 1, "fx": fx, "fy": fy, "fr": int(half), "l": [], "ln": [], "bg": bg, "bm": bm}
