extends SceneTree
## Verifies that inserters holding more than one item stack up to MAX_HELD_STACK (4) items vertically in
## their hand (pile_step + ItemCards.PILE_TURN), across GDScript pose, native pose, native loop, and
## events-driven modes, plus the --inserter-hand-stack=off switch and samples-only fallback.
## Run: godot --headless --audio-driver Dummy --path client --log-file <abs> --script res://tests/inserter_hand_stack_test.gd

const Arms := preload("res://scripts/world/inserter_arms.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const Swing := preload("res://scripts/world/inserter_swing.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")

var passes := 0
var fails := 0


class Rec:
	var unit := 0
	var pos := Vector2.ZERO
	var proto_id := 1
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
	var t := -1.0

	func drawn_tick() -> float:
		return t

	func item_height() -> float:
		return 0.27


func check(cond: bool, msg: String) -> void:
	if cond:
		passes += 1
	else:
		fails += 1
		print("FAIL: %s" % msg)


func _init() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	NativeLibrary.ensure()
	var ld = ModelLibrary.Load.new()
	ld.path = ProjectSettings.globalize_path("res://tests/fixtures/rig_inserter.glb")
	ld.rig_wanted = true
	ld.run()
	if ld.rig.is_empty():
		check(false, "test rig loaded")
		_finish()
		return
	var rig: Dictionary = ModelLibrary._commit_rig(ld.rig, "test-inserter")
	var protos := ProtoDB.new()
	var p := ProtoDB.EntityProto.new()
	p.id = 1
	p.name = "test-inserter"
	p.type = "inserter"
	protos.entities[1] = p
	protos.entities_by_name["test-inserter"] = p

	var has_pose: bool = ClassDB.class_exists("InserterPoseNative")
	var has_loop: bool = has_pose and ClassDB.class_exists("InserterArmsNative") and bool(ClassDB.instantiate("InserterPoseNative").has_method("frame_draw"))

	var modes: Array = [["gd_items", false, false, true]]
	if has_pose:
		modes.append(["native_pose", true, false, true])
	if has_loop:
		modes.append(["native_loop", true, true, true])
	modes.append(["events_on", false, false, false])

	for m: Array in modes:
		_test_stacking_mode(m[0], m[1], m[2], m[3], true, protos, rig)

	_test_stacking_mode("switch_off", has_pose, has_loop, true, false, protos, rig)
	_test_samples_only(protos, rig)
	_finish()


func _finish() -> void:
	Arms.native_pose = true
	Arms.native_loop = true
	Arms.events = true
	Arms.events_items = true
	Arms.handoff = true
	Arms.hand_stack = true
	Arms.belt_clock = true
	Arms.rest_arms = true
	print("inserter_hand_stack_test: %s (%d passed, %d failed)" % ["PASS" if fails == 0 else "FAIL", passes, fails])
	quit(1 if fails > 0 else 0)


func _make_world(units: Array) -> StubWorld:
	var world := StubWorld.new()
	var cv := Chunk.new()
	world.chunks[Vector2i.ZERO] = cv
	for i in units.size():
		var u: int = units[i]
		var rec := Rec.new()
		rec.unit = u
		rec.pos = Vector2(10.5 + float(i) * 4.0, 20.5)
		rec.proto_id = 1
		world.entities[u] = rec
		cv.entities[u] = rec
	return world


func _read_instances(arms: Node, item_id: int) -> Array:
	var mmi: MultiMeshInstance3D = arms._cards._kinds.get(item_id)
	var n: int = mmi.multimesh.visible_instance_count if mmi != null else 0
	var out: Array = []
	if n == 0:
		return out
	var buf: PackedFloat32Array = arms._cards._buffers.get(item_id, PackedFloat32Array())
	for i in n:
		var o := i * ItemCards.STRIDE
		if o + 11 >= buf.size():
			break
		var pos := Vector3(buf[o + 3], buf[o + 7], buf[o + 11])
		var yaw := atan2(buf[o + 2], buf[o])
		out.append([pos, yaw])
	return out


func _test_stacking_mode(label: String, use_pose: bool, use_loop: bool, use_items_mode: bool, stack_on: bool,
		protos: ProtoDB, rig: Dictionary) -> void:
	Arms.belt_clock = true
	Arms.handoff = true
	Arms.events = true
	Arms.events_items = use_items_mode
	Arms.native_pose = use_pose
	Arms.native_loop = use_loop
	Arms.rest_arms = false
	Arms.hand_stack = stack_on

	var world := _make_world([77, 78])
	var belts := StubBelts.new()
	var arms := Arms.new()
	arms.protos = protos
	arms.world = world
	arms.belts = belts
	arms.eprops = {1: {"x": {"ip": [0, -1], "id": [0, 1.2], "rs": 0.014, "es": 0.035}}}
	arms._rigs["test-inserter"] = rig
	if use_pose:
		arms._pose_native()

	var p77: Vector2 = (world.entities[77].pos + Vector2(0.0, -1.0)) * 256.0
	var d77: Vector2 = (world.entities[77].pos + Vector2(0.0, 1.2)) * 256.0
	var p78: Vector2 = (world.entities[78].pos + Vector2(0.0, -1.0)) * 256.0
	var d78: Vector2 = (world.entities[78].pos + Vector2(0.0, 1.2)) * 256.0

	# Arm 77: incremental pickup 1 -> 2 -> 3 -> 4 (item 5), swing, incremental drop 3 -> 1 -> 0.
	# Arm 78: picks up 12 (item 6, capped at 4), drops at 160 with uncertain window c = 4 (ticks 156..160).
	var evs: Array = [
		[Swing.Ev.SYNC, 77, 100, 0, 0, 0, roundi(p77.x), roundi(p77.y), 0],
		[Swing.Ev.PICKED, 77, 110, 1, 5, 0, roundi(p77.x), roundi(p77.y), 0],
		[Swing.Ev.PICKED, 77, 112, 2, 5, 0, roundi(p77.x), roundi(p77.y), 0],
		[Swing.Ev.PICKED, 77, 114, 3, 5, 0, roundi(p77.x), roundi(p77.y), 0],
		[Swing.Ev.PICKED, 77, 116, 4, 5, 0, roundi(p77.x), roundi(p77.y), 0],
		[Swing.Ev.DROPPED, 77, 150, 3, 5, 0, roundi(d77.x), roundi(d77.y), 0],
		[Swing.Ev.DROPPED, 77, 152, 1, 5, 0, roundi(d77.x), roundi(d77.y), 0],
		[Swing.Ev.DROPPED, 77, 154, 0, 5, 0, roundi(d77.x), roundi(d77.y), 0],
		[Swing.Ev.SYNC, 78, 100, 0, 0, 0, roundi(p78.x), roundi(p78.y), 0],
		[Swing.Ev.PICKED, 78, 110, 12, 6, 0, roundi(p78.x), roundi(p78.y), 0],
		[Swing.Ev.DROPPED, 78, 160, 0, 6, 4, roundi(d78.x), roundi(d78.y), 0],
	]
	var flat_ev: Array = []
	for e: Array in evs:
		flat_ev.append_array(e)
	arms.handle_events({"t": "ie", "k": 165, "n": 6, "p": 2, "part": 1, "parts": 1, "l": flat_ev})

	# Provide ih samples covering the timeline (for sample-pose modes).
	for k in range(99, 172, 6):
		var i77 := 5 if (k >= 110 and k < 154) else 0
		var pos77 := p77 if k < 118 else (d77 if k >= 148 else (p77 + d77) * 0.5 + Vector2(128.0, 0.0))
		var i78 := 6 if (k >= 110 and k < 160) else 0
		var pos78 := p78 if k < 112 else (d78 if k >= 150 else (p78 + d78) * 0.5 + Vector2(128.0, 0.0))
		arms.handle({"t": "ih", "k": k, "p": 6, "part": 1, "parts": 1, "l": [
			77, roundi(pos77.x), roundi(pos77.y), i77,
			78, roundi(pos78.x), roundi(pos78.y), i78,
		]})

	var want77 := {
		105: 0,
		110: 1, 111: 1,
		112: 2 if stack_on else 1, 113: 2 if stack_on else 1,
		114: 3 if stack_on else 1, 115: 3 if stack_on else 1,
		116: 4 if stack_on else 1, 130: 4 if stack_on else 1, 149: 4 if stack_on else 1,
		150: 3 if stack_on else 1, 151: 3 if stack_on else 1,
		152: 1, 153: 1,
		154: 0, 162: 0,
	}
	var counts_ok := true
	var geom_ok := true
	var cap_ok := true
	var unc_ok := true
	var bad_msg := ""

	for t in range(104, 165):
		belts.t = float(t)
		arms._process(1.0 / 60.0)
		arms.sync_arms()
		var inst77 := _read_instances(arms, 5)
		var inst78 := _read_instances(arms, 6)
		if want77.has(t):
			if inst77.size() != int(want77[t]):
				counts_ok = false
				bad_msg = "tick %d: got %d, want %d" % [t, inst77.size(), int(want77[t])]
				break
		if stack_on and t == 130 and inst77.size() == 4:
			var step: float = arms._cards.pile_step(5)
			var p0: Vector3 = inst77[0][0]
			var y0: float = inst77[0][1]
			for c in range(1, 4):
				var pc: Vector3 = inst77[c][0]
				var yc: float = inst77[c][1]
				if not is_equal_approx(pc.x, p0.x) or not is_equal_approx(pc.z, p0.z) \
						or absf(pc.y - (p0.y + step * float(c))) > 0.001 \
						or absf(angle_difference(yc, y0 + ItemCards.PILE_TURN * float(c))) > 0.001:
					geom_ok = false
					bad_msg = "copy %d pos=%s yaw=%.4f vs base pos=%s yaw=%.4f step=%.4f" % [c, pc, yc, p0, y0, step]
					break
		if t == 130:
			var want78 := 4 if stack_on else 1
			if inst78.size() != want78:
				cap_ok = false
				bad_msg = "tick 130 cap: got %d, want %d" % [inst78.size(), want78]
		if stack_on and t == 157:
			# Uncertain drop window (156..160): must still show the 4-item stack, not flicker to 1.
			if inst78.size() != 4:
				unc_ok = false
				bad_msg = "tick 157 uncertain: got %d, want 4" % inst78.size()

	check(counts_ok, "%s: incremental pick/drop stack counts match (%s)" % [label, bad_msg])
	if stack_on:
		check(geom_ok, "%s: stacked copies step by pile_step and PILE_TURN (%s)" % [label, bad_msg])
		check(unc_ok, "%s: uncertain drop window keeps full hand stack (%s)" % [label, bad_msg])
	check(cap_ok, "%s: hand count 12 caps at %d (%s)" % [label, 4 if stack_on else 1, bad_msg])

	for c in arms._cards.get_children():
		c.free()
	arms._cards.free()
	arms.free()
	belts.free()
	world.free()


func _test_samples_only(protos: ProtoDB, rig: Dictionary) -> void:
	Arms.belt_clock = true
	Arms.handoff = false
	Arms.events = false
	Arms.events_items = false
	Arms.native_pose = ClassDB.class_exists("InserterPoseNative")
	Arms.native_loop = false
	Arms.rest_arms = false
	Arms.hand_stack = true

	var world := _make_world([79])
	var belts := StubBelts.new()
	var arms := Arms.new()
	arms.protos = protos
	arms.world = world
	arms.belts = belts
	arms.eprops = {1: {"x": {"ip": [0, -1], "id": [0, 1.2], "rs": 0.014, "es": 0.035}}}
	arms._rigs["test-inserter"] = rig
	if Arms.native_pose:
		arms._pose_native()

	var p79: Vector2 = (world.entities[79].pos + Vector2(0.0, -1.0)) * 256.0
	var d79: Vector2 = (world.entities[79].pos + Vector2(0.0, 1.2)) * 256.0
	arms.handle({"t": "ih", "k": 100, "p": 6, "part": 1, "parts": 1, "l": [79, roundi(p79.x), roundi(p79.y), 5]})
	arms.handle({"t": "ih", "k": 106, "p": 6, "part": 1, "parts": 1, "l": [79, roundi(d79.x), roundi(d79.y), 5]})
	belts.t = 103.0
	arms._process(1.0 / 60.0)
	var inst := _read_instances(arms, 5)
	check(inst.size() == 1 and arms._arms[79].item_count == 1, "samples-only ih draws 1 item cleanly (got %d)" % inst.size())

	for c in arms._cards.get_children():
		c.free()
	arms._cards.free()
	arms.free()
	belts.free()
	world.free()
