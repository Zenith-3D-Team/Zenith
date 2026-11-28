extends SceneTree
## Tests for time-sliced ShaderWarmup and RenderWarm staged APIs plus legacy start() compatibility.
## Run headless:
##   godot --headless --audio-driver Dummy --path client -s res://tests/shader_warmup_staged_test.gd
## Prints "SHADER WARMUP STAGED FAILS: 0" when all pass; quits with 1 otherwise.

const ShaderWarmup := preload("res://scripts/world/shader_warmup.gd")
const RenderWarm := preload("res://scripts/world/render_warm.gd")
const FarChunks := preload("res://scripts/world/far_chunks.gd")
const TestEnv := preload("res://tests/test_env.gd")

var _fails := 0


func _check(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("FAIL: ", what)


func _initialize() -> void:
	TestEnv.isolate("shader_warmup_staged_test")
	var fail_fast := func() -> void:
		print("FAIL: test timed out")
		TestEnv.clean()
		quit(1)
	create_timer(30.0).timeout.connect(fail_fast)
	_run.call_deferred()


func _run() -> void:
	var holder := Node3D.new()
	holder.name = "Holder"
	root.add_child(holder)

	var shaders_was: Array[Shader] = ShaderWarmup.shaders.duplicate()
	var mode_was := ShaderWarmup.mode
	var compile_mode_was := ShaderWarmup.compile_mode
	var msec_was := ShaderWarmup.warmed_msec
	var boot_was := ShaderWarmup.handled_by_boot
	var render_done_was := RenderWarm.done

	_test_collect_paths()
	_test_weights_and_interleave()
	await _test_shader_warmup_staged(holder)
	await _test_shader_warmup_legacy(holder)
	await _test_render_warm(holder)

	ShaderWarmup.shaders = shaders_was
	ShaderWarmup.mode = mode_was
	ShaderWarmup.compile_mode = compile_mode_was
	ShaderWarmup.warmed_msec = msec_was
	ShaderWarmup.handled_by_boot = boot_was
	RenderWarm.done = render_done_was
	holder.queue_free()
	await process_frame

	print("SHADER WARMUP STAGED FAILS: %d" % _fails)
	TestEnv.clean()
	quit(1 if _fails > 0 else 0)


func _write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


func _test_collect_paths() -> void:
	var all_paths := ShaderWarmup.collect_paths(true)
	_check(all_paths.has("res://shaders/terrain.gdshader") and all_paths.has("res://shaders/factorio_material.gdshader")
		and all_paths.has("res://shaders/far_merged.gdshader"),
		"collect_paths(true) finds core spatial shaders (%d found)" % all_paths.size())
	var uncached_old := false
	var has_remap := false
	var is_sorted := true
	var prev := ""
	for p in all_paths:
		if p.ends_with(".remap"):
			has_remap = true
		if p.get_file().ends_with("_old.gdshader") and not ResourceLoader.has_cached(p):
			uncached_old = true
		if prev != "" and p <= prev:
			is_sorted = false
		prev = p
	_check(not uncached_old, "collect_paths(true) skips uncached *_old.gdshader files")
	_check(not has_remap and is_sorted, "collect_paths(true) trims .remap, deduplicates, and sorts alphabetically")

	var loaded_paths := ShaderWarmup.collect_paths(false)
	var all_cached := true
	for p in loaded_paths:
		if not ResourceLoader.has_cached(p):
			all_cached = false
	_check(all_cached, "collect_paths(false) only keeps ResourceLoader-cached shaders (%d)" % loaded_paths.size())

	var extra_dir := "user://staged_warmup_extra_scan"
	var dummy_shader := "shader_type spatial;\nvoid fragment() { ALBEDO = vec3(0.4); }\n"
	_write_text(extra_dir.path_join("alpha.gdshader"), dummy_shader)
	_write_text(extra_dir.path_join("legacy_old.gdshader"), dummy_shader)
	_write_text(extra_dir.path_join("sub/beta.gdshader"), dummy_shader)
	_write_text(extra_dir.path_join("sub/gamma.gdshader.remap"), "")
	_write_text(extra_dir.path_join(".hidden/ignored.gdshader"), dummy_shader)

	var with_extra := ShaderWarmup.collect_paths(true, [extra_dir, extra_dir, "user://does_not_exist_xyz"])
	_check(with_extra.has(extra_dir.path_join("alpha.gdshader"))
		and with_extra.has(extra_dir.path_join("sub/beta.gdshader"))
		and with_extra.has(extra_dir.path_join("sub/gamma.gdshader")),
		"collect_paths(true, extra_dirs) scans recursively and trims .remap")
	_check(not with_extra.has(extra_dir.path_join("legacy_old.gdshader"))
		and not with_extra.has(extra_dir.path_join(".hidden/ignored.gdshader")),
		"collect_paths(true, extra_dirs) skips uncached *_old and dot-dirs")
	var unique_check := {}
	for p in with_extra:
		unique_check[p] = true
	_check(unique_check.size() == with_extra.size(), "collect_paths deduplicates across repeated extra_dirs")

	var loaded_with_extra := ShaderWarmup.collect_paths(false, [extra_dir])
	_check(not loaded_with_extra.has(extra_dir.path_join("alpha.gdshader")),
		"collect_paths(false) does not scan extra_dirs")


func _test_weights_and_interleave() -> void:
	var inc_cache := {}
	var fm_info := ShaderWarmup._estimate_shader_info("res://shaders/factorio_material.gdshader", inc_cache)
	var wire_info := ShaderWarmup._estimate_shader_info("res://shaders/wire.gdshader", inc_cache)
	var fm_w := float(fm_info.get("weight", 0.0))
	var wire_w := float(wire_info.get("weight", 0.0))
	_check(bool(fm_info.get("heavy", false)) and fm_w >= ShaderWarmup.HEAVY_WEIGHT_THRESHOLD,
		"factorio_material.gdshader is flagged heavy (weight=%.1f)" % fm_w)
	_check(not bool(wire_info.get("heavy", true)) and wire_w < fm_w,
		"wire.gdshader is light and lighter than factorio_material (%.1f < %.1f)" % [wire_w, fm_w])

	var canvas_tmp := "user://staged_warmup_weight_canvas.gdshader"
	_write_text(canvas_tmp, "shader_type canvas_item;\nvoid fragment() { COLOR = vec4(1.0); }\n")
	var canvas_info := ShaderWarmup._estimate_shader_info(canvas_tmp, inc_cache)
	_check(not bool(canvas_info.get("heavy", true)) and float(canvas_info.get("weight", 1.0)) <= 0.2,
		"canvas_item shader gets minimal weight (%.2f)" % float(canvas_info.get("weight", 1.0)))

	# Interleaving spreads heavy shaders out instead of clustering them consecutively.
	var items: Array[ShaderWarmup._WorkItem] = []
	for i in 12:
		items.append(ShaderWarmup._WorkItem.new(ShaderWarmup._ItemKind.SHADER, "res://a%d.gdshader" % i, "a%d" % i, 2.0, false))
	for i in 4:
		items.append(ShaderWarmup._WorkItem.new(ShaderWarmup._ItemKind.SHADER, "res://h%d.gdshader" % i, "h%d" % i, 50.0, true))
	var mixed := ShaderWarmup._interleave_heavy(items)
	var max_consec_heavy := 0
	var cur_consec := 0
	var first_heavy_idx := -1
	for i in mixed.size():
		if mixed[i].is_heavy:
			if first_heavy_idx == -1:
				first_heavy_idx = i
			cur_consec += 1
			max_consec_heavy = maxi(max_consec_heavy, cur_consec)
		else:
			cur_consec = 0
	_check(mixed.size() == items.size() and max_consec_heavy == 1 and first_heavy_idx >= 0 and first_heavy_idx <= 5,
		"interleave spreads heavy items (first=%d, max_consec=%d, total=%d)" % [first_heavy_idx, max_consec_heavy, mixed.size()])


func _test_shader_warmup_staged(holder: Node3D) -> void:
	ShaderWarmup.compile_mode = "safe"
	ShaderWarmup.shaders.clear()
	ShaderWarmup.warmed_msec = -1
	ShaderWarmup.handled_by_boot = false
	var extra_load_dir := "user://staged_warmup_extra_load"
	var extra_path := extra_load_dir.path_join("staged_custom.gdshader")
	var canvas_path := extra_load_dir.path_join("canvas_only.gdshader")
	_write_text(extra_path, "shader_type spatial;\nvoid fragment() { ALBEDO = vec3(0.2, 0.7, 0.3); }\n")
	_write_text(canvas_path, "shader_type canvas_item;\nvoid fragment() { COLOR = vec4(1.0); }\n")
	var expected_paths := ShaderWarmup.collect_paths(true, [extra_load_dir])

	var staged: ShaderWarmup = ShaderWarmup.begin_staged(holder, true, [extra_load_dir], 25) as ShaderWarmup
	_check(staged != null, "begin_staged returns a staged ShaderWarmup node")
	_check(not staged.is_done(), "begin_staged is not done immediately after attachment")
	_check(staged.done_count == 0, "begin_staged starts with done_count == 0")
	_check(staged.total_count == expected_paths.size() + 2,
		"begin_staged total_count matches collected paths + 2 (%d vs %d)" % [staged.total_count, expected_paths.size() + 2])
	_check(staged.total_weight > float(staged.total_count),
		"begin_staged computes weighted total_weight > total_count (%.1f > %d)" % [staged.total_weight, staged.total_count])
	_check(is_equal_approx(staged.progress_fraction(), 0.0), "begin_staged starts with progress_fraction() == 0.0")
	_check(staged.get_child_count() == 0, "begin_staged does not synchronously create children in _ready()")
	_check(ShaderWarmup.shaders.is_empty(), "begin_staged does not synchronously load shaders in _ready()")
	_check(ShaderWarmup.warmed_msec == -1, "warmed_msec stays -1 until staged warmup finishes")

	var frames := 0
	var max_batches := 0
	var max_heavy_concurrent := 0
	var prev_done := 0
	var prev_frac := 0.0
	var monotonic := true
	var frac_monotonic := true
	while not staged.is_done() and frames < 1000:
		await process_frame
		frames += 1
		var dc := staged.done_count
		if dc < prev_done:
			monotonic = false
		prev_done = dc
		var pf := staged.progress_fraction()
		if pf + 0.0001 < prev_frac:
			frac_monotonic = false
		prev_frac = pf
		var ch := staged.get_child_count()
		if ch > max_batches:
			max_batches = ch
		var active_heavy := 0
		for b in staged._active_batches:
			if b.is_heavy:
				active_heavy += 1
		max_heavy_concurrent = maxi(max_heavy_concurrent, active_heavy)

	_check(staged.is_done(), "begin_staged reaches is_done() == true within frame limit (%d frames)" % frames)
	_check(frames > ShaderWarmup.STAGED_WARM_FRAMES + 1, "begin_staged steps across multiple frames (%d frames)" % frames)
	_check(staged.max_active_batches >= ShaderWarmup.COLD_MAX_ACTIVE_MIN and staged.max_active_batches <= ShaderWarmup.COLD_MAX_ACTIVE_MAX,
		"safe cold begin_staged caps max_active_batches (%d in %d..%d)" % [staged.max_active_batches, ShaderWarmup.COLD_MAX_ACTIVE_MIN, ShaderWarmup.COLD_MAX_ACTIVE_MAX])
	_check(max_batches <= staged.max_active_batches,
		"begin_staged keeps active batches within max_active_batches (%d <= %d)" % [max_batches, staged.max_active_batches])
	_check(max_heavy_concurrent <= 1, "safe cold begin_staged serializes heavy shaders (%d <= 1)" % max_heavy_concurrent)
	_check(monotonic and frac_monotonic and is_equal_approx(staged.progress_fraction(), 1.0),
		"begin_staged done_count and progress_fraction() advance monotonically to 1.0")
	_check(staged.done_count == staged.total_count,
		"begin_staged finishes with done_count == total_count (%d/%d)" % [staged.done_count, staged.total_count])
	_check(staged.get_child_count() == 0, "begin_staged frees all temporary batch nodes on completion (%d left)" % staged.get_child_count())
	_check(ShaderWarmup.warmed_msec >= 0, "begin_staged records ShaderWarmup.warmed_msec (%d)" % ShaderWarmup.warmed_msec)
	_check(staged.pipelines_compiled() >= 0, "pipelines_compiled() returns a non-negative integer")
	var only_spatial := not ShaderWarmup.shaders.is_empty()
	var loaded_extra := false
	var loaded_canvas := false
	for s in ShaderWarmup.shaders:
		if s.get_mode() != Shader.MODE_SPATIAL:
			only_spatial = false
		if s.resource_path == extra_path:
			loaded_extra = true
		if s.resource_path == canvas_path:
			loaded_canvas = true
	_check(only_spatial, "begin_staged populates ShaderWarmup.shaders with spatial shaders (%d)" % ShaderWarmup.shaders.size())
	_check(loaded_extra and not loaded_canvas, "begin_staged loads spatial shaders from extra_dirs and skips canvas_item shaders")
	staged.queue_free()
	await process_frame

	# Verify background_throttle = true completes cleanly without stalling.
	ShaderWarmup.warmed_msec = -1
	var bg: ShaderWarmup = ShaderWarmup.begin_staged(holder, true, [], 16) as ShaderWarmup
	bg.background_throttle = true
	var bg_frames := 0
	while not bg.is_done() and bg_frames < 1000:
		await process_frame
		bg_frames += 1
	_check(bg.is_done() and bg.done_count == bg.total_count and bg.get_child_count() == 0,
		"background_throttle=true finishes cleanly without starving (%d frames)" % bg_frames)
	bg.queue_free()
	await process_frame

	# Verify budget_ms = 0 still guarantees progress (>= 1 item/frame) and completes cleanly.
	ShaderWarmup.warmed_msec = -1
	var tight: ShaderWarmup = ShaderWarmup.begin_staged(holder, false, [], 0) as ShaderWarmup
	var tight_frames := 0
	# One item a frame here, so the label read each frame is every item's: with a budget, the last few
	# items (standard materials, then terrain & far chunks) can share a frame and the first is never seen.
	var saw_standard := false
	var saw_special := false
	while not tight.is_done() and tight_frames < 500:
		await process_frame
		tight_frames += 1
		var lbl := tight.current_label
		if lbl == "Standard materials":
			saw_standard = true
		elif lbl == "Terrain & far chunks":
			saw_special = true
	_check(tight.is_done() and tight.get_child_count() == 0 and tight.done_count == tight.total_count,
		"begin_staged with budget_ms=0 still advances >= 1 item/frame and frees batches (%d frames)" % tight_frames)
	_check(saw_standard and saw_special, "begin_staged updates current_label for standard materials and terrain/far chunks")
	tight.queue_free()
	await process_frame

	# Verify warm staged mode (include_all = false, budget > 0) uses WARM_MAX_ACTIVE and completes quickly.
	ShaderWarmup.warmed_msec = -1
	var warm: ShaderWarmup = ShaderWarmup.begin_staged(holder, false, [], 50) as ShaderWarmup
	_check(warm.max_active_batches == ShaderWarmup.WARM_MAX_ACTIVE,
		"warm begin_staged uses WARM_MAX_ACTIVE (%d == %d)" % [warm.max_active_batches, ShaderWarmup.WARM_MAX_ACTIVE])
	var warm_frames := 0
	while not warm.is_done() and warm_frames < 500:
		await process_frame
		warm_frames += 1
	_check(warm.is_done() and warm.get_child_count() == 0 and warm.done_count == warm.total_count,
		"warm begin_staged finishes cleanly and frees batches (%d frames)" % warm_frames)
	warm.queue_free()
	await process_frame

	# Verify --shader-compile=fast restores legacy concurrency limits.
	ShaderWarmup.compile_mode = "fast"
	var fast_cold: ShaderWarmup = ShaderWarmup.begin_staged(holder, true, [], 35) as ShaderWarmup
	var fast_warm: ShaderWarmup = ShaderWarmup.begin_staged(holder, false, [], 50) as ShaderWarmup
	_check(fast_cold.max_active_batches >= ShaderWarmup.FAST_COLD_MAX_ACTIVE_MIN
		and fast_cold.max_active_batches <= ShaderWarmup.FAST_COLD_MAX_ACTIVE_MAX,
		"--shader-compile=fast uses legacy cold concurrency (%d)" % fast_cold.max_active_batches)
	_check(fast_warm.max_active_batches == ShaderWarmup.FAST_WARM_MAX_ACTIVE,
		"--shader-compile=fast uses FAST_WARM_MAX_ACTIVE (%d == %d)" % [fast_warm.max_active_batches, ShaderWarmup.FAST_WARM_MAX_ACTIVE])
	fast_cold.queue_free()
	fast_warm.queue_free()
	ShaderWarmup.compile_mode = "safe"
	await process_frame


func _test_shader_warmup_legacy(holder: Node3D) -> void:
	ShaderWarmup.shaders.clear()
	ShaderWarmup.mode = "loaded"
	ShaderWarmup.warmed_msec = -1
	ShaderWarmup.handled_by_boot = false
	var warm_node := ShaderWarmup.start(holder)
	_check(warm_node != null, "legacy ShaderWarmup.start() returns a Node3D when enabled")
	_check(not ShaderWarmup.shaders.is_empty(), "legacy ShaderWarmup.start() populates shaders synchronously when empty")
	var has_color_mm := false
	var has_far_mesh := false
	var has_far_crown := false
	if warm_node != null:
		for ch in warm_node.get_children():
			if ch is MultiMeshInstance3D and ch.multimesh != null and ch.multimesh.use_colors:
				has_color_mm = true
			elif ch is MeshInstance3D and ch.mesh != null and ch.mesh.get_surface_count() == 1:
				if ch.mesh.surface_get_material(0) == FarChunks.material():
					has_far_mesh = true
				elif ch.mesh.surface_get_material(0) == FarChunks.crown_material():
					has_far_crown = true
	_check(has_color_mm and has_far_mesh and has_far_crown,
		"legacy ShaderWarmup.start() synchronously builds children in _ready()")
	_check(ShaderWarmup.warmed_msec >= 0, "legacy ShaderWarmup.start() records warmed_msec")
	if warm_node != null:
		for i in ShaderWarmup.WARM_FRAMES + 3:
			await process_frame
			if not is_instance_valid(warm_node):
				break
		_check(not is_instance_valid(warm_node), "legacy ShaderWarmup frees itself after WARM_FRAMES")

	ShaderWarmup.warmed_msec = -1
	ShaderWarmup.handled_by_boot = true
	_check(ShaderWarmup.start(holder) == null, "ShaderWarmup.start() returns null when handled_by_boot is true")
	ShaderWarmup.handled_by_boot = false
	ShaderWarmup.mode = "off"
	_check(ShaderWarmup.start(holder) == null, "ShaderWarmup.start() returns null when mode == 'off'")
	ShaderWarmup.mode = "loaded"
	ShaderWarmup.warmed_msec = 42
	_check(ShaderWarmup.start(holder) == null, "ShaderWarmup.start() returns null when warmed_msec >= 0")


func _test_render_warm(holder: Node3D) -> void:
	RenderWarm.done = false
	_check(RenderWarm.WARM_FRAMES == 4, "RenderWarm.WARM_FRAMES remains 4")
	_check(RenderWarm.begin_staged(holder) == null, "RenderWarm.begin_staged() returns null cleanly in headless mode")
	_check(not RenderWarm.done, "RenderWarm.done stays false when begin_staged() skips headless")
	_check(RenderWarm.start(holder) == null, "legacy RenderWarm.start() returns null cleanly in headless mode")
	RenderWarm.done = true
	_check(RenderWarm.begin_staged(holder) == null, "RenderWarm.begin_staged() returns null when RenderWarm.done is true")
	RenderWarm.done = false
	var rw := RenderWarm.new()
	_check(rw.total_count == 3 and rw.done_count == 0
		and rw.current_label == "" and not rw.is_done(),
		"RenderWarm exposes staged progress defaults cleanly")
	rw._staged = true
	holder.add_child(rw)
	_check(rw._vp != null and is_instance_valid(rw._vp), "RenderWarm staged creates SubViewport in _ready()")

	await process_frame
	_check(rw.done_count == 1 and rw.current_label == "Post-processing effects" and not rw.is_done(),
		"RenderWarm staged phase 0 sets up post-processing effects")
	await process_frame
	_check(rw.done_count == 2 and rw.current_label == "Hover & fluid overlays" and not rw.is_done(),
		"RenderWarm staged phase 1 sets up hover & fluid overlays")
	await process_frame
	_check(rw.done_count == 3 and rw.current_label == "Alt-mode GPU icons" and not rw.is_done() and not RenderWarm.done,
		"RenderWarm staged phase 2 sets up Alt-mode GPU icons before hold frames")

	for i in RenderWarm.WARM_FRAMES - 1:
		await process_frame
		_check(not rw.is_done() and not RenderWarm.done,
			"RenderWarm staged holds during frame %d of %d" % [i + 1, RenderWarm.WARM_FRAMES])
	await process_frame
	_check(rw.is_done() and RenderWarm.done and rw._vp == null,
		"RenderWarm staged marks done and frees SubViewport after WARM_FRAMES")
	rw.queue_free()
	await process_frame
