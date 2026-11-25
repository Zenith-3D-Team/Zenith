extends RefCounted
## The fight's sounds Factorio plays that Zenith had none for (the combat-sounds audit's "not played"
## rows), each from the event that already reaches the client, or `atk` (combat.lua's attack cue):
## - capsule throws (`pj`: a capsule's projectile first seen): throw-projectile, and throw-grenade too
##   for grenades and cluster grenades, as the capsules' items play them;
## - combat robots: their guns from `afx` (defender-gunshot; the distractor's and destroyer's laser), at
##   most once per ROBOT_SHOT_MSEC per robot, and their working loops (fx.gd's _scan, robot_loop());
## - the nuke (`pj.e` of an atomic rocket): nuclear-explosion and its aftershock, heard as far as
##   Factorio's max_distance 1000;
## - bullet hits (`afx` of a bullet's damage): Factorio's deliver-impact sounds, bullet-impact-organic
##   on enemies, bullet-impact on the character;
## - enemies' attacks: a biter's roar (`atk`), a spitter's spit start and a behemoth's spit end (its
##   acid stream's cyclic_sound in `pj`), a worm's attack roar (its starting_attack_sound, as its acid
##   stream starts, at most once per WORM_ROAR_MSEC per worm);
## - the player's character: its heartbeat (the prototype's `heartbeat`) while under HEART_BELOW of its
##   health, and the console's player-died sound when it dies.
## The heartbeat's threshold and the robots' and worms' repeat times are chosen, not Factorio's data
## (the engine decides those). `--combat-sounds-extra=off` plays none of these.

const SoundBank := preload("res://scripts/fx/sound_bank.gd")
const Sfx := preload("res://scripts/fx/sfx.gd")
const Switches := preload("res://scripts/switches.gd")

static var on := Switches.on("--combat-sounds-extra")

const FIGHT := "base/sound/fight/"
const CREATURES := "base/sound/creatures/"
## Capsule projectile -> the sounds its throw plays (item.lua's capsule_action).
const THROWS := {
	"grenade": ["throw-projectile", "throw-grenade"],
	"cluster-grenade": ["throw-projectile", "throw-grenade"],
	"poison-capsule": ["throw-projectile"],
	"slowdown-capsule": ["throw-projectile"],
	"defender-capsule": ["throw-projectile"],
	"distractor-capsule": ["throw-projectile"],
	"destroyer-capsule": ["throw-projectile"],
	"cliff-explosives": ["throw-projectile"],
}
## Combat robot -> its gun's sound (flying-robots.lua: defender_gunshot, make_laser_sounds()).
const ROBOT_GUNS := {"defender": "defender-gunshot", "distractor": "laser", "destroyer": "laser"}
const ROBOT_LOOPS := {"defender": "defender-robot-loop.ogg", "distractor": "distractor-robot-loop.ogg",
	"destroyer": "destroyer-robot-loop.ogg"}
const ROBOT_SHOT_MSEC := 300
## Causes whose physical damage is a bullet's (Factorio's deliver_category "bullet").
const BULLET_CAUSES := ["gun-turret", "character", "defender", "car", "tank", "spidertron"]
const WORM_ROAR_MSEC := 4000
const HEART_BELOW := 0.3
## The nuke's play-sound: max_distance 1000 tiles over sfx.gd's AUDIBLE_DISTANCE.
const NUKE_REACH := 25.0

var sfx: Node = null  # sfx.gd
var _last := {}  # throttle key -> msec
var _heart := 0.0  # seconds to the next heartbeat


## Every combat sound's files decoded ahead (sfx.gd plays a file only once decoded, and its first
## ask only starts that): called on the first combat message, so they don't hold up the start's.
static func warm(files: Array) -> void:
	for prefix in [FIGHT + "throw-projectile", FIGHT + "throw-grenade", FIGHT + "defender-gunshot", FIGHT + "laser",
			FIGHT + "nuclear-explosion", "base/sound/bullets/bullet-impact-organic", "base/sound/bullets/bullet-impact",
			CREATURES + "biter-roar", CREATURES + "biter-roar-mid", CREATURES + "biter-roar-big", CREATURES + "biter-roar-behemoth",
			CREATURES + "spitter-spit-start", CREATURES + "spitter-spit-start-mid", CREATURES + "spitter-spit-start-big",
			CREATURES + "spitter-spit-start-behemoth", CREATURES + "spitter-spit-end-big", CREATURES + "worm-roar", CREATURES + "worm-roar-big"]:
		for f in SoundBank.variants(prefix):
			files.append(f)
	files.append(FIGHT + "nuclear-explosion-aftershock.ogg")
	files.append("base/sound/heartbeat.ogg")
	for f in files:
		SoundBank.stream_soon(f)


func _play(prefix: String, at: Vector3, bus: String, volume := 0.5, reach := 1.0) -> void:
	if sfx == null:
		return
	var file := SoundBank.pick(prefix)
	if file != "":
		sfx.play_at(file, at, volume, 0.05, reach, bus)


func _due(key: String, msec: int) -> bool:
	var now := Time.get_ticks_msec()
	if now - int(_last.get(key, -1000000)) < msec:
		return false
	_last[key] = now
	if _last.size() > 512:
		for k in _last.keys():
			if now - int(_last[k]) > 10000:
				_last.erase(k)
	return true


## A capsule's projectile seen for the first time at `at`: its throw.
func throw(name: String, at: Vector3) -> void:
	if not on or not THROWS.has(name):
		return
	for s: String in THROWS[name]:
		_play(FIGHT + s, at, "Weapons", 0.4)


## An acid stream first seen, `from` where it left its spitter or worm.
func stream_start(name: String, from: Vector3) -> void:
	if not on or not name.begins_with("acid-stream-"):
		return
	var size := _size(name)
	if name.begins_with("acid-stream-spitter-"):
		var start := {"small": "spitter-spit-start", "medium": "spitter-spit-start-mid", "big": "spitter-spit-start-big",
			"behemoth": "spitter-spit-start-behemoth"}
		_play(CREATURES + str(start[size]), from, "Enemies", 0.35)
	elif name.begins_with("acid-stream-worm-"):
		if _due("worm %d %d" % [roundi(from.x), roundi(from.z)], WORM_ROAR_MSEC):
			_play(CREATURES + ("worm-roar-big" if size in ["big", "behemoth"] else "worm-roar"), from, "Enemies", 0.5, 2.0)


## An acid stream that ended at `at`: the behemoth spitter's has an end_sound.
func stream_end(name: String, at: Vector3) -> void:
	if on and name == "acid-stream-spitter-behemoth":
		_play(CREATURES + "spitter-spit-end-big", at, "Enemies", 0.43)


## A projectile that ended at `at` (`pj.e`).
func projectile_end(name: String, at: Vector3) -> void:
	if not on or not name.begins_with("atomic-"):
		return
	_play(FIGHT + "nuclear-explosion", at, "Explosions", 0.9, NUKE_REACH)
	if sfx != null:
		sfx.play_at(FIGHT + "nuclear-explosion-aftershock.ogg", at, 0.4, 0.0, NUKE_REACH, "Explosions")


## `afx`: a hit on a character or a creature. `own` is the player's character's unit.
func hit(msg: Dictionary, own: int) -> void:
	if not on:
		return
	var src := str(msg.get("src", ""))
	var at := Vector3(int(msg.get("x", 0)) / 256.0, 0.6, int(msg.get("y", 0)) / 256.0)
	if ROBOT_GUNS.has(src) and msg.has("cx") and msg.has("cy"):
		var from := Vector3(int(msg["cx"]) / 256.0, 1.0, int(msg["cy"]) / 256.0)
		if _due("robot %d %d" % [roundi(from.x * 2.0), roundi(from.z * 2.0)], ROBOT_SHOT_MSEC):
			_play(FIGHT + str(ROBOT_GUNS[src]), from, "Weapons", 0.6)
	if str(msg.get("dt", "")) == "physical" and (src in BULLET_CAUSES or src.ends_with("-magazine")):
		var u := int(msg.get("u", 0))
		var character := u == 0 or u == own
		_play("base/sound/bullets/bullet-impact" + ("" if character else "-organic"), at, "Weapons", 0.5 if character else 0.3)


## `atk`: an enemy unit's melee attack landed; `name` its prototype.
func attack(name: String, at: Vector3) -> void:
	if not on or "spitter" in name:
		return
	var roar := "biter-roar"
	if "behemoth" in name:
		roar = "biter-roar-behemoth"
	elif "big" in name:
		roar = "biter-roar-big"
	elif "medium" in name:
		roar = "biter-roar-mid"
	_play(CREATURES + roar, at, "Enemies", 0.4)


## A combat robot's working loop for fx.gd's set_loops, or {} for anything else.
static func robot_loop(name: String, unit: int, at: Vector3) -> Dictionary:
	if not on or not ROBOT_LOOPS.has(name):
		return {}
	return {"key": "r%d" % unit, "pos": at, "path": FIGHT + str(ROBOT_LOOPS[name]), "volume": 0.7, "group": name, "reach": 1.0}


## Each frame: the character's heartbeat while it is badly hurt.
func character(delta: float, health: int, max_health: int, at: Vector3) -> void:
	if not on or health <= 0 or max_health <= 0 or float(health) / max_health >= HEART_BELOW:
		_heart = 0.0
		return
	_heart -= delta
	if _heart > 0.0:
		return
	var stream := SoundBank.stream_soon("base/sound/heartbeat.ogg")
	_heart = stream.get_length() if stream != null else 0.5
	if sfx != null and stream != null:
		sfx.play_at("base/sound/heartbeat.ogg", at, 0.8, 0.0, 1.0, "Effects")


## The player's character died.
func character_died() -> void:
	if on:
		Sfx.play_ui("console-player-died")


static func _size(name: String) -> String:
	for s in ["behemoth", "big", "medium", "small"]:
		if name.ends_with(s):
			return s
	return "small"
