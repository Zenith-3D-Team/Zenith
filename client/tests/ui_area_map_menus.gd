extends "res://tests/ui_test_base.gd"
## UI test sections: map_menus.

func _map_layers_cache(ui) -> void:
	var lm := UiModel.new()
	var settings = UiSettings.shared()
	var layers := MapLayersScript.new()
	layers.model = lm
	layers.size = Vector2(300, 300)
	add_child(layers)
	var chart := func(ov: Array) -> void:
		lm.handle({"t": "chart", "cx": 0, "cy": 0, "n": 1, "pal": [[20, 220, 40]], "px": [0], "ov": ov})
	var rows := [["e", 5 * 256, 5 * 256, 2.5], ["w", 5 * 256, 5 * 256, 12 * 256, 5 * 256], ["l", 20 * 256, 20 * 256, 25, 55],
		["b", 8 * 256, 8 * 256], ["s", 10 * 256, 12 * 256, "Iron"]]
	chart.call(rows)
	lm.handle({"t": "mtr", "si": lm.shown_surface(), "part": 1, "parts": 1, "l": [], "cov": []})
	layers.redraw(Vector2(16, 16), 2.0)
	await get_tree().process_frame
	# (Lambdas keep a copy of a local: `before` is one Dictionary, refilled.)
	var before: Dictionary = layers.drawn.duplicate()
	var renders: int = layers.renders
	# Turret coverage is off by default: a hidden layer isn't drawn.
	check(MapLayersScript.LAYERS.all(func(l): return l == "turret" or int(before.get(l, 0)) >= 1) and layers.cached.texture == layers._vp.get_texture(),
		"the map's layers are drawn into a SubViewport shown as one texture: %s" % [before])
	var since := func(layer: String) -> int: return int(layers.drawn.get(layer, 0)) - int(before.get(layer, 0))
	var settle := func() -> void:
		layers._drawn_msec -= MapLayersScript.DATA_REDRAW_MSEC + 1
		layers.follow(Vector2(16, 16), 2.0, false)
	# Trains come once a second: only their layer.
	lm.handle({"t": "mtr", "si": lm.shown_surface(), "part": 1, "parts": 1, "l": [256, 512, 250, 1485, 460, 0xEB1200]})
	settle.call()
	var armed: bool = layers._vp.render_target_update_mode == SubViewport.UPDATE_ONCE
	await get_tree().process_frame
	check(since.call("trains") == 1 and since.call("electric") == 0 and since.call("logistic") == 0 and since.call("construction") == 0
		and since.call("shade") == 0 and since.call("wires") == 0 and since.call("marks") == 0 and layers.renders == renders + 1 and armed,
		"new trains draw the trains layer again and not the coverage layers, and the texture renders once: %s" % [layers.drawn])
	# The same chart again (the views ask every few seconds): nothing.
	before.clear()
	before.merge(layers.drawn)
	renders = layers.renders
	chart.call(rows)
	settle.call()
	await get_tree().process_frame
	check(layers.drawn == before and layers.renders == renders, "a chart that comes again unchanged draws nothing again")
	# A pole's area changed: the electric layer, and the texture is armed again.
	var poles: Array = rows.duplicate(true)
	poles[0][3] = 3.5
	chart.call(poles)
	settle.call()
	armed = layers._vp.render_target_update_mode == SubViewport.UPDATE_ONCE
	await get_tree().process_frame
	check(since.call("electric") == 1 and since.call("trains") == 0 and since.call("logistic") == 0 and since.call("marks") == 0
		and layers.renders == renders + 1 and armed,
		"a changed supply area draws the electric layer again and re-arms the texture (UPDATE_ONCE): %s" % [layers.drawn])
	# A robot moved: only the markers; new data waits DATA_REDRAW_MSEC.
	before.clear()
	before.merge(layers.drawn)
	poles[3][1] = 9 * 256
	chart.call(poles)
	layers.follow(Vector2(16, 16), 2.0, false)
	await get_tree().process_frame
	var waited: bool = layers.drawn == before
	settle.call()
	await get_tree().process_frame
	check(waited and since.call("marks") == 1 and since.call("electric") == 0 and since.call("wires") == 0,
		"a moved robot draws only the markers, after a moment: %s" % [layers.drawn])
	# The roboports' list: the logistic and construction layers (and what counts as seen).
	before.clear()
	before.merge(layers.drawn)
	lm.roboports_changed.emit()
	settle.call()
	await get_tree().process_frame
	check(since.call("logistic") == 1 and since.call("construction") == 1 and since.call("electric") == 0 and since.call("trains") == 0,
		"new roboports draw the logistic and construction layers again")
	# Moving a little only moves the texture; past shift_px everything is drawn again there.
	before.clear()
	before.merge(layers.drawn)
	renders = layers.renders
	layers.follow(Vector2(20, 16), 2.0, false)
	var moved: Vector2 = layers.shift_now()
	var cached_at: Vector2 = layers.cached.position
	layers.follow(Vector2(40, 16), 2.0, false)
	await get_tree().process_frame
	check(moved == Vector2(-8, 0) and cached_at == Vector2(-8 - MapLayersScript.SHIFT_PX, -MapLayersScript.SHIFT_PX) and layers.renders == renders + 1
		and since.call("electric") == 1 and since.call("trains") == 1,
		"moving 4 tiles moves the texture 8 px; 24 tiles on everything is drawn again: %s %s" % [moved, cached_at])
	# A map switch shows at once (no wait).
	before.clear()
	before.merge(layers.drawn)
	settings.set_value("map/show_turrets", not bool(settings.get_value("map/show_turrets")))
	layers.follow(Vector2(40, 16), 2.0, false)
	await get_tree().process_frame
	settings.set_value("map/show_turrets", not bool(settings.get_value("map/show_turrets")))
	check(since.call("turret") == 1, "a map switch draws the layers again at once")
	layers.queue_free()
	# The map view (M) still draws its layers, in its own SubViewport, and moves them while panning.
	var view = ui.map_view
	ui.open_map(true)
	await get_tree().process_frame
	await get_tree().process_frame
	var vl = view.layers
	var vbefore: Dictionary = vl.drawn.duplicate()
	check(view.is_open() and vl.cached.visible and vl.cached.texture == vl._vp.get_texture() and vl.shift_px == view.LAYERS_SHIFT_PX
		and vl.centre == view.centre and Vector2(vl._vp.size) == vl.size + Vector2.ONE * 2.0 * vl.shift_px * vl._screen_scale(),
		"the map view draws its layers into a SubViewport the size of the window and its margins: %s" % [vl._vp.size])
	view.following = false
	view.centre += Vector2(10, 0) / view.scale_now()
	await get_tree().process_frame
	var panned: Vector2 = vl.shift_now()
	var still_drawn: bool = vl.drawn == vbefore
	view.centre += Vector2(200, 0) / view.scale_now()
	await get_tree().process_frame
	check(still_drawn and panned == Vector2(-10, 0) and vl.centre == view.centre and int(vl.drawn.get("electric", 0)) > int(vbefore.get("electric", 0)),
		"panning the map moves its layers and draws them again past %d px: %s" % [view.LAYERS_SHIFT_PX, panned])
	ui.open_map(false)
	await get_tree().process_frame


## The minimap, the map view (M, Esc), the tag dialog's commands, and how charts are asked for.
## The alert bar's alerts on the minimap and the map view (alerts.gd map_marks, map_cache.gd draw_alerts):
## at their spots, the shown surface's only, the bar's kinds only, the important ones drawn last, none
## outside the square, none with --minimap-alerts=off, drawn again only when the blink flips.


func _minimap_alerts(ui) -> void:
	var m = ui.model
	var mini = ui.minimap
	var view = ui.map_view
	ui.close_all()
	await get_tree().process_frame
	m.map_si = 0
	m.set_character_surface(1)
	MapCache.alerts_clock_msec = 500  # the blink's on half: every kind drawn
	await get_tree().process_frame
	var c: Vector2 = mini._drawn_at
	var e := func(kind: String, t: Vector2, si: int, unit: int) -> Array:
		return [kind, 1, [[roundi(t.x * 256.0), roundi(t.y * 256.0), si, "gun-turret", unit]]]
	m.handle({"t": "al", "l": [
		e.call("destroyed", c + Vector2(4, 0), 1, 901), e.call("attack", c + Vector2(4, 0), 1, 902),
		e.call("no_ammo", c + Vector2(-4, 2), 1, 903), e.call("fire", c + Vector2(2, -3), 3, 904),
		e.call("no_power", c + Vector2(1, 1), 1, 905), e.call("output_full", c + Vector2(-1, -1), 1, 906),
		e.call("no_material", c + Vector2(0, 3), 1, 907), e.call("train_path", c + Vector2(100000, 0), 1, 908)]})
	for i in 3:
		await get_tree().process_frame
	var kinds_of := func(placed: Array) -> Array: return placed.map(func(p: Array) -> String: return str(p[0]))
	var spot_of := func(placed: Array, kind: String) -> Vector2:
		for p in placed:
			if p[0] == kind:
				return p[1]
		return Vector2.INF
	var placed: Array = mini.alerts_placed
	var kinds: Array = kinds_of.call(placed)
	var scale: float = mini.scale_now()
	var middle: Vector2 = mini._area.size / 2.0
	var ammo_at: Vector2 = spot_of.call(placed, "no_ammo")
	check(kinds.size() == 4 and kinds.has("no_ammo") and kinds.has("attack") and kinds.has("destroyed") and kinds.has("no_material")
		and ammo_at.distance_to(middle + (c + Vector2(-4, 2) - mini._drawn_at) * scale) < 1.0,
		"the minimap draws the bar's alerts at their spots; another surface's, status-only, hidden and far ones not: %s" % [placed])
	check(kinds.find("destroyed") > kinds.find("attack") and kinds.find("attack") > kinds.find("no_ammo"),
		"destroyed is drawn over attack over the rest (Factorio's 0.9.7 order): %s" % [kinds])
	# The map view: the same, at its own scale; another surface's once the map shows that surface.
	ui.open_map(true)
	view.centre = c
	view.following = false
	view.zoom = 4.0
	view._redraw = true
	for i in 3:
		await get_tree().process_frame
	var vk: Array = kinds_of.call(view.alerts_placed)
	var vat: Vector2 = spot_of.call(view.alerts_placed, "no_ammo")
	check(vk.size() == 4 and not vk.has("fire") and vat.distance_to(view.tiles_to_screen(c + Vector2(-4, 2))) < 1.0,
		"the map view draws them at their spots too: %s" % [view.alerts_placed])
	m.map_si = 3  # as show_surface(3) leaves it, without asking for that surface's tags and pad
	view._redraw = true
	for i in 3:
		await get_tree().process_frame
	vk = kinds_of.call(view.alerts_placed)
	check(vk == ["fire"], "on the other surface's map only that surface's alert: %s" % [vk])
	m.map_si = 0
	view.following = true
	ui.open_map(false)
	await get_tree().process_frame
	# Blinking: a redraw when the phase flips while there are alerts, not every frame.
	var flips := false
	for attempt in 3:
		mini._blink_was = not MapCache.alerts_blink_on(Time.get_ticks_msec())
		if mini._alerts_blinked() and not mini._alerts_blinked():
			flips = true
			break
	check(flips, "the minimap is drawn again when the blink flips, not on the next frame")
	check(not MapCache.alerts_blink_on(0) and not MapCache.alerts_blink_on(449) and MapCache.alerts_blink_on(450)
		and MapCache.alerts_blink_on(999) and not MapCache.alerts_blink_on(1000), "the blink: off 45% of each second, on 55%, as over the entities")
	MapCache.alerts_clock_msec = 0  # the off half: the blinking kinds hide, the steady ones (as over the entities) stay
	mini._redraw = true
	for i in 3:
		await get_tree().process_frame
	check(kinds_of.call(mini.alerts_placed) == ["no_material"], "in the blink's off half only the steady kinds show: %s" % [mini.alerts_placed])
	MapCache.alerts_clock_msec = 500
	# (Testing) Muted in the Alerts configuration silences the beep only, so the maps still show the kind; a
	# disabled kind leaves the bar and the maps.
	var ac = ui.alerts_config
	ac.set_flag("Turret out of ammunition", "muted", true)
	ac.set_flag("Entity destroyed", "disabled", true)
	m.alerts_changed.emit()
	mini._redraw = true
	for i in 3:
		await get_tree().process_frame
	kinds = kinds_of.call(mini.alerts_placed)
	check(kinds.has("no_ammo") and kinds.has("attack") and not kinds.has("destroyed"),
		"a muted kind stays on the minimap, a disabled one leaves it: %s" % [kinds])
	ac.set_flag("Turret out of ammunition", "muted", false)
	ac.set_flag("Entity destroyed", "disabled", false)
	m.alerts_changed.emit()
	await get_tree().process_frame
	check(ui.alerts.map_marks().any(func(d: Dictionary) -> bool: return d["kind"] == "destroyed"), "and back when enabled again")
	# (Testing) The minimap following another surface's map shows that surface's alert only.
	m.map_si = 3
	mini._redraw = true
	for i in 3:
		await get_tree().process_frame
	check(not kinds_of.call(mini.alerts_placed).has("no_ammo") and not kinds_of.call(mini.alerts_placed).has("destroyed"),
		"the minimap on another surface leaves the character's surface's alerts out: %s" % [mini.alerts_placed])
	m.map_si = 0
	# (Testing) The map view zoomed far in and far out: each alert at its tile's spot, the far one never.
	ui.open_map(true)
	view.centre = c
	view.following = false
	for z in [0.05, 0.5, 16.0]:
		view.zoom = z
		view._redraw = true
		for i in 3:
			await get_tree().process_frame
		var zk: Array = kinds_of.call(view.alerts_placed)
		print("TESTER map view zoom %s: size %s scale %.2f placed %s" % [z, view.size, view.scale_now(), view.alerts_placed])
		# Every alert placed at its own tile's spot; every one whose spot is on screen placed (those just off
		# the edge may still show, by the icon's size); never the far one, never another surface's.
		var want := {"destroyed": Vector2(4, 0), "attack": Vector2(4, 0), "no_ammo": Vector2(-4, 2), "no_material": Vector2(0, 3)}
		var ok := not zk.has("train_path") and not zk.has("fire")
		for p in view.alerts_placed:
			ok = ok and want.has(p[0]) and (p[1] as Vector2).distance_to(view.tiles_to_screen(c + want[p[0]])) < 1.0
		for k in want:
			if Rect2(Vector2.ZERO, view.size).has_point(view.tiles_to_screen(c + want[k])):
				ok = ok and zk.has(k)
		check(ok and not zk.is_empty(), "the map view at zoom %s: the alerts on it at their spots, the far one never: %s" % [z, view.alerts_placed])
	view.following = true
	ui.open_map(false)
	await get_tree().process_frame
	# (Testing) A big list (40 of each of 7 kinds, the bridge's PER_KIND; 5 of them on the maps): the cost of one minimap draw of them.
	var big: Array = []
	var n_big := 0
	for kind in ["destroyed", "attack", "no_ammo", "no_fuel", "unplugged", "no_material", "train_path"]:
		var ents: Array = []
		for j in 40:
			var t := c + Vector2(float(j % 8) * 3.0 - 12.0, float(j / 8) * 3.0 - 7.0) + Vector2(0.5, 0.5) * float(n_big % 3)
			ents.append([roundi(t.x * 256.0), roundi(t.y * 256.0), 1, "gun-turret", 2000 + n_big * 40 + j])
		big.append([kind, 40, ents])
		n_big += 1
	m.handle({"t": "al", "l": big})
	await get_tree().process_frame
	var marks: Array = ui.alerts.map_marks()
	var probe := Control.new()
	probe.size = mini._area.size
	var cost := [0, 0, 0]  # usec for 20 draws, placed, usec for 20 map_marks()
	var probe_draw := func() -> void:
		var t0 := Time.get_ticks_usec()
		var placed_n := 0
		for r in 20:
			placed_n = MapCache.draw_alerts(probe, marks, func(t: Vector2) -> Vector2: return probe.size / 2.0 + (t - c) * scale,
				float(Kit.px(16)), Rect2(Vector2.ZERO, probe.size), 1).size()
		cost[0] = Time.get_ticks_usec() - t0
		cost[1] = placed_n
		t0 = Time.get_ticks_usec()
		for r in 20:
			ui.alerts.map_marks()
		cost[2] = Time.get_ticks_usec() - t0
	probe.draw.connect(probe_draw)
	add_child(probe)
	await get_tree().process_frame
	await get_tree().process_frame
	probe.queue_free()
	print("TESTER minimap alerts cost: %d marks, %d placed, draw_alerts %.1f us each, map_marks %.1f us each"
		% [marks.size(), cost[1], cost[0] / 20.0, cost[2] / 20.0])
	check(marks.size() == 200 and cost[1] > 0 and cost[0] / 20.0 < 2000.0,
		"280 alerts sent, 200 on the maps (no_fuel and unplugged are status-only): one draw of them under 2 ms (%.1f us, %d placed)" % [cost[0] / 20.0, cost[1]])
	# (Testing) Redraws on the real clock over 120 frames, with the same `al` again every second as the bridge
	# sends it: the minimap is drawn again on the blink's flips and on `al`, not every frame.
	MapCache.alerts_clock_msec = -1
	var draws := [0]
	var count_draw := func() -> void: draws[0] += 1
	mini._area.draw.connect(count_draw)
	var t_start := Time.get_ticks_msec()
	var als := 0
	var next_al := 0
	for f in 120:
		if Time.get_ticks_msec() - t_start >= next_al:
			m.handle({"t": "al", "l": big})
			als += 1
			next_al += 1000
		await get_tree().process_frame
	var span := Time.get_ticks_msec() - t_start
	var flips_due := int(span / 500) + 2
	print("TESTER minimap redraws, alerts: %d draws in 120 frames over %d ms, %d al messages" % [draws[0], span, als])
	check(draws[0] < 120 and draws[0] <= flips_due + als + 1,
		"with alerts the minimap is drawn on blink flips and updates only: %d draws, 120 frames, %d ms, %d al" % [draws[0], span, als])
	# The same with no alerts (for the report: an unchanged `al` still asks for a redraw).
	m.handle({"t": "al", "l": []})
	await get_tree().process_frame
	draws[0] = 0
	t_start = Time.get_ticks_msec()
	als = 0
	next_al = 0
	for f in 120:
		if Time.get_ticks_msec() - t_start >= next_al:
			m.handle({"t": "al", "l": []})
			als += 1
			next_al += 1000
		await get_tree().process_frame
	span = Time.get_ticks_msec() - t_start
	print("TESTER minimap redraws, no alerts: %d draws in 120 frames over %d ms, %d al messages" % [draws[0], span, als])
	check(draws[0] == 0, "with no alerts an unchanged `al` draws nothing: %d draws, %d al" % [draws[0], als])
	mini._area.draw.disconnect(count_draw)
	# shown_changed (the maps' redraw) fires only when the marks change, never with the switch off.
	var fired := [0]
	var count_fired := func() -> void: fired[0] += 1
	ui.alerts.shown_changed.connect(count_fired)
	var one := [e.call("destroyed", c + Vector2(4, 0), 1, 901)]
	m.handle({"t": "al", "l": one})
	m.handle({"t": "al", "l": one})
	m.handle({"t": "al", "l": one})
	check(fired[0] == 1, "one change, then the same `al` twice: the maps told once (%d)" % fired[0])
	m.handle({"t": "al", "l": [e.call("destroyed", c + Vector2(5, 0), 1, 901)]})
	check(fired[0] == 2, "an alert that moved: the maps told again (%d)" % fired[0])
	# Steady kinds alone: the blink's flips draw nothing.
	m.handle({"t": "al", "l": [["no_material", 1, [[roundi(c.x * 256.0), roundi(c.y * 256.0), 1, "inserter", 905, "iron-plate"]]]]})
	var steady_flip := false
	for half in [0, 500, 1000]:
		MapCache.alerts_clock_msec = half
		steady_flip = steady_flip or mini._alerts_blinked() or view._alerts_blinked()
	check(not ui.alerts.map_marks().is_empty() and not steady_flip, "only steady kinds shown: no redraw on the blink's flips")
	MapCache.alerts_clock_msec = -1
	Alerts.map_marks_on = false
	m.handle({"t": "al", "l": []})
	var off_from := int(fired[0])
	m.handle({"t": "al", "l": one})
	m.handle({"t": "al", "l": [e.call("attack", c + Vector2(4, 0), 1, 902)]})
	m.handle({"t": "al", "l": []})
	check(fired[0] == off_from, "--minimap-alerts=off: alerts coming and going never ask the maps to redraw (%d)" % (fired[0] - off_from))
	Alerts.map_marks_on = true
	ui.alerts.shown_changed.disconnect(count_fired)
	# (Testing) No bridge traffic of its own: nothing about alerts was sent.
	var asked: Array = sent().filter(func(msg: Dictionary) -> bool: return str(msg.get("t", "")).begins_with("al"))
	check(asked.is_empty(), "the maps' alerts send nothing to the bridge: %s" % [asked])
	m.handle({"t": "al", "l": [
		e.call("destroyed", c + Vector2(4, 0), 1, 901), e.call("no_ammo", c + Vector2(-4, 2), 1, 903)]})
	await get_tree().process_frame
	# The switch off: nothing on either view.
	MapCache.alerts_clock_msec = 500
	Alerts.map_marks_on = false
	mini._redraw = true
	for i in 3:
		await get_tree().process_frame
	check(mini.alerts_placed.is_empty() and ui.alerts.map_marks().is_empty() and not mini._alerts_blinked() and not mini._alerts_blinked(),
		"--minimap-alerts=off: no alerts on the maps, no blink redraws")
	Alerts.map_marks_on = true
	MapCache.alerts_clock_msec = -1
	m.handle({"t": "al", "l": []})
	await get_tree().process_frame
	check(ui.alerts.map_marks().is_empty(), "no alerts: nothing to draw")


func _map(ui) -> void:
	ui.map_cache.flush()
	check(ui.map_cache.is_charted(Vector2i(1, -2)) and not ui.map_cache.is_charted(Vector2i(5, 0)), "charts reach the map's pages")
	check(ui.minimap.visible, "minimap shows")
	sent()
	key(KEY_M)
	await get_tree().process_frame
	check(ui.map_open() and ui.minimap.visible, "M opens the map; the minimap stays (H22)")
	var view = ui.map_view
	view.centre = Vector2(300, -200)
	view.following = false
	view.zoom = 2.0
	await get_tree().process_frame
	await get_tree().process_frame
	check(ui.minimap.look_at == Vector2(300, -200) and ui.minimap._drawn_at == Vector2(300, -200) and ui.minimap.map_asks,
		"in the map view the minimap follows the map's view, which does the asking (H22): %s" % [ui.minimap._drawn_at])
	view.centre = Vector2.ZERO
	await get_tree().process_frame
	# Right click on empty ground: create a tag there.
	var spot: Vector2 = view.tiles_to_screen(Vector2(-20, 12))
	view.edit_tag_at(spot)
	check(view.dialog.is_open() and not view.dialog.editing, "right click opens the create-tag dialog")
	view.dialog.text_field.text = "Copper"
	view.dialog._pick("copper-ore")
	view.dialog._confirm()
	var add := sent_one("tag_add")
	check(add.get("text") == "Copper" and add.get("icon") == ["item", "copper-ore"]
		and absf(float(add.get("x", 0)) / 256.0 + 20.0) < 0.5 and absf(float(add.get("y", 0)) / 256.0 - 12.0) < 0.5
		and not view.dialog.is_open(), "confirm sends tag_add at the clicked spot")
	# On the existing tag (id 3 at 5, -2): edit, then delete.
	view.edit_tag_at(view.tiles_to_screen(Vector2(5, -2)))
	check(view.dialog.editing and view.dialog.text_field.text == "base" and view.dialog.icon_name == "iron-plate", "right click on a tag edits it")
	view.dialog.deleted.emit()
	view.dialog.close()
	check(sent_one("tag_del").get("id") == 3, "delete sends tag_del")
	view.edit_tag_at(view.tiles_to_screen(Vector2(5, -2)))
	key(KEY_ESCAPE)
	await get_tree().process_frame
	check(not view.dialog.is_open() and ui.map_open(), "Esc closes the tag dialog first")
	var before: Vector2 = view.centre
	view.zoom_by(2.0, Vector2(10, 10))
	check(view.zoom == 4.0 and view.centre != before, "wheel zoom keeps the point under the mouse")
	key(KEY_ESCAPE)
	await get_tree().process_frame
	check(not ui.map_open() and ui.minimap.visible, "Esc closes the map")
	await get_tree().process_frame
	check(ui.minimap.look_at == Vector2.INF and not ui.minimap.map_asks, "and the minimap follows the character again")
	key(KEY_M)
	await get_tree().process_frame
	key(KEY_M)
	await get_tree().process_frame
	check(not ui.map_open(), "M again closes it")
	# Owner's #1: the game menu (front_end.gd) gets Esc before the HUD and asks ui.escape(), so
	# everything the HUD can have open must say yes there, not only the windows in is_open().
	check(not ui.escape(), "with nothing open Esc is left to the game menu")
	var esc_cases := {
		"the map view": [func() -> void: ui.open_map(true), func() -> bool: return ui.map_open()],
		"the quickbar's page chooser": [func() -> void: ui.quickbar.open_chooser(0, true), func() -> bool: return ui.quickbar.chooser_open()],
		"the remote view": [func() -> void: ui.remote = true, func() -> bool: return ui.remote],
		"the blueprint library": [func() -> void: ui.planners.toggle_library(), func() -> bool: return ui.planners.library_window.is_open()],
		"the inventory": [func() -> void: ui.toggle_inventory(), func() -> bool: return ui.is_open()],
	}
	for what in esc_cases:
		esc_cases[what][0].call()
		await get_tree().process_frame
		var was_open: bool = esc_cases[what][1].call()
		var took := bool(ui.escape())
		check(was_open and took and not esc_cases[what][1].call(), "Esc closes %s instead of opening the game menu" % what)
		ui.close_all()
	check(not ui.escape(), "and then nothing is left open")
	# Requests: a 40 x 10 chunk area goes out as two blocks (the mod takes 32 x 32 at most), one at
	# a time; asking for the same area again sends nothing until the refresh.
	var cache = ui.map_cache
	sent()
	var n0: int = cache.requests_sent
	cache.want(Rect2i(0, 0, 40, 10), 4, 60.0)
	var req := sent_one("map")
	check(req.get("res") == 4 and int(req.get("cx2", 99)) - int(req.get("cx1", 0)) < 32 and cache.requests_sent == n0 + 1, "map request in blocks of 32 chunks")
	cache.want(Rect2i(0, 0, 40, 10), 4, 60.0)
	check(cache.requests_sent == n0 + 1, "same area: no new request while the first block is coming")
	# Settings: the minimap's switch and size.
	var settings = UiSettings.shared()
	settings.set_value("map/minimap", false)
	check(not ui.minimap.visible, "minimap setting hides it")
	settings.set_value("map/minimap", true)
	settings.set_value("map/minimap_size", 9999)
	check(settings.get_value("map/minimap_size") == 480 and ui.minimap.size.x == ui.minimap.side_px(), "minimap size is clamped and applied (as far as the window has room)")
	ui.minimap.set_max_side(INF)
	check(ui.minimap.size.x == Kit.px(480), "with room it is the full size")
	settings.set_value("map/minimap_size", 240)
	var cfg := ConfigFile.new()
	check(cfg.load(TEST_SETTINGS) == OK and cfg.get_value("map", "minimap_size") == 240, "UI settings are saved in the one settings file")
	Settings.set_value("map", "minimap", false)
	check(not ui.minimap.visible, "a change through settings.gd reaches the minimap too")
	Settings.set_value("map", "minimap", true)

	# The map view's layers: they come with the charts and follow the map view's switches.
	var m = ui.model
	m.handle({"t": "chart", "cx": 0, "cy": 0, "n": 1, "pal": [[10, 20, 30]], "px": [0], "ov": [
		["e", 2560, 2560, 2.5], ["t", 2816, 2560, 18], ["l", 3072, 3072, 25, 55], ["s", 2048, 2048, "Iron"],
		["g", 1536, 1536, 1], ["c", 3584, 2048, "iron-gear-wheel"], ["b", 1024, 1024]]})
	var ov: Array = m.map_overlays.get(Vector2i(0, 0), [])
	check(ov.size() == 7 and ov[0][0] == "e" and ov[0][1] == 10.0 and ov[3][3] == "Iron", "chart overlays reach the model in tiles")
	key(KEY_M)
	await get_tree().process_frame
	view.centre = Vector2(10, 10)
	view.following = false
	view.zoom = 4.0
	view._redraw = true
	await get_tree().process_frame
	var turrets: Button = view.panel.find_child("map-show_turrets", true, false)
	check(turrets != null and not turrets.button_pressed and not view.layers._groups["turret"][0].visible, "turret coverage is off by default")
	check(turrets.toggle_mode and turrets.theme_type_variation == "FSideButton" and turrets.tooltip_text == "Turret coverage"
		and view.panel.find_child("TrainsOverview", true, false) == null,
		"Factorio's map view settings: an icon toggle per layer with its name as the tooltip, no extra Trains button (C5)")
	turrets.button_pressed = true
	await get_tree().process_frame
	await get_tree().process_frame
	check(bool(settings.get_value("map/show_turrets")) and view.layers._groups["turret"][0].visible, "the map view's switch turns turret coverage on")
	check(view.layers._visible_entries(0).size() == 7, "the layers find the chunk's entries in view")
	settings.set_value("map/show_electric", false)
	var electric: Button = view.panel.find_child("map-show_electric", true, false)
	await get_tree().process_frame
	await get_tree().process_frame
	check(not electric.button_pressed and not view.layers._groups["electric"][0].visible, "a switch changed in Settings shows on the map view")
	settings.set_value("map/show_electric", true)
	settings.set_value("map/show_turrets", false)

	# The surface switcher: a button per planet and platform; another surface's map is asked for
	# with its `si`, its charts are kept apart, and closing the map goes back to the character's.
	m.set_character_surface(1)
	m.handle({"t": "surfs", "l": [[1, "nauvis", "nauvis", "", 0], [3, "vulcanus", "vulcanus", "", 0], [5, "platform-1", "", "Orbiter", 1]]})
	await get_tree().process_frame
	var vulcanus: Button = view.surfaces_panel.find_child("Surface3", true, false)
	check(view.surfaces_panel.visible and vulcanus != null and view.surfaces_panel.find_child("Surface5", true, false) != null,
		"the map lists the planets and platforms to switch to")
	# H13: the map's logistic layer shows every roboport of the surface (`mrp`), not only those in the
	# charts loaded, and their construction areas count as seen (not dimmed).
	var was_ready: bool = Bridge.world_ready
	Bridge.world_ready = true
	sent()
	m.ask_roboports(1)
	var mrp_ask := sent_one("mrp")
	m.ask_roboports(1)
	var mrp_again := sent_one("mrp")
	Bridge.world_ready = was_ready
	check(int(mrp_ask.get("si", 0)) == 1 and mrp_again.is_empty(), "a map asks for its surface's roboports (mrp), not again for 10 s: %s" % [mrp_ask])
	var mq := int(mrp_ask.get("q", 0))
	m.handle({"t": "mrp", "si": 1, "q": mq, "part": 1, "last": 0, "l": [1000 * 256, 1000 * 256, 25 * 256, 55 * 256]})
	check(m.roboports_of(1).is_empty(), "a list in parts counts once its last part is in")
	m.handle({"t": "mrp", "si": 1, "q": mq, "part": 2, "last": 1, "l": [3072, 3072, 25 * 256, 55 * 256]})
	check(m.roboports_of(1).size() == 8 and m.roboport_covers(1, Vector2i(31, 31)) and m.roboport_covers(1, Vector2i(30, 32))
		and not m.roboport_covers(1, Vector2i(34, 31)) and not m.roboport_covers(3, Vector2i(31, 31)),
		"the roboports arrive, and the chunks whose middle a construction area holds count as seen")
	m.handle({"t": "mtr", "si": 1, "part": 1, "parts": 1, "l": [], "cov": []})
	check(m.map_coverage_known and m.chunk_covered(Vector2i(31, 31), Vector2(-5000, 0)) and not m.chunk_covered(Vector2i(40, 40), Vector2(-5000, 0)),
		"the map dims what no radar sees but not a roboport's construction area (H13)")
	view.centre = Vector2(1000, 1000)
	view.zoom = 1.0
	view.layers.redraw(view.centre, view.scale_now())
	var far_squares: Array = view.layers.roboport_squares("construction")
	check(far_squares.size() == 1 and is_equal_approx(far_squares[0].size.x, 110.0 * view.scale_now()),
		"the map view draws a roboport far from every chart loaded: %s" % [far_squares])
	view.centre = Vector2(12, 12)
	view.layers.redraw(view.centre, view.scale_now())
	check(view.layers.roboport_squares("logistic").size() == 1, "one in a chart's rows and the list is drawn once")
	m.handle({"t": "mrp", "si": 1, "q": mq, "part": 1, "last": 1, "l": []})
	check(view.layers.roboport_squares("logistic").size() == 1 and not m.roboport_covers(1, Vector2i(31, 31)),
		"the list empties; a roboport the charts show is still drawn from them")
	view.centre = Vector2.ZERO
	view.zoom = 4.0
	var plain: Array = view._plain_name("[item=space-science-pack] run [planet=vulcanus]")
	check(not str(plain[0]).contains("[") and str(plain[0]).contains("run") and plain[1] == "space-science-pack",
		"a platform's rich-text name shows as words, its first item as the icon: %s" % [plain])
	sent()
	vulcanus.pressed.emit()
	await get_tree().process_frame
	var lpad_ask := {}
	for msg in sent():
		if msg.get("t", "") == "lpad":
			lpad_ask = msg
	check(int(lpad_ask.get("si", 0)) == 3 and view.centre == Vector2.ZERO, "switching to a planet asks where its landing pad is (H23): %s" % [lpad_ask])
	m.handle({"t": "lpad", "si": 3, "q": int(lpad_ask.get("q", 0)), "x": 40 * 256, "y": -30 * 256})
	check(view.centre == Vector2(40, -30), "and the map centres on it: %s" % [view.centre])
	view.show_surface(3)
	lpad_ask = sent_one("lpad")
	view.zoom_by(1.0 / view.ZOOM_STEP, Vector2(10, 10))
	var moved: Vector2 = view.centre
	m.handle({"t": "lpad", "si": 3, "q": int(lpad_ask.get("q", 0)), "x": 400 * 256, "y": 0})
	check(view.centre == moved, "an answer after the view was moved leaves it where it is")
	view.zoom = 4.0
	cache._last_send = -1e9
	cache.want(Rect2i(-2, -2, 4, 4), 4, 60.0)
	var vreq := sent_one("map")
	check(m.map_si == 3 and int(vreq.get("si", 0)) == 3 and not cache.is_charted(Vector2i(1, -2)), "switching asks for that surface's map")
	m.handle({"t": "chart", "cx": 0, "cy": 0, "n": 1, "pal": [[200, 80, 20]], "px": [0], "si": 3})
	m.handle({"t": "chart", "cx": 7, "cy": 7, "n": 1, "pal": [[1, 2, 3]], "px": [0], "si": 1})
	m.handle({"t": "tags", "l": [[9, 0, 0, "Lava", "", ""]], "si": 3})
	check(cache.is_charted(Vector2i(0, 0)) and not cache.is_charted(Vector2i(7, 7)) and m.map_tags.size() == 1,
		"charts and tags of the shown surface are kept, a late chart of the other is dropped")
	view.edit_tag_at(view.tiles_to_screen(Vector2(30, 30)))
	view.dialog.text_field.text = "Here"
	view.dialog._confirm()
	check(int(sent_one("tag_add").get("si", 0)) == 3, "a tag goes on the shown surface")
	# Factorio's Remote view frame: title bar and Surfaces; no Add tag / Add ping panel (the owner's call).
	await get_tree().process_frame
	var frame = ui.remote_frame
	check(frame.visible and frame.mode == "map" and view.surfaces_panel.get_parent() == frame and _texts(frame).has("Remote view")
		and _texts(frame).has("Surfaces") and frame.find_child("SpaceMap", true, false) != null and frame.find_child("AddPlatform", true, false) != null,
		"the map is framed as Factorio's Remote view: title bar, Surfaces (Space map, Planets, Platforms, + Add space platform)")
	check(frame.find_child("AddTag", true, false) == null and frame.find_child("AddPing", true, false) == null
		and frame.find_child("Quick_coal", true, false) == null and not _texts(frame).has("Add tag"),
		"no Add tag / Add ping panel or quick tag icons on the map")
	check(view.panel.visible and ui.minimap.visible and view.panel.get_global_rect().position.y >= ui.minimap.get_global_rect().end.y,
		"the map view settings go under the minimap, which the map view keeps (H22)")
	sent()
	var right := InputEventMouseButton.new()
	right.button_index = MOUSE_BUTTON_RIGHT
	right.pressed = true
	right.position = view.tiles_to_screen(Vector2(3, 3))
	view._gui_input(right)
	right = right.duplicate()
	right.pressed = false
	view._gui_input(right)
	var ask := sent_one("unghost")
	check(not view.dialog.is_open() and ask.get("x") == 3 * 256 and ask.get("y") == 3 * 256,
		"a right-click on the map first asks the mod to remove a ghost there (owner's #22): %s" % [ask])
	m.handle({"t": "unghost", "q": int(ask.get("q", 0)), "n": 1})
	check(not view.dialog.is_open(), "a ghost was removed: no tag dialog")
	right = right.duplicate()
	right.pressed = true
	view._gui_input(right)
	ask = sent_one("unghost")
	m.handle({"t": "unghost", "q": int(ask.get("q", 0)), "n": 0})
	check(view.dialog.is_open(), "no ghost there: the right-click opens the tag dialog, as before")
	view.dialog.close()
	key(KEY_ESCAPE)
	await get_tree().process_frame
	check(m.map_si == 0 and cache.is_charted(Vector2i(1, -2)) and cache._stash.has(3),
		"closing the map goes back to the character's surface and its charts")
	key(KEY_M)
	await get_tree().process_frame
	key(KEY_ESCAPE)
	await get_tree().process_frame
	settings.set_value("map/minimap_tags", false)
	check(not bool(Settings.get_value("map", "minimap_tags")), "tags on the minimap can be switched off")
	settings.set_value("map/minimap_tags", true)

	# The older ui.cfg and audio.cfg are read into the one file, once.
	var legacy_ui := ConfigFile.new()
	legacy_ui.set_value("map", "minimap_size", 300)
	legacy_ui.set_value("map", "minimap", false)
	legacy_ui.save("user://ui-test-legacy-ui.cfg")
	var legacy_audio := ConfigFile.new()
	legacy_audio.set_value("audio", "music", 0.4)
	legacy_audio.set_value("effects", "enabled", false)
	legacy_audio.save("user://ui-test-legacy-audio.cfg")
	Settings.legacy = {"user://ui-test-legacy-ui.cfg": {"map": "map"}, "user://ui-test-legacy-audio.cfg": {"audio": "sound"}}
	DirAccess.remove_absolute("user://ui-test-migrated.cfg")
	Settings.use_file("user://ui-test-migrated.cfg")
	check(Settings.get_value("map", "minimap_size") == 300 and Settings.get_value("map", "minimap") == false
		and is_equal_approx(float(Settings.get_value("sound", "music")), 0.4) and Settings.get_value("graphics", "effects") == false,
		"ui.cfg and audio.cfg values are migrated into settings.cfg")
	Settings.set_value("map", "minimap_size", 200)
	Settings.use_file("user://ui-test-migrated.cfg")
	check(Settings.get_value("map", "minimap_size") == 200, "and only once")
	Settings.legacy = {}
	Settings.use_file(TEST_SETTINGS)

	# UI scale changes live: Ctrl+= / Ctrl+- step through Factorio's scales, Ctrl+0 is automatic.
	Settings.set_value("interface", "ui_scale", "1.5")
	check(is_equal_approx(Settings.wanted_ui_scale(), 1.5), "a chosen UI scale is the one wanted")
	Settings.step_ui_scale(1)
	check(Settings.get_value("interface", "ui_scale") == "1.75", "Ctrl+= steps up to the next scale")
	Settings.step_ui_scale(-2)
	check(Settings.get_value("interface", "ui_scale") == "1.25", "Ctrl+- steps down, as the dropdown stores it")
	Settings.set_value("interface", "ui_scale", "2.0")
	Settings.step_ui_scale(1)
	check(Settings.get_value("interface", "ui_scale") == "2.0", "and stops at 200%")
	check(InputMap.has_action("increase_ui_scale") and InputMap.has_action("reset_ui_scale"), "the UI scale keys are controls")
	Settings.set_value("interface", "ui_scale", "auto")
	for f in ["user://ui-test-legacy-ui.cfg", "user://ui-test-legacy-audio.cfg", "user://ui-test-migrated.cfg"]:
		DirAccess.remove_absolute(f)


## The Settings window's tabs, key bindings, the map generator and the mods list, with the server
## folders pointed at a test folder.
## Under a look that draws its own passes (the Cinematic shaders) MSAA is greyed out and a saved MSAA
## is switched to SMAA in the settings (Settings.MSAA_UNDER_LOOK), at the start and when such a look
## comes on mid-run; Zenith's own looks keep it. SMAA is the default.


func _menus() -> void:
	# A modded save whose mod is missing (or at another version): Factorio 2.1.24's --sync-mods tries
	# to download it, fails without a login and says only "unknown error"; its log names the mod.
	var sync_out := "   4.689 Info ModPortal.cpp:612: Downloading /download/space-exploration-graphics/6a762ff78fa6a8630ec108e9?username=<private>&token=<private> to C:\\Users\\x\\Temp\\data\\temp\\space-exploration-graphics_0.7.7.zip\n   4.890 Info HttpSharedState.cpp:187: Status code: 403\nFailed to sync mods with save: Failed to sync mods, unknown error - check the log file."
	var missing := ServerLauncher.missing_from_sync(sync_out)
	check(missing.size() == 1 and missing[0].contains("space-exploration-graphics 0.7.7"),
		"a modded save's mod missing from the mods folder is named with its version, not \"unknown error\": %s" % [missing])
	var data := OS.get_user_data_dir().path_join("ui-test-server")
	DirAccess.make_dir_recursive_absolute(data.path_join("mods/factorio-3d-bridge"))
	DirAccess.make_dir_recursive_absolute(data.path_join("mods/some-mod"))
	_write(data.path_join("mods/factorio-3d-bridge/info.json"), JSON.stringify({"name": "factorio-3d-bridge", "version": "0.2.0", "title": "Zenith bridge"}))
	_write(data.path_join("mods/some-mod/info.json"), JSON.stringify({"name": "some-mod", "version": "1.0.0", "title": "Some mod"}))
	DirAccess.remove_absolute(data.path_join("mods/mod-list.json"))
	Settings.set_value("factorio", "server_data", data)

	var w: Node = SettingsWindow.new()
	add_child(w)
	await get_tree().process_frame
	var find := func(n: String) -> Node: return w.find_child(n, true, false)
	check(w.current_tab() == "Graphics" and find.call("graphics-effects") != null, "the settings window opens on Graphics")
	(find.call("graphics-effects") as CheckBox).button_pressed = false
	check(not FxSettings.effects_enabled, "Show smoke and particles turns the effects off")
	(find.call("graphics-effects") as CheckBox).button_pressed = true
	# The owner's belt step-up: on by default, its box turns the character's step onto belts off and on.
	var step_box := find.call("graphics-belt_step") as CheckBox
	var step_on := Avatar.belt_step()
	if step_box != null:
		step_box.button_pressed = false
	var step_off := Avatar.belt_step()
	if step_box != null:
		step_box.button_pressed = true
	check(step_box != null and step_on and not step_off and Avatar.belt_step() and bool(Settings.DEFAULTS["graphics"]["belt_step"]),
		"Graphics > Step onto belts: on by default, off turns the belt step-up off, on again back")
	(find.call("graphics-brightness") as HSlider).value = 1.2
	check(is_equal_approx(float(Settings.get_value("graphics", "brightness")), 1.2), "brightness applies while dragged")
	var env := Environment.new()
	Settings.apply_environment(env)
	check(env.adjustment_enabled and is_equal_approx(env.adjustment_brightness, 1.2), "and adjusts the 3D environment")
	(find.call("graphics-brightness") as HSlider).value = 1.0
	var filter: Node = ColorFilter.new()
	add_child(filter)
	var filters := find.call("graphics-color_filter") as OptionButton
	filters.select(2)
	filters.item_selected.emit(2)
	check(Settings.get_value("graphics", "color_filter") == "deuteranopia" and filter.visible, "a colour filter covers the screen")
	filters.select(0)
	filters.item_selected.emit(0)
	check(not filter.visible, "and None takes it away")
	filter.queue_free()
	# Render distance: the default is the dual split (View distance (full) 2..50 and Distant horizon 0..512, each its
	# own slider); Manual horizon split off gives one Render distance 2..512 auto-balanced by the 4-tier Level of
	# detail. Far lamp lighting is a setting again.
	var view := find.call("graphics-view_radius") as HSlider
	var view_value := find.call("graphics-view_radius-value") as Button
	var lod_dd := find.call("graphics-lod_quality") as OptionButton
	var view_was := view.value
	var lod_was := lod_dd.selected if lod_dd != null else 1
	var manual_chk := find.call("graphics-distant_horizon_manual") as CheckBox
	var far_lamps := find.call("graphics-far_lights") as CheckBox
	var tints: Array = []
	for v in [10, 11, 20, 21, 50]:
		tints.append(SettingsWindow.view_distance_tint(float(v)))
	var dh_slider := find.call("graphics-distant_horizon") as HSlider
	var dh_value := find.call("graphics-distant_horizon-value") as Button
	var dh_quality := find.call("graphics-distant_horizon_quality") as OptionButton
	var dh_dropoff := find.call("graphics-distant_horizon_dropoff") as OptionButton
	var dh_off_ok: bool = int(Settings.DEFAULTS["graphics"]["distant_horizon"]) == 96 and dh_slider != null and int(dh_slider.value) == 96 and dh_value != null and dh_value.text == "96 chunks (3072 tiles)"
	var dh_on_text := ""
	if dh_slider != null and dh_value != null:
		dh_slider.value = 128
		dh_on_text = dh_value.text
		dh_slider.value = 96
	var dh_q_ok: bool = dh_quality != null and dh_quality.item_count == 5 and dh_quality.get_item_text(dh_quality.selected) == "Medium"
	var dh_d_ok: bool = dh_dropoff != null and dh_dropoff.item_count == 3 and str(Settings.DEFAULTS["graphics"]["distant_horizon_dropoff"]) == "balanced" and dh_dropoff.get_item_text(dh_dropoff.selected) == "Balanced"
	check(RenderDistance.is_manual_split(PackedStringArray()) and manual_chk != null and manual_chk.button_pressed
		and view != null and int(view.max_value) == Settings.VIEW_RADIUS_SLIDER_MAX and Settings.VIEW_RADIUS_MAX == WorldMirror.MAX_VIEW_RADIUS
		and tints == [Color(0, 0, 0, 0), Kit.RED_TEXT, Kit.RED_TEXT, Kit.RED_TEXT, Kit.RED_TEXT]
		and dh_off_ok and dh_slider != null and int(dh_slider.max_value) == Settings.DISTANT_HORIZON_SLIDER_MAX and int(dh_slider.step) == 16
		and dh_on_text == "128 chunks (4096 tiles)" and dh_q_ok and dh_d_ok,
		"Graphics > Render distance: the default is the dual split, View distance (full) + Distant horizon 0..512 (%s) [%s]" % [dh_on_text, [manual_chk != null and manual_chk.button_pressed, view != null and int(view.max_value), tints, dh_off_ok, dh_slider != null and int(dh_slider.max_value), dh_q_ok, dh_d_ok]])
	# Far lamp lighting drives main.gd's far lights (the control is back, the key is read).
	var far_was: bool = bool(Settings.get_value("graphics", "far_lights"))
	check(far_lamps != null and far_lamps.button_pressed == far_was and bool(Settings.DEFAULTS["graphics"]["far_lights"]),
		"Graphics > Far lamp lighting: the checkbox is there and on by default")
	# Manual horizon split off: the one unified Render distance slider and Level of detail.
	if manual_chk != null:
		manual_chk.button_pressed = false
		await get_tree().process_frame
		await get_tree().process_frame
		view = find.call("graphics-view_radius") as HSlider
		view_value = find.call("graphics-view_radius-value") as Button
		lod_dd = find.call("graphics-lod_quality") as OptionButton
		view_was = view.value
		view.value = 500
		var text_500_med := view_value.text if view_value != null else ""
		var text_500_ultra := ""
		var text_500_low := ""
		if lod_dd != null and lod_dd.item_count == 4:
			lod_was = lod_dd.selected
			lod_dd.select(3)
			lod_dd.item_selected.emit(3)
			text_500_ultra = view_value.text
			lod_dd.select(0)
			lod_dd.item_selected.emit(0)
			text_500_low = view_value.text
			lod_dd.select(lod_was)
			lod_dd.item_selected.emit(lod_was)
		view.value = view_was
		var dh_glow := find.call("graphics-distant_horizon_glow") as CheckBox
		var dh_shots := find.call("graphics-distant_horizon_shots") as CheckBox
		var split_off := find.call("graphics-distant_horizon_manual") as CheckBox
		check(not RenderDistance.is_manual_split(PackedStringArray()) and view != null and int(view.max_value) == Settings.RENDER_DISTANCE_MAX
			and lod_dd != null and lod_dd.item_count == 4
			and text_500_med == "500 chunks (8 full + LOD)" and text_500_ultra == "500 chunks (16 full + LOD)" and text_500_low == "500 chunks (5 full + LOD)"
			and find.call("graphics-distant_horizon") == null and find.call("graphics-distant_horizon_quality") == null
			and find.call("graphics-distant_horizon_dropoff") == null and dh_glow != null and dh_glow.button_pressed
			and dh_shots != null and dh_shots.button_pressed and split_off != null and not split_off.button_pressed,
			"Graphics > Manual horizon split off: unified Render distance 2..512 auto-balanced by 4-tier LOD (%s / %s / %s)" % [text_500_low, text_500_med, text_500_ultra])
		if split_off != null:
			split_off.button_pressed = true
		await get_tree().process_frame
		await get_tree().process_frame
		check(RenderDistance.is_manual_split(PackedStringArray()) and find.call("graphics-distant_horizon") != null,
			"and back on, the dual split's two sliders return")
	# Graphics presets: High is today's defaults; a preset sets its settings together and the
	# individual settings stay; changing one by hand shows Custom.
	for key in Settings.PRESETS["high"]:
		check(Settings.PRESETS["high"][key] == Settings.DEFAULTS["graphics"][key], "the High preset keeps the default %s" % key)
	for preset in Settings.PRESETS:
		check((Settings.PRESETS[preset] as Dictionary).keys() == (Settings.PRESETS["high"] as Dictionary).keys(), "the %s preset sets the same settings as High" % preset)
	# The Graphics cards show each control's description as its tooltip (the Moving belt items row has one).
	var belt_box: Control = find.call("graphics-belt_updates")
	check(belt_box != null and belt_box.tooltip_text.begins_with("Max moving belt items"),
		"settings: the Graphics cards give each control its description as a tooltip")
	var preset_box := find.call("graphics-preset") as OptionButton
	check(preset_box != null and str(preset_box.get_item_metadata(preset_box.selected)) == Settings.preset_now(), "the Graphics tab shows the preset in use")
	for i in preset_box.item_count:
		if preset_box.get_item_metadata(i) == "low":
			preset_box.select(i)
			preset_box.item_selected.emit(i)
	await get_tree().process_frame
	check(Settings.get_value("graphics", "shadows") == "low" and Settings.get_value("graphics", "ssao") == false
		and int(Settings.get_value("graphics", "view_radius")) == 5 and Settings.preset_now() == "low", "the Low preset sets shadows, SSAO and view distance together")
	check(str((find.call("graphics-shadows") as OptionButton).get_item_metadata((find.call("graphics-shadows") as OptionButton).selected)) == "low",
		"and the tab's controls show the new values")
	check(bool(Settings.DEFAULTS["graphics"]["ssao"]) and ["high", "ultra"].all(func(p: String) -> bool: return Settings.PRESETS[p]["ssao"] == true)
		and ["low", "medium"].all(func(p: String) -> bool: return Settings.PRESETS[p]["ssao"] == false),
		"ambient occlusion is on by default and in High and Ultra, off in Low and Medium (ao_zoom.gd switches it off zoomed out)")
	check(bool(Settings.DEFAULTS["graphics"]["contact_shading"]) and Settings.PRESETS.values().all(func(p: Dictionary) -> bool: return p["contact_shading"] == true),
		"contact shading is on by default and in every preset")
	check(is_equal_approx(float(Settings.DEFAULTS["graphics"]["god_rays"]), 0.5)
		and is_equal_approx(float(Settings.PRESETS["low"]["god_rays"]), 0.0)
		and is_equal_approx(float(Settings.PRESETS["medium"]["god_rays"]), 0.25)
		and is_equal_approx(float(Settings.PRESETS["high"]["god_rays"]), 0.5)
		and is_equal_approx(float(Settings.PRESETS["ultra"]["god_rays"]), 0.5)
		and find.call("graphics-god_rays") != null,
		"god_rays defaults to 0.5, matches preset progression (0/0.25/0.5/0.5), and exposes Settings slider")
	var keep_path := Settings.path
	var before_cfg := ConfigFile.new()
	before_cfg.set_value("graphics", "ssao", true)
	before_cfg.save("user://ssao-once-test.cfg")
	Settings.use_file("user://ssao-once-test.cfg")
	var turned_off: bool = Settings.get_value("graphics", "ssao") == false
	Settings.set_value("graphics", "ssao", true)
	Settings.use_file("user://ssao-once-test.cfg")
	check(turned_off and Settings.get_value("graphics", "ssao") == true,
		"a settings file saved before has SSAO turned off once; turned on again, it stays on")
	Settings.use_file(keep_path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://ssao-once-test.cfg"))
	# An older save of the unified Render distance (view_radius past View distance's 50) is split into View distance
	# (full) + Distant horizon once, and later changes are kept.
	var ud_cfg := ConfigFile.new()
	ud_cfg.set_value("graphics", "view_radius", 256)
	ud_cfg.set_value("graphics", "distant_horizon", 0)
	ud_cfg.set_value("graphics", "distant_horizon_manual", false)
	ud_cfg.save("user://unified-dist-test.cfg")
	Settings.use_file("user://unified-dist-test.cfg")
	var migrated_256: bool = int(Settings.get_value("graphics", "distant_horizon")) == 256 and int(Settings.get_value("graphics", "view_radius")) <= Settings.VIEW_RADIUS_MAX 		and bool(Settings.get_value("graphics", "distant_horizon_manual"))
	Settings.set_value("graphics", "view_radius", 10)
	Settings.use_file("user://unified-dist-test.cfg")
	check(migrated_256 and int(Settings.get_value("graphics", "view_radius")) == 10 and int(Settings.get_value("graphics", "distant_horizon")) == 256,
		"a saved unified view_radius past 50 migrates once into View distance (full) + Distant horizon and respects later changes")
	Settings.use_file(keep_path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://unified-dist-test.cfg"))
	# The Model look's projected sprite is gone (owner): no row for it, and a file that chose it
	# reads and saves "colours".
	check(find.call("graphics-model_look") == null and not _texts(w).has("Model look"), "Settings has no Model look any more")
	var sprite_cfg := ConfigFile.new()
	sprite_cfg.set_value("graphics", "model_look", "sprite")
	sprite_cfg.save("user://model-look-test.cfg")
	Settings.use_file("user://model-look-test.cfg")
	sprite_cfg.load("user://model-look-test.cfg")
	check(str(sprite_cfg.get_value("graphics", "model_look", "")) == "colours" and ModelLibrary.look == "colours",
		"a saved sprite look is saved as colours, and models wear the colours")
	Settings.use_file(keep_path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://model-look-test.cfg"))
	# A look that sets SSAO and its own clouds itself (the Cinematic look): those rows grey out and say so.
	LooksScript.register("ui-test-own-ao", {"name": "Own AO", "environment": {"ssao_enabled": true}, "own_clouds": false}, "ui-test")
	var look_was: Variant = Settings.get_value("graphics", "look")
	Settings.set_value("graphics", "look", "ui-test-own-ao")
	w.open_tab("Graphics")
	await get_tree().process_frame
	var ssao_box := find.call("graphics-ssao") as CheckBox
	var clouds_box := find.call("graphics-clouds") as CheckBox
	check(Settings.look_overrides("ssao") == "Own AO" and ssao_box.disabled and clouds_box.disabled
		and ssao_box.tooltip_text.begins_with("Set by the Own AO look"),
		"under a look with its own ambient occlusion and clouds, those rows are greyed out and say where they are set")
	Settings.set_value("graphics", "look", look_was)
	LooksScript.remove_owner("ui-test")
	w.open_tab("Graphics")
	await get_tree().process_frame
	check(not (find.call("graphics-ssao") as CheckBox).disabled and Settings.look_overrides("ssao") == "", "and back under Zenith's own look")
	check(Settings.resolution_choices(Vector2i(2560, 1440), false)[0][0] == "%d × %d (default)" % [Settings.default_window_size().x, Settings.default_window_size().y]
		and Settings.resolution_choices(Vector2i(2560, 1440), true)[0][0] == "2560 × 1440 (default)"
		and Settings.default_window_size() == Vector2i(1600, 900), "Resolution's default names the window's own size windowed (project.godot's 1600 × 900), the monitor's in full screen")
	# The Resolution row's list and note follow the window mode.
	var res_box := find.call("graphics-resolution") as OptionButton
	check(Settings.get_value("graphics", "window_mode") == "borderless" and res_box.get_item_text(0).ends_with("(default)")
		and _tip_has(res_box, "scaled"),
		"in full screen it scales to the monitor, and the row's tooltip says so")
	var mode_box := find.call("graphics-window_mode") as OptionButton
	mode_box.select(0)
	mode_box.item_selected.emit(0)
	await get_tree().process_frame
	res_box = find.call("graphics-resolution") as OptionButton
	check(res_box.get_item_text(0).begins_with("1600") and res_box.get_item_text(0).ends_with("(default)") and _tip_has(res_box, "Window size"),
		"windowed, Resolution is the window's size")
	mode_box = find.call("graphics-window_mode") as OptionButton
	mode_box.select(1)
	mode_box.item_selected.emit(1)
	await get_tree().process_frame
	Settings.set_value("graphics", "view_radius", 6)
	preset_box = find.call("graphics-preset") as OptionButton
	check(Settings.preset_now() == "custom" and str(preset_box.get_item_metadata(preset_box.selected)) == "custom", "a setting changed by hand makes it Custom")
	Settings.apply_preset("high")
	check(Settings.preset_now() == "high" and Settings.get_value("graphics", "shadows") == "high" and int(Settings.get_value("graphics", "view_radius")) == 4,
		"High puts the defaults back")
	var project := ConfigFile.new()
	project.load("res://project.godot")
	check(int(project.get_value("rendering", "driver/threads/thread_model", 0)) == Settings.THREAD_SAFE
		and bool(Settings.DEFAULTS["graphics"]["render_thread"])
		and str(project.get_value("application", "config/project_settings_override", "")) == Settings.ENGINE_OVERRIDES,
		"the setting puts the renderer on its own thread by default (written to the overrides at start), project.godot's main thread the fallback")
	var engine_before := FileAccess.get_file_as_string(Settings.ENGINE_OVERRIDES) if FileAccess.file_exists(Settings.ENGINE_OVERRIDES) else ""
	var render_thread := find.call("graphics-render_thread") as CheckBox
	# Off first: a test settings file kept from an earlier run may have it on already.
	render_thread.button_pressed = false
	render_thread.button_pressed = true
	var engine := ConfigFile.new()
	engine.load(Settings.ENGINE_OVERRIDES)
	check(int(engine.get_value("rendering", "driver/threads/thread_model", 0)) == Settings.THREAD_SEPARATE, "turning it on writes the separate render thread for the next start")
	render_thread.button_pressed = false
	engine.load(Settings.ENGINE_OVERRIDES)
	check(int(engine.get_value("rendering", "driver/threads/thread_model", 0)) == Settings.THREAD_SAFE, "and off, the main-thread renderer")
	if engine_before == "":
		DirAccess.remove_absolute(Settings.ENGINE_OVERRIDES)
	else:
		var restore := FileAccess.open(Settings.ENGINE_OVERRIDES, FileAccess.WRITE)
		restore.store_string(engine_before)
		restore.close()

	var pack_tiles := find.call("graphics-pack_tiles") as CheckBox
	var packs_mp: GDScript = load("res://scripts/world/model_packs.gd")
	check(pack_tiles != null and pack_tiles.button_pressed and packs_mp.tiles_on, "Ground textures from model packs: a tick box, on")
	if pack_tiles != null:
		pack_tiles.button_pressed = false
		check(not packs_mp.tiles_on and Settings.get_value("graphics", "pack_tiles") == false, "off: packs' tiles left out (model_packs.gd tiles_on)")
		pack_tiles.button_pressed = true
		check(packs_mp.tiles_on, "and back on")
	var pack_decor := find.call("graphics-pack_decoratives") as CheckBox
	check(pack_decor != null and pack_decor.button_pressed and packs_mp.decor_on, "Decoratives from model packs: a tick box, on")
	if pack_decor != null:
		pack_decor.button_pressed = false
		check(not packs_mp.decor_on and Settings.get_value("graphics", "pack_decoratives") == false, "off: packs' decoratives left out (model_packs.gd decor_on)")
		pack_decor.button_pressed = true
		check(packs_mp.decor_on, "and back on")
	var decor_models_box := find.call("graphics-decor_models") as CheckBox
	# (Off by default since the placeholder 3D decoratives were removed, 2a52be70: a pack's own still work;
	# the box shows the setting as saved.)
	var dm_was := decor_models_box != null and decor_models_box.button_pressed
	check(decor_models_box != null and dm_was == bool(Settings.get_value("graphics", "decor_models"))
		and Settings.DEFAULTS["graphics"]["decor_models"] == false,
		"3D decorative models: a tick box showing the setting, off by default (%s)" % dm_was)
	if decor_models_box != null:
		decor_models_box.button_pressed = not dm_was
		check(packs_mp.decor_models_on == (not dm_was) and Settings.get_value("graphics", "decor_models") == (not dm_was),
			"switched: packs' 3D decorative models %s" % ("used" if not dm_was else "left out"))
		decor_models_box.button_pressed = dm_was
		check(packs_mp.decor_models_on == dm_was, "and back")

	w.open_tab("Sound")
	await get_tree().process_frame
	(find.call("sound-walking") as HSlider).value = 0.5
	var bus := AudioServer.get_bus_index("Walking")
	check(bus >= 0 and absf(AudioServer.get_bus_volume_db(bus) - linear_to_db(0.5)) < 0.01 and AudioServer.get_bus_send(bus) == "Effects",
		"the walking slider sets its bus, part of the game effects")
	(find.call("sound-walking_on") as CheckBox).button_pressed = false
	check(AudioServer.is_bus_mute(bus) and Settings.get_value("sound", "walking_on") == false, "its box mutes it")
	(find.call("sound-walking_on") as CheckBox).button_pressed = true
	check(not AudioServer.is_bus_mute(bus), "and unmutes it")
	var pack_sounds := find.call("sound-pack_sounds") as CheckBox
	check(pack_sounds != null and pack_sounds.button_pressed and packs_mp.sounds_on, "Sounds from model packs: a tick box, on")
	if pack_sounds != null:
		pack_sounds.button_pressed = false
		check(not packs_mp.sounds_on and Settings.get_value("sound", "pack_sounds") == false, "off: packs' sounds left out (model_packs.gd sounds_on)")
		pack_sounds.button_pressed = true
		check(packs_mp.sounds_on, "and back on")

	w.open_tab("Interface")
	await get_tree().process_frame
	var delay := find.call("interface-tooltip_delay") as HSlider
	delay.value = 1.25
	delay.drag_ended.emit(true)
	check(is_equal_approx(float(ProjectSettings.get_setting("gui/timers/tooltip_delay_sec")), 1.25), "tooltip delay goes to Godot's tooltips")
	(find.call("map-show_robots") as CheckBox).button_pressed = false
	check(UiSettings.shared().get_value("map/show_robots") == false, "the map view switches are in Interface too")
	(find.call("map-show_robots") as CheckBox).button_pressed = true
	# The minimap's sliders save on release (they called a save() ui_settings.gd doesn't have).
	var mm_size := find.call("map-minimap_size") as HSlider
	var mm_was := mm_size.value
	mm_size.value = 320.0
	mm_size.drag_ended.emit(true)
	var mm_cfg := ConfigFile.new()
	mm_cfg.load(Settings.path)
	check(is_equal_approx(float(mm_cfg.get_value("map", "minimap_size", 0.0)), 320.0), "the minimap size slider is saved when let go")
	mm_size.value = mm_was
	mm_size.drag_ended.emit(true)

	# Camera > Add-ons' camera motion (bob and shake make some players ill): 100% by default, a
	# change scales the add-ons' summed modifier on the rig at once.
	var cm_holder := Node3D.new()
	add_child(cm_holder)
	var cm_rig := CameraRig.new()
	cm_holder.add_child(cm_rig)
	var cm_stand_gs := GDScript.new()
	cm_stand_gs.source_code = "extends Node\nvar rig\n"
	cm_stand_gs.reload()
	var cm_stand: Node = cm_stand_gs.new()
	cm_stand.rig = cm_rig
	cm_holder.add_child(cm_stand)
	var cm_host := AddonHostScript.new()
	cm_host.autoload = false
	cm_host.main = cm_stand
	cm_holder.add_child(cm_host)
	cm_host._game_on = true
	cm_host.camera_modifier("menus-test", Vector3(1, 0, 0), Vector3(0, 0.2, 0), 10.0)
	var cm_full := [cm_rig._mod_offset, cm_rig._mod_turn, cm_rig._mod_fov]
	w.open_tab("Camera")
	await get_tree().process_frame
	var motion := find.call("camera-addon_motion") as HSlider
	var motion_default := motion != null and is_equal_approx(motion.value, 100.0) and int(Settings.get_value("camera", "addon_motion")) == 100
	if motion != null:
		motion.value = 50.0
	var cm_half := [cm_rig._mod_offset, cm_rig._mod_turn, cm_rig._mod_fov]
	if motion != null:
		motion.value = 0.0
		motion.drag_ended.emit(true)
	var cm_none := [cm_rig._mod_offset, cm_rig._mod_on]
	var cm_cfg := ConfigFile.new()
	cm_cfg.load(Settings.path)
	var cm_saved := int(cm_cfg.get_value("camera", "addon_motion", -1))
	if motion != null:
		motion.value = 100.0
		motion.drag_ended.emit(true)
	var cm_back: Vector3 = cm_rig._mod_offset
	check(motion_default and cm_full == [Vector3(1, 0, 0), Vector3(0, 0.2, 0), 10.0], "Camera has Add-ons' camera motion at 100%%, the modifier drawn whole: %s" % [cm_full])
	check((cm_half[0] as Vector3).is_equal_approx(Vector3(0.5, 0, 0)) and (cm_half[1] as Vector3).is_equal_approx(Vector3(0, 0.1, 0)) and is_equal_approx(float(cm_half[2]), 5.0),
		"add-ons' camera motion at 50%% halves the rig's modifier at once: %s" % [cm_half])
	check(cm_none == [Vector3.ZERO, false] and cm_saved == 0 and cm_back == Vector3(1, 0, 0),
		"at 0%% no modifier is drawn, saved when let go; 100%% gives it back: %s %s %s" % [cm_none, cm_saved, cm_back])
	cm_host.camera_modifier("menus-test", Vector3.ZERO, Vector3.ZERO, 0.0)
	cm_holder.queue_free()

	w.open_tab("Other")
	await get_tree().process_frame
	var autosave := find.call("factorio-autosave_interval") as OptionButton
	for i in autosave.item_count:
		if autosave.get_item_metadata(i) == 5:
			autosave.select(i)
			autosave.item_selected.emit(i)
	var launcher := ServerLauncher.new()
	launcher._data = data
	var server_settings = JSON.parse_string(FileAccess.get_file_as_string(launcher._server_settings({"name": "Test host", "port": 34999, "lan": true, "max_players": 4})))
	check(server_settings is Dictionary and int(server_settings["autosave_interval"]) == 5 and server_settings["name"] == "Test host"
		and server_settings["visibility"]["lan"] == true and int(server_settings["max_players"]) == 4, "autosave and host settings reach the server's settings file")
	launcher.free()

	w.open_tab("Mod settings")
	await get_tree().process_frame
	check(w.current_tab() == "Mod settings" and _texts(w).any(func(s: String) -> bool: return s.contains("type them in the server's console")),
		"mod settings explain where to change them without a launched server")

	# Factorio's way in the game: one page at a time from the Settings list, titled "<Page> settings"
	var page: Node = SettingsWindow.new()
	page.page_mode = true
	page.start_tab = "Sound"
	add_child(page)
	await get_tree().process_frame
	var page_labels: Array = page.find_children("*", "Label", true, false).map(func(l: Label) -> String: return l.text)
	check(page.current_tab() == "Sound" and page_labels.has("Sound settings") and not page.find_child("TabGraphics", true, false).is_visible_in_tree(),
		"a settings page alone: its title, no tab row")
	var confirmed := [false]
	page.confirmed.connect(func() -> void: confirmed[0] = true)
	(page.find_child("Confirm", true, false) as Button).pressed.emit()
	check(confirmed[0], "Confirm closes the settings")
	page.queue_free()

	PlayerInput.define_actions()
	Settings.apply_bindings()
	# Issue #14: the keys changed in Factorio's own controls (config.ini's [controls], the rest
	# written as comments) are the defaults; a key Zenith can't take (a mouse button) leaves its own.
	var fk = load("res://scripts/player/factorio_keys.gd")
	var ini := char(10).join(["[path]", "read-data=__PATH__executable__/../../data", "[controls]", "; toggle-driving=RETURN",
		"toggle-driving=TAB", "next-weapon=", "next-weapon-alternative=CONTROL + SHIFT + N", "pipette=mouse-button-3",
		"open-factoriopedia-alternative=KP_PLUS", "made-up-control=K", "[other]", "rotate=Y"])
	var theirs: Dictionary = fk.keys_from(ini)
	check(theirs == {"enter_vehicle": [KEY_TAB, -1], "next_gun": [0, KEY_N | KEY_MASK_CTRL | KEY_MASK_SHIFT],
		"toggle_factoriopedia": [-1, KEY_KP_ADD]}, "#14: config.ini's [controls] is read as Zenith's actions: %s" % [theirs])
	check(fk.key_code("ALT + B") == (KEY_B | KEY_MASK_ALT) and fk.key_code("RETURN") == KEY_ENTER and fk.key_code("F5") == KEY_F5
		and fk.key_code("KP_ENTER") == KEY_KP_ENTER and fk.key_code("GRAVE") == KEY_QUOTELEFT and fk.key_code("mouse-wheel-up") == -1
		and fk.key_code("") == 0, "#14: Factorio's key sequences become Godot keys")
	Settings.apply_factorio_keys(theirs)
	var tab := InputEventKey.new()
	tab.physical_keycode = KEY_TAB
	tab.pressed = true
	var enter := InputEventKey.new()
	enter.physical_keycode = KEY_ENTER
	enter.pressed = true
	check(Controls.pressed(tab, "enter_vehicle") and not Controls.pressed(enter, "enter_vehicle") and not Controls.pressed(tab, "next_gun")
		and Settings.keys_for("enter_vehicle") == [KEY_TAB, KEY_KP_ENTER] and Settings.keys_for("pipette") == [KEY_Q, 0],
		"#14: with TAB for Enter/leave vehicle in Factorio, TAB gets in and out and Enter doesn't: %s" % [Settings.keys_for("enter_vehicle")])
	Settings.bind_slot("enter_vehicle", 0, KEY_G)
	check(Settings.keys_for("enter_vehicle")[0] == KEY_G, "#14: a key changed in Zenith's Settings still wins over Factorio's")
	Settings.bind("enter_vehicle", [])
	check(Settings.keys_for("enter_vehicle")[0] == KEY_TAB, "#14: and Default puts Factorio's back")
	Settings.apply_factorio_keys({})
	check(Settings.keys_for("enter_vehicle") == [KEY_ENTER, KEY_KP_ENTER] and Settings.keys_for("next_gun")[0] == KEY_C
		and Settings.keys_for("toggle_map") == [KEY_TAB, KEY_M] and Settings.keys_for("shoot_cursor")[0] == (KEY_SPACE | KEY_MASK_SHIFT),
		"#14: with the setting off, Zenith's own defaults are back (#26: 2.0's Map Tab or M, Next weapon C, Shoot selected Shift+Space)")
	# Factorio's own settings (config.ini's set lines, factorio_settings.gd) are the defaults too:
	# in config version 12's form, a comment and a [controls] line with a setting's name left alone.
	var fs = load("res://scripts/menu/factorio_settings.gd")
	var settings_ini := char(10).join(["; version=12", "[path]", "read-data=x", "[general]", "locale=de", "[other]", "autosave-interval=0",
		"[interface]", "ui-scale-mode=custom", "custom-ui-scale=1.3", "; smart-belt-building=false", "show-minimap=false",
		"[controls]", "show-minimap=true", "[sound]", "master-volume=0.300000", "music-volume=0.000000", "; game-effects-volume=0.9",
		"walking-sound-volume=loud", "[graphics]", "show-clouds=false", "show-smoke=false", "full-screen=true",
		"color-filter=deuteranopia", "brightness=0.2"])
	var got: Dictionary = fs.values_from(settings_ini)
	check(got == {"general": {"locale": "de"}, "factorio": {"autosave_interval": 0}, "interface": {"ui_scale": "1.25"},
		"map": {"minimap": false}, "sound": {"master": 0.3, "music": 0.0},
		"graphics": {"clouds": false, "effects": false, "window_mode": "fullscreen", "color_filter": "deuteranopia"}},
		"Factorio's settings: config.ini's set lines become Zenith's, comments and unknown values left out: %s" % [got])
	var older: Dictionary = fs.values_from(char(10).join(["; version=9", "[interface]", "automatic-ui-scale=true", "ui-scale=1.5",
		"[general]", "locale=auto", "[graphics]", "full-screen=false", "color-filter="]))
	check(older == {"interface": {"ui_scale": "auto"}, "graphics": {"window_mode": "windowed", "color_filter": "none"}},
		"Factorio's settings: an older config.ini's UI scale, and an automatic language left to Zenith: %s" % [older])
	Settings.factorio_values = {"sound": {"master": 0.3}, "map": {"minimap": false}}
	var theirs_now: bool = is_equal_approx(float(Settings.get_value("sound", "master")), 0.3) and Settings.factorio_default("map", "minimap") == false
	Settings.set_value("sound", "master", 0.6)
	var own_wins := is_equal_approx(float(Settings.get_value("sound", "master")), 0.6)
	Settings.reset_value("sound", "master")
	var back := is_equal_approx(float(Settings.get_value("sound", "master")), 0.3)
	Settings.reload_factorio_settings()  # the test's own settings file: the machine's Factorio isn't read
	var off: bool = Settings.factorio_values.is_empty() and is_equal_approx(float(Settings.get_value("sound", "master")), float(Settings.DEFAULTS["sound"]["master"]))
	check(theirs_now and own_wins and back and off,
		"Factorio's settings are the defaults: Zenith's own change wins, Default puts Factorio's back, a test's settings file reads none (%s %s %s %s)" % [theirs_now, own_wins, back, off])
	w.open_tab("Factorio")
	await get_tree().process_frame
	check(find.call("factorio-use_factorio_settings") != null and _texts(w).has("Use the settings set in Factorio"),
		"Settings → Factorio install has the switch for Factorio's settings")
	var root := "user://fake-factorio"
	DirAccess.make_dir_recursive_absolute(root + "/bin/x64")
	var cfg_file := FileAccess.open(root + "/config-path.cfg", FileAccess.WRITE)
	cfg_file.store_string(char(10).join(["config-path=__PATH__executable__/../../config", "use-system-read-write-data-directories=false"]))
	cfg_file.close()
	var places: Array = fk.candidates(ProjectSettings.globalize_path(root + "/bin/x64/factorio.exe"))
	check(not places.is_empty() and str(places[0]).ends_with("fake-factorio/config/config.ini"),
		"#14: a zip install's config.ini is in its own config folder: %s" % [places])
	w.open_tab("Controls")
	await get_tree().process_frame
	check(find.call("controls-rotate-1") != null and _texts(w).has("Basic interaction") and _texts(w).has("Movement"), "controls are grouped like Factorio's")
	check(find.call("factorio-use_factorio_keys") != null and _texts(w).has("Use the keys set in Factorio"),
		"#14: Settings → Controls has the switch for Factorio's keys")
	# Issue #26: the switch back to Zenith 0.2.2's keys, saved (Factorio's keys are off here: this test reads no
	# config.ini of the machine's; factorio_keys_test.gd has the rest, the copy's message in both modes too).
	var old_box := find.call("factorio-" + Controls.OLD_KEYS_SETTING) as CheckBox
	check(old_box != null and _texts(w).has("Zenith 0.2.2's keys") and not old_box.button_pressed and not old_box.disabled,
		"#26: Settings → Controls has the switch for Zenith 0.2.2's keys, off")
	if old_box != null:
		old_box.button_pressed = true
		var on_keys := [bool(Settings.get_value("factorio", Controls.OLD_KEYS_SETTING)), Settings.keys_for("next_gun")[0] == KEY_TAB,
			Settings.keys_for("toggle_map")[0] == KEY_M]
		Settings.set_value("factorio", Controls.OLD_KEYS_SETTING, false)
		check(on_keys == [true, true, true] and Settings.keys_for("next_gun")[0] == KEY_C and Settings.keys_for("toggle_map")[0] == KEY_TAB,
			"#26: ticked, it saves and gives 0.2.2's Tab for Next weapon and M for Map; unticked, 2.1's C and Tab (%s)" % [on_keys])
		await get_tree().process_frame
		w.open_tab("Controls")
		await get_tree().process_frame
	(find.call("controls-rotate-1") as Button).pressed.emit()
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_H
	ev.keycode = KEY_H
	ev.shift_pressed = true
	ev.pressed = true
	get_viewport().push_input(ev)
	await get_tree().process_frame
	check(Settings.keys_for("rotate") == [KEY_R, KEY_H | KEY_MASK_SHIFT], "a key with Shift becomes the alternative binding")
	var shift_h := false
	for e in InputMap.action_get_events("rotate"):
		if e is InputEventKey and (e as InputEventKey).physical_keycode == KEY_H and (e as InputEventKey).shift_pressed:
			shift_h = true
	check(shift_h, "and is in the input map with its modifier")
	var plain_h := InputEventKey.new()
	plain_h.physical_keycode = KEY_H
	plain_h.pressed = true
	var with_shift := plain_h.duplicate()
	with_shift.shift_pressed = true
	check(not plain_h.is_action_pressed("rotate") and with_shift.is_action_pressed("rotate"), "Shift + H fires it, H alone doesn't")
	Settings.bind_slot("pick_up", 1, KEY_R)
	check(Settings.conflicts("pick_up", KEY_R).has("rotate"), "a key used twice is a conflict")
	check(Settings.conflicts("pipette", KEY_Q).is_empty() and Settings.conflicts("clear_cursor", KEY_Q).is_empty()
		and Settings.conflicts("give_red_wire", KEY_R | KEY_MASK_ALT).is_empty() and Settings.conflicts("toggle_rail_layer", KEY_R | KEY_MASK_ALT).is_empty(),
		"Q (clear cursor, pipette) and Alt+R (red wire, rail layer) share their key by design: no clash out of the box")
	w.open_tab("Controls")
	await get_tree().process_frame
	check((find.call("controls-pick_up-1") as Button).tooltip_text.contains("Rotate"), "and the binding says what else uses it")
	(find.call("ResetControls") as Button).pressed.emit()
	check(Settings.keys_for("rotate") == Settings.default_keys("rotate") and not Settings.has_value("controls", "rotate"), "reset puts the defaults back")
	# Issue #26: Copy keys from Factorio, against a fixture config.ini (factorio_keys_test.gd has the rest).
	var ini_file := ProjectSettings.globalize_path("user://copy-keys/config.ini")
	DirAccess.make_dir_recursive_absolute(ini_file.get_base_dir())
	var ini_out := FileAccess.open(ini_file, FileAccess.WRITE)
	ini_out.store_string(char(10).join(["; version=13", "[controls]", "; toggle-driving=RETURN", "toggle-driving=TAB",
		"pipette=mouse-button-3", "connect-train=J", "[sound]"]))
	ini_out.close()
	fk.test_config = ini_file
	Settings.bind_slot("enter_vehicle", 0, KEY_G)
	check(find.call("CopyFactorioKeys") != null, "#26: Settings → Controls has Copy keys from Factorio")
	(find.call("CopyFactorioKeys") as Button).pressed.emit()
	await get_tree().process_frame
	var said := ""
	for t in _texts(w):
		if str(t).contains("Read from:"):
			said = str(t)
	check(Settings.keys_for("enter_vehicle")[0] == KEY_TAB and said.contains("Enter/leave vehicle: Tab") and said.contains("Pipette tool: Middle-click (a mouse button")
		and said.contains("connect-train: J (Zenith has no key") and said.contains(ini_file) and w.find_child("Message", true, false) != null,
		"#26: the copy takes Factorio's TAB over Zenith's saved G and says what it copied, skipped and read: %s" % said)
	# A config.ini with nothing changed in Factorio: its "; " default lines are the keys, and the copy says so.
	(w.find_child("Message", true, false) as Node).free()
	ini_out = FileAccess.open(ini_file, FileAccess.WRITE)
	ini_out.store_string(char(10).join(["; version=13", "[controls]", "; toggle-driving=RETURN", "; toggle-driving-alternative=G",
		"; toggle-rail-layer=G", "; shoot-selected=SHIFT + SPACE", "; shoot-enemy=SPACE", "; redo-alternative=CONTROL + SHIFT + Z", "[sound]"]))
	ini_out.close()
	Settings.bind_slot("shoot_cursor", 0, KEY_K)
	(find.call("CopyFactorioKeys") as Button).pressed.emit()
	await get_tree().process_frame
	said = ""
	for t in _texts(w):
		if str(t).contains("Read from:"):
			said = str(t)
	check(Settings.keys_for("enter_vehicle") == [KEY_ENTER, KEY_G] and Settings.keys_for("toggle_rail_layer")[0] == KEY_G
		and Settings.keys_for("shoot_cursor")[0] == (KEY_SPACE | KEY_MASK_SHIFT) and Settings.keys_for("redo")[1] == (KEY_Z | KEY_MASK_CTRL | KEY_MASK_SHIFT)
		and said.contains("None of Factorio's controls were changed there. Its defaults are used here.")
		and said.contains("Factorio's defaults taken for the rest: 6.") and said.contains("put back to Factorio's: 1."),
		"#26: Factorio's default lines are copied too (Zenith's saved K for Shoot selected gives way to Shift+Space): %s" % said)
	check(Settings.conflicts("enter_vehicle", KEY_G).is_empty() and Settings.conflicts("toggle_rail_layer", KEY_G).is_empty()
		and (find.call("controls-enter_vehicle-1") as Button).tooltip_text.find("Also bound to") == -1,
		"#26: G for getting in and the rail layer, as 2.1 has them, isn't shown as a clash")
	var shift_space := Controls.key_event(KEY_SPACE | KEY_MASK_SHIFT)
	shift_space.pressed = true
	check(Controls.pressed(shift_space, "shoot_cursor") and not Controls.pressed(shift_space, "shoot_enemies"),
		"#26: Shift+Space shoots at the cursor, not at enemies")
	fk.test_config = ""
	Settings.set_value("factorio", "use_factorio_keys", false)
	Settings.reload_factorio_keys()
	w.queue_free()

	# The map generator. It starts from the last settings played (Settings [new_game]), which a
	# later step of this test stores in the test's settings file: clear them, or every other run
	# starts from that run's changes.
	Settings.set_value("new_game", "settings", null)
	Settings.set_value("new_game", "seed", null)
	var gen: Node = MapGeneratorWindow.new()
	add_child(gen)
	await get_tree().process_frame
	check(gen.settings["gen"]["autoplace_controls"].has("iron-ore") and gen.settings["gen"]["autoplace_controls"].has("tungsten_ore"), "the map generator has every resource, Space Age's too")
	var rich := gen.find_child("gen-autoplace_controls-iron-ore-richness", true, false) as HSlider
	rich.value = 8
	check(is_equal_approx(float(gen.settings["gen"]["autoplace_controls"]["iron-ore"]["richness"]), 2.0) and MapGen.changed_count(gen.settings) == 1, "a resource slider changes its richness")
	var preset := gen.find_child("Preset", true, false) as OptionButton
	for i in preset.item_count:
		if preset.get_item_metadata(i) == "rich-resources":
			preset.select(i)
			preset.item_selected.emit(i)
	check(gen.settings["preset"] == "rich-resources" and MapGen.changed_count(gen.settings) == 0, "a preset sets its values")
	gen.open_tab("Terrain")
	await get_tree().process_frame
	(gen.find_child("gen-autoplace_controls-water-frequency", true, false) as HSlider).value = 8
	check(is_equal_approx(float(gen.settings["gen"]["autoplace_controls"]["water"]["frequency"]), 0.5), "water scale 200% is frequency 0.5")
	gen.open_tab("Enemy")
	await get_tree().process_frame
	(gen.find_child("gen-peaceful_mode", true, false) as CheckBox).button_pressed = true
	(gen.find_child("map-enemy_expansion-max_expansion_cooldown", true, false) as SpinBox).value = 30
	check(gen.settings["gen"]["peaceful_mode"] == true and int(gen.settings["map"]["enemy_expansion"]["max_expansion_cooldown"]) == 30 * 3600, "peaceful mode and expansion cooldown in minutes")
	var played := []
	gen.play.connect(func(n: String, st: Dictionary, sd: String, _ex: String) -> void: played.append([n, st, sd]))
	(gen.find_child("Seed", true, false) as LineEdit).text = "123"
	(gen.find_child("Seed", true, false) as LineEdit).text_changed.emit("123")
	(gen.find_child("Play", true, false) as Button).pressed.emit()
	check(played.size() == 1 and played[0][2] == "123" and played[0][1]["gen"]["peaceful_mode"] == true, "Play hands the settings and seed on")
	check(Settings.has_value("new_game", "settings") and str(Settings.get_value("new_game", "seed")) == "123", "and they are remembered for next time")
	gen.queue_free()
	var again: Node = MapGeneratorWindow.new()
	add_child(again)
	await get_tree().process_frame
	check(again.settings["gen"]["peaceful_mode"] == true and again.seed_text == "123", "the next new game starts from them")
	again.queue_free()

	# The mods list keeps the player's choices (mod_choices.gd), with the DLC's dependencies.
	DirAccess.remove_absolute(ModChoices.path(data))
	var mods: Node = ModsWindow.new()
	add_child(mods)
	await get_tree().process_frame
	var names: Array = mods._mods.map(func(x: Dictionary) -> String: return x["name"])
	check(names.has("factorio-3d-bridge") and names.has("some-mod") and (mods.find_child("factorio-3d-bridge", true, false) as CheckBox).disabled, "the mods list shows the server's mods, the bridge always on")
	mods.set_enabled("some-mod", false)
	if names.has("space-age"):
		mods.set_enabled("quality", false)
		var states := ModChoices.states()
		check(states.get("quality") == false and states.get("space-age") == false and states.get("some-mod") == false, "turning Quality off turns Space Age off too")
		mods.set_enabled("space-age", true)
		states = ModChoices.states()
		check(states.get("quality") == true and states.get("elevated-rails") == true and states.get("space-age") == true, "and Space Age brings its DLC back")
		mods.set_enabled("space-age", false)
		check(not MapGen.controls_for(MapGen.enabled_mods()).any(func(c: Array) -> bool: return c[0] == "tungsten_ore"), "without Space Age the map generator leaves its planets out")
		mods.set_enabled("space-age", true)
	else:
		check(ModChoices.states().get("some-mod") == false, "a mod can be turned off")
	mods.queue_free()
	Settings.reset_value("factorio", "server_data")
	await _issue_folders_and_install()
	_bug_report()
	_user_data_layout()
	await _addons_and_packs_out_of_settings()
	await _graphics_settings_layout()
	await _view_distance_limits()


func _tip_has(c: Control, word: String) -> bool:
	return c.tooltip_text.contains(word) or (c.get_parent() is Control and (c.get_parent() as Control).tooltip_text.contains(word))


func _graphics_settings_layout() -> void:
	var prev_override: int = SettingsWindow.old_graphics_layout_override
	SettingsWindow.old_graphics_layout_override = 0
	var w: Node = SettingsWindow.new()
	add_child(w)
	await get_tree().process_frame
	await get_tree().process_frame

	var cols_box := w.find_child("GraphicsColumns", true, false) as HBoxContainer
	var has_three_cols := cols_box != null and cols_box.get_child_count() == 3
	for i in 3:
		has_three_cols = has_three_cols and cols_box.find_child("GraphicsCol%d" % i, false, false) is VBoxContainer
	var cat_ids := ["display", "performance", "distances", "world", "lighting", "accessibility"]
	var cats_ok := true
	for id in cat_ids:
		cats_ok = cats_ok and w.find_child("graphics-cat-" + id, true, false) != null
	check(w.find_child("GraphicsTopBar", true, false) != null and has_three_cols and cats_ok,
		"graphics layout: 3 columns, top bar, and all 6 category cards are present")

	var gfx_pane: Vector2 = w._pane_frame.custom_minimum_size
	w.open_tab("Sound")
	await get_tree().process_frame
	var sound_pane: Vector2 = w._pane_frame.custom_minimum_size
	w.open_tab("Graphics")
	await get_tree().process_frame
	var restored_pane: Vector2 = w._pane_frame.custom_minimum_size
	check(gfx_pane.x > sound_pane.x and gfx_pane.y > sound_pane.y and restored_pane.is_equal_approx(gfx_pane),
		"graphics layout: Graphics pane (%.0f x %.0f) is larger/squarer than Sound (%.0f x %.0f)" % [
			gfx_pane.x, gfx_pane.y, sound_pane.x, sound_pane.y])

	var vp_fhd := SubViewport.new()
	vp_fhd.size = Vector2i(Kit.px(1920), Kit.px(1080))
	vp_fhd.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp_fhd)
	var wf := SettingsWindow.new()
	vp_fhd.add_child(wf)
	await get_tree().process_frame
	await get_tree().process_frame
	var fhd_pane: Vector2 = wf._pane_frame.custom_minimum_size
	var fhd_size: Vector2 = (wf as Control).size
	var fhd_ratio: float = fhd_size.x / maxf(1.0, fhd_size.y)
	check(fhd_pane.is_equal_approx(Kit.pxv(1080, 880))
		and fhd_size.x <= float(vp_fhd.size.x) + 1.0 and fhd_size.y <= float(vp_fhd.size.y) + 1.0 and fhd_ratio <= 1.35,
		"graphics layout: at 1920x1080 keeps full square pane (%.0f x %.0f), ratio %.2f, window (%.0f x %.0f)" % [
			fhd_pane.x, fhd_pane.y, fhd_ratio, fhd_size.x, fhd_size.y])
	vp_fhd.queue_free()

	var vp_hd := SubViewport.new()
	vp_hd.size = Vector2i(Kit.px(1280), Kit.px(720))
	vp_hd.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp_hd)
	var wh := SettingsWindow.new()
	vp_hd.add_child(wh)
	await get_tree().process_frame
	await get_tree().process_frame
	var hd_pane: Vector2 = wh._pane_frame.custom_minimum_size
	var hd_size: Vector2 = (wh as Control).size
	check(hd_size.x <= float(vp_hd.size.x) + 1.0 and hd_size.y <= float(vp_hd.size.y) + 1.0 and hd_pane.y < float(Kit.px(880)),
		"graphics layout: at 1280x720 clamps pane height (%.0f x %.0f) so window (%.0f x %.0f) fits" % [
			hd_pane.x, hd_pane.y, hd_size.x, hd_size.y])
	vp_hd.queue_free()

	var more_cats := ["display", "performance", "distances", "world", "lighting"]
	var collapsed_ok := true
	for id in more_cats:
		var mbtn := w.find_child("graphics-more-" + id, true, false) as Button
		var mwrap := w.find_child("graphics-advanced-" + id, true, false) as Control
		collapsed_ok = collapsed_ok and mbtn != null and mbtn.visible and mbtn.text.begins_with("More (") and mwrap != null and not mwrap.visible
	var access_btn := w.find_child("graphics-more-accessibility", true, false) as Button
	check(collapsed_ok and access_btn != null and not access_btn.visible,
		"graphics layout: categories with granular settings show collapsed More buttons, accessibility hides it")

	var collapsed_keys := [
		"screen", "upscaler_sharpness", "minimize_on_focus_loss",
		"lod_distance", "server_first", "merge_far", "merged_materials", "animate_mod_buildings", "chunk_disk_cache", "render_thread",
		"distant_horizon_quality", "distant_horizon_dropoff", "distant_horizon_glow", "distant_horizon_shots",
		"decorative_density", "decorative_distance", "belt_step",
		"shadow_distance", "pack_shading", "pack_tiles", "pack_decoratives", "decor_models",
	]
	var missing_keys: Array = []
	for k in collapsed_keys:
		if w.find_child("graphics-" + k, true, false) == null:
			missing_keys.append(k)
	check(missing_keys.is_empty(), "graphics layout: all More-drawer controls remain discoverable while collapsed (%s)" % [missing_keys])
	check(w.find_child("graphics-texture_metal", true, false) == null and not Settings.DEFAULTS["graphics"].has("texture_metal"),
		"graphics layout: Metal on textured models (texture_metal) setting removed")

	var dist_btn := w.find_child("graphics-more-distances", true, false) as Button
	var perf_btn := w.find_child("graphics-more-performance", true, false) as Button
	dist_btn.button_pressed = true
	perf_btn.button_pressed = true
	await get_tree().process_frame
	var dist_wrap := w.find_child("graphics-advanced-distances", true, false) as Control
	var perf_wrap := w.find_child("graphics-advanced-performance", true, false) as Control
	var opened_ok := dist_wrap.visible and perf_wrap.visible and dist_btn.text == "Less" and perf_btn.text == "Less"
	w.open_tab("Graphics")
	await get_tree().process_frame
	dist_btn = w.find_child("graphics-more-distances", true, false) as Button
	perf_btn = w.find_child("graphics-more-performance", true, false) as Button
	dist_wrap = w.find_child("graphics-advanced-distances", true, false) as Control
	perf_wrap = w.find_child("graphics-advanced-performance", true, false) as Control
	var persisted_ok := dist_wrap.visible and perf_wrap.visible and dist_btn.text == "Less" and perf_btn.text == "Less"

	var cache_was: Variant = Settings.get_value("graphics", "chunk_disk_cache")
	var cache_had: bool = Settings.has_value("graphics", "chunk_disk_cache")
	var cache_box := w.find_child("graphics-chunk_disk_cache", true, false) as CheckBox
	cache_box.button_pressed = not bool(cache_was)
	var cache_changed: bool = bool(Settings.get_value("graphics", "chunk_disk_cache")) != bool(cache_was)
	cache_box.button_pressed = bool(cache_was)
	if not cache_had:
		Settings.reset_value("graphics", "chunk_disk_cache")

	var pack_tiles_box := w.find_child("graphics-pack_tiles", true, false) as CheckBox
	var packs_mp: GDScript = load("res://scripts/world/model_packs.gd")
	var pt_was := bool(Settings.get_value("graphics", "pack_tiles"))
	var pt_had := Settings.has_value("graphics", "pack_tiles")
	pack_tiles_box.button_pressed = false
	var pt_off: bool = (not bool(packs_mp.tiles_on) and Settings.get_value("graphics", "pack_tiles") == false)
	pack_tiles_box.button_pressed = true
	var pt_on: bool = (bool(packs_mp.tiles_on) and Settings.get_value("graphics", "pack_tiles") == true)
	pack_tiles_box.button_pressed = pt_was
	if not pt_had:
		Settings.reset_value("graphics", "pack_tiles")
	check(pack_tiles_box != null and pt_off and pt_on,
		"graphics layout: Ground textures from model packs toggles ModelPacks.tiles_on (%s %s)" % [pt_off, pt_on])

	var pack_decor_box := w.find_child("graphics-pack_decoratives", true, false) as CheckBox
	var pd_was := bool(Settings.get_value("graphics", "pack_decoratives"))
	var pd_had := Settings.has_value("graphics", "pack_decoratives")
	pack_decor_box.button_pressed = false
	var pd_off: bool = (not bool(packs_mp.decor_on) and Settings.get_value("graphics", "pack_decoratives") == false)
	pack_decor_box.button_pressed = true
	var pd_on: bool = (bool(packs_mp.decor_on) and Settings.get_value("graphics", "pack_decoratives") == true)
	pack_decor_box.button_pressed = pd_was
	if not pd_had:
		Settings.reset_value("graphics", "pack_decoratives")
	check(pack_decor_box != null and pd_off and pd_on,
		"graphics layout: Decoratives from model packs toggles ModelPacks.decor_on (%s %s)" % [pd_off, pd_on])

	var decor_mdl_box := w.find_child("graphics-decor_models", true, false) as CheckBox
	var dm_was := bool(Settings.get_value("graphics", "decor_models"))
	var dm_had := Settings.has_value("graphics", "decor_models")
	decor_mdl_box.button_pressed = false
	var dm_off: bool = (not bool(packs_mp.decor_models_on) and Settings.get_value("graphics", "decor_models") == false)
	decor_mdl_box.button_pressed = true
	var dm_on: bool = (bool(packs_mp.decor_models_on) and Settings.get_value("graphics", "decor_models") == true)
	decor_mdl_box.button_pressed = dm_was
	if not dm_had:
		Settings.reset_value("graphics", "decor_models")
	check(decor_mdl_box != null and dm_off and dm_on,
		"graphics layout: 3D decorative models toggles ModelPacks.decor_models_on (%s %s)" % [dm_off, dm_on])

	dist_btn.button_pressed = false
	perf_btn.button_pressed = false
	await get_tree().process_frame
	var closed_ok := not dist_wrap.visible and not perf_wrap.visible and dist_btn.text == "More (5)" and perf_btn.text == "More (7)"
	check(opened_ok and persisted_ok and closed_ok and cache_changed,
		"graphics layout: More buttons toggle and persist across rebuilds, chunk_disk_cache updates Setting (%s %s %s %s, buttons %s/%s)" % [
			opened_ok, persisted_ok, closed_ok, cache_changed, dist_btn.text, perf_btn.text])
	w.queue_free()
	await get_tree().process_frame

	SettingsWindow.old_graphics_layout_override = 1
	var legacy_w: Node = SettingsWindow.new()
	add_child(legacy_w)
	await get_tree().process_frame
	var legacy_texts: Array = _texts(legacy_w)
	check(legacy_w.find_child("GraphicsColumns", true, false) == null
		and legacy_texts.has("General") and legacy_texts.has("Advanced")
		and legacy_w._pane_frame.custom_minimum_size.x <= sound_pane.x + 1.0,
		"graphics layout: old layout fallback restores single-column General/Advanced view")
	legacy_w.queue_free()
	SettingsWindow.old_graphics_layout_override = prev_override
	await get_tree().process_frame


func _view_distance_limits() -> void:
	var prev_override: int = SettingsWindow.old_graphics_layout_override
	var prev_vr: Variant = Settings.get_value("graphics", "view_radius")
	var prev_dh: Variant = Settings.get_value("graphics", "distant_horizon")
	var prev_er: Variant = Settings.get_value("graphics", "entity_radius")
	var prev_bd: Variant = Settings.get_value("graphics", "belt_distance")
	SettingsWindow.old_graphics_layout_override = 0
	Settings.set_value("graphics", "view_radius", 4, false)
	Settings.set_value("graphics", "distant_horizon", 96, false)
	Settings.set_value("graphics", "entity_radius", 128, false)
	Settings.set_value("graphics", "belt_distance", 128, false)

	var w: Node = SettingsWindow.new()
	add_child(w)
	await get_tree().process_frame
	await get_tree().process_frame

	var view_slider := w.find_child("graphics-view_radius", true, false) as HSlider
	var view_btn := w.find_child("graphics-view_radius-value", true, false) as Button
	var view_edit := w.find_child("graphics-view_radius-value-edit", true, false) as LineEdit
	var dh_slider := w.find_child("graphics-distant_horizon", true, false) as HSlider
	var dh_btn := w.find_child("graphics-distant_horizon-value", true, false) as Button
	var dh_edit := w.find_child("graphics-distant_horizon-value-edit", true, false) as LineEdit
	var ent_slider := w.find_child("graphics-entity_radius", true, false) as HSlider
	var ent_btn := w.find_child("graphics-entity_radius-value", true, false) as Button
	var ent_edit := w.find_child("graphics-entity_radius-value-edit", true, false) as LineEdit
	var belt_slider := w.find_child("graphics-belt_distance", true, false) as HSlider
	var belt_btn := w.find_child("graphics-belt_distance-value", true, false) as Button
	var belt_edit := w.find_child("graphics-belt_distance-value-edit", true, false) as LineEdit

	check(view_slider != null and int(view_slider.max_value) == 10
		and dh_slider != null and int(dh_slider.max_value) == 256
		and ent_slider != null and int(ent_slider.max_value) == 128 and int(ent_slider.value) == 128
		and belt_slider != null and int(belt_slider.max_value) == 128 and int(belt_slider.value) == 128,
		"view distance limits: view max 10, distant horizon max 256, entity/belt default to view distance (128) at right end")

	var type_commit := func(btn: Button, edit: LineEdit, text: String) -> void:
		btn.pressed.emit()
		edit.text = text
		edit.text_submitted.emit(text)

	type_commit.call(view_btn, view_edit, "25")
	check(int(Settings.get_value("graphics", "view_radius")) == 25
		and int(view_slider.value) == 10
		and view_btn.text == "25 chunks (51 × 51)"
		and view_btn.get_theme_color("font_color") == Kit.RED_TEXT,
		"view distance: typing 25 stores 25, keeps bar at 10, and turns label red")

	type_commit.call(view_btn, view_edit, "80")
	check(int(Settings.get_value("graphics", "view_radius")) == 50
		and view_btn.get_theme_color("font_color") == Kit.RED_TEXT,
		"view distance: typing above 50 clamps to 50 and stays red")

	type_commit.call(view_btn, view_edit, "4")
	check(int(Settings.get_value("graphics", "view_radius")) == 4
		and int(view_slider.value) == 4
		and view_btn.get_theme_color("font_color") == Kit.WHITE,
		"view distance: typing 4 restores normal colour")

	type_commit.call(dh_btn, dh_edit, "400")
	check(int(Settings.get_value("graphics", "distant_horizon")) == 400
		and int(dh_slider.value) == 256
		and dh_btn.text == "400 chunks (12800 tiles)"
		and dh_btn.get_theme_color("font_color") == Kit.RED_TEXT,
		"distant horizon: typing 400 stores 400, keeps bar at 256, and turns label red")

	type_commit.call(dh_btn, dh_edit, "900")
	check(int(Settings.get_value("graphics", "distant_horizon")) == 512
		and dh_btn.get_theme_color("font_color") == Kit.RED_TEXT,
		"distant horizon: typing above 512 clamps to 512 and stays red")

	type_commit.call(dh_btn, dh_edit, "96")
	check(int(Settings.get_value("graphics", "distant_horizon")) == 96
		and dh_btn.get_theme_color("font_color") == Kit.WHITE,
		"distant horizon: typing 96 restores normal colour")

	type_commit.call(ent_btn, ent_edit, "256")
	type_commit.call(belt_btn, belt_edit, "256")
	check(int(Settings.get_value("graphics", "entity_radius")) == 128
		and int(Settings.get_value("graphics", "belt_distance")) == 128
		and ent_btn.text == "128 tiles" and belt_btn.text == "128 tiles",
		"entity and belt distance: typing above view distance (128) clamps down to 128")

	type_commit.call(view_btn, view_edit, "3")
	check(int(ent_slider.max_value) == 96 and int(belt_slider.max_value) == 96
		and int(Settings.get_value("graphics", "entity_radius")) == 96
		and int(Settings.get_value("graphics", "belt_distance")) == 96
		and int(ent_slider.value) == 96 and int(belt_slider.value) == 96,
		"entity and belt distance: lowering view distance to 3 (96 tiles) steps maxes and values down to 96")

	w.queue_free()
	await get_tree().process_frame
	SettingsWindow.old_graphics_layout_override = prev_override
	Settings.set_value("graphics", "view_radius", prev_vr, false)
	Settings.set_value("graphics", "distant_horizon", prev_dh, false)
	Settings.set_value("graphics", "entity_radius", prev_er, false)
	Settings.set_value("graphics", "belt_distance", prev_bd, false)


## N7 (owner): add-ons and model packs aren't in Settings: the Settings list has no Add-ons or Model
## packs page and Graphics no Model packs rows; both open from the main menu and the Esc menu, each
## its own window (addons_window.gd keeps every add-on's settings and keys).


func _addons_and_packs_out_of_settings() -> void:
	var w: Node = SettingsWindow.new()
	add_child(w)
	await get_tree().process_frame
	var texts: Array = _texts(w)
	check(w.current_tab() == "Graphics" and w.find_child("graphics-model-packs", true, false) == null
		and w.find_child("graphics-open-models", true, false) == null and not texts.has("Model packs") and not w.has_signal("model_packs_requested"),
		"N7: Settings > Graphics has no Model packs heading or button")
	w.queue_free()
	var fe: Node = FrontEndScript.new()
	add_child(fe)
	await get_tree().process_frame
	fe._show_settings("")
	await get_tree().process_frame
	var list: Node = fe._settings
	var pages: Array = list.find_children("Page*", "Button", true, false).map(func(b: Button) -> String: return b.text) if list != null else []
	check(list != null and pages.has("Graphics") and pages.has("Factorio install") and not pages.has("Add-ons") and not pages.has("Model packs"),
		"N7: the Settings list has no Add-ons or Model packs page: %s" % [pages])
	list.queue_free()
	fe._settings = null
	fe._show_main_menu()
	var addons_main := fe._page.find_child("Add-ons", true, false) as Button
	var packs_main := fe._page.find_child("Modelpacks", true, false) as Button
	check(addons_main != null and packs_main != null, "N7: the main menu has Add-ons and Model packs")
	if addons_main != null and packs_main != null:
		addons_main.pressed.emit()
		check(not fe._overlays.is_empty() and fe._overlays.back().name == "Addons", "the main menu's Add-ons opens the Add-ons window")
		fe._clear_overlays()
		await get_tree().process_frame  # the window gone, so the next takes its name
		packs_main.pressed.emit()
		check(not fe._overlays.is_empty() and fe._overlays.back().name == "ModelPacks", "the main menu's Model packs opens the Model packs window")
		fe._clear_overlays()
		await get_tree().process_frame  # the window gone, so the next takes its name
	# The Esc menu, with a stand-in for main.gd (the game's input switched off while it is open).
	var stand := GDScript.new()
	stand.source_code = "extends Node\nvar hud = null\nvar addons = null\nvar world = null\nfunc set_game_input(_on: bool) -> void:\n\tpass\n"
	stand.reload()
	var fake_main: Node = stand.new()
	fe.add_child(fake_main)
	fe.main = fake_main
	fe._toggle_esc_menu()
	var esc: Node = fe._esc_menu
	var addons_esc := esc.find_child("Addons", true, false) as Button if esc != null else null
	var packs_esc := esc.find_child("ModelPacks", true, false) as Button if esc != null else null
	check(addons_esc != null and packs_esc != null and addons_esc.text == "Add-ons" and packs_esc.text == "Model packs",
		"N7: the Esc menu has Add-ons and Model packs")
	if addons_esc != null and packs_esc != null:
		addons_esc.pressed.emit()
		check(not fe._overlays.is_empty() and fe._overlays.back().name == "Addons", "the Esc menu's Add-ons opens the Add-ons window")
		fe._clear_overlays()
		await get_tree().process_frame  # the window gone, so the next takes its name
		packs_esc.pressed.emit()
		check(not fe._overlays.is_empty() and fe._overlays.back().name == "ModelPacks", "the Esc menu's Model packs opens the Model packs window")
		fe._clear_overlays()
		await get_tree().process_frame  # the window gone, so the next takes its name
	fe._close_esc_menu()
	fe.main = null
	fe.queue_free()
	await get_tree().process_frame


## The main menu's backdrop chooser (backdrop_recorder.gd, menu_background.gd, front_end.gd): a
## snapshot recorded from the mock's own messages (MOCK_MENU_WORLD is a recording of them)
## and drawn behind the menu with the camera where it was; the ways back to the built-in world; the
## menus' buttons; the background made again after a Model packs change.


func _load_mods() -> void:
	var root := OS.get_user_data_dir().path_join("ui-test-load-mods")
	_remove_tree(root)
	var data := root.path_join("server-data")
	var mods_dir := data.path_join("mods")
	var mod := func(dir: String, info: Dictionary) -> void:
		DirAccess.make_dir_recursive_absolute(mods_dir.path_join(dir))
		_write(mods_dir.path_join(dir).path_join("info.json"), JSON.stringify(info))
	mod.call("factorio-3d-bridge", {"name": "factorio-3d-bridge", "version": "0.2.2"})
	mod.call("alpha_1.0.0", {"name": "alpha", "version": "1.0.0", "dependencies": ["base >= 2.1", "beta >= 1.0", "+ gamma", "? delta", "(?) space-age"]})
	mod.call("beta_1.0.0", {"name": "beta", "version": "1.0.0"})
	mod.call("beta_1.2.0", {"name": "beta", "version": "1.2.0", "title": "Beta"})
	mod.call("delta_1.0.0", {"name": "delta", "version": "1.0.0"})
	mod.call("clash_1.0.0", {"name": "clash", "version": "1.0.0", "dependencies": ["! space-age"]})
	mod.call("needs-missing_1.0.0", {"name": "needs-missing", "version": "1.0.0", "dependencies": ["nowhere"]})
	mod.call("needs-sa_1.0.0", {"name": "needs-sa", "version": "1.0.0", "dependencies": ["~ space-age >= 2.1"]})
	mod.call("saved_2.0.0", {"name": "saved", "version": "2.0.0", "dependencies": ["! hater"]})
	mod.call("hater_1.0.0", {"name": "hater", "version": "1.0.0"})
	var packer := ZIPPacker.new()
	packer.open(mods_dir.path_join("gamma_0.1.0.zip"))
	packer.start_file("gamma_0.1.0/info.json")
	packer.write_file(JSON.stringify({"name": "gamma", "version": "0.1.0"}).to_utf8_buffer())
	packer.close_file()
	packer.close()
	Settings.set_value("factorio", "server_data", data)

	# A folder from before: its mod-list.json is the last load's --sync-mods (a version on every mod it
	# turned on), so only what was ticked since counts as the player's.
	var list_file := mods_dir.path_join("mod-list.json")
	_write(list_file, JSON.stringify({"mods": [{"name": "base", "enabled": true, "version": "2.1.24"}, {"name": "space-age", "enabled": false},
		{"name": "saved", "enabled": true, "version": "2.0.0"}, {"name": "alpha", "enabled": true}, {"name": "beta", "enabled": false}]}))
	var migrated := ModChoices.states()
	check(migrated == {"alpha": true} and ModChoices.is_on("space-age", migrated) and not ModChoices.is_on("saved", migrated)
		and ModChoices.is_on("base", migrated) and ModChoices.is_on("factorio-3d-bridge", migrated),
		"M5: from a list a load wrote, only the mod ticked since is the player's; the last save's mods and DLC aren't: %s" % [migrated])
	_write(list_file, JSON.stringify({"mods": [{"name": "space-age", "enabled": false}, {"name": "alpha", "enabled": true}, {"name": "beta", "enabled": false}]}))
	check(ModChoices.states() == {"space-age": false, "alpha": true}, "M5: a list only the Mods window wrote is taken as it is: %s" % [ModChoices.states()])
	check(ModChoices.dependencies({"dependencies": ["! Squeak Through", "? x >= 1.0", "(?) y", "~ z", "+ w = 2.0.0", "base"]})
		== [["!", "Squeak Through"], ["?", "x"], ["(?)", "y"], ["~", "z"], ["+", "w"], ["", "base"]] and ModChoices.newer("1.10.0", "1.9.3")
		and ModChoices.highest(["1.0.0", "1.2.0", "0.9.9"]) == "1.2.0", "M5: Factorio's dependency prefixes (2.1's + too) and versions read")

	# The Mods window: one row per mod at its highest version; a change goes to the choices, not to
	# the server's list.
	var list_before := FileAccess.get_file_as_string(list_file)
	var window: Node = ModsWindow.new()
	add_child(window)
	await get_tree().process_frame
	var rows: Array = window._mods.filter(func(m: Dictionary) -> bool: return m["name"] == "beta")
	window.set_enabled("clash", true)
	window.set_enabled("needs-missing", true)
	window.set_enabled("needs-sa", true)
	window.set_enabled("hater", true)
	var chosen := ModChoices.added(ModChoices.states())
	check(rows.size() == 1 and rows[0]["version"] == "1.2.0" and rows[0]["title"] == "Beta" and window._mods.filter(func(m: Dictionary) -> bool: return m["name"] == "alpha")[0]["enabled"] == true
		and chosen == ["alpha", "clash", "hater", "needs-missing", "needs-sa"] and FileAccess.get_file_as_string(list_file) == list_before
		and FileAccess.file_exists(ModChoices.path(data)),
		"M5: the Mods window shows a mod once (its highest version) and keeps its changes as the player's choices, the server's mod-list.json untouched: %s" % [chosen])
	window.queue_free()
	var in_game: Node = ModsWindow.new()
	in_game.read_only = true
	add_child(in_game)
	await get_tree().process_frame
	var running_rows: Dictionary = {}
	for m in in_game._mods:
		running_rows[m["name"]] = m["enabled"]
	check(running_rows.get("alpha") == true and running_rows.get("beta") == false and running_rows.get("gamma") == true,
		"M5: in a game the window shows what the server runs (its mod-list.json, a mod it leaves out on): %s" % [running_rows])
	in_game.queue_free()

	# After --sync-mods (the save's mods at their versions): the chosen ones are added, with what they
	# need and recommend; those that would stop the server are left out, named.
	_write(list_file, JSON.stringify({"mods": [{"name": "base", "enabled": true, "version": "2.1.24"}, {"name": "space-age", "enabled": true, "version": "2.1.24"},
		{"name": "saved", "enabled": true, "version": "2.0.0"}, {"name": "alpha", "enabled": false}, {"name": "beta", "enabled": false}, {"name": "factorio-3d-bridge", "enabled": false}]}))
	var launcher := ServerLauncher.new()
	launcher._data = data
	launcher.add_chosen_mods(list_file)
	var after: Dictionary = {}
	for m in JSON.parse_string(FileAccess.get_file_as_string(list_file))["mods"]:
		after[m["name"]] = [m["enabled"], m.get("version", "")]
	check(launcher.added_mods == ["alpha", "beta", "gamma", "needs-sa"]
		and after["alpha"] == [true, ""] and after["beta"] == [true, ""] and after["gamma"] == [true, ""] and after["saved"] == [true, "2.0.0"]
		and after["space-age"] == [true, "2.1.24"] and not after.has("delta") and not after.has("clash") and not after.has("hater"),
		"M5: a loaded save keeps its mods at its versions, and gets the chosen ones with what they need and recommend (not the optional): %s %s" % [launcher.added_mods, after])
	check(launcher.left_out_mods == ["clash: clash can't run with space-age", "hater: saved can't run with hater", "needs-missing: needs nowhere, which isn't in the mods folder"],
		"M5: one that clashes with the save's mods either way, or needs a mod the folder hasn't, is left out and named: %s" % [launcher.left_out_mods])
	# A save without Space Age: a chosen mod that needs it is left out, as Wube's mods follow the save.
	_write(list_file, JSON.stringify({"mods": [{"name": "base", "enabled": true, "version": "2.1.24"}, {"name": "space-age", "enabled": false}]}))
	launcher.add_chosen_mods(list_file)
	check(launcher.left_out_mods.has("needs-sa: needs space-age, which isn't on") and launcher.added_mods.has("clash"),
		"M5: without Space Age in the save, the mod needing it is left out and the one refusing it is added: %s %s" % [launcher.added_mods, launcher.left_out_mods])
	# A new game: Wube's mods and the rest as the Mods window has them, every mod listed.
	var choices := ModChoices.states()
	choices["space-age"] = false
	choices["hater"] = false
	ModChoices.write(choices)
	launcher.write_new_game_mods()
	var fresh: Dictionary = {}
	for m in JSON.parse_string(FileAccess.get_file_as_string(list_file))["mods"]:
		fresh[m["name"]] = m["enabled"]
	check(fresh.get("base") == true and fresh.get("space-age") == false and fresh.get("quality") == true and fresh.get("alpha") == true
		and fresh.get("beta") == true and fresh.get("gamma") == true and fresh.get("clash") == true and fresh.get("delta") == false
		and fresh.get("hater") == false and fresh.get("needs-sa") == false and fresh.get("saved") == false and fresh.get("factorio-3d-bridge") == true
		and MapGen.enabled_mods().get("space-age") == false,
		"M5: a new game gets the Mods window's mods (with what they need) and its Space Age choice; the map generator follows: %s" % [fresh])
	launcher.free()

	# Load game: Sync mods with save (Factorio's words) is a choice beside the save, off each time the
	# page opens, and reaches the launcher; the note says which mods the save gets.
	var saves := root.path_join("saves")
	DirAccess.make_dir_recursive_absolute(saves)
	_write(saves.path_join("world.zip"), "x")
	Settings.set_value("factorio", "saves", saves)
	var stand_in := GDScript.new()
	stand_in.source_code = "extends \"res://scripts/menu/server_launcher.gd\"\nvar calls: Array = []\n" \
		+ "func start(path: String, host := {}, exact_mods := false) -> bool:\n\tcalls.append([path.get_file(), exact_mods])\n\terror = \"stand-in\"\n\treturn false\n"
	stand_in.reload()
	var fe: Node = FrontEndScript.new()
	add_child(fe)
	await get_tree().process_frame
	var fake: Node = stand_in.new()
	fe.add_child(fake)
	fe.launcher = fake
	var notes: Array = []
	for sync in [false, true, false]:
		fe._show_main_menu()  # back out first, as a player does (a second "Worlds" page beside the first would be renamed)
		await get_tree().process_frame
		fe._show_worlds("load")
		var box := fe._page.find_child("SyncMods", true, false) as CheckBox
		var started_off := box != null and not box.button_pressed
		if box != null and sync:
			box.button_pressed = true  # its toggled lays the details out again
			await get_tree().process_frame
		var note := fe._page.find_child("ModsNote", true, false) as Label
		notes.append([started_off, note.text if note != null else ""])
		(fe._page.find_child("Load", true, false) as Button).pressed.emit()
		await get_tree().process_frame
		fe._clear_overlays()
	check(fake.calls == [["world.zip", false], ["world.zip", true], ["world.zip", false]] and notes.all(func(n: Array) -> bool: return n[0])
		and notes[0][1].contains("Mods window: alpha, clash, needs-missing, needs-sa") and notes[1][1].contains("exactly the save's mods"),
		"M5: Load game's Sync mods with save starts off, loads the save with exactly its mods when ticked, and the note names the Mods window's mods otherwise: %s %s" % [fake.calls, notes])
	fe.queue_free()
	Settings.reset_value("factorio", "saves")
	Settings.reset_value("factorio", "server_data")
	_remove_tree(root)


## A downloaded build keeps its saves and server data in Zenith's user folder, so they outlive an
## update (paths.gd); an older build's server/saves and server mods beside the exe come over once.


func _user_data_layout() -> void:
	var root := OS.get_user_data_dir().path_join("ui-test-user-layout")
	_remove_tree(root)
	var install := root.path_join("old-install")
	var user := root.path_join("user")
	for f in ["server/saves/base.zip", "server/saves/Space Age/run.zip", "server/saves/notes.txt",
			"server/data/mods/some-mod_1.0.0.zip", "server/data/mods/mod-list.json", "server/data/zenith-mods.json", "server/data/factorio-current.log"]:
		DirAccess.make_dir_recursive_absolute(install.path_join(f).get_base_dir())
		_write(install.path_join(f), "x")
	var was: Array = [Paths.keep_in_user_data, Paths.user_data_dir, Paths._moved]
	Paths._moved = true  # not this checkout's own server/ folder
	Paths.keep_in_user_data = true
	Paths.user_data_dir = user
	var saves := Paths.saves_dir()
	var data := Paths.server_data_dir()
	Paths.move_from_install(install)
	var copied := FileAccess.file_exists(user.path_join("saves/base.zip")) and FileAccess.file_exists(user.path_join("saves/Space Age/run.zip"))
	var mods := FileAccess.file_exists(user.path_join("server-data/mods/some-mod_1.0.0.zip")) and FileAccess.file_exists(user.path_join("server-data/mods/mod-list.json")) \
		and FileAccess.file_exists(user.path_join("server-data/zenith-mods.json"))
	var left_out := not FileAccess.file_exists(user.path_join("saves/notes.txt")) and not FileAccess.file_exists(user.path_join("server-data/factorio-current.log"))
	# Once there: a newer world in the user folder isn't replaced by the old one again.
	_write(user.path_join("saves/base.zip"), "newer")
	Paths.move_from_install(install)
	var kept := FileAccess.get_file_as_string(user.path_join("saves/base.zip")) == "newer"
	Settings.set_value("factorio", "saves", root.path_join("chosen"))
	var setting_wins := Paths.saves_dir() == root.path_join("chosen")
	Settings.reset_value("factorio", "saves")
	Paths.keep_in_user_data = false
	var checkout := Paths.saves_dir() == Paths.repo_dir().path_join("server/saves") and Paths.server_data_dir() == Paths.repo_dir().path_join("server/data")
	Paths.keep_in_user_data = was[0]
	Paths.user_data_dir = was[1]
	Paths._moved = was[2]
	_remove_tree(root)
	check(saves == user.path_join("saves") and data == user.path_join("server-data") and copied and mods and left_out and kept and setting_wins and checkout,
		"a download keeps saves and server data in the user folder, brings an old install's over once, a setting still wins (%s, %s; copied %s, mods %s, left out %s, kept %s)" % [saves, data, copied, mods, left_out, kept])
	_download_saves_in_checkout()


## A checkout lists a download's saves (the user folder's) beside its own server/saves, loads one
## as a copy, and uses that copy again while it is unchanged (the owner's world from a dev build
## wasn't in the source build's list).


func _download_saves_in_checkout() -> void:
	var root := OS.get_user_data_dir().path_join("ui-test-download-saves")
	_remove_tree(root)
	var user := root.path_join("user")
	var server := root.path_join("server-saves")
	DirAccess.make_dir_recursive_absolute(user.path_join("saves"))
	DirAccess.make_dir_recursive_absolute(server)
	_write(user.path_join("saves/playtest.zip"), "the dev build's world")
	_write(server.path_join("old.zip"), "x")
	var was: Array = [Paths.keep_in_user_data, Paths.user_data_dir]
	Paths.keep_in_user_data = false
	Paths.user_data_dir = user
	Settings.set_value("factorio", "saves", server)
	var sources: Array = Saves.roots().map(func(r: Array) -> String: return str(r[0]))
	var listed := Saves.list().filter(func(s: Dictionary) -> bool: return s["source"] == "zenith").map(func(s: Dictionary) -> String: return str(s["name"]))
	var fe: Node = FrontEndScript.new()
	fe._list_worlds()
	var picked := -1
	for i in fe._saves.size():
		if fe._saves[i]["name"] == "playtest":
			picked = i
	var heading: String = fe._source_heading("zenith")
	fe.free()
	var first := Saves.copy_to_server(user.path_join("saves/playtest.zip"))
	var again := Saves.copy_to_server(user.path_join("saves/playtest.zip"))
	_write(server.path_join("playtest.zip"), "played on since")
	var after_play := Saves.copy_to_server(user.path_join("saves/playtest.zip"))
	var original := FileAccess.get_file_as_string(user.path_join("saves/playtest.zip")) == "the dev build's world"
	# A download itself has no second list, and a checkout whose saves are the user folder's neither.
	Settings.set_value("factorio", "saves", user.path_join("saves"))
	var same_folder := Paths.download_saves_dir()
	Paths.keep_in_user_data = true
	var in_download := Paths.download_saves_dir()
	Settings.reset_value("factorio", "saves")
	Paths.keep_in_user_data = was[0]
	Paths.user_data_dir = was[1]
	_remove_tree(root)
	check(sources.slice(0, 2) == ["server", "zenith"] and listed == ["playtest"] and picked >= 0 and heading.contains("copy")
		and first == server.path_join("playtest.zip") and again == first and after_play == server.path_join("playtest (2).zip")
		and original and same_folder == "" and in_download == "",
		"a checkout lists a download's saves and loads one as a copy, used again while unchanged (%s, %s; %s, %s, %s)" % [sources, listed, first.get_file(), again.get_file(), after_play.get_file()])


func _issue_folders_and_install() -> void:
	var saves := OS.get_user_data_dir().path_join("ui-test-saves")
	DirAccess.make_dir_recursive_absolute(saves.path_join("Space Age/Older"))
	_write(saves.path_join("top.zip"), "x")
	_write(saves.path_join("Space Age/run.zip"), "x")
	_write(saves.path_join("Space Age/Older/old.zip"), "x")
	Settings.set_value("factorio", "saves", saves)
	var fe: Node = FrontEndScript.new()
	fe._list_worlds()
	var names := func() -> Array: return fe._saves.filter(func(e: Dictionary) -> bool: return e["source"] == "server").map(func(e: Dictionary) -> String: return ("[%s]" if e.get("folder", false) else "%s") % e["name"])
	var top: Array = names.call()
	var folder: Dictionary = fe._saves.filter(func(e: Dictionary) -> bool: return e["name"] == "Space Age")[0]
	fe._open_worlds_folder(folder)
	var inside: Array = names.call()
	var selected_inside: String = str(fe._saves[fe._selected]["name"]) if fe._selected >= 0 else ""
	fe._open_worlds_folder(fe._saves.filter(func(e: Dictionary) -> bool: return e["name"] == "Older")[0])
	var deeper: Array = names.call()
	fe._open_worlds_folder(fe._saves[0])  # [..]
	var up_once: Array = names.call()
	fe._open_worlds_folder(fe._saves[0])
	var at_top: bool = fe._worlds_dir.is_empty()
	fe.free()
	check(top.slice(0, 2) == ["[Space Age]", "top"] and inside == ["[..]", "[Older]", "run"] and selected_inside == "run"
		and deeper == ["[..]", "old"] and up_once == inside and at_top,
		"issue #3: the load screen shows folders, opens them at any depth and goes back up (%s / %s / %s)" % [top, inside, deeper])
	Settings.reset_value("factorio", "saves")
	# #6: a standalone install anywhere (D:/Factorio_2.1 in the report), found from the exe set.
	var install := OS.get_user_data_dir().path_join("ui-test-factorio")
	DirAccess.make_dir_recursive_absolute(install.path_join("bin/x64"))
	DirAccess.make_dir_recursive_absolute(install.path_join("data/base/graphics/icons"))
	_write(install.path_join("bin/x64/factorio.exe"), "")
	Settings.set_value("factorio", "executable", install.path_join("bin/x64/factorio.exe"))
	var found: String = ItemIcons._find_data_dir()
	var folder_ok: bool = Paths.configured_exe() == install.path_join("bin/x64/factorio.exe")
	Settings.set_value("factorio", "executable", install)
	var by_folder: String = ItemIcons._find_data_dir()
	var w: Node = SettingsWindow.new()
	add_child(w)
	await get_tree().process_frame
	w.open_tab("Factorio")
	await get_tree().process_frame
	var graphics := w.find_child("factorio-graphics", true, false) as Label
	var says: String = graphics.text if graphics != null else ""
	w.queue_free()
	Settings.reset_value("factorio", "executable")
	check(found == install.path_join("data") and by_folder == found and folder_ok and Paths.configured_exe() == ""
		and says.begins_with("Restart Zenith"),
		"issue #6: the data folder comes from the factorio.exe (or folder) set in Settings, which says to restart (%s)" % says)
	check(Paths.read_data_dir("/Applications/factorio.app/Contents/MacOS/factorio") == "/Applications/factorio.app/Contents/data"
		and Paths.read_data_dir("D:/Factorio_2.1/bin/x64/factorio.exe") == "D:/Factorio_2.1/data",
		"the install's data folder on macOS (factorio.app/Contents/data) and elsewhere (bin/x64/../../data)")


## Report a bug: the zip holds system.txt and this run's log, and GitHub's page has the versions and
## the zip's name in its text.


func _bug_report() -> void:
	var path := BugReport.make_bundle()
	var names := PackedStringArray()
	var reader := ZIPReader.new()
	if path != "" and reader.open(path) == OK:
		names = reader.get_files()
		reader.close()
	var url := BugReport.issue_url(path.get_file())
	var body := url.get_slice("body=", 1).uri_decode()
	if path != "":
		DirAccess.remove_absolute(path)
	check("system.txt" in names and "zenith/godot.log" in names and url.begins_with(BugReport.ISSUES + "?labels=bug")
		and body.contains("Zenith " + str(ProjectSettings.get_setting("application/config/version"))) and body.contains(path.get_file()),
		"report a bug: the logs' zip (%s) and GitHub's page with the versions and the zip's name" % ", ".join(names))
	var kept_mod: String = Bridge.mod_version
	Bridge.mod_version = "9.8.7"
	var with_mod := BugReport.system_text(true)
	Bridge.mod_version = ""
	var without_mod := BugReport.system_text(true)
	Bridge.mod_version = kept_mod
	check(with_mod.contains("\nZenith Bridge mod 9.8.7\n") and not without_mod.contains("Bridge mod"),
		"a bug report lists the bridge mod's version once a game has said it")


func _perf_test() -> void:
	var theme_before: Theme = get_tree().root.theme
	var quit_before := get_tree().auto_accept_quit
	var fe: Node = FrontEndScript.new()
	add_child(fe)
	await get_tree().process_frame
	fe._show_main_menu()
	check(fe._page.find_child("Performancetest", true, false) is Button, "the main menu has a Performance test entry")
	fe._show_perf_test()
	var choice: Control = fe._overlays.back() if not fe._overlays.is_empty() else null
	var texts: Array = _texts(choice) if choice != null else []
	check(choice != null and choice.name == "PerfTestChoice" and texts.has("Quick, about 3 minutes")
		and texts.has("Default, about 6 minutes (an estimate)") and texts.has("Extensive, about 17 minutes (an estimate)"),
		"it asks Quick, Default or Extensive, with their times (Default's and Extensive's estimates): %s" % [texts])
	var fake_script := GDScript.new()
	fake_script.source_code = "extends Node\nvar error := \"\"\nvar info := {\"factorio\": \"2.1.24\", \"space_age\": true, \"buildings\": \"2603\"}\nvar tests: Array = []\nvar settings: Array = []\nvar stopped := 0\n" \
		+ "func prepare(say: Callable) -> bool:\n\tsay.call(\"fake\", 0.1)\n\treturn true\n" \
		+ "func run_test(n: int, test: Array, child_settings: Dictionary) -> Dictionary:\n\ttests.append(test.duplicate())\n\tsettings.append(child_settings)\n\tawait get_tree().process_frame\n" \
		+ "\treturn {\"frames\": 1800.0, \"p50\": 8.0 + n, \"p99\": 15.0, \"worst\": 30.0, \"over16\": 3.0, \"over33\": 0.0, \"over50\": 0.0, \"gpu_p50\": 5.0, \"gpu_p99\": 9.0, \"render_cpu_p50\": 2.0, \"process_p50\": 3.0, \"process_p99\": 6.0, \"draw_calls_p50\": 900.0, \"primitives_p50\": 1000000.0, \"bridge_avg\": 3.3, \"bridge_p99\": 4.8, \"bridge_worst\": 6.0, \"ups\": 60.0, \"seconds\": 55.0}\n" \
		+ "func cancel() -> void:\n\tpass\nfunc stop() -> void:\n\tstopped += 1\n"
	fake_script.reload()
	var file := ProjectSettings.globalize_path(PerfTestScript.RESULTS_DIR).path_join("Zenith-perf-%s-%%s.txt" % PerfTestScript.version())
	for mode in ["quick", "default"]:
		var fake := Node.new()
		fake.set_script(fake_script)
		fe.perf_runner = fake
		if fe._overlays.is_empty():
			fe._show_perf_test()
		var button := fe._overlays.back().find_child("Perf" + str(PerfTestScript.MODES[mode][0]), true, false) as Button
		button.pressed.emit()
		var waited := 0
		while fe._perf != null and waited < 600:
			await get_tree().process_frame
			waited += 1
		check(fake.tests == PerfTestScript.PLANS[mode] and fake.stopped == 1,
			"%s runs its tests (%d) and stops the server after: %s" % [mode, PerfTestScript.PLANS[mode].size(), fake.tests])
		var cinematic: Array = fake.settings.map(func(s: Dictionary) -> bool: return s["addons"]["cinematic-shaders"])
		var own := func(s: Dictionary) -> bool:
			var g: Dictionary = s["graphics"]
			return g["shadows"] == "high" and g["vsync"] == false and g["window_mode"] == "borderless" and g["hold_ups"] == false and s["sound"]["master"] == 0.0
		check(fake.settings.all(own) and cinematic == fake.tests.map(func(t: Array) -> bool: return t[0] == "cinematic"),
			"each test gets its own settings: High, full screen, vsync and sound off, the Cinematic shaders only for the Cinematic look")
		var text := FileAccess.get_file_as_string(file % mode)
		var lines := text.split("\n")
		var csv_at := lines.find(",".join(PerfTestScript.CSV_KEYS))
		check(text.begins_with("Zenith performance test\n") and text.contains("Zenith %s, %s mode, run " % [PerfTestScript.version(), mode])
			and text.contains("\nThis PC\n  CPU:      ") and text.contains("\n  RAM:      ") and text.contains("\n  GPU:      ")
			and text.contains("\n  Screen:   ") and text.contains("\n  System:   ") and text.contains("\n  Factorio: 2.1.24 with Space Age\n")
			and text.contains("\nHow it was run\n") and text.contains("base of 2603 buildings") and text.contains("\n| # | Test | Frames | Middle frame |")
			and text.contains("| 1 | Factorio look, High, standing still | 1800 | 8.0 ms | 125 | 15.0 ms |") and text.contains("For the project's tools")
			and csv_at > 0 and lines[csv_at + 1].begins_with("1,factorio,high,stand,1800,8,15,30,")
			and Array(lines.slice(csv_at + 1)).filter(func(l: String) -> bool: return l != "").size() == PerfTestScript.PLANS[mode].size(),
			"the %s results file has the version, mode, the PC, how it ran, a table row and a CSV line per test" % mode)
		var results: Control = fe._overlays.back() if not fe._overlays.is_empty() else null
		var details: Array = results.find_children("*", "Button", true, false).filter(func(b: Button) -> bool: return b.text == "Details") if results != null else []
		check(results != null and results.name == "PerfResults" and details.size() == PerfTestScript.PLANS[mode].size(),
			"the results show in the menu, a line per test")
		if not details.is_empty():
			(details[0] as Button).pressed.emit()
			check(results.find_child("PerfReport", true, false).report_open(), "and Details opens the debug menu's report window for that test")
		fe._clear_overlays()
		DirAccess.remove_absolute(file % mode)
	var last: Dictionary = PerfTestScript._lasts()
	check(last.has("quick") and last.has("default"), "each mode's reports are kept for the next run to compare against")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PerfTestScript.RESULTS_DIR).path_join("last.json"))
	fe.queue_free()
	await get_tree().process_frame
	get_tree().root.theme = theme_before
	get_tree().auto_accept_quit = quit_before


## Plays the windows the way a player would.
