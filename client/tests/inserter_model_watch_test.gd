extends SceneTree
## (--arm-model-watch, perf wave 4 T2) The arms' draw modes and resting arms follow a stamp of the layer's own
## (_model_ver): the names the lookups were told "not ready" are asked again on a ModelLibrary.generation change and the
## stamp goes up only when one became ready (a safety net takes the raw generation at most every 2 s). Two arms layers
## with the native pose and loop, the switch off and on, fed the same hands and events (240 arms of three prototypes:
## one drawn as boxes, one as Wube's pieces, one whose model (fake readiness here) is "being read" until a frame
## mid-run; a fifth never heard). Every frame: the same modes, native draw state, MultiMesh rows and resting-arm
## count (the stubs give no resting rows; their whole rebuilds are counted, Probing `arm_rest_all`). Unrelated
## models finishing (generation bumps, nothing watched changed): the switched-on layer re-decides no mode, clears no native modes and rebuilds no resting arms, the switched-off layer all of them; the
## watched model turning ready: its arms drawn the same frame as with the switch off, the stamp up once; the safety
## net: an unexplained bump not taken inside its 2 s, taken after. Needs the native library (skips without it).
## Run: godot --headless --audio-driver Dummy --path client --log-file <abs> --script res://tests/inserter_model_watch_test.gd

const Arms := preload("res://scripts/world/inserter_arms.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const Swing := preload("res://scripts/world/inserter_swing.gd")
const Wire := preload("res://scripts/util/wire.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")
const Probing := preload("res://scripts/debug/probing.gd")

const ARMS := 240
const FRAMES := 160
const READY_FRAME := 90
const LOSE := 0.15
const TOL := 1e-5
const KINDS := [["inserter", 0.014, 0.035, false], ["long-handed-inserter", 0.02, 0.05, true], ["fast-inserter", 0.04, 0.1, false]]
const WATCHED := "test-rig-fast-inserter"

## Fake readiness (TestArms._ask_ready): names here answer as set, the rest as ModelLibrary does.
static var fake_ready := {}
## The simulated frame (TestArms._frame_now): the whole run is one engine frame, the stamp is latched per frame.
static var sim_frame := 0

var passes := 0
var fails := 0
var shown := 0


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


## The arms layer with the draw modes the test gives each prototype, asking its model's readiness through _model_ready
## (watched) as the real lookups do: fast-inserter's model is WATCHED, fake, not ready until READY_FRAME.
class TestArms extends "res://scripts/world/inserter_arms.gd":
	var decides := 0

	func _ask_ready(name: String) -> bool:
		var fake: Dictionary = (load("res://tests/inserter_model_watch_test.gd") as GDScript).fake_ready
		if fake.has(name):
			return bool(fake[name])
		return super._ask_ready(name)

	func _frame_now() -> int:
		return int((load("res://tests/inserter_model_watch_test.gd") as GDScript).sim_frame)

	func _decide_mode(arm: Arm) -> bool:
		var pack_ver := ModelLibrary.ModelPacks.version
		var model_ver := _model_ver()
		if arm.mode != Arm.Mode.NONE and arm.mode_pack_ver == pack_ver and arm.mode_model_ver == model_ver:
			return true
		if arm.mode != Arm.Mode.NONE:
			decides += 1  # (a mode decided before, decided again)
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
			"fast-inserter":
				if not _model_ready(WATCHED):
					return false  # (its model still being read)
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
	if not (NativeLibrary.ensure() and ClassDB.class_exists("InserterPoseNative")):
		print("inserter_model_watch_test: SKIP (no InserterPoseNative in this build)")
		quit(0)
		return
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	var probe_was := Probing.on
	Probing.on = true
	_scenario(7001)
	Probing.on = probe_was
	Arms.model_watch = true
	Arms.rest_arms = true
	fake_ready.clear()
	print("inserter_model_watch_test: %s (%d passed, %d failed)" % ["PASS" if fails == 0 else "FAIL", passes, fails])
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
		h.idle = rng.randf() < 0.3
		h.kind = rng.randi_range(1, 6)
		h.start = 0 if n % 5 != 4 else 1 << 30  # (a fifth never heard: resting arms)
		hands.append(h)
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
	Arms.rest_arms = true
	Arms.native_pose = true
	for a: Node in layers:
		a._pose_native()
	return [world, belts, layers]


## Layer 0 with the switch off, layer 1 on; every queued plan made at once in both (inserter_bind_stamp_test says why).
func _feed(layers: Array, msg: Dictionary, events: bool) -> void:
	for li in 2:
		Arms.model_watch = li == 1
		var m := msg.duplicate(true)
		if events:
			layers[li].handle_events(m)
		else:
			layers[li].handle(m)
		var pn = layers[li]._pn
		while pn != null and pn.preplan_size() > 0:
			pn.preplan_some(Swing.reach_slack)
	Arms.model_watch = true


## One frame of both layers; per layer [modes re-decided, native modes cleared, resting arms rebuilt whole].
func _process_both(layers: Array) -> Array:
	var out: Array = []
	for li in 2:
		Arms.model_watch = li == 1
		var d0: int = layers[li].decides
		var c0 := int(Probing.counts.get("arm_modes_cleared", 0))
		var r0 := int(Probing.counts.get("arm_rest_all", 0))
		layers[li]._process(1.0 / 60.0)
		out.append([layers[li].decides - d0, int(Probing.counts.get("arm_modes_cleared", 0)) - c0,
			int(Probing.counts.get("arm_rest_all", 0)) - r0])
	Arms.model_watch = true
	return out


func _hands_msg(hands: Array, tick: int, rng: RandomNumberGenerator, lose: float) -> Dictionary:
	var l: Array = []
	for h: Hand in hands:
		if tick < h.start or rng.randf() < lose:
			continue
		var hand := h.base + Vector2(cos(h.angle), sin(h.angle)) * h.reach
		l.append_array([h.unit, roundi(hand.x * 256.0), roundi(hand.y * 256.0), h.item])
	return {"t": "ih", "k": tick, "p": 3, "part": 1, "parts": 1, "l": PackedInt32Array(l)}


func _scenario(seed_v: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	fake_ready.clear()
	fake_ready[WATCHED] = false
	var hands: Array = []
	var made := _setup(rng, hands)
	var world: StubWorld = made[0]
	var belts: StubBelts = made[1]
	var layers: Array = made[2]
	var old: Node3D = layers[0]
	var new: Node3D = layers[1]
	shown = 0
	var tick := 0
	var unrelated := [[0, 0, 0], [0, 0, 0]]
	var unrelated_frames := 0
	var ready_frame_diffs := -1
	for f in FRAMES:
		sim_frame += 1
		var bump := ""
		var bumps_before: int = new.watch_bumps
		if f == READY_FRAME:
			fake_ready[WATCHED] = true
			ModelLibrary.generation += 1
			bump = "watched"
		elif f > 20 and f % 7 == 3:
			ModelLibrary.generation += 1  # (some other model finished)
			bump = "unrelated"
		tick += 1
		var evs: Array = []
		for h: Hand in hands:
			if tick >= h.start:
				_step(h, tick, evs, rng)
		if not evs.is_empty():
			_feed(layers, {"t": "ie", "k": tick, "n": 6, "p": 1, "part": 1, "parts": 1, "l": evs}, true)
		if tick % 3 == 0:
			_feed(layers, _hands_msg(hands, tick, rng, LOSE), false)
		belts.tick = float(tick) - 30.0
		var shown_was := shown
		var counts := _process_both(layers)
		_compare_draw(old, new, "frame %d" % f)
		_compare_rest(old, new, "frame %d" % f)
		if bump == "unrelated":
			unrelated_frames += 1
			for li in 2:
				for j in 3:
					unrelated[li][j] += int(counts[li][j])
		elif bump == "watched":
			ready_frame_diffs = shown - shown_was
			check(new.watch_bumps == bumps_before + 1, "the watched model ready: the stamp up once (%d -> %d)" % [bumps_before, new.watch_bumps])
			var drawn_fast := [0, 0]
			for li in 2:
				for u in layers[li]._arms:
					var a = layers[li]._arms[u]
					if a.proto_name == "fast-inserter" and a.mode != Arms.Arm.Mode.NONE:
						drawn_fast[li] += 1
			check(drawn_fast[1] > 0 and drawn_fast[1] == drawn_fast[0],
				"the watched model ready: its arms have a mode the same frame (%d on, %d off)" % [drawn_fast[1], drawn_fast[0]])
	check(shown == 0, "both layers draw the same every frame (%d frames)" % FRAMES)
	check(ready_frame_diffs == 0, "the watched model's arms drawn as with the switch off on the frame it became ready")
	check(unrelated_frames > 5 and unrelated[0][0] > unrelated_frames * 50 and unrelated[0][1] == unrelated_frames,
		"switch off: unrelated models re-decide every arm (%d re-decides, %d clears in %d frames)" % [unrelated[0][0], unrelated[0][1], unrelated_frames])
	check(unrelated[0][2] > 0, "switch off: unrelated models rebuild the resting arms (%d)" % unrelated[0][2])
	check(unrelated[1][0] == 0 and unrelated[1][1] == 0 and unrelated[1][2] == 0,
		"switch on: unrelated models re-decide no mode, clear no native modes, rebuild no resting arms (%s)" % [unrelated[1]])
	print("unrelated bumps (%d frames): off %s, on %s [modes re-decided, native mode clears, resting rebuilds]; resting arms %d" % [
		unrelated_frames, unrelated[0], unrelated[1], new.rest_count])
	# The latch: a bump mid-frame (a model finishing between two arms' lookups) keeps the frame's stamp.
	var latched: int = new._model_ver()
	fake_ready["test-rig-latch"] = false
	new._model_ready("test-rig-latch")
	fake_ready["test-rig-latch"] = true
	ModelLibrary.generation += 1
	check(new._model_ver() == latched, "latch: a watched model ready mid-frame keeps the frame's stamp (%d)" % latched)
	sim_frame += 1
	check(new._model_ver() == latched + 1, "latch: taken the next frame (%d -> %d)" % [latched, new._model_stamp])
	fake_ready.erase("test-rig-latch")
	sim_frame += 1
	_process_both(layers)  # (the arms take the latch's new stamp)
	# The safety net, trailing: a bump nothing watched explains is taken once it stayed unaccepted WATCH_NET_MSEC,
	# even long after the last one was taken (the old leading net took the first bump after a quiet spell at once).
	ModelLibrary.generation += 1
	var nets_was: int = new.watch_nets
	var stamp_was: int = new._model_stamp
	sim_frame += 1
	var c := _process_both(layers)
	check(new.watch_nets == nets_was and new._model_stamp == stamp_was and int(c[1][1]) == 0,
		"safety net: an unexplained bump after a quiet spell is not taken at once")
	sim_frame += 1
	c = _process_both(layers)
	check(new.watch_nets == nets_was and new._model_stamp == stamp_was and int(c[1][1]) == 0,
		"safety net: nor inside its 2 s")
	new._watch_pend_msec -= Arms.WATCH_NET_MSEC
	sim_frame += 1
	c = _process_both(layers)
	check(new.watch_nets == nets_was + 1 and new._model_stamp == stamp_was + 1 and int(c[1][1]) == 1,
		"safety net: taken once unaccepted for 2 s (nets %d -> %d, native mode clears %d)" % [nets_was, new.watch_nets, int(c[1][1])])
	var shown_was2 := shown
	_compare_draw(old, new, "after the safety net")
	_compare_rest(old, new, "after the safety net")
	check(shown == shown_was2, "after the safety net both layers draw the same")
	for n: Node in [old, new, belts, world]:
		root.remove_child(n)
		n.free()


## The resting arms both layers draw: their count and box MultiMesh rows.
func _compare_rest(old: Node3D, new: Node3D, where: String) -> void:
	if old.rest_count != new.rest_count:
		_show("%s: %d resting arms off, %d on" % [where, old.rest_count, new.rest_count])
		return
	if old._rest_mmi != null and new._rest_mmi != null:
		var d := _rows_diff(_rows(old._rest_mmi.multimesh, 16), _rows(new._rest_mmi.multimesh, 16))
		if d > TOL:
			_show("%s: resting arms differ by %s" % [where, d])


## After _process: every arm's pose, mode and native draw state, and every MultiMesh's rows.
func _compare_draw(old: Node3D, new: Node3D, where: String) -> void:
	if old._pn_loop:
		old.sync_arms()
		new.sync_arms()
	if old._arms.size() != new._arms.size():
		_show("%s: %d arms off, %d on" % [where, old._arms.size(), new._arms.size()])
	for unit in old._arms:
		var ao = old._arms[unit]
		var an = new._arms.get(unit)
		if an == null:
			continue
		if absf(angle_difference(ao.angle, an.angle)) > TOL or absf(ao.reach - an.reach) > TOL or ao.item_id != an.item_id \
				or ao.mode != an.mode:
			_show("%s: arm %d drawn (%.5f, %.5f, %d, mode %d) off, (%.5f, %.5f, %d, mode %d) on" % [where, unit, ao.angle, ao.reach,
				ao.item_id, ao.mode, an.angle, an.reach, an.item_id, an.mode])
		elif ao.slot >= 0 and an.slot >= 0 and old._pn_loop:
			var so: PackedFloat64Array = old._pn.draw_state(ao.slot)
			var sn: PackedFloat64Array = new._pn.draw_state(an.slot)
			if so != sn:
				_show("%s: arm %d draw state %s off, %s on" % [where, unit, so, sn])
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
	if h.moving_to < 0:
		h.wait -= 1
		if h.wait > 0:
			return
		if h.item == 0:
			h.item = h.kind
			h.moving_to = 1
			made.append_array([Swing.Ev.PICKED, h.unit, tick, 1, h.item, 0, hx, hy, 0])
		else:
			made.append_array([Swing.Ev.DROPPED, h.unit, tick, 0, h.item, 0, hx, hy, 0])
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
