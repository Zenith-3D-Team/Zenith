extends TextureRect
## The night vision equipment's own icon (from the player's Factorio install, as the quickbar's items) while
## night vision is on, over the shortcut bar beside the alerts (factorio_ui.gd places it). Faded with
## main.gd's `_night_vision`; hidden once it is off, or with Settings > Interface > Night vision indicator
## off (`interface/night_vision_indicator`) or `--night-vision-fx=off`.

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const Overlay := preload("res://scripts/ui/night_vision_overlay.gd")

const ITEM := "night-vision-equipment"

## 0..1, as the overlay's.
var level := 0.0:
	set(v):
		level = v
		_update()


func _init() -> void:
	name = "NightVisionIcon"
	mouse_filter = Control.MOUSE_FILTER_PASS
	custom_minimum_size = Kit.pxv(Kit.SLOT, Kit.SLOT)
	size = custom_minimum_size
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	texture_filter = Kit.ICON_FILTER
	tooltip_text = "Night vision"
	visible = false


func _ready() -> void:
	texture = Kit.item_icon(ITEM)
	Settings.listen(_on_setting)


func _exit_tree() -> void:
	Settings.unlisten(_on_setting)


func _on_setting(section: String, key: String) -> void:
	if section == "interface" and key == "night_vision_indicator":
		_update()


func _update() -> void:
	var v := level if Overlay.indicator_enabled() else 0.0
	visible = v > 0.0
	modulate.a = v
