extends RefCounted
## Physics-driven biter, spitter, worm & nest ragdolls (Phase 1) for the Immersive Enemies add-on.
##
## Lightweight rigid-body + dynamic 6-leg (biter) / 12-leg (spitter) damped-spring solver,
## heavy toppling worms (0 limbs), and destructible nests (grounded ruined base + flying chunks).
## Collides with terrain height/normals, bounces horizontally off solid walls/buildings, separates
## gently from other active ragdolls, emits bounce/decay/flame callbacks, chars & burns
## fire-killed corpses to ash, and settles into resting corpses that decay cleanly.

const GRAVITY := -18.0
const RESTITUTION := 0.16
const WALL_RESTITUTION := 0.42
const GROUND_FRICTION := 8.2
const AIR_DRAG := 0.32
const ANG_DAMPING := 4.2
const GROUND_ANG_MULT := 3.4
const SETTLE_SPEED := 0.38
const SETTLE_ANG_SPEED := 0.65
const SETTLE_HOLD := 0.35
const MAX_ACTIVE_TIME := 4.2
const MAX_SETTLED := 96
const MAX_DETACHED_LEGS := 28
const MAX_SPLIT_PARTS := 48
const CORPSE_LIFETIME := 38.0
const CORPSE_DECAY_TIME := 10.0
const RECENT_BURN_WINDOW := 6.0
const BURN_DURATION := 5.5
const BURN_ASH_TIME := 4.5
const BOUNCE_SMEAR_SPEED := 2.2
const LIMB_COUNT := 6
const MAX_LIMB_COUNT := 12
const SEVERED_SENTINEL := 100.0
const COM_Y := 1.15
const MAX_WOUND_HOLES := 6
const WOUND_STALE_TIME := 45.0
const LIVE_YAW_REFRESH := 0.12
const SPLIT_PARTS := ["head", "thorax", "abdomen"]

const TIER_MASS := {
	"small-biter": 0.6,
	"medium-biter": 0.9,
	"big-biter": 1.3,
	"behemoth-biter": 1.8,
	"small-spitter": 0.48,
	"medium-spitter": 0.72,
	"big-spitter": 1.05,
	"behemoth-spitter": 1.48,
	"small-worm-turret": 1.5,
	"medium-worm-turret": 2.2,
	"big-worm-turret": 3.0,
	"behemoth-worm-turret": 4.0,
	"biter-spawner": 5.0,
	"spitter-spawner": 5.0,
}
const TIER_RADIUS := {
	"small-biter": 0.36,
	"medium-biter": 0.50,
	"big-biter": 0.70,
	"behemoth-biter": 0.92,
	"small-spitter": 0.34,
	"medium-spitter": 0.48,
	"big-spitter": 0.66,
	"behemoth-spitter": 0.86,
	"small-worm-turret": 0.65,
	"medium-worm-turret": 0.85,
	"big-worm-turret": 1.05,
	"behemoth-worm-turret": 1.25,
	"biter-spawner": 1.6,
	"spitter-spawner": 1.6,
}
const TIER_HALF_HEIGHT := {
	"small-biter": 0.22,
	"medium-biter": 0.32,
	"big-biter": 0.46,
	"behemoth-biter": 0.62,
	"small-spitter": 0.22,
	"medium-spitter": 0.32,
	"big-spitter": 0.45,
	"behemoth-spitter": 0.60,
	"small-worm-turret": 0.50,
	"medium-worm-turret": 0.65,
	"big-worm-turret": 0.80,
	"behemoth-worm-turret": 0.95,
	"biter-spawner": 0.65,
	"spitter-spawner": 0.65,
}
const TIER_MODEL_SCALE := {
	"small-biter": 0.5,
	"medium-biter": 0.7,
	"big-biter": 1.0,
	"behemoth-biter": 1.2,
	"small-spitter": 0.5,
	"medium-spitter": 0.7,
	"big-spitter": 1.0,
	"behemoth-spitter": 1.2,
	"small-worm-turret": 0.65,
	"medium-worm-turret": 0.83,
	"big-worm-turret": 1.0,
	"behemoth-worm-turret": 1.2,
	"biter-spawner": 1.0,
	"spitter-spawner": 1.0,
}

var api
var _container: Node3D
var _active: Array = []
var _settled: Array = []
var _wounds: Dictionary = {}  # unit: int -> {blood, hits, holes, pending_hits, last_t}
var _live_yaw: Dictionary = {}  # unit: int -> float
var _clock := 0.0
var _last_yaw_refresh := -10.0
var _last_wound_prune := 0.0
var _rng := RandomNumberGenerator.new()
## Fast native simulation (BiterRagdollNative: limb springs and pairwise separation); main.gd sets it from the
## add-on setting and --enemies-native=off. No native object (no library) = the GDScript below.
var use_native := true
var _native: Object = null
var _native_tried := false

var force_mul := 1.0
var max_active := 32
var gibs_enabled := true
var gore_enabled := true
var blood_amount := 1.0
var on_bounce: Callable = Callable()
var on_decay_dust: Callable = Callable()
var on_burn_flame: Callable = Callable()


func _init(a, root: Node3D) -> void:
	api = a
	_rng.randomize()
	_container = Node3D.new()
	_container.name = "BiterRagdolls"
	root.add_child(_container)


## For tests: hand in (or take away with null) the native object.
func set_native(obj: Object) -> void:
	_native = obj
	_native_tried = true


func _get_native() -> Object:
	if not use_native:
		return null
	if not _native_tried:
		_native_tried = true
		if api != null and api.has_method("native_class"):
			_native = api.native_class("BiterRagdollNative")
	return _native


func active_count() -> int:
	return _active.size()


func settled_count() -> int:
	return _settled.size()


func set_gore_enabled(on: bool) -> void:
	gore_enabled = on
	if not on:
		_clear_live_wounds()
	elif blood_amount > 0.001 and api != null and api.get("creatures") != null and api.creatures.has_method("set_unit_wounds"):
		for k in _wounds:
			var w: Dictionary = _wounds[k] as Dictionary
			var eff_blood: float = clampf(float(w.get("blood", 0.0)) * blood_amount, 0.0, 1.0)
			api.creatures.set_unit_wounds(int(k), eff_blood, int(w.get("hits", 0)))
	_refresh_ragdoll_wounds()


func set_blood_amount(val: float) -> void:
	blood_amount = clampf(val, 0.0, 2.0)
	if not gore_enabled or blood_amount <= 0.001:
		_clear_live_wounds()
	elif api != null and api.get("creatures") != null and api.creatures.has_method("set_unit_wounds"):
		for k in _wounds:
			var w: Dictionary = _wounds[k] as Dictionary
			var eff_blood: float = clampf(float(w.get("blood", 0.0)) * blood_amount, 0.0, 1.0)
			api.creatures.set_unit_wounds(int(k), eff_blood, int(w.get("hits", 0)))
	_refresh_ragdoll_wounds()


func _refresh_ragdoll_wounds() -> void:
	for rec_obj in _active:
		var rec: Dictionary = rec_obj as Dictionary
		var mn: Variant = rec.get("node", null)
		if mn is MeshInstance3D and is_instance_valid(mn):
			_apply_ragdoll_wounds(mn as MeshInstance3D, float(rec.get("blood", 0.0)), rec.get("holes", []) as Array)
	for rec_obj in _settled:
		var rec: Dictionary = rec_obj as Dictionary
		var mn: Variant = rec.get("node", null)
		if mn is MeshInstance3D and is_instance_valid(mn):
			_apply_ragdoll_wounds(mn as MeshInstance3D, float(rec.get("blood", 0.0)), rec.get("holes", []) as Array)


func clear_wound(unit: int) -> void:
	if unit != 0:
		_wounds.erase(unit)
		if api != null and api.get("creatures") != null and api.creatures.has_method("set_unit_wounds"):
			api.creatures.set_unit_wounds(unit, 0.0, 0)


## (0.1.2) Whether spawn() would take a body now with `pending` bodies already promised to queued
## deaths of a burst (each counted as a whole body plus its pieces).
func can_take(proto: String, pending: int) -> bool:
	if api == null or _container == null or not _is_supported(proto):
		return false
	return _active_body_count() + pending < max_active and _active.size() + pending * 4 < max_active * 3


func _is_supported(proto: String) -> bool:
	return (
		proto.ends_with("-biter")
		or proto.ends_with("-spitter")
		or proto.ends_with("-worm-turret")
		or proto == "biter-spawner"
		or proto == "spitter-spawner"
	)


func _is_worm(proto: String) -> bool:
	return proto.ends_with("-worm-turret")


func _is_spawner(proto: String) -> bool:
	return proto == "biter-spawner" or proto == "spitter-spawner"


func _limb_count_for(proto: String) -> int:
	if _is_worm(proto) or _is_spawner(proto):
		return 0
	return mini(12 if proto.ends_with("-spitter") else LIMB_COUNT, MAX_LIMB_COUNT)


func _is_fire_hit(damage_type: String, fx_kind: String, src: String) -> bool:
	if damage_type == "fire" or fx_kind == "burn":
		return true
	if src.contains("flame") or src == "fire" or src.begins_with("fire-") or src.contains("-fire"):
		return true
	return false


func on_damaged(info: Dictionary) -> void:
	if api == null:
		return
	var proto: String = str(info.get("name", ""))
	if not _is_supported(proto):
		return
	var unit: int = int(info.get("unit", 0))
	if unit == 0:
		return

	var dmg: int = int(info.get("dmg", 0))
	var hp: int = int(info.get("hp", -1))
	var src: String = str(info.get("src", "")).to_lower()
	var fx_kind: String = str(info.get("fx", "")).to_lower()
	var damage_type: String = str(info.get("damage_type", "physical")).to_lower()
	var pos: Vector3 = info.get("pos", Vector3.ZERO) as Vector3
	var cause_pos: Variant = info.get("cause_pos", null)
	var scale: float = float(TIER_MODEL_SCALE.get(proto, 1.0))

	var is_static_enemy: bool = _is_worm(proto) or _is_spawner(proto)
	var w: Dictionary
	if _wounds.has(unit):
		w = _wounds[unit] as Dictionary
	else:
		w = {
			"blood": 0.0,
			"hits": 0,
			"holes": [],
			"pending_hits": [],
			"last_t": _clock,
		}
		_wounds[unit] = w

	if _is_fire_hit(damage_type, fx_kind, src):
		w["burn_t"] = _clock

	var hits: int = int(w["hits"]) + 1
	w["hits"] = hits
	var prev_blood: float = float(w["blood"])
	var blood: float
	if hp >= 0:
		blood = clampf((1.0 - float(hp) / 1000.0) * 0.65, 0.06, 0.65)
	else:
		blood = clampf(prev_blood + 0.12, 0.0, 0.65)
	w["blood"] = blood
	w["last_t"] = _clock

	var holes: Array = w["holes"] as Array
	var pending: Array = w["pending_hits"] as Array
	var yaw: float = float(info["yaw"]) if info.has("yaw") else (0.0 if is_static_enemy else _lookup_live_yaw(unit))
	if not is_nan(yaw):
		var hole: Vector4 = _make_torso_hole(pos, cause_pos, yaw, scale, damage_type, dmg, src, proto)
		_push_hole(holes, hole)
	else:
		var incoming := Vector3.ZERO
		var has_cause: bool = false
		if cause_pos is Vector3:
			incoming = (cause_pos as Vector3) - pos
			incoming.y = 0.0
			if incoming.length_squared() > 0.0004:
				incoming = incoming.normalized()
				has_cause = true
		if holes.size() + pending.size() >= MAX_WOUND_HOLES:
			if not pending.is_empty():
				pending.pop_front()
			elif not holes.is_empty():
				holes.pop_front()
		pending.append({
			"dir": incoming,
			"has_cause": has_cause,
			"damage_type": damage_type,
			"dmg": dmg,
			"src": src,
		})

	if gore_enabled and blood_amount > 0.001 and api.get("creatures") != null and api.creatures.has_method("set_unit_wounds"):
		api.creatures.set_unit_wounds(unit, clampf(blood * blood_amount, 0.0, 1.0), hits)


func spawn(info: Dictionary) -> bool:
	if api == null or _container == null:
		return false
	var proto: String = str(info.get("name", ""))
	if not _is_supported(proto):
		return false

	var is_worm: bool = _is_worm(proto)
	var is_spawner: bool = _is_spawner(proto)
	var unit: int = int(info.get("unit", 0))
	var wound_rec: Variant = _wounds.get(unit, null) if unit != 0 else null
	if unit != 0:
		_wounds.erase(unit)
		if (is_worm or is_spawner) and api.get("creatures") != null and api.creatures.has_method("set_unit_wounds"):
			api.creatures.set_unit_wounds(unit, 0.0, 0)

	if _active_body_count() >= max_active or _active.size() >= max_active * 3:
		return false

	var pos: Vector3 = info.get("pos", Vector3.ZERO) as Vector3
	var yaw: float = float(info.get("yaw", 0.0))
	var init_vel: Vector3 = info.get("vel", Vector3.ZERO) as Vector3
	var default_scale: float = float(TIER_MODEL_SCALE.get(proto, 1.0))
	var scale: float = maxf(float(info.get("scale", default_scale)), 0.1)
	var cause_pos: Variant = info.get("cause_pos", null)
	var damage_type: String = str(info.get("damage_type", "physical")).to_lower()
	var dmg: int = int(info.get("dmg", 0))
	var src: String = str(info.get("src", "")).to_lower()

	var blood := 0.0
	var hits := 0
	var holes: Array = []
	var recently_burned := false
	if wound_rec is Dictionary:
		var wd: Dictionary = wound_rec as Dictionary
		blood = float(wd.get("blood", 0.0))
		hits = int(wd.get("hits", 0))
		if wd.has("burn_t") and (_clock - float(wd["burn_t"])) <= RECENT_BURN_WINDOW:
			recently_burned = true
		var saved_holes: Array = wd.get("holes", []) as Array
		for h in saved_holes:
			if h is Vector4:
				holes.append(h)
		var pending_hits: Array = wd.get("pending_hits", []) as Array
		for ph in pending_hits:
			if ph is Dictionary:
				var pd: Dictionary = ph as Dictionary
				var pdir: Vector3 = pd.get("dir", Vector3.ZERO) as Vector3
				var p_has: bool = bool(pd.get("has_cause", false))
				var p_dt: String = str(pd.get("damage_type", "physical"))
				var p_dmg: int = int(pd.get("dmg", 0))
				var p_src: String = str(pd.get("src", ""))
				var phole: Vector4 = _make_torso_hole_from_dir(pdir, p_has, yaw, scale, p_dt, p_dmg, p_src, proto)
				_push_hole(holes, phole)

	# Add one final lethal impact hole on death.
	var lethal_hole: Vector4 = _make_torso_hole(pos, cause_pos, yaw, scale, damage_type, dmg, src, proto)
	_push_hole(holes, lethal_hole)

	var was_burning: bool = _is_fire_hit(damage_type, "", src) or recently_burned
	var is_spitter: bool = proto.ends_with("-spitter")
	var limb_count: int = _limb_count_for(proto)

	var is_explosive_src: bool = (
		damage_type == "explosion"
		or src.contains("grenade")
		or src.contains("rocket")
		or src.contains("artillery")
		or src.contains("cannon")
	)
	var is_non_dismember: bool = (
		damage_type == "fire"
		or damage_type == "poison"
		or damage_type == "acid"
		or damage_type == "laser"
		or damage_type == "electric"
	)
	var should_split: bool = is_explosive_src or (not is_non_dismember and dmg >= 850)
	var is_heavy: bool = not is_non_dismember and (damage_type == "impact" or dmg >= 450 or src.contains("shotgun"))
	# A deep burst queue (main.gd) asks for a cheap body: whole, no split parts or detached legs.
	var lite: bool = bool(info.get("lite", false))

	var detach_want := 0
	if should_split:
		blood = maxf(blood, 0.88)
		if limb_count > 0:
			detach_want = _rng.randi_range(4, 6) if is_spitter else _rng.randi_range(3, 5)
	elif is_non_dismember:
		blood = maxf(blood, 0.25)
		detach_want = 0
	elif is_heavy:
		blood = maxf(blood, 0.72)
		if limb_count > 0:
			detach_want = _rng.randi_range(2, 4) if is_spitter else _rng.randi_range(2, 3)
	elif dmg >= 200 or hits >= 4:
		blood = maxf(blood, 0.45)
		if limb_count > 0:
			detach_want = _rng.randi_range(1, 2)
	else:
		blood = maxf(blood, 0.25)
		detach_want = 0

	if lite:
		detach_want = 0

	var mass: float = float(TIER_MASS.get(proto, 1.0))
	var radius: float = float(TIER_RADIUS.get(proto, 0.5))
	var half_h: float = float(TIER_HALF_HEIGHT.get(proto, 0.32))

	var h_init := Vector3(init_vel.x, 0.0, init_vel.z)
	var init_speed: float = h_init.length()
	var dir_xz: Vector3 = _launch_dir(pos, init_vel, cause_pos)
	var gh: float = float(api.creatures.ground_height(pos.x, pos.z))
	var quat: Quaternion = Quaternion(Vector3.UP, yaw)

	# Nests / spawners leave a grounded ruined corpse base in their crater (with wounds & burning-to-ash)
	# and on explosive/overkill or heavy kills also blast 3 meat-capped nest chunks outward.
	if is_spawner:
		var corpse_node: MeshInstance3D = api.creatures.make_ragdoll_node(proto + "-corpse")
		if corpse_node == null:
			corpse_node = api.creatures.make_ragdoll_node(proto)
		if corpse_node == null:
			return false
		var crater_pos := Vector3(pos.x, gh, pos.z)
		var nest_blood: float = maxf(blood, 0.55)
		_container.add_child(corpse_node)
		corpse_node.transform = Transform3D(Basis(quat), crater_pos)
		_apply_ragdoll_wounds(corpse_node, nest_blood, holes)
		if was_burning:
			_apply_ragdoll_burn(corpse_node, 0.25)
		_settle_body({
			"node": corpse_node,
			"proto": proto,
			"is_leg": false,
			"is_part": false,
			"is_worm": false,
			"is_spawner": true,
			"part_name": "",
			"limb_count": 0,
			"pos": Vector3(pos.x, gh + 0.35 * scale, pos.z),
			"scale": scale * 1.45,
			"burning": was_burning,
			"burn_age": 0.0,
			"flame_cd": 0.0,
			"blood": nest_blood,
			"holes": holes.duplicate(),
		}, gh)
		if (should_split or is_heavy) and gibs_enabled and not lite:
			var nest_com := Vector3(pos.x, maxf(pos.y, gh) + 0.75 * scale, pos.z)
			_spawn_split_body(proto, 0, crater_pos, nest_com, quat, h_init, dir_xz, mass, radius, scale, maxf(blood, 0.85), holes, 0, was_burning)
		return true

	var impulse_dt: String = "explosion" if is_explosive_src else damage_type
	var launch: Dictionary = _compute_impulse(impulse_dt, dir_xz, mass)
	# Preserve 100% of pre-death sprint momentum with restrained pitch/tumble torque.
	var lin_vel: Vector3 = (launch["vel"] as Vector3) + h_init
	var ang_vel: Vector3 = launch["ang"] as Vector3
	if init_speed > 0.4:
		var init_dir: Vector3 = h_init / init_speed
		ang_vel += Vector3.UP.cross(init_dir) * (init_speed * 0.45)
	if is_worm and not is_explosive_src:
		var topple_axis: Vector3 = Vector3.UP.cross(dir_xz)
		if topple_axis.length_squared() > 0.0001:
			ang_vel += topple_axis.normalized() * _rng.randf_range(3.2, 4.8)

	var com_local := Vector3(0.0, (1.6 if is_worm else COM_Y) * scale, 0.0)
	var com_world := Vector3(pos.x, maxf(pos.y, gh) + com_local.y, pos.z)
	var mesh_origin: Vector3 = com_world - (quat * com_local)

	# Grenades / explosions / overkill split the creature into 3 solid body chunks + severed legs.
	if should_split and gibs_enabled and not lite:
		if _spawn_split_body(proto, limb_count, mesh_origin, com_world, quat, h_init, dir_xz, mass, radius, scale, blood, holes, detach_want, was_burning):
			return true

	var node: MeshInstance3D = api.creatures.make_ragdoll_node(proto)
	if node == null:
		return false

	var swing := PackedFloat32Array()
	var swing_v := PackedFloat32Array()
	var lift := PackedFloat32Array()
	var lift_v := PackedFloat32Array()
	var knee := PackedFloat32Array()
	var knee_v := PackedFloat32Array()
	var twists := PackedFloat32Array()
	var twists_v := PackedFloat32Array()
	var severed := PackedByteArray()
	var limbs := PackedVector3Array()
	if limb_count > 0:
		swing.resize(limb_count)
		swing_v.resize(limb_count)
		lift.resize(limb_count)
		lift_v.resize(limb_count)
		knee.resize(limb_count)
		knee_v.resize(limb_count)
		twists.resize(limb_count)
		twists_v.resize(limb_count)
		severed.resize(limb_count)
		limbs.resize(limb_count)

		var kick_mag: float = clampf(lin_vel.length() * 0.85, 2.2, 10.0)
		for i in limb_count:
			swing[i] = _rng.randf_range(-0.45, 0.45)
			lift[i] = _rng.randf_range(-0.35, 0.45)
			knee[i] = _rng.randf_range(-0.4, 0.4)
			twists[i] = _rng.randf_range(-0.35, 0.35)
			swing_v[i] = _rng.randf_range(-kick_mag, kick_mag)
			lift_v[i] = _rng.randf_range(-kick_mag * 0.85, kick_mag * 1.05)
			knee_v[i] = _rng.randf_range(-kick_mag * 0.95, kick_mag * 0.95)
			twists_v[i] = _rng.randf_range(-kick_mag * 0.9, kick_mag * 0.9)
			severed[i] = 0
			limbs[i] = Vector3(swing[i], lift[i], knee[i])

		if detach_want > 0:
			_detach_legs(proto, detach_want, limb_count, mesh_origin, quat, lin_vel, mass, radius, scale, blood, twists, severed, was_burning)

	_container.add_child(node)
	node.transform = Transform3D(Basis(quat), mesh_origin)
	if limb_count > 0:
		api.creatures.set_ragdoll_limbs(node, limbs, twists)
	_apply_ragdoll_wounds(node, blood, holes)
	if was_burning:
		_apply_ragdoll_burn(node, 0.25)

	var body := {
		"node": node,
		"proto": proto,
		"is_leg": false,
		"is_part": false,
		"is_worm": is_worm,
		"part_name": "",
		"limb_count": limb_count,
		"pos": com_world,
		"com_local": com_local,
		"vel": lin_vel,
		"quat": quat,
		"ang": ang_vel,
		"scale": scale,
		"mass": mass,
		"radius": radius,
		"half_h": half_h,
		"age": 0.0,
		"still": 0.0,
		"grounded": false,
		"skid_cd": 0.0,
		"skid_count": 0,
		"burning": was_burning,
		"burn_age": 0.0,
		"flame_cd": 0.0,
		"swing": swing,
		"swing_v": swing_v,
		"lift": lift,
		"lift_v": lift_v,
		"knee": knee,
		"knee_v": knee_v,
		"twists": twists,
		"twists_v": twists_v,
		"severed": severed,
		"limbs": limbs,
		"blood": blood,
		"holes": holes.duplicate(),
	}
	_active.append(body)
	return true


func step(dt: float) -> void:
	if dt <= 0.0 or api == null:
		return
	_clock += dt
	if not _active.is_empty():
		_step_active(dt)
	if not _settled.is_empty():
		_step_settled(dt)
	if not _wounds.is_empty() and _clock - _last_wound_prune >= 5.0:
		_prune_stale_wounds()
		_last_wound_prune = _clock


func clear() -> void:
	for b in _active:
		var body: Dictionary = b as Dictionary
		var n: Variant = body.get("node", null)
		if n is Node and is_instance_valid(n):
			(n as Node).queue_free()
	_active.clear()
	for s in _settled:
		var rec: Dictionary = s as Dictionary
		var n: Variant = rec.get("node", null)
		if n is Node and is_instance_valid(n):
			(n as Node).queue_free()
	_settled.clear()
	_clear_live_wounds()
	_wounds.clear()
	_live_yaw.clear()
	_last_yaw_refresh = -10.0


func dispose() -> void:
	clear()
	if _container != null and is_instance_valid(_container):
		var parent: Node = _container.get_parent()
		if parent != null:
			parent.remove_child(_container)
		_container.queue_free()
	_container = null
	api = null


func _step_active(dt: float) -> void:
	var n_active: int = _active.size()
	# Gentle pairwise separation between active ragdolls.
	var nat: Object = _get_native()
	if n_active > 1 and nat != null:
		_separate_native(nat, n_active, dt)
	elif n_active > 1:
		_separate_script(n_active, dt)

	var i: int = _active.size() - 1
	while i >= 0:
		var body: Dictionary = _active[i] as Dictionary
		var node: MeshInstance3D = body["node"] as MeshInstance3D
		if node == null or not is_instance_valid(node):
			_active.remove_at(i)
			i -= 1
			continue

		var pos: Vector3 = body["pos"] as Vector3
		var vel: Vector3 = body["vel"] as Vector3
		var quat: Quaternion = body["quat"] as Quaternion
		var ang: Vector3 = body["ang"] as Vector3
		var radius: float = float(body["radius"])
		var half_h: float = float(body["half_h"])
		var scale: float = float(body["scale"])

		var prev_vel: Vector3 = vel
		vel.y += GRAVITY * dt
		vel *= maxf(0.0, 1.0 - AIR_DRAG * dt)

		var next_pos: Vector3 = pos + vel * dt

		# Horizontal wall / building collision via solid_at(x, z).
		var sx: float = 1.0 if vel.x >= 0.0 else -1.0
		if absf(vel.x) > 0.05 and bool(api.creatures.solid_at(next_pos.x + sx * radius, pos.z)):
			next_pos.x = pos.x
			vel.x = -vel.x * WALL_RESTITUTION
			ang.z += vel.x * 0.7
			ang.y += _rng.randf_range(-1.2, 1.2)

		var sz: float = 1.0 if vel.z >= 0.0 else -1.0
		if absf(vel.z) > 0.05 and bool(api.creatures.solid_at(next_pos.x, next_pos.z + sz * radius)):
			next_pos.z = pos.z
			vel.z = -vel.z * WALL_RESTITUTION
			ang.x -= vel.z * 0.7
			ang.y += _rng.randf_range(-1.2, 1.2)

		# Ground height & normal collision (supports slopes / hills).
		var gh: float = float(api.creatures.ground_height(next_pos.x, next_pos.z))
		var normal: Vector3 = api.creatures.ground_normal(next_pos.x, next_pos.z) as Vector3
		if normal.length_squared() < 0.01:
			normal = Vector3.UP
		else:
			normal = normal.normalized()

		var is_leg: bool = bool(body.get("is_leg", false))
		var is_part: bool = bool(body.get("is_part", false))
		var is_worm: bool = bool(body.get("is_worm", false))
		var has_limbs: bool = not is_leg and not is_part and int(body.get("limb_count", 0)) > 0
		var com_local: Vector3 = body.get("com_local", Vector3.ZERO) as Vector3
		var up_dot: float = (quat * Vector3.UP).dot(normal)
		var rest_clear: float
		if is_leg:
			rest_clear = 0.16 * clampf(scale * 2.0, 0.5, 1.5)
		elif is_part:
			rest_clear = half_h
		elif is_worm:
			rest_clear = lerpf(half_h, com_local.y, absf(up_dot))
		elif up_dot > 0.35:
			rest_clear = 0.54 * scale
		elif up_dot < -0.35:
			rest_clear = 0.82 * scale
		else:
			rest_clear = 0.65 * scale
		var floor_y: float = gh + rest_clear
		var grounded: bool = false
		var bounce_kick: float = 0.0

		if next_pos.y <= floor_y:
			next_pos.y = floor_y
			grounded = true
			var vn: float = vel.dot(normal)
			if vn < -0.5:
				var impact_speed: float = -vn
				vel -= (1.0 + RESTITUTION) * vn * normal
				var vel_tan: Vector3 = vel - normal * vel.dot(normal)
				ang += normal.cross(vel_tan) * 0.35
				bounce_kick = clampf(impact_speed * 0.7, 0.0, 8.0)
				if impact_speed >= BOUNCE_SMEAR_SPEED and on_bounce.is_valid():
					var smear_scale: float = scale * 0.75 if is_part else scale
					on_bounce.call(Vector3(next_pos.x, gh, next_pos.z), impact_speed, smear_scale)
			elif vn < 0.0:
				vel -= vn * normal

			# Slope gravity & gentle downhill slide/tumble.
			var slope_g: Vector3 = Vector3(0.0, GRAVITY, 0.0) - normal * (GRAVITY * normal.y)
			if slope_g.length_squared() > 0.25:
				vel += slope_g * dt
				ang += normal.cross(slope_g) * (0.25 * dt)

			# High ground friction on tangential velocity for a heavy dirt skid & thud.
			var tan_vel: Vector3 = vel - normal * vel.dot(normal)
			var tan_speed: float = tan_vel.length()
			if not is_leg and tan_speed >= 3.0 and on_bounce.is_valid():
				var skid_cd: float = float(body.get("skid_cd", 0.0)) - dt
				var skid_count: int = int(body.get("skid_count", 0))
				if skid_cd <= 0.0 and skid_count < 2:
					var skid_scale: float = scale * 0.65 if is_part else scale * 0.85
					on_bounce.call(Vector3(next_pos.x, gh, next_pos.z), tan_speed * 0.65, skid_scale)
					skid_cd = 0.14
					skid_count += 1
				body["skid_cd"] = skid_cd
				body["skid_count"] = skid_count
			var fric: float = exp(-GROUND_FRICTION * dt)
			vel = normal * vel.dot(normal) + tan_vel * fric

			# Strong grounded angular damping + anti-roll stabilization so bodies skid & settle flat.
			# Upright worms topple freely under gravity until they slap down onto their side.
			var body_up: Vector3 = quat * Vector3.UP
			var worm_toppling: bool = is_worm and absf(body_up.dot(normal)) > 0.18
			if worm_toppling:
				ang *= exp(-2.2 * dt)
				var horiz_w: Vector3 = body_up - normal * body_up.dot(normal)
				if horiz_w.length_squared() > 0.0004:
					ang += body_up.cross(horiz_w.normalized()) * (16.0 * dt)
				else:
					var ta: float = _rng.randf_range(0.0, TAU)
					ang += body_up.cross(Vector3(cos(ta), 0.0, sin(ta))) * (6.0 * dt)
			else:
				ang *= exp(-ANG_DAMPING * GROUND_ANG_MULT * dt)
				var ang_yaw: Vector3 = normal * ang.dot(normal)
				var ang_tilt: Vector3 = ang - ang_yaw
				ang = ang_yaw + ang_tilt * exp(-4.8 * dt)
				if is_leg or is_worm:
					var horiz: Vector3 = body_up - normal * body_up.dot(normal)
					if horiz.length_squared() > 0.001:
						var target_flat: Vector3 = horiz.normalized()
						ang += body_up.cross(target_flat) * (12.0 * dt)
				else:
					var target_up: Vector3 = normal if body_up.dot(normal) >= -0.15 else -normal
					var align_axis: Vector3 = body_up.cross(target_up)
					ang += align_axis * (16.0 * dt)
		else:
			ang *= exp(-ANG_DAMPING * 0.35 * dt)

		var ang_speed: float = ang.length()
		if ang_speed > 0.0001:
			var dq: Quaternion = Quaternion(ang / ang_speed, minf(ang_speed * dt, 0.8))
			quat = (dq * quat).normalized()

		if has_limbs:
			var lin_acc: Vector3 = (vel - prev_vel) / maxf(dt, 0.001)
			_step_limbs(body, dt, lin_acc, ang, quat, normal, grounded, bounce_kick)

		var age: float = float(body["age"]) + dt
		var still: float = float(body["still"])
		var worm_still_upright: bool = is_worm and absf((quat * Vector3.UP).dot(normal)) > 0.22
		if grounded and not worm_still_upright and vel.length() < SETTLE_SPEED and ang.length() < SETTLE_ANG_SPEED:
			still += dt
		else:
			still = 0.0

		body["pos"] = next_pos
		body["vel"] = vel
		body["quat"] = quat
		body["ang"] = ang
		body["age"] = age
		body["still"] = still
		body["grounded"] = grounded

		node.transform = Transform3D(Basis(quat), next_pos - (quat * com_local))
		if has_limbs:
			api.creatures.set_ragdoll_limbs(node, body["limbs"] as PackedVector3Array, body["twists"] as PackedFloat32Array)

		if bool(body.get("burning", false)):
			var burn_age: float = float(body.get("burn_age", 0.0)) + dt
			body["burn_age"] = burn_age
			var burn_level: float = clampf(burn_age / 2.2, 0.25, 1.0)
			_apply_ragdoll_burn(node, burn_level)
			var flame_cd: float = float(body.get("flame_cd", 0.0)) - dt
			if flame_cd <= 0.0 and on_burn_flame.is_valid():
				var ash_t: float = clampf((burn_age - BURN_DURATION) / BURN_ASH_TIME, 0.0, 1.0)
				var emit_scale: float = scale * 0.7 if is_part else scale
				on_burn_flame.call(next_pos, emit_scale, ash_t)
				flame_cd = _rng.randf_range(0.09, 0.14)
			body["flame_cd"] = flame_cd

		if still >= SETTLE_HOLD or age >= MAX_ACTIVE_TIME:
			_settle_body(body, gh)
			_active.remove_at(i)
		i -= 1


func _separate_script(n_active: int, dt: float) -> void:
	for i in range(n_active):
		var bi: Dictionary = _active[i] as Dictionary
		var pi: Vector3 = bi["pos"] as Vector3
		var ri: float = float(bi["radius"])
		for j in range(i + 1, n_active):
			var bj: Dictionary = _active[j] as Dictionary
			var pj: Vector3 = bj["pos"] as Vector3
			var min_d: float = ri + float(bj["radius"])
			var diff: Vector3 = pj - pi
			diff.y = 0.0
			var d2: float = diff.length_squared()
			if d2 > 0.00001 and d2 < min_d * min_d:
				var d: float = sqrt(d2)
				var push_dir: Vector3 = diff / d
				var overlap: float = (min_d - d) * 0.5
				var push_v: Vector3 = push_dir * minf(overlap * 6.0, 2.5) * dt
				bi["pos"] = pi - push_dir * (overlap * 0.35)
				bj["pos"] = pj + push_dir * (overlap * 0.35)
				bi["vel"] = (bi["vel"] as Vector3) - push_v
				bj["vel"] = (bj["vel"] as Vector3) + push_v
				pi = bi["pos"] as Vector3


func _separate_native(nat: Object, n_active: int, dt: float) -> void:
	var data := PackedFloat32Array()
	data.resize(n_active * 8)
	for i in n_active:
		var b: Dictionary = _active[i] as Dictionary
		var p: Vector3 = b["pos"] as Vector3
		var v: Vector3 = b["vel"] as Vector3
		var o: int = i * 8
		data[o] = p.x
		data[o + 1] = p.y
		data[o + 2] = p.z
		data[o + 3] = float(b["radius"])
		data[o + 4] = v.x
		data[o + 5] = v.y
		data[o + 6] = v.z
	var out: PackedFloat32Array = nat.separate(data, n_active, dt)
	for i in n_active:
		var o: int = i * 8
		if data[o] == out[o] and data[o + 2] == out[o + 2] and data[o + 4] == out[o + 4] and data[o + 6] == out[o + 6]:
			continue
		var b: Dictionary = _active[i] as Dictionary
		b["pos"] = Vector3(out[o], out[o + 1], out[o + 2])
		b["vel"] = Vector3(out[o + 4], out[o + 5], out[o + 6])


func _step_limbs_native(nat: Object, body: Dictionary, dt: float, lin_acc: Vector3, ang: Vector3, quat: Quaternion, normal: Vector3, grounded: bool, bounce_kick: float) -> void:
	var limbs: PackedVector3Array = body["limbs"] as PackedVector3Array
	var limb_count: int = mini(int(body.get("limb_count", limbs.size())), limbs.size())
	if not body.has("ls"):
		body["ls"] = nat.make_state(body["swing"], body["swing_v"], body["lift"], body["lift_v"], body["knee"], body["knee_v"], body["twists"], body["twists_v"])
	body["ls"] = nat.step_limbs(body["ls"], body["severed"], limb_count, dt, lin_acc, ang, quat, normal, grounded, bounce_kick)
	# limbs / twists stay the arrays set_ragdoll_limbs and _settle_body read.
	body["limbs"] = nat.last_limbs()
	body["twists"] = nat.last_twists()


func _step_limbs(body: Dictionary, dt: float, lin_acc: Vector3, ang: Vector3, quat: Quaternion, normal: Vector3, grounded: bool, bounce_kick: float) -> void:
	var nat: Object = _get_native()
	if nat != null:
		_step_limbs_native(nat, body, dt, lin_acc, ang, quat, normal, grounded, bounce_kick)
		return
	# Typed assignment (not `as`, which copies a packed array) so the writes below reach the body's arrays.
	var swing: PackedFloat32Array = body["swing"]
	var swing_v: PackedFloat32Array = body["swing_v"]
	var lift: PackedFloat32Array = body["lift"]
	var lift_v: PackedFloat32Array = body["lift_v"]
	var knee: PackedFloat32Array = body["knee"]
	var knee_v: PackedFloat32Array = body["knee_v"]
	var twists: PackedFloat32Array = body["twists"]
	var twists_v: PackedFloat32Array = body["twists_v"]
	var severed: PackedByteArray = body["severed"]
	var limbs: PackedVector3Array = body["limbs"]
	var limb_count: int = mini(int(body.get("limb_count", limbs.size())), limbs.size())
	var is_spitter: bool = limb_count > 6

	var inv_q: Quaternion = quat.inverse()
	var local_acc: Vector3 = inv_q * lin_acc
	var local_ang: Vector3 = inv_q * ang
	var local_grav: Vector3 = inv_q * Vector3(0.0, -1.0, 0.0)
	var up_dot: float = (quat * Vector3.UP).dot(normal)

	var stiffness: float = 4.5 if grounded else 2.2
	var damping: float = 4.2 if grounded else 2.0

	for i in limb_count:
		if severed[i] != 0:
			twists[i] = SEVERED_SENTINEL
			continue
		var side: float
		var pair_idx: int
		var fore_bias: float
		if is_spitter:
			side = -1.0 if i < 6 else 1.0
			pair_idx = i % 6
			fore_bias = (2.5 - float(pair_idx)) * 0.16
		else:
			side = -1.0 if (i % 2) == 0 else 1.0
			pair_idx = i / 2
			fore_bias = (1.0 - float(pair_idx)) * 0.35

		var t_swing: float = fore_bias + local_grav.z * 0.9
		var t_lift: float = -local_grav.y * 0.85 + local_grav.x * side * 0.75
		var t_knee: float = 0.0
		var t_twist: float = local_grav.z * side * 0.45
		if grounded:
			if up_dot >= 0.0:
				t_lift += 0.45 + float(pair_idx) * (0.06 if is_spitter else 0.12)
				t_knee = -0.45
			else:
				t_lift -= 0.55
				t_knee = 1.05
		else:
			t_knee = clampf(-local_grav.y * 0.65, -1.4, 1.4)

		var acc_swing: float = stiffness * (t_swing - swing[i]) - damping * swing_v[i]
		acc_swing += clampf(-local_acc.z * 0.16 + local_ang.y * side * 1.4, -26.0, 26.0)

		var acc_lift: float = stiffness * (t_lift - lift[i]) - damping * lift_v[i]
		acc_lift += clampf(-local_acc.y * 0.16 + local_ang.z * side * 1.3 + bounce_kick * 1.5, -28.0, 28.0)

		var acc_knee: float = stiffness * (t_knee - knee[i]) - damping * knee_v[i]
		acc_knee += clampf(local_acc.x * side * 0.15 + local_ang.x * 1.2 - bounce_kick * 0.9, -26.0, 26.0)

		var acc_twist: float = stiffness * (t_twist - twists[i]) - damping * twists_v[i]
		acc_twist += clampf(local_ang.y * 0.9 + local_ang.z * side * 0.75 + bounce_kick * side * 0.6, -24.0, 24.0)

		swing_v[i] += acc_swing * dt
		lift_v[i] += acc_lift * dt
		knee_v[i] += acc_knee * dt
		twists_v[i] += acc_twist * dt

		swing[i] = clampf(swing[i] + swing_v[i] * dt, -2.3, 2.3)
		lift[i] = clampf(lift[i] + lift_v[i] * dt, -2.0, 2.0)
		knee[i] = clampf(knee[i] + knee_v[i] * dt, -2.1, 2.1)
		twists[i] = clampf(twists[i] + twists_v[i] * dt, -1.8, 1.8)

		limbs[i] = Vector3(swing[i], lift[i], knee[i])


func _settle_body(body: Dictionary, gh: float) -> void:
	var pos: Vector3 = body["pos"] as Vector3
	var scale: float = float(body["scale"])
	var is_leg: bool = bool(body.get("is_leg", false))
	var is_part: bool = bool(body.get("is_part", false))
	var has_limbs: bool = not is_leg and not is_part and int(body.get("limb_count", 0)) > 0
	var burning: bool = bool(body.get("burning", false))
	if not is_leg and not burning and gore_enabled and blood_amount > 0.001:
		var puddle_scale: float = scale * clampf(blood_amount, 0.35, 1.6)
		if is_part:
			var pname: String = str(body.get("part_name", ""))
			puddle_scale *= (0.85 if pname == "thorax" else 0.50)
		api.creatures.add_blood_puddle(Vector3(pos.x, gh, pos.z), puddle_scale)

	while _settled.size() >= MAX_SETTLED:
		var oldest: Dictionary = _settled.pop_front() as Dictionary
		var old_node: Variant = oldest.get("node", null)
		if old_node is Node and is_instance_valid(old_node):
			(old_node as Node).queue_free()

	var base_limbs := PackedVector3Array()
	var base_twists := PackedFloat32Array()
	var severed := PackedByteArray()
	if has_limbs:
		base_limbs = (body["limbs"] as PackedVector3Array).duplicate()
		base_twists = (body["twists"] as PackedFloat32Array).duplicate()
		severed = (body["severed"] as PackedByteArray).duplicate()

	_settled.append({
		"node": body["node"],
		"is_leg": is_leg,
		"is_part": is_part,
		"limb_count": int(body.get("limb_count", base_limbs.size())),
		"com_pos": pos,
		"floor_y": gh,
		"scale": scale,
		"limbs": base_limbs,
		"twists": base_twists,
		"severed": severed,
		"curled_limbs": base_limbs.duplicate(),
		"blood": float(body.get("blood", 0.0)),
		"holes": body.get("holes", []) as Array,
		"burning": burning,
		"burn_age": float(body.get("burn_age", 0.0)),
		"flame_cd": float(body.get("flame_cd", 0.0)),
		"decay": 0.0,
		"dust_t": 0.0,
		"age": 0.0,
	})


func _step_settled(dt: float) -> void:
	var has_decay: bool = api.creatures.has_method("set_ragdoll_decay")
	var i: int = _settled.size() - 1
	while i >= 0:
		var rec: Dictionary = _settled[i] as Dictionary
		var node: Variant = rec.get("node", null)
		if not (node is MeshInstance3D) or not is_instance_valid(node):
			_settled.remove_at(i)
			i -= 1
			continue
		var age: float = float(rec["age"]) + dt
		rec["age"] = age
		var mesh_node := node as MeshInstance3D
		var floor_y: float = float(rec.get("floor_y", 0.0))
		var burning: bool = bool(rec.get("burning", false))
		if not burning and age <= CORPSE_LIFETIME:
			i -= 1  # a resting corpse that is neither burning nor decaying has nothing to step
			continue

		var decay: float = -1.0
		if burning:
			var burn_age: float = float(rec.get("burn_age", 0.0)) + dt
			rec["burn_age"] = burn_age
			var burn_level: float = clampf(burn_age / 2.2, 0.25, 1.0)
			_apply_ragdoll_burn(mesh_node, burn_level)
			var ash_t: float = clampf((burn_age - BURN_DURATION) / BURN_ASH_TIME, 0.0, 1.0)
			if burn_age > BURN_DURATION:
				decay = ash_t
			if ash_t < 1.0 and on_burn_flame.is_valid():
				var flame_cd: float = float(rec.get("flame_cd", 0.0)) - dt
				if flame_cd <= 0.0:
					var com_pos: Vector3 = rec.get("com_pos", mesh_node.position) as Vector3
					var emit_pos := Vector3(com_pos.x, maxf(com_pos.y, floor_y + 0.08), com_pos.z)
					var emit_scale: float = float(rec.get("scale", 1.0)) * (0.7 if bool(rec.get("is_part", false)) else 1.0)
					on_burn_flame.call(emit_pos, emit_scale, ash_t)
					flame_cd = _rng.randf_range(0.09, 0.14)
				rec["flame_cd"] = flame_cd
		elif age > CORPSE_LIFETIME:
			decay = clampf((age - CORPSE_LIFETIME) / CORPSE_DECAY_TIME, 0.0, 1.0)

		if decay >= 0.0:
			rec["decay"] = decay
			if decay >= 1.0:
				mesh_node.queue_free()
				_settled.remove_at(i)
			else:
				if has_decay:
					api.creatures.set_ragdoll_decay(mesh_node, decay, floor_y)
				var is_leg: bool = bool(rec.get("is_leg", false))
				var is_part: bool = bool(rec.get("is_part", false))
				var has_limbs: bool = not is_leg and not is_part and int(rec.get("limb_count", 0)) > 0
				if has_limbs:
					var base_limbs: PackedVector3Array = rec["limbs"] as PackedVector3Array
					var curled: PackedVector3Array = rec["curled_limbs"] as PackedVector3Array
					var twists: PackedFloat32Array = rec["twists"] as PackedFloat32Array
					var severed: PackedByteArray = rec["severed"] as PackedByteArray
					var limb_count: int = mini(int(rec.get("limb_count", base_limbs.size())), base_limbs.size())
					var ck: float = clampf(decay / 0.55, 0.0, 1.0)
					ck = ck * ck * (3.0 - 2.0 * ck)
					for li in limb_count:
						if li < severed.size() and severed[li] != 0:
							if li < twists.size():
								twists[li] = SEVERED_SENTINEL
							continue
						var b: Vector3 = base_limbs[li]
						curled[li] = Vector3(
							lerpf(b.x, b.x * 0.45, ck),
							lerpf(b.y, -0.75, ck),
							lerpf(b.z, 1.25, ck)
						)
					api.creatures.set_ragdoll_limbs(mesh_node, curled, twists)
				if not burning and decay > 0.45 and decay < 0.95 and on_decay_dust.is_valid():
					var dust_t: float = float(rec.get("dust_t", 0.0)) + dt
					if dust_t >= 0.45:
						dust_t = 0.0
						var com_pos: Vector3 = rec.get("com_pos", mesh_node.position) as Vector3
						on_decay_dust.call(Vector3(com_pos.x, floor_y + 0.05, com_pos.z), float(rec.get("scale", 1.0)))
					rec["dust_t"] = dust_t
		i -= 1


func _spawn_split_body(proto: String, limb_count: int, mesh_origin: Vector3, com_world: Vector3, quat: Quaternion, h_init: Vector3, dir_xz: Vector3, mass: float, radius: float, scale: float, blood: float, holes: Array, detach_want: int, was_burning := false) -> bool:
	if not api.creatures.has_method("make_ragdoll_part_node"):
		return false

	var part_active := 0
	for b in _active:
		if bool((b as Dictionary).get("is_part", false)):
			part_active += 1
	if part_active + SPLIT_PARTS.size() > MAX_SPLIT_PARTS:
		return false

	var created: Array = []
	for p in SPLIT_PARTS:
		var part_name: String = str(p)
		var pnode: MeshInstance3D = api.creatures.make_ragdoll_part_node(proto, part_name)
		if pnode == null:
			for c in created:
				var cn: Variant = (c as Dictionary).get("node", null)
				if cn is Node and is_instance_valid(cn):
					(cn as Node).queue_free()
			return false
		created.append({"part": part_name, "node": pnode})

	var is_worm: bool = _is_worm(proto)
	var is_spawner: bool = _is_spawner(proto)
	var inv_m: float = clampf(force_mul / maxf(mass, 0.35), 0.55, 1.55)
	for c in created:
		var cd: Dictionary = c as Dictionary
		var part_name: String = str(cd["part"])
		var pnode: MeshInstance3D = cd["node"] as MeshInstance3D

		var fallback_c := Vector3(0.0, 1.15 * scale, 0.0)
		var part_rad_mul := 0.50
		var part_hh_mul := 0.35
		var part_mass_mul := 0.33
		var up_lo := 4.8
		var up_hi := 7.8
		if is_spawner:
			part_rad_mul = 0.75
			part_hh_mul = 0.45
			if part_name == "head":
				fallback_c = Vector3(0.0, 0.75 * scale, -1.2 * scale)
				part_mass_mul = 0.32
				up_lo = 5.4
				up_hi = 8.4
			elif part_name == "thorax":
				fallback_c = Vector3(0.0, 0.95 * scale, 0.0)
				part_mass_mul = 0.36
				up_lo = 4.8
				up_hi = 7.6
			else:
				fallback_c = Vector3(0.0, 0.75 * scale, 1.2 * scale)
				part_mass_mul = 0.32
				up_lo = 5.2
				up_hi = 8.2
		elif is_worm:
			if part_name == "head":
				fallback_c = Vector3(0.0, 3.2 * scale, 0.0)
				part_rad_mul = 0.45
				part_hh_mul = 0.36
				part_mass_mul = 0.28
				up_lo = 5.6
				up_hi = 8.8
			elif part_name == "thorax":
				fallback_c = Vector3(0.0, 1.9 * scale, 0.0)
				part_rad_mul = 0.55
				part_hh_mul = 0.40
				part_mass_mul = 0.40
				up_lo = 4.6
				up_hi = 7.4
			else:
				fallback_c = Vector3(0.0, 0.7 * scale, 0.0)
				part_rad_mul = 0.52
				part_hh_mul = 0.38
				part_mass_mul = 0.32
				up_lo = 4.0
				up_hi = 6.8
		elif part_name == "head":
			fallback_c = Vector3(0.0, 1.12 * scale, -0.95 * scale)
			part_rad_mul = 0.42
			part_hh_mul = 0.32
			part_mass_mul = 0.25
			up_lo = 5.4
			up_hi = 8.4
		elif part_name == "thorax":
			fallback_c = Vector3(0.0, 1.22 * scale, -0.05 * scale)
			part_rad_mul = 0.55
			part_hh_mul = 0.38
			part_mass_mul = 0.42
			up_lo = 4.4
			up_hi = 7.0
		else:
			fallback_c = Vector3(0.0, 1.15 * scale, 0.85 * scale)
			part_rad_mul = 0.50
			part_hh_mul = 0.35
			part_mass_mul = 0.33
			up_lo = 5.0
			up_hi = 8.0

		var raw_c: Variant = pnode.get_meta(&"part_centroid", pnode.get_meta(&"leg_centroid", fallback_c))
		var centroid: Vector3 = raw_c as Vector3 if raw_c is Vector3 else fallback_c
		var part_world: Vector3 = mesh_origin + (quat * centroid)

		var radial: Vector3 = part_world - com_world
		radial.y = 0.0
		if radial.length_squared() > 0.001:
			radial = radial.normalized()
		else:
			var ra: float = _rng.randf_range(0.0, TAU)
			radial = Vector3(cos(ra), 0.0, sin(ra))

		var blast_dir: Vector3 = dir_xz * 0.72 + radial * 0.88 + Vector3(
			_rng.randf_range(-0.35, 0.35),
			0.0,
			_rng.randf_range(-0.35, 0.35)
		)
		if blast_dir.length_squared() > 0.001:
			blast_dir = blast_dir.normalized()
		else:
			blast_dir = dir_xz

		var h_spd: float = _rng.randf_range(4.2, 7.6) * inv_m
		var u_spd: float = _rng.randf_range(up_lo, up_hi) * inv_m
		var part_vel: Vector3 = h_init + blast_dir * h_spd + Vector3.UP * u_spd
		var spin_mag: float = _rng.randf_range(3.0, 6.2)
		var part_ang: Vector3 = Vector3.UP.cross(blast_dir) * (spin_mag * 0.65) + Vector3(
			_rng.randf_range(-2.6, 2.6),
			_rng.randf_range(-3.4, 3.4),
			_rng.randf_range(-2.6, 2.6)
		)

		var chunk_blood: float = maxf(blood, _rng.randf_range(0.86, 0.98))
		var part_holes: Array = []
		for h in holes:
			if h is Vector4:
				var hv: Vector4 = h as Vector4
				var rel := Vector3(hv.x - centroid.x, hv.y - centroid.y, hv.z - centroid.z)
				if rel.length() <= 1.25 * scale + hv.w * 2.5:
					_push_hole(part_holes, Vector4(rel.x, rel.y, rel.z, hv.w))
		# Add 1-2 blast/shrapnel tear holes directly on each split piece.
		var tear_count: int = _rng.randi_range(1, 2)
		for _ti in tear_count:
			var tear_pos := Vector3(
				_rng.randf_range(-0.26, 0.26) * scale,
				_rng.randf_range(-0.18, 0.24) * scale,
				_rng.randf_range(-0.26, 0.26) * scale
			)
			var tear_rad: float = _rng.randf_range(0.16, 0.28) * scale
			_push_hole(part_holes, Vector4(tear_pos.x, tear_pos.y, tear_pos.z, tear_rad))

		_container.add_child(pnode)
		pnode.transform = Transform3D(Basis(quat), part_world)
		_apply_ragdoll_wounds(pnode, chunk_blood, part_holes)
		if was_burning:
			_apply_ragdoll_burn(pnode, 0.25)

		_active.append({
			"node": pnode,
			"proto": proto,
			"is_leg": false,
			"is_part": true,
			"part_name": part_name,
			"pos": part_world,
			"com_local": Vector3.ZERO,
			"vel": part_vel,
			"quat": quat,
			"ang": part_ang,
			"scale": scale,
			"mass": maxf(mass * part_mass_mul, 0.18),
			"radius": clampf(radius * part_rad_mul, 0.16, 1.35),
			"half_h": clampf(part_hh_mul * scale, 0.14, 0.85),
			"age": 0.0,
			"still": 0.0,
			"grounded": false,
			"skid_cd": 0.0,
			"skid_count": 0,
			"burning": was_burning,
			"burn_age": 0.0,
			"flame_cd": 0.0,
			"blood": chunk_blood,
			"holes": part_holes.duplicate(),
		})

	var leg_base_vel: Vector3 = h_init + dir_xz * (4.8 * inv_m) + Vector3.UP * (3.6 * inv_m)
	_detach_legs(proto, detach_want, limb_count, mesh_origin, quat, leg_base_vel, mass, radius, scale, maxf(blood, 0.85), PackedFloat32Array(), PackedByteArray(), was_burning)
	return true


func _detach_legs(proto: String, detach_want: int, limb_count: int, mesh_origin: Vector3, quat: Quaternion, torso_vel: Vector3, mass: float, radius: float, scale: float, blood: float, twists: PackedFloat32Array, severed: PackedByteArray, was_burning := false) -> void:
	if detach_want <= 0 or limb_count <= 0 or not gibs_enabled or not api.creatures.has_method("make_ragdoll_leg_node"):
		return

	var clamped_limbs: int = mini(limb_count, MAX_LIMB_COUNT)
	var leg_active := 0
	for b in _active:
		if bool((b as Dictionary).get("is_leg", false)):
			leg_active += 1
	var budget: int = mini(detach_want, maxi(0, MAX_DETACHED_LEGS - leg_active))
	if budget <= 0:
		return

	var rinfo: Dictionary = api.creatures.rig_info(proto) as Dictionary
	var rlimbs: Array = rinfo.get("limbs", []) as Array
	var order: Array[int] = []
	for k in clamped_limbs:
		order.append(k)
	for k in range(clamped_limbs - 1, 0, -1):
		var swap_i: int = _rng.randi_range(0, k)
		var tmp: int = order[k]
		order[k] = order[swap_i]
		order[swap_i] = tmp

	var spawned := 0
	for li in order:
		if spawned >= budget:
			break
		var leg_node: MeshInstance3D = api.creatures.make_ragdoll_leg_node(proto, li)
		if leg_node == null:
			continue
		if li < severed.size():
			severed[li] = 1
		if li < twists.size():
			twists[li] = SEVERED_SENTINEL

		var fallback_c: Vector3
		if clamped_limbs > 6:
			var side_x: float = -0.45 if li < 6 else 0.45
			var p_idx: int = li % 6
			fallback_c = Vector3(side_x * scale, (0.95 - float(p_idx) * 0.12) * scale, (-0.8 + float(p_idx) * 0.4) * scale)
		else:
			fallback_c = Vector3(0.35 if (li % 2) == 1 else -0.35, 0.35 * scale, (-0.3 + float(li / 2) * 0.3) * scale)
		if li < rlimbs.size() and rlimbs[li] is Dictionary:
			var ld: Dictionary = rlimbs[li] as Dictionary
			if ld.has("joint") and ld["joint"] is Array:
				var j: Array = ld["joint"] as Array
				if j.size() >= 3:
					fallback_c = Vector3(float(j[0]), float(j[1]), float(j[2]))
		var raw_c: Variant = leg_node.get_meta(&"leg_centroid", fallback_c)
		var local_center: Vector3 = raw_c as Vector3 if raw_c is Vector3 else fallback_c
		var leg_world: Vector3 = mesh_origin + (quat * local_center)
		var scatter: Vector3 = Vector3(
			_rng.randf_range(-1.0, 1.0),
			_rng.randf_range(0.45, 1.35),
			_rng.randf_range(-1.0, 1.0)
		).normalized() * _rng.randf_range(3.2, 8.0)
		var leg_vel: Vector3 = torso_vel + scatter
		var leg_ang := Vector3(
			_rng.randf_range(-12.0, 12.0),
			_rng.randf_range(-12.0, 12.0),
			_rng.randf_range(-12.0, 12.0)
		)
		var leg_quat: Quaternion = quat
		var leg_blood: float = clampf(blood * 0.65, 0.22, 0.55)
		_container.add_child(leg_node)
		leg_node.transform = Transform3D(Basis(leg_quat), leg_world)
		_apply_ragdoll_wounds(leg_node, leg_blood, [])
		if was_burning:
			_apply_ragdoll_burn(leg_node, 0.25)
		_active.append({
			"node": leg_node,
			"proto": proto,
			"is_leg": true,
			"is_part": false,
			"part_name": "",
			"pos": leg_world,
			"com_local": Vector3.ZERO,
			"vel": leg_vel,
			"quat": leg_quat,
			"ang": leg_ang,
			"scale": scale * 0.5,
			"mass": maxf(mass * 0.2, 0.12),
			"radius": clampf(radius * 0.35, 0.10, 0.28),
			"half_h": clampf(0.16 * scale, 0.08, 0.28),
			"age": 0.0,
			"still": 0.0,
			"grounded": false,
			"burning": was_burning,
			"burn_age": 0.0,
			"flame_cd": 0.0,
			"blood": leg_blood,
			"holes": [],
		})
		spawned += 1


func _launch_dir(pos: Vector3, vel: Vector3, cause_pos: Variant) -> Vector3:
	if cause_pos is Vector3:
		var d: Vector3 = pos - (cause_pos as Vector3)
		d.y = 0.0
		if d.length_squared() > 0.0004:
			return d.normalized()
	var hvel := Vector3(vel.x, 0.0, vel.z)
	if hvel.length_squared() > 0.04:
		return hvel.normalized()
	var a: float = _rng.randf_range(0.0, TAU)
	return Vector3(cos(a), 0.0, sin(a))


func _compute_impulse(damage_type: String, dir_xz: Vector3, mass: float) -> Dictionary:
	var inv_m: float = force_mul / maxf(mass, 0.35)
	var side_xz := Vector3(-dir_xz.z, 0.0, dir_xz.x)
	var h_speed: float = 4.2
	var up_speed: float = 3.0
	var spin_scale: float = 2.4
	var lateral: float = _rng.randf_range(-1.2, 1.2)

	if damage_type == "explosion":
		h_speed = _rng.randf_range(7.2, 11.4)
		up_speed = _rng.randf_range(8.0, 11.6)
		spin_scale = _rng.randf_range(4.5, 8.0)
		lateral = _rng.randf_range(-2.6, 2.6)
	elif damage_type == "impact":
		h_speed = _rng.randf_range(9.4, 13.6)
		up_speed = _rng.randf_range(4.0, 6.2)
		spin_scale = _rng.randf_range(3.5, 6.8)
		lateral = _rng.randf_range(-1.4, 1.4)
	elif damage_type == "fire" or damage_type == "poison" or damage_type == "acid":
		h_speed = _rng.randf_range(0.2, 0.7)
		up_speed = _rng.randf_range(0.4, 1.0)
		spin_scale = _rng.randf_range(0.8, 2.0)
		lateral = _rng.randf_range(-0.4, 0.4)
	elif damage_type == "laser" or damage_type == "electric":
		h_speed = _rng.randf_range(1.2, 2.4)
		up_speed = _rng.randf_range(1.6, 2.8)
		spin_scale = _rng.randf_range(2.6, 5.0)
		lateral = _rng.randf_range(-1.1, 1.1)
	else:
		# physical / bullet / default: mild push with restrained spin so sprint momentum skids & thuds.
		h_speed = _rng.randf_range(1.4, 2.8)
		up_speed = _rng.randf_range(0.9, 1.9)
		spin_scale = _rng.randf_range(1.2, 2.8)

	var launch_v: Vector3 = (dir_xz * h_speed + side_xz * lateral + Vector3.UP * up_speed) * inv_m
	# Tumble axis biased perpendicular to travel direction plus restrained yaw/roll.
	var tumble_axis: Vector3 = Vector3.UP.cross(dir_xz)
	var ang_v: Vector3 = tumble_axis * (spin_scale * 0.75 * clampf(inv_m, 0.5, 1.8))
	ang_v += Vector3(
		_rng.randf_range(-spin_scale, spin_scale) * 0.40,
		_rng.randf_range(-spin_scale, spin_scale) * 0.60,
		_rng.randf_range(-spin_scale, spin_scale) * 0.40
	) * clampf(inv_m, 0.5, 1.6)

	return {"vel": launch_v, "ang": ang_v}


func _active_body_count() -> int:
	var count := 0
	for b in _active:
		var bd: Dictionary = b as Dictionary
		if bool(bd.get("is_leg", false)):
			continue
		if bool(bd.get("is_part", false)):
			if str(bd.get("part_name", "")) == "thorax":
				count += 1
		else:
			count += 1
	return count


func _apply_ragdoll_wounds(node: MeshInstance3D, blood: float, holes: Array) -> void:
	if api == null or api.get("creatures") == null or not api.creatures.has_method("set_ragdoll_wounds"):
		return
	if not gore_enabled or blood_amount <= 0.001:
		api.creatures.set_ragdoll_wounds(node, 0.0, [])
		return
	var eff: float = clampf(blood * blood_amount, 0.0, 1.0)
	var capped: Array = holes if holes.size() <= MAX_WOUND_HOLES else holes.slice(holes.size() - MAX_WOUND_HOLES)
	api.creatures.set_ragdoll_wounds(node, eff, capped)


func _apply_ragdoll_burn(node: MeshInstance3D, burn: float) -> void:
	if api == null or api.get("creatures") == null or not api.creatures.has_method("set_ragdoll_burn"):
		return
	api.creatures.set_ragdoll_burn(node, clampf(burn, 0.0, 1.0))


func _push_hole(holes: Array, hole: Vector4) -> void:
	if holes.size() >= MAX_WOUND_HOLES:
		holes.pop_front()
	holes.append(hole)


func _make_torso_hole(pos: Vector3, cause_pos: Variant, yaw: float, scale: float, damage_type: String, dmg: int, src: String, proto := "") -> Vector4:
	var incoming := Vector3.ZERO
	var has_cause: bool = false
	if cause_pos is Vector3:
		incoming = (cause_pos as Vector3) - pos
		incoming.y = 0.0
		if incoming.length_squared() > 0.0004:
			incoming = incoming.normalized()
			has_cause = true
	return _make_torso_hole_from_dir(incoming, has_cause, yaw, scale, damage_type, dmg, src, proto)


func _make_torso_hole_from_dir(incoming_world_xz: Vector3, has_cause: bool, yaw: float, scale: float, damage_type: String, dmg: int, src: String, proto := "") -> Vector4:
	var local_dir: Vector3
	if has_cause and incoming_world_xz.length_squared() > 0.0004:
		var raw_local: Vector3 = Quaternion(Vector3.UP, -yaw) * incoming_world_xz
		var jitter_ang: float = _rng.randf_range(-0.48, 0.48)
		local_dir = Quaternion(Vector3.UP, jitter_ang) * raw_local
		local_dir.y = 0.0
		if local_dir.length_squared() > 0.0004:
			local_dir = local_dir.normalized()
		else:
			local_dir = Vector3(0.0, 0.0, -1.0)
	else:
		var a: float = _rng.randf_range(0.0, TAU)
		local_dir = Vector3(cos(a), 0.0, sin(a))

	# Map onto the impact-facing side of the enemy's body shell in scaled model space.
	var lx: float
	var ly: float
	var lz: float
	if _is_worm(proto):
		lx = clampf(local_dir.x * (0.48 * scale) + _rng.randf_range(-0.14, 0.14) * scale, -0.58 * scale, 0.58 * scale)
		lz = clampf(local_dir.z * (0.48 * scale) + _rng.randf_range(-0.14, 0.14) * scale, -0.58 * scale, 0.58 * scale)
		ly = _rng.randf_range(0.65 * scale, 3.40 * scale)
	elif _is_spawner(proto):
		lx = clampf(local_dir.x * (1.35 * scale) + _rng.randf_range(-0.35, 0.35) * scale, -1.75 * scale, 1.75 * scale)
		lz = clampf(local_dir.z * (1.35 * scale) + _rng.randf_range(-0.35, 0.35) * scale, -1.75 * scale, 1.75 * scale)
		ly = _rng.randf_range(0.25 * scale, 1.45 * scale)
	else:
		lx = clampf(local_dir.x * (0.42 * scale) + _rng.randf_range(-0.14, 0.14) * scale, -0.46 * scale, 0.46 * scale)
		lz = clampf(-0.05 * scale + local_dir.z * (0.92 * scale) + _rng.randf_range(-0.26, 0.26) * scale, -1.32 * scale, 1.22 * scale)
		var ly_lo: float = 0.90 * scale if absf(lz) > 0.75 * scale else 0.98 * scale
		var ly_hi: float = 1.48 * scale if absf(lz) > 0.75 * scale else 1.70 * scale
		ly = _rng.randf_range(ly_lo, ly_hi)
	var rad: float = _hole_radius(damage_type, dmg, src, scale)
	return Vector4(lx, ly, lz, rad)


func _hole_radius(damage_type: String, dmg: int, src: String, scale: float) -> float:
	if damage_type == "explosion" or dmg >= 450 or src.contains("grenade") or src.contains("rocket") or src.contains("artillery") or src.contains("cannon"):
		return _rng.randf_range(0.20, 0.30) * scale
	if dmg >= 200 or src.contains("shotgun") or damage_type == "impact":
		return _rng.randf_range(0.15, 0.22) * scale
	if damage_type == "laser" or damage_type == "electric" or damage_type == "fire":
		return _rng.randf_range(0.12, 0.18) * scale
	return _rng.randf_range(0.11, 0.16) * scale


func _lookup_live_yaw(unit: int) -> float:
	if api == null or api.get("creatures") == null:
		return NAN
	if _clock - _last_yaw_refresh >= LIVE_YAW_REFRESH:
		_last_yaw_refresh = _clock
		_live_yaw.clear()
		for fam in ["biter", "spitter"]:
			var live: Array = api.creatures.list_live(str(fam)) as Array
			for item in live:
				var entry: Dictionary = item as Dictionary
				var proto: String = str(entry.get("name", ""))
				if not (proto.ends_with("-biter") or proto.ends_with("-spitter")):
					continue
				var u: int = int(entry.get("unit", 0))
				if u != 0:
					_live_yaw[u] = float(entry.get("yaw", 0.0))
	if _live_yaw.has(unit):
		return float(_live_yaw[unit])
	return NAN


func _clear_live_wounds() -> void:
	if api == null or api.get("creatures") == null or not api.creatures.has_method("set_unit_wounds"):
		return
	for k in _wounds:
		api.creatures.set_unit_wounds(int(k), 0.0, 0)


func _prune_stale_wounds() -> void:
	var dead_keys: Array = []
	for k in _wounds:
		var w: Dictionary = _wounds[k] as Dictionary
		if _clock - float(w.get("last_t", 0.0)) > WOUND_STALE_TIME:
			dead_keys.append(k)
	for k in dead_keys:
		_wounds.erase(k)
