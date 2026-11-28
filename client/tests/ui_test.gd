extends "res://tests/ui_test_base.gd"
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


const UiTestBase := preload("res://tests/ui_test_base.gd")
const AreaBackdrop := preload("res://tests/ui_area_backdrop.gd")
const AreaBelts := preload("res://tests/ui_area_belts.gd")
const AreaBuild := preload("res://tests/ui_area_build.gd")
const AreaCombatDebug := preload("res://tests/ui_area_combat_debug.gd")
const AreaHud := preload("res://tests/ui_area_hud.gd")
const AreaIcons := preload("res://tests/ui_area_icons.gd")
const AreaLighting := preload("res://tests/ui_area_lighting.gd")
const AreaMapMenus := preload("res://tests/ui_area_map_menus.gd")
const AreaPacks := preload("res://tests/ui_area_packs.gd")
const AreaParity := preload("res://tests/ui_area_parity.gd")
const AreaPbrLooks := preload("res://tests/ui_area_pbr_looks.gd")
const AreaPerfLod := preload("res://tests/ui_area_perf_lod.gd")
const AreaPipesOres := preload("res://tests/ui_area_pipes_ores.gd")
const AreaPlay := preload("res://tests/ui_area_play.gd")
const AreaStreaming := preload("res://tests/ui_area_streaming.gd")
const AreaWorldAnim := preload("res://tests/ui_area_world_anim.gd")

## What a section needs another to have run first (`--only`). _info fills the inventory with
## hud.set_inventory, ignored since the set-up's `slots`, until _hud goes back to the old message.
const NEEDS := {"_info": ["_hud"]}
const SECTION_ORDER: PackedStringArray = [
	"_map",
	"_map_layers_cache",
	"_minimap_alerts",
	"_play",
	"_parity",
	"_hud",
	"_info",
	"_gear",
	"_planners",
	"_space",
	"_modded_planets",
	"_world_marks",
	"_oil_and_pipelines",
	"_pipeline_vis",
	"_pipeline_vis_edges",
	"_predictions",
	"_underground_clear",
	"_build_spend",
	"_turned_previews",
	"_pipe_fluid_icons",
	"_stop_labels",
	"_pipe_end",
	"_pipe_end_edges",
	"_pipe_windows",
	"_ore_scatter",
	"_drill_wet",
	"_pipe_covers",
	"_ore_pipe_edges",
	"_craft_pie",
	"_craft_predicted",
	"_train_loading",
	"_total_raw",
	"_mod_windows",
	"_window_bounds",
	"_wires",
	"_logistics_parity",
	"_build_tools",
	"_wall_drag",
	"_blueprint_preview",
	"_repair_pack",
	"_menus",
	"_menu_backdrop",
	"_menu_backdrop_cases",
	"_menu_backdrop_list",
	"_menu_backdrop_ground",
	"_load_mods",
	"_antialiasing_look",
	"_texture_metal_look",
	"_pack_shading_look",
	"_pbr_look",
	"_pbr_reference",
	"_pbr_light",
	"_light_env_window",
	"_perf_test",
	"_layout",
	"_map_title",
	"_help",
	"_icons",
	"_alt_sequences",
	"_alt_stock",
	"_alt_icon_order",
	"_alt_icon_order_kept",
	"_alt_robot_items",
	"_turrets",
	"_turrets_far",
	"_turret_lights",
	"_collectors",
	"_asteroid_chunks",
	"_rocket_launch_vfx",
	"_ride_before_silo",
	"_belt_end_rules",
	"_belt_line_ends",
	"_fx_movers",
	"_lightning",
	"_weapons",
	"_flame_streams",
	"_acid_aim",
	"_console",
	"_debug_menu",
	"_health_bars",
	"_debug_menu_over_camera",
	"_debug_sim_switches",
	"_debug_light_sliders",
	"_debug_live_sliders",
	"_dev_tools",
	"_update_overlays",
	"_view_priority",
	"_performance",
	"_resolution_scaling",
	"_streaming",
	"_frame_budget",
	"_shot_release",
	"_hotfix_021",
	"_pipeline_warm",
	"_bridge_parsing",
	"_bridge_relay",
	"_working_near",
	"_stream_spread",
	"_far_chunks",
	"_distant_horizon_integration",
	"_belt_stand_ins",
	"_belt_stand_ins_at_4k",
	"_belt_item_shadows",
	"_lod_lines",
	"_belts_always_run",
	"_belt_blur",
	"_ups_governor",
	"_budget_fast",
	"_perf_warning",
	"_terrain",
	"_hill_culling",
	"_lamps",
	"_signal_lights",
	"_states_sliced",
	"_ih_quick",
	"_hill_lights",
	"_vehicle_lights",
	"_binary_movers",
	"_robot_sim",
	"_binary_belts",
	"_binary_world",
	"_camera_focus",
	"_f6_projection",
	"_contact_shade",
	"_contact_drills",
	"_contact_chunk",
	"_contact_mask",
	"_ao_zoom",
	"_post_hotfix",
	"_surface_change",
	"_gpu_anim",
	"_gate_open",
	"_creature_motion",
	"_space_creatures",
	"_tree_crowns",
	"_belt_sim",
	"_belt_self_side",
	"_belt_unison",
	"_belt_lattice_turns",
	"_ninth_list",
	"_mining_feedback",
	"_mine_reach",
	"_mine_reach_more",
	"_research_done",
	"_research_open_queue",
	"_first_person_aim",
	"_center_aim",
	"_pick_up",
	"_belt_take",
	"_belt_drop_show",
	"_belt_line_end",
	"_belt_early_stop",
	"_belt_step_creep",
	"_belt_lattice_mask_join",
	"_belt_lattice_open",
	"_belt_lattice_handover",
	"_belt_perf_upgrades",
	"_track2a_cpu_opts",
	"_track2b_streaming_and_prep",
	"_track3_gpu_opts",
	"_belt_lattice_tail",
	"_belt_turn_id",
	"_belt_item_variants",
	"_belt_lane_inset_far",
	"_quickbar_hand",
	"_cursor_count",
	"_hand_stack",
	"_hand_stack_more",
	"_belt_removed",
	"_twelfth_list",
	"_model_packs_window",
	"_vehicle_guns",
	"_belt_preview_ends",
	"_model_chooser",
	"_entity_info_pack",
	"_entity_info_pack_edges",
	"_hover_run_rate",
	"_esc_tooltip",
	"_picture",
]

var _section_owner: Dictionary = {}
var _section_args: Dictionary = {}


func _init_areas() -> Dictionary:
	var base_script: Script = UiTestBase
	var base_methods := {}
	for m: Dictionary in base_script.get_script_method_list():
		base_methods[str(m["name"])] = true
	var by_name := {}
	var area_backdrop: Node = AreaBackdrop.new()
	area_backdrop.name = "AreaBackdrop"
	add_child(area_backdrop)
	by_name["backdrop"] = area_backdrop
	var area_belts: Node = AreaBelts.new()
	area_belts.name = "AreaBelts"
	add_child(area_belts)
	by_name["belts"] = area_belts
	var area_build: Node = AreaBuild.new()
	area_build.name = "AreaBuild"
	add_child(area_build)
	by_name["build"] = area_build
	var area_combat_debug: Node = AreaCombatDebug.new()
	area_combat_debug.name = "AreaCombatDebug"
	add_child(area_combat_debug)
	by_name["combat_debug"] = area_combat_debug
	var area_hud: Node = AreaHud.new()
	area_hud.name = "AreaHud"
	add_child(area_hud)
	by_name["hud"] = area_hud
	var area_icons: Node = AreaIcons.new()
	area_icons.name = "AreaIcons"
	add_child(area_icons)
	by_name["icons"] = area_icons
	var area_lighting: Node = AreaLighting.new()
	area_lighting.name = "AreaLighting"
	add_child(area_lighting)
	by_name["lighting"] = area_lighting
	var area_map_menus: Node = AreaMapMenus.new()
	area_map_menus.name = "AreaMapMenus"
	add_child(area_map_menus)
	by_name["map_menus"] = area_map_menus
	var area_packs: Node = AreaPacks.new()
	area_packs.name = "AreaPacks"
	add_child(area_packs)
	by_name["packs"] = area_packs
	var area_parity: Node = AreaParity.new()
	area_parity.name = "AreaParity"
	add_child(area_parity)
	by_name["parity"] = area_parity
	var area_pbr_looks: Node = AreaPbrLooks.new()
	area_pbr_looks.name = "AreaPbrLooks"
	add_child(area_pbr_looks)
	by_name["pbr_looks"] = area_pbr_looks
	var area_perf_lod: Node = AreaPerfLod.new()
	area_perf_lod.name = "AreaPerfLod"
	add_child(area_perf_lod)
	by_name["perf_lod"] = area_perf_lod
	var area_pipes_ores: Node = AreaPipesOres.new()
	area_pipes_ores.name = "AreaPipesOres"
	add_child(area_pipes_ores)
	by_name["pipes_ores"] = area_pipes_ores
	var area_play: Node = AreaPlay.new()
	area_play.name = "AreaPlay"
	add_child(area_play)
	by_name["play"] = area_play
	var area_streaming: Node = AreaStreaming.new()
	area_streaming.name = "AreaStreaming"
	add_child(area_streaming)
	by_name["streaming"] = area_streaming
	var area_world_anim: Node = AreaWorldAnim.new()
	area_world_anim.name = "AreaWorldAnim"
	add_child(area_world_anim)
	by_name["world_anim"] = area_world_anim
	_section_owner.clear()
	_section_args.clear()
	for area_name: String in by_name:
		var node: Node = by_name[area_name]
		var scr: Script = node.get_script()
		for m: Dictionary in scr.get_script_method_list():
			var mname: String = str(m["name"])
			if base_methods.has(mname):
				continue
			check(not _section_owner.has(mname), "unique section/helper name across areas: %s" % mname)
			_section_owner[mname] = node
			var arg_names: Array = []
			for a: Dictionary in m["args"]:
				arg_names.append(str(a["name"]))
			_section_args[mname] = arg_names
	var seen_order := {}
	for s: String in SECTION_ORDER:
		check(not seen_order.has(s), "unique section in SECTION_ORDER: %s" % s)
		seen_order[s] = true
		check(_section_owner.has(s), "section exists on an area node: %s" % s)
	return by_name


func _exit_tree() -> void:
	for what in _failed:
		print("FAILED: " + what)
	ModelLibrary.NatureLooks.finish_all()
	ModelLods.finish_all()
	BeltLods.finish_all()
	TerrainTextures.finish_all()
	ModelLibrary.ModelPacks.wait()
	TestEnv.clean()



## Sections run one after another in one tree: one that leaves a control of its own bound broke a
## later one (_parity's test binding made _help fail on 0.1.3's and 0.2.0's CI). Checked at the end of
## the whole run and of each --only run, so the section that leaves one is found running it alone.
func _nothing_left_behind() -> void:
	# Zenith's own controls (the Controls tab's list) may be defined on the way; anything else is a test's.
	var stray := func(a) -> bool:
		return not _controls_before.has(a) and not ControlsInfo.ACTIONS.has(a)
	var left: Array = Settings.bindable_actions().filter(stray)
	check(left.is_empty(), "no section leaves a control of its own bound (left: %s)" % [left])



## The sections `--only=` asks for, or none.
func _only_sections() -> PackedStringArray:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			return arg.get_slice("=", 1).split(",", false)
	return PackedStringArray()



## Runs the sections named instead of them all, each with what _ready would pass it, by the names
## of its arguments: the list of sections in _ready stays the only one.
func _run_only(names: PackedStringArray, values: Dictionary) -> void:
	# Several sections press keys or read their bindings; the sections defining them may not run.
	PlayerInput.define_actions()
	Settings.apply_bindings()
	var order: Array[String] = []
	for section: String in names:
		for needed: String in NEEDS.get(section, []):
			if not order.has(needed):
				order.append(needed)
		if not order.has(section):
			order.append(section)
	for section: String in order:
		var owner_node: Node = _section_owner.get(section)
		var arg_names: Array = _section_args.get(section, [])
		var has_args := true
		for a: String in arg_names:
			if not values.has(a):
				has_args = false
				break
		var known: bool = owner_node != null and has_args
		check(known, "--only: %s is a section of this test" % section)
		if known:
			print("--- " + section)
			var call_args: Array = []
			for a: String in arg_names:
				call_args.append(values[a])
			await owner_node.callv(section, call_args)
	_nothing_left_behind()
	print("FAILS: %d" % fails)
	get_tree().quit(1 if fails else 0)


func _ready() -> void:
	fails = 0
	passes = 0
	_failed.clear()
	var _areas := _init_areas()
	var area_backdrop: Node = _areas["backdrop"]
	var area_belts: Node = _areas["belts"]
	var area_build: Node = _areas["build"]
	var area_combat_debug: Node = _areas["combat_debug"]
	var area_hud: Node = _areas["hud"]
	var area_icons: Node = _areas["icons"]
	var area_lighting: Node = _areas["lighting"]
	var area_map_menus: Node = _areas["map_menus"]
	var area_packs: Node = _areas["packs"]
	var area_parity: Node = _areas["parity"]
	var area_pbr_looks: Node = _areas["pbr_looks"]
	var area_perf_lod: Node = _areas["perf_lod"]
	var area_pipes_ores: Node = _areas["pipes_ores"]
	var area_play: Node = _areas["play"]
	var area_streaming: Node = _areas["streaming"]
	var area_world_anim: Node = _areas["world_anim"]
	TestEnv.isolate("ui-test")
	_catch_commands()
	UiModel.save_path = "user://quickbar-test.cfg"  # leave the player's own pins alone
	# and every other setting: a file of the test's own, without the player's old ui.cfg / audio.cfg
	Settings.legacy = {}
	DirAccess.remove_absolute(TEST_SETTINGS)
	Settings.use_file(TEST_SETTINGS)
	# The player's own Factorio controls (config.ini) mustn't change the keys the test presses.
	Settings.set_value("factorio", "use_factorio_keys", false)
	FxSettings.load_settings()
	var gs := GDScript.new()
	gs.source_code = "extends Node\nvar cursor_item := \"\"\nvar cursor_slot := 0\nvar remembered: Array = []\nfunc hold(i: String, slot := 0) -> void:\n\tcursor_item = i\n\tcursor_slot = slot\nfunc remember_mod(h: int, what: String) -> void:\n\tremembered.append([h, what])\nvar cursor_tool := \"\"\nvar reselect_slot := 0\nfunc hold_tool(t: String) -> void:\n\tcursor_tool = t\nvar _undo: Array = []\nvar _redo: Array = []\n"
	gs.reload()
	var player: Node = gs.new()
	add_child(player)
	var hud: Hud = Hud.new()
	add_child(hud)
	await get_tree().process_frame
	var ui = hud.ui
	ui.player = player
	ui.auto_sort = false  # J12's `sort`s would land among the commands the sections count (_ninth_list turns it on)
	ui.auto_sort_containers = false
	hud.set_inventory([["iron-plate", 60], ["transport-belt", 50]])
	hud.set_recipes(["iron-gear-wheel", "transport-belt"])
	check(hud.count_of("iron-plate") == 60, "count_of")
	check(ui.model.main_slots.size() == 80, "80 slots")
	for i in 10:
		ui.model.unpin(i)
	ui.toggle_inventory()
	check(ui.is_open(), "E opens the window")
	ui.window.slot_clicked.emit("main", 2, MOUSE_BUTTON_LEFT, false, false)
	check(player.cursor_item == "transport-belt", "inventory click picks up the stack")
	player.cursor_item = "transport-belt"
	key(KEY_3)
	await get_tree().process_frame
	check(ui.model.quickbar[2] == "" and player.cursor_item == "transport-belt",
		"K18: a number key on an empty slot doesn't pin the held item (in Factorio only a click does)")
	ui._on_quickbar_clicked(2, MOUSE_BUTTON_LEFT)
	check(ui.model.quickbar[2] == "transport-belt" and player.cursor_item == "transport-belt", "a click on an empty slot pins the held item")
	ui.window.hovered_item = "iron-plate"
	key(KEY_0)
	await get_tree().process_frame
	check(ui.model.quickbar[9] == "iron-plate", "number key pins the hovered item")
	ui.window.hovered_item = ""
	key(KEY_ESCAPE)
	await get_tree().process_frame
	check(not ui.is_open(), "Esc closes the window")
	player.cursor_item = ""
	key(KEY_3)
	await get_tree().process_frame
	check(player.cursor_item == "transport-belt", "number key holds the pinned item")
	key(KEY_3)
	await get_tree().process_frame
	check(player.cursor_item == "", "again puts it away")
	ui._on_quickbar_clicked(4, MOUSE_BUTTON_LEFT)
	check(ui.model.quickbar[4] == "", "click on an empty slot with nothing held does nothing")
	player.cursor_item = "iron-plate"
	ui._on_quickbar_clicked(4, MOUSE_BUTTON_LEFT)
	check(ui.model.quickbar[4] == "iron-plate" and ui.model.quickbar[9] == "", "click pins the held item (moving it)")
	ui._on_quickbar_clicked(4, MOUSE_BUTTON_RIGHT)
	check(ui.model.quickbar[4] == "", "right click clears")
	ui.quickbar._slots[1].on_drop.call("iron-plate")
	check(ui.model.quickbar[1] == "iron-plate", "drop pins")
	await get_tree().process_frame
	check(ui.quickbar._slots[1].count == 60, "quickbar shows the count")
	hud.set_inventory([["transport-belt", 50]])
	await get_tree().process_frame
	check(ui.quickbar._slots[1].ghost, "quickbar slot fades when none are left")
	key(KEY_F4)
	await get_tree().process_frame
	check(ui.debug_overlay, "F4 toggles the debug overlay")
	ui.model.set_recipe_details([{"name": "iron-gear-wheel", "group": "intermediate-products", "ingredients": [["iron-plate", 2]]},
		{"name": "transport-belt", "group": "logistics", "ingredients": [["transport-belt", 1]]}], ["logistics", "intermediate-products"])
	check(ui.model.groups == ["logistics", "intermediate-products"], "groups from details")
	check(ui.model.recipe("iron-gear-wheel")["craftable"] == 0, "craftable from ingredients")
	check(ui.model.recipe("transport-belt")["craftable"] == 50, "craftable count")
	hud.set_recipes(["iron-gear-wheel", "transport-belt"])
	check(ui.model.recipe("iron-gear-wheel")["group"] == "intermediate-products", "names-only update keeps details")
	ui.model.set_inventory_slots([["iron-plate", 100], [], ["iron-plate", 20]], 90)
	check(ui.model.main_slots.size() == 90 and ui.model.count_of("iron-plate") == 120 and ui.model.has_slots, "slot data")
	hud.set_inventory([["coal", 5]])
	check(ui.model.count_of("coal") == 0, "inv ignored once slots arrive")
	# The mod's UI data messages (docs/PROTOCOL.md, "Factorio's windows") reach the model's setters.
	var m = ui.model
	m.handle({"t": "slots", "l": {"main": [["wood", 3], 0], "guns": [["pistol", 1], 0, 0]}})
	check(m.main_slots.size() == 2 and m.count_of("wood") == 3 and m.other_slots["guns"][0]["item"] == "pistol", "slots message")
	m.handle({"t": "rdet", "part": 1, "parts": 1, "l": [["iron-gear-wheel", 0.5, ["crafting"], "intermediate-products", "c",
		"intermediate-product", "a", "a", [["item", "iron-plate", 2]], [["item", "iron-gear-wheel", 1]]]]})
	m.handle({"t": "craftable", "l": [["iron-gear-wheel", 7]]})
	var gear: Dictionary = m.recipe("iron-gear-wheel")
	check(gear.get("craftable") == 7 and gear.get("energy") == 0.5 and gear.get("ingredients") == [["iron-plate", 2.0]], "rdet and craftable messages")
	m.handle({"t": "cq", "pr": 500, "l": [[1, "iron-gear-wheel", 3, 0]]})
	check(m.craft_queue_size == 3 and m.craft_queue[0]["progress"] == 0.5 and m.craft_queue[0]["index"] == 1, "cq message")
	m.handle({"t": "techs", "part": 1, "parts": 1, "l": [["automation", "a", [], [["automation-science-pack", 1]], 10, 10, 1, ""]]})
	m.handle({"t": "rs", "cur": "automation", "pr": 250, "q": []})
	check(m.techs.has("automation") and m.research == "automation" and m.research_progress == 0.25, "techs and rs messages")
	m.handle({"t": "chart", "cx": 1, "cy": -2, "n": 2, "pal": [[10, 20, 30], [204, 217, 204]], "px": [0, 0, 1, 0]})
	m.handle({"t": "chart", "cx": 5, "cy": 0, "n": 0})
	var chart: Image = m.map_charts.get(Vector2i(1, -2))
	check(chart != null and chart.get_width() == 2 and chart.get_pixel(0, 1).to_rgba32() == Color8(204, 217, 204).to_rgba32()
		and m.map_charts.has(Vector2i(5, 0)) and m.map_charts[Vector2i(5, 0)] == null, "chart messages")
	m.handle({"t": "tags", "l": [[3, 1280, -512, "base", "item", "iron-plate"]]})
	check(m.map_tags.size() == 1 and m.map_tags[0]["position"] == Vector2(5, -2) and m.map_tags[0]["icon_name"] == "iron-plate", "tags message")
	var only := _only_sections()
	_controls_before = Settings.bindable_actions().duplicate()
	if not only.is_empty():
		await _run_only(only, {"hud": hud, "player": player, "ui": ui})
		return
	await area_map_menus._map(ui)
	await area_map_menus._map_layers_cache(ui)
	await area_map_menus._minimap_alerts(ui)
	m.handle({"t": "tr", "l": [[4, "wait_station", 0, -150, 900, "Iron", [700, 701]]]})
	check(m.trains.has(4) and m.trains[4]["speed"] == -0.15 and m.trains[4]["dest"] == "Iron" and m.train_of_unit.get(701) == 4, "tr message")
	m.handle({"t": "clog", "on": 0, "trash": 1, "l": [["iron-plate", 100, -1], ["wood", 5, 20, "rare"]]})
	check(m.char_requests.size() == 2 and m.char_requests[1]["quality"] == "rare" and m.char_requests[0]["max"] == -1
		and not m.char_requests_on and m.char_trash_unrequested, "clog message")
	check(m._request_list(m.char_requests) == [["iron-plate", 100, -1], ["wood", 5, 20, "rare"]], "requests go back on the wire as they came")
	m.handle({"t": "ln", "id": 3, "log": [1, 2], "con": [0, 4]})
	check(m.network.get("id") == 3 and m.network["construction"] == [0, 4], "ln message")
	m.handle({"t": "ln", "id": 0})
	m.handle({"t": "rc", "l": [800, 5, 4]})
	check(m.network.is_empty() and m.robot_cargo.get(800, {}).get("count") == 4, "ln outside a network, rc message")
	m.handle({"t": "planet", "name": "vulcanus", "props": {"gravity": 40}, "day": 5400, "always": 0, "mb": 200, "sol": 4000,
		"dusk": 250, "evening": 450, "morning": 550, "dawn": 750, "heat": [[12, 12.5]]})
	check(m.planet.get("name") == "vulcanus" and m.planet["solar"] == 4.0 and m.heating_radius.get(12) == 12.5, "planet message")
	m.handle({"t": "seg", "l": [[90, 7, [8, 512, 256, 250, 8, 1024, 256, 250]]]})
	check(m.demolishers.has(90) and m.demolishers[90]["segments"].size() == 2 and m.demolishers[90]["segments"][1]["position"] == Vector2(4, 1), "seg message")
	m.handle({"t": "pg", "l": [5, 256, 512, 500]})
	m.handle({"t": "legs", "l": [[6, [0, 0, 256, 256]]]})
	m.handle({"t": "fz", "l": [7]})
	m.handle({"t": "bf", "part": 1, "parts": 1, "l": [42, 750]})
	m.handle({"t": "cp", "l": [[9, "descending", "surface", "vulcanus", 10 * 256, 20 * 256]]})
	check(m.plant_growth.get(Vector2(1, 2)) == 0.5 and m.legs[6].size() == 2 and m.frozen.has(7) and m.belt_freshness[42] == 0.75
		and m.cargo_pods[9]["surface"] == "vulcanus" and m.cargo_pods[9]["to"] == Vector2(10, 20), "pg, legs, fz, bf and cp messages, a falling pod's landing spot too")
	check(m._slot_dicts([["yumako", 5, "normal", 640]])[0].get("freshness") == 0.64, "freshness in slots")
	var qb: Array = []
	qb.resize(100)
	qb.fill("")
	qb[12] = "iron-chest"
	m.handle({"t": "qb", "p": 2, "sel": 0, "held": "", "l": qb})
	check(m.server_quickbar and m.quickbar[2] == "iron-chest", "qb message shows its page")
	await area_play._play(hud, player)
	await area_parity._parity(hud, player)
	await area_hud._hud(hud, player)
	await area_hud._info(hud, player)
	await area_parity._gear(hud, player)
	await area_parity._planners(hud, player)
	await area_parity._space(hud, player)
	await area_parity._modded_planets(hud)
	await area_build._world_marks(hud)
	area_pipes_ores._oil_and_pipelines(hud)
	await area_pipes_ores._pipeline_vis(hud)
	await area_pipes_ores._pipeline_vis_edges()
	await area_build._predictions(hud)
	await area_build._underground_clear(hud)
	await area_build._build_spend(hud)
	await area_build._turned_previews(hud)
	area_pipes_ores._pipe_fluid_icons()
	area_pipes_ores._stop_labels()
	area_pipes_ores._pipe_end()
	area_pipes_ores._pipe_end_edges()
	await area_pipes_ores._pipe_windows()
	await area_pipes_ores._ore_scatter()
	area_pipes_ores._drill_wet()
	area_pipes_ores._pipe_covers()
	await area_pipes_ores._ore_pipe_edges()
	await area_pipes_ores._craft_pie(hud)
	area_pipes_ores._craft_predicted(hud)
	await area_pipes_ores._train_loading(hud)
	area_pipes_ores._total_raw()
	await area_hud._mod_windows(hud)
	await area_hud._window_bounds(hud)
	await area_parity._wires(hud)
	await area_parity._logistics_parity(hud, player)
	await area_build._build_tools(hud)
	area_build._wall_drag(hud)
	await area_build._blueprint_preview(hud)
	area_pipes_ores._repair_pack(hud)
	await area_map_menus._menus()
	await area_backdrop._menu_backdrop()
	await area_backdrop._menu_backdrop_cases()
	await area_backdrop._menu_backdrop_list()
	await area_backdrop._menu_backdrop_ground()
	await area_map_menus._load_mods()
	await area_pbr_looks._antialiasing_look()
	await area_pbr_looks._texture_metal_look()
	await area_pbr_looks._pack_shading_look()
	await area_pbr_looks._pbr_look()
	await area_pbr_looks._pbr_reference()
	await area_pbr_looks._pbr_light()
	await area_pbr_looks._light_env_window()
	await area_map_menus._perf_test()
	await area_hud._layout(hud)
	await area_hud._map_title(hud)
	await area_hud._help(hud)
	await area_icons._icons(hud)
	area_hud._alt_sequences()
	area_hud._alt_stock()
	area_hud._alt_icon_order()
	area_hud._alt_icon_order_kept()
	area_hud._alt_robot_items()
	area_combat_debug._turrets()
	area_combat_debug._turrets_far()
	area_combat_debug._turret_lights()
	area_combat_debug._collectors()
	area_combat_debug._asteroid_chunks()
	area_combat_debug._rocket_launch_vfx()
	area_combat_debug._ride_before_silo()
	area_combat_debug._belt_end_rules()
	area_combat_debug._belt_line_ends()
	await area_combat_debug._fx_movers()
	area_combat_debug._lightning()
	await area_combat_debug._weapons()
	await area_combat_debug._flame_streams()
	area_combat_debug._acid_aim()
	await area_combat_debug._console(hud)
	await area_combat_debug._debug_menu(hud)
	await area_combat_debug._health_bars()
	await area_combat_debug._debug_menu_over_camera(hud)
	area_combat_debug._debug_sim_switches(hud)
	area_combat_debug._debug_light_sliders(hud)
	area_combat_debug._debug_live_sliders(hud)
	await area_combat_debug._dev_tools(hud)
	await area_combat_debug._update_overlays(hud)
	area_combat_debug._view_priority()
	await area_perf_lod._performance()
	area_streaming._resolution_scaling()
	await area_streaming._streaming()
	await area_streaming._frame_budget()
	await area_streaming._shot_release()
	await area_streaming._hotfix_021()
	await area_streaming._pipeline_warm()
	await area_streaming._bridge_parsing()
	await area_streaming._bridge_relay()
	area_streaming._working_near()
	await area_streaming._stream_spread()
	await area_streaming._far_chunks()
	await area_streaming._distant_horizon_integration()
	area_perf_lod._belt_stand_ins()
	area_perf_lod._belt_stand_ins_at_4k()
	area_perf_lod._belt_item_shadows()
	area_perf_lod._lod_lines()
	area_perf_lod._belts_always_run()
	area_perf_lod._belt_blur()
	area_streaming._ups_governor()
	area_streaming._budget_fast()
	await area_streaming._perf_warning(hud)
	area_world_anim._terrain()
	await area_world_anim._hill_culling()
	area_lighting._lamps()
	area_lighting._signal_lights()
	area_lighting._states_sliced()
	area_lighting._ih_quick()
	area_lighting._hill_lights()
	area_lighting._vehicle_lights()
	area_world_anim._binary_movers()
	area_world_anim._robot_sim()
	area_world_anim._binary_belts()
	area_world_anim._binary_world()
	area_lighting._camera_focus()
	area_lighting._f6_projection()
	area_lighting._contact_shade()
	area_lighting._contact_drills()
	area_lighting._contact_chunk()
	area_lighting._contact_mask()
	await area_lighting._ao_zoom()
	area_lighting._post_hotfix()
	area_world_anim._surface_change()
	area_world_anim._gpu_anim()
	area_world_anim._gate_open()
	await area_world_anim._creature_motion()
	await area_world_anim._space_creatures()
	area_world_anim._tree_crowns()
	area_belts._belt_sim()
	area_belts._belt_self_side()
	area_belts._belt_unison()
	area_belts._belt_lattice_turns()
	await area_play._ninth_list(hud, player)
	await area_play._mining_feedback(hud)
	area_play._mine_reach(hud)
	area_play._mine_reach_more(hud)
	await area_play._research_done(hud)
	await area_play._research_open_queue(hud)
	await area_play._first_person_aim(hud)
	await area_play._center_aim(hud)
	area_play._pick_up(hud)
	area_belts._belt_take()
	area_belts._belt_drop_show()
	area_belts._belt_line_end()
	area_belts._belt_early_stop()
	area_belts._belt_step_creep()
	area_belts._belt_lattice_mask_join()
	area_belts._belt_lattice_open()
	area_belts._belt_lattice_handover()
	area_belts._belt_perf_upgrades()
	await area_belts._track2a_cpu_opts()
	await area_belts._track2b_streaming_and_prep()
	await area_belts._track3_gpu_opts()
	area_belts._belt_lattice_tail()
	area_belts._belt_turn_id()
	area_belts._belt_item_variants()
	area_belts._belt_lane_inset_far()
	await area_play._quickbar_hand(hud, player)
	await area_play._cursor_count()
	await area_play._hand_stack(hud)
	await area_play._hand_stack_more(hud)
	area_belts._belt_removed()
	await area_packs._twelfth_list(hud)
	await area_packs._model_packs_window()
	await area_play._vehicle_guns(hud)
	await area_packs._belt_preview_ends()
	await area_packs._model_chooser(hud)
	await area_packs._entity_info_pack(hud)
	await area_packs._entity_info_pack_edges(hud)
	await area_packs._hover_run_rate(hud)
	await area_hud._esc_tooltip()
	if DisplayServer.get_name() != "headless" and OS.get_cmdline_user_args().size() > 0 and OS.get_cmdline_user_args()[-1].ends_with(".png"):
		await area_hud._picture(hud, player)
	_nothing_left_behind()
	print("FAILS: %d" % fails)
	get_tree().quit(1 if fails else 0)

