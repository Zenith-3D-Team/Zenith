extends SceneTree
## (--native-inserter-loop, perf A4) The rest of the arms' per-arm loop in InserterPoseNative (frame_check, frame_draw)
## against the GDScript loop: two arms layers with the native pose, the loop switch off and on, fed the same stream
## (inserter_pose_native_test's hands: 300 arms of four prototypes, cycling or idle, picks, drops, syncs, 18% of
## updates lost, arms coming and going) for 600 frames at 1, 2 and 6 game ticks a frame. The draw modes are set by the
## test (a subclass's _decide_mode): sprite cards, a rig, Wube's pieces and boxes, one prototype whose model is "still
## being read" for its first 40 frames; hands meeting belt items (take_hands, position_of) steered; a chunk behind
## the view for a while (behind_cull); arms' records removed (mined) and put back turned; a models' generation change
## mid-run. Every frame: every MultiMesh's instances (sorted: the two loops order arms differently) and count, the
## held items queued for ItemCards (position, turn), the animator's moving hands, the live set, every arm's pose,
## pincers and grabs (sync_arms), the steered count. _process time of both printed (300 arms; 1,500 with -- --big).
## Needs the native library (skips without it).
## Run: godot --headless --audio-driver Dummy --path client --log-file <abs> --script res://tests/inserter_loop_native_test.gd

const Arms := preload("res://scripts/world/inserter_arms.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const Swing := preload("res://scripts/world/inserter_swing.gd")
const Wire := preload("res://scripts/util/wire.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ViewPriority := preload("res://scripts/world/view_priority.gd")
const BeltSimConst := preload("res://scripts/world/belt_sim.gd")

const TOL := 1e-5
const FRAMES := 600
const LOSE := 0.18
const BEHIND := 40.0
const PENDING_FRAMES := 40
const KINDS := [["inserter", 0.014, 0.035, false], ["fast-inserter", 0.04, 0.1, false],
	["long-handed-inserter", 0.02, 0.05, true], ["bulk-inserter", 0.04, 0.1, false], ["stack-inserter", 0.04, 0.1, false]]

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


class StubAnim:
	var arm_working := {}

	func arm_moving(rec, moving: bool) -> void:
		if rec == null:
			return
		var unit := int(rec.unit)
		if moving == arm_working.has(unit):
			return
		if moving:
			arm_working[unit] = 1
		else:
			arm_working.erase(unit)


class StubCull:
	var hide := {}

	func is_active() -> bool:
		return true

	func hidden(c: Vector2i) -> bool:
		return hide.has(c)


class StubWorld extends Node3D:
	signal entities_changed(chunk: Vector2i)
	var entities := {}
	var chunks := {}
	var animator := StubAnim.new()
	var behind_cull := StubCull.new()


class StubBelts extends Node3D:
	var tick := -1.0
	var hands: Array = []
	var where := {}  # uid -> Vector3

	func drawn_tick() -> float:
		return tick

	func take_hands() -> Array:
		var out := hands
		hands = []
		return out

	func position_of(uid: int):
		return where.get(uid)


## The arms layer with the draw modes the test gives each prototype (both loops call _decide_mode).
class TestArms extends "res://scripts/world/inserter_arms.gd":
	var frame := 0

	func _test_mmis(count: int, colors := false) -> Array:
		var out: Array = []
		for i in count:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = colors
			mm.mesh = BoxMesh.new()
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			add_child(mmi)
			out.append(mmi)
		return out

	func _decide_mode(arm: Arm) -> bool:
		var pack_ver := ModelLibrary.ModelPacks.version
		var model_ver := _model_ver()
		if arm.mode != Arm.Mode.NONE and arm.mode_pack_ver == pack_ver and arm.mode_model_ver == model_ver:
			return true
		match arm.proto_name:
			"inserter":
				if not _sprite_mmis.has(arm.model_name):
					_sprite_mmis[arm.model_name] = _test_mmis(3)
				arm.mode = Arm.Mode.SPRITE
				arm.mode_cards = {"widths": [0.55, 0.3, 0.34]}
				arm.mode_rig = {}
			"fast-inserter":
				if not _rigs.has(arm.proto_name):
					_rigs[arm.proto_name] = {"mmis": _test_mmis(5)}
				arm.mode = Arm.Mode.RIG
				arm.mode_cards = {}
				arm.mode_rig = {"hinge": Vector3(1, 0, 0), "pivot": Vector3(0, 0.3, 0), "shoulder": Vector3(0.05, 0.42, 0.0),
					"elbow": Vector3(0.0, 0.55, -0.55), "grip": Vector3(0.02, 0.4, -1.1), "lengths": [0.56, 0.58],
					"heads": [Vector3(0, 0.3, 0), null, null, Vector3(0.05, 0.4, -1.0), Vector3(-0.05, 0.4, -1.0)],
					"axes": [null, null, null, Vector3(0, 1, 0), Vector3(0, 1, 0)],
					"angles": [null, null, null, 0.5, -0.5], "grip_angles": [null, null, null, 0.3, -0.3]}
			"long-handed-inserter":
				if not _model_parts.has(arm.proto_name):
					_model_parts[arm.proto_name] = _test_mmis(3)
				arm.mode = Arm.Mode.MODEL
				arm.mode_cards = {}
				arm.mode_rig = {}
			"stack-inserter":
				if frame < PENDING_FRAMES:
					return false  # (its model still being read)
				arm.mode = Arm.Mode.BASIC
				arm.mode_cards = {}
				arm.mode_rig = {}
			_:
				arm.mode = Arm.Mode.BASIC
				arm.mode_cards = {}
				arm.mode_rig = {}
		arm.mode_pack_ver = pack_ver
		arm.mode_model_ver = model_ver
		return true


## A game hand, tick by tick (inserter_pose_native_test's).
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
	var count := 0
	var cap := 1
	var at_pick := true
	var moving_to := -1
	var wait := 0
	var idle := false
	var start := 0
	var stop := 1 << 30
	var gone_event := false
	var kind := 3


func check(cond: bool, msg: String) -> void:
	if cond:
		passes += 1
	else:
		fails += 1
		print("FAIL: %s" % msg)


func _init() -> void:
	if not (NativeLibrary.ensure() and ClassDB.class_exists("InserterPoseNative")
			and ClassDB.class_exists("InserterArmsNative")
			and ClassDB.instantiate("InserterPoseNative").has_method("frame_draw")):
		print("inserter_loop_native_test: SKIP (no InserterPoseNative.frame_draw in this build)")
		quit(0)
		return
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	var tight := ViewPriority.tight_cull
	ViewPriority.tight_cull = true
	var times := []
	for with_events in [true, false]:
		for tpf in [1, 2, 6]:
			times.append([with_events, tpf, 300, _scenario(with_events, tpf, 300, 2000 + tpf * 7 + (0 if with_events else 50), true)])
	if "--big" in OS.get_cmdline_user_args():  # (the timing at 1,500 arms, not compared: a bench, off by default)
		times.append([true, 6, 1500, _scenario(true, 6, 1500, 4242, false)])
	ViewPriority.tight_cull = tight
	for t: Array in times:
		var r: Dictionary = t[3]
		print("%s, %d tick(s) a frame, %d arms: _process %.3f ms a frame with the GDScript loop, %.3f ms native (%d live on average); %d arm-frames compared" % [
			"events (hand-off)" if t[0] else "samples only", t[1], t[2], r["old_ms"], r["new_ms"], r["arms"], r["compared"]])
	print("inserter_loop_native_test: %s (%d passed, %d failed)" % ["PASS" if fails == 0 else "FAIL", passes, fails])
	quit(1 if fails > 0 else 0)


func _scenario(with_events: bool, tpf: int, count: int, seed_v: int, compare: bool) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
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
	var hands: Array = []
	var recs := {}
	var cols := 40
	for n in count:
		var h := Hand.new()
		h.unit = 1000 + n
		var ki := n % KINDS.size()
		var dir: int = [0, 4, 8, 12][rng.randi() % 4]
		h.base = Vector2(float(n % cols) * 3.0 + 0.5, float(n / cols) * 4.0 + 0.5)
		var x: Dictionary = eprops[ki + 1]["x"]
		h.pick = Vector2(0.0, float(x["ip"][1])).rotated(-Wire.direction_yaw(dir))
		h.drop = Vector2(0.0, float(x["id"][1])).rotated(-Wire.direction_yaw(dir))
		h.omega = KINDS[ki][1]
		h.v = KINDS[ki][2]
		h.angle = h.pick.angle()
		h.reach = h.pick.length()
		h.wait = rng.randi_range(0, 30)
		h.idle = rng.randf() < 0.25
		h.kind = rng.randi_range(1, 6)
		h.cap = rng.randi_range(2, 6) if ki >= 3 else 1
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
		recs[h.unit] = r
		if not world.chunks.has(r.chunk):
			world.chunks[r.chunk] = Chunk.new()
		(world.chunks[r.chunk] as Chunk).entities[h.unit] = r
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
	Arms.handoff = with_events
	Arms.events = with_events
	Arms.events_items = with_events
	Arms.rest_arms = false
	Arms.native_pose = true
	for li in 2:
		(layers[li] as Node)._pose_native()
	var old: Node3D = layers[0]
	var new: Node3D = layers[1]
	var anim_old := StubAnim.new()
	var anim_new := StubAnim.new()
	var tick := 0
	var pending: Array = []
	var old_us := 0
	var new_us := 0
	var live_frames := 0
	var compared := 0
	var mined := {}  # unit -> frame it comes back
	var gen0: int = ModelLibrary.generation
	for f in FRAMES:
		old.frame = f
		new.frame = f
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
					var msg := {"t": "ie", "k": tick, "n": 6, "p": 2, "part": 1, "parts": 1, "l": l}
					for li in 2:
						(layers[li] as Node).handle_events(msg.duplicate(true))
			if tick % 6 == 3:
				var l: Array = []
				for h: Hand in hands:
					if tick < h.start or tick >= h.stop or rng.randf() < LOSE:
						continue
					var hand := h.base + Vector2(cos(h.angle), sin(h.angle)) * h.reach
					l.append_array([h.unit, roundi(hand.x * 256.0), roundi(hand.y * 256.0), h.item])
				var msg := {"t": "ih", "k": tick, "p": 6, "part": 1, "parts": 1, "l": l}
				for li in 2:
					(layers[li] as Node).handle(msg.duplicate(true))
		belts.tick = float(tick) - BEHIND
		# A chunk behind the view for a while; arms mined and put back turned; the models' generation changed once.
		if f == 150:
			world.behind_cull.hide[Vector2i(0, 0)] = true
		if f == 260:
			world.behind_cull.hide.clear()
		if f % 37 == 5:
			var u: int = 1000 + rng.randi_range(0, count - 1)
			if world.entities.has(u):
				world.entities.erase(u)
				mined[u] = f + rng.randi_range(3, 30)
		for u: int in mined.keys():
			if f >= int(mined[u]):
				var r: Rec = recs[u]
				var r2 := Rec.new()
				r2.unit = r.unit
				r2.pos = r.pos
				r2.proto_id = r.proto_id
				r2.dir = (r.dir + 4) % 16
				r2.chunk = r.chunk
				world.entities[u] = r2
				recs[u] = r2
				mined.erase(u)
		if f == 400:
			ModelLibrary.generation = gen0 + 1
		# Hands meeting belt items: a take a few ticks ahead, the item still on the belt (position_of), or a put.
		var meet_hands: Array = []
		if with_events:
			for i in 6:
				var h: Hand = hands[rng.randi_range(0, hands.size() - 1)]
				var why := BeltSimConst.HAND_TAKEN if rng.randf() < 0.6 else BeltSimConst.HAND_PUT
				var at := h.base + (h.pick if why == BeltSimConst.HAND_TAKEN else h.drop)
				var uid := 50000 + f * 10 + i
				belts.where[uid] = Vector3(at.x + 0.1, 0.2, at.y - 0.1)
				meet_hands.append([why, h.unit, belts.tick + rng.randf_range(0.0, 5.0), uid, at.x, at.y])
		for li in 2:
			# (Each layer's own copy of the meets, and its own animator.)
			belts.hands = meet_hands.duplicate(true)
			world.animator = anim_old if li == 0 else anim_new
			Arms.native_loop = li == 1  # (a static: the layer's switch for its own frame)
			var t0 := Time.get_ticks_usec()
			(layers[li] as Node)._process(1.0 / 60.0 * tpf)
			var took := Time.get_ticks_usec() - t0
			if li == 0:
				old_us += took
			else:
				new_us += took
		live_frames += old._scratch_live.size()
		if f == 0:
			check(new._pn != null and old._pn != null, "both layers have InserterPoseNative")
		if f == FRAMES - 1:
			check(new.loop_frames > FRAMES / 2 and old.loop_frames == 0, "the switched-on layer ran the native loop (%d frames), the other none (%d)" % [
				new.loop_frames, old.loop_frames])
		if compare:
			compared += _compare(f, old, new, anim_old, anim_new)
	ModelLibrary.generation = gen0
	Arms.native_loop = true
	check(shown == 0, "%s, %d tick(s) a frame: every frame equal with the native loop (%d arm-frames)" % [
		"events" if with_events else "samples", tpf, compared])
	if compare:
		check(compared > FRAMES * 50, "%s, %d tick(s) a frame: arms were drawn (%d)" % ["events" if with_events else "samples", tpf, compared])
	_check_loop_chunks(new, "%s, %d tick(s) a frame" % ["events" if with_events else "samples", tpf])
	var out := {"old_ms": old_us / 1000.0 / FRAMES, "new_ms": new_us / 1000.0 / FRAMES, "arms": live_frames / FRAMES, "compared": compared}
	shown = 0
	for n: Node in [old, new, belts, world]:
		root.remove_child(n)
		n.free()
	Arms.native_pose = true
	Arms.rest_arms = true
	return out


## (perf-w3-fix B1) The native layer's _loop_chunks holds exactly the chunks its bound arms stand in now, with
## their counts, and shrinks as arms are dropped: empty once every arm is.
func _check_loop_chunks(a: Node, what: String) -> void:
	var want := {}
	for unit: int in a._arms:
		var arm = a._arms[unit]
		if arm.loop_in:
			want[arm.loop_chunk] = int(want.get(arm.loop_chunk, 0)) + 1
			if arm.loop_chunk != arm.chunk:
				check(false, "%s: arm %d counted under chunk %s, stands in %s" % [what, unit, arm.loop_chunk, arm.chunk])
				return
	check(not want.is_empty() and want == a._loop_chunks, "%s: _loop_chunks matches the bound arms' chunks (%d chunks)" % [
		what, a._loop_chunks.size()])
	var units: Array = a._arms.keys()
	if units.is_empty():
		return
	var first: Vector2i = a._arms[units[0]].chunk
	for unit: int in units:
		if a._arms[unit].chunk == first:
			a._drop_arm(unit)
	check(not a._loop_chunks.has(first), "%s: a chunk whose arms all went leaves _loop_chunks" % what)
	for unit: int in a._arms.keys():
		a._drop_arm(unit)
	check(a._loop_chunks.is_empty(), "%s: _loop_chunks empty once every arm is dropped (%d left)" % [what, a._loop_chunks.size()])


## One frame's comparison of the two layers (`old` the GDScript loop, `new` the native one); the arms compared.
func _compare(f: int, old: Node3D, new: Node3D, anim_old: StubAnim, anim_new: StubAnim) -> int:
	new.sync_arms()
	var n := 0
	if old._arms.size() != new._arms.size():
		_show("frame %d: %d arms, native loop %d" % [f, old._arms.size(), new._arms.size()])
		return 0
	for unit in old._arms:
		var ao = old._arms[unit]
		var an = new._arms.get(unit)
		if an == null:
			_show("frame %d: arm %d only in the GDScript layer" % [f, unit])
			continue
		n += 1
		if absf(angle_difference(ao.angle, an.angle)) > TOL or absf(ao.reach - an.reach) > TOL or ao.item_id != an.item_id \
				or ao.item_count != an.item_count or absf(ao.close - an.close) > TOL or ao.grabs != an.grabs or ao.mode != an.mode:
			_show("frame %d arm %d: GDScript (%.5f, %.5f, %d x%d, close %.3f, grabs %d, mode %d), native (%.5f, %.5f, %d x%d, close %.3f, grabs %d, mode %d)" % [
				f, unit, ao.angle, ao.reach, ao.item_id, ao.item_count, ao.close, ao.grabs, ao.mode, an.angle, an.reach, an.item_id, an.item_count, an.close, an.grabs, an.mode])
	# The live set: the GDScript loop's (this frame's `live`) and the one the native loop keeps.
	var live_old: Dictionary = old._scratch_live
	var live_new: Dictionary = new._rest_live if new._loop_was else new._scratch_live
	if live_old.size() != live_new.size():
		_show("frame %d: live %d, native loop %d" % [f, live_old.size(), live_new.size()])
	else:
		for u in live_old:
			if live_new.get(u) != live_old[u]:
				_show("frame %d: arm %d live in chunk %s, native loop %s" % [f, u, live_old[u], live_new.get(u)])
				break
	if anim_old.arm_working.size() != anim_new.arm_working.size():
		_show("frame %d: %d hands moving, native loop %d" % [f, anim_old.arm_working.size(), anim_new.arm_working.size()])
	else:
		for u in anim_old.arm_working:
			if not anim_new.arm_working.has(u):
				_show("frame %d: hand %d moving, not with the native loop" % [f, u])
				break
	if old.steered != new.steered:
		_show("frame %d: %d steered, native loop %d" % [f, old.steered, new.steered])
	# Held items: per kind, each held item's place and turn.
	var ho: Dictionary = old._scratch_held
	var hn: Dictionary = new._scratch_held
	if ho.size() != hn.size():
		_show("frame %d: %d held kinds, native loop %d" % [f, ho.size(), hn.size()])
	else:
		for key in ho:
			if not hn.has(key):
				_show("frame %d: held kind %s missing with the native loop" % [f, key])
				break
			var a := _held_rows(ho[key], old._scratch_held_yaws[key])
			var b := _held_rows(hn[key], new._scratch_held_yaws[key])
			if _rows_diff(a, b) > TOL:
				_show("frame %d: held kind %s: %d items, native loop %d, max diff %s" % [f, key, a.size(), b.size(), _rows_diff(a, b)])
				break
	# Every MultiMesh: its count and its instances, sorted.
	var pairs: Array = []
	for i in old._parts.size():
		pairs.append(["basic %d" % i, old._parts[i], new._parts[i], 16])
	for key in old._sprite_mmis:
		for i in (old._sprite_mmis[key] as Array).size():
			pairs.append(["sprite %s %d" % [key, i], old._sprite_mmis[key][i], new._sprite_mmis.get(key, [null, null, null])[i], 12])
	for key in old._model_parts:
		if old._model_parts[key] == null:
			continue
		for i in (old._model_parts[key] as Array).size():
			pairs.append(["model %s %d" % [key, i], old._model_parts[key][i], new._model_parts.get(key, [null, null, null])[i], 12])
	for key in old._rigs:
		if not (old._rigs[key] is Dictionary):
			continue
		var mo: Array = old._rigs[key]["mmis"]
		var mn: Array = new._rigs[key]["mmis"] if new._rigs.has(key) else []
		for i in mo.size():
			pairs.append(["rig %s %d" % [key, i], mo[i], mn[i] if i < mn.size() else null, 12])
	for p: Array in pairs:
		if p[2] == null:
			_show("frame %d: %s missing with the native loop" % [f, p[0]])
			continue
		var mo: MultiMesh = (p[1] as MultiMeshInstance3D).multimesh
		var mn: MultiMesh = (p[2] as MultiMeshInstance3D).multimesh
		if mo.visible_instance_count != mn.visible_instance_count:
			_show("frame %d: %s: %d instances, native loop %d" % [f, p[0], mo.visible_instance_count, mn.visible_instance_count])
			continue
		var d := _rows_diff(_rows(mo, p[3]), _rows(mn, p[3]))
		if d > TOL:
			_show("frame %d: %s: instances differ by %s" % [f, p[0], d])
	return n


func _rows(mm: MultiMesh, stride: int) -> Array:
	var buf := mm.buffer
	var out: Array = []
	for i in mm.visible_instance_count:
		out.append(buf.slice(i * stride, i * stride + stride))
	out.sort_custom(_less)
	return out


func _held_rows(places: Array, yaws: Array) -> Array:
	var out: Array = []
	for i in places.size():
		var p: Vector3 = places[i]
		out.append(PackedFloat32Array([p.x, p.y, p.z, float(yaws[i])]))
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
	if shown <= 10:
		print("DIFF: " + msg)


## One game tick of a hand (inserter_pose_native_test's); its events into `made`.
func _step(h: Hand, tick: int, made: Array, rng: RandomNumberGenerator) -> void:
	var hand := h.base + Vector2(cos(h.angle), sin(h.angle)) * h.reach
	var hx := roundi(hand.x * 256.0)
	var hy := roundi(hand.y * 256.0)
	if (tick + h.unit) % 120 == 0:
		made.append_array([Swing.Ev.SYNC, h.unit, tick, h.count, h.item, 0, hx, hy, 0])
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
