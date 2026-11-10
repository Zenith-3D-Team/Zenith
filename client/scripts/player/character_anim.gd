extends RefCounted
## The character's animations, Factorio's set and timing (base/prototypes/entity/
## character-animations.lua and the character prototype in entities.lua), posed on its skeleton
## (character_pose.gd):
##
## - idle: breathing, 22 frames at 0.15 a tick (2.4 s a breath);
## - running: legs and arms in step with the ground, one loop (two steps) per 22 frames x
##   distance_per_frame 0.13 / animation_speed 0.6 = 4.77 tiles (at running_speed 0.15 a tick
##   that's about 1.9 loops a second);
## - mining_with_tool: a pickaxe swung over the head, 26 frames at 0.9 (half a second a swing),
##   striking at frame 19;
## - running_with_gun and idle_with_gun: the gun held out towards the target while firing, at
##   the ready for a while after (ticks_to_stay_in_combat 600, ten seconds), the upper body
##   twisting towards the aim while the legs run, kicked back by each shot (kick());
## - dead: falls on its back.
##
## Layers blend in and out over a fraction of a second, so changing state never snaps.

const CharacterPose := preload("res://scripts/player/character_pose.gd")

const IDLE_LOOP := 22.0 / (0.15 * 60.0)
## Tiles walked per run loop: Factorio advances a running animation animation_speed frames per
## distance_per_frame walked (UnitPrototype's frames = distance / distance_per_frame x
## animation_speed), so 22 frames x 0.13 / 0.6 for the character and / 0.37 for the mech's run
## (leaving animation_speed out ran the cycle 1.7 times too fast, flailing).
const RUN_LOOP := 22.0 * 0.13 / 0.6
const MECH_RUN_LOOP := 22.0 * 0.13 / 0.37
const MINE_LOOP := 26.0 / (0.9 * 60.0)
const MINE_STRIKE := 19.0 / 26.0
const COMBAT_SECONDS := 10.0
const FALL_SECONDS := 0.7
## How fast layers fade in and out (1 / seconds).
const BLEND_RATE := 9.0
## The furthest the upper body twists towards the aim before the legs turn too (radians).
const MAX_TWIST := 1.25

## Inputs, set by the avatar every frame.
var running := false
var mining := false
var aiming := false  # shooting at something
var firing := false  # shots going off
var aim_twist := 0.0  # radians from where the legs face to the aim, + to the left
var dead := false
## In mech armour (Space Age's mech-armor animations): the right forearm is a gun and the left a
## claw, so no pickaxe or hand gun; a long, crouching stride; mining swings the claw.
var mech := false

## Outputs.
var pickaxe_shown := false
var gun_shown := false

var _t := 0.0
var _run_phase := 0.0
var _mine_clock := 0.0
var _combat := 0.0
var _fall := 0.0
var _w := {"run": 0.0, "mine": 0.0, "aim": 0.0, "ready": 0.0}
var _twist := 0.0
var _recoil := 0.0
var _kick := 1.0
var _kicked := false  # shots come from the bridge (`shot`); before one has, kick on a beat
var _speed := 0.0  # tiles a second along the facing, smoothed (- backwards)
var _accel := 0.0
var _gait := 0.0  # the stride's speed in RUN_SPEEDs, held and shrinking while settling
var _phase_rate := 0.0  # radians a second of the run loop while running
var _was_running := false
var _settle := 0.0  # 1 when a run stops, down to 0 over SETTLE_SECONDS


## `distance`: tiles walked this frame (+ forwards, - backwards).
func step(pose: CharacterPose, delta: float, distance: float) -> void:
	_t += delta
	var dt := maxf(delta, 0.0001)
	# The speed along the facing, smoothed over about a tenth of a second, and how it changes
	# (leaning into a start, back on stopping).
	var ks := 1.0 - exp(-dt * 10.0)
	var before := _speed
	_speed += (clampf(distance / dt, -90.0, 90.0) - _speed) * ks
	_accel += ((_speed - before) / dt - _accel) * ks
	if running and not dead:
		_gait = absf(_speed) / RUN_SPEED
	else:
		_gait = move_toward(_gait, 0.0, dt * 1.5)  # stopping: the stride shrinks as it settles
	_air_step(delta)
	var in_air := air_state != Air.GROUND
	if running and not dead and not in_air:
		var turn := distance / _loop_length() * TAU
		_run_phase = fposmod(_run_phase + turn, TAU)
		if absf(turn) > 0.00001:
			_phase_rate = turn / dt
	elif _w["run"] > 0.01:
		_settle_phase(delta)
	if _was_running and not running and _w["run"] > 0.3:
		_settle = 1.0
	_was_running = running
	_settle = maxf(0.0, _settle - delta / SETTLE_SECONDS)
	if aiming or firing:
		_combat = COMBAT_SECONDS
	else:
		_combat = maxf(0.0, _combat - delta)
	var k := 1.0 - exp(-delta * BLEND_RATE)
	# The run fades out more slowly than it comes in, while the legs carry on to a stance.
	_blend("run", 1.0 if running and not dead and not in_air else 0.0,
		k if running else 1.0 - exp(-delta * BLEND_RATE * 0.6))
	_blend("mine", 1.0 if mining and not running and not dead and not aiming else 0.0, k)
	_blend("aim", 1.0 if aiming and not dead else 0.0, k)
	_blend("ready", 1.0 if _combat > 0.0 and not aiming and not mining and not dead else 0.0, k)
	_twist = lerp_angle(_twist, clampf(aim_twist, -MAX_TWIST, MAX_TWIST) if aiming else 0.0, k)
	if _w["mine"] > 0.01:
		_mine_clock += delta
	else:
		_mine_clock = MINE_LOOP * 0.35  # start the next swing from the backswing
	_fall = move_toward(_fall, 1.0 if dead else 0.0, delta / FALL_SECONDS if dead else delta * 2.0)
	_recoil = maxf(0.0, _recoil - delta * 12.0)
	if firing and not _kicked and fmod(_t, 0.25) < delta:
		_recoil = 1.0
	pickaxe_shown = _w["mine"] > 0.3 and not mech
	gun_shown = (_w["aim"] + _w["ready"]) > 0.3 and _w["mine"] <= 0.3 and not mech

	pose.clear()
	var run: float = _w["run"]
	var action := clampf(_w["mine"] + _w["aim"] + _w["ready"], 0.0, 1.0)
	if mech:
		_mech_idle(pose, 1.0 - run, 1.0 - action)
		_run(pose, run, 1.0 - action)
		if _w["mine"] > 0.0:
			_mech_mine(pose, _w["mine"], 1.0 - run)
		if _w["aim"] + _w["ready"] > 0.0:
			_mech_gun(pose, _w["aim"], _w["ready"])
	else:
		_idle(pose, 1.0 - run, 1.0 - action)
		_run(pose, run, 1.0 - action)
		if _w["mine"] > 0.0:
			_mine(pose, _w["mine"], 1.0 - run)
		if _w["aim"] > 0.0:
			_gun(pose, _w["aim"], true)
		if _w["ready"] > 0.0:
			_gun(pose, _w["ready"], false)
	if _settle > 0.0:
		# Stopping: a dip at the knees as the body's way is taken, then up into idle.
		_crouch(pose, 0.35 * sin(PI * (1.0 - _settle)) * (1.0 - air_weight()), 1.0)
	_fly(pose)
	pose.root_offset.y += flight_height * _lift
	if _fall > 0.0:
		_die(pose, _fall)
	pose.compute()


func _blend(layer: String, goal: float, k: float) -> void:
	var v: float = _w[layer]
	v += (goal - v) * k
	_w[layer] = 0.0 if v < 0.002 else v


## `body`: weight of the whole pose; `upper`: of the arms, spine and head (less while another
## layer uses them).
func _idle(pose: CharacterPose, body: float, upper: float) -> void:
	var b := sin(_t / IDLE_LOOP * TAU)
	var u := body * upper
	pose.root_offset.y += 0.006 * b * body
	pose.add("spine", Vector3(0.015 * b - 0.02, 0.0, 0.0), u)
	pose.add("head", Vector3(-0.02 * b, 0.03 * sin(_t / IDLE_LOOP * PI), 0.0), u)
	pose.add("upper_arm_r", Vector3(0.04, 0.0, 0.05 + 0.025 * b), u)
	pose.add("upper_arm_l", Vector3(0.04, 0.0, -0.05 - 0.025 * b), u)
	pose.add("forearm_r", Vector3(0.15 + 0.03 * b, 0.0, 0.0), u)
	pose.add("forearm_l", Vector3(0.15 + 0.03 * b, 0.0, 0.0), u)
	pose.add("shin_r", Vector3(-0.05, 0.0, 0.0), body)
	pose.add("thigh_r", Vector3(0.05, 0.0, 0.0), body)
	pose.add("shin_l", Vector3(-0.05, 0.0, 0.0), body)
	pose.add("thigh_l", Vector3(0.05, 0.0, 0.0), body)


# --- Running: a planted-foot gait -------------------------------------------------------------
# Factorio's run is drawn from a 22-frame sheet stepped by distance (RUN_LOOP); seen up close in
# 3D a fixed sine on each joint slid the feet over the ground and never put one down. Here each leg
# runs a stance and a swing: in stance its foot stays where it touched down (the leg worked out by
# two-bone IK, so the foot is fixed on the ground while the body passes over it), in swing the
# joints follow keyframes (heel up behind, knee driven forward, the shin reaching out and pawing
# back before it lands). Hips drop over the stance foot and rise in the flight between steps, roll
# and sway over it and twist with the legs; the shoulders turn against them, the arms follow the
# legs a little late and the head stays level. The stance is as long as the leg can reach, so the
# share of the loop a foot is down (the duty factor) falls as the stride grows: a sprint at
# Factorio's 9 tiles a second has each foot down about a seventh of the loop, as a sprinter's.

## The body's height, lean and the leg's reach per look (tiles and radians): `drop` hips lowered
## at touch-down, `squash` more over the stance foot, `rise` in the flight between steps, `thigh`
## and `knee` the swing's peak (forward thigh, knee bend), `lean` forward at full speed, `arm` arm
## swing per thigh swing, `twist`/`shoulders` pelvis turn and the shoulders' turn against it,
## `roll`/`sway` the hip dropping and the body shifting over the stance foot, `centre` where the
## stance is centred ahead of the hip.
const PLAIN_GAIT := {"loop": RUN_LOOP, "drop": 0.1, "squash": 0.05, "rise": 0.035, "thigh": 1.0, "knee": 2.05,
	"lean": 0.16, "arm": 1.25, "twist": 0.14, "shoulders": 0.22, "roll": 0.05, "sway": 0.022, "centre": 0.04}
## The mech: the crouching stride fitted to mech-run (hips about 0.2 tiles down, legs nearly straight
## at the ends of a stride), heavier: less heel kick, little arm swing (the right arm is the gun).
const MECH_GAIT := {"loop": MECH_RUN_LOOP, "drop": 0.17, "squash": 0.06, "rise": 0.03, "thigh": 0.8, "knee": 1.25,
	"lean": 0.24, "arm": 0.55, "twist": 0.1, "shoulders": 0.12, "roll": 0.035, "sway": 0.04, "centre": 0.08}
## Factorio's running_speed, tiles a second: the speed the loop lengths above are for.
const RUN_SPEED := 0.15 * 60.0
## Faster than RUN_SPEED (exoskeletons) the cadence grows with the square root of the speed and the
## stride takes the rest, as a runner's does, instead of the legs spinning in step with the distance
## (at the owner's 0.714 tiles a tick that was 18 steps a second). Capped, so a very fast character
## leaps rather than blurs. Slower (starting off) the steps shorten more than they slow. At
## RUN_SPEED the loop is Factorio's own, so its timing is unchanged where its sprites were drawn.
const CADENCE_MAX := 2.0
const CADENCE_MIN := 0.55
## The shortest and longest share of the loop a foot is planted.
const DUTY_MIN := 0.07
const DUTY_MAX := 0.42
## Stopping: the legs carry on to the next stance and the body settles into idle over this long.
const SETTLE_SECONDS := 0.45

var _geo := {}
var _geo_pose: CharacterPose = null
var _duty := 0.2


## The legs' lengths and rest angles from the rig (Wube's character and the mech differ).
func _geometry(pose: CharacterPose) -> Dictionary:
	if pose == _geo_pose and not _geo.is_empty():
		return _geo
	_geo_pose = pose
	_geo = {}
	for side in ["_r", "_l"]:
		var hip := pose.head_of("thigh" + side)
		var knee := pose.tail_of("thigh" + side)
		var foot := pose.tail_of("shin" + side)
		_geo["l1"] = Vector2(knee.z - hip.z, knee.y - hip.y).length()
		_geo["l2"] = Vector2(foot.z - knee.z, foot.y - knee.y).length()
		_geo["a_t" + side] = atan2(-(knee.z - hip.z), hip.y - knee.y)
		_geo["a_s" + side] = atan2(-(foot.z - knee.z), knee.y - foot.y)
		_geo["hip"] = hip.y
		_geo["foot"] = foot.y
	return _geo


## Two-bone IK in the leg's plane: the foot `x` ahead of the hip (tiles) and `y` above it (so
## negative). Returns the thigh's and shin's angles from straight down, forward positive.
static func leg_ik(l1: float, l2: float, x: float, y: float) -> Vector2:
	var r := clampf(Vector2(x, y).length(), absf(l1 - l2) + 0.01, (l1 + l2) * 0.999)
	var alpha := atan2(x, -y)
	var beta := acos(clampf((l1 * l1 + r * r - l2 * l2) / (2.0 * l1 * r), -1.0, 1.0))
	var inner := acos(clampf((l1 * l1 + l2 * l2 - r * r) / (2.0 * l1 * l2), -1.0, 1.0))
	var thigh := alpha + beta
	return Vector2(thigh, thigh - (PI - inner))


## Hermite curve through keys [[s, value], ...] (s rising from 0 to 1).
static func curve(keys: Array, s: float) -> float:
	var n := keys.size()
	var i := 0
	while i < n - 2 and s > float(keys[i + 1][0]):
		i += 1
	var t0 := float(keys[i][0])
	var t1 := float(keys[i + 1][0])
	var v0 := float(keys[i][1])
	var v1 := float(keys[i + 1][1])
	var h := maxf(t1 - t0, 0.0001)
	var m0 := v1 - v0
	if i > 0:
		m0 = (v1 - float(keys[i - 1][1])) / (t1 - float(keys[i - 1][0])) * h
	var m1 := v1 - v0
	if i + 2 < n:
		m1 = (float(keys[i + 2][1]) - v0) / (float(keys[i + 2][0]) - t0) * h
	var f := clampf((s - t0) / h, 0.0, 1.0)
	var f2 := f * f
	var f3 := f2 * f
	return (2.0 * f3 - 3.0 * f2 + 1.0) * v0 + (f3 - 2.0 * f2 + f) * m0 + (-2.0 * f3 + 3.0 * f2) * v1 + (f3 - f2) * m1


## Tiles a loop at the gait's speed (`_gait`, 1 at RUN_SPEED): Factorio's loop at its own speed.
func _loop_length() -> float:
	var base: float = MECH_GAIT["loop"] if mech else PLAIN_GAIT["loop"]
	var f := maxf(_gait, 0.05)
	return base * f / clampf(sqrt(f), CADENCE_MIN, CADENCE_MAX)


## One frame of the gait's numbers, shared by both legs and the upper body.
class Gait:
	var g := 1.0  # intensity: 0 standing .. 1 at running speed (more with exoskeletons)
	var duty := 0.2
	var stride := 0.6  # tiles a foot travels under the hip while planted
	var centre := 0.04
	var drop := 0.0
	var hip := 0.82
	var foot := 0.08
	var l1 := 0.35
	var l2 := 0.39
	var td := Vector2.ZERO  # thigh and shin at touch-down
	var off := Vector2.ZERO  # and at toe-off
	var thigh_keys := []
	var bend_keys := []


func _gait_now(pose: CharacterPose) -> Gait:
	var P: Dictionary = MECH_GAIT if mech else PLAIN_GAIT
	var geo := _geometry(pose)
	var q := Gait.new()
	q.l1 = geo["l1"]
	q.l2 = geo["l2"]
	q.hip = geo["hip"]
	q.foot = geo["foot"]
	q.centre = P["centre"]
	q.g = clampf(_gait, 0.0, 1.6)
	var g1 := minf(q.g, 1.0)
	var back := _speed < -0.5
	q.drop = float(P["drop"]) * clampf(q.g * 1.5, 0.3, 1.0)
	var height := q.hip - q.drop - q.foot
	var reach := (q.l1 + q.l2) * 0.96
	var half := sqrt(maxf(reach * reach - height * height, 0.0025))
	var stride_max := 2.0 * maxf(half - q.centre, 0.05)
	var loop := _loop_length()
	q.duty = clampf(stride_max / loop, DUTY_MIN, DUTY_MAX)
	q.stride = minf(stride_max, q.duty * loop)
	_duty = q.duty
	q.td = leg_ik(q.l1, q.l2, q.centre + q.stride * 0.5, q.foot - (q.hip - q.drop))
	q.off = leg_ik(q.l1, q.l2, q.centre - q.stride * 0.5, q.foot - (q.hip - q.drop))
	var td_bend := q.td.x - q.td.y
	var off_bend := q.off.x - q.off.y
	var reach_k := g1 * (0.55 if back else 1.0)
	var peak := lerpf(q.td.x, float(P["thigh"]) * (1.0 + 0.12 * maxf(q.g - 1.0, 0.0)), reach_k)
	var knee := lerpf(td_bend + 0.25, float(P["knee"]) * (0.6 if back else 1.0), g1)
	q.thigh_keys = [[0.0, q.off.x], [0.3, lerpf(q.off.x, peak, 0.5)], [0.68, peak], [1.0, q.td.x]]
	q.bend_keys = [[0.0, off_bend], [0.3, knee], [0.62, lerpf(td_bend, knee, 0.45)], [0.86, td_bend * 0.5 + 0.04], [1.0, td_bend]]
	return q


## How far the stance compresses (x, 0..1, most mid-stance) and the flight's arc (y, 0..1) at loop
## position `u` of the right leg (either leg's stance counts).
func _bounce(q: Gait, u: float) -> Vector2:
	var h := fposmod(u, 0.5)
	if h < q.duty:
		return Vector2(sin(PI * h / q.duty), 0.0)
	return Vector2(0.0, sin(PI * (h - q.duty) / (0.5 - q.duty)))


## One leg at loop position `u` (0 at its touch-down): thigh and shin angles from straight down.
func _leg(q: Gait, u: float, body_y: float) -> Vector2:
	u = fposmod(u, 1.0)
	if u < q.duty:
		var s := u / q.duty
		return leg_ik(q.l1, q.l2, q.centre + q.stride * (0.5 - s), q.foot - (q.hip + body_y))
	var sw := (u - q.duty) / (1.0 - q.duty)
	var thigh := curve(q.thigh_keys, sw)
	return Vector2(thigh, thigh - curve(q.bend_keys, sw))


func _body_y(q: Gait, u: float) -> float:
	var P: Dictionary = MECH_GAIT if mech else PLAIN_GAIT
	var b := _bounce(q, u)
	var g1 := minf(q.g, 1.0)
	return -q.drop - float(P["squash"]) * b.x * g1 + float(P["rise"]) * b.y * g1


func _run(pose: CharacterPose, w: float, upper: float) -> void:
	if w <= 0.0 or not pose.index.has("thigh_r"):
		return
	var P: Dictionary = MECH_GAIT if mech else PLAIN_GAIT
	var q := _gait_now(pose)
	var geo := _geo
	var u := _run_phase / TAU
	var by := _body_y(q, u)
	var legs := {"_r": _leg(q, u, by), "_l": _leg(q, u + 0.5, by)}
	for side in legs:
		var a: Vector2 = legs[side]
		var thigh_turn: float = a.x - float(geo["a_t" + side])
		pose.add("thigh" + side, Vector3(thigh_turn, 0.0, 0.0), w)
		pose.add("shin" + side, Vector3(a.y - float(geo["a_s" + side]) - thigh_turn, 0.0, 0.0), w)
	var b := _bounce(q, u)
	var g1 := minf(q.g, 1.0)
	# Which foot carries the body: + right, - left.
	var right_down := fposmod(u, 1.0) < 0.5
	var stance := b.x * (1.0 if right_down else -1.0)
	pose.root_offset.y += by * w
	pose.root_offset.x += float(P["sway"]) * stance * g1 * w
	# The legs a moment ago, which the arms and shoulders follow (follow-through).
	var lag_r := _leg(q, u - 0.07, by)
	var lag_l := _leg(q, u + 0.43, by)
	var r_leg: Vector2 = legs["_r"]
	var l_leg: Vector2 = legs["_l"]
	var swing := (r_leg.x - l_leg.x) * 0.5  # + while the right leg is forward
	var swing_late := (lag_r.x - lag_l.x) * 0.5
	var pelvis := float(P["twist"]) * swing * g1
	var roll := float(P["roll"]) * stance * g1  # the swing leg's hip drops
	pose.add("root", Vector3(0.0, pelvis, roll), w)
	var u_w := w * upper
	var lean := float(P["lean"]) * g1 + clampf(_accel * 0.012, -0.1, 0.16)
	if _speed < -0.5:
		lean = -0.05 * g1  # running backwards (shooting): upright, a little back
	var shoulders := -pelvis - float(P["shoulders"]) * swing_late * g1
	pose.add("spine", Vector3(-lean, 0.0, -roll * 0.8), w)
	pose.add("spine", Vector3(0.0, shoulders, 0.0), u_w)
	# The head looks where it goes: it takes out the trunk's turn and most of its lean.
	pose.add("head", Vector3(lean * 0.75, -(pelvis + shoulders * upper) * 0.9, -roll * 0.2), w)
	var arm := -swing_late * float(P["arm"]) / 0.7  # the right arm comes forward with the left leg
	if mech:
		pose.add("upper_arm_r", Vector3(0.5, 0.0, 0.0), u_w)
		pose.add("forearm_r", Vector3(-0.3, 0.0, 0.0), u_w)
		pose.add("upper_arm_l", Vector3(-0.2 - arm * 0.6, 0.0, -0.05), u_w)
		pose.add("forearm_l", Vector3(0.5 + 0.2 * maxf(-arm, 0.0), 0.0, 0.0), u_w)
		return
	# Elbows bent; each forearm folds in further as its arm comes forward, a beat later.
	var late_r := _leg(q, u - 0.14, by)
	var late_l := _leg(q, u + 0.36, by)
	var late := -(late_r.x - late_l.x) * 0.5 / 0.7
	pose.add("upper_arm_r", Vector3(-0.3 + 0.75 * arm * g1, 0.0, 0.14), u_w)
	pose.add("upper_arm_l", Vector3(-0.3 - 0.75 * arm * g1, 0.0, -0.14), u_w)
	pose.add("forearm_r", Vector3(1.2 + (0.45 * maxf(late, 0.0) + 0.1) * g1, 0.0, 0.0), u_w)
	pose.add("forearm_l", Vector3(1.2 + (0.45 * maxf(-late, 0.0) + 0.1) * g1, 0.0, 0.0), u_w)


## Stopped: the legs carry on to the next mid-stance (one foot under the body) instead of freezing
## mid-stride, slowing as they go, while the run layer fades into idle.
func _settle_phase(delta: float) -> void:
	var u := _run_phase / TAU
	var dir := 1.0 if _phase_rate >= 0.0 else -1.0
	var best := INF
	for target in [_duty * 0.5, _duty * 0.5 + 0.5]:
		best = minf(best, fposmod((float(target) - u) * dir, 1.0))
	if best < 0.002 or best > 0.6:
		return
	var step := minf(best, absf(_phase_rate) / TAU * 0.6 * delta)
	_run_phase = fposmod(_run_phase + dir * step * TAU, TAU)


# --- Flight (Space Age's mech armour) ---------------------------------------------------------
# mech-armor-animations.lua: take_off (mech-uplift) and landing (mech-descend) are 16 frames at
# 0.6 a tick, 0.44 s each; in the air idle_with_gun_in_air (5 frames at 0.2, a 0.42 s shake), used
# moving or not; smoke_in_air puffs from the feet. Drawn here: take-off as a crouch, then the
# thrust (the body lifting to the height the mod sends) with the legs tucking; hovering with a
# slow bob, the legs hanging and small balancing motions; flying along leaning into the way it
# goes, the legs trailing; landing with the legs reaching down and bending to take the touch-down.

const TAKE_OFF := 16.0 / (0.6 * 60.0)
const LANDING := 16.0 / (0.6 * 60.0)
const AIR_SHAKE := 5.0 / (0.2 * 60.0)
const HOVER_BOB := 1.8
enum Air { GROUND, TAKE_OFF, AIR, LANDING }

## Inputs: the mod's `fl` and the height (tiles, already smoothed by the avatar), and whether the
## mod's height is coming down. In Factorio 2.1 (measured) the height climbs 1/32 tile a tick to
## about 1, comes down 3/64 a tick once over land, and `is_flying` stays true until it is 0: so the
## landing starts from the height falling (below LAND_FROM), not from `fl` going.
var flying := false
var flight_height := 0.0
var descending := false
const LAND_FROM := 0.55
## Output: how hard the feet's thrusters burn (0..1), for the smoke.
var thrust := 0.0
var air_state := Air.GROUND
var _air_t := 0.0
## The body lift let through (0..1): held back for the crouch before the thrust.
var _lift := 0.0


func _air_step(delta: float) -> void:
	_air_t += delta
	match air_state:
		Air.GROUND:
			if flying and not descending and not dead:
				air_state = Air.TAKE_OFF
				_air_t = 0.0
		Air.TAKE_OFF:
			if not flying:
				air_state = Air.LANDING
				_air_t = LANDING * (1.0 - minf(_air_t / TAKE_OFF, 1.0)) * 0.5
			elif _air_t >= TAKE_OFF:
				air_state = Air.AIR
		Air.AIR:
			if not flying or (descending and flight_height < LAND_FROM):
				air_state = Air.LANDING
				_air_t = 0.0
		Air.LANDING:
			if flying and not descending and _air_t < LANDING * 0.5:
				air_state = Air.TAKE_OFF
				_air_t = TAKE_OFF * 0.4
			elif _air_t >= LANDING:
				air_state = Air.GROUND
	var k := _air_t / (TAKE_OFF if air_state == Air.TAKE_OFF else LANDING)
	match air_state:
		Air.GROUND:
			_lift = 0.0
			thrust = 0.0
		Air.TAKE_OFF:
			_lift = smoothstep(0.3, 0.8, k)
			thrust = smoothstep(0.25, 0.4, k)
		Air.AIR:
			_lift = 1.0
			thrust = 0.6 + 0.3 * clampf(absf(_speed) / RUN_SPEED, 0.0, 1.0)
		Air.LANDING:
			_lift = 1.0 - smoothstep(0.15, 0.5, k)
			thrust = 0.7 * (1.0 - smoothstep(0.35, 0.6, k))


## How much of the air pose shows (0 on the ground, 1 hovering).
func air_weight() -> float:
	match air_state:
		Air.TAKE_OFF:
			return smoothstep(0.35, 1.0, _air_t / TAKE_OFF)
		Air.AIR:
			return 1.0
		Air.LANDING:
			return 1.0 - smoothstep(0.0, 0.5, _air_t / LANDING)
	return 0.0


func _fly(pose: CharacterPose) -> void:
	if air_state == Air.GROUND or not pose.index.has("thigh_r"):
		return
	var a := air_weight()
	var geo := _geometry(pose)
	# Moving in the air: + forwards, in running speeds.
	var m := clampf(_speed / RUN_SPEED, -1.5, 1.5)
	var fwd := maxf(m, 0.0)
	# Hanging legs, the left a little behind; trailing back as it flies along.
	pose.add("thigh_r", Vector3(0.38 - 0.45 * fwd, 0.0, 0.06), a)
	pose.add("shin_r", Vector3(-0.7 - 0.35 * fwd, 0.0, 0.0), a)
	pose.add("thigh_l", Vector3(0.18 - 0.5 * fwd, 0.0, -0.06), a)
	pose.add("shin_l", Vector3(-0.5 - 0.45 * fwd, 0.0, 0.0), a)
	var shake := sin(_t / AIR_SHAKE * TAU)
	var bob := sin(_t / HOVER_BOB * TAU)
	pose.root_offset.y += (0.05 * bob + 0.008 * shake) * a
	# Balancing: the arms out a little, the trunk rocking slowly.
	pose.add("root", Vector3(0.0, 0.0, 0.04 * sin(_t * 1.7)), a)
	pose.add("spine", Vector3(0.03 * sin(_t * 2.3) - 0.06, 0.0, -0.03 * sin(_t * 1.7)), a)
	pose.add("upper_arm_l", Vector3(0.1, 0.0, -0.25), a)
	pose.add("upper_arm_r", Vector3(0.05, 0.0, 0.12), a)
	# Leaning into the way it flies (back when it flies backwards), about the hips.
	var lean := -0.3 * m * a
	if absf(lean) > 0.0001:
		pose.body_pivot = Vector3(0.0, float(geo["hip"]), 0.0)
		pose.body_turn = Basis(Vector3.RIGHT, lean) * pose.body_turn
	if air_state == Air.TAKE_OFF:
		# Crouch, then the thrust straightens the legs before they tuck.
		var k := _air_t / TAKE_OFF
		var push := sin(PI * clampf((k - 0.3) / 0.35, 0.0, 1.0))
		_crouch(pose, sin(PI * clampf(k / 0.4, 0.0, 1.0)), 1.0)
		pose.add("spine", Vector3(0.12 * push, 0.0, 0.0), 1.0)
		pose.add("upper_arm_l", Vector3(-0.4 * push, 0.0, -0.2 * push), 1.0)
	elif air_state == Air.LANDING:
		# The legs reach down for the ground, then bend to take the landing.
		var k := _air_t / LANDING
		var reach := sin(PI * clampf(k / 0.5, 0.0, 1.0))
		pose.add("thigh_r", Vector3(0.12 * reach, 0.0, 0.0), 1.0)
		pose.add("thigh_l", Vector3(0.05 * reach, 0.0, 0.0), 1.0)
		pose.add("shin_r", Vector3(-0.1 * reach, 0.0, 0.0), 1.0)
		pose.add("shin_l", Vector3(-0.1 * reach, 0.0, 0.0), 1.0)
		_crouch(pose, sin(PI * clampf((k - 0.42) / 0.58, 0.0, 1.0)), 1.0)


## Knees bent and hips down by `c` (0..1): taking off and landing, stopping from a run.
func _crouch(pose: CharacterPose, c: float, w: float) -> void:
	if c <= 0.0:
		return
	var deep := 0.24 if mech else 0.13
	pose.root_offset.y += -deep * c * w
	pose.add("thigh_r", Vector3(0.55 * c, 0.0, 0.0), w)
	pose.add("thigh_l", Vector3(0.5 * c, 0.0, 0.0), w)
	pose.add("shin_r", Vector3(-1.1 * c, 0.0, 0.0), w)
	pose.add("shin_l", Vector3(-1.0 * c, 0.0, 0.0), w)
	pose.add("spine", Vector3(-0.22 * c, 0.0, 0.0), w)
	pose.add("head", Vector3(0.15 * c, 0.0, 0.0), w)


## Keyframes of a swing: [time 0-1, upper arm, forearm, spine lean, spine twist].
const SWING := [
	[0.0, 0.85, 0.15, -0.38, 0.12],
	[0.18, 1.05, 0.45, -0.3, 0.08],
	[0.52, 2.75, 1.55, 0.04, -0.22],
	[0.64, 2.9, 1.7, 0.06, -0.25],
	[MINE_STRIKE, 0.8, 0.1, -0.4, 0.14],
	[1.0, 0.85, 0.15, -0.38, 0.12],
]


func _mine(pose: CharacterPose, w: float, legs: float) -> void:
	var u := fposmod(_mine_clock / MINE_LOOP, 1.0)
	var k := 0
	while k < SWING.size() - 2 and u > float(SWING[k + 1][0]):
		k += 1
	var a: Array = SWING[k]
	var b: Array = SWING[k + 1]
	var f := clampf((u - float(a[0])) / maxf(float(b[0]) - float(a[0]), 0.001), 0.0, 1.0)
	f = f * f * (3.0 - 2.0 * f) if k != 3 else f * f  # the strike accelerates
	var arm := lerpf(float(a[1]), float(b[1]), f)
	var fore := lerpf(float(a[2]), float(b[2]), f)
	var lean := lerpf(float(a[3]), float(b[3]), f)
	var twist := lerpf(float(a[4]), float(b[4]), f)
	pose.add("upper_arm_r", Vector3(arm, 0.0, 0.18), w)
	pose.add("forearm_r", Vector3(fore, 0.0, 0.0), w)
	pose.add("upper_arm_l", Vector3(0.75 + 0.15 * lean, 0.0, -0.05), w)
	pose.add("forearm_l", Vector3(1.0, 0.0, 0.0), w)
	pose.add("spine", Vector3(lean, twist, 0.0), w)
	pose.add("head", Vector3(-0.1 - 0.3 * lean, -0.5 * twist, 0.0), w)
	# A wide stance, right foot forward.
	var l := w * legs
	pose.add("thigh_r", Vector3(0.38, 0.0, 0.06), l)
	pose.add("shin_r", Vector3(-0.42, 0.0, 0.0), l)
	pose.add("thigh_l", Vector3(-0.2, 0.0, -0.08), l)
	pose.add("shin_l", Vector3(-0.3, 0.0, 0.0), l)
	pose.root_offset.y += (-0.06 + 0.02 * lean) * l


## One shot going off: the gun kicks back, harder for heavy guns (`strength` about 0.5 to 1.6).
func kick(strength := 1.0) -> void:
	_kicked = true
	_recoil = 1.0
	_kick = strength


## The gun towards the target (`aimed`), or held across the chest at the ready.
func _gun(pose: CharacterPose, w: float, aimed: bool) -> void:
	var lift := 1.0 if aimed else 0.55
	var kick := 0.07 * _recoil * _kick if aimed else 0.0
	pose.add("upper_arm_r", Vector3(1.38 * lift - kick, 0.0, -0.12), w)
	pose.add("forearm_r", Vector3(0.2 + (1.0 - lift) * 1.2, 0.0, 0.0), w)
	pose.add("upper_arm_l", Vector3(1.2 * lift - kick, 0.25, 0.4), w)
	pose.add("forearm_l", Vector3(0.55 + (1.0 - lift) * 0.9, 0.0, 0.0), w)
	pose.add("spine", Vector3(-0.08 + 0.4 * kick, _twist * 0.75, 0.0), w)
	pose.add("head", Vector3(0.04, _twist * 0.25, 0.0), w)


## Falls backwards about the heels, arms flung out, and lies on its back.
func _die(pose: CharacterPose, k: float) -> void:
	var f := k * k  # gravity
	var back := 1.42 * f
	pose.body_pivot = Vector3(0.0, 0.0, 0.18)
	pose.body_turn = Basis(Vector3.RIGHT, back)
	pose.root_offset.y += 0.32 * f
	var w := clampf(k * 1.5, 0.0, 1.0)
	pose.add("upper_arm_r", Vector3(0.9, 0.0, 1.0), w)
	pose.add("upper_arm_l", Vector3(0.5, 0.0, -1.2), w)
	pose.add("forearm_r", Vector3(0.6, 0.0, 0.0), w)
	pose.add("forearm_l", Vector3(0.3, 0.0, 0.0), w)
	pose.add("thigh_r", Vector3(0.45, 0.0, 0.1), w)
	pose.add("shin_r", Vector3(-0.6, 0.0, 0.0), w)
	pose.add("thigh_l", Vector3(0.15, 0.0, -0.15), w)
	pose.add("head", Vector3(0.25, 0.4, 0.0), w)


# --- Mech armour ------------------------------------------------------------------------------
# Space Age's mech-armor animations (mech-armor-animations.lua): the same character, its run
# loop by distance as before, but a crouching stride with the legs reaching far, the gun arm
# held up in front, and mining done with the claw (27 frames at 0.45, striking at frames 10 and
# 25). Poses fitted to mech-run's frames by silhouette (8 directions): the legs straight at the
# ends of a stride and both knees bent between, the body 0.2 tiles lower and leaning forward there.

const MECH_MINE_LOOP := 27.0 / (0.45 * 60.0)
const MECH_STRIKES := [10.0 / 27.0, 25.0 / 27.0]


func _mech_idle(pose: CharacterPose, body: float, upper: float) -> void:
	var b := sin(_t / IDLE_LOOP * TAU)
	pose.root_offset.y += 0.01 * b * body
	pose.add("spine", Vector3(0.012 * b, 0.0, 0.0), body * upper)
	pose.add("upper_arm_l", Vector3(0.03 * b, 0.0, 0.0), body * upper)


func _mech_mine(pose: CharacterPose, w: float, legs: float) -> void:
	var u := fposmod(_mine_clock / MECH_MINE_LOOP, 1.0)
	# The claw rises after each strike and comes down on the next.
	var reach := 1.0
	for strike in MECH_STRIKES:
		reach = minf(reach, absf(u - float(strike)))
	reach = minf(reach, absf(u + 1.0 - float(MECH_STRIKES[0])))
	var up := smoothstep(0.0, 0.25, reach)
	pose.add("upper_arm_l", Vector3(-0.1 + 1.8 * up, 0.0, -0.3 * up), w)
	pose.add("forearm_l", Vector3(0.6 - 0.4 * up, 0.0, 0.0), w)
	pose.add("spine", Vector3(-0.25 + 0.15 * up, 0.15 * up, 0.0), w)
	var l := w * legs
	pose.add("thigh_r", Vector3(0.3, 0.0, 0.0), l)
	pose.add("shin_r", Vector3(-0.4, 0.0, 0.0), l)
	pose.add("thigh_l", Vector3(0.2, 0.0, 0.0), l)
	pose.add("shin_l", Vector3(-0.35, 0.0, 0.0), l)
	pose.root_offset.y += -0.1 * l


## The gun arm raised towards the target (`aim`), a little lower at the ready.
func _mech_gun(pose: CharacterPose, aim: float, ready: float) -> void:
	var kick := 0.06 * _recoil * aim
	pose.add("upper_arm_r", Vector3(0.3 - kick, 0.0, 0.0), aim)
	pose.add("upper_arm_r", Vector3(0.15, 0.0, 0.0), ready)
	pose.add("spine", Vector3(-0.05, _twist * 0.85, 0.0), aim)