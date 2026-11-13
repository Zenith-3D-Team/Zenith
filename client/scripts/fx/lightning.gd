extends Node3D
## Fulgora's lightning (`lt`): each strike the bridge reports is drawn as Factorio draws it, a jagged
## blue-white bolt down from the sky with a few forks, flickering out over the prototype's
## effect_duration (36 ticks), and a flash of light on the ground round it. fx.gd plays the
## prototype's sound with it and main.gd lights the sky. Until now a strike only lit the lightning
## rod it hit (anim.gd), so a storm went by unseen.
##
## Factorio draws its bolt with a shader from the prototype's graphics_set (bolt_detail_level 5,
## colours {0, 0.6, 1}); here it is midpoint displacement to as many levels, as two camera-facing
## ribbons (a white core and a blue glow), rebuilt each frame while a bolt is out.

const BoltShader := preload("res://shaders/lightning_bolt.gdshader")

## Seconds a bolt is drawn (the prototype's effect_duration, 36 ticks).
const LIFE := 0.6
## How high the bolt starts (tiles): Factorio's source_offset is 25 tiles up its picture.
const HEIGHT := 32.0
## Levels of midpoint displacement (the prototype's bolt_detail_level), and how far a midpoint may
## move sideways, as a share of its segment's length.
const DETAIL := 5
const JITTER := 0.32
## Forks off the main bolt, and their length as a share of what is left of it below.
const FORKS := Vector2i(1, 3)
const FORK_LENGTH := 0.35
## Ribbon widths (tiles): the core and the glow round it.
const CORE := 0.16
const GLOW := 1.1
const CORE_COLOR := Color(0.82, 0.93, 1.0)
const GLOW_COLOR := Color(0.0, 0.6, 1.0)
## The light on the ground: energy at the strike, reach (tiles). At most LIGHTS at once.
const LIGHT_ENERGY := 8.0
const LIGHT_RANGE := 28.0
const LIGHTS := 4
## Bolts drawn at once; a storm's further ones wait their turn.
const MAX_BOLTS := 12

class Bolt:
	var paths: Array = []  # Array of PackedVector3Array: the main bolt first, then its forks
	var age := 0.0
	var phase := 0.0
	var light: OmniLight3D

## Bolts out now (tests).
var bolts: Array[Bolt] = []
var _mesh := ImmediateMesh.new()
var _node := MeshInstance3D.new()
var _material := ShaderMaterial.new()
var _lights: Array[OmniLight3D] = []
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_material.shader = BoltShader
	_node.mesh = _mesh
	_node.material_override = _material
	_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The bolts move every frame and are thin: one box round the whole sky above the ground drawn,
	# rather than working one out per frame.
	_node.custom_aabb = AABB(Vector3(-1e5, -1.0, -1e5), Vector3(2e5, HEIGHT + 20.0, 2e5))
	add_child(_node)
	for i in LIGHTS:
		var l := OmniLight3D.new()
		l.light_color = Color(0.62, 0.8, 1.0)
		l.omni_range = LIGHT_RANGE
		l.shadow_enabled = false
		l.visible = false
		add_child(l)
		_lights.append(l)


## A strike landed at `at` (tiles, Factorio x/y); `caught` when a lightning rod or collector took it.
func strike(at: Vector2, caught := false) -> void:
	if bolts.size() >= MAX_BOLTS:
		return
	var b := Bolt.new()
	b.phase = _rng.randf() * 100.0
	# A rod or collector that caught it is struck at its tip, as Factorio draws it.
	var ground := Vector3(at.x, 3.0 if caught else 0.0, at.y)
	var top := ground + Vector3(_rng.randf_range(-4.0, 4.0), HEIGHT * _rng.randf_range(0.9, 1.1), _rng.randf_range(-3.0, 3.0))
	var main := _jagged(top, ground, DETAIL)
	b.paths.append(main)
	for _f in _rng.randi_range(FORKS.x, FORKS.y):
		var from := _rng.randi_range(int(main.size() * 0.2), int(main.size() * 0.6))
		var start := main[from]
		var left := start.y
		var dir := Vector3(_rng.randf_range(-1.0, 1.0), -1.2, _rng.randf_range(-1.0, 1.0)).normalized()
		b.paths.append(_jagged(start, start + dir * left * FORK_LENGTH * _rng.randf_range(0.6, 1.4), DETAIL - 2))
	for l in _lights:
		if not l.visible:
			b.light = l
			l.position = ground + Vector3(0.0, 3.0, 0.0)
			l.visible = true
			break
	bolts.append(b)


## Points from `a` to `b`, each segment's middle moved sideways at random, `levels` times over.
func _jagged(a: Vector3, b: Vector3, levels: int) -> PackedVector3Array:
	var pts := PackedVector3Array([a, b])
	for level in levels:
		var out := PackedVector3Array()
		for i in pts.size() - 1:
			var p := pts[i]
			var q := pts[i + 1]
			var reach := p.distance_to(q) * JITTER
			out.append(p)
			out.append((p + q) * 0.5 + Vector3(_rng.randf_range(-reach, reach), _rng.randf_range(-reach, reach) * 0.3, _rng.randf_range(-reach, reach)))
		out.append(pts[-1])
		pts = out
	return pts


## How bright a bolt is at `age`: a few quick flickers, then out (Factorio's bolt pulses as it fades).
static func strength(age: float, phase: float) -> float:
	if age >= LIFE:
		return 0.0
	var t := age / LIFE
	var flicker := 0.55 + 0.45 * sin(age * 70.0 + phase) * sin(age * 31.0 + phase * 2.0)
	return clampf((1.0 - t * t) * flicker, 0.0, 1.0)


func _process(delta: float) -> void:
	_mesh.clear_surfaces()
	if bolts.is_empty():
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var eye := cam.global_position if cam != null else Vector3(0.0, 100.0, 0.0)
	var left: Array[Bolt] = []
	for b in bolts:
		b.age += delta
		if b.age < LIFE:
			left.append(b)
		elif b.light != null:
			b.light.visible = false
	bolts = left
	var lit := false
	for b in bolts:
		var s := strength(b.age, b.phase)
		if b.light != null:
			b.light.light_energy = LIGHT_ENERGY * s
		lit = lit or s > 0.01
	if not lit:
		return  # (an ImmediateMesh surface may not be empty)
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for b in bolts:
		var s := maxf(strength(b.age, b.phase), 0.01)
		for i in b.paths.size():
			var thin := 1.0 if i == 0 else 0.5
			var path: PackedVector3Array = b.paths[i]
			_ribbon(path, GLOW * thin, Color(GLOW_COLOR, 0.35 * s * thin), eye)
			_ribbon(path, CORE * thin, Color(CORE_COLOR, s * thin), eye)
	_mesh.surface_end()


## A ribbon `width` wide along `path`, turned to face `eye`.
func _ribbon(path: PackedVector3Array, width: float, color: Color, eye: Vector3) -> void:
	for i in path.size() - 1:
		var p := path[i]
		var q := path[i + 1]
		var along := q - p
		var side := along.cross(eye - (p + q) * 0.5)
		if side.length_squared() < 1e-8:
			continue
		side = side.normalized() * (width * 0.5)
		_mesh.surface_set_color(color)
		_mesh.surface_set_uv(Vector2(0.0, 0.0))
		_mesh.surface_add_vertex(p - side)
		_mesh.surface_set_uv(Vector2(1.0, 0.0))
		_mesh.surface_add_vertex(p + side)
		_mesh.surface_set_uv(Vector2(1.0, 1.0))
		_mesh.surface_add_vertex(q + side)
		_mesh.surface_set_uv(Vector2(0.0, 0.0))
		_mesh.surface_add_vertex(p - side)
		_mesh.surface_set_uv(Vector2(1.0, 1.0))
		_mesh.surface_add_vertex(q + side)
		_mesh.surface_set_uv(Vector2(0.0, 1.0))
		_mesh.surface_add_vertex(q - side)


## Everything out (a new surface or game).
func clear() -> void:
	bolts.clear()
	_mesh.clear_surfaces()
	for l in _lights:
		l.visible = false
