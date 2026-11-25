extends Node
## Flamethrowers' sound as Factorio plays it: each gun's `cyclic_sound`, its begin sound once when
## it starts firing, the middle sound looped while it keeps firing, the end sound when it stops,
## from the nozzle and following it (read from the player's install, sound_bank.gd).
##
## Whoever fires calls firing() every frame while the gun fires (turrets.gd for flamethrower
## turrets and the tank's flamethrower, fx.gd for the character's); a gun not called for HOLD
## seconds has stopped. Only the MAX_HEARD loudest guns firing at once are heard, so a wall of
## flamethrower turrets doesn't stack its loops; the rest stay silent until one of those stops.
##
## Factorio's data (base/prototypes): the turret's sound_variations(..., 3, 0.5), the handheld
## flamethrower's volume 0.7, the tank's 1.0, the same start/mid/end files for the last two.
## `--flame-sound=old` keeps the earlier one-shots (the middle sound replayed every 0.9 s from a
## turret, every 0.5 s from the character, no begin or end from the character).

const SoundBank := preload("res://scripts/fx/sound_bank.gd")
const Sfx := preload("res://scripts/fx/sfx.gd")
const Switches := preload("res://scripts/switches.gd")

static var old := Switches.has("--flame-sound=old")

## Seconds without a firing() call before a gun counts as stopped (turrets.gd keeps a turret's
## flame going 0.19 s after each shot, fx.gd calls every frame).
const HOLD := 0.12
## Guns heard at once.
const MAX_HEARD := 3
## The middle loop fades in under the begin sound's tail and out under the end sound.
const LOOP_FADE_IN := 0.12
const LOOP_FADE_OUT := 0.1
## The add-on loop owner the loops are kept under in sfx.gd (not an add-on id: none can clash).
const OWNER := "zenith:flamethrower"

## What each kind of gun plays: [begin prefix, middle prefix, end prefix, volume].
const KINDS := {
	"turret": ["base/sound/fight/flamethrower-turret-start", "base/sound/fight/flamethrower-turret-mid",
		"base/sound/fight/flamethrower-turret-end", 0.5],
	"handheld": ["base/sound/fight/flamethrower-start", "base/sound/fight/flamethrower-mid",
		"base/sound/fight/flamethrower-end", 0.7],
	"tank": ["base/sound/fight/flamethrower-start", "base/sound/fight/flamethrower-mid",
		"base/sound/fight/flamethrower-end", 1.0],
}


class Gun:
	var kind := "turret"
	var at := Vector3.ZERO
	var quiet := 0.0  # seconds since the last firing()
	var heard := false  # holds one of the MAX_HEARD places
	var loop := 0  # sfx.gd's add-on loop handle (0: none)
	var loop_due := -1.0  # seconds until the middle loop starts (after the begin sound)


var _guns := {}  # key -> Gun


## `key` (a turret's unit, "hand") fires now at `at` (the nozzle, flat world as sprite_fx's cards).
func firing(key: Variant, at: Vector3, kind := "turret") -> void:
	var g: Gun = _guns.get(key)
	if g == null:
		g = Gun.new()
		g.kind = kind if KINDS.has(kind) else "turret"
		_guns[key] = g
	g.at = at
	g.quiet = 0.0


## Guns firing now (tests, the debug overlay).
func count() -> int:
	return _guns.size()


## Of those, the ones heard.
func heard() -> int:
	var n := 0
	for g: Gun in _guns.values():
		if g.heard:
			n += 1
	return n


## A new game: every loop stops at once, without end sounds.
func reset() -> void:
	var sfx = _sfx()
	for g: Gun in _guns.values():
		if g.loop > 0 and sfx != null:
			sfx.stop_addon_loop(OWNER, g.loop, 0.0)
	_guns.clear()


func _exit_tree() -> void:
	reset()


func _sfx():
	return Sfx.instance


func _process(delta: float) -> void:
	if _guns.is_empty():
		return
	var sfx = _sfx()
	# Stopped guns: the end sound, the loop faded out.
	for key in _guns.keys():
		var g: Gun = _guns[key]
		g.quiet += delta
		if g.quiet > HOLD:
			if g.heard and sfx != null:
				if g.loop > 0:
					sfx.stop_addon_loop(OWNER, g.loop, LOOP_FADE_OUT)
				sfx.play_at(SoundBank.pick(str(KINDS[g.kind][2])), g.at, float(KINDS[g.kind][3]), 0.0, 1.0, "Weapons", "", str(key) == "hand")
			_guns.erase(key)
	if sfx == null:
		return
	# The loudest MAX_HEARD keep or take a place; a gun that loses its place goes quiet.
	var order: Array = []
	for key in _guns.keys():
		var g: Gun = _guns[key]
		order.append([float(sfx.distance_gain(g.at)) * float(KINDS[g.kind][3]) * (1.2 if g.heard else 1.0), key])
	order.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) > float(b[0]))
	for i in order.size():
		var g: Gun = _guns[order[i][1]]
		var wants := i < MAX_HEARD and float(order[i][0]) > 0.0001
		if wants and not g.heard:
			g.heard = true
			var begin := SoundBank.pick(str(KINDS[g.kind][0]))
			sfx.play_at(begin, g.at, float(KINDS[g.kind][3]), 0.0, 1.0, "Weapons", "", str(order[i][1]) == "hand")
			var stream: AudioStream = SoundBank.stream_soon(begin) if begin != "" else null
			g.loop_due = maxf(0.0, stream.get_length() - LOOP_FADE_IN) if stream != null else 0.15
		elif not wants and g.heard:
			g.heard = false
			g.loop_due = -1.0
			if g.loop > 0:
				sfx.stop_addon_loop(OWNER, g.loop, LOOP_FADE_OUT)
				g.loop = 0
		if not g.heard:
			continue
		if g.loop_due >= 0.0:
			g.loop_due -= delta
			if g.loop_due < 0.0:
				var mid := SoundBank.pick(str(KINDS[g.kind][1]))
				if mid != "":
					g.loop = int(sfx.start_addon_loop(OWNER, mid, g.at, float(KINDS[g.kind][3]), 1.0, 1.0, "Weapons", LOOP_FADE_IN))
		elif g.loop > 0:
			if not bool(sfx.update_addon_loop(OWNER, g.loop, {"at": g.at})):
				g.loop = 0  # sfx stopped everything (a new game): start it again
				g.loop_due = 0.0
