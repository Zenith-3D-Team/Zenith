extends "res://tests/ui_test_base.gd"
## UI test sections: streaming.

func _resolution_scaling() -> void:
	var uhd := Vector2i(3840, 2160)
	var fhd := Vector2i(1920, 1080)
	check(is_equal_approx(Settings.resolution_ratio("1920x1080", uhd), 0.5), "1080p on a 4K monitor is drawn at half its size each way")
	check(is_equal_approx(Settings.resolution_ratio("1280x720", fhd), 2.0 / 3.0), "720p on a 1080p monitor at two thirds")
	check(Settings.resolution_ratio("", uhd) == 1.0, "no resolution is the monitor's own")
	check(Settings.resolution_ratio("wide", uhd) == 1.0 and Settings.resolution_ratio("100x100", uhd) == 1.0, "and so is one that can't be read or is too small")
	check(Settings.resolution_ratio("3840x2160", fhd) == 1.0 and Settings.resolution_ratio("1920x1200", fhd) == 1.0, "a size past the monitor is clamped to it")
	check(Settings.resolution_ratio("1920x1080", Vector2i.ZERO) == 1.0, "no monitor known: no scaling")
	check(is_equal_approx(Settings.resolution_ratio("1280x1024", fhd), 1024.0 / 1080.0), "a narrower shape keeps its rows")
	check(is_equal_approx(Settings.resolution_ratio("1920x1080", Vector2i(3440, 1440)), 0.75), "16:9 on an ultrawide keeps its rows, undistorted")
	check(is_equal_approx(Settings.resolution_ratio("1600x900", Vector2i(1600, 1200)), 1.0), "a wider shape keeps its columns")
	# Game render scaling multiplies, down to Godot's floor.
	check(is_equal_approx(Settings.render_scale_for(1.0, 1.0), 1.0), "windowed or at the monitor's own, render scale alone")
	check(is_equal_approx(Settings.render_scale_for(1.0, 0.5), 0.5), "the resolution sets the 3D scale")
	check(is_equal_approx(Settings.render_scale_for(1.5, 0.5), 0.75) and is_equal_approx(Settings.render_scale_for(2.0, 1.0), 2.0), "and render scaling multiplies it")
	check(is_equal_approx(Settings.render_scale_for(0.25, 0.25), 0.1), "never below Godot's floor")
	# FSR 2.2 upscaler at/below 1.0 by default, plain bilinear above 1.0; FSR 1 explicit below native scale.
	check(Settings.scaling_mode_for(0.5) == Viewport.SCALING_3D_MODE_FSR2
		and Settings.scaling_mode_for(0.75) == Viewport.SCALING_3D_MODE_FSR2
		and Settings.scaling_mode_for(1.0) == Viewport.SCALING_3D_MODE_FSR2
		and Settings.scaling_mode_for(1.5) == Viewport.SCALING_3D_MODE_BILINEAR
		and Settings.scaling_mode_for(0.5, "fsr1") == Viewport.SCALING_3D_MODE_FSR
		and Settings.scaling_mode_for(1.0, "fsr1") == Viewport.SCALING_3D_MODE_BILINEAR,
		"3D scaling uses FSR 2.2 at/below 1.0 by default and bilinear above 1.0 (FSR 1 explicit below native)")
	# The interface: as at the picked resolution, on the monitor's own pixels.
	check(is_equal_approx(Settings.ui_scale_for("auto", 2160, 0.5), 2.0), "automatic UI scale for 1080p on a 4K monitor: 1080p's 100%, twice the pixels")
	check(is_equal_approx(Settings.ui_scale_for("auto", 2160, 1.0 / 3.0), 3.0), "720p's 100%, three times the pixels")
	check(is_equal_approx(Settings.ui_scale_for("1.5", 2160, 0.5), 3.0), "a chosen UI scale means what it would at that resolution")
	check(is_equal_approx(Settings.ui_scale_for("auto", 1440, 1.0), 1.25) and is_equal_approx(Settings.ui_scale_for("1.5", 1440, 1.0), 1.5), "at the monitor's own, as before")
	check(is_equal_approx(2160.0 / Settings.ui_scale_for("1.0", 2160, 0.5), 1080.0), "so the interface has the room of 1080 lines")
	# The list: full screen offers what it can scale up from.
	var window_list: Array = Settings.resolution_choices(fhd, false).map(func(c: Array) -> Variant: return c[1])
	check(window_list == ["", "1280x720", "1600x900", "1920x1080"], "windowed: the sizes that fit on the monitor")
	var full: Array = Settings.resolution_choices(uhd, true)
	check(str(full[0][0]) == "Monitor's own (3840 × 2160)" and full[0][1] == "", "full screen starts with the monitor's own")
	check(full.map(func(c: Array) -> Variant: return c[1]) == ["", "1280x720", "1600x900", "1920x1080", "2560x1440"], "then the common sizes below it")
	check(Settings.resolution_choices(Vector2i(1920, 1200), true).map(func(c: Array) -> Variant: return c[1]) == ["", "1280x720", "1600x900"],
		"a size that would draw at the monitor's own isn't offered twice")
	# Windowed nothing changes (headless is never full screen).
	check(Settings.full_screen_ratio() == 1.0, "a window isn't scaled")
	# A size left over from a window doesn't turn a full-screen game blurry when this arrives.
	var keep_path := Settings.path
	var old_file := "user://ui-test-full-res.cfg"
	var cfg := ConfigFile.new()
	cfg.set_value("graphics", "window_mode", "borderless")
	cfg.set_value("graphics", "resolution", "1280x720")
	cfg.save(old_file)
	Settings.use_file(old_file)
	var dropped: bool = Settings.get_value("graphics", "resolution") == ""
	Settings.set_value("graphics", "resolution", "1280x720")
	Settings.use_file(old_file)
	check(dropped and Settings.get_value("graphics", "resolution") == "1280x720", "a full-screen file saved before forgets its window size once; picked again, it stays")
	cfg = ConfigFile.new()
	cfg.set_value("graphics", "resolution", "1280x720")
	cfg.save(old_file)
	Settings.use_file(old_file)
	check(Settings.get_value("graphics", "resolution") == "1280x720", "a windowed file keeps its size")
	Settings.use_file(keep_path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(old_file))


## Walking on a big base (stutters as chunks stream in): a chunk built again fills its MultiMeshes
## in place, new ones are added within a frame's budget, shadows change only what changes, chunks
## let go of are freed a few a frame, the minimap's layers move with the view instead of being drawn
## again, and the map's pictures are read as bytes.


func _streaming() -> void:
	var protos := ProtoDB.new()
	protos.add_entities([[1, "zz-test-box", "container", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[2, "zz-test-plant", "plant", -0.5, -0.5, 0.5, 0.5, 30, 160, 30, 1, 1]])
	var cv := ChunkView.new()
	add_child(cv)
	var add := func(unit: int, proto: int, x: float) -> void:
		var r := WorldMirror.Rec.new()
		r.key = unit
		r.unit = unit
		r.proto_id = proto
		r.pos = Vector2(x, 3.5)
		cv.entities[unit] = r
	add.call(1, 1, 1.5)
	add.call(2, 2, 3.5)
	var budget := ChunkView.Budget.new(1)
	cv.build_entities(protos, {}, null, budget)
	check(cv._instances.size() == 1 and cv.pending.size() == 1 and budget.left <= 0,
		"a new chunk adds MultiMeshes only within the frame's budget, the rest waits (%d drawn, %d waiting)" % [cv._instances.size(), cv.pending.size()])
	check(cv.add_pending({}, null, ChunkView.Budget.new(10)) and cv._instances.size() == 2 and cv.pending.is_empty(),
		"and adds the rest on a later frame")
	var before := cv._instances.duplicate()
	add.call(3, 1, 5.5)
	cv.build_entities(protos, {}, null, ChunkView.Budget.new(0))
	var box: MultiMeshInstance3D = cv._nodes.get("box")
	check(cv._instances.size() == 2 and before.has(cv._instances[0]) and before.has(cv._instances[1]) and box != null
		and box.multimesh.instance_count == 2 and cv.pending.is_empty(),
		"built again (an entity added), the chunk fills the MultiMeshes it has in place, with no budget left")
	cv.entities.erase(2)
	cv.build_entities(protos, {})
	check(cv._instances.size() == 1 and cv._nodes.has("box") and not cv._nodes.has("cone"),
		"a MultiMesh nothing uses any more goes")
	# H21: train stops wear their colours, one MultiMesh a colour (a model's custom data can be full).
	var stop_mesh := BoxMesh.new()
	var stop_rec := func(unit: int, col: Array) -> WorldMirror.Rec:
		var r := WorldMirror.Rec.new()
		r.key = unit
		r.unit = unit
		r.extra = {"col": col}
		return r
	var stop_key := [stop_mesh, Color8(242, 0, 0)]
	var stop_wants := cv._painted_wants(stop_key, [[Transform3D(), Transform3D()], [[stop_rec.call(90, [242, 0, 0]), "train-stop"], [stop_rec.call(91, [242, 0, 0]), "train-stop"]], []])
	cv._apply(stop_wants[0], {}, null, null)
	var stop_mmi: MultiMeshInstance3D = cv._nodes.get(stop_key)
	check(stop_mmi != null and stop_mmi.multimesh.instance_count == 2 and stop_mmi.get_instance_shader_parameter("f3d_paint") == Color8(242, 0, 0)
		and is_equal_approx(float(stop_mmi.get_instance_shader_parameter("f3d_paint_from")), stop_mesh.get_aabb().end.y * ChunkView.PAINT_FROM),
		"H21: a train stop's MultiMesh carries its colour, painted over the top of the model")
	cv._drop(stop_key)
	check(FarChunks.KEEP_TYPES.has("train-stop"), "H21: far chunks keep train stops in their own colours")
	cv.set_shadow_tier(ChunkView.SHADOWS_NONE)
	check(box.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "a chunk with no shadows to cast turns its own off")
	cv.set_shadow_tier(ChunkView.SHADOWS_NEAR)
	check(box.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON and cv._unready == 0,
		"and on again near the camera; nothing waits for a stand-in, so more stand-ins being ready skips it")
	cv.queue_free()
	# Chunks let go of are freed within a time budget (a whole row goes at once when walking, all of
	# them on a respawn), and a reset hides them at once.
	var w := WorldMirror.new()
	add_child(w)
	var gone: Array = []
	for i in 5:
		var c := Vector2i(i, 0)
		var ucv := ChunkView.new()
		ucv.coord = c
		w.chunks[c] = ucv
		w.add_child(ucv)
		gone.append(ucv)
	for i in 3:
		w._unload(Vector2i(i, 0))
	var left_now := gone.filter(func(n) -> bool: return is_instance_valid(n)).size()
	w.reset(true)
	var hidden: bool = not gone[3].visible and not gone[4].visible
	for f in 10:
		w._free_unloaded()
	check(w.chunks.is_empty() and left_now == gone.size() and hidden and gone.all(func(n) -> bool: return not is_instance_valid(n)),
		"chunks let go of (unloaded, or all on a reset, hidden at once) are freed over the next frames (%d kept at first)" % left_now)
	w.queue_free()
	# An item seen for the first time. --item-models-later=off: its model is read there and then on the main thread
	# (item_models.gd), drawn at once. On (default): a pack's .glb is read on a worker, the kind drawn once it is in.
	var IM := preload("res://scripts/world/item_models.gd")
	var later_was: bool = IM.later
	var fresh: Array = []
	for file in DirAccess.get_files_at(IM.DIR):
		if file.ends_with(".glb") and not IM._cache.has(file.get_basename()) and not IM._jobs.has(file.get_basename()):
			fresh.append(file.get_basename())
			if fresh.size() == 2:
				break
	IM.later = false
	var fresh_item: String = fresh[0] if fresh.size() > 0 else ""
	var cards = preload("res://scripts/world/item_cards.gd").new()
	cards.protos = ProtoDB.new()
	cards.protos.add_items([[77, fresh_item]])
	add_child(cards)
	cards.draw({77: [Vector3(1, 0, 1)]})
	check(fresh_item != "" and cards._kinds[77].visible
		and cards._kinds[77].multimesh.mesh == IM.mesh_for(fresh_item)
		and cards._kinds[77].multimesh.visible_instance_count == 1,
		"--item-models-later=off: an item's model is read on the main thread the first time it is seen (%s), drawn at once" % fresh_item)
	cards.queue_free()
	IM.later = true
	var later_item: String = fresh[1] if fresh.size() > 1 else ""
	var reads_before: int = IM.reads_later
	var later_path: String = IM.ModelPacks.item_model_path(later_item) if later_item != "" else ""
	var on_worker: bool = later_path != "" and not IM._main_only(later_path, IM.ModelPacks.pbr(later_path))
	cards = preload("res://scripts/world/item_cards.gd").new()
	cards.protos = ProtoDB.new()
	cards.protos.add_items([[78, later_item]])
	add_child(cards)
	cards.draw({78: [Vector3(1, 0, 1)]})
	for i in 300:
		if cards._kinds[78].visible:
			break
		await get_tree().process_frame
	check(later_item != "" and cards._kinds[78].visible and cards._kinds[78].multimesh.mesh == IM.mesh_for(later_item)
		and (not on_worker or IM.reads_later == reads_before + 1),
		"item models later: a new item's model read on a worker (%s, %s), its kind drawn with it once in" % [later_item, on_worker])
	cards.queue_free()
	IM.later = later_was
	# The map's pictures from their palette, as bytes: the same as a pixel at a time.
	var pal := [[255, 0, 0], [0, 128, 255], "bad"]
	var px := [0, 1, 2, 7, 1, 0, 0, 1, 1]
	var img: Image = UiModel.chart_image(3, pal, px)
	check(img.get_pixel(0, 0) == Color8(255, 0, 0) and img.get_pixel(1, 0) == Color8(0, 128, 255) and img.get_pixel(2, 0) == Color8(0, 0, 0)
		and img.get_pixel(0, 1) == Color8(0, 0, 0) and img.get_pixel(2, 2) == Color8(0, 128, 255),
		"a chart's picture: palette colours where known, black where the index has none")
	# The minimap's layers move with the view; drawn again past SHIFT_PX, a new zoom or new data.
	var layers := MapLayersScript.new()
	layers.size = Vector2(200, 200)
	add_child(layers)
	layers.follow(Vector2(100, 100), 2.0, true)
	var marks_at: Vector2 = layers.shift_now()
	layers.follow(Vector2(105, 100), 2.0, false)
	var shifted: Vector2 = layers.shift_now()
	layers.follow(Vector2(130, 100), 2.0, false)
	check(marks_at == Vector2.ZERO and shifted == Vector2(-10, 0) and layers.centre == Vector2(130, 100) and layers.shift_now() == Vector2.ZERO,
		"the minimap's layers move 10 px for 5 tiles at 2 px a tile, and are drawn again 30 tiles on (%s, %s)" % [shifted, layers.centre])
	layers.follow(Vector2(131, 100), 2.0, true)
	check(layers.centre == Vector2(130, 100) and layers.shift_now() == Vector2(-2, 0),
		"new data waits a moment rather than being drawn every frame")
	layers.queue_free()


## While moving: the main thread's sliced work shares one allowance a frame (frame_budget.gd),
## handed out by priority, every queue still draining; the bridge's JSON is read off the main thread.


func _frame_budget() -> void:
	const FrameBudget := preload("res://scripts/world/frame_budget.gd")
	var was: bool = FrameBudget.shared
	FrameBudget.shared = false
	FrameBudget.reset()
	await get_tree().process_frame
	check(FrameBudget.grant(&"build") == 6000 and FrameBudget.grant(&"wires") == 1500 and FrameBudget.grant(&"messages", 2) == 8000,
		"frame budget off: each system gets its own slice as before")
	FrameBudget.shared = true
	FrameBudget.reset()
	FrameBudget.test_no_deadline = true
	FrameBudget.test_other_usec = 6000  # the frame's other scripts: 16.7 - 5 reserved - 6 = a 5.7 ms pool
	FrameBudget.waiting(&"messages", 40)
	FrameBudget.waiting(&"build", 5)
	FrameBudget.waiting(&"wires", 9)
	await get_tree().process_frame
	# Wires (priority 7) ask first, but messages and builds (0, 2) are still to run with work waiting.
	var wires_first := FrameBudget.grant(&"wires")
	var pool := FrameBudget.pool
	var msgs := FrameBudget.grant(&"messages")
	FrameBudget.spent(&"messages", msgs, 0)
	var build := FrameBudget.grant(&"build")
	FrameBudget.spent(&"build", build, 3)
	var wires_after := FrameBudget.grant(&"wires")
	var want_build := maxi(pool - 4000 - FrameBudget.LOW_RESERVE, int(FrameBudget.SYSTEMS[&"build"][2]))
	var want_wires := pool - 4000 - want_build
	check(pool > 5000 and pool < 6500 and wires_first == 0 and msgs == 4000 and build == want_build
		and wires_after == (want_wires if want_wires >= FrameBudget.MIN_SLICE else 0),
		"frame budget: one pool a frame (%d µs), messages first, builds what is left but a little for the far work, wires nothing while those wait: %d, %d, %d, %d" % [pool, wires_first, msgs, build, wires_after])
	# A system given nothing frame after frame gets a little anyway, so its queue still drains.
	FrameBudget.spent(&"wires", wires_after, 9)
	var starved := 0
	for i in FrameBudget.STARVE_FRAMES:
		starved = maxi(starved, FrameBudget.grant(&"wires"))
	check(starved == FrameBudget.MIN_SLICE, "frame budget: a system starved %d times gets %d µs" % [FrameBudget.STARVE_FRAMES, starved])
	# --frame-budget-belts=first (on): far belt icons rank with the messages: builds waiting don't hold them back; off,
	# they come after the builds (priority 6, no floor), as before.
	var lanes_got := {}
	for first in [true, false]:
		FrameBudget.reset()
		FrameBudget.belts_first = first
		FrameBudget.waiting(&"messages", 40)
		FrameBudget.waiting(&"build", 5)
		FrameBudget.waiting(&"lanes", 9)
		await get_tree().process_frame
		var m := FrameBudget.grant(&"messages")
		FrameBudget.spent(&"messages", m, 0)
		lanes_got[first] = FrameBudget.grant(&"lanes")
	FrameBudget.belts_first = true
	check(int(lanes_got[true]) >= FrameBudget.MIN_SLICE and int(lanes_got[false]) == 0,
		"frame budget: far belt icons get their slice with builds waiting (%d µs), off nothing while builds wait (%d µs)" % [lanes_got[true], lanes_got[false]])
	# Standing (nothing waiting near the character), a backlog of far work drains at the larger pool.
	FrameBudget.reset()
	FrameBudget.test_other_usec = 3000
	var backlog := 60  # far merges of 1 ms each
	var frames := 0
	FrameBudget.waiting(&"far_install", backlog)
	while backlog > 0 and frames < 200:
		await get_tree().process_frame
		frames += 1
		var g := FrameBudget.grant(&"far_install")
		var done := mini(g / 1000, backlog)
		backlog -= done
		FrameBudget.spent(&"far_install", done * 1000, backlog)
	check(backlog == 0 and frames <= 60 / (FrameBudget.SYSTEMS[&"far_install"][1] / 1000) + 2,
		"frame budget: standing, a backlog of 60 ms of far work drains in %d frames" % frames)
	# Moving (builds waiting every frame), the same backlog still drains, more slowly.
	FrameBudget.reset()
	FrameBudget.test_other_usec = 6000
	backlog = 60
	frames = 0
	FrameBudget.waiting(&"far_install", backlog)
	while backlog > 0 and frames < 400:
		await get_tree().process_frame
		frames += 1
		var b := FrameBudget.grant(&"build")
		FrameBudget.spent(&"build", b, 10)
		var g := FrameBudget.grant(&"far_install")
		var done := mini(g / 1000, backlog)
		if g > 0:
			done = maxi(done, 1)
		backlog -= done
		FrameBudget.spent(&"far_install", done * 1000, backlog)
	check(backlog == 0 and frames <= 62, "frame budget: moving, far work still drains under the builds, a millisecond a frame: %d frames" % frames)
	# A busy frame (the pool at its floor, far work waiting): messages get the floor less the far work's
	# share, backlog or not; fallen behind (bridge.gd --message-catchup) their whole slice.
	FrameBudget.reset()
	FrameBudget.test_other_usec = 60000
	FrameBudget.waiting(&"messages", 4000)
	FrameBudget.waiting(&"wires", 9)
	await get_tree().process_frame
	var busy_msgs := FrameBudget.grant(&"messages", 2)
	var caught := FrameBudget.grant(&"messages", 2, true)
	check(FrameBudget.pool == FrameBudget.POOL_MIN and busy_msgs == FrameBudget.POOL_MIN - FrameBudget.LOW_RESERVE
		and caught == int(FrameBudget.SYSTEMS[&"messages"][1]) and int(FrameBudget.catchups.get(&"messages", 0)) == 1,
		"frame budget: with the pool at its floor messages get %d µs with 4,000 waiting, %d once behind" % [busy_msgs, caught])
	# Overruns are counted per system.
	FrameBudget.reset()
	await get_tree().process_frame
	FrameBudget.grant(&"shadows")
	FrameBudget.spent(&"shadows", 9000, 0)
	check(int(FrameBudget.overruns.get(&"shadows", 0)) == 1, "frame budget: a slice that runs 8 ms past its grant is an overrun")
	# A frame whose other scripts already took most of its time leaves the sliced work only the rest.
	FrameBudget.test_no_deadline = false
	var fps_was := Engine.max_fps
	Engine.max_fps = 0
	FrameBudget.reset()
	await get_tree().process_frame
	FrameBudget.grant(&"messages")
	OS.delay_usec(FrameBudget.TARGET_USEC - FrameBudget.RESERVE_USEC + 2000)
	var late_wires := FrameBudget.grant(&"wires")
	var late_build := FrameBudget.grant(&"build")
	check(late_wires == 0 and late_build == FrameBudget.SYSTEMS[&"build"][2],
		"frame budget: past the frame's deadline wires get nothing (%d µs), builds their floor (%d µs)" % [late_wires, late_build])
	Engine.max_fps = fps_was
	FrameBudget.test_other_usec = -1
	FrameBudget.reset()
	FrameBudget.shared = was


## L14: a screenshot zoomed far out loads thousands of chunks, and after it the game was laggy for a long
## while ("easier to just reload the save"). Once its cover ends the view's own subscription goes out at
## the next step; the chunks no longer wanted are hidden first, farthest from the focus first, a slice a
## frame, before any of their records go (with --unload-hide=off each stayed drawn until its records had
## gone, 2-3 chunks a frame); and the UPS governor takes no step while full detail is on, judging afresh
## after it (it had taken its whole ladder during a long shot, in force the moment the shot ended).


func _shot_release() -> void:
	const FrameBudget := preload("res://scripts/world/frame_budget.gd")
	var sq_was: int = Bridge.square_subs
	var shared_was: bool = FrameBudget.shared
	var hide_was: bool = WorldMirror.unload_hide
	Bridge.square_subs = WorldMirror.MAX_VIEW_RADIUS
	FrameBudget.shared = false  # each call the unload slice (1.5 ms), as one a frame
	_catch_commands()
	var runs := {}
	for hide_first: bool in [true, false]:
		WorldMirror.unload_hide = hide_first
		var w := WorldMirror.new()
		add_child(w)
		w.view_radius = 2
		w.set_focus(Vector2(16.0, 16.0))
		# The shot's cover: 41 x 41 chunks round the focus, every one seen, each arriving with nodes and records.
		var all_seen := func(_c: Vector2i) -> bool: return true
		w.set_cover(Rect2i(Vector2i(-20, -20), Vector2i(41, 41)), Vector2i.ZERO, all_seen)
		var unit := 0
		for step in 60:
			w._update_subscription(WorldMirror.STREAM_STEP)
			for c: Vector2i in w._coming.keys():
				var cv: ChunkView = w.chunks[c]
				if cv.loaded:
					continue
				cv.loaded = true
				cv.tile_ids = PackedInt32Array()
				for k in 6:
					cv.add_child(MeshInstance3D.new())
				for k in 40:
					unit += 1
					var r := WorldMirror.Rec.new()
					r.key = unit
					r.unit = unit
					r.chunk = c
					r.pos = Vector2(c.x * 32 + 0.5 + k % 32, c.y * 32 + 4.5 + k / 32)
					cv.entities[unit] = r
					w.entities[unit] = r
			if w._subscribed.size() >= w._wanted.size() and w._coming.is_empty():
				break
		var loaded := w.chunks.size()
		sent()
		w.clear_cover()
		w._update_subscription(0.0)  # the next frame
		var sub := {}
		for m: Dictionary in sent():
			if m.get("t") == "sub":
				sub = m
		var released: Array = w._unloaded.duplicate()
		var kept: Array = w.chunks.values()
		var records := w.entities.size()
		var center := WorldMirror.chunk_of(w.focus())
		var calls := 0
		var hidden_at := -1
		var far_first := true
		var records_early := false
		var longest := 0
		while not w._unloaded.is_empty() and calls < 20000:
			var t0 := Time.get_ticks_usec()
			w._free_unloaded()
			longest = maxi(longest, Time.get_ticks_usec() - t0)
			calls += 1
			if hidden_at >= 0:
				continue
			var nearest_hidden := INF
			var farthest_drawn := -1.0
			for n in released:
				if not is_instance_valid(n):
					continue
				var d := float(((n as ChunkView).coord - center).length_squared())
				if (n as ChunkView).visible:
					farthest_drawn = maxf(farthest_drawn, d)
				else:
					nearest_hidden = minf(nearest_hidden, d)
			if farthest_drawn < 0.0:
				hidden_at = calls
			else:
				far_first = far_first and nearest_hidden >= farthest_drawn
				records_early = records_early or w.entities.size() < records
		runs[hide_first] = {"loaded": loaded, "sub": sub, "released": released.size(), "hidden_at": hidden_at, "calls": calls,
			"far_first": far_first, "records_early": records_early, "longest": longest,
			"kept_drawn": kept.all(func(n) -> bool: return is_instance_valid(n) and (n as ChunkView).visible),
			"freed": released.all(func(n) -> bool: return not is_instance_valid(n)) and w._unload_keys.is_empty()}
		w.queue_free()
	var on: Dictionary = runs[true]
	var off: Dictionary = runs[false]
	var sub: Dictionary = on["sub"]
	var o: Array = sub.get("o", [99, 99])
	check(int(on["loaded"]) == 41 * 41 and int(sub.get("r", -1)) == 2 and int(o[0]) == 0 and int(o[1]) == 0,
		"L14: the shot's %d chunks loaded, the view's own square goes out at the step after its cover ends (r %s)" % [on["loaded"], str(sub.get("r"))])
	check(int(on["released"]) > 1000 and on["far_first"] and not on["records_early"] and int(on["hidden_at"]) > 0,
		"L14: the %d chunks it let go are hidden first, farthest from the focus first, before any record goes: all hidden in %d frames (farthest first %s, records early %s)"
		% [on["released"], on["hidden_at"], on["far_first"], on["records_early"]])
	check(int(off["hidden_at"]) >= int(on["hidden_at"]) * 4,
		"L14: --unload-hide=off left them drawn until their records had gone: %d frames, hidden first %d" % [off["hidden_at"], on["hidden_at"]])
	check(int(on["longest"]) < 8000 and on["freed"] and on["kept_drawn"] and int(on["calls"]) > int(on["hidden_at"]),
		"L14: a slice a frame (longest %.1f ms), the view's chunks still drawn, every one let go freed over %d frames" % [on["longest"] / 1000.0, on["calls"]])
	# The governor: slow ticks while full detail is on take no step; after it, START_DELAY before judging.
	var g = UpsGovernor.new()
	add_child(g)
	g.set_process(false)
	var tick := [1000.0]
	_govern(g, tick, 40.0, 60.0)
	UpsGovernor.lifted = true
	_govern(g, tick, 90.0, 20.0)
	var during: int = g.level
	UpsGovernor.lifted = false
	_govern(g, tick, UpsGovernor.START_DELAY - 1.0, 60.0)
	var after: int = g.level
	_govern(g, tick, 20.0, 40.0)
	check(during == 0 and after == 0 and g.level > 0,
		"L14: 90 s at 20 UPS under full detail take no step (%d), nor the first seconds after it (%d); slow after that, it steps as before (%d)" % [during, after, g.level])
	var rest_was: bool = UpsGovernor.rest_lifted
	UpsGovernor.rest_lifted = false
	var g_old = UpsGovernor.new()
	add_child(g_old)
	g_old.set_process(false)
	var tick_old := [1000.0]
	_govern(g_old, tick_old, 40.0, 60.0)
	UpsGovernor.lifted = true
	_govern(g_old, tick_old, 40.0, 20.0)
	UpsGovernor.lifted = false
	check(g_old.level >= 8,
		"L14: --governor-full-detail=judge: 40 s of a shot's slow ticks took most of the ladder, as before (level %d)" % g_old.level)
	UpsGovernor.rest_lifted = rest_was
	g.queue_free()
	g_old.queue_free()
	WorldMirror.unload_hide = hide_was
	FrameBudget.shared = shared_was
	Bridge.square_subs = sq_was
	await get_tree().process_frame


## 0.2.1's main-thread fixes (art-src/perf-plans/client-cpu.md): a chunk built once its snapshot's
## last part is in, levels of detail looked at by bands of rings, kept chunks replayed through
## Bridge's queue, the frame budget measuring the frame's own scripts, the ground's texture array
## written a layer at a time.


func _hotfix_021() -> void:
	const FrameBudget := preload("res://scripts/world/frame_budget.gd")
	preload("res://scripts/world/sprite_standins.gd").card("zz-test-box", 0)
	FrameBudget.reset()
	var dbr_was := WorldMirror.double_buffer_refresh
	WorldMirror.double_buffer_refresh = false
	# One build per snapshot: held while parts are still to come, built once with the last.
	var hw := WorldMirror.new()
	add_child(hw)
	hw.protos.add_entities([[1, "zz-test-box", "container", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1]])
	var hcv := ChunkView.new()
	hcv.coord = Vector2i.ZERO
	hw.chunks[Vector2i.ZERO] = hcv
	hw.add_child(hcv)
	hw.handle({"t": "chunk", "cx": 0, "cy": 0, "tiles": [], "parts": 3})
	hw._dirty_terrain.clear()  # (no tile prototypes here: no ground to mesh)
	hw.handle({"t": "ents", "cx": 0, "cy": 0, "part": 1, "parts": 3, "e": [[1, 1, 5 * 256 + 128, 5 * 256 + 128, 0]]})
	var builds := hw.entity_builds
	hw._rebuild_dirty()
	var held := hw.entity_builds == builds and hw._dirty.has(Vector2i.ZERO)
	hw.handle({"t": "ents", "cx": 0, "cy": 0, "part": 2, "parts": 3, "e": [[2, 1, 6 * 256 + 128, 5 * 256 + 128, 0]]})
	hw._rebuild_dirty()
	held = held and hw.entity_builds == builds
	hw.handle({"t": "ents", "cx": 0, "cy": 0, "part": 3, "parts": 3, "e": [[3, 1, 7 * 256 + 128, 5 * 256 + 128, 0]]})
	hw._rebuild_dirty()
	var once := hw.entity_builds == builds + 1 and not hw._dirty.has(Vector2i.ZERO) and hcv.entities.size() == 3
	check(held and once, "a chunk's snapshot is built once, with its last part, not on each part (%d builds)" % (hw.entity_builds - builds))
	# A part lost on the way: built anyway once PARTS_WAIT_MSEC has passed.
	hw.handle({"t": "chunk", "cx": 0, "cy": 0, "tiles": [], "parts": 2})
	hw._dirty_terrain.clear()  # (no tile prototypes here: no ground to mesh)
	hw.handle({"t": "ents", "cx": 0, "cy": 0, "part": 1, "parts": 2, "e": [[1, 1, 5 * 256 + 128, 5 * 256 + 128, 0]]})
	builds = hw.entity_builds
	hw._rebuild_dirty()
	var waited := hw.entity_builds == builds
	hcv.snapshot_msec -= WorldMirror.PARTS_WAIT_MSEC + 1
	hw._rebuild_dirty()
	check(waited and hw.entity_builds == builds + 1, "and a snapshot with a part lost is built after %d ms" % WorldMirror.PARTS_WAIT_MSEC)
	hw.queue_free()
	WorldMirror.double_buffer_refresh = dbr_was

	# Levels of detail by bands: standing still only the camera's 3x3 chunks are looked at; a little
	# movement the next ring too; a zoom every chunk; a chunk shown again behind the camera at once.
	var lw := WorldMirror.new()
	add_child(lw)
	for y in range(-6, 7):
		for x in range(-6, 7):
			var lcv := ChunkView.new()
			lcv.coord = Vector2i(x, y)
			lcv.loaded = true
			lw.chunks[lcv.coord] = lcv
			lw.add_child(lcv)
	lw._sq_center = Vector2i.ZERO
	lw._sq_radius = 6
	var at := Vector3(16.0, 30.0, 16.0)
	var per_tile := 0.001
	var looked_all := 0
	for i in 200:
		lw._update_lod_bands(at, per_tile, -1.0, 0.016)
		looked_all += lw.lod_looked
		var busy := false
		for band: WorldMirror.LodBand in lw._lod_bands:
			busy = busy or band.ring >= 0
		if not busy:
			break
	lw._update_lod_bands(at, per_tile, -1.0, 0.016)
	var still := lw.lod_looked
	lw._update_lod_bands(at + Vector3(1.5, 0.0, 0.0), per_tile, -1.0, 0.016)
	var moved := lw.lod_looked
	lw._update_lod_bands(at + Vector3(1.5, 0.0, 0.0), per_tile, -1.0, 0.016)
	var after := lw.lod_looked
	var zoomed := 0
	for i in 200:
		lw._update_lod_bands(at + Vector3(1.5, 0.0, 0.0), per_tile * 1.1, -1.0, 0.016)
		zoomed += lw.lod_looked
		var busy := false
		for band: WorldMirror.LodBand in lw._lod_bands:
			busy = busy or band.ring >= 0
		if not busy:
			break
	lw.chunk_shown(Vector2i(5, 5))
	lw._update_lod_bands(at + Vector3(1.5, 0.0, 0.0), per_tile * 1.1, -1.0, 0.016)
	var shown := lw.lod_looked
	check(looked_all >= 13 * 13 and still == 9 and moved == 9 + 16 and after == 9 and zoomed >= 13 * 13 and shown == 10,
		"levels of detail by bands: all %d at first, %d standing, %d a step on, %d after it, %d on a zoom, %d with one shown again"
		% [looked_all, still, moved, after, zoomed, shown])
	# Ring perimeter helper covers every unique cell of ring r (8 * r) with no gaps or duplicates.
	var ring_seen := {}
	var ring_ok := true
	for r in [1, 2, 5]:
		ring_seen.clear()
		for pos in 8 * r:
			var off := WorldMirror._lod_ring_offset(r, pos)
			if maxi(absi(off.x), absi(off.y)) != r or ring_seen.has(off):
				ring_ok = false
			ring_seen[off] = true
		if ring_seen.size() != 8 * r:
			ring_ok = false
	check(ring_ok, "levels of detail ring helper visits every 8*r perimeter chunk once")
	lw.queue_free()

	# BehindCull shows newly in-view chunks immediately on a camera turn while slicing off-view hides
	# across frames (HIDE_PER_FRAME), and turning back cancels pending hides without toggling visible.
	# (The sliced path, --unload-fast=off; chunk_streaming_test _test_unload_fast has the time-sliced one.)
	var bc_fast_was: bool = WorldMirror.BehindCull.unload_fast
	WorldMirror.BehindCull.unload_fast = false
	var bcw := WorldMirror.new()
	bcw.view_radius = 6
	add_child(bcw)
	var bcam := Camera3D.new()
	bcam.fov = 40.0
	bcam.far = 600.0
	add_child(bcam)
	bcam.current = true
	for y in range(-10, 11):
		for x in range(-4, 5):
			var c := Vector2i(x, y)
			var bcv := ChunkView.new()
			bcv.coord = c
			bcv.loaded = true
			bcw.chunks[c] = bcv
			bcw.add_child(bcv)
			bcw.behind_cull.added(c, bcv)
	bcam.look_at_from_position(Vector3(16.0, 20.0, 0.0), Vector3(16.0, 0.0, 120.0))
	for _i in 30:
		bcw.behind_cull._process(0.016)
	var settled_south := bcw.behind_cull._to_hide.is_empty() and bcw.behind_cull.hidden_count() > 20
	var hidden_north: Array[Vector2i] = []
	for y in range(-10, -4):
		var c := Vector2i(0, y)
		if bcw.behind_cull.hidden(c):
			hidden_north.append(c)
	bcam.look_at_from_position(Vector3(16.0, 20.0, 0.0), Vector3(16.0, 0.0, -120.0))
	bcw.behind_cull._process(0.016)
	var shown_now := not hidden_north.is_empty() and hidden_north.all(func(c: Vector2i) -> bool: return (bcw.chunks[c] as ChunkView).visible and not bcw.behind_cull.hidden(c))
	var pending_first := bcw.behind_cull._to_hide.size()
	var hidden_after_turn := 0
	for c: Vector2i in bcw.chunks:
		if not (bcw.chunks[c] as ChunkView).visible:
			hidden_after_turn += 1
	bcw.behind_cull._process(0.016)
	var hidden_step2 := 0
	for c: Vector2i in bcw.chunks:
		if not (bcw.chunks[c] as ChunkView).visible:
			hidden_step2 += 1
	var step2_delta := hidden_step2 - hidden_after_turn
	# Turn back before the remaining hides finish: queued chunks stay visible cleanly.
	var cancelled_candidates: Array[Vector2i] = []
	for c: Vector2i in bcw.behind_cull._to_hide:
		cancelled_candidates.append(c)
	bcam.look_at_from_position(Vector3(16.0, 20.0, 0.0), Vector3(16.0, 0.0, 120.0))
	bcw.behind_cull._process(0.016)
	var kept_visible := not cancelled_candidates.is_empty() and cancelled_candidates.all(func(c: Vector2i) -> bool: return (bcw.chunks[c] as ChunkView).visible)
	check(settled_south and shown_now and pending_first > 0 and step2_delta == WorldMirror.BehindCull.HIDE_PER_FRAME and kept_visible,
		"BehindCull shows turned-to chunks at once (%s), slices off-view hides (%d queued, +%d/frame), and cancels pending hides cleanly (%s)"
		% [shown_now, pending_first, step2_delta, kept_visible])
	WorldMirror.BehindCull.unload_fast = bc_fast_was
	bcam.queue_free()
	bcw.queue_free()

	# Kept chunks are replayed through Bridge's queue, ahead of what came after them.
	var b = load("res://scripts/net/bridge.gd").new()
	var got: Array = []
	var handler := func(m: Dictionary) -> void: got.append(m.get("n"))
	b._waiting = [{"t": "zz", "n": 1}, {"t": "zz", "n": 2}]
	b._waiting_len = PackedInt32Array([1, 1])
	b._waiting_at = 1
	b.requeue_front([[handler, {"n": "a"}], [handler, {"n": "b"}]])
	var queued: bool = b.waiting_count() == 3 and b._replay_head.size() == 2 and b._replay_at == 0 and b._waiting.size() == 2 and b._waiting_at == 1 and b._waiting[1].get("n") == 2
	b._drain()
	check(queued and got == ["a", "b"] and not b.draining() and b.waiting_count() == 0,
		"kept chunks' messages go to the front of the queue and are handled there, in order: %s" % [got])
	b.free()

	# The frame budget's other scripts: the frame from its first ask to its last script, less the
	# sliced work (Godot's TIME_PROCESS is the slowest whole frame of the last second).
	FrameBudget.reset()
	var was_measure: bool = FrameBudget.measure_frame
	FrameBudget.measure_frame = true
	FrameBudget.test_other_usec = -1
	var f := Engine.get_process_frames()
	FrameBudget._frame = f - 1
	FrameBudget._frame_start = 1000000
	FrameBudget._end_frame = f - 1
	FrameBudget._end_usec = 1000000 + 5000
	FrameBudget.used_total = 1000
	FrameBudget.grant(&"build")
	check(FrameBudget.other_usec == 4000, "frame budget: the other scripts measured from the frame itself: %d µs" % FrameBudget.other_usec)
	FrameBudget.measure_frame = was_measure
	FrameBudget.reset()

	# Charts' pictures and chunks' tiles decoded as the bridge reads them (its parsing thread); a
	# message with fields of the wrong kind left as it came, for its handler to read the old way.
	const MessageDecode := preload("res://scripts/net/message_decode.gd")
	var chart := {"t": "chart", "n": 2, "pal": [[10, 20, 30], [200, 210, 220]], "px": [0, 1, 1, 0]}
	MessageDecode.prepare(chart, "chart")
	var bad := {"t": "chart", "n": 2, "pal": [[10, 20, 30]], "px": [0, "x", 0, 0]}
	MessageDecode.prepare(bad, "chart")
	var runs := {"t": "chunk", "tiles": [5, 3, 7, 2000]}
	MessageDecode.prepare(runs, "chunk")
	var tcv := ChunkView.new()
	tcv.set_tiles_rle([5, 3, 7, 2000])
	check(chart.get("_img") is Image and (chart["_img"] as Image).get_pixel(1, 0).r8 == 200 and not chart.has("px")
		and not bad.has("_img") and bad.has("px") and runs.get("_tiles") == tcv.tile_ids,
		"charts' pictures and chunks' tiles decoded off the main thread, as the main thread did; odd ones left as they came")
	tcv.free()

	# The ground's array: made with room, then a new kind of ground is one layer written.
	var saved := [TerrainTextures._images.duplicate(), TerrainTextures._infos, TerrainTextures._reflects, TerrainTextures._array,
		TerrainTextures._room, TerrainTextures._uploaded, TerrainTextures._dirty]
	var mats: Array = []
	for m: ShaderMaterial in [Visuals.terrain_material(), Visuals.terrain_shore_material(), Visuals.water_material()]:
		mats.append([m, m.get_shader_parameter("tiles"), m.get_shader_parameter("tile_info"), m.get_shader_parameter("textured"),
			m.get_shader_parameter("tile_reflect")])
	TerrainTextures._images.clear()
	TerrainTextures._infos = PackedColorArray()
	TerrainTextures._reflects = PackedFloat32Array()
	TerrainTextures._room = 0
	TerrainTextures._uploaded = 0
	var add_layer := func() -> void:
		var image := Image.create_empty(8, 8, true, Image.FORMAT_RGB8)
		TerrainTextures._images.append(image)
		TerrainTextures._infos.append(Color(10, 1, 1, 1))
		TerrainTextures._reflects.append(1.0)
		TerrainTextures._dirty = true
	var made := TerrainTextures.arrays_made
	var written := TerrainTextures.layers_written
	for i in 3:
		add_layer.call()
	TerrainTextures.commit(true)
	var first: bool = TerrainTextures.arrays_made == made + 1 and TerrainTextures._array.get_layers() == 3 + TerrainTextures.ARRAY_STEP_PLAIN
	add_layer.call()
	TerrainTextures.commit(true)
	var one := TerrainTextures.arrays_made == made + 1 and TerrainTextures.layers_written == written + 1
	for i in TerrainTextures.ARRAY_STEP_PLAIN:
		add_layer.call()
	TerrainTextures.commit(true)
	var grown: bool = TerrainTextures.arrays_made == made + 2 and TerrainTextures._array.get_layers() == 8 + TerrainTextures.ARRAY_STEP_PLAIN
	check(first and one and grown, "the ground's array: made with room, a new kind of ground written into its own layer, made again only when full")
	TerrainTextures._images.assign(saved[0])
	TerrainTextures._infos = saved[1]
	TerrainTextures._reflects = saved[2]
	TerrainTextures._array = saved[3]
	TerrainTextures._room = saved[4]
	TerrainTextures._uploaded = saved[5]
	TerrainTextures._dirty = saved[6]
	for entry: Array in mats:
		var m: ShaderMaterial = entry[0]
		m.set_shader_parameter("tiles", entry[1])
		m.set_shader_parameter("tile_info", entry[2])
		m.set_shader_parameter("textured", entry[3])
		m.set_shader_parameter("tile_reflect", entry[4])
	await get_tree().process_frame


## A model whose shader and vertex format no pipeline has met yet waits out of view while Godot
## compiles them (pipeline_warm.gd); one with a shader and format met already is drawn at once.


func _pipeline_warm() -> void:
	const PipelineWarm := preload("res://scripts/world/pipeline_warm.gd")
	PipelineWarm._read_args()
	var was_enabled := PipelineWarm.enabled
	var was_hold := PipelineWarm.hold_msec
	PipelineWarm.enabled = true
	PipelineWarm.hold_msec = 50
	var holder := Node3D.new()
	add_child(holder)
	PipelineWarm.attach(holder)
	var shader := Shader.new()
	shader.code = "shader_type spatial;\nvoid fragment() { ALBEDO = vec3(0.5); }\n"
	var material := ShaderMaterial.new()
	material.shader = shader
	var make := func() -> ArrayMesh:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, material)
		return mesh
	var a: ArrayMesh = make.call()
	var b: ArrayMesh = make.call()
	var instances := PipelineWarm.instances_made
	var first_held := not PipelineWarm.mesh_ready(a) and PipelineWarm.pending_count() == 1 and PipelineWarm.instances_made == instances + 1
	var same_held := not PipelineWarm.mesh_ready(b) and PipelineWarm.instances_made == instances + 1  # its pipelines on their way: no second instance
	var gen := PipelineWarm.generation
	var until := Time.get_ticks_msec() + 3000
	while PipelineWarm.pending_count() > 0 and Time.get_ticks_msec() < until:
		await get_tree().process_frame
		PipelineWarm.poll()
	var c: ArrayMesh = make.call()
	check(first_held and same_held and PipelineWarm.mesh_ready(a) and PipelineWarm.mesh_ready(b) and PipelineWarm.generation > gen
		and PipelineWarm.mesh_ready(c) and PipelineWarm.instances_made == instances + 1,
		"pipelines: a new shader and vertex format waits out of view, then counts as met; a mesh like it is drawn at once")
	await get_tree().process_frame
	check(holder.get_child(0).get_child_count() == 0, "and its warming instance is gone")
	const ShaderWarmup := preload("res://scripts/world/shader_warmup.gd")
	const FarChunks := preload("res://scripts/world/far_chunks.gd")
	var far_m: ArrayMesh = ShaderWarmup._far_chunk_mesh()
	var far_c: ArrayMesh = ShaderWarmup._far_crown_mesh()
	check(far_m.get_surface_count() == 1 and far_m.surface_get_material(0) == FarChunks.material()
		and far_c.get_surface_count() == 1 and far_c.surface_get_material(0) == FarChunks.crown_material()
		and (far_c.surface_get_format(0) & Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES) == 0,
		"shader warmup builds the far-chunk compressed and uncompressed tree-crown mesh layouts")
	var warm_mode_was := ShaderWarmup.mode
	var warm_msec_was := ShaderWarmup.warmed_msec
	ShaderWarmup.mode = "loaded"
	ShaderWarmup.warmed_msec = -1
	var warm_node := ShaderWarmup.start(holder)
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
		warm_node.queue_free()
	ShaderWarmup.mode = warm_mode_was
	ShaderWarmup.warmed_msec = warm_msec_was
	check(has_color_mm and has_far_mesh and has_far_crown,
		"shader warmup warms colored MultiMeshes (%s), far-chunk (%s) and far-crown meshes (%s)" % [has_color_mm, has_far_mesh, has_far_crown])
	PipelineWarm._preload_warm = ["zz-nonexistent-preload-test"]
	PipelineWarm._preload_warm_i = 0
	PipelineWarm._warm_preloaded()
	check(PipelineWarm._preload_warm.is_empty(), "preloaded pipeline warmup drops unknown models cleanly")
	PipelineWarm.enabled = was_enabled
	PipelineWarm.hold_msec = was_hold
	holder.queue_free()
	await get_tree().process_frame


## The bridge reads datagrams' JSON on a thread of its own (while moving, decoding was about half
## of the main thread's message time).


func _bridge_parsing() -> void:
	# The bridge reads datagrams' JSON on a thread of its own: a bound bridge gets every message, in
	# order, as Dictionaries; numbers that aren't finite are still read and counted.
	var b = load("res://scripts/net/bridge.gd").new()
	add_child(b)
	b.connect_to("127.0.0.1", 35899, 0)  # any free port: fixed ones crossed with another run's
	var got: Array = []
	b.message_received.connect(func(msg: Dictionary) -> void: got.append(int(msg.get("k", -1))))
	var tx := PacketPeerUDP.new()
	tx.set_dest_address("127.0.0.1", b.local_port())
	tx.put_packet('{"t":"welcome","r":1,"v":1,"k":1}'.to_utf8_buffer())
	for d in 4:
		var lines: Array = []
		for i in 50:
			lines.append('{"t":"sky","k":%d}' % (2 + d * 50 + i))
		tx.put_packet("\n".join(lines).to_utf8_buffer())
	tx.put_packet('{"t":"sky","k":202,"x":inf}'.to_utf8_buffer())
	var waited := 0
	while got.size() < 201 and waited < 120:
		await get_tree().process_frame
		waited += 1
	var in_order := got.size() == 201
	for i in got.size():
		in_order = in_order and got[i] == 2 + i
	check(in_order and int(b.stats["packets"]) == 6 and int(b.stats["bad_json"]) == 1 and b._parse_thread != null,
		"the bridge reads its datagrams' JSON on its parsing thread: %d of 201 messages in order, %d datagrams, %d not finite" % [got.size(), int(b.stats["packets"]), int(b.stats["bad_json"])])
	# A console answer is handed over as it is read, and the newest tick read is kept apart from the
	# last handled one (they differ while messages wait their turn).
	var early: Array = []
	b.answer_read.connect(func(msg: Dictionary) -> void: early.append([int(msg.get("id", 0)), b.server_tick]))
	tx.put_packet('{"t":"sky","k":300}\n{"t":"cmdr","k":301,"id":7,"l":[]}'.to_utf8_buffer())
	waited = 0
	while early.is_empty() and waited < 120:
		await get_tree().process_frame
		waited += 1
	check(early.size() == 1 and early[0][0] == 7 and early[0][1] < 300 and b.newest_tick >= 301,
		"a console answer is handed over as its datagram is read, before its turn; the newest tick read is kept: %s, newest %d" % [early, b.newest_tick])
	b.disconnect_from()
	check(b._parse_thread == null and b._io_thread == null, "... and both threads stop with the connection")
	b.queue_free()


## A server on another PC: the bridge's link to the relay beside it (server/relay.py), over TCP, here
## against a stand-in relay (a TCPServer): greeted, commands framed, datagrams in frames read as over
## UDP (a frame split across writes too), a dropped link made again with the last hello first (how the
## relay gives the session its port back), a refusal's reason kept. tools/test_relay.py tests the relay.


func _bridge_relay() -> void:
	var front := load("res://scripts/menu/front_end.gd")
	check(front.parse_address("192.168.1.20:34200") == ["192.168.1.20", 34200] and front.parse_address("pi.local") == ["pi.local", 34200]
		and front.parse_address("34210") == ["127.0.0.1", 34210] and front.parse_address("localhost:5") == ["127.0.0.1", 5]
		and front.parse_address("[fd00::7]:34300") == ["fd00::7", 34300] and front.parse_address("a:b").is_empty()
		and front.parse_address("host:70000").is_empty(),
		"Connect to address reads host:port, a host alone (port 34200), a port alone (this PC) and [IPv6]:port")
	var b = load("res://scripts/net/bridge.gd").new()
	check(not b.through_relay("127.0.0.1") and not b.through_relay("localhost") and not b.through_relay("::1")
		and b.through_relay("192.168.1.20") and b.through_relay("server.local"),
		"a host other than this PC is a server on another PC (through its relay)")
	var swap := load("res://scripts/menu/game_swap.gd")
	var swap_said: String = swap._after_focus(2, false, 0, "192.168.1.20")
	check(swap_said.contains("192.168.1.20") and swap_said.contains("Connect to address") and swap._after_focus(0, false, 0, "192.168.1.20") == "",
		"Ctrl+F9 with the server on another PC and no Factorio window here says how to join it: %s" % swap_said)
	var server := TCPServer.new()
	var port := 0
	for p in range(35870, 35896):
		if server.listen(p, "127.0.0.1") == OK:
			port = p
			break
	add_child(b)
	b.relay_forced = true
	b.connect_to("127.0.0.1", port, 0)
	check(port > 0 and b.via_relay and b.bind_error == OK and b.local_port() == 0 and b.server_on_this_pc(),
		"--relay: the bridge goes through a relay even on this PC, binding no UDP port (the server still counts as on this PC)")
	var got: Array = []
	b.message_received.connect(func(msg: Dictionary) -> void: got.append(int(msg.get("k", -1))))
	var peer: StreamPeerTCP = await _relay_accept(server)
	if peer == null:
		check(false, "the bridge connects to the relay")
		b.disconnect_from()
		server.stop()
		b.queue_free()
		return
	var said := await _relay_read(peer, 4)
	peer.put_data("ZRL1".to_ascii_buffer())
	var hello := await _relay_frame(peer)
	check(said.get_string_from_ascii() == "ZRL1" and str(hello.get("t", "")) == "hello" and str(hello.get("sid", "")) != "",
		"it says it is Zenith, then its hello comes as a frame: %s %s" % [said.get_string_from_ascii(), hello.get("t")])
	peer.put_data(_relay_framed('{"t":"welcome","r":1,"v":1,"k":1}'))
	var lines: Array = []
	for i in 50:
		lines.append('{"t":"sky","k":%d}' % (2 + i))
	var batch := _relay_framed("\n".join(lines))
	peer.put_data(batch.slice(0, 700))  # a frame split across writes
	await get_tree().process_frame
	peer.put_data(batch.slice(700))
	peer.put_data(_relay_framed('{"t":"sky","k":52}'))
	var waited := 0
	while got.size() < 51 and waited < 180:
		await get_tree().process_frame
		waited += 1
	var in_order := got.size() == 51
	for i in got.size():
		in_order = in_order and got[i] == 2 + i
	check(in_order and b.relay_status() == "connected" and b.connected,
		"the relay's frames are the bridge's datagrams, read whole and in order: %d of 51, %s" % [got.size(), b.relay_status()])
	# The link drops: made again, the last hello first.
	peer.disconnect_from_host()
	var again: StreamPeerTCP = await _relay_accept(server, 6000)
	var said_again := PackedByteArray()
	var first := {}
	if again != null:
		said_again = await _relay_read(again, 4)
		first = await _relay_frame(again)
	check(again != null and said_again.get_string_from_ascii() == "ZRL1" and str(first.get("t", "")) == "hello"
		and str(first.get("sid", "")) == str(hello.get("sid", "")),
		"a dropped link is made again, its first frame the last hello (the same session: the relay gives back its port)")
	# A relay that refuses: the reason is kept for the connecting screen.
	if again != null:
		again.put_data("ZRL!".to_ascii_buffer())
		again.put_data(_relay_framed("the relay has 8 Zeniths connected already (--max-clients)"))
	waited = 0
	while not b.relay_status().begins_with("refused") and waited < 180:
		await get_tree().process_frame
		waited += 1
	check(b.relay_status() == "refused: the relay has 8 Zeniths connected already (--max-clients)",
		"a refusal's reason is kept: %s" % b.relay_status())
	b.disconnect_from()
	check(b._io_thread == null and not b.via_relay and b.relay_status() == "", "... and the link closes with the connection")
	server.stop()
	b.queue_free()


func _relay_accept(server: TCPServer, msec := 4000) -> StreamPeerTCP:
	var until := Time.get_ticks_msec() + msec
	while Time.get_ticks_msec() < until:
		if server.is_connection_available():
			return server.take_connection()
		await get_tree().process_frame
	return null


func _relay_read(peer: StreamPeerTCP, n: int, msec := 4000) -> PackedByteArray:
	var until := Time.get_ticks_msec() + msec
	while Time.get_ticks_msec() < until:
		peer.poll()
		if peer.get_available_bytes() >= n:
			return peer.get_data(n)[1]
		await get_tree().process_frame
	return PackedByteArray()


## The next frame from the bridge, as JSON ({} after the time).


func _relay_frame(peer: StreamPeerTCP) -> Dictionary:
	var head := await _relay_read(peer, 4)
	if head.size() < 4:
		return {}
	var size := (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3]
	var body := await _relay_read(peer, size)
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}


func _relay_framed(text: String) -> PackedByteArray:
	var data := text.to_utf8_buffer()
	var out := PackedByteArray([(data.size() >> 24) & 255, (data.size() >> 16) & 255, (data.size() >> 8) & 255, data.size() & 255])
	out.append_array(data)
	return out


## Machines with a state near a point come from their chunks (fx.gd, working_glow.gd), not from a
## pass over every state in the world.


func _working_near() -> void:
	var w := WorldMirror.new()
	add_child(w)
	for c in [Vector2i(0, 0), Vector2i(12, 0)]:
		var cv := ChunkView.new()
		cv.coord = c
		w.chunks[c] = cv
		w.add_child(cv)
	w._add([7, 1, 10 * 256, 10 * 256, 0])
	w._on_states([7, 1, 8, 1])  # 8 has no record yet
	w._add([8, 1, 400 * 256, 10 * 256, 0])  # its record arrives later, far away
	w._add([9, 1, 12 * 256, 12 * 256, 0])  # no state
	var near := w.working_near(Vector2(0, 0), 40.0)
	var far := w.working_near(Vector2(400, 10), 40.0)
	w._remove(7)
	var gone := w.working_near(Vector2(0, 0), 40.0)
	check(near == [7] and far == [8] and gone.is_empty(),
		"machines with a state near a point, from their chunks: %s near, %s far, %s after the near one went" % [near, far, gone])
	w.queue_free()


## Chunk streaming spread over frames (docs/PERFORMANCE-AUDIT.md 4.7): the subscription list without
## a sort, builds that stop part-way and carry on, shadow tiers and unloading a slice a frame. Each
## gives what doing it at once gave, and its queue drains.


func _stream_spread() -> void:
	# The nearest-first order of a square of chunks, worked out without sorting.
	var order := WorldMirror.ring_order(14)
	var square := {}
	var ordered := true
	for i in order.size():
		square[order[i]] = true
		if i > 0 and (order[i] as Vector2i).length_squared() < (order[i - 1] as Vector2i).length_squared():
			ordered = false
	check(order.size() == 29 * 29 and square.size() == order.size() and ordered and order[0] == Vector2i.ZERO,
		"the subscription's order: every chunk of the square once, nearest first (%d)" % order.size())
	# Walking: each step asks for what asking from scratch would (still-wanted chunks kept, chunks of
	# the area cache wanted again at once, the first of the rest while fewer than the allowance are on
	# their way), in the view's order (I18: the way the view looks and moves first, prio_order), and
	# the only other chunks kept are the area cache's, up to WARM_RINGS past the square.
	var was_legacy_w1 := WorldMirror.stream_window_legacy
	var was_lookahead_w1 := WorldMirror.stream_lookahead
	WorldMirror.stream_window_legacy = true
	WorldMirror.stream_lookahead = false
	var sw := WorldMirror.new()
	add_child(sw)
	sw.view_radius = 6
	var same := true
	var in_order := true
	var only_cache := true
	for k in 40:
		sw.set_focus(Vector2(16.0 + k * 9.0, 16.0 - k * 4.0))
		var asked_before := {}
		for c in sw._subscribed:
			asked_before[c] = true
		var coming_before: Dictionary = sw._coming.duplicate()
		var warm_before: Dictionary = sw._warm.duplicate()
		var had: Dictionary = sw.chunks.duplicate()
		sw._update_subscription(WorldMirror.STREAM_STEP)
		# From scratch: wanted in the view's order; still-asked kept, and kept chunks wanted again;
		# then the first new ones while those on their way (not drawn: here those not marked drawn
		# below) stay under the allowance.
		var center := WorldMirror.chunk_of(sw.focus())
		var prio: Array = WorldMirror.prio_order(6, sw._wanted_sector)
		var expect := {}
		var on_way := 0
		# Walking a few at a time; the first steps are a standing start (nothing drawn yet).
		var allowance := WorldMirror.STREAM_MOVING if Time.get_ticks_msec() - sw._moved_msec < WorldMirror.MOVING_FOR * 1000.0 else WorldMirror.STREAM_STILL
		for off: Vector2i in prio:
			if asked_before.has(center + off):
				expect[center + off] = true
				if coming_before.has(center + off) and not sw._drawn(center + off):
					on_way += 1
			elif warm_before.has(center + off) and had.has(center + off):
				expect[center + off] = true
		for off: Vector2i in prio:
			if not expect.has(center + off) and on_way < allowance:
				expect[center + off] = true
				on_way += 1
		var got := {}
		for c in sw._subscribed:
			got[c] = true
		same = same and got == expect
		for c: Vector2i in sw.chunks:
			if not got.has(c) and not (sw._warm.has(c) and sw._past_square(c) <= WorldMirror.WARM_RINGS):
				only_cache = false
		var rank := {}
		for i in prio.size():
			rank[prio[i]] = i
		for i in range(1, sw._subscribed.size()):
			if int(rank.get(sw._subscribed[i] - center, -1)) < int(rank.get(sw._subscribed[i - 1] - center, -1)):
				in_order = false
		# Half the chunks on their way arrive (no ground, nothing to build).
		var n := 0
		for c in sw._coming.keys():
			n += 1
			if n % 2 == 0:
				var acv: ChunkView = sw.chunks[c]
				acv.loaded = true
				acv.tile_ids = PackedInt32Array()
	check(same and in_order and only_cache,
		"walking, the subscription asks for what asking from scratch would, in the view's order, and keeps only those chunks and the area cache (same %s, order %s, cache %s)"
		% [same, in_order, only_cache])
	for f in 400:
		sw._free_unloaded()
		if sw._unloaded.is_empty():
			break
	check(sw._unloaded.is_empty() and sw._unload_keys.is_empty(), "and the chunks left behind are all freed over frames")
	sw.queue_free()
	WorldMirror.stream_window_legacy = was_legacy_w1
	WorldMirror.stream_lookahead = was_lookahead_w1
	# The furthest view (50 chunks: 101x101) is all within what the bridge subscribes to, and goes as
	# rows of runs (square_rows): the same chunks back, the whole square in a small message (as a
	# list of chunks it was about 120 KB, more than a datagram).
	var big := WorldMirror.new()
	add_child(big)
	big.view_radius = WorldMirror.MAX_VIEW_RADIUS
	big.set_focus(Vector2(16.0, 16.0))
	big._update_subscription(WorldMirror.STREAM_STEP)
	# A bridge from before (no welcome `sq`) takes a list of its nearest 625 only.
	var old_bridge := big._wanted.size() == WorldMirror.LIST_MAX
	var sq_was: int = Bridge.square_subs
	Bridge.square_subs = WorldMirror.MAX_VIEW_RADIUS
	big._update_subscription(WorldMirror.STREAM_STEP)
	Bridge.square_subs = sq_was
	var bside := WorldMirror.MAX_VIEW_RADIUS * 2 + 1
	var all_wanted := old_bridge and big._wanted.size() == bside * bside and bside * bside <= WorldMirror.MAX_SUBSCRIPTIONS
	var bc := WorldMirror.chunk_of(big.focus())
	var some: Array = []
	var some_set := {}
	for c: Vector2i in big._wanted:
		if (c.x + 2 * c.y) % 3 != 0 or c.y == bc.y:
			some.append(c)
			some_set[c] = true
	var rows_back := {}
	for row: Array in WorldMirror.square_rows(bc, WorldMirror.MAX_VIEW_RADIUS, some):
		for i in range(1, row.size(), 2):
			for x in range(int(row[i]), int(row[i]) + int(row[i + 1])):
				rows_back[Vector2i(x, int(row[0]))] = true
	var full_bytes := JSON.stringify({"t": "sub", "o": [bc.x, bc.y], "r": WorldMirror.MAX_VIEW_RADIUS,
		"w": WorldMirror.square_rows(bc, WorldMirror.MAX_VIEW_RADIUS, big._wanted)}).length()
	check(all_wanted and rows_back == some_set and full_bytes < 4000,
		"view distance 50 wants its whole square (%d chunks), and its rows of runs give the same chunks back in %d bytes" % [big._wanted.size(), full_bytes])
	# Past COARSE_FROM chunks the ground is a quad per 4x4 tiles (its most common tile), and a chunk
	# keeps the ground it has within COARSE_SLACK rings either way.
	var meshed: Array = []
	for coarse in [false, true]:
		var job: RefCounted = WorldMirror.TerrainMesher.new()
		job.coarse = coarse
		var ids := PackedInt32Array()
		ids.resize(32 * 32)
		ids[5] = 1  # one other tile: a block's most common tile wins
		job.tile_ids = ids
		for i in 9:
			job.around.append(ids)
		job.colors = PackedColorArray([Color.DARK_GREEN, Color.SADDLE_BROWN])
		job.kind_of = PackedByteArray([0, 0])
		job.run()
		meshed.append(job.land.verts.size())
	# Each tile family's own roughness and specular (owner: paving glared pale with the sun low behind):
	# matte paving and ground, the code each land vertex carries in CUSTOM1.w, and the shader reading it.
	var concrete := TerrainTextures.surface_of("refined-hazard-concrete-left")
	var grass_s := TerrainTextures.surface_of("grass-1")
	var path_s := TerrainTextures.surface_of("stone-path")
	var all_matte := true
	for tn in ["concrete", "hazard-concrete-left", "refined-concrete", "stone-path", "landfill", "dirt-3", "sand-1",
			"grass-2", "red-desert-0", "volcanic-ash-flats", "space-platform-foundation", "ice-smooth"]:
		var su := TerrainTextures.surface_of(tn)
		all_matte = all_matte and su.x > 0.79 and su.y < 0.16
	var code := TerrainTextures.surface_code(concrete)
	var sjob: RefCounted = WorldMirror.TerrainMesher.new()
	var sids := PackedInt32Array()
	sids.resize(32 * 32)
	sjob.tile_ids = sids
	for i in 9:
		sjob.around.append(sids)
	var sg := TerrainTextures.TileGfx.new()
	sg.name = "refined-hazard-concrete-left"
	sg.surface = code
	sjob.gfx_of = [sg]
	sjob.colors = PackedColorArray([Color.GRAY])
	sjob.kind_of = PackedByteArray([0])
	sjob.run()
	var tshader: String = FileAccess.get_file_as_string("res://shaders/terrain_common.gdshaderinc")
	check(all_matte and concrete == Vector2(0.88, 0.12) and grass_s == TerrainTextures.NATURAL_SURFACE and is_equal_approx(TerrainTextures.surface_code(grass_s), TerrainTextures.NATURAL_CODE) and path_s.x > 0.9
		and is_equal_approx(floorf(code) * 0.01, 0.88) and is_equal_approx(fposmod(code, 1.0), 0.12)
		and sjob.land.custom1.size() > 3 and is_equal_approx(sjob.land.custom1[3], code)
		and tshader.contains("per_tile_surface && masks.w > 0.5"),
		"ground tiles are matte by family (concrete %s, grass %s), carried per vertex (%.2f) to terrain.gdshader" % [concrete, grass_s, code])
	# Grass and ground plants: low specular and fully rough, so a low sun behind them doesn't light a white sheen.
	var plants_matte := true
	for sp in ["decorative_grass", "decorative_carpet", "decorative_flat", "decorative_sheet"]:
		var sc: String = (load("res://shaders/%s.gdshader" % sp) as Shader).code
		# The optimised shaders draw no specular at all; --grass-opt=old's copies keep the low plant specular.
		plants_matte = plants_matte and sc.contains("specular_disabled") and not sc.contains("SPECULAR =") and (load("res://shaders/%s_old.gdshader" % sp) as Shader).code.contains("SPECULAR = plant_specular()")
	var inc := FileAccess.get_file_as_string("res://shaders/decorative_grass.gdshaderinc")
	check(plants_matte and inc.contains("const float PLANT_SPECULAR = 0.05;") and not DecorativeLayer.old_sheen_on,
		"grass and flat plants take the low plant specular (--grass-backlight=old for 0.2.2's)")
	var far_cv := ChunkView.new()
	var gone_far := big._wants_coarse(far_cv, Vector2i(WorldMirror.COARSE_FROM + 1, 0), Vector2i.ZERO)
	var near_cv := ChunkView.new()
	near_cv.loaded = true  # no tiles: drawn (empty), and full
	var kept_full := not big._wants_coarse(near_cv, Vector2i(WorldMirror.COARSE_FROM + WorldMirror.COARSE_SLACK, 0), Vector2i.ZERO)
	far_cv.free()
	near_cv.free()
	check(meshed[0] == 32 * 32 * 4 and meshed[1] == 8 * 8 * 4 and gone_far and kept_full,
		"far ground is a quad per 4x4 tiles (%d vertices, not %d), past %d chunks, kept full within the slack" % [meshed[1], meshed[0], WorldMirror.COARSE_FROM])
	big.queue_free()
	# A build stopped part-way and carried on draws exactly what one build at once draws.
	var protos := ProtoDB.new()
	protos.add_entities([[1, "zz-test-box", "container", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[2, "zz-test-plant", "plant", -0.5, -0.5, 0.5, 0.5, 30, 160, 30, 1, 1]])
	var whole := ChunkView.new()
	var sliced := ChunkView.new()
	add_child(whole)
	add_child(sliced)
	for unit in range(1, 1201):
		for cv: ChunkView in [whole, sliced]:
			var r := WorldMirror.Rec.new()
			r.key = unit
			r.unit = unit
			r.proto_id = 1 + unit % 2
			r.pos = Vector2(float(unit % 32) + 0.5, float(unit / 32 % 32) + 0.5)
			cv.entities[unit] = r
	whole.build_entities(protos, {})
	sliced.build_entities(protos, {}, null, null, Time.get_ticks_usec())  # out of time at once
	var stopped := sliced.building
	var resumes := 0
	while sliced.building and resumes < 10000:
		sliced.resume_build(Time.get_ticks_usec())
		resumes += 1
	var alike := whole._nodes.size() == sliced._nodes.size() and whole._nodes.size() == 2
	for key in whole._nodes:
		var a: MultiMesh = whole._nodes[key].multimesh
		var b: MultiMesh = sliced._nodes[key].multimesh if sliced._nodes.has(key) else null
		alike = alike and b != null and a.instance_count == b.instance_count
		if alike:
			for i in a.instance_count:
				alike = alike and a.get_instance_transform(i) == b.get_instance_transform(i) and a.get_instance_color(i) == b.get_instance_color(i)
	check(stopped and resumes > 1 and not sliced.building and alike,
		"a build that runs out of time stops part-way and carries on (%d more slices), drawing what one build at once draws" % resumes)
	whole.queue_free()
	sliced.queue_free()
	# In the world: busy chunks are built over frames within the frame's time, and the queue drains.
	var bw := WorldMirror.new()
	add_child(bw)
	bw.protos = protos
	for i in 4:
		var c := Vector2i(i, 0)
		var bcv := ChunkView.new()
		bcv.coord = c
		bw.chunks[c] = bcv
		bw.add_child(bcv)
		for j in 1500:
			bw._add([i * 10000 + j + 1, 1 + j % 2, (i * 32 + j % 32) * 256 + 128, (j / 32 % 32) * 256 + 128, 0])
	var frames := 0
	var went_partial := false
	while (not bw._dirty.is_empty() or not bw._partial.is_empty() or not bw._pending.is_empty() or not bw._prep_jobs.is_empty()) and frames < 500:
		bw._rebuild_dirty()
		went_partial = went_partial or not bw._partial.is_empty()
		if not bw._prep_jobs.is_empty() and bw._dirty.is_empty() and bw._partial.is_empty():
			OS.delay_msec(1)
		frames += 1
	var drawn := 0
	for c in bw.chunks:
		var box: MultiMeshInstance3D = (bw.chunks[c] as ChunkView)._nodes.get("box")
		drawn += box.multimesh.instance_count if box != null else 0
	check(bw._dirty.is_empty() and bw._partial.is_empty() and bw._prep_jobs.is_empty() and drawn == 4 * 750,
		"busy chunks are built within the frame's time and the queue drains: %d frames, %d boxes (stopped part-way: %s)" % [frames, drawn, went_partial])
	# Shadow tiers are set a slice a frame: the same tiers and count as all at once, and the pass ends.
	var cam := Camera3D.new()
	cam.fov = 35.0
	add_child(cam)
	cam.current = true
	cam.look_at_from_position(Vector3(13.6, 23.0, 13.6), Vector3.ZERO)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	sun.directional_shadow_max_distance = 150.0
	sun.shadow_enabled = true
	add_child(sun)
	var region := WorldMirror.shadow_region(cam, sun)
	var agree := true
	var meeting := 0
	for cy in range(-12, 13):
		var row := WorldMirror.hull_row(region, cy * 32.0, cy * 32.0 + 32.0)
		for cx in range(-12, 13):
			var rect := Rect2(cx * 32.0, cy * 32.0, 32.0, 32.0)
			var by_row := row.x <= rect.end.x and row.y >= rect.position.x
			agree = agree and WorldMirror._rect_meets_hull(rect, region) == by_row
			meeting += 1 if by_row else 0
	check(agree and meeting > 0 and meeting < 625,
		"the shadow region's reach along each row of chunks gives the hull test's answers (%d of 625 chunks meet it)" % meeting)
	var sh := WorldMirror.new()
	sh.sun = sun
	add_child(sh)
	for y in range(-8, 9):
		for x in range(-8, 9):
			var scv := ChunkView.new()
			scv.coord = Vector2i(x, y)
			sh.chunks[scv.coord] = scv
			sh.add_child(scv)
	sh.shadow_usec = 1 << 40
	sh._update_shadow_casters()
	var tiers := {}
	for c in sh.chunks:
		tiers[c] = (sh.chunks[c] as ChunkView).shadow_tier
	var casters := sh.shadow_casters
	for scv: ChunkView in sh.chunks.values():
		scv.set_shadow_tier(ChunkView.SHADOWS_NEAR if scv.shadow_tier == ChunkView.SHADOWS_NONE else ChunkView.SHADOWS_NONE)
	sh.shadow_casters = -1
	sh._shadow_key = []
	sh.shadow_usec = -1  # one chunk a frame
	sh._update_shadow_casters()
	var calls := 1
	var spread := int(sh.stream_queues()["shadow"]) > 0
	while int(sh.stream_queues()["shadow"]) > 0 and calls < 20000:  # a finished level of detail starts a pass again
		sh._update_shadow_casters()
		calls += 1
	var same_tiers := true
	for c in sh.chunks:
		same_tiers = same_tiers and (sh.chunks[c] as ChunkView).shadow_tier == tiers[c]
	check(spread and same_tiers and sh.shadow_casters == casters and calls >= sh.chunks.size(),
		"shadow tiers set a chunk a frame end as all at once: %d calls, %d casters" % [calls, sh.shadow_casters])
	sh.queue_free()
	# Unloading: the records leave `entities` over frames (not a record of a chunk asked for again
	# meanwhile), entities_changed goes out, and the chunk is freed.
	var changed: Array = []
	bw.entities_changed.connect(func(c: Vector2i) -> void: changed.append(c))
	var gone: ChunkView = bw.chunks[Vector2i(0, 0)]
	var other: ChunkView = bw.chunks[Vector2i(1, 0)]
	bw._unload(Vector2i(0, 0))
	bw._unload(Vector2i(1, 0))
	var kept_at_first := bw.entities.has(1) and bw.entities.has(10001)
	# Chunk (1, 0) comes back at once with one record of the same key.
	var back := ChunkView.new()
	back.coord = Vector2i(1, 0)
	bw.chunks[back.coord] = back
	bw.add_child(back)
	bw._add([10001, 1, 32 * 256 + 128, 128, 0])
	var free_frames := 0
	while not bw._unloaded.is_empty() and free_frames < 1000:
		bw._free_unloaded()
		free_frames += 1
	check(kept_at_first and not bw.entities.has(1) and not bw.entities.has(1500) and bw.entities.has(10001)
		and bw.entities[10001].chunk == Vector2i(1, 0) and not bw.entities.has(10002) and changed.has(Vector2i(0, 0))
		and not is_instance_valid(gone) and not is_instance_valid(other),
		"unloaded chunks' records go over %d frames (a chunk asked for again keeps its own), then the chunks are freed" % free_frames)
	bw.queue_free()
	sun.queue_free()
	cam.queue_free()
	await get_tree().process_frame


## Far chunks merged (far_chunks.gd): a chunk going far keeps its MultiMeshes until its merged mesh
## (buildings, tree trunks and opaque tree crowns) is made, then hides them without a build; kept
## types like ore keep theirs; coming near again before anything changed shows them again at once; what
## it holds changing lets them go and merges again; picking still finds its entities; coming near after
## that, its MultiMeshes are made again and the merged mesh goes once they are all in. Bakes and
## merges run on worker threads, so this waits for them.


func _far_chunks() -> void:
	var w := WorldMirror.new()
	add_child(w)
	w.protos.add_entities([[1, "steel-chest", "container", -0.35, -0.35, 0.35, 0.35, 200, 180, 0, 1, 1],
		[2, "zz-test-box", "container", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[3, "tree-01", "tree", -0.4, -0.4, 0.4, 0.4, 30, 160, 30, 1, 1],
		[4, "iron-ore", "resource", -0.5, -0.5, 0.5, 0.5, 100, 120, 140, 1, 1]])
	# Made now rather than on a worker, so the first build draws them.
	ModelLibrary.mesh_for_entity("steel-chest", "container", {}, 0)
	ModelLibrary.mesh_for_entity("iron-ore", "resource", {}, 0)
	var tree_mesh := ModelLibrary.mesh_for_entity("tree-01", "tree", {}, 0)
	var ore_until := Time.get_ticks_msec() + 10000
	while ModelLibrary.ore_rocks("iron-ore") == null and Time.get_ticks_msec() < ore_until:
		ModelLibrary.poll()
		await get_tree().process_frame
	var c := Vector2i(12, 0)  # 384 tiles from the focus at the origin: far from any camera there
	var cv := ChunkView.new()
	cv.coord = c
	cv.loaded = true
	w.chunks[c] = cv
	w.add_child(cv)
	var add := func(unit: int, proto: int, x: float) -> void:
		var r := WorldMirror.Rec.new()
		r.key = unit
		r.unit = unit
		r.proto_id = proto
		r.pos = Vector2(c.x * 32 + x, 3.5)
		r.chunk = c
		cv.entities[unit] = r
		w.entities[unit] = r
	add.call(1, 1, 1.5)
	add.call(2, 2, 3.5)
	add.call(3, 3, 5.5)
	add.call(4, 4, 9.5)
	var fc = w.far_chunks
	var shown := func() -> int: return cv._instances.filter(func(m: MultiMeshInstance3D) -> bool: return m.visible).size()
	var wait_merged := func() -> void:
		var until := Time.get_ticks_msec() + 20000
		while Time.get_ticks_msec() < until and not (cv.far.node != null and cv.far.node.visible and cv.far.phase == 0):
			await get_tree().process_frame
	fc.enabled = false
	cv.build_entities(w.protos, {})
	var full_shown := int(shown.call())
	check(full_shown >= 4 and cv._instances.size() == full_shown and not cv.far.far and cv.far.full,
		"a chunk is built in full while merging is off: %d MultiMeshes" % full_shown)
	# Merging on: far, its merged mesh is made on workers and its MultiMeshes are hidden, not rebuilt.
	fc.enabled = true
	var kept_meanwhile := true
	var until := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < until and not (cv.far.node != null and cv.far.node.visible):
		kept_meanwhile = kept_meanwhile and shown.call() == full_shown
		await get_tree().process_frame
	var node: MeshInstance3D = cv.far.node
	var mesh: ArrayMesh = node.mesh if node != null else null
	var crown_uvs := PackedVector2Array()
	var crown_fmt := 0
	var tree_pos := Vector2(c.x * 32 + 5.5, 3.5)
	if mesh != null and mesh.get_surface_count() >= 3:
		crown_fmt = mesh.surface_get_format(2)
		var ca := mesh.surface_get_arrays(2)
		if ca[Mesh.ARRAY_TEX_UV] is PackedVector2Array:
			crown_uvs = ca[Mesh.ARRAY_TEX_UV]
	check(cv.far.far and node != null and node.visible and kept_meanwhile and mesh != null and mesh.get_surface_count() == 3
		and (mesh.surface_get_format(0) & Mesh.ARRAY_FORMAT_COLOR) != 0 and mesh.surface_get_material(0) == fc.material()
		and (mesh.surface_get_format(1) & Mesh.ARRAY_FORMAT_COLOR) != 0 and mesh.surface_get_material(1) == fc.nature_material()
		and mesh.surface_get_material(2) == fc.crown_material() and (crown_fmt & Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES) == 0
		and not crown_uvs.is_empty() and crown_uvs[0].is_equal_approx(tree_pos),
		"far, buildings become surface 0, tree trunks surface 1 and tree crowns surface 2 with uncompressed world UV (%s)" % [
			crown_uvs[0] if not crown_uvs.is_empty() else Vector2.ZERO])
	# Outward clockwise winding on baked crown octahedron puffs.
	var tree_bake: FarChunks.Bake = FarChunks._bakes.get(tree_mesh)
	var puffs_ok := tree_bake != null and tree_bake.crown_verts.size() >= 6 and tree_bake.crown_indices.size() >= 24
	if puffs_ok:
		var bv := tree_bake.crown_verts
		var bi := tree_bake.crown_indices
		for off in range(0, bv.size(), 6):
			var center := Vector3.ZERO
			for vi in 6:
				center += bv[off + vi]
			center /= 6.0
			var tri_base := (off / 6) * 24
			for ti in range(tri_base, tri_base + 24, 3):
				var a := bv[bi[ti]]
				var b := bv[bi[ti + 1]]
				var d := bv[bi[ti + 2]]
				if (b - a).cross(d - a).dot((a + b + d) / 3.0 - center) >= 0.0:
					puffs_ok = false
					break
	check(puffs_ok, "far tree crown octahedron puffs wind clockwise outward")
	var tree_mmi: MultiMeshInstance3D = cv._nodes.get(tree_mesh)
	check(shown.call() == full_shown - 3 and tree_mmi != null and not tree_mmi.visible and cv.far.hidden.has(tree_mmi)
		and cv.far.hidden.size() == 3 and not w._dirty.has(c),
		"the chest, box and tree MultiMeshes are hidden with no build; kept types like ore stay visible: %d shown" % shown.call())
	cv.set_shadow_tier(ChunkView.SHADOWS_NONE)
	var no_shadow := node.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cv.set_shadow_tier(ChunkView.SHADOWS_FAR)
	check(no_shadow and node.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		"the merged mesh casts the chunk's shadows where they can reach the view, and none beyond")
	check(w.pick(Vector2(c.x * 32 + 1.5, 3.5)) == cv.entities[1], "picking still finds a merged building")
	# The focus walks up before anything changed: the MultiMeshes are shown again, at once.
	w.set_focus(Vector2(c.x * 32 + 16, 16))
	until = Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < until and cv.far.far:
		await get_tree().process_frame
	check(not cv.far.far and shown.call() == full_shown and cv.far.node == null and cv.far.hidden.is_empty() and not w._dirty.has(c),
		"near again with nothing changed: its MultiMeshes are shown again and the merged mesh goes, with no build")
	# Away again, then something built there: the build lets the hidden MultiMeshes go and merges again.
	w.set_focus(Vector2.ZERO)
	await wait_merged.call()
	node = cv.far.node
	var one: int = cv.far.triangles
	add.call(5, 1, 7.5)
	cv.build_entities(w.protos, {})
	check(node != null and node.visible and cv._instances.size() == full_shown - 3 and cv.far.hidden.is_empty() and not cv.far.full,
		"a building added far away lets the hidden MultiMeshes go; the old merged mesh stays meanwhile")
	until = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < until and cv.far.triangles == one:
		await get_tree().process_frame
	check(cv.far.triangles > one and cv.far.node == node, "and the merged mesh is made again with it (%d -> %d triangles)" % [one, cv.far.triangles])
	# Near after that: its MultiMeshes are made within the budget, the merged mesh drawn until the last is in.
	w.set_focus(Vector2(c.x * 32 + 16, 16))
	until = Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < until and not w._dirty.has(c):
		await get_tree().process_frame
	w._dirty.erase(c)
	cv.build_entities(w.protos, {}, null, ChunkView.Budget.new(1))
	check(not cv.far.far and not cv.pending.is_empty() and is_instance_valid(node) and node.visible,
		"near again after a change, the chunk is built in full; the merged mesh stays while MultiMeshes are still to come")
	cv.add_pending({}, null, ChunkView.Budget.new(100))
	check(shown.call() == full_shown and cv.far.node == null and cv.far.full,
		"and goes once they are all in (%d shown, merged mesh %s, full %s)" % [shown.call(), cv.far.node, cv.far.full])
	var t6_mesh := ModelLibrary.mesh_for_entity("tree-06", "tree", {}, 0)
	var b6 := fc._bake_for(t6_mesh)
	until = Time.get_ticks_msec() + 5000
	while b6 == null and Time.get_ticks_msec() < until:
		await get_tree().process_frame
		b6 = fc._bake_for(t6_mesh)
	check(b6 != null and b6.indices.size() >= 3 and b6.crown_indices.size() >= 3,
		"solid-leaf trees (tree-06) also bake trunk and crown for far chunks (%d/%d)" % [
			b6.indices.size() / 3 if b6 != null else 0, b6.crown_indices.size() / 3 if b6 != null else 0])
	var was_far_trees := FarChunks.far_trees
	FarChunks.far_trees = false
	check(not FarChunks.merges("tree", tree_mesh) and not FarChunks.bakeable(tree_mesh),
		"--far-trees=off keeps trees unmerged in far chunks")
	FarChunks.far_trees = was_far_trees
	# With a graphics list a building without a model is a card, far away too: never merged as a box.
	var kept_fp := ModGraphics.fingerprint
	check(FarChunks.merges("container", null), "without a list a placeholder box is merged far away")
	ModGraphics.fingerprint = "a list"
	check(not FarChunks.merges("container", null), "with a list a mod's building keeps its card far away, not a merged box")
	ModGraphics.fingerprint = kept_fp
	# Screen-size far merging (S9): hysteresis band in perspective, none in orthographic, and 4K capped at 1080p.
	check(FarChunks.merge_at(FarChunks.MERGE_BELOW_PX - 0.5, false, false)
		and FarChunks.merge_at(FarChunks.MERGE_BELOW_PX + 1.0, true, false)
		and not FarChunks.merge_at(FarChunks.MERGE_BELOW_PX + 1.0, false, false)
		and not FarChunks.merge_at(FarChunks.FULL_ABOVE_PX + 0.5, true, false)
		and not FarChunks.merge_at(FarChunks.MERGE_BELOW_PX + 0.5, true, true),
		"far merge_at: hysteresis in perspective, no gap in orthographic")
	var svp_fhd := SubViewport.new()
	svp_fhd.size = Vector2i(1920, 1080)
	var svp_uhd := SubViewport.new()
	svp_uhd.size = Vector2i(3840, 2160)
	var cam_50 := Camera3D.new()
	cam_50.fov = 50.0
	var cam_60 := Camera3D.new()
	cam_60.fov = 60.0
	var d_fhd := FarChunks.screen_distances(cam_50, svp_fhd)
	var d_uhd := FarChunks.screen_distances(cam_50, svp_uhd)
	var d_wide := FarChunks.screen_distances(cam_60, svp_fhd)
	check(d_fhd.is_equal_approx(d_uhd) and d_fhd.x > 100.0 and d_fhd.x < 125.0 and d_fhd.y < d_fhd.x and d_wide.x < d_fhd.x,
		"far screen_distances: 4K matches 1080p (%.1f vs %.1f), wider FOV merges sooner (%.1f)" % [d_uhd.x, d_fhd.x, d_wide.x])
	cam_50.free()
	cam_60.free()
	svp_fhd.free()
	svp_uhd.free()
	# Far -> near race: an in-flight merged worker ChunkPrepJob must be cancelled and redrawn whole.
	check(FarChunks.prep_guard, "far prep_guard is on by default")
	w.set_focus(Vector2.ZERO)
	until = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < until and not (cv.far.far and cv.far.node != null and cv.far.node.visible and cv.far.phase == 0 and cv.far.full):
		await get_tree().process_frame
	await cv.collect_entities(w.protos, {})
	var merged_job: ChunkView.ChunkPrepJob = cv._prep_pending
	cv._prep_pending = null
	var race_setup: bool = merged_job != null and bool(merged_job.merged)
	if race_setup:
		merged_job.run()
		merged_job.task_id = -1
		w._prep_jobs[c] = merged_job
	w.set_focus(Vector2(c.x * 32 + 16, 16))
	until = Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < until and (cv.far.far or not w._prep_jobs.is_empty() or not w._dirty.is_empty() or not w._partial.is_empty() or not w._pending.is_empty()):
		await get_tree().process_frame
	check(race_setup and not cv.far.far and cv.far.full and cv.far.node == null and shown.call() == full_shown,
		"coming near cancels an in-flight merged worker prep job and rebuilds full MultiMeshes (far=%s full=%s node=%s shown=%d/%d)" % [
			cv.far.far, cv.far.full, cv.far.node, shown.call(), full_shown])
	w.queue_free()


## Belts small on screen (belt_lods.gd): each kind gets a stand-in of a few triangles with the belt
## surface's top where the model has it; a chunk's belts are drawn whole near the camera, as their
## stand-ins far away (no shadow, the model's shadow stand-in hidden with it) or in a wide
## orthographic view, and whole again only once a tile is drawn FULL_ABOVE pixels (hysteresis).


func _distant_horizon_integration() -> void:
	# 1. Bridge lod capability negotiation (hello.lod and welcome.lod + disconnect reset).
	var was_dh_en: bool = Bridge.distant_horizon_enabled
	var was_lod_sup: bool = Bridge.lod_supported
	var was_conn: bool = Bridge.connected
	var was_cap: Variant = Bridge.capture
	Bridge.capture = []

	Bridge.capture.clear()
	Bridge.distant_horizon_enabled = true
	Bridge._send_hello()
	var hello_on: Dictionary = {}
	if not (Bridge.capture as Array).is_empty():
		var p1: Variant = JSON.parse_string(str((Bridge.capture as Array)[-1]))
		if p1 is Dictionary:
			hello_on = p1
	Bridge.capture.clear()
	Bridge.distant_horizon_enabled = false
	Bridge._send_hello()
	var hello_off: Dictionary = {}
	if not (Bridge.capture as Array).is_empty():
		var p2: Variant = JSON.parse_string(str((Bridge.capture as Array)[-1]))
		if p2 is Dictionary:
			hello_off = p2
	Bridge.capture.clear()
	check(int(hello_on.get("lod", 0)) == 1 and not hello_off.has("lod"),
		"Bridge hello carries lod=1 when distant_horizon_enabled and omits it when off")

	Bridge.connected = false
	Bridge._handle({"t": "welcome", "v": Bridge.PROTOCOL, "r": 1, "lod": 1})
	var sup_on: bool = Bridge.lod_supported
	Bridge._handle({"t": "welcome", "v": Bridge.PROTOCOL, "r": 2})
	var sup_off: bool = Bridge.lod_supported
	Bridge._handle({"t": "welcome", "v": Bridge.PROTOCOL, "r": 3, "lod": 1})
	Bridge.disconnect_from()
	var sup_disc: bool = Bridge.lod_supported
	check(sup_on and not sup_off and not sup_disc,
		"Bridge welcome sets lod_supported on lod=1 and disconnect_from clears it")

	Bridge.distant_horizon_enabled = was_dh_en
	Bridge.lod_supported = was_lod_sup
	Bridge.connected = was_conn
	Bridge.capture = was_cap

	# 2. FullDetail.cover() reduced reach when distant_horizon + distant_horizon_shots are active vs COVER_REACH.
	var sv := SubViewport.new()
	sv.size = Vector2i(800, 600)
	add_child(sv)
	var cam := Camera3D.new()
	cam.fov = 55.0
	cam.far = 16000.0
	sv.add_child(cam)
	cam.position = Vector3(0.0, 60.0, 0.0)
	cam.rotation_degrees = Vector3(-18.0, 0.0, 0.0)
	cam.make_current()

	var fw_script := GDScript.new()
	fw_script.source_code = "extends Node\nvar last_rect := Rect2i()\nfunc set_cover(r: Rect2i, _near: Vector2i, _view: Callable) -> void:\n\tlast_rect = r\nfunc clear_cover() -> void:\n\tpass\n"
	fw_script.reload()
	var fm_script := GDScript.new()
	fm_script.source_code = "extends Node\nvar world: Object = null\nvar distant_horizon: Object = null\n"
	fm_script.reload()
	var fw: Node = fw_script.new()
	var fm: Node = fm_script.new()
	var dh := DistantHorizon.new()
	sv.add_child(fw)
	sv.add_child(fm)
	sv.add_child(dh)
	fm.set("world", fw)
	fm.set("distant_horizon", dh)

	var was_shots := bool(Settings.get_value("graphics", "distant_horizon_shots"))
	var was_vr := int(Settings.get_value("graphics", "view_radius"))
	Settings.set_value("graphics", "distant_horizon_shots", true)
	dh.enabled = false
	dh.radius_chunks = 0
	FullDetail.cover(fm, true)
	var rect_off: Rect2i = fw.get("last_rect")

	Settings.set_value("graphics", "view_radius", 500)
	dh.enabled = true
	dh.radius_chunks = 500
	FullDetail.cover(fm, true)
	var rect_dh: Rect2i = fw.get("last_rect")

	Settings.set_value("graphics", "distant_horizon_shots", false)
	FullDetail.cover(fm, true)
	var rect_switch_off: Rect2i = fw.get("last_rect")

	FullDetail.cover(fm, false)
	Settings.set_value("graphics", "view_radius", was_vr)
	Settings.set_value("graphics", "distant_horizon_shots", was_shots)
	check(rect_off.size.x >= 90 and rect_off.size.y >= 80 and rect_dh.size.x <= 30 and rect_dh.size.y <= 30 and rect_switch_off == rect_off,
		"FullDetail.cover uses reduced reach with DistantHorizon on even at view_radius=500 (%s) and preserves COVER_REACH when off/switched (%s, %s)" % [rect_dh, rect_off, rect_switch_off])
	sv.free()
	await get_tree().process_frame

	# 3. Looks.fog_distance_scale scales env.fog_density and _env_release() restores it cleanly.
	var env := Environment.new()
	env.fog_enabled = true
	env.fog_density = 0.02
	var sun := DirectionalLight3D.new()
	add_child(sun)
	var lk: Node = LooksScript.new()
	add_child(lk)
	lk.attach(env, sun)
	lk.use("factorio", true)
	lk.fog_distance_scale = 1.0
	lk.apply(0.0, 0.0, "nauvis", false)
	var base_fog: float = env.fog_density
	var held_at_one: bool = lk._scene_held.is_empty()
	lk.fog_distance_scale = 0.25
	lk.apply(0.0, 0.0, "nauvis", false)
	var scaled_fog: float = env.fog_density
	lk._env_release()
	var released_fog: float = env.fog_density
	lk.fog_distance_scale = 1.0
	lk.free()
	sun.free()
	await get_tree().process_frame
	check(held_at_one and is_equal_approx(base_fog, 0.02) and is_equal_approx(scaled_fog, 0.005) and is_equal_approx(released_fog, 0.02),
		"Looks.fog_distance_scale scales fog_density (%.4f -> %.4f) and _env_release restores it (%.4f)" % [base_fog, scaled_fog, released_fog])


func _perf_warning(hud: Hud) -> void:
	var ui = hud.ui
	var pw = ui.perf_warning
	var fb: Button = ui.factorio_button
	check(pw != null and bool(Settings.get_value("interface", "perf_warning")), "perf warning: in the HUD, the setting on by default")
	PerfWarningScript.forced_off = false
	PerfLog.clear()
	PerfLog.test_msec = 1000000
	pw.refresh()
	check(not pw.visible, "perf warning: hidden with nothing in the log")
	# The corner: in the Show in Factorio button's place while that is hidden, right of it while shown.
	var show_was: Callable = ui.show_factorio
	ui.show_factorio = Callable()
	fb.visible = false
	ui.layout()
	var alone: Vector2 = pw.position
	ui.show_factorio = func() -> void: pass
	fb.visible = true
	ui.layout()
	var beside: Vector2 = pw.position
	ui.show_factorio = show_was
	fb.visible = show_was.is_valid()
	ui.layout()
	check(alone == fb.position and beside == fb.position + Vector2(Kit.px(Kit.SLOT + 4), 0.0),
		"perf warning: in the Factorio button's place while it is hidden (%s), right of it while shown (%s, the button at %s)" % [alone, beside, fb.position])
	# A governor driven with made-up ticks, as _ups_governor does.
	var g = UpsGovernor.new()
	add_child(g)
	g.set_process(false)
	var tick := [1000.0]
	_govern(g, tick, 40.0, 60.0)
	check(not pw.visible and PerfLog.entries.is_empty(), "perf warning: at 60 UPS nothing is logged")
	_govern(g, tick, 4.0, 50.0)
	var ups_entries := PerfLog.entries.filter(func(e: Dictionary) -> bool: return e["source"] == "ups")
	check(g.level == 1 and pw.visible and pw.count() == 1 and pw.button.count == 1 and ups_entries.size() == 1,
		"perf warning: a governor step shows the icon with its count (level %d, count %d, %d entries)" % [g.level, pw.count(), ups_entries.size()])
	var budget_e: Dictionary = PerfLog.find_open("budget", "budget")
	check(not budget_e.is_empty() and not budget_e["lights"] and int(budget_e["to"]) < 300 and pw.count() == 1,
		"perf warning: the work budget's cut is logged once, the lowest kept, without lighting the icon: %s" % [budget_e])
	var tip = pw.button.get_meta("tip", [])
	check(tip is Array and str(tip[1][0][0]).contains("updates slowed to level 0 → 1"), "perf warning: the tooltip lists what is held now: %s" % [tip])
	pw.button.pressed.emit()
	var rows: String = pw.rows_text()
	check(pw.is_open() and rows.contains("updates slowed to level 0 → 1") and rows.contains("game at 5") and rows.contains(" UPS for 2 s") and rows.contains("held")
		and pw.panel.find_child("Note", true, false).text.contains("don't light it") and pw.panel.find_child("Copy", true, false) is Button,
		"perf warning: a click opens the log with from → to, its reason, held, the note on what doesn't light it and Copy:\n%s" % rows)
	check(PerfLog.text().contains("updates slowed to level 0 → 1"), "perf warning: Copy's text has the entries")
	# The load goes: the step comes back, the entry is restored, the icon stays LINGER_MSEC and then goes.
	_govern(g, tick, 45.0, 60.0)
	var first: Dictionary = ups_entries[0]
	check(g.level == 0 and first.has("ended_msec") and str(first["ended"]).begins_with("restored, back at 60 for") and pw.count() == 0
		and pw.visible and pw._linger.time_left > 9.0,
		"perf warning: a step back marks the entry restored (%s), the icon stays a while (%s, timer %.1f s)" % [first.get("ended"), pw.visible, pw._linger.time_left])
	pw.refresh()
	await get_tree().process_frame  # the open panel refills once at the frame's end
	rows = pw.rows_text()
	check(rows.contains("restored, back at 60") and not PerfLog.is_open("budget", "budget"), "perf warning: the panel shows it restored; the budget back at 300 restored too:\n%s" % rows)
	PerfLog.test_msec += PerfLog.LINGER_MSEC + 1
	pw.refresh()
	check(not pw.visible and not pw.is_open(), "perf warning: the icon hides 10 s after the last restore")
	g.queue_free()
	# Log only: Automatic moving belt items under half its start, the bridge's belt square cut.
	PerfLog.clear()
	pw.refresh()
	var cap_was: float = BeltLanesScript.auto_cap
	BeltLanesScript.auto_cap = 2000.0
	BeltLanesScript.log_auto("frames at 20.0 ms")
	BeltLanesScript.auto_cap = 1500.0
	BeltLanesScript.log_auto("frames at 20.0 ms")
	var lanes = BeltLanesScript.new()
	lanes.near = 64
	lanes.covered = Vector3(0, 0, 40)
	lanes.log_square()
	var square_soon := PerfLog.is_open("square", "square")
	PerfLog.test_msec += BeltLanesScript.SQUARE_HOLD_MSEC + 1
	lanes.log_square()
	var auto_e: Dictionary = PerfLog.find_open("belts", "auto")
	check(not auto_e.is_empty() and str(auto_e["to"]) == "1500" and not square_soon and PerfLog.is_open("square", "square")
		and PerfLog.entries.size() == 2 and not pw.visible and pw.count() == 0,
		"perf warning: Automatic belt items under half (one entry, lowest %s) and the bridge's belt square cut (after %d ms) are logged, the icon stays off" % [auto_e.get("to"), BeltLanesScript.SQUARE_HOLD_MSEC])
	BeltLanesScript.auto_cap = 6000.0
	BeltLanesScript.log_auto("")
	lanes.covered = Vector3(0, 0, 64)
	lanes.log_square()
	check(not PerfLog.is_open("belts", "auto") and not PerfLog.is_open("square", "square"), "perf warning: both restored once back")
	# Automatic low at 60 UPS on a base with few belts: the cap no longer binds and never grows back, so its entry
	# ends AUTO_FREE_MSEC later (nothing held back) instead of reading "held" for good; binding again opens a new one.
	BeltLanesScript.auto_cap = 1000.0
	BeltLanesScript.log_auto("game at 48.0 UPS")
	BeltLanesScript.log_auto("", false)
	var free_soon := PerfLog.is_open("belts", "auto")
	PerfLog.test_msec += BeltLanesScript.AUTO_FREE_MSEC + 1
	BeltLanesScript.log_auto("", false)
	var freed: Dictionary = PerfLog.entries.filter(func(e: Dictionary) -> bool: return e["source"] == "belts")[-1]
	var freed_ok: bool = free_soon and not PerfLog.is_open("belts", "auto") and str(freed.get("ended", "")).begins_with("nothing held back now")
	BeltLanesScript.log_auto("", false)
	var stays_ended := not PerfLog.is_open("belts", "auto")
	BeltLanesScript.auto_cap = 1200.0
	BeltLanesScript.log_auto("", true)
	var again: Dictionary = PerfLog.find_open("belts", "auto")
	check(freed_ok and stays_ended and not again.is_empty() and str(again["to"]) == "1200" and str(again["why"]).contains("in reach"),
		"perf warning: Automatic low but not binding ends its entry (%s); binding again opens a new one (%s)" % [freed.get("ended"), again])
	BeltLanesScript.auto_cap = 6000.0
	BeltLanesScript.log_auto("")
	lanes.free()
	BeltLanesScript.auto_cap = cap_was
	# Off: the icon hides, the log still fills.
	Settings.set_value("interface", "perf_warning", false)
	PerfLog.note("ups", "entity", UpsGovernor.LABELS["entity"], "192", "128", "game at 50.0 UPS for 2 s")
	check(not pw.visible and PerfLog.is_open("ups", "entity") and pw.count() == 1, "perf warning: the setting off hides the icon, the log still fills")
	Settings.set_value("interface", "perf_warning", true)
	check(pw.visible, "perf warning: on again, the icon is back")
	# Flipped while the panel is open: the panel closes with the icon, and isn't left open behind it.
	pw.set_open(true)
	Settings.set_value("interface", "perf_warning", false)
	var closed_off: bool = not pw.visible and not pw.is_open()
	Settings.set_value("interface", "perf_warning", true)
	check(closed_off and pw.visible and not pw.is_open(), "perf warning: the setting off with the panel open closes it; on again the icon is back, closed")
	# Entries arriving while the panel is open are drawn at once, newest first.
	pw.set_open(true)
	PerfLog.note("ups", "far", UpsGovernor.LABELS["far"], "96", "64", "game at 49.0 UPS for 2 s")
	await get_tree().process_frame
	var open_rows: String = pw.rows_text()
	check(open_rows.begins_with(PerfLog.entries[-1]["time"] + "   belt item distance 96 → 64") and open_rows.contains("entity distance 192 → 128"),
		"perf warning: an entry arriving with the panel open shows by the next frame, at the top:\n%s" % open_rows)
	PerfLog.restore("ups", "far", "back at 60 for 30 s")
	await get_tree().process_frame
	check(pw.rows_text().contains("restored, back at 60 for 30 s at ") and pw.count() == 1, "perf warning: its restore shows too, the other hold still counted")
	# Copy's lines: time, from → to, (why), [log only], held or restored at, after.
	var copy_lines := PerfLog.text().split("\n")
	check(copy_lines.size() == PerfLog.entries.size() and copy_lines[0].contains("belt item distance 96 → 64 (game at 49.0 UPS for 2 s): restored, back at 60 for 30 s at ")
		and copy_lines[0].ends_with("after 0 s") and copy_lines[1].ends_with("entity distance 192 → 128 (game at 50.0 UPS for 2 s): held"),
		"perf warning: Copy's text, one line an entry, newest first:\n%s" % PerfLog.text())
	# The open panel isn't rebuilt for nothing: an unchanged log keeps its rows, and changes in one frame refill once.
	var row0: Node = pw._rows.get_child(0)
	pw.refresh()
	await get_tree().process_frame
	var kept: bool = is_instance_valid(row0) and pw._rows.get_child(0) == row0
	PerfLog.note("ups", "map", UpsGovernor.LABELS["map"], "1", "2", "game at 49.0 UPS for 2 s")
	PerfLog.lower("ups", "map", "3")
	PerfLog.restore("ups", "map", "back at 60 for 30 s")
	var queued: bool = pw._dirty and pw._rows.get_child(0) == row0
	await get_tree().process_frame
	check(kept and queued and not pw._dirty and pw._filled == PerfLog.version and pw._rows.get_child(0) != row0
		and pw.rows_text().begins_with(PerfLog.entries[-1]["time"] + "   " + PerfLog.what(PerfLog.entries[-1])),
		"perf warning: the open panel keeps its rows while the log is unchanged (%s) and refills once for three changes in a frame (%s)" % [kept, queued])
	# Esc closes the open log first, as Factorio closes an open GUI.
	var esc_handled: bool = ui.escape()
	check(esc_handled and not pw.is_open() and pw.visible, "perf warning: Esc closes the open log panel (the icon stays)")
	pw.set_open(false)
	# The debug menu's row flips the same setting; --perf-warning=off starts it off until the setting changes.
	ui.debug_menu.set_toggle("perfwarn", false)
	var debug_off: bool = not bool(Settings.get_value("interface", "perf_warning")) and not pw.visible
	ui.debug_menu.set_toggle("perfwarn", true)
	check(debug_off and bool(Settings.get_value("interface", "perf_warning")) and pw.visible, "perf warning: the debug menu's row flips the saved setting")
	PerfWarningScript.forced_off = true
	pw.refresh()
	var flag_off: bool = not pw.visible
	Settings.set_value("interface", "perf_warning", true)
	check(flag_off and pw.visible and not PerfWarningScript.forced_off, "perf warning: --perf-warning=off hides it until the setting is changed")
	# With the flag and the saved setting on, both switches show it off (unsaved), and one click turns it on.
	PerfWarningScript.forced_off = true
	pw.refresh()
	ui.debug_menu.open(true)
	var row_btn: Button = ui.debug_menu._toggles.get("perfwarn")
	var row_off: bool = row_btn != null and not row_btn.button_pressed and row_btn.text == "Show"
	if row_btn != null:
		row_btn.button_pressed = true
	var row_one: bool = pw.visible and not PerfWarningScript.forced_off and bool(Settings.get_value("interface", "perf_warning"))
	ui.debug_menu.open(false)
	check(row_off and row_one, "perf warning: under --perf-warning=off the debug row shows it off (%s) and one click shows the icon (%s)" % [row_off, row_one])
	PerfWarningScript.forced_off = true
	pw.refresh()
	var flag_w: Node = SettingsWindow.new()
	add_child(flag_w)
	await get_tree().process_frame
	flag_w.open_tab("Interface")
	var flag_box := flag_w.find_child("interface-perf_warning", true, false) as CheckBox
	var box_off: bool = flag_box != null and not flag_box.button_pressed and bool(Settings.get_value("interface", "perf_warning"))
	if flag_box != null:
		flag_box.button_pressed = true
	check(box_off and pw.visible and not PerfWarningScript.forced_off and bool(Settings.get_value("interface", "perf_warning")),
		"perf warning: under --perf-warning=off Settings > Interface shows it off, the saved setting untouched (%s), and one click shows the icon" % box_off)
	flag_w.queue_free()
	# The cap: 200 entries, the oldest ended ones dropped first.
	for i in 250:
		PerfLog.note("test", str(i), "test %s", "1", "2", "a test", false)
		PerfLog.restore("test", str(i), "")
	check(PerfLog.entries.size() == PerfLog.CAP and PerfLog.is_open("ups", "entity"), "perf warning: the log holds %d (%d), the open hold kept" % [PerfLog.CAP, PerfLog.entries.size()])
	# A public build (no dev tools) still has the setting in Settings > Interface.
	Settings.dev_tools_override = 0
	var w: Node = SettingsWindow.new()
	add_child(w)
	await get_tree().process_frame
	w.open_tab("Interface")
	var box := w.find_child("interface-perf_warning", true, false)
	check(box is CheckBox and (box as CheckBox).button_pressed, "perf warning: a public build has the setting in Settings > Interface")
	ui.debug_menu.open(true)
	check(not ui.debug_menu.is_open(), "perf warning: a public build has no debug menu, so no debug row")
	Settings.dev_tools_override = -1
	w.queue_free()
	PerfLog.clear()
	PerfLog.test_msec = -1
	pw.refresh()
	await get_tree().process_frame


## Feeds the governor `secs` of frames at `ups` (a Callable of its level, or a number), 0.1 s each.


func _budget_fast() -> void:
	var g = UpsGovernor.new()
	add_child(g)
	g.set_process(false)
	var tick := [1000.0]
	_govern(g, tick, 40.0, 60.0)
	check(g.budget == UpsGovernor.BUDGET_DEFAULT and g.fast_cuts == 0, "budget fast: at 60 UPS the budget stays (%d)" % g.budget)
	# A stall (a save): its first quarter second reads as a long tick; once no tick is in the window nothing more is cut.
	var stalled = UpsGovernor.new()
	add_child(stalled)
	stalled.set_process(false)
	var tick3 := [1000.0]
	_govern(stalled, tick3, 40.0, 60.0)
	for i in 4:
		stalled.feed(int(tick3[0]), 0.1)
	var after_window: int = stalled.fast_cuts
	for i in 10:
		stalled.feed(int(tick3[0]), 0.1)
	check(stalled.fast_cuts == after_window and stalled.fast_cuts <= 2, "budget fast: a stall cuts at most in its first quarter second (%d), then nothing more" % stalled.fast_cuts)
	stalled.queue_free()
	var sent := []
	g.budget_changed.connect(func(u: int) -> void: sent.append(u))
	# Long ticks: 30 UPS for a third of a second.
	for i in 3:
		tick[0] += 3.0
		g.feed(int(tick[0]), 0.1)
	check(g.fast_cuts >= 1 and g.budget < UpsGovernor.BUDGET_DEFAULT and not sent.is_empty() and int(sent[0]) == int(UpsGovernor.BUDGET_DEFAULT * UpsGovernor.BUDGET_CUT),
		"budget fast: ticks at 30 UPS cut the budget within 0.3 s (%d, %d cut, sent %s)" % [g.budget, g.fast_cuts, str(sent)])
	g.queue_free()
	var off = UpsGovernor.new()
	add_child(off)
	off.set_process(false)
	off.budget_fast = false
	var tick2 := [1000.0]
	_govern(off, tick2, 40.0, 60.0)
	for i in 3:
		tick2[0] += 3.0
		off.feed(int(tick2[0]), 0.1)
	check(off.fast_cuts == 0 and off.budget == UpsGovernor.BUDGET_DEFAULT, "budget fast off: the same slow ticks leave the budget to the 3 s rule (%d)" % off.budget)
	off.queue_free()


func _ups_governor() -> void:
	check(bool(Settings.get_value("graphics", "hold_ups")), "Hold the game at 60 UPS is on by default")
	check(bool(Settings.get_value("graphics", "server_first")), "Give the server the CPU first is on by default")
	var g = UpsGovernor.new()
	add_child(g)
	g.set_process(false)
	var tick := [1000.0]
	_govern(g, tick, 40.0, 60.0)
	check(g.level == 0 and g.status() == "" and absf(g.ups - 60.0) < 0.5, "at 60 UPS nothing is held back (measured %.1f)" % g.ups)
	# Slow, and each step buys a little: it steps down one at a time, PAUSE_DOWN apart, to the floors.
	var helped := func(level: int) -> float: return 50.0 + level * 0.3
	_govern(g, tick, 4.0, helped)
	var first: int = g.level
	check(first == 1 and g.limit("rate", 0.0) == 1.0 and g.limit("map", 1.0) == 1.0 and g.limit("entity", 192.0) == 192.0
		and g.status().contains("updates slowed"),
		"under 57 UPS the first step is taken (the bridge's costliest updates less often), the rest wait: level %d, %s" % [g.level, g.status()])
	_govern(g, tick, 3.0, helped)
	check(g.level == first, "the next step waits PAUSE_DOWN after the last")
	_govern(g, tick, 150.0, helped)
	check(g.level == UpsGovernor.STEPS.size() and g.limit("entity", 192.0) == 64.0 and g.limit("updates", 6000.0) == 6000.0
		and g.limit("far", 160.0) == 32.0 and g.limit("view", 10.0) == 5.0 and g.limit("fps", 0.0) == 45.0 and g.limit("map", 1.0) == 4.0
		and g.limit("rate", 0.0) == 3.0 and not g.status().contains("moving belt items"),
		"still slow: every step taken, each knob at its floor and no lower; the Moving belt items steps skipped (the belts are simulated here, the bridge's square ignores the cap): level %d, %s" % [g.level, g.status()])
	check(g.limit("updates", 1000.0) == 1000.0 and g.limit("fps", 30.0) == 30.0, "a player's setting under the floor stays theirs")
	# --ups-updates-steps=on: the Moving belt items steps are taken as before (a bridge whose square the cap bounds).
	var g2 = UpsGovernor.new()
	add_child(g2)
	g2.set_process(false)
	g2.updates_steps = true
	var tick2 := [1000.0]
	_govern(g2, tick2, 40.0, 60.0)
	_govern(g2, tick2, 150.0, helped)
	check(g2.level == UpsGovernor.STEPS.size() and g2.limit("updates", 6000.0) == 1500.0 and g2.status().contains("moving belt items 1500"),
		"--ups-updates-steps=on: the Moving belt items steps are taken, to their floor: level %d, %s" % [g2.level, g2.status()])
	g2.queue_free()
	# --governor-belts-last (on): the belt item distance is cut only once every other step is taken, the view
	# distance and the FPS cap too; off, STEPS' order as before (96 at the seventh step).
	var g3 = UpsGovernor.new()
	add_child(g3)
	g3.set_process(false)
	var others := 0
	for st: Array in g3.steps:
		if st[0] != "far" and st[0] != "updates":
			others += 1
	for i in others:
		g3._step(1)
	var far_kept: float = g3.limit("far", 160.0)
	var view_then: float = g3.limit("view", 10.0)
	var fps_then: float = g3.limit("fps", 0.0)
	g3._step(1)
	var far_first: float = g3.limit("far", 160.0)
	g3.belts_last = false
	var old_order: bool = g3.steps == UpsGovernor.STEPS
	g3.queue_free()
	check(far_kept == 160.0 and view_then == 5.0 and fps_then == 45.0 and far_first == 96.0 and old_order,
		"--governor-belts-last: the belt item distance holds (%s) until view distance (%s) and the FPS cap (%s) are at their floors, then 96 (%s); off, STEPS' order" % [far_kept, view_then, fps_then, far_first])
	# The load goes away: one step back up per HOLD_UP at 60, back to the player's settings.
	var top: int = g.level
	_govern(g, tick, 45.0, 60.0)
	check(g.level == top - 1, "after HOLD_UP at 60 UPS one step comes back: level %d of %d" % [g.level, top])
	# Right after a step back up, a few seconds' dip (the bridge sending the newly wanted chunks)
	# takes no step down; a lasting one does.
	var back: int = g.level
	_govern(g, tick, 6.0, 52.0)
	_govern(g, tick, 12.0, 60.0)
	check(g.level == back, "a short dip after a step back up is the burst of new chunks, not load: level %d" % g.level)
	_govern(g, tick, 35.0, 60.0)
	# A 3 s reading at 60 wanders under 59.5 now and then (ticks arrive unevenly); the way back up
	# reads 10 s, so it still comes.
	var frames := [0]
	var uneven := func(_level: int) -> float:
		frames[0] += 1
		return 58.6 if (frames[0] / 25) % 2 == 0 else 61.4
	_govern(g, tick, 35.0 * top, uneven)
	check(g.level == 0 and g.status() == "" and g.limit("entity", 192.0) == 192.0 and g.limit("fps", 0.0) == 0.0,
		"settings return to the player's when the load goes away: level %d" % g.level)
	# A save or a pause (the ticks stop) isn't slowness.
	_govern(g, tick, 20.0, 0.0)
	check(g.level == 0, "stalled ticks take no step")
	# Slow for its own reasons: the steps buy nothing, so it goes back up and holds nothing back.
	var reached := 0
	for i in 12:
		_govern(g, tick, 10.0, 45.0)
		reached = maxi(reached, g.level)
	_govern(g, tick, 90.0, 45.0)
	check(reached == UpsGovernor.STEPS.size() and g.level == 0,
		"steps that buy no UPS are given back and not tried again for a while: level %d, then %d" % [reached, g.level])
	g.queue_free()
	# A setting the player already has low is skipped; switched off, nothing is held back.
	Settings.set_value("graphics", "entity_radius", 64)
	g = UpsGovernor.new()
	add_child(g)
	g.set_process(false)
	_govern(g, tick, 60.0, 60.0)
	_govern(g, tick, 40.0, helped)
	check(g.level > 3 and g.limit("entity", 64.0) == 64.0 and (g.status().find("entity") < 0), "steps for a knob already under them are skipped: %s" % g.status())
	Settings.set_value("graphics", "hold_ups", false)
	check(g.level == 0 and not g.enabled, "switching it off gives everything back at once")
	_govern(g, tick, 60.0, 40.0)
	check(g.level == 0, "switched off, a slow game takes no step")
	Settings.reset_value("graphics", "hold_ups")
	Settings.reset_value("graphics", "entity_radius")
	g.queue_free()
	# The bridge's work budget is kept to the room the game has before anything is asked, so the next
	# big request (a map zoom, a jump) is paced to it rather than reacted to once the UPS has dropped.
	g = UpsGovernor.new()
	add_child(g)
	g.set_process(false)
	var sent: Array = []
	g.budget_changed.connect(func(units: int) -> void: sent.append(units))
	_govern(g, tick, 20.0, 60.0)
	check(sent == [UpsGovernor.BUDGET_DEFAULT] and g.budget == UpsGovernor.BUDGET_DEFAULT,
		"at 60 UPS with nothing waiting the bridge keeps its default budget, sent once: %s" % [sent])
	_govern(g, tick, 5.0, 55.0)
	var cut: int = g.budget
	check(cut < UpsGovernor.BUDGET_DEFAULT and cut >= UpsGovernor.BUDGET_FLOOR and sent[-1] == cut,
		"under 58.5 UPS the budget shrinks within seconds, before any step: %d (sent %s)" % [cut, sent])
	_govern(g, tick, 30.0, 40.0)
	check(g.budget == UpsGovernor.BUDGET_FLOOR, "and no lower than its floor: %d" % g.budget)
	g.queued = 500
	_govern(g, tick, 60.0, 60.0)
	check(g.budget == UpsGovernor.BUDGET_MAX, "at 60 UPS with work waiting it grows back, to its ceiling: %d" % g.budget)
	g.queued = 0
	_govern(g, tick, 20.0, 60.0)
	check(g.budget == UpsGovernor.BUDGET_DEFAULT, "and with nothing waiting back to the default: %d" % g.budget)
	var count := sent.size()
	_govern(g, tick, 10.0, 60.0)
	check(sent.size() == count, "a steady budget isn't sent again")
	_govern(g, tick, 5.0, 50.0)
	Settings.set_value("graphics", "hold_ups", false)
	_govern(g, tick, 2.0, 50.0)
	check(g.budget == UpsGovernor.BUDGET_DEFAULT and sent[-1] == UpsGovernor.BUDGET_DEFAULT, "switched off, the default budget: %s" % [sent])
	Settings.reset_value("graphics", "hold_ups")
	g.queue_free()
	# The bridge's first load of the belts (bs ld, the square still small) is a burst: no step while it
	# lasts nor AFTER_LOAD after, the budget not cut under BUDGET_LOAD_FLOOR meanwhile and back at
	# its default when it ends; steady at 59.0-59.4 after it the bridge keeps 6-tick updates.
	g = UpsGovernor.new()
	add_child(g)
	g.set_process(false)
	var loading_now := [false]
	g.loading_probe = func() -> bool: return loading_now[0]
	_govern(g, tick, 20.0, 60.0)
	loading_now[0] = true
	_govern(g, tick, 25.0, 45.0)
	check(g.loading and g.level == 0 and g.limit("rate", 0.0) == 0.0,
		"a slow game while the bridge makes its first load takes no step: level %d" % g.level)
	check(g.budget == UpsGovernor.BUDGET_LOAD_FLOOR,
		"and paces the load with the budget, no lower than its load floor: %d" % g.budget)
	loading_now[0] = false
	_govern(g, tick, 1.0, 45.0)
	check(g.budget >= UpsGovernor.BUDGET_DEFAULT and g.level == 0,
		"the load done, the budget is back at its default at once: %d" % g.budget)
	_govern(g, tick, 60.0, 59.2)
	check(g.level == 0 and g.limit("rate", 0.0) == 0.0, "steady at 59.2 UPS after the load nothing is held back: level %d" % g.level)
	# Held back for a real slowness, 59.2 UPS on a 10 s reading is enough to come back.
	_govern(g, tick, 10.0, 50.0)
	var held: int = g.level
	_govern(g, tick, 45.0, 59.2)
	check(held > 0 and g.level == held - 1, "a step comes back at 59.2 UPS (a 10 s reading): level %d, then %d" % [held, g.level])
	g.queue_free()
	# Recommended (Graphics): from the hardware, then from what a game measured.
	var rec := func(cores: int, gpu: String, fps := 0.0, ups := 0.0, now := "") -> String:
		return Settings.recommended_preset(cores, gpu, fps, ups, now)
	check(rec.call(16, "NVIDIA GeForce RTX 5080") == "ultra" and rec.call(8, "NVIDIA GeForce RTX 3060 Laptop GPU") == "high"
		and rec.call(8, "Intel(R) UHD Graphics") == "medium" and rec.call(4, "Intel(R) Iris(R) Xe Graphics") == "low"
		and rec.call(16, "AMD Radeon(TM) Graphics") == "medium",
		"Recommended picks by the hardware: a big recent GPU with 16 threads Ultra, a discrete one High, integrated Medium or Low")
	check(rec.call(16, "NVIDIA GeForce RTX 5080", 40.0, 60.0, "ultra") == "high" and rec.call(16, "NVIDIA GeForce RTX 5080", 30.0, 52.0, "ultra") == "low"
		and rec.call(8, "NVIDIA GeForce RTX 3060", 120.0, 60.0, "high") == "ultra" and rec.call(8, "NVIDIA GeForce RTX 3060", 70.0, 60.0, "high") == "high",
		"measured in a game it steps down for slow frames or a slow game, up when there is plenty of room")
	check(bool(Settings.get_value("graphics", "belt_smooth")), "Smooth belt items is on by default")
	# The minimap following the character asks only for the chunks it hasn't had lately.
	var cache := MapCache.new(UiModel.new())
	for y in range(0, 10):
		for x in range(0, 10):
			cache._charted[Vector2i(x, y)] = cache._now()
	var strips: Array = cache._stale(Rect2i(1, 1, 10, 10), cache._now() - 4.0)
	check(strips == [Rect2i(10, 1, 1, 9), Rect2i(1, 10, 10, 1)], "a moved minimap asks for the new strips, not its whole area: %s" % [strips])


## The sun's shadow map fitted to the ground in view (sun_shadows.gd), with the camera the angled
## view has by default (30 tiles off, 50 degrees down) and a sun in it.
