extends SceneTree
## (--arm-bind-layout, perf wave 4 T1) An arm's bind (_bind: base, direction, colour, model name, ModelLibrary.placed,
## chunk) stamped on ModelLibrary.layout_generation and the packs' version instead of ModelLibrary.generation, which
## goes up whenever any model finishes: two arms layers with the native pose, the switch off and on, fed the same
## stream (300 arms of four prototypes, cycling or idle, picks, drops, syncs, statuses, gone events, 15% lost, plain,
## delta-coded and packed lists), with records replaced (turned) and removed, chunks changed, and ready-only bumps of
## ModelLibrary.generation on random frames. After every message both layers hold the same arms with the same bind
## (base, dir, colour, model name, placed, chunk, bound) and InserterPoseNative state; after every frame's _process the
## same draw state (draw_state: mode, key, bound) and the same MultiMesh rows. With InserterIngestNative on and off.
## Then: after a ready-only bump the switched-on layer skips the bind (an arm's colour, set wrong by the test, stays),
## while a packs' version bump or ModelLibrary.choices_changed still binds every arm again; the unbind_all counts.
## Needs the native library (skips without it).
## Run: godot --headless --audio-driver Dummy --path client --log-file <abs> --script res://tests/inserter_bind_stamp_test.gd

const Arms := preload("res://scripts/world/inserter_arms.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const Swing := preload("res://scripts/world/inserter_swing.gd")
const Wire := preload("res://scripts/util/wire.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")
const Probing := preload("res://scripts/debug/probing.gd")

const ARMS := 300
const FRAMES := 300
const LOSE := 0.15
const TOL := 1e-5
const KINDS := [["inserter", 0.014, 0.035, false], ["fast-inserter", 0.04, 0.1, false],
	["long-handed-inserter", 0.02, 0.05, true], ["bulk-inserter", 0.04, 0.1, false]]

var passes := 0
var fails := 0
var shown := 0
var unbinds := [0, 0]
var handle_us := [0, 0]


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


## The arms layer with draw modes the test gives each prototype (no models in a headless test): boxes, Wube's pieces
## (long-handed), and one prototype (bulk) "still being read" for the first 30 frames.
class TestArms extends "res://scripts/world/inserter_arms.gd":
	var frame := 0

	func _decide_mode(arm: Arm) -> bool:
		var pack_ver := ModelLibrary.ModelPacks.version
		var model_ver := _model_ver()
		if arm.mode != Arm.Mode.NONE and arm.mode_pack_ver == pack_ver and arm.mode_model_ver == model_ver:
			return true
		match arm.proto_name:
			"long-handed-inserter":
				if not _model_parts.has(arm.proto_name):
					var out: Array = []
					for i in 3:
						var mm := MultiMesh.new()
						mm.transform_format = MultiMesh.TRANSFORM_3D
						mm.mesh = BoxMesh.new()
						var mmi := MultiMeshInstance3D.new()
						mmi.multimesh = mm
						add_child(mmi)
						out.append(mmi)
					_model_parts[arm.proto_name] = out
				arm.mode = Arm.Mode.MODEL
			"bulk-inserter":
				if frame < 30:
					return false
				arm.mode = Arm.Mode.BASIC
			_:
				arm.mode = Arm.Mode.BASIC
		arm.mode_cards = {}
		arm.mode_rig = {}
		arm.mode_pack_ver = pack_ver
		arm.mode_model_ver = model_ver
		return true


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
		print("inserter_bind_stamp_test: SKIP (no InserterPoseNative / InserterIngestNative in this build)")
		quit(0)
		return
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	var probe_was := Probing.on
	Probing.on = true
	_scenario(true, 1, 5100)
	_scenario(false, 3, 5103)
	Probing.on = probe_was
	Arms.bind_layout = true
	Arms.native_ingest = true
	print("inserter_bind_stamp_test: %s (%d passed, %d failed)" % ["PASS" if fails == 0 else "FAIL", passes, fails])
	quit(1 if fails > 0 else 0)


func _setup(rng: RandomNumberGenerator, hands: Array) -> Array:
	var protos := ProtoDB.new()
	var world := StubWorld.new()
	var eprops := {}
	for i in KINDS.size():
		var p := ProtoDB.EntityProto.new()
		p.id = i + 1
		p.name = KINDS[i][0]
		p.type = "inserter"
		p.color = Color(0.2 + 0.2 * i, 0.5, 0.8 - 0.15 * i)
		protos.entities[p.id] = p
		protos.entities_by_name[p.name] = p
		var long: bool = KINDS[i][3]
		eprops[p.id] = {"x": {"ip": [0, -2.0 if long else -1.0], "id": [0, 2.0 if long else 1.0], "rs": KINDS[i][1], "es": KINDS[i][2]}}
	for n in ARMS:
		var h := Hand.new()
		h.unit = 1000 + n
		h.ki = n % KINDS.size()
		h.dir = [0, 4, 8, 12][rng.randi() % 4]
		h.base = Vector2(float(n % 40) * 3.0 + 0.5, float(n / 40) * 4.0 + 0.5)
		var x: Dictionary = eprops[h.ki + 1]["x"]
		h.pick = Vector2(0.0, float(x["ip"][1])).rotated(-Wire.direction_yaw(h.dir))
		h.drop = Vector2(0.0, float(x["id"][1])).rotated(-Wire.direction_yaw(h.dir))
		h.omega = KINDS[h.ki][1]
		h.v = KINDS[h.ki][2]
		h.angle = h.pick.angle()
		h.reach = h.pick.length()
		h.wait = rng.randi_range(0, 30)
		h.idle = rng.randf() < 0.25
		h.kind = rng.randi_range(1, 6)
		h.start = 0 if rng.randf() < 0.7 else rng.randi_range(1, FRAMES / 2)
		if rng.randf() < 0.15:
			h.stop = rng.randi_range(h.start + 60, FRAMES * 3 + 60)
			h.gone_event = rng.randf() < 0.5
		hands.append(h)
		_put_rec(world, h)
	root.add_child(world)
	var belts := StubBelts.new()
	root.add_child(belts)
	var layers: Array = []
	for li in 2:
		var a: Node3D = TestArms.new()
		a.protos = protos
		a.world = world
		a.belts = belts
		a.eprops = eprops
		root.add_child(a)
		a.set_process(false)
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


## A new record for the hand (as world.gd makes one on every change), turned when `turn`.
func _put_rec(world: StubWorld, h: Hand, turn := false) -> void:
	if turn:
		h.dir = (h.dir + 4) % 16
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


## The message to each layer (each its own copy): layer 0 with the switch off, layer 1 on.
func _feed(layers: Array, msg: Dictionary, events: bool, ingest: bool) -> void:
	Arms.native_ingest = ingest
	for li in 2:
		Arms.bind_layout = li == 1
		var m := msg.duplicate(true)
		var before := int(Probing.counts.get("arm_unbind_all", 0))
		var t0 := Time.get_ticks_usec()
		if events:
			layers[li].handle_events(m)
		else:
			layers[li].handle(m)
		handle_us[li] += Time.get_ticks_usec() - t0
		unbinds[li] += int(Probing.counts.get("arm_unbind_all", 0)) - before
		# (Every queued plan made now, in both layers: which arms InserterPoseNative plans ahead each frame depends on
		# the queue's order, and a plan made ahead from fewer events can differ from one made later; the switch changes
		# that order (fewer hands through the GDScript), not the arms' state, so the test takes the order out.)
		var pn = layers[li]._pn
		while pn != null and pn.preplan_size() > 0:
			pn.preplan_some(Swing.reach_slack)
	Arms.bind_layout = true


func _process_both(layers: Array, f: int) -> void:
	for li in 2:
		Arms.bind_layout = li == 1
		layers[li].frame = f
		layers[li]._process(1.0 / 60.0)
	Arms.bind_layout = true


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


func _hands_msg(hands: Array, tick: int, rng: RandomNumberGenerator, lose: float) -> Dictionary:
	var l: Array = []
	for h: Hand in hands:
		if tick < h.start or tick >= h.stop or rng.randf() < lose:
			continue
		var hand := h.base + Vector2(cos(h.angle), sin(h.angle)) * h.reach
		l.append_array([h.unit, roundi(hand.x * 256.0), roundi(hand.y * 256.0), h.item])
	var msg := {"t": "ih", "k": tick, "p": 6, "part": 1, "parts": 1, "l": l}
	var form := rng.randi() % 3
	if form == 1:
		msg["l"] = _delta(l, 4)
		msg["z"] = 1
	elif form == 2:
		msg["l"] = PackedInt32Array(l)
	return msg


func _scenario(ingest: bool, tpf: int, seed_v: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var hands: Array = []
	var made := _setup(rng, hands)
	var world: StubWorld = made[0]
	var belts: StubBelts = made[1]
	var layers: Array = made[2]
	var old: Node3D = layers[0]
	var new: Node3D = layers[1]
	unbinds = [0, 0]
	handle_us = [0, 0]
	shown = 0
	var tick := 0
	var pending: Array = []
	var compared := 0
	var msgs := 0
	var bumps := 0
	var removed: Array = []
	var what := "ingest %s, %d tick(s) a frame" % ["on" if ingest else "off", tpf]
	for f in FRAMES:
		if f % 37 == 11:
			_put_rec(world, hands[rng.randi() % hands.size()], true)
		if f % 53 == 20:
			var h: Hand = hands[rng.randi() % hands.size()]
			world.entities.erase(h.unit)
			removed.append(h)
		elif f % 53 == 26 and not removed.is_empty():
			_put_rec(world, removed.pop_back())
		if f % 41 == 7:
			world.entities_changed.emit(Vector2i(rng.randi_range(0, 3), rng.randi_range(0, 2)))
		if f > 2 and rng.randf() < 0.2:
			ModelLibrary.generation += 1  # (a model finished: nothing an arm's bind reads changed)
			bumps += 1
		for _s in tpf:
			tick += 1
			var evs: Array = []
			for h: Hand in hands:
				if tick < h.start:
					continue
				if tick == h.stop and h.gone_event:
					evs.append_array([Swing.Ev.GONE, h.unit, tick, 0, 0, 0, 0, 0, 0])
				if tick >= h.stop:
					continue
				_step(h, tick, evs, rng)
			pending.append([tick, evs])
			while not pending.is_empty() and int(pending[0][0]) < tick - 5:
				pending.pop_front()
			if tick % 2 == 0 and rng.randf() >= LOSE:
				var l: Array = []
				for e: Array in pending:
					l.append_array(e[1])
				var msg := {"t": "ie", "k": tick, "n": 6, "p": 2, "part": 1, "parts": 1, "l": l}
				if rng.randf() < 0.4:
					msg["l"] = _delta(l, 9)
					msg["z"] = 1
				_feed(layers, msg, true, ingest)
				msgs += 1
				compared += _compare_bind(old, new, "%s: frame %d tick %d ie" % [what, f, tick])
			if tick % 6 == 3:
				_feed(layers, _hands_msg(hands, tick, rng, LOSE), false, ingest)
				msgs += 1
				compared += _compare_bind(old, new, "%s: frame %d tick %d ih" % [what, f, tick])
		belts.tick = float(tick) - 40.0
		_process_both(layers, f)
		_compare_draw(old, new, "%s: frame %d" % [what, f])
	check(shown == 0, "%s: both layers' arms, binds, poses and draws equal after every one of %d messages (%d arm checks, %d ready-only bumps)" % [
		what, msgs, compared, bumps])
	check(compared > FRAMES * 50, "%s: arms compared (%d)" % [what, compared])
	if ingest:
		check(unbinds[0] >= bumps / 2 and unbinds[1] <= 2, "%s: InserterIngestNative's unbind_all %d times with the switch off, %d on (%d bumps)" % [
			what, unbinds[0], unbinds[1], bumps])
	print("%s: unbind_all off %d / on %d; handle() total %.2f ms off, %.2f ms on (%d messages)" % [what, unbinds[0], unbinds[1],
		handle_us[0] / 1000.0, handle_us[1] / 1000.0, msgs])
	_rebind_phase(layers, hands, tick, ingest, what)
	for n: Node in [old, new, belts, world]:
		root.remove_child(n)
		n.free()


## After a ready-only bump the switched-on layer keeps an arm's bind (its colour, set wrong here, stays); after a
## packs' version bump and after choices_changed both layers bind every arm again.
func _rebind_phase(layers: Array, hands: Array, tick: int, ingest: bool, what: String) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var wrong := Color(1.0, 0.0, 1.0)
	var steps := [["ready-only bump", 0], ["packs' version", 1], ["choices_changed", 2]]
	for st: Array in steps:
		for a: Node in layers:
			for u in a._arms:
				a._arms[u].color = wrong
		match int(st[1]):
			0:
				ModelLibrary.generation += 1
			1:
				ModelLibrary.ModelPacks.version += 1
			2:
				ModelLibrary.choices_changed(["inserter"])
		tick += 6
		_feed(layers, _hands_msg(hands, tick, rng, 0.0), false, ingest)
		var kept := [0, 0]
		var total := [0, 0]
		for li in 2:
			for h: Hand in hands:
				var arm = layers[li]._arms.get(h.unit)
				if arm == null or not arm.bound or tick < h.start or tick >= h.stop:
					continue  # (no hand of it in the message)
				total[li] += 1
				if arm.color == wrong:
					kept[li] += 1
		if int(st[1]) == 0:
			check(total[1] > 0 and kept[1] == total[1] and kept[0] == 0, "%s: %s: the switched-on layer kept %d of %d binds, off %d of %d" % [
				what, st[0], kept[1], total[1], kept[0], total[0]])
		elif int(st[1]) == 1:
			check(total[1] > 0 and kept[1] == 0 and kept[0] == 0, "%s: %s binds every arm again (wrong colour left: on %d of %d, off %d of %d)" % [
				what, st[0], kept[1], total[1], kept[0], total[0]])
		else:  # (off, as before: only when the change dropped a model already made, none in this test)
			check(total[1] > 0 and kept[1] == 0, "%s: %s binds every arm again with the switch on (wrong colour left: %d of %d)" % [
				what, st[0], kept[1], total[1]])


## Both layers' arms the same: the bind's fields and the native pose state; how many arms were compared.
func _compare_bind(old: Node3D, new: Node3D, where: String) -> int:
	if old._arms.size() != new._arms.size():
		_show("%s: %d arms with the switch off, %d on" % [where, old._arms.size(), new._arms.size()])
		return 0
	var n := 0
	for unit in old._arms:
		var ao = old._arms[unit]
		var an = new._arms.get(unit)
		if an == null:
			_show("%s: arm %d only with the switch off" % [where, unit])
			continue
		n += 1
		if ao.base != an.base or ao.dir != an.dir or ao.color != an.color or ao.model_name != an.model_name \
				or not ao.placed.is_equal_approx(an.placed) or ao.chunk != an.chunk or ao.bound != an.bound or ao.proto_name != an.proto_name:
			_show("%s: arm %d bind differs: off (%s, %d, %s, %s, %s, %s) on (%s, %d, %s, %s, %s, %s)" % [where, unit, ao.base, ao.dir,
				ao.color, ao.model_name, ao.chunk, ao.bound, an.base, an.dir, an.color, an.model_name, an.chunk, an.bound])
			continue
		if (ao.slot >= 0) != (an.slot >= 0):
			_show("%s: arm %d native slot %d / %d" % [where, unit, ao.slot, an.slot])
			continue
		if ao.slot >= 0:
			var sto: Dictionary = old._pn.arm_state(ao.slot)
			var stn: Dictionary = new._pn.arm_state(an.slot)
			sto.erase("plans")  # (when a plan is made ahead: scheduling only, the poses are compared each frame)
			stn.erase("plans")
			if var_to_str(sto) != var_to_str(stn):
				_show("%s: arm %d pose state differs" % [where, unit])
	return n


## After _process: every arm's pose and native draw state, and every MultiMesh's rows.
func _compare_draw(old: Node3D, new: Node3D, where: String) -> void:
	if old._pn_loop:
		old.sync_arms()
		new.sync_arms()
	for unit in old._arms:
		var ao = old._arms[unit]
		var an = new._arms.get(unit)
		if an == null:
			continue
		if absf(angle_difference(ao.angle, an.angle)) > TOL or absf(ao.reach - an.reach) > TOL or ao.item_id != an.item_id \
				or ao.mode != an.mode:
			_show("%s: arm %d drawn (%.5f, %.5f, %d, mode %d) off, (%.5f, %.5f, %d, mode %d) on" % [where, unit, ao.angle, ao.reach,
				ao.item_id, ao.mode, an.angle, an.reach, an.item_id, an.mode])
		elif ao.slot >= 0 and an.slot >= 0 and old._pn_loop and old._pn.draw_state(ao.slot) != new._pn.draw_state(an.slot):
			_show("%s: arm %d draw state %s off, %s on" % [where, unit, old._pn.draw_state(ao.slot), new._pn.draw_state(an.slot)])
	var pairs: Array = []
	for i in old._parts.size():
		pairs.append(["basic %d" % i, old._parts[i], new._parts[i], 16])
	for key in old._model_parts:
		if old._model_parts[key] == null:
			continue
		for i in (old._model_parts[key] as Array).size():
			pairs.append(["model %s %d" % [key, i], old._model_parts[key][i], new._model_parts.get(key, [null, null, null])[i], 12])
	for p: Array in pairs:
		if p[2] == null:
			_show("%s: %s missing with the switch on" % [where, p[0]])
			continue
		var mo: MultiMesh = (p[1] as MultiMeshInstance3D).multimesh
		var mn: MultiMesh = (p[2] as MultiMeshInstance3D).multimesh
		if mo.visible_instance_count != mn.visible_instance_count:
			_show("%s: %s: %d instances off, %d on" % [where, p[0], mo.visible_instance_count, mn.visible_instance_count])
			continue
		var d := _rows_diff(_rows(mo, p[3]), _rows(mn, p[3]))
		if d > TOL:
			_show("%s: %s: instances differ by %s" % [where, p[0], d])


func _rows(mm: MultiMesh, stride: int) -> Array:
	var buf := mm.buffer
	var out: Array = []
	var n := mm.visible_instance_count if mm.visible_instance_count >= 0 else mm.instance_count
	for i in n:
		out.append(buf.slice(i * stride, i * stride + stride))
	out.sort_custom(_less)
	return out


func _less(a: PackedFloat32Array, b: PackedFloat32Array) -> bool:
	for i in mini(a.size(), b.size()):
		if a[i] != b[i]:
			return a[i] < b[i]
	return a.size() < b.size()


func _rows_diff(a: Array, b: Array) -> float:
	if a.size() != b.size():
		return INF
	var worst := 0.0
	for i in a.size():
		var ra: PackedFloat32Array = a[i]
		var rb: PackedFloat32Array = b[i]
		for j in ra.size():
			worst = maxf(worst, absf(ra[j] - rb[j]))
	return worst


func _show(msg: String) -> void:
	shown += 1
	if shown <= 8:
		print("DIFF: " + msg)


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
			made.append_array([Swing.Ev.PICKED, h.unit, tick, 1, h.item, c, hx, hy, 0])
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
