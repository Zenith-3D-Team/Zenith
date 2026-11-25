extends RefCounted
## Nauvis weather state machine: picks transitions, eases between presets, applies user
## multipliers, gates on Nauvis surface (clearing in space or on other planets), freezes during
## screenshots, simulates ground/model wetness and puddles (rain soaks, sun slowly dries), and
## persists per-save progress through `api.storage`.

const Presets := preload("weather_presets.gd")

var api
var current_id := "fair"
var target_id := "fair"
var blend_t := 1.0
var hold_left := 240.0
var active_on_nauvis := false
var current_spec := {}
## Persistent moisture (0..1): surfaces soak while it rains and evaporate when dry.
var ground_wetness := 0.0
var model_wetness := 0.0
var puddle_level := 0.0
var flash_level := 0.0

var _dirty_save := false
var _moisture_save_t := 0.0

## (1.92) The weather timeline (`--weather-timeline=<file>`): entries {at: ticks after the cue,
## weather, over: seconds}, sorted by `at`; `timeline_before` the weather until the cue. While one
## is loaded it decides the weather, not the Weather cycle setting.
var timeline: Array = []
var timeline_before := ""
var timeline_path := ""
var timeline_error := ""
var _tl_entry := -2  # the entry in force: -1 the `before` weather, -2 none applied yet


func _init(a) -> void:
	api = a


func reset_for_game() -> void:
	var saved: Dictionary = api.storage.read("weather")
	var def_id := "fair"
	current_id = str(saved.get("current_id", def_id))
	target_id = str(saved.get("target_id", current_id))
	if not Presets.PRESETS.has(current_id):
		current_id = def_id
	if not Presets.PRESETS.has(target_id):
		target_id = current_id
	blend_t = clampf(float(saved.get("blend_t", 1.0)), 0.0, 1.0)
	var cycle_s := maxf(float(api.settings.value("cycle_minutes")) * 60.0, 30.0)
	hold_left = clampf(float(saved.get("hold_left", cycle_s * 0.7)), 5.0, cycle_s * 1.5)
	ground_wetness = clampf(float(saved.get("ground_wetness", 0.0)), 0.0, 1.0)
	model_wetness = clampf(float(saved.get("model_wetness", 0.0)), 0.0, 1.0)
	puddle_level = clampf(float(saved.get("puddle_level", 0.0)), 0.0, 1.0)
	_moisture_save_t = 0.0
	active_on_nauvis = false
	_ensure_allowed()


func save_state() -> void:
	if not api.in_game():
		return
	api.storage.write({
		"current_id": current_id,
		"target_id": target_id,
		"blend_t": blend_t,
		"hold_left": hold_left,
		"ground_wetness": clampf(ground_wetness, 0.0, 1.0),
		"model_wetness": clampf(model_wetness, 0.0, 1.0),
		"puddle_level": clampf(puddle_level, 0.0, 1.0),
	}, "weather")
	_dirty_save = false
	_moisture_save_t = 0.0


func is_nauvis() -> bool:
	return api.in_game() and str(api.world.planet()) == "nauvis" and not bool(api.world.on_platform())


func step(delta: float) -> void:
	if not is_nauvis():
		if active_on_nauvis:
			active_on_nauvis = false
			flash_level = 0.0
			current_spec = {}
			api.weather.clear()
		return
	active_on_nauvis = true
	if api.view.screenshot_busy():
		_push()
		return
	if has_timeline():
		_timeline_step()
		_update_moisture(delta)
		_push()
		if _dirty_save:
			save_state()
		return
	var s = api.settings
	var mode := str(s.value("mode"))
	if mode == "locked":
		var wanted := str(s.value("locked_weather"))
		if Presets.PRESETS.has(wanted) and wanted != target_id:
			transition_to(wanted)
	else:
		_ensure_allowed()
	if target_id != current_id:
		var trans_s := maxf(float(s.value("transition_seconds")), 0.5)
		blend_t = minf(1.0, blend_t + delta / trans_s)
		if blend_t >= 1.0:
			current_id = target_id
			blend_t = 1.0
			_dirty_save = true
	elif mode == "dynamic":
		hold_left -= delta
		if hold_left <= 0.0:
			transition_to(_pick_next())
			var cycle_s := maxf(float(s.value("cycle_minutes")) * 60.0, 30.0)
			hold_left = cycle_s * randf_range(0.7, 1.3)
	_update_moisture(delta)
	_push()
	if _dirty_save:
		save_state()


func jump_to(id: String) -> void:
	if not Presets.PRESETS.has(id):
		return
	current_id = id
	target_id = id
	blend_t = 1.0
	var preset: Dictionary = Presets.PRESETS[id]
	ground_wetness = clampf(float(preset.get("target_wetness", 0.0)), 0.0, 1.0)
	model_wetness = ground_wetness
	puddle_level = clampf(float(preset.get("target_puddles", 0.0)), 0.0, 1.0)
	var cycle_s := maxf(float(api.settings.value("cycle_minutes")) * 60.0, 30.0)
	hold_left = cycle_s * randf_range(0.7, 1.3)
	_dirty_save = true
	if is_nauvis():
		active_on_nauvis = true
		_push()
	save_state()


func dry_now() -> void:
	ground_wetness = 0.0
	model_wetness = 0.0
	puddle_level = 0.0
	if is_nauvis():
		active_on_nauvis = true
		_push()
	save_state()


func transition_to(id: String) -> void:
	if not Presets.PRESETS.has(id):
		return
	if id == target_id:
		return
	# Snap current midpoint when redirecting mid-transition so nothing pops.
	if target_id != current_id and blend_t > 0.0 and blend_t < 1.0:
		if blend_t >= 0.5:
			current_id = target_id
		blend_t = 0.0
	else:
		blend_t = 0.0
	target_id = id
	var cycle_s := maxf(float(api.settings.value("cycle_minutes")) * 60.0, 30.0)
	hold_left = cycle_s * randf_range(0.7, 1.3)
	_dirty_save = true


func next_weather() -> String:
	var nxt := _pick_next()
	transition_to(nxt)
	return nxt


func _allowed(id: String) -> bool:
	var p: Dictionary = Presets.PRESETS.get(id, {})
	var cat := str(p.get("category", "clear"))
	if cat == "hazy" and not bool(api.settings.value("allow_hazy")):
		return false
	if cat == "overcast" and not bool(api.settings.value("allow_overcast")):
		return false
	if cat == "rain" and not bool(api.settings.value("allow_rain")):
		return false
	if cat == "storm" and not bool(api.settings.value("allow_storms")):
		return false
	return true


func _ensure_allowed() -> void:
	if str(api.settings.value("mode")) == "locked":
		return
	if not _allowed(target_id):
		transition_to(_pick_next())


func _pick_next() -> String:
	var cur: Dictionary = Presets.PRESETS.get(current_id, Presets.PRESETS["fair"])
	var candidates: Array = []
	for cid in cur.get("next", []):
		var sid := str(cid)
		if sid != current_id and _allowed(sid):
			candidates.append(sid)
	if candidates.is_empty():
		for sid: String in Presets.ORDER:
			if sid != current_id and _allowed(sid):
				candidates.append(sid)
	if candidates.is_empty():
		return "fair"
	var total := 0.0
	for sid: String in candidates:
		total += float((Presets.PRESETS[sid] as Dictionary).get("weight", 1.0))
	var r := randf() * total
	for sid: String in candidates:
		r -= float((Presets.PRESETS[sid] as Dictionary).get("weight", 1.0))
		if r <= 0.0:
			return sid
	return str(candidates[0])


func _update_moisture(delta: float) -> void:
	if delta <= 0.0:
		return
	var raw := Presets.blend(current_id, target_id, blend_t)
	var rain := float(raw["rain_intensity"])
	if rain > 0.02:
		var k := clampf(rain, 0.3, 1.0)
		var target_wet := clampf(float(raw["target_wetness"]), 0.0, 1.0)
		var target_pud := clampf(float(raw["target_puddles"]), 0.0, 1.0)
		if model_wetness < target_wet:
			model_wetness = minf(target_wet, model_wetness + delta / 28.0 * k)
		if ground_wetness < target_wet:
			ground_wetness = minf(target_wet, ground_wetness + delta / 40.0 * k)
		if ground_wetness > 0.22 and puddle_level < target_pud:
			puddle_level = minf(target_pud, puddle_level + delta / 65.0 * k)
	else:
		var dry_s := maxf(float(api.settings.value("dry_minutes")) * 60.0, 10.0)
		var sun := clampf(float(raw["sun_energy_scale"]), 0.5, 1.25)
		var rate := delta * sun / dry_s
		model_wetness = maxf(0.0, model_wetness - rate * 1.3)
		ground_wetness = maxf(0.0, ground_wetness - rate)
		puddle_level = maxf(0.0, puddle_level - rate * 0.65)
	_moisture_save_t += delta
	if _moisture_save_t >= 20.0:
		_moisture_save_t = 0.0
		_dirty_save = true


func _push() -> void:
	var raw := Presets.blend(current_id, target_id, blend_t)
	var s = api.settings
	var cloud_k := float(s.value("cloud_strength"))
	var mood_k := float(s.value("mood_strength"))
	var fog_k := float(s.value("fog_strength"))
	var wind_k := float(s.value("wind_strength"))
	var rain_on := bool(s.value("rain_enabled"))

	var cov := float(raw["cloud_cover"])
	if cloud_k <= 0.001:
		cov = 0.0
	var scaled := {
		"sun_energy_scale": lerpf(1.0, float(raw["sun_energy_scale"]), mood_k),
		"sun_color_tint": raw["sun_color_tint"],
		"sun_tint_amount": clampf(float(raw["sun_tint_amount"]) * mood_k, 0.0, 1.0),
		"sun_disc_scale": lerpf(1.0, float(raw["sun_disc_scale"]), mood_k),
		"shadow_opacity_scale": clampf(lerpf(1.0, float(raw["shadow_opacity_scale"]), mood_k), 0.0, 1.0),
		"ambient_energy_scale": lerpf(1.0, float(raw["ambient_energy_scale"]), mood_k),
		"ambient_tint": raw["ambient_tint"],
		"ambient_tint_amount": clampf(float(raw["ambient_tint_amount"]) * mood_k, 0.0, 1.0),
		"sky_zenith_tint": raw["sky_zenith_tint"],
		"sky_horizon_tint": raw["sky_horizon_tint"],
		"sky_tint_amount": clampf(float(raw["sky_tint_amount"]) * mood_k, 0.0, 1.0),
		"star_visibility_scale": clampf(lerpf(1.0, float(raw["star_visibility_scale"]), mood_k), 0.0, 1.5),
		"cloud_cover": cov,
		"cloud_alpha_scale": clampf(float(raw["cloud_alpha_scale"]) * cloud_k, 0.0, 1.5),
		"cloud_shadow_scale": clampf(float(raw["cloud_shadow_scale"]) * cloud_k, 0.0, 2.0),
		"cloud_darkness": clampf(float(raw["cloud_darkness"]) * clampf(mood_k, 0.25, 1.5), 0.0, 1.0),
		"cloud_tint": raw["cloud_tint"],
		"cloud_tint_amount": clampf(float(raw["cloud_tint_amount"]) * mood_k, 0.0, 1.0),
		"wind": (raw["wind"] as Vector2) * wind_k,
		"wind_strength": clampf(float(raw["wind_strength"]) * wind_k, 0.0, 3.0),
		"fog_density_add": float(raw["fog_density_add"]) * fog_k,
		"fog_color": raw["fog_color"],
		"fog_color_amount": clampf(float(raw["fog_color_amount"]) * minf(fog_k, 1.25), 0.0, 1.0),
		"haze_strength": float(raw["haze_strength"]) * fog_k,
		"haze_color": raw["haze_color"],
		"god_rays_scale": clampf(lerpf(1.0, float(raw["god_rays_scale"]), mood_k), 0.0, 2.0),
	}
	scaled["wind_audio"] = float(raw["wind_audio"]) * clampf(wind_k, 0.0, 1.5)

	var wet_k := float(s.value("wetness_strength"))
	var ground_on := bool(s.value("ground_wetness_enabled"))
	var model_on := bool(s.value("model_wetness_enabled"))
	scaled["ground_wetness"] = clampf(ground_wetness * wet_k, 0.0, 1.0) if ground_on else 0.0
	scaled["model_wetness"] = clampf(model_wetness * wet_k, 0.0, 1.0) if model_on else 0.0
	scaled["puddle_amount"] = 0.0
	if bool(s.value("ground_puddles_enabled")):
		scaled["puddle_amount"] = clampf(puddle_level * float(s.value("puddle_amount")), 0.0, 1.0)
	scaled["model_puddles"] = 0.0
	if bool(s.value("model_puddles_enabled")):
		scaled["model_puddles"] = clampf(puddle_level * float(s.value("model_puddles_strength")), 0.0, 1.0)
	scaled["rain_ripples"] = 0.0
	if rain_on and bool(s.value("rain_ripples_enabled")):
		scaled["rain_ripples"] = clampf(float(raw["ripple_strength"]) * float(s.value("rain_ripples_strength")), 0.0, 1.0)
	scaled["puddle_scale"] = float(s.value("puddle_scale"))
	scaled["puddle_reflect"] = float(s.value("puddle_reflect"))
	scaled["wet_darken"] = float(s.value("wet_darken"))
	scaled["rain_intensity"] = float(raw["rain_intensity"]) if rain_on else 0.0
	var splash_on := rain_on and bool(s.value("splashes_enabled"))
	scaled["splash_rate"] = float(raw["splash_rate"]) * float(s.value("splash_density")) if splash_on else 0.0
	scaled["rain_audio"] = float(raw["rain_audio"])
	scaled["storm_intensity"] = clampf(float(raw["storm_intensity"]), 0.0, 1.0)
	scaled["lightning_rate"] = clampf(float(raw["lightning_rate"]), 0.0, 2.0)
	scaled["flash"] = clampf(flash_level, 0.0, 2.0)
	current_spec = scaled
	api.weather.set_state(scaled)


# --- The weather timeline (API 1.92) ------------------------------------------------------------

## The timeline's file from the command line (`--weather-timeline=<file>`); "" none.
static func timeline_arg(args: PackedStringArray) -> String:
	for a: String in args:
		if a.begins_with("--weather-timeline="):
			return a.substr(19).strip_edges()
	return ""


func has_timeline() -> bool:
	return timeline_before != ""


func clear_timeline() -> void:
	timeline.clear()
	timeline_before = ""
	timeline_error = ""
	_tl_entry = -2


## Loads the timeline from `path` (relative paths from the add-on's folder); "" unloads it. Returns
## why it didn't load, "" when it did (or when unloading).
func load_timeline(path: String) -> String:
	clear_timeline()
	timeline_path = path
	if path == "":
		return ""
	var full := path
	if path.is_relative_path() and not path.begins_with("res://") and not path.begins_with("user://") and api != null:
		full = str(api.dir).path_join(path)
	var text := FileAccess.get_file_as_string(full)
	if text == "":
		timeline_error = "can't read the weather timeline %s" % full
		return timeline_error
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		timeline_error = "the weather timeline %s isn't JSON" % full
		return timeline_error
	return set_timeline(parsed)


## The timeline itself: {"before": "<weather>", "timeline": [{"at": ticks after the cue,
## "weather": "<weather>", "over": seconds}, ...]}; a bare array of entries works too (before: the
## first entry's weather). Weathers are the presets' ids (weather_presets.gd ORDER).
func set_timeline(data: Variant) -> String:
	clear_timeline()
	var list: Variant = data
	var before := ""
	if data is Dictionary:
		list = data.get("timeline", data.get("entries", []))
		before = str(data.get("before", ""))
	if not list is Array:
		timeline_error = "the weather timeline has no list of entries"
		return timeline_error
	var bad := 0
	for e: Variant in list:
		if not e is Dictionary or not _num(e.get("at")) or not Presets.PRESETS.has(str(e.get("weather", ""))):
			bad += 1
			continue
		timeline.append({"at": maxi(int(e["at"]), 0), "weather": str(e["weather"]),
			"over": maxf(float(e["over"]), 0.0) if _num(e.get("over")) else 0.0})
	if timeline.is_empty():
		timeline_error = "the weather timeline has no entries (%d without an at and a known weather)" % bad
		return timeline_error
	var by_at := func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["at"]) < int(b["at"])
	timeline.sort_custom(by_at)
	if before == "":
		before = str(timeline[0]["weather"])
	elif not Presets.PRESETS.has(before):
		timeline.clear()
		timeline_error = "the weather timeline's before %s isn't a known weather" % before
		return timeline_error
	timeline_before = before
	if bad > 0 and api != null:
		api.note("weather timeline: %d entries without an at and a known weather left out" % bad)
	return ""


static func _num(v: Variant) -> bool:
	return v is float or v is int


## The timeline's weather at the game's tick from the cue (api.world.cue_tick): `before` until the
## cue (or while there is none), then each entry in turn, moving from the weather showing over its
## `over` seconds of game time (so a paused or slowed game holds the change, and every take matches).
## A tick going back (a save loaded again) or a late join sets the weather as it would be by then.
func _timeline_step() -> void:
	var cue := int(api.world.cue_tick()) if api.world.has_method("cue_tick") else -1
	var t := -1.0
	if api.world.has_method("smooth_tick"):
		t = float(api.world.smooth_tick())
	elif api.world.has_method("tick"):
		t = float(api.world.tick())
	var idx := -1
	var since := 0.0
	if cue >= 0 and t >= 0.0:
		var after := t - float(cue)
		for i in timeline.size():
			if after >= float(timeline[i]["at"]):
				idx = i
			else:
				break
		if idx >= 0:
			since = (after - float(timeline[idx]["at"])) / 60.0
	if idx < 0:
		if _tl_entry != -1 or current_id != timeline_before or target_id != timeline_before:
			jump_to(timeline_before)  # the scene's start: its weather at once, dry as that weather is
		_tl_entry = -1
		return
	var e: Dictionary = timeline[idx]
	if idx != _tl_entry or target_id != str(e["weather"]):  # (the panel's choice overridden too)
		if _tl_entry == idx - 1 and _tl_entry >= -1:
			# The next entry in turn: from what shows now (a change still going half done snaps).
			if target_id != current_id and blend_t >= 0.5:
				current_id = target_id
		else:
			current_id = timeline_before if idx == 0 else str(timeline[idx - 1]["weather"])
		target_id = str(e["weather"])
		_tl_entry = idx
		_dirty_save = true
	var over := float(e["over"])
	blend_t = 1.0 if over <= 0.0 else clampf(since / over, 0.0, 1.0)
	if blend_t >= 1.0 and current_id != target_id:
		current_id = target_id
		_dirty_save = true


func status_text() -> String:
	if not api.in_game():
		return "Waiting for game"
	if not is_nauvis():
		var p := str(api.world.planet())
		return "Inactive (%s)" % ("space platform" if api.world.on_platform() else (p if p != "" else "off Nauvis"))
	var base := Presets.label_of(current_id)
	if has_timeline():
		base = "Timeline: " + base
	if target_id != current_id:
		base = "%s -> %s (%d%%)" % [Presets.label_of(current_id), Presets.label_of(target_id), roundi(blend_t * 100.0)]
	var damp: Array = []
	if maxf(ground_wetness, model_wetness) > 0.05:
		damp.append("Wet %d%%" % roundi(maxf(ground_wetness, model_wetness) * 100.0))
	if puddle_level > 0.05:
		damp.append("Puddles %d%%" % roundi(puddle_level * 100.0))
	if damp.is_empty():
		return base
	return "%s (%s)" % [base, ", ".join(damp)]
