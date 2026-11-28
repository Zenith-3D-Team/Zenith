extends Control
## Factorio's logistic networks window (L): every logistic network of the force down the left, by
## surface, with its robots; the selected network on the right: its logistic and construction
## robots (available / all), its members, contents, requests and items in transit, rename, search,
## and locate-on-map cycling. As in Factorio 2.1 it lives in the remote view: opening it (and
## choosing a network) looks at the network (show_at; factorio_ui.gd keeps the remote view open while
## this is, and its frame's close closes both). From the mod's `lnets`, `lnet`, and `lnet_locs`.

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const UiModel := preload("res://scripts/ui/factorio/ui_model.gd")
const Slot := preload("res://scripts/ui/factorio/slot.gd")
const RichText := preload("res://scripts/ui/factorio/rich_text.gd")
const MenuKit := preload("res://scripts/menu/menu_kit.gd")
const GuiAssets := preload("res://scripts/ui/factorio/gui_assets.gd")
const LogicKit := preload("res://scripts/ui/factorio/logic_kit.gd")

signal close_requested
## Look at a position (tiles) on a surface (its index).
signal show_at(at: Vector2, si: int)

const REFRESH := 2.0
const LIST_WIDTH := 290
## The member and item grids' width (slots), as Factorio's.
const COLUMNS := 6
const TINT_MISSING := Color(0.85, 0.22, 0.14, 0.42)
const TABS := ["Contents", "Requests", "In transit"]

var model: UiModel
var selected := 0

var _list := VBoxContainer.new()
var _details := VBoxContainer.new()
var _items := GridContainer.new()
var _members_grid := Kit.slot_grid(COLUMNS)
var _right_frame: PanelContainer
var _timer := 0.0
var _sig := ""
## The two frames side by side, at the top left under the remote view's title bar.
var _frames_row := HBoxContainer.new()

var _title_label: Label
var _rename_field: LineEdit
var _rename_btn: Button
var _look_btn: Button
var _charging_label: Label
var _search_box: LineEdit
var _tab := "Contents"
var _tab_buttons := {}
var _search_text := ""
var _renaming := false
var _pending_select := 0

var _cycle_bar := HBoxContainer.new()
var _prev_btn: Button
var _next_btn: Button
var _cycle_label: Label
var _locs: Array = []
var _locs_si := 0
var _loc_index := 0


## Puts the frames' top at `y` (screen pixels) when that is under the title bar's: under anything of
## Zenith's in the top left corner (factorio_ui.gd's Show in Factorio button). 0: right under it.
func set_top(y: float) -> void:
	_frames_row.position.y = maxf(Kit.px(40), y)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = MenuKit.theme()
	visible = false
	# Factorio 2.1 draws two frames at the top left of the screen (in its remote view): the list,
	# and the selected network beside it.
	var row := _frames_row
	row.add_theme_constant_override("separation", Kit.px(4))
	row.position = Kit.pxv(12, 40)  # under the remote view's title bar, as Factorio's
	add_child(row)
	var left_frame := Kit.panel("FFrame")
	left_frame.mouse_filter = Control.MOUSE_FILTER_STOP
	left_frame.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(left_frame)
	var lbox := VBoxContainer.new()
	lbox.add_theme_constant_override("separation", Kit.px(6))
	left_frame.add_child(lbox)
	# No close of its own: the remote view's title bar closes it.
	var bar := Kit.title_bar("Logistic networks", false)
	(bar.get_child(1) as Control).visible = false
	lbox.add_child(bar)
	var left := Kit.panel("FDeepFrame")
	lbox.add_child(left)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Kit.pxv(LIST_WIDTH, 560)
	left.add_child(scroll)
	_list.add_theme_constant_override("separation", 0)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)

	_right_frame = Kit.panel("FFrame")
	_right_frame.mouse_filter = Control.MOUSE_FILTER_STOP
	_right_frame.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_right_frame.visible = false
	row.add_child(_right_frame)
	_details.add_theme_constant_override("separation", Kit.px(6))
	_right_frame.add_child(_details)
	_build_right_panel()

	var on_lnets := func() -> void:
		_pending_select = 0
		_refresh()
	model.lnets_changed.connect(on_lnets)
	var got := func(id: int) -> void:
		if id == selected:
			_refresh_details()
	model.lnet_received.connect(got)
	model.lnet_locs_received.connect(_on_locs)


func _build_right_panel() -> void:
	var bar := Kit.title_bar("", false)
	_title_label = bar.get_child(0) as Label
	_rename_field = MenuKit.textbox("", "Network name")
	_rename_field.name = "RenameField"
	_rename_field.visible = false
	_rename_field.custom_minimum_size = Kit.pxv(140, 22)
	_rename_field.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var on_rename_submit := func(text: String) -> void:
		_commit_rename(text)
	_rename_field.text_submitted.connect(on_rename_submit)
	var on_rename_input := func(event: InputEvent) -> void:
		var k := event as InputEventKey
		if k != null and k.pressed and k.keycode == KEY_ESCAPE:
			_set_renaming(false)
			_rename_field.accept_event()
	_rename_field.gui_input.connect(on_rename_input)
	bar.add_child(_rename_field)
	bar.move_child(_rename_field, 1)

	var on_rename_press := func() -> void:
		if _renaming:
			_set_renaming(false)
		else:
			_start_rename()
	_rename_btn = LogicKit.rename_button("Rename", on_rename_press)
	_rename_btn.name = "Rename"
	bar.add_child(_rename_btn)
	bar.move_child(_rename_btn, 2)

	_look_btn = Kit.close_button()
	_look_btn.name = "LookAtIt"
	_look_btn.tooltip_text = "Look at it"
	var go := GuiAssets.core_sprite("icons/mip/center.png")
	if go != null:
		_look_btn.icon = go
	_look_btn.pressed.connect(_look)
	bar.add_child(_look_btn)
	_details.add_child(bar)

	_details.add_child(_subheader("Members"))
	_charging_label = Kit.label("")
	_charging_label.name = "ChargingLabel"
	_charging_label.visible = false
	_charging_label.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	_details.add_child(_charging_label)

	var mframe := Kit.panel("FDeepFrame")
	mframe.add_child(_members_grid)
	_details.add_child(mframe)

	var tabs_row := HBoxContainer.new()
	tabs_row.add_theme_constant_override("separation", 0)
	for t in TABS:
		var b := Button.new()
		b.text = t
		b.name = "TransitTab" if t == "In transit" else t + "Tab"
		b.theme_type_variation = "FTab"
		b.toggle_mode = true
		b.button_pressed = t == _tab
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Kit.pxv(0, 26)
		b.add_theme_font_override("font", Kit.font("bold"))
		var tab_name: String = t
		var pick_tab := func() -> void:
			_show_tab(tab_name)
		b.pressed.connect(pick_tab)
		tabs_row.add_child(b)
		_tab_buttons[t] = b
	_details.add_child(tabs_row)

	_search_box = MenuKit.textbox("", "Search (Ctrl+F)")
	_search_box.name = "SearchBox"
	_search_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_box.custom_minimum_size = Kit.pxv(0, 24)
	var on_search_changed := func(new_text: String) -> void:
		_search_text = new_text.strip_edges().to_lower()
		_refresh_items()
	_search_box.text_changed.connect(on_search_changed)
	var on_search_input := func(event: InputEvent) -> void:
		var k := event as InputEventKey
		if k != null and k.pressed and k.keycode == KEY_ESCAPE:
			_search_box.release_focus()
			_search_box.accept_event()
	_search_box.gui_input.connect(on_search_input)
	_details.add_child(_search_box)

	_items.columns = COLUMNS
	_items.add_theme_constant_override("h_separation", 0)
	_items.add_theme_constant_override("v_separation", 0)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.focus_mode = Control.FOCUS_NONE
	scroll.custom_minimum_size = Vector2(Kit.px(Kit.SLOT * COLUMNS + 12), Kit.px(Kit.SLOT * 10))
	var deep := Kit.panel("FDeepFrame")
	deep.add_child(scroll)
	_details.add_child(deep)
	scroll.add_child(_items)

	_cycle_bar.name = "LocateBar"
	_cycle_bar.visible = false
	_cycle_bar.add_theme_constant_override("separation", Kit.px(6))
	_prev_btn = MenuKit.button("<")
	_prev_btn.name = "LocPrev"
	_prev_btn.tooltip_text = "Previous match"
	_prev_btn.custom_minimum_size = Kit.pxv(28, 24)
	_prev_btn.pressed.connect(func() -> void: _step_loc(-1))
	_cycle_bar.add_child(_prev_btn)
	_cycle_label = Kit.label("")
	_cycle_label.name = "LocCount"
	_cycle_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cycle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cycle_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_cycle_bar.add_child(_cycle_label)
	_next_btn = MenuKit.button(">")
	_next_btn.name = "LocNext"
	_next_btn.tooltip_text = "Next match"
	_next_btn.custom_minimum_size = Kit.pxv(28, 24)
	_next_btn.pressed.connect(func() -> void: _step_loc(1))
	_cycle_bar.add_child(_next_btn)
	_details.add_child(_cycle_bar)


func is_open() -> bool:
	return visible


func _reset_browse_state() -> void:
	_set_renaming(false)
	_clear_locs()
	_search_text = ""
	if _search_box != null:
		_search_box.text = ""
	_tab = "Contents"
	for t in _tab_buttons:
		(_tab_buttons[t] as Button).button_pressed = (str(t) == _tab)


func open(on: bool) -> void:
	visible = on
	if on:
		_timer = 0.0
		_sig = ""
		_refresh()
		_look()
	else:
		_reset_browse_state()


## Opens the window directly on network `id`, requests its data, and looks at it.
func open_network(id: int) -> void:
	selected = id
	_pending_select = id
	_reset_browse_state()
	visible = true
	_timer = REFRESH
	_sig = ""
	model.request_lnets()
	if selected != 0:
		model.request_lnet(selected)
	_refresh()
	_look()


func toggle() -> void:
	open(not visible)


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if visible and k != null and k.pressed and not k.echo and k.ctrl_pressed and k.keycode == KEY_F:
		if _right_frame != null and _right_frame.visible and _search_box != null:
			_search_box.grab_focus()
			_search_box.select_all()
			get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not visible:
		return
	_timer -= delta
	if _timer <= 0.0:
		_timer = REFRESH
		model.request_lnets()
		if selected != 0:
			model.request_lnet(selected)


func _refresh() -> void:
	if not is_inside_tree():
		return
	var ids: Array = model.lnets.map(func(n) -> int: return int(n["id"]))
	if (selected == 0 or (not ids.has(selected) and selected != _pending_select)) and not ids.is_empty():
		selected = int(ids[0])
		model.request_lnet(selected)
		_look()
	var sig := JSON.stringify(model.lnets) + str(selected)
	if sig != _sig:
		_sig = sig
		_clear_children(_list)
		if model.lnets.is_empty():
			var none := Kit.label("No logistic networks present.")
			none.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
			_list.add_child(none)
		var surface := ""
		for n in model.lnets:
			if str(n["surface"]) != surface:
				surface = str(n["surface"])
				var head := Kit.panel("FSubheader")
				head.add_child(Kit.label(Kit.pretty(surface), "FHeading"))
				_list.add_child(head)
			_list.add_child(_row(n))
	_refresh_details()


## One network in the list: the roboport's icon, its name (or number) and its robots on the right.
func _row(n: Dictionary) -> Button:
	var b := Button.new()
	var id := int(n["id"])
	b.name = "Net%d" % id
	b.theme_type_variation = "FListItemSelected" if id == selected else "FListItem"
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.icon = Kit.item_icon("roboport")
	b.expand_icon = false
	b.add_theme_constant_override("icon_max_width", Kit.px(20))
	var log_robots: Array = n["logistic"]
	var con: Array = n["construction"]
	var name := _name_of(n)
	b.text = name
	b.tooltip_text = "%s\nLogistic robots: %d available of %d\nConstruction robots: %d available of %d\n%d roboport cells" % [
		name, int(log_robots[0]), int(log_robots[1]), int(con[0]), int(con[1]), int(n["cells"])]
	b.custom_minimum_size = Kit.pxv(LIST_WIDTH - 12, 28)
	var count := Kit.label(str(int(log_robots[1]) + int(con[1])))
	count.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	count.offset_left = -Kit.px(60)
	count.offset_right = -Kit.px(8)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if id == selected:
		count.add_theme_color_override("font_color", Kit.BLACK)
	b.add_child(count)
	var pick := func() -> void:
		if selected != id:
			_set_renaming(false)
			_clear_locs()
		selected = id
		_pending_select = 0
		_sig = ""
		model.request_lnet(id)
		_refresh()
		_look()
	b.pressed.connect(pick)
	return b


## Looks at the selected network (one of its roboports) in the remote view.
func _look() -> void:
	var n := _network(selected)
	if not n.is_empty() and int(n["cells"]) > 0:
		show_at.emit(n["position"], int(n["si"]))


func _name_of(n: Dictionary) -> String:
	return RichText.plain(str(n["name"])) if str(n["name"]) != "" else "Network #%d" % int(n["id"])


func _network(id: int) -> Dictionary:
	for n in model.lnets:
		if int(n["id"]) == id:
			return n
	return {}


func _start_rename() -> void:
	var n := _network(selected)
	if n.is_empty():
		return
	_rename_field.text = str(n["name"])
	_set_renaming(true)
	_rename_field.grab_focus()
	_rename_field.select_all()


func _set_renaming(on: bool) -> void:
	_renaming = on
	if _title_label != null:
		_title_label.visible = not on
	if _rename_field != null:
		_rename_field.visible = on
		if not on and _rename_field.has_focus():
			_rename_field.release_focus()


func _commit_rename(text: String) -> void:
	if selected != 0:
		model.set_lnet_name(selected, text.strip_edges())
	_set_renaming(false)


func _show_tab(tab_name: String) -> void:
	_tab = tab_name
	for t in _tab_buttons:
		(_tab_buttons[t] as Button).set_pressed_no_signal(t == tab_name)
	_refresh_items()


func _refresh_details() -> void:
	if _right_frame == null:
		return
	var n := _network(selected)
	_right_frame.visible = not n.is_empty()
	if n.is_empty():
		return
	_title_label.text = _name_of(n)
	if not _renaming:
		_title_label.visible = true
		_rename_field.visible = false
	_look_btn.disabled = int(n["cells"]) == 0

	var contents: Dictionary = model.lnet.get(selected, {})
	var ch: Array = contents.get("ch", [])
	var ch_cur := int(ch[0]) if ch.size() >= 1 else 0
	var ch_wait := int(ch[1]) if ch.size() >= 2 else 0
	if ch.size() >= 2:
		_charging_label.text = "Charging: %d, waiting: %d" % [ch_cur, ch_wait]
		_charging_label.visible = true
	else:
		_charging_label.visible = false

	_clear_children(_members_grid)
	var log_robots: Array = n["logistic"]
	var con: Array = n["construction"]
	var robot_rows: Array = [
		["logistic-robot", int(log_robots[1]), "Logistic robots: %d / %d available" % [int(log_robots[0]), int(log_robots[1])]],
		["construction-robot", int(con[1]), "Construction robots: %d / %d available" % [int(con[0]), int(con[1])]],
	]
	for rm in robot_rows:
		var rproto := str(rm[0])
		var rcnt := int(rm[1])
		if rcnt <= 0:
			continue
		var rs := Slot.new()
		rs.name = "Member_" + rproto
		rs.set_stack(rproto, rcnt)
		rs.set_extra({"quality": "normal"})
		rs.mouse_filter = Control.MOUSE_FILTER_PASS
		var rlines: Array = []
		if ch.size() >= 2:
			rlines.append(["Charging: %d, waiting: %d" % [ch_cur, ch_wait]])
		rs.set_tip(str(rm[2]), rlines)
		_members_grid.add_child(rs)

	var members: Array = contents.get("members", [])
	if members.is_empty():
		members = [
			["roboport", int(n["cells"])],
			["storage-chest", int(n["storages"])],
			["passive-provider-chest", int(n["providers"])],
			["requester-chest", int(n["requesters"])],
		]
	for m in members:
		if not (m is Array and m.size() >= 2):
			continue
		var proto := str(m[0])
		var cnt := int(m[1])
		if cnt <= 0:
			continue
		var s := Slot.new()
		s.name = "Member_" + proto
		s.set_stack(proto, cnt)
		s.set_extra({"quality": "normal"})
		s.mouse_filter = Control.MOUSE_FILTER_PASS
		s.set_tip(Kit.entity_name(proto), [["%s in the network" % Kit.count_text(cnt)], ["Left-click| to locate on map.", "", null, "keys"]])
		var on_member_click := func(button_index: int, _shift: bool) -> void:
			if button_index == MOUSE_BUTTON_LEFT and selected != 0:
				model.find_in_lnet(selected, {"proto": proto})
		s.clicked.connect(on_member_click)
		_members_grid.add_child(s)

	var pad_m := (COLUMNS - _members_grid.get_child_count() % COLUMNS) % COLUMNS
	for i in pad_m:
		_members_grid.add_child(Kit.empty_cell())
	_refresh_items()


func _refresh_items() -> void:
	_clear_children(_items)
	var contents: Dictionary = model.lnet.get(selected, {})
	if _tab == "Contents":
		var items_list: Array = contents.get("items", [])
		for it in items_list:
			if not (it is Array and it.size() >= 2):
				continue
			var item_name := str(it[0])
			var cnt := int(it[1])
			if not _matches_search(item_name):
				continue
			var q := str(it[2]) if it.size() > 2 else "normal"
			var s := _make_item_slot(item_name, cnt, q, [["%s in the network" % Kit.count_text(cnt)], ["Left-click| to locate on map.", "", null, "keys"]], "")
			_items.add_child(s)
	elif _tab == "Requests":
		var req_list: Array = contents.get("req", [])
		for r in req_list:
			if not (r is Array and r.size() >= 3):
				continue
			var item_name := str(r[0])
			var req_cnt := int(r[1])
			var missing := int(r[2])
			if not _matches_search(item_name):
				continue
			var q := str(r[3]) if r.size() > 3 else "normal"
			var lines: Array = [
				["Requested: %s" % Kit.count_text(req_cnt)],
				["Missing: %s" % Kit.count_text(missing), "", Kit.RED_TEXT if missing > 0 else Kit.GREEN_TEXT],
				["Left-click| to locate requesters.", "", null, "keys"],
			]
			var s := _make_item_slot(item_name, req_cnt, q, lines, "req")
			if missing > 0:
				s.set_logistic_state(-1, TINT_MISSING)
			_items.add_child(s)
	elif _tab == "In transit":
		var transit_list: Array = contents.get("transit", [])
		for tr in transit_list:
			if not (tr is Array and tr.size() >= 2):
				continue
			var item_name := str(tr[0])
			var cnt := int(tr[1])
			if not _matches_search(item_name):
				continue
			var q := str(tr[2]) if tr.size() > 2 else "normal"
			var s := _make_item_slot(item_name, cnt, q, [["%s in transit" % Kit.count_text(cnt)], ["Left-click| to locate on map.", "", null, "keys"]], "transit")
			_items.add_child(s)
	var cells := maxi(COLUMNS * 10, _items.get_child_count() + (COLUMNS - _items.get_child_count() % COLUMNS) % COLUMNS)
	for i in cells - _items.get_child_count():
		_items.add_child(Kit.empty_cell())


func _make_item_slot(item_name: String, cnt: int, q: String, lines: Array, role: String) -> Slot:
	var s := Slot.new()
	s.set_stack(item_name, cnt)
	s.set_extra({"quality": q})
	s.mouse_filter = Control.MOUSE_FILTER_PASS
	var title := Kit.pretty(item_name) + (" (%s)" % q.capitalize() if q != "" and q != "normal" else "")
	s.set_tip(title, lines)
	var on_click := func(button_index: int, _shift: bool) -> void:
		if button_index == MOUSE_BUTTON_LEFT and selected != 0:
			var query := {"item": item_name, "q": q}
			if role != "":
				query["role"] = role
			model.find_in_lnet(selected, query)
	s.clicked.connect(on_click)
	return s


func _matches_search(item_name: String) -> bool:
	if _search_text == "":
		return true
	return item_name.to_lower().contains(_search_text) or Kit.pretty(item_name).to_lower().contains(_search_text)


func _on_locs(id: int, si: int, locs: Array) -> void:
	if id != selected:
		return
	_locs = locs.duplicate()
	_locs_si = si
	_loc_index = 0
	if _locs.is_empty():
		_update_cycle_bar()
		return
	var first: Dictionary = _locs[0]
	show_at.emit(first["position"], _locs_si)
	_update_cycle_bar()


func _step_loc(delta: int) -> void:
	if _locs.is_empty():
		return
	_loc_index = posmod(_loc_index + delta, _locs.size())
	var loc: Dictionary = _locs[_loc_index]
	show_at.emit(loc["position"], _locs_si)
	_update_cycle_bar()


func _clear_locs() -> void:
	_locs.clear()
	_locs_si = 0
	_loc_index = 0
	_cycle_bar.visible = false


func _update_cycle_bar() -> void:
	_cycle_bar.visible = true
	if _locs.is_empty():
		_cycle_label.text = "0 / 0"
		_cycle_label.tooltip_text = "No matching entities found"
		_prev_btn.disabled = true
		_next_btn.disabled = true
		return
	_cycle_label.text = "%d / %d" % [_loc_index + 1, _locs.size()]
	var loc: Dictionary = _locs[_loc_index]
	_cycle_label.tooltip_text = "%s (%d)" % [Kit.entity_name(str(loc.get("proto", ""))), int(loc.get("count", 0))]
	var multi := _locs.size() > 1
	_prev_btn.disabled = not multi
	_next_btn.disabled = not multi


func _clear_children(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.queue_free()


func _subheader(text: String) -> Control:
	var p := Kit.panel("FSubheader")
	p.add_child(Kit.label(text, "FHeading"))
	return p
