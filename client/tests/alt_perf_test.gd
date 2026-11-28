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
	# These two compare paths within a frame, so every icon read at once (--alt-icons-later=off); the
	# incremental tests below have it on (_inc_settle waits for the workers' reads).
	var prev_later := AltOverlay.icons_later
	AltOverlay.icons_later = false
	await _test_alt_overlay_cache_and_idle()
	await _test_alt_overlay_flat_batching()
	AltOverlay.icons_later = prev_later
	await _test_alt_overlay_incremental()
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
		and _whole_keys_at(overlay, ModGraphics.generation, 0) and not overlay._moving_machines.is_empty() \
		and overlay._moving_machines[0].gfx_gen == ModGraphics.generation
	ModelPacks.icons_version += 1
	overlay._process(1.0 / 60.0)
	var packs_redraws := overlay.redraws_queued
	overlay.collect()
	var packs_keys_ok: bool = alt_cc_rebuilt.icons_ver == ModelPacks.icons_version \
		and _whole_keys_at(overlay, ModelPacks.icons_version, 1) \
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


## --alt-incremental: the per-chunk caches against a whole-map rebuild after every event of a seeded
## sequence (both the card's path and the CPU path), builds only for the chunks that changed, and the cost of
## one chunk's change on a big base.
func _test_alt_overlay_incremental() -> void:
	var prev_inc := AltOverlay.incremental
	var prev_mode := AltOverlay.icons_mode
	var prev_cache := AltOverlay.use_cache
	var prev_alt_contents: int = Bridge.alt_contents
	var win_before := get_window().size
	get_window().size = Vector2i(1280, 720)
	AltOverlay._read_args()
	AltOverlay.use_cache = true
	var prev_native := AltOverlay.native
	for mode in ["gpu", "cpu"]:
		AltOverlay.native = false
		await _inc_parity_run(mode)
	# --alt-native: the overlay under test sorts and packs in C++, the reference in GDScript.
	if _native_ready():
		inc_native = true
		await _inc_parity_run("gpu")
		inc_native = false
	else:
		print("alt_perf_test: AltIconsNative not loaded, --alt-native parity skipped")
	AltOverlay.native = prev_native
	await _inc_on_change_only()
	await _inc_no_blink()
	await _inc_relift_counts()
	await _inc_quiet_counts()
	await _inc_icons_later()
	AltOverlay.incremental = prev_inc
	AltOverlay.icons_mode = prev_mode
	AltOverlay.use_cache = prev_cache
	Bridge.set_alt_contents(false)
	if prev_alt_contents > 0:
		Bridge.set_alt_contents(true)
	GroundHeight.clear()
	get_window().size = win_before


const INC_RECIPES := ["iron-gear-wheel", "electronic-circuit", "copper-cable", "pipe"]
const INC_ITEMS := ["iron-plate", "copper-plate", "coal", "stone", "steel-plate"]
const INC_FLUIDS := ["water", "crude-oil", "steam"]


class IncScene:
	var holder: Node3D
	var w
	var fp
	var trains
	var rig: Node3D
	var player: Node3D
	var model: Node3D
	var inc  # the overlay under test (--alt-incremental, and the switches under test on)
	var ref  # the reference: every cache built again from nothing (--alt-incremental=off)
	var off  # --alt-incremental with the switches under test off (--alt-relift=off): its buffer to the byte


func _inc_scene(grid: int) -> IncScene:
	var sc := IncScene.new()
	sc.holder = Node3D.new()
	add_child(sc.holder)
	sc.w = WorldMirror.new()
	sc.holder.add_child(sc.w)
	sc.w.protos.add_entities([
		[1, "assembling-machine-2", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3],
		[2, "fast-inserter", "inserter", -0.4, -0.4, 0.4, 0.4, 80, 80, 80, 1, 1],
		[3, "wooden-chest", "container", -0.35, -0.35, 0.35, 0.35, 100, 100, 100, 1, 1],
		[4, "beacon", "beacon", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3],
		[5, "pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 80, 80, 80, 1, 1],
		[6, "storage-tank", "storage-tank", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3],
		[7, "cargo-wagon", "cargo-wagon", -1.0, -3.0, 1.0, 3.0, 150, 150, 150, 2, 6],
	])
	for cy in grid:
		for cx in grid:
			sc.w.chunks[Vector2i(cx, cy)] = ChunkView.new()
	sc.fp = FluidsPower.new()
	sc.fp.name = "FluidsPower"
	sc.fp.world = sc.w
	sc.holder.add_child(sc.fp)
	sc.fp.set_process(false)
	sc.trains = MoverLayer.new()
	sc.trains.protos = sc.w.protos
	sc.holder.add_child(sc.trains)
	sc.trains.handle({"t": "mv", "k": 1, "l": [[9001, 7, 20 * 256, 20 * 256, 0]]})
	sc.trains._process(1.0 / 60.0)
	var stub_gs := GDScript.new()
	stub_gs.source_code = "extends Node3D\nvar world\nvar rig\nvar camera: Camera3D\nvar first_person := false\nvar hovered\nvar movers\nvar remote_fog\nvar eprops := {}\n"
	stub_gs.reload()
	sc.rig = stub_gs.new()
	sc.rig.camera = Camera3D.new()
	sc.rig.add_child(sc.rig.camera)
	sc.holder.add_child(sc.rig)
	sc.rig.camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	sc.rig.camera.fov = 50.0
	sc.rig.camera.far = 4000.0
	var mid := grid * 16.0
	sc.rig.camera.position = Vector3(mid, grid * 32.0 * 0.9, mid + grid * 32.0 * 0.75)
	sc.rig.camera.look_at(Vector3(mid, 0, mid))
	sc.player = stub_gs.new()
	sc.player.world = sc.w
	sc.player.rig = sc.rig
	sc.player.movers = sc.trains
	sc.holder.add_child(sc.player)
	sc.model = stub_gs.new()
	sc.model.eprops = {
		1: {"x": {"ids": [0, -0.2, 1.0], "isq": [["m", 0, 0.7, 0.5, 4, 2, 1.1, -0.1]]}},
		4: {"x": {"isq": [["m", 0, 0, 0.5, 2, 2, 1.1, -0.3]]}},
		7: {"x": {"isq": [["c", 0, 0, 0.5, 4, 1, 1.1, -0.1]]}},
	}
	sc.holder.add_child(sc.model)
	for i in 3:
		var ov := AltOverlay.new()
		ov.model = sc.model
		ov.player = sc.player
		ov.on = true
		sc.holder.add_child(ov)
		ov.set_process(false)
		if i == 0:
			sc.inc = ov
		elif i == 1:
			sc.ref = ov
		else:
			sc.off = ov
	return sc


func _inc_free(sc: IncScene) -> void:
	for ov in [sc.inc, sc.ref, sc.off]:
		ov.on = false
		ov._process(0.0)
	remove_child(sc.holder)
	sc.holder.free()


## Brings `ov` up to date: the card's path until nothing is left to look at, the CPU path's collect() until no
## chunk in view is left for the next frame.
func _inc_settle(ov, mode: String) -> void:
	if mode == "gpu":
		for _i in 400:
			_inc_wait_icons(ov)
			ov._process(1.0 / 60.0)
			if ov._gpu_check.is_empty() and ov._icon_wait.is_empty() \
					and not (AltOverlay.incremental and ov._inc_has_news(ov.player.world.get_parent().get_node("FluidsPower"))):
				break
	else:
		for _i in 50:
			_inc_wait_icons(ov)
			ov.collect()
			if not ov._inc_view_left and ov._icon_wait.is_empty():
				break


## --alt-icons-later: the icons `ov` waits for read on their workers and taken (up to 2 s).
func _inc_wait_icons(ov) -> void:
	var t0 := Time.get_ticks_msec()
	while not ov._icon_wait.is_empty() and Time.get_ticks_msec() - t0 < 2000:
		ov._poll_icons_later()
		if not ov._icon_wait.is_empty():
			OS.delay_msec(1)


## What `ov` draws, independent of the order icons at one depth were found in (the whole-map caches find them
## in the bridge's order, the per-chunk ones in the chunk's): the card's instances per chunk with their pictures
## as textures, or the CPU path's paint list; plus the movers' units.
func _inc_snapshot(ov, mode: String) -> Array:
	var out: Array = []
	if mode == "gpu":
		var tex_of := {}
		for t: Texture2D in ov._gpu_layer_of:
			tex_of[int(ov._gpu_layer_of[t])] = t.get_instance_id()
		var chunks: Array = []
		for c: Vector2i in ov._gpu_chunks:
			var d: PackedFloat32Array = ov._gpu_chunk_data(c)
			var rows := PackedStringArray()
			for i in range(0, d.size(), AltOverlay.GPU_FLOATS):
				var pic := int(d[i + 11])
				var row := d.slice(i, i + AltOverlay.GPU_FLOATS)
				row[11] = 0.0
				rows.append("%s|%d|%d" % [str(row), int(tex_of.get(pic % 4096, -1)), int(tex_of.get(pic / 4096 - 1, -2))])
			rows.sort()
			chunks.append("%d,%d:%s" % [c.x, c.y, "/".join(rows)])
		chunks.sort()
		out.append(chunks)
		out.append(ov.gpu_instances)
	else:
		var list: Array = []
		for e: Array in ov.paint_list():  # each overlay has its own shadow texture
			list.append([e[0], null if str(e[0]) == "s" else e[1], e[2], e[3]])
		var sig := _paint_signature(list)
		sig.sort()
		out.append(sig)
		out.append(ov.drawn)
	var units: Array = []
	for ms in ov._moving_machines:
		units.append(ms.unit)
	units.sort()
	out.append(units)
	return out


var inc_native := false  # the overlay under test with --alt-native (the reference without)
## The switches perf wave 4 adds, as the overlay under test has them (the `off` overlay has them off).
var inc_relift := true


## Sets perf wave 4's switches on (the overlay under test) or off (the `off` overlay).
func _w4_switches(v: bool) -> void:
	AltOverlay.relift = v and inc_relift
	AltOverlay.quiet_builds = v
	AltOverlay.icons_later = v


## What `ov` draws to the bit, in its own order: the card's joined buffer, each instance's picture and mark as
## their textures (each overlay numbers its own layers), or the CPU path's paint list with every float's bytes.
func _exact_sig(ov, mode: String) -> PackedStringArray:
	var out := PackedStringArray()
	if mode == "gpu":
		var tex_of := {}
		for t: Texture2D in ov._gpu_layer_of:
			tex_of[int(ov._gpu_layer_of[t])] = t.get_instance_id()
		var d: PackedFloat32Array = ov._gpu_join()
		for i in range(0, d.size(), AltOverlay.GPU_FLOATS):
			var pic := int(d[i + 11])
			var row := d.slice(i, i + AltOverlay.GPU_FLOATS)
			row[11] = 0.0
			out.append("%s|%d|%d" % [row.to_byte_array().hex_encode(), int(tex_of.get(pic % 4096, -1)), int(tex_of.get(pic / 4096 - 1, -2))])
	else:
		for e: Array in ov.paint_list():
			var tex: Texture2D = null if str(e[0]) == "s" else e[1]
			out.append("%s:%d:%s" % [str(e[0]), tex.get_instance_id() if tex != null else 0,
				var_to_bytes([e[2], float(e[3])]).hex_encode()])
	return out


static func _native_ready() -> bool:
	return preload("res://scripts/native_library.gd").ensure() and ClassDB.class_exists(&"AltIconsNative")


func _inc_compare(sc: IncScene, mode: String) -> Array:
	AltOverlay.incremental = true
	AltOverlay.native = inc_native
	_w4_switches(true)
	_inc_settle(sc.inc, mode)
	var a := _inc_snapshot(sc.inc, mode)
	var a_exact := _exact_sig(sc.inc, mode)
	if inc_native:
		check(sc.inc._gpu_nat_on, "alt_overlay incremental: the overlay under test uses AltIconsNative")
	_w4_switches(false)
	_inc_settle(sc.off, mode)
	var c_exact := _exact_sig(sc.off, mode)
	_w4_switches(true)
	if a_exact != c_exact:
		a.append("differs to the byte from the switches off (%d vs %d rows)" % [a_exact.size(), c_exact.size()])
	AltOverlay.native = false
	AltOverlay.incremental = false
	sc.ref._clear_caches()
	sc.ref._gpu_global_key = []
	_inc_settle(sc.ref, mode)
	var b := _inc_snapshot(sc.ref, mode)
	AltOverlay.incremental = true
	return [a, b]


func _inc_parity_run(mode: String) -> void:
	AltOverlay.icons_mode = mode
	AltOverlay.incremental = true
	var grid := 4
	var sc := _inc_scene(grid)
	var w = sc.w
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261126
	var unit := 100
	var adds := {}  # unit -> [chunk, add array, kind]
	var ac := {}  # unit -> ac row (the chests' current contents)
	var am := {}  # unit -> am row
	var fluids := {}
	var unloaded := {}  # chunk -> [add arrays]
	var used_tiles := {}
	var last_hill: Variant = null  # [image, origin, step] of the last field set
	Bridge.set_alt_contents(true)
	var send := func(msg: Dictionary) -> void:
		if msg.has("g"):
			msg["g"] = Bridge.alt_contents
		w.handle(msg)
		Bridge.message_received.emit(msg)
	var free_tile := func(c: Vector2i) -> Vector2i:
		for _t in 40:
			var tile := Vector2i(c.x * 32 + 2 + rng.randi_range(0, 7) * 4, c.y * 32 + 2 + rng.randi_range(0, 7) * 4)
			if not used_tiles.has(tile):
				used_tiles[tile] = true
				return tile
		return Vector2i(-99999, -99999)
	var loaded := func() -> Array:
		return w.chunks.keys()
	# A start: a few of each kind in every chunk.
	for c: Vector2i in w.chunks.keys():
		for k in 7:
			var tile: Vector2i = free_tile.call(c)
			unit += 1
			var proto: int = [1, 1, 3, 3, 5, 2, 6][k]
			var extra := {}
			if proto == 1:
				extra = {"ai": ["recipe", INC_RECIPES[rng.randi_range(0, 3)]]}
			elif proto == 2:
				extra = {"ai": ["item", INC_ITEMS[rng.randi_range(0, 4)]]}
			var arr := [unit, proto, tile.x * 256 + 128, tile.y * 256 + 128, 0, extra]
			w._add(arr)
			adds[unit] = [c, arr, proto]
			if proto == 1:
				am[unit] = [unit, ["speed-module-3", ["productivity-module-3", "rare"]], []]
			elif proto == 3:
				ac[unit] = [unit, INC_ITEMS[rng.randi_range(0, 4)], [INC_ITEMS[rng.randi_range(0, 4)]]]
			elif proto == 5 or proto == 6:
				fluids[unit] = [{"fluid": INC_FLUIDS[rng.randi_range(0, 2)], "amount": 50, "capacity": 100}]
		w.entities_changed.emit(c)
	var beacon_tile: Vector2i = free_tile.call(Vector2i(1, 1))
	unit += 1
	var beacon_arr := [unit, 4, beacon_tile.x * 256 + 128, beacon_tile.y * 256 + 128, 0, {}]
	w._add(beacon_arr)
	adds[unit] = [Vector2i(1, 1), beacon_arr, 4]
	am[unit] = [unit, ["speed-module-3", "speed-module-3"], []]
	am[9001] = [9001, 0, ["iron-plate", "copper-plate"]]
	sc.fp.fluids = fluids.duplicate()
	send.call({"t": "ac", "g": 0, "l": ac.values()})
	send.call({"t": "am", "g": 0, "l": am.values()})
	send.call({"t": "fl"})
	var first: Array = _inc_compare(sc, mode)
	var ok := 0
	var bad: Array = []
	check(first[0] == first[1] and int(first[0][1]) > 0,
		"alt_overlay incremental (%s%s): first sync matches a whole-map build (%d vs %d icons)" % [mode, " native" if inc_native else "", int(first[0][1]), int(first[1][1])])
	var kinds_seen := {}
	for step in 200:
		var ev := rng.randi_range(0, 17)
		var units: Array = adds.keys()
		var pick: int = units[rng.randi_range(0, units.size() - 1)] if not units.is_empty() else -1
		match ev:
			0, 1, 2:  # a machine, chest or pipe built
				var chunks: Array = loaded.call()
				var c: Vector2i = chunks[rng.randi_range(0, chunks.size() - 1)]
				var tile: Vector2i = free_tile.call(c)
				if tile.x < -9999:
					continue
				unit += 1
				var proto: int = [1, 3, 5][ev]
				var extra := {"ai": ["recipe", INC_RECIPES[rng.randi_range(0, 3)]]} if proto == 1 else {}
				var arr := [unit, proto, tile.x * 256 + 128, tile.y * 256 + 128, 0, extra]
				w._add(arr)
				adds[unit] = [c, arr, proto]
				w.entities_changed.emit(c)
				if proto == 1 and rng.randf() < 0.7:
					am[unit] = [unit, ["speed-module-3"], []]
					send.call({"t": "am", "g": 0, "l": [am[unit]]})
				elif proto == 3:
					ac[unit] = [unit, INC_ITEMS[rng.randi_range(0, 4)]]
					send.call({"t": "ac", "g": 0, "l": [ac[unit]]})
				elif proto == 5:
					fluids[unit] = [{"fluid": INC_FLUIDS[rng.randi_range(0, 2)], "amount": 10, "capacity": 100}]
					sc.fp.fluids = fluids.duplicate()
					send.call({"t": "fl"})
			3:  # one removed
				if pick < 0 or not w.entities.has(pick):
					continue
				var c: Vector2i = adds[pick][0]
				w._remove(pick)
				adds.erase(pick)
				w.entities_changed.emit(c)
				if rng.randf() < 0.5:  # the bridge tells (or not yet)
					if ac.erase(pick):
						send.call({"t": "ac", "g": 0, "l": [[pick]]})
					if am.erase(pick):
						send.call({"t": "am", "g": 0, "l": [[pick]]})
			4:  # a chest's contents
				var chests: Array = ac.keys()
				if chests.is_empty():
					continue
				var u: int = chests[rng.randi_range(0, chests.size() - 1)]
				if rng.randf() < 0.2:
					ac.erase(u)
					send.call({"t": "ac", "g": 0, "l": [[u]]})
				else:
					ac[u] = [u, INC_ITEMS[rng.randi_range(0, 4)], [INC_ITEMS[rng.randi_range(0, 4)], INC_ITEMS[rng.randi_range(0, 4)]]]
					send.call({"t": "ac", "g": 0, "l": [ac[u]]})
			5:  # a machine's modules (or the wagon's cargo)
				var machines: Array = am.keys()
				if machines.is_empty():
					continue
				var u: int = machines[rng.randi_range(0, machines.size() - 1)]
				if rng.randf() < 0.2 and u != 9001:
					am.erase(u)
					send.call({"t": "am", "g": 0, "l": [[u]]})
				else:
					var list: Array = []
					for _m in rng.randi_range(1, 4):
						list.append(["speed-module-3", "productivity-module-3", ["efficiency-module", "rare"]][rng.randi_range(0, 2)])
					am[u] = [u, 0, list] if u == 9001 else [u, list, []]
					send.call({"t": "am", "g": 0, "l": [am[u]]})
			6:  # `aiu`: a recipe changed, or a chest given (or losing) a filter icon of its own
				if pick < 0 or not w.entities.has(pick):
					continue
				var proto: int = adds[pick][2]
				if proto == 1:
					send.call({"t": "aiu", "l": [[pick, "recipe", INC_RECIPES[rng.randi_range(0, 3)]]]})
				elif proto == 3:
					if rng.randf() < 0.5:
						send.call({"t": "aiu", "l": [[pick, "item", "coal"]]})
					else:
						send.call({"t": "aiu", "l": [[pick, ""]]})
				else:
					continue
			7:  # `fl`: one changed, one emptied, one new, one gone
				var next := fluids.duplicate()
				var fu: Array = next.keys()
				if fu.size() >= 3:
					next[fu[0]] = [{"fluid": INC_FLUIDS[rng.randi_range(0, 2)], "amount": 40, "capacity": 100}]
					next[fu[1]] = [{"fluid": "water", "amount": 0, "capacity": 100}]
					next.erase(fu[2])
				for u in adds:
					if (adds[u][2] == 5 or adds[u][2] == 6) and not next.has(u):
						next[u] = [{"fluid": "steam", "amount": 5, "capacity": 100}]
						break
				fluids = next
				sc.fp.fluids = fluids.duplicate()
				send.call({"t": "fl"})
			8:  # `fl` with the same fluids
				sc.fp.fluids = fluids.duplicate()
				send.call({"t": "fl"})
			9:  # a chunk unloaded
				var chunks: Array = loaded.call()
				if chunks.size() <= 4:
					continue
				var c: Vector2i = chunks[rng.randi_range(0, chunks.size() - 1)]
				var cv = w.chunks[c]
				var saved: Array = []
				for r in cv.entities.values():
					w.entities.erase(r.key)
					if adds.has(r.unit):
						saved.append(adds[r.unit])
						adds.erase(r.unit)
				w.chunks.erase(c)
				unloaded[c] = saved
				w.entities_changed.emit(c)
			10:  # a chunk loaded again
				if unloaded.is_empty():
					continue
				var c: Vector2i = unloaded.keys()[rng.randi_range(0, unloaded.size() - 1)]
				w.chunks[c] = ChunkView.new()
				for e: Array in unloaded[c]:
					w._add(e[1])
					adds[int(e[1][0])] = e
				unloaded.erase(c)
				w.entities_changed.emit(c)
			11:  # Alt-mode off and on (a new g: the bridge sends everything again)
				Bridge.set_alt_contents(false)
				Bridge.set_alt_contents(true)
				send.call({"t": "ac", "g": 0, "l": ac.values()})
				send.call({"t": "am", "g": 0, "l": am.values()})
			12:  # the ground's heights (--alt-relift: every format, a fade and its steps, the same field again)
				var hk := rng.randi_range(0, 7)
				if hk <= 3 or (hk == 5 and last_hill == null):
					var fmt: int = [Image.FORMAT_RF, Image.FORMAT_RGF, Image.FORMAT_RGBF, Image.FORMAT_RF][hk % 4]
					var hill := Image.create(rng.randi_range(9, 40), rng.randi_range(9, 40), false, fmt)
					for hy in hill.get_height():
						for hx in hill.get_width():
							hill.set_pixel(hx, hy, Color(rng.randf_range(-1.0, 4.0), rng.randf_range(-1.0, 3.0), rng.randf(), 1.0))
					if hk == 3:
						hill.set_meta(&"fade_in", 3.0)  # faded in from the field before (mix 0)
					last_hill = [hill, Vector2(rng.randi_range(-20, 90) + 0.25, rng.randi_range(-20, 90)), rng.randf_range(0.5, 3.0)]
					if rng.randf() < 0.3:  # set while chunks wait to be built
						var dc: Array = loaded.call()
						w.entities_changed.emit(dc[rng.randi_range(0, dc.size() - 1)])
					GroundHeight.set_field(last_hill[0], last_hill[1], last_hill[2])
				elif hk == 4 and GroundHeight.fading():
					# The fade a step on: its mix moved, version() with it.
					GroundHeight._fade_from -= int(GroundHeight._fade_usec * rng.randf_range(0.25, 0.4))
					GroundHeight._fade_on()
				elif hk == 5:
					GroundHeight.set_field(last_hill[0], last_hill[1], last_hill[2])  # the same field again
				else:
					GroundHeight.clear()
			13:  # the wagon moved
				sc.trains.handle({"t": "mv", "k": 10 + step, "l": [[9001, 7, rng.randi_range(5, 100) * 256, rng.randi_range(5, 100) * 256, 0]]})
				sc.trains._process(0.1)
			14:  # world.gd built a chunk again with no record changed (--alt-quiet-builds: nothing to do)
				var chunks: Array = loaded.call()
				for _q in rng.randi_range(1, 3):
					w.entities_changed.emit(chunks[rng.randi_range(0, chunks.size() - 1)])
			15:  # a record sent again in place (another recipe), its chunk's signal after
				if pick < 0 or not w.entities.has(pick) or int(adds[pick][2]) != 1:
					continue
				var arr: Array = (adds[pick][1] as Array).duplicate(true)
				arr[5] = {"ai": ["recipe", INC_RECIPES[rng.randi_range(0, 3)]]}
				w._add(arr)
				adds[pick][1] = arr
				w.entities_changed.emit(adds[pick][0])
			16:  # one removed and another built on its tile in one frame, one signal
				if pick < 0 or not w.entities.has(pick):
					continue
				var c: Vector2i = adds[pick][0]
				var old: Array = adds[pick][1]
				var proto: int = adds[pick][2]
				w._remove(pick)
				adds.erase(pick)
				unit += 1
				var arr := [unit, proto, old[2], old[3], 0, ({"ai": ["recipe", INC_RECIPES[rng.randi_range(0, 3)]]} if proto == 1 else {})]
				w._add(arr)
				adds[unit] = [c, arr, proto]
				if proto == 3:
					ac[unit] = [unit, INC_ITEMS[rng.randi_range(0, 4)]]
					send.call({"t": "ac", "g": 0, "l": [ac[unit]]})
				w.entities_changed.emit(c)
			17:  # the chunk's tiles only
				var chunks: Array = loaded.call()
				var c: Vector2i = chunks[rng.randi_range(0, chunks.size() - 1)]
				var ids := PackedInt32Array()
				ids.resize(ChunkView.SIZE * ChunkView.SIZE)
				ids.fill(rng.randi_range(1, 9))
				w.chunks[c].set_tiles(ids)
				w.entities_changed.emit(c)
		kinds_seen[ev] = true
		var res: Array = _inc_compare(sc, mode)
		if res[0] == res[1]:
			ok += 1
		elif bad.size() < 3:
			bad.append("step %d event %d: %d vs %d icons" % [step, ev, int(res[0][1]), int(res[1][1])])
	check(bad.is_empty() and kinds_seen.size() == 18,
		"alt_overlay incremental (%s%s): %d of 200 seeded events match a whole-map build (event kinds %d of 18) %s"
		% [mode, " native" if inc_native else "", ok, kinds_seen.size(), str(bad)])
	GroundHeight.clear()
	_inc_free(sc)


## The 144-chunk base of the incremental tests (sc from _inc_scene(12)): machines, chests, inserters and pipes in
## every chunk, their `ac`, `am` and `fl` sent, the camera over its middle. Returns the fluids.
func _inc_populate(sc: IncScene) -> Dictionary:
	var w = sc.w
	Bridge.set_alt_contents(true)
	var g: int = Bridge.alt_contents
	var unit := 1000
	var ac_rows: Array = []
	var am_rows: Array = []
	var fluids := {}
	for c: Vector2i in w.chunks.keys():
		var ox := c.x * 32
		var oy := c.y * 32
		for i in 20:
			unit += 1
			w._add([unit, 1, (ox + 2 + (i % 8) * 4) * 256 + 128, (oy + 2 + (i / 8) * 4) * 256 + 128, 0,
				{"ai": ["recipe", INC_RECIPES[i % 4]]}])
			am_rows.append([unit, ["speed-module-3", "productivity-module-3"], []])
		for i in 10:
			unit += 1
			w._add([unit, 3, (ox + i) * 256 + 128, (oy + 28) * 256 + 128, 0])
			ac_rows.append([unit, INC_ITEMS[i % 5], [INC_ITEMS[(i + 1) % 5]]])
		for i in 5:
			unit += 1
			w._add([unit, 2, (ox + i) * 256 + 128, (oy + 30) * 256 + 128, 0, {"ai": ["item", INC_ITEMS[i % 5]]}])
		for i in 60:
			unit += 1
			w._add([unit, 5, (ox + i % 32) * 256 + 128, (oy + 24 + i / 32) * 256 + 128, 0])
			fluids[unit] = [{"fluid": INC_FLUIDS[(c.x + c.y + 64) % 3], "amount": 50, "capacity": 100}]
	sc.fp.fluids = fluids
	for msg in [{"t": "ac", "g": g, "l": ac_rows}, {"t": "am", "g": g, "l": am_rows}, {"t": "fl"}]:
		w.handle(msg)
		Bridge.message_received.emit(msg)
	sc.rig.camera.position = Vector3(192, 110, 262)
	sc.rig.camera.look_at(Vector3(192, 0, 192))
	return fluids


## The CPU path (first person, remote fog, Compatibility) on the 144-chunk base: a change of an "all" key
## (the ground's heights, the icons' pictures) keeps the per-chunk stores and builds the chunks again a few a
## frame, so the first frame after it still draws every icon (before perf-fix-r1: about a third, for 20+ frames).
func _inc_no_blink() -> void:
	AltOverlay.icons_mode = "cpu"
	AltOverlay.incremental = true
	var sc := _inc_scene(12)
	var ov = sc.inc
	_inc_populate(sc)
	await get_tree().process_frame
	var hill := Image.create(16, 16, false, Image.FORMAT_RF)
	hill.fill(Color(1.5, 0, 0))
	GroundHeight.set_field(hill, Vector2(500, 500), 2.0)  # far off: no icon moves
	_inc_settle(ov, "cpu")
	var settled: int = ov.drawn
	var report := PackedStringArray()
	var worst := settled
	for what in ["heights", "pictures"]:
		if what == "heights":
			GroundHeight.clear()
		else:
			AltOverlay.use_spec = not AltOverlay.use_spec
		ov.collect()
		var first: int = ov.drawn
		var frames := 1
		while ov._inc_view_left and frames < 60:
			ov.collect()
			frames += 1
		worst = mini(worst, first)
		report.append("%s: %d of %d icons in the first frame, %d frames to rebuild" % [what, first, settled, frames])
		if what == "pictures":
			AltOverlay.use_spec = not AltOverlay.use_spec
			_inc_settle(ov, "cpu")
	print("alt_overlay incremental (cpu): ", ", ".join(report))
	check(settled > 0 and worst == settled,
		"alt_overlay incremental (cpu): an \"all\" key change keeps every icon drawn while chunks rebuild (%s)" % ", ".join(report))
	GroundHeight.clear()
	_inc_free(sc)


func _inc_on_change_only() -> void:
	AltOverlay.icons_mode = "gpu"
	AltOverlay.incremental = true
	var sc := _inc_scene(12)
	var w = sc.w
	var ov = sc.inc
	var fluids := _inc_populate(sc)
	await get_tree().process_frame
	_inc_settle(ov, "gpu")
	var chunks: Array = w.chunks.keys()
	var in_view: Vector2i = Vector2i(6, 6)
	# One chunk built again: its three kinds, not every chunk's.
	var b0: int = ov.chunk_builds
	w.chunks[in_view].content_rev += 1  # a record changed (--alt-quiet-builds leaves a signal with none alone)
	w.entities_changed.emit(in_view)
	var t0 := Time.get_ticks_usec()
	ov._process(1.0 / 60.0)
	var one_ms := (Time.get_ticks_usec() - t0) / 1000.0
	_inc_settle(ov, "gpu")
	var one_builds: int = ov.chunk_builds - b0
	# `fl` with the same fluids: nothing built or sent.
	var b1: int = ov.chunk_builds
	var u1: int = ov.gpu_uploads
	sc.fp.fluids = fluids.duplicate()
	var fl_msg := {"t": "fl"}
	Bridge.message_received.emit(fl_msg)
	_inc_settle(ov, "gpu")
	var fl_builds: int = ov.chunk_builds - b1
	var fl_uploads: int = ov.gpu_uploads - u1
	# 20 idle frames.
	var b2: int = ov.chunk_builds
	var u2: int = ov.gpu_uploads
	for _f in 20:
		ov._process(1.0 / 60.0)
	var idle_builds: int = ov.chunk_builds - b2
	var idle_uploads: int = ov.gpu_uploads - u2
	check(one_builds > 0 and one_builds <= 3 and fl_builds == 0 and fl_uploads == 0 and idle_builds == 0 and idle_uploads == 0,
		"alt_overlay incremental: one chunk changed -> %d builds (of %d chunks), same `fl` -> %d builds %d uploads, 20 idle frames -> %d builds %d uploads"
		% [one_builds, chunks.size(), fl_builds, fl_uploads, idle_builds, idle_uploads])
	# Cost guard (loose): one chunk's change on the 144-chunk base, median of 9.
	var times: Array = []
	for i in 9:
		w.chunks[chunks[(i * 7) % chunks.size()]].content_rev += 1
		w.entities_changed.emit(chunks[(i * 7) % chunks.size()])
		t0 = Time.get_ticks_usec()
		ov._process(1.0 / 60.0)
		times.append((Time.get_ticks_usec() - t0) / 1000.0)
		_inc_settle(ov, "gpu")
	times.sort()
	var med_inc: float = times[4]
	# The same with the whole-map caches, for the log.
	AltOverlay.incremental = false
	ov._clear_caches()
	ov._gpu_global_key = []
	_inc_settle(ov, "gpu")
	var old_times: Array = []
	for i in 5:
		w.chunks[chunks[(i * 7) % chunks.size()]].content_rev += 1
		w.entities_changed.emit(chunks[(i * 7) % chunks.size()])
		t0 = Time.get_ticks_usec()
		ov._process(1.0 / 60.0)
		old_times.append((Time.get_ticks_usec() - t0) / 1000.0)
		_inc_settle(ov, "gpu")
	old_times.sort()
	AltOverlay.incremental = true
	print("alt_overlay incremental: one chunk event on 144 chunks: %.2f ms (first %.2f), --alt-incremental=off %.2f ms"
		% [med_inc, one_ms, float(old_times[2])])
	check(med_inc < 5.0, "alt_overlay incremental: one chunk event's _process on 144 chunks %.2f ms (< 5 ms; whole-map %.2f ms)"
		% [med_inc, float(old_times[2])])
	_inc_free(sc)


## --alt-relift on the 144-chunk base, the card's path (GDScript, then native when loaded): a new field builds no
## chunk again (each cache lifted), the same field again sends nothing, and the buffer equals --alt-relift=off's.
func _inc_relift_counts() -> void:
	AltOverlay.icons_mode = "gpu"
	AltOverlay.incremental = true
	var prev_native := AltOverlay.native
	var natives := [false, true] if _native_ready() else [false]
	for nat: bool in natives:
		AltOverlay.native = nat
		AltOverlay.relift = true
		var sc := _inc_scene(12)
		var ov = sc.inc
		_inc_populate(sc)
		await get_tree().process_frame
		_inc_settle(ov, "gpu")
		AltOverlay.relift = false
		_inc_settle(sc.off, "gpu")
		AltOverlay.relift = true
		var hill := Image.create(96, 96, false, Image.FORMAT_RGF)
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		for hy in 96:
			for hx in 96:
				hill.set_pixel(hx, hy, Color(rng.randf_range(0.0, 3.0), rng.randf_range(0.0, 2.0), 0, 1))
		var b0: int = ov.chunk_builds
		var u0: int = ov.gpu_uploads
		var l0: int = ov.relifts
		GroundHeight.set_field(hill, Vector2(-8, -8), 4.0)
		var t0 := Time.get_ticks_usec()
		_inc_settle(ov, "gpu")
		var on_ms := (Time.get_ticks_usec() - t0) / 1000.0
		var new_builds: int = ov.chunk_builds - b0
		var new_uploads: int = ov.gpu_uploads - u0
		var lifted: int = ov.relifts - l0
		AltOverlay.relift = false
		var ob0: int = sc.off.chunk_builds
		t0 = Time.get_ticks_usec()
		_inc_settle(sc.off, "gpu")
		var off_ms := (Time.get_ticks_usec() - t0) / 1000.0
		var off_builds: int = sc.off.chunk_builds - ob0
		var b := _exact_sig(sc.off, "gpu")
		AltOverlay.relift = true
		var a := _exact_sig(ov, "gpu")
		var b1: int = ov.chunk_builds
		var u1: int = ov.gpu_uploads
		GroundHeight.set_field(hill, Vector2(-8, -8), 4.0)  # the same field again
		t0 = Time.get_ticks_usec()
		_inc_settle(ov, "gpu")
		var same_ms := (Time.get_ticks_usec() - t0) / 1000.0
		var same_builds: int = ov.chunk_builds - b1
		var same_uploads: int = ov.gpu_uploads - u1
		var a2 := _exact_sig(ov, "gpu")
		print("alt_overlay relift (%s): a new field on 144 chunks settled in %.1f ms (%d caches lifted), --alt-relift=off %.1f ms (%d chunk builds); the same field again %.1f ms"
			% ["native" if nat else "GDScript", on_ms, lifted, off_ms, off_builds, same_ms])
		check(new_builds == 0 and new_uploads >= 1 and lifted > 0 and same_builds == 0 and same_uploads == 0 and a == b and a2 == a and a.size() > 0,
			"alt_overlay relift (%s): a new field -> %d chunk builds, %d uploads, %d caches lifted; the same field again -> %d builds %d uploads; buffer equal to --alt-relift=off's: %s (%d instances)"
			% ["native" if nat else "GDScript", new_builds, new_uploads, lifted, same_builds, same_uploads, a == b, a.size()])
		GroundHeight.clear()
		_inc_free(sc)
	AltOverlay.native = prev_native


## --alt-quiet-builds on the 144-chunk base, the card's path: chunks' signals with no record changed build and send
## nothing and ask no redraw (=off: each builds its chunk again); a record changed in place with its signal builds
## its chunk and sends it.
func _inc_quiet_counts() -> void:
	AltOverlay.icons_mode = "gpu"
	AltOverlay.incremental = true
	var sc := _inc_scene(12)
	var w = sc.w
	var ov = sc.inc
	_inc_populate(sc)
	await get_tree().process_frame
	_inc_settle(ov, "gpu")
	var report := {}
	for quiet: bool in [true, false]:
		AltOverlay.quiet_builds = quiet
		_inc_settle(ov, "gpu")
		var b0: int = ov.chunk_builds
		var u0: int = ov.gpu_uploads
		var r0: int = ov._alt_rev
		for i in 12:
			w.entities_changed.emit(Vector2i(i, (i * 5) % 12))
		_inc_settle(ov, "gpu")
		report[quiet] = [ov.chunk_builds - b0, ov.gpu_uploads - u0, ov._alt_rev - r0]
	AltOverlay.quiet_builds = true
	_inc_settle(ov, "gpu")
	# A machine's recipe sent again in place: its chunk built and sent.
	var r: WorldMirror.Rec = null
	for e: WorldMirror.Rec in w.chunks[Vector2i(6, 6)].entities.values():
		if e.proto_id == 1:
			r = e
			break
	var b1: int = ov.chunk_builds
	var u1: int = ov.gpu_uploads
	w._add([r.unit, 1, int(r.pos.x * 256.0), int(r.pos.y * 256.0), 0, {"ai": ["recipe", "pipe" if WorldMirror.alt_icon(r).has("iron-gear-wheel") else "iron-gear-wheel"]}])
	w.entities_changed.emit(Vector2i(6, 6))
	_inc_settle(ov, "gpu")
	var moved_builds: int = ov.chunk_builds - b1
	var moved_uploads: int = ov.gpu_uploads - u1
	# A machine whose selection box is off its centre turned in place (as a Zenith-only turn, a predicted turn or its
	# revert do: world.record_edited, perf-w4-fix B-S1): its icon moves, so its chunk is built and sent again with
	# --alt-quiet-builds on (before, only cache_gen and a redraw: content_rev unchanged, the signal left alone).
	var mc := Vector2i(6, 6)
	w.protos.add_entities([[8, "assembling-machine-3", "assembling-machine", -1.5, -1.5, 1.5, 0.5, 150, 150, 150, 3, 3]])
	w._add([990001, 8, (mc.x * 32 + 16) * 256 + 128, (mc.y * 32 + 17) * 256 + 128, 0, {"ai": ["recipe", "pipe"]}])
	w.entities_changed.emit(mc)
	_inc_settle(ov, "gpu")
	var tr_rec: WorldMirror.Rec = w.entities.get(990001)
	var data0: PackedFloat32Array = ov._gpu_chunk_data(mc)
	var b2: int = ov.chunk_builds
	var u2: int = ov.gpu_uploads
	tr_rec.dir = posmod(tr_rec.dir + 4, 16)
	w.record_edited(tr_rec)
	w.entities_changed.emit(mc)
	_inc_settle(ov, "gpu")
	var turned_builds: int = ov.chunk_builds - b2
	var turned_uploads: int = ov.gpu_uploads - u2
	check(turned_builds > 0 and turned_uploads > 0 and ov._gpu_chunk_data(mc) != data0,
		"alt_overlay quiet builds: a turned machine with an off-centre selection rebuilds its chunk's icons (%d builds %d uploads)" % [turned_builds, turned_uploads])
	var q: Array = report[true]
	var o: Array = report[false]
	print("alt_overlay quiet builds: 12 unchanged signals -> %d builds %d uploads (--alt-quiet-builds=off %d builds); one record changed -> %d builds %d uploads"
		% [int(q[0]), int(q[1]), int(o[0]), moved_builds, moved_uploads])
	check(int(q[0]) == 0 and int(q[1]) == 0 and int(q[2]) == 0 and int(o[0]) > 0 and moved_builds > 0 and moved_uploads > 0,
		"alt_overlay quiet builds: 12 signals with no record changed -> %d builds %d uploads %d redraw revs (--alt-quiet-builds=off: %d builds %d uploads); a record changed in place -> %d builds %d uploads"
		% [int(q[0]), int(q[1]), int(q[2]), int(o[0]), int(o[1]), moved_builds, moved_uploads])
	_inc_free(sc)


## --alt-icons-later, the card's path: a chest holding a kind whose icon was never read builds without it, reading
## nothing on the main thread (ItemIcons.is_cached still false after the build); once the worker's read is taken
## the chunk is built again and the buffer equals --alt-icons-later=off's.
func _inc_icons_later() -> void:
	AltOverlay.icons_mode = "gpu"
	AltOverlay.incremental = true
	AltOverlay.icons_later = true
	var sc := _inc_scene(2)
	var w = sc.w
	var cold := "f3d-cold-test-icon-%d" % Time.get_ticks_usec()
	Bridge.set_alt_contents(true)
	w._add([501, 3, 5 * 256 + 128, 5 * 256 + 128, 0])
	w._add([502, 3, 9 * 256 + 128, 5 * 256 + 128, 0])
	w.entities_changed.emit(Vector2i(0, 0))
	var msg := {"t": "ac", "g": Bridge.alt_contents, "l": [[501, cold, ["iron-plate"]], [502, "iron-plate"]]}
	w.handle(msg)
	Bridge.message_received.emit(msg)
	var ov = sc.inc
	ov._process(1.0 / 60.0)  # the first build
	var cached_after := ItemIcons.is_cached(cold)
	var waiting: bool = ov._icon_wait.has(cold)
	var before := _exact_sig(ov, "gpu")
	_inc_settle(ov, "gpu")
	var after := _exact_sig(ov, "gpu")
	AltOverlay.icons_later = false
	_inc_settle(sc.off, "gpu")
	var ref := _exact_sig(sc.off, "gpu")
	AltOverlay.icons_later = true
	print("alt_overlay icons later: cold icon cached after the first build: %s; %d instances, %d after the read, --alt-icons-later=off %d"
		% [cached_after, before.size(), after.size(), ref.size()])
	check(not cached_after and waiting and after == ref and after.size() > before.size() and before.size() > 0,
		"alt_overlay icons later: a cold icon read on a worker (cached on the main thread after the first build: %s), %d instances then %d after its read, equal to --alt-icons-later=off's %d: %s"
		% [cached_after, before.size(), after.size(), ref.size(), after == ref])
	_inc_free(sc)


## Whether the three whole-map caches (or, --alt-incremental, their per-chunk keys) were built for this
## ModGraphics.generation (what 0) or ModelPacks.icons_version (what 1).
static func _whole_keys_at(overlay, v: int, what: int) -> bool:
	if AltOverlay.incremental:
		return int(overlay._inc_ac_key[5 + what]) == v and int(overlay._inc_am_key[5 + what]) == v \
			and int(overlay._inc_fl_key[3 + what]) == v
	if what == 0:
		return overlay._cached_ac_gfx == v and overlay._cached_am_gfx == v and overlay._cached_fl_gfx == v
	return overlay._cached_ac_icons == v and overlay._cached_am_icons == v and overlay._cached_fl_icons == v


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


## collect() until no chunk in view is left for the next frame (--alt-incremental builds at most
## ALT_VIEW_BUDGET_USEC of chunks a frame).
static func _collect_settled(overlay) -> void:
	overlay.collect()
	for _i in 50:
		if not overlay._inc_view_left:
			break
		overlay.collect()


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
	_collect_settled(overlay)
	var unbatched_list := overlay.paint_list()
	var unbatched_runs := _count_texture_runs(unbatched_list)

	AltOverlay.flat_batch_tex = true
	overlay._layers_key = []
	_collect_settled(overlay)
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
		_collect_settled(overlay)
	var cached_usec := Time.get_ticks_usec() - t0

	t0 = Time.get_ticks_usec()
	for k in 5:
		rig.camera.position.x -= 0.2
		AltOverlay.use_cache = false
		_collect_settled(overlay)
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
	_collect_settled(overlay)
	var far_unbatched := _count_texture_runs(overlay.paint_list())
	AltOverlay.flat_batch_tex = true
	overlay._layers_key = []
	_collect_settled(overlay)
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
