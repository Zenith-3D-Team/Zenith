extends SceneTree
## (--native-inserter-ingest, perf A5) The arms' `ih` hands and `ie` events taken by InserterIngestNative against the
## GDScript (handle's list loop and _update, handle_events' loop, _end_frame's missing count, the stale sweep): two arms
## layers, both with InserterPoseNative, the switch off and on, fed the same stream: 300 arms of four prototypes,
## cycling or idle, picks, drops (some uncertain), syncs, statuses, gone events, arms falling silent, 18% of messages
## lost; hand lists plain, delta-coded (z = 1) or packed (a binary frame's PackedInt32Array), some updates in two
## parts with one part lost; records replaced mid-run (rotated: a new Rec), removed and put back, entities_changed
## and a ModelLibrary generation bump. After every message both layers hold the same arms, each with the same
## InserterPoseNative state (arm_state, preplan queue), ev_any, last_heard (after the native's heard) and missing
## count; after each frame's _process the same pose. Then timing: one `ih` of 300 and of 1,500 hands both ways.
## (--native-inserter-ingest2, perf wave 4 T3) The scenarios again with the native told of every dropped arm (its hands
## check only the record; end_frame2 and sweep walk its own entries and the unbound arms), against the same GDScript;
## then 5,000 arms known: _end_frame, the stale sweep and a 300-hand part timed GDScript, native, native 2.
## Needs the native library (skips without it).
## Run: godot --headless --audio-driver Dummy --path client --log-file <abs> --script res://tests/inserter_ingest_native_test.gd

const Arms := preload("res://scripts/world/inserter_arms.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const Swing := preload("res://scripts/world/inserter_swing.gd")
const Wire := preload("res://scripts/util/wire.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")

const ARMS := 300
const FRAMES := 400
const LOSE := 0.18

var passes := 0
var fails := 0
var shown := 0
var drawn_diffs := 0
var order_diffs := 0


class Rec:
	var unit := 0
	var pos := Vector2.ZERO
	var proto_id := 0
	var dir := 0
	var extra := {}
	var chunk := Vector2i.ZERO


class Chunk:
	var entities := {}
	var content_rev := 0


class StubWorld extends Node3D:
	signal entities_changed(chunk: Vector2i)
	var entities := {}
	var chunks := {}


class StubBelts extends Node3D:
	var tick := -1.0

	func drawn_tick() -> float:
		return tick


class Hand:
	var unit := 0
	var base := Vector2.ZERO
	var pick := Vector2.ZERO
	var drop := Vector2.ZERO
	var omega := 0.014
	var v := 0.035
	var angle := 0.0
	var reach := 1.0
	var item := 0
	var moving_to := -1
	var wait := 0
	var idle := false
	var start := 0
	var stop := 1 << 30
	var gone_event := false
	var kind := 3
	var ki := 0
	var dir := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		passes += 1
	else:
		fails += 1
		print("FAIL: %s" % msg)


func _init() -> void:
	if not (NativeLibrary.ensure() and ClassDB.class_exists("InserterPoseNative") and ClassDB.class_exists("InserterIngestNative")):
		print("inserter_ingest_native_test: SKIP (no InserterIngestNative in this build)")
		quit(0)
		return
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	var v2_ok: bool = (ClassDB.instantiate("InserterIngestNative") as Object).has_method("end_frame2")
	for v2 in [false, true]:
		if v2 and not v2_ok:
			print("inserter_ingest_native_test: native 2 SKIPPED (a library without end_frame2)")
			continue
		Arms.native_ingest2 = v2
		for tpf in [1, 3]:
			_scenario(tpf, 4000 + tpf, " (native 2)" if v2 else "")
	Arms.native_ingest2 = false
	for n in [300, 1500]:
		_timing(n)
	if v2_ok:
		_timing_big(5000)
	Arms.native_ingest2 = true
	print("inserter_ingest_native_test: %s (%d passed, %d failed)" % ["PASS" if fails == 0 else "FAIL", passes, fails])
	quit(1 if fails > 0 else 0)


func _setup(n_arms: int, rng: RandomNumberGenerator, hands: Array, n_layers := 2) -> Array:
	var protos := ProtoDB.new()
	var world := StubWorld.new()
	var eprops := {}
	var kinds := [["inserter", 0.014, 0.035, false], ["fast-inserter", 0.04, 0.1, false],
		["long-handed-inserter", 0.02, 0.05, true], ["bulk-inserter", 0.04, 0.1, false]]
	for i in kinds.size():
		var p := ProtoDB.EntityProto.new()
		p.id = i + 1
		p.name = kinds[i][0]
		p.type = "inserter"
		protos.entities[p.id] = p
		protos.entities_by_name[p.name] = p
		var long: bool = kinds[i][3]
		eprops[p.id] = {"x": {"ip": [0, -2.0 if long else -1.0], "id": [0, 2.0 if long else 1.0], "rs": kinds[i][1], "es": kinds[i][2]}}
	var belt_p := ProtoDB.EntityProto.new()
	belt_p.id = 9
	belt_p.name = "transport-belt"
	belt_p.type = "transport-belt"
	protos.entities[9] = belt_p
	protos.entities_by_name["transport-belt"] = belt_p
	for n in n_arms:
		var h := Hand.new()
		h.unit = 1000 + n
		h.ki = n % 4
		h.dir = [0, 4, 8, 12][rng.randi() % 4]
		h.base = Vector2(float(n % 40) * 3.0 + 0.5, float(n / 40) * 4.0 + 0.5)
		var x: Dictionary = eprops[h.ki + 1]["x"]
		h.pick = Vector2(0.0, float(x["ip"][1])).rotated(-Wire.direction_yaw(h.dir))
		h.drop = Vector2(0.0, float(x["id"][1])).rotated(-Wire.direction_yaw(h.dir))
		h.omega = kinds[h.ki][1]
		h.v = kinds[h.ki][2]
		h.angle = h.pick.angle()
		h.reach = h.pick.length()
		h.wait = rng.randi_range(0, 30)
		h.idle = rng.randf() < 0.25
		h.kind = rng.randi_range(1, 6)
		hands.append(h)
		_put_rec(world, h)
		if n % 2 == 0:
			var b := Rec.new()
			b.unit = 100000 + n
			b.pos = h.base + h.pick
			b.proto_id = 9
			b.chunk = Vector2i(floori(b.pos.x / 32.0), floori(b.pos.y / 32.0))
			if not world.chunks.has(b.chunk):
				world.chunks[b.chunk] = Chunk.new()
			(world.chunks[b.chunk] as Chunk).entities["b%d" % n] = b
	root.add_child(world)
	var belts := StubBelts.new()
	root.add_child(belts)
	var layers: Array = []
	for li in n_layers:
		var a: Node3D = Arms.new()
		a.protos = protos
		a.world = world
		a.belts = belts
		a.eprops = eprops
		root.add_child(a)
		layers.append(a)
	Arms.belt_clock = true
	Arms.handoff = true
	Arms.events = true
	Arms.events_items = true
	Arms.rest_arms = false
	Arms.native_pose = true
	for a: Node in layers:
		a._pose_native()
	return [world, belts, layers]


## A new record for the hand (as world.gd makes one on every change).
func _put_rec(world: StubWorld, h: Hand) -> void:
	var r := Rec.new()
	r.unit = h.unit
	r.pos = h.base
	r.proto_id = h.ki + 1
	r.dir = h.dir
	r.chunk = Vector2i(floori(h.base.x / 32.0), floori(h.base.y / 32.0))
	world.entities[h.unit] = r
	if not world.chunks.has(r.chunk):
		world.chunks[r.chunk] = Chunk.new()
	(world.chunks[r.chunk] as Chunk).entities["i%d" % h.unit] = r


## The message to each layer, the GDScript first (each its own copy), the switch as it should be for each.
func _feed(layers: Array, msg: Dictionary, events: bool) -> void:
	for li in 2:
		Arms.native_ingest = li == 1
		var m := msg.duplicate(true)
		if events:
			layers[li].handle_events(m)
		else:
			layers[li].handle(m)
	Arms.native_ingest = true


static func _delta(l: Array, stride: int) -> Array:
	var out := []
	var prev := []
	prev.resize(stride)
	prev.fill(0)
	for i in l.size():
		var j := i % stride
		out.append(int(l[i]) - int(prev[j]))
		prev[j] = int(l[i])
	return out


func _scenario(tpf: int, seed_v: int, label := "") -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var hands: Array = []
	var made_setup := _setup(ARMS, rng, hands)
	var world: StubWorld = made_setup[0]
	var belts: StubBelts = made_setup[1]
	var layers: Array = made_setup[2]
	for h: Hand in hands:
		h.start = 0 if rng.randf() < 0.7 else rng.randi_range(1, FRAMES * tpf / 2)
		if rng.randf() < 0.2:
			h.stop = rng.randi_range(h.start + 60, FRAMES * tpf + 60)
			h.gone_event = rng.randf() < 0.5
	var old: Node3D = layers[0]
	var new: Node3D = layers[1]
	var tick := 0
	var pending: Array = []
	var compared := 0
	var msgs := 0
	var removed: Array = []
	for f in FRAMES:
		# (Mid-run changes to the world: a record replaced (turned), one removed and put back, a chunk changed, the
		# models' generation.)
		if f % 37 == 11:
			var h: Hand = hands[rng.randi() % hands.size()]
			_put_rec(world, h)
		if f % 53 == 20:
			var h: Hand = hands[rng.randi() % hands.size()]
			world.entities.erase(h.unit)
			removed.append(h)
		elif f % 53 == 26 and not removed.is_empty():
			_put_rec(world, removed.pop_back())
		if f % 41 == 7:
			world.entities_changed.emit(Vector2i(rng.randi_range(0, 3), rng.randi_range(0, 2)))
		if f == FRAMES / 2:
			ModelLibrary.generation += 1
		for _s in tpf:
			tick += 1
			var made: Array = []
			for h: Hand in hands:
				if tick < h.start:
					continue
				if tick == h.stop and h.gone_event:
					made.append_array([Swing.Ev.GONE, h.unit, tick, 0, 0, 0, 0, 0, 0])
				if tick >= h.stop:
					continue
				_step(h, tick, made, rng)
				if rng.randf() < 0.0005:
					made.append_array([6, h.unit, tick, 1, h.item, 0, 0, 0, 0])  # (placed: for belt_items.gd)
			pending.append([tick, made])
			while not pending.is_empty() and int(pending[0][0]) < tick - 5:
				pending.pop_front()
			if tick % 2 == 0 and rng.randf() >= LOSE:
				var l: Array = []
				for e: Array in pending:
					l.append_array(e[1])
				if rng.randf() < 0.08 and l.size() >= 18:
					var tail := l.slice(l.size() - 9)
					l = tail + l.slice(0, l.size() - 9)
				var msg := {"t": "ie", "k": tick, "n": 6, "p": 2, "part": 1, "parts": 1, "l": l}
				if rng.randf() < 0.4:
					msg["l"] = _delta(l, 9)
					msg["z"] = 1
				_feed(layers, msg, true)
				msgs += 1
				compared += _compare(old, new, "frame %d tick %d ie" % [f, tick])
			if tick % 6 == 3:
				var l: Array = []
				for h: Hand in hands:
					if tick < h.start or tick >= h.stop or rng.randf() < LOSE:
						continue
					var hand := h.base + Vector2(cos(h.angle), sin(h.angle)) * h.reach
					l.append_array([h.unit, roundi(hand.x * 256.0), roundi(hand.y * 256.0), h.item])
				var parts: Array = [l]
				if rng.randf() < 0.25 and l.size() >= 8:
					var cut := (l.size() / 8) * 4
					parts = [l.slice(0, cut), l.slice(cut)]
				var lost := rng.randi_range(0, parts.size() - 1) if parts.size() > 1 and rng.randf() < 0.5 else -1
				for pi in parts.size():
					if pi == lost:
						continue
					var pl: Array = parts[pi]
					var msg := {"t": "ih", "k": tick, "p": 6, "part": pi + 1, "parts": parts.size(), "l": pl}
					var form := rng.randi() % 3
					if form == 1:
						msg["l"] = _delta(pl, 4)
						msg["z"] = 1
					elif form == 2:
						msg["l"] = PackedInt32Array(pl)
					_feed(layers, msg, false)
					msgs += 1
					compared += _compare(old, new, "frame %d tick %d ih part %d" % [f, tick, pi + 1])
		belts.tick = float(tick) - 40.0
		old._process(1.0 / 60.0)
		new._process(1.0 / 60.0)
		for unit in old._arms:
			var ao = old._arms[unit]
			var an = new._arms.get(unit)
			if an != null and (absf(angle_difference(ao.angle, an.angle)) > 1e-6 or absf(ao.reach - an.reach) > 1e-6 or ao.item_id != an.item_id):
				drawn_diffs += 1
				_show("frame %d: arm %d drawn (%.5f, %.5f, %d) GDScript, (%.5f, %.5f, %d) native ingest" % [f, unit,
					ao.angle, ao.reach, ao.item_id, an.angle, an.reach, an.item_id])
	var c: PackedInt64Array = new._ing.counts() if new._ing != null else PackedInt64Array([0, 0, 0, 0])
	check((label != "") == new._ing2, "%d tick(s) a frame%s: native 2 in use as asked (%s)" % [tpf, label, new._ing2])
	check(new._ing != null and old._ing == null, "%d tick(s) a frame%s: only the switched-on layer has InserterIngestNative" % [tpf, label])
	check(shown == 0, "%d tick(s) a frame%s: both layers' arms equal after every one of %d messages (%d arm checks)" % [tpf, label, msgs, compared])
	check(c[0] > c[1] * 4 and c[2] > c[3], "%d tick(s) a frame%s: most hands and events taken natively (hands %d native, %d back; events %d native, %d back)" % [
		tpf, label, c[0], c[1], c[2], c[3]])
	check(drawn_diffs == 0, "%d tick(s) a frame%s: every drawn pose equal (%d arm-frames differ)" % [tpf, label, drawn_diffs])
	print("%d tick(s) a frame%s: %d checks where only the preplan order differed" % [tpf, label, order_diffs])
	drawn_diffs = 0
	order_diffs = 0
	check(compared > FRAMES * 100, "%d tick(s) a frame%s: arms compared (%d)" % [tpf, label, compared])
	print("%d tick(s) a frame%s: hands %d native, %d back; events %d native, %d back" % [tpf, label, c[0], c[1], c[2], c[3]])
	shown = 0
	for n: Node in [old, new, belts, world]:
		root.remove_child(n)
		n.free()


## Both layers' arms the same, field by field; how many arms were compared.
func _compare(old: Node3D, new: Node3D, where: String) -> int:
	if new._ing != null:
		new._native_ingest(Arms.INGEST_HEARD)  # (last_heard as the sweep would read it)
	if old._arms.size() != new._arms.size():
		_show("%s: %d arms GDScript, %d native ingest" % [where, old._arms.size(), new._arms.size()])
		return 0
	# (The preplan queue's order, and so which arms have a plan made ahead, may differ: the hands the native can't take
	# join the queue after the ones it took. Only a scheduling difference: a plan not made ahead is made when the pose
	# needs it, and the drawn poses are compared after every frame.)
	if old._pn.preplan_size() != new._pn.preplan_size():
		order_diffs += 1
	if old._missing.size() != new._missing.size():
		_show("%s: missing counts differ: %s / %s" % [where, old._missing, new._missing])
		if shown <= 2:
			for u in new._missing:
				if not old._missing.has(u):
					var ao = old._arms.get(u)
					var an = new._arms.get(u)
					print("  unit %d: old arm %s ev_any %s evt %d; new arm %s ev_any %s registered %s; rec %s" % [u, ao != null,
						ao.ev_any if ao else false, ao.ev_ticks.size() if ao else -1, an != null, an.ev_any if an else false,
						new._ing.has(u), new.world.entities.has(u)])
	else:
		for u in old._missing:
			if not new._missing.has(u) or int(new._missing[u]) != int(old._missing[u]):
				_show("%s: missing count of %s differs: %s / %s" % [where, u, old._missing, new._missing])
				break
	var n := 0
	for unit in old._arms:
		var ao = old._arms[unit]
		var an = new._arms.get(unit)
		if an == null:
			_show("%s: arm %d only in the GDScript layer" % [where, unit])
			continue
		n += 1
		if ao.ev_any != an.ev_any or ao.last_heard != an.last_heard or ao.bound != an.bound or ao.base != an.base:
			_show("%s: arm %d ev_any %s/%s last_heard %s/%s bound %s/%s" % [where, unit, ao.ev_any, an.ev_any, ao.last_heard,
				an.last_heard, ao.bound, an.bound])
		var sto: Dictionary = old._pn.arm_state(ao.slot)
		var stn: Dictionary = new._pn.arm_state(an.slot)
		if sto.get("plans") != stn.get("plans"):
			order_diffs += 1
		sto.erase("plans")
		stn.erase("plans")
		var so := var_to_str(sto)
		var sn := var_to_str(stn)
		if so != sn:
			_show("%s: arm %d pose state differs:\n  %s\n  %s" % [where, unit, so.replace("\n", " "), sn.replace("\n", " ")])
	return n


func _show(msg: String) -> void:
	shown += 1
	if shown <= 8:
		print("DIFF: " + msg)


## One `ih` of n hands into a layer with arms known, both ways: the handle() time.
func _timing(n_arms: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 77 + n_arms
	var hands: Array = []
	var made := _setup(n_arms, rng, hands)
	var world: StubWorld = made[0]
	var belts: StubBelts = made[1]
	var layers: Array = made[2]
	var us := [0, 0]
	var runs := 20
	for r in runs + 2:
		var tick := 6 * (r + 1)
		var l: Array = []
		for h: Hand in hands:
			var a := h.angle + 0.01 * r
			var hand := h.base + Vector2(cos(a), sin(a)) * h.reach
			l.append_array([h.unit, roundi(hand.x * 256.0), roundi(hand.y * 256.0), h.kind if r % 2 == 0 else 0])
		var msg := {"t": "ih", "k": tick, "p": 6, "part": 1, "parts": 1, "l": PackedInt32Array(l)}
		for li in 2:
			Arms.native_ingest = li == 1
			var m := msg.duplicate(true)
			var t0 := Time.get_ticks_usec()
			layers[li].handle(m)
			if r >= 2:  # (the first two make and bind the arms)
				us[li] += Time.get_ticks_usec() - t0
	Arms.native_ingest = true
	var c: PackedInt64Array = layers[1]._ing.counts()
	print("timing: an ih of %d hands: %.3f ms GDScript, %.3f ms native ingest (hands %d native, %d back)" % [n_arms,
		us[0] / 1000.0 / runs, us[1] / 1000.0 / runs, c[0], c[1]])
	check(us[1] < us[0], "an ih of %d hands faster natively" % n_arms)
	for nd: Node in [layers[0], layers[1], belts, world]:
		root.remove_child(nd)
		nd.free()


func _step(h: Hand, tick: int, made: Array, rng: RandomNumberGenerator) -> void:
	var hand := h.base + Vector2(cos(h.angle), sin(h.angle)) * h.reach
	var hx := roundi(hand.x * 256.0)
	var hy := roundi(hand.y * 256.0)
	if (tick + h.unit) % 120 == 0:
		made.append_array([Swing.Ev.SYNC, h.unit, tick, 1 if h.item != 0 else 0, h.item, 0, hx, hy, 0])
	if rng.randf() < 0.002:
		made.append_array([Swing.Ev.STATUS, h.unit, tick, 1 if h.item != 0 else 0, h.item, rng.randi_range(0, 9), hx, hy, 0])
	if h.moving_to < 0:
		h.wait -= 1
		if h.wait > 0:
			return
		var c := rng.randi_range(1, 8) if rng.randf() < 0.15 else 0
		if h.item == 0:
			h.item = h.kind
			h.moving_to = 1
			made.append_array([Swing.Ev.PICKED, h.unit, tick, 1, h.item, c, hx, hy, 1 if h.unit % 2 == 0 else 0])
		else:
			made.append_array([Swing.Ev.DROPPED, h.unit, tick, 0, h.item, c, hx, hy, 0])
			h.item = 0
			h.moving_to = 0
		return
	var target: Vector2 = h.drop if h.moving_to == 1 else h.pick
	var w := h.omega * TAU
	var da := wrapf(target.angle() - h.angle, -PI, PI)
	var dr := target.length() - h.reach
	h.angle += signf(da) * minf(absf(da), w)
	h.reach += signf(dr) * minf(absf(dr), h.v)
	if absf(da) <= w and absf(dr) <= h.v:
		h.angle = target.angle()
		h.reach = target.length()
		h.moving_to = -1
		h.wait = rng.randi_range(200, 600) if h.idle else rng.randi_range(0, 12)


## (--native-inserter-ingest2) 5,000 arms known and bound in three layers (GDScript, native, native 2): _end_frame (every
## hand seen, nothing missing), the stale sweep (_sweep_stale, nothing stale) and a 300-hand `ih` part, timed.
func _timing_big(n_arms: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 501
	var hands: Array = []
	var made := _setup(n_arms, rng, hands, 3)
	var world: StubWorld = made[0]
	var belts: StubBelts = made[1]
	var layers: Array = made[2]
	var names := ["GDScript", "native", "native 2"]
	var part := 300
	var runs := 10
	var us_end := [0, 0, 0]
	var us_sweep := [0, 0, 0]
	var us_part := [0, 0, 0]
	var parts_timed := 0
	for r in runs + 2:
		var tick := 6 * (r + 1)
		var l: Array = []
		for h: Hand in hands:
			var a := h.angle + 0.01 * r
			var hand := h.base + Vector2(cos(a), sin(a)) * h.reach
			l.append_array([h.unit, roundi(hand.x * 256.0), roundi(hand.y * 256.0), h.kind if r % 2 == 0 else 0])
		var n_parts := ceili(float(n_arms) / part)
		for li in 3:
			var layer: Node3D = layers[li]
			Arms.native_ingest = li > 0
			Arms.native_ingest2 = li == 2
			var t0 := Time.get_ticks_usec()
			layer._end_frame()
			var t1 := Time.get_ticks_usec()
			layer._sweep_stale()
			var t2 := Time.get_ticks_usec()
			if r >= 2:  # (the first two make and bind the arms)
				us_end[li] += t1 - t0
				us_sweep[li] += t2 - t1
			layer._frame_tick = -1  # (this tick's _end_frame done above)
			for pi in n_parts:
				var pl := PackedInt32Array(l.slice(pi * part * 4, mini((pi + 1) * part * 4, l.size())))
				var msg := {"t": "ih", "k": tick, "p": 6, "part": pi + 1, "parts": n_parts, "l": pl}
				var tp := Time.get_ticks_usec()
				layer.handle(msg)
				if r >= 2 and pi > 0:
					us_part[li] += Time.get_ticks_usec() - tp
					if li == 0:
						parts_timed += 1
	Arms.native_ingest = true
	Arms.native_ingest2 = false
	var same: bool = layers[0]._arms.size() == n_arms and layers[1]._arms.size() == n_arms and layers[2]._arms.size() == n_arms
	check(same, "%d arms kept in all three layers (%d, %d, %d)" % [n_arms, layers[0]._arms.size(), layers[1]._arms.size(), layers[2]._arms.size()])
	check(layers[2]._ing2 and not layers[1]._ing2, "native 2 only in the third layer")
	for li in 3:
		print("timing, %d arms, %s: _end_frame %.3f ms, stale sweep %.3f ms, a %d-hand ih part %.3f ms" % [n_arms, names[li],
			us_end[li] / 1000.0 / runs, us_sweep[li] / 1000.0 / runs, part, us_part[li] / 1000.0 / maxi(1, parts_timed)])
	check(us_end[2] < us_end[1] and us_sweep[2] < us_sweep[1], "native 2's _end_frame and sweep faster than native's (%d / %d µs, %d / %d µs)" % [
		us_end[2], us_end[1], us_sweep[2], us_sweep[1]])
	for nd: Node in [layers[0], layers[1], layers[2], belts, world]:
		root.remove_child(nd)
		nd.free()
