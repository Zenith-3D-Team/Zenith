extends SceneTree
## The whole sound system in a busy scene, counted (sfx.gd), headless and muted: the owner heard
## footsteps, vehicles, shots and explosions dropped "across the board". The Dummy audio driver still
## mixes, so voices end as they would in a window.
##   godot --headless --audio-driver Dummy --path client -s res://tests/sound_pool_test.gd [-- --sound-pool=old]
## Heard from the player at (0, 0), who walks (own steps), fires an SMG (own gun) and drives a car (own
## vehicle loop) at once (a worst case), beside: three other walkers, a tank and two cars others drive,
## 64 machines of 9 kinds and a belt line (their working loops, activate/deactivate sounds), robots
## building, and a fight (10 gun turrets, lasers, a rocket turret, biters and spitters dying, calling and
## roaring, bullet hits, explosions, grenade throws). First a cold second (files decoded on first ask),
## then SCENE_SEC with every file decoded. Per source: asked, played, and near ones (heard at half
## volume or more) lost other than by Factorio's own aggregation; per bus the reasons (sfx.gd counts).
## With the pool (the default) it fails when an own sound is lost after decoding, the own car's loop
## isn't held every scan, or near steps, shots or explosions lose more than LOSS_MAX other than by
## aggregation. `--sound-pool=old`: counted, not judged. Prints "SOUND POOL FAILS: n". Without a
## Factorio install: skipped (0 fails).

const Sfx := preload("res://scripts/fx/sfx.gd")
const SoundBank := preload("res://scripts/fx/sound_bank.gd")
const TestEnv := preload("res://tests/test_env.gd")

const SCENE_SEC := 10.0
const COLD_SEC := 1.0
const LOSS_MAX := 0.1
const SCAN_SEC := 0.25  # fx.gd's SCAN_INTERVAL

## name, prefix, bus, plays a second, [positions], volume, own
var SOURCES := [
	["own-steps", "base/sound/walking/grass", "Walking", 3.3, [Vector3(0, 0.1, 0)], 0.5, true],
	["own-smg", "base/sound/fight/submachine-gunshot", "Weapons", 10.0, [Vector3(0.2, 1, 0)], 0.55, true],
	["other-steps", "base/sound/walking/concrete", "Walking", 3.0, [Vector3(6, 0.1, 2), Vector3(-9, 0.1, 5), Vector3(14, 0.1, -3)], 0.5, false],
	["near-turrets", "base/sound/fight/gun-turret-gunshot", "Weapons", 10.0,
		[Vector3(5, 1, 2), Vector3(-6, 1, 3), Vector3(7, 1, -4), Vector3(-8, 1, -6), Vector3(10, 1, 6), Vector3(-12, 1, 1)], 0.6, false],
	["far-turrets", "base/sound/fight/gun-turret-gunshot", "Weapons", 10.0,
		[Vector3(25, 1, 5), Vector3(-28, 1, 8), Vector3(30, 1, -10), Vector3(-35, 1, -2)], 0.6, false],
	["lasers", "base/sound/fight/laser-beam", "Weapons", 1.5, [Vector3(8, 1, 8), Vector3(-8, 1, 8)], 0.6, false],
	["rocket-turret", "space-age/sound/ammo/rocket-turret-launcher", "Weapons", 0.5, [Vector3(4, 1, -9)], 0.6, false],
	["bullet-hits", "base/sound/bullets/bullet-impact-organic", "Weapons", 6.0, [Vector3(9, 0.6, 9), Vector3(-10, 0.6, -10)], 0.3, false],
	["throws", "base/sound/fight/throw-grenade", "Weapons", 0.5, [Vector3(3, 0.8, 1)], 0.4, false],
	["biter-deaths", "base/sound/creatures/biter-death", "Enemies", 2.0, [Vector3(9, 0.5, 9), Vector3(-15, 0.5, 12), Vector3(18, 0.5, -10)], 0.6, false],
	["spitter-deaths", "base/sound/creatures/spitter-death", "Enemies", 1.0, [Vector3(-10, 0.5, -10), Vector3(14, 0.5, 4)], 0.6, false],
	["calls", "base/sound/creatures/biter-call", "Enemies", 1.0, [Vector3(20, 0.5, 15), Vector3(-18, 0.5, 18)], 0.45, false],
	["roars", "base/sound/creatures/biter-roar", "Enemies", 2.0, [Vector3(2, 0.6, 1), Vector3(-15, 0.6, 12)], 0.4, false],
	["grenades", "base/sound/fight/medium-explosion", "Explosions", 1.0, [Vector3(6, 0.5, 6), Vector3(-7, 0.5, 5)], 0.8, false],
	["small-explosions", "base/sound/small-explosion", "Explosions", 1.0, [Vector3(3, 0.5, -4), Vector3(-12, 0.5, -3)], 0.8, false],
	["large-explosion", "base/sound/fight/large-explosion", "Explosions", 0.25, [Vector3(11, 0.5, -2)], 0.8, false],
	["building", "core/sound/build-small", "Effects", 2.0, [Vector3(7, 0.5, -7), Vector3(-5, 0.5, 9)], 0.7, false],
	["deconstruct", "core/sound/deconstruct-medium", "Effects", 0.5, [Vector3(-7, 0.5, -7)], 0.7, false],
]
## Machines heard: prototype, how many, nearest and farthest (tiles); spread round the player.
const MACHINES := [
	["assembling-machine-2", 12, 4.0, 28.0], ["electric-mining-drill", 10, 6.0, 30.0], ["stone-furnace", 10, 5.0, 25.0],
	["inserter", 10, 3.0, 20.0], ["fast-inserter", 6, 3.0, 20.0], ["lab", 4, 10.0, 25.0],
	["boiler", 2, 12.0, 20.0], ["steam-engine", 4, 12.0, 22.0], ["transport-belt", 6, 2.0, 15.0],
]
## Vehicles: key, VEHICLE_SOUNDS path, position, volume, own.
const VEHICLES := [
	["vown", "base/sound/car-engine-driving.ogg", Vector3(0, 1, 0), 0.6, true],
	["vtank", "base/sound/fight/tank-engine-driving.ogg", Vector3(10, 1, 4), 0.6, false],
	["vcar2", "base/sound/car-engine-driving.ogg", Vector3(-18, 1, 6), 0.6, false],
	["vcar3", "base/sound/car-engine-driving.ogg", Vector3(16, 1, -16), 0.5, false],
]

var _fails := 0
var _sfx = null
var _phase := 0  # 0 waiting for the sound rules, 1 cold, 2 decoding, 3 scene, 4 done
var _t := 0.0
var _scan := 0.0
var _due := {}
var _per := {}  # source name -> [asked, played, near asked, near lost]
var _files: Array[String] = []
var _wait := 0.0
var _machines: Array = []  # [unit, proto, pos, Loop]
var _working := {}  # unit -> bool
var _vehicle_held := {}  # key -> [scans, held]
var _loop_kinds := {}  # group -> [scans asked, held]


func _check(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("FAIL: ", what)


func _initialize() -> void:
	TestEnv.isolate("sound-pool-test")
	Engine.max_fps = 60
	_sfx = Sfx.new()
	root.add_child(_sfx)
	_sfx.set_listener(Vector2.ZERO, null)
	if not SoundBank.available():
		print("skip: no Factorio install")
		print("SOUND POOL FAILS: 0")
		quit(0)
		return
	print("sound pool: ", "new" if Sfx.pool else "old", ", one-shot voices ", _sfx._shots.size(), ", loop voices ", _sfx._loops.size())


func _process(delta: float) -> bool:
	if _sfx == null or _phase == 4:
		return false
	match _phase:
		0:
			_wait += delta
			if SoundBank.ready() or _wait > 30.0:
				_setup()
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
				_sfx.set_loops([])
				_start(3)
		3:
			_tick(delta)
			if _t >= SCENE_SEC:
				_report("busy scene, every file decoded")
				_verdict()
				_phase = 4
				print("SOUND POOL FAILS: %d" % _fails)
				_sfx.stop_all()
				quit(1 if _fails > 0 else 0)
	return false


func _setup() -> void:
	for src: Array in SOURCES:
		var v := SoundBank.variants(str(src[1]))
		_check(not v.is_empty(), "files for " + str(src[1]))
		for f in v:
			_files.append(f)
	var unit := 1000
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for m: Array in MACHINES:
		var loop := SoundBank.working_sound(str(m[0]))
		_check(loop != null and loop.sound != null, "working sound of " + str(m[0]))
		if loop == null or loop.sound == null:
			continue
		for f in loop.sound.files:
			_files.append(f)
		for i in int(m[1]):
			unit += 1
			var a := rng.randf() * TAU
			var r := rng.randf_range(float(m[2]), float(m[3]))
			_machines.append([unit, str(m[0]), Vector3(cos(a) * r, 1.0, sin(a) * r), loop])
	for v: Array in VEHICLES:
		_files.append(str(v[1]))


func _start(phase: int) -> void:
	_phase = phase
	_t = 0.0
	_scan = 0.0
	_wait = 0.0
	_due.clear()
	_per.clear()
	_vehicle_held.clear()
	_loop_kinds.clear()
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
	_scan -= delta
	if _scan <= 0.0:
		_scan += SCAN_SEC
		_loops()


## fx.gd's _scan as it hands sfx.gd the loops: each machine's working loop (a variation per unit),
## activate/deactivate when one starts or stops (a few each scan), and the vehicles' engines.
func _loops() -> void:
	var sources: Array = []
	for m: Array in _machines:
		var unit: int = m[0]
		var loop = m[3]
		var working: bool = (unit + int(_t / 2.0)) % 5 != 0  # a fifth idle, changing every 2 s
		if _working.has(unit) and bool(_working[unit]) != working:
			var d = loop.activate if working else loop.deactivate
			if d != null:
				_sfx.play_def(d, m[2], "Environment")
		_working[unit] = working
		var def = loop.sound if working else loop.idle
		if def == null or def.files.is_empty():
			continue
		var i: int = unit % def.files.size()
		sources.append({"key": unit, "pos": m[2], "path": def.files[i], "volume": def.max_volumes[i], "reach": def.reach,
			"curve": def.attenuation, "group": m[1], "per_group": loop.max_per_prototype, "fade_in": loop.fade_in, "fade_out": loop.fade_out})
	for v: Array in VEHICLES:
		sources.append({"key": v[0], "pos": v[2], "path": v[1], "volume": v[3], "group": "car" if "car" in str(v[1]) else "tank",
			"reach": 1.0, "own": v[4]})
	_sfx.set_loops(sources)
	var held := {}
	for lv in _sfx._loops:
		if lv.key != null and lv.wanted:
			held[lv.key] = true
	for v: Array in VEHICLES:
		var h: Array = _vehicle_held.get(v[0], [0, 0])
		h[0] += 1
		h[1] += 1 if held.has(v[0]) else 0
		_vehicle_held[v[0]] = h
	for s: Dictionary in sources:
		var g := str(s["group"])
		var k: Array = _loop_kinds.get(g, [0, 0])
		k[0] += 1
		k[1] += 1 if held.has(s["key"]) else 0
		_loop_kinds[g] = k


func _fire(src: Array, at: Vector3) -> void:
	var bus := str(src[2])
	var c: Dictionary = Sfx.counts.get(bus, {})
	var played := int(c.get("played", 0))
	var near_lost := _near_lost(c)
	var near: bool = _sfx.distance_gain(at) >= 0.5
	_sfx.play_at(SoundBank.pick(str(src[1])), at, float(src[5]), 0.05, 1.0, bus, "", bool(src[6]))
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
	for key in _vehicle_held:
		var h: Array = _vehicle_held[key]
		print("  loop %-14s held %3d of %3d scans" % [key, h[1], h[0]])
	for g in _loop_kinds:
		var k: Array = _loop_kinds[g]
		print("  loops %-22s %4d of %4d source-scans held" % [g, k[1], k[0]])
	print("  voices busy now: %d one-shots, %d loops" % [_sfx.busy_shots(), _sfx.busy_loops()])


func _verdict() -> void:
	if not Sfx.pool:
		return  # the old behaviour: counted, not judged
	for name in ["own-steps", "own-smg"]:
		var p: Array = _per[name]
		_check(p[3] == 0, "%s: an own sound lost (%d of %d)" % [name, p[3], p[2]])
	var own: Array = _vehicle_held.get("vown", [0, 0])
	_check(own[0] > 0 and own[1] == own[0], "own car's loop held every scan (%d of %d)" % [own[1], own[0]])
	var tank: Array = _vehicle_held.get("vtank", [0, 0])
	_check(tank[1] == tank[0], "the near tank's loop held every scan (%d of %d)" % [tank[1], tank[0]])
	for name in ["other-steps", "near-turrets", "grenades", "small-explosions", "large-explosion", "roars", "throws", "building"]:
		var p: Array = _per[name]
		_check(p[3] <= p[2] * LOSS_MAX, "%s: %d of %d near ones lost other than by Factorio's aggregation" % [name, p[3], p[2]])
