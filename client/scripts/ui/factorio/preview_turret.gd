extends RefCounted
## Play animation on a turret in the Model packs window's preview (model_preview.gd): it does what a
## turret firing at a target does in the game, drawn by the world's own code fed what the bridge sends
## for one. A turret layer of its own (turrets.gd) gets the bridge's turret states (`ts`, every 6 ticks:
## its orientation, the shots fired since, the target) and firing cues (`tf`), and turns, raises, kicks
## and flashes the head exactly as in the world; its sprites (sprite_fx.gd) and a weapon drawing
## (weapon_fx.gd) of its own draw what it fires: the flash and hit of a bullet, the laser's, tesla's and
## railgun's beams, the flamethrower's burning stream (turrets.gd), and a rocket's or an artillery
## shell's flight and its explosion (weapon_fx.gd, from `pj` as the bridge would send for it).
##
## The target is a point fixed in the preview's world in front of the turret, about the model's size
## off (so everything stays in the picture: the railgun's beam is cut to that length too), swept a
## little side to side. A shot is reported only once the head points at it, at most once per the
## weapon's cooldown (turrets.gd's TURRETS). With the speaker on, the sounds turrets.gd and
## weapon_fx.gd play (raising, firing, folding, explosions) are heard, not placed in the world, on
## their own bus. Stopped (or another model shown) all of it is freed and the head stands as an idle
## turret's: folded, facing north (turrets.gd head_transform with no unit).

const Turrets := preload("res://scripts/world/turrets.gd")
const SpriteFx := preload("res://scripts/fx/sprite_fx.gd")
const WeaponFx := preload("res://scripts/fx/weapon_fx.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const SoundBank := preload("res://scripts/fx/sound_bank.gd")

## The preview's turret, to the turret layer.
const UNIT := 1
## The bridge's report interval for turret states (ticks).
const REPORT_TICKS := 6.0
## The sweep: turns either side of the target's line, and a sweep's length (s). Slow enough for the
## artillery's rotation_speed.
const SWEEP := 0.035
const SWEEP_SECONDS := 6.0
## Shots are reported once the head is this close to the goal (turns).
const AIMED := 0.02
## Where the target stands from the turret's middle: a direction in the preview's world (across the
## picture and away from the camera) and its distance as a share of the model's radius.
const TARGET_DIR := Vector3(0.8, 0.0, -0.6)
const TARGET_REACH := 1.0
## At least this far past the muzzle (tiles).
const TARGET_PAST := 1.5
## What flies out of a rocket and an artillery turret: the projectile's prototype and its speed at
## launch (tiles a tick; a rocket speeds up by its prototype's `acc`, weapon_fx.json). The shell is
## slower than Factorio's so its climb shows over so short a way.
const FLIGHT := {"rocket": ["rocket", 0.1], "artillery": ["artillery-projectile", 0.15]}
## Its impact and launch effects' atlases, made on workers as the turret starts.
const PREWARM := ["rocket", "artillery-projectile", "explosion", "big-artillery-explosion", "smoke-fast",
	"small-scorchmark-tintable", "medium-scorchmark-tintable"]


## The preview's speaker for the turret: what turrets.gd and weapon_fx.gd ask sfx.gd to play, heard
## while `on`, not placed.
class Speaker extends Node:
	var on := false
	## Voices started (the tests) and the last file.
	var started := 0
	var last := ""
	var _players: Array[AudioStreamPlayer] = []

	func play_at(path: String, _pos: Vector3, volume := 1.0, _pitch_spread := 0.0, _reach := 1.0, bus := "Effects", _kind := "") -> void:
		if not on or path == "" or volume <= 0.0:
			return
		var def := SoundBank.sound_for_file(path)
		var speed := 1.0
		if def != null:
			var i := def.files.find(path)
			if i >= 0:
				volume = def.volume_of(i)
			speed = def.speed()
		var s := SoundBank.stream_soon(path)
		if s == null:
			return  # decoded for next time
		var p: AudioStreamPlayer = null
		for q in _players:
			if not q.playing:
				p = q
				break
		if p == null:
			if _players.size() >= 6:
				p = _players.pop_front()
				_players.append(p)
			else:
				p = AudioStreamPlayer.new()
				add_child(p)
				_players.append(p)
		var name := StringName(bus)
		p.bus = name if AudioServer.get_bus_index(name) >= 0 else (&"Effects" if AudioServer.get_bus_index(&"Effects") >= 0 else &"Master")
		p.stream = s
		p.volume_db = linear_to_db(maxf(volume, 0.001))
		p.pitch_scale = speed
		p.play()
		started += 1
		last = path

	func hush() -> void:
		for p in _players:
			p.stop()


## What turrets.gd reads from fx.gd: its sprites and its sounds.
class Host extends Node:
	var sprites: Node
	var sfx: Node


var playing := false
## The turret layer, sprites and weapon drawing while playing (under `_fx`, in the preview's world).
var turrets: Turrets = null
var sprites: SpriteFx = null
var weapons: WeaponFx = null
var speaker: Speaker = null
## Whether the speaker is on (model_preview.gd, each frame).
var sound_on := false
var _fx: Node3D = null
var _host: Host = null
var _holder: Node3D = null
var _part: ModelLibrary.AnimPart = null
var _cfg: Dictionary = {}
var _clock := 0.0
var _report := 0.0  # ticks to the next report
var _owed := 0.0  # shots due by the cooldown, not reported yet
var _seen := 0  # shots drawn so far (TurretState.fired)
var _target := Vector3.ZERO  # in the preview's world
var _aim := Vector3.ZERO  # the target swept now
var _flyers: Array = []  # [id, prototype, at Vector2, to Vector2, speed, acceleration]
var _next_id := 1
var _tick := 0
var _first := true
## Reports sent with shots, and shots in them (the tests).
var shots_sent := 0


## The head of a turret's model (its `turret_head` part), else null.
static func head_of(model: String) -> ModelLibrary.AnimPart:
	if model == "":
		return null
	for part: ModelLibrary.AnimPart in ModelLibrary.parts_for(model):
		if part.kind == "turret_head" and part.mesh != null:
			return part
	return null


## Whether `model` is a turret this can play: a head and turrets.gd's settings for it (not a vehicle's).
static func can_play(model: String) -> bool:
	var file := ModelLibrary.file_of(model)
	if not Turrets.TURRETS.has(file) or bool(Turrets.TURRETS[file].get("vehicle", false)):
		return false
	return head_of(model) != null


## Why a turret can't sound ("" it can): its sounds are read from the install.
static func sound_reason() -> String:
	if not SoundBank.available():
		return "No Factorio install found: the sounds are read from it"
	SoundBank.prepare()
	if not SoundBank.ready():
		return "Reading Factorio's sounds..."
	return ""


## Playing (`play`) starts firing at the target from rest; else (or for a model that isn't a turret)
## everything is freed and the head stands idle. `world` is where the effects go (the preview's
## viewport, whose coordinates are the world's), `holder` the model's node.
func build(world: Node, holder: Node3D, model: String, play: bool) -> void:
	clear()
	_holder = holder
	_part = head_of(model) if can_play(model) else null
	if _part == null:
		return
	_cfg = Turrets.TURRETS[ModelLibrary.file_of(model)]
	if not play or world == null or not holder.is_inside_tree():
		_pose_idle()
		return
	playing = true
	_fx = Node3D.new()
	_fx.name = "TurretFx"
	speaker = Speaker.new()
	speaker.name = "Speaker"
	speaker.on = sound_on
	sprites = SpriteFx.new()
	sprites.name = "Sprites"
	weapons = WeaponFx.new()
	weapons.name = "Weapons"
	weapons.sprites = sprites
	weapons.sfx = speaker
	_host = Host.new()
	_host.sprites = sprites
	_host.sfx = speaker
	turrets = Turrets.new()
	turrets.name = "Turrets"
	turrets.fx = _host
	_fx.add_child(speaker)
	_fx.add_child(sprites)
	_fx.add_child(weapons)
	_fx.add_child(turrets)
	world.add_child(_fx)
	# Driven from process(), on the preview's clock (and the tests' steps), not each by itself.
	for n: Node in [sprites, weapons, turrets]:
		n.set_process(false)
	weapons.prewarm(PREWARM)
	# The turret's state as the world has it: its kind's settings, raised already if it never folds.
	var st := turrets._state(UNIT)
	st.name = ModelLibrary.file_of(model)
	st.cfg = _cfg
	if float(_cfg["prep"]) <= 0.0:
		st.fold = 1.0
	# Past the barrels' ends (a railgun's and an artillery's reach far out: a target nearer than their
	# muzzle had the beam, the stream and the shells go back through the turret).
	var muzzle: Vector3 = turrets._muzzle_point(_part, st) - _part.pivot.origin
	var reach := Vector2(muzzle.x, muzzle.z).length()
	var dist := maxf(maxf(_model_radius(holder), 1.0) * TARGET_REACH, reach + TARGET_PAST)
	turrets.railgun_length = dist + 1.0
	var base := holder.global_transform
	_target = base.origin + TARGET_DIR.normalized() * dist
	_aim = _target
	_clock = 0.0
	_report = 0.0
	_owed = 0.0
	_seen = 0
	_tick = 0
	_first = true
	shots_sent = 0


## Frees the effects and stands the head idle.
func clear() -> void:
	if _fx != null and is_instance_valid(_fx):
		if speaker != null:
			speaker.hush()
		if _fx.get_parent() != null:
			_fx.get_parent().remove_child(_fx)
		_fx.queue_free()
	if _host != null and is_instance_valid(_host):
		_host.free()  # out of the tree
	_fx = null
	_host = null
	turrets = null
	sprites = null
	weapons = null
	speaker = null
	_flyers.clear()
	if playing:
		playing = false
		_pose_idle()


## The effects' node while playing (the tests), else null.
func effects() -> Node3D:
	return _fx


## The turret's state in its layer (turrets.gd TurretState) while playing, else null.
func state():
	return turrets.state_of(UNIT) if turrets != null else null


## A frame while playing: a report when one is due, the head posed, the effects moved on.
func process(delta: float) -> void:
	if not playing or turrets == null or _holder == null or not is_instance_valid(_holder) or not _holder.is_inside_tree():
		return
	delta = minf(delta, 0.1)
	_clock += delta
	speaker.on = sound_on
	if not sound_on:
		speaker.hush()
	var base := _holder.global_transform
	var sweep := SWEEP * sin(_clock * TAU / SWEEP_SECONDS)
	_aim = base.origin + Basis(Vector3.UP, -sweep * TAU) * (_target - base.origin)
	_report -= delta * 60.0
	if _report <= 0.0:
		_report += REPORT_TICKS
		_send_report(base)
	var xf := turrets.head_transform(UNIT, _part, base, delta)
	_pose(xf)
	turrets._process(delta)
	_shots_fired()
	_fly(delta)
	weapons._process(delta)
	sprites._process(delta)


## The bridge's `ts` for the turret: first where its idle head points (north of its base), then the
## line to the target, the shots due since, the target.
func _send_report(base: Transform3D) -> void:
	var st = turrets.state_of(UNIT)
	if _first or st == null:
		_first = false
		var idle := fposmod(-base.basis.get_euler().y / TAU, 1.0)
		turrets.handle_states({"t": "ts", "l": [[UNIT, roundi(idle * 1000.0), 0, 0]]})
		return
	var goal := _orientation(_aim - base.origin)
	var shots := 0
	if absf(wrapf(goal - st.yaw, -0.5, 0.5)) < AIMED:
		_owed += REPORT_TICKS / maxf(float(_cfg.get("cooldown", 6)), 1.0)
		shots = int(_owed)
		_owed -= shots
	else:
		_owed = minf(_owed, 1.0)
	if shots > 0:
		shots_sent += shots
	turrets.handle_states({"t": "ts", "l": [[UNIT, roundi(goal * 1000.0), shots, 1, roundi(_aim.x * 256.0), roundi(_aim.z * 256.0)]]})


## Factorio's orientation (turns clockwise from north) of a direction in the world.
static func _orientation(d: Vector3) -> float:
	return fposmod(atan2(d.x, -d.z) / TAU, 1.0)


## For each shot the layer drew: the bridge's firing cue, and a rocket's or shell's flight.
func _shots_fired() -> void:
	var st = turrets.state_of(UNIT)
	if st == null:
		return
	while _seen < st.fired:
		_seen += 1
		turrets.handle_fire({"t": "tf", "u": UNIT, "x": roundi(_aim.x * 256.0), "y": roundi(_aim.z * 256.0)})
		var flight: Array = FLIGHT.get(str(_cfg.get("kind", "")), [])
		if flight.is_empty():
			continue
		var from: Vector3 = turrets._launcher_point(st)
		var rec: Dictionary = weapons.data.get("pr", {}).get(str(flight[0]), {})
		_flyers.append([_next_id, str(flight[0]), Vector2(from.x, from.z), Vector2(_aim.x, _aim.z), float(flight[1]),
			float(rec.get("acc", 0.0))])
		_next_id += 1


## The flights a tick at a time, sent as the bridge's `pj` (positions, and those that ended).
func _fly(_delta: float) -> void:
	var now := int(_clock * 60.0)
	if _flyers.is_empty():
		_tick = now
		return
	var ended: Array = []
	while _tick < now:
		_tick += 1
		for f: Array in _flyers.duplicate():
			f[4] = float(f[4]) + float(f[5])
			var at: Vector2 = f[2]
			var to: Vector2 = f[3]
			if at.distance_to(to) <= float(f[4]):
				ended.append_array([f[0], roundi(to.x * 256.0), roundi(to.y * 256.0)])
				_flyers.erase(f)
			else:
				f[2] = at.move_toward(to, float(f[4]))
	var p: Array = []
	for f: Array in _flyers:
		var at: Vector2 = f[2]
		p.append_array([f[0], f[1], roundi(at.x * 256.0), roundi(at.y * 256.0)])
	weapons.handle({"t": "pj", "k": _tick, "p": p, "e": ended})


## The head (and any copy drawing it, preview_anim.gd's for a glowing one) at `xf` in the model.
func _pose(xf: Transform3D) -> void:
	if _holder == null or not is_instance_valid(_holder):
		return
	for c in _holder.get_children():
		var mi := c as MeshInstance3D
		var mmi := c as MultiMeshInstance3D
		if (mi != null and mi.mesh == _part.mesh) or (mmi != null and mmi.multimesh != null and mmi.multimesh.mesh == _part.mesh):
			(c as Node3D).transform = xf


## An idle turret's head: folded, facing north, as the world draws a turret with no state.
func _pose_idle() -> void:
	if _part == null:
		return
	var layer := Turrets.new()
	_pose(layer.head_transform(0, _part, Transform3D.IDENTITY, 0.0))
	layer.free()


## The model's radius on the ground (its box's half diagonal across).
static func _model_radius(holder: Node3D) -> float:
	var r := 0.0
	for c in holder.get_children():
		var mi := c as MeshInstance3D
		if mi != null and mi.mesh != null:
			var b := mi.transform * mi.mesh.get_aabb()
			r = maxf(r, Vector2(b.size.x, b.size.z).length() * 0.5)
	return r
