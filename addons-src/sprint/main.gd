extends Node
## Sprint: hold the Sprint key (Shift) to run faster. An add-on can't change the game itself, so it
## asks its Factorio mod, zenith-sprint (mod/zenith-sprint), over api.game; the mod, which every
## player in the game has, makes the character faster and slows it again. Messages are best-effort:
## while the key is held the add-on says "on" again every half second, and the mod stops the sprint
## by itself when it hears nothing for a moment and a half.

const CHANNEL := "zenith-sprint"
const REPEAT := 0.5

var api
var _on := false
var _since := 0.0
var _told_missing := false


func addon_start(a) -> void:
	api = a
	api.keys.add("sprint", "Sprint (hold)", ["Shift"])
	api.game.open(CHANNEL)
	api.game.link_changed.connect(_on_link)


func addon_stop() -> void:
	_say(false)


func _on_link(_on_now: bool) -> void:
	_on = false
	_told_missing = false


func _process(delta: float) -> void:
	var want: bool = api.in_game() and api.keys.held("sprint")
	if want and api.game.mod(CHANNEL) == "":
		if not _told_missing and api.game.available():
			_told_missing = true
			api.ui.message("Sprint needs the Factorio mod zenith-sprint in this game")
		return
	_since += delta
	if want != _on or (want and _since >= REPEAT):
		_say(want)


func _say(on: bool) -> void:
	if api.game.send(CHANNEL, {"on": on}) or not on:
		_on = on
		_since = 0.0
