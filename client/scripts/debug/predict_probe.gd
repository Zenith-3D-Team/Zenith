extends Node
## --predict-probe=<out.json>[@builds]: how long a build waits for the game (the wait the latency
## layer, scripts/world/predicted.gd, hides). Stands the character still, then over and over builds
## a wooden chest two tiles east of it the way a click does (drag_build.gd), and once the game's
## chest is drawn mines it again. Records each build's milliseconds from the click to the game's
## chest drawn in its chunk, and how many predictions were refused. Needs wooden chests in the
## inventory (the mock and a new map have some). Writes the summary, prints it and quits.

const SETTLE := 6.0
const EVERY := 1.5

var main: Node  # main.gd: its world, input and predicted
var out_path := ""
var builds := 20

var _left := SETTLE
var _done := 0
var _chest_at := Vector2.INF
var _sent_msec := 0
var _drawn: Array = []  # ms from the click to the game's chest drawn (measured here, prediction or not)
var _shown: Array = []  # ms from the click to something drawn there (0 when predicted)


func _process(delta: float) -> void:
	if main == null or main.world == null or main.input == null or not Bridge.world_ready:
		return
	var world = main.world
	if _chest_at != Vector2.INF:
		var rec = world.pick(_chest_at)
		var is_chest: bool = rec != null and world.protos.entity(rec.proto_id).name == "wooden-chest"
		if is_chest and world._drawn(world.chunk_of(_chest_at)):
			_drawn.append(Time.get_ticks_msec() - _sent_msec)
			Bridge.send({"t": "mine", "u": rec.unit, "p": rec.proto_id, "x": rec.fixed.x, "y": rec.fixed.y})
			_chest_at = Vector2.INF
			_left = EVERY
		elif Time.get_ticks_msec() - _sent_msec > 5000:
			_chest_at = Vector2.INF  # never came: refused
			_left = EVERY
		return
	_left -= delta
	if _left > 0.0:
		return
	if _done >= builds:
		_finish()
		return
	Bridge.send({"t": "walk", "d": -1})
	var input = main.input
	var proto = world.protos.placed_entity("wooden-chest")
	if proto == null:
		return
	var at: Vector2 = world.focus() + Vector2(2.5, 0.0)
	at = Vector2(floorf(at.x) + 0.5, floorf(at.y) + 0.5)
	var before: int = main.predicted.count() if main.predicted != null else 0
	input.drag.begin("wooden-chest", proto, at, false)
	input.drag.end()
	_shown.append(0 if main.predicted != null and main.predicted.count() > before else -1)
	_sent_msec = Time.get_ticks_msec()
	_chest_at = at
	_done += 1


func _finish() -> void:
	var sorted := _drawn.duplicate()
	sorted.sort()
	var n := sorted.size()
	var summary := {
		"builds": _done, "drawn": n,
		"predicted": _shown.count(0),
		"refused": main.predicted.refused if main.predicted != null else 0,
		"wait_ms_p50": sorted[n / 2] if n > 0 else -1,
		"wait_ms_p90": sorted[mini(n - 1, n * 9 / 10)] if n > 0 else -1,
		"wait_ms_max": sorted[n - 1] if n > 0 else -1,
		"waits_ms": _drawn,
	}
	print("predict probe: ", JSON.stringify(summary))
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(summary, "  "))
	get_tree().quit()
