extends PanelContainer
## The Model packs window (M7; the main menu, the in-game Esc menu, Settings), Minecraft's resource
## packs screen for models (model_packs.gd), about 90% of the screen in three columns by task. Left,
## the packs: Selected (on, the top one winning where two have a model of one name) ordered with up
## and down, the arrow on a row moving it to Available (off) under them and back; every pack moves
## and switches, Placeholders and Factorio (the install's pictures, greyed without one) too. Each row has the pack's picture (pack.json's "icon_image", else pack.png, else its
## "icon" model, else its first model), name and model count, pack.json's lines in its tooltip.
## Middle, a click on a pack (its row turns Factorio's selected orange) lists its models in tabs:
## Models (every entity model, by family: a prototype's model with its variants, ModelPacks.family),
## Items, Icons and Other (empty for now: room for other kinds of pack content); the search box
## filters the open tab, in as many columns as fit, the list filled a slice a frame (FILL_BUDGET_USEC)
## with "Loading... N / M" over it until it is whole. Right, a click on one shows it
## turning (model_preview.gd), which pack's version is in use, every pack's version of it to look at,
## and takes it from the pack shown whatever the order (settings.cfg [model_packs] choices) or gives
## it back to the order; with none clicked, the listed pack's details. Reset choices clears every one.
## The Factorio pack (ModelPacks.FACTORIO_ID: the player's install, no files of its own) lists its
## entities' pictures in Models (sprite_standins.gd's cards, shown face on, their directions in the
## variant picker), the install's items in Items (icon cards, as items without a model lie on belts) and
## its icons in Icons (items, entities, fluids, recipes, technologies, signals); its card stands beside
## the other packs' wherever both have one.
##
## Everything applies at once: a change of order or switch finds the packs again
## (ModelLibrary.apply_packs; a zip turned on is unpacked first), a choice makes that family's
## models again (apply_choices), and in a game the world builds the chunks drawing them again
## (world.gd models_changed). Moving things (trains, robots, creatures) and inserter arms keep the
## models they have until they are made again (a restart at the latest): the note says so in a game.
## Controls are named for tests: "Available", "Selected", "pack-<id>" (its "title", "count", "add",
## "remove", "up", "down"), "AvailableNone", "OpenFolder", "Tabs" ("PackName", "TabModels", "TabItems",
## "TabIcons", "TabOther"), "Models", "ModelsLoading", "model-<family>", "icon-<key>" (the Icons tab's, "/" as "_"),
## "IconCompare" (its "PackIcon", "FactorioIcon" and their captions), "EmptyNote", "Search",
## "Preview", "PreviewTools" (its corner's "PlayAnim", "Speaker"), "PackDetails", "Versions" (a
## "version-<pack id>" card each: "InUseTag", View "show-<pack id>", Select "use-<pack id>"),
## "UseOrder", "ResetChoices", "Note"; the columns "PacksColumn", "ModelsColumn", "PreviewColumn".

signal closed

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const MenuKit := preload("res://scripts/menu/menu_kit.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const Sfx := preload("res://scripts/fx/sfx.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const ModelPreview := preload("res://scripts/ui/factorio/model_preview.gd")
const GuiAssets := preload("res://scripts/ui/factorio/gui_assets.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const ModFiles := preload("res://scripts/world/mod_files.gd")
const SpriteStandins := preload("res://scripts/world/sprite_standins.gd")
const ModGraphics := preload("res://scripts/world/mod_graphics.gd")
const PackCheck := preload("res://scripts/world/pack_check.gd")
const Looks := preload("res://scripts/world/looks.gd")

## world.gd while a game runs (its drawn chunks are built again on a change), else null.
var world = null
## The pack whose models are listed first ("" the top one).
var selected_pack := ""
## The family shown first ("" none).
var selected_family := ""
## The item shown in the preview (the Items tab), "" none; a family and an item aren't shown both.
var selected_item := ""

var _packs: Array = []  # ModelPacks.listed: in their order
var _available: VBoxContainer
var _selected: VBoxContainer
var _models: GridContainer
var _models_title: Label
var _search: LineEdit
var _preview: ModelPreview
var _info: VBoxContainer
var _note: Label
var _models_scroll: ScrollContainer
var _info_scroll: ScrollContainer
var _available_frame: Control  # Available's list, hidden while every pack is in use
var _available_none: Label  # what to do for more packs, in its place
var _shown_pack := ""  # whose version of the family the preview shows
var _variant := ""  # the family's variant the preview shows ("" its main model); display only
var _play_button: Button  # the preview's corner: Play animation / Stop animation
var _speaker_button: Button  # and the building's sound
static var sound_choice := true  # the speaker: on by default, the player's off kept for the session (not saved)
var _credit: Label  # the preview's top left: the shown pack's credit ("© Vasillo · used with permission")
var _unpacking: Label = null  # the models list's "Unpacking ..." line while the listed zip is unpacked
var _icon_queue: Array = []  # [button, family] whose icon isn't cached yet, loaded a few a frame
var _icons_hidden := false  # the models' column too narrow for a name and its icon both
var _tab := "models"  # the middle column's open tab (TABS), kept while the window is open
var _tab_buttons := {}  # tab id -> its Button
const CARD_PAD := 6  # a version card's inner margin, every side (Kit.px: scaled with the UI)
const ROW_PAD := 4  # a pack row's sides
const TAB_GAP := 4  # between the middle column's tabs
const CARD_TEXT_ROOM := 96  # the least a card's name and tag keep beside its buttons, else the buttons go under them
var _icon := ""  # the Icons tab's icon shown: its key in the pack ("iron-plate", "fluid/water"), "" none
var _icon_shown_pack := ""  # whose version of it is shown
var _icon_view: Control  # the pack's icon and Factorio's side by side, over the 3D preview in the Icons tab
var _loading: Label  # "Loading... N / M" in the list's corner while the Models tab fills
var _fill: Dictionary = {}  # the Models tab's fill under way: pack, families, names, at ({} none)
var fill_slice_max_usec := 0  # the longest slice a fill took (tests)
static var _family_cache := {}  # [ModelPacks.version, the packs] -> {family: every pack's model names, sorted}
static var _family_cache_key: Array = []
static var _pack_families := {}  # pack id -> [version, model count, families_of]
var _pack_pictures := {}  # a pack's picture's key -> [texture or null], read once while the window is open
static var _pack_icon_textures := {}  # an icon file -> its texture (the window's own; the UI's go by the order)
var _factorio_icon_queue: Array = []  # [button, icon key] of the Factorio pack's Icons tab, read a few a frame
static var _factorio_icons := {}  # icon key -> Factorio's own texture (or null), this graphics list's
static var _factorio_icons_generation := -1
static var _factorio_keys: Array = []  # the install's icon keys, sorted by kind then name
static var _factorio_keys_generation := -1
## The Factorio pack's icon kinds, in the order the Icons tab lists them (an item's key is its bare name).
const FACTORIO_ICON_KINDS := ["item", "entity", "fluid", "recipe", "technology", "virtual-signal"]

## The middle column's tabs: [id, label]. Models: the pack's entity models; Items and Icons: its
## items and icons (_fill_items_tab, _fill_icons_tab); Other: kept for kinds of pack content to come.
const TABS := [["models", "Models"], ["items", "Items"], ["icons", "Icons"], ["other", "Other"]]

## Family buttons' icons are drawn this many pixels across (at UI scale 1); a family without one
## gets a clear square of the same size, so every name starts at the same place.
const FAMILY_ICON := 24
## The longest a frame spends loading family icons that aren't cached yet.
const ICON_BUDGET_USEC := 3000
## The longest a frame spends adding the Models tab's buttons: a pack of 350 families comes in over a
## few frames rather than holding one frame for half a second.
const FILL_BUDGET_USEC := 2500
static var _blank_icons := {}  # pixels across -> the clear square


func _ready() -> void:
	theme_type_variation = "FFrame"
	name = "ModelPacksWindow"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Kit.px(8))
	add_child(box)
	var bar := Kit.title_bar("Model packs", true)
	box.add_child(bar)
	(bar.get_child(bar.get_child_count() - 1) as Button).pressed.connect(_close)
	# Three columns by task: the packs and their order, the listed pack's models, the one chosen.
	var columns := HBoxContainer.new()
	columns.name = "Columns"
	columns.add_theme_constant_override("separation", Kit.px(8))
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(columns)
	columns.add_child(_packs_column())
	columns.add_child(_models_column())
	columns.add_child(_preview_column())
	# The footer: Factorio's back button, the line about what is in use, and Reset choices.
	var row: Array = MenuKit.dialog_buttons("Back", "")
	var foot: HBoxContainer = row[0]
	foot.name = "Footer"
	box.add_child(foot)
	(row[1] as Button).pressed.connect(func() -> void:
		Sfx.play_ui("gui-back")
		_close())
	var filler: Node = foot.get_child(1)  # the dialog row's drag space: the note takes its place
	foot.remove_child(filler)
	filler.queue_free()
	_note = _wrapped("")
	_note.name = "Note"
	_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_note.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	foot.add_child(_note)
	var reset := MenuKit.button("Reset choices")
	reset.name = "ResetChoices"
	reset.tooltip_text = "Every model from the packs' order again"
	reset.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	reset.pressed.connect(func() -> void:
		Sfx.play_ui("gui-click")
		reset_choices())
	foot.add_child(reset)
	get_viewport().size_changed.connect(_fit_screen)
	_fit_screen()
	_refresh()


## The share of the screen the window takes, and the least it takes (GUI pixels) where the screen
## has room for that.
const SCREEN_SHARE := 0.9
const MIN_SIZE := Vector2(760, 420)


## About 90% of the screen, centred by the overlay, never past the screen's edges.
func _fit_screen() -> void:
	var screen := get_viewport().get_visible_rect().size
	var want := (screen * SCREEN_SHARE).max(Kit.pxv(MIN_SIZE.x, MIN_SIZE.y)).min(screen)
	custom_minimum_size = want.floor()


## Left, narrow: Selected in order (top wins), Available under it, Open folder.
func _packs_column() -> Control:
	var column := VBoxContainer.new()
	column.name = "PacksColumn"
	column.add_theme_constant_override("separation", Kit.px(4))
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_stretch_ratio = 1.0
	column.custom_minimum_size.x = Kit.px(250)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", Kit.px(8))
	column.add_child(top)
	var heading := Kit.label("Selected", "FHeading")
	heading.tooltip_text = "In use, the higher winning. ◀ takes one out; ▲ ▼ order them."
	heading.mouse_filter = Control.MOUSE_FILTER_PASS
	top.add_child(heading)
	var wins := Kit.label("the top one wins")
	wins.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	wins.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wins.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	wins.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(wins)
	_selected = _pack_list(column, "Selected", true)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", Kit.px(8))
	column.add_child(head)
	var title := Kit.label("Available", "FHeading")
	title.tooltip_text = "Packs not in use. ▶ adds one on top of Selected."
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(title)
	var open := MenuKit.button("Open folder")
	open.name = "OpenFolder"
	open.tooltip_text = "The models folder: drop a .zip or a folder of models in it"
	open.pressed.connect(func() -> void:
		Sfx.play_ui("gui-click")
		var dir := _folder()
		DirAccess.make_dir_recursive_absolute(dir)
		OS.shell_open(dir))
	head.add_child(open)
	_available = _pack_list(column, "Available", false)
	_available_frame = _available.get_parent().get_parent()
	_available_none = _wrapped("Every pack is in use. Drop a .zip or a folder of models in the models folder (Open folder) for more.")
	_available_none.name = "AvailableNone"
	_available_none.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	column.add_child(_available_none)
	return column


## Middle: the listed pack's models, the search box on top.
func _models_column() -> Control:
	var column := VBoxContainer.new()
	column.name = "ModelsColumn"
	column.add_theme_constant_override("separation", Kit.px(4))
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_stretch_ratio = 1.25
	column.custom_minimum_size.x = Kit.px(200)
	# The listed pack's name, then Factorio's tabs (style.lua's tab and tab_selected, as Settings
	# draws them); in a narrow column the tabs go on to a second line rather than being cut.
	var tabs := HFlowContainer.new()
	tabs.name = "Tabs"
	tabs.add_theme_constant_override("h_separation", Kit.px(TAB_GAP))
	tabs.add_theme_constant_override("v_separation", Kit.px(2))
	column.add_child(tabs)
	_models_title = Kit.label("", "FHeading")
	_models_title.name = "PackName"
	_models_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var name_pad := MarginContainer.new()
	name_pad.add_theme_constant_override("margin_right", Kit.px(8))
	name_pad.add_child(_models_title)
	tabs.add_child(name_pad)
	for t: Array in TABS:
		var b := Button.new()
		b.text = str(t[1])
		b.name = "Tab" + str(t[1]).replace(" ", "")
		b.set_meta("tab", t[0])
		b.theme_type_variation = "FTab"
		b.toggle_mode = true
		b.button_pressed = t[0] == _tab
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Kit.pxv(0, 32)
		b.add_theme_font_override("font", Kit.font("bold"))
		var id := str(t[0])
		b.pressed.connect(func() -> void:
			Sfx.play_ui("gui-tab")
			open_tab(id))
		tabs.add_child(b)
		_tab_buttons[id] = b
	_search = MenuKit.textbox("", "Search")
	_search.name = "Search"
	_search.custom_minimum_size.x = Kit.px(120)
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(func(_t: String) -> void: _fill_models())
	column.add_child(_search)
	var deep: Array = Kit.deep_scroll(Kit.pxv(0, 120))
	(deep[0] as Control).size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(deep[0])
	_models_scroll = deep[1]
	_models_scroll.resized.connect(_fit_model_columns)
	_models = GridContainer.new()
	_models.name = "Models"
	_models.columns = 2
	_models.add_theme_constant_override("h_separation", Kit.px(2))
	_models.add_theme_constant_override("v_separation", Kit.px(2))
	_models.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_models_scroll.add_child(_models)
	_loading = Kit.label("", "")
	_loading.name = "ModelsLoading"
	_loading.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	_loading.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_loading.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_loading.offset_right = -Kit.px(18)  # clear of the scroll bar
	_loading.offset_top = Kit.px(4)
	_loading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_loading.visible = false
	# Over the list (a PanelContainer fills each child): a layer as big as the list, the line in its corner.
	var over := Control.new()
	over.name = "ModelsOverlay"
	over.mouse_filter = Control.MOUSE_FILTER_IGNORE
	over.add_child(_loading)
	(deep[0] as Control).add_child(over)
	return column


## Right, wide: the model turning as large as fits, what is shown and in use, the packs' versions,
## the choice; the listed pack's details while no model is chosen.
func _preview_column() -> Control:
	var right := Kit.panel("FShallowFrame")
	right.name = "PreviewColumn"
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 1.9
	right.custom_minimum_size.x = Kit.px(250)
	var pad := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, Kit.px(8))
	right.add_child(pad)
	var side_box := VBoxContainer.new()
	side_box.add_theme_constant_override("separation", Kit.px(6))
	pad.add_child(side_box)
	var frame := Kit.panel("FDeepFrame")
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side_box.add_child(frame)
	_preview = ModelPreview.new()
	_preview.name = "Preview"
	_preview.interactive = true  # drag to turn, wheel to zoom, double click to reset
	_preview.custom_minimum_size = Kit.pxv(160, 120)
	frame.add_child(_preview)
	frame.add_child(_icon_compare())
	frame.add_child(_preview_tools())
	frame.add_child(_preview_credit())
	frame.resized.connect(_fit_credit)
	# Under it what is shown, in a box as tall as its lines up to half the column, scrolling past
	# that (a long description on a small screen), so the preview keeps the rest.
	_info_scroll = ScrollContainer.new()
	_info_scroll.name = "InfoScroll"
	_info_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_info_scroll.focus_mode = Control.FOCUS_NONE
	side_box.add_child(_info_scroll)
	_info = VBoxContainer.new()
	_info.name = "Info"
	_info.add_theme_constant_override("separation", Kit.px(4))
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info_scroll.add_child(_info)
	_info.minimum_size_changed.connect(_fit_info)
	side_box.resized.connect(_fit_info)
	return right


func _fit_info() -> void:
	var column := _info_scroll.get_parent() as Control
	_info_scroll.custom_minimum_size.y = minf(_info.get_combined_minimum_size().y, floorf(column.size.y * 0.5))


## A label that wraps to the width its container gives it.
static func _wrapped(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.custom_minimum_size.x = Kit.px(60)
	return l


## While a zip is being unpacked: its progress under its models' title, and the lists again once
## its models are in.
func _process(_delta: float) -> void:
	_fill_step()
	_load_queued_icons()
	_load_factorio_icons()
	_update_play_row()
	if not _packs.any(func(p: Dictionary) -> bool: return bool(p["unpacking"]) or bool(p["checking"])):
		return
	if ModelPacks.is_ready():
		_refresh()
	elif _unpacking != null:
		_unpacking.text = unpacking_line(_pack_by_id(selected_pack))


## "Unpacking Zenith... 12 of 41 files" for a zip pack the worker is unpacking.
static func unpacking_line(p: Dictionary) -> String:
	var at := ModelPacks.progress(str(p["id"]))
	var text := "Unpacking %s..." % p["title"]
	if int(at[1]) > 0:
		text += " %d of %d files" % [int(at[0]), int(at[1])]
	return text + " Its models come once it is unpacked."


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.physical_keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_close()


func _close() -> void:
	closed.emit()


# --- the packs ---------------------------------------------------------------------------------

## A list of packs in a deep frame, the Selected one taking the column's room (`grow`); returns its box.
func _pack_list(column: Container, box_name: String, grow: bool) -> VBoxContainer:
	var deep: Array = Kit.deep_scroll(Kit.pxv(0, 96 if grow else 52))
	(deep[0] as Control).size_flags_vertical = Control.SIZE_EXPAND_FILL if grow else Control.SIZE_FILL
	column.add_child(deep[0])
	var list := VBoxContainer.new()
	list.name = box_name
	list.add_theme_constant_override("separation", Kit.px(2))
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	deep[1].add_child(list)
	return list


func _refresh() -> void:
	_packs = ModelPacks.listed(_folder(), ModelLibrary._pack_ids(Settings, "order"), ModelLibrary._pack_ids(Settings, "off"))
	if selected_pack == "" or _pack_by_id(selected_pack).is_empty():
		selected_pack = str(_packs[0]["id"]) if not _packs.is_empty() else ""
	for list: VBoxContainer in [_available, _selected]:
		for c in list.get_children():
			list.remove_child(c)
			c.queue_free()
	var movable: Array = []  # the packs in use that move (not a --models one)
	for p: Dictionary in _packs:
		if _is_on(p) and not ModelPacks.fixed(p):
			movable.append(p)
	for p: Dictionary in _packs:
		if not _is_on(p):
			_available.add_child(_pack_row(p, false, -1, 0))
	for p: Dictionary in _packs:
		if _is_on(p):
			_selected.add_child(_pack_row(p, true, movable.find(p), movable.size()))
	# With every pack in use Available folds to a line saying how to add one; else it shows up to
	# three rows before it scrolls, Selected keeping the rest of the column.
	var off := _available.get_child_count()
	_available_frame.visible = off > 0
	_available_none.visible = off == 0
	(_available.get_parent() as Control).custom_minimum_size.y = Kit.px(50 * mini(maxi(off, 1), 3))
	_fill_models()
	_show_family()
	_say()


func _is_on(p: Dictionary) -> bool:
	return bool(p["on"]) and str(p["problem"]) == ""


func _pack_by_id(id: String) -> Dictionary:
	for p: Dictionary in _packs:
		if p["id"] == id:
			return p
	return {}


## One pack's row: its picture, name and model count (the rest in its tooltip), and its arrows.
func _pack_row(p: Dictionary, on: bool, at: int, of: int) -> Control:
	var id := str(p["id"])
	var row := PanelContainer.new()
	row.name = "pack-" + id.replace(":", "_").replace("/", "_")
	row.set_meta("pack", id)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.gui_input.connect(func(event: InputEvent) -> void:
		var mb := event as InputEventMouseButton
		if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			Sfx.play_ui("gui-click")
			select_pack(id))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", Kit.px(8))
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(h)
	h.add_child(_pack_picture(p))
	var text := VBoxContainer.new()
	text.add_theme_constant_override("separation", 0)
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(text)
	var title := Kit.label(str(p["title"]))
	title.name = "title"
	title.add_theme_font_override("font", Kit.font("bold"))
	# Wrapped, not cut: "Wube3DP (Adapted)" in a narrow column goes on two lines.
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.custom_minimum_size.x = Kit.px(40)
	text.add_child(title)
	# The count on the row; the rest of pack_line (where, version, author, licence) and the
	# description in its tooltip, and in the details on the right once it is listed.
	var n := int(p["count"])
	var count := Kit.label("%d model%s" % [n, "" if n == 1 else "s"] + (", unpacking" if bool(p["unpacking"]) else "")
		+ (", new" if bool(p.get("new", false)) else ""))
	count.name = "count"
	count.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	count.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	count.custom_minimum_size.x = Kit.px(40)
	text.add_child(count)
	var shading_text := shading_line(p)
	if shading_text != "":
		var shading := Kit.label(shading_text)
		shading.name = "shading"
		shading.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		shading.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		shading.custom_minimum_size.x = Kit.px(40)
		text.add_child(shading)
	var description := str((p["info"] as Dictionary).get("description", ""))
	row.tooltip_text = pack_line(p) + ("\n" + description if description != "" else "") \
		+ ("\n" + PackCheck.UNCHECKED if bool(p["unchecked"]) else "")
	if ModelPacks.refused(p):
		text.add_child(refusal_card(p))
	elif bool(p["checking"]):
		var wait := _wrapped(PackCheck.CHECKING)
		wait.name = "checking"
		wait.mouse_filter = Control.MOUSE_FILTER_IGNORE
		wait.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		text.add_child(wait)
	elif str(p["problem"]) != "":
		var why := _wrapped("Left out: %s" % p["problem"])
		why.name = "problem"
		why.mouse_filter = Control.MOUSE_FILTER_IGNORE
		why.add_theme_color_override("font_color", Kit.RED_TEXT)
		text.add_child(why)
	if ModelPacks.fixed(p):
		var locked := Kit.label("this run")
		locked.name = "fixed"
		locked.tooltip_text = "Given with --models: on top for this run"
		locked.mouse_filter = Control.MOUSE_FILTER_PASS
		locked.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		locked.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(locked)
		_mark_row(row, id == selected_pack)
		return row
	_mark_row(row, id == selected_pack)
	if not on:
		var add := _arrow("add", "▶", "Use this pack (on top of Selected)")
		add.disabled = str(p["problem"]) != ""
		add.pressed.connect(func() -> void: set_pack_on(id, true))
		h.add_child(add)
		return row
	var arrows := HBoxContainer.new()
	arrows.name = "arrows"
	arrows.add_theme_constant_override("separation", Kit.px(2))
	arrows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(arrows)
	var remove := _arrow("remove", "◀", "Stop using this pack")
	remove.pressed.connect(func() -> void: set_pack_on(id, false))
	arrows.add_child(remove)
	var up := _arrow("up", "▲", "Above the pack over it")
	up.disabled = at <= 0
	up.pressed.connect(func() -> void: move_pack(id, -1))
	arrows.add_child(up)
	var down := _arrow("down", "▼", "Under the pack below it")
	# The last pack in use can't go further down.
	down.disabled = at < 0 or at >= of - 1
	down.pressed.connect(func() -> void: move_pack(id, 1))
	arrows.add_child(down)
	return row


## A pack refused for holding copies of Factorio's files (pack_check.gd), in Factorio's red: why,
## and "Show the files" listing every copy (paths in the pack).
static func refusal_card(p: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.name = "refused"
	box.add_theme_constant_override("separation", Kit.px(2))
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var copies: Array = p["copies"]
	var head := _wrapped(PackCheck.REFUSED)
	head.name = "problem"
	head.add_theme_font_override("font", Kit.font("bold"))
	var why := _wrapped(PackCheck.detail(copies))
	why.name = "why"
	var files := _wrapped("\n".join(PackedStringArray(copies)))
	files.name = "files"
	files.visible = false
	for l: Label in [head, why, files]:
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.add_theme_color_override("font_color", Kit.RED_TEXT)
	var show := MenuKit.button("Show the files")
	show.name = "show-files"
	show.toggle_mode = true
	show.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var flip := func(on: bool) -> void:
		files.visible = on
		show.text = "Hide the files" if on else "Show the files"
	show.toggled.connect(flip)
	for c: Control in [head, why, show, files]:
		box.add_child(c)
	return box


## A small button with Factorio's dropdown arrow turned to point its way (`glyph` without the
## install's GUI pictures).
func _arrow(button_name: String, glyph: String, tip: String) -> Button:
	var b := Button.new()
	b.name = button_name
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Kit.pxv(28, 28)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var arrow := GuiAssets.core_sprite("icons/mip/dropdown.png")
	var image: Image = arrow.get_image().duplicate() as Image if arrow != null and arrow.get_image() != null else null
	if image == null:
		b.text = glyph
		return b
	image.clear_mipmaps()
	match button_name:
		"up":
			image.flip_y()
		"add":
			image.rotate_90(COUNTERCLOCKWISE)
		"remove":
			image.rotate_90(CLOCKWISE)
	image.resize(Kit.px(16), Kit.px(16), Image.INTERPOLATE_LANCZOS)
	b.icon = ImageTexture.create_from_image(image)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return b


## A pack's picture: its pack.json "icon_image" (pack_image), else its pack.png (or icon.png), else
## its pack.json "icon" model or its first, still.
func _pack_picture(p: Dictionary) -> Control:
	return pack_picture(p, Kit.pxv(36, 36), _pack_pictures, _is_on(p))


## The pack's texture from `cache` (reading pack.json "icon_image", pack.png or icon.png once), or null.
static func pack_texture(p: Dictionary, cache: Dictionary) -> Texture2D:
	var root := str(p["root"])
	# Read once a window session's packs: the files, and a zip not unpacked yet listed (Default.zip's
	# directory), were read again on every refresh (each order change).
	var key := "%s|%s|%s|%s" % [p["id"], root, p["source"], (p["info"] as Dictionary).get("icon_image", "")]
	if ModelPacks.refused(p):
		cache[key] = [null]  # nothing of a refused pack is read, its pictures neither
	if not cache.has(key):
		var image := pack_image(p)
		for file in ["pack.png", "icon.png"]:
			if image == null and root != "":
				image = _image_at(root.path_join(file))
		cache[key] = [ImageTexture.create_from_image(image) if image != null else null]
	return (cache[key] as Array)[0] as Texture2D


## The `<model>@<pack>` name a pack without a picture uses for its thumbnail ("" if none or off).
static func pack_icon_model(p: Dictionary, cache: Variant = null) -> String:
	var id := str(p.get("id", ""))
	if id == "":
		return ""
	if cache is Dictionary and (cache as Dictionary).has(id):
		return str((cache as Dictionary)[id])
	var models: Dictionary = p["models"]
	var icon := str((p["info"] as Dictionary).get("icon", "")).to_lower()
	if not models.has(icon):
		var names := models.keys()
		names.sort()
		icon = str(names[0]) if not names.is_empty() else ""
	var out := icon + "@" + id if icon != "" and not ModelPacks.pack(id).is_empty() else ""
	if cache is Dictionary:
		(cache as Dictionary)[id] = out
	return out


## The pack's picture as a pack row draws it (also the entity info's pack symbol, N8): `cache` keeps
## the pictures read (key -> [texture or null]); `live` lets a pack without a picture show its model.
static func pack_picture(p: Dictionary, size: Vector2, cache: Dictionary, live: bool) -> Control:
	var texture := pack_texture(p, cache)
	if texture != null:
		var t := TextureRect.new()
		t.name = "image"
		t.texture = texture
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		t.custom_minimum_size = size
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return t
	var shown := ModelPreview.new()
	shown.name = "picture"
	shown.turning = false
	shown.custom_minimum_size = size
	var icon_model := pack_icon_model(p) if live else ""
	if icon_model != "":
		shown.show_model.call_deferred(icon_model)
	else:
		shown.viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	return shown


## pack.json's "icon_image" as a picture, or null (not set, not there, not a picture): a file in
## the pack, from its top or the folder its pack.json is in (a zip not unpacked yet is read as it
## is), or "factorio:<path>" in the player's Factorio install ("factorio:data/core/graphics/
## wube-logo.png", the path from the install's folder or its data folder), so a pack can show a
## picture of Wube's without carrying it (nothing of Wube's is committed or shipped).
static func pack_image(p: Dictionary) -> Image:
	var want := str((p["info"] as Dictionary).get("icon_image", "")).strip_edges().replace("\\", "/")
	if want == "":
		return null
	if want.begins_with("factorio:"):
		var path := ModelPacks.safe_entry(want.trim_prefix("factorio:"))
		var data := ItemIcons.find_data_dir()
		if path == "" or data == "":
			return null
		var image := _image_at(data.get_base_dir().path_join(path))
		return image if image != null else _image_at(data.path_join(path.trim_prefix("data/")))
	var rel := ModelPacks.safe_entry(want)
	var root := str(p["root"])
	if rel == "":
		return null
	if root != "" and (root.begins_with("res://") or DirAccess.dir_exists_absolute(root)):
		var image := _image_at(root.path_join(rel))
		if image != null:
			return image
		for sub in DirAccess.get_directories_at(root):
			image = _image_at(root.path_join(sub).path_join(rel))
			if image != null:
				return image
		return null
	if str(p["kind"]) != "zip":
		return null
	var entries := ModFiles.zip_entries(str(p["source"]))
	for entry: String in entries:
		var at := ModelPacks.safe_entry(entry)
		if at == rel or (at.ends_with("/" + rel) and at.count("/") == rel.count("/") + 1):
			var f := FileAccess.open(str(p["source"]), FileAccess.READ)
			if f == null:
				return null
			var bytes := ModFiles.zip_entry(f, entries[entry])
			f.close()
			return _image_from(bytes, rel.get_extension())
	return null


## A picture file (res:// through its import, so an exported game has it too), or null.
static func _image_at(path: String) -> Image:
	if path.begins_with("res://"):
		if not ResourceLoader.exists(path):
			return null
		var t := load(path) as Texture2D
		var image: Image = t.get_image() if t != null else null
		return image if image != null and not image.is_empty() else null
	if not FileAccess.file_exists(path):
		return null
	return _image_from(FileAccess.get_file_as_bytes(path), path.get_extension())


static func _image_from(bytes: PackedByteArray, ext: String) -> Image:
	var image := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	match ext.to_lower():
		"png":
			err = image.load_png_from_buffer(bytes)
		"jpg", "jpeg":
			err = image.load_jpg_from_buffer(bytes)
		"webp":
			err = image.load_webp_from_buffer(bytes)
	return image if err == OK and not image.is_empty() else null


## The line on a pack's card saying how its textured models are drawn (pack.json "shading",
## model_packs.gd shading()); "" for the Factorio pack (pictures, no models).
static func shading_line(p: Dictionary) -> String:
	if ModelPacks.is_sprite_pack(p):
		return ""
	var mixed := not ((p.get("info", {}) as Dictionary).get("shading_models", {}) as Dictionary).is_empty()
	if mixed:
		return "Shading: set per model (PBR or Factorio's)" + ("" if Looks.pack_shading() else ", Factorio's in Settings")
	if ModelPacks.shading(p) == "pbr":
		return "Shading: as its files say (PBR)" + ("" if Looks.pack_shading() else ", Factorio's in Settings")
	return "Shading: Factorio's"


## Under a pack's name: how many models, where it is, its pack.json's version, author and licence.
static func pack_line(p: Dictionary) -> String:
	var info: Dictionary = p["info"]
	var parts := PackedStringArray()
	var n := int(p["count"])
	parts.append("%d model%s" % [n, "" if n == 1 else "s"] + (", unpacking" if bool(p["unpacking"]) else ""))
	parts.append(ModelPacks.where(p))
	if str(info.get("version", "")) != "":
		parts.append("version " + str(info["version"]))
	if str(info.get("author", "")) != "":
		parts.append("by " + str(info["author"]))
	if str(info.get("licence", "")) != "":
		parts.append(str(info["licence"]))
	if bool(p.get("new", false)):
		parts.append("new")
	return ", ".join(parts)


## Opens on a pack's models with one family shown, that pack's version of it (the entity info's pack
## symbol, N8): before the window is in the tree it starts there, after it moves there.
func start_on(pack: String, fam: String) -> void:
	selected_pack = ModelPacks.canonical_id(pack)
	selected_family = fam
	selected_item = ""
	_shown_pack = selected_pack
	_variant = ""
	if is_inside_tree() and _models != null:
		select_pack(selected_pack)
		select_family(fam, selected_pack)


## Lists a pack's models.
func select_pack(id: String) -> void:
	selected_pack = id
	for list: VBoxContainer in [_available, _selected]:
		for row in list.get_children():
			if row is PanelContainer:
				_mark_row(row as PanelContainer, str(row.get_meta("pack", "")) == id)
	_fill_models()
	_show_family()


static var _row_styles := {}  # [state, ui pixels] -> the row's panel style


## list_box_item's look for a pack row ("selected", "hover" or "normal": the family buttons'
## FListItemSelected normal, FListItem hover and normal), with narrow sides (the button style's
## room for its text would cut the count in a narrow column). The copy keeps the style's own
## pictures (LayeredStyle's layers, exported so duplicate() takes them).
## `card`: a version card's, with CARD_PAD all round (its buttons kept off the frame's edges).
static func _row_style(state: String, card := false) -> StyleBox:
	var key := [state, Kit.px(100), card]
	if not _row_styles.has(key):
		var source := MenuKit.theme().get_stylebox("hover" if state == "hover" else "normal", "FListItemSelected" if state == "selected" else "FListItem")
		var box := source.duplicate() as StyleBox
		# Narrow sides, but not none: the picture and the arrows keep off the frame's edges.
		var side := Kit.px(CARD_PAD if card else ROW_PAD)
		box.set_content_margin(SIDE_LEFT, side)
		box.set_content_margin(SIDE_RIGHT, side)
		box.set_content_margin(SIDE_TOP, Kit.px(CARD_PAD if card else 2))
		box.set_content_margin(SIDE_BOTTOM, Kit.px(CARD_PAD if card else 2))
		_row_styles[key] = box
	return _row_styles[key]


## The listed pack's row in the look of the family grid's selected button (FListItemSelected:
## list_box_item's orange, its dark text), the others the plain dark one, orange under the mouse as
## a list's rows are. A PanelContainer draws its "panel" style, which the FListItem variations (made
## for buttons) don't have, so the button style is put on the panel itself.
func _mark_row(row: PanelContainer, on: bool) -> void:
	row.theme_type_variation = "FListItemSelected" if on else "FListItem"
	row.set_meta("selected", on)
	if not row.has_meta("hover_wired"):
		row.set_meta("hover_wired", true)
		row.mouse_entered.connect(func() -> void: _hover_row(row, true))
		# Leaving for an arrow button inside the row isn't leaving the row.
		row.mouse_exited.connect(func() -> void:
			_hover_row(row, row.get_global_rect().has_point(row.get_global_mouse_position())))
	_paint_row(row, "selected" if on else ("hover" if bool(row.get_meta("hovered", false)) else "normal"))


func _hover_row(row: PanelContainer, over: bool) -> void:
	row.set_meta("hovered", over)
	if not bool(row.get_meta("selected", false)):
		_paint_row(row, "hover" if over else "normal")


## A row's style and its labels' colours: lit (selected or hovered) the button's own text colours
## for that state, else white names, grey counts and a version card's green "In use".
func _paint_row(row: PanelContainer, state: String) -> void:
	row.add_theme_stylebox_override("panel", _row_style(state, bool(row.get_meta("card", false))))
	var lit := state != "normal"
	var lit_color := MenuKit.theme().get_color("font_color" if state == "selected" else "font_hover_color", "FListItemSelected" if state == "selected" else "FListItem")
	for key: String in ["title", "count", "fixed", "words"]:
		var l := row.find_child(key, true, false) as Label
		if l == null:
			continue
		if lit:
			l.add_theme_color_override("font_color", lit_color)
		elif key == "title":
			l.remove_theme_color_override("font_color")
		elif key == "words":
			l.add_theme_color_override("font_color", Kit.GREEN_TEXT)
		else:
			l.add_theme_color_override("font_color", Kit.DISABLED_TEXT)


## Turns a pack on (on top of the packs in use) or off, saved and used at once.
func set_pack_on(id: String, on: bool) -> void:
	Sfx.play_ui("gui-click")
	var p := _pack_by_id(id)
	if p.is_empty() or ModelPacks.fixed(p):
		return
	p["on"] = on
	if on:
		# On top of the packs in use (under a --models pack, which stays first for its run).
		_packs.erase(p)
		var at := 0
		while at < _packs.size() and str(_packs[at]["kind"]) == "arg":
			at += 1
		_packs.insert(at, p)
	_save_order()


## Moves a pack in use one place up (-1) or down (1) among those in use, saved and used at once.
func move_pack(id: String, by: int) -> void:
	Sfx.play_ui("gui-click")
	var on: Array = []
	for p: Dictionary in _packs:
		if _is_on(p) and not ModelPacks.fixed(p):
			on.append(p)
	var p := _pack_by_id(id)
	var at := on.find(p)
	var to := at + by
	if at < 0 or to < 0 or to >= on.size():
		return
	var other: Dictionary = on[to]
	var i := _packs.find(p)
	var j := _packs.find(other)
	_packs[i] = other
	_packs[j] = p
	_save_order()


func _save_order() -> void:
	Settings.set_value("model_packs", "order", ModelPacks.saved_order(_packs))
	Settings.set_value("model_packs", "off", ModelPacks.saved_off(_packs))
	ModelLibrary.apply_packs()
	if world != null:
		world.models_changed([])
	_refresh()


# --- a pack's models ---------------------------------------------------------------------------

## Opens one of the middle column's tabs (TABS' id), kept until the window closes.
func open_tab(id: String) -> void:
	var icons_changed := (_tab == "icons") != (id == "icons")
	_tab = id
	for key: String in _tab_buttons:
		(_tab_buttons[key] as Button).set_pressed_no_signal(key == id)
	_fill_models()
	if icons_changed:
		_show_family()  # the Icons tab shows icons where the others show the model turning


## The open tab's id.
func current_tab() -> String:
	return _tab


## Fills the middle column for the listed pack and the open tab, the search box filtering within it.
func _fill_models() -> void:
	_clear_grid()
	_unpacking = null
	var p := _pack_by_id(selected_pack)
	_models_title.text = "%s:" % p.get("short", p["title"]) if not p.is_empty() else ""
	_models_title.get_parent().visible = not p.is_empty()
	if p.is_empty():
		return
	if bool(p["unpacking"]):
		_models.columns = 1
		_unpacking = _wrapped(unpacking_line(p))
		_unpacking.name = "Unpacking"
		_unpacking.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		_models.add_child(_unpacking)
		return
	if ModelPacks.refused(p) or bool(p["checking"]):
		_models.columns = 1  # nothing of it listed or shown: refused, or not known clean yet
		var note := _wrapped(PackCheck.REFUSED if ModelPacks.refused(p) else PackCheck.CHECKING)
		note.name = "Refused" if ModelPacks.refused(p) else "Checking"
		note.add_theme_color_override("font_color", Kit.RED_TEXT if ModelPacks.refused(p) else Kit.DISABLED_TEXT)
		_models.add_child(note)
		return
	var filter := _search.text.strip_edges().to_lower()
	match _tab:
		"items":
			_fill_items_tab(p, filter)
		"icons":
			_fill_icons_tab(p, filter)
		"other":
			_grid_note("Nothing here yet: room for other kinds of pack content.")
		_:
			_fill_family_tab(p, filter)


## Empties the middle column's grid (and the icons still to load for it).
func _clear_grid() -> void:
	_icon_queue.clear()
	_factorio_icon_queue.clear()
	_fill = {}  # an unfinished fill of another pack, tab or search goes with the grid
	if _loading != null:
		_loading.visible = false
	for c in _models.get_children():
		_models.remove_child(c)
		c.queue_free()


## A line in the middle of the empty grid ("No icons in this pack.").
func _grid_note(text: String) -> Label:
	_models.columns = 1
	var n := _wrapped(text)
	n.name = "EmptyNote"
	n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	n.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	_models.add_child(n)
	return n


## The Items tab: the pack's models of items (on belts, on the ground, in hands; its items/
## folder, ModelPacks.items), each with Factorio's item icon and name; a click shows it turning.
func _fill_items_tab(pack: Dictionary, filter: String) -> void:
	_clear_grid()
	var sprite := ModelPacks.is_sprite_pack(pack)
	var list: Array = factorio_items().map(func(n: String) -> Dictionary: return {"name": n}) if sprite else ModelPacks.items(pack)
	if list.is_empty():
		var later := str(pack["kind"]) == "zip" and int(pack.get("item_count", 0)) > 0
		if sprite and not ModelPacks.factorio_usable():
			_grid_note(ModelPacks.NO_INSTALL + ".")
		else:
			_grid_note("Use the pack to see its items (a zip is unpacked first)." if later else "No items in this pack.")
		return
	var names: Array = []
	for entry: Dictionary in list:
		var item := str(entry["name"])
		var label := Kit.pretty(item)
		if filter == "" or item.contains(filter) or label.to_lower().contains(filter):
			names.append(item)
	if names.is_empty():
		_grid_note("No items in this pack match.")
		return
	_start_fill(pack, names, func(item: String) -> Control: return _item_button(pack, item))


## Fills the grid with `make`'s button for each of `names`, a slice a frame (_fill_step).
func _start_fill(pack: Dictionary, names: Array, make: Callable) -> void:
	_fill = {"pack": pack, "families": {}, "names": names, "at": 0, "make": make}
	_fill_step()


## The install's items (icons.json's and the game's graphics list's), sorted: the Factorio pack's Items.
static func factorio_items() -> Array:
	if not ModelPacks.factorio_usable():
		return []
	var out := {}
	for map: Dictionary in [ItemIcons.index().get("item", {}), ModGraphics.icons.get("item", {})]:
		for n in map:
			out[str(n)] = true
	var names := out.keys()
	names.sort()
	return names


## The install's icon keys ("iron-plate" for an item, "<kind>/<name>" for the rest), by kind then name.
static func factorio_icon_keys() -> Array:
	if not ModelPacks.factorio_usable():
		return []
	if _factorio_keys_generation == ModGraphics.generation and not _factorio_keys.is_empty():
		return _factorio_keys
	var out: Array = []
	for kind: String in FACTORIO_ICON_KINDS:
		var names := {}
		for map: Dictionary in [ItemIcons.index().get(kind, {}), ModGraphics.icons.get(kind, {})]:
			for n in map:
				names[str(n)] = true
		var sorted := names.keys()
		sorted.sort()
		for n: String in sorted:
			out.append(n if kind == "item" else kind + "/" + n)
	_factorio_keys = out
	_factorio_keys_generation = ModGraphics.generation
	return out


## Factorio's own icon for an icon key, read once a graphics list (the Factorio pack's Icons tab).
static func factorio_icon_cached(key: String) -> Texture2D:
	if _factorio_icons_generation != ModGraphics.generation:
		_factorio_icons = {}
		_factorio_icons_generation = ModGraphics.generation
	if not _factorio_icons.has(key):
		_factorio_icons[key] = factorio_icon(key if key.contains("/") else "item/" + key)
	return _factorio_icons[key]


## The Factorio pack's icons not read yet, a few a frame (ICON_BUDGET_USEC).
func _load_factorio_icons(budget := ICON_BUDGET_USEC) -> void:
	var start := Time.get_ticks_usec()
	while not _factorio_icon_queue.is_empty() and Time.get_ticks_usec() - start < budget:
		var job: Array = _factorio_icon_queue.pop_front()
		if is_instance_valid(job[0]):
			var t := factorio_icon_cached(str(job[1]))
			(job[0] as Button).icon = t if t != null else blank_icon()


## One item's button in the Items tab: its icon and name, ✔ when chosen from this pack, dim when
## another pack's is in use.
func _item_button(pack: Dictionary, item: String) -> Button:
	var b := Button.new()
	b.name = "item-" + item
	b.theme_type_variation = "FListItemSelected" if item == selected_item else "FListItem"
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.custom_minimum_size = Kit.pxv(0, 28)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.text = Kit.pretty(item)
	b.set_meta("item", true)
	_set_family_icon(b, item)
	var using: Dictionary = ModelPacks.item_source(item).get("pack", {})
	if ModelPacks.item_choice(item) == pack["id"]:
		b.text = "✔ " + b.text
	if not using.is_empty() and using["id"] != pack["id"]:
		b.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	b.tooltip_text = "%s\n%s" % [item, ("In use: %s's" % using.get("short", using["title"])) if not using.is_empty() else ""]
	var listed := str(pack["id"])
	b.pressed.connect(func() -> void:
		Sfx.play_ui("gui-click")
		select_item(item, listed))
	return b


## The Icons tab: the pack's icons (model_packs.gd: its icons/<name>.png and icons/<kind>/<name>.png),
## each its picture and name; a click shows it large beside Factorio's own (_show_icon). The Factorio
## pack's are the install's (factorio_icon_keys, about 1,600), their pictures read a few a frame.
func _fill_icons_tab(pack: Dictionary, filter: String) -> void:
	_clear_grid()
	var sprite := ModelPacks.is_sprite_pack(pack)
	var keys := factorio_icon_keys() if sprite else ModelPacks.icon_names(pack)
	if keys.is_empty():
		if sprite:
			_grid_note(ModelPacks.NO_INSTALL + ".")
		else:
			_grid_note("Use the pack to see its icons (a zip is unpacked first)." if int(pack.get("icon_count", 0)) > 0
				else "No icons in this pack.")
		return
	var names: Array = []
	for key: String in keys:
		if filter == "" or key.contains(filter) or icon_label(key).to_lower().contains(filter):
			names.append(key)
	if names.is_empty():
		_grid_note("No icons in this pack match.")
		return
	_start_fill(pack, names, func(key: String) -> Control: return _icon_button(pack, key))


func _icon_button(pack: Dictionary, key: String) -> Button:
	var listed := str(pack["id"])
	var sprite := ModelPacks.is_sprite_pack(pack)
	var b := Button.new()
	b.name = "icon-" + key.replace("/", "_")
	b.set_meta("icon_key", key)
	b.theme_type_variation = "FListItemSelected" if key == _icon else "FListItem"
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.custom_minimum_size = Kit.pxv(0, 28)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.expand_icon = false
	b.add_theme_constant_override("icon_max_width", Kit.px(FAMILY_ICON))
	if sprite:
		if _factorio_icon_cached_now(key):
			var t := factorio_icon_cached(key)
			b.icon = t if t != null else blank_icon()
		else:
			b.icon = blank_icon()
			_factorio_icon_queue.append([b, key])
	else:
		var picture := pack_icon_texture(ModelPacks.icon_in(pack, _icon_kind(key), key.get_file()))
		b.icon = picture if picture != null else blank_icon()
	b.text = icon_label(key)
	var using := _icon_in_use(key)
	if ModelPacks.icon_choice(key.get_file()) == listed:
		b.text = "✔ " + b.text
	if not using.is_empty() and using["id"] != listed:
		b.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	var where := ("Factorio's own, from your install" if sprite else "icons/%s.png" % key)
	b.tooltip_text = "%s\n%s" % [where, ("In use: %s's" % using.get("short", using["title"])) if not using.is_empty()
		else "Not in use (the pack is off)"]
	b.pressed.connect(func() -> void:
		Sfx.play_ui("gui-click")
		select_icon(key, listed))
	return b


static func _factorio_icon_cached_now(key: String) -> bool:
	return _factorio_icons_generation == ModGraphics.generation and _factorio_icons.has(key)


## The pack in use whose icon `key` is drawn: a pack's file (ModelPacks.icon_pack), else the Factorio
## pack when it is in use (its install's own); {} for none.
static func _icon_in_use(key: String) -> Dictionary:
	var p := ModelPacks.icon_pack(_icon_kind(key), key.get_file())
	if p.is_empty() and ModelPacks.factorio_on():
		return ModelPacks.pack(ModelPacks.FACTORIO_ID)
	return p


## An icon key's name as the game names it ("Iron plate", "Water (fluid)").
static func icon_label(key: String) -> String:
	var kind := key.get_base_dir()
	var proto := key.get_file()
	var shown := ""
	match kind:
		"entity":
			shown = Kit.entity_name(proto)
		"recipe":
			shown = Kit.recipe_name(proto)
		"technology":
			shown = Kit.tech_name(proto)
		_:
			shown = Kit.pretty(proto)
	if shown == "":
		shown = proto
	return shown + (" (%s)" % kind.replace("-", " ") if kind != "" else "")


## The kind an icon key is looked up as: its own folder's, "item" for a bare one.
static func _icon_kind(key: String) -> String:
	var kind := key.get_base_dir()
	return kind if kind != "" else "item"


## An icon file's texture as the window shows it (a pack's own, whatever the order), cached by file.
static func pack_icon_texture(path: String) -> Texture2D:
	if _pack_icon_textures.has(path):
		return _pack_icon_textures[path]
	var image := ModelPacks.icon_image(path)
	var texture: Texture2D = null
	if image != null:
		image.generate_mipmaps()
		texture = ImageTexture.create_from_image(image)
	_pack_icon_textures[path] = texture
	return texture


## Factorio's own icon for an icon key, from the bridge's graphics list or the install (none without
## either): a bare name's item, else its entity, fluid, technology or recipe of that name.
static func factorio_icon(key: String) -> Texture2D:
	var kind := key.get_base_dir()
	var proto := key.get_file()
	if kind == "item" or kind == "":
		var item := ItemIcons.install_texture(proto)
		if item != null or kind == "item":
			return item
		for k: String in ["entity", "fluid", "technology", "recipe", "virtual-signal"]:
			var t := ItemIcons.install_kind_texture(k, proto)
			if t != null:
				return t
		return null
	return ItemIcons.install_kind_texture(kind, proto)


## Shows an icon of the Icons tab: `pack`'s version (a pack's list passes its own), else the one in use.
func select_icon(key: String, pack := "") -> void:
	_icon = key
	_icon_shown_pack = pack
	for b in _models.get_children():
		if b is Button and b.has_meta("icon_key"):
			(b as Button).theme_type_variation = "FListItemSelected" if str(b.get_meta("icon_key")) == key else "FListItem"
	_show_family()


## Takes icon `key`'s name from `pack` whatever the order ("" back to the order's): settings.cfg
## [model_packs] choices "icon:<name>", every icon drawn from then on (the UI's icon cache is dropped).
func choose_icon(key: String, pack: String) -> void:
	Sfx.play_ui("gui-click")
	var choice_key := ModelPacks.ICON_PREFIX + key.get_file()
	var saved: Variant = Settings.get_value("model_packs", "choices")
	var map: Dictionary = (saved as Dictionary).duplicate() if saved is Dictionary else {}
	if pack == "":
		map.erase(choice_key)
	else:
		map[choice_key] = pack
	Settings.set_value("model_packs", "choices", map)
	ModelLibrary.apply_choices([choice_key])  # no model's family: only the icons follow
	_fill_models()
	_show_family()
	_say()


## The pack's icon and Factorio's side by side, each with its caption, over the 3D preview (hidden
## but in the Icons tab).
func _icon_compare() -> Control:
	var center := CenterContainer.new()
	center.name = "IconCompare"
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.visible = false
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Kit.px(24))
	center.add_child(row)
	for side: Array in [["PackIcon", "PackIconCaption"], ["FactorioIcon", "FactorioIconCaption"]]:
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", Kit.px(6))
		row.add_child(col)
		var pic := TextureRect.new()
		pic.name = side[0]
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.custom_minimum_size = Kit.pxv(128, 128)
		col.add_child(pic)
		var caption := Kit.label("")
		caption.name = side[1]
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		caption.add_theme_color_override("font_color", Kit.CAPTION)
		col.add_child(caption)
	_icon_view = center
	return center


## The Icons tab's right column: the icon shown large beside Factorio's, a card per pack in use with
## that icon (View, Select), and Use the pack order; with none clicked, the pack's details.
func _show_icon() -> void:
	_preview.show_model("")
	var compare_row := _icon_view.get_child(0)
	if _icon == "":
		_icon_view.visible = false
		_set_credit("")
		_pack_details(_pack_by_id(selected_pack))
		var hint := _wrapped("Click an icon to see it beside Factorio's, and to take it from a pack of your choice whatever the order.")
		hint.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		_info.add_child(hint)
		return
	var proto := _icon.get_file()
	var having: Array = []
	var factorio_own := factorio_icon(_icon)
	for p: Dictionary in ModelPacks.active():
		if (p.get("icons", {}) as Dictionary).has(_icon) or (ModelPacks.is_sprite_pack(p) and factorio_own != null):
			having.append(p)
	# The Factorio pack listed while it is off: its icon still shown.
	if _icon_shown_pack == ModelPacks.FACTORIO_ID and factorio_own != null and ModelPacks.pack(ModelPacks.FACTORIO_ID).is_empty():
		having.append(_pack_by_id(ModelPacks.FACTORIO_ID))
	var in_use_id := str(_icon_in_use(_icon).get("id", ""))
	var shown := _icon_shown_pack
	if shown == "" or not having.any(func(p: Dictionary) -> bool: return p["id"] == shown):
		if having.any(func(p: Dictionary) -> bool: return p["id"] == in_use_id):
			shown = in_use_id
		elif having.any(func(p: Dictionary) -> bool: return p["id"] == selected_pack):
			shown = selected_pack
		else:
			shown = str(having[0]["id"]) if not having.is_empty() else ""
	_icon_shown_pack = shown
	var shown_pack := ModelPacks.pack(shown)
	if shown_pack.is_empty():
		shown_pack = _pack_by_id(shown if shown != "" else selected_pack)  # a pack that is off: its icon still shown
	var file := str((shown_pack.get("icons", {}) as Dictionary).get(_icon, ""))
	_icon_view.visible = true
	_set_credit(credit_line(shown_pack))
	var pack_pic := compare_row.find_child("PackIcon", true, false) as TextureRect
	var factorio := factorio_own
	var factorio_pic := compare_row.find_child("FactorioIcon", true, false) as TextureRect
	# The Factorio pack's own icon shown alone, large (beside itself it would be the same picture twice).
	var own := ModelPacks.is_sprite_pack(shown_pack)
	factorio_pic.get_parent().visible = not own
	if own:
		pack_pic.texture = factorio
		(compare_row.find_child("PackIconCaption", true, false) as Label).text = "Factorio's"
	else:
		pack_pic.texture = pack_icon_texture(file) if file != "" else null
		(compare_row.find_child("PackIconCaption", true, false) as Label).text = "%s's" % shown_pack.get("short", shown_pack.get("title", "")) if file != "" else ""
	factorio_pic.texture = factorio
	(compare_row.find_child("FactorioIconCaption", true, false) as Label).text = "Factorio's" if factorio != null else "Factorio's: none (no install)"
	var title := Kit.label(icon_label(_icon), "FHeading")
	title.name = "Family"
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.custom_minimum_size.x = Kit.px(60)
	_info.add_child(title)
	var chosen := ModelPacks.icon_choice(proto)
	var cards := VBoxContainer.new()
	cards.name = "Versions"
	cards.add_theme_constant_override("separation", Kit.px(4))
	_info.add_child(cards)
	for p: Dictionary in having:
		cards.add_child(_version_card(_icon, p, p["id"] == shown, p["id"] == in_use_id, chosen, "icon"))
	var order := MenuKit.button("Use the pack order")
	order.name = "UseOrder"
	order.custom_minimum_size.x = 0
	order.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	order.disabled = chosen == ""
	order.tooltip_text = "From the highest pack in Selected that has it" if chosen != "" else "Already from the pack order: Select a pack's version to take it whatever the order"
	order.pressed.connect(func() -> void: choose_icon(_icon, ""))
	_info.add_child(order)


## The Models tab: the pack's families by name, the search box filtering them. The buttons are added
## a slice a frame (_fill_step), the first slice at once, so a short list is whole straight away and a
## long one (Placeholders' 348) never holds a frame; a new pack, tab or search drops what is left.
func _fill_family_tab(p: Dictionary, filter: String) -> void:
	var families := _families_of(p)
	if families.is_empty():
		if ModelPacks.is_sprite_pack(p):
			_grid_note(ModelPacks.NO_INSTALL + "." if not ModelPacks.factorio_usable() else "No pictures in this pack.")
		else:
			_grid_note("Use the pack to see its models (a zip is unpacked first)." if not _is_on(p) else "No models read yet.")
		return
	var names: Array = []
	for fam: String in families:
		if filter == "" or fam.contains(filter) or _family_name(fam).to_lower().contains(filter):
			names.append(fam)
	names.sort()
	if names.is_empty():
		_grid_note("No models in this pack match.")
		return
	_fill = {"pack": p, "families": families, "names": names, "at": 0}
	_fill_step()


## Adds the next buttons of the fill under way, for at most FILL_BUDGET_USEC (one at least); the
## list's columns fitted after its first slice and once it is whole, "Loading... N / M" shown until then.
func _fill_step(budget := FILL_BUDGET_USEC) -> void:
	if _fill.is_empty():
		return
	var start := Time.get_ticks_usec()
	var names: Array = _fill["names"]
	var at: int = _fill["at"]
	var first := at == 0
	var from := at
	while at < names.size() and (at == from or Time.get_ticks_usec() - start < budget):
		var make: Variant = _fill.get("make")
		_models.add_child((make as Callable).call(str(names[at])) if make is Callable
			else _family_button(_fill["pack"], _fill["families"], str(names[at])))
		at += 1
	_fill["at"] = at
	var done := at >= names.size()
	if first or done:
		_fit_model_columns()
	fill_slice_max_usec = maxi(fill_slice_max_usec, Time.get_ticks_usec() - start)
	_loading.text = "Loading... %d / %d" % [at, names.size()]
	_loading.visible = not done
	if done:
		_fill = {}


## Finishes the fill under way now (tests).
func finish_fill() -> void:
	while not _fill.is_empty():
		_fill_step()


## Whether the Models tab is still being filled.
func filling() -> bool:
	return not _fill.is_empty()


func _family_button(p: Dictionary, families: Dictionary, fam: String) -> Button:
	var b := Button.new()
	b.name = "model-" + fam
	b.theme_type_variation = "FListItemSelected" if fam == selected_family else "FListItem"
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.custom_minimum_size = Kit.pxv(0, 28)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var count := (families[fam] as Array).size()
	b.text = _family_name(fam) + (" (%d)" % count if count > 1 else "")
	_set_family_icon(b, fam)
	var using := _pack_in_use(fam)
	var chosen := str(ModelPacks.choices.get(fam, ""))
	if chosen == p["id"]:
		b.text = "✔ " + b.text
	# Its name whole without the count, for a list too narrow for both (_fit_model_columns).
	b.set_meta("full_text", b.text)
	b.set_meta("short_text", ("✔ " if chosen == p["id"] else "") + _family_name(fam))
	if not using.is_empty() and using["id"] != p["id"]:
		b.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
	b.tooltip_text = "%s\n%s" % [", ".join(families[fam]), ("In use: %s's" % using.get("short", using["title"])) if not using.is_empty() else ""]
	# From a pack's list the preview shows that pack's version (the one in use is marked on its button).
	var listed := str(p["id"])
	b.pressed.connect(func() -> void:
		Sfx.play_ui("gui-click")
		select_family(fam, listed))
	return b


## ModelPacks.families_of, kept per pack until the packs change (each a pass over its models).
static func _families_of(p: Dictionary) -> Dictionary:
	var id := str(p["id"])
	var models: Dictionary = p["models"]
	if ModelPacks.is_sprite_pack(p):
		# The Factorio pack: its entities with a picture (no files), grouped the same way.
		models = ModelPacks.sprite_names()
		var held: Array = _pack_families.get(id, [])
		if held.is_empty() or held[0] != ModelPacks.version or held[1] != models.size():
			var by := {}
			for name: String in models:
				var f := ModelPacks.family(name)
				if not by.has(f):
					by[f] = []
				(by[f] as Array).append(name)
			for f in by:
				(by[f] as Array).sort()
			held = [ModelPacks.version, models.size(), by]
			_pack_families[id] = held
		return held[2]
	var kept: Array = _pack_families.get(id, [])
	if kept.is_empty() or kept[0] != ModelPacks.version or kept[1] != models.size():
		kept = [ModelPacks.version, models.size(), ModelPacks.families_of(p)]
		_pack_families[id] = kept
	return kept[2]


## Every pack's model names of a family, sorted: ModelPacks.family_names(fam), from one pass over the
## packs kept until they change (it was a pass over every pack's models for each family asked).
static func _all_family_names(fam: String) -> Array:
	if _family_cache_key.size() != 2 or _family_cache_key[0] != ModelPacks.version or not is_same(_family_cache_key[1], ModelPacks.packs):
		var by := {}
		for p: Dictionary in ModelPacks.packs:
			for name: String in p["models"]:
				var f := ModelPacks.family(name)
				if not by.has(f):
					by[f] = {}
				(by[f] as Dictionary)[name] = true
		_family_cache = {}
		for f: String in by:
			var names: Array = (by[f] as Dictionary).keys()
			names.sort()
			_family_cache[f] = names
		_family_cache_key = [ModelPacks.version, ModelPacks.packs]
	return _family_cache.get(fam, [])


## As many columns of models as fit the list's width with the longest name and its icon whole (one
## at least; in one column too narrow the icons are drawn smaller, then names shortened; the tooltip
## has them all).
func _fit_model_columns() -> void:
	if _models == null or _models_scroll == null:
		return
	var widest := 0.0
	var buttons: Array[Button] = []
	for b in _models.get_children():
		if b is Button:
			if b.has_meta("full_text"):
				(b as Button).text = str(b.get_meta("full_text"))
			if b.has_meta("wrapped"):
				_wrap_button(b as Button, false)
			buttons.append(b as Button)
			widest = maxf(widest, button_text_width(b as Button))
	if buttons.is_empty():
		_models.columns = 1
		return
	var room := _models_scroll.size.x - Kit.px(14)  # the scroll bar's width
	var gap := float(Kit.px(2))
	var with_icons := buttons[0].has_meta("family")
	var icon := float(Kit.px(FAMILY_ICON)) if with_icons else 0.0
	var sep := float(buttons[0].get_theme_constant("h_separation")) if with_icons else 0.0
	var cell := maxf(widest + icon + sep, Kit.px(140))
	_models.columns = clampi(int((room + gap) / (cell + gap)), 1, 8)
	# A count ("(2)") keeping the list to one column: the names without it, if that fits two (the
	# tooltip lists the pieces).
	if _models.columns == 1:
		var widest_short := 0.0
		for b in buttons:
			var t := b.text
			if b.has_meta("short_text"):
				b.text = str(b.get_meta("short_text"))
			widest_short = maxf(widest_short, button_text_width(b))
			b.text = t
		var cell_short := maxf(widest_short + icon + sep, Kit.px(140))
		if int((room + gap) / (cell_short + gap)) >= 2:
			for b in buttons:
				if b.has_meta("short_text"):
					b.text = str(b.get_meta("short_text"))
			_models.columns = clampi(int((room + gap) / (cell_short + gap)), 1, 8)
	_icons_hidden = false
	if with_icons and _models.columns == 1 and widest + icon + sep > room:
		icon = floorf(room - widest - sep)
		_icons_hidden = icon < Kit.px(12)  # a small screen at a large UI scale: the names whole first
	# One column and still a name too long (a belt tier's five pieces, "(5)", at a large UI scale):
	# that one's count goes (its tooltip lists them).
	# Still too long without it ("Express underground belt" at 1280x720, UI scale 1.5): that name on
	# two lines, its button two lines high, the icon still at its left (only those, once a fit).
	if _models.columns == 1:
		for b in buttons:
			var beside := 0.0 if _icons_hidden or not b.has_meta("family") else icon + sep
			if b.has_meta("short_text") and button_text_width(b) + beside > room:
				b.text = str(b.get_meta("short_text"))
			if button_text_width(b) + beside > room:
				_wrap_button(b, true)
	for b in buttons:
		if not b.has_meta("family"):
			continue
		if _icons_hidden:
			b.icon = null
			continue
		b.add_theme_constant_override("icon_max_width", int(icon))
		if b.icon == null:
			var fam := str(b.get_meta("family"))
			_put_family_icon(b, _button_icon(b, fam) if _button_icon_cached(b, fam) else null, fam)
			if not _button_icon_cached(b, fam):
				_icon_queue.append([b, fam])


## A list button's name on up to two lines (`on`), its height two lines', or back on one line.
static func _wrap_button(b: Button, on: bool) -> void:
	if on:
		var font := b.get_theme_font("font")
		var style := b.get_theme_stylebox("normal")
		var sides := style.get_margin(SIDE_TOP) + style.get_margin(SIDE_BOTTOM) if style != null else 0.0
		var lines := 2.0 * font.get_height(b.get_theme_font_size("font_size")) + sides + 2.0
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		b.custom_minimum_size = Vector2(0, maxf(Kit.px(28), ceilf(lines)))
		b.set_meta("wrapped", true)
	else:
		b.autowrap_mode = TextServer.AUTOWRAP_OFF
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		b.custom_minimum_size = Kit.pxv(0, 28)
		b.remove_meta("wrapped")


## The width a button needs for its text whole: the text and its style's sides.
static func button_text_width(b: Button) -> float:
	var font := b.get_theme_font("font")
	var style := b.get_theme_stylebox("normal")
	var sides := style.get_margin(SIDE_LEFT) + style.get_margin(SIDE_RIGHT) if style != null else 0.0
	return font.get_string_size(b.text, HORIZONTAL_ALIGNMENT_LEFT, -1, b.get_theme_font_size("font_size")).x + sides + 2.0


## Factorio's icon for a family's entity, as its windows and Factoriopedia draw it: the entity's own
## (a tree, a biter, a rail: entities without an item of their name), else its item's (a chest, a
## belt, an inserter: the item placing it), from the bridge's graphics list or the install; null
## without either (no install, a model that isn't a prototype). Cached with the rest of the UI's.
static func family_icon(fam: String) -> Texture2D:
	var texture: Texture2D = ItemIcons.texture_for_kind("entity", fam)
	if texture == null:
		texture = ItemIcons.texture_for(fam)
	var main := main_model(fam)
	if texture == null and main != fam:
		texture = ItemIcons.texture_for_kind("entity", main)
		if texture == null:
			texture = ItemIcons.texture_for(main)
	return texture


## Whether family_icon(fam) answers from the cache, without reading a file.
static func _family_icon_cached(fam: String) -> bool:
	var main := main_model(fam)
	var own := _name_icon_cached(fam)
	if own == 0:
		return false
	return own == 1 or main == fam or _name_icon_cached(main) != 0


## 1: a name's icon is cached, -1: cached as none, 0: not looked for yet.
static func _name_icon_cached(name: String) -> int:
	ItemIcons._follow_list()
	var key := "entity:" + name
	if not ItemIcons._kinds.has(key):
		return 0
	if ItemIcons._kinds[key] != null:
		return 1
	if not ItemIcons.is_cached(name):
		return 0
	return 1 if ItemIcons._textures[name] != null else -1


## A family button's icon: its own when cached, else the clear square until _load_queued_icons
## reads it (a window of 400 families opens at once; their files come over the next frames).
func _set_family_icon(b: Button, fam: String) -> void:
	b.add_theme_constant_override("icon_max_width", Kit.px(FAMILY_ICON))
	b.expand_icon = false
	b.set_meta("family_icon", "")
	b.set_meta("family", fam)
	if _button_icon_cached(b, fam):
		_put_family_icon(b, _button_icon(b, fam), fam)
	else:
		b.icon = blank_icon()
		_icon_queue.append([b, fam])


## An item's icon as its slots draw it (its own, else its entity's); a family's family_icon.
static func item_icon(item: String) -> Texture2D:
	var texture: Texture2D = ItemIcons.texture_for(item)
	return texture if texture != null else family_icon(item)


static func _button_icon(b: Button, name: String) -> Texture2D:
	return item_icon(name) if b.get_meta("item", false) else family_icon(name)


static func _button_icon_cached(b: Button, name: String) -> bool:
	if b.get_meta("item", false):
		return ItemIcons.is_cached(name) and (ItemIcons._textures[name] != null or _family_icon_cached(name))
	return _family_icon_cached(name)


static func _put_family_icon(b: Button, texture: Texture2D, fam: String) -> void:
	b.icon = texture if texture != null else blank_icon()
	b.set_meta("family_icon", fam if texture != null else "")


func _load_queued_icons() -> void:
	if _icon_queue.is_empty():
		return
	var start := Time.get_ticks_usec()
	while not _icon_queue.is_empty() and Time.get_ticks_usec() - start < ICON_BUDGET_USEC:
		var job: Array = _icon_queue.pop_front()
		var b = job[0]
		if not is_instance_valid(b):
			continue
		if _icons_hidden:
			(b as Button).icon = null
			continue
		_put_family_icon(b as Button, _button_icon(b as Button, str(job[1])), str(job[1]))


## Loads every queued icon now (tests).
func load_icons_now() -> void:
	while not _icon_queue.is_empty():
		_load_queued_icons()
	while not _factorio_icon_queue.is_empty():
		_load_factorio_icons()


## The clear square in a family button without an icon, as wide as an icon is drawn.
static func blank_icon() -> Texture2D:
	var side := Kit.px(FAMILY_ICON)
	if not _blank_icons.has(side):
		var image := Image.create(side, side, false, Image.FORMAT_RGBA8)
		image.fill(Color(0, 0, 0, 0))
		_blank_icons[side] = ImageTexture.create_from_image(image)
	return _blank_icons[side]


## A family's name as Factorio names the entity (its own name for a piece of one).
static func _family_name(fam: String) -> String:
	var shown := Kit.entity_name(fam)
	return shown if shown != "" else fam


## The model drawn for a family: its own name if a pack has it, else its first variant's.
static func main_model(fam: String) -> String:
	var names := _all_family_names(fam)
	return fam if names.has(fam) or names.is_empty() else str(names[0])


## The pack in use whose version of a family is drawn ({} none): as the order and the choices have it
## (a tier drawn from its base recoloured: the base's pack).
static func _pack_in_use(fam: String) -> Dictionary:
	# An ore scattered as a pack's numbered rocks: that pack (ModelLibrary.drawing_pack's rule).
	if ModelLibrary.ORE_STAGES.has(fam) and ModelLibrary.ore_scatter != "off" and ModelPacks.is_ready():
		var found := ModelLibrary.ore_scatter_names(fam)
		if not (found[1] as Array).is_empty():
			return found[0]
	var name := main_model(fam)
	if ModelLibrary.draws_sprite(name) or (name != fam and ModelLibrary.draws_sprite(fam)):
		return ModelPacks.pack(ModelPacks.FACTORIO_ID)  # Factorio's picture is drawn
	var alias := ModelLibrary._alias_of(name)
	var drawn := alias if alias != "" else name
	# _source waits for a zip being unpacked (Default.zip's first start takes a while): not known yet,
	# rather than the window hanging; the lists are made again once it is in (_process).
	if not ModelPacks.is_ready() and not ModelLibrary._sources.has(drawn):
		return {}
	var src := ModelLibrary._source(drawn)
	var base := ModelLibrary._tier_base(drawn)
	if src == "" and base != "" and (ModelPacks.is_ready() or ModelLibrary._sources.has(base)):
		src = ModelLibrary._source(base)
	return ModelPacks.pack_of(src)


## Shows a family turning: `pack`'s version (a pack's list passes its own), else the one in use.
func select_family(fam: String, pack := "") -> void:
	if fam != selected_family:
		_variant = ""
	selected_family = fam
	selected_item = ""
	_shown_pack = pack
	for b in _models.get_children():
		if b is Button:
			(b as Button).theme_type_variation = "FListItemSelected" if str(b.name) == "model-" + fam else "FListItem"
	_show_family()


func _show_family() -> void:
	for c in _info.get_children():
		_info.remove_child(c)
		c.queue_free()
	if _tab == "icons":
		_show_icon()
		return
	if _icon_view != null:
		_icon_view.visible = false
	if selected_item != "":
		_show_item()
		return
	var fam := selected_family
	if fam == "":
		_set_credit("")
		_preview.show_model("")
		_pack_details(_pack_by_id(selected_pack))
		var hint := _wrapped("Click a model to see it turning, and to take it from a pack of your choice whatever the order.")
		hint.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		_info.add_child(hint)
		return
	var main := main_model(fam)
	# Every pack in use with a version of it, the selected one first if it has one.
	var having: Array = []
	var picture := sprite_of(fam)  # the Factorio pack's picture of it, "" none
	for p: Dictionary in ModelPacks.active():
		if ModelPacks.is_sprite_pack(p):
			if picture != "":
				having.append(p)
		elif ModelPacks.find_in(str(p["id"]), main) != "" or ModelPacks.find_in(str(p["id"]), ModelLibrary._tier_base(main)) != "" 				or ModelPacks.provides(p, fam):  # an ore's numbered rocks (`iron-ore-1`) are its version
			having.append(p)
	# The Factorio pack listed while it is off: its picture still shown.
	if picture != "" and _shown_pack == ModelPacks.FACTORIO_ID and ModelPacks.pack(ModelPacks.FACTORIO_ID).is_empty():
		having.append(_pack_by_id(ModelPacks.FACTORIO_ID))
	# The pack asked for (a pack's list asks for its own), else the version in use, then the listed pack's.
	var in_use_id := str(_pack_in_use(fam).get("id", ""))
	var shown := _shown_pack
	if shown == "" or not having.any(func(p: Dictionary) -> bool: return p["id"] == shown):
		if having.any(func(p: Dictionary) -> bool: return p["id"] == in_use_id):
			shown = in_use_id
		elif having.any(func(p: Dictionary) -> bool: return p["id"] == selected_pack):
			shown = selected_pack
		else:
			shown = str(having[0]["id"]) if not having.is_empty() else ""
	_shown_pack = shown
	var shown_pack := ModelPacks.pack(shown)
	if shown_pack.is_empty() and shown != "":
		shown_pack = _pack_by_id(shown)
	_set_credit(credit_line(shown_pack))
	var variants: Array
	var model: String
	if ModelPacks.is_sprite_pack(shown_pack):
		# Factorio's picture, its directions as the variants (["inserter|0", "inserter|4", ...]).
		variants = sprite_variants(picture)
		model = _variant if variants.has(_variant) else (variants[0] if not variants.is_empty() else picture + "|0")
		_preview.show_sprite(model.get_slice("|", 0), int(model.get_slice("|", 1)))
	else:
		var names := ModelPacks.family_names(fam, [shown_pack] if not shown_pack.is_empty() else [])
		variants = picker_variants(fam, names)
		# The variant looked at, kept across packs that have it; else the main model.
		model = _variant if _variant != "" and variants.has(_variant) else main
		# A pack with only the family's variants (an ore's numbered rocks, `iron-ore-1`...: no `iron-ore`,
		# nor a tier's base) shows its first: `iron-ore@pack` is drawn as the usual iron ore (_alias_of),
		# another pack's, until a variant was picked by hand (the picker read 0 / 3).
		if (model == main and shown != "" and not variants.is_empty() and not variants.has(main)
				and ModelPacks.find_in(shown, main) == "" and ModelPacks.find_in(shown, ModelLibrary._tier_base(main)) == ""):
			model = str(variants[0])
		_preview.entity = fam
		_preview.show_model(model + "@" + shown if shown != "" else model)
	var title := Kit.label(_family_name(fam), "FHeading")
	title.name = "Family"
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.custom_minimum_size.x = Kit.px(60)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title_row := HBoxContainer.new()
	title_row.name = "FamilyRow"
	title_row.add_theme_constant_override("separation", Kit.px(6))
	var icon := family_icon(fam)
	if icon != null:
		var pic := TextureRect.new()
		pic.name = "FamilyIcon"
		pic.texture = icon
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.custom_minimum_size = Kit.pxv(32, 32)
		pic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		title_row.add_child(pic)
	title_row.add_child(title)
	_info.add_child(title_row)
	var chosen := str(ModelPacks.choices.get(fam, ""))
	if ModelPacks.pack(chosen).is_empty():
		chosen = ""
	# A card per pack with a version of it: its picture and name, the one in use tagged (by the
	# order or chosen), View to look at it and Select to draw it in the game.
	var cards := VBoxContainer.new()
	cards.name = "Versions"
	cards.add_theme_constant_override("separation", Kit.px(4))
	_info.add_child(cards)
	for p: Dictionary in having:
		cards.add_child(_version_card(fam, p, p["id"] == shown, p["id"] == in_use_id, chosen))
	var order := MenuKit.button("Use the pack order")
	order.name = "UseOrder"
	order.custom_minimum_size.x = 0
	order.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	order.disabled = chosen == ""
	order.tooltip_text = "From the highest pack in Selected that has it" if chosen != "" else "Already from the pack order: Select a pack's version to take it whatever the order"
	order.pressed.connect(func() -> void: choose_pack(fam, ""))
	_info.add_child(order)
	if variants.size() > 1:
		_info.add_child(_variant_picker(fam, variants, model))


## The Factorio pack's picture of a family: the entity of its name, else its first with a picture;
## "" when it has none.
static func sprite_of(fam: String) -> String:
	var sprites := ModelPacks.sprite_names()
	if sprites.has(fam):
		return fam
	var names: Array = _families_of({"id": ModelPacks.FACTORIO_ID, "models": {}}).get(fam, [])
	if not names.is_empty():
		return str(names[0])
	var main := main_model(fam)
	return main if sprites.has(main) else ""


## A picture's directions as the variant picker's entries, "<entity>|<16-way direction>": the four
## when the picture has them (SpriteStandins.directions), else just the one.
static func sprite_variants(name: String) -> Array:
	if name == "":
		return []
	var dirs := SpriteStandins.directions(name)
	if dirs.is_empty():
		dirs = [0]
	return dirs.map(func(d: int) -> String: return "%s|%d" % [name, d])


## The variants the picker steps through: the family's files without a belt's start and end pieces
## (`<belt>-start`, `<belt>-end`), which the world adds at a line's ends and the preview draws on the
## straight belt, splitter and underground, but nobody builds.
## A pipe's, heat pipe's or wall's sixteen connection shapes come down to four (CONNECTION_SHAPES: one
## of each, its most natural turn), after the family's own model (a wall's is its lone pillar, a
## pipe's a straight).
static func picker_variants(fam: String, names: Array) -> Array:
	var shapes := connection_shapes(fam, names)
	if not shapes.is_empty():
		var out: Array = [fam] if names.has(fam) else []
		for rest: String in shapes:
			if names.has(fam + "-" + rest):
				out.append(fam + "-" + rest)
		return out
	if not fam.ends_with("transport-belt"):
		return names
	return names.filter(func(n: String) -> bool: return n != fam + "-start" and n != fam + "-end")


## The connection kits' shapes the picker keeps, by the file each kit has for its cross, and their labels.
const CONNECTION_SHAPES := {
	"cross": [["straight-horizontal", "Straight"], ["corner-up-right", "Corner"], ["t-up", "T"], ["cross", "Cross"]],
	"nesw": [["ew", "Straight"], ["ne", "Corner"], ["new", "T"], ["nesw", "Cross"]],
}


## The shapes (file name endings) kept for a connection kit's family, [] for any other family.
static func connection_shapes(fam: String, names: Array) -> Array:
	for cross: String in CONNECTION_SHAPES:
		if names.has(fam + "-" + cross):
			return CONNECTION_SHAPES[cross].map(func(s: Array) -> String: return str(s[0]))
	return []


## A connection kit's shape's label ("Straight", "Corner", "T", "Cross"), "" for anything else.
static func _connection_label(fam: String, rest: String) -> String:
	for cross: String in CONNECTION_SHAPES:
		if cross == "nesw" and not fam.ends_with("wall"):
			continue  # "ne" is a diagonal rail's too
		for shape: Array in CONNECTION_SHAPES[cross]:
			if rest == shape[0]:
				return str(shape[1])
	return ""


## Shows an item turning: `pack`'s version (a pack's list passes its own), else the one in use.
func select_item(item: String, pack := "") -> void:
	selected_item = item
	selected_family = ""
	_variant = ""
	_shown_pack = pack
	for b in _models.get_children():
		if b is Button:
			(b as Button).theme_type_variation = "FListItemSelected" if str(b.name) == "item-" + item else "FListItem"
	_show_family()


## The item picked: its icon and name, a card per pack in use with a version of it (View, Select),
## Use the pack order.
func _show_item() -> void:
	var item := selected_item
	var card := SpriteStandins.item_picture(item) != null  # Factorio's icon card of it
	var having: Array = ModelPacks.active().filter(func(p: Dictionary) -> bool:
		return not ModelPacks.item_files(p, item).is_empty() or (ModelPacks.is_sprite_pack(p) and card))
	if card and _shown_pack == ModelPacks.FACTORIO_ID and ModelPacks.pack(ModelPacks.FACTORIO_ID).is_empty():
		having.append(_pack_by_id(ModelPacks.FACTORIO_ID))  # listed while off: its card still shown
	var in_use_id := str((ModelPacks.item_source(item).get("pack", {}) as Dictionary).get("id", ""))
	var shown := _shown_pack
	if shown == "" or not having.any(func(p: Dictionary) -> bool: return p["id"] == shown):
		if having.any(func(p: Dictionary) -> bool: return p["id"] == in_use_id):
			shown = in_use_id
		elif having.any(func(p: Dictionary) -> bool: return p["id"] == selected_pack):
			shown = selected_pack
		else:
			shown = str(having[0]["id"]) if not having.is_empty() else ""
	_shown_pack = shown
	var shown_pack := ModelPacks.pack(shown)
	if shown_pack.is_empty() and shown != "":
		shown_pack = _pack_by_id(shown)
	_set_credit(credit_line(shown_pack))
	if ModelPacks.is_sprite_pack(shown_pack):
		_preview.show_item_card(item)
	else:
		var files := ModelPacks.item_files(shown_pack, item) if not shown_pack.is_empty() else []
		_preview.show_item(item, str(files[0]) if not files.is_empty() else "")
	var title_row := HBoxContainer.new()
	title_row.name = "FamilyRow"
	title_row.add_theme_constant_override("separation", Kit.px(6))
	var icon := item_icon(item)
	if icon != null:
		var pic := TextureRect.new()
		pic.name = "FamilyIcon"
		pic.texture = icon
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.custom_minimum_size = Kit.pxv(32, 32)
		pic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		title_row.add_child(pic)
	var title := Kit.label(Kit.pretty(item), "FHeading")
	title.name = "Item"
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.custom_minimum_size.x = Kit.px(60)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	_info.add_child(title_row)
	var chosen := ModelPacks.item_choice(item)
	var cards := VBoxContainer.new()
	cards.name = "Versions"
	cards.add_theme_constant_override("separation", Kit.px(4))
	_info.add_child(cards)
	for p: Dictionary in having:
		cards.add_child(_version_card(item, p, p["id"] == shown, p["id"] == in_use_id, chosen, "item"))
	var order := MenuKit.button("Use the pack order")
	order.name = "UseOrder"
	order.custom_minimum_size.x = 0
	order.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	order.disabled = chosen == ""
	order.tooltip_text = "From the highest pack in Selected that has it" if chosen != "" else "Already from the pack order: Select a pack's version to take it whatever the order"
	order.pressed.connect(func() -> void: choose_item_pack(item, ""))
	_info.add_child(order)


## A family's variants to look at in the preview: arrows either side of a dropdown of their names
## ("Curve left", "Arm (hand)"; the file's name in its tooltip) and "2 / 5". Display only: a choice
## (Select) is still the whole family's.
func _variant_picker(fam: String, names: Array, model: String) -> Control:
	var row := HBoxContainer.new()
	row.name = "VariantPicker"
	row.add_theme_constant_override("separation", Kit.px(4))
	var at := names.find(model)
	var prev := _arrow("remove", "<", "Previous variant")
	prev.name = "VariantPrev"
	prev.pressed.connect(func() -> void: step_variant(-1))
	row.add_child(prev)
	var items: Array = []
	for n: String in names:
		items.append([variant_label(fam, n), n])
	var pick := MenuKit.dropdown(items, model)
	pick.name = "VariantChoice"
	pick.custom_minimum_size.x = Kit.px(60)
	pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pick.clip_text = true
	pick.tooltip_text = model
	for i in names.size():
		pick.set_item_tooltip(i, str(names[i]))
	pick.item_selected.connect(func(i: int) -> void:
		Sfx.play_ui("gui-click")
		select_variant(str(pick.get_item_metadata(i))))
	row.add_child(pick)
	var next := _arrow("add", ">", "Next variant")
	next.name = "VariantNext"
	next.pressed.connect(func() -> void: step_variant(1))
	row.add_child(next)
	var count := Kit.label("%d / %d" % [at + 1, names.size()])
	count.name = "VariantCount"
	count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(count)
	return row


## Shows variant `name` of the family picked ("" or one the pack shown lacks: its main model).
func select_variant(name: String) -> void:
	_variant = name
	_show_family()


## The next (or previous, -1) variant of the family picked, round the end.
func step_variant(by: int) -> void:
	var picker := _info.find_child("VariantChoice", true, false) as OptionButton
	if picker == null or picker.item_count == 0:
		return
	Sfx.play_ui("gui-click")
	select_variant(str(picker.get_item_metadata(posmod(picker.selected + by, picker.item_count))))


## A variant's readable name from what its file name adds to the family's: "Curve left", "Start
## piece", "Arm (hand)"; the family's own model "Main model".
static func variant_label(fam: String, name: String) -> String:
	if name.contains("|"):  # a Factorio picture's direction
		return ["North", "East", "South", "West"][posmod(int(name.get_slice("|", 1)) / 4, 4)]
	if name == fam:
		return "Main model"
	if name.begins_with("inserter-arm-"):
		return "Arm (%s)" % name.get_slice("-", name.get_slice_count("-") - 1)
	var rest := name.substr(fam.length() + 1) if name.begins_with(fam + "-") else name
	var shape := _connection_label(fam, rest)
	if shape != "":
		return shape
	match rest:
		"start":
			return "Start piece"
		"end":
			return "End piece"
		"input", "entrance":
			return "Entrance"
		"output", "exit":
			return "Exit"
	var compass := {"n": "north", "e": "east", "s": "south", "w": "west"}
	var words: Array = []
	for w: String in rest.split("-", false):
		words.append(str(compass.get(w, w)))
	var text := " ".join(words)
	return text if text == "" else text.substr(0, 1).to_upper() + text.substr(1)


## One pack's version of a family: the pack's picture (as in its row on the left), its name, "In use"
## with Factorio's green tick on the one drawn in the game, View (pressed on the one shown) and
## Select ("Selected" on the one chosen).
## `kind`: "icon" for the Icons tab's card for icon key `fam` (View and Select its icon, not a
## model), "item" for the Items tab's card for item `fam`, "" for a model family.
func _version_card(fam: String, p: Dictionary, shown: bool, in_use: bool, chosen: String, kind := "") -> Control:
	var icon := kind == "icon"
	var item := kind == "item"
	var id := str(p["id"])
	var key := id.replace(":", "_")
	var card := PanelContainer.new()
	card.name = "version-" + key
	card.set_meta("pack", id)
	card.set_meta("card", true)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", Kit.px(8))
	card.add_child(h)
	var picture := _pack_picture(p)
	picture.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(picture)
	var text := VBoxContainer.new()
	text.add_theme_constant_override("separation", 0)
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(text)
	var title := Kit.label(str(p["title"]))
	title.name = "title"
	title.add_theme_font_override("font", Kit.font("bold"))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.custom_minimum_size.x = Kit.px(40)
	text.add_child(title)
	if in_use:
		var tag := HBoxContainer.new()
		tag.name = "InUseTag"
		tag.add_theme_constant_override("separation", Kit.px(4))
		var tick_texture := GuiAssets.core_sprite("icons/mip/check-mark-green.png")
		if tick_texture != null:
			var tick := TextureRect.new()
			tick.name = "tick"
			tick.texture = tick_texture
			tick.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tick.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tick.custom_minimum_size = Kit.pxv(16, 16)
			tick.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			tag.add_child(tick)
		var words := _wrapped("In use (chosen)" if chosen == id else "In use (by the order)")
		words.name = "words"
		words.custom_minimum_size.x = Kit.px(40)
		words.add_theme_color_override("font_color", Kit.GREEN_TEXT)
		tag.add_child(words)
		text.add_child(tag)
	var buttons := HFlowContainer.new()
	buttons.name = "buttons"
	buttons.add_theme_constant_override("h_separation", Kit.px(4))
	buttons.add_theme_constant_override("v_separation", Kit.px(4))
	buttons.alignment = FlowContainer.ALIGNMENT_END
	buttons.size_flags_horizontal = Control.SIZE_SHRINK_END
	buttons.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(buttons)
	var short := str(p.get("short", p["title"]))
	var view := MenuKit.button("View")
	view.name = "show-" + key
	view.custom_minimum_size.x = Kit.px(64)
	view.set_meta("in_use", in_use)
	view.toggle_mode = true
	view.button_pressed = shown
	view.tooltip_text = "Look at %s's version in the preview%s" % [short, " (the one in use)" if in_use else ""]
	view.pressed.connect(func() -> void:
		Sfx.play_ui("gui-click")
		if icon:
			select_icon(fam, id)
		elif item:
			select_item(fam, id)
		else:
			select_family(fam, id))
	buttons.add_child(view)
	var select := MenuKit.button("Selected" if chosen == id else "Select")
	select.name = "use-" + key
	select.custom_minimum_size.x = Kit.px(64)
	select.disabled = chosen == id
	var select_what := "Draw %s's version of this model and its variants in the game, whatever the order"
	if icon:
		select_what = "Draw %s's icon everywhere in the game, whatever the order"
	elif item:
		select_what = "Draw %s's version of this item in the game, whatever the order"
	select.tooltip_text = ("%s's version is chosen: Use the pack order gives it back" % short) if chosen == id else (select_what % short)
	select.pressed.connect(func() -> void:
		if icon:
			choose_icon(fam, id)
		elif item:
			choose_item_pack(fam, id)
		else:
			choose_pack(fam, id))
	buttons.add_child(select)
	# Deferred: a container is sorting its children while it says it was resized.
	card.resized.connect(func() -> void: _fit_card.call_deferred(card))
	_fit_card(card)
	# The shown card in the left list's selected look (a plain panel never drew the variation's).
	_mark_row(card, shown)
	return card


## A version card's buttons beside its name and tag while the card leaves the text CARD_TEXT_ROOM,
## else under them (right-aligned, wrapping if need be): the buttons keep their size and stay
## inside the card's margin at every width, the text wraps first.
func _fit_card(card: PanelContainer) -> void:
	if not is_instance_valid(card):
		return
	var h := card.get_child(0) as HBoxContainer
	var buttons := card.find_child("buttons", true, false) as HFlowContainer
	var text := h.get_child(1) as VBoxContainer
	var picture := h.get_child(0) as Control
	var row_width := 0.0
	for b: Control in buttons.get_children():
		row_width += b.get_combined_minimum_size().x
	row_width += buttons.get_theme_constant("h_separation") * maxf(0.0, buttons.get_child_count() - 1)
	var inner := card.size.x - Kit.px(CARD_PAD) * 2
	var sep := float(h.get_theme_constant("separation"))
	var beside := card.size.x <= 0.0 or inner - picture.get_combined_minimum_size().x - sep * 2 - row_width >= Kit.px(CARD_TEXT_ROOM)
	if beside:
		buttons.custom_minimum_size.x = row_width
		buttons.size_flags_horizontal = Control.SIZE_SHRINK_END
		if buttons.get_parent() != h:
			buttons.reparent(h, false)
	else:
		buttons.custom_minimum_size.x = 0
		buttons.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if buttons.get_parent() != text:
			buttons.reparent(text, false)


## Play animation and the speaker in the preview's top right corner, over the picture: the model's
## moving parts as in the game, and the entity's working sound while they play (greyed while the
## model is read, or with nothing to play). Only the buttons take the mouse: the rest of the
## picture still turns the model.
func _preview_tools() -> Control:
	var corner := MarginContainer.new()
	corner.name = "PreviewTools"
	corner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	corner.size_flags_horizontal = Control.SIZE_SHRINK_END
	corner.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	for side in ["top", "right"]:
		corner.add_theme_constant_override("margin_" + side, Kit.px(6))
	var row := HBoxContainer.new()
	row.name = "PlayRow"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", Kit.px(4))
	corner.add_child(row)
	_play_button = _corner_button("PlayAnim", GuiAssets.core_sprite("icons/mip/play.png"), "▶")
	_play_button.pressed.connect(func() -> void:
		Sfx.play_ui("gui-click")
		_preview.set_playing(not _preview.is_playing())
		_update_play_row())
	row.add_child(_play_button)
	# Factorio's own speaker: the programmable speaker's icon, from the install.
	_speaker_button = _corner_button("Speaker", Kit.item_icon("programmable-speaker"), "♪")
	_speaker_button.toggle_mode = true
	_speaker_button.toggled.connect(func(on: bool) -> void:
		Sfx.play_ui("gui-click")
		sound_choice = on
		_preview.set_sounding(on)
		_update_play_row())
	row.add_child(_speaker_button)
	# lighting-fixes step 6: the preview is lit as the game is (the Factorio look at noon); this gives the studio
	# light it had before, while the window is open (--preview-light=studio makes that the default).
	var studio := _corner_button("StudioLight", Kit.item_icon("small-lamp"), "☀")
	studio.toggle_mode = true
	studio.button_pressed = _preview.studio
	studio.tooltip_text = "Studio light: the preview's own light from before. Off: lit as in a game (the Factorio look at noon on Nauvis). While on, the menu's backdrop draws pbr packs as before too"
	studio.toggled.connect(func(on: bool) -> void:
		Sfx.play_ui("gui-click")
		_preview.set_studio(on))
	row.add_child(studio)
	corner.visible = false
	return corner


## The shown pack's credit in the preview's top left, over the picture: one small line in Factorio's
## caption colour on a tooltip's dark backing, cut short with "..." before the corner's buttons. It
## takes no mouse, so a drag over it still turns the model.
func _preview_credit() -> Control:
	var corner := MarginContainer.new()
	corner.name = "PreviewCredit"
	corner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	corner.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	corner.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	for side in ["top", "left"]:
		corner.add_theme_constant_override("margin_" + side, Kit.px(6))
	var back := PanelContainer.new()
	back.name = "Backing"
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0, 0, 0, 0.55)
	box.set_corner_radius_all(Kit.px(2))
	box.content_margin_left = Kit.px(5)
	box.content_margin_right = Kit.px(5)
	box.content_margin_top = Kit.px(1)
	box.content_margin_bottom = Kit.px(2)
	back.add_theme_stylebox_override("panel", box)
	corner.add_child(back)
	_credit = Kit.label("")
	_credit.name = "Credit"
	_credit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_credit.add_theme_font_size_override("font_size", Kit.px(12))
	_credit.add_theme_color_override("font_color", Kit.CAPTION)
	_credit.clip_text = true
	_credit.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	back.add_child(_credit)
	corner.visible = false
	return corner


## A pack's credit line: its pack.json's "credit" as it is, else built from its author and licence
## (a licence that is a "©" line gives "© <author>", "· used with permission" when it says so; a long
## licence is left to the pack's row), else nothing.
static func credit_line(p: Dictionary) -> String:
	var info: Dictionary = p.get("info", {})
	var credit := str(info.get("credit", "")).strip_edges()
	if credit != "":
		return credit
	var author := str(info.get("author", "")).strip_edges()
	var licence := str(info.get("licence", "")).strip_edges()
	if licence.begins_with("©"):
		if author == "":
			return licence.get_slice(",", 0).get_slice(";", 0)
		return "© " + author + (" · used with permission" if licence.to_lower().contains("permission") else "")
	var parts := PackedStringArray()
	if author != "":
		parts.append(author)
	if licence != "" and licence.length() <= 32:
		parts.append(licence)
	return " · ".join(parts)


func _set_credit(text: String) -> void:
	if _credit == null:
		return
	_credit.text = text
	_fit_credit()


## The credit's width: its text's, at most up to the corner's buttons (a gap before them).
func _fit_credit() -> void:
	if _credit == null:
		return
	var corner := _credit.get_parent().get_parent() as Control
	var frame := corner.get_parent() as Control
	var tools := frame.get_node_or_null("PreviewTools") as Control
	var style := frame.get_theme_stylebox("panel")
	var inner := frame.size.x - (style.get_margin(SIDE_LEFT) + style.get_margin(SIDE_RIGHT) if style != null else 0.0)
	var room := inner - Kit.px(6) - Kit.px(6) - Kit.px(10)  # its left margin, a gap, the backing's sides
	if tools != null:
		room -= tools.get_combined_minimum_size().x
	var font := _credit.get_theme_font("font")
	var want := font.get_string_size(_credit.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		_credit.get_theme_font_size("font_size")).x + 1.0
	_credit.custom_minimum_size.x = clampf(want, 0.0, maxf(room, 0.0))
	corner.visible = _credit.text != "" and room >= Kit.px(24)


## A small tool button with its picture drawn over it (4 pixels in), or `glyph` without the install.
static func _corner_button(button_name: String, picture: Texture2D, glyph: String) -> Button:
	var b := Button.new()
	b.name = button_name
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Kit.pxv(28, 28)
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	if picture == null:
		b.text = glyph
		return b
	var t := TextureRect.new()
	t.name = "Icon"
	t.texture = picture
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.texture_filter = Kit.ICON_FILTER
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t.set_anchors_preset(Control.PRESET_FULL_RECT)
	t.offset_left = Kit.px(4)
	t.offset_top = Kit.px(4)
	t.offset_right = -Kit.px(4)
	t.offset_bottom = -Kit.px(4)
	b.add_child(t)
	return b


func _update_play_row() -> void:
	if _play_button == null or _speaker_button == null:
		return
	(_play_button.get_parent().get_parent() as Control).visible = selected_family != "" and _tab != "icons"
	var ready := _preview.shown_mesh != null
	var playing := _preview.is_playing()
	_play_button.disabled = not _preview.can_play()
	var icon := _play_button.get_node_or_null("Icon") as TextureRect
	if icon != null:
		var want := GuiAssets.core_sprite("icons/mip/stop.png" if playing else "icons/mip/play.png")
		if want != null and icon.texture != want:
			icon.texture = want
		icon.modulate = Color(1, 1, 1, 0.4) if _play_button.disabled else Color(1, 1, 1)
	else:
		_play_button.text = "■" if playing else "▶"
	_play_button.tooltip_text = ("A picture, not a model" if _preview.is_picture() else "Reading the model..." if not ready else "Nothing on this model moves or glows"
		if not _preview.can_play() else "Stop animation" if playing else "Play animation")
	var why := _preview.sound_reason()
	_speaker_button.disabled = why != ""
	# On unless the player turned it off; greyed it shows off but keeps their choice. The preview
	# forgets it with each model it shows, so it is given again here.
	var on := sound_choice and why == ""
	if _speaker_button.button_pressed != on:
		_speaker_button.set_pressed_no_signal(on)
	if _preview.sounding_on() != on:
		_preview.set_sounding(on)
	var speaker_icon := _speaker_button.get_node_or_null("Icon") as Control
	var dim := Color(1, 1, 1) if _speaker_button.button_pressed else Color(0.55, 0.55, 0.55)
	if speaker_icon != null:
		speaker_icon.modulate = dim
	else:
		_speaker_button.modulate = dim
	_speaker_button.tooltip_text = why if why != "" else ("Building sound on" if _speaker_button.button_pressed
		else "Building sound off") + (": its working sound while the animation plays" if _preview.can_play() else ": its working sound")


## The listed pack's details while no model is chosen: its name, pack.json's lines in full (where
## it is, version, author, licence, source) and its description.
func _pack_details(p: Dictionary) -> void:
	if p.is_empty():
		return
	var details := VBoxContainer.new()
	details.name = "PackDetails"
	details.add_theme_constant_override("separation", Kit.px(2))
	_info.add_child(details)
	var title := Kit.label(str(p["title"]), "FHeading")
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.custom_minimum_size.x = Kit.px(60)
	details.add_child(title)
	var info: Dictionary = p["info"]
	var n := int(p["count"])
	var icons := int(p.get("icon_count", 0))
	var sounds := int(p.get("sound_count", 0))
	var lines := PackedStringArray(["%d model%s%s%s%s, %s" % [n, "" if n == 1 else "s", ", %d icon%s" % [icons, "" if icons == 1 else "s"] if icons > 0 else "",
		", %d sound%s" % [sounds, "" if sounds == 1 else "s"] if sounds > 0 else "", ", unpacking" if bool(p["unpacking"]) else "", ModelPacks.where(p)]])
	for key: String in ["version", "author", "licence", "source", "url"]:
		if str(info.get(key, "")) != "":
			lines.append("%s: %s" % [key.capitalize(), info[key]])
	if shading_line(p) != "":
		lines.append(shading_line(p))
	if ModelPacks.refused(p):
		lines.append(PackCheck.REFUSED)
	elif str(p["problem"]) != "":
		lines.append("Left out: %s" % p["problem"])
	elif bool(p["checking"]):
		lines.append(PackCheck.CHECKING)
	elif bool(p["unchecked"]):
		lines.append(PackCheck.UNCHECKED)
	var facts := _wrapped("\n".join(lines))
	facts.name = "Facts"
	details.add_child(facts)
	if str(info.get("description", "")) != "":
		var about := _wrapped(str(info["description"]))
		about.name = "Description"
		about.add_theme_color_override("font_color", Kit.DISABLED_TEXT)
		details.add_child(about)


## Takes a family from `pack` whatever the order ("" back to the order's), saved and drawn at once.
func choose_pack(fam: String, pack: String) -> void:
	Sfx.play_ui("gui-click")
	var saved: Variant = Settings.get_value("model_packs", "choices")
	var map: Dictionary = (saved as Dictionary).duplicate() if saved is Dictionary else {}
	if pack == "":
		map.erase(fam)
	else:
		map[fam] = pack
	Settings.set_value("model_packs", "choices", map)
	ModelLibrary.apply_choices([fam])
	if world != null:
		world.models_changed([fam])
	_fill_models()
	_show_family()
	_say()


## Takes an item's model from `pack` whatever the order ("" back to the order's), saved as
## choices' "item:<name>"; items laid out from now on take it (item_models.gd follows the packs).
func choose_item_pack(item: String, pack: String) -> void:
	Sfx.play_ui("gui-click")
	var saved: Variant = Settings.get_value("model_packs", "choices")
	var map: Dictionary = (saved as Dictionary).duplicate() if saved is Dictionary else {}
	var key := ModelPacks.ITEM_PREFIX + item
	if pack == "":
		map.erase(key)
	else:
		map[key] = pack
	Settings.set_value("model_packs", "choices", map)
	ModelLibrary.apply_choices([key])
	_fill_models()
	_show_family()
	_say()


## Every family back to the order's.
func reset_choices() -> void:
	var saved: Variant = Settings.get_value("model_packs", "choices")
	var families: Array = (saved as Dictionary).keys() if saved is Dictionary else []
	if families.is_empty():
		return
	Settings.set_value("model_packs", "choices", {})
	ModelLibrary.apply_choices(families)
	if world != null:
		world.models_changed(families.filter(func(f) -> bool: return not str(f).begins_with(ModelPacks.ICON_PREFIX)))
	_fill_models()
	_show_family()
	_say()


func _say() -> void:
	var used := ModelPacks.model_count()
	var chosen := ModelPacks.model_choice_count()
	var items_chosen := ModelPacks.choices.keys().filter(func(k: Variant) -> bool: return str(k).begins_with(ModelPacks.ITEM_PREFIX)).size()
	var icons_chosen := ModelPacks.choices.size() - chosen - items_chosen
	var text := "%d models in use from %d packs." % [used, ModelPacks.active().size()]
	if chosen > 0:
		text += " %d model%s from a chosen pack." % [chosen, "" if chosen == 1 else "s"]
	if items_chosen > 0:
		text += " %d item%s from a chosen pack." % [items_chosen, "" if items_chosen == 1 else "s"]
	if icons_chosen > 0:
		text += " %d icon%s from a chosen pack." % [icons_chosen, "" if icons_chosen == 1 else "s"]
	if not ModelPacks.is_ready():
		text += " Unpacking a zip or checking a pack for copies of Factorio's files: its models come in a moment."
	if ModelPacks.models_dir == "":
		text += " Started with --no-custom-models: the models folder's packs are left out this run."
	if world != null:
		text += " Buildings and items change at once; trains, robots, creatures and inserter arms already drawn at the next start."
	_note.text = text
	(find_child("ResetChoices", true, false) as Button).disabled = ModelPacks.choices.is_empty()


static func _folder() -> String:
	return ModelPacks.folder if ModelPacks.folder != "" else ModelLibrary.custom_models_dir()
