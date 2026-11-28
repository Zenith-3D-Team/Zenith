extends Control
## Mods' windows, drawn from the real player's GUI as the bridge reads it (`mgui`, mod_gui.lua):
## every element a mod puts in player.gui.top (buttons along the top left), left (a column under
## them), center, screen (at the place the mod gave) and relative (beside the Factorio window it is
## anchored to, here beside Zenith's own copy of that window). Factorio's own windows aren't in
## player.gui; Zenith draws those itself.
##
## A mod only hears a real click in Factorio, and no script can make one. Buttons of mods with a
## remote interface the bridge knows (Informatron) are pressed by the bridge (`ck`, `mpress`). Any
## other button pressed here is clicked in Factorio's own window where Factorio has it (factorio_clicks.gd; Windows, when that
## window is on this PC: hybrid), worked out from this copy's layout, the window's place and
## Factorio's UI scale (`ds`); without that it says to use it in Factorio (Ctrl+F9). Only with a real
## player (hybrid single-player, or joined to the server): a player-less character has no GUI and the
## bridge sends nothing. Settings > Interface > Click mods' buttons in Factorio turns it off.

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const UiModel := preload("res://scripts/ui/factorio/ui_model.gd")
const RichText := preload("res://scripts/ui/factorio/rich_text.gd")
const GuiAssets := preload("res://scripts/ui/factorio/gui_assets.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const LocaleNames := preload("res://scripts/world/locale_names.gd")
const FactorioClicks := preload("res://scripts/ui/factorio/factorio_clicks.gd")
const ModGraphics := preload("res://scripts/world/mod_graphics.gd")
const Settings := preload("res://scripts/menu/settings.gd")

const USE_IN_FACTORIO := "Mods' windows are shown here; to use one, press Ctrl+F9 and use it in Factorio"
## A scroll pane holds at most this much before it scrolls (mods' styles size them; these don't).
const SCROLL_MAX := Vector2(900, 520)
## Labels longer than this many characters wrap at WRAP_WIDTH pixels (UI scale 1).
const WRAP_AFTER := 70
const WRAP_WIDTH := 560

var model: UiModel
## Shows a line on the HUD (factorio_ui.gd sets it).
var message := Callable()
## Zenith's windows a relative element may sit beside, by Factorio's relative_gui_type name
## (factorio_ui.gd fills it: the character window, the machine screen).
var anchors := {}

## index -> {"r": root, "node": Control, "at": [x, y], "an": [gui, position, name]}
var _windows := {}
## Factorio's window: [width, height, UI scale] (`ds`), empty when the bridge didn't say.
var display: Array = []
## Clicks sent on to Factorio (for tests: [Vector2 in Factorio's pixels, element name]).
var forwarded: Array = []
## Buttons the bridge was asked to press (`mpress`), by element index (for tests).
var pressed_by_bridge: Array = []
## What the player changed in a window here, sent as `mset` {ix, v} (for tests).
var sets_sent: Array = []
## Texts typed here lately, by element index: {texts, msec}. The bridge's next reading of the window comes back
## with the text it had when it heard (a letter or two behind a fast typist), which must not undo it.
var _typed := {}
const TYPED_KEEP_MSEC := 2000
## Windows' newer trees that came while the player was dragging them: index -> entry.
var _held := {}
## Screen windows just closed, by name: {pos, msec}; a new window of that name takes the place.
var _gone := {}
const GONE_KEEP_MSEC := 5000
## Zenith's item picker (factorio_ui.gd sets it): what a mod's choose-elem-button opens.
var picker: Node
## The picker's kinds for the elem types it can choose.
const PICKABLE := {"item": ["item"], "fluid": ["fluid"], "signal": ["item", "fluid", "virtual"], "entity": ["entity"]}
var _top: HBoxContainer
var _left: VBoxContainer
var _center: CenterContainer


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top = HBoxContainer.new()
	_top.position = Vector2(Kit.px(8 + 40 + 6), Kit.px(8))  # after the Factorio button (factorio_ui.gd)
	_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_top)
	_left = VBoxContainer.new()
	_left.position = Vector2(Kit.px(8), Kit.px(56))
	_left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_left)
	_center = CenterContainer.new()
	_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_center)
	if Settings.has_arg("--mod-click-probe="):
		var probe: Node = preload("res://scripts/debug/mod_click_probe.gd").new()
		probe.mod_gui = self
		add_child(probe)


func count() -> int:
	return _windows.size()


## One `mgui`: the windows it carries are built again; any not in `ids` are gone.
func handle(msg: Dictionary) -> void:
	# Off (the default for now): nothing of mods' windows is drawn; ones shown before go.
	if not bool(Settings.get_value("interface", "mod_windows")):
		if not _windows.is_empty():
			for w in _windows.values():
				(w["node"] as Control).queue_free()
			_windows.clear()
		return
	var ds = msg.get("ds")
	if ds is Array and ds.size() == 3:
		display = [float(ds[0]), float(ds[1]), float(ds[2])]
	var ids := {}
	for i in UiModel._array(msg.get("ids")):
		ids[int(i)] = true
	for index in _windows.keys():
		if not ids.has(index):
			var gone: Dictionary = _windows[index]
			var gone_node: Control = gone["node"]
			if str(gone["r"]) == "screen" and str(gone.get("n", "")) != "":
				_gone[str(gone["n"])] = {"pos": gone_node.position, "msec": Time.get_ticks_msec()}
			gone_node.queue_free()
			_windows.erase(index)
	for entry in UiModel._array(msg.get("l")):
		if not (entry is Dictionary):
			continue
		var index := int(entry.get("i", 0))
		if _windows.has(index) and _dragging(_windows[index]["node"]):
			_held[index] = entry  # rebuilt when the button is let go, or the drag would stop
			continue
		_apply(index, entry)
	_place()


## Builds window `index` again from its entry, keeping where the player dragged it.
func _apply(index: int, entry: Dictionary) -> void:
	var dragged := Vector2.ZERO
	var focus := {}
	if _windows.has(index):
		var old: Control = _windows[index]["node"]
		dragged = old.get_meta("drag_offset", Vector2.ZERO)
		focus = _focused_input(old)
		old.queue_free()
	var root := str(entry.get("r", "screen"))
	var node := build(entry.get("e", {}), 0)
	if dragged != Vector2.ZERO:
		node.set_meta("drag_offset", dragged)
	var w := {"r": root, "node": node, "at": entry.get("at"), "an": entry.get("an"), "n": str((entry.get("e", {}) as Dictionary).get("n", ""))}
	# A mod that rebuilds its window (Informatron, on every page) makes a new one where Factorio hasn't
	# placed it yet: it keeps the place of the one of the same name it replaced until Factorio says
	# where the new one is (its `at` changes from the first it gave).
	var before: Dictionary = _windows.get(index, {})
	if before.has("hold") and str(before.get("first_at")) == str(entry.get("at")):
		w["hold"] = before["hold"]
		w["first_at"] = before["first_at"]
	elif before.is_empty() and root == "screen" and _gone.has(w["n"]) and Time.get_ticks_msec() - int(_gone[w["n"]]["msec"]) < GONE_KEEP_MSEC:
		w["hold"] = _gone[w["n"]]["pos"]
		w["first_at"] = entry.get("at")
	_windows[index] = w
	match root:
		"top":
			_top.add_child(node)
		"left":
			_left.add_child(node)
		"center":
			_center.add_child(node)
		_:
			add_child(node)
			node.top_level = false
	_restore_input(node, focus)


## The text field with the keyboard focus in `node`: {ix, text, caret}, or empty.
func _focused_input(node: Control) -> Dictionary:
	var f := node.get_viewport().gui_get_focus_owner() if node.is_inside_tree() else null
	if f == null or not node.is_ancestor_of(f) or not f.has_meta("mod_ix"):
		return {}
	return {"ix": int(f.get_meta("mod_ix")), "text": f.get("text"), "caret": f.get("caret_column")}


## Gives the focus (and the caret) back to the field being typed in after its window was built
## again. Its text stays what was typed while the bridge's reading is just what it heard of it.
func _restore_input(node: Control, focus: Dictionary) -> void:
	if focus.is_empty():
		return
	for c in node.find_children("*", "LineEdit", true, false):
		if int(c.get_meta("mod_ix", -1)) != int(focus["ix"]):
			continue
		var typed: Dictionary = _typed.get(int(focus["ix"]), {})
		if (c as LineEdit).text != str(focus["text"]) and (typed.get("texts", []) as Array).has((c as LineEdit).text) 				and Time.get_ticks_msec() - int(typed.get("msec", 0)) < TYPED_KEEP_MSEC:
			(c as LineEdit).text = str(focus["text"])
		(c as LineEdit).grab_focus()
		(c as LineEdit).caret_column = mini(int(focus["caret"]), (c as LineEdit).text.length())
		return


## The player changed element `ix` here: the bridge sets it on the mod's element and raises the
## event (mod_gui.lua set).
func _typed_text(ix: int, text: String) -> void:
	var texts: Array = (_typed.get(ix, {}) as Dictionary).get("texts", []) if Time.get_ticks_msec() - int((_typed.get(ix, {}) as Dictionary).get("msec", 0)) < TYPED_KEEP_MSEC else []
	texts.append(text)
	_typed[ix] = {"texts": texts.slice(-20), "msec": Time.get_ticks_msec()}
	send_set(ix, text.substr(0, 2000))


func send_set(ix: int, value: Variant) -> void:
	sets_sent.append([ix, value])
	Bridge.send({"t": "mset", "ix": ix, "v": value})


func _dragging(node: Control) -> bool:
	# A drop-down's list open: the window isn't rebuilt under it.
	for pick in node.find_children("*", "OptionButton", true, false):
		if (pick as OptionButton).get_popup().visible:
			return true
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return false
	for handle in node.find_children("*", "Control", true, false):
		if bool(handle.get_meta("dragging", false)):
			return true
	return false


func _process(_delta: float) -> void:
	for index in _held.keys():
		if not _windows.has(index):
			_held.erase(index)
		elif not _dragging(_windows[index]["node"]):
			_apply(index, _held[index])
			_held.erase(index)
	if not _windows.is_empty():
		_place()
	if FactorioClicks.waiting > 0:
		heard(FactorioClicks.poll())


func _exit_tree() -> void:
	FactorioClicks.stop()


## The click helper's answers: a click that didn't happen there (no Factorio window, an error)
## says to use the button in Factorio instead.
func heard(replies: PackedStringArray) -> void:
	for r in replies:
		if not r.begins_with("ok"):
			if message.is_valid():
				message.call(USE_IN_FACTORIO)
			return


## Screen windows where the mod put them (Factorio's pixels at UI scale 1), relative ones beside
## their window, shown only while it is.
func _place() -> void:
	for w in _windows.values():
		var node: Control = w["node"]
		match str(w["r"]):
			"screen":
				var at = w.get("at")
				if node.has_meta("full_screen"):
					node.position = Vector2.ZERO
					node.size = get_viewport_rect().size
					var inner: Control = node.get_child(0)
					inner.size = inner.get_combined_minimum_size()
					inner.position = node.size - inner.size
				elif w.has("hold"):
					node.position = w["hold"]
				elif at is Array and at.size() == 2 and float(at[0]) == 0.0 and float(at[1]) == 0.0 						and node.get_meta("drag_offset", Vector2.ZERO) == Vector2.ZERO:
					# At 0, 0: a window the mod centres (force_auto_center), not placed by Factorio yet.
					node.position = ((get_viewport_rect().size - node.size) / 2.0).floor()
				elif at is Array and at.size() == 2:
					# Where the mod put it, moved by any drag here, kept on the screen.
					var want := Vector2(float(at[0]), float(at[1])) * Kit.scale_for(get_viewport_rect().size.y)
					want += Vector2(node.get_meta("drag_offset", Vector2.ZERO))
					# Its title bar stays where it can be grabbed.
					var view := get_viewport_rect().size
					if view.x > Kit.px(200) and view.y > Kit.px(200):
						want.x = clampf(want.x, Kit.px(80) - node.size.x, view.x - Kit.px(80))
						want.y = clampf(want.y, 0.0, view.y - Kit.px(40))
					node.position = want
			"relative":
				var an = w.get("an")
				var gui := str(an[0]) if an is Array and an.size() > 0 else ""
				var target: Control = anchors.get(gui, anchors.get("entity") if gui != "controller_gui" and gui != "" else null)
				var shown := target != null and is_instance_valid(target) and target.is_visible_in_tree()
				node.visible = shown and bool(node.get_meta("mod_visible", true))
				if shown:
					var rect := target.get_global_rect()
					var side := str(an[1]) if an is Array and an.size() > 1 else "right"
					match side:
						"left":
							node.global_position = rect.position - Vector2(node.size.x + Kit.px(4), 0)
						"top":
							node.global_position = rect.position - Vector2(0, node.size.y + Kit.px(4))
						"bottom":
							node.global_position = Vector2(rect.position.x, rect.end.y + Kit.px(4))
						_:
							node.global_position = Vector2(rect.end.x + Kit.px(4), rect.position.y)


## One element and its children as Godot controls, in Factorio's look.
func build(e: Dictionary, depth: int) -> Control:
	var ty := str(e.get("t", "empty-widget"))
	var style := str(e.get("st", ""))
	var caption := LocaleNames.localise(e.get("c"))
	var node: Control
	match ty:
		"frame":
			node = _frame(e, depth, caption, style)
		"flow":
			node = _box(str(e.get("d", "horizontal")))
			_children(node, e, depth)
		"table":
			var grid := GridContainer.new()
			grid.columns = maxi(1, int(e.get("cc", 1)))
			grid.add_theme_constant_override("h_separation", Kit.px(4))
			grid.add_theme_constant_override("v_separation", Kit.px(4))
			node = grid
			_children(node, e, depth)
		"scroll-pane":
			var scroll := ScrollContainer.new()
			scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			var inner := _box("vertical")
			scroll.add_child(inner)
			_children(inner, e, depth)
			node = scroll
			if not e.get("vs", false):
				_fit_scroll.call_deferred(scroll, inner, _max_height(e))
		"label":
			node = RichText.text_label(caption, _label_variation(style)) if RichText.has_tags(caption) else Kit.label(caption, _label_variation(style))
			# Factorio wraps a label whose style isn't single-line at its maximal width (`ml`, `mw`);
			# a long one without either wraps at WRAP_WIDTH, as these copies have no widths of their own.
			# Rich text (icons, colours) too: Informatron's pages are paragraphs of it.
			if e.get("ml", false) or caption.length() > WRAP_AFTER:
				var width := Kit.px(clampf(float(e.get("mw", WRAP_WIDTH)), 120.0, 1200.0))
				if node is Label:
					(node as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				elif node is RichTextLabel:
					(node as RichTextLabel).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				node.custom_minimum_size.x = width
		"button":
			var b := Button.new()
			b.text = caption
			RichText.decorate_button(b, caption)
			node = _clickable(b, e)
		"sprite-button", "choose-elem-button":
			node = _sprite_button(e, ty, caption)
		"sprite":
			var rect := TextureRect.new()
			rect.texture = sprite(str(e.get("sp", "")))
			rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			rect.custom_minimum_size = Kit.pxv(32, 32)
			node = rect
		"checkbox", "radiobutton":
			var c := CheckBox.new()
			c.text = caption
			c.button_pressed = bool(e.get("s", false))
			if e.get("ix") != null:
				# Checking it here is the mod's checkbox checked (on_gui_checked_state_changed, mod_gui.lua).
				var cix := int(e.get("ix"))
				var radio := ty == "radiobutton"
				c.focus_mode = Control.FOCUS_NONE
				c.mouse_filter = Control.MOUSE_FILTER_STOP
				c.toggle_mode = true
				c.toggled.connect(func(on: bool) -> void:
					if radio and not on:
						c.set_pressed_no_signal(true)  # a click never switches a radio button off
						return
					send_set(cix, on))
				node = c
			else:
				node = _clickable(c, e)
		"textfield":
			var f := LineEdit.new()
			f.text = str(e.get("tx", ""))
			f.editable = false
			f.custom_minimum_size.x = Kit.px(160)
			if e.get("ix") != null:
				# Typing sets the mod's textfield (on_gui_text_changed, mod_gui.lua).
				var fix := int(e.get("ix"))
				f.editable = e.get("en", true) != false
				f.set_meta("mod_ix", fix)
				f.text_changed.connect(func(t: String) -> void: _typed_text(fix, t))
			node = f
		"text-box":
			var t := TextEdit.new()
			t.text = str(e.get("tx", ""))
			t.editable = false
			t.custom_minimum_size = Kit.pxv(240, 80)
			node = t
		"progressbar":
			var bar := Kit.progress_bar()
			bar.max_value = 1.0
			bar.step = 0.0
			bar.value = float(e.get("v", 0.0))
			bar.custom_minimum_size.x = Kit.px(160)
			node = bar
		"slider":
			var s := HSlider.new()
			s.editable = false
			s.step = 0.0
			s.min_value = float(e.get("mn", 0.0))
			s.max_value = float(e.get("mx", maxf(1000000.0, float(e.get("v", 0.0)))))
			s.value = float(e.get("v", 0.0))
			s.custom_minimum_size.x = Kit.px(160)
			if e.get("ix") != null:
				# Moving it sets the mod's slider (on_gui_value_changed); its window isn't rebuilt under the handle.
				var six := int(e.get("ix"))
				s.editable = e.get("en", true) != false
				s.step = float(e.get("stp", 0.0))
				s.value = float(e.get("v", 0.0))
				s.focus_mode = Control.FOCUS_NONE
				s.drag_started.connect(func() -> void: s.set_meta("dragging", true))
				s.drag_ended.connect(func(_changed: bool) -> void: s.set_meta("dragging", false))
				s.value_changed.connect(func(v: float) -> void: send_set(six, v))
			node = s
		"drop-down":
			var items := UiModel._array(e.get("it"))
			var i := int(e.get("si", 0)) - 1
			if e.get("ix") != null:
				# Picking one sets the mod's drop-down (on_gui_selection_state_changed, mod_gui.lua).
				var dix := int(e.get("ix"))
				var pick := OptionButton.new()
				pick.focus_mode = Control.FOCUS_NONE
				pick.custom_minimum_size.x = Kit.px(160)
				for k in items.size():
					pick.add_item(LocaleNames.localise(items[k]), k)
				pick.selected = i if i >= 0 and i < items.size() else -1
				pick.item_selected.connect(func(k: int) -> void: send_set(dix, k + 1))
				node = pick
			else:
				var d := Button.new()
				d.text = (LocaleNames.localise(items[i]) if i >= 0 and i < items.size() else "") + "  ▾"
				node = _clickable(d, e)
		"list-box":
			var items := UiModel._array(e.get("it"))
			if e.get("ix") != null:
				# Clicking a row sets the mod's list box (on_gui_selection_state_changed, mod_gui.lua).
				var lix := int(e.get("ix"))
				var rows := ItemList.new()
				rows.focus_mode = Control.FOCUS_NONE
				rows.auto_height = true
				rows.custom_minimum_size.x = Kit.px(160)
				for k in items.size():
					rows.add_item(LocaleNames.localise(items[k]))
				var chosen := int(e.get("si", 0)) - 1
				if chosen >= 0 and chosen < items.size():
					rows.select(chosen)
				rows.item_selected.connect(func(k: int) -> void: send_set(lix, k + 1))
				if e.get("en", true) == false:
					rows.mouse_filter = Control.MOUSE_FILTER_IGNORE  # a disabled list box takes no clicks
					rows.modulate.a = 0.5
				node = rows
			else:
				var list := _box("vertical")
				for k in items.size():
					var row := Kit.label(LocaleNames.localise(items[k]), "FHeading" if k == int(e.get("si", 0)) - 1 else "")
					list.add_child(row)
				node = list
		"line":
			node = HSeparator.new() if str(e.get("d", "horizontal")) == "horizontal" else VSeparator.new()
		"switch":
			var sw := _box("horizontal")
			if e.get("ix") != null:
				# Clicking a side puts the mod's switch there (on_gui_switch_state_changed, mod_gui.lua).
				var wix := int(e.get("ix"))
				for side in ["left", "right"]:
					var sb := Button.new()
					var label := LocaleNames.localise(e.get("lc" if side == "left" else "rc"))
					sb.text = label if label != "" else side.capitalize()
					sb.focus_mode = Control.FOCUS_NONE
					sb.toggle_mode = true
					sb.button_pressed = str(e.get("s", "")) == side
					sb.disabled = e.get("en", true) == false
					sb.pressed.connect(func() -> void: send_set(wix, side))
					sw.add_child(sb)
			else:
				sw.add_child(Kit.label(LocaleNames.localise(e.get("lc")), "FHeading" if str(e.get("s", "")) == "left" else ""))
				sw.add_child(Kit.label("⇄"))
				sw.add_child(Kit.label(LocaleNames.localise(e.get("rc")), "FHeading" if str(e.get("s", "")) == "right" else ""))
			node = sw
		"tabbed-pane":
			node = _tabs(e, depth)
		"empty-widget":
			node = Control.new()
			node.mouse_filter = Control.MOUSE_FILTER_IGNORE
			if style.contains("drag") or style.contains("filler") or style.contains("spacer"):
				node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			if style.contains("drag"):
				# A mod's title bar filler (draggable_space_header): drags its window here too.
				node.custom_minimum_size.y = Kit.px(24)
				Kit.make_drag_handle(node)
		_:
			# camera, minimap, entity-preview: what they show needs a view of the world of their own
			var p := Kit.panel("FDeepFrame")
			p.add_child(Kit.label("(%s)" % ty))
			node = p
	var tip := LocaleNames.localise(e.get("tt"))
	if tip != "":
		node.tooltip_text = RichText.plain(tip)
	if e.get("vis", true) == false:
		node.visible = false
		node.set_meta("mod_visible", false)
	if e.get("en", true) == false and node is BaseButton:
		(node as BaseButton).disabled = true
	if e.get("dr", false):
		Kit.make_drag_handle(node)
	_apply_style(node, e, depth)
	var element_name := str(e.get("n", ""))
	node.name = (element_name if element_name != "" else ty).validate_node_name()
	return node


func _frame(e: Dictionary, depth: int, caption: String, style: String) -> Control:
	if e.get("ig", false) and depth == 0:
		return _pass_through(e, depth)
	var variation := "FFrame"
	if depth > 0:
		variation = "FDeepFrame" if style.contains("deep") else ("FSubheader" if style.contains("subheader") else "FShallowFrame")
	var frame := Kit.panel(variation)
	frame.mouse_filter = Control.MOUSE_FILTER_STOP
	var body := _box("vertical")
	frame.add_child(body)
	if caption != "":
		body.add_child(Kit.title_bar(caption, false) if depth == 0 else Kit.label(caption, "FHeading"))
	var content := _box(str(e.get("d", "vertical")))
	var window_scroll: ScrollContainer = null
	if depth == 0:
		# A window taller than Zenith's scrolls under its title bar instead of running off the screen;
		# its content fills the window's own height (a style's fixed height), stretched panes with it.
		window_scroll = ScrollContainer.new()
		window_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		window_scroll.focus_mode = Control.FOCUS_NONE
		window_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		content.size_flags_vertical = Control.SIZE_EXPAND_FILL
		content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		window_scroll.add_child(content)
		body.add_child(window_scroll)
		body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	else:
		body.add_child(content)
	content.set_meta("mod_body", true)
	_children(content, e, depth)
	if window_scroll != null:
		# After the children's own scroll panes, which are fitted on the same deferred pass.
		_fit_window.call_deferred(window_scroll, content)
	if e.get("cut", false):
		body.add_child(Kit.label("(more in Factorio: Ctrl+F9)"))
	return frame


func _tabs(e: Dictionary, depth: int) -> Control:
	var pane := _box("vertical")
	var heads := _box("horizontal")
	pane.add_child(heads)
	var chosen := int(e.get("si", 1)) - 1
	var tabs := UiModel._array(e.get("tb"))
	for k in tabs.size():
		var pair = tabs[k]
		if not (pair is Array and pair.size() == 2):
			continue
		var head := Button.new()
		head.theme_type_variation = "FTab"
		head.text = LocaleNames.localise((pair[0] as Dictionary).get("c"))
		head.button_pressed = k == chosen
		heads.add_child(_clickable(head, pair[0]))
		if k == chosen:
			var page := Kit.panel("FShallowFrame")
			page.add_child(build(pair[1], depth + 1))
			pane.add_child(page)
	return pane


func _sprite_button(e: Dictionary, ty: String, caption: String) -> Control:
	var b := Button.new()
	b.theme_type_variation = "FSlotButton"
	b.custom_minimum_size = Kit.pxv(40, 40)
	var path := str(e.get("sp", ""))
	if ty == "choose-elem-button":
		# A signal's value says what it is (evt: item, fluid, virtual...): its picture is that kind's.
		var kind := str(e.get("et", "item"))
		if e.has("evt"):
			kind = "virtual-signal" if str(e.get("evt")) == "virtual" else str(e.get("evt"))
		path = "%s/%s" % [kind, str(e.get("ev", ""))] if e.get("ev") != null else ""
	var tex := sprite(path)
	if tex != null:
		b.icon = tex
		b.expand_icon = true
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	elif caption != "":
		b.text = caption
	else:
		b.text = path.get_file().left(3)
	if e.has("nu") and e.get("nu") != null:
		var n := Kit.label(Kit.count_text(int(e.get("nu"))))
		n.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
		n.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		b.add_child(n)
	b.button_pressed = bool(e.get("tg", false))
	if ty == "choose-elem-button" and e.get("ix") != null and PICKABLE.has(str(e.get("et", "item"))):
		return _elem_button(b, e)
	return _clickable(b, e)


## A mod's choose-elem-button: click opens the item picker, right click clears it; the choice goes
## to the bridge (on_gui_elem_changed, mod_gui.lua: a name, {type, name} for a signal, false to clear).
func _elem_button(b: Button, e: Dictionary) -> Button:
	var eix := int(e.get("ix"))
	var elem := str(e.get("et", "item"))
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.pressed.connect(func() -> void:
		if picker == null or not picker.has_method("choose"):
			return
		picker.choose(PICKABLE[elem], func(type_name: String, item_name: String) -> void:
			send_set(eix, {"type": "virtual" if type_name == "virtual" else type_name, "name": item_name} if elem == "signal" else item_name)))
	b.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
			send_set(eix, false))
	return b


## A SpritePath ("item/iron-plate", "entity/...", "technology/...", "utility/...") as a texture, or
## null for a mod's own sprite this doesn't know yet.
static func sprite(path: String) -> Texture2D:
	if path == "":
		return null
	var slash := path.find("/")
	if slash < 0:
		# A `sprite` prototype (a mod's own GUI picture), else an item of that name.
		var own := ModGraphics.sprite_texture(path)
		return own if own != null else ItemIcons.texture_for(path)
	var kind := path.substr(0, slash)
	var item := path.substr(slash + 1)
	match kind:
		"item", "fluid", "virtual-signal", "recipe":
			return Kit.item_icon(item)
		"utility":
			return GuiAssets.core_sprite("icons/%s.png" % item)
		_:
			return RichText.icon(kind.replace("_", "-"), item)


func _clickable(b: BaseButton, e: Dictionary) -> BaseButton:
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.toggle_mode = b is CheckBox or b.button_pressed
	if e.get("ck", false) and e.get("ix") != null:
		b.set_meta("press_ix", int(e.get("ix")))
	b.pressed.connect(func() -> void: press(b))
	return b


## A mod's button pressed here: one the bridge can press itself (`ck`: a mod with a remote
## interface, mod_gui.lua) goes to the bridge as `mpress`, which works on a server too and never
## misses; any other is clicked in Factorio's window where it is, or the message.
func press(b: Control) -> void:
	if b.has_meta("press_ix"):
		var ix := int(b.get_meta("press_ix"))
		pressed_by_bridge.append(ix)
		Bridge.send({"t": "mpress", "ix": ix})
		return
	var at := factorio_point(b)
	var mode := str(Settings.get_value("interface", "mod_click_mode"))
	if at.x >= 0.0 and bool(Settings.get_value("interface", "mod_clicks")) and FactorioClicks.click(at, mode):
		forwarded.append([at, str(b.name)])
		return
	if message.is_valid():
		message.call(USE_IN_FACTORIO)


## Where `c` is in Factorio's window (its client pixels), from this copy: the offset inside its
## top-level window turned from Zenith's UI scale into Factorio's, from where Factorio has that
## window (screen: where the mod put it; center: the middle; top and left: their place along the
## top left, as here). (-1, -1) when the bridge hasn't said how big Factorio's window is.
func factorio_point(c: Control) -> Vector2:
	if display.is_empty():
		return Vector2(-1, -1)
	var top: Control = null
	var root := ""
	for w in _windows.values():
		var node: Control = w["node"]
		if node == c or node.is_ancestor_of(c):
			top = node
			root = str(w["r"])
			if root == "screen":
				top.set_meta("factorio_at", w.get("at"))
			break
	if top == null:
		return Vector2(-1, -1)
	var zs := Kit.scale_for(get_viewport_rect().size.y)
	var fs: float = display[2]
	var res := Vector2(display[0], display[1])
	var to_f := fs / maxf(0.01, zs)
	# Just inside its top-left corner rather than its middle: this copy has none of the mod's own
	# styles, so a button may be narrower or shorter here than in Factorio, and its corner is
	# where both agree best (Informatron's menu: 89 px wide here, 246 in Factorio).
	var rect := c.get_global_rect()
	var aim := rect.position + Vector2(minf(rect.size.x * 0.5, 10.0 * zs), minf(rect.size.y * 0.5, 10.0 * zs))
	var offset := (aim - top.global_position) * to_f
	var origin := top.global_position * to_f
	match root:
		"screen":
			var at = top.get_meta("factorio_at", null)
			if at is Array and at.size() == 2:
				origin = Vector2(float(at[0]), float(at[1])) * fs
		"center":
			origin = (res - top.size * to_f) / 2.0
	return origin + offset


func _children(parent: Control, e: Dictionary, depth: int) -> void:
	for child in UiModel._array(e.get("a")):
		if child is Dictionary:
			parent.add_child(build(child, depth + 1))


func _box(direction: String) -> BoxContainer:
	var box: BoxContainer = VBoxContainer.new() if direction == "vertical" else HBoxContainer.new()
	box.add_theme_constant_override("separation", Kit.px(4))
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return box


func _label_variation(style: String) -> String:
	if style.contains("heading") or style.contains("bold"):
		return "FHeading"
	if style.contains("caption"):
		return "FCaption"
	return ""


func _fit_scroll(scroll: ScrollContainer, inner: Control, max_h := 0) -> void:
	if not is_instance_valid(scroll):
		return
	var want := inner.get_combined_minimum_size()
	var cap := Kit.pxv(SCROLL_MAX.x, max_h if max_h > 0 else SCROLL_MAX.y)
	scroll.custom_minimum_size = Vector2(minf(want.x + Kit.px(12), cap.x), minf(want.y, cap.y))


## A top-level window's content: as big as it is, but no taller than Zenith's window leaves room
## for (its title bar and a margin); taller, it scrolls.
func _fit_window(scroll: ScrollContainer, inner: Control) -> void:
	if not is_instance_valid(scroll):
		return
	var want := inner.get_combined_minimum_size()
	var cap := get_viewport_rect().size.y - Kit.px(120)
	var scrolls := want.y > cap
	scroll.custom_minimum_size = Vector2(want.x + (Kit.px(12) if scrolls else 0), minf(want.y, maxf(cap, Kit.px(120))))


## A frame clicks go through (`ig`): no panel, nothing takes the mouse, drawn faint as Factorio's
## watermarks are; one the size of the screen (`fs`, Space Exploration's version line) puts its
## contents in the bottom-right corner, as its own style does.
func _pass_through(e: Dictionary, depth: int) -> Control:
	var content := _box(str(e.get("d", "horizontal")))
	_children(content, e, depth)
	content.modulate = Color(1, 1, 1, 0.5)
	for c in content.find_children("*", "Control", true, false):
		(c as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not e.get("fs", false):
		return content
	var full := Control.new()
	full.mouse_filter = Control.MOUSE_FILTER_IGNORE
	full.set_meta("full_screen", true)
	full.add_child(content)
	return full


## The largest height the style allows (pixels at UI scale 1, 0 for none).
static func _max_height(e: Dictionary) -> int:
	var sz = e.get("sz")
	return int(sz[3]) if sz is Array and (sz as Array).size() == 4 else 0


## Factorio lays a window out by its elements' styles: their size limits (`sz`: min and max width,
## min and max height at UI scale 1) and whether they stretch (`hs`, `vs`). Minimum sizes become this
## copy's; a fixed width or height (min = max) too, a top-level window's height no taller than
## Zenith's window (it scrolls then); stretching fills the parent's room.
func _apply_style(node: Control, e: Dictionary, depth: int) -> void:
	var sz = e.get("sz")
	if sz is Array and (sz as Array).size() == 4:
		var min_w := float(sz[0])
		var min_h := float(sz[2])
		var max_w := float(sz[1])
		var max_h := float(sz[3])
		var w: float = Kit.px(min_w) if min_w > 0.0 else 0.0
		var h: float = Kit.px(min_h) if min_h > 0.0 else 0.0
		if depth == 0 and h > 0.0:
			h = minf(h, get_viewport_rect().size.y - Kit.px(80))
		node.custom_minimum_size = Vector2(maxf(node.custom_minimum_size.x, w), maxf(node.custom_minimum_size.y, h))
		if max_w > 0.0 and node is Label and (node as Label).autowrap_mode == TextServer.AUTOWRAP_OFF and max_w == min_w:
			(node as Label).clip_text = true
	if e.get("hs", false):
		node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if e.get("vs", false):
		node.size_flags_vertical = Control.SIZE_EXPAND_FILL
