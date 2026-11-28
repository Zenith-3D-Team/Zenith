extends Node
## Vehicles' and robots' own animations, as Factorio draws them, on the movers' nodes (movers.gd
## makes a MeshInstance3D per moving part, `anim_<kind>` in the model, at rest in model space;
## this sets their transforms and glow every frame). Wheels, tracks' road wheels and turrets are
## moved by movers.gd and turrets.gd; this does the rest:
##
## - spidertron: each leg is an upper and a lower part stretched between hip, knee and foot as
##   Factorio stretches its leg sprites (knee 40% of the way out, as high over the higher of
##   hip and foot as the model has it over its hip). The feet stand where the mod says its
##   spider-leg entities stand (`legs`); a foot that moves steps there in an arc. Without the
##   mod's feet (an older mod, the mock) the legs step by themselves: Factorio's two walking
##   groups in turn, each foot back to its ground_position when it strays. The shell turns
##   with the torso's aim (turrets.gd) and the body bobs, more while it walks. Gleba's strafers
##   and stompers (pentapods) walk the same way on their five legs, each with its own
##   prototype's leg table, knee and step size;
## - logistic robots swing their legs (the thrusters) back and light their tips while they fly,
##   and show the antenna's red ball while they carry cargo (`rc`), white without; construction
##   robots hovering in one place are working: their nozzle light flickers on Factorio's two
##   working frames, the arms reach forward and Factorio's sparks fly; all robots bob a little.
##   Only for robots on nodes (--robot-nodes): otherwise robot_swarm.gd and the robot shader draw
##   them all that way;
## - capture robots sway their hanging cables on the capture animation's 128-tick loop, the tips
##   pulsing;
## - cargo pods open high in the sky (antenna up, then three panels out, pod-opening.png) and
##   close before they come down; their thruster burns while rockets.gd moves them up or down;
## - the tank's treads slide forward by the distance driven.
## Every mover's glowing materials are lit here (f3d_glow), since a single MeshInstance3D has no
## INSTANCE_CUSTOM to carry the buildings' working glow.

const ModelLibrary := preload("res://scripts/world/model_library.gd")
const Switches := preload("res://scripts/switches.gd")

## `--vehicle-anim=old`: keep static linear track slide and disable chassis suspension/rumble/fan/recoil rock.
static var enhanced := not (Switches.has("--vehicle-anim=old"))

## Factorio's tank closed-loop caterpillar contour in Blender (y_north, z_up, radius) coordinates,
## shared verbatim with tools/models/military.py.
const TANK_CIRCLES := [
	Vector3(-1.06, 0.34, 0.28),
	Vector3(0.82, 0.22, 0.16),
	Vector3(1.24, 0.39, 0.23),
]
const TANK_CLEATS := 32
const TANK_CLEAT_START_Y := 0.85
const TANK_CLEAT_TOP_Z := 0.62

static var _track_segs: Array = []
static var _track_perim := 0.0
static var _cleat_cache := {}  # Mesh -> ArrayMesh (extracted top Cleat #0)

## Factorio's spidertron legs (spider_engine.legs, base/prototypes/entity/spidertron.lua, from
## `factorio --dump-data`), in the order the mod sends their feet: mount position, ground
## position (x east, y south, tiles) and walking group.
const SPIDER_LEGS := [
	[Vector2(0.46875, -0.6875), Vector2(2.25, -2.5), 1], [Vector2(0.71875, -0.3125), Vector2(3.0, -1.0), 2],
	[Vector2(0.78125, 0.125), Vector2(3.0, 1.0), 1], [Vector2(0.46875, 0.53125), Vector2(2.25, 2.5), 2],
	[Vector2(-0.46875, -0.6875), Vector2(-2.25, -2.5), 2], [Vector2(-0.71875, -0.3125), Vector2(-3.0, -1.0), 1],
	[Vector2(-0.78125, 0.125), Vector2(-3.0, 1.0), 2], [Vector2(-0.46875, 0.53125), Vector2(-2.25, 2.5), 1],
]
const KNEE_AT := 0.4  # spider-leg knee_distance_factor
## Pentapods' spider_engine.legs, big tiers (`factorio --dump-data`; gleba.py builds the same):
## mount and ground position (x east, y south) and walking group, in the order the mod sends
## their feet. The small and medium tiers are these scaled (PENTAPOD_TIERS).
const STOMPER_LEGS := [
	[Vector2(-1.0345, -1.4239), Vector2(-6.5832, -9.061), 1], [Vector2(-1.6739, 0.5439), Vector2(-10.6518, 3.461), 3],
	[Vector2(0.0, 1.76), Vector2(0.0, 11.2), 5], [Vector2(1.6739, 0.5439), Vector2(10.6518, 3.461), 2],
	[Vector2(1.0345, -1.4239), Vector2(6.5832, -9.061), 4],
]
const STRAFER_LEGS := [
	[Vector2(-0.3236, -0.2351), Vector2(-6.4721, -4.7023), 1], [Vector2(-0.3236, 0.2351), Vector2(-6.4721, 4.7023), 3],
	[Vector2(0.1236, 0.3804), Vector2(2.4721, 7.6085), 5], [Vector2(0.4, 0.0), Vector2(8.0, 0.0), 2],
	[Vector2(0.1236, -0.3804), Vector2(2.4721, -7.6085), 4],
]
const PENTAPOD_TIERS := {"small": 0.5625, "medium": 0.75, "big": 1.0}
## kind -> [legs, the legs' knee_distance_factor, their minimal_step_size (big tier)]
const LEG_TABLES := {"spidertron": [SPIDER_LEGS, KNEE_AT, 1.0], "stomper": [STOMPER_LEGS, 0.55, 1.76],
	"strafer": [STRAFER_LEGS, 0.5, 1.6]}
## Steps: how high a foot lifts, its speed (Factorio's legs accelerate from 0.06 to well over
## a tile a tick; a step of a tile or two takes about a fifth of a second), and when a foot
## steps by itself: more than minimal_step_size from where it should stand while walking, or
## a quarter of that standing still.
const STEP_LIFT := 0.7  # at the spidertron's size; bigger legs lift higher and step faster
const STEP_SPEED := 9.0
const STEP_MIN_TIME := 0.12
const STEP_TRIGGER := 1.0
const STEP_TIDY := 0.25
const STEP_LEAD := 0.35  # seconds of the body's motion a foot steps ahead
const FEET_STALE := 0.5  # seconds without the mod's feet before the legs step by themselves
## The torso's bob: tiles up and down, standing and walking, and how fast standing.
const BOB_IDLE := 0.04
const BOB_WALK := 0.1
const BOB_RATE := 0.5
## Robots.
const ROBOT_BOB := 0.035
const ROBOT_BOB_RATE := 0.7
const THRUSTER_SWING := -0.5  # radians the legs swing back at full speed
const ROBOT_FULL_SPEED := 2.5  # tiles a second counted as flying flat out
const WORK_STILL := 0.3  # seconds a construction robot hovers in place before it works
const WORK_FRAME := 1.0 / (0.3 * 60.0)  # working animation: 2 frames at 0.3 a tick
const ARMS_REACH := 0.6
const SPARK_EVERY := 0.25
## Capture robots: capture_animation, 32 frames at 0.25 a tick.
const CAPTURE_LOOP := 32.0 / 0.25 / 60.0
const CABLE_SWAY := 0.07
## Cargo pods: open above this height, in this long (pod-opening, 34 frames), flame when moving
## up or down faster than this (tiles a second).
const POD_OPEN_HEIGHT := 18.0
const POD_OPEN_TIME := 34.0 / 30.0
const POD_ANTENNA_RISE := 0.3
const POD_THRUST_SPEED := 0.5
## The tank's treads: their spacing along the track (military.py track(), stretched with the hull).
const TREAD_SPACING := {"tank": (1.38 + 1.42 - 0.08) / 25.0 * 1.071}

const RIG_KINDS := {"spidertron": "spider", "logistic-robot": "logistic", "construction-robot": "construction",
	"capture-robot": "capture", "cargo-pod": "pod", "car": "car", "tank": "tracks"}


class Leg:
	var upper: MeshInstance3D
	var lower: MeshInstance3D
	var hip0 := Vector3.ZERO  # at rest, in the node's space
	var knee0 := Vector3.ZERO
	var foot0 := Vector3.ZERO
	var rest := Vector3.ZERO  # where the foot stands (node space) when the spider is still
	var group := 1
	var knee_rise := 1.25  # the model's knee over its hip at rest
	var foot := Vector3.ZERO  # drawn, world space (y is the lift)
	var from := Vector3.ZERO  # a step's start and end, world space on the ground
	var to := Vector3.ZERO
	var step := -1.0  # progress 0 to 1, or -1 when planted


class Rig:
	var kind := ""
	var unit := 0
	var node: Node3D
	var body: MeshInstance3D
	var parts := {}  # part kind -> [[MeshInstance3D, AnimPart], ...]
	var meshes: Array[MeshInstance3D] = []
	var last := Vector3.ZERO
	var velocity := Vector3.ZERO  # smoothed, tiles a second
	var phase := 0.0
	var still := 0.0  # seconds hovering in place
	var amount := 0.0  # robots: flying (0-1); pods: open (0-1)
	var travelled := 0.0
	var spark := 0.0
	var legs: Array[Leg] = []
	var stepping_group := 0
	var placed := false
	var knee_at := KNEE_AT
	var step_size := STEP_TRIGGER  # minimal_step_size
	var size := 1.0  # the legs' reach against the spidertron's
	var last_yaw := 0.0
	var prev_speed := 0.0
	var pitch := 0.0
	var pitch_vel := 0.0
	var roll := 0.0
	var roll_vel := 0.0
	var chassis_xf := Transform3D.IDENTITY
	var fan_angle := 0.0
	var left_travel := 0.0
	var right_travel := 0.0
	var track_l_mm: MultiMeshInstance3D
	var track_r_mm: MultiMeshInstance3D
	var track_l_x := -0.66
	var track_r_x := 0.66


## ui_model.gd (legs, robot_cargo), turrets.gd (the spidertron's torso), sprite_fx.gd (sparks):
## main.gd sets them.
var model
var turrets: Node
var sprites: Node

var _rigs := {}  # unit -> Rig
var _time := 0.0
var _feet_at := {}  # unit -> time the mod's feet for it last came
var _legs_heard := -1  # ui_model.gd's legs_heard when they were last looked at
## The last frame's _process time, microseconds (--robot-probe).
var process_usec := 0


func _ready() -> void:
	# After rockets.gd has lifted the cargo pods this frame, so their climb shows here.
	process_priority = 10


## A new mover's node (movers.gd): lights its glowing materials, and rigs it if it animates.
func attach(unit: int, node: Node3D, proto_name: String) -> void:
	var rig := Rig.new()
	rig.unit = unit
	rig.node = node
	rig.kind = RIG_KINDS.get(proto_name, "")
	rig.last = node.position
	rig.last_yaw = node.rotation.y
	rig.phase = float(posmod(unit * 7919, 1000)) / 1000.0 * TAU
	for child in node.get_children():
		var mi := child as MeshInstance3D
		if mi == null:
			continue
		rig.meshes.append(mi)
		if child.has_meta("part"):
			var part: ModelLibrary.AnimPart = child.get_meta("part")
			mi.set_instance_shader_parameter("f3d_glow", 0.0 if part.kind == "headlight" else 1.0)
			var list: Array = rig.parts.get(part.kind, [])
			list.append([mi, part])
			rig.parts[part.kind] = list
		else:
			mi.set_instance_shader_parameter("f3d_glow", 1.0)
			rig.body = mi
	if proto_name == "rocket-silo-rocket":
		# Its engines glow only once they start (rockets.gd lights the launching one).
		for mi in rig.meshes:
			mi.set_instance_shader_parameter("f3d_glow", 0.0)
	if rig.kind == "" and proto_name.ends_with("-pentapod") and not proto_name.contains("wriggler"):
		rig.kind = "spider"  # strafers and stompers
	if rig.kind == "":
		return
	if rig.kind == "spider":
		_rig_legs(rig, proto_name)
	elif rig.kind == "tracks" and enhanced:
		_attach_tank_tracks(rig)
	_rigs[unit] = rig


func detach(unit: int) -> void:
	_rigs.erase(unit)
	_feet_at.erase(unit)


func reset() -> void:
	_rigs.clear()
	_feet_at.clear()


func count() -> int:
	return _rigs.size()


## Current smoothed world velocity of `unit`, or Vector3.ZERO if not rigged.
func velocity_of(unit: int) -> Vector3:
	var rig: Rig = _rigs.get(unit)
	return rig.velocity if rig != null else Vector3.ZERO


## Current world transforms of all animated child parts (`MeshInstance3D` with `"part"` meta)
## on `unit`, in `ModelLibrary.parts_for` order.
func part_transforms(unit: int) -> Array:
	var rig: Rig = _rigs.get(unit)
	if rig == null or not is_instance_valid(rig.node):
		return []
	var in_tree := rig.node.is_inside_tree()
	var out: Array = []
	for child in rig.node.get_children():
		if child is MeshInstance3D and child.has_meta("part"):
			var part: ModelLibrary.AnimPart = child.get_meta("part") as ModelLibrary.AnimPart
			var xf: Transform3D = (child as Node3D).global_transform if in_tree else (rig.node.transform * (child as Node3D).transform)
			out.append({"kind": part.kind if part != null else "", "xform": xf})
	return out


## Planet data came; only a `legs` makes the feet fresh (`seg`, `pg` and the rest come with the same
## signal, and would keep a spider that left the mod's list on its last feet).
func _on_planet_data() -> void:
	if model == null or model.legs_heard == _legs_heard:
		return
	_legs_heard = model.legs_heard
	for unit in model.legs:
		_feet_at[int(unit)] = _time


func _process(delta: float) -> void:
	var started := Time.get_ticks_usec()
	_animate(delta)
	process_usec = Time.get_ticks_usec() - started


func _animate(delta: float) -> void:
	_time += delta
	if model != null and not model.planet_data_changed.is_connected(_on_planet_data):
		model.planet_data_changed.connect(_on_planet_data)
	if delta <= 0.0:
		return
	for rig: Rig in _rigs.values():
		if not is_instance_valid(rig.node):
			continue
		var moved := rig.node.position - rig.last
		var turned := wrapf(rig.node.rotation.y - rig.last_yaw, -PI, PI)
		rig.last = rig.node.position
		rig.last_yaw = rig.node.rotation.y
		if moved.length() > 4.0:
			moved = Vector3.ZERO  # a teleport
			turned = 0.0
		rig.velocity = rig.velocity.lerp(moved / delta, 1.0 - exp(-delta * 8.0))
		match rig.kind:
			"spider":
				_spider(rig, delta)
			"logistic", "construction":
				_robot(rig, delta)
			"capture":
				_capture(rig, delta)
			"pod":
				_pod(rig, delta)
			"car":
				_car(rig, moved, turned, delta)
			"tracks":
				_tracks(rig, moved, turned, delta)


## Current sprung hull offset transform for a rigged vehicle (`car` / `tank`), or IDENTITY.
func chassis_xform(unit: int) -> Transform3D:
	if not enhanced:
		return Transform3D.IDENTITY
	var rig: Rig = _rigs.get(unit)
	return rig.chassis_xf if rig != null else Transform3D.IDENTITY


## Adds a suspension impulse in `world_dir` (e.g. -muzzle_forward for tank cannon recoil).
func impulse(unit: int, world_dir: Vector3, strength: float) -> void:
	if not enhanced or strength == 0.0:
		return
	var rig: Rig = _rigs.get(unit)
	if rig == null or not is_instance_valid(rig.node) or world_dir.length_squared() < 1e-6:
		return
	var local_dir := (rig.node.global_transform.basis.inverse() * world_dir).normalized()
	rig.pitch_vel += local_dir.z * strength
	rig.roll_vel += -local_dir.x * strength


# --- spidertron --------------------------------------------------------------------------------

## Pairs each upper leg with its lower one and with Factorio's leg of the same mount (the
## spidertron's, or a pentapod's at its tier's scale).
func _rig_legs(rig: Rig, proto_name: String) -> void:
	var table: Array = LEG_TABLES["spidertron"]
	var scale := 1.0
	for kind in ["stomper", "strafer"]:
		if proto_name.contains(kind):
			table = LEG_TABLES[kind]
			scale = float(PENTAPOD_TIERS.get(proto_name.get_slice("-", 0), 1.0))
	var legs: Array = table[0]
	rig.knee_at = float(table[1])
	rig.step_size = float(table[2]) * scale
	var reach := 0.0
	for l in legs:
		reach += (l[1] as Vector2).length() * scale / legs.size()
	rig.size = reach / 2.9  # the spidertron's feet stand about 2.9 tiles out
	var uppers: Array = rig.parts.get("leg_upper", [])
	var lowers: Array = rig.parts.get("leg_lower", [])
	var used := {}
	for pair in uppers:
		var leg := Leg.new()
		leg.upper = pair[0]
		var part: ModelLibrary.AnimPart = pair[1]
		leg.hip0 = part.pivot.origin
		var dir := Vector2(leg.hip0.x, leg.hip0.z).angle()
		var best := -1
		for i in lowers.size():
			var k: Vector3 = (lowers[i][1] as ModelLibrary.AnimPart).pivot.origin
			if not used.has(i) and (best < 0 or _off(Vector2(k.x, k.z).angle(), dir) < _off(_flat_angle(lowers[best][1]), dir)):
				best = i
		if best < 0:
			continue
		used[best] = true
		leg.lower = lowers[best][0]
		leg.knee0 = (lowers[best][1] as ModelLibrary.AnimPart).pivot.origin
		leg.knee_rise = leg.knee0.y - leg.hip0.y
		var index := 0
		for i in legs.size():
			if _off((legs[i][0] as Vector2).angle(), dir) < _off((legs[index][0] as Vector2).angle(), dir):
				index = i
		var g: Vector2 = (legs[index][1] as Vector2) * scale
		leg.foot0 = Vector3(g.x, 0.0, g.y)
		leg.rest = leg.foot0
		leg.group = int(legs[index][2])
		rig.legs.resize(maxi(rig.legs.size(), index + 1))
		rig.legs[index] = leg
	# Legs the model doesn't have (another spider's) are dropped.
	var kept: Array[Leg] = []
	for leg in rig.legs:
		if leg != null:
			kept.append(leg)
	if kept.size() != rig.legs.size():
		rig.legs = kept


static func _off(a: float, b: float) -> float:
	return absf(angle_difference(a, b))


static func _flat_angle(part: ModelLibrary.AnimPart) -> float:
	return Vector2(part.pivot.origin.x, part.pivot.origin.z).angle()


func _spider(rig: Rig, delta: float) -> void:
	if rig.legs.is_empty():
		return
	var speed := Vector2(rig.velocity.x, rig.velocity.z).length()
	var walking := clampf(speed / 2.0, 0.0, 1.0)
	rig.travelled += speed * delta
	# Bob: slow breathing standing still, a bounce per step walking.
	rig.phase += delta * TAU * BOB_RATE
	var bob := lerpf(BOB_IDLE * sin(rig.phase), BOB_WALK * absf(sin(rig.travelled * PI / 1.6)) - BOB_WALK * 0.5, walking)
	bob *= sqrt(rig.size)
	if rig.body != null:
		rig.body.position.y = bob
	for pair in rig.parts.get("torso", []):
		var mi: MeshInstance3D = pair[0]
		var part: ModelLibrary.AnimPart = pair[1]
		var yaw := 0.0
		var st = turrets.call("state_of", rig.unit) if turrets != null else null
		if st != null:
			yaw = wrapf(-float(st.yaw) * TAU - rig.node.rotation.y, -PI, PI)
		mi.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, bob, 0.0)) * part.turned(yaw)
	var xf := rig.node.global_transform
	var mod_feet = model.legs.get(rig.unit) if model != null else null
	var fresh := mod_feet != null and _time - float(_feet_at.get(rig.unit, -INF)) < FEET_STALE \
		and (mod_feet as PackedVector2Array).size() >= rig.legs.size()
	if not rig.placed:
		for leg in rig.legs:
			leg.foot = _ground(xf * leg.rest)
			leg.from = leg.foot
			leg.to = leg.foot
		rig.placed = true
	if fresh:
		var feet: PackedVector2Array = mod_feet
		for i in rig.legs.size():
			var at := Vector3(feet[i].x, 0.0, feet[i].y)
			if at.distance_to(rig.legs[i].to) > 0.05:
				_step_to(rig.legs[i], at)
	else:
		_own_steps(rig, xf)
	var hip_lift := Vector3(0.0, bob, 0.0)
	for leg in rig.legs:
		if leg.step >= 0.0:
			var span := maxf(leg.from.distance_to(leg.to), 0.01)
			var time := maxf(span / (STEP_SPEED * sqrt(rig.size)), STEP_MIN_TIME)
			leg.step = minf(leg.step + delta / time, 1.0)
			leg.foot = leg.from.lerp(leg.to, leg.step)
			leg.foot.y = STEP_LIFT * rig.size * minf(span / (1.5 * rig.size), 1.0) * sin(leg.step * PI)
			if leg.step >= 1.0:
				leg.step = -1.0
				leg.foot = leg.to
		_pose_leg(leg, leg.hip0 + hip_lift, xf.affine_inverse() * leg.foot, rig.knee_at)


## A foot starts (or turns, mid-step, towards) a step to `to`.
func _step_to(leg: Leg, to: Vector3) -> void:
	to = _ground(to)
	if leg.step < 0.0:
		leg.from = leg.foot
		leg.from.y = 0.0
		leg.step = 0.0
	leg.to = to


## Legs stepping by themselves: one walking group at a time, each foot back to its ground
## position (and a little ahead while walking) when it strays too far.
func _own_steps(rig: Rig, xf: Transform3D) -> void:
	for leg in rig.legs:
		if leg.step >= 0.0 and leg.group == rig.stepping_group:
			return  # a group is still mid-step
	var moving := Vector2(rig.velocity.x, rig.velocity.z).length() > 0.1
	var lead := rig.velocity * STEP_LEAD
	lead.y = 0.0
	var trigger := rig.step_size if moving else rig.step_size * STEP_TIDY
	var worst := 0.0
	var group := 0
	for leg in rig.legs:
		var want := xf * leg.rest + lead
		var d := Vector2(want.x - leg.to.x, want.z - leg.to.z).length()
		if d > trigger and d > worst and leg.group != rig.stepping_group:
			worst = d
			group = leg.group
	if group == 0:
		# Only the group that just stepped is out of place: let it go again.
		for leg in rig.legs:
			var want := xf * leg.rest + lead
			if Vector2(want.x - leg.to.x, want.z - leg.to.z).length() > trigger * 1.5:
				group = leg.group
				break
	if group == 0:
		return
	rig.stepping_group = group
	for leg in rig.legs:
		if leg.group == group:
			_step_to(leg, xf * leg.rest + lead)


static func _ground(p: Vector3) -> Vector3:
	return Vector3(p.x, 0.0, p.z)


## Bends a leg between its hip and foot (node space): the knee `knee_at` of the way out and as
## high over the higher end as the model's knee stands over its hip; each part stretched along
## its length as Factorio stretches its leg sprites.
static func _pose_leg(leg: Leg, hip: Vector3, foot: Vector3, knee_at: float) -> void:
	var knee := hip.lerp(foot, knee_at)
	knee.y = maxf(hip.y, foot.y) + leg.knee_rise
	leg.upper.transform = _segment(leg.hip0, leg.knee0, hip, knee)
	leg.lower.transform = _segment(leg.knee0, leg.foot0, knee, foot)


## The transform taking a part modelled from a0 to b0 onto a1 to b1: turned without twisting
## about the vertical, stretched along its length.
static func _segment(a0: Vector3, b0: Vector3, a1: Vector3, b1: Vector3) -> Transform3D:
	var f0 := _frame(b0 - a0)
	var f1 := _frame(b1 - a1)
	var stretch := (b1 - a1).length() / maxf((b0 - a0).length(), 0.001)
	var basis := f1 * Basis.from_scale(Vector3(1.0, 1.0, stretch)) * f0.transposed()
	return Transform3D(basis, a1 - basis * a0)


## An orthonormal frame whose z is along `d`, x level.
static func _frame(d: Vector3) -> Basis:
	var z := d.normalized()
	var x := Vector3.UP.cross(z)
	if x.length() < 0.001:
		x = Vector3.RIGHT
	x = x.normalized()
	return Basis(x, z.cross(x), z)


# --- robots ------------------------------------------------------------------------------------

func _robot(rig: Rig, delta: float) -> void:
	var speed := rig.velocity.length()
	rig.amount = move_toward(rig.amount, clampf(speed / ROBOT_FULL_SPEED, 0.0, 1.0), delta * 3.0)
	rig.still = rig.still + delta if speed < 0.08 else 0.0
	rig.phase += delta * TAU * ROBOT_BOB_RATE
	var lift := Vector3(0.0, ROBOT_BOB * sin(rig.phase), 0.0)
	if rig.body != null:
		rig.body.position = lift
	for pair in rig.parts.get("thrusters", []):
		var mi: MeshInstance3D = pair[0]
		mi.transform = Transform3D(Basis.IDENTITY, lift) * _pitched(pair[1], THRUSTER_SWING * rig.amount)
		mi.set_instance_shader_parameter("f3d_glow", 0.3 + 0.7 * rig.amount)
	var cargo: bool = model != null and model.robot_cargo.has(rig.unit)
	for pair in rig.parts.get("lamp_cargo", []):
		_place(pair, lift, cargo)
	for pair in rig.parts.get("lamp_empty", []):
		_place(pair, lift, not cargo)
	var working := rig.kind == "construction" and rig.still > WORK_STILL
	var frame := int(_time / WORK_FRAME) % 2
	for pair in rig.parts.get("lamp_nozzle", []):
		_place(pair, lift, true)
		(pair[0] as MeshInstance3D).set_instance_shader_parameter("f3d_glow", (1.0 if frame == 0 else 0.3) if working else 0.6)
	for pair in rig.parts.get("arms", []):
		var mi: MeshInstance3D = pair[0]
		var reach: float = float(mi.get_meta("reach", 0.0))
		reach = move_toward(reach, ARMS_REACH if working else 0.0, delta * 3.0)
		mi.set_meta("reach", reach)
		mi.transform = Transform3D(Basis.IDENTITY, lift) * _pitched(pair[1], reach)
	if working and sprites != null:
		rig.spark -= delta
		if rig.spark <= 0.0:
			rig.spark = SPARK_EVERY * randf_range(0.6, 1.4)
			var at := rig.node.global_transform * Vector3(0.0, 0.0, -0.35)
			sprites.call("emit", "sparks", at, 0.45, 0.35)


## A part tipped about its pivot's east-west axis (+ forward and down, - back).
static func _pitched(part: ModelLibrary.AnimPart, angle: float) -> Transform3D:
	return part.pivot * Transform3D(Basis(Vector3.RIGHT, angle), Vector3.ZERO) * part.pivot.affine_inverse()


static func _place(pair: Array, lift: Vector3, shown: bool) -> void:
	var mi: MeshInstance3D = pair[0]
	mi.visible = shown
	mi.position = lift


# --- capture robots ----------------------------------------------------------------------------

func _capture(rig: Rig, delta: float) -> void:
	rig.phase += delta * TAU / CAPTURE_LOOP
	var k := 0
	for pair in rig.parts.get("cable", []):
		var mi: MeshInstance3D = pair[0]
		var part: ModelLibrary.AnimPart = pair[1]
		var a := rig.phase + k * 2.1
		var sway := Basis(Vector3.RIGHT, CABLE_SWAY * sin(a)) * Basis(Vector3.BACK, CABLE_SWAY * 0.7 * sin(a * 2.0 + k))
		mi.transform = part.pivot * Transform3D(sway, Vector3.ZERO) * part.pivot.affine_inverse()
		mi.set_instance_shader_parameter("f3d_glow", 0.55 + 0.45 * sin(a * 2.0))
		k += 1


# --- cargo pods --------------------------------------------------------------------------------

func _pod(rig: Rig, delta: float) -> void:
	var height := rig.node.position.y
	rig.amount = move_toward(rig.amount, 1.0 if height > POD_OPEN_HEIGHT else 0.0, delta / POD_OPEN_TIME)
	# The antenna comes out over the first third, the panels swing out over the rest.
	var antenna := clampf(rig.amount / 0.3, 0.0, 1.0)
	var panels := clampf((rig.amount - 0.3) / 0.7, 0.0, 1.0)
	for pair in rig.parts.get("antenna", []):
		(pair[0] as MeshInstance3D).position = Vector3(0.0, POD_ANTENNA_RISE * (antenna - 1.0), 0.0)
	for pair in rig.parts.get("panel", []):
		var mi: MeshInstance3D = pair[0]
		var part: ModelLibrary.AnimPart = pair[1]
		var out := Vector3(part.pivot.origin.x, 0.0, part.pivot.origin.z).normalized()
		var axis := out.cross(Vector3.UP).normalized()
		var turn := Basis(axis, panels * PI * 0.5)
		mi.transform = part.pivot * Transform3D(part.pivot.basis.inverse() * turn * part.pivot.basis, Vector3.ZERO) \
			* part.pivot.affine_inverse()
	var thrust := clampf(absf(rig.velocity.y) / 6.0, 0.0, 1.0) if absf(rig.velocity.y) > POD_THRUST_SPEED else 0.0
	for pair in rig.parts.get("flame", []):
		var mi: MeshInstance3D = pair[0]
		mi.visible = thrust > 0.0
		if thrust > 0.0:
			var flicker := 0.85 + 0.15 * sin(_time * 41.0 + rig.phase)
			mi.scale = Vector3(1.0, (0.5 + 0.5 * thrust) * flicker, 1.0)


# --- car & tank chassis, closed-loop caterpillar tracks ------------------------------------------

func _car(rig: Rig, moved: Vector3, turned: float, delta: float) -> void:
	if not enhanced:
		rig.chassis_xf = Transform3D.IDENTITY
		_apply_chassis(rig)
		for pair in rig.parts.get("engine_fan", []):
			(pair[0] as MeshInstance3D).transform = Transform3D.IDENTITY
		return
	var forward := -rig.node.global_transform.basis.z
	var dist := moved.dot(forward)
	var speed := dist / delta
	var accel := clampf((speed - rig.prev_speed) / delta, -25.0, 25.0)
	rig.prev_speed = speed
	var lat_accel := clampf(speed * (turned / delta), -25.0, 25.0)
	var rumble := (0.0025 + 0.003 * clampf(absf(speed) / 10.0, 0.0, 1.0)) * sin(_time * 42.0 + rig.phase)
	_step_chassis(rig, accel, lat_accel, delta, 110.0, 13.0, 0.0022, 0.0045, 0.045, 0.055, rumble, 0.36)
	_apply_chassis(rig)
	var fan_turns := 1.2 + clampf(absf(speed) * 0.28, 0.0, 3.2)
	rig.fan_angle = fposmod(rig.fan_angle - delta * fan_turns * TAU, TAU)
	for pair in rig.parts.get("engine_fan", []):
		var mi: MeshInstance3D = pair[0]
		var part: ModelLibrary.AnimPart = pair[1]
		mi.transform = rig.chassis_xf * part.pivot * Transform3D(Basis(part.axis, rig.fan_angle), Vector3.ZERO) \
			* part.pivot.affine_inverse()


func _tracks(rig: Rig, moved: Vector3, turned: float, delta: float) -> void:
	var forward := -rig.node.global_transform.basis.z
	var dist := moved.dot(forward)
	rig.travelled += dist
	if not enhanced:
		rig.chassis_xf = Transform3D.IDENTITY
		_apply_chassis(rig)
		var spacing: float = TREAD_SPACING.get("tank", 0.12)
		var slide := fposmod(rig.travelled, spacing)
		for key in ["tread", "tread_l", "tread_r"]:
			for pair in rig.parts.get(key, []):
				(pair[0] as MeshInstance3D).position = Vector3(0.0, 0.0, -slide)
		return
	rig.left_travel += dist + turned * rig.track_l_x
	rig.right_travel += dist + turned * rig.track_r_x
	if absf(dist) > 1e-5 or absf(turned) > 1e-5:
		if rig.track_l_mm != null:
			update_track_mm(rig.track_l_mm, rig.track_l_x, rig.left_travel)
		if rig.track_r_mm != null:
			update_track_mm(rig.track_r_mm, rig.track_r_x, rig.right_travel)
	var speed := dist / delta
	var accel := clampf((speed - rig.prev_speed) / delta, -20.0, 20.0)
	rig.prev_speed = speed
	var lat_accel := clampf(speed * (turned / delta), -20.0, 20.0)
	var move_factor := clampf(absf(speed) / 4.0, 0.0, 1.0)
	var tread_heave := sin(rig.travelled * 7.5) * 0.008 * move_factor
	var clunk := sin(rig.travelled * 17.0 + rig.phase) * 0.0035 * move_factor
	var engine_hum := (0.0016 + 0.0022 * clampf(absf(speed) / 8.0, 0.0, 1.0)) * sin(_time * 24.0 + rig.phase)
	var rumble := engine_hum + tread_heave + clunk
	_step_chassis(rig, accel, lat_accel, delta, 68.0, 8.8, 0.0024, 0.0032, 0.052, 0.042, rumble, 0.48)
	_apply_chassis(rig)


func _step_chassis(rig: Rig, forward_accel: float, lat_accel: float, delta: float,
		stiffness: float, damping: float, pitch_gain: float, roll_gain: float,
		max_pitch: float, max_roll: float, heave: float, pivot_y: float) -> void:
	var target_pitch := clampf(forward_accel * pitch_gain, -max_pitch, max_pitch)
	var target_roll := clampf(-lat_accel * roll_gain, -max_roll, max_roll)
	var steps := maxi(1, ceili(delta / 0.015))
	var dt := delta / float(steps)
	for _i in steps:
		var p_acc := (target_pitch - rig.pitch) * stiffness - rig.pitch_vel * damping
		var r_acc := (target_roll - rig.roll) * stiffness - rig.roll_vel * damping
		rig.pitch_vel += p_acc * dt
		rig.roll_vel += r_acc * dt
		rig.pitch = clampf(rig.pitch + rig.pitch_vel * dt, -max_pitch * 1.4, max_pitch * 1.4)
		rig.roll = clampf(rig.roll + rig.roll_vel * dt, -max_roll * 1.4, max_roll * 1.4)
	var pivot := Vector3(0.0, pivot_y, 0.0)
	var rot := Basis(Vector3.RIGHT, rig.pitch) * Basis(Vector3.BACK, rig.roll)
	rig.chassis_xf = Transform3D(Basis.IDENTITY, pivot + Vector3(0.0, heave, 0.0)) \
		* Transform3D(rot, Vector3.ZERO) * Transform3D(Basis.IDENTITY, -pivot)


func _apply_chassis(rig: Rig) -> void:
	if rig.body != null:
		rig.body.transform = rig.chassis_xf
	for pair in rig.parts.get("headlight", []):
		(pair[0] as MeshInstance3D).transform = rig.chassis_xf


func _attach_tank_tracks(rig: Rig) -> void:
	for key in ["tread_l", "tread_r"]:
		for pair in rig.parts.get(key, []):
			var mi: MeshInstance3D = pair[0]
			var part: ModelLibrary.AnimPart = pair[1]
			mi.visible = false
			var mmi := build_track_mm(part)
			if mmi == null:
				continue
			mmi.name = "TrackCleatsL" if key == "tread_l" else "TrackCleatsR"
			rig.node.add_child(mmi)
			if key == "tread_l":
				rig.track_l_mm = mmi
				rig.track_l_x = part.pivot.origin.x
			else:
				rig.track_r_mm = mmi
				rig.track_r_x = part.pivot.origin.x


static func _ensure_track_contour() -> void:
	if not _track_segs.is_empty():
		return
	var c0: Vector3 = TANK_CIRCLES[0]
	var c1: Vector3 = TANK_CIRCLES[1]
	var c2: Vector3 = TANK_CIRCLES[2]
	var top := _ext_tangent(c0, c2)
	var diag := _ext_tangent(c2, c1)
	var bot := _ext_tangent(c1, c0)
	var top_a: Vector2 = top[0]
	var top_b: Vector2 = top[1]
	var ang_top: float = top[2]
	var diag_a: Vector2 = diag[0]
	var diag_b: Vector2 = diag[1]
	var ang_diag: float = diag[2]
	var bot_a: Vector2 = bot[0]
	var bot_b: Vector2 = bot[1]
	var ang_bot: float = bot[2]
	var c1_a1 := ang_bot - TAU if ang_bot > ang_diag else ang_bot
	var c0_a0 := ang_bot if ang_bot < ang_top else ang_bot - TAU
	var raw := [
		["line", Vector2(TANK_CLEAT_START_Y, top_b.y), top_b, ang_top],
		["arc", c2, ang_top, ang_diag],
		["line", diag_a, diag_b, ang_diag],
		["arc", c1, ang_diag, c1_a1],
		["line", bot_a, bot_b, ang_bot],
		["arc", c0, c0_a0, ang_top - TAU],
		["line", top_a, Vector2(TANK_CLEAT_START_Y, top_a.y), ang_top],
	]
	_track_perim = 0.0
	for seg in raw:
		var seg_arr: Array = seg
		if str(seg_arr[0]) == "line":
			var p0: Vector2 = seg_arr[1]
			var p1: Vector2 = seg_arr[2]
			var l := p0.distance_to(p1)
			_track_segs.append(["line", l, p0, p1, float(seg_arr[3])])
			_track_perim += l
		else:
			var c: Vector3 = seg_arr[1]
			var a0 := float(seg_arr[2])
			var a1 := float(seg_arr[3])
			while a1 > a0:
				a1 -= TAU
			var l := c.z * (a0 - a1)
			_track_segs.append(["arc", l, c.x, c.y, c.z, a0, a1])
			_track_perim += l


static func _ext_tangent(a: Vector3, b: Vector3) -> Array:
	var dy := b.x - a.x
	var dz := b.y - a.y
	var d := sqrt(dy * dy + dz * dz)
	var ang := atan2(dz, dy) + acos(clampf((a.z - b.z) / d, -1.0, 1.0))
	var nx := cos(ang)
	var nz := sin(ang)
	return [Vector2(a.x + a.z * nx, a.y + a.z * nz), Vector2(b.x + b.z * nx, b.y + b.z * nz), ang]


static func track_perimeter() -> float:
	_ensure_track_contour()
	return _track_perim


## Returns Vector3(blender_y_north, blender_z_up, normal_angle_rad) along the CW closed loop.
static func track_sample(s: float) -> Vector3:
	_ensure_track_contour()
	var d := fposmod(s, _track_perim)
	for i in _track_segs.size():
		var seg: Array = _track_segs[i]
		var l := float(seg[1])
		if d <= l or i == _track_segs.size() - 1:
			var t := 0.0 if l <= 1e-8 else minf(1.0, d / l)
			if str(seg[0]) == "line":
				var p0: Vector2 = seg[2]
				var p1: Vector2 = seg[3]
				var p := p0.lerp(p1, t)
				return Vector3(p.x, p.y, float(seg[4]))
			var cy := float(seg[2])
			var cz := float(seg[3])
			var r := float(seg[4])
			var ang := lerpf(float(seg[5]), float(seg[6]), t)
			return Vector3(cy + r * cos(ang), cz + r * sin(ang), ang)
		d -= l
	return Vector3(TANK_CLEAT_START_Y, TANK_CLEAT_TOP_Z, PI * 0.5)


static func extract_top_cleat(part: ModelLibrary.AnimPart) -> ArrayMesh:
	if part == null or part.mesh == null:
		return null
	if _cleat_cache.has(part.mesh):
		return _cleat_cache[part.mesh]
	var out := ArrayMesh.new()
	var origin_shift := Vector3(part.pivot.origin.x, TANK_CLEAT_TOP_Z, -TANK_CLEAT_START_Y)
	for s in part.mesh.get_surface_count():
		var arrays := ModelLibrary.ModelLods.arrays_of(part.mesh, s)
		if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			continue
		var src_idx_var: Variant = arrays[Mesh.ARRAY_INDEX]
		var kept_order: Array[int] = []
		var remap := {}
		var new_idx := PackedInt32Array()
		var tri_indices: PackedInt32Array
		if src_idx_var is PackedInt32Array and not (src_idx_var as PackedInt32Array).is_empty():
			tri_indices = src_idx_var
		else:
			tri_indices = PackedInt32Array()
			tri_indices.resize(verts.size())
			for v_i in verts.size():
				tri_indices[v_i] = v_i
		var j := 0
		while j + 2 < tri_indices.size():
			var i0 := tri_indices[j]
			var i1 := tri_indices[j + 1]
			var i2 := tri_indices[j + 2]
			j += 3
			var c := (verts[i0] + verts[i1] + verts[i2]) / 3.0
			if absf(c.z - (-TANK_CLEAT_START_Y)) < 0.095 and c.y > 0.58:
				for old_i in [i0, i1, i2]:
					if not remap.has(old_i):
						remap[old_i] = kept_order.size()
						kept_order.append(old_i)
					new_idx.append(int(remap[old_i]))
		if new_idx.is_empty():
			continue
		var new_arrays: Array = []
		new_arrays.resize(Mesh.ARRAY_MAX)
		var v_count := verts.size()
		var kept_count := kept_order.size()
		for k in Mesh.ARRAY_MAX:
			if k == Mesh.ARRAY_INDEX:
				new_arrays[k] = new_idx
				continue
			var src_var: Variant = arrays[k]
			if src_var == null:
				continue
			var total: int = src_var.size()
			if total == 0 or total % v_count != 0:
				continue
			var stride: int = total / v_count
			var dst: Variant = src_var.duplicate()
			dst.resize(kept_count * stride)
			if k == Mesh.ARRAY_VERTEX and stride == 1:
				var dst_v: PackedVector3Array = dst
				for ni in kept_count:
					dst_v[ni] = verts[kept_order[ni]] - origin_shift
				new_arrays[k] = dst_v
			else:
				for ni in kept_count:
					var oi := kept_order[ni]
					for el in stride:
						dst[ni * stride + el] = src_var[oi * stride + el]
				new_arrays[k] = dst
		var fmt := int(part.mesh.surface_get_format(s))
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, new_arrays, [], {},
			fmt & ModelLibrary.ModelLods.CUSTOM_FORMATS)
		var surf_idx := out.get_surface_count() - 1
		out.surface_set_material(surf_idx, part.mesh.surface_get_material(s))
		out.surface_set_name(surf_idx, part.mesh.surface_get_name(s))
	_cleat_cache[part.mesh] = out
	return out


static func build_track_mm(part: ModelLibrary.AnimPart) -> MultiMeshInstance3D:
	var cleat := extract_top_cleat(part)
	if cleat == null or cleat.get_surface_count() == 0:
		return null
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = cleat
	mm.instance_count = TANK_CLEATS
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.set_instance_shader_parameter("f3d_glow", 0.0)
	var track_x := part.pivot.origin.x
	mmi.custom_aabb = AABB(Vector3(track_x - 0.35, -0.05, -1.65), Vector3(0.7, 0.85, 3.15))
	update_track_mm(mmi, track_x, 0.0)
	return mmi


static func update_track_mm(mmi: MultiMeshInstance3D, track_x: float, travel: float) -> void:
	if mmi == null or mmi.multimesh == null:
		return
	var mm := mmi.multimesh
	var perim := track_perimeter()
	var n := mm.instance_count
	var xf0 := Transform3D.IDENTITY
	for k in n:
		var sample := track_sample(perim * float(k) / float(n) + travel)
		var xf := Transform3D(Basis(Vector3.RIGHT, sample.z - PI * 0.5), Vector3(track_x, sample.y, -sample.x))
		if k == 0:
			xf0 = xf
		mm.set_instance_transform(k, xf)
	mmi.set_meta("travel", travel)
	mmi.set_meta("cleat0_origin", xf0.origin)
