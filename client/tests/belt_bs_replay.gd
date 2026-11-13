extends SceneTree
## Replays a captured `bs` stream (tools/belt_bench.py --bs --capture) through belt_items.gd's own
## job (its simulation and records) and compares the simulated items with a recording of the game
## made over the same ticks (tools/belt_sim/record.py): each update's tick, every game item on a lane
## the simulation has loaded, by unique id (on its lane at its position, off by how much, missing),
## and the simulation's items the game doesn't have.
##
##   godot --headless --path client -s res://tests/belt_bs_replay.gd -- --stream=bs.jsonl --truth=rec.json
##       [--explain=N] [--dump=out.json --dump-at=TICK] [--gd]
## --gd runs belt_sim.gd even when BeltSimNative is loaded. --replay-bre answers the job's own `bre`
## from the recording two updates on (off by default: a live capture holds the bridge's answers already). The drawing's toggles (--belt-sim-ahead=N,
## --belt-draw-gone-order=off, --belt-draw-lead=off, --belt-draw-head-move=off) as the client reads them. --drawn-check: by place, the simulation and
## what its items' records draw against the game.
## --cap=N: Items in 3D's cap at N (every kind taken for a model), as Settings > Items in 3D; with
## --cam=x,z the camera leads it (view_priority.gd: an add-on's camera, first person, the remote view):
## a camera 12 tiles above (x, z + 10) looking north and down, drifting 0.1 tile east a job, so the cap
## is worked out again as it moves (tools/belt_draw_diff.py checks both records paths agree).
## --dump writes, for the first compared update at or after TICK, every game item on a simulated lane
## and every simulated item as {"game": {uid: [lane, pos]}, "sim": {uid: [lane, pos]}}.
## --view-dump=<out.jsonl> (tools/belt_view_check.py): a line per compared update (every
## --view-every=N'th, default 1, and always the first and last) with every game item in the recording,
## simulated lane or not ([lane, pos, the recording's item index]), every simulated item ([lane, pos,
## the item id its `sl` gave: the bridge's, or minus the recording's index for a `bre` answered here])
## and the simulated lanes; then a last line with the --drawn-check totals.

const BeltItems := preload("res://scripts/world/belt_items.gd")
const ViewPriority := preload("res://scripts/world/view_priority.gd")
const BeltRecords := preload("res://scripts/world/belt_records.gd")
const BeltSim := preload("res://scripts/world/belt_sim.gd")


## (--drawn-check) The job, keeping each item's last change as the simulation gave it (uid -> [lane,
## pos, tick, speed, reach, run]): what the records should say.
class DiagJob extends BeltItems.Job:
	var last: Dictionary
	static var trace := 0  # --trace=UID: its changes, and each tick where it is and is drawn

	func _apply_changes(ch: Dictionary) -> void:
		var uids: PackedInt64Array = ch["uid"]
		var keys: PackedInt64Array = ch["key"]
		var poss: PackedInt32Array = ch["pos"]
		var ticks: PackedInt64Array = ch["tick"]
		var speeds: PackedInt32Array = ch["speed"]
		var reaches: PackedInt32Array = ch["reach"]
		var runs: PackedInt32Array = ch["run"]
		# (What the job applies now, as it does: what happened after the drawn tick waits for the next
		# job, State.later, with what happens to that item after it.)
		var now := floori(fold_tick)
		var held := {}
		for e: Array in state.later:
			if int(e[2]) > now or held.has(e[1]):
				held[e[1]] = true
			elif int(e[0]) == 0:
				last[e[1]] = [e[5], e[6], e[2], e[7], e[8], e[9]]
			else:
				last.erase(e[1])
		var gone: PackedInt64Array = ch["gone"]
		var gone_ticks: PackedInt64Array = ch.get("gone_tick", PackedInt64Array())
		var gone_at: PackedInt32Array = ch.get("gone_at", PackedInt32Array())
		var timed := gone_ticks.size() == gone.size() and gone_at.size() == gone.size()
		var gi := 0
		for i in uids.size() + 1:
			while gi < gone.size() and (i == uids.size() or timed and gone_at[gi] <= i):
				if timed and gone_ticks[gi] > now or held.has(gone[gi]):
					held[gone[gi]] = true
				else:
					last.erase(gone[gi])
				gi += 1
			if i == uids.size():
				break
			if ticks[i] > now or held.has(uids[i]):
				held[uids[i]] = true
				continue
			last[uids[i]] = [keys[i], poss[i], ticks[i], speeds[i], reaches[i], runs[i]]
			if uids[i] == trace:
				print("  trace %d: job at %.1f (sim %d): change %s" % [trace, fold_tick, int(state.sim.tick), last[uids[i]]])
		if trace != 0 and (ch["gone"] as PackedInt64Array).has(trace):
			print("  trace %d: job at %.1f: gone" % [trace, fold_tick])
		if trace != 0 and state.sim is BeltSim:
			var id: int = state.sim._uid_line.get(trace, -1)
			if id >= 0:
				var L = state.sim._lines[id]
				var j: int = L.uid.find(trace)
				print("  trace %d: job at %.1f sim %d: line %d lanes %s mode %d due %d ft %d, item %d of %d rv %d" % [trace, fold_tick,
					int(state.sim.tick), id, (state.sim.debug_item(trace) as Dictionary).get("lanes"), L.mode, L.due, L.ft, j, L.uid.size(),
					L.rv[state.sim._rec_index(L, j)] if j >= 0 else -99])
		super(ch)


## (--drawn-check) Each simulated item's last change (DiagJob.last), how many of each class of item-tick
## (_drawn_precise), and examples of each (--drawn-explain=N a class).
var _dx_last := {}
var _dx := {}
var _dx_ex := {}
var _dx_max := 0
var _dx_ex_at := {}
const DX_EVERY := 37
## Off by more than this (tiles) counts: float noise is far below it.
const DX_TOL := 0.02


func _initialize() -> void:
	var stream := ""
	var truth := ""
	var explain := 0
	var explain_from := 0
	var dump := ""
	var dump_at := 0
	var follow_key := 0  # --follow=KEY@TICK: the lanes from KEY on along the simulation's links, game and simulation
	var follow_at := 0
	var dump_all := false  # --dump-all: every compared update from --dump-at on, each to <dump>.<tick>
	var drawn_check := false  # --drawn-check: by place, the simulation's items and what their records draw
	# Game items counted, none simulated within 0.15 tile, none drawn within 0.15 tile; by id: simulated
	# within 0.15 tile of the game's place, elsewhere, not simulated; drawn within 0.15, elsewhere, not drawn.
	var dc := [0, 0, 0, 0, 0, 0, 0, 0, 0]
	var dk := {}  # (--drawn-check) items drawn more than 0.15 tile from their simulated place, by why
	var view_dump := ""
	var view_every := 1
	# --every-tick[=LAG]: a job every tick, as the client's (a job a frame), the drawn clock LAG ticks
	# behind the updates (each update's messages go to the job at its tick - LAG); every recorded tick
	# compared. Without it a job per update, at its tick.
	var every_tick := false
	var lag := -1
	# --oracle-at=TICK: at the first recorded tick at or after it, every recorded lane is read (its items as
	# the recording has them, as `sl`), so the simulation starts from the game's state there. --reads-after=
	# none: after that tick no lane reads (`sl`, nor answers to `bre`) are applied: the simulation alone.
	# --persist: (with --oracle-at) per update, the items the game had at that tick still on recorded lanes:
	# exact, on their lane within 0.15 tile, on another lane, missing.
	var oracle_at := -1
	var reads_after := "all"
	var persist := false
	var read_probe := false  # --read-probe (belt_sim.gd): each read against the simulation just before it, by distance
	# --confirm-emu=split|all: what the bridge's confirmations would do (`ok`): at each update, every recorded
	# lane of that kind (split: splitters' lanes) whose game state then (count, front, back) is what its last
	# read said is read again at the update's tick with that read's items.
	var confirm_emu := ""
	# --hold-emu: what the bridge's splitter-input holds would do (`sh`, belt_sim.gd): at each recorded update,
	# every recorded splitter input whose items (ids and places) are as at the update before is held from
	# that update's tick to this one's.
	var hold_emu := false
	# --replay-bre: answer the client's own `bre` from the recording two updates on, as before this round.
	# Off by default: a live capture already holds the bridge's answers to the live client's asks, so
	# answering again from the recording read lanes the live client never got.
	var replay_bre := false
	# --sim-dump=<file> (scratchpad attribution): a line per compared tick, "tick uid,key,pos ..." of every
	# simulated item. --drop-dump=<file>: belt_sim.gd's drop_log ("tick uid key why" a line: each item a read
	# took off), forcing belt_sim.gd and --read-probe.
	var sim_dump: FileAccess = null
	var drop_dump := ""
	var cap := -1
	var cam: Camera3D = null
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--stream="):
			stream = a.substr(9)
		elif a.begins_with("--truth="):
			truth = a.substr(8)
		elif a.begins_with("--explain="):
			explain = int(a.substr(10))
		elif a.begins_with("--explain-from="):
			explain_from = int(a.substr(15))
		elif a.begins_with("--dump="):
			dump = a.substr(7)
		elif a.begins_with("--dump-at="):
			dump_at = int(a.substr(10))
		elif a.begins_with("--dump-all"):
			dump_all = true
		elif a.begins_with("--follow="):
			var fa := a.substr(9).split("@")
			follow_key = int(fa[0])
			follow_at = int(fa[1]) if fa.size() > 1 else 0
		elif a == "--gd":
			BeltItems.State.force_gd = true
		elif a == "--drawn-check":
			drawn_check = true
		elif a.begins_with("--view-dump="):
			view_dump = a.substr(12)
		elif a.begins_with("--view-every="):
			view_every = maxi(1, int(a.substr(13)))
		elif a.begins_with("--sim-dump="):
			sim_dump = FileAccess.open(a.substr(11), FileAccess.WRITE)
		elif a.begins_with("--drop-dump="):
			drop_dump = a.substr(12)
			read_probe = true
			BeltItems.State.force_gd = true
		elif a.begins_with("--trace="):
			DiagJob.trace = int(a.substr(8))
			drawn_check = true
		elif a.begins_with("--drawn-explain="):
			drawn_check = true
			_dx_max = int(a.substr(16))
		elif a.begins_with("--oracle-at="):
			oracle_at = int(a.substr(12))
		elif a.begins_with("--reads-after="):
			reads_after = a.substr(14)
		elif a == "--read-probe":
			read_probe = true
			BeltItems.State.force_gd = true
		elif a == "--persist":
			persist = true
		elif a == "--hold-emu":
			hold_emu = true
		elif a == "--replay-bre":
			replay_bre = true
		elif a.begins_with("--confirm-emu="):
			confirm_emu = a.substr(14)
		elif a.begins_with("--cap="):
			cap = int(a.substr(6))
		elif a.begins_with("--cam="):
			var ca := a.substr(6).split(",")
			cam = Camera3D.new()
			cam.fov = 50.0
			root.add_child(cam)
			cam.global_transform = Transform3D(Basis(Vector3.RIGHT, -deg_to_rad(50.0)), Vector3(float(ca[0]), 12.0, float(ca[1]) + 10.0))
		elif a == "--every-tick" or a.begins_with("--every-tick="):
			every_tick = true
			if a.length() > 13:
				lag = int(a.substr(13))
	BeltItems.read_flags(OS.get_cmdline_user_args())
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--belt-draw-dump="):
			# (What each job writes for the GPU, as the client's --belt-draw-dump: tools/belt_draw_diff.py.)
			BeltItems.Job.dump = FileAccess.open(a.substr(17), FileAccess.WRITE)
	if drawn_check:
		BeltItems.State.draw_native = false  # (DiagJob watches _apply_changes)
	print("drawing: %s" % BeltItems.flags_text())
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(truth))
	var metas: Array = d["lanes"]
	var keys := PackedInt64Array([0])
	for m: Array in metas:
		keys.append(int(m[0]) * 8 + int(m[5]))
	var game := {}  # tick -> {uid: [key, pos]}
	var game_item := {}  # uid -> the recording's item (its index in "names", from 1)
	var lanes_at := {}  # tick -> {key: [uid, item, pos, stack, ...]}: the bridge's answer to `bre`, emulated
	var recorded := {}
	for k in keys:
		recorded[k] = true
	var split_key := {}  # (--confirm-emu) recorded splitters' lanes
	for m: Array in metas:
		if str(m[2]) == "splitter" or str(m[2]) == "lane-splitter":
			split_key[int(m[0]) * 8 + int(m[5])] = true
	var split_in := {}  # (--hold-emu) recorded splitters' inputs
	for m: Array in metas:
		if (str(m[2]) == "splitter" and int(m[5]) <= 4) or (str(m[2]) == "lane-splitter" and int(m[5]) <= 2):
			split_in[int(m[0]) * 8 + int(m[5])] = true
	var hold_last := {}  # (--hold-emu) splitter input key -> its last read's items
	var n_holds := 0
	var last_read := {}  # (--confirm-emu) key -> [count, front, back, the read's items (uid, item, pos, stack, ...)]
	var n_confirm := 0
	for row: Array in d["ticks"]:
		var g := {}
		var la := {}
		for i in range(1, row.size(), 5):
			var key: int = keys[int(row[i])]
			g[int(row[i + 1])] = [key, int(row[i + 2])]
			game_item[int(row[i + 1])] = int(row[i + 4])
			if not la.has(key):
				la[key] = []
			(la[key] as Array).append_array([int(row[i + 1]), int(row[i + 4]), int(row[i + 2]), int(row[i + 3])])
		game[int(row[0])] = g
		lanes_at[int(row[0])] = la
	d = {}
	print("truth: %d lanes, ticks %s" % [metas.size(), [game.keys().min(), game.keys().max()]])
	# The stream's updates, parts together.
	var updates: Array = []
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
		if k != cur_k and not cur.is_empty():
			updates.append(cur)
			cur = []
		cur_k = k
		cur.append(msg)
	if not cur.is_empty():
		updates.append(cur)
	print("stream: %d updates" % updates.size())
	var vf: FileAccess = null
	var view_last := ""  # the last compared update's line, written at the end unless written already
	var view_written := false
	# (--view-dump) Each item's kind as the `sl` that set it said: the bridge's item id, or minus the
	# recording's (its "names" index from 1) for the `bre` answers emulated here from the recording.
	var item_of := {}
	if not view_dump.is_empty():
		vf = FileAccess.open(view_dump, FileAccess.WRITE)
	var state := BeltItems.State.new()
	var probe_from := int(game.keys().min())
	var right := 0
	var wrong := 0
	var missing := 0
	var extra := 0
	var off_sum := 0.0
	var near := 0  # elsewhere, but on the game's lane within 0.15 tile (38/256)
	var other_lane := 0  # elsewhere, on another lane than the game's
	var gone := 0
	var asked := 0
	var shown := 0
	var compared := 0
	var asks: Array = []  # [update index it is answered in, keys]
	# The jobs: [fold tick, the updates whose messages it gets].
	var steps: Array = []
	# (--every-tick) Compared up to the last update's drawn tick and its period: later the client would
	# have had another update (a capture cut short ends before the recording).
	var cmp_until := 1 << 62
	if every_tick:
		# Each update goes to the job at its tick less its period and 3 (the client's drawn clock: a gap
		# between updates and a margin behind the game), or less LAG; in order.
		var ks: Array = []
		var at: Array = []
		for u2: Array in updates:
			var uk := int(u2[0].get("k", 0))
			ks.append(uk)
			at.append(uk - (lag if lag >= 0 else int(u2[0].get("p", 1)) + 3))
		var last_t: int = maxi(int(ks.back()), int(game.keys().max()))
		var ni := 0
		for t in range(int(at[0]), last_t + 1):
			var us: Array = []
			while ni < ks.size() and int(at[ni]) <= t:
				us.append(ni)
				ni += 1
			steps.append([t, us])
		cmp_until = int(at.back()) + int(updates.back()[0].get("p", 1))
		if cmp_until < int(game.keys().max()):
			print("every tick: the capture ends before the recording: compared up to tick %d" % cmp_until)
			while not steps.is_empty() and int(steps.back()[0]) > cmp_until + 1:
				steps.pop_back()
		print("every tick: a job a tick, the drawn clock %s behind the updates" % ["%d ticks" % lag if lag >= 0 else "a period and 3 ticks"])
	else:
		for ui in updates.size():
			steps.append([int(updates[ui][0].get("k", 0)), [ui]])
	var known := {}
	var full := false
	var last_ui := 0
	var cost := [0, 0, 0, 0, 0, 0]  # jobs on recorded ticks: count, usec, records written, renewed, changes, records usec
	var last_ct := -1  # the tick compared last (the simulation standing at the newest update isn't compared twice)
	var prev_st: Array = []  # the simulation's items as the job before left it, at tick prev_t
	var prev_t := -1
	var oracle_tick := -1  # (--oracle-at) the tick every recorded lane was read
	var g0 := {}
	var closed := {}  # (--oracle-at, belt_sim.gd) recorded lanes whose items only go on into recorded lanes
	var ps := [0, 0, 0, 0, 0]  # (--persist) all compared updates: items, exact, within 0.15 on their lane, other lane, missing
	for step_e: Array in steps:
		var k: int = step_e[0]
		var job: BeltItems.Job = DiagJob.new() if drawn_check else BeltItems.Job.new()
		if drawn_check:
			(job as DiagJob).last = _dx_last
		job.state = state
		job.known = known.duplicate()
		job.full = full
		job.model_cap = cap
		if cam != null:
			cam.global_position.x += 0.1
			job.cam_led = true
			job.cam_pos = cam.global_position
			job.cam_dir = -cam.global_transform.basis.z
			job.cam_planes = ViewPriority.planes(cam)
		var no_reads := oracle_tick >= 0 and reads_after == "none"
		for ui: int in step_e[1]:
			var u: Array = updates[ui]
			var uk := int(u[0].get("k", 0))
			if no_reads:
				for m0: Dictionary in u:
					var m1 := m0.duplicate()
					m1.erase("sl")
					job.msgs.append(m1)
				last_ui = ui
				asks.clear()
				continue
			job.msgs.append_array(u.duplicate())
			if vf != null:
				for m: Dictionary in u:
					_note_items(m.get("sl", []), item_of, 1)
			if hold_emu:
				# (The bridge's `sh`: a splitter input whose items at this update are its last read's.)
				var read_h := {}
				for m: Dictionary in u:
					var a8: Array = m.get("sl", [])
					var i8 := 0
					while i8 + 2 < a8.size():
						var n8 := int(a8[i8 + 2])
						if split_in.has(int(a8[i8])):
							hold_last[int(a8[i8])] = a8.slice(i8 + 3, i8 + 3 + n8 * 4)
						read_h[int(a8[i8])] = true
						i8 += 3 + n8 * 4
				var la_h: Dictionary = lanes_at.get(uk, {})
				if not la_h.is_empty():
					var shl: Array = []
					for key in hold_last:
						if read_h.has(key) or not recorded.has(key):
							continue
						var lr: Array = hold_last[key]
						var gi: Array = la_h.get(key, [])
						if lr.is_empty() or gi.size() != lr.size():
							continue
						var same := true
						for j4 in range(0, lr.size(), 4):
							if int(lr[j4]) != int(gi[j4]) or int(lr[j4 + 2]) != int(gi[j4 + 2]):
								same = false
								break
						if same:
							shl.append_array([key, uk])
							n_holds += 1
					if not shl.is_empty():
						job.msgs.append({"t": "bs", "k": uk, "sh": shl})
			if not confirm_emu.is_empty():
				var read_now := {}
				for m: Dictionary in u:
					var a2: Array = m.get("sl", [])
					var i2 := 0
					while i2 + 2 < a2.size():
						var n2 := int(a2[i2 + 2])
						var its2: Array = a2.slice(i2 + 3, i2 + 3 + n2 * 4)
						var fr2 := 1 << 30
						var bk2 := -1
						for j2 in n2:
							fr2 = mini(fr2, int(its2[j2 * 4 + 2]))
							bk2 = maxi(bk2, int(its2[j2 * 4 + 2]))
						last_read[int(a2[i2])] = [n2, fr2 if n2 > 0 else -1, bk2, its2]
						read_now[int(a2[i2])] = true
						i2 += 3 + n2 * 4
				var la_c: Dictionary = lanes_at.get(uk, {})
				if not la_c.is_empty():
					var slc: Array = []
					for key in last_read:
						if read_now.has(key) or not recorded.has(key) or (confirm_emu == "split" and not split_key.has(key)):
							continue
						var lr: Array = last_read[key]
						var gi: Array = la_c.get(key, [])
						var gn := gi.size() / 4
						var gf := 1 << 30
						var gb := -1
						for j3 in gn:
							gf = mini(gf, int(gi[j3 * 4 + 2]))
							gb = maxi(gb, int(gi[j3 * 4 + 2]))
						if gn != int(lr[0]) or (gn > 0 and (gf != int(lr[1]) or gb != int(lr[2]))):
							continue
						slc.append_array([key, uk, gn])
						slc.append_array(lr[3])
						n_confirm += 1
					if not slc.is_empty():
						job.msgs.append({"t": "bs", "k": uk, "sl": slc})
			last_ui = ui
			# The bridge answers `bre` two updates on, reading the lanes then (here: from the recording).
			var la: Dictionary = lanes_at.get(uk, {})
			while not asks.is_empty() and int(asks[0][0]) <= ui and not la.is_empty():
				var sl: Array = []
				for key in asks[0][1]:
					if recorded.has(int(key)):
						var its: Array = la.get(int(key), [])
						sl.append_array([int(key), uk, its.size() / 4])
						sl.append_array(its)
				asks.pop_front()
				if not sl.is_empty():
					job.msgs.append({"t": "bs", "k": uk, "sl": sl})
					if vf != null:
						_note_items(sl, item_of, -1)
		if oracle_at >= 0 and oracle_tick < 0 and k >= oracle_at and game.has(k):
			oracle_tick = k
			g0 = game[k]
			var la0: Dictionary = lanes_at.get(k, {})
			var sl0: Array = []
			for key in keys:
				if key == 0:
					continue
				var its0: Array = la0.get(int(key), [])
				sl0.append_array([int(key), k, its0.size() / 4])
				sl0.append_array(its0)
			job.msgs.append({"t": "bs", "k": k, "sl": sl0})
			print("oracle: every recorded lane read at %d (%d items)" % [k, g0.size()])
			if state.sim is BeltSim:
				closed = _closed_lanes(state.sim, recorded)
				print("oracle: %d recorded lanes closed (all they lead on into recorded)" % closed.size())
		if read_probe and state.sim is BeltSim:
			state.sim.probe_reads = k >= probe_from
		job.fold_tick = float(k)
		job.now_msec = k * 16
		job.run()
		# (The kinds' looks, as the main thread gives them a job later.)
		full = not job.unknown.is_empty()
		for id in job.unknown:
			known[id] = [Vector3.ZERO, cap >= 0, 0.07]
		gone += job.gone_n
		asked += job.resend.size()
		if game.has(k):
			cost[0] += 1
			cost[1] += job.usec
			cost[2] += job.records_written
			cost[3] += job.renewed
			cost[4] += job.changes
			cost[5] += job.apply_usec + job.renew_usec + job.write_usec
		if replay_bre and not job.resend.is_empty():
			asks.append([last_ui + 2, job.resend.duplicate()])
		# The job's records are drawn from tick k (its fold) till the next job's: compared at k with the
		# simulation at k (the simulation runs ahead of the drawn clock: then as the job before left
		# it), and (--drawn-check) at the end, the simulation's tick now, with the simulation now.
		var now_st: Array = state.sim.items_state()
		var now_t := int(state.sim.tick)
		var st: Array = now_st
		# (The simulation stepped past k, ahead of the drawn clock (--belt-sim-ahead), and not at k after the
		# job before either: compared at its own tick, where the recording has it.)
		var ct := k
		if now_t != k:
			if prev_t == k:
				st = prev_st
			elif game.has(now_t) and now_t <= cmp_until and now_t != last_ct:
				ct = now_t
			else:
				st = []
		last_ct = ct
		if drawn_check and now_t > k and now_t <= k + BeltItems.Job.ahead and game.has(k) and k <= cmp_until:
			_drawn_precise(job as DiagJob, state, now_st[0], now_st[1], now_st[2], now_t, "(end) ")
		prev_st = now_st
		prev_t = now_t
		if st.is_empty() or ct > cmp_until:
			continue
		var g: Dictionary = game.get(ct, {})
		if g.is_empty():
			continue
		compared += 1
		var r0 := right
		var dc0 := dc.duplicate()
		var w0 := wrong
		var m0 := missing
		var e0 := extra
		var su: PackedInt64Array = st[0]
		var sk: PackedInt64Array = st[1]
		var sp: PackedInt32Array = st[2]
		var where := {}
		for i in su.size():
			where[su[i]] = i
		for uid in g:
			var e: Array = g[uid]
			if not state.lanes.has(int(e[0])):
				continue
			if not where.has(uid):
				missing += 1
				if shown < explain and ct >= explain_from:
					shown += 1
					print("  tick %d: game item %d on lane %d at %d, none simulated" % [ct, uid, e[0], e[1]])
				continue
			var i: int = where[uid]
			if sk[i] == int(e[0]) and sp[i] == int(e[1]):
				right += 1
			else:
				wrong += 1
				if sk[i] != int(e[0]):
					other_lane += 1
				if sk[i] == int(e[0]):
					off_sum += absf(sp[i] - int(e[1]))
					if absi(sp[i] - int(e[1])) <= 38:
						near += 1
				if shown < explain and ct >= explain_from:
					shown += 1
					print("  tick %d: game item %d on lane %d at %d, simulated on lane %d at %d" % [ct, uid, e[0], e[1], sk[i], sp[i]])
		for i in su.size():
			if not g.has(su[i]) and state.lanes.has(sk[i]):
				extra += 1
		if persist and oracle_tick >= 0:
			var pc := [0, 0, 0, 0, 0]
			for uid in g:
				if not g0.has(uid):
					continue
				var e3: Array = g[uid]
				if not state.lanes.has(int(e3[0])):
					continue
				if not closed.is_empty() and not closed.has(int(e3[0])):
					continue
				pc[0] += 1
				if not where.has(uid):
					pc[4] += 1
					continue
				var i3: int = where[uid]
				if sk[i3] != int(e3[0]):
					pc[3] += 1
				elif sp[i3] == int(e3[1]):
					pc[1] += 1
					pc[2] += 1
				elif absi(sp[i3] - int(e3[1])) <= 38:
					pc[2] += 1
			for x in 5:
				ps[x] += pc[x]
			print("  persist %d (+%d): items %d, exact %.1f%%, within 0.15 %.1f%%, other lane %.1f%%, missing %.1f%%" % [ct, ct - oracle_tick,
				pc[0], 100.0 * pc[1] / maxi(1, pc[0]), 100.0 * pc[2] / maxi(1, pc[0]), 100.0 * pc[3] / maxi(1, pc[0]), 100.0 * pc[4] / maxi(1, pc[0])])
		if follow_key != 0 and ct >= follow_at:
			var bykey := {}
			for uid in g:
				var e2: Array = g[uid]
				if not bykey.has(e2[0]):
					bykey[e2[0]] = [[], []]
				(bykey[e2[0]][0] as Array).append(int(e2[1]))
			for i in su.size():
				if not bykey.has(sk[i]):
					bykey[sk[i]] = [[], []]
				(bykey[sk[i]][1] as Array).append(sp[i])
			var fk := follow_key
			print("follow at %d:" % ct)
			for step in 400:
				if fk == 0:
					break
				var pr: Array = bykey.get(fk, [[], []])
				var gp: Array = pr[0]
				var spp: Array = pr[1]
				gp.sort()
				spp.sort()
				print("  %d (lane %d) out_edge %s: game %s sim %s" % [fk, ((fk - 1) & 7) + 1, state.sim.is_out_edge(fk) if state.sim.has_method("is_out_edge") else "?", gp, spp])
				fk = state.sim.next_of(fk)
			follow_key = 0
		if drawn_check:
			_drawn_check(job, state, g, su, sk, sp, ct, dc, dk)
			_drawn_precise(job as DiagJob, state, su, sk, sp, ct, "")
		if sim_dump != null:
			var parts := PackedStringArray()
			parts.append(str(ct))
			for i in su.size():
				parts.append("%d,%d,%d" % [su[i], sk[i], sp[i]])
			sim_dump.store_line(" ".join(parts))
		if vf != null:
			var vg := {}
			for uid in g:
				vg[str(uid)] = [g[uid][0], g[uid][1], game_item.get(uid, 0)]
			var vs := {}
			for i in su.size():
				vs[str(su[i])] = [sk[i], sp[i], item_of.get(su[i], 0)]
			view_last = JSON.stringify({"tick": ct, "lanes": state.lanes.keys(), "game": vg, "sim": vs})
			view_written = compared == 1 or (compared - 1) % view_every == 0
			if view_written:
				vf.store_line(view_last)
		if not dump.is_empty() and ct >= dump_at:
			var dg := {}
			for uid in g:
				if state.lanes.has(int(g[uid][0])):
					dg[str(uid)] = g[uid]
			var ds := {}
			for i in su.size():
				ds[str(su[i])] = [sk[i], sp[i]]
			var df := FileAccess.open(dump + ("." + str(ct) if dump_all else ""), FileAccess.WRITE)
			df.store_string(JSON.stringify({"tick": ct, "game": dg, "sim": ds}))
			df.close()
			if not dump_all:
				dump = ""
		if compared <= 40 or compared % 20 == 0:
			print("  update %d (sim tick %d, %d items, %d lanes): right %d, elsewhere %d, missing %d, extra %d%s" % [ct, int(state.sim.tick),
				state.sim.stats()["items"], state.lanes.size(), right - r0, wrong - w0, missing - m0, extra - e0,
				"; drawn by id within 0.15 %d, elsewhere %d, not drawn %d" % [dc[6] - dc0[6], dc[7] - dc0[7], dc[8] - dc0[8]] if drawn_check else ""])
	if drawn_check:
		print("by place, the game's items on lanes that show: %d; none simulated within 0.15 tile %.2f%%, none drawn within 0.15 tile %.2f%%" % [
			dc[0], 100.0 * dc[1] / maxi(1, dc[0]), 100.0 * dc[2] / maxi(1, dc[0])])
		print("by id, the game's items on lanes that show: simulated within 0.15 tile %.2f%%, elsewhere %.2f%%, not simulated %.2f%%; drawn within 0.15 tile %.2f%%, elsewhere %.2f%%, not drawn %.2f%%" % [
			100.0 * dc[3] / maxi(1, dc[0]), 100.0 * dc[4] / maxi(1, dc[0]), 100.0 * dc[5] / maxi(1, dc[0]),
			100.0 * dc[6] / maxi(1, dc[0]), 100.0 * dc[7] / maxi(1, dc[0]), 100.0 * dc[8] / maxi(1, dc[0])])
		print("items drawn off their simulated place, by kind: %s" % [dk])
		_drawn_report()
	if vf != null:
		if not view_written and not view_last.is_empty():
			vf.store_line(view_last)
		vf.store_line(JSON.stringify({"drawn": dk, "dc": dc, "updates": compared}))
		vf.close()
	if read_probe and state.sim is BeltSim:
		_read_probe_report(state, metas)
		# Each item a read took off on a recorded lane: whether the game still had it on the next recorded tick.
		var rt: Array = game.keys()
		rt.sort()
		var dv := {}
		for e: Array in state.sim.drop_log:
			if not recorded.has(int(e[2])):
				continue
			var t2 := rt.bsearch(int(e[0]))
			if t2 >= rt.size():
				continue
			var gg: Dictionary = game[rt[t2]]
			var still: bool = gg.has(int(e[1]))
			var rel := ""
			if still:
				var gk := int(gg[int(e[1])][0])
				var dk2 := int(e[2])
				if gk == dk2:
					rel = " on that lane"
				elif state.sim.next_of(dk2) == gk or state.sim.next_of(state.sim.next_of(dk2)) == gk:
					rel = " ahead (next 1-2)"
				elif state.sim.next_of(gk) == dk2 or state.sim.next_of(state.sim.next_of(gk)) == dk2:
					rel = " behind (feeder 1-2)"
				elif BeltSim._unit(gk) == BeltSim._unit(dk2):
					rel = " on that belt/splitter"
				else:
					rel = " elsewhere"
			var key2 := "%s: %s" % [e[3], ("the game still has it" + rel) if still else "the game hasn't"]
			dv[key2] = int(dv.get(key2, 0)) + 1
		var ks: Array = dv.keys()
		ks.sort()
		for k2 in ks:
			print("  dropped on recorded lanes, %s: %d" % [k2, dv[k2]])
		if not drop_dump.is_empty():
			var df2 := FileAccess.open(drop_dump, FileAccess.WRITE)
			for e: Array in state.sim.drop_log:
				df2.store_line("%d %d %d %s" % [int(e[0]), int(e[1]), int(e[2]), str(e[3])])
			df2.close()
	if sim_dump != null:
		sim_dump.close()
	if persist:
		print("persist, all compared updates: items %d, exact %.2f%%, within 0.15 %.2f%%, other lane %.2f%%, missing %.2f%%" % [ps[0],
			100.0 * ps[1] / maxi(1, ps[0]), 100.0 * ps[2] / maxi(1, ps[0]), 100.0 * ps[3] / maxi(1, ps[0]), 100.0 * ps[4] / maxi(1, ps[0])])
	if hold_emu:
		print("hold-emu: %d `sh` made, %d crossings held back" % [n_holds, int(state.sim.n_held)])
	if not confirm_emu.is_empty():
		print("confirm-emu %s: %d lanes read again as their last read" % [confirm_emu, n_confirm])
	var nj := maxi(1, cost[0])
	print("jobs on the recorded ticks: %d, %.2f ms a job (records: applying, renewing, writing %.2f ms), %.0f changes, %.0f renewed, %.0f records written a job" % [
		cost[0], cost[1] / 1000.0 / nj, cost[5] / 1000.0 / nj, float(cost[4]) / nj, float(cost[3]) / nj, float(cost[2]) / nj])
	var all := maxi(1, right + wrong + missing)
	print("compared %d updates: game items on simulated lanes where the game has them %d (%.2f%%), elsewhere %d (%.2f%%, on another lane %.2f%%, same lane off %.1f/256 on average), missing %d (%.2f%%); within 0.15 tile on their lane %.2f%%; simulated items the game hasn't %d; gone %d, asked again %d" % [
		compared, right, 100.0 * right / all, wrong, 100.0 * wrong / all, 100.0 * other_lane / all, off_sum / maxf(1.0, wrong), missing, 100.0 * missing / all, 100.0 * (right + near) / all, extra, gone, asked])
	quit(0)


## (--view-dump) Each item's kind from an `sl` list ([key, tick, n, uid, item, pos, stack, ...]), times sign.
static func _note_items(sl: Array, item_of: Dictionary, sign: int) -> void:
	var i := 0
	while i + 2 < sl.size():
		var n := int(sl[i + 2])
		for j in n:
			item_of[int(sl[i + 3 + j * 4])] = sign * int(sl[i + 4 + j * 4])
		i += 3 + n * 4


## (--read-probe) The reads from the first recorded tick on, by distance from the recording's middle
## (tiles, Chebyshev) and by lane kind: how many of their items the simulation had exactly there.
func _read_probe_report(state: RefCounted, metas: Array) -> void:
	var cx := 0.0
	var cy := 0.0
	for m: Array in metas:
		cx += float(m[7][0])
		cy += float(m[7][1])
	cx /= maxf(1.0, metas.size()) * 256.0
	cy /= maxf(1.0, metas.size()) * 256.0
	var bands := [8, 16, 32, 48, 64, 96, 128, 1000000]
	var by := {}
	var kinds := {}
	for key in state.sim.read_probe:
		var pr: Array = state.sim.read_probe[key]
		var lm: PackedInt32Array = state.lanes.get(int(key), PackedInt32Array())
		if lm.is_empty():
			continue
		var d := maxf(absf(lm[3] / 256.0 - cx), absf(lm[4] / 256.0 - cy))
		var bi := 0
		while d >= bands[bi]:
			bi += 1
		for tab in [[by, bi], [kinds, lm[0]]]:
			var t: Dictionary = tab[0]
			var a: Array = t.get(tab[1], [0, 0, 0, 0, 0, 0, 0])
			for x in 6:
				a[x] += pr[x]
			a[6] += 1
			t[tab[1]] = a
	print("read probe, items reads took off: %s; past back ends gone %d, carried back %d" % [state.sim.gone_probe, state.sim.n_past_back, state.sim.n_carried])
	print("read probe (centre %.1f, %.1f): reads' items the simulation had exactly there just before each read" % [cx, cy])
	for bi in bands.size():
		if by.has(bi):
			var a: Array = by[bi]
			print("  < %4d tiles: lanes %5d reads %6d items %7d exact %5.1f%% same line off %5.1f%% other line %5.1f%% none %5.1f%%" % [bands[bi], a[6], a[5], a[0],
				100.0 * a[1] / maxi(1, a[0]), 100.0 * a[2] / maxi(1, a[0]), 100.0 * a[3] / maxi(1, a[0]), 100.0 * a[4] / maxi(1, a[0])])
	for kd in kinds:
		var a: Array = kinds[kd]
		print("  kind %d: lanes %5d reads %6d items %7d exact %5.1f%% same line off %5.1f%% other line %5.1f%% none %5.1f%%" % [kd, a[6], a[5], a[0],
			100.0 * a[1] / maxi(1, a[0]), 100.0 * a[2] / maxi(1, a[0]), 100.0 * a[3] / maxi(1, a[0]), 100.0 * a[4] / maxi(1, a[0])])


## (--oracle-at) The recorded lanes from which every lane items can go on into (next, side-load target,
## a splitter input's outputs) is recorded too, by key.
static func _closed_lanes(sim: BeltSim, recorded: Dictionary) -> Dictionary:
	sim._relink()
	var memo := {}  # lane index -> 1 closed, 0 open, 2 being looked at
	var out := {}
	for key in recorded:
		var i: int = sim._key_idx.get(int(key), -1)
		if i >= 0 and _closed_at(sim, i, recorded, memo):
			out[int(key)] = true
	return out


static func _closed_at(sim: BeltSim, i: int, recorded: Dictionary, memo: Dictionary) -> bool:
	if memo.has(i):
		return memo[i] != 0
	if not recorded.has(int(sim.l_key[i])) or sim._out_keys.has(int(sim.l_key[i])):
		memo[i] = 0
		return false
	memo[i] = 2
	var nx: Array = []
	if sim.l_next[i] >= 0:
		nx.append(sim.l_next[i])
	if sim.l_side[i] >= 0:
		nx.append(sim.l_side[i])
	if sim.l_kind[i] == BeltSim.SPLIT_IN:
		var sp = sim._splitters.get(BeltSim._unit(int(sim.l_key[i])))
		if sp != null:
			for o in sp.outs:
				if o >= 0:
					nx.append(o)
	for j: int in nx:
		if not _closed_at(sim, j, recorded, memo):
			memo[i] = 0
			return false
	memo[i] = 1
	return true


## (--drawn-check) The game's items by place against the simulation's and against what the items'
## records draw at the same tick (their motion as belt_items.gd wrote it), on lanes that show; and the
## items drawn more than 0.15 tile from their simulated place, by their record's state and speed and
## by how far along the lane their record is off.
static func _cell(grid: Dictionary, x: float, y: float) -> bool:
	var cx := floori(x * 4.0)
	var cy := floori(y * 4.0)
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for q: Vector2 in grid.get(Vector2i(cx + dx, cy + dy), []):
				if absf(q.x - x) <= 0.15 and absf(q.y - y) <= 0.15 and Vector2(q.x - x, q.y - y).length() <= 0.15:
					return true
	return false


static func _put(grid: Dictionary, x: float, y: float) -> void:
	var c := Vector2i(floori(x * 4.0), floori(y * 4.0))
	if not grid.has(c):
		grid[c] = []
	(grid[c] as Array).append(Vector2(x, y))


func _drawn_check(job: RefCounted, state: RefCounted, g: Dictionary, su: PackedInt64Array, sk: PackedInt64Array,
		sp: PackedInt32Array, k: int, dc: Array, dk: Dictionary) -> void:
	var sim_grid := {}
	var sim_at := {}
	var sim_lane := {}
	for i in su.size():
		sim_lane[su[i]] = [sk[i], sp[i]]
		var w: Vector4 = job._point(int(sk[i]), float(sp[i]))
		if w.w > 0.5:
			_put(sim_grid, w.x, w.z)
			sim_at[su[i]] = w
	var drawn_grid := {}
	var drawn_at := {}
	for uid in state.items:
		var it = state.items[uid]
		if it.hidden:
			continue
		var gg := 1.0 if it.t_to <= it.t_from else clampf((float(k) - it.t_from) / (it.t_to - it.t_from), 0.0, 1.0)
		var at: Vector3 = it.from
		if it.path.is_empty():
			at += it.step * gg
		else:
			var pts: int = it.path.size() / 4
			var f := gg * float(pts - 1)
			var j := mini(int(f), maxi(pts - 2, 0))
			var a := Vector3(it.path[j * 4], it.path[j * 4 + 1], it.path[j * 4 + 2])
			var b := a if pts < 2 else Vector3(it.path[(j + 1) * 4], it.path[(j + 1) * 4 + 1], it.path[(j + 1) * 4 + 2])
			at += a.lerp(b, f - j)
			if lerpf(it.path[j * 4 + 3], it.path[mini(j + 1, pts - 1) * 4 + 3], f - j) < 0.5:
				continue  # (not drawn there: under the ground, or not on its lane yet)
		_put(drawn_grid, at.x, at.z)
		drawn_at[uid] = at
		var sw: Variant = sim_at.get(uid)
		if sw != null and Vector2(at.x - sw.x, at.z - sw.z).length() > 0.15:
			var why := "path" if not it.path.is_empty() else ("future" if it.t_from > float(k) + 0.5 else ("moving" if it.t_to > float(k) else "stood"))
			why += " v%d" % it.v
			dk[why] = int(dk.get(why, 0)) + 1
			if sim_lane.has(uid) and int(sim_lane[uid][0]) == it.lane:
				# Along the lane: where its record has it against where the simulation has it (- ahead).
				var pred: int = it.pos - mini(it.v * (k - it.t0), it.reach) if it.v > 0 else it.pos
				var b := "d%+d" % (clampi(pred - int(sim_lane[uid][1]), -512, 512) / 32 * 32)
				dk[b] = int(dk.get(b, 0)) + 1
			else:
				dk["other lane"] = int(dk.get("other lane", 0)) + 1
	for uid in g:
		var e: Array = g[uid]
		if not state.lanes.has(int(e[0])):
			continue
		var w: Vector4 = job._point(int(e[0]), float(e[1]))
		if w.w < 0.5:
			continue
		dc[0] += 1
		if not _cell(sim_grid, w.x, w.z):
			dc[1] += 1
		if not _cell(drawn_grid, w.x, w.z):
			dc[2] += 1
		var sw2: Variant = sim_at.get(uid)
		if sw2 != null and Vector2(sw2.x - w.x, sw2.z - w.z).length() <= 0.15:
			dc[3] += 1
		elif sw2 != null or sim_lane.has(uid):
			dc[4] += 1
		else:
			dc[5] += 1
		var dw: Variant = drawn_at.get(uid)
		if dw != null and Vector2(dw.x - w.x, dw.z - w.z).length() <= 0.15:
			dc[6] += 1
		elif dw != null:
			dc[7] += 1
		else:
			dc[8] += 1


## Where record r draws its item at tick t (absolute), as belt_path.gdshaderinc does, without the lift:
## Vector4(x, y, z, 1 shown / 0 not drawn).
static func _record_at(state: RefCounted, r: int, t: float) -> Vector4:
	var recs: BeltRecords = state.records
	var d := recs.data
	var o := r * BeltRecords.FLOATS
	var code := d[o + 11]
	if code < -0.5:
		return Vector4(d[o], d[o + 1], d[o + 2], 0.0)
	var ct := t - recs.base
	var g := clampf((ct - d[o + 3]) / (d[o + 7] - d[o + 3]), 0.0, 1.0) if d[o + 7] > d[o + 3] else 1.0
	var at := Vector3(d[o], d[o + 1], d[o + 2])
	if code < 0.5:
		return Vector4(at.x + d[o + 4] * g, at.y + d[o + 5] * g, at.z + d[o + 6] * g, 1.0)
	var c := int(code + 0.5) - 1
	var first := c / 64
	var pieces := c - first * 64 + 1
	var f := g * pieces
	var i := mini(int(f), pieces - 1)
	var tex: PackedFloat32Array = state.path_tex
	var a := (first + i) * 4
	if a + 7 >= tex.size():
		return Vector4(at.x, at.y, at.z, 0.0)
	var u := f - i
	var p := Vector4(lerpf(tex[a], tex[a + 4], u), lerpf(tex[a + 1], tex[a + 5], u), lerpf(tex[a + 2], tex[a + 6], u),
		lerpf(tex[a + 3], tex[a + 7], u))
	return Vector4(at.x + p.x, at.y + p.y, at.z + p.z, 1.0 if p.w >= 0.5 else 0.0)


func _dx_add(cls: String, line: String, k := 0) -> void:
	_dx[cls] = int(_dx.get(cls, 0)) + 1
	if _dx_max > 0:
		# (One a tick, from ticks DX_EVERY apart: examples from all over the run.)
		var ex: Array = _dx_ex.get(cls, [])
		if ex.size() < _dx_max and k >= int(_dx_ex_at.get(cls, -1000000000)) + DX_EVERY:
			_dx_ex_at[cls] = k
			ex.append(line)
			_dx_ex[cls] = ex


## (--drawn-check) Every simulated item at tick k: where its record (as written for the GPU) draws it
## against where the simulation has it; off by more than DX_TOL, classed by cause: the simulation's own
## last change for it doesn't lead to where it has it ("sim change": its output is wrong), else the
## record's kind (straight, path, standing, hidden, past its lane's back, kept) and timing (not started,
## ended, within) against that change. Also items drawn the simulation doesn't have.
func _drawn_precise(job: DiagJob, state: RefCounted, su: PackedInt64Array, sk: PackedInt64Array, sp: PackedInt32Array,
		k: int, pre: String) -> void:
	var sim_has := {}
	for i in su.size():
		var uid: int = su[i]
		sim_has[uid] = true
		_dx[pre + "item-ticks"] = int(_dx.get(pre + "item-ticks", 0)) + 1
		var w: Vector4 = job._point(int(sk[i]), float(sp[i]))
		var sim_vis := w.w > 0.5
		# (Past its lane's back end: in the game on a lane behind that isn't sent; drawn hidden.)
		var slm: PackedInt32Array = state.lanes.get(int(sk[i]), PackedInt32Array())
		if not slm.is_empty() and sp[i] > slm[1]:
			sim_vis = false
		var it = state.items.get(uid)
		if it == null:
			if pre != "":
				continue
			_dx_add(pre + "no item", "tick %d uid %d sim %d@%d" % [k, uid, sk[i], sp[i]], k)
			continue
		var kind = state.kinds.get(it.key)
		if it.slot < 0 or kind == null or kind.base < 0 or not kind.known:
			if pre != "":
				continue
			_dx_add(pre + "no record", "tick %d uid %d sim %d@%d slot %d key %d kind %s" % [k, uid, sk[i], sp[i], it.slot, it.key,
				"none" if kind == null else "base %d known %s" % [kind.base, kind.known]], k)
			continue
		var rec := _record_at(state, kind.base + it.slot, float(k))
		var mine: Vector3 = job._at(it, float(k))
		var dist := Vector2(rec.x - w.x, rec.z - w.z).length()
		if uid == DiagJob.trace:
			print("  trace %d: tick %d sim %d@%d (%.3f, %.3f)%s; item %d@%d t0 %d v %d reach %d run %d record %.2f..%.2f from (%.3f, %.3f) step (%.3f, %.3f) path %d -> (%.3f, %.3f)%s off %.3f" % [
				uid, k, sk[i], sp[i], w.x, w.z, "" if sim_vis else " hidden", it.lane, it.pos, it.t0, it.v, it.reach, it.run, it.t_from, it.t_to,
				it.from.x, it.from.z, it.step.x, it.step.z, it.path.size() / 4, rec.x, rec.z, "" if rec.w > 0.5 else " hidden", dist])
		var shown := rec.w > 0.5
		if shown and not it.hidden and Vector2(rec.x - mine.x, rec.z - mine.z).length() > 0.005:
			_dx_add(pre + "record != item", "tick %d uid %d rec %s item %s" % [k, uid, rec, mine])
		if not sim_vis and not shown:
			continue
		var bad := sim_vis != shown or dist > DX_TOL
		# (Just at a lane's end or entry, where one lane shows and the next doesn't: either.)
		if bad and dist <= DX_TOL and not slm.is_empty() and (sp[i] == 0 or sp[i] == slm[1]):
			bad = false
		if not bad:
			continue
		# What the simulation's last change for it says it is at k.
		var ch: Array = _dx_last.get(uid, [])
		var cause := ""
		var said := Vector2i(0, 0)
		if ch.is_empty():
			cause = "sim change: none"
		else:
			var dd := mini(int(ch[3]) * (k - int(ch[2])), int(ch[4])) if int(ch[3]) > 0 else 0
			said = job._advance(int(ch[0]), int(ch[1]), dd)
			if said.x != int(sk[i]) or said.y != int(sp[i]):
				cause = "sim change: %s, %s" % ["standing" if int(ch[3]) <= 0 else "moving", "same lane" if said.x == int(sk[i]) else "other lane"]
				cause += _sim_rec(state.sim, uid, int(ch[3]))
		if not cause.is_empty() and pre != "":
			continue  # (at the end: the simulation's changes on that tick are the next job's)
		if cause.is_empty():
			var rk := ""
			if state.kept.has(it):
				rk = "kept"
			elif it.hidden:
				rk = "hidden"
			elif not it.path.is_empty():
				rk = "path"
			elif it.step != Vector3.ZERO:
				rk = "straight"
			else:
				rk = "standing"
			var lm: PackedInt32Array = state.lanes.get(it.lane, PackedInt32Array())
			if not lm.is_empty() and it.pos > lm[1]:
				rk += " past back"
			var tm := "not started" if it.t_from > float(k) + 0.01 else ("ended" if it.t_to < float(k) - 0.01 else "within")
			cause = "record %s, %s%s%s" % [rk, tm, ", renewing" if state.renewing.has(it) else "",
				", shown wrong" if sim_vis != shown else ""]
		cause += " (> 0.15)" if dist > 0.15 or sim_vis != shown else ""
		var sk_kind: int = (state.lanes.get(int(sk[i]), PackedInt32Array([0])) as PackedInt32Array)[0]
		var it_kind: int = (state.lanes.get(it.lane, PackedInt32Array([0])) as PackedInt32Array)[0]
		_dx_add(pre + cause, "tick %d uid %d: sim %d@%d (kind %d) at (%.3f, %.3f)%s; change %s -> %d@%d; item %d@%d (kind %d) t0 %d v %d reach %d run %d; record t %.2f..%.2f from (%.3f, %.3f) step (%.3f, %.3f) path %d renew %.2f -> (%.3f, %.3f)%s, off %.3f" % [
			k, uid, sk[i], sp[i], sk_kind, w.x, w.z, "" if sim_vis else " hidden", ch, said.x, said.y, it.lane, it.pos, it_kind,
			it.t0, it.v, it.reach, it.run, it.t_from, it.t_to, it.from.x, it.from.z, it.step.x, it.step.z, it.path.size() / 4,
			it.renew, rec.x, rec.z, "" if shown else " hidden", dist], k)
	for uid in state.items:
		if sim_has.has(uid) or pre != "":
			continue  # (at the end: items gone on that tick are the next job's)
		var it = state.items[uid]
		if it.hidden:
			continue
		_dx_add(pre + "drawn, not simulated%s" % (" (kept)" if state.kept.has(it) else ""), "tick %d uid %d" % [k, uid], k)


func _drawn_report() -> void:
	for pre in ["", "(end) "]:
		var n := int(_dx.get(pre + "item-ticks", 0))
		if n == 0:
			continue
		var bad := 0
		var far := 0
		var keys := _dx.keys()
		keys.sort()
		print("drawn against simulated%s, every simulated item-tick (%d): off by more than %.2f tile, by cause:" % [
			", at the end of each job's ticks (the next job's tick)" if pre != "" else "", n, DX_TOL])
		for c: String in keys:
			if not c.begins_with(pre) or c == pre + "item-ticks" or pre == "" and c.begins_with("(end) "):
				continue
			print("  %6d  %s" % [_dx[c], c])
			var cc := c.substr(pre.length())
			if not cc.begins_with("record != item") and not cc.begins_with("drawn, not"):
				bad += int(_dx[c])
				if cc.ends_with("(> 0.15)") or cc.begins_with("no "):
					far += int(_dx[c])
		print("%sdrawn off their simulated place: %d item-ticks (%.3f%%), more than 0.15 tile or shown wrong %d (%.3f%%)" % [
			pre, bad, 100.0 * bad / n, far, 100.0 * far / n])
	for c in _dx_ex:
		print("examples, %s:" % c)
		for line: String in _dx_ex[c]:
			print("    " + line)


## (belt_sim.gd only) The item's record in its line as the simulation keeps it: pending (-1: emitted
## at the line's next step), or a speed (its last change said `said_v`), and the line's mode.
static func _sim_rec(sim: RefCounted, uid: int, said_v: int) -> String:
	if not (sim is BeltSim):
		return ""
	var id: int = sim._uid_line.get(uid, -1)
	if id < 0:
		return " [no line]"
	var L = sim._lines[id]
	var j: int = L.uid.find(uid)
	if j < 0 or L.rs.is_empty():
		return " [not in its line]"
	var rv: int = L.rv[sim._rec_index(L, j)]
	var mode := "mode %d%s" % [L.mode, "" if L.due >= 0 else " asleep"]
	if rv < 0:
		return " [pending, %s]" % mode
	if rv == said_v:
		return " [record v%d as said, %s]" % [rv, mode]
	return " [record v%d, said v%d, %s]" % [rv, said_v, mode]
