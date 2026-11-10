extends Node
## --mod-click-probe=<name>[,<name>...]: presses mods' buttons in Zenith's copies of their windows
## one at a time (mod_gui.gd press, as a click would), each once it exists, and logs what the mods'
## windows hold before and after: did the click reach the mod in Factorio? With no names it lists
## the clickable elements it finds. --mod-click-probe-quit ends the client after the last.
## Lines start MODCLICK.

const Settings := preload("res://scripts/menu/settings.gd")

var mod_gui: Control
var _names: Array = []
var _step := 0
var _wait := 0.0
var _pressed_at := -1.0
var _before := ""
var _t := 0.0


func _ready() -> void:
	var arg := Settings.arg_value("--mod-click-probe=")
	if arg != "":
		_names = Array(arg.split(","))


func _process(delta: float) -> void:
	if mod_gui == null:
		return
	_t += delta
	_wait -= delta
	if _wait > 0.0 or _t < 20.0:
		return
	_wait = 0.5
	if _names.is_empty():
		print("MODCLICK windows: %s" % snapshot())
		print("MODCLICK buttons: %s" % ", ".join(buttons()))
		_names = ["-"]
		return
	if _step >= _names.size():
		if Settings.has_arg("--mod-click-probe-quit"):
			print("MODCLICK done")
			get_tree().quit()
		return
	var name := str(_names[_step])
	if _pressed_at < 0.0:
		var c := mod_gui.find_child(name.validate_node_name(), true, false) as Control
		if c == null:
			return
		_before = snapshot()
		mod_gui.press(c)
		_pressed_at = _t
		var sent: Array = mod_gui.forwarded.back() if not mod_gui.forwarded.is_empty() else []
		print("MODCLICK pressed %s: Zenith %s, Factorio %s (display %s)" % [name, c.get_global_rect().get_center(), sent[0] if sent.size() > 0 else "not sent", mod_gui.display])
	elif _t - _pressed_at > 4.0:
		var after := snapshot()
		print("MODCLICK after %s: %s\n   before: %s\n   after:  %s" % [name, "CHANGED" if after != _before else "unchanged", _before, after])
		var clicks := preload("res://scripts/ui/factorio/factorio_clicks.gd")
		print("MODCLICK helper said: %s" % ", ".join(clicks.heard))  # mod_gui.gd reads the answers
		clicks.heard = PackedStringArray()
		_pressed_at = -1.0
		_step += 1


## Each mod window: its name and the text of its labels and buttons, in order.
func snapshot() -> String:
	var out := PackedStringArray()
	for w in mod_gui._windows.values():
		var node: Control = w["node"]
		var texts := PackedStringArray()
		_texts(node, texts)
		out.append("[%s]" % " | ".join(texts.slice(0, 12)))  # texts only: nodes are renamed on a rebuild
	return "; ".join(out)


func _texts(n: Node, out: PackedStringArray) -> void:
	if n is Label and (n as Label).text != "" and (n as Control).is_visible_in_tree():
		out.append((n as Label).text.left(30))
	elif n is Button and (n as Button).text != "" and (n as Control).is_visible_in_tree():
		out.append("<%s>" % (n as Button).text.left(30))
	for ch in n.get_children():
		_texts(ch, out)


func buttons() -> PackedStringArray:
	var out := PackedStringArray()
	_buttons(mod_gui, out)
	return out


func _buttons(n: Node, out: PackedStringArray) -> void:
	if n is BaseButton:
		out.append("%s %s" % [n.name, (n as Control).get_global_rect()])
	for ch in n.get_children():
		_buttons(ch, out)
