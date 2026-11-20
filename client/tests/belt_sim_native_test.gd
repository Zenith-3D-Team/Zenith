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
const NativeLibrary := preload("res://scripts/native_library.gd")
const Replay := preload("res://tests/belt_sim_replay.gd")
const DEFAULT := "res://tests/data/belt_sim_small.json"
const STATE_KEYS := ["uid", "item", "stack", "key", "pos", "tick", "speed", "reach", "run", "num", "gone", "gone_tick", "gone_at", "mismatch",
	"mismatch_n", "hand_uid", "hand_tick", "hand_ins", "hand_key", "hand_pos", "hand_why"]

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
	for speed_of in 4:
		var fa: PackedInt32Array = gd.lane_fronts(keys, speed_of)
		var fb: PackedInt32Array = nat.lane_fronts(keys, speed_of)
		if fa != fb:
			return _fail(where, "lane_fronts differ (%d lanes, speed_of %d)" % [keys.size(), speed_of])
	# (belt_lattice.gd tail) Whether nothing comes close behind each lane's entry.
	for need in [64, 128, 600]:
		if gd.lane_tails(keys, need) != nat.lane_tails(keys, need):
			return _fail(where, "lane_tails differ (need %d)" % need)
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
	if gd.n_hand != nat.n_hand:
		return _fail(where, "hand counters %s against %s" % [gd.n_hand, nat.n_hand])
	if gd.n_rescue_denied != nat.n_rescue_denied:
		return _fail(where, "rescues denied %d/%d" % [gd.n_rescue_denied, nat.n_rescue_denied])
	if gd.n_take_read != nat.n_take_read or gd.n_take_rescued != nat.n_take_rescued:
		return _fail(where, "takes made at a read %d/%d, from a push-back %d/%d" % [gd.n_take_read, nat.n_take_read,
			gd.n_take_rescued, nat.n_take_rescued])
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
## Takes and reads in the order they came, as before --belt-sim-take-first: a pass.
var take_first := true
## Takes after the reads of their tick, the nearest the hand, reads by id alone, as before --belt-sim-take-line: a pass.
var take_line := true
## A take looks only on its belt's own lanes, as before --belt-sim-take-edge: a pass.
var take_edge := true
## A tunnel with no next links like a belt, as before --belt-sim-ug-guard: a pass.
var ug_guard := true
## Reads put back every item they haven't behind or ahead of their own, as before --belt-sim-rescue-seen: a pass.
var rescue_seen := true


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
	gd.take_first = take_first
	nat.take_first = take_first
	gd.take_line = take_line
	nat.take_line = take_line
	gd.take_edge = take_edge
	nat.take_edge = take_edge
	gd.ug_guard = ug_guard
	nat.ug_guard = ug_guard
	gd.rescue_seen = rescue_seen
	nat.rescue_seen = rescue_seen


func _initialize() -> void:
	if not NativeLibrary.ensure():
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
		_take_before_read()
	if fails == 0:
		_take_at_line_end()
	if fails == 0:
		_tails_case()
	if fails == 0:
		_take_at_front_edge()
	if fails == 0:
		_rescue_seen_case()
	if fails == 0:
		_ug_guard_case()
	if fails == 0:
		_ug_exit_later()
	if fails == 0:
		for seed in [1, 2, 3]:
			_synthetic(seed, 1500)
			print("synthetic world %d: %d checks, %d differences (reads: %d items shifted, %d carried back, %d past a back end gone, %d carried on, %d gone past a front; %d crossings held, %d split_wake; hand-off: %d taken, %d read first, %d none near, %d put, %d had)" % [
				seed, checked, fails, gd.n_shifted, gd.n_carried, gd.n_past_back, gd.n_forward, gd.n_forward_gone, gd.n_held, gd.n_woke,
				gd.n_hand[0], gd.n_hand[1], gd.n_hand[2], gd.n_hand[3], gd.n_hand[4]])
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
	if fails == 0:
		take_first = false
		_synthetic(2, 1500)
		print("synthetic world 2, take_first off: %d checks, %d differences" % [checked, fails])
		take_first = true
	if fails == 0:
		take_line = false
		_synthetic(2, 1500)
		print("synthetic world 2, take_line off: %d checks, %d differences" % [checked, fails])
		take_line = true
	if fails == 0:
		take_edge = false
		_synthetic(1, 1500)
		print("synthetic world 1, take_edge off: %d checks, %d differences" % [checked, fails])
		take_edge = true
	if fails == 0:
		rescue_seen = false
		_synthetic(3, 1500)
		print("synthetic world 3, rescue_seen off: %d checks, %d differences" % [checked, fails])
		rescue_seen = true
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
		elif r < 0.74:
			# (--inserter-handoff) An inserter's take near an item of a lane (a tick or two either side of now,
			# off the item by up to half a tile, the kind right or any), or its put of a new item (or of one
			# already there).
			var l12: Array = lanes[rng.randi_range(0, lanes.size() - 1)]
			var u12 := (int(l12[0]) - 1) >> 3
			var at12 := t + rng.randi_range(-2, 2)
			var p0: Vector2i = l12[4]
			var p1: Vector2i = l12[6]
			var f := rng.randf()
			var hx := int(lerpf(p0.x, p1.x, f)) + rng.randi_range(-128, 128)
			var hy := int(lerpf(p0.y, p1.y, f)) + rng.randi_range(-128, 128)
			if rng.randf() < 0.6:
				var ta := [at12 + rng.randi_range(0, 6), u12, rng.randi_range(0, 5), rng.randi_range(1, 3), hx, hy]
				var pa: PackedInt64Array = gd.callv("peek_take", ta)
				var pb: PackedInt64Array = nat.callv("peek_take", ta)
				if pa != pb:
					_fail("synthetic %d tick %d" % [seed, t], "peek_take %s against %s" % [pa, pb])
					return
				both("take_at", [at12, u12, rng.randi_range(0, 5), rng.randi_range(1, 3), hx, hy, 9000 + rng.randi_range(0, 9)])
			else:
				var pu := uid if rng.randf() < 0.8 else rng.randi_range(1, uid)
				if pu == uid:
					uid += 1
				both("put_at", [at12, l12[0], pu, rng.randi_range(1, 5), rng.randi_range(1, 4), rng.randi_range(0, int(l12[2]) - 1), 9000])
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


## K9 (owner: "when an item is picked up off a belt the items behind it jump to the start of the belt"): a
## hand takes the only item of a belt's lane and the bridge reads that lane, empty, on the take's tick. Three
## yellow belts in a line (units 1-3, east), one item on each; the hand takes belt 2's at tick 10. The read and
## the take come in four orders: the take first; the read first (the bridge sends `bs` before `ie` in a tick:
## the read used to push the taken item back to the start of belt 2 and the item behind with it); the read a
## tick before the pick's stamp (the mod saw the pick at its check a tick after the hand closed); the take
## coming after the simulation had applied the read. Both twins alike every tick, the taken item gone and
## reported taken, and (but in the last order, where the read's push-back of the item behind it already
## happened) no item ever moving back. With take_first off the read-first order still jumps (the old way).
func _take_before_read() -> void:
	var at_read := 0
	var from_push := 0
	for take_first in [true, false]:
		for order in ["take first", "read first", "late stamp", "late event"]:
			_fresh(BeltSim.EDGE_STOP)
			gd.take_first = take_first
			nat.take_first = take_first
			# (The old way is both off: take_line puts a tick's takes before its reads whatever came first.)
			gd.take_line = take_first
			nat.take_line = take_first
			# (And rescue_seen, which lets the read's taken item go: the old way pushed it back.)
			gd.rescue_seen = take_first
			nat.rescue_seen = take_first
			both("step_to", [0])
			for u in [1, 2, 3]:
				var ex := Vector2i((u + 1) * 256, 2560)
				var en := Vector2i(u * 256, 2560)
				both("set_lane", [u * 8 + 1, BeltSim.STRAIGHT, 256, 8, ex, (ex + en) / 2, en, 0, 0])
			both("load_lane", [3 * 8 + 1, 0, PackedInt64Array([30, 1, 200, 1])])
			both("load_lane", [2 * 8 + 1, 0, PackedInt64Array([20, 1, 128, 1])])
			both("load_lane", [1 * 8 + 1, 0, PackedInt64Array([10, 1, 100, 1])])
			both("step_to", [1])
			var where := "take before read (%s, take_first %s)" % [order, take_first]
			if not compare(where + " set-up"):
				return
			match order:
				"take first":
					both("take_at", [10, 2, 1, 1, 720, 2560, 99])
					both("load_lane", [2 * 8 + 1, 10, PackedInt64Array()])
				"read first":
					both("load_lane", [2 * 8 + 1, 10, PackedInt64Array()])
					both("take_at", [10, 2, 1, 1, 720, 2560, 99])
				"late stamp":
					both("load_lane", [2 * 8 + 1, 9, PackedInt64Array()])
					both("take_at", [10, 2, 1, 1, 728, 2560, 99])
				"late event":
					both("load_lane", [2 * 8 + 1, 10, PackedInt64Array()])
			var last := {}
			var back := 0
			var taken := 0
			for t in range(2, 40):
				if order == "late event" and t == 12:
					both("take_at", [10, 2, 1, 1, 720, 2560, 99])
				both("step_to", [t])
				var ch: Dictionary = gd.take_changes()
				var chn: Dictionary = nat.take_changes()
				for k in STATE_KEYS:
					if ch[k] != chn[k]:
						_fail("%s tick %d" % [where, t], "take_changes %s: %s against %s" % [k, str(ch[k]).left(200), str(chn[k]).left(200)])
						return
				for j in (ch["hand_why"] as PackedInt32Array).size():
					if int(ch["hand_why"][j]) == BeltSim.HAND_TAKEN and int(ch["hand_uid"][j]) == 20:
						taken += 1
				if not compare("%s tick %d" % [where, t]):
					return
				var st: Array = gd.items_state()
				for j in (st[0] as PackedInt64Array).size():
					var u: int = st[0][j]
					var line_pos: int = int(st[2][j]) + (3 - (int(st[1][j]) >> 3)) * 256
					if last.has(u) and line_pos > int(last[u]):
						back += 1
					last[u] = line_pos
			at_read += gd.n_take_read
			from_push += gd.n_take_rescued
			var left: PackedInt64Array = gd.items_state()[0]
			if take_first:
				var ok: bool = taken == 1 and not left.has(20) and left.size() == 2 and (back == 0 or order == "late event")
				if not ok:
					_fail(where, "the taken item: reported taken %d times, still on the belts %s, %d moves back" % [taken, left.has(20), back])
					return
			elif order == "read first" and (back == 0 or not left.has(20)):
				_fail(where, "with take_first off the read first should push the taken item back as before (%d moves back)" % back)
				return
	print("take before read: %d checks, %d differences (take_first: %d taken at a read, %d from a read's push-back)" % [
		checked, fails, at_read, from_push])


## K19 (owner: "belt items all of a sudden jump around ... an item reaching the end"): --belt-sim-take-line. A
## line of six yellow belts that ends (units 1-6, west: unit 1 at the end), packed with one kind from its end
## to its back, 24 items a gap apart. A hand over belt 3 takes an item; the bridge reads the lanes round it on
## the take's tick and sends them before the hand's event, the lane behind the pickup lane first, each as the
## game has it a tick into closing the hole. Three cases, both twins alike every tick:
##  - "front": the taken item is the pickup lane's front one. The old way the read of the lane behind moved it
##    across the belt's edge with the run in front, the take found its belt read and did nothing, and the item
##    stayed: 24 items where the game has 23, the line's front items past its end. Now 23, none past the end,
##    none closer than a gap to another, every one where the game has one.
##  - "neighbour": the event's hand is two ticks into its swing, nearer the item behind the taken one, and the
##    pickup lane's read comes an update later (the take made first, by the hand alone: the wrong one). The
##    line closes to the game's places under other ids; the read then tells the two apart and moves nothing.
##  - "known": the same hand, the pickup lane's read queued when the take is made: the take takes the item the
##    read hasn't, whatever the hand is nearest.
## With take_line off (the old way) "front" keeps the taken item.
## (belt_lattice.gd tail) lane_tails on a line of six belts going west (belt 1 its front, belt 6 its back, fed by no
## lane: the square's edge): belt 1 full, belt 2 one item at its exit. Nothing behind belt 2 or 5 for 128 (1); an item
## right behind belt 1 (0); belt 6, where what feeds it isn't known (0).
func _tails_case() -> void:
	_fresh(BeltSim.EDGE_STOP)
	both("step_to", [0])
	for u in range(1, 7):
		var ex := Vector2i((u - 1) * 256, 2560)
		var en := Vector2i(u * 256, 2560)
		both("set_lane", [u * 8 + 1, BeltSim.STRAIGHT, 256, 8, ex, (ex + en) / 2, en, 0, 0])
	var its := PackedInt64Array()
	for k in 4:
		its.append_array([100 + k, 7, 64 * k, 1])
	both("load_lane", [9, 0, its])
	both("load_lane", [17, 0, PackedInt64Array([110, 7, 0, 1])])
	both("step_to", [1])
	if not compare("lane tails"):
		return
	var keys := PackedInt64Array([9, 17, 41, 49])
	var want := PackedInt32Array([0, 1, 1, 0])
	for sim in [gd, nat]:
		var got: PackedInt32Array = sim.lane_tails(keys, 128)
		if got != want:
			_fail("lane tails", "%s: %s, not %s" % ["belt_sim.gd" if sim == gd else "BeltSimNative", str(got), str(want)])
			return
	print("lane tails: as wanted")


func _take_at_line_end() -> void:
	var known_n := 0
	for on in [true, false]:
		for case in ["front", "neighbour", "known"]:
			_fresh(BeltSim.EDGE_STOP)
			gd.take_line = on
			nat.take_line = on
			both("step_to", [0])
			for u in range(1, 7):
				var ex := Vector2i((u - 1) * 256, 2560)
				var en := Vector2i(u * 256, 2560)
				both("set_lane", [u * 8 + 1, BeltSim.STRAIGHT, 256, 8, ex, (ex + en) / 2, en, 0, 0])
			# (Item 100 + 4 * (u - 1) + k at position 64 k of belt u: 100 at the line's end.)
			for u in range(1, 7):
				var its := PackedInt64Array()
				for k in 4:
					its.append_array([100 + 4 * (u - 1) + k, 7, 64 * k, 1])
				both("load_lane", [u * 8 + 1, 0, its])
			both("step_to", [1])
			var where := "take at a line's end (%s, take_line %s)" % [case, on]
			if not compare(where + " set-up"):
				return
			# The game: the hand takes at tick 9 (seen at 10); the items behind close up 8 a tick from 10 on.
			var taken := 108 if case == "front" else 110
			var game := {}  # uid -> place along the line (0 its end)
			for u in range(1, 7):
				for k in 4:
					game[100 + 4 * (u - 1) + k] = (u - 1) * 256 + 64 * k
			var taken_at: int = game[taken]
			game.erase(taken)
			var read_at := 10 if case != "neighbour" else 22
			var worst := 0
			var past_end := 0
			var close := 0
			var moved_at_read := 0
			for t in range(2, 60):
				if t >= 10:
					for u2: int in game:
						if int(game[u2]) > taken_at and int(game[u2]) - taken_at > 64 * ((int(game[u2]) - taken_at + 63) / 64 - 1):
							pass
					# (Each item behind the hole moves 8 until it is a gap behind the one in front.)
					var order: Array = game.keys()
					order.sort_custom(func(a: int, b: int) -> bool: return int(game[a]) < int(game[b]))
					var prev := -64
					for u2: int in order:
						game[u2] = mini(int(game[u2]), maxi(int(game[u2]) - 8, prev + 64))
						prev = int(game[u2])
				if t == read_at:
					# The reads, the lane behind first, then the pickup lane, as the game has them now; then
					# the hand's event (stamped 10): at the item for "front", 54 on along the belt otherwise.
					for u in [4, 3]:
						var its := PackedInt64Array()
						var order2: Array = game.keys()
						order2.sort_custom(func(a: int, b: int) -> bool: return int(game[a]) < int(game[b]))
						for u2: int in order2:
							var g := int(game[u2])
							if g >= (u - 1) * 256 and g < u * 256:
								its.append_array([u2, 7, g - (u - 1) * 256, 1])
						both("load_lane", [u * 8 + 1, t, its])
				if t == 10:
					var hx := taken_at if case == "front" else taken_at + 54
					both("take_at", [10, 3, 7, 1, hx, 2560, 99])
				var before: Array = gd.items_state() if t == read_at else []
				both("step_to", [t])
				var ch: Dictionary = gd.take_changes()
				var chn: Dictionary = nat.take_changes()
				for k in STATE_KEYS:
					if ch[k] != chn[k]:
						_fail("%s tick %d" % [where, t], "take_changes %s: %s against %s" % [k, str(ch[k]).left(200), str(chn[k]).left(200)])
						return
				if not compare("%s tick %d" % [where, t]):
					return
				var st: Array = gd.items_state()
				var places: Array = []
				for j in (st[0] as PackedInt64Array).size():
					places.append(int(st[2][j]) + ((int(st[1][j]) >> 3) - 1) * 256)
				places.sort()
				for j in places.size():
					if int(places[j]) < 0:
						past_end += 1
					if j > 0 and int(places[j]) - int(places[j - 1]) < 64:
						close += 1
				if t == read_at and case == "neighbour" and on:
					# (The read only tells items apart: no place changes but by the tick's own step, none here: all
					# stand.)
					var was: Array = []
					for j in (before[0] as PackedInt64Array).size():
						was.append(int(before[2][j]) + ((int(before[1][j]) >> 3) - 1) * 256)
					was.sort()
					if was != places:
						moved_at_read += 1
				if t >= 30:
					var want: Array = game.values()
					want.sort()
					if places != want:
						worst += 1
			known_n += int(gd.n_take_known)
			var left: PackedInt64Array = gd.items_state()[0]
			if on:
				if left.size() != 23 or past_end > 0 or close > 0 or worst > 0 or moved_at_read > 0:
					_fail(where, "%d items (the game 23), %d item-ticks past the line's end, %d closer than a gap, %d ticks off the game's places from tick 30, %d reads that moved an item" % [
						left.size(), past_end, close, worst, moved_at_read])
					return
				if case != "neighbour" and left.has(taken):
					_fail(where, "the taken item %d is still on the belts" % taken)
					return
				if case == "neighbour" and left.has(taken):
					_fail(where, "the read didn't put it right: the taken item %d is still on the belts" % taken)
					return
			elif case == "front" and left.size() == 23 and past_end == 0:
				_fail(where, "with take_line off the taken item should stay as before (%d items, %d past the end)" % [left.size(), past_end])
				return
	print("take at a line's end: %d checks, %d differences (take_line: %d takes by a queued read)" % [checked, fails, known_n])


## A take at a belt's front edge, made late (tools/belt_line_end.py seed 1, item 168): six yellow belts going
## west (lane key u * 8 + 1, belt u from x (u - 1) * 256), items 128 apart running to the line's end. The
## game's hand takes item 208 on tick 10 at belt 3's front edge (line position 512); the event and the reads of
## lanes 3 and 2 as of tick 13 (neither has it) come together on tick 15, when the simulation has run it 40 on,
## over the edge onto belt 2; "reads first": the reads on tick 13, the pick on 15 (lane 2's read has put the item
## back at its entry by then). Both twins alike every tick; with take_edge the take finds it (the item gone,
## every other where the game has one once all stand, from tick 120); off (the old way) the take finds nothing and lane 2's read
## puts it back at its entry: it stays.
func _take_at_front_edge() -> void:
	for variant in 4:
		var on := variant < 2
		var case := "together" if variant % 2 == 0 else "reads first"
		take_edge = on
		rescue_seen = on  # (the old way: rescue_seen, which lets the item go too, off with it)
		_fresh(BeltSim.EDGE_STOP)
		take_edge = true
		rescue_seen = true
		both("step_to", [0])
		for u in range(1, 7):
			var ex := Vector2i((u - 1) * 256, 2560)
			var en := Vector2i(u * 256, 2560)
			both("set_lane", [u * 8 + 1, BeltSim.STRAIGHT, 256, 8, ex, (ex + en) / 2, en, 0, 0])
		var game := {}  # uid -> place along the line (0 its end)
		for m in range(-4, 8):
			game[208 + m] = 592 + 128 * m
		for u in range(1, 7):
			both("load_lane", [u * 8 + 1, 0, _game_lane(game, u)])
		var where := "take at a belt's front edge (%s, take_edge %s)" % [case, on]
		var reads := {}  # lane key -> the game's items on it as of tick 13
		var worst := 0
		for t in range(1, 130):
			# (The game: each item 8 on a tick, never within a gap of the one in front, the first stopping at 0.)
			var order: Array = game.keys()
			order.sort_custom(func(a: int, b: int) -> bool: return int(game[a]) < int(game[b]))
			var prev := -64
			for u2: int in order:
				game[u2] = mini(int(game[u2]), maxi(int(game[u2]) - 8, prev + 64))
				prev = int(game[u2])
			if t == 10:
				if int(game[208]) != 512:
					_fail(where, "the set-up's item 208 is at %d on tick 10, not belt 3's front edge" % int(game[208]))
					return
				game.erase(208)
			if t == 13:
				for u in [3, 2]:
					reads[u * 8 + 1] = _game_lane(game, u)
				if case == "reads first":
					# (The reads in time, the hand's pick an update later.)
					for key in [25, 17]:
						both("load_lane", [key, 13, reads[key]])
			if t == 15:
				# The update with the hand's pick (stamped 10, at belt 3's front edge) and the reads as of 13.
				both("take_at", [10, 3, 7, 1, 512 + 8, 2560, 99])
				if case == "together":
					for key in [25, 17]:
						both("load_lane", [key, 13, reads[key]])
			both("step_to", [t])
			var ch: Dictionary = gd.take_changes()
			var chn: Dictionary = nat.take_changes()
			for k in STATE_KEYS:
				if ch[k] != chn[k]:
					_fail("%s tick %d" % [where, t], "take_changes %s: %s against %s" % [k, str(ch[k]).left(200), str(chn[k]).left(200)])
					return
			if not compare("%s tick %d" % [where, t]):
				return
			if t >= 120:
				var st: Array = gd.items_state()
				var places: Array = []
				for j in (st[0] as PackedInt64Array).size():
					places.append(int(st[2][j]) + ((int(st[1][j]) >> 3) - 1) * 256)
				places.sort()
				var want: Array = game.values()
				want.sort()
				if places != want:
					worst += 1
		var left: PackedInt64Array = gd.items_state()[0]
		if on:
			if left.has(208) or left.size() != game.size() or worst > 0:
				_fail(where, "%d items (the game %d), the taken item 208 %s, %d ticks off the game's places from tick 120 (all standing by then)" % [
					left.size(), game.size(), "still on the belts" if left.has(208) else "gone", worst])
				return
		elif not left.has(208):
			_fail(where, "with take_edge off the taken item 208 should stay as before")
			return
	print("take at a belt's front edge: %d checks, %d differences" % [checked, fails])


## --belt-sim-rescue-seen: an inserter past the bridge's hands radius takes an item with no `ie`, so the client
## learns of it only from reads. Six yellow belts that end (units 1-6, west), two items a few tiles apart; the
## game's hand takes the front one (50) over belt 4 on tick 10, and the bridge reads the pickup belt and its
## feeder (belt 5, item 51 on it) as the game has them, both without 50, in one update. The old way the read of
## belt 4 put 50 back onto belt 5 as one the game's had yet to reach, belt 5's read then pushed it ahead onto
## belt 4 again, and it ran on to the line's end for good. Cases: "pickup first", "feeder first" (the update's two
## reads either way round), "pickup only" (belt 4 alone read without it, every 8 ticks: rescued twice, then gone
## at the third). With rescue_seen the line ends as the game's (51 alone at the end); off, 50 stays. Both twins
## alike every tick.
func _rescue_seen_case() -> void:
	for variant in 6:
		var on := variant < 3
		var case: String = ["pickup first", "feeder first", "pickup only"][variant % 3]
		rescue_seen = on
		_fresh(BeltSim.EDGE_STOP)
		rescue_seen = true
		both("step_to", [0])
		for u in range(1, 7):
			var ex := Vector2i((u - 1) * 256, 2560)
			var en := Vector2i(u * 256, 2560)
			both("set_lane", [u * 8 + 1, BeltSim.STRAIGHT, 256, 8, ex, (ex + en) / 2, en, 0, 0])
		var game := {50: 1100, 51: 1300}  # uid -> place along the line (0 its end)
		for u in range(1, 7):
			both("load_lane", [u * 8 + 1, 0, _game_lane(game, u)])
		var where := "rescue seen (%s, rescue_seen %s)" % [case, on]
		for t in range(1, 260):
			var order: Array = game.keys()
			order.sort_custom(func(a: int, b: int) -> bool: return int(game[a]) < int(game[b]))
			var prev := -64
			for u2: int in order:
				game[u2] = mini(int(game[u2]), maxi(int(game[u2]) - 8, prev + 64))
				prev = int(game[u2])
			if t == 10:
				if int(game[50]) < 768 or int(game[50]) >= 1024:
					_fail(where, "the set-up's item 50 is at %d on tick 10, not on belt 4" % int(game[50]))
					return
				game.erase(50)
			if t == 13:
				# (The update as of tick 12: no `ie`, the hand past the bridge's radius.)
				var keys: Array = [33, 41] if case == "pickup first" else ([41, 33] if case == "feeder first" else [33])
				for key: int in keys:
					both("load_lane", [key, 12, _game_lane(game, (key - 1) / 8)])
			elif case == "pickup only" and t > 13 and t < 60 and (t - 13) % 8 == 0:
				both("load_lane", [33, t - 1, _game_lane(game, 4)])
			both("step_to", [t])
			var ch: Dictionary = gd.take_changes()
			var chn: Dictionary = nat.take_changes()
			for k in STATE_KEYS:
				if ch[k] != chn[k]:
					_fail("%s tick %d" % [where, t], "take_changes %s: %s against %s" % [k, str(ch[k]).left(200), str(chn[k]).left(200)])
					return
			if not compare("%s tick %d" % [where, t]):
				return
		var left: PackedInt64Array = gd.items_state()[0]
		if on:
			if left.has(50) or not left.has(51) or gd.n_rescue_denied < 1:
				_fail(where, "items left %s (the game: 51 alone), %d rescues denied" % [str(left), gd.n_rescue_denied])
				return
		elif not left.has(50):
			_fail(where, "with rescue_seen off the taken item 50 should stay as before")
			return
	print("rescue seen: %d checks, %d differences" % [checked, fails])


## An underground's tunnel the bridge sends no next for (`lm` next 0, s272_out's lane 35360348): its exit beside
## a straight belt running across it, 136/256 tile off. Both twins alike every tick; with ug_guard the tunnel
## leads nowhere, so its entrance ends at its own end: its items stand there, none in the tunnel or on the belt;
## off (the old way) they go through and side-load onto the belt.
func _ug_guard_case() -> void:
	for on in [true, false]:
		ug_guard = on
		_fresh(BeltSim.EDGE_STOP)
		ug_guard = true
		both("step_to", [0])
		both("set_lane", [17, BeltSim.UG_VISIBLE, 128, 8, Vector2i(512, 2560), Vector2i(576, 2560), Vector2i(640, 2560), 0, 19])
		both("set_lane", [19, BeltSim.UG_HIDDEN, 256, 8, Vector2i(256, 2560), Vector2i(384, 2560), Vector2i(511, 2560), 0, 0])
		both("set_lane", [41, BeltSim.STRAIGHT, 256, 8, Vector2i(120, 2432), Vector2i(120, 2560), Vector2i(120, 2688), 0, 0])
		both("load_lane", [17, 0, PackedInt64Array([300, 7, 40, 1, 301, 7, 104, 1])])
		var where := "underground tunnel with no next (ug_guard %s)" % on
		var on_belt := 0
		var in_tunnel := 0
		for t in range(1, 120):
			both("step_to", [t])
			var ch: Dictionary = gd.take_changes()
			var chn: Dictionary = nat.take_changes()
			for k in STATE_KEYS:
				if ch[k] != chn[k]:
					_fail("%s tick %d" % [where, t], "take_changes %s: %s against %s" % [k, str(ch[k]).left(200), str(chn[k]).left(200)])
					return
			if not compare("%s tick %d" % [where, t]):
				return
			var st: Array = gd.items_state()
			for j in (st[0] as PackedInt64Array).size():
				if int(st[1][j]) == 41:
					on_belt += 1
				elif int(st[1][j]) == 19:
					in_tunnel += 1
		if on and on_belt + in_tunnel > 0:
			_fail(where, "%d item-ticks on the belt beside the tunnel's exit, %d in the tunnel" % [on_belt, in_tunnel])
			return
		if not on and on_belt == 0:
			_fail(where, "with ug_guard off the items should side-load onto the belt as before")
			return
	print("underground tunnel with no next: %d checks, %d differences" % [checked, fails])


## (ug_guard) A tunnel whose exit the bridge names (`lm` next 33) leads on whether its exit is loaded or not, its
## items going into the tunnel as the game's do: "exit later" (the exit's lane loads on tick 30; after it the items
## come out into it), "exit outside" (the tunnel leads out of what is sent: minus the exit's key, out edge on; the
## exit never loads), "exit not loaded" (named, never loaded, no out edge) and "next unknown" (next 0 with next_named
## off, as tests/belt_sim_replay.gd's recordings: no dead end). Both twins alike every tick. Before,
## an exit not in what was loaded made the entrance a dead end, its items standing at it while the game sent them
## through (tests/belt_sim_replay.gd's fixture: 0.879% off; live, an exit outside the square).
func _ug_exit_later() -> void:
	for variant in ["exit later", "exit outside", "exit not loaded", "next unknown"]:
		_fresh(BeltSim.EDGE_STOP)
		if variant == "next unknown":
			# (A recording's lanes, next_named off: next 0 says nothing, no dead end.)
			gd.next_named = false
			nat.next_named = false
		both("step_to", [0])
		both("set_lane", [17, BeltSim.UG_VISIBLE, 128, 8, Vector2i(512, 2560), Vector2i(576, 2560), Vector2i(640, 2560), 0, 19])
		both("set_lane", [19, BeltSim.UG_HIDDEN, 256, 8, Vector2i(256, 2560), Vector2i(384, 2560), Vector2i(511, 2560), 0, 0 if variant == "next unknown" else 33])
		if variant == "exit outside":
			both("set_out_edge", [19, true])
		both("load_lane", [17, 0, PackedInt64Array([300, 7, 40, 1, 301, 7, 104, 1])])
		var where := "underground's named exit (%s)" % variant
		var in_tunnel := 0
		var after := 0
		var linked := false
		for t in range(1, 160):
			if t == 30 and variant == "exit later":
				both("set_lane", [33, BeltSim.UG_VISIBLE, 128, 8, Vector2i(128, 2560), Vector2i(192, 2560), Vector2i(255, 2560), 0, 0])
			both("step_to", [t])
			var ch: Dictionary = gd.take_changes()
			var chn: Dictionary = nat.take_changes()
			for k in STATE_KEYS:
				if ch[k] != chn[k]:
					_fail("%s tick %d" % [where, t], "take_changes %s: %s against %s" % [k, str(ch[k]).left(200), str(chn[k]).left(200)])
					return
			if not compare("%s tick %d" % [where, t]):
				return
			if t == 5:
				linked = gd.next_of(17) == 19 and nat.next_of(17) == 19
			var st: Array = gd.items_state()
			for j in (st[0] as PackedInt64Array).size():
				var key := int(st[1][j])
				if key == 19:
					in_tunnel += 1
				elif key == 33:
					after += 1
		# (A tunnel leading out of the square takes items as the bridge's reads of it say, its wall: none here, so the
		# entrance's link into it is what is checked, not the dead end's held items.)
		if not linked or (variant != "exit outside" and in_tunnel == 0) or (variant == "exit later") != (after > 0):
			_fail(where, "entrance led into its tunnel %s, %d item-ticks in the tunnel (want some), %d in the exit (want some only once it loads)" % [linked, in_tunnel, after])
			return
	print("underground's named exit: %d checks, %d differences" % [checked, fails])


## (_take_at_front_edge) The game's items on belt u's lane, front first: [uid, 7, place on the lane, 1] each.
func _game_lane(game: Dictionary, u: int) -> PackedInt64Array:
	var its := PackedInt64Array()
	var order: Array = game.keys()
	order.sort_custom(func(a: int, b: int) -> bool: return int(game[a]) < int(game[b]))
	for u2: int in order:
		var g := int(game[u2])
		if g >= (u - 1) * 256 and g < u * 256:
			its.append_array([u2, 7, g - (u - 1) * 256, 1])
	return its

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
