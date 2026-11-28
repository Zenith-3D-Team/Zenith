extends "res://tests/ui_test_base.gd"
## UI test sections: play.

func _cursor_count() -> void:
	var mode_was := Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var cs := CursorStack.new()
	add_child(cs)
	cs.debug_at = Vector2(200, 200)
	cs.item = "big-electric-pole"
	cs.count = 12
	cs.over_gui = false
	cs.over_world_too = false  # player_input.gd: the held building's ghost shows
	await get_tree().process_frame
	await get_tree().process_frame
	var over_ghost: bool = cs.count_shown() and not cs.shown() and cs._drawn
	cs.over_world_too = true  # an item that can't be built, or over nothing
	await get_tree().process_frame
	await get_tree().process_frame
	var icon: bool = cs.shown() and cs._drawn
	cs.over_world_too = false
	cs.over_gui = true
	await get_tree().process_frame
	await get_tree().process_frame
	var over_window: bool = cs.shown() and not cs.count_shown() and cs._drawn
	cs.over_gui = false
	cs.count = 0
	await get_tree().process_frame
	await get_tree().process_frame
	var empty_hand: bool = not cs.count_shown() and not cs._drawn
	cs.count = 12
	CursorStack.count_fix = false
	await get_tree().process_frame
	await get_tree().process_frame
	var old_none: bool = not cs.count_shown() and not cs._drawn
	CursorStack.count_fix = true
	check(over_ghost and icon and over_window and empty_hand,
		"L7: over the held building's ghost the hand's count is drawn by the pointer (the icon over windows and where no ghost shows; none for an empty hand)")
	check(old_none, "L7: --cursor-count=old draws nothing over the ghost, as before")
	cs.queue_free()
	Input.mouse_mode = mode_was


## L2's and L7's leftovers (the owner's playtest video). L7: an item picked from the quickbar was held
## with no stack in particular and the cursor counted all of it in the inventory; Factorio's cursor
## holds one stack (the hand on its slot) and refills from the inventory as it empties: the key takes a
## stack (the biggest, as the pipette), builds name its slot (`hs`) so that stack pays, the count is
## the stack's, the next stack comes into the hand when it runs out, Q puts it back, a click on a slot
## puts it down. L2: the quickbar and the inventory's slots count the builds sent out at once, as the
## cursor did, and get them back when the game refuses one. --hand-stack=all, --slot-counts=report: as
## before.


func _hand_stack(hud: Hud) -> void:
	var ui = hud.ui
	var m: UiModel = ui.model
	var world := WorldMirror.new()
	world.pick_build_usec = 1 << 40  # the whole pick index at once (see _predictions)
	world.protos.add_entities([[1, "wooden-chest", "container", -0.35, -0.35, 0.35, 0.35, 120, 90, 60, 1, 1]])
	world.protos.item_places = {"wooden-chest": "wooden-chest"}
	world.chunks[Vector2i.ZERO] = ChunkView.new()
	var until_models := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < until_models and not ModelLibrary.entity_ready("wooden-chest", "container", {}, 0):
		ModelLibrary.poll()
		await get_tree().process_frame
	var chest: ProtoDB.EntityProto = world.protos.entity(1)
	var pred := Predicted.new()
	pred.world = world
	add_child(pred)
	var input := PlayerInput.new()
	input.world = world
	input.hud = hud
	input.predicted = pred
	input.drag.pi = input
	m.inventory_changed.connect(pred.inventory_heard)
	var stub := GDScript.new()
	stub.source_code = "extends Node\nvar cursor_item := \"\"\nvar cursor_slot := 0\nvar cursor_tool := \"\"\nvar cursor_quality := \"normal\"\nvar reselect_slot := 0\nvar predicted\nfunc hold(i: String, slot := 0) -> void:\n\tif i != cursor_item:\n\t\tcursor_quality = \"normal\"\n\tcursor_item = i\n\tcursor_slot = slot\n"
	stub.reload()
	var holder: Node = stub.new()
	holder.predicted = pred
	var player_was = ui.player
	var hand_was: Dictionary = ui.hand
	var had: Array = m.main_slots
	var had_slots := m.has_slots
	var had_counts: Dictionary = m.counts.duplicate()
	var had_qb: Array = m.quickbar.duplicate()
	var sorting: bool = ui.auto_sort
	var tick0 := Bridge.server_tick
	hud.screen.close()
	ui.close_all()
	ui.auto_sort = false
	ui.player = holder
	ui.hand = {}
	m.quickbar_upper = 0
	var qb: Array = []
	qb.resize(100)
	qb.fill("")
	qb[0] = "wooden-chest"
	m.handle({"t": "qb", "p": 1, "sel": 0, "held": "", "l": qb})
	var stock := func(a: int, b: int, c: int) -> void:
		var chests := func(n: int): return ["wooden-chest", n] if n > 0 else 0
		m.handle({"t": "slots", "l": {"main": [chests.call(a), ["iron-plate", 10], chests.call(b), chests.call(c), 0, 0, 0, 0, 0, 0]}})
	stock.call(3, 5, 2)
	sent()
	# L7: the key takes one stack, the biggest (slot 3's 5 of the 10).
	ui._quickbar_key(0)
	check(holder.cursor_item == "wooden-chest" and ui.held_slot() == 3 and ui.hand_count() == 5 and ui.cursor_count() == 5 and sent().is_empty(),
		"L7: a quickbar key takes one stack into the hand, not all of the item (slot %d, %d at the cursor of 10)" % [ui.held_slot(), ui.cursor_count()])
	ui.toggle_inventory()
	await get_tree().process_frame
	await get_tree().process_frame
	var grid: Node = ui.window._grid
	check(ui.window.hand_slot == ["main", 3, 0] and grid.get_child(2).hand and ui.cursor.count == 5 and ui.quickbar._slots[0].count == 10,
		"L7: its slot shows Factorio's hand, the cursor the stack's count, the quickbar all 10: %s" % [ui.window.hand_slot])
	# Builds from it: the hand's stack pays, then the stack the cursor refills from (the first of it).
	input.cursor_item = "wooden-chest"
	Bridge.server_tick = tick0
	input.drag.begin("wooden-chest", chest, Vector2(0.5, 0.5), false)
	for x in range(1, 5):
		input.drag.update(Vector2(x + 0.5, 0.5))
	var count5: int = ui.cursor_count()
	var slot5: int = ui.build_slot()
	for x in range(5, 7):
		input.drag.update(Vector2(x + 0.5, 0.5))
	input.drag.end()
	var named: Array = input.drag.sent.map(func(c: Dictionary) -> int: return int(c.get("hs", 0)))
	check(named == [3, 3, 3, 3, 3, 1, 1],
		"L7: each build names the held stack's slot (hs), then the stack the cursor refills from: %s" % [named])
	check(count5 == 3 and slot5 == 1 and ui.cursor_count() == 1,
		"L7: with its stack used up the cursor shows the next stack (3 after 5 built: %d, then %d)" % [count5, ui.cursor_count()])
	# L2: the quickbar and the inventory's slots count the 7 builds out at once; the inventory heard has 10 still.
	await get_tree().process_frame
	await get_tree().process_frame
	var bar: int = ui.quickbar._slots[0].count
	var shown: Array = m.shown_main_slots()
	check(m.count_of("wooden-chest") == 10 and m.shown_count_of("wooden-chest") == 3 and bar == 3,
		"L2: the quickbar counts the builds sent out at once (10 heard, 7 sent: %d)" % bar)
	check((shown[2] as Dictionary).is_empty() and int(shown[0]["count"]) == 1 and int(shown[3]["count"]) == 2 and int(shown[1]["count"]) == 10
		and grid.get_child(2).item == "" and grid.get_child(0).hand and grid.get_child(3).count == 2 and ui.window.hand_slot == ["main", 1, 0],
		"L2: the inventory's slots too: the hand's stack gone, the hand on the stack it refilled from, the others as they were: %s" % [shown.slice(0, 4)])
	UiModel.shown_fix = false
	ui._push_spent("wooden-chest")
	var bar_old: int = ui.quickbar._slots[0].count
	var old_same: bool = m.shown_main_slots() == m.main_slots and m.shown_count_of("wooden-chest") == 10
	UiModel.shown_fix = true
	ui._push_spent("wooden-chest")
	check(bar_old == 10 and old_same, "L2: --slot-counts=report: the quickbar and the slots wait for the report, as before (%d)" % bar_old)
	# The game builds them and reports: nothing spent, the hand on the stack the cursor refilled from.
	var unit := 950
	for c in input.drag.sent:
		unit += 1
		var e := [unit, 1, int(c["x"]), int(c["y"]), 0]
		pred.heard_add(e)
		world._add(e)
	pred._on_entities_changed(Vector2i.ZERO)
	stock.call(1, 0, 2)
	await get_tree().process_frame
	check(pred.unpaid("wooden-chest") == 0 and ui.held_slot() == 1 and ui.cursor_count() == 1 and m.shown_main_slots() == m.main_slots
		and ui.quickbar._slots[0].count == 3 and ui.window.hand_slot == ["main", 1, 0],
		"L7: after the report the hand is on the stack the cursor refilled from (slot %d, %d)" % [ui.held_slot(), ui.cursor_count()])
	# A build the game refuses: its item comes back to the slots and the quickbar.
	Bridge.server_tick = tick0
	input.drag.begin("wooden-chest", chest, Vector2(30.5, 0.5), false)
	input.drag.end()
	await get_tree().process_frame
	var spent_one: bool = ui.cursor_count() == 2 and ui.build_slot() == 4 and ui.quickbar._slots[0].count == 2 and (m.shown_main_slots()[0] as Dictionary).is_empty()
	Bridge.server_tick = tick0 + Predicted.REFUSED_TICKS
	pred._spends[0].msec -= Predicted.REFUSED_MSEC
	pred._process(0.0)
	await get_tree().process_frame
	check(spent_one and ui.cursor_count() == 1 and ui.build_slot() == 1 and ui.quickbar._slots[0].count == 3 and int(m.shown_stack_at(1).get("count", 0)) == 1,
		"L2: a build the game refuses gives its item back to the slots, the quickbar and the hand (sent: %s, back: %d)" % [spent_one, ui.quickbar._slots[0].count])
	# Q puts the stack back (it never left its slot); a click on a slot puts it down there.
	Bridge.server_tick = tick0
	sent()
	ui.clear_cursor()
	check(holder.cursor_item == "" and ui.hand.is_empty() and sent().is_empty(), "L7: Q puts the held stack back: the hand gone, nothing moved")
	ui._quickbar_key(0)
	var again: int = ui.held_slot()
	click_main(ui, 6)
	var mv := sent_one("move")
	check(again == 4 and int(mv.get("fi", 0)) == 4 and int(mv.get("ti", 0)) == 6 and mv.get("from") == "main" and holder.cursor_item == "",
		"L7: a click on an empty slot puts the held stack down there: %s" % [mv])
	# The cursor's quality is its stack's; another quality asked for (Ctrl+wheel, the pipette) takes a stack of it.
	m.handle({"t": "slots", "l": {"main": [["wooden-chest", 4], ["wooden-chest", 6, "rare"], 0, 0]}})
	# The pin has no quality, so the key holds the normal stack, not the bigger rare one.
	ui._quickbar_key(0)
	var normal: bool = ui.held_slot() == 1 and holder.cursor_quality == "normal"
	ui.hand_quality_changed("rare")
	var rare: bool = ui.held_slot() == 2
	ui.clear_cursor()
	ui.pick_from_inventory("wooden-chest", "rare")
	check(rare and normal and ui.held_slot() == 2 and holder.cursor_quality == "rare",
		"L7: the cursor's quality is the held stack's; asked for another, a stack of that quality comes into the hand")
	# With no normal stack left the pin holds the item alone at normal quality, as before L7.
	ui.clear_cursor()
	m.handle({"t": "slots", "l": {"main": [0, ["wooden-chest", 6, "rare"], 0, 0]}})
	ui._quickbar_key(0)
	check(holder.cursor_item == "wooden-chest" and ui.hand.is_empty() and holder.cursor_quality == "normal",
		"L7: a pin with only another quality left holds the item alone, normal, as before L7 (hand %s, %s)" % [ui.hand, holder.cursor_quality])
	ui.clear_cursor()
	# --hand-stack=all: the item with no stack, all of it counted, as before.
	stock.call(3, 5, 2)
	FactorioUi.stack_hand = false
	ui._quickbar_key(0)
	var all_held: bool = holder.cursor_item == "wooden-chest" and ui.hand.is_empty() and ui.hand_count() == 10 and ui.build_slot() == 0
	FactorioUi.stack_hand = true
	check(all_held, "L7: --hand-stack=all: the quickbar's item with no stack in the hand, all 10 counted, as before")
	ui.clear_cursor()
	m.inventory_changed.disconnect(pred.inventory_heard)
	Bridge.server_tick = tick0
	ui.close_all()
	ui.player = player_was
	ui.hand = hand_was
	ui.auto_sort = sorting
	m.main_slots = had
	m.counts = had_counts
	m.has_slots = had_slots
	m._shown = []
	m.set_spent({})
	m.quickbar = had_qb
	m.quickbar_changed.emit()
	holder.free()
	input.free()
	pred.queue_free()
	await get_tree().process_frame
	sent()


## L7, the testing agent's cases beside _hand_stack: tiles (`tile`), capsules (`throw`) and Z (`drop`) name the
## held stack's slot; a quickbar key with the inventory open takes a stack too; a pinned item with none left is
## held alone (no stack, nothing named); and the quickbar's pin (no quality) holds a normal stack while one is
## there, as before L7. Each but the last fails with --hand-stack=all.


func _hand_stack_more(hud: Hud) -> void:
	var ui = hud.ui
	var m: UiModel = ui.model
	var input := PlayerInput.new()
	input.hud = hud
	input.drag.pi = input
	input.tile_brush.pi = input
	input.capsule_aim.pi = input
	var stub := GDScript.new()
	stub.source_code = "extends Node\nvar cursor_item := \"\"\nvar cursor_slot := 0\nvar cursor_tool := \"\"\nvar cursor_quality := \"normal\"\nvar reselect_slot := 0\nvar predicted\nfunc hold(i: String, slot := 0) -> void:\n\tif i != cursor_item:\n\t\tcursor_quality = \"normal\"\n\tcursor_item = i\n\tcursor_slot = slot\n"
	stub.reload()
	var holder: Node = stub.new()
	var player_was = ui.player
	var hand_was: Dictionary = ui.hand
	var had: Array = m.main_slots
	var had_slots := m.has_slots
	var had_counts: Dictionary = m.counts.duplicate()
	var had_qb: Array = m.quickbar.duplicate()
	var had_uses: Dictionary = m.item_uses.duplicate(true)
	var sorting: bool = ui.auto_sort
	hud.screen.close()
	ui.close_all()
	ui.auto_sort = false
	ui.player = holder
	ui.hand = {}
	m.quickbar_upper = 0
	m.handle({"t": "iuse", "part": 1, "parts": 1, "l": [["concrete", "t", "concrete", "", [1]], ["grenade", "c", "throw", 15, 6.5]]})
	var qb: Array = []
	qb.resize(100)
	qb.fill("")
	qb[0] = "concrete"
	qb[1] = "grenade"
	qb[2] = "transport-belt"
	qb[3] = "iron-chest"
	m.handle({"t": "qb", "p": 1, "sel": 0, "held": "", "l": qb})
	m.handle({"t": "slots", "l": {"main": [["concrete", 40], ["concrete", 100], ["grenade", 5], ["grenade", 10],
		["transport-belt", 10], ["transport-belt", 30, "rare"], 0, 0, 0, 0]}})
	sent()
	var per_switch := {}
	for on in [true, false]:
		FactorioUi.stack_hand = on
		var r := {}
		ui.clear_cursor()
		ui._quickbar_key(0)
		input.cursor_item = holder.cursor_item
		r["concrete_slot"] = ui.held_slot()
		input.tile_brush.size = 1
		input.tile_brush._last_paint = Vector2(-999, -999)
		input.tile_brush._timer = 0.0
		input.tile_brush.paint("concrete", Vector2(4.5, 3.5), false, 1.0)
		r["tile"] = sent_one("tile")
		ui.clear_cursor()
		ui._quickbar_key(1)
		input.cursor_item = holder.cursor_item
		r["grenade_slot"] = ui.held_slot()
		input.capsule_aim._next_msec = 0  # (the capsule's cooldown, held across clicks)
		input.capsule_aim.hold("grenade", Vector2(3, 3), 1.0)
		r["throw"] = sent_one("throw")
		input.has_ground = true
		input.ground = Vector2(1.5, 1.5)
		input._drop_timer = 0.0
		Input.action_press("drop_item")
		input._update_drop(1.0)
		Input.action_release("drop_item")
		r["drop"] = sent_one("drop")
		# The inventory open: the key still takes a stack (K18's path: a pinned slot's key picks).
		ui.clear_cursor()
		ui.toggle_inventory()
		await get_tree().process_frame
		ui._quickbar_key(0)
		r["open_slot"] = ui.held_slot()
		r["open_item"] = holder.cursor_item
		ui.close_all()
		await get_tree().process_frame
		# A pin with none of it in the inventory: the item alone, as a ghost cursor builds.
		ui.clear_cursor()
		ui._quickbar_key(3)
		r["none"] = [holder.cursor_item, ui.hand.is_empty(), ui.build_slot(), ui.hand_count()]
		# Two qualities: the quickbar's pin has none, so it is the normal one (before L7 the cursor stayed normal).
		ui.clear_cursor()
		ui._quickbar_key(2)
		r["belt"] = [ui.held_slot(), str(holder.cursor_quality)]
		# A stack picked from the inventory: L7 gives the cursor its quality; --hand-stack=all leaves the
		# cursor's quality alone, as before L7 (the pipette sets its own after).
		ui.clear_cursor()
		ui.pick_from_inventory("transport-belt", "rare")
		r["pick_q"] = str(holder.cursor_quality)
		ui.clear_cursor()
		per_switch[on] = r
	FactorioUi.stack_hand = true
	var on_r: Dictionary = per_switch[true]
	var off_r: Dictionary = per_switch[false]
	check(int(on_r["concrete_slot"]) == 2 and int(on_r["tile"].get("hs", 0)) == 2 and not off_r["tile"].has("hs"),
		"L7: tiles are laid out of the held stack (`tile` hs %s; --hand-stack=all: none, %s)" % [on_r["tile"].get("hs"), off_r["tile"].get("hs")])
	check(int(on_r["grenade_slot"]) == 4 and int(on_r["throw"].get("hs", 0)) == 4 and not off_r["throw"].has("hs"),
		"L7: a capsule is thrown out of the held stack (`throw` hs %s; --hand-stack=all: none)" % [on_r["throw"].get("hs")])
	check(int(on_r["drop"].get("hs", 0)) == 4 and on_r["drop"].get("item") == "grenade" and off_r["drop"].get("item") == "grenade" and not off_r["drop"].has("hs"),
		"L7: Z drops out of the held stack (`drop` hs %s; --hand-stack=all: none)" % [on_r["drop"].get("hs")])
	check(int(on_r["open_slot"]) == 2 and on_r["open_item"] == "concrete" and int(off_r["open_slot"]) == 0 and off_r["open_item"] == "concrete",
		"L7: with the inventory open a quickbar key takes one stack too (slot %d; --hand-stack=all %d)" % [on_r["open_slot"], off_r["open_slot"]])
	check(on_r["none"] == ["iron-chest", true, 0, 0] and off_r["none"] == ["iron-chest", true, 0, 0],
		"L7: a pinned item with none left is held alone, nothing named for the bridge: %s" % [on_r["none"]])
	check(on_r["belt"] == [5, "normal"] and off_r["belt"][1] == "normal",
		"L7: a quickbar pin (no quality) holds a normal stack while there is one, not the bigger rare one: %s (--hand-stack=all: %s)" % [on_r["belt"], off_r["belt"]])
	check(on_r["pick_q"] == "rare" and off_r["pick_q"] == "normal",
		"L7: a stack picked up gives the cursor its quality; --hand-stack=all leaves it as before L7 (%s, off %s)" % [on_r["pick_q"], off_r["pick_q"]])
	ui.clear_cursor()
	ui.close_all()
	ui.player = player_was
	ui.hand = hand_was
	ui.auto_sort = sorting
	m.main_slots = had
	m.counts = had_counts
	m.has_slots = had_slots
	m.item_uses = had_uses
	m._shown = []
	m.set_spent({})
	m.quickbar = had_qb
	m.quickbar_changed.emit()
	holder.free()
	input.free()
	await get_tree().process_frame
	sent()


## N3: in a car, tank or spidertron the tool bar shows the vehicle's guns over their ammo (`guns`
## with `v`), the selected one pressed; a click uses the vehicle's gun, a held stack goes into its
## ammo (`vammo`); out of it the character's three come back.


func _vehicle_guns(hud: Hud) -> void:
	var ui = hud.ui
	var m = ui.model
	var w = ui.weapons
	ui.close_all()
	ui.hand = {}
	m.other_slots["guns"] = [{"item": "pistol", "count": 1}, {"item": "submachine-gun", "count": 1}, {"item": "shotgun", "count": 1}]
	m.other_slots["ammo"] = [{"item": "firearm-magazine", "count": 100}, {}, {"item": "shotgun-shell", "count": 12}]
	hud.set_guns(3, [["pistol", "firearm-magazine", 100], ["submachine-gun", "", 0], ["shotgun", "shotgun-shell", 12]])
	await get_tree().process_frame
	check(w._guns.size() == 3 and w._guns[2].item == "shotgun" and w._guns[2].button_pressed, "N3: on foot the character's guns, the shotgun in use")
	hud.set_guns(2, [["vehicle-machine-gun", "piercing-rounds-magazine", 20, 7, 10], ["tank-cannon", "cannon-shell", 5, 1, 1],
		["tank-flamethrower", "", 0, 0, 0]], 77)
	await get_tree().process_frame
	check(w.shown_vehicle == 77 and w._guns.size() == 3 and w._guns[0].item == "vehicle-machine-gun" and w._guns[1].item == "tank-cannon"
		and w._guns[2].item == "tank-flamethrower", "N3: in a tank the tool bar shows its three guns")
	check(w._ammo[0].item == "piercing-rounds-magazine" and w._ammo[0].count == 20 and w._ammo[1].item == "cannon-shell"
		and w._ammo[2].item == "", "N3: and their ammo with counts, not the character's")
	check(w._guns[1].button_pressed and not w._guns[0].button_pressed and w._ammo[1].button_pressed, "N3: the vehicle's selected gun is pressed")
	sent()
	w._guns[0].clicked.emit(MOUSE_BUTTON_LEFT, false)
	check(int(sent_one("gun").get("i", 0)) == 1, "N3: clicking a vehicle gun uses it")
	var hand_was: Dictionary = ui.hand
	ui.hand = {"role": "main", "index": 1, "n": 0, "unit": 0, "item": "piercing-rounds-magazine"}
	var held_was: String = ui.player.cursor_item
	ui.player.cursor_item = "piercing-rounds-magazine"
	w._ammo[0].clicked.emit(MOUSE_BUTTON_LEFT, false)
	var mv := sent_one("move")
	check(mv.get("from") == "main" and mv.get("to") == "vammo" and int(mv.get("ti", 0)) == 1, "N3: a held stack goes into the vehicle's ammo slot: %s" % mv)
	ui.hand = hand_was
	ui.player.cursor_item = held_was
	hud.set_guns(1, [["spidertron-rocket-launcher-1", "rocket", 10], ["spidertron-rocket-launcher-2", "", 0],
		["spidertron-rocket-launcher-3", "", 0], ["spidertron-rocket-launcher-4", "", 0]], 78)
	await get_tree().process_frame
	check(w._guns.size() == 4 and w._guns[3].item == "spidertron-rocket-launcher-4" and w._ammo[0].count == 10, "N3: a spidertron's four rocket launchers")
	hud.set_guns(3, [["pistol", "firearm-magazine", 100], ["submachine-gun", "", 0], ["shotgun", "shotgun-shell", 12]])
	await get_tree().process_frame
	check(w.shown_vehicle == 0 and w._guns.size() == 3 and w._guns[0].item == "pistol" and w._ammo[2].item == "shotgun-shell"
		and w._guns[2].button_pressed, "N3: out of the vehicle the character's guns come back")
	m.other_slots.erase("guns")
	m.other_slots.erase("ammo")
	sent()


## The tenth play-test list's quickbar, as Factorio 2.1's (its wiki's Quickbar page, the changelog, its
## interface settings, where "Set quickbar filter by clicking with item" is off by default): K17 a
## slot's key, or a click on it, with its item already in the hand puts the hand back, however the item
## came there, a ghost cursor too; K18 neither a key nor a click on a pinned slot changes what it
## holds, the inventory open or not: only a click on an empty slot pins the held item.


func _quickbar_hand(hud: Hud, player: Node) -> void:
	var ui = hud.ui
	var m = ui.model
	hud.screen.close()
	ui.close_all()
	ui.hand = {}
	player.cursor_item = ""
	ui.window.hovered_item = ""
	var sorting: bool = ui.auto_sort
	ui.auto_sort = false
	m.quickbar_upper = 0
	# The bridge keeps the quickbar: a pin goes to it as `qb_set` and comes back in its next `qb`.
	var qb: Array = []
	qb.resize(100)
	qb.fill("")
	qb[1] = "wooden-chest"  # slot 2
	qb[2] = "transport-belt"  # slot 3
	qb[4] = "iron-plate"  # slot 5
	qb[6] = "stone-furnace"  # slot 7: none in the inventory
	qb[10] = "copper-plate"  # page 2, the second row's first slot
	m.handle({"t": "qb", "p": 1, "sel": 0, "held": "", "l": qb})
	m.handle({"t": "slots", "l": {"main": [["transport-belt", 50], ["wooden-chest", 10], ["iron-plate", 60], ["copper-plate", 20],
		0, 0, 0, 0, 0, 0]}})
	await get_tree().process_frame
	sent()
	var before: Array = m.quickbar.duplicate()
	# What would change the quickbar or move a stack: none of it may be sent.
	var touched := func() -> Array:
		return sent().filter(func(c: Dictionary) -> bool: return ["qb_set", "drop", "move", "xfer", "put"].has(str(c.get("t", ""))))
	var press := func(k: Key) -> void:
		key(k)
		await get_tree().process_frame
	for open in [false, true]:
		var where := " (inventory open)" if open else ""
		if open:
			ui.toggle_inventory()
			await get_tree().process_frame
			get_viewport().gui_release_focus()
		await press.call(KEY_3)
		# L7: one stack of them, the hand on its slot (not the item alone with every belt counted).
		check(player.cursor_item == "transport-belt" and ui.held_slot() == 1, "K17: 3 puts slot 3's belts in the hand" + where)
		await press.call(KEY_3)
		var moved: Array = touched.call()
		check(player.cursor_item == "" and ui.hand.is_empty() and m.count_of("transport-belt") == 50 and moved.is_empty() and m.quickbar == before,
			"K17: 3 again empties the hand: the belts stay in the inventory, nothing dropped or moved, the quickbar as it was%s: %s" % [where, moved])
		await press.call(KEY_2)
		await press.call(KEY_3)
		check(player.cursor_item == "transport-belt" and touched.call().is_empty() and m.quickbar == before,
			"K17: 3 with slot 2's chest in the hand takes slot 3's belts instead, as before" + where)
		await press.call(KEY_3)
		check(player.cursor_item == "", "K17: and 3 puts them back" + where)
		await press.call(KEY_7)
		check(player.cursor_item == "stone-furnace", "K17: 7 with no furnaces in the inventory: a ghost cursor" + where)
		await press.call(KEY_7)
		check(player.cursor_item == "", "K17: 7 again puts the ghost cursor away too" + where)
		# K18: slot 2 holds the chest; picking it and then slot 5 leaves both slots as they were.
		await press.call(KEY_2)
		await press.call(KEY_5)
		moved = touched.call()
		check(player.cursor_item == "iron-plate" and moved.is_empty() and m.quickbar == before,
			"K18: 2 then 5: the plates in the hand, slot 2 still the chest and slot 5 still the plates%s: %s %s" % [where, moved, m.quickbar])
		ui._on_quickbar_clicked(1, MOUSE_BUTTON_LEFT)
		check(player.cursor_item == "wooden-chest", "K18: a click on slot 2 with the plates in the hand picks the chest" + where)
		ui._on_quickbar_clicked(4, MOUSE_BUTTON_LEFT)
		moved = touched.call()
		check(player.cursor_item == "iron-plate" and moved.is_empty() and m.quickbar == before,
			"K18: then a click on slot 5 picks the plates, neither slot changed%s: %s" % [where, moved])
		ui._on_quickbar_clicked(4, MOUSE_BUTTON_LEFT)
		check(player.cursor_item == "" and touched.call().is_empty(), "K17: a click on the slot of what the hand holds puts it back" + where)
		ui._on_second_quickbar_clicked(0, MOUSE_BUTTON_LEFT)
		check(player.cursor_item == "copper-plate" and touched.call().is_empty(), "K18: the second row's slot picks its item, not pinned over" + where)
		ui._on_quickbar_clicked(1, MOUSE_BUTTON_LEFT)
		ui._on_second_quickbar_clicked(0, MOUSE_BUTTON_LEFT)
		check(player.cursor_item == "copper-plate" and touched.call().is_empty() and m.quickbar == before,
			"K18: a click on the second row with the chest in the hand picks the copper, slot 2 kept" + where)
		ui._on_second_quickbar_clicked(0, MOUSE_BUTTON_LEFT)
		check(player.cursor_item == "", "K17: and on it again puts the hand back" + where)
	# The item in the hand from an inventory slot, not the quickbar: its key puts it back the same way.
	click_main(ui, 1)
	await get_tree().process_frame
	check(player.cursor_item == "transport-belt" and ui.held_slot() == 1, "K17: belts picked up from inventory slot 1")
	await press.call(KEY_3)
	await get_tree().process_frame
	check(player.cursor_item == "" and ui.hand.is_empty() and ui.window.hand_slot.is_empty() and touched.call().is_empty(),
		"K17: 3 puts belts picked up from a slot back into it (the hand's mark gone, nothing sent)")
	# Over a pinned slot the hovered item doesn't pin either; over an empty one it does (quick pipette).
	ui.window.hovered_item = "copper-plate"
	await press.call(KEY_2)
	check(player.cursor_item == "wooden-chest" and touched.call().is_empty() and m.quickbar == before,
		"K18: 2 with the copper hovered picks slot 2's chest, the slot kept")
	await press.call(KEY_4)
	var pins: Array = sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "qb_set" and c.get("item") == "copper-plate")
	check(pins.any(func(c: Dictionary) -> bool: return int(c.get("i", 0)) == 4) and player.cursor_item == "wooden-chest",
		"an empty slot's key pins the hovered item (Factorio's quick pipette): %s" % [pins])
	ui.window.hovered_item = ""
	m.handle({"t": "qb", "p": 1, "sel": 0, "held": "", "l": qb})
	await press.call(KEY_4)
	check(player.cursor_item == "wooden-chest" and touched.call().is_empty() and m.quickbar == before,
		"K18: an empty slot's key with the chest in the hand pins nothing")
	ui._on_quickbar_clicked(3, MOUSE_BUTTON_LEFT)
	pins = sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "qb_set" and c.get("item") == "wooden-chest")
	check(pins.any(func(c: Dictionary) -> bool: return int(c.get("i", 0)) == 4), "a click on an empty slot pins the held item: %s" % [pins])
	m.handle({"t": "qb", "p": 1, "sel": 0, "held": "", "l": qb})
	ui.close_all()
	ui.hand = {}
	player.cursor_item = ""
	ui.auto_sort = sorting
	await get_tree().process_frame
	sent()


## The owner's ninth play-test list: the hand refilled after a Ctrl+click (J3), the character
## window's Crafting and Logistics tabs, Logistics only once researched (J7, J8), the inventory
## sorting itself (J12), a long crafting queue's "+N" (J13), the recipe tooltip in an assembler's
## chooser and its red lines (J14, J16), and the technology screen opening on its technology (J17).


func _ninth_list(hud: Hud, player: Node) -> void:
	var ui = hud.ui
	var m = ui.model
	var screen: MachineScreen = hud.screen
	screen.close()
	ui.close_all()
	ui.hand = {}
	player.cursor_item = ""
	await get_tree().process_frame
	sent()
	var row10 := func(first: Array) -> Array:
		var out: Array = first.duplicate()
		while out.size() < 10:
			out.append(0)
		return out

	# --- J3: a Ctrl+click that empties the hand takes the next stack into it ------------------------
	m.handle({"t": "slots", "l": {"main": row10.call([["coal", 50], ["iron-plate", 100], ["coal", 30]])}})
	ui.toggle_inventory()
	click_main(ui, 1)
	await get_tree().process_frame
	ui.close_all()
	check(player.cursor_item == "coal" and ui.hand.get("index") == 1 and ui.held_slot() == 1, "J3: a stack of coal in the hand, from slot 1")
	ui.fast_transfer_sent("coal", Vector3.ZERO)
	m.handle({"t": "slots", "l": {"main": row10.call([0, ["iron-plate", 100], ["coal", 30]])}})
	await get_tree().process_frame
	check(player.cursor_item == "coal" and ui.hand.get("index") == 3 and ui.hand_count() == 30 and ui.held_slot() == 3,
		"J3: the Ctrl+click emptied it: the next stack of coal comes into the hand (%s, %d)" % [ui.hand, ui.hand_count()])
	ui.fast_transfer_sent("coal", Vector3.ZERO)
	m.handle({"t": "slots", "l": {"main": row10.call([0, ["iron-plate", 100], 0])}})
	await get_tree().process_frame
	check(player.cursor_item == "" and ui.hand.is_empty(), "J3: with no coal left the hand empties (no ghost cursor, I1)")

	# --- J7, J8: Crafting and Logistics tabs, Logistics once researched -----------------------------
	var w = ui.window
	m.char_logistics = false
	m.logistics_changed.emit()
	w.show_tab("Crafting")
	ui.toggle_inventory()
	await get_tree().process_frame
	check(not w._tabs_row.visible and w._crafting_caption.visible and w._crafting_caption.text == "Crafting"
		and w._crafting.is_visible_in_tree(), "J8: before the research the right half is Crafting alone, under its title")
	w.show_tab("Logistics")
	check(w.current_tab() == "Crafting" and not w._logistics.is_visible_in_tree(), "J8: and has no Logistics tab to open")
	m.handle({"t": "clog", "on": 1, "trash": 0, "l": [["iron-plate", 100, -1]]})
	await get_tree().process_frame
	check(m.char_logistics and w._tabs_row.is_visible_in_tree() and not w._crafting_caption.visible
		and (w._tab_buttons["Crafting"] as Button).button_pressed and not (w._tab_buttons["Logistics"] as Button).button_pressed,
		"J7: once researched (the bridge's first clog) the title is Factorio's Crafting and Logistics tabs, Crafting chosen")
	var crafting_size: Vector2 = w._crafting_frame.get_combined_minimum_size()
	(w._tab_buttons["Logistics"] as Button).pressed.emit()
	await get_tree().process_frame
	check(is_equal_approx(w._crafting_frame.get_combined_minimum_size().x, crafting_size.x),
		"J7: both tabs as wide, so switching doesn't move the window (%s, %s)" % [crafting_size, w._crafting_frame.get_combined_minimum_size()])
	check(w.current_tab() == "Logistics" and w._logistics.is_visible_in_tree() and not w._crafting.is_visible_in_tree()
		and (w._tab_buttons["Logistics"] as Button).button_pressed and _find_checkbox(w._logistics, "Personal logistics") != null,
		"J7: the Logistics tab shows the character's logistics in Crafting's place")
	check(w._crafting_frame.is_ancestor_of(w._logistics) and w.get("_logistics_frame") == null,
		"J7: on the right half, not a part of its own between the inventory and crafting")
	w.focus_search()
	check(w.current_tab() == "Crafting" and w._crafting.is_visible_in_tree(), "J7: Ctrl+F goes back to Crafting for its search")
	w._crafting.search.text = ""
	w._crafting.search.visible = false
	w._crafting.search.release_focus()
	ui.close_all()

	# --- J12: the main inventory sorts itself -----------------------------------------------------
	ui.auto_sort = true
	ui._sort_due = false
	ui._sort_pending = false
	var sorts := func() -> Array: return sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "sort")
	sent()
	m.handle({"t": "slots", "l": {"main": row10.call([["iron-plate", 10], 0, ["coal", 5]])}})
	ui._sort_sent_ms = -100000
	await get_tree().process_frame
	var asked: Array = sorts.call()
	check(asked.size() == 1 and asked[0].get("inv") == "main", "J12: the inventory changed with no window open: the bridge is asked to sort it")
	m.handle({"t": "slots", "l": {"main": row10.call([["coal", 5], ["iron-plate", 10]])}})  # its answer
	ui._sort_sent_ms = -100000
	await get_tree().process_frame
	check(sorts.call().is_empty(), "J12: the sorted answer asks for nothing more")
	ui.toggle_inventory()
	m.handle({"t": "slots", "l": {"main": row10.call([0, ["iron-plate", 10], 0, 0, ["coal", 5]])}})
	ui._sort_sent_ms = -100000
	await get_tree().process_frame
	check(sorts.call().size() == (0 if Switches.has("--auto-sort-open=old") else 1),
		"J12: inventory sorts even while the window is open (unless --auto-sort-open=old)")
	ui.close_all()
	await get_tree().process_frame
	m.handle({"t": "slots", "l": {"main": row10.call([["coal", 5], ["iron-plate", 10]])}})
	ui.toggle_inventory()
	click_main(ui, 1)
	ui.close_all()
	m.handle({"t": "slots", "l": {"main": row10.call([["coal", 5], ["iron-plate", 10], 0, ["wood", 4]])}})
	ui._sort_sent_ms = -100000
	await get_tree().process_frame
	check(player.cursor_item == "coal" and sorts.call().is_empty(), "J12: not while the hand holds one of its stacks (sorting would move it)")
	ui.clear_cursor()
	ui._sort_sent_ms = -100000
	await get_tree().process_frame
	check(sorts.call().size() == 1, "J12: and once the hand is empty again")
	# Bug #19: a sort answer that still has a gap re-triggers sorting if counts match.
	m.handle({"t": "slots", "l": {"main": row10.call([["coal", 5], 0, ["iron-plate", 10], ["wood", 4]])}})
	ui._sort_sent_ms = -100000
	await get_tree().process_frame
	check(sorts.call().size() == 1, "#19: a sort answer with a gap still schedules a re-sort")
	ui.auto_sort = false

	# --- Batch 3 C12: All-inventory auto-sort (trash, chest, cargo, trunk) ------------------------
	check(bool(Settings.DEFAULTS["interface"].get("auto_sort_inventory", false))
		and bool(Settings.DEFAULTS["interface"].get("auto_sort_containers", false)),
		"C12: Settings defaults enable auto_sort_inventory and auto_sort_containers")
	var was_auto_containers: bool = ui.auto_sort_containers
	ui.auto_sort_containers = true
	ui._trash_sent_ms = -100000
	m.handle({"t": "slots", "l": {"main": row10.call([["iron-plate", 5]]), "trash": [0, ["wood", 3]]}})
	await get_tree().process_frame
	var trash_sorts: Array = sorts.call().filter(func(c: Dictionary) -> bool: return str(c.get("inv", "")) == "trash")
	check(trash_sorts.size() == 1, "C12: character trash gap triggers sort inv='trash': %s" % [trash_sorts])
	ui.screen.request(520, {"t": "open", "u": 520, "p": 0, "x": 0, "y": 0})
	ui.screen.handle({"t": "gui", "u": 520, "p": 0, "kind": "container", "name": "wooden-chest",
		"inv": {"chest": {}}, "slots": {"chest": [0, ["iron-plate", 4]]}})
	await get_tree().process_frame
	var chest_sorts: Array = sorts.call().filter(func(c: Dictionary) -> bool: return str(c.get("inv", "")) == "chest" and int(c.get("u", 0)) == 520)
	check(chest_sorts.size() == 1, "C12: open chest gap triggers sort inv='chest': %s" % [chest_sorts])
	ui.screen.request(521, {"t": "open", "u": 521, "p": 0, "x": 0, "y": 0})
	ui.screen.handle({"t": "gui", "u": 521, "p": 0, "kind": "train", "name": "cargo-wagon",
		"inv": {"cargo": {}}, "slots": {"cargo": [0, ["coal", 4]]}, "bar": 2})
	await get_tree().process_frame
	var cargo_sorts: Array = sorts.call().filter(func(c: Dictionary) -> bool: return str(c.get("inv", "")) == "cargo" and int(c.get("u", 0)) == 521)
	check(cargo_sorts.size() == 1, "C12: open cargo-wagon gap triggers sort inv='cargo': %s" % [cargo_sorts])
	ui.screen.request(522, {"t": "open", "u": 522, "p": 0, "x": 0, "y": 0})
	ui.screen.handle({"t": "gui", "u": 522, "p": 0, "kind": "vehicle", "name": "car",
		"inv": {"trunk": {}}, "slots": {"trunk": [0, ["stone", 2]]}})
	await get_tree().process_frame
	var trunk_sorts: Array = sorts.call().filter(func(c: Dictionary) -> bool: return str(c.get("inv", "")) == "trunk" and int(c.get("u", 0)) == 522)
	check(trunk_sorts.size() == 1, "C12: open car trunk gap triggers sort inv='trunk': %s" % [trunk_sorts])
	ui.auto_sort_containers = false
	m.handle({"t": "slots", "l": {"main": row10.call([["iron-plate", 5]]), "trash": [0, ["coal", 2]]}})
	ui.screen.handle({"t": "gui", "u": 520, "p": 0, "kind": "container", "name": "wooden-chest",
		"inv": {"chest": {}}, "slots": {"chest": [0, ["copper-plate", 4]]}})
	await get_tree().process_frame
	check(sorts.call().is_empty(), "C12: auto_sort_containers=false suppresses container and trash auto-sorts")
	ui.screen.close()
	ui.auto_sort_containers = was_auto_containers

	# --- Batch 3 C2: 1 s orange new-item slot flash preserved across sort & --inv-slot-flash=off --
	var fm := UiModel.new()
	fm.set_inventory_slots([["iron-plate", 5], 0, 0, 0], 4)
	var first_load_hl := fm.main_highlight_until(1)
	fm.set_inventory_slots([["iron-plate", 5], 0, ["copper-plate", 3], 0], 4)
	var added_hl := fm.main_highlight_until(3)
	fm.set_inventory_slots([["copper-plate", 3], ["iron-plate", 5], 0, 0], 4)
	var sorted_new_hl := fm.main_highlight_until(1)
	var sorted_old_hl := fm.main_highlight_until(3)
	check(first_load_hl == 0 and added_hl > 0 and sorted_new_hl > 0 and sorted_old_hl == 0,
		"C2: new item flashes 1s and flash moves with stack across sort (init=%d add=%d moved=%d old=%d)" % [first_load_hl, added_hl, sorted_new_hl, sorted_old_hl])
	var hl_slot := Slot.new()
	var was_flash := Slot.slot_flash
	Slot.slot_flash = true
	hl_slot.set_highlight(Time.get_ticks_msec() + 900)
	var flash_on := hl_slot.highlight_until > 0 and hl_slot.is_processing()
	Slot.slot_flash = false
	hl_slot.set_highlight(Time.get_ticks_msec() + 900)
	var flash_off := hl_slot.highlight_until == 0
	check(flash_on and flash_off, "C2: Slot.set_highlight honours --inv-slot-flash=off (%s, %s)" % [flash_on, flash_off])
	Slot.slot_flash = was_flash
	hl_slot.free()

	# --- Batch 2 #1: UI item move/pickup SFX & --inv-move-sfx=off -------------------------------
	const Sfx := preload("res://scripts/fx/sfx.gd")
	var sfx_stub_script := GDScript.new()
	sfx_stub_script.source_code = "extends Node\nvar played := []\nfunc play_flat(path: String, volume: float, kind := \"\", bus := \"UI\") -> void:\n\tplayed.append([path, volume, kind, bus])\n"
	sfx_stub_script.reload()
	var sfx_stub: Node = sfx_stub_script.new()
	var was_sfx = Sfx.instance
	var was_move_sfx := FactorioUi.inv_move_sfx
	Sfx.instance = sfx_stub
	FactorioUi.inv_move_sfx = true
	m.handle({"t": "slots", "l": {"main": row10.call([["iron-plate", 10], 0, 0])}})
	ui.toggle_inventory()
	await get_tree().process_frame
	sfx_stub.played.clear()
	ui._on_character_slot("main", 1, MOUSE_BUTTON_LEFT, false, false)
	var pick_sfx_count: int = sfx_stub.played.size()
	ui._on_character_slot("main", 2, MOUSE_BUTTON_LEFT, false, false)
	var put_sfx_count: int = sfx_stub.played.size() - pick_sfx_count
	ui._on_character_slot("main", 1, MOUSE_BUTTON_LEFT, false, false)
	sfx_stub.played.clear()
	ui.clear_cursor()
	var clear_sfx_count: int = sfx_stub.played.size()
	FactorioUi.inv_move_sfx = false
	sfx_stub.played.clear()
	ui._on_character_slot("main", 2, MOUSE_BUTTON_LEFT, false, false)
	ui._on_character_slot("main", 1, MOUSE_BUTTON_LEFT, false, false)
	var off_sfx_count: int = sfx_stub.played.size()
	check(pick_sfx_count >= 1 and put_sfx_count >= 1 and clear_sfx_count >= 1 and off_sfx_count == 0,
		"B2#1: inventory pick/move/clear play UI SFX and --inv-move-sfx=off silences them (pick=%d put=%d clear=%d off=%d)" % [pick_sfx_count, put_sfx_count, clear_sfx_count, off_sfx_count])
	FactorioUi.inv_move_sfx = was_move_sfx
	Sfx.instance = was_sfx
	sfx_stub.free()
	ui.clear_cursor()
	ui.close_all()
	sent()

	# --- Bug #4 + Batch 2 #6/#7/#8: LimitButton clear-and-reselect, hover preview, Esc/RMB, barred move ---
	var chest_slots := []
	for i in 10:
		chest_slots.append({})
	m.handle({"t": "slots", "l": {"main": row10.call([["iron-plate", 5], ["copper-plate", 5], ["coal", 5]])}})
	ui.screen.request(501, {"t": "open", "u": 501, "p": 0, "x": 0, "y": 0})
	ui.screen.handle({"t": "gui", "u": 501, "p": 0, "kind": "container", "name": "wooden-chest",
		"inv": {"chest": {}}, "slots": {"chest": chest_slots}, "bar": 2})
	await get_tree().process_frame
	var limit_btn := ui.screen.find_child("LimitButton", true, false) as Slot
	var chest_grid_node := limit_btn.get_parent() if limit_btn != null else null
	check(limit_btn != null and chest_grid_node != null and chest_grid_node.get_child(10) == limit_btn,
		"#4: container LimitButton is placed after the last slot (index 10), not at bar=2")
	sent()
	if limit_btn != null:
		limit_btn.clicked.emit(MOUSE_BUTTON_LEFT, false)
		var first_bar_cmds: Array = sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "set_bar")
		check(ui.screen._setting_bar and first_bar_cmds.size() == 1 and int(first_bar_cmds[0].get("n", -1)) == 10,
			"#4 + B2#8: first LMB on LimitButton with bar=2 clears to 10 immediately AND enters bar-setting mode: %s" % [first_bar_cmds])
		# B2#7: live mouse-hover red barred preview and Esc / RMB cancel (re-fetch grid after _rebuild_now).
		var grid_fn := func() -> Control:
			var lb := ui.screen.find_child("LimitButton", true, false) as Slot
			return lb.get_parent() if lb != null else null
		var g_hover: Control = grid_fn.call()
		ui.screen.set_bar_hover(4)
		var prev_ok: bool = g_hover != null and not (g_hover.get_child(2) as Slot).blocked and (g_hover.get_child(3) as Slot).blocked
		var esc := InputEventKey.new()
		esc.pressed = true
		esc.physical_keycode = KEY_ESCAPE
		ui.screen._unhandled_key_input(esc)
		var g_esc: Control = grid_fn.call()
		var esc_ok: bool = not ui.screen._setting_bar and g_esc != null and not (g_esc.get_child(3) as Slot).blocked
		check(prev_ok and esc_ok, "B2#7: live hover previews red barred slots and Esc cancels without changing limit (%s, %s)" % [prev_ok, esc_ok])
		var limit_btn2 := ui.screen.find_child("LimitButton", true, false) as Slot
		if limit_btn2 != null:
			limit_btn2.clicked.emit(MOUSE_BUTTON_LEFT, false)
		ui.screen.set_bar_hover(6)
		var g_rmb: Control = grid_fn.call()
		if g_rmb != null:
			(g_rmb.get_child(5) as Slot).clicked.emit(MOUSE_BUTTON_RIGHT, false)
		check(not ui.screen._setting_bar and sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "set_bar").is_empty(),
			"B2#7: RMB cancels bar-setting without sending set_bar")
		# Select limit bar = 4 (clicking slot index 5) and test B2#6 manual move into barred slot 7.
		var limit_btn3 := ui.screen.find_child("LimitButton", true, false) as Slot
		if limit_btn3 != null:
			limit_btn3.clicked.emit(MOUSE_BUTTON_LEFT, false)
		var g_pick: Control = grid_fn.call()
		if g_pick != null:
			(g_pick.get_child(4) as Slot).clicked.emit(MOUSE_BUTTON_LEFT, false)
		var pick_bar_cmds: Array = sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "set_bar")
		var g_barred: Control = grid_fn.call()
		check(not ui.screen._setting_bar and pick_bar_cmds.size() == 1 and int(pick_bar_cmds[0].get("n", -1)) == 4
			and g_barred != null and (g_barred.get_child(5) as Slot).blocked,
			"B2#7: clicking slot 5 sets bar=4 and marks slots 5+ blocked: %s" % [pick_bar_cmds])
		ui._on_character_slot("main", 1, MOUSE_BUTTON_LEFT, false, false)
		sent()
		if g_barred != null:
			(g_barred.get_child(6) as Slot).clicked.emit(MOUSE_BUTTON_LEFT, false)
		var barred_moves: Array = sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "move" and str(c.get("to", "")) == "chest" and int(c.get("ti", 0)) == 7)
		check(barred_moves.size() == 1, "B2#6: manual click into barred chest slot 7 sends move command: %s" % [barred_moves])
		ui.clear_cursor()
		sent()

	# --- Bug #11: Shift+LMB drag transfers multiple same-side slots without Godot DnD ---
	var test_slot := Slot.new()
	test_slot.drag_item = "iron-plate"
	Slot.spreading = false
	check(test_slot._get_drag_data(Vector2.ZERO) != null, "#11: normal slot drag returns preview")
	Slot.spreading = true
	check(test_slot._get_drag_data(Vector2.ZERO) == null, "#11: Slot.spreading suppresses Godot DnD hijack")
	Slot.spreading = false
	test_slot.free()
	m.handle({"t": "slots", "l": {"main": row10.call([["iron-plate", 5], ["copper-plate", 5], ["coal", 5]])}})
	ui.toggle_inventory()
	await get_tree().process_frame
	sent()
	ui._on_character_slot("main", 1, MOUSE_BUTTON_LEFT, true, false)
	var s2 := Slot.new()
	s2.slot_role = "main"
	s2.slot_index = 2
	var s3 := Slot.new()
	s3.slot_role = "main"
	s3.slot_index = 3
	var s_opp := Slot.new()
	s_opp.slot_role = "chest"
	s_opp.slot_index = 1
	ui._shift_drag_to(s2)
	ui._shift_drag_to(s2)  # duplicate visit ignored
	ui._shift_drag_to(s3)
	ui._shift_drag_to(s_opp)  # opposite side ignored
	ui._end_shift_drag()
	var xfers: Array = sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "xfer")
	check(xfers.size() == 3 and xfers.map(func(c: Dictionary) -> int: return int(c.get("fi", 0))) == [1, 2, 3],
		"#11: Shift+LMB drag transfers each same-side slot once and ignores opposite side: %s" % [xfers])
	for n in [s2, s3, s_opp]:
		n.free()
	ui.close_all()
	await get_tree().process_frame

	# --- Bug #13: clickable inserter hand and transport-belt lane slots ---
	ui.screen.request(502, {"t": "open", "u": 502, "p": 0, "x": 0, "y": 0})
	ui.screen.handle({"t": "gui", "u": 502, "p": 0, "kind": "inserter", "name": "inserter", "ins": {"h": ["iron-plate", 2]}})
	await get_tree().process_frame
	var ins_hand := ui.screen.find_child("Hand", true, false) as Slot
	check(ins_hand != null and ins_hand.slot_role == "hand" and ins_hand.slot_index == 1 and ins_hand.item == "iron-plate",
		"#13: inserter Hand slot has role=hand, index=1, item=iron-plate")
	sent()
	if ins_hand != null:
		ins_hand.clicked.emit(MOUSE_BUTTON_LEFT, true)
	var hand_xfers: Array = sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "xfer" and c.get("from") == "hand")
	check(hand_xfers.size() == 1 and int(hand_xfers[0].get("u", 0)) == 502,
		"#13: Shift+click on inserter Hand emits xfer from=hand: %s" % [hand_xfers])
	var had_screen_protos: Variant = ui.screen.protos
	if ui.screen.protos == null:
		ui.screen.protos = ProtoDB.new()
	if ui.screen.protos.entities_by_name.get("transport-belt") == null:
		ui.screen.protos.add_entities([[503, "transport-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 100, 140, 200, 1, 1]])
	var belt_proto: ProtoDB.EntityProto = ui.screen.protos.entities_by_name.get("transport-belt")
	var belt_pid: int = belt_proto.id if belt_proto != null else 0
	ui.screen.request(503, {"t": "open", "u": 503, "p": belt_pid, "x": 0, "y": 0})
	ui.screen.handle({"t": "gui", "u": 503, "p": belt_pid, "kind": "other", "name": "transport-belt",
		"bl": [[{"name": "iron-plate", "count": 1}], [{"name": "copper-plate", "count": 1}]]})
	await get_tree().process_frame
	var b1 := ui.screen.find_child("belt_1_1", true, false) as Slot
	var b2 := ui.screen.find_child("belt_2_1", true, false) as Slot
	check(b1 != null and b1.item == "iron-plate" and b2 != null and b2.item == "copper-plate",
		"#13: transport-belt screen populates clickable lane slots from gui.bl")
	sent()
	if b2 != null:
		b2.clicked.emit(MOUSE_BUTTON_LEFT, true)
	var belt_xfers: Array = sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "xfer" and c.get("from") == "belt_2")
	check(belt_xfers.size() == 1 and int(belt_xfers[0].get("u", 0)) == 503,
		"#13: Shift+click on belt_2_1 emits xfer from=belt_2: %s" % [belt_xfers])
	ui.close_all()
	ui.screen.protos = had_screen_protos
	await get_tree().process_frame

	# --- Bug #9: fluid/machine-only recipes appear in crafting tab with hand=false and refuse hand craft ---
	var had_hc: Array = m.hand_categories.duplicate()
	var had_rdet: Array = m._rdet.duplicate()
	m.handle({"t": "rdet", "part": 1, "parts": 1, "hc": ["crafting"], "l": [
		["iron-gear-wheel", 0.5, ["crafting"], "intermediate-products", "d", "intermediate-product", "a", "a", [["item", "iron-plate", 2]], [["item", "iron-gear-wheel", 1]]],
		["oil-processing", 5.0, ["oil-processing"], "intermediate-products", "d", "fluid-recipes", "a", "b", [["fluid", "crude-oil", 100]], [["fluid", "petroleum-gas", 55]]],
	]})
	var oil_rec: Dictionary = m.recipe("oil-processing")
	var gear_rec: Dictionary = m.recipe("iron-gear-wheel")
	check(not oil_rec.is_empty() and not bool(oil_rec.get("hand", true)) and bool(gear_rec.get("hand", false)),
		"#9: rdet.hc marks hand=true for crafting and hand=false for oil-processing")
	ui.toggle_inventory()
	await get_tree().process_frame
	var find_slot_by_item := func(root_n: Node, target_item: String) -> Slot:
		var stack_q: Array = [root_n]
		while not stack_q.is_empty():
			var n: Node = stack_q.pop_back()
			if n is Slot and (str(n.get_meta("recipe", "")) == target_item or (n as Slot).item == target_item):
				return n as Slot
			for ch in n.get_children():
				stack_q.append(ch)
		return null
	var oil_slot: Slot = find_slot_by_item.call(ui.window, "oil-processing")
	check(oil_slot != null and oil_slot.ghost and oil_slot.count == -1,
		"#9: machine-only recipe appears in crafting panel as ghost with no count")
	sent()
	if oil_slot != null:
		oil_slot.clicked.emit(MOUSE_BUTTON_LEFT, false)
	check(sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "craft").is_empty(),
		"#9: clicking machine-only recipe sends no craft command")
	ui.close_all()
	await get_tree().process_frame
	m.hand_categories = had_hc
	m._rdet = had_rdet
	m._apply_recipe_details()

	# --- J13: a crafting queue longer than its row ------------------------------------------------
	var q = ui.craft_queue
	var root: Control = hud.get_child(0)  # laid out at 1280x720, as _layout does
	root.anchor_right = 0.0
	root.anchor_bottom = 0.0
	root.size = Vector2(1280, 720)
	var many: Array = []
	for i in 30:
		many.append([i + 1, "iron-gear-wheel", 1, 0])
	m.handle({"t": "cq", "pr": 0, "l": many})
	await get_tree().process_frame
	await get_tree().process_frame
	var fit: int = q._fit
	var shown: int = q._slots.filter(func(s: Slot) -> bool: return s.visible).size()
	var rest := 30 - (fit - 1)
	check(fit >= 2 and fit < 30 and shown == fit - 1 and q.more_button.visible and q.more_button.text == "+%d" % rest,
		"J13: the row holds what fits (%d), ending in \"+%d\": %d shown, %s" % [fit, rest, shown, q.more_button.text])
	check(q.get_global_rect().end.x <= ui.quickbar.frame.get_global_rect().position.x + 0.5, "J13: the row stays clear of the quickbar")
	check(not q.more_panel.visible, "J13: the rest stays shut until asked for")
	# The headless window is too small to move the mouse there: the button is told it is entered, as
	# the viewport does.
	q.more_button.notification(Control.NOTIFICATION_MOUSE_ENTER)
	await get_tree().process_frame
	check(q.more_panel.visible, "J13: the mouse on \"+N\" opens the rest")
	q.more_button.notification(Control.NOTIFICATION_MOUSE_EXIT)
	await get_tree().process_frame
	check(not q.more_panel.visible, "J13: and moving away shuts it")
	q.more_button.button_pressed = true
	await get_tree().process_frame
	var panel_rect: Rect2 = q.more_panel.get_global_rect()
	var rows: int = ceili(rest / float(fit))
	var lowest: Control = q.more_panel.get_child(rows - 1)
	var first_rest: Slot = lowest.get_child(0)
	check(q.pinned and q.more_panel.visible and absf(panel_rect.end.y - q.get_global_rect().position.y) <= 1.0
		and q._more_slots.filter(func(s: Slot) -> bool: return s.visible).size() == rest and int(first_rest.get_meta("index", 0)) == fit,
		"J13: a click holds the rest open upwards over the row, the next entry (%d) nearest it: %s over %s" % [fit, panel_rect, q.get_global_rect()])
	first_rest.clicked.emit(MOUSE_BUTTON_LEFT, false)
	var cancel := sent_one("cancel_craft")
	check(int(cancel.get("i", 0)) == fit and int(cancel.get("n", 0)) == 1, "J13: a craft held open there is cancelled by a click: %s" % cancel)
	m.handle({"t": "cq", "pr": 0, "l": [[1, "iron-gear-wheel", 1, 0]]})
	await get_tree().process_frame
	check(not q.more_button.visible and not q.more_panel.visible and not q.pinned, "J13: a queue that fits its row has no \"+N\" and nothing held open")
	m.handle({"t": "cq", "pr": 0, "l": []})
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# --- J16: which lines of a recipe's tooltip are red ---------------------------------------------
	m.set_recipe_details([
		{"name": "iron-gear-wheel", "energy": 0.5, "ingredients": [["iron-plate", 2]], "products": [["iron-gear-wheel", 1]]},
		{"name": "copper-cable", "energy": 0.5, "ingredients": [["copper-plate", 1]], "products": [["copper-cable", 2]]},
		{"name": "electronic-circuit", "energy": 0.5, "ingredients": [["iron-plate", 1], ["copper-cable", 3]], "products": [["electronic-circuit", 1]]},
		{"name": "inserter", "energy": 0.5, "ingredients": [["electronic-circuit", 1], ["iron-gear-wheel", 1], ["iron-plate", 1]],
			"products": [["inserter", 1]]}])
	var red := func(lines: Array) -> Array:
		return lines.filter(func(l: Array) -> bool: return l.size() > 2 and l[2] is Color and (l[2] as Color).is_equal_approx(Kit.RED_TEXT)).map(
			func(l: Array) -> String: return str(l[0]))
	m.set_inventory_slots([["iron-plate", 4], ["copper-plate", 2]], 10)
	var tip: Array = CraftingPanel.recipe_tip_lines(m, m.recipe("inserter"))
	var texts: Array = tip.map(func(l: Array) -> String: return str(l[0]))
	check(red.call(tip).is_empty() and texts.has("1 × Electronic circuit") and texts.has("1 × Iron gear wheel") and texts.has("4 × Iron plate"),
		"J16: ingredients craftable from the plates held aren't red; Total raw has all it needs: %s" % [texts])
	m.set_inventory_slots([["iron-plate", 3], ["copper-plate", 2]], 10)
	tip = CraftingPanel.recipe_tip_lines(m, m.recipe("inserter"))
	check(red.call(tip) == ["0/1 × Iron plate", "3/4 × Iron plate"],
		"J16: the plates go to the circuit and the gear first: the plate itself is red (have/need), and Total raw's plates: %s" % [red.call(tip)])
	m.set_inventory_slots([["copper-plate", 2]], 10)
	tip = CraftingPanel.recipe_tip_lines(m, m.recipe("electronic-circuit"))
	check(red.call(tip) == ["0/1 × Iron plate", "0/1 × Iron plate"],
		"J16: cable made from the copper held isn't red; the missing plate is, and in Total raw: %s" % [red.call(tip)])

	# --- J14: an assembler's recipe chooser has Factorio's recipe tooltip ---------------------------
	m.handle({"t": "pedia", "kind": "recipe", "name": "plastic-bar", "found": 1,
		"d": {"ing": [["fluid", "petroleum-gas", 20], ["item", "coal", 1]], "prod": [["item", "plastic-bar", 2]], "time": 1}})
	screen.request(606, {"t": "open", "u": 606, "p": 0, "x": 0, "y": 0})
	sent()
	screen.handle({"t": "gui", "u": 606, "p": 0, "kind": "crafter", "inv": {}, "recipe": "", "rl": ["plastic-bar", "inserter", "sulfur"]})
	screen._picking = true
	screen._rebuild_now()
	await get_tree().process_frame
	var plastic: Slot = _find_slot_tip(screen, Kit.recipe_name("plastic-bar") + " (Recipe)")
	var plastic_lines: Array = plastic.tip_fn.call() if plastic != null and plastic.tip_fn.is_valid() else []
	var ptexts: Array = plastic_lines.map(func(l: Array) -> String: return str(l[0]))
	check(ptexts.has("Ingredients:") and ptexts.has("20 × Petroleum gas") and ptexts.has("1 × Coal") and ptexts.has("Products:")
		and ptexts.has("2 × Plastic bar") and ptexts.any(func(t: String) -> bool: return t.ends_with("Crafting time"))
		and red.call(plastic_lines).is_empty() and plastic._make_custom_tooltip("") != null,
		"J14: a recipe in the chooser has Factorio's recipe tooltip from its Factoriopedia page: %s" % [ptexts])
	var ins: Slot = _find_slot_tip(screen, Kit.recipe_name("inserter") + " (Recipe)")
	var itexts: Array = (ins.tip_fn.call() as Array).map(func(l: Array) -> String: return str(l[0])) if ins != null else []
	check(itexts.has("Total raw:") and itexts.has("1 × Electronic circuit") and not itexts.any(func(t: String) -> bool: return t.contains("/")),
		"J14: a hand recipe's from its details, with Total raw, nothing red (an assembler doesn't craft from the inventory): %s" % [itexts])
	var sulfur: Slot = _find_slot_tip(screen, Kit.recipe_name("sulfur") + " (Recipe)")
	if sulfur != null:
		sulfur.mouse_entered.emit()
	var pages := sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "pedia" and c.get("kind") == "recipe")
	var asked_page: Dictionary = pages[0] if pages.size() == 1 else {}
	check(asked_page.get("name") == "sulfur",
		"J14: a recipe not known yet: its page is asked for as the mouse comes on it: %s" % asked_page)
	screen.close()
	sent()

	# --- J17: the technology screen opens on its technology, scrolled to it -------------------------
	var chain: Array = []
	for i in 12:
		chain.append(["t%d" % i, "a%02d" % i, [] if i == 0 else ["t%d" % (i - 1)], [["automation-science-pack", 1]], 10, 10,
			2 if i < 10 else 1, ""])
	m.handle({"t": "techs", "part": 1, "parts": 1, "l": chain})
	m.handle({"t": "rs", "cur": "t11", "pr": 100, "q": []})
	var r = ui.research
	r.selected = "t3"
	var shown_at := func(tech: String) -> bool:
		var s: Control = r._tree_slots.get(tech)
		var view := Rect2(Vector2(r._tree_scroll.scroll_horizontal, r._tree_scroll.scroll_vertical), r._tree_scroll.size)
		return s != null and view.encloses(Rect2(s.position, s.size))
	ui.close_all()
	key(KEY_T)
	for i in 4:
		await get_tree().process_frame
	check(r.is_open() and r.selected == "t11" and r._tree_scroll.scroll_vertical > 0 and shown_at.call("t11"),
		"J17: T opens on the research in progress, the tree scrolled to it, not at its top (%d)" % r._tree_scroll.scroll_vertical)
	m.handle({"t": "rs", "cur": "", "pr": 0, "q": []})
	r.select("t10")
	ui.close_all()
	await get_tree().process_frame
	key(KEY_T)
	for i in 4:
		await get_tree().process_frame
	check(r.selected == "t10" and r._tree_scroll.scroll_vertical > 0 and shown_at.call("t10"),
		"J17: with nothing researched, on the technology looked at last (still to be researched, L9), scrolled to it")
	ui.close_all()
	await get_tree().process_frame
	ui.pedia.open_technology.emit("t6")
	for i in 4:
		await get_tree().process_frame
	check(r.is_open() and r.selected == "t6" and shown_at.call("t6"), "J17: a Factoriopedia link opens it on that technology")
	r.select("t1")
	for i in 3:
		await get_tree().process_frame
	r.select("t11")
	for i in 4:
		await get_tree().process_frame
	check(shown_at.call("t11"), "J17: from a short tree to a technology deep in a tall one: scrolled to it (the old scroll range clamped it)")
	ui.close_all()
	await get_tree().process_frame


## The eleventh list's technology screen. L9: with nothing researched, T opens on the technology looked at
## last only while it is still to be researched; a researched one (the research just finished) gave way to the
## first available and the list opens at its top, not scrolled down to the researched ones (--research-open=last
## as before). L12: Start research / Add to queue on a technology whose prerequisites aren't researched sends
## `research` (the bridge queues the missing ones first), its tooltip naming them; greyed with Factorio's reason
## when a missing one is unlocked by doing its task or the queue's seven can't hold them (--research-chain=off
## greys it as before). The queue's places count Factorio's research_queue, which starts with the research in
## progress (the second in the queue was numbered 3). The owner: such a technology is drawn orange (Factorio's
## conditionally_available_technology_slot) in the list, the tree, the details and the queue, a full queue
## not turning it red; trigger-blocked ones stay red, available yellow, researched green; with
## --research-chain=off none is orange, and --research-orange=factorio keeps Factorio's own rule.


func _research_open_queue(hud: Hud) -> void:
	var ui = hud.ui
	var m = ui.model
	var r = ui.research
	var saved_techs: Dictionary = m.techs.duplicate(true)
	ui.close_all()
	await get_tree().process_frame
	var recs: Array = []
	var pack := [["automation-science-pack", 1]]
	for i in 70:
		recs.append(["r-done-%02d" % i, "z%02d" % i, [], pack, 10, 10, 2, ""])
	recs.append(["r-avail-a", "b1", [], pack, 10, 10, 1, ""])
	recs.append(["r-avail-b", "b2", [], pack, 10, 10, 1, ""])
	recs.append(["r-trigtech", "b3", [], [], 1, 0, 1, "craft-item"])
	recs.append(["r-locked", "c1", ["r-avail-a"], pack, 10, 10, 0, ""])
	recs.append(["r-deep", "c2", ["r-locked", "r-avail-b", "r-done-03"], pack, 10, 10, 0, ""])
	recs.append(["r-needs-trig", "c3", ["r-trigtech"], pack, 10, 10, 0, ""])
	recs.append(["r-trig-locked", "c4", ["r-avail-a"], [], 1, 0, 0, "craft-item"])
	recs.append(["r-past-trig", "c5", ["r-needs-trig"], pack, 10, 10, 0, ""])
	m.handle({"t": "techs", "part": 1, "parts": 1, "l": recs})
	m.handle({"t": "rs", "cur": "", "pr": 0, "q": []})
	key(KEY_T)
	for i in 3:
		await get_tree().process_frame
	r.select("r-done-69")
	for i in 4:
		await get_tree().process_frame
	var scrolled_down: int = r._list_scroll.scroll_vertical
	check(r.is_open() and r.selected == "r-done-69" and scrolled_down > 0,
		"L9: a researched technology selected brings the list down to it (%d)" % scrolled_down)
	ui.close_all()
	await get_tree().process_frame
	key(KEY_T)
	for i in 4:
		await get_tree().process_frame
	check(r.is_open() and r.selected == "r-avail-a" and r._list_scroll.scroll_vertical == 0,
		"L9: with nothing researched, T opens on the first available, not the researched one looked at last, the list at its top (%s, %d)"
		% [r.selected, r._list_scroll.scroll_vertical])
	r.select("r-locked")
	ui.close_all()
	await get_tree().process_frame
	key(KEY_T)
	for i in 4:
		await get_tree().process_frame
	check(r.selected == "r-locked", "L9: one looked at last that is still to be researched stays (J17): %s" % r.selected)
	r.select("r-done-69")
	ui.close_all()
	await get_tree().process_frame
	r.open_on_researched = true
	key(KEY_T)
	for i in 4:
		await get_tree().process_frame
	check(r.selected == "r-done-69" and r._list_scroll.scroll_vertical > 0,
		"L9: --research-open=last opens on the researched one, the list down there, as before")
	r.open_on_researched = false

	# --- L12: queueing a technology whose prerequisites aren't researched ---------------------------
	# Drawn orange where Start research can queue it with what it needs.
	var cond: int = r._slots["r-locked"].CONDITIONAL
	var drawn := func(slots: Dictionary, names: Array) -> Array:
		var out: Array = []
		for t in names:
			out.append(int(slots[t].state) if slots.has(t) else -1)
		return out
	var list_states: Array = drawn.call(r._slots, ["r-locked", "r-deep", "r-needs-trig", "r-trig-locked", "r-past-trig",
		"r-avail-a", "r-trigtech", "r-done-00"])
	check(list_states == [cond, cond, 0, 0, 0, 1, 1, 2],
		"orange in the list for the queueable ones, red behind a trigger technology (and one itself), yellow and green unchanged: %s" % [list_states])
	check(r._slots["r-locked"].theme_type_variation == "FTechConditional" and r._slots["r-needs-trig"].theme_type_variation == "FTechUnavailable"
		and r._slots["r-avail-a"].theme_type_variation == "FTechAvailable" and r._slots["r-done-00"].theme_type_variation == "FTechResearched",
		"each drawn with its own technology_slot style: %s" % r._slots["r-locked"].theme_type_variation)
	var rows := []
	for n in ["tech_conditional", "tech_conditional_hover", "tech_conditional_selected", "tech_band_conditional"]:
		var layers: Array = Kit._layers(n)
		rows.append(layers[-1]["at"] if not layers.is_empty() else [])
	check(rows == [[296, 153], [312, 153], [330, 153], [347, 153]],
		"its images are Factorio's conditionally_available_technology_slot: slot, hovered, highlighted, ingredients band: %s" % [rows])
	if GuiAssets.available():
		var atlas: Image = GuiAssets.atlas()
		var hue := func(y: int) -> float:
			return atlas.get_pixel(304, y + 8).h
		var red_h: float = hue.call(170)
		check(atlas.get_pixel(405, 161).is_equal_approx(r._slots["r-locked"].STRIP[cond])
			and atlas.get_pixel(389, 161).is_equal_approx(r._slots["r-locked"].BADGE[cond]),
			"its strip and level badge are the atlas's level_range_band and level_band on that row: %s %s"
			% [atlas.get_pixel(405, 161), atlas.get_pixel(389, 161)])
		check(hue.call(153) > (red_h if red_h < 0.5 else red_h - 1.0) and hue.call(153) < hue.call(136),
			"and that row's slot is orange, between the red and the yellow ones (hue %.3f, red %.3f, yellow %.3f)"
			% [hue.call(153), red_h, hue.call(136)])
	r.select("r-deep")
	for i in 2:
		await get_tree().process_frame
	var tree_states: Array = drawn.call(r._tree_slots, ["r-deep", "r-locked", "r-avail-a", "r-avail-b", "r-done-03"])
	check(tree_states == [cond, cond, 1, 1, 2] and r._big != null and r._big.state == cond,
		"orange in the tree and on the details' big card: %s, %s" % [tree_states, r._big.state if r._big != null else "no card"])
	r.select("r-past-trig")
	for i in 2:
		await get_tree().process_frame
	tree_states = drawn.call(r._tree_slots, ["r-past-trig", "r-needs-trig", "r-trigtech"])
	check(tree_states == [0, 0, 1] and r._big.state == 0,
		"red in the tree and the details where a trigger technology is on the way: %s" % [tree_states])
	var start_button := func() -> Button:
		for b: Node in r._details.find_children("*", "Button", true, false):
			if (b as Button).text in ["Start research", "Add to queue"]:
				return b as Button
		return null
	check(r.missing_prerequisites("r-deep") == ["r-avail-b", "r-avail-a", "r-locked"],
		"L12: what r-deep waits for, each after its own, by order (a researched one left out): %s" % [r.missing_prerequisites("r-deep")])
	sent()
	r.select("r-deep")
	for i in 2:
		await get_tree().process_frame
	var b: Button = start_button.call()
	var names := ", ".join(PackedStringArray([r.title_of("r-avail-b"), r.title_of("r-avail-a"), r.title_of("r-locked")]))
	check(b != null and b.text == "Start research" and not b.disabled and b.tooltip_text == "Queues first: " + names,
		"L12: Start research on a locked technology, its tooltip naming what it queues first: %s" % (b.tooltip_text if b != null else "no button"))
	if b != null:
		b.pressed.emit()
	var cmd := sent_one("research")
	check(cmd.get("name") == "r-deep", "L12: and it sends `research` (the bridge queues the missing ones first): %s" % cmd)
	# Factorio's research_queue starts with the research in progress.
	m.handle({"t": "rs", "cur": "r-avail-b", "pr": 100, "q": ["r-avail-b", "r-avail-a"]})
	for i in 2:
		await get_tree().process_frame
	check(r._place("r-avail-b") == 1 and r._place("r-avail-a") == 2 and r.missing_prerequisites("r-deep") == ["r-locked"],
		"L12: the second in Factorio's queue is place 2 (was 3); only what isn't queued is missing: %d %d %s"
		% [r._place("r-avail-b"), r._place("r-avail-a"), r.missing_prerequisites("r-deep")])
	m.handle({"t": "rs", "cur": "r-avail-b", "pr": 100, "q": ["r-avail-a"]})
	check(r._place("r-avail-a") == 2, "L12: and a queue without the current one (the mock's) still counts it")
	for i in 2:
		await get_tree().process_frame
	b = start_button.call()
	check(b != null and b.text == "Add to queue" and not b.disabled, "L12: Add to queue while one is being researched")
	m.handle({"t": "rs", "cur": "r-avail-b", "pr": 100, "q": ["r-avail-b", "x1", "x2", "x3", "x4", "x5"]})
	for i in 2:
		await get_tree().process_frame
	b = start_button.call()
	check(b != null and b.disabled and b.tooltip_text == "Research queue full",
		"L12: greyed when the queue's seven can't hold it and what it needs: %s" % (b.tooltip_text if b != null else "no button"))
	check(r._slots["r-deep"].state == cond and r._big.state == cond, "and still orange: a full queue doesn't turn the tree red")
	m.handle({"t": "rs", "cur": "r-avail-a", "pr": 100, "q": ["r-avail-a", "r-locked"]})
	for i in 2:
		await get_tree().process_frame
	var queued_slot = r._queue_box.get_node_or_null("Queue_r-locked")
	check(queued_slot != null and queued_slot.state == cond and r._queue_box.get_node("Queue_r-avail-a").state == 1,
		"a queued one waiting for the one before it is orange in the queue too: %s" % (queued_slot.state if queued_slot != null else "none"))
	r.orange_factorio = true
	r.refresh()
	list_states = drawn.call(r._slots, ["r-locked", "r-deep", "r-needs-trig", "r-avail-a"])
	check(list_states == [cond, 0, 0, 1],
		"--research-orange=factorio: orange only where every prerequisite is researched or queued (Factorio's queue rule): %s" % [list_states])
	r.orange_factorio = false
	m.handle({"t": "rs", "cur": "", "pr": 0, "q": []})
	r.select("r-needs-trig")
	for i in 2:
		await get_tree().process_frame
	b = start_button.call()
	check(b != null and b.disabled and b.tooltip_text == "Research %s first: it is unlocked by doing its task" % r.title_of("r-trigtech"),
		"L12: greyed when a missing one is unlocked by doing its task (Factorio queues no trigger technology): %s"
		% (b.tooltip_text if b != null else "no button"))
	r.research_chain = false
	r.select("r-deep")
	for i in 2:
		await get_tree().process_frame
	r._details_sig = ""
	r.refresh()
	b = start_button.call()
	check(b != null and b.disabled and b.tooltip_text == "Research the required technologies first",
		"L12: --research-chain=off greys it as before")
	list_states = drawn.call(r._slots, ["r-locked", "r-deep", "r-needs-trig", "r-avail-a", "r-done-00"])
	check(list_states == [0, 0, 0, 1, 2] and r._big.state == 0, "and draws nothing orange (none of them can be queued then): %s" % [list_states])
	r.research_chain = true
	sent()
	ui.close_all()
	m.techs = saved_techs
	m.handle({"t": "rs", "cur": "", "pr": 0, "q": []})
	await get_tree().process_frame


## M7: the Model packs window (model_packs_window.gd, Minecraft's resource packs screen for models):
## the packs in Available (off) and Selected (on, the top winning), a new zip on top, the built-in
## packs under the folder's, Factorio's (the install's pictures) last, Placeholders moving and
## switching like the rest; ▶ puts a pack on top of Selected, ◀
## takes one out, ▲ ▼ order them, each saved in settings.cfg and used at once (ModelPacks.find);
## a pack's models listed by family with a search box; a model's preview made (its pack's model,
## read on a worker), which pack is in use, every pack's version to look at; Use takes the family
## from the pack shown whatever the order (settings.cfg choices, the library's source at once),
## By the order and Reset choices give it back.
## The Factorio pack in the Model packs window (with an install): its entities' pictures in Models by
## family with Factorio's icons, one shown as its card framed face on, Play greyed ("a picture, not a
## model"), its card beside another pack's model (View, Select, the order), a picture's four directions
## in the variant picker; its items as icon cards; the install's icons filled over frames.


func _play(hud: Hud, player: Node) -> void:
	var ui = hud.ui
	var m = ui.model
	sent()
	player.cursor_item = ""
	ui.close_all()

	# --- the cursor stack: pick up, put down, split, swap, put back --------------------------
	m.handle({"t": "slots", "l": {"main": [["transport-belt", 50], ["iron-plate", 100], 0, 0, 0, 0, 0, 0, 0, 0],
		"guns": [["pistol", 1], ["submachine-gun", 1], 0], "ammo": [["firearm-magazine", 10], 0, 0], "armor": [0]}})
	ui.toggle_inventory()
	click_main(ui, 1)
	await get_tree().process_frame
	check(player.cursor_item == "transport-belt" and ui.hand.get("index") == 1, "click picks the stack up")
	check(ui.hand_count() == 50 and ui.cursor.item == "transport-belt" and ui.cursor.count == 50, "the cursor shows the stack and its count")
	check(ui.window._grid.get_child(0).hand, "its slot shows Factorio's hand")
	click_main(ui, 5)
	var mv := sent_one("move")
	check(mv.get("from") == "main" and mv.get("fi") == 1 and mv.get("to") == "main" and mv.get("ti") == 5 and int(mv.get("n", -1)) == 0,
		"click on an empty slot moves the stack there")
	check(player.cursor_item == "" and ui.hand.is_empty(), "and empties the cursor")
	click_main(ui, 2, MOUSE_BUTTON_RIGHT)
	check(player.cursor_item == "iron-plate" and int(ui.hand.get("n", 0)) == 50 and ui.hand_count() == 50, "right click picks up half")
	await get_tree().process_frame
	var half_slot: Slot = ui.window._grid.get_child(1)
	check(not half_slot.hand and ui.window.hand_slot.is_empty(),
		"a split leaves no hand on its slot (2.1.23: hand_location nil), the rest shows as a stack")
	click_main(ui, 6)
	mv = sent_one("move")
	check(mv.get("fi") == 2 and mv.get("ti") == 6 and int(mv.get("n", 0)) == 50, "and puts down only that half")
	click_main(ui, 1)
	click_main(ui, 2)
	check(sent_one("move").is_empty(), "a stack onto another item: nothing moves (2.1.23 puts the held stack back in its hand slot)")
	check(player.cursor_item == "iron-plate" and ui.hand.get("index") == 2, "and picks up the clicked one, the hand on its slot")
	ui.hand = {}
	player.cursor_item = ""
	click_main(ui, 1)
	click_main(ui, 3, MOUSE_BUTTON_RIGHT)
	mv = sent_one("move")
	check(int(mv.get("n", 0)) == 1 and player.cursor_item == "transport-belt", "right click with a stack drops one and keeps holding")
	click_main(ui, 1)
	check(player.cursor_item == "" and sent_one("move").is_empty(), "click on its own slot puts it back")
	click_main(ui, 1)
	key(KEY_Q)  # player_input.gd's Q isn't here; holding nothing must drop the hand too
	player.cursor_item = ""
	await get_tree().process_frame
	check(ui.hand.is_empty(), "the hand is forgotten when the cursor is emptied elsewhere")
	click_main(ui, 1)
	m.handle({"t": "slots", "l": {"main": [0, ["iron-plate", 100], 0, 0, ["transport-belt", 30], 0, 0, 0, 0, 0]}})
	await get_tree().process_frame
	check(ui.hand.get("index") == 5 and ui.hand_count() == 30, "a used-up stack refills the cursor from another one")
	ui.hand = {}
	player.cursor_item = ""

	# --- a machine screen: moves by slot, Shift transfers, status, fluids --------------------
	var screen: MachineScreen = hud.screen
	screen.unit = 77
	screen.handle({"t": "gui", "u": 77, "p": 0, "kind": "container", "inv": {"chest": [["coal", 10]]},
		"slots": {"chest": [["coal", 10], 0, 0, 0]}, "status": "working"})
	await get_tree().process_frame
	check(screen.is_open() and ui.window.is_open(), "a chest's screen opens beside the inventory")
	screen.slot_clicked.emit("chest", 1, "coal", 10, MOUSE_BUTTON_LEFT, false, false)
	# I7: Factorio's cursor owns a stack taken from a chest (it stays held when the window closes);
	# the bridge's character has no cursor, so the stack moves into the first free inventory slot at
	# once and is held from there.
	mv = sent_one("move")
	check(player.cursor_item == "coal" and ui.hand.get("role") == "main" and int(ui.hand.get("index", 0)) == 1
		and ui.can_build_from_hand(), "click picks up a chest stack, held from the first free inventory slot as an inventory stack (I7): %s" % [ui.hand])
	check(mv.get("from") == "chest" and mv.get("fi") == 1 and mv.get("to") == "main" and mv.get("ti") == 1 and int(mv.get("u", 0)) == 77,
		"and moves it into that slot at once: %s" % [mv])
	click_main(ui, 7)
	mv = sent_one("move")
	check(mv.get("from") == "main" and mv.get("fi") == 1 and mv.get("to") == "main" and mv.get("ti") == 7 and player.cursor_item == "",
		"a click on another inventory slot puts it down there: %s" % [mv])
	click_main(ui, 2, MOUSE_BUTTON_LEFT, true)
	var put := sent_one("xfer")
	check(put.get("from") == "main" and put.get("fi") == 2 and put.get("k") == "stack" and int(put.get("u", 0)) == 77,
		"Shift+click moves that inventory stack into the machine (xfer stack)")
	click_main(ui, 2, MOUSE_BUTTON_LEFT, false, true)
	check(sent_one("xfer").get("k") == "all", "Ctrl+click moves all of that item (xfer all)")
	click_main(ui, 4, MOUSE_BUTTON_LEFT, false, true)
	var everything := sent_one("xfer")
	check(everything.get("k") == "all" and everything.get("fi") == 4, "Ctrl+click on an empty slot moves everything")
	click_main(ui, 4, MOUSE_BUTTON_LEFT, true)
	check(sent_one("xfer").is_empty(), "Shift+click on an empty slot does nothing")
	# F6: a screen opened from the remote view out of reach (`far`): a module held and clicked into
	# a module slot is asked for (modreq with the slot), right click takes the request back, and the
	# requested module shows faintly in its slot (mrq).
	m.handle({"t": "iuse", "part": 1, "parts": 1, "l": [["speed-module", "m", "speed"]]})
	screen.handle({"t": "gui", "u": 77, "p": 0, "kind": "lab", "inv": {"input": [], "modules": []},
		"slots": {"input": [0, 0], "modules": [0, 0]}, "far": 1, "mrq": ["", "speed-module"]})
	await get_tree().process_frame
	ui.hand = {}
	player.cursor_item = "speed-module"
	sent()
	screen.slot_clicked.emit("modules", 1, "", 0, MOUSE_BUTTON_LEFT, false, false)
	var asked := sent_one("modreq")
	screen.slot_clicked.emit("modules", 2, "", 0, MOUSE_BUTTON_RIGHT, false, false)
	var unasked := sent_one("modreq")
	var faint := 0
	for n in screen.find_children("*", "", true, false):
		if n.get("filter_item") == "speed-module":
			faint += 1
	check(m.is_module("speed-module") and not m.is_module("coal") and asked.get("item") == "speed-module" and int(asked.get("s", 0)) == 1
		and not asked.has("q")
		and int(asked.get("u", 0)) == 77 and int(unasked.get("clr", 0)) == 1 and int(unasked.get("s", 0)) == 2 and faint == 1,
		"far screen: a held module asks for itself in a module slot, right click cancels, requests show (F6): %s %s %d" % [asked, unasked, faint])
	player.cursor_item = ""
	screen.handle({"t": "gui", "u": 77, "p": 0, "kind": "container", "inv": {"chest": [["coal", 10]]},
		"slots": {"chest": [["coal", 10], 0, 0, 0]}, "status": "working"})
	await get_tree().process_frame
	sent()
	screen.slot_clicked.emit("chest", 1, "coal", 10, MOUSE_BUTTON_LEFT, true, false)
	var take := sent_one("xfer")
	check(take.get("from") == "chest" and take.get("fi") == 1 and take.get("k") == "stack" and int(take.get("u", 0)) == 77,
		"Shift+click takes that machine stack")
	click_main(ui, 2)
	screen.slot_clicked.emit("chest", 3, "", 0, MOUSE_BUTTON_LEFT, false, false)
	mv = sent_one("move")
	check(mv.get("from") == "main" and mv.get("fi") == 2 and mv.get("to") == "chest" and mv.get("ti") == 3 and int(mv.get("u", 0)) == 77,
		"an inventory stack goes into a chosen chest slot")
	check(MachineScreen.status_text("no_ingredients") == "No ingredients" and MachineScreen.status_text("full_output") == "Output full",
		"status names read like Factorio's")
	check(MachineScreen.status_color("working") == "green" and MachineScreen.status_color("no_power") == "red"
		and MachineScreen.status_color("low_power") == "yellow", "status dots are green, red or yellow")
	screen.handle({"t": "gui", "u": 77, "p": 0, "kind": "furnace", "inv": {"input": [["iron-ore", 5]], "fuel": [["coal", 2]], "output": []},
		"slots": {"input": [["iron-ore", 5]], "fuel": [["coal", 2]], "output": [0]}, "status": "no_fuel", "pw": 400,
		"fb": [["water", 150, 200, 15]], "recipe": "iron-plate", "pr": 300})
	await get_tree().process_frame
	var texts := _texts(screen)
	check(texts.has("No fuel") and texts.has("30%") and not texts.has("Energy") and not texts.has("Fluids"),
		"a furnace shows its status and progress, and no energy or fluid rows (as in Factorio)")
	var furnace_sig: String = screen._sig
	screen.handle({"t": "gui", "u": 77, "p": 0, "kind": "furnace", "inv": {"input": [["iron-ore", 5]], "fuel": [["coal", 2]], "output": []},
		"slots": {"input": [["iron-ore", 5]], "fuel": [["coal", 2]], "output": [0]}, "status": "no_fuel", "pw": 950,
		"fb": [["water", 150, 200, 15]], "recipe": "iron-plate", "pr": 310})
	check(screen._sig == furnace_sig, "a screen isn't rebuilt when only its buffer's fill (pw, not drawn) changes")
	# The furnace's fuel picked up: a machine stack in the cursor.
	screen.slot_clicked.emit("fuel", 1, "coal", 2, MOUSE_BUTTON_LEFT, false, false)
	await get_tree().process_frame
	var held_fuel: bool = player.cursor_item == "coal" and ui.hand.get("role") == "main"
	key(KEY_ESCAPE)
	await get_tree().process_frame
	check(not screen.is_open() and not ui.is_open() and sent_one("close").size() > 0, "Esc closes the machine and the window and tells the mod")
	# I7: moved into a free inventory slot as it was picked up, it stays in the hand.
	check(held_fuel and player.cursor_item == "coal" and ui.hand.get("role") == "main",
		"a machine stack in the cursor stays held when its screen closes (I7; held from the inventory: %s)" % held_fuel)
	ui.clear_cursor()
	player.cursor_item = ""

	# --- production windows laid out as Factorio's (production_panels.gd) ----------------------
	var old_protos = screen.protos
	var pp := ProtoDB.new()
	pp.add_entities([[1, "assembling-machine-2", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 1, 1, 1, 3, 3],
		[2, "pumpjack", "mining-drill", -1.5, -1.5, 1.5, 1.5, 1, 1, 1, 3, 3],
		[3, "nuclear-reactor", "reactor", -2.5, -2.5, 2.5, 2.5, 1, 1, 1, 5, 5],
		[4, "heat-exchanger", "boiler", -1.5, -1, 1.5, 1, 1, 1, 1, 3, 2],
		[5, "lab", "lab", -1.5, -1.5, 1.5, 1.5, 1, 1, 1, 3, 3],
		[6, "requester-chest", "logistic-container", -0.5, -0.5, 0.5, 0.5, 1, 1, 1, 1, 1],
		[7, "recycler", "furnace", -1, -2, 1, 2, 1, 1, 1, 2, 4]])
	screen.protos = pp
	screen.request(78, {"t": "open", "u": 78, "p": 1, "x": 0, "y": 0})
	sent()
	var asm_msg := {"t": "gui", "u": 78, "p": 1, "kind": "crafter", "recipe": "electronic-circuit", "pr": 870,
		"inv": {"input": [["iron-plate", 5]], "output": [["electronic-circuit", 24]], "modules": []},
		"slots": {"input": [["iron-plate", 5], 0], "output": [["electronic-circuit", 24]], "modules": [0, 0]},
		"rd": {"i": [["item", "iron-plate", 1], ["item", "copper-cable", 3]], "o": [["item", "electronic-circuit", 1]], "e": 0.5},
		"pb": 80, "bp": 400, "status": "item_ingredient_shortage", "rl": ["electronic-circuit", "iron-gear-wheel", "inserter"],
		"rg": [["intermediate-products", "c", "b x", "e"], ["intermediate-products", "c", "b x", "c"], ["logistics", "a", "c inserter", "b"]],
		"ql": ["normal", "uncommon"]}
	screen.handle(asm_msg)
	await get_tree().process_frame
	texts = _texts(screen)
	check(texts.has(Kit.recipe_name("electronic-circuit")) and texts.has("87%") and ui.window._char_frame.visible,
		"an assembler: the recipe row with its name, the progress bar's %, beside the inventory")
	var cable := _find_slot_tip(screen, Kit.pretty("copper-cable"))
	var circuit := _find_slot_tip(screen, Kit.pretty("electronic-circuit"))
	check(cable != null and cable.theme_type_variation == "FRedSlot" and cable.filter_item == "copper-cable",
		"a missing ingredient is a red slot with its ghost")
	check(circuit != null and circuit.theme_type_variation == "FYellowSlot", "a product waiting in the output is gold")
	check(MachineScreen.status_color("item_ingredient_shortage") == "red", "ingredient shortage has Factorio's red dot")
	var bonus_bars := screen.find_children("*", "ProgressBar", true, false).filter(func(b): return (b as ProgressBar).tooltip_text.begins_with("Productivity"))
	check(bonus_bars.size() == 1, "the purple productivity bar under the progress bar")
	var gear: Button = screen.find_child("ChangeRecipe", true, false)
	check(gear != null, "the gear button changes the recipe")
	if gear != null:
		gear.pressed.emit()
	await get_tree().process_frame
	check(screen.choosing_recipe() and not screen.shows_inventory() and screen.title_text() == "Select a recipe for assembling"
		and not ui.window._char_frame.visible, "the gear opens Factorio's recipe chooser as a window of its own")
	var tabs := screen.find_children("*", "Button", true, false).filter(func(b): return (b as Button).theme_type_variation == "FTab")
	check(tabs.size() == 2, "the chooser has a tab per item group")
	key(KEY_F, false, true)
	await get_tree().process_frame
	var chooser_search: LineEdit = screen.find_child("ChooserSearch", true, false)
	check(chooser_search != null and chooser_search.visible and chooser_search.has_focus(), "Ctrl+F focuses the chooser's search")
	if chooser_search != null:
		chooser_search.text = "inserter"
		chooser_search.text_changed.emit("inserter")
	await get_tree().process_frame
	check(_find_slot_tip(screen, Kit.recipe_name("inserter") + " (Recipe)") != null and _find_slot_tip(screen, Kit.recipe_name("electronic-circuit") + " (Recipe)") == null,
		"typing filters the recipes across every group")
	if chooser_search != null:
		var esc := InputEventKey.new()
		esc.physical_keycode = KEY_ESCAPE
		esc.keycode = KEY_ESCAPE
		esc.pressed = true
		chooser_search.gui_input.emit(esc)
	await get_tree().process_frame
	check(chooser_search != null and chooser_search.text == "" and _find_slot_tip(screen, Kit.recipe_name("electronic-circuit") + " (Recipe)") != null,
		"Esc clears the search")
	if chooser_search != null:
		chooser_search.release_focus()
	var uncommon := screen.find_children("*", "Button", true, false).filter(func(b): return (b as Button).tooltip_text == Kit.pretty("uncommon").capitalize())
	if not uncommon.is_empty():
		(uncommon[0] as Button).pressed.emit()
	await get_tree().process_frame
	var gear_slot := _find_slot_tip(screen, Kit.recipe_name("iron-gear-wheel") + " (Recipe)")
	if gear_slot != null:
		gear_slot.clicked.emit(MOUSE_BUTTON_LEFT, false)
	var sr := sent_one("set_recipe")
	check(sr.get("recipe") == "iron-gear-wheel" and sr.get("q") == "uncommon" and not screen.choosing_recipe(),
		"picking a recipe sets it with the ingredient quality and goes back to the machine")
	asm_msg.erase("recipe")
	asm_msg.erase("rd")
	screen.handle(asm_msg)
	await get_tree().process_frame
	check(screen.choosing_recipe() and screen.title_text() == "Select a recipe for assembling",
		"an assembler without a recipe opens as the chooser, as in Factorio")

	screen.request(79, {"t": "open", "u": 79, "p": 2, "x": 0, "y": 0})
	screen.handle({"t": "gui", "u": 79, "p": 2, "kind": "other", "inv": {"modules": []}, "slots": {"modules": [0, 0]},
		"mp": 450, "mt": "crude-oil", "mr": 430, "pb": 300, "bp": 750, "status": "waiting_for_space_in_destination"})
	await get_tree().process_frame
	texts = _texts(screen)
	check(texts.has("45%") and texts.has("4.3/s") and texts.has("Target full"), "a pumpjack: mining %, its yield per second")
	screen.handle({"t": "gui", "u": 79, "p": 2, "kind": "other", "inv": {"modules": []}, "slots": {"modules": [0, 0]},
		"mp": 900, "mt": "crude-oil", "mr": 430, "pb": 300, "bp": 750, "status": "working"})
	check(_texts(screen).has("90%"), "the mining bar follows mp without a rebuild")

	screen.request(80, {"t": "open", "u": 80, "p": 3, "x": 0, "y": 0})
	screen.handle({"t": "gui", "u": 80, "p": 3, "kind": "other", "inv": {"fuel": [["uranium-fuel-cell", 1]], "burnt": []},
		"slots": {"fuel": [["uranium-fuel-cell", 1]], "burnt": [0]}, "bn": 400, "tc": 67215, "temp": 672, "tmax": 1000})
	await get_tree().process_frame
	check(_texts(screen).has("Temperature: 672.15 °C") and screen.find_child("BurnerBar", true, false) != null,
		"a reactor: the fuel row with its burner bar, the temperature bar")
	screen.request(81, {"t": "open", "u": 81, "p": 4, "x": 0, "y": 0})
	screen.handle({"t": "gui", "u": 81, "p": 4, "kind": "other", "inv": {}, "tc": 50010, "temp": 500, "tmax": 1000,
		"fb": [["water", 200, 200, 15]]})
	await get_tree().process_frame
	check(not screen.shows_inventory() and not ui.window._char_frame.visible and not _texts(screen).has("Fluids"),
		"a heat exchanger opens compact, without fluid rows")

	screen.request(82, {"t": "open", "u": 82, "p": 5, "x": 0, "y": 0})
	screen.handle({"t": "gui", "u": 82, "p": 5, "kind": "lab", "inv": {"input": [["automation-science-pack", 3]]},
		"slots": {"input": [["automation-science-pack", 3], 0]}, "li": ["automation-science-pack", "logistic-science-pack"]})
	await get_tree().process_frame
	var ghost_pack := screen.find_children("*", "Button", true, false).filter(func(b): return b.get("filter_item") == "logistic-science-pack")
	check(ghost_pack.size() == 1, "a lab's empty pack slot shows the pack's ghost")

	# The lab's research box: the research in progress; after it finished with none started, Factorio's
	# "<name> finished. Press T." with its icon and a full bar (ours said "No research in progress").
	var lab_gui := {"t": "gui", "u": 82, "p": 5, "kind": "lab", "inv": {"input": [["automation-science-pack", 3]]},
		"slots": {"input": [["automation-science-pack", 3], 0]}, "li": ["automation-science-pack", "logistic-science-pack"]}
	var lab_model = screen.model
	var lab_had := [lab_model.research, lab_model.research_progress, lab_model.research_finished, lab_model.research_finished_level]
	lab_model.handle({"t": "rs", "cur": "automation", "pr": 500, "q": []})
	screen.handle(lab_gui)
	await get_tree().process_frame
	check(_texts(screen).has(Kit.tech_name("automation")) and _texts(screen).has("50%"), "a lab's box names the research in progress with its share")
	lab_model.handle({"t": "rdone", "k": 900, "r": 1, "tick": 899, "l": [["automation", 0]]})
	lab_model.handle({"t": "rs", "cur": "", "pr": 0, "q": []})
	screen.handle(lab_gui)
	await get_tree().process_frame
	var lab_done := "%s finished. Press T." % Kit.tech_name("automation")
	check(_texts(screen).has(lab_done) and _texts(screen).has("100%") and not _texts(screen).has("No research in progress. Press T."),
		"a lab's box after a research finished: Factorio's \"%s\", a full bar: %s" % [lab_done, _texts(screen).filter(func(t): return "Press" in t or "%" in t)])
	lab_model.handle({"t": "rdone", "k": 950, "r": 1, "tick": 949, "l": [["mining-productivity-3", 7]]})
	screen.handle(lab_gui)
	await get_tree().process_frame
	check(_texts(screen).has("%s finished. Press T." % Kit.tech_level_name("mining-productivity-3", 7)), "a levelled research finished is named with its level")
	ProductionPanels.lab_finished = false
	screen.handle(lab_gui)
	await get_tree().process_frame
	var lab_old := _texts(screen).has("No research in progress. Press T.")
	ProductionPanels.lab_finished = true
	lab_model.handle({"t": "rs", "cur": "logistics", "pr": 0, "q": []})
	screen.handle(lab_gui)
	await get_tree().process_frame
	check(lab_old and lab_model.research_finished == "" and _texts(screen).has(Kit.tech_name("logistics")) and not _texts(screen).has(lab_done),
		"--lab-finished=old: \"No research in progress\" as before; the next research started replaces the finished line")
	lab_model.research = lab_had[0]
	lab_model.research_progress = lab_had[1]
	lab_model.research_finished = lab_had[2]
	lab_model.research_finished_level = lab_had[3]

	screen.request(83, {"t": "open", "u": 83, "p": 6, "x": 0, "y": 0})
	screen.handle({"t": "gui", "u": 83, "p": 6, "kind": "container", "inv": {"chest": [], "trash": []},
		"slots": {"chest": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], "trash": [0, 0]}, "bar": 12,
		"lg": {"mode": "requester", "requests": []},
		"lc": {"tu": 0, "rb": 0, "sec": [{"i": 1, "g": "", "on": 1, "m": 1, "man": 1, "f": [["iron-plate", "", 100, -1, "", -1]]}]},
		"lgs": ["Mall", "Science"]})
	await get_tree().process_frame
	var limit_x: Node = screen.find_child("LimitButton", true, false)
	check(limit_x != null and limit_x.get_parent() is GridContainer and limit_x.get_index() == 12,
		"the chest's red X sits in the grid, in the cell after the last slot")
	check(_texts(screen).has("Normal") and _texts(screen).has("Logistic requests") and _texts(screen).has("[No group assigned]")
		and _texts(screen).has("Trash slots"), "a requester chest: Normal, Logistic requests, its sections, trash slots")
	var trash_box := _find_checkbox(screen, "Trash unrequested")
	if trash_box != null:
		trash_box.button_pressed = true
	check(sent_one("set_chest_logistics").get("tu") == 1, "Trash unrequested sends set_chest_logistics")
	var buffers := _find_checkbox(screen, "Request from buffer chests")
	if buffers != null:
		buffers.button_pressed = true
	check(sent_one("set_chest_logistics").get("rb") == 1, "Request from buffer chests too")
	var pencil: Button = screen.find_child("GroupButton", true, false)
	if pencil != null:
		pencil.pressed.emit()
	var group_box: LineEdit = screen.find_child("GroupName", true, false)
	check(group_box != null and group_box.is_visible_in_tree(), "the section's pencil opens its group picker")
	if group_box != null:
		group_box.text = "Mall"
		group_box.text_submitted.emit("Mall")
	var sg := sent_one("set_section")
	check(sg.get("g") == "Mall" and sg.get("i") == 1, "a group name puts the section in that group")

	screen.request(84, {"t": "open", "u": 84, "p": 7, "x": 0, "y": 0})
	var outs: Array = []
	for i in 12:
		outs.append(0)
	outs[0] = ["iron-plate", 3]
	screen.handle({"t": "gui", "u": 84, "p": 7, "kind": "furnace", "inv": {"input": [], "output": [["iron-plate", 3]]},
		"slots": {"input": [0], "output": outs, "modules": [0, 0, 0, 0]}})
	await get_tree().process_frame
	var out_grid := screen.find_children("*", "GridContainer", true, false).filter(func(gr): return (gr as GridContainer).columns == 6)
	check(_texts(screen).has("No recipe set") and out_grid.size() == 1 and out_grid[0].get_child_count() == 12,
		"the recycler shows all 12 outputs, 6 x 2")
	screen.close_local()
	screen.protos = old_protos
	sent()

	# --- crafting: Factorio's clicks, the queue in the corner ---------------------------------
	m.set_recipe_details([{"name": "iron-gear-wheel", "group": "intermediate-products", "ingredients": [["iron-plate", 2]],
		"products": [["iron-gear-wheel", 1]], "energy": 0.5, "craftable": 50}], ["intermediate-products"])
	ui.toggle_inventory()
	await get_tree().process_frame
	var recipe_slot = _find_recipe_slot(ui, "iron-gear-wheel")
	check(recipe_slot != null, "the recipe is in the crafting grid")
	if recipe_slot != null:
		recipe_slot.clicked.emit(MOUSE_BUTTON_RIGHT, false)
		check(int(sent_one("craft").get("n", 0)) == 5, "right click crafts 5")
		recipe_slot.clicked.emit(MOUSE_BUTTON_LEFT, true)
		check(int(sent_one("craft").get("n", 0)) == 50, "Shift+click crafts as many as possible")
	Bridge.server_tick += 10  # late enough for this `cq` to include the clicks above
	m.handle({"t": "cq", "pr": 500, "l": [[1, "iron-gear-wheel", 3, 0], [2, "transport-belt", 2, 0]]})
	await get_tree().process_frame
	var q = ui.craft_queue
	check(q._slots.size() >= 2 and q._slots[0].visible and q._slots[1].visible and q._slots[0].count == 3, "the crafting queue shows each entry")
	check(q._slots[0].progress > 0.0 and q._slots[1].progress < 0.0, "the first has the progress pie (moving: _craft_pie checks where): %s" % q._slots[0].progress)
	q._slots[1].clicked.emit(MOUSE_BUTTON_LEFT, false)
	var cancel := sent_one("cancel_craft")
	check(int(cancel.get("i", 0)) == 2 and int(cancel.get("n", 0)) == 1, "click cancels one")
	q._slots[0].clicked.emit(MOUSE_BUTTON_RIGHT, false)
	check(int(sent_one("cancel_craft").get("n", 0)) == 5, "right click cancels five")
	m.handle({"t": "cq", "pr": 0, "l": []})
	await get_tree().process_frame
	check(not q._slots[0].visible, "an empty queue shows nothing")
	ui.close_all()

	# --- weapons and health -------------------------------------------------------------------
	hud.set_guns(1, [["pistol", "firearm-magazine", 10], ["submachine-gun", "", 0], ["", "", 0]])
	m.other_slots.erase("guns")
	m.other_slots.erase("ammo")
	m.guns_changed.emit()
	var w = ui.weapons
	check(w._guns[0].item == "pistol" and w._guns[0].button_pressed and w._ammo[0].count == 10, "the weapon slots show the selected gun and its ammo")
	check(w._guns[1].item == "submachine-gun" and not w._guns[1].button_pressed and w._ammo[1].item == "", "and the others")
	w._guns[1].clicked.emit(MOUSE_BUTTON_LEFT, false)
	check(int(sent_one("gun").get("i", 0)) == 2, "clicking a gun uses it")
	var gin := PlayerInput.new()
	gin.hud = hud
	gin._next_gun()
	check(sent_one("gun").is_empty(), "Next weapon skips a gun with no ammo (Factorio: the weapon to change to must have ammo)")
	hud.set_guns(1, [["pistol", "firearm-magazine", 10], ["submachine-gun", "firearm-magazine", 5], ["", "", 0]])
	gin._next_gun()
	gin.free()
	check(int(sent_one("gun").get("i", 0)) == 2, "and takes one that has")
	hud.set_health(100, 250)
	check(hud.health_bar.visible and hud.health_bar.value == 100, "the health bar shows while hurt")
	hud.set_health(250, 250)
	check(not hud.health_bar.visible, "and hides at full health")
	hud.set_mining(40)
	check(hud.mining_bar.visible and hud.mining_bar.get_parent() == ui.quickbar, "mining progress sits over the quickbar")
	hud.set_mining(-1)

	# --- technologies (T) ---------------------------------------------------------------------
	m.handle({"t": "techs", "part": 1, "parts": 1, "l": [
		["automation", "a", [], [["automation-science-pack", 1]], 10, 10, 2, ""],
		["electronics", "b", ["automation"], [["automation-science-pack", 1]], 30, 15, 1, ""],
		["logistics-2", "c", ["electronics"], [["automation-science-pack", 1], ["logistic-science-pack", 1]], 200, 30, 0, ""]]})
	m.handle({"t": "rs", "cur": "", "pr": 0, "q": []})
	ui.research.selected = ""  # an earlier check selected "automation"
	key(KEY_T)
	await get_tree().process_frame
	await get_tree().process_frame
	var r = ui.research
	check(r.is_open() and ui.is_open(), "T opens the technology screen")
	check(r._slots.size() == 3 and r.selected == "electronics", "every technology is in the tree; an available one is selected")
	check(r._tree_slots["logistics-2"].position.y > r._tree_slots["electronics"].position.y and r._tree_slots["electronics"].position.y > r._tree_slots["automation"].position.y,
		"the tree: what it needs above the selected technology, what needs it below")
	check(r._list.get_child(0) == r._slots["electronics"] and r._list.get_child(2) == r._slots["automation"],
		"the list of technologies: available first, researched last")
	var start: Button = _find_button(r, "Start research")
	check(start != null and not start.disabled, "an available technology can be started")
	if start != null:
		start.pressed.emit()
		check(sent_one("research").get("name") == "electronics", "Start research sends it")
	m.handle({"t": "rs", "cur": "electronics", "pr": 400, "q": []})
	await get_tree().process_frame
	check(r._slots["electronics"].progress > 0.39 and r._slots["electronics"].queue_place == 1, "its slot shows the progress")
	var cancel_button: Button = _find_button(r, "Cancel research")
	check(cancel_button != null, "the research in progress can be cancelled")
	if cancel_button != null:
		cancel_button.pressed.emit()
		check(sent_one("research_cancel").get("name") == "electronics", "Cancel research sends it")
	# Issue #7: a trigger technology (2.x's red science: craft a lab) has no Start research button.
	var three := [["automation", "a", [], [["automation-science-pack", 1]], 10, 10, 2, ""],
		["electronics", "b", ["automation"], [["automation-science-pack", 1]], 30, 15, 1, ""],
		["logistics-2", "c", ["electronics"], [["automation-science-pack", 1], ["logistic-science-pack", 1]], 200, 30, 0, ""]]
	m.handle({"t": "techs", "part": 1, "parts": 1, "l": three + [["red-science", "d", ["automation"], [], 1, 0, 1, "craft-item"]]})
	m.handle({"t": "rs", "cur": "", "pr": 0, "q": []})
	r.select("red-science")
	await get_tree().process_frame
	check(_find_button(r, "Start research") == null and _find_button(r, "Add to queue") == null,
		"a trigger technology can't be started, as in Factorio")
	m.handle({"t": "techs", "part": 1, "parts": 1, "l": three})
	m.handle({"t": "rs", "cur": "electronics", "pr": 400, "q": []})
	await get_tree().process_frame
	r.select("logistics-2")
	await get_tree().process_frame
	start = _find_button(r, "Add to queue")
	# L12: a technology whose prerequisites are being researched or queued can be queued behind them, as in
	# Factorio (it was greyed before); --research-chain=off keeps the old rule.
	if r.research_chain:
		check(start != null and not start.disabled, "a technology whose prerequisite is being researched can be queued behind it")
	else:
		check(start != null and start.disabled, "a technology that isn't available yet can't be queued")
	ui.toggle_inventory()
	check(not ui.is_open(), "E closes the technology screen")
	key(KEY_T)
	await get_tree().process_frame
	key(KEY_T)
	await get_tree().process_frame
	check(not r.is_open(), "T again closes it")

	# --- keys that mustn't reach buttons, and the mouse over windows --------------------------
	ui.toggle_inventory()
	click_main(ui, 2)
	await get_tree().process_frame
	check(get_viewport().gui_get_focus_owner() == null, "nothing in the UI takes keyboard focus (Space, Enter, Tab, arrows stay game keys)")
	ui.close_all()
	ui.hand = {}
	player.cursor_item = ""
	check(not ui.mouse_over_gui() or DisplayServer.get_name() != "headless", "no window under a headless mouse")

	# --- tooltips and scale --------------------------------------------------------------------
	var tip = Kit.tooltip("Iron plate", [["100", "iron-plate"], ["Red", "", Kit.RED_TEXT]])
	check(tip is Control and tip.get_child_count() == 3, "a Factorio tooltip has its title and lines")
	tip.free()
	check(Kit.scale_for(720) == 1.0 and Kit.scale_for(1080) == 1.0 and Kit.scale_for(1440) == 1.25 and Kit.scale_for(1659) == 1.5
		and Kit.scale_for(2160) == 2.0, "UI scale like Factorio's: 1280x720 and 1080p 100%, 2880x1659 150%")



## Blueprints and planners: Factorio's exchange strings, the library (B) with its books, search,
## moves and import, taking records into the cursor, the blueprint, book and planner windows and
## what they write back, the mod's undo entries, the selection highlight and quality cycling.


func _first_person_aim(hud: Hud) -> void:
	const G := preload("res://scripts/world/ground_height.gd")
	G.clear()
	var vp := SubViewport.new()
	vp.size = Vector2i(640, 360)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var rig := CameraRig.new()
	vp.add_child(rig)
	await get_tree().process_frame  # its default view's deferred toggles
	if not rig.first_person:
		rig.toggle_first_person()
	var world := WorldMirror.new()
	world.pick_build_usec = 1 << 40  # the whole pick index at once (see _predictions)
	# Names without models: the boxes are the placeholders' heights (visuals.gd), whatever is read.
	world.protos.add_entities([
		[1, "fp-test-assembler", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 120, 120, 120, 3, 3],
		[2, "fp-test-chest", "container", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[3, "fp-test-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
	])
	world.chunks[Vector2i.ZERO] = ChunkView.new()
	world._add([901, 1, 10 * 256 + 128, 7 * 256 + 128, 0])  # an assembler, its south face at y = 9
	world._add([902, 2, 20 * 256 + 128, 9 * 256 + 128, 0])  # a chest
	world._add([903, 3, 20 * 256 + 128, 7 * 256 + 128, 0])  # a belt behind it
	var machine: WorldMirror.Rec = world.entities[901]
	var chest: WorldMirror.Rec = world.entities[902]
	var belt: WorldMirror.Rec = world.entities[903]
	var input := PlayerInput.new()
	input.world = world
	input.hud = hud
	input.rig = rig
	input.tile_brush.pi = input
	input.cursor_item = ""
	input.fp_pick_models = true
	var look := func(at: Vector3, yaw: float, pitch: float) -> void:
		rig.global_position = at
		rig._look_yaw = yaw
		rig._look_pitch = pitch
		rig._process(0.0)
		input._update_ground()
	# Standing two tiles south of the assembler's face, looking level north at it.
	look.call(Vector3(10.5, 0, 11.0), 0.0, 0.0)
	var inside := Rect2(9, 6, 3, 3).has_point(input.ground)
	var unit_of := func(r: WorldMirror.Rec) -> String: return str(r.unit) if r != null else "nothing"
	check(input.hovered == machine and input.has_ground and inside,
		"K7: first person, looking level at a machine two tiles off selects it (hovered %s, cursor at %s)" % [unit_of.call(input.hovered), input.ground])
	# Looking down past a chest: the ray meets the ground on the belt behind it (3.5 tiles off).
	var past := rad_to_deg(atan(CameraRig.EYE_HEIGHT / 3.5))
	look.call(Vector3(20.5, 0, 11.0), 0.0, past)
	var ground_pt = rig.ground_point(rig.aim_position())
	check(ground_pt != null and Rect2(20, 7, 1, 1).has_point(Vector2(ground_pt.x, ground_pt.z)) and world.pick(Vector2(ground_pt.x, ground_pt.z)) == belt,
		"(the ray meets the ground on the belt behind the chest)")
	check(input.hovered == chest and Rect2(20, 9, 1, 1).has_point(input.ground),
		"K7: a belt behind a chest isn't picked through the chest: the chest is (hovered %s)" % unit_of.call(input.hovered))
	sent()
	input._rmb_down = true
	input._update_mining(0.0)
	var mines: Array = sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "mine")
	check(mines.size() == 1 and int(mines[0].get("u", 0)) == 902, "K7: the right button mines the chest looked at, not the belt behind it: %s" % [mines])
	input._rmb_down = false
	input._update_mining(0.0)
	sent()
	# A car behind the chest (further along the ray than what it met) isn't hovered; one in front is.
	var car_behind := [77, 9, Vector2i.ZERO, Vector2(20.5, 6.0), Vector2.ONE, 0.0, 6.0]
	var car_front := [78, 9, Vector2i.ZERO, Vector2(20.5, 10.5), Vector2.ONE, 0.0, 0.5]
	check(input._nearer_than_aim(car_behind).is_empty() and input._nearer_than_aim(car_front) == car_front,
		"K7: a vehicle counts only in front of what the ray met")
	# Holding something: on the machine's side it goes just out from the face; on the chest's top, where the ray met it.
	input.cursor_item = "fp-test-chest"
	look.call(Vector3(10.5, 0, 11.0), 0.0, 0.0)
	var beside := input.build_point()
	check(input.hovered == null and not input._aim.is_empty(), "with something held nothing is hovered, as before, but the aim still decides where it goes")
	input.cursor_item = "fp-test-assembler"
	var beside_big := input.build_point()
	check(beside.is_equal_approx(Vector2(10.5, 9.5)) and absf(beside_big.y - 10.5) < 0.001,
		"K7: a held chest goes on the tile in front of the machine's face (%s), a held assembler as far out as it reaches (%s)" % [beside, beside_big])
	look.call(Vector3(20.5, 0, 11.0), 0.0, past)
	check(input.build_point() == input.ground, "on the chest's top the held entity stays where the ray met it (fast-replace, or red)")
	input.cursor_item = ""
	# Looking down at a belt with nothing in front: the belt, as before.
	look.call(Vector3(20.5, 0, 6.0), 180.0, rad_to_deg(atan(CameraRig.EYE_HEIGHT / 1.5)))
	check(input.hovered == belt, "looking down at a belt with nothing before it picks the belt")
	# Hills: the boxes stand on the ground under them, as the models do.
	var hill := Image.create(32, 32, false, Image.FORMAT_RF)
	hill.fill(Color(3.0, 0.0, 0.0))
	G.set_field(hill, Vector2(-64, -64), 4.0)
	look.call(Vector3(10.5, 3.0, 11.0), 0.0, 0.0)
	check(input.hovered == machine, "K7: on a 3-tile hill, looking level at the machine standing on it picks it")
	G.clear()
	# --fp-pick=ground: the ground point picks, as before K7.
	input.fp_pick_models = false
	look.call(Vector3(10.5, 0, 11.0), 0.0, 0.0)
	var level_old := input.hovered
	look.call(Vector3(20.5, 0, 11.0), 0.0, past)
	check(level_old == null and input.hovered == belt and input._aim.is_empty(),
		"--fp-pick=ground: a level look picks nothing and the belt behind the chest is picked, as before")
	input.fp_pick_models = true
	rig.toggle_first_person()
	input._update_ground()
	check(input._aim.is_empty(), "out of first person the ray pick stays off")
	hud.ui.set_selected(null)
	input.free()
	var cv0: ChunkView = world.chunks[Vector2i.ZERO]
	world.chunks.clear()
	cv0.free()
	world.free()
	vp.queue_free()
	await get_tree().process_frame


## Step 6 (add-on API 1.7): an add-on's camera taken with take({"input": false, "aim": "center"})
## aims the player's controls at the middle of the screen (camera_rig.gd aims_center): looking level
## at a machine from the add-on's camera hovers it (the mouse's ray, as before, met nothing there); a
## camera modifier's offset cuts first person's pick reach by its length, so a moved eye never picks
## further than the player's own; and the mouse no longer turns the hidden first-person view while an
## add-on has the camera.


func _center_aim(hud: Hud) -> void:
	const G := preload("res://scripts/world/ground_height.gd")
	G.clear()
	var vp := SubViewport.new()
	vp.size = Vector2i(640, 360)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var rig := CameraRig.new()
	vp.add_child(rig)
	await get_tree().process_frame  # its default view's deferred toggles
	if rig.first_person:
		rig.toggle_first_person()
	var world := WorldMirror.new()
	world.pick_build_usec = 1 << 40
	world.protos.add_entities([
		[1, "ca-test-assembler", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 120, 120, 120, 3, 3],
		[2, "ca-test-chest", "container", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
	])
	world.chunks[Vector2i.ZERO] = ChunkView.new()
	world._add([911, 1, 10 * 256 + 128, 7 * 256 + 128, 0])  # an assembler, its south face at y = 9
	var machine: WorldMirror.Rec = world.entities[911]
	var input := PlayerInput.new()
	input.world = world
	input.hud = hud
	input.rig = rig
	input.tile_brush.pi = input
	input.cursor_item = ""
	input.fp_pick_models = true
	var unit_of := func(r: WorldMirror.Rec) -> String: return str(r.unit) if r != null else "nothing"
	# An add-on's camera two tiles south of the face, at eye height, looking level north at it.
	var shot := Transform3D(Basis.IDENTITY, Vector3(10.5, CameraRig.EYE_HEIGHT, 11.0))
	rig.take_over()
	rig.camera.global_transform = shot
	input._update_ground()
	var plain := [rig.aims_center(), input.hovered]
	rig.hand_back()
	rig.take_over(true)
	rig.camera.global_transform = shot
	input._update_ground()
	check(not plain[0] and plain[1] != machine and rig.aims_center() and input.hovered == machine and Rect2(9, 6, 3, 3).has_point(input.ground),
		"aim center: an add-on's camera with aim center hovers the machine on its centre ray (without: %s), cursor at %s" % [unit_of.call(plain[1]), input.ground])
	# The mouse doesn't turn the hidden first-person view while an add-on has the camera.
	rig.hand_back()
	rig.toggle_first_person()
	rig.take_over(true)
	var yaw0 := rig._look_yaw
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(40, 0)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	input._unhandled_input(motion)
	var yaw_taken := rig._look_yaw
	rig.hand_back()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	input._unhandled_input(motion)
	var yaw_own := rig._look_yaw
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if captured:
		check(yaw_taken == yaw0 and yaw_own != yaw0, "aim center: the mouse turns first person's view only while no add-on has the camera: %s %s %s" % [yaw0, yaw_taken, yaw_own])
	else:
		print("(the mouse can't be captured headless: the mouse look check is left out)")
	rig._look_yaw = yaw0
	# First person's pick reach with a modifier: a chest whose face is 64.5 tiles off is out of reach;
	# an offset of 1.5 forward brings the eye to 63 from it, still out of reach (64 less 1.5).
	var picks := {}
	for d: float in [63.5, 65.0]:
		world._add([920, 2, int((-40.5 + d) * 256), int(16.5 * 256), 0])
		for o: float in [0.0, 1.5]:
			rig.set_modifier(Vector3(0, 0, -o), Vector3.ZERO, 0.0)
			rig.global_position = Vector3(-40.5, 0, 16.5)
			rig._look_yaw = -90.0
			rig._look_pitch = rad_to_deg(atan2(CameraRig.EYE_HEIGHT - 0.4, d))
			rig._process(0.0)
			input._aim_from(rig.aim_position(), null)
			picks["%s@%s" % [d, o]] = not input._aim.is_empty()
		world._remove(920)
	var reach_cut := rig.modifier_reach()
	rig.set_modifier(Vector3.ZERO, Vector3.ZERO, 0.0)
	rig._process(0.0)
	check(picks == {"63.5@0.0": true, "63.5@1.5": true, "65.0@0.0": false, "65.0@1.5": false} and is_equal_approx(reach_cut, 1.5),
		"aim center: a 1.5-tile modifier cuts the pick's reach by 1.5 (AIM_RANGE %d): the eye moved closer picks nothing the player's own eye couldn't: %s" % [PlayerInput.AIM_RANGE, picks])
	rig.toggle_first_person()
	hud.ui.set_selected(null)
	input.free()
	var cv0: ChunkView = world.chunks[Vector2i.ZERO]
	world.chunks.clear()
	cv0.free()
	world.free()
	vp.queue_free()
	await get_tree().process_frame


## K23: a finished research (`rdone`) plays Factorio's research_completed chime once a tick however many
## finished, writes "<icon> <name> researched." in the console for each (an infinite one at the level
## it finished), and the research panel shows the last one's icon and "<name> finished. Press T." until
## the next research starts.


func _research_done(hud: Hud) -> void:
	var ui = hud.ui
	var m = ui.model
	var r = ui.research_hud
	var chimes := [0]
	var was_chime: Callable = ui.research_chime
	ui.research_chime = func() -> void: chimes[0] += 1
	var saved_techs: Dictionary = m.techs.duplicate(true)
	var lines_at_start: int = m.chat_log.size()
	var lines_before := lines_at_start
	var plain := {"order": "a", "prerequisites": [], "ingredients": [], "count": 10, "seconds": 10.0, "state": 1, "trigger": "",
		"effects": [], "level": 1, "max_level": 1, "trigger_detail": [], "saved": 0.0, "formula": ""}
	m.techs["automation"] = plain.duplicate()
	m.techs["logistics"] = plain.duplicate()
	var infinite: Dictionary = plain.duplicate()
	infinite["level"] = 7
	infinite["max_level"] = -1
	m.techs["mining-productivity-3"] = infinite
	m.handle({"t": "rs", "cur": "automation", "pr": 990, "q": []})
	await get_tree().process_frame
	check(r._name.text == Kit.tech_name("automation") and r._percent.text == "99%", "K23: researching automation, 99%%: %s" % r._name.text)

	m.handle({"t": "rdone", "k": 900, "r": 1, "tick": 899, "l": [["automation", 0]]})
	await get_tree().process_frame
	check(chimes[0] == 1, "K23: a finished research plays the chime once: %d" % chimes[0])
	var added: Array = m.chat_log.slice(lines_before)
	check(added.size() == 1 and str(added[0][0]) == "" and str(added[0][1]) == "[technology=automation] %s researched." % Kit.tech_name("automation"),
		"K23: its console line is Factorio's technology-researched, the technology's icon and name: %s" % [added])
	var tokens: Array = RichText.parse(str(added[0][1])) if added.size() == 1 else []
	check(not tokens.is_empty() and tokens[0]["t"] == "icon" and tokens[0]["kind"] == "technology" and tokens[0]["name"] == "automation",
		"K23: the line starts with the technology's icon: %s" % [tokens])
	check(m.research == "" and r.finished == "automation" and r._name.text == "%s finished. Press T." % Kit.tech_name("automation")
		and r._percent.text == "100%" and not r._hint.visible,
		"K23: the research panel says it finished (before the next rs): %s, %s" % [r._name.text, r._percent.text])
	var icon: Texture2D = GuiAssets.tech_icon("automation")
	check(r._icon.texture == icon or icon == null, "K23: with the technology's icon: %s" % r._icon.texture)
	var shown: bool = ui.chat._lines.get_child_count() > 0 and (ui.chat._lines.get_child(ui.chat._lines.get_child_count() - 1) as RichTextLabel).get_parsed_text().ends_with("researched.")
	check(shown, "K23: the console shows the line")
	m.handle({"t": "rs", "cur": "", "pr": 0, "q": []})
	await get_tree().process_frame
	check(r.finished == "automation" and r._name.text.ends_with("finished. Press T."), "K23: it stays after rs says nothing is researched: %s" % r._name.text)

	# Two in one tick: one chime, a line each; an infinite one with the level it finished.
	m.handle({"t": "rs", "cur": "mining-productivity-3", "pr": 999, "q": []})
	await get_tree().process_frame
	check(r._name.text == Kit.tech_level_name("mining-productivity-3", 7), "K23: an infinite research in progress at its level: %s" % r._name.text)
	lines_before = m.chat_log.size()
	m.handle({"t": "rdone", "k": 1200, "r": 2, "tick": 1199, "l": [["logistics", 0], ["mining-productivity-3", 7]]})
	m.handle({"t": "rdone", "k": 1200, "r": 3, "tick": 1199, "l": [["automation", 0]]})  # the same tick, another message
	await get_tree().process_frame
	added = m.chat_log.slice(lines_before)
	var mining := Kit.tech_level_name("mining-productivity-3", 7)
	check(chimes[0] == 2, "K23: several in one tick chime once (Factorio 2.0.34): %d chimes in all" % chimes[0])
	check(added.size() == 3 and str(added[0][1]) == "[technology=logistics] %s researched." % Kit.tech_name("logistics")
		and str(added[1][1]) == "[technology=mining-productivity-3] %s researched." % mining and mining.ends_with(" 7"),
		"K23: each gets its line, the infinite one with its level: %s" % [added])
	check(r.finished == "automation", "K23: the panel shows the last one: %s" % r.finished)
	m.handle({"t": "rdone", "k": 1300, "r": 4, "tick": 1299, "l": [["mining-productivity-3", 8]], "n": 4})
	await get_tree().process_frame
	check(chimes[0] == 3 and r.finished == "mining-productivity-3" and r._name.text == "%s finished. Press T." % Kit.tech_level_name("mining-productivity-3", 8)
		and str(m.chat_log[-1][1]) == "4 more technologies researched.",
		"K23: an infinite one finished: its level in the panel; n's rest in one line: %s / %s" % [r._name.text, m.chat_log[-1][1]])
	m.handle({"t": "rs", "cur": "logistics", "pr": 0, "q": []})
	await get_tree().process_frame
	check(r.finished == "" and r._name.text == Kit.tech_name("logistics"), "K23: the next research clears it: %s" % r._name.text)
	# Something else finishing (a trigger technology) while a research runs: chime and line, the panel
	# keeps the research in progress.
	m.handle({"t": "rdone", "k": 1350, "r": 5, "tick": 1349, "l": [["automation", 0]]})
	await get_tree().process_frame
	check(chimes[0] == 4 and m.research == "logistics" and r._name.text == Kit.tech_name("logistics")
		and str(m.chat_log[-1][1]).ends_with(" researched."), "K23: another technology finishing keeps the research in progress: %s" % r._name.text)
	# A bridge before `rdone`: its msg with `tech` is said the same way (main.gd turns it into an rdone
	# with the message's k).
	m.handle({"t": "rs", "cur": "", "pr": 0, "q": []})
	m.handle({"t": "rdone", "k": 1400, "l": [["automation", 0]]})
	await get_tree().process_frame
	check(chimes[0] == 5 and r.finished == "automation", "K23: an rdone without its own tick chimes by k")
	m.handle({"t": "rdone", "l": [[]], "tick": 1500})
	m.handle({"t": "rdone", "l": "x", "tick": 1501})
	check(chimes[0] == 5, "K23: an rdone naming nothing plays nothing")

	ui.research_chime = was_chime
	m.chat_log.resize(mini(m.chat_log.size(), lines_at_start))
	m.handle({"t": "rs", "cur": "", "pr": 0, "q": []})
	m.techs.clear()
	m.techs.merge(saved_techs)
	r.finished = ""
	r.finished_level = 0
	await get_tree().process_frame


## The latency layer (FFF #83): what is built shows at once, before the game confirms it, and
## goes when the game's entity is drawn or the game has moved on without it.
## J20 and J27: what the character mines goes from the world on the bridge's `mnd` (the tick it is mined,
## ahead of its `del`), a record of it coming before the `del` (read before the mining) is left out, and
## its items fly to the character; a drill with nothing left to mine has Factorio's resources-depleted
## icon over it, not a button on the alert bar.


func _mining_feedback(hud: Hud) -> void:
	var ui = hud.ui
	var m: UiModel = ui.model
	var world := WorldMirror.new()
	world.protos.add_entities([
		[1, "transport-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[2, "tree-01", "tree", -0.5, -0.5, 0.5, 0.5, 60, 120, 60, 1, 1],
		[3, "electric-mining-drill", "mining-drill", -1.5, -1.5, 1.5, 1.5, 120, 120, 120, 3, 3],
	])
	world.chunks[Vector2i.ZERO] = ChunkView.new()
	world._add([90, 1, 4 * 256 + 128, 4 * 256 + 128, 4])
	world._add([0, 2, 6 * 256 + 128, 4 * 256 + 128, 0])
	var tree_key = WorldMirror.static_key(2, 6 * 256 + 128, 4 * 256 + 128)
	check(world.entities.has(90) and world.entities.has(tree_key), "J20: a belt and a tree in the world")
	world._dirty.clear()
	var belt_mnd := {"t": "mnd", "u": 90, "p": 1, "x": 4 * 256 + 128, "y": 4 * 256 + 128, "g": 1,
		"l": [["transport-belt", 1], ["iron-plate", 3]]}
	world.mined(belt_mnd)
	ui.mined(belt_mnd)
	check(not world.entities.has(90) and world._dirty.has(Vector2i.ZERO),
		"J20: the mined belt leaves the world on `mnd`, its chunk drawn again, without waiting for the `del`")
	var flights: Array = ui.flying._flights
	check(flights.size() >= 2 and str(flights[-2][0]) == "transport-belt" and str(flights[-1][0]) == "iron-plate"
		and str(flights[-1][1]) == "+3" and str(flights[-1][3]) == "character" and flights[-1][2] is Vector3,
		"J20: the belt and the items it carried fly from where it was to the character: %s" % [flights.slice(-2)])
	flights.clear()  # (the test's avatar has no ground for "character" to land on)
	world._add([90, 1, 4 * 256 + 128, 4 * 256 + 128, 4])
	check(not world.entities.has(90), "J20: a record of it read before the mining (a snapshot or `upd` ahead of the `del`) is left out")
	world.handle({"t": "del", "u": 90, "p": 1, "x": 4 * 256 + 128, "y": 4 * 256 + 128})
	check(not world._mined_early.has(90), "J20: its `del` ends that")
	world._add([90, 1, 4 * 256 + 128, 4 * 256 + 128, 4])
	check(world.entities.has(90), "J20: after the `del` a record of that unit is taken again")
	var ore_mnd := {"t": "mnd", "u": 0, "p": 2, "x": 6 * 256 + 128, "y": 4 * 256 + 128, "g": 0, "l": [["wood", 4]]}
	world.mined(ore_mnd)
	check(world.entities.has(tree_key), "J20: `g` 0 (ore mined a unit at a time) leaves the entity")
	world.mined({"t": "mnd", "u": 0, "p": 2, "x": 6 * 256 + 128, "y": 4 * 256 + 128, "g": 1, "l": [["wood", 4]]})
	check(not world.entities.has(tree_key), "J20: a tree (no unit number) goes by its prototype and place")
	for cv in world.chunks.values():
		cv.free()
	world.free()

	# --- J27: a drill with nothing left to mine ------------------------------------------------------
	check(AlertIconsScript.DRAWN.has("depleted") and str(AlertIconsScript.DRAWN["depleted"][0]) == "resources-depleted-icon.png",
		"J27: the depleted drill's icon is Factorio's resources-depleted-icon.png")
	var icons := AlertIconsScript.new()
	add_child(icons)
	var fake_world := GDScript.new()
	fake_world.source_code = "extends RefCounted\nvar entities := {}\n"
	fake_world.reload()
	var fw = fake_world.new()
	var drill_rec := WorldMirror.Rec.new()
	drill_rec.key = 31
	drill_rec.unit = 31
	drill_rec.pos = Vector2(12, 8)
	fw.entities[31] = drill_rec
	icons.world = fw
	icons.show_alerts({"depleted": [{"position": Vector2(12, 8), "si": 1, "unit": 31}]}, 1)
	check(icons.shown.get("depleted") == 1 and is_equal_approx((icons.placed["depleted"][0] as Vector3).x, 12.0),
		"J27: the icon over the drill, where the world draws it: %s" % [icons.placed.get("depleted")])
	icons.world = null
	icons.queue_free()
	m.handle({"t": "al", "l": [["depleted", 1, [[12 * 256, 8 * 256, 1, "electric-mining-drill", 31, "no_minable_resources"]]]]})
	await get_tree().process_frame
	var bar_button = ui.alerts._buttons.get("depleted")
	check(bar_button == null or not bar_button.visible, "J27: no button on the alert bar (Factorio has no alert for it)")
	m.handle({"t": "al", "l": []})
	await get_tree().process_frame


## Issue #24: the right button held on something out of the character's reach (ore past its
## resource reach, a tree past its reach) sends the `mine` (the bridge says "Out of reach") but gives
## no swing hint, so fx.gd plays no swing sound, sparks or dust; within reach the hint is as before;
## the bridge's "Out of reach" stops a swing the client let start and keeps it stopped on that target
## until the character moves; `--mine-reach-check=off` swings at anything, as before.


func _mine_reach(hud: Hud) -> void:
	var m: UiModel = hud.ui.model
	var had_info: Dictionary = m.character_info
	m.character_info = {}  # Factorio 2.1's base reach until `cinfo`: 10, resources 2.7
	var world := WorldMirror.new()
	world.pick_build_usec = 1 << 40  # the whole pick index at once (see _predictions): the sections run in one frame
	world.protos.add_entities([
		[1, "iron-ore", "resource", -0.5, -0.5, 0.5, 0.5, 100, 120, 140, 1, 1],
		[2, "tree-01", "tree", -0.5, -0.5, 0.5, 0.5, 60, 120, 60, 1, 1],
	])
	world.chunks[Vector2i.ZERO] = ChunkView.new()
	world._add([0, 1, 5 * 256 + 128, 128, 0])  # ore 5 tiles off: past 2.7 + the bridge's 1.5
	world._add([0, 1, 3 * 256 + 128, 128, 0])  # ore 3 tiles off: in reach
	world._add([0, 2, 14 * 256 + 128, 128, 0])  # a tree 14 tiles off: past 10 + 1.5
	world._add([0, 2, 8 * 256 + 128, 128, 0])  # a tree 8 tiles off
	var input := PlayerInput.new()
	input.world = world
	input.hud = hud
	input.tile_brush.pi = input
	input.cursor_item = ""
	var body := Avatar.new()
	body.position = Vector3(0.5, 0.0, 0.5)
	input.avatar = body
	input.has_ground = true
	var none := Vector2(INF, INF)
	var press := func(at: Vector2) -> Vector2:
		input.ground = at
		input._rmb_down = true
		input._mine_timer = 0.0
		input._update_mining(0.016)
		return body.mining_for_sound()
	var release := func() -> void:
		input._rmb_down = false
		input._update_mining(0.016)
	sent()
	var far_ore: Vector2 = press.call(Vector2(5.5, 0.5))
	var far_mines: Array = sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "mine")
	check(far_ore == none and far_mines.size() == 1,
		"issue #24: ore 5 tiles off (past its 2.7 reach and the bridge's slack): the `mine` is sent, no swing: %s %s" % [far_ore, far_mines])
	var near_ore: Vector2 = press.call(Vector2(3.5, 0.5))
	check(near_ore == Vector2(3.5, 0.5), "issue #24: ore 3 tiles off swings on the click, as before: %s" % near_ore)
	release.call()
	var far_tree: Vector2 = press.call(Vector2(14.5, 0.5))
	release.call()
	var near_tree: Vector2 = press.call(Vector2(8.5, 0.5))
	check(far_tree == none and near_tree == Vector2(8.5, 0.5),
		"issue #24: a tree 14 tiles off doesn't swing, one 8 off does (reach 10): %s %s" % [far_tree, near_tree])
	# The bridge refuses (its reach is the real character's): the swing stops and stays stopped.
	input.heard_message("Out of reach")
	var refused := body.mining_for_sound()
	var held: Vector2 = press.call(Vector2(8.5, 0.5))
	check(refused == none and held == none,
		"issue #24: the bridge's \"Out of reach\" stops the swing, held on the same target it stays stopped: %s %s" % [refused, held])
	body.position = Vector3(1.5, 0.0, 0.5)
	var moved: Vector2 = press.call(Vector2(8.5, 0.5))
	check(moved == Vector2(8.5, 0.5), "issue #24: the character moving tries it again: %s" % moved)
	release.call()
	# A bigger reach from `cinfo` (bonuses): the ore 5 off is in reach.
	m.character_info = {"reach": 100, "rreach": 40}
	var bonus_ore: Vector2 = press.call(Vector2(5.5, 0.5))
	release.call()
	check(bonus_ore == Vector2(5.5, 0.5), "issue #24: the reach from `cinfo` counts (resource reach 4): %s" % bonus_ore)
	m.character_info = {}
	# Refusals for other reasons (can_hand_mine): uranium in reach, swept across three tiles. The first
	# tile's swing stops on "This needs a mining drill" and no later tile of it swings; iron ore in the
	# same hold still does; let go and pressed again, uranium is tried again.
	world.protos.add_entities([[3, "uranium-ore", "resource", -0.5, -0.5, 0.5, 0.5, 80, 200, 40, 1, 1],
		[4, "foreign-chest", "container", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1]])
	for x in [1, 2, 3]:
		world._add([0, 3, x * 256 + 128, 2 * 256 + 128, 0])
	world._add([95, 4, 4 * 256 + 128, 4 * 256 + 128, 0])
	var swept: Array = []
	swept.append(press.call(Vector2(1.5, 2.5)))
	input.heard_message("This needs a mining drill")
	swept.append(body.mining_for_sound())
	swept.append(press.call(Vector2(2.5, 2.5)))
	swept.append(press.call(Vector2(3.5, 2.5)))
	var iron_after: Vector2 = press.call(Vector2(3.5, 0.5))
	check(swept[0] == Vector2(1.5, 2.5) and swept.slice(1).all(func(v: Vector2) -> bool: return v == none)
		and iron_after == Vector2(3.5, 0.5),
		"issue #24: \"This needs a mining drill\" stops the swing on uranium and the sweep over the patch stays silent; iron ore still swings: %s %s" % [swept, iron_after])
	release.call()
	var uranium_again: Vector2 = press.call(Vector2(2.5, 2.5))
	# "Can't mine that" (another force's chest): stopped on that target, the character moving changes nothing.
	var chest_first: Vector2 = press.call(Vector2(4.5, 4.5))
	input.heard_message("Can't mine that")
	body.position = Vector3(2.0, 0.0, 0.5)
	var chest_held: Vector2 = press.call(Vector2(4.5, 4.5))
	release.call()
	body.position = Vector3(1.5, 0.0, 0.5)
	check(uranium_again == Vector2(2.5, 2.5) and chest_first == Vector2(4.5, 4.5) and chest_held == none,
		"issue #24: uranium is tried again after a release; \"Can't mine that\" stops the swing on that chest, moving or not: %s %s %s" % [uranium_again, chest_first, chest_held])
	check(PlayerInput.MINE_REFUSALS.has("This needs a pump or drill") and PlayerInput.MINE_REFUSALS.size() == 4,
		"issue #24: every reason can_hand_mine refuses with is known: %s" % [PlayerInput.MINE_REFUSALS.keys()])
	# --mine-reach-check=off: uranium swept swings throughout, as before.
	PlayerInput.mine_reach_check = false
	var old_swept: Array = []
	old_swept.append(press.call(Vector2(1.5, 2.5)))
	input.heard_message("This needs a mining drill")
	old_swept.append(press.call(Vector2(2.5, 2.5)))
	old_swept.append(press.call(Vector2(3.5, 2.5)))
	release.call()
	PlayerInput.mine_reach_check = true
	check(old_swept == [Vector2(1.5, 2.5), Vector2(2.5, 2.5), Vector2(3.5, 2.5)],
		"issue #24: --mine-reach-check=off swings over the uranium patch throughout, as before: %s" % [old_swept])
	# --mine-reach-check=off: the swing at anything clicked, the refusal changing nothing (the bug).
	PlayerInput.mine_reach_check = false
	var old_far: Vector2 = press.call(Vector2(14.5, 0.5))
	input.heard_message("Out of reach")
	var old_refused := body.mining_for_sound()
	release.call()
	PlayerInput.mine_reach_check = true
	check(old_far == Vector2(14.5, 0.5) and old_refused == Vector2(14.5, 0.5),
		"issue #24: --mine-reach-check=off swings at a tree out of reach and through the refusal, as before: %s %s" % [old_far, old_refused])
	sent()
	input.avatar = null
	body.free()
	input.free()
	m.character_info = had_info
	for cv in world.chunks.values():
		cv.free()
	world.free()


## Issue #24, the testing agent's cases: rocks (not resources: the character's reach, 10), a building
## and a vehicle out of reach and in it; the reported case, the button held while the mouse sweeps
## across an out-of-reach ore patch (each tile a new target, the bridge refusing each), silent
## throughout and still sending `mine`; the sweep coming onto ore in reach swings; walking into reach
## while holding on a refused target swings, a step still out of it doesn't; the edge (in reach at
## exactly reach + 1.5, as the bridge's `>`, out 1/256 past it); the switch off is the old way.


func _mine_reach_more(hud: Hud) -> void:
	var m: UiModel = hud.ui.model
	var had_info: Dictionary = m.character_info
	m.character_info = {}
	var world := WorldMirror.new()
	world.pick_build_usec = 1 << 40  # the whole pick index at once (see _predictions): the sections run in one frame
	world.protos.add_entities([
		[1, "iron-ore", "resource", -0.5, -0.5, 0.5, 0.5, 100, 120, 140, 1, 1],
		[3, "huge-rock", "simple-entity", -1.0, -1.0, 1.0, 1.0, 90, 90, 90, 2, 2],
		[4, "wooden-chest", "container", -0.35, -0.35, 0.35, 0.35, 120, 90, 40, 1, 1],
		[8, "car", "car", -0.7, -1.0, 0.7, 1.0, 1, 1, 1, 2, 2],
	])
	world.chunks[Vector2i.ZERO] = ChunkView.new()
	world.chunks[Vector2i(0, -1)] = ChunkView.new()
	for i in 5:  # an ore patch 5 to 9 tiles east (all past 2.7 + 1.5)
		world._add([0, 1, (5 + i) * 256 + 128, 128, 0])
	world._add([0, 1, 3 * 256 + 128, 4 * 256 + 128, 0])  # ore about 5 off at (3.5, 4.5): 3 east, 4 south
	world._add([0, 1, 2 * 256 + 128, 2 * 256 + 128, 0])  # ore 2.8 off at (2.5, 2.5): in reach
	world._add([0, 3, 4 * 256, 10 * 256, 0])  # a huge rock at (4, 10): 10.1 off
	world._add([0, 3, 13 * 256, 12 * 256, 0])  # a huge rock at (13, 12): 17 off
	world._add([0, 4, 128, 11 * 256 + 128, 0])  # a chest at (0.5, 11.5): 11 off
	world._add([0, 4, 128, -12 * 256 - 128, 0])  # a chest at (0.5, -12.5): 13 off
	var input := PlayerInput.new()
	input.world = world
	input.hud = hud
	input.tile_brush.pi = input
	input.cursor_item = ""
	var body := Avatar.new()
	body.position = Vector3(0.5, 0.0, 0.5)
	input.avatar = body
	input.has_ground = true
	var none := Vector2(INF, INF)
	var press := func(at: Vector2) -> Vector2:
		input.ground = at
		input._rmb_down = true
		input._mine_timer = 0.0
		input._update_mining(0.016)
		return body.mining_for_sound()
	var release := func() -> void:
		input._rmb_down = false
		input._update_mining(0.016)
	var mines := func() -> Array:
		return sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "mine")
	sent()
	var rock_near: Vector2 = press.call(Vector2(4.0, 10.0))
	release.call()
	var rock_far: Vector2 = press.call(Vector2(13.0, 12.0))
	release.call()
	check(rock_near == Vector2(4.0, 10.0) and rock_far == none,
		"issue #24 (test): a huge rock 10.1 off swings (reach 10, not the ore's 2.7), one 17 off doesn't: %s %s" % [rock_near, rock_far])
	var chest_near: Vector2 = press.call(Vector2(0.5, 11.5))
	release.call()
	mines.call()
	var chest_far: Vector2 = press.call(Vector2(0.5, -12.5))
	var chest_far_mines: Array = mines.call()
	release.call()
	check(chest_near == Vector2(0.5, 11.5) and chest_far == none and chest_far_mines.size() == 1,
		"issue #24 (test): a chest 11 off swings, one 13 off doesn't but its `mine` goes: %s %s %s" % [chest_near, chest_far, chest_far_mines])
	# A vehicle (a mover, picked before the world's records): by its own middle.
	var cars := MoverLayer.new()
	input.movers = cars
	input.hovered_mover = [9401, 8, Vector2i(13 * 256 + 128, 128), Vector2(13.5, 0.5)]
	mines.call()
	var car_far: Vector2 = press.call(Vector2(13.5, 0.5))
	var car_mines: Array = mines.call()
	release.call()
	input.hovered_mover = [9402, 8, Vector2i(6 * 256 + 128, 6 * 256 + 128), Vector2(6.5, 6.5)]
	var car_near: Vector2 = press.call(Vector2(6.5, 6.5))
	release.call()
	input.hovered_mover = []
	input.movers = null
	cars.free()
	check(car_far == none and car_near == Vector2(6.5, 6.5) and car_mines.size() == 1 and int(car_mines[0].get("u", 0)) == 9401,
		"issue #24 (test): a car 13 off doesn't swing (its `mine` goes), one 8.5 off does: %s %s %s" % [car_far, car_near, car_mines])
	# The reported case: the button held, the mouse sweeping across the patch (each tile a new target
	# sent at once, J26), the bridge answering each `mine` with "Out of reach": silent every frame.
	mines.call()
	var heard := []
	var sweep_mines := 0
	input._rmb_down = true
	input._mine_timer = 0.0
	for step in 60:
		input.ground = Vector2(5.0 + step * 0.075, 0.5 + 0.2 * sin(step * 0.5))
		input._update_mining(0.016)
		heard.append(body.mining_for_sound())
		var got: Array = mines.call()
		sweep_mines += got.size()
		if not got.is_empty():
			input.heard_message("Out of reach")
			heard.append(body.mining_for_sound())
	var loud := heard.filter(func(v: Vector2) -> bool: return v != none)
	check(loud.is_empty() and sweep_mines >= 5,
		"issue #24 (test): held across an out-of-reach ore patch, 60 frames over 5 tiles: no swing in any frame (%d `mine` sent): %s" % [sweep_mines, loud])
	input.ground = Vector2(2.5, 2.5)
	input._update_mining(0.016)
	var swept_near := body.mining_for_sound()
	check(swept_near == Vector2(2.5, 2.5), "issue #24 (test): the held sweep onto ore 2.8 off swings at once: %s" % swept_near)
	release.call()
	# Held on ore 5 off and refused: a 0.3 step still out of reach stays silent; walking into reach swings.
	press.call(Vector2(5.5, 0.5))
	input.heard_message("Out of reach")
	body.position = Vector3(0.8, 0.0, 0.5)
	input._update_mining(0.2)
	var stepped := body.mining_for_sound()
	body.position = Vector3(2.0, 0.0, 0.5)
	input._update_mining(0.2)
	var walked_in := body.mining_for_sound()
	release.call()
	check(stepped == none and walked_in == Vector2(5.5, 0.5),
		"issue #24 (test): held on refused ore, a step still out of reach is silent, walking into reach swings: %s %s" % [stepped, walked_in])
	# The edge: resource reach 2.5 from `cinfo` + 1.5 = 4.0, the character at 1.5 and the ore at 5.5.
	m.character_info = {"reach": 100, "rreach": 25}
	body.position = Vector3(1.5, 0.0, 0.5)
	var edge: Vector2 = press.call(Vector2(5.5, 0.5))
	release.call()
	body.position = Vector3(1.5 - 1.0 / 256.0, 0.0, 0.5)
	var past: Vector2 = press.call(Vector2(5.5, 0.5))
	release.call()
	check(edge == Vector2(5.5, 0.5) and past == none,
		"issue #24 (test): ore exactly reach + 1.5 off swings (the bridge mines it), 1/256 further doesn't: %s %s" % [edge, past])
	m.character_info = {}
	body.position = Vector3(0.5, 0.0, 0.5)
	# The switch off: the same sweep swings throughout (the reported bug).
	PlayerInput.mine_reach_check = false
	var old_loud := 0
	input._rmb_down = true
	input._mine_timer = 0.0
	for step in 20:
		input.ground = Vector2(5.0 + step * 0.2, 0.5)
		input._update_mining(0.016)
		if not mines.call().is_empty():
			input.heard_message("Out of reach")
		if body.mining_for_sound() != none:
			old_loud += 1
	release.call()
	PlayerInput.mine_reach_check = true
	check(old_loud == 20, "issue #24 (test): --mine-reach-check=off: the sweep across the patch swings every frame, as reported: %d of 20" % old_loud)
	sent()
	input.avatar = null
	body.free()
	input.free()
	m.character_info = had_info
	for cv in world.chunks.values():
		cv.free()
	world.free()


## Issue #18: what F takes (`pku`): an item off the ground is hidden at once; one off a belt leaves the simulated
## lane on the game's tick by the inserters' own take (pick_up.gd: an `ie` pick by no inserter, the item of its
## kind nearest where the game had it), the item behind it staying; a stack taken in part stays; every kind flies
## from where the nearest of it was to the character with what was got.


func _pick_up(hud: Hud) -> void:
	var ui = hud.ui
	var msg := {"t": "pku", "k": 2005, "l": [
		["iron-gear-wheel", 1, roundi(1.906 * 256), 10 * 256, 9, 801, 0, 2],
		["iron-plate", 1, 30 * 256 + 64, 40 * 256 + 64, 0, 0, 0, 1],
		["copper-plate", 2, roundi(3.5 * 256), 10 * 256, 25, 805, 1, 3],
		["iron-gear-wheel", 3, roundi(4.5 * 256), 10 * 256, 33, 806, 0, 2]]}
	var takes: Dictionary = PickUpScript.belt_takes(msg)
	var tl: Array = takes.get("l", [])
	check(str(takes.get("t", "")) == "ie" and int(takes.get("k", 0)) == 2005 and tl.size() == 18
		and tl.slice(0, 9) == [1, 0, 2005, 1, 2, 0, roundi(1.906 * 256), 10 * 256, 1]
		and tl.slice(9, 18) == [1, 0, 2005, 2, 2, 0, roundi(4.5 * 256), 10 * 256, 4],
		"issue #18: what F took off belts goes to the belt layer as picks by no inserter (unit 0), each its own, on its belt; a stack taken in part isn't: %s" % [tl])
	var spots: Array[Vector2i] = PickUpScript.ground_spots(msg)
	check(spots.size() == 1 and spots[0] == Vector2i(30 * 256 + 64, 40 * 256 + 64), "issue #18: and what it took off the ground is where it lay: %s" % [spots])
	# Five yellow belts in a row along +x at y 10 (belt u from x = u to u + 1), lane 1 each, as _belt_sim's: a gear
	# 0.25 from the first belt's exit and a plate half a tile behind it, read on tick 2000. On 2005 F took the gear
	# where the game had it then (40 on: line position 24, x 1.906).
	var was_cull: bool = BeltItemsScript.Job.view_cull
	BeltItemsScript.Job.view_cull = false
	var items = BeltItemsScript.new()
	add_child(items)
	items._sync = true
	var lm: Array = []
	for u in range(1, 6):
		lm.append_array(_bs_lane(u * 8 + 1, 1, 256, 8, u + 1.0, 10.0, u, 10.0))
	_bs_feed(items, 2000, {"lm": lm, "sl": [9, 2000, 2, 801, 2, 64, 1, 804, 1, 192, 1]})
	var k := 2000
	for f in 3:
		k += 1
		_bs_feed(items, k, {}, 1)
	items.handle(takes)
	for f in 90:
		k += 1
		_bs_feed(items, k, {}, 1)
	var uids: PackedInt64Array = items._state.sim.items_state()[0]
	check(not uids.has(801) and uids.has(804) and not items.has_item(801) and items.has_item(804),
		"issue #18: the gear F took leaves the simulated belt, the plate behind it stays: %s" % [uids])
	items.queue_free()
	BeltItemsScript.Job.view_cull = was_cull
	# The ground's item hidden at once, as main.gd does with each spot.
	var protos := ProtoDB.new()
	protos.add_items([[1, "iron-plate"], [2, "iron-gear-wheel"], [3, "copper-plate"]])
	var gi_layer := GroundItemsScript.new()
	gi_layer.protos = protos
	add_child(gi_layer)
	gi_layer.handle({"t": "gi", "k": 5, "part": 1, "parts": 1, "l": [1, 30 * 256 + 64, 40 * 256 + 64, 1, 31 * 256, 40 * 256]})
	for at in PickUpScript.ground_spots(msg):
		gi_layer.take(at)
	check(gi_layer.count() == 1 and gi_layer.item_at(Vector2(30.25, 40.25)).is_empty(),
		"issue #18: an item F took off the ground is hidden at once, the other stays")
	gi_layer.queue_free()
	# Each kind flies once, from the nearest of it, with all of it that was got.
	var flights: Array = ui.flying._flights
	flights.clear()
	ui.picked(msg)
	check(flights.size() == 3 and str(flights[0][0]) == "iron-gear-wheel" and str(flights[0][1]) == "+4"
		and str(flights[1][0]) == "iron-plate" and str(flights[1][1]) == "+1" and str(flights[2][0]) == "copper-plate"
		and str(flights[2][1]) == "+2" and str(flights[0][3]) == "character" and flights[0][2] is Vector3
		and (flights[0][2] as Vector3).is_equal_approx(Vector3(488.0 / 256.0, 0.25, 10.0)),
		"issue #18: each kind F took flies to the character, from the nearest of it, with its count: %s" % [flights])
	flights.clear()
	_pick_up_stop(hud, msg)


## The owner: "when picking items off the belt seems to pickup for almost a second after you let go". F let go sends
## `pickup_stop` (the bridge kept a pickup 30 ticks after the last one; --pickup-stop=off sends nothing), and a belt
## item a `pku` names hides from the drawn belt in the belt layer's next job, as it starts flying (`hu`), not when
## the drawn clock reaches the take (--pickup-hide-now=off); belt_sim.gd's records and BeltDrawNative's alike.


func _pick_up_stop(hud: Hud, msg: Dictionary) -> void:
	var input := PlayerInput.new()
	input.hud = hud
	var was_stop: bool = input.pickup_stop
	for stop in [true, false]:
		input.pickup_stop = stop
		sent()
		Input.action_press("pick_up")
		input._update_pickup(0.2)
		input._update_pickup(0.2)
		Input.action_release("pick_up")
		input._update_pickup(0.016)
		input._update_pickup(0.016)
		var ts: Array = sent().map(func(c: Dictionary) -> String: return str(c.get("t", "")))
		if stop:
			check(ts == ["pickup", "pickup", "pickup_stop"], "pickup_stop: F's release sends pickup_stop once: %s" % [ts])
		else:
			check(ts == ["pickup", "pickup"], "pickup_stop: --pickup-stop=off sends nothing on release, as before: %s" % [ts])
	input.pickup_stop = was_stop
	# F read with exactly its modifiers (issue #26's round): Ctrl+F (search) and Alt+F (the personal roboport) held
	# send no pickup, F alone does; --pickup-exact=off picks up under them too, as before. The tree is paused while
	# the keys go in, so the HUD doesn't answer them too (Ctrl+F would open the search and take the keyboard).
	var key := func(code: int, down: bool, ctrl := false, alt := false) -> void:
		var ev := InputEventKey.new()
		ev.physical_keycode = code as Key
		ev.keycode = code as Key
		ev.pressed = down
		ev.ctrl_pressed = ctrl
		ev.alt_pressed = alt
		var was_paused := get_tree().paused
		get_tree().paused = true
		Input.parse_input_event(ev)
		Input.flush_buffered_events()
		get_tree().paused = was_paused
	var was_exact: bool = input.pickup_exact
	var typing_before: bool = hud.ui.typing()
	var states: Array = []
	for exact in [true, false]:
		input.pickup_exact = exact
		var got: Array = []
		for m in [[KEY_CTRL, true, false], [KEY_ALT, false, true], [0, false, false]]:
			if m[0] != 0:
				key.call(int(m[0]), true, m[1], m[2])
			key.call(KEY_F, true, m[1], m[2])
			states.append([Input.is_action_pressed("pick_up"), Input.is_action_pressed("pick_up", true), hud.ui.typing()])
			sent()
			input._update_pickup(0.2)
			got.append(sent().filter(func(c: Dictionary) -> bool: return c.get("t", "") == "pickup").size())
			key.call(KEY_F, false, m[1], m[2])
			if m[0] != 0:
				key.call(int(m[0]), false)
			input._update_pickup(0.2)
		if exact:
			check(got == [0, 0, 1], "pick up exact: Ctrl+F and Alt+F held send no pickup, F alone does: %s" % [got])
		else:
			check(got == [1, 1, 1], "pick up exact: --pickup-exact=off picks up under Ctrl and Alt too, as before: %s" % [got])
	input.pickup_exact = was_exact
	check(not typing_before and not hud.ui.typing(), "pick up exact: the keys reached no text box (typing before, after: %s, %s; each press's [loose, exact, typing]: %s)"
		% [typing_before, hud.ui.typing(), states])
	sent()
	input.free()
	# The hide: the gear F took (801, the game's id) at 2005 while the drawn clock is behind it.
	var was_cull: bool = BeltItemsScript.Job.view_cull
	var was_gd: bool = BeltItemsScript.State.force_gd
	var was_now: bool = PickUpScript.hide_now
	BeltItemsScript.Job.view_cull = false
	var sims := [true]
	if ClassDB.class_exists("BeltSimNative"):
		sims.append(false)
	for now in [true, false]:
		for force_gd in sims:
			BeltItemsScript.State.force_gd = force_gd
			PickUpScript.hide_now = now
			var takes: Dictionary = PickUpScript.belt_takes(msg)
			var items = BeltItemsScript.new()
			add_child(items)
			items._sync = true
			var lm: Array = []
			for u in range(1, 6):
				lm.append_array(_bs_lane(u * 8 + 1, 1, 256, 8, u + 1.0, 10.0, u, 10.0))
			_bs_feed(items, 1990, {"lm": lm, "sl": [9, 1990, 2, 801, 2, 64 + 80, 1, 804, 1, 192 + 80, 1]})
			for k in range(1991, 2000):
				_bs_feed(items, k, {}, 1)
			var shown := items.has_item(801)
			items.handle(takes)
			_bs_feed(items, 2000, {}, 1)
			var drawn: float = items._drawn
			var h: float = items.hide_of(801)
			var what := "%s, %s" % ["belt_sim.gd" if force_gd else "BeltDrawNative", "on" if now else "off"]
			if now:
				check(shown and takes.get("hu", []) == [801, 806] and drawn < 2005.0 and h >= 0.0 and h <= drawn and items.hide_of(804) < 0.0,
					"pickup_stop (%s): a belt item F took hides in the next job, before the drawn clock (%.1f) reaches the take (2005): from %.1f; the one behind not" % [what, drawn, h])
			else:
				check(not takes.has("hu") and (h < 0.0 or h > drawn),
					"pickup_stop (%s): --pickup-hide-now=off: not before the drawn clock (%.1f) reaches the take, as before: %.1f" % [what, drawn, h])
			items.queue_free()
	# A packed lane the lattice draws: F's take (no inserter) makes its hole from the drawn tick, where the item was
	# then (a moving lane's slot a step a tick further back), as an inserter's take's hole is made at its own tick;
	# an inserter's take, and F's with --pickup-hide-now=off, at the take's tick as before.
	var lat_gs := GDScript.new()
	lat_gs.source_code = "extends RefCounted\nvar v := {}\nfunc drawn_speed(key: int) -> int:\n\treturn int(v.get(key, -1))\n"
	lat_gs.reload()
	for now in [true, false]:
		PickUpScript.hide_now = now
		var job = BeltItemsScript.Job.new()
		job.state = BeltItemsScript.State.new()
		var lat = lat_gs.new()
		lat.v = {17: 0, 25: 8}
		job.state.lattice = lat
		job.fold_tick = 1990.4
		job._take_holes({"hand_why": PackedInt32Array([0, 0, 0, 0]), "hand_tick": PackedInt64Array([2005, 2005, 2005, 2005]),
			"hand_key": PackedInt64Array([17, 25, 33, 25]), "hand_pos": PackedInt32Array([100, 100, 100, 100]),
			"hand_ins": PackedInt64Array([0, 0, 0, 99])})
		var want: Array = [[17, 1990, 100], [25, 1990, 100 + 8 * 15], [33, 2005, 100], [25, 2005, 100]] if now \
			else [[17, 2005, 100], [25, 2005, 100], [33, 2005, 100], [25, 2005, 100]]
		check(job.holes == want, "pickup_stop (%s): F's takes' lattice holes from the drawn tick (a standing lane's place, a moving lane's 15 ticks back), not on a lane the lattice doesn't draw or for an inserter: %s" % ["on" if now else "off", job.holes])
	PickUpScript.hide_now = was_now
	BeltItemsScript.State.force_gd = was_gd
	BeltItemsScript.Job.view_cull = was_cull
	_pick_up_stop_edges(hud, msg)


## The owner's F case at its edges (belts-pickup-test): F tapped inside one 0.15 s repeat; F let go while a text box
## has the keyboard; and the drawn belt: how many frames a `pku`'d item stays drawn with --pickup-hide-now on and off,
## nothing the game kept hidden (a stack taken in part, `left` 1; an item no `pku` names), in every pair of
## simulation and records twins (belt_sim.gd with its records, the C++ with BeltDrawNative, the C++ with
## --belt-draw-native=off).


func _pick_up_stop_edges(hud: Hud, msg: Dictionary) -> void:
	var input := PlayerInput.new()
	input.hud = hud
	var was_stop: bool = input.pickup_stop
	input.pickup_stop = true
	sent()
	Input.action_press("pick_up")
	input._update_pickup(0.016)
	Input.action_release("pick_up")
	input._update_pickup(0.016)
	input._update_pickup(0.016)
	var ts: Array = sent().map(func(c: Dictionary) -> String: return str(c.get("t", "")))
	check(ts == ["pickup", "pickup_stop"], "pickup_stop: F tapped inside one repeat: one pickup, one stop: %s" % [ts])
	Input.action_press("pick_up")
	input._update_pickup(0.016)
	ts = sent().map(func(c: Dictionary) -> String: return str(c.get("t", "")))
	check(ts == ["pickup"], "pickup_stop: pressed again straight after the stop, it picks at once: %s" % [ts])
	# F held, then a text box takes the keyboard (F still down): the pickup stops, once.
	var box := LineEdit.new()
	hud.ui.add_child(box)
	box.grab_focus()
	input._update_pickup(0.016)
	input._update_pickup(0.2)
	var typing: bool = hud.ui.typing()
	ts = sent().map(func(c: Dictionary) -> String: return str(c.get("t", "")))
	check(typing and ts == ["pickup_stop"], "pickup_stop: F held as a text box takes the keyboard: the pickup stops, once (typing %s): %s" % [typing, ts])
	Input.action_release("pick_up")
	input._update_pickup(0.2)
	box.release_focus()
	box.queue_free()
	ts = sent().map(func(c: Dictionary) -> String: return str(c.get("t", "")))
	check(ts.is_empty(), "pickup_stop: and F let go after that sends nothing more: %s" % [ts])
	# A stop with no pickup sent (F never pressed): nothing.
	input._update_pickup(0.2)
	check(sent().is_empty(), "pickup_stop: no F, no stop")
	input.pickup_stop = was_stop
	input.free()
	# The drawn belt: 801 (gear, lane 9) and 806 (gear, lane 33) taken whole, 805 (copper, lane 25) taken in part
	# (left 1), 804 (plate, lane 9) not named.
	var was_cull: bool = BeltItemsScript.Job.view_cull
	var was_gd: bool = BeltItemsScript.State.force_gd
	var was_dn: bool = BeltItemsScript.State.draw_native
	var was_now: bool = PickUpScript.hide_now
	BeltItemsScript.Job.view_cull = false
	var twins := [[true, true]]
	if ClassDB.class_exists("BeltSimNative"):
		twins.append([false, true])
		twins.append([false, false])
	var frames_seen := {}
	for now in [true, false]:
		for tw in twins:
			BeltItemsScript.State.force_gd = tw[0]
			BeltItemsScript.State.draw_native = tw[1]
			PickUpScript.hide_now = now
			var takes: Dictionary = PickUpScript.belt_takes(msg)
			var items = BeltItemsScript.new()
			add_child(items)
			items._sync = true
			var lm: Array = []
			for u in range(1, 6):
				lm.append_array(_bs_lane(u * 8 + 1, 1, 256, 8, u + 1.0, 10.0, u, 10.0))
			_bs_feed(items, 1990, {"lm": lm, "sl": [9, 1990, 2, 801, 2, 64 + 80, 1, 804, 1, 192 + 80, 1,
				25, 1990, 1, 805, 3, 64 + 80, 3, 33, 1990, 1, 806, 2, 64 + 80, 3]})
			for k in range(1991, 2000):
				_bs_feed(items, k, {}, 1)
			var native_draw: bool = items._state.draw != null
			items.handle(takes)
			var k := 2000
			var first := -1
			var kept_ok := true
			for f in 60:
				_bs_feed(items, k, {}, 1)
				k += 1
				var h: float = items.hide_of(801)
				if first < 0 and (not items.has_item(801) or (h >= 0.0 and h <= items._drawn)):
					first = f
				# (Off the drawn belt the taken stack 805 left on its belt and the plate behind stay drawn.)
				var h4: float = items.hide_of(804)
				var h5: float = items.hide_of(805)
				if items.has_item(804) and h4 >= 0.0 and h4 <= items._drawn:
					kept_ok = false
				if items.has_item(805) and h5 >= 0.0 and h5 <= items._drawn:
					kept_ok = false
			var what := "%s sim, %s records, %s" % ["GDScript" if tw[0] else "C++", "C++" if native_draw else "GDScript",
				"on" if now else "off"]
			frames_seen[what] = first
			print("  pickup_stop edges: %s: the taken item drawn %d frame(s) after its pku" % [what, first])
			check(kept_ok, "pickup_stop (%s): nothing the game kept (a stack taken in part, an item not named) is hidden" % what)
			if now:
				check(first == 0, "pickup_stop (%s): the item F took is gone from the drawn belt in the next frame: %d" % [what, first])
			else:
				check(first > 0, "pickup_stop (%s): off, it stays drawn until the drawn clock reaches the take: %d" % [what, first])
			items.queue_free()
	PickUpScript.hide_now = was_now
	BeltItemsScript.State.force_gd = was_gd
	BeltItemsScript.State.draw_native = was_dn
	BeltItemsScript.Job.view_cull = was_cull
