extends RefCounted
## Factorio 2.1's schedule list (style.lua's train_schedule_*), shared by a train's window
## (train_window.gd) and a platform hub's (space_panels.gd), which differ only in what `kind` says.
##
## Each stop is a train_schedule_station_frame: the go button, its name, the draggable space that
## reorders it, a narrow delete button. Under it each wait condition is a frame in Factorio's own
## words ("30 s passed", "Cargo [item] [<] [100]"), with AND / OR straddling the gap between two,
## then "+ Add wait condition". "+ Add station" closes the list; the interrupts follow, each folded
## to a row that opens to its "When:" conditions and targets.

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const RichText := preload("res://scripts/ui/factorio/rich_text.gd")
const GuiAssets := preload("res://scripts/ui/factorio/gui_assets.gd")
const MenuKit := preload("res://scripts/menu/menu_kit.gd")
const LogicKit := preload("res://scripts/ui/factorio/logic_kit.gd")
const EntityPanels := preload("res://scripts/ui/factorio/entity_panels.gd")
const Slot := preload("res://scripts/ui/factorio/slot.gd")

## The space left of the wait conditions, where AND / OR sits.
const GUTTER := 100
## train_schedule_comparison_type_frame's left_margin, and its button.
const AND_OR_LEFT := 28
const AND_OR_SIZE := Vector2(56, 28)
## The list's rows, as train_schedule_scroll_pane's background tiles them (the frame plus a gap of 4).
const FRAME_HEIGHT := 32
## What each kind of wait says before its value, where that isn't the name it is added by.
const WAIT_WORDS := {"item_count": "Cargo", "fluid_count": "Fluid", "circuit": "Circuit",
	"fuel_item_count_all": "Fuel (all)", "fuel_item_count_any": "Fuel (any)"}
const REQUEST_WAITS := ["request_satisfied", "request_not_satisfied"]
const INTERRUPTS_TIP := "Interrupts are conditions that can be added to schedules.\nTheir configuration is shared globally between all trains or space platforms."
const WHEN_TIP := "When the conditions are met, the interrupt will activate and append all the targets to the schedule as temporary stops."
const TARGETS_TIP := "The target stops of this interrupt."
const INSIDE_TIP := "By default, an interrupt cannot trigger while another interrupt is being executed. This option disables this behavior, allowing the interrupt to trigger while another interrupt is in progress."

## Interrupts shown open, by name (folded otherwise; kept while the window is rebuilt).
static var open_interrupts := {}


## A train's: `stops` are the station names to pick from.
static func train_kind(stops: Array) -> Dictionary:
	return {"stops": stops, "waits": EntityPanels.WAIT_TYPES, "new_wait": EntityPanels._new_wait,
		"add_wait": "+ Add wait condition", "temporary": true, "unload": false,
		"stop_text": func(n: String) -> String: return n, "stop_icon": Callable(),
		"new_record": func(n: String) -> Dictionary: return {"station": n, "wait_conditions": [{"type": "time", "compare_type": "or", "ticks": 30 * 60}]}}


## A wide grey button opening a list (Factorio's "+ Add station" and "+ Add wait condition").
static func menu_button(text: String, items: Array) -> MenuButton:
	var b := MenuButton.new()
	b.text = text
	b.flat = false
	b.theme_type_variation = "Button"
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size.y = Kit.px(36)
	b.focus_mode = Control.FOCUS_NONE
	var p := b.get_popup()
	for i in items.size():
		p.add_item(str(items[i]), i)
	return b


## What picking item k does (pick(k, ctrl held)); kept as the button's "pick" meta for tests.
static func on_pick(b: MenuButton, pick: Callable) -> void:
	b.set_meta("pick", pick)
	b.get_popup().id_pressed.connect(func(id: int) -> void: pick.call(id, Input.is_key_pressed(KEY_CTRL)))


## train_schedule_delete_button: a narrow dark button with a cross.
static func delete_button(tip: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.theme_type_variation = "FDarkButton"
	b.custom_minimum_size = Kit.pxv(16, 28)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = tip
	var cross := GuiAssets.core_sprite("icons/close.png")
	if cross != null:
		b.icon = cross
		b.expand_icon = true
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.add_theme_constant_override("icon_max_width", Kit.px(12))
		b.add_theme_constant_override("h_separation", 0)
	else:
		b.text = "×"
	b.pressed.connect(on_press)
	return b


## `list` with entry `from` moved to where entry `to` is.
static func reorder(list: Array, from: int, to: int) -> Array:
	var l := list.duplicate(true)
	if from >= 0 and from < l.size() and to >= 0 and to < l.size() and from != to:
		var moved = l.pop_at(from)
		l.insert(to, moved)
	return l


## draggable_space_in_train_schedule, which drags its row; `row` takes a drop from the same `path`.
static func _grip(row: Control, path: String, index: int, on_move: Callable) -> Control:
	var grip := Kit.panel("FDraggable")
	grip.custom_minimum_size = Kit.pxv(60, 28)
	grip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	grip.mouse_default_cursor_shape = Control.CURSOR_DRAG
	grip.tooltip_text = "Drag to reorder"
	var drag := func(_at: Vector2) -> Variant:
		var preview := Kit.panel("FDraggable")
		preview.custom_minimum_size = Vector2(row.size.x, Kit.px(FRAME_HEIGHT))
		preview.modulate = Color(1, 1, 1, 0.7)
		grip.set_drag_preview(preview)
		return {"f3d_schedule": path, "from": index}
	var can := func(_at: Vector2, data: Variant) -> bool:
		return data is Dictionary and str(data.get("f3d_schedule", "")) == path and int(data.get("from", -1)) != index
	var drop := func(_at: Vector2, data: Variant) -> void: on_move.call(int(data["from"]), index)
	grip.set_drag_forwarding(drag, can, drop)
	row.set_drag_forwarding(Callable(), can, drop)
	row.set_meta("drop", drop)
	return grip


## Each record: its frame, then its wait conditions and "+ Add wait condition". `path` tells this
## list's rows from another's for dragging.
static func records(screen, list: VBoxContainer, recs: Array, current: int, kind: Dictionary, can_go: bool, on_change: Callable, path: String) -> void:
	for i in recs.size():
		var index := i
		var rec: Dictionary = recs[i] if recs[i] is Dictionary else {}
		var temporary := bool(rec.get("temporary", false))
		var bar := Kit.panel("FTemporaryStation" if temporary else "FShallowFrame")
		bar.custom_minimum_size.y = Kit.px(FRAME_HEIGHT)
		bar.name = "StopRow%d" % (i + 1)
		var r := EntityPanels.row(4)
		bar.add_child(LogicKit.padded(r, 2, 2))
		if can_go:
			r.add_child(_go_button(screen, i + 1, current))
		var station := str(rec.get("station", ""))
		if kind["stop_icon"].is_valid():
			var icon := TextureRect.new()
			icon.texture = kind["stop_icon"].call(station)
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon.custom_minimum_size = Kit.pxv(24, 24)
			icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			r.add_child(icon)
		var title: String = kind["stop_text"].call(station) if rec.has("station") else "Rail %s" % str(rec.get("rail", ""))
		var name := RichText.text_label("Temporary: %s" % title if temporary else title)
		name.name = "Station%d" % (i + 1)
		name.set("vertical_alignment", VERTICAL_ALIGNMENT_CENTER)
		r.add_child(name)
		var edit := func(key: String, value) -> void:
			var l := recs.duplicate(true)
			l[index][key] = value
			on_change.call(l)
		if kind["unload"]:
			var unload := EntityPanels.checkbox("Unload", bool(rec.get("allows_unloading", true)), func(on: bool) -> void: edit.call("allows_unloading", on))
			unload.tooltip_text = "Allow unloading cargo at this stop."
			r.add_child(unload)
		var move := func(from: int, to: int) -> void:
			on_change.call(reorder(recs, from, to))
			# The game keeps the index of the stop it is heading for: keep it on the same stop.
			if can_go and from + 1 == current:
				screen.model.train_go(screen.unit, to + 1)
		r.add_child(_grip(bar, path, i, move))
		var remove := delete_button("Remove this station", func() -> void:
			var l := recs.duplicate(true)
			l.remove_at(index)
			on_change.call(l))
		remove.name = "Remove%d" % (i + 1)
		r.add_child(remove)
		list.add_child(bar)
		var set_waits := func(w: Array) -> void: edit.call("wait_conditions", w)
		var conditions: Array = rec.get("wait_conditions", []) if rec.get("wait_conditions") is Array else []
		waits(screen, list, conditions, kind, set_waits, str(kind["add_wait"]), "%s:%d" % [path, i])


static func _go_button(screen, position: int, current: int) -> Button:
	var go := Button.new()
	go.name = "Go%d" % position
	go.custom_minimum_size = Kit.pxv(28, 28)
	go.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	go.focus_mode = Control.FOCUS_NONE
	go.toggle_mode = true
	go.button_pressed = position == current
	go.tooltip_text = "The train is going here" if position == current else "Go to this station now"
	var icon := GuiAssets.core_sprite("icons/mip/stop.png" if position == current else "icons/mip/play.png")
	if icon != null:
		go.icon = icon
		go.expand_icon = true
		go.add_theme_constant_override("icon_max_width", Kit.px(16))
	else:
		go.text = "■" if position == current else "▶"
	go.pressed.connect(func() -> void: screen.model.train_go(screen.unit, position))
	return go


## Wait conditions: each in its frame, an AND / OR button straddling the gap before each one after
## the first, then the add button.
static func waits(screen, list: VBoxContainer, conditions: Array, kind: Dictionary, on_change: Callable, add_text: String, path: String) -> void:
	for i in conditions.size():
		var index := i
		var w: Dictionary = conditions[i] if conditions[i] is Dictionary else {}
		var r := EntityPanels.row(4)
		var gutter := Control.new()
		gutter.custom_minimum_size.x = Kit.px(GUTTER)
		gutter.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if i > 0:
			var and_or := MenuKit.button(str(w.get("compare_type", "and")).to_upper())
			and_or.size = Kit.pxv(AND_OR_SIZE.x, AND_OR_SIZE.y)
			and_or.position = Vector2(Kit.px(AND_OR_LEFT), -Kit.px(16))
			and_or.name = "AndOr%d" % (i + 1)
			and_or.tooltip_text = "AND: both must hold · OR: either"
			and_or.pressed.connect(func() -> void:
				var l := conditions.duplicate(true)
				l[index]["compare_type"] = "or" if str(w.get("compare_type", "and")) == "and" else "and"
				on_change.call(l))
			gutter.add_child(and_or)
		r.add_child(gutter)
		var changed := func(c) -> void:
			var l := conditions.duplicate(true)
			l[index] = c
			on_change.call(l)
		var frame := Kit.panel("FShallowFrame")
		frame.custom_minimum_size.y = Kit.px(FRAME_HEIGHT)
		frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var inside := EntityPanels.row(4)
		var shown := condition(screen, w, kind, changed)
		_compact(shown)
		inside.add_child(shown)
		var move := func(from: int, to: int) -> void: on_change.call(reorder(conditions, from, to))
		inside.add_child(_grip(frame, path, i, move))
		inside.add_child(delete_button("Remove this condition", func() -> void:
			var l := conditions.duplicate(true)
			l.remove_at(index)
			on_change.call(l)))
		frame.add_child(LogicKit.padded(inside, 2, 2))
		r.add_child(frame)
		list.add_child(r)
	var add_row := EntityPanels.row(4)
	var gap := Control.new()
	gap.custom_minimum_size.x = Kit.px(GUTTER)
	add_row.add_child(gap)
	var add := menu_button(add_text, kind["waits"].map(func(p): return str(p[1])))
	add.name = "AddWait"
	var pick := func(k: int, _temporary: bool) -> void:
		var l := conditions.duplicate(true)
		l.append(kind["new_wait"].call(str(kind["waits"][k][0]), "and"))
		on_change.call(l)
	on_pick(add, pick)
	add_row.add_child(add)
	list.add_child(add_row)


static func _name_of(kind: Dictionary, t: String) -> String:
	for p in kind["waits"]:
		if p[0] == t:
			return str(p[1])
	return t.replace("_", " ").capitalize()


## One wait condition in Factorio's words. on_change(condition).
static func condition(screen, w: Dictionary, kind: Dictionary, on_change: Callable) -> Control:
	var r := EntityPanels.row(4)
	var t := str(w.get("type", "time"))
	var set_field := func(key: String, value) -> void:
		var c := w.duplicate(true)
		c[key] = value
		on_change.call(c)
	if t == "time" or t == "inactivity":
		r.add_child(EntityPanels.dark_number_box(int(w.get("ticks", 0)) / 60, func(v: int) -> void: set_field.call("ticks", maxi(0, v) * 60), 56))
		r.add_child(_word("s passed" if t == "time" else "s of inactivity"))
		return r
	r.add_child(_word(str(WAIT_WORDS.get(t, _name_of(kind, t)))))
	if t in EntityPanels.CONDITION_WAITS:
		var cond: Dictionary = (w.get("condition") as Dictionary).duplicate(true) if w.get("condition") is Dictionary else {"comparator": "<", "constant": 0}
		var kinds: Array = ["fluid"] if t == "fluid_count" else (["item", "fluid", "virtual"] if t == "circuit" else ["item"])
		r.add_child(EntityPanels._condition_editor(screen, cond, kinds, func(c: Dictionary) -> void: set_field.call("condition", c)))
	elif t in EntityPanels.STATION_WAITS:
		var names: Array = kind["stops"].duplicate()
		var current := str(w.get("station", ""))
		if current != "" and not names.has(current):
			names.push_front(current)
		var pick := MenuKit.dropdown(names.map(func(n): return [n, n]), current)
		pick.custom_minimum_size.x = Kit.px(140)
		RichText.decorate_items(pick, names)
		pick.item_selected.connect(func(i: int) -> void: set_field.call("station", str(names[i])))
		r.add_child(pick)
	elif t in REQUEST_WAITS:
		var cond: Dictionary = w.get("condition") if w.get("condition") is Dictionary else {}
		var set_item := func(_type: String, item: String) -> void:
			set_field.call("condition", {"name": item, "quality": str(cond.get("quality", "normal"))} if item != "" else {})
		r.add_child(EntityPanels.choose_slot(screen, EntityPanels._signal_name(cond), ["item"], set_item, "Item"))
	elif t == "any_planet_import_zero":
		var planets: Array = kind["stops"].duplicate()
		planets.push_front("")
		var pick := MenuKit.dropdown(planets.map(func(n): return [kind["stop_text"].call(str(n)) if str(n) != "" else "Any planet", n]), str(w.get("planet", "")))
		pick.custom_minimum_size.x = Kit.px(150)
		pick.item_selected.connect(func(k: int) -> void: set_field.call("planet", str(planets[k])))
		r.add_child(pick)
	elif t == "damage_taken":
		r.add_child(EntityPanels.dark_number_box(int(w.get("damage", 0)), func(v: int) -> void: set_field.call("damage", maxi(0, v)), 70))
	return r


## Fits a condition's slots, boxes and dropdowns to its frame (train_schedule_item_select_button,
## and the rest of the row, are 28 high; the windows' own are taller).
static func _compact(node: Node) -> void:
	for c in node.get_children():
		if c is Slot:
			(c as Slot).custom_minimum_size = Kit.pxv(28, 28)
			(c as Slot).icon_px = 24
		elif c is LineEdit or c is OptionButton:
			(c as Control).custom_minimum_size.y = Kit.px(28)
		_compact(c)


static func _word(text: String) -> Label:
	var l := Kit.label(text)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return l


static func add_station(screen, recs: Array, kind: Dictionary, on_change: Callable, can_go: bool, text := "+ Add station") -> Control:
	var stops: Array = kind["stops"]
	var add := menu_button(text, stops.map(func(n): return kind["stop_text"].call(str(n))))
	add.name = "AddStation"
	if kind["stop_icon"].is_valid():
		for i in stops.size():
			add.get_popup().set_item_icon(i, kind["stop_icon"].call(str(stops[i])))
			add.get_popup().set_item_icon_max_width(i, Kit.px(20))
	else:
		RichText.decorate_items(add.get_popup(), stops)
	var temporary_allowed: bool = can_go and kind["temporary"]
	add.tooltip_text = "Control + Left-click: insert a temporary stop" if temporary_allowed else ""
	add.disabled = stops.is_empty()
	var pick := func(k: int, temporary: bool) -> void:
		if k < 0 or k >= stops.size():
			return
		if temporary and temporary_allowed:
			screen.model.train_go_to_station(screen.unit, str(stops[k]))
			return
		var l := recs.duplicate(true)
		l.append(kind["new_record"].call(str(stops[k])))
		on_change.call(l)
	on_pick(add, pick)
	return add


## The "Interrupts (i)" strip, each interrupt's row (open or fold, name, drag, remove), the open
## ones' conditions and targets, and "+ Add interrupt", which asks for a name.
static func interrupts(screen, list: VBoxContainer, all: Array, kind: Dictionary) -> void:
	var strip := LogicKit.subheader()
	(strip[1] as HBoxContainer).add_child(LogicKit.info_label("Interrupts", INTERRUPTS_TIP, "FHeading"))
	list.add_child(strip[0])
	var send := func(l: Array) -> void: screen.model.set_interrupts(screen.unit, l)
	for i in all.size():
		var index := i
		var it: Dictionary = all[i] if all[i] is Dictionary else {}
		var iname := str(it.get("name", ""))
		var open := bool(open_interrupts.get(iname, false))
		var bar := Kit.panel("FShallowFrame")
		bar.custom_minimum_size.y = Kit.px(FRAME_HEIGHT)
		bar.name = "Interrupt%d" % (i + 1)
		var r := EntityPanels.row(4)
		bar.add_child(LogicKit.padded(r, 2, 2))
		var toggle := func() -> void:
			open_interrupts[iname] = not open
			screen._rebuild_now()
		var fold := LogicKit.tool_button("icons/mip/collapse.png" if open else "icons/mip/expand.png", "Collapse" if open else "Expand", toggle, "FDarkButton")
		fold.name = "Fold%d" % (i + 1)
		r.add_child(fold)
		var title := RichText.text_label(iname, "FHeading")
		title.set("vertical_alignment", VERTICAL_ALIGNMENT_CENTER)
		r.add_child(title)
		r.add_child(_grip(bar, "interrupts", i, func(from: int, to: int) -> void: send.call(reorder(all, from, to))))
		r.add_child(delete_button("Remove this interrupt", func() -> void:
			var l := all.duplicate(true)
			l.remove_at(index)
			send.call(l)))
		list.add_child(bar)
		if not open:
			continue
		var edit := func(key: String, value) -> void:
			var l := all.duplicate(true)
			l[index][key] = value
			send.call(l)
		list.add_child(LogicKit.info_label("When:", WHEN_TIP, "FHeading"))
		var conditions: Array = it.get("conditions", []) if it.get("conditions") is Array else []
		waits(screen, list, conditions, kind, func(w: Array) -> void: edit.call("conditions", w), "+ Add interrupt condition", "interrupt:%d:when" % i)
		list.add_child(LogicKit.info_label("Targets", TARGETS_TIP, "FHeading"))
		var targets: Array = it.get("targets", []) if it.get("targets") is Array else []
		var set_targets := func(t: Array) -> void: edit.call("targets", t)
		records(screen, list, targets, 0, kind, false, set_targets, "interrupt:%d:targets" % i)
		list.add_child(add_station(screen, targets, kind, set_targets, false, "+ Add interrupt station"))
		list.add_child(LogicKit.info_checkbox("Allow interrupting other interrupts", INSIDE_TIP, bool(it.get("inside_interrupt", false)),
			func(on: bool) -> void: edit.call("inside_interrupt", on)))
	var field := MenuKit.textbox("", "Name")
	field.visible = false
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.text_submitted.connect(func(t: String) -> void:
		field.release_focus()
		if t.strip_edges() == "":
			return
		var l := all.duplicate(true)
		l.append({"name": t.strip_edges(), "conditions": [], "targets": [], "inside_interrupt": false})
		send.call(l))
	var add := LogicKit.wide_button("+ Add interrupt", func() -> void:
		field.visible = true
		field.grab_focus())
	add.custom_minimum_size.y = Kit.px(36)
	add.name = "AddInterrupt"
	list.add_child(add)
	list.add_child(field)
