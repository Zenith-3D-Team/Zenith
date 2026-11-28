extends SceneTree
## (--native-inserter-pose, perf A3) The arms' samples, events and pose kept and worked out by InserterPoseNative
## against the GDScript (Arm, _add_sample, _backdate, _preplan_some, _plan_pair, _pose_at, _item_from_events): two
## arms layers, the switch off and on, fed the same stream over 600 frames at 1, 2 and 6 game ticks a frame: 300
## arms of four prototypes (half taking from a belt), cycling or idle, picks and drops (some uncertain, dated back by
## the exact one after), syncs and statuses, events repeated over three messages and some out of order, 18% of hand
## updates and event messages lost, arms coming and going (gone events, falling silent). Every frame, after both
## layers' _process, every arm's angle and reach within TOL and its item equal. Run with the default hand-off (the
## pose from the samples, the item from the events) and with samples only. The arms layer's _process time printed
## both ways. A third layer, the GDScript pose with InserterSwingNative's plans (--native-inserter-swing), checked
## against the plain GDScript the same way. Needs the native library (skips without it).
## Run: godot --headless --audio-driver Dummy --path client --log-file <abs> --script res://tests/inserter_pose_native_test.gd

const Arms := preload("res://scripts/world/inserter_arms.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const Swing := preload("res://scripts/world/inserter_swing.gd")
const Wire := preload("res://scripts/util/wire.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")

const TOL := 1e-4
const ARMS := 300
const FRAMES := 600
const LOSE := 0.18
const BEHIND := 40.0  # the drawn tick behind the newest

var passes := 0
var fails := 0
var shown := 0
var shown_swing := 0


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


## A game hand, tick by tick: waits at an end, then swings to the other at its speeds, the item changing hands as
## it leaves.
class Hand:
	var unit := 0
	var base := Vector2.ZERO
	var pick := Vector2.ZERO  # about the base
	var drop := Vector2.ZERO
	var omega := 0.014
	var v := 0.035
	var angle := 0.0
	var reach := 1.0
	var item := 0
	var count := 0
	var cap := 1
	var at_pick := true
	var moving_to := -1  # -1 waiting; 0 to the pickup, 1 to the drop
	var wait := 0
	var idle := false
	var start := 0
	var stop := 1 << 30
	var gone_event := false
	var kind := 3  # the item it carries


func check(cond: bool, msg: String) -> void:
	if cond:
		passes += 1
	else:
		fails += 1
		print("FAIL: %s" % msg)


func _init() -> void:
	if not (NativeLibrary.ensure() and ClassDB.class_exists("InserterPoseNative")):
		print("inserter_pose_native_test: SKIP (no InserterPoseNative in this build)")
		quit(0)
		return
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	var times := []
	for with_events in [true, false]:
		for tpf in [1, 2, 6]:
			times.append([with_events, tpf, _scenario(with_events, tpf, 1000 + tpf * 7 + (0 if with_events else 50))])
	for t: Array in times:
		var r: Dictionary = t[2]
		print("%s, %d tick(s) a frame: _process %.3f ms a frame GDScript, %.3f ms native (%d arms on average); %d arm-frames compared" % [
			"events (hand-off)" if t[0] else "samples only", t[1], r["old_ms"], r["new_ms"], r["arms"], r["compared"]])
	print("inserter_pose_native_test: %s (%d passed, %d failed)" % ["PASS" if fails == 0 else "FAIL", passes, fails])
	quit(1 if fails > 0 else 0)


func _scenario(with_events: bool, tpf: int, seed_v: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
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
	var hands: Array = []
	for n in ARMS:
		var h := Hand.new()
		h.unit = 1000 + n
		var ki := n % 4
		var dir: int = [0, 4, 8, 12][rng.randi() % 4]
		h.base = Vector2(float(n % 20) * 3.0 + 0.5, float(n / 20) * 4.0 + 0.5)
		var x: Dictionary = eprops[ki + 1]["x"]
		h.pick = Vector2(0.0, float(x["ip"][1])).rotated(-Wire.direction_yaw(dir))
		h.drop = Vector2(0.0, float(x["id"][1])).rotated(-Wire.direction_yaw(dir))
		h.omega = kinds[ki][1]
		h.v = kinds[ki][2]
		h.angle = h.pick.angle()
		h.reach = h.pick.length()
		h.wait = rng.randi_range(0, 30)
		h.idle = rng.randf() < 0.25
		h.kind = rng.randi_range(1, 6)
		h.cap = rng.randi_range(2, 6) if ki == 3 else 1
		h.start = 0 if rng.randf() < 0.7 else rng.randi_range(1, FRAMES * tpf / 2)
		if rng.randf() < 0.2:
			h.stop = rng.randi_range(h.start + 60, FRAMES * tpf + 60)
			h.gone_event = rng.randf() < 0.5
		hands.append(h)
		var r := Rec.new()
		r.unit = h.unit
		r.pos = h.base
		r.proto_id = ki + 1
		r.dir = dir
		r.chunk = Vector2i(floori(h.base.x / 32.0), floori(h.base.y / 32.0))
		world.entities[h.unit] = r
		if not world.chunks.has(r.chunk):
			world.chunks[r.chunk] = Chunk.new()
		(world.chunks[r.chunk] as Chunk).entities["i%d" % h.unit] = r
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
	for native in [false, true, false]:
		var a: Node3D = Arms.new()
		a.protos = protos
		a.world = world
		a.belts = belts
		a.eprops = eprops
		root.add_child(a)
		layers.append(a)
	# (After _ready's read_flags.) The flags for this run; each layer makes its arms (and so picks the native or
	# not) at its first message, with native_pose as it is then.
	Arms.belt_clock = true
	Arms.handoff = with_events
	Arms.events = with_events
	Arms.events_items = with_events
	Arms.rest_arms = false
	Arms.native_swing = false
	for li in 3:
		Arms.native_pose = li == 1
		(layers[li] as Node)._pose_native()  # (picked once, here)
	Arms.native_pose = true
	# (The third: the GDScript pose with InserterSwingNative's plans, --native-inserter-swing; the first plain GDScript.)
	layers[0]._sw_tried = true
	layers[0]._sw = null
	layers[2]._sw_tried = true
	layers[2]._sw = ClassDB.instantiate("InserterSwingNative")
	var old: Node3D = layers[0]
	var new: Node3D = layers[1]
	var tick := 0
	var pending: Array = []  # [tick made, events]
	var old_us := 0
	var new_us := 0
	var arm_frames := 0
	var compared := 0
	var compared_swing := 0
	for f in FRAMES:
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
			if with_events:
				pending.append([tick, made])
				while not pending.is_empty() and int(pending[0][0]) < tick - 5:
					pending.pop_front()
				if tick % 2 == 0 and rng.randf() >= LOSE:
					var l: Array = []
					for e: Array in pending:
						l.append_array(e[1])
					if rng.randf() < 0.08 and l.size() >= 18:
						# (Out of order: the last record first.)
						var tail := l.slice(l.size() - 9)
						l = tail + l.slice(0, l.size() - 9)
					var msg := {"t": "ie", "k": tick, "n": 6, "p": 2, "part": 1, "parts": 1, "l": l}
					for li in 3:
						(layers[li] as Node).handle_events(msg.duplicate(true))
			if tick % 6 == 3:
				var l: Array = []
				for h: Hand in hands:
					if tick < h.start or tick >= h.stop or rng.randf() < LOSE:
						continue
					var hand := h.base + Vector2(cos(h.angle), sin(h.angle)) * h.reach
					l.append_array([h.unit, roundi(hand.x * 256.0), roundi(hand.y * 256.0), h.item])
				var msg := {"t": "ih", "k": tick, "p": 6, "part": 1, "parts": 1, "l": l}
				for li in 3:
					(layers[li] as Node).handle(msg.duplicate(true))
		belts.tick = float(tick) - BEHIND
		var t0 := Time.get_ticks_usec()
		old._process(1.0 / 60.0)
		var t1 := Time.get_ticks_usec()
		new._process(1.0 / 60.0)
		var t2 := Time.get_ticks_usec()
		old_us += t1 - t0
		new_us += t2 - t1
		layers[2]._process(1.0 / 60.0)
		new.sync_arms()  # (--native-inserter-loop: the arms' drawn pose is kept natively; copied back to compare)
		arm_frames += old._arms.size()
		if f == 0:
			check(new._pn != null and old._pn == null and layers[2]._pn == null, "the switched-on layer has InserterPoseNative, the others none")
		for li in [1, 2]:
			var other: Node3D = layers[li]
			var what: String = "native pose" if li == 1 else "native swing"
			if old._arms.size() != other._arms.size():
				_show("frame %d: %d arms, %s %d" % [f, old._arms.size(), what, other._arms.size()], li)
				continue
			for unit in old._arms:
				var ao = old._arms[unit]
				var an = other._arms.get(unit)
				if an == null:
					_show("frame %d: arm %d only in the GDScript layer (%s)" % [f, unit, what], li)
					continue
				if li == 1:
					compared += 1
				else:
					compared_swing += 1
				if absf(angle_difference(ao.angle, an.angle)) > TOL or absf(ao.reach - an.reach) > TOL or ao.item_id != an.item_id or ao.item_count != an.item_count:
					_show("frame %d (tick %d, drawn %.0f) arm %d: GDScript (%.5f, %.5f, %d x%d), %s (%.5f, %.5f, %d x%d)" % [f, tick, belts.tick,
						unit, ao.angle, ao.reach, ao.item_id, ao.item_count, what, an.angle, an.reach, an.item_id, an.item_count], li)
	check(shown == 0, "%s, %d tick(s) a frame: every arm's pose equal with InserterPoseNative (%d arm-frames)" % [
		"events" if with_events else "samples", tpf, compared])
	check(shown_swing == 0, "%s, %d tick(s) a frame: every arm's pose equal with InserterSwingNative's plans (%d arm-frames)" % [
		"events" if with_events else "samples", tpf, compared_swing])
	check(compared > FRAMES * 50, "%s, %d tick(s) a frame: arms were drawn (%d)" % ["events" if with_events else "samples", tpf, compared])
	var out := {"old_ms": old_us / 1000.0 / FRAMES, "new_ms": new_us / 1000.0 / FRAMES, "arms": arm_frames / FRAMES, "compared": compared}
	shown = 0
	shown_swing = 0
	for n: Node in [old, new, layers[2], belts, world]:
		root.remove_child(n)
		n.free()
	Arms.native_pose = true
	Arms.native_swing = true
	Arms.rest_arms = true
	return out


func _show(msg: String, li: int) -> void:
	if li == 2:
		shown_swing += 1
		if shown_swing <= 4:
			print("DIFF: " + msg)
		return
	shown += 1
	if shown <= 8:
		print("DIFF: " + msg)


## One game tick of a hand; its events into `made` ([kind, unit, tick, a, b, c, x, y, belt] as the bridge's `ie`).
func _step(h: Hand, tick: int, made: Array, rng: RandomNumberGenerator) -> void:
	var hand := h.base + Vector2(cos(h.angle), sin(h.angle)) * h.reach
	var hx := roundi(hand.x * 256.0)
	var hy := roundi(hand.y * 256.0)
	if (tick + h.unit) % 120 == 0:
		made.append_array([Swing.Ev.SYNC, h.unit, tick, h.count, h.item, 0, hx, hy, 0])
	if rng.randf() < 0.002:
		made.append_array([Swing.Ev.STATUS, h.unit, tick, h.count, h.item, rng.randi_range(0, 9), hx, hy, 0])
	if h.moving_to < 0:
		h.wait -= 1
		if h.wait > 0:
			return
		var c := rng.randi_range(1, 8) if rng.randf() < 0.15 else 0
		if h.at_pick:
			if h.item == 0:
				h.item = h.kind
				h.count = 1
			else:
				h.count = mini(h.cap, h.count + 1)
			made.append_array([Swing.Ev.PICKED, h.unit, tick, h.count, h.item, c, hx, hy, 1 if h.unit % 2 == 0 else 0])
			if h.count < h.cap and rng.randf() < 0.65:
				h.wait = rng.randi_range(1, 2)
			else:
				h.moving_to = 1
		else:
			if h.count > 1 and rng.randf() < 0.45:
				h.count -= 1
				made.append_array([Swing.Ev.DROPPED, h.unit, tick, h.count, h.item, c, hx, hy, 0])
				h.wait = 1
			else:
				made.append_array([Swing.Ev.DROPPED, h.unit, tick, 0, h.item, c, hx, hy, 0])
				h.item = 0
				h.count = 0
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
		h.at_pick = h.moving_to == 0
		h.moving_to = -1
		h.wait = rng.randi_range(200, 600) if h.idle else rng.randi_range(0, 12)
