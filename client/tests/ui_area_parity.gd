extends "res://tests/ui_test_base.gd"
## UI test sections: parity.

func _planners(hud: Hud, player: Node) -> void:
	var ui = hud.ui
	var m = ui.model
	var pl = ui.planners
	ui.close_all()
	player.cursor_item = ""
	ui.hand = {}
	sent()

	# --- exchange strings: one Factorio 2.1.23 wrote (export_stack), decoded and written again --------
	var decoded := BpString.decode(FACTORIO_STRING)
	check(BpString.kind(decoded) == "blueprint" and BpString.label(decoded) == "Belt to chest"
		and BpString.icons(decoded) == [["item", "transport-belt"], ["item", "iron-chest"]], "a string from Factorio decodes: label, icons")
	check(BpString.components(decoded) == [["transport-belt", 3, "entity"], ["stone-path", 2, "tile"], ["inserter", 1, "entity"],
		["iron-chest", 1, "entity"]], "its components, most first: %s" % [BpString.components(decoded)])
	var again := BpString.decode(BpString.encode(decoded))
	check(BpString._plain(again) == BpString._plain(decoded) and BpString.encode(decoded).begins_with("0e"), "and encodes back to the same record (zlib, base64, version 0)")
	check(BpString.decode("not a string").is_empty() and BpString.decode("0" + Marshalls.utf8_to_base64("x")).is_empty(), "anything else decodes to nothing")
	var trimmed := decoded.duplicate(true)
	BpString.remove_component(trimmed, "transport-belt", "entity")
	check(BpString.components(trimmed).size() == 3 and not BpString.components(trimmed).any(func(c): return c[0] == "transport-belt"),
		"taking a component out removes every one of it")

	# --- the library: add, books, move, search, keep in user:// -----------------------------------
	BpLibrary.save_path = "user://test-blueprint-library.json"
	DirAccess.remove_absolute(BpLibrary.save_path)
	pl.library.load_file()
	var lib = pl.library
	check(lib.records.is_empty(), "a fresh library is empty")
	check(pl.import_string(FACTORIO_STRING), "Import string adds a pasted Factorio string to My blueprints")
	lib.add([], m.planners.empty("blueprint_book"))
	lib.add([], BpString.empty("deconstruction_planner"))
	check(lib.records.size() == 3 and BpString.kind(lib.records[1]) == "blueprint_book", "new book and planner from the library's buttons")
	check(lib.into_book([], 0, 1) and lib.records.size() == 2 and lib.list_at([0]).size() == 1, "a blueprint dropped on a book goes in as a page")
	lib.add([0], decoded)
	check(lib.list_at([0]).size() == 2 and int(BpString.pages(lib.records[0])[1][0]) == 1, "pages are numbered in order")
	check(lib.search("chest").size() == 2 and lib.search("chest")[0][0] == [0, 0], "search finds labels inside books: %s" % [lib.search("chest").map(func(e): return e[0])])
	lib.move([], 1, 0)
	check(BpString.kind(lib.records[0]) == "deconstruction_planner", "drag moves a record")
	lib.out_of_book([1], 0)
	check(lib.records.size() == 3 and lib.list_at([1]).size() == 1, "a page dragged out of the book goes up a level")
	var reloaded := BpLibrary.new()
	check(reloaded.records.size() == 3 and BpString.label(reloaded.records[2]) == "Belt to chest", "the library is kept in user:// and read back")

	# --- the window (B): tabs, take into the cursor, open books, the game's tab ---------------------
	var ev := Controls.key_event(KEY_B)
	ev.pressed = true
	get_viewport().push_input(ev)
	await get_tree().process_frame
	check(pl.library_window.is_open() and ui.is_open(), "B opens the blueprint library")
	check(sent_one("bp_lib").size() > 0, "and asks the mod for the game's and the player's libraries")
	m.handle({"t": "bpl", "src": "game", "who": "", "l": [[1, "blueprint", "Smelter", [["item", "stone-furnace"]]]]})
	m.handle({"t": "bpl", "src": "player", "who": "owner", "l": [[1, "blueprint-book", "Trains", []], [2, "upgrade-planner", "", []]]})
	await get_tree().process_frame
	check(m.planners.game_library.size() == 1 and m.planners.player_name == "owner" and _find_button(pl.library_window, "owner's blueprints") != null,
		"a taken-over player's library gets its own tab")
	check(ui.window.side == pl.library_window and ui.window._char_caption.text == "Blueprint library",
		"the library is the right half of one window with the inventory, titled Blueprint library")
	var grid_slots: Array = pl.library_window.record_slots()
	check(grid_slots.size() == 3, "My blueprints lists its three records")
	check(_texts(pl.library_window).has("Belt to chest"), "the list view shows each record's name beside its picture")
	grid_slots[2].clicked.emit(MOUSE_BUTTON_LEFT, false)
	var written := sent_one("bp_set")
	check(written.get("i") == -1 and BpString.label(BpString.decode(str(written.get("s", "")))) == "Belt to chest",
		"clicking a record writes it into the mod's cursor stack (bp_set -1)")
	m.handle({"t": "bp_ok", "q": int(written.get("q", 0)), "i": -1, "item": "blueprint"})
	check(player.cursor_item == "blueprint" and player.cursor_slot == -1, "and holds it from there")
	player.cursor_item = ""
	grid_slots[1].clicked.emit(MOUSE_BUTTON_RIGHT, false)
	await get_tree().process_frame
	check(pl.library_window.path == [1] and pl.library_window.record_slots().size() == 1,
		"right click on a book opens it in place")
	pl.library_window._go_back()
	check(pl.library_window.path == [] and not pl.library_window._forward.disabled, "back returns from the book, forward is offered")
	pl.library_window._go_forward()
	check(pl.library_window.path == [1], "and forward goes into it again")
	pl.library_window._go_up()
	pl.library_window.view = "grid"
	pl.library_window.refresh()
	check(pl.library_window.record_slots().size() == 3 and pl.library_window.find_child("View_grid", true, false) != null,
		"the small icons view lists the same records")
	pl.library_window.view = "list"
	pl.library_window.show_tab("game")
	await get_tree().process_frame
	var game_slots: Array = pl.library_window.record_slots()
	game_slots[0].clicked.emit(MOUSE_BUTTON_LEFT, false)
	var rec := sent_one("bp_rec")
	check(rec.get("src") == "game" and rec.get("ix") == 1 and rec.get("to") == -1, "a game record goes straight into the cursor (bp_rec to -1)")
	pl.library_window.show_tab("mine")
	pl.library_window.open(false)
	check(ui.window.side == null and not ui.window.visible, "closing the library closes its window")

	# --- the mod's string in parts, and its answers ---------------------------------------------------
	var got := []
	var q: int = m.planners.export_stack(7, func(r, _t, info): got.append([r, info]))
	check(sent_one("bp_get").get("i") == 7, "bp_get asks for slot 7")
	m.handle({"t": "bp", "q": q, "part": 2, "parts": 2, "s": FACTORIO_STRING.substr(100), "item": "blueprint", "i": 7})
	check(got.is_empty(), "a string waits for all its parts")
	m.handle({"t": "bp", "q": q, "part": 1, "parts": 2, "s": FACTORIO_STRING.substr(0, 100), "item": "blueprint", "i": 7})
	check(got.size() == 1 and BpString.label(got[0][0]) == "Belt to chest" and m.planners.version == 562954249895938,
		"then decodes, and the game's version is kept for new records")
	var long_label := ""
	for i in 3000:  # digits that don't compress much
		long_label += str(hash(i))
	var big := decoded.duplicate(true)
	BpString.body(big)["label"] = long_label
	m.planners.write(0, big)
	var parts: Array = sent().filter(func(c): return c.get("t") == "bp_set")
	check(parts.size() >= 2 and parts.all(func(c): return c.has("d") and int(c["parts"]) == parts.size()), "a long string goes to the mod in parts")
	m.handle({"t": "quals", "l": [["normal", 0, 1], ["uncommon", 1, 1], ["rare", 2, 0]]})
	check(m.planners.unlocked_qualities() == ["normal", "uncommon"], "quals: the qualities the force has")
	m.handle({"t": "hist", "h": 12, "what": "blueprint"})
	check(player.remembered == [[12, "blueprint"]], "hist: the mod's undo entry goes on the player's undo list")

	# --- the blueprint window: from an inventory slot, edited, saved back ---------------------------------
	m.set_inventory_slots([["blueprint", 1], ["deconstruction-planner", 1], ["upgrade-planner", 1], ["blueprint-book", 1]], 80)
	ui.window.open_crafting(true)
	click_main(ui, 1, MOUSE_BUTTON_RIGHT)
	var get_cmd := sent_one("bp_get")
	check(get_cmd.get("i") == 1 and player.cursor_item == "", "right click on a blueprint in the inventory asks for it (no half stack picked up)")
	m.handle({"t": "bp", "q": int(get_cmd.get("q", 0)), "part": 1, "parts": 1, "s": FACTORIO_STRING, "item": "blueprint", "i": 1})
	await get_tree().process_frame
	var bw = pl.bp_window
	check(bw.is_open() and bw._title.text == "Blueprint item" and (bw._sub["caption"] as Label).text == "Belt to chest"
		and _texts(bw).has("Components ⓘ") and _texts(bw).has("Preview"),
		"its window (Blueprint item) opens with the name, components and preview")
	var comps: Array = bw.find_child("Components", true, false).get_children().filter(func(c): return c is Slot)
	check(comps.size() == 4 and comps[0].item == "transport-belt" and comps[0].count == 3, "the components show with their counts")
	comps[2].clicked.emit(MOUSE_BUTTON_LEFT, false)  # the inserter
	(bw._sub["pencil"] as Button).pressed.emit()
	check((bw._sub["edit"] as LineEdit).visible, "the pencil turns the name into a text box")
	(bw._sub["edit"] as LineEdit).text = "Edited"
	(bw._sub["edit"] as LineEdit).text_submitted.emit("Edited")
	check((bw._sub["caption"] as Label).text == "Edited", "Enter renames it")
	var belt_no := int(BpString._list(BpString.body(bw.record).get("entities"))[0].get("entity_number", 0))
	bw.preview_clicked(belt_no, MOUSE_BUTTON_RIGHT)
	check(bw.removed.has(belt_no) and BpString.components(bw.result())[0][1] == 2, "right click in the preview removes an entity")
	bw.preview_clicked(belt_no, MOUSE_BUTTON_LEFT)
	check(not bw.removed.has(belt_no), "left click restores it")
	(bw.find_child("SnapToGrid", true, false) as CheckBox).button_pressed = true
	(bw.find_child("SnapX", true, false) as LineEdit).text = "6"
	(bw.find_child("SnapX", true, false) as LineEdit).text_changed.emit("6")
	(bw.find_child("AbsoluteSnapping", true, false) as CheckBox).button_pressed = true
	await get_tree().process_frame
	(bw.find_child("Save", true, false) as Button).pressed.emit()
	var saved := sent_one("bp_set")
	var out := BpString.decode(str(saved.get("s", "")))
	var body: Dictionary = BpString._plain(BpString.body(out))
	check(saved.get("i") == 1 and BpString.label(out) == "Edited" and not BpString.components(out).any(func(c): return c[0] == "inserter")
		and body.get("snap-to-grid") == {"x": 6, "y": 1} and body.get("absolute-snapping") == true,
		"Save writes it back to its slot: label, a component taken out, snap to grid, absolute snapping: %s" % [body.keys()])
	check(not bw.is_open(), "and closes the window")

	# --- the book window: pages, the active one, reorder, open a page --------------------------------------
	var book: Dictionary = m.planners.empty("blueprint_book")
	var page_b := decoded.duplicate(true)
	BpString.body(page_b)["label"] = "Second"
	BpString.set_pages(book, [decoded, page_b])
	pl.edit(book, {"kind": "slot", "slot": 4})
	await get_tree().process_frame
	var bk = pl.book_window
	var pages: Array = _slots_named(bk, "Page")
	check(bk.is_open() and ui.window.side == bk and ui.window._char_caption.text == "Blueprint book" and pages.size() == 2 and pages[0].marked,
		"a book is the right half of one window with the inventory, its pages listed, the active one framed")
	check(_texts(bk).has("Second") and bk.find_child("AddPage", true, false) != null, "each page with its name, and an empty slot to add one")
	bk._page_dropped(1, bk._owner, 0)
	check(BpString.label(BpString.pages(bk.record)[0][1]) == "Second", "dragging a page reorders the book")
	pages = _slots_named(bk, "Page")
	pages[1].clicked.emit(MOUSE_BUTTON_RIGHT, false)
	check(bw.is_open() and bk.is_open() and str(bw.source.get("kind")) == "page" and (bw._sub["caption"] as Label).text == "Belt to chest",
		"right click opens a page in the blueprint window, over the book")
	bw._set_label("Page edited")
	(bw.find_child("Save", true, false) as Button).pressed.emit()
	check(not bw.is_open() and BpString.label(BpString.pages(bk.record)[1][1]) == "Page edited", "saving the page puts it back into the book")
	check(sent_one("bp_set").is_empty(), "the book isn't written while it is open")
	bk.view = "slots"
	bk._show()
	check(_slots_named(bk, "Page").size() == 2, "the large icons view shows the same pages")
	ui.close_all()
	check(sent_one("bp_set").get("i") == 4 and ui.window.side == null, "closing the book writes it to its slot, as Factorio keeps every change")
	# A click on a page takes it out of the book into the cursor; the active page stays the same page.
	var book2: Dictionary = m.planners.empty("blueprint_book")
	BpString.set_pages(book2, [decoded, page_b])
	BpString.body(book2)["active_index"] = 1
	pl.edit(book2, {"kind": "slot", "slot": 4})
	await get_tree().process_frame
	sent()
	_slots_named(bk, "Page")[0].clicked.emit(MOUSE_BUTTON_LEFT, false)
	var writes: Array = sent().filter(func(c): return c.get("t") == "bp_set")
	check(BpString.pages(bk.record).size() == 1 and BpString.label(BpString.pages(bk.record)[0][1]) == "Second"
		and int(BpString.body(bk.record)["active_index"]) == 0 and writes.any(func(c): return c.get("i") == 4)
		and writes.any(func(c): return c.get("i") == -1 and BpString.label(BpString.decode(str(c.get("s", "")))) == "Belt to chest"),
		"click on a page: the book loses it at once and the cursor gets it; the active page stays \"Second\"")
	# The book's upgrade button: an upgrade planner's mappings applied to every page.
	var planner := {"upgrade_planner": {"item": "upgrade-planner", "settings": {"mappers": [
		{"index": 0, "from": {"type": "entity", "name": "transport-belt"}, "to": {"type": "entity", "name": "fast-transport-belt"}}]}}}
	var changed: int = bk.apply_upgrade(planner)
	check(changed > 0 and BpString.components(BpString.pages(bk.record)[0][1]).any(func(c): return c[0] == "fast-transport-belt"),
		"the book's upgrade button maps every page's entities (%d)" % changed)
	# The blueprint window's header: Factorio's six buttons; select new contents, upgrade.
	pl.edit(decoded, {"kind": "slot", "slot": 1})
	await get_tree().process_frame
	check(bw.find_child("ReselectButton", true, false) != null and bw.find_child("UpgradeButton", true, false) != null
		and (bw.find_child("ParametriseButton", true, false) as Button).disabled and bw.find_child("DeleteButton", true, false) != null
		and _find_checkbox(bw, "Tiles") == null, "the blueprint window's header has Factorio's six buttons (parametrise can't be used), and no Include section")
	bw.apply_upgrade(planner)
	check(BpString.components(bw.result()).any(func(c): return c[0] == "fast-transport-belt"), "upgrade: the planner's mappings applied to the blueprint")
	(bw.find_child("ReselectButton", true, false) as Button).pressed.emit()
	check(not bw.is_open() and player.cursor_tool == "blueprint" and player.reselect_slot == 1, "select new contents: the blueprint tool, aimed at this blueprint")
	m.handle({"t": "bp_ok", "q": 0, "i": 1, "item": "blueprint", "new": 1})
	check(sent_one("bp_get").get("i") == 1, "and when the mod has filled it, its window opens again")
	player.cursor_tool = ""
	ui.close_all()
	# Import string and a new book are on the shortcut bar, as in Factorio (not in the library).
	check(ui.shortcuts._buttons.has("import") and ui.shortcuts._buttons.has("book") and pl.library_window.find_child("ImportString", true, false) == null,
		"Import string and New blueprint book are shortcut bar buttons; the library has no buttons of its own")
	sent()
	ui._on_shortcut("book")
	var nb := sent_one("bp_set")
	check(nb.get("i") == -1 and BpString.kind(BpString.decode(str(nb.get("s", "")))) == "blueprint_book", "the book shortcut puts a new book in the cursor")
	ui._on_shortcut("import")
	check(pl._string_box.visible and pl._string_mode == "import", "the import shortcut opens the string box")
	pl._string_text.text = FACTORIO_STRING
	pl._on_string_ok()
	var imp := sent_one("bp_set")
	check(imp.get("i") == -1 and BpString.label(BpString.decode(str(imp.get("s", "")))) == "Belt to chest", "Import puts the blueprint in the cursor, as Factorio does")

	# --- the deconstruction and upgrade planners ------------------------------------------------------------
	var pw = pl.planner_window
	pl.edit(BpString.empty("deconstruction_planner"), {"kind": "slot", "slot": 2})
	await get_tree().process_frame
	check(pw.is_open() and ui.window.side == pw and ui.window._char_caption.text == "Deconstruction planner"
		and pw._title.text == "Deconstruction planner" and pw.find_child("EntityFilters", true, false).get_child_count() == 30,
		"the deconstruction planner joins the inventory: its Entities tab has 30 filters")
	check(_texts(pw).has("Trees/rocks only") and _find_button(pw, "Whitelist") != null and _find_button(pw, "Tiles") != null,
		"Trees/rocks only, the Whitelist / Blacklist switch and the Tiles tab")
	pw.set_filter("entity_filters", 0, "wooden-chest")
	pw.set_filter("entity_filters", 3, "iron-chest")
	# Factorio's filters are entity and tile prototypes, not items: the choosers list those (an item like iron-plate has no entity).
	pw._filter_clicked("entity_filters", 5, MOUSE_BUTTON_LEFT)
	var entity_kinds: Array = pw.picker._kinds.duplicate()
	pw.picker.close()
	_find_button(pw, "Blacklist").pressed.emit()
	await get_tree().process_frame
	(pw.find_child("Tab_tiles", true, false) as Button).pressed.emit()
	check(pw.find_child("TileFilters", true, false) != null and pw.find_child("EntityFilters", true, false) == null, "the Tiles tab: tile filters")
	pw._filter_clicked("tile_filters", 5, MOUSE_BUTTON_LEFT)
	check(entity_kinds == ["map_entity"] and pw.picker._kinds == ["tile"], "the filter choosers list entities and tiles, not items: %s, %s" % [entity_kinds, pw.picker._kinds])
	pw.picker.close()
	(pw.find_child("TileSelectionMode", true, false) as OptionButton).item_selected.emit(3)
	check(sent_one("bp_set").is_empty(), "nothing is written while the window is open")
	pw.close()
	var st: Dictionary = BpString._plain(BpString.body(BpString.decode(str(sent_one("bp_set").get("s", ""))))["settings"])
	check(st.get("entity_filters") == [{"name": "wooden-chest", "index": 0}, {"name": "iron-chest", "index": 3}]
		and st.get("entity_filter_mode") == 1 and st.get("tile_selection_mode") == 3,
		"closing it writes the filters (0-based, as 2.x writes them), blacklist and tile mode: %s" % [st])
	check(ui.window.side == null, "and takes it out of the window")
	pl.edit(BpString.empty("upgrade_planner"), {"kind": "slot", "slot": 3})
	await get_tree().process_frame
	check(pw._title.text == "Upgrade planner" and _texts(pw).count("From") == 4 and pw.find_child("Mapper15_from", true, false) != null
		and pw.find_child("Mapper16_from", true, false) == null, "an empty upgrade planner: four From / To pairs, four rows")
	pw.set_mapper(0, "from", "transport-belt")
	pw.set_mapper(0, "to", "fast-transport-belt")
	pw.set_mapper(15, "from", "inserter")
	check(pw.find_child("Mapper16_from", true, false) != null, "filling the last row adds the next")
	ui.close_all()
	st = BpString._plain(BpString.body(BpString.decode(str(sent_one("bp_set").get("s", ""))))["settings"])
	check((st.get("mappers") as Array).size() == 2 and st.get("mappers")[0] == {"index": 0, "from": {"type": "entity", "name": "transport-belt"}, "to": {"type": "entity", "name": "fast-transport-belt"}},
		"the mapper rules are written when it closes: %s" % [st.get("mappers")])

	# --- Alt+B's area: the new blueprint's window opens; the upgrade shortcut gives a new planner ------------
	m.handle({"t": "bp_ok", "q": 0, "i": 5, "item": "blueprint", "new": 1})
	check(sent_one("bp_get").get("i") == 5, "a blueprint made from an area opens its window (asks for it)")
	ui.close_all()
	m.set_inventory_slots([], 80)
	ui._on_shortcut("upgrade")
	var up := sent_one("bp_set")
	check(up.get("i") == -1 and BpString.kind(BpString.decode(str(up.get("s", "")))) == "upgrade_planner",
		"the upgrade planner shortcut without one gives a new one in the cursor")

	# --- player_input: which stack, undo entries, quality, the selection highlight, book pages ---------------
	var world := WorldMirror.new()
	world.protos.add_entities([
		[1, "wooden-chest", "container", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[2, "tree-01", "tree", -0.4, -0.4, 0.4, 0.4, 40, 110, 40, 1, 1],
		[3, "transport-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[4, "assembling-machine-1", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 200, 200, 200, 3, 3],
		[5, "small-electric-pole", "electric-pole", -0.5, -0.5, 0.5, 0.5, 150, 100, 50, 1, 1],
		[6, "big-electric-pole", "electric-pole", -1.0, -1.0, 1.0, 1.0, 150, 100, 50, 2, 2],
	])
	world.chunks[Vector2i.ZERO] = ChunkView.new()
	world._add([70, 1, 2 * 256 + 128, 2 * 256 + 128, 0])
	world._add([0, 2, 3 * 256 + 128, 2 * 256 + 128, 0])
	world._add([71, 3, 4 * 256 + 128, 2 * 256 + 128, 0, {"d": 1}])
	world._add([72, 4, 8 * 256 + 128, 2 * 256 + 128, 0])
	world._add([73, 5, 3 * 256 + 128, 8 * 256 + 128, 0])
	world._add([74, 6, 25 * 256 + 128, 8 * 256 + 128, 0])
	var input := PlayerInput.new()
	input.world = world
	input.hud = hud
	# The build reach is the character's own (cinfo's build: research and other mods add to it).
	var info_before: Dictionary = hud.ui.model.character_info.duplicate()
	hud.ui.model.character_info = {"build": 250}
	check(is_equal_approx(input.build_reach(), 25.0), "a far-reach bonus (cinfo build 250) gives 25 tiles of build reach")
	hud.ui.model.character_info = {}
	check(is_equal_approx(input.build_reach(), 10.0), "without cinfo yet: Factorio's base 10 tiles")
	hud.ui.model.character_info = info_before
	input.hold("deconstruction-planner", -1)
	check(input.planner_slot() == -1 and sent_one("bp_get").get("i") == -1, "a planner held from the library is slot -1; its settings are fetched")
	var area := Rect2(1, 1, 5, 3)
	check(input.selected_by("decon", area, false).size() == 3, "a planner without filters takes everything in the box")
	pl.held_record = {"deconstruction_planner": {"settings": {"trees_and_rocks_only": true}}}
	check(input.selected_by("decon", area, false).map(func(e): return e.proto_id) == [2], "trees and rocks only: the tree")
	pl.held_record = {"deconstruction_planner": {"settings": {"entity_filters": [{"name": "wooden-chest", "index": 0}]}}}
	check(input.selected_by("decon", area, false).map(func(e): return e.proto_id) == [1], "a whitelist: the chest")
	check(input.selected_by("decon", area, true).map(func(e): return e.proto_id) == [3], "Shift (cancel): what is marked")
	pl.held_record = {"upgrade_planner": {"settings": {"mappers": [{"from": {"type": "entity", "name": "transport-belt"}, "index": 0}]}}}
	check(input.selected_by("upgrade", area, false).map(func(e): return e.proto_id) == [3], "an upgrade planner: what it maps")
	check(input.selected_by("blueprint", area, false).map(func(e): return e.proto_id).has(1)
		and not input.selected_by("blueprint", area, false).map(func(e): return e.proto_id).has(2), "a blueprint selection: buildings, not trees")
	# What the game takes (live-checked: tools/live_check.py --only plannerdiff): the selection box overlapping the area, a 3x3
	# machine whose middle is outside it, and a click on a point. (An upgrade planner with no mappings upgrades everything with a
	# next tier in the game, so it keeps highlighting everything.)
	pl.held_record = {"deconstruction_planner": {"settings": {}}}
	check(input.selected_by("decon", Rect2(6.5, 1, 1, 3), false).map(func(e): return e.proto_id) == [4]
		and input.selected_by("decon", Rect2(8.4, 2.4, 0, 0), false).map(func(e): return e.proto_id) == [4]
		and input.selected_by("decon", Rect2(6.0, 1, 0.5, 3), false).is_empty(),
		"a planner's box takes what it overlaps, not only what has its middle inside: a 3x3 machine at its edge, a click on a point")
	# A held pole's wires go to the poles within the shorter of the two reaches: a big pole (30) held 8.5 tiles from a small
	# one (7.5) wires only the big pole at 13.5, not the small one.
	var eprops_was: Dictionary = m.eprops.duplicate()
	m.eprops[5] = {"under": 0.0, "wire": 7.5, "supply": 2.5, "x": {}}
	m.eprops[6] = {"under": 0.0, "wire": 30.0, "supply": 2.0, "x": {}}
	input._update_reach(world.protos.entity(6), Vector2(11.5, 8.5))
	var big_lines: int = (input._reach_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	input._update_reach(world.protos.entity(5), Vector2(8.5, 8.5))
	var small_lines: int = (input._reach_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	check(big_lines == 2 and small_lines == 2, "a pole's build preview wires only to poles within both reaches (vertices: big pole %d, small pole %d)" % [big_lines, small_lines])
	m.eprops = eprops_was
	input.hold("wooden-chest")
	input.cycle_quality(1)
	check(input.cursor_quality == "uncommon", "Ctrl+wheel: the next quality the force has")
	input.cycle_quality(1)
	check(input.cursor_quality == "uncommon", "and no further than it has")
	input.hold("transport-belt")
	check(input.cursor_quality == "normal", "another item starts at normal")
	input.remember_mod(40, "deconstruction")
	sent()
	input.undo()
	check(sent_one("undo").get("h") == 40, "Ctrl+Z on a mod entry sends undo with its id")
	input.redo()
	check(sent_one("redo").get("h") == 40, "Ctrl+Y redo")
	input._remember({"do": "build", "item": "wooden-chest", "x": 2.5, "y": 2.5, "d": 0})
	input.undo()
	check(sent_one("decon").get("nh") == 1, "undoing a build marks it with nh, so the mod doesn't remember the undo itself")
	input.hold("blueprint-book", -1)
	pl.held_record = book
	BpString.body(pl.held_record)["active_index"] = 0
	sent()
	input._cycle_book(1)
	check(sent_one("bp_page").get("a") == 2 and int(BpString.body(pl.held_record)["active_index"]) == 1, "Shift+wheel: the book's next page")
	input._cycle_book(1)
	check(sent_one("bp_page").get("a") == 1, "round to the first again")
	# Factorio's selection colours (item.lua's border_color): select, Shift, right-drag.
	check(PlayerInput.selection_color("decon", false) == Color8(255, 24, 24) and PlayerInput.selection_color("decon", true) == Color8(239, 153, 34)
		and PlayerInput.selection_color("upgrade", false) == Color8(71, 255, 73) and PlayerInput.selection_color("upgrade", false, true) == Color8(246, 255, 0)
		and PlayerInput.selection_color("blueprint", false) == Color8(57, 156, 251) and PlayerInput.selection_color("copy", false) == Color(1, 1, 1),
		"selection boxes in Factorio's colours: deconstruct red, cancel orange, upgrade green, downgrade yellow, blueprint blue, copy white")
	# Owner's #21: the copied buildings follow the mouse where Factorio pastes them. A clipboard real
	# Factorio 2.1.23 sent (three chests and an assembler) and where its paste put them.
	world.protos.add_entities([[4, "assembling-machine-1", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3]])
	var clip := [{"p": 1, "at": Vector2(-3, -1), "d": 0}, {"p": 1, "at": Vector2(-2, -1), "d": 0},
		{"p": 1, "at": Vector2(-1, -1), "d": 0}, {"p": 4, "at": Vector2(2, 0), "d": 0}]
	for c in [[Vector2(20.3, 20.6), 0, [Vector2(17.5, 19.5), Vector2(22.5, 20.5)]], [Vector2(40.7, 20.2), 0, [Vector2(37.5, 19.5), Vector2(42.5, 20.5)]],
			[Vector2(60.2, 20.9), 4, [Vector2(61.5, 17.5), Vector2(60.5, 22.5)]]]:
		input.ground = c[0]
		input.build_dir = c[1]
		var centre := input._paste_centre(clip[0], c[1] / 4)
		var first: Vector2 = clip[0]["at"]
		var asm: Vector2 = clip[3]["at"]
		if c[1] == 4:
			first = Vector2(-first.y, first.x)
			asm = Vector2(-asm.y, asm.x)
		check((centre + first).is_equal_approx(c[2][0]) and (centre + asm).is_equal_approx(c[2][1]),
			"pasting at %s turned %d: the preview's chest and assembler where Factorio puts them: %s %s" % [c[0], c[1], centre + first, centre + asm])
	input.build_dir = 0
	input._box_edges()
	check(input._drag_box.mesh == null and input._drag_box.get_child_count() == 4, "the selection box is only its border (four edges), as Factorio draws it")
	# A held blueprint: placed as the button goes down, with Factorio's build modes, and again along a drag.
	input.hold("blueprint", 1)
	pl.held_slot = 1
	pl.held_record = decoded.duplicate(true)
	sent()
	input.place_blueprint(Vector2(10, 5), 1)
	var bpc := sent_one("blueprint")
	check(bpc.get("bm") == 1 and bpc.get("i") == 1 and bpc.get("x") == 2560 and not bpc.has("sf"), "Shift+click places it forced (bm 1)")
	input.place_blueprint(Vector2(10, 5), 2)
	check(sent_one("blueprint").get("sf") == 1, "Ctrl+Shift+click super-forced")
	var step: Vector2i = pl.held_step(world.protos, 0)
	check(step.x >= 1 and step.y >= 1, "the blueprint's drag step is its size: %s" % [step])
	input._lmb_down = true
	input.has_ground = true
	input._bp_mode = 0
	input._bp_axis = Vector2.ZERO
	input._bp_last = Vector2(10, 5)
	input.ground = Vector2(10 + step.x * 2.2, 5.2)
	input._update_blueprint_drag()
	var placed: Array = sent().filter(func(c): return c.get("t") == "blueprint")
	check(placed.size() == 2 and placed[0].get("x") == int((10 + step.x) * 256) and placed[1].get("x") == int((10 + step.x * 2) * 256)
		and placed[0].get("y") == 5 * 256 and placed[0].get("bm") == 0, "dragging places it again every step along the drag: %s" % [placed])
	input._lmb_down = false
	input._bp_last = Vector2.INF
	# The upgrade planner's right-drag downgrades.
	input.hold("upgrade-planner", 3)
	input._reverse_from = Vector2(1, 1)
	input.ground = Vector2(6, 4)
	input._use_planner(false, true)
	var down := sent_one("upgrade")
	check(down.get("down") == 1 and down.get("i") == 3 and down.get("x1") == 256 and down.get("cancel") == 0, "right-drag with an upgrade planner: downgrade (down 1)")
	input._reverse_from = Vector2.INF
	input.has_ground = false
	# The red delete button destroys an inventory planner (bp_del).
	pl.edit(BpString.empty("deconstruction_planner"), {"kind": "slot", "slot": 2})
	(pw.find_child("DeleteButton", true, false) as Button).pressed.emit()
	check(sent_one("bp_del").get("i") == 2 and not pw.is_open(), "the planner's delete button destroys it (bp_del) and closes the window")

	# --- Other #2: Saving Ctrl+C clipboard as blueprint into inventory, library, and books ----------
	player.cursor_item = ""
	player.cursor_slot = 0
	player.cursor_tool = "paste"
	check(pl.cursor_slot() == -2, "Other #2: PlannerUi.cursor_slot() returns -2 when cursor_tool == 'paste'")
	player.cursor_tool = "blueprint"
	check(pl.cursor_slot() == 0, "Other #2: PlannerUi.cursor_slot() returns 0 for non-paste tools")
	# Clicking an empty main inventory slot while holding clipboard saves clipboard to that slot (bp_get i=-2, to=slot).
	player.cursor_tool = "paste"
	ui.hand = {}
	sent()
	ui.window.open_crafting(true)
	click_main(ui, 12, MOUSE_BUTTON_LEFT)
	var clip_save := sent_one("bp_get")
	check(int(clip_save.get("i", 0)) == -2 and int(clip_save.get("to", -99)) == 12 and player.cursor_tool == "",
		"Other #2: clicking empty main slot 12 with clipboard sends bp_get(i=-2, to=12) and clears cursor_tool: %s" % [clip_save])
	# Direct save_clipboard(0) requests first empty slot.
	player.cursor_tool = "paste"
	sent()
	var saved_ok: bool = pl.save_clipboard(0)
	var clip_save0 := sent_one("bp_get")
	check(saved_ok and int(clip_save0.get("i", 0)) == -2 and int(clip_save0.get("to", -99)) == 0 and player.cursor_tool == "",
		"Other #2: save_clipboard(0) sends bp_get(i=-2, to=0) and drops cursor_tool: %s" % [clip_save0])
	# Adding clipboard into blueprint library via add_held([]).
	var lib_before: int = lib.records.size()
	player.cursor_tool = "paste"
	sent()
	pl.add_held([])
	var clip_lib_get := sent_one("bp_get")
	check(int(clip_lib_get.get("i", 0)) == -2 and not clip_lib_get.has("to"),
		"Other #2: add_held([]) with clipboard exports slot -2: %s" % [clip_lib_get])
	m.handle({"t": "bp", "q": int(clip_lib_get.get("q", 0)), "part": 1, "parts": 1, "s": FACTORIO_STRING, "item": "blueprint", "i": -2})
	check(lib.records.size() == lib_before + 1 and player.cursor_tool == "",
		"Other #2: clipboard exported into library adds blueprint (%d -> %d) and clears cursor_tool" % [lib_before, lib.records.size()])
	# Adding clipboard as a page into an open blueprint book via _add_held_page().
	var clip_book: Dictionary = m.planners.empty("blueprint_book")
	pl.edit(clip_book, {"kind": "slot", "slot": 4})
	await get_tree().process_frame
	player.cursor_tool = "paste"
	sent()
	pl._add_held_page()
	var clip_page_get := sent_one("bp_get")
	check(int(clip_page_get.get("i", 0)) == -2, "Other #2: _add_held_page() with clipboard exports slot -2: %s" % [clip_page_get])
	m.handle({"t": "bp", "q": int(clip_page_get.get("q", 0)), "part": 1, "parts": 1, "s": FACTORIO_STRING, "item": "blueprint", "i": -2})
	check(BpString.pages(bk.record).size() == 1 and player.cursor_tool == "",
		"Other #2: clipboard added as book page (pages=%d) and clears cursor_tool" % BpString.pages(bk.record).size())
	# Must-fix #3: stale non-empty hand + cursor_item='blueprint' + cursor_tool='paste' still saves clipboard to empty main slot.
	player.cursor_item = "blueprint"
	player.cursor_tool = "paste"
	ui.hand = {"role": "main", "index": 1, "n": 1, "unit": 0}
	ui._check_hand("blueprint")
	var hand_cleared: bool = ui.hand.is_empty()
	ui.hand = {"role": "main", "index": 1, "n": 1, "unit": 0}
	sent()
	click_main(ui, 12, MOUSE_BUTTON_LEFT)
	var clip_stale_save := sent_one("bp_get")
	var clip_stale_move := sent_one("move")
	check(hand_cleared and int(clip_stale_save.get("i", 0)) == -2 and int(clip_stale_save.get("to", -99)) == 12
		and clip_stale_move.is_empty() and player.cursor_tool == "",
		"Other #2: non-empty hand clears under cursor_tool and empty-slot click saves clipboard instead of move: save=%s move=%s" % [
			clip_stale_save, clip_stale_move])
	ui.close_all()
	sent()

	input.hold("")
	input.free()
	world.chunks[Vector2i.ZERO].free()
	world.free()
	ui.close_all()
	DirAccess.remove_absolute(BpLibrary.save_path)


## Factorio parity: the controls, windows and entity screens added for it.


func _parity(hud: Hud, player: Node) -> void:
	var ui = hud.ui
	var m = ui.model
	ui.close_all()
	player.cursor_item = ""
	ui.hand = {}
	sent()

	# --- controls: InputMap actions with modifiers, exact matching, rebinding ------------------
	var shift_r := Controls.key_event(KEY_R | KEY_MASK_SHIFT)
	shift_r.pressed = true
	var plain_r := Controls.key_event(KEY_R)
	plain_r.pressed = true
	check(Controls.pressed(shift_r, "reverse_rotate") and not Controls.pressed(shift_r, "rotate") and Controls.pressed(plain_r, "rotate"),
		"R and Shift+R are different controls")
	var ctrl_c := Controls.key_event(KEY_C | KEY_MASK_CTRL)
	ctrl_c.pressed = true
	check(Controls.pressed(ctrl_c, "copy") and not Controls.pressed(ctrl_c, "shoot_cursor"), "Ctrl+C copies, it doesn't shoot")
	# Stored in the settings as text ("Ctrl+Shift+V") and read back from it (settings.gd bind / keys_for).
	var ctrl_shift_v := KEY_V | KEY_MASK_CTRL | KEY_MASK_SHIFT
	# A test action of its own (add-ons' way in), so no real control's binding changes.
	Settings.add_action("ui_test_binding", [KEY_F12, 0])
	Settings.bind_slot("ui_test_binding", 1, ctrl_shift_v)
	var test_keys := Settings.keys_for("ui_test_binding")
	Settings.bind("ui_test_binding", [])
	# Gone again, or _help (run after) finds a bound control the help doesn't name.
	Settings.remove_action("ui_test_binding")
	check(test_keys == [KEY_F12, ctrl_shift_v], "a binding with modifiers survives being saved as text: %s" % [test_keys])
	check(ControlsInfo.name_of("drop_item") == "Drop item" and ControlsInfo.group_of("quickbar_page_3") == "Quickbar"
		and ControlsInfo.name_of("give_blueprint") == "Blueprint",
		"actions carry Factorio's names for the Controls tab")
	# The add-on author's reload key exists only while --addons is given (Settings.apply_bindings drops it otherwise).
	var unnamed: Array = ControlsInfo.ACTIONS.keys().filter(func(a: String) -> bool: return not InputMap.has_action(a) and not Controls.ADDON_AUTHOR_ONLY.has(a))
	check(unnamed.is_empty() and ControlsInfo.group_of("toggle_factoriopedia") == "Panels",
		"every action the Controls tab names exists (F2 under Panels): %s" % [unnamed])

	# --- quickbar pages (Shift+1-0, X) ------------------------------------------------------------
	var qb_swap: Array = []
	qb_swap.resize(100)
	qb_swap.fill("")
	qb_swap[12] = "iron-chest"
	qb_swap[21] = "wooden-chest"
	qb_swap[60] = "transport-belt"
	m.handle({"t": "qb", "p": 2, "sel": 0, "held": "", "l": qb_swap})
	sent()
	key(KEY_3, true)
	await get_tree().process_frame
	check(sent_one("qb_page").get("p") == 3 and m.quickbar_page == 3 and str(ui.quickbar._pages[1].text) == "3",
		"Shift+3 shows quickbar page 3")
	ui.quickbar.open_chooser(0, true)
	ui.quickbar.pick_page(7)
	player.cursor_item = "transport-belt"
	await get_tree().process_frame
	check(m.quickbar_upper_page() == 7 and m.quickbar_page == 3
		and str(ui.quickbar._pages[0].text) == "7" and str(ui.quickbar._pages[1].text) == "3"
		and ui.quickbar._second[0].item == "transport-belt" and ui.quickbar._slots[1].item == "wooden-chest"
		and ui.quickbar._second[0].button_pressed and not ui.quickbar._slots[0].button_pressed,
		"the two quickbar rows show pages 7 (upper) and 3 (lower)")
	ui.quickbar.open_chooser(1, true)
	check(ui.quickbar._pages[1].button_pressed and (ui.quickbar._chooser_pages[3] as Button).button_pressed
		and not (ui.quickbar._chooser_pages[7] as Button).button_pressed,
		"the open chooser highlights the row's page button")
	key(KEY_X)
	await get_tree().process_frame
	check(sent_one("qb_page").get("p") == 7 and m.quickbar_page == 7 and m.quickbar_upper_page() == 3
		and str(ui.quickbar._pages[0].text) == "3" and str(ui.quickbar._pages[1].text) == "7"
		and ui.quickbar._slots[0].item == "transport-belt" and ui.quickbar._second[1].item == "wooden-chest"
		and ui.quickbar._slots[0].button_pressed and not ui.quickbar._second[0].button_pressed,
		"X swaps the two active quickbar rows")
	check(ui.quickbar._pages[1].button_pressed and (ui.quickbar._chooser_pages[7] as Button).button_pressed
		and not (ui.quickbar._chooser_pages[3] as Button).button_pressed,
		"and the highlighted page button follows")
	ui.quickbar.open_chooser(0, true)
	check(ui.quickbar._pages[0].button_pressed and (ui.quickbar._chooser_pages[3] as Button).button_pressed,
		"the second row's chooser highlights its swapped page")
	key(KEY_X)
	await get_tree().process_frame
	check(sent_one("qb_page").get("p") == 3 and m.quickbar_page == 3 and m.quickbar_upper_page() == 7
		and str(ui.quickbar._pages[0].text) == "7" and str(ui.quickbar._pages[1].text) == "3"
		and (ui.quickbar._chooser_pages[7] as Button).button_pressed
		and not (ui.quickbar._chooser_pages[3] as Button).button_pressed,
		"X again swaps the two rows back and the chooser highlight follows")
	ui.quickbar.open_chooser(0, false)
	player.cursor_item = ""
	await get_tree().process_frame
	PlayerInput.define_actions()
	Settings.apply_bindings()
	Settings.bind_slot("rotate_quickbars", 0, KEY_Y)
	key(KEY_X)
	await get_tree().process_frame
	check(m.quickbar_page == 3 and m.quickbar_upper_page() == 7 and sent().is_empty(),
		"once rotate_quickbars is rebound, X no longer swaps")
	key(KEY_Y)
	await get_tree().process_frame
	check(sent_one("qb_page").get("p") == 7 and m.quickbar_page == 7 and m.quickbar_upper_page() == 3,
		"the rebound rotate_quickbars key swaps the two rows")
	Settings.bind("rotate_quickbars", [])
	check(Settings.keys_for("rotate_quickbars") == [KEY_X, 0], "rotate_quickbars binding restored to default")
	qb_swap[21] = ""
	qb_swap[60] = ""
	m.quickbar_upper = 0
	m.handle({"t": "qb", "p": 2, "sel": 0, "held": "", "l": qb_swap})
	sent()

	# --- statistics (P, K), chat (`, /), research progress, Alt-mode --------------------------
	key(KEY_P)
	await get_tree().process_frame
	var st := sent_one("stats")
	check(ui.stats.is_open() and st.get("kind") == "item" and st.get("prec") == 1, "P opens production statistics on 5s and asks for them")
	m.handle({"t": "stats", "kind": "item", "prec": 1, "l": [["iron-plate", 42.0, 11.5, 2520, 690]]})
	await get_tree().process_frame
	check(_texts(ui.stats).has("42/m") and _texts(ui.stats).has("11.5/m"), "the rows show the rates per minute: %s" % [_texts(ui.stats)])
	key(KEY_K)
	await get_tree().process_frame
	check(ui.stats.is_open() and ui.stats.kind == "kill" and sent_one("stats").get("kind") == "kill" and ui.stats._tabs.visible
		and (ui.stats._tabs.get_child(4) as Button).button_pressed, "K switches to the production window's Kills tab")
	key(KEY_ESCAPE)
	await get_tree().process_frame
	check(not ui.stats.is_open(), "Esc closes statistics")
	key(KEY_SLASH)
	await get_tree().process_frame
	check(ui.chat.is_open() and ui.typing(), "/ opens the console line, which takes the keys")
	ui.chat._submit("hello factory")
	check(sent_one("chat").get("text") == "hello factory", "Enter says it in the game's chat")
	check(not ui.chat.is_open(), "and closes the line")
	m.handle({"t": "chat", "from": "Player", "text": "hi 3D"})
	await get_tree().process_frame
	ui.chat._refresh()
	check(_texts(ui.chat).has("Player: hi 3D"), "the game's chat shows: %s" % [_texts(ui.chat)])
	m.handle({"t": "rs", "cur": "automation", "pr": 500, "q": []})
	check(ui.research_hud.visible and _texts(ui.research_hud).size() > 0, "the research in progress shows (top right, in the side menu)")
	ui.set_alt_mode(true)
	var alt_turn: int = Bridge.alt_contents
	check(sent_one("alt").is_empty() and ui.alt_overlay.on and alt_turn > 0,
		"Alt-mode on asks the mod for no icons (they come with the records, #9), only the chests' contents (altc, J6)")
	ui.set_alt_mode(false)
	ui.set_alt_mode(true)
	check(Bridge.alt_contents > alt_turn, "J6: each turning on of Alt-mode is a new one for the chests' contents")
	ui.set_alt_mode(false)
	check(not ui.alt_overlay.on and Bridge.alt_contents == 0, "and goes off")
	# Settings > Interface > Alt-mode switches it in the game too (it only saved the setting before).
	Settings.set_value("interface", "alt_mode", true)
	check(ui.alt_mode and ui.alt_overlay.on, "the Alt-mode setting turns Alt-mode on in the game")
	Settings.set_value("interface", "alt_mode", false)
	check(not ui.alt_mode and not ui.alt_overlay.on and Settings.get_value("interface", "alt_mode") == false, "and off")
	m.handle({"t": "clip", "l": [[5, 256, -512, 4]]})
	check(m.clipboard.size() == 1 and m.clipboard[0]["at"] == Vector2(1, -2) and m.clipboard[0]["d"] == 4, "clip message")
	m.handle({"t": "eprops", "r": 1, "l": [[7, 5, 0, 0], [8, 0, 7.5, 2.5]]})
	check(m.eprops.get(7, {}).get("under") == 5.0 and m.eprops.get(8, {}).get("supply") == 2.5, "eprops message")

	# --- the shortcut bar ------------------------------------------------------------------------
	ui._on_shortcut("alt")
	check(ui.alt_mode and ui.alt_overlay.on, "the Alt-mode shortcut toggles it")
	ui._on_shortcut("alt")
	sent()

	# --- crafting search ---------------------------------------------------------------------------
	key(KEY_F, false, true)
	await get_tree().process_frame
	var crafting = ui.window._crafting
	check(ui.window.is_open() and crafting.search.visible and crafting.search.has_focus(), "Ctrl+F opens crafting and its search")
	crafting.search.text = "gear"
	crafting._fill_grid()
	var found_gear := _find_recipe_slot(ui, "iron-gear-wheel") != null
	crafting.search.text = "nothing like this"
	crafting._fill_grid()
	check(found_gear and _find_recipe_slot(ui, "iron-gear-wheel") == null, "search filters recipes by name")
	crafting.search.text = ""
	crafting.search.release_focus()
	crafting._fill_grid()
	ui.model.char_logistics = true  # researched (a `clog` came)
	ui.window.show_tab("Logistics")
	check(_texts(ui.window._logistics).size() >= 1, "the Logistics tab shows something (its switches and sections)")
	ui.window.show_tab("Crafting")
	ui.close_all()
	await get_tree().process_frame
	# Shut, the crafting grid isn't built again for a new recipe list (16-27 ms on the owner's
	# save each time); it is when it next shows.
	crafting._rebuild_stale = false
	ui.model.recipes_changed.emit()
	var stale_while_shut: bool = crafting._rebuild_stale
	ui.window.open_crafting(true)
	await get_tree().process_frame
	check(stale_while_shut and ui.window.is_open() and not crafting._rebuild_stale and _find_recipe_slot(ui, "iron-gear-wheel") != null,
		"a shut crafting panel only notes a new recipe list, and builds it when it shows")
	ui.close_all()

	# --- inventory slot filters (middle click) ------------------------------------------------------
	m.handle({"t": "slots", "l": {"main": [["iron-plate", 10], 0, 0]}})
	sent()
	click_main(ui, 1, MOUSE_BUTTON_MIDDLE)
	var fl := sent_one("inv_filter")
	check(fl.get("i") == 1 and fl.get("item") == "iron-plate", "middle click filters a slot to its item")
	m.handle({"t": "slots", "l": {"main": [0, 0, 0]}, "fl": [[1, "iron-plate"]]})
	ui.toggle_inventory()
	await get_tree().process_frame
	check(m.main_filters.get(1) == "iron-plate" and ui.window._grid.get_child(0).filter_item == "iron-plate", "the filter shows in the empty slot")
	click_main(ui, 1, MOUSE_BUTTON_MIDDLE)
	check(sent_one("inv_filter").get("item") == "", "middle click on a filtered empty slot clears it")
	ui.close_all()

	# --- machine screens: inserter, splitter, chest bar, combinator, train stop -----------------
	var screen: MachineScreen = hud.screen
	var old_protos = screen.protos
	screen.protos = _logic_protos()
	screen.request(900, {"t": "open", "u": 900, "p": 1, "x": 0, "y": 0})
	sent()
	screen.handle({"t": "gui", "u": 900, "p": 1, "kind": "inserter", "inv": {}, "ins": {"n": 5, "f": ["", "", "", "", ""], "m": "whitelist", "use": 0, "st": 0, "max": 3}})
	await get_tree().process_frame
	var mode_switch = screen.find_child("FilterMode", true, false)
	check(mode_switch != null and mode_switch.left_label.text == "Whitelist", "an inserter shows Factorio's whitelist / blacklist switch")
	if mode_switch != null:
		mode_switch.pick("right")
	check(sent_one("set_inserter").get("m") == "blacklist", "switching to blacklist sends it")
	player.cursor_item = "iron-plate"
	var filter_slot := _find_slot_tip(screen, "Filter")
	if filter_slot != null:
		filter_slot.clicked.emit(MOUSE_BUTTON_LEFT, false)
	var si := sent_one("set_inserter")
	check(si.get("f", [])[0] == "iron-plate" and si.get("use") == 1, "a filter slot clicked with an item held sets that filter (and uses filters)")
	player.cursor_item = ""
	if filter_slot != null:
		filter_slot.clicked.emit(MOUSE_BUTTON_LEFT, false)
	await get_tree().process_frame
	check(ui.picker.is_open(), "with nothing held it opens Factorio's item chooser")
	ui.picker._callback.call("item", "copper-plate")
	ui.picker.close()
	check(sent_one("set_inserter").get("f", [])[0] == "copper-plate", "and the chosen item becomes the filter")
	screen.handle({"t": "gui", "u": 900, "p": 1, "kind": "splitter", "inv": {}, "spl": {"i": "none", "o": "none", "f": ""}})
	await get_tree().process_frame
	var input_pri := _find_checkbox(screen, "Input priority")
	if input_pri != null:
		input_pri.button_pressed = true
	check(sent_one("set_splitter").get("i") == "left", "a splitter's input priority: ticking it sends the switch's side")
	var out_sw = screen.find_child("Priority_o", true, false)
	check(out_sw != null and not out_sw.enabled, "the output side's switch is greyed until Output priority is ticked")
	screen.handle({"t": "gui", "u": 900, "p": 1, "kind": "container", "inv": {"chest": [["iron-plate", 5]]},
		"slots": {"chest": [["iron-plate", 5], 0, 0, 0, 0, 0, 0, 0]}, "bar": 8})
	await get_tree().process_frame
	var limit := _find_slot_tip(screen, "Limit")
	check(limit != null, "a chest with a bar shows the limit button")
	if limit != null:
		limit.clicked.emit(MOUSE_BUTTON_LEFT, false)
		await get_tree().process_frame
		screen._stack_slot("chest", 4, {}).clicked.emit(MOUSE_BUTTON_LEFT, false)
	check(sent_one("set_bar").get("n") == 3, "the X then slot 4 limits the chest to 3 slots")
	screen.handle({"t": "gui", "u": 900, "p": 1, "kind": "container", "inv": {"chest": []},
		"slots": {"chest": [0, 0, 0, 0, 0, 0, 0, 0]}, "bar": 3})
	await get_tree().process_frame
	check(screen._stack_slot("chest", 5, {}).blocked and not screen._stack_slot("chest", 2, {}).blocked, "slots past the bar are red")
	screen.handle({"t": "gui", "u": 900, "p": 1, "kind": "combinator", "inv": {}, "cb": {"enabled": true, "signals": [["item", "iron-plate", 10]]},
		"sig": {"r": [["item", "iron-plate", 10]], "g": [], "ri": 7}})
	await get_tree().process_frame
	check(_texts(screen).has("Connected to:") and _texts(screen).has("7"), "a combinator's strip says which network it is connected to")
	var out = screen.find_child("OutputSwitch", true, false)
	if out != null:
		out.pick("left")
	check(sent_one("set_cb").get("cb", {}).get("enabled") == false, "a constant combinator's Off/On switch")
	await _circuit_screens(screen, ui)
	screen.handle({"t": "gui", "u": 900, "p": 1, "kind": "stop", "inv": {}, "stop": {"name": "Iron", "limit": -1, "count": 1}})
	await get_tree().process_frame
	var lim := _find_checkbox(screen, "Enable train limit")
	if lim != null:
		lim.button_pressed = true
	check(sent_one("set_stop").get("limit") == 1, "a train stop's limit")
	screen.handle({"t": "gui", "u": 900, "p": 1, "kind": "stop", "inv": {}, "stop": {"name": "Iron", "limit": -1, "count": 1, "pri": 50,
		"train": 0, "cb": {"wired": 1, "en": 0, "send": 1, "read": 0, "stopped": 1, "limit": 0, "count": 0, "pri": 0,
		"stopped_sig": {"type": "virtual", "name": "signal-T"}}}})
	await get_tree().process_frame
	var dock = screen.circuit_dock
	var read := _find_checkbox(dock, "Read train contents")
	if read != null:
		read.button_pressed = true
	var stop_cmd := sent_one("set_stop")
	check(read != null and _find_checkbox(dock, "Send to train").button_pressed and stop_cmd.get("cb", {}).get("read") == 1,
		"a train stop's circuit settings: in the docked circuit window, they show and send cb")
	check(_find_slot_tip(dock, "Signal-T") != null or _find_slot_tip(dock, Kit.pretty("signal-T")) != null, "and the stopped train's signal")
	check(dock.is_open("circuit") and dock.circuit_button.visible and dock.circuit_button.button_pressed,
		"a wired stop opens its circuit window, its title bar button lit")
	dock.circuit_button.button_pressed = false
	check(not dock.is_open("circuit") and not dock.visible, "the title bar button closes it")
	dock.circuit_button.button_pressed = true
	screen.handle({"t": "gui", "u": 900, "p": 14, "kind": "train", "inv": {}, "tr": {"id": 1, "state": "wait_station", "manual": false,
		"station": "", "dest": "", "sched": {"current": 1, "records": [{"station": "Iron", "wait_conditions": [{"type": "time", "compare_type": "or", "ticks": 600}]}]}}})
	await get_tree().process_frame
	check(_texts(screen).has("Iron") and _texts(screen).has("seconds passed"), "a train's schedule shows its stops and waits, in Factorio's words")
	var go := screen.find_child("Go1", true, false) as Button
	if go != null:
		go.pressed.emit()
	check(sent_one("train_go").get("i") == 1, "Go sends the train to that stop")
	# The full train window: every wait condition, interrupts, go to station, cargo, fuel, camera.
	screen.handle({"t": "gui", "u": 900, "p": 14, "kind": "train", "inv": {}, "tr": {"id": 1, "state": "on_the_path", "manual": 0,
		"station": "", "dest": "Iron", "speed": 200, "pos": [2560, 2560], "cargo": [["iron-plate", 400]], "fluids": [], "fuel": [["coal", 20]],
		"stops": ["Copper", "Iron"], "sched": {"current": 1, "group": "", "records": [{"station": "Iron", "wait_conditions": [
			{"type": "item_count", "compare_type": "and", "condition": {"first_signal": {"type": "item", "name": "iron-plate"}, "comparator": ">", "constant": 100}},
			{"type": "inactivity", "compare_type": "or", "ticks": 300}]}],
			"interrupts": [{"name": "Refuel", "conditions": [{"type": "fuel_item_count_any", "compare_type": "and"}],
				"targets": [{"station": "Copper", "wait_conditions": []}], "inside_interrupt": false}]}}})
	await get_tree().process_frame
	check(_texts(screen).has("Cargo") and _texts(screen).has("seconds of inactivity") and _find_button(screen, "OR") != null,
		"wait conditions show their words and the AND/OR button")
	check(_texts(screen).has("Refuel") and not _texts(screen).has("Fuel (any)"), "interrupts start folded to their name")
	var fold := screen.find_child("Fold1", true, false) as Button
	if fold != null:
		fold.pressed.emit()
	await get_tree().process_frame
	check(_texts(screen).has("Fuel (any)") and _texts(screen).has("When:") and _find_button(screen, "+ Add interrupt station") != null,
		"opening one shows its conditions and targets")
	fold = screen.find_child("Fold1", true, false) as Button
	if fold != null:
		fold.pressed.emit()
	await get_tree().process_frame
	check(screen.has_meta("train_camera") and (screen.get_meta("train_camera") as Camera3D).position.x == 10.0, "a camera above the train")
	var first_wait: Node = screen.find_child("Schedule", true, false).find_children("*", "PanelContainer", true, false).filter(func(n): return n.has_meta("drop"))[1]
	first_wait.get_meta("drop").call(Vector2.ZERO, {"f3d_schedule": "stations:0", "from": 1})
	var sched_cmd := sent_one("set_schedule")
	check(sched_cmd.get("records", [{}])[0].get("wait_conditions", [{}, {}])[0].get("type") == "inactivity", "dragging a condition onto another moves it")
	var moved_list := ScheduleEditor.reorder(["a", "b", "c"], 2, 0)
	check(moved_list == ["c", "a", "b"], "reordering moves the entry to the other's place: %s" % [moved_list])
	var add_station := screen.find_child("AddStation", true, false)
	if add_station != null:
		add_station.get_meta("pick").call(0, true)
	check(sent_one("train_temp").get("station") == "Copper", "Ctrl+click on a station in + Add station sends a temporary stop")
	if add_station != null:
		add_station.get_meta("pick").call(1, false)
	var added: Array = sent_one("set_schedule").get("records", [])
	check(added.size() == 2 and added[1].get("station") == "Iron", "a plain click adds the station to the schedule")
	var interrupt_field: LineEdit = null
	for e in screen.find_children("*", "LineEdit", true, false):
		if (e as LineEdit).placeholder_text == "Name":
			interrupt_field = e
	if interrupt_field != null:
		interrupt_field.text_submitted.emit("Depot")
	var ints: Array = sent_one("set_interrupts").get("interrupts", [])
	check(ints.size() == 2 and ints[1]["name"] == "Depot", "a new interrupt is added by name")
	sent()
	if interrupt_field != null and ints.size() == 2:
		interrupt_field.text_submitted.emit(str(ints[0]["name"]))
	check(sent_one("set_interrupts").is_empty(), "an interrupt name already in use is refused (Factorio: Interrupt names must be unique)")
	# Removing a station before the one the train is heading for keeps it heading for that stop.
	screen.handle({"t": "gui", "u": 900, "p": 14, "kind": "train", "inv": {}, "tr": {"id": 1, "state": "on_the_path", "manual": 0,
		"station": "", "dest": "Iron", "speed": 0, "stops": ["Copper", "Iron"], "sched": {"current": 2, "group": "", "records": [
			{"station": "Copper", "wait_conditions": []}, {"station": "Iron", "wait_conditions": []}], "interrupts": []}}})
	await get_tree().process_frame
	sent()
	var remove_first := screen.find_child("Remove1", true, false) as Button
	if remove_first != null:
		remove_first.pressed.emit()
	var removed := sent()
	check(removed.size() == 2 and removed[0].get("t") == "set_schedule" and removed[0].get("records", [1, 2]).size() == 1
		and removed[1].get("t") == "train_go" and removed[1].get("i") == 1,
		"removing a station before the current one sends the train to the same stop at its new place: %s" % [removed])
	ui.trains_window.open(true)  # the side menu's Trains button
	check(sent_one("trains_list").get("t") == "trains_list" and ui.trains_window.is_open(),
		"the train overview opens and asks for the trains at once (it showed none for 3 s)")
	m.handle({"t": "trl", "part": 1, "parts": 1, "l": [[1, "wait_station", 0, "Iron", "", 3, 700, 2560, 2560, 1, 0, [["iron-plate", 400]], []],
		[2, "manual_control", 1, "", "", 2, 710, 0, 0, 1, 0, [], []]]})
	await get_tree().process_frame
	var row2: Node = ui.trains_window.find_child("Train2", true, false)
	check(ui.trains_window.find_child("Train1", true, false) != null and row2 != null and _texts(ui.trains_window).has("Waiting at Iron"),
		"the overview lists every train with its state")
	var texts := [ui.trains_window.state_text({"state": "manual_control", "stop": ""}), ui.trains_window.state_text({"state": "manual_control_stop", "stop": ""}),
		ui.trains_window.state_text({"state": "no_path", "stop": "Iron"}), ui.trains_window.state_text({"state": "destination_full", "stop": "Iron"})]
	check(texts == ["Manually driving", "Manually stopped", "No path to Iron", "Destination full Iron"],
		"the card's state in Factorio's words (gui-train-state): %s" % [texts])
	var view: Node = row2.find_child("View", true, false) if row2 != null else null
	check(view != null and view.unit == 710 and _find_button(row2, "Manual") == null and _find_button(row2, "Automatic") == null,
		"a card shows a live view of the train from above (its locomotive), and no automatic / manual switch (Factorio's has none)")
	# Owner's C8: a train the client isn't drawing (far away) gets no 3D view, only the chart, asked for.
	var no_view: bool = view != null and view.find_children("*", "SubViewport", true, false).is_empty()
	if view != null:
		view._asked_at = -1e9
		view._ask_chart()
	check(no_view and ui.map_cache.spots.size() > 0, "a far train's card makes no 3D view; it asks for the chart around the train (C8): %s" % [ui.map_cache.spots])
	ui.map_cache.spots.clear()
	if view != null:
		view._make_view()
	var vp: SubViewport = view.find_children("*", "SubViewport", true, false)[0] if view != null else null
	check(vp != null and vp.world_3d == ui.get_viewport().world_3d and vp.render_target_update_mode != SubViewport.UPDATE_ALWAYS,
		"near, the view shares the client's world and renders only now and then")
	var tw = ui.trains_window
	check(_texts(tw).has("Train overview") and (tw._tab_buttons["Trains"] as Button).text == "Trains  2"
		and not tw._banner.visible, "Factorio's Train overview: tabs with counts, a card per train")
	var by_stop: Button = tw.find_child("List_Iron", true, false)
	var found_stop := by_stop != null
	if found_stop:
		by_stop.pressed.emit()
	await get_tree().process_frame
	check(found_stop and tw.find_child("Train1", true, false) != null and tw.find_child("Train2", true, false) == null,
		"the list on the left filters the cards (trains for Iron)")
	tw.show_tab("Groups")
	await get_tree().process_frame
	check(tw.filter == "" and tw._banner.visible == false, "the Groups tab lists every train under All")
	tw.show_tab("Trains")
	var look_at := []
	var catch_look := func(at: Vector2) -> void: look_at.append(at)
	tw.show_at.connect(catch_look)
	var card_click := InputEventMouseButton.new()
	card_click.button_index = MOUSE_BUTTON_LEFT
	card_click.pressed = true
	(tw.find_child("Train1", true, false) as Control).gui_input.emit(card_click)
	tw.show_at.disconnect(catch_look)
	check(look_at == [Vector2(10, 10)], "clicking a train's card looks at it: %s" % [look_at])
	tw.open(true)
	m.handle({"t": "trl", "part": 1, "parts": 1, "l": []})
	await get_tree().process_frame
	check(tw._banner.visible, "no trains: Factorio's red \"No Trains found.\" banner")
	# A stop may be called "All": its row filters to it, not to every train; fluids in the tooltip.
	m.handle({"t": "trl", "part": 1, "parts": 1, "l": [[1, "wait_station", 0, "All", "", 2, 700, 0, 0, 1, 0, [], [["water", 25000]]],
		[2, "wait_station", 0, "Iron", "", 2, 710, 0, 0, 1, 0, [], []]]})
	await get_tree().process_frame
	var all_stop: Button = null
	for row in tw._list.get_children():
		if row is Button and (row as Button).text.begins_with("All ("):
			all_stop = row
	var found_all := all_stop != null
	if found_all:
		all_stop.pressed.emit()  # the list is rebuilt: the button is freed
	await get_tree().process_frame
	var all_card := tw.find_child("Train1", true, false) as Control
	check(found_all and tw.filter == "All" and all_card != null and tw.find_child("Train2", true, false) == null
		and all_card.tooltip_text.contains("Water"), "a stop called All filters to its trains; a train's fluid is in its tooltip")
	# The Stations tab follows the search too: a train-less station that doesn't match is gone.
	var stops_player := Node.new()  # stands in for the player: stop_names() reads world.entities' names
	var stops_script := GDScript.new()
	stops_script.source_code = "extends Node\nvar world := {\"entities\": {1: {\"extra\": {\"n\": \"Idle stop\"}}}}\n"
	stops_script.reload()
	stops_player.set_script(stops_script)
	var old_player = ui.player
	ui.player = stops_player
	tw.search = "nomatch"
	var found_none: Array = tw._entries_for("Stations", tw._trains())
	tw.search = "iro"
	var found_iron: Array = tw._entries_for("Stations", tw._trains())
	tw.search = ""
	ui.player = old_player
	stops_player.free()
	check(found_none.is_empty() and found_iron.any(func(e: Array) -> bool: return e[0] == "Iron")
		and not found_iron.any(func(e: Array) -> bool: return e[0] == "Idle stop"),
		"the Stations tab's list follows the search box: %s / %s" % [found_none, found_iron])
	var ctrl_f := InputEventKey.new()
	ctrl_f.keycode = KEY_F
	ctrl_f.ctrl_pressed = true
	ctrl_f.pressed = true
	tw._unhandled_key_input(ctrl_f)
	check(tw._search_box.visible, "Ctrl+F opens the overview's search, as its button says")
	tw.toggle_search()
	ui.trains_window.open(false)
	await _logic_windows(screen, ui)
	await _logic2_windows(screen, ui)
	screen.close()
	screen.protos = old_protos

	# --- splitting transfers with a machine open ------------------------------------------------
	screen.request(901, {"t": "open", "u": 901, "p": 1, "x": 0, "y": 0})
	screen.handle({"t": "gui", "u": 901, "p": 1, "kind": "container", "inv": {"chest": [["coal", 9]]}, "slots": {"chest": [["coal", 9], 0]}})
	await get_tree().process_frame
	m.handle({"t": "slots", "l": {"main": [["iron-plate", 100], ["iron-plate", 50], 0]}})
	sent()
	click_main(ui, 1, MOUSE_BUTTON_RIGHT, true)
	check(sent_one("xfer").get("k") == "half", "Shift+right click puts half the stack in")
	click_main(ui, 1, MOUSE_BUTTON_RIGHT, false, true)
	check(sent_one("xfer").get("k") == "allhalf", "Ctrl+right click puts half of each stack of the item in")
	ui._on_machine_slot("chest", 1, "coal", 9, MOUSE_BUTTON_RIGHT, true, false)
	var half_take := sent_one("xfer")
	check(half_take.get("k") == "half" and half_take.get("from") == "chest", "Shift+right click on the machine takes half the stack")
	await _input_rules(hud, player, screen)
	screen.close()
	ui.close_all()


## Slot rules recorded from Factorio 2.1.23 itself (tools/ui_reference/f3d-ui-capture/rules.lua:
## cursor_transfer, cursor_split, stack_transfers, clear_cursor, pipette): merging what fits, a full
## stack left alone, one into the hand's own slot, dragging a stack across slots (left spreads it,
## right puts one in each), the middle click's item chooser, the pipette's biggest stack, Q
## putting a machine's stack into the inventory, and how the hand's slot is drawn.


func _input_rules(hud: Hud, player: Node, screen: MachineScreen) -> void:
	var ui = hud.ui
	var m = ui.model
	screen.close()
	ui.close_all()
	ui.hand = {}
	player.cursor_item = ""
	ui.toggle_inventory()
	m.handle({"t": "slots", "l": {"main": [["iron-plate", 80], ["iron-plate", 50], 0, 0, 0, 0, 0, 0, 0, 0]}})
	await get_tree().process_frame
	sent()
	click_main(ui, 1)
	await get_tree().process_frame
	var whole: Slot = ui.window._grid.get_child(0)
	check(whole.hand and whole.hand_left == -1, "a stack picked up whole leaves Factorio's hand alone on its slot")
	click_main(ui, 2)
	var mv := sent_one("move")
	check(mv.get("fi") == 1 and mv.get("ti") == 2 and player.cursor_item == "iron-plate" and ui.hand.has("merge"),
		"a click onto the same item moves what fits and keeps holding until the mod answers")
	m.handle({"t": "slots", "l": {"main": [["iron-plate", 30], ["iron-plate", 100], 0, 0, 0, 0, 0, 0, 0, 0]}})
	await get_tree().process_frame
	check(player.cursor_item == "iron-plate" and ui.hand.get("index") == 1 and ui.hand_count() == 30 and not ui.hand.has("merge"),
		"what didn't fit stays in the cursor (2.1.23: 80 onto 50 leaves 30 held)")
	click_main(ui, 3)
	sent()
	m.handle({"t": "slots", "l": {"main": [0, ["iron-plate", 100], ["iron-plate", 30], 0, 0, 0, 0, 0, 0, 0]}})
	await get_tree().process_frame
	check(player.cursor_item == "" and ui.hand.is_empty(), "a put-down that empties the hand's slot empties the cursor (no refill)")

	# right click on the hand's own slot puts one back
	click_main(ui, 3)
	click_main(ui, 3, MOUSE_BUTTON_RIGHT)
	await get_tree().process_frame
	var own: Slot = ui.window._grid.get_child(2)
	check(sent_one("move").is_empty() and ui.hand_count() == 29 and own.hand_left == 1,
		"right click on the hand's slot puts one back there (2.1.23: 1 in the slot, 36 of 37 held)")
	click_main(ui, 3)
	check(ui.hand.is_empty(), "and a click there puts the rest back")

	# dragging: the right button puts one in each slot crossed
	click_main(ui, 3)
	click_main(ui, 5, MOUSE_BUTTON_RIGHT)
	ui._spread_to("main", 6, 0)
	ui._spread_to("main", 6, 0)
	ui._spread_to("main", 2, 0)
	var ones := sent().filter(func(c): return c.get("t") == "move" and int(c.get("n", 0)) == 1)
	check(ones.size() == 3 and ones[1].get("ti") == 6 and ones[2].get("ti") == 2,
		"right drag puts one in each slot crossed, once each, onto the same item too")
	ui._spread = {}
	ui.clear_cursor()
	# the left button spreads the stack evenly; what doesn't divide stays held
	m.handle({"t": "slots", "l": {"main": [["iron-plate", 50], 0, 0, 0, 0, 0, 0, 0, 0, 0]}})
	await get_tree().process_frame
	sent()
	click_main(ui, 1)
	click_main(ui, 5)
	ui._spread_to("main", 6, 0)
	var moves := sent()
	check(moves.size() == 2 and moves[1].get("fi") == 5 and moves[1].get("ti") == 6 and int(moves[1].get("n")) == 25,
		"left drag over a second slot: half of the 50 goes on")
	ui._spread_to("main", 7, 0)
	moves = sent()
	var to7 := 0
	var back := 0
	for c in moves:
		if c.get("ti") == 7:
			to7 += int(c["n"])
		elif c.get("ti") == 1:
			back += int(c["n"])
	check(to7 == 16 and back == 2 and player.cursor_item == "iron-plate" and ui.hand.get("index") == 1,
		"a third slot: 16 each, the 2 left over back in the cursor")
	ui._spread = {}
	# the same through mouse motion over a slot with the button held
	ui.clear_cursor()
	m.handle({"t": "slots", "l": {"main": [["iron-plate", 50], 0, 0, 0, 0, 0, 0, 0, 0, 0]}})
	await get_tree().process_frame
	sent()
	click_main(ui, 1)
	click_main(ui, 5)
	var target: Control = ui.window._grid.get_child(7)
	var motion := InputEventMouseMotion.new()
	motion.position = target.get_global_rect().get_center()
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	ui._input(motion)
	moves = sent()
	check(moves.size() == 2 and moves[1].get("ti") == 8, "dragging over a slot with the left button held spreads onto it")
	motion.button_mask = 0
	ui._input(motion)
	check(ui._spread.is_empty(), "letting go ends the spreading")
	ui.clear_cursor()

	# middle click: an empty slot with nothing held asks which item to filter it to
	ui._on_character_slot("main", 9, MOUSE_BUTTON_MIDDLE, false, false)
	check(ui.picker.is_open(), "middle click on an empty slot opens the item chooser for its filter")
	ui.picker.close()

	# the pipette takes the biggest stack; Q puts a machine's stack into the inventory
	m.handle({"t": "slots", "l": {"main": [["iron-plate", 5], ["transport-belt", 30], ["transport-belt", 100], 0, 0, 0, 0, 0, 0, 0]}})
	await get_tree().process_frame
	check(ui.pick_from_inventory("transport-belt") and ui.hand.get("index") == 3 and ui.hand_count() == 100,
		"pipette: the biggest stack of the item, with its hand (2.1.23 takes a full stack)")
	ui.clear_cursor()
	# A full inventory: the chest's stack stays in the chest while held (with a free slot it would
	# move into the inventory at once, I7, _play).
	m.handle({"t": "slots", "l": {"main": [["iron-plate", 5], ["transport-belt", 30], ["transport-belt", 100], ["coal", 50],
		["coal", 50], ["coal", 50], ["coal", 50], ["coal", 50], ["coal", 50], ["coal", 50]]}})
	await get_tree().process_frame
	screen.unit = 78
	screen.handle({"t": "gui", "u": 78, "p": 0, "kind": "container", "inv": {"chest": [["coal", 10]]},
		"slots": {"chest": [["coal", 10], 0, 0, 0]}, "status": "working"})
	await get_tree().process_frame
	sent()
	screen.slot_clicked.emit("chest", 1, "coal", 10, MOUSE_BUTTON_LEFT, false, false)
	await get_tree().process_frame
	check(ui.window.hand_slot.is_empty() and screen.hand_slot.size() == 3, "a stack from a chest: the hand array carries the count")
	ui.clear_cursor()
	var back_in := sent_one("xfer")
	check(back_in.get("from") == "chest" and back_in.get("k") == "stack" and int(back_in.get("u", 0)) == 78 and player.cursor_item == "",
		"Q with a chest's stack puts it in the inventory (2.1.23's clear_cursor)")
	screen.close()
	ui.close_all()


## The character's gear: the armour's equipment grid in the character window (picking up, moving,
## putting from the inventory, Shift+click both ways), Alt+F / Alt+E and the shortcuts, the
## Character tab, the shield and energy bars, the damage flash and low-health tint, the respawn
## screen, the players window and the names over other players' characters.


func _gear(hud: Hud, player: Node) -> void:
	var ui = hud.ui
	var m = ui.model
	ui.close_all()
	player.cursor_item = ""
	ui.hand = {}
	m.handle({"t": "slots", "l": {"main": [["energy-shield-equipment", 2], 0, ["iron-plate", 10], 0], "armor": [["power-armor-mk2", 1]]}})
	m.handle({"t": "eq", "kind": "char", "u": 77, "w": 10, "h": 10, "sh": 30, "msh": 150, "bat": 5000000, "mbat": 100000000,
		"gen": 750000, "mv": 300, "inv": 0, "mvon": 1, "nv": 1, "rb": 1, "l": [
			["fission-reactor-equipment", 0, 0, 4, 4, "normal", 0, 0, 0, 0, 0],
			["energy-shield-mk2-equipment", 4, 0, 2, 2, "normal", 1000, 360000, 30, 150, 0],
			["exoskeleton-equipment", 6, 0, 2, 4, "normal", 400000, 400000, 0, 0, 0],
			["personal-roboport-equipment", 8, 0, 2, 2, "normal", 1, 35000000, 0, 0, 0]]})
	check(m.grid("char")["w"] == 10 and m.equipment_at("char", Vector2i(7, 3)).get("name") == "exoskeleton-equipment"
		and m.equipment_at("char", Vector2i(5, 5)).is_empty(), "eq message: the grid and what covers each cell")
	ui.toggle_inventory()
	await get_tree().process_frame
	check(not ui.window._armor_frame.visible, "the armour's grid stays shut with the inventory, as in Factorio")
	ui._on_character_slot("armor", 1, MOUSE_BUTTON_RIGHT, false, false)
	check(ui.window.armor_open, "right click on the armour opens its grid")
	await get_tree().process_frame
	check(ui.window._armor_frame.visible and ui.window.side == ui.window._armor_frame
		and ui.window.armor_grid.custom_minimum_size == Vector2(10, 10) * float(Kit.px(40)) and not ui.window._crafting_frame.visible,
		"the armour opens as its own window: the inventory and the whole 10x10 grid, no crafting")
	check(_texts(ui.window).has("Power armor MK2") or _texts(ui.window).has("Power armor mk2"), "titled with the armour's name")
	check(_texts(ui.window).has("Equipment grid") and _texts(ui.window).has("Equipment grid size:") and _texts(ui.window).has("10×10")
		and _texts(ui.window).has("Shield capacity:") and _texts(ui.window).has("150") and _texts(ui.window).has("100 MJ")
		and _texts(ui.window).has("• Max. robots:") and _texts(ui.window).has("10"),
		"with Factorio's summary under it: grid size, battery and shield capacity, the roboport's robots")
	sent()
	# Click a piece: it is picked up; click an empty cell: it moves there.
	ui._on_grid_clicked("char", Vector2i(7, 2), MOUSE_BUTTON_LEFT, false)
	check(player.cursor_item == "exoskeleton-equipment" and ui.hand.get("role") == "grid" and ui.hand.get("cell") == Vector2i(6, 0),
		"a click on a piece picks it up (by any of its cells)")
	ui._process(0.0)
	check(ui.window.armor_grid.grabbed == Vector2i(6, 0) and ui.window.armor_grid.held_size == Vector2i(2, 4),
		"the grid shows it grabbed, and where it would go")
	ui._on_grid_clicked("char", Vector2i(0, 5), MOUSE_BUTTON_LEFT, false)
	var mv := sent_one("eq_move")
	check(mv.get("x") == 6 and mv.get("y") == 0 and mv.get("tx") == 0 and mv.get("ty") == 5 and mv.get("kind") == "char"
		and player.cursor_item == "", "a click elsewhere in the grid moves it there (eq_move)")
	# Pick up, then click an empty inventory slot: back into the inventory there.
	ui._on_grid_clicked("char", Vector2i(8, 1), MOUSE_BUTTON_LEFT, false)
	click_main(ui, 2)
	var tk := sent_one("eq_take")
	check(tk.get("x") == 8 and tk.get("y") == 0 and tk.get("ti") == 2 and ui.hand.is_empty(), "and onto an empty inventory slot (eq_take into it)")
	# A stack of equipment from the inventory onto the grid.
	click_main(ui, 1)
	check(player.cursor_item == "energy-shield-equipment" and ui.hand.get("role") == "main", "equipment picked up in the inventory")
	ui._process(0.0)
	check(ui.window.armor_grid.held_item == "energy-shield-equipment", "the grid shows where the held equipment would go")
	ui._on_grid_clicked("char", Vector2i(4, 4), MOUSE_BUTTON_LEFT, false)
	var put := sent_one("eq_put")
	check(put.get("fi") == 1 and put.get("x") == 4 and put.get("y") == 4 and put.get("kind") == "char", "clicked into the grid at that cell (eq_put)")
	ui._drop_hand()
	# Shift+click both ways.
	click_main(ui, 1, MOUSE_BUTTON_LEFT, true)
	put = sent_one("eq_put")
	check(put.get("fi") == 1 and not put.has("x"), "Shift+click on equipment in the inventory puts it where it fits")
	click_main(ui, 3, MOUSE_BUTTON_LEFT, true)
	check(sent_one("eq_put").is_empty(), "but not iron plates")
	ui._on_grid_clicked("char", Vector2i(5, 1), MOUSE_BUTTON_LEFT, true)
	tk = sent_one("eq_take")
	check(tk.get("x") == 4 and tk.get("y") == 0 and not tk.has("ti"), "Shift+click on a piece takes it to the inventory")
	# Alt+F and Alt+E, and their shortcuts.
	for code in [KEY_F, KEY_E]:
		var ev := InputEventKey.new()
		ev.physical_keycode = code
		ev.keycode = code
		ev.alt_pressed = true
		ev.pressed = true
		get_viewport().push_input(ev)
		await get_tree().process_frame
	var toggles: Array = sent().filter(func(c): return c.get("t") == "eq_toggle")
	check(toggles.size() == 2 and toggles[0].get("what") == "roboport" and toggles[0].get("on") == 0
		and toggles[1].get("what") == "movement" and toggles[1].get("on") == 0, "Alt+F and Alt+E switch the roboport and exoskeletons off")
	ui._process(0.0)
	ui.shortcuts.update_unlocks({"personal-roboport-equipment": {"state": 2}, "exoskeleton-equipment": {"state": 2}})
	check(ui.shortcuts._buttons["roboport"].visible and ui.shortcuts._buttons["roboport"].button_pressed
		and ui.shortcuts._buttons["exoskeleton"].visible, "the shortcut bar has both switches while the armour has the equipment")
	ui._on_shortcut("exoskeleton")
	check(sent_one("eq_toggle").get("what") == "movement", "the exoskeleton shortcut switches it")
	# The artillery and discharge remotes: the shortcut puts the remote in the cursor, a click uses it (the mod's capsule).
	ui._on_shortcut("artillery")
	check(player.cursor_tool == "artillery", "the artillery remote shortcut holds the remote tool")
	ui._on_shortcut("discharge")
	check(player.cursor_tool == "discharge", "the discharge remote shortcut holds the remote tool")
	player.cursor_tool = ""
	var pi = load("res://scripts/player/player_input.gd").new()
	pi.cursor_tool = "artillery"
	pi.ground = Vector2(12.5, -3.0)
	pi.has_ground = true
	pi._lmb_down = true
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	pi._input(up)
	var thrown := sent_one("throw")
	check(thrown.get("item") == "artillery-targeting-remote" and thrown.get("x") == 3200 and thrown.get("y") == -768, "a click with the remote sends its capsule use at the cursor (throw)")
	pi.free()
	var cb := _find_checkbox(ui.window, "Personal roboport")
	check(cb == null or not cb.is_visible_in_tree(), "the armour window has no switches (Factorio has them on the shortcut bar)")
	# The Character tab.
	m.handle({"t": "cinfo", "craft": 1000, "mine": 1500, "run": 1000, "speed": 195, "eqmv": 300, "reach": 100, "build": 100,
		"rreach": 27, "pick": 11, "loot": 20, "drop": 100, "invb": 10, "eqinv": 20, "trash": 10, "hp": 250, "hpb": 0, "robots": 4, "slots": 110})
	if ui.window.side != null:
		ui.window.hide_side(ui.window.side)  # the armour's grid has the right half: the tab shows without it
	ui.window.open_crafting(true)
	ui.window.show_tab("Character")
	var info: Array = _texts(ui.window)
	check(info.has("Mining speed") and info.has("150%  (+50%)") and info.has("2.7") and info.has("110  (+10 bonus, +20 armor)")
		and info.has("100%  (+30% equipment)"), "the Character tab: bonuses, distances, slots, the equipment's running bonus")
	ui.window.show_tab("Crafting")
	ui.close_all()
	m.handle({"t": "eq", "kind": "char", "u": 77, "w": 0, "h": 0, "l": []})
	ui._process(0.0)
	check(not ui.window._armor_frame.visible and not ui.shortcuts._buttons["roboport"].visible, "without a grid: no armour panel, no switches")
	# Shield, energy, damage.
	hud.set_health(250, 250)
	hud.set_shield(150, 150)
	check(not hud.shield_bar.visible, "a full shield isn't shown")
	hud.set_shield(90, 150)
	check(hud.shield_bar.visible and hud.shield_bar.value == 90 and hud.damage.flash > 0.9, "a hit on the shield shows it over the health bar, with a red flash")
	hud.damage.flash = 0.0
	m.handle({"t": "eq", "kind": "char", "u": 77, "w": 2, "h": 2, "sh": 0, "msh": 0, "bat": 10, "mbat": 100, "gen": 0, "mv": 0, "inv": 0,
		"mvon": 1, "nv": 0, "l": [["battery-equipment", 0, 0, 1, 2, "normal", 10, 100, 0, 0, 0]]})
	check(not hud.energy_bar.visible and ui.weapons._energy.visible and is_equal_approx(ui.weapons._energy.value, 0.1),
		"batteries show their charge beside the armour slot, not over the quickbar")
	m.handle({"t": "eq", "kind": "char", "u": 77, "w": 2, "h": 2, "sh": 0, "msh": 0, "bat": 100, "mbat": 100, "gen": 0, "mv": 0, "inv": 0,
		"mvon": 1, "nv": 0, "l": [["battery-equipment", 0, 0, 1, 2, "normal", 100, 100, 0, 0, 0]]})
	check(not hud.energy_bar.visible and ui.weapons._energy.visible and is_equal_approx(ui.weapons._energy.value, 1.0),
		"full batteries stay shown beside the armour slot and hidden over the quickbar")
	hud.set_health(200, 250)
	check(hud.health_bar.visible and hud.health_bar.value == 200 and is_equal_approx(ui.weapons._energy.value, 1.0),
		"losing health shows the middle health bar without changing the armour power bar")
	check(hud.damage.flash > 0.9 and hud.damage.low == 0.0 and hud.damage.visible, "losing health flashes the screen's edges")
	m.handle({"t": "eq", "kind": "char", "u": 77, "w": 0, "h": 0, "l": []})
	check(not ui.weapons._energy.visible and not hud.energy_bar.visible, "without batteries, the armour power bar hides")
	Switches.set_test_args(PackedStringArray(["--power-bar=middle"]))
	m.handle({"t": "eq", "kind": "char", "u": 77, "w": 2, "h": 2, "sh": 0, "msh": 0, "bat": 10, "mbat": 100, "gen": 0, "mv": 0, "inv": 0,
		"mvon": 1, "nv": 0, "l": [["battery-equipment", 0, 0, 1, 2, "normal", 10, 100, 0, 0, 0]]})
	hud.set_health(125, 250)
	check(hud.energy_bar.visible and hud.energy_bar.value == 10 and is_equal_approx(ui.weapons._energy.value, 0.5),
		"--power-bar=middle restores the middle energy bar and health beside the armour")
	Switches.reset_cache()
	m.handle({"t": "eq", "kind": "char", "u": 77, "w": 0, "h": 0, "l": []})
	hud.set_health(25, 250)
	check(hud.damage.low > 0.5, "low health tints the screen red")
	hud.set_health(250, 250)
	hud.damage.flash = 0.0
	hud.damage._process(0.0)
	check(hud.damage.low == 0.0 and not hud.damage.visible, "healed: no tint")
	# The respawn screen.
	m.handle({"t": "dead", "left": 600, "x": 256, "y": 512})
	await get_tree().process_frame
	check(ui.death_screen.visible and _texts(ui.death_screen).has("You died. Bad luck. Respawn in 10 seconds.")
		and not ui.death_screen._button.visible and ui.death_screen.died_at == Vector2(1, 2), "dead: Factorio's respawn screen counts down")
	m.handle({"t": "dead", "left": 0})
	ui.death_screen._process(0.0)
	check(ui.death_screen._button.visible, "with nothing left to wait for, the Respawn button")
	ui.death_screen._button.pressed.emit()
	check(not sent_one("respawn").is_empty(), "which asks for the respawn")
	ui.death_screen.alive()
	check(not ui.death_screen.visible, "the new character's `me` closes it")
	# Players.
	m.handle({"t": "pl", "me": 1, "u": 77, "l": [[1, "engineer", 1, 0, 55, 255, 77, "nauvis", 1, 0, ""],
		[2, "friend", 1, 255, 120, 0, 900, "vulcanus", 0, 0, "[builder]"], [3, "gone", 0, 90, 90, 90, 0, "nauvis", 0, 0, ""]]})
	ui.players_window.toggle()
	await get_tree().process_frame
	var names: Array = _texts(ui.players_window)
	check(ui.players_window.visible and names.has("engineer  (you)") and names.has("friend [builder]") and names.has("Offline")
		and names.has("Player management") and names.has("2 online"), "the players window lists everyone, online first, with tags")
	check(m.player_of_unit(900).get("name") == "friend", "a player by their character")
	key(KEY_ESCAPE)
	await get_tree().process_frame
	check(not ui.players_window.visible, "Esc closes the players window")
	var movers := MoverLayer.new()
	var protos := ProtoDB.new()
	protos.add_entities([[3, "character", "character", -0.2, -0.2, 0.2, 0.2, 1, 1, 1, 1, 1]])
	movers.protos = protos
	add_child(movers)
	movers.handle({"t": "mv", "k": 1, "part": 1, "parts": 1, "l": [[900, 3, 2560, 2560], [77, 3, 0, 0]]})
	var tags := PlayerTags.new()
	tags.movers = movers
	tags.model = m
	add_child(tags)
	movers.puppet_unit = 77
	tags._process(0.0)
	var label: Label3D = tags.get_child(0) if tags.get_child_count() > 0 else null
	check(tags.count() == 1 and label != null and label.text == "friend [builder]" and label.position.y > 2.0,
		"another player's name floats over their character, not over our own")
	tags.queue_free()
	movers.queue_free()
	sent()
## Circuit settings (gui.cc), combinators in full and the entity settings of entity_settings.gd.


func _circuit_screens(screen: MachineScreen, ui) -> void:
	var gui := func(kind: String, extra: Dictionary) -> void:
		var msg := {"t": "gui", "u": 900, "p": 1, "kind": kind, "inv": {}}
		msg.merge(extra, true)
		screen.handle(msg)
	# Constant combinator sections.
	gui.call("combinator", {"cb": {"enabled": true, "signals": [["item", "iron-plate", 10]],
		"sections": [{"g": "", "on": 1, "m": 1, "s": [["item", "iron-plate", 10]]}]}})
	await get_tree().process_frame
	var add_section := _find_button(screen, "Add section")
	if add_section != null:
		add_section.pressed.emit()
	var cb: Dictionary = sent_one("set_cb").get("cb", {})
	check(cb.get("sections", []).size() == 2 and cb["sections"][1].get("on") == 1, "a constant combinator gets a second section")
	# A signal's value: Factorio's "Set request" popup (the chooser, the number, a slider, the tick).
	gui.call("combinator", {"cb": {"enabled": true, "signals": [["item", "iron-plate", 10]],
		"sections": [{"g": "", "on": 1, "m": 1, "s": [["item", "iron-plate", 10]]}]}})
	await get_tree().process_frame
	var sig_grid = screen.find_child("Signals", true, false)
	if sig_grid != null:
		(sig_grid.get_child(0) as Slot).clicked.emit(MOUSE_BUTTON_LEFT, false)
	await get_tree().process_frame
	var vbox := ui.picker.find_child("ConstantBox", true, false) as LineEdit
	var vtick := ui.picker.find_child("ValueOk", true, false) as Button
	check(ui.picker.is_open() and ui.picker._title.text == "Set request" and vbox != null and vbox.text == "10" and vtick != null and vtick.visible,
		"clicking a signal opens Set request with its value")
	if vbox != null:
		vbox.text = "25"
		vtick.pressed.emit()
	cb = sent_one("set_cb").get("cb", {})
	check(not ui.picker.is_open() and int(cb.get("sections", [{}])[0].get("s", [[0, 0, 0]])[0][2]) == 25, "the tick sets the signal's value")
	# Decider: conditions with and/or and networks, outputs.
	gui.call("combinator", {"cb": {"conditions": [{"first_signal": {"type": "item", "name": "iron-plate"}, "comparator": ">", "constant": 5}],
		"outputs": [{"signal": {"type": "virtual", "name": "signal-A"}, "copy_count_from_input": true}]}})
	await get_tree().process_frame
	var add_cond := _find_button(screen, "+ Add condition")
	if add_cond != null:
		add_cond.pressed.emit()
	cb = sent_one("set_cb").get("cb", {})
	check(cb.get("conditions", []).size() == 2 and cb["conditions"][1].get("compare_type") == "or", "a decider gets a second condition (or)")
	gui.call("combinator", {"cb": {"conditions": [{"first_signal": {"type": "item", "name": "iron-plate"}, "comparator": ">", "constant": 5},
		{"first_signal": {"type": "virtual", "name": "signal-B"}, "comparator": "<", "constant": 3, "compare_type": "or"}],
		"outputs": [{"signal": {"type": "virtual", "name": "signal-A"}, "copy_count_from_input": true}]}})
	await get_tree().process_frame
	var andor := screen.find_child("AndOr", true, false) as Button
	if andor != null:
		andor.pressed.emit()
	cb = sent_one("set_cb").get("cb", {})
	check(cb.get("conditions", [{}, {}])[1].get("compare_type") == "and", "and/or between conditions")
	var green := screen.find_child("NetG", true, false) as CheckBox
	if green != null:
		green.button_pressed = false
	cb = sent_one("set_cb").get("cb", {})
	check(cb.get("conditions", [{}])[0].get("first_signal_networks", {}) == {"red": true, "green": false}, "a condition's signal read from the red network only")
	var const_out := screen.find_child("OutConst", true, false) as CheckBox
	if const_out != null:
		const_out.button_pressed = true
	cb = sent_one("set_cb").get("cb", {})
	check(cb.get("outputs", [{}])[0].get("copy_count_from_input") == false, "an output switches from the input count to a constant")
	# Arithmetic: the first operand is a signal or a constant, as the second.
	gui.call("combinator", {"cb": {"first_constant": 7, "operation": "+", "second_constant": 2, "output_signal": {"type": "virtual", "name": "signal-A"}}})
	await get_tree().process_frame
	await get_tree().process_frame
	var first_op := screen.find_child("FirstOperand", true, false) as Button
	check(first_op != null and first_op.text == "7", "an arithmetic combinator's first constant shows on its operand button")
	if first_op != null:
		first_op.pressed.emit()
	await get_tree().process_frame
	var fbox := ui.picker.find_child("ConstantBox", true, false) as LineEdit
	if fbox != null:
		fbox.text = "9"
		fbox.text_submitted.emit("9")
	cb = sent_one("set_cb").get("cb", {})
	check(cb.get("first_constant") == 9 and not cb.has("first_signal"), "the first operand's constant is sent")
	# Selector: every mode.
	gui.call("combinator", {"cb": {"operation": "select", "select_max": true, "index_constant": 0}})
	await get_tree().process_frame
	var mode := screen.find_child("SelectorMode", true, false) as OptionButton
	check(mode != null and mode.item_count == CircuitPanel.SELECTOR_MODES.size(), "the selector lists every mode")
	if mode != null:
		mode.item_selected.emit(6)
	check(sent_one("set_cb").get("cb", {}).get("operation") == "quality-transfer", "choosing a selector mode sends it")
	gui.call("combinator", {"cb": {"operation": "quality-transfer", "quality_destination_signal": {"type": "virtual", "name": "signal-each"}}})
	await get_tree().process_frame
	check(_find_button(screen, "Quality from a signal") != null and _texts(screen).has("Output signal"), "quality transfer shows its settings")
	# The circuit connection of an inserter, with its network id.
	gui.call("inserter", {"ins": {"n": 0, "f": [], "st": 0, "max": 3, "sp": "none"}, "cc": {"o": "inserter", "w": 1, "nets": {"r": 5, "g": 0},
		"f": {"circuit_enable_disable": 0, "circuit_condition": {"comparator": "<", "constant": 0}, "circuit_read_hand_contents": 1,
		"circuit_hand_read_mode": "pulse", "circuit_set_stack_size": 0, "circuit_stack_control_signal": {}, "connect_to_logistic_network": 0,
		"logistic_condition": {"comparator": "<", "constant": 0}}, "ln": 1}, "sig": {"r": [["item", "iron-plate", 4]], "g": [], "ri": 5}})
	await get_tree().process_frame
	var dock = screen.circuit_dock
	check(_texts(dock).has("Circuit connection") and _texts(dock).has("Red network 5") and _texts(dock).has("Logistic connection")
		and _texts(dock).has("Input") and _texts(dock).has("Output"),
		"an inserter's circuit and logistic connection are in the docked windows, Input and Output apart, with the network id")
	check(dock.logistic_button.visible and not dock.is_open("logistic"), "the logistic window opens from its own title bar button")
	var enable := _find_checkbox(dock, "Enable if")
	if enable != null:
		enable.button_pressed = true
	var en_f: Dictionary = sent_one("set_cc").get("f", {})
	check(en_f.size() == 1 and int(en_f.get("circuit_enable_disable", 0)) == 1, "Enable/disable sends set_cc")
	var hold := _find_button(dock, "Hold")
	if hold != null:
		hold.button_pressed = true
	check(sent_one("set_cc").get("f", {}).get("circuit_hand_read_mode") == "hold", "the hand read mode")
	var spoiled := _find_button(screen, "Spoiled first")
	check(spoiled != null and spoiled.disabled, "Spoiled first / Fresh first are greyed until Spoiled priority is ticked")
	var spoil := _find_checkbox(screen, "Spoiled priority")
	if spoil != null:
		spoil.button_pressed = true
	check(sent_one("set_inserter").get("sp") == "spoiled-first", "an inserter's spoil priority")
	# A lamp's colour.
	gui.call("other", {"p": 11, "ao": 0, "col": [255, 255, 255], "cc": {"o": "lamp", "w": 1, "nets": {"r": 0, "g": 2}, "f": {"circuit_enable_disable": 0,
		"circuit_condition": {"comparator": "<", "constant": 0}, "use_colors": 1, "color_mode": "components",
		"red_signal": {"type": "virtual", "name": "signal-red"}, "rgb_signal": {"type": "virtual", "name": "signal-white"}}}})
	await get_tree().process_frame
	check(_texts(dock).has("Red") and not _texts(dock).has("RGB"), "a lamp in components mode shows its red signal, not the packed one")
	# docs/UI-DIFFERENCES.md, Lamp: the frame's entity preview, between the status line and the lamp's own rows.
	var lamp_always := _find_checkbox(screen, "Always on")
	check(screen._preview != null and screen._preview_proto == "small-lamp" and screen._preview.get_parent() == screen._body
		and lamp_always != null and screen._preview.get_index() < _child_of(screen._body, lamp_always).get_index(),
		"a lamp's window has the entity preview under its status line, over Always on")
	var always := _find_checkbox(screen, "Always on")
	if always != null:
		always.button_pressed = true
	check(sent_one("set_lamp").get("ao") == 1, "a lamp's Always on")
	var picker := screen.find_child("ColorPicker", true, false) as ColorPickerButton
	if picker != null:
		picker.color = Color8(255, 0, 0)
		picker.popup_closed.emit()
	check(sent_one("set_color").get("c", []).map(func(v): return int(v)) == [255, 0, 0], "a lamp's colour")
	# Programmable speaker.
	gui.call("other", {"p": 12, "spk": {"vol": 0.5, "mode": "local", "poly": 0, "vctl": 0, "vsig": {}, "inst": 0, "note": 0, "pitch": 0, "stop": 0,
		"al": {"show": 0, "map": 0, "icon": {}, "msg": ""}, "il": [["alarms", ["alarm-1", "alarm-2"]], ["piano", ["C4", "D4", "E4"]]]}})
	await get_tree().process_frame
	check(screen._preview != null and screen._preview_proto == "programmable-speaker" and screen._preview.get_parent() == screen._body
		and screen._preview.get_index() == 2 and screen._preview.get_index() < screen._body.get_child_count() - 1,
		"a programmable speaker's window has the entity preview under its network strip and status line, over its settings: child %d of %d"
			% [screen._preview.get_index() if screen._preview != null else -1, screen._body.get_child_count()])
	var inst := screen.find_child("Instrument", true, false) as OptionButton
	if inst != null:
		inst.item_selected.emit(1)
	check(sent_one("set_speaker").get("inst") == 1, "a speaker's instrument")
	var show := _find_checkbox(screen, "Show alert")
	if show != null:
		show.button_pressed = true
	check(sent_one("set_speaker").get("al", {}).get("show") == 1, "a speaker's alert")
	var glob := _find_button(screen, "Universe")
	if glob != null:
		glob.button_pressed = true
	check(sent_one("set_speaker").get("mode") == "global", "a speaker's playback")
	# Pump filter and turret targets go through the chooser.
	gui.call("other", {"p": 13, "pf": "", "fb": [["water", 50, 100]]})
	await get_tree().process_frame
	var fluid_slot := _find_slot_tip(screen, "Fluid filter")
	if fluid_slot != null:
		fluid_slot.clicked.emit(MOUSE_BUTTON_LEFT, false)
	await get_tree().process_frame
	check(ui.picker.is_open() and ui.picker._kinds == ["fluid"], "a pump's filter opens the chooser for fluids")
	check(not _texts(screen).has("Fluids"), "a pump shows no fluid box rows, as in Factorio")
	ui.picker._callback.call("fluid", "water")
	ui.picker.close()
	check(sent_one("set_pump").get("f") == "water", "a pump's fluid filter")
	gui.call("turret", {"tgt": {"l": ["small-biter"], "ign": 0}})
	await get_tree().process_frame
	var add_target := _find_slot_tip(screen, "Add a priority target")
	if add_target != null:
		add_target.clicked.emit(MOUSE_BUTTON_LEFT, false)
	await get_tree().process_frame
	check(ui.picker.is_open() and ui.picker._kinds == ["entity"], "a turret's targets open the chooser for entities")
	ui.picker._callback.call("entity", "medium-biter")
	ui.picker.close()
	check(sent_one("set_targets").get("l") == ["small-biter", "medium-biter"], "a priority target is added")
	var ign := _find_checkbox(screen, "Ignore unlisted targets")
	if ign != null:
		ign.button_pressed = true
	check(sent_one("set_targets").get("ign") == 1, "ignore unprioritised targets")
	# Display panel messages.
	gui.call("panel", {"p": 18, "dp": {"text": "Hi", "icon": {}, "show": 0, "chart": 0, "msgs": []}, "sig": {"r": [], "g": [], "ri": 3}})
	await get_tree().process_frame
	var add_msg := _find_button(screen, "+ Add message")
	if add_msg != null:
		add_msg.pressed.emit()
	check(sent_one("set_panel").get("msgs", []).size() == 1, "a display panel gets a message with a condition")
	var chart := _find_checkbox(screen, "Show tag in chart")
	if chart != null:
		chart.button_pressed = true
	check(sent_one("set_panel").get("chart") == 1, "a display panel's Show tag in chart")
	var text_box := screen.find_child("PanelText", true, false) as TextEdit
	if text_box != null:
		text_box.text = "Two lines"
	var confirm := screen.find_child("Confirm", true, false) as Button
	if confirm != null:
		confirm.pressed.emit()
	check(sent_one("set_panel").get("text") == "Two lines", "a display panel's text is sent with the green tick")


## The wire tools: what a click sends, reach, letting go, removing a pole's cables, drawing.


func _slots_named(node: Node, prefix: String) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is Slot and str(child.name).begins_with(prefix) and str(child.name).substr(prefix.length()).is_valid_int() \
				and not child.is_queued_for_deletion():
			out.append(child)
		else:
			out.append_array(_slots_named(child, prefix))
	return out


func _child_of(parent: Node, node: Node) -> Node:
	var n := node
	while n != null and n.get_parent() != parent:
		n = n.get_parent()
	return n if n != null else node


## The HUD's pieces stay on screen and apart at common window sizes, both at Factorio's automatic UI
## scale and at 200%. The HUD is laid out in a smaller area at this test's scale instead of
## rebuilding it at each scale: the same layout, divided by the scale.


func _modded_planets(hud: Hud) -> void:
	var ui = hud.ui
	var m = ui.model
	var Files = load("res://scripts/world/mod_files.gd")
	var Graphics = load("res://scripts/world/mod_graphics.gd")
	var Panels = load("res://scripts/ui/factorio/space_panels.gd")
	var MainScript = load("res://scripts/main.gd")
	var dirs_were: Array[String] = Files.extra_dirs.duplicate()
	var mods_were: Dictionary = Files.active_mods().duplicate()
	var locations_were: Array = m.space_locations.duplicate()
	var dirs: Array[String] = [ProjectSettings.globalize_path("res://").path_join("../tools/mod_tests/fixtures").simplify_path()]
	Files.extra_dirs = dirs
	Files.set_mods({"zenith-gfx-test": "1.0.0"})
	var until := Time.get_ticks_msec() + 5000
	while not Files.is_ready() and Time.get_ticks_msec() < until:
		await get_tree().process_frame
	var icon := [["__zenith-gfx-test__/graphics/icons/gizmo.png", 64, null, null, null]]
	# (mod_graphics.gd's use() went in the code review: what it did, by hand.)
	Graphics._want = "ui-test-planets"
	Graphics._apply("ui-test-planets", {"icons": {"space-location": {"zenith-test-planet": icon, "zenith-test-edge": icon}}})
	check(Panels.planet_icon("zenith-test-planet") != null and ui.space_map._planet_texture("zenith-test-planet") != null
		and ui.stats._planet_texture("zenith-test-planet") != null and MainScript.planet_picture("zenith-test-planet") != null
		and ui.map_view._surface_icon("zenith-test-planet") != null,
		"another mod's planet has its icon on the space map, the platform panel, the statistics, the map's surfaces and below a platform")
	var main = MainScript.new()
	main.hud = hud
	main._space_material = ShaderMaterial.new()
	main._space_material.shader = MainScript.SPACE_SKY
	m.space_locations = []  # the solar system not here yet
	sent()
	main._show_planet("zenith-test-planet")
	var before = main._space_material.get_shader_parameter("planet_on")
	var asked := sent_one("smap")
	m.handle({"t": "smap", "loc": [["zenith-test-planet", "planet", 0, 0, 1, 1], ["zenith-test-edge", "space-location", 0, 0, 1, 0]], "con": []})
	main._show_planet("zenith-test-planet")
	var planet_on = main._space_material.get_shader_parameter("planet_on")
	var tex_on = main._space_material.get_shader_parameter("planet_tex_on")
	main._show_planet("zenith-test-edge")
	var edge_on = main._space_material.get_shader_parameter("planet_on")
	check(before == 0.0 and asked.get("t") == "smap" and planet_on == 1.0 and tex_on == 1.0 and edge_on == 0.0,
		"a modded planet shows below a platform once smap says it is a planet, a space location doesn't: %s %s %s %s %s"
		% [before, asked, planet_on, tex_on, edge_on])
	main.free()
	m.space_locations = locations_were
	Graphics.clear()
	Files.extra_dirs = dirs_were
	Files.set_mods(mods_were)


## Space Age's screens (space_panels.gd, space_map.gd, planet_info.gd): the hub, a silo, a landing
## pad, a collector, quality and freshness in slots, the space map, the planet panel.


func _space(hud: Hud, player: Node) -> void:
	var ui = hud.ui
	var m = ui.model
	ui.close_all()
	player.cursor_item = ""
	sent()
	var screen: MachineScreen = hud.screen

	# --- slots: quality icons and the freshness bar, everywhere slots are drawn -------------------
	m.handle({"t": "slots", "l": {"main": [["iron-plate", 100, "rare"], ["yumako", 10, "normal", 250], 0]}})
	ui.toggle_inventory()
	await get_tree().process_frame
	var rare := _find_slot_tip(ui.window, "Iron plate")
	check(rare != null and rare.quality == "rare" and rare.freshness < 0.0, "an inventory slot knows its stack's quality")
	var fruit := _find_slot_tip(ui.window, "Yumako")
	check(fruit != null and is_equal_approx(fruit.freshness, 0.25), "and a spoiling stack's freshness (the bar)")
	check(fruit != null and fruit.tip_lines.any(func(l): return str(l[0]) == "Freshness: 25%"), "the tooltip says how fresh it is")
	ui.close_all()

	# --- the hub: the platform, its schedule, its requests from planets --------------------------
	var hub_msg := {"t": "gui", "u": 600, "p": 0, "kind": "hub", "inv": {"chest": [["iron-plate", 40]], "trash": []},
		"slots": {"chest": [["iron-plate", 40, "uncommon"], 0], "trash": [0]}, "status": "working", "ql": ["normal", "uncommon", "rare"],
		"hub": {"i": 1, "n": "Mock Orbiter", "st": "on_the_path", "pa": 0, "sp": 120.0, "w": 1250000, "from": "nauvis", "to": "vulcanus",
			"d": 400, "len": 15000, "th": [2, 2], "fuel": [["thruster-fuel", 1600, 2000]], "prov": 0, "dest": ["nauvis", "vulcanus"],
			"sched": {"current": 1, "group": "", "records": [{"station": "vulcanus", "wait_conditions": [{"type": "all_requests_satisfied", "compare_type": "and"}]}],
				"interrupts": []},
			"sec": [{"i": 1, "g": "", "on": 1, "m": 1, "man": 1, "f": [["iron-plate", "normal", 200, -1, "nauvis", -1]]}]}}
	screen.request(600, {"t": "open", "u": 600, "p": 0, "x": 0, "y": 0})
	sent()
	screen.handle(hub_msg)
	await get_tree().process_frame
	check(screen.is_open() and _texts(screen).has("Travelling: Nauvis → Vulcanus"), "a hub's screen shows the platform's trip")
	check(_texts(screen).any(func(t): return str(t).contains("Weight 1250 t") and str(t).contains("Thrusters 2 / 2 working")),
		"its speed, weight and thrusters")
	var pause := _find_button(screen, "Pause")
	if pause != null:
		pause.pressed.emit()
	check(sent_one("set_hub").get("pa") == 1, "Pause pauses the platform")
	var go := screen.find_child("Go1", true, false) as Button
	if go != null:
		go.pressed.emit()
	var tg := sent_one("train_go")
	check(_texts(screen).has("Vulcanus") and _texts(screen).has("All requests satisfied") and _texts(screen).has("Unload")
		and _find_button(screen, "+ Add fly condition") != null, "a platform's schedule is the same list as a train's, with Unload and fly conditions")
	check(tg.get("i") == 1 and int(tg.get("u", 0)) == 600, "Go sends the platform to that stop (the hub takes the train commands)")
	var prov := _find_checkbox(screen, "Provide materials to other platforms")
	if prov != null:
		prov.button_pressed = true
	check(sent_one("set_hub").get("prov") == 1, "provide to other platforms")
	var hub_columns := screen._columns.get_children().filter(func(c): return c.has_meta("extra_column"))
	check(hub_columns.size() == 2, "the hub's window has Factorio's three columns")
	var req: Node = null
	for b in _all_buttons(screen):
		if b.get("tip_title") == "Iron plate" and b.get("count") == 200:
			req = b
	check(req != null, "a request from a planet shows as a slot with its minimum")
	if req != null:
		req.clicked.emit(MOUSE_BUTTON_LEFT, false)
		await get_tree().process_frame
	var set_button := _find_button(screen, "Set")
	if set_button != null:
		set_button.pressed.emit()
	var sec := sent_one("set_section")
	var f0: Array = sec.get("f", [[]])[0] if sec.get("f") is Array else []
	check(int(sec.get("i", 0)) == 1 and f0.size() == 6 and f0[0] == "iron-plate" and int(f0[2]) == 200 and int(f0[3]) == -1
		and f0[4] == "nauvis" and int(f0[5]) == -1,
		"editing a request sends its section, import from planet and minimum delivery included")
	var add_section := _find_button(screen, "Add section")
	if add_section != null:
		add_section.pressed.emit()
	check(sent_one("set_section").get("i") == 0, "Add section")
	var moving: Dictionary = hub_msg.duplicate(true)
	moving["hub"]["d"] = 700
	screen.handle(moving)
	check(_texts(screen).any(func(t): return str(t).contains("10k / 15k km")), "the trip moves on without rebuilding the window")
	# Owner's G6: a long schedule scrolled down stays where it is when the screen is rebuilt (the
	# hub's inventory changes every second on a busy platform).
	var long_msg: Dictionary = moving.duplicate(true)
	var stops: Array = []
	for i in 16:
		stops.append({"station": "vulcanus" if i % 2 == 0 else "nauvis", "wait_conditions": [{"type": "time", "compare_type": "and", "ticks": 1800}]})
	long_msg["hub"]["sched"]["records"] = stops
	screen.handle(long_msg)
	for i in 3:
		await get_tree().process_frame
	var hub_scroll := func() -> ScrollContainer:
		var col: Node = screen._columns.get_children().filter(func(c): return c.has_meta("extra_column")).back()
		var found := col.find_children("*", "ScrollContainer", true, false)
		return found[0] if not found.is_empty() else null
	var before: ScrollContainer = hub_scroll.call()
	var room := before.get_v_scroll_bar().max_value - before.get_v_scroll_bar().page if before != null else 0.0
	if before != null:
		before.scroll_vertical = 150
	var refilled: Dictionary = long_msg.duplicate(true)
	refilled["slots"]["chest"] = [["iron-plate", 41, "uncommon"], 0]
	screen.handle(refilled)
	for i in 3:
		await get_tree().process_frame
	var after: ScrollContainer = hub_scroll.call()
	check(room > 150.0 and after != null and after != before and after.scroll_vertical == 150,
		"the hub's schedule keeps its scroll place when the screen is rebuilt (G6): %s of %s" % [after.scroll_vertical if after != null else -1, room])
	screen.close()
	sent()

	# --- a silo: parts, automatic launch, launch to a platform ---------------------------------------
	screen.request(601, {"t": "open", "u": 601, "p": 0, "x": 0, "y": 0})
	sent()
	screen.handle({"t": "gui", "u": 601, "p": 0, "kind": "silo", "inv": {"input": [], "rocket": [["space-platform-starter-pack", 1]]},
		"slots": {"input": [0, 0, 0], "rocket": [["space-platform-starter-pack", 1], 0]}, "status": "working",
		"rk": {"parts": 50, "need": 50, "st": "rocket_ready", "auto": 0, "to": [[2, "Platform 2", "waiting_for_starter_pack"]]}})
	await get_tree().process_frame
	check(_texts(screen).has("Rocket parts: 50 / 50") and _texts(screen).has("Rocket inventory"), "a silo shows its parts and the rocket's inventory")
	check(_texts(screen).has("Rocket progress") and _texts(screen).count("100%") >= 2 and _texts(screen).has("Trash unrequested"),
		"a silo: Rocket progress with its two bars, and its requests in the second column")
	var auto := _find_checkbox(screen, "Send to orbit automatically")
	if auto != null:
		auto.button_pressed = true
	check(sent_one("set_silo").get("auto") == 1, "automatic launches")
	var launch := _find_button(screen, "Launch")
	check(launch != null and not launch.disabled, "Launch, with the rocket ready")
	if launch != null:
		launch.pressed.emit()
	check(sent_one("silo_launch").get("to") == 2, "launches to the platform waiting for its starter pack")
	var no_ride := _find_button(screen, "Ride")
	check(no_ride != null and no_ride.disabled, "no ride to a platform still waiting for its starter pack (#10)")
	screen.handle({"t": "gui", "u": 601, "p": 0, "kind": "silo", "inv": {"input": [], "rocket": []},
		"slots": {"input": [0, 0, 0], "rocket": [0, 0]}, "status": "working",
		"rk": {"parts": 50, "need": 50, "st": "rocket_ready", "auto": 0, "to": [[3, "Orbiter", "waiting_at_station"]]}})
	await get_tree().process_frame
	var ride_button := _find_button(screen, "Ride")
	check(ride_button != null and not ride_button.disabled, "Ride, with the rocket ready and a platform with a hub in orbit (#10)")
	if ride_button != null:
		ride_button.pressed.emit()
	var rode := sent()
	check(rode.any(func(m): return m.get("t") == "ride" and m.get("u") == 601 and m.get("to") == 3) and screen.unit == 0,
		"Ride sends ride to the platform and closes the silo's screen: %s" % [rode])
	screen.close()
	sent()

	# --- a landing pad, a collector, a crafter's recipe quality and effects ---------------------------
	screen.request(602, {"t": "open", "u": 602, "p": 0, "x": 0, "y": 0})
	sent()
	screen.handle({"t": "gui", "u": 602, "p": 0, "kind": "pad", "inv": {"chest": [], "trash": []}, "slots": {"chest": [0], "trash": [0]},
		"pad": {"sec": [], "cb": {"read": 1, "req": 0, "empty": 0}}})
	await get_tree().process_frame
	var set_req := _find_checkbox(screen, "Set requests")
	if set_req != null:
		set_req.button_pressed = true
	check(sent_one("set_pad").get("req") == 1, "a landing pad's circuit settings")
	screen.close()
	sent()
	screen.request(603, {"t": "open", "u": 603, "p": 0, "x": 0, "y": 0})
	sent()
	screen.handle({"t": "gui", "u": 603, "p": 0, "kind": "collector", "inv": {"output": []}, "slots": {"output": [0]},
		"col": {"n": 3, "f": ["", "", ""]}})
	await get_tree().process_frame
	var chunk_filter := _find_slot_tip(screen, "No filter")
	if chunk_filter != null:
		chunk_filter.clicked.emit(MOUSE_BUTTON_LEFT, false)
	var sc := sent_one("set_collector")
	check(str(sc.get("f", [""])[0]).ends_with("-asteroid-chunk"), "a collector's filter slot picks an asteroid chunk")
	screen.close()
	sent()
	screen.request(604, {"t": "open", "u": 604, "p": 0, "x": 0, "y": 0})
	sent()
	screen.handle({"t": "gui", "u": 604, "p": 0, "kind": "crafter", "inv": {}, "recipe": "iron-gear-wheel", "rq": "rare",
		"ql": ["normal", "uncommon", "rare"], "eff": {"q": 25, "sp": -50}, "rl": ["iron-gear-wheel", "transport-belt"]})
	await get_tree().process_frame
	check(_texts(screen).has("Quality +2.5%") and _texts(screen).has("Speed -5.0%"), "module effects, quality among them")
	screen._picking = true
	screen._rebuild_now()
	await get_tree().process_frame
	var uncommon: Button = null
	for b in _all_buttons(screen):
		if b.tooltip_text == "Uncommon":
			uncommon = b
	if uncommon != null:
		uncommon.pressed.emit()
	var belt_recipe := _find_slot_tip(screen, "Transport belt (Recipe)")
	if belt_recipe != null:
		belt_recipe.clicked.emit(MOUSE_BUTTON_LEFT, false)
	var sr := sent_one("set_recipe")
	check(sr.get("recipe") == "transport-belt" and sr.get("q") == "uncommon", "the recipe picker sets the recipe's quality")
	screen.close()
	sent()

	# --- the space map, the planet panel, "can't build here", chunks and belt quality --------------
	m.handle({"t": "smap", "loc": [["nauvis", "planet", 0, -5000, 1, 1], ["vulcanus", "planet", 9000, 4000, 1, 0],
		["aquilo", "planet", 2000, 20000, 0, 0]], "con": [["nauvis", "vulcanus", 15000, 120], ["vulcanus", "aquilo", 30000, 900]]})
	check(m.space_locations.size() == 3 and m.space_connections[1]["danger"] == 0.9 and m.space_locations[0]["position"] == Vector2(0, -5),
		"smap message")
	ui.open_space_map(true)
	check(ui.space_map.is_open() and sent_one("smap").get("t") == "smap", "the space map opens and asks for the solar system")
	m.map_surfaces = [{"si": 1, "name": "nauvis", "planet": "nauvis", "platform": "", "pf": 0},
		{"si": 3, "name": "vulcanus", "planet": "vulcanus", "platform": "", "pf": 0}]
	await get_tree().process_frame
	await get_tree().process_frame
	check(ui.remote_frame.visible and ui.remote_frame.mode == "space" and ui.space_map.size.x > 0.0 and not ui.minimap.visible
		and ui.map_view.surfaces_panel.visible and (ui.map_view.surfaces_panel.find_child("SpaceMap", true, false) as Button).theme_type_variation == "FListItemSelected",
		"the space map is full screen in the Remote view frame, its row chosen in the Surfaces panel, the minimap hidden")
	# Owner's B6: hovering a route between planets highlights it and tells its distance and danger.
	var map_scale_was: float = ui.space_map.view_scale
	ui.space_map.view_center = Vector2(4.5, -0.5)
	ui.space_map.view_scale = 40.0  # the test's window is tiny: zoom in so the planets don't cover the route
	var route_ends: Array = ui.space_map._route_ends(0)
	var on_route: Vector2 = (route_ends[0] + route_ends[1]) * 0.5
	var hovered: Dictionary = ui.space_map.pick(on_route)
	var route_tip: String = ui.space_map._get_tooltip(on_route)
	check(hovered.get("route") == 0 and route_tip.contains("15 000 km") and route_tip.contains("Asteroids: Low") and route_tip.contains("—"),
		"a route on the space map: hover shows both ends, the distance and the asteroid danger: %s" % [route_tip])
	ui.space_map.view_scale = map_scale_was
	check(ui.space_map.km(1234567) == "1 234 567" and ui.space_map.danger_text(0.9) == "High", "distances written in full, danger in words")
	# A platform: parked at Nauvis, then selected on the map (its panel), then looked at.
	var pf_script := GDScript.new()
	pf_script.source_code = "extends Control\nvar platforms := {}\nvar on := 0\n"
	pf_script.reload()
	var pf_stub: Control = pf_script.new()
	pf_stub.platforms = {5: {"i": 5, "n": "Orbiter", "st": "waiting_at_station", "pa": 0, "hub": 9, "sp": 0.0, "w": 86600, "loc": "nauvis"}}
	add_child(pf_stub)
	var old_panel = ui.platform_panel
	ui.platform_panel = pf_stub
	m.map_surfaces = [{"si": 1, "name": "nauvis", "planet": "nauvis", "platform": "", "pf": 0},
		{"si": 3, "name": "vulcanus", "planet": "vulcanus", "platform": "", "pf": 0},
		{"si": 4, "name": "platform-5", "planet": "", "platform": "Orbiter", "pf": 5}, {"si": 6, "name": "f3d-lab", "planet": "", "platform": "", "pf": 0}]
	m.map_surfaces_changed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	var spots: Array = ui.space_map._platform_spots()
	check(spots.size() == 1 and _texts(ui.map_view.surfaces_panel).has("Other") and _texts(ui.map_view.surfaces_panel).has("f3d-lab")
		and ui.map_view.surfaces_panel.find_child("Surface4", true, false).find_child("At", true, false) != null,
		"the platform is drawn by its planet; the Surfaces panel has Other and the platform row its planet: %s" % [_texts(ui.map_view.surfaces_panel)])
	if not spots.is_empty():
		ui.space_map.click(spots[0][0])
	await get_tree().process_frame
	await get_tree().process_frame
	check(ui.space_map.selected == 5 and ui.remote_frame.info_panel.visible and _texts(ui.remote_frame.info_panel).has("Stopped at Nauvis")
		and _texts(ui.remote_frame.info_panel).has(" 86.6 tons"),
		"a click selects a platform: Factorio's panel under the tag icons (where, speed, mass): %s" % [_texts(ui.remote_frame.info_panel)])
	if not spots.is_empty():
		ui.space_map.click(spots[0][0])
	check(not ui.space_map.is_open() and ui.map_view.is_open() and m.map_si == 4, "a second click looks at the platform in remote view")
	await get_tree().process_frame
	await get_tree().process_frame
	check(ui.remote_frame.info_panel.visible, "the map of a platform shows its panel too")
	# G1, as Factorio 2.1.23 draws it (capture.py --only platform_panel): travelling, the strip holds the
	# planet it left, the bar of the way done with the distance come at its end, and the next planet;
	# under it the speed and mass. The panel sits under the map view settings.
	pf_stub.platforms[5] = {"i": 5, "n": "Orbiter", "st": "on_the_path", "pa": 0, "hub": 9, "sp": 150.0, "w": 86600,
		"from": "nauvis", "to": "vulcanus", "d": 250, "len": 15000}
	await get_tree().process_frame
	await get_tree().process_frame
	var info_p: Control = ui.remote_frame.info_panel
	var jtexts := "|".join(PackedStringArray(_texts(info_p)))
	var jbar := info_p.find_child("JourneyBar", true, false) as ProgressBar
	var jfrom := info_p.find_child("JourneyFrom", true, false) as Button
	var jto := info_p.find_child("JourneyTo", true, false) as Button
	# The planets' icons come from a Factorio install (none in CI).
	var icons_ok := SoundBank.data_dir() == "" or (jfrom != null and jfrom.icon != null)
	check(jbar != null and jbar.value == 250 and jfrom != null and jfrom.tooltip_text == "Nauvis" and icons_ok
		and jto != null and jto.tooltip_text == "Vulcanus" and jtexts.contains("3 750 km") and jtexts.contains(" 150.00 km/s")
		and jtexts.contains(" 86.6 tons") and not jtexts.contains("Stopped at"),
		"the map of a travelling platform shows Factorio's strip: planet left, bar with the distance come, next planet (G1): %s" % jtexts)
	var settings_r: Rect2 = ui.map_view.panel.get_global_rect()
	check(ui.map_view.panel.is_visible_in_tree() and info_p.get_global_rect().position.y >= settings_r.end.y - 0.5,
		"the platform's panel sits under the map view settings, as Factorio's: %s under %s" % [info_p.get_global_rect(), settings_r])
	# Stopped (paused, waiting at its stop, or done and waiting for cargo before it leaves) Factorio says
	# "Stopped at Nauvis" with the planet's icon; ours adds where it goes next (H7), with that planet's icon.
	pf_stub.platforms[5] = {"i": 5, "n": "Orbiter", "st": "waiting_for_departure", "pa": 0, "hub": 9, "sp": 0.0, "w": 60000,
		"loc": "nauvis", "nx": "vulcanus"}
	await get_tree().process_frame
	await get_tree().process_frame
	var wtexts := "|".join(PackedStringArray(_texts(info_p)))
	var next_row := info_p.find_child("NextStop", true, false)
	check(wtexts.contains("Stopped at Nauvis") and wtexts.contains(" 60 tons") and wtexts.contains(" 0.00 km/s") and next_row != null
		and _texts(next_row).has("Next stop:") and _texts(next_row).has(" Vulcanus") and info_p.find_child("JourneyBar", true, false) == null,
		"waiting for its cargo before leaving: Factorio's Stopped at Nauvis, and the next stop with its icon (H7): %s" % wtexts)
	pf_stub.platforms[5] = {"i": 5, "n": "Orbiter", "st": "paused", "pa": 1, "hub": 9, "sp": 0.0, "w": 1000, "loc": "nauvis"}
	await get_tree().process_frame
	await get_tree().process_frame
	wtexts = "|".join(PackedStringArray(_texts(info_p)))
	check(wtexts.contains("Stopped at Nauvis") and wtexts.contains(" 1 ton") and info_p.find_child("NextStop", true, false) == null,
		"paused, Factorio still says Stopped at (no Paused at), one ton: %s" % wtexts)
	# H3: zoomed into the platform's world from Nauvis (the remote view of another surface), its panel
	# shows under the minimap (the HUD's platform panel, watching that platform), the frame's goes.
	pf_stub.platforms[5] = {"i": 5, "n": "Orbiter", "st": "on_the_path", "pa": 0, "hub": 9, "sp": 150.0, "w": 86600,
		"from": "nauvis", "to": "vulcanus", "d": 250, "len": 15000}
	var hud_pp := PlatformPanel.new()
	hud.add_child(hud_pp)
	hud_pp.handle({"on": 0, "here": "nauvis", "dest": ["nauvis", "vulcanus"], "l": [pf_stub.platforms[5]]})
	ui.platform_panel = hud_pp
	ui.open_map(false)
	ui.remote = true
	ui.viewing_si = 4
	await get_tree().process_frame
	await get_tree().process_frame
	var corner: Rect2 = ui.side_menu.get_global_rect()
	var hud_r := hud_pp.get_global_rect()
	# under the minimap, or beside it on a window too short for that (F2)
	var placed := absf(hud_r.position.y - corner.end.y) < 1.0 or (absf(hud_r.position.y - corner.position.y) < 1.0 and hud_r.end.x <= corner.position.x)
	check(hud_pp.visible and hud_pp.find_child("JourneyBar", true, false) != null and not ui.remote_frame.info_panel.is_visible_in_tree()
		and placed and absf(hud_r.size.x - corner.size.x) < 1.0
		and not (hud_pp.find_child("DropRow", true, false) as Control).visible,
		"the remote view of a platform shows its panel under the minimap, as wide as the column (H3): %s under %s" % [hud_r, corner])
	ui.viewing_si = 0
	ui.remote = false
	await get_tree().process_frame
	check(not hud_pp.visible, "back to the character on Nauvis, the panel goes")
	# On board: Factorio's "Drop to a planet" with the character's icon, and the red cross that cancels.
	var aboard := {"i": 5, "n": "Orbiter", "st": "on_the_path", "pa": 0, "hub": 9, "sp": 150.0, "w": 86600,
		"from": "nauvis", "to": "vulcanus", "d": 250, "len": 15000}
	hud_pp.handle({"on": 5, "dest": ["nauvis", "solar-system-edge", "vulcanus"], "l": [aboard]})
	await get_tree().process_frame
	var drop_b := hud_pp.find_child("Drop", true, false) as Button
	var cancel_b := hud_pp.find_child("CancelDrop", true, false) as Button
	check(hud_pp.visible and drop_b != null and drop_b.is_visible_in_tree() and drop_b.text == "Drop to a planet" and cancel_b.disabled,
		"on board the panel has Factorio's Drop to a planet, the cross unlit")
	sent()
	drop_b.pressed.emit()
	var choices := hud_pp.find_child("DropChoices", true, false) as Control
	check(choices.visible and choices.find_child("DropTo_vulcanus", true, false) != null
		and choices.find_child("DropTo_solar-system-edge", true, false) == null, "it lists the planets to drop to: %s" % [_texts(choices)])
	(choices.find_child("DropTo_vulcanus", true, false) as Button).pressed.emit()
	check(not choices.visible and drop_b.text == "Dropping to Vulcanus" and not cancel_b.disabled and sent_one("land").is_empty(),
		"travelling, a drop to Vulcanus waits for the platform to get there (Dropping to Vulcanus)")
	aboard = {"i": 5, "n": "Orbiter", "st": "waiting_at_station", "pa": 0, "hub": 9, "sp": 0.0, "w": 86600, "loc": "vulcanus"}
	hud_pp.handle({"on": 5, "dest": ["nauvis", "vulcanus"], "l": [aboard]})
	check(sent_one("land").get("t") == "land" and hud_pp.dropping_to == "" and drop_b.text == "Drop to a planet",
		"stopped at Vulcanus, it drops (land)")
	drop_b.pressed.emit()
	(hud_pp.find_child("DropTo_nauvis", true, false) as Button).pressed.emit()
	cancel_b.pressed.emit()
	check(hud_pp.dropping_to == "" and cancel_b.disabled and sent_one("land").is_empty(), "the red cross cancels a planned drop")
	ui.platform_panel = pf_stub
	hud_pp.queue_free()
	ui.open_map(false)
	ui.open_space_map(true)
	var planet_at: Vector2 = ui.space_map.to_screen(m.space_locations[1]["position"])
	ui.space_map.click(planet_at)
	check(not ui.space_map.is_open() and ui.map_view.is_open() and m.map_si == 3, "clicking a planet shows it in remote view (the map's surface switcher)")
	ui.platform_panel = old_panel
	pf_stub.queue_free()
	ui.open_map(false)
	sent()
	m.handle({"t": "planet", "name": "space", "props": {"gravity": 0, "pressure": 0, "solar-power": 300}, "day": 25000, "always": 1,
		"heat": [], "nb": [[42, "gravity", 0.1, 1000000000]]})
	check(m.cant_build_reason(42) == "Can't build here: gravity is 0.0 m/s², it needs at least 0.1 m/s²" and m.cant_build_reason(7) == "",
		"planet.nb: why something can't be built here")
	ui.toggle_inventory()
	await get_tree().process_frame
	check(_texts(ui.window).has("Space") and _texts(ui.window).has("Gravity") and _texts(ui.window).has("300%"),
		"the character screen shows the planet's properties")
	ui.close_all()
	m.handle({"t": "ach", "l": [["metallic-asteroid-chunk", 2560, -512, 0, 768]]})
	check(m.asteroid_chunks.size() == 1 and m.asteroid_chunks[0]["velocity"] == Vector2(0, 3), "ach message")
	m.handle({"t": "bq", "l": [[77, "rare"]]})
	check(m.belt_quality.get(77) == "rare", "bq message")
	m.handle({"t": "ach", "l": []})
	m.handle({"t": "bq", "l": []})
	var MainScript = load("res://scripts/main.gd")
	var sky_main = MainScript.new()
	var sky_pp := PlatformPanel.new()
	sky_main.hud = hud
	sky_main.platform_panel = sky_pp
	sky_main._env = Environment.new()
	sky_main._planet_sky_res = Sky.new()
	sky_main._space_material = ShaderMaterial.new()
	sky_main._space_material.shader = MainScript.SPACE_SKY
	var plat_recs := [{"i": 1, "loc": "nauvis"}, {"i": 2, "loc": "vulcanus"}]
	sky_pp.handle({"on": 0, "here": "nauvis", "dest": ["nauvis", "vulcanus", "gleba"], "l": plat_recs})
	sky_main._space_platform = 1
	sky_main._set_space(true)
	sky_pp.handle({"on": 0, "here": "nauvis", "dest": ["nauvis", "vulcanus", "gleba"], "l": plat_recs})
	sky_main._show_planet_for(sky_main._sky_platform())
	var remote_planet_on = sky_main._space_material.get_shader_parameter("planet_on")
	check(remote_planet_on == 1.0 and sky_main._sky_planet == "nauvis" and sky_pp.on == 0,
		"remote viewing a platform from a planet keeps its planet in space even after plat arrives: on=%s sky=%s pp=%d"
		% [remote_planet_on, sky_main._sky_planet, sky_pp.on])
	sky_pp.handle({"on": 1, "dest": ["nauvis", "vulcanus", "gleba"], "l": plat_recs})
	sky_pp.plan_drop("gleba")
	sky_main._space_platform = 2
	sky_main._set_space(true)
	sky_pp.handle({"on": 1, "dest": ["nauvis", "vulcanus", "gleba"], "l": plat_recs})
	sky_main._show_planet_for(sky_main._sky_platform())
	var other_planet_on = sky_main._space_material.get_shader_parameter("planet_on")
	check(other_planet_on == 1.0 and sky_main._sky_planet == "vulcanus" and sky_pp.on == 1 and sky_pp.dropping_to == "gleba",
		"remote viewing another platform while boarded shows the viewed platform's planet and preserves board state: on=%s sky=%s pp=%d drop=%s"
		% [other_planet_on, sky_main._sky_planet, sky_pp.on, sky_pp.dropping_to])
	sky_pp.free()
	sky_main.free()
	for loc in ["nauvis", "vulcanus"]:
		if MainScript._planet_tasks.has(loc):
			WorkerThreadPool.wait_for_task_completion(int(MainScript._planet_tasks[loc]))
			MainScript._planet_tasks.erase(loc)
		MainScript._planet_lock.lock()
		MainScript._planet_images.erase(loc)
		MainScript._planet_lock.unlock()
		MainScript._planet_maps.erase(loc)
	var space_fog := RemoteFog.new()
	add_child(space_fog)
	space_fog.handle({"t": "cov", "si": 1, "l": [0, 0, 1], "x": 0, "y": 0, "cr": 32})
	space_fog.update(true, Vector2.ZERO)
	var was_hiding: bool = space_fog.hiding()
	space_fog.reset()
	var space_fog_quad := space_fog.get_node("RemoteFog") as MeshInstance3D
	check(was_hiding and not space_fog.hiding() and not space_fog_quad.visible,
		"switching surfaces resets remote_fog so stale planet fog never hides space")
	space_fog.free()
	sent()


## The decider conditions the real game was asked (tools/live/circuit_diff.py, section circdiff, on the combinator's real inputs):
## the green behind a condition (`condition_holds`, worked out from `gui.sig`) is what the game's combinator did.
func _decider_live_cases() -> void:
	var f := FileAccess.open("res://tests/fixtures/decider_live_cases.json", FileAccess.READ)
	check(f != null, "the recorded decider cases fixture opens")
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	var cases: Array = data["cases"] if data is Dictionary else []
	check(not cases.is_empty(), "the recorded decider cases load")
	var wrong: Array = []
	for r in cases:
		var cfg: Dictionary = data["configs"][int(r["i"])]
		if CircuitPanel.condition_holds(r["c"], cfg["sig"]) != bool(r["g"]):
			wrong.append("%s | red %s green %s | game %s" % [JSON.stringify(r["c"]), JSON.stringify(cfg["red"]), JSON.stringify(cfg["green"]), r["g"]])
	check(wrong.is_empty(), "the green behind a decider condition is what the game's combinator did (%d of %d differ): %s" % [wrong.size(), cases.size(), wrong.slice(0, 6)])


const ItemPicker := preload("res://scripts/ui/factorio/item_picker.gd")
const EntityPanels := preload("res://scripts/ui/factorio/entity_panels.gd")


## The signal chooser lists the game's whole virtual-signal set in its order (base game: 149 in the Signals tab; tools/live circdiff
## compares the list with `prototypes.virtual_signal`), each subgroup starting a row, and leaves the hidden items out.
func _picker_signals() -> void:
	var names: Array = []
	for group in ItemPicker.VIRTUAL_GROUPS:
		names.append_array(group)
	var seen := {}
	for n in names:
		seen[n] = true
	check(names.size() == 149 and seen.size() == 149, "the chooser lists the base game's 149 virtual signals once each: %d" % names.size())
	check(names.slice(0, 3) == ["signal-everything", "signal-each", "signal-anything"] and names.has("signal-info") and names.has("signal-heart")
		and names.has("up-arrow") and names.has("signal-skull"), "Everything, Each, Anything first; the symbols, arrows and pictographs too")
	var picker := ItemPicker.new()
	picker.items = func() -> Array: return ["iron-plate", "coin", "loader", "infinity-chest", "copper-plate"]
	add_child(picker)
	picker.choose(["item"], func(_t: String, _n: String) -> void: pass)
	var shown: Array = []
	for slot in picker._grid.get_children():
		if slot is Slot:
			shown.append(slot.item)
	check(shown == ["copper-plate", "iron-plate"], "the chooser leaves out hidden items (coin, loaders, infinity chests): %s" % [shown])
	picker.choose(["virtual"], func(_t: String, _n: String) -> void: pass)
	var cells := 0
	for slot in picker._grid.get_children():
		if slot is Slot:
			cells += 1
	check(cells == 149, "the chooser's grid holds all of them: %d" % cells)
	var counts := []
	for kind in ["virtual:plain", "virtual:each", "virtual:no-anything"]:
		picker.choose([kind], func(_t: String, _n: String) -> void: pass)
		var n := 0
		for slot in picker._grid.get_children():
			if slot is Slot:
				n += 1
		counts.append(n)
	check(counts == [146, 147, 148], "constant combinators take no Each / Anything / Everything, arithmetic operands Each only: %s" % [counts])
	var got := []
	var box := EntityPanels.number_box(0, func(v: int) -> void: got.append(v))
	add_child(box)
	box.text_submitted.emit("99999999999")
	box.text_submitted.emit("-99999999999")
	check(got == [2147483647, -2147483648], "a signal value clamps to 32 bits, as Factorio's box does (the game refuses more): %s" % [got])
	box.queue_free()
	# Batch 2 #10: Factorio-style tabbed ItemPicker + --item-picker-tabs=off.
	var was_tabs := ItemPicker.use_tabs
	ItemPicker.use_tabs = true
	picker.pedia_groups = func() -> Array: return [["logistics", "a"], ["production", "b"]]
	picker.pedia_index = func() -> Array: return [
		{"kind": "item", "name": "transport-belt", "group": "logistics", "sub": "belt", "order": "a"},
		{"kind": "item", "name": "assembling-machine-1", "group": "production", "sub": "asm", "order": "a"},
	]
	picker.items = func() -> Array: return ["transport-belt", "assembling-machine-1"]
	picker.choose(["item"], func(_t: String, _n: String) -> void: pass)
	var tab_items := func() -> Array:
		var out: Array = []
		for slot in picker._grid.get_children():
			if slot is Slot:
				out.append(slot.item)
		return out
	var log_items: Array = tab_items.call()
	var tabs_shown := picker._tab_strip.visible and picker._tabs.get_child_count() == 2
	if picker._tabs.get_child_count() >= 2:
		(picker._tabs.get_child(1) as Button).pressed.emit()
	var prod_items: Array = tab_items.call()
	picker._search.text = "belt"
	picker._search.text_changed.emit("belt")
	var search_hides_tabs: bool = not picker._tab_strip.visible and tab_items.call() == ["transport-belt"]
	picker._search.text = ""
	ItemPicker.use_tabs = false
	picker.choose(["item"], func(_t: String, _n: String) -> void: pass)
	var flat_no_tabs: bool = not picker._tab_strip.visible and tab_items.call() == ["assembling-machine-1", "transport-belt"]
	check(tabs_shown and log_items == ["transport-belt"] and prod_items == ["assembling-machine-1"]
		and search_hides_tabs and flat_no_tabs,
		"B2#10: tabbed ItemPicker groups by tab, searches across tabs, and --item-picker-tabs=off flattens (tabs=%s log=%s prod=%s search=%s flat=%s)"
		% [tabs_shown, log_items, prod_items, search_hides_tabs, flat_no_tabs])
	ItemPicker.use_tabs = was_tabs
	picker.queue_free()


func _logic2_windows(screen: MachineScreen, ui) -> void:
	const LogicWindows := preload("res://scripts/ui/factorio/logic_windows.gd")
	const SpiderRemote := preload("res://scripts/player/spider_remote.gd")
	var gui := func(kind: String, extra: Dictionary) -> void:
		var msg := {"t": "gui", "u": 900, "p": 1, "kind": kind, "inv": {}}
		msg.merge(extra, true)
		screen.handle(msg)
	sent()
	# Tank: three guns over three ammo slots, then the equipment grid button.
	LogicWindows.vehicle_grid_open = false
	gui.call("vehicle", {"p": 28, "inv": {"fuel": [["solid-fuel", 20]], "trunk": [], "car_ammo": []},
		"slots": {"fuel": [["solid-fuel", 20], 0], "car_ammo": [0, 0, 0], "trunk": [0, 0, 0, 0]},
		"guns": ["tank-cannon", "tank-machine-gun", "tank-flamethrower"], "bu": 700, "veh": {"grid": 1}})
	await get_tree().process_frame
	var guns = screen.find_child("Guns", true, false)
	var grid_button := screen.find_child("EquipmentGrid", true, false) as Button
	check(guns != null and guns.get_child(0).get_child_count() == 3 and grid_button != null and screen.find_child("SpiderTargeting", true, false) == null,
		"a tank: its three guns over their ammo slots and the equipment grid button")
	if grid_button != null:
		grid_button.button_pressed = true
	check(LogicWindows.vehicle_grid_open, "the grid button shows the vehicle's equipment grid")
	LogicWindows.vehicle_grid_open = false
	# Spidertron: the name strip (rename, colour) and Auto targeting.
	gui.call("vehicle", {"p": 29, "col": [229, 113, 0], "inv": {"trunk": [], "car_ammo": []}, "slots": {"car_ammo": [0, 0, 0, 0], "trunk": [0, 0]},
		"guns": ["spidertron-rocket-launcher-1", "spidertron-rocket-launcher-2", "spidertron-rocket-launcher-3", "spidertron-rocket-launcher-4"],
		"veh": {"grid": 1, "lbl": "Spidey", "at": [1, 0]}})
	await get_tree().process_frame
	check(_texts(screen).has("Spidey") and screen.find_child("ColorPicker", true, false) != null and _texts(screen).has("Auto targeting"),
		"a spidertron: its name and colour in the strip, Auto targeting")
	var with_gunner := screen.find_child("WithGunner", true, false) as CheckBox
	if with_gunner != null:
		with_gunner.button_pressed = true
	check(sent_one("set_vehicle").get("wi") == 1, "With gunner sends set_vehicle wi")
	var rename := screen.find_child("Rename", true, false) as Button
	var field := screen.find_child("VehicleNameField", true, false) as LineEdit
	if rename != null and field != null:
		rename.pressed.emit()
		field.text_submitted.emit("Spider 2")
	check(sent_one("set_vehicle").get("lbl") == "Spider 2", "the pencil renames the spidertron")
	# Artillery: Auto targeting, no target priorities; the wagon too.
	gui.call("turret", {"p": 30, "inv": {"turret_ammo": []}, "slots": {"turret_ammo": [0]}, "tgt": {"l": [], "ign": 0}, "art": 1})
	await get_tree().process_frame
	var auto := screen.find_child("AutoTargeting", true, false) as CheckBox
	check(auto != null and auto.button_pressed and not _texts(screen).has("Target priorities"), "an artillery turret: Auto targeting, no target priorities")
	if auto != null:
		auto.button_pressed = false
	check(sent_one("set_artillery").get("on") == 0, "unticking Auto targeting sends set_artillery")
	gui.call("train", {"p": 31, "inv": {"ammo": []}, "slots": {"ammo": [0]}, "art": 0,
		"tr": {"id": 1, "state": "on_the_path", "manual": 0, "station": "", "dest": "", "sched": {"current": 1, "group": "", "records": []}}})
	await get_tree().process_frame
	auto = screen.find_child("AutoTargeting", true, false) as CheckBox
	check(auto != null and not auto.button_pressed, "an artillery wagon: Auto targeting over its shells")
	# Storage tank and pipe: the contents, the pipeline and the flush buttons.
	gui.call("other", {"p": 16, "fb": [["crude-oil", 25000, 25000, 25]], "pl": ["crude-oil", 106100, 106100]})
	await get_tree().process_frame
	check(_texts(screen).has("Storage tank contents:") and _texts(screen).has("Pipeline contents:") and _texts(screen).has("106100 of 106100"),
		"a storage tank: its contents and the pipeline's")
	var flush_pipe = screen.find_child("Flush1", true, false)
	var flush_button = flush_pipe.find_child("FlushButton", true, false) as Button if flush_pipe != null else null
	if flush_button != null:
		flush_button.pressed.emit()
	check(sent_one("flush").get("pipe") == 1, "the pipeline's red button flushes the pipeline")
	gui.call("other", {"p": 32, "fb": [["", 0, 100, 0]], "pl": ["", 0, 4800]})
	await get_tree().process_frame
	var empty_flush = screen.find_child("Flush0", true, false)
	var empty_button = empty_flush.find_child("FlushButton", true, false) as Button if empty_flush != null else null
	check(_texts(screen).has("No fluid") and _texts(screen).has("N/A") and _texts(screen).has("0.00 of 100") and _texts(screen).has("Pipe contents:")
		and empty_button != null and empty_button.disabled, "an empty pipe: No fluid, N/A, 0.00 of 100, its flush button greyed")
	gui.call("other", {"p": 33, "temp": 656, "tc": 65613, "tmax": 1000})
	await get_tree().process_frame
	check(_texts(screen).has("Temperature: 656.13 °C"), "a heat pipe: its temperature in the red bar")
	# Decider: a condition that holds is green, worked out from the input signals.
	var cond_cb := {"conditions": [{"first_signal": {"type": "virtual", "name": "signal-T"}, "comparator": "<", "constant": 1100},
		{"first_signal": {"type": "virtual", "name": "signal-X"}, "comparator": "=", "constant": 0, "compare_type": "and"}], "outputs": []}
	gui.call("combinator", {"p": 26, "cb": cond_cb, "sig": {"r": [], "g": [["virtual", "signal-T", 1300]], "gi": 26}})
	await get_tree().process_frame
	var c1 = screen.find_child("Condition1", true, false)
	var c2 = screen.find_child("Condition2", true, false)
	check(c1 != null and c2 != null and not c1.get_meta("holds") and c2.get_meta("holds"),
		"T(1300) < 1100 doesn't hold, X = 0 does: the second condition is green")
	check(CircuitPanel.condition_holds({"first_signal": {"type": "virtual", "name": "signal-anything"}, "comparator": ">", "constant": 5},
		{"r": [["item", "iron-plate", 3], ["item", "coal", 9]]}) and not CircuitPanel.condition_holds(
		{"first_signal": {"type": "virtual", "name": "signal-everything"}, "comparator": ">", "constant": 5},
		{"r": [["item", "iron-plate", 3], ["item", "coal", 9]]}), "Anything and Everything over the input signals")
	check(not CircuitPanel.condition_holds({"first_signal": {"type": "item", "name": "coal"}, "comparator": ">", "constant": 5,
		"first_signal_networks": {"red": false, "green": true}}, {"r": [["item", "coal", 9]]}), "an operand reads only the networks ticked beside it")
	_decider_live_cases()
	_picker_signals()
	# The second operand is one signal-or-constant button: the chooser with its Constant row.
	var operand := screen.find_child("SecondOperand", true, false) as Button
	check(operand != null and operand.text == "1.1k", "the constant shows on the operand button, as Factorio writes it: %s" % [operand.text if operand != null else ""])
	if operand != null:
		operand.pressed.emit()
	await get_tree().process_frame
	var crow = ui.picker.find_child("ConstantRow", true, false)
	var cbox := ui.picker.find_child("ConstantBox", true, false) as LineEdit
	check(ui.picker.is_open() and crow != null and crow.visible and cbox != null and cbox.text == "1100", "clicking it opens the chooser with the constant")
	if cbox != null:
		cbox.text = "42"
		cbox.text_submitted.emit("42")
	var dcb: Dictionary = sent_one("set_cb").get("cb", {})
	check(not ui.picker.is_open() and dcb.get("conditions", [{}])[0].get("constant") == 42, "Enter sets the constant")
	# Locomotive in a group: "[2]", the Change train group popup, the camera into remote view.
	var followed: Array = []
	var old_follow: Callable = screen.remote_follow
	screen.remote_follow = func(unit: int, at: Vector2) -> void: followed.append([unit, at])
	gui.call("train", {"p": 14, "col": [242, 120, 0], "inv": {"fuel": []}, "slots": {"fuel": [0, 0, 0]},
		"tr": {"id": 1, "state": "on_the_path", "manual": 0, "station": "", "dest": "Iron", "name": "Loco", "stops": ["Iron"], "pos": [2560, 512],
			"gc": 2, "groups": [["Copper", 2], ["Iron", 3]], "sched": {"current": 1, "group": "Copper", "records": []}}})
	await get_tree().process_frame
	check(_texts(screen).has("Copper") and _texts(screen).has("[2]"), "a train in a group: the group's name and its count")
	var change := screen.find_child("ChangeGroup", true, false) as Button
	if change != null:
		change.pressed.emit()
	await get_tree().process_frame
	var group_field := screen.find_child("GroupField", true, false) as LineEdit
	check(group_field != null and group_field.text == "Copper" and screen.find_child("Groups", true, false) != null, "the pencil opens Change train group")
	if group_field != null:
		group_field.text = "Iron"
		group_field.text_submitted.emit("Iron")
	var sg := sent_one("set_train_group")
	check(sg.get("g") == "Iron" and sg.get("all") == 0, "Enter moves the train to that group")
	var cam := screen.find_child("TrainCamera", true, false) as Control
	if cam != null:
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		cam.gui_input.emit(click)
	check(followed.size() == 1 and followed[0][0] == 900 and followed[0][1] == Vector2(10, 2), "clicking the camera follows the train in remote view: %s" % [followed])
	screen.remote_follow = old_follow
	await get_tree().process_frame  # the popup Enter closed is gone
	if change != null:
		change.pressed.emit()
	var popup_open := screen.get_node_or_null("TrainGroupDialog") != null
	screen.close_local()
	check(popup_open and screen.get_node_or_null("TrainGroupDialog") == null,
		"closing the window takes Change train group with it (it showed over the next screen and moved that one's train)")
	# The spidertron remote: a click sends the selection, Shift queues; spd draws the waypoints.
	var remote := SpiderRemote.new()
	check(remote.left(null, Vector2(5, 5), Vector2(5, 5), false) != "" and sent_one("spider_go").is_empty(), "with nothing selected a click only says so")
	remote.selected = [610]
	remote.left(null, Vector2(5, 5), Vector2(5.1, 5), true)
	var go := sent_one("spider_go")
	check(go.get("l", []).map(func(v): return int(v)) == [610] and int(go.get("q", 0)) == 1 and int(go.get("x", 0)) == int(5.1 * 256),
		"Shift+click queues a waypoint for the selection: %s" % [go])
	remote._on_message({"t": "spd", "l": [[610, [[1280, 256], [2560, 512]]]]})
	check(remote.waypoints.get(610) == [Vector2(5, 1), Vector2(10, 2)], "spd: each spidertron's waypoints")
	remote._on_message({"t": "spd", "l": [[610, {}]]})
	check(remote.waypoints.get(610) == [], "spd: a spidertron's last waypoint reached clears its markers (Factorio writes the empty list as {})")
	remote.left(null, Vector2(0, 0), Vector2(20, 20), false)
	check(remote.selected.is_empty(), "a drag over no spidertron empties the selection")
	check(PlayerInput.OPENABLE_TYPES.has("pipe") and PlayerInput.OPENABLE_TYPES.has("land-mine") and not PlayerInput.OPENABLE_TYPES.has("generator")
		and not PlayerInput.OPENABLE_MOVERS.has("fluid-wagon"), "what opens a window is 2.1.23's list (rules_openable)")
	sent()


## Prototypes for the entity windows that go by type (ids as the screen tests send them).


func _logic_protos() -> ProtoDB:
	var p := ProtoDB.new()
	var rows: Array = []
	for e in [[1, "wooden-chest", "container"], [11, "small-lamp", "lamp"], [12, "programmable-speaker", "programmable-speaker"],
			[13, "pump", "pump"], [14, "locomotive", "locomotive"], [15, "cargo-wagon", "cargo-wagon"],
			[16, "storage-tank", "storage-tank"], [17, "train-stop", "train-stop"], [18, "display-panel", "display-panel"],
			[19, "rail-signal", "rail-signal"], [20, "car", "car"], [21, "burner-inserter", "inserter"], [22, "gun-turret", "ammo-turret"],
			[23, "roboport", "roboport"], [24, "small-electric-pole", "electric-pole"], [25, "power-switch", "power-switch"],
			[26, "decider-combinator", "decider-combinator"], [27, "arithmetic-combinator", "arithmetic-combinator"],
			[28, "tank", "car"], [29, "spidertron", "spider-vehicle"], [30, "artillery-turret", "artillery-turret"],
			[31, "artillery-wagon", "artillery-wagon"], [32, "pipe", "pipe"], [33, "heat-pipe", "heat-pipe"]]:
		rows.append([e[0], e[1], e[2], -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1])
	p.add_entities(rows)
	return p


## The logistics, logic, train and vehicle windows in Factorio's layout (logic_windows.gd,
## train_window.gd, circuit_panel.gd, circuit_window.gd): what each control sends.


func _logic_windows(screen: MachineScreen, ui) -> void:
	var gui := func(kind: String, extra: Dictionary) -> void:
		var msg := {"t": "gui", "u": 900, "p": 1, "kind": kind, "inv": {}}
		msg.merge(extra, true)
		screen.handle(msg)
	sent()
	# A burner inserter: the hand, the fuel slot and its bar, updated without a rebuild.
	gui.call("inserter", {"p": 21, "inv": {"fuel": [["coal", 2]]}, "slots": {"fuel": [["coal", 2]]}, "bu": 400,
		"ins": {"n": 0, "f": [], "st": 0, "max": 3, "h": ["iron-plate", 1]}})
	await get_tree().process_frame
	var hand = screen.find_child("Hand", true, false)
	var burner = screen.find_child("BurnerBar", true, false)
	check(hand != null and hand.item == "iron-plate" and burner != null and int(burner.value) == 400, "an inserter shows its hand, its fuel and the burning bar")
	gui.call("inserter", {"p": 21, "inv": {"fuel": [["coal", 2]]}, "slots": {"fuel": [["coal", 2]]}, "bu": 200,
		"ins": {"n": 0, "f": [], "st": 0, "max": 3}})
	await get_tree().process_frame
	check(screen.find_child("Hand", true, false) == hand and hand.item == "" and int(burner.value) == 200,
		"the hand and the bar change in place, without rebuilding the window")
	var size = screen.find_child("HandSize", true, false)
	check(size != null and not size.enabled, "the hand size slider is greyed until Override hand size is ticked")
	var override := _find_checkbox(screen, "Override hand size")
	if override != null:
		override.button_pressed = true
	check(int(sent_one("set_inserter").get("st", 0)) == 3, "ticking Override hand size sends the slider's value")
	gui.call("inserter", {"p": 21, "ins": {"n": 0, "f": [], "st": 3, "max": 3}})
	await get_tree().process_frame
	size = screen.find_child("HandSize", true, false)
	if size != null:
		size.commit(2)
	check(int(sent_one("set_inserter").get("st", 0)) == 2, "moving the notched slider sends the hand size")
	# No capacity bonus (max 1): the hand size can't be set above what the force allows.
	gui.call("inserter", {"p": 21, "ins": {"n": 0, "f": [], "st": 0, "max": 1}})
	await get_tree().process_frame
	size = screen.find_child("HandSize", true, false)
	check(size != null and size.max_value == 1, "the hand size slider goes no higher than the force's capacity (1 with no bonus)")
	if size != null:
		size.enabled = true
		size.commit(2)
		check(size.value == 1, "a hand size over the force's capacity is clamped")
	# A power switch: State, Off / On.
	gui.call("switch", {"p": 25, "sw": 0})
	await get_tree().process_frame
	var power = screen.find_child("PowerSwitch", true, false)
	if power != null:
		power.pick("right")
	check(sent_one("set_switch").get("on") == 1, "a power switch's Off / On switch")
	# A rail signal: the status line only, in a window of its own.
	gui.call("other", {"p": 19, "status": "working"})
	await get_tree().process_frame
	check(_texts(screen).has("Working") and not screen.shows_inventory(), "a rail signal opens alone with its status")
	# Arithmetic combinator: Input / Output, the signal strips, the description.
	gui.call("combinator", {"p": 27, "cb": {"operation": "*", "first_signal": {"type": "item", "name": "iron-plate"}, "second_constant": 2},
		"sig": {"r": [["item", "iron-plate", 5]], "g": [], "ri": 3, "out": {"r": [["item", "iron-plate", -10]], "g": [], "ri": 4}}, "desc": ""})
	await get_tree().process_frame
	var ins_strip = screen.find_child("InputSignals", true, false)
	check(_texts(screen).has("Input:") and _texts(screen).has("Output:") and ins_strip != null and _texts(screen).has("-10"),
		"an arithmetic combinator: the Input / Output strip, the signal strips (negative counts too)")
	var add_desc := screen.find_child("AddDescription", true, false) as Button
	if add_desc != null:
		add_desc.pressed.emit()
	var desc_text := screen.find_child("DescriptionText", true, false) as TextEdit
	if desc_text != null:
		desc_text.text = "Doubles iron"
	var desc_ok := screen.find_child("ConfirmDescription", true, false) as Button
	if desc_ok != null:
		desc_ok.pressed.emit()
	check(sent_one("set_desc").get("text") == "Doubles iron", "Add description sends the combinator's description")
	# Decider: + Add else.
	gui.call("combinator", {"p": 26, "cb": {"conditions": [{"comparator": "<", "constant": 0}], "outputs": []}})
	await get_tree().process_frame
	var add_else := screen.find_child("AddElseOutputs", true, false) as Button
	if add_else != null:
		add_else.pressed.emit()
	await get_tree().process_frame
	if ui.picker.is_open():
		ui.picker._callback.call("virtual", "signal-A")
		ui.picker.close()
	var dc: Dictionary = sent_one("set_cb").get("cb", {})
	check(dc.get("else_outputs", [{}])[0].get("signal", {}).get("name") == "signal-A", "+ Add else adds an else output")
	# Train stop: rename, train limit slider, priority, the train cards.
	gui.call("stop", {"p": 17, "col": [242, 0, 0], "stop": {"name": "Iron", "limit": 2, "count": 1, "pri": 50, "train": 0,
		"trs": [[4, "on_the_path", 1, 700], [5, "wait_station", 0, 710]]}})
	await get_tree().process_frame
	check(not screen.shows_inventory() and screen.find_child("Train4", true, false) != null and screen.find_child("Train5", true, false) == null,
		"a train stop opens alone; Trains on the way shows the train heading there")
	var with_tab := screen.find_child("TabTrainswiththisstop(2)", true, false) as Button
	if with_tab != null:
		with_tab.pressed.emit()
	await get_tree().process_frame
	check(screen.find_child("Train5", true, false) != null, "Trains with this stop shows every train with it in its schedule")
	var lim = screen.find_child("TrainLimit", true, false)
	if lim != null:
		lim.commit(4)
	check(sent_one("set_stop").get("limit") == 4, "the train limit slider")
	var pri = screen.find_child("Priority", true, false)
	if pri != null:
		pri.commit(80)
	check(sent_one("set_stop").get("pri") == 80, "the priority slider")
	var rename := screen.find_child("Rename", true, false) as Button
	var name_field := screen.find_child("StopNameField", true, false) as LineEdit
	if rename != null and name_field != null:
		rename.pressed.emit()
		name_field.text_submitted.emit("Copper")
	check(sent_one("set_stop").get("name") == "Copper", "the pencil renames the stop")
	check(not sent_one("set_stop").has("all"), "a plain rename renames only this stop")
	# Wired, with "Set train limit" and "Set priority" on, the circuit rules: Factorio greys both controls out.
	gui.call("stop", {"p": 17, "col": [242, 0, 0], "stop": {"name": "Iron", "limit": 3, "count": 1, "pri": 70, "train": 0, "trs": [],
		"cb": {"wired": 1, "limit": 1, "pri": 1}}})
	await get_tree().process_frame
	lim = screen.find_child("TrainLimit", true, false)
	pri = screen.find_child("Priority", true, false)
	check(lim != null and pri != null and not lim.enabled and not pri.enabled,
		"a train stop whose limit and priority the circuit network sets has both sliders disabled")
	gui.call("stop", {"p": 17, "col": [242, 0, 0], "stop": {"name": "Iron", "limit": 3, "count": 1, "pri": 70, "train": 0, "trs": [],
		"cb": {"wired": 0, "limit": 1, "pri": 1}}})
	await get_tree().process_frame
	lim = screen.find_child("TrainLimit", true, false)
	check(lim != null and lim.enabled, "the circuit flags without a wire change nothing")
	# Locomotive: alone, its name and colour, the Fuel tab.
	gui.call("train", {"p": 14, "col": [242, 120, 0], "inv": {"fuel": [["coal", 20]]}, "slots": {"fuel": [["coal", 20], 0, 0]}, "bu": 500,
		"tr": {"id": 1, "state": "on_the_path", "manual": 0, "station": "", "dest": "Iron", "name": "Copper", "stops": ["Iron"], "ctc": 0,
			"sched": {"current": 1, "group": "", "records": [{"station": "Iron", "wait_conditions": []}]}}})
	await get_tree().process_frame
	check(not screen.shows_inventory() and _texts(screen).has("Copper") and screen.find_child("ColorPicker", true, false) != null,
		"a locomotive opens alone with its name and colour")
	var mode = screen.find_child("TrainMode", true, false)
	if mode != null:
		mode.pick("right")
	check(sent_one("train_mode").get("auto") == 0, "the Automatic / Manual switch sends manual")
	var use_color := screen.find_child("UseStopColor", true, false) as CheckBox
	if use_color != null:
		use_color.button_pressed = true
	var copy_sent := sent_one("train_mode")
	check(use_color != null and copy_sent.get("ctc") == 1 and not copy_sent.has("auto"),
		"a locomotive's \"Use destination train stop color\" sends ctc: %s" % [copy_sent])
	var fuel_tab := screen.find_child("TabFuel", true, false) as Button
	if fuel_tab != null:
		fuel_tab.pressed.emit()
	await get_tree().process_frame
	check(screen.find_child("Slots_fuel", true, false) != null and screen.find_child("Schedule", true, false) == null, "the Fuel tab shows the fuel slots")
	var sched_tab := screen.find_child("TabSchedule", true, false) as Button
	if sched_tab != null:
		sched_tab.pressed.emit()
	await get_tree().process_frame
	var add_wait = screen.find_child("AddWait", true, false)
	if add_wait != null:
		add_wait.get_meta("pick").call(0, false)
	var recs: Array = sent_one("set_schedule").get("records", [])
	check(recs.size() == 1 and recs[0].get("wait_conditions", []).size() == 1 and recs[0]["wait_conditions"][0].get("type") == "time",
		"+ Add wait condition adds the chosen condition")
	# G8: rich text icons in names players write: a stop's name, a schedule's stations and the
	# "+ Add station" list, a train group's name, a logistic group's name and the overview's cards.
	var g8_plain = RichText.text_label("Iron")
	var g8_rich = RichText.text_label("[item=iron-plate] Iron", "FHeading")
	var g8_split: Array = RichText.icon_and_text("[item=iron-plate] Iron [virtual-signal=signal-A]")
	check(g8_plain is Label and g8_rich is RichTextLabel and (g8_rich as RichTextLabel).get_parsed_text().contains("Iron")
		and not (g8_rich as RichTextLabel).get_parsed_text().contains("[item") and g8_split[0] != null and str(g8_split[1]).begins_with("Iron [") and not str(g8_split[1]).contains("item="),
		"names with rich text icons get a label that draws them; one icon and plain text where only one fits (G8): %s" % [g8_split])
	g8_plain.free()
	g8_rich.free()
	gui.call("stop", {"p": 17, "col": [242, 0, 0], "stop": {"name": "[item=iron-plate] Iron", "limit": 2, "count": 1, "pri": 50, "train": 0, "trs": []}})
	await get_tree().process_frame
	var g8_stop = screen.find_child("StopName", true, false)
	check(g8_stop is RichTextLabel and (g8_stop as RichTextLabel).get_parsed_text().strip_edges() == "Iron",
		"a train stop's name draws its icon (G8): %s" % [g8_stop])
	gui.call("train", {"p": 14, "col": [242, 120, 0], "inv": {"fuel": []}, "slots": {"fuel": [0, 0, 0]}, "bu": 500,
		"tr": {"id": 1, "state": "on_the_path", "manual": 0, "station": "", "dest": "", "name": "", "stops": ["[item=copper-plate] Copper", "Iron"],
			"sched": {"current": 1, "group": "[item=coal] Coal run", "records": [{"station": "[item=copper-plate] Copper", "wait_conditions": []}]}}})
	await get_tree().process_frame
	var g8_station = screen.find_child("Station1", true, false)
	var g8_group = screen.find_child("TrainName", true, false)
	var g8_add := screen.find_child("AddStation", true, false) as MenuButton
	check(g8_station is RichTextLabel and (g8_station as RichTextLabel).get_parsed_text().strip_edges() == "Copper" and g8_group is RichTextLabel
		and g8_add != null and g8_add.get_popup().get_item_text(0) == "Copper" and g8_add.get_popup().get_item_icon(0) != null
		and g8_add.get_popup().get_item_text(1) == "Iron",
		"a schedule's station, the train group and + Add station's list draw their icons (G8)")
	var g8_card: Button = ui.trains_window._station_card("[item=iron-plate] Iron", 2)
	check(g8_card.text == "Iron\n2 trains" and g8_card.icon == RichText.icon("item", "iron-plate"),
		"the train overview's station card shows the name's icon (G8): %s" % g8_card.text)
	g8_card.free()
	# Cargo wagon: only its cargo and the red X.
	gui.call("train", {"p": 15, "inv": {"cargo": [["iron-plate", 50]]}, "slots": {"cargo": [["iron-plate", 50], 0, 0, 0]}, "bar": 4,
		"tr": {"id": 1, "state": "on_the_path", "manual": 0, "station": "", "dest": "Iron", "sched": {"current": 1, "group": "", "records": []}}})
	await get_tree().process_frame
	check(screen.shows_inventory() and screen.find_child("Schedule", true, false) == null and _find_slot_tip(screen, "Limit") != null,
		"a cargo wagon shows its cargo and the limit button, not the train's schedule")
	_find_slot_tip(screen, "Limit").clicked.emit(MOUSE_BUTTON_RIGHT, false)
	check(sent_one("set_bar").get("n") == 4, "right click on the red X: no limit on the wagon")
	# Middle click on a wagon's slot filters it (LuaInventory.set_filter on the wagon), clicking again clears it.
	ui._on_machine_slot("cargo", 1, "iron-plate", 50, MOUSE_BUTTON_MIDDLE, false, false)
	var wf := sent_one("inv_filter")
	check(wf.get("i") == 1 and wf.get("item") == "iron-plate" and int(wf.get("u", 0)) == screen.unit, "middle click on a cargo wagon's slot filters it to its item: %s" % str(wf))
	gui.call("train", {"p": 15, "inv": {"cargo": [["iron-plate", 50]]}, "slots": {"cargo": [["iron-plate", 50], 0, 0, 0]}, "bar": 4, "wfl": [[1, "iron-plate"]],
		"tr": {"id": 1, "state": "on_the_path", "manual": 0, "station": "", "dest": "Iron", "sched": {"current": 1, "group": "", "records": []}}})
	await get_tree().process_frame
	check(screen.wagon_filter(1) == "iron-plate" and screen.wagon_filter(2) == "", "a cargo wagon's filters (wfl) are read per slot")
	ui._on_machine_slot("cargo", 1, "iron-plate", 50, MOUSE_BUTTON_MIDDLE, false, false)
	check(sent_one("inv_filter").get("item") == "", "middle click on the filtered slot clears it")
	# Car: fuel and its bar, the gun over its ammo slot, the trunk.
	gui.call("vehicle", {"p": 20, "inv": {"fuel": [["coal", 5]], "trunk": [], "car_ammo": []}, "slots": {"fuel": [["coal", 5]], "car_ammo": [0],
		"trunk": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]}, "guns": ["vehicle-machine-gun"], "bu": 800})
	await get_tree().process_frame
	var guns = screen.find_child("Guns", true, false)
	check(guns != null and guns.get_child(0).get_child(0).item == "vehicle-machine-gun" and _texts(screen).has("Trunk") and screen.find_child("BurnerBar", true, false) != null,
		"a car: fuel with its bar, the gun over its ammo, the trunk")
	# Gun turret: the ammo row and target priorities; roboport rows.
	gui.call("turret", {"p": 22, "inv": {"turret_ammo": []}, "slots": {"turret_ammo": [0]}, "tgt": {"l": [], "ign": 0}})
	await get_tree().process_frame
	check(screen.find_child("Slots_turret_ammo", true, false) != null and _texts(screen).has("Target priorities"), "a turret: its ammo row and target priorities")
	gui.call("roboport", {"p": 23, "inv": {"robots": [], "repair": []}, "slots": {"robots": [0, 0, 0, 0, 0, 0, 0], "repair": [0, 0, 0, 0, 0, 0, 0]}})
	await get_tree().process_frame
	check(screen.find_child("Slots_robots", true, false) != null and screen.find_child("Slots_repair", true, false) != null
		and not _texts(screen).has("Robots"), "a roboport: two rows of slots without headings")
	# Storage tank: its fluid row.
	gui.call("other", {"p": 16, "fb": [["crude-oil", 12500, 25000, 25]]})
	await get_tree().process_frame
	check(_texts(screen).has("50%") and _texts(screen).has("12500 of 25000"), "a storage tank: fill in percent and its contents")
	# A pole opens the electric network statistics instead of a window.
	var opened: Array = []
	var old_stats: Callable = screen.open_stats
	screen.open_stats = func(kind: String, target: Dictionary) -> void: opened.append([kind, target])
	gui.call("pole", {"p": 24})
	await get_tree().process_frame
	check(opened.size() == 1 and opened[0][0] == "electric" and not screen.is_open(), "a pole opens Factorio's electric network info")
	screen.open_stats = old_stats
	screen.request(900, {"t": "open", "u": 900, "p": 1, "x": 0, "y": 0})
	# Batch 3 C5: entity-ghost opens with "Ghost: " title prefix.
	gui.call("crafter", {"p": 1, "gh": 1, "far": 1, "recipe": "iron-gear-wheel", "slots": {"modules": [0, 0]}})
	await get_tree().process_frame
	check(screen._title.text.begins_with("Ghost: "),
		"C5: entity-ghost gui prefixes title with 'Ghost: ' (%s)" % screen._title.text)
	screen.close()
	# Batch 2 #10: MMB on an empty quickbar slot opens the shared ItemPicker and pins the pick.
	var qb_idx: int = ui.model.quickbar_page * 10 + 4
	ui.model.unpin(qb_idx)
	sent()
	ui._on_quickbar_clicked(4, MOUSE_BUTTON_MIDDLE)
	var mmb_opened: bool = ui.picker.is_open()
	if mmb_opened and ui.picker._callback.is_valid():
		ui.picker._callback.call("item", "iron-plate")
		ui.picker.close()
	var qb_cmds: Array = sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "qb_set")
	check(mmb_opened and not ui.picker.is_open() and qb_cmds.size() == 1 and str(qb_cmds[0].get("item", "")) == "iron-plate",
		"B2#10: MMB on quickbar slot opens ItemPicker and pins selected item: %s" % [qb_cmds])
	ui.model.unpin(qb_idx)
	screen.request(900, {"t": "open", "u": 900, "p": 1, "x": 0, "y": 0})
	sent()


## Owner's play-test icons (#13 books' and blueprints' icons, #24 technologies). The index is
## checked always; the pictures only with a Factorio install (they're never in the repo).


func _wires(hud: Hud) -> void:
	var m: UiModel = hud.ui.model
	var world := WorldMirror.new()
	world.protos.add_entities([
		[1, "constant-combinator", "constant-combinator", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[2, "decider-combinator", "decider-combinator", -0.5, -1, 0.5, 1, 200, 180, 0, 1, 2],
		[3, "small-electric-pole", "electric-pole", -0.25, -0.25, 0.25, 0.25, 120, 90, 60, 1, 1],
		[4, "small-lamp", "lamp", -0.5, -0.5, 0.5, 0.5, 200, 200, 160, 1, 1],
	])
	m.handle({"t": "eprops", "l": [[1, 0, 0, 0, {"cw": 9}], [2, 0, 0, 0, {"cw": 9}], [3, 0, 7.5, 2.5, {"cw": 7.5}], [4, 0, 0, 0, {"cw": 9}]]})
	world.chunks[Vector2i.ZERO] = ChunkView.new()
	world._add([60, 1, 2 * 256 + 128, 2 * 256 + 128, 0])
	world._add([61, 2, 4 * 256 + 128, 2 * 256, 0])
	world._add([62, 3, 0 * 256 + 128, 6 * 256 + 128, 0])
	world._add([63, 3, 20 * 256 + 128, 6 * 256 + 128, 0])
	world._add([64, 4, 6 * 256 + 128, 2 * 256 + 128, 0, {"g": [61]}])
	var tool := WireTool.new()
	tool.world = world
	tool.model = m
	add_child(tool)
	sent()
	var alt_r := Controls.key_event(KEY_R | KEY_MASK_ALT)
	alt_r.pressed = true
	check(Controls.pressed(alt_r, "give_red_wire") and not Controls.pressed(alt_r, "rotate"), "Alt+R gives red wire (not rotate)")
	var e: Dictionary = world.entities
	check(tool.click("red-wire", e[60], Vector2(2.5, 2.5)) == "" and sent().is_empty() and not tool.from.is_empty(),
		"a first click takes the wire from the entity")
	tool.update("red-wire", null, Vector2(3.5, 3.5), true)
	check(tool._mesh.get_surface_count() == 1 and tool._ring_mesh.get_surface_count() == 1,
		"the wire is drawn to the mouse with its ground reach ring")
	tool.click("red-wire", e[61], Vector2(4.5, 2.6))
	var w := sent_one("wire")
	check(w.get("k") == "r" and w.get("a", {}).get("u") == 60 and w.get("b", {}).get("u") == 61 and int(w.get("b", {}).get("my", 0)) == roundi(2.6 * 256),
		"the second click connects them, with where it landed (the combinator's side)")
	check((tool.from["rec"] as WorldMirror.Rec).unit == 61, "the wire then hangs from the second entity")
	tool.click("red-wire", e[61], Vector2(4.5, 2.6))
	check(tool.from.is_empty() and sent().is_empty(), "clicking it again lets go")
	check(tool.click("copper-wire", e[64], Vector2(6.5, 2.5)) != "", "copper wire doesn't go on a lamp")
	tool.click("copper-wire", e[62], Vector2(0.5, 6.5))
	check(tool.click("copper-wire", e[63], Vector2(20.5, 6.5)) == "Wire can't reach that far" and sent().is_empty(), "a pole out of reach is refused")
	check(tool.cancel() and tool.from.is_empty() and tool._ring_mesh.get_surface_count() == 0,
		"right click lets go of the wire and clears its reach ring")
	# The game measures from one connection point to the other (live: two constant combinators 10 tiles apart take a 9-tile wire,
	# tools/live circdiff), so a click a little past the reach is the game's to refuse; one nothing could reach is the client's.
	world._add([65, 1, 2 * 256 + 128, 12 * 256 + 128, 0])
	world._add([66, 1, 12 * 256 + 128, 12 * 256 + 128, 0])
	world._add([67, 1, 14 * 256 + 128, 12 * 256 + 128, 0])
	tool.click("red-wire", e[65], Vector2(2.5, 12.5))
	check(tool.click("red-wire", e[66], Vector2(12.5, 12.5)) == "" and sent_one("wire").get("b", {}).get("u") == 66, "10 tiles apart: sent to the game to decide")
	tool.cancel()
	tool.click("red-wire", e[65], Vector2(2.5, 12.5))
	check(tool.click("red-wire", e[67], Vector2(14.5, 12.5)) == "Wire can't reach that far" and sent().is_empty(), "12 tiles apart: refused")
	tool.cancel()
	tool.clear_cables(e[62])
	check(sent_one("wire_clear").get("u") == 62, "Shift+click on a pole removes its cables")
	var input := PlayerInput.new()
	input.world = world
	check(input._openable(e[64]), "a wired lamp opens (anything on a circuit network does)")
	input.free()
	tool.queue_free()


## Phases 1-4 Logistics Network & Logistic Requests parity: character logistics tab, spidertron,
## roboport robot requests & open-network jump, ghost requester, storage filter quality, constant
## combinator groups/multiplier/quality, L window (rename/search/tabs/locate), --logistic-status=off,
## and empty `{}` / malformed array handling.
func _logistics_parity(hud: Hud, player: Node) -> void:
	const SpacePanels := preload("res://scripts/ui/factorio/space_panels.gd")
	const Wire := preload("res://scripts/util/wire.gd")
	var ui = hud.ui
	var m: UiModel = ui.model
	var w = ui.window
	var screen: MachineScreen = ui.screen
	ui.close_all()
	player.cursor_item = ""
	ui.hand = {}
	sent()

	# Save state we temporarily adjust.
	var old_protos = screen.protos
	var had_quals: Array = m.planners.qualities.duplicate(true)
	m.handle({"t": "quals", "l": [["normal", 0, 1], ["uncommon", 1, 1], ["rare", 2, 1]]})

	# --- 1. Character Logistics tab: quality, comparator, multiplier, auto-trash, tints, man==0 ---
	m.handle({"t": "slots", "l": {"main": [["iron-plate", 2, "rare"], ["wood", 5], 0, 0]}})
	m.handle({
		"t": "clog", "on": 1, "trash": 0, "lgs": ["Personal", "Mall"],
		"l": [["iron-plate", 10, 20, "rare", "≥"]],
		"del": [["iron-plate", 15, "rare"]],
		"pick": [["wood", 5]],
		"sec": [
			{"i": 1, "g": "Personal", "on": 1, "m": 2, "man": 1, "f": [
				["iron-plate", "rare", 10, 20, "", -1, "≥"],
				["wood", "normal", 0, 0, "", -1],
			]},
			{"i": 2, "g": "", "on": 1, "m": 1.5, "man": 0, "f": [
				["copper-plate", "uncommon", 5, -1, "", -1, "<"],
			]},
		],
	})
	m.handle({"t": "ln", "id": 4, "log": [10, 20], "con": [5, 8]})
	ui.toggle_inventory()
	await get_tree().process_frame
	(w._tab_buttons["Logistics"] as Button).pressed.emit()
	await get_tree().process_frame
	check(w.current_tab() == "Logistics" and w._logistics.is_visible_in_tree(), "Character Logistics tab opens")

	var char_slots: Array = w._logistics.find_children("*", "Button", true, false).filter(func(b): return b is Slot)
	var iron_slot: Slot = null
	var wood_slot: Slot = null
	var copper_slot: Slot = null
	for cs in char_slots:
		var s: Slot = cs
		if s.item == "iron-plate":
			iron_slot = s
		elif s.item == "wood":
			wood_slot = s
		elif s.item == "copper-plate":
			copper_slot = s
	check(iron_slot != null and iron_slot.quality == "rare" and iron_slot.quality_comparator == "≥"
		and iron_slot.max_count == 20 and iron_slot.status_tint.is_equal_approx(SpacePanels.TINT_UNSATISFIED),
		"character request slot shows quality, comparator >=, max count, and unsatisfied tint (2+15 < 20)")
	check(wood_slot != null and wood_slot.status_tint.is_equal_approx(SpacePanels.TINT_TRASHING),
		"character 0-0 auto-trash request gets trashing tint")
	check(copper_slot != null and copper_slot.theme_type_variation == "FSlot" and copper_slot.quality_comparator == "<"
		and _texts(w._logistics).has("Automatic requests") and _texts(w._logistics).has("Circuit / Automatic"),
		"non-manual (man=0) section renders read-only FSlot and automatic heading")

	# Non-manual section has no editable controls and ignores clicks.
	sent()
	if copper_slot != null:
		copper_slot.clicked.emit(MOUSE_BUTTON_LEFT, false)
	await get_tree().process_frame
	check(sent().is_empty(), "clicking a man=0 read-only request slot sends nothing")

	# On-the-way tint when have + del >= eff_min, and satisfied tint when have >= eff_min.
	m.handle({"t": "clog", "on": 1, "trash": 0, "lgs": ["Personal", "Mall"], "l": [],
		"del": [["iron-plate", 18, "rare"]], "pick": [],
		"sec": [{"i": 1, "g": "Personal", "on": 1, "m": 2, "man": 1, "f": [["iron-plate", "rare", 10, 20, "", -1, "≥"]]}]})
	await get_tree().process_frame
	var iron_on_way: Slot = null
	for cs in w._logistics.find_children("*", "Button", true, false):
		if cs is Slot and (cs as Slot).item == "iron-plate":
			iron_on_way = cs as Slot
			break
	check(iron_on_way != null and iron_on_way.status_tint.is_equal_approx(SpacePanels.TINT_ON_WAY),
		"character request turns yellow (on the way) when have + del >= eff_min")

	m.handle({"t": "slots", "l": {"main": [["iron-plate", 25, "rare"], ["wood", 5], 0, 0]}})
	m.logistics_changed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	var iron_sat: Slot = null
	for cs in w._logistics.find_children("*", "Button", true, false):
		if cs is Slot and not cs.is_queued_for_deletion() and (cs as Slot).item == "iron-plate":
			iron_sat = cs as Slot
			break
	check(iron_sat != null and iron_sat.status_tint.is_equal_approx(SpacePanels.TINT_SATISFIED),
		"character request turns blue (satisfied) when inventory meets eff_min")

	# Inline section multiplier edit in Character Logistics tab.
	var char_mult := w._logistics.find_child("SectionMultiplier", true, false) as LineEdit
	check(char_mult != null and char_mult.text == "2", "character section multiplier box shows 2")
	if char_mult != null:
		char_mult.text = "3"
		char_mult.text_submitted.emit("3")
	var mult_cmd := sent_one("set_section")
	check(int(mult_cmd.get("u", -1)) == 0 and int(mult_cmd.get("i", 0)) == 1 and is_equal_approx(float(mult_cmd.get("m", 0)), 3.0),
		"editing character section multiplier sends set_section u=0 m=3: %s" % [mult_cmd])

	# Open request editor on iron_sat, change comparator and click Auto-trash (0-0).
	sent()
	if iron_sat != null:
		iron_sat.clicked.emit(MOUSE_BUTTON_LEFT, false)
	await get_tree().process_frame
	var cmp_pick := w._logistics.find_child("QualityComparator", true, false) as OptionButton
	var auto_trash_btn := _find_button(w._logistics, "Auto-trash (0–0)")
	check(cmp_pick != null and auto_trash_btn != null, "request editor shows QualityComparator and Auto-trash (0-0)")
	if cmp_pick != null:
		cmp_pick.select(1)  # "≠"
		cmp_pick.item_selected.emit(1)
	if auto_trash_btn != null:
		auto_trash_btn.pressed.emit()
	var edit_cmd := sent_one("set_section")
	var edit_f: Array = edit_cmd.get("f", [])
	check(edit_f.size() >= 1 and int(edit_f[0][2]) == 0 and int(edit_f[0][3]) == 0 and str(edit_f[0][6]) == "≠",
		"Auto-trash (0-0) with comparator sends min=0, max=0, cmp=≠: %s" % [edit_cmd])

	# Shift+click on main inventory while Logistics tab is open sends xfer trash=1.
	sent()
	ui._transfer("main", 2, {"item": "wood", "count": 5}, MOUSE_BUTTON_LEFT, false, 0)
	var xfer_cmd := sent_one("xfer")
	check(int(xfer_cmd.get("trash", 0)) == 1 and str(xfer_cmd.get("from", "")) == "main",
		"Shift+click on main slot while Logistics tab open sends xfer trash=1: %s" % [xfer_cmd])
	ui.close_all()

	# --- 2. Screen tests: Spidertron, Roboport, Ghost requester, Storage quality, Constant comb ---
	var p := _logic_protos()
	p.add_entities([
		[34, "storage-chest", "logistic-container", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[35, "constant-combinator", "constant-combinator", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[36, "requester-chest", "logistic-container", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
	])
	screen.protos = p
	screen.request(910, {"t": "open", "u": 910, "p": 1, "x": 0, "y": 0})
	var gui := func(kind: String, extra: Dictionary) -> void:
		var msg := {"t": "gui", "u": 910, "p": 1, "kind": kind, "inv": {}}
		msg.merge(extra, true)
		screen.handle(msg)

	# 2a. Spidertron Logistics tab (on/mv/tu, requester sections, trunk/trash).
	sent()
	gui.call("vehicle", {
		"p": 29, "col": [229, 113, 0],
		"inv": {"trunk": [["rocket", 5]], "car_ammo": [], "trash": [["wood", 3]]},
		"slots": {"car_ammo": [0, 0, 0, 0], "trunk": [["rocket", 5], 0], "trash": [["wood", 3], 0]},
		"guns": ["spidertron-rocket-launcher-1", "spidertron-rocket-launcher-2", "spidertron-rocket-launcher-3", "spidertron-rocket-launcher-4"],
		"veh": {"grid": 1, "lbl": "Spider", "at": [1, 0]},
		"lg": {"mode": "requester", "net": {"id": 4}},
		"lc": {"on": 1, "mv": 1, "tu": 0, "in_net": 1, "sec": [{"i": 1, "g": "", "on": 1, "m": 1, "man": 1, "f": [["rocket", "normal", 20, 40, "", -1]]}]},
	})
	await get_tree().process_frame
	var tab_inv := screen.find_child("SpiderTab_Inventory", true, false) as Button
	var tab_log := screen.find_child("SpiderTab_Logistics", true, false) as Button
	check(tab_inv != null and tab_log != null and _texts(screen).has("Trunk"),
		"spidertron opens on Inventory tab with Trunk and Logistics tab")
	if tab_log != null:
		tab_log.pressed.emit()
	await get_tree().process_frame
	var sp_on := _find_checkbox(screen, "Enable logistics")
	var sp_mv := _find_checkbox(screen, "Enable logistics while moving")
	var sp_tu := _find_checkbox(screen, "Trash unrequested")
	check(sp_on != null and sp_mv != null and sp_tu != null and _texts(screen).has("Trash slots"),
		"spidertron Logistics tab shows on/mv/tu checkboxes, sections, and trash slots")
	if sp_on != null:
		sp_on.button_pressed = false
	check(int(sent_one("set_chest_logistics").get("on", -1)) == 0, "spidertron Enable logistics sends on=0")
	if sp_mv != null:
		sp_mv.button_pressed = false
	check(int(sent_one("set_chest_logistics").get("mv", -1)) == 0, "spidertron Enable logistics while moving sends mv=0")
	if sp_tu != null:
		sp_tu.button_pressed = true
	check(int(sent_one("set_chest_logistics").get("tu", -1)) == 1, "spidertron Trash unrequested sends tu=1")

	# 2b. Roboport robot requests + "Open logistic network" jump to Networks window.
	var rig_script := GDScript.new()
	rig_script.source_code = "extends Node3D\nvar target: Node3D = null\n"
	rig_script.reload()
	var rp_script := GDScript.new()
	rp_script.source_code = "extends Node\nvar rig: Node3D = null\nvar avatar: Node3D = null\nvar cursor_item := \"\"\nvar cursor_tool := \"\"\n"
	rp_script.reload()
	var real_player = ui.player
	var rig_player: Node = rp_script.new()
	var world_holder := Node3D.new()
	add_child(world_holder)
	rig_player.rig = rig_script.new()
	rig_player.avatar = Node3D.new()
	world_holder.add_child(rig_player.rig)
	world_holder.add_child(rig_player.avatar)
	add_child(rig_player)
	ui.player = rig_player

	sent()
	gui.call("roboport", {
		"p": 23,
		"inv": {"robots": [["logistic-robot", 12]], "repair": []},
		"slots": {"robots": [["logistic-robot", 12], 0, 0, 0, 0, 0, 0], "repair": [0, 0, 0, 0, 0, 0, 0]},
		"lg": {"mode": "roboport", "net": {"id": 4, "name": "Main", "log": [10, 20], "con": [5, 8]}, "cell": {"sl": 12, "sc": 4, "ch": 2, "tc": 1}},
		"lc": {"tu": 0, "no_tu": 1, "on": 1, "in_net": 1, "sec": [{"i": 1, "g": "", "on": 1, "m": 1, "man": 1, "f": [["logistic-robot", "normal", 25, -1, "", -1]]}]},
	})
	await get_tree().process_frame
	var rp_texts := _texts(screen)
	var open_net_btn := screen.find_child("OpenNetwork", true, false) as Button
	check(rp_texts.has("Main") and rp_texts.has("Logistic: 10 / 20 · Construction: 5 / 8")
		and rp_texts.has("Stationed: 12 logistic, 4 construction · Charging: 2 (1 waiting)")
		and _find_checkbox(screen, "Trash unrequested") == null and open_net_btn != null,
		"roboport renders network header, cell stats, robot request sections, no Trash unrequested, and OpenNetwork")
	if open_net_btn != null:
		open_net_btn.pressed.emit()
	await get_tree().process_frame
	var lnet_asks := sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "lnet" and int(c.get("id", 0)) == 4)
	check(not screen.visible and ui.networks.is_open() and ui.networks.selected == 4 and not lnet_asks.is_empty(),
		"Open logistic network closes roboport screen, jumps to L window on network 4, and requests lnet")
	ui.networks.open(false)
	await get_tree().process_frame

	# 2c. Ghost requester chest.
	screen.request(910, {"t": "open", "u": 910, "p": 1, "x": 0, "y": 0})
	sent()
	gui.call("container", {
		"p": 36, "gh": 1, "far": 1,
		"inv": {"chest": [], "trash": []}, "slots": {"chest": [], "trash": []},
		"lg": {"mode": "requester"},
		"lc": {"tu": 0, "rb": 1, "in_net": 0, "sec": [{"i": 1, "g": "", "on": 1, "m": 1, "man": 1, "f": [["iron-plate", "uncommon", 50, -1, "", -1, "≥"]]}]},
	})
	await get_tree().process_frame
	check(screen._title.text.begins_with("Ghost: ") and _texts(screen).has("Logistic requests")
		and not _texts(screen).has("Trash slots"),
		"ghost requester chest renders Ghost title and requests without trash slots")

	# 2d. Storage chest filter quality.
	sent()
	gui.call("container", {
		"p": 34,
		"inv": {"chest": []}, "slots": {"chest": [0, 0]},
		"lg": {"mode": "storage", "filter": "iron-plate", "filter_q": "rare", "net": {"id": 4}},
		"ql": ["normal", "uncommon", "rare"],
	})
	await get_tree().process_frame
	var sto_slots: Array = screen.find_children("*", "Button", true, false).filter(func(b): return b is Slot and (b as Slot).item == "iron-plate")
	var unc_btn := screen.find_children("*", "Button", true, false).filter(func(b): return (b as Button).tooltip_text == "Uncommon")
	check(sto_slots.size() >= 1 and (sto_slots[0] as Slot).quality == "rare" and unc_btn.size() >= 1,
		"storage chest filter slot shows rare quality and unlocked quality row")
	if not unc_btn.is_empty():
		(unc_btn[0] as Button).pressed.emit()
	var ssf := sent_one("set_storage_filter")
	check(str(ssf.get("item", "")) == "iron-plate" and str(ssf.get("q", "")) == "uncommon",
		"clicking quality button on storage chest sends set_storage_filter with q: %s" % [ssf])

	# 2e. Constant combinator group chips, multiplier, and signal quality.
	sent()
	gui.call("combinator", {
		"p": 35,
		"cb": {"enabled": true, "sections": [{"g": "Mall", "on": 1, "m": 2, "s": [["item", "iron-plate", 10, "rare"]]}]},
		"lgs": ["Mall", "Science"],
		"ql": ["normal", "uncommon", "rare"],
	})
	await get_tree().process_frame
	var cc_group_btn := screen.find_child("GroupButton", true, false) as Button
	var cc_editor := screen.find_child("GroupEditor", true, false) as Control
	var cc_mult := screen.find_child("SectionMultiplier", true, false) as LineEdit
	check(cc_group_btn != null and cc_editor != null and cc_mult != null and cc_mult.text == "2",
		"constant combinator shows GroupButton, GroupEditor, and SectionMultiplier")
	if cc_group_btn != null:
		cc_group_btn.pressed.emit()
	var sci_chip := _find_button(cc_editor, "Science") if cc_editor != null else null
	check(cc_editor != null and cc_editor.visible and sci_chip != null, "constant combinator GroupEditor shows logistic group chips")
	if sci_chip != null:
		sci_chip.pressed.emit()
	var cb_grp: Dictionary = sent_one("set_cb").get("cb", {})
	check(cb_grp.get("sections", [{}])[0].get("g") == "Science", "clicking group chip updates constant combinator section group")
	if cc_mult != null:
		cc_mult.text = "3.5"
		cc_mult.text_submitted.emit("3.5")
	var cb_mult: Dictionary = sent_one("set_cb").get("cb", {})
	check(is_equal_approx(float(cb_mult.get("sections", [{}])[0].get("m", 0)), 3.5),
		"editing constant combinator multiplier sends set_cb m=3.5")

	var sig_grid := screen.find_child("Signals", true, false)
	var sig0: Slot = sig_grid.get_child(0) as Slot if sig_grid != null and sig_grid.get_child_count() > 0 else null
	check(sig0 != null and sig0.quality == "rare", "constant combinator signal slot renders rare quality")
	if sig0 != null:
		sig0.clicked.emit(MOUSE_BUTTON_LEFT, false)
	await get_tree().process_frame
	if ui.picker.is_open():
		ui.picker.close()
	var q_ed := screen.find_child("SignalQualityEditor", true, false) as Control
	var sig_unc := q_ed.find_children("*", "Button", true, false).filter(func(b): return (b as Button).tooltip_text == "Uncommon") if q_ed != null else []
	check(q_ed != null and q_ed.visible and not sig_unc.is_empty(), "clicking constant combinator signal opens SignalQualityEditor")
	if not sig_unc.is_empty():
		(sig_unc[0] as Button).pressed.emit()
	var cb_q: Dictionary = sent_one("set_cb").get("cb", {})
	var sig_out: Array = cb_q.get("sections", [{}])[0].get("s", [[]])[0]
	check(sig_out.size() >= 4 and str(sig_out[0]) == "item" and str(sig_out[1]) == "iron-plate"
		and int(sig_out[2]) == 10 and str(sig_out[3]) == "uncommon",
		"picking quality in SignalQualityEditor sends updated signal quality in set_cb: %s" % [cb_q])
	screen.close_local()

	# --- 3. Logistic Networks L window: rename, search, sub-tabs, quality, locate cycling ---
	sent()
	ui.networks.open_network(4)
	m.handle({"t": "lnets", "l": [[4, 1, "nauvis", [10, 12], [5, 6], 2, 1, 1, 2, 2560, 512, "Old Net"]]})
	m.handle({
		"t": "lnet", "id": 4, "found": 1, "log": [10, 12], "con": [5, 6],
		"ch": [3, 2],
		"members": [["roboport", 2], ["requester-chest", 2], ["storage-chest", 1]],
		"items": [["iron-plate", 100, "rare"], ["copper-cable", 50]],
		"req": [["iron-plate", 200, 100, "rare"], ["wood", 10, 0]],
		"transit": [["iron-plate", 25, "rare"]],
	})
	await get_tree().process_frame
	var ch_lbl := ui.networks.find_child("ChargingLabel", true, false) as Label
	check(ch_lbl != null and ch_lbl.visible and ch_lbl.text == "Charging: 3, waiting: 2",
		"L window displays charging and waiting counts")

	# Rename network
	var ren_btn := ui.networks.find_child("Rename", true, false) as Button
	var ren_field := ui.networks.find_child("RenameField", true, false) as LineEdit
	if ren_btn != null:
		ren_btn.pressed.emit()
	check(ren_field != null and ren_field.visible, "Rename button reveals RenameField")
	if ren_field != null:
		ren_field.text = "Base Alpha"
		ren_field.text_submitted.emit("Base Alpha")
	var ren_cmd := sent_one("set_lnet_name")
	check(int(ren_cmd.get("id", 0)) == 4 and str(ren_cmd.get("name", "")) == "Base Alpha",
		"RenameField submits set_lnet_name: %s" % [ren_cmd])

	# Search filtering on Contents tab
	var lnet_search := ui.networks.find_child("SearchBox", true, false) as LineEdit
	check(lnet_search != null, "L window has SearchBox")
	if lnet_search != null:
		lnet_search.text = "iron"
		lnet_search.text_changed.emit("iron")
	await get_tree().process_frame
	var first_item := ui.networks._items.get_child(0) as Slot
	var second_child: Node = ui.networks._items.get_child(1)
	check(first_item != null and first_item.item == "iron-plate" and first_item.quality == "rare"
		and not (second_child is Slot),
		"L window search filters Contents and keeps quality badge")
	if lnet_search != null:
		lnet_search.text = ""
		lnet_search.text_changed.emit("")
	await get_tree().process_frame

	# Requests & In transit sub-tabs
	var req_tab := ui.networks.find_child("RequestsTab", true, false) as Button
	var tr_tab := ui.networks.find_child("TransitTab", true, false) as Button
	if req_tab != null:
		req_tab.pressed.emit()
	await get_tree().process_frame
	var req_s0 := ui.networks._items.get_child(0) as Slot
	var req_s1 := ui.networks._items.get_child(1) as Slot
	check(req_s0 != null and req_s0.item == "iron-plate" and req_s0.quality == "rare" and req_s0.status_tint.a > 0.0
		and req_s1 != null and req_s1.item == "wood" and req_s1.status_tint.a == 0.0,
		"L window Requests tab tints missing requests and leaves fulfilled untinted")

	if tr_tab != null:
		tr_tab.pressed.emit()
	await get_tree().process_frame
	var tr_s0 := ui.networks._items.get_child(0) as Slot
	check(tr_s0 != null and tr_s0.item == "iron-plate" and tr_s0.count == 25 and tr_s0.quality == "rare",
		"L window In transit tab shows transit items and quality badge")

	# Click-to-locate + LocateBar cycling
	sent()
	if tr_s0 != null:
		tr_s0.clicked.emit(MOUSE_BUTTON_LEFT, false)
	var find_cmd := sent_one("lnet_find")
	check(int(find_cmd.get("id", 0)) == 4 and str(find_cmd.get("item", "")) == "iron-plate"
		and str(find_cmd.get("q", "")) == "rare" and str(find_cmd.get("role", "")) == "transit",
		"clicking item in L window sends lnet_find: %s" % [find_cmd])

	var jumped: Array = []
	var on_jump := func(at: Vector2, si: int) -> void: jumped.append([at, si])
	ui.networks.show_at.connect(on_jump)
	m.handle({"t": "lnet_locs", "id": 4, "si": 1, "l": [[512, 256, "requester-chest", 15], [1024, 512, "requester-chest", 10]]})
	await get_tree().process_frame
	var loc_bar := ui.networks.find_child("LocateBar", true, false) as Control
	var loc_cnt := ui.networks.find_child("LocCount", true, false) as Label
	var loc_next := ui.networks.find_child("LocNext", true, false) as Button
	var loc_prev := ui.networks.find_child("LocPrev", true, false) as Button
	check(loc_bar != null and loc_bar.visible and loc_cnt != null and loc_cnt.text == "1 / 2"
		and jumped == [[Vector2(2, 1), 1]], "lnet_locs shows LocateBar 1 / 2 and jumps to first entity")
	if loc_next != null:
		loc_next.pressed.emit()
	check(loc_cnt != null and loc_cnt.text == "2 / 2" and jumped.size() == 2 and jumped[1] == [Vector2(4, 2), 1],
		"LocNext cycles to 2 / 2")
	if loc_prev != null:
		loc_prev.pressed.emit()
	check(loc_cnt != null and loc_cnt.text == "1 / 2" and jumped.size() == 3 and jumped[2] == [Vector2(2, 1), 1],
		"LocPrev cycles back to 1 / 2")
	m.handle({"t": "lnet_locs", "id": 4, "si": 1, "l": {}})
	await get_tree().process_frame
	check(loc_cnt != null and loc_cnt.text == "0 / 0" and loc_prev != null and loc_prev.disabled and loc_next != null and loc_next.disabled,
		"empty {} lnet_locs shows 0 / 0 and disables cycling buttons")
	ui.networks.show_at.disconnect(on_jump)
	ui.networks.open(false)
	await get_tree().process_frame
	ui.player = real_player
	rig_player.queue_free()
	world_holder.queue_free()

	# --- 4. --logistic-status=off switch fallback ---
	Switches.set_test_args(PackedStringArray(["--logistic-status=off"]))
	check(not Switches.on("--logistic-status", true), "--logistic-status=off disables logistic status tint switch")
	var test_slot := Slot.new()
	test_slot.custom_minimum_size = Vector2(40, 40)
	test_slot.size = Vector2(40, 40)
	test_slot.set_logistic_state(-1, Color(1.0, 0.0, 0.0, 1.0))
	add_child(test_slot)
	await get_tree().process_frame
	Switches.set_test_args(PackedStringArray(["--logistic-status=on"]))
	check(Switches.on("--logistic-status", true), "--logistic-status=on re-enables logistic status tint switch")
	test_slot.queue_redraw()
	await get_tree().process_frame
	Switches.reset_cache()
	test_slot.queue_free()

	# --- 5. Edge cases: empty Lua {} dicts & malformed/missing arrays handled cleanly ---
	m.handle({"t": "clog", "on": 1, "trash": 0, "l": {}, "sec": {}, "lgs": {}, "del": {}, "pick": {}})
	m.handle({"t": "lnet", "id": 4, "found": 1, "log": {}, "con": {}, "items": {}, "members": {}, "req": {}, "transit": {}, "ch": {}})
	check(m.char_sections is Array and (m.char_sections as Array).is_empty()
		and m.char_deliver.is_empty() and m.char_pickup.is_empty() and m.logistic_groups.is_empty()
		and m.lnet[4]["items"] is Array and (m.lnet[4]["items"] as Array).is_empty()
		and m.lnet[4]["members"] is Array and m.lnet[4]["req"] is Array and m.lnet[4]["transit"] is Array,
		"empty Lua {} tables in clog and lnet convert cleanly to empty Arrays")
	# Malformed/non-array payloads do not crash Wire.array or UI screens.
	check(Wire.array("bad").is_empty() and Wire.array(123).is_empty() and Wire.array(null).is_empty(),
		"Wire.array safely rejects malformed non-array values")
	m.handle({"t": "lnet", "id": 4, "found": 1, "log": "bad", "con": null, "items": [123, ["iron-plate"]],
		"members": ["bad"], "req": [["only-one"]], "transit": [null], "ch": [1]})
	ui.networks._refresh_details()
	screen.request(910, {"t": "open", "u": 910, "p": 1, "x": 0, "y": 0})
	gui.call("container", {"p": 36, "inv": {}, "slots": {}, "lg": {"mode": "requester"},
		"lc": {"tu": 0, "rb": 0, "sec": {}, "del": "bad", "pick": null}})
	await get_tree().process_frame
	check(screen.is_open(), "malformed/empty lc and lnet payloads render cleanly without crash")
	screen.close_local()

	# Restore shared test state.
	ui.close_all()
	screen.protos = old_protos
	m.planners.qualities = had_quals
	m.lnet.erase(4)
	m.lnets.clear()
	m.handle({"t": "clog", "on": 1, "trash": 0, "l": []})
	sent()

