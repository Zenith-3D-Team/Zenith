extends "res://tests/ui_test_base.gd"
## UI test sections: perf_lod.

func _belt_stand_ins() -> void:
	var w := WorldMirror.new()
	add_child(w)
	w.far_chunks.enabled = false
	w.protos.add_entities([[1, "transport-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[2, "underground-belt", "underground-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[3, "splitter", "splitter", -1.0, -0.5, 1.0, 0.5, 200, 180, 0, 1, 1]])
	# Wube3DP's belts and undergrounds, Placeholders' splitter (drawn slats; FUE5's, above them, are
	# textured and get no flat stand-in).
	var kinds := [["transport-belt", "transport-belt", {"s": "s", ModelLibrary.PACK_KEY: "builtin:wube3dp"}, 20], ["transport-belt", "transport-belt", {"s": "l", ModelLibrary.PACK_KEY: "builtin:wube3dp"}, 80],
		["fast-transport-belt", "transport-belt", {"s": "r", ModelLibrary.PACK_KEY: "builtin:wube3dp"}, 80], ["underground-belt", "underground-belt", {"u": "i", ModelLibrary.PACK_KEY: "builtin:wube3dp"}, 120],
		["underground-belt", "underground-belt", {"u": "o", ModelLibrary.PACK_KEY: "builtin:wube3dp"}, 120], ["splitter", "splitter", {ModelLibrary.PACK_KEY: "builtin:placeholders"}, 200]]
	var meshes := []
	for k in kinds:
		var mesh := ModelLibrary.mesh_for_entity(k[0], k[1], k[2], 0)
		meshes.append(mesh)
		BeltLods.stand_in(mesh, BeltLods.kind_of(k[1], k[2]))
		BeltLods.mid_stand_in(mesh, BeltLods.kind_of(k[1], k[2]))
	BeltLods.finish_all()
	for i in kinds.size():
		var k: Array = kinds[i]
		var mesh: Mesh = meshes[i]
		var flat := BeltLods.stand_in(mesh, BeltLods.kind_of(k[1], k[2]))
		var tris := 0
		if flat != null:
			for s in flat.get_surface_count():
				tris += (flat.surface_get_arrays(s)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		var top_gap := absf(flat.get_aabb().end.y - mesh.get_aabb().end.y) if flat != null else INF
		check(flat != null and tris > 0 and tris <= int(k[3]) and (k[1] != "transport-belt" or top_gap < 0.01)
			and flat.surface_get_material(0) == mesh.surface_get_material(int((flat.get_meta(&"f3d_from") as PackedInt32Array)[0])),
			"a stand-in for %s %s: %d triangles, its materials the model's, the belt's top %.3f off" % [k[0], k[2], tris, top_gap])
	var c := Vector2i(4, 0)
	var cv := ChunkView.new()
	cv.coord = c
	cv.loaded = true
	w.chunks[c] = cv
	w.add_child(cv)
	for i in 3:
		var r := WorldMirror.Rec.new()
		r.key = 900 + i
		r.unit = 900 + i
		r.proto_id = i + 1
		r.pos = Vector2(c.x * 32 + 4.5 + i * 3, 4.5)
		r.chunk = c
		r.extra = [{"s": "s", ModelLibrary.PACK_KEY: "builtin:wube3dp"}, {"u": "i", ModelLibrary.PACK_KEY: "builtin:wube3dp"}, {ModelLibrary.PACK_KEY: "builtin:placeholders"}][i]
		cv.entities[r.key] = r
		w.entities[r.key] = r
	cv.build_entities(w.protos, {})
	var belt := ModelLibrary.mesh_for_entity("transport-belt", "transport-belt", {"s": "s", ModelLibrary.PACK_KEY: "builtin:wube3dp"}, 0)
	var full: MultiMeshInstance3D = cv._nodes.get(belt)
	var flat_mmi: MultiMeshInstance3D = cv._nodes.get([belt, BeltLods.FLAT])
	var mid_mmi: MultiMeshInstance3D = cv._nodes.get([belt, BeltLods.MID])
	var parts: Array = cv._nodes.keys().filter(func(key) -> bool: return key is Array and key[1] is int)
	check(full != null and flat_mmi != null and (not BeltLods.mid_enabled or mid_mmi != null) and BeltLods._chunks.has(cv) and parts.size() > 0,
		"a chunk with belts draws each belt model and its stand-in, and is watched (%d moving parts)" % parts.size())
	var cam := Camera3D.new()
	cam.fov = 50.0
	w.add_child(cam)
	var vp := cam.get_viewport()
	var pixels := vp.get_visible_rect().size.y * (vp.scaling_3d_scale if vp.scaling_3d_mode != Viewport.SCALING_3D_MODE_FSR2 else 1.0)
	# The camera straight over the chunk's belts, so its distance is just its height above them.
	var at := func(px: float) -> void:
		var d := pixels / (2.0 * tan(deg_to_rad(cam.fov) * 0.5) * px)
		cam.global_position = Vector3(cv.belt_bounds.get_center().x, cv.belt_bounds.end.y + d, cv.belt_bounds.get_center().z)
		BeltLods.update(w, cam, 1.0)
	var whole := func() -> bool:
		return full.visible and not flat_mmi.visible and (mid_mmi == null or not mid_mmi.visible) and cv._nodes.keys().all(func(key) -> bool:
			return not (key is Array and key[1] is int) or (cv._nodes[key] as MultiMeshInstance3D).visible)
	var mid_now := func() -> bool:
		return not full.visible and mid_mmi != null and mid_mmi.visible and not flat_mmi.visible and cv._nodes.keys().all(func(key) -> bool:
			return not (key is Array and key[1] is int) or not (cv._nodes[key] as MultiMeshInstance3D).visible)
	var flat_now := func() -> bool:
		return not full.visible and (mid_mmi == null or not mid_mmi.visible) and flat_mmi.visible and cv._nodes.keys().all(func(key) -> bool:
			return not (key is Array and key[1] is int) or not (cv._nodes[key] as MultiMeshInstance3D).visible)
	at.call(60.0)
	check(not cv.belt_flat and whole.call(), "near the camera (60 px a tile) the belts are drawn whole")
	if BeltLods.mid_enabled:
		at.call(40.0)
		check(not cv.belt_flat and cv.belt_lod == BeltLods.TIER_MID and mid_now.call(),
			"at mid zoom (40 px a tile) the 3D mid-detail belt LOD is drawn with moving parts hidden")
	at.call(10.0)
	var proxies_off: bool = cv._shadows.values().all(func(m: MultiMeshInstance3D) -> bool: return not m.visible)
	var flat_casts := flat_mmi.cast_shadow == (GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if cv.shadow_tier == ChunkView.SHADOWS_NONE else GeometryInstance3D.SHADOW_CASTING_SETTING_ON)
	check(cv.belt_flat and flat_now.call() and flat_casts and proxies_off,
		"far (10 px a tile) the stand-ins are drawn instead, the splitter's moving parts hidden, the flat belts casting the shadow (the full model's stand-in hidden)")
	at.call(22.0)
	check(cv.belt_flat and flat_now.call(), "between the two thresholds (22 px) they stay flat")
	at.call(26.0)
	var above_ok: bool = (cv.belt_lod == BeltLods.TIER_MID and mid_now.call()) if BeltLods.mid_enabled else whole.call()
	check(not cv.belt_flat and above_ok, "and leave flat above %d px a tile" % int(BeltLods.FULL_ABOVE))
	if BeltLods.mid_enabled:
		at.call(60.0)
		check(cv.belt_lod == BeltLods.TIER_FULL and whole.call(), "and are whole again above %d px a tile" % int(BeltLods.MID_FULL_ABOVE))
	at.call(22.0)
	check(not cv.belt_flat, "and stay non-flat coming back to 22 px")
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = pixels / 12.0
	BeltLods.update(w, cam, 1.0)
	var ortho_flat: bool = cv.belt_flat and flat_now.call()
	cam.size = pixels / (60.0 if BeltLods.mid_enabled else 32.0)
	BeltLods.update(w, cam, 1.0)
	check(ortho_flat and not cv.belt_flat and whole.call(), "an orthographic view goes by its size: flat at 12 px a tile, whole near Factorio's zoom")
	# A build keeps the choice: the stand-ins stay drawn in place of the models.
	cam.size = pixels / 12.0
	BeltLods.update(w, cam, 1.0)
	cv.build_entities(w.protos, {})
	check(cv.belt_flat and flat_now.call(), "a rebuild of a flat chunk draws its belts flat again")
	# B-roll: changing surface unloads every chunk, whose MultiMeshes are freed a few a frame before the
	# chunk itself, and belt levels of detail went on setting them flat or whole ("previously freed").
	w._unload(c)
	check(cv.retired and not BeltLods._chunks.has(cv) and cv._belt_pairs.is_empty(),
		"an unloaded chunk is let go: no belt levels of detail, no lists of its MultiMeshes")
	cv.get_child(cv.get_child_count() - 1).free()
	cam.size = pixels / 32.0
	BeltLods.update(w, cam, 1.0)
	cv.set_belt_flat(not cv.belt_flat)
	check(cv.belt_flat, "and belt updates leave it alone while its nodes are freed")
	# Should a list still name a freed MultiMesh, the pairs after it are still set.
	var gone := MultiMeshInstance3D.new()
	gone.free()
	var live := MultiMeshInstance3D.new()
	live.visible = false
	cv.retired = false
	cv.belt_flat = false
	cv._belt_pairs = [[[gone], null], [[live], gone], [[live], null]]
	cv._apply_belt_flat()
	check(live.visible, "_apply_belt_flat skips a freed MultiMesh and goes on")
	live.free()
	w.queue_free()


## Belts' stand-ins count at most 1080 lines (belt_lods.gd MAX_LINES), so 4K draws as many belt
## triangles as 1080p: the sums alone, then a 4K viewport through update() itself.


func _belt_stand_ins_at_4k() -> void:
	var hd := Vector2(1920, 1080)
	var uhd := Vector2(3840, 2160)
	check(is_equal_approx(BeltLods.view_pixels(hd, 1.0), 1080.0) and is_equal_approx(BeltLods.view_pixels(uhd, 1.0), 1080.0),
		"belts' stand-ins count 1080p and 4K alike, 1080 lines")
	check(is_equal_approx(BeltLods.view_pixels(uhd, 0.5), 1080.0) and is_equal_approx(BeltLods.view_pixels(uhd, 0.25), 540.0)
		and is_equal_approx(BeltLods.view_pixels(hd, 0.5), 540.0) and is_equal_approx(BeltLods.view_pixels(hd, 2.0), 1080.0),
		"the limit is on the lines rendered: 4K at half scale is 1080, a quarter 540, 1080p at half 540, supersampled 1080")
	check(is_equal_approx(BeltLods.view_pixels(uhd, 1.0, true), 1920.0), "a camera keeping its width counts the width of that 1080-line picture")
	var cam := Camera3D.new()
	cam.fov = 50.0
	var box := AABB(Vector3.ZERO, Vector3(1, 0, 1))
	# Straight over the box, 15 px a tile at 1080p: 30 real pixels at 4K, which didn't go flat before.
	var at := Vector3(0, 1080.0 / (2.0 * tan(deg_to_rad(cam.fov) * 0.5) * 15.0), 0)
	var px_hd := BeltLods.tile_pixels(cam, at, BeltLods.view_pixels(hd, 1.0), box)
	var px_uhd := BeltLods.tile_pixels(cam, at, BeltLods.view_pixels(uhd, 1.0), box)
	check(is_equal_approx(px_hd, 15.0) and is_equal_approx(px_uhd, 15.0) and BeltLods.flat_at(px_uhd, false, false),
		"a view that is flat at 1080p is flat at 4K (%.1f and %.1f px a tile)" % [px_hd, px_uhd])
	check(not BeltLods.flat_at(22.0, false, false) and BeltLods.flat_at(22.0, true, false) and not BeltLods.flat_at(26.0, true, false),
		"a perspective view keeps the gap between the thresholds")
	# Factorio's view shows more ground in a bigger window, tile for tile.
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = uhd.y / CameraRig.FACTORIO_PX_PER_TILE * sin(deg_to_rad(CameraRig.FACTORIO_PITCH))
	var px_f6 := BeltLods.tile_pixels(cam, at, BeltLods.view_pixels(uhd, 1.0), box)
	check(px_f6 > BeltLods.FLAT_BELOW and not BeltLods.flat_at(px_f6, true, true),
		"Factorio's view at 4K (%.1f px) is whole, even from belts that were flat" % px_f6)
	cam.free()
	var w := WorldMirror.new()
	add_child(w)
	w.far_chunks.enabled = false
	var cv := ChunkView.new()
	cv.coord = Vector2i(6, 0)
	cv.loaded = true
	w.chunks[cv.coord] = cv
	w.add_child(cv)
	cv.belt_bounds = AABB(Vector3(192, 0, 0), Vector3(32, 0.2, 32))
	BeltLods.track(cv)
	var vp := SubViewport.new()
	vp.size = Vector2i(uhd)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	w.add_child(vp)
	var c4 := Camera3D.new()
	c4.fov = 50.0
	vp.add_child(c4)
	var over := func(px: float) -> void:
		var d := 1080.0 / (2.0 * tan(deg_to_rad(c4.fov) * 0.5) * px)
		c4.global_position = Vector3(cv.belt_bounds.get_center().x, cv.belt_bounds.end.y + d, cv.belt_bounds.get_center().z)
		BeltLods.update(w, c4, 1.0)
	over.call(40.0)
	var near_whole: bool = not cv.belt_flat
	over.call(15.0)
	check(near_whole and cv.belt_flat, "a 4K viewport's belts go flat where 1080p's do (whole at 40 px a tile, flat at 15)")
	BeltLods.untrack(cv)
	w.queue_free()


## Items on belts cast no shadows unless the camera is within the Shadows setting's distance
## (belt_items.gd shadows_within, High's 60 here); lone items on the ground or in hands always do.


func _belt_item_shadows() -> void:
	const ON := GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	const OFF := GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var vp := SubViewport.new()
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var cam := Camera3D.new()
	vp.add_child(cam)
	var items = BeltItemsScript.new()
	vp.add_child(items)
	items._cards.prepare(1)
	var kind: MultiMeshInstance3D = items._cards._kinds[1]
	check(kind.cast_shadow == OFF, "items on belts cast no shadows before any update says where they are")
	var within_before: float = BeltItemsScript.shadows_within
	BeltItemsScript.shadows_within = 60.0
	items._square = Vector3(10.0, 20.0, 24.0)
	cam.global_position = Vector3(10.0, 100.0, 20.0)
	items._update_shadows()
	check(kind.cast_shadow == OFF, "nor zoomed far out, 100 tiles away")
	items._cards.reset()
	items._cards.prepare(1)
	kind = items._cards._kinds[1]
	check(kind.cast_shadow == OFF, "nor after their kinds are made again")
	cam.global_position = Vector3(10.0, 30.0, 20.0)
	items._update_shadows()
	items._cards.prepare(2)
	var second: MultiMeshInstance3D = items._cards._kinds[2]
	check(kind.cast_shadow == ON and second.cast_shadow == ON, "at the default zoom, 30 tiles away, they do, a kind made then too")
	cam.global_position = Vector3(10.0, 100.0, 20.0)
	items._update_shadows()
	check(kind.cast_shadow == OFF and second.cast_shadow == OFF, "and stop again zooming far out")
	check(kind.layers == ItemCardsScript.BELT_LAYER and second.layers == ItemCardsScript.BELT_LAYER,
		"items on belts are on their own render layer, which the character's lights leave out of their shadows")
	# Shadows Low: none at any zoom (sun_shadows.gd QUALITY "items" 0, 18, 25, 35).
	BeltItemsScript.shadows_within = float(SunShadows.QUALITY["low"]["items"])
	cam.global_position = Vector3(10.0, 21.0, 20.0)
	items._update_shadows()
	check(kind.cast_shadow == OFF and SunShadows.QUALITY["medium"]["items"] == 18.0 and SunShadows.QUALITY["high"]["items"] == 25.0
		and SunShadows.QUALITY["ultra"]["items"] == 35.0, "on Low items on belts cast no shadows even up close; Medium to Ultra 18, 25, 35 tiles")
	BeltItemsScript.shadows_within = within_before
	vp.queue_free()
	var loose := ItemCardsScript.new()
	add_child(loose)
	loose.prepare(1)
	var lone: MultiMeshInstance3D = loose._kinds[1]
	check(lone.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON and lone.layers == 1,
		"items on the ground and in hands still do, on the usual layer")
	loose.queue_free()


## Levels of detail, the shadow stand-ins (Godot's own LODs) and SSAO count pixels on at most
## ModelLods.max_lines (High and Medium 1440, Low 1080): a 4K picture is counted as 1440 lines, so it
## doesn't keep detail twice as far as 1080p. The ground's relief is off at Level of detail Low.


func _lod_lines() -> void:
	ModelLods.apply_quality("high", get_viewport())
	check(ModelLods.max_lines == 1440.0 and ModelLods.counted_lines(2160.0) == 1440.0 and ModelLods.counted_lines(1080.0) == 1080.0
		and ModelLods.counted_lines(0.0) == 1.0, "Level of detail High counts at most 1440 lines, a smaller picture its own")
	var vp := SubViewport.new()
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	vp.size = Vector2i(3840, 2160)
	add_child(vp)
	ModelLods.apply_quality("high", vp)
	var high_4k := vp.mesh_lod_threshold
	vp.size = Vector2i(1920, 1080)
	ModelLods.fit_lines(vp)
	var high_1080 := vp.mesh_lod_threshold
	vp.size = Vector2i(3840, 2160)
	ModelLods.apply_quality("low", vp)
	var low_4k := vp.mesh_lod_threshold
	check(is_equal_approx(high_4k, 1.5) and is_equal_approx(high_1080, 1.0) and is_equal_approx(low_4k, 15.0),
		"Godot's own levels (the shadow stand-ins) allow as many real pixels at 4K as 1440 lines' (High 1.5, 1080p 1, Low at 4K 15): %.2f %.2f %.2f"
		% [high_4k, high_1080, low_4k])
	ModelLods.max_lines = 0.0
	ModelLods.fit_lines(vp)
	check(is_equal_approx(vp.mesh_lod_threshold, 7.5) and ModelLods.counted_lines(2160.0) == 2160.0, "--lod-lines=0 counts every real line, as before 0.2.1")
	vp.queue_free()
	# SSAO at 4K fades out where it does at 1440p (ao_zoom.gd measures on the counted lines).
	ModelLods.apply_quality("medium", get_viewport())
	var AoZoom := preload("res://scripts/world/ao_zoom.gd")
	var cam := Camera3D.new()
	cam.fov = 35.0
	add_child(cam)
	cam.look_at_from_position(Vector3(0, sin(deg_to_rad(50.0)) * 100.0, cos(deg_to_rad(50.0)) * 100.0), Vector3.ZERO)
	var at_4k := AoZoom.view_tiles_per_pixel(cam, Vector2(3840, ModelLods.counted_lines(2160.0)))
	var at_1440 := AoZoom.view_tiles_per_pixel(cam, Vector2(2560, 1440))
	check(is_equal_approx(at_4k, at_1440) and at_4k > AoZoom.SSAO_FULL, "a 4K view 100 tiles off is measured as 1440p's: %.4f tiles a pixel" % at_4k)
	cam.queue_free()
	# The ground's bumps and crevices: off at Level of detail Low (three texture reads a ground pixel).
	var terrain := Visuals.terrain_material()
	Visuals.set_ground_relief(false)
	var off: bool = terrain.get_shader_parameter("ground_relief") == false
	Visuals.set_ground_relief(true)
	check(off and terrain.get_shader_parameter("ground_relief") == true, "the ground's relief switches off and on (Level of detail Low)")
	ModelLods.apply_quality(str(Settings.get_value("graphics", "lod_quality")), get_viewport())


## Fast belts' surfaces are smeared over the way they move in a frame (belt_blur.gd, the shader's
## belt_smear): the width follows speed * dt, and is 0 for a slow or stopped belt.


func _belt_blur() -> void:
	var dt := 1.0 / 60.0
	var yellow := BeltBlur.smear(ModelLibrary.BELT_SPEED, dt)
	var red := BeltBlur.smear(ModelLibrary.BELT_SPEEDS["fast-"], dt)
	var express := BeltBlur.smear(ModelLibrary.BELT_SPEEDS["express-"], dt)
	var turbo := BeltBlur.smear(ModelLibrary.BELT_SPEEDS["turbo-"], dt)
	check(yellow == 0.0 and BeltBlur.smear(0.0, dt) == 0.0 and BeltBlur.smear(7.5, 0.0) == 0.0,
		"a yellow belt at 60 fps, a stopped belt and a still frame aren't smeared (%.4f)" % yellow)
	check(is_equal_approx(express, 5.625 * dt * BeltBlur.SHUTTER) and is_equal_approx(turbo, 7.5 * dt * BeltBlur.SHUTTER),
		"express and turbo belts are smeared over %.0f frames' travel: %.4f and %.4f tiles" % [BeltBlur.SHUTTER, express, turbo])
	check(is_equal_approx(red, BeltBlur.MIN * BeltBlur.PERIOD) and red > 3.75 * dt * BeltBlur.SHUTTER
		and is_equal_approx(BeltBlur.smear(-7.5, dt), turbo),
		"a red belt is smeared over the least width, a little more than its step (%.4f), a belt running back as much as forwards" % red)
	var fade := smoothstep(BeltBlur.FROM * BeltBlur.PERIOD, BeltBlur.TO * BeltBlur.PERIOD, 5.625 / 144.0)
	check(is_equal_approx(BeltBlur.smear(5.625, 1.0 / 144.0), BeltBlur.MIN * BeltBlur.PERIOD * fade) and fade > 0.0 and fade < 1.0,
		"at 144 fps an express belt is smeared less, faded by its smaller step (%.2f)" % fade)
	check(BeltBlur.SHUTTER <= 1.0 and BeltBlur.smear(ModelLibrary.BELT_SPEED, 1.0 / 30.0) == 0.0
		and BeltBlur.smear(7.5, 5.0) == turbo and BeltBlur.smear(7.5, 1.0 / 30.0) == turbo,
		"at most one frame's travel, and a slow frame (30 fps, a hitch) smears no more than a 60 fps one")
	# The shader works it out the same way: its constants are these.
	var text := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	var same := true
	for pair in [["BELT_SHUTTER", BeltBlur.SHUTTER], ["BELT_SMEAR_MIN", BeltBlur.MIN], ["BELT_SMEAR_FROM", BeltBlur.FROM], ["BELT_SMEAR_TO", BeltBlur.TO], ["BELT_PERIOD", BeltBlur.PERIOD]]:
		var m := RegEx.create_from_string("const float %s = ([0-9.]+);" % pair[0]).search(text)
		same = same and m != null and is_equal_approx(float(m.get_string(1)), float(pair[1]))
	check(same and text.contains("global uniform float f3d_frame_dt;") and ProjectSettings.has_setting("shader_globals/f3d_frame_dt"),
		"the shader's smear constants match belt_blur.gd and f3d_frame_dt is a shader global")
	# The world sets the frame's length every frame, the menu's world too (before it is ready).
	var taa_was := Settings.look_taa
	Settings.look_taa = false
	BeltBlur._sharp_until = 0
	BeltBlur._smooth = -1.0
	var w := WorldMirror.new()
	add_child(w)
	w._process(1.0 / 100.0)
	check(is_equal_approx(BeltBlur.frame_dt, 1.0 / 100.0),
		"world.gd sets f3d_frame_dt to the frame's length")
	w.queue_free()
	# Smoothed and capped: one hitch moves it a little, and never past a 60 fps frame.
	BeltBlur.frame(0.5)
	var after_hitch := BeltBlur.frame_dt
	check(is_equal_approx(after_hitch, lerpf(1.0 / 100.0, BeltBlur.MAX_DT, BeltBlur.SMOOTHING)) and after_hitch < BeltBlur.MAX_DT,
		"a hitch's frame barely moves the smear's frame length (%.4f s)" % after_hitch)
	for i in 200:
		BeltBlur.frame(1.0 / 20.0)
	check(is_equal_approx(BeltBlur.frame_dt, BeltBlur.MAX_DT), "slow frames count as 60 fps ones (%.4f s)" % BeltBlur.frame_dt)
	# No smear while TAA blends frames (the setting or a look's), nor on a screenshot's frames.
	Settings.look_taa = true
	BeltBlur.frame(1.0 / 60.0)
	check(BeltBlur.frame_dt == 0.0, "no smear while TAA is on")
	Settings.look_taa = false
	BeltBlur.frame(1.0 / 60.0)
	check(BeltBlur.frame_dt > 0.0, "the smear is back with TAA off")
	BeltBlur.sharp_frames(2)
	var at_once := BeltBlur.frame_dt
	BeltBlur.frame(1.0 / 60.0)
	check(at_once == 0.0 and BeltBlur.frame_dt == 0.0, "sharp_frames() turns the smear off at once and for that frame")
	BeltBlur._sharp_until = 0
	BeltBlur.frame(1.0 / 60.0)
	check(BeltBlur.frame_dt > 0.0, "and it comes back after")
	Settings.look_taa = taa_was
	# Chevrons spaced as Factorio's belt sprites space their arrows, per tier.
	var periods := {}
	for name: String in ["transport-belt", "fast-transport-belt", "express-transport-belt", "turbo-transport-belt", "turbo-transport-belt-curve-left"]:
		var mesh := ModelLibrary.mesh_for(name) as ArrayMesh
		for i in mesh.get_surface_count():
			var m := mesh.surface_get_material(i) as ShaderMaterial
			if m != null and m.resource_name.to_lower().contains(ModelLibrary.BELT_MATERIAL):
				periods[name] = float(m.get_shader_parameter("belt_chevron_period"))
	check(periods.get("transport-belt") == 0.5 and periods.get("fast-transport-belt") == 1.0 and periods.get("express-transport-belt") == 1.0
		and periods.get("turbo-transport-belt") == 2.0 and periods.get("turbo-transport-belt-curve-left") == 2.0,
		"chevrons every half tile on yellow belts, one a tile on red and blue, every other tile on turbo: %s" % periods)
	check(text.contains("uniform float belt_chevron_period") and text.contains("varying flat float belt_parity;"),
		"the shader spaces chevrons by belt_chevron_period, a 2-tile period by the tile's parity")
	# Lined up tile to tile: the shader's distance along a line (a tile's s plus its parity for a
	# 2-tile period) runs on across a tile's edge, in a line north or east and either way.
	var line_s := func(s: float, tile: Vector2i) -> float: return fposmod(s + float(posmod(tile.x + tile.y, 2)), 2.0)
	var joins := true
	for step: Vector2i in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(1, 0), Vector2i(-1, 0)]:
		for at: Vector2i in [Vector2i(0, 0), Vector2i(3, -2), Vector2i(-5, 7)]:
			joins = joins and is_equal_approx(fposmod(line_s.call(0.5, at) - line_s.call(-0.5, at + step), 2.0), 0.0)
	check(joins, "a turbo belt's chevrons run on from tile to tile")


## Belts run all the time, carrying items or not; only one the circuit network switches off stands
## still (`st` 5), surface and rollers, in place and with no rebuild, and starts again. A splitter's
## gears rest while nothing passes (Factorio's structure animation) but its belts and rollers run.


func _belts_always_run() -> void:
	for name: String in ["transport-belt", "transport-belt-curve-left", "fast-transport-belt", "underground-belt-input",
			"underground-belt-output", "splitter", "fast-splitter", "loader", "turbo-loader"]:
		var mesh := ModelLibrary.mesh_for(name)
		var speed := 0.0
		for i in (mesh as ArrayMesh).get_surface_count():
			var m := mesh.surface_get_material(i) as ShaderMaterial
			if m != null and m.resource_name.to_lower().contains(ModelLibrary.BELT_MATERIAL):
				speed = float(m.get_shader_parameter("belt_speed"))
		check(speed != 0.0, "%s's belt surface runs on its own, with nothing asked of the game (speed %.3f)" % [name, speed])
	var w := WorldMirror.new()
	add_child(w)
	w.far_chunks.enabled = false
	w.protos.add_entities([[1, "transport-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1]])
	var c := Vector2i(6, 0)
	var cv := ChunkView.new()
	cv.coord = c
	cv.loaded = true
	w.chunks[c] = cv
	w.add_child(cv)
	var add_belt := func(unit: int, x: float, extra: Dictionary) -> WorldMirror.Rec:
		var r := WorldMirror.Rec.new()
		r.key = unit
		r.unit = unit
		r.proto_id = 1
		r.pos = Vector2(c.x * 32 + x, 4.5)
		r.chunk = c
		r.extra = extra
		cv.entities[r.key] = r
		w.entities[r.key] = r
		return r
	# Wube3DP's belt, which has a flat stand-in (FUE5's, above it, is textured: none).
	add_belt.call(951, 4.5, {"s": "s", ModelLibrary.PACK_KEY: "builtin:wube3dp"})
	add_belt.call(952, 5.5, {"s": "s", ModelLibrary.PACK_KEY: "builtin:wube3dp"})
	var belt := ModelLibrary.mesh_for_entity("transport-belt", "transport-belt", {"s": "s", ModelLibrary.PACK_KEY: "builtin:wube3dp"}, 0)
	BeltLods.stand_in(belt, "s")
	BeltLods.finish_all()
	cv.build_entities(w.protos, w.working)
	var full: MultiMeshInstance3D = cv._nodes.get(belt)
	check(full != null and not full.multimesh.use_custom_data and cv._switches.is_empty(),
		"belts with no wire are drawn with no per-belt data: nothing can stop them")
	cv.entities[951].extra = {"s": "s", "r": [953], ModelLibrary.PACK_KEY: "builtin:wube3dp"}
	cv.build_entities(w.protos, w.working)
	var flat: MultiMeshInstance3D = cv._nodes.get([belt, BeltLods.FLAT])
	# The renderer behind a headless run keeps no instance data, so what was written is read from the list.
	var stopped := func(unit: int) -> Array:
		return (cv._switches.get(unit, []) as Array).map(func(s: Array) -> bool: return s[2])
	# Every form the belt is drawn in: the model and its flat stand-in, and the 3D mid-detail one when an
	# earlier section has made it (--belt-mid-lod): all of them run, or all stand still.
	var forms := func(states: Array, v: bool) -> bool:
		return states.size() >= 2 and states.size() <= 3 and states.all(func(b: bool) -> bool: return b == v)
	check(full.multimesh.use_custom_data and flat != null and flat.multimesh.use_custom_data and forms.call(stopped.call(951), false)
		and not cv._switches.has(952), "a belt with a wire is drawn ready to stop (the model and its stand-in), and runs")
	var dirty_before := w._dirty.has(c)
	w._on_states([951, AnimScript.SWITCHED_OFF])
	check(forms.call(stopped.call(951), true) and w._dirty.has(c) == dirty_before,
		"switched off (`st` 5): that belt stands still, model and stand-in, with no rebuild")
	cv.build_entities(w.protos, w.working)
	check(forms.call(stopped.call(951), true), "a rebuild keeps it stopped")
	w._on_states([951, 0])
	check(forms.call(stopped.call(951), false), "and `st` 0 starts it again")
	w._on_states([952, AnimScript.SWITCHED_OFF])
	check(w._dirty.has(c), "a belt with no wire (a logistic condition) that stops is drawn again, ready to")
	cv.build_entities(w.protos, w.working)
	check(forms.call(stopped.call(952), true), "and then stands still")
	w.queue_free()
	# A roller's motion: its loop running, frozen dead while switched off, and running on from there.
	var anim := AnimScript.new()
	add_child(anim)
	var part_of := func(model: String, roller: bool) -> ModelLibrary.AnimPart:
		var part := ModelLibrary.AnimPart.new()
		part.kind = "baked"
		part.model = model
		part.roller = roller
		part.rate = 1.0
		part.mesh = BoxMesh.new()
		return part
	var unit := 9700
	var working := {}
	var on_of := func(group: AnimScript.Group) -> bool:
		var code := -group.customs[0].b - 1.0
		return int(floor(code)) % 2 == 1
	var speed_of := func(group: AnimScript.Group) -> float:
		var code := -group.customs[0].b - 1.0
		return code - floor(code)
	var base := Transform3D(Basis(), Vector3(1.5, 0.0, 2.5))
	var roller := _anim_group(part_of.call("transport-belt", false), unit, base)
	roller.stateful[0] = 0
	roller.kind = AnimScript.kind_of(roller)
	anim._write(roller, 0, working)
	check(on_of.call(roller), "a belt's rollers run with nothing asked of the game")
	anim._process(0.6)
	working[unit] = AnimScript.SWITCHED_OFF
	anim._write(roller, 0, working)
	var frozen_at: float = roller.customs[0].g
	check(not on_of.call(roller) and speed_of.call(roller) == 0.0 and frozen_at > 0.0,
		"switched off, they stop dead where they are (at %.3f of a loop, no coasting)" % frozen_at)
	anim._process(0.6)
	anim._write(roller, 0, working)
	check(roller.customs[0].g == frozen_at, "and stay there")
	working[unit] = 0
	anim._write(roller, 0, working)
	check(on_of.call(roller) and speed_of.call(roller) > 0.9 and roller.customs[0].g == frozen_at, "and run on from there at once")
	unit += 1
	var gears := _anim_group(part_of.call("splitter", false), unit, base)
	var spinner := _anim_group(part_of.call("splitter", true), unit, base)
	gears.kind = AnimScript.kind_of(gears)
	spinner.kind = AnimScript.kind_of(spinner)
	working[unit] = 0
	anim._write(gears, 0, working)
	anim._write(spinner, 0, working)
	check(not on_of.call(gears) and on_of.call(spinner), "a splitter with nothing passing: its gears rest, its rollers run")
	working[unit] = 1
	anim._write(gears, 0, working)
	anim._write(spinner, 0, working)
	check(on_of.call(gears) and on_of.call(spinner), "with items passing both move")
	anim.queue_free()


## The performance warning (perf_warning.gd, perf_log.gd; owner: "a warning icon in the top left ... showing any hold
## 60 ups or performance automatic downgrading of settings ... clickable to show a log"): a governor step shows the
## icon with its count; a click opens the log with "from → to" and why; a step back marks it restored and the icon
## goes 10 s later; the work budget, Automatic moving belt items and the bridge's belt square are logged without
## lighting it; the setting off hides it while the log fills; the log holds 200; the icon takes the Show in
## Factorio button's place while that is hidden; a public build has the setting; the debug menu's row and
## --perf-warning=off.


func _sun_shadows(cam: Camera3D, sun: DirectionalLight3D) -> void:
	var depths := SunShadows.ground_depths(cam)
	check(depths.x > 20.0 and depths.x < 28.0 and depths.y > 36.0 and depths.y < 46.0,
		"from the angled view the ground in view runs from about 24 to 41 tiles from the camera: %s" % depths)
	var fitted := SunShadows.distance_for(depths.y, 150.0, -1.0)
	check(fitted >= depths.y / float(SunShadows.QUALITY["high"]["fade"]) and fitted <= depths.y / float(SunShadows.QUALITY["high"]["fade"]) * SunShadows.STEP + 0.5,
		"the shadows reach just past the top of the screen, so their fade starts there: %.1f" % fitted)
	check(SunShadows.distance_for(INF, 150.0, -1.0) == 150.0 and SunShadows.distance_for(INF, 150.0, fitted) == 150.0,
		"with the horizon in view (first person, a low tilt) they reach the quality's cap at once")
	check(SunShadows.distance_for(INF, 80.0, 150.0) == 80.0, "a lower quality's cap applies at once")
	check(SunShadows.distance_for(depths.y * 0.95, 150.0, fitted) == fitted and SunShadows.distance_for(depths.y * 0.6, 150.0, fitted) < fitted,
		"zooming in a little keeps the step (no flipping to and fro), zooming in more takes a shorter one")
	var two := SunShadows.split_fractions(depths, fitted, 2)
	var four := SunShadows.split_fractions(depths, fitted, 4)
	check(two.x * fitted > depths.x and two.x * fitted < depths.y and four.x < four.y and four.y < four.z and four.x * fitted > depths.x and four.z < 1.0,
		"the splits share out the ground in view: %s %s" % [two, four])
	check(SunShadows.split_fractions(Vector2(0.5, INF), 150.0, 4) == Vector3(0.1, 0.2, 0.5), "with the horizon in view, Godot's own splits")
	# One map while the nearest ground in view is at least a quarter as far as the shadows reach;
	# Godot's cascades for the horizon, with a margin so tilting across the line doesn't flip it.
	check(not SunShadows.reaches_far(depths, fitted, false) and SunShadows.reaches_far(Vector2(1.0, INF), 150.0, false)
		and SunShadows.reaches_far(Vector2(20.0, 150.0), 150.0, false) and SunShadows.reaches_far(Vector2(40.0, 150.0), 150.0, true)
		and not SunShadows.reaches_far(Vector2(40.0, 150.0), 150.0, false), "one shadow map for the angled view, cascades looking far")
	# Fitted, the chunks that cast are those round the view, not 90 tiles ahead under the ground.
	var ahead := Rect2(-70, -70, 16, 16)
	# (--tight-cull, the default since the close-up culling: the region is the ground slab in view, so the chunks far
	# ahead under the ground cast at no reach; the old corner-grown region, checked with it off, takes them in.)
	var tight_was := ViewPriority.tight_cull
	ViewPriority.tight_cull = false
	check(WorldMirror._rect_meets_hull(ahead, WorldMirror.shadow_region(cam, sun)), "at a fixed 150 tiles, chunks far ahead cast shadows (--tight-cull=off)")
	ViewPriority.tight_cull = true
	check(not WorldMirror._rect_meets_hull(ahead, WorldMirror.shadow_region(cam, sun)) and WorldMirror._rect_meets_hull(Rect2(-16, -16, 32, 32), WorldMirror.shadow_region(cam, sun)),
		"--tight-cull: at a fixed 150 tiles the chunks far ahead under the ground don't cast, the ground round the focus does")
	ViewPriority.tight_cull = tight_was
	var fitter := SunShadows.new()
	fitter.sun = sun
	add_child(fitter)
	for q in ["low", "medium", "high", "ultra"]:
		fitter.apply_quality(q)
		var spec: Dictionary = SunShadows.QUALITY[q]
		check(sun.directional_shadow_mode == SunShadows.MODES[int(spec["splits"])] and sun.directional_shadow_max_distance <= float(spec["cap"])
			and Settings.SHADOW_SIZES[q] == int(spec["atlas"]),
			"%s shadows: %d split(s) on a %d atlas, at most %d tiles" % [q, int(spec["splits"]), int(spec["atlas"]), int(spec["cap"])])
	fitter.apply_quality("high")
	check(is_equal_approx(sun.directional_shadow_max_distance, fitted) and sun.directional_shadow_mode == DirectionalLight3D.SHADOW_ORTHOGONAL
		and not WorldMirror._rect_meets_hull(ahead, WorldMirror.shadow_region(cam, sun)) and WorldMirror._rect_meets_hull(Rect2(-16, -16, 32, 32), WorldMirror.shadow_region(cam, sun)),
		"fitted to the view (one map, %.1f tiles), they don't, and the ground round the focus still does" % sun.directional_shadow_max_distance)
	# Looking at the horizon: the cap, in cascades.
	cam.look_at_from_position(Vector3(0.0, 1.6, 0.0), Vector3(30.0, 1.0, 0.0))
	fitter._fit(false)
	check(sun.directional_shadow_max_distance == 150.0 and sun.directional_shadow_mode == SunShadows.MODES[int(SunShadows.QUALITY["high"]["horizon_splits"])],
		"looking at the horizon (first person) the shadows reach the cap in cascades")
	cam.look_at_from_position(Vector3(13.6, 23.0, 13.6), Vector3.ZERO)
	fitter.queue_free()
	sun.directional_shadow_max_distance = 150.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	_sun_shadow_fit()


## Shadows "very unstable and flickering ... blurry with holes even when zoomed in" (the owner): the
## fit with the camera rig's own views at a 1920 x 1080 picture. Zoomed in the view gets one map
## over the ground it needs (the old fit gave it cascades from a 32-tile floor), walking over hills
## at a fixed zoom changes neither the mode nor the distance (the old fit measured from y = 0 under
## a camera riding the hills), a low tilt with the horizon still cascades, and Factorio's
## orthographic view is fitted as before. Each but the last fails with --shadow-fit=old.


func _sun_shadow_fit() -> void:
	CameraRig.GroundHeight.clear()
	var vp := SubViewport.new()
	vp.size = Vector2i(1920, 1080)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var me := Node3D.new()
	vp.add_child(me)
	var rig := CameraRig.new()
	rig.target = me
	vp.add_child(rig)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	sun.shadow_enabled = true
	vp.add_child(sun)
	var fitter := SunShadows.new()
	fitter.sun = sun
	vp.add_child(fitter)
	fitter.set_process(false)  # fitted by hand below, after the rig moved
	var old_was: bool = SunShadows.old_fit
	var cam: Camera3D = rig.camera
	var settle := func(yaw: float, pitch: float, dist: float, ortho: bool) -> void:
		rig._snap(yaw, pitch, dist, ortho)
		rig.global_position = me.position
		for i in 150:
			rig._process(1.0 / 60.0)
		fitter._fit(true)
	# Texels a tile in the nearest split, as Godot fits it (sun_shadows.gd, which fits the blur to it).
	var texels := func(atlas: int, last := false) -> float:
		return SunShadows.texels_per_tile(cam, sun, atlas, last)
	var modes := {DirectionalLight3D.SHADOW_ORTHOGONAL: "1 map", DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS: "2 splits", DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS: "4 splits"}
	# Each quality at zooms 6, 15, 30 (pitch 50, flat): mode, distance and texels a tile, both fits.
	var table := func() -> Array:
		var said := []
		var close_ok := true
		for q in ["low", "medium", "high", "ultra"]:
			fitter.apply_quality(q)
			var row := []
			for z: float in [6.0, 15.0, 30.0]:
				settle.call(45.0, 50.0, z, false)
				var atlas := int(SunShadows.QUALITY[q]["atlas"])
				row.append("%d: %s %.1f %.0f/%.0f" % [int(z), modes[sun.directional_shadow_mode], sun.directional_shadow_max_distance, texels.call(atlas), texels.call(atlas, true)])
				if z == 6.0:
					close_ok = close_ok and sun.directional_shadow_mode == DirectionalLight3D.SHADOW_ORTHOGONAL and sun.directional_shadow_max_distance < 32.0
			said.append("%s (%s)" % [q, ", ".join(row)])
		return [close_ok, "; ".join(said)]
	SunShadows.old_fit = false
	var new_table: Array = table.call()
	SunShadows.old_fit = true
	var old_table: Array = table.call()
	SunShadows.old_fit = false
	check(new_table[0], "zoomed right in (6 tiles, pitch 50) every quality has one map under 32 tiles (zoom: mode, distance, texels a tile nearest/furthest split): %s" % new_table[1])
	check(not old_table[0], "--shadow-fit=old: zoomed right in the 32-tile floor counts as far, cascades or 32 tiles: %s" % old_table[1])
	fitter.apply_quality("high")
	# Walking over 4-tile hills at a fixed zoom: the camera rides them; the fit mustn't move.
	CameraRig.GroundHeight.clear()
	var img := Image.create(160, 160, false, Image.FORMAT_RF)
	for j in 160:
		for i in 160:
			var x := -160.0 + (i + 0.5) * 2.0
			var z := -160.0 + (j + 0.5) * 2.0
			img.set_pixel(i, j, Color(2.0 + 2.0 * sin(x / 9.0) * cos(z / 13.0), 0.0, 0.0))
	CameraRig.GroundHeight.set_field(img, Vector2(-160, -160), 2.0)
	var walk := func() -> Array:
		var said := []
		var total := 0
		for z: float in [6.0, 15.0, 30.0, 45.0]:
			me.position = Vector3(-50.0, 0.0, 7.0)
			settle.call(45.0, 50.0, z, false)
			var dist := sun.directional_shadow_max_distance
			var mode := sun.directional_shadow_mode
			var changes := 0
			for f in 660:  # 9 tiles a second for 11 s, east over the hills
				me.position.x += 0.15
				rig._process(1.0 / 60.0)
				fitter._fit(false)
				if sun.directional_shadow_max_distance != dist or sun.directional_shadow_mode != mode:
					changes += 1
					dist = sun.directional_shadow_max_distance
					mode = sun.directional_shadow_mode
			total += changes
			said.append("zoom %d: %d" % [int(z), changes])
		return [total, ", ".join(said)]
	var new_walk: Array = walk.call()
	SunShadows.old_fit = true
	var old_walk: Array = walk.call()
	SunShadows.old_fit = false
	check(int(new_walk[0]) == 0, "walking 100 tiles over 4-tile hills at a fixed zoom changes neither the shadows' mode nor their distance (changes): %s" % new_walk[1])
	check(int(old_walk[0]) > 0, "--shadow-fit=old: the same walk re-fits the map (changes): %s" % old_walk[1])
	# The furthest ground counted 1.5 tiles under the ground looked at: valleys beyond keep shadows.
	me.position = Vector3(0.0, 0.0, 7.0)
	settle.call(45.0, 50.0, 30.0, false)
	var g := SunShadows.centre_ground(cam)
	var flat_depths := SunShadows.ground_depths(cam, g)
	check(fitter.view_depths.y > flat_depths.y and is_equal_approx(fitter.view_depths.x, flat_depths.x),
		"on the hills the furthest ground is measured 1.5 tiles under the ground looked at (%.1f against %.1f; ground %.2f)" % [fitter.view_depths.y, flat_depths.y, g])
	# A low tilt with the horizon (or nearly) in view: cascades, zoomed in and at the default zoom.
	CameraRig.GroundHeight.clear()
	me.position = Vector3.ZERO
	var low_ok := true
	var low_said := []
	for z: float in [6.0, 30.0]:
		settle.call(45.0, CameraRig.MIN_PITCH, z, false)
		low_ok = low_ok and sun.directional_shadow_mode == SunShadows.MODES[int(SunShadows.QUALITY["high"]["horizon_splits"])]
		low_said.append("zoom %d: %s %.1f, ground %.1f-%.1f" % [int(z), modes[sun.directional_shadow_mode], sun.directional_shadow_max_distance, fitter.view_depths.x, fitter.view_depths.y])
	check(low_ok, "at the lowest tilt the view reaches far and gets cascades: %s" % ", ".join(low_said))
	# Factorio's orthographic view: fitted as before, either fit.
	var ortho := []
	for old: bool in [false, true]:
		SunShadows.old_fit = old
		settle.call(0.0, 50.0, 30.0, true)
		ortho.append([sun.directional_shadow_mode, sun.directional_shadow_max_distance, sun.directional_shadow_split_1, sun.directional_shadow_split_2, sun.directional_shadow_split_3])
	SunShadows.old_fit = old_was
	check(ortho[0] == ortho[1] and ortho[0][0] == DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS and is_equal_approx(float(ortho[0][1]), 150.0),
		"the orthographic view's shadows are fitted as before (fixed cascades, 150 tiles): %s" % [ortho])
	_sun_shadow_soft(settle, fitter, sun, cam)
	_sun_shadow_soft_edges(settle, fitter, sun, cam, rig)
	vp.queue_free()


## Steps 2-3 (the owner: shadows "blurry with holes"): High and Ultra on Soft High's 16 taps, the blur
## fitted so the edge is EDGE tiles on the ground at every zoom (between a texel and the filter's own
## radius), Low unchanged; a look's sun size (PCSS) only when asked, with blur 1 and the short pancake;
## --shadow-filter=old as before. Each fitted check fails under the old filter.


func _sun_shadow_soft(settle: Callable, fitter: SunShadows, sun: DirectionalLight3D, cam: Camera3D) -> void:
	var filter_was: bool = SunShadows.old_filter
	CameraRig.GroundHeight.clear()
	fitter.set_look(0.0)
	var soft := func() -> Array:
		var ok := true
		var said := []
		for q in ["low", "medium", "high", "ultra"]:
			fitter.apply_quality(q)
			var filter := int(fitter.spec["filter"])
			var radius := float(SunShadows.QUALITY_RADIUS[filter])
			var row := []
			for z: float in [6.0, 15.0, 30.0]:
				settle.call(45.0, 50.0, z, false)
				var tx := SunShadows.texels_per_tile(cam, sun, fitter.atlas)
				var r := sun.shadow_blur * radius
				if q == "low":
					ok = ok and is_equal_approx(sun.shadow_blur, 1.0)
				else:
					ok = ok and r >= SunShadows.MIN_TEXELS - 0.001 and r <= radius + 0.001
					if tx * SunShadows.EDGE > SunShadows.MIN_TEXELS and tx * SunShadows.EDGE < radius:
						ok = ok and absf(r / tx - SunShadows.EDGE) <= SunShadows.EDGE * 0.1
				ok = ok and is_equal_approx(sun.light_angular_distance, 0.0) and is_equal_approx(sun.directional_shadow_pancake_size, SunShadows.PANCAKE)
				row.append("%d: %.0f texels, blur %.2f = %.2f texels, %.3f tiles" % [int(z), tx, sun.shadow_blur, r, r / tx])
			if q == "high":
				ok = ok and filter == RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM
			elif q == "ultra":
				ok = ok and filter == RenderingServer.SHADOW_QUALITY_SOFT_HIGH
			said.append("%s (filter %d: %s)" % [q, filter, ", ".join(row)])
		return [ok, "; ".join(said)]
	SunShadows.old_filter = false
	var new_soft: Array = soft.call()
	SunShadows.old_filter = true
	var old_soft: Array = soft.call()
	SunShadows.old_filter = false
	check(new_soft[0], "the shadows' edge is %.2f tiles on the ground wherever a texel to the filter's radius allows, High on Soft Medium and Ultra on Soft High, Low as before: %s" % [SunShadows.EDGE, new_soft[1]])
	check(not old_soft[0], "--shadow-filter=old: Soft Low and fixed blurs: %s" % old_soft[1])
	# texels_per_tile is the fit's own measure, as step 1's table had it on High (185 / 91 / 45).
	fitter.apply_quality("high")
	var said := []
	var same := true
	var want := [185.0, 91.0, 45.0]
	for i in 3:
		settle.call(45.0, 50.0, [6.0, 15.0, 30.0][i], false)
		var tx := SunShadows.texels_per_tile(cam, sun, 4096)
		same = same and absf(tx - float(want[i])) < 1.5 and is_equal_approx(fitter.texels, tx)
		said.append("%.1f" % tx)
	check(same, "texels a tile on High at zooms 6 / 15 / 30 as step 1 measured them (185 / 91 / 45): %s" % ", ".join(said))
	# A wider edge (the Cinematic look's Soft shadows) at zoom 30: wider blur within Soft Medium's radius.
	settle.call(45.0, 50.0, 30.0, false)
	var b1 := sun.shadow_blur
	fitter.set_look(0.0, 0.04)
	fitter._fit(true)
	var b2 := sun.shadow_blur
	fitter.set_look(0.0)
	fitter._fit(true)
	check(b2 > b1 * 1.3 and is_equal_approx(b2, SunShadows.blur_for(0.04, fitter.texels, int(fitter.spec["filter"]))) and is_equal_approx(sun.shadow_blur, b1),
		"an edge of 0.04 tiles (the Cinematic look's Soft shadows) blurs wider than 0.02, up to the filter's radius (%.3f against %.3f)" % [b2, b1])
	# The look's sun size: PCSS with blur 1 and the short pancake, and back; Ultra caps PCSS at Soft Medium unless old_filter.
	fitter.set_look(0.5)
	fitter._fit(false)
	var pcss := [sun.light_angular_distance, sun.shadow_blur, sun.directional_shadow_pancake_size]
	fitter.apply_quality("ultra")
	var ultra_pcss := fitter.filter_now()
	fitter.set_look(0.0)
	fitter._fit(false)
	var ultra_pcf := fitter.filter_now()
	SunShadows.old_filter = true
	fitter.set_look(0.5)
	var ultra_old_pcss := fitter.filter_now()
	SunShadows.old_filter = false
	fitter.set_look(0.0)
	fitter.apply_quality("high")
	fitter._fit(false)
	var plain := [sun.light_angular_distance, sun.shadow_blur, sun.directional_shadow_pancake_size]
	check(is_equal_approx(float(pcss[0]), 0.5) and is_equal_approx(float(pcss[1]), 1.0) and is_equal_approx(float(pcss[2]), SunShadows.PCSS_PANCAKE)
		and is_equal_approx(float(plain[0]), 0.0) and is_equal_approx(float(plain[1]), b1) and is_equal_approx(float(plain[2]), SunShadows.PANCAKE)
		and ultra_pcss == SunShadows.PCSS_MAX_FILTER and ultra_pcf == RenderingServer.SHADOW_QUALITY_SOFT_HIGH
		and ultra_old_pcss == RenderingServer.SHADOW_QUALITY_SOFT_HIGH,
		"a sun size of 0.5: the sun gets it, blur 1, pancake %.0f, Ultra caps PCSS at Soft Medium; 0: none, the fitted blur, pancake %.0f (%s, %s, ultra %s/%s/%s)" % [SunShadows.PCSS_PANCAKE, SunShadows.PANCAKE, pcss, plain, ultra_pcss, ultra_pcf, ultra_old_pcss])
	# --shadow-filter=old: High's old filter and 0.6 blur, the sun size straight through, pancake 20.
	SunShadows.old_filter = true
	fitter.apply_quality("high")
	fitter.set_look(1.4)
	fitter._fit(true)
	check(int(fitter.spec["filter"]) == RenderingServer.SHADOW_QUALITY_SOFT_LOW and is_equal_approx(sun.shadow_blur, 0.6)
		and is_equal_approx(sun.light_angular_distance, 1.4) and is_equal_approx(sun.directional_shadow_pancake_size, SunShadows.PANCAKE),
		"--shadow-filter=old: High on Soft Low, blur 0.6, the sun size 1.4 as it was, pancake 20")
	fitter.set_look(0.0)
	SunShadows.old_filter = filter_was
	fitter.apply_quality("high")
	# --sun-step: the light held inside the step, moved past it; 0 is smooth.
	var a := Vector3(-40.0, -30.0, 0.0)
	var near := Vector3(-40.3, -30.0, 0.0)
	var far := Vector3(-41.5, -30.0, 0.0)
	check(PlanetSky.stepped_sun(null, a, 1.0) == a and PlanetSky.stepped_sun(a, near, 1.0) == a and PlanetSky.stepped_sun(a, far, 1.0) == far
		and PlanetSky.stepped_sun(a, near, 0.0) == near and PlanetSky.sun_step == 0.0,
		"--sun-step=1 holds the light within a degree and moves it past one; 0 (the default) follows the sun")


## Steps 2-3, the tester's edge cases: each preset's blur at the furthest zoom and in Factorio's view
## (F6, orthographic: its own texels), the sun size put on and taken off mid-game while zooming,
## --shadow-pancake, a look's own sun size, and --sun-step with the Cinematic look's moving sun.


func _sun_shadow_soft_edges(settle: Callable, fitter: SunShadows, sun: DirectionalLight3D, cam: Camera3D, rig: Node) -> void:
	var filter_was: bool = SunShadows.old_filter
	var max_was: float = rig.max_distance
	SunShadows.old_filter = false
	CameraRig.GroundHeight.clear()
	fitter.set_look(0.0)
	# Each preset at the furthest zoom (the setting's 400 tiles and the default) and in F6's view.
	var ok := true
	var said := []
	rig.max_distance = CameraRig.MAX_ZOOM_RANGE.y
	for q in ["low", "medium", "high", "ultra"]:
		fitter.apply_quality(q)
		var radius := float(SunShadows.QUALITY_RADIUS[int(fitter.spec["filter"])])
		var row := []
		for view: Array in [[45.0, 50.0, CameraRig.MAX_DISTANCE, false], [45.0, 50.0, CameraRig.MAX_ZOOM_RANGE.y, false], [0.0, 50.0, 30.0, true], [0.0, 50.0, 6.0, true]]:
			settle.call(view[0], view[1], view[2], view[3])
			var tx := SunShadows.texels_per_tile(cam, sun, fitter.atlas)
			var b := sun.shadow_blur
			var good := is_finite(b) and b > 0.0 and b <= 1.0001 and is_finite(tx) and tx > 0.0
			if q != "low":
				good = good and is_equal_approx(fitter.texels, tx) and is_equal_approx(b, SunShadows.blur_for(SunShadows.EDGE, tx, int(fitter.spec["filter"])))
			ok = ok and good
			row.append("%s%d: %.1f texels, blur %.2f, edge %.3f tiles" % ["F6 " if view[3] else "", int(view[2]), tx, b, b * radius / tx])
		said.append("%s (%s)" % [q, ", ".join(row)])
	rig.max_distance = max_was
	check(ok, "the fitted blur at the furthest zooms and in Factorio's view (F6) is the fit's own, inside (0, 1]: %s" % "; ".join(said))
	# The orthographic camera's texels: its box (no widening with depth) round the nearest split.
	fitter.apply_quality("high")
	settle.call(0.0, 50.0, 30.0, true)
	var d := sun.directional_shadow_max_distance
	var depth := d * sun.directional_shadow_split_1 - cam.near
	var vs := cam.get_viewport().get_visible_rect().size
	var half := Vector2(cam.size * 0.5 * vs.x / vs.y, cam.size * 0.5)
	var want := float(fitter.atlas) * 0.5 / (2.0 * sqrt(half.x * half.x + half.y * half.y + depth * depth * 0.25))
	var got := SunShadows.texels_per_tile(cam, sun, fitter.atlas)
	check(cam.projection == Camera3D.PROJECTION_ORTHOGONAL and absf(got - want) < 0.01 * want,
		"in Factorio's view (orthographic) texels a tile come from the camera's box, not a widening frustum (%.2f, %.2f by hand)" % [got, want])
	# The sun size put on at zoom 6 and off at zoom 30: the blur is fitted to 30 by the next fit, not left at 6's.
	settle.call(45.0, 50.0, 30.0, false)
	var b30 := sun.shadow_blur
	settle.call(45.0, 50.0, 6.0, false)
	fitter.set_look(0.5)
	settle.call(45.0, 50.0, 30.0, false)
	var during := [sun.light_angular_distance, sun.shadow_blur]
	fitter.set_look(0.0)
	fitter._fit(false)
	check(is_equal_approx(float(during[0]), 0.5) and is_equal_approx(float(during[1]), 1.0) and is_equal_approx(sun.shadow_blur, b30)
		and is_equal_approx(sun.light_angular_distance, 0.0),
		"a sun size put on zoomed in and taken off zoomed out: PCSS while on, then zoom 30's fitted blur at once (%.3f, want %.3f)" % [sun.shadow_blur, b30])
	# A look put on and taken off mid-game through looks.gd, as main.gd wires it, while the fit runs.
	var env := Environment.new()
	var looks := LooksScript.new()
	looks.shadows = fitter
	add_child(looks)
	looks.attach(env, sun)
	LooksScript.register("test/pcss", {"name": "PCSS", "sun": {"light_angular_distance": 0.8, "shadow_opacity": 0.9}, "shadow_edge": 0.05})
	LooksScript.register("test/edge", {"name": "Edge", "shadow_edge": 0.04})
	var trail := []
	var flips_ok := true
	for id in ["test/pcss", "factorio", "test/edge", "test/pcss", "test/edge", "factorio"]:
		looks.use(id)
		for z: float in [15.0, 6.0]:
			settle.call(45.0, 50.0, z, false)
			var e := 0.04 if id == "test/edge" else SunShadows.EDGE
			if id == "test/pcss":
				flips_ok = flips_ok and is_equal_approx(sun.light_angular_distance, 0.8) and is_equal_approx(sun.shadow_blur, 1.0) and is_equal_approx(sun.directional_shadow_pancake_size, SunShadows.pcss_pancake)
			else:
				flips_ok = flips_ok and is_equal_approx(sun.light_angular_distance, 0.0) and is_equal_approx(sun.directional_shadow_pancake_size, SunShadows.PANCAKE)
				flips_ok = flips_ok and is_equal_approx(fitter.edge, e) and is_equal_approx(sun.shadow_blur, SunShadows.blur_for(e, fitter.texels, int(fitter.spec["filter"])))
			trail.append("%s@%d %.2f/%.2f/%.0f" % [id, int(z), sun.light_angular_distance, sun.shadow_blur, sun.directional_shadow_pancake_size])
	flips_ok = flips_ok and is_equal_approx(sun.shadow_opacity, 1.0)
	check(flips_ok, "looks switched on and off while zooming: the sun size, blur, pancake and edge follow each, nothing left behind (look@zoom size/blur/pancake): %s" % ", ".join(trail))
	LooksScript.remove_owner("")
	looks.queue_free()
	# --shadow-pancake=<tiles>: the PCSS pancake only; the PCF path and the old switch keep 20.
	var pancake_was: float = SunShadows.pcss_pancake
	SunShadows.pcss_pancake = 4.0
	fitter.set_look(0.5)
	var p_pcss := sun.directional_shadow_pancake_size
	fitter.set_look(0.0)
	var p_pcf := sun.directional_shadow_pancake_size
	SunShadows.old_filter = true
	fitter.apply_quality("high")
	fitter.set_look(0.5)
	var p_old := sun.directional_shadow_pancake_size
	fitter.set_look(0.0)
	SunShadows.old_filter = false
	fitter.apply_quality("high")
	SunShadows.pcss_pancake = pancake_was
	check(is_equal_approx(p_pcss, 4.0) and is_equal_approx(p_pcf, SunShadows.PANCAKE) and is_equal_approx(p_old, SunShadows.PANCAKE),
		"--shadow-pancake=4 sets the PCSS pancake only (PCSS %.1f, PCF %.1f, old switch %.1f)" % [p_pcss, p_pcf, p_old])
	# --sun-step with the Cinematic look's sun moving (sky.gd's apply, twilight on, a minute of game
	# time a frame): the light rests between steps and jumps past them.
	var step_was: float = PlanetSky.sun_step
	var sky := PlanetSky.new()
	add_child(sky)
	sky.set_planet("nauvis")
	sky.twilight = 1.0
	sky.sky_twilight = 1.0
	var sky_env := Environment.new()
	var light := DirectionalLight3D.new()
	add_child(light)
	var runs := {}
	for step: float in [0.0, 1.0]:
		PlanetSky.sun_step = step
		sky._held_sun = null
		var moves := 0
		var last := Vector3.INF
		var worst := 0.0
		for f in 600:
			sky.apply(sky_env, light, 0.05 + f * 0.0002, 0.0, 1.0 / 60.0, false)
			if light.rotation_degrees != last:
				moves += 1
				last = light.rotation_degrees
			var aim: Vector3 = Basis.from_euler(Vector3(-float(PlanetSky.sun_model(sky._p, 0.05 + f * 0.0002, 0.0)["light_pitch"]), float(PlanetSky.sun_model(sky._p, 0.05 + f * 0.0002, 0.0)["light_yaw"]), 0.0) * (PI / 180.0)).z
			worst = maxf(worst, rad_to_deg(light.global_basis.z.angle_to(aim)))
		runs[step] = [moves, worst]
	PlanetSky.sun_step = step_was
	sky.queue_free()
	light.queue_free()
	check(int(runs[0.0][0]) >= 590 and float(runs[0.0][1]) < 0.01 and int(runs[1.0][0]) > 1 and int(runs[1.0][0]) < int(runs[0.0][0]) / 10 and float(runs[1.0][1]) <= 1.0001,
		"--sun-step=1 under a moving sun: the light moves on few frames and never more than a degree from the sun; 0 every frame (moves, worst degrees off): %s" % [runs])
	# The stutter probe's "soft low" on Ultra: the blur refitted to Soft Low's radius (2 texels), not left
	# at the one meant for Soft High's 3; put back after.
	fitter.apply_quality("ultra")
	settle.call(45.0, 50.0, 30.0, false)
	var b_high := sun.shadow_blur
	var probe := StutterProbeScript.new()
	probe._filter_variant(fitter, "soft low", true)
	var soft_on := [fitter.filter_now(), sun.shadow_blur, SunShadows.blur_for(SunShadows.EDGE, fitter.texels, RenderingServer.SHADOW_QUALITY_SOFT_LOW)]
	settle.call(45.0, 50.0, 30.0, false)  # and a fit on top keeps it
	var soft_fit := sun.shadow_blur
	probe._filter_variant(fitter, "soft low", false)
	probe.free()
	check(int(soft_on[0]) == RenderingServer.SHADOW_QUALITY_SOFT_LOW and is_equal_approx(float(soft_on[1]), float(soft_on[2])) and is_equal_approx(soft_fit, float(soft_on[2]))
		and not is_equal_approx(float(soft_on[1]), b_high) and fitter.filter_override == -1 and fitter.filter_now() == RenderingServer.SHADOW_QUALITY_SOFT_HIGH
		and is_equal_approx(sun.shadow_blur, b_high),
		"the probe's \"soft low\" on Ultra refits the blur to Soft Low (%.3f, want %.3f; Ultra's %.3f), and puts Ultra's back after (%.3f)" % [float(soft_on[1]), float(soft_on[2]), b_high, sun.shadow_blur])
	# Under PCSS the texels a tile still follow the fit (the probe prints them): zoom 6 then 30 with a sun size.
	fitter.set_look(0.5)
	var pcss_tx := []
	for z: float in [6.0, 30.0]:
		settle.call(45.0, 50.0, z, false)
		pcss_tx.append([fitter.texels, SunShadows.texels_per_tile(cam, sun, fitter.atlas)])
	fitter.set_look(0.0)
	check(is_equal_approx(float(pcss_tx[0][0]), float(pcss_tx[0][1])) and is_equal_approx(float(pcss_tx[1][0]), float(pcss_tx[1][1]))
		and not is_equal_approx(float(pcss_tx[0][0]), float(pcss_tx[1][0])),
		"while the sun has a size (PCSS) the texels a tile are refreshed by each fit (zoom 6, 30: %s)" % [pcss_tx])
	SunShadows.old_filter = filter_was
	fitter.set_look(0.0)
	fitter.apply_quality("high")

## Owner: "flickers slightly with the lower LODs; logistic chests and inserters the worst". Godot's
## own mesh LODs switched a whole chunk's models at one distance either way, with no fade, from
## simplifications that could drop thin parts. Now: levels of whole meshes (no coplanar faces added,
## thin parts and the silhouette kept), picked per chunk with hysteresis by the size of a pixel
## there, cross-faded with a screen-door dither, the MultiMesh's instances (machines' states) kept.


func _lod_level_checks(model: Mesh, surfaces: int) -> void:
	# The levels are a second job after the stand-in's (up to a minute with others queued).
	var until := Time.get_ticks_msec() + 60000
	while ModelLods.levels(model).is_empty() and ModelLods.busy() and Time.get_ticks_msec() < until:
		ModelLods.poll()
		await get_tree().process_frame
	var levels := ModelLods.levels(model)
	var ordered := not levels.is_empty() and levels.size() <= ModelLods.MAX_LEVELS
	var last_error := 0.0
	var last_count := 1 << 30
	for level: Array in levels:
		var lod: ArrayMesh = level[0]
		var count := 0
		for i in lod.get_surface_count():
			count += lod.surface_get_array_index_len(i)
		var lod_box := lod.custom_aabb if lod.custom_aabb.has_volume() else lod.get_aabb()
		ordered = ordered and lod.get_surface_count() == surfaces and float(level[1]) >= last_error * ModelLods.LEVEL_STEP \
			and count < last_count and lod_box.is_equal_approx(model.get_aabb()) and lod != model
		last_error = float(level[1])
		last_count = count
	check(ordered, "the assembler gets up to %d levels of its own, coarser in turn, with its surfaces and bounds (%d)" % [ModelLods.MAX_LEVELS, levels.size()])
	# Hysteresis: a level is taken once its error is well inside what is allowed, left only once it isn't.
	var fake := [[null, 0.1], [null, 0.4]]
	check(ModelLods.level_for(fake, 0, 0.11) == 0 and ModelLods.level_for(fake, 0, 0.13) == 1
		and ModelLods.level_for(fake, 1, 0.1) == 1 and ModelLods.level_for(fake, 1, 0.09) == 0
		and ModelLods.level_for(fake, 0, 0.5) == 2 and ModelLods.level_for(fake, 2, 0.35) == 1,
		"levels switch with hysteresis: no popping back and forth at one distance")
	# Thin parts: a simplification that drops a pole (a long thin part) is refused.
	var verts := PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1),
		Vector3(2, 0, 0), Vector3(2.02, 0, 0), Vector3(2.02, 1, 0)])
	var idx := PackedInt32Array([0, 1, 2, 0, 2, 3, 4, 5, 6])
	var parts := ModelLods.Parts.new(verts, idx)
	check(parts.kept_by(idx, 0.05) and not parts.kept_by(PackedInt32Array([0, 1, 2, 0, 2, 3]), 0.05),
		"a level must keep a thin pole that is long enough to see")
	# Coplanar faces: two faces over each other in one plane are found (they would z-fight).
	var quad := [PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0.001, 0), Vector3(1, 0.001, 0), Vector3(1, 0.001, 1)]), null, null, null]
	var apart := [PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0.1, 0), Vector3(1, 0.1, 0), Vector3(1, 0.1, 1)]), null, null, null]
	var both := PackedInt32Array([0, 1, 2, 3, 4, 5])
	check(float(ModelLods.ModelLodsMath.fights([quad], [both])[0]) > 0.4 and float(ModelLods.ModelLodsMath.fights([apart], [both])[0]) == 0.0,
		"faces lying on each other in one plane are found, so a level adding them is refused")
	# Dense textured models (>=5,000 tris) get a triangle-density ladder and a 7% third level.
	var dv := PackedVector3Array()
	var di := PackedInt32Array()
	for t in 6000:
		var z := t * 0.01
		var b := t * 3
		dv.append_array([Vector3(0.0, 0.0, z), Vector3(0.1, 0.0, z), Vector3(0.0, 0.1, z)])
		di.append_array([b, b + 1, b + 2])
	var da := []
	da.resize(Mesh.ARRAY_MAX)
	da[Mesh.ARRAY_VERTEX] = dv
	da[Mesh.ARRAY_INDEX] = di
	var d_surf := [[dv, null, di, null, da]]
	var d_lods := [{0.05: di.slice(0, 3000 * 3), 0.2: di.slice(0, 1200 * 3), 0.8: di.slice(0, 500 * 3)}]
	var d_new := ModelLods.ModelLodsMath.levels(d_surf, d_lods, true, true)
	var d_old := ModelLods.ModelLodsMath.levels(d_surf, d_lods, true, false)
	var d_longest := 5999.0 * 0.01
	var d_px0: float = float(d_new[0][2]) if not d_new.is_empty() else INF
	var o_px0: float = float(d_old[0][2]) if not d_old.is_empty() else 0.0
	check(d_new.size() == 3 and d_px0 < d_longest / 64.0 and d_px0 >= d_longest / ModelLods.TEXTURED_MAX_PIXELS
		and d_old.size() == 2 and is_equal_approx(o_px0, d_longest / 64.0),
		"dense textured models get 3 LOD levels down to 7%% and switch by triangle density (%d levels, px0=%.3f; legacy %d, %.3f)"
		% [d_new.size(), d_px0, d_old.size(), o_px0])
	if levels.is_empty():
		return
	# A chunk switches its model's level with its MultiMesh's instances kept, cross-fading. This MultiMesh is filled
	# here, not by a chunk's apply, so it has no CPU copy of its instances: the default (no renderer reads) switches
	# it at once, checked below; the cross-fade from what it reads back is --render-reads=old's, checked here. (The
	# CPU copies' cross-fade: "LOD cross-fade copies CPU-cached data" further on.)
	var readback_was := ChunkView.lod_no_readback
	ChunkView.lod_no_readback = false
	var cv := ChunkView.new()
	add_child(cv)
	var w := ChunkView.Want.new()
	w.key = model
	w.mesh = model
	w.custom = true
	w.xforms = [Transform3D(Basis.IDENTITY, Vector3(4, 0, 4)), Transform3D(Basis.IDENTITY, Vector3(9, 0, 4))]
	var mmi := cv._new_mmi(null)
	cv._nodes[model] = mmi
	ChunkView._fill(mmi.multimesh, cv._lod_mesh(mmi, w), w.xforms, [], true)
	mmi.multimesh.set_instance_custom_data(1, Color(0.25, 0.5, 0.75, 1.0))
	var state := mmi.multimesh.get_instance_custom_data(1)
	var e1 := ModelLods.switch_error(levels[0])  # (its error as picked: the untextured scaled by distance_scale)
	var top := ChunkView.LOD_HEIGHT
	cv.update_lods(Vector3(16, top + e1 * 0.9, 16), 1.0, -1.0, 0.0)
	var near_whole: bool = mmi.multimesh.mesh == model
	cv.update_lods(Vector3(16, top + e1 * 1.3, 16), 1.0, -1.0, 0.0)
	var st: ChunkView.LodState = cv._lods.get(mmi)
	var switched: bool = st != null and st.level == 1 and mmi.multimesh.mesh == levels[0][0] and mmi.multimesh.instance_count == 2 \
		and mmi.multimesh.get_instance_custom_data(1).is_equal_approx(state)
	var fading: bool = st != null and st.fade != null and st.fade.multimesh.mesh == model and st.fade.multimesh.get_instance_custom_data(1).is_equal_approx(state) \
		and float(mmi.get_instance_shader_parameter(&"f3d_lod_fade")) == 0.0 and st.fade.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cv.update_lods(Vector3(16, top + e1 * 1.3, 16), 1.0, -1.0, ModelLods.FADE_SECONDS * 0.5)
	var halfway: bool = st != null and st.fade != null and is_equal_approx(float(mmi.get_instance_shader_parameter(&"f3d_lod_fade")), 0.5) \
		and is_equal_approx(float(st.fade.get_instance_shader_parameter(&"f3d_lod_fade")), 2.5)
	cv.update_lods(Vector3(16, top + e1 * 1.3, 16), 1.0, -1.0, ModelLods.FADE_SECONDS)
	var faded: bool = st != null and st.fade == null and float(mmi.get_instance_shader_parameter(&"f3d_lod_fade")) == 1.0
	cv.update_lods(Vector3(16, top + e1 * 1.05, 16), 1.0, -1.0, 0.0)
	var held: bool = st != null and st.level == 1
	cv.update_lods(Vector3(16, top + e1 * 0.9, 16), 1.0, -1.0, 0.0)
	var back: bool = st != null and st.level == 0 and mmi.multimesh.mesh == model
	ChunkView._fill(mmi.multimesh, cv._lod_mesh(mmi, w), w.xforms, [], true)
	check(near_whole and switched and fading and halfway and faded and held and back and mmi.multimesh.mesh == model,
		"a chunk's model takes a coarser level far off (same instances and states), the level before dithered out over %.1f s, holds it a little nearer, and is whole again near (%s %s %s %s %s %s %s)"
		% [ModelLods.FADE_SECONDS, near_whole, switched, fading, halfway, faded, held, back])
	ChunkView.lod_no_readback = true
	cv.update_lods(Vector3(16, top + e1 * 1.3, 16), 1.0, -1.0, 0.0)
	var at_once: bool = st != null and st.level == 1 and st.fade == null and mmi.multimesh.mesh == levels[0][0] and mmi.multimesh.instance_count == 2
	cv.update_lods(Vector3(16, top + e1 * 0.9, 16), 1.0, -1.0, 0.0)
	at_once = at_once and st.level == 0 and st.fade == null and mmi.multimesh.mesh == model
	check(at_once, "with no CPU copy of its instances and no renderer reads (the default), the level switches at once, both ways, nothing read back")
	ChunkView.lod_no_readback = readback_was
	# Switch budget stops mid-chunk and resumes cleanly on the next call.
	var mmi2 := cv._new_mmi(null)
	cv._nodes[w] = mmi2
	ChunkView._fill(mmi2.multimesh, cv._lod_mesh(mmi2, w), w.xforms, [], true)
	cv.update_lods(Vector3(16, top + e1 * 1.3, 16), 1.0, -1.0, 0.0, 1)
	var p1_sw := cv.lod_last_switches
	var p1_part := cv.lod_partial
	cv.update_lods(Vector3(16, top + e1 * 1.3, 16), 1.0, -1.0, 0.0, 1)
	var p2_sw := cv.lod_last_switches
	var p2_part := cv.lod_partial
	check(p1_sw == 1 and p1_part and p2_sw == 1 and not p2_part,
		"chunk LOD switch budget stops mid-chunk (%d, partial=%s) and finishes next call (%d, partial=%s)"
		% [p1_sw, p1_part, p2_sw, p2_part])
	# Chunks built through _apply cross-fade via CPU-cached instance data (zero mm.buffer readbacks).
	var cv3 := ChunkView.new()
	cv3.coord = Vector2i.ZERO
	add_child(cv3)
	var w3 := cv3._want(model, model, w.xforms, [], null, true, [], null, false)
	w3.switches = [[1, 700]]
	cv3._apply(w3, {700: AnimScript.SWITCHED_OFF}, null, null)
	var probing_was := Probing.on
	Probing.on = true
	ChunkView.counters.clear()
	cv3.update_lods(Vector3(16, top + e1 * 1.3, 16), 1.0, -1.0, 0.0)
	var cpu_copies := int(ChunkView.counters.get("lod_cpu_copies", 0))
	var buf_readbacks := int(ChunkView.counters.get("lod_buffer_readbacks", 0))
	var mesh_touches := int(ChunkView.counters.get("lod_mesh_touches", 0))
	var mmi3: MultiMeshInstance3D = cv3._nodes[model]
	var st3: ChunkView.LodState = cv3._lods.get(mmi3)
	var cd_before := mmi3.multimesh.get_instance_custom_data(1)
	var fade_ok: bool = st3 != null and st3.from_apply and st3.switches == [[1, 700]] and st3.fade != null \
		and st3.fade.multimesh.instance_count == 2 \
		and st3.fade.multimesh.get_instance_custom_data(1).is_equal_approx(cd_before)
	var toggled: bool = cv3.set_belt_off(700, false)
	var real_gpu := DisplayServer.get_name() != "headless"
	var xf_ok: bool = not real_gpu or (mmi3.multimesh.get_instance_transform(0).is_equal_approx(w.xforms[0] as Transform3D) \
		and mmi3.multimesh.get_instance_transform(1).is_equal_approx(w.xforms[1] as Transform3D))
	var cd_after := mmi3.multimesh.get_instance_custom_data(1)
	var cd_ok: bool = not real_gpu or (cd_before.is_equal_approx(AnimScript.BELT_STOPPED) \
		and cd_after.is_equal_approx(Color(0.0, 0.0, 0.0, 0.0)))
	var grp := AnimScript.Group.new()
	grp.bases.append(Transform3D(Basis.IDENTITY, Vector3(1, 0, 2)))
	var grp_st := ChunkView.LodState.new()
	grp_st.group = grp
	var xforms_ok: bool = ChunkView._lod_xforms(st3) == w.xforms and ChunkView._lod_xforms(grp_st) == Array(grp.bases)
	grp.drawn.append(Transform3D(Basis.IDENTITY, Vector3(3, 0, 4)))
	xforms_ok = xforms_ok and ChunkView._lod_xforms(grp_st) == Array(grp.drawn)
	ChunkView.counters.clear()
	cv3.lod_snap = true
	cv3.update_lods(Vector3(16, top + e1 * 0.9, 16), 1.0, -1.0, 0.0)
	var snap_touches := int(ChunkView.counters.get("lod_mesh_touches", 0))
	cv3.lod_snap = false
	mmi3.visible = false
	cv3.update_lods(Vector3(16, top + e1 * 1.3, 16), 1.0, -1.0, 0.0)
	var hidden_touches := int(ChunkView.counters.get("lod_mesh_touches", 0))
	var was_touch := ChunkView.lod_mesh_touch
	ChunkView.lod_mesh_touch = false
	cv3.update_lods(Vector3(16, top + e1 * 0.9, 16), 1.0, -1.0, 0.0)
	var off_touches := int(ChunkView.counters.get("lod_mesh_touches", 0))
	ChunkView.lod_mesh_touch = was_touch
	Probing.on = probing_was
	check(fade_ok and toggled and xf_ok and cd_ok and xforms_ok and mmi3.multimesh.instance_count == 2
		and cpu_copies == 1 and buf_readbacks == 0 and mesh_touches == 1
		and snap_touches == 1 and hidden_touches == 2 and off_touches == 2,
		"LOD cross-fade copies CPU-cached data, touches instance 0 across normal/snap/hidden swaps, and keeps transforms after custom data edits (fade=%s, toggled=%s, xf=%s, cd=%s, xforms=%s, cpu=%d, readback=%d, touch=%d/%d/%d/%d)"
		% [fade_ok, toggled, xf_ok, cd_ok, xforms_ok, cpu_copies, buf_readbacks, mesh_touches, snap_touches, hidden_touches, off_touches])
	cv3.queue_free()
	var shader_text := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	check(shader_text.contains("instance uniform float f3d_lod_fade = 1.0;") and shader_text.contains("!IN_SHADOW_PASS"),
		"models cross-fade levels with a screen-door dither, shadows left whole")
	cv.queue_free()


## D5, D6, D13: what keeps a big base smooth. Shadows only from chunks that can shade what the
## camera sees, through simplified stand-ins; models get LODs of their own; the Level of detail
## setting; batched datagrams from the mod; messages handled within a frame's budget; chunk
## rebuilds within a time budget.


func _performance() -> void:
	# The probes' own timings are kept only while --stutter-probe runs (Probing.on), so a normal
	# game doesn't time each animated group every frame.
	var probed := WorldMirror.new()
	var probing_was := Probing.on
	Probing.on = false
	ChunkView.counters.clear()
	probed._prof("test", Time.get_ticks_usec() - 5)
	ChunkView.count("test")
	var kept_off := probed.prof.size() + ChunkView.counters.size()
	Probing.on = true
	probed._prof("test", Time.get_ticks_usec() - 5)
	ChunkView.count("test")
	var kept_on := probed.prof.has("test") and int(ChunkView.counters.get("test", 0)) == 1
	Probing.on = probing_was
	ChunkView.counters.clear()
	probed.free()
	check(kept_off == 0 and kept_on, "probe timings and counts are kept only while a probe reads them (off: %d kept)" % kept_off)
	# The region whose casters can shade the view, and the rectangle test against it.
	var hull := PackedVector2Array([Vector2(0, 0), Vector2(100, 0), Vector2(100, 100), Vector2(0, 0)])
	check(WorldMirror._rect_meets_hull(Rect2(10, 10, 32, 32), hull) and not WorldMirror._rect_meets_hull(Rect2(10, 60, 20, 20), hull)
		and not WorldMirror._rect_meets_hull(Rect2(-100, -100, 32, 32), hull),
		"a chunk inside the shadow region casts, one beyond its slanted edge or far away doesn't")
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
	check(WorldMirror._rect_meets_hull(Rect2(-16, -16, 32, 32), region) and not WorldMirror._rect_meets_hull(Rect2(320, 320, 32, 32), region),
		"the shadow region holds the ground round the focus, not chunks 300 tiles behind the camera")
	_sun_shadows(cam, sun)
	# A world's chunks: near ones cast at full detail, far ones simplified, ones behind none. (--tight-cull=off: the
	# old region reaches (-3, -3), 64-96 tiles ahead under the ground; --tight-cull's ground slab doesn't, so it casts none.)
	var tight_on := ViewPriority.tight_cull
	for tight: bool in [false, true]:
		ViewPriority.tight_cull = tight
		var world := WorldMirror.new()
		world.sun = sun
		add_child(world)
		for c in [Vector2i(0, 0), Vector2i(-3, -3), Vector2i(9, 9)]:
			var cv := ChunkView.new()
			cv.coord = c
			world.chunks[c] = cv
			world.add_child(cv)
		world.shadow_usec = 1 << 40  # all three in one call, whatever the frame's budget has left
		world._update_shadow_casters()
		var ahead_tier := ChunkView.SHADOWS_NONE if tight else ChunkView.SHADOWS_FAR
		check(world.chunks[Vector2i(0, 0)].shadow_tier == ChunkView.SHADOWS_NEAR and world.chunks[Vector2i(-3, -3)].shadow_tier == ahead_tier
			and world.chunks[Vector2i(9, 9)].shadow_tier == ChunkView.SHADOWS_NONE and world.shadow_casters == (1 if tight else 2),
			"shadow tiers%s: near the focus full, further out simplified, behind the camera none: %s" % ["" if tight else " (--tight-cull=off)", world.chunks.values().map(func(cv): return cv.shadow_tier)])
		world.queue_free()
	ViewPriority.tight_cull = tight_on
	sun.queue_free()
	cam.queue_free()
	# Batch 2 #5: Inserter LOD scaling, far-chunk keep, shadow retention, and Ultra lod_quality preset.
	check(str(Settings.PRESETS.get("ultra", {}).get("lod_quality", "")) == "ultra",
		"B2#5: Ultra preset sets lod_quality='ultra'")
	var was_dist_scale := ModelLods.distance_scale
	var was_scale_untex := ModelLods.scale_untextured
	var was_qual := ModelLods.quality_name
	var was_far_keep := FarChunks.keep_inserters
	var was_ins_shad := ChunkView.keep_inserter_shadows
	ModelLods.distance_scale = 2.0
	ModelLods.scale_untextured = true
	var err_scaled := ModelLods.switch_error([null, 0.5])
	ModelLods.scale_untextured = false
	var err_old := ModelLods.switch_error([null, 0.5])
	check(is_equal_approx(err_scaled, 1.0) and is_equal_approx(err_old, 0.5),
		"B2#5: untextured LOD error scales with distance_scale (%.2f) unless --inserter-lod-scale=old (%.2f)" % [err_scaled, err_old])
	ModelLods.quality_name = "high"
	FarChunks.keep_inserters = true
	var far_kept_high := FarChunks._kept_type("inserter")
	ModelLods.quality_name = "ultra"
	var far_kept_ultra := FarChunks._kept_type("inserter")
	ModelLods.quality_name = "medium"
	var far_kept_med := FarChunks._kept_type("inserter")
	ModelLods.quality_name = "high"
	FarChunks.keep_inserters = false
	var far_kept_off := FarChunks._kept_type("inserter")
	check(far_kept_high and far_kept_ultra and not far_kept_med and not far_kept_off,
		"B2#5: FarChunks keeps inserters on High/Ultra unless --inserter-far-keep=off (high=%s ultra=%s med=%s off=%s)" % [far_kept_high, far_kept_ultra, far_kept_med, far_kept_off])
	var small_box := BoxMesh.new()
	small_box.size = Vector3(0.2, 0.2, 0.2)
	ModelLods.quality_name = "high"
	ChunkView.keep_inserter_shadows = true
	var culled_high := ChunkView.too_low_to_cast(small_box, ChunkView.SHADOWS_FAR, "inserter")
	ModelLods.quality_name = "medium"
	var culled_med := ChunkView.too_low_to_cast(small_box, ChunkView.SHADOWS_FAR, "inserter")
	ModelLods.quality_name = "high"
	ChunkView.keep_inserter_shadows = false
	var culled_old := ChunkView.too_low_to_cast(small_box, ChunkView.SHADOWS_FAR, "inserter")
	check(not culled_high and culled_med and culled_old,
		"B2#5: inserter shadows kept beyond near rings on High/Ultra unless --inserter-shadows=old (culled high=%s med=%s old=%s)" % [culled_high, culled_med, culled_old])
	ChunkView._tops.erase(small_box.get_instance_id())
	ModelLods.distance_scale = was_dist_scale
	ModelLods.scale_untextured = was_scale_untex
	ModelLods.quality_name = was_qual
	FarChunks.keep_inserters = was_far_keep
	ChunkView.keep_inserter_shadows = was_ins_shad

	# Batch 3 C7: Near-tree real shadows skip tree stand-ins on SHADOWS_NEAR (--near-tree-real-shadows=off).
	var crown_proxy := ArrayMesh.new()
	var c_verts := PackedVector3Array([Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(0, 2, 0)])
	var c_arr := []
	c_arr.resize(Mesh.ARRAY_MAX)
	c_arr[Mesh.ARRAY_VERTEX] = c_verts
	crown_proxy.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, c_arr)
	crown_proxy.surface_set_material(0, ModelLods.leaf_material())
	var plain_proxy := ArrayMesh.new()
	plain_proxy.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, c_arr)
	check(ModelLods.has_crown(crown_proxy) and not ModelLods.has_crown(plain_proxy),
		"C7: ModelLods.has_crown detects leaf-material tree proxies")
	ModelLods._ready[crown_proxy] = true
	var tree_cv := ChunkView.new()
	var tree_mmi := MultiMeshInstance3D.new()
	var proxy_mmi := MultiMeshInstance3D.new()
	tree_cv.add_child(tree_mmi)
	tree_cv.add_child(proxy_mmi)
	tree_cv._shadow_pairs.append([tree_mmi, proxy_mmi, crown_proxy])
	add_child(tree_cv)
	var was_near_tree := ChunkView.near_tree_real_shadows
	ChunkView.near_tree_real_shadows = true
	tree_cv.shadow_tier = ChunkView.SHADOWS_NEAR
	tree_cv._apply_shadows()
	var near_standin_hidden := not proxy_mmi.visible
	tree_cv.shadow_tier = ChunkView.SHADOWS_FAR
	tree_cv._apply_shadows()
	var far_standin_shown := proxy_mmi.visible
	ChunkView.near_tree_real_shadows = false
	tree_cv.shadow_tier = ChunkView.SHADOWS_NEAR
	tree_cv._apply_shadows()
	var off_standin_shown := proxy_mmi.visible
	check(near_standin_hidden and far_standin_shown and off_standin_shown,
		"C7: SHADOWS_NEAR keeps real tree shadows (stand-in hidden=%s), FAR uses stand-in (%s), --near-tree-real-shadows=off restores stand-in (%s)" % [near_standin_hidden, far_standin_shown, off_standin_shown])
	ChunkView.near_tree_real_shadows = was_near_tree
	ModelLods._ready.erase(crown_proxy)
	tree_cv.queue_free()
	# Picking what's under the mouse uses an index of selection boxes: the same answers as testing
	# every entity, and it follows entities coming and going.
	var pw := WorldMirror.new()
	pw.pick_build_usec = 1 << 40  # the whole index at once (in play it is built over frames)
	add_child(pw)
	pw.protos.add_entities([[1, "transport-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[2, "assembling-machine-1", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 120, 120, 120, 3, 3],
		[3, "iron-ore", "resource", -0.5, -0.5, 0.5, 0.5, 100, 100, 160, 1, 1]])
	for c in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
		var pcv := ChunkView.new()
		pcv.coord = c
		pw.chunks[c] = pcv
		pw.add_child(pcv)
	var unit := 1
	for x in range(-6, 40, 3):
		for y in range(-2, 40, 3):
			pw._add([unit, 2 if (x + y) % 2 == 0 else 1, x * 256 + 128, y * 256 + 128, 0])
			unit += 1
			pw._add([unit, 3, x * 256 + 128, y * 256 + 128, 0])
			unit += 1
	var brute := func(point: Vector2) -> Object:
		var best: Object = null
		var area := INF
		for r in pw.entities.values():
			var proto: ProtoDB.EntityProto = pw.protos.entity(r.proto_id)
			var rect := WorldMirror.selection_rect(proto, r.pos, r.dir)
			var a := rect.get_area() + (1000.0 if proto.type == "resource" else 0.0)
			if rect.has_point(point) and a < area:
				area = a
				best = r
		return best
	var same := true
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for k in 400:
		var point := Vector2(rng.randf_range(-8.0, 42.0), rng.randf_range(-4.0, 42.0))
		same = same and pw.pick(point) == brute.call(point)
	check(same, "picking from the index finds what testing every entity finds (400 points)")
	var picked = pw.pick(Vector2(3.6, 1.6))
	var picked_key = picked.key if picked != null else null
	pw._remove(picked_key)
	var after = pw.pick(Vector2(3.6, 1.6))
	check(picked != null and after != picked and after == brute.call(Vector2(3.6, 1.6)),
		"an entity removed is no longer picked (%s, then %s)" % [picked_key, after.key if after != null else null])
	# In play a chunk's index is built a slice a frame (PICK_BUILD_USEC), so walking with the mouse
	# over new busy chunks doesn't take the whole build in one frame.
	pw.pick_build_usec = 0
	var slow_cv: ChunkView = pw.chunks[Vector2i(0, 0)]
	slow_cv.pick_grid = []
	pw._pick_frame = -1
	pw._pick_grid(slow_cv)
	var partial := slow_cv.pick_grid.size() == 4 and int(slow_cv.pick_grid[3]) < slow_cv.entities.size()
	pw.pick_build_usec = 1 << 40
	pw._pick_grid(slow_cv)
	check(partial and slow_cv.pick_grid.size() == 2, "a chunk's pick index is built over frames, then kept whole")
	# Left part-built (the mouse moved off, the chunk went), it stops counting as work waiting, or
	# the frame budget keeps time for it for good.
	const FrameBudget := preload("res://scripts/world/frame_budget.gd")
	pw.pick_build_usec = 0
	slow_cv.pick_grid = []
	pw._pick_frame = -1
	pw._pick_grid(slow_cv)
	var pick_waiting := int(FrameBudget.queued.get(&"pick", 0))
	for i in 3:
		await get_tree().process_frame
	check(pick_waiting > 0 and int(FrameBudget.queued.get(&"pick", 0)) == 0,
		"a pick index left part-built reserves no frame budget (%d waiting, then %d)" % [pick_waiting, int(FrameBudget.queued.get(&"pick", 0))])
	pw.queue_free()
	# Chunks stream in a few at a time, nearest first: walking at a long view distance asked for a
	# whole row at once (owner's desktop, 18 fps running).
	var was_legacy_w2 := WorldMirror.stream_window_legacy
	var was_lookahead_w2 := WorldMirror.stream_lookahead
	WorldMirror.stream_window_legacy = true
	WorldMirror.stream_lookahead = false
	var sw := WorldMirror.new()
	add_child(sw)
	sw.view_radius = 10
	sw._update_subscription(0.2)
	var first: Array = sw._subscribed.duplicate()
	var nearest := first.all(func(c: Vector2i) -> bool: return c.length_squared() <= 10)  # the 32 nearest
	for c in first:
		var cv: ChunkView = sw.chunks[c]
		cv.loaded = true
		cv.tile_ids = PackedInt32Array()
	sw.set_focus(Vector2(40.0, 0.0))  # walked into the next chunk east
	sw._update_subscription(0.2)
	check(first.size() == WorldMirror.STREAM_STILL and nearest and sw._subscribed.size() == WorldMirror.STREAM_STILL + WorldMirror.STREAM_MOVING,
		"chunks are asked for a few at a time, nearest first, a standing start's worth, then fewer while walking once those are drawn: %d then %d" % [first.size(), sw._subscribed.size()])
	# A jump (a teleport, another surface, a Factorissimo building's door) has nothing of its new
	# square yet: it loads as a standing start, not a few chunks at a time as walking does, even
	# straight after walking (into the door). Walking into the door had it at 8 for 1.5 s.
	for c in sw._subscribed:
		var cv: ChunkView = sw.chunks[c]
		cv.loaded = true
		cv.tile_ids = PackedInt32Array()
	sw.set_focus(Vector2(32.0 * 60.0, 32.0 * 40.0))
	sw._update_subscription(0.2)
	var jumped := sw._subscribed.filter(func(c: Vector2i) -> bool: return (c - Vector2i(60, 40)).length_squared() <= 100)
	check(jumped.size() == WorldMirror.STREAM_STILL, "after a jump a standing start's worth of chunks is asked for at once: %d" % jumped.size())
	sw.reset(true, 7)
	sw.set_focus(Vector2(32.0 * 60.0 + 40.0, 32.0 * 40.0))
	sw._update_subscription(0.2)
	check(sw._subscribed.size() == WorldMirror.STREAM_STILL, "and after a surface change, the chunk next door or not: %d" % sw._subscribed.size())
	sw._update_subscription(0.05)
	var waited := sw._subscribed.size()
	for c in sw._subscribed:
		var cv: ChunkView = sw.chunks[c]
		cv.loaded = true
		cv.tile_ids = PackedInt32Array()
	sw._update_subscription(0.05)
	check(waited == WorldMirror.STREAM_STILL and sw._subscribed.size() == 2 * WorldMirror.STREAM_STILL,
		"standing, the next chunks are asked for as soon as those on their way are drawn, not a step later: %d, %d" % [waited, sw._subscribed.size()])
	sw.queue_free()
	WorldMirror.stream_window_legacy = was_legacy_w2
	WorldMirror.stream_lookahead = was_lookahead_w2
	# Copies of models' materials made without asking the RenderingServer (copy_material) match duplicate().
	var source_mat := ModelLibrary.mesh_for("assembling-machine-1").surface_get_material(0) as ShaderMaterial
	var copied := ModelLods.copy_material(source_mat)
	var duplicated := source_mat.duplicate() as ShaderMaterial
	var params_match := copied.shader == duplicated.shader and copied.resource_name == duplicated.resource_name
	for u: Dictionary in source_mat.shader.get_shader_uniform_list():
		var a: Variant = copied.get_shader_parameter(u["name"])
		var b: Variant = duplicated.get_shader_parameter(u["name"])
		params_match = params_match and (a == b or (a == null and b == RenderingServer.shader_get_parameter_default(source_mat.shader.get_rid(), u["name"])))
	check(params_match, "a material copied for a model has the shader, name and parameters duplicate() gives")
	check(ModelLibrary._source("assembling-machine-1").begins_with(ModelLibrary.GLTF_SOURCE),
		"models are read from their .glb (also in an exported game, addons/zenith_export ships them)")
	# A modeller's folder (--models=) only fills gaps, unless --models-first lets it replace a model.
	var outside := OS.get_user_data_dir().path_join("test-models")
	DirAccess.make_dir_recursive_absolute(outside)
	DirAccess.copy_absolute(ProjectSettings.globalize_path(_own_glb("wooden-chest")), outside.path_join("iron-chest.glb"))
	var saved_packs := ModelLibrary.ModelPacks.packs
	ModelLibrary.ModelPacks.use([ModelLibrary.ModelPacks.folder_pack(outside, false)])
	ModelLibrary._sources.erase("iron-chest")
	check(not ModelLibrary._source("iron-chest").contains(outside), "a --models folder doesn't replace a model the project has")
	ModelLibrary.ModelPacks.use([ModelLibrary.ModelPacks.folder_pack(outside, true)])
	ModelLibrary._sources.erase("iron-chest")
	check(ModelLibrary._source("iron-chest") == ModelLibrary.GLTF_SOURCE + outside.path_join("iron-chest.glb"),
		"with --models-first the folder's model replaces the project's own")
	ModelLibrary.ModelPacks.use(saved_packs)
	ModelLibrary._sources.erase("iron-chest")
	DirAccess.remove_absolute(outside.path_join("iron-chest.glb"))
	# A model's stand-in and its own LODs, made on a worker thread.
	var mesh := ModelLibrary.mesh_for("assembling-machine-1")
	var surfaces := mesh.get_surface_count()
	var proxy := ModelLods.proxy_for(mesh)
	# Every model the test drew before queued its own job: wait for this one (up to a minute).
	var until := Time.get_ticks_msec() + 60000
	while proxy != null and not ModelLods.is_ready(proxy) and Time.get_ticks_msec() < until:
		ModelLods.poll()
		await get_tree().process_frame
	check(proxy != null and ModelLods.is_ready(proxy) and proxy.get_surface_count() == 1,
		"a model gets a one-surface shadow stand-in, its levels of detail queued after it (%s, %d jobs waiting)" % [proxy, ModelLods._queue.size()])
	check(mesh.get_surface_count() == surfaces and mesh.surface_get_material(0) is ShaderMaterial,
		"the assembler keeps its surfaces and materials when given its LODs")
	await _lod_level_checks(mesh, surfaces)
	# Settings > Graphics > Merged materials (off by default): one material per model, burner drill's
	# materials rows of one surface's material; off, a surface per material as before.
	var merged_default: bool = Settings.DEFAULTS["graphics"]["merged_materials"]
	var am_load := ModelLibrary.Load.new()
	am_load.path = _own_glb("burner-mining-drill")
	am_load.combine = true
	am_load.run()
	var am2 := ModelLibrary._commit_load(am_load, [])
	var am_rows := ModelLibrary.MaterialRows.rows(am2.surface_get_material(0)).size()
	var am_plain := ModelLibrary.Load.new()
	am_plain.path = am_load.path
	am_plain.combine = false
	am_plain.run()
	var saved_merge := ModelLibrary.merge_materials
	Settings.set_value("graphics", "merged_materials", true, false)
	Settings.apply_merged_materials()
	var merge_on := ModelLibrary.merge_materials
	Settings.set_value("graphics", "merged_materials", merged_default, false)
	Settings.apply_merged_materials()
	var merge_off := ModelLibrary.merge_materials
	ModelLibrary.merge_materials = saved_merge
	check(not merged_default and merge_on and not merge_off and am2.get_surface_count() == 1 and am_rows > 1
		and (ModelLods.arrays_of(am2, 0)[Mesh.ARRAY_CUSTOM2] as PackedFloat32Array).size() > 0 and am_plain.groups.size() == am_rows,
		"Merged materials (off by default) makes burner drill one surface, its %d materials rows of one; off, %d surfaces" % [am_rows, am_plain.groups.size()])
	check(Settings.recommended_merged_materials("NVIDIA GeForce RTX 5080") and not Settings.recommended_merged_materials("NVIDIA GeForce RTX 5060 Laptop GPU")
		and not Settings.recommended_merged_materials("Intel(R) UHD Graphics") and not Settings.recommended_merged_materials("NVIDIA GeForce RTX 4090", 16.0, 15.0),
		"Recommended turns merged materials on for a big desktop GPU whose frames the CPU holds up, off otherwise")
	check(ModelLods.proxy_for(Visuals.box_mesh()) == null, "a small mesh casts its own shadow")
	var tree_job = ModelLods._job_for(ModelLibrary.mesh_for("tree-01") as ArrayMesh)
	check(tree_job != null and tree_job.tree_cards and tree_job.view_lods == ModelLods.tree_lods and not tree_job.proxy_lods,
		"a tree keeps card-level view LODs (%s) with a whole shadow stand-in" % [ModelLods.tree_lods])
	# Forests: with SSAO on, Godot's depth prepass writes normals and roughness, so a leaf card's
	# roughness must not come from the weathering noise (each crown is a dozen cut-out layers deep:
	# a zoomed-out forest's GPU frame 17.5 -> 12.3 ms), and trees keep no per-frame LODs.
	var leaf_shader := load("res://shaders/factorio_material_leaf.gdshader") as Shader
	var include_text := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	check(leaf_shader != null and include_text.contains("// Leaves keep their base roughness")
		and include_text.contains("ROUGHNESS = mix(m_rough, 0.85, pc);"),
		"leaf cards' roughness skips the weathering, so the SSAO prepass stays cheap in forests")
	# D6: a model's first appearance is made on a worker thread. Its chunk leaves it out meanwhile
	# (nothing blocks the frame), and draws it when built again once the model is ready.
	var fresh := "cryogenic-plant"
	if ModelLibrary._cache.has(fresh):
		check(false, "the test needs %s not made yet" % fresh)
	var lprotos := ProtoDB.new()
	lprotos.add_entities([[7, fresh, "assembling-machine", -2.5, -2.5, 2.5, 2.5, 1, 1, 1, 1, 1]])
	var lcv := ChunkView.new()
	add_child(lcv)
	var lrec := WorldMirror.Rec.new()
	lrec.key = 4242
	lrec.unit = 4242
	lrec.proto_id = 7
	lrec.pos = Vector2(3, 3)
	lcv.entities[lrec.key] = lrec
	var t0 := Time.get_ticks_usec()
	lcv.build_entities(lprotos, {})
	var first_usec := Time.get_ticks_usec() - t0
	check(lcv.waiting_models and lcv._instances.is_empty() and not lcv.placeholder_keys.has(lrec.key) and not ModelLibrary._cache.has(fresh),
		"a chunk whose model isn't made yet draws nothing for it and waits (%d us, %d instances)" % [first_usec, lcv._instances.size()])
	var gen := ModelLibrary.generation
	until = Time.get_ticks_msec() + 60000
	while not ModelLibrary.ready(fresh) and Time.get_ticks_msec() < until:
		ModelLibrary.poll()
		await get_tree().process_frame
	check(ModelLibrary.generation > gen and ModelLibrary.mesh_for(fresh) != null and ModelLibrary.mesh_for(fresh).has_meta(ModelLods.ARRAYS_META),
		"the model is made on a worker thread, keeping its arrays on the CPU (no GPU read-back later)")
	lcv.build_entities(lprotos, {})
	var drawn := lcv._instances.any(func(mmi: MultiMeshInstance3D) -> bool: return mmi.multimesh.mesh == ModelLibrary.mesh_for(fresh))
	check(not lcv.waiting_models and drawn, "built again, the chunk draws the model")
	lcv.queue_free()
	# Settings > Graphics > Level of detail & custom LOD falloff distance.
	var rd_script: GDScript = preload("res://scripts/world/render_distance.gd")
	var lod_was := str(Settings.get_value("graphics", "lod_quality"))
	var dist_was: int = int(Settings.get_value("graphics", "lod_distance"))
	var dist_had: bool = Settings.has_value("graphics", "lod_distance")
	var old_low_was: bool = ModelLods.old_low_lod
	check(str(Settings.DEFAULTS["graphics"]["lod_quality"]) == "medium" and int(Settings.DEFAULTS["graphics"]["lod_distance"]) == 0,
		"Level of detail defaults to medium and custom lod_distance defaults to 0 (Auto)")
	ModelLods.old_low_lod = false
	ModelLods.apply_quality("low", get_viewport())
	BeltLods.apply_lod_quality("low")
	ItemCardsScript.apply_lod_quality("low")
	var lanes_probe := BeltLanesScript.new()
	lanes_probe.apply_lod_quality("low")
	var low_items: Vector2 = ItemCardsScript.character_thresholds("low")
	var low_tree_err: float = ModelLods.switch_error([null, 0.01, 0.25])
	check(is_equal_approx(get_viewport().mesh_lod_threshold, 7.5) and is_equal_approx(ModelLods.lod_bias, 0.5)
		and is_equal_approx(ModelLods.distance_scale, 0.52) and is_equal_approx(low_tree_err, 0.25 * 7.5 * 0.52)
		and is_equal_approx(BeltLods.lod_scale, 1.9) and BeltLods.flat_at(35.0, false, false)
		and low_items.x < 14.0 and low_items.y < 30.0 and is_equal_approx(lanes_probe.far_3d_dist, 18.0),
		"low: 7.5 px (~half range), shadows 15 px, belts 1.9x, items (%.1f/%.1f), 3D lanes %.0f" % [
			low_items.x, low_items.y, lanes_probe.far_3d_dist])
	ModelLods.old_low_lod = true
	ModelLods.apply_quality("low", get_viewport())
	BeltLods.apply_lod_quality("low")
	ItemCardsScript.apply_lod_quality("low")
	lanes_probe.apply_lod_quality("low")
	var old_low_items: Vector2 = ItemCardsScript.character_thresholds("low")
	check(is_equal_approx(get_viewport().mesh_lod_threshold, 4.0) and is_equal_approx(ModelLods.distance_scale, 1.0)
		and is_equal_approx(BeltLods.lod_scale, 1.0) and old_low_items.x > 18.0 and is_equal_approx(lanes_probe.far_3d_dist, 32.0),
		"--lod-low=old restores prior Low LOD distances")
	ModelLods.old_low_lod = old_low_was

	ModelLods.apply_quality("medium", get_viewport(), 24.0)
	BeltLods.apply_lod_quality("medium", 24.0)
	ItemCardsScript.apply_lod_quality("medium", 24.0)
	lanes_probe.apply_lod_quality("medium", 24.0)
	var th24: Vector2 = ItemCardsScript.character_thresholds()
	var rd24: Dictionary = rd_script.resolve(500, "medium", false, 0, "medium", "balanced", {}, 24.0)
	var snap24 := [get_viewport().mesh_lod_threshold, ModelLods.distance_scale, BeltLods.lod_scale, th24.x, lanes_probe.far_3d_dist, float(rd24["far_merge_scale"])]

	ModelLods.apply_quality("medium", get_viewport(), 48.0)
	BeltLods.apply_lod_quality("medium", 48.0)
	ItemCardsScript.apply_lod_quality("medium", 48.0)
	lanes_probe.apply_lod_quality("medium", 48.0)
	var th48: Vector2 = ItemCardsScript.character_thresholds()
	var rd48: Dictionary = rd_script.resolve(500, "medium", false, 0, "medium", "balanced", {}, 48.0)
	var snap48 := [get_viewport().mesh_lod_threshold, ModelLods.distance_scale, BeltLods.lod_scale, th48.x, lanes_probe.far_3d_dist, float(rd48["far_merge_scale"])]

	ModelLods.apply_quality("medium", get_viewport(), 96.0)
	BeltLods.apply_lod_quality("medium", 96.0)
	ItemCardsScript.apply_lod_quality("medium", 96.0)
	lanes_probe.apply_lod_quality("medium", 96.0)
	var th96: Vector2 = ItemCardsScript.character_thresholds()
	var rd96: Dictionary = rd_script.resolve(500, "medium", false, 0, "medium", "balanced", {}, 96.0)
	var snap96 := [get_viewport().mesh_lod_threshold, ModelLods.distance_scale, BeltLods.lod_scale, th96.x, lanes_probe.far_3d_dist, float(rd96["far_merge_scale"])]
	check(float(snap24[0]) > float(snap48[0]) and float(snap48[0]) > float(snap96[0])
		and float(snap24[1]) < float(snap48[1]) and float(snap48[1]) < float(snap96[1])
		and float(snap24[2]) > float(snap48[2]) and float(snap48[2]) > float(snap96[2])
		and float(snap24[3]) < float(snap48[3]) and float(snap48[3]) < float(snap96[3])
		and float(snap24[4]) < float(snap48[4]) and float(snap48[4]) < float(snap96[4])
		and float(snap24[5]) > float(snap48[5]) and float(snap48[5]) > float(snap96[5]),
		"custom lod_distance (24/48/96) auto-adjusts all LOD systems monotonically: %s / %s / %s" % [snap24, snap48, snap96])

	const LampLightsPerf := preload("res://scripts/world/lamp_lights.gd")
	const SignalLightsPerf := preload("res://scripts/world/signal_lights.gd")
	const WorkingGlowPerf := preload("res://scripts/world/working_glow.gd")
	var lp_probe := LampLightsPerf.new()
	var sg_probe := SignalLightsPerf.new()
	var wg_probe := WorkingGlowPerf.new()
	lp_probe.apply_lod_quality("high", 24.0)
	sg_probe.apply_lod_quality("high", 24.0)
	wg_probe.apply_lod_quality("high", 24.0)
	var l24: float = lp_probe._compute_detail_distance()
	var s24: float = sg_probe._compute_detail_distance()
	var w24: float = wg_probe._effective_radius()
	lp_probe.apply_lod_quality("high", 96.0)
	sg_probe.apply_lod_quality("high", 96.0)
	wg_probe.apply_lod_quality("high", 96.0)
	var l96: float = lp_probe._compute_detail_distance()
	var s96: float = sg_probe._compute_detail_distance()
	var w96: float = wg_probe._effective_radius()
	lp_probe.free()
	sg_probe.free()
	wg_probe.free()
	check(w24 < 60.0 and l24 < l96 and s24 < s96 and w24 < w96,
		"custom lod_distance scales light/glow LOD distances down on High too (24 vs 96): lamps %.1f/%.1f signals %.1f/%.1f glow %.1f/%.1f" % [
			l24, l96, s24, s96, w24, w96])

	ModelLods.apply_quality("high", get_viewport())
	check(is_equal_approx(get_viewport().mesh_lod_threshold, 1.0) and is_equal_approx(ModelLods.lod_bias, 1.0), "high: Godot's pixel, the shadows' too")
	ModelLods.apply_quality("medium", get_viewport())
	BeltLods.apply_lod_quality(lod_was, float(dist_was) if dist_had else 0.0)
	ItemCardsScript.apply_lod_quality(lod_was, float(dist_was) if dist_had else 0.0)
	lanes_probe.queue_free()
	ModelLods.apply_quality(lod_was, get_viewport(), float(dist_was) if dist_had else 0.0)
	check(is_equal_approx(get_viewport().mesh_lod_threshold, 4.0) or lod_was != "medium",
		"medium (High's preset): 4 px, 2 ms less GPU on the owner's base than 2 with no visible change")

	var window := SettingsWindow.new()
	add_child(window)
	var found := window.find_children("*", "", true, false).any(func(n: Node) -> bool: return n is Label and (n as Label).text == "Level of detail")
	var lod_dist_slider := window.find_child("graphics-lod_distance", true, false) as HSlider
	var lod_dist_val := window.find_child("graphics-lod_distance-value", true, false) as Button
	var dist_auto_ok := lod_dist_slider != null and int(lod_dist_slider.value) == 0 and lod_dist_val != null and lod_dist_val.text == "Auto"
	var dist_custom_ok := false
	if lod_dist_slider != null:
		lod_dist_slider.value = 32.0
		lod_dist_slider.drag_ended.emit(true)
		dist_custom_ok = lod_dist_val != null and lod_dist_val.text == "32 tiles" and int(Settings.get_value("graphics", "lod_distance")) == 32
		lod_dist_slider.value = float(dist_was) if dist_had else 0.0
		lod_dist_slider.drag_ended.emit(true)
	if not dist_had:
		Settings.reset_value("graphics", "lod_distance")
	check(found and dist_auto_ok and dist_custom_ok, "the settings window offers Level of detail and Performance > More LOD falloff distance")
	window.queue_free()
	# Batched datagrams (hello b) and the frame budget for handling messages.
	var b = load("res://scripts/net/bridge.gd").new()
	var got: Array = []
	b.message_received.connect(func(msg: Dictionary) -> void: got.append(str(msg.get("t"))))
	b.receive('{"t":"welcome","r":1,"v":1,"k":1,"mod":"0.1.3"}'.to_utf8_buffer())
	check(b.mod_version == "0.1.3", "the welcome's mod version is kept (for a bug report): %s" % b.mod_version)
	b.receive('{"t":"sky","k":2}\n{"t":"me","k":2}\n{"t":"mv","k":2,"l":[]}'.to_utf8_buffer())
	check(got == ["sky", "me", "mv"], "several messages in one datagram, joined by newlines, are each handled: %s" % [got])
	got.clear()
	var lines: Array = []
	for i in 3000:
		lines.append('{"t":"sky","k":%d}' % (3 + i))
	b._queue("\n".join(lines).to_utf8_buffer())
	var slow := func(_msg: Dictionary) -> void: OS.delay_usec(20)
	b.message_received.connect(slow)
	b._drain()
	check(got.size() > 0 and got.size() < 3000 and b.waiting_count() == 3000 - got.size(),
		"a frame handles messages for its time budget and leaves the rest for the next: %d now, %d waiting" % [got.size(), b.waiting_count()])
	while b.waiting_count() > 0:
		b._drain()
	check(got.size() == 3000, "... and they are all handled in order over the next frames")
	# Messages that have waited past --message-catchup-msec since their datagram was read are behind
	# (their frame's slice then is the whole of theirs, frame_budget.gd); fresh ones, or the switch off, not.
	b._queue('{"t":"sky","k":4000}\n{"t":"sky","k":4001}'.to_utf8_buffer())
	var q_now := Time.get_ticks_usec()
	var q_fresh: bool = b.behind(q_now)
	b._waiting_usec[b._waiting_at] = q_now - b.catchup_usec - 1000
	var q_old: bool = b.behind(q_now)
	b.message_catchup = false
	var q_off: bool = b.behind(q_now)
	b.message_catchup = true
	check(not q_fresh and q_old and not q_off and b.waiting_msec() >= b.catchup_usec / 1000 and b._waiting_usec.size() == b._waiting.size(),
		"messages are behind once the oldest has waited over %d ms (fresh %s, old %s, switched off %s)" % [b.catchup_usec / 1000, q_fresh, q_old, q_off])
	while b.waiting_count() > 0:
		b._drain()
	check(b.waiting_msec() == 0 and not b.behind(Time.get_ticks_usec()), "... and not once they are handled")
	# --belt-messages-first (on): the belt simulation's updates (bs) are handled before the others waiting, but never
	# ahead of a welcome or surface still waiting (they start the belts over), nor of belt messages queued behind one;
	# the inserters' events (ie) stay in order.
	got.clear()
	var lens := PackedInt32Array([10, 10, 10])
	var now_q := Time.get_ticks_usec()
	b._route([{"t": "sky", "k": 5000}, {"t": "bs", "k": 5000}, {"t": "sky", "k": 5001}], lens, now_q)
	var ahead: Array = b._belt_waiting.duplicate()
	while b.waiting_count() > 0 or not b._belt_waiting.is_empty():
		b._drain()
	var first_order: Array = got.duplicate()
	got.clear()
	b._route([{"t": "surface", "r": b._expected_r, "k": 5002}, {"t": "bs", "k": 5002}], PackedInt32Array([10, 10]), now_q)
	var held_back: bool = b._belt_waiting.is_empty() and b._belt_barriers == 1 and b._belts_behind == 1
	b._route([{"t": "bs", "k": 5003}], PackedInt32Array([10]), now_q)
	var still_behind: bool = b._belt_waiting.is_empty() and b._belts_behind == 2
	b._route([{"t": "ie", "k": 5003}], PackedInt32Array([10]), now_q)
	var ie_in_order: bool = b._belt_waiting.is_empty() and b._belts_behind == 2
	while b.waiting_count() > 0 or not b._belt_waiting.is_empty():
		b._drain()
	var after_barrier: Array = got.duplicate()
	b._route([{"t": "bs", "k": 5004}], PackedInt32Array([10]), now_q)
	var fast_again: bool = b._belt_waiting.size() == 1 and b._belt_barriers == 0 and b._belts_behind == 0
	b._drain()
	check(ahead.size() == 1 and first_order == ["bs", "sky", "sky"] and held_back and still_behind
		and ie_in_order and after_barrier == ["surface", "bs", "bs", "ie"] and fast_again,
		"--belt-messages-first: a bs is handled ahead of the messages before it %s, but behind a surface still waiting %s (held %s %s, fast again %s)" % [first_order, after_barrier, held_back, still_behind, fast_again])
	b.free()
	# Chunk rebuilds stop at their time budget (at least one a frame).
	var build_slice := int(preload("res://scripts/world/frame_budget.gd").SYSTEMS[&"build"][1])
	check(build_slice > 0 and build_slice <= 8000, "chunk rebuilds have a frame time budget")


## The debug menu (debug_menu.gd): Ctrl+F12 opens it; its Time controls and spots send /f3d-debug
## through the bridge and follow the state the bridge answers (`cmdr` dbg), greyed with the reason
## when the bridge refuses (na: multiplayer, not an admin) or doesn't know the command; the tests
## ask the bridge; a benchmark's report compares with the last run, copies and saves; Esc closes.
