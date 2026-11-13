extends RefCounted
## How far round each planet in a platform's sky has turned: once per its day-night cycle, as the
## game's time of day on that planet says (the bridge's `plat` `days`: ticks per day and daytime at
## tick `k`). Between the once-a-second updates it runs on at the game's measured tick rate
## (game_clock.gd), so the planet turns smoothly and stops with a paused game; each update is eased
## in rather than snapped to.
##
## turns(): 0 when the map's middle meridian (u 0.5) faces the sun (noon there), going east a full
## turn a day; space_sky.gdshader's planet_spin.

const GameClock := preload("res://scripts/world/game_clock.gd")

## Factorio 2.1's day lengths in ticks (planet.lua's surface_properties "day-night-cycle"), for a
## planet the bridge hasn't spoken of yet (the mock, an older bridge).
const DAYS := {"nauvis": 25200, "vulcanus": 5400, "fulgora": 10800, "gleba": 36000, "aquilo": 72000}
## The bridge's `plat` comes every 60 ticks.
const PERIOD := 60.0
## A correction smaller than this (turns) is eased in over about a second; a larger one is a jump in
## the game's time of day (a /c, a save loaded) and is taken at once.
const SNAP := 0.05
const EASE := 2.0
## The clouds turn this much faster than the ground.
const CLOUD_LEAD := 0.08

var clock := GameClock.new()
## name -> {day: ticks, at: daytime at tick k (turns), k: tick, frozen: bool, off: eased correction}
var _p := {}
var _cloud := {}  # name -> how far the clouds have run ahead of the ground (turns, wrapped)
var _last_tick := -1.0
var _free_tick := 0.0


## A `plat`'s `k` and `days`.
func heard(k: float, rows: Array) -> void:
	clock.heard(k, PERIOD)
	var now := clock.tick
	for r in rows:
		if not r is Array or (r as Array).size() < 3:
			continue
		var name := str(r[0])
		var day := maxf(float(r[1]), 60.0)
		var at := float(r[2]) / 100000.0
		var frozen := (r as Array).size() > 3 and int(r[3]) == 1
		var p: Dictionary = _p.get(name, {})
		if p.is_empty():
			_p[name] = {"day": day, "at": at, "k": k, "frozen": frozen, "off": 0.0}
			continue
		# A frozen time of day still turns the planet (it always turns), from where it froze.
		if frozen and bool(p["frozen"]) and is_equal_approx(float(p["day"]), day):
			continue
		var before := _turns_of(p, now) + float(p["off"])
		p["day"] = day
		p["at"] = at
		p["k"] = k
		p["frozen"] = frozen
		var jump := wrapf(before - _turns_of(p, now), -0.5, 0.5)
		p["off"] = jump if absf(jump) < SNAP else 0.0


## Once a frame: the clock and the corrections run on.
func advance(delta: float) -> void:
	clock.advance(delta)
	if clock.tick < 0.0:
		_free_tick += delta * 60.0  # no `k` yet (the mock before its first `plat`, an older bridge)
	var now := tick_now()
	var step := 0.0
	if _last_tick >= 0.0 and now >= _last_tick:
		step = minf(now - _last_tick, 600.0)
	_last_tick = now
	var fade := exp(-delta * EASE)
	for name in _p:
		var p: Dictionary = _p[name]
		p["off"] = float(p["off"]) * fade
		_cloud[name] = fposmod(float(_cloud.get(name, 0.0)) + step / float(p["day"]) * CLOUD_LEAD, 1.0)


## How far round `name` has turned (0-1), for the game's tick now. A planet not heard of turns from
## the game's tick at Factorio's day length for it (Nauvis' for one unknown).
func turns(name: String) -> float:
	if _p.has(name):
		var p: Dictionary = _p[name]
		return fposmod(_turns_of(p, clock.tick) + float(p["off"]), 1.0)
	var day := float(DAYS.get(name, DAYS["nauvis"]))
	return fposmod(tick_now() / day, 1.0)


## The game's tick as drawn, or until the bridge has said, a clock of its own at 60 a second.
func tick_now() -> float:
	return clock.tick if clock.tick >= 0.0 else _free_tick


## The clouds' turn: the ground's and a little ahead.
func cloud_turns(name: String) -> float:
	return fposmod(turns(name) + float(_cloud.get(name, 0.0)), 1.0)


## Radians, for the test and the shader's callers.
func angle(name: String) -> float:
	return turns(name) * TAU


func day_ticks(name: String) -> float:
	return float(_p[name]["day"]) if _p.has(name) else float(DAYS.get(name, DAYS["nauvis"]))


static func _turns_of(p: Dictionary, tick: float) -> float:
	return float(p["at"]) + (tick - float(p["k"])) / float(p["day"])
