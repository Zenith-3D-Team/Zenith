extends Control
## The stack in the cursor, drawn at the mouse like Factorio: the item's icon with its count in the
## count font (Factorio's count-font: default-bold 13, bordered), over windows and over the world
## (`over_world_too`, which player_input.gd sets true for buildings too unless `--cursor-icon-world=old`,
## where a build ghost shows only the count by the pointer, L7). factorio_ui.gd sets `item`, `count`
## and `over_gui`.

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const Switches := preload("res://scripts/switches.gd")

## L7 (the owner's playtest: "I can't see how many big electric poles I have through my hand"):
## holding a building over the world showed its ghost and no count at all. `--cursor-count=old`: none.
static var count_fix := not (Switches.has("--cursor-count=old"))

var item := ""
## -1 hides the count.
var count := -1
## Also drawn over the world (player_input.gd: no build ghost is showing).
var over_world_too := false
## Over a window this frame (factorio_ui.gd).
var over_gui := false
## Where to draw instead of the mouse (--ui-hover, for screenshots); x < 0: the mouse.
var debug_at := Vector2(-1, -1)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = Kit.ICON_FILTER
	z_index = 100


## Whether the last _draw drew the stack (so hiding it redraws once more, to clear it).
var _drawn := false


func _process(_delta: float) -> void:
	if _drawn or shown() or count_shown():
		queue_redraw()


## The icon and its count: over a window, or over the world where no build ghost shows.
func shown() -> bool:
	return item != "" and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE and (over_gui or over_world_too)


## The count alone, by the pointer: over the world where the held building's ghost shows (L7). None
## for an empty hand (a ghost cursor: Factorio's has no count either).
func count_shown() -> bool:
	return count_fix and item != "" and count > 0 and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE \
		and not over_gui and not over_world_too


func _draw() -> void:
	var icon := shown()
	_drawn = icon or count_shown()
	if not _drawn:
		return
	var at := get_local_mouse_position() if debug_at.x < 0 else debug_at
	var side := float(Kit.px(32))
	# Down and right of the pointer's tip, so the pointer still shows where a click lands. The count
	# alone stays where it is with the icon, so it doesn't jump as the mouse leaves a window.
	var rect := Rect2(at + Vector2(Kit.px(6), Kit.px(6)), Vector2(side, side))
	if icon:
		draw_texture_rect(Kit.item_icon(item), rect, false)
	if count >= 0:
		var f := Kit.font("bold")
		var fs := Kit.px(13)
		var text := Kit.count_text(count)
		var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var pos := rect.end - Vector2(w - Kit.px(2), -Kit.px(2))
		draw_string_outline(f, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Kit.px(3), Color(0, 0, 0, 0.9))
		draw_string(f, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)
