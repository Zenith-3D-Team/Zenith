extends Node
## Esc with a tooltip showing. Godot spends an Esc on hiding a tooltip that is up (Viewport's GUI step,
## measured on 4.7.2) and nothing after it sees the key: with the mouse resting on anything whose
## tooltip showed, the first Esc closed nothing (seen on the technology screen's greyed Add to queue
## with its "Research queue full"). Every tooltip here is one of Godot's, a slot's or a recipe's too
## (Zenith's box inside Godot's popup, _make_custom_tooltip). Factorio's Esc closes the window,
## tooltip or not.
##
## So an Esc pressed while a tooltip shows is sent once more, after Godot has hidden the tooltip: the
## whole way again (a text box holding the keyboard still gets it first), ending where it would have
## without the tooltip. main.gd puts this node first among its children, so its _input is asked after
## every other node's: an Esc one of them took (a key being rebound, a screenshot being cancelled)
## never gets here. `--esc-tooltip=old`: as before, the first Esc only hides the tooltip.

const Switches := preload("res://scripts/switches.gd")

var enabled := not Switches.has("--esc-tooltip=old")
## How many were sent again (the UI test reads it).
var resent := 0
var _resending := false


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if not enabled or _resending or key == null or not key.pressed or key.echo or key.physical_keycode != KEY_ESCAPE:
		return
	var tip := showing(get_viewport())
	if tip != null:
		_resend_once_gone(tip, key)


## Godot marks the tooltip it hid to be freed at the frame's end, and until it is gone every Esc is
## spent on it: the key goes again the frame after. A tooltip still up and not marked wasn't what
## took the key, so nothing is sent.
func _resend_once_gone(tip: Window, key: InputEventKey) -> void:
	await get_tree().process_frame
	if is_instance_valid(tip) and not tip.is_queued_for_deletion():
		return
	for i in 4:
		if not is_instance_valid(tip):
			break
		await get_tree().process_frame
	if is_instance_valid(tip) or not is_inside_tree():
		return
	resent += 1
	_resending = true
	get_viewport().push_input(key)
	_resending = false


## Godot's tooltip for what the mouse is on, while it shows: a popup of theme type TooltipPanel that
## Godot adds under the control whose tooltip it is, the hovered one or one above it.
static func showing(viewport: Viewport) -> Window:
	var c: Node = viewport.gui_get_hovered_control() if viewport != null else null
	while c != null:
		for child in c.get_children(true):
			var popup := child as PopupPanel
			if popup != null and popup.visible and popup.theme_type_variation == &"TooltipPanel":
				return popup
		c = c.get_parent()
	return null
