extends StyleBox
## Several style boxes drawn on top of each other, the way Factorio draws a graphical set: its
## shadow, then the base image, then the glow. The content margins are the element's padding.

# Exported so duplicate() copies it: a plain var isn't stored, and a copy drew nothing (the Model
# packs window's selected row, whose copy only changes the margins, showed no orange).
@export var layers: Array[StyleBox] = []


func _draw(to_canvas_item: RID, rect: Rect2) -> void:
	for layer in layers:
		layer.draw(to_canvas_item, rect)
