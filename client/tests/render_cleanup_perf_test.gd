extends SceneTree
## Headless verification for Track 4 (render & budget & hover cleanup):
## 1. SignalLights: disabled real OmniLight3D pool by default (--signal-omni-lights=on restores),
##    empty far_glows() stub kept for LampLights, SignalGlows billboards unaffected.
## 2. FrameBudget: combined floor cap FLOOR_TOTAL_MAX (3500 us) on slow frames, preserving messages
##    floor and >= 1500 us for REDUCERS (--budget-floor-cap=off restores).
## 3. ItemCards: skip redundant multimesh_set_buffer on 0->0 or unchanged steady-state buffers
##    (--mv-skip-clean=off restores).
## 4. RobotSwarm & Creatures: skip per-frame write_xform/upload for idle layers/batches under
##    temporal AA while still uploading moving frames + 2 settling frames to zero motion vectors
##    (--mv-skip-idle=off restores).
## 5. Settings: do not stack SMAA over active MSAA 2x/4x/8x (--msaa-with-smaa=on restores),
##    preserving MSAA -> SMAA fallback under looks that draw passes.
## 6. PlayerInput: cache _update_highlights() when hovered target + cursor tile + held item +
##    rotation + world state haven't changed (--hover-highlight-cache=off restores).
##
##   godot --headless --audio-driver Dummy --path client -s res://tests/render_cleanup_perf_test.gd

const TestEnv := preload("res://tests/test_env.gd")
const Switches := preload("res://scripts/switches.gd")
const FrameBudget := preload("res://scripts/world/frame_budget.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const MoverRecords := preload("res://scripts/world/mover_records.gd")
const RobotSwarm := preload("res://scripts/world/robot_swarm.gd")
const Creatures := preload("res://scripts/world/creatures.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const LooksScript := preload("res://scripts/world/looks.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")
const FxSettings := preload("res://scripts/fx/fx_settings.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")

# Loaded in _run() after SceneTree adds autoloads (Bridge).
var SignalLights: Script
var LampLights: Script
var WorldMirror: Script
var Hud: Script
var PlayerInput: Script

var passes := 0
var fails := 0


func check(ok: bool, what: String) -> void:
	if ok:
		passes += 1
	else:
		fails += 1
		print("FAIL: ", what)


func _test_signal_lights() -> void:
	var omni_was: bool = SignalLights.omni_lights_enabled
	var off_was: bool = SignalLights.disabled_by_arg
	SignalLights.disabled_by_arg = false
	GroundHeight.clear()

	# Flag parsing defaults & rollback.
	Switches.set_test_args(PackedStringArray([]))
	check(not Switches.on("--signal-omni-lights", false), "signal omni lights default off")
	Switches.set_test_args(PackedStringArray(["--signal-omni-lights=on"]))
	check(Switches.on("--signal-omni-lights", false), "--signal-omni-lights=on enables pool")
	Switches.reset_cache()

	var holder := Node3D.new()
	root.add_child(holder)
	var w: Node3D = WorldMirror.new()
	holder.add_child(w)
	w.set_process(false)
	w.protos.add_entities([
		[6, "rail-signal", "rail-signal", -0.5, -0.5, 0.5, 0.5, 90, 160, 90, 1, 1],
		[7, "rail-chain-signal", "rail-chain-signal", -0.5, -0.5, 0.5, 0.5, 90, 160, 160, 1, 1],
	])
	w.chunks[Vector2i.ZERO] = ChunkView.new()
	w._add([1061, 6, 4 * 256 + 128, 4 * 256 + 128, 0, {"sg": 1}])
	w._add([1062, 7, 8 * 256 + 128, 4 * 256 + 128, 0, {"sg": 4}])

	# Default: no OmniLight3D pool allocated, SignalGlows billboards active, far_glows() stubbed [].
	SignalLights.omni_lights_enabled = false
	var sigs: Node3D = SignalLights.new()
	sigs.protos = w.protos
	sigs.world = w
	holder.add_child(sigs)
	sigs._on_entities_changed(Vector2i.ZERO)
	sigs.darkness = 0.9
	sigs._process(SignalLights.REFRESH)
	check(sigs._lights.is_empty(), "SignalLights default allocates zero OmniLight3D nodes (%d)" % sigs._lights.size())
	check(sigs.lit_count() == 2 and sigs._glows.multimesh.visible_instance_count == 2,
		"SignalLights default keeps SignalGlows MultiMesh billboards (%d, vis=%d)" % [sigs.lit_count(), sigs._glows.multimesh.visible_instance_count])
	var fg: Variant = sigs.call("far_glows")
	check(fg is Array and (fg as Array).is_empty(), "SignalLights far_glows() stub returns empty Array")

	# LampLights can still poll signal_lights.far_glows() without errors.
	var lamps: Node3D = LampLights.new()
	lamps.protos = w.protos
	lamps.world = w
	lamps.signal_lights = sigs
	holder.add_child(lamps)
	lamps.darkness = 0.9
	lamps._process(LampLights.REFRESH)
	check(lamps.lit_count() == 0, "LampLights polls SignalLights.far_glows() cleanly")

	# Rollback: --signal-omni-lights=on restores real OmniLight3D pool and lights them at night.
	SignalLights.omni_lights_enabled = true
	sigs._process(SignalLights.REFRESH)
	check(sigs._lights.size() >= SignalLights.MAX_LIGHTS and sigs._lights[0].visible and sigs._lights[1].visible,
		"SignalLights rollback enables and lights real OmniLight3D pool (size=%d)" % sigs._lights.size())

	# Toggling back off hides existing pool lights without hiding billboards.
	SignalLights.omni_lights_enabled = false
	sigs._process(SignalLights.REFRESH)
	check(not sigs._lights[0].visible and sigs._glows.multimesh.visible_instance_count == 2,
		"SignalLights off hides OmniLight3D pool while keeping SignalGlows visible")

	lamps._exit_tree()
	holder.queue_free()
	SignalLights.omni_lights_enabled = omni_was
	SignalLights.disabled_by_arg = off_was


func _test_frame_budget_floor_cap() -> void:
	var shared_was := FrameBudget.shared
	var hard_was := FrameBudget.hard_cap
	var floor_was := FrameBudget.floor_cap
	var rf_was := FrameBudget.reduce_floors
	var bf_was := FrameBudget.belts_first
	var other_was := FrameBudget.test_other_usec
	var nodl_was := FrameBudget.test_no_deadline

	Switches.set_test_args(PackedStringArray([]))
	check(Switches.on("--budget-floor-cap"), "budget floor cap default on")
	Switches.set_test_args(PackedStringArray(["--budget-floor-cap=off"]))
	check(not Switches.on("--budget-floor-cap"), "--budget-floor-cap=off disables cap")
	Switches.reset_cache()

	FrameBudget.shared = true
	FrameBudget.hard_cap = true
	FrameBudget.reduce_floors = true
	FrameBudget.belts_first = true
	FrameBudget.test_no_deadline = false
	FrameBudget.test_other_usec = 60000

	# With floor_cap = true: slow frame caps non-messages normal floors + REDUCERS at FLOOR_TOTAL_MAX (3500),
	# while preserving messages floor (1000) and reserving >= REDUCER_RESERVE_MIN (1500) for REDUCERS.
	FrameBudget.floor_cap = true
	FrameBudget.reset()
	FrameBudget.spent(&"pick", 6000, 0)  # exhausts pool so normal grants hit 0
	for sys: StringName in [&"messages", &"lanes", &"states", &"terrain", &"blueprint", &"build", &"hydrate", &"models", &"unload", &"pipelines", &"lods", &"belt_lods", &"shadows", &"far_decide", &"far_collect", &"far_install"]:
		FrameBudget.waiting(sys, 20)
	var g_msg := FrameBudget.grant(&"messages")
	var norm_sum := 0
	for sys: StringName in [&"lanes", &"states", &"terrain", &"blueprint", &"build", &"hydrate", &"models", &"unload", &"pipelines"]:
		norm_sum += FrameBudget.grant(sys)
	var red_sum := 0
	for sys: StringName in [&"lods", &"belt_lods", &"shadows", &"far_decide", &"far_collect", &"far_install"]:
		red_sum += FrameBudget.grant(sys)
	check(g_msg >= int(FrameBudget.SYSTEMS[&"messages"][2]),
		"FrameBudget floor cap preserves messages floor (%d >= 1000)" % g_msg)
	check(norm_sum + red_sum <= FrameBudget.FLOOR_TOTAL_MAX,
		"FrameBudget floor cap caps non-messages + reducers (%d + %d <= %d)" % [norm_sum, red_sum, FrameBudget.FLOOR_TOTAL_MAX])
	check(red_sum >= FrameBudget.REDUCER_RESERVE_MIN,
		"FrameBudget floor cap reserves >= %d us for REDUCERS (got %d)" % [FrameBudget.REDUCER_RESERVE_MIN, red_sum])

	# Rollback: floor_cap = false allows old uncapped stacking (> FLOOR_TOTAL_MAX).
	FrameBudget.floor_cap = false
	FrameBudget.reset()
	FrameBudget.spent(&"pick", 6000, 0)
	for sys: StringName in [&"messages", &"lanes", &"states", &"terrain", &"blueprint", &"build", &"hydrate", &"models", &"unload", &"pipelines", &"lods", &"belt_lods", &"shadows", &"far_decide", &"far_collect", &"far_install"]:
		FrameBudget.waiting(sys, 20)
	var off_sum := 0
	for sys: StringName in [&"lanes", &"states", &"terrain", &"blueprint", &"build", &"hydrate", &"models", &"unload", &"pipelines", &"lods", &"belt_lods", &"shadows", &"far_decide", &"far_collect", &"far_install"]:
		off_sum += FrameBudget.grant(sys)
	check(off_sum > FrameBudget.FLOOR_TOTAL_MAX + 2000,
		"FrameBudget --budget-floor-cap=off restores uncapped floor stacking (%d > %d)" % [off_sum, FrameBudget.FLOOR_TOTAL_MAX])

	FrameBudget.reset()
	FrameBudget.shared = shared_was
	FrameBudget.hard_cap = hard_was
	FrameBudget.floor_cap = floor_was
	FrameBudget.reduce_floors = rf_was
	FrameBudget.belts_first = bf_was
	FrameBudget.test_other_usec = other_was
	FrameBudget.test_no_deadline = nodl_was


func _make_mv_buf(cap: int, seed_v: float) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(cap * ItemCards.STRIDE)
	for i in cap:
		var o := i * ItemCards.STRIDE
		b[o] = 1.0
		b[o + 3] = seed_v + float(i)
		b[o + 5] = 1.0
		b[o + 10] = 1.0
	return b


func _test_item_cards_skip_clean() -> void:
	var skip_was := ItemCards.mv_skip_clean
	Switches.set_test_args(PackedStringArray([]))
	check(Switches.on("--mv-skip-clean"), "mv-skip-clean default on")
	Switches.set_test_args(PackedStringArray(["--mv-skip-clean=off"]))
	check(not Switches.on("--mv-skip-clean"), "--mv-skip-clean=off disables skip")
	Switches.reset_cache()

	ItemCards.mv_skip_clean = true
	var bounds := AABB(Vector3(-32.0, -4.0, -32.0), Vector3(64.0, 16.0, 64.0))
	var cards := ItemCards.new()
	cards.mv_mode = true
	cards.mv_buf_getter = func(_id: int) -> PackedFloat32Array: return PackedFloat32Array()
	root.add_child(cards)
	cards.put_records(21, 0, 2, 4, bounds)

	# Steady-state unchanged buffer skips redundant upload; changed buffer uploads.
	var buf1 := _make_mv_buf(4, 1.0)
	cards.put_mv(21, buf1, 2, 4, bounds)
	var u1 := cards.mv_uploads
	cards.put_mv(21, buf1, 2, 4, bounds)
	cards.put_mv(21, buf1.duplicate(), 2, 4, bounds)
	check(cards.mv_uploads == u1 and u1 == 1,
		"ItemCards skips steady-state unchanged buffer upload (%d -> %d)" % [u1, cards.mv_uploads])

	var buf2 := _make_mv_buf(4, 2.0)
	cards.put_mv(21, buf2, 2, 4, bounds)
	check(cards.mv_uploads == 2, "ItemCards uploads when steady-state buffer changes (%d)" % cards.mv_uploads)

	# 0 -> 0 visible_count in _sync_mv_mmi skips redundant upload.
	var mmi: MultiMeshInstance3D = cards._kinds[21]
	mmi.multimesh.visible_instance_count = 0
	var before_zero := cards.mv_uploads
	cards._sync_mv_mmi(mmi, buf2, 0, 4, bounds)
	cards._sync_mv_mmi(mmi, buf2, 0, 4, bounds)
	check(cards.mv_uploads == before_zero,
		"ItemCards _sync_mv_mmi skips upload when visible_count==0 and previously 0 (%d == %d)" % [cards.mv_uploads, before_zero])

	# Rollback: --mv-skip-clean=off uploads every frame even when unchanged or 0->0.
	ItemCards.mv_skip_clean = false
	var before_off := cards.mv_uploads
	cards.put_mv(21, buf2, 2, 4, bounds)
	cards.put_mv(21, buf2, 2, 4, bounds)
	cards._sync_mv_mmi(mmi, buf2, 0, 4, bounds)
	check(cards.mv_uploads == before_off + 3,
		"ItemCards --mv-skip-clean=off restores every-call upload (%d vs %d)" % [cards.mv_uploads, before_off + 3])

	cards.queue_free()
	ItemCards.mv_skip_clean = skip_was


func _test_robot_and_creature_idle_skip() -> void:
	var orig_mv := Settings.temporal_mv_override
	var r_skip_was := RobotSwarm.mv_skip_idle
	var c_skip_was := Creatures.mv_skip_idle

	Switches.set_test_args(PackedStringArray([]))
	check(Switches.on("--mv-skip-idle"), "mv-skip-idle default on")
	Switches.set_test_args(PackedStringArray(["--mv-skip-idle=off"]))
	check(not Switches.on("--mv-skip-idle"), "--mv-skip-idle=off disables skip")
	Switches.reset_cache()

	Settings.temporal_mv_override = 1
	RobotSwarm.mv_skip_idle = true
	Creatures.mv_skip_idle = true

	# --- 1. RobotSwarm: moving -> stopped -> 2 settling uploads -> idle skip -> wake ---
	var rec_rb := MoverRecords.new()
	rec_rb.frame(10.0, 60.0, 0.016)
	var sb := rec_rb.alloc()
	rec_rb.write_sim(sb, Vector2(0.0, 0.0), Vector2(20.0, 0.0), Vector2(20.0, 0.0), Vector2.ZERO,
		10.0, 30.0, 30.0, MoverRecords.ANIMATED | MoverRecords.SIMULATED, 3.0, 10.0,
		0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 6.0, 0.0, 1.0)
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

	rec_rb.frame(20.0, 60.0, 0.016)
	swarm.draw(0.016)
	var u_mov1 := swarm.mv_uploads
	rec_rb.frame(25.0, 60.0, 0.016)
	swarm.draw(0.016)
	var u_mov2 := swarm.mv_uploads
	check(u_mov2 == u_mov1 + 1, "RobotSwarm uploads while moving (%d -> %d)" % [u_mov1, u_mov2])

	# Stopped past t_arr (30) and blend/turn decay: first 2 frames upload to land + zero motion vectors.
	rec_rb.frame(80.0, 60.0, 0.016)
	swarm.draw(0.016)
	var u_stop1 := swarm.mv_uploads
	rec_rb.frame(81.0, 60.0, 0.016)
	swarm.draw(0.016)
	var u_stop2 := swarm.mv_uploads
	check(u_stop1 == u_mov2 + 1 and u_stop2 == u_stop1 + 1,
		"RobotSwarm uploads settling frames after stopping to zero motion vectors (%d -> %d -> %d)" % [u_mov2, u_stop1, u_stop2])

	# Subsequent idle frames skip write_xform & upload.
	for t in [82.0, 83.0, 84.0]:
		rec_rb.frame(t, 60.0, 0.016)
		swarm.draw(0.016)
	check(swarm.mv_uploads == u_stop2,
		"RobotSwarm skips upload on steady idle frames (%d == %d)" % [swarm.mv_uploads, u_stop2])

	# Waking up uploads immediately.
	rec_rb.write_sim(sb, Vector2(20.0, 0.0), Vector2(30.0, 0.0), Vector2(30.0, 0.0), Vector2.ZERO,
		85.0, 105.0, 105.0, MoverRecords.ANIMATED | MoverRecords.SIMULATED, 3.0, 85.0,
		0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 6.0, 0.0, 0.5)
	rec_rb.frame(86.0, 60.0, 0.016)
	swarm.draw(0.016)
	check(swarm.mv_uploads == u_stop2 + 1, "RobotSwarm resumes uploading when bot moves again")

	# Rollback: --mv-skip-idle=off uploads idle frames every frame.
	RobotSwarm.mv_skip_idle = false
	rec_rb.frame(200.0, 60.0, 0.016)
	swarm.draw(0.016)
	var u_off1 := swarm.mv_uploads
	rec_rb.frame(201.0, 60.0, 0.016)
	swarm.draw(0.016)
	check(swarm.mv_uploads == u_off1 + 1, "RobotSwarm --mv-skip-idle=off uploads every frame even when idle")
	swarm.clear()
	swarm.queue_free()

	# --- 2. Creatures: moving walker -> stopped -> settling -> idle skip -> wake ---
	var rec_cr := MoverRecords.new()
	rec_cr.frame(100.0, 60.0, 0.016)
	var sw := rec_cr.alloc()
	var wspots: Array[Vector3] = [
		Vector3(16.0, 0.0, 16.0), Vector3(17.0, 0.0, 16.0),
		Vector3(18.0, 0.0, 16.0), Vector3(19.0, 0.0, 16.0),
	]
	var wticks: Array[float] = [90.0, 95.0, 100.0, 110.0]
	rec_cr.write(sw, wspots, wticks, 0, 0.0, 0.0, 0.0, 100.0, 0.0, 0.0, 0.0, 5.0, 1.0, 0.0, 0.0,
		0.0, 0.0, 0.0, 4.0, 1.0, 1.0)
	var creatures := Creatures.new()
	creatures.records = rec_cr
	root.add_child(creatures)
	var mover_mat := ShaderMaterial.new()
	mover_mat.shader = Creatures.MoverShader
	var tri := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3(0.2, 0.0, 0.0), Vector3(0.0, 0.2, 0.0)])
	arr[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP])
	arr[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.UP])
	tri.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	tri.surface_set_material(0, mover_mat)
	creatures._mover_meshes["test-walker"] = tri
	creatures._layers["test-walker"] = {}
	var dummy := Node3D.new()
	dummy.position = Vector3(16.0, 0.0, 16.0)
	creatures.add(10, "test-walker", dummy, sw)
	dummy.free()
	creatures.placed(10, Vector3(16.0, 0.0, 16.0))
	var cell := Creatures._cell_of(Vector3(16.0, 0.0, 16.0))
	var layer: Creatures.Layer = (creatures._layers["test-walker"] as Dictionary)[cell]

	rec_cr.frame(104.0, 60.0, 0.016)
	creatures._flush(Vector3(16.0, 0.0, 16.0), 0.016)
	var c_mov := creatures.mv_uploads
	check(not layer.still and c_mov == 1, "Creatures uploads active walker layer (%d)" % c_mov)

	# Stopped past end_drawn (110) and yaw decay: 2 settling uploads then layer.still == true.
	rec_cr.frame(180.0, 60.0, 0.016)
	creatures._flush(Vector3(16.0, 0.0, 16.0), 0.016)
	var c_stop1 := creatures.mv_uploads
	rec_cr.frame(181.0, 60.0, 0.016)
	creatures._flush(Vector3(16.0, 0.0, 16.0), 0.016)
	var c_stop2 := creatures.mv_uploads
	check(c_stop1 == c_mov + 1 and c_stop2 == c_stop1 + 1 and layer.still,
		"Creatures settles idle layer after 2 frames (%d -> %d -> %d, still=%s)" % [c_mov, c_stop1, c_stop2, layer.still])

	for t in [182.0, 183.0, 184.0]:
		rec_cr.frame(t, 60.0, 0.016)
		creatures._flush(Vector3(16.0, 0.0, 16.0), 0.016)
	check(creatures.mv_uploads == c_stop2, "Creatures skips idle layer uploads (%d == %d)" % [creatures.mv_uploads, c_stop2])

	# Waking up via write + placed resumes uploads.
	var wspots2: Array[Vector3] = [
		Vector3(19.0, 0.0, 16.0), Vector3(20.0, 0.0, 16.0),
		Vector3(21.0, 0.0, 16.0), Vector3(22.0, 0.0, 16.0),
	]
	var wticks2: Array[float] = [180.0, 185.0, 190.0, 200.0]
	rec_cr.write(sw, wspots2, wticks2, 0, 0.0, 0.0, 0.0, 185.0, 0.0, 0.0, 0.0, 5.0, 1.0, 0.0, 0.0,
		0.0, 0.0, 0.0, 4.0, 1.0, 1.0)
	creatures.placed(10, Vector3(22.0, 0.0, 16.0))
	rec_cr.frame(192.0, 60.0, 0.016)
	creatures._flush(Vector3(16.0, 0.0, 16.0), 0.016)
	check(creatures.mv_uploads == c_stop2 + 1 and not layer.still,
		"Creatures wakes settled layer when walker moves again")

	# Rollback: --mv-skip-idle=off uploads idle layers every frame.
	Creatures.mv_skip_idle = false
	rec_cr.frame(300.0, 60.0, 0.016)
	creatures._flush(Vector3(16.0, 0.0, 16.0), 0.016)
	var c_off1 := creatures.mv_uploads
	rec_cr.frame(301.0, 60.0, 0.016)
	creatures._flush(Vector3(16.0, 0.0, 16.0), 0.016)
	check(creatures.mv_uploads == c_off1 + 1, "Creatures --mv-skip-idle=off uploads idle layers every frame")

	creatures.clear()
	creatures.queue_free()
	Settings.temporal_mv_override = orig_mv
	RobotSwarm.mv_skip_idle = r_skip_was
	Creatures.mv_skip_idle = c_skip_was


func _test_msaa_no_smaa_stack() -> void:
	var stack_was := Settings.msaa_with_smaa
	var aa_was: Variant = Settings.get_value("graphics", "antialiasing")
	var look_was: Variant = Settings.get_value("graphics", "look")
	var started_was := Settings._addons_started
	var active_was: Node = LooksScript.active

	Switches.set_test_args(PackedStringArray([]))
	check(not Switches.on("--msaa-with-smaa", false), "msaa-with-smaa default off")
	Switches.set_test_args(PackedStringArray(["--msaa-with-smaa=on"]))
	check(Switches.on("--msaa-with-smaa", false), "--msaa-with-smaa=on enables stacking")
	Switches.reset_cache()

	# Default: no SMAA stacked on MSAA 2x/4x/8x.
	Settings.msaa_with_smaa = false
	for msaa_key: String in ["msaa2", "msaa4", "msaa8"]:
		check(Settings.screen_space_aa_for(msaa_key, false) == Viewport.SCREEN_SPACE_AA_DISABLED,
			"Settings %s does not stack SMAA by default" % msaa_key)
	check(Settings.screen_space_aa_for("smaa", false) == Viewport.SCREEN_SPACE_AA_SMAA, "SMAA alone stays SMAA")
	check(Settings.screen_space_aa_for("fxaa", false) == Viewport.SCREEN_SPACE_AA_FXAA, "FXAA alone stays FXAA")

	# MSAA -> SMAA fallback under a look that draws passes stays intact.
	LooksScript.active = null
	var id := "perf-cleanup-test/passes"
	LooksScript.register(id, {"name": "With pass", "passes": [{"shader": "res://shaders/ui_test_none.gdshader"}]}, "perf-test")
	Settings._addons_started = true
	Settings.set_value("graphics", "antialiasing", "msaa4", false)
	Settings.set_value("graphics", "look", id, false)
	check(Settings.antialiasing_in_effect() == "smaa"
		and Settings.screen_space_aa_for(Settings.antialiasing_in_effect(), false) == Viewport.SCREEN_SPACE_AA_SMAA,
		"MSAA under a look with passes still falls back to SMAA")
	LooksScript.looks.erase(id)
	LooksScript.order.erase(id)

	# Rollback: --msaa-with-smaa=on restores SMAA paired with MSAA when TAA is off.
	Settings.msaa_with_smaa = true
	check(Settings.screen_space_aa_for("msaa4", false) == Viewport.SCREEN_SPACE_AA_SMAA
		and Settings.screen_space_aa_for("msaa4", true) == Viewport.SCREEN_SPACE_AA_DISABLED,
		"Settings --msaa-with-smaa=on restores SMAA stacking with MSAA")

	Settings.msaa_with_smaa = stack_was
	LooksScript.active = active_was
	Settings._addons_started = started_was
	Settings.set_value("graphics", "antialiasing", aa_was, false)
	Settings.set_value("graphics", "look", look_was, false)


func _test_hover_highlight_cache() -> void:
	var cache_was: bool = PlayerInput.hover_highlight_cache
	Switches.set_test_args(PackedStringArray([]))
	check(Switches.on("--hover-highlight-cache"), "hover-highlight-cache default on")
	Switches.set_test_args(PackedStringArray(["--hover-highlight-cache=off"]))
	check(not Switches.on("--hover-highlight-cache"), "--hover-highlight-cache=off disables cache")
	Switches.reset_cache()

	FxSettings.load_settings()
	var holder := Node3D.new()
	root.add_child(holder)
	var hud: CanvasLayer = Hud.new()
	holder.add_child(hud)
	await process_frame
	var world: Node3D = WorldMirror.new()
	holder.add_child(world)
	world.set_process(false)
	world.protos.add_tiles([[0, "grass-1", 80, 120, 60]])
	world.protos.add_entities([
		[1, "test-box-entity", "assembling-machine", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[2, "inserter", "inserter", -0.5, -0.5, 0.5, 0.5, 200, 60, 60, 1, 1],
	])
	hud.ui.model.handle({"t": "eprops", "l": [[2, 0, 0, 0, {"ip": [0, -1], "id": [0, 1]}]]})
	hud.set_inventory([["test-box-entity", 50]])
	world.chunks[Vector2i.ZERO] = ChunkView.new()
	world._add([101, 2, 3 * 256 + 128, 3 * 256 + 128, 0])
	var ins: Variant = world.entities[world.entities.keys()[0]]

	var input: Node = PlayerInput.new()
	input.world = world
	input.hud = hud
	holder.add_child(input)
	input.set_process(false)
	input.set_process_unhandled_input(false)

	PlayerInput.hover_highlight_cache = true
	input.has_ground = true
	input.ground = Vector2(3.4, 3.4)
	input.hovered = ins
	input._update_highlights()
	check(input.highlight_rebuilds == 1 and input.highlight_cache_hits == 0,
		"Hover cache misses on first frame (%d rebuilds, %d hits)" % [input.highlight_rebuilds, input.highlight_cache_hits])

	# Steady hover (even with slight cursor movement on same hovered entity) hits cache.
	input.ground = Vector2(3.6, 3.6)
	input._update_highlights()
	input._update_highlights()
	check(input.highlight_rebuilds == 1 and input.highlight_cache_hits == 2,
		"Hover cache hits on steady entity hover (%d rebuilds, %d hits)" % [input.highlight_rebuilds, input.highlight_cache_hits])

	# Rotating hovered entity invalidates cache.
	ins.dir = 4
	input._update_highlights()
	check(input.highlight_rebuilds == 2, "Hover cache invalidates when hovered entity rotates")

	# Held build item: sub-tile mouse move hits cache; tile change or R rotation invalidates.
	input.hovered = null
	input.hold("test-box-entity")
	input.ground = Vector2(5.2, 5.2)
	input._update_highlights()
	var rb_held: int = input.highlight_rebuilds
	input.ground = Vector2(5.8, 5.8)  # same snapped tile (5.5, 5.5)
	input._update_highlights()
	check(input.highlight_rebuilds == rb_held and input.highlight_cache_hits == 3,
		"Held entity sub-tile jitter hits cache (%d == %d)" % [input.highlight_rebuilds, rb_held])

	input.build_dir = 4
	input._update_highlights()
	check(input.highlight_rebuilds == rb_held + 1, "Rotating held item invalidates highlight cache")

	input.ground = Vector2(6.2, 5.8)  # moved to next tile (6.5, 5.5)
	input._update_highlights()
	check(input.highlight_rebuilds == rb_held + 2, "Moving cursor to new tile invalidates highlight cache")

	# Rollback: --hover-highlight-cache=off rebuilds every frame.
	PlayerInput.hover_highlight_cache = false
	var rb_off: int = input.highlight_rebuilds
	var hits_off: int = input.highlight_cache_hits
	input._update_highlights()
	input._update_highlights()
	check(input.highlight_rebuilds == rb_off + 2 and input.highlight_cache_hits == hits_off,
		"PlayerInput --hover-highlight-cache=off rebuilds every frame (%d -> %d)" % [rb_off, input.highlight_rebuilds])

	holder.queue_free()
	PlayerInput.hover_highlight_cache = cache_was


func _initialize() -> void:
	TestEnv.isolate("render-cleanup-perf-test")
	_run.call_deferred()


func _run() -> void:
	SignalLights = load("res://scripts/world/signal_lights.gd")
	LampLights = load("res://scripts/world/lamp_lights.gd")
	WorldMirror = load("res://scripts/world/world.gd")
	Hud = load("res://scripts/ui/hud.gd")
	PlayerInput = load("res://scripts/player/player_input.gd")

	_test_signal_lights()
	_test_frame_budget_floor_cap()
	_test_item_cards_skip_clean()
	_test_robot_and_creature_idle_skip()
	_test_msaa_no_smaa_stack()
	await _test_hover_highlight_cache()

	await process_frame
	await process_frame
	print("render_cleanup_perf_test: %d passed, %d failed (%s)" % [passes, fails, "PASS" if fails == 0 else "FAIL"])
	TestEnv.clean()
	quit(1 if fails > 0 else 0)
