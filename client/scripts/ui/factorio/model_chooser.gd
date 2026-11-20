extends Control
## The model chooser (M8): the Model button in a building's window opens it, a card for every pack
## in use with a model of that building (its own variant: a curve for a curved belt, the direction
## it faces), each turning in its preview (model_preview.gd). "This one" draws that building with
## the pack's model whatever the order, kept for this save until it is mined (building_models.gd,
## world.gd set_building_pack); "Every one" takes the model (its family, every variant) from that
## pack for every building of its kind, as the Model packs window does (settings.cfg choices,
## world.gd models_changed). Both apply at once: the building moves to that model's MultiMesh in
## its chunk. The cards say which one this building and the rest use. Client only: nothing goes to
## the game. Controls are named for tests: "card-<pack id>" (its "ThisOne", "EveryOne"), "Usual",
## "ByOrder".

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const MenuKit := preload("res://scripts/menu/menu_kit.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const Sfx := preload("res://scripts/fx/sfx.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const BuildingModels := preload("res://scripts/world/building_models.gd")
const ModelPreview := preload("res://scripts/ui/factorio/model_preview.gd")

## The building shown (its unit number) and the world it is in.
var unit := 0
var world = null
var _proto_name := ""
var _proto_type := ""
var _title: Label
var _cards := HBoxContainer.new()
var _state: Label


func _ready() -> void:
	name = "ModelChooser"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var frame := Kit.panel("FFrame")
	center.add_child(frame)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Kit.px(8))
	frame.add_child(box)
	var bar := Kit.title_bar("Model", true)
	_title = bar.get_child(0)
	(bar.get_child(bar.get_child_count() - 1) as Button).pressed.connect(close)
	box.add_child(bar)
	var scroll := ScrollContainer.new()
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Kit.pxv(860, 0)
	scroll.focus_mode = Control.FOCUS_NONE
	box.add_child(scroll)
	_cards.name = "Cards"
	_cards.add_theme_constant_override("separation", Kit.px(8))
	scroll.add_child(_cards)
	_state = Kit.label("")
	_state.name = "State"
	_state.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_state.custom_minimum_size.x = Kit.px(860)
	box.add_child(_state)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Kit.px(8))
	box.add_child(row)
	var usual := MenuKit.button("Usual model")
	usual.name = "Usual"
	usual.tooltip_text = "This building drawn as every other of its kind"
	usual.pressed.connect(func() -> void: choose_this(""))
	row.add_child(usual)
	var order := MenuKit.button("Every one by the order")
	order.name = "ByOrder"
	order.tooltip_text = "Every building of its kind from the highest pack in use that has it (Model packs)"
	order.pressed.connect(func() -> void: choose_every(""))
	row.add_child(order)


## Opens for a building: its unit, prototype and the world it is in.
func open(target_unit: int, proto_name: String, proto_type: String, in_world) -> void:
	unit = target_unit
	_proto_name = proto_name
	_proto_type = proto_type
	world = in_world
	visible = unit > 0 and proto_name != ""
	if visible:
		_fill()


func close() -> void:
	visible = false
	for c in _cards.get_children():
		_cards.remove_child(c)
		c.queue_free()


func is_open() -> bool:
	return visible


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if visible and key != null and key.pressed and not key.echo and key.physical_keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		close()


## The building's record ({} when it isn't in the world now).
func _record():
	return world.entities.get(unit) if world != null and unit > 0 else null


## The building's model, as `pack` would draw it ("" the usual): its variant's name and the extra
## that picks it.
func _model_for(pack: String) -> String:
	var r = _record()
	var extra: Dictionary = (r.extra as Dictionary).duplicate() if r != null else {}
	var dir: int = int(r.dir) if r != null else 0
	extra.erase(ModelLibrary.PACK_KEY)
	if pack != "":
		extra[ModelLibrary.PACK_KEY] = pack
	var names := ModelLibrary.entity_models(_proto_name, _proto_type, extra, dir)
	return str(names[0])


## The packs in use with a model of this building (or its tier's base): in their order.
func packs_having() -> Array:
	var out: Array = []
	for p: Dictionary in ModelPacks.active():
		var id := str(p["id"])
		var own := _model_for(id)
		var file := ModelLibrary.file_of(own)
		if ModelLibrary._pack_draws(id, file) or ModelLibrary._pack_draws(id, _proto_name):
			out.append(p)
	return out


func _fill() -> void:
	for c in _cards.get_children():
		_cards.remove_child(c)
		c.queue_free()
	_title.text = "Model: %s" % Kit.entity_name(_proto_name)
	var family := ModelPacks.family(_proto_name)
	var own := BuildingModels.pack_for(_save_id(), unit)
	var every := ModelPacks.choice(_proto_name)
	var usual := _usual_pack()
	for p: Dictionary in packs_having():
		var id := str(p["id"])
		var card := Kit.panel("FShallowFrame")
		card.name = "card-" + id.replace(":", "_")
		card.set_meta("pack", id)
		var pad := MarginContainer.new()
		for side in ["left", "top", "right", "bottom"]:
			pad.add_theme_constant_override("margin_" + side, Kit.px(6))
		card.add_child(pad)
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", Kit.px(4))
		pad.add_child(v)
		var frame := Kit.panel("FDeepFrame")
		v.add_child(frame)
		var preview := ModelPreview.new()
		preview.name = "Preview"
		preview.custom_minimum_size = Kit.pxv(200, 160)
		frame.add_child(preview)
		preview.show_model(_model_for(id))
		var title := Kit.label(str(p["title"]), "FHeading")
		v.add_child(title)
		var marks := PackedStringArray()
		if own == id or (own == "" and usual == id):
			marks.append("this building")
		if usual == id:
			marks.append("every other one" if own != "" and own != id else "every one")
		if every == id:
			marks.append("chosen")
		var mark := Kit.label(", ".join(marks) if not marks.is_empty() else " ")
		mark.name = "Marks"
		mark.add_theme_color_override("font_color", Kit.YELLOW_TEXT if own == id else Kit.DISABLED_TEXT)
		v.add_child(mark)
		var buttons := HBoxContainer.new()
		buttons.add_theme_constant_override("separation", Kit.px(4))
		v.add_child(buttons)
		var this_one := MenuKit.button("This one")
		this_one.name = "ThisOne"
		this_one.disabled = own == id
		this_one.tooltip_text = "This building drawn with %s's model (kept for this save until it is mined)" % p.get("short", p["title"])
		this_one.pressed.connect(func() -> void: choose_this(id))
		buttons.add_child(this_one)
		var every_one := MenuKit.button("Every one")
		every_one.name = "EveryOne"
		every_one.disabled = every == id
		every_one.tooltip_text = "Every %s drawn with %s's model, whatever the order (Model packs)" % [Kit.entity_name(_proto_name), p.get("short", p["title"])]
		every_one.pressed.connect(func() -> void: choose_every(id))
		buttons.add_child(every_one)
		_cards.add_child(card)
	var text := "Its family: %s. " % family
	text += ("This building: %s's model. " % _title_of(own)) if own != "" else "This building: as the others. "
	text += "The others: %s's (%s)." % [_title_of(usual), "chosen" if every != "" else "the order's"]
	_state.text = text
	(find_child("Usual", true, false) as Button).disabled = own == ""
	(find_child("ByOrder", true, false) as Button).disabled = every == ""


## The pack the other buildings of this kind are drawn from now (the order's or the chosen one).
func _usual_pack() -> String:
	var name := _model_for("")
	var alias := ModelLibrary._alias_of(name)
	var drawn := alias if alias != "" else name
	var src := ModelLibrary._source(drawn)
	if src == "" and ModelLibrary._tier_base(drawn) != "":
		src = ModelLibrary._source(ModelLibrary._tier_base(drawn))
	return str(ModelPacks.pack_of(src).get("id", ""))


static func _title_of(id: String) -> String:
	var p := ModelPacks.pack(id)
	return str(p.get("short", p["title"])) if not p.is_empty() else (id if id != "" else "none")


## The save the bridge said it plays (the welcome's `sid`), whose buildings' choices these are.
func _save_id() -> String:
	return Bridge.save_id


## This building from `pack` ("" as the others), at once.
func choose_this(pack: String) -> void:
	Sfx.play_ui("gui-click")
	if world != null:
		world.set_building_pack(unit, pack)
	else:
		BuildingModels.choose(_save_id(), unit, pack)
	_fill()


## Every building of its kind from `pack` ("" back to the order's), at once.
func choose_every(pack: String) -> void:
	Sfx.play_ui("gui-click")
	var family := ModelPacks.family(_proto_name)
	var saved: Variant = Settings.get_value("model_packs", "choices")
	var map: Dictionary = (saved as Dictionary).duplicate() if saved is Dictionary else {}
	if pack == "":
		map.erase(family)
	else:
		map[family] = pack
	Settings.set_value("model_packs", "choices", map)
	ModelLibrary.apply_choices([family])
	if world != null:
		world.models_changed([family])
	_fill()
