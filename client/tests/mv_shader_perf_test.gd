extends SceneTree
## Headless verification for Wave 2 Track 4 (BeltMv Sync & Shader Cleanup):
## 1. BeltMv partial_sync (--belt-mv-partial / --belt-mv-partial=off): skips redundant
##    target.put_mv / restore_kind calls on idle/unchanged/settled/offscreen batches,
##    preserves dynamic motion & parity, and invalidates on reset() / invalidate_all() /
##    active toggle.
## 2. Shader compilation & per-vertex inverse() removal: ghost_card.gdshader,
##    sprite_card.gdshaderinc consumers, factorio_material.gdshaderinc consumers (incl. ragdoll),
##    and cinematic_grade.gdshader load cleanly with zero inverse() in card/ragdoll vertex paths.
## 3. ground_up_in mathematical equivalence against inverse(mat3(M)) * vec3(0, h, 0) and
##    degenerate det == 0.0 safety + RAGDOLL_DECAY floor/normal projection.
## 4. cinematic-shaders/main.gd cloud_ray_opt uniform wiring (--cloud-ray-opt / =off) and
##    idempotent AA/TAA look setup (S12).
##
##   godot --headless --audio-driver Dummy --path client -s res://tests/mv_shader_perf_test.gd

const TestEnv := preload("res://tests/test_env.gd")
const Switches := preload("res://scripts/switches.gd")
const BeltMv := preload("res://scripts/world/belt_mv.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const Looks := preload("res://scripts/world/looks.gd")
const SunShadows := preload("res://scripts/world/sun_shadows.gd")
const AddonShaders := preload("res://scripts/addons/addon_shaders.gd")
const AddonSettings := preload("res://scripts/addons/addon_settings.gd")


class FakeAddonApi:
	extends RefCounted
	var id := "cinematic-shaders"
	var level := 1.9
	var dir := ""
	var settings: AddonSettings
	var shaders: AddonShaders
	var notes: Array[String] = []

	func note(msg: String) -> void:
		notes.append(msg)


class SpyItemCards:
	extends ItemCards
	var put_mv_calls := 0
	var restore_kind_calls := 0

	func put_mv(item_id: int, buf: PackedFloat32Array, visible_count: int, cap: int, bounds: AABB, ping_pong := false, changed := -1) -> int:
		put_mv_calls += 1
		return super.put_mv(item_id, buf, visible_count, cap, bounds, ping_pong, changed)

	func restore_kind(item_id: int) -> void:
		restore_kind_calls += 1
		super.restore_kind(item_id)


var passes := 0
var fails := 0


func check(ok: bool, what: String) -> void:
	if ok:
		passes += 1
	else:
		fails += 1
		print("FAIL: ", what)


func _make_rgba_page(w: int, h: int, rows_data: Dictionary) -> Image:
	var floats := PackedFloat32Array()
	floats.resize(w * h * 4)
	for r_v in rows_data:
		var r := int(r_v)
		var vals: Array = rows_data[r_v] as Array
		var bo := r * 16
		for i in mini(vals.size(), 16):
			floats[bo + i] = float(vals[i])
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBAF, floats.to_byte_array())


func _ground_up_in_ref(m: Basis, h: float) -> Vector3:
	var a := m.x
	var b := m.y
	var c := m.z
	var bc := b.cross(c)
	var det := a.dot(bc)
	if det == 0.0:
		return Vector3.ZERO
	return Vector3(bc.y, c.z * a.x - c.x * a.z, a.z * b.x - a.x * b.z) * (h / det)


func _test_ground_up_in_equivalence() -> void:
	var bases: Array[Basis] = [
		Basis.IDENTITY,
		Basis(Vector3.UP, 0.73).scaled(Vector3(1.5, 0.8, 2.2)),
		Basis(Vector3(1.2, 0.3, -0.4), Vector3(0.45, 1.35, 0.25), Vector3(-0.2, 0.15, 0.95)),
		Basis(Vector3(0.8, 0.0, 0.6), Vector3(0.1, -1.4, 0.2), Vector3(-0.6, 0.0, 0.8)),
	]
	for bi in bases.size():
		var m := bases[bi]
		var inv_m := m.inverse()
		for h: float in [0.0, 1.0, -2.75, 4.5]:
			var got := _ground_up_in_ref(m, h)
			var expected := inv_m * Vector3(0.0, h, 0.0)
			check(got.distance_to(expected) < 1e-4,
				"ground_up_in matches inverse(mat3) * (0, h, 0) for basis %d h=%.2f (diff=%.6f)" % [bi, h, got.distance_to(expected)])

		# RAGDOLL_DECAY equivalence: wp.y adjusted by delta_y leaves wp.x/z unchanged and matches world target y.
		var xf := Transform3D(m, Vector3(12.5, 3.2, -7.8))
		var v := Vector3(0.35, 1.1, -0.42)
		var wp := xf * v
		var target_y := 0.45
		var delta_y := target_y - wp.y
		var up_local := _ground_up_in_ref(xf.basis, 1.0)
		var v_new := v + up_local * delta_y
		var wp_new := xf * v_new
		check(absf(wp_new.x - wp.x) < 1e-4 and absf(wp_new.y - target_y) < 1e-4 and absf(wp_new.z - wp.z) < 1e-4,
			"RAGDOLL_DECAY vertex lift via ground_up_in preserves world XZ and sets world Y (basis %d)" % bi)
		var local_up_got := up_local.normalized()
		var local_up_ref := (xf.basis.inverse() * Vector3.UP).normalized()
		check(local_up_got.distance_to(local_up_ref) < 1e-4,
			"RAGDOLL_DECAY local_up matches inverse(MODEL_MATRIX) * vec3(0,1,0) (basis %d)" % bi)

	# Degenerate zero-determinant matrix must return Vector3.ZERO without NaN/Inf.
	var deg := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
	var deg_res := _ground_up_in_ref(deg, 2.5)
	check(deg_res == Vector3.ZERO and deg_res.is_finite(), "ground_up_in returns finite Vector3.ZERO on det == 0.0")
	var sheared_deg := Basis(Vector3(1.0, 0.0, 0.0), Vector3(2.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0))
	var sheared_res := _ground_up_in_ref(sheared_deg, 1.0)
	check(sheared_res == Vector3.ZERO and sheared_res.is_finite(), "ground_up_in returns finite Vector3.ZERO on rank-2 basis")


func _test_shaders_compile_and_no_inverse() -> void:
	var shader_paths: Array[String] = [
		"res://shaders/ghost_card.gdshader",
		"res://shaders/sprite_card.gdshader",
		"res://shaders/sprite_card_unlit.gdshader",
		"res://shaders/factorio_material.gdshader",
		"res://shaders/factorio_material_mover.gdshader",
		"res://shaders/factorio_material_robot.gdshader",
		"res://shaders/factorio_material_ragdoll.gdshader",
	]
	for sp in shader_paths:
		var sh := load(sp) as Shader
		var valid := sh != null and not sh.code.is_empty()
		if valid:
			var mat := ShaderMaterial.new()
			mat.shader = sh
			var _unis: Array = sh.get_shader_uniform_list()
			valid = mat.shader == sh
		check(valid, "shader loads & parses cleanly: %s" % sp)

	var cine_path := ProjectSettings.globalize_path("res://../addons-src/cinematic-shaders/shaders/cinematic_grade.gdshader")
	var cine_sh := load(cine_path) as Shader
	var cine_ok := cine_sh != null and not cine_sh.code.is_empty()
	var cine_unis: Array[String] = []
	if cine_ok:
		for u_v in cine_sh.get_shader_uniform_list():
			if u_v is Dictionary:
				var u: Dictionary = u_v as Dictionary
				cine_unis.append(str(u.get("name", "")))
		var cine_mat := ShaderMaterial.new()
		cine_mat.shader = cine_sh
		cine_ok = cine_mat.shader == cine_sh
	check(cine_ok and cine_unis.has("cloud_ray_opt"),
		"cinematic_grade.gdshader compiles cleanly and declares cloud_ray_opt uniform")
	if cine_sh != null:
		check(cine_sh.code.contains("cloud_ray_opt > 0.5") and cine_sh.code.contains("base_dt * 2.0")
			and cine_sh.code.contains("bool use_detail"),
			"cinematic_grade.gdshader uses cloud_ray_opt 2x empty stride and gated detail fetches")

	var ghost_src := FileAccess.get_file_as_string("res://shaders/ghost_card.gdshader")
	var card_inc := FileAccess.get_file_as_string("res://shaders/sprite_card.gdshaderinc")
	var mat_inc := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	check(not ghost_src.contains("inverse(") and ghost_src.contains("ground_up_in("),
		"ghost_card.gdshader uses ground_up_in() with zero inverse() calls")
	check(not card_inc.contains("inverse(") and card_inc.contains("ground_up_in("),
		"sprite_card.gdshaderinc uses ground_up_in() with zero inverse() calls")
	check(not mat_inc.contains("inverse(") and mat_inc.contains("ground_up_in(MODEL_MATRIX"),
		"factorio_material.gdshaderinc uses ground_up_in() with zero inverse() calls")


func _run_belt_mv_partial_case(use_nat: bool, partial_on: bool, tag: String) -> void:
	var orig_partial := BeltMv.partial_sync
	var orig_band := BeltMv.max_band
	BeltMv.partial_sync = partial_on
	BeltMv.max_band = 1

	var mv := BeltMv.new(use_nat)
	var cards := SpyItemCards.new()
	var lat_cards := SpyItemCards.new()
	cards.mv_mode = true
	cards.mv_max_band = BeltMv.max_band
	lat_cards.mv_mode = true
	lat_cards.mv_max_band = BeltMv.max_band
	lat_cards.record_tex = 1
	root.add_child(cards)
	root.add_child(lat_cards)

	var bounds := AABB(Vector3(-500.0, -4.0, -500.0), Vector3(1000.0, 32.0, 1000.0))
	var vrect := Vector4(-100.0, -100.0, 100.0, 100.0)

	# Kind 7: slot 0 moving [aw=0, bw=10], slot 1 stationary with future handoff [aw=0, bw=0, ew=50]
	# Kind 8: slot 2 stationary waiting handoff [aw=0, bw=0, ew=50]
	# Kind 9: slot 3 moving offscreen at x=500 (outside vrect)
	var sim_img := _make_rgba_page(1024, 1, {
		0: [1.0, 0.2, 2.0, 0.0,  4.0, 0.0, 0.0, 10.0,  1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 0.0],
		1: [8.0, 0.2, 2.0, 0.0,  0.0, 0.0, 0.0, 0.0,   1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 50.0],
		2: [3.0, 0.2, 4.0, 0.0,  0.0, 0.0, 0.0, 0.0,   1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 50.0],
		3: [500.0, 0.2, 6.0, 0.0, 2.0, 0.0, 0.0, 10.0, 1.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 0.0],
	})
	var lat_img := _make_rgba_page(1024, 1, {
		0: [10.0, 0.2, 20.0, 0.0,  1.0, 0.0, 0.0, 0.0,  0.0, 7.0, 0.0, 0.0,  0.0, 0.0, 2.0, 2.0],
	})
	mv.update_rec_pages({"pages": [[0, sim_img]], "all": true})
	mv.update_lat_pages({"pages": [[0, lat_img]], "all": true})
	cards.put_records(7, 0, 2, 4, bounds)
	mv.set_rec_kind(7, 0, 2, 4)
	cards.put_records(8, 2, 1, 2, bounds)
	mv.set_rec_kind(8, 2, 1, 2)
	cards.put_records(9, 3, 1, 2, bounds)
	mv.set_rec_kind(9, 3, 1, 2)
	lat_cards.put_records(12, 0, 1, 2, bounds)
	mv.set_lat_kind(12, 0, 1, 2)

	# Step 1: initial upload of all 3 sim kinds + 1 lat kind
	mv.step(2.0, vrect, cards, lat_cards, bounds, true)
	var after_init_sim := cards.put_mv_calls
	var after_init_lat := lat_cards.put_mv_calls
	check(after_init_sim == 3 and after_init_lat == 1,
		"%s: initial step uploads all active kinds (sim=%d, lat=%d)" % [tag, after_init_sim, after_init_lat])

	# Step 2: idle/paused same clock + same vrect -> skipped when partial_on, re-uploaded when partial_off
	mv.step(2.0, vrect, cards, lat_cards, bounds, true)
	if partial_on:
		check(cards.put_mv_calls == after_init_sim and lat_cards.put_mv_calls == after_init_lat and mv.sync_skips > 0,
			"%s: same-clock idle step skips redundant put_mv (sim=%d, lat=%d, skips=%d)" % [tag, cards.put_mv_calls, lat_cards.put_mv_calls, mv.sync_skips])
	else:
		check(cards.put_mv_calls > after_init_sim and lat_cards.put_mv_calls > after_init_lat,
			"%s: --belt-mv-partial=off re-uploads on same-clock step (sim=%d, lat=%d)" % [tag, cards.put_mv_calls, lat_cards.put_mv_calls])

	# Step 3: clock advances (3.0 -> 4.0); kind 8 is settled (zero motion waiting on ew=50), kind 9 is offscreen!
	var before_adv_sim := cards.put_mv_calls
	mv.step(3.0, vrect, cards, lat_cards, bounds, true)
	var calls_at_3 := cards.put_mv_calls - before_adv_sim
	if partial_on:
		check(calls_at_3 == 1, "%s: advancing clock only uploads moving visible kind 7, skipping settled kind 8 & offscreen kind 9 (got %d)" % [tag, calls_at_3])
	else:
		check(calls_at_3 == 2, "%s: --belt-mv-partial=off uploads both kind 7 and settled kind 8 (got %d)" % [tag, calls_at_3])

	# Verify moving item transform actually advanced in MultiMesh
	var mmi_7: MultiMeshInstance3D = cards._kinds[7]
	var buf_7 := RenderingServer.multimesh_get_buffer(mmi_7.multimesh.get_rid())
	check(absf(buf_7[3] - (1.0 + 4.0 * 0.3)) < 1e-4,
		"%s: moving slot x advances accurately to 2.2 (got %.4f)" % [tag, buf_7[3]])

	# Step 4: dirty re-evaluation with identical pages -> kinds already at clock=3.0 skip, repeat dirty skips all 3!
	var before_dirty := cards.put_mv_calls
	mv.update_rec_pages({"pages": [[0, sim_img]], "all": true})
	mv.step(3.0, vrect, cards, lat_cards, bounds, true)
	var dirty_first := cards.put_mv_calls - before_dirty
	var before_dirty2 := cards.put_mv_calls
	mv.update_rec_pages({"pages": [[0, sim_img]], "all": true})
	mv.step(3.0, vrect, cards, lat_cards, bounds, true)
	var dirty_second := cards.put_mv_calls - before_dirty2
	if partial_on:
		check(dirty_first == 1 and dirty_second == 0,
			"%s: dirty re-eval skips kinds with identical buffers (1st=%d for formerly offscreen kind 9, 2nd=%d)" % [tag, dirty_first, dirty_second])
	else:
		check(dirty_first == 3 and dirty_second == 3,
			"%s: --belt-mv-partial=off re-uploads all 3 kinds after dirty re-eval (%d, %d)" % [tag, dirty_first, dirty_second])

	# Step 5: pan vrect to reveal offscreen kind 9 at x=500 -> must upload kind 9!
	# (--belt-mv-native-put: a steady kind may be put by BeltMvNative.step, counted in mv.native_puts.)
	var before_pan := cards.put_mv_calls + mv.native_puts
	mv.step(4.0, Vector4(490.0, -50.0, 520.0, 50.0), cards, lat_cards, bounds, true)
	var mmi_9: MultiMeshInstance3D = cards._kinds[9]
	var buf_9 := RenderingServer.multimesh_get_buffer(mmi_9.multimesh.get_rid())
	check(cards.put_mv_calls + mv.native_puts > before_pan and absf(buf_9[3] - (500.0 + 2.0 * 0.4)) < 1e-3,
		"%s: panning onto offscreen kind 9 uploads updated position (x=%.3f)" % [tag, buf_9[3]])

	# Step 6: bring all kinds to clock=4.0, then invalidate_all() clears sync cache so next step re-uploads
	mv.step(4.0, Vector4(-100.0, -100.0, 600.0, 100.0), cards, lat_cards, bounds, true)
	mv.invalidate_all()
	var before_inv := cards.put_mv_calls
	mv.step(4.0, Vector4(-100.0, -100.0, 600.0, 100.0), cards, lat_cards, bounds, true)
	check(cards.put_mv_calls == before_inv + 3,
		"%s: invalidate_all() clears sync cache and re-uploads all 3 kinds (%d)" % [tag, cards.put_mv_calls - before_inv])
	var before_post_inv := cards.put_mv_calls
	mv.step(4.0, Vector4(-100.0, -100.0, 600.0, 100.0), cards, lat_cards, bounds, true)
	if partial_on:
		check(cards.put_mv_calls == before_post_inv,
			"%s: post-invalidate idle step skips redundant put_mv again" % tag)
	else:
		check(cards.put_mv_calls > before_post_inv,
			"%s: --belt-mv-partial=off re-uploads on post-invalidate idle step" % tag)

	# Toggling active=false calls restore_records() and clears sync cache; active=true re-uploads cleanly.
	mv.step(4.0, Vector4(490.0, -50.0, 520.0, 50.0), cards, lat_cards, bounds, false)
	var before_reactivate := cards.put_mv_calls
	mv.step(4.0, Vector4(490.0, -50.0, 520.0, 50.0), cards, lat_cards, bounds, true)
	check(cards.put_mv_calls >= before_reactivate + 3 and int(mmi_7.get_instance_shader_parameter("belt_base")) == -2,
		"%s: active false->true restores then re-uploads cleanly (calls %d -> %d)" % [tag, before_reactivate, cards.put_mv_calls])

	# reset() clears sync cache and internal counters
	mv.reset()
	check(mv.sync_calls == 0 and mv.sync_skips == 0, "%s: reset() clears sync_calls and sync_skips" % tag)

	cards.queue_free()
	lat_cards.queue_free()
	BeltMv.partial_sync = orig_partial
	BeltMv.max_band = orig_band


func _test_belt_mv_partial_sync() -> void:
	var cli_off := "--belt-mv-partial=off" in OS.get_cmdline_user_args()
	check(BeltMv.partial_sync == (not cli_off),
		"BeltMv.partial_sync matches CLI switch (--belt-mv-partial%s)" % ["=off" if cli_off else " default on"])

	# Verify Switches.on("--belt-mv-partial") toggle behavior
	Switches.set_test_args(PackedStringArray([]))
	check(Switches.on("--belt-mv-partial"), "Switches.on('--belt-mv-partial') defaults to true")
	Switches.set_test_args(PackedStringArray(["--belt-mv-partial=off"]))
	check(not Switches.on("--belt-mv-partial"), "Switches.on('--belt-mv-partial') respects =off")
	Switches.reset_cache()

	_run_belt_mv_partial_case(true, true, "native-on")
	_run_belt_mv_partial_case(false, true, "gd-on")
	_run_belt_mv_partial_case(true, false, "native-off")
	_run_belt_mv_partial_case(false, false, "gd-off")
	# --belt-mv-change-flag=off: the native path hashes buffers again; the same checks hold.
	var orig_flag := BeltMv.change_flag
	BeltMv.change_flag = false
	_run_belt_mv_partial_case(true, true, "native-on-hashing")
	_run_belt_mv_partial_case(true, false, "native-off-hashing")
	BeltMv.change_flag = orig_flag


func _test_cinematic_shaders_main() -> void:
	var src := ProjectSettings.globalize_path("res://").path_join("../addons-src/cinematic-shaders").simplify_path()
	if not DirAccess.dir_exists_absolute(src):
		check(false, "cinematic-shaders directory exists at %s" % src)
		return
	var cli_ray_off := "--cloud-ray-opt=off" in OS.get_cmdline_user_args()
	Switches.set_test_args(PackedStringArray([]))
	check(Switches.on("--cloud-ray-opt"), "Switches.on('--cloud-ray-opt') defaults to true")
	Switches.set_test_args(PackedStringArray(["--cloud-ray-opt=off"]))
	check(not Switches.on("--cloud-ray-opt"), "Switches.on('--cloud-ray-opt') respects =off")
	Switches.reset_cache()

	var look_before: Variant = Settings.get_value("graphics", "look")
	var had_look_before := Settings.has_value("graphics", "look_before")
	var look_before_saved: Variant = Settings.get_value("graphics", "look_before") if had_look_before else ""
	var vp := root
	var orig_taa := vp.use_taa
	var orig_msaa := vp.msaa_3d
	var orig_scale := vp.scaling_3d_mode

	var look_env := Environment.new()
	var look_sun := DirectionalLight3D.new()
	var game_looks := Looks.new()
	var shadows := SunShadows.new()
	var holder := Node3D.new()
	root.add_child(holder)
	holder.add_child(look_sun)
	holder.add_child(game_looks)
	shadows.sun = look_sun
	holder.add_child(shadows)
	shadows.set_process(false)
	game_looks.shadows = shadows
	game_looks.attach(look_env, look_sun)

	var cine_script := load(src.path_join("main.gd")) as Script
	check(cine_script != null, "cinematic-shaders/main.gd loads cleanly")
	if cine_script == null:
		holder.queue_free()
		return

	# Case 1: look starts as "classic" -> starting cinematic-shaders switches to LOOK once.
	vp.use_taa = false
	Settings.set_value("graphics", "look", "classic", false)
	var api1 := FakeAddonApi.new()
	api1.dir = src
	api1.settings = AddonSettings.new(null, api1)
	api1.shaders = AddonShaders.new(null, api1)
	var node1: Node = cine_script.new() as Node
	holder.add_child(node1)
	node1.addon_start(api1)
	await process_frame

	var look_id := "cinematic-shaders/cinematic"
	check(str(Settings.get_value("graphics", "look")) == look_id and game_looks.current == look_id,
		"cinematic-shaders switches look from classic to %s on start" % look_id)
	var cls_dyn: Variant = cine_script
	check(bool(cls_dyn.cloud_ray_opt) == (not cli_ray_off),
		"cinematic-shaders cloud_ray_opt matches CLI switch")
	var params: Dictionary = (Looks.looks[look_id]["passes"][0] as Dictionary).get("params", {}) as Dictionary
	var expect_opt := 0.0 if cli_ray_off else 1.0
	check(is_equal_approx(float(params.get("cloud_ray_opt", -1.0)), expect_opt),
		"cinematic-shaders wires cloud_ray_opt=%.1f into pass params (got %s)" % [expect_opt, str(params.get("cloud_ray_opt", "missing"))])

	# Toggling cloud_ray_opt and calling _register() updates params; repeat _register() is idempotent.
	var look_changes := [0]
	var on_look_changed := func(_id: String) -> void:
		look_changes[0] += 1
	game_looks.look_changed.connect(on_look_changed)
	node1._register()
	node1._register()
	check(look_changes[0] == 0,
		"redundant _register() with unchanged settings emits 0 look_changed / AA re-toggles (got %d)" % look_changes[0])

	var prev_opt := bool(cls_dyn.cloud_ray_opt)
	cls_dyn.cloud_ray_opt = not prev_opt
	node1._register()
	var flipped_params: Dictionary = (Looks.looks[look_id]["passes"][0] as Dictionary).get("params", {}) as Dictionary
	check(is_equal_approx(float(flipped_params.get("cloud_ray_opt", -1.0)), 0.0 if prev_opt else 1.0) and look_changes[0] == 1,
		"changing cloud_ray_opt updates pass params and emits 1 look update (got opt=%s, changes=%d)" % [str(flipped_params.get("cloud_ray_opt", -1.0)), look_changes[0]])
	cls_dyn.cloud_ray_opt = prev_opt
	node1._register()
	game_looks.look_changed.disconnect(on_look_changed)

	node1.addon_stop()
	node1.queue_free()
	api1.settings = null
	api1.shaders = null
	await process_frame

	# Case 2: restarting add-on when current look is already LOOK must NOT fire Settings("graphics","look") or redundant use_look().
	Settings.set_value("graphics", "look", look_id, false)
	game_looks.use(look_id, true)
	var look_notif := [0]
	var aa_changes := [0]
	var on_settings := func(sec: String, key: String) -> void:
		if sec == "graphics" and key == "look":
			look_notif[0] += 1
	var on_look_reapply := func(_id: String) -> void:
		aa_changes[0] += 1
	Settings.listen(on_settings)
	game_looks.look_changed.connect(on_look_reapply)
	var api2 := FakeAddonApi.new()
	api2.dir = src
	api2.settings = AddonSettings.new(null, api2)
	api2.shaders = AddonShaders.new(null, api2)
	var node2: Node = cine_script.new() as Node
	holder.add_child(node2)
	node2.addon_start(api2)
	await process_frame
	Settings.unlisten(on_settings)
	game_looks.look_changed.disconnect(on_look_reapply)
	check(look_notif[0] == 0 and aa_changes[0] == 1,
		"restarting cinematic-shaders when already on LOOK skips redundant use_look() Settings notification (look_notif=%d, look_changed=%d)" % [look_notif[0], aa_changes[0]])

	node2.addon_stop()
	Looks.remove_owner("cinematic-shaders")
	node2.queue_free()
	api2.settings = null
	api2.shaders = null
	await process_frame

	Settings.set_value("graphics", "look", look_before, false)
	if had_look_before:
		Settings.set_value("graphics", "look_before", look_before_saved, false)
	else:
		Settings.reset_value("graphics", "look_before")
	vp.use_taa = orig_taa
	vp.msaa_3d = orig_msaa
	vp.scaling_3d_mode = orig_scale
	holder.queue_free()
	await process_frame


func _initialize() -> void:
	TestEnv.isolate("mv-shader-perf-test")
	_run.call_deferred()


func _run() -> void:
	_test_ground_up_in_equivalence()
	_test_shaders_compile_and_no_inverse()
	_test_belt_mv_partial_sync()
	await _test_cinematic_shaders_main()

	await process_frame
	await process_frame
	print("mv_shader_perf_test: %d passed, %d failed (%s)" % [passes, fails, "PASS" if fails == 0 else "FAIL"])
	TestEnv.clean()
	quit(1 if fails > 0 else 0)
