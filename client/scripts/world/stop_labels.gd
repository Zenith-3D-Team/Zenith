extends Node3D
## Alt-mode's train stop names: hidden in normal play by default so station names show only in map view
## (`map_layers.gd`). With `--stop-labels=alt`, each train stop near the camera's focus shows its name
## over it while Alt-mode is on, as Factorio's entity info does (the name from the record's `extra.n`).
## Rich text tags in a name ([item=..] and so on) are left out. Found per chunk and kept until that
## chunk's entities change.

const WorldMirror := preload("res://scripts/world/world.gd")
const Kit := preload("res://scripts/ui/factorio/kit.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const Switches := preload("res://scripts/switches.gd")

## Over the stop (about 2.2 tiles tall).
const HEIGHT := 2.8
## Chunks round the focus looked at, and the most labels shown.
const CHUNK_RADIUS := 3
const MAX_LABELS := 64
const REFRESH := 0.25

## --stop-labels=alt restores 3D stop names over train stops in Alt-mode; default keeps them map-view only.
static var enabled := Switches.value("--stop-labels", "map") == "alt"

var world: WorldMirror
var alt_mode := false

var _wired: WorldMirror = null
var _stops := {}  # chunk -> [[position Vector2, name]] (absent: not looked at yet)
var _labels: Array[Label3D] = []
var _timer := 0.0
var _tag_re := RegEx.create_from_string(r"\[[^\]]*\]")


func _exit_tree() -> void:
	if is_instance_valid(_wired) and _wired.entities_changed.is_connected(_on_changed):
		_wired.entities_changed.disconnect(_on_changed)


func _on_changed(c: Vector2i) -> void:
	_stops.erase(c)


func _process(delta: float) -> void:
	if _wired != world:
		if is_instance_valid(_wired) and _wired.entities_changed.is_connected(_on_changed):
			_wired.entities_changed.disconnect(_on_changed)
		_wired = world
		_stops.clear()
		if world != null:
			world.entities_changed.connect(_on_changed)
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = REFRESH
	if world == null or not enabled or not alt_mode:
		_show([])
		return
	var f: Vector2 = world.focus()
	var fc := Vector2i(floori(f.x / 32.0), floori(f.y / 32.0))
	var found: Array = []
	for dx in range(-CHUNK_RADIUS, CHUNK_RADIUS + 1):
		for dy in range(-CHUNK_RADIUS, CHUNK_RADIUS + 1):
			var c := fc + Vector2i(dx, dy)
			if not _stops.has(c):
				_stops[c] = _find(c)
			found.append_array(_stops[c])
	if found.size() > MAX_LABELS:
		found.sort_custom(func(a, b) -> bool: return (a[0] as Vector2).distance_squared_to(f) < (b[0] as Vector2).distance_squared_to(f))
		found.resize(MAX_LABELS)
	_show(found)


## The train stops of a chunk: [[position, name], ...].
func _find(c: Vector2i) -> Array:
	var out: Array = []
	var cv = world.chunks.get(c)
	if cv == null:
		return out
	for key in cv.entities:
		var r: WorldMirror.Rec = cv.entities[key]
		var proto = world.protos.entity(r.proto_id)
		if proto == null or proto.type != "train-stop":
			continue
		var text: String = _tag_re.sub(str(r.extra.get("n", "")), "", true).strip_edges()
		if text != "":
			out.append([r.pos, text])
	return out


func _show(list: Array) -> void:
	while _labels.size() < list.size():
		var l := _make_label()
		add_child(l)
		_labels.append(l)
	for i in _labels.size():
		var l := _labels[i]
		l.visible = i < list.size()
		if l.visible:
			var at: Vector2 = list[i][0]
			if l.text != str(list[i][1]):
				l.text = str(list[i][1])
			l.position = GroundHeight.lift(Vector3(at.x, HEIGHT, at.y))


## How many names are shown (tests).
func shown() -> int:
	var n := 0
	for l in _labels:
		n += 1 if l.visible else 0
	return n


func _make_label() -> Label3D:
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.fixed_size = true
	l.pixel_size = 0.0006
	l.font_size = 22
	l.outline_size = 8
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.no_depth_test = true
	l.render_priority = 10
	var f := Kit.font("bold")
	if f != null:
		l.font = f
	return l
