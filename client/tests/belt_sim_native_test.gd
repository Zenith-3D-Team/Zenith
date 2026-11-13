extends SceneTree
## BeltSimNative (the C++ twin, client/native/belt_sim) against belt_sim.gd, step for step: both are
## given the same calls and must answer the same, every tick: items_state(), take_changes() (every
## change, item gone and mismatch, in order), stats() and the counters.
##
##   godot --headless --path client -s res://tests/belt_sim_native_test.gd -- [rec.json] [--ticks=N]
##
## Worlds: the replay fixture (tests/data/belt_sim_small.json) with the game's oracle and with edges
## stopping, then a synthetic one (loops, runs ending nowhere, side-loads, a splitter) where items are
## put on and taken off at random, lanes dropped and sent again, belts switched off and on, drift
## checks made. Exits 1 at the first difference; skips (exit 0) when the extension isn't loaded.
## Worlds 2 and 3 have closed rings of lanes (cut into two lines: every lane must have one, and items
## arriving into the line past the cut before it is stepped stand that tick); world 1's loops are open.
## A loop side-loading onto its own first belt (one line side-loading onto its own back lane, which
## crashed the C++ twin on Aquilo) runs sparse and packed.

const BeltSim := preload("res://scripts/world/belt_sim.gd")
const Replay := preload("res://tests/belt_sim_replay.gd")
const DEFAULT := "res://tests/data/belt_sim_small.json"
const STATE_KEYS := ["uid", "item", "stack", "key", "pos", "tick", "speed", "reach", "run", "gone", "gone_tick", "gone_at", "mismatch"]

var gd: RefCounted
var nat: RefCounted
var fails := 0
var checked := 0


## Both simulations, called alike.
func both(method: String, args: Array = []) -> void:
	gd.callv(method, args)
	nat.callv(method, args)


func compare(where: String) -> bool:
	checked += 1
	for i in gd.l_key.size():
		if gd.l_alive[i] == 1 and gd.l_line[i] < 0:
			return _fail(where, "belt_sim.gd's lane %d has no line" % int(gd.l_key[i]))
	# (Before items_state(), which works the lines' motion out: lane_fronts reads them as they stand.)
	var keys := PackedInt64Array()
	for i in gd.l_key.size():
		if gd.l_alive[i] == 1:
			keys.append(gd.l_key[i])
	var fa: PackedInt32Array = gd.lane_fronts(keys)
	var fb: PackedInt32Array = nat.lane_fronts(keys)
	if fa != fb:
		return _fail(where, "lane_fronts differ (%d lanes)" % keys.size())
	var a: Array = gd.items_state()
	var b: Array = nat.items_state()
	if a != b:
		return _fail(where, "items_state: %d items against %d" % [(a[0] as PackedInt64Array).size(), (b[0] as PackedInt64Array).size()])
	var ca: Dictionary = gd.take_changes()
	var cb: Dictionary = nat.take_changes()
	for k in STATE_KEYS:
		if ca[k] != cb[k]:
			return _fail(where, "take_changes %s: %s against %s" % [k, str(ca[k]).left(200), str(cb[k]).left(200)])
	if gd.stats() != nat.stats():
		return _fail(where, "stats %s against %s" % [gd.stats(), nat.stats()])
	if gd.n_past_back != nat.n_past_back or gd.n_carried != nat.n_carried or gd.n_shifted != nat.n_shifted:
		return _fail(where, "read counters: past back %d/%d carried %d/%d shifted %d/%d" % [gd.n_past_back, nat.n_past_back,
			gd.n_carried, nat.n_carried, gd.n_shifted, nat.n_shifted])
	if gd.n_held != nat.n_held or gd.n_woke != nat.n_woke:
		return _fail(where, "held crossings %d/%d, woke %d/%d" % [gd.n_held, nat.n_held, gd.n_woke, nat.n_woke])
	if gd.n_line_steps != nat.n_line_steps or gd.prof != nat.prof or gd.tick != nat.tick:
		return _fail(where, "counters: steps %d/%d prof %s/%s tick %d/%d" % [gd.n_line_steps, nat.n_line_steps,
			gd.prof, nat.prof, gd.tick, nat.tick])
	if gd.why_tick != nat.why_tick or gd.why_mark != nat.why_mark:
		return _fail(where, "why_tick %s/%s why_mark %s/%s" % [gd.why_tick, nat.why_tick, gd.why_mark, nat.why_mark])
	if gd.given != nat.given:
		return _fail(where, "given differs")
	return true


func _fail(where: String, what: String) -> bool:
	fails += 1
	printerr("DIFF at %s: %s" % [where, what])
	return false


## The records as they were (--belt-draw-head-move=off): the last pass, both alike too.
var head_move := true
## Reads as before --belt-sim-read-apply (items a read leaves past a line's back end stay there): a pass.
var read_bound := true
## Reads as before --belt-sim-read-conserve: a pass.
var read_conserve := true
## Reads as before --belt-sim-read-forward: a pass.
var read_forward := true
## Reads as before --belt-sim-shift-keep: a pass.
var shift_keep := true
## Splitters as before --belt-sim-split-wake: a pass.
var split_wake := true
## Reads as before --belt-sim-read-skip-same: a pass.
var read_skip_same := true


func _fresh(edge: int) -> void:
	gd = BeltSim.new()
	nat = ClassDB.instantiate("BeltSimNative")
	gd.edge_mode = edge
	nat.edge_mode = edge
	gd.ask_on_link = true
	nat.ask_on_link = true
	gd.head_move = head_move
	nat.head_move = head_move
	gd.read_bound = read_bound
	nat.read_bound = read_bound
	gd.read_conserve = read_conserve
	nat.read_conserve = read_conserve
	gd.read_forward = read_forward
	nat.read_forward = read_forward
	gd.shift_keep = shift_keep
	nat.shift_keep = shift_keep
	gd.split_wake = split_wake
	nat.split_wake = split_wake
	gd.read_skip_same = read_skip_same
	nat.read_skip_same = read_skip_same


func _initialize() -> void:
	if not ClassDB.class_exists("BeltSimNative"):
		print("BeltSimNative isn't loaded: nothing to compare (skipped)")
		quit(0)
		return
	var path := DEFAULT
	var max_ticks := 1 << 30
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--ticks="):
			max_ticks = int(a.substr(8))
		elif not a.begins_with("--"):
			path = a
	var t0 := Time.get_ticks_msec()
	for edge in [BeltSim.EDGE_ORACLE, BeltSim.EDGE_STOP, BeltSim.EDGE_RUN_OFF]:
		_recording(path, edge, max_ticks)
		print("recording, edge mode %d: %d checks, %d differences" % [edge, checked, fails])
		if fails > 0:
			break
	if fails == 0:
		for packed in [false, true]:
			_ring(packed)
			print("ring (%s): %d checks, %d differences" % ["packed" if packed else "sparse", checked, fails])
	if fails == 0:
		for packed in [false, true]:
			_self_side_loop(packed)
			print("loop side-loading onto itself (%s): %d checks, %d differences" % ["packed" if packed else "sparse", checked, fails])
	if fails == 0:
		for seed in [1, 2, 3]:
			_synthetic(seed, 1500)
			print("synthetic world %d: %d checks, %d differences (reads: %d items shifted, %d carried back, %d past a back end gone, %d carried on, %d gone past a front; %d crossings held, %d split_wake)" % [
				seed, checked, fails, gd.n_shifted, gd.n_carried, gd.n_past_back, gd.n_forward, gd.n_forward_gone, gd.n_held, gd.n_woke])
			if fails > 0:
				break
	if fails == 0:
		head_move = false
		_recording(path, BeltSim.EDGE_STOP, max_ticks)
		print("recording, edge mode 1, head_move off: %d checks, %d differences" % [checked, fails])
		if fails == 0:
			_synthetic(1, 1500)
			print("synthetic world 1, head_move off: %d checks, %d differences" % [checked, fails])
		head_move = true
	if fails == 0:
		read_bound = false
		_synthetic(2, 1500)
		print("synthetic world 2, read_bound off: %d checks, %d differences" % [checked, fails])
		read_bound = true
	if fails == 0:
		read_conserve = false
		_synthetic(3, 1500)
		print("synthetic world 3, read_conserve off: %d checks, %d differences" % [checked, fails])
		read_conserve = true
	if fails == 0:
		read_forward = false
		_synthetic(2, 1500)
		print("synthetic world 2, read_forward off: %d checks, %d differences" % [checked, fails])
		read_forward = true
	if fails == 0:
		shift_keep = false
		_synthetic(3, 1500)
		print("synthetic world 3, shift_keep off: %d checks, %d differences" % [checked, fails])
		shift_keep = true
	if fails == 0:
		split_wake = false
		_synthetic(1, 1500)
		print("synthetic world 1, split_wake off: %d checks, %d differences" % [checked, fails])
		split_wake = true
	if fails == 0:
		read_skip_same = false
		_synthetic(3, 1500)
		print("synthetic world 3, read_skip_same off: %d checks, %d differences" % [checked, fails])
		read_skip_same = true
	print("%s in %d ms: %d checks, %d differences" % ["PASS" if fails == 0 else "FAIL", Time.get_ticks_msec() - t0,
		checked, fails])
	quit(1 if fails > 0 else 0)


func _recording(path: String, edge: int, max_ticks: int) -> void:
	_fresh(edge)
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var metas: Array = d["lanes"]
	var names: Array = d.get("names", [])
	var ticks: Array = d["ticks"]
	var keys := PackedInt64Array([0])
	var kinds := PackedInt32Array([0])
	for m: Array in metas:
		var key := int(m[0]) * 8 + int(m[5])
		var kind := Replay.kind_of(m)
		keys.append(key)
		kinds.append(kind)
		var extra := 0
		if m.size() > 12 and m[12] is Array and (m[12] as Array).size() >= 2:
			extra = Replay.prio(m[12][0]) + 3 * Replay.prio(m[12][1])
			if (m[12] as Array).size() >= 3 and str(m[12][2]) != "":
				extra += 9 * (names.find(str(m[12][2])) + 1)
		var next_key := 0
		if str(m[2]) == "underground-belt" and str(m[3]) == "input" and int(m[5]) <= 2:
			next_key = key + 2
		var e: Array = m[7]
		var mid: Array = m[8]
		var en: Array = m[9]
		both("set_lane", [key, kind, int(m[6]), int(m[10]), Vector2i(int(e[0]), int(e[1])),
			Vector2i(int(mid[0]), int(mid[1])), Vector2i(int(en[0]), int(en[1])), extra, next_key])
	var first: Array = ticks[0]
	both("step_to", [int(first[0])])
	for i in range(1, first.size(), 5):
		both("put_item", [keys[int(first[i])], int(first[i + 1]), int(first[i + 4]), int(first[i + 3]), int(first[i + 2])])
	both("mark_split_holds")
	if not compare("recording set-up"):
		return
	for t in range(mini(ticks.size(), max_ticks) - 1):
		var row: Array = ticks[t + 1]
		var game := {}
		for i in range(1, row.size(), 5):
			game[int(row[i + 1])] = [keys[int(row[i])], int(row[i + 2]), kinds[int(row[i])], int(row[i + 4]), int(row[i + 3])]
		gd.oracle = game
		nat.oracle = game
		both("step_to", [int(row[0])])
		var st: Array = gd.items_state()
		if not compare("recording tick %d" % int(row[0])):
			return
		var where := {}
		for u in st[0]:
			where[u] = true
		for u in st[0]:
			if not game.has(u):
				both("take_item", [u, false])
		for u in game:
			if not where.has(u):
				var g: Array = game[u]
				both("put_item", [int(g[0]), u, int(g[3]), int(g[4]), int(g[1])])
		# Drift checks against the game's own lanes now and then (mismatches must agree too).
		if t % 7 == 0:
			var per := {}
			for u in game:
				var g2: Array = game[u]
				var a: Array = per.get(g2[0], [0, 1 << 30, -1])
				per[g2[0]] = [a[0] + 1, mini(a[1], g2[1]), maxi(a[2], g2[1])]
			for k in per:
				both("check_lane", [k, int(row[0]) + 1, per[k][0], per[k][1], per[k][2]])


## A random world: rows of straight belts (some loops of straights and curves, some runs ending
## nowhere), side-loads onto them, a splitter, and random edits every tick.
func _synthetic(seed: int, n_ticks: int) -> void:
	_fresh(BeltSim.EDGE_STOP if seed != 3 else BeltSim.EDGE_RUN_OFF)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var lanes: Array = []  # [key, kind, length, step, p0, pm, p1, extra, next]
	var unit := 1
	both("step_to", [0])
	var speeds := [8, 16, 24, 32]
	for row in 12:
		var y := row * 6 * 256
		var step: int = speeds[rng.randi_range(0, 3)]
		var n := rng.randi_range(6, 30)
		if row % 3 == 0:
			# A loop: n straights east, a curve, n straights west, a curve.
			var p := Vector2i(0, y)
			var dirs := [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]
			var lens := [n, 2, n, 2]
			for side in 4:
				var dv: Vector2i = dirs[side]
				for k in lens[side]:
					var q: Vector2i = p + dv * 256
					lanes.append([unit * 8 + 1, BeltSim.STRAIGHT, 256, step, q, (p + q) / 2, p, 0, 0])
					unit += 1
					p = q
				if side == 3 and seed == 1:
					break  # (open: rings only in worlds 2 and 3)
				var nd: Vector2i = dirs[(side + 1) % 4]
				var q2: Vector2i = p + (dv + nd) * 53
				lanes.append([unit * 8 + 1, BeltSim.CURVE, 106, step, q2, (p + q2) / 2, p, 0, 0])
				unit += 1
				p = q2
		else:
			# A run ending nowhere (two lanes side by side), with a side-load onto its middle.
			for lane_line in [1, 2]:
				var off := 0 if lane_line == 1 else 128
				for k in n:
					var en := Vector2i(k * 256, y + off)
					var ex := en + Vector2i(256, 0)
					lanes.append([(unit + k) * 8 + lane_line, BeltSim.STRAIGHT, 256, step, ex, (en + ex) / 2, en, 0, 0])
			var mid := (n / 2) * 256 + 128
			# A belt coming in from the north whose exit is level with the run's lane 1, across it.
			for k in 3:
				var ex2 := Vector2i(mid, y - 100 - k * 256)
				lanes.append([(unit + n + k) * 8 + 1, BeltSim.STRAIGHT, 256, step, ex2, ex2 - Vector2i(0, 128), ex2 - Vector2i(0, 256), 0, 0])
			unit += n + 4
	# A splitter fed by two lanes, its outputs leading on into two short runs.
	var sy := 80 * 256
	var su := unit
	unit += 1
	var sx := 2000 * 256
	var extra_sp := 0 if seed == 1 else (1 + 3 * 2)  # (seed 2, 3: input and output priorities)
	for line in [1, 3]:
		var x := sx + (0 if line == 1 else 128)
		lanes.append([su * 8 + line, BeltSim.SPLIT_IN, 128, 8, Vector2i(x, sy), Vector2i(x, sy + 64), Vector2i(x, sy + 128), extra_sp, 0])
	for line in [5, 7]:
		var x2 := sx + (0 if line == 5 else 128)
		lanes.append([su * 8 + line, BeltSim.SPLIT_OUT, 128, 8, Vector2i(x2, sy - 128), Vector2i(x2, sy - 64), Vector2i(x2, sy), extra_sp, 0])
	for line in [1, 3]:
		var x3 := sx + (0 if line == 1 else 128)
		for k in 6:
			lanes.append([unit * 8 + 1, BeltSim.STRAIGHT, 256, 8, Vector2i(x3, sy + 128 + k * 256), Vector2i(x3, sy + 256 + k * 256),
				Vector2i(x3, sy + 384 + k * 256), 0, 0])
			unit += 1
		for k in 4:
			lanes.append([unit * 8 + 1, BeltSim.STRAIGHT, 256, 8, Vector2i(x3, sy - 384 - k * 256), Vector2i(x3, sy - 256 - k * 256),
				Vector2i(x3, sy - 128 - k * 256), 0, 0])
			unit += 1
	for l: Array in lanes:
		both("set_lane", l)
	var uid := 1
	for l: Array in lanes:
		if rng.randf() < 0.6:
			var items := PackedInt64Array()
			var pos := int(l[2]) - 1 - rng.randi_range(0, 30)
			while pos >= 0:
				items.append_array([uid, rng.randi_range(1, 5), pos, rng.randi_range(1, 4)])
				uid += 1
				pos -= rng.randi_range(64, 200) if rng.randf() < 0.5 else 64
			# (front first)
			var sorted := PackedInt64Array()
			for j in range(items.size() / 4 - 1, -1, -1):
				sorted.append_array(items.slice(j * 4, j * 4 + 4))
			both("load_lane", [l[0], 0, sorted])
	both("step_to", [1])
	if not compare("synthetic %d set-up" % seed):
		return
	var dropped: Array = []
	for t in range(2, n_ticks):
		var r := rng.randf()
		if r < 0.25:
			var l2: Array = lanes[rng.randi_range(0, lanes.size() - 1)]
			both("put_item", [l2[0], uid, rng.randi_range(1, 5), 1, rng.randi_range(0, int(l2[2]) - 1)])
			uid += 1
		elif r < 0.45 and uid > 2:
			both("take_item", [rng.randi_range(1, uid - 1), rng.randf() < 0.5])
		elif r < 0.5:
			var l3: Array = lanes[rng.randi_range(0, lanes.size() - 1)]
			both("set_off", [(int(l3[0]) - 1) >> 3, rng.randf() < 0.6, t])
		elif r < 0.53:
			var l4: Array = lanes[rng.randi_range(0, lanes.size() - 1)]
			both("drop_lane", [l4[0]])
			dropped.append(l4)
		elif r < 0.58 and not dropped.is_empty():
			both("set_lane", dropped.pop_back())
		elif r < 0.62:
			var l5: Array = lanes[rng.randi_range(0, lanes.size() - 1)]
			both("check_lane", [l5[0], t, rng.randi_range(0, 3), rng.randi_range(0, 255), rng.randi_range(0, 255)])
		elif r < 0.64:
			var l6: Array = lanes[rng.randi_range(0, lanes.size() - 1)]
			var it := PackedInt64Array([uid, 2, rng.randi_range(0, int(l6[2]) - 1), 1])
			uid += 1
			both("load_lane", [l6[0], t + rng.randi_range(0, 3), it])
		elif r < 0.70:
			# A lane read again as the simulation has it moved by a few steps or a gap either way, its packed
			# run moving with it (and what that leaves past a line's back end carried back).
			var l8: Array = lanes[rng.randi_range(0, lanes.size() - 1)]
			var st: Array = gd.items_state()
			var d: int = [-64, -24, -8, 8, 16, 24, 64][rng.randi_range(0, 6)]
			var rd := PackedInt64Array()
			for j in (st[0] as PackedInt64Array).size():
				if int(st[1][j]) == int(l8[0]):
					var np := clampi(int(st[2][j]) + d, 0, int(l8[2]) - 1)
					rd.append_array([st[0][j], 1, np, 1])
			var sorted2 := PackedInt64Array()
			var last := -1000
			for j in rd.size() / 4:
				if rd[j * 4 + 2] - last >= 64:
					sorted2.append_array(rd.slice(j * 4, j * 4 + 4))
					last = rd[j * 4 + 2]
			both("load_lane", [l8[0], t, sorted2])
		elif r < 0.72 and not dropped.is_empty():
			# A lane coming back with an update: its meta as of its read's tick, a tick or two on.
			var l9: Array = dropped.pop_back()
			var at := t + rng.randi_range(1, 3)
			both("set_lane_at", [at, l9[0], l9[1], l9[2], l9[3], l9[4], l9[5], l9[6], l9[7], l9[8], rng.randf() < 0.3])
			both("load_lane", [l9[0], at, PackedInt64Array([uid, 3, int(l9[2]) - 1, 1])])
			uid += 1
		elif r < 0.76:
			# A splitter input the bridge found as its last read left it (`sh`): as the simulation has it, or
			# moved a few steps (put back so), then held till its next read.
			var ins: Array = []
			for l10: Array in lanes:
				if int(l10[1]) == BeltSim.SPLIT_IN:
					ins.append(l10)
			if not ins.is_empty():
				var l11: Array = ins[rng.randi_range(0, ins.size() - 1)]
				var st2: Array = gd.items_state()
				var d2: int = [0, 0, 8, 16, -8][rng.randi_range(0, 4)]
				var hi := PackedInt64Array()
				var last2 := -1000
				for j in (st2[0] as PackedInt64Array).size():
					if int(st2[1][j]) == int(l11[0]):
						var np2 := clampi(int(st2[2][j]) + d2, 0, int(l11[2]) - 1)
						if np2 - last2 >= 64:
							hi.append_array([st2[0][j], 1, np2, 1])
							last2 = np2
				both("hold_input", [l11[0], t, hi])
		if t % 211 == 0:
			both("skip_to", [t + rng.randi_range(1, 40)])
		if t % 97 == 0:
			for l7: Array in lanes:
				if gd.run_of(l7[0]) != nat.run_of(l7[0]):
					_fail("synthetic %d tick %d" % [seed, t], "run_of(%d)" % int(l7[0]))
					return
				if gd.next_of(l7[0]) != nat.next_of(l7[0]):
					_fail("synthetic %d tick %d" % [seed, t], "next_of(%d)" % int(l7[0]))
					return
			if gd.debug_links() != nat.debug_links():
				_fail("synthetic %d tick %d" % [seed, t], "debug_links")
				return
		both("step_to", [maxi(t, int(gd.tick)) + rng.randi_range(0, 2)])
		if not compare("synthetic %d tick %d" % [seed, t]):
			return


## A closed ring of lanes alone (two speeds, a curve at each corner) whose items go round and round:
## none may be lost or made, none closer than 64 behind another on its lane, every tick.
func _ring(packed: bool) -> void:
	_fresh(BeltSim.EDGE_STOP)
	both("step_to", [0])
	var p := Vector2i(0, 0)
	var dirs := [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]
	var keys: Array = []
	var lens: Array = []
	var unit := 1
	for side in 4:
		var dv: Vector2i = dirs[side]
		for k in 3:
			var q: Vector2i = p + dv * 256
			both("set_lane", [unit * 8 + 1, BeltSim.STRAIGHT, 256, 8, q, (p + q) / 2, p, 0, 0])
			keys.append(unit * 8 + 1)
			lens.append(256)
			unit += 1
			p = q
		var nd: Vector2i = dirs[(side + 1) % 4]
		var q2: Vector2i = p + (dv + nd) * 53
		both("set_lane", [unit * 8 + 1, BeltSim.CURVE, 106, 8, q2, (p + q2) / 2, p, 0, 0])
		keys.append(unit * 8 + 1)
		lens.append(106)
		unit += 1
		p = q2
	# Items every `spacing` along the ring (distance g from the first lane's entry), the gap across
	# the place where the ring closes at least as big.
	var total := 0
	for l in lens:
		total += int(l)
	var spacing := 64 if packed else 150
	var n := total / spacing
	var start := 0
	var g := 0
	var uid := 1
	for j in keys.size():
		var items := PackedInt64Array()
		while g < n * spacing and g < start + int(lens[j]):
			items.append_array([uid, 1, int(lens[j]) - 1 - (g - start), 1])
			uid += 1
			g += spacing
		var front := PackedInt64Array()
		for e in range(items.size() / 4 - 1, -1, -1):
			front.append_array(items.slice(e * 4, e * 4 + 4))
		both("load_lane", [keys[j], 0, front])
		start += int(lens[j])
	for t in range(1, 700):
		both("step_to", [t])
		if not compare("ring tick %d" % t):
			return
		var st: Array = gd.items_state()
		if (st[0] as PackedInt64Array).size() != n:
			_fail("ring tick %d" % t, "%d items, %d put on" % [(st[0] as PackedInt64Array).size(), n])
			return
		var per := {}
		for i in (st[0] as PackedInt64Array).size():
			var a: Array = per.get(st[1][i], [])
			a.append(int(st[2][i]))
			per[st[1][i]] = a
		for k in per:
			var a2: Array = per[k]
			a2.sort()
			for i in range(1, a2.size()):
				if a2[i] - a2[i - 1] < 64:
					_fail("ring tick %d" % t, "lane %d: items %d apart" % [int(k), a2[i] - a2[i - 1]])
					return


## A loop of yellow belts whose last belt side-loads onto the middle of its first, as one on Aquilo
## (the C++ twin crashed there): the loop is one line whose front side-loads onto its own back lane.
## The lanes as set_lane's arguments; the first is the one side-loaded onto. (ui_test.gd's
## _belt_self_side runs it too.)
static func self_side_loop_lanes() -> Array:
	var pts := [Vector2i(-256, 0), Vector2i(0, 0), Vector2i(256, 0), Vector2i(512, 0), Vector2i(768, 0),
		Vector2i(768, -256), Vector2i(768, -512), Vector2i(512, -512), Vector2i(256, -512), Vector2i(0, -512),
		Vector2i(-128, -512), Vector2i(-128, -256), Vector2i(-128, -100)]
	var lanes: Array = []
	for i in pts.size() - 1:
		var p1: Vector2i = pts[i]
		var p0: Vector2i = pts[i + 1]
		lanes.append([(i + 1) * 8 + 1, BeltSim.STRAIGHT, roundi((p0 - p1).length()), 8, p0, (p0 + p1) / 2, p1, 0, 0])
	return lanes


## Its items, lane key -> load_lane's items (front first), uids from 1: sparse, the first 30 short of
## the side-loading lane's end and three more round the loop; packed, one every 64 all the way round.
static func self_side_loop_items(lanes: Array, packed: bool) -> Dictionary:
	var out := {}
	var uid := 1
	var last: Array = lanes[lanes.size() - 1]
	if not packed:
		out[last[0]] = PackedInt64Array([uid, 1, 30, 1])
		uid += 1
		for j in [2, 5, 8]:
			out[lanes[j][0]] = PackedInt64Array([uid, 1, 100, 1])
			uid += 1
		return out
	for l: Array in lanes:
		var items := PackedInt64Array()
		var pos := 0
		while pos <= int(l[2]) - 64:
			items.append_array([uid, 1, pos, 1])
			uid += 1
			pos += 64
		out[l[0]] = items
	return out


## The loop side-loading onto itself: both alike every tick, no item lost or made, and (sparse) the
## first item round the loop and over the side-load more than once.
func _self_side_loop(packed: bool) -> void:
	_fresh(BeltSim.EDGE_STOP)
	both("step_to", [0])
	var lanes := self_side_loop_lanes()
	for l: Array in lanes:
		both("set_lane", l)
	var loads := self_side_loop_items(lanes, packed)
	var n := 0
	for key in loads:
		both("load_lane", [key, 0, loads[key]])
		n += (loads[key] as PackedInt64Array).size() / 4
	var first_lane: int = lanes[0][0]
	var side_lane: int = lanes[lanes.size() - 1][0]
	var crossings := 0
	var was_on := side_lane
	for t in range(1, 900):
		both("step_to", [t])
		if not compare("self side-load loop tick %d" % t):
			return
		var st: Array = gd.items_state()
		if (st[0] as PackedInt64Array).size() != n:
			_fail("self side-load loop tick %d" % t, "%d items, %d put on" % [(st[0] as PackedInt64Array).size(), n])
			return
		var i1 := (st[0] as PackedInt64Array).find(1)
		var on: int = int(st[1][i1]) if i1 >= 0 else -1
		if was_on == side_lane and on == first_lane:
			crossings += 1
		was_on = on
	if not packed and crossings < 2:
		_fail("self side-load loop", "the first item went over the side-load %d times in 900 ticks (2 laps)" % crossings)
