extends SceneTree
## Replays a recording of the game's belts (tools/belt_sim/record.py) through belt_sim.gd, as
## tools/belt_sim/sim.py's free mode does: the lanes and the first tick's items, then each tick the
## simulation steps on by itself, given only what the game put on and took off (items it has that
## the simulation doesn't, and back), and every item is compared with where the game has it.
##
##   godot --headless --path client -s res://tests/belt_sim_replay.gd -- [rec.json] [--ticks=N] [--bench]
##       [--gd | --native] [--split-wake=off] [--game-crossings=N] [--game-inputs]
##
## Exits 1 when an item is anywhere else than where the game has it on the default fixture
## (tests/data/belt_sim_small.json: Zenith Test -272,-23 to -266,-18, 300 ticks: straight belts,
## curves, undergrounds, a side-load and two splitters, where sim.py is right every tick). --bench
## also collects the changes and times the steps; --tile=N runs N copies side by side. The C++ twin
## (BeltSimNative) is used when its extension is loaded, as belt_items.gd does; --gd runs belt_sim.gd,
## --native fails when the extension isn't there. --game-crossings=N (the cross round): every N ticks
## each splitter's output lanes are read from the recording and given to the simulation as the bridge's
## `sl` would be (load_lane at that tick), --game-inputs its inputs too; the summary then also says how
## many items were within 0.15 tile on the game's lane and how many of the game's items on packed
## straight lanes had no simulated item near them (holes).

const BeltSim := preload("res://scripts/world/belt_sim.gd")
const DEFAULT := "res://tests/data/belt_sim_small.json"
const KEY_OFF := 8 * 100000000
const UID_OFF := 1 << 34

const KIND_NAMES := {1: "straight", 2: "curve", 3: "underground-belt", 4: "underground hidden",
	5: "splitter", 6: "splitter", 7: "loader", 8: "other"}


static func kind_of(m: Array) -> int:
	var t := str(m[2])
	var line := int(m[5])
	match t:
		"transport-belt":
			return 2 if str(m[3]) == "left" or str(m[3]) == "right" else 1
		"underground-belt":
			return 3 if line <= 2 else 4
		"splitter":
			return 5 if line <= 4 else 6
		"lane-splitter":
			return 5 if line <= 2 else 6
		"loader", "loader-1x1":
			return 7
	return 8


static func prio(v: Variant) -> int:
	match str(v):
		"left":
			return 1
		"right":
			return 2
	return 0


## belt_sim.gd ("gd"), its C++ twin ("native", null when its extension isn't loaded), or the one
## belt_items.gd would use ("").
static func make_sim(which: String) -> RefCounted:
	var has_native := ClassDB.class_exists("BeltSimNative")
	if which == "native" and not has_native:
		printerr("BeltSimNative isn't loaded (client/native/bin: docs/RUNNING.md)")
		return null
	var sim: RefCounted = ClassDB.instantiate("BeltSimNative") if has_native and which != "gd" else BeltSim.new()
	print("simulation: ", "BeltSimNative (C++)" if sim.get_class() == "BeltSimNative" else "belt_sim.gd")
	return sim


func _initialize() -> void:
	var path := DEFAULT
	var max_ticks := 1 << 30
	var bench := false
	var tile := 1
	var runoff := false
	var split_wake := true  # --split-wake=off: splitters as before (BeltSim.split_wake)
	var game_x := 0  # --game-crossings=N
	var game_in := false  # --game-inputs
	var dump: FileAccess = null
	var which := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--ticks="):
			max_ticks = int(a.substr(8))
		elif a.begins_with("--tile="):
			tile = int(a.substr(7))
		elif a == "--stop":
			runoff = true
		elif a == "--bench":
			bench = true
		elif a == "--gd" or a == "--native":
			which = a.substr(2)
		elif a == "--split-wake=off":
			split_wake = false
		elif a.begins_with("--game-crossings="):
			game_x = int(a.substr(17))
		elif a == "--game-inputs":
			game_in = true
		elif a.begins_with("--dump="):
			dump = FileAccess.open(a.substr(7), FileAccess.WRITE)
		elif not a.begins_with("--"):
			path = a
	var t0 := Time.get_ticks_msec()
	var text := FileAccess.get_file_as_string(path)
	print("read %d MB in %d ms" % [text.length() >> 20, Time.get_ticks_msec() - t0])
	if text.is_empty():
		printerr("can't read ", path)
		quit(2)
		return
	var d: Dictionary = JSON.parse_string(text)
	text = ""
	var metas: Array = d["lanes"]
	var names: Array = d.get("names", [])
	var ticks: Array = d["ticks"]
	print("loaded %s: %d lanes, %d ticks in %d ms" % [path, metas.size(), ticks.size(), Time.get_ticks_msec() - t0])
	var sim = make_sim(which)
	if sim == null:
		quit(2)
		return
	sim.edge_mode = BeltSim.EDGE_STOP if runoff else BeltSim.EDGE_ORACLE
	sim.split_wake = split_wake
	sim.emit_changes = bench
	sim.profile = bench
	var keys := PackedInt64Array()
	var kinds := PackedInt32Array()
	keys.resize(metas.size() + 1)
	kinds.resize(metas.size() + 1)
	for j in metas.size():
		var m: Array = metas[j]
		var key := int(m[0]) * 8 + int(m[5])
		var kind := kind_of(m)
		keys[j + 1] = key
		kinds[j + 1] = kind
		var extra := 0
		if m.size() > 12 and m[12] is Array and (m[12] as Array).size() >= 2:
			extra = prio(m[12][0]) + 3 * prio(m[12][1])
			if (m[12] as Array).size() >= 3 and str(m[12][2]) != "":
				extra += 9 * (names.find(str(m[12][2])) + 1)
		# An underground entrance's visible half goes on into its own hidden line (the bridge's `next`).
		var next_key := 0
		if str(m[2]) == "underground-belt" and str(m[3]) == "input" and int(m[5]) <= 2:
			next_key = key + 2
		var e: Array = m[7]
		var mid: Array = m[8]
		var en: Array = m[9]
		# (--tile: copies of the recording side by side, far apart, keys and uids their own.)
		for c in tile:
			var sh := Vector2i(0, c * 256 * 1000)
			sim.set_lane(key + c * KEY_OFF, kind, int(m[6]), int(m[10]), Vector2i(int(e[0]), int(e[1])) + sh,
				Vector2i(int(mid[0]), int(mid[1])) + sh, Vector2i(int(en[0]), int(en[1])) + sh, extra,
				next_key + c * KEY_OFF if next_key != 0 else 0)
	var n_ticks := mini(ticks.size(), max_ticks)
	# Packed straight lanes (the bus): those the game keeps at 3 or more items of 4 over the run.
	var full := {}
	for t in n_ticks:
		var row0: Array = ticks[t]
		for i in range(1, row0.size(), 5):
			full[int(row0[i])] = int(full.get(int(row0[i]), 0)) + 1
	var bus := {}
	for j in full:
		var m: Array = metas[j - 1]
		if kinds[j] == 1 and int(m[6]) == 256 and int(full[j]) >= n_ticks * 3:
			bus[keys[j]] = true
	print("packed straight lanes: %d" % bus.size())
	var first: Array = ticks[0]
	sim.step_to(int(first[0]))
	for c in tile:
		for i in range(1, first.size(), 5):
			sim.put_item(keys[int(first[i])] + c * KEY_OFF, int(first[i + 1]) + c * UID_OFF, int(first[i + 4]),
				int(first[i + 3]), int(first[i + 2]))
	sim.mark_split_holds()
	print("set up in %d ms: %s" % [Time.get_ticks_msec() - t0, sim.stats()])
	var right := 0
	var wrong := 0
	var put := 0
	var took := 0
	var by_kind := {}
	var tot_kind := {}
	var step_us := 0
	var worst_us := 0
	var shown := 0
	var changes := 0
	var near_ok := 0
	var bus_ticks := 0
	var bus_holes := 0
	var bus_sim := 0
	var lost := 0
	var prev_game := {}
	for t in range(n_ticks - 1):
		var row: Array = ticks[t + 1]
		var game := {}  # uid -> [key, pos, kind, item, stack]
		for c in tile:
			for i in range(1, row.size(), 5):
				game[int(row[i + 1]) + c * UID_OFF] = [keys[int(row[i])] + c * KEY_OFF, int(row[i + 2]),
					kinds[int(row[i])], int(row[i + 4]), int(row[i + 3])]
		sim.oracle = game
		if OS.get_environment("BS_WATCH") != "" and int(row[0]) >= int(OS.get_environment("BS_T0")):
			print(int(row[0]) - 1, " ", sim.debug_item(int(OS.get_environment("BS_WATCH"))))
		if game_x > 0 and (t + 1) % game_x == 0:
			# The splitters' output (and input) lanes as the game has them at this tick, as `sl` reads.
			var reads := {}
			for c in tile:
				for i in range(1, row.size(), 5):
					var k: int = kinds[int(row[i])]
					if k == 6 or (game_in and k == 5):
						var key := keys[int(row[i])] + c * KEY_OFF
						if not reads.has(key):
							reads[key] = PackedInt64Array()
						var arr: PackedInt64Array = reads[key]
						arr.append(int(row[i + 1]) + c * UID_OFF)
						arr.append(int(row[i + 4]))
						arr.append(int(row[i + 2]))
						arr.append(int(row[i + 3]))
						reads[key] = arr
			for j in range(1, metas.size() + 1):
				if kinds[j] == 6 or (game_in and kinds[j] == 5):
					for c in tile:
						var key := keys[j] + c * KEY_OFF
						var arr: PackedInt64Array = reads.get(key, PackedInt64Array())
						# (Items front first, as the bridge lists them.)
						var order: Array = []
						for q in arr.size() / 4:
							order.append([arr[q * 4 + 2], q])
						order.sort()
						var sorted := PackedInt64Array()
						for e in order:
							var q: int = e[1]
							sorted.append_array(arr.slice(q * 4, q * 4 + 4))
						sim.load_lane(key, int(row[0]), sorted)
		var c0 := Time.get_ticks_usec()
		sim.step_to(int(row[0]))
		var c1 := Time.get_ticks_usec() - c0
		step_us += c1
		worst_us = maxi(worst_us, c1)
		if bench:
			var ch: Dictionary = sim.take_changes()
			changes += (ch["uid"] as PackedInt64Array).size()
		var st: Array = sim.items_state()
		var su: PackedInt64Array = st[0]
		var sk: PackedInt64Array = st[1]
		var sp: PackedInt32Array = st[2]
		var where := {}
		for i in su.size():
			where[su[i]] = i
		if dump != null:
			var lines := PackedStringArray()
			for i in su.size():
				lines.append("%d %d %d" % [su[i], sk[i], sp[i]])
			lines.sort()
			dump.store_line("T %d" % int(row[0]))
			dump.store_line("\n".join(lines))
		var sim_on := {}  # packed lane key -> PackedInt32Array of simulated positions
		for i in su.size():
			if bus.has(sk[i]):
				if not sim_on.has(sk[i]):
					sim_on[sk[i]] = PackedInt32Array()
				var pa: PackedInt32Array = sim_on[sk[i]]
				pa.append(sp[i])
				sim_on[sk[i]] = pa
				bus_sim += 1
		for u in game:
			var g0: Array = game[u]
			if bus.has(int(g0[0])):
				bus_ticks += 1
				var hole := true
				if sim_on.has(int(g0[0])):
					for q in (sim_on[int(g0[0])] as PackedInt32Array):
						if absi(q - int(g0[1])) <= 38:
							hole = false
							break
				if hole:
					bus_holes += 1
			if not where.has(u) or sim.given.has(u):
				continue
			var g: Array = game[u]
			var kn: String = KIND_NAMES.get(int(g[2]), "other")
			tot_kind[kn] = int(tot_kind.get(kn, 0)) + 1
			var i: int = where[u]
			if sk[i] == int(g[0]) and absi(sp[i] - int(g[1])) <= 38:
				near_ok += 1
			if sk[i] == int(g[0]) and sp[i] == int(g[1]):
				right += 1
			else:
				wrong += 1
				by_kind[kn] = int(by_kind.get(kn, 0)) + 1
				if shown < 8:
					shown += 1
					print("  tick %d item %d: game on lane %d at %d; simulated on lane %d at %d" % [
						int(row[0]), u, int(g[0]), int(g[1]), sk[i], sp[i]])
		# What the game put on and took off.
		for i in su.size():
			if not game.has(su[i]):
				sim.take_item(su[i], false)
				took += 1
		for u in game:
			if not where.has(u):
				var g2: Array = game[u]
				sim.put_item(int(g2[0]), u, int(g2[3]), int(g2[4]), int(g2[1]))
				put += 1
				if prev_game.has(u):
					lost += 1  # (the game had it last tick too: the simulation had lost it)
		prev_game = game
	print("mode free: %d item-ticks where the game has them, %d not (%.3f%%); put on %d, taken off %d" % [
		right, wrong, 100.0 * wrong / maxf(1.0, right + wrong), put, took])
	print("  within 38 on the game's lane: %.3f%%; items the simulation lost (put back by the game): %d; packed lanes: %d game item-ticks, %d with no simulated item within 38 (%.3f%%), simulated items %.2f%% of the game's" % [
		100.0 * near_ok / maxf(1.0, right + wrong), lost, bus_ticks, bus_holes, 100.0 * bus_holes / maxf(1.0, bus_ticks),
		100.0 * bus_sim / maxf(1.0, bus_ticks)])
	if game_x > 0:
		print("  crossings from the game every %d ticks%s" % [game_x, " + inputs" if game_in else ""])
	for kn in tot_kind:
		print("  %-20s %8d item-ticks, %6.3f%% not where the game has them" % [kn, tot_kind[kn],
			100.0 * int(by_kind.get(kn, 0)) / float(tot_kind[kn])])
	var nt := maxf(1.0, n_ticks - 1)
	print("steps: %.1f us a tick on average, worst %d us; %.1f line steps a tick; %s; changes %.1f a tick; prof %s" % [
		float(step_us) / nt, worst_us, float(sim.n_line_steps) / nt, sim.stats(), changes / nt, sim.prof])
	if bench:
		print("line steps: %.1f us a tick in lines leading out of the square (the replay's oracle), %.1f us in the rest" % [
			sim.step_us[0] / nt, sim.step_us[1] / nt])
	quit(1 if wrong > 0 and path == DEFAULT else 0)
