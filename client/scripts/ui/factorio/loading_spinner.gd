extends Control
## A loading icon: a ring of dots with the bright one going round, for a window waiting on the mod.
## Factorio has none (its data is there at once); ours comes over the bridge, under its work budget.

const DOTS := 12
## Milliseconds the bright dot stays on each place.
const STEP_MS := 80.0
const COLOR := Color8(255, 166, 0)


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	if is_visible_in_tree():
		queue_redraw()


func _draw() -> void:
	var middle := size * 0.5
	var dot := minf(size.x, size.y) * 0.09
	var ring := minf(size.x, size.y) * 0.5 - dot
	var head := floori(Time.get_ticks_msec() / STEP_MS)
	for i in DOTS:
		var angle := TAU * i / DOTS
		var age := float(posmod(head - i, DOTS)) / DOTS
		var c := COLOR
		c.a = 1.0 - age * 0.85
		draw_circle(middle + Vector2(sin(angle), -cos(angle)) * ring, dot, c)
