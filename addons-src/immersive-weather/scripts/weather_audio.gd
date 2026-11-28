extends RefCounted
## Smooth wind & rain audio loop controller via api.sound.loop / update_loop (API 1.8).
## Storm wind (0.3.2): StormWind's generated roar and rush with gusts (setting "Storm wind", New);
## Classic or `--weather-wind=old` keeps the 0.3.1 whistle loop pitched up with the wind.

const StormWind := preload("storm_wind.gd")

const GENTLE_PATH := "sounds/wind-gentle.ogg"
const GUSTY_PATH := "sounds/wind-gusty.ogg"
const RAIN_LIGHT_PATH := "sounds/rain-light.ogg"
const RAIN_STEADY_PATH := "sounds/rain-steady.ogg"
const RAIN_HEAVY_PATH := "sounds/rain-heavy.ogg"
const THUNDER_CRACK_PATHS := [
	"sounds/thunder-crack-1.ogg",
	"sounds/thunder-crack-2.ogg",
	"sounds/thunder-crack-3.ogg",
	"sounds/thunder-crack-4.ogg",
]
const THUNDER_ROLL_PATHS := [
	"sounds/thunder-roll-1.ogg",
	"sounds/thunder-roll-2.ogg",
	"sounds/thunder-roll-3.ogg",
	"sounds/thunder-roll-4.ogg",
]
const FACTORIO_RAIN_PATH := "__space-age__/sound/world/weather/rain.ogg"
const FACTORIO_CRACK_PATHS := [
	"__space-age__/sound/explosions/lightning-effect-1.ogg",
	"__space-age__/sound/explosions/lightning-effect-2.ogg",
	"__space-age__/sound/explosions/lightning-effect-3.ogg",
	"__space-age__/sound/explosions/lightning-effect-4.ogg",
	"__space-age__/sound/explosions/lightning-effect-5.ogg",
]
const FACTORIO_ROLL_PATHS := [
	"__space-age__/sound/world/semi-persistent/distant-thunder-1.ogg",
	"__space-age__/sound/world/semi-persistent/distant-thunder-2.ogg",
	"__space-age__/sound/world/semi-persistent/distant-thunder-3.ogg",
	"__space-age__/sound/world/semi-persistent/distant-thunder-4.ogg",
]
const FACTORIO_RETRY_MS := 1500

var api
var _gentle_id := 0
var _gusty_id := 0
var _rain_light_id := 0
var _rain_steady_id := 0
var _rain_heavy_id := 0
var _factorio_rain_id := 0
var _factorio_next_try := 0
var _factorio_preloaded := false
var _last_crack_idx := -1
var _last_roll_idx := -1
var storm: StormWind = null
var _roar_id := 0
var _rush_id := 0
var _last_usec := 0
var _forced_old := false
var _forced_original := false
var _tone_original := false  # the tone in use (the setting, unless --weather-sounds=original)
var _opts := {"volume": 0.0, "pitch": 1.0}  # update_loop's options, reused every frame


func _init(a) -> void:
	api = a
	_forced_old = wind_arg(OS.get_cmdline_user_args()) == "old"
	_forced_original = sounds_arg(OS.get_cmdline_user_args()) == "original"
	storm = StormWind.new()


## `--weather-wind=old` (the Classic storm wind whatever the setting), else "".
static func wind_arg(args: PackedStringArray) -> String:
	for a: String in args:
		if a.begins_with("--weather-wind="):
			return a.substr(15).strip_edges()
	return ""


## The new storm wind is in use (the setting, unless --weather-wind=old).
func new_wind() -> bool:
	if _forced_old:
		return false
	var v: Variant = api.settings.value("storm_wind")
	return v == null or str(v) != "classic"


## `--weather-sounds=original` (the unsoftened rain and wind loops whatever the setting), else "".
static func sounds_arg(args: PackedStringArray) -> String:
	for a: String in args:
		if a.begins_with("--weather-sounds="):
			return a.substr(17).strip_edges()
	return ""


## The original Weather Elements loops are in use (the setting, or --weather-sounds=original).
func original_tone() -> bool:
	if _forced_original:
		return true
	var v: Variant = api.settings.value("sound_tone")
	return v != null and str(v) == "original"


## A rain or wind loop's path in the tone in use ("sounds/x.ogg" soft, "sounds/original/x.ogg" original).
func tone_path(path: String) -> String:
	return path.replace("sounds/", "sounds/original/") if _tone_original else path


func preload_all() -> void:
	_tone_original = original_tone()
	api.sound.preload_sounds([tone_path(GENTLE_PATH), tone_path(GUSTY_PATH), tone_path(RAIN_LIGHT_PATH), tone_path(RAIN_STEADY_PATH), tone_path(RAIN_HEAVY_PATH)])
	api.sound.preload_sounds(THUNDER_CRACK_PATHS)
	api.sound.preload_sounds(THUNDER_ROLL_PATHS)
	_preload_factorio()
	if new_wind():
		storm.start()


## Factorio's own rain & thunder files are only decoded when asked for (and only if Space Age is there).
func _preload_factorio() -> void:
	if _factorio_preloaded or not _use_factorio():
		return
	_factorio_preloaded = true
	api.sound.preload_sounds([FACTORIO_RAIN_PATH])
	api.sound.preload_sounds(FACTORIO_CRACK_PATHS)
	api.sound.preload_sounds(FACTORIO_ROLL_PATHS)


func _use_factorio() -> bool:
	var v: Variant = api.settings.value("use_factorio_audio")
	return v != null and bool(v)


func _setting_float(key: String, fallback: float) -> float:
	var v: Variant = api.settings.value(key)
	return fallback if v == null else float(v)


## `delta`: the frame's seconds (the storm wind's gusts); < 0 measures it by the clock.
func update(active_on_nauvis: bool, spec: Dictionary, delta := -1.0) -> void:
	var audio_on: Variant = api.settings.value("audio_enabled")
	var enabled := (audio_on == null or bool(audio_on)) and active_on_nauvis
	if not enabled:
		stop_all()
		return
	if original_tone() != _tone_original:
		# The tone setting changed: stop the loops, load the other files; they restart below.
		stop_all()
		preload_all()
	var master := _setting_float("audio_volume", 1.0)
	_update_wind(master, spec, delta)
	_update_rain(master, spec)


func _update_wind(master: float, spec: Dictionary, frame_delta := -1.0) -> void:
	var wind_vol := _setting_float("wind_volume", 1.0)
	var wind_amt := clampf(float(spec.get("wind_audio", 0.0)), 0.0, 1.2)
	var base_gain := clampf(master * wind_vol, 0.0, 1.0)
	# Crossfade smoothly from gentle breeze (low wind) to gustier overcast wind (high wind).
	var gentle_v := clampf(wind_amt * 1.1 * (1.0 - smoothstep(0.45, 0.95, wind_amt)) * base_gain, 0.0, 0.85)
	var gusty_v := clampf(smoothstep(0.32, 0.95, wind_amt) * 0.8 * base_gain, 0.0, 0.85)

	_gentle_id = _drive_loop(_gentle_id, tone_path(GENTLE_PATH), gentle_v, 0.95 + 0.1 * wind_amt)

	var now := Time.get_ticks_usec()
	var delta := clampf(float(now - _last_usec) / 1000000.0, 0.0, 0.1) if _last_usec > 0 else 0.0
	if frame_delta >= 0.0:
		delta = minf(frame_delta, 0.1)
	_last_usec = now
	if new_wind():
		storm.start()
	if new_wind() and storm.ready():
		# A roar with gusts; the whistle only a quiet layer at the top of the strongest gusts.
		storm.step(delta, wind_amt, base_gain)
		_roar_id = _drive_stream(_roar_id, storm.roar, storm.roar_vol, storm.roar_pitch)
		_rush_id = _drive_stream(_rush_id, storm.rush, storm.rush_vol, storm.rush_pitch)
		_gusty_id = _drive_loop(_gusty_id, tone_path(GUSTY_PATH), storm.whistle_vol, 1.0)
		return
	# Classic (or the new layers still being made at the game's start).
	_roar_id = _drive_stream(_roar_id, null, 0.0, 1.0)
	_rush_id = _drive_stream(_rush_id, null, 0.0, 1.0)
	_gusty_id = _drive_loop(_gusty_id, tone_path(GUSTY_PATH), gusty_v, 0.92 + 0.16 * wind_amt)


func _update_rain(master: float, spec: Dictionary) -> void:
	var rain_amt := clampf(float(spec.get("rain_audio", 0.0)), 0.0, 1.0)
	var gain := clampf(master * _setting_float("rain_volume", 1.0), 0.0, 1.0)
	if rain_amt <= 0.02 or gain <= 0.005:
		_stop_rain(1.2)
		return

	# Factorio's rain first, when asked for and it exists (a 0 handle: absent, or still decoding).
	var factorio_v := clampf(smoothstep(0.02, 0.4, rain_amt) * gain * 0.85, 0.0, 1.0)
	var factorio_live := false
	if _use_factorio():
		_preload_factorio()
		factorio_live = _drive_factorio(factorio_v, 0.96 + 0.08 * rain_amt)
	elif _factorio_rain_id > 0:
		api.sound.stop_loop(_factorio_rain_id, 1.0)
		_factorio_rain_id = 0

	# Our own loops fill in (and carry the rain whenever Factorio's isn't playing): light drizzle
	# -> steady rain -> downpour, crossfaded across rain_audio.
	var fade_in := smoothstep(0.02, 0.14, rain_amt)
	var light := (1.0 - smoothstep(0.15, 0.55, rain_amt)) * fade_in
	var steady := smoothstep(0.10, 0.50, rain_amt) * (1.0 - smoothstep(0.55, 0.95, rain_amt))
	var heavy := smoothstep(0.55, 0.95, rain_amt)
	var own := 0.0 if factorio_live else 1.0
	var base := clampf(gain * 0.9, 0.0, 1.0) * own
	var pitch := 0.97 + 0.06 * rain_amt
	_rain_light_id = _drive_loop(_rain_light_id, tone_path(RAIN_LIGHT_PATH), clampf(light * base, 0.0, 1.0), pitch)
	_rain_steady_id = _drive_loop(_rain_steady_id, tone_path(RAIN_STEADY_PATH), clampf(steady * base, 0.0, 1.0), pitch)
	_rain_heavy_id = _drive_loop(_rain_heavy_id, tone_path(RAIN_HEAVY_PATH), clampf(heavy * base, 0.0, 1.0), pitch)


## Keeps Factorio's rain loop going; true when it is playing. Retries (not every frame) while absent.
func _drive_factorio(vol: float, pitch: float) -> bool:
	if _factorio_rain_id > 0:
		if bool(api.sound.update_loop(_factorio_rain_id, {"volume": vol, "pitch": pitch})):
			return true
		_factorio_rain_id = 0
	var now := Time.get_ticks_msec()
	if now < _factorio_next_try:
		return false
	_factorio_rain_id = int(api.sound.loop(FACTORIO_RAIN_PATH, {"bus": "ambient", "volume": vol, "pitch": pitch, "fade_in": 1.5}))
	if _factorio_rain_id <= 0:
		_factorio_rain_id = 0
		_factorio_next_try = now + FACTORIO_RETRY_MS
		return false
	return true


func _stop_rain(fade: float) -> void:
	if _rain_light_id > 0:
		api.sound.stop_loop(_rain_light_id, fade)
		_rain_light_id = 0
	if _rain_steady_id > 0:
		api.sound.stop_loop(_rain_steady_id, fade)
		_rain_steady_id = 0
	if _rain_heavy_id > 0:
		api.sound.stop_loop(_rain_heavy_id, fade)
		_rain_heavy_id = 0
	if _factorio_rain_id > 0:
		api.sound.stop_loop(_factorio_rain_id, fade)
		_factorio_rain_id = 0


func _drive_loop(handle: int, path: String, vol: float, pitch: float) -> int:
	if vol <= 0.005:
		if handle > 0:
			api.sound.stop_loop(handle, 0.8)
		return 0
	if handle <= 0:
		return int(api.sound.loop(path, {"bus": "ambient", "volume": vol, "pitch": pitch, "fade_in": 1.2}))
	_opts["volume"] = vol
	_opts["pitch"] = pitch
	if not bool(api.sound.update_loop(handle, _opts)):
		return int(api.sound.loop(path, {"bus": "ambient", "volume": vol, "pitch": pitch, "fade_in": 1.2}))
	return handle


## As _drive_loop, for a generated stream (StormWind's layers). Stays off until the gain is worth it
## (a quiet layer is not kept playing).
func _drive_stream(handle: int, stream: AudioStream, vol: float, pitch: float) -> int:
	if vol <= 0.004 or stream == null:
		if handle > 0:
			api.sound.stop_loop(handle, 1.2)
		return 0
	if handle > 0:
		_opts["volume"] = vol
		_opts["pitch"] = pitch
		if bool(api.sound.update_loop(handle, _opts)):
			return handle
	return int(api.sound.loop(stream, {"bus": "ambient", "volume": vol, "pitch": pitch, "fade_in": 1.5}))


func stop_all() -> void:
	if _gentle_id > 0:
		api.sound.stop_loop(_gentle_id, 0.4)
		_gentle_id = 0
	if _gusty_id > 0:
		api.sound.stop_loop(_gusty_id, 0.4)
		_gusty_id = 0
	if _roar_id > 0:
		api.sound.stop_loop(_roar_id, 0.4)
		_roar_id = 0
	if _rush_id > 0:
		api.sound.stop_loop(_rush_id, 0.4)
		_rush_id = 0
	_last_usec = 0
	_stop_rain(0.4)


## The add-on stopping: waits for the storm wind's layers if they are still being made.
func shutdown() -> void:
	if storm != null:
		storm.finish()


func play_thunder(distance: float, strength := 1.0) -> bool:
	var audio_on: Variant = api.settings.value("audio_enabled")
	if audio_on != null and not bool(audio_on):
		return false
	var master := _setting_float("audio_volume", 1.0)
	var thunder_vol := _setting_float("thunder_volume", 0.85)
	var dist_att := clampf(1.0 - distance / 180.0, 0.28, 1.0)
	var vol := clampf(master * thunder_vol * strength * dist_att, 0.0, 1.0)
	if vol <= 0.01:
		return false

	var close := distance < 55.0
	if _use_factorio():
		_preload_factorio()
		var fac_pool: Array = FACTORIO_CRACK_PATHS if close else FACTORIO_ROLL_PATHS
		if not fac_pool.is_empty():
			var fac_path: String = str(fac_pool[randi() % fac_pool.size()])
			if bool(api.sound.play(fac_path, {"bus": "ambient", "volume": vol, "pitch_spread": 0.08})):
				return true

	var pool: Array = THUNDER_CRACK_PATHS if close else THUNDER_ROLL_PATHS
	if pool.is_empty():
		return false
	var last_idx := _last_crack_idx if close else _last_roll_idx
	var idx := _pick_non_repeat(pool.size(), last_idx)
	if close:
		_last_crack_idx = idx
	else:
		_last_roll_idx = idx
	var chosen: String = str(pool[idx])
	return bool(api.sound.play(chosen, {"bus": "ambient", "volume": vol, "pitch_spread": 0.08}))


func _pick_non_repeat(size: int, last_idx: int) -> int:
	if size <= 1:
		return 0
	var idx := randi() % size
	if idx == last_idx:
		idx = (idx + 1 + (randi() % (size - 1))) % size
	return idx
