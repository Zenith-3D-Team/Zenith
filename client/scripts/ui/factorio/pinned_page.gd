extends PanelContainer
## A Factoriopedia page pinned to the screen (the pedia's Pin button): a small window with the
## thing's icon, name and description that stays when Factoriopedia is closed. Drag it by its title,
## close it with its X, click its icon row to open the full page.

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const RichText := preload("res://scripts/ui/factorio/rich_text.gd")
const Info := preload("res://scripts/ui/factorio/info_text.gd")

signal open_page(kind: String, name: String)
signal closed

const WIDTH := 300

var kind := ""
var thing := ""


func setup(new_kind: String, name: String) -> void:
	kind = new_kind
	thing = name
	theme_type_variation = "FFrame"
	custom_minimum_size.x = Kit.px(WIDTH)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Kit.px(6))
	add_child(box)
	var bar := Kit.title_bar("Factoriopedia", true)
	(bar.get_child(bar.get_child_count() - 1) as Button).pressed.connect(func() -> void: closed.emit())
	box.add_child(bar)
	var row := Button.new()
	row.name = "Open"
	row.flat = true
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.text = Info.display_name(kind, thing)
	row.icon = RichText.icon(kind, thing)
	row.expand_icon = true
	row.tooltip_text = "Open in Factoriopedia"
	row.pressed.connect(func() -> void: open_page.emit(kind, thing))
	box.add_child(row)
	var desc := Info.description(kind, thing)
	if desc != "":
		var dl := Kit.label(desc)
		dl.autowrap_mode = TextServer.AUTOWRAP_WORD
		dl.custom_minimum_size.x = Kit.px(WIDTH - 24)
		box.add_child(dl)
