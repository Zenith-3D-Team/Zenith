extends "res://tests/ui_test_base.gd"
## UI test sections: hud.

func _hud(hud: Hud, player: Node) -> void:
	var ui = hud.ui
	var m = ui.model
	ui.close_all()
	ui.open_map(false)
	player.cursor_item = ""
	ui.hand = {}
	sent()
	for i in 3:
		await get_tree().process_frame

	# --- top right: research, side menu, minimap ------------------------------------------------
	var view: Vector2 = ui.size
	var menu: Rect2 = ui.side_menu.get_global_rect()
	check(is_equal_approx(menu.end.x, view.x) and is_zero_approx(menu.position.y), "the side menu sits flush in the top-right corner: %s" % menu)
	check(is_equal_approx(menu.size.x, Kit.px(256)), "it is slot_window_frame's 8 + 240 + 8 wide: %s" % menu.size.x)
	check(menu.encloses(ui.research_hud.get_global_rect()), "the research panel is in it")
	check(not ui.minimap.visible or menu.encloses(ui.minimap.get_global_rect().grow(-0.5)), "the minimap sits in it, under the buttons")
	check(ui.research_hud.get_global_rect().end.y < ui.minimap.get_global_rect().position.y, "research above the minimap")
	if ui.minimap.visible:  # owner's #7: the frame sat up and to the left of its place
		var slot_rect: Rect2 = ui.side_menu.minimap_slot.get_global_rect()
		var map_rect: Rect2 = ui.minimap._frame.get_global_rect()
		check(map_rect.size.x == ui.minimap.side_px() and ui.minimap.size == map_rect.size, "the minimap's Control is its frame's size: %s, %s" % [ui.minimap.size, map_rect])
		check(absf(map_rect.get_center().x - slot_rect.get_center().x) <= 1.0 and is_equal_approx(map_rect.position.y, slot_rect.position.y)
			and is_equal_approx(map_rect.size.y, slot_rect.size.y), "the minimap fills its place in the side menu: %s in %s" % [map_rect, slot_rect])
	check(ui.entity_info.global_position.y >= menu.end.y, "the entity info goes under the side menu")
	check(ui.side_menu.button("production") != null and ui.side_menu.button("mute") != null and SideMenu.BUTTONS.size() == 10,
		"Factorio's ten side menu buttons")
	ui._on_side_button("production")
	await get_tree().process_frame
	check(ui.stats.is_open() and sent_one("stats").get("kind") == "item", "the production button opens production statistics")
	ui.stats.visible = false
	ui._on_side_button("logistic_networks")
	check(ui.networks.is_open(), "the logistic networks button opens them")
	ui.networks.open(false)
	var was_on := bool(FxSettings.enabled.get("master", true))
	ui._on_side_button("mute")
	check(bool(FxSettings.enabled.get("master", true)) != was_on, "the speaker button mutes all sounds")
	await get_tree().process_frame
	check(ui.side_menu.button("mute").has_meta("muted") == was_on, "and shows the muted speaker")
	ui._on_side_button("mute")
	check(bool(FxSettings.enabled.get("master", true)) == was_on, "and unmutes them")
	var tip = ui.side_menu.button("production")._make_custom_tooltip("Production statistics (P)")
	check(tip != null and _texts(tip).has("P") and _texts(tip).has("Production statistics"), "side buttons have Factorio's tooltip, the key apart: %s" % [_texts(tip) if tip != null else []])
	if tip != null:
		tip.free()

	var saved_techs: Dictionary = m.techs.duplicate(true)
	var tech := {"order": "a", "prerequisites": [], "ingredients": [], "count": 10, "seconds": 10.0, "state": 1, "trigger": "",
		"effects": [], "level": 1, "max_level": 1, "trigger_detail": [], "saved": 0.0, "formula": ""}
	m.techs["automation"] = tech.duplicate()
	m.handle({"t": "rs", "cur": "automation", "pr": 100, "q": []})
	m.handle({"t": "rs", "cur": "", "pr": 0, "q": []})  # cancelled, not finished
	await get_tree().process_frame
	var r = ui.research_hud
	check(r._hint.visible and "".join(_texts(r._hint)).begins_with("Press T to start"), "no research: \"Press T to start a new research.\": %s" % [_texts(r._hint)])
	m.handle({"t": "rs", "cur": "automation", "pr": 370, "q": []})
	await get_tree().process_frame
	check(not r._hint.visible and r._name.visible and r._percent.text == "37%", "researching: the name, the bar and the percentage: %s" % r._percent.text)
	m.techs["automation"]["state"] = 2
	m.handle({"t": "rs", "cur": "", "pr": 0, "q": []})
	await get_tree().process_frame
	check(r.finished == "automation" and r._name.text.ends_with("finished. Press T.") and r._percent.text == "100%",
		"a finished research says so until the next starts: %s" % r._name.text)
	m.handle({"t": "rs", "cur": "automation", "pr": 0, "q": []})
	check(r.finished == "", "the next research clears it")
	m.techs["automation"]["ingredients"] = [["automation-science-pack", 1]]
	var now := Time.get_ticks_msec()
	r._samples.clear()
	r.note_progress(now - 30000, "automation", 2.0)
	r.note_progress(now - 10, "automation", 4.0)
	var rtip = r._make_custom_tooltip("Technologies (T)")
	var rtexts: Array = _texts(rtip)
	check(rtexts.has("Science production information") and rtexts.has("Progress:") and rtexts.has("× 10")
		and rtexts.has("Science per minute:"), "the research tooltip is Factorio's science production information: %s" % [rtexts])
	check(absf(r.rate_now("automation") - 4.0) < 0.1, "science per minute from the progress seen: %s" % r.rate_now("automation"))
	check(r.duration(1446) == "24m6s", "Factorio's remaining time format")
	rtip.free()
	m.techs.clear()
	m.techs.merge(saved_techs)

	# --- the shortcut bar: every shortcut, the chooser -------------------------------------------
	var bar = ui.shortcuts
	for name in ["import", "book", "green-wire", "red-wire"]:
		check(bar.button(name) != null, "Factorio's %s shortcut is on the bar" % name)
	check(not bar.button("spidertron").visible and not bar.button("artillery").visible, "the remotes stay off the bar until researched")
	bar.update_unlocks({"spidertron": {"state": 2}})
	check(bar.button("spidertron").visible, "a researched remote shows")
	bar.update_unlocks(m.techs)
	bar._expand.button_pressed = true
	await get_tree().process_frame
	check(bar.chooser_open() and bar._expand.button_pressed, "the ⋮ button opens the shortcut chooser")
	var copy_box: CheckBox = bar._rows["copy"][1]
	check(copy_box.button_pressed and bar._rows["artillery"][1].disabled, "rows: ticked when shown, greyed out when not researched")
	var shown: int = bar.shown_count()
	copy_box.button_pressed = false
	await get_tree().process_frame
	check(not bar.button("copy").visible and bar.shown_count() == shown - 1, "unticking a shortcut takes it off the bar")
	var hidden = Settings.get_value("interface", "hidden_shortcuts")
	check(hidden is Array and (hidden as Array).has("copy"), "and the choice is kept in the settings")
	copy_box.button_pressed = true
	check(bar.button("copy").visible, "ticking it puts it back")
	bar._filter("wire")
	check(bar._rows["red-wire"][0].visible and not bar._rows["undo"][0].visible, "the chooser's search filters its rows")
	bar._filter("")
	key(KEY_ESCAPE)
	await get_tree().process_frame
	check(not bar.chooser_open(), "Esc closes the chooser")
	ui._on_shortcut("import")
	check(ui.planners._string_box.visible and ui.planners._string_mode == "import", "Import string opens the import box")
	ui.planners._string_box.visible = false
	# Owner: no see-through fade of trees and buildings in the way (the tall-entities toggle is gone).
	check(bar.button("tall") == null and not Settings.DEFAULTS["interface"].has("hide_tall")
		and not FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc").contains("f3d_fade"),
		"no tall-entities fade: no shortcut, no setting, nothing in the model shader")
	var order: Array = []
	for sc in bar.SHORTCUTS:
		order.append(str(sc[0]))
	check(order.slice(order.find("upgrade"), order.find("red-wire") + 1) == ["upgrade", "roboport", "exoskeleton", "copper-wire", "green-wire", "red-wire"],
		"the shortcuts in Factorio's order: planners, the equipment toggles, copper, green, red wire: %s" % [order])
	check(bar.button("red-wire").theme_type_variation == "FPageButton" and bar.button("green-wire").theme_type_variation == "FPageButton",
		"the wire shortcuts are plain grey buttons, as Factorio's")
	# The fake player has PlayerInput's undo and redo stacks.
	(ui.player.get("_redo") as Array).append({"t": "rotate"})
	await get_tree().process_frame
	var redo_lit: bool = not bar.button("redo").disabled
	(ui.player.get("_redo") as Array).clear()
	await get_tree().process_frame
	check(redo_lit and bar.button("redo").disabled, "redo is greyed with nothing to redo, lit with something")
	sent()

	# --- the side menu's windows: bonuses, achievements, alerts settings, tips and tricks ---------
	for which in ["bonuses", "achievements", "alerts", "tips"]:
		ui._on_side_button(which)
		await get_tree().process_frame
		var w = {"bonuses": ui.bonuses, "achievements": ui.achievements, "alerts": ui.alerts_config, "tips": ui.tips}[which]
		check(w.is_open(), "the side menu's %s button opens its window" % which)
		ui._on_side_button(which)
		check(not w.is_open(), "and closes it again")
	ui.open_global("bonuses")
	ui.open_global("tips")
	check(ui.tips.is_open() and not ui.bonuses.is_open(), "one game-wide window at a time")
	if not ui.tips.tips().is_empty():
		var first := str(ui.tips.tips()[0][0])
		ui.tips.select(first)
		check(ui.tips.find_child("Tip_" + first, true, false) != null and ui.tips.selected == first, "a tip is listed and can be selected")
	else:
		print("skip selecting a tip: no Factorio install (the tips come from it)")
	ui.close_all()
	check(not ui.tips.is_open(), "Esc / close_all closes the tips")
	ui.chat.console.run("/permissions")
	check(ui.permissions.is_open(), "/permissions opens the permissions window, as in Factorio")
	ui.close_all()

	# --- quickbar tooltips, the ammo bar, the minimap's hover ---------------------------------------
	var qslot = ui.quickbar._slots[0]
	ui.quickbar._show(qslot, "iron-plate", "1")
	var qtip = qslot._make_custom_tooltip("")
	var qtexts: Array = _texts(qtip)
	check(qtexts.has("Middle-click") and qtexts.has(" to clear shortcut."), "a pinned quickbar slot's tooltip: the item, then \"Middle-click to clear shortcut.\": %s" % [qtexts])
	qtip.free()
	ui.quickbar._show(qslot, "", "1")
	check(qslot._make_custom_tooltip("") == null, "an empty quickbar slot has no tooltip, as Factorio's")
	m.quickbar[3] = "iron-plate"
	ui._on_quickbar_clicked(3, MOUSE_BUTTON_MIDDLE)
	check(sent().any(func(c) -> bool: return str(c.get("t", "")) == "qb_set") or str(m.quickbar[3]) == "", "middle-click clears a quickbar slot")
	m.set_guns(1, [["pistol", "firearm-magazine", 10, 4, 10], ["", "", 0, 0, 0], ["", "", 0, 0, 0]])
	await get_tree().process_frame
	var ammo_slot = ui.weapons._ammo[0]
	check(is_equal_approx(ammo_slot.ammo_bar, 0.4) and ammo_slot.tip_lines[0][0] == "Ammo: 4/10",
		"the ammo slot's green bar and \"Ammo: 4/10\" from the magazine's rounds: %s %s" % [ammo_slot.ammo_bar, ammo_slot.tip_lines])
	m.set_guns(1, [["pistol", "firearm-magazine", 10, 10, 10], ["", "", 0, 0, 0], ["", "", 0, 0, 0]])
	await get_tree().process_frame
	check(ammo_slot.ammo_bar >= 1.0, "a full magazine has no bar")
	var mtip = ui.minimap._area._make_custom_tooltip(ui.minimap._area.tooltip_text)
	var mtexts: Array = []
	for row in mtip.get_children():
		mtexts += _texts(row)
	check(mtexts.has("Map") and mtexts.has("Shift + Mouse wheel"), "the minimap's tooltip: Map (M) and Shift + Mouse wheel to zoom: %s" % [mtexts])
	mtip.free()
	var zoom_was := float(ui.minimap.settings.get_value("map/minimap_zoom"))
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	ui.minimap._on_area_input(wheel)
	check(is_equal_approx(float(ui.minimap.settings.get_value("map/minimap_zoom")), zoom_was), "the wheel alone doesn't zoom the minimap")
	wheel.shift_pressed = true
	ui.minimap._on_area_input(wheel)
	check(float(ui.minimap.settings.get_value("map/minimap_zoom")) > zoom_was, "Shift + wheel does")
	ui.minimap.settings.set_value("map/minimap_zoom", zoom_was)
	check(ui.minimap.find_children("*", "BaseButton", true, false).is_empty(), "the minimap has no zoom buttons, as Factorio's")

	# --- the character's logistic sections and colour -----------------------------------------------
	m.handle({"t": "clog", "on": 1, "trash": 0, "l": [["iron-plate", 100, -1]], "lgs": ["Main"],
		"sec": [{"i": 1, "g": "Main", "on": 1, "m": 1, "man": 1, "f": [["iron-plate", "normal", 100, -1, "", -1]]},
			{"i": 2, "g": "", "on": 0, "m": 1, "man": 1, "f": []}]})
	m.handle({"t": "ccol", "c": [10, 20, 200]})
	ui.window.open_crafting(true)
	ui.window.show_tab("Logistics")  # J7: the right half's second tab
	await get_tree().process_frame
	await get_tree().process_frame
	var lg = ui.window._logistics
	var secs = lg.find_child("Sections", true, false)
	check(secs != null and _all_texts(secs).has("Main") and _all_texts(secs).has("[No group assigned]") and _all_texts(secs).has("Add section"),
		"the character's logistics show each section with its group, and Add section: %s" % [_all_texts(secs) if secs != null else []])
	sent()
	var add_button: Button = null
	for b in secs.find_children("*", "Button", true, false):
		if (b as Button).text == "Add section":
			add_button = b
	add_button.pressed.emit()
	var add_cmd := sent_one("set_section")
	check(add_cmd.get("u") == 0 and add_cmd.get("i") == 0, "Add section sends set_section for the character (u 0): %s" % add_cmd)
	var swatch: ColorPickerButton = ui.window.find_child("ColorSwatch", true, false)
	check(swatch != null and swatch.color.is_equal_approx(Color8(10, 20, 200)), "the colour button shows the character's colour (ccol)")
	swatch.color = Color8(255, 0, 0)
	swatch.popup_closed.emit()
	var col_cmd := sent_one("set_char_color")
	check(col_cmd.get("c") == [255.0, 0.0, 0.0] or col_cmd.get("c") == [255, 0, 0], "a colour picked goes to the bridge: %s" % col_cmd)
	ui.close_all()

	# --- the quickbar's page chooser --------------------------------------------------------------
	var qb = ui.quickbar
	# As in Factorio, the page in use (keys 1-0) is the top row, the second page below it; their
	# page buttons the same way round (it was the bottom row).
	var top_row: Control = qb._slots[0].get_parent()
	var second_row: Control = qb._second[0].get_parent()
	check(top_row.get_index() == 0 and second_row.get_index() == 1 and qb._pages[1].get_index() == 0
		and qb._pages[0].get_index() == 1 and top_row.get_global_rect().position.y < second_row.get_global_rect().position.y,
		"the quickbar's page in use is its top row, as in Factorio: %s %s" % [top_row.get_global_rect(), second_row.get_global_rect()])
	qb._pages[0].pressed.emit()
	await get_tree().process_frame
	check(qb.chooser_open() and qb._chooser_row == 0, "a page button opens the page chooser for its row")
	check(qb._chooser_pages.size() == 10 and str(qb._chooser_pages[10].text) == "0", "ten pages, 0 for the tenth")
	await get_tree().process_frame
	var cr: Rect2 = qb.chooser.get_global_rect()
	var fr: Rect2 = qb.frame.get_global_rect()
	check(is_equal_approx(cr.position.x, fr.position.x) and (cr.end.y <= fr.position.y + 0.5 or is_zero_approx(cr.position.y)),
		"the chooser sits over the quickbar, on its left edge (or at the top when there's no room): %s %s" % [cr, fr])
	qb.pick_page(7)
	check(m.quickbar_upper_page() == 7 and not qb.chooser_open(), "picking a page shows it in that row and closes the chooser")
	check(str(qb._pages[0].text) == "7", "the second row's button says 7")
	qb.open_chooser(1, true)
	qb.pick_page(4)
	check(not m.server_quickbar or sent_one("qb_page").get("p") == 4, "the top row (the page in use) asks the mod for its page")
	m.quickbar_upper = 0
	qb.refresh()
	qb.open_chooser(1, true)
	key(KEY_ESCAPE)
	await get_tree().process_frame
	check(not qb.chooser_open(), "Esc closes the page chooser")
	sent()

	# --- the character screen ----------------------------------------------------------------------
	ui.window.open_crafting(true)
	await get_tree().process_frame
	await get_tree().process_frame
	var w = ui.window
	check(not w._sort_button.visible, "no sort button: Factorio 2.1 sorts by itself")
	var color_buttons := _all_buttons(w._char_frame).filter(func(b: Button) -> bool: return b.tooltip_text == "Color" and b.is_visible_in_tree())
	check(color_buttons.size() == 2, "the colour picker and colour buttons over the inventory")
	check(w._stripes.is_visible_in_tree(), "the empty striped rows under the slots")
	var crafting = w._crafting
	check(crafting.search.get_parent() is HBoxContainer and crafting.search.get_parent() != crafting, "the recipe search sits in Crafting's title bar")
	check(crafting._tabs.columns <= CraftingPanel.TABS_PER_ROW, "group tabs wrap at five a row")
	if m.has_signal("logistics_changed"):
		m.set("char_requests", [{"item": "iron-plate", "min": 50, "max": -1}])
		m.set("char_requests_on", true)
		m.set("char_logistics", true)
		w.show_tab("Logistics")
		w._logistics_sig = "-"
		w._refresh_logistics()
		check(_find_checkbox(w._logistics, "Personal logistics") != null and _find_checkbox(w._logistics, "Trash unrequested") != null,
			"Personal logistics and Trash unrequested, Factorio's labels")
		check(_find_button(w._logistics, "Add section") != null and _texts(w._logistics).has("Main"), "the Main section and Add section")
	ui.close_all()

	# --- recipe tooltips, chat ----------------------------------------------------------------------
	var lines: Array = CraftingPanel.recipe_tip_lines(m, {"ingredients": [["iron-plate", 2]], "energy": 0.5,
		"products": [["iron-gear-wheel", 1]]})
	var heads := lines.map(func(l: Array) -> String: return str(l[0]))
	check(heads.has("Ingredients:") and heads.has("Products:") and heads.any(func(t: String) -> bool: return t.ends_with("Crafting time")),
		"Factorio's recipe tooltip: ingredients, crafting time, products: %s" % [heads])
	ui.chat.open()
	await get_tree().process_frame
	check(ui.chat.backdrop_shown and ui.chat._input.placeholder_text == "", "the open console: a dark backdrop, a plain input line")
	check(ui.chat.get_global_rect().end.x >= ui.quickbar.frame.get_global_rect().end.x - 1.0, "as wide as the HUD up to the quickbar's right edge")
	ui.chat.close()
	await get_tree().process_frame
	check(not ui.chat.backdrop_shown, "closed: no backdrop")
	sent()


## The information windows: the alert bar (`al`: buttons, counts, tooltips, clicking through the
## entities, icons in the world), Factoriopedia (F2, Alt+click, the index's tabs and grid, pages,
## links, history), item tooltips' stats, the logistic networks window (L), the statistics' tabs,
## surfaces and graphs, rich text in the chat (icons, colours, gps links and pings) and the
## technology screen's details (effects, trigger tasks, infinite levels).


func _info(hud: Hud, player: Node) -> void:
	var ui = hud.ui
	var m = ui.model
	ui.close_all()
	player.cursor_item = ""
	sent()

	# --- alerts -----------------------------------------------------------------------------------
	m.handle({"t": "al", "l": [["no_ammo", 3, [[2560, 0, 1, "gun-turret", 11], [5120, 0, 1, "gun-turret", 12]]],
		["no_material", 1, [[0, 2560, 1, "transport-belt", 13, "transport-belt"]]],
		["output_full", 929, [[7680, 0, 1, "assembling-machine-1", 14]]]]})
	for i in 2:
		await get_tree().process_frame
	var ammo: Button = ui.alerts._buttons.get("no_ammo")
	check(ammo != null and ammo.visible and ammo.get("count") == 3 and ammo.text == "" and ui.alerts._buttons.has("no_material")
		and (ammo.get("picture") != null or GuiAssets.core_sprite("icons/alerts/ammo-icon-red.png") == null),
		"al: a button per kind of alert, with its picture and its count drawn in the corner (not Godot's text over the icon)")
	var full: Button = ui.alerts._buttons.get("output_full")
	check((full == null or not full.visible) and not ui.alerts._lists.has("output_full"),
		"output full (not a Factorio alert) is left off the bar by default")
	var tip: Array = ui.alerts.tooltip_lines("no_ammo")
	check(str(tip[0][0]) == "3 turrets just ran out of ammunition." and str(tip[1][0]).ends_with("× 2") and str(tip[1][1]) == "gun-turret"
		and str(tip[2][0]) == "and 1 more", "the alert's tooltip says it in Factorio's words and lists the entities: %s" % [tip])
	check(str(ui.alerts.tooltip_lines("no_material")[1][0]).contains("needs"), "a ghost's alert says what it needs")
	var looked: Array = []
	var catch := func(at: Vector2) -> void: looked.append(at)
	ui.alerts.show_at.connect(catch)
	ammo.pressed.emit()
	ammo.pressed.emit()
	ammo.pressed.emit()
	ui.alerts.show_at.disconnect(catch)
	check(looked == [Vector2(10, 0), Vector2(20, 0), Vector2(10, 0)], "clicking an alert looks at its entities one after another: %s" % [looked])
	check(ui.alerts._icons != null and ui.alerts._icons.shown.get("no_ammo") == 2 and ui.alerts._icons.shown.get("no_material") == 1,
		"alert icons over the entities in the world: %s" % [ui.alerts._icons.shown if ui.alerts._icons != null else null])
	# Owner's G19: icons only over entities the 3D world holds. The mod's lists are seconds old, so a
	# building mined since (or one on a surface the world doesn't show) left its icon on empty ground.
	var fake_world := GDScript.new()
	fake_world.source_code = "extends RefCounted\nvar entities := {}\n"
	fake_world.reload()
	var fake_movers := GDScript.new()
	fake_movers.source_code = "extends RefCounted\nfunc position_of(unit: int) -> Variant:\n\treturn Vector3(30, 0, 4) if unit == 77 else null\n"
	fake_movers.reload()
	var icons = ui.alerts._icons
	var fw = fake_world.new()
	var turret_rec := WorldMirror.Rec.new()
	turret_rec.key = 11
	turret_rec.unit = 11
	turret_rec.pos = Vector2(10, 0)
	fw.entities[11] = turret_rec
	icons.world = fw
	icons.movers = fake_movers.new()
	m.handle({"t": "al", "l": [["no_ammo", 2, [[2560, 0, 1, "gun-turret", 11], [5120, 0, 1, "gun-turret", 12]]],
		["no_fuel", 1, [[9000, 9000, 1, "burner-mining-drill", 99]]],
		["train_fuel", 1, [[7680, 1024, 1, "locomotive", 77, "5"]]]]})
	await get_tree().process_frame
	check(icons.shown.get("no_ammo") == 1 and icons.shown.get("no_fuel") == 0 and icons.shown.get("train_fuel") == 1,
		"alert icons are drawn only over entities the world has (a mined drill's goes, a train's follows its locomotive): %s" % [icons.shown])
	check(icons.placed.get("train_fuel", []).size() == 1 and (icons.placed["train_fuel"][0] as Vector3).x == 30.0,
		"the train's icon is over the locomotive where it is drawn: %s" % [icons.placed.get("train_fuel")])
	var fuel_button = ui.alerts._buttons.get("no_fuel")
	check((fuel_button == null or not fuel_button.visible) and icons.shown.has("no_fuel"),
		"no fuel is an icon over the entity, not on the alert bar, as in Factorio (H5)")
	# Owner: low power over random machines. Factorio draws its blinking no-power icon only for no
	# power; a brownout (low_power) has no icon, nor does `pw`'s "not connected" (the alerts' unplugged
	# icon covers it). Factorio draws the 64-pixel picture at half size: one tile.
	var pwld := WorldMirror.new()
	for u in [41, 42, 43]:
		var prec := WorldMirror.Rec.new()
		prec.key = u
		prec.unit = u
		prec.pos = Vector2(u, 0)
		pwld.entities[u] = prec
	var power := FluidsPowerScript.new()
	add_child(power)
	power.world = pwld
	power.handle({"t": "pw", "k": 7, "part": 1, "parts": 1, "l": [41, 0, 42, 1, 43, 2]})
	await get_tree().process_frame
	var picon: Transform3D = power.icon_spots[0] if power.icon_spots.size() > 0 else Transform3D()
	check(power.icon_count() == 1 and is_equal_approx(picon.origin.x, 41.0) and is_equal_approx(picon.basis.x.length(), 1.0)
		and power.power_state(42) == FluidsPowerScript.LOW_POWER and power.has_no_power(43),
		"the no-power icon only over the machine with no power, one tile wide; low power and not connected get none: %d %s %s" % [power.icon_count(), picon, power.unpowered])
	power.world = null
	power.queue_free()
	pwld.free()
	# Alerts over tall/animated models, ghosts and inserters sit above the full model height (body + parts + arm).
	var pj_name := "pumpjack@builtin:placeholders"
	var pj_mesh: Mesh = ModelLibrary.mesh_for(pj_name)
	var pj_top := ModelLibrary.top_for(pj_name)
	check(pj_mesh != null and pj_top > pj_mesh.get_aabb().end.y + 1.5,
		"model_library records full animated model top above static body for pumpjack: top=%.2f static=%.2f"
		% [pj_top, pj_mesh.get_aabb().end.y if pj_mesh != null else -1.0])
	var aw := WorldMirror.new()
	aw.protos.add_entities([
		[101, "pumpjack", "mining-drill", -1.5, -1.5, 1.5, 1.5, 120, 120, 120, 3, 3],
		[102, "entity-ghost", "entity-ghost", -1.5, -1.5, 1.5, 1.5, 120, 120, 120, 3, 3],
		[103, "inserter", "inserter", -0.4, -0.4, 0.4, 0.4, 200, 160, 40, 1, 1],
		[104, "test-delayed-model", "container", -0.5, -0.5, 0.5, 0.5, 100, 100, 100, 1, 1],
	])
	var apj := WorldMirror.Rec.new()
	apj.key = 501
	apj.unit = 501
	apj.proto_id = 101
	apj.pos = Vector2(5, 6)
	apj.extra = {ModelLibrary.PACK_KEY: "builtin:placeholders"}
	var agh := WorldMirror.Rec.new()
	agh.key = 503
	agh.unit = 503
	agh.proto_id = 102
	agh.pos = Vector2(9, 6)
	agh.extra = {"gh": 101, ModelLibrary.PACK_KEY: "builtin:placeholders"}
	var ains := WorldMirror.Rec.new()
	ains.key = 504
	ains.unit = 504
	ains.proto_id = 103
	ains.pos = Vector2(12, 6)
	var adel := WorldMirror.Rec.new()
	adel.key = 502
	adel.unit = 502
	adel.proto_id = 104
	adel.pos = Vector2(15, 6)
	aw.entities[501] = apj
	aw.entities[503] = agh
	aw.entities[504] = ains
	aw.entities[502] = adel
	var apower := FluidsPowerScript.new()
	add_child(apower)
	apower.world = aw
	apower.handle({"t": "pw", "k": 1, "part": 1, "parts": 1, "l": [501, 0]})
	await get_tree().process_frame
	var apicon: Transform3D = apower.icon_spots[0] if apower.icon_spots.size() > 0 else Transform3D()
	var ghost_top := apower.entity_top(agh)
	var ins_top := apower.entity_top(ains)
	check(is_equal_approx(apower.entity_top(apj), pj_top)
		and apicon.origin.y - 0.5 * FluidsPowerScript.ICON_SIZE > pj_top
		and is_equal_approx(ghost_top, pj_top) and ins_top >= 1.15,
		"no-power icons, ghosts and inserters clear the full animated model height: pj=%.2f icon_y=%.2f ghost=%.2f ins=%.2f"
		% [pj_top, apicon.origin.y, ghost_top, ins_top])
	var aicons := AlertIconsScript.new()
	add_child(aicons)
	aicons.world = aw
	aicons.show_alerts({"no_fuel": [{"position": Vector2(5, 6), "si": 1, "unit": 501}],
		"depleted": [{"position": Vector2(15, 6), "si": 1, "unit": 502}]}, 1)
	var nf_y := (aicons.placed["no_fuel"][0] as Vector3).y
	var dep_before := (aicons.placed["depleted"][0] as Vector3).y
	adel.proto_id = 101
	adel.extra = {ModelLibrary.PACK_KEY: "builtin:placeholders"}
	ModelLibrary.generation += 1
	aicons._process(0.016)
	var dep_after := (aicons.placed["depleted"][0] as Vector3).y
	check(nf_y - 0.5 * AlertIconsScript.SIZE > pj_top and dep_after > dep_before + 1.5,
		"AlertIcons clears animated parts and refreshes when ModelLibrary.generation advances: nf=%.2f dep %.2f->%.2f"
		% [nf_y, dep_before, dep_after])
	aicons.world = null
	aicons.queue_free()
	apower.world = null
	apower.queue_free()
	aw.free()
	var ModelSkinScript = load("res://scripts/world/model_skin.gd")
	var bimg := Image.create_empty(9, 2, false, Image.FORMAT_RGBAF)
	for f in 2:
		bimg.set_pixel(0 * 3 + 1, f, Color(0.0, 1.0, 0.0, 0.0))
		bimg.set_pixel(1 * 3 + 1, f, Color(0.0, 1.0, 0.0, 1.5 if f == 1 else 0.0))
		bimg.set_pixel(2 * 3 + 1, f, Color(0.0, 0.0, -1.0, 0.3) if f == 1 else Color(0.0, 1.0, 0.0, 0.0))
	var barr := []
	barr.resize(Mesh.ARRAY_MAX)
	barr[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0.0, 0.5, 0.0), Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.3, -0.2)])
	barr[Mesh.ARRAY_CUSTOM3] = PackedFloat32Array([0.999, 0.0, 0.0, 0.0, 1.999, 0.0, 0.0, 0.0, 2.999, 0.0, 0.0, 0.0])
	var peak := float(ModelSkinScript.peak_y({"image": bimg, "frames": 2, "joints": 3}, [[[], barr, 0]]))
	check(absf(peak - 2.5) < 0.05, "ModelSkin.peak_y measures tight animated bone peak without box inflation: %.3f" % peak)
	icons.world = null
	icons.movers = null
	# Owner's #18: an alert on another surface opens that surface's map, centred on it.
	var si_was: int = m.character_si
	m.character_si = 1
	m.handle({"t": "al", "l": [["no_ammo", 1, [[40 * 256, 8 * 256, 3, "gun-turret", 21]]]]})
	await get_tree().process_frame
	ui.alerts._buttons.get("no_ammo").pressed.emit()
	check(ui.map_open() and m.map_si == 3 and ui.map_view.centre == Vector2(40, 8) and not ui.map_view.following,
		"clicking an alert on another surface shows it on that surface's map: si %d at %s" % [m.map_si, ui.map_view.centre])
	ui.open_map(false)
	m.character_si = si_was
	m.handle({"t": "al", "l": []})
	await get_tree().process_frame
	check(not ammo.visible and ui.alerts._icons.shown.get("no_ammo") == 0, "alerts that ended go away")

	# --- Factoriopedia ----------------------------------------------------------------------------
	sent()
	key(KEY_F2)
	await get_tree().process_frame
	check(ui.pedia.is_open() and sent().any(func(c) -> bool: return c.get("t") == "pedia_index"), "F2 opens Factoriopedia and asks for its index")
	m.handle({"t": "pidx", "part": 1, "parts": 2, "g": [["logistics", "a"], ["intermediate-products", "c"], ["technologies", "zzz"]],
		"l": [["item", "transport-belt", "logistics", "belt", "a"], ["item", "wooden-chest", "logistics", "storage", "a"]]})
	m.handle({"t": "pidx", "part": 2, "parts": 2, "l": [["item", "iron-plate", "intermediate-products", "raw-material", "a"],
		["recipe", "basic-oil-processing", "intermediate-products", "fluid-recipes", "a"], ["technology", "automation", "technologies", "technologies", "a"]]})
	await get_tree().process_frame
	var tab_buttons: Array = ui.pedia._tabs.get_children().filter(func(c) -> bool: return c is Button)
	check(m.pedia_index.size() == 5 and tab_buttons.size() == 2 and ui.pedia._tabs.get_child_count() == 6 and ui.pedia.grid_rows().size() == 2
		and ui.pedia.grid_rows()[0].get_child_count() == 10,
		"the index's groups are tabs (technologies have none; the row filled), the group's things rows by subgroup, ten wide (%d tabs, %d rows)" % [tab_buttons.size(), ui.pedia.grid_rows().size()])
	ui.pedia._search.text = "iron"
	ui.pedia._fill_grid()
	check(ui.pedia.grid_rows().size() == 1 and ui.pedia.row_things(ui.pedia.grid_rows()[0]).size() == 1, "search finds things across every group")
	ui.pedia._search.text = ""
	ui.pedia._fill_grid()
	ui.open_pedia("entity", "transport-belt")
	check(ui.pedia.kind == "item" and ui.pedia.thing == "transport-belt" and m._pedia_asked.has("item/transport-belt"),
		"an entity an item builds opens the item's page (as Factoriopedia does), asked for: %s" % [m._pedia_asked.keys()])
	m.handle({"t": "pedia", "kind": "item", "name": "transport-belt", "found": 1, "d": {"stack": 100, "made": ["transport-belt"],
		"used": ["fast-transport-belt", "underground-belt"], "entity": {"type": "transport-belt", "hp": 150, "belt": 15, "res": [["fire", 0, 90]]}}})
	m.handle({"t": "pedia", "kind": "recipe", "name": "transport-belt", "found": 1, "d": {"ing": [["item", "iron-plate", 1], ["item", "iron-gear-wheel", 1]],
		"prod": [["item", "transport-belt", 2]], "time": 0.5, "made_in": ["assembling-machine-1"], "unlocked": ["logistics"]}})
	for i in 3:
		await get_tree().process_frame
	var texts: Array = _texts(ui.pedia._page)
	check(texts.has("Stack size:") and texts.has(" 100") and texts.has("Speed:") and texts.has("Base health:") and texts.has("Used in")
		and texts.has("Ingredients") and texts.has("Products") and texts.has("Made in") and texts.has("0.5 s") and texts.has(" Crafting time")
		and texts.has("Iron gear wheel") and texts.has("Resistances") and ui.pedia._page_title.text == "Transport belt (Recipe/Item/Entity)",
		"the page as Factoriopedia's: title with every kind, stats box, Ingredients / time / Products, Made in, Used in: %s %s" % [ui.pedia._page_title.text, texts])
	check(ui.pedia._page.find_child("Tech_logistics", true, false) != null, "Unlocked by shows the technology's card")
	var links: Array = []
	_collect(ui.pedia._page, links)
	var used: Array = links.filter(func(b) -> bool: return b.thing == "underground-belt")
	check(not used.is_empty(), "what it's used in links to those pages")
	if not used.is_empty():
		used[0].pressed.emit()
	check(ui.pedia.thing == "underground-belt" and not ui.pedia._back.disabled, "a link opens its page; back is possible")
	ui.pedia._back.pressed.emit()
	check(ui.pedia.thing == "transport-belt" and not ui.pedia._forward.disabled, "back goes to the last page, forward is possible")
	m.handle({"t": "pedia", "kind": "item", "name": "coal", "found": 1, "d": {"stack": 50, "fuel": 4000000, "fcat": ["chemical"]}})
	var info: Array = ui.item_info("coal")
	check(info.has(["Fuel value: 4 MJ"]) and info.has(["Stack size: 50"]), "item tooltips get Factorio's stats (fuel value, stack size): %s" % [info])
	key(KEY_F2)
	await get_tree().process_frame
	check(not ui.pedia.is_open(), "F2 again closes it")
	# Alt+click on an inventory slot opens its page.
	hud.set_inventory([["iron-plate", 60]])
	ui.toggle_inventory()
	await get_tree().process_frame
	await get_tree().process_frame
	var slot: Control = _find_slot_item(ui.window, "iron-plate")
	if slot != null:
		# What _input does with the hovered control (the GUI's hover itself isn't reliable in a
		# headless run: it depended on what earlier sections did).
		check(ui.alt_click(slot), "Alt+click on a slot is taken")
		await get_tree().process_frame
	check(slot != null and ui.pedia.is_open() and ui.pedia.thing == "iron-plate" and player.cursor_item == "",
		"Alt+click on an inventory slot opens its Factoriopedia page (and picks nothing up)")
	ui.close_all()

	# --- logistic networks (L) --------------------------------------------------------------------
	# A player with a camera rig, so the remote view can start.
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
	key(KEY_L)
	await get_tree().process_frame
	await get_tree().process_frame
	check(ui.networks.is_open() and sent_one("lnets").size() > 0, "L opens the logistic networks window and asks for them")
	m.handle({"t": "lnets", "l": [[4, 1, "nauvis", [998, 1000], [201, 201], 34, 22, 138, 108, 2560, 512, ""],
		[9, 4, "vulcanus", [10, 12], [0, 5], 2, 1, 3, 1, 0, 0, "[item=iron-plate] Mall"]]})
	m.handle({"t": "lnet", "id": 4, "found": 1, "log": [998, 1000], "con": [201, 201], "items": [["stone", 17750], ["copper-cable", 9600]]})
	await get_tree().process_frame
	var net_texts := _texts(ui.networks)
	var robots_slot = ui.networks.find_child("Member_logistic-robot", true, false)
	check(ui.networks.selected == 4 and ui.networks._items.get_child(1).get("item") == "copper-cable" and robots_slot != null and robots_slot.count == 1000
		and robots_slot.tip_title == "Logistic robots: 998 / 1000 available" and net_texts.any(func(t) -> bool: return str(t).begins_with("[Iron plate] Mall")),
		"every network with its robots, the selected one's items: %s" % [net_texts.slice(0, 12)])
	var looks: Array = []
	var catch_net := func(at: Vector2, si: int) -> void: looks.append([at, si])
	ui.networks.show_at.connect(catch_net)
	(ui.networks.find_child("LookAtIt", true, false) as Button).pressed.emit()
	ui.networks.show_at.disconnect(catch_net)
	check(looks == [[Vector2(10, 2), 1]], "Look at it goes to a roboport of the network: %s" % [looks])
	await get_tree().process_frame
	check(ui.remote and ui.remote_frame.visible and ui.remote_frame.networks_open and not ui.map_view.surfaces_panel.visible
		and not (ui.remote_frame.title_bar.find_child("Search", true, false) as Control).visible,
		"as in Factorio it opens in the remote view: the frame's title bar without search, its frames where the Surfaces panel was")
	ui.networks.open(true)
	key(KEY_L)
	await get_tree().process_frame
	await get_tree().process_frame
	check(not ui.networks.is_open() and not ui.remote, "L again closes it, and the remote view it opened")
	key(KEY_L)
	await get_tree().process_frame
	await get_tree().process_frame
	ui.remote_frame.close_requested.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	check(not ui.networks.is_open() and not ui.remote, "the remote view's close closes the networks window too")
	ui.player = real_player
	rig_player.queue_free()
	world_holder.queue_free()

	# --- statistics: tabs, surfaces, graphs ------------------------------------------------------
	sent()
	key(KEY_P)
	await get_tree().process_frame
	sent()
	check(ui.stats._tabs.get_child_count() == 5 and ui.stats._scales.get_child_count() == 9,
		"production statistics has Factorio's tabs (Items, Fluids, Buildings, Pollution, Kills) and nine time scales (5s ... All)")
	_find_button(ui.stats, "Pollution").pressed.emit()
	var ask := sent_one("stats")
	check(ask.get("kind") == "pollution" and ask.get("g") == [], "the Pollution tab asks for pollution with graph lines: %s" % [ask])
	m.handle({"t": "stats", "kind": "pollution", "prec": ask.get("prec", 2), "si": 1, "l": [["boiler", 30.0, 0.0, 1800, 0], ["grass-1", 0.0, 20.0, 0, 1200]],
		"gr": [["boiler", [1, 2, 3], [0, 0, 0]], ["grass-1", [0, 0, 0], [5, 4, 3]]]})
	await get_tree().process_frame
	var side0: Node = ui.stats._sides[0]["grid"]
	var side1: Node = ui.stats._sides[1]["grid"]
	check(ui.stats._in_graph.lines.size() == 2 and ui.stats._colors.size() == 2 and side0.find_child("Row_boiler", false, false) != null
		and side0.find_child("Row_grass-1", false, false) == null and side1.find_child("Row_grass-1", false, false) != null,
		"two panels, each with a graph line per drawn row and its own rows (produced left, consumed right)")
	sent()
	(ui.stats._sides[0]["universe"] as CheckBox).button_pressed = true
	check(sent_one("stats").get("si") == 0 and (ui.stats._sides[1]["universe"] as CheckBox).button_pressed,
		"Universe statistics asks for every surface's statistics (both panels' boxes follow)")
	(ui.stats._sides[0]["universe"] as CheckBox).button_pressed = false
	sent()
	var row_boiler: Control = side0.find_child("Row_boiler", false, false)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	row_boiler.gui_input.emit(click)
	check(not (sent_one("stats").get("g", []) as Array).has("boiler"), "clicking a drawn row takes its line away")
	sent()
	(ui.stats._sides[0]["box"].find_child("Reset", true, false) as Button).pressed.emit()
	check(ui.stats.graph_names.is_empty() and (sent_one("stats").get("g", []) as Array).has("boiler"), "reset draws the busiest again")
	sent()
	(ui.stats._scales.get_child(8) as Button).pressed.emit()
	check(sent_one("stats").get("prec") == 9 and ui.stats.prec == ui.stats.ALL, "All asks for prec 9 (rows by all-time totals)")
	m.handle({"t": "stats", "kind": "pollution", "prec": 9, "si": 1, "l": [["boiler", 30.0, 0.0, 1800, 0]], "gr": []})
	await get_tree().process_frame
	check(_texts(ui.stats._sides[0]["grid"]).has("1.8k"), "All shows the all-time totals: %s" % [_texts(ui.stats._sides[0]["grid"])])
	ui.stats.toggle_search()
	ui.stats._search_box.text = "nothing like it"
	ui.stats._search_box.text_changed.emit(ui.stats._search_box.text)
	check(ui.stats._sides[0]["grid"].find_child("Row_boiler", false, false) == null, "the search hides rows that don't match")
	ui.stats.toggle_search()
	(ui.stats._scales.get_child(0) as Button).pressed.emit()
	ui.stats.visible = false
	ui.stats.toggle("electric", {"u": 9})
	await get_tree().process_frame
	check(ui.stats._title.text == "Electric network info" and ui.stats._summary.visible and not ui.stats._tabs.visible
		and ui.stats._sides[2]["box"].visible, "a pole opens Electric network info: summary bars, no tabs, three panels")
	m.handle({"t": "stats", "kind": "electric", "prec": ui.stats.prec, "l": [["steam-engine", 0.0, 540.0, 0, 32400],
		["inserter", 540.0, 0.0, 792, 0]], "st": [["accumulator", 1000, 5000000]]})
	await get_tree().process_frame
	check(_texts(ui.stats).has("9 W / 9 W") and _texts(ui.stats).has("5 MJ") and ui.stats._sides[2]["grid"].find_child("Row_accumulator", false, false) != null,
		"satisfaction, the accumulators' charge and their rows: %s" % [_texts(ui.stats._summary)])
	m.handle({"t": "stats", "kind": "electric", "prec": ui.stats.prec, "l": [["steam-engine", 0.0, 540.0, 0, 32400]],
		"st": [], "ef": [500, 1000, 500, 2000, 2500000, 5000000]})
	await get_tree().process_frame
	check(_texts(ui.stats).has("30 kW / 60 kW") and _texts(ui.stats).has("30 kW / 120 kW") and _texts(ui.stats).has("2.5 MJ / 5 MJ")
		and is_equal_approx((ui.stats._bars["Satisfaction"][0] as ProgressBar).value, 0.5),
		"the summary bars from the network's last update (flow_last_tick): %s" % [_texts(ui.stats._summary)])
	ui.stats.visible = false

	# --- the game-wide windows: bonuses, alerts configuration, achievements, permissions -----------
	sent()
	ui.open_global("bonuses")
	check(ui.bonuses.is_open() and sent_one("bonuses").get("t") == "bonuses", "the Bonuses window asks for the force's bonuses")
	m.handle({"t": "bonus", "l": [["inserter_stack_size_bonus", 1, ["inserter"]], ["worker_robots_speed_modifier", 0.35, ["logistic-robot", "construction-robot"]],
		["worker_robots_storage_bonus", 1, ["logistic-robot", "construction-robot"]], ["ammo_damage:bullet", 0.8, ["firearm-magazine"]],
		["turret_attack:gun-turret", 0.4, ["gun-turret"]]]})
	await get_tree().process_frame
	var bt := _texts(ui.bonuses)
	check(bt.has("Inserter capacity: +1") and bt.has("Movement speed: +35%\nCargo capacity: +1") and bt.has("Damage: +80%")
		and bt.has("Damage: +40%\n(Stacks with ammo bonuses)") and ui.bonuses._grid.get_child_count() % 4 == 0,
		"bonuses in Factorio's words, the same things' bonuses in one cell, four to a row: %s" % [bt])
	ui.open_global("bonuses")
	check(not ui.bonuses.is_open(), "its toggle closes it")
	ui.open_global("alerts")
	var ac = ui.alerts_config
	check(ac.is_open() and ac._table.get_child_count() == 5 * (1 + ac.TYPES.size()), "Alerts configuration: Icon, Name, Muted, Disabled, Latest for every alert type")
	(ac.find_child("SortName", true, false) as Button).pressed.emit()
	await get_tree().process_frame
	check(ac.sort_by == "Name" and ac.rows()[0][1][0] == "Asteroid collector blocked", "clicking Name sorts by name")
	ac.set_flag("Entity destroyed", "disabled", true)
	check(ui.alerts.hidden_kinds.has("destroyed"), "a disabled alert leaves the alert bar")
	ac.set_flag("Entity destroyed", "disabled", false)
	check(not ui.alerts.hidden_kinds.has("destroyed"), "and comes back")
	# The alert sound (Factorio's alert_destroyed beep): when something is destroyed; not when a turret runs out
	# of ammunition (owner), unless --alert-sounds=ammo, then once; not for what was there already, not for damage,
	# not when muted or disabled.
	var bar = ui.alerts
	# (Testing) The default, with no --alert-sounds switch: only destroyed sounds.
	if not ("--alert-sounds=ammo" in OS.get_cmdline_user_args()):
		check(Alerts.sound_kinds == ["destroyed"], "alert sound: by default only destroyed beeps, not no_ammo: %s" % [Alerts.sound_kinds])
	else:
		check(Alerts.sound_kinds.has("no_ammo"), "alert sound: --alert-sounds=ammo puts the ammunition beep back: %s" % [Alerts.sound_kinds])
	var beeps := [0]
	var was_beep: Callable = bar.alert_beep
	bar.alert_beep = func() -> void: beeps[0] += 1
	var had_alerts: Array = m.alerts.duplicate(true)
	bar._sound_primed = false
	bar._sounded = {}
	var al := func(rows: Array) -> void:
		bar._sound_msec = -100000  # (each update a second or more after the last)
		m.handle({"t": "al", "l": rows})
	var wall := [2560, 0, 1, "stone-wall", 0]
	var wall2 := [2816, 0, 1, "stone-wall", 0]
	var turret := [5120, 0, 1, "gun-turret", 71]
	al.call([["destroyed", 1, [wall]]])
	check(beeps[0] == 0, "alert sound: none for the alerts already there when the client joins: %d" % beeps[0])
	al.call([["destroyed", 1, [wall]], ["attack", 1, [[0, 0, 1, "stone-wall", 5]]]])
	check(beeps[0] == 0, "alert sound: none for something being damaged, nor for the same destroyed entity again: %d" % beeps[0])
	al.call([["destroyed", 3, [wall, wall2, [3072, 0, 1, "stone-wall", 0]]]])
	check(beeps[0] == 1, "alert sound: one beep when more is destroyed, however many at once: %d" % beeps[0])
	al.call([["destroyed", 3, [wall, wall2, [3072, 0, 1, "stone-wall", 0]]], ["no_ammo", 1, [turret]]])
	check(beeps[0] == 1, "alert sound: none when a turret runs out of ammunition (owner): %d" % beeps[0])
	al.call([["destroyed", 3, [wall, wall2, [3072, 0, 1, "stone-wall", 0]]]])
	var was_kinds: Array = Alerts.sound_kinds
	Alerts.sound_kinds = Alerts.SOUND_KINDS_AMMO
	al.call([["destroyed", 3, [wall, wall2, [3072, 0, 1, "stone-wall", 0]]], ["no_ammo", 1, [turret]]])
	al.call([["destroyed", 3, [wall, wall2, [3072, 0, 1, "stone-wall", 0]]], ["no_ammo", 1, [turret]]])
	check(beeps[0] == 2, "alert sound: --alert-sounds=ammo beeps once when a turret runs out of ammunition, not again while it stays empty: %d" % beeps[0])
	ac.set_flag("Turret out of ammunition", "muted", true)
	al.call([["no_ammo", 2, [turret, [7680, 0, 1, "gun-turret", 72]]]])
	check(bar.muted_kinds == ["no_ammo"] and beeps[0] == 2, "alert sound: a kind muted in the Alerts configuration makes none: %s %d" % [bar.muted_kinds, beeps[0]])
	ac.set_flag("Turret out of ammunition", "muted", false)
	Alerts.sound_kinds = was_kinds
	ac.set_flag("Entity destroyed", "disabled", true)
	al.call([["destroyed", 1, [[9000, 0, 1, "stone-wall", 0]]]])
	ac.set_flag("Entity destroyed", "disabled", false)
	check(beeps[0] == 2, "alert sound: nor one that is disabled: %d" % beeps[0])
	Alerts.sounds_on = false
	al.call([["destroyed", 1, [[9500, 0, 1, "stone-wall", 0]]]])
	Alerts.sounds_on = true
	var silent: int = beeps[0]
	al.call([["destroyed", 1, [[9900, 0, 1, "stone-wall", 0]]]])
	check(silent == 2 and beeps[0] == 3, "alert sound: --alert-sounds=off is silent as before; on, the next destroyed entity beeps: %d %d" % [silent, beeps[0]])
	check(ac.TYPES.any(func(t: Array) -> bool: return t[0] == "Pipeline overextended" and t[2] == "pipeline"),
		"Alerts configuration: Pipeline overextended is the bar's pipeline alert (its Disabled and Latest work)")
	bar.alert_beep = was_beep
	m.alerts = had_alerts
	m.alerts_changed.emit()
	ac.open(false)
	ui.open_global("achievements")
	check(ui.achievements.is_open() and str(ui.achievements._earned.text).begins_with("Earned 0 of"), "Achievements: the progress line (modded: none earned)")
	ui.achievements.open(false)
	sent()
	ui.open_global("permissions")
	check(sent_one("perms").get("t") == "perms", "the Permissions window asks for the groups")
	m.handle({"t": "perms", "me": "", "l": [["Default", ["Alice", "Bob"]], ["Admin", ["Carol"]]]})
	await get_tree().process_frame
	var pw = ui.permissions
	check(pw.selected == "Default" and (pw.find_child("Row_Default", true, false) as Button).theme_type_variation == "FListItemSelected"
		and pw._members.get_child_count() == 2, "the first group is selected, its players listed")
	(pw.find_child("Row_Admin", true, false) as Button).pressed.emit()
	await get_tree().process_frame
	check(pw.selected == "Admin" and _texts(pw._members) == ["Carol"], "clicking a group shows its players")
	key(KEY_ESCAPE)
	await get_tree().process_frame
	check(not pw.is_open(), "Esc closes the permissions window")

	# --- rich text and the chat ----------------------------------------------------------------------
	check(RichText.plain("[item=iron-plate] for [color=1,0,0]Alice[/color] at [gps=10,-5]") == "[Iron plate] for Alice at [10, -5]",
		"rich text without its tags: %s" % RichText.plain("[item=iron-plate] for [color=1,0,0]Alice[/color] at [gps=10,-5]"))
	var plat_label := RichText.label("[planet=vulcanus] smelter")
	check(RichText.parse("[planet=vulcanus] smelter")[0]["t"] == "icon" and plat_label.get_parsed_text().contains("smelter"),
		"a platform name with [planet=vulcanus] is drawn with the planet's icon (the platform panel's rows)")
	plat_label.free()
	var toks: Array = RichText.parse("[font=default-bold]A[/font][color=red]B[/color][train=5][unknown=x]")
	check(toks.size() == 4 and toks[0]["font"] == "bold" and toks[1]["color"] == RichText.COLORS["red"] and toks[2]["t"] == "train"
		and toks[3]["s"] == "[unknown=x]", "fonts, colours, trains; unknown tags stay as written: %s" % [toks])
	var pings: int = m.live_pings().size()
	m.handle({"t": "chat", "from": "Alice", "c": [1, 0.5, 0], "text": "Iron at [gps=10,-5,nauvis] [item=iron-plate] [color=red]now[/color]"})
	await get_tree().process_frame
	var line: RichTextLabel = ui.chat._lines.get_child(ui.chat._lines.get_child_count() - 1)
	check(line.get_parsed_text().begins_with("Alice: Iron at ") and line.get_parsed_text().contains("[10, -5]") and m.live_pings().size() == pings + 1,
		"a chat line in rich text: the name, icons, colours, the gps link; it pings the map: %s" % line.get_parsed_text())
	var gps_seen: Array = []
	var catch_gps := func(at: Vector2, _s: String, clicked: bool) -> void: gps_seen.append([at, clicked])
	ui.chat.gps.connect(catch_gps)
	line.meta_clicked.emit("gps:10,-5,nauvis")
	ui.chat.gps.disconnect(catch_gps)
	check(gps_seen == [[Vector2(10, -5), true]], "clicking a gps link looks there")

	# --- the technology screen's details -------------------------------------------------------------
	m.handle({"t": "techs", "part": 1, "parts": 1, "l": [
		["automation", "a", [], [["automation-science-pack", 1]], 10, 10, 2, "", [["unlock-recipe", "assembling-machine-1", 0]], 1, 1, [], 0, ""],
		["steam-power", "a", [], [], 1, 0, 1, "craft-item", [["unlock-recipe", "boiler", 0]], 1, 1, ["craft-item", "iron-plate", 50], 0, ""],
		["mining-productivity-3", "b", ["automation"], [["automation-science-pack", 1]], 1000, 60, 1, "", [["mining-drill-productivity-bonus", "", 0.1]],
			7, -1, [], 250, "1000*(L - 2)"]]})
	ui.open_research(true)
	ui.research.select("mining-productivity-3")
	await get_tree().process_frame
	await get_tree().process_frame
	var rt := _texts(ui.research)
	check(rt.has("Mining productivity 7 (Available)") and rt.has("Infinite technology: each level costs more") and rt.has("Units: 1000*(L - 2) (L: the level)")
		and rt.has("25% researched before it was stopped") and rt.any(func(t) -> bool: return str(t).contains("Mining drill productivity bonus")),
		"an infinite technology by its level, its formula, kept progress and bonus: %s" % [rt.filter(func(t) -> bool: return str(t) != "").slice(0, 30)])
	ui.research.select("steam-power")
	await get_tree().process_frame
	await get_tree().process_frame
	rt = _texts(ui.research)
	check(rt.has("Craft 50 × Iron plate") and rt.has("Effects"), "a trigger technology's task and what it unlocks")
	ui.research.select("automation")
	await get_tree().process_frame
	await get_tree().process_frame
	check(ui.research._tree_slots.has("mining-productivity-3") and ui.research._tree_slots["mining-productivity-3"].position.y > ui.research._tree_slots["automation"].position.y
		and ui.research._tree_slots["automation"].size.x > ui.research._tree_slots["mining-productivity-3"].size.x,
		"the tree centres on the selected technology, drawn large, with what needs it below")
	ui.research.go_back()
	check(ui.research.selected == "steam-power", "back goes to the technology selected before")
	ui.research.go_forward()
	check(ui.research.selected == "automation", "and forward again")
	ui.research._search.text = "boiler"
	ui.research._refresh_tree()
	check(ui.research._slots["steam-power"].modulate.a == 1.0 and ui.research._slots["automation"].modulate.a < 1.0,
		"the technology search finds what unlocks a recipe; the rest dims")
	ui.research._search.text = ""
	ui.close_all()


func _collect(node: Node, out: Array) -> void:
	for c in node.get_children():
		if c.get("thing") != null and c is Button:
			out.append(c)
		_collect(c, out)


func _find_slot_item(node: Node, item: String) -> Control:
	for c in node.get_children():
		if c is Button and c.get("item") == item and (c as Control).is_visible_in_tree():
			return c
		var found := _find_slot_item(c, item)
		if found != null:
			return found
	return null


## Mods' windows (mgui, mod_gui.gd): built from the tree, placed, a click says to use Factorio,
## gone when the bridge no longer lists them.


func _mod_windows(hud: Hud) -> void:
	var mg = hud.ui.mod_gui
	# Off by default (owner: not usable yet): a mod's window isn't drawn.
	Settings.reset_value("interface", "mod_windows")
	mg.handle({"t": "mgui", "ids": [3], "l": [{"i": 3, "r": "screen", "at": [10, 10], "e": {"t": "frame", "a": [{"t": "label", "c": "Off"}]}}]})
	check(mg.count() == 0, "mod windows: off by default, a mod's window isn't drawn")
	Settings.set_value("interface", "mod_windows", true)
	var said := []
	var keep: Callable = mg.message
	mg.message = func(t: String) -> void: said.append(t)
	mg.handle({"t": "mgui", "ids": [5, 6], "l": [
		{"i": 5, "r": "screen", "at": [100, 50], "e": {"t": "frame", "c": ["", "Mod ", "info"], "d": "vertical", "a": [
			{"t": "label", "c": "Hello from a mod"},
			{"t": "table", "cc": 2, "a": [{"t": "sprite-button", "sp": "item/iron-plate", "nu": 3}, {"t": "button", "c": "Go"}]}]}},
		{"i": 6, "r": "top", "e": {"t": "sprite-button", "sp": "informatron", "c": "I"}}]})
	await get_tree().process_frame
	check(mg.count() == 2, "mod windows: a screen window and a top button are built (%d)" % mg.count())
	var window: Control = mg._windows[5]["node"]
	var texts := _texts(window)
	check(texts.has("Mod info") and texts.has("Hello from a mod") and texts.has("Go"),
		"mod windows: the frame's localised caption, its label and button are drawn: %s" % [texts])
	check(window.position.is_equal_approx(Vector2(100, 50) * Kit.scale_for(mg.get_viewport_rect().size.y)),
		"mod windows: a screen window sits where the mod put it (%s)" % window.position)
	var go: Button = window.find_children("*", "Button", true, false).filter(func(b): return b.text == "Go")[0]
	go.pressed.emit()
	check(said.size() == 1 and said[0].contains("Ctrl+F9"), "mod windows: pressing a mod's button says to use it in Factorio: %s" % [said])
	# With Factorio's window size and UI scale (`ds`), a button maps to Factorio's pixels: the
	# window where the mod put it at Factorio's scale, the button just inside its corner.
	mg.handle({"t": "mgui", "ids": [5, 6], "l": [], "ds": [1920, 1080, 1.5]})
	var zs := Kit.scale_for(mg.get_viewport_rect().size.y)
	var r := go.get_global_rect()
	var aim := r.position + Vector2(minf(r.size.x * 0.5, 10.0 * zs), minf(r.size.y * 0.5, 10.0 * zs))
	var want := Vector2(100, 50) * 1.5 + (aim - window.global_position) * (1.5 / zs)
	check(mg.factorio_point(go).is_equal_approx(want) and mg.display == [1920.0, 1080.0, 1.5],
		"mod windows: a button's place in Factorio's window (%s, want %s)" % [mg.factorio_point(go), want])
	var top_button: Control = mg._windows[6]["node"]
	check(mg.factorio_point(top_button).x >= 0.0, "mod windows: a top button maps too")
	Settings.set_value("interface", "mod_clicks", false)
	go.pressed.emit()
	Settings.reset_value("interface", "mod_clicks")
	check(said.size() == 2 and mg.forwarded.is_empty(), "mod windows: with clicks in Factorio off, the button says to use Factorio")
	# The click helper's answers (read every frame while clicks wait): a click done says nothing,
	# one with no Factorio window to click (or an error) says to use Factorio.
	mg.heard(PackedStringArray(["ok front=other minimised=False"]))
	check(said.size() == 2, "mod windows: a click done in Factorio says nothing more")
	mg.heard(PackedStringArray(["none"]))
	check(said.size() == 3 and said[2].contains("Ctrl+F9"), "mod windows: a click with no Factorio window says to use Factorio")
	check(preload("res://scripts/ui/factorio/factorio_clicks.gd").poll().is_empty(), "mod windows: no helper, nothing to read")
	# Dragging its title bar moves it, and the move outlasts the bridge's next placement.
	var bar: Control = window.find_children("*", "HBoxContainer", true, false).filter(func(b): return b.has_meta("drag_handle"))[0]
	check(Kit.drag_target(bar) == window, "mod windows: the title bar drags its own window")
	var before := window.position
	Kit.move_window(window, Vector2(30, 20))
	mg._place()
	check(window.position.is_equal_approx(before + Vector2(30, 20)), "mod windows: a dragged window stays where it was dragged (%s -> %s)" % [before, window.position])
	var cw: Control = hud.ui.window
	var cw_bar: Control = cw.find_children("*", "HBoxContainer", true, false).filter(func(b): return b.has_meta("drag_handle"))[0]
	check(Kit.drag_target(cw_bar) == cw._center, "windows: the character window's title drags the whole window")
	var LocaleNames := preload("res://scripts/world/locale_names.gd")
	check(LocaleNames._plurals("__plural_for_parameter__1__{1=day|rest=days}__", [1]) == "day"
		and LocaleNames._plurals("__plural_for_parameter__1__{1=day|rest=days}__", [3]) == "days"
		and LocaleNames.localise(["", "a", 2, "b"]) == "a2b", "locale: plural forms and joined strings")
	# A button the bridge can press itself (ck: Informatron's, through its remote interface) goes to
	# the bridge as `mpress`, never clicked in Factorio's window (owner: those clicks missed). A label
	# Factorio wraps (ml) wraps at its maximal width (mw), rich text too, instead of running off the screen.
	var long_text := "A long paragraph [item=iron-plate] that Factorio wraps at the label's width. " .repeat(6)
	mg.handle({"t": "mgui", "ids": [6, 7], "l": [
		{"i": 7, "r": "screen", "at": [100, 50], "e": {"t": "frame", "ix": 7, "d": "vertical", "a": [
			{"t": "label", "ix": 71, "ml": true, "mw": 400, "c": long_text},
			{"t": "button", "ix": 72, "c": "Page two", "ck": true}]}}]})
	await get_tree().process_frame
	var info: Control = mg._windows[7]["node"]
	var page_b: Button = info.find_children("*", "Button", true, false).filter(func(b): return b.text == "Page two")[0]
	var before_forwarded: int = mg.forwarded.size()
	page_b.pressed.emit()
	check(mg.pressed_by_bridge == [72] and mg.forwarded.size() == before_forwarded,
		"mod windows: a ck button is sent to the bridge (mpress %s), not clicked in Factorio" % [mg.pressed_by_bridge])
	var para: Control = info.find_children("*", "RichTextLabel", true, false)[0] if not info.find_children("*", "RichTextLabel", true, false).is_empty() else null
	var zs7 := Kit.scale_for(mg.get_viewport_rect().size.y)
	check(para != null and (para as RichTextLabel).autowrap_mode != TextServer.AUTOWRAP_OFF and info.size.x < 600.0 * zs7,
		"mod windows: a long rich text label wraps at its width (window %.0f px wide)" % info.size.x)
	# Informatron rebuilds its window on every page: the new one (another index, the same name) keeps
	# the old one's place until Factorio places it, instead of jumping to the top left (owner).
	var view7 := mg.get_viewport_rect().size
	mg.handle({"t": "mgui", "ids": [6, 7], "l": [{"i": 7, "r": "screen", "at": [300, 200], "e": {"t": "frame", "n": "informatron", "a": [{"t": "label", "c": "Page one"}]}}]})
	await get_tree().process_frame
	var held_at: Vector2 = mg._windows[7]["node"].position
	mg.handle({"t": "mgui", "ids": [6, 8], "l": [{"i": 8, "r": "screen", "at": [0, 0], "e": {"t": "frame", "n": "informatron", "a": [{"t": "label", "c": "Page two"}]}}]})
	await get_tree().process_frame
	check(mg._windows.has(8) and mg._windows[8]["node"].position.is_equal_approx(held_at),
		"mod windows: a rebuilt window of the same name keeps its place (%s, was %s)" % [mg._windows[8]["node"].position if mg._windows.has(8) else null, held_at])
	mg.handle({"t": "mgui", "ids": [6, 8], "l": [{"i": 8, "r": "screen", "at": [300, 200], "e": {"t": "frame", "n": "informatron", "a": [{"t": "label", "c": "Page two"}]}}]})
	await get_tree().process_frame
	check(not mg._windows[8].has("hold"), "mod windows: once Factorio places it, the bridge's place is used again")
	# A window at 0, 0 that wasn't one before (the mod centres it, Factorio hasn't yet) is drawn centred.
	mg.handle({"t": "mgui", "ids": [6, 9], "l": [{"i": 9, "r": "screen", "at": [0, 0], "e": {"t": "frame", "n": "other", "a": [{"t": "label", "c": "Centred"}]}}]})
	await get_tree().process_frame
	await get_tree().process_frame
	var c9: Control = mg._windows[9]["node"]
	check(c9.position.is_equal_approx(((view7 - c9.size) / 2.0).floor()), "mod windows: a window at 0, 0 is drawn centred (%s in %s)" % [c9.position, view7])
	# Taller than Zenith's window: its content scrolls, the window stays on the screen.
	var tall_rows: Array = []
	for k in 80:
		tall_rows.append({"t": "label", "c": "Row %d" % k})
	mg.handle({"t": "mgui", "ids": [6, 10], "l": [{"i": 10, "r": "screen", "at": [10, 10], "e": {"t": "frame", "n": "tall", "a": tall_rows}}]})
	await get_tree().process_frame
	await get_tree().process_frame
	var tall: Control = mg._windows[10]["node"]
	var tall_scroll: ScrollContainer = tall.find_children("*", "ScrollContainer", true, false)[0]
	var tall_inner: Control = tall_scroll.get_child(0)
	check(tall_scroll.custom_minimum_size.y <= maxf(view7.y - Kit.px(120), Kit.px(120)) + 0.5 and tall_inner.get_combined_minimum_size().y > tall_scroll.custom_minimum_size.y,
		"mod windows: a window taller than the screen scrolls (%.0f of its %.0f px shown, screen %.0f)" % [tall_scroll.custom_minimum_size.y, tall_inner.get_combined_minimum_size().y, view7.y])
	# Factorio lays a window out by its styles (owner: Informatron's came out a thin strip): a fixed
	# height (sz) makes the window that tall, a stretched scroll pane (vs) fills it.
	mg.handle({"t": "mgui", "ids": [6, 12], "l": [{"i": 12, "r": "screen", "at": [10, 10], "e": {"t": "frame", "n": "styled", "sz": [0, 0, 40, 40], "a": [
		{"t": "scroll-pane", "vs": true, "a": [{"t": "label", "c": "Inside"}]}]}}]})
	await get_tree().process_frame
	await get_tree().process_frame
	var styled: Control = mg._windows[12]["node"]
	var want_h := minf(Kit.px(40), view7.y - Kit.px(80))
	var pane: ScrollContainer = styled.find_children("*", "ScrollContainer", true, false).filter(func(c): return c.name == "scroll-pane")[0]
	check(styled.custom_minimum_size.y >= want_h - 0.5 and pane.size_flags_vertical == Control.SIZE_EXPAND_FILL,
		"mod windows: a style's fixed height sizes the window (%.0f, want %.0f) and a stretched pane fills it" % [styled.custom_minimum_size.y, want_h])
	# Space Exploration's watermark: a frame clicks go through, the size of the screen: no panel, faint,
	# its text in the bottom-right corner, the mouse never stopped by it.
	mg.handle({"t": "mgui", "ids": [6, 11], "l": [{"i": 11, "r": "screen", "at": [0, 0], "e": {"t": "frame", "n": "se_watermark_string_frame", "ig": true, "fs": true, "d": "horizontal",
		"a": [{"t": "label", "n": "se_watermark_string_label", "c": "SE 0.7.64 T602"}]}}]})
	await get_tree().process_frame
	await get_tree().process_frame
	var wm: Control = mg._windows[11]["node"]
	var wm_label: Control = wm.find_children("*", "Label", true, false)[0]
	check(wm.find_children("*", "PanelContainer", true, false).is_empty() and wm.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and wm_label.mouse_filter == Control.MOUSE_FILTER_IGNORE and wm.size.is_equal_approx(view7)
		and absf(wm_label.get_global_rect().end.x - wm.get_global_rect().end.x) < 4.0 and absf(wm_label.get_global_rect().end.y - wm.get_global_rect().end.y) < 4.0,
		"mod windows: a full-screen frame clicks go through is drawn as a watermark in the bottom-right corner (%s)" % wm_label.get_global_rect())
	mg.handle({"t": "mgui", "ids": [6], "l": []})
	await get_tree().process_frame
	check(mg.count() == 1 and not mg._windows.has(5), "mod windows: a window the bridge no longer lists goes")
	mg.handle({"t": "mgui", "ids": [], "l": []})
	Settings.reset_value("interface", "mod_windows")
	# The hello says whether they are drawn (mg), so the bridge reads them only for a client that does.
	var was_windows: bool = Bridge.mod_windows
	var hellos: Array = []
	for says: bool in [false, true]:
		Bridge.mod_windows = says
		sent()
		Bridge._send_hello()
		for text in Bridge.capture:
			var hello = JSON.parse_string(text)
			if hello is Dictionary and hello.get("t", "") == "hello":
				hellos.append(int(hello.get("mg", -1)))
		Bridge.capture.clear()
	Bridge.mod_windows = was_windows
	check(hellos == [0, 1], "the hello says whether mods' windows are wanted (mg): %s" % [hellos])
	# L13: and the account this PC's Factorio plays under (pn) when it is known, whose player takes this character.
	var was_player: String = Bridge.factorio_player
	var names: Array = []
	for player: String in ["", "zen"]:
		Bridge.factorio_player = player
		sent()
		Bridge._send_hello()
		for text in Bridge.capture:
			var hello = JSON.parse_string(text)
			if hello is Dictionary and hello.get("t", "") == "hello":
				names.append(str(hello.get("pn", "-")))
		Bridge.capture.clear()
	Bridge.factorio_player = was_player
	check(names == ["-", "zen"], "L13: the hello names its Factorio's player (pn) only when it is known: %s" % [names])
	mg.message = keep


## Windows held to Zenith's height (owner: a modded storehouse ran off the bottom) and the
## top-left Factorio button (Ctrl+F9's swap, owner).


func _window_bounds(hud: Hud) -> void:
	var screen: MachineScreen = hud.ui.screen
	var tall := Control.new()
	tall.custom_minimum_size = Vector2(Kit.px(400), 5000)
	screen._columns.add_child(tall)
	screen._fit_to_window()
	var cap := maxf(Kit.px(200), screen.get_viewport_rect().size.y - Kit.px(MachineScreen.WINDOW_ROOM))
	check(screen._fit.custom_minimum_size.y <= cap + 0.5 and screen._fit.get_child(0) == screen._columns,
		"windows: a machine screen taller than Zenith's window is held to it and scrolls (%.0f of %.0f, room %.0f)" % [screen._fit.custom_minimum_size.y, 5000.0, cap])
	tall.queue_free()
	await get_tree().process_frame
	screen._fit_to_window()
	var button: Button = hud.ui.factorio_button
	var keep: Callable = hud.ui.show_factorio
	hud.ui.show_factorio = Callable()
	await get_tree().process_frame
	check(button != null and not button.visible, "the Factorio button is hidden outside a game")
	var pressed := [0]
	hud.ui.show_factorio = func() -> void: pressed[0] += 1
	await get_tree().process_frame
	button.pressed.emit()
	check(button.visible and pressed[0] == 1 and button.position.is_equal_approx(Kit.pxv(8, 8)),
		"the Factorio button sits at the top left in a game and does what Ctrl+F9 does")
	hud.ui.show_factorio = keep
	await _focus_never_blocks()


## Ctrl+F9's window-focusing script runs on its own: the main thread blocked in OS.execute until it
## (and anything holding its output) had gone, and Zenith froze. Asked for a process nothing has, it
## answers "no window" a moment later through poll(), and the press returned at once.


func _focus_never_blocks() -> void:
	const GameSwap := preload("res://scripts/menu/game_swap.gd")
	var got := [-99]
	var answer := func(code: int) -> String:
		got[0] = code
		return "answered"
	var t0 := Time.get_ticks_msec()
	var started: bool = GameSwap._focus(0, "zenith-test-no-such-process", answer)
	var start_ms := Time.get_ticks_msec() - t0
	var said := ""
	while said == "" and GameSwap.focusing() and Time.get_ticks_msec() - t0 < GameSwap.FOCUS_TIMEOUT_MSEC + 2000:
		await get_tree().process_frame
		said = GameSwap.poll()
	check(started and start_ms < 500 and said == "answered" and got[0] != 0 and not GameSwap.focusing(),
		"Ctrl+F9: the focusing script is started, not waited for (%d ms), and answers later (exit %d)" % [start_ms, got[0]])


## K7: first person picks what the crosshair is on (aim_pick.gd), as a shooter does, not where its
## ray meets the ground: looking level at a machine two tiles off selects it (a level look meets no
## ground, so the old pick found nothing), a belt behind a chest isn't picked through the chest (the
## old pick took the belt the ray landed on) and the right button mines the chest, a vehicle behind
## what the ray met isn't hovered, a held entity goes beside the face looked at, the boxes stand on
## the hills, and --fp-pick=ground (fp_pick_models off) picks from the ground point as before.


func _layout(hud: Hud) -> void:
	var ui = hud.ui
	var root: Control = hud.get_child(0)
	ui.close_all()
	ui.open_map(false)
	ui.debug_overlay = true
	ui.model.handle({"t": "rs", "cur": "automation", "pr": 250, "q": []})
	ui.model.handle({"t": "cq", "pr": 300, "l": [[1, "iron-gear-wheel", 3, 0], [2, "transport-belt", 2, 0]]})
	ui.model.handle({"t": "al", "l": [["no_power", 3, [[0, 0, 1, "assembling-machine-1", 5]]]]})
	hud.cursor_label.text = "12 km/h · WASD drive · Enter: get out"
	var had_help := bool(Settings.get_value("interface", "show_help"))
	Settings.set_value("interface", "show_help", true)
	hud.help.visible = true
	var platforms := PanelContainer.new()  # stands in for main.gd's platform panel
	platforms.custom_minimum_size = Kit.pxv(300, 140)
	hud.add_child(platforms)
	ui.platform_panel = platforms
	root.anchor_right = 0.0
	root.anchor_bottom = 0.0
	var pieces := {"debug line": ui.status_label, "research": ui.research_hud, "platforms": platforms, "minimap": ui.minimap,
		"quickbar": ui.quickbar, "weapons": ui.weapons, "shortcuts": ui.shortcuts, "alerts": ui.alerts,
		"crafting queue": ui.craft_queue, "driving line": hud.cursor_label, "help": hud.help}
	for window in [Vector2(1280, 720), Vector2(1626, 971), Vector2(1920, 1080), Vector2(2560, 1440)]:
		for ui_scale in [Kit.scale_for(window.y), 2.0]:
			var view: Vector2 = (window / (ui_scale / Kit.scale)).floor()
			root.size = view
			for i in 4:
				await get_tree().process_frame
			var where := "%dx%d at %d%%" % [window.x, window.y, roundi(ui_scale * 100.0)]
			var rects := {}
			for piece in pieces:
				var c: Control = pieces[piece]
				if c.is_visible_in_tree() and c.self_modulate.a > 0.0:
					rects[piece] = c.get_global_rect()
			check(rects.size() == pieces.size() or (ui_scale > 1.25 and rects.size() == pieces.size() - 1 and not rects.has("help")),
				"%s: every piece shows (missing: %s)" % [where, ", ".join(pieces.keys().filter(func(p): return not rects.has(p)))])
			if window.y >= 1080 and ui_scale == Kit.scale_for(window.y):
				# F1's help whole at 1080p and up (it scrolls in less room): owner, "keep it fitting on screen".
				check(not hud.help.scroll_active and rects.has("help"), "%s: the whole help fits, no scrolling (%s, font %d)"
					% [where, hud.help.size, hud.help.get_theme_font_size("normal_font_size")])
			var screen := Rect2(Vector2.ZERO, view)
			var names: Array = rects.keys()
			# Half a pixel in from each edge, never below nothing: a piece under a pixel wide grew
			# a negative size, an engine error each time (87 a run).
			var inner := func(r: Rect2) -> Rect2:
				return Rect2(r.position + Vector2(0.5, 0.5), (r.size - Vector2.ONE).max(Vector2.ZERO))
			for i in names.size():
				var a: Rect2 = rects[names[i]]
				check(screen.encloses(inner.call(a)), "%s: %s %s on screen (%s)" % [where, names[i], a, view])
				for j in range(i + 1, names.size()):
					var b: Rect2 = rects[names[j]]
					check(not inner.call(a).intersects(inner.call(b)), "%s: %s %s and %s %s apart" % [where, names[i], a, names[j], b])
			# F2: on a platform its panel sits right under the minimap, against the right edge, or
			# beside it when the shortcut bar would have no room.
			var side: Rect2 = ui.side_menu.get_global_rect()
			var pr: Rect2 = rects.get("platforms", Rect2())
			var below := absf(pr.position.y - side.end.y) < 1.0 and absf(pr.end.x - view.x) < 1.0
			var beside := absf(pr.position.y - side.position.y) < 1.0 and pr.end.x <= side.position.x
			check(below or beside,
				"%s: the platform panel sits under the minimap (F2): %s by %s" % [where, pr, side])
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.platform_panel = null
	platforms.queue_free()
	# The help panel: off by default (Factorio has none) and hidden while a window is open.
	check(Settings.DEFAULTS["interface"]["show_help"] == false, "the help panel is off by default")
	ui.window.open_crafting(true)
	await get_tree().process_frame
	await get_tree().process_frame
	check(not hud.help.visible, "the help panel hides while a window is open")
	ui.close_all()
	# It names the keys bound now (Settings → Controls, or Factorio's own), not the defaults.
	var drop_was := "%s: drop" % Hud._key("drop_item")
	var help_was := str(hud.help.get_meta("full_text", ""))
	Settings.bind("drop_item", [KEY_J])
	await get_tree().process_frame
	await get_tree().process_frame
	var help_rebound := str(hud.help.get_meta("full_text", ""))
	Settings.bind("drop_item", [])
	await get_tree().process_frame
	await get_tree().process_frame
	check(help_was.contains(drop_was) and help_rebound.contains("J: drop") and not help_rebound.contains(drop_was)
		and str(hud.help.get_meta("full_text", "")).contains(drop_was) and help_was.contains("hide help"),
		"the help (F1) names the keys bound now: %s, J once rebound, back after reset" % drop_was)
	Settings.set_value("interface", "show_help", had_help)
	ui.debug_overlay = false


## The map view's title, the Remote view frame's caption, was half under the Show in Factorio button,
## which stood at the top left over the title bar (found testing with the owner's settings): in the
## remote view the button goes under the title bar, and the Surfaces panel and the logistic networks'
## frames under the button, at every window size and UI scale (the root's size stands in for the scale,
## as in _layout); outside the remote view it stays in the corner. Fails on the old layout.


func _map_title(hud: Hud) -> void:
	var ui = hud.ui
	var root: Control = hud.get_child(0)
	ui.close_all()
	var show_was: Callable = ui.show_factorio
	ui.show_factorio = func() -> void: pass
	ui.model.handle({"t": "surfs", "l": [[1, "nauvis", "nauvis", "", 0], [3, "vulcanus", "vulcanus", "", 0], [5, "platform-1", "", "Orbiter", 1]]})
	ui.open_map(true)
	root.anchor_right = 0.0
	root.anchor_bottom = 0.0
	var button: Button = ui.factorio_button
	var frame = ui.remote_frame
	var inner := func(r: Rect2) -> Rect2:
		return Rect2(r.position + Vector2(0.5, 0.5), (r.size - Vector2.ONE).max(Vector2.ZERO))
	for window in [Vector2(1280, 720), Vector2(1600, 900), Vector2(1920, 1080), Vector2(2560, 1440)]:
		for ui_scale in [0.75, Kit.scale_for(window.y), 1.5, 2.0]:
			var view: Vector2 = (window / (ui_scale / Kit.scale)).floor()
			root.size = view
			for i in 3:
				await get_tree().process_frame
			var where := "%dx%d at %d%%" % [window.x, window.y, roundi(ui_scale * 100.0)]
			var b: Rect2 = button.get_global_rect()
			var title: Rect2 = frame.title_label.get_global_rect()
			var bar: Rect2 = frame.title_bar.get_global_rect()
			var surfaces: Rect2 = ui.map_view.surfaces_panel.get_global_rect()
			var row_top: float = ui.networks._frames_row.global_position.y
			check(button.visible and frame.visible and ui.map_view.surfaces_panel.visible
				and not inner.call(b).intersects(inner.call(title)) and not inner.call(b).intersects(inner.call(bar))
				and not inner.call(b).intersects(inner.call(surfaces)) and row_top >= b.end.y and b.position.x >= 0.0,
				"%s: the map view's title %s and its bar %s clear of the Show in Factorio button %s, the Surfaces panel %s and the networks' frames (%.0f) under it (shown: %s %s %s)"
				% [where, title, bar, b, surfaces, row_top, button.visible, frame.visible, ui.map_view.surfaces_panel.visible])
	ui.open_map(false)
	await get_tree().process_frame
	await get_tree().process_frame
	check(button.position.is_equal_approx(Kit.pxv(8, 8)) and not frame.visible, "out of the remote view the button is back in the corner")
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.show_factorio = show_was
	await get_tree().process_frame


## F1's help (hud.gd): every control bound now is in it under its key; an add-on's controls under the
## add-on while it is loaded, those of its camera apart; the debug menu only where the testing tools
## are; and when it doesn't fit, it scrolls with the wheel over it instead of losing lines.


func _help(hud: Hud) -> void:
	var ui = hud.ui
	ui.close_all()
	var had_help := bool(Settings.get_value("interface", "show_help"))
	Settings.set_value("interface", "show_help", true)
	hud.refresh_help()
	var text := Hud.help_text()
	var named := Hud.help_actions()
	var missing: Array = []
	for action in Settings.bindable_actions():
		var shown := Hud._key(str(action))
		var page := str(action).begins_with("quickbar_page_")
		var row := ""  # the quickbar's ten as "1-0" or "Shift+1-0"
		if str(action).begins_with("quickbar_"):
			row = Hud._range("quickbar_page_1" if page else "quickbar_1", "quickbar_page_10" if page else "quickbar_10")
		if shown != "" and (not named.has(action) or not (text.contains(shown) or (row != "" and text.contains(row)))):
			missing.append("%s (%s)" % [action, shown])
	check(missing.is_empty(), "the help names every control bound now (missing: %s)" % ", ".join(missing))
	check(text.begins_with("%s: hide help" % Hud._key("toggle_help")), "its first line says how to hide it")
	check(text.contains("Shift+1-0: quickbar page") and text.contains("1-0: quickbar") and text.contains("WASD: walk")
		and text.contains("Ctrl+= / Ctrl+- / Ctrl+0: UI scale") and text.contains("Numpad + / Numpad -: tile area"),
		"keys read short: ranges, WASD, = and -, the numpad (%s)" % text.replace("\n", " | "))
	var bbcode := str(hud.help.get_meta("full_bbcode", ""))
	check(bbcode.contains("[color=#%s]" % Kit.KEY_TEXT.to_html(false)) and bbcode.contains("[b][color=#%s]Moving and camera" % Kit.CAPTION.to_html(false)),
		"keys in Factorio's hint blue, headings in its caption colour")
	# The debug menu (Ctrl+F12) is a testing tool: only in a build that has them.
	var dev_was: int = Settings.dev_tools_override
	Settings.dev_tools_override = 0
	check(not Hud.help_actions().has("debug_menu") and not Hud.help_text().contains("debug menu"), "a public build's help has no debug menu")
	Settings.dev_tools_override = 1
	check(Hud.help_actions().has("debug_menu") and Hud.help_text().contains("debug menu") == (Hud._key("debug_menu") != ""),
		"a dev build's help has the debug menu under its key")
	Settings.dev_tools_override = dev_was
	# An add-on's controls (api.keys: ControlsInfo.extra, Settings.contexts) while it is loaded.
	var toggle := "addon_help_test__toggle"
	var fly := "addon_help_test__fly"
	ControlsInfo.extra[toggle] = ["Help Test", "Toggle the thing (as it says)"]
	Settings.add_action(toggle, [KEY_F10 | KEY_MASK_SHIFT], "global")
	ControlsInfo.extra[fly] = ["Help Test", "Fly forward"]
	Settings.add_action(fly, [KEY_I], "help_test:camera")
	await get_tree().process_frame
	await get_tree().process_frame
	var with_addon := str(hud.help.get_meta("full_text", ""))
	var camera_at := with_addon.find("With its camera:")
	check(with_addon.contains("Help Test (add-on)\nShift+F10: toggle the thing") and camera_at > 0
		and with_addon.find("I: fly forward") > camera_at, "an add-on's keys show under it, its camera's apart: %s"
		% with_addon.substr(with_addon.find("Help Test")).replace("\n", " | "))
	for action in [toggle, fly]:
		Settings.remove_action(action)
		ControlsInfo.extra.erase(action)
	await get_tree().process_frame
	await get_tree().process_frame
	check(not str(hud.help.get_meta("full_text", "")).contains("Help Test"), "and are gone with the add-on")
	# Too little room: the panel takes the room and scrolls, a line at a time to its last.
	var w := float(Kit.px(ui.HELP_WIDTH))
	ui._help_fit = []
	ui._fit_help(Rect2(Vector2(8, 8), Vector2(w, Kit.px(160))))
	check(hud.help.scroll_active and hud.help.self_modulate.a > 0.0 and absf(hud.help.size.y - Kit.px(160)) < 0.5,
		"too little room: the help scrolls in it (%s)" % hud.help.size)
	ui.scroll_help_lines(3)
	var moved: float = hud.help.get_v_scroll_bar().value
	check(ui.help_top == 3 and moved > 0.0, "three lines down: %d, %.0f px" % [ui.help_top, moved])
	ui.scroll_help_lines(100000)
	var last: int = ui.help_top
	ui.scroll_help_lines(-100000)
	check(last > 3 and ui.help_top == 0 and hud.help.get_v_scroll_bar().value == 0.0, "to its last line (%d) and back to the top" % last)
	# Room enough: all of it, no scroll bar.
	ui._help_fit = []
	ui._fit_help(Rect2(Vector2(8, 8), Vector2(w, Kit.px(3000))))
	check(not hud.help.scroll_active and hud.help.size.y < Kit.px(3000) and hud.help.size.y > Kit.px(160),
		"room enough: all of it, no scroll bar (%.0f px)" % hud.help.size.y)
	ui._help_fit = []
	Settings.set_value("interface", "show_help", had_help)


## A picture of the HUD in a busy state: inventory with a stack in the cursor, the crafting queue,
## weapons, the health bar and a message.


func _esc_tooltip() -> void:
	var EscTooltip = load("res://scripts/ui/esc_tooltip.gd")
	var sv := SubViewport.new()
	sv.size = Vector2i(400, 300)
	sv.gui_embed_subwindows = true
	add_child(sv)
	var resender: Node = EscTooltip.new()
	sv.add_child(resender)
	var catcher := EscCatcher.new()
	sv.add_child(catcher)
	var b := Button.new()
	b.text = "Add to queue"
	b.disabled = true
	b.tooltip_text = "Research queue full"
	b.position = Vector2(100, 100)
	b.size = Vector2(120, 30)
	b.focus_mode = Control.FOCUS_NONE
	sv.add_child(b)
	for i in 2:
		await get_tree().process_frame
	sv.notification(NOTIFICATION_VP_MOUSE_ENTER)
	var esc := func() -> void:
		var ev := InputEventKey.new()
		ev.physical_keycode = KEY_ESCAPE
		ev.keycode = KEY_ESCAPE
		ev.pressed = true
		sv.push_input(ev)
		for i in 3:
			await get_tree().process_frame
	# The mouse comes onto the button and rests until its tooltip is up.
	var rest := func(at: Vector2) -> bool:
		var motion := InputEventMouseMotion.new()
		motion.position = at
		motion.global_position = at
		sv.push_input(motion)
		var limit := Time.get_ticks_msec() + 4000
		while EscTooltip.showing(sv) == null and Time.get_ticks_msec() < limit:
			await get_tree().process_frame
		return EscTooltip.showing(sv) != null
	resender.enabled = true
	await esc.call()
	check(catcher.seen == 1 and resender.resent == 0, "Esc with no tooltip up goes on as ever, sent once (%d seen, %d sent again)" % [catcher.seen, resender.resent])
	var up: bool = await rest.call(Vector2(150, 110))
	check(up, "the mouse resting on a button brings up Godot's tooltip, found as the one showing")
	resender.enabled = false
	await esc.call()
	check(catcher.seen == 1 and EscTooltip.showing(sv) == null,
		"--esc-tooltip=old: Godot spends that Esc on hiding the tooltip and nothing else sees it (%d seen)" % catcher.seen)
	up = await rest.call(Vector2(153, 113))
	resender.enabled = true
	await esc.call()
	check(up and catcher.seen == 2 and resender.resent == 1 and EscTooltip.showing(sv) == null,
		"Esc with a tooltip showing hides it and still reaches the windows' Esc, once (%d seen, %d sent again)" % [catcher.seen, resender.resent])
	await esc.call()
	check(catcher.seen == 3 and resender.resent == 1, "the next Esc, the tooltip gone, isn't sent twice (%d seen)" % catcher.seen)
	# A slot's tooltip is Godot's too, with Zenith's own box in it (Slot._make_custom_tooltip): the inventory with
	# the mouse resting on an item.
	var slot := Slot.new()
	slot.position = Vector2(100, 200)
	slot.set_stack("iron-plate", 5)
	slot.set_tip("Iron plate", [["A plate"]])
	sv.add_child(slot)
	for i in 2:
		await get_tree().process_frame
	up = await rest.call(slot.position + slot.size * 0.5)
	await esc.call()
	check(up and catcher.seen == 4 and resender.resent == 2 and EscTooltip.showing(sv) == null,
		"a slot's tooltip the same: Esc with it showing still reaches the windows' Esc (%s up, %d seen, %d sent again)" % [up, catcher.seen, resender.resent])
	sv.queue_free()


class EscCatcher extends Node:
	var seen := 0

	func _unhandled_input(event: InputEvent) -> void:
		var key := event as InputEventKey
		if key != null and key.pressed and key.physical_keycode == KEY_ESCAPE:
			seen += 1


## The controls when the sections started (Settings.bindable_actions), for _nothing_left_behind.


func _picture(hud: Hud, player: Node) -> void:
	var ui = hud.ui
	var bg := ColorRect.new()
	bg.color = Color(0.45, 0.55, 0.35)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.show_behind_parent = true
	hud.get_child(0).add_child(bg)
	hud.get_child(0).move_child(bg, 0)
	ui.model.set_inventory_slots([["transport-belt", 50], ["iron-plate", 7], ["coal", 20]], 80)
	ui.model.handle({"t": "cq", "pr": 300, "l": [[1, "iron-gear-wheel", 3, 0], [2, "transport-belt", 2, 0]]})
	ui.model.pin(0, "transport-belt")
	ui.model.pin(1, "inserter")
	ui.toggle_inventory()
	click_main(ui, 1)
	hud.set_health(120, 250)
	hud.set_mining(60)
	hud.show_message("Out of reach")
	ui._hover_at = get_viewport().get_visible_rect().size * Vector2(0.5, 0.35)
	ui._hover()
	ui.cursor.over_world_too = true  # no world here to say whether a ghost shows
	await get_tree().create_timer(0.5).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OS.get_cmdline_user_args()[-1])


## Another mod's planet: its icon from the bridge's graphics list (here the fixture mod's) on the
## space map, the platform panel and the statistics, and below a platform once the solar system
## (`smap`) says it is a planet (a platform also stops at places that aren't, such as the edge).


func _all_texts(node: Node) -> Array:
	var out: Array = []
	for child in node.find_children("*", "", true, false):
		if child is Label:
			out.append((child as Label).text)
		elif child is Button:
			out.append((child as Button).text)
	return out


## The child of `parent` that holds `node` (itself, when it is one).


func _alt_sequences() -> void:
	# The layouts alone, in tiles from the machine's centre (x right, y down).
	var asm_row := ["m", 0, 0.7, 0.5, 4, 2, 1.1, -0.1]
	var near := func(got: Array, want: Array) -> bool:
		if got.size() != want.size():
			return false
		for i in got.size():
			if absf(float(got[i]) - float(want[i])) > 0.001:
				return false
		return true
	var four: Array = AltOverlay.sequence_cells(4, asm_row)
	var xs: Array = four.map(func(c): return (c[0] as Vector2).x)
	var on_row := func(c) -> bool:
		return is_equal_approx((c[0] as Vector2).y, 0.7) and is_equal_approx(float(c[1]), 0.5)
	check(four.size() == 4 and near.call(xs, [-0.825, -0.275, 0.275, 0.825]) and four.all(on_row),
		"K1: four modules in an assembling machine 3: one row 0.7 tiles below its centre, 0.55 apart, 0.5 tiles each: %s" % [four])
	var box := Rect2(-1.5, -1.5, 3, 3)
	var lab_packs := ["l", 0, 0, 0.5, 6, 2, 0.909, -0.1]
	var lab_mods := ["m", 0, 0.9, 0.5, 4, 2, 1.1, -0.1]
	var packs: Array = AltOverlay.sequence_cells(7, lab_packs)
	var mods: Array = AltOverlay.sequence_cells(2, lab_mods)
	var rects: Array[Rect2] = []
	for c in packs + mods:
		rects.append(Rect2((c[0] as Vector2) - Vector2(c[1], c[1]) * 0.5, Vector2(c[1], c[1])))
	var inside := rects.all(func(r: Rect2): return box.encloses(r))
	var pack_bottom := 0.0
	for i in 7:
		pack_bottom = maxf(pack_bottom, rects[i].end.y)
	check(packs.size() == 7 and is_equal_approx((packs[0][0] as Vector2).y, -0.1) and is_equal_approx((packs[5][0] as Vector2).y, -0.1)
		and is_equal_approx((packs[6][0] as Vector2).x, 0.0) and absf((packs[6][0] as Vector2).y - (-0.1 + 0.4545)) < 0.001
		and absf((packs[0][0] as Vector2).x + 2.5 * 0.4545) < 0.001,
		"K2: a lab's seven packs: six in the first row lifted 0.1, the seventh centred under them, 0.4545 apart: %s" % [packs])
	check(inside and pack_bottom < rects[7].position.y and is_equal_approx((mods[0][0] as Vector2).y, 0.9),
		"K2: the lab's packs and its modules' row under them fit in its 3 x 3 without overlapping: %.3f < %.3f" % [pack_bottom, rects[7].position.y])
	var base_lab: Array = AltOverlay.sequence_cells(7, ["l", 0, 0, 0.5, 4, 2, 0.909, -0.1])
	check(near.call(base_lab.slice(4).map(func(c): return (c[0] as Vector2).x), [-0.4545, 0.0, 0.4545]),
		"K2: the base game's lab, four a row: the last three centred")
	check(AltOverlay.sequence_cells(9, asm_row).size() == 8
		and (AltOverlay.sequence_cells(1, asm_row)[0][0] as Vector2).is_equal_approx(Vector2(0, 0.7)),
		"K1: no more than a row's icons times its rows; one alone on the shift")
	# Drawn: from above, the rows round each machine's centre on the screen, its own icon by ids.
	var holder := Node3D.new()
	add_child(holder)
	var w := WorldMirror.new()
	holder.add_child(w)
	w.protos.add_entities([[21, "assembling-machine-3", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3],
		[22, "lab", "lab", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3],
		[23, "beacon", "beacon", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3]])
	w.chunks[Vector2i.ZERO] = ChunkView.new()
	w._add([960, 21, 5 * 256 + 128, 5 * 256 + 128, 0, {"ai": ["recipe", "iron-gear-wheel"]}])
	w._add([961, 22, 12 * 256 + 128, 5 * 256 + 128, 0])
	w._add([962, 23, 19 * 256 + 128, 5 * 256 + 128, 0])
	var gs := GDScript.new()
	gs.source_code = "extends Node3D\nvar world\nvar rig\nvar camera: Camera3D\nvar first_person := false\nvar hovered\nvar eprops := {}\n"
	gs.reload()
	var rig: Node3D = gs.new()
	rig.camera = Camera3D.new()
	rig.add_child(rig.camera)
	holder.add_child(rig)
	var fake_player: Node3D = gs.new()
	fake_player.world = w
	fake_player.rig = rig
	var fake_model: Node3D = gs.new()  # only its eprops are read
	fake_model.eprops = {21: {"x": {"ids": [0, -0.3, 1], "isq": [asm_row]}}, 22: {"x": {"isq": [lab_mods, lab_packs]}},
		23: {"x": {"isq": [["m", 0, 0, 0.5, 2, 2, 1.1, -0.3]]}}}
	var overlay := AltOverlay.new()
	overlay.model = fake_model
	overlay.player = fake_player
	overlay.on = true
	add_child(overlay)
	rig.camera.position = Vector3(12.5, 40, 5.5)
	rig.camera.look_at(Vector3(12.5, 0, 5.5), Vector3(0, 0, -1))
	var turns_before: int = Bridge.alt_contents
	Bridge.set_alt_contents(true)
	var seven: Array = ["automation-science-pack", "logistic-science-pack", "military-science-pack", "chemical-science-pack",
		"production-science-pack", "utility-science-pack", "space-science-pack"]
	w.handle({"t": "am", "g": Bridge.alt_contents, "l": [[960, ["speed-module-3", ["speed-module-3", "rare"], "productivity-module-3",
		"productivity-module-3"]], [961, ["speed-module", "speed-module"], seven], [962, ["speed-module-3", "speed-module-3"]]]})
	w.handle({"t": "am", "g": Bridge.alt_contents + 5, "l": [[961]]})
	overlay.collect()
	check(overlay.drawn == 1 + 4 + 9 and (w.alt_machines_now().get(961, []) as Array).size() == 2,
		"K1, K2: the recipe, four modules, seven packs and two modules drawn; the beacon's not while the mouse is off it: %d" % overlay.drawn)
	var anchor := func(x: float) -> Vector2:
		return rig.camera.unproject_position(Vector3(x, Visuals.height_for(w.protos.entity(21)), 5.5))
	var module_rects: Array = overlay._icons.get(Kit.item_icon("productivity-module-3"), [])
	var recipe_rects: Array = overlay._icons.get(Kit.item_icon("iron-gear-wheel"), [])
	var asm_at: Vector2 = anchor.call(5.5)
	var ok_rows := module_rects.size() == 2 and recipe_rects.size() == 1
	if ok_rows:
		var m0: Rect2 = module_rects[0]
		var rc: Rect2 = recipe_rects[0]
		# Tiles as drawn: the recipe icon is ICON_TILES across (held to its 8-80 px, the rows with it).
		var per_tile: float = rc.size.x / AltOverlay.ICON_TILES
		ok_rows = absf((m0.get_center().y - asm_at.y) / per_tile - 0.7) < 0.05 and absf(m0.size.x / per_tile - 0.5) < 0.05 \
			and absf((rc.get_center().y - asm_at.y) / per_tile + 0.3) < 0.05 and rc.end.y < m0.position.y
	check(ok_rows, "K1: on the screen the modules' row sits 0.7 tiles under the machine's centre, its recipe 0.3 over it (ids), apart: %s %s" % [module_rects, recipe_rects])
	var rare := Slot.quality_icon("rare")
	check(rare == null or (overlay._marks.get(rare, []) as Array).size() == 1,
		"K1: a rare module carries its quality's mark (when the install has the picture)")
	fake_player.hovered = w.entities[962]
	overlay.collect()
	check(overlay.drawn == 1 + 4 + 9 + 2, "K1: the beacon's modules with the mouse on it, as Factorio 2.1 draws them: %d" % overlay.drawn)
	fake_player.hovered = null
	rig.first_person = true
	rig.camera.position = Vector3(12.5, 1.6, 14)
	rig.camera.look_at(Vector3(12.5, 1.0, 5.5))
	overlay.collect()
	var shown_quads := overlay._quads.filter(func(q): return q.visible)
	check(overlay.drawn == 1 + 4 + 9 and shown_quads.size() == overlay.drawn + overlay._marks_3d,
		"K1, K2: first person draws them as depth-tested quads (C9), quality marks besides: %d %d" % [overlay.drawn, shown_quads.size()])
	rig.first_person = false
	rig.camera.position = Vector3(12.5, 40, 5.5)
	rig.camera.look_at(Vector3(12.5, 0, 5.5), Vector3(0, 0, -1))
	w.handle({"t": "am", "g": Bridge.alt_contents, "l": [[960], [961, 0, seven.slice(0, 2)]]})
	overlay.collect()
	var cleared := overlay.drawn
	Bridge.set_alt_contents(false)
	overlay.collect()
	check(cleared == 1 + 2 and overlay.drawn == 1 and w.alt_machines_now().is_empty(),
		"K1, K2: [unit] clears a machine's icons, 0 leaves a lab its packs alone, Alt-mode off draws none of them: %d %d" % [cleared, overlay.drawn])
	if turns_before > 0:
		Bridge.set_alt_contents(true)
	overlay.on = false
	overlay._process(0.0)
	overlay.queue_free()
	holder.queue_free()


## K1's leftover: Alt-mode draws an ammo turret's ammo and a locomotive's fuel, one icon a filled
## slot, where the prototype's icons_positioning puts them (2.1's gun turret: its ammo a quarter tile
## over its centre, two a row; its locomotive: its fuel 0.3 under, three a row). A locomotive is a
## mover: its icons are drawn where it is drawn now and go with it. --alt-ammo-fuel=off draws neither.


func _alt_stock() -> void:
	var ammo_row := ["a", 0, -0.25, 0.5, 2, 1, 1.1, -0.1]
	var fuel_row := ["f", 0, 0.3, 0.5, 3, 4, 1.1, -0.1]
	var one: Array = AltOverlay.sequence_cells(1, ammo_row)
	var two: Array = AltOverlay.sequence_cells(2, ammo_row)
	check(one.size() == 1 and (one[0][0] as Vector2).is_equal_approx(Vector2(0, -0.25)) and is_equal_approx(float(one[0][1]), 0.5)
		and two.size() == 2 and absf((two[0][0] as Vector2).x + 0.275) < 0.001 and absf((two[1][0] as Vector2).x - 0.275) < 0.001
		and AltOverlay.sequence_cells(3, ammo_row).size() == 2,
		"K1: a gun turret's ammo: one kind 0.25 tiles over its centre at half a tile, two side by side, never a third: %s %s" % [one, two])
	var three: Array = AltOverlay.sequence_cells(3, fuel_row)
	check(three.size() == 3 and three.all(func(c): return is_equal_approx((c[0] as Vector2).y, 0.3))
		and absf((three[0][0] as Vector2).x + 0.55) < 0.001 and absf((three[2][0] as Vector2).x - 0.55) < 0.001,
		"K1: a locomotive's three fuel slots: one row 0.3 tiles under its centre: %s" % [three])
	var holder := Node3D.new()
	add_child(holder)
	var w := WorldMirror.new()
	holder.add_child(w)
	w.protos.add_entities([[31, "gun-turret", "ammo-turret", -1.0, -1.0, 1.0, 1.0, 150, 150, 150, 2, 2],
		[32, "locomotive", "locomotive", -1.0, -3.0, 1.0, 3.0, 150, 150, 150, 2, 6],
		[33, "cargo-wagon", "cargo-wagon", -1.0, -3.0, 1.0, 3.0, 150, 150, 150, 2, 6]])
	w.chunks[Vector2i.ZERO] = ChunkView.new()
	w._add([970, 31, 6 * 256, 6 * 256, 0])
	w._add([971, 31, 10 * 256, 6 * 256, 0])
	var trains := MoverLayer.new()
	trains.protos = w.protos
	holder.add_child(trains)
	trains.handle({"t": "mv", "k": 1, "l": [[980, 32, 16 * 256, 6 * 256, 0]]})
	trains._process(1.0 / 60.0)
	var gs := GDScript.new()
	gs.source_code = "extends Node3D\nvar world\nvar rig\nvar camera: Camera3D\nvar first_person := false\nvar hovered\nvar movers\nvar eprops := {}\n"
	gs.reload()
	var rig: Node3D = gs.new()
	rig.camera = Camera3D.new()
	rig.add_child(rig.camera)
	holder.add_child(rig)
	var fake_player: Node3D = gs.new()
	fake_player.world = w
	fake_player.rig = rig
	fake_player.movers = trains
	var fake_model: Node3D = gs.new()  # only its eprops are read
	fake_model.eprops = {31: {"x": {"isq": [ammo_row]}}, 32: {"x": {"isq": [fuel_row]}}, 33: {"x": {"isq": [["c", 0, 0, 0.5, 4, 1, 1.1, -0.1]]}}}
	var overlay := AltOverlay.new()
	overlay.model = fake_model
	overlay.player = fake_player
	overlay.on = true
	add_child(overlay)
	rig.camera.position = Vector3(11, 40, 6)
	rig.camera.look_at(Vector3(11, 0, 6), Vector3(0, 0, -1))
	var turns_before: int = Bridge.alt_contents
	var loco_icons_before: bool = Bridge.loco_fuel_icons
	Bridge.loco_fuel_icons = true  # the old way (--loco-fuel-icons=on); off by default, checked below
	Bridge.set_alt_contents(true)
	w.handle({"t": "am", "g": Bridge.alt_contents, "l": [[970, 0, ["firearm-magazine"]], [980, 0, ["coal", ["wood", "rare"]]]]})
	overlay.collect()
	var ammo_rects: Array = overlay._icons.get(Kit.item_icon("firearm-magazine"), [])
	var coal_rects: Array = overlay._icons.get(Kit.item_icon("coal"), [])
	var wood_rects: Array = overlay._icons.get(Kit.item_icon("wood"), [])
	check(overlay.drawn == 3 and ammo_rects.size() == 1 and coal_rects.size() == 1 and wood_rects.size() == 1,
		"K1: the loaded turret's magazine and the locomotive's two fuels drawn, nothing over the empty turret: %d" % overlay.drawn)
	var turret_at: Vector2 = rig.camera.unproject_position(Vector3(6, Visuals.height_for(w.protos.entity(31)), 6))
	var loco_3d: Vector3 = trains.position_of(980)
	var loco_at: Vector2 = rig.camera.unproject_position(loco_3d + Vector3(0, Visuals.height_for(w.protos.entity(32)), 0))
	var placed := ammo_rects.size() == 1 and coal_rects.size() == 1 and wood_rects.size() == 1
	if placed:
		var a: Rect2 = ammo_rects[0]
		var c: Rect2 = coal_rects[0]
		var d: Rect2 = wood_rects[0]
		# A cell is half a tile across: twice its side is a tile on the screen.
		var per_tile: float = a.size.x / 0.5
		placed = absf(a.get_center().x - turret_at.x) < 1.0 and absf((a.get_center().y - turret_at.y) / per_tile + 0.25) < 0.05 \
			and absf((c.get_center().y - loco_at.y) / per_tile - 0.3) < 0.05 and absf((d.get_center().y - loco_at.y) / per_tile - 0.3) < 0.05 \
			and absf((c.get_center().x - loco_at.x) / per_tile + 0.275) < 0.05 and absf((d.get_center().x - loco_at.x) / per_tile - 0.275) < 0.05
	check(placed, "K1: on the screen the ammo sits 0.25 tiles over the turret's centre, the fuel 0.3 under the locomotive's, side by side: %s %s %s (turret %s, locomotive %s)"
		% [ammo_rects, coal_rects, wood_rects, turret_at, loco_at])
	var rare := Slot.quality_icon("rare")
	check(rare == null or (overlay._marks.get(rare, []) as Array).size() == 1, "K1: rare fuel carries its quality's mark (when the install has the picture)")
	# The locomotive drives on: its icons go with it.
	var before_x: float = (coal_rects[0] as Rect2).get_center().x if coal_rects.size() == 1 else 0.0
	for i in 40:
		trains.handle({"t": "mv", "k": 2 + i, "l": [[980, 32, (16 * 256) + 26 * (i + 1), 6 * 256, 0]]})
		trains._process(1.0 / 60.0)
	overlay.collect()
	coal_rects = overlay._icons.get(Kit.item_icon("coal"), [])
	var moved: Vector3 = trains.position_of(980)
	var moved_at: Vector2 = rig.camera.unproject_position(moved + Vector3(0, Visuals.height_for(w.protos.entity(32)), 0))
	check(moved.x > loco_3d.x + 1.0 and coal_rects.size() == 1 and (coal_rects[0] as Rect2).get_center().x > before_x + 1.0
		and absf(((coal_rects[0] as Rect2).get_center().x - moved_at.x) / ((coal_rects[0] as Rect2).size.x / 0.5) + 0.275) < 0.05,
		"K1: the fuel icons follow the locomotive as it is drawn (%.2f -> %.2f tiles): %s" % [loco_3d.x, moved.x, coal_rects])
	# First person: depth-tested quads, as the machines' rows.
	rig.first_person = true
	rig.camera.position = Vector3(11, 1.6, 16)
	rig.camera.look_at(Vector3(11, 1.0, 6))
	overlay.collect()
	var shown_quads := overlay._quads.filter(func(q): return q.visible)
	check(overlay.drawn == 3 and shown_quads.size() == overlay.drawn + overlay._marks_3d,
		"K1: first person draws them as quads too: %d %d" % [overlay.drawn, shown_quads.size()])
	rig.first_person = false
	rig.camera.position = Vector3(11, 40, 6)
	rig.camera.look_at(Vector3(11, 0, 6), Vector3(0, 0, -1))
	# The switch: neither drawn, whatever the bridge sent.
	AltOverlay.ammo_fuel = false
	overlay.collect()
	var off_drawn := overlay.drawn
	AltOverlay.ammo_fuel = true
	overlay.collect()
	check(off_drawn == 0 and overlay.drawn == 3, "K1: --alt-ammo-fuel=off draws no ammo or fuel, as before: %d, on %d" % [off_drawn, overlay.drawn])
	# Wagon items (owner): a cargo wagon's kinds in one row of half-tile cells, following it; the locomotive's fuel
	# gone unless --loco-fuel-icons=on.
	trains.handle({"t": "mv", "k": 60, "l": [[981, 33, 16 * 256, 12 * 256, 0]]})
	trains._process(1.0 / 60.0)
	w.handle({"t": "am", "g": Bridge.alt_contents, "l": [[981, 0, ["iron-plate", "coal", "stone"]]]})
	overlay.collect()
	var plate_rects: Array = overlay._icons.get(Kit.item_icon("iron-plate"), [])
	var wagon_3d: Vector3 = trains.position_of(981)
	var wagon_at: Vector2 = rig.camera.unproject_position(wagon_3d + Vector3(0, Visuals.height_for(w.protos.entity(33)), 0))
	check(plate_rects.size() == 1 and absf(((plate_rects[0] as Rect2).get_center().x - wagon_at.x) / ((plate_rects[0] as Rect2).size.x / 0.5) + 0.55) < 0.05
		and absf((plate_rects[0] as Rect2).get_center().y - wagon_at.y) < 1.0 and overlay.drawn == 6,
		"wagon items: a cargo wagon's three kinds drawn in a row over it (with the 3 already there): %d %s at %s" % [overlay.drawn, plate_rects, wagon_at])
	Bridge.loco_fuel_icons = false
	overlay.collect()
	check(overlay.drawn == 4 and not overlay._icons.has(Kit.item_icon("wood")) and (overlay._icons.get(Kit.item_icon("iron-plate"), []) as Array).size() == 1,
		"wagon items: with --loco-fuel-icons off (default) the locomotive's fuel icons are gone, the wagon's stay: %d" % overlay.drawn)
	Bridge.loco_fuel_icons = true
	trains.remove(981)
	# A turret that ran out is cleared; the locomotive gone from the movers takes its icons with it.
	w.handle({"t": "am", "g": Bridge.alt_contents, "l": [[970], [971, 0, [["piercing-rounds-magazine", "rare"]]]]})
	overlay.collect()
	var swapped := overlay.drawn == 3 and (overlay._icons.get(Kit.item_icon("piercing-rounds-magazine"), []) as Array).size() == 1 \
		and not overlay._icons.has(Kit.item_icon("firearm-magazine"))
	trains.remove(980)
	overlay.collect()
	check(swapped and trains.proto_id_of(980) == 0 and overlay.drawn == 1,
		"K1: [unit] clears a turret out of ammo, another's shows; a locomotive that left takes its icons: %d" % overlay.drawn)
	Bridge.loco_fuel_icons = loco_icons_before
	Bridge.set_alt_contents(false)
	if turns_before > 0:
		Bridge.set_alt_contents(true)
	overlay.on = false
	overlay._process(0.0)
	overlay.queue_free()
	holder.queue_free()


## The owner: "the alt crafting items are stacked backwards, should be closest first not highest": in
## the angled view a north-south line of assemblers' recipe icons overlapped up the screen with the
## farthest drawn in front. Where Alt-mode's icons overlap, the one nearest the camera is drawn last
## (in front): recipes, a lab's two rows of packs (its lower row over the upper) and a turret's ammo
## before it, in the angled view, Factorio's view zoomed out (orthographic, icons held at their 8
## pixels) and first person (quads nearer the camera). --alt-icon-order=old: in the order found.


func _alt_icon_order() -> void:
	var holder := Node3D.new()
	add_child(holder)
	var w := WorldMirror.new()
	holder.add_child(w)
	w.protos.add_entities([[41, "assembling-machine-2", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3],
		[42, "lab", "lab", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3],
		[43, "gun-turret", "ammo-turret", -1.0, -1.0, 1.0, 1.0, 150, 150, 150, 2, 2]])
	w.chunks[Vector2i.ZERO] = ChunkView.new()
	# The assemblers south first: found first, so the old order draws the farthest last, on top.
	for k in 5:
		w._add([990 + k, 41, 20 * 256 + 128, (17 - 3 * k) * 256 + 128, 0, {"ai": ["recipe", "logistic-science-pack"]}])
	w._add([996, 42, 12 * 256 + 128, 5 * 256 + 128, 0])
	w._add([997, 43, 12 * 256 + 128, 7 * 256, 0])
	var gs := GDScript.new()
	gs.source_code = "extends Node3D\nvar world\nvar rig\nvar camera: Camera3D\nvar first_person := false\nvar hovered\nvar movers\nvar eprops := {}\n"
	gs.reload()
	var rig: Node3D = gs.new()
	rig.camera = Camera3D.new()
	rig.add_child(rig.camera)
	holder.add_child(rig)
	var fake_player: Node3D = gs.new()
	fake_player.world = w
	fake_player.rig = rig
	var fake_model: Node3D = gs.new()  # only its eprops are read
	fake_model.eprops = {42: {"x": {"isq": [["l", 0, 0, 0.5, 4, 2, 0.909, -0.1]]}},
		43: {"x": {"isq": [["a", 0, -0.25, 0.5, 2, 1, 1.1, -0.1]]}}}
	var overlay := AltOverlay.new()
	overlay.model = fake_model
	overlay.player = fake_player
	overlay.on = true
	add_child(overlay)
	var turns_before: int = Bridge.alt_contents
	Bridge.set_alt_contents(true)
	var six: Array = ["automation-science-pack", "logistic-science-pack", "military-science-pack", "chemical-science-pack",
		"production-science-pack", "utility-science-pack"]
	# The turret first, the lab after: the old order draws the lab's packs (behind) over its ammo.
	w.handle({"t": "am", "g": Bridge.alt_contents, "l": [[997, 0, ["firearm-magazine"]], [996, 0, six]]})
	# [overlapping pairs of icons at different depths, those drawn with the farther one in front].
	var judge := func() -> Array:
		overlay.collect()
		var icons := overlay.paint_list().filter(func(e): return e[0] == "i")
		var pairs := 0
		var wrong := 0
		for a in icons.size():
			for b in range(a + 1, icons.size()):
				var ra: Rect2 = icons[a][2]
				var rb: Rect2 = icons[b][2]
				if not ra.intersects(rb):
					continue
				var da: float = icons[a][3]
				var db: float = icons[b][3]
				if absf(da - db) > 0.01:
					pairs += 1
					if db > da:  # b drawn after a but farther off
						wrong += 1
		return [pairs, wrong]
	# The lab's lower row over its upper: drawn after it (one machine, one depth: the order found).
	var rows_ok := func() -> bool:
		var icons := overlay.paint_list().filter(func(e): return e[0] == "i")
		var top_at := -1
		var low_at := -1
		for i in icons.size():
			if icons[i][1] == Kit.item_icon("automation-science-pack"):
				top_at = i
			elif icons[i][1] == Kit.item_icon("production-science-pack"):
				low_at = i
		return top_at >= 0 and low_at > top_at
	var views := {
		"angled": func() -> void:
			rig.camera.projection = Camera3D.PROJECTION_PERSPECTIVE
			rig.camera.position = Vector3(16, 6, 24)
			rig.camera.look_at(Vector3(16, 1, 7)),
		"Factorio's view zoomed out": func() -> void:
			rig.camera.projection = Camera3D.PROJECTION_ORTHOGONAL
			rig.camera.size = 260.0
			var pitch := deg_to_rad(48.0)
			rig.camera.position = Vector3(16, 0, 10) + Vector3(0, sin(pitch), cos(pitch)) * 100.0
			rig.camera.look_at(Vector3(16, 0, 10)),
	}
	var cap_before: int = AltOverlay.layer_cap
	for run in ["angled", "Factorio's view zoomed out", "angled, over the layering cap", "Factorio's view zoomed out, over the layering cap"]:
		var view := str(run).trim_suffix(", over the layering cap")
		# Over the cap: one list farthest first, no layers.
		AltOverlay.layer_cap = 0 if run != view else cap_before
		(views[view] as Callable).call()
		AltOverlay.icon_order = true
		var got: Array = judge.call()
		var lab_rows: bool = rows_ok.call()
		# The layers kept for an unchanged view and icons give the same order.
		var kept_same: bool = overlay.paint_list() == (func() -> Array:
			overlay.collect()
			return overlay.paint_list()).call()
		# The turret's ammo overlaps the lab's packs behind it, and is drawn after them.
		var ammo_over := false
		var icons := overlay.paint_list().filter(func(e): return e[0] == "i")
		for i in icons.size():
			if icons[i][1] != Kit.item_icon("firearm-magazine"):
				continue
			for j in i:
				if six.any(func(n): return Kit.item_icon(n) == icons[j][1]) and (icons[i][2] as Rect2).intersects(icons[j][2]):
					ammo_over = true
		AltOverlay.icon_order = false
		var old: Array = judge.call()
		AltOverlay.icon_order = true
		check(int(got[0]) >= 4 and int(got[1]) == 0 and lab_rows and ammo_over and kept_same and overlay.drawn == 5 + 6 + 1
			and overlay._flat == (run != view),
			"alt icon order, %s: where icons overlap the nearer is drawn in front (%d overlapping pairs, %d the wrong way), the lab's lower row after its upper (%s), the turret's ammo over the lab's packs (%s), kept alike (%s)"
			% [run, got[0], got[1], lab_rows, ammo_over, kept_same])
		check(int(old[1]) > 0, "alt icon order, %s: --alt-icon-order=old draws a farther icon over a nearer one (%d of %d), as the owner saw"
			% [run, old[1], old[0]])
	AltOverlay.layer_cap = cap_before
	# First person: quads, which Godot's transparent pass sorts by the distance from the camera less
	# each one's sorting_offset (perspective; renderer_rd's _fill_render_list): a machine's lower row
	# sorts nearer than its upper, looking level at the lab and from below looking up over it.
	rig.camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	rig.first_person = true
	var lab_quads := func() -> Array:
		overlay.collect()
		var top_q: MeshInstance3D = null
		var low_q: MeshInstance3D = null
		for q: MeshInstance3D in overlay._quads:
			if not q.visible:
				continue
			var tex = (q.material_override as ShaderMaterial).get_shader_parameter("icon")
			if tex == Kit.item_icon("automation-science-pack"):
				top_q = q
			elif tex == Kit.item_icon("production-science-pack"):
				low_q = q
		if top_q == null or low_q == null:
			return [-1.0, -1.0]
		var sorted_at := func(q: MeshInstance3D) -> float:
			return rig.camera.global_position.distance_to(q.global_position) - q.sorting_offset
		return [sorted_at.call(top_q), sorted_at.call(low_q)]
	var fp_views := {"level": [Vector3(12.5, 1.6, 14), Vector3(12.5, 1.0, 5.5)],
		"looking up over the icons": [Vector3(12.5, 0.3, 8), Vector3(12.5, 6.0, 4.0)]}
	var old_wrong := 0
	for v in fp_views:
		rig.camera.position = fp_views[v][0]
		rig.camera.look_at(fp_views[v][1])
		var fp: Array = lab_quads.call()
		AltOverlay.icon_order = false
		var fp_old: Array = lab_quads.call()
		AltOverlay.icon_order = true
		if float(fp_old[1]) >= float(fp_old[0]):
			old_wrong += 1
		check(float(fp[1]) > 0.0 and float(fp[1]) < float(fp[0]) - 0.0005,
			"alt icon order, first person, %s: the lab's lower row sorts nearer the camera than its upper, so drawn in front: %s (old %s)"
			% [v, fp, fp_old])
	check(old_wrong > 0, "alt icon order, first person: --alt-icon-order=old sorts the upper row in front from below (%d view)" % old_wrong)
	rig.first_person = false
	Bridge.set_alt_contents(false)
	if turns_before > 0:
		Bridge.set_alt_contents(true)
	overlay.on = false
	overlay._process(0.0)
	overlay.queue_free()
	holder.queue_free()


## Alt-mode's icon order (testing agent): the layers kept for an unchanged view must follow every change
## of the icons (a recipe changed, two recipes swapped, a machine built or mined, a chest's contents, a
## module's quality) and of the camera (a small move), drawing exactly this frame's icons, as a fresh
## layering would; over the layering cap (a big base in Factorio's view zoomed out) nothing is missing
## and the nearer still in front; first person looking down from above, the lab's lower row in front.


func _alt_icon_order_kept() -> void:
	var holder := Node3D.new()
	add_child(holder)
	var w := WorldMirror.new()
	holder.add_child(w)
	w.protos.add_entities([[41, "assembling-machine-2", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3],
		[42, "lab", "lab", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3],
		[9, "wooden-chest", "container", -0.35, -0.35, 0.35, 0.35, 150, 120, 80, 1, 1]])
	for cx in range(-1, 3):
		for cy in range(-1, 3):
			w.chunks[Vector2i(cx, cy)] = ChunkView.new()
	for k in 5:
		w._add([1990 + k, 41, 20 * 256 + 128, (17 - 3 * k) * 256 + 128, 0, {"ai": ["recipe", "logistic-science-pack"]}])
	w._add([1996, 42, 12 * 256 + 128, 5 * 256 + 128, 0])
	w._add([1998, 9, 20 * 256 + 128, 19 * 256 + 128, 0])
	var gs := GDScript.new()
	gs.source_code = "extends Node3D\nvar world\nvar rig\nvar camera: Camera3D\nvar first_person := false\nvar hovered\nvar movers\nvar eprops := {}\n"
	gs.reload()
	var rig: Node3D = gs.new()
	rig.camera = Camera3D.new()
	rig.add_child(rig.camera)
	holder.add_child(rig)
	var fake_player: Node3D = gs.new()
	fake_player.world = w
	fake_player.rig = rig
	var fake_model: Node3D = gs.new()
	fake_model.eprops = {42: {"x": {"isq": [["l", 0, 0, 0.5, 4, 2, 0.909, -0.1], ["m", 0, 0.9, 0.5, 4, 2, 1.1, -0.1]]}}}
	var overlay := AltOverlay.new()
	overlay.model = fake_model
	overlay.player = fake_player
	overlay.on = true
	add_child(overlay)
	var turns_before: int = Bridge.alt_contents
	Bridge.set_alt_contents(true)
	AltOverlay.icon_order = true
	var cap_before: int = AltOverlay.layer_cap
	w.handle({"t": "am", "g": Bridge.alt_contents, "l": [[1996, [["speed-module", "rare"]], ["automation-science-pack", "logistic-science-pack"]]]})
	w.handle({"t": "ac", "g": Bridge.alt_contents, "l": [[1998, "stone"]]})
	rig.camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	rig.camera.position = Vector3(16, 6, 24)
	rig.camera.look_at(Vector3(16, 1, 7))
	# The icons drawn, as [texture, rect] sorted, against this frame's own (overlay._e_*), and against a
	# fresh layering of the same frame: kept layers must draw neither stale nor missing icons.
	var drawn_set := func() -> Array:
		var out := []
		for e in overlay.paint_list():
			if e[0] == "i" or e[0] == "m":
				out.append("%s %d %s" % [e[0], (e[1] as Texture2D).get_instance_id(), e[2]])
		out.sort()
		return out
	var frame_set := func() -> Array:
		var out := []
		for i in overlay._e_tex.size():
			out.append("i %d %s" % [overlay._e_tex[i].get_instance_id(), overlay._e_rect[i]])
			if overlay._e_mark[i] != null:
				out.append("m %d %s" % [(overlay._e_mark[i] as Texture2D).get_instance_id(), overlay._e_mark_rect[i]])
		out.sort()
		return out
	var kept_matches := func(what: String) -> void:
		overlay.collect()
		var kept: Array = overlay.paint_list()
		var kept_set: Array = drawn_set.call()
		var mine: Array = frame_set.call()
		overlay._layers_key = []
		overlay.collect()
		var fresh: Array = overlay.paint_list()
		check(kept_set == mine and kept == fresh and not mine.is_empty(),
			"alt icon order, kept layers after %s: this frame's icons drawn (%d), none stale or missing, as a fresh layering (%s)"
			% [what, mine.size(), kept == fresh])
	overlay.collect()
	overlay.collect()
	kept_matches.call("nothing changed")
	w._add([1992, 41, 20 * 256 + 128, 11 * 256 + 128, 0, {"ai": ["recipe", "automation-science-pack"]}])
	overlay.collect()  # a frame between, so the next is judged against kept layers
	kept_matches.call("a recipe changed")
	w._add([1991, 41, 20 * 256 + 128, 14 * 256 + 128, 0, {"ai": ["recipe", "automation-science-pack"]}])
	w._add([1992, 41, 20 * 256 + 128, 11 * 256 + 128, 0, {"ai": ["recipe", "logistic-science-pack"]}])
	overlay.collect()
	kept_matches.call("two recipes swapped between neighbours")
	w._add([1999, 41, 20 * 256 + 128, 20 * 256 + 128, 0, {"ai": ["recipe", "electronic-circuit"]}])
	kept_matches.call("a machine built")
	w._remove(1993)
	kept_matches.call("a machine mined")
	w.handle({"t": "ac", "g": Bridge.alt_contents, "l": [[1998, "coal"]]})
	kept_matches.call("a chest's contents changed")
	w.handle({"t": "am", "g": Bridge.alt_contents, "l": [[1996, [["speed-module", "epic"]], ["automation-science-pack", "logistic-science-pack"]]]})
	kept_matches.call("a module's quality changed")
	rig.camera.position += Vector3(0.01, 0, 0)
	kept_matches.call("the camera moved a hundredth of a tile")
	# Over the cap for real: a big base of machines in Factorio's view zoomed out, icons held at their
	# smallest so most overlap. Every icon drawn, and none behind a farther one.
	var recipes := ["iron-gear-wheel", "electronic-circuit", "copper-cable", "transport-belt", "inserter", "pipe"]
	var unit := 3000
	for gx in 30:
		for gy in 30:
			w._add([unit, 41, (gx * 3 - 30) * 256 + 128, (gy * 3 - 30) * 256 + 128, 0, {"ai": ["recipe", recipes[unit % recipes.size()]]}])
			unit += 1
	rig.camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	rig.camera.size = 260.0
	var pitch := deg_to_rad(48.0)
	rig.camera.position = Vector3(16, 0, 10) + Vector3(0, sin(pitch), cos(pitch)) * 100.0
	rig.camera.look_at(Vector3(16, 0, 10))
	overlay.collect()  # the icons loaded from the install first
	var icons := overlay.paint_list().filter(func(e): return e[0] == "i")
	var wrong := 0
	var pairs := 0
	for a in icons.size():
		var ra: Rect2 = icons[a][2]
		for b in range(a + 1, icons.size()):
			if absf(float(icons[a][3]) - float(icons[b][3])) > 0.01 and ra.intersects(icons[b][2]):
				pairs += 1
				if float(icons[b][3]) > float(icons[a][3]):
					wrong += 1
	check(overlay._flat and icons.size() == overlay._e_tex.size() and icons.size() >= 900 and pairs > 100 and wrong == 0,
		"alt icon order, %d icons over the layering cap (%d): every one drawn (%d), %d overlapping pairs, %d the wrong way"
		% [overlay._e_tex.size(), AltOverlay.layer_cap, icons.size(), pairs, wrong])
	# Cost (printed, headless): a frame's collect with the order made again (walking), kept (standing)
	# and the old order, in Factorio's view zoomed out (most icons overlap) and the angled view.
	var timed := func(rebuild: bool) -> float:
		var total := 0
		for k in 5:
			if rebuild:
				overlay._layers_key = []
			var t0 := Time.get_ticks_usec()
			overlay.collect()
			total += Time.get_ticks_usec() - t0
		return total / 5000.0
	for cap in [cap_before, 100000]:
		AltOverlay.layer_cap = cap
		for v in ["zoomed out", "angled"]:
			if v == "angled":
				rig.camera.projection = Camera3D.PROJECTION_PERSPECTIVE
				rig.camera.position = Vector3(16, 25, 45)
				rig.camera.look_at(Vector3(16, 0, 5))
			else:
				rig.camera.projection = Camera3D.PROJECTION_ORTHOGONAL
				rig.camera.position = Vector3(16, 0, 10) + Vector3(0, sin(pitch), cos(pitch)) * 100.0
				rig.camera.look_at(Vector3(16, 0, 10))
			overlay.collect()
			var made: float = timed.call(true)
			var kept: float = timed.call(false)
			AltOverlay.icon_order = false
			var old: float = timed.call(false)
			AltOverlay.icon_order = true
			print("alt icon order cost (headless, %s, %d icons, cap %d, %s): collect %.2f ms with the order made, %.2f kept, %.2f old"
				% [v, overlay._e_tex.size(), cap, "flat" if overlay._flat else "%d layers" % overlay._layers_used, made, kept, old])
	# The same in a 1920 x 1080 window, Factorio's view at the furthest default zoom (140) and further
	# (260), with fewer machines in view: the layering's cost grows with how many icons overlap.
	var window_before := get_window().size
	get_window().size = Vector2i(1920, 1080)
	AltOverlay.layer_cap = 100000
	for keep in [909, 600, 300]:
		for u in range(3000 + keep, unit):
			w._remove(u)
		for size in [140.0, 260.0]:
			rig.camera.projection = Camera3D.PROJECTION_ORTHOGONAL
			rig.camera.size = size
			rig.camera.position = Vector3(16, 0, 10) + Vector3(0, sin(pitch), cos(pitch)) * 100.0
			rig.camera.look_at(Vector3(16, 0, 10))
			overlay.collect()
			var made: float = timed.call(true)
			var kept: float = timed.call(false)
			AltOverlay.icon_order = false
			var old: float = timed.call(false)
			AltOverlay.icon_order = true
			print("alt icon order cost (headless, %s, Factorio's view size %d, %d icons, %d layers): collect %.2f ms with the order made, %.2f kept, %.2f old"
				% [overlay.get_viewport_rect().size, size, overlay._e_tex.size(), overlay._layers_used, made, kept, old])
	# Quality marks: a farther icon's mark must not be drawn over a nearer icon that covers it. The
	# grid's assemblers get a rare module each (a module row, its mark) and are looked at zoomed out.
	fake_model.eprops[41] = {"x": {"isq": [["m", 0, 0.7, 0.5, 4, 2, 1.1, -0.1]]}}
	# The mark's picture is the install's (Slot.quality_icon): without one (CI) a stand-in, so the
	# marks are still made and their order checked.
	var mark_standin := Slot.quality_icon("rare") == null
	if mark_standin:
		var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.2, 0.5, 1.0))
		Slot._quality_icons["rare"] = ImageTexture.create_from_image(img)
	var with_modules := []
	for u in range(3000, 3000 + 300):
		with_modules.append([u, [["speed-module", "rare"]]])
	w.handle({"t": "am", "g": Bridge.alt_contents, "l": with_modules})
	rig.camera.size = 260.0
	rig.camera.position = Vector3(16, 0, 10) + Vector3(0, sin(pitch), cos(pitch)) * 100.0
	rig.camera.look_at(Vector3(16, 0, 10))
	var marks_over := func() -> int:
		overlay._layers_key = []
		overlay.collect()
		var list: Array = overlay.paint_list()
		var owner_depth := {}
		for i in overlay._e_tex.size():
			if overlay._e_mark[i] != null:
				owner_depth[overlay._e_mark_rect[i]] = overlay._e_depth[i]
		var bad := 0
		for pm in list.size():
			if list[pm][0] != "m":
				continue
			var d: float = owner_depth.get(list[pm][2], -1.0)
			for pi in pm:
				if list[pi][0] == "i" and float(list[pi][3]) < d - 0.01 and (list[pm][2] as Rect2).intersects(list[pi][2]):
					bad += 1
					break
		return bad
	for cap in [100000, cap_before]:
		AltOverlay.layer_cap = cap
		var bad: int = marks_over.call()
		var marks := overlay.paint_list().filter(func(e): return e[0] == "m").size()
		if cap != cap_before:
			check(marks >= 300 and bad == 0, "alt icon order, layered: no quality mark drawn over a nearer icon (%d of %d marks)" % [bad, marks])
		else:
			# Printed, not checked: over the cap the marks are all drawn last (a testing note for the coder).
			print("alt icon order, over the layering cap (%d icons, flat %s): %d of %d quality marks drawn over a nearer icon"
				% [overlay._e_tex.size(), overlay._flat, bad, marks])
	fake_model.eprops.erase(41)
	if mark_standin:
		Slot._quality_icons.erase("rare")
	get_window().size = window_before
	rig.camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	rig.camera.position = Vector3(16, 0, 10) + Vector3(0, sin(pitch), cos(pitch)) * 100.0
	rig.camera.look_at(Vector3(16, 0, 10))
	AltOverlay.layer_cap = cap_before
	for u in range(3000, unit):
		w._remove(u)
	# First person from above, looking down on the lab: its lower row still sorts in front.
	rig.camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	rig.first_person = true
	rig.camera.position = Vector3(12.5, 9.0, 9.0)
	rig.camera.look_at(Vector3(12.5, 1.0, 5.5))
	overlay.collect()
	var top_q: MeshInstance3D = null
	var low_q: MeshInstance3D = null
	var module_q: MeshInstance3D = null
	for q: MeshInstance3D in overlay._quads:
		if not q.visible:
			continue
		var tex = (q.material_override as ShaderMaterial).get_shader_parameter("icon")
		if tex == Kit.item_icon("automation-science-pack"):
			top_q = q
		elif tex == Kit.item_icon("logistic-science-pack"):
			low_q = q
		elif tex == Kit.item_icon("speed-module"):
			module_q = q
	var sorted_at := func(q: MeshInstance3D) -> float:
		return rig.camera.global_position.distance_to(q.global_position) - q.sorting_offset
	check(top_q != null and low_q != null and float(sorted_at.call(low_q)) < float(sorted_at.call(top_q)),
		"alt icon order, first person from above: the lab's second pack (after its first) sorts nearer the camera: %s / %s"
		% [sorted_at.call(top_q) if top_q != null else -1.0, sorted_at.call(low_q) if low_q != null else -1.0])
	if top_q != null and module_q != null:
		print("alt icon order, first person from above: the lab's first pack sorts at %.9f, its module row (another row, below) at %.9f"
			% [sorted_at.call(top_q), sorted_at.call(module_q)])
	rig.first_person = false
	Bridge.set_alt_contents(false)
	if turns_before > 0:
		Bridge.set_alt_contents(true)
	overlay.on = false
	overlay._process(0.0)
	overlay.queue_free()
	holder.queue_free()


## Turrets (turrets.gd) from the mod's turret states: folded until a target comes, raised at
## Factorio's preparing_speed, turned at its rotation_speed, shots no faster than the cooldown, a
## laser's beam, folded again after the target has gone.
