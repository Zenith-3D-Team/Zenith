extends "res://tests/ui_test_base.gd"
## UI test sections: icons.

func _check_ride(cam_rig, viewer, ui) -> void:
	var rider := Avatar.new()
	add_child(rider)
	rider.snap_to(Vector2(4, 1))
	viewer.avatar = rider
	cam_rig.target = rider
	var lock := Node.new()  # stands in for player_input: the ride turns its processing off
	add_child(lock)
	lock.set_process(true)
	var ride := Ride.new()
	ride.avatar = rider
	ride.rig = cam_rig
	ride.ui = ui
	ride.input = lock
	add_child(ride)
	var me := func(extra: Dictionary) -> Dictionary:
		var m := {"t": "me", "u": 7, "x": 0, "y": 0, "d": 0, "w": 0, "hp": 250, "q": 0}
		m.merge(extra, true)
		return ride.handle_me(m)
	var silo := Vector2(11.5, -0.5)
	var held: Dictionary = me.call({"x": 2944, "y": -1352, "pod": 50, "ps": "awaiting_launch", "up": 1, "gx": 2944, "gy": -128})
	check(ride.state == Ride.BOARDING and held["x"] == 4 * 256 and held["w"] == 1 and not lock.is_processing()
		and cam_rig.target != rider and cam_rig.in_cinematic(),
		"ride: the character walks into the rocket from where it stood, input locked, the camera on the silo (#10)")
	for i in 90:
		ride._process(1.0 / 60.0)
	check(ride.state == Ride.UP and not rider.visible, "ride: inside the rocket the character is hidden")
	me.call({"x": 2944, "y": -128 - 100 * 256, "pod": 50, "ps": "ascending", "up": 1, "gx": 2944, "gy": -128})
	for i in 60:
		ride._process(1.0 / 60.0)
	var climbed: float = ride._height
	me.call({"x": 2944, "y": -128 - 200 * 256, "pod": 50, "ps": "surface_transition", "up": 1, "gx": 2944, "gy": -128})
	for i in 60:
		ride._process(1.0 / 60.0)
	check(climbed > 80.0 and ride.fade() > 0.9, "ride: the rocket climbs on the game's height (%.0f tiles) and the view fades out high up" % climbed)
	me.call({"x": -40 * 256, "y": -40 * 256, "pod": 50, "ps": "descending", "up": 0, "gx": 0, "gy": 0})
	check(ride.state == Ride.ARRIVING and is_equal_approx(ride._height, 40.0), "ride: in space the pod comes down onto the hub")
	me.call({"x": 0, "y": 0, "hub": 44})
	for i in 10:
		ride._process(1.0 / 60.0)
	check(ride.state == Ride.IN_HUB and ui.remote and ui.in_hub() and lock.is_processing() and not rider.visible
		and not cam_rig.in_cinematic(), "in the hub: the remote view round it, input back, no avatar (#17)")
	ui.end_remote_view()
	check(ui.remote and ui.in_hub(), "in the hub: leaving the remote view comes back to the hub, not the character (#17)")
	check(ui._at_hub() and not ui.escape(), "in the hub: Esc on the hub itself goes on to the game menu")
	me.call({"x": -512, "y": 0, "pod": 51, "ps": "awaiting_launch", "up": 1, "gx": 0, "gy": 0})
	check(ride.state == Ride.LEAVING and not ui.in_hub() and not lock.is_processing(), "land: out of the hub into a pod, input locked")
	me.call({"x": 108 * 256, "y": -230 * 256, "pod": 51, "ps": "descending", "up": 0, "gx": 0, "gy": 0})
	me.call({"x": 0, "y": 0, "pod": 51, "ps": "descending", "up": 0, "gx": 0, "gy": 0})
	me.call({"x": -102, "y": -102})
	for i in 10:
		ride._process(1.0 / 60.0)
	check(ride.state == Ride.IDLE and rider.visible and cam_rig.target == rider and lock.is_processing() and not ui.remote
		and rider.ground_position().distance_to(Vector2(-0.4, -0.4)) < 0.05, "land: the character steps out where the pod came down")
	ride.queue_free()
	lock.queue_free()
	rider.queue_free()


func _planet_spin() -> void:
	var spin := PlanetSpinScript.new()
	spin.heard(6000.0, [["vulcanus", 5400, 25000, 0], ["nauvis", 25200, 50000, 0]])
	check(absf(spin.turns("vulcanus") - 0.25) < 1e-5 and absf(spin.turns("nauvis") - 0.5) < 1e-5,
		"a planet's turn is its surface's daytime: %.5f %.5f" % [spin.turns("vulcanus"), spin.turns("nauvis")])
	# The drawn clock settles about a frame ahead of the game (game_clock.gd): a second to settle, then
	# one game second at 60 UPS measured.
	for i in 60:
		spin.advance(1.0 / 60.0)
	spin.heard(6060.0, [["vulcanus", 5400, int(round((0.25 + 60.0 / 5400.0) * 100000.0)), 0],
		["nauvis", 25200, int(round((0.5 + 60.0 / 25200.0) * 100000.0)), 0]])
	var v0 := spin.angle("vulcanus")
	var n0 := spin.angle("nauvis")
	for i in 60:
		spin.advance(1.0 / 60.0)
	var v_deg := rad_to_deg(spin.angle("vulcanus") - v0)
	var n_deg := rad_to_deg(spin.angle("nauvis") - n0)
	check(absf(v_deg - 360.0 / 90.0) < 0.01 and absf(n_deg - 360.0 / 420.0) < 0.01,
		"a game second turns Vulcanus 360 degrees / 90 s and Nauvis 360 / 420 s: %.4f %.4f" % [v_deg, n_deg])
	# An update 0.01 turn ahead of the drawn planet: no jump, then eased onto the game's.
	var at := 0.25 + 120.0 / 5400.0 + 0.01
	var before := spin.turns("vulcanus")
	spin.heard(6120.0, [["vulcanus", 5400, int(round(at * 100000.0)), 0]])
	var no_jump := absf(spin.turns("vulcanus") - before) < 1e-4
	for s in 4:
		for i in 60:
			spin.advance(1.0 / 60.0)
		spin.heard(6180.0 + 60.0 * s, [["vulcanus", 5400, int(round((at + (60.0 + 60.0 * s) / 5400.0) * 100000.0)), 0]])
	var want := fposmod(at + 240.0 / 5400.0, 1.0)
	# Within a couple of ticks (the drawn clock's frame ahead): 0.01 turn would be 54.
	check(no_jump and absf(spin.turns("vulcanus") - want) < 5e-4,
		"phase-locked to the daytime: an update eased in without a jump: %.5f, want %.5f" % [spin.turns("vulcanus"), want])
	for i in 60:
		spin.advance(1.0 / 60.0)
	spin.heard(6420.0, [["vulcanus", 5400, 80000, 0]])
	check(absf(spin.turns("vulcanus") - 0.8) < 5e-4, "a jump in the time of day is taken at once: %.4f" % spin.turns("vulcanus"))
	# Paused: no updates, the clock holds at its limit and the planet with it.
	for i in 240:
		spin.advance(1.0 / 60.0)
	var held := spin.turns("vulcanus")
	for i in 120:
		spin.advance(1.0 / 60.0)
	check(is_equal_approx(spin.turns("vulcanus"), held), "a paused game holds the planet where it is")
	var frozen := PlanetSpinScript.new()
	frozen.heard(100.0, [["aquilo", 72000, 30000, 1]])
	for s in 3:
		for i in 60:
			frozen.advance(1.0 / 60.0)
		frozen.heard(160.0 + 60.0 * s, [["aquilo", 72000, 30000, 1]])
	check(absf(frozen.turns("aquilo") - (0.3 + 180.0 / 72000.0)) < 1e-4,
		"with its time of day frozen a planet still turns: %.5f" % frozen.turns("aquilo"))
	var unheard := PlanetSpinScript.new()
	var u0 := unheard.turns("gleba")
	for i in 60:
		unheard.advance(1.0 / 60.0)
	check(absf(rad_to_deg(unheard.angle("gleba")) - rad_to_deg(u0 * TAU) - 360.0 / 600.0) < 0.01,
		"before any update a planet turns at Factorio's own day length (Gleba's 10 minutes)")


## Nauvis's enemies' skins and poses (I23): each tier's carapace is its sprite's mask layers per vertex
## under the tier's own tints from the prototypes (creature_skins.json, skin_mode 1 for biters and
## spitters, 2 for worms and spawners); walking models carry their knees, the walk's bend and their
## attack and corpse poses' legs (creature_rigs.json, creature_poses.json); a biting or spitting
## creature and a dying one are drawn with the walking model, its legs blended into the pose (the
## instance's custom data a), not swapped to the pose's model.
## Trees' crowns as pollution takes them (tools/models/nature: clumps of leaf cards round dark cores,
## UV -1 a core, -2 solid leaves): merged into one material the cores share the cards' leaf surface
## without its leaf_core reaching the cards; a tree's shadow stand-in casts its crown from a surface
## of its own (cards drawn in to their spray, cores and solid leaves marked) in a shader that drops
## them; tree-06's strands are leaves too; the spruce has no green cap left on top.


func _icons(hud: Hud) -> void:
	var ui = hud.ui
	var m = ui.model
	m.handle({"t": "slots", "l": {"main": [["blueprint-book", 1], ["blueprint", 1], ["iron-plate", 10], 0, 0, 0, 0, 0, 0, 0]},
		"ic": [[1, [["item", "iron-plate"], ["virtual", "signal-A"]]], [2, [["item", "transport-belt"]]]]})
	check(m.main_slots[0].get("icons") == [["item", "iron-plate"], ["virtual", "signal-A"]] and not m.main_slots[2].has("icons"),
		"slots' ic gives a book its icons, and nothing else any")
	ui.toggle_inventory()
	await get_tree().process_frame
	var book_slot: Slot = ui.window._grid.get_child(0)
	var plate_slot: Slot = ui.window._grid.get_child(2)
	check(book_slot.item == "blueprint-book" and book_slot.record_icons.size() == 2 and plate_slot.record_icons.is_empty(),
		"the inventory's book slot draws its two icons over the book (owner's #13)")
	ui.close_all()
	var bar: Array = []
	bar.resize(100)
	bar.fill("")
	bar[0] = "blueprint-book"
	m.handle({"t": "qb", "p": 1, "sel": 0, "held": "", "l": bar})
	await get_tree().process_frame
	ui.quickbar.refresh()
	var pinned: Slot = ui.quickbar._slots[0]
	check(pinned.item == "blueprint-book" and pinned.record_icons.size() == 2, "a book pinned to the quickbar shows its icons too: %s" % [pinned.record_icons])
	bar[0] = ""
	m.handle({"t": "qb", "p": 1, "sel": 0, "held": "", "l": bar})
	m.handle({"t": "slots", "l": {"main": [["blueprint-book", 1], 0, 0, 0, 0, 0, 0, 0, 0, 0]}})
	check(not m.main_slots[0].has("icons"), "icons cleared again without ic")
	# #23: a filter inserter's Alt-mode icon shows every filter, shrunk to fit the one icon's room.
	var filter_rec := WorldMirror.Rec.new()
	filter_rec.extra = {"ai": ["item", "iron-plate", ["copper-plate", "coal", "stone", "wood"]]}
	check(WorldMirror.alt_icon(filter_rec) == ["item", "iron-plate", "copper-plate", "coal", "stone", "wood"],
		"a record's extra filters are kept: %s" % [WorldMirror.alt_icon(filter_rec)])
	var fits := true
	for n in range(1, 6):
		var cells: Array = AltOverlay.grid(n)
		var rects: Array[Rect2] = []
		for c in cells:
			rects.append(Rect2(c[0], Vector2(c[1], c[1])))
		for i in rects.size():
			fits = fits and Rect2(0, 0, 1, 1).grow(0.0001).encloses(rects[i])
			for j in range(i + 1, rects.size()):
				fits = fits and rects[i].intersection(rects[j]).get_area() < 0.0001
	check(fits and AltOverlay.grid(1)[0][1] == 1.0 and AltOverlay.grid(2)[0][1] == 0.5 and AltOverlay.grid(5)[0][1] == 1.0 / 3.0,
		"1 to 5 filters fit in the icon's square without overlapping (one alone keeps the full size)")
	# C9: in first person the icons are 3D quads with the depth test on, so buildings hide them.
	var holder := Node3D.new()
	add_child(holder)
	var w3 := WorldMirror.new()
	holder.add_child(w3)
	w3.protos.add_entities([[8, "assembling-machine-1", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3]])
	w3.chunks[Vector2i.ZERO] = ChunkView.new()
	w3._add([950, 8, 5 * 256 + 128, 5 * 256 + 128, 0, {"ai": ["item", "iron-plate", ["coal"]]}])
	var fp_gs := GDScript.new()
	fp_gs.source_code = "extends Node3D\nvar world\nvar rig\nvar camera: Camera3D\nvar first_person := true\n"
	fp_gs.reload()
	var fp_rig: Node3D = fp_gs.new()
	fp_rig.camera = Camera3D.new()
	fp_rig.add_child(fp_rig.camera)
	holder.add_child(fp_rig)
	var fp_player: Node3D = fp_gs.new()
	fp_player.world = w3
	fp_player.rig = fp_rig
	var overlay := AltOverlay.new()
	overlay.model = m
	overlay.player = fp_player
	overlay.on = true
	add_child(overlay)
	fp_rig.camera.position = Vector3(5.5, 1.6, 14)
	fp_rig.camera.look_at(Vector3(5.5, 1.0, 5.5))
	alt_collect(overlay)
	var shown_quads := overlay._quads.filter(func(q): return q.visible)
	check(shown_quads.size() == 2 and (shown_quads[0].material_override as ShaderMaterial).shader == load("res://shaders/billboard_icon_depth.gdshader")
		and shown_quads[0].position.y > 1.0, "first person: Alt-mode icons are depth-tested quads over the building (C9)")
	fp_rig.first_person = false
	overlay._quads_used = 0
	overlay._hide_quads()
	# #9: from above, only chunks in the camera's view are looked at; a machine far off draws nothing.
	w3.chunks[Vector2i(40, 40)] = ChunkView.new()
	w3._add([951, 8, 40 * 32 * 256 + 128, 40 * 32 * 256 + 128, 0, {"ai": ["recipe", "iron-gear-wheel"]}])
	fp_rig.camera.position = Vector3(5.5, 30, 12)
	fp_rig.camera.look_at(Vector3(5.5, 0, 5.5))
	alt_collect(overlay)
	check(overlay.drawn == 2 and AltOverlay._chunk_in_view(Vector2i.ZERO, fp_rig.camera.get_frustum())
		and not AltOverlay._chunk_in_view(Vector2i(40, 40), fp_rig.camera.get_frustum()),
		"Alt-mode draws the icons in view (an inserter's two filters) and skips chunks out of view: %d" % overlay.drawn)
	# On an add-on's hills (ground_height.gd) the icons sit over the lifted building, not on the flat ground.
	fp_rig.camera.position = Vector3(5.5, 12, 30)
	fp_rig.camera.look_at(Vector3(5.5, 0, 5.5))
	alt_collect(overlay)
	var flat_icon: Rect2 = (overlay._icons.values()[0] as Array)[0]
	var hill := Image.create(16, 16, false, Image.FORMAT_RF)
	hill.fill(Color(6.0, 0, 0))
	var GroundHeightT := preload("res://scripts/world/ground_height.gd")
	GroundHeightT.set_field(hill, Vector2(-8, -8), 2.0)
	alt_collect(overlay)
	var hill_icon: Rect2 = (overlay._icons.values()[0] as Array)[0]
	var lifted: float = fp_rig.camera.unproject_position(Vector3(5.5, 6.0, 5.5)).y - fp_rig.camera.unproject_position(Vector3(5.5, 0.0, 5.5)).y
	GroundHeightT.clear()
	check(overlay.drawn == 2 and absf((hill_icon.position.y - flat_icon.position.y) / lifted - 1.0) < 0.2 and lifted < -5.0,
		"Alt-mode icons rise with the hill under their building: %.1f px (the hill: %.1f)" % [hill_icon.position.y - flat_icon.position.y, lifted])
	# J6: a chest's contents (`ac`) over it, smaller than a machine's icon (0.7, its prototype's
	# icon_draw_specification); a machine with an icon of its own keeps that; an answer to another
	# turning on of Alt-mode is dropped, and nothing is drawn once it is off.
	w3.protos.add_entities([[9, "wooden-chest", "container", -0.35, -0.35, 0.35, 0.35, 150, 120, 80, 1, 1]])
	w3._add([952, 9, 8 * 256 + 128, 5 * 256 + 128, 0])
	var turns_before: int = Bridge.alt_contents
	Bridge.set_alt_contents(true)
	w3.handle({"t": "ac", "g": Bridge.alt_contents, "l": [[952, "stone"], [950, "wood"]]})
	w3.handle({"t": "ac", "g": Bridge.alt_contents + 7, "l": [[952, "copper-plate"]]})
	alt_collect(overlay)
	var chest_tiles: float = AltOverlay._tiles_for(w3, w3.entities[952])
	var machine_tiles: float = AltOverlay._tiles_for(w3, w3.entities[950])
	check(overlay.drawn == 3 and w3.alt_contents_now().get(952) == ["stone"] and overlay._icons.has(Kit.item_icon("stone"))
		and not overlay._icons.has(Kit.item_icon("wood")) and is_equal_approx(chest_tiles, 0.84) and is_equal_approx(machine_tiles, 1.2),
		"J6: a chest shows what it holds (ac) at a chest's icon size, a machine keeps its own icon: %d drawn, %.2f / %.2f tiles" % [overlay.drawn, chest_tiles, machine_tiles])
	w3.handle({"t": "ac", "g": Bridge.alt_contents, "l": [[952]]})
	alt_collect(overlay)
	var cleared := overlay.drawn
	w3.handle({"t": "ac", "g": Bridge.alt_contents, "l": [[952, "coal", ["stone", "wood"]]]})
	Bridge.set_alt_contents(false)
	alt_collect(overlay)
	check(cleared == 2 and overlay.drawn == 2 and w3.alt_contents_now().is_empty(),
		"J6: [unit] clears a chest's icons, and Alt-mode off draws none: %d %d" % [cleared, overlay.drawn])
	if turns_before > 0:
		Bridge.set_alt_contents(true)
	overlay.on = false
	overlay._process(0.0)
	check(overlay._quads.all(func(q): return not q.visible), "and none are left in the world once Alt-mode is off")
	overlay.queue_free()
	holder.queue_free()
	var techs: Dictionary = ItemIcons.index().get("technology", {})
	check(techs.size() > 250 and techs.has("recycling") and techs.has("planet-discovery-vulcanus") and techs.has("follower-robot-count-1"),
		"icons.json has every technology's icon, those technology.lua doesn't name too: %d" % techs.size())
	check((techs.get("physical-projectile-damage-1", []) as Array).size() == 2, "a bonus technology's icon is its picture and the badge")
	# C10: copper wires between poles ride with the chart and are drawn with the electric layer.
	m.handle({"t": "chart", "cx": 0, "cy": 0, "n": 1, "pal": [[20, 220, 40]], "px": [0],
		"ov": [["e", 5 * 256, 5 * 256, 2.5], ["w", 5 * 256, 5 * 256, 12 * 256, 5 * 256]]})
	var wire_entries: Array = (m.map_overlays.get(Vector2i(0, 0), []) as Array).filter(func(r): return str(r[0]) == "w")
	check(wire_entries.size() == 1 and is_equal_approx(float(wire_entries[0][3]), 12.0) and is_equal_approx(float(wire_entries[0][4]), 5.0),
		"a chart's copper wire keeps both ends, in tiles (C10): %s" % [wire_entries])
	ui.map_view.layers.redraw(Vector2(8, 5), 8.0)
	await get_tree().process_frame
	# C15: the minimap preloads what the map view shows on opening, once in a while, when idle.
	var mm = ui.minimap
	var mcache = ui.map_cache
	mcache._blocks.clear()
	mcache._pending.clear()
	mm._preloading = false
	mm._preloaded_at = -1e9
	var own := Rect2i(-1, -1, 3, 3)
	mm._ask(own, 4, Vector2.ZERO)
	var big: Rect2i = mcache._goal
	var preloading_now: bool = mm._preloading
	mcache._blocks.clear()
	mcache._pending.clear()
	mm._ask(own, 4, Vector2.ZERO)
	mm._ask(own, 4, Vector2.ZERO)
	var half_view: Vector2 = mm.get_viewport_rect().size / 2.0 / (mm.PRELOAD_ZOOM * Kit.scale)
	var expected: Rect2i = MapCache.chunks_of(Rect2(-half_view, half_view * 2.0))
	check(preloading_now and big == expected and not mm._preloading and mcache._goal == own,
		"the minimap asks once for the map view's opening area, then for its own again (C15): %s then %s" % [big, mcache._goal])
	mm._ask(own, 4, Vector2.ZERO)
	check(not mm._preloading, "and not again until PRELOAD_EVERY has passed")
	mcache._blocks.clear()
	mcache._pending.clear()
	mcache.spots.clear()
	mcache.spots.append(Rect2i(40, 40, 3, 3))
	mm._ask(own, 4, Vector2.ZERO)
	check(mcache._goal == Rect2i(40, 40, 3, 3) and mcache.spots.is_empty(), "a train card's spot is charted by the minimap when idle (C8)")
	mcache._blocks.clear()
	mcache._pending.clear()
	mm._ask(own, 4, Vector2.ZERO)
	mm._ask(own, 4, Vector2.ZERO)
	# #4: demolisher territories' borders, from `terr` in two parts: two chunks side by side have six
	# outer sides (the shared one isn't a border); a lone chunk four.
	m.handle({"t": "terr", "part": 1, "parts": 2, "l": [[1, 2, 2, 2]]})
	var after_first: int = m.territory_edges.size()
	m.handle({"t": "terr", "part": 2, "parts": 2, "l": [[-5, 0]]})
	check(after_first == 0 and m.territory_edges.size() == 20 and m.territory_edges.has(Vector2(32, 64)),
		"terr parts make the territories' borders, in tiles (owner's #4): %d points" % m.territory_edges.size())
	var terr_layer := TerritoryLayer.new()
	terr_layer.model = m
	add_child(terr_layer)
	check(terr_layer.mesh != null and terr_layer.mesh.get_surface_count() == 1, "the borders are drawn on the ground in the world")
	# G20: the map view stripes the territories' ground, on the surface they are on only.
	check(m.territory_chunks.size() == 3 and m.territories_shown(), "terr keeps the territories' chunks for the map's stripes (G20)")
	var stripe_area := 0.0
	var tarea := Rect2(32, 64, 32, 32)
	var speriod := MapLayersScript.stripe_period(1.0)
	var sk := floorf(96.0 / speriod) * speriod
	while sk < 96.0 + 64.0:
		var sband := MapLayersScript.stripe_band(tarea, sk, sk + speriod / 2.0)
		for vi in sband.size():
			var sa := sband[vi]
			var sb := sband[(vi + 1) % sband.size()]
			stripe_area += (sa.x * sb.y - sb.x * sa.y) / 2.0
		sk += speriod
	check(absf(stripe_area - 512.0) < 0.5 and speriod * 1.0 >= MapLayersScript.STRIPE_PX * 2.0 and MapLayersScript.stripe_period(0.1) > speriod,
		"the stripes cover half of each territory chunk, wider in tiles when zoomed out (G20): %.1f of 1024, speriod %d" % [stripe_area, speriod])
	m.handle({"t": "terr", "part": 1, "parts": 1, "si": 7, "l": [[1, 2]]})
	check(not m.territories_shown(), "territories on another surface aren't drawn on this map (G20)")
	var tl := MapLayersScript.new()
	tl.model = m
	tl.size = Vector2(400, 300)
	add_child(tl)
	m.handle({"t": "terr", "part": 1, "parts": 1, "si": m.shown_surface(), "l": [[1, 2]]})
	tl.redraw(Vector2(48, 80), 4.0)
	await get_tree().process_frame
	check(m.territories_shown(), "the world's own surface's territories are drawn (G20)")
	tl.queue_free()
	m.handle({"t": "terr", "part": 1, "parts": 1, "l": []})
	check(m.territory_edges.is_empty() and terr_layer.mesh == null and m.territory_chunks.is_empty(), "an empty terr clears them")
	terr_layer.queue_free()
	# Demolishers (`seg`): the head, segments and tail drawn with their models at their prototypes'
	# scales, gliding to where the mod puts them, the head led ahead of the segment behind it.
	var dprotos := ProtoDB.new()
	dprotos.add_entities([[1, "small-demolisher", "segmented-unit", -1.5, -1.5, 1.5, 1.5, 90, 60, 50, 3, 3],
		[2, "small-demolisher-segment-x0_68", "segment", -2, -0.7, 2, 0.7, 90, 60, 50, 4, 1],
		[3, "small-demolisher-tail-x0_32", "segment", -1, -1, 1, 1, 90, 60, 50, 2, 2]])
	var dem := DemolisherLayer.new()
	dem.model = m
	dem.protos = dprotos
	add_child(dem)
	m.handle({"t": "seg", "l": [[90000, 1, [1, 0, 0, 0, 2, 0, 512, 0, 3, 0, 1280, 0]]]})
	dem._process(0.0)
	dem._process(1.0)
	var dparts: Array = dem.parts_of(90000)
	check(dem.count() == 1 and dparts.size() == 3 and dparts[0][0] == "demolisher-head" and dparts[1][0] == "demolisher-segment"
		and dparts[2][0] == "demolisher-tail" and (dparts[0][1] as Vector3).z < -0.5 and is_equal_approx((dparts[2][1] as Vector3).z, 5.0),
		"a demolisher's head, segment and tail are drawn where seg puts them, the head led ahead: %s" % [dparts])
	m.handle({"t": "seg", "l": [[90000, 1, [1, 0, 2560, 0, 2, 0, 3072, 0, 3, 0, 3840, 0]]]})
	dem._process(0.0)
	dem._process(1.0 / 60.0)
	var mid: float = (dem.parts_of(90000)[2][1] as Vector3).z
	check(mid > 5.0 and mid < 15.0, "its parts glide to their next places (the tail between 5 and 15: %.2f)" % mid)
	dem._process(DemolisherLayer.STALE + 1.0)
	check(dem.count() == 0, "without seg for a while the demolishers are taken away")
	dem.queue_free()
	# Pentapods: a stomper's five legs, each an upper and a lower part, bent to where the mod's
	# feet stand (vehicle_anim.gd, Factorio's leg table for the stomper).
	var vanim := VehicleAnim.new()
	vanim.model = m
	add_child(vanim)
	var sprotos := ProtoDB.new()
	sprotos.add_entities([[4, "big-stomper-pentapod", "spider-unit", -4, -4, 4, 4, 160, 120, 60, 8, 8]])
	var smov := MoverLayer.new()
	smov.protos = sprotos
	var snode: Node3D = smov._make_node(sprotos.entity(4))
	add_child(snode)
	vanim.attach(4000, snode, "big-stomper-pentapod")
	var srig = vanim._rigs.get(4000)
	check(srig != null and srig.kind == "spider" and srig.legs.size() == 5 and is_equal_approx(srig.knee_at, 0.55),
		"a stomper is rigged on its five legs with its own knee: %s" % [srig.legs.size() if srig != null else -1])
	var feet := []
	for i in 5:
		var g: Vector2 = (VehicleAnim.STOMPER_LEGS[i][1] as Vector2) * 0.8
		feet += [int(g.x * 256), int(g.y * 256)]
	m.handle({"t": "legs", "l": [[4000, feet]]})
	vanim._on_planet_data()
	for i in 8:  # within FEET_STALE, while the mod's feet count
		vanim._process(0.05)
	var reached := true
	if srig != null:
		for i in srig.legs.size():
			var want: Vector2 = (VehicleAnim.STOMPER_LEGS[i][1] as Vector2) * 0.8
			reached = reached and Vector2(srig.legs[i].foot.x, srig.legs[i].foot.z).distance_to(want) < 0.1
	check(srig != null and reached, "its feet step to where the mod's feet stand")
	snode.queue_free()
	smov.free()
	vanim.queue_free()
	# C12: pollution from the charts, a map view switch, tinted stronger where there is more.
	m.handle({"t": "chart", "cx": 2, "cy": 0, "n": 1, "pal": [[20, 220, 40]], "px": [0], "pol": 900})
	check(m.map_pollution.get(Vector2i(2, 0)) == 900 and UiSettings.MAP_LAYERS.any(func(l): return l[0] == "map/show_pollution")
		and MapLayersScript.pollution_alpha(9000.0) > MapLayersScript.pollution_alpha(90.0) and MapLayersScript.pollution_alpha(0.0) == 0.0,
		"a chart's pollution is kept and the map's Pollution switch tints it, more for more (C12)")
	m.handle({"t": "chart", "cx": 2, "cy": 0, "n": 1, "pal": [[20, 220, 40]], "px": [0]})
	check(not m.map_pollution.has(Vector2i(2, 0)), "and a chart without pol clears it")
	# C11: recipe icons, robots, signals and stops on the map are drawn over the coverage areas.
	for layers in [ui.map_view.layers, ui.minimap._layers]:
		var lroot: Node = layers.marks.get_parent()
		check(lroot.get_child(lroot.get_child_count() - 1) == layers.marks and lroot.get_child(lroot.get_child_count() - 2) == layers.trains
			and lroot.get_child(0) is CanvasGroup and not layers.has_method("_draw"),
			"the map's markers draw last, over the electric, logistic and turret areas (C11)")
	# Factorio's minimap draws none of the map view's layers (checked in 2.1.24): with coverage
	# switched on, the map view shows it and the minimap doesn't; both still mark the stations.
	var kept_layers := {}
	for key in ["map/show_electric", "map/show_logistic", "map/show_turrets", "map/show_stops"]:
		kept_layers[key] = ui.map_view.layers.settings.get_value(key)
		ui.map_view.layers.settings.set_value(key, key != "map/show_stops", false)
	check(ui.minimap._layers.minimap and not ui.map_view.layers.minimap
		and ["electric", "logistic", "turret"].all(func(k): return ui.map_view.layers._shown(k) and not ui.minimap._layers._shown(k)),
		"the minimap draws no coverage areas while the map view does (as Factorio's)")
	for key in kept_layers:
		ui.map_view.layers.settings.set_value(key, kept_layers[key], false)
	# D11: trains on the map: asked for while a map is open, at most once a second, kept per surface.
	sent()
	var was_ready: bool = Bridge.world_ready
	Bridge.world_ready = true
	m._map_trains_asked = -1000000
	m.ask_map_trains()
	m.ask_map_trains()
	Bridge.world_ready = was_ready
	await get_tree().process_frame
	var train_asks := sent().filter(func(c): return c.get("t", "") == "mtr")
	check(train_asks.size() == 1, "a map asks for the trains on it (mtr), at most once a second (D11): %s" % [train_asks])
	var here: int = m.shown_surface()
	m.handle({"t": "mtr", "si": here, "part": 1, "parts": 2, "l": [256, 512, 250, 1485, 460, 0xEB1200]})
	var after_part: int = m.map_trains.size()
	m.handle({"t": "mtr", "si": here, "part": 2, "parts": 2, "l": [2048, 512, 250, 1485, 460, 0x9A9A9A]})
	m.handle({"t": "mtr", "si": here + 7, "part": 1, "parts": 1, "l": []})
	check(after_part == 0 and m.map_trains.size() == 12 and m.map_trains[6] == 2048,
		"mtr parts make the map's trains, and another surface's don't replace them (D11)")
	ui.map_view.layers.redraw(Vector2.ZERO, 4.0)
	await get_tree().process_frame
	m.handle({"t": "mtr", "si": here, "part": 1, "parts": 1, "l": {}})
	check(m.map_trains.is_empty(), "an empty mtr clears the map's trains")
	# D12: what radars cover (cov): the rest of the charted map is dimmed, except round the character.
	m.handle({"t": "mtr", "si": here, "part": 1, "parts": 1, "l": [], "cov": [20, 0, 3]})
	check(m.map_coverage_known and m.chunk_covered(Vector2i(22, 3), Vector2.ZERO) and not m.chunk_covered(Vector2i(24, 0), Vector2.ZERO)
		and m.chunk_covered(Vector2i(1, 1), Vector2.ZERO) and not m.chunk_covered(Vector2i(10, 0), Vector2.ZERO),
		"cov: a radar's square of chunks and the ground round the character count as seen, the rest not (D12)")
	ui.map_view.layers.redraw(Vector2.ZERO, 0.5)
	await get_tree().process_frame
	# A space platform's map: no radars, and the whole platform seen (all), from another surface too.
	m.handle({"t": "mtr", "si": here, "part": 1, "parts": 1, "l": [], "cov": [], "all": 1})
	check(m.chunk_covered(Vector2i(40, 40), Vector2(-5000, 0)), "mtr all: a platform's map is seen whole, nothing dimmed")
	m.handle({"t": "mtr", "si": here, "part": 1, "parts": 1, "l": [], "cov": []})
	check(not m.chunk_covered(Vector2i(40, 40), Vector2(-5000, 0)), "and the next surface's mtr without all dims again")
	# D3/D9: quality marks only in Alt-mode; quality marks and alert icons depth tested and cut out.
	check(QualityMarksScript.IconShader.resource_path.ends_with("billboard_icon_cut.gdshader")
		and AlertIconsScript.IconShader.resource_path.ends_with("billboard_icon_cut.gdshader")
		and ui.has_signal("alt_mode_changed"),
		"quality marks and alert icons are hidden behind buildings and don't flicker (D3, D9)")
	# Quality marks are gathered per chunk: a change in one chunk doesn't go through every record.
	var qw := WorldMirror.new()
	add_child(qw)
	qw.chunks[Vector2i.ZERO] = ChunkView.new()
	qw.chunks[Vector2i(1, 0)] = ChunkView.new()
	qw._add([701, 8, 5 * 256, 5 * 256, 0, {"q": "rare"}])
	qw._add([702, 8, 40 * 256, 5 * 256, 0, {"q": "rare"}])
	var qm2 := QualityMarksScript.new()
	qm2.world = qw
	add_child(qm2)
	qm2._gather_entities()
	var all_rare: int = (qm2._entity_marks.get("rare", []) as Array).size()
	qw._remove(702)
	qw.chunks[Vector2i(1, 0)].entities.clear()
	qm2._dirty_chunks[Vector2i(1, 0)] = true
	qm2._gather_entities()
	check(all_rare == 2 and (qm2._entity_marks.get("rare", []) as Array).size() == 1 and qm2._chunk_marks.has(Vector2i.ZERO)
		and not qm2._chunk_marks.has(Vector2i(1, 0)), "quality marks: a changed chunk is gathered again alone")
	qm2.model = ui.model
	qm2._process(0.0)
	var marks_off := 0
	for mmi in qm2._layers.values():
		marks_off += (mmi as MultiMeshInstance3D).multimesh.visible_instance_count
	qm2.alt_mode = true
	qm2._process(0.0)
	var rare_layer = qm2._layers.get("rare")
	check(marks_off == 0 and rare_layer != null and (rare_layer as MultiMeshInstance3D).multimesh.visible_instance_count == 1,
		"quality marks show only in Alt-mode (D3): %d without it, the rare building's with it" % marks_off)
	qm2.queue_free()
	qw.queue_free()
	# #2 / B2: belts far away show an icon per lane (bfar), and the client asks for them (bfar r).
	var lanes := BeltLanesScript.new()
	add_child(lanes)
	check(lanes._materials.size() == 1, "lane icons' shader is set up at start-up, not with the first far belt (21 ms on a real base)")
	lanes.sync = true
	lanes.handle({"t": "bfar", "cx": 3, "cy": 1, "l": [100 * 256, 40 * 256, 4, 1, 2, 101 * 256, 40 * 256, 4, 0, 2]})
	var lane_icons: int = lanes.icons_in(Vector2i(3, 1))
	# A chunk's lanes that arrive before the chunk itself is loaded are drawn once it is: the mod
	# sends them only when they change, so a steady belt stayed bare (owner's screenshots).
	var lane_world := WorldMirror.new()
	var lanes_late := BeltLanesScript.new()
	lanes_late.world = lane_world
	add_child(lanes_late)
	lanes_late.handle({"t": "bfar", "cx": 5, "cy": 2, "l": [170 * 256, 70 * 256, 4, 1, 2]})
	for i in 10:
		await get_tree().process_frame
	var lanes_early: int = lanes_late.icons_in(Vector2i(5, 2))
	var lanes_late_cv := ChunkView.new()
	lane_world.chunks[Vector2i(5, 2)] = lanes_late_cv
	lane_world.entities_changed.emit(Vector2i(5, 2))
	var lanes_until := Time.get_ticks_msec() + 3000
	while lanes_late.icons_in(Vector2i(5, 2)) == 0 and Time.get_ticks_msec() < lanes_until:
		await get_tree().process_frame
	check(lanes_early == 0 and lanes_late.icons_in(Vector2i(5, 2)) == 2,
		"far belt icons sent before their chunk loaded are drawn when it arrives (%d, then %d)" % [lanes_early, lanes_late.icons_in(Vector2i(5, 2))])
	lanes_late.queue_free()
	lanes_late_cv.free()
	lane_world.free()
	lanes.handle({"t": "bfar", "cx": 3, "cy": 1, "l": []})
	check(lane_icons == 3 and lanes.icons_in(Vector2i(3, 1)) == 0 and Settings.get_value("graphics", "belt_distance") != null,
		"bfar: an icon per lane carrying something, an empty list clears the chunk, with a distance setting (#2, B2)")
	# G17: a lane is drawn with as many icons as it holds, spread along the belt, neighbours a step apart.
	var dense: Dictionary = BeltLanesScript.Job.build([100 * 256, 40 * 256, 4, 1, 2, 101 * 256, 40 * 256, 4, 0, 2], [4, 4, 0, 2], 0.2)
	var dense_xs: Array = []
	var dense_buf: PackedFloat32Array = dense.get(1, PackedFloat32Array())
	var stride: int = BeltLanesScript.STRIDE
	for j in dense_buf.size() / stride:
		dense_xs.append(snappedf(dense_buf[j * stride + 3], 0.001))
	check(BeltLanesScript.Job.icon_count(dense) == 10 and dense_xs == [99.625, 99.875, 100.125, 100.375]
		and dense_buf.size() >= stride * 2 and dense_buf[7] != dense_buf[stride + 7],
		"bfar c: a full lane is four icons along its belt (an east belt's along x), every other one a step higher (G17): %s" % [dense_xs])
	# Each icon carries its belt's centre (custom data), and the shader hands over belt by belt: no
	# band where a belt shows both its moving items and its icons (owner: overlap between far and close).
	check(dense_buf[12] == 100.0 and dense_buf[13] == 40.0 and dense_buf[stride * 3 + 12] == 100.0
		and BeltLanesScript.LaneShader.code.contains("INSTANCE_CUSTOM") and BeltLanesScript.LaneShader.code.contains("abs(belt - focus)"),
		"lane icons carry their belt's centre, and the shader leaves out whole belts inside the square")
	lanes.near = 48
	check(int(Settings.DEFAULTS["graphics"]["belt_distance"]) == 128 and int(Settings.DEFAULTS["graphics"]["belt_updates"]) == -1
		and not Settings.DEFAULTS["graphics"].has("belt_near_distance") and is_equal_approx(lanes.near_edge(), 46.0),
		"one Belt item distance (128) and Moving belt items Automatic by default; before the mod says its square, lane icons start just inside it")
	# Stacks far away: each lane's icons are piles as high as its stacks (bfar h), a step apart.
	var piled: Dictionary = BeltLanesScript.Job.build([100 * 256, 40 * 256, 4, 1, 2], [2, 1], 0.2, [4, 1])
	var piled_buf: PackedFloat32Array = piled.get(1, PackedFloat32Array())
	var piled_ys: Array = []
	for j in 4:
		piled_ys.append(snappedf(piled_buf[j * stride + 7], 0.001))
	var piled_ok: bool = BeltLanesScript.Job.icon_count(piled) == 9 and piled_ys.size() == 4 and is_equal_approx(piled_buf[3], piled_buf[stride * 3 + 3])
	for j in 4:
		piled_ok = piled_ok and absf(float(piled_ys[j]) - (0.2 + 0.07 * j)) < 0.002
	check(piled_ok,
		"bfar h: a lane of stacks of 4 is two piles of four icons, each a step higher in one place: %s" % [piled_ys])
	# Far icon piles are messy as models' are, the icon under them turned too (ItemCards.turn_for: a
	# lone icon had stood square beside turned ones, owner), each copy above PILE_TURN more.
	var far_seed: int = BeltLanesScript.Job.slot_seed(100 * 256, 40 * 256, 0, 0)
	var far_cs: Array = []
	var far_turn_ok: bool = absf(ItemCardsScript.turn_for(far_seed)) > 0.0001
	for j in range(0, 4):
		var want_a := ItemCardsScript.turn_for(far_seed, j)
		far_cs.append(snappedf(piled_buf[j * stride], 0.0001))
		far_turn_ok = far_turn_ok and absf(piled_buf[j * stride] - cos(want_a)) < 0.0001 and absf(piled_buf[j * stride + 2] - sin(want_a)) < 0.0001
	check(far_turn_ok, "bfar h: an icon pile turns by ItemCards.turn_for, the icon under it too, each copy PILE_TURN more: %s" % [far_cs])
	# G16: lane icons start where the items drawn now were read (bi fx, fy, fr), not round the camera,
	# which runs ahead while panning; at any Belt items in full distance; exactly there, no overlap.
	lanes.focus = Vector2(300, 0)
	lanes.covered = Vector3(200, 10, 64)
	var handover_ok := lanes.hand_over_centre() == Vector2(200, 10) and is_equal_approx(lanes.near_edge(), 64.0)
	lanes.covered = Vector3(0, 0, -1)
	check(handover_ok and lanes.hand_over_centre() == Vector2(300, 0) and is_equal_approx(lanes.near_edge(), 46.0),
		"lane icons hand over exactly at the square belt items cover, else round the focus (G16)")
	# The worker path: messages wait for a job, chunks are made within the frame budget.
	lanes.sync = false
	lanes.handle({"t": "bfar", "cx": 4, "cy": 1, "l": [130 * 256, 40 * 256, 0, 1, 2], "c": [4, 3]})
	lanes.handle({"t": "bfar", "cx": 4, "cy": 1, "l": [130 * 256, 40 * 256, 0, 1, 2], "c": [2, 3]})
	var until_lanes := Time.get_ticks_msec() + 5000
	while lanes.waiting() > 0 and Time.get_ticks_msec() < until_lanes:
		lanes._process(0.016)
		await get_tree().process_frame
	check(lanes.icons_in(Vector2i(4, 1)) == 5, "bfar on a worker thread: the newest message for a chunk wins (%d icons)" % lanes.icons_in(Vector2i(4, 1)))
	# An icon not loaded yet is loaded on a worker thread too (a tinted one took 30 ms), its chunk waiting.
	var lane_protos := ProtoDB.new()
	lane_protos.add_items([[7, "zenith-test-lane-item"]])
	lanes.protos = lane_protos
	var icon_was_cached: bool = BeltLanesScript.ItemIcons.is_cached("zenith-test-lane-item")
	lanes.handle({"t": "bfar", "cx": 5, "cy": 1, "l": [160 * 256, 40 * 256, 0, 7, 0], "c": [2, 0]})
	until_lanes = Time.get_ticks_msec() + 5000
	while lanes.waiting() > 0 and Time.get_ticks_msec() < until_lanes:
		lanes._process(0.016)
		await get_tree().process_frame
	check(not icon_was_cached and lanes.icons_in(Vector2i(5, 1)) == 2 and BeltLanesScript.ItemIcons.is_cached("zenith-test-lane-item")
		and lanes._icon_task < 0, "bfar: a new item's icon is loaded on a worker and cached, then its chunk is drawn")
	# Moving belt items' Automatic keeps the bridge's reading within its share of the server's tick:
	# each update says what it took (bs w over p ticks), and with frames and the game to spare the cap
	# grows a fifth only while that would still fit AUTO_WORK units a tick; a quarter over shrinks it.
	var work_items = BeltItemsScript.new()
	add_child(work_items)
	work_items._sync = true
	work_items.lanes = lanes
	work_items.handle({"t": "bs", "k": 600, "p": 6, "w": 9000})
	var work_heard: float = lanes.bridge_work
	work_items.queue_free()
	var cap_was: float = BeltLanesScript.auto_cap
	var ready_was: bool = Bridge.world_ready
	Bridge.world_ready = true
	var auto_caps: Array = []
	var covered_was: Vector3 = lanes.covered
	# The last: the mod's square reaches the whole belt item distance (bs fr = n), so the cap stops
	# nothing (an empty stretch) and growing it would only make the next busy belts dear.
	for work in [-1.0, 500.0, BeltLanesScript.AUTO_WORK * 0.9, BeltLanesScript.AUTO_WORK * 1.3, 400.0]:
		BeltLanesScript.auto_cap = 6000.0
		lanes.bridge_work = work
		lanes.covered = Vector3(0.0, 0.0, float(lanes.near)) if work == 400.0 else Vector3(0.0, 0.0, 12.0)
		lanes._frames = PackedFloat32Array()
		lanes._auto_t = 0.0
		for i in 101:
			lanes._auto(0.01)  # a second of 10 ms frames: room to spare
		auto_caps.append(roundi(BeltLanesScript.auto_cap))
	Bridge.world_ready = ready_was
	BeltLanesScript.auto_cap = cap_was
	lanes.bridge_work = -1.0
	lanes.covered = covered_was
	check(is_equal_approx(work_heard, 1500.0) and auto_caps == [7200, 7200, 6000, 4800, 6000],
		"Moving belt items' Automatic grows only while the bridge's reading fits its share of the tick (bs w / p) and the cap is what stops it (bs fr < n): heard %.0f a tick, caps %s" % [work_heard, auto_caps])
	lanes.queue_free()
	# G16: the square an update covers is known (lane icons take over outside it).
	var sq_items = BeltItemsScript.new()
	add_child(sq_items)
	sq_items._sync = true
	_bs_feed(sq_items, 600, {"fx": 30 * 256, "fy": 0, "fr": 24}, 2)
	check(sq_items.covered() == Vector3(30, 0, 24), "bs: the square the update covers is known (G16): %s" % sq_items.covered())
	sq_items.queue_free()
	# Items on a real server's belts were thought invisible: a full row of plain iron plates far from
	# the map's origin. Each one must land in its kind's drawn instances, where it was sent, above the
	# belt model's top.
	var belt_top := 0.0
	var belt_mesh: Mesh = ModelLibrary.mesh_for("transport-belt")
	if belt_mesh != null:
		belt_top = belt_mesh.get_aabb().end.y
	var far_items = BeltItemsScript.new()
	add_child(far_items)
	far_items._sync = true
	var far_lm: Array = []
	var far_sl: Array = []
	for b in 10:
		var x0 := -49.0 + b
		far_lm.append_array(_bs_lane((300 + b) * 8 + 1, 1, 256, 0, x0 + 1.0, 56.5, x0, 56.5))
		far_sl.append_array([(300 + b) * 8 + 1, 900, 4])
		for j in 4:
			far_sl.append_array([5000 + b * 4 + j, 1, 32 + 64 * j, 1])
	_bs_feed(far_items, 900, {"fx": int(-40.0 * 256), "fy": int(55.0 * 256), "fr": 24, "lm": far_lm, "sl": far_sl}, 2)
	for f in 24:  # the simulation steps once the drawn clock passes the read tick; looks, then slots
		_bs_feed(far_items, 901 + f, {"fx": int(-40.0 * 256), "fy": int(55.0 * 256), "fr": 24}, 1)
	var far_mmi: MultiMeshInstance3D = far_items._cards._kinds.get(1)
	var far_ok := far_mmi != null and far_mmi.multimesh.visible_instance_count == 40
	if BeltItemsScript.Job.park_lat:
		# (--belt-draw-park-lattice: the ten full lanes' items are parked and the lattice draws them, at the
		# map's phase rather than where each was sent.)
		var on_line := 0
		for e in far_items.drawn_lattice(1):
			if e != null and e[0].y > belt_top and absf(e[0].z - 56.5) < 0.01:
				on_line += 1
		far_ok = on_line == 40
	elif far_ok:
		var fb: Array = far_items.drawn(1)
		far_ok = fb.size() == 40
		var found := 0
		for e in fb:
			if e == null or e[0].y <= belt_top or float(e[1]) == 0.0:
				far_ok = false
				continue
			var lx: float = e[0].x + 49.0
			var frac := lx - floorf(lx)
			if absf(e[0].z - 56.5) < 0.01 and absf(fmod(1.0 - frac, 0.25) - 0.125) < 0.01:
				found += 1
		far_ok = far_ok and found == 40
	check(far_ok and far_items.count() == 40, "bs: items far from the origin, as a real server sends them, are all drawn where sent and above the belt (%d tracked, top %.3f)" % [far_items.count(), belt_top])
	far_items.queue_free()
	# The hand-over never leaves a belt bare (owner): an item on a lane dropped from the square stays
	# until its chunk's far icons are made, those icons stay hidden while it does, and both change together.
	var ho_lanes = BeltLanesScript.new()
	add_child(ho_lanes)
	ho_lanes.sync = true
	var ho_items = BeltItemsScript.new()
	add_child(ho_items)
	ho_items._sync = true
	ho_items.lanes = ho_lanes
	_bs_feed(ho_items, 1400, {"fx": 0, "fy": 0, "fr": 24, "lm": _bs_lane(9, 1, 256, 0, 21.0, 5.0, 20.0, 5.0), "sl": [9, 1400, 1, 9000, 1, 128, 1]}, 1)
	for f in 20:
		_bs_feed(ho_items, 1401 + f, {"fx": 0, "fy": 0, "fr": 24}, 1)
	_bs_feed(ho_items, 1422, {"fx": 200 * 256, "fy": 0, "fr": 24, "dl": [9]}, 2)
	var kept_n: int = ho_items.count()
	var held_now: bool = ho_lanes._held.has(Vector2i(0, 0))
	ho_lanes.handle({"t": "bfar", "cx": 0, "cy": 0, "l": [20 * 256, 5 * 256 + 64, 4, 1, 0], "c": [1, 0]})
	var hidden_built: bool = ho_lanes._chunks.has(Vector2i(0, 0)) and not (ho_lanes._chunks[Vector2i(0, 0)] as Node3D).visible
	_bs_feed(ho_items, 1424, {"fx": 200 * 256, "fy": 0, "fr": 24}, 2)
	check(kept_n == 1 and held_now and hidden_built and ho_items.count() == 0 and (ho_lanes._chunks[Vector2i(0, 0)] as Node3D).visible
		and ho_lanes.covered == Vector3(200, 0, 24),
		"hand-over: an item on a dropped lane stays until its chunk's icons exist (%d, held %s, icons made hidden %s), then both swap in one job's frame" % [kept_n, held_now, hidden_built])
	ho_items.queue_free()
	ho_lanes.queue_free()
	# The old two belt settings: Belt items far away becomes the Belt item distance, Belt items in
	# full goes (Belt updates decides how far items move).
	var belt_path_was: String = Settings.path
	var belt_cfg := ConfigFile.new()
	belt_cfg.set_value("graphics", "belt_far_distance", 320)
	belt_cfg.set_value("graphics", "belt_near_distance", 48)
	belt_cfg.save("user://ui-test-belt-rename.cfg")
	Settings.use_file("user://ui-test-belt-rename.cfg")
	var renamed_ok: bool = int(Settings.get_value("graphics", "belt_distance")) == 320 and int(Settings.get_value("graphics", "belt_updates")) == -1
	belt_cfg = ConfigFile.new()
	belt_cfg.load("user://ui-test-belt-rename.cfg")
	renamed_ok = renamed_ok and not belt_cfg.has_section_key("graphics", "belt_far_distance") and not belt_cfg.has_section_key("graphics", "belt_near_distance")
	Settings.use_file(belt_path_was)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://ui-test-belt-rename.cfg"))
	check(renamed_ok, "a settings file with the two old belt distances keeps the far one as the Belt item distance and drops both")
	# The old Items on belts (models or icons) is Items in 3D's 0: an old file's icons carry over,
	# and Items in 3D alone decides the look.
	var cards_script := preload("res://scripts/world/item_cards.gd")
	var look_cfg := ConfigFile.new()
	look_cfg.set_value("graphics", "item_models", false)
	look_cfg.save("user://ui-test-item-look.cfg")
	Settings.use_file("user://ui-test-item-look.cfg")
	Settings.apply_item_look()
	var look_ok: bool = int(Settings.get_value("graphics", "item_models_max")) == 0 and not cards_script.use_models
	Settings.set_value("graphics", "item_models_max", 500)
	look_ok = look_ok and cards_script.use_models and cards_script.model_cap == 500
	Settings.use_file(belt_path_was)
	Settings.apply_item_look()
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://ui-test-item-look.cfg"))
	check(look_ok, "an old file's Items on belts: Icons becomes Items in 3D 0 (icons); Items in 3D above 0 brings the models back")
	# A 0.1.2 file moved over to 0.1.3's belt settings: Items on belts: Icons is Items in 3D's 0;
	# Smooth belt items and item icons, which left the menu, come back on; High's Belt updates of
	# 6,000 is Automatic, as High is now (once: a 6,000 chosen afterwards stays).
	var old_cfg := ConfigFile.new()
	old_cfg.set_value("meta", "migrated", true)
	old_cfg.set_value("meta", "ssao_off", true)
	for key in Settings.PRESETS["high"]:
		old_cfg.set_value("graphics", key, Settings.PRESETS["high"][key])
	old_cfg.set_value("graphics", "belt_updates", 6000)
	old_cfg.set_value("graphics", "item_models", false)
	old_cfg.set_value("graphics", "item_icons", false)
	old_cfg.set_value("graphics", "belt_smooth", false)
	old_cfg.save("user://ui-test-012.cfg")
	Settings.use_file("user://ui-test-012.cfg")
	var moved_012: Array = [int(Settings.get_value("graphics", "item_models_max")), Settings.get_value("graphics", "item_icons"),
		Settings.get_value("graphics", "belt_smooth"), int(Settings.get_value("graphics", "belt_updates")), Settings.preset_now()]
	Settings.set_value("graphics", "belt_updates", 6000)
	Settings.use_file("user://ui-test-012.cfg")
	var chosen_after := int(Settings.get_value("graphics", "belt_updates"))
	old_cfg = ConfigFile.new()
	old_cfg.load("user://ui-test-012.cfg")
	var gone_012: bool = not old_cfg.has_section_key("graphics", "item_models") and not old_cfg.has_section_key("graphics", "item_icons")
	# On a preset of its own (Ultra's view distance with 6,000): the player's own cap, kept.
	old_cfg = ConfigFile.new()
	old_cfg.set_value("meta", "migrated", true)
	old_cfg.set_value("graphics", "belt_updates", 6000)
	old_cfg.set_value("graphics", "view_radius", 14)
	old_cfg.set_value("graphics", "item_models", "yes")  # not a bool: dropped, not read as one
	old_cfg.save("user://ui-test-012.cfg")
	Settings.use_file("user://ui-test-012.cfg")
	var custom_cap := int(Settings.get_value("graphics", "belt_updates"))
	var odd_models := int(Settings.get_value("graphics", "item_models_max"))
	Settings.use_file(belt_path_was)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://ui-test-012.cfg"))
	check(moved_012 == [0, true, true, -1, "high"] and chosen_after == 6000 and gone_012
		and custom_cap == 6000 and odd_models == Settings.ITEM_MODELS_ALL,
		"a 0.1.2 settings file is moved over: Icons to Items in 3D 0, hidden belt switches back on, High's 6,000 to Automatic once (%s, then %d; custom %d, %d)"
		% [moved_012, chosen_after, custom_cap, odd_models])
	# Factorio's table_to_json writes a float that isn't finite as a bare inf or nan: such a message
	# (4 in a 30-minute session on a real busy base) was dropped whole. It is read, those as numbers.
	var bad_before := int(Bridge.stats.get("bad_json", 0))
	var not_finite = Bridge.parse('{"t":"zz","l":[1,inf,-inf,nan],"o":{"a":inf},"s":"inferno, nan"}')
	var fine = Bridge.parse('{"t":"zz","l":[1,2]}')
	check(not_finite is Dictionary and (not_finite["l"] as Array).map(func(v) -> float: return float(v)) == [1.0, 1e18, -1e18, 0.0] and float(not_finite["o"]["a"]) == 1e18
		and not_finite["s"] == "inferno, nan" and fine is Dictionary and Bridge.parse("{nope") == null
		and int(Bridge.stats.get("bad_json", 0)) == bad_before + 1,
		"a message with inf or nan is read with finite numbers, not dropped (%s)" % [not_finite])
	# With the renderer on its own thread a texture's upload happens there, later: the map's pages and
	# the remote fog's mask are drawn into again meanwhile, so each upload must get its own copy (the
	# render thread read an empty image in texture_2d_update on the real base).
	var page_cache = MapCache.new(UiModel.new())
	var page: Array = page_cache._page(Vector2i.ZERO)
	page_cache._dirty[Vector2i.ZERO] = true
	page_cache.flush()
	var uploaded: Image = (page[1] as ImageTexture).get_image()
	(page[0] as Image).set_pixel(0, 0, Color.RED)
	page_cache._dirty[Vector2i.ZERO] = true
	page_cache.flush()
	var fog_script := FileAccess.get_file_as_string("res://scripts/world/remote_fog.gd")
	check(page[1] != null and (uploaded == null or not is_same(uploaded, page[0])) and fog_script.count("_texture.update(_image)") == 0,
		"map pages and the fog mask upload a copy of their image, not the one drawn into next")
	# A model asked for during play is read on a worker thread, never on the main thread: the export's
	# ModelLibrary.slowest said "parsed here" for the inserter arms' pieces (2-4 ms each, first arm seen).
	var arm_names := ["inserter-arm-bulk-upper", "inserter-arm-bulk-hand-open", "inserter-arm-bulk-hand-closed"]
	for n in arm_names:
		ModelLibrary._cache.erase(n)
		ModelLibrary._jobs.erase(n)
		ModelLibrary._job_order.erase(n)
	var arms_layer: Node3D = preload("res://scripts/world/inserter_arms.gd").new()
	add_child(arms_layer)
	var slow_before := ModelLibrary.slowest.size()
	var arms_first = arms_layer._pieces_for("bulk-inserter")
	var arms_queued := arm_names.all(func(n: String) -> bool: return ModelLibrary._jobs.has(n))
	# A long wait: on a busy PC the worker queue can hold every model the earlier sections asked for.
	var until_arms := Time.get_ticks_msec() + 120000
	while arms_layer._pieces_for("bulk-inserter") == null and Time.get_ticks_msec() < until_arms:
		ModelLibrary.poll()
		await get_tree().process_frame
	# The arms' own: anything else a leftover node asks for meanwhile isn't this check's.
	var parsed_here := ModelLibrary.slowest.slice(slow_before).filter(func(r: Array) -> bool: return r.size() > 4 and r[4] == "parsed here" and r[1] in arm_names)
	check(arms_first == null and arms_queued and arms_layer._pieces_for("bulk-inserter") != null and parsed_here.is_empty(),
		"inserter arm pieces wait for their models, read on worker threads (%s)" % [parsed_here])
	arms_layer.queue_free()
	# D1/D4: flat things that overlap never share a height: decoratives by Factorio's render layer
	# (then a step per tile), items on belts a step apart by id.
	var lifts: Dictionary = DecorativeLayer.LAYER_LIFT
	check(lifts["decals"] < lifts["ground-layer-1"] and lifts["ground-layer-4"] < lifts["floor"] and lifts["floor"] < lifts["decorative"]
		and DecorativeLayer.TILE_STEP * DecorativeLayer.TILE_STEPS <= lifts["ground-layer-1"] - lifts["decals"],
		"flat decoratives lie in Factorio's layer order, steps within a layer never reaching the next (D1)")
	check(BeltItemsScript.LAYERS > 1 and BeltItemsScript.LAYER_STEP > 0.0, "items on belts sit a step apart by id, so overlapping cards don't flicker (D4)")
	# Gleba fights: the premature wrigglers a dying stomper lets out are wrigglers of their tier, not
	# orange boxes, and stomper shells have models of their own (not a cream box).
	var premature_ok := true
	for tier in ["small-", "medium-", "big-"]:
		var a = CreatureModels.ALIASES.get(tier + "wriggler-pentapod-premature")
		var b = CreatureModels.ALIASES.get(tier + "wriggler-pentapod")
		premature_ok = premature_ok and a != null and a == b and CreatureModels.walks(tier + "wriggler-pentapod-premature")
		premature_ok = premature_ok and FileAccess.file_exists(_own_glb(tier + "stomper-shell"))
	check(premature_ok, "premature wrigglers drawn as their tier's wriggler; stomper shells have models")
	# Belt items' simulation runs on a worker thread: the same items and records as on the main thread,
	# and a dropped lane's items go.
	var layers: Array = []
	for sync in [false, true]:
		var bil = BeltItemsScript.new()
		add_child(bil)
		bil._sync = sync
		var bil_lm: Array = []
		var bil_sl: Array = []
		for row in 30:
			for b in 3:
				var key := (400 + row * 3 + b) * 8 + 1
				bil_lm.append_array(_bs_lane(key, 1, 256, 0, b + 1.0, row * 2.0, float(b), row * 2.0))
				var n := 4 if b < 2 else 2
				bil_sl.append_array([key, 600, n])
				for j in n:
					var uid := 1000 + row * 10 + b * 4 + j
					bil_sl.append_array([uid, 1 + row % 3, 32 + 64 * j, 1])
		bil.handle({"t": "bs", "k": 600, "p": 6, "fx": 0, "fy": 0, "fr": 80, "lm": bil_lm, "sl": bil_sl})
		var bk := 600
		var until_job := Time.get_ticks_msec() + 8000
		while (bil._task >= 0 or bil.count() < 300 or not bil._positions.has(1005)) and Time.get_ticks_msec() < until_job:
			bil.position_of(1005)
			bk += 1
			bil.handle({"t": "bs", "k": bk, "p": 6})
			await get_tree().process_frame
		var pos = bil._positions.get(1005)
		layers.append([bil.count(), bil._cards.kind_count(), pos[0] if pos != null else null])
		bil.handle({"t": "bs", "k": bk + 1, "p": 6, "dl": [400 * 8 + 1, 401 * 8 + 1, 402 * 8 + 1]})
		until_job = Time.get_ticks_msec() + 5000
		while (bil._task >= 0 or not bil._inbox.is_empty() or bil.count() == 300) and Time.get_ticks_msec() < until_job:
			await get_tree().process_frame
		layers.append(bil.count())
		bil.queue_free()
	check(layers[0][0] == 300 and layers[0][1] == 3 and layers[1] == 290,
		"bs on a worker thread: 300 items in 3 kinds, a dropped line's 10 go (%s)" % [layers])
	check(layers[0][2] != null and layers[2][2] != null and (layers[0][2] as Vector3).is_equal_approx(layers[2][2]) and layers[3] == 290,
		"and the worker and the main thread put an item in the same place (%s)" % [layers])
	# C4: ground clutter is drawn around the character (the rig's target), not the camera.
	var decor := DecorativeLayer.new()
	var follow := Node3D.new()
	add_child(decor)
	add_child(follow)
	follow.global_position = Vector3(500, 0, 500)
	var gs := GDScript.new()
	gs.source_code = "extends Node3D\nvar target: Node3D\n"
	gs.reload()
	var rig_node: Node3D = gs.new()
	rig_node.target = follow
	add_child(rig_node)  # first: a global position out of the tree is an error
	rig_node.global_position = Vector3(0, 60, 0)  # the camera far from the character
	decor.rig = rig_node
	for c in [Vector2i(15, 15), Vector2i(19, 15), Vector2i(20, 15), Vector2i(22, 15), Vector2i(0, 0)]:
		var n := Node3D.new()
		var inst := MultiMeshInstance3D.new()
		inst.multimesh = MultiMesh.new()
		inst.multimesh.transform_format = MultiMesh.TRANSFORM_3D
		inst.multimesh.instance_count = 100
		n.add_child(inst)
		decor.add_child(n)
		decor._chunks[c] = n
	decor._cull()
	var drawn := func(c: Vector2i) -> int: return (decor._chunks[c].get_child(0) as MultiMeshInstance3D).multimesh.visible_instance_count
	check(decor._chunks[Vector2i(15, 15)].visible and decor._chunks[Vector2i(19, 15)].visible and not decor._chunks[Vector2i(0, 0)].visible,
		"clutter shows around the character and not around the camera (C4)")
	check(drawn.call(Vector2i(15, 15)) == 100 and drawn.call(Vector2i(19, 15)) == 50 and drawn.call(Vector2i(20, 15)) == 25
		and not decor._chunks[Vector2i(22, 15)].visible,
		"clutter thins with distance (all, half, a quarter) out to 192 tiles (B9)")
	for n in [decor, follow, rig_node]:
		n.queue_free()
	# #3 / #12: a robot sent every 2 ticks, the messages arriving unevenly (two at once, then a gap),
	# moves the same distance every frame instead of lurching and stalling.
	var bots := MoverLayer.new()
	var bot_protos := ProtoDB.new()
	bot_protos.add_entities([[5, "logistic-robot", "logistic-robot", -0.2, -0.2, 0.2, 0.2, 1, 1, 1, 1, 1]])
	bots.protos = bot_protos
	add_child(bots)
	var xs: Array[float] = []
	var sent_tick := 0
	for frame in 120:
		# Messages for ticks up to this frame, delivered in bursts every 4 frames.
		if frame % 4 == 0:
			while sent_tick <= frame:
				bots.handle({"t": "mv", "k": sent_tick, "l": [[901, 5, roundi(sent_tick * 0.1 * 256), 0]]})
				sent_tick += 2
		bots._process(1.0 / 60.0)
		xs.append((bots.position_of(901) as Vector3).x)
	var steps: Array[float] = []
	for i in range(30, xs.size()):
		steps.append(xs[i] - xs[i - 1])
	var lo: float = steps.min()
	var hi: float = steps.max()
	check(lo > 0.07 and hi < 0.13, "a robot moves steadily between uneven updates: %.3f to %.3f tiles a frame at 0.1 a tick" % [lo, hi])
	# A busy save runs the server slower than 60 UPS: here 40, a message every 3 frames. The client's
	# clock follows the game's measured rate, so the robot still moves the same distance every frame
	# instead of running ahead, waiting and lurching on.
	var slow := MoverLayer.new()
	slow.protos = bot_protos
	add_child(slow)
	var sx: Array[float] = []
	var game_tick := 0.0
	var slow_sent := 0
	for frame in 300:
		game_tick += 40.0 / 60.0
		while slow_sent <= game_tick:
			slow.handle({"t": "mv", "k": slow_sent, "l": [[904, 5, roundi(slow_sent * 0.1 * 256), 0]]})
			slow_sent += 2
		slow._process(1.0 / 60.0)
		sx.append((slow.position_of(904) as Vector3).x)
	var slow_steps: Array[float] = []
	for i in range(150, sx.size()):
		slow_steps.append(sx[i] - sx[i - 1])
	var slow_lo: float = slow_steps.min()
	var slow_hi: float = slow_steps.max()
	check(slow_lo > 0.055 and slow_hi < 0.08 and absf(slow.clock.rate - 40.0) < 3.0,
		"at 40 UPS a robot still moves steadily: %.3f to %.3f tiles a frame (0.067 expected), clock at %.1f ticks a second"
		% [slow_lo, slow_hi, slow.clock.rate])
	slow.queue_free()
	# F1: Factorio reports a flying robot's position about every 20 ticks, a tile at a time
	# (2.1.23), while it draws it gliding at 0.05 tiles a tick. Sent every 2 ticks, the position
	# repeats nine times and then jumps: the robot must still glide, not hop a tile at a time.
	var coarse := MoverLayer.new()
	coarse.protos = bot_protos
	add_child(coarse)
	var cx: Array[float] = []
	for frame in 400:
		if frame % 2 == 0:
			var k := frame
			coarse.handle({"t": "mv", "k": k, "l": [[905, 5, (k / 20) * 256, 0]]})
		coarse._process(1.0 / 60.0)
		cx.append((coarse.position_of(905) as Vector3).x)
	var coarse_steps: Array[float] = []
	for i in range(200, cx.size()):
		coarse_steps.append(cx[i] - cx[i - 1])
	var coarse_lo: float = coarse_steps.min()
	var coarse_hi: float = coarse_steps.max()
	check(coarse_lo > 0.03 and coarse_hi < 0.07,
		"a robot whose position Factorio moves a tile every 20 ticks glides: %.3f to %.3f tiles a frame (0.05)" % [coarse_lo, coarse_hi])
	coarse.queue_free()
	_update_rates()
	_robot_swarm()
	_gpu_movers()
	bots.handle({"t": "mv", "k": sent_tick, "l": [[901, 5, 500 * 256, 0]]})
	bots._process(1.0 / 60.0)
	check((bots.position_of(901) as Vector3).x > 400.0, "a long jump is a teleport, not a slow glide")
	# B3: locomotives carry two headlights that come on at night, as Factorio's front_light.
	bot_protos.add_entities([[6, "locomotive", "locomotive", -1.0, -3.0, 1.0, 3.0, 1, 1, 1, 2, 6]])
	bots.handle({"t": "mv", "k": sent_tick + 1, "l": [[903, 6, 0, 10 * 256, 0]]})
	var loco = bots._movers[903]
	bots.set_night(0.0)
	var dark_by_day: bool = loco.headlights.size() == 2 and not loco.headlights[0].visible
	bots.set_night(1.0)
	check(dark_by_day and loco.headlights[0].visible and loco.headlights[0].light_energy > 1.0 and loco.headlights[1].position.z < -2.0,
		"a locomotive's two headlights at its nose, on at night only (B3)")
	bots.set_night(0.0)
	# C1: a train appears facing its way instead of swinging round from north.
	bots.handle({"t": "mv", "k": sent_tick + 2, "l": [[902, 5, 0, 0, 250]]})
	check(is_equal_approx(bots.yaw_of(902), Visuals.orientation_yaw(0.25)), "a new mover appears facing its orientation (C1)")
	bots.queue_free()
	# #10: no instant boarding of a platform in orbit, and no list of them on a planet either (owner).
	var pp := PlatformPanel.new()
	add_child(pp)
	pp.handle({"on": 0, "here": "nauvis", "dest": [], "l": [{"i": 2, "n": "Orbiter", "loc": "nauvis", "st": "paused"}]})
	check(not pp.visible and not _texts(pp).has("Board") and not _texts(pp).has("Orbiter"),
		"on a planet the platform panel stays hidden: no platforms-over list, no Board button")
	pp.handle({"on": 2, "dest": ["nauvis"], "l": [{"i": 2, "n": "Orbiter", "st": "waiting_at_station", "loc": "nauvis", "sp": 0.0, "pa": 0}]})
	sent()
	var drop := pp.find_child("Drop", true, false) as Button
	if drop != null:
		drop.pressed.emit()
	var to_nauvis := pp.find_child("DropTo_nauvis", true, false) as Button
	if to_nauvis != null:
		to_nauvis.pressed.emit()
	check(pp.visible and drop != null and drop.is_visible_in_tree() and to_nauvis != null and sent_one("land").get("t") == "land",
		"on board over Nauvis, Drop to a planet and Nauvis ride a cargo pod down at once (land), not the old instant drop")
	pp.queue_free()
	# #6: zooming the map in past its closest level drops into Factorio's angle there, and back out.
	var cam_holder := Node3D.new()
	add_child(cam_holder)
	var cam_rig := CameraRig.new()
	cam_holder.add_child(cam_rig)
	var walker := Node3D.new()
	cam_holder.add_child(walker)
	cam_rig.target = walker
	var view_gs := GDScript.new()
	view_gs.source_code = "extends Node\nvar rig\nvar avatar\n"
	view_gs.reload()
	var viewer: Node = view_gs.new()
	viewer.rig = cam_rig
	viewer.avatar = walker
	var player_was = ui.player
	ui.player = viewer
	ui._zoom_into_world(Vector2(40, 12))
	var dropped: bool = ui.remote and cam_rig.in_factorio_view() and cam_rig.orthographic
	ui.end_remote_view()
	check(dropped and not cam_rig.in_factorio_view() and not cam_rig.orthographic and cam_rig.target == walker,
		"zooming the map in drops into the world at Factorio's angle, leaving puts the camera back (owner's #6)")
	# By default, 2D/3D auto-swap on zoom is off and the top-bar button switches between 2D map and 3D view,
	# preserving the viewed surface even after Factorio sends the character's surface back.
	var map_auto_was = Settings.get_value("camera", "map_auto_swap")
	var char_si_was: int = ui.model.character_si
	var charts_was: Dictionary = ui.model.map_charts.duplicate()
	var tags_was: Array = ui.model.map_tags.duplicate()
	var cache_si_was: int = ui.map_cache._si
	ui.model.set_character_surface(1)
	ui.open_map(true)
	ui.map_view.show_surface(2)
	ui.map_view.zoom = ui.map_view.MAX_ZOOM
	ui.map_view.zoom_by(ui.map_view.ZOOM_STEP, Vector2(100, 100))
	var stayed_2d_on_zoom: bool = not ui.remote and ui.map_view.is_open()
	var orange_bar_shown: bool = ui.map_view._enter_3d_panel != null and ui.map_view._enter_3d_panel.visible \
		and ui.map_view._enter_3d_bar != null and ui.map_view._enter_3d_bar.value > 0.0
	ui.map_view.zoom_by(1.0 / ui.map_view.ZOOM_STEP, Vector2(100, 100))
	var orange_bar_cleared: bool = not ui.map_view._enter_3d_panel.visible and is_zero_approx(ui.map_view._enter_3d_bar.value)
	ui.map_view.zoom = ui.map_view.MAX_ZOOM
	for _s in ui.map_view.ENTER_3D_SCROLLS:
		ui.map_view.zoom_by(ui.map_view.ZOOM_STEP, Vector2(100, 100))
	var entered_3d_after_scrolls: bool = ui.remote and not ui.map_view.is_open() and ui.viewing_si == 2 \
		and not ui.map_view._enter_3d_panel.visible
	ui.remote_frame.show_for("world")
	ui.remote_frame.view_mode_toggled.emit()
	ui.remote_frame.show_for("map")
	var btn_to_3d: bool = ui.remote_frame.view_toggle != null and ui.remote_frame.view_toggle.visible \
		and ui.remote_frame.view_toggle.text == "3D view"
	ui.remote_frame.view_mode_toggled.emit()
	var toggled_to_3d: bool = ui.remote and not ui.map_view.is_open() and ui.viewing_si == 2 \
		and cam_rig.map_handoff_distance == INF
	for i in 60:
		cam_rig.zoom(1.1)
	var stayed_3d_on_zoom: bool = ui.remote and is_equal_approx(cam_rig._distance_goal, cam_rig.max_distance)
	ui.remote_frame.show_for("world")
	var btn_to_2d: bool = ui.remote_frame.view_toggle != null and ui.remote_frame.view_toggle.visible \
		and ui.remote_frame.view_toggle.text == "2D map"
	ui.remote_frame.view_mode_toggled.emit()
	ui.model.set_character_surface(1)
	var kept_surface_after_toggle: bool = not ui.remote and ui.map_view.is_open() \
		and ui.model.map_si == 2 and ui.model.shown_surface() == 2
	ui.open_map(false)
	var reset_on_close: bool = ui.model.map_si == 0
	check(stayed_2d_on_zoom and orange_bar_shown and orange_bar_cleared and entered_3d_after_scrolls \
		and btn_to_3d and toggled_to_3d and stayed_3d_on_zoom and btn_to_2d \
		and kept_surface_after_toggle and reset_on_close,
		"2D/3D auto-swap defaults off; scrolling past max zoom fills orange bar into 3D; top-bar toggle switches 2D<->3D and keeps the viewed surface")

	# Issue #4: with auto-swap enabled, zooming back out of that view goes to the map there, at the
	# distance set in Settings > Camera (past Furthest zoom), keeping the viewed surface.
	var map_out_was = Settings.get_value("camera", "map_zoom_out")
	Settings.set_value("camera", "map_auto_swap", true)
	Settings.set_value("camera", "map_zoom_out", 320)
	ui.open_map(true)
	ui.map_view.show_surface(2)
	ui.map_view.centre = Vector2(40, 12)
	ui._zoom_into_world(Vector2(40, 12))
	var handoff: float = cam_rig.map_handoff_distance
	var map_reached := 0.0
	var out_steps := 0
	while ui.remote and out_steps < 200:
		map_reached = maxf(map_reached, cam_rig._distance_goal)
		cam_rig.zoom(1.1)
		out_steps += 1
	ui.model.set_character_surface(1)
	Settings.set_value("camera", "map_zoom_out", map_out_was)
	Settings.set_value("camera", "map_auto_swap", map_auto_was)
	var back_on_map: bool = not ui.remote and ui.map_view.is_open() and ui.map_view.centre.distance_to(Vector2(40, 12)) < 0.01 \
		and is_equal_approx(ui.map_view.zoom, 8.0) and cam_rig.map_handoff_distance == INF \
		and ui.model.map_si == 2 and ui.model.shown_surface() == 2
	ui.open_map(false)
	ui.model.set_character_surface(char_si_was)
	if cache_si_was == 0 and ui.map_cache._stash.has(1):
		var back: Array = ui.map_cache._stash[1]
		ui.map_cache._stash.erase(1)
		ui.map_cache._pages = back[0]
		ui.map_cache._charted = back[1]
		ui.map_cache._uncharted = back[2]
		ui.map_cache._si = 0
	ui.model.map_charts = charts_was.duplicate()
	ui.model.map_tags = tags_was.duplicate()
	ui.remote_view(Vector2(5, 5))  # a remote view not from the map (an alert) zooms out as before
	for i in 60:
		cam_rig.zoom(1.1)
	var alert_stays: bool = ui.remote and is_equal_approx(cam_rig._distance_goal, cam_rig.max_distance)
	ui.end_remote_view()
	check(is_equal_approx(handoff, 320.0) and is_equal_approx(map_reached, 320.0) and map_reached > cam_rig.max_distance
		and out_steps > 1 and out_steps < 200 and back_on_map and alert_stays,
		"issue #4: with auto-swap on, the map's remote view zooms out to the setting's distance (%d tiles, past Furthest zoom), then the map comes back on the same surface at its closest zoom" % int(map_reached))
	# The projection is a setting (Settings > Camera), no longer the O key; Factorio's view stays
	# orthographic and leaving it returns to the setting.
	var ortho_was = Settings.get_value("camera", "orthographic")
	Settings.set_value("camera", "orthographic", true)
	cam_rig.apply_settings()
	var set_ortho := cam_rig.orthographic
	cam_rig.toggle_factorio_view()
	Settings.set_value("camera", "orthographic", false)
	cam_rig.apply_settings()
	var f6_ortho := cam_rig.orthographic
	cam_rig.toggle_factorio_view()
	check(set_ortho and f6_ortho and not cam_rig.orthographic and not Controls.LIST.any(func(a: Array) -> bool: return a[0] == "toggle_ortho"),
		"Projection setting: orthographic when chosen, F6 always orthographic, back to the setting after; no O key")
	Settings.set_value("camera", "orthographic", ortho_was)
	cam_rig.apply_settings()
	# Owner's H17: the map's remote view has a projection of its own, and F7 switches the one in use.
	var map_ortho_was = Settings.get_value("camera", "map_orthographic")
	Settings.set_value("camera", "map_orthographic", false)
	Settings.set_value("camera", "orthographic", false)
	cam_rig.apply_settings()
	ui._zoom_into_world(Vector2(40, 12))
	cam_rig._process(0.0)
	var map_persp: bool = cam_rig.camera.projection == Camera3D.PROJECTION_PERSPECTIVE
	var h17_map_said: String = cam_rig.toggle_projection()
	cam_rig._process(0.0)
	var map_f7: bool = cam_rig.camera.projection == Camera3D.PROJECTION_ORTHOGONAL and bool(Settings.get_value("camera", "map_orthographic"))
	ui.end_remote_view()
	cam_rig._process(0.0)
	var normal_back: bool = not cam_rig.in_remote and cam_rig.camera.projection == Camera3D.PROJECTION_PERSPECTIVE
	var h17_normal_said: String = cam_rig.toggle_projection()
	var normal_f7: bool = cam_rig.orthographic and bool(Settings.get_value("camera", "orthographic"))
	cam_rig.toggle_projection()
	check(map_persp and map_f7 and h17_map_said.begins_with("Map view") and normal_back and normal_f7 and h17_normal_said.begins_with("Normal view")
		and Controls.LIST.any(func(a: Array) -> bool: return a[0] == "toggle_projection" and a[1] == [KEY_F7]),
		"H17: the map's view keeps its own projection, F7 switches the one in use (map, then normal) and saves it")
	Settings.set_value("camera", "map_orthographic", map_ortho_was)
	Settings.set_value("camera", "orthographic", ortho_was)
	cam_rig.apply_settings()
	# Owner's H19: Settings > Camera > Furthest zoom sets how far the wheel zooms out.
	var max_zoom_was = Settings.get_value("camera", "max_zoom")
	var zoom_goal_was: float = cam_rig._distance_goal
	Settings.set_value("camera", "max_zoom", 300)
	cam_rig.apply_settings()
	cam_rig.zoom(100.0)
	var far_goal: float = cam_rig._distance_goal
	Settings.set_value("camera", "max_zoom", 60)
	cam_rig.apply_settings()
	var near_goal: float = cam_rig._distance_goal
	cam_rig.zoom(100.0)
	check(is_equal_approx(far_goal, 300.0) and is_equal_approx(near_goal, 60.0) and is_equal_approx(cam_rig._distance_goal, 60.0),
		"H19: the furthest zoom follows its setting (300 lets the wheel out to 300, 60 pulls the view in): %.0f, %.0f" % [far_goal, near_goal])
	# A `--camera=` view further out than Furthest zoom starts and stays there (RUNNING.md: "start in
	# that view"); it had glided in to the setting's distance.
	var view_was := [cam_rig._yaw_goal, cam_rig.yaw_degrees, cam_rig.pitch_degrees, cam_rig.distance, cam_rig.orthographic]
	cam_rig.configure_from(PackedStringArray(["--camera=0,30,300"]))
	cam_rig.apply_settings()
	cam_rig.zoom(1.1)
	check(is_equal_approx(cam_rig._distance_goal, 300.0) and is_equal_approx(cam_rig.distance, 300.0) and is_equal_approx(cam_rig.pitch_degrees, 30.0),
		"--camera=0,30,300 starts and stays 300 tiles out (zoomed out too) with Furthest zoom at 60: %.0f, %.0f" % [cam_rig._distance_goal, cam_rig.distance])
	cam_rig._arg_distance = 0.0
	cam_rig._yaw_goal = view_was[0]
	cam_rig.yaw_degrees = view_was[1]
	cam_rig.pitch_degrees = view_was[2]
	cam_rig.distance = view_was[3]
	cam_rig.orthographic = view_was[4]
	Settings.set_value("camera", "max_zoom", max_zoom_was)
	cam_rig.apply_settings()
	cam_rig._distance_goal = zoom_goal_was
	# Owner's G5: F6 snaps to Factorio's view on every press unless the view is exactly Factorio's.
	# Zoomed, turned or tilted there (the wheel, a nudge of the middle mouse), a press went back to
	# the view before instead, so it took another to get Factorio's view.
	cam_rig.pitch_degrees = 60.0
	cam_rig.zoom(1.0)
	var before_f6: float = cam_rig._distance_goal
	cam_rig.toggle_factorio_view()
	var snapped: Array = [cam_rig._yaw_goal, cam_rig.pitch_degrees, cam_rig._distance_goal]
	var f6_ok := true
	for nudge in ["zoom", "turn", "tilt"]:
		match nudge:
			"zoom": cam_rig.zoom(1.25)
			"turn": cam_rig.rotate_free(3.0)
			"tilt": cam_rig.tilt(-2.0)
		cam_rig.toggle_factorio_view()
		f6_ok = f6_ok and cam_rig.in_factorio_view() and [cam_rig._yaw_goal, cam_rig.pitch_degrees, cam_rig._distance_goal] == snapped
	cam_rig.toggle_factorio_view()
	check(f6_ok and not cam_rig.in_factorio_view() and cam_rig.pitch_degrees == 60.0 and cam_rig._distance_goal == before_f6,
		"F6 after zooming, turning or tilting Factorio's view snaps back to it at once; once more goes back to the view before (G5)")
	cam_rig.first_person = true
	cam_rig.toggle_factorio_view()
	var from_fp: bool = cam_rig.in_factorio_view() and not cam_rig.first_person
	cam_rig.toggle_factorio_view()
	check(from_fp, "F6 in first person leaves it for Factorio's view (G5)")
	cam_rig.toggle_factorio_view()
	cam_rig.zoom(1.3)
	ui._zoom_into_world(Vector2(40, 12))
	ui.end_remote_view()
	check(not cam_rig.in_factorio_view() and cam_rig._saved_view.is_empty() and cam_rig.pitch_degrees == 60.0,
		"leaving the map's remote view goes back to the view before Factorio's, even zoomed in it")
	# Owner: first person, into the map's remote view and out again left a third-person view with no
	# character: first person ended while the camera followed the map, so the body never heard.
	var body_gs := GDScript.new()
	body_gs.source_code = "extends Node3D\nvar hidden := false\nfunc set_first_person(on: bool) -> void:\n\thidden = on\n"
	body_gs.reload()
	var body: Node3D = body_gs.new()
	cam_holder.add_child(body)
	cam_rig.target = body
	viewer.avatar = body
	if cam_rig.first_person:
		cam_rig.toggle_first_person()
	cam_rig.toggle_first_person()
	var hid_fp: bool = body.hidden
	ui._zoom_into_world(Vector2(40, 12))
	var shown_in_map: bool = not body.hidden and not cam_rig.first_person
	ui.end_remote_view()
	check(hid_fp and shown_in_map and cam_rig.first_person and body.hidden and cam_rig.target == body,
		"first person, the map's remote view and back: the body shows meanwhile, then first person again")
	cam_rig.toggle_first_person()
	check(not body.hidden, "and leaving first person shows the body")
	cam_rig.target = walker
	viewer.avatar = walker
	body.queue_free()
	# H8: in a platform's hub (a remote view with no character to go back to) M opens the map.
	var hub_was: Vector2 = ui.hub_at
	var remote_was: bool = ui.remote
	ui.hub_at = Vector2(3, 4)
	ui.remote = true
	ui.open_map(true)
	var hub_map_open: bool = ui.map_open()
	ui.open_map(false)
	ui.hub_at = hub_was
	ui.remote = remote_was
	check(hub_map_open, "M opens the map while the character sits in a platform's hub, travelling or not (H8)")
	# #5: zooming into another surface's map asks the mod to stream that surface (view), and leaving
	# the remote view goes back to the character's.
	sent()
	var other_si: int = ui.model.character_si + 5
	ui.model.map_si = other_si
	ui._zoom_into_world(Vector2(8, 9))
	var view_ask := sent_one("view")
	var viewing_was: int = ui.viewing_si
	ui.end_remote_view()
	var view_back := sent_one("view")
	check(view_ask.get("si") == other_si and view_ask.get("x") == 8 * 256 and viewing_was == other_si
		and view_back.get("si") == 0 and ui.viewing_si == 0,
		"zooming into another surface's map views that surface, and leaving goes back (#5): %s %s" % [view_ask, view_back])
	ui.model.map_si = 0
	ui.model.map_charts = charts_was.duplicate()
	ui.model.map_tags = tags_was.duplicate()
	await _check_ride(cam_rig, viewer, ui)
	ui.player = player_was
	viewer.free()
	cam_holder.queue_free()
	# #19: the character's own position, sent every 2 ticks and arriving unevenly, moves evenly, so
	# the run cycle steps evenly too (exoskeleton speed: 0.3 tiles a tick).
	var runner := Avatar.new()
	add_child(runner)
	var rx: Array[float] = []
	var rtick := 0
	for frame in 150:  # the clock measures the game's rate over its first half second
		if frame % 4 == 0:
			while rtick <= frame:
				runner.update_from({"t": "me", "k": rtick, "u": 1, "x": roundi(rtick * 0.3 * 256), "y": 0, "d": 4, "w": 1, "hp": 250, "q": 0})
				rtick += 2
		runner._process(1.0 / 60.0)
		rx.append(runner.position.x)
	var rsteps: Array[float] = []
	for i in range(60, rx.size()):
		rsteps.append(rx[i] - rx[i - 1])
	check(rsteps.min() > 0.27 and rsteps.max() < 0.33, "the character runs at an even speed between uneven updates (#19): %.3f to %.3f a frame at 0.3" % [rsteps.min(), rsteps.max()])
	runner.queue_free()
	# On a busy save the server runs below 60 UPS (here 40, a `me` every 3 frames): the avatar's clock
	# follows the measured rate, so the character still runs evenly instead of lurching.
	var slow_runner := Avatar.new()
	add_child(slow_runner)
	var srx: Array[float] = []
	var s_game := 0.0
	var s_sent := 0
	for frame in 300:
		s_game += 40.0 / 60.0
		while s_sent <= s_game:
			slow_runner.update_from({"t": "me", "k": s_sent, "u": 1, "x": roundi(s_sent * 0.15 * 256), "y": 0, "d": 4, "w": 1, "hp": 250, "q": 0})
			s_sent += 2
		slow_runner._process(1.0 / 60.0)
		srx.append(slow_runner.position.x)
	var srsteps: Array[float] = []
	for i in range(150, srx.size()):
		srsteps.append(srx[i] - srx[i - 1])
	check(srsteps.min() > 0.085 and srsteps.max() < 0.115 and absf(slow_runner._clock.rate - 40.0) < 3.0,
		"at 40 UPS the character still runs evenly: %.3f to %.3f tiles a frame (0.100 expected), clock at %.1f ticks a second"
		% [srsteps.min(), srsteps.max(), slow_runner._clock.rate])
	slow_runner.queue_free()
	# B7: walking at 20 degrees the mod zig-zags between north and north-east (puppet.lua's
	# angle_step); the avatar is drawn straight along the line, facing it, at an even speed.
	var zig := Avatar.new()
	add_child(zig)
	var za := 56  # thousandths of a turn
	var zrad := za / 1000.0 * TAU
	var zline := Vector2(sin(zrad), -cos(zrad))
	var zpos := Vector2.ZERO
	var zerr := 0.0
	var ztick := 0
	var real_side := 0.0
	var drawn_side: Array[float] = []
	var drawn_along: Array[float] = []
	for frame in 150:
		if frame % 4 == 0:
			while ztick <= frame:
				for i in 2:
					var zlo := int(floor(za / 1000.0 * 8.0)) % 8
					var slo := sin(zlo / 8.0 * TAU - zrad)
					var shi := sin((zlo + 1) / 8.0 * TAU - zrad)
					var pick := zlo + 1 if absf(zerr + shi) < absf(zerr + slo) else zlo
					zerr += shi if pick != zlo else slo
					zpos += Vector2(sin(pick / 8.0 * TAU), -cos(pick / 8.0 * TAU)) * 0.15
				ztick += 2
				real_side = maxf(real_side, absf(zline.cross(zpos)))
				zig.update_from({"t": "me", "k": ztick, "u": 1, "x": roundi(zpos.x * 256), "y": roundi(zpos.y * 256), "d": 2, "w": 1, "a": za, "hp": 250, "q": 0})
		zig._process(1.0 / 60.0)
		var at := Vector2(zig.position.x, zig.position.z)
		drawn_side.append(zline.cross(at))
		drawn_along.append(zline.dot(at))
	var jitter := 0.0
	var zsteps: Array[float] = []
	for i in range(40, drawn_side.size()):
		jitter = maxf(jitter, absf(drawn_side[i] - drawn_side[i - 1]))
		zsteps.append(drawn_along[i] - drawn_along[i - 1])
	var face_off := absf(wrapf(zig.rotation.y + zrad, -PI, PI))
	check(real_side > 0.02 and jitter < 0.004 and zsteps.min() > 0.12 and zsteps.max() < 0.16 and face_off < 0.02,
		"walking at an angle is drawn straight along it (B7): the real path strays %.3f tiles, the drawn one moves %.4f sideways a frame at most, %.3f to %.3f along, facing %.3f off"
		% [real_side, jitter, zsteps.min(), zsteps.max(), face_off])
	# Stopping, the drawn character comes back to where the real one is.
	for frame in 30:
		if frame % 2 == 0:
			ztick += 2
			zig.update_from({"t": "me", "k": ztick, "u": 1, "x": roundi(zpos.x * 256), "y": roundi(zpos.y * 256), "d": 2, "w": 0, "hp": 250, "q": 0})
		zig._process(1.0 / 60.0)
	check(Vector2(zig.position.x, zig.position.z).distance_to(zpos) < 0.01, "and on stopping it is drawn where the character really is")
	zig.queue_free()
	# B4: the character's flashlight, a cone ahead of it at night.
	var me := Avatar.new()
	add_child(me)
	me.set_night(0.2)
	var off: bool = not me._flashlight.visible
	me.set_night(0.9)
	check(off and me._flashlight.visible and me._flashlight.light_energy > 1.0 and me._flashlight.rotation.x < 0.0,
		"the character's flashlight lights the ground ahead, from darkness 0.3 as in Factorio (B4)")
	# Owner: "seems to be no flashlight" (V27). Factorio's is a light picture drawn over the world
	# (light-cone.png, 25 tiles long, its middle 13 ahead), which no building stops: the beam is that
	# picture projected from high over the character, nothing casting its shadow, and the ground gets
	# the picture's own fade, from a tile ahead to its far end. Fails on 0.2.1's shadowed spot.
	Avatar._beam_texture = null
	var built_at := Time.get_ticks_usec()
	Avatar.beam_texture()
	var built_ms := (Time.get_ticks_usec() - built_at) / 1000.0
	var cone_image: Image = Avatar.cone_picture()
	var cone_data := cone_image.get_data()
	var cone_side := cone_image.get_width()
	var beam_off := 0.0
	var beam_most := 0.0
	for f in range(2, 23):
		var lit: float = Avatar.beam_light_at(Vector3(0.0, 0.0, -f)) / Avatar.BEAM_PEAK
		beam_off = maxf(beam_off, absf(lit - Avatar.cone_at(cone_data, cone_side, f, 0.0)))
		beam_most = maxf(beam_most, lit)
	check(me._flashlight.light_projector != null and me._flashlight.shadow_caster_mask == 0 and me._flashlight.shadow_enabled
		and beam_off < 0.08 and beam_most > 0.85,
		"the flashlight lands Factorio's cone on the ground, its fade within %.3f of light-cone.png's from 2 to 22 tiles ahead (brightest %.2f), no shadow casters (picture made in %.1f ms)"
		% [beam_off, beam_most, built_ms])
	var mid10: float = Avatar.beam_light_at(Vector3(0.0, 0.0, -10.0))
	var side10: float = Avatar.beam_light_at(Vector3(2.0, 0.0, -10.0))
	var out10: float = Avatar.beam_light_at(Vector3(-7.0, 0.0, -10.0))
	var past: float = Avatar.beam_light_at(Vector3(0.0, 0.0, -27.0))
	var behind: float = Avatar.beam_light_at(Vector3(0.0, 0.0, 3.0))
	check(side10 > 0.5 * mid10 and out10 < 0.03 * Avatar.BEAM_PEAK and past < 0.03 * Avatar.BEAM_PEAK and behind == 0.0,
		"its sides 25 degrees off the middle, nothing past 25 tiles or behind (10 ahead: %.2f, 2 across %.2f, 7 across %.3f; 27 ahead %.3f)" % [mid10, side10, out10, past])
	var front: float = Avatar.beam_light_at(Vector3(0.0, 1.5, -12.0), Vector3.BACK)
	var self_lit := 0.0
	for h in [0.3, 0.9, 1.5, 2.0]:
		for z in [-0.4, 0.0, 0.4]:
			self_lit = maxf(self_lit, Avatar.beam_light_at(Vector3(0.0, h, z), Vector3(0.0, 0.5, -0.86).normalized()))
	check(front > 0.3 * Avatar.BEAM_PEAK and self_lit < 0.01,
		"a building's front 12 tiles ahead is lit (%.2f), the character itself isn't (%.3f)" % [front, self_lit])
	# --flashlight=old: 0.2.1's spot, 3 tiles up, 14 degrees down, the buildings casting its shadows.
	var mode_was: String = Avatar.flashlight_mode
	Avatar.flashlight_mode = "old"
	var old_me := Avatar.new()
	add_child(old_me)
	var beam_down := -old_me._flashlight.rotation.x
	var beam_reach := old_me._flashlight.position.y / tan(beam_down)
	check(beam_down >= deg_to_rad(12.0) and beam_reach > 8.0 and beam_reach < 16.0 and old_me._flashlight.spot_range > beam_reach * 1.5
		and old_me._flashlight.light_projector == null and (1 & old_me._flashlight.shadow_caster_mask) != 0,
		"--flashlight=old: the shadowed spot's beam meets the ground 8 to 16 tiles ahead (%.1f)" % beam_reach)
	old_me.queue_free()
	Avatar.flashlight_mode = mode_was
	# K3: in first person the flashlight turns to where the camera (the crosshair) looks while the body
	# faces elsewhere; out of first person it faces with the body.
	var cam_was := get_viewport().get_camera_3d()
	var aim_cam := Camera3D.new()
	add_child(aim_cam)
	aim_cam.make_current()
	aim_cam.global_transform = Transform3D(Basis(Vector3.UP, deg_to_rad(-90.0)) * Basis(Vector3.RIGHT, deg_to_rad(-20.0)), Vector3(0.0, 1.6, 0.0))
	me.rotation.y = 0.0
	me.set_first_person(true)
	me._aim_flashlight()
	var beam_dir := -me._flashlight.global_transform.basis.z
	var cam_dir := -aim_cam.global_transform.basis.z
	var fp_off := absf(wrapf(atan2(-beam_dir.x, -beam_dir.z) - atan2(-cam_dir.x, -cam_dir.z), -PI, PI))
	me.set_first_person(false)
	me._aim_flashlight()
	var body_dir := -me._flashlight.global_transform.basis.z
	var body_off := absf(wrapf(atan2(-body_dir.x, -body_dir.z) - me.rotation.y, -PI, PI))
	aim_cam.queue_free()
	if cam_was != null:
		cam_was.make_current()
	check(fp_off < 0.01 and body_off < 0.01 and absf(atan2(-cam_dir.x, -cam_dir.z)) > 1.0,
		"K3: in first person the flashlight turns where the crosshair looks (%.3f off), else with the body (%.3f off)" % [fp_off, body_off])
	# F7: the character's own body and tools cast no shadow from its lights (its head and arms
	# crossed the flashlight while running), and the facing, which the flashlight follows, keeps an
	# angled walk's line through a message without the angle and on stopping.
	var self_shadow := false
	var self_meshes := 0
	for node in me.find_children("*", "GeometryInstance3D", true, false):
		self_meshes += 1
		if (node as GeometryInstance3D).layers & me._flashlight.shadow_caster_mask or (node as GeometryInstance3D).layers & me._lantern.shadow_caster_mask:
			self_shadow = true
	check(self_meshes > 0 and not self_shadow and me._flashlight.shadow_enabled,
		"the character's lights cast no shadows of the character itself (F7): %d meshes" % self_meshes)
	check((ItemCardsScript.BELT_LAYER & me._flashlight.shadow_caster_mask) == 0 and (ItemCardsScript.BELT_LAYER & me._lantern.shadow_caster_mask) == 0
		and (1 & me._lantern.shadow_caster_mask) != 0,
		"nor of the items on belts (their own layer); buildings still cast the lantern's")
	var line_yaw := -56 / 1000.0 * TAU
	var yaws: Array[float] = []
	for msg in [{"k": 2, "d": 0, "w": 1, "a": 56}, {"k": 4, "d": 2, "w": 1}, {"k": 6, "d": 0, "w": 1, "a": 56},
			{"k": 8, "d": 2, "w": 0}, {"k": 10, "d": 0, "w": 0}]:
		me.update_from(msg.merged({"t": "me", "u": 1, "x": 0, "y": 0, "hp": 250, "q": 0}))
		yaws.append(absf(wrapf(me._yaw_goal - line_yaw, -PI, PI)))
	me.update_from({"t": "me", "k": 12, "u": 1, "x": 0, "y": 0, "d": 4, "w": 0, "hp": 250, "q": 0})
	var turned := absf(wrapf(me._yaw_goal - Visuals.direction_yaw(4), -PI, PI)) < 0.001
	me.update_from({"t": "me", "k": 14, "u": 1, "x": 0, "y": 0, "d": 0, "w": 1, "a": 56, "hp": 250, "q": 0})
	for k in range(16, 40, 2):  # then a walk with no angle: after ANGLE_HOLD ticks it faces its direction
		me.update_from({"t": "me", "k": k, "u": 1, "x": 0, "y": 0, "d": 0, "w": 1, "hp": 250, "q": 0})
	var plain := absf(wrapf(me._yaw_goal - Visuals.direction_yaw(0), -PI, PI)) < 0.001
	check(yaws.max() < 0.001 and turned and plain,
		"the character keeps facing an angled walk's line through the zig-zag's steps and stopping, and turns to a new direction (F7): %s" % [yaws])
	me.queue_free()
	# F8: the run cycle steps with the distance walked at Factorio's pace: 22 frames per
	# distance_per_frame 0.13 / animation_speed 0.6 tiles (the mech's 0.37).
	var legs := CharacterAnimScript.new()
	var legs_pose := CharacterPoseScript.new()
	for i in 60:  # the gait follows the smoothed speed: let it settle at Factorio's running speed
		legs.running = true
		legs.step(legs_pose, 1.0 / 60.0, 0.15)
	var loops := 0.0
	for i in 100:
		var before: float = legs._run_phase
		legs.running = true
		legs.step(legs_pose, 1.0 / 60.0, 0.15)
		loops += fposmod(legs._run_phase - before, TAU) / TAU
	var per_loop := 15.0 / loops
	legs.mech = true
	var mech_before: float = legs._run_phase
	legs.step(legs_pose, 1.0 / 60.0, 0.15)
	var mech_per_loop := 0.15 / (fposmod(legs._run_phase - mech_before, TAU) / TAU)
	check(absf(per_loop - 4.767) < 0.01 and absf(mech_per_loop - 7.73) < 0.01,
		"the run cycle takes Factorio's 4.77 tiles a loop (7.73 in mech armour), not 2.86 (F8): %.3f, %.3f" % [per_loop, mech_per_loop])
	_character_motion()
	_planet_spin()
	# F4: a travelling platform's sky has the planet it left only over the route's first 12% and
	# the next one only over the last; `d` is thousandths of the route.
	var MainSky = load("res://scripts/main.gd")
	var route := {"from": "nauvis", "to": "vulcanus", "len": 15000}
	var sky_at := func(d: int) -> Array: return MainSky.planet_in_sky(route.merged({"d": d}))
	var early: Array = sky_at.call(30)
	var middle: Array = sky_at.call(300)
	var middle2: Array = sky_at.call(700)
	var late: Array = sky_at.call(960)
	# H9: a planet's way is continuous through a stop or a fly-by, shrinking with distance, ahead of a
	# platform coming and behind one leaving, and gone at its far end without popping.
	var at_planet: Array = MainSky.planet_pose(0.0)
	var coming: Array = MainSky.planet_pose(-0.5)
	var going: Array = MainSky.planet_pose(0.5)
	var far_off: Array = MainSky.planet_pose(-1.0)
	check(is_equal_approx(float(at_planet[0]), 0.9) and (at_planet[1] as Vector3).is_equal_approx(Vector3(0, -1, 0))
		and is_equal_approx(float(at_planet[2]), 1.0), "a planet at a stopped platform is straight below it at full size (H9)")
	check(float(coming[0]) < 0.2 and (coming[1] as Vector3).z < -0.3 and (going[1] as Vector3).z > 0.0 and float(far_off[2]) == 0.0
		and absf(float(MainSky.planet_pose(-0.001)[0]) - 0.9) < 0.01 and absf(float(MainSky.planet_pose(0.001)[0]) - 0.9) < 0.01,
		"a planet comes from ahead and falls away behind, shrinking with distance, and fades out at the far end (H9)")
	check(float(MainSky.planet_offset(route.merged({"d": 60}))[1]) > 0.4 and float(MainSky.planet_offset(route.merged({"d": 940}))[1]) < -0.4
		and is_equal_approx(float(MainSky.planet_offset({"loc": "fulgora"})[1]), 0.0), "a platform's offset from the planet: leaving positive, coming negative, stopped 0 (H9)")
	var stopped: Array = MainSky.planet_in_sky({"loc": "fulgora"})
	check(early[0] == "nauvis" and early[1] > 0.7 and middle[0] == "" and middle2[0] == "" and late[0] == "vulcanus"
		and late[1] > 0.6 and stopped[0] == "fulgora" and stopped[1] == 1.0,
		"a travelling platform shows the planet left, then none, then the next (F4): %s %s %s %s %s" % [early, middle, middle2, late, stopped])
	# F04: in mech armour the character is drawn as the mech (its own model and rig), and back.
	var mech := Avatar.new()
	add_child(mech)
	var plain_rig: Node = mech._rig
	var plain_top := mech._pose.head_of("head").y if mech._pose != null else 0.0
	mech.set_armor("light-armor")
	var kept: bool = mech._rig == plain_rig and not mech.is_mech() and mech.look == "character"
	# Armour looks: Factorio draws heavy and modular armour with its level 2 layer, power armour
	# with level 3, each on the character's own skeleton (so its bones stay where they were).
	var looks := []
	var same_bones := true
	for item in ["heavy-armor", "modular-armor", "power-armor", "power-armor-mk2", "light-armor"]:
		mech.set_armor(item)
		looks.append(mech.look)
		if mech._pose != null and absf(mech._pose.head_of("head").y - plain_top) > 0.001:
			same_bones = false
	check(looks == ["character-armor-2", "character-armor-2", "character-armor-3", "character-armor-3", "character"]
		and same_bones and mech._rig.get_parent() == mech and not mech.is_mech(),
		"each armour swaps the character to Factorio's look for it, on the same skeleton (N43): %s" % [looks])
	var others := Creatures.new()
	var other := Node3D.new()
	others.add(900, "character", other)
	var plain_node := Node3D.new()
	others.add(901, "character", plain_node)
	others.set_looks({900: Avatar.look_for("power-armor"), 902: Avatar.look_for("heavy-armor")})
	check(others.look_of(900) == "character-armor-3" and others.look_of(901) == "character"
		and Avatar.look_for("mech-armor") == "character-mech-armor" and Avatar.look_for("") == "character",
		"other players' characters wear their armour's look from `pl` (N43): %s, %s" % [others.look_of(900), others.look_of(901)])
	others.free()
	other.free()
	plain_node.free()
	# Dying enemies fall the way their corpse model lies (creature_poses.json, fitted to Factorio's
	# corpse sprites), every tier at its size, so the corpse that replaces them lies where they fell.
	var falls := Creatures.new()
	var fell := []
	for n in ["small-biter", "behemoth-biter", "medium-spitter", "big-spitter", "small-worm-turret", "big-worm-turret"]:
		var f := falls.fall_of(n)
		if f.is_empty():
			continue
		var d := Creatures.Dying.new()
		d.name = n
		d.seconds = 1.0
		d.age = 1.0
		var k: float = falls._scale_of(n)
		var end: Transform3D = falls._collapse(d)
		d.age = 0.0
		var start: Transform3D = falls._collapse(d)
		var at: Vector3 = f["at"] * k
		if (end * at).is_equal_approx(f["to"] * k) and (start * at).is_equal_approx(at):
			fell.append(n)
	falls.free()
	check(fell.size() == 6, "dying biters, spitters and worms fall into their corpses' poses, every tier: %s" % [fell])
	# Fights: corpses lie in one MultiMesh per model per 16-tile cell, bounded by it, built once
	# (not every frame), and live creatures' layers are bounded by where they are, so neither is
	# drawn out of view or in every shadow split (a 150-enemy wave: 1.7 -> 7.2 million triangles).
	var heap := Creatures.new()
	add_child(heap)
	var corpse_model := "small-biter-corpse"
	var wait_until := Time.get_ticks_msec() + 10000
	while not (ModelLibrary.ready(corpse_model) and ModelLibrary.ready("small-biter")) and Time.get_ticks_msec() < wait_until:
		ModelLibrary.poll()
		await get_tree().process_frame
	if ModelLibrary.mesh_for(corpse_model) != null:
		heap._add_corpse(corpse_model, Transform3D(Basis.IDENTITY, Vector3(5, 0, 5)))
		heap._add_corpse(corpse_model, Transform3D(Basis.IDENTITY, Vector3(6, 0, 7)))
		heap._add_corpse(corpse_model, Transform3D(Basis.IDENTITY, Vector3(300, 0, 5)))
		heap._process(0.016)
		var built: Array = heap._cells.values().map(func(c) -> bool: return c.dirty)
		var heap_walker := Node3D.new()
		heap_walker.position = Vector3(-40, 0, 10)
		heap.add(77, "small-biter", heap_walker)
		heap._process(0.016)
		heap._process(0.016)
		var corpse_boxes: Array = []
		var live_cells: Dictionary = heap._layers.get("small-biter", {})
		var live_layer: MultiMeshInstance3D = live_cells.values()[0].mmi if live_cells.size() == 1 else null
		var live_box := live_layer.custom_aabb if live_layer != null else AABB()
		for mmi: MultiMeshInstance3D in heap.find_children("*", "MultiMeshInstance3D", false, false):
			if mmi != live_layer and mmi.multimesh.visible_instance_count > 0 and mmi.multimesh.use_custom_data:
				corpse_boxes.append(mmi.custom_aabb)
		check(heap._cells.size() == 2 and corpse_boxes.size() == 2 and corpse_boxes.all(func(b: AABB) -> bool: return b.size.x <= 48.0)
			and built == [false, false] and live_box.has_point(Vector3(-40, 1, 10)) and live_box.size.x < 20.0,
			"corpses are drawn per 16-tile cell and built once, live creatures bounded by where they are: %s, %s %s" % [corpse_boxes, live_box, heap._layers.keys()])
		# A corpse joining a built cell is added to what it holds, not the cell built again.
		var first_cell = heap._cells.get(Vector2i(0, 0))
		var first_layer: MultiMeshInstance3D = first_cell.layers.get(corpse_model) if first_cell != null else null
		heap._add_corpse(corpse_model, Transform3D(Basis.IDENTITY, Vector3(7, 0, 6)))
		var queued: bool = first_cell != null and not first_cell.dirty and first_cell.pending.size() == 1
		heap._process(0.016)
		check(queued and first_layer != null and first_layer.multimesh.visible_instance_count == 3 and first_cell.pending.is_empty()
			and (first_cell.buffers[corpse_model] as PackedFloat32Array).size() == 48 and not first_cell.dirty,
			"a new corpse in a built cell is added to it, not the cell built again: %d drawn" % [first_layer.multimesh.visible_instance_count if first_layer != null else -1])
		# Creatures' view LODs come as a new mesh the layer swaps to: rebuilding the mesh in place
		# while it was drawn stalled the renderer 330-600 ms at a fight's first corpses.
		var source: Mesh = ModelLibrary.mesh_for("small-biter")
		var lod_until := Time.get_ticks_msec() + 15000
		while ModelLods.lod_copy(source) == null and Time.get_ticks_msec() < lod_until:
			ModelLods.poll()
			await get_tree().process_frame
		heap._process(0.016)
		var swapped: Mesh = live_layer.multimesh.mesh if live_layer != null else null
		check(ModelLods.lod_copy(source) != null and swapped == ModelLods.lod_copy(source) and swapped != source,
			"live creatures switch to a copy of their mesh with view LODs, the shared mesh left as it is")
		heap_walker.free()
	heap.free()
	mech.set_armor("mech-armor")
	var mech_top := mech._pose.head_of("head").y if mech._pose != null else 0.0
	var swapped: bool = mech.is_mech() and mech._rig != plain_rig and mech._rig.get_parent() == mech \
		and mech._anim.mech and mech_top > plain_top * 1.3
	mech.update_from({"t": "me", "u": 1, "x": 0, "y": 0, "d": 0, "w": 0, "hp": 250, "q": 0, "m": 50, "mx": 0, "my": 256})
	for i in 30:
		mech._process(1.0 / 60.0)
	var no_tools: bool = not mech._pickaxe.visible and not mech._gun.visible
	var muzzle := mech.muzzle_position()
	mech.set_armor("")
	check(kept and swapped and no_tools and muzzle.y > 1.3 and not mech.is_mech() and not mech._anim.mech,
		"mech armour draws the character as the mech, with no pickaxe or hand gun, and back (F04): head %.2f -> %.2f, muzzle %s"
		% [plain_top, mech_top, muzzle])
	mech.queue_free()
	var ents: Dictionary = ItemIcons.index().get("entity", {})
	check(ents.has("straight-rail") and ents.has("big-rock") and not ents.has("transport-belt"),
		"icons.json has the icons of entities no item is named after (C3): %d" % ents.size())
	# Plain maths, so before the install's pictures (CI has no Factorio).
	var near := func(x: float) -> float: return PlatformPanel.planet_nearness(x, 0.12)
	check(near.call(0.0) == 1.0 and near.call(0.06) > 0.4 and near.call(0.06) < 0.6 and near.call(0.5) == 0.0 and near.call(0.97) > 0.7,
		"while travelling, the planet left falls away and the next one comes near (#15)")
	if ItemIcons.find_data_dir() == "":
		print("skip technology pictures: no Factorio install")
		return
	for e in ["straight-rail", "big-rock", "curved-rail-a"]:
		var tex := Kit.item_icon(e)
		check(tex != null and not Kit._swatches.has(e), "%s's tooltip shows its icon, not a coloured square (C3)" % e)
	# #15: the planet below a platform is Factorio's own picture of it.
	var MainScript = load("res://scripts/main.gd")
	check(MainScript.planet_picture("nauvis") != null and MainScript.planet_picture("vulcanus") != null and MainScript.planet_picture("") == null,
		"the real planets' pictures for space's sky (owner's #15)")
	# Their whole-surface maps for the sphere below the platform, read on a worker thread.
	var first_maps: Dictionary = MainScript.planet_maps_soon("vulcanus")
	var maps_until := Time.get_ticks_msec() + 10000
	while MainScript.planet_maps_soon("vulcanus").is_empty() and Time.get_ticks_msec() < maps_until:
		await get_tree().process_frame
	var vmaps: Dictionary = MainScript.planet_maps_soon("vulcanus")
	check(first_maps.is_empty() and vmaps.has("map") and vmaps.has("clouds") and vmaps.has("emission")
		and (vmaps["map"] as Texture2D).get_width() >= 2048 and MainScript.planet_maps_soon("space-location-x").is_empty(),
		"a planet's 2048-wide surface, cloud and glow maps load on a worker for the sphere below a platform")
	var missing := []
	for t in techs:
		if GuiAssets.tech_icon(t) == null:
			missing.append(t)
	check(missing.is_empty(), "every technology has a picture (none falls back to the red science pack): %s" % [missing])
	var bonus := GuiAssets.tech_icon("physical-projectile-damage-1").get_image()
	bonus.decompress()
	check(bonus.get_size() == Vector2i(256, 256) and bonus.get_pixel(228, 228).a > 0.5,
		"the bonus badge is drawn in the bottom-right corner, 256 px as Factorio's tech icons: %s" % [bonus.get_pixel(228, 228)])


## A server under load slows the mod's costliest updates down (`rate`): movers and belt items then
## come two, four or eight times further apart, each message saying how far (`p`). They must still
## move the same distance every frame: no stall at the end of each gap, no jump at the next update,
## and no stop or step back when the spacing changes under way.


func _update_rates() -> void:
	var car_protos := ProtoDB.new()
	car_protos.add_entities([[8, "car", "car", -0.7, -1.0, 0.7, 1.0, 1, 1, 1, 1, 1]])
	# Movers: a car at 0.1 tiles a tick, sent every 2 ticks, then every 4 (rate 1) and every 16
	# (rate 3, quadrupled again), at 60 UPS and 60 frames a second. As the mod does (rate.lua), after
	# a slow-down they still come at the old rate for 120 ticks while already saying the new one.
	for spacing in [[2, 4], [4, 8], [2, 16]]:
		var cars := MoverLayer.new()
		cars.protos = car_protos
		add_child(cars)
		var xs: Array[float] = []
		var switch_frame := 120
		for frame in 480:
			var p: int = spacing[0] if frame < switch_frame else spacing[1]
			var every: int = spacing[0] if frame < switch_frame + 120 else spacing[1]
			if frame % every == 0:
				cars.handle({"t": "mv", "k": frame, "p": p, "l": [[950, 8, roundi(frame * 0.1 * 256), 0]]})
			cars._process(1.0 / 60.0)
			xs.append(cars._movers[950].node.position.x)
		var steady: Array[float] = []
		var during: Array[float] = []
		for i in range(60, xs.size()):
			var s := xs[i] - xs[i - 1]
			if i >= switch_frame + 180:
				steady.append(s)
			elif i >= switch_frame:
				during.append(s)
		check(steady.min() > 0.085 and steady.max() < 0.115,
			"movers every %d ticks (then %d) glide evenly: %.3f to %.3f tiles a frame (0.1)" % [spacing[0], spacing[1], steady.min(), steady.max()])
		check(during.min() > 0.03 and during.max() < 0.16,
			"and while the spacing goes from %d to %d ticks they slow a little but never stop or jump: %.3f to %.3f" % [spacing[0], spacing[1], during.min(), during.max()])
		cars.queue_free()


## Movers drawn on the GPU (mover_records.gd): written only when a position arrives, a record put
## where the shader would draw it (records.position, the shader's code on the CPU) must match where
## movers.gd's old per-frame CPU code drew it (_drawn_at at the clock less the lag eased every frame),
## in every case the earlier glide checks cover: messages in bursts, Factorio's coarse robot
## positions, a 40 UPS server, its updates slowed down (`rate`); and the facing must ease the same.


func _gpu_movers() -> void:
	ModelLibrary.mesh_for("logistic-robot")
	var protos := ProtoDB.new()
	protos.add_entities([[5, "logistic-robot", "logistic-robot", -0.2, -0.2, 0.2, 0.2, 1, 1, 1, 1, 1]])
	# [name, frames, message for frame (or null), game ticks a frame]
	var cases := [
		["bursts", 240, func(f: int) -> Array: return range(f - 3 if f % 4 == 0 else f + 1, f + 1).filter(func(k: int) -> bool: return k >= 0 and k % 2 == 0), 1.0],
		["coarse", 400, func(f: int) -> Array: return [f] if f % 2 == 0 else [], 1.0],
		["40 UPS", 360, func(f: int) -> Array: return [roundi(f * 40.0 / 60.0)] if roundi(f * 40.0 / 60.0) % 2 == 0 and roundi(f * 40.0 / 60.0) != roundi((f - 1) * 40.0 / 60.0) else [], 40.0 / 60.0],
		["slowed", 480, func(f: int) -> Array: return [f] if (f < 180 and f % 2 == 0) or f % 8 == 0 else [], 1.0],
	]
	for case in cases:
		var layer := MoverLayer.new()
		layer.protos = protos
		add_child(layer)
		var worst := 0.0
		var worst_yaw := 0.0
		var cpu_lag := -1.0
		var cpu_yaw := 0.0
		var on_record := false
		# While its updates go from every 2 ticks to every 8 the clock is steered to the new spacing,
		# and the old code eased the lag by frames, the record by the clock: a little apart meanwhile,
		# but never stopping, stepping back or jumping.
		var easing := 0.0
		var steps: Array[float] = []
		var last_x := NAN
		for f in int(case[1]):
			for k: int in case[2].call(f):
				var x := 0.0
				var y := 0.0
				if case[0] == "coarse":
					x = floorf(k / 20.0)  # a tile every 20 ticks, as Factorio reports a flying robot
				else:
					x = k * 0.1
					y = 2.0 * sin(k * 0.02)  # a curve, so corners count
				var turn := roundi(fposmod(k * 0.002, 1.0) * 1000.0)
				var msg := {"t": "mv", "k": k, "l": [[910, 5, roundi(x * 256), roundi(y * 256), turn]]}
				if case[0] == "slowed" and f >= 180:
					msg["p"] = 8
				layer.handle(msg)
			layer._process(1.0 / 60.0)
			var m = layer._movers.get(910)
			if m == null or layer.clock.tick < 0.0:
				continue
			# movers.gd's old per-frame path for the same mover.
			var want := maxf(layer.clock.gap * MoverLayer.GameClock.DELAY_SENDS, m.key_gap + layer.clock.gap)
			cpu_lag = want if cpu_lag < 0.0 else move_toward(cpu_lag, want, 1.0 / 60.0 * layer.clock.rate * (0.5 if want > cpu_lag else 1.0))
			var cpu: Vector3 = MoverLayer._drawn_at(m, layer.clock.tick - cpu_lag)
			cpu_yaw = lerp_angle(cpu_yaw, m.yaw_goal, 1.0 - exp(-1.0 / 60.0 * MoverLayer.FOLLOW_RATE)) if f > 0 else m.yaw_goal
			on_record = m.slot >= 0
			if f >= 60:
				var gpu: Vector3 = layer.position_of(910)
				var apart := Vector2(gpu.x - cpu.x, gpu.z - cpu.z).length()
				if case[0] == "slowed" and f >= 180 and f < 330:
					easing = maxf(easing, apart)
				else:
					worst = maxf(worst, apart)
				worst_yaw = maxf(worst_yaw, absf(angle_difference(layer.yaw_of(910), cpu_yaw)))
				if not is_nan(last_x) and f >= 200:  # once the coarse robot's spacing is learnt (F1)
					steps.append(gpu.x - last_x)
				last_x = gpu.x
		check(on_record and worst < 0.02 and worst_yaw < 0.02 and easing < 0.1 and steps.min() > 0.02 and steps.max() < 0.16,
			"a robot drawn from its record is where the old CPU code drew it (%s): %.4f tiles (%.4f while its updates slow), %.4f radians at worst; %.3f to %.3f tiles a frame"
			% [case[0], worst, easing, worst_yaw, steps.min(), steps.max()])
		layer.queue_free()
	# The records' two clocks: a record written just before an epoch ends is drawn on through the
	# next one and, moved onto the newer clock, through the one after (float precision holds in a
	# long game).
	var rec = MoverLayer.MoverRecords.new()
	var rslot: int = rec.alloc()
	var e: float = MoverLayer.MoverRecords.EPOCH
	var rspots: Array[Vector3] = [Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(2, 1, 0), Vector3(3, 1, 0)]
	var rticks: Array[float] = [2.0 * e - 20.0, 2.0 * e - 10.0, 2.0 * e, 2.0 * e + 10.0]
	rec.frame(2.0 * e - 15.0, 60.0, 0.016)
	rec.write(rslot, rspots, rticks, 0, 1.0, 3.0, 0.0, 2.0 * e - 15.0, 4.0, 2.0, 2.0, 2.0, 0.25, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0)
	var off := 0.0
	for t in [2.0 * e - 15.0, 2.0 * e - 1.0, 2.0 * e + 1.0, 2.0 * e + 9.0, 3.0 * e - 2.0, 3.0 * e + 1.0, 4.0 * e + 5.0]:
		rec.frame(t, 60.0, 0.016)
		var expect := clampf((t - 4.0 - (2.0 * e - 20.0)) * 0.1, 0.0, 3.0)
		off = maxf(off, absf((rec.position(rslot) as Vector3).x - expect))
	check(off < 0.002, "a record is drawn where it should be across the clocks' epochs: %.4f tiles off at worst" % off)
	# robot_carry matches MoverRecords.robot_anim(state(slot)) for moving, stopped, and working robots.
	var r_flags := MoverLayer.MoverRecords.ANIMATED | MoverLayer.MoverRecords.BUILDER
	var r_carry := rec.alloc()
	var carry_ok := true
	var t_samples := [
		[2.0 * e - 12.0, 2.0 * e - 12.0],
		[2.0 * e + 8.0, 2.0 * e + 8.0],
		[2.0 * e + 10.0, 2.0 * e + 90.0],
	]
	for pair in t_samples:
		var wt: float = pair[0]
		var qt: float = pair[1]
		rec.frame(wt, 60.0, 0.016)
		rec.write(r_carry, rspots, rticks, r_flags, 1.0, 3.0, 0.0, wt, 4.0, 2.0, 2.0, 2.0, 0.25, 0.0, 0.0, 0.25, 0.1, 0.0, 0.0, 0.0, 1.0)
		rec.frame(qt, 60.0, 0.016)
		var expect_anim: Vector4 = MoverLayer.MoverRecords.robot_anim(rec.state(r_carry))
		var got_carry: Vector2 = rec.robot_carry(r_carry)
		if not is_equal_approx(got_carry.x, expect_anim.x) or not is_equal_approx(got_carry.y, expect_anim.w):
			carry_ok = false
	# Stationary mover fast path preserves target/yaw on identical updates and applies orient-only changes.
	var st_layer := MoverLayer.new()
	st_layer.protos = protos
	add_child(st_layer)
	st_layer.handle({"t": "mv", "k": 10, "l": [[915, 5, 2560, 5120, 250]]})
	var st_m = st_layer._movers.get(915)
	var yaw1: float = st_m.yaw_goal
	var ticks_n: int = st_m.ticks.size()
	st_layer.handle({"t": "mv", "k": 12, "l": [[915, 5, 2560, 5120, 250]]})
	var fast_kept: bool = is_equal_approx(st_m.to_tick, 12.0) and is_equal_approx(st_m.yaw_goal, yaw1) and st_m.ticks.size() == ticks_n
	st_layer.handle({"t": "mv", "k": 14, "l": [[915, 5, 2560, 5120, 500]]})
	var rot_changed: bool = is_equal_approx(st_m.to_tick, 14.0) and not is_equal_approx(st_m.yaw_goal, yaw1)
	st_layer.queue_free()
	check(carry_ok and fast_kept and rot_changed,
		"robot_carry matches robot_anim (%s) and stationary mover fast path handles unchanged/rotated updates (%s %s)"
		% [carry_ok, fast_kept, rot_changed])
	# Walking biters: their instances only point at their records (slot + 1 in the custom data's b,
	# a plain transform at their square's middle) and use the mover shader; an attack (`en`) poses
	# one here, its end gives it back to the shader, and one that dies falls from where it was drawn.
	ModelLibrary.mesh_for("small-biter")
	ModelLibrary.mesh_for("small-biter-corpse")
	var bprotos := ProtoDB.new()
	bprotos.add_entities([[9, "small-biter", "unit", -0.2, -0.2, 0.2, 0.2, 1, 1, 1, 1, 1]])
	var biters := MoverLayer.new()
	biters.protos = bprotos
	add_child(biters)
	var near := Node3D.new()  # the character, near: posed creatures are worked out every frame
	near.position = Vector3(45, 0, 15)
	biters.creatures.target = near
	for f in 60:
		if f % 2 == 0:
			biters.handle({"t": "mv", "k": f, "l": [[920, 9, roundi((40.0 + f * 0.1) * 256), roundi(10.0 * 256), 250],
				[921, 9, roundi(50.0 * 256), roundi(20.0 * 256), 0]]})
		biters._process(1.0 / 60.0)
		biters.creatures._process(1.0 / 60.0)
	var cr = biters.creatures
	var walker = cr._creatures.get(920)
	var layer = walker.walker if walker != null else null
	var custom := Color()
	var origin := Vector3.ZERO
	var shader_ok := false
	if layer != null:
		var b: PackedFloat32Array = layer.buffer
		var o: int = walker.index * 16
		custom = Color(b[o + 12], b[o + 13], b[o + 14], b[o + 15])
		origin = Vector3(b[o + 3], b[o + 7], b[o + 11])
		var mat := (layer.mmi.multimesh.mesh as Mesh).surface_get_material(0) as ShaderMaterial
		shader_ok = mat != null and mat.shader == preload("res://shaders/factorio_material_mover.gdshader")
	var biter_at = biters.position_of(920)
	check(walker != null and walker.slot >= 0 and int(custom.b) == walker.slot + 1 and origin.is_equal_approx(Vector3(48, 0, 16))
		and shader_ok and biter_at != null and (biter_at as Vector3).x > 40.5,
		"a walking biter's instance points at its record (b = slot + 1), set once at its square's middle, drawn with the mover shader: %s %s %s"
		% [custom, origin, biter_at])
	var st: Dictionary = biters.records.state(walker.slot) if walker != null else {}
	var g: Vector2 = biters.records.creature_gait(st) if not st.is_empty() else Vector2.ZERO
	check(not st.is_empty() and float(st["speed"]) > 5.0 and g.y > 0.99 and is_equal_approx(float(st["kind"].y), TAU / 2.0),
		"its record walks it at 6 tiles a second with full gait, a loop of legs every 2 tiles: %s" % [st.get("speed"), ])
	cr.handle_attacks({"l": [921, roundi(51.0 * 256), roundi(20.0 * 256)]})
	var posed: bool = cr._posed.has(921) and cr._creatures[921].walker == null
	for f in 60:
		cr._process(1.0 / 60.0)
	var back: bool = not cr._posed.has(921) and cr._creatures[921].walker != null
	var at_death: Vector3 = biters.position_of(920)
	biters.remove(920)
	var dying: Array = cr._dying
	near.free()
	check(posed and back and dying.size() == 1 and (dying[0].xform.origin as Vector3).distance_to(at_death) < 0.001,
		"an attacking biter is posed here, back on its record once the attack lapses; one that dies falls where it was drawn: %s %s %d"
		% [posed, back, dying.size()])
	# The mod sends no `en` while nobody attacks: a quiet minute after a fight brings back no guesses
	# (a still biter, or another player's character, by the player was posed biting).
	cr._clock += 60.0
	check(cr.attacks_reported(), "once `en` has come, attacks aren't guessed again after a quiet spell")
	biters.queue_free()


## G3: flying robots are drawn together, one MultiMesh per robot kind and part (robot_swarm.gd),
## with their animation (flying, cargo lamp, working, arms) in each instance's data, instead of a
## node and several MeshInstance3Ds each.


func _robot_swarm() -> void:
	for name in ["logistic-robot", "construction-robot", "defender"]:
		ModelLibrary.mesh_for(name)
	var layer := MoverLayer.new()
	var p := ProtoDB.new()
	p.add_entities([[5, "logistic-robot", "logistic-robot", -0.2, -0.2, 0.2, 0.2, 1, 1, 1, 1, 1],
		[6, "construction-robot", "construction-robot", -0.2, -0.2, 0.2, 0.2, 1, 1, 1, 1, 1],
		[7, "defender", "combat-robot", -0.2, -0.2, 0.2, 0.2, 1, 1, 1, 1, 1]])
	layer.protos = p
	add_child(layer)
	layer.vehicles.model = {"robot_cargo": {1000: {"item": 1, "count": 4}}}
	# 200 logistic robots flying east at 0.05 tiles a tick, 99 construction robots hovering, a defender.
	var records := func(k: int, logistic: int) -> Array:
		var l: Array = []
		for i in logistic:
			l.append([1000 + i, 5, roundi((i * 2 + k * 0.05) * 256), 0])
		for j in 99:
			l.append([2000 + j, 6, j * 256, 10 * 256])
		l.append([3000, 7, 0, 20 * 256])
		return l
	for frame in 90:
		if frame % 2 == 0:
			layer.handle({"t": "mv", "k": frame, "l": records.call(frame, 200)})
		layer._process(1.0 / 60.0)
	var swarm := layer.robots
	var meshes := 0
	var in_tree := 0
	for m in layer._movers.values():
		meshes += m.node.get_child_count()
		in_tree += 1 if m.node.is_inside_tree() else 0
	var parts := swarm.instances()
	check(layer.count() == 300 and swarm.count() == 300 and meshes == 0 and in_tree == 0 and parts.size() > 0 and parts.size() <= 20,
		"300 robots are drawn by %d MultiMeshes, not %d nodes of their own (G3)" % [parts.size(), in_tree])
	var shader_ok := true
	for mmi in parts:
		if mmi.material_override == null:
			var mat := mmi.multimesh.mesh.surface_get_material(0) as ShaderMaterial
			shader_ok = shader_ok and mat != null and mat.shader == preload("res://shaders/factorio_material_robot.gdshader")
	check(shader_ok, "robots' parts use the robot shader, their shadows the drop-shadow material")
	var at := func(unit: int) -> Array: return swarm.drawn(layer._movers[unit].bot)
	var flying: Array = at.call(1000)
	var empty: Array = at.call(1001)
	var hovering: Array = at.call(2000)
	var defender: Array = at.call(3000)
	var node_at: Vector3 = layer.position_of(1000)
	check(not flying.is_empty() and (flying[0] as Transform3D).origin.distance_to(node_at) < 0.001 and node_at.x > 0.5
		and (flying[1] as Color).r > 0.3 and int((flying[1] as Color).b) == 1 and int((empty[1] as Color).b) == 0,
		"a flying robot is drawn where it glides, its thrusters out, the cargo lamp lit only with cargo: %s %s" % [flying, empty])
	check(int((hovering[1] as Color).b) == 2 and (hovering[1] as Color).a > 0.3 and (hovering[1] as Color).r < 0.05
		and (defender[1] as Color).g == 0.0,
		"a construction robot hovering in place works with its arms out; a defender doesn't bob: %s %s" % [hovering, defender])
	check(layer.robot_near(node_at, 1.0) and not layer.robot_near(node_at + Vector3(0, 0, 300), 2.0),
		"robot_near finds the robots through its grid")
	# Half the logistic robots leave: the rest keep their own places after the slots are reused.
	for frame in range(90, 110):
		if frame % 2 == 0:
			layer.handle({"t": "mv", "k": frame, "l": records.call(frame, 100)})
		layer._process(1.0 / 60.0)
	var wrong := 0
	for unit in layer._movers:
		var d: Array = swarm.drawn(layer._movers[unit].bot)
		if d.is_empty() or (d[0] as Transform3D).origin.distance_to(layer.position_of(unit)) > 0.001:
			wrong += 1
	check(swarm.count() == 200 and layer.count() == 200 and wrong == 0,
		"robots that leave are dropped and the others drawn where they are: %d drawn, %d wrong" % [swarm.count(), wrong])
	layer.vehicles.model = null  # a stand-in: vehicle_anim.gd wants ui_model.gd's signals
	layer.queue_free()


## The run plants its feet, takes exoskeleton speed with a faster cadence and a longer stride, settles
## when it stops; the mech takes off, hovers, flies and lands (`me` fl, fh) with every bone finite.


func _character_motion() -> void:
	var anim := CharacterAnimScript.new()
	var pose := CharacterPoseScript.new()
	if not pose.load_rig("character"):
		check(false, "the character's rig loads for the motion checks")
		return
	var dt := 1.0 / 240.0
	var v := 9.0  # Factorio's running speed, tiles a second
	for model in ["character", "character-mech-armor"]:
		var feet := CharacterAnimScript.new()
		feet.mech = model != "character"
		var rig := CharacterPoseScript.new()
		if not rig.load_rig(model):
			check(false, "the %s rig loads for the motion checks" % model)
			continue
		var r := _foot_slide(feet, rig, v, dt)
		check(r.x < 99.0 and r.y < 0.05 and absf(r.z) < 0.05,
			"running, a planted foot stays where it touched down (%s): slides %.3f tiles, %.3f off the ground" % [model, r.y, r.z])
	for i in 240:
		anim.running = true
		anim.step(pose, dt, v * dt)
	# Exoskeletons: three times the speed is about 1.7 times the cadence, not three times.
	var base_loop: float = anim._loop_length()
	anim._gait = 3.0
	var exo_loop: float = anim._loop_length()
	var cadence := (3.0 / exo_loop) / (1.0 / base_loop)
	check(absf(base_loop - CharacterAnimScript.RUN_LOOP) < 0.01 and cadence > 1.5 and cadence < 1.9,
		"at exoskeleton speed the steps quicken by about the root of the speed, the stride takes the rest: %.2f" % cadence)
	anim._gait = 1.0
	# Stopping: the legs carry on to a stance instead of freezing mid-stride, and the run fades.
	var stop_phase: float = anim._run_phase
	for i in 240:
		anim.running = false
		anim.step(pose, dt, 0.0)
	var settled_u: float = fposmod(anim._run_phase / TAU, 0.5)
	check(anim._run_phase != stop_phase and absf(settled_u - anim._duty * 0.5) < 0.02 and anim._w["run"] < 0.05,
		"stopping, the legs finish their step to a stance and the run fades into idle: u %.3f, run %.3f" % [settled_u, anim._w["run"]])
	# Running backwards (shooting while running away) keeps every bone finite.
	var finite := true
	for i in 120:
		anim.running = true
		anim.step(pose, dt, -6.0 * dt)
		finite = finite and _pose_finite(pose)
	check(finite and anim._speed < -5.0, "running backwards keeps the pose finite: speed %.1f" % anim._speed)
	# The mech's flight: take-off, the air, flying along, landing.
	var mech := CharacterAnimScript.new()
	mech.mech = true
	var mpose := CharacterPoseScript.new()
	if not mpose.load_rig("character-mech-armor"):
		check(false, "the mech's rig loads for the flight checks")
		return
	var root_rest: Vector3 = mpose.head_of("spine")
	var states := []
	var top := -INF
	var crouch := INF
	finite = true
	var thrust_max := 0.0
	# 2.5 s: 0.25 s on the ground, then flying (moving for a while); from 1.75 s the height comes
	# down at Factorio's 3/64 tile a tick with `fl` still 1 until it touches down, as in 2.1.
	for i in 600:
		var t := i * dt
		mech.descending = t >= 1.75
		mech.flight_height = clampf((t - 0.25) * 60.0 / 32.0, 0.0, 1.0) if t < 1.75 else maxf(0.0, 1.0 - (t - 1.75) * 60.0 * 3.0 / 64.0)
		mech.flying = t > 0.25 and (t < 1.75 or mech.flight_height > 0.0)
		mech.running = t > 1.0 and t < 1.6
		mech.step(mpose, dt, (9.0 * dt) if mech.running else 0.0)
		finite = finite and _pose_finite(mpose)
		if states.is_empty() or states.back() != mech.air_state:
			states.append(mech.air_state)
		var y: float = mpose.point("spine", root_rest).y - root_rest.y
		top = maxf(top, y)
		if mech.air_state == CharacterAnimScript.Air.TAKE_OFF and mech._air_t < CharacterAnimScript.TAKE_OFF * 0.3:
			crouch = minf(crouch, y)
		thrust_max = maxf(thrust_max, mech.thrust)
	var Air = CharacterAnimScript.Air
	check(finite and states == [Air.GROUND, Air.TAKE_OFF, Air.AIR, Air.LANDING, Air.GROUND],
		"the mech takes off, flies and lands with every bone finite: %s" % [states])
	check(crouch < -0.1 and top > 0.7 and thrust_max > 0.5 and mech.thrust == 0.0,
		"it crouches before the thrust (%.2f), rises by the height sent (%.2f), its thrusters burn while flying (%.2f)" % [crouch, top, thrust_max])


## Runs `anim` at `v` tiles a second: (stances seen, the most a planted right foot slid along the
## ground, its height off the ground), 99 when no stance was seen.


func _foot_slide(anim, pose, v: float, dt: float) -> Vector3:
	var tail: Vector3 = pose.tail_of("shin_r")
	for i in 240:
		anim.running = true
		anim.step(pose, dt, v * dt)
	var walked := 0.0
	var spans: Array[float] = []
	var heights: Array[float] = []
	var zs: Array[float] = []
	for i in 600:
		anim.running = true
		anim.step(pose, dt, v * dt)
		walked += v * dt
		var u: float = anim._run_phase / TAU
		var at: Vector3 = pose.point("shin_r", tail)
		if u > anim._duty * 0.1 and u < anim._duty * 0.9:
			zs.append(at.z - walked)  # the model faces -Z: the ground moves +Z under it
			heights.append(at.y - tail.y)
		elif not zs.is_empty():
			spans.append(zs.max() - zs.min())
			zs.clear()
	if spans.size() < 2:
		return Vector3(spans.size(), 99.0, 99.0)
	var lift := 0.0
	for h in heights:
		if absf(h) > absf(lift):
			lift = h
	return Vector3(spans.size(), spans.max(), lift)


func _pose_finite(pose) -> bool:
	for r in pose.rows():
		if not (is_finite(r.x) and is_finite(r.y) and is_finite(r.z) and is_finite(r.w)):
			return false
	return true


## The saved backdrops' list (backdrop_list.gd, 0.2.2): two recordings give two entries (new files, named
## from their saves and the time, not in the file name); the Menu backdrop window lists them under
## Default with the one in use marked; rename, Use, Delete (asked first), Default; a broken file falls
## back to Default; the one file from before moved into the list once; Open folder; the shipped default.
