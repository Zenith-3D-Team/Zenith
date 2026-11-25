extends Node
## Shared preloads, counters, and test helpers for ui_test.gd and ui_area_*.gd.

## The Factorio-style UI without a server, played like a player with synthetic clicks and keys:
## picking up, splitting, swapping and putting back stacks, machine screens (moves, Shift
## transfers, status, fluids), number keys, quickbar pins and drops, the crafting queue, weapon
## slots, the health bar, the technology screen (T), Esc and F4, keys that mustn't reach buttons,
## the UI scale, the map (M, minimap, tags, chart requests, the map view's layers and switches), the
## settings store (one file, migration from ui.cfg / audio.cfg), the Settings window's tabs, key
## binding with modifiers, the map generator, the mods list, the model's hooks for the mod's data,
## and the Factorio parity controls (rebindable keys with modifiers, quickbar pages, statistics,
## chat, Alt-mode, the clipboard, inserter / splitter / chest bar / combinator / train stop screens,
## the item chooser, splitting transfers, crafting search), blueprints and planners (exchange
## strings, the library, the blueprint / book / planner windows, undo entries, the selection
## highlight, quality and book cycling), circuit settings, decider / selector / constant combinators
## in full, lamp colour, speaker, pump, turret targets, display panel messages, the wire tools,
## tiles, capsules, the rail planner and drag building, and the HUD's layout at common window sizes. The commands the UI sends are caught by
## the Bridge. Exits with 1 if a check fails. Each run has a user folder of its own (test_env.gd),
## and test_watchdog.gd stops one that doesn't compile or passes its time limit.
##
##   godot --headless --path client res://tests/ui_test.tscn
##   godot --headless --path client res://tests/ui_test.tscn -- --only=_terrain,_belt_paths
##       only those sections (any function called from _ready; the set-up always runs, NEEDS adds
##       what a section needs from another)
##   godot --headless --path client res://tests/ui_test.tscn -- --time-limit=600
##   godot --path client res://tests/ui_test.tscn -- <out.png>   also saves the HUD as a picture

const Hud := preload("res://scripts/ui/hud.gd")
const PlanetSpinScript := preload("res://scripts/world/planet_spin.gd")
const UiModel := preload("res://scripts/ui/factorio/ui_model.gd")
const ScheduleEditor := preload("res://scripts/ui/factorio/schedule_editor.gd")
const Kit := preload("res://scripts/ui/factorio/kit.gd")
const MenuKit := preload("res://scripts/menu/menu_kit.gd")
const MachineScreen := preload("res://scripts/ui/factorio/machine_screen.gd")
const ProductionPanels := preload("res://scripts/ui/factorio/production_panels.gd")
const Alerts := preload("res://scripts/ui/factorio/alerts.gd")
const UiSettings := preload("res://scripts/ui/ui_settings.gd")
const PLANNER_UI := preload("res://scripts/ui/factorio/planner_ui.gd")
const PlannerSlot := preload("res://scripts/ui/factorio/planner_slot.gd")
const GhostShader := preload("res://shaders/ghost.gdshader")
const Controls := preload("res://scripts/player/controls.gd")
const ControlsInfo := preload("res://scripts/menu/controls_info.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const SettingsWindow := preload("res://scripts/menu/settings_window.gd")
const ModelPacksWindow := preload("res://scripts/menu/model_packs_window.gd")
const LooksScript := preload("res://scripts/world/looks.gd")
const FxSettings := preload("res://scripts/fx/fx_settings.gd")
const FxScript := preload("res://scripts/fx/fx.gd")
const ColorFilter := preload("res://scripts/menu/color_filter.gd")
const PlayerInput := preload("res://scripts/player/player_input.gd")
const DragBuildScript := preload("res://scripts/player/drag_build.gd")
const PoleCoverageScript := preload("res://scripts/player/pole_coverage.gd")
const GroundItemsScript := preload("res://scripts/world/ground_items.gd")
const BeltLanesScript := preload("res://scripts/world/belt_lanes.gd")
const QualityMarksScript := preload("res://scripts/world/quality_marks.gd")
const AlertIconsScript := preload("res://scripts/ui/factorio/alert_icons.gd")
const EntityInfoScript := preload("res://scripts/ui/factorio/entity_info.gd")
const FluidsPowerScript := preload("res://scripts/world/fluids_power.gd")
const InterfaceStateScript := preload("res://scripts/ui/interface_state.gd")
const RoboportLinksScript := preload("res://scripts/world/roboport_links.gd")
const BeltItemsScript := preload("res://scripts/world/belt_items.gd")
const PickUpScript := preload("res://scripts/world/pick_up.gd")
const BeltSimScript := preload("res://scripts/world/belt_sim.gd")
const BeltSimTwins := preload("res://tests/belt_sim_native_test.gd")
const BeltRecordsScript := preload("res://scripts/world/belt_records.gd")
const BeltLatticeScript := preload("res://scripts/world/belt_lattice.gd")
const MapGen := preload("res://scripts/menu/map_gen.gd")
const MapGeneratorWindow := preload("res://scripts/menu/map_generator_window.gd")
const ModsWindow := preload("res://scripts/menu/mods_window.gd")
const ModChoices := preload("res://scripts/menu/mod_choices.gd")
const FrontEndScript := preload("res://scripts/menu/front_end.gd")
const BackdropRecorderScript := preload("res://scripts/menu/backdrop_recorder.gd")
const MenuBackgroundScript := preload("res://scripts/menu/menu_background.gd")
const BackdropListScript := preload("res://scripts/menu/backdrop_list.gd")
## The mock's recording, the menu's default before 0.2.2 (tools/record_menu_world.py): the backdrop tests' messages.
const ModelPacksScript := preload("res://scripts/world/model_packs.gd")
const PerfTestScript := preload("res://scripts/menu/perf_test.gd")
const BugReport := preload("res://scripts/menu/bug_report.gd")
const CreatureModels := preload("res://scripts/world/creature_models.gd")
const Paths := preload("res://scripts/menu/paths.gd")
const Saves := preload("res://scripts/menu/saves.gd")
const ServerLauncher := preload("res://scripts/menu/server_launcher.gd")
const WorldMirror := preload("res://scripts/world/world.gd")
const RenderDistance := preload("res://scripts/world/render_distance.gd")
const UpdateOverlayScript := preload("res://scripts/debug/update_overlay.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")
const Probing := preload("res://scripts/debug/probing.gd")
const Predicted := preload("res://scripts/world/predicted.gd")
const AnimScript := preload("res://scripts/world/anim.gd")
const MoverLayer := preload("res://scripts/world/movers.gd")
const RemoteFog := preload("res://scripts/world/remote_fog.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const PipeCovers := preload("res://scripts/world/pipe_covers.gd")
const PipeInsides := preload("res://scripts/world/pipe_insides.gd")
const TurretLayer := preload("res://scripts/world/turrets.gd")
const CollectorLayer := preload("res://scripts/world/collectors.gd")
const CursorOverlay := preload("res://scripts/player/cursor_overlay.gd")
const UndergroundPairs := preload("res://scripts/world/underground_pairs.gd")
const VisualTurns := preload("res://scripts/world/visual_turns.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const PlayerTags := preload("res://scripts/world/player_tags.gd")
const BpString := preload("res://scripts/ui/factorio/bp_string.gd")
const BpLibrary := preload("res://scripts/ui/factorio/bp_library.gd")
const ConsoleCommands := preload("res://scripts/ui/factorio/console_commands.gd")
const Slot := preload("res://scripts/ui/factorio/slot.gd")
const SideMenu := preload("res://scripts/ui/factorio/side_menu.gd")
const CraftingPanel := preload("res://scripts/ui/factorio/crafting_panel.gd")
const ResearchWindow := preload("res://scripts/ui/factorio/research_window.gd")
## A blueprint Factorio 2.1.23 exported (LuaItemStack.export_stack): three belts, an inserter, an
## iron chest and two stone path tiles, labelled "Belt to chest" with two icons and a description.
const WireTool := preload("res://scripts/player/wire_tool.gd")
const WireLayerScript := preload("res://scripts/world/wires.gd")
const CircuitPanel := preload("res://scripts/ui/factorio/circuit_panel.gd")
const TileBrush := preload("res://scripts/player/tile_brush.gd")
const RailPlanner := preload("res://scripts/player/rail_planner.gd")
const RichText := preload("res://scripts/ui/factorio/rich_text.gd")
const GuiAssets := preload("res://scripts/ui/factorio/gui_assets.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const ModGraphics := preload("res://scripts/world/mod_graphics.gd")
const FarChunks := preload("res://scripts/world/far_chunks.gd")
const TerrainTextures := preload("res://scripts/world/terrain_textures.gd")
const AltOverlay := preload("res://scripts/ui/factorio/alt_overlay.gd")
const AltArrowsScript := preload("res://scripts/world/alt_arrows.gd")
const DecorativeLayer := preload("res://scripts/world/decoratives.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const BeltLods := preload("res://scripts/world/belt_lods.gd")
const ItemCardsScript := preload("res://scripts/world/item_cards.gd")
const SunShadows := preload("res://scripts/world/sun_shadows.gd")
const StutterProbeScript := preload("res://scripts/debug/stutter_probe.gd")
const PlanetSky := preload("res://scripts/world/sky.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const CharacterAnimScript := preload("res://scripts/player/character_anim.gd")
const CharacterPoseScript := preload("res://scripts/player/character_pose.gd")
const Avatar := preload("res://scripts/player/avatar.gd")
const Creatures := preload("res://scripts/world/creatures.gd")
const CameraRig := preload("res://scripts/player/camera_rig.gd")
const CursorStack := preload("res://scripts/ui/factorio/cursor_stack.gd")
const FactorioUi := preload("res://scripts/ui/factorio/factorio_ui.gd")
const ViewPriority := preload("res://scripts/world/view_priority.gd")
const AddonHostScript := preload("res://scripts/addons/addon_host.gd")
const MapCache := preload("res://scripts/ui/factorio/map_cache.gd")
const PediaCache := preload("res://scripts/ui/factorio/pedia_cache.gd")
const UpsGovernor := preload("res://scripts/world/ups_governor.gd")
const PerfLog := preload("res://scripts/world/perf_log.gd")
const PerfWarningScript := preload("res://scripts/ui/factorio/perf_warning.gd")
const TerritoryLayer := preload("res://scripts/world/territories.gd")
const DemolisherLayer := preload("res://scripts/world/demolishers.gd")
const VehicleAnim := preload("res://scripts/world/vehicle_anim.gd")
const MapLayersScript := preload("res://scripts/ui/factorio/map_layers.gd")
const PlatformPanel := preload("res://scripts/ui/factorio/platform_panel.gd")
const RocketsScript := preload("res://scripts/world/rockets.gd")
const Ride := preload("res://scripts/world/ride.gd")
const SpriteFx := preload("res://scripts/fx/sprite_fx.gd")
const WeaponFx := preload("res://scripts/fx/weapon_fx.gd")
const SoundBank := preload("res://scripts/fx/sound_bank.gd")
const DistantHorizon := preload("res://scripts/world/distant_horizon.gd")
const FullDetail := preload("res://scripts/world/full_detail.gd")
const TestEnv := preload("res://tests/test_env.gd")
const BeltBlur := preload("res://scripts/world/belt_blur.gd")
const LodDump := preload("res://scripts/debug/lod_dump.gd")
## What a section needs another to have run first (`--only`). _info fills the inventory with
## hud.set_inventory, ignored since the set-up's `slots`, until _hud goes back to the old message.
const MOCK_MENU_WORLD := "res://tests/data/mock_menu_world.json"
const FACTORIO_STRING := "0eNqVkt1ugzAMhV8l8nU6DQpT4XLPsLtpmgJYIxI4KHGnVYh3nwnrVtF2aq/yd/Qdx8cjVN0eB2+JoRyhwVB7O7B1BCW8tB5RVdhxUGgCK1E5ZUhZ70jVLQbW8UgBPaOXfaOMCuwI1WC4BQ22dhSgfB0h2A8y3exCpkfBszcUBud5M1vAJGJq8AvKZNIX5LPpJpqeSNPpTQMSW7a42MTD4Z32fYVeWPqKnYbBBbv8dARBPT7kGg5xFX5jPdbLazaXs8KmN2OTe7Dbm7HpPdjsF3uM6hy4vQZM0gvEXF+I5YyZnTDnoNh2Pymtex9lkvuRGmdoE2dodl/39D+5+FjGXm7/RltDZ6SPcvcs3VQyxceKP9GHCM6f0iLP0qzYFXmx3U3TN938Bso="
const TEST_SETTINGS := "user://ui-test-settings.cfg"

static var fails: int = 0
static var passes: int = 0
static var _failed: PackedStringArray = []
static var _controls_before: Array = []
static var _pr_linear: PackedFloat32Array = PackedFloat32Array()
static var _saved_packs: Array = []

class ChunkModel:
	signal asteroid_chunks_changed
	signal rocket_launched
	var asteroid_chunks: Array = []
	var asteroid_chunks_msec := 0

	func set_chunks(list: Array) -> void:
		asteroid_chunks = list
		asteroid_chunks_msec = Time.get_ticks_msec()
		asteroid_chunks_changed.emit()


## The little of world.gd that WeaponFx._stream_shooter reads: one chunk holding one worm.


class SiloWorld extends Node:
	var silo := false
	var working := {}

	func has_near(_type: String, _at: Vector2, _radius: float) -> bool:
		return silo

	func unit_near(_type: String, _at: Vector2, _radius: float) -> int:
		return 77 if silo else 0


## The little of movers.gd that rockets.gd's rockets read.


class SiloMovers:
	var world
	var nodes := {}
	var fogged := false

	func units_of_type(type: String) -> Array:
		var out: Array = []
		if type == "rocket-silo-rocket":
			for unit in nodes:
				out.append([unit, nodes[unit]])
		return out

	func is_fogged(_unit: int) -> bool:
		return fogged


## The little of camera_rig.gd that ride.gd moves.


func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails += 1
		_failed.append(what)


func key(code: Key, shift := false, ctrl := false) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.shift_pressed = shift
	ev.ctrl_pressed = ctrl
	ev.pressed = true
	get_viewport().push_input(ev)


## Has the Bridge keep what it sends, so sent commands can be checked and nothing goes to a real
## game. (Not through a socket: under load a loopback datagram can land after a check has looked.)


func _catch_commands() -> void:
	Bridge.capture = []
	Bridge.bind_error = OK


## The commands sent since the last call (keep-alives left out).


func sent() -> Array:
	var out: Array = []
	for text in Bridge.capture:
		var msg = JSON.parse_string(text)
		if msg is Dictionary and msg.get("t", "") != "hello":
			out.append(msg)
	Bridge.capture.clear()
	return out


## The first sent command of type `t`, or {}.


func sent_one(t: String) -> Dictionary:
	for msg in sent():
		if msg.get("t", "") == t:
			return msg
	return {}


func click_main(ui, index: int, button := MOUSE_BUTTON_LEFT, shift := false, ctrl := false) -> void:
	ui.window.slot_clicked.emit("main", index, button, shift, ctrl)


func _texts(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is Label:
			out.append((child as Label).text)
		elif child is RichTextLabel:
			out.append((child as RichTextLabel).get_parsed_text())
		elif child is Button and (child as Button).text != "":
			out.append((child as Button).text)
		out.append_array(_texts(child))
	return out


func _find_button(node: Node, text: String) -> Button:
	for child in node.get_children():
		if child is Button and (child as Button).text == text and not child.is_queued_for_deletion():
			return child
		var b := _find_button(child, text)
		if b != null:
			return b
	return null


func _find_checkbox(node: Node, text: String) -> CheckBox:
	for child in node.get_children():
		if child is CheckBox and (child as CheckBox).text == text and not child.is_queued_for_deletion():
			return child
		var c := _find_checkbox(child, text)
		if c != null:
			return c
	return null


## Every label's text under a node, at any depth.


func _find_slot_tip(node: Node, title: String) -> Node:
	for child in node.get_children():
		if child.get("tip_title") == title and not child.is_queued_for_deletion():
			return child
		var found := _find_slot_tip(child, title)
		if found != null:
			return found
	return null


## Slots named <prefix><n> under a node, in order.


func _all_buttons(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is Button and not child.is_queued_for_deletion():
			out.append(child)
		out.append_array(_all_buttons(child))
	return out


## The second pass on those windows: tanks, spidertrons and their remote, artillery, pipes and
## tanks' pipelines, heat pipes, decider conditions that hold, the signal-or-constant operand,
## train groups and the train camera's remote view, what opens a window.


func _bs_lane(key: int, kind: int, length: int, step: int, ex: float, ey: float, nx: float, ny: float,
		mx := INF, my := INF, nxt := 0) -> Array:
	var cx := (ex + nx) / 2.0 if mx == INF else mx
	var cy := (ey + ny) / 2.0 if my == INF else my
	return [key, kind, length, step, roundi(ex * 256), roundi(ey * 256), roundi(cx * 256), roundi(cy * 256),
		roundi(nx * 256), roundi(ny * 256), 0, nxt]


## Feeds a belt layer a `bs` update at tick k and runs `frames` frames of 1/60 s (a tick each).


func _bs_feed(layer, k: int, extra: Dictionary, frames := 1) -> void:
	var m := {"t": "bs", "k": k, "p": 6, "w": 100, "fx": 0, "fy": 10 * 256, "fr": 40}
	m.merge(extra, true)
	layer.handle(m)
	for f in frames:
		layer._process(1.0 / 60.0)


## The owner: "holding Z on a belt to place items takes a while to show up; it needs to be shown instantly". Z over a
## belt shows the item at once (--belt-drop-show-now): standing where it lands on the nearest lane drawn, ahead of the
## drawn clock, until that clock reaches the tick of the bridge's put (`ie` kind 6 with no inserter, drop_put); the
## simulated item shows from that tick at the same place, and the shown one goes then: one item, never two, no gap.
## One the bridge never confirms goes after DROP_SHOW_MSEC; off a belt, or with the switch off, nothing is shown.
## belt_sim.gd and its C++ twin alike.


static func _own_glb(name: String) -> String:
	var wube := "res://assets/models/packs/wube3dp/%s.glb" % name
	return wube if FileAccess.file_exists(wube) else "res://assets/models/packs/placeholders/%s.glb" % name


## The project's own models of `names` (_own_glb) in place of the ones another project's replace
## them with in play, whose moving parts differ, so checks of our parts still run; _restore_models()
## puts the others back.


func _theirs_in_use(model: String) -> bool:
	var src := ModelLibrary._source(model)
	return src != "" and not (src.contains("/assets/models/packs/wube3dp/") or src.contains("/assets/models/packs/placeholders/"))


## The project's own model of `name`: its .glb in the Wube3DP pack or Placeholders (they never share a name).


func _ours(names: Array) -> void:
	for n: String in names:
		ModelLibrary.mesh_for(n)  # finishes a worker's job still reading the other file
		ModelLibrary._sources[n] = ModelLibrary.GLTF_SOURCE + _own_glb(n)
		ModelLibrary._cache.erase(n)
		ModelLibrary._parts.erase(n)


func _restore_models(names: Array) -> void:
	for n: String in names:
		ModelLibrary._sources.erase(n)
		ModelLibrary._cache.erase(n)
		ModelLibrary._parts.erase(n)


func _anim_group(part: ModelLibrary.AnimPart, unit: int, base: Transform3D, mesh: Mesh = null) -> AnimScript.Group:
	var group := AnimScript.Group.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = part.mesh if part != null else mesh
	mm.instance_count = 1
	mm.set_instance_transform(0, base)
	group.mm = mm
	group.part = part
	group.keys.append(unit)
	group.units.append(unit)
	group.bases.append(Transform3D(Basis(), base.origin) if part != null and part.upright else base)
	group.stateful.append(1)
	group.customs.append(Color(base.origin.x, base.origin.z, 0.0, 1.0))
	return group


## Where the model shader draws vertex v of a timed part (factorio_material.gdshaderinc
## anim_vertex, the same sums), in model space.


func _part_of(model: String, kind: String) -> ModelLibrary.AnimPart:
	for p: ModelLibrary.AnimPart in ModelLibrary.parts_for(model):
		if p.kind == kind:
			return p
	return null


## True when `model` is drawn with another project's model (the FUE5 pack's, a pack of the models
## folder's) in place of ours (Wube3DP's or Placeholders').


static func _box_glb(path: String, size: Vector3) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.position.y = size.y * 0.5
	mi.name = "Box"
	root.add_child(mi)
	mi.owner = root
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	doc.append_from_scene(root, state)
	doc.write_to_filesystem(state, path)
	root.free()


## Fixture packs in their own folder (`packs`: folder -> {model name: box size}, "pack.json" text too), put on
## top in `order`; the packs as they were come back with _fixture_packs_done().


func _fixture_packs(name: String, packs: Dictionary, order: Array) -> String:
	var dir := OS.get_user_data_dir().path_join(name)
	for folder: String in packs:
		var models: Dictionary = packs[folder]
		for model: String in models:
			if model == "pack.json":
				DirAccess.make_dir_recursive_absolute(dir.path_join(folder))
				var f := FileAccess.open(dir.path_join(folder).path_join("pack.json"), FileAccess.WRITE)
				f.store_string(str(models[model]))
				f.close()
			else:
				_box_glb(dir.path_join(folder).path_join(model + ".glb"), models[model])
	_saved_packs = ModelLibrary.ModelPacks.packs
	ModelLibrary.ModelPacks.configure(dir, order, [])
	ModelLibrary.ModelPacks.wait()
	ModelLibrary.choices_changed([])
	return dir


func _fixture_packs_done() -> void:
	ModelLibrary.ModelPacks.use(_saved_packs)
	ModelLibrary.choices_changed([])


## Makes every model a chunk's records are drawn with now (a build otherwise waits for workers' loads).


static func _make_models(protos: ProtoDB, cv: ChunkView) -> void:
	for rec in cv.entities.values():
		var p: ProtoDB.EntityProto = protos.entity(rec.proto_id)
		for n: String in ModelLibrary.entity_models(p.name, p.type, rec.extra, rec.dir):
			ModelLibrary.mesh_for(n)
		var wet := ModelLibrary.wet_model(p.name, p.type, rec.extra, rec.dir)
		if wet != "":
			ModelLibrary.mesh_for(wet)


## Instances drawn per model in a chunk: Mesh -> its MultiMesh's transforms (the whole model's, not parts').


static func _drawn(cv: ChunkView) -> Dictionary:
	var out := {}
	for key in cv._nodes:
		if key is Mesh:
			var mm: MultiMesh = (cv._nodes[key] as MultiMeshInstance3D).multimesh
			var xf: Array = []
			for i in mm.instance_count:
				xf.append(mm.get_instance_transform(i))
			out[key] = xf
	return out


## Window pipes (Factorio's `straight_*_window` pictures): every second straight pipe, where the floored x plus the
## floored y is even (world.gd extra.pw), drawn with the pack's `-window` model when the pack drawing the pipe has it;
## never on a corner or a T; a pack without it draws its plain straight; `--pipe-windows=off` none.


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## The performance test in the main menu (perf_test.gd): the entry, the three modes with their
## times, the tests each mode runs with their settings, and the results file's sections, with a
## stand-in for perf_game.gd (no Factorio, no second Zenith).


func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for f in dir.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	for sub in dir.get_directories():
		_remove_tree(path.path_join(sub))
	DirAccess.remove_absolute(path)


## Issue #3: saves in folders, browsed as Factorio's load screen does; issue #6: the Factorio
## install set in Settings → Factorio is where the graphics come from, wherever it is.


func _govern(g, tick: Array, secs: float, ups) -> void:
	for i in int(secs * 10.0):
		var u: float = ups.call(g.level) if ups is Callable else float(ups)
		tick[0] += u * 0.1
		g.feed(int(tick[0]), 0.1)


func _find_recipe_slot(ui, recipe: String) -> Node:
	var stack: Array = [ui.window]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.has_meta("recipe") and str(n.get_meta("recipe")) == recipe and not n.is_queued_for_deletion():
			return n
		stack.append_array(n.get_children())
	return null
