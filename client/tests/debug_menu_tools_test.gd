extends Node
## Verifies the expanded Debug Menu (Render & Bridge tabs, Tests enhancements, Lighting Reset All),
## DebugOverlay profiler, runtime debug hooks (ItemCards.forced_lod_tier, BeltItems.apply_debug_item_settings,
## BeltLanes.set_far_3d_dist / _far_3d_debug), and removal of Settings > Graphics > Metal on textured models.
##   godot --headless --audio-driver Dummy --path client res://tests/debug_menu_tools_test.tscn

const BeltItems := preload("res://scripts/world/belt_items.gd")
const BeltLanes := preload("res://scripts/world/belt_lanes.gd")
const BeltLods := preload("res://scripts/world/belt_lods.gd")
const DebugMenu := preload("res://scripts/ui/factorio/debug_menu.gd")
const DebugOverlay := preload("res://scripts/debug/debug_overlay.gd")
const FarChunks := preload("res://scripts/world/far_chunks.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const ItemModels := preload("res://scripts/world/item_models.gd")
const Looks := preload("res://scripts/world/looks.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const PerfLog := preload("res://scripts/world/perf_log.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const SettingsWindow := preload("res://scripts/menu/settings_window.gd")
const TestEnv := preload("res://tests/test_env.gd")
const UiModel := preload("res://scripts/ui/factorio/ui_model.gd")

var fails := 0


class FakeCountNode:
	extends Node3D
	var _n := 0

	func count() -> int:
		return _n


class FakeFarChunks:
	extends Node
	var enabled := true
	var _far_count := 3
	var reset_calls := 0

	func reset_decide() -> void:
		reset_calls += 1

	func census() -> Array:
		return [_far_count if enabled else 0, 1200 if enabled else 0, _far_count]


class FakeWorld:
	extends Node3D
	var far_chunks: FakeFarChunks = null
	var chunks := {Vector2i.ZERO: true, Vector2i(1, 0): true}
	var view_radius := 10
	var focus_radius := 24
	var remote_view := false
	var hold := false
	var behind_cull = null

	func focus() -> Vector2:
		return Vector2.ZERO

	func loaded_chunk_count() -> int:
		return chunks.size()

	func entity_count() -> int:
		return 42


class FakeHorizon:
	extends Node3D
	var enabled := true

	func stats() -> Dictionary:
		return {
			"enabled": enabled,
			"radius_chunks": 48,
			"visible_sections": 4,
			"sections": 16,
			"triangles": 12000,
		}


class FakeShadows:
	extends Node
	var atlas := 4096
	var texels := 16.0
	var blur_override := 0.0


class FakeAvatar:
	extends Node3D

	func ground_position() -> Vector2:
		return Vector2(64.5, -32.25)


class FakeRig:
	extends Node
	var distance := 22.0
	var pitch_degrees := 48.0
	var yaw_degrees := 135.0
	var camera: Camera3D = null

	func focus_point() -> Vector2:
		return Vector2(65.0, -32.0)


class FakeMain:
	extends Node3D
	var world: FakeWorld
	var belt_items: Node3D
	var belt_lanes: Node3D
	var ground_items: FakeCountNode
	var decoratives: Node3D
	var arms: Node3D
	var movers: FakeCountNode
	var distant_horizon: FakeHorizon
	var pollution: Node3D
	var god_rays: Node3D
	var lamps: Node3D
	var signal_lights: Node3D
	var working_glow: Node3D
	var wires: Node3D
	var fx: Node3D
	var _sun: DirectionalLight3D
	var sun_shadows: FakeShadows
	var avatar: FakeAvatar
	var rig: FakeRig
	var ups_overlay_on := false


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _ready() -> void:
	TestEnv.isolate("debug-menu-tools-test")
	_run.call_deferred()


func _make_protos() -> ProtoDB:
	var p := ProtoDB.new()
	p.item_names = {1: "copper-cable", 2: "stone", 3: "iron-plate"}
	p.item_ids = {"copper-cable": 1, "stone": 2, "iron-plate": 3}
	return p


func _make_fake_main(vp: Viewport) -> FakeMain:
	var m := FakeMain.new()
	m.world = FakeWorld.new()
	m.world.far_chunks = FakeFarChunks.new()
	m.world.add_child(m.world.far_chunks)
	m.add_child(m.world)

	var protos := _make_protos()
	var bi := BeltItems.new()
	bi.protos = protos
	bi.world = m.world
	m.belt_items = bi
	m.add_child(bi)

	var bl := BeltLanes.new()
	bl.protos = protos
	m.belt_lanes = bl
	m.add_child(bl)

	m.ground_items = FakeCountNode.new()
	m.ground_items._n = 7
	m.add_child(m.ground_items)
	m.decoratives = null
	m.arms = Node3D.new()
	m.add_child(m.arms)
	m.movers = FakeCountNode.new()
	m.movers._n = 3
	m.add_child(m.movers)
	m.distant_horizon = FakeHorizon.new()
	m.add_child(m.distant_horizon)
	m.pollution = Node3D.new()
	m.add_child(m.pollution)
	m.god_rays = Node3D.new()
	m.add_child(m.god_rays)
	m.lamps = Node3D.new()
	m.add_child(m.lamps)
	m.signal_lights = Node3D.new()
	m.add_child(m.signal_lights)
	m.working_glow = Node3D.new()
	m.add_child(m.working_glow)
	m.wires = Node3D.new()
	m.add_child(m.wires)
	m.fx = Node3D.new()
	m.add_child(m.fx)
	m._sun = DirectionalLight3D.new()
	m._sun.shadow_enabled = true
	m.add_child(m._sun)
	m.sun_shadows = FakeShadows.new()
	m.add_child(m.sun_shadows)
	m.avatar = FakeAvatar.new()
	m.add_child(m.avatar)
	m.rig = FakeRig.new()
	m.rig.camera = vp.get_camera_3d()
	m.add_child(m.rig)
	vp.add_child(m)
	return m


func _take_sent() -> Array:
	var out: Array = []
	for text in Bridge.capture:
		var msg: Variant = JSON.parse_string(str(text))
		if msg is Dictionary and str((msg as Dictionary).get("t", "")) != "hello":
			out.append(msg)
	Bridge.capture.clear()
	return out


func _run() -> void:
	# Snapshot globals & singletons.
	var was_dev: int = Settings.dev_tools_override
	var was_old_gfx: int = SettingsWindow.old_graphics_layout_override
	var was_ready: bool = Bridge.world_ready
	var was_capture = Bridge.capture
	var was_bind_err: int = Bridge.bind_error
	var was_pbr_tune := Looks.pbr_tune.duplicate(true)
	var was_light_tune := Looks.light_tune.duplicate(true)
	var was_forced_lod := ItemCards.forced_lod_tier
	var was_lat_mode := ItemCards.lattice_variants_mode
	var was_use_models := ItemCards.use_models
	var was_model_cap := ItemCards.model_cap
	var was_shadow_proxy := ItemCards.shadow_proxy_enabled
	var was_lod_mode := ItemCards.lod_mode
	var was_geom_lod := ItemModels.item_geom_lod
	var was_far_3d := BeltLanes.far_3d_dist
	var was_far_3d_dbg := BeltLanes._far_3d_debug
	var was_far_pbr := BeltLanes.far_item_pbr_full
	var was_far_var := BeltLanes.far_belt_variants
	var was_belt_lods := BeltLods.enabled
	var was_belt_lods_dirty := BeltLods._dirty
	var was_far_coarse := FarChunks.far_coarse
	var was_perf_entries := PerfLog.entries.duplicate(true)

	Settings.dev_tools_override = 1
	Bridge.capture = []
	Bridge.bind_error = OK
	Bridge.world_ready = true

	ModelPacks.configure("", ["builtin:placeholders"], [])
	ModelPacks.wait()
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.85, 0.45, 0.2, 1.0))
	ItemIcons.store("copper-cable", ImageTexture.create_from_image(img))
	ItemIcons.store("stone", ImageTexture.create_from_image(img))

	var vp := SubViewport.new()
	vp.size = Vector2i(1280, 720)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var cam := Camera3D.new()
	cam.fov = 50.0
	cam.global_position = Vector3(0.0, 20.0, 0.0)
	vp.add_child(cam)
	cam.current = true

	var main := _make_fake_main(vp)
	var model := UiModel.new()
	var dm := DebugMenu.new()
	dm.model = model
	dm.main = main
	vp.add_child(dm)
	await get_tree().process_frame

	await _test_tabs_and_controls(dm)
	await _test_dev_tools_gating(dm, main, vp)
	await _test_render_tab_and_reset(dm, main, vp)
	await _test_item_lod_override_and_shadows(vp, cam)
	await _test_profiler_and_audit(dm, main)
	_test_bridge_teleport_snapshot_and_lighting(dm, model)
	await _test_texture_metal_removed()

	# Restore static state cleanly.
	vp.queue_free()
	await get_tree().process_frame
	Settings.dev_tools_override = was_dev
	SettingsWindow.old_graphics_layout_override = was_old_gfx
	Bridge.world_ready = was_ready
	Bridge.capture = was_capture
	Bridge.bind_error = was_bind_err
	Looks.pbr_tune = was_pbr_tune
	Looks.light_tune = was_light_tune
	ItemCards.forced_lod_tier = was_forced_lod
	ItemCards.lattice_variants_mode = was_lat_mode
	ItemCards.use_models = was_use_models
	ItemCards.model_cap = was_model_cap
	ItemCards.shadow_proxy_enabled = was_shadow_proxy
	ItemCards.lod_mode = was_lod_mode
	ItemModels.item_geom_lod = was_geom_lod
	BeltLanes.far_3d_dist = was_far_3d
	BeltLanes._far_3d_debug = was_far_3d_dbg
	BeltLanes.far_item_pbr_full = was_far_pbr
	BeltLanes.far_belt_variants = was_far_var
	BeltLods.enabled = was_belt_lods
	BeltLods._dirty = was_belt_lods_dirty
	FarChunks.far_coarse = was_far_coarse
	PerfLog.entries = was_perf_entries
	ModelPacks.configure("", [], [])
	ModelPacks.wait()

	print("debug_menu_tools_test: %s" % ("PASS" if fails == 0 else "%d FAILED" % fails))
	TestEnv.clean()
	get_tree().quit(1 if fails > 0 else 0)


func _test_tabs_and_controls(dm: Control) -> void:
	var tab_names: Array = []
	for b: Button in dm._tab_buttons:
		tab_names.append(b.text)
	check(tab_names == ["Time", "Benchmarks", "Tests", "Updates", "Simulation", "Lighting", "Render", "Bridge"],
		"Tabs: expected 8 tabs in order, got %s" % [tab_names])

	var expected_names := [
		"RenderDraw_disabled", "RenderDraw_wireframe", "RenderDraw_overdraw", "RenderDraw_unshaded",
		"RenderDraw_lighting", "RenderDraw_normal", "RenderDraw_shadows",
		"Layer_world", "Layer_belt_items", "Layer_belt_lanes", "Layer_ground_items",
		"Layer_decoratives", "Layer_arms", "Layer_movers", "Layer_distant_horizon",
		"Layer_pollution", "Layer_god_rays", "Layer_lights", "Layer_wires", "Layer_fx", "Layer_sun_shadows",
		"Layer_all_on",
		"ItemLod_auto", "ItemLod_0", "ItemLod_1", "ItemLod_2",
		"LatticeVar_close", "LatticeVar_all", "LatticeVar_off",
		"Far3dDist", "Far3dDistAll",
		"RenderOpt_item_models", "RenderOpt_item_geom_lod", "RenderOpt_item_shadow_proxy",
		"RenderOpt_far_item_pbr", "RenderOpt_far_belt_variants", "RenderOpt_belt_stand_ins",
		"RenderOpt_far_merge", "RenderOpt_far_coarse",
		"RenderResetAll", "RenderStats",
		"Bridge_profile", "Bridge_trace", "Bridge_status", "Bridge_selftest", "Bridge_perf", "Bridge_bs",
		"BridgeRate_0", "BridgeRate_1", "BridgeRate_2", "BridgeRate_3", "BridgeRate_free",
		"BridgeCmdBox", "BridgeCmdSend",
		"BridgeQuick_evo", "BridgeQuick_seed", "BridgeQuick_time", "BridgeQuick_players",
		"BridgePerfLog", "BridgePerfClear", "CopySnapshot",
		"OpenLogs", "OpenDebug", "OpenBenchmarks", "BridgeOut",
		"Test_profiler", "Test_ao_audit", "PosLabel", "TeleportX", "TeleportY", "TeleportGo", "CopyPos",
		"LightResetAll",
	]
	var missing: Array = []
	for cname: String in expected_names:
		if dm.find_child(cname, true, false) == null:
			missing.append(cname)
	check(missing.is_empty(), "Controls: all new debug menu controls exist (%s)" % [missing])
	await get_tree().process_frame


func _test_dev_tools_gating(dm: Control, main: FakeMain, vp: SubViewport) -> void:
	dm._state = {"dt": 0.0, "fz": 0, "sp": 1, "pa": 0, "ad": 0, "s": "nauvis", "x": 2560, "y": -512, "sx": 0, "sy": 0}
	dm._why = ""
	_take_sent()

	Settings.dev_tools_override = 0
	var was_draw := vp.debug_draw
	var was_world_vis := main.world.visible
	var was_forced := ItemCards.forced_lod_tier
	var was_lat := ItemCards.lattice_variants_mode
	var was_far := BeltLanes.far_3d_dist
	var was_models := ItemCards.use_models
	Looks.pbr_tune["pbr_fill"] = 0.77
	Looks.light_tune["sun_energy"] = 2.5

	var ok_gate: bool = (not dm.set_render_draw("wireframe")
		and not dm.set_layer_visible("world", false)
		and not dm.show_all_layers()
		and not dm.set_item_lod_override(1)
		and not dm.set_lattice_variants_mode("off")
		and not dm.set_far_3d_dist(16.0)
		and not dm.set_render_toggle("item_models", false)
		and not dm.reset_render()
		and not dm.teleport_to("10", "20")
		and not dm.send_bridge_cmd("f3d-perf"))
	dm.reset_all_light()
	(dm.find_child("BridgeRate_0", true, false) as Button).pressed.emit()
	var sent_when_off := _take_sent()
	check(ok_gate
		and vp.debug_draw == was_draw
		and main.world.visible == was_world_vis
		and ItemCards.forced_lod_tier == was_forced
		and ItemCards.lattice_variants_mode == was_lat
		and is_equal_approx(BeltLanes.far_3d_dist, was_far)
		and ItemCards.use_models == was_models
		and Looks.pbr_tune.has("pbr_fill")
		and Looks.light_tune.has("sun_energy")
		and sent_when_off.is_empty(),
		"Dev tools gate: dev_tools_override=0 blocks all new mutators, reset_all_light, and BridgeRate_* (%s)" % [sent_when_off])

	Looks.pbr_tune.clear()
	Looks.light_tune.clear()
	Settings.dev_tools_override = 1
	await get_tree().process_frame


func _test_render_tab_and_reset(dm: Control, main: FakeMain, vp: SubViewport) -> void:
	# Viewport debug draw modes
	check(dm.set_render_draw("wireframe") and vp.debug_draw == Viewport.DEBUG_DRAW_WIREFRAME,
		"Render draw: wireframe sets Viewport.DEBUG_DRAW_WIREFRAME")
	check(dm.set_render_draw("overdraw") and vp.debug_draw == Viewport.DEBUG_DRAW_OVERDRAW,
		"Render draw: overdraw sets Viewport.DEBUG_DRAW_OVERDRAW")
	check(dm.set_render_draw("disabled") and vp.debug_draw == Viewport.DEBUG_DRAW_DISABLED,
		"Render draw: disabled restores Viewport.DEBUG_DRAW_DISABLED")
	dm.set_render_draw("wireframe")

	# Layer visibility isolators including lights group and sun_shadows
	check(dm.set_layer_visible("world", false) and not main.world.visible,
		"Render layers: hiding world sets main.world.visible=false")
	check(dm.set_layer_visible("lights", false)
		and not main.lamps.visible and not main.signal_lights.visible and not main.working_glow.visible,
		"Render layers: hiding lights hides lamps, signal_lights, and working_glow")
	check(dm.set_layer_visible("sun_shadows", false) and not main._sun.shadow_enabled,
		"Render layers: hiding sun_shadows disables _sun.shadow_enabled")
	check(dm.show_all_layers()
		and main.world.visible and main.lamps.visible and main.signal_lights.visible
		and main.working_glow.visible and main._sun.shadow_enabled,
		"Render layers: show_all_layers restores all layer visibility")
	dm.set_layer_visible("lights", false)
	dm.set_layer_visible("sun_shadows", false)

	# Far 3D distance + _far_3d_debug guard against apply_lod_quality()
	var prev_far_dist := BeltLanes.far_3d_dist
	var prev_far_dbg := BeltLanes._far_3d_debug
	check(dm.set_far_3d_dist(-1.0) and BeltLanes.far_3d_dist < 0.0 and BeltLanes._far_3d_debug,
		"Render far 3D: -1 enables All and sets _far_3d_debug=true")
	check(dm.set_far_3d_dist(24.0) and is_equal_approx(BeltLanes.far_3d_dist, 24.0) and BeltLanes._far_3d_debug,
		"Render far 3D: 24.0 sets far_3d_dist=24 and _far_3d_debug=true")
	main.belt_lanes.apply_lod_quality("ultra")
	check(is_equal_approx(BeltLanes.far_3d_dist, 24.0),
		"Render far 3D: apply_lod_quality('ultra') does not overwrite debug override")

	# Forced LOD & lattice variants & all 8 RenderOpt checkboxes
	dm.set_item_lod_override(2)
	dm.set_lattice_variants_mode("off")
	var opt_targets := {
		"item_models": false,
		"item_geom_lod": false,
		"item_shadow_proxy": false,
		"far_item_pbr": true,
		"far_belt_variants": true,
		"belt_stand_ins": false,
		"far_merge": false,
		"far_coarse": false,
	}
	for k: String in opt_targets:
		var box := dm.find_child("RenderOpt_" + k, true, false) as CheckBox
		var want := bool(opt_targets[k])
		box.button_pressed = want
	check(ItemCards.forced_lod_tier == 2
		and ItemCards.lattice_variants_mode == "off"
		and ItemCards.use_models == false
		and ItemModels.item_geom_lod == false
		and ItemCards.shadow_proxy_enabled == false
		and BeltLanes.far_item_pbr_full == true
		and BeltLanes.far_belt_variants == true
		and BeltLods.enabled == false
		and main.world.far_chunks.enabled == false
		and FarChunks.far_coarse == false,
		"Render opts: all 8 checkboxes, forced LOD, and lattice variants update live state")

	# Reset all render overrides
	check(dm.reset_render(), "Render reset: reset_render returns true")
	check(vp.debug_draw == Viewport.DEBUG_DRAW_DISABLED
		and main.lamps.visible and main.signal_lights.visible and main.working_glow.visible
		and main._sun.shadow_enabled
		and ItemCards.forced_lod_tier == -1
		and ItemCards.lattice_variants_mode == "close"
		and is_equal_approx(BeltLanes.far_3d_dist, prev_far_dist)
		and BeltLanes._far_3d_debug == prev_far_dbg
		and ItemCards.use_models == true
		and ItemModels.item_geom_lod == true
		and ItemCards.shadow_proxy_enabled == true
		and BeltLanes.far_item_pbr_full == false
		and BeltLanes.far_belt_variants == false
		and BeltLods.enabled == true
		and main.world.far_chunks.enabled == true
		and FarChunks.far_coarse == true,
		"Render reset: reset_render restores viewport draw, layers, item LOD, lattice, far_3d_dist + _far_3d_debug, and all 8 toggles")

	main.belt_lanes.apply_lod_quality("ultra")
	check(is_equal_approx(BeltLanes.far_3d_dist, 80.0),
		"Render reset: after _far_3d_debug restored to false, apply_lod_quality('ultra') updates far_3d_dist to 80")
	BeltLanes.far_3d_dist = prev_far_dist
	BeltLanes._far_3d_debug = prev_far_dbg

	# Item models toggle from Icons-only (model_cap == 0) lifts model_cap to -1 and reset_render restores 0
	var saved_cap := ItemCards.model_cap
	ItemCards.use_models = false
	ItemCards.model_cap = 0
	dm.set_render_toggle("item_models", true)
	check(ItemCards.use_models and ItemCards.model_cap == -1,
		"Render opt item_models: turning on from model_cap=0 lifts model_cap to -1")
	dm.reset_render()
	check(not ItemCards.use_models and ItemCards.model_cap == 0,
		"Render reset: restores use_models=false and model_cap=0")
	ItemCards.use_models = true
	ItemCards.model_cap = saved_cap
	await get_tree().process_frame


func _test_item_lod_override_and_shadows(vp: SubViewport, cam: Camera3D) -> void:
	# 1. Distance mode with real 3D shadow proxy twin
	ItemCards.lod_mode = "distance"
	ItemCards.forced_lod_tier = -1
	ItemCards.use_models = true
	ItemModels.item_geom_lod = true
	ItemCards.shadow_proxy_enabled = true

	var cards := ItemCards.new()
	cards.allow_lod = true
	cards.use_shadow_proxy = true
	cards.casts_shadow = true
	cards.protos = _make_protos()
	vp.add_child(cards)
	var bounds := AABB(Vector3(-8, -1, -8), Vector3(16, 4, 16))
	cards.put_records(1, 0, 4, 8, bounds)
	await get_tree().process_frame

	cards.update_distance_lod(cam, 1080.0, bounds)
	var smmi: MultiMeshInstance3D = cards._shadow_kinds.get(1)
	check(smmi != null and smmi.visible and cards._shadow_tier_ok(),
		"ItemCards LOD distance: auto distance creates visible shadow proxy for copper-cable")

	ItemCards.forced_lod_tier = 1
	cards.update_distance_lod(cam, 1080.0, bounds)
	check(cards._lod_band_mask == 2
		and is_equal_approx(cards._lod_d1, 0.0)
		and not is_finite(cards._lod_d2)
		and not cards._shadow_tier_ok()
		and (smmi == null or not smmi.visible),
		"ItemCards LOD distance: forced=1 sets mask=2, d1=0, d2=INF, hides shadow proxy")

	ItemCards.forced_lod_tier = 2
	cards.update_distance_lod(cam, 1080.0, bounds)
	check(cards._lod_band_mask == 4
		and is_equal_approx(cards._lod_d1, 0.0)
		and is_equal_approx(cards._lod_d2, 0.0)
		and not cards._shadow_tier_ok()
		and (smmi == null or not smmi.visible),
		"ItemCards LOD distance: forced=2 sets mask=4, d1=0, d2=0, hides shadow proxy")

	ItemCards.forced_lod_tier = 0
	cards.update_distance_lod(cam, 1080.0, bounds)
	check(cards._lod_band_mask == 1
		and not is_finite(cards._lod_d1)
		and not is_finite(cards._lod_d2)
		and cards._shadow_tier_ok()
		and (smmi != null and smmi.visible),
		"ItemCards LOD distance: forced=0 sets mask=1, d1=INF, d2=INF, shows shadow proxy")

	# Ortho medium zoom where auto band has LOD1 only; transitioning forced 1 -> -1 still restores _shadow_tier_ok
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 45.0
	ItemCards.forced_lod_tier = 1
	cards.update_distance_lod(cam, 1080.0, bounds)
	ItemCards.forced_lod_tier = -1
	cards.update_distance_lod(cam, 1080.0, bounds)
	check(cards._shadow_tier_ok() and (smmi != null and smmi.visible),
		"ItemCards LOD distance: ortho forced 1 -> -1 restores shadow proxy visibility")
	ItemCards.forced_lod_tier = 2
	ItemModels.item_geom_lod = false
	check(cards._shadow_tier_ok(),
		"ItemCards LOD distance: forced=2 keeps _shadow_tier_ok() true when item_geom_lod=false")
	ItemModels.item_geom_lod = true
	ItemCards.forced_lod_tier = -1
	cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	cam.size = 1.0
	cards.queue_free()

	# 2. Global mode via BeltItems.apply_debug_item_settings()
	ItemCards.lod_mode = "global"
	var bi := BeltItems.new()
	bi.protos = _make_protos()
	vp.add_child(bi)
	await get_tree().process_frame
	bi._square = Vector3(0.0, 0.0, 16.0)
	cam.global_position = Vector3(0.0, 15.0, 0.0)
	ItemCards.forced_lod_tier = 2
	bi.apply_debug_item_settings(false)
	var forced2_ok: bool = bi._cards.lod_tier == 2 and bi._lat_cards.lod_tier == 2
	ItemCards.forced_lod_tier = 1
	bi.apply_debug_item_settings(false)
	var forced1_ok: bool = bi._cards.lod_tier == 1 and bi._lat_cards.lod_tier == 1
	ItemCards.forced_lod_tier = 0
	bi.apply_debug_item_settings(false)
	var forced0_ok: bool = bi._cards.lod_tier == 0 and bi._lat_cards.lod_tier == 0
	cam.global_position = Vector3(0.0, 80.0, 0.0)
	ItemCards.forced_lod_tier = -1
	bi.apply_debug_item_settings(false)
	var auto_back_ok: bool = bi._cards.lod_tier == 2
	check(forced2_ok and forced1_ok and forced0_ok and auto_back_ok,
		"BeltItems global LOD: apply_debug_item_settings enforces tiers 2/1/0 and restores auto (%s/%s/%s/%s)" % [
			forced2_ok, forced1_ok, forced0_ok, auto_back_ok])
	bi.queue_free()
	ItemCards.lod_mode = "distance"
	ItemCards.forced_lod_tier = -1
	await get_tree().process_frame


func _test_profiler_and_audit(dm: Control, main: FakeMain) -> void:
	var prof_btn := dm.find_child("Test_profiler", true, false) as Button
	var cnt_btn := dm.find_child("Test_counters", true, false) as Button
	prof_btn.button_pressed = true
	cnt_btn.button_pressed = true
	check(dm._overlay != null and dm._overlay.profiler and dm._overlay.counters,
		"Profiler toggle: Test_profiler enables DebugOverlay.profiler")
	var ptext: String = dm._overlay.profiler_text()
	var ctext: String = dm._overlay.counter_text()
	check(ptext.contains("FPS ") and ptext.contains("GPU ") and ptext.contains("Render CPU ")
		and ptext.contains("View ") and ptext.contains("Shadow ") and ptext.contains("Net ")
		and ptext.contains("Shadows ") and ptext.contains("Items ") and ptext.contains("Horizon ")
		and ptext.contains("FarChunks "),
		"Profiler text: contains FPS/GPU/Render CPU/View/Shadow/Net/Shadows/Items/Horizon/FarChunks lines:\n%s" % ptext)
	check(ctext.contains("draw calls"), "Counter text: preserves 'draw calls' expectation")
	prof_btn.button_pressed = false
	cnt_btn.button_pressed = false
	check(not dm._overlay.profiler and not dm._overlay.counters,
		"Profiler toggle: toggles back off cleanly")
	var off_text: String = dm._overlay.profiler_text()
	check(off_text.contains("GPU off | Render CPU off"),
		"Profiler text: reports 'off' rather than 'render thread' when profiler is off:\n%s" % off_text)

	# Add a visible MultiMeshInstance3D, a SHADOWS_ONLY proxy, and a ContactShade node with baked AO shader param.
	var mesh := BoxMesh.new()
	var mm := MultiMesh.new()
	mm.mesh = mesh
	mm.instance_count = 3
	var vis_mmi := MultiMeshInstance3D.new()
	vis_mmi.multimesh = mm
	main.add_child(vis_mmi)

	var smm := MultiMesh.new()
	smm.mesh = mesh
	smm.instance_count = 2
	var shad_mmi := MultiMeshInstance3D.new()
	shad_mmi.multimesh = smm
	shad_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	main.add_child(shad_mmi)

	var hid_smmi := MultiMeshInstance3D.new()
	hid_smmi.multimesh = smm
	hid_smmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	hid_smmi.visible = false
	main.add_child(hid_smmi)

	var csh := Shader.new()
	csh.code = "shader_type spatial;\nuniform float ao_strength = 0.5;\nvoid fragment() { ALBEDO = vec3(0.5); }\n"
	var cmat := ShaderMaterial.new()
	cmat.shader = csh
	cmat.set_shader_parameter("ao_strength", 0.5)
	var cm := MultiMesh.new()
	cm.mesh = mesh
	cm.instance_count = 4
	var contact_mmi := MultiMeshInstance3D.new()
	contact_mmi.name = "ContactShade"
	contact_mmi.multimesh = cm
	contact_mmi.material_override = cmat
	main.add_child(contact_mmi)

	var audit: String = dm.run_scene_audit()
	check(audit.contains("Scene render audit:")
		and audit.contains("shadows-only: 1 (2 instances)")
		and audit.contains("Contact rings: 1 nodes (4 visible instances)")
		and audit.contains("Baked AO materials: 1 /"),
		"Scene audit: counts MultiMeshes, shadow-only proxies, contact rings, and baked AO materials:\n%s" % audit)
	await get_tree().process_frame


func _test_bridge_teleport_snapshot_and_lighting(dm: Control, model: UiModel) -> void:
	dm._state = {"dt": 0.0, "fz": 0, "sp": 1, "pa": 0, "ad": 0, "s": "nauvis", "x": 2560, "y": -512, "sx": 0, "sy": 0}
	dm._why = ""
	dm._sync_pos_label()
	check((dm.find_child("PosLabel", true, false) as Label).text.contains("10.0, -2.0"),
		"Teleport pos label: formats server x/y (1/256 tile) cleanly")

	# Validation & formatting
	_take_sent()
	check(not dm.teleport_to("abc", "10") and not dm.teleport_to("10", "") and not dm.teleport_to("2000000", "0"),
		"Teleport: rejects invalid, empty, and out-of-range coordinates")
	check(_take_sent().is_empty(), "Teleport: invalid coordinates send no bridge command")
	check(dm.teleport_to("12.5", "-3.5"), "Teleport: accepts valid float coordinates")
	var tp_sent := _take_sent()
	check(tp_sent.size() == 1 and str((tp_sent[0] as Dictionary).get("text", "")) == "/f3d-debug teleport 12.5 -3.5",
		"Teleport: sends /f3d-debug teleport 12.5 -3.5 (%s)" % [tp_sent])

	# Bridge command auto-'/', BridgeRate_* button, and _on_reply updating BridgeOut
	check(dm.send_bridge_cmd("evolution"), "Bridge cmd: auto-prefixes '/' when missing")
	(dm.find_child("BridgeRate_2", true, false) as Button).pressed.emit()
	var br_sent := _take_sent()
	check(br_sent.size() == 2
		and str((br_sent[0] as Dictionary).get("text", "")) == "/evolution"
		and str((br_sent[1] as Dictionary).get("text", "")) == "/f3d-rate 2 hold",
		"Bridge cmd & rate: sends '/evolution' and '/f3d-rate 2 hold' (%s)" % [br_sent])
	model.handle({"t": "cmdr", "id": model._command_id, "l": ["rate held at 2"]})
	var bridge_out := dm.find_child("BridgeOut", true, false) as Label
	check(bridge_out.text.contains("rate held at 2"),
		"Bridge output: cmdr updates BridgeOut (%s)" % bridge_out.text)

	# Snapshot text sections
	var prof_btn := dm.find_child("Test_profiler", true, false) as Button
	prof_btn.button_pressed = true
	var snap: String = dm.snapshot_text()
	prof_btn.button_pressed = false
	check(snap.contains("Bridge:") and snap.contains("Net:") and snap.contains("Render:")
		and snap.contains("Render opts:") and snap.contains("Profiler:") and snap.contains("light:")
		and snap.contains("PerfLog"),
		"Snapshot text: includes Bridge, Net, Render, Render opts, Profiler, light, and PerfLog")

	# Lighting Reset all button
	Looks.pbr_tune["pbr_fill"] = 0.9
	Looks.light_tune["sun_energy"] = 2.0
	(dm.find_child("LightResetAll", true, false) as Button).pressed.emit()
	check(Looks.pbr_tune.is_empty() and Looks.light_tune.is_empty(),
		"Lighting ResetAll: clears both Looks.pbr_tune and Looks.light_tune")


func _test_texture_metal_removed() -> void:
	check(not Settings.DEFAULTS["graphics"].has("texture_metal"),
		"texture_metal removed: absent from Settings.DEFAULTS['graphics']")

	var vp := SubViewport.new()
	vp.size = Vector2i(1280, 720)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)

	SettingsWindow.old_graphics_layout_override = 0
	var w_modern: Node = SettingsWindow.new()
	vp.add_child(w_modern)
	await get_tree().process_frame
	await get_tree().process_frame
	check(w_modern.find_child("graphics-texture_metal", true, false) == null,
		"texture_metal removed: absent from modern card Graphics settings UI")
	w_modern.queue_free()

	SettingsWindow.old_graphics_layout_override = 1
	var w_legacy: Node = SettingsWindow.new()
	vp.add_child(w_legacy)
	await get_tree().process_frame
	await get_tree().process_frame
	check(w_legacy.find_child("graphics-texture_metal", true, false) == null,
		"texture_metal removed: absent from legacy grid Graphics settings UI")
	w_legacy.queue_free()
	vp.queue_free()

	check(is_equal_approx(Looks.texture_metal_arg(PackedStringArray(["--texture-metal=full"])), 1.0)
		and is_equal_approx(Looks.texture_metal_arg(PackedStringArray(["--texture-metal=paint"])), 0.1)
		and is_equal_approx(Looks.texture_metal_arg(PackedStringArray(["--texture-metal=0.3"])), 0.3),
		"texture_metal CLI preserved: --texture-metal=full|paint|0.3 still parses")
	await get_tree().process_frame
