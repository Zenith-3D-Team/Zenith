extends SceneTree
## A fight's sounds counted (sfx.gd), headless and muted: what was asked for, what played and what was
## lost (and why), per bus and per source, as the owner heard "some shots and not others, explosions
## sometimes". The Dummy audio driver still mixes, so voices end as they would in a window.
##   godot --headless --audio-driver Dummy --path client -s res://tests/combat_sound_test.gd [-- --combat-sound-limit=old]
## The fight, heard from the middle (0, 0): the character's SMG at the listener, 6 gun turrets 5-12 tiles
## away and 4 more at 25-35, 2 laser turrets, a rocket turret, biters dying (3 a second, 8-20 tiles),
## explosions (grenades, a medium and a large one), enemies' calls, bullet hits, biters' roars, grenade
## throws, the character's steps. First a cold
## second (the files not yet decoded), then FIGHT_SEC with every file decoded.
## With the install and the new limits it fails when a near shot or explosion (heard at half volume or
## more) is lost other than by Factorio's own aggregation (which Factorio drops too), or when the SMG,
## the near turrets or the explosions lose more than LOSS_MAX of their near sounds that way. Prints "COMBAT SOUND FAILS: n". Without a Factorio install: skipped (0 fails).

const Sfx := preload("res://scripts/fx/sfx.gd")
const SoundBank := preload("res://scripts/fx/sound_bank.gd")
const TestEnv := preload("res://tests/test_env.gd")

const FIGHT_SEC := 10.0
const COLD_SEC := 1.0
const LOSS_MAX := 0.1

## name, prefix, bus, shots a second, [positions], volume (play_at's default for files not defined)
var SOURCES := [
	["smg", "base/sound/fight/submachine-gunshot", "Weapons", 10.0, [Vector3(0.5, 1, 0)], 0.55],
	["near-turrets", "base/sound/fight/gun-turret-gunshot", "Weapons", 10.0,
		[Vector3(5, 1, 2), Vector3(-6, 1, 3), Vector3(7, 1, -4), Vector3(-8, 1, -6), Vector3(10, 1, 6), Vector3(-12, 1, 1)], 0.6],
	["far-turrets", "base/sound/fight/gun-turret-gunshot", "Weapons", 10.0,
		[Vector3(25, 1, 5), Vector3(-28, 1, 8), Vector3(30, 1, -10), Vector3(-35, 1, -2)], 0.6],
	["lasers", "base/sound/fight/laser-beam", "Weapons", 1.5, [Vector3(8, 1, 8), Vector3(-8, 1, 8)], 0.6],
	["rocket-turret", "space-age/sound/ammo/rocket-turret-launcher", "Weapons", 0.5, [Vector3(4, 1, -9)], 0.6],
	["biter-deaths", "base/sound/creatures/biter-death", "Enemies", 2.0, [Vector3(9, 0.5, 9), Vector3(-15, 0.5, 12), Vector3(18, 0.5, -10)], 0.6],
	["spitter-deaths", "base/sound/creatures/spitter-death", "Enemies", 1.0, [Vector3(-10, 0.5, -10), Vector3(14, 0.5, 4)], 0.6],
	["calls", "base/sound/creatures/biter-call", "Enemies", 1.0, [Vector3(20, 0.5, 15), Vector3(-18, 0.5, 18)], 0.45],
	["grenades", "base/sound/fight/medium-explosion", "Explosions", 1.0, [Vector3(6, 0.5, 6), Vector3(-7, 0.5, 5)], 0.8],
	["small-explosions", "base/sound/small-explosion", "Explosions", 1.0, [Vector3(3, 0.5, -4), Vector3(-12, 0.5, -3)], 0.8],
	["large-explosion", "base/sound/fight/large-explosion", "Explosions", 0.25, [Vector3(11, 0.5, -2)], 0.8],
	["bullet-hits", "base/sound/bullets/bullet-impact-organic", "Weapons", 10.0, [Vector3(9, 0.6, 9), Vector3(-10, 0.6, -10)], 0.3],
	["roars", "base/sound/creatures/biter-roar", "Enemies", 2.0, [Vector3(2, 0.6, 1), Vector3(-15, 0.6, 12)], 0.4],
	["throws", "base/sound/fight/throw-grenade", "Weapons", 0.5, [Vector3(0.5, 0.8, 0)], 0.4],
	["steps", "base/sound/walking/grass", "Walking", 3.0, [Vector3(0, 0, 0)], 0.5],
]

var _fails := 0
var _sfx = null
var _phase := 0  # 0 waiting for the sound rules, 1 cold, 2 decoding, 3 fight, 4 done
var _t := 0.0
var _due := {}  # source name -> seconds to its next shot
var _per := {}  # source name -> [asked, played, near asked, near lost]
var _files: Array[String] = []
var _wait := 0.0


func _check(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("FAIL: ", what)


func _initialize() -> void:
	TestEnv.isolate("combat-sound-test")
	Engine.max_fps = 60
	_sfx = Sfx.new()
	root.add_child(_sfx)
	_sfx.set_listener(Vector2.ZERO, null)
	if not SoundBank.available():
		print("skip: no Factorio install")
		print("COMBAT SOUND FAILS: 0")
		quit(0)
		return
	print("combat sound limits: ", "new" if Sfx.combat_limits else "old")


func _process(delta: float) -> bool:
	if _sfx == null or _phase == 4:
		return false
	match _phase:
		0:
			_wait += delta
			if SoundBank.ready() or _wait > 30.0:
				for src: Array in SOURCES:
					for f in SoundBank.variants(str(src[1])):
						_files.append(f)
					_check(not SoundBank.variants(str(src[1])).is_empty(), "files for " + str(src[1]))
				_start(1)
		1:
			_tick(delta)
			if _t >= COLD_SEC:
				_report("cold (files decoded on first ask)")
				_start(2)
		2:
			var left := 0
			for f in _files:
				if SoundBank.stream_soon(f) == null:
					left += 1
			_wait += delta
			if left == 0 or _wait > 30.0:
				_sfx.stop_all()
				_start(3)
		3:
			_tick(delta)
			if _t >= FIGHT_SEC:
				_report("fight, every file decoded")
				_verdict()
				_phase = 4
				print("COMBAT SOUND FAILS: %d" % _fails)
				_sfx.stop_all()
				quit(1 if _fails > 0 else 0)
	return false


func _start(phase: int) -> void:
	_phase = phase
	_t = 0.0
	_wait = 0.0
	_due.clear()
	_per.clear()
	Sfx.reset_counts()
	for src: Array in SOURCES:
		_due[src[0]] = randf() / float(src[3])
		_per[src[0]] = [0, 0, 0, 0]


func _tick(delta: float) -> void:
	_t += delta
	for src: Array in SOURCES:
		var name := str(src[0])
		_due[name] = float(_due[name]) - delta
		while float(_due[name]) <= 0.0:
			_due[name] = float(_due[name]) + 1.0 / float(src[3])
			for at: Vector3 in src[4]:
				_fire(src, at)


func _fire(src: Array, at: Vector3) -> void:
	var bus := str(src[2])
	var c: Dictionary = Sfx.counts.get(bus, {})
	var played := int(c.get("played", 0))
	var near_lost := _near_lost(c)
	var near: bool = _sfx.distance_gain(at) >= 0.5
	_sfx.play_at(SoundBank.pick(str(src[1])), at, float(src[5]), 0.05, 1.0, bus)
	c = Sfx.counts.get(bus, {})
	var p: Array = _per[src[0]]
	p[0] += 1
	p[1] += int(c.get("played", 0)) - played
	if near:
		p[2] += 1
		p[3] += _near_lost(c) - near_lost


## Near sounds lost other than by Factorio's own aggregation (which Factorio drops too).
static func _near_lost(c: Dictionary) -> int:
	var n := 0
	for k in ["near_far", "near_repeat", "near_thin", "near_undecoded", "near_novoice"]:
		n += int(c.get(k, 0))
	return n


func _report(what: String) -> void:
	print("--- %s, %.1f s ---" % [what, _t])
	for bus in Sfx.counts:
		print("  bus %s: %s" % [bus, Sfx.counts[bus]])
	for src: Array in SOURCES:
		var p: Array = _per[src[0]]
		print("  %-16s asked %4d played %4d (%3d%%)  near asked %4d near lost %4d (not by aggregation)" % [src[0], p[0], p[1],
			roundi(100.0 * p[1] / maxf(p[0], 1)), p[2], p[3]])
	print("  voices busy now: %d" % _sfx.busy_shots())


func _verdict() -> void:
	if not Sfx.combat_limits:
		return  # the old behaviour: counted, not judged
	for bus in ["Weapons", "Explosions", "Enemies"]:
		var c: Dictionary = Sfx.counts.get(bus, {})
		_check(_near_lost(c) == 0, "%s: no near sound lost but by Factorio's aggregation (%d lost: %s)" % [bus, _near_lost(c), c])
	for name in ["smg", "near-turrets", "grenades", "small-explosions", "large-explosion", "roars", "throws"]:
		var p: Array = _per[name]
		_check(p[3] <= p[2] * LOSS_MAX, "%s: %d of %d near ones lost other than by Factorio's aggregation" % [name, p[3], p[2]])
