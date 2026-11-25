extends Node
## Regression and integration tests for megabase priority queues and main-thread CPU optimizations.

const BridgeScript := preload("res://scripts/net/bridge.gd")
const FrameBudget := preload("res://scripts/world/frame_budget.gd")
const WorldMirror := preload("res://scripts/world/world.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")
const QualityMarksScript := preload("res://scripts/world/quality_marks.gd")
const InserterArmsScript := preload("res://scripts/world/inserter_arms.gd")
const MoversScript := preload("res://scripts/world/movers.gd")
const FluidsPowerScript := preload("res://scripts/world/fluids_power.gd")
const AltOverlayScript := preload("res://scripts/ui/factorio/alt_overlay.gd")
const FxScript := preload("res://scripts/fx/fx.gd")

var passes := 0
var fails := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		passes += 1
	else:
		fails += 1
		print("FAIL: %s" % msg)


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_bridge_priority_queue()
	_test_quality_marks_cache()
	_test_inserter_arms_chunked()
	_test_movers_node_pick()
	await _test_fluids_power_dirty_filter()
	_test_alt_overlay_cull_and_batch()
	_test_fx_track_filter()
	await get_tree().process_frame
	print("megabase_prio_test: %d passed, %d failed" % [passes, fails])
	print("FAILS: %d" % fails)
	get_tree().quit(1 if fails > 0 else 0)


func _test_bridge_priority_queue() -> void:
	var b := BridgeScript.new()
	add_child(b)
	b.priority_queue = true
	b.connected = true
	b.world_ready = true
	b._seq_connected = true
	b._seq_world_ready = true
	b._expected_r = 1

	var delivered := []
	var delayed_chunk := false
	var on_msg := func(m: Dictionary) -> void:
		var t := str(m.get("t", ""))
		var unit := 0
		var e: Variant = m.get("e")
		if e is Array:
			var arr: Array = e
			if not arr.is_empty():
				unit = int(arr[0])
		delivered.append([t, unit, int(m.get("cx", -1))])
		if t == "chunk" and not delayed_chunk:
			delayed_chunk = true
			OS.delay_usec(12000)
	b.message_received.connect(on_msg)

	var msgs: Array = []
	for i in 500:
		msgs.append({"t": "chunk", "r": i + 1, "cx": i % 5, "cy": 0})
	msgs.append({"t": "add", "r": 501, "e": [9001, 1, 128, 128, 0]})
	msgs.append({"t": "add", "r": 502, "e": [9002, 1, 9 * 32 * 256 + 128, 9 * 32 * 256 + 128, 0]})
	msgs.append({"t": "gui", "r": 503})
	msgs.append({"t": "me", "k": 100})

	b._route(msgs, PackedInt32Array(), Time.get_ticks_usec())
	check(int(b.stats.get("gaps", 0)) == 0, "bridge prio: sequential arrivals record 0 gaps")
	check(b._me_waiting.size() == 1 and b._prio_waiting.size() == 2 and b._waiting.size() == 501,
		"bridge prio: routes me=%d prio=%d bulk=%d (same-chunk add stays in bulk behind chunk 0,0)"
		% [b._me_waiting.size(), b._prio_waiting.size(), b._waiting.size()])
	check(b._chunk_waiting.has(Vector2i(0, 0)), "bridge prio: tracks pending chunks per coordinate")

	# Drain once: P1 (me), P2 (far add + gui) drain first; bulk stops early once FrameBudget expires.
	b._drain()
	var frame1_count := delivered.size()
	var first_t: String = str((delivered[0] as Array)[0]) if frame1_count > 0 else ""
	var second_t: String = str((delivered[1] as Array)[0]) if frame1_count > 1 else ""
	var second_unit: int = int((delivered[1] as Array)[1]) if frame1_count > 1 else 0
	var third_t: String = str((delivered[2] as Array)[0]) if frame1_count > 2 else ""
	var add_9001_early := false
	for item in delivered:
		var row: Array = item
		if str(row[0]) == "add" and int(row[1]) == 9001:
			add_9001_early = true
	check(first_t == "me" and second_t == "add" and second_unit == 9002 and third_t == "gui",
		"bridge prio: me and P2 actions/far delta jump 500-msg backlog (%s)" % [delivered.slice(0, 4)])
	check(frame1_count < 504 and not add_9001_early,
		"bridge prio: bulk drains incrementally (%d/504) and same-chunk add waits (%s)"
		% [frame1_count, add_9001_early])

	var safety := 0
	while b.waiting_count() > 0 and safety < 1000:
		b._drain()
		safety += 1
	check(delivered.size() == 504 and int(b.stats.get("gaps", 0)) == 0 and b.waiting_count() == 0,
		"bridge prio: full drain finishes all 504 msgs with 0 gaps (got %d, waiting %d)"
		% [delivered.size(), b.waiting_count()])

	# Verify requeue_front prepends via _replay_head in exact order.
	var replay_order := []
	var on_replay := func(m: Dictionary) -> void:
		replay_order.append(int(m.get("id", -1)))
	b.requeue_front([[on_replay, {"id": 1}], [on_replay, {"id": 2}], [on_replay, {"id": 3}]])
	b.requeue_front([[on_replay, {"id": 0}]])
	check(b._replay_head.size() == 4, "bridge prio: requeue_front prepends in O(head) (%d)" % b._replay_head.size())
	b._drain()
	check(replay_order == [0, 1, 2, 3] and b._replay_head.is_empty(),
		"bridge prio: _replay_head drains in exact prepended order %s" % [replay_order])

	b.queue_free()


func _test_quality_marks_cache() -> void:
	var prev_cache: bool = QualityMarksScript.static_cache
	QualityMarksScript.static_cache = true

	var w := WorldMirror.new()
	add_child(w)
	w.chunks[Vector2i(0, 0)] = ChunkView.new()
	w.chunks[Vector2i(1, 0)] = ChunkView.new()
	w._add([701, 8, 5 * 256, 5 * 256, 0, {"q": "rare"}])
	w._add([702, 8, 40 * 256, 5 * 256, 0, {"q": "rare"}])

	var model_gs := GDScript.new()
	model_gs.source_code = "extends Node\nvar belt_quality := {}\n"
	model_gs.reload()
	var fake_model: Node = model_gs.new()

	var qm := QualityMarksScript.new()
	qm.world = w
	qm.model = fake_model
	add_child(qm)

	qm.alt_mode = true
	qm._process(0.0)
	var rare_mmi: MultiMeshInstance3D = qm._layers.get("rare")
	check(qm.entity_uploads == 1 and rare_mmi != null and rare_mmi.multimesh.visible_instance_count == 2,
		"quality_marks: initial upload counts 2 rare entities (uploads=%d)" % qm.entity_uploads)

	for _f in 5:
		qm._process(0.0)
	check(qm.entity_uploads == 1,
		"quality_marks: steady idle frames skip static entity re-upload (uploads=%d)" % qm.entity_uploads)

	qm.alt_mode = false
	qm._process(0.0)
	var hidden_count: int = rare_mmi.multimesh.visible_instance_count if rare_mmi != null else -1
	qm.alt_mode = true
	qm._process(0.0)
	var restored_count: int = rare_mmi.multimesh.visible_instance_count if rare_mmi != null else -1
	check(hidden_count == 0 and restored_count == 2 and qm.entity_uploads == 1,
		"quality_marks: alt_mode toggle hides (%d) and restores (%d) without re-uploading (uploads=%d)"
		% [hidden_count, restored_count, qm.entity_uploads])

	qm._dirty_chunks[Vector2i(0, 0)] = true
	qm._process(0.0)
	check(qm.entity_uploads == 2,
		"quality_marks: dirtying one chunk re-uploads once (uploads=%d)" % qm.entity_uploads)

	QualityMarksScript.static_cache = prev_cache
	qm.queue_free()
	fake_model.free()
	w.queue_free()


func _test_inserter_arms_chunked() -> void:
	var prev_rest: bool = InserterArmsScript.rest_arms
	var prev_chunked: bool = InserterArmsScript.rest_arms_chunked
	InserterArmsScript.rest_arms = true
	InserterArmsScript.rest_arms_chunked = true

	var w := WorldMirror.new()
	add_child(w)
	w.protos.add_entities([[1, "test-arm", "inserter", -0.4, -0.4, 0.4, 0.4, 100, 100, 100, 1, 1]])
	w.chunks[Vector2i(0, 0)] = ChunkView.new()
	w.chunks[Vector2i(1, 0)] = ChunkView.new()
	w._add([101, 1, 10 * 256 + 128, 20 * 256 + 128, 0])
	w._add([102, 1, 42 * 256 + 128, 20 * 256 + 128, 4])

	var arms := InserterArmsScript.new()
	arms.world = w
	arms.protos = w.protos
	arms.eprops = {1: {"x": {"ip": [0, -1], "id": [0, 1.2], "rs": 0.014, "es": 0.035}}}
	arms._rigs["test-arm"] = {}
	add_child(arms)

	arms._process(1.0 / 60.0)
	check(arms.rest_count == 2 and arms.rest_buffer.size() == 2 * 3 * 16 and arms.rest_chunk_uploads == 2,
		"inserter_arms: initial chunked upload produces 2 rest arms (%d, buf=%d, uploads=%d)"
		% [arms.rest_count, arms.rest_buffer.size(), arms.rest_chunk_uploads])

	w._add([103, 1, 14 * 256 + 128, 20 * 256 + 128, 0])
	w.entities_changed.emit(Vector2i(0, 0))
	arms._process(1.0)
	check(arms.rest_chunk_uploads == 3 and arms.rest_count == 3 and arms.rest_buffer.size() == 3 * 3 * 16,
		"inserter_arms: dirtying chunk (0,0) uploads only 1 chunk (uploads=%d, count=%d)"
		% [arms.rest_chunk_uploads, arms.rest_count])

	arms._process(1.0)
	check(arms.rest_chunk_uploads == 3,
		"inserter_arms: idle frame triggers 0 chunk uploads (uploads=%d)" % arms.rest_chunk_uploads)

	InserterArmsScript.rest_arms = prev_rest
	InserterArmsScript.rest_arms_chunked = prev_chunked
	arms.queue_free()
	w.queue_free()


func _test_movers_node_pick() -> void:
	var prev_pick: bool = MoversScript.pick_node_movers
	MoversScript.pick_node_movers = true

	var w := WorldMirror.new()
	add_child(w)
	w.protos.add_entities([
		[1, "car", "car", -0.8, -1.0, 0.8, 1.0, 100, 100, 100, 2, 2],
		[2, "logistic-robot", "logistic-robot", -0.3, -0.3, 0.3, 0.3, 100, 100, 100, 1, 1],
	])
	var ml := MoversScript.new()
	ml.protos = w.protos
	add_child(ml)

	ml.handle({"t": "mv", "k": 100, "l": [
		[10, 1, 10 * 256, 10 * 256, 0],
		[11, 2, 12 * 256, 12 * 256, 0],
		[12, 2, 14 * 256, 14 * 256, 0],
	]})
	var car_m = ml._movers.get(10)
	if car_m != null:
		car_m.node.position = Vector3(10.0, 0.0, 10.0)
	for rid in [11, 12]:
		var rm = ml._movers.get(rid)
		if rm != null and rm.slot < 0:
			ml._to_record(rm, Vector4.ZERO, 0)

	var picked_car: Array = ml.pick(Vector2(10.0, 10.0), 3.0, ["car"])
	var ray_car: Array = ml.pick_ray(Vector3(10.0, 5.0, 10.0), Vector3(0.0, -1.0, 0.0), ["car"])
	var car_units: Array = ml.units_of_type("car")
	var robot_units: Array = ml.units_of_type("logistic-robot")

	check(ml._node_movers.has(10) and not ml._node_movers.has(11) and not ml._node_movers.has(12),
		"movers: car stays in _node_movers while GPU robots leave _node_movers")
	check(picked_car.size() >= 1 and int(picked_car[0]) == 10 and ray_car.size() >= 1 and int(ray_car[0]) == 10,
		"movers: pick and pick_ray hit node car cleanly (pick=%s, ray=%s)" % [picked_car, ray_car])
	check(car_units.size() == 1 and robot_units.size() == 2,
		"movers: units_of_type uses _node_movers for car (%d) and falls back for GPU robots (%d)"
		% [car_units.size(), robot_units.size()])

	MoversScript.pick_node_movers = prev_pick
	ml.queue_free()
	w.queue_free()


func _test_fluids_power_dirty_filter() -> void:
	var w := WorldMirror.new()
	add_child(w)
	w.protos.add_entities([
		[1, "storage-tank", "storage-tank", -1.5, -1.5, 1.5, 1.5, 100, 100, 100, 3, 3],
		[2, "assembling-machine-2", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3],
	])
	w.protos.fluid_colors["water"] = Color(0.2, 0.4, 1.0)
	w.chunks[Vector2i(0, 0)] = ChunkView.new()
	w.chunks[Vector2i(1, 0)] = ChunkView.new()
	w.chunks[Vector2i(5, 5)] = ChunkView.new()
	w._add([101, 1, 5 * 256, 5 * 256, 0])
	w._add([102, 2, 40 * 256, 5 * 256, 0])

	var fp := FluidsPowerScript.new()
	fp.world = w
	add_child(fp)
	await get_tree().process_frame
	fp.reset()
	fp._visuals_dirty = false
	fp._icons_dirty = false
	fp._windows_dirty = false

	fp.fluids = {101: [{"box": 0, "fluid": "water", "amount": 50, "capacity": 100, "temperature": 15}]}
	fp._windows_dirty = true
	fp.handle({"t": "pw", "k": 1, "part": 1, "parts": 1, "l": [102, 0]})
	fp._process(0.0)
	check(fp.window_rebuilds == 1 and fp.icon_rebuilds == 1,
		"fluids_power: initial rebuilds win=%d icon=%d" % [fp.window_rebuilds, fp.icon_rebuilds])

	w.entities_changed.emit(Vector2i(5, 5))
	fp.handle({"t": "ht", "k": 2, "part": 1, "parts": 1, "l": []})
	fp._process(0.0)
	check(fp.window_rebuilds == 1 and fp.icon_rebuilds == 1,
		"fluids_power: unrelated chunk change and heat update skip icon/window rebuilds (win=%d, icon=%d)"
		% [fp.window_rebuilds, fp.icon_rebuilds])

	w.entities_changed.emit(Vector2i(0, 0))
	fp._process(0.0)
	check(fp.window_rebuilds == 2 and fp.icon_rebuilds == 1,
		"fluids_power: chunk (0,0) edit rebuilds windows (%d) without touching icons (%d)"
		% [fp.window_rebuilds, fp.icon_rebuilds])

	fp.queue_free()
	w.queue_free()


func _test_alt_overlay_cull_and_batch() -> void:
	var prev_cap: int = AltOverlayScript.layer_cap
	var prev_batch: bool = AltOverlayScript.flat_batch_marks
	var prev_order: bool = AltOverlayScript.icon_order
	var prev_alt_contents: int = Bridge.alt_contents

	var holder := Node3D.new()
	add_child(holder)
	var w := WorldMirror.new()
	holder.add_child(w)
	w.protos.add_entities([
		[1, "storage-tank", "storage-tank", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3],
		[42, "lab", "lab", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3],
	])
	w.chunks[Vector2i(0, 0)] = ChunkView.new()
	w.chunks[Vector2i(20, 20)] = ChunkView.new()
	w._add([201, 1, 5 * 256, 5 * 256, 0])
	w._add([202, 1, 650 * 256, 650 * 256, 0])

	var fp := FluidsPowerScript.new()
	fp.name = "FluidsPower"
	fp.world = w
	holder.add_child(fp)
	fp.fluids = {
		201: [{"fluid": "water", "amount": 50, "capacity": 100}],
		202: [{"fluid": "water", "amount": 50, "capacity": 100}],
	}

	var stub_gs := GDScript.new()
	stub_gs.source_code = "extends Node3D\nvar world\nvar rig\nvar camera: Camera3D\nvar first_person := false\nvar hovered\nvar movers\nvar remote_fog\nvar eprops := {}\n"
	stub_gs.reload()

	var rig: Node3D = stub_gs.new()
	rig.camera = Camera3D.new()
	rig.add_child(rig.camera)
	holder.add_child(rig)
	rig.camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	rig.camera.position = Vector3(5, 8, 16)
	rig.camera.look_at(Vector3(5, 0, 5))

	var fake_player: Node3D = stub_gs.new()
	fake_player.world = w
	fake_player.rig = rig
	holder.add_child(fake_player)
	var fake_model: Node3D = stub_gs.new()
	fake_model.eprops = {42: {"x": {"isq": [["m", 0, 0.9, 0.5, 4, 2, 1.1, -0.1]]}}}
	holder.add_child(fake_model)

	var overlay := AltOverlayScript.new()
	overlay.model = fake_model
	overlay.player = fake_player
	overlay.on = true
	holder.add_child(overlay)

	AltOverlayScript.icon_order = true
	AltOverlayScript.flat_batch_marks = true
	overlay.collect()
	check(overlay.drawn == 1,
		"alt_overlay: frustum-culls off-screen fluid tank at (20,20), drawing %d in-view fluid" % overlay.drawn)

	# Add a lab with mixed-rarity quality marks and force _flat mode via layer_cap = 1.
	Bridge.set_alt_contents(true)
	w._add([210, 42, 5 * 256, 5 * 256, 0])
	w.handle({"t": "am", "g": Bridge.alt_contents, "l": [
		[210, [["speed-module", "rare"], ["productivity-module", "epic"], ["efficiency-module", "rare"]], []],
	]})
	AltOverlayScript.layer_cap = 1
	overlay._layers_key = []
	overlay.collect()
	var batched: Array = overlay.paint_list()
	var last_i := -1
	var first_m := 1000000
	var mark_tex_runs := 0
	var prev_mtex: Texture2D = null
	for idx in batched.size():
		var row: Array = batched[idx]
		var kind := str(row[0])
		if kind == "i":
			last_i = idx
		elif kind == "m":
			if idx < first_m:
				first_m = idx
			var mtex: Texture2D = row[1]
			if mtex != prev_mtex:
				mark_tex_runs += 1
				prev_mtex = mtex
	check(overlay._flat and last_i >= 0 and first_m < 1000000 and last_i < first_m and mark_tex_runs == 2,
		"alt_overlay: _flat batching emits all icons before marks (last_i=%d < first_m=%d) grouped by texture (runs=%d)"
		% [last_i, first_m, mark_tex_runs])

	AltOverlayScript.flat_batch_marks = false
	overlay._layers_key = []
	overlay.collect()
	var unbatched: Array = overlay.paint_list()
	var interleaved := false
	var last_i2 := -1
	var first_m2 := 1000000
	for idx in unbatched.size():
		var kind := str((unbatched[idx] as Array)[0])
		if kind == "i":
			last_i2 = idx
		elif kind == "m" and idx < first_m2:
			first_m2 = idx
	if first_m2 < last_i2:
		interleaved = true
	check(interleaved,
		"alt_overlay: --alt-flat-batch=off interleaves marks after each icon (first_m=%d < last_i=%d)"
		% [first_m2, last_i2])

	Bridge.set_alt_contents(false)
	if prev_alt_contents > 0:
		Bridge.set_alt_contents(true)
	AltOverlayScript.layer_cap = prev_cap
	AltOverlayScript.flat_batch_marks = prev_batch
	AltOverlayScript.icon_order = prev_order
	overlay.on = false
	holder.queue_free()


func _test_fx_track_filter() -> void:
	var w := WorldMirror.new()
	add_child(w)
	w.protos.add_entities([
		[1, "logistic-robot", "logistic-robot", -0.3, -0.3, 0.3, 0.3, 100, 100, 100, 1, 1],
		[2, "car", "car", -0.8, -1.0, 0.8, 1.0, 100, 100, 100, 2, 2],
		[3, "small-biter", "unit", -0.4, -0.4, 0.4, 0.4, 100, 100, 100, 1, 1],
	])
	var fx := FxScript.new()
	fx.world = w
	add_child(fx)

	fx.handle({"t": "mv", "k": 100, "l": [
		[1, 1, 10 * 256, 10 * 256],
		[2, 2, 12 * 256, 12 * 256],
		[3, 3, 14 * 256, 14 * 256],
	]})
	check(not fx._tracked.has(1) and fx._tracked.has(2) and fx._tracked.has(3),
		"fx._track: skips robots while keeping cars and biters (%s)" % [fx._tracked.keys()])

	fx.queue_free()
	w.queue_free()
