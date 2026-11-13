extends SceneTree
## What belt_items.gd's job costs on a captured `bs` stream (belt_items.gd --belt-capture), offline and
## the same every run: each part of a job (decoding, the simulation's relinking, loads and checks and
## stepping, making records, writing them), line steps a tick and why lines are stepped every tick.
##
##   godot --headless --path client -s res://tests/belt_bs_perf.gd -- --stream=bs.jsonl [--bundle=N]
##       [--from=<update>] [--updates=N] [--gd]
##
## --bundle: updates a job takes at once (live, a slow job's next one holds every update that came
## meanwhile); the simulation is stepped to the last one's tick, as belt_items.gd does. --gd: belt_sim.gd
## even when the C++ twin (BeltSimNative) is loaded; the last line's hash of every item's place is the
## same for both.

const BeltItems := preload("res://scripts/world/belt_items.gd")


func _initialize() -> void:
	var stream := ""
	var bundle := 1
	var from := 0
	var count := 1 << 30
	var use_gd := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--stream="):
			stream = a.substr(9)
		elif a.begins_with("--bundle="):
			bundle = int(a.substr(9))
		elif a.begins_with("--from="):
			from = int(a.substr(7))
		elif a.begins_with("--updates="):
			count = int(a.substr(10))
		elif a == "--gd":
			use_gd = true
	BeltItems.read_flags(OS.get_cmdline_user_args())  # (the drawing's toggles, --belt-draw-lattice-native=off and the rest)
	var updates: Array = []
	var looks := {}  # item id -> a stand-in look (lift, turns, pile), so records are written as live
	var cur: Array = []
	var cur_k := -1
	var f := FileAccess.open(stream, FileAccess.READ)
	while not f.eof_reached():
		var line := f.get_line()
		if line.is_empty():
			continue
		var msg = JSON.parse_string(line)
		if not (msg is Dictionary) or msg.get("t") != "bs":
			continue
		var k := int(msg.get("k", 0))
		var sl = msg.get("sl")
		if sl is Array:
			var a2: Array = sl
			var q := 0
			while q + 2 < a2.size():
				var n := int(a2[q + 2])
				for e in n:
					looks[int(a2[q + 3 + e * 4 + 1])] = [Vector3(0.0, 0.1, 0.0), true, 0.07]
				q += 3 + n * 4
		if k != cur_k and not cur.is_empty():
			updates.append(cur)
			cur = []
		cur_k = k
		cur.append(msg)
	if not cur.is_empty():
		updates.append(cur)
	var state := BeltItems.State.new()
	if use_gd and state.sim.get_class() == "BeltSimNative":
		var gd_sim: RefCounted = BeltItems.BeltSim.new()
		gd_sim.edge_mode = state.sim.edge_mode
		gd_sim.ask_on_link = state.sim.ask_on_link
		state.sim = gd_sim
	var sim = state.sim
	print("simulation: ", "BeltSimNative (C++)" if sim.get_class() == "BeltSimNative" else "belt_sim.gd")
	if "profile" in sim:
		sim.profile = true  # (the C++ twin: the queue's loads and checks timed and counted, stats())
	var parts := {"job": 0, "handle": 0, "sim": 0, "apply": 0, "renew": 0, "cap": 0, "write": 0, "lat": 0}
	var jobs := 0
	var measured_jobs := 0
	var worst := 0
	var ticks := 0
	var steps0 := 0
	var why0 := PackedInt64Array()
	var us0 := [0, 0, 0]
	var changes := 0
	var records := 0
	var asked := 0
	var first_tick := -1
	var i := 0
	var last := mini(updates.size(), from + count)
	while i < last:
		var msgs: Array = []
		var j := i
		while j < mini(i + bundle, updates.size()):
			msgs.append_array(updates[j])
			j += 1
		var k := int(msgs[msgs.size() - 1].get("k", 0))
		var job := BeltItems.Job.new()
		job.state = state
		job.msgs = msgs
		job.fold_tick = float(k)
		job.now_msec = k * 16
		job.known = looks
		var t_before := int(sim.tick)
		if i >= from and steps0 == 0 and jobs > 0:
			steps0 = sim.n_line_steps
			why0 = sim.why_tick.duplicate()
			us0 = [sim.us_relink, sim.us_queue, sim.us_step]
			first_tick = t_before
		var c0 := Time.get_ticks_usec()
		job.run()
		var took := Time.get_ticks_usec() - c0
		jobs += 1
		if i >= from and jobs > 1:
			measured_jobs += 1
			parts["job"] += took
			parts["handle"] += job.handle_usec
			parts["sim"] += job.sim_usec
			parts["apply"] += job.apply_usec
			parts["renew"] += job.renew_usec
			parts["cap"] += job.cap_usec
			parts["write"] += job.write_usec
			parts["lat"] += job.lat_usec
			worst = maxi(worst, took)
			ticks = int(sim.tick) - first_tick
			changes += job.changes
			records += job.records_written
			asked += job.resend.size()
		i = j
	var nj := maxf(1.0, measured_jobs)
	var nt := maxf(1.0, ticks)
	var st: Dictionary = sim.stats()
	print("updates %d, jobs %d (%d measured, %d updates each), ticks %d; items %d, lanes %d, lines %d (asleep %d, flowing %d)" % [
		updates.size(), jobs, measured_jobs, bundle, ticks, st["items"], st["lanes"], st["lines"], st["asleep"], st["flowing"]])
	var line := "a job: %.1f ms on average, worst %.1f ms;" % [parts["job"] / nj / 1000.0, worst / 1000.0]
	for p in ["handle", "sim", "apply", "renew", "cap", "write", "lat"]:
		line += " %s %.2f" % [p, parts[p] / nj / 1000.0]
	print(line + " (ms)")
	print("drawing: %s; lattice lanes %d, slots %d" % [BeltItems.flags_text(), state.lattice.lanes_n, state.lattice.slots_n])
	print("the simulation a tick: %.3f ms (relink %.3f, loads and checks %.3f, stepping %.3f); line steps %.1f a tick" % [
		parts["sim"] / nt / 1000.0, (sim.us_relink - us0[0]) / nt / 1000.0, (sim.us_queue - us0[1]) / nt / 1000.0,
		(sim.us_step - us0[2]) / nt / 1000.0, (sim.n_line_steps - steps0) / nt])
	var why: Array = []
	for w in sim.why_tick.size():
		why.append(snappedf((sim.why_tick[w] - (why0[w] if why0.size() > w else 0)) / nt, 0.1))
	print("lines stepped next tick, a tick, by why [-, side/split waiting, -, following slower, arrived, front crossing, other, held near a standing item, gap closing]: %s" % [why])
	print("changes %.1f a tick, records %.1f a tick, lanes asked again %d" % [changes / nt, records / nt, asked])
	if st.has("q_us_load"):
		print("the queue, whole run: loads %.2f ms a tick (%d loads, %d found the lane exactly as read, %.0f line items walked a load), checks %.2f ms a tick, other %.2f; stepping edge lines %.2f ms a tick, other lines %.2f" % [
			st["q_us_load"] / 1000.0 / nt, st["q_loads"], st["q_loads_same"], float(st["q_load_n"]) / maxi(1, st["q_loads"]),
			st["q_us_check"] / 1000.0 / nt, st["q_us_other"] / 1000.0 / nt, st["step_us_edge"] / 1000.0 / nt, st["step_us_other"] / 1000.0 / nt])
		var lp: Array = st["load_us"]
		print("a load by part, us [positions and index, shift and push back, rescue and keep, uid->line map, the read's items, space out, rebuild, carries and holds]: %s" % [
			lp.map(func(v): return snappedf(float(v) / maxi(1, st["q_loads"]), 0.1))])
	print("lanes marked for relinking, by what: %s; relinks with changed meta: see set_lane" % [sim.why_mark])
	print("items now: %d, their places' hash %d" % [(sim.items_state()[0] as PackedInt64Array).size(), hash(sim.items_state())])
	quit(0)
