extends SceneTree
## Times belt_sim.gd on a synthetic world: rectangular loops of belts (flowing forever, some packed,
## some sparse) and straight runs that end nowhere (backing up and standing), at every belt speed.
##
##   godot --headless --path client -s res://tests/belt_sim_bench.gd -- [--items=80000] [--ticks=600]
##       [--packed=0.5] [--deadend=0.5] [--rec=<record.py json> --tile=N] [--gd | --native]
##
## --rec tiles a recording's lanes and first tick N times instead (its lanes leading nowhere stop).
## The C++ twin (BeltSimNative) when its extension is loaded; --gd times belt_sim.gd.

const BeltSim := preload("res://scripts/world/belt_sim.gd")
const SPEEDS := [8, 16, 24, 32]

var sim: RefCounted
var next_unit := 1
var next_uid := 1


func _initialize() -> void:
	var items := 80000
	var ticks := 600
	var packed := 0.5
	var deadend := 0.5
	var rec := ""
	var tile := 1
	var which := ""
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		match kv[0]:
			"--items":
				items = int(kv[1])
			"--ticks":
				ticks = int(kv[1])
			"--packed":
				packed = float(kv[1])
			"--deadend":
				deadend = float(kv[1])
			"--rec":
				rec = kv[1]
			"--tile":
				tile = int(kv[1])
			"--gd", "--native":
				which = kv[0].substr(2)
	const ReplayS := preload("res://tests/belt_sim_replay.gd")
	sim = ReplayS.make_sim(which)
	if sim == null:
		quit(2)
		return
	sim.edge_mode = BeltSim.EDGE_STOP
	var t0 := Time.get_ticks_msec()
	sim.step_to(0)
	if rec != "":
		_build_rec(rec, tile)
	else:
		_build_synthetic(items, packed, deadend)
	sim.step_to(1)
	print("built in %d ms: %s" % [Time.get_ticks_msec() - t0, sim.stats()])
	# Warm up: let the dead ends back up.
	var w0 := Time.get_ticks_msec()
	for t in range(2, 302):
		sim.step_to(t)
		sim.take_changes()
	print("warm-up 300 ticks in %d ms: %s" % [Time.get_ticks_msec() - w0, sim.stats()])
	var total := 0
	var worst := 0
	var changes := 0
	var steps0: int = sim.n_line_steps
	var times := PackedInt32Array()
	for t in range(302, 302 + ticks):
		var c0 := Time.get_ticks_usec()
		sim.step_to(t)
		var ch: Dictionary = sim.take_changes()
		var c1 := Time.get_ticks_usec() - c0
		times.append(c1)
		total += c1
		worst = maxi(worst, c1)
		changes += (ch["uid"] as PackedInt64Array).size()
	times.sort()
	print("%d ticks: %.0f us a tick (p50 %d, p99 %d, worst %d); line steps %.1f a tick; changes %.1f a tick; %s" % [
		ticks, float(total) / ticks, times[ticks / 2], times[ticks * 99 / 100], worst,
		float(sim.n_line_steps - steps0) / ticks, float(changes) / ticks, sim.stats()])
	print("prof ", sim.prof)
	quit(0)


## A lane from (x0, y0) (its exit) back to (x1, y1) (its entry), map positions in 1/256.
func _lane(kind: int, length: int, step: int, ex: Vector2i, en: Vector2i) -> int:
	var key := next_unit * 8 + 1
	next_unit += 1
	sim.set_lane(key, kind, length, step, ex, (ex + en) / 2, en, 0, 0)
	return key


## One lane going round a rectangle w x h tiles from `o`: straight lanes of 256 with corner lanes
## (curves) between. Returns the keys in the order items go.
func _loop(o: Vector2i, w: int, h: int, step: int) -> Array:
	var keys: Array = []
	var p := o
	var dirs := [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]
	var lens := [w, h, w, h]
	for side in 4:
		var d: Vector2i = dirs[side]
		for k in lens[side]:
			var q: Vector2i = p + d * 256
			keys.append(_lane(BeltSim.STRAIGHT, 256, step, q, p))
			p = q
		# A corner: a short curve lane.
		var nd: Vector2i = dirs[(side + 1) % 4]
		var q2: Vector2i = p + (d + nd) * 53
		keys.append(_lane(BeltSim.CURVE, 106, step, q2, p))
		p = q2
	# Close the loop: the last lane's exit must be the first lane's entry.
	return keys


func _fill(keys: Array, lens: Array, density: float, packed: bool) -> int:
	# Items along the lanes, from the back of the loop to the front, with gaps of 64 (packed) or random.
	var n := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = next_unit
	var gap := 64
	for i in keys.size():
		var len: int = lens[i]
		var pos := len - 1
		var lane_items := PackedInt64Array()
		var plist := []
		while pos >= 0:
			if packed or rng.randf() < density:
				plist.push_front(pos)
			pos -= gap if packed else rng.randi_range(64, 140)
		for q in plist:
			lane_items.append_array([next_uid, 1 + (next_uid % 7), q, 1])
			next_uid += 1
			n += 1
		if not lane_items.is_empty():
			sim.load_lane(int(keys[i]), sim.tick, lane_items)
	return n


func _build_synthetic(items: int, packed: float, deadend: float) -> void:
	var made := 0
	var row := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	while made < items:
		var o := Vector2i(0, row * 12 * 256)
		var x := 0
		while x < 600 and made < items:
			var step: int = SPEEDS[rng.randi_range(0, 3)]
			if rng.randf() < deadend:
				# A run of 10-60 straight lanes ending nowhere, packed or sparse; it backs up.
				var nl := rng.randi_range(10, 60)
				var keys: Array = []
				var lens: Array = []
				for k in nl:
					var p := Vector2i((x + k) * 256, o.y)
					keys.append(_lane(BeltSim.STRAIGHT, 256, step, p, p + Vector2i(256, 0)))
					lens.append(256)
				made += _fill(keys, lens, 0.7, rng.randf() < packed)
				x += nl + 2
			else:
				var w := rng.randi_range(8, 40)
				var keys := _loop(Vector2i(x * 256, o.y + 512), w, 6, step)
				var lens: Array = []
				for side in 4:
					var sl: int = w if side % 2 == 0 else 6
					for k in sl:
						lens.append(256)
					lens.append(106)
				made += _fill(keys, lens, 0.6, rng.randf() < packed)
				x += w + 4
		row += 1


func _build_rec(path: String, tile: int) -> void:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var metas: Array = d["lanes"]
	var first: Array = d["ticks"][0]
	const ReplayT := preload("res://tests/belt_sim_replay.gd")
	for c in tile:
		var shift := Vector2i(0, c * 256 * 400)
		var keys := PackedInt64Array()
		keys.resize(metas.size() + 1)
		for j in metas.size():
			var m: Array = metas[j]
			var key := (int(m[0]) + c * 10000000) * 8 + int(m[5])
			keys[j + 1] = key
			var e: Array = m[7]
			var mid: Array = m[8]
			var en: Array = m[9]
			sim.set_lane(key, ReplayT.kind_of(m), int(m[6]), int(m[10]), Vector2i(int(e[0]), int(e[1])) + shift,
				Vector2i(int(mid[0]), int(mid[1])) + shift, Vector2i(int(en[0]), int(en[1])) + shift, 0, 0)
		var per := {}
		for i in range(1, first.size(), 5):
			var k := keys[int(first[i])]
			if not per.has(k):
				per[k] = PackedInt64Array()
			var a: PackedInt64Array = per[k]
			a.append_array([int(first[i + 1]) + c * 100000000, int(first[i + 4]), int(first[i + 2]), int(first[i + 3])])
			per[k] = a
		for k in per:
			var a2: PackedInt64Array = per[k]
			# (front first: sort by position)
			var idx: Array = range(a2.size() / 4)
			idx.sort_custom(func(x: int, y: int) -> bool: return a2[x * 4 + 2] < a2[y * 4 + 2])
			var s := PackedInt64Array()
			for x in idx:
				s.append_array(a2.slice(x * 4, x * 4 + 4))
			sim.load_lane(k, sim.tick, s)
