extends CanvasLayer
## The debug menu's overlays (debug_menu.gd), each switched on there: a graph of the last frames'
## times with lines at 16.7 and 33.3 ms (60 and 30 fps), and counters of what is drawn and kept,
## twice a second: FPS, the renderer's draw calls, triangles and objects, nodes, chunks, entities,
## movers, items on belts and on the ground, and the 3D grass (decoratives.gd grass_stats(), what
## --grass-stats prints). Both read only what the engine and the layers count anyway.

const Kit := preload("res://scripts/ui/factorio/kit.gd")

const FRAMES := 300
const SCALE_MS := 50.0  # the graph's top
const COUNT_EVERY := 0.5

var main  # main.gd (counters of its layers; the engine's alone without it)
var graph := false:
	set(v):
		graph = v
		_update()
var counters := false:
	set(v):
		counters = v
		_update()

var _times := PackedFloat32Array()
var _at := 0
var _last_usec := 0
var _plot := Control.new()
var _text := Label.new()
var _count_left := 0.0


func _ready() -> void:
	layer = 115
	_times.resize(FRAMES)
	_plot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_plot.position = Kit.pxv(12, 260)
	_plot.size = Kit.pxv(360, 120)
	_plot.draw.connect(_draw_graph)
	add_child(_plot)
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text.position = Kit.pxv(12, 390)
	_text.add_theme_font_override("font", Kit.font("semibold"))
	_text.add_theme_font_size_override("font_size", Kit.px(14))
	_text.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_text.add_theme_constant_override("outline_size", Kit.px(4))
	add_child(_text)
	_update()


func _update() -> void:
	if not is_inside_tree():
		return
	_plot.visible = graph
	_text.visible = counters
	set_process(graph or counters)


func _process(delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _last_usec > 0:
		_times[_at] = (now - _last_usec) / 1000.0
		_at = (_at + 1) % FRAMES
	_last_usec = now
	if graph:
		_plot.queue_redraw()
	_count_left -= delta
	if counters and _count_left <= 0.0:
		_count_left = COUNT_EVERY
		_text.text = counter_text()


func _draw_graph() -> void:
	var size := _plot.size
	_plot.draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.55))
	for line in [[16.7, Color(0.49, 0.77, 0.42, 0.8)], [33.3, Color(0.95, 0.6, 0.18, 0.8)]]:
		var y := size.y * (1.0 - float(line[0]) / SCALE_MS)
		_plot.draw_line(Vector2(0, y), Vector2(size.x, y), line[1], 1.0)
	var points := PackedVector2Array()
	var sorted := PackedFloat32Array()
	for i in FRAMES:
		var ms := _times[(_at + i) % FRAMES]
		if ms <= 0.0:
			continue
		sorted.append(ms)
		points.append(Vector2(size.x * i / float(FRAMES - 1), size.y * (1.0 - minf(ms, SCALE_MS) / SCALE_MS)))
	if points.size() > 1:
		_plot.draw_polyline(points, Color(1.0, 0.9, 0.75), 1.5)
	if sorted.is_empty():
		return
	sorted.sort()
	var font := Kit.font("semibold")
	var text := "frame p50 %.1f  p99 %.1f  worst %.1f ms" % [sorted[sorted.size() / 2], sorted[mini(sorted.size() - 1, int(sorted.size() * 0.99))], sorted[-1]]
	_plot.draw_string(font, Vector2(Kit.px(6), Kit.px(16)), text, HORIZONTAL_ALIGNMENT_LEFT, -1, Kit.px(13), Color(1, 1, 1))


## The counters as lines of text (also for the UI test).
func counter_text() -> String:
	var lines := [
		"%d fps | %.1f ms" % [Engine.get_frames_per_second(), 1000.0 / maxf(Engine.get_frames_per_second(), 1.0)],
		"draw calls %d | triangles %s | objects %d" % [int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			_big(int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))), int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))],
		"nodes %d | video memory %.0f MB" % [int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0],
	]
	if main != null and main.world != null:
		lines.append("chunks %d loaded of %d | entities %d | view %d chunks, entities %d tiles" % [main.world.loaded_chunk_count(), main.world.chunks.size(),
			main.world.entity_count(), main.world.view_radius, main.world.focus_radius])
		lines.append("movers %d | belt items %d | on the ground %d" % [main.movers.count(), main.belt_items.count(), main.ground_items.count()])
		if main.decoratives != null:
			var g: Dictionary = main.decoratives.grass_stats()
			lines.append("3D grass: %d chunks, %s triangles (%s in view)" % [g["chunks"], _big(g["triangles"]), _big(g["view_triangles"])])
		lines.append("server tick %d | messages waiting %d" % [Bridge.server_tick, Bridge.waiting_count()])
	return "\n".join(PackedStringArray(lines))


static func _big(n: int) -> String:
	if n >= 1000000:
		return "%.2f M" % (n / 1000000.0)
	if n >= 1000:
		return "%.1f k" % (n / 1000.0)
	return str(n)
