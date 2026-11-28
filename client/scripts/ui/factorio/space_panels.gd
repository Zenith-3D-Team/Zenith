extends RefCounted
## Space Age's entity windows for machine_screen.gd, from space.lua's `gui` fields:
##   hub        the space platform hub: the platform's state, its trip and speed, weight,
##              thrusters and their fuel, pause and "provide to other platforms"; its schedule
##              (stations, Factorio's platform wait conditions, interrupts); its requests from
##              planets as logistic sections (item, quality, minimum, maximum, "import from" and
##              the minimum delivery count)
##   silo       a rocket silo: the rocket parts, its status, "send to orbit automatically" and,
##              for each platform in orbit, Launch (to its hub, or its starter pack) and Ride (the
##              character goes up in the rocket, scripts/world/ride.gd)
##   pad        a cargo landing pad: its requests from orbit and its circuit settings
##   collector  an asteroid collector's chunk filters
##   effects    a machine's module and beacon effects (quality among them)
## and quality_row, the quality buttons of recipe pickers and request editors.
## Like entity_panels.gd, each builder takes the screen (unit, model, picker, held_item, _last)
## and returns a Control; changes are sent at once.

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const Slot := preload("res://scripts/ui/factorio/slot.gd")
const MenuKit := preload("res://scripts/menu/menu_kit.gd")
const GuiAssets := preload("res://scripts/ui/factorio/gui_assets.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const EntityPanels := preload("res://scripts/ui/factorio/entity_panels.gd")
const LocaleNames := preload("res://scripts/world/locale_names.gd")
const ProductionPanels := preload("res://scripts/ui/factorio/production_panels.gd")
const LogicKit := preload("res://scripts/ui/factorio/logic_kit.gd")
const ScheduleEditor := preload("res://scripts/ui/factorio/schedule_editor.gd")
const Wire := preload("res://scripts/util/wire.gd")

## Factorio's platform wait conditions (WaitConditionType), in the order its menu lists them.
const PLATFORM_WAITS := [["time", "Time passed"], ["inactivity", "Inactivity"],
	["all_requests_satisfied", "All requests satisfied"], ["any_request_not_satisfied", "Any request not satisfied"],
	["any_request_zero", "Any request zero"], ["request_satisfied", "Request satisfied"],
	["request_not_satisfied", "Request not satisfied"], ["any_planet_import_zero", "Any planet import zero"],
	["item_count", "Item count"], ["fluid_count", "Fluid count"], ["circuit", "Circuit condition"],
	["damage_taken", "Damage taken"]]
const STATES := {
	"waiting_at_station": "Waiting at %s", "on_the_path": "Travelling", "paused": "Paused",
	"no_schedule": "No schedule", "no_path": "No path", "waiting_for_departure": "Waiting for departure",
	"waiting_for_starter_pack": "Waiting for the starter pack", "starter_pack_requested": "Starter pack requested",
	"starter_pack_on_the_way": "Starter pack on the way",
}
## defines.rocket_silo_status in Factorio's words.
const SILO_STATES := {
	"building_rocket": "Building rocket", "create_rocket": "Creating rocket", "lights_blinking_open": "Preparing for launch",
	"doors_opening": "Opening doors", "doors_opened": "Doors opened", "rocket_rising": "Rocket rising",
	"arms_advance": "Arms advancing", "rocket_ready": "Rocket ready", "launch_starting": "Launch starting",
	"engine_starting": "Engine starting", "arms_retract": "Arms retracting", "rocket_flying": "Rocket flying",
	"lights_blinking_close": "Closing", "doors_closing": "Closing doors", "launch_started": "Launch started",
}
const EFFECT_NAMES := [["sp", "Speed"], ["pr", "Productivity"], ["co", "Consumption"], ["po", "Pollution"], ["q", "Quality"]]
const FUEL_COLOR := Color(0.85, 0.55, 0.2)
## How tall the hub's settings are before they scroll (GUI pixels).
const HUB_HEIGHT := 420


## A platform's name with Factorio's rich text ("[planet=vulcanus]") in plain words.
static func plain(name: String) -> String:
	var re := RegEx.create_from_string("\\[(item|planet|space-location|fluid|virtual-signal|entity|recipe)=([^\\],]+)[^\\]]*\\]")
	var out := name
	for m in re.search_all(name):
		var what := m.get_string(2)
		out = out.replace(m.get_string(0), LocaleNames.space_location(what) if m.get_string(1) in ["planet", "space-location"] else Kit.pretty(what))
	return out.strip_edges()


static func place(name: String) -> String:
	return LocaleNames.space_location(name) if name != "" else "?"


static func _dim(text: String) -> Label:
	var l := Kit.label(text)
	l.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	return l


# --- the hub -------------------------------------------------------------------------------------

## The hub window's third column, as Factorio's: the platform (its state, trip, speed, weight,
## thrusters and fuel, pause) and its schedule with interrupts, scrolling when long.
static func hub_platform(screen, h: Dictionary) -> Control:
	var box := EntityPanels.column(10)
	box.add_child(_platform_state(screen, h))
	box.add_child(_schedule(screen, h))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.focus_mode = Control.FOCUS_NONE
	scroll.custom_minimum_size = Vector2(0, Kit.px(HUB_HEIGHT))
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	return scroll


## The hub's "Provide materials to other platforms" box (over its inventory, as in Factorio).
static func provide_box(screen, h: Dictionary) -> Control:
	var unit: int = screen.unit
	var prov := func(on: bool) -> void: Bridge.send({"t": "set_hub", "u": unit, "prov": 1 if on else 0})
	var c := EntityPanels.checkbox("Provide materials to other platforms", int(h.get("prov", 0)) == 1, prov)
	c.tooltip_text = "Other platforms over the same planet can take this hub's items."
	return c


## A landing pad's circuit settings (Factorio puts them in its circuit connection panel).
static func pad_circuit(screen, p: Dictionary) -> Control:
	var box := EntityPanels.column(6)
	var cb: Dictionary = p.get("cb") if p.get("cb") is Dictionary else {}
	var unit: int = screen.unit
	box.add_child(EntityPanels.heading("Circuit connection"))
	for opt in [["read", "Read contents"], ["req", "Set requests"], ["empty", "Read empty slots"]]:
		var key := str(opt[0])
		var on := func(v: bool) -> void: Bridge.send({"t": "set_pad", "u": unit, key: 1 if v else 0})
		box.add_child(EntityPanels.checkbox(str(opt[1]), int(cb.get(key, 0)) == 1, on))
	return box


## The trip, speed, weight, thrusters and fuel; pause. Labels
## that change while travelling are kept in the screen's meta "hub_live" so refresh() updates them
## without rebuilding the window.
static func _platform_state(screen, h: Dictionary) -> Control:
	var box := EntityPanels.column(4)
	var title := EntityPanels.row(8)
	title.add_child(Kit.label(plain(str(h.get("n", "Space platform"))), "FHeading"))
	var state := Kit.label("")
	state.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_child(state)
	var paused := int(h.get("pa", 0)) == 1
	var unit: int = screen.unit
	var pause_btn := EntityPanels.button("Resume" if paused else "Pause",
		func() -> void: Bridge.send({"t": "set_hub", "u": unit, "pa": 0 if paused else 1}), 90)
	title.add_child(pause_btn)
	box.add_child(title)
	var bar := Kit.progress_bar(Kit.BAR_GREEN)
	bar.max_value = 1000
	bar.custom_minimum_size = Kit.pxv(300, 10)
	bar.show_percentage = false
	box.add_child(bar)
	var info := Kit.label("")
	box.add_child(info)
	var fuel_box := EntityPanels.column(2)
	box.add_child(fuel_box)
	screen.set_meta("hub_live", {"state": state, "bar": bar, "info": info, "fuel": fuel_box})
	refresh(screen, {"hub": h})
	return EntityPanels.pane(box)


## Updates the hub's moving parts from a new `gui` (machine_screen.gd calls it every message).
static func refresh(screen, msg: Dictionary) -> void:
	var live = screen.get_meta("hub_live") if screen.has_meta("hub_live") else null
	var h = msg.get("hub")
	if not (live is Dictionary and h is Dictionary and is_instance_valid(live["state"])):
		return
	var st := str(h.get("st", ""))
	var loc := str(h.get("loc", ""))
	var travelling: bool = h.has("to")
	var text: String = STATES.get(st, st.capitalize())
	if st == "waiting_at_station":
		text = text % place(loc)
	elif travelling:
		text = "%s: %s → %s" % [text, place(str(h.get("from", ""))), place(str(h.get("to", "")))]
	elif loc != "":
		text = "%s at %s" % [text, place(loc)]
	(live["state"] as Label).text = text
	var bar: ProgressBar = live["bar"]
	bar.visible = travelling
	bar.value = int(h.get("d", 0))
	var parts: Array = ["Speed %s km/s" % str(snappedf(float(h.get("sp", 0.0)), 0.1))]
	if travelling and h.has("len"):
		var length := int(h["len"])
		parts.append("%s / %s km" % [Kit.count_text(int(length * int(h.get("d", 0)) / 1000.0)), Kit.count_text(length)])
	parts.append("Weight %d t" % roundi(int(h.get("w", 0)) / 1000.0))
	var th := Wire.array(h.get("th"))
	if th.size() >= 2:
		parts.append("Thrusters %d / %d working" % [int(th[1]), int(th[0])])
	(live["info"] as Label).text = " · ".join(parts)
	var fuel_box: VBoxContainer = live["fuel"]
	for c in fuel_box.get_children():
		fuel_box.remove_child(c)
		c.queue_free()
	for f in Wire.array(h.get("fuel")):
		if f is Array and f.size() >= 3:
			var r := EntityPanels.row(8)
			var name := Kit.label(Kit.pretty(str(f[0])))
			name.custom_minimum_size.x = Kit.px(150)
			r.add_child(name)
			var fb := Kit.progress_bar(FUEL_COLOR)
			fb.max_value = maxf(1.0, float(f[2]))
			fb.value = float(f[1])
			fb.custom_minimum_size = Kit.pxv(160, 10)
			fb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			r.add_child(fb)
			r.add_child(Kit.label("%s / %s" % [Kit.count_text(int(f[1])), Kit.count_text(int(f[2]))]))
			fuel_box.add_child(r)


## The platform's schedule: Factorio's list (schedule_editor.gd), stops from the unlocked
## destinations. Sent with the train commands on the hub's unit.
static func _schedule(screen, h: Dictionary) -> Control:
	var box := EntityPanels.column(6)
	box.name = "Schedule"
	var sched: Dictionary = h.get("sched") if h.get("sched") is Dictionary else {}
	var dest := Wire.array(h.get("dest"))
	var head := EntityPanels.row(8)
	head.add_child(EntityPanels.heading("Schedule"))
	if str(sched.get("group", "")) != "":
		head.add_child(_dim("Group: %s" % sched["group"]))
	box.add_child(head)
	var records: Array = Wire.array(sched.get("records")).duplicate(true)
	var unit: int = screen.unit
	var send := func(l: Array) -> void: screen.model.set_schedule(unit, l)
	var kind := _schedule_kind(dest)
	var frame := Kit.panel("FDeepFrame")
	var list := EntityPanels.column(4)
	frame.add_child(LogicKit.padded(list, 4, 4))
	ScheduleEditor.records(screen, list, records, int(sched.get("current", 0)), kind, true, send, "stations")
	list.add_child(ScheduleEditor.add_station(screen, records, kind, send, true))
	ScheduleEditor.interrupts(screen, list, Wire.array(sched.get("interrupts")).duplicate(true), kind)
	box.add_child(frame)
	return box


## What a platform's schedule has where a train's has stations and its conditions.
static func _schedule_kind(dest: Array) -> Dictionary:
	return {"stops": dest, "waits": PLATFORM_WAITS, "new_wait": new_wait, "add_wait": "+ Add fly condition",
		"temporary": false, "unload": true, "stop_text": place, "stop_icon": planet_icon,
		"new_record": func(n: String) -> Dictionary: return {"station": n, "wait_conditions": [{"type": "all_requests_satisfied", "compare_type": "and"}]}}


## A platform wait condition of that type with Factorio's defaults.
static func new_wait(t: String, compare := "and") -> Dictionary:
	var w := {"type": t, "compare_type": compare}
	if t == "time":
		w["ticks"] = 30 * 60
	elif t == "inactivity":
		w["ticks"] = 5 * 60
	elif t in ["item_count", "fluid_count", "circuit"]:
		w["condition"] = {"comparator": "<", "constant": 0}
	elif t == "damage_taken":
		w["damage"] = 1000
	return w


## A planet's (or space location's) icon: the bridge's graphics list (every mod's planets), else
## the player's install, or null.
static func planet_icon(name: String) -> Texture2D:
	if name == "":
		return null
	var listed := ItemIcons.texture_for_kind("space-location", name)
	if listed != null:
		return listed
	for path in ["space-age/graphics/icons/%s.png", "base/graphics/icons/%s.png"]:
		var t := GuiAssets.data_sprite(path % name)
		if t != null:
			return t
	return null


# --- logistic sections (the hub's requests from planets, the pad's from orbit, chests, char) ---

const QUALITY_COMPARATORS := ["=", "≠", "<", "≤", ">", "≥"]
const QUALITY_ORDER := ["normal", "uncommon", "rare", "epic", "legendary"]
const TINT_UNSATISFIED := Color(0.85, 0.18, 0.15, 0.35)
const TINT_ON_WAY := Color(0.95, 0.75, 0.15, 0.35)
const TINT_TRASHING := Color(0.95, 0.45, 0.1, 0.30)
const TINT_SATISFIED := Color(0.2, 0.55, 0.9, 0.22)


static func _normalize_cmp(cmp: String) -> String:
	match cmp:
		"!=", "≠":
			return "≠"
		"<=", "≤":
			return "≤"
		">=", "≥":
			return "≥"
		"<", ">":
			return cmp
	return "="


static func _quality_rank(q: String, qualities: Array) -> int:
	var name := q if q != "" else "normal"
	var idx := qualities.find(name)
	if idx >= 0:
		return idx
	var fallback := QUALITY_ORDER.find(name)
	return fallback if fallback >= 0 else 0


static func _matches_quality(item_q: String, req_q: String, cmp: String, qualities: Array) -> bool:
	var n := _normalize_cmp(cmp)
	var a := _quality_rank(item_q, qualities)
	var b := _quality_rank(req_q, qualities)
	match n:
		"=":
			return a == b
		"≠":
			return a != b
		"<":
			return a < b
		"≤":
			return a <= b
		">":
			return a > b
		"≥":
			return a >= b
	return a == b


static func _sum_matching(counts: Dictionary, item: String, req_q: String, cmp: String, qualities: Array) -> int:
	var total := 0
	var prefix := item + "/"
	for k in counts:
		var key := str(k)
		if key.begins_with(prefix):
			var q := key.substr(prefix.length())
			if _matches_quality(q, req_q, cmp, qualities):
				total += int(counts[k])
	return total


## Builds a fulfillment context (`{"have": ..., "del": ..., "pick": ...}`) from slot dicts and
## transfer arrays `[[item, count, quality?], ...]`.
static func build_status_context(slots: Array, del_list: Array, pick_list: Array) -> Dictionary:
	var have := {}
	for st in slots:
		if st is Dictionary and not (st as Dictionary).is_empty():
			var item := str(st.get("item", ""))
			if item != "":
				var q := str(st.get("quality", "normal"))
				if q == "":
					q = "normal"
				var key := item + "/" + q
				have[key] = int(have.get(key, 0)) + int(st.get("count", 0))
	var del := {}
	for entry in del_list:
		if entry is Array and entry.size() >= 2:
			var q := str(entry[2]) if entry.size() >= 3 and str(entry[2]) != "" else "normal"
			var key := str(entry[0]) + "/" + q
			del[key] = int(del.get(key, 0)) + int(entry[1])
	var pick := {}
	for entry in pick_list:
		if entry is Array and entry.size() >= 2:
			var q := str(entry[2]) if entry.size() >= 3 and str(entry[2]) != "" else "normal"
			var key := str(entry[0]) + "/" + q
			pick[key] = int(pick.get(key, 0)) + int(entry[1])
	return {"have": have, "del": del, "pick": pick}


static func _default_stack_size(screen, item: String) -> int:
	var m = screen.get("model")
	if m != null:
		var pages = m.get("pedia_pages")
		if pages is Dictionary:
			var p = (pages as Dictionary).get("item/" + item)
			if p is Dictionary:
				var d = (p as Dictionary).get("d")
				if d is Dictionary and int((d as Dictionary).get("stack", 0)) > 0:
					return int((d as Dictionary)["stack"])
	return 50


static func _unlocked_qualities(screen) -> Array:
	var last = screen.get("_last")
	var qs := Wire.array(last.get("ql")) if last is Dictionary else []
	if qs.size() > 1:
		return qs
	var m = screen.get("model")
	if m != null:
		var pl = m.get("planners")
		if pl != null and pl.has_method("unlocked_qualities"):
			var uq: Array = pl.unlocked_qualities()
			if not uq.is_empty():
				return uq
	return qs


## Factorio's logistic sections: each with its group name, an on/off box, the multiplier, and its
## request slots (the minimum as the count, the quality's icon, optional max and fulfillment tint).
## Click a slot to edit its item, quality, comparator, minimum, maximum and, on a hub, "import from"
## and the minimum delivery count; right click removes it; an empty slot adds the held item or one
## from the chooser. Non-manual sections (`man == 0`) render their live requests read-only.
static func sections(screen, secs: Array, dest: Array, hub_like: bool, status_ctx := {}) -> Control:
	var box := EntityPanels.column(6)
	box.add_child(EntityPanels.heading("Requests from planets" if hub_like else "Requests"))
	var qualities := _unlocked_qualities(screen)
	var slots := func(sec: Dictionary, filters: Array, send: Callable) -> Control:
		var editable := send.is_valid() and int(sec.get("man", 1)) == 1
		var mult := float(sec.get("m", 1.0))
		var sec_on := int(sec.get("on", 1)) == 1
		if not editable and filters.is_empty():
			return _dim("No active requests (set automatically)")
		return _request_slots(screen, filters, dest, qualities, hub_like, send, Kit.COLUMNS, editable, status_ctx, mult, sec_on)
	box.add_child(ProductionPanels.sections(screen, secs, slots))
	return box


static func _request_slots(screen, filters: Array, dest: Array, qualities: Array, hub_like: bool, on_change: Callable,
		columns := EntityPanels.PANE_COLUMNS, editable := true, status_ctx := {}, mult := 1.0, sec_on := true) -> Control:
	var box := EntityPanels.column(4)
	var frame := Kit.panel("FDeepFrame")
	frame.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var grid := Kit.slot_grid(columns)
	frame.add_child(grid)
	var editor := EntityPanels.column(4)
	editor.visible = false
	var extra_cell := 1 if editable else 0
	var cells := maxi(columns, ceili((filters.size() + extra_cell) / float(columns)) * columns)
	var have_map: Dictionary = status_ctx.get("have", {}) if status_ctx.get("have") is Dictionary else {}
	var del_map: Dictionary = status_ctx.get("del", {}) if status_ctx.get("del") is Dictionary else {}
	var pick_map: Dictionary = status_ctx.get("pick", {}) if status_ctx.get("pick") is Dictionary else {}
	var has_status := not status_ctx.is_empty() and sec_on
	for i in cells:
		var index := i
		var s := Slot.new()
		s.theme_type_variation = "FSlotButton" if editable else "FSlot"
		if i < filters.size() and filters[i] is Array and (filters[i] as Array).size() >= 6:
			var f: Array = filters[i]
			var item_name := str(f[0])
			var q := str(f[1]) if str(f[1]) != "" else "normal"
			var min_raw := int(f[2])
			var max_raw := int(f[3])
			var cmp := _normalize_cmp(str(f[6])) if f.size() >= 7 else "="
			var eff_min := roundi(float(min_raw) * mult)
			var eff_max := roundi(float(max_raw) * mult) if max_raw >= 0 else -1
			s.set_stack(item_name, min_raw)
			s.set_extra({"quality": q})
			var tint := Color(0, 0, 0, 0)
			var lines: Array = []
			var min_str := str(min_raw) if is_equal_approx(mult, 1.0) else "%d (×%s = %d)" % [min_raw, ProductionPanels._num(mult), eff_min]
			var max_str := "∞" if max_raw < 0 else (str(max_raw) if is_equal_approx(mult, 1.0) else "%d (×%s = %d)" % [max_raw, ProductionPanels._num(mult), eff_max])
			lines.append(["Requested: %s – %s" % [min_str, max_str]])
			if cmp != "=":
				lines.append(["Quality filter: %s %s" % [cmp, q.capitalize()]])
			if has_status:
				var have := _sum_matching(have_map, item_name, q, cmp, qualities)
				var incoming := _sum_matching(del_map, item_name, q, cmp, qualities)
				var outgoing := _sum_matching(pick_map, item_name, q, cmp, qualities)
				lines.append(["In inventory: %d" % have])
				if incoming > 0:
					lines.append(["On the way: +%d" % incoming, "", Color(0.95, 0.8, 0.25)])
				if outgoing > 0:
					lines.append(["Scheduled pickup: -%d" % outgoing, "", Color(0.95, 0.55, 0.2)])
				if eff_min == 0 and eff_max == 0 and (have > 0 or outgoing > 0):
					tint = TINT_TRASHING
				elif eff_max >= 0 and have > eff_max:
					tint = TINT_TRASHING
				elif have < eff_min:
					tint = TINT_ON_WAY if have + incoming >= eff_min else TINT_UNSATISFIED
				else:
					tint = TINT_SATISFIED
			s.set_logistic_state(max_raw, tint, cmp)
			if hub_like:
				lines.append(["Import from: %s" % (place(str(f[4])) if str(f[4]) != "" else "any planet")])
				if int(f[5]) >= 0:
					lines.append(["Minimum delivery: %d" % int(f[5])])
			if editable:
				lines.append(["Click: change · Right click: remove", "", Kit.DISABLED_TEXT])
			else:
				lines.append(["Set automatically (read-only)", "", Kit.DISABLED_TEXT])
			s.set_tip(Kit.pretty(item_name), Slot.extra_lines({"quality": q}) + lines)
		elif editable:
			s.set_tip("Add a request", [["Click: choose an item (or the one held)", "", Kit.DISABLED_TEXT]])
		else:
			s.disabled = true
		if editable:
			var on_click := func(button_index: int, _shift: bool) -> void:
				if index < filters.size():
					if button_index == MOUSE_BUTTON_RIGHT:
						var l := filters.duplicate(true)
						l.remove_at(index)
						on_change.call(l)
					elif button_index == MOUSE_BUTTON_LEFT:
						_edit_request(screen, editor, filters, index, dest, qualities, hub_like, on_change)
				elif button_index == MOUSE_BUTTON_LEFT:
					var add := func(_type: String, item: String) -> void:
						if item != "":
							var l := filters.duplicate(true)
							var def_count := _default_stack_size(screen, item)
							l.append([item, "normal", def_count, -1, "", -1])
							on_change.call(l)
					var held: String = screen.held_item.call() if screen.get("held_item") is Callable and screen.held_item.is_valid() else ""
					if held != "":
						add.call("item", held)
					elif screen.get("picker") != null:
						screen.picker.choose(["item"], add)
			s.clicked.connect(on_click)
		grid.add_child(s)
	box.add_child(frame)
	if editable:
		box.add_child(editor)
	return box


## One request's editor under the slots: swap item, quality + comparator, min/max sliders & boxes,
## infinite max checkbox, quick auto-trash (0-0), and on a hub import from + minimum delivery count.
static func _edit_request(screen, editor: VBoxContainer, filters: Array, index: int, dest: Array, qualities: Array, hub_like: bool, on_change: Callable) -> void:
	for c in editor.get_children():
		editor.remove_child(c)
		c.queue_free()
	editor.name = "RequestEditor"
	editor.visible = true
	var f: Array = (filters[index] as Array).duplicate()
	while f.size() < 6:
		f.append(-1 if f.size() == 3 or f.size() == 5 else "")
	var stack_sz := _default_stack_size(screen, str(f[0]))
	var top := EntityPanels.row(8)
	var item_btn := Slot.new()
	item_btn.theme_type_variation = "FSlotButton"
	item_btn.set_stack(str(f[0]), -1)
	item_btn.set_tip(Kit.pretty(str(f[0])), [["Click to change item", "", Kit.DISABLED_TEXT]])
	var title := Kit.label(Kit.pretty(str(f[0])), "FHeading")
	var on_swap := func(button_index: int, _shift: bool) -> void:
		if button_index == MOUSE_BUTTON_LEFT and screen.get("picker") != null:
			var picked := func(_t: String, item: String) -> void:
				if item != "":
					f[0] = item
					item_btn.set_stack(item, -1)
					title.text = Kit.pretty(item)
			screen.picker.choose(["item"], picked)
	item_btn.clicked.connect(on_swap)
	top.add_child(item_btn)
	top.add_child(title)
	editor.add_child(top)
	var cmp_state := [_normalize_cmp(str(f[6])) if f.size() >= 7 else "="]
	if qualities.size() > 1:
		var qrow := EntityPanels.row(6)
		var cmp_pick := MenuKit.dropdown(QUALITY_COMPARATORS.map(func(c): return [c, c]), str(cmp_state[0]))
		cmp_pick.name = "QualityComparator"
		cmp_pick.custom_minimum_size.x = Kit.px(52)
		var cmp_changed := func(sel: int) -> void:
			cmp_state[0] = QUALITY_COMPARATORS[sel]
		cmp_pick.item_selected.connect(cmp_changed)
		qrow.add_child(cmp_pick)
		var set_q := func(q: String) -> void: f[1] = q
		qrow.add_child(quality_row(qualities, str(f[1]) if str(f[1]) != "" else "normal", set_q))
		editor.add_child(qrow)
	var cur_min := maxi(0, int(f[2]))
	var cur_max := int(f[3])
	var slider_cap := maxi(stack_sz * 10, maxi(cur_min * 2, cur_max * 2))
	var min_row := EntityPanels.row(6)
	min_row.add_child(Kit.label("Min"))
	var min_slider := MenuKit.slider(0, slider_cap, 1, cur_min)
	min_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var min_box := MenuKit.textbox(str(cur_min), "Min")
	min_box.name = "MinBox"
	min_box.custom_minimum_size.x = Kit.px(70)
	var on_min_slide := func(v: float) -> void:
		min_box.text = str(int(v))
	min_slider.value_changed.connect(on_min_slide)
	var on_min_text := func(t: String) -> void:
		if t.strip_edges().is_valid_int():
			var v := maxi(0, int(t.strip_edges()))
			if float(v) > min_slider.max_value:
				min_slider.max_value = float(v)
			min_slider.set_value_no_signal(float(v))
	min_box.text_changed.connect(on_min_text)
	min_row.add_child(min_slider)
	min_row.add_child(min_box)
	editor.add_child(min_row)
	var max_row := EntityPanels.row(6)
	max_row.add_child(Kit.label("Max"))
	var inf_box := MenuKit.checkbox("∞", cur_max < 0)
	inf_box.name = "MaxInf"
	var max_slider := MenuKit.slider(0, slider_cap, 1, maxi(cur_min, cur_max) if cur_max >= 0 else cur_min)
	max_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var max_box := MenuKit.textbox("" if cur_max < 0 else str(cur_max), "∞")
	max_box.name = "MaxBox"
	max_box.custom_minimum_size.x = Kit.px(70)
	var sync_inf := func(is_inf: bool) -> void:
		max_slider.editable = not is_inf
		max_box.editable = not is_inf
		if is_inf:
			max_box.text = ""
		elif not max_box.text.strip_edges().is_valid_int():
			var mv := maxi(0, int(min_box.text) if min_box.text.is_valid_int() else cur_min)
			max_box.text = str(mv)
			max_slider.set_value_no_signal(float(mv))
	inf_box.toggled.connect(sync_inf)
	sync_inf.call(cur_max < 0)
	var on_max_slide := func(v: float) -> void:
		if not inf_box.button_pressed:
			max_box.text = str(int(v))
	max_slider.value_changed.connect(on_max_slide)
	var on_max_text := func(t: String) -> void:
		if t.strip_edges().is_valid_int():
			var v := maxi(0, int(t.strip_edges()))
			if float(v) > max_slider.max_value:
				max_slider.max_value = float(v)
			max_slider.set_value_no_signal(float(v))
	max_box.text_changed.connect(on_max_text)
	max_row.add_child(max_slider)
	max_row.add_child(max_box)
	max_row.add_child(inf_box)
	editor.add_child(max_row)
	var from_pick: OptionButton = null
	var mdc_box: LineEdit = null
	if hub_like:
		var r2 := EntityPanels.row(6)
		var places: Array = dest.duplicate()
		places.push_front("")
		from_pick = MenuKit.dropdown(places.map(func(n): return [place(str(n)) if str(n) != "" else "Any planet", n]), str(f[4]))
		from_pick.custom_minimum_size.x = Kit.px(150)
		r2.add_child(Kit.label("Import from"))
		r2.add_child(from_pick)
		mdc_box = MenuKit.textbox("" if int(f[5]) < 0 else str(int(f[5])), "Default")
		mdc_box.custom_minimum_size.x = Kit.px(80)
		r2.add_child(Kit.label("Minimum delivery"))
		r2.add_child(mdc_box)
		editor.add_child(r2)
	var commit := func(_t := "") -> void:
		if min_box.text.strip_edges().is_valid_int():
			f[2] = maxi(0, int(min_box.text.strip_edges()))
		if inf_box.button_pressed or not max_box.text.strip_edges().is_valid_int():
			f[3] = -1
		else:
			f[3] = maxi(int(f[2]), int(max_box.text.strip_edges()))
		if from_pick != null and from_pick.selected >= 0:
			f[4] = str(from_pick.get_item_metadata(from_pick.selected))
		if mdc_box != null:
			f[5] = int(mdc_box.text.strip_edges()) if mdc_box.text.strip_edges().is_valid_int() else -1
		var chosen_cmp := str(cmp_state[0])
		if chosen_cmp != "=":
			if f.size() < 7:
				f.append(chosen_cmp)
			else:
				f[6] = chosen_cmp
		elif f.size() >= 7:
			f.resize(6)
		var l := filters.duplicate(true)
		l[index] = f
		editor.visible = false
		on_change.call(l)
	min_box.text_submitted.connect(commit)
	max_box.text_submitted.connect(commit)
	var btns := EntityPanels.row(6)
	var set_btn := EntityPanels.button("Set", func() -> void: commit.call(), 60)
	set_btn.theme_type_variation = "FGreenButton"
	btns.add_child(set_btn)
	var trash_zero := func() -> void:
		min_box.text = "0"
		inf_box.button_pressed = false
		max_box.text = "0"
		commit.call()
	btns.add_child(EntityPanels.button("Auto-trash (0–0)", trash_zero, 120))
	editor.add_child(btns)


## Quality buttons (each quality's icon), the chosen one pressed; on_pick(quality) gets a choice.
static func quality_row(qualities: Array, current: String, on_pick: Callable) -> Control:
	var r := EntityPanels.row(2)
	r.add_child(Kit.label("Quality"))
	var group := ButtonGroup.new()
	for q in qualities:
		var name := str(q)
		var b := Button.new()
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.button_pressed = name == current
		b.custom_minimum_size = Kit.pxv(32, 32)
		b.expand_icon = true
		b.icon = Slot.quality_icon(name)
		if b.icon == null:
			b.text = name.substr(0, 1).to_upper()
		b.tooltip_text = name.capitalize()
		b.pressed.connect(func() -> void: on_pick.call(name))
		r.add_child(b)
	return r


# --- silo, landing pad, collector, effects ---------------------------------------------------

## gui.rk: {parts, need, st, auto, to: [[platform, name, state], ...]}.
static func silo(screen, rk: Dictionary) -> Control:
	var box := EntityPanels.column(6)
	var parts := int(rk.get("parts", 0))
	var need := maxi(1, int(rk.get("need", 1)))
	var st := str(rk.get("st", ""))
	var head := EntityPanels.row(12)
	head.add_child(Kit.label("Rocket parts: %d / %d" % [parts, need]))
	if st != "":
		head.add_child(_dim(SILO_STATES.get(st, st.capitalize())))
	box.add_child(head)
	var unit: int = screen.unit
	var auto := func(on: bool) -> void: Bridge.send({"t": "set_silo", "u": unit, "auto": 1 if on else 0})
	box.add_child(EntityPanels.checkbox("Send to orbit automatically", int(rk.get("auto", 0)) == 1, auto))
	var to := Wire.array(rk.get("to"))
	box.add_child(EntityPanels.heading("Launch to"))
	if to.is_empty():
		box.add_child(_dim("No platform in orbit here"))
	var ready := st == "rocket_ready"
	for t in to:
		if not (t is Array and t.size() >= 3):
			continue
		var r := EntityPanels.row(8)
		var name := Kit.label(plain(str(t[1])))
		name.custom_minimum_size.x = Kit.px(180)
		r.add_child(name)
		var waiting := str(t[2]) in ["waiting_for_starter_pack", "starter_pack_requested"]
		r.add_child(_dim("waiting for its starter pack" if waiting else STATES.get(str(t[2]), str(t[2])).replace(" at %s", "")))
		var index := int(t[0])
		var b := EntityPanels.button("Launch", func() -> void: Bridge.send({"t": "silo_launch", "u": unit, "to": index}), 90)
		b.theme_type_variation = "FGreenButton"
		b.disabled = not ready
		b.tooltip_text = "Launch the rocket to %s" % str(t[1]) if ready else "The rocket isn't ready"
		r.add_child(b)
		# Riding up: the character gets into the rocket and goes to the platform's hub (#10).
		var go_up := func() -> void:
			Bridge.send({"t": "ride", "u": unit, "to": index})
			screen.close()
		var ride := EntityPanels.button("Ride", go_up, 70)
		ride.name = "Ride%d" % index
		ride.theme_type_variation = "FGreenButton"
		ride.disabled = not ready or waiting
		ride.tooltip_text = ("Ride the rocket up to %s's hub" % plain(str(t[1])) if ready and not waiting
			else ("The platform has no hub yet" if waiting else "The rocket isn't ready"))
		r.add_child(ride)
		box.add_child(r)
	return box


## gui.col: {n, f: [chunk or ""]}. Click a filter: the next asteroid chunk; right click clears it.
static func collector(screen, col: Dictionary) -> Control:
	var box := EntityPanels.column(6)
	box.add_child(EntityPanels.heading("Asteroid chunk filter"))
	var n := int(col.get("n", 0))
	var filters: Array = Wire.array(col.get("f")).duplicate()
	while filters.size() < n:
		filters.append("")
	var chunks := _chunk_names(screen)
	var unit: int = screen.unit
	var r := EntityPanels.row(4)
	for i in n:
		var index := i
		var s := Slot.new()
		s.theme_type_variation = "FSlotButton"
		s.set_stack(str(filters[i]), -1)
		s.set_tip(Kit.pretty(str(filters[i])) if str(filters[i]) != "" else "No filter",
			[["Click: the next asteroid chunk · Right click: clear", "", Kit.DISABLED_TEXT]])
		var on_click := func(button_index: int, _shift: bool) -> void:
			var l := filters.duplicate()
			if button_index == MOUSE_BUTTON_RIGHT or chunks.is_empty():
				l[index] = ""
			else:
				var at := chunks.find(str(l[index]))
				l[index] = chunks[(at + 1) % chunks.size()]
			Bridge.send({"t": "set_collector", "u": unit, "f": l})
		s.clicked.connect(on_click)
		r.add_child(s)
	box.add_child(r)
	r.tooltip_text = "Collects only these chunks (none set: any)"
	return box


## Asteroid chunks the game knows (items named *-asteroid-chunk).
static func _chunk_names(screen) -> Array:
	var out: Array = []
	var protos = screen.protos
	if protos != null:
		for name in protos.item_names.values():
			if str(name).ends_with("-asteroid-chunk"):
				out.append(str(name))
	if out.is_empty():
		out = ["metallic-asteroid-chunk", "carbonic-asteroid-chunk", "oxide-asteroid-chunk"]
	out.sort()
	return out


## gui.eff: the machine's effects, Factorio's "+20% speed" lines, in thousandths.
static func effects(eff: Dictionary) -> Control:
	var r := EntityPanels.row(14)
	r.add_child(EntityPanels.heading("Effects"))
	for e in EFFECT_NAMES:
		if eff.has(e[0]):
			var v := int(eff[e[0]]) / 10.0
			var l := Kit.label("%s %s%s%%" % [e[1], "+" if v > 0 else "", str(snappedf(v, 0.1))])
			var good := v > 0 if e[0] in ["sp", "pr", "q"] else v < 0
			l.add_theme_color_override("font_color", Kit.GREEN_TEXT if good else Kit.RED_TEXT)
			r.add_child(l)
	return r
