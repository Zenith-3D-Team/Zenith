extends Node3D
## High-drama 3D rocket launch pad and launch VFX:
## - Subterranean 26-tile cylindrical launch shaft with structural gantry rings, umbilical rails,
##   elevator cradle, hinged hold-down clamp arms, blast deflector pit floor, firelight & cooling embers
## - Multi-shell volumetric supersonic rocket exhaust plume with pulsating Mach shock diamonds,
##   throat glare, and ground-impingement plasma ring
## - Pooled 3D-lit fire-illuminated cumulus smoke puffs and ballistic velocity-stretched sparks
## - Pulsing crimson rim warning beacons

const GroundHeight := preload("res://scripts/world/ground_height.gd")
const MomentHold := preload("res://scripts/world/moment_hold.gd")

const ShaftShader := preload("res://shaders/silo_shaft.gdshader")
const PlumeShader := preload("res://shaders/rocket_plume.gdshader")
const RingShader := preload("res://shaders/rocket_ring.gdshader")
const SmokeShader := preload("res://shaders/rocket_smoke.gdshader")
const SparkShader := preload("res://shaders/rocket_sparks.gdshader")

const SHAFT_DEPTH := 26.0
const SMOKE_CAPACITY := 480
const SPARK_CAPACITY := 320
const BEACON_CAPACITY := 176  # 16 active silos * 11 beacons

static var _shaft_mesh: ArrayMesh
static var _elevator_mesh: ArrayMesh
static var _elevator_mat: StandardMaterial3D
static var _clamp_arm_mesh: ArrayMesh
static var _clamp_mat: StandardMaterial3D
static var _plume_core_mesh: ArrayMesh
static var _plume_mantle_mesh: ArrayMesh
static var _throat_mesh: SphereMesh
static var _ring_mesh: ArrayMesh
static var _quad_mesh: QuadMesh
static var _beacon_mesh: SphereMesh
static var _beacon_mat: StandardMaterial3D


## One silo's subterranean shaft, elevator cradle, clamp arms, pit light, and rim blast ring.
class SiloShaft:
	var unit := 0
	var center := Vector2.ZERO
	var radius := 2.6
	var root := Node3D.new()
	var shaft := MeshInstance3D.new()
	var shaft_mat := ShaderMaterial.new()
	var elevator := MeshInstance3D.new()
	var clamps_root := Node3D.new()
	var clamp_arms: Array[MeshInstance3D] = []
	var ring := MeshInstance3D.new()
	var ring_mat := ShaderMaterial.new()
	var pit_light := OmniLight3D.new()
	var fire_glow := 0.0
	var ember_glow := 0.0
	var alarm_glow := 0.0
	var shock := 0.0
	var lift := 0.0
	var clamps := 0.0
	var work_glow := 0.0


## Attached to a launching rocket: volumetric Mach-diamond core + turbulent combustion mantle.
class PlumeRig:
	var root := Node3D.new()
	var core := MeshInstance3D.new()
	var core_mat := ShaderMaterial.new()
	var mantle := MeshInstance3D.new()
	var mantle_mat := ShaderMaterial.new()
	var throat := MeshInstance3D.new()
	var throat_mat := StandardMaterial3D.new()


class SmokePuff:
	var pos := Vector3.ZERO
	var vel := Vector3.ZERO
	var age := 0.0
	var life := 1.0
	var size0 := 1.0
	var size1 := 4.0
	var color := Color.WHITE
	var heat := 0.0
	var seed := 0.0
	var spin := 0.0
	var spin_rate := 0.0
	var drag := 0.0
	var rise := 0.0


class Spark:
	var pos := Vector3.ZERO
	var vel := Vector3.ZERO
	var age := 0.0
	var life := 1.0
	var color := Color.WHITE
	var width := 0.14
	var drag := 0.7


var _shafts := {}  # unit -> SiloShaft
var _beacon_items: Array = []  # [Vector3(x, y, z), Color]
var _beacon_mmi := MultiMeshInstance3D.new()
var _beacon_mm := MultiMesh.new()
var _beacon_buf := PackedFloat32Array()

var _smoke_mmi := MultiMeshInstance3D.new()
var _smoke_mm := MultiMesh.new()
var _smoke_mat := ShaderMaterial.new()
var _smoke_buf := PackedFloat32Array()
var _smoke_puffs: Array[SmokePuff] = []
var _smoke_cursor := 0
var _smoke_shown := 0
var _smoke_brightness := -1.0

var _spark_mmi := MultiMeshInstance3D.new()
var _spark_mm := MultiMesh.new()
var _spark_mat := ShaderMaterial.new()
var _spark_buf := PackedFloat32Array()
var _sparks: Array[Spark] = []
var _spark_cursor := 0
var _spark_shown := 0

var night := 0.0


func _ready() -> void:
	_init_shared_meshes()
	_setup_smoke_pool()
	_setup_spark_pool()
	_setup_beacon_pool()


func reset() -> void:
	for s: SiloShaft in _shafts.values():
		if is_instance_valid(s.root):
			s.root.queue_free()
	_shafts.clear()
	_smoke_puffs.clear()
	_smoke_cursor = 0
	_smoke_mm.visible_instance_count = 0
	_smoke_shown = 0
	_sparks.clear()
	_spark_cursor = 0
	_spark_mm.visible_instance_count = 0
	_spark_shown = 0
	_beacon_items.clear()
	_beacon_mm.visible_instance_count = 0


func shaft_count() -> int:
	return _shafts.size()


func smoke_count() -> int:
	return _smoke_puffs.size()


func spark_count() -> int:
	return _sparks.size()


## Ensures a 3D subterranean launch shaft exists for silo `unit` at `center` with `radius`.
func ensure_shaft(unit: int, center: Vector2, radius: float) -> SiloShaft:
	var s: SiloShaft = _shafts.get(unit)
	if s == null:
		s = SiloShaft.new()
		s.unit = unit
		s.center = center
		s.radius = radius
		s.root.position = Vector3(center.x, 0.0, center.y)

		s.shaft_mat.shader = ShaftShader
		s.shaft_mat.set_shader_parameter("shaft_depth", SHAFT_DEPTH)
		s.shaft_mat.set_shader_parameter("shaft_radius", radius)
		s.shaft.mesh = _shaft_mesh
		s.shaft.material_override = s.shaft_mat
		s.shaft.scale = Vector3(radius, 1.0, radius)
		s.shaft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		s.shaft.custom_aabb = AABB(Vector3(-1.5, -SHAFT_DEPTH - 2.0, -1.5), Vector3(3.0, SHAFT_DEPTH + 4.0, 3.0))
		s.root.add_child(s.shaft)

		s.elevator.mesh = _elevator_mesh
		s.elevator.material_override = _elevator_mat
		s.elevator.scale = Vector3(radius, 1.0, radius)
		s.elevator.position = Vector3(0.0, -SHAFT_DEPTH + 0.15, 0.0)
		s.elevator.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		s.elevator.custom_aabb = AABB(Vector3(-1.2, -1.0, -1.2), Vector3(2.4, 16.0, 2.4))
		s.root.add_child(s.elevator)

		s.clamps_root.name = "Clamps"
		for k in 3:
			var ang := float(k) * TAU / 3.0 + 0.35
			var arm := MeshInstance3D.new()
			arm.mesh = _clamp_arm_mesh
			arm.material_override = _clamp_mat
			arm.position = Vector3(cos(ang) * radius * 0.94, -0.28, sin(ang) * radius * 0.94)
			arm.rotation = Vector3(-1.48, PI * 0.5 - ang, 0.0)
			arm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			s.clamps_root.add_child(arm)
			s.clamp_arms.append(arm)
		s.root.add_child(s.clamps_root)

		s.ring_mat.shader = RingShader
		s.ring.mesh = _ring_mesh
		s.ring.material_override = s.ring_mat
		s.ring.position = Vector3(0.0, 0.16, 0.0)
		s.ring.scale = Vector3(radius * 2.5, 1.0, radius * 2.5)
		s.ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		s.ring.visible = false
		s.root.add_child(s.ring)

		s.pit_light.light_color = Color(1.0, 0.56, 0.2)
		s.pit_light.omni_range = 28.0
		s.pit_light.omni_attenuation = 1.15
		s.pit_light.light_energy = 0.0
		s.pit_light.position = Vector3(0.0, -1.2, 0.0)
		s.pit_light.visible = false
		s.root.add_child(s.pit_light)

		add_child(s.root)
		_shafts[unit] = s
	elif s.center.distance_squared_to(center) > 0.001 or absf(s.radius - radius) > 0.001:
		s.center = center
		s.radius = radius
		s.root.position = Vector3(center.x, 0.0, center.y)
		s.shaft.scale = Vector3(radius, 1.0, radius)
		s.elevator.scale = Vector3(radius, 1.0, radius)
		for k in s.clamp_arms.size():
			var ang := float(k) * TAU / 3.0 + 0.35
			s.clamp_arms[k].position = Vector3(cos(ang) * radius * 0.94, -0.28, sin(ang) * radius * 0.94)
		s.shaft_mat.set_shader_parameter("shaft_radius", radius)
		s.ring.scale = Vector3(radius * 2.5, 1.0, radius * 2.5)
	return s


func sync_shafts(wanted: Dictionary, radius: float) -> void:
	for unit: int in _shafts.keys():
		if not wanted.has(unit):
			var s: SiloShaft = _shafts[unit]
			if is_instance_valid(s.root):
				s.root.queue_free()
			_shafts.erase(unit)
	for unit: int in wanted:
		ensure_shaft(unit, wanted[unit] as Vector2, radius)


func get_shaft(unit: int) -> SiloShaft:
	return _shafts.get(unit)


func update_shaft(s: SiloShaft, fire_glow: float, ember_glow: float, alarm_glow: float, shock: float,
		pit_energy: float, pit_color: Color, ring_intensity: float,
		lift := 0.0, clamps := 0.0, work_glow := 0.0) -> void:
	s.fire_glow = fire_glow
	s.ember_glow = ember_glow
	s.alarm_glow = alarm_glow
	s.shock = shock
	s.lift = clampf(lift, 0.0, 1.0)
	s.clamps = clampf(clamps, 0.0, 1.0)
	s.work_glow = clampf(work_glow, 0.0, 1.0)
	s.shaft_mat.set_shader_parameter("fire_glow", fire_glow)
	s.shaft_mat.set_shader_parameter("ember_glow", ember_glow)
	s.shaft_mat.set_shader_parameter("alarm_glow", alarm_glow)
	s.shaft_mat.set_shader_parameter("work_glow", s.work_glow)

	var ring_on := ring_intensity > 0.005 or (shock > 0.005 and shock < 0.99)
	s.ring.visible = ring_on
	if ring_on:
		s.ring_mat.set_shader_parameter("intensity", ring_intensity)
		s.ring_mat.set_shader_parameter("shock", shock)

	var gh := GroundHeight.at(s.center.x, s.center.y)
	s.elevator.position = Vector3(0.0, lerpf(-SHAFT_DEPTH + 0.15, -15.5, s.lift) + gh, 0.0)
	s.clamps_root.position.y = gh
	var arm_c := s.clamps * s.clamps * (3.0 - 2.0 * s.clamps)
	var pitch := lerpf(-1.48, 0.42, arm_c)
	for arm: MeshInstance3D in s.clamp_arms:
		arm.rotation.x = pitch

	s.pit_light.position = Vector3(0.0, lerpf(-1.0, -4.5, s.work_glow) + gh, 0.0)
	s.pit_light.light_color = pit_color
	s.pit_light.light_energy = pit_energy
	s.pit_light.visible = pit_energy > 0.02


## Builds and attaches the 3D volumetric exhaust plume rig to a rocket root node.
func attach_plume(rocket_root: Node3D) -> PlumeRig:
	var rig := PlumeRig.new()
	rig.root.position = Vector3(0.0, 0.15, 0.0)
	rig.root.visible = false

	rig.core_mat.shader = PlumeShader
	rig.core_mat.set_shader_parameter("is_core", 1.0)
	rig.core_mat.set_shader_parameter("time_offset", randf() * 10.0)
	rig.core.mesh = _plume_core_mesh
	rig.core.material_override = rig.core_mat
	rig.core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rig.core.custom_aabb = AABB(Vector3(-4.0, -28.0, -4.0), Vector3(8.0, 30.0, 8.0))
	rig.root.add_child(rig.core)

	rig.mantle_mat.shader = PlumeShader
	rig.mantle_mat.set_shader_parameter("is_core", 0.0)
	rig.mantle_mat.set_shader_parameter("time_offset", randf() * 10.0)
	rig.mantle.mesh = _plume_mantle_mesh
	rig.mantle.material_override = rig.mantle_mat
	rig.mantle.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rig.mantle.custom_aabb = AABB(Vector3(-5.0, -28.0, -5.0), Vector3(10.0, 30.0, 10.0))
	rig.root.add_child(rig.mantle)

	rig.throat_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rig.throat_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rig.throat_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	rig.throat_mat.albedo_color = Color(3.2, 2.7, 1.8, 1.0)
	rig.throat_mat.disable_receive_shadows = true
	rig.throat_mat.disable_fog = true
	rig.throat.mesh = _throat_mesh
	rig.throat.material_override = rig.throat_mat
	rig.throat.scale = Vector3(1.15, 0.85, 1.15)
	rig.throat.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rig.root.add_child(rig.throat)

	rocket_root.add_child(rig.root)
	return rig


func update_plume(rig: PlumeRig, throttle: float, climbed: float, flicker: float) -> void:
	if rig == null or not is_instance_valid(rig.root):
		return
	var active := throttle > 0.01
	rig.root.visible = active
	if not active:
		return
	var length := lerpf(6.5, 22.0, clampf(climbed / 18.0, 0.0, 1.0)) * lerpf(0.6, 1.0, throttle)
	var eff := throttle * flicker
	rig.core_mat.set_shader_parameter("throttle", eff)
	rig.core_mat.set_shader_parameter("plume_length", length * 0.9)
	rig.mantle_mat.set_shader_parameter("throttle", eff)
	rig.mantle_mat.set_shader_parameter("plume_length", length)
	var tc := Color(3.0, 2.4, 1.5, clampf(eff * 1.15, 0.0, 1.0))
	rig.throat_mat.albedo_color = tc
	var ts := lerpf(0.75, 1.35, clampf(eff, 0.0, 1.0))
	rig.throat.scale = Vector3(ts, ts * 0.7, ts)


func queue_beacon(pos: Vector3, intensity: float) -> void:
	if intensity <= 0.02 or _beacon_items.size() >= BEACON_CAPACITY:
		return
	_beacon_items.append([pos, Color(2.6 * intensity, 0.14 * intensity, 0.06 * intensity, intensity)])


func emit_smoke(pos: Vector3, vel: Vector3, size0: float, size1: float, life: float,
		color: Color, heat := 0.0, drag := 1.0, rise := 0.6, spin_rate := 0.4) -> void:
	var p := SmokePuff.new()
	p.pos = pos
	p.vel = vel
	p.life = maxf(life, 0.05)
	p.size0 = size0
	p.size1 = size1
	p.color = color
	p.heat = clampf(heat, 0.0, 1.0)
	p.seed = randf()
	p.spin = randf() * TAU
	p.spin_rate = randf_range(-spin_rate, spin_rate)
	p.drag = drag
	p.rise = rise
	if _smoke_puffs.size() >= SMOKE_CAPACITY:
		_smoke_puffs[_smoke_cursor] = p
		_smoke_cursor = (_smoke_cursor + 1) % SMOKE_CAPACITY
	else:
		_smoke_puffs.append(p)


func emit_spark(pos: Vector3, vel: Vector3, life: float, color: Color, width := 0.14, drag := 0.65) -> void:
	var sp := Spark.new()
	sp.pos = pos
	sp.vel = vel
	sp.life = maxf(life, 0.05)
	sp.color = color
	sp.width = width
	sp.drag = drag
	if _sparks.size() >= SPARK_CAPACITY:
		_sparks[_spark_cursor] = sp
		_spark_cursor = (_spark_cursor + 1) % SPARK_CAPACITY
	else:
		_sparks.append(sp)


func step(delta: float) -> void:
	var step_dt := 0.0 if MomentHold.on else delta
	var b := lerpf(1.0, 0.3, night)
	if not is_equal_approx(_smoke_brightness, b):
		_smoke_brightness = b
		_smoke_mat.set_shader_parameter("brightness", b)
	_step_smoke(step_dt)
	_step_sparks(step_dt)
	_flush_beacons()


func _step_smoke(delta: float) -> void:
	var n := _smoke_puffs.size()
	if n == 0:
		if _smoke_shown != 0:
			_smoke_mm.visible_instance_count = 0
			_smoke_shown = 0
		return
	var move := delta > 0.0
	var i := 0
	var o := 0
	while i < n:
		var p: SmokePuff = _smoke_puffs[i]
		p.age += delta
		if p.age >= p.life:
			n -= 1
			if i < n:
				_smoke_puffs[i] = _smoke_puffs[n]
			_smoke_puffs.pop_back()
			continue
		if move:
			if p.rise != 0.0:
				p.vel.y += p.rise * delta
			if p.drag > 0.0:
				p.vel *= maxf(0.0, 1.0 - p.drag * delta)
			p.pos += p.vel * delta
			if p.pos.y < 0.05:
				p.pos.y = 0.05
				p.vel.y = maxf(p.vel.y, 0.25)
			p.spin += p.spin_rate * delta
		var t := p.age / p.life
		var sz := lerpf(p.size0, p.size1, sqrt(t))
		var fade_in := clampf(t / 0.12, 0.0, 1.0)
		var fade_out := clampf((1.0 - t) / 0.55, 0.0, 1.0)
		var alpha := p.color.a * fade_in * fade_out
		var heat_now := p.heat * pow(maxf(1.0 - t * 1.45, 0.0), 1.6)
		_smoke_buf[o] = sz
		_smoke_buf[o + 3] = p.pos.x
		_smoke_buf[o + 5] = sz
		_smoke_buf[o + 7] = p.pos.y
		_smoke_buf[o + 10] = 1.0
		_smoke_buf[o + 11] = p.pos.z
		_smoke_buf[o + 12] = p.color.r
		_smoke_buf[o + 13] = p.color.g
		_smoke_buf[o + 14] = p.color.b
		_smoke_buf[o + 15] = alpha
		_smoke_buf[o + 16] = p.seed
		_smoke_buf[o + 17] = heat_now
		_smoke_buf[o + 18] = p.spin
		_smoke_buf[o + 19] = t
		i += 1
		o += 20
	if n > 0:
		_smoke_mm.buffer = _smoke_buf
		_smoke_mm.visible_instance_count = n
		_smoke_shown = n
	elif _smoke_shown != 0:
		_smoke_mm.visible_instance_count = 0
		_smoke_shown = 0


func _step_sparks(delta: float) -> void:
	var n := _sparks.size()
	if n == 0:
		if _spark_shown != 0:
			_spark_mm.visible_instance_count = 0
			_spark_shown = 0
		return
	var move := delta > 0.0
	var i := 0
	var o := 0
	while i < n:
		var sp: Spark = _sparks[i]
		sp.age += delta
		if sp.age >= sp.life:
			n -= 1
			if i < n:
				_sparks[i] = _sparks[n]
			_sparks.pop_back()
			continue
		if move:
			sp.vel.y -= 18.0 * delta
			if sp.drag > 0.0:
				sp.vel *= maxf(0.0, 1.0 - sp.drag * delta)
			sp.pos += sp.vel * delta
			if sp.pos.y < 0.12 and sp.vel.y < 0.0:
				sp.pos.y = 0.12
				sp.vel.y = -sp.vel.y * 0.35
				sp.vel.x *= 0.72
				sp.vel.z *= 0.72
		var t := sp.age / sp.life
		var fade := 1.0 - t * t
		_spark_buf[o] = 1.0
		_spark_buf[o + 3] = sp.pos.x
		_spark_buf[o + 5] = 1.0
		_spark_buf[o + 7] = sp.pos.y
		_spark_buf[o + 10] = 1.0
		_spark_buf[o + 11] = sp.pos.z
		_spark_buf[o + 12] = sp.color.r
		_spark_buf[o + 13] = sp.color.g
		_spark_buf[o + 14] = sp.color.b
		_spark_buf[o + 15] = sp.color.a * fade
		_spark_buf[o + 16] = sp.vel.x
		_spark_buf[o + 17] = sp.vel.y
		_spark_buf[o + 18] = sp.vel.z
		_spark_buf[o + 19] = sp.width * lerpf(1.0, 0.4, t)
		i += 1
		o += 20
	if n > 0:
		_spark_mm.buffer = _spark_buf
		_spark_mm.visible_instance_count = n
		_spark_shown = n
	elif _spark_shown != 0:
		_spark_mm.visible_instance_count = 0
		_spark_shown = 0


func _flush_beacons() -> void:
	var n := mini(_beacon_items.size(), BEACON_CAPACITY)
	if n == 0:
		_beacon_mm.visible_instance_count = 0
		return
	for i in n:
		var item: Array = _beacon_items[i]
		var pos: Vector3 = item[0]
		var col: Color = item[1]
		var o := i * 16
		var s := 0.75 + 0.55 * col.a
		_beacon_buf[o] = s
		_beacon_buf[o + 3] = pos.x
		_beacon_buf[o + 5] = s
		_beacon_buf[o + 7] = pos.y + GroundHeight.at(pos.x, pos.z)
		_beacon_buf[o + 10] = s
		_beacon_buf[o + 11] = pos.z
		_beacon_buf[o + 12] = col.r
		_beacon_buf[o + 13] = col.g
		_beacon_buf[o + 14] = col.b
		_beacon_buf[o + 15] = col.a
	_beacon_items.clear()
	_beacon_mm.buffer = _beacon_buf
	_beacon_mm.visible_instance_count = n


func _setup_smoke_pool() -> void:
	_smoke_mat.shader = SmokeShader
	_smoke_mm.transform_format = MultiMesh.TRANSFORM_3D
	_smoke_mm.use_colors = true
	_smoke_mm.use_custom_data = true
	_smoke_mm.mesh = _quad_mesh
	_smoke_mm.instance_count = SMOKE_CAPACITY
	_smoke_mm.visible_instance_count = 0
	_smoke_buf.resize(SMOKE_CAPACITY * 20)
	_smoke_buf.fill(0.0)
	_smoke_mmi.multimesh = _smoke_mm
	_smoke_mmi.material_override = _smoke_mat
	_smoke_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_smoke_mmi.custom_aabb = AABB(Vector3(-1e6, -1e3, -1e6), Vector3(2e6, 2e3, 2e6))
	_smoke_mmi.name = "RocketSmokePool"
	add_child(_smoke_mmi)


func _setup_spark_pool() -> void:
	_spark_mat.shader = SparkShader
	_spark_mm.transform_format = MultiMesh.TRANSFORM_3D
	_spark_mm.use_colors = true
	_spark_mm.use_custom_data = true
	_spark_mm.mesh = _quad_mesh
	_spark_mm.instance_count = SPARK_CAPACITY
	_spark_mm.visible_instance_count = 0
	_spark_buf.resize(SPARK_CAPACITY * 20)
	_spark_buf.fill(0.0)
	_spark_mmi.multimesh = _spark_mm
	_spark_mmi.material_override = _spark_mat
	_spark_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_spark_mmi.custom_aabb = AABB(Vector3(-1e6, -1e3, -1e6), Vector3(2e6, 2e3, 2e6))
	_spark_mmi.name = "RocketSparkPool"
	add_child(_spark_mmi)


func _setup_beacon_pool() -> void:
	_beacon_mm.transform_format = MultiMesh.TRANSFORM_3D
	_beacon_mm.use_colors = true
	_beacon_mm.mesh = _beacon_mesh
	_beacon_mm.instance_count = BEACON_CAPACITY
	_beacon_mm.visible_instance_count = 0
	_beacon_buf.resize(BEACON_CAPACITY * 16)
	_beacon_buf.fill(0.0)
	_beacon_mmi.multimesh = _beacon_mm
	_beacon_mmi.material_override = _beacon_mat
	_beacon_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_beacon_mmi.custom_aabb = AABB(Vector3(-1e6, -1e3, -1e6), Vector3(2e6, 2e3, 2e6))
	_beacon_mmi.name = "SiloBeacons"
	add_child(_beacon_mmi)


static func _init_shared_meshes() -> void:
	if _shaft_mesh != null:
		return
	_quad_mesh = QuadMesh.new()
	_quad_mesh.size = Vector2.ONE
	_shaft_mesh = _build_shaft_mesh()
	_elevator_mesh = _build_elevator_mesh()
	_elevator_mat = StandardMaterial3D.new()
	_elevator_mat.albedo_color = Color(0.22, 0.24, 0.27)
	_elevator_mat.metallic = 0.65
	_elevator_mat.roughness = 0.48
	_clamp_arm_mesh = _build_clamp_arm_mesh()
	_clamp_mat = StandardMaterial3D.new()
	_clamp_mat.albedo_color = Color(0.32, 0.30, 0.26)
	_clamp_mat.metallic = 0.58
	_clamp_mat.roughness = 0.45
	_plume_core_mesh = _build_plume_mesh(0.95, 0.32)
	_plume_mantle_mesh = _build_plume_mesh(1.42, 2.55)
	_throat_mesh = SphereMesh.new()
	_throat_mesh.radius = 1.0
	_throat_mesh.height = 1.6
	_throat_mesh.radial_segments = 16
	_throat_mesh.rings = 8
	_ring_mesh = _build_ring_mesh()
	_beacon_mesh = SphereMesh.new()
	_beacon_mesh.radius = 0.24
	_beacon_mesh.height = 0.48
	_beacon_mesh.radial_segments = 10
	_beacon_mesh.rings = 5
	_beacon_mat = StandardMaterial3D.new()
	_beacon_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_beacon_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_beacon_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_beacon_mat.vertex_color_use_as_albedo = true
	_beacon_mat.disable_receive_shadows = true
	_beacon_mat.disable_fog = true


static func _add_quad(st: SurfaceTool, p00: Vector3, p10: Vector3, p11: Vector3, p01: Vector3,
		n0: Vector3, n1: Vector3, desired: Vector3) -> void:
	if (p11 - p00).cross(p10 - p00).dot(desired) >= 0.0:
		st.set_normal(n0); st.add_vertex(p00)
		st.set_normal(n1); st.add_vertex(p10)
		st.set_normal(n1); st.add_vertex(p11)
		st.set_normal(n0); st.add_vertex(p00)
		st.set_normal(n1); st.add_vertex(p11)
		st.set_normal(n0); st.add_vertex(p01)
	else:
		st.set_normal(n0); st.add_vertex(p00)
		st.set_normal(n1); st.add_vertex(p11)
		st.set_normal(n1); st.add_vertex(p10)
		st.set_normal(n0); st.add_vertex(p00)
		st.set_normal(n0); st.add_vertex(p01)
		st.set_normal(n1); st.add_vertex(p11)


static func _add_ring_band(st: SurfaceTool, segs: int, r0: float, y0: float, r1: float, y1: float,
		desired_radial_sign: float, desired_y_normal := Vector3.UP) -> void:
	var flat := absf(y1 - y0) < 0.001
	for k in segs:
		var a0 := float(k) / float(segs) * TAU
		var a1 := float(k + 1) / float(segs) * TAU
		var c0 := cos(a0)
		var s0 := sin(a0)
		var c1 := cos(a1)
		var s1 := sin(a1)
		var p00 := Vector3(r0 * c0, y0, r0 * s0)
		var p10 := Vector3(r0 * c1, y0, r0 * s1)
		var p11 := Vector3(r1 * c1, y1, r1 * s1)
		var p01 := Vector3(r1 * c0, y1, r1 * s0)
		var n0 := desired_y_normal if flat else Vector3(c0, 0.0, s0) * desired_radial_sign
		var n1 := desired_y_normal if flat else Vector3(c1, 0.0, s1) * desired_radial_sign
		var desired := desired_y_normal if flat else ((n0 + n1) * 0.5)
		_add_quad(st, p00, p10, p11, p01, n0, n1, desired)


static func _build_shaft_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segs := 36
	# Main cylindrical shaft wall (r=1.0 normalized) from rim (y=0.0) down to blast floor (-26).
	var ys: Array[float] = [0.0, -1.8, -5.0, -8.5, -12.0, -15.5, -19.0, -22.5, -SHAFT_DEPTH]
	for i in ys.size() - 1:
		_add_ring_band(st, segs, 1.0, ys[i], 1.0, ys[i + 1], -1.0)
	# Top armored rim collar sealing into the silo ring & terrain cutout edge (below closed doors).
	_add_ring_band(st, segs, 1.0, -0.02, 1.18, -0.02, -1.0, Vector3.UP)
	_add_ring_band(st, segs, 1.0, 0.0, 1.0, -0.35, -1.0)
	# 7 recessed steel gantry rings around the interior wall for 3D depth parallax.
	for ry: float in [-1.8, -5.0, -8.5, -12.0, -15.5, -19.0, -22.5]:
		_add_ring_band(st, segs, 1.0, ry + 0.14, 0.935, ry + 0.14, -1.0, Vector3.UP)
		_add_ring_band(st, segs, 0.935, ry + 0.14, 0.935, ry - 0.14, -1.0)
		_add_ring_band(st, segs, 0.935, ry - 0.14, 1.0, ry - 0.14, -1.0, Vector3.DOWN)
	# 6 vertical guide / umbilical rails down the shaft wall.
	for k in 6:
		var ang := float(k) * TAU / 6.0 + 0.25
		var half_w := 0.045
		var a0 := ang - half_w
		var a1 := ang + half_w
		var c0 := cos(a0)
		var s0 := sin(a0)
		var c1 := cos(a1)
		var s1 := sin(a1)
		var r_in := 0.955
		var r_out := 1.0
		var y_top := -0.3
		var y_bot := -SHAFT_DEPTH + 0.4
		var p_tl := Vector3(r_in * c0, y_top, r_in * s0)
		var p_tr := Vector3(r_in * c1, y_top, r_in * s1)
		var p_br := Vector3(r_in * c1, y_bot, r_in * s1)
		var p_bl := Vector3(r_in * c0, y_bot, r_in * s0)
		var n_in := Vector3(-cos(ang), 0.0, -sin(ang))
		_add_quad(st, p_tl, p_tr, p_br, p_bl, n_in, n_in, n_in)
		var p_otl := Vector3(r_out * c0, y_top, r_out * s0)
		var p_obl := Vector3(r_out * c0, y_bot, r_out * s0)
		var nl := Vector3(-s0, 0.0, c0)
		_add_quad(st, p_otl, p_tl, p_bl, p_obl, nl, nl, nl)
		var p_otr := Vector3(r_out * c1, y_top, r_out * s1)
		var p_obr := Vector3(r_out * c1, y_bot, r_out * s1)
		var nr := Vector3(s1, 0.0, -c1)
		_add_quad(st, p_tr, p_otr, p_obr, p_br, nr, nr, nr)
	# Blast deflector pit floor with central exhaust cone (upward-facing).
	var center := Vector3(0.0, -SHAFT_DEPTH + 0.7, 0.0)
	for k in segs:
		var a0 := float(k) / float(segs) * TAU
		var a1 := float(k + 1) / float(segs) * TAU
		var p0 := Vector3(1.02 * cos(a0), -SHAFT_DEPTH, 1.02 * sin(a0))
		var p1 := Vector3(1.02 * cos(a1), -SHAFT_DEPTH, 1.02 * sin(a1))
		var fn := (p1 - center).cross(p0 - center).normalized()
		if fn.dot(Vector3.UP) >= 0.0:
			st.set_normal(fn); st.add_vertex(center)
			st.set_normal(fn); st.add_vertex(p0)
			st.set_normal(fn); st.add_vertex(p1)
		else:
			fn = -fn
			st.set_normal(fn); st.add_vertex(center)
			st.set_normal(fn); st.add_vertex(p1)
			st.set_normal(fn); st.add_vertex(p0)
	return st.commit()


static func _add_box_seg(st: SurfaceTool, lo: Vector3, hi: Vector3) -> void:
	# +Y top, -Y bottom, +X, -X, +Z, -Z faces with strictly outward winding.
	_add_quad(st, Vector3(lo.x, hi.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, hi.y, lo.z), Vector3(lo.x, hi.y, lo.z), Vector3.UP, Vector3.UP, Vector3.UP)
	_add_quad(st, Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z), Vector3.DOWN, Vector3.DOWN, Vector3.DOWN)
	_add_quad(st, Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3.RIGHT, Vector3.RIGHT, Vector3.RIGHT)
	_add_quad(st, Vector3(lo.x, hi.y, lo.z), Vector3(lo.x, hi.y, hi.z), Vector3(lo.x, lo.y, hi.z), Vector3(lo.x, lo.y, lo.z), Vector3.LEFT, Vector3.LEFT, Vector3.LEFT)
	_add_quad(st, Vector3(lo.x, hi.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z), Vector3.BACK, Vector3.BACK, Vector3.BACK)
	_add_quad(st, Vector3(hi.x, hi.y, lo.z), Vector3(lo.x, hi.y, lo.z), Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3.FORWARD, Vector3.FORWARD, Vector3.FORWARD)


static func _add_annulus_ring(st: SurfaceTool, segs: int, r_in: float, r_out: float, y0: float, y1: float) -> void:
	_add_ring_band(st, segs, r_in, y1, r_out, y1, 1.0, Vector3.UP)
	_add_ring_band(st, segs, r_in, y0, r_out, y0, 1.0, Vector3.DOWN)
	_add_ring_band(st, segs, r_out, y1, r_out, y0, 1.0)
	_add_ring_band(st, segs, r_in, y1, r_in, y0, -1.0)


static func _build_elevator_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segs := 24
	# Open-center annular steel launch cradle (clears 4.2-tile rocket body cleanly).
	_add_annulus_ring(st, segs, 0.86, 0.95, 0.0, 0.45)
	_add_annulus_ring(st, segs, 0.86, 0.95, 13.4, 13.85)
	# 3 structural guide columns connecting lower base ring to upper collar along shaft rails.
	for k in 3:
		var ang := float(k) * TAU / 3.0 + 0.25
		var c := cos(ang)
		var s := sin(ang)
		var w := 0.055
		_add_box_seg(st, Vector3(c * 0.91 - w, 0.45, s * 0.91 - w), Vector3(c * 0.91 + w, 13.4, s * 0.91 + w))
	return st.commit()


static func _build_clamp_arm_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Hinged at local (0,0,0), extending inward along -Z (stays below y=-0.10 when pitched down -1.48 rad).
	_add_box_seg(st, Vector3(-0.14, -0.09, -0.82), Vector3(0.14, 0.09, 0.02))
	_add_box_seg(st, Vector3(-0.18, -0.10, -1.06), Vector3(0.18, 0.10, -0.78))
	return st.commit()


static func _build_plume_mesh(top_r: float, bottom_r: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segs := 24
	var rings := 12
	for j in rings:
		var v0 := float(j) / float(rings)
		var v1 := float(j + 1) / float(rings)
		var r0 := lerpf(top_r, bottom_r, v0)
		var r1 := lerpf(top_r, bottom_r, v1)
		var y0 := -v0
		var y1 := -v1
		for k in segs:
			var u0 := float(k) / float(segs)
			var u1 := float(k + 1) / float(segs)
			var a0 := u0 * TAU
			var a1 := u1 * TAU
			var c0 := cos(a0)
			var s0 := sin(a0)
			var c1 := cos(a1)
			var s1 := sin(a1)
			var n0 := Vector3(c0, 0.0, s0)
			var n1 := Vector3(c1, 0.0, s1)
			st.set_uv(Vector2(u0, v0)); st.set_normal(n0); st.add_vertex(Vector3(r0 * c0, y0, r0 * s0))
			st.set_uv(Vector2(u1, v0)); st.set_normal(n1); st.add_vertex(Vector3(r0 * c1, y0, r0 * s1))
			st.set_uv(Vector2(u1, v1)); st.set_normal(n1); st.add_vertex(Vector3(r1 * c1, y1, r1 * s1))
			st.set_uv(Vector2(u0, v0)); st.set_normal(n0); st.add_vertex(Vector3(r0 * c0, y0, r0 * s0))
			st.set_uv(Vector2(u1, v1)); st.set_normal(n1); st.add_vertex(Vector3(r1 * c1, y1, r1 * s1))
			st.set_uv(Vector2(u0, v1)); st.set_normal(n0); st.add_vertex(Vector3(r1 * c0, y1, r1 * s1))
	return st.commit()


static func _build_ring_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segs := 36
	var rings := 4
	for j in rings:
		var r0 := lerpf(0.18, 1.0, float(j) / float(rings))
		var r1 := lerpf(0.18, 1.0, float(j + 1) / float(rings))
		for k in segs:
			var a0 := float(k) / float(segs) * TAU
			var a1 := float(k + 1) / float(segs) * TAU
			var p00 := Vector3(r0 * cos(a0), 0.0, r0 * sin(a0))
			var p10 := Vector3(r0 * cos(a1), 0.0, r0 * sin(a1))
			var p11 := Vector3(r1 * cos(a1), 0.0, r1 * sin(a1))
			var p01 := Vector3(r1 * cos(a0), 0.0, r1 * sin(a0))
			st.set_normal(Vector3.UP); st.add_vertex(p00)
			st.set_normal(Vector3.UP); st.add_vertex(p10)
			st.set_normal(Vector3.UP); st.add_vertex(p11)
			st.set_normal(Vector3.UP); st.add_vertex(p00)
			st.set_normal(Vector3.UP); st.add_vertex(p11)
			st.set_normal(Vector3.UP); st.add_vertex(p01)
	return st.commit()
