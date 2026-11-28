extends Node
## Immersive Weather add-on entry point (API 1.8; the strike list and the weather timeline need 1.91,
## a cue set by the game while running 1.92).
## Phase 1: Nauvis-only dry/sky weather states (Open Skies, Sunny, Fair, Partly Cloudy,
## Hazy Sun, Overcast, Heavy Overcast), wind-driven clouds/grass, bundled weather audio,
## Add-ons settings, and a quick in-game Weather Control panel.
## Phase 2: Light Drizzle, Steady Rain, Heavy Downpour with 3D rain, splashes, rain audio, and
## persistent wet surfaces, puddles, and ripples.
## Phase 3: Thunderstorm and Severe Thunderstorm with 3D lightning bolts, cloud flashes,
## speed-of-sound delayed thunder, optional camera rumble, and photosensitivity settings.

const Presets := preload("scripts/weather_presets.gd")
const Director := preload("scripts/weather_director.gd")
const WeatherAudio := preload("scripts/weather_audio.gd")
const PuddleAudio := preload("scripts/puddle_audio.gd")
const WeatherPanel := preload("scripts/weather_panel.gd")

var api
var director
var audio
var puddle_audio
var panel
var rain_fx
var puddle_fx
var lightning_fx


func addon_start(a) -> void:
	api = a
	if api.get("level") == null or float(api.level) < 1.8:
		api.note("needs Zenith's add-on API 1.8 (api.weather and api.sound.loop)")
		return
	_declare_settings()
	api.keys.add("panel", "Weather control panel", [KEY_F9 | KEY_MASK_ALT])
	director = Director.new(api)
	audio = WeatherAudio.new(api)
	puddle_audio = PuddleAudio.new(api)
	_mount_rain()
	_mount_puddles()
	_mount_lightning()
	panel = WeatherPanel.new(api, director, lightning_fx)

	_load_timeline()
	_load_strikes()
	if api.has_signal("cue_changed"):
		var on_cue := func(tick: int) -> void:
			api.note("cue from the game: tick %d" % tick if tick >= 0 else "cue from the game cleared")
		api.cue_changed.connect(on_cue)
	var on_setting := func(id: String, _v: Variant) -> void:
		if id == "strike_list":
			_load_strikes()
		if (id == "mode" or id == "locked_weather") and not director.has_timeline():
			if str(api.settings.value("mode")) == "locked":
				director.transition_to(str(api.settings.value("locked_weather")))
		if panel != null:
			panel.refresh()
	api.settings.changed.connect(on_setting)

	var on_options := func(box: VBoxContainer) -> void:
		box.add_child(api.ui.label("Status: %s" % director.status_text()))
		var open_fn := func() -> void:
			if api.in_game():
				panel.toggle()
			else:
				api.ui.message("Start or join a game first.")
		box.add_child(api.ui.button("Toggle Weather Panel (%s)" % api.keys.text("panel"), open_fn))
	api.ui.set_options(on_options)

	var on_start := func() -> void:
		audio.preload_all()
		if puddle_audio != null and bool(api.settings.value("vehicle_puddle_audio_enabled")):
			puddle_audio.start()
		director.reset_for_game()
		director.step(0.0)
		panel.refresh()
	api.game_started.connect(on_start)

	var on_end := func() -> void:
		director.save_state()
		audio.stop_all()
		if puddle_audio != null:
			puddle_audio.stop_all()
		if rain_fx != null:
			rain_fx.clear()
		if puddle_fx != null:
			puddle_fx.clear()
		if lightning_fx != null:
			lightning_fx.clear()
		director.flash_level = 0.0
		api.weather.clear()
		panel.refresh()
	api.game_ended.connect(on_end)

	if api.in_game():
		on_start.call()


func addon_stop() -> void:
	if director != null and api != null and api.in_game():
		director.save_state()
	if audio != null:
		audio.stop_all()
		audio.shutdown()
	if puddle_audio != null:
		puddle_audio.shutdown()
		puddle_audio = null
	if rain_fx != null:
		rain_fx.clear()
		rain_fx.queue_free()
		rain_fx = null
	if puddle_fx != null:
		puddle_fx.clear()
		puddle_fx.queue_free()
		puddle_fx = null
	if lightning_fx != null:
		lightning_fx.clear()
		lightning_fx.queue_free()
		lightning_fx = null
	if api != null and api.get("weather") != null:
		api.weather.clear()


func _process(delta: float) -> void:
	if director == null or not api.in_game():
		return
	var on_nauvis: bool = director.is_nauvis()
	if puddle_fx != null:
		puddle_fx.update(delta, on_nauvis and director.active_on_nauvis, director.current_spec)
	var flash := 0.0
	if lightning_fx != null:
		lightning_fx.external_offset = puddle_fx.rumble_offset() if puddle_fx != null else Vector3.ZERO
		lightning_fx.external_turn = puddle_fx.rumble_turn() if puddle_fx != null else Vector3.ZERO
		flash = float(lightning_fx.update(delta, on_nauvis, director.current_spec))
	director.flash_level = flash
	director.step(delta)
	if rain_fx != null:
		rain_fx.update(delta, director.active_on_nauvis, director.current_spec)
	audio.update(director.active_on_nauvis, director.current_spec, delta)
	if panel != null and panel.is_open():
		panel.refresh()


func _unhandled_input(event: InputEvent) -> void:
	if panel != null and api != null and api.in_game() and api.keys.pressed(event, "panel"):
		panel.toggle()
		get_viewport().set_input_as_handled()


## The weather timeline (`--weather-timeline=<file>`), when one is given: the weather follows it
## from the cue (api.world.cue_tick, a cue the game sets while running with API 1.92) instead of the
## Weather cycle setting; listed strikes then wait for the cue as well.
func _load_timeline() -> void:
	var path: String = Director.timeline_arg(OS.get_cmdline_user_args())
	if path == "":
		return
	if not api.world.has_method("cue_tick"):
		api.note("the weather timeline needs Zenith's add-on API 1.91 (api.world.cue_tick); the Weather cycle setting stays")
		return
	var err: String = director.load_timeline(path)
	if err != "":
		api.note(err + "; the Weather cycle setting stays")
		return
	api.note("weather timeline %s: %s before the cue, %d changes" % [path, director.timeline_before, director.timeline.size()])
	if lightning_fx != null:
		lightning_fx.wait_for_cue = true


## The strike list (`--weather-strikes=<file>`, else the Strike list setting), when one is asked for.
func _load_strikes() -> void:
	if lightning_fx == null:
		return
	var path: String = lightning_fx.strikes_arg(OS.get_cmdline_user_args(), str(api.settings.value("strike_list")))
	if path == lightning_fx.strikes_path and (path == "" or lightning_fx.has_strikes()):
		return
	if path != "" and not api.world.has_method("tick"):
		api.note("the strike list needs Zenith's add-on API 1.91 (api.world.tick); random strikes stay")
		return
	var err: String = lightning_fx.load_strikes(path)
	if err != "":
		api.note(err + "; random strikes stay")
	elif path != "":
		api.note("strike list %s: %d strikes" % [path, lightning_fx._strikes_offsets.size()])


func _mount_rain() -> void:
	var rain_path: String = (get_script() as Script).resource_path.get_base_dir().path_join("scripts/weather_rain.gd")
	if not ResourceLoader.exists(rain_path):
		return
	var rain_script: Script = load(rain_path) as Script
	if rain_script == null:
		return
	rain_fx = rain_script.new()
	add_child(rain_fx)
	rain_fx.setup(api)


func _mount_puddles() -> void:
	var puddle_path: String = (get_script() as Script).resource_path.get_base_dir().path_join("scripts/weather_puddles.gd")
	if not ResourceLoader.exists(puddle_path):
		return
	var puddle_script: Script = load(puddle_path) as Script
	if puddle_script == null:
		return
	puddle_fx = puddle_script.new()
	add_child(puddle_fx)
	puddle_fx.setup(api, puddle_audio)


func _mount_lightning() -> void:
	var light_path: String = (get_script() as Script).resource_path.get_base_dir().path_join("scripts/weather_lightning.gd")
	if not ResourceLoader.exists(light_path):
		return
	var light_script: Script = load(light_path) as Script
	if light_script == null:
		return
	lightning_fx = light_script.new()
	add_child(lightning_fx)
	lightning_fx.setup(api, audio)


func _declare_settings() -> void:
	var s = api.settings
	s.add("mode", "choice", "dynamic", "Weather cycle", {
		"choices": [["Dynamic", "dynamic"], ["Locked", "locked"]],
		"section": "Weather Cycle",
		"note": "Dynamic evolves through Nauvis weather over time; Locked holds one chosen weather.",
	})
	s.add("locked_weather", "choice", "fair", "Locked weather", {
		"choices": Presets.choices(),
		"section": "Weather Cycle",
		"note": "Weather held when Weather cycle is set to Locked.",
	})
	s.add("cycle_minutes", "number", 8.0, "Weather duration", {
		"min": 1.0, "max": 30.0, "step": 1.0, "unit": "min",
		"section": "Weather Cycle",
		"note": "Average time spent in each weather state before shifting.",
	})
	s.add("transition_seconds", "number", 30.0, "Transition time", {
		"min": 2.0, "max": 120.0, "step": 2.0, "unit": "s",
		"section": "Weather Cycle",
		"note": "Seconds to smoothly blend from one weather state to the next.",
	})
	s.add("allow_hazy", "bool", true, "Allow hazy sun", {
		"section": "Weather Cycle",
		"note": "Include warm Hazy Sun weather in the dynamic cycle.",
	})
	s.add("allow_overcast", "bool", true, "Allow overcast skies", {
		"section": "Weather Cycle",
		"note": "Include Overcast and Heavy Overcast skies in the dynamic cycle.",
	})
	s.add("allow_rain", "bool", true, "Allow rain", {
		"section": "Weather Cycle",
		"note": "Include Light Drizzle, Steady Rain, and Heavy Downpour in the dynamic cycle.",
	})
	s.add("allow_storms", "bool", true, "Allow thunderstorms", {
		"section": "Weather Cycle",
		"note": "Include Thunderstorm and Severe Thunderstorm in the dynamic cycle.",
	})
	s.add("dry_minutes", "number", 4.0, "Drying time", {
		"min": 0.5, "max": 20.0, "step": 0.5, "unit": "min",
		"section": "Weather Cycle",
		"note": "Minutes for wet surfaces to dry in full sun once rain stops (puddles linger longer, dim skies dry slower).",
	})

	s.add("cloud_strength", "number", 1.0, "Cloud strength", {
		"min": 0.0, "max": 1.5, "step": 0.05,
		"section": "Sky & Atmosphere",
		"note": "Strength of weather cloud density and cloud shadows (0 hides weather clouds).",
	})
	s.add("mood_strength", "number", 1.0, "Lighting mood", {
		"min": 0.0, "max": 1.5, "step": 0.05,
		"section": "Sky & Atmosphere",
		"note": "How strongly sun dimming, sky tints, and shadow softness follow the weather.",
	})
	s.add("fog_strength", "number", 1.0, "Fog & mist", {
		"min": 0.0, "max": 2.0, "step": 0.05,
		"section": "Sky & Atmosphere",
		"note": "Multiplier on atmospheric mist and distance fog added by overcast and hazy weather.",
	})
	s.add("wind_strength", "number", 1.0, "Wind strength", {
		"min": 0.0, "max": 2.0, "step": 0.05,
		"section": "Sky & Atmosphere",
		"note": "Multiplier on cloud drift speed and 3D grass wind sway.",
	})

	s.add("rain_enabled", "bool", true, "Rain", {
		"section": "Rain Effects",
		"note": "Show 3D rainfall (also gates splashes and ripples) during rainy weather.",
	})
	s.add("rain_density", "number", 1.0, "Rain density", {
		"min": 0.25, "max": 2.0, "step": 0.05,
		"section": "Rain Effects",
		"note": "Multiplier on the number of falling raindrops.",
	})
	s.add("rain_visibility", "number", 1.0, "Rain visibility", {
		"min": 0.25, "max": 2.0, "step": 0.05,
		"section": "Rain Effects",
		"note": "Multiplier on how bright and opaque the raindrop streaks look.",
	})
	s.add("splashes_enabled", "bool", true, "Ground splashes", {
		"section": "Rain Effects",
		"note": "Draw small splashes where raindrops hit the ground.",
	})
	s.add("splash_density", "number", 1.0, "Splash density", {
		"min": 0.25, "max": 2.0, "step": 0.05,
		"section": "Rain Effects",
		"note": "Multiplier on the number of ground splashes.",
	})

	s.add("ground_wetness_enabled", "bool", true, "Wet ground", {
		"section": "Wet Surfaces & Puddles",
		"note": "Darken and gloss terrain while it is wet from rain.",
	})
	s.add("model_wetness_enabled", "bool", true, "Wet buildings & objects", {
		"section": "Wet Surfaces & Puddles",
		"note": "Darken and gloss entity models, trees, and the character while wet.",
	})
	s.add("wetness_strength", "number", 1.0, "Wetness strength", {
		"min": 0.0, "max": 1.5, "step": 0.05,
		"section": "Wet Surfaces & Puddles",
		"note": "Multiplier on how wet surfaces get.",
	})
	s.add("wet_darken", "number", 0.45, "Wet darkening", {
		"min": 0.0, "max": 1.0, "step": 0.05,
		"section": "Wet Surfaces & Puddles",
		"note": "How much wet surfaces darken.",
	})
	s.add("ground_puddles_enabled", "bool", true, "Ground puddles", {
		"section": "Wet Surfaces & Puddles",
		"note": "Reflective puddles collect on flat terrain after sustained rain and linger as it dries.",
	})
	s.add("puddle_amount", "number", 1.0, "Puddle amount", {
		"min": 0.0, "max": 1.5, "step": 0.05,
		"section": "Wet Surfaces & Puddles",
		"note": "Multiplier on how much of the ground puddles cover.",
	})
	s.add("puddle_scale", "number", 0.12, "Puddle size", {
		"min": 0.04, "max": 0.30, "step": 0.01,
		"section": "Wet Surfaces & Puddles",
		"note": "Noise scale of puddle shapes (lower makes larger, broader puddles).",
	})
	s.add("puddle_reflect", "number", 0.85, "Puddle reflectivity", {
		"min": 0.0, "max": 1.5, "step": 0.05,
		"section": "Wet Surfaces & Puddles",
		"note": "How mirror-like puddle surfaces look.",
	})
	s.add("model_puddles_enabled", "bool", true, "Puddles on models", {
		"section": "Wet Surfaces & Puddles",
		"note": "Water pools on flat tops of buildings and objects.",
	})
	s.add("model_puddles_strength", "number", 1.0, "Model puddle strength", {
		"min": 0.0, "max": 1.5, "step": 0.05,
		"section": "Wet Surfaces & Puddles",
	})
	s.add("rain_ripples_enabled", "bool", true, "Rain ripples", {
		"section": "Wet Surfaces & Puddles",
		"note": "Concentric ripples from raindrops landing in puddles and wet surfaces while it rains.",
	})
	s.add("rain_ripples_strength", "number", 1.0, "Ripple strength", {
		"min": 0.0, "max": 1.5, "step": 0.05,
		"section": "Wet Surfaces & Puddles",
	})
	s.add("vehicle_puddle_splashes_enabled", "bool", true, "Vehicle puddle splashes", {
		"section": "Wet Surfaces & Puddles",
		"note": "Show 3D splashes and terrain puddle ripples when vehicles drive through puddles.",
	})
	s.add("vehicle_puddle_splash_strength", "number", 1.0, "Vehicle splash strength", {
		"min": 0.0, "max": 2.0, "step": 0.05,
		"section": "Wet Surfaces & Puddles",
	})
	s.add("vehicle_puddle_rumble_enabled", "bool", true, "Vehicle puddle impact shudder", {
		"section": "Wet Surfaces & Puddles",
		"note": "Subtle driver-seat shudder when hitting a puddle at speed.",
	})

	s.add("lightning_enabled", "bool", true, "Lightning", {
		"section": "Thunderstorms & Lightning",
		"note": "Allow cloud-to-cloud flashes, 3D bolts, and thunder during thunderstorms.",
	})
	s.add("lightning_bolts_enabled", "bool", true, "3D lightning bolts", {
		"section": "Thunderstorms & Lightning",
		"note": "Draw jagged 3D lightning bolts down from storm clouds (visual only, zero game damage).",
	})
	s.add("lightning_frequency", "number", 1.0, "Strike frequency", {
		"min": 0.25, "max": 2.0, "step": 0.05,
		"section": "Thunderstorms & Lightning",
		"note": "Multiplier on how often lightning strikes during storms.",
	})
	s.add("flash_brightness", "number", 0.75, "Flash brightness", {
		"min": 0.0, "max": 1.5, "step": 0.05,
		"section": "Thunderstorms & Lightning",
		"note": "Brightness of full-sky/cloud lightning flashes (0 disables full-sky flashes for photosensitivity).",
	})
	s.add("camera_rumble_enabled", "bool", true, "Thunder camera rumble", {
		"section": "Thunderstorms & Lightning",
		"note": "Subtle temporary camera shake when close thunder hits.",
	})
	s.add("camera_rumble_strength", "number", 0.45, "Rumble strength", {
		"min": 0.0, "max": 1.5, "step": 0.05,
		"section": "Thunderstorms & Lightning",
	})
	s.add("strike_list", "text", "", "Strike list (file)", {
		"section": "Thunderstorms & Lightning",
		"placeholder": "strikes.json",
		"note": "Timed strikes for a filmed scene: a JSON file (README, \"Timed strikes\"), from the add-on's folder unless a full path. They fire on the game's tick from --cue-tick, the same every run; random strikes are off while a list is loaded. --weather-strikes=<file> wins over this.",
	})

	s.add("audio_enabled", "bool", true, "Weather audio", {
		"section": "Audio",
		"note": "Play ambient wind, rain, and thunder audio on Nauvis (follows Zenith's Ambient volume slider).",
	})
	s.add("audio_volume", "number", 0.55, "Master weather volume", {
		"min": 0.0, "max": 1.0, "step": 0.05,
		"section": "Audio",
	})
	s.add("wind_volume", "number", 0.7, "Wind volume", {
		"min": 0.0, "max": 1.0, "step": 0.05,
		"section": "Audio",
	})
	s.add("storm_wind", "choice", "new", "Storm wind", {
		"choices": [["New (roar with gusts)", "new"], ["Classic (whistle loop)", "classic"]],
		"section": "Audio",
		"note": "New: a broad roar made at start, with gusts that never repeat the same way. Classic: the 0.3.1 whistle loop. --weather-wind=old forces Classic.",
	})
	s.add("sound_tone", "choice", "soft", "Rain and wind tone", {
		"choices": [["Soft (tilted down, more headroom)", "soft"], ["Original (Weather Elements as recorded)", "original"]],
		"section": "Audio",
		"note": "Soft: the rain and wind loops with their top end eased and the loudest peaks 5 dB lower. Original: the files as first bundled. --weather-sounds=original forces Original.",
	})
	s.add("rain_volume", "number", 0.8, "Rain volume", {
		"min": 0.0, "max": 1.0, "step": 0.05,
		"section": "Audio",
	})
	s.add("thunder_volume", "number", 0.85, "Thunder volume", {
		"min": 0.0, "max": 1.0, "step": 0.05,
		"section": "Audio",
	})
	s.add("use_factorio_audio", "bool", false, "Use Factorio rain & thunder audio", {
		"section": "Audio",
		"note": "Use Factorio Space Age's rain and thunder sounds from your own install when present; falls back to the bundled Weather Elements audio automatically.",
	})
	s.add("vehicle_puddle_audio_enabled", "bool", true, "Vehicle puddle audio", {
		"section": "Audio",
		"note": "Play wet spray and puddle impact sounds on the Effects bus.",
	})
