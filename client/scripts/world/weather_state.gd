extends RefCounted
## Central client-side weather overrides driven by an add-on through `api.weather` (API 1.8).
## Off by default: while inactive, Zenith's sky, lighting, clouds, grass wind, and surface shaders
## remain unchanged. Single-owner like ground_height.gd, cleared when the owning add-on stops,
## the game ends, or on a space platform.

const Switches := preload("res://scripts/switches.gd")

const GLOBAL_WET := &"f3d_weather_wet"
const GLOBAL_PUDDLE := &"f3d_weather_puddle"
const GLOBAL_CLOUDS := &"f3d_weather_clouds"
const GLOBAL_WIND := &"f3d_weather_wind"
const GLOBAL_GRASS_WIND := &"f3d_grass_wind"
const GLOBAL_IMPULSES := &"f3d_weather_impulses"
const GLOBAL_IMPULSE_INFO := &"f3d_weather_impulse_info"
const GLOBAL_IMPULSE_BOUNDS := &"f3d_weather_impulse_bounds"
const GLOBAL_WET_METAL := &"f3d_wet_metal"

const DEFAULT_WIND := Vector2(0.9, 0.3)
const MAX_IMPULSES := 64
const IMPULSE_CLOCK_WRAP := 10000.0

## --addon-weather=off disables api.weather overrides for a run.
static var disabled: bool = not Switches.on("--addon-weather")
## --puddle-splashes=off disables vehicle puddle splashes and terrain puddle wakes.
static var splashes_disabled: bool = not Switches.on("--puddle-splashes")
## --wet-metal=old restores the previous metallic rain wetness behaviour instead of dampening metal.
static var wet_metal_old: bool = Switches.has("--wet-metal=old")
static var owner := ""
static var active := false
static var state := {}
static var cloud_drift := Vector2.ZERO
static var base_grass_wind := false
## Snapshot of globals last sent to RenderingServer (for headless tests, where global reads are null).
static var last_globals := {}
static var _impulses: Array = []
static var _imp_clock := 0.0
static var _imp_strength := 1.0
static var _imp_image: Image = null
static var _imp_tex: ImageTexture = null
static var _imp_data := PackedFloat32Array()
static var _imp_was_active := false


static func _finite(v: Variant, fallback: float, lo: float, hi: float) -> float:
	if not (v is int or v is float):
		return fallback
	var f := float(v)
	if is_nan(f) or is_inf(f):
		return fallback
	return clampf(f, lo, hi)


static func _color(v: Variant, fallback: Color) -> Color:
	if v is Color:
		var c: Color = v
		return Color(
			clampf(0.0 if is_nan(c.r) or is_inf(c.r) else c.r, 0.0, 2.0),
			clampf(0.0 if is_nan(c.g) or is_inf(c.g) else c.g, 0.0, 2.0),
			clampf(0.0 if is_nan(c.b) or is_inf(c.b) else c.b, 0.0, 2.0),
			clampf(0.0 if is_nan(c.a) or is_inf(c.a) else c.a, 0.0, 1.0)
		)
	return fallback


static func _vec2(v: Variant, fallback: Vector2, limit: float) -> Vector2:
	if v is Vector2:
		var p: Vector2 = v
		var x := 0.0 if is_nan(p.x) or is_inf(p.x) else clampf(p.x, -limit, limit)
		var y := 0.0 if is_nan(p.y) or is_inf(p.y) else clampf(p.y, -limit, limit)
		return Vector2(x, y)
	return fallback


static func _sanitize(spec: Dictionary) -> Dictionary:
	var out := {
		"sun_energy_scale": _finite(spec.get("sun_energy_scale", 1.0), 1.0, 0.0, 2.0),
		"sun_color_tint": _color(spec.get("sun_color_tint"), Color.WHITE),
		"sun_tint_amount": _finite(spec.get("sun_tint_amount", 0.0), 0.0, 0.0, 1.0),
		"sun_disc_scale": _finite(spec.get("sun_disc_scale", 1.0), 1.0, 0.0, 1.5),
		"shadow_opacity_scale": _finite(spec.get("shadow_opacity_scale", 1.0), 1.0, 0.0, 1.0),
		"ambient_energy_scale": _finite(spec.get("ambient_energy_scale", 1.0), 1.0, 0.0, 2.0),
		"ambient_tint": _color(spec.get("ambient_tint"), Color.WHITE),
		"ambient_tint_amount": _finite(spec.get("ambient_tint_amount", 0.0), 0.0, 0.0, 1.0),
		"sky_zenith_tint": _color(spec.get("sky_zenith_tint"), Color(0.27, 0.47, 0.76)),
		"sky_horizon_tint": _color(spec.get("sky_horizon_tint"), Color(0.7, 0.8, 0.88)),
		"sky_tint_amount": _finite(spec.get("sky_tint_amount", 0.0), 0.0, 0.0, 1.0),
		"star_visibility_scale": _finite(spec.get("star_visibility_scale", 1.0), 1.0, 0.0, 1.5),
		"flash": _finite(spec.get("flash", 0.0), 0.0, 0.0, 2.0),
		"cloud_cover": _finite(spec.get("cloud_cover", -1.0), -1.0, -1.0, 1.0),
		"cloud_alpha_scale": _finite(spec.get("cloud_alpha_scale", 1.0), 1.0, 0.0, 1.5),
		"cloud_shadow_scale": _finite(spec.get("cloud_shadow_scale", 1.0), 1.0, 0.0, 2.0),
		"cloud_darkness": _finite(spec.get("cloud_darkness", 0.0), 0.0, 0.0, 1.0),
		"cloud_tint": _color(spec.get("cloud_tint"), Color.WHITE),
		"cloud_tint_amount": _finite(spec.get("cloud_tint_amount", 0.0), 0.0, 0.0, 1.0),
		"wind": _vec2(spec.get("wind"), DEFAULT_WIND, 30.0),
		"has_wind": spec.has("wind"),
		"wind_strength": _finite(spec.get("wind_strength", 1.0), 1.0, 0.0, 3.0),
		"fog_density_add": _finite(spec.get("fog_density_add", 0.0), 0.0, 0.0, 0.03),
		"fog_color": _color(spec.get("fog_color"), Color(0.68, 0.74, 0.80)),
		"fog_color_amount": _finite(spec.get("fog_color_amount", 0.0), 0.0, 0.0, 1.0),
		"haze_strength": _finite(spec.get("haze_strength", 0.0), 0.0, 0.0, 0.35),
		"haze_color": _color(spec.get("haze_color"), Color(0.75, 0.80, 0.86)),
		"god_rays_scale": _finite(spec.get("god_rays_scale", 1.0), 1.0, 0.0, 2.0),
		"ground_wetness": _finite(spec.get("ground_wetness", 0.0), 0.0, 0.0, 1.0),
		"model_wetness": _finite(spec.get("model_wetness", 0.0), 0.0, 0.0, 1.0),
		"puddle_amount": _finite(spec.get("puddle_amount", 0.0), 0.0, 0.0, 1.0),
		"model_puddles": _finite(spec.get("model_puddles", 0.0), 0.0, 0.0, 1.0),
		"rain_ripples": _finite(spec.get("rain_ripples", 0.0), 0.0, 0.0, 1.0),
		"puddle_scale": _finite(spec.get("puddle_scale", 0.12), 0.12, 0.03, 0.6),
		"puddle_reflect": _finite(spec.get("puddle_reflect", 0.75), 0.75, 0.0, 1.5),
		"wet_darken": _finite(spec.get("wet_darken", 0.45), 0.45, 0.0, 1.0),
	}
	return out


static func set_state(by: String, spec: Dictionary) -> bool:
	if disabled or by == "":
		return false
	owner = by
	active = true
	state = _sanitize(spec)
	push_globals(false)
	return true


static func clear(by := "") -> void:
	if by != "" and by != owner:
		return
	owner = ""
	active = false
	state = {}
	_impulses.clear()
	_imp_strength = 1.0
	push_globals(false)


static func add_impulse(by: String, pos: Vector2, dir: Vector2, radius: float, amp: float, life: float) -> bool:
	if disabled or splashes_disabled or not active or by == "" or by != owner:
		return false
	if is_nan(pos.x) or is_inf(pos.x) or is_nan(pos.y) or is_inf(pos.y):
		return false
	var r: float = _finite(radius, 2.4, 0.3, 10.0)
	var a: float = _finite(amp, 1.0, 0.0, 3.0)
	var l: float = _finite(life, 1.6, 0.15, 6.0)
	var d := Vector2.ZERO
	if not (is_nan(dir.x) or is_inf(dir.x) or is_nan(dir.y) or is_inf(dir.y)):
		if dir.length() > 0.01:
			d = dir.normalized()
	if _impulses.size() >= MAX_IMPULSES:
		_impulses.pop_front()
	_impulses.append([pos.x, pos.y, _imp_clock, r, d.x, d.y, a, l])
	return true


static func set_impulse_strength(by: String, strength: float) -> void:
	if by != "" and by != owner:
		return
	_imp_strength = _finite(strength, 1.0, 0.0, 2.5)


static func clear_impulses(by := "") -> void:
	if by != "" and by != owner:
		return
	_impulses.clear()
	var info := Vector4(0.0, _imp_clock, _imp_strength, 0.0)
	var bounds := Vector4.ZERO
	last_globals["f3d_weather_impulse_info"] = info
	last_globals["f3d_weather_impulse_bounds"] = bounds
	RenderingServer.global_shader_parameter_set(GLOBAL_IMPULSE_INFO, info)
	RenderingServer.global_shader_parameter_set(GLOBAL_IMPULSE_BOUNDS, bounds)
	_imp_was_active = false


static func active_impulse_count() -> int:
	return _impulses.size()


static func current() -> Dictionary:
	return state.duplicate()


static func grass_wind_value() -> float:
	if not base_grass_wind:
		return 0.0
	if active:
		return float(state.get("wind_strength", 1.0))
	return 1.0


static func advance(delta: float, space := false) -> void:
	if active and not space and delta > 0.0:
		var wind: Vector2 = state.get("wind", DEFAULT_WIND)
		cloud_drift += wind * delta
		if not splashes_disabled and not disabled:
			_imp_clock = fposmod(_imp_clock + delta, IMPULSE_CLOCK_WRAP)
	if not active or splashes_disabled or disabled:
		if not _impulses.is_empty():
			_impulses.clear()
	elif not space and not _impulses.is_empty():
		var kept: Array = []
		for item: Variant in _impulses:
			var rec: Array = item
			var spawn_t: float = float(rec[2])
			var life: float = float(rec[7])
			var age: float = fposmod(_imp_clock - spawn_t + IMPULSE_CLOCK_WRAP, IMPULSE_CLOCK_WRAP)
			if age < life:
				kept.append(rec)
		_impulses = kept
	push_globals(space)


static func push_globals(space := false) -> void:
	var wet := Vector4.ZERO
	var puddle := Vector4(0.12, 0.75, 0.45, 0.0)
	var clouds := Vector4.ZERO
	var wind_g := Vector4(0.0, 0.0, 1.0, 0.0)
	var grass := 1.0 if base_grass_wind else 0.0
	var imp_info := Vector4(0.0, _imp_clock, _imp_strength, 0.0)
	var imp_bounds := Vector4.ZERO
	var wet_metal := 0.0 if wet_metal_old else 1.0
	if active and not space:
		wet = Vector4(
			float(state.get("ground_wetness", 0.0)),
			float(state.get("model_wetness", 0.0)),
			float(state.get("puddle_amount", 0.0)),
			float(state.get("rain_ripples", 0.0))
		)
		puddle = Vector4(
			float(state.get("puddle_scale", 0.12)),
			float(state.get("puddle_reflect", 0.75)),
			float(state.get("wet_darken", 0.45)),
			float(state.get("model_puddles", 0.0))
		)
		var cov := float(state.get("cloud_cover", -1.0))
		clouds = Vector4(
			clampf(cov, 0.0, 1.0),
			float(state.get("cloud_darkness", 0.0)),
			1.0 if cov >= 0.0 else 0.0,
			float(state.get("flash", 0.0))
		)
		var w_str := float(state.get("wind_strength", 1.0))
		var use_drift := 1.0 if bool(state.get("has_wind", false)) else 0.0
		wind_g = Vector4(cloud_drift.x, cloud_drift.y, w_str, use_drift)
		grass = w_str if base_grass_wind else 0.0
		var live: int = _impulses.size()
		if not splashes_disabled and not disabled and live > 0:
			if _imp_image == null:
				_imp_image = Image.create(MAX_IMPULSES, 2, false, Image.FORMAT_RGBAF)
				_imp_data.resize(MAX_IMPULSES * 2 * 4)
				_imp_data.fill(0.0)
				_imp_tex = ImageTexture.create_from_image(_imp_image)
				RenderingServer.global_shader_parameter_set(GLOBAL_IMPULSES, _imp_tex)
			elif not _imp_was_active:
				RenderingServer.global_shader_parameter_set(GLOBAL_IMPULSES, _imp_tex)
			var min_x := INF
			var min_z := INF
			var max_x := -INF
			var max_z := -INF
			var row1_base: int = MAX_IMPULSES * 4
			for i: int in range(live):
				var rec: Array = _impulses[i]
				var x: float = float(rec[0])
				var z: float = float(rec[1])
				var spawn_t: float = float(rec[2])
				var max_r: float = float(rec[3])
				var dx: float = float(rec[4])
				var dz: float = float(rec[5])
				var amp: float = float(rec[6])
				var life: float = float(rec[7])
				var o0: int = i * 4
				_imp_data[o0] = x
				_imp_data[o0 + 1] = z
				_imp_data[o0 + 2] = spawn_t
				_imp_data[o0 + 3] = max_r
				var o1: int = row1_base + o0
				_imp_data[o1] = dx
				_imp_data[o1 + 1] = dz
				_imp_data[o1 + 2] = amp
				_imp_data[o1 + 3] = life
				min_x = minf(min_x, x - max_r)
				min_z = minf(min_z, z - max_r)
				max_x = maxf(max_x, x + max_r)
				max_z = maxf(max_z, z + max_r)
			_imp_image.set_data(MAX_IMPULSES, 2, false, Image.FORMAT_RGBAF, _imp_data.to_byte_array())
			_imp_tex.update(_imp_image)
			imp_info = Vector4(float(live), _imp_clock, _imp_strength, 1.0)
			imp_bounds = Vector4(min_x, min_z, max_x, max_z)
			_imp_was_active = true
		elif _imp_was_active:
			_imp_was_active = false
	elif _imp_was_active:
		_imp_was_active = false
	last_globals = {
		"f3d_weather_wet": wet,
		"f3d_weather_puddle": puddle,
		"f3d_weather_clouds": clouds,
		"f3d_weather_wind": wind_g,
		"f3d_grass_wind": grass,
		"f3d_weather_impulse_info": imp_info,
		"f3d_weather_impulse_bounds": imp_bounds,
		"f3d_wet_metal": wet_metal,
	}
	RenderingServer.global_shader_parameter_set(GLOBAL_WET, wet)
	RenderingServer.global_shader_parameter_set(GLOBAL_PUDDLE, puddle)
	RenderingServer.global_shader_parameter_set(GLOBAL_CLOUDS, clouds)
	RenderingServer.global_shader_parameter_set(GLOBAL_WIND, wind_g)
	RenderingServer.global_shader_parameter_set(GLOBAL_GRASS_WIND, grass)
	RenderingServer.global_shader_parameter_set(GLOBAL_IMPULSE_INFO, imp_info)
	RenderingServer.global_shader_parameter_set(GLOBAL_IMPULSE_BOUNDS, imp_bounds)
	RenderingServer.global_shader_parameter_set(GLOBAL_WET_METAL, wet_metal)
