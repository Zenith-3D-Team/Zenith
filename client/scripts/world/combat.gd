extends Node3D
## Combat on screen: health bars over damaged entities (`hp`), dead movers taken away at once
## (`died`; fx.gd plays their dying explosion), and where the character aims while it fires (`me.sh`). Its shots themselves (muzzle
## flash, hits, casings) come from the bridge's `shot` and are drawn by fx/weapon_fx.gd.

const WorldMirror := preload("res://scripts/world/world.gd")
const MoverLayer := preload("res://scripts/world/movers.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const Avatar := preload("res://scripts/player/avatar.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const InterfaceState := preload("res://scripts/ui/interface_state.gd")
const Switches := preload("res://scripts/switches.gd")

const BAR_SIZE := Vector2(0.9, 0.12)
const BAR_LIFT := 0.5  # above the top of the entity it belongs to
const MOVER_BAR_HEIGHT := 1.2
const AVATAR_BAR_HEIGHT := 2.2
const GUN_RANGE := 18.0
const MUZZLE_HEIGHT := 1.1

var world: WorldMirror
var movers: MoverLayer
var avatar: Avatar
## Set by the input: -1 not shooting, 0 at enemies near the character, 1 at `aim` (tiles).
var aim_mode := -1
var aim := Vector2.ZERO

## --health-bars=auto (default): drawn with the interface, gone while it is hidden (F11, an add-on's
## hide_interface, --clean-shot: interface_state.gd); always: drawn even then (as before); off: never.
static var bars_mode := "auto"

var _health := {}  # unit -> 0..1, from the latest complete hp update
var _incoming := {}
var _frame_tick := -1
var _back := MultiMeshInstance3D.new()
var _fill := MultiMeshInstance3D.new()


static func configure_from_command_line() -> void:
	for arg in Switches.args():
		if arg.begins_with("--health-bars="):
			var v := arg.get_slice("=", 1)
			if v == "auto" or v == "always" or v == "off":
				bars_mode = v


## Whether the bars are drawn this frame (the mode and the interface's one flag).
static func bars_wanted() -> bool:
	if bars_mode == "off":
		return false
	return bars_mode == "always" or not InterfaceState.hidden()


func _ready() -> void:
	configure_from_command_line()
	for pair in [[_back, 0], [_fill, 1]]:
		var mmi: MultiMeshInstance3D = pair[0]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE
		mm.mesh = quad
		mmi.multimesh = mm
		mmi.material_override = _bar_material(int(pair[1]))
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)


func reset() -> void:
	_health.clear()
	_incoming.clear()
	_frame_tick = -1


## One part of {t: "hp", k, part, parts, l: [unit, health in thousandths, ...]}: the full list of
## damaged entities near the camera, used once its last part is in.
func handle_health(msg: Dictionary) -> void:
	var k := int(msg.get("k", 0))
	if k != _frame_tick:
		_frame_tick = k
		_incoming = {}
	var list = msg.get("l")
	if list is Array:
		var i := 0
		while i + 1 < list.size():
			_incoming[int(list[i])] = int(list[i + 1]) / 1000.0
			i += 2
	if int(msg.get("part", 1)) >= int(msg.get("parts", 1)):
		_health = _incoming
		_incoming = {}


## {t: "died", u, p, x, y, cx?, cy?, dt?, dmg?, src?}: a dead mover goes at once rather than when it stops showing up in
## `mv`; a building's `del` comes separately.
func handle_died(msg: Dictionary) -> void:
	var unit := int(msg.get("u", 0))
	_health.erase(unit)
	if unit != 0:
		var cause: Variant = Vector3(int(msg["cx"]) / 256.0, 0.0, int(msg["cy"]) / 256.0) if msg.has("cx") and msg.has("cy") else null
		var dt := str(msg.get("dt", ""))
		var dmg := int(msg.get("dmg", 0))
		var src := str(msg.get("src", ""))
		if movers != null and movers.creatures != null:
			movers.creatures.set_pending_death(unit, cause, dt, dmg, src)
		movers.remove(unit)
		if movers != null and movers.creatures != null:
			movers.creatures.clear_pending_death(unit)


func _process(delta: float) -> void:
	_update_aim()
	_update_bars()


## What the character turns and holds its gun towards (character_anim.gd): the aim point, or with
## Space the nearest enemy, which is a good guess at the one the game picks.
func _update_aim() -> void:
	if avatar == null:
		return
	var target = null
	if aim_mode == 1:
		target = Vector3(aim.x, 0.4, aim.y)
	elif aim_mode == 0:
		var found = movers.nearest_enemy(avatar.position, GUN_RANGE)
		if found != null:
			var enemy: Vector3 = found
			target = enemy + Vector3(0, 0.4, 0)
	avatar.aim_target = target


## Bars face the camera: a dark back and a fill from green to red, drawn over everything.
func _update_bars() -> void:
	var cam := get_viewport().get_camera_3d()
	var back := _back.multimesh
	var fill := _fill.multimesh
	if cam == null or _health.is_empty() or not bars_wanted():
		back.visible_instance_count = 0
		fill.visible_instance_count = 0
		return
	if back.instance_count < _health.size():
		back.instance_count = _health.size() * 2
		fill.instance_count = _health.size() * 2
	var face := cam.global_transform.basis
	var back_shape := face * Basis.from_scale(Vector3(BAR_SIZE.x, BAR_SIZE.y, 1.0))
	var right := face.x.normalized()
	var toward := face.z.normalized() * 0.01
	var n := 0
	for unit in _health:
		var p = _bar_position(int(unit))
		if p == null:
			continue
		var at: Vector3 = p
		var ratio: float = clampf(_health[unit], 0.0, 1.0)
		back.set_instance_transform(n, Transform3D(back_shape, at))
		back.set_instance_color(n, Color(0.05, 0.05, 0.05, 0.8))
		var w := maxf(BAR_SIZE.x * ratio, 0.001)
		var centre := at - right * (BAR_SIZE.x - w) * 0.5 + toward
		var fill_shape := face * Basis.from_scale(Vector3(w, BAR_SIZE.y * 0.7, 1.0))
		fill.set_instance_transform(n, Transform3D(fill_shape, centre))
		fill.set_instance_color(n, Color(0.9, 0.2, 0.15).lerp(Color(0.3, 0.85, 0.25), ratio))
		n += 1
	back.visible_instance_count = n
	fill.visible_instance_count = n


func _bar_position(unit: int) -> Variant:
	if avatar != null and unit == avatar.unit:
		return avatar.position + Vector3(0, AVATAR_BAR_HEIGHT, 0) + avatar.lifted()  # over the drawn head (1.7)
	var mover = movers.position_of(unit)
	if mover != null:
		var at: Vector3 = mover
		return at + Vector3(0, MOVER_BAR_HEIGHT, 0)
	var rec: WorldMirror.Rec = world.entities.get(unit)
	if rec == null:
		return null
	var proto: ProtoDB.EntityProto = world.protos.entity(rec.proto_id)
	var height := Visuals.height_for(proto) if proto != null else 1.0
	return Vector3(rec.pos.x, height + BAR_LIFT, rec.pos.y)


static func _bar_material(priority: int) -> ShaderMaterial:
	# Vertex colours over everything, lifted with the entity onto the hills (ground_height.gd).
	return GroundHeight.overlay_material(priority)
