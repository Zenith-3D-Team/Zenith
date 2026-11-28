extends RefCounted
## Factorio's windows for logistics, logic, trains and vehicles, laid out as the game's own
## (tools/ui_reference's pictures, style.lua): inserters, splitters, power switches, lamps,
## speakers, display panels, pumps, storage tanks, turrets, roboports, rail signals, cars, tanks
## and spidertrons, cargo wagons, locomotives and train stops. machine_screen.gd puts the status
## line first and calls build() for the rest; the circuit and logistic connection live in the
## docked window of circuit_window.gd, and the combinators in circuit_panel.gd.
##
## Settings are sent at once, as Factorio applies GUI edits immediately. Values that change all
## the time (the inserter's hand, the burner's fuel bar) are updated in place by refresh() so the
## window isn't rebuilt twice a second.

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const GuiAssets := preload("res://scripts/ui/factorio/gui_assets.gd")
const MenuKit := preload("res://scripts/menu/menu_kit.gd")
const Slot := preload("res://scripts/ui/factorio/slot.gd")
const LogicKit := preload("res://scripts/ui/factorio/logic_kit.gd")
const EntityPanels := preload("res://scripts/ui/factorio/entity_panels.gd")
const CircuitPanel := preload("res://scripts/ui/factorio/circuit_panel.gd")
const EntitySettings := preload("res://scripts/ui/factorio/entity_settings.gd")
const TrainWindow := preload("res://scripts/ui/factorio/train_window.gd")
const ProductionPanels := preload("res://scripts/ui/factorio/production_panels.gd")
const SpacePanels := preload("res://scripts/ui/factorio/space_panels.gd")
const Wire := preload("res://scripts/util/wire.gd")

## The red bar beside a burner's fuel slot.
const BURNER_COLOR := Color8(230, 60, 40)
## Maximum items shown per lane on a transport belt window.
const BELT_SLOTS := 8
## Kinds and entity types whose fluid boxes Factorio doesn't show as our generic rows.
const OWN_FLUIDS := ["pump", "storage-tank", "pipe", "pipe-to-ground"]
## The entities whose window shows their own contents, the pipeline's and the flush buttons.
const PIPELINE := {"storage-tank": "Storage tank contents:", "pipe": "Pipe contents:", "pipe-to-ground": "Pipe contents:"}
## The vehicle's equipment grid shows beside the inventory while this is on (the grid button
## beside a vehicle's ammo slots toggles it, as Factorio's does).
static var vehicle_grid_open := false


## The open entity's prototype type ("lamp", "locomotive"...), or "".
static func entity_type(screen) -> String:
	if screen.protos == null:
		return ""
	var proto = screen.protos.entities_by_name.get(screen.proto_name)
	return str(proto.type) if proto != null else ""


## Builds the window's own part into `body` (the status line is already there). False for what
## machine_screen.gd draws itself (chests, crafters, furnaces, labs, Space Age's machines).
static func build(screen, kind: String, inv: Dictionary, body: VBoxContainer) -> bool:
	var last: Dictionary = screen._last
	var t := entity_type(screen)
	for key in ["hand_slot", "burner_bars", "belt_lanes"]:
		if screen.has_meta(key):
			screen.remove_meta(key)
	match kind:
		"inserter":
			_inserter(screen, last, body)
			return true
		"splitter":
			if last.get("spl") is Dictionary:
				body.add_child(splitter(screen, last["spl"]))
			return true
		"switch":
			body.add_child(power_switch(screen, int(last.get("sw", 0)) == 1))
			return true
		"combinator":
			if last.get("cb") is Dictionary:
				CircuitPanel.combinator_window(screen, last, body)
			return true
		"turret":
			_turret(screen, last, body)
			return true
		"vehicle":
			_vehicle(screen, last, body)
			return true
		"roboport":
			_roboport(screen, body)
			return true
		"stop":
			if last.get("stop") is Dictionary:
				TrainWindow.stop(screen, last["stop"], body)
			return true
		"train":
			if t == "locomotive":
				TrainWindow.locomotive(screen, last, body)
			else:
				_wagon(screen, inv, body)
			return true
		"pole":
			_pole(screen)
			return true
		"panel":
			if last.get("dp") is Dictionary:
				body.add_child(display_panel(screen, last["dp"]))
			return true
	match t:
		"lamp":
			_lamp(screen, last, body)
			return true
		"programmable-speaker":
			if last.get("spk") is Dictionary:
				_speaker(screen, last, body)
			return true
		"pump":
			body.add_child(pump(screen, str(last.get("pf", ""))))
			return true
		"storage-tank", "pipe", "pipe-to-ground":
			_tank(screen, last, body)
			return true
		"heat-pipe":
			_heat_pipe(screen, last, body)
			return true
		"land-mine":
			return true  # the status line and preview only
		"transport-belt":
			_transport_belt(screen, last, body)
			return true
		"rail-signal", "rail-chain-signal", "lane-splitter":
			return true  # the status line only; their circuit settings are in the docked window
	return false


## What else changes the layout, for machine_screen.gd's rebuild check: a vehicle's name and
## targeting, artillery's, the pipeline's contents, a train's group, a heat pipe's temperature.
static func sig_extra(screen, msg: Dictionary) -> String:
	var tr = msg.get("tr")
	var groups = [tr.get("gc"), tr.get("groups")] if tr is Dictionary else null
	var temp = msg.get("tc", msg.get("temp")) if entity_type(screen) == "heat-pipe" else null
	return JSON.stringify([msg.get("veh"), msg.get("art"), msg.get("pl"), groups, temp])


## Whether machine_screen.gd should leave out its generic fluid rows.
static func hides_fluids(screen) -> bool:
	return entity_type(screen) in OWN_FLUIDS


## Updates what changes all the time without rebuilding: the hand, the burner bar, the camera.
static func refresh(screen, msg: Dictionary) -> void:
	if screen.has_meta("hand_slot"):
		var hand = screen.get_meta("hand_slot")
		var ins = msg.get("ins")
		if is_instance_valid(hand) and ins is Dictionary:
			var h = ins.get("h")
			if h is Array and h.size() >= 2:
				var stack := {"item": str(h[0]), "count": int(h[1])}
				hand.set_stack(str(h[0]), int(h[1]))
				hand.set_hand(screen.hand_slot.size() >= 2 and str(screen.hand_slot[0]) == "hand" and int(screen.hand_slot[1]) == 1,
					Slot.hand_left_of(screen.hand_slot, stack))
				hand.set_tip(Kit.pretty(str(h[0])), [["In the inserter's hand", "", Kit.DISABLED_TEXT],
					["Click: pick up · Shift click: into your inventory", "", Kit.DISABLED_TEXT]])
			else:
				hand.set_stack("", -1)
				hand.set_hand(false)
				hand.set_tip("Inserter hand", [["Empty", "", Kit.DISABLED_TEXT]])
	if screen.has_meta("belt_lanes") and msg.has("bl"):
		var lanes: Array = screen.get_meta("belt_lanes")
		var bl := Wire.array(msg.get("bl"))
		for li in mini(2, lanes.size()):
			var row_slots: Array = lanes[li]
			var items: Array = Wire.array(bl[li]) if li < bl.size() else []
			var role := "belt_1" if li == 0 else "belt_2"
			for i in row_slots.size():
				var s: Slot = row_slots[i]
				if not is_instance_valid(s):
					continue
				var idx := i + 1
				var entry: Dictionary = items[i] if i < items.size() and items[i] is Dictionary else {}
				var item_name := str(entry.get("name", ""))
				var item_count := int(entry.get("count", 0))
				if item_name != "" and item_count > 0:
					var stack := {"item": item_name, "count": item_count}
					if entry.has("quality"):
						stack["quality"] = str(entry["quality"])
					s.set_extra(stack)
					s.set_stack(item_name, item_count)
					s.set_hand(screen.hand_slot.size() >= 2 and str(screen.hand_slot[0]) == role and int(screen.hand_slot[1]) == idx,
						Slot.hand_left_of(screen.hand_slot, stack))
					s.set_tip(Kit.pretty(item_name), Slot.extra_lines(stack) + [
						["%d on the belt lane" % item_count],
						["Click: pick up · Shift click: into your inventory", "", Kit.DISABLED_TEXT],
					])
				else:
					s.set_extra({})
					s.set_stack("", -1)
					s.set_hand(false)
					s.set_tip("", [])
					s.tooltip_text = ""
	if screen.has_meta("burner_bars") and msg.has("bu"):
		for bar in screen.get_meta("burner_bars"):
			if is_instance_valid(bar):
				bar.value = int(msg["bu"])


# --- shared pieces -------------------------------------------------------------------------------

## A row of a checkbox (with its label) and the rest pushed to the right.
static func _right(row: HBoxContainer, child: Control) -> void:
	LogicKit.push_right(row, child)


static func _radios_enabled(r: Container, on: bool) -> void:
	for c in r.get_children():
		if c is BaseButton:
			(c as BaseButton).disabled = not on


static func _status_row(body: VBoxContainer) -> HBoxContainer:
	if body.get_child_count() == 0:
		return null
	var status := body.get_child(0)
	for c in status.get_children():
		if c is HBoxContainer:
			return c
	return null


# --- inserters, splitters, power switches ---------------------------------------------------------

## Factorio's inserter: the hand, the burner's fuel, filters with the whitelist switch, the hand
## size override and spoiled priority, each part under a thin line.
static func _inserter(screen, last: Dictionary, body: VBoxContainer) -> void:
	var ins: Dictionary = last.get("ins") if last.get("ins") is Dictionary else {}
	var hand_row := HBoxContainer.new()
	hand_row.add_theme_constant_override("separation", 0)
	var hand := Slot.new()
	hand.theme_type_variation = "FSlotButton"
	hand.empty_icon = GuiAssets.core_sprite("icons/mip/empty-inserter-hand-slot.png")
	hand.name = "Hand"
	hand.slot_role = "hand"
	hand.slot_index = 1
	hand.mouse_filter = Control.MOUSE_FILTER_PASS
	var on_hand_click := func(button_index: int, shift: bool) -> void:
		screen.slot_clicked.emit("hand", 1, hand.item, hand.count, button_index, shift, hand.ctrl)
	hand.clicked.connect(on_hand_click)
	hand_row.add_child(hand)
	screen.set_meta("hand_slot", hand)
	for i in Kit.COLUMNS - 1:
		var faint := Kit.empty_cell()
		faint.modulate.a = 0.35
		hand_row.add_child(faint)
	body.add_child(hand_row)
	refresh(screen, {"ins": ins})
	if screen.knows_slots("fuel") or (screen._last.get("inv") is Dictionary and screen._last["inv"].has("fuel")):
		body.add_child(LogicKit.line())
		body.add_child(LogicKit.fuel_row(screen))
	body.add_child(LogicKit.line())
	body.add_child(inserter(screen, ins))


## A transport belt's two lanes (`gui.bl`), each as clickable slots to take items off the belt.
static func _transport_belt(screen, last: Dictionary, body: VBoxContainer) -> void:
	var lanes: Array = []
	for lane in [["Left lane", "belt_1"], ["Right lane", "belt_2"]]:
		var title: String = lane[0]
		var role: String = lane[1]
		body.add_child(Kit.label(title, "FHeading"))
		var frame := Kit.panel("FDeepFrame")
		frame.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		var grid := Kit.slot_grid(BELT_SLOTS)
		frame.add_child(grid)
		var row_slots: Array = []
		for i in BELT_SLOTS:
			var s := Slot.new()
			var idx := i + 1
			s.name = "%s_%d" % [role, idx]
			s.theme_type_variation = "FSlotButton"
			s.slot_role = role
			s.slot_index = idx
			var on_click := func(button_index: int, shift: bool) -> void:
				screen.slot_clicked.emit(role, idx, s.item, s.count, button_index, shift, s.ctrl)
			s.clicked.connect(on_click)
			grid.add_child(s)
			row_slots.append(s)
		body.add_child(frame)
		lanes.append(row_slots)
	screen.set_meta("belt_lanes", lanes)
	refresh(screen, {"bl": last.get("bl", [])})


## The settings part of an inserter's window (also used without the hand row).
static func inserter(screen, ins: Dictionary) -> Control:
	var box := EntityPanels.column(6)
	box.name = "InserterSettings"
	var n := int(ins.get("n", 0))
	if n > 0:
		var r := EntityPanels.row(8)
		var left := EntityPanels.column(4)
		var use := func(on: bool) -> void: screen.model.set_inserter(screen.unit, null, "", 1 if on else 0)
		left.add_child(EntityPanels.checkbox("Use filters", int(ins.get("use", 0)) == 1, use))
		var mode := "right" if str(ins.get("m", "whitelist")) == "blacklist" else "left"
		var sw := LogicKit.switch("Whitelist", "Blacklist", mode,
			func(s: String) -> void: screen.model.set_inserter(screen.unit, null, "blacklist" if s == "right" else "whitelist"))
		sw.name = "FilterMode"
		left.add_child(sw)
		r.add_child(left)
		var filters: Array = (ins.get("f", []) as Array).duplicate()
		var frame := Kit.panel("FDeepFrame")
		var grid := Kit.slot_grid(n)
		frame.add_child(grid)
		for i in n:
			var index := i
			var current := str(filters[i]) if i < filters.size() else ""
			var set_filter := func(_type: String, item: String) -> void:
				while filters.size() < n:
					filters.append("")
				filters[index] = item
				screen.model.set_inserter(screen.unit, filters, "", 1 if item != "" else -1)
			grid.add_child(EntityPanels.choose_slot(screen, current, ["item"], set_filter, "Filter"))
		_right(r, frame)
		box.add_child(r)
		box.add_child(LogicKit.line())
	var stack := int(ins.get("st", 0))
	var most := maxi(1, int(ins.get("max", 1)))
	var size_row := EntityPanels.row(8)
	var slider := LogicKit.notched(1, maxi(2, most), stack if stack > 0 else most, stack > 0,
		func(v: int) -> void: screen.model.set_inserter(screen.unit, null, "", -1, v))
	slider.name = "HandSize"
	# No capacity bonus (a plain inserter at 1): nothing above 1 to pick, as the game ignores an override over the force's limit.
	slider.max_value = most
	slider.value = clampi(slider.value, 1, most)
	slider.box.text = str(slider.value)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var override := func(on: bool) -> void: screen.model.set_inserter(screen.unit, null, "", -1, slider.value if on else 0)
	size_row.add_child(EntityPanels.checkbox("Override hand size", stack > 0, override))
	size_row.add_child(slider)
	box.add_child(size_row)
	if ins.has("sp"):
		box.add_child(LogicKit.line())
		box.add_child(spoil_priority(screen, str(ins["sp"])))
	return box


## Space Age: "Spoiled priority (i)" and which first, greyed until it is ticked.
static func spoil_priority(screen, sp: String) -> Control:
	var r := EntityPanels.row(8)
	var on := sp != "none"
	var send := func(v: String) -> void: screen.model.set_inserter(screen.unit, null, "", -1, -1, v)
	r.add_child(LogicKit.info_checkbox("Spoiled priority", "Selects items based on spoiled percentage.\n\nOnly takes effect when taking items from an inventory.", on,
		func(v: bool) -> void: send.call("spoiled-first" if v else "none")))
	var radios := EntityPanels.radios([["spoiled-first", "Spoiled first"], ["fresh-first", "Fresh first"]], sp if on else "spoiled-first", send)
	_radios_enabled(radios, on)
	_right(r, radios)
	return r


## Factorio's splitter: "Input priority" and "Output priority", each a checkbox and a Left/Right
## switch, the filter at the end of the output row.
static func splitter(screen, spl: Dictionary) -> Control:
	var box := EntityPanels.column(6)
	box.name = "SplitterSettings"
	for side in [["i", "Input priority"], ["o", "Output priority"]]:
		var key: String = side[0]
		var current := str(spl.get(key, "none"))
		var r := EntityPanels.row(12)
		var sw := LogicKit.switch("Left", "Right", current if current != "none" else "left")
		sw.name = "Priority_" + key
		sw.set_enabled(current != "none")
		var send := func(v: String) -> void:
			if key == "i":
				screen.model.set_splitter(screen.unit, v)
			else:
				screen.model.set_splitter(screen.unit, "", v)
		sw.switched.connect(send)
		var cb := EntityPanels.checkbox(str(side[1]), current != "none", func(on: bool) -> void: send.call(sw.state if on else "none"))
		cb.custom_minimum_size.x = Kit.px(150)
		r.add_child(cb)
		r.add_child(sw)
		if key == "o":
			var f := EntityPanels.row(8)
			var l := Kit.label("Filter")
			l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			f.add_child(l)
			var set_filter := func(_type: String, item: String) -> void:
				# A filter needs an output side to send it to, as in Factorio: left unless one is set.
				var out := "" if current != "none" or item == "" else "left"
				screen.model.set_splitter(screen.unit, "", out, item)
			f.add_child(EntityPanels.choose_slot(screen, str(spl.get("f", "")), ["item"], set_filter, "Filter"))
			_right(r, f)
		box.add_child(r)
		if key == "i":
			box.add_child(LogicKit.line())
	return box


## Factorio's power switch: "State" and an Off/On switch.
static func power_switch(screen, on: bool) -> Control:
	var box := EntityPanels.column(4)
	box.add_child(Kit.label("State", "FHeading"))
	var sw := LogicKit.switch("Off", "On", "right" if on else "left",
		func(s: String) -> void: screen.model.set_switch(screen.unit, s == "right"))
	sw.name = "PowerSwitch"
	box.add_child(sw)
	return box


# --- lamps, speakers, display panels, pumps, tanks ----------------------------------------------

static func _lamp(screen, last: Dictionary, body: VBoxContainer) -> void:
	var status := _status_row(body)
	if status == null:
		status = EntityPanels.row(6)
		body.add_child(status)
	if last.get("col") is Array:
		_right(status, LogicKit.color_buttons(screen, last["col"]))
	if last.has("ao"):
		body.add_child(LogicKit.info_checkbox("Always on", "Lamp will be always on (unless disabled by control behavior).", int(last["ao"]) == 1,
			func(on: bool) -> void: Bridge.send({"t": "set_lamp", "u": screen.unit, "ao": 1 if on else 0})))


## Factorio's programmable speaker: the network strip, its circuit settings (play condition, pitch,
## stop, volume signal), the sound settings and the alert.
static func _speaker(screen, last: Dictionary, body: VBoxContainer) -> void:
	var spk: Dictionary = last["spk"]
	body.add_child(LogicKit.network_header(last))
	body.move_child(body.get_child(body.get_child_count() - 1), 0)
	var send := func(cmd: Dictionary) -> void: screen.model.set_speaker(screen.unit, cmd)
	var box := EntityPanels.column(6)
	box.add_child(Kit.label("Circuit connection settings", "FHeading"))
	var cc = last.get("cc")
	var f: Dictionary = cc.get("f") if cc is Dictionary and cc.get("f") is Dictionary else {}
	var cond: Dictionary = (f.get("circuit_condition") as Dictionary).duplicate(true) if f.get("circuit_condition") is Dictionary else {"comparator": "<", "constant": 0}
	cond.erase("ful")
	box.add_child(EntityPanels._condition_editor(screen, cond, CircuitPanel.SIGNAL_KINDS,
		func(c: Dictionary) -> void: screen.model.set_circuit(screen.unit, {"circuit_condition": c})))
	box.add_child(EntityPanels.checkbox("Signal value is pitch", int(spk.get("pitch", 0)) == 1, func(on: bool) -> void: send.call({"pitch": 1 if on else 0})))
	box.add_child(EntityPanels.checkbox("Stop playing sounds", int(spk.get("stop", 0)) == 1, func(on: bool) -> void: send.call({"stop": 1 if on else 0})))
	box.add_child(LogicKit.line())
	box.add_child(EntityPanels.choose_slot(screen, EntityPanels._signal_name(spk.get("vsig")), CircuitPanel.SIGNAL_KINDS,
		func(t: String, n: String) -> void: send.call({"vsig": {"type": t, "name": n} if n != "" else {}}), "Volume signal"))
	box.add_child(EntityPanels.checkbox("Signal value is volume", int(spk.get("vctl", 0)) == 1, func(on: bool) -> void: send.call({"vctl": 1 if on else 0})))
	box.add_child(LogicKit.line())
	box.add_child(Kit.label("Sound settings", "FHeading"))
	var vol_row := EntityPanels.row(8)
	vol_row.add_child(Kit.label("Volume"))
	var vol := MenuKit.slider(0, 100, 1, roundf(float(spk.get("vol", 1)) * 100.0))
	vol.name = "Volume"
	vol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vol.drag_ended.connect(func(_changed: bool) -> void: send.call({"vol": vol.value / 100.0}))
	vol_row.add_child(vol)
	box.add_child(vol_row)
	var mode_row := EntityPanels.row(8)
	mode_row.add_child(Kit.label("Playback mode"))
	_right(mode_row, EntityPanels.radios([["local", "Local"], ["surface", "Surface"], ["global", "Universe"]], str(spk.get("mode", "local")),
		func(v: String) -> void: send.call({"mode": v})))
	box.add_child(mode_row)
	var instruments: Array = spk.get("il") if spk.get("il") is Array else []
	var inst := int(spk.get("inst", 0))
	var inst_items: Array = []
	for i in instruments.size():
		inst_items.append([str(instruments[i][0]).replace("-", " ").capitalize(), i])
	var inst_row := EntityPanels.row(8)
	inst_row.add_child(Kit.label("Category/Instrument"))
	var inst_box := MenuKit.dropdown(inst_items, inst)
	inst_box.name = "Instrument"
	inst_box.custom_minimum_size.x = Kit.px(136)
	inst_box.item_selected.connect(func(i: int) -> void: send.call({"inst": i}))
	_right(inst_row, inst_box)
	box.add_child(inst_row)
	var notes: Array = instruments[inst][1] if inst >= 0 and inst < instruments.size() and instruments[inst][1] is Array else []
	var note_items: Array = []
	for i in notes.size():
		note_items.append([str(notes[i]).replace("-", " ").capitalize(), i])
	var note_row := EntityPanels.row(8)
	note_row.add_child(Kit.label("Sound/Note"))
	var note_box := MenuKit.dropdown(note_items, int(spk.get("note", 0)))
	note_box.name = "Note"
	note_box.custom_minimum_size.x = Kit.px(116)
	note_box.item_selected.connect(func(i: int) -> void: send.call({"note": i}))
	_right(note_row, note_box)
	box.add_child(note_row)
	box.add_child(EntityPanels.checkbox("Allow polyphony", int(spk.get("poly", 0)) == 1, func(on: bool) -> void: send.call({"poly": 1 if on else 0})))
	box.add_child(LogicKit.line())
	var al: Dictionary = spk.get("al") if spk.get("al") is Dictionary else {}
	box.add_child(EntityPanels.checkbox("Show alert", int(al.get("show", 0)) == 1, func(on: bool) -> void: send.call({"al": {"show": 1 if on else 0}})))
	var msg_row := EntityPanels.row(8)
	msg_row.add_child(EntityPanels.choose_slot(screen, EntityPanels._signal_name(al.get("icon")), CircuitPanel.SIGNAL_KINDS,
		func(t: String, n: String) -> void: send.call({"al": {"icon": {"type": t, "name": n} if n != "" else {}}}), "Alert icon"))
	var text := MenuKit.textbox(str(al.get("msg", "")), "")
	text.name = "AlertMessage"
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.text_submitted.connect(func(t: String) -> void: send.call({"al": {"msg": t}}))
	msg_row.add_child(text)
	box.add_child(msg_row)
	box.add_child(EntityPanels.checkbox("Show icon on map", int(al.get("map", 0)) == 1, func(on: bool) -> void: send.call({"al": {"map": 1 if on else 0}})))
	body.add_child(box)


## Factorio's display panel: the Alt-mode and chart checkboxes, the icon, the text in a large box
## with a green tick to confirm; with a circuit network, its messages and their conditions.
static func display_panel(screen, dp: Dictionary) -> Control:
	var box := EntityPanels.column(8)
	var send := func(settings: Dictionary) -> void: screen.model.set_panel(screen.unit, settings)
	box.add_child(LogicKit.info_checkbox("Always show in \"Alt-mode\"", "Always show the first line of the display panel's text in \"Alt-mode\" even when not selected.", int(dp.get("show", 0)) == 1,
		func(on: bool) -> void: send.call({"show": 1 if on else 0})))
	box.add_child(LogicKit.info_checkbox("Show tag in chart", "Show the chosen icon and the first line of text in the map charts.", int(dp.get("chart", 0)) == 1,
		func(on: bool) -> void: send.call({"chart": 1 if on else 0})))
	var icon_row := EntityPanels.row(8)
	var il := Kit.label("Icon")
	il.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	icon_row.add_child(il)
	icon_row.add_child(EntityPanels.choose_slot(screen, EntityPanels._signal_name(dp.get("icon")), CircuitPanel.SIGNAL_KINDS,
		func(t: String, n: String) -> void: send.call({"icon": {"type": t, "name": n} if n != "" else {}}), "Icon"))
	box.add_child(icon_row)
	var text := TextEdit.new()
	text.name = "PanelText"
	text.text = str(dp.get("text", ""))
	text.custom_minimum_size = Kit.pxv(396, 296)
	text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	text.add_theme_stylebox_override("normal", MenuKit.theme().get_stylebox("normal", "LineEdit"))
	text.add_theme_stylebox_override("focus", MenuKit.theme().get_stylebox("focus", "LineEdit"))
	text.add_theme_color_override("font_color", Kit.BLACK)
	text.add_theme_font_override("font", Kit.font("regular"))
	box.add_child(text)
	var ok_row := HBoxContainer.new()
	var ok := Button.new()
	ok.name = "Confirm"
	ok.theme_type_variation = "FGreenButton"
	ok.custom_minimum_size = Kit.pxv(28, 28)
	ok.focus_mode = Control.FOCUS_NONE
	ok.tooltip_text = "Confirm"
	var tick := GuiAssets.core_sprite("icons/mip/confirm.png")
	if tick != null:
		ok.icon = tick
		ok.expand_icon = true
		ok.add_theme_constant_override("icon_max_width", Kit.px(20))
	else:
		ok.text = "✔"
	ok.pressed.connect(func() -> void: send.call({"text": text.text}))
	_right(ok_row, ok)
	box.add_child(ok_row)
	var msgs: Array = (dp.get("msgs") as Array).duplicate(true) if dp.get("msgs") is Array else []
	var wired: bool = screen._last.get("sig") is Dictionary or (screen._last.get("cc") is Dictionary and int(screen._last["cc"].get("w", 0)) == 1)
	if wired or not msgs.is_empty():
		box.add_child(LogicKit.line())
		box.add_child(LogicKit.info_label("Messages", "With a circuit network the first message whose condition holds is shown", "FHeading"))
		var send_msgs := func() -> void: send.call({"msgs": msgs})
		var list := EntityPanels.column(4)
		list.name = "Messages"
		for i in msgs.size():
			list.add_child(EntitySettings._message_row(screen, msgs, i, send_msgs))
		box.add_child(list)
		box.add_child(LogicKit.wide_button("+ Add message", func() -> void:
			msgs.append({"text": "", "icon": {}, "cond": {"comparator": "<", "constant": 0}})
			send_msgs.call()))
	return box


## Factorio's pump: "Select filter" and the fluid slot; its fluid isn't shown as a fluid box.
static func pump(screen, filter: String) -> Control:
	var box := EntityPanels.column(4)
	box.add_child(Kit.label("Select filter"))
	box.add_child(EntityPanels.choose_slot(screen, filter, ["fluid"], func(_t: String, n: String) -> void: screen.model.set_pump(screen.unit, n), "Fluid filter"))
	return box


## Factorio's storage tank and pipe: the fluid's icon and name ("No fluid") with its fill in
## percent over a thin bar, the temperature ("N/A" empty), "<entity> contents: x of y" and
## "Pipeline contents: x of y" (`gui.pl`, the fluid segment), each with its red flush button (grey
## while empty). Factorio's "Visualize pipeline" box isn't here: the client can't outline a segment.
static func _tank(screen, last: Dictionary, body: VBoxContainer) -> void:
	var fb = last.get("fb")
	var entry: Array = fb[0] if fb is Array and not fb.is_empty() and fb[0] is Array and (fb[0] as Array).size() >= 3 else ["", 0, 100]
	var fluid := str(entry[0])
	var amount := float(entry[1])
	var capacity := maxf(1.0, float(entry[2]))
	var col := EntityPanels.column(2)
	col.name = "TankFluid"
	var r := EntityPanels.row(6)
	var icon := TextureRect.new()
	icon.texture = Kit.item_icon(fluid) if fluid != "" else null
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.custom_minimum_size = Kit.pxv(32, 32)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r.add_child(icon)
	var bars := EntityPanels.column(2)
	bars.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var line := EntityPanels.row(6)
	line.add_child(Kit.label(Kit.pretty(fluid) if fluid != "" else "No fluid"))
	_right(line, Kit.label("%d%%" % roundi(amount / capacity * 100.0)))
	bars.add_child(line)
	var bar := Kit.progress_bar(screen._fluid_color(fluid))
	bar.max_value = capacity
	bar.value = amount
	bar.custom_minimum_size.y = Kit.px(6)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bars.add_child(bar)
	r.add_child(bars)
	col.add_child(r)
	body.add_child(col)
	body.add_child(_bold_pair("Temperature:", "%d °C" % int(entry[3]) if fluid != "" and entry.size() > 3 else "N/A"))
	var t := entity_type(screen)
	body.add_child(_flush_row(screen, str(PIPELINE.get(t, "Contents:")), amount, capacity, fluid, 0))
	var pl = last.get("pl")
	if pl is Array and (pl as Array).size() >= 3:
		body.add_child(LogicKit.line())
		body.add_child(_flush_row(screen, "Pipeline contents:", float(pl[1]), float(pl[2]), str(pl[0]), 1))


## "Pipe contents: 0.00 of 100" and its red flush button at the right (grey while empty).
static func _flush_row(screen, title: String, amount: float, capacity: float, fluid: String, pipe: int) -> HBoxContainer:
	var r := _bold_pair(title, "%s of %d" % [_fluid_amount(amount, capacity), roundi(capacity)])
	r.name = "Flush%d" % pipe
	var what := ("this pipeline" if pipe == 1 else "this entity")
	var trash := LogicKit.tool_button("icons/mip/trash.png", "Flush %s from %s." % [Kit.pretty(fluid), what] if fluid != "" else "Nothing to flush",
		func() -> void: Bridge.send({"t": "flush", "u": screen.unit, "pipe": pipe}), "FRedButton")
	trash.name = "FlushButton"
	trash.disabled = amount <= 0.0 or fluid == ""
	_right(r, trash)
	return r


## Factorio writes small amounts with two decimals ("0.00 of 100"), a tank's in whole units.
static func _fluid_amount(v: float, capacity: float) -> String:
	return "%.2f" % v if capacity < 1000.0 else "%d" % roundi(v)


## Factorio's heat pipe: one red bar with "Temperature: 656.13 °C" in it, full at its maximum
## (machine_info.lua's tc in hundredths of a degree, tmax).
static func _heat_pipe(_screen, last: Dictionary, body: VBoxContainer) -> void:
	var temp := float(last["tc"]) / 100.0 if last.has("tc") else float(last.get("temp", 15))
	var holder := Control.new()
	holder.name = "HeatBar"
	holder.custom_minimum_size = Kit.pxv(0, 28)
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var bar := Kit.progress_bar(Color8(209, 61, 50))
	bar.max_value = maxf(1.0, float(last.get("tmax", 1000)))
	bar.value = clampf(temp, 0.0, bar.max_value)
	bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(bar)
	var text := Kit.label("Temperature: %.2f °C" % temp)
	text.set_anchors_preset(Control.PRESET_FULL_RECT)
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	text.offset_right = -Kit.px(8)
	holder.add_child(text)
	body.add_child(holder)


static func _bold_pair(a: String, b: String) -> HBoxContainer:
	var r := EntityPanels.row(6)
	r.add_child(Kit.label(a, "FHeading"))
	r.add_child(Kit.label(b))
	return r


# --- turrets, roboports, vehicles, wagons, poles ---------------------------------------------------

static func _turret(screen, last: Dictionary, body: VBoxContainer) -> void:
	var artillery := last.has("art")
	if artillery:
		body.add_child(auto_targeting(screen, last))
	if screen.knows_slots("turret_ammo") or (last.get("inv") is Dictionary and last["inv"].has("turret_ammo")):
		body.add_child(LogicKit.slot_row(screen, "turret_ammo", "icons/mip/empty-ammo-slot.png", 1))
	# Artillery has no target priorities in Factorio's window, only "Auto targeting".
	if last.get("tgt") is Dictionary and not artillery:
		body.add_child(LogicKit.line())
		body.add_child(turret_targets(screen, last["tgt"]))


## "Target priorities (i)": ten slots of what it shoots first, and "Ignore unlisted targets (i)".
static func turret_targets(screen, tgt: Dictionary) -> Control:
	var box := EntityPanels.column(6)
	box.add_child(LogicKit.info_label("Target priorities", "Gives an explicit order in which targets will be picked if multiple are in range.", "FHeading"))
	var list: Array = (tgt.get("l") as Array).duplicate() if tgt.get("l") is Array else []
	var frame := Kit.panel("FDeepFrame")
	var grid := Kit.slot_grid(Kit.COLUMNS)
	grid.name = "Targets"
	frame.add_child(grid)
	var cells := maxi(Kit.COLUMNS, ceili((list.size() + 1) / float(Kit.COLUMNS)) * Kit.COLUMNS)
	for i in cells:
		var index := i
		if i > list.size():
			grid.add_child(Kit.empty_cell())
			continue
		var set_target := func(_t: String, n: String) -> void:
			var l := list.duplicate()
			if n == "":
				if index < l.size():
					l.remove_at(index)
			elif index < l.size():
				l[index] = n
			else:
				l.append(n)
			screen.model.set_targets(screen.unit, l)
		grid.add_child(EntityPanels.choose_slot(screen, str(list[i]) if i < list.size() else "", ["entity"], set_target, "Add a priority target"))
	box.add_child(frame)
	box.add_child(LogicKit.line())
	box.add_child(LogicKit.info_checkbox("Ignore unlisted targets", "If set, targets not appearing in the priority list will never be targeted. Otherwise they come after all listed targets.", int(tgt.get("ign", 0)) == 1,
		func(on: bool) -> void: screen.model.set_targets(screen.unit, null, 1 if on else 0)))
	return box


## Factorio's roboport: network header strip, robot and repair pack slots (7 each), and robot requests.
static func _roboport(screen, body: VBoxContainer) -> void:
	var last: Dictionary = screen._last
	var lg: Dictionary = last.get("lg") if last.get("lg") is Dictionary else {}
	var net = lg.get("net")
	var in_net: bool = net is Dictionary
	var net_box := EntityPanels.column(4)
	var net_top := EntityPanels.row(6)
	var dot_tex := GuiAssets.status_dot("green" if in_net else "red")
	if dot_tex != null:
		var dot := TextureRect.new()
		dot.texture = dot_tex
		dot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		dot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		dot.custom_minimum_size = Kit.pxv(14, 14)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		dot.texture_filter = Kit.ICON_FILTER
		net_top.add_child(dot)
	var net_title := "Not in a logistic network"
	if in_net:
		var net_dict: Dictionary = net
		var net_name := str(net_dict.get("name", ""))
		net_title = net_name if net_name != "" else "Network #%d" % int(net_dict.get("id", 0))
	var title_lbl := Kit.label(net_title, "FHeading")
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	net_top.add_child(title_lbl)
	if in_net:
		var net_id := int((net as Dictionary).get("id", 0))
		var open_net := func() -> void:
			screen.open_network_requested.emit(net_id)
		var btn := MenuKit.button("Open logistic network")
		btn.name = "OpenNetwork"
		btn.pressed.connect(open_net)
		net_top.add_child(btn)
	net_box.add_child(net_top)
	if in_net:
		var net_dict: Dictionary = net
		var log_r: Array = net_dict.get("log", [0, 0]) if net_dict.get("log") is Array else [0, 0]
		var con_r: Array = net_dict.get("con", [0, 0]) if net_dict.get("con") is Array else [0, 0]
		if log_r.size() >= 2 and con_r.size() >= 2:
			var bots_lbl := Kit.label("Logistic: %d / %d · Construction: %d / %d" % [
				int(log_r[0]), int(log_r[1]), int(con_r[0]), int(con_r[1])])
			bots_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			net_box.add_child(bots_lbl)
	var cell = lg.get("cell")
	if cell is Dictionary:
		var cell_dict: Dictionary = cell
		var cell_lbl := Kit.label("Stationed: %d logistic, %d construction · Charging: %d (%d waiting)" % [
			int(cell_dict.get("sl", 0)), int(cell_dict.get("sc", 0)),
			int(cell_dict.get("ch", 0)), int(cell_dict.get("tc", 0))])
		cell_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		net_box.add_child(cell_lbl)
	body.add_child(net_box)
	body.add_child(LogicKit.line())
	body.add_child(LogicKit.slot_row(screen, "robots", "icons/mip/empty-robot-slot.png", 7))
	body.add_child(LogicKit.line())
	body.add_child(LogicKit.slot_row(screen, "repair", "icons/mip/empty-robot-material-slot.png", 7))
	var lc = last.get("lc")
	if lc is Dictionary:
		var lc_dict: Dictionary = lc
		body.add_child(LogicKit.line())
		body.add_child(ProductionPanels.network_heading("Logistic requests", in_net or int(lc_dict.get("in_net", 0)) == 1))
		var secs_data: Array = (lc_dict.get("sec") as Array).duplicate(true) if lc_dict.get("sec") is Array else []
		var status_ctx := SpacePanels.build_status_context(screen._slot_list("robots"), Wire.array(lc_dict.get("del")), Wire.array(lc_dict.get("pick")))
		var secs := SpacePanels.sections(screen, secs_data, [], false, status_ctx)
		if secs.get_child_count() > 0:
			var heading := secs.get_child(0)
			secs.remove_child(heading)
			heading.queue_free()
		body.add_child(secs)


## Artillery's "Auto targeting" checkbox (`gui.art`, set_artillery).
static func auto_targeting(screen, last: Dictionary) -> Control:
	var c := MenuKit.checkbox("Auto targeting", int(last.get("art", 1)) == 1)
	c.name = "AutoTargeting"
	c.tooltip_text = "Shoot at enemies in range automatically"
	c.toggled.connect(func(on: bool) -> void: Bridge.send({"t": "set_artillery", "u": screen.unit, "on": 1 if on else 0}))
	return c


## Factorio's car, tank and spidertron: a spidertron's name strip (rename, colour), the fuel and its
## bar, each gun over its ammo slot with the equipment grid button after them (a spidertron's "Auto
## targeting" boxes at the right), the trunk and (for spidertron) its Inventory / Logistics tabs.
static func _vehicle(screen, last: Dictionary, body: VBoxContainer) -> void:
	var inv: Dictionary = last.get("inv") if last.get("inv") is Dictionary else {}
	var veh: Dictionary = last.get("veh") if last.get("veh") is Dictionary else {}
	var is_spider := entity_type(screen) == "spider-vehicle"
	if is_spider:
		var strip := _name_strip(screen, str(veh.get("lbl", "")), Kit.entity_name(str(screen.proto_name)), "Rename",
			func(t: String) -> void: Bridge.send({"t": "set_vehicle", "u": screen.unit, "lbl": t}))
		body.add_child(strip)
		body.move_child(strip, 0)
	if screen.knows_slots("fuel") or inv.has("fuel"):
		body.add_child(LogicKit.fuel_row(screen))
		body.add_child(LogicKit.line())
	var guns: Array = last.get("guns") if last.get("guns") is Array else []
	var ammo: Array = screen._slot_list("car_ammo")
	if not guns.is_empty() or not ammo.is_empty():
		var n := maxi(1, maxi(guns.size(), ammo.size()))
		var cols := EntityPanels.column(4)
		cols.name = "Guns"
		var gun_row := HBoxContainer.new()
		gun_row.add_theme_constant_override("separation", 0)
		for i in n:
			var g := Slot.new()
			g.mouse_filter = Control.MOUSE_FILTER_PASS
			g.custom_minimum_size = Kit.pxv(Kit.SLOT, 24)
			g.flat = true
			if i < guns.size():
				g.set_stack(str(guns[i]), -1)
				g.set_tip(Kit.pretty(str(guns[i])))
			gun_row.add_child(g)
		cols.add_child(gun_row)
		var ammo_row := HBoxContainer.new()
		ammo_row.add_theme_constant_override("separation", 0)
		var exact: bool = screen.knows_slots("car_ammo")
		var empty := GuiAssets.core_sprite("icons/mip/empty-ammo-slot.png")
		for i in n:
			var stack: Dictionary = ammo[i] if i < ammo.size() else {}
			var s: Slot = screen._stack_slot("car_ammo", i + 1 if exact else 0, stack)
			if stack.is_empty():
				s.empty_icon = empty
			ammo_row.add_child(s)
		if int(veh.get("grid", 0)) == 1:
			ammo_row.add_child(_grid_button(screen))
		cols.add_child(ammo_row)
		var r := EntityPanels.row(8)
		r.add_child(cols)
		if veh.get("at") is Array and (veh["at"] as Array).size() >= 2:
			_right(r, _spider_targeting(screen, veh["at"]))
		body.add_child(r)
		body.add_child(LogicKit.line())
	var lc = last.get("lc")
	if is_spider and lc is Dictionary:
		var lc_dict: Dictionary = lc
		var unit: int = screen.unit
		var tab := str(screen.get_meta("spider_tab", "Inventory")) if int(screen.get_meta("spider_tab_unit", 0)) == unit else "Inventory"
		var tabs := HBoxContainer.new()
		tabs.add_theme_constant_override("separation", 0)
		for t_name in ["Inventory", "Logistics"]:
			var b := Button.new()
			b.text = t_name
			b.name = "SpiderTab_" + t_name
			b.theme_type_variation = "FTab"
			b.toggle_mode = true
			b.button_pressed = t_name == tab
			b.focus_mode = Control.FOCUS_NONE
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.custom_minimum_size = Kit.pxv(110, 28)
			b.add_theme_font_override("font", Kit.font("bold"))
			var picked: String = t_name
			var on_pick := func() -> void:
				screen.set_meta("spider_tab", picked)
				screen.set_meta("spider_tab_unit", unit)
				screen._rebuild_now()
			b.pressed.connect(on_pick)
			tabs.add_child(b)
		body.add_child(tabs)
		if tab == "Logistics":
			var lg = last.get("lg")
			var in_net := int(lc_dict.get("in_net", 0)) == 1 or (lg is Dictionary and (lg as Dictionary).get("net") is Dictionary)
			body.add_child(ProductionPanels.network_heading("Logistic requests", in_net))
			var set_on := func(v: bool) -> void: Bridge.send({"t": "set_chest_logistics", "u": unit, "on": 1 if v else 0})
			body.add_child(EntityPanels.checkbox("Enable logistics", int(lc_dict.get("on", 1)) == 1, set_on))
			var set_mv := func(v: bool) -> void: Bridge.send({"t": "set_chest_logistics", "u": unit, "mv": 1 if v else 0})
			body.add_child(EntityPanels.checkbox("Enable logistics while moving", int(lc_dict.get("mv", 1)) == 1, set_mv))
			var set_tu := func(v: bool) -> void: Bridge.send({"t": "set_chest_logistics", "u": unit, "tu": 1 if v else 0})
			body.add_child(EntityPanels.checkbox("Trash unrequested", int(lc_dict.get("tu", 0)) == 1, set_tu))
			var secs_data: Array = (lc_dict.get("sec") as Array).duplicate(true) if lc_dict.get("sec") is Array else []
			var status_ctx := SpacePanels.build_status_context(screen._slot_list("trunk"), Wire.array(lc_dict.get("del")), Wire.array(lc_dict.get("pick")))
			var secs := SpacePanels.sections(screen, secs_data, [], false, status_ctx)
			if secs.get_child_count() > 0:
				var heading := secs.get_child(0)
				secs.remove_child(heading)
				heading.queue_free()
			body.add_child(secs)
			if screen.knows_slots("trash") or inv.has("trash"):
				body.add_child(ProductionPanels.trash_slots(screen))
		elif screen.knows_slots("trunk") or inv.has("trunk"):
			body.add_child(Kit.label("Trunk", "FHeading"))
			body.add_child(screen._grid_frame("trunk", inv, Kit.COLUMNS))
	elif screen.knows_slots("trunk") or inv.has("trunk"):
		body.add_child(Kit.label("Trunk", "FHeading"))
		body.add_child(screen._grid_frame("trunk", inv, Kit.COLUMNS))


## The equipment grid button after a vehicle's ammo slots: Factorio's slot-sized button with the
## grid icon; it shows the vehicle's grid beside the inventory (pressed while shown).
static func _grid_button(screen) -> Button:
	var b := Button.new()
	b.name = "EquipmentGrid"
	b.theme_type_variation = "FPageButton"
	b.custom_minimum_size = Kit.pxv(Kit.SLOT, Kit.SLOT)
	b.focus_mode = Control.FOCUS_NONE
	b.toggle_mode = true
	b.button_pressed = vehicle_grid_open
	b.tooltip_text = "Equipment grid"
	var icon := GuiAssets.core_sprite("icons/mip/grid-view.png")
	if icon != null:
		b.add_child(LogicKit._icon_over(icon, 6))
	else:
		b.text = "#"
	b.toggled.connect(func(on: bool) -> void:
		vehicle_grid_open = on
		screen.opened_changed.emit(true))
	return b


## A spidertron's "Auto targeting": Without gunner / With gunner (`gui.veh.at`, set_vehicle).
static func _spider_targeting(screen, at: Array) -> Control:
	var box := EntityPanels.column(2)
	box.name = "SpiderTargeting"
	box.add_child(Kit.label("Auto targeting"))
	var wo := MenuKit.checkbox("Without gunner", int(at[0]) == 1)
	wo.name = "WithoutGunner"
	wo.tooltip_text = "Shoot nearby enemies automatically when the vehicle is empty"
	wo.toggled.connect(func(on: bool) -> void: Bridge.send({"t": "set_vehicle", "u": screen.unit, "wo": 1 if on else 0}))
	box.add_child(wo)
	var wi := MenuKit.checkbox("With gunner", int(at[1]) == 1)
	wi.name = "WithGunner"
	wi.tooltip_text = "Shoot nearby enemies automatically when a gunner (driver or passenger) is in the vehicle"
	wi.toggled.connect(func(on: bool) -> void: Bridge.send({"t": "set_vehicle", "u": screen.unit, "wi": 1 if on else 0}))
	box.add_child(wi)
	return box


## The dark name strip a spidertron's window starts with: the name in bold, the rename pencil (a
## text box in its place until Enter), the eyedropper and the colour swatch.
static func _name_strip(screen, name: String, fallback: String, tip: String, on_rename: Callable) -> Control:
	var sh := LogicKit.subheader()
	var head: HBoxContainer = sh[1]
	var title := Kit.label(name if name != "" else fallback, "FHeading")
	title.name = "VehicleName"
	title.add_theme_color_override("font_color", Kit.WHITE)
	head.add_child(title)
	var field := MenuKit.textbox(name)
	field.name = "VehicleNameField"
	field.visible = false
	field.custom_minimum_size.x = Kit.px(170)
	field.text_submitted.connect(func(t: String) -> void:
		field.release_focus()
		on_rename.call(t.strip_edges()))
	head.add_child(field)
	var rename := LogicKit.rename_button(tip, func() -> void:
		title.visible = false
		field.visible = true
		field.grab_focus()
		field.select_all())
	rename.name = "Rename"
	head.add_child(rename)
	if screen._last.get("col") is Array:
		LogicKit.push_right(head, LogicKit.color_buttons(screen, screen._last["col"]))
	return LogicKit.bleed(sh[0])


## A cargo, fluid or artillery wagon: only its own inventory, a cargo wagon's limit (red X), an
## artillery wagon's "Auto targeting".
static func _wagon(screen, inv: Dictionary, body: VBoxContainer) -> void:
	if screen._last.has("art"):
		body.add_child(auto_targeting(screen, screen._last))
	for role in ["cargo", "ammo"]:
		if screen.knows_slots(role) or inv.has(role):
			# The red X sits in the grid at the limit, as production_panels.gd draws a chest's.
			var x: Control = screen._bar_button() if role == "cargo" and screen._last.has("bar") else null
			body.add_child(ProductionPanels.chest_grid(screen, role, x))
	var tr = screen._last.get("tr")
	if tr is Dictionary and screen.knows_slots("cargo") == false and not inv.has("cargo") and not inv.has("ammo"):
		# A fluid wagon: what the train carries of fluids.
		for f in (tr.get("fluids", []) if tr.get("fluids") is Array else []):
			if f is Array and f.size() >= 2:
				body.add_child(Kit.label("%s: %d" % [Kit.pretty(str(f[0])), int(f[1])]))


## A pole opens Factorio's electric network info at once, not a window of its own.
static func _pole(screen) -> void:
	var r: Dictionary = screen._last
	if screen.open_stats.is_valid():
		var target := {"u": screen.unit, "p": int(r.get("p", 0)), "x": int(screen.target.get("x", 0)), "y": int(screen.target.get("y", 0))}
		screen.open_stats.call_deferred("electric", target)
		screen.call_deferred("close")
