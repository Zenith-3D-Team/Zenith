extends Node
## A tiny add-on for tests/addon_test.gd: a global key, one whose default Zenith already uses, two
## camera keys, the game's signals, the camera's `lost`, options for the Mods window, and a setting
## of each type (API 1.1) for the Add-ons menu, and (1.7) the character's steps and hurts and the
## camera's mode, from watch() on (a handler on api.character starts Zenith watching, so not before).

var api
var started := 0
var stopped := 0
var games := 0
var lost := 0
var presses := 0
var changes: Array = []
var steps: Array = []
var hurt := Vector2i.ZERO
var modes: Array = []


func addon_start(a) -> void:
	api = a
	started += 1
	api.keys.add("toggle", "Toggle the test camera", [KEY_F8])
	api.keys.add("taken", "Wants Zenith's W", [KEY_W, KEY_F10])
	api.keys.add("fly", "Fly forward", [KEY_W, KEY_UP], "camera")
	api.keys.add("rise", "Fly up", ["Shift+E"], "camera")
	api.game_started.connect(func() -> void: games += 1)
	api.camera.lost.connect(func() -> void: lost += 1)
	api.ui.set_options(func(box: VBoxContainer) -> void: box.add_child(api.ui.label("Test options")))
	api.settings.add("loud", "bool", false, "Loud", {"section": "Sound"})
	api.settings.add("speed", "number", 8, "Speed", {"min": 1, "max": 40, "step": 1, "unit": "tiles/s"})
	api.settings.add("blur", "number", 0.5, "Blur", {"min": 0.0, "max": 1.0, "step": 0.05})
	api.settings.add("look", "choice", "down", "Looking", {"choices": [["Straight down", "down"], ["At Factorio's angle", "factorio"]]})
	api.settings.add("folder", "text", "", "Folder", {"placeholder": "Default"})
	api.settings.changed.connect(func(id: String, v: Variant) -> void: changes.append([id, v]))


func watch() -> void:
	api.character.footfall.connect(func(foot: String, _at: Vector3) -> void: steps.append(foot))
	api.character.damaged.connect(func(health: int, shield: int) -> void: hurt += Vector2i(health, shield))
	api.camera.mode_changed.connect(func(mode: String, before: String) -> void: modes.append([mode, before]))


func addon_stop() -> void:
	stopped += 1


func _unhandled_input(event: InputEvent) -> void:
	if api != null and api.keys.pressed(event, "fly"):
		presses += 1
