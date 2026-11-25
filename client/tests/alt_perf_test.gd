extends Node3D
## Tests for Alt-mode performance optimizations:
## (a) AltOverlay per-chunk cache, idle redraw skip, invalidation, culling, and parity vs --alt-cache=off.
## (b) AltOverlay _flat mode (>600 mixed icons) overlap-safe texture batching vs --alt-flat-batch-tex=off.
## (c) AltArrows and QualityMarks buffer reuse, throttling, selective layer uploads, and exact parity.

const WorldMirror := preload("res://scripts/world/world.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")
const AltOverlay := preload("res://scripts/ui/factorio/alt_overlay.gd")
const AltArrows := preload("res://scripts/world/alt_arrows.gd")
const QualityMarks := preload("res://scripts/world/quality_marks.gd")
const FluidsPower := preload("res://scripts/world/fluids_power.gd")
const MoverLayer := preload("res://scripts/world/movers.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const SettingsFile := preload("res://scripts/menu/settings.gd")
const Slot := preload("res://scripts/ui/factorio/slot.gd")
const Kit := preload("res://scripts/ui/factorio/kit.gd")
const ModGraphics := preload("res://scripts/world/mod_graphics.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")

var passes := 0
var fails := 0


class MockBeltItems:
	extends Node
	var tick := 10.0
	var positions := {}  # uid -> Vector3

	func drawn_tick() -> float:
		return tick

	func position_of(uid: int) -> Variant:
		return positions.get(uid, null)


func check(cond: bool, msg: String) -> void:
	if cond:
		passes += 1
	else:
		fails += 1
		print("FAIL: %s" % msg)


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	await _test_alt_overlay_cache_and_idle()
	await _test_alt_overlay_flat_batching()
	_test_alt_arrows_opt()
	_test_quality_marks_opt()
	await get_tree().process_frame
	await get_tree().process_frame
	print("alt_perf_test: %d passed, %d failed" % [passes, fails])
	print("FAILS: %d" % fails)
	get_tree().quit(1 if fails > 0 else 0)


static func _sorted_vec3s(arr: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for v: Vector3 in arr:
		out.append("%.3f,%.3f,%.3f" % [v.x, v.y, v.z])
	out.sort()
	return out


static func _paint_signature(list: Array) -> Array:
	var out: Array = []
	for entry: Array in list:
		var kind := str(entry[0])
		var tex: Texture2D = entry[1]
		var rect: Rect2 = entry[2]
		var depth: float = float(entry[3])
		out.append("%s:%d:%.2f,%.2f,%.2f,%.2f:%.3f" % [
			kind,
			tex.get_instance_id() if tex != null else 0,
			rect.position.x, rect.position.y, rect.size.x, rect.size.y,
			depth,
		])
	return out


func _test_alt_overlay_cache_and_idle() -> void:
	var prev_cache := AltOverlay.use_cache
	var prev_spec := AltOverlay.use_spec
	var prev_ammo := AltOverlay.ammo_fuel
	var prev_order := AltOverlay.icon_order
	var prev_alt_contents: int = Bridge.alt_contents
	var prev_loco: bool = Bridge.loco_fuel_icons
	var win_before := get_window().size
	get_window().size = Vector2i(1280, 720)

	var holder := Node3D.new()
	add_child(holder)
	var w := WorldMirror.new()
	holder.add_child(w)
	w.protos.add_entities([
		[1, "assembling-machine-2", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3],
		[2, "fast-inserter", "inserter", -0.4, -0.4, 0.4, 0.4, 80, 80, 80, 1, 1],
		[3, "wooden-chest", "container", -0.35, -0.35, 0.35, 0.35, 100, 100, 100, 1, 1],
		[4, "beacon", "beacon", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3],
		[5, "pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 80, 80, 80, 1, 1],
		[6, "storage-tank", "storage-tank", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3],
		[7, "cargo-wagon", "cargo-wagon", -1.0, -3.0, 1.0, 3.0, 150, 150, 150, 2, 6],
	])
	w.chunks[Vector2i(0, 0)] = ChunkView.new()
	w.chunks[Vector2i(1, 0)] = ChunkView.new()
	w.chunks[Vector2i(30, 30)] = ChunkView.new()  # far off-screen chunk

	w._add([101, 1, 5 * 256 + 128, 5 * 256 + 128, 0, {"ai": ["recipe", "iron-gear-wheel"]}])
	w._add([102, 2, 9 * 256 + 128, 5 * 256 + 128, 0, {"ai": ["item", "iron-plate", ["copper-plate", "coal"]]}])
	w._add([103, 3, 12 * 256 + 128, 5 * 256 + 128, 0])
	w._add([104, 4, 15 * 256 + 128, 5 * 256 + 128, 0])
	w._add([105, 5, 10 * 256 + 128, 10 * 256 + 128, 0])  # tile (10, 10): 10 + 20 = 30 -> pipe_shows_icon true
	w._add([106, 6, 18 * 256 + 128, 8 * 256 + 128, 0])
	w._add([107, 1, 36 * 256 + 128, 5 * 256 + 128, 0, {"ai": ["recipe", "electronic-circuit"]}])  # chunk (1, 0)
	w._add([108, 1, (30 * 32 + 5) * 256 + 128, (30 * 32 + 5) * 256 + 128, 0, {"ai": ["recipe", "copper-cable"]}])  # off-screen

	var fp := FluidsPower.new()
	fp.name = "FluidsPower"
	fp.world = w
	holder.add_child(fp)
	fp.fluids = {
		105: [{"fluid": "water", "amount": 50, "capacity": 100}],
		106: [{"fluid": "crude-oil", "amount": 1000, "capacity": 25000}],
	}

	var trains := MoverLayer.new()
	trains.protos = w.protos
	holder.add_child(trains)
	trains.handle({"t": "mv", "k": 1, "l": [[201, 7, 14 * 256, 12 * 256, 0]]})
	trains._process(1.0 / 60.0)

	var stub_gs := GDScript.new()
	stub_gs.source_code = "extends Node3D\nvar world\nvar rig\nvar camera: Camera3D\nvar first_person := false\nvar hovered\nvar movers\nvar remote_fog\nvar eprops := {}\n"
	stub_gs.reload()

	var rig: Node3D = stub_gs.new()
	rig.camera = Camera3D.new()
	rig.add_child(rig.camera)
	holder.add_child(rig)
	rig.camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	rig.camera.position = Vector3(14, 24, 28)
	rig.camera.look_at(Vector3(14, 0, 8))

	var fake_player: Node3D = stub_gs.new()
	fake_player.world = w
	fake_player.rig = rig
	fake_player.movers = trains
	holder.add_child(fake_player)

	var fake_model: Node3D = stub_gs.new()
	fake_model.eprops = {
		1: {"x": {"ids": [0, -0.2, 1.0], "isq": [["m", 0, 0.7, 0.5, 4, 2, 1.1, -0.1]]}},
		4: {"x": {"isq": [["m", 0, 0, 0.5, 2, 2, 1.1, -0.3]]}},
		7: {"x": {"isq": [["c", 0, 0, 0.5, 4, 1, 1.1, -0.1]]}},
	}
	holder.add_child(fake_model)

	var overlay := AltOverlay.new()
	overlay.model = fake_model
	overlay.player = fake_player
	overlay.on = true
	holder.add_child(overlay)

	var mark_standin := Slot.quality_icon("rare") == null
	if mark_standin:
		var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.2, 0.5, 1.0))
		Slot._quality_icons["rare"] = ImageTexture.create_from_image(img)

	Bridge.set_alt_contents(true)
	w.handle({"t": "ac", "g": Bridge.alt_contents, "l": [[103, "coal", ["stone"]]]})
	w.handle({"t": "am", "g": Bridge.alt_contents, "l": [
		[101, [["speed-module-3", "rare"], "productivity-module-3"], []],
		[104, ["speed-module-3", "speed-module-3"], []],
		[201, 0, ["iron-plate", "copper-plate"]],
	]})

	AltOverlay.use_spec = true
	AltOverlay.ammo_fuel = true
	AltOverlay.icon_order = true

	# 1. Exact output parity vs --alt-cache=off across 2D, hovered beacon, hills, and 3D quads.
	for hovered_state in [null, w.entities[104]]:
		fake_player.hovered = hovered_state
		AltOverlay.use_cache = false
		overlay._layers_key = []
		overlay.collect()
		var ref_drawn := overlay.drawn
		var ref_sig := _paint_signature(overlay.paint_list())

		AltOverlay.use_cache = true
		overlay._clear_caches()
		overlay._layers_key = []
		overlay.collect()
		var cached_drawn := overlay.drawn
		var cached_sig := _paint_signature(overlay.paint_list())
		check(cached_drawn == ref_drawn and cached_sig == ref_sig and cached_drawn > 0,
			"alt_overlay parity (hovered=%s): cached matches --alt-cache=off (%d vs %d)"
			% [hovered_state != null, cached_drawn, ref_drawn])

	# Hill lift parity.
	fake_player.hovered = null
	var hill := Image.create(16, 16, false, Image.FORMAT_RF)
	hill.fill(Color(5.0, 0, 0))
	GroundHeight.set_field(hill, Vector2(-8, -8), 2.0)
	AltOverlay.use_cache = false
	overlay._layers_key = []
	overlay.collect()
	var hill_ref := _paint_signature(overlay.paint_list())
	AltOverlay.use_cache = true
	overlay._layers_key = []
	overlay.collect()
	var hill_cached := _paint_signature(overlay.paint_list())
	GroundHeight.clear()
	check(hill_cached == hill_ref, "alt_overlay parity: GroundHeight hill lift matches --alt-cache=off")

	# First-person 3D quad parity.
	rig.first_person = true
	rig.camera.position = Vector3(14, 1.6, 20)
	rig.camera.look_at(Vector3(14, 1.0, 8))
	AltOverlay.use_cache = false
	overlay.collect()
	var ref_quads := _sorted_vec3s(overlay._quads.filter(func(q): return q.visible).map(func(q): return q.position))
	var ref_3d_drawn := overlay.drawn
	AltOverlay.use_cache = true
	overlay._clear_caches()
	overlay.collect()
	var cached_quads := _sorted_vec3s(overlay._quads.filter(func(q): return q.visible).map(func(q): return q.position))
	check(overlay.drawn == ref_3d_drawn and cached_quads == ref_quads,
		"alt_overlay parity: first-person 3D quads match --alt-cache=off (%d vs %d)" % [overlay.drawn, ref_3d_drawn])

	# Restore 2D view for idle redraw skip and invalidation checks.
	rig.first_person = false
	rig.camera.position = Vector3(14, 24, 28)
	rig.camera.look_at(Vector3(14, 0, 8))
	await get_tree().process_frame
	overlay.collect()
	overlay.redraws_queued = 0

	# 2. Idle redraw skip: standing still with stationary cargo wagon -> 0 queue_redraw() calls over 20 frames.
	for _f in 20:
		overlay._process(1.0 / 60.0)
	check(overlay.redraws_queued == 0,
		"alt_overlay idle: standing still skips queue_redraw() (queued=%d)" % overlay.redraws_queued)

	# Hovering a non-beacon (assembler) does NOT trigger a redraw.
	fake_player.hovered = w.entities[101]
	overlay._process(1.0 / 60.0)
	check(overlay.redraws_queued == 0,
		"alt_overlay idle: hovering non-beacon does not queue redraw (queued=%d)" % overlay.redraws_queued)

	# Hovering a beacon DOES trigger a redraw, and unhovering triggers another.
	fake_player.hovered = w.entities[104]
	overlay._process(1.0 / 60.0)
	var on_beacon := overlay.redraws_queued
	overlay.collect()
	fake_player.hovered = null
	overlay._process(1.0 / 60.0)
	var off_beacon := overlay.redraws_queued
	overlay.collect()
	check(on_beacon == 1 and off_beacon == 2,
		"alt_overlay beacon hover triggers redraws (%d -> %d)" % [on_beacon, off_beacon])

	# Camera movement triggers a redraw.
	rig.camera.position += Vector3(0.5, 0.0, 0.0)
	overlay._process(1.0 / 60.0)
	check(overlay.redraws_queued == 3,
		"alt_overlay camera movement triggers redraw (%d)" % overlay.redraws_queued)
	overlay.collect()

	# Moving cargo wagon triggers a redraw when it moves, and returns to 0 when stopped.
	trains.handle({"t": "mv", "k": 100, "l": [[201, 7, 16 * 256, 12 * 256, 0]]})
	trains._process(0.1)
	overlay._process(1.0 / 60.0)
	var on_mover := overlay.redraws_queued
	overlay.collect()
	for _f in 5:
		overlay._process(1.0 / 60.0)
	check(on_mover == 4 and overlay.redraws_queued == 4,
		"alt_overlay moving wagon redraws once moved (%d) then skips when stationary (%d)" % [on_mover, overlay.redraws_queued])

	# 3. Selective per-chunk cache invalidation: dirtying chunk (0,0) keeps chunk (1,0)'s ChunkCache intact.
	var cache_chunk_1_before: Object = overlay._chunk_alt_cache.get(Vector2i(1, 0))
	var cache_chunk_0_before: Object = overlay._chunk_alt_cache.get(Vector2i(0, 0))
	w._add([109, 1, 7 * 256 + 128, 5 * 256 + 128, 0, {"ai": ["recipe", "pipe"]}])
	w.entities_changed.emit(Vector2i(0, 0))
	overlay._process(1.0 / 60.0)
	var on_chunk_dirty := overlay.redraws_queued
	overlay.collect()
	var cache_chunk_1_after: Object = overlay._chunk_alt_cache.get(Vector2i(1, 0))
	var cache_chunk_0_after: Object = overlay._chunk_alt_cache.get(Vector2i(0, 0))
	check(on_chunk_dirty == 5 and cache_chunk_1_before != null and is_same(cache_chunk_1_before, cache_chunk_1_after)
		and cache_chunk_0_before != null and overlay.drawn > 0,
		"alt_overlay chunk cache: dirtying (0,0) preserves (1,0) cache (%s) and redraws (%d)"
		% [is_same(cache_chunk_1_before, cache_chunk_1_after), on_chunk_dirty])

	# 3b. ModGraphics.generation and ModelPacks.icons_version bumps invalidate icon caches and queue redraws.
	var prev_gfx_gen := ModGraphics.generation
	var prev_icons_ver := ModelPacks.icons_version
	ItemIcons.texture_for("iron-gear-wheel")
	var stale_img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	stale_img.fill(Color(1.0, 0.0, 1.0))
	var stale_tex := ImageTexture.create_from_image(stale_img)
	ItemIcons._textures["iron-gear-wheel"] = stale_tex
	overlay._clear_caches()
	overlay.collect()
	var had_stale := overlay._icons.has(stale_tex)
	overlay.redraws_queued = 0
	ModGraphics.generation += 1
	overlay._process(1.0 / 60.0)
	var gfx_redraws := overlay.redraws_queued
	overlay.collect()
	var stale_gone := not overlay._icons.has(stale_tex) and overlay._icons.has(Kit.item_icon("iron-gear-wheel"))
	var alt_cc_rebuilt: AltOverlay.ChunkCache = overlay._chunk_alt_cache.get(Vector2i(0, 0))
	var gfx_keys_ok: bool = alt_cc_rebuilt != null and alt_cc_rebuilt.gfx_gen == ModGraphics.generation \
		and overlay._cached_ac_gfx == ModGraphics.generation and overlay._cached_am_gfx == ModGraphics.generation \
		and overlay._cached_fl_gfx == ModGraphics.generation and not overlay._moving_machines.is_empty() \
		and overlay._moving_machines[0].gfx_gen == ModGraphics.generation
	ModelPacks.icons_version += 1
	overlay._process(1.0 / 60.0)
	var packs_redraws := overlay.redraws_queued
	overlay.collect()
	var packs_keys_ok: bool = alt_cc_rebuilt.icons_ver == ModelPacks.icons_version \
		and overlay._cached_ac_icons == ModelPacks.icons_version and overlay._cached_am_icons == ModelPacks.icons_version \
		and overlay._cached_fl_icons == ModelPacks.icons_version \
		and overlay._moving_machines[0].icons_ver == ModelPacks.icons_version
	check(had_stale and stale_gone and gfx_redraws == 1 and packs_redraws == 2 and gfx_keys_ok and packs_keys_ok,
		"alt_overlay invalidates cached textures and redraws on ModGraphics.generation / ModelPacks.icons_version bump")
	ModGraphics.generation = prev_gfx_gen
	ModelPacks.icons_version = prev_icons_ver
	ItemIcons._follow_list()
	overlay._clear_caches()

	# 4. --alt-cache=off restores unconditional per-frame redraw.
	AltOverlay.use_cache = false
	overlay.redraws_queued = 0
	for _f in 5:
		overlay._process(1.0 / 60.0)
	check(overlay.redraws_queued == 5,
		"alt_overlay --alt-cache=off queues redraw every frame (%d/5)" % overlay.redraws_queued)

	# 5. Sub-pixel skip (< 3 px) and viewport culling.
	AltOverlay.use_cache = true
	fake_model.eprops[1] = {"x": {"ids": [0, 0, 1.0], "isq": [["m", 0, 0.7, 0.15, 4, 1, 1.1, 0.0]]}}
	rig.camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	rig.camera.size = 260.0
	rig.camera.position = Vector3(14, 100, 8)
	rig.camera.look_at(Vector3(14, 0, 8), Vector3(0, 0, -1))
	overlay._clear_caches()
	overlay.collect()
	# Tiny 0.15-tile modules at 8 px parent icon -> 0.15 / 1.2 * 8 = 1.0 px < 3 px -> skipped!
	var mod_drawn := overlay._icons.has(Kit.item_icon("productivity-module-3"))
	# Place an off-viewport machine inside an in-view or near-edge chunk and confirm behind-camera culling.
	rig.camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	rig.camera.position = Vector3(14, 10, 14)
	rig.camera.look_at(Vector3(14, 0, 0))
	w._add([110, 1, 14 * 256, 30 * 256, 0, {"ai": ["recipe", "assembling-machine-1"]}])
	overlay.collect()
	check(not mod_drawn and not overlay._icons.has(Kit.item_icon("assembling-machine-1")),
		"alt_overlay skips tiny sub-pixel icons (< 3 px) and culls behind-camera entries")

	if mark_standin:
		Slot._quality_icons.erase("rare")
	Bridge.set_alt_contents(false)
	if prev_alt_contents > 0:
		Bridge.set_alt_contents(true)
	Bridge.loco_fuel_icons = prev_loco
	AltOverlay.use_cache = prev_cache
	AltOverlay.use_spec = prev_spec
	AltOverlay.ammo_fuel = prev_ammo
	AltOverlay.icon_order = prev_order
	get_window().size = win_before
	overlay.on = false
	overlay._process(0.0)
	remove_child(holder)
	holder.free()


func _count_texture_runs(list: Array) -> int:
	var runs := 0
	var prev_tex: Texture2D = null
	for entry: Array in list:
		if str(entry[0]) != "i":
			continue
		var tex: Texture2D = entry[1]
		if tex != prev_tex:
			runs += 1
			prev_tex = tex
	return runs


func _test_alt_overlay_flat_batching() -> void:
	var prev_cache := AltOverlay.use_cache
	var prev_batch_tex := AltOverlay.flat_batch_tex
	var prev_batch_marks := AltOverlay.flat_batch_marks
	var prev_cap := AltOverlay.layer_cap
	var prev_order := AltOverlay.icon_order
	var prev_alt_contents: int = Bridge.alt_contents
	var win_before := get_window().size
	get_window().size = Vector2i(1920, 1080)

	var holder := Node3D.new()
	add_child(holder)
	var w := WorldMirror.new()
	holder.add_child(w)
	w.protos.add_entities([
		[41, "assembling-machine-2", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3],
	])
	for cx in range(-2, 4):
		for cy in range(-2, 4):
			w.chunks[Vector2i(cx, cy)] = ChunkView.new()

	var recipes := ["iron-gear-wheel", "electronic-circuit", "copper-cable", "transport-belt", "inserter", "pipe"]
	var unit := 5000
	var with_mods := []
	for gy in 30:
		for gx in 30:
			w._add([unit, 41, (gx * 3 - 30) * 256 + 128, (gy * 3 - 30) * 256 + 128, 0,
				{"ai": ["recipe", recipes[(gx + gy) % recipes.size()]]}])
			if unit % 3 == 0:
				with_mods.append([unit, [["speed-module", "rare"]], []])
			unit += 1

	var mark_standin := Slot.quality_icon("rare") == null
	if mark_standin:
		var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.2, 0.5, 1.0))
		Slot._quality_icons["rare"] = ImageTexture.create_from_image(img)

	var stub_gs := GDScript.new()
	stub_gs.source_code = "extends Node3D\nvar world\nvar rig\nvar camera: Camera3D\nvar first_person := false\nvar hovered\nvar movers\nvar remote_fog\nvar eprops := {}\n"
	stub_gs.reload()

	var rig: Node3D = stub_gs.new()
	rig.camera = Camera3D.new()
	rig.add_child(rig.camera)
	holder.add_child(rig)
	rig.camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	rig.camera.size = 140.0
	var pitch := deg_to_rad(48.0)
	rig.camera.position = Vector3(16, 0, 10) + Vector3(0, sin(pitch), cos(pitch)) * 100.0
	rig.camera.look_at(Vector3(16, 0, 10))

	var fake_player: Node3D = stub_gs.new()
	fake_player.world = w
	fake_player.rig = rig
	holder.add_child(fake_player)

	var fake_model: Node3D = stub_gs.new()
	fake_model.eprops = {41: {"x": {"isq": [["m", 0, 0.7, 0.5, 4, 2, 1.1, -0.1]]}}}
	holder.add_child(fake_model)

	Bridge.set_alt_contents(true)
	w.handle({"t": "am", "g": Bridge.alt_contents, "l": with_mods})

	var overlay := AltOverlay.new()
	overlay.model = fake_model
	overlay.player = fake_player
	overlay.on = true
	holder.add_child(overlay)

	AltOverlay.use_cache = true
	AltOverlay.icon_order = true
	AltOverlay.layer_cap = 600
	AltOverlay.flat_batch_marks = true

	AltOverlay.flat_batch_tex = false
	overlay._layers_key = []
	overlay.collect()
	var unbatched_list := overlay.paint_list()
	var unbatched_runs := _count_texture_runs(unbatched_list)

	AltOverlay.flat_batch_tex = true
	overlay._layers_key = []
	overlay.collect()
	var batched_list := overlay.paint_list()
	var batched_runs := _count_texture_runs(batched_list)

	var icons: Array = batched_list.filter(func(e): return str(e[0]) == "i")
	var wrong := 0
	for a in icons.size():
		var ra: Rect2 = icons[a][2]
		var da := float(icons[a][3])
		for b in range(a + 1, icons.size()):
			if absf(da - float(icons[b][3])) > 0.01 and ra.intersects(icons[b][2]) and float(icons[b][3]) > da:
				wrong += 1

	# Compare cache-on vs cache-off collect() cost across 5 panning steps.
	var t0 := Time.get_ticks_usec()
	for k in 5:
		rig.camera.position.x += 0.2
		AltOverlay.use_cache = true
		overlay.collect()
	var cached_usec := Time.get_ticks_usec() - t0

	t0 = Time.get_ticks_usec()
	for k in 5:
		rig.camera.position.x -= 0.2
		AltOverlay.use_cache = false
		overlay.collect()
	var uncached_usec := Time.get_ticks_usec() - t0

	print("alt_perf_test _flat (size 140): %d icons, tex runs unbatched=%d -> batched=%d, wrong_occlusion=%d, 5-pan cached=%.2f ms vs uncached=%.2f ms"
		% [icons.size(), unbatched_runs, batched_runs, wrong, cached_usec / 1000.0, uncached_usec / 1000.0])

	check(overlay._flat and icons.size() == 1200 and unbatched_runs >= 800 and batched_runs <= 60 and wrong == 0,
		"_flat texture batching cuts draw runs (%d -> %d) for %d icons with 0 occlusion errors (%d)"
		% [unbatched_runs, batched_runs, icons.size(), wrong])

	# Also verify heavily-overlapping far zoom-out (ortho size 260) maintains 0 occlusion errors and large batch reduction.
	rig.camera.size = 260.0
	AltOverlay.flat_batch_tex = false
	overlay._layers_key = []
	overlay.collect()
	var far_unbatched := _count_texture_runs(overlay.paint_list())
	AltOverlay.flat_batch_tex = true
	overlay._layers_key = []
	overlay.collect()
	var far_batched_list := overlay.paint_list()
	var far_batched := _count_texture_runs(far_batched_list)
	var far_icons: Array = far_batched_list.filter(func(e): return str(e[0]) == "i")
	var far_wrong := 0
	for a in far_icons.size():
		var ra: Rect2 = far_icons[a][2]
		var da := float(far_icons[a][3])
		for b in range(a + 1, far_icons.size()):
			if absf(da - float(far_icons[b][3])) > 0.01 and ra.intersects(far_icons[b][2]) and float(far_icons[b][3]) > da:
				far_wrong += 1
	print("alt_perf_test _flat (size 260): %d icons, tex runs %d -> %d, wrong_occlusion=%d"
		% [far_icons.size(), far_unbatched, far_batched, far_wrong])
	check(overlay._flat and far_icons.size() == 1200 and far_batched < far_unbatched / 3 and far_wrong == 0,
		"_flat texture batching zoomed-out (size 260): %d -> %d runs, %d occlusion errors"
		% [far_unbatched, far_batched, far_wrong])

	if mark_standin:
		Slot._quality_icons.erase("rare")
	Bridge.set_alt_contents(false)
	if prev_alt_contents > 0:
		Bridge.set_alt_contents(true)
	AltOverlay.use_cache = prev_cache
	AltOverlay.flat_batch_tex = prev_batch_tex
	AltOverlay.flat_batch_marks = prev_batch_marks
	AltOverlay.layer_cap = prev_cap
	AltOverlay.icon_order = prev_order
	get_window().size = win_before
	overlay.on = false
	overlay._process(0.0)
	remove_child(holder)
	holder.free()


func _snapshot_arrows(layer: AltArrows) -> Dictionary:
	var layer_counts := []
	var layer_bufs := []
	for mmi: MultiMeshInstance3D in layer._layers:
		var n := mmi.multimesh.visible_instance_count
		layer_counts.append(n)
		layer_bufs.append(mmi.multimesh.buffer.slice(0, n * 12) if n > 0 else PackedFloat32Array())
	var fluid_counts := {}
	var fluid_bufs := {}
	for fluid in layer._icon_layers:
		var fmmi: MultiMeshInstance3D = layer._icon_layers[fluid]
		var fn := fmmi.multimesh.visible_instance_count
		fluid_counts[fluid] = fn
		fluid_bufs[fluid] = fmmi.multimesh.buffer.slice(0, fn * 12) if fn > 0 else PackedFloat32Array()
	return {
		"drawn": layer.drawn,
		"icons_drawn": layer.icons_drawn,
		"layer_counts": layer_counts,
		"layer_bufs": layer_bufs,
		"fluid_counts": fluid_counts,
		"fluid_bufs": fluid_bufs,
	}


func _test_alt_arrows_opt() -> void:
	var prev_opt := AltArrows.opt_enabled
	var prev_ins = SettingsFile.get_value("interface", "alt_inserter_arrows")
	var prev_pump = SettingsFile.get_value("interface", "alt_pump_arrows")
	var prev_mach = SettingsFile.get_value("interface", "alt_machine_arrows")
	SettingsFile.set_value("interface", "alt_inserter_arrows", true, false)
	SettingsFile.set_value("interface", "alt_pump_arrows", true, false)
	SettingsFile.set_value("interface", "alt_machine_arrows", true, false)

	var holder := Node3D.new()
	add_child(holder)
	var w := WorldMirror.new()
	holder.add_child(w)
	w.protos.add_entities([
		[91, "fast-inserter", "inserter", -0.4, -0.4, 0.4, 0.4, 0, 0, 0, 1, 1],
		[92, "chemical-plant", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 0, 0, 0, 3, 3],
		[93, "pump", "pump", -0.5, -1.0, 0.5, 1.0, 0, 0, 0, 1, 2],
	])
	w.chunks[Vector2i(0, 0)] = ChunkView.new()
	w.chunks[Vector2i(1, 0)] = ChunkView.new()
	w.chunks[Vector2i(20, 20)] = ChunkView.new()
	w._add([501, 91, 5 * 256 + 128, 5 * 256 + 128, 0])
	w._add([502, 92, 10 * 256 + 128, 10 * 256 + 128, 0, {"fa": 3, "fc": [[1, 2, 8, "i", "water"], [2, -2, 0, "o", "steam"]]}])
	w._add([503, 93, 40 * 256 + 128, 8 * 256 + 128, 4])  # chunk (1, 0)
	w._add([504, 91, (20 * 32 + 5) * 256, (20 * 32 + 5) * 256, 0])  # off-screen chunk (20, 20)

	var stub_gs := GDScript.new()
	stub_gs.source_code = "extends Node\nvar eprops := {}\n"
	stub_gs.reload()
	var fake_model: Node = stub_gs.new()
	fake_model.eprops = {
		91: {"x": {"ip": [0, -1], "id": [0, 1.2]}},
		92: {"x": {"fb": [[-1, -1, 0, "i"], [1, 1, 8, "o"]]}},
		93: {"x": {"fb": [[0, -0.5, 0, "o"], [0, 0.5, 8, "i"]]}},
	}
	holder.add_child(fake_model)

	var cam := Camera3D.new()
	holder.add_child(cam)
	cam.position = Vector3(20, 35, 30)
	cam.look_at(Vector3(20, 0, 8))

	var layer_ref := AltArrows.new()
	layer_ref.world = w
	layer_ref.model = fake_model
	layer_ref.alt_mode = true
	holder.add_child(layer_ref)
	AltArrows.opt_enabled = false
	layer_ref.refresh(cam)
	var snap_ref := _snapshot_arrows(layer_ref)

	var layer_opt := AltArrows.new()
	layer_opt.world = w
	layer_opt.model = fake_model
	layer_opt.alt_mode = true
	holder.add_child(layer_opt)
	AltArrows.opt_enabled = true
	layer_opt.refresh(cam)
	var snap_opt := _snapshot_arrows(layer_opt)

	check(snap_opt["drawn"] == snap_ref["drawn"] and snap_opt["icons_drawn"] == snap_ref["icons_drawn"]
		and snap_opt["layer_counts"] == snap_ref["layer_counts"] and snap_opt["layer_bufs"] == snap_ref["layer_bufs"]
		and snap_opt["fluid_counts"] == snap_ref["fluid_counts"] and snap_opt["fluid_bufs"] == snap_ref["fluid_bufs"],
		"alt_arrows parity: optimized output matches --alt-arrows-opt=off (%s vs %s)"
		% [snap_opt["drawn"], snap_ref["drawn"]])

	# Repeated idle refreshes perform 0 MultiMesh uploads.
	var uploads_before := layer_opt.layer_uploads
	for _f in 10:
		layer_opt.refresh(cam)
	check(layer_opt.layer_uploads == uploads_before,
		"alt_arrows idle: repeated refresh performs 0 MultiMesh uploads (%d -> %d)"
		% [uploads_before, layer_opt.layer_uploads])

	# Dirtying a chunk with ONLY a pump (FLUID layer 1) only uploads layer 1 (not INDICATION / FLUID_BOTH / fluid icons).
	w._add([505, 93, 42 * 256 + 128, 8 * 256 + 128, 0])
	w.entities_changed.emit(Vector2i(1, 0))
	layer_opt.refresh(cam)
	var uploads_after_pump := layer_opt.layer_uploads
	check(uploads_after_pump - uploads_before == 1 and layer_opt.drawn == snap_ref["drawn"] + 1,
		"alt_arrows selective: dirtying pump-only chunk uploads 1 layer (delta=%d, drawn=%d)"
		% [uploads_after_pump - uploads_before, layer_opt.drawn])

	AltArrows.opt_enabled = prev_opt
	SettingsFile.set_value("interface", "alt_inserter_arrows", prev_ins, false)
	SettingsFile.set_value("interface", "alt_pump_arrows", prev_pump, false)
	SettingsFile.set_value("interface", "alt_machine_arrows", prev_mach, false)
	remove_child(holder)
	holder.free()


func _test_quality_marks_opt() -> void:
	var prev_cache := QualityMarks.static_cache
	var prev_opt := QualityMarks.opt_enabled
	QualityMarks.static_cache = true

	var holder := Node3D.new()
	add_child(holder)
	var w := WorldMirror.new()
	holder.add_child(w)
	w.chunks[Vector2i(0, 0)] = ChunkView.new()
	w._add([701, 8, 5 * 256, 5 * 256, 0, {"q": "rare"}])

	var model_gs := GDScript.new()
	model_gs.source_code = "extends Node\nvar belt_quality := {}\n"
	model_gs.reload()
	var fake_model: Node = model_gs.new()
	holder.add_child(fake_model)

	var bi := MockBeltItems.new()
	holder.add_child(bi)

	var qm := QualityMarks.new()
	qm.world = w
	qm.model = fake_model
	qm.belt_items = bi
	qm.alt_mode = true
	holder.add_child(qm)

	# 1. Empty belt_quality skips belt-item polling/uploads completely.
	QualityMarks.opt_enabled = true
	for _f in 10:
		qm._process(1.0 / 60.0)
	check(qm.item_uploads == 0 and qm.entity_uploads == 1,
		"quality_marks empty belt_quality skips item uploads (item_uploads=%d, entity_uploads=%d)"
		% [qm.item_uploads, qm.entity_uploads])

	# 2. Populate belt_quality: paused (drawn_tick constant) uploads once then 0 times.
	for i in 20:
		var uid := 8000 + i
		fake_model.belt_quality[uid] = "rare" if i % 2 == 0 else "epic"
		bi.positions[uid] = Vector3(float(i), 0.25, 4.0)
	qm._process(0.0)
	var after_first := qm.item_uploads
	for _f in 10:
		qm._process(1.0 / 60.0)
	check(after_first == 1 and qm.item_uploads == 1,
		"quality_marks paused tick skips belt-item re-uploads (uploads=%d)" % qm.item_uploads)

	# 3. Advancing tick at 120 Hz throttles polling to <= 30 Hz.
	var uploads_start := qm.item_uploads
	for _f in 12:
		bi.tick += 0.5
		for uid in fake_model.belt_quality:
			bi.positions[uid] = (bi.positions[uid] as Vector3) + Vector3(0.05, 0.0, 0.0)
		qm._process(1.0 / 120.0)
	var throttled_uploads := qm.item_uploads - uploads_start
	check(throttled_uploads >= 2 and throttled_uploads <= 4,
		"quality_marks 120 Hz advance throttled to ~30 Hz (12 frames -> %d uploads)" % throttled_uploads)

	# 4. Exact buffer parity vs --quality-marks-opt=off after polling at latest tick.
	qm._process(0.05)  # flush latest tick
	var opt_rare := (qm._item_layers["rare"] as MultiMeshInstance3D).multimesh
	var opt_rare_cnt := opt_rare.visible_instance_count
	var opt_rare_buf := opt_rare.buffer.slice(0, opt_rare_cnt * 12)

	var qm_ref := QualityMarks.new()
	qm_ref.world = w
	qm_ref.model = fake_model
	qm_ref.belt_items = bi
	qm_ref.alt_mode = true
	holder.add_child(qm_ref)
	QualityMarks.opt_enabled = false
	qm_ref._process(0.0)
	var ref_rare := (qm_ref._item_layers["rare"] as MultiMeshInstance3D).multimesh
	var ref_rare_cnt := ref_rare.visible_instance_count
	var ref_rare_buf := ref_rare.buffer.slice(0, ref_rare_cnt * 12)

	check(opt_rare_cnt == 10 and opt_rare_cnt == ref_rare_cnt and opt_rare_buf == ref_rare_buf,
		"quality_marks parity: optimized MultiMesh matches --quality-marks-opt=off (%d items)" % opt_rare_cnt)

	QualityMarks.static_cache = prev_cache
	QualityMarks.opt_enabled = prev_opt
	remove_child(holder)
	holder.free()
