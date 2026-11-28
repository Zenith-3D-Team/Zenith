extends RefCounted
## Reworked biter & spitter animations (Phase 3) for the Immersive Enemies add-on.
##
## Applies tier-weighted gait speed, smooth yaw-rate turn banking (roll), subtle acceleration/lunge
## pitch, sharper attack boost, and directional hit-flinch jolts via `api.creatures.set_unit_override`.
## Throttled cleanly and does zero work when `animations` is disabled.

const STEP_INTERVAL := 1.0 / 30.0
const MAX_ACTIVE_DIST := 52.0
const OVERRIDE_TTL := 0.16
const FLINCH_DURATION := 0.18
const STALE_UNIT_TIME := 2.0

const TIER_GAIT := {
	"small-biter": 1.25,
	"medium-biter": 1.05,
	"big-biter": 0.90,
	"behemoth-biter": 0.80,
	"small-spitter": 1.30,
	"medium-spitter": 1.12,
	"big-spitter": 0.96,
	"behemoth-spitter": 0.86,
	"small-wriggler-pentapod": 1.30,
	"medium-wriggler-pentapod": 1.10,
	"big-wriggler-pentapod": 0.92,
	"small-wriggler-pentapod-premature": 1.30,
	"medium-wriggler-pentapod-premature": 1.10,
	"big-wriggler-pentapod-premature": 0.92,
}
const TIER_BITE := {
	"small-biter": 1.25,
	"medium-biter": 1.15,
	"big-biter": 1.08,
	"behemoth-biter": 1.05,
	"small-spitter": 1.20,
	"medium-spitter": 1.15,
	"big-spitter": 1.10,
	"behemoth-spitter": 1.05,
	"small-wriggler-pentapod": 1.25,
	"medium-wriggler-pentapod": 1.15,
	"big-wriggler-pentapod": 1.08,
	"small-wriggler-pentapod-premature": 1.25,
	"medium-wriggler-pentapod-premature": 1.15,
	"big-wriggler-pentapod-premature": 1.08,
}
const TIER_FLINCH_SCALE := {
	"small-biter": 1.25,
	"medium-biter": 1.0,
	"big-biter": 0.75,
	"behemoth-biter": 0.55,
	"small-spitter": 1.35,
	"medium-spitter": 1.10,
	"big-spitter": 0.85,
	"behemoth-spitter": 0.65,
	"small-wriggler-pentapod": 1.35,
	"medium-wriggler-pentapod": 1.10,
	"big-wriggler-pentapod": 0.85,
	"small-wriggler-pentapod-premature": 1.35,
	"medium-wriggler-pentapod-premature": 1.10,
	"big-wriggler-pentapod-premature": 0.85,
}

var api
var enabled := true

var _accum := 0.0
var _clock := 0.0
## (0.1.2) Live biter/spitter prototypes seen so far (main.gd pre-cuts their ragdoll legs and parts).
var seen_protos: Dictionary = {}
var _units: Dictionary = {}  # unit: int -> tracking state dict
var _rng := RandomNumberGenerator.new()


func _init(a) -> void:
	api = a
	_rng.randomize()


func set_enabled(on: bool) -> void:
	enabled = on
	if api != null and api.get("creatures") != null:
		api.creatures.set_anim_enabled(on)
	if not on:
		_units.clear()
		_accum = 0.0


func _is_supported(proto: String) -> bool:
	return proto.ends_with("-biter") or proto.ends_with("-spitter") or proto.contains("-wriggler-pentapod")


func on_damaged(info: Dictionary) -> void:
	if not enabled or api == null:
		return
	var proto: String = str(info.get("name", ""))
	if not _is_supported(proto):
		return
	var unit: int = int(info.get("unit", 0))
	if unit == 0:
		return
	var pos: Vector3 = info.get("pos", Vector3.ZERO) as Vector3
	var cause_pos: Variant = info.get("cause_pos", null)
	var damage_type: String = str(info.get("damage_type", "physical")).to_lower()
	var dmg: int = int(info.get("dmg", 0))
	var src: String = str(info.get("src", "")).to_lower()

	var dir := Vector3.ZERO
	if cause_pos is Vector3:
		dir = pos - (cause_pos as Vector3)
		dir.y = 0.0
	if dir.length_squared() > 0.0004:
		dir = dir.normalized()
	else:
		var a: float = _rng.randf_range(0.0, TAU)
		dir = Vector3(cos(a), 0.0, sin(a))

	var strength: float = float(TIER_FLINCH_SCALE.get(proto, 1.0))
	if damage_type == "explosion" or damage_type == "impact":
		strength *= 1.35
	elif damage_type == "fire" or damage_type == "poison" or damage_type == "acid":
		strength *= 0.6
	elif dmg >= 450 or src.contains("shotgun"):
		strength *= 1.25
	elif dmg > 0 and dmg < 80:
		strength *= 0.75

	var st: Dictionary = _get_or_create(unit)
	st["flinch_t"] = FLINCH_DURATION
	st["flinch_dir"] = dir
	st["flinch_str"] = strength
	st["last_seen"] = _clock


func on_died(unit: int) -> void:
	if unit != 0:
		_units.erase(unit)


func clear() -> void:
	_units.clear()
	seen_protos.clear()
	_accum = 0.0


func dispose() -> void:
	if api != null and api.get("creatures") != null:
		api.creatures.set_anim_enabled(false)
	clear()
	api = null


func step(dt: float) -> void:
	if not enabled or api == null or dt <= 0.0:
		return
	_clock += dt
	_accum += dt
	if _accum < STEP_INTERVAL:
		return
	var step_dt: float = _accum
	_accum = 0.0

	var live: Array = []
	live.append_array(api.creatures.list_live("biter") as Array)
	live.append_array(api.creatures.list_live("spitter") as Array)
	live.append_array(api.creatures.list_live("wriggler") as Array)
	if live.is_empty():
		if not _units.is_empty():
			_prune_stale()
		return

	var focus: Vector2 = api.world.focus()
	var max_d2: float = MAX_ACTIVE_DIST * MAX_ACTIVE_DIST

	for item in live:
		var entry: Dictionary = item as Dictionary
		var proto: String = str(entry.get("name", ""))
		if not _is_supported(proto):
			continue
		if not seen_protos.has(proto):
			seen_protos[proto] = true
		var unit: int = int(entry.get("unit", 0))
		if unit == 0:
			continue
		var pos: Vector3 = entry.get("pos", Vector3.ZERO) as Vector3
		var dx: float = pos.x - focus.x
		var dz: float = pos.z - focus.y
		var st_exists: bool = _units.has(unit)
		var flinch_t: float = float((_units[unit] as Dictionary).get("flinch_t", 0.0)) if st_exists else 0.0
		if dx * dx + dz * dz > max_d2 and flinch_t <= 0.0:
			continue

		var yaw: float = float(entry.get("yaw", 0.0))
		var speed: float = float(entry.get("speed", 0.0))
		var attacking: bool = bool(entry.get("attacking", false))
		var moving: bool = speed > 0.15

		if not moving and not attacking and flinch_t <= 0.0:
			if st_exists:
				var st_idle: Dictionary = _units[unit] as Dictionary
				st_idle["prev_yaw"] = yaw
				st_idle["prev_speed"] = speed
				st_idle["roll"] = lerpf(float(st_idle["roll"]), 0.0, minf(step_dt * 10.0, 1.0))
				st_idle["pitch"] = lerpf(float(st_idle["pitch"]), 0.0, minf(step_dt * 10.0, 1.0))
				st_idle["last_seen"] = _clock
			continue

		var st: Dictionary = _get_or_create(unit)
		if not bool(st["init"]):
			st["prev_yaw"] = yaw
			st["prev_speed"] = speed
			st["init"] = true

		var dyaw: float = wrapf(yaw - float(st["prev_yaw"]), -PI, PI)
		var yaw_rate: float = dyaw / maxf(step_dt, 0.001)
		var accel: float = (speed - float(st["prev_speed"])) / maxf(step_dt, 0.001)

		var target_roll: float = clampf(-yaw_rate * 0.055 * clampf(speed * 0.3, 0.2, 1.2), -0.32, 0.32)
		var target_pitch: float = clampf(-accel * 0.018, -0.14, 0.16)
		if attacking:
			target_pitch -= 0.08
		elif moving:
			# Subtle forward lean while sprinting.
			target_pitch += clampf(-speed * 0.012, -0.10, 0.0)

		var blend: float = minf(step_dt * 12.0, 1.0)
		var roll: float = lerpf(float(st["roll"]), target_roll, blend)
		var pitch: float = lerpf(float(st["pitch"]), target_pitch, blend)

		var offset := Vector3.ZERO
		var flinch_pitch := 0.0
		var flinch_roll := 0.0
		var flinch_yaw := 0.0

		flinch_t = float(st["flinch_t"])
		if flinch_t > 0.0:
			var frac: float = clampf(flinch_t / FLINCH_DURATION, 0.0, 1.0)
			# Sharp onset, smooth decay.
			var env: float = sin(frac * PI)
			var f_dir: Vector3 = st["flinch_dir"] as Vector3
			var f_str: float = float(st["flinch_str"])
			# Convert world hit direction into biter's local forward/right frame.
			var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
			var right := Vector3(cos(yaw), 0.0, -sin(yaw))
			var fwd_dot: float = f_dir.dot(fwd)
			var right_dot: float = f_dir.dot(right)
			offset = f_dir * (0.14 * env * f_str) + Vector3(0.0, 0.06 * env * f_str, 0.0)
			flinch_pitch = -fwd_dot * 0.28 * env * f_str
			flinch_roll = -right_dot * 0.34 * env * f_str
			flinch_yaw = right_dot * 0.14 * env * f_str
			st["flinch_t"] = maxf(0.0, flinch_t - step_dt)

		st["prev_yaw"] = yaw
		st["prev_speed"] = speed
		st["roll"] = roll
		st["pitch"] = pitch
		st["last_seen"] = _clock

		var gait_mul: float = float(TIER_GAIT.get(proto, 1.0))
		var bite_mul: float = float(TIER_BITE.get(proto, 1.1)) if attacking else 1.0
		api.creatures.set_unit_override(unit, {
			"pitch": pitch + flinch_pitch,
			"roll": roll + flinch_roll,
			"yaw_offset": flinch_yaw,
			"offset": offset,
			"gait_mul": gait_mul,
			"bite_mul": bite_mul,
			"ttl": OVERRIDE_TTL,
		})

	_prune_stale()


func _get_or_create(unit: int) -> Dictionary:
	if _units.has(unit):
		return _units[unit] as Dictionary
	var st := {
		"init": false,
		"prev_yaw": 0.0,
		"prev_speed": 0.0,
		"roll": 0.0,
		"pitch": 0.0,
		"flinch_t": 0.0,
		"flinch_dir": Vector3.ZERO,
		"flinch_str": 1.0,
		"last_seen": _clock,
	}
	_units[unit] = st
	return st


func _prune_stale() -> void:
	var dead_keys: Array = []
	for k in _units:
		var st: Dictionary = _units[k] as Dictionary
		if _clock - float(st["last_seen"]) > STALE_UNIT_TIME and float(st["flinch_t"]) <= 0.0:
			dead_keys.append(k)
	for k in dead_keys:
		_units.erase(k)
