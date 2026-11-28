extends "res://tests/ui_test_base.gd"
## UI test sections: pipes_ores.

func _total_raw() -> void:
	var m := UiModel.new()
	m.set_recipe_details([
		{"name": "copper-cable", "energy": 0.5, "ingredients": [["copper-plate", 1]], "products": [["copper-cable", 2]]},
		{"name": "electronic-circuit", "energy": 0.5, "ingredients": [["iron-plate", 1], ["copper-cable", 3]], "products": [["electronic-circuit", 1]]},
		{"name": "inserter", "energy": 0.5, "ingredients": [["electronic-circuit", 1], ["iron-plate", 1]], "products": [["inserter", 1]]},
		{"name": "gear", "energy": 0.5, "ingredients": [["iron-plate", 2]], "products": [["gear", 1]]},
		{"name": "loop-a", "energy": 1.0, "ingredients": [["loop-b", 1]], "products": [["loop-a", 1]]},
		{"name": "loop-b", "energy": 1.0, "ingredients": [["loop-a", 1]], "products": [["loop-b", 1]]}])
	var raw := m.total_raw("inserter")
	check(raw["expanded"] and is_equal_approx(raw["items"]["iron-plate"], 2.0) and is_equal_approx(raw["items"]["copper-plate"], 1.5)
		and is_equal_approx(raw["time"], 1.75) and raw["items"].size() == 2, "total raw goes down through the hand recipes: %s" % raw)
	var lines: Array = CraftingPanel.recipe_tip_lines(m, m.recipe("inserter"))
	var at := -1
	for i in lines.size():
		if str(lines[i][0]) == "Total raw:":
			at = i
	check(at >= 0 and str(lines[at + 1][0]).contains("1.75") and str(lines[at + 2][0]).ends_with("1.5 × Copper plate"), "the tooltip lists it after the products: %s" % [lines])
	check(not m.total_raw("gear")["expanded"] and not CraftingPanel.recipe_tip_lines(m, m.recipe("gear")).any(func(l): return str(l[0]) == "Total raw:"),
		"a recipe of raw items only has no Total raw")
	check(m.total_raw("loop-a")["too_complex"], "a loop of recipes is too complex to calculate")


## P47: the crafting queue's pie moves every frame between `cq`s, evenly, and each `cq` only corrects it.


func _craft_pie(hud: Hud) -> void:
	var m: UiModel = hud.ui.model
	var q = hud.ui.craft_queue
	m.set_recipe_details([{"name": "pie-gear", "energy": 2.0, "ingredients": [["iron-plate", 2]], "products": [["pie-gear", 1]]}])
	var had_info: Dictionary = m.character_info
	var had_recipes: Array = m.recipes
	m.character_info = {"craft": 1000}
	q._ticks_per_s = 60.0
	m.handle({"t": "cq", "pr": 200, "l": [[1, "pie-gear", 3, 0]]})
	var first: Slot = q._slots[0]
	check(is_equal_approx(first.progress, 0.2), "the pie starts where the game says: %s" % first.progress)
	q._process(0.1)
	check(is_equal_approx(first.progress, 0.25), "and moves between updates at the recipe's speed: %s" % first.progress)
	m.handle({"t": "cq", "pr": 260, "l": [[1, "pie-gear", 3, 0]]})
	check(is_equal_approx(first.progress, 0.25), "an update near it doesn't jump: %s" % first.progress)
	var before: float = first.progress
	q._process(0.1)
	check(first.progress > before + 0.05 and first.progress < before + 0.06, "it eases onto the update: %s" % first.progress)
	q._pie = 0.99
	q._pie_gap = 0.0
	q._process(0.1)
	check(first.progress > 0.0 and first.progress < 0.1, "a craft done comes round while more are queued: %s" % first.progress)
	var outline := Slot.pie_points(Rect2(0, 0, 40, 40), 0.3)
	check(outline.size() == 4 and outline[2] == Vector2(40, 0) and is_equal_approx(outline[3].x, 40.0),
		"the pie's edge runs along the slot's side past the corner: %s" % outline)
	m.handle({"t": "cq", "pr": 0, "l": []})
	check(q._pie == -1.0, "an empty queue stops the pie")
	m.character_info = had_info
	m.recipes = had_recipes


## P48: a craft shows in the queue the moment it is asked for, if the ingredients are there; the
## game's next `cq` replaces it, and one it refused goes away.


func _craft_predicted(hud: Hud) -> void:
	var m: UiModel = hud.ui.model
	var had_recipes: Array = m.recipes
	var had_slots: Array = m.main_slots
	var had_counts: Dictionary = m.counts.duplicate()
	var had_has := m.has_slots
	m.set_recipe_details([{"name": "soon-gear", "energy": 1.0, "ingredients": [["iron-plate", 2]], "products": [["soon-gear", 1]]},
		{"name": "soon-belt", "energy": 1.0, "ingredients": [["soon-gear", 1]], "products": [["soon-belt", 1]]}])
	m.handle({"t": "slots", "l": {"main": [["iron-plate", 5]]}})
	m.handle({"t": "cq", "pr": 0, "l": []})
	m.craft("soon-gear", 1)
	check(m.craft_queue.size() == 1 and m.craft_queue[0].get("predicted", false) and m.craft_queue_size == 1, "a craft shows at once: %s" % [m.craft_queue])
	m.craft("soon-gear", 5)
	check(m.craft_queue.size() == 1 and m.craft_queue_size == 2, "as many more as the ingredients left allow, on the same entry: %s" % m.craft_queue_size)
	m.craft("soon-belt", 1)
	check(m.craft_queue_size == 2, "a craft whose intermediates are missing waits for the game")
	var q = hud.ui.craft_queue
	check(q._slots[0].visible and int(q._slots[0].get_meta("index")) == 0, "the predicted slot shows and has no index to cancel yet")
	m.handle({"t": "cq", "pr": 100, "l": [[1, "soon-gear", 2, 0]]})
	check(m._pending_crafts.is_empty() and m.craft_queue_size == 2 and int(m.craft_queue[0]["index"]) == 1 and not m.craft_queue[0].has("predicted"),
		"the game's queue replaces the prediction")
	m.handle({"t": "cq", "pr": 0, "l": []})
	m.craft("soon-gear", 1)
	m._pending_crafts[0]["at"] = Time.get_ticks_msec() - UiModel.PREDICTED_CRAFT_MS - 1
	m.expire_predicted_crafts()
	check(m.craft_queue.is_empty(), "a craft the game never answered goes away")
	sent()
	m.recipes = had_recipes
	m.main_slots = had_slots
	m.counts = had_counts
	m.has_slots = had_has


## P46: the train overview shows a loading icon until its list comes, and a far train's view until
## its chart does; "No Trains found." only once the mod has said so.


func _train_loading(hud: Hud) -> void:
	var m: UiModel = hud.ui.model
	var w = hud.ui.trains_window
	var had: Array = m.trains_overview.duplicate()
	m.trains_overview.clear()
	w.open(true)
	check(w._loading.visible and not w._banner.visible, "the empty overview waits with its loading icon instead of the banner")
	m.handle({"t": "trl", "part": 1, "parts": 1, "l": []})
	check(not w._loading.visible and w._banner.visible, "the answer ends it: no trains means the banner")
	w.open(false)
	w.open(true)
	w._wait_left = 0.0
	w._process(0.016)
	check(not w._loading.visible and w._banner.visible, "a list that doesn't come stops the wait too")
	w.open(false)
	m.trains_overview = had
	sent()
	var view := preload("res://scripts/ui/factorio/train_view.gd").new()
	var cache = preload("res://scripts/ui/factorio/map_cache.gd").new(m)
	view.cache = cache
	view.custom_minimum_size = Vector2(100, 100)
	view.size = Vector2(100, 100)
	view.show_train(0, Vector2(500, 500))
	hud.add_child(view)
	await get_tree().process_frame
	view._process(0.016)
	check(view._spinner.visible, "a far train's view waits with its loading icon")
	cache._charted[Vector2i(15, 15)] = 1.0
	view._process(0.016)
	check(not view._spinner.visible, "and stops when the chart is there")
	view.queue_free()


## P50: plain pipes show their fluid every few tiles, whichever way a run goes.
## The eleventh list's L6, L8, L10, L11 (the owner's playtest video on oil):
## L8: a held pumpjack shows its output arrow (an old bridge's `fo` doesn't hide an output-only drill's), no arrow
## in its middle, is red off a resource it mines ("... can only be built on resources", "... cannot mine this
## resource" over ore), marks the wells round the cursor and the one it takes; a held pipe joins the pipes beside it
## and a machine's connection pointing at its tile. L10: a refinery's record `fc` draws each connection's arrow and
## fluid icon on hover and in Alt-mode, `aiu` keeps it, --fluid-icons=off the prototype's arrows. L11: a pipe's
## hinfo `pl` and `ox` read "Pipeline overextended" and "Pipeline extent: 333/320"; the alert kind. L6: a
## resource's entity info (amount now, an infinite one's yield, what mines it), the map's `rpatch` answer, its
## outline and the entity info's patch.


func _oil_and_pipelines(hud: Hud) -> void:
	const ResourceHints := preload("res://scripts/player/resource_hints.gd")
	const AltArrows := preload("res://scripts/world/alt_arrows.gd")
	const MapView := preload("res://scripts/ui/factorio/map_view.gd")
	const AlertsScript := preload("res://scripts/ui/factorio/alerts.gd")
	const AlertIconsScript := preload("res://scripts/ui/factorio/alert_icons.gd")
	var m: UiModel = hud.ui.model
	var world := WorldMirror.new()
	world.pick_build_usec = 1 << 40
	world.protos.add_entities([
		[41, "pumpjack", "mining-drill", -1.5, -1.5, 1.5, 1.5, 120, 120, 120, 3, 3],
		[42, "crude-oil", "resource", -1.4, -1.4, 1.4, 1.4, 120, 120, 120, 3, 3],
		[43, "pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1],
		[44, "oil-refinery", "assembling-machine", -2.5, -2.5, 2.5, 2.5, 120, 120, 120, 5, 5],
		[45, "iron-ore", "resource", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1],
	])
	var ref_fb := [[-1, 3, 8, "i"], [1, 3, 8, "i"], [-2, -3, 0, "o"], [0, -3, 0, "o"], [2, -3, 0, "o"]]
	m.handle({"t": "eprops", "l": [
		# (as a bridge before L8 sent it: `fo` on every drill)
		[41, 0, 0, 0, {"mr": 0.49, "vp": [0, 0], "fb": [[1, -1, 0, "o"]], "fo": 1, "rk": ["basic-fluid"], "rr": 1}],
		[42, 0, 0, 0, {"rk": "basic-fluid", "hl": 1}], [45, 0, 0, 0, {"rk": "basic-solid"}], [44, 0, 0, 0, {"fb": ref_fb}]]})
	world.chunks[Vector2i.ZERO] = ChunkView.new()
	world._add([0, 42, 10 * 256 + 128, 10 * 256 + 128, 0, {"a": 150000}])
	world._add([0, 45, 20 * 256 + 128, 5 * 256 + 128, 0, {"a": 1234}])
	world._add([31, 41, 10 * 256 + 128, 10 * 256 + 128, 0])
	var input := PlayerInput.new()
	input.world = world
	input.hud = hud
	var jack: ProtoDB.EntityProto = world.protos.entity(41)
	var jx: Dictionary = m.eprops[41]["x"]

	# --- L8: the held pumpjack ---------------------------------------------------------------------
	var held := CursorOverlay.marks_for("mining-drill", jx, Vector2(10.5, 10.5), 0, true)
	var held_arrows: Array = held.filter(func(k): return k["k"] == "arrow")
	check(held_arrows.size() == 1 and (held_arrows[0]["at"] as Vector2).is_equal_approx(Vector2(11.5, 8.88))
		and (held_arrows[0]["dir"] as Vector2).is_equal_approx(Vector2(0, -1)),
		"L8: a held pumpjack facing north shows its output arrow at the north-east tile, northwards, and none in its middle: %s" % [held_arrows])
	var east: Array = CursorOverlay.marks_for("mining-drill", jx, Vector2(10.5, 10.5), 4, true).filter(func(k): return k["k"] == "arrow")
	check(east.size() == 1 and (east[0]["at"] as Vector2).is_equal_approx(Vector2(12.12, 11.5)),
		"L8: and turned east, at the south-east tile eastwards, as 2.1.24's pumpjack: %s" % [east])
	check(ResourceHints.mining_refusal(world, m.eprops, jack, Vector2(10.5, 10.5)) == ""
		and ResourceHints.mining_refusal(world, m.eprops, jack, Vector2(13.5, 10.5)).ends_with("can only be built on resources")
		and ResourceHints.mining_refusal(world, m.eprops, jack, Vector2(20.5, 5.5)).ends_with("cannot mine this resource"),
		"L8: a pumpjack goes only on an oil well: red off it, and over ore it can't mine")
	var on_marks := ResourceHints.drill_marks(world, m.eprops, jack, Vector2(10.5, 10.5))
	var off_marks := ResourceHints.drill_marks(world, m.eprops, jack, Vector2(14.5, 10.5))
	check(on_marks.size() == 1 and on_marks[0]["edge"] == ResourceHints.MINE_OK and off_marks.size() == 1
		and off_marks[0]["edge"] == ResourceHints.HIGHLIGHT_EDGE and (off_marks[0]["rect"] as Rect2).has_point(Vector2(10.5, 10.5)),
		"L8: the well it would pump is marked green, wells round the cursor white (Factorio's highlight); ore not: %s %s" % [on_marks, off_marks])
	ResourceHints.drill_hints = false
	check(ResourceHints.mining_refusal(world, m.eprops, jack, Vector2(13.5, 10.5)) == ""
		and ResourceHints.drill_marks(world, m.eprops, jack, Vector2(14.5, 10.5)).is_empty(), "--resource-hints=off: as before")
	ResourceHints.drill_hints = true
	# Uranium ore (rf: needs fluid), as 2.1.24's can_place_entity measured: an electric drill (a fluid input) over it is
	# red until the force can mine with fluid, even with iron ore beside it; a burner drill (none) can't mine it at all.
	world.protos.add_entities([
		[46, "electric-mining-drill", "mining-drill", -1.5, -1.5, 1.5, 1.5, 120, 120, 120, 3, 3],
		[47, "burner-mining-drill", "mining-drill", -1.0, -1.0, 1.0, 1.0, 120, 120, 120, 2, 2],
		[48, "uranium-ore", "resource", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1],
	])
	m.handle({"t": "eprops", "l": [
		[41, 0, 0, 0, {"mr": 0.49, "vp": [0, 0], "fb": [[1, -1, 0, "o"]], "fo": 1, "rk": ["basic-fluid"], "rr": 1}],
		[42, 0, 0, 0, {"rk": "basic-fluid", "hl": 1}], [45, 0, 0, 0, {"rk": "basic-solid"}], [44, 0, 0, 0, {"fb": ref_fb}],
		[46, 0, 0, 0, {"mr": 2.49, "fb": [[-2, 0, 12, "b"], [2, 0, 4, "b"], [0, 2, 8, "b"]], "fo": 1, "rk": ["basic-solid"], "rr": 1}],
		[47, 0, 0, 0, {"mr": 0.99, "rk": ["basic-solid"], "rr": 1}], [48, 0, 0, 0, {"rk": "basic-solid", "rf": 1}]]})
	world._add([0, 48, 25 * 256 + 128, 25 * 256 + 128, 0, {"a": 500}])
	world._add([0, 45, 27 * 256 + 128, 27 * 256 + 128, 0, {"a": 500}])
	var edrill: ProtoDB.EntityProto = world.protos.entity(46)
	var bdrill: ProtoDB.EntityProto = world.protos.entity(47)
	check(ResourceHints.mining_refusal(world, m.eprops, edrill, Vector2(25.5, 25.5), false) == "Uranium mining not researched."
		and ResourceHints.mining_refusal(world, m.eprops, edrill, Vector2(25.5, 25.5), true) == ""
		and ResourceHints.mining_refusal(world, m.eprops, edrill, Vector2(29.5, 29.5), false) == "",
		"an electric drill over uranium ore: red before Uranium mining (iron beside it or not), placed after; over the iron alone either way")
	check(ResourceHints.mining_refusal(world, m.eprops, bdrill, Vector2(25, 25), true).ends_with("cannot mine this resource")
		and ResourceHints.mining_refusal(world, m.eprops, bdrill, Vector2(27, 27), false) == "",
		"a burner drill (no fluid input) can't mine uranium ore, researched or not; beside it on iron ore it goes")
	m.handle({"t": "cinfo", "mwf": 0})
	var no_mwf := m.mines_with_fluid()
	m.handle({"t": "cinfo", "mwf": 1})
	var yes_mwf := m.mines_with_fluid()
	m.handle({"t": "cinfo"})
	check(not no_mwf and yes_mwf and m.mines_with_fluid(), "cinfo mwf: 0 can't mine with fluid, 1 can, a bridge without it counts as can")
	ResourceHints.fluid_mining_hints = false
	check(ResourceHints.mining_refusal(world, m.eprops, edrill, Vector2(25.5, 25.5), false) == ""
		and ResourceHints.mining_refusal(world, m.eprops, bdrill, Vector2(25, 25), false) == "",
		"--fluid-mining-hints=off: uranium ore counts as any ore, as before")
	ResourceHints.fluid_mining_hints = true
	for k in world.entities.keys():  # (the L6 checks below hover the iron ore at 20, 5)
		var r: WorldMirror.Rec = world.entities[k]
		if r.pos.is_equal_approx(Vector2(25.5, 25.5)) or r.pos.is_equal_approx(Vector2(27.5, 27.5)):
			world._remove(k)
	# A pipe held where the pumpjack's output leads (11, 8) joins it, and the pipe east of it.
	var pipe: ProtoDB.EntityProto = world.protos.entity(43)
	world._add([32, 43, 12 * 256 + 128, 8 * 256 + 128, 0])
	check(int(input.build_extra(pipe, Vector2(11.5, 8.5), 0).get("pc", -1)) == 6
		and int(input.build_extra(pipe, Vector2(10.5, 8.5), 0).get("pc", -1)) == 0,
		"L8: a held pipe joins the pumpjack's output south of it and the pipe east (6), not a pumpjack side without one (0)")
	ResourceHints.pipe_joins = false
	check(int(input.build_extra(pipe, Vector2(11.5, 8.5), 0).get("pc", -1)) == 0, "--held-pipe-joins=off: the lone pipe, as before")
	ResourceHints.pipe_joins = true

	# --- L10: a refinery's connections and their fluids --------------------------------------------
	var fc := [[1, 2, 8, "i", "crude-oil"], [2, -2, 0, "o", "petroleum-gas"]]
	world._add([33, 44, 30 * 256 + 128, 10 * 256 + 128, 0, {"fa": 3, "fc": fc}])
	var rx: Dictionary = m.eprops[44]["x"]
	var ref_rec: WorldMirror.Rec = world.entities.get(33)
	var hovered := input.hover_marks(world.protos.entity(44), ref_rec.pos, 0, ref_rec.extra["fc"])
	var ref_arrows: Array = hovered.filter(func(k): return k["k"] == "arrow")
	var ref_icons: Array = hovered.filter(func(k): return k["k"] == "icon")
	check(ref_arrows.size() == 2 and ref_icons.size() == 2 and ref_icons[0]["name"] == "crude-oil" and ref_icons[1]["name"] == "petroleum-gas"
		and (ref_arrows[0]["dir"] as Vector2).is_equal_approx(Vector2(0, -1)) and (ref_icons[0]["at"] as Vector2).is_equal_approx(Vector2(31.5, 12.45)),
		"L10: hovering a refinery shows each used connection's arrow and its fluid's icon (crude oil in, petroleum gas out): %s" % [hovered])
	var alt := AltArrows.arrows_for("assembling-machine", rx, ref_rec.pos, 0, 3, fc)
	check(alt.filter(func(a): return int(a[0]) == AltArrows.ICON).map(func(a): return a[3]) == ["crude-oil", "petroleum-gas"]
		and alt.filter(func(a): return int(a[0]) == AltArrows.FLUID).size() == 2, "L10: Alt-mode draws the same arrows and icons: %s" % [alt])
	CursorOverlay.fluid_icons = false
	var old_marks: Array = input.hover_marks(world.protos.entity(44), ref_rec.pos, 0, ref_rec.extra["fc"])
	check(old_marks.filter(func(k): return k["k"] == "arrow").size() == 5 and old_marks.filter(func(k): return k["k"] == "icon").is_empty()
		and AltArrows.arrows_for("assembling-machine", rx, ref_rec.pos, 0, 3, fc).filter(func(a): return int(a[0]) == AltArrows.ICON).is_empty(),
		"--fluid-icons=off: the prototype's arrows without icons, as before")
	CursorOverlay.fluid_icons = true
	world._on_alt_fluids([[33, 0]])
	check(not ref_rec.extra.has("fc"), "L10: aiu's fa 0 drops the connections")
	world._on_alt_fluids([[33, 3, fc]])
	check(ref_rec.extra.get("fc") == fc, "L10: and its fa row brings them back")
	var shown_marks := hovered.duplicate()
	input._overlay.show_marks(shown_marks)
	check(input._overlay._icon_quads.size() == 2 and input._overlay._icon_quads.all(func(q): return q.visible),
		"L10: the overlay draws the two icons on quads of their own")
	input._overlay.show_marks([])
	check(not input._overlay._icon_quads.any(func(q): return q.visible), "and hides them with the marks")

	# --- L11 and L6: the entity info ---------------------------------------------------------------
	var einfo = hud.ui.entity_info
	var einfo_player = einfo.player
	einfo.player = input
	var pipe_rec: WorldMirror.Rec = world.entities.get(32)
	sent()
	einfo.show_entity(pipe_rec)
	var pask := sent_one("hinfo")
	m.handle({"t": "hinfo", "q": int(pask.get("q", 0)), "u": 32, "pl": [333, 320], "ox": 1})
	einfo.show_entity(pipe_rec)
	var ptext := "|".join(PackedStringArray(_texts(einfo._lines))).replace(":| ", ": ")
	check(int(pask.get("u", 0)) == 32 and einfo._status.text == "Pipeline overextended" and ptext.contains("Pipeline extent: 333/320"),
		"L11: hovering a pipe asks hinfo; its pipeline overextended and its extent as Factorio's entity info: %s %s" % [einfo._status.text, ptext])
	m.pedia_pages["entity/crude-oil"] = {"found": true, "d": {"type": "resource", "rinf": 1, "rnormal": 300000, "mined_by": ["pumpjack"]}}
	m.pedia_pages["entity/iron-ore"] = {"found": true, "d": {"type": "resource", "mined_by": ["burner-mining-drill", "electric-mining-drill"]}}
	var oil_rec: WorldMirror.Rec = null
	var ore_rec: WorldMirror.Rec = null
	for k in world.entities:
		var r: WorldMirror.Rec = world.entities[k]
		if r.proto_id == 42:
			oil_rec = r
		elif r.proto_id == 45:
			ore_rec = r
	einfo.show_entity(oil_rec)
	var oask := sent_one("hinfo")
	m.handle({"t": "hinfo", "q": int(oask.get("q", 0)), "u": int(oask.get("u", 0)), "ra": 258738})
	einfo.show_entity(oil_rec)
	var otext := "|".join(PackedStringArray(_texts(einfo._lines))).replace(":| ", ": ")
	check(int(oask.get("u", 1)) < 0 and int(oask.get("x", 0)) == oil_rec.fixed.x and otext.contains("Yield: 86%")
		and otext.contains("Mined by:") and not otext.contains("Remaining"),
		"L6: hovering crude oil asks hinfo by its place (no unit) and shows its yield now (258,738 of 300,000) and what mines it: %s %s" % [oask, otext])
	einfo.show_entity(ore_rec)
	var rask := sent_one("hinfo")
	einfo.show_entity(ore_rec)
	var rtext := "|".join(PackedStringArray(_texts(einfo._lines))).replace(":| ", ": ")
	check(rtext.contains("Amount: 1,234") and int(rask.get("u", 0)) != int(oask.get("u", 0)),
		"L6: an ore tile its amount (the record's until hinfo answers), another tile another key: %s" % rtext)
	# The map's resource patch (rpatch), shown with nothing in the world hovered.
	sent()
	m.ask_patch(Vector2i(60, 60))
	var patch_ask := sent_one("rpatch")
	m.ask_patch(Vector2i(60, 60))
	check(int(patch_ask.get("x", 0)) == 60 * 256 + 128 and sent_one("rpatch").is_empty(), "L6: the map asks rpatch once a tile")
	m.handle({"t": "rpatch", "q": int(patch_ask.get("q", 0)), "n": "iron-ore", "a": 1234567, "c": 4, "o": [[60, 60, 3, 65, 1], [61, 61, 2]]})
	check(UiModel.patch_has(m.map_patch, Vector2i(65, 60)) and UiModel.patch_has(m.map_patch, Vector2i(62, 61))
		and not UiModel.patch_has(m.map_patch, Vector2i(63, 60)), "L6: the patch's tiles from its rows")
	einfo.show_entity(null)
	var mtext := "|".join(PackedStringArray(_texts(einfo._lines))).replace(":| ", ": ")
	check(einfo.visible and einfo._title.text.to_lower().contains("iron") and mtext.contains("Amount: 1,234,567"),
		"L6: the entity info shows the patch's total while the map's mouse is on it: %s %s" % [einfo._title.text, mtext])
	m.handle({"t": "rpatch", "q": int(patch_ask.get("q", 0)), "n": "crude-oil", "a": 450000, "c": 2, "y": 150, "o": [[9, 9, 3]]})
	einfo.show_entity(null)
	var ytext := "|".join(PackedStringArray(_texts(einfo._lines)))
	check(ytext.contains("combined yield 150%"), "L6: an oil field's combined yield, Factorio's words: %s" % ytext)
	m.clear_patch()
	einfo.show_entity(null)
	check(not einfo.visible and m.map_patch.is_empty(), "L6: gone when the mouse leaves the patch or the map")
	var edges := MapView.outline_edges([[0, 0, 2], [1, 1, 2]])
	# Two runs: (0..2, row 0) and (1..3, row 1): 4 ends, row 0's top and the part of its bottom row 1 doesn't
	# cover (0..1), row 1's top part row 0 doesn't cover (2..3) and its bottom.
	check(edges.size() == 16 and edges.has(Vector2(0, 1)) and edges.has(Vector2(3, 2)), "L6: the outline round a patch's tiles: %s" % [edges])
	einfo.player = einfo_player
	einfo.show_entity(null)
	check(AlertsScript.KINDS.has("pipeline") and AlertIconsScript.DRAWN.has("pipeline")
		and str(AlertsScript.KINDS["pipeline"][0]) == "fluid-icon-red.png", "L11: the pipeline alert in the bar and over its entity")
	input._overlay.free()  # (not in the tree: not freed with it)
	input.pipeline_vis.free()
	input.free()


## The owner's FUE5 pipe left open where its run now ended: a pipe mined out of the middle of a run (the bridge's
## `mnd`, then its `del`) leaves the pipes beside it the run's ending pieces at once, though their connections came
## from the bridge (`pc`, trusted) and a bridge before /f3d-perf mined_neighbours never sent them again. The pieces
## are in FUE5's kit and Placeholders'. `--pipe-end=old` (pipe_end_now off): they stay straights.


func _pipe_end() -> void:
	for old in [false, true]:
		WorldMirror.pipe_end_now = not old
		for via in ["mnd", "del"]:
			var world := WorldMirror.new()
			world.protos.add_entities([[43, "pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1]])
			world.chunks[Vector2i.ZERO] = ChunkView.new()
			var masks := [2, 10, 10, 10, 8]  # five pipes west to east, as the bridge sends them
			for i in 5:
				world._add([500 + i, 43, (3 + i) * 256 + 128, 6 * 256 + 128, 0, {"pc": masks[i]}])
			var mid := {"u": 502, "p": 43, "x": 5 * 256 + 128, "y": 6 * 256 + 128}
			if via == "mnd":
				world.mined({"t": "mnd", "g": 1, "l": []}.merged(mid))
			world.handle({"t": "del"}.merged(mid))
			var shapes: Array = []
			for u in [500, 501, 503, 504]:
				var r: WorldMirror.Rec = world.entities.get(u)
				shapes.append(ModelLibrary.model_name("pipe", "pipe", r.extra) if r != null else "gone")
			if old:
				check(shapes[1] == "pipe-straight-horizontal" and shapes[2] == "pipe-straight-horizontal",
					"--pipe-end=old (%s): the pipes beside a mined one stay straights until the bridge says: %s" % [via, shapes])
				continue
			check(shapes == ["pipe-ending-right", "pipe-ending-left", "pipe-ending-right", "pipe-ending-left"],
				"a pipe mined from a run (%s): the pipes beside it are the run's ending pieces at once: %s" % [via, shapes])
			check(world._dirty.has(Vector2i.ZERO), "and their chunk is drawn again (%s)" % via)
			# A pipe built on the emptied tile again joins them as the bridge sends it.
			world._add([505, 43, 5 * 256 + 128, 6 * 256 + 128, 0, {"pc": 10}])
			world.handle({"t": "upd", "e": [501, 43, 4 * 256 + 128, 6 * 256 + 128, 0, {"pc": 10}]})
			check(ModelLibrary.model_name("pipe", "pipe", (world.entities[501] as WorldMirror.Rec).extra) == "pipe-straight-horizontal",
				"and the bridge's `upd` of a neighbour is taken as it says (%s)" % via)
			world.free()
	WorldMirror.pipe_end_now = true
	# The owner's second picture: a T whose branch was mined stayed a T, its mouth open. A T, a cross and a corner,
	# each losing the north arm (the bridge's connections), and a pipe whose pipe-to-ground was mined.
	for old in [false, true]:
		WorldMirror.pipe_end_now = not old
		var cases := {"T": [11, [[1, 0], [-1, 0]], "pipe-straight-horizontal", "pipe-t-up"],
			"cross": [15, [[1, 0], [-1, 0], [0, 1]], "pipe-t-down", "pipe-cross"],
			"corner": [3, [[1, 0]], "pipe-ending-right", "pipe-corner-up-right"]}
		for name: String in cases:
			var c: Array = cases[name]
			var world := WorldMirror.new()
			world.protos.add_entities([[43, "pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1]])
			world.chunks[Vector2i.ZERO] = ChunkView.new()
			world._add([600, 43, 10 * 256 + 128, 10 * 256 + 128, 0, {"pc": int(c[0])}])
			var u := 601
			for arm: Array in c[1]:
				world._add([u, 43, (10 + int(arm[0])) * 256 + 128, (10 + int(arm[1])) * 256 + 128, 0, {"pc": 0}])
				u += 1
			world._add([620, 43, 10 * 256 + 128, 9 * 256 + 128, 0, {"pc": 4}])
			world.mined({"t": "mnd", "g": 1, "l": [], "u": 620, "p": 43, "x": 10 * 256 + 128, "y": 9 * 256 + 128})
			var shape := ModelLibrary.model_name("pipe", "pipe", (world.entities[600] as WorldMirror.Rec).extra)
			check(shape == str(c[3] if old else c[2]), "%sa %s losing its north arm to mining is drawn %s: %s"
				% ["--pipe-end=old: " if old else "", name, c[3] if old else c[2], shape])
			world.free()
		var w2 := WorldMirror.new()
		w2.protos.add_entities([[43, "pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1],
			[46, "pipe-to-ground", "pipe-to-ground", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1]])
		w2.chunks[Vector2i.ZERO] = ChunkView.new()
		w2._add([700, 46, 4 * 256 + 128, 4 * 256 + 128, 4])  # facing east, at the pipe
		w2._add([701, 43, 5 * 256 + 128, 4 * 256 + 128, 0, {"pc": 8}])
		w2.handle({"t": "del", "u": 700, "p": 46, "x": 4 * 256 + 128, "y": 4 * 256 + 128})
		var lone := ModelLibrary.model_name("pipe", "pipe", (w2.entities[701] as WorldMirror.Rec).extra)
		check(lone == ("pipe-ending-left" if old else "pipe-straight-vertical-single"),
			"%sa pipe whose pipe-to-ground was mined: %s" % ["--pipe-end=old: " if old else "", lone])
		w2.free()
	WorldMirror.pipe_end_now = true
	# Walls and heat pipes: the bridge sends no connections for them (no `wc`, no `pc`: heat pipes have no fluid
	# box), so the client works out their shapes from their neighbours and again on a removal; the same holds.
	var w3 := WorldMirror.new()
	w3.protos.add_entities([[47, "stone-wall", "wall", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1],
		[48, "heat-pipe", "heat-pipe", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1]])
	w3.chunks[Vector2i.ZERO] = ChunkView.new()
	for i in 3:
		w3._add([800 + i, 47, (3 + i) * 256 + 128, 2 * 256 + 128, 0])
		w3._add([810 + i, 48, (3 + i) * 256 + 128, 7 * 256 + 128, 0])
	var before := [ModelLibrary.model_name("stone-wall", "wall", (w3.entities[800] as WorldMirror.Rec).extra),
		ModelLibrary.model_name("heat-pipe", "heat-pipe", (w3.entities[810] as WorldMirror.Rec).extra)]
	w3.mined({"t": "mnd", "g": 1, "l": [], "u": 801, "p": 47, "x": 4 * 256 + 128, "y": 2 * 256 + 128})
	w3.handle({"t": "del", "u": 811, "p": 48, "x": 4 * 256 + 128, "y": 7 * 256 + 128})
	var after: Array = []
	for u in [800, 802, 810, 812]:
		var r: WorldMirror.Rec = w3.entities[u]
		after.append(ModelLibrary.model_name("stone-wall" if u < 810 else "heat-pipe", "wall" if u < 810 else "heat-pipe", r.extra))
	check(before == ["stone-wall-e", "heat-pipe-ending-right"]
		and after == ["stone-wall-pylon", "stone-wall-pylon", "heat-pipe-straight-vertical-single", "heat-pipe-straight-vertical-single"],
		"a wall and a heat pipe mined from a run of three leave their neighbours lone pieces: %s -> %s" % [before, after])
	w3.free()
	for piece in ["stone-wall-e", "stone-wall-w", "stone-wall-pylon", "heat-pipe-ending-left", "heat-pipe-straight-horizontal",
			"pipe-straight-horizontal", "pipe-t-down", "pipe-straight-vertical-single"]:
		check(ModelLibrary.ModelPacks.find_in("builtin:fue5", piece) != "", "FUE5 has %s" % piece)
	for pack in ["builtin:fue5", "builtin:placeholders"]:
		var missing: Array = []
		for piece in ["pipe-ending-left", "pipe-ending-right", "pipe-ending-up", "pipe-ending-down"]:
			if ModelLibrary.ModelPacks.find_in(pack, piece) == "":
				missing.append(piece)
		check(missing.is_empty(), "%s has the ending pieces a run's end is drawn with: missing %s" % [pack, missing])


## A box (`size`, standing on the ground, centred) written as a .glb at `path`: a fixture pack's model.


func _pipe_windows() -> void:
	var b := Vector3(1.0, 0.3, 0.3)
	_fixture_packs("ui-test-pipe-windows", {
		"Windows": {"pipe-straight-horizontal": b, "pipe-straight-vertical": b, "pipe-straight-horizontal-window": Vector3(1.0, 0.4, 0.4),
			"pipe-straight-vertical-window": Vector3(0.4, 0.4, 1.0), "pipe-corner-up-right": b, "pipe-t-up": b},
		"Plain": {"pipe-straight-horizontal": Vector3(1.0, 0.25, 0.25), "pipe-straight-vertical": Vector3(0.25, 0.25, 1.0)}},
		["dir:Windows", "dir:Plain"])
	var make := func() -> WorldMirror:
		var w := WorldMirror.new()
		w.protos.add_entities([[43, "pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1]])
		w.chunks[Vector2i.ZERO] = ChunkView.new()
		return w
	var names := func(w: WorldMirror, units: Array) -> Array:
		return units.map(func(u: int) -> String: return ModelLibrary.model_name("pipe", "pipe", (w.entities[u] as WorldMirror.Rec).extra))
	# Six straights west to east on row 6, x 3..8 (as the bridge sends them, all joined both ways): x 4, 6, 8 even.
	var world: WorldMirror = make.call()
	for i in 6:
		world._add([500 + i, 43, (3 + i) * 256 + 128, 6 * 256 + 128, 0, {"pc": 10}])
	var line: Array = names.call(world, [500, 501, 502, 503, 504, 505])
	var want := ["pipe-straight-horizontal", "pipe-straight-horizontal-window"]
	check(line == [want[0], want[1], want[0], want[1], want[0], want[1]],
		"a line of 6 straight pipes has windows on the 3 even tiles: %s" % [line])
	# A vertical run worked out here (no `pc` from the bridge): its middle straights, the even ones windowed.
	for i in 4:
		world._add([520 + i, 43, 12 * 256 + 128, (2 + i) * 256 + 128, 0])
	var column: Array = names.call(world, [520, 521, 522, 523])
	check(column == ["pipe-ending-down", "pipe-straight-vertical", "pipe-straight-vertical-window", "pipe-ending-up"],
		"a vertical run joined by the client: a window on its even straight: %s" % [column])
	# The chunk draws them: three windows among the line, with the vertical one.
	var cv: ChunkView = world.chunks[Vector2i.ZERO]
	add_child(cv)
	_make_models(world.protos, cv)
	cv.build_entities(world.protos, {})
	var drawn := _drawn(cv)
	var win := ModelLibrary.mesh_for("pipe-straight-horizontal-window")
	check(win != null and drawn.has(win) and (drawn[win] as Array).size() == 3,
		"the chunk draws the 3 windows with the pack's window model: %s" % [(drawn.get(win, []) as Array).size()])
	cv.queue_free()
	world.chunks.clear()
	world.free()
	# A corner and a T on even tiles never get one.
	world = make.call()
	world._add([600, 43, 4 * 256 + 128, 4 * 256 + 128, 0, {"pc": 3}])
	world._add([601, 43, 6 * 256 + 128, 6 * 256 + 128, 0, {"pc": 11}])
	var bent: Array = names.call(world, [600, 601])
	check((world.entities[600] as WorldMirror.Rec).extra.has("pw") and bent == ["pipe-corner-up-right", "pipe-t-up"],
		"a corner and a T on even tiles: no window: %s" % [bent])
	world.free()
	# A pack without the window model (drawing the pipe) draws the plain straight.
	ModelLibrary.ModelPacks.configure(ModelLibrary.ModelPacks.folder, ["dir:Plain", "dir:Windows"], [])
	ModelLibrary.ModelPacks.wait()
	ModelLibrary.choices_changed([])
	world = make.call()
	world._add([700, 43, 4 * 256 + 128, 6 * 256 + 128, 0, {"pc": 10}])
	var plain: String = names.call(world, [700])[0]
	check(plain == "pipe-straight-horizontal", "a pack without the window model draws its plain straight: %s" % plain)
	world.free()
	# The switch off: no windows.
	ModelLibrary.ModelPacks.configure(ModelLibrary.ModelPacks.folder, ["dir:Windows", "dir:Plain"], [])
	ModelLibrary.ModelPacks.wait()
	ModelLibrary.choices_changed([])
	ModelLibrary.pipe_windows = false
	world = make.call()
	for i in 6:
		world._add([800 + i, 43, (3 + i) * 256 + 128, 6 * 256 + 128, 0, {"pc": 10}])
	var off: Array = names.call(world, [800, 801, 802, 803, 804, 805])
	check(not off.any(func(n: String) -> bool: return n.ends_with("-window")), "--pipe-windows=off: no windows: %s" % [off])
	world.free()
	ModelLibrary.pipe_windows = true

	# PipeInsides: a single-sided CULL_DISABLED opaque surface alongside a BLEND glass surface gets
	# reversed inward back faces with negated normals, glass stays single-sided, and repeated calls
	# / CULL_BACK / --pipe-insides=off are skipped.
	var make_shell := func(cull: int) -> Array:
		var solid_mat := StandardMaterial3D.new()
		solid_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		solid_mat.cull_mode = cull
		var glass_mat := StandardMaterial3D.new()
		glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		glass_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var s_arr := []
		s_arr.resize(Mesh.ARRAY_MAX)
		s_arr[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1)])
		s_arr[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
		s_arr[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
		s_arr[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2])
		var g_arr := []
		g_arr.resize(Mesh.ARRAY_MAX)
		g_arr[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 0.7, 0), Vector3(1, 0.7, 0), Vector3(1, 0.7, 1), Vector3(0, 0.7, 1)])
		g_arr[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
		g_arr[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2])
		return [[[ [solid_mat, true, false, false, "", false] ], s_arr, 0],
			[[ [glass_mat, false, false, false, "", false] ], g_arr, 0]]
	var groups: Array = make_shell.call(BaseMaterial3D.CULL_DISABLED)
	var added_insides := PipeInsides.add_to_groups(groups)
	var solid_out: Array = groups[0][1]
	var glass_out: Array = groups[1][1]
	var out_idx: PackedInt32Array = solid_out[Mesh.ARRAY_INDEX]
	var out_norms: PackedVector3Array = solid_out[Mesh.ARRAY_NORMAL]
	check(added_insides == 2 and out_idx.size() == 12
		and out_idx[6] == 4 and out_idx[7] == 5 and out_idx[8] == 6
		and out_norms.size() == 8 and out_norms[4].is_equal_approx(Vector3.DOWN)
		and (glass_out[Mesh.ARRAY_INDEX] as PackedInt32Array).size() == 6,
		"pipe_insides: opaque CULL_DISABLED doubled with reversed winding & flipped normals; glass untouched (%d, %s)" % [added_insides, out_idx])
	check(PipeInsides.add_to_groups(groups) == 0, "pipe_insides: idempotent on a second pass")
	check(PipeInsides.add_to_groups(make_shell.call(BaseMaterial3D.CULL_BACK)) == 0,
		"pipe_insides: skips opaque CULL_BACK")
	PipeInsides.enabled = false
	check(not PipeInsides.wanted("pipe-straight-horizontal-window"), "pipe_insides: --pipe-insides=off skips wanted()")
	PipeInsides.enabled = true

	# FluidsPower pipe fluid columns: only windowed straight pipes draw fluids, matched to horizontal/vertical
	# orientation, fluid colour, fill fraction, trace minimum (0.06), removal, --pipe-fluids=off and pack support.
	world = make.call()
	world.protos.add_fluids([[1, "water", 51, 102, 255], [2, "crude-oil", 18, 18, 18]])
	world._add([900, 43, 4 * 256 + 128, 6 * 256 + 128, 0, {"pc": 10}])  # even (4+6=10), horizontal straight
	world._add([901, 43, 6 * 256 + 128, 6 * 256 + 128, 0, {"pc": 5}])   # even (6+6=12), vertical straight
	world._add([902, 43, 5 * 256 + 128, 6 * 256 + 128, 0, {"pc": 10}])  # odd (5+6=11), plain straight
	world._add([903, 43, 8 * 256 + 128, 6 * 256 + 128, 0, {"pc": 3}])   # even (8+6=14), corner (never window)
	world._add([904, 43, 10 * 256 + 128, 6 * 256 + 128, 0, {"pc": 10}]) # even, horizontal trace test
	ModelLibrary.mesh_for("pipe-straight-horizontal-window")
	ModelLibrary.mesh_for("pipe-straight-vertical-window")
	var fp := FluidsPowerScript.new()
	fp.world = world
	add_child(fp)
	await get_tree().process_frame
	fp.handle({"t": "fl", "k": 1, "part": 1, "parts": 1, "l": [
		900, 1, 1, 50, 100, 15,
		901, 1, 2, 100, 100, 15,
		902, 1, 1, 80, 100, 15,
		903, 1, 1, 80, 100, 15,
	]})
	await get_tree().process_frame
	check(fp.pipe_fluid_count() == 2,
		"pipe_fluids: draws fluid only in the 2 windowed straight pipes (got %d)" % fp.pipe_fluid_count())
	var pmm: MultiMesh = fp._pipe_fluids.multimesh
	var water_lin := Color8(51, 102, 255).srgb_to_linear()
	var oil_lin := Color8(18, 18, 18).srgb_to_linear()
	var h_ok := false
	var v_ok := false
	var gpu_ok := DisplayServer.get_name() == "headless" or pmm.instance_count == fp.pipe_fluid_spots.size()
	for i in fp.pipe_fluid_spots.size():
		var spot: Array = fp.pipe_fluid_spots[i]
		var xf: Transform3D = spot[0]
		var col: Color = spot[1]
		var fill_v := float(spot[2])
		if DisplayServer.get_name() != "headless":
			gpu_ok = gpu_ok and pmm.get_instance_transform(i).is_equal_approx(xf) \
				and pmm.get_instance_color(i).is_equal_approx(col) \
				and is_equal_approx(pmm.get_instance_custom_data(i).r, fill_v)
		if absf(xf.origin.x - 4.5) < 0.01:
			h_ok = is_equal_approx(fill_v, 0.5) and absf(xf.basis.z.x) > 0.2 and col.is_equal_approx(water_lin)
		elif absf(xf.origin.x - 6.5) < 0.01:
			v_ok = is_equal_approx(fill_v, 1.0) and absf(xf.basis.z.z) > 0.2 and col.is_equal_approx(oil_lin)
	check(h_ok and v_ok and gpu_ok,
		"pipe_fluids: horizontal 50%% water and vertical 100%% crude oil transforms/colours match (%s, %s, %s)" % [h_ok, v_ok, gpu_ok])
	# Trace fluid (amount 0 with fluid present) keeps visible minimum fill 0.06.
	fp.handle({"t": "fl", "k": 2, "part": 1, "parts": 1, "l": [
		900, 1, 1, 50, 100, 15,
		901, 1, 2, 100, 100, 15,
		904, 1, 1, 0, 100, 15,
	]})
	await get_tree().process_frame
	var trace_fill := -1.0
	for spot_v in fp.pipe_fluid_spots:
		var spot: Array = spot_v
		var xf: Transform3D = spot[0]
		if absf(xf.origin.x - 10.5) < 0.01:
			trace_fill = float(spot[2])
	check(fp.pipe_fluid_count() == 3 and is_equal_approx(trace_fill, 0.06),
		"pipe_fluids: trace fluid amount 0 keeps minimum fill 0.06 (count=%d fill=%.3f)" % [fp.pipe_fluid_count(), trace_fill])
	# Removing an entity + entities_changed drops its fluid column at once.
	world.entities.erase(901)
	world.entities_changed.emit(Vector2i.ZERO)
	await get_tree().process_frame
	check(fp.pipe_fluid_count() == 2, "pipe_fluids: removing entity clears its fluid (%d)" % fp.pipe_fluid_count())
	# --pipe-fluids=off hides them all.
	FluidsPowerScript.pipe_fluids = false
	fp._visuals_dirty = true
	await get_tree().process_frame
	check(fp.pipe_fluid_count() == 0, "pipe_fluids: --pipe-fluids=off draws 0 (%d)" % fp.pipe_fluid_count())
	FluidsPowerScript.pipe_fluids = true
	# Switching to Plain pack (no -window model) draws none either.
	ModelLibrary.ModelPacks.configure(ModelLibrary.ModelPacks.folder, ["dir:Plain", "dir:Windows"], [])
	ModelLibrary.ModelPacks.wait()
	ModelLibrary.choices_changed([])
	fp._visuals_dirty = true
	await get_tree().process_frame
	check(fp.pipe_fluid_count() == 0, "pipe_fluids: Plain pack without -window models draws 0 (%d)" % fp.pipe_fluid_count())
	fp.world = null
	fp.queue_free()
	world.free()
	_fixture_packs_done()


## Scattered ore (Vasillo's single rocks, model_library.gd ore_rocks): a pack's numbered `iron-ore-1..3` draw each tile
## as 2, 4 or 6 rocks by its amount (under 400, from 400, from 2900), the same on every build, filled rank by rank so
## a far chunk shows one a tile; `--ore-scatter=off` one model a tile; a whole-tile `copper-ore.glb` (1.4 tiles)
## never scatters, a small plain `coal.glb` does; a pack.json's `"ore_scatter": false` keeps its numbered stone out.


func _ore_scatter() -> void:
	var ore_dir := _fixture_packs("ui-test-ore-scatter", {
		"Rocks": {"iron-ore-1": Vector3(0.36, 0.14, 0.31), "iron-ore-2": Vector3(0.36, 0.14, 0.27), "iron-ore-3": Vector3(0.27, 0.14, 0.27)},
		"Big": {"copper-ore": Vector3(1.4, 0.3, 1.4), "coal": Vector3(0.35, 0.14, 0.3)},
		"Asks": {"stone-1": Vector3(0.3, 0.1, 0.3), "stone-2": Vector3(0.2, 0.1, 0.3), "pack.json": "{\"name\": \"Asks\", \"ore_scatter\": false}"}},
		["dir:Rocks", "dir:Big", "dir:Asks"])
	var protos := ProtoDB.new()
	protos.add_entities([[61, "iron-ore", "resource", -0.5, -0.5, 0.5, 0.5, 100, 120, 140, 1, 1],
		[62, "copper-ore", "resource", -0.5, -0.5, 0.5, 0.5, 200, 100, 60, 1, 1],
		[63, "coal", "resource", -0.5, -0.5, 0.5, 0.5, 20, 20, 20, 1, 1],
		[64, "stone", "resource", -0.5, -0.5, 0.5, 0.5, 180, 160, 120, 1, 1]])
	var rocks: Variant = null
	for i in 600:
		rocks = ModelLibrary.ore_rocks("iron-ore")
		if rocks != null and ModelLibrary.ore_rocks("coal") != null and ModelLibrary.ore_rocks("copper-ore") != null:
			break
		ModelLibrary.poll()
		await get_tree().process_frame
	check(rocks is Array and (rocks as Array).size() == 3, "a pack's iron-ore-1..3 are scattered: %s" % [rocks])
	check(ModelLibrary.ore_rocks("copper-ore") is Array and (ModelLibrary.ore_rocks("copper-ore") as Array).is_empty(),
		"a 1.4-tile copper-ore.glb never scatters: %s" % [ModelLibrary.ore_rocks("copper-ore")])
	check(ModelLibrary.ore_rocks("coal") is Array and (ModelLibrary.ore_rocks("coal") as Array).size() == 1,
		"a plain coal.glb of one small rock (0.35 tiles) scatters: %s" % [ModelLibrary.ore_rocks("coal")])
	check(ModelLibrary.ore_rocks("stone") is Array and (ModelLibrary.ore_rocks("stone") as Array).is_empty(),
		"a pack whose pack.json says \"ore_scatter\": false keeps its stone-1, -2 unscattered")
	check(ModelLibrary.drawing_pack("iron-ore", "resource", {"a": 1000}).get("id", "") == "dir:Rocks",
		"the entity info names the rocks' pack as the ore's")
	# (Headless, a MultiMesh keeps no transforms: what a tile gets is counted by a chunk of that one tile.)
	var build := func(proto_id: int, amounts: Array, far := false) -> ChunkView:
		var cv := ChunkView.new()
		add_child(cv)
		for i in amounts.size():
			var r := WorldMirror.Rec.new()
			r.key = Vector3i(proto_id, i, 0)
			r.proto_id = proto_id
			r.fixed = Vector2i((2 + i * 4) * 256 + 128, 3 * 256 + 128)
			r.pos = Vector2(r.fixed) / 256.0
			r.extra = {"a": amounts[i]}
			cv.entities[r.key] = r
		cv.far.far = far
		_make_models(protos, cv)
		cv.build_entities(protos, {})
		return cv
	var made: Array[ChunkView] = []
	var total := func(cv: ChunkView) -> int:
		var n := 0
		for xf: Array in _drawn(cv).values():
			n += xf.size()
		return n
	var per_tile: Array = []
	for amount in [100, 1000, 5000]:
		var one: ChunkView = build.call(61, [amount])
		made.append(one)
		per_tile.append(total.call(one))
	check(per_tile == [3, 6, 8], "iron ore tiles of 100, 1000 and 5000 (Factorio's 8th, 6th and 4th stage): 3, 6 and 8 rocks: %s" % [per_tile])
	# --ore-density=classic: 0.2.2's 2, 4 and 6 at one size; the default grows them with the stage (1.1 to 1.9).
	var scale_of := func(amount: int) -> Array:
		var lo := 99.0
		var hi := 0.0
		for p: Array in ModelLibrary.ore_rock_places(Vector2i(1000, 2000), Vector3.ZERO, amount, 3):
			var s: float = (p[1] as Transform3D).basis.get_scale().x
			lo = minf(lo, s)
			hi = maxf(hi, s)
		return [lo, hi]
	var grown: Array = scale_of.call(5000)
	ModelLibrary.ore_density = "classic"
	var classic_tile: Array = []
	for amount in [100, 1000, 5000]:
		var one: ChunkView = build.call(61, [amount])
		made.append(one)
		classic_tile.append(total.call(one))
	var classic_scale: Array = scale_of.call(5000)
	ModelLibrary.ore_density = "factorio"
	check(classic_tile == [2, 4, 6] and float(classic_scale[0]) >= 0.799 and float(classic_scale[1]) <= 1.201
		and float(grown[0]) >= 0.8 * 1.6 - 0.001 and float(grown[1]) <= 1.2 * 1.6 + 0.001 and float(grown[1]) > 1.201,
		"--ore-density=classic: 2, 4 and 6 rocks sized %.2f-%.2f (default at 5000: %.2f-%.2f, x1.6): %s"
		% [classic_scale[0], classic_scale[1], grown[0], grown[1], classic_tile])
	var places := ModelLibrary.ore_rock_places(Vector2i(1000, 2000), Vector3(3.9, 0, 7.8), 5000, 3)
	var again := ModelLibrary.ore_rock_places(Vector2i(1000, 2000), Vector3(3.9, 0, 7.8), 5000, 3)
	var other := ModelLibrary.ore_rock_places(Vector2i(1256, 2000), Vector3(4.9, 0, 7.8), 5000, 3)
	var inside := places.all(func(p: Array) -> bool: return absf(p[1].origin.x - 3.9) <= 0.56 and absf(p[1].origin.z - 7.8) <= 0.56)
	var variants := {}
	for p: Array in places + other:
		variants[p[0]] = true
	check(places == again and places != other and inside and variants.size() >= 2,
		"each rock's model, place, turn and size from its tile and number: the same every time, another tile's its own, in its tile (%d models used)" % variants.size())
	var a: ChunkView = build.call(61, [100, 1000, 5000])
	var b: ChunkView = build.call(61, [100, 1000, 5000])
	made.append_array([a, b])
	var counts := func(cv: ChunkView) -> Dictionary:
		var out := {}
		for m: Mesh in _drawn(cv):
			out[m] = (_drawn(cv)[m] as Array).size()
		return out
	check(counts.call(a) == counts.call(b) and total.call(a) == 17, "the same rocks per model on two builds: %s" % [counts.call(a).values()])
	var models := _drawn(a).keys()
	check(models.size() == 3 and models.all(func(m: Mesh) -> bool: return (rocks as Array).has(m)),
		"the rocks go in the chunk's MultiMesh per rock model, no node per rock: %d MultiMeshes" % models.size())
	var first := 0
	for m: Mesh in a._ore_near:
		first += int(a._ore_near[m])
	check(first == 3, "each model's instances start with every tile's first rock: %d first rocks" % first)
	# A far chunk: one rock a tile, by the visible count (no build); near again, all of them.
	var visible_count := func(cv: ChunkView) -> int:
		var n := 0
		for key in cv._nodes:
			var mm: MultiMesh = (cv._nodes[key] as MultiMeshInstance3D).multimesh
			n += mm.instance_count if mm.visible_instance_count < 0 else mm.visible_instance_count
		return n
	a.far.far = true
	a.thin_ore()
	check(visible_count.call(a) == 3, "a far chunk shows one rock a tile: %d of 17" % visible_count.call(a))
	a.far.far = false
	a.thin_ore()
	check(visible_count.call(a) == 17, "near again, all 17: %d" % visible_count.call(a))
	var c: ChunkView = build.call(61, [100, 1000, 5000], true)
	made.append(c)
	check(visible_count.call(c) == 3, "a chunk built while far shows one rock a tile too: %d" % visible_count.call(c))
	var rich: ChunkView = build.call(61, [5000], true)
	made.append(rich)
	check(visible_count.call(rich) == 1 and total.call(rich) == 8, "a far rich tile: one of its 8 rocks shown: %d" % visible_count.call(rich))
	var copper: ChunkView = build.call(62, [100, 1000, 5000])
	made.append(copper)
	check(total.call(copper) == 3, "the whole-tile copper ore: one model a tile: %d for 3 tiles" % total.call(copper))
	ModelLibrary.ore_scatter = "off"
	var off: ChunkView = build.call(61, [100, 1000, 5000])
	made.append(off)
	check(total.call(off) == 3 and not _drawn(off).keys().any(func(m: Mesh) -> bool: return (rocks as Array).has(m)),
		"--ore-scatter=off: one model a tile, no rocks: %d for 3 tiles" % total.call(off))
	ModelLibrary.ore_scatter = "auto"
	# Whose ore it is (ModelPacks.provides, the one rule): Placeholders above the rocks' pack draws its own
	# iron ore, no rocks; the rocks' pack chosen for iron ore (its card's Select) scatters them again.
	var MP = ModelLibrary.ModelPacks
	MP.configure(ore_dir, ["builtin:placeholders", "dir:Rocks", "dir:Big", "dir:Asks"], [])
	MP.wait()
	ModelLibrary.choices_changed([])
	# Placeholders' ore is made on a worker the first time (ore_rocks: null meanwhile, to see whether it is one small
	# rock): a chunk built before then draws none of it but waits, and world.gd draws it again once it is made.
	var early: ChunkView = build.call(61, [100, 1000, 5000])
	made.append(early)
	var placeholder_rocks: Variant = ModelLibrary.ore_rocks("iron-ore")
	check(placeholder_rocks is Array or early.waiting_models,
		"a chunk built while Placeholders' ore is still being made waits for it: %d drawn, waiting %s" % [total.call(early), early.waiting_models])
	for i in 600:
		placeholder_rocks = ModelLibrary.ore_rocks("iron-ore")
		if placeholder_rocks != null:
			break
		ModelLibrary.poll()
		await get_tree().process_frame
	var under: ChunkView = build.call(61, [100, 1000, 5000])
	made.append(under)
	check(str(ModelLibrary.drawing_pack("iron-ore", "resource", {"a": 1000}).get("id", "")) == "builtin:placeholders"
		and placeholder_rocks is Array and (placeholder_rocks as Array).is_empty()
		and total.call(under) == 3 and not under.waiting_models,
		"Placeholders above the rocks' pack: its iron ore, one model a tile: %d for 3 tiles" % total.call(under))
	MP.set_choices({"iron-ore": "dir:Rocks"})
	ModelLibrary.choices_changed(["iron-ore"])
	var again_rocks: Variant = null
	for i in 600:
		again_rocks = ModelLibrary.ore_rocks("iron-ore")
		if again_rocks != null:
			break
		ModelLibrary.poll()
		await get_tree().process_frame
	var chosen_cv: ChunkView = build.call(61, [100, 1000, 5000])
	made.append(chosen_cv)
	check(again_rocks is Array and (again_rocks as Array).size() == 3 and total.call(chosen_cv) == 17
		and _drawn(chosen_cv).keys().all(func(m: Mesh) -> bool: return (again_rocks as Array).has(m)),
		"the rocks' pack chosen for iron ore: its 3 rocks scattered whatever the order: %d" % total.call(chosen_cv))
	MP.set_choices({})
	ModelLibrary.choices_changed(["iron-ore"])
	for cv: ChunkView in made:
		cv.queue_free()
	_fixture_packs_done()


## Pipe covers (pipe_covers.gd): a wet drill's three connections (west, east, south) each get the pack's
## `pipe-cover` while nothing is connected; a pipe reaching back takes that one away (one whose `pc` doesn't,
## and a ghost, don't), and taking the pipe away brings it back. A dry drill, a pack without covers and
## --pipe-covers=off draw none. A pack with no `pipe-cover` but a pipe kit takes the cap off its
## `pipe-ending-down` (the ending less its straight: Vasillo's), turned to the north edge.


func _pipe_covers() -> void:
	var dir := _fixture_packs("ui-test-pipe-covers", {"Covers": {"x-drill": Vector3(2.8, 1.0, 2.8),
		"x-drill-wet": Vector3(3.0, 0.4, 0.6), "pipe-cover": Vector3(0.9, 0.9, 0.11)},
		"Plain": {"y-drill": Vector3(2.8, 1.0, 2.8), "y-drill-wet": Vector3(3.0, 0.4, 0.6)}}, ["dir:Covers", "dir:Plain"])
	var world := WorldMirror.new()
	world.protos.add_entities([[71, "x-drill", "mining-drill", -1.5, -1.5, 1.5, 1.5, 120, 120, 120, 3, 3],
		[72, "y-drill", "mining-drill", -1.5, -1.5, 1.5, 1.5, 120, 120, 120, 3, 3],
		[73, "pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1]])
	# The electric mining drill's connections as the bridge sends them (eprops fb, facing north).
	var fb := [[-1, 0, 12, "i"], [1, 0, 4, "i"], [0, 1, 8, "i"]]
	world.fluid_ports_from({71: {"x": {"fb": fb}}, 72: {"x": {"fb": fb}}})
	var cv := ChunkView.new()
	world.chunks[Vector2i.ZERO] = cv
	add_child(cv)
	world._add([910, 71, 4 * 256 + 128, 4 * 256 + 128, 0, {"fa": 1}])
	world._add([911, 71, 10 * 256 + 128, 4 * 256 + 128, 0])
	world._add([912, 72, 16 * 256 + 128, 4 * 256 + 128, 0, {"fa": 1}])
	var wet_drill: WorldMirror.Rec = world.entities[910]
	check(wet_drill.covers == 7 and (world.entities[911] as WorldMirror.Rec).covers == 0,
		"a wet drill with nothing attached: all three connections open (%d); a dry one none" % wet_drill.covers)
	var cover := ModelLibrary.mesh_for("pipe-cover@dir:Covers")
	var build := func() -> Array:
		_make_models(world.protos, cv)
		ModelLibrary.mesh_for("pipe-cover@dir:Covers")
		cv.build_entities(world.protos, {})
		return _drawn(cv).get(cover, [])
	var drawn_covers: Array = build.call()
	# (Headless, a MultiMesh keeps no transforms: where they go is asked of PipeCovers as chunk_view asks it.)
	var places := PipeCovers.places(wet_drill.cover_ports, wet_drill.covers, ModelLibrary.placed("x-drill", "mining-drill", 0, {}, Vector3(4.5, 0, 4.5)))
	var spots: Array = places.map(func(t: Transform3D) -> Vector2: return Vector2(t.origin.x, t.origin.z).snapped(Vector2(0.01, 0.01)))
	check(cover != null and drawn_covers.size() == 6 and spots.has(Vector2(3.5, 4.5)) and spots.has(Vector2(5.5, 4.5))
		and spots.has(Vector2(4.5, 5.5)), "six covers (3 on x-drill + 3 fallback on y-drill), on the connections' own tiles: %s" % [spots])
	var west: Variant = null
	for t: Transform3D in places:
		if is_equal_approx(t.origin.x, 3.5):
			west = t
	check(west != null and ((west as Transform3D).basis * Vector3(0, 0, -1)).is_equal_approx(Vector3(-1, 0, 0)),
		"the west one turned to face west (its north edge outwards)")
	check((world.entities[912] as WorldMirror.Rec).covers == 7 and _drawn(cv).has(ModelLibrary.mesh_for("y-drill")),
		"a pack without its own covers falls back to the active pipe cover pack (both drills covered)")
	# A pipe west of it whose connections (the bridge's pc) reach east, back to the drill: that cover goes.
	world._dirty.clear()
	world._add([0, 73, 2 * 256 + 128, 4 * 256 + 128, 0, {"pc": 2}])
	check(wet_drill.covers == 6 and world._dirty.has(Vector2i.ZERO), "a pipe connected on the west: its cover gone (%d)" % wet_drill.covers)
	check((build.call() as Array).size() == 5, "and five covers drawn")
	# One whose pc doesn't reach the drill (it runs north) leaves the south cover.
	world._add([0, 73, 4 * 256 + 128, 6 * 256 + 128, 0, {"pc": 2}])
	check(wet_drill.covers == 6, "a pipe beside the south connection not connected to it: still covered")
	world._add([0, 73, 4 * 256 + 128, 6 * 256 + 128, 0, {"pc": 1, "gh": 73}])
	check(wet_drill.covers == 6, "nor a ghost")
	world._remove(WorldMirror.static_key(73, 2 * 256 + 128, 4 * 256 + 128))
	check(wet_drill.covers == 7 and (build.call() as Array).size() == 6, "the pipe taken away: the cover back (%d)" % wet_drill.covers)
	# Another machine with a connection back onto the east one: a second drill beside it, west connection to east.
	world._add([913, 71, 7 * 256 + 128, 4 * 256 + 128, 0, {"fa": 1}])
	check(wet_drill.covers == 5 and (world.entities[913] as WorldMirror.Rec).covers == 6,
		"two drills side by side: the connections between them covered on neither (%d, %d)" % [wet_drill.covers, (world.entities[913] as WorldMirror.Rec).covers])
	world._remove(913)
	check(wet_drill.covers == 7, "the other drill gone: the east cover back")
	world._add([914, 71, 6 * 256 + 128 + 0, 8 * 256 + 128, 4, {"fa": 1}])
	var turned: WorldMirror.Rec = world.entities[914]
	check(turned.covers == 7, "a drill facing east: open too (%d)" % turned.covers)
	world._remove(914)
	# Turned: facing east, its south connection leads west.
	world._remove(910)
	world._add([910, 71, 4 * 256 + 128, 4 * 256 + 128, 4, {"fa": 1}])
	wet_drill = world.entities[910]
	world._add([0, 73, 2 * 256 + 128, 4 * 256 + 128, 0, {"pc": 2}])
	check(wet_drill.covers == 3, "a drill facing east: the pipe on the west meets its (turned) south connection (%d)" % wet_drill.covers)
	world._remove(WorldMirror.static_key(73, 2 * 256 + 128, 4 * 256 + 128))
	# The drill going dry (`aiu` fa) takes its covers away (y-drill's 3 fallback covers stay).
	world._on_alt_fluids([[910, 0]])
	check(wet_drill.covers == 0 and (build.call() as Array).size() == 3, "a drill gone dry: no covers on wet_drill (%d drawn from y-drill)" % (build.call() as Array).size())
	world._on_alt_fluids([[910, 1]])
	check(wet_drill.covers == 7, "wet again: covered again")
	PipeCovers.enabled = false
	world.fluid_ports_from({71: {"x": {"fb": fb}}, 72: {"x": {"fb": fb}}})
	check(wet_drill.covers == 0 and (build.call() as Array).is_empty(), "--pipe-covers=off: none")
	PipeCovers.enabled = true
	cv.queue_free()
	world.chunks.clear()
	world.free()
	_fixture_packs_done()
	# A pipe kit without a pipe-cover: the cap of its ending (Vasillo's: the straight plus a cap at its north edge).
	var kit := dir.path_join("Kit")
	_boxes_glb(kit.path_join("pipe-straight-vertical.glb"), [[Vector3(0.9, 0.9, 1.0), Vector3(0, 0.5, 0)]])
	_boxes_glb(kit.path_join("pipe-ending-down.glb"), [[Vector3(0.9, 0.9, 1.0), Vector3(0, 0.5, 0)],
		[Vector3(0.9, 0.9, 0.11), Vector3(0, 0.5, 0.445)]])
	_boxes_glb(kit.path_join("k-drill.glb"), [[Vector3(2.8, 1.0, 2.8), Vector3(0, 0.5, 0)]])
	var saved := ModelLibrary.ModelPacks.packs
	ModelLibrary.ModelPacks.configure(dir, ["dir:Kit"], ["dir:Covers", "dir:Plain"])
	ModelLibrary.ModelPacks.wait()
	ModelLibrary.ModelPacks.wait()
	ModelLibrary.choices_changed([])
	var pack := ModelLibrary.drawing_pack("k-drill", "mining-drill", {"fa": 1})
	var name := PipeCovers.model_for(pack)
	var made := PipeCovers.cover(name, func(n: String) -> Mesh: return ModelLibrary.mesh_for(n))
	var cap: Mesh = made[0] if not made.is_empty() else null
	var box := cap.get_aabb() if cap != null else AABB()
	check(name == "pipe-ending-down@dir:Kit" and cap != null and box.position.z > -0.51 and box.end.z < -0.38
		and box.size.x > 0.85, "a kit's cap taken off its ending, at the north edge: %s %s" % [name, box])
	check(PipeCovers.cover(name, func(n: String) -> Mesh: return ModelLibrary.mesh_for(n)) == made, "made once")
	# Bug #12: PipeInsides.wanted covers pipe endings/underground/covers, add_to_groups works without glass,
	# and PipeCovers.cap_from falls back to outer-edge triangles when straight shares none.
	check(PipeInsides.wanted("pipe-ending-down") and PipeInsides.wanted("pipe-straight-vertical-single")
		and PipeInsides.wanted("pipe-to-ground") and PipeInsides.wanted("pipe-cover")
		and not PipeInsides.wanted("assembling-machine-1"),
		"#12: PipeInsides.wanted matches capped/underground pipe pieces")
	var raw_arr := []
	raw_arr.resize(Mesh.ARRAY_MAX)
	raw_arr[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)])
	raw_arr[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK])
	var ds_mat := StandardMaterial3D.new()
	ds_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var opaque_groups := [[[[ds_mat]], raw_arr]]
	var added_tris := PipeInsides.add_to_groups(opaque_groups)
	check(added_tris == 1 and (raw_arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() == 6,
		"#12: PipeInsides.add_to_groups adds inward back-faces without a glass surface (%d)" % added_tris)
	var edge_box := ArrayMesh.new()
	var bmesh := BoxMesh.new()
	bmesh.size = Vector3(0.4, 0.4, 0.1)
	edge_box.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, bmesh.get_mesh_arrays())
	var diff_straight := ArrayMesh.new()
	var smesh := BoxMesh.new()
	smesh.size = Vector3(2.0, 2.0, 2.0)
	diff_straight.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, smesh.get_mesh_arrays())
	var fb_cap := PipeCovers.cap_from(edge_box, diff_straight)
	check(fb_cap != null and fb_cap.get_surface_count() > 0,
		"#12: PipeCovers.cap_from boundary fallback extracts cap when straight shares no triangles")
	# Batch 3 C8: flush pipe & drill caps (CAP_EDGE_Z = -0.505, --pipe-cap-edge=old, procedural cap).
	var was_flush := PipeCovers.flush_edge
	check(was_flush and is_equal_approx(PipeCovers.CAP_EDGE_Z, -0.505),
		"C8: flush_edge defaults on with CAP_EDGE_Z == -0.505")
	check(is_equal_approx(box.position.z, PipeCovers.CAP_EDGE_Z),
		"C8: extracted kit cap front edge sits flush at CAP_EDGE_Z (-0.505, got %.4f)" % box.position.z)
	var proc_cap := PipeCovers._procedural_cap(edge_box)
	check(proc_cap != null and is_equal_approx(proc_cap.get_aabb().position.z, PipeCovers.CAP_EDGE_Z),
		"C8: procedural cap sits flush at CAP_EDGE_Z (-0.505, got %.4f)" % (proc_cap.get_aabb().position.z if proc_cap != null else 0.0))
	PipeCovers.flush_edge = false
	var old_made := PipeCovers.cover(name, func(n: String) -> Mesh: return ModelLibrary.mesh_for(n))
	var old_cap: Mesh = old_made[0] if not old_made.is_empty() else null
	check(old_cap != null and old_cap != cap and absf(old_cap.get_aabb().position.z - PipeCovers.CAP_EDGE_Z) > 0.002,
		"C8: --pipe-cap-edge=old invalidates cache and restores unshifted cap (%.4f)" % (old_cap.get_aabb().position.z if old_cap != null else 0.0))
	PipeCovers.flush_edge = was_flush
	ModelLibrary.ModelPacks.use(saved)
	ModelLibrary.choices_changed([])

	# --- Item #16: PipeCovers dominant plate Z, backface subtraction, PipeInsides wet drill, ghost caps, FACING_MODELS covers ---
	const GhostsScript := preload("res://scripts/world/ghosts.gd")
	const WireScript := preload("res://scripts/util/wire.gd")
	check(PipeInsides.wanted("electric-mining-drill-wet") and PipeInsides.wanted("big-mining-drill-wet")
		and not PipeInsides.wanted("electric-mining-drill"),
		"Item #16: PipeInsides.wanted matches wet mining drills and excludes dry drills")
	# Synthetic doubled-backface ending vs single-sided straight: reversed barrel triangles must NOT survive cap_from.
	var barrel_box := BoxMesh.new()
	barrel_box.size = Vector3(0.4, 0.4, 1.0)
	var barrel_arr: Array = barrel_box.get_mesh_arrays()
	var straight_m := ArrayMesh.new()
	straight_m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, barrel_arr)
	var cap_box := BoxMesh.new()
	cap_box.size = Vector3(0.6, 0.6, 0.1)
	var cap_arr: Array = cap_box.get_mesh_arrays()
	var cap_verts: PackedVector3Array = cap_arr[Mesh.ARRAY_VERTEX]
	for vi in cap_verts.size():
		cap_verts[vi] += Vector3(0.0, 0.0, 0.5)
	cap_arr[Mesh.ARRAY_VERTEX] = cap_verts
	var ending_m := ArrayMesh.new()
	ending_m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, barrel_arr)
	# Append reversed barrel triangles (simulating PipeInsides doubled backfaces on ending).
	var rev_arr: Array = barrel_arr.duplicate(true)
	var ridx: PackedInt32Array = rev_arr[Mesh.ARRAY_INDEX]
	for ti in range(0, ridx.size() - 2, 3):
		var tmp := ridx[ti + 1]
		ridx[ti + 1] = ridx[ti + 2]
		ridx[ti + 2] = tmp
	rev_arr[Mesh.ARRAY_INDEX] = ridx
	ending_m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, rev_arr)
	ending_m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, cap_arr)
	ending_m.set_meta(PipeInsides.META, 12)
	var sub_cap := PipeCovers.cap_from(ending_m, straight_m)
	var sub_box := sub_cap.get_aabb() if sub_cap != null else AABB()
	check(sub_cap != null and sub_box.size.z < 0.25 and is_equal_approx(sub_box.position.z, PipeCovers.CAP_EDGE_Z),
		"Item #16: cap_from subtracts doubled-backface barrel triangles cleanly and aligns plate to CAP_EDGE_Z (box=%s)" % [sub_box])
	# Builtin packs (`builtin:fue5` and `builtin:placeholders`): real pipe-ending-down minus pipe-straight-vertical.
	for pack_id: String in ["builtin:fue5", "builtin:placeholders"]:
		var end_name := PipeCovers.ENDING + "@" + pack_id
		var str_name := PipeCovers.STRAIGHT + "@" + pack_id
		var m_end := ModelLibrary.mesh_for(end_name)
		var m_str := ModelLibrary.mesh_for(str_name)
		if m_end != null and m_str != null:
			var bcap := PipeCovers.cap_from(m_end, m_str)
			var bbox := bcap.get_aabb() if bcap != null else AABB()
			var cap_kept: Array = []
			if bcap != null:
				for si in bcap.get_surface_count():
					var sarr: Array = bcap.surface_get_arrays(si)
					var sidx: PackedInt32Array = sarr[Mesh.ARRAY_INDEX] if sarr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
					if sidx.is_empty():
						var sv: PackedVector3Array = sarr[Mesh.ARRAY_VERTEX]
						sidx.resize(sv.size())
						for k_i in sv.size():
							sidx[k_i] = k_i
					cap_kept.append([si, sidx])
			var pz: float = PipeCovers._dominant_plate_z(bcap, cap_kept, Basis.IDENTITY, bbox.position.z, INF) if bcap != null else 0.0
			check(bcap != null and bcap.get_surface_count() > 0 and bbox.size.z < 0.45
				and pz <= PipeCovers.CAP_EDGE_Z + 0.01 and pz >= -0.60,
				"Item #16 (%s): cap_from produces clean plate at target Z without barrel stub (plate_z=%.4f box=%s)" % [pack_id, pz, bbox])
	# Ghosts.ghost_pieces / PipeCovers.ghost_cap_pieces: wet drill gets 3 caps, dry gets 0; pipe-to-ground gets 1 unless connected.
	var ppack := ModelLibrary.drawing_pack("electric-mining-drill", "mining-drill", {"fa": 1}, 0)
	var mesh_fn := func(n: String) -> Mesh:
		return ModelLibrary.mesh_for(n)
	var wet_caps := PipeCovers.ghost_cap_pieces("mining-drill", PipeCovers.WET_DRILL_PORTS, {"fa": 1}, 0, Vector2(4.5, 4.5), ppack, mesh_fn)
	var dry_caps := PipeCovers.ghost_cap_pieces("mining-drill", PipeCovers.WET_DRILL_PORTS, {}, 0, Vector2(4.5, 4.5), ppack, mesh_fn)
	var ug_open := PipeCovers.ghost_cap_pieces("pipe-to-ground", null, {}, 0, Vector2(4.5, 4.5), ppack, mesh_fn)
	var ug_conn := PipeCovers.ghost_cap_pieces("pipe-to-ground", null, {"pc": 1}, 0, Vector2(4.5, 4.5), ppack, mesh_fn)
	check(wet_caps.size() == 3 and dry_caps.is_empty() and ug_open.size() == 1 and ug_conn.is_empty(),
		"Item #16: ghost_cap_pieces emits 3 caps for wet drill (%d), 0 for dry (%d), 1 for open pipe-to-ground (%d), 0 when pc connected (%d)" % [
			wet_caps.size(), dry_caps.size(), ug_open.size(), ug_conn.size()])
	# chunk_view._add_covers uses rec.dir (not base.basis, which stays north on FACING_MODELS entities).
	var cv16 := ChunkView.new()
	add_child(cv16)
	var rec16 := WorldMirror.Rec.new()
	rec16.pos = Vector2(5.5, 5.5)
	rec16.dir = 4  # facing east
	rec16.covers = 1  # port 0 only: [-1, 0, 12, "i"] -> turned east (90 deg CW in Factorio) lands at (0, -1) facing north
	rec16.cover_ports = PipeCovers.ports(PipeCovers.WET_DRILL_PORTS, "mining-drill", 1)
	var proto16 := ProtoDB.EntityProto.new()
	proto16.name = "electric-mining-drill"
	proto16.type = "mining-drill"
	var by_m16 := {}
	var recs_m16 := {}
	var parts_m16 := {}
	var north_base := Transform3D(Basis.IDENTITY, Vector3(5.5, 0.0, 5.5))
	var cover_name16 := PipeCovers.model_for(ModelLibrary.drawing_pack(proto16.name, proto16.type, rec16.extra, rec16.dir))
	if cover_name16 != "":
		ModelLibrary.mesh_for(cover_name16)
		if cover_name16.begins_with(PipeCovers.ENDING + "@"):
			ModelLibrary.mesh_for(PipeCovers.STRAIGHT + cover_name16.substr(PipeCovers.ENDING.length()))
		cv16._add_covers(rec16, proto16, north_base, by_m16, recs_m16, parts_m16)
		var placed16: Array = []
		for arr16: Array in by_m16.values():
			placed16.append_array(arr16)
		if not placed16.is_empty():
			var xf16: Transform3D = placed16[0]
			var expected_at := Transform3D(Basis(Vector3.UP, WireScript.direction_yaw(4)), Vector3(5.5, 0.0, 5.5))
			var want_xf: Transform3D = PipeCovers.places(rec16.cover_ports, 1, expected_at)[0]
			check(xf16.origin.is_equal_approx(want_xf.origin) and xf16.basis.is_equal_approx(want_xf.basis),
				"Item #16: chunk_view._add_covers turns covers by rec.dir even when base.basis is north (%s vs %s)" % [xf16.origin, want_xf.origin])
	cv16.queue_free()

	# Bug batch 4 #3: inward-detail bolt caps (Vasillo Zenith pipe-cap) flip outward past CAP_EDGE_Z,
	# and active top-priority pipe pack provides covers for buildings in lower-priority packs.
	var saved_b4 := ModelLibrary.ModelPacks.packs
	var dir_b4 := _fixture_packs("ui-test-pipe-covers-zenith", {}, [])
	var top_dir := dir_b4.path_join("TopPipes")
	var low_dir := dir_b4.path_join("LowerBld")
	_boxes_glb(top_dir.path_join("pipe-straight-vertical.glb"), [[Vector3(0.9, 0.9, 1.0), Vector3(0.0, 0.5, 0.0)]])
	# Ending = straight + recessed flat plate at z=-0.45 + bolt boss strictly inward (+Z at z=-0.39).
	_boxes_glb(top_dir.path_join("pipe-ending-down.glb"), [
		[Vector3(0.9, 0.9, 1.0), Vector3(0.0, 0.5, 0.0)],
		[Vector3(0.9, 0.9, 0.002), Vector3(0.0, 0.5, -0.45)],
		[Vector3(0.15, 0.15, 0.04), Vector3(0.30, 0.5, -0.39)],
	])
	_boxes_glb(low_dir.path_join("pipe-straight-vertical.glb"), [[Vector3(0.75, 0.75, 1.0), Vector3(0.0, 0.5, 0.0)]])
	_boxes_glb(low_dir.path_join("pipe-ending-down.glb"), [
		[Vector3(0.75, 0.75, 1.0), Vector3(0.0, 0.5, 0.0)],
		[Vector3(0.75, 0.75, 0.10), Vector3(0.0, 0.5, -0.45)],
	])
	_boxes_glb(low_dir.path_join("z-boiler.glb"), [[Vector3(2.8, 1.5, 1.8), Vector3(0.0, 0.75, 0.0)]])
	ModelLibrary.ModelPacks.configure(dir_b4, ["dir:TopPipes", "dir:LowerBld"], [])
	ModelLibrary.ModelPacks.wait()
	ModelLibrary.choices_changed([])
	var bld_pack := ModelLibrary.drawing_pack("z-boiler", "boiler", {})
	var was_follow := PipeCovers.follow_pipe_pack
	PipeCovers.follow_pipe_pack = true
	var follow_name := PipeCovers.model_for(bld_pack)
	PipeCovers.follow_pipe_pack = false
	var own_name := PipeCovers.model_for(bld_pack)
	PipeCovers.follow_pipe_pack = was_follow
	check(follow_name == "pipe-ending-down@dir:TopPipes" and own_name == "pipe-ending-down@dir:LowerBld",
		"PipeCovers.model_for follows active pipe pack (%s) and --pipe-covers=own uses entity pack (%s)" % [follow_name, own_name])
	var inw_made := PipeCovers.cover(follow_name, func(n: String) -> Mesh: return ModelLibrary.mesh_for(n))
	var inw_cap: Mesh = inw_made[0] if not inw_made.is_empty() else null
	var inw_box := inw_cap.get_aabb() if inw_cap != null else AABB()
	var inw_kept := []
	if inw_cap != null:
		var arr0: Array = inw_cap.surface_get_arrays(0)
		var idx0: Variant = arr0[Mesh.ARRAY_INDEX]
		if idx0 is PackedInt32Array and not (idx0 as PackedInt32Array).is_empty():
			inw_kept = [[0, idx0]]
		else:
			var v0: PackedVector3Array = arr0[Mesh.ARRAY_VERTEX]
			inw_kept = [[0, PackedInt32Array(range(v0.size()))]]
	var inw_pz := PipeCovers._dominant_plate_z(inw_cap, inw_kept, Basis.IDENTITY, inw_box.position.z, INF) if inw_cap != null else 0.0
	PipeCovers.flush_edge = false
	var unflip_made := PipeCovers.cover(follow_name, func(n: String) -> Mesh: return ModelLibrary.mesh_for(n))
	var unflip_cap: Mesh = unflip_made[0] if not unflip_made.is_empty() else null
	var unflip_box := unflip_cap.get_aabb() if unflip_cap != null else AABB()
	PipeCovers.flush_edge = was_flush
	check(inw_cap != null and inw_box.position.z < PipeCovers.CAP_EDGE_Z - 0.05 and absf(inw_pz - PipeCovers.CAP_EDGE_Z) < 0.01
		and unflip_cap != null and unflip_box.position.z > -0.47,
		"Inward bolt cap flips outward past CAP_EDGE_Z (box=%s pz=%.4f) while --pipe-cap-edge=old stays unflipped (%s)" % [inw_box, inw_pz, unflip_box])
	ModelLibrary.ModelPacks.use(saved_b4)
	ModelLibrary.choices_changed([])
	_fixture_packs_done()


## A .glb of boxes ([[size, centre], ...]), one mesh each, sharing one material.


static func _boxes_glb(path: String, boxes: Array) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var root := Node3D.new()
	var material := StandardMaterial3D.new()
	for b: Array in boxes:
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = b[0]
		box.material = material
		mi.mesh = box
		mi.position = b[1]
		root.add_child(mi)
		mi.owner = root
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	doc.append_from_scene(root, state)
	doc.write_to_filesystem(state, path)
	root.free()


## A drill's fluid part (Factorio's wet drill: model_library.gd wet_model): a pack's `x-drill-wet` over its `x-drill`
## at the drill's own place while the record's fa has bit 1 (the resource under it needs fluid), not without;
## `--drill-wet=off` never; a pack without the -wet model draws the drill alone. A change of fa draws the chunk again.


func _drill_wet() -> void:
	_fixture_packs("ui-test-drill-wet", {"Drills": {"x-drill": Vector3(2.8, 1.0, 2.8), "x-drill-wet": Vector3(3.0, 0.4, 0.6),
		"y-drill": Vector3(2.8, 1.0, 2.8)}}, ["dir:Drills"])
	var world := WorldMirror.new()
	world.protos.add_entities([[71, "x-drill", "mining-drill", -1.5, -1.5, 1.5, 1.5, 120, 120, 120, 3, 3],
		[72, "y-drill", "mining-drill", -1.5, -1.5, 1.5, 1.5, 120, 120, 120, 3, 3]])
	var cv := ChunkView.new()
	world.chunks[Vector2i.ZERO] = cv
	add_child(cv)
	world._add([900, 71, 4 * 256 + 128, 4 * 256 + 128, 4, {"fa": 1}])
	world._add([901, 71, 10 * 256 + 128, 4 * 256 + 128, 0])
	world._add([902, 72, 16 * 256 + 128, 4 * 256 + 128, 0, {"fa": 1}])
	var drill := ModelLibrary.mesh_for("x-drill")
	var wet := ModelLibrary.mesh_for("x-drill-wet@dir:Drills")
	_make_models(world.protos, cv)
	cv.build_entities(world.protos, {})
	var drawn := _drawn(cv)
	var wets: Array = drawn.get(wet, [])
	check(wet != null and wets.size() == 1 and (drawn.get(drill, []) as Array).size() == 2,
		"the -wet part over the drill with fa only (1 of 2 drills): %d" % wets.size())
	check((drawn.get(ModelLibrary.mesh_for("y-drill"), []) as Array).size() == 1 and drawn.size() == 3,
		"a drill whose pack has no -wet model: the drill alone (%d models drawn)" % drawn.size())
	# fa changing on the drill without it (`aiu`) draws its chunk again; the other bit alone doesn't.
	world._dirty.clear()
	world._on_alt_fluids([[901, 2]])
	check(world._dirty.is_empty(), "a drill's fa without bit 1 doesn't draw its chunk again")
	world._on_alt_fluids([[901, 1]])
	check(world._dirty.has(Vector2i.ZERO), "a drill's fa bit 1 arriving draws its chunk again")
	_make_models(world.protos, cv)
	cv.build_entities(world.protos, {})
	check((_drawn(cv).get(wet, []) as Array).size() == 2, "and then both drills with it have their -wet part")
	ModelLibrary.drill_wet = false
	cv.build_entities(world.protos, {})
	check(not _drawn(cv).has(wet), "--drill-wet=off: no -wet part")
	ModelLibrary.drill_wet = true
	cv.queue_free()
	world.chunks.clear()
	world.free()
	_fixture_packs_done()


## Scattered ore and window pipes, the edges (the testing agent's, vas-test): a tile's rock count at each of Factorio's
## stage edges (149/150 ... 14999/15000), and --ore-density=classic's 2/4/6; a record arriving again with an amount over an edge draws its chunk again with the new
## count; a depleted tile (`del`) takes its rocks away; a tile at negative coordinates keeps its rocks in its tile;
## `--ore-scatter=on` scatters a pack that asks not to and a whole-tile plain model; window pipes at negative
## coordinates follow posmod (x + y even), and a column's windows alternate the same way across y = 0.


func _ore_pipe_edges() -> void:
	var at_edges := func(amounts: Array, ore: String) -> Array:
		return amounts.map(func(n: int) -> int: return ModelLibrary.ore_rock_count(n, ore))
	var iron_at: Array = at_edges.call([0, 149, 150, 399, 400, 1299, 1300, 2899, 2900, 5499, 5500, 9499, 9500, 14999, 15000, 1000000], "")
	check(iron_at == [3, 3, 5, 5, 6, 6, 7, 7, 8, 8, 10, 10, 12, 12, 14, 14],
		"ore rocks at the 7 stage edges (150, 400, 1300, 2900, 5500, 9500, 15000): 3, 5, 6, 7, 8, 10, 12, 14: %s" % [iron_at])
	# Uranium's own edges, about a third lower (Factorio's 100, 270, 870, 1930, 3670, 6330, 10000): the rocks and the
	# stage model follow them.
	var uranium_at: Array = at_edges.call([49, 99, 100, 269, 270, 869, 870, 1929, 1930, 3669, 3670, 6329, 6330, 9999, 10000], "uranium-ore")
	check(uranium_at == [3, 3, 5, 5, 6, 6, 7, 7, 8, 8, 10, 10, 12, 12, 14]
		and ModelLibrary.ore_rock_count(1930, "iron-ore") == 7 and ModelLibrary.ore_rock_count(270, "iron-ore") == 5,
		"uranium's rocks at its own edges: %s (iron at 1930->7, 270->5)" % [uranium_at])
	ModelLibrary.ore_density = "classic"
	var classic_at: Array = at_edges.call([0, 399, 400, 2899, 2900, 1000000], "") + at_edges.call([269, 270, 1929, 1930], "uranium-ore")
	ModelLibrary.ore_density = "factorio"
	check(classic_at == [2, 2, 4, 4, 6, 6, 2, 4, 4, 6], "--ore-density=classic: 2/4/6 from 400 and 2900 (uranium 270, 1930): %s" % [classic_at])
	check(ModelLibrary.ore_rock_places(Vector2i(0, 0), Vector3.ZERO, 2000, 2, "uranium-ore").size() == 8
		and ModelLibrary.ore_rock_places(Vector2i(0, 0), Vector3.ZERO, 2000, 2, "iron-ore").size() == 7,
		"a uranium tile with 2000 left gets 8 rocks, an iron one 7")
	check(ModelLibrary.model_name("uranium-ore", "resource", {"a": 1930}) == "uranium-ore-rich"
		and ModelLibrary.model_name("uranium-ore", "resource", {"a": 269}) == "uranium-ore-sparse"
		and ModelLibrary.model_name("uranium-ore", "resource", {"a": 1000}) == "uranium-ore"
		and ModelLibrary.model_name("iron-ore", "resource", {"a": 1930}) == "iron-ore",
		"uranium's stage models at its own edges: 1930 rich, 269 sparse, 1000 plain (iron 1930 plain)")
	_fixture_packs("ui-test-ore-edges", {
		"Rocks": {"iron-ore-1": Vector3(0.36, 0.14, 0.31), "iron-ore-2": Vector3(0.36, 0.14, 0.27)},
		"Big": {"copper-ore": Vector3(1.4, 0.3, 1.4)},
		"Asks": {"stone-1": Vector3(0.3, 0.1, 0.3), "pack.json": "{\"name\": \"Asks\", \"ore_scatter\": false}"},
		"Windows": {"pipe-straight-horizontal": Vector3(1.0, 0.3, 0.3), "pipe-straight-vertical": Vector3(0.3, 0.3, 1.0),
			"pipe-straight-horizontal-window": Vector3(1.0, 0.4, 0.4), "pipe-straight-vertical-window": Vector3(0.4, 0.4, 1.0)}},
		["dir:Rocks", "dir:Big", "dir:Asks", "dir:Windows"])
	for i in 600:
		if ModelLibrary.ore_rocks("iron-ore") != null:
			break
		ModelLibrary.poll()
		await get_tree().process_frame
	var world := WorldMirror.new()
	world.protos.add_entities([[61, "iron-ore", "resource", -0.5, -0.5, 0.5, 0.5, 100, 120, 140, 1, 1],
		[43, "pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1]])
	var cv := ChunkView.new()
	var neg := ChunkView.new()
	world.chunks[Vector2i.ZERO] = cv
	world.chunks[Vector2i(-1, -1)] = neg
	add_child(cv)
	add_child(neg)
	var total := func(c: ChunkView) -> int:
		var n := 0
		for xf: Array in _drawn(c).values():
			n += xf.size()
		return n
	var rebuild := func(c: ChunkView) -> int:
		_make_models(world.protos, c)
		c.build_entities(world.protos, {})
		return total.call(c)
	world._add([0, 61, 5 * 256 + 128, 5 * 256 + 128, 0, {"a": 399}])
	var at_399: int = rebuild.call(cv)
	world._dirty.clear()
	world._add([0, 61, 5 * 256 + 128, 5 * 256 + 128, 0, {"a": 400}])
	var dirty_400 := world._dirty.has(Vector2i.ZERO)
	var at_400: int = rebuild.call(cv)
	world._add([0, 61, 5 * 256 + 128, 5 * 256 + 128, 0, {"a": 2899}])
	var at_2899: int = rebuild.call(cv)
	world._add([0, 61, 5 * 256 + 128, 5 * 256 + 128, 0, {"a": 2900}])
	var at_2900: int = rebuild.call(cv)
	check([at_399, at_400, at_2899, at_2900] == [5, 6, 7, 8] and dirty_400 and cv.entities.size() == 1,
		"one tile's record again with 399, 400, 2899, 2900: its chunk drawn again with 5, 6, 7, 8 rocks: %s (dirty %s, records %d)"
		% [[at_399, at_400, at_2899, at_2900], dirty_400, cv.entities.size()])
	world._add([0, 61, 6 * 256 + 128, 5 * 256 + 128, 0, {"a": 1000}])
	var two_tiles: int = rebuild.call(cv)
	world._dirty.clear()
	world.handle({"t": "del", "u": 0, "p": 61, "x": 5 * 256 + 128, "y": 5 * 256 + 128})
	var dirty_del := world._dirty.has(Vector2i.ZERO)
	var after_del: int = rebuild.call(cv)
	var near_after := 0
	for m: Mesh in cv._ore_near:
		near_after += int(cv._ore_near[m])
	check(two_tiles == 14 and dirty_del and after_del == 6 and near_after == 1,
		"a depleted tile (del): its chunk drawn again without its rocks: %d -> %d (first rank %d, dirty %s)"
		% [two_tiles, after_del, near_after, dirty_del])
	world.handle({"t": "del", "u": 0, "p": 61, "x": 6 * 256 + 128, "y": 5 * 256 + 128})
	var none_left: int = rebuild.call(cv)
	check(none_left == 0, "the last tile depleted: no rocks left in the chunk: %d" % none_left)
	# Negative coordinates: tile (-3, -7) in chunk (-1, -1).
	world._add([0, 61, -3 * 256 + 128, -7 * 256 + 128, 0, {"a": 5000}])
	var neg_rocks: int = rebuild.call(neg)
	var places := ModelLibrary.ore_rock_places(Vector2i(-3 * 256 + 128, -7 * 256 + 128), Vector3(-2.5, 0, -6.5), 5000, 2)
	var again := ModelLibrary.ore_rock_places(Vector2i(-3 * 256 + 128, -7 * 256 + 128), Vector3(-2.5, 0, -6.5), 5000, 2)
	var inside := places.all(func(p: Array) -> bool:
		return absf(p[1].origin.x + 2.5) <= 0.56 and absf(p[1].origin.z + 6.5) <= 0.56)
	check(neg_rocks == 8 and places.size() == 8 and inside and places == again,
		"a rich tile at (-3, -7): 8 rocks, each within its tile, the same twice: %d" % neg_rocks)
	# --ore-scatter=on: the pack that asks not to and the whole-tile copper model scatter too; auto again: not.
	ModelLibrary.ore_scatter = "on"
	var stone_on: Variant = null
	var copper_on: Variant = null
	for i in 600:
		stone_on = ModelLibrary.ore_rocks("stone")
		copper_on = ModelLibrary.ore_rocks("copper-ore")
		if stone_on != null and copper_on != null:
			break
		ModelLibrary.poll()
		await get_tree().process_frame
	ModelLibrary.ore_scatter = "auto"
	var stone_auto: Variant = ModelLibrary.ore_rocks("stone")
	var copper_auto: Variant = ModelLibrary.ore_rocks("copper-ore")
	check(stone_on is Array and (stone_on as Array).size() == 1 and copper_on is Array and (copper_on as Array).size() == 1
		and stone_auto is Array and (stone_auto as Array).is_empty() and copper_auto is Array and (copper_auto as Array).is_empty(),
		"--ore-scatter=on scatters a pack saying \"ore_scatter\": false and a whole-tile model; auto again doesn't: %s %s / %s %s"
		% [stone_on, copper_on, stone_auto, copper_auto])
	# Window pipes at negative coordinates: a row on y = -5 from x = -6 to 1 (all straights), and a column on x = -1
	# from y = -3 to 4, across both axes.
	for c in [Vector2i(0, -1), Vector2i(-1, 0)]:
		world.chunks[c] = ChunkView.new()
	var row_units: Array = []
	for i in 8:
		world._add([1000 + i, 43, (-6 + i) * 256 + 128, -5 * 256 + 128, 0, {"pc": 10}])
		row_units.append(1000 + i)
	var col_units: Array = []
	for i in 8:
		world._add([1100 + i, 43, -1 * 256 + 128, (-3 + i) * 256 + 128, 0, {"pc": 5}])
		col_units.append(1100 + i)
	var windowed := func(units: Array) -> Array:
		return units.map(func(u: int) -> bool:
			return ModelLibrary.model_name("pipe", "pipe", (world.entities[u] as WorldMirror.Rec).extra).ends_with("-window"))
	var want_row: Array = []
	for i in 8:
		want_row.append(posmod(-6 + i + -5, 2) == 0)
	var want_col: Array = []
	for i in 8:
		want_col.append(posmod(-1 + -3 + i, 2) == 0)
	var row: Array = windowed.call(row_units)
	var col: Array = windowed.call(col_units)
	check(row == want_row and row.count(true) == 4, "a row of straights at y -5, x -6..1: windows where x + y is even: %s" % [row])
	check(col == want_col and col.count(true) == 4, "a column at x -1, y -3..4 (across y = 0): windows alternate: %s" % [col])
	for c in [Vector2i(0, -1), Vector2i(-1, 0)]:
		(world.chunks[c] as ChunkView).free()
	world.chunks.clear()
	cv.queue_free()
	neg.queue_free()
	world.free()
	_fixture_packs_done()


## _pipe_end's edges (the testing agent's): a pipe removed at a chunk border (the neighbour across it, in its own chunk,
## unlinked and that chunk drawn again), beside a pipe-to-ground (its bridge-sent side goes), beside a storage tank (the
## tank's side isn't touched: a machine has no `pc`), a storage tank removed (not a pipe: its pipes wait for the bridge's
## `upd`), a ghost pipe removed beside real pipes (theirs kept: a ghost connects to nothing), a T losing its branch and a
## cross an arm, a heat pipe and a wall from a row (the client joins those itself), an `upd` in place (no unlinking).


func _pipe_end_edges() -> void:
	WorldMirror.pipe_end_now = true
	var world := WorldMirror.new()
	world.protos.add_entities([[43, "pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1],
		[44, "pipe-to-ground", "pipe-to-ground", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1],
		[45, "storage-tank", "storage-tank", -1.5, -1.5, 1.5, 1.5, 120, 120, 120, 3, 3],
		[46, "heat-pipe", "heat-pipe", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1],
		[47, "stone-wall", "wall", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1]])
	for cx in range(-1, 3):
		for cy in range(-1, 2):
			world.chunks[Vector2i(cx, cy)] = ChunkView.new()
	var at := func(tx: int, ty: int) -> Array: return [tx * 256 + 128, ty * 256 + 128]
	var pc_of := func(u: int) -> int:
		var r: WorldMirror.Rec = world.entities.get(u)
		return int(r.extra.get("pc", -1)) if r != null else -2
	var del := func(u: int, p: int, tx: int, ty: int) -> void:
		world.handle({"t": "del", "u": u, "p": p, "x": tx * 256 + 128, "y": ty * 256 + 128})
	# A chunk border at x = 32: pipes at 30..33, 31 removed; 32 (chunk 1) loses its west side.
	for i in 4:
		var p: Array = at.call(30 + i, 5)
		world._add([600 + i, 43, p[0], p[1], 0, {"pc": [2, 10, 10, 8][i]}])
	world._dirty.clear()
	del.call(601, 43, 31, 5)
	check(pc_of.call(600) == 0 and pc_of.call(602) == 2 and world._dirty.has(Vector2i(1, 0)) and world._dirty.has(Vector2i(0, 0)),
		"a pipe removed at a chunk border: both neighbours unlinked, the far chunk drawn again: %d %d %s" % [pc_of.call(600), pc_of.call(602), world._dirty.keys()])
	# Beside a pipe-to-ground facing it (west) and a storage tank: pipe 611 between them removed.
	var p1: Array = at.call(3, 10)
	world._add([610, 44, p1[0], p1[1], 4, {"pc": 2}])  # the pipe-to-ground at 3, its ground end east
	var p2: Array = at.call(4, 10)
	world._add([611, 43, p2[0], p2[1], 0, {"pc": 10}])
	world._add([612, 45, 6 * 256, 11 * 256, 0, {}])  # the tank over tiles 5..7, 10..12: its west connection at (5, 10)
	del.call(611, 43, 4, 10)
	check(pc_of.call(610) == 0, "a pipe removed beside a pipe-to-ground: its side towards it goes: %d" % pc_of.call(610))
	check(not (world.entities[612] as WorldMirror.Rec).extra.has("pc"), "and the tank beside it is left alone (no pc)")
	# The tank removed with a pipe on its connection: not a pipe, so the pipe waits for the bridge's `upd`.
	var p3: Array = at.call(4, 11)
	world._add([613, 43, p3[0], p3[1], 0, {"pc": 2}])
	world.handle({"t": "del", "u": 612, "p": 45, "x": 6 * 256, "y": 11 * 256})
	check(pc_of.call(613) == 2, "a storage tank removed: the pipe on its connection waits for the bridge's upd: %d" % pc_of.call(613))
	# A ghost pipe removed beside real pipes: theirs stay (a ghost connects to nothing).
	var g: Array = at.call(10, 15)
	world._add([620, 43, g[0], g[1], 0, {"gh": 43}])
	var a: Array = at.call(9, 15)
	world._add([621, 43, a[0], a[1], 0, {"pc": 8}])
	var b: Array = at.call(11, 15)
	world._add([622, 43, b[0], b[1], 0, {"pc": 2}])
	del.call(620, 43, 10, 15)
	check(pc_of.call(621) == 8 and pc_of.call(622) == 2, "a ghost pipe removed: the real pipes beside it keep theirs: %d %d" % [pc_of.call(621), pc_of.call(622)])
	# A T losing its branch is a straight, a cross losing an arm a T (the owner's second screenshot).
	for i in 3:
		var t: Array = at.call(14 + i, 20)
		world._add([630 + i, 43, t[0], t[1], 0, {"pc": [2, 14, 8][i]}])
	var br: Array = at.call(15, 21)
	world._add([633, 43, br[0], br[1], 0, {"pc": 1}])
	world.mined({"t": "mnd", "g": 1, "l": [], "u": 633, "p": 43, "x": br[0], "y": br[1]})
	check(ModelLibrary.model_name("pipe", "pipe", (world.entities[631] as WorldMirror.Rec).extra) == "pipe-straight-horizontal",
		"a T whose branch is mined is a straight at once: pc %d" % pc_of.call(631))
	var arm: Array = at.call(15, 19)
	world._add([634, 43, arm[0], arm[1], 0, {"pc": 4}])
	world._add([635, 43, br[0], br[1], 0, {"pc": 1}])
	world.handle({"t": "upd", "e": [631, 43, at.call(15, 20)[0], at.call(15, 20)[1], 0, {"pc": 15}]})
	world.mined({"t": "mnd", "g": 1, "l": [], "u": 634, "p": 43, "x": arm[0], "y": arm[1]})
	check(pc_of.call(631) == 14, "a cross whose north arm is mined is a T at once: pc %d" % pc_of.call(631))
	# An `upd` of a pipe in place unlinks nothing.
	world.handle({"t": "upd", "e": [630, 43, at.call(14, 20)[0], at.call(14, 20)[1], 0, {"pc": 2}]})
	check(pc_of.call(631) == 14, "an upd of a neighbour in place leaves the others alone: %d" % pc_of.call(631))
	# Heat pipes and walls: no shape from the bridge, the client joins them; the middle of a row of three removed.
	for i in 3:
		var h: Array = at.call(20 + i, 25)
		world._add([640 + i, 46, h[0], h[1], 0, {}])
		var w: Array = at.call(20 + i, 27)
		world._add([650 + i, 47, w[0], w[1], 0, {}])
	check(pc_of.call(640) == 2 and int((world.entities[650] as WorldMirror.Rec).extra.get("wc", -1)) == 2,
		"heat pipes and walls joined by the client (east end of the west piece): %d %s" % [pc_of.call(640), (world.entities[650] as WorldMirror.Rec).extra])
	del.call(641, 46, 21, 25)
	world.mined({"t": "mnd", "g": 1, "l": [], "u": 651, "p": 47, "x": at.call(21, 27)[0], "y": at.call(21, 27)[1]})
	check(pc_of.call(640) == 0 and pc_of.call(642) == 0, "a heat pipe removed from a row: its neighbours are lone pieces: %d %d" % [pc_of.call(640), pc_of.call(642)])
	var wcs := [int((world.entities[650] as WorldMirror.Rec).extra.get("wc", -1)), int((world.entities[652] as WorldMirror.Rec).extra.get("wc", -1))]
	check(wcs == [0, 0], "a wall mined from a row: its neighbours are pillars: %s" % [wcs])
	world.free()

## N9: Factorio 2.1's fluid pipeline visualization (pipeline_marks.gd): the pipeline found across pipes'
## `pc` sides, an underground pair and a tank's connections, stopping at a pump and a pipe not joined;
## tinted to its fluid, red when overextended; every pipeline round the cursor with a pipe held in
## Alt-mode; the switch and the settings; a 4,000-pipe pipeline found a slice a frame.


func _pipeline_vis(hud: Hud) -> void:
	const PipelineMarks := preload("res://scripts/player/pipeline_marks.gd")
	const FrameBudget := preload("res://scripts/world/frame_budget.gd")
	var m: UiModel = hud.ui.model
	var world := WorldMirror.new()
	world.pick_build_usec = 1 << 40
	world.protos.add_entities([
		[61, "pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1],
		[62, "pipe-to-ground", "pipe-to-ground", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1],
		[63, "storage-tank", "storage-tank", -1.5, -1.5, 1.5, 1.5, 120, 120, 120, 3, 3],
		[64, "pump", "pump", -0.5, -1.0, 0.5, 1.0, 120, 120, 120, 1, 2],
	])
	world.protos.fluid_colors["water"] = Color8(51, 102, 255)
	var eprops := {62: {"under": 10.0}, 63: {"x": {"fb": [[1, -1, 0, "b"], [1, 1, 4, "b"], [-1, 1, 8, "b"], [-1, -1, 12, "b"]]}},
		64: {"x": {"fb": [[0, -0.5, 0, "o"], [0, 0.5, 8, "i"]]}}}
	world.chunks[Vector2i.ZERO] = ChunkView.new()
	var t := func(x: float) -> int: return int(x * 256.0)
	# Pipes (0..2, 0) into a pipe to ground facing west at (3, 0), its partner facing east at (8, 0), a pipe
	# (9, 0) onto the tank's west connection (tank 10..12 x 0..2), a pump on its east one (13, 2) and a pipe
	# past the pump (15, 2); a pipe south of (1, 0) the bridge says isn't joined (pc 0), a lone pipe (5, 5).
	for i in 3:
		world._add([100 + i, 61, t.call(i + 0.5), t.call(0.5), 0])
	world._add([110, 62, t.call(3.5), t.call(0.5), 12])
	world._add([111, 62, t.call(8.5), t.call(0.5), 4])
	world._add([112, 61, t.call(9.5), t.call(0.5), 0])
	world._add([120, 63, t.call(11.5), t.call(1.5), 0])
	world._add([130, 64, t.call(14.0), t.call(2.5), 4])
	world._add([131, 61, t.call(15.5), t.call(2.5), 0])
	world._add([140, 61, t.call(1.5), t.call(1.5), 0, {"pc": 0}])
	world._add([141, 61, t.call(5.5), t.call(5.5), 0])
	var first: WorldMirror.Rec = world.entities.get(100)
	var f := PipelineMarks.segment_from(world, first, eprops)
	var units: Array = f.units.keys()
	units.sort()
	check(units == [100, 101, 102, 110, 111, 112, 120] and f.joints.size() == 5 and f.unders.size() == 1 and not f.capped,
		"N9: a pipeline runs across pipes' sides, an underground pair and into a tank, stopping at the pump and at a pipe not joined: %s, %d joints, %d pairs"
		% [units, f.joints.size(), f.unders.size()])
	var from_tank := PipelineMarks.segment_from(world, world.entities.get(120), eprops)
	check(from_tank.units.size() == 7 and not from_tank.units.has(130) and not from_tank.units.has(131),
		"N9: the same pipeline found from the tank: %s" % [from_tank.units.keys()])
	check(PipelineMarks.segment_from(world, world.entities.get(131), eprops).units.keys() == [131],
		"N9: the pipe past the pump is a pipeline of its own")
	# The bridge sends a tank's connections as `fj` (pipeline joins, no arrows), not `fb`: the tank joins its
	# line the same way (live_check pipevis: the game puts it in the pipes' segment); a bridge without `fj`
	# (none at all), the marks stop at the tank as before.
	var tank_fb: Array = eprops[63]["x"]["fb"]
	var with_fj := eprops.duplicate(true)
	with_fj[63] = {"x": {"fj": tank_fb}}
	var fj_units: Array = PipelineMarks.segment_from(world, first, with_fj).units.keys()
	fj_units.sort()
	var without := eprops.duplicate(true)
	without[63] = {"x": {}}
	var bare_units: Array = PipelineMarks.segment_from(world, first, without).units.keys()
	bare_units.sort()
	check(fj_units == units and bare_units == [100, 101, 102, 110, 111, 112]
		and PipelineMarks.segment_from(world, world.entities.get(120), without).units.keys() == [120],
		"N9: a tank joins its pipeline by the bridge's fj, and stands apart without it: %s, %s" % [fj_units, bare_units])

	var vis := PipelineMarks.new()
	vis.world = world
	var fp := FluidsPowerScript.new()
	fp.fluids = {101: [{"box": 0, "fluid": "water", "amount": 50, "capacity": 100, "temperature": 15}]}
	vis.fluids_power = fp
	vis.update(first, null, false, null, eprops, {}, [])
	var water := Color8(51, 102, 255)
	water.a = 0.9
	var want_surfs := 2 if PipelineMarks.show_pipe_joints else 1
	check(PipelineMarks.show_pipe_joints == Switches.has("--pipeline-joints=old"),
		"#10: PipelineMarks.show_pipe_joints is false by default and true with --pipeline-joints=old")
	check(vis.shown.size() == 1 and (vis.shown[0].color as Color).is_equal_approx(water)
		and vis.shown[0].mesh.visible and vis.shown[0].mesh.mesh.get_surface_count() == want_surfs,
		"N9: hovering a pipe shows its pipeline in the water's colour (%d surfaces): %s" % [
			vis.shown[0].mesh.mesh.get_surface_count() if not vis.shown.is_empty() else -1,
			vis.shown.map(func(s): return s.color)])
	if not PipelineMarks.show_pipe_joints:
		var was_joints := PipelineMarks.show_pipe_joints
		PipelineMarks.show_pipe_joints = true
		var f_old := PipelineMarks.segment_from(world, first, eprops)
		check(f_old.jv.size() > 0, "#10: --pipeline-joints=old restores pipe joint quads (%d verts)" % f_old.jv.size())
		PipelineMarks.show_pipe_joints = was_joints
	var seg = vis.shown[0]
	vis.update(world.entities.get(112), null, false, null, eprops, {}, [])
	check(vis.shown.size() == 1 and vis.shown[0] == seg, "N9: another pipe of it shows the same pipeline, not found again")
	vis.update(first, null, false, null, eprops, {"u": 100, "pl": [340, 320], "ox": 1}, [])
	check(vis.shown.size() == 1 and (vis.shown[0].color as Color).is_equal_approx(PipelineMarks.OVEREXTENDED),
		"N9: red when the hovered pipe's hinfo says overextended (ox)")
	fp.fluids = {}
	vis.update(first, null, false, null, eprops, {}, [])
	check((vis.shown[0].color as Color).is_equal_approx(PipelineMarks.EMPTY), "N9: white when empty")

	# Alt-mode with a pipe held: every pipeline round the cursor; one with a pipeline alert red.
	var pipe_proto: ProtoDB.EntityProto = world.protos.entity(61)
	var alerts := [{"kind": "pipeline", "count": 1, "entities": [{"unit": 141}]}]
	# Each update below is a frame of its own in the game: FrameBudget's per-frame floor cap starts again
	# (this section runs in one engine frame after others that used it up).
	FrameBudget.test_next_frame()
	vis.update(null, pipe_proto, true, Vector2(5, 5), eprops, {}, alerts)
	var lone = vis.shown.filter(func(s): return s.flood.units.has(141))
	check(vis.shown.size() == 4 and lone.size() == 1 and (lone[0].color as Color).is_equal_approx(PipelineMarks.OVEREXTENDED)
		and vis.shown.filter(func(s): return s.flood.units.has(100))[0].color.is_equal_approx(PipelineMarks.EMPTY),
		"N9: a pipe held in Alt-mode shows every pipeline in view (4), the one with the alert's entity red: %d" % vis.shown.size())
	vis.update(null, pipe_proto, false, Vector2(5, 5), eprops, {}, alerts)
	check(vis.shown.is_empty() and vis._segs.all(func(s): return not s.mesh.visible), "N9: not without Alt-mode")
	FrameBudget.test_next_frame()
	vis.update(null, world.protos.entity(64), true, Vector2(5, 5), eprops, {}, [])
	check(vis.shown.size() == 4, "N9: a pump held shows them too (a fluid entity)")
	Settings.set_value("interface", "fluid_vis", false, false)
	vis.update(null, pipe_proto, true, Vector2(5, 5), eprops, {}, [])
	check(vis.shown.is_empty(), "N9: \"Show fluid pipeline visualization\" off: none held")
	Settings.set_value("interface", "fluid_vis", true, false)
	Settings.set_value("interface", "fluid_vis_selected", false, false)
	vis.update(first, null, false, null, eprops, {}, [])
	check(vis.shown.is_empty(), "N9: \"... when selected\" off: none hovered")
	Settings.set_value("interface", "fluid_vis_selected", true, false)

	# Hovering a fluid entity that isn't a pipe (the pump): the pipelines on its connections.
	vis.update(world.entities.get(130), null, false, null, eprops, {}, [])
	check(vis.shown.size() == 2 and vis.shown.any(func(s): return s.flood.units.has(120)) and vis.shown.any(func(s): return s.flood.units.has(131)),
		"N9: hovering the pump shows the pipelines on both its connections (the tank's and the pipe past it): %d" % vis.shown.size())
	# A change in a chunk it read finds it again: the pump's pipe joined to the line.
	world._add([142, 61, t.call(15.5), t.call(1.5), 0, {"pc": 4}])
	vis.update(world.entities.get(131), null, false, null, eprops, {}, [])
	check(vis.shown.size() == 1 and vis.shown[0].flood.units.size() == 2, "N9: a pipe built onto a pipeline shows it again with it")

	PipelineMarks.on = false
	vis.update(first, pipe_proto, true, Vector2(5, 5), eprops, {"u": 100, "ox": 1}, alerts)
	check(vis.shown.is_empty() and vis._segs.all(func(s): return not s.mesh.visible), "--pipeline-vis=off: nothing drawn, as before")
	PipelineMarks.on = true
	vis.free()

	# Alt-mode: a pipeline whose far end's chunk loads later is found again once, not a second time over
	# itself from the new pipes (its marks drawn twice).
	var wd := WorldMirror.new()
	wd.pick_build_usec = 1 << 40
	wd.protos.add_entities([[61, "pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1]])
	wd.chunks[Vector2i.ZERO] = ChunkView.new()
	for i in 4:
		wd._add([300 + i, 61, t.call(28.5 + i), t.call(5.5), 0, {"pc": 10}])
	var visd := PipelineMarks.new()
	visd.world = wd
	visd.update(null, pipe_proto, true, Vector2(20, 5), eprops, {}, [])
	var first_n: int = visd.shown.size()
	wd.chunks[Vector2i(1, 0)] = ChunkView.new()
	for i in 4:
		wd._add([304 + i, 61, t.call(32.5 + i), t.call(5.5), 0, {"pc": 10}])
	for k in 3:
		visd.update(null, pipe_proto, true, Vector2(20, 5), eprops, {}, [])
	var holding: Array = visd._segs.filter(func(s): return s.flood.units.has(300) or s.flood.units.has(307))
	var drawn: Array = visd._segs.filter(func(s): return s.mesh.visible)
	check(first_n == 1 and visd.shown.size() == 1 and visd.shown[0].flood.units.size() == 8 and holding.size() == 1 and drawn.size() == 1,
		"N9: Alt-mode, the far chunk loading later: one pipeline of 8, drawn once (%d then %d shown, %d holding it, %d drawn)"
		% [first_n, visd.shown.size(), holding.size(), drawn.size()])
	visd.free()

	# A 4,000-pipe pipeline (of 4,500) found a slice a frame within its budget.
	var long := WorldMirror.new()
	long.pick_build_usec = 1 << 40
	long.protos.add_entities([[61, "pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1]])
	for c in range(0, 4500 / 32 + 1):
		long.chunks[Vector2i(c, 0)] = ChunkView.new()
	for i in 4500:
		long._add([1000 + i, 61, t.call(i + 0.5), t.call(0.5), 0])
	var big := PipelineMarks.new()
	big.world = long
	var head: WorldMirror.Rec = long.entities.get(1000)
	var frames := 0
	var worst := 0
	while big.shown.is_empty() and frames < 600:
		await get_tree().process_frame
		big.update(head, null, false, null, {}, {}, [])
		worst = maxi(worst, big.last_usec)
		frames += 1
	var slice := int(FrameBudget.SYSTEMS[&"pipelines"][1])
	check(big.shown.size() == 1 and big.shown[0].flood.nodes.size() == PipelineMarks.CAP and big.shown[0].flood.capped
		and frames > 1 and worst < slice + 3000,
		"N9: a 4,500-pipe pipeline is found to its cap of 4,000 over %d frames, at most %d µs a frame (slice %d)" % [frames, worst, slice])
	big.free()
	fp.free()


## N9, the testing agent's cases: chunk borders (loaded, not loaded yet, a pipe to ground pair across
## one), pipelines side by side, a tank joining two, heat pipes, the red clearing, the hills' shader,
## a quick hover between pipes, the two settings each alone and both, and a pipeline split by a mined pipe.


func _pipeline_vis_edges() -> void:
	const PipelineMarks := preload("res://scripts/player/pipeline_marks.gd")
	var t := func(x: float) -> int: return int(x * 256.0)
	var protos := [
		[61, "pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1],
		[62, "pipe-to-ground", "pipe-to-ground", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1],
		[63, "storage-tank", "storage-tank", -1.5, -1.5, 1.5, 1.5, 120, 120, 120, 3, 3],
		[65, "heat-pipe", "heat-pipe", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1],
	]
	var eprops := {62: {"under": 10.0}, 63: {"x": {"fb": [[1, -1, 0, "b"], [1, 1, 4, "b"], [-1, 1, 8, "b"], [-1, -1, 12, "b"]]}}}
	var new_world := func(chunk_list: Array) -> WorldMirror:
		var w := WorldMirror.new()
		w.pick_build_usec = 1 << 40
		w.protos.add_entities(protos)
		for c: Vector2i in chunk_list:
			w.chunks[c] = ChunkView.new()
		return w
	var units_of := func(f) -> Array:
		var u: Array = f.units.keys()
		u.sort()
		return u

	# A line of 8 pipes over the border of chunks (0, 0) and (1, 0): x 28..35.
	var w: WorldMirror = new_world.call([Vector2i(0, 0), Vector2i(1, 0)])
	for i in 8:
		w._add([200 + i, 61, t.call(28.5 + i), t.call(5.5), 0])
	var f = PipelineMarks.segment_from(w, w.entities.get(200), eprops)
	check(f.units.size() == 8 and f.chunks.has(Vector2i(1, 0)), "N9 edges: a pipeline across a chunk border is one: %s" % [units_of.call(f)])

	# Its far end in a chunk not loaded yet (no view, then a view with no records), the bridge's `pc` saying
	# the edge pipe goes on east: found to the edge, then whole once the far chunk's pipes come.
	for variant in ["no view", "empty view"]:
		var w2: WorldMirror = new_world.call([Vector2i(0, 0)] if variant == "no view" else [Vector2i(0, 0), Vector2i(1, 0)])
		for i in 4:
			w2._add([300 + i, 61, t.call(28.5 + i), t.call(5.5), 0, {"pc": 10}])
		var vis := PipelineMarks.new()
		vis.world = w2
		var root: WorldMirror.Rec = w2.entities.get(300)
		vis.update(root, null, false, null, eprops, {}, [])
		var before: int = vis.shown[0].flood.units.size() if vis.shown.size() == 1 else -1
		if variant == "no view":
			w2.chunks[Vector2i(1, 0)] = ChunkView.new()
		for i in 4:
			w2._add([304 + i, 61, t.call(32.5 + i), t.call(5.5), 0, {"pc": 10}])
		vis.update(root, null, false, null, eprops, {}, [])
		var after: int = vis.shown[0].flood.units.size() if vis.shown.size() == 1 else -1
		check(before == 4 and after == 8,
			"N9 edges (%s): a pipeline whose far end's chunk loads later is found again with it: %d then %d (8 wanted)" % [variant, before, after])
		vis.free()

	# A pipe to ground pair across the border: (30, 8) facing west, (35, 8) facing east, a pipe either side.
	var w3: WorldMirror = new_world.call([Vector2i(0, 0), Vector2i(1, 0)])
	w3._add([400, 61, t.call(29.5), t.call(8.5), 0])
	w3._add([401, 62, t.call(30.5), t.call(8.5), 12])
	w3._add([402, 62, t.call(35.5), t.call(8.5), 4])
	w3._add([403, 61, t.call(36.5), t.call(8.5), 0])
	var f3 = PipelineMarks.segment_from(w3, w3.entities.get(400), eprops)
	check(units_of.call(f3) == [400, 401, 402, 403] and f3.unders.size() == 1,
		"N9 edges: a pipe to ground pair across a chunk border joins its two halves: %s, %d pairs" % [units_of.call(f3), f3.unders.size()])
	# The same with the exit's chunk loading later.
	var w3b: WorldMirror = new_world.call([Vector2i(0, 0)])
	w3b._add([410, 61, t.call(29.5), t.call(8.5), 0])
	w3b._add([411, 62, t.call(30.5), t.call(8.5), 12])
	var vis3 := PipelineMarks.new()
	vis3.world = w3b
	vis3.update(w3b.entities.get(410), null, false, null, eprops, {}, [])
	var b3: int = vis3.shown[0].flood.units.size() if vis3.shown.size() == 1 else -1
	w3b.chunks[Vector2i(1, 0)] = ChunkView.new()
	w3b._add([412, 62, t.call(35.5), t.call(8.5), 4])
	w3b._add([413, 61, t.call(36.5), t.call(8.5), 0])
	vis3.update(w3b.entities.get(410), null, false, null, eprops, {}, [])
	var a3: int = vis3.shown[0].flood.units.size() if vis3.shown.size() == 1 else -1
	check(b3 == 2 and a3 == 4, "N9 edges: a pipe to ground's partner in a chunk that loads later joins once it comes: %d then %d" % [b3, a3])
	vis3.free()

	# Pipelines side by side: rows y 12 and 14 (a tile apart), and rows y 16 and 17 touching, which the
	# bridge's `pc` (east and west only) says aren't joined; and two pipes to ground side by side.
	var w4: WorldMirror = new_world.call([Vector2i(0, 0)])
	for i in 5:
		w4._add([500 + i, 61, t.call(2.5 + i), t.call(12.5), 0])
		w4._add([510 + i, 61, t.call(2.5 + i), t.call(14.5), 0])
		w4._add([520 + i, 61, t.call(2.5 + i), t.call(16.5), 0, {"pc": 10 if i > 0 and i < 4 else (2 if i == 0 else 8)}])
		w4._add([530 + i, 61, t.call(2.5 + i), t.call(17.5), 0, {"pc": 10 if i > 0 and i < 4 else (2 if i == 0 else 8)}])
	w4._add([540, 62, t.call(10.5), t.call(12.5), 0])  # facing north, open end north
	w4._add([541, 62, t.call(11.5), t.call(12.5), 0])
	var a4 = PipelineMarks.segment_from(w4, w4.entities.get(500), eprops)
	var b4 = PipelineMarks.segment_from(w4, w4.entities.get(510), eprops)
	var c4 = PipelineMarks.segment_from(w4, w4.entities.get(520), eprops)
	var d4 = PipelineMarks.segment_from(w4, w4.entities.get(530), eprops)
	var p4 = PipelineMarks.segment_from(w4, w4.entities.get(540), eprops)
	check(a4.units.size() == 5 and b4.units.size() == 5 and c4.units.size() == 5 and d4.units.size() == 5
		and not c4.units.has(530) and p4.units.keys() == [540],
		"N9 edges: pipelines side by side stay apart (a tile apart, touching but not joined, pipes to ground abreast): %d %d %d %d %s"
		% [a4.units.size(), b4.units.size(), c4.units.size(), d4.units.size(), p4.units.keys()])

	# A tank between two pipelines: pipes west of its west connection and east of its east one are one.
	var w5: WorldMirror = new_world.call([Vector2i(0, 0)])
	w5._add([600, 61, t.call(5.5), t.call(20.5), 0])
	w5._add([601, 61, t.call(6.5), t.call(20.5), 0])  # onto the tank's north-west port (dir 12 at -1,-1)
	w5._add([610, 63, t.call(8.5), t.call(21.5), 0])
	w5._add([620, 61, t.call(10.5), t.call(22.5), 0])  # onto its south-east port (dir 4 at 1,1)
	w5._add([621, 61, t.call(11.5), t.call(22.5), 0])
	var f5 = PipelineMarks.segment_from(w5, w5.entities.get(600), eprops)
	var g5 = PipelineMarks.segment_from(w5, w5.entities.get(621), eprops)
	check(units_of.call(f5) == [600, 601, 610, 620, 621] and units_of.call(g5) == units_of.call(f5),
		"N9 edges: a tank between two pipelines makes them one, found from either end: %s / %s" % [units_of.call(f5), units_of.call(g5)])

	# Heat pipes: a heat pipe line touching a pipe line isn't part of it, and hovering it shows nothing.
	var w6: WorldMirror = new_world.call([Vector2i(0, 0)])
	for i in 3:
		w6._add([700 + i, 61, t.call(2.5 + i), t.call(26.5), 0])
		w6._add([710 + i, 65, t.call(5.5 + i), t.call(26.5), 0])
	w6._add([713, 65, t.call(2.5), t.call(27.5), 0, {"pc": 1}])
	var f6 = PipelineMarks.segment_from(w6, w6.entities.get(700), eprops)
	var vis6 := PipelineMarks.new()
	vis6.world = w6
	vis6.update(w6.entities.get(711), null, false, null, eprops, {}, [])
	var heat_hover := vis6.shown.size()
	vis6.update(null, w6.protos.entity(65), true, Vector2(4, 26), eprops, {}, [])
	check(units_of.call(f6) == [700, 701, 702] and heat_hover == 0 and vis6.shown.is_empty()
		and not PipelineMarks.held_shows(w6.protos.entity(65), eprops),
		"N9 edges: heat pipes aren't fluid pipelines: not joined (%s), not shown hovered (%d) nor held in Alt-mode" % [units_of.call(f6), heat_hover])
	vis6.free()

	# The red clears once the alert goes (and the hover's `ox` with it).
	var vis7 := PipelineMarks.new()
	vis7.world = w
	var alert := [{"kind": "pipeline", "count": 1, "entities": [{"unit": 203}]}]
	vis7.update(w.entities.get(200), null, false, null, eprops, {}, alert)
	var red_on: bool = vis7.shown.size() == 1 and (vis7.shown[0].color as Color).is_equal_approx(PipelineMarks.OVEREXTENDED)
	vis7.update(w.entities.get(200), null, false, null, eprops, {}, [])
	var red_off: bool = vis7.shown.size() == 1 and (vis7.shown[0].color as Color).is_equal_approx(PipelineMarks.EMPTY)
	vis7.update(w.entities.get(200), null, false, null, eprops, {"u": 200, "ox": 1}, [])
	var ox_on: bool = (vis7.shown[0].color as Color).is_equal_approx(PipelineMarks.OVEREXTENDED)
	vis7.update(w.entities.get(200), null, false, null, eprops, {"u": 200, "pl": [8, 320]}, [])
	var ox_off: bool = (vis7.shown[0].color as Color).is_equal_approx(PipelineMarks.EMPTY)
	# `ox` of another pipe (hinfo still the last hovered one's) doesn't turn this pipeline red.
	vis7.update(w.entities.get(200), null, false, null, eprops, {"u": 999, "ox": 1}, [])
	var other_ox: bool = (vis7.shown[0].color as Color).is_equal_approx(PipelineMarks.EMPTY)
	check(red_on and red_off and ox_on and ox_off and other_ox,
		"N9 edges: red with the alert and gone with it (%s, %s); with ox and gone with it (%s, %s); not from another pipe's hinfo (%s)"
		% [red_on, red_off, ox_on, ox_off, other_ox])

	# The marks ride the hills: Factorio's overlay shader, lifted by ground_lift, just over the ground.
	# Use w3 (which has an underground pair so marks exist even when show_pipe_joints is false).
	vis7.world = w3
	vis7.update(w3.entities.get(400), null, false, null, eprops, {}, [])
	var mat: ShaderMaterial = vis7.shown[0].materials[0]
	var lifted: bool = mat.shader.resource_path == "res://shaders/ground_overlay.gdshader" \
		and mat.shader.code.contains("ground_lift(VERTEX") and mat.shader.code.contains("ground_height.gdshaderinc")
	var aabb: AABB = vis7.shown[0].mesh.mesh.get_aabb()
	check(lifted and absf(aabb.position.y - PipelineMarks.LIFT) < 0.001 and aabb.size.y < 0.001
		and vis7.shown[0].mesh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"N9 edges: the marks lie flat %.2f over the ground in the hills' overlay shader (ground_lift), no shadow" % aabb.position.y)
	vis7.free()

	# A quick hover between two pipelines: each found once, only the hovered one drawn, no new meshes or
	# finding while nothing changes.
	var vis8 := PipelineMarks.new()
	vis8.world = w4
	var ra: WorldMirror.Rec = w4.entities.get(500)
	var rb: WorldMirror.Rec = w4.entities.get(510)
	var ok8 := true
	for k in 40:
		var r: WorldMirror.Rec = ra if k % 2 == 0 else rb
		vis8.update(r, null, false, null, eprops, {}, [])
		var visible := vis8._segs.filter(func(s): return s.mesh.visible)
		if vis8.shown.size() != 1 or not vis8.shown[0].flood.units.has(r.unit) or visible.size() != 1 or visible[0] != vis8.shown[0]:
			ok8 = false
	var segs_now := vis8._segs.size()
	var children := vis8.get_child_count()
	var floods := {}
	for s in vis8._segs:
		floods[s.flood] = true
	vis8.update(null, null, false, null, eprops, {}, [])
	check(ok8 and segs_now == 2 and floods.size() == 2 and vis8._segs.all(func(s): return not s.mesh.visible),
		"N9 edges: hovering back and forth 40 frames draws only the hovered pipeline, each found once (%d kept, %d children), none left drawn after"
		% [segs_now, children])
	vis8.free()

	# A big pipeline being found when the hover moves on is dropped, its pipes free for the next asking.
	var wl: WorldMirror = new_world.call([])
	for c in range(0, 6000 / 32 + 1):
		wl.chunks[Vector2i(c, 0)] = ChunkView.new()
	for i in 6000:
		wl._add([5000 + i, 61, t.call(i + 0.5), t.call(0.5), 0])
	wl.chunks[Vector2i(0, 1)] = ChunkView.new()
	wl._add([9000, 61, t.call(3.5), t.call(40.5), 0])
	var vis9 := PipelineMarks.new()
	vis9.world = wl
	vis9.update(wl.entities.get(5000), null, false, null, {}, {}, [])
	var part_way: bool = vis9._job != null and vis9.shown.is_empty()
	vis9.update(wl.entities.get(9000), null, false, null, {}, {}, [])
	var moved: bool = vis9._job == null and vis9.shown.size() == 1 and vis9.shown[0].flood.units.keys() == [9000] \
		and not vis9._owner.has(5000) and not vis9._owner.has(5100)
	var frames := 0
	while frames < 200:
		vis9.update(wl.entities.get(5000), null, false, null, {}, {}, [])
		frames += 1
		if not vis9.shown.is_empty():
			break
	check(part_way and moved and vis9.shown.size() == 1 and vis9.shown[0].flood.units.size() == PipelineMarks.CAP,
		"N9 edges: a pipeline half found is dropped when the hover moves on (%s, %s) and found whole on coming back (%d frames)" % [part_way, moved, frames])
	vis9.free()

	# Alt-mode's steady cost with nothing changing, round the cursor's 25 chunks: rows of pipelines of 10
	# pipes, 2 a row, `rows` rows a chunk (2, 8 and 16: 100, 400 and 800 pipelines; 1,000 to 8,000 pipes).
	var steady_by := {}
	for rows in [2, 8, 16]:
		var wa: WorldMirror = new_world.call([])
		var unit := 20000
		for cy in range(-2, 3):
			for cx in range(-2, 3):
				wa.chunks[Vector2i(cx, cy)] = ChunkView.new()
				for row in rows:
					for half in 2:
						for i in 10:
							wa._add([unit, 61, t.call(cx * 32 + half * 16 + i + 0.5), t.call(cy * 32 + row * 2 + 0.5), 0])
							unit += 1
		var want_n: int = 25 * rows * 2
		var visa := PipelineMarks.new()
		visa.world = wa
		var held: ProtoDB.EntityProto = wa.protos.entity(61)
		var frames_a := 0
		while frames_a < 400:
			await get_tree().process_frame
			visa.update(null, held, true, Vector2(0, 0), eprops, {}, [])
			frames_a += 1
			if visa._job == null and visa._roots.is_empty() and visa.shown.size() == want_n:
				break
		var steady := 0
		for k in 20:
			visa.update(null, held, true, Vector2(0, 0), eprops, {}, [])
			steady = maxi(steady, visa.last_usec)
		steady_by[want_n] = [visa.shown.size(), frames_a, steady]
		print("N9 edges: Alt-mode over %d pipes in %d pipelines: found in %d frames, then %d µs a frame with nothing changing"
			% [want_n * 10, want_n, frames_a, steady])
		visa.free()
	check(steady_by.keys().all(func(n): return steady_by[n][0] == n and steady_by[n][2] < 1000),
		"N9 edges: Alt-mode with 100, 400 and 800 pipelines round the cursor shows them all, then costs under 1 ms a frame while nothing changes ([shown, frames, µs]: %s)"
		% [steady_by])

	# The two settings each alone, and both off.
	var vis10 := PipelineMarks.new()
	vis10.world = w4
	var hp: WorldMirror.Rec = w4.entities.get(500)
	var pipe61: ProtoDB.EntityProto = w4.protos.entity(61)
	var states := {}
	for combo in [[true, false], [false, true], [false, false]]:
		Settings.set_value("interface", "fluid_vis", combo[0], false)
		Settings.set_value("interface", "fluid_vis_selected", combo[1], false)
		vis10.update(hp, null, false, null, eprops, {}, [])
		var hovered_n := vis10.shown.size()
		vis10.update(null, pipe61, true, Vector2(4, 13), eprops, {}, [])
		var held_n := vis10.shown.size()
		states[str(combo)] = [hovered_n, held_n]
	Settings.set_value("interface", "fluid_vis", true, false)
	Settings.set_value("interface", "fluid_vis_selected", true, false)
	check(states[str([true, false])][0] == 0 and states[str([true, false])][1] > 0
		and states[str([false, true])][0] == 1 and states[str([false, true])][1] == 0
		and states[str([false, false])] == [0, 0],
		"N9 edges: only the held setting on: none hovered, all held; only the selected one: hovered, none held; both off: none (%s)" % [states])
	vis10.free()

	# A pipe mined out of the middle splits the pipeline in two; the cache follows.
	var w11: WorldMirror = new_world.call([Vector2i(0, 0)])
	for i in 9:
		w11._add([800 + i, 61, t.call(2.5 + i), t.call(30.5), 0])
	var vis11 := PipelineMarks.new()
	vis11.world = w11
	vis11.update(w11.entities.get(800), null, false, null, eprops, {}, [])
	var whole: int = vis11.shown[0].flood.units.size()
	w11._remove(804)
	vis11.update(w11.entities.get(800), null, false, null, eprops, {}, [])
	var west: Array = units_of.call(vis11.shown[0].flood) if vis11.shown.size() == 1 else []
	vis11.update(w11.entities.get(808), null, false, null, eprops, {}, [])
	var east: Array = units_of.call(vis11.shown[0].flood) if vis11.shown.size() == 1 else []
	check(whole == 9 and west == [800, 801, 802, 803] and east == [805, 806, 807, 808] and vis11._segs.all(func(s): return not s.flood.units.has(804)),
		"N9 edges: a pipe mined from the middle splits the pipeline: %d, then %s and %s" % [whole, west, east])
	vis11.free()

	# Review 1: a chunk the running search read changes before it finishes: what it shows is the new state.
	var wr: WorldMirror = new_world.call([])
	for c in range(0, 4500 / 32 + 1):
		wr.chunks[Vector2i(c, 0)] = ChunkView.new()
	for i in 4500:
		wr._add([30000 + i, 61, t.call(i + 0.5), t.call(0.5), 0])
	var vr := PipelineMarks.new()
	vr.world = wr
	var r1: WorldMirror.Rec = wr.entities.get(30000)
	await get_tree().process_frame
	vr.update(r1, null, false, null, {}, {}, [])
	var running: bool = vr._job != null
	wr._remove(30002)  # chunk (0, 0), read already: the line is cut after its second pipe
	var frames_r := 0
	while frames_r < 400:
		await get_tree().process_frame
		vr.update(r1, null, false, null, {}, {}, [])
		frames_r += 1
		if vr._job == null and vr._roots.is_empty() and not vr.shown.is_empty():
			break
	var got: Array = units_of.call(vr.shown[0].flood) if vr.shown.size() == 1 else []
	check(running and got == [30000, 30001],
		"N9 review: a pipe mined in a chunk the running search had read: the pipeline shown is the cut one (%s, %s)" % [running, got.slice(0, 4)])
	vr.free()

	# Review 2: a found pipeline keeps only what showing it needs (its search's queue, keys and marks let go).
	var m0 := OS.get_static_memory_usage()
	var fm = PipelineMarks.segment_from(wr, wr.entities.get(30003), {})
	var m1 := OS.get_static_memory_usage()
	PipelineMarks._shed(fm)
	var m2 := OS.get_static_memory_usage()
	check(fm.nodes.size() == PipelineMarks.CAP and fm.units.size() == PipelineMarks.CAP and not fm.chunks.is_empty()
		and fm.queue.is_empty() and fm.queued.is_empty() and fm.done_keys.is_empty() and fm.joints.is_empty() and fm.jv.is_empty()
		and m1 - m2 > 400000,
		"N9 review: a 4,000-entity pipeline found takes %.2f MB, %.2f MB of it let go once its mesh is made; its entities, units and chunks kept"
		% [(m1 - m0) / 1048576.0, (m1 - m2) / 1048576.0])

	# Review 3: a pipeline over the cap, held in Alt-mode, is found once in parts and not again while nothing changes.
	var wc: WorldMirror = new_world.call([])
	for c in 4:
		wc.chunks[Vector2i(c, 0)] = ChunkView.new()
	for i in 120:
		wc._add([40000 + i, 61, t.call(i + 0.5), t.call(2.5), 0])
	var vc := PipelineMarks.new()
	vc.world = wc
	vc.cap = 50
	var held_c: ProtoDB.EntityProto = wc.protos.entity(61)
	for k in 30:
		vc.update(null, held_c, true, Vector2(40, 2), eprops, {}, [])
		if vc._job == null and vc._roots.is_empty():
			break
	var made_then := vc.made_count
	var parts_then := vc.shown.size()
	for k in 10:
		var al := [{"kind": "pipeline", "entities": [{"unit": 40000 + k}]}] if k % 2 == 0 else []
		vc.update(null, held_c, true, Vector2(40, 2), eprops, {}, al)
	var covered := {}
	for s in vc.shown:
		for u in s.flood.units:
			covered[u] = true
	check(parts_then == 3 and made_then == 3 and vc.made_count == 3 and vc.shown.size() == 3 and covered.size() == 120,
		"N9 review: 120 pipes over a cap of 50 in Alt-mode: found once in %d parts covering %d, none found again over 10 changing frames (%d made)"
		% [parts_then, covered.size(), vc.made_count])
	vc.free()

	# Review 4: a search dropped unfinished gives back the entities it ran over to the pipeline that had them.
	var wo: WorldMirror = new_world.call([Vector2i(0, 0)])
	for i in 6:
		wo._add([50000 + i, 61, t.call(i + 2.5), t.call(3.5), 0])
	var vo := PipelineMarks.new()
	vo.world = wo
	var ro: WorldMirror.Rec = wo.entities.get(50000)
	vo.update(ro, null, false, null, eprops, {}, [])
	var seg_o = vo.shown[0]
	vo._job = PipelineMarks.Flood.new(wo, eprops, wo.entities.get(50005), PipelineMarks.CAP)
	vo._job.owner = vo._owner
	PipelineMarks.step(vo._job, 1 << 62)
	var taken: bool = vo._owner.get(50000) == vo._job
	vo._drop_job()
	var back: bool = range(6).all(func(i): return vo._owner.get(50000 + i) == seg_o.flood)
	var made_o := vo.made_count
	vo.update(null, null, false, null, eprops, {}, [])
	vo.update(wo.entities.get(50003), null, false, null, eprops, {}, [])
	check(taken and back and vo.shown.size() == 1 and vo.shown[0] == seg_o and vo.made_count == made_o,
		"N9 review: a dropped search's entities go back to the pipeline that held them (%s, %s), shown again without a new search" % [taken, back])
	vo.free()

	# Batch 2 #4: Alt-mode wide pipe range (world.view_radius vs RADIUS=2, --alt-pipe-range=old).
	var wr_w: WorldMirror = new_world.call([Vector2i(0, 0), Vector2i(3, 0)])
	wr_w.view_radius = 4
	wr_w.set_focus(Vector2(16.0, 16.0))
	wr_w._add([60001, 61, t.call(16.5), t.call(16.5), 0])
	wr_w._add([60002, 61, t.call(100.5), t.call(16.5), 0])  # chunk (3, 0), outside RADIUS=2
	var wr_vis := PipelineMarks.new()
	wr_vis.world = wr_w
	var was_wide := PipelineMarks.wide_range
	PipelineMarks.wide_range = true
	var wide_pipes := wr_vis._window_pipes(Vector2(16.5, 16.5))
	check(wide_pipes.size() == 2,
		"B2#4: wide_range includes Alt-mode pipes at chunk (3, 0) within view_radius=4 (%d pipes)" % wide_pipes.size())
	PipelineMarks.wide_range = false
	var narrow_pipes := wr_vis._window_pipes(Vector2(16.5, 16.5))
	check(narrow_pipes.size() == 1,
		"B2#4: --alt-pipe-range=old clamps Alt-mode pipes to RADIUS=2 chunk window (%d pipes)" % narrow_pipes.size())
	PipelineMarks.wide_range = was_wide
	wr_vis.free()
	wr_w.free()


func _pipe_fluid_icons() -> void:
	var overlay := preload("res://scripts/ui/factorio/alt_overlay.gd")
	for way in [Vector2i(1, 0), Vector2i(0, 1)]:
		var hits: Array[int] = []
		for i in 40:
			if overlay.pipe_shows_icon(Vector2i(-13, 7) + way * i):
				hits.append(i)
		var even := hits.size() == 8
		for k in range(1, hits.size()):
			even = even and hits[k] - hits[k - 1] == overlay.PIPE_ICON_EVERY
		check(even, "a straight run of pipes shows one icon in every %d tiles along %s: %s" % [overlay.PIPE_ICON_EVERY, way, hits])
	var stairs := 0
	for i in 40:
		if overlay.pipe_shows_icon(Vector2i(i / 2 + i % 2, i / 2)):
			stairs += 1
	check(stairs >= 4, "a staircase of pipes shows icons too: %d of 40" % stairs)


## Alt-mode's train stop names (stop_labels.gd): hidden in normal play by default (map mode only);
## with --stop-labels=alt enabled, shown over each stop near the focus while Alt-mode is on, rich text tags left out.
func _stop_labels() -> void:
	const StopLabelsScript := preload("res://scripts/world/stop_labels.gd")
	var world := WorldMirror.new()
	world.protos.add_entities([[44, "train-stop", "train-stop", -1, -1, 1, 1, 120, 120, 120, 2, 2]])
	world.chunks[Vector2i.ZERO] = ChunkView.new()
	world._add([601, 44, 6 * 256 + 128, 6 * 256 + 128, 0, {"n": "[item=iron-ore] Iron Pickup"}])
	world._add([602, 44, 10 * 256 + 128, 6 * 256 + 128, 0, {"n": ""}])
	var was_stop_on: bool = StopLabelsScript.enabled
	var labels = StopLabelsScript.new()
	labels.world = world
	StopLabelsScript.enabled = false
	labels.alt_mode = true
	labels._process(1.0)
	check(labels.shown() == 0, "train stop 3D names stay hidden in normal play by default even with Alt-mode on")
	StopLabelsScript.enabled = true
	labels.alt_mode = false
	labels._process(1.0)
	check(labels.shown() == 0, "no train stop names while Alt-mode is off (--stop-labels=alt)")
	labels.alt_mode = true
	labels._process(1.0)
	check(labels.shown() == 1 and labels._labels[0].text == "Iron Pickup",
		"Alt-mode (--stop-labels=alt) names a train stop (rich text tags left out, an unnamed one nothing): %d" % labels.shown())
	world._add([603, 44, 12 * 256 + 128, 8 * 256 + 128, 0, {"n": "Smelter"}])
	world.entities_changed.emit(Vector2i.ZERO)
	labels._process(1.0)
	check(labels.shown() == 2, "a stop built later is named too: %d" % labels.shown())
	labels.alt_mode = false
	labels._process(1.0)
	check(labels.shown() == 0, "and the names go with Alt-mode")
	StopLabelsScript.enabled = was_stop_on
	labels.free()
	world.free()


## K13: a repair pack (`iuse` "h") held, the left button on a building sends `repair` for it (its unit, the
## item, the held stack's slot), again only every REPEAT while it stays on it and at once on another; letting
## go sends `repair` without a target, once. Nothing goes without a repair tool. A worn pack's slot (its fifth
## value, durability in thousandths) shows Factorio's green durability bar; me's `rp` swings the character.


func _repair_pack(hud: Hud) -> void:
	PlayerInput.define_actions()
	var m: UiModel = hud.ui.model
	m.handle({"t": "iuse", "part": 1, "parts": 1, "l": [["repair-pack", "h", 2, 300], ["grenade", "c", "throw", 15, 6.5]]})
	check(m.is_repair_tool("repair-pack") and not m.is_repair_tool("grenade") and not m.is_repair_tool("")
		and m.item_uses["repair-pack"]["h"] == [2.0, 300.0], "K13: iuse's \"h\" marks a repair tool, with its speed and durability")
	var holder := Node3D.new()
	add_child(holder)
	var world := WorldMirror.new()
	holder.add_child(world)
	world.pick_build_usec = 1 << 40  # the whole pick index at once (see _predictions)
	world.protos.add_entities([[6, "wooden-chest", "container", -0.5, -0.5, 0.5, 0.5, 150, 110, 60, 1, 1]])
	world.chunks[Vector2i.ZERO] = ChunkView.new()
	world._add([7701, 6, 3 * 256 + 128, 2 * 256 + 128, 0])
	world._add([7702, 6, 5 * 256 + 128, 2 * 256 + 128, 0])
	var input := PlayerInput.new()
	input.world = world
	input.hud = hud
	input.has_ground = true
	sent()
	input.cursor_item = "repair-pack"
	input.cursor_quality = "normal"
	input._lmb_down = true
	input.ground = Vector2(3.5, 2.5)
	input._update_repair(0.016)
	var first := sent_one("repair")
	input._update_repair(0.016)
	var again := sent_one("repair")
	input._update_repair(PlayerInput.REPEAT)
	var repeated := sent_one("repair")
	input.ground = Vector2(5.5, 2.5)
	input._update_repair(0.016)
	var other := sent_one("repair")
	check(int(first.get("u", 0)) == 7701 and first.get("item") == "repair-pack" and int(first.get("x", 0)) == 3 * 256 + 128
		and again.is_empty() and int(repeated.get("u", 0)) == 7701 and int(other.get("u", 0)) == 7702,
		"K13: the left button held with a repair pack sends `repair` for the building under it, repeated, at once on another: %s %s %s %s"
		% [first, again, repeated, other])
	input._lmb_down = false
	input._update_repair(0.016)
	var stop := sent_one("repair")
	input._update_repair(0.016)
	var after := sent_one("repair")
	check(not stop.is_empty() and not stop.has("u") and after.is_empty() and input.repair_unit == 0,
		"K13: letting go sends one `repair` without a target: %s %s" % [stop, after])
	input.ground = Vector2(9.5, 9.5)
	input._lmb_down = true
	input._update_repair(0.016)
	var over_nothing := sent_one("repair")
	input.cursor_item = "grenade"
	input.ground = Vector2(3.5, 2.5)
	input._update_repair(0.016)
	var no_tool := sent_one("repair")
	input._lmb_down = false
	check(over_nothing.is_empty() and no_tool.is_empty(), "K13: nothing goes over empty ground, nor without a repair tool held")
	# N4: a car (a mover, picked by its own box, not a world record) under the mouse is repaired too,
	# and wins over the chest under it; the ray comes down onto it (the rig's pointer stands in for the mouse).
	var cars := MoverLayer.new()
	cars.protos = world.protos
	world.protos.add_entities([[8, "car", "car", -0.7, -1.0, 0.7, 1.0, 1, 1, 1, 2, 2]])
	holder.add_child(cars)
	cars.handle({"t": "mv", "k": 1, "l": [[9301, 8, 3 * 256 + 128, 2 * 256 + 128, 0]]})
	cars._process(1.0 / 60.0)
	var car_rig := CameraRig.new()
	holder.add_child(car_rig)
	car_rig.vr_pointer = [Vector3(3.5, 20.0, 2.5), Vector3.DOWN]
	input.movers = cars
	input.rig = car_rig
	input.cursor_item = "repair-pack"
	input.ground = Vector2(3.5, 2.5)
	input._lmb_down = true
	sent()
	input._update_repair(0.016)
	var on_car := sent_one("repair")
	input._lmb_down = false
	input._update_repair(0.016)
	sent()
	input.movers = null
	input.rig = null
	check(int(on_car.get("u", 0)) == 9301 and int(on_car.get("p", 0)) == 8 and int(on_car.get("x", 0)) == 3 * 256 + 128
		and int(on_car.get("y", 0)) == 2 * 256 + 128 and on_car.get("item") == "repair-pack",
		"N4: the left button with a repair pack on a car sends `repair` for the car: %s" % [on_car])
	check(cars.proto_near(Vector2i(3 * 256 + 128, 2 * 256 + 128), ["car"]) == 8,
		"N4: the repair sound's prototype is the car's at me's rx/ry")
	# The worn pack's slot: the bar, and freshness -1 (it doesn't spoil) read as none.
	var d: Array = UiModel._slot_dicts([["repair-pack", 4, "normal", -1, 650], ["yumako", 5, "normal", 640]])
	var slot := Slot.new()
	slot.set_extra(d[0])
	check(is_equal_approx(float(d[0].get("durability", -1.0)), 0.65) and not d[0].has("freshness")
		and is_equal_approx(float(d[1].get("freshness", -1.0)), 0.64) and not d[1].has("durability")
		and is_equal_approx(slot.durability, 0.65) and slot.freshness < 0.0,
		"K13: a worn tool's slot carries its durability (the green bar), -1 freshness is none: %s" % [d])
	slot.free()
	input.free()
	holder.queue_free()


## `ih` (inserter hands) took about 0.9 ms a message, most of it _bind looking each arm's model placement up for
## every hand of every update: --ih-apply=quick binds again only when the record, its direction, position or
## pack, or the models in use changed, and an arm's place in the preplan queue is a flag. What is drawn is
## the same as --ih-apply=old.
