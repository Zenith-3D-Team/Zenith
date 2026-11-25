extends SceneTree
## Temporal motion vectors & FSR 2.2 belt reactive mask verification:
## Settings/BeltBlur toggles, MoverRecords.write_xform parity, RobotSwarm/Creatures MV mode +
## rollback, BeltMv sim + ping-pong lattice (including high-clock float32 ULP safety), shadow proxy
## preservation, ModelLibrary/ModelLods belt_reactive next_pass attachment & shader compilation.
##   godot --headless --audio-driver Dummy --path client -s res://tests/temporal_mv_test.gd

const Settings := preload("res://scripts/menu/settings.gd")
const BeltBlur := preload("res://scripts/world/belt_blur.gd")
const MoverRecords := preload("res://scripts/world/mover_records.gd")
const RobotSwarm := preload("res://scripts/world/robot_swarm.gd")
const Creatures := preload("res://scripts/world/creatures.gd")
const BeltMv := preload("res://scripts/world/belt_mv.gd")
const BeltItems := preload("res://scripts/world/belt_items.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const MaterialRows := preload("res://scripts/world/material_rows.gd")
const TestEnv := preload("res://tests/test_env.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _make_rgba_page(w: int, h: int, rows_data: Dictionary) -> Image:
	var floats := PackedFloat32Array()
	floats.resize(w * h * 4)
	for r_v in rows_data:
		var r := int(r_v)
		var vals: Array = rows_data[r_v]
		var bo := r * 16
		for i in mini(vals.size(), 16):
			floats[bo + i] = float(vals[i])
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBAF, floats.to_byte_array())


func _make_triangle_mesh(mat: Material) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-0.2, 0.1, -0.2),
		Vector3(0.2, 0.1, -0.2),
		Vector3(0.0, 0.1, 0.2),
	])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(0.5, 1.0)])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, mat)
	return mesh


func _test_settings_and_belt_blur() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(64, 64)
	root.add_child(vp)

	Settings.temporal_mv_override = -1
	Settings.belt_reactive_override = -1
	vp.use_taa = false
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	check(not Settings.temporal_aa_active(vp), "Settings: non-temporal AA leaves temporal_aa_active false")
	check(not Settings.belt_reactive_mask_active(vp), "Settings: non-FSR2 leaves belt_reactive_mask_active false")

	vp.use_taa = true
	check(Settings.temporal_aa_active(vp), "Settings: TAA enables temporal_aa_active")
	check(not Settings.belt_reactive_mask_active(vp), "Settings: TAA does not enable belt_reactive_mask_active")

	Settings.temporal_mv_override = 0
	check(not Settings.temporal_motion_vectors_enabled(), "Settings: temporal_mv_override=0 disables temporal_motion_vectors_enabled")
	check(not Settings.temporal_aa_active(vp), "Settings: temporal_mv_override=0 suppresses temporal_aa_active under TAA")

	Settings.temporal_mv_override = -1
	vp.use_taa = false
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	check(Settings.temporal_aa_active(vp), "Settings: FSR 2.2 enables temporal_aa_active")
	check(Settings.belt_reactive_mask_active(vp), "Settings: FSR 2.2 enables belt_reactive_mask_active")

	Settings.belt_reactive_override = 0
	check(not Settings.belt_reactive_mask_enabled(), "Settings: belt_reactive_override=0 disables belt_reactive_mask_enabled")
	check(not Settings.belt_reactive_mask_active(vp), "Settings: belt_reactive_override=0 suppresses belt_reactive_mask_active")

	var orig_taa := root.use_taa
	var orig_look_taa := Settings.look_taa
	var orig_scale := root.scaling_3d_mode
	Settings.look_taa = false
	Settings.belt_reactive_override = -1
	root.use_taa = false
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	check(root.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR2,
		"Viewport accepts SCALING_3D_MODE_FSR2 in test (got %d)" % int(root.scaling_3d_mode))
	check(not BeltBlur.sharp_now(), "BeltBlur: sharp_now() is false under FSR 2.2 when reactive mask is active")
	Settings.belt_reactive_override = 0
	check(BeltBlur.sharp_now(), "BeltBlur: sharp_now() is true under FSR 2.2 when reactive mask is disabled")
	Settings.belt_reactive_override = -1
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	Settings.look_taa = true
	root.use_taa = true
	check(BeltBlur.sharp_now(), "BeltBlur: sharp_now() stays true under TAA")

	Settings.look_taa = orig_look_taa
	root.use_taa = orig_taa
	root.scaling_3d_mode = orig_scale
	vp.queue_free()


func _assert_write_xform_matches(rec: MoverRecords, slot: int, label: String) -> void:
	var cl := rec.clocks()
	var c_even := MoverRecords._f32(cl.x)
	var c_odd := MoverRecords._f32(cl.y)
	var inv_rate := 1.0 / maxf(rec.rate, 1.0)
	var buf := PackedFloat32Array()
	buf.resize(16)
	rec.write_xform(slot, buf, 0, c_even, c_odd, inv_rate)
	var nat := MoverRecords.native()
	if nat != null:
		var nx: PackedFloat32Array = nat.xform_of(rec.data, slot, c_even, c_odd, inv_rate)
		var worst := 0.0
		for i in 12:
			worst = maxf(worst, absf(nx[i] - buf[i]))
		check(worst < 1e-6, "%s native xform matches write_xform (max diff %g)" % [label, worst])
	var st := rec.state(slot)
	var st_pos: Vector3 = st["pos"]
	var xf_pos := Vector3(buf[3], buf[7], buf[11])
	check(xf_pos.distance_to(st_pos) < 1e-4, "%s pos matches state(): %s vs %s" % [label, xf_pos, st_pos])
	var yaw := float(st["yaw"])
	check(absf(buf[0] - cos(yaw)) < 1e-4 and absf(buf[2] - sin(yaw)) < 1e-4,
		"%s cos/sin yaw matches state(): (%f,%f) vs (%f,%f)" % [label, buf[0], buf[2], cos(yaw), sin(yaw)])


func _test_mover_records_and_actors() -> void:
	var rec := MoverRecords.new()
	rec.frame(100.0, 60.0, 0.016)

	# 1. SIMULATED Leg 1 -> Leg 2 -> hover with blend residual
	var s_sim := rec.alloc()
	var f_sim := MoverRecords.ANIMATED | MoverRecords.SIMULATED | MoverRecords.CARGO | MoverRecords.SIM_NEXT_CARGO
	rec.write_sim(s_sim, Vector2(0.0, 0.0), Vector2(12.0, 0.0), Vector2(12.0, 12.0), Vector2(0.4, -0.2),
		90.0, 120.0, 150.0, f_sim, 3.0, 100.0, 0.2, 1.0, 0.5, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 6.0, 0.0, 0.4)
	_assert_write_xform_matches(rec, s_sim, "SIMULATED Leg 1")
	rec.frame(135.0, 60.0, 0.016)
	_assert_write_xform_matches(rec, s_sim, "SIMULATED Leg 2")
	rec.frame(165.0, 60.0, 0.016)
	_assert_write_xform_matches(rec, s_sim, "SIMULATED hover")

	# 2. SIM_ORBIT
	var s_orb := rec.alloc()
	rec.write_sim(s_orb, Vector2(20.0, 30.0), Vector2(20.0, 30.0), Vector2(20.0, 30.0), Vector2.ZERO,
		150.0, 200.0, 200.0, MoverRecords.ANIMATED | MoverRecords.SIMULATED | MoverRecords.SIM_ORBIT,
		3.0, 165.0, 0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 2.0, 0.05, 0.7, 6.0, 0.0, 0.1)
	_assert_write_xform_matches(rec, s_orb, "SIM_ORBIT")

	# 3. 4-point mover history (biter walking + ext)
	var s_walk := rec.alloc()
	var spots: Array[Vector3] = [
		Vector3(16.0, 0.0, 16.0),
		Vector3(17.0, 0.0, 16.5),
		Vector3(18.0, 0.0, 17.0),
		Vector3(19.0, 0.0, 17.5),
	]
	var ticks: Array[float] = [140.0, 148.0, 156.0, 164.0]
	rec.write(s_walk, spots, ticks, 0, 0.0, 2.0, 0.3, 165.0, 2.0, 2.0, 2.0, 8.0, 1.0, 0.3, 0.8,
		0.0, 0.0, 0.5, 4.0, 1.0, 1.5)
	_assert_write_xform_matches(rec, s_walk, "4-point walker mid")
	rec.frame(172.0, 60.0, 0.016)
	_assert_write_xform_matches(rec, s_walk, "4-point walker ext")

	# 4. RobotSwarm MV mode + rollback
	var rec_rb := MoverRecords.new()
	rec_rb.frame(10.0, 60.0, 0.016)
	var sb := rec_rb.alloc()
	rec_rb.write_sim(sb, Vector2(0.0, 0.0), Vector2(20.0, 0.0), Vector2(20.0, 0.0), Vector2.ZERO,
		10.0, 50.0, 50.0, MoverRecords.ANIMATED | MoverRecords.SIMULATED, 3.0, 10.0,
		0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 6.0, 0.0, 0.5)
	var swarm := RobotSwarm.new()
	swarm.records = rec_rb
	root.add_child(swarm)
	var box := BoxMesh.new()
	var batch := RobotSwarm.Batch.new()
	batch.name = "test-bot"
	batch.kind = "logistic"
	batch.capacity = 4
	batch.buffer.resize(4 * RobotSwarm.STRIDE)
	batch.parts.append(swarm._instance(box, null))
	batch.shadows.append(swarm._instance(box, swarm._shadow()))
	for mmi in batch.parts:
		mmi.multimesh.instance_count = 4
	for mmi in batch.shadows:
		mmi.multimesh.instance_count = 4
	swarm._batches["test-bot"] = batch
	var bot := swarm.add(1, "test-bot")
	swarm.place(bot, sb)

	Settings.temporal_mv_override = 1
	rec_rb.frame(20.0, 60.0, 0.016)
	swarm.draw(0.016)
	var p1 := Vector3(batch.buffer[3], batch.buffer[7], batch.buffer[11])
	check(is_equal_approx(batch.buffer[13], 1.0), "RobotSwarm MV sets INSTANCE_CUSTOM.g = 1.0")
	rec_rb.frame(25.0, 60.0, 0.016)
	swarm.draw(0.016)
	var p2 := Vector3(batch.buffer[3], batch.buffer[7], batch.buffer[11])
	check(p2.x > p1.x + 1.0, "RobotSwarm MV advances transform across frames (%f -> %f)" % [p1.x, p2.x])

	Settings.temporal_mv_override = 0
	swarm.draw(0.016)
	check(is_equal_approx(batch.buffer[13], 0.0), "RobotSwarm rollback restores INSTANCE_CUSTOM.g = 0.0")
	check(is_equal_approx(batch.buffer[3], 0.0) and is_equal_approx(batch.buffer[0], 1.0) and is_equal_approx(batch.buffer[10], 1.0),
		"RobotSwarm rollback restores identity transform")
	swarm.clear()
	swarm.queue_free()

	# 5. Creatures MV mode + posed untouched + rollback
	var rec_cr := MoverRecords.new()
	rec_cr.frame(100.0, 60.0, 0.016)
	var sw := rec_cr.alloc()
	var wspots: Array[Vector3] = [
		Vector3(16.0, 0.0, 16.0),
		Vector3(17.0, 0.0, 16.0),
		Vector3(18.0, 0.0, 16.0),
		Vector3(19.0, 0.0, 16.0),
	]
	var wticks: Array[float] = [90.0, 95.0, 100.0, 110.0]
	rec_cr.write(sw, wspots, wticks, 0, 0.0, 0.0, 0.0, 100.0, 0.0, 0.0, 0.0, 5.0, 1.0, 0.0, 0.0,
		0.0, 0.0, 0.0, 4.0, 1.0, 2.0)
	var creatures := Creatures.new()
	creatures.records = rec_cr
	root.add_child(creatures)
	var mover_mat := ShaderMaterial.new()
	mover_mat.shader = Creatures.MoverShader
	creatures._mover_meshes["test-walker"] = _make_triangle_mesh(mover_mat)
	creatures._layers["test-walker"] = {}
	var dummy_node := Node3D.new()
	dummy_node.position = Vector3(16.0, 0.0, 16.0)
	creatures.add(10, "test-walker", dummy_node, sw)
	dummy_node.free()
	creatures.placed(10, Vector3(16.0, 0.0, 16.0))
	var cell := Creatures._cell_of(Vector3(16.0, 0.0, 16.0))
	var layer: Creatures.Layer = (creatures._layers["test-walker"] as Dictionary)[cell]

	Settings.temporal_mv_override = 1
	rec_cr.frame(102.0, 60.0, 0.016)
	creatures._flush(Vector3(16.0, 0.0, 16.0), 0.016)
	var wp1 := layer.buffer[3]
	check(is_equal_approx(layer.buffer[13], 1.0) and is_equal_approx(layer.buffer[14], float(sw + 1)),
		"Creatures MV sets INSTANCE_CUSTOM.g = 1.0 and keeps slot in .b")
	check(not layer.still, "Creatures MV marks active walker layer non-still")
	rec_cr.frame(106.0, 60.0, 0.016)
	creatures._flush(Vector3(16.0, 0.0, 16.0), 0.016)
	var wp2 := layer.buffer[3]
	check(wp2 > wp1 + 0.1, "Creatures MV advances walker transform (%f -> %f)" % [wp1, wp2])

	# Also confirm posed instances in the same frame preserve their own Transform + custom.g == 0
	var posed_xf := Transform3D(Basis.IDENTITY, Vector3(16.25, 0.0, 16.25))
	Creatures._append_instance(layer.posed, posed_xf, 1.2, 0.8, 1.0)
	layer.low = layer.low.min(posed_xf.origin)
	layer.high = layer.high.max(posed_xf.origin)
	creatures._flush(Vector3(16.0, 0.0, 16.0), 0.016)
	var uploaded_mm := RenderingServer.multimesh_get_buffer(layer.mmi.multimesh.get_rid())
	check(uploaded_mm.size() >= 32 and is_equal_approx(uploaded_mm[13], 1.0)
		and is_equal_approx(uploaded_mm[16 + 3], 16.25)
		and is_equal_approx(uploaded_mm[16 + 13], 0.8)
		and is_equal_approx(uploaded_mm[16 + 14], 0.0),
		"Creatures MV leaves posed instances untouched in same layer")

	Settings.temporal_mv_override = 0
	creatures._flush(Vector3(16.0, 0.0, 16.0), 0.016)
	var centre := (Vector2(cell) + Vector2(0.5, 0.5)) * Creatures.LIVE_CELL
	check(is_equal_approx(layer.buffer[13], 0.0) and layer.still,
		"Creatures rollback clears INSTANCE_CUSTOM.g and restores still flag")
	check(absf(layer.buffer[3] - centre.x) < 1e-4 and absf(layer.buffer[11] - centre.y) < 1e-4,
		"Creatures rollback restores cell-center identity (%f,%f)" % [layer.buffer[3], layer.buffer[11]])
	creatures.clear()
	creatures.queue_free()


func _check_lattice_clock_range(mv: BeltMv, cards: ItemCards, lat_cards: ItemCards, bounds: AABB, clocks: Array[float], tag: String) -> void:
	var prev_buf := PackedFloat32Array()
	var prev_clock := 0.0
	var b_step := Vector3(1.0, 0.0, 0.0)
	var ew := 2.0
	for fi in clocks.size():
		var clock := clocks[fi]
		mv.step(clock, Vector4(-1.0e5, -1.0e5, 1.0e5, 1.0e5), cards, lat_cards, bounds, true)
		var mmi: MultiMeshInstance3D = lat_cards._kinds[12]
		var curr_buf := RenderingServer.multimesh_get_buffer(mmi.multimesh.get_rid())
		check(curr_buf.size() >= 32, "%s frame %d uploaded ping-pong pair" % [tag, fi])
		var vis_count := 0
		var hid_count := 0
		var act_idx := -1
		for slot_i in 2:
			var c3 := curr_buf[slot_i * 16 + 15]
			if c3 < 0.0:
				vis_count += 1
				act_idx = slot_i
			elif c3 > 1.0e10:
				hid_count += 1
		check(vis_count == 1 and hid_count == 1, "%s frame %d: exactly 1 visible and 1 hidden (%d/%d)" % [tag, fi, vis_count, hid_count])
		if fi > 0 and act_idx >= 0 and floori(clock / ew) != floori(prev_clock / ew):
			var prev_o := Vector3(prev_buf[act_idx * 16 + 3], prev_buf[act_idx * 16 + 7], prev_buf[act_idx * 16 + 11])
			var curr_o := Vector3(curr_buf[act_idx * 16 + 3], curr_buf[act_idx * 16 + 7], curr_buf[act_idx * 16 + 11])
			var dq := (clock - prev_clock) / ew
			var expected := b_step * dq
			check(curr_o.distance_to(prev_o + expected) < 1e-4,
				"%s wrap frame %d: newly active slot delta %s == %s" % [tag, fi, curr_o - prev_o, expected])
		prev_buf = curr_buf
		prev_clock = clock


func _test_belt_mv_and_item_cards() -> void:
	var orig_band := BeltMv.max_band
	check(orig_band == 0, "BeltMv.max_band defaults to 0 (got %d)" % orig_band)
	BeltMv.max_band = 1
	_run_belt_mv_suite(true, "native")
	_run_belt_mv_suite(false, "gd")
	_test_belt_mv_parity_and_pan()
	_test_belt_mv_bounds()
	_test_hidden_mv_defer_and_prof()
	BeltMv.max_band = orig_band


func _run_belt_mv_suite(use_nat: bool, tag: String) -> void:
	var mv := BeltMv.new(use_nat)
	if use_nat:
		check(mv.has_native(), "%s: BeltMvNative instantiates cleanly" % tag)
	var cards := ItemCards.new()
	var lat_cards := ItemCards.new()
	cards.mv_mode = true
	cards.mv_max_band = BeltMv.max_band
	lat_cards.mv_mode = true
	lat_cards.mv_max_band = BeltMv.max_band
	lat_cards.record_tex = 1
	root.add_child(cards)
	root.add_child(lat_cards)
	var bounds := AABB(Vector3(-64.0, -4.0, -64.0), Vector3(128.0, 32.0, 128.0))
	var vrect := Vector4(-100.0, -100.0, 100.0, 100.0)

	# Sim records:
	# 0: moving along +X (dx = 4.0 over 10 ticks)
	# 1: standing still
	# 2: handoff take at ew = 5.0
	var sim_img := _make_rgba_page(1024, 1, {
		0: [1.0, 0.2, 2.0, 0.0,  4.0, 0.0, 0.0, 10.0,  1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 0.0],
		1: [8.0, 0.2, 2.0, 0.0,  0.0, 0.0, 0.0, 0.0,   1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 0.0],
		2: [3.0, 0.2, 4.0, 0.0,  0.0, 0.0, 0.0, 0.0,   1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 5.0],
	})
	mv.update_rec_pages({"pages": [[0, sim_img]], "all": true})
	cards.put_records(7, 0, 3, 4, bounds)
	mv.set_rec_kind(7, 0, 3, 4)

	# Band 1 and Band 2 kinds: max_band = 1 must keep Band 2 on GPU records (belt_base >= 0)
	var key_b1 := ItemCards.band_key(7, 1)
	var key_b2 := ItemCards.band_key(7, 2)
	cards.put_records(key_b1, 0, 2, 4, bounds)
	mv.set_rec_kind(key_b1, 0, 2, 4)
	cards.put_records(key_b2, 0, 2, 4, bounds)
	mv.set_rec_kind(key_b2, 0, 2, 4)

	# Shadow proxy test on kind 7
	cards.use_shadow_proxy = true
	var smm := MultiMesh.new()
	smm.transform_format = MultiMesh.TRANSFORM_3D
	smm.use_custom_data = true
	smm.mesh = BoxMesh.new()
	var smmi := MultiMeshInstance3D.new()
	smmi.multimesh = smm
	cards.add_child(smmi)
	cards._shadow_kinds[7] = smmi
	cards.put_records(7, 0, 3, 4, bounds)

	# Lattice records at key 12 (moving, ew = 2.0) and key 14 (standing-only, ew = 0.0)
	var lat_img := _make_rgba_page(1024, 1, {
		0: [10.0, 0.2, 20.0, 0.0,  1.0, 0.0, 0.0, 0.0,  0.0, 7.0, 0.0, 0.0,  0.0, 0.0, 2.0, 2.0],
		1: [12.0, 0.2, 24.0, 0.0,  0.0, 0.0, 0.0, 0.0,  0.0, 9.0, 0.0, 0.0,  0.0, 0.0, 2.0, 0.0],
	})
	mv.update_lat_pages({"pages": [[0, lat_img]], "all": true})
	lat_cards.put_records(12, 0, 1, 2, bounds)
	mv.set_lat_kind(12, 0, 1, 2)
	lat_cards.put_records(14, 1, 1, 2, bounds)
	mv.set_lat_kind(14, 1, 1, 2)

	mv.step(2.0, vrect, cards, lat_cards, bounds, true)
	check(mv.get_moving_count(false, 7) == 2,
		"%s: BeltMv sim moving list skips standing record 1 (%d)" % [tag, mv.get_moving_count(false, 7)])
	var mmi_sim: MultiMeshInstance3D = cards._kinds[7]
	var mmi_b1: MultiMeshInstance3D = cards._kinds[key_b1]
	var mmi_b2: MultiMeshInstance3D = cards._kinds[key_b2]
	var mmi_lat_stand: MultiMeshInstance3D = lat_cards._kinds[14]
	check(mmi_sim.get_instance_shader_parameter("belt_base") == -2, "%s: Band 0 uses belt_base = -2" % tag)
	check(mmi_b1.get_instance_shader_parameter("belt_base") == -2, "%s: Band 1 uses belt_base = -2" % tag)
	check(mmi_b2.get_instance_shader_parameter("belt_base") == 0, "%s: Band 2 stays on belt_base >= 0 when max_band = 1" % tag)
	check(int(mmi_lat_stand.get_instance_shader_parameter("belt_base")) == 1 and mmi_lat_stand.multimesh.visible_instance_count == 1,
		"%s: standing-only lattice stays on 1x GPU records (belt_base >= 0)" % tag)
	check(smmi.get_instance_shader_parameter("belt_base") == 0, "%s: ItemCards shadow proxy keeps belt_base >= 0" % tag)
	var b2 := RenderingServer.multimesh_get_buffer(mmi_sim.multimesh.get_rid())
	check(b2[2 * 16 + 15] < 0.0, "%s: BeltMv handoff item visible before take tick" % tag)

	mv.step(4.0, vrect, cards, lat_cards, bounds, true)
	var b4 := RenderingServer.multimesh_get_buffer(mmi_sim.multimesh.get_rid())
	check(absf((b4[3] - b2[3]) - 4.0 * 0.2) < 1e-4, "%s: BeltMv sim moving delta matches vel * dt (%f)" % [tag, b4[3] - b2[3]])

	mv.step(5.0, vrect, cards, lat_cards, bounds, true)
	var b5 := RenderingServer.multimesh_get_buffer(mmi_sim.multimesh.get_rid())
	check(b5[2 * 16 + 15] > 1.0e10, "%s: BeltMv handoff item hidden at clock >= ew" % tag)

	# Transition standing -> moving -> standing to verify restore_kind dynamically
	var lat_img_mv := _make_rgba_page(1024, 1, {
		0: [10.0, 0.2, 20.0, 0.0,  1.0, 0.0, 0.0, 0.0,  0.0, 7.0, 0.0, 0.0,  0.0, 0.0, 2.0, 2.0],
		1: [12.0, 0.2, 24.0, 0.0,  1.0, 0.0, 0.0, 0.0,  0.0, 9.0, 0.0, 0.0,  0.0, 0.0, 2.0, 2.0],
	})
	mv.update_lat_pages({"pages": [[0, lat_img_mv]], "all": true})
	mv.step(5.2, vrect, cards, lat_cards, bounds, true)
	check(int(mmi_lat_stand.get_instance_shader_parameter("belt_base")) == -2 and mmi_lat_stand.multimesh.visible_instance_count == 2,
		"%s: lattice promotes to belt_base = -2 when moving" % tag)
	mv.update_lat_pages({"pages": [[0, lat_img]], "all": true})
	mv.step(5.4, vrect, cards, lat_cards, bounds, true)
	check(int(mmi_lat_stand.get_instance_shader_parameter("belt_base")) == 1 and mmi_lat_stand.multimesh.visible_instance_count == 1,
		"%s: lattice restores via restore_kind to belt_base >= 0 when stopped" % tag)

	# Standing-only non-lattice (_rec_kinds) restores back to GPU records (belt_base >= 0)
	var sim_stand_img := _make_rgba_page(1024, 1, {
		0: [1.0, 0.2, 2.0, 0.0,  4.0, 0.0, 0.0, 10.0,  1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 0.0],
		1: [8.0, 0.2, 2.0, 0.0,  0.0, 0.0, 0.0, 0.0,   1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 0.0],
		2: [3.0, 0.2, 4.0, 0.0,  0.0, 0.0, 0.0, 0.0,   1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 5.0],
		3: [6.0, 0.2, 6.0, 0.0,  0.0, 0.0, 0.0, 0.0,   1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 0.0],
	})
	mv.update_rec_pages({"pages": [[0, sim_stand_img]], "all": true})
	cards.put_records(9, 3, 1, 2, bounds)
	mv.set_rec_kind(9, 3, 1, 2)
	mv.step(5.6, vrect, cards, lat_cards, bounds, true)
	var mmi_sim_stand: MultiMeshInstance3D = cards._kinds[9]
	check(int(mmi_sim_stand.get_instance_shader_parameter("belt_base")) == 3 and mmi_sim_stand.multimesh.visible_instance_count == 1,
		"%s: standing-only non-lattice stays on GPU records (belt_base >= 0)" % tag)
	var sim_mv_img := _make_rgba_page(1024, 1, {
		0: [1.0, 0.2, 2.0, 0.0,  4.0, 0.0, 0.0, 10.0,  1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 0.0],
		1: [8.0, 0.2, 2.0, 0.0,  0.0, 0.0, 0.0, 0.0,   1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 0.0],
		2: [3.0, 0.2, 4.0, 0.0,  0.0, 0.0, 0.0, 0.0,   1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 5.0],
		3: [6.0, 0.2, 6.0, 0.0,  2.0, 0.0, 0.0, 10.0,  1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 0.0],
	})
	mv.update_rec_pages({"pages": [[0, sim_mv_img]], "all": true})
	mv.step(5.8, vrect, cards, lat_cards, bounds, true)
	check(int(mmi_sim_stand.get_instance_shader_parameter("belt_base")) == -2,
		"%s: non-lattice promotes to belt_base = -2 when moving" % tag)
	mv.update_rec_pages({"pages": [[0, sim_stand_img]], "all": true})
	mv.step(6.0, vrect, cards, lat_cards, bounds, true)
	check(int(mmi_sim_stand.get_instance_shader_parameter("belt_base")) == 3 and mmi_sim_stand.multimesh.visible_instance_count == 1,
		"%s: non-lattice restores via restore_kind to belt_base >= 0 when stopped" % tag)
	cards.put_records(9, 3, 0, 2, bounds)
	mv.set_rec_kind(9, 3, 0, 2)

	# Lattice ping-pong over 20 frames (low clock and high clock > 2048 for float32 ULP check)
	var low_clocks: Array[float] = []
	var high_clocks: Array[float] = []
	for i in 20:
		low_clocks.append(0.25 + float(i) * 1.0)
		high_clocks.append(5000.25 + float(i) * 1.0)
	_check_lattice_clock_range(mv, cards, lat_cards, bounds, low_clocks, "%s lattice low-clock" % tag)
	_check_lattice_clock_range(mv, cards, lat_cards, bounds, high_clocks, "%s lattice high-clock" % tag)

	check(cards.visible_item_count() == 7, "%s: ItemCards.visible_item_count() returns logical sim count (%d)" % [tag, cards.visible_item_count()])
	check(lat_cards.visible_item_count() == 2, "%s: ItemCards.visible_item_count() returns logical lattice count %d, not 2*n" % [tag, lat_cards.visible_item_count()])

	# Rollback via BeltMv active = false -> ItemCards.restore_records()
	mv.step(5021.25, vrect, cards, lat_cards, bounds, false)
	check(mmi_sim.get_instance_shader_parameter("belt_base") == 0, "%s: restore_records restores sim belt_base >= 0" % tag)
	check(mmi_sim.multimesh.visible_instance_count == 3, "%s: restore_records restores sim visible_instance_count" % tag)
	var mmi_lat: MultiMeshInstance3D = lat_cards._kinds[12]
	check(mmi_lat.get_instance_shader_parameter("belt_base") == 0, "%s: restore_records restores lattice belt_base >= 0" % tag)
	check(mmi_lat.multimesh.visible_instance_count == 1, "%s: restore_records restores lattice visible_instance_count" % tag)
	var id_buf := RenderingServer.multimesh_get_buffer(mmi_lat.multimesh.get_rid())
	check(id_buf.size() >= 16 and is_equal_approx(id_buf[0], 1.0) and is_equal_approx(id_buf[3], 0.0) and is_equal_approx(id_buf[15], 0.0),
		"%s: restore_records restores identity transforms" % tag)

	cards.queue_free()
	lat_cards.queue_free()


func _test_belt_mv_parity_and_pan() -> void:
	var mv_nat := BeltMv.new(true)
	var mv_gd := BeltMv.new(false)
	var bounds := AABB(Vector3(-500.0, -4.0, -500.0), Vector3(1000.0, 32.0, 1000.0))
	var cards_n := ItemCards.new()
	var lat_n := ItemCards.new()
	lat_n.record_tex = 1
	var cards_g := ItemCards.new()
	var lat_g := ItemCards.new()
	lat_g.record_tex = 1
	root.add_child(cards_n)
	root.add_child(lat_n)
	root.add_child(cards_g)
	root.add_child(lat_g)

	# Standing record + far moving record at x=500 (outside vrect[-50,50], inside pan[490,520])
	var sim_img := _make_rgba_page(1024, 1, {
		0: [500.0, 0.2, 10.0, 0.0,  2.0, 0.0, 0.0, 10.0,  1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 0.0],
		1: [1.0, 0.2, 2.0, 0.0,    0.0, 0.0, 0.0, 0.0,   0.7, 0.7, 0.0, 0.0,  0.0, 0.0, 0.0, 0.0],
	})
	var lat_img := _make_rgba_page(1024, 1, {
		0: [5.0, 0.2, 6.0, 0.0,  1.0, 0.0, 0.0, 0.0,  42.0, 99.0, 0.0, 0.0,  0.0, 0.0, 2.0, 2.0],
	})
	for mv_v in [mv_nat, mv_gd]:
		var mv := mv_v as BeltMv
		mv.update_rec_pages({"pages": [[0, sim_img]], "all": true})
		mv.update_lat_pages({"pages": [[0, lat_img]], "all": true})
		mv.set_rec_kind(3, 0, 2, 4)
		mv.set_lat_kind(5, 0, 1, 2)
	cards_n.put_records(3, 0, 2, 4, bounds)
	lat_n.put_records(5, 0, 1, 2, bounds)
	cards_g.put_records(3, 0, 2, 4, bounds)
	lat_g.put_records(5, 0, 1, 2, bounds)

	# Step 1: initial eval inside [-50..50]
	var vr1 := Vector4(-50.0, -50.0, 50.0, 50.0)
	mv_nat.step(1.0, vr1, cards_n, lat_n, bounds, true)
	mv_gd.step(1.0, vr1, cards_g, lat_g, bounds, true)

	# Step 2: camera pan [-40..60] does not touch far slot at x=500, and moving slot stays skipped on steady pass
	var vr2 := Vector4(-40.0, -50.0, 60.0, 50.0)
	mv_nat.step(2.0, vr2, cards_n, lat_n, bounds, true)
	mv_gd.step(2.0, vr2, cards_g, lat_g, bounds, true)
	var bn2 := RenderingServer.multimesh_get_buffer((cards_n._kinds[3] as MultiMeshInstance3D).multimesh.get_rid())
	var bg2 := RenderingServer.multimesh_get_buffer((cards_g._kinds[3] as MultiMeshInstance3D).multimesh.get_rid())
	check(absf(bn2[3] - 500.2) < 1e-3 and absf(bg2[3] - 500.2) < 1e-3,
		"outside-vrect moving slot skipped on steady pan frame (%f vs %f)" % [bn2[3], bg2[3]])
	check(mv_nat.get_moving_count(false, 3) == 1 and mv_gd.get_moving_count(false, 3) == 1,
		"outside-vrect skipped slot stays tracked in moving list")

	# Step 3: camera pans to [490..520] -> far moving slot is now evaluated and native matches GDScript bit-for-bit
	var vr3 := Vector4(490.0, -50.0, 520.0, 50.0)
	mv_nat.step(3.0, vr3, cards_n, lat_n, bounds, true)
	mv_gd.step(3.0, vr3, cards_g, lat_g, bounds, true)
	var bn3 := RenderingServer.multimesh_get_buffer((cards_n._kinds[3] as MultiMeshInstance3D).multimesh.get_rid())
	var bg3 := RenderingServer.multimesh_get_buffer((cards_g._kinds[3] as MultiMeshInstance3D).multimesh.get_rid())
	var ln3 := RenderingServer.multimesh_get_buffer((lat_n._kinds[5] as MultiMeshInstance3D).multimesh.get_rid())
	var lg3 := RenderingServer.multimesh_get_buffer((lat_g._kinds[5] as MultiMeshInstance3D).multimesh.get_rid())
	var max_diff := 0.0
	for i in mini(bn3.size(), bg3.size()):
		max_diff = maxf(max_diff, absf(bn3[i] - bg3[i]))
	for i in mini(ln3.size(), lg3.size()):
		max_diff = maxf(max_diff, absf(ln3[i] - lg3[i]))
	check(absf(bn3[3] - 500.6) < 1e-3 and max_diff < 1e-4,
		"BeltMvNative vs GDScript buffer parity on sim + lattice (max_diff=%f, x=%f)" % [max_diff, bn3[3]])

	cards_n.queue_free()
	lat_n.queue_free()
	cards_g.queue_free()
	lat_g.queue_free()


func _test_hidden_mv_defer_and_prof() -> void:
	var cards := ItemCards.new()
	cards.mv_mode = true
	cards.mv_max_band = 0
	root.add_child(cards)
	var bounds := AABB(Vector3(-32.0, -4.0, -32.0), Vector3(64.0, 16.0, 64.0))
	var buf := PackedFloat32Array()
	buf.resize(2 * ItemCards.STRIDE)
	buf[0] = 1.0
	buf[5] = 1.0
	buf[10] = 1.0
	cards.put_records(21, 0, 1, 2, bounds)
	cards.put_mv(21, buf, 1, 2, bounds)
	var mmi: MultiMeshInstance3D = cards._kinds[21]
	mmi.visible = false
	var before := cards.mv_uploads
	cards.put_mv(21, buf, 1, 2, bounds)
	check(cards.mv_uploads == before, "hidden MultiMesh defers multimesh_set_buffer (uploads=%d vs %d)" % [cards.mv_uploads, before])
	check(cards._mv_deferred.has(21), "hidden MultiMesh marks _mv_deferred")
	mmi.visible = true
	cards._mv_deferred.erase(21)
	cards._reapply_mv(21, mmi)
	check(cards.mv_uploads == before + 1, "flushing via _reapply_mv increments mv_uploads (%d vs %d)" % [cards.mv_uploads, before + 1])
	cards.queue_free()

	var bi := BeltItems.new()
	root.add_child(bi)
	bi._epoch = bi._cards.epoch
	bi._rewrite = false
	check(bi.prof_breakdown() == "", "BeltItems.prof_breakdown() empty when disabled")
	bi.set_prof_detail(true)
	bi._process(0.016)
	var br := bi.prof_breakdown()
	check("mv " in br and "apply " in br and "lods " in br and "start " in br,
		"BeltItems.prof_breakdown() reports 4 phases when enabled (got '%s')" % br)
	bi.set_prof_detail(false)
	check(bi.prof_breakdown() == "", "BeltItems.prof_breakdown() clears when disabled")
	bi.queue_free()


func _test_belt_reactive_and_shaders() -> void:
	# 1. Unmerged belt mesh
	var unmerged_mat := ShaderMaterial.new()
	unmerged_mat.shader = ModelLibrary.FactorioShader
	unmerged_mat.resource_name = "belt_surface"
	var unmerged_mesh := _make_triangle_mesh(unmerged_mat)
	ModelLibrary._setup_belt(unmerged_mesh, "transport-belt")
	var final_unmerged := unmerged_mesh.surface_get_material(0) as ShaderMaterial

	# 2. Merged belt mesh (row 0 = rail, row 1 = belt_surface -> mask = 2)
	var row0 := ShaderMaterial.new()
	row0.shader = ModelLibrary.FactorioShader
	row0.resource_name = "metal_frame"
	var row1 := ShaderMaterial.new()
	row1.shader = ModelLibrary.FactorioShader
	row1.resource_name = "belt_surface"
	var merged_mat := MaterialRows.make([row0, row1])
	var merged_mesh := _make_triangle_mesh(merged_mat)
	ModelLibrary._setup_belt(merged_mesh, "express-transport-belt")
	var final_merged := merged_mesh.surface_get_material(0) as ShaderMaterial

	# 3. -start belt mesh (previously returned early)
	var start_mat := ShaderMaterial.new()
	start_mat.shader = ModelLibrary.FactorioShader
	start_mat.resource_name = "belt_surface"
	var start_mesh := _make_triangle_mesh(start_mat)
	ModelLibrary._setup_belt(start_mesh, "transport-belt-start")
	var final_start := start_mesh.surface_get_material(0) as ShaderMaterial

	# 4. Copy via ModelLods.copy_material
	var copied := ModelLods.copy_material(final_unmerged)

	ModelLibrary.sync_belt_reactive(false)
	check(final_unmerged.next_pass == null and final_merged.next_pass == null
		and final_start.next_pass == null and copied.next_pass == null,
		"ModelLibrary.sync_belt_reactive(false) detaches reactive next_pass")

	ModelLibrary.sync_belt_reactive(true)
	var rp_unmerged := final_unmerged.next_pass as ShaderMaterial
	var rp_merged := final_merged.next_pass as ShaderMaterial
	var rp_start := final_start.next_pass as ShaderMaterial
	var rp_copied := copied.next_pass as ShaderMaterial
	check(rp_unmerged != null and rp_unmerged.shader == ModelLibrary.BeltReactiveShader and rp_unmerged.render_priority == -95,
		"ModelLibrary attaches belt_reactive.gdshader at render_priority -95 on unmerged belt")
	check(int(rp_unmerged.get_shader_parameter("belt_row_mask")) == 0, "unmerged belt has belt_row_mask == 0")
	check(rp_merged != null and int(rp_merged.get_shader_parameter("belt_row_mask")) == 2,
		"merged belt has belt_row_mask == 2 for belt row 1")
	check(rp_start != null and rp_start.shader == ModelLibrary.BeltReactiveShader,
		"-start belt mesh receives reactive next_pass")
	check(rp_copied != null and rp_copied.shader == ModelLibrary.BeltReactiveShader,
		"ModelLods.copy_material registers copy with sync_belt_reactive")

	# End-to-end Settings.sync_temporal_uniforms toggle
	var vp := SubViewport.new()
	vp.size = Vector2i(32, 32)
	root.add_child(vp)
	Settings.belt_reactive_override = -1
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	Settings.sync_temporal_uniforms(vp)
	check(final_unmerged.next_pass == null and copied.next_pass == null,
		"Settings.sync_temporal_uniforms detaches belt reactive pass when FSR2 is off")
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	Settings.sync_temporal_uniforms(vp)
	check(final_unmerged.next_pass != null and copied.next_pass != null,
		"Settings.sync_temporal_uniforms attaches belt reactive pass when FSR2 is on")
	ModelLibrary.sync_belt_reactive(false)
	vp.queue_free()

	# Modified & added shaders compile cleanly
	var shader_paths := [
		"res://shaders/belt_reactive.gdshader",
		"res://shaders/robot_shadow.gdshader",
		"res://shaders/item.gdshader",
		"res://shaders/item_own.gdshader",
		"res://shaders/item_own_cut.gdshader",
		"res://shaders/item_own_blend.gdshader",
		"res://shaders/item_card.gdshader",
		"res://shaders/item_contact.gdshader",
		"res://shaders/factorio_material.gdshader",
		"res://shaders/factorio_material_mover.gdshader",
		"res://shaders/factorio_material_robot.gdshader",
	]
	for sp in shader_paths:
		var sh := load(sp) as Shader
		check(sh != null and not sh.code.is_empty(), "shader loads cleanly: %s" % sp)


## The render review's item 5: n past the buffer's cap, and a page shorter than per_page (the last
## image's size wins), must neither write nor read past the end; both twins alike.
func _test_belt_mv_bounds() -> void:
	var big := _make_rgba_page(64, 1, {
		0: [1.0, 0.2, 2.0, 0.0,  4.0, 0.0, 0.0, 10.0,  1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 0.0],
		1: [2.0, 0.2, 2.0, 0.0,  4.0, 0.0, 0.0, 10.0,  1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 0.0],
	})
	var short := _make_rgba_page(8, 1, {
		0: [3.0, 0.2, 2.0, 0.0,  4.0, 0.0, 0.0, 10.0,  1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 0.0],
		1: [4.0, 0.2, 2.0, 0.0,  4.0, 0.0, 0.0, 10.0,  1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 0.0],
	})
	var bufs: Array = []
	for use_nat: bool in [true, false]:
		var mv := BeltMv.new(use_nat)
		# Page 1 holds 2 rows, page 0 sets per_page to 16: rows 18, 19 of kind 4 are past page 1's end.
		mv.update_rec_pages({"pages": [[1, short], [0, big]], "all": true})
		mv.update_lat_pages({"pages": [[1, short], [0, big]], "all": true})
		mv.set_rec_kind(3, 0, 9, 4)  # n 9 into a cap of 4
		mv.set_rec_kind(4, 16, 4, 4)
		mv.set_lat_kind(5, 0, 7, 2)  # n 7 lattice slots into 2 (4 instances)
		mv.set_lat_kind(6, 16, 4, 4)
		mv.step(1.0, Vector4(-100.0, -100.0, 100.0, 100.0), null, null, AABB(), true)
		mv.step(2.0, Vector4(-100.0, -100.0, 100.0, 100.0), null, null, AABB(), true)
		bufs.append([mv.get_buf(false, 3), mv.get_buf(false, 4), mv.get_buf(true, 5), mv.get_buf(true, 6)])
		var tag := "native" if use_nat else "gd"
		check(mv.get_buf(false, 3).size() == 4 * 16 and mv.get_buf(true, 5).size() == 4 * 16,
			"%s: n past cap keeps the buffers at cap (%d, %d floats)" % [tag, mv.get_buf(false, 3).size(), mv.get_buf(true, 5).size()])
		check(mv.get_moving_count(false, 3) <= 4 and mv.get_moving_count(false, 4) == 2,
			"%s: rows past a short page aren't read (moving %d of 4)" % [tag, mv.get_moving_count(false, 4)])
	var same := true
	for k in 4:
		var a1: PackedFloat32Array = bufs[0][k]
		var a2: PackedFloat32Array = bufs[1][k]
		same = same and a1.size() == a2.size()
		for i in mini(a1.size(), a2.size()):
			same = same and absf(a1[i] - a2[i]) < 1e-4
	check(same, "bounds: native and GDScript buffers alike")


func _initialize() -> void:
	TestEnv.isolate("temporal-mv-test")
	var orig_mv := Settings.temporal_mv_override
	var orig_br := Settings.belt_reactive_override
	var orig_taa := root.use_taa
	var orig_scale := root.scaling_3d_mode

	_test_settings_and_belt_blur()
	_test_mover_records_and_actors()
	_test_belt_mv_and_item_cards()
	_test_belt_reactive_and_shaders()

	Settings.temporal_mv_override = orig_mv
	Settings.belt_reactive_override = orig_br
	root.use_taa = orig_taa
	root.scaling_3d_mode = orig_scale
	Settings.sync_temporal_uniforms(root)

	print("temporal_mv_test: %s" % ("PASS" if fails == 0 else "%d FAILED" % fails))
	TestEnv.clean()
	quit(1 if fails > 0 else 0)
