extends RefCounted
## api.weather (1.8): client-only atmosphere, sky, cloud, lighting mood, wind, and surface
## wetness/puddle overrides on top of whichever Look is active (scripts/world/weather_state.gd).
## Single-owner (the last add-on to call set_state wins) and cleared automatically on
## addon_stop(), game_ended(), and space platforms.

const WeatherState := preload("res://scripts/world/weather_state.gd")

var _host
var _api


func _init(host, api) -> void:
	_host = host
	_api = api


## Applies weather overrides. Every key in `spec` is optional; omitted keys stay at their neutral
## default. Returns false when disabled via `--addon-weather=off` or outside a game.
func set_state(spec: Dictionary) -> bool:
	if _host == null or not _host.in_game() or WeatherState.disabled:
		return false
	if WeatherState.set_state(str(_api.id), spec):
		_host.set("_weather_owner", str(_api.id))
		return true
	return false


## Clears this add-on's weather overrides back to Zenith's defaults.
func clear() -> void:
	if _host != null and str(_host.get("_weather_owner")) == str(_api.id):
		WeatherState.clear(str(_api.id))
		_host.set("_weather_owner", "")


## Whether any weather override is currently active.
func is_on() -> bool:
	return WeatherState.active


## A copy of the active weather state (`{}` when off).
func state() -> Dictionary:
	return WeatherState.current()


## Whether weather overrides were disabled via `--addon-weather=off`.
func disabled() -> bool:
	return WeatherState.disabled


## Injects an expanding puddle wake / dispersive ripple impulse at world XZ `pos` in tiles.
## Returns false if weather or puddle splashes are disabled, not in a game, or this add-on
## does not own the active weather state.
func add_puddle_ripple(pos: Vector2, dir := Vector2.ZERO, radius := 2.4, strength := 1.0, life := 1.6) -> bool:
	if _host == null or not _host.in_game():
		return false
	return WeatherState.add_impulse(str(_api.id), pos, dir, radius, strength, life)


## Scales the strength of active terrain puddle wake impulses (`0.0..2.5`).
func set_puddle_ripple_strength(strength: float) -> void:
	if _host == null or not _host.in_game():
		return
	WeatherState.set_impulse_strength(str(_api.id), strength)


## Clears all active terrain puddle wake impulses owned by this add-on.
func clear_puddle_ripples() -> void:
	if _host == null:
		return
	WeatherState.clear_impulses(str(_api.id))


## Whether vehicle puddle splashes and terrain puddle wakes were disabled via `--puddle-splashes=off`.
func splashes_disabled() -> bool:
	return WeatherState.splashes_disabled
