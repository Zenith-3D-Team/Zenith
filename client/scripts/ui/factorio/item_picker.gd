extends PanelContainer
## Factorio's "choose an item / signal" dialog (choose-elem-button's popup): a search field and a
## grid of every item (and, for signals, fluids and virtual signals) as slot buttons. Click one to
## pick it; right click or Esc closes. factorio_ui.gd owns one; machine screens open it with
## `choose(kinds, callback)`, and the callback gets (type, name): "item", "fluid", "virtual" or
## "entity" (enemies, for a turret's priority targets).
##
## The item list is the mod's item dictionary (iprotos), so it holds every item the game knows,
## sorted by name (the bridge has no item groups for items that can't be hand-crafted).

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const Slot := preload("res://scripts/ui/factorio/slot.gd")
const MenuKit := preload("res://scripts/menu/menu_kit.gd")
const GuiAssets := preload("res://scripts/ui/factorio/gui_assets.gd")
const Switches := preload("res://scripts/switches.gd")

static var use_tabs := not (Switches.has("--item-picker-tabs=off"))

## Factorio's virtual signals (base game), in its own order: the "Signals" tab's subgroups (special, numbers, letters, punctuation,
## maths, colours, symbols, shapes, arrows, more arrows, pictographs), each starting a row.
const VIRTUAL_GROUPS := [
	["signal-everything", "signal-each", "signal-anything"],
	["signal-0", "signal-1", "signal-2", "signal-3", "signal-4", "signal-5", "signal-6", "signal-7", "signal-8", "signal-9"],
	["signal-A", "signal-B", "signal-C", "signal-D", "signal-E", "signal-F", "signal-G", "signal-H", "signal-I", "signal-J", "signal-K", "signal-L", "signal-M", "signal-N", "signal-O", "signal-P", "signal-Q", "signal-R", "signal-S", "signal-T", "signal-U", "signal-V", "signal-W", "signal-X", "signal-Y", "signal-Z", "signal-comma", "signal-letter-dot", "signal-exclamation-mark", "signal-question-mark"],
	["signal-colon", "signal-slash", "signal-apostrophe", "signal-quotation-mark", "signal-ampersand", "signal-circumflex-accent", "signal-number-sign", "signal-percent"],
	["signal-plus", "signal-minus", "signal-multiplication", "signal-division", "signal-equal", "signal-not-equal", "signal-less-than", "signal-greater-than", "signal-less-than-or-equal-to", "signal-greater-than-or-equal-to", "signal-left-parenthesis", "signal-right-parenthesis", "signal-left-square-bracket", "signal-right-square-bracket"],
	["signal-red", "signal-green", "signal-blue", "signal-yellow", "signal-pink", "signal-cyan", "signal-white", "signal-grey", "signal-black"],
	["signal-check", "signal-deny", "signal-no-entry", "signal-heart", "signal-alert", "signal-star", "signal-info"],
	["shape-vertical", "shape-horizontal", "shape-curve", "shape-curve-2", "shape-corner", "shape-corner-2", "shape-t", "shape-t-2", "shape-cross", "shape-diagonal-cross", "shape-diagonal", "shape-diagonal-2", "shape-curve-3", "shape-curve-4", "shape-corner-4", "shape-corner-3", "shape-t-4", "shape-t-3", "shape-circle", "signal-dot"],
	["up-arrow", "up-right-arrow", "right-arrow", "down-right-arrow", "down-arrow", "down-left-arrow", "left-arrow", "up-left-arrow"],
	["signal-rightwards-leftwards-arrow", "signal-upwards-downwards-arrow", "signal-shuffle", "signal-left-right-arrow", "signal-up-down-arrow", "signal-clockwise-circle-arrow", "signal-anticlockwise-circle-arrow", "signal-input", "signal-output"],
	["signal-fuel", "signal-lightning", "signal-battery-low", "signal-battery-mid-level", "signal-battery-full", "signal-radioactivity", "signal-thermometer-blue", "signal-thermometer-red", "signal-fire", "signal-snowflake", "signal-explosion", "signal-liquid", "signal-stack-size", "signal-recycle", "signal-trash-bin", "signal-science-pack", "signal-map-marker", "signal-white-flag", "signal-lock", "signal-unlock", "signal-speed", "signal-clock", "signal-hourglass", "signal-alarm", "signal-sun", "signal-moon", "signal-mining", "signal-skull", "signal-damage", "signal-weapon", "signal-ghost"],
]
## Internal items that never go in a filter.
const HIDDEN := ["item-unknown", "blueprint", "blueprint-book", "deconstruction-planner", "upgrade-planner",
	"copy-paste-tool", "cut-paste-tool", "selection-tool", "spidertron-remote", "artillery-targeting-remote",
	"discharge-defense-remote"]
## The base game's hidden items (prototypes.item with `hidden`): Factorio's chooser leaves them out.
const HIDDEN_ITEMS := ["artillery-wagon-cannon", "bottomless-chest", "burner-generator", "coin", "electric-energy-interface",
	"electric-energy-interface-equipment", "empty-module-slot", "express-loader", "fast-loader", "heat-interface", "infinity-cargo-wagon",
	"infinity-chest", "infinity-pipe", "lane-splitter", "linked-belt", "linked-chest", "loader", "no-item", "one-way-valve", "overflow-valve",
	"proxy-container", "rocket-part", "science", "simple-entity-with-force", "simple-entity-with-owner", "space-platform-hub",
	"spidertron-rocket-launcher-1", "spidertron-rocket-launcher-2", "spidertron-rocket-launcher-3", "spidertron-rocket-launcher-4",
	"tank-cannon", "tank-flamethrower", "tank-machine-gun", "top-up-valve", "turbo-loader", "vehicle-machine-gun"]
const SPECIAL := ["signal-everything", "signal-each", "signal-anything"]
const ROWS := 8
const ROWS_WITH_TABS := 6
const TABS_PER_ROW := 5
const CORE_GROUP_ICONS := {"enemies": "enemies", "environment": "environment", "tiles": "tiles-editor", "other": "unsorted"}

## Item names (and fluid names) to choose from; factorio_ui.gd fills these from the prototypes.
var items: Callable  # -> Array of item names
var fluids: Callable  # -> Array of fluid names
var entities: Callable  # -> Array of entity names a turret can target
var tiles: Callable  # -> Array of tile prototype names (a deconstruction planner's tile filters)
var map_entities: Callable  # -> Array of the entity names a deconstruction planner can filter on (buildings, trees, rocks)
var pedia_groups: Callable  # -> Array of [group_name, order]
var pedia_index: Callable  # -> Array of {"kind", "name", "group", "sub", "order"}
var on_open: Callable  # called before filling when choose() opens

var _search: LineEdit
var _tabs := GridContainer.new()
var _tab_strip := Kit.panel("FDeepFrame")
var _scroll: ScrollContainer
var _group := ""
## The value area under the grid, Factorio's two shapes: "Or set a constant" (a decider's or
## arithmetic combinator's second operand: a header, a slider, the number and "Set constant") and a
## constant combinator signal's value ("Set request": the number, a slider and the green tick).
var _constant_row: VBoxContainer
var _constant_head: Control
var _constant_box: LineEdit
var _constant_slider: HSlider
var _constant_ok: Button
var _value_tick: Button
var _on_constant := Callable()
var _grid := Kit.slot_grid()
var _title: Label
var _kinds: Array = ["item"]
var _callback := Callable()
var _entries: Array = []
var _group_rank := {}


func _ready() -> void:
	theme = MenuKit.theme()
	theme_type_variation = "FFrame"
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	z_index = 20
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Kit.px(8))
	add_child(box)
	var bar := Kit.title_bar("Select an item", true)
	_title = bar.get_child(0)
	(bar.get_child(bar.get_child_count() - 1) as Button).pressed.connect(close)
	box.add_child(bar)
	_search = MenuKit.textbox("", "Search")
	_search.custom_minimum_size.x = Kit.px(Kit.SLOT * Kit.COLUMNS)
	var on_search := func(_t: String) -> void:
		_fill()
		reset_size()
	_search.text_changed.connect(on_search)
	box.add_child(_search)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 0)
	box.add_child(content)
	_tabs.add_theme_constant_override("h_separation", 0)
	_tabs.add_theme_constant_override("v_separation", 0)
	_tab_strip.add_child(_tabs)
	_tab_strip.visible = false
	content.add_child(_tab_strip)
	var pane := Kit.panel("FTabPane")
	pane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(pane)
	var deep: Array = Kit.deep_scroll(Kit.pxv(Kit.SLOT * Kit.COLUMNS, Kit.SLOT * ROWS))
	pane.add_child(deep[0])
	_scroll = deep[1]
	_scroll.add_child(_grid)
	_build_value_area(box)


## Opens the dialog for these kinds ("item", "fluid", "virtual"); `callback(type, name)` gets the
## choice.
func choose(kinds: Array, callback: Callable, title := "") -> void:
	if on_open.is_valid():
		on_open.call()
	_constant_row.visible = false
	_on_constant = Callable()
	_kinds = kinds
	_callback = callback
	_title.text = title if title != "" else ("Select a signal" if kinds.size() > 1 else
		{"fluid": "Select a fluid", "entity": "Select an entity"}.get(str(kinds[0]) if not kinds.is_empty() else "", "Select an item"))
	_search.text = ""
	if _scroll != null:
		_scroll.scroll_vertical = 0
	_fill()
	visible = true
	reset_size()
	_search.grab_focus.call_deferred()


## Refreshes the grid and tabs while open (e.g. when prototype group metadata arrives).
func refresh() -> void:
	if not visible:
		return
	_fill()
	reset_size()


func _build_value_area(box: VBoxContainer) -> void:
	_constant_row = VBoxContainer.new()
	_constant_row.name = "ConstantRow"
	_constant_row.add_theme_constant_override("separation", Kit.px(4))
	_constant_row.visible = false
	var head := Kit.panel("FSubheader")
	head.custom_minimum_size.y = Kit.px(32)
	var hl := Kit.label("Or set a constant", "FHeading")
	hl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var hm := MarginContainer.new()
	hm.add_theme_constant_override("margin_left", Kit.px(8))
	hm.add_child(hl)
	head.add_child(hm)
	_constant_head = head
	_constant_row.add_child(head)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Kit.px(8))
	_constant_box = MenuKit.textbox("0")
	_constant_box.name = "ConstantBox"
	_constant_box.custom_minimum_size.x = Kit.px(80)
	_constant_box.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_constant_box.text_submitted.connect(func(_t: String) -> void: _set_constant())
	_constant_slider = MenuKit.slider(0, 100, 1, 0)
	_constant_slider.name = "ConstantSlider"
	_constant_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_constant_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_constant_slider.value_changed.connect(func(v: float) -> void:
		if _constant_box.text.strip_edges() != str(int(v)):
			_constant_box.text = str(int(v)))
	row.add_child(_constant_slider)
	row.add_child(_constant_box)
	_constant_ok = MenuKit.button("Set constant", "FGreenButton")
	_constant_ok.name = "ConstantOk"
	_constant_ok.pressed.connect(_set_constant)
	row.add_child(_constant_ok)
	_value_tick = Button.new()
	_value_tick.name = "ValueOk"
	_value_tick.theme_type_variation = "FGreenButton"
	_value_tick.custom_minimum_size = Kit.pxv(28, 28)
	_value_tick.focus_mode = Control.FOCUS_NONE
	_value_tick.tooltip_text = "Confirm"
	var tick := GuiAssets.core_sprite("icons/mip/confirm.png")
	if tick != null:
		_value_tick.icon = tick
		_value_tick.expand_icon = true
		_value_tick.add_theme_constant_override("icon_max_width", Kit.px(20))
	else:
		_value_tick.text = "✔"
	_value_tick.pressed.connect(_set_constant)
	row.add_child(_value_tick)
	var pad := MarginContainer.new()
	for side in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + side, Kit.px(8))
	pad.add_child(row)
	_constant_row.add_child(pad)
	box.add_child(_constant_row)


## The chooser of a "signal or constant" operand: the signals, and under them "Or set a constant"
## holding `constant`; on_constant(value) gets a constant set.
func choose_or_constant(kinds: Array, callback: Callable, constant: int, on_constant: Callable) -> void:
	choose(kinds, callback, "Select a signal")
	_show_value(constant, on_constant, true)


## A constant combinator's signal: the chooser to swap the signal, and its value under the grid
## (a number box, a slider and the green tick), as Factorio's "Set request" popup.
func choose_with_value(kinds: Array, callback: Callable, value: int, on_value: Callable) -> void:
	choose(kinds, callback, "Set request")
	_show_value(value, on_value, false)


func _show_value(value: int, on_value: Callable, constant: bool) -> void:
	_on_constant = on_value
	_constant_row.visible = true
	_constant_head.visible = constant
	_constant_ok.visible = constant
	_value_tick.visible = not constant
	# Factorio's order: the slider, then the number for a constant; the number first for a value.
	var row := _constant_box.get_parent()
	row.move_child(_constant_box, 1 if constant else 0)
	_constant_slider.max_value = maxf(100.0, float(absi(value)) * 2.0)
	_constant_slider.set_value_no_signal(clampf(value, _constant_slider.min_value, _constant_slider.max_value))
	_constant_box.text = str(value)
	reset_size()
	_constant_box.grab_focus.call_deferred()
	_constant_box.select_all.call_deferred()


func _set_constant() -> void:
	var t := _constant_box.text.strip_edges()
	if not t.is_valid_int() or not _on_constant.is_valid():
		return
	var f := _on_constant
	close()
	f.call(clampi(int(t), -2147483648, 2147483647))  # 32-bit, as Factorio's own box


func close() -> void:
	_on_constant = Callable()
	visible = false
	_search.release_focus()
	_callback = Callable()


func is_open() -> bool:
	return visible


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if visible and key != null and key.pressed and key.physical_keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


func _clear_grid() -> void:
	for c in _grid.get_children():
		_grid.remove_child(c)
		c.queue_free()


func _make_slot(type_name: String, name: String) -> Slot:
	var s := Slot.new()
	s.theme_type_variation = "FSlotButton"
	s.set_stack(name, -1)
	s.set_tip(Kit.pretty(name))
	var on_click := func(button_index: int, _shift: bool) -> void:
		if button_index == MOUSE_BUTTON_LEFT and _callback.is_valid():
			var f := _callback
			close()
			f.call(type_name, name)
		elif button_index == MOUSE_BUTTON_RIGHT:
			close()
	s.clicked.connect(on_click)
	return s


func _matches_query(name: String, q: String) -> bool:
	return q == "" or name.contains(q) or Kit.pretty(name).to_lower().contains(q)


func _tab_button(group: String) -> Button:
	var b := Button.new()
	b.theme_type_variation = "FTab"
	b.toggle_mode = true
	b.button_pressed = group == _group
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Kit.pxv(71, 72)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.tooltip_text = Kit.group_name(group)
	var icon := GuiAssets.group_icon(group)
	if icon == null and CORE_GROUP_ICONS.has(group):
		icon = GuiAssets.core_sprite("icons/category/%s.png" % CORE_GROUP_ICONS[group])
	if icon != null:
		b.icon = icon
		b.expand_icon = true
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.add_theme_constant_override("icon_max_width", Kit.px(64))
	else:
		b.text = Kit.group_name(group)
		b.clip_text = true
	var pick := func() -> void:
		_group = group
		for t in _tabs.get_children():
			if t is Button:
				(t as Button).set_pressed_no_signal(t == b)
		if _scroll != null:
			_scroll.scroll_vertical = 0
		_fill_tabbed_grid(_search.text.strip_edges().to_lower(), _tab_strip.visible)
	b.pressed.connect(pick)
	return b


func _virtual_skip(kind: String) -> Array:
	return {"virtual:plain": SPECIAL, "virtual:each": ["signal-everything", "signal-anything"],
		"virtual:no-anything": ["signal-anything"]}.get(kind, [])


func _fill() -> void:
	var q := _search.text.strip_edges().to_lower()
	var groups_raw: Array = pedia_groups.call() if use_tabs and pedia_groups.is_valid() else []
	var index_raw: Array = pedia_index.call() if use_tabs and pedia_index.is_valid() else []
	if not (use_tabs and not groups_raw.is_empty() and not index_raw.is_empty()):
		_tab_strip.visible = false
		if _scroll != null:
			_scroll.custom_minimum_size.y = Kit.px(Kit.SLOT * ROWS)
		_fill_flat(q)
		return
	var by_key := {}
	for i in index_raw.size():
		var e: Dictionary = index_raw[i]
		var ek := "%s/%s" % [str(e.get("kind", "")), str(e.get("name", ""))]
		by_key[ek] = {
			"group": str(e.get("group", "other")),
			"sub": str(e.get("sub", "other")),
			"order": str(e.get("order", "")),
			"rank": i,
		}
	_entries = []
	var has_group := {}
	for kind_v in _kinds:
		var kind := str(kind_v)
		if kind == "virtual" or kind.begins_with("virtual:"):
			var skip := _virtual_skip(kind)
			for gi in VIRTUAL_GROUPS.size():
				var vg: Array = VIRTUAL_GROUPS[gi]
				for si in vg.size():
					var name := str(vg[si])
					if skip.has(name):
						continue
					has_group["signals"] = true
					_entries.append({
						"kind": "virtual", "name": name, "group": "signals",
						"sub": "virtual_%02d" % gi, "order": "%02d|%03d" % [gi, si],
						"rank": gi * 100 + si,
					})
			continue
		var names: Array = []
		if kind == "item" and items.is_valid():
			names = items.call()
		elif kind == "fluid" and fluids.is_valid():
			names = fluids.call()
		elif kind == "entity" and entities.is_valid():
			names = entities.call()
		elif kind == "tile" and tiles.is_valid():
			names = tiles.call()
		elif kind == "map_entity" and map_entities.is_valid():
			names = map_entities.call()
		for n in names:
			var name := str(n)
			if HIDDEN.has(name) or (kind == "item" and HIDDEN_ITEMS.has(name)):
				continue
			var meta := {}
			if kind == "map_entity":
				meta = by_key.get("entity/" + name, by_key.get("item/" + name, {}))
			else:
				meta = by_key.get("%s/%s" % [kind, name], {})
			var group := "fluids" if kind == "fluid" else str(meta.get("group", "other"))
			var sub := str(meta.get("sub", "fluid" if kind == "fluid" else kind))
			var order := str(meta.get("order", name))
			var rank := int(meta.get("rank", 1000000))
			has_group[group] = true
			_entries.append({
				"kind": kind, "name": name, "group": group,
				"sub": sub, "order": order, "rank": rank,
			})
	var active_groups: Array = []
	for g in groups_raw:
		var gname := str(g[0]) if g is Array and g.size() >= 1 else str(g)
		if gname != "technologies" and has_group.has(gname) and not active_groups.has(gname):
			active_groups.append(gname)
	for extra in ["fluids", "signals", "other"]:
		if has_group.has(extra) and not active_groups.has(extra):
			active_groups.append(extra)
	for gname in has_group.keys():
		var gs := str(gname)
		if gs != "technologies" and not active_groups.has(gs):
			active_groups.append(gs)
	_group_rank = {}
	for i in active_groups.size():
		_group_rank[str(active_groups[i])] = i
	if (_group == "" or not active_groups.has(_group)) and not active_groups.is_empty():
		_group = str(active_groups[0])
	var show_tabs := active_groups.size() > 1 and q == ""
	_tab_strip.visible = show_tabs
	if _scroll != null:
		_scroll.custom_minimum_size.y = Kit.px(Kit.SLOT * (ROWS_WITH_TABS if show_tabs else ROWS))
	for child in _tabs.get_children():
		_tabs.remove_child(child)
		child.queue_free()
	if show_tabs:
		_tabs.columns = clampi(active_groups.size(), 1, TABS_PER_ROW)
		for g in active_groups:
			_tabs.add_child(_tab_button(str(g)))
	_fill_tabbed_grid(q, show_tabs)


func _fill_tabbed_grid(q: String, show_tabs: bool) -> void:
	_clear_grid()
	var shown: Array = []
	for entry in _entries:
		var e: Dictionary = entry
		if q != "":
			if _matches_query(str(e["name"]), q):
				shown.append(e)
		elif str(e["group"]) == _group:
			shown.append(e)
	var sort_entries := func(a: Dictionary, b: Dictionary) -> bool:
		var ga := int(_group_rank.get(str(a["group"]), 999))
		var gb := int(_group_rank.get(str(b["group"]), 999))
		if ga != gb:
			return ga < gb
		var ra := int(a["rank"])
		var rb := int(b["rank"])
		if ra != rb:
			return ra < rb
		var oa := str(a["order"])
		var ob := str(b["order"])
		if oa != ob:
			return oa < ob
		return str(a["name"]) < str(b["name"])
	shown.sort_custom(sort_entries)
	var cells := 0
	var prev_sub := ""
	for entry in shown:
		var e: Dictionary = entry
		var sub := str(e["sub"])
		if q == "" and prev_sub != "" and sub != prev_sub:
			while cells % Kit.COLUMNS != 0:
				_grid.add_child(Kit.empty_cell())
				cells += 1
		prev_sub = sub
		_grid.add_child(_make_slot(str(e["kind"]), str(e["name"])))
		cells += 1
	while cells % Kit.COLUMNS != 0:
		_grid.add_child(Kit.empty_cell())
		cells += 1
	var min_rows := ROWS_WITH_TABS if show_tabs else ROWS
	while cells < Kit.COLUMNS * min_rows:
		_grid.add_child(Kit.empty_cell())
		cells += 1


func _fill_flat(q: String) -> void:
	_clear_grid()
	var cells := 0
	var blocks: Array = []  # [kind, names, sort them?]: each starts a row
	for kind in _kinds:
		var names: Array = []
		if kind == "item" and items.is_valid():
			names = items.call()
		elif kind == "fluid" and fluids.is_valid():
			names = fluids.call()
		elif kind == "virtual" or kind.begins_with("virtual:"):
			# "virtual:plain" has no Each / Anything / Everything (a constant combinator's, a comparison's second signal);
			# "virtual:each" has Each only (an arithmetic combinator's operands), "virtual:no-anything" all but Anything (an output).
			var skip: Array = _virtual_skip(str(kind))
			for group in VIRTUAL_GROUPS:
				blocks.append(["virtual", group.filter(func(n: String) -> bool: return not skip.has(n)), false])
			continue
		elif kind == "entity" and entities.is_valid():
			names = entities.call()
		elif kind == "tile" and tiles.is_valid():
			names = tiles.call()
		elif kind == "map_entity" and map_entities.is_valid():
			names = map_entities.call()
		blocks.append([kind, names, true])
	for block in blocks:
		var kind: String = block[0]
		var names: Array = block[1].duplicate()
		if block[2]:
			names.sort()
		for n in names:
			var name := str(n)
			if HIDDEN.has(name) or (kind == "item" and HIDDEN_ITEMS.has(name)) or not _matches_query(name, q):
				continue
			_grid.add_child(_make_slot(kind, name))
			cells += 1
		# Each kind starts a row, like Factorio's groups.
		while cells % Kit.COLUMNS != 0:
			_grid.add_child(Kit.empty_cell())
			cells += 1
	while cells < Kit.COLUMNS * ROWS:
		_grid.add_child(Kit.empty_cell())
		cells += 1
