extends "res://tests/addon_test_base.gd"
## Add-on test sections: weather_enemies.

func _weather_api(api, host, fake) -> void:
	check(api.weather != null and not api.weather.is_on() and api.weather.state().is_empty(),
		"1.8 weather: starts off with empty state")
	var was_game: bool = host._game_on
	host._game_on = true
	var was_disabled: bool = WeatherState.disabled
	WeatherState.disabled = true
	check(not api.weather.set_state({"cloud_cover": 0.9}) and not api.weather.is_on(),
		"1.8 weather: --addon-weather=off refuses set_state")
	WeatherState.disabled = was_disabled

	var ok: bool = api.weather.set_state({
		"cloud_cover": 0.92,
		"cloud_darkness": 0.6,
		"sun_energy_scale": 0.4,
		"shadow_opacity_scale": 0.3,
		"ambient_energy_scale": 1.1,
		"fog_density_add": 0.002,
		"fog_color": Color(0.6, 0.65, 0.72),
		"fog_color_amount": 0.5,
		"wind": Vector2(2.5, 1.0),
		"wind_strength": 1.8,
		"ground_wetness": 0.85,
		"model_wetness": 0.7,
		"puddle_amount": 0.5,
		"model_puddles": 0.4,
		"rain_ripples": 0.9,
		"puddle_scale": 0.15,
		"puddle_reflect": 0.9,
		"wet_darken": 0.5,
		"god_rays_scale": 0.2,
		"flash": NAN,
	})
	WeatherState.base_grass_wind = true
	WeatherState.cloud_drift = Vector2.ZERO
	WeatherState.advance(2.0, false)
	var lg: Dictionary = WeatherState.last_globals
	check(ok and api.weather.is_on() and is_equal_approx(float(WeatherState.state["flash"]), 0.0)
		and (lg["f3d_weather_wet"] as Vector4).is_equal_approx(Vector4(0.85, 0.7, 0.5, 0.9))
		and (lg["f3d_weather_puddle"] as Vector4).is_equal_approx(Vector4(0.15, 0.9, 0.5, 0.4))
		and (lg["f3d_weather_clouds"] as Vector4).is_equal_approx(Vector4(0.92, 0.6, 1.0, 0.0))
		and (lg["f3d_weather_wind"] as Vector4).is_equal_approx(Vector4(5.0, 2.0, 1.8, 1.0))
		and is_equal_approx(float(lg["f3d_grass_wind"]), 1.8),
		"1.8 weather: set_state sanitizes NaNs and pushes weather/puddle/wind globals: %s" % [lg])

	# Verify integration with PlanetSky, Looks, and GodRays, then clean release.
	var sky := PlanetSky.new()
	add_child(sky)
	var env := Environment.new()
	var sun := DirectionalLight3D.new()
	add_child(sun)
	var looks := Looks.new()
	add_child(looks)
	looks.attach(env, sun)
	sky.apply(env, sun, 0.0, 0.0, 0.016, false)
	var sun_wx := sun.light_energy
	looks.apply(0.0, 0.0, "nauvis", false, sky.state)
	var fog_wx := env.fog_enabled
	var fog_d_wx := env.fog_density
	var shadow_wx := sun.shadow_opacity
	var rays := GodRays.new()
	add_child(rays)
	rays.set_forced_strength(0.5)
	rays.update(sky.atmosphere(), 0.0)
	var rays_mat := rays._quad.material_override as ShaderMaterial
	var rays_str := float(rays_mat.get_shader_parameter("strength"))
	check(fog_wx and fog_d_wx >= 0.0019 and shadow_wx <= 0.31 and is_equal_approx(rays_str, 0.1),
		"1.8 weather: PlanetSky/Looks/GodRays apply fog, shadow opacity, and god ray scale (%s, %.4f, %.2f, %.2f)" % [fog_wx, fog_d_wx, shadow_wx, rays_str])

	# Space platform suppresses weather globals & fog cleanly.
	WeatherState.advance(1.0, true)
	var space_wet: Vector4 = WeatherState.last_globals["f3d_weather_wet"]
	var space_clouds: Vector4 = WeatherState.last_globals["f3d_weather_clouds"]
	sky.apply(env, sun, 0.0, 0.0, 0.016, true)
	looks.apply(0.0, 0.0, "nauvis", true, sky.state)
	check(space_wet == Vector4.ZERO and space_clouds == Vector4.ZERO and not env.fog_enabled,
		"1.8 weather: space platform zeroes surface/cloud globals and disables fog")

	# --wet-metal=old toggle pushes f3d_wet_metal 1.0 by default, 0.0 when old.
	var was_wet_metal_old: bool = WeatherState.wet_metal_old
	WeatherState.wet_metal_old = false
	WeatherState.push_globals(false)
	var wm_new := float(WeatherState.last_globals.get("f3d_wet_metal", -1.0))
	WeatherState.wet_metal_old = true
	WeatherState.push_globals(false)
	var wm_old := float(WeatherState.last_globals.get("f3d_wet_metal", -1.0))
	WeatherState.wet_metal_old = was_wet_metal_old
	WeatherState.push_globals(false)
	check(is_equal_approx(wm_new, 1.0) and is_equal_approx(wm_old, 0.0),
		"wet-metal: f3d_wet_metal pushes 1.0 by default and 0.0 for --wet-metal=old (%.1f, %.1f)" % [wm_new, wm_old])

	var ws_src := FileAccess.get_file_as_string("res://shaders/weather_surface.gdshaderinc")
	var fm_src := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	check(ws_src.contains("global uniform float f3d_wet_metal")
		and ws_src.contains("inout float metallic")
		and fm_src.contains("ALBEDO, ROUGHNESS, SPECULAR, METALLIC, NORMAL, VIEW_MATRIX"),
		"wet-metal: weather_surface and factorio_material wire f3d_wet_metal and inout metallic")
	for sh_name in ["factorio_material", "factorio_material_alpha", "factorio_material_clip"]:
		var sh: Shader = load("res://shaders/%s.gdshader" % sh_name) as Shader
		var u_names: Array = sh.get_shader_uniform_list().map(func(u: Dictionary) -> String: return str(u.get("name", ""))) if sh != null else []
		check(sh != null and u_names.has("albedo") and u_names.has("metallic"),
			"wet-metal: %s.gdshader loads and compiles cleanly (%d uniforms)" % [sh_name, u_names.size()])

	# Clearing weather restores baseline sun/shadows/fog/globals cleanly.
	api.weather.clear()
	sky.apply(env, sun, 0.0, 0.0, 0.016, false)
	looks.apply(0.0, 0.0, "nauvis", false, sky.state)
	check(not api.weather.is_on() and WeatherState.last_globals["f3d_weather_wet"] == Vector4.ZERO
		and sun.light_energy > sun_wx * 2.0 and is_equal_approx(sun.shadow_opacity, 1.0) and not env.fog_enabled,
		"1.8 weather: clear() restores sun energy, shadow opacity, fog, and surface globals")

	# game_ended() clears active weather automatically.
	api.weather.set_state({"cloud_cover": 0.1, "ground_wetness": 0.3})
	check(api.weather.is_on(), "1.8 weather: active before game_ended")
	host.game_ended()
	check(not api.weather.is_on() and WeatherState.last_globals["f3d_weather_wet"] == Vector4.ZERO,
		"1.8 weather: game_ended() clears active weather")
	host._game_on = was_game
	WeatherState.base_grass_wind = false
	WeatherState.clear()
	rays.queue_free()
	looks.queue_free()
	sun.queue_free()
	sky.queue_free()


## Immersive Weather add-on (addons-src/immersive-weather/): Phase 1 Nauvis states, gating, audio, panel.


func _immersive_weather(fake) -> void:
	var src := ProjectSettings.globalize_path("res://").path_join("../addons-src/immersive-weather").simplify_path()
	if not DirAccess.dir_exists_absolute(src):
		check(false, "immersive weather: the add-on's folder is at " + src)
		return
	var was_planet: String = str(fake._planet_sky.planet)
	var was_space: bool = bool(fake._space)
	fake._planet_sky.planet = "nauvis"
	fake._space = false
	var sfx := Sfx.new()
	add_child(sfx)
	Settings.set_value("addons", "immersive-weather", true)
	var host := AddonHost.new()
	host.autoload = false
	host.main = fake
	add_child(host)
	host.load_all([[src.get_base_dir(), "test"]])
	await get_tree().process_frame
	var m := host.find("immersive-weather")
	var node: Node = m.get("node")
	check(node != null, "immersive weather: starts cleanly: " + str(m.get("error", m.get("problem", ""))))
	if node == null:
		Settings.reset_value("addons", "immersive-weather")
		host.queue_free()
		remove_child(sfx)
		sfx.free()
		fake._planet_sky.planet = was_planet
		fake._space = was_space
		return

	host.game_started()
	await get_tree().process_frame
	node._process(0.1)
	var s_gentle := SoundBank.stream("addon:immersive-weather/sounds/wind-gentle.ogg", true)
	var s_gusty := SoundBank.stream("addon:immersive-weather/sounds/wind-gusty.ogg", true)
	check(s_gentle != null and s_gentle.get_length() > 10.0 and s_gusty != null and s_gusty.get_length() > 10.0,
		"immersive weather: bundled Ogg Vorbis wind loops decode cleanly (%s, %s)" % [
			s_gentle.get_length() if s_gentle != null else 0.0,
			s_gusty.get_length() if s_gusty != null else 0.0])
	check(WeatherState.active and WeatherState.owner == "immersive-weather" and sfx.addon_loop_count("immersive-weather") >= 1,
		"immersive weather: active on Nauvis with breeze audio loop")

	# Locking Overcast and stepping completes transition cleanly.
	node.api.settings.set_value("mode", "locked", false)
	node.api.settings.set_value("locked_weather", "overcast", false)
	node.api.settings.set_value("transition_seconds", 2.0, false)
	node._process(3.0)
	check(node.director.current_id == "overcast" and float(WeatherState.state.get("cloud_cover", 0.0)) >= 0.89
		and float(WeatherState.state.get("sun_energy_scale", 1.0)) < 0.5,
		"immersive weather: locked Overcast shifts cloud_cover and dims sunlight: %s" % [WeatherState.state])

	# Open Skies clears clouds completely.
	node.director.jump_to("open_skies")
	check(is_equal_approx(float(WeatherState.state.get("cloud_cover", 1.0)), 0.0),
		"immersive weather: Open Skies sets cloud_cover to 0")

	# Weather panel opens and refreshes cleanly.
	node.panel.toggle()
	check(node.panel.is_open(), "immersive weather: control panel opens")

	# Leaving Nauvis (Vulcanus) and boarding space platform clears weather & stops loops.
	fake._planet_sky.planet = "vulcanus"
	node._process(0.1)
	check(not WeatherState.active and sfx.addon_loop_count("immersive-weather") == 0,
		"immersive weather: clears weather and stops audio on Vulcanus")
	fake._planet_sky.planet = "nauvis"
	fake._space = true
	node._process(0.1)
	check(not WeatherState.active, "immersive weather: inactive on a space platform")
	fake._space = false
	node._process(0.1)
	check(WeatherState.active, "immersive weather: resumes cleanly on returning to Nauvis")

	await _immersive_weather_rain(host, node, sfx, fake)
	await _immersive_weather_storms(host, node, sfx, fake)
	_iw_vehicle_puddles(node, sfx, fake)

	host.set_enabled("immersive-weather", false)
	await get_tree().process_frame
	check(not WeatherState.active and sfx.addon_loop_count("immersive-weather") == 0,
		"immersive weather: switching add-on off clears weather and stops audio loops")

	host.game_ended()
	for id in ["mode", "locked_weather", "cycle_minutes", "transition_seconds", "allow_hazy",
			"allow_overcast", "allow_rain", "allow_storms", "dry_minutes", "cloud_strength", "mood_strength", "fog_strength",
			"wind_strength", "rain_enabled", "rain_density", "rain_visibility", "splashes_enabled",
			"splash_density", "ground_wetness_enabled", "model_wetness_enabled", "wetness_strength",
			"wet_darken", "ground_puddles_enabled", "puddle_amount", "puddle_scale", "puddle_reflect",
			"model_puddles_enabled", "model_puddles_strength", "rain_ripples_enabled",
			"rain_ripples_strength", "vehicle_puddle_splashes_enabled", "vehicle_puddle_splash_strength",
			"vehicle_puddle_rumble_enabled", "vehicle_puddle_audio_enabled",
			"lightning_enabled", "lightning_bolts_enabled", "lightning_frequency",
			"flash_brightness", "camera_rumble_enabled", "camera_rumble_strength", "audio_enabled", "audio_volume", "wind_volume", "rain_volume", "thunder_volume",
			"use_factorio_audio", "strike_list", "storm_wind"]:
		Settings.reset_value("addon_immersive_weather", id)
	Settings.reset_value("addons", "immersive-weather")
	WeatherState.clear()
	host.queue_free()
	remove_child(sfx)
	sfx.free()
	fake._planet_sky.planet = was_planet
	fake._space = was_space


func _iw_wet() -> Vector4:
	var v: Vector4 = WeatherState.last_globals["f3d_weather_wet"]
	return v


func _iw_pud() -> Vector4:
	var v: Vector4 = WeatherState.last_globals["f3d_weather_puddle"]
	return v


## Steps the add-on's per-frame update for `secs` seconds in `step`-second slices.
## Storm wind (0.3.2): the generated roar and rush play in a heavy wind, gusts vary, Classic and
## --weather-wind=old bring back the whistle loop.


func _iw_storm_wind(node: Node, sfx: Node, st) -> void:
	var audio = node.audio
	audio.storm.finish()
	_iw_run(node, 2.0, 1.0 / 30.0)
	var roar: AudioStreamWAV = audio.storm.roar
	check(roar != null and audio.storm.rush != null and roar.stereo and roar.loop_mode == AudioStreamWAV.LOOP_FORWARD
		and roar.get_length() > 10.0 and audio._roar_id > 0 and audio._rush_id > 0,
		"storm wind: heavy wind plays the generated roar and rush, stereo looping layers (%d, %d)" % [audio._roar_id, audio._rush_id])
	# The loop's seam: the last frame flows into the first as any two frames do (filtered round the buffer).
	var d: PackedByteArray = roar.data
	var n := d.size() / 4
	var seam := absi(d.decode_s16(0) - d.decode_s16((n - 1) * 4))
	var typical := 0
	for i in range(1, 2001):
		typical = maxi(typical, absi(d.decode_s16(i * 4) - d.decode_s16((i - 1) * 4)))
	check(seam <= typical, "storm wind: no step at the roar's loop seam (%d, steps up to %d)" % [seam, typical])
	var s = audio.storm.get_script().new(99)
	var lo := 1.0
	var hi := 0.0
	var pitch_hi := 0.0
	for i in 3600:
		s.step(1.0 / 60.0, 1.1, 0.4)
		lo = minf(lo, s.gust)
		hi = maxf(hi, s.gust)
		pitch_hi = maxf(pitch_hi, s.roar_pitch)
	check(hi - lo > 0.5 and pitch_hi < 1.06, "storm wind: gusts swing (%.2f-%.2f over a minute), no pitch rise past 1.05 (%.3f)" % [lo, hi, pitch_hi])
	st.set_value("storm_wind", "classic", false)
	_iw_run(node, 3.0)
	check(audio._roar_id == 0 and audio._rush_id == 0 and audio._gusty_id > 0, "storm wind: Classic plays the whistle loop only")
	st.set_value("storm_wind", "new", false)
	check(audio.wind_arg(PackedStringArray(["--x", "--weather-wind=old"])) == "old" and audio.wind_arg(PackedStringArray()) == "",
		"storm wind: --weather-wind=old is read")


func _iw_run(node: Node, secs: float, step := 0.5) -> void:
	var t := 0.0
	while t < secs - 0.0001:
		var d := minf(step, secs - t)
		node._process(d)
		t += d


func _iw_visible(node: Node, child: String) -> bool:
	var n: Node = node.rain_fx.get_node_or_null(child)
	return n != null and bool((n as Node3D).visible)


## Immersive Weather Phase 2: rain presets, moisture ramp/drying/persistence, every rain/wetness/puddle
## setting, 3D drops + splashes, rain audio, and planet/platform gating.


func _immersive_weather_rain(host, node: Node, sfx: Node, fake) -> void:
	var presets = node.director.Presets
	var st = node.api.settings
	st.set_value("mode", "locked", false)
	st.set_value("transition_seconds", 2.0, false)
	st.set_value("cycle_minutes", 8.0, false)
	check(node.rain_fx != null and _iw_visible(node, "RainDrops") == false and _iw_visible(node, "RainSplashes") == false,
		"1.9 rain: add-on mounts RainDrops/RainSplashes (hidden while dry)")

	# --- Rain audio: 3 bundled loops decode cleanly. ---
	for nm in ["light", "steady", "heavy"]:
		var s := SoundBank.stream("addon:immersive-weather/sounds/rain-%s.ogg" % nm, true)
		check(s != null and s.get_length() > 10.0 and s.get_length() < 25.0,
			"1.9 rain: bundled rain-%s.ogg decodes cleanly (%s s)" % [nm, s.get_length() if s != null else 0.0])

	# --- All 12 presets. ---
	check(presets.ORDER.size() == 12 and presets.ORDER[0] == "open_skies" and presets.ORDER[9] == "heavy_downpour" and presets.ORDER[11] == "severe_thunderstorm",
		"1.9 rain: twelve presets from open_skies to severe_thunderstorm: %s" % [presets.ORDER])
	var rain_ids: Array = ["light_drizzle", "steady_rain", "heavy_downpour", "thunderstorm", "severe_thunderstorm"]
	for id: String in presets.ORDER:
		var p: Dictionary = presets.PRESETS[id]
		var is_rain := id in rain_ids
		var cat := str(p["category"])
		check((cat == "rain" or cat == "storm") == is_rain, "1.9 rain: preset %s category %s" % [id, cat])
		st.set_value("locked_weather", id, false)
		node.director.jump_to(id)
		_iw_run(node, 2.5)
		var spec: Dictionary = node.director.current_spec
		check(is_equal_approx(float(WeatherState.state.get("cloud_cover", -1.0)), float(p["cloud_cover"])),
			"1.9 rain: preset %s applies cloud_cover %s" % [id, WeatherState.state.get("cloud_cover")])
		check(is_equal_approx(float(spec["rain_intensity"]), float(p["rain_intensity"])) and (float(spec["rain_intensity"]) > 0.0) == is_rain,
			"1.9 rain: preset %s rain_intensity %s" % [id, spec["rain_intensity"]])
		check(_iw_visible(node, "RainDrops") == is_rain and _iw_visible(node, "RainSplashes") == is_rain,
			"1.9 rain: preset %s shows rain drops/splashes only when raining (%s/%s)" % [
				id, _iw_visible(node, "RainDrops"), _iw_visible(node, "RainSplashes")])
		var wet := _iw_wet()
		check((wet.x > 0.0) == is_rain and (wet.y > 0.0) == is_rain and (wet.z > 0.0) == (is_rain and float(p["target_puddles"]) > 0.0),
			"1.9 rain: preset %s wetness globals %s" % [id, wet])

	# --- Rain presets: instance counts per intensity/density. ---
	st.set_value("locked_weather", "heavy_downpour", false)
	node.director.jump_to("heavy_downpour")
	_iw_run(node, 3.0)
	var drops_mm: MultiMesh = node.rain_fx._drop_mm
	var splash_mm: MultiMesh = node.rain_fx._splash_mm
	check(drops_mm.visible_instance_count == int(3200 * 0.8) and splash_mm.visible_instance_count == 600,
		"1.9 rain: Heavy Downpour draws %d drops and a full splash buffer (%d)" % [drops_mm.visible_instance_count, splash_mm.visible_instance_count])
	st.set_value("rain_density", 0.5, false)
	_iw_run(node, 3.0)
	check(drops_mm.visible_instance_count == int(3200 * 0.4), "1.9 rain: rain_density 0.5 halves the drops (%d)" % drops_mm.visible_instance_count)
	st.set_value("rain_density", 2.0, false)
	_iw_run(node, 3.0)
	check(drops_mm.visible_instance_count == 3200, "1.9 rain: rain_density 2.0 draws the full 3200 drops (%d)" % drops_mm.visible_instance_count)
	st.set_value("rain_density", 1.0, false)
	st.set_value("locked_weather", "steady_rain", false)
	node.director.jump_to("steady_rain")
	_iw_run(node, 4.0)
	check(drops_mm.visible_instance_count == int(3200 * 0.65 * 0.8), "1.9 rain: Steady Rain draws %d drops" % drops_mm.visible_instance_count)
	st.set_value("locked_weather", "heavy_downpour", false)
	node.director.jump_to("heavy_downpour")
	_iw_run(node, 3.0)

	# --- Settings: rain, splashes, wetness, puddles, ripples. ---
	check(_iw_wet().w > 0.9 and _iw_wet().z > 0.8 and _iw_pud().w > 0.8, "1.9 rain: Heavy Downpour globals start strong %s %s" % [_iw_wet(), _iw_pud()])
	st.set_value("splashes_enabled", false, false)
	_iw_run(node, 1.5)
	check(_iw_visible(node, "RainDrops") and not _iw_visible(node, "RainSplashes") and float(node.director.current_spec["splash_rate"]) == 0.0,
		"1.9 rain: splashes_enabled off hides splashes only")
	st.set_value("splashes_enabled", true, false)
	st.set_value("splash_density", 2.0, false)
	_iw_run(node, 1.0)
	check(_iw_visible(node, "RainSplashes") and is_equal_approx(float(node.director.current_spec["splash_rate"]), 2.0),
		"1.9 rain: splash_density 2.0 doubles splash_rate")
	st.set_value("splash_density", 1.0, false)
	st.set_value("rain_ripples_enabled", false, false)
	node._process(0.1)
	check(_iw_wet().w == 0.0, "1.9 rain: ripples off zeroes ripple global")
	st.set_value("rain_ripples_enabled", true, false)
	st.set_value("rain_ripples_strength", 0.5, false)
	node._process(0.1)
	check(is_equal_approx(_iw_wet().w, 0.5), "1.9 rain: ripple strength 0.5 -> %s" % _iw_wet().w)
	st.set_value("rain_ripples_strength", 1.0, false)
	st.set_value("ground_wetness_enabled", false, false)
	node._process(0.1)
	check(_iw_wet().x == 0.0 and _iw_wet().y > 0.0, "1.9 rain: wet ground off keeps wet models %s" % _iw_wet())
	st.set_value("ground_wetness_enabled", true, false)
	st.set_value("model_wetness_enabled", false, false)
	node._process(0.1)
	check(_iw_wet().y == 0.0 and _iw_wet().x > 0.0, "1.9 rain: wet models off keeps wet ground %s" % _iw_wet())
	st.set_value("model_wetness_enabled", true, false)
	st.set_value("wetness_strength", 0.5, false)
	node._process(0.1)
	check(is_equal_approx(_iw_wet().x, 0.5) and is_equal_approx(_iw_wet().y, 0.5), "1.9 rain: wetness_strength 0.5 halves wetness %s" % _iw_wet())
	st.set_value("wetness_strength", 1.0, false)
	st.set_value("ground_puddles_enabled", false, false)
	node._process(0.1)
	check(_iw_wet().z == 0.0 and _iw_pud().w > 0.0, "1.9 rain: ground puddles off keeps model puddles")
	st.set_value("ground_puddles_enabled", true, false)
	st.set_value("puddle_amount", 0.5, false)
	node._process(0.1)
	check(is_equal_approx(_iw_wet().z, 0.45), "1.9 rain: puddle_amount 0.5 -> %s" % _iw_wet().z)
	st.set_value("puddle_amount", 1.0, false)
	st.set_value("model_puddles_enabled", false, false)
	node._process(0.1)
	check(_iw_pud().w == 0.0 and _iw_wet().z > 0.0, "1.9 rain: model puddles off keeps ground puddles")
	st.set_value("model_puddles_enabled", true, false)
	st.set_value("model_puddles_strength", 0.5, false)
	node._process(0.1)
	check(is_equal_approx(_iw_pud().w, 0.45), "1.9 rain: model_puddles_strength 0.5 -> %s" % _iw_pud().w)
	st.set_value("model_puddles_strength", 1.0, false)
	st.set_value("puddle_scale", 0.2, false)
	st.set_value("puddle_reflect", 1.2, false)
	st.set_value("wet_darken", 0.7, false)
	node._process(0.1)
	check(is_equal_approx(_iw_pud().x, 0.2) and is_equal_approx(_iw_pud().y, 1.2) and is_equal_approx(_iw_pud().z, 0.7),
		"1.9 rain: puddle size/reflect/darken reach the shader globals %s" % _iw_pud())
	st.set_value("puddle_scale", 0.12, false)
	st.set_value("puddle_reflect", 0.85, false)
	st.set_value("wet_darken", 0.45, false)
	st.set_value("rain_enabled", false, false)
	_iw_run(node, 3.0)
	check(not _iw_visible(node, "RainDrops") and not _iw_visible(node, "RainSplashes") and _iw_wet().w == 0.0
		and float(node.director.current_spec["rain_intensity"]) == 0.0 and _iw_wet().x > 0.0,
		"1.9 rain: rain off hides drops/splashes/ripples but the ground stays wet")
	st.set_value("rain_enabled", true, false)
	_iw_run(node, 3.0)
	check(_iw_visible(node, "RainDrops") and _iw_visible(node, "RainSplashes"), "1.9 rain: rain back on shows drops and splashes")

	# --- Moisture ramps up while it rains. ---
	st.set_value("locked_weather", "heavy_downpour", false)
	node.director.dry_now()
	check(node.director.ground_wetness == 0.0 and node.director.model_wetness == 0.0 and node.director.puddle_level == 0.0
		and _iw_wet().x == 0.0 and _iw_wet().y == 0.0 and _iw_wet().z == 0.0,
		"1.9 rain: dry_now() clears wetness and puddles at once %s" % _iw_wet())
	_iw_run(node, 12.0, 1.0)
	var d = node.director
	check(d.model_wetness > d.ground_wetness and d.ground_wetness > 0.2 and d.puddle_level > 0.0 and d.puddle_level < d.ground_wetness,
		"1.9 rain: models soak first, then ground, then puddles (m %.2f g %.2f p %.2f)" % [d.model_wetness, d.ground_wetness, d.puddle_level])
	_iw_run(node, 90.0, 5.0)
	check(is_equal_approx(d.model_wetness, 1.0) and is_equal_approx(d.ground_wetness, 1.0) and d.puddle_level > 0.7,
		"1.9 rain: sustained downpour soaks everything (m %.2f g %.2f p %.2f)" % [d.model_wetness, d.ground_wetness, d.puddle_level])

	# --- Post-rain drying: models faster than ground, ground faster than puddles. ---
	st.set_value("locked_weather", "sunny", false)
	st.set_value("dry_minutes", 4.0, false)
	d.current_id = "sunny"
	d.target_id = "sunny"
	d.blend_t = 1.0
	var m0: float = d.model_wetness
	var g0: float = d.ground_wetness
	var p0: float = d.puddle_level
	_iw_run(node, 60.0, 5.0)
	var lost_m: float = (m0 - d.model_wetness) / m0
	var lost_g: float = (g0 - d.ground_wetness) / g0
	var lost_p: float = (p0 - d.puddle_level) / p0
	check(lost_m > lost_g and lost_g > lost_p and lost_p > 0.0 and d.puddle_level > d.ground_wetness * 0.6,
		"1.9 rain: after rain models dry fastest, then ground, puddles linger (lost m %.2f g %.2f p %.2f)" % [lost_m, lost_g, lost_p])
	check(_iw_wet().z > 0.0 and _iw_pud().w > 0.0 and not _iw_visible(node, "RainDrops"),
		"1.9 rain: sunny puddles stay visible in the shader globals while the rain has stopped %s" % _iw_wet())
	_iw_run(node, 600.0, 10.0)
	check(d.model_wetness == 0.0 and d.ground_wetness == 0.0 and d.puddle_level == 0.0 and _iw_wet().z == 0.0,
		"1.9 rain: everything dries out eventually")

	# --- dry_now() mid-puddle and persistence across a restart. ---
	st.set_value("locked_weather", "heavy_downpour", false)
	d.jump_to("heavy_downpour")
	node._process(0.1)
	d.dry_now()
	check(d.puddle_level == 0.0 and _iw_wet().z == 0.0 and _iw_pud().w == 0.0, "1.9 rain: dry_now() zeroes puddle globals during rain")
	d.ground_wetness = 0.37
	d.model_wetness = 0.41
	d.puddle_level = 0.23
	d.save_state()
	host.game_ended()
	d.ground_wetness = 0.0
	d.model_wetness = 0.0
	d.puddle_level = 0.0
	host.game_started()
	await get_tree().process_frame
	d = node.director
	check(absf(d.ground_wetness - 0.37) < 0.005 and absf(d.model_wetness - 0.41) < 0.005 and absf(d.puddle_level - 0.23) < 0.005,
		"1.9 rain: moisture persists in api.storage across a restart (g %.2f m %.2f p %.2f)" % [d.ground_wetness, d.model_wetness, d.puddle_level])
	check(d.current_id == "heavy_downpour", "1.9 rain: restart keeps the saved weather %s" % d.current_id)

	# --- allow_rain filtering. ---
	st.set_value("mode", "dynamic", false)
	st.set_value("allow_rain", false, false)
	var leaked := 0
	for id: String in presets.ORDER:
		d.current_id = id
		for i in 40:
			if str(presets.PRESETS[d._pick_next()]["category"]) == "rain":
				leaked += 1
	check(leaked == 0, "1.9 rain: allow_rain off never picks a rain preset (%d leaks)" % leaked)
	d.current_id = "steady_rain"
	d.target_id = "steady_rain"
	d.blend_t = 1.0
	node._process(0.1)
	check(str(presets.PRESETS[d.target_id]["category"]) != "rain", "1.9 rain: allow_rain off moves away from a running rain preset (%s)" % d.target_id)
	st.set_value("allow_rain", true, false)
	d.current_id = "steady_rain"
	var got_rain := false
	for i in 120:
		if str(presets.PRESETS[d._pick_next()]["category"]) == "rain":
			got_rain = true
	check(got_rain, "1.9 rain: allow_rain on lets rain follow rain")
	st.set_value("mode", "locked", false)

	# --- Audio: rain loops play; Factorio audio falls back safely. ---
	st.set_value("locked_weather", "heavy_downpour", false)
	d.jump_to("heavy_downpour")
	_iw_run(node, 3.0)
	check(sfx.addon_loop_count("immersive-weather") >= 2, "1.9 rain: heavy rain plays wind + rain loops (%d)" % sfx.addon_loop_count("immersive-weather"))
	_iw_storm_wind(node, sfx, st)
	st.set_value("use_factorio_audio", true, false)
	_iw_run(node, 4.0)
	check(sfx.addon_loop_count("immersive-weather") >= 2, "1.9 rain: use_factorio_audio without Space Age falls back to the bundled rain (%d)" % sfx.addon_loop_count("immersive-weather"))
	st.set_value("use_factorio_audio", false, false)
	_iw_run(node, 2.0)
	st.set_value("audio_enabled", false, false)
	_iw_run(node, 2.0)
	check(sfx.addon_loop_count("immersive-weather") == 0, "1.9 rain: audio off stops the rain loops")
	st.set_value("audio_enabled", true, false)

	# --- Planet / platform gating. ---
	_iw_run(node, 2.0)
	check(_iw_visible(node, "RainDrops") and _iw_wet().x > 0.0, "1.9 rain: raining on Nauvis before leaving")
	fake._planet_sky.planet = "gleba"
	node._process(0.1)
	check(not _iw_visible(node, "RainDrops") and not _iw_visible(node, "RainSplashes") and _iw_wet() == Vector4.ZERO and node.rain_fx._drop_mm.visible_instance_count == 0,
		"1.9 rain: other planet hides rain and clears wetness/puddles")
	fake._planet_sky.planet = "nauvis"
	fake._space = true
	node._process(0.1)
	check(not _iw_visible(node, "RainDrops") and not _iw_visible(node, "RainSplashes") and _iw_wet() == Vector4.ZERO and _iw_pud().w == 0.0,
		"1.9 rain: space platform hides rain and clears wetness/puddles")
	fake._space = false
	_iw_run(node, 3.0)
	check(_iw_visible(node, "RainDrops") and _iw_wet().x > 0.0, "1.9 rain: rain resumes on returning to Nauvis")
	node.panel.refresh()
	check(node.director.status_text().contains("Wet"), "1.9 rain: status text reports wetness: " + node.director.status_text())


func _iw_clouds() -> Vector4:
	var v: Vector4 = WeatherState.last_globals["f3d_weather_clouds"]
	return v


## Immersive Weather Phase 3: thunderstorms, 3D lightning bolts, sky flashes, photosensitivity
## safety, speed-of-sound delayed thunder, optional camera rumble, thunder audio, and gating.


func _immersive_weather_storms(host, node: Node, _sfx: Node, fake) -> void:
	var presets = node.director.Presets
	var st = node.api.settings
	var d = node.director
	var lfx = node.lightning_fx
	check(lfx != null, "1.10 storm: lightning controller mounted")
	if lfx == null:
		return

	# --- 8 bundled thunder files decode cleanly (> 2 s each). ---
	for tpath: String in [
		"thunder-crack-1", "thunder-crack-2", "thunder-crack-3", "thunder-crack-4",
		"thunder-roll-1", "thunder-roll-2", "thunder-roll-3", "thunder-roll-4",
	]:
		var s := SoundBank.stream("addon:immersive-weather/sounds/%s.ogg" % tpath, true)
		check(s != null and s.get_length() > 2.0,
			"1.10 storm: bundled %s.ogg decodes cleanly (%s s)" % [tpath, s.get_length() if s != null else 0.0])

	# --- Storm presets & allow_storms filtering. ---
	st.set_value("mode", "locked", false)
	st.set_value("locked_weather", "severe_thunderstorm", false)
	d.jump_to("severe_thunderstorm")
	_iw_run(node, 0.2, 0.1)
	check(float(d.current_spec["lightning_rate"]) >= 0.99 and float(d.current_spec["storm_intensity"]) >= 0.99,
		"1.10 storm: Severe Thunderstorm activates lightning_rate and storm_intensity")

	st.set_value("mode", "dynamic", false)
	st.set_value("allow_storms", false, false)
	var storm_leaks := 0
	for id: String in presets.ORDER:
		d.current_id = id
		for i in 40:
			if str(presets.PRESETS[d._pick_next()]["category"]) == "storm":
				storm_leaks += 1
	check(storm_leaks == 0, "1.10 storm: allow_storms off never picks a storm preset (%d leaks)" % storm_leaks)
	d.current_id = "thunderstorm"
	d.target_id = "thunderstorm"
	d.blend_t = 1.0
	node._process(0.1)
	check(str(presets.PRESETS[d.target_id]["category"]) != "storm",
		"1.10 storm: allow_storms off transitions away from active storm (%s)" % d.target_id)
	st.set_value("allow_storms", true, false)
	st.set_value("mode", "locked", false)
	d.jump_to("severe_thunderstorm")
	_iw_run(node, 0.2, 0.1)

	# --- Hill height-aware 3D bolt, pooled OmniLight3D, sky flash global, and speed-of-sound queue. ---
	var h_img := Image.create(16, 16, false, Image.FORMAT_RF)
	h_img.fill(Color(4.5, 0.0, 0.0, 1.0))
	node.api.terrain.set_heights(h_img, Vector2(-128.0, -128.0), 16.0)
	lfx.clear()
	st.set_value("lightning_enabled", true, false)
	st.set_value("lightning_bolts_enabled", true, false)
	st.set_value("flash_brightness", 1.0, false)
	st.set_value("camera_rumble_enabled", true, false)
	st.set_value("camera_rumble_strength", 0.6, false)
	var strike_res: Dictionary = lfx.trigger_strike("bolt", Vector2(18.0, -12.0))
	node._process(0.016)
	var gpos: Vector3 = strike_res.get("pos", Vector3.ZERO)
	var expect_delay := clampf(Vector2(18.0, -12.0).length() / 32.0, 0.15, 5.5)
	check(str(strike_res.get("kind", "")) == "bolt" and lfx.bolts.size() == 1
		and lfx.active_light_count() == 1 and absf(gpos.y - 4.5) < 0.25
		and _iw_clouds().w > 0.2 and lfx.pending_thunder_count() == 1
		and is_equal_approx(float(strike_res.get("thunder_delay", 0.0)), expect_delay),
		"1.10 storm: 3D bolt spawns on hill height (%.2f), lights pool, raises flash (%.2f), queues %.2fs thunder" % [
			gpos.y, _iw_clouds().w, float(strike_res.get("thunder_delay", 0.0))])
	node.api.terrain.clear()

	# --- Speed-of-sound thunder triggers camera rumble then decays cleanly to zero. ---
	_iw_run(node, expect_delay + 0.1, 0.1)
	var mod_now: Dictionary = node.api.camera.modifier()
	var mod_off: Vector3 = mod_now["offset"]
	var mod_turn: Vector3 = mod_now["turn"]
	check(lfx.pending_thunder_count() == 0 and (mod_off != Vector3.ZERO or mod_turn != Vector3.ZERO),
		"1.10 storm: thunder fires after delay and nudges camera rumble (%s)" % mod_now)
	_iw_run(node, 4.0, 0.25)
	var mod_after: Dictionary = node.api.camera.modifier()
	check(mod_after["offset"] == Vector3.ZERO and mod_after["turn"] == Vector3.ZERO,
		"1.10 storm: camera rumble clears completely after decay")

	# --- Photosensitivity flash_brightness=0 & lightning_bolts_enabled=false & audio fallback. ---
	st.set_value("flash_brightness", 0.0, false)
	lfx.trigger_strike("bolt", Vector2(20.0, 0.0))
	node._process(0.016)
	check(_iw_clouds().w == 0.0, "1.10 storm: flash_brightness 0 keeps sky_flash at 0")
	st.set_value("flash_brightness", 0.75, false)

	lfx.clear()
	st.set_value("lightning_bolts_enabled", false, false)
	var sheet_res: Dictionary = lfx.trigger_strike("bolt", Vector2(20.0, 0.0))
	node._process(0.016)
	check(str(sheet_res.get("kind", "")) == "sheet" and lfx.bolts.is_empty() and _iw_clouds().w > 0.1,
		"1.10 storm: lightning_bolts_enabled off degrades cleanly to sheet flash")
	st.set_value("lightning_bolts_enabled", true, false)

	st.set_value("lightning_enabled", false, false)
	lfx.clear()
	var refused: Dictionary = lfx.trigger_strike("bolt", Vector2(15.0, 15.0))
	check(refused.is_empty() and lfx.bolts.is_empty() and lfx.pending_thunder_count() == 0,
		"1.10 storm: lightning off ignores trigger_strike")
	st.set_value("lightning_enabled", true, false)

	# --- Audio play_thunder safety (synthetic + Space Age opt-in without Space Age). ---
	st.set_value("use_factorio_audio", false, false)
	node.audio.play_thunder(40.0, 1.0)
	node.audio.play_thunder(110.0, 0.8)
	st.set_value("use_factorio_audio", true, false)
	node.audio.play_thunder(40.0, 1.0)
	st.set_value("use_factorio_audio", false, false)
	check(true, "1.10 storm: play_thunder close/distant paths and Space Age fallback succeed without errors")

	# --- Planet switch & space platform clear active bolts, lights, flash, and rumble. ---
	lfx.trigger_strike("bolt", Vector2(12.0, -8.0))
	node._process(0.016)
	check(lfx.bolts.size() >= 1 and lfx.active_light_count() >= 1, "1.10 storm: bolt active on Nauvis before gating check")
	fake._planet_sky.planet = "vulcanus"
	node._process(0.05)
	check(lfx.bolts.is_empty() and lfx.active_light_count() == 0 and _iw_clouds().w == 0.0
		and node.api.camera.modifier()["offset"] == Vector3.ZERO,
		"1.10 storm: non-Nauvis surface clears bolts, lights, sky flash, and camera rumble")
	fake._planet_sky.planet = "nauvis"
	node._process(0.05)
	lfx.trigger_strike("bolt", Vector2(12.0, -8.0))
	node._process(0.016)
	fake._space = true
	node._process(0.05)
	check(lfx.bolts.is_empty() and lfx.active_light_count() == 0 and _iw_clouds().w == 0.0,
		"1.10 storm: space platform clears bolts, lights, and sky flash")
	fake._space = false
	_iw_run(node, 0.2, 0.1)
	_immersive_weather_strikes(node)


## 1.91 timed strikes: api.world.tick / cue_tick, and Immersive Weather's strike list firing on the
## game's tick at its tile, the same bolt every run, random strikes off while it is loaded.


func _immersive_weather_strikes(node: Node) -> void:
	var lfx = node.lightning_fx
	var st = node.api.settings
	var d = node.director
	var tick0 := Bridge.server_tick
	var world = node.api.world
	Bridge.server_tick = 5000
	check(world.tick() == 5000 and world.smooth_tick() == 5000.0,
		"1.91: api.world.tick() and smooth_tick() give the game's tick in a game (%d, %.1f)" % [world.tick(), world.smooth_tick()])
	check(world.cue_tick() == -1 and AddonWorld.cue_from_args(PackedStringArray(["--cue-tick=1234"])) == 1234
		and AddonWorld.cue_from_args(PackedStringArray(["--cue-tick=soon"])) == -1,
		"1.91: api.world.cue_tick() -1 without --cue-tick; --cue-tick=1234 reads 1234, a non-number -1")
	check(lfx.strikes_arg(PackedStringArray(["--weather-strikes=a.json"]), "b.json") == "a.json"
		and lfx.strikes_arg(PackedStringArray(), " b.json ") == "b.json",
		"timed strikes: --weather-strikes wins over the Strike list setting")

	st.set_value("lightning_enabled", true, false)
	st.set_value("lightning_bolts_enabled", true, false)
	st.set_value("flash_brightness", 1.0, false)
	st.set_value("camera_rumble_enabled", false, false)
	st.set_value("mode", "locked", false)
	d.jump_to("severe_thunderstorm")
	lfx.clear()

	# Without a list: the random storm as before (a strike within 20 s of a severe storm).
	lfx.load_strikes("")
	var random_seen := false
	for i in 200:
		node._process(0.1)
		if not lfx.bolts.is_empty() or lfx.pending_thunder_count() > 0:
			random_seen = true
			break
	check(not lfx.has_strikes() and random_seen, "timed strikes: no list, random strikes still fall in a severe storm")
	lfx.clear()

	# The example file loads (relative to the add-on's folder).
	check(lfx.load_strikes("strikes-example.json") == "" and lfx.has_strikes() and lfx._strikes_offsets.size() == 4,
		"timed strikes: strikes-example.json loads its 4 strikes: " + lfx.strikes_error)

	var list := {"cue_tick": 6000, "strikes": [
		{"tick": 100, "x": 30.0, "y": 40.0, "kind": "bolt", "seed": 11},
		{"tick": 160, "x": -20.0, "y": 10.0, "kind": "sheet", "strength": 0.5},
		{"tick": -10, "x": 0.0, "y": 0.0},
		{"x": 1.0, "y": 2.0},
	]}
	var take := func() -> Dictionary:
		lfx.clear()
		check(lfx.set_strikes(list) == "", "timed strikes: the list loads")
		var out := {"before": -1, "at": -1, "paths": [], "ground": Vector3.ZERO, "random": 0, "sheet_at": -1, "past": true}
		# Ticks 5995..6099 (the entry at 5990 already past): nothing fires (and no random strike: a severe storm would strike in 20 s).
		for k in range(5995, 6100):
			Bridge.server_tick = k
			node._process(1.0 / 6.0)
			if not lfx.strikes_fired.is_empty() or not lfx.bolts.is_empty():
				out["before"] = k
				break
		Bridge.server_tick = 6100
		node._process(0.016)
		out["at"] = lfx.strikes_fired.size()
		if not lfx.bolts.is_empty():
			out["paths"] = lfx.bolts[0].paths.duplicate(true)
			out["ground"] = lfx.bolts[0].ground
		for k in range(6101, 6160):
			Bridge.server_tick = k
			node._process(0.016)
		out["random"] = lfx.strikes_fired.size()
		Bridge.server_tick = 6160
		node._process(0.016)
		out["sheet_at"] = lfx.strikes_fired.size()
		out["past"] = not lfx.strikes_fired.has(2)
		return out
	var a: Dictionary = take.call()
	check(a["before"] == -1, "timed strikes: nothing before the strike's tick, random strikes off while a list is loaded (fired at %d)" % a["before"])
	var ground: Vector3 = a["ground"]
	check(a["at"] == 1 and Vector2(ground.x, ground.z).distance_to(Vector2(30, 40)) < 0.01,
		"timed strikes: the bolt fires on cue + 100 at its tile (30, 40): %s" % [ground])
	check(a["random"] == 1 and a["sheet_at"] == 2 and a["past"],
		"timed strikes: nothing between, the sheet at cue + 160; the entry before the cue skipped (%d, %d)" % [a["random"], a["sheet_at"]])
	var b: Dictionary = take.call()
	var same := (a["paths"] as Array).size() > 0 and str(a["paths"]) == str(b["paths"])
	check(same, "timed strikes: the same bolt (shape and forks) on a second run (%d paths)" % (a["paths"] as Array).size())

	# Paused: the tick holds, nothing fires; the tick going back (the save loaded again) plays it again.
	lfx.clear()
	lfx.set_strikes(list)
	Bridge.server_tick = 6050
	node._process(0.016)
	for i in 60:
		node._process(0.1)
	check(lfx.strikes_fired.is_empty(), "timed strikes: a paused game (the tick holding at 6050) fires nothing in 6 s")
	Bridge.server_tick = 6100
	node._process(0.016)
	Bridge.server_tick = 6020
	node._process(0.016)
	Bridge.server_tick = 6100
	node._process(0.016)
	check(lfx.strikes_fired == [0, 0], "timed strikes: the tick going back plays the strike again (%s)" % [lfx.strikes_fired])
	# Loaded late: entries already past are skipped.
	lfx.clear()
	lfx.set_strikes(list)
	Bridge.server_tick = 6130
	node._process(0.016)
	Bridge.server_tick = 6160
	node._process(0.016)
	check(lfx.strikes_fired == [1], "timed strikes: loaded at 6130, the past bolt is skipped and the sheet fires (%s)" % [lfx.strikes_fired])
	# Photosensitivity: bolts off makes the listed bolt a sheet flash; lightning off fires nothing.
	lfx.clear()
	st.set_value("lightning_bolts_enabled", false, false)
	lfx.set_strikes(list)
	Bridge.server_tick = 6000
	node._process(0.016)
	Bridge.server_tick = 6100
	node._process(0.016)
	check(lfx.strikes_fired == [0] and lfx.bolts.is_empty(), "timed strikes: bolts off, the listed bolt is a sheet flash")
	st.set_value("lightning_bolts_enabled", true, false)
	lfx.clear()
	st.set_value("lightning_enabled", false, false)
	lfx.set_strikes(list)
	Bridge.server_tick = 6000
	node._process(0.016)
	Bridge.server_tick = 6100
	node._process(0.016)
	check(lfx.bolts.is_empty() and lfx.pending_thunder_count() == 0 and lfx.current_flash() == 0.0,
		"timed strikes: lightning off, listed strikes draw nothing")
	st.set_value("lightning_enabled", true, false)
	lfx.load_strikes("")
	lfx.clear()
	Bridge.server_tick = tick0
	_immersive_weather_timeline(node)


## 1.92 a cue the game sets while running (Bridge.cue_tick from `cue`, api.world.cue_tick before
## --cue-tick, api.cue_changed) and Immersive Weather's timeline: the `before` weather until the
## cue, each entry's change over its seconds of game time, the strike list waiting for the cue.
func _immersive_weather_timeline(node: Node) -> void:
	var d = node.director
	var lfx = node.lightning_fx
	var world = node.api.world
	var tick0 := Bridge.server_tick
	var cue0: int = Bridge.cue_tick
	var heard: Array = []
	var on_cue := func(t: int) -> void:
		heard.append(t)
	Bridge.cue_changed.connect(on_cue)
	Bridge._set_cue(7000)
	Bridge._set_cue(7000)
	check(Bridge.cue_tick == 7000 and world.cue_tick() == 7000 and AddonWorld.run_cue() == 7000 and heard == [7000],
		"1.92: a cue from the game (Bridge `cue`) is api.world.cue_tick(), told once (%s)" % [heard])
	Bridge._set_cue(-1)
	check(world.cue_tick() == -1 and heard == [7000, -1], "1.92: the cue cleared, cue_tick() falls back to --cue-tick (none: -1)")
	Bridge.cue_changed.disconnect(on_cue)
	check(node.api.has_signal("cue_changed") and is_equal_approx(node.api.level, 1.93), "1.92: api.cue_changed is there")

	check(d.timeline_arg(PackedStringArray(["--x", "--weather-timeline=t.json"])) == "t.json" and d.timeline_arg(PackedStringArray()) == "",
		"weather timeline: --weather-timeline=<file> read from the command line")
	check(d.load_timeline("timeline-example.json") == "" and d.timeline_before == "fair" and d.timeline.size() == 2,
		"weather timeline: timeline-example.json loads (fair before, 2 changes): " + d.timeline_error)
	check(d.set_timeline({"before": "drizzle?", "timeline": [{"at": 0, "weather": "thunderstorm"}]}) != ""
		and d.set_timeline({"timeline": [{"weather": "thunderstorm"}, {"at": 5, "weather": "nope"}]}) != "" and not d.has_timeline(),
		"weather timeline: an unknown weather or entries without at are refused")
	var tl := {"before": "fair", "timeline": [
		{"at": 600, "weather": "steady_rain", "over": 0},
		{"at": 0, "weather": "thunderstorm", "over": 6},
		{"at": 900, "weather": "nope", "over": 1},
	]}
	check(d.set_timeline(tl) == "" and d.timeline.size() == 2 and int(d.timeline[0]["at"]) == 0,
		"weather timeline: loads, sorted by at, the unknown weather left out")
	lfx.wait_for_cue = true
	lfx.set_strikes({"strikes": [{"tick": 120, "x": 5.0, "y": 5.0}]})
	var st = node.api.settings
	st.set_value("mode", "locked", false)
	st.set_value("locked_weather", "severe_thunderstorm", false)

	# Before the cue (none yet): `before`, whatever the settings lock, and the strikes wait.
	Bridge.server_tick = 5000
	_iw_run(node, 1.0, 0.1)
	check(d.current_id == "fair" and d.target_id == "fair" and d.blend_t == 1.0 and d.status_text().begins_with("Timeline"),
		"weather timeline: no cue yet, the before weather (fair) over the locked severe storm (%s -> %s)" % [d.current_id, d.target_id])
	check(lfx.strikes_cue == -1 and lfx.strikes_fired.is_empty(), "weather timeline: the strike list waits for the cue")
	var wet0: float = d.ground_wetness
	var rain_fair := float(d.current_spec.get("rain_intensity", -1.0))

	# The cue at 5000 (set while running): the storm builds over 6 s of game time.
	Bridge._set_cue(5000)
	node._process(0.016)
	check(d.current_id == "fair" and d.target_id == "thunderstorm" and d.blend_t < 0.01 and lfx.strikes_cue == 5000,
		"weather timeline: at the cue, fair -> thunderstorm starts; the strikes placed from the cue (%.2f, %d)" % [d.blend_t, lfx.strikes_cue])
	Bridge.server_tick = 5180
	node._process(0.5)
	var rain_mid := float(d.current_spec.get("rain_intensity", -1.0))
	check(d.blend_t > 0.3 and d.blend_t < 0.7 and rain_mid > rain_fair and d.ground_wetness > wet0,
		"weather timeline: half way through 6 s, blending and rain rising (%.2f, rain %.2f -> %.2f)" % [d.blend_t, rain_fair, rain_mid])
	Bridge.server_tick = 5360
	_iw_run(node, 1.0, 0.1)
	check(d.current_id == "thunderstorm" and d.target_id == "thunderstorm" and d.blend_t == 1.0,
		"weather timeline: after 6 s, arrived at thunderstorm (%s, %.2f)" % [d.current_id, d.blend_t])
	# The strike at cue + 120 already fired (at 5180, well past 5120); clearing or replacing drops it.
	check(lfx.strikes_fired.has(0), "weather timeline: the strike list fired after cue + 120 (%s)" % [lfx.strikes_fired])

	# At cue + 600 (over 0): steady rain at once.
	Bridge.server_tick = 5600
	node._process(0.016)
	check(d.current_id == "steady_rain" and d.target_id == "steady_rain" and d.blend_t == 1.0,
		"weather timeline: at cue + 600 with over 0, steady_rain at once (%s)" % d.current_id)

	# Cue goes away (-1): back to `before` and the strikes wait again.
	Bridge._set_cue(-1)
	_iw_run(node, 0.5, 0.1)
	check(d.current_id == "fair" and d.target_id == "fair" and lfx.strikes_cue == -1,
		"weather timeline: cue cleared, back to before (%s)" % d.current_id)

	# Clean up so later sections aren't left on a timeline.
	d.set_timeline({})
	d.timeline_error = ""
	lfx.wait_for_cue = false
	lfx.load_strikes("")
	lfx.clear()
	Bridge._set_cue(cue0)
	Bridge.server_tick = tick0


class FakeVehicleMovers extends Node:
	var protos := FakeProtos.new()
	var creatures = null
	var unit_id := 42
	var unit_type := "car"
	var proto_name := "tank"
	var unit_pos := Vector3.ZERO
	var unit_yaw := 0.0
	var unit_node := Node3D.new()

	func _init() -> void:
		add_child(unit_node)

	func units_of_type(t: String) -> Array:
		return [[unit_id, unit_node]] if t == unit_type else []

	func node_of(unit: int) -> Node3D:
		return unit_node if unit == unit_id else null

	func position_of(unit: int) -> Variant:
		return unit_pos if unit == unit_id else null

	func yaw_of(unit: int) -> float:
		return unit_yaw if unit == unit_id else 0.0

	func proto_name_of(unit: int) -> String:
		return proto_name if unit == unit_id else ""


class FakeDriverAvatar extends Node3D:
	var unit := 1
	var vehicle := 42


## Vehicle puddle splashes, directional terrain wake impulses, procedural puddle audio, and
## combined lightning + vehicle camera rumble.


func _iw_vehicle_puddles(node: Node, sfx: Node, fake) -> void:
	var st = node.api.settings
	var d = node.director
	var pfx = node.puddle_fx
	var lfx = node.lightning_fx
	check(pfx != null and node.puddle_audio != null,
		"vehicle puddles: puddle_fx and puddle_audio mounted")
	if pfx == null or node.puddle_audio == null:
		return
	check(pfx.MAX_SPLASH_PARTICLES == 1600,
		"vehicle puddles: MAX_SPLASH_PARTICLES == 1600 (%d)" % pfx.MAX_SPLASH_PARTICLES)

	# Ensure clean active Nauvis weather state.
	st.set_value("mode", "locked", false)
	st.set_value("locked_weather", "heavy_downpour", false)
	st.set_value("ground_puddles_enabled", true, false)
	st.set_value("puddle_amount", 1.0, false)
	st.set_value("puddle_scale", 0.12, false)
	st.set_value("vehicle_puddle_splashes_enabled", true, false)
	st.set_value("vehicle_puddle_splash_strength", 1.0, false)
	st.set_value("vehicle_puddle_rumble_enabled", true, false)
	st.set_value("vehicle_puddle_audio_enabled", true, false)
	d.jump_to("heavy_downpour")
	d.ground_wetness = 0.9
	d.puddle_level = 0.9
	pfx.clear()
	lfx.clear()
	node._process(0.05)

	# --- Test 1: WeatherState & api.weather puddle impulses ---
	WeatherState.clear_impulses()
	WeatherState.set_impulse_strength("immersive-weather", 1.0)
	var added_short: bool = node.api.weather.add_puddle_ripple(Vector2(12.0, -8.0), Vector2(1.0, 0.0), 2.5, 0.9, 0.4)
	var added_long: bool = node.api.weather.add_puddle_ripple(Vector2(18.0, -4.0), Vector2(0.0, 1.0), 2.0, 0.8, 2.0)
	WeatherState.advance(0.05, false)
	var imp_info: Vector4 = WeatherState.last_globals["f3d_weather_impulse_info"]
	var imp_bounds: Vector4 = WeatherState.last_globals["f3d_weather_impulse_bounds"]
	check(added_short and added_long and int(roundf(imp_info.x)) == 2 and is_equal_approx(imp_info.w, 1.0)
		and imp_bounds.x < imp_bounds.z and imp_bounds.y < imp_bounds.w,
		"vehicle puddles (1): add_puddle_ripple pushes active impulse info & padded bounds (%s, %s)" % [imp_info, imp_bounds])

	# Compaction after short impulse expires, then full deactivation after long impulse expires.
	WeatherState.advance(0.55, false)
	var imp_mid: Vector4 = WeatherState.last_globals["f3d_weather_impulse_info"]
	check(WeatherState.active_impulse_count() == 1 and int(roundf(imp_mid.x)) == 1 and is_equal_approx(imp_mid.w, 1.0),
		"vehicle puddles (1): advancing past short life compacts impulses cleanly (%s)" % imp_mid)
	WeatherState.advance(1.6, false)
	var imp_end: Vector4 = WeatherState.last_globals["f3d_weather_impulse_info"]
	check(WeatherState.active_impulse_count() == 0 and imp_end.x == 0.0 and imp_end.w == 0.0,
		"vehicle puddles (1): advancing past all lives deactivates impulses cleanly (%s)" % imp_end)

	# Space platform suppression and clear_puddle_ripples() / clear() cleanup.
	node.api.weather.add_puddle_ripple(Vector2(10.0, 5.0), Vector2(1.0, 0.0), 2.2, 1.0, 3.0)
	WeatherState.advance(0.05, true)
	var sp_info: Vector4 = WeatherState.last_globals["f3d_weather_impulse_info"]
	var sp_bounds: Vector4 = WeatherState.last_globals["f3d_weather_impulse_bounds"]
	check(sp_info.x == 0.0 and sp_info.w == 0.0 and sp_bounds == Vector4.ZERO,
		"vehicle puddles (1): space platform zeroes impulse info & bounds")
	WeatherState.advance(0.05, false)
	node.api.weather.clear_puddle_ripples()
	var clr_info: Vector4 = WeatherState.last_globals["f3d_weather_impulse_info"]
	var clr_bounds: Vector4 = WeatherState.last_globals["f3d_weather_impulse_bounds"]
	check(WeatherState.active_impulse_count() == 0 and clr_info.x == 0.0 and clr_info.w == 0.0 and clr_bounds == Vector4.ZERO,
		"vehicle puddles (1): clear_puddle_ripples() clears impulses and globals")

	node.api.weather.add_puddle_ripple(Vector2(10.0, 5.0), Vector2(1.0, 0.0), 2.2, 1.0, 3.0)
	WeatherState.advance(0.05, false)
	node.api.weather.clear()
	var wx_clr_info: Vector4 = WeatherState.last_globals["f3d_weather_impulse_info"]
	check(not node.api.weather.is_on() and WeatherState.active_impulse_count() == 0
		and wx_clr_info.x == 0.0 and wx_clr_info.w == 0.0,
		"vehicle puddles (1): api.weather.clear() zeroes impulses cleanly")
	d.jump_to("heavy_downpour")
	d.ground_wetness = 0.9
	d.puddle_level = 0.9
	node._process(0.05)

	# Refusal when splashes_disabled or disabled is set (restoring flags afterwards).
	var was_splashes_disabled: bool = WeatherState.splashes_disabled
	var was_weather_disabled: bool = WeatherState.disabled
	WeatherState.splashes_disabled = true
	var refused_spl: bool = node.api.weather.add_puddle_ripple(Vector2(5.0, 5.0), Vector2.RIGHT, 2.0, 1.0, 1.0)
	check(not refused_spl and WeatherState.active_impulse_count() == 0,
		"vehicle puddles (1): splashes_disabled=true refuses add_puddle_ripple")
	WeatherState.splashes_disabled = was_splashes_disabled
	WeatherState.disabled = true
	var refused_wx: bool = node.api.weather.add_puddle_ripple(Vector2(5.0, 5.0), Vector2.RIGHT, 2.0, 1.0, 1.0)
	check(not refused_wx and WeatherState.active_impulse_count() == 0,
		"vehicle puddles (1): WeatherState.disabled=true refuses add_puddle_ripple")
	WeatherState.disabled = was_weather_disabled

	# --- Test 2: weather_puddles.gd CPU sampler, vehicle tracking & splash emission ---
	check(pfx.puddle_depth_at(10.0, 10.0, 0.0, 0.12, 1.0) == 0.0,
		"vehicle puddles (2): puddle_depth_at returns 0.0 when puddle_amount == 0.0")
	var focus: Vector2 = node.api.world.focus()
	var puddle_pt := Vector2.INF
	var dry_pt := Vector2.INF
	for gx in range(-24, 25):
		for gz in range(-24, 25):
			var px := focus.x + float(gx)
			var pz := focus.y + float(gz)
			var depth := float(pfx.puddle_depth_at(px, pz, 0.9, 0.12, 1.0))
			if puddle_pt == Vector2.INF and depth >= 0.25:
				puddle_pt = Vector2(px, pz)
			if dry_pt == Vector2.INF:
				var all_dry := true
				for em: Vector2 in pfx.TANK_EMITTERS:
					var ed := float(pfx.puddle_depth_at(px + em.x, pz + em.y, 0.9, 0.12, 1.0))
					if ed >= 0.10:
						all_dry = false
						break
				if all_dry:
					dry_pt = Vector2(px, pz)
			if puddle_pt != Vector2.INF and dry_pt != Vector2.INF:
				break
		if puddle_pt != Vector2.INF and dry_pt != Vector2.INF:
			break
	check(puddle_pt != Vector2.INF and dry_pt != Vector2.INF,
		"vehicle puddles (2): deterministic scan finds deep puddle %s and dry start %s" % [puddle_pt, dry_pt])

	var prev_movers = fake.movers
	var prev_avatar = fake.avatar
	var fake_movers := FakeVehicleMovers.new()
	add_child(fake_movers)
	fake.movers = fake_movers
	var driver := FakeDriverAvatar.new()
	add_child(driver)
	if prev_avatar is Node3D:
		driver.global_position = (prev_avatar as Node3D).global_position
	fake.avatar = driver

	if puddle_pt != Vector2.INF and dry_pt != Vector2.INF:
		# Place tank at dry_pt to initialize track cleanly without emitting.
		pfx.clear()
		WeatherState.clear_impulses()
		fake_movers.unit_pos = Vector3(dry_pt.x, 0.0, dry_pt.y)
		node._process(0.05)
		var splashes_node := pfx.get_node_or_null("VehicleSplashes") as MultiMeshInstance3D
		check(splashes_node != null and not splashes_node.visible and WeatherState.active_impulse_count() == 0,
			"vehicle puddles (2): initial vehicle placement seeds without emitting")

		# Drive tank in <6-tile steps from dry_pt so its bow emitter enters puddle_pt at speed.
		var target_center := puddle_pt + Vector2(0.0, 1.45)
		var total_dist := dry_pt.distance_to(target_center)
		var step_count := maxi(1, int(ceilf(total_dist / 1.5)))
		var saw_splashes := false
		var saw_impulses := false
		var saw_rumble := false
		for i in range(1, step_count + 1):
			var t := float(i) / float(step_count)
			var next_pos := dry_pt.lerp(target_center, t)
			var step_d := Vector2(fake_movers.unit_pos.x, fake_movers.unit_pos.z).distance_to(next_pos)
			var dt := maxf(step_d / 10.0, 0.05)
			fake_movers.unit_pos = Vector3(next_pos.x, 0.0, next_pos.y)
			node._process(dt)
			if splashes_node != null and splashes_node.visible and splashes_node.multimesh.visible_instance_count > 0:
				saw_splashes = true
			if WeatherState.active_impulse_count() > 0:
				saw_impulses = true
			if pfx.rumble_offset() != Vector3.ZERO:
				saw_rumble = true
		check(saw_splashes and saw_impulses and saw_rumble,
			"vehicle puddles (2): driving tank into puddle emits splashes (%s), impulses (%s), and entry rumble (%s)" % [
				saw_splashes, saw_impulses, saw_rumble])

		# Slow tank cruising (~1.5 tiles/s, below old 2.2 threshold) still triggers splashes & wake impulses.
		pfx.clear()
		WeatherState.clear_impulses()
		fake_movers.unit_pos = Vector3(dry_pt.x, 0.0, dry_pt.y)
		node._process(0.05)
		var slow_steps := maxi(1, int(ceilf(total_dist / 0.35)))
		var slow_splashes := false
		var slow_impulses := false
		for i in range(1, slow_steps + 1):
			var t := float(i) / float(slow_steps)
			var next_pos := dry_pt.lerp(target_center, t)
			var step_d := Vector2(fake_movers.unit_pos.x, fake_movers.unit_pos.z).distance_to(next_pos)
			var slow_dt := maxf(step_d / 1.5, 0.016)
			fake_movers.unit_pos = Vector3(next_pos.x, 0.0, next_pos.y)
			node._process(slow_dt)
			if splashes_node != null and splashes_node.visible and splashes_node.multimesh.visible_instance_count > 0:
				slow_splashes = true
			if WeatherState.active_impulse_count() > 0:
				slow_impulses = true
		check(slow_splashes and slow_impulses,
			"vehicle puddles (2): slow tank (~1.5 tiles/s) entering puddle triggers splashes (%s) and wake impulses (%s)" % [
				slow_splashes, slow_impulses])

		# Dry ground check: puddle_amount = 0.0 produces 0 puddle impulses.
		pfx.clear()
		WeatherState.clear_impulses()
		d.puddle_level = 0.0
		d.ground_wetness = 0.2
		node._process(0.05)
		fake_movers.unit_pos = Vector3(puddle_pt.x, 0.0, puddle_pt.y + 1.45)
		node._process(0.05)
		fake_movers.unit_pos = Vector3(puddle_pt.x, 0.0, puddle_pt.y - 0.55)
		node._process(0.2)
		check(WeatherState.active_impulse_count() == 0,
			"vehicle puddles (2): dry ground (puddle_amount=0) produces 0 puddle impulses (%d)" % WeatherState.active_impulse_count())

		# Teleport guard (> 6.0 tile jump resets without emitting even onto a deep puddle).
		d.puddle_level = 0.9
		d.ground_wetness = 0.9
		node._process(0.05)
		pfx.clear()
		WeatherState.clear_impulses()
		fake_movers.unit_pos = Vector3(dry_pt.x, 0.0, dry_pt.y)
		node._process(0.05)
		var jump_pt := target_center
		if dry_pt.distance_to(jump_pt) <= 6.2:
			jump_pt = dry_pt + Vector2(8.0, 0.0)
		var head_before: int = pfx._spawn_head
		fake_movers.unit_pos = Vector3(jump_pt.x, 0.0, jump_pt.y)
		node._process(0.1)
		check(WeatherState.active_impulse_count() == 0 and pfx._spawn_head == head_before,
			"vehicle puddles (2): >6 tile teleport resets without emitting particles or ripples")

		# Drive again into puddle_pt to verify disable & clear() cleanup.
		pfx.clear()
		WeatherState.clear_impulses()
		fake_movers.unit_pos = Vector3(dry_pt.x, 0.0, dry_pt.y)
		node._process(0.05)
		for i in range(1, step_count + 1):
			var t := float(i) / float(step_count)
			var next_pos := dry_pt.lerp(target_center, t)
			var step_d := Vector2(fake_movers.unit_pos.x, fake_movers.unit_pos.z).distance_to(next_pos)
			fake_movers.unit_pos = Vector3(next_pos.x, 0.0, next_pos.y)
			node._process(maxf(step_d / 10.0, 0.05))
		check(splashes_node != null and splashes_node.visible and WeatherState.active_impulse_count() > 0,
			"vehicle puddles (2): splashes and impulses active before disable/clear check")
		st.set_value("vehicle_puddle_splashes_enabled", false, false)
		_iw_run(node, 1.35, 0.25)
		var dis_info: Vector4 = WeatherState.last_globals["f3d_weather_impulse_info"]
		check(splashes_node != null and not splashes_node.visible
			and splashes_node.multimesh.visible_instance_count == 0 and is_equal_approx(dis_info.z, 0.0),
			"vehicle puddles (2): disabling vehicle_puddle_splashes_enabled hides splashes and zeroes ripple strength")

		st.set_value("vehicle_puddle_splashes_enabled", true, false)
		pfx.clear()
		var was_wx_dis: bool = WeatherState.disabled
		WeatherState.disabled = true
		fake_movers.unit_pos = Vector3(dry_pt.x, 0.0, dry_pt.y)
		node._process(0.05)
		for i in range(1, step_count + 1):
			var t := float(i) / float(step_count)
			var next_pos := dry_pt.lerp(target_center, t)
			var step_d := Vector2(fake_movers.unit_pos.x, fake_movers.unit_pos.z).distance_to(next_pos)
			fake_movers.unit_pos = Vector3(next_pos.x, 0.0, next_pos.y)
			node._process(maxf(step_d / 10.0, 0.05))
		check(splashes_node != null and not splashes_node.visible
			and splashes_node.multimesh.visible_instance_count == 0 and WeatherState.active_impulse_count() == 0,
			"vehicle puddles (2): --addon-weather=off disables weather_puddles emissions")
		WeatherState.disabled = was_wx_dis

		pfx.clear()
		fake_movers.unit_pos = Vector3(dry_pt.x, 0.0, dry_pt.y)
		node._process(0.05)
		for i in range(1, step_count + 1):
			var t := float(i) / float(step_count)
			var next_pos := dry_pt.lerp(target_center, t)
			var step_d := Vector2(fake_movers.unit_pos.x, fake_movers.unit_pos.z).distance_to(next_pos)
			fake_movers.unit_pos = Vector3(next_pos.x, 0.0, next_pos.y)
			node._process(maxf(step_d / 10.0, 0.05))
		pfx.clear()
		check(splashes_node != null and not splashes_node.visible
			and splashes_node.multimesh.visible_instance_count == 0 and WeatherState.active_impulse_count() == 0,
			"vehicle puddles (2): puddle_fx.clear() hides VehicleSplashes and clears impulses")

	fake.avatar = prev_avatar
	fake.movers = prev_movers
	driver.queue_free()
	fake_movers.queue_free()

	# --- Test 3: puddle_audio.gd ---
	var pa = node.puddle_audio
	pa.make_now()
	var spray: AudioStreamWAV = pa.spray_loop
	var spray_ok: bool = (
		spray != null and spray.stereo
		and spray.loop_mode == AudioStreamWAV.LOOP_FORWARD
		and spray.data.size() > 0
	)
	check(spray_ok, "vehicle puddles (3): puddle_audio.make_now() creates stereo LOOP_FORWARD spray_loop")
	if spray_ok:
		var pd: PackedByteArray = spray.data
		var pn: int = pd.size() / 4
		var p_seam: int = absi(pd.decode_s16(0) - pd.decode_s16((pn - 1) * 4))
		var p_typical := 0
		for i in range(1, mini(pn, 2001)):
			p_typical = maxi(p_typical, absi(pd.decode_s16(i * 4) - pd.decode_s16((i - 1) * 4)))
		check(p_seam <= p_typical,
			"vehicle puddles (3): spray_loop has smooth loop seam (%d <= %d)" % [p_seam, p_typical])

	var heavy_ok: bool = pa.impacts_heavy.size() == 3
	for h_wav: Variant in pa.impacts_heavy:
		var hw := h_wav as AudioStreamWAV
		if hw == null or hw.data.is_empty():
			heavy_ok = false
	var light_ok: bool = pa.impacts_light.size() == 3
	for l_wav: Variant in pa.impacts_light:
		var lw := l_wav as AudioStreamWAV
		if lw == null or lw.data.is_empty():
			light_ok = false
	check(heavy_ok and light_ok,
		"vehicle puddles (3): impacts_heavy (3) and impacts_light (3) hold valid AudioStreamWAV data")

	node.audio.stop_all()
	sfx._process(1.0)
	pa.update_spray(true, Vector3(10.0, 0.0, 5.0), 0.9, 0.8, true, 1.0)
	var loops_playing: int = sfx.addon_loop_count("immersive-weather")
	var active_id: int = pa._spray_id
	pa.stop_all()
	check(active_id > 0 and loops_playing >= 1 and pa._spray_id == 0
		and sfx.addon_loop_count("immersive-weather") == 0,
		"vehicle puddles (3): update_spray + stop_all() leaves 0 loops (%d -> %d, id %d -> %d)" % [
			loops_playing, sfx.addon_loop_count("immersive-weather"), active_id, pa._spray_id])

	# --- Test 4: Combined camera rumble ---
	lfx.clear()
	pfx.clear()
	st.set_value("lightning_enabled", true, false)
	st.set_value("camera_rumble_enabled", true, false)
	st.set_value("camera_rumble_strength", 0.6, false)
	var ext_off := Vector3(0.02, -0.01, 0.0)
	var ext_turn := Vector3(0.001, 0.0, -0.001)
	lfx.external_offset = ext_off
	lfx.external_turn = ext_turn
	lfx.update(0.016, true, d.current_spec)
	var mod_ext: Dictionary = node.api.camera.modifier()
	check((mod_ext["offset"] as Vector3).is_equal_approx(ext_off)
		and (mod_ext["turn"] as Vector3).is_equal_approx(ext_turn),
		"vehicle puddles (4): external_offset/turn flow into api.camera.modifier()")

	var l_res: Dictionary = lfx.trigger_strike("bolt", Vector2(10.0, 0.0))
	var l_delay := float(l_res.get("thunder_delay", 0.5))
	var t_elapsed := 0.0
	while t_elapsed < l_delay + 0.15:
		lfx.external_offset = ext_off
		lfx.external_turn = ext_turn
		lfx.update(0.05, true, d.current_spec)
		t_elapsed += 0.05
	var mod_combo: Dictionary = node.api.camera.modifier()
	var combo_off: Vector3 = mod_combo["offset"]
	var combo_turn: Vector3 = mod_combo["turn"]
	check(combo_off != Vector3.ZERO and not combo_off.is_equal_approx(ext_off)
		and combo_turn != Vector3.ZERO and not combo_turn.is_equal_approx(ext_turn),
		"vehicle puddles (4): lightning rumble combines with external_offset without clobbering (%s)" % mod_combo)

	lfx.clear()
	var mod_cleared: Dictionary = node.api.camera.modifier()
	check(mod_cleared["offset"] == Vector3.ZERO and mod_cleared["turn"] == Vector3.ZERO,
		"vehicle puddles (4): lfx.clear() clears combined camera modifier cleanly")
	lfx.external_offset = Vector3.ZERO
	lfx.external_turn = Vector3.ZERO
	lfx.update(0.016, true, d.current_spec)
	var mod_idle: Dictionary = node.api.camera.modifier()
	check(mod_idle["offset"] == Vector3.ZERO and mod_idle["turn"] == Vector3.ZERO,
		"vehicle puddles (4): idle update keeps camera modifier cleared")


class FakeEnemiesFx extends Node:
	var on_damaged_hook := Callable()
	var weapons = null


class FakeEnemiesWorld extends FakeWorld:
	var animator = null


## Immersive Enemies add-on (addons-src/immersive-enemies/): API 1.9 manifest, settings,
## biter-only damage/death interception, pooled ragdolls + 6-leg springs, gore droplets/decals/gibs,
## slimy swamp-green acid goo streams/splashes/pools, live animation overrides, and clean teardown.


func _immersive_enemies(fake) -> void:
	const CreaturesScript := preload("res://scripts/world/creatures.gd")
	const AnimScript := preload("res://scripts/world/anim.gd")
	const SpriteFxScript := preload("res://scripts/fx/sprite_fx.gd")
	const WeaponFxScript := preload("res://scripts/fx/weapon_fx.gd")
	const ModelLib := preload("res://scripts/world/model_library.gd")
	const ModelPacks := preload("res://scripts/world/model_packs.gd")
	var src := ProjectSettings.globalize_path("res://").path_join("../addons-src/immersive-enemies").simplify_path()
	if not DirAccess.dir_exists_absolute(src):
		check(false, "immersive enemies: the add-on's folder is at " + src)
		return

	var prev_movers = fake.movers
	var owned_movers: FakeMovers = null
	if fake.movers == null:
		owned_movers = FakeMovers.new()
		add_child(owned_movers)
		fake.movers = owned_movers
	var prev_creatures = fake.movers.creatures
	var prev_fx = fake.fx
	var prev_world = fake.world
	var owned_world := FakeEnemiesWorld.new()
	add_child(owned_world)
	var anim := AnimScript.new()
	add_child(anim)
	owned_world.animator = anim
	fake.world = owned_world
	var cr := CreaturesScript.new()
	add_child(cr)
	fake.movers.creatures = cr
	var fake_sprites := SpriteFxScript.new()
	add_child(fake_sprites)
	var fake_weapons := WeaponFxScript.new()
	fake_weapons.sprites = fake_sprites
	add_child(fake_weapons)
	var fake_fx := FakeEnemiesFx.new()
	fake_fx.weapons = fake_weapons
	add_child(fake_fx)
	fake.fx = fake_fx

	Settings.set_value("addons", "immersive-enemies", true)
	var host := AddonHost.new()
	host.autoload = false
	host.main = fake
	add_child(host)
	host.load_all([[src.get_base_dir(), "test"]])
	await get_tree().process_frame

	var m := host.find("immersive-enemies")
	var node: Node = m.get("node")
	check(node != null and str(m.get("id", "")) == "immersive-enemies"
		and is_equal_approx(float(m.get("api", 0.0)), 1.9),
		"immersive enemies: manifest (api 1.9) loads and starts cleanly: " + str(m.get("error", m.get("problem", ""))))
	if node == null:
		Settings.reset_value("addons", "immersive-enemies")
		host.queue_free()
		fake.movers.creatures = prev_creatures
		fake.movers = prev_movers
		if owned_movers != null:
			owned_movers.queue_free()
		fake.fx = prev_fx
		fake.world = prev_world
		anim.queue_free()
		owned_world.queue_free()
		cr.queue_free()
		fake_weapons.reset()
		fake_fx.queue_free()
		fake_weapons.queue_free()
		fake_sprites.queue_free()
		return

	host.game_started()
	await get_tree().process_frame
	# The checks below fire several deaths with no frame between them, each checked at once: the
	# all-at-once path (0.1.2 would spread the third onwards over frames; tests/enemies_burst_probe.gd).
	check(bool(node.burst_spread), "immersive enemies: spreads death bursts over frames by default (0.1.2)")
	node.burst_spread = false
	check(cr.on_died_hook.is_valid() and fake_fx.on_damaged_hook.is_valid()
		and fake_weapons.on_stream_hook.is_valid() and fake_weapons.on_ground_hook.is_valid()
		and cr._anim_enabled,
		"immersive enemies: game_started wires died/damaged/stream/ground hooks and enables live anim path")

	# Reworked enemy models toggle sets transient runtime overrides for Placeholders without writing settings.cfg.
	check(str(ModelLib.addon_pack_overrides.get("big-biter", "")) == "builtin:placeholders"
		and str(ModelLib.addon_pack_overrides.get("big-spitter", "")) == "builtin:placeholders"
		and str(ModelLib.addon_pack_overrides.get("biter-spawner", "")) == "builtin:placeholders"
		and ModelPacks.choice("big-biter") == "" and ModelPacks.choice("big-spitter") == ""
		and ModelPacks.choice("biter-spawner") == "",
		"immersive enemies: use_reworked_biters sets transient builtin:placeholders overrides without touching player choices")
	check(ModelLib.source_of("small-biter").contains("placeholders/big-biter.glb")
		and ModelLib.source_of("big-biter").contains("placeholders/big-biter.glb")
		and ModelLib.source_of("behemoth-biter").contains("placeholders/big-biter.glb")
		and ModelLib.source_of("big-spitter").contains("placeholders/big-spitter.glb")
		and ModelLib.source_of("biter-spawner").contains("placeholders/biter-spawner.glb"),
		"immersive enemies: biter, spitter, and spawner tiers resolve to reworked Placeholders models while active")

	# Synchronously warm reworked Placeholders enemy meshes so ModelLib.ready(...) and all ragdoll/split paths execute.
	var mesh_small: Mesh = ModelLib.mesh_for("small-biter")
	var mesh_big: Mesh = ModelLib.mesh_for("big-biter")
	var mesh_behemoth: Mesh = ModelLib.mesh_for("behemoth-biter")
	var mesh_spitter: Mesh = ModelLib.mesh_for("big-spitter")
	var mesh_worm: Mesh = ModelLib.mesh_for("big-worm-turret")
	var mesh_spawner: Mesh = ModelLib.mesh_for("biter-spawner")
	var mesh_spawner_corpse: Mesh = ModelLib.mesh_for("biter-spawner-corpse")
	var model_ready: bool = (
		ModelLib.ready("small-biter") and ModelLib.ready("big-biter") and ModelLib.ready("behemoth-biter")
		and ModelLib.ready("big-spitter") and ModelLib.ready("big-worm-turret")
		and ModelLib.ready("biter-spawner") and ModelLib.ready("biter-spawner-corpse")
		and mesh_small != null and mesh_big != null and mesh_behemoth != null
		and mesh_spitter != null and mesh_worm != null and mesh_spawner != null and mesh_spawner_corpse != null
	)
	check(model_ready, "immersive enemies: reworked Placeholders biter, spitter, worm, and spawner meshes load synchronously")

	# Add live units so list_live + biter_anim + set_unit_wounds + Creatures.remove exercise real paths.
	var b1_node := Node3D.new()
	b1_node.position = Vector3(12.0, 0.0, 8.0)
	add_child(b1_node)
	cr.add(1001, "small-biter", b1_node, -1)

	var b2_node := Node3D.new()
	b2_node.position = Vector3(14.0, 0.0, 9.0)
	add_child(b2_node)
	cr.add(1002, "big-biter", b2_node, -1)

	var b4_node := Node3D.new()
	b4_node.position = Vector3(18.0, 0.0, 12.0)
	add_child(b4_node)
	cr.add(1004, "big-biter", b4_node, -1)

	var b5_node := Node3D.new()
	b5_node.position = Vector3(22.0, 0.0, 14.0)
	add_child(b5_node)
	cr.add(1005, "big-biter", b5_node, -1)

	# Non-Nauvis creature (Gleba wriggler) damage & death should NOT be intercepted.
	var wrig_dmg := {"unit": 1099, "name": "small-wriggler-pentapod", "pos": Vector3(8.0, 0.0, 8.0),
		"cause_pos": Vector3(2.0, 0.0, 8.0), "damage_type": "physical", "fx": "blood",
		"dmg": 120, "hp": 880, "src": "firearm-magazine"}
	fake_fx.on_damaged_hook.call(wrig_dmg)
	var wrig_die := {"unit": 1099, "name": "small-wriggler-pentapod", "pos": Vector3(8.0, 0.0, 8.0),
		"yaw": 0.0, "vel": Vector3.ZERO, "scale": 0.5, "phase": 0.0,
		"cause_pos": Vector3(2.0, 0.0, 8.0), "damage_type": "physical", "dmg": 120, "src": "", "handled": false}
	cr.on_died_hook.call(wrig_die)
	check(not bool(wrig_die.get("handled", false)),
		"immersive enemies: leaves unsupported creatures (small-wriggler-pentapod) untouched")

	# Live biter hit -> hit-flinch override, gore droplets, live set_unit_wounds state, and ragdoll wound inheritance.
	fake_fx.on_damaged_hook.call({"unit": 1001, "name": "small-biter", "pos": b1_node.position,
		"cause_pos": Vector3(4.0, 0.0, 8.0), "damage_type": "physical", "fx": "blood",
		"dmg": 250, "hp": 750, "src": "piercing-rounds-magazine"})
	node._process(0.05)
	check(cr._overrides.has(1001) and cr._wounds.has(1001) and float(cr._wounds[1001]) < 0.0,
		"immersive enemies: live hit registers flinch override and negative packed live wound state")

	# Direct API verification of make_ragdoll_part_node + biter_inner_meat cap + make_ragdoll_leg_node across models.
	var all_parts_ok := true
	for proto_check in ["big-biter", "big-spitter", "big-worm-turret", "biter-spawner"]:
		for pname in ["head", "thorax", "abdomen"]:
			var part_probe: MeshInstance3D = node.api.creatures.make_ragdoll_part_node(proto_check, pname)
			var has_meat := false
			if part_probe != null and part_probe.mesh != null and part_probe.has_meta(&"part_centroid"):
				for si in part_probe.mesh.get_surface_count():
					var sm: Material = part_probe.mesh.surface_get_material(si)
					if sm != null and sm.resource_name == "biter_inner_meat":
						has_meat = true
				part_probe.free()
			else:
				if part_probe != null:
					part_probe.free()
				all_parts_ok = false
			if not has_meat:
				all_parts_ok = false
	var all_legs_ok := true
	for li in 6:
		var lp: MeshInstance3D = node.api.creatures.make_ragdoll_leg_node("big-biter", li)
		if lp == null or lp.mesh == null or not lp.has_meta(&"leg_centroid"):
			all_legs_ok = false
		if lp != null:
			lp.free()
	var spitter_leg11: MeshInstance3D = node.api.creatures.make_ragdoll_leg_node("big-spitter", 11)
	if spitter_leg11 == null or spitter_leg11.mesh == null or not spitter_leg11.has_meta(&"leg_centroid"):
		all_legs_ok = false
	if spitter_leg11 != null:
		spitter_leg11.free()
	check(all_parts_ok and all_legs_ok,
		"immersive enemies: reworked biter, spitter (12 legs), worm (vertical Y), and spawner split with biter_inner_meat caps")

	# 1) Fire kill -> clears live wound, spawns 1 burning torso (`burning=true`, `rig_burn > 0`), 0 split parts, 0 detached legs, blood >= 0.25.
	var before_fire: int = node._ragdoll._active.size()
	cr.remove(1001, true, Vector3(4.0, 0.0, 8.0), "fire", 50, "flamethrower-ammo")
	var fire_torsos := 0
	var fire_parts := 0
	var fire_legs := 0
	var fire_blood := 0.0
	var fire_burn := -1.0
	var fire_burning_flag := false
	var fire_has_hole := false
	for idx in range(before_fire, node._ragdoll._active.size()):
		var b_rec: Dictionary = node._ragdoll._active[idx] as Dictionary
		if bool(b_rec.get("is_leg", false)):
			fire_legs += 1
		elif bool(b_rec.get("is_part", false)):
			fire_parts += 1
		else:
			fire_torsos += 1
			fire_burning_flag = bool(b_rec.get("burning", false))
			var rn: MeshInstance3D = b_rec["node"] as MeshInstance3D
			var rm: ShaderMaterial = rn.get_surface_override_material(0) as ShaderMaterial
			if rm != null:
				fire_blood = float(rm.get_shader_parameter("rig_blood"))
				fire_burn = float(rm.get_shader_parameter("rig_burn"))
				var raw_holes: Variant = rm.get_shader_parameter("rig_holes")
				if raw_holes is Array:
					for hv_obj in (raw_holes as Array):
						if hv_obj is Vector4 and (hv_obj as Vector4).w > 0.0:
							fire_has_hole = true
	check(not cr._wounds.has(1001) and fire_torsos == 1 and fire_parts == 0 and fire_legs == 0
		and fire_blood >= 0.25 and fire_has_hole and fire_burning_flag and fire_burn > 0.0,
		"immersive enemies: fire kill spawns burning ragdoll (rig_burn=%.2f) with 0 legs and inherited holes" % fire_burn)

	# 2) Heavy shotgun/physical kill -> spawns 1 intact torso + 2..3 detached legs + heavy blood >= 0.72.
	var before_heavy: int = node._ragdoll._active.size()
	cr.remove(1004, true, Vector3(10.0, 0.0, 12.0), "physical", 600, "piercing-shotgun-shell")
	var heavy_torsos := 0
	var heavy_legs := 0
	var heavy_blood := 0.0
	for idx in range(before_heavy, node._ragdoll._active.size()):
		var h_rec: Dictionary = node._ragdoll._active[idx] as Dictionary
		if bool(h_rec.get("is_leg", false)):
			heavy_legs += 1
		elif not bool(h_rec.get("is_part", false)):
			heavy_torsos += 1
			var h_node: MeshInstance3D = h_rec["node"] as MeshInstance3D
			var h_mat: ShaderMaterial = h_node.get_surface_override_material(0) as ShaderMaterial
			if h_mat != null:
				heavy_blood = float(h_mat.get_shader_parameter("rig_blood"))
	check(heavy_torsos == 1 and heavy_legs >= 2 and heavy_legs <= 3 and heavy_blood >= 0.72,
		"immersive enemies: heavy hit detaches 2-3 legs (%d) with blood=%.2f" % [heavy_legs, heavy_blood])

	# 3) Grenade / explosive kill via real Creatures.remove -> spawns 3 body chunks (head/thorax/abdomen) + 3-5 legs, gore droplets & gibs.
	var before_grenade: int = node._ragdoll._active.size()
	cr.remove(1002, true, Vector3(20.0, 0.0, 9.0), "explosion", 1500, "grenade")
	var split_parts := {}
	var grenade_legs := 0
	var min_part_blood := 2.0
	for idx in range(before_grenade, node._ragdoll._active.size()):
		var g_rec: Dictionary = node._ragdoll._active[idx] as Dictionary
		if bool(g_rec.get("is_leg", false)):
			grenade_legs += 1
		elif bool(g_rec.get("is_part", false)):
			var gp_name: String = str(g_rec.get("part_name", ""))
			split_parts[gp_name] = true
			var gn: MeshInstance3D = g_rec["node"] as MeshInstance3D
			var gm: ShaderMaterial = gn.get_surface_override_material(0) as ShaderMaterial
			if gm != null:
				min_part_blood = minf(min_part_blood, float(gm.get_shader_parameter("rig_blood")))
	check(split_parts.has("head") and split_parts.has("thorax") and split_parts.has("abdomen")
		and split_parts.size() == 3 and grenade_legs >= 3 and grenade_legs <= 5
		and min_part_blood >= 0.85 and node._gore._droplets.size() > 0 and node._gore._gibs.size() > 0,
		"immersive enemies: grenade splits body into head/thorax/abdomen + %d legs with min_blood=%.2f" % [grenade_legs, min_part_blood])

	# 4) Spitter, worm & spawner support:
	# Spitter grenade split -> 3 parts + 4..6 detached legs.
	var before_spit: int = node._ragdoll._active.size()
	var spit_die := {"unit": 1006, "name": "big-spitter", "pos": Vector3(26.0, 0.0, 10.0),
		"yaw": 0.2, "vel": Vector3(2.0, 0.0, 0.0), "scale": 1.0, "phase": 0.0,
		"cause_pos": Vector3(22.0, 0.0, 10.0), "damage_type": "explosion", "dmg": 1200, "src": "grenade", "handled": false}
	cr.on_died_hook.call(spit_die)
	var spit_parts := 0
	var spit_legs := 0
	for idx in range(before_spit, node._ragdoll._active.size()):
		var sr: Dictionary = node._ragdoll._active[idx] as Dictionary
		if bool(sr.get("is_leg", false)):
			spit_legs += 1
		elif bool(sr.get("is_part", false)):
			spit_parts += 1
	check(bool(spit_die.get("handled", false)) and spit_parts == 3 and spit_legs >= 4 and spit_legs <= 6,
		"immersive enemies: spitter grenade death splits into 3 chunks + %d severed legs" % spit_legs)

	# Live worm & nest bullet holes/blood -> records wounds in ragdoll + Anim.set_unit_wounds and clears on death.
	fake_fx.on_damaged_hook.call({"unit": 1007, "name": "big-worm-turret", "pos": Vector3(30.0, 0.0, 10.0),
		"cause_pos": Vector3(26.0, 0.0, 10.0), "damage_type": "physical", "fx": "blood",
		"dmg": 350, "hp": 650, "src": "firearm-magazine"})
	var worm_wounded_live: bool = node._ragdoll._wounds.has(1007) and anim._wounds.has(1007) and float(anim._wounds[1007]) < 0.0

	# Worm physical kill -> toppling 0-limb ragdoll; worm explosive kill -> 3 vertical chunks + 0 legs.
	var before_worm: int = node._ragdoll._active.size()
	var worm_die := {"unit": 1007, "name": "big-worm-turret", "pos": Vector3(30.0, 0.0, 10.0),
		"yaw": 0.0, "vel": Vector3.ZERO, "scale": 1.0, "phase": 0.0,
		"cause_pos": Vector3(26.0, 0.0, 10.0), "damage_type": "explosion", "dmg": 1400, "src": "rocket", "handled": false}
	cr.on_died_hook.call(worm_die)
	var worm_parts := 0
	var worm_legs := 0
	for idx in range(before_worm, node._ragdoll._active.size()):
		var wr: Dictionary = node._ragdoll._active[idx] as Dictionary
		if bool(wr.get("is_leg", false)):
			worm_legs += 1
		elif bool(wr.get("is_part", false)):
			worm_parts += 1
	check(worm_wounded_live and not node._ragdoll._wounds.has(1007) and not anim._wounds.has(1007)
		and bool(worm_die.get("handled", false)) and worm_parts == 3 and worm_legs == 0,
		"immersive enemies: live worm records wounds in Anim, clears on death, and splits vertically into 3 chunks with 0 legs")

	# Nest / Spawner physical + flamethrower damage -> live Anim wounds, cleared on explosive death -> grounded burning ruined corpse + 3 flying burning chunks.
	fake_fx.on_damaged_hook.call({"unit": 1008, "name": "biter-spawner", "pos": Vector3(36.0, 0.0, 10.0),
		"cause_pos": Vector3(30.0, 0.0, 10.0), "damage_type": "physical", "fx": "blood",
		"dmg": 250, "hp": 750, "src": "piercing-rounds-magazine"})
	fake_fx.on_damaged_hook.call({"unit": 1008, "name": "biter-spawner", "pos": Vector3(36.0, 0.0, 10.0),
		"cause_pos": Vector3(30.0, 0.0, 10.0), "damage_type": "fire", "fx": "burn",
		"dmg": 200, "hp": 550, "src": "flamethrower-ammo"})
	var nest_wounded_live: bool = node._ragdoll._wounds.has(1008) and anim._wounds.has(1008) and float(anim._wounds[1008]) < 0.0
	var before_nest_active: int = node._ragdoll._active.size()
	var before_nest_settled: int = node._ragdoll._settled.size()
	var nest_die := {"unit": 1008, "name": "biter-spawner", "pos": Vector3(36.0, 0.0, 10.0),
		"yaw": 0.0, "vel": Vector3.ZERO, "scale": 1.0, "phase": 0.0,
		"cause_pos": Vector3(30.0, 0.0, 10.0), "damage_type": "explosion", "dmg": 1500, "src": "grenade", "handled": false}
	cr.on_died_hook.call(nest_die)
	var nest_base_burning: bool = node._ragdoll._settled.size() == before_nest_settled + 1 and bool((node._ragdoll._settled[before_nest_settled] as Dictionary).get("burning", false))
	var nest_chunks := 0
	var nest_chunks_burning := true
	for idx in range(before_nest_active, node._ragdoll._active.size()):
		var nr: Dictionary = node._ragdoll._active[idx] as Dictionary
		if bool(nr.get("is_part", false)):
			nest_chunks += 1
			if not bool(nr.get("burning", false)):
				nest_chunks_burning = false
	check(nest_wounded_live and not node._ragdoll._wounds.has(1008) and not anim._wounds.has(1008)
		and bool(nest_die.get("handled", false)) and nest_base_burning and nest_chunks == 3 and nest_chunks_burning,
		"immersive enemies: live nest records wounds in Anim, clears on death, and spawns burning ruined base + 3 flying burning chunks")

	# Procedural 3D gib pools (chitin armor shards, wet meat chunks, curved horn splinters) are populated across explosive/nest deaths.
	var chitin_mm: MultiMesh = node._gore._gibs_chitin_mm
	var meat_mm: MultiMesh = node._gore._gibs_meat_mm
	var spike_mm: MultiMesh = node._gore._gibs_spike_mm
	var gib_meshes_ok: bool = (
		chitin_mm != null and chitin_mm.mesh is ArrayMesh and chitin_mm.mesh.get_surface_count() > 0
		and meat_mm != null and meat_mm.mesh is ArrayMesh and meat_mm.mesh.get_surface_count() > 0
		and spike_mm != null and spike_mm.mesh is ArrayMesh and spike_mm.mesh.get_surface_count() > 0
	)
	check(gib_meshes_ok and chitin_mm.visible_instance_count > 0 and meat_mm.visible_instance_count > 0 and spike_mm.visible_instance_count > 0,
		"immersive enemies: procedural 3D gib pools (chitin=%d, meat=%d, spike=%d) populate cleanly" % [
			chitin_mm.visible_instance_count if chitin_mm != null else -1,
			meat_mm.visible_instance_count if meat_mm != null else -1,
			spike_mm.visible_instance_count if spike_mm != null else -1])

	# Unit scale invariant across all active ragdolls, legs, and split chunks.
	var bad_scale := false
	for ab in node._ragdoll._active:
		var ab_d: Dictionary = ab as Dictionary
		var an: Node3D = ab_d["node"] as Node3D
		if not an.transform.basis.get_scale().is_equal_approx(Vector3.ONE):
			bad_scale = true
	check(not bad_scale, "immersive enemies: all ragdoll torsos, split chunks, and detached legs spawn at unit scale")

	# Higher ground friction and anti-roll damping constants.
	check(node._ragdoll.GROUND_FRICTION >= 8.0 and node._ragdoll.ANG_DAMPING >= 4.0 and node._ragdoll.RESTITUTION <= 0.2,
		"immersive enemies: higher ground friction (%.1f), angular damping (%.1f), low restitution (%.2f)" % [
			node._ragdoll.GROUND_FRICTION, node._ragdoll.ANG_DAMPING, node._ragdoll.RESTITUTION])

	# Momentum carry-through: sprinting biter shot with standard physical bullet keeps forward velocity.
	var mom_info := {"unit": 1003, "name": "small-biter", "pos": Vector3(5.0, 0.0, 5.0),
		"yaw": 0.0, "vel": Vector3(6.0, 0.0, 0.0), "scale": 0.5, "phase": 0.0,
		"cause_pos": Vector3(2.0, 0.0, 5.0), "damage_type": "physical", "dmg": 120, "src": "firearm-magazine", "handled": false}
	cr.on_died_hook.call(mom_info)
	var mom_body: Dictionary = {}
	for ab_i in range(node._ragdoll._active.size() - 1, -1, -1):
		var cand: Dictionary = node._ragdoll._active[ab_i] as Dictionary
		if not bool(cand.get("is_leg", false)) and not bool(cand.get("is_part", false)):
			mom_body = cand
			break
	var mom_vel: Vector3 = mom_body.get("vel", Vector3.ZERO) as Vector3
	check(bool(mom_info.get("handled", false)) and mom_vel.x >= 5.5,
		"immersive enemies: sprinting biter preserves full momentum into ragdoll velocity (%s)" % [mom_vel])

	# Step physics & particles until ragdolls and split parts settle, then advance into organic decay / burn-to-ash windows.
	for _step in 95:
		node._process(0.05)
	await get_tree().process_frame
	check(node._gore._decal_active > 0 and node.api.creatures.rig_info("small-biter").has("limbs"),
		"immersive enemies: splatter decals (%d) and scaled rig_info limbs active after physics step" % node._gore._decal_active)

	var non_burn_idx := -1
	var burn_node: Node3D = null
	for si in node._ragdoll._settled.size():
		var sr_s: Dictionary = node._ragdoll._settled[si] as Dictionary
		if bool(sr_s.get("burning", false)):
			if burn_node == null:
				burn_node = sr_s["node"] as Node3D
		elif non_burn_idx < 0:
			non_burn_idx = si
	check(node._ragdoll.settled_count() > 0 and non_burn_idx >= 0 and burn_node != null,
		"immersive enemies: both burning and non-burning bodies settle cleanly (settled=%d)" % node._ragdoll.settled_count())
	if non_burn_idx >= 0 and burn_node != null:
		var pre_s: Dictionary = node._ragdoll._settled[non_burn_idx] as Dictionary
		var pre_node: Node3D = pre_s["node"] as Node3D
		var pre_y: float = pre_node.position.y
		for _burn_step in 14:
			node._ragdoll.step(0.5)
			node._process(0.05)
		await get_tree().process_frame
		check(not is_instance_valid(burn_node) or not burn_node.is_inside_tree(),
			"immersive enemies: burning corpses burn to ash and clean up on accelerated fire schedule")
		var post_y: float = pre_node.position.y
		var post_decay := 0.0
		for sr_s2 in node._ragdoll._settled:
			var s_dict: Dictionary = sr_s2 as Dictionary
			if s_dict.get("node") == pre_node:
				post_decay = float(s_dict.get("decay", 0.0))
				break
		if post_decay <= 0.1:
			node._ragdoll.step(30.0)
			node._process(0.05)
			for sr_s3 in node._ragdoll._settled:
				var s_dict3: Dictionary = sr_s3 as Dictionary
				if s_dict3.get("node") == pre_node:
					post_decay = float(s_dict3.get("decay", 0.0))
					post_y = pre_node.position.y
					break
		check(post_decay > 0.1 and is_equal_approx(post_y, pre_y),
			"immersive enemies: non-burning settled corpses decay organically (decay=%.2f) without sinking into floor" % post_decay)

	# Toggling use_reworked_biters clears and restores all 3 transient ModelLibrary.addon_pack_overrides cleanly.
	node.api.settings.set_value("use_reworked_biters", false)
	await get_tree().process_frame
	check(str(ModelLib.addon_pack_overrides.get("big-biter", "")) == ""
		and str(ModelLib.addon_pack_overrides.get("big-spitter", "")) == ""
		and str(ModelLib.addon_pack_overrides.get("biter-spawner", "")) == "",
		"immersive enemies: toggling use_reworked_biters off clears all transient pack overrides")
	node.api.settings.set_value("use_reworked_biters", true)
	await get_tree().process_frame
	check(str(ModelLib.addon_pack_overrides.get("big-biter", "")) == "builtin:placeholders"
		and str(ModelLib.addon_pack_overrides.get("big-spitter", "")) == "builtin:placeholders"
		and str(ModelLib.addon_pack_overrides.get("biter-spawner", "")) == "builtin:placeholders",
		"immersive enemies: toggling use_reworked_biters back on restores builtin:placeholders overrides")

	# Slimy swamp-green acid goo: intercept spitter & worm acid streams and ground pools, ignore flamethrower & fire-flame.
	fake_weapons.handle({
		"t": "pj", "k": 10,
		"p": [
			6001, "acid-stream-spitter-big", 26 * 256, 10 * 256,
			6002, "acid-stream-worm-big", 30 * 256, 12 * 256,
			6003, "flamethrower-fire-stream", 10 * 256, 10 * 256,
		],
		"e": [], "b": [], "x": [],
	})
	var acid_streams_intercepted: bool = (
		fake_weapons._streams.has(6001) and fake_weapons._streams[6001].custom
		and fake_weapons._streams.has(6002) and fake_weapons._streams[6002].custom
		and fake_weapons._streams.has(6003) and not fake_weapons._streams[6003].custom
		and node._acid._globs.size() >= 6
	)
	var peak_drops := 0
	var peak_rings := 0
	for _astep in 10:
		node._process(0.05)
		peak_drops = maxi(peak_drops, node._acid._drops.size())
		peak_rings = maxi(peak_rings, node._acid._rings.size())
	check(acid_streams_intercepted and peak_drops > 0 and peak_rings > 0,
		"immersive enemies: spitter & worm acid streams spawn 3D slime globs, splashes (peak=%d), and rings (peak=%d) while leaving flamethrowers untouched" % [peak_drops, peak_rings])

	fake_weapons.handle({
		"t": "gf",
		"l": [
			7001, "acid-splash-fire-spitter-big", 26 * 256, 10 * 256, 300,
			7002, "acid-splash-fire-worm-big", 30 * 256, 12 * 256, 300,
			7003, "fire-flame", 10 * 256, 10 * 256, 300,
		],
	})
	node._process(0.05)
	var acid_pools_intercepted: bool = (
		fake_weapons._ground.has(7001) and fake_weapons._ground[7001].custom
		and fake_weapons._ground.has(7002) and fake_weapons._ground[7002].custom
		and fake_weapons._ground.has(7003) and not fake_weapons._ground[7003].custom and fake_weapons._ground[7003].fire
		and node._acid._pools.has(7001) and node._acid._pools.has(7002)
		and node._acid._pools_mm.visible_instance_count >= 2
	)
	# Remove acid pools from gf while keeping fire-flame -> pools fade out and clear cleanly.
	fake_weapons.handle({"t": "gf", "l": [7003, "fire-flame", 10 * 256, 10 * 256, 300]})
	for _pstep in 16:
		node._process(0.05)
	var acid_pools_cleared: bool = not node._acid._pools.has(7001) and not node._acid._pools.has(7002) and node._acid._pools_mm.visible_instance_count == 0
	check(acid_pools_intercepted and acid_pools_cleared,
		"immersive enemies: acid splash pools spawn custom swamp-green shader pools (fire-flame ignored) and fade cleanly")

	# Disabling acid_goo clears active globs/pools and falls back to WeaponFx without fire light/smoke on acid pools.
	fake_weapons.handle({"t": "gf", "l": [7005, "acid-splash-fire-spitter-big", 24 * 256, 12 * 256, 300]})
	node.api.settings.set_value("acid_goo", false)
	fake_weapons.handle({"t": "gf", "l": [7004, "acid-splash-fire-spitter-small", 18 * 256, 14 * 256, 300]})
	var fallback_no_fire: bool = (
		node._acid._pools.is_empty() and node._acid._globs.is_empty()
		and fake_weapons._ground.has(7004)
		and not fake_weapons._ground[7004].custom
		and not fake_weapons._ground[7004].fire
	)
	check(fallback_no_fire,
		"immersive enemies: disabling acid_goo clears pools/globs and keeps vanilla acid pools free of fire smoke/glow")
	node.api.settings.set_value("acid_goo", true)

	# Toggling animations off disables live override path without errors; wound remaining walker & static worm units to test disable cleanup.
	fake_fx.on_damaged_hook.call({"unit": 1005, "name": "big-biter", "pos": b5_node.position,
		"cause_pos": Vector3(2.0, 0.0, 14.0), "damage_type": "physical", "fx": "blood",
		"dmg": 300, "hp": 700, "src": "firearm-magazine"})
	fake_fx.on_damaged_hook.call({"unit": 1009, "name": "big-worm-turret", "pos": Vector3(40.0, 0.0, 14.0),
		"cause_pos": Vector3(34.0, 0.0, 14.0), "damage_type": "physical", "fx": "blood",
		"dmg": 300, "hp": 700, "src": "firearm-magazine"})
	node.api.settings.set_value("animations", false)
	node._process(0.05)
	check(not cr._anim_enabled and cr._overrides.is_empty() and cr._wounds.has(1005) and anim._wounds.has(1009),
		"immersive enemies: disabling animations turns off live override path with zero leftover overrides while keeping live wounds")

	# Switch add-on off and verify complete teardown (including all 3 transient pack overrides & live wounds cleanup).
	host.set_enabled("immersive-enemies", false)
	await get_tree().process_frame
	check(not cr._anim_enabled and host.find("immersive-enemies").get("node") == null
		and str(ModelLib.addon_pack_overrides.get("big-biter", "")) == ""
		and str(ModelLib.addon_pack_overrides.get("big-spitter", "")) == ""
		and str(ModelLib.addon_pack_overrides.get("biter-spawner", "")) == ""
		and cr._wounds.is_empty() and anim._wounds.is_empty(),
		"immersive enemies: switching add-on off tears down nodes, anim hooks, live wounds, and pack overrides cleanly")

	host.game_ended()
	ModelLib.addon_pack_overrides.clear()
	ModelLib.choices_changed(["big-biter", "big-spitter", "biter-spawner"])
	for id in ["ragdolls", "ragdoll_force", "spread_deaths", "max_ragdolls", "gore", "gibs", "gore_level", "blood_amount", "acid_goo", "animations", "use_reworked_biters"]:
		Settings.reset_value("addon_immersive_enemies", id)
	Settings.reset_value("addons", "immersive-enemies")
	b1_node.queue_free()
	b2_node.queue_free()
	b4_node.queue_free()
	b5_node.queue_free()
	host.queue_free()
	fake.movers.creatures = prev_creatures
	fake.movers = prev_movers
	if owned_movers != null:
		owned_movers.queue_free()
	fake.fx = prev_fx
	fake.world = prev_world
	anim.queue_free()
	owned_world.queue_free()
	cr.queue_free()
	fake_weapons.reset()
	fake_fx.queue_free()
	fake_weapons.queue_free()
	fake_sprites.queue_free()
