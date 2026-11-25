extends Node3D
## The sky over a planet and the weather on its ground: a sky dome (shaders/planet_sky.gdshader)
## with a gradient, the sun, stars at night and clouds; the clouds' soft shadows drifting over the
## ground and, where the planet has it, a coloured haze (shaders/cloud_shadows.gdshader, one
## full-screen pass); and the sun and ambient light's colours. All of it follows the game's time of
## day, which main.gd eases and hands to apply().
##
## How the sun goes down is the look's to say (`twilight`, looks.gd). At 0, the Factorio and Classic
## looks: the old sun, which never sets and fades in mid-sky. Above 0 sun_model() takes over: one
## driving value, the sun's elevation, follows the game's own darkness down below the horizon, and the
## light, its colour, the ambient light, the sky, the clouds and the water are all curves over it.
##
## Each planet looks as Factorio draws it (`surface_render_parameters` in its planet prototype):
## Nauvis, Gleba and Fulgora have clouds (shadow opacity 0.25, Fulgora's stormier and darker at
## night, with lightning), Vulcanus and Gleba have fog (yellow; yellow and green), Aquilo neither,
## under a cold dim sky. Space platforms keep shaders/space_sky.gdshader (main.gd).
##
## Clouds can be turned off (Settings, graphics "clouds"); `--clean-shot` and `--review-shots` turn
## them off too, so model screenshots stay clean. `--sky=<planet>[@<daytime 0..1>]` shows another
## planet's sky (and holds the time of day), for screenshots against the mock.

const SKY_SHADER := preload("res://shaders/planet_sky.gdshader")
const SHADOW_SHADER := preload("res://shaders/cloud_shadows.gdshader")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const WeatherState := preload("res://scripts/world/weather_state.gd")
const Switches := preload("res://scripts/switches.gd")

## Per planet: sky by day and night, sun and ambient light by day and night, clouds (shadow
## opacity, cover: lower is more cloud, 1 none), haze (strength and its two colours), lightning.
## `twilight` is what sun_model() goes through between day and night, each pair [golden hour, blue
## hour]: `scatter` the air's optical depth per colour (how the sun reddens), the sky's top, its
## horizon away from the sun and towards it, the pink band opposite the sun, the ambient light;
## `dawn` overrides any of those for the morning.
const PLANETS := {
	"nauvis": {
		"zenith": [Color(0.27, 0.47, 0.76), Color(0.012, 0.02, 0.05)],
		"horizon": [Color(0.7, 0.8, 0.88), Color(0.05, 0.07, 0.12)],
		"sun": [Color(1.0, 0.97, 0.92), Color(0.6, 0.68, 0.95)], "sun_energy": [1.1, 0.12],
		"ambient": [Color(0.75, 0.78, 0.82), Color(0.35, 0.42, 0.6)], "ambient_energy": [0.6, 0.12],
		"shadow": 0.25, "cover": 0.46, "clouds": [Color(1.0, 1.0, 1.0), Color(0.6, 0.65, 0.72)],
		"haze": 0.0, "stars": 1.0,
		"twilight": {
			"scatter": Color(0.02, 0.075, 0.18),
			"zenith": [Color(0.2, 0.34, 0.64), Color(0.06, 0.1, 0.3)],
			"horizon": [Color(0.62, 0.62, 0.72), Color(0.26, 0.24, 0.46)],
			"sun_side": [Color(1.0, 0.58, 0.24), Color(0.92, 0.32, 0.14)],
			"belt": Color(0.86, 0.5, 0.58),
			"ambient": [Color(0.62, 0.7, 0.98), Color(0.46, 0.5, 0.92)], "ambient_energy": [0.78, 2.6],
		},
		"dawn": {
			"scatter": Color(0.02, 0.085, 0.14),
			"sun_side": [Color(1.0, 0.58, 0.36), Color(0.94, 0.36, 0.34)],
			"horizon": [Color(0.68, 0.64, 0.76), Color(0.3, 0.26, 0.48)],
		},
	},
	"vulcanus": {
		"zenith": [Color(0.36, 0.2, 0.12), Color(0.05, 0.025, 0.02)],
		"horizon": [Color(0.86, 0.56, 0.3), Color(0.2, 0.08, 0.04)],
		"sun": [Color(1.0, 0.8, 0.58), Color(0.75, 0.42, 0.3)], "sun_energy": [1.15, 0.14],
		"ambient": [Color(0.85, 0.68, 0.52), Color(0.45, 0.28, 0.22)], "ambient_energy": [0.62, 0.15],
		"shadow": 0.0, "cover": 1.0, "clouds": [Color(0.9, 0.7, 0.5), Color(0.4, 0.25, 0.18)],
		"haze": 0.045, "haze_colors": [Color(1.0, 0.87, 0.3), Color(1.0, 0.87, 0.29)], "stars": 0.25,
		"twilight": {
			"scatter": Color(0.025, 0.09, 0.18),
			"zenith": [Color(0.3, 0.14, 0.1), Color(0.14, 0.06, 0.05)],
			"horizon": [Color(0.72, 0.36, 0.2), Color(0.34, 0.13, 0.08)],
			"sun_side": [Color(1.0, 0.42, 0.14), Color(0.68, 0.18, 0.06)],
			"belt": Color(0.6, 0.26, 0.2),
			"ambient": [Color(0.82, 0.58, 0.46), Color(0.58, 0.3, 0.22)], "ambient_energy": [0.8, 1.8],
		},
	},
	"gleba": {
		"zenith": [Color(0.42, 0.55, 0.42), Color(0.02, 0.04, 0.03)],
		"horizon": [Color(0.78, 0.82, 0.62), Color(0.07, 0.1, 0.07)],
		"sun": [Color(0.97, 1.0, 0.84), Color(0.55, 0.7, 0.6)], "sun_energy": [1.0, 0.12],
		"ambient": [Color(0.72, 0.8, 0.66), Color(0.32, 0.42, 0.36)], "ambient_energy": [0.62, 0.13],
		"shadow": 0.25, "cover": 0.46, "clouds": [Color(0.92, 0.95, 0.85), Color(0.55, 0.62, 0.52)],
		"haze": 0.025, "haze_colors": [Color(1.0, 0.85, 0.55), Color(0.72, 1.0, 0.66)], "stars": 0.6,
		"twilight": {
			"scatter": Color(0.022, 0.11, 0.07),
			"zenith": [Color(0.3, 0.36, 0.42), Color(0.1, 0.1, 0.18)],
			"horizon": [Color(0.72, 0.58, 0.62), Color(0.28, 0.2, 0.3)],
			"sun_side": [Color(1.0, 0.5, 0.56), Color(0.8, 0.28, 0.44)],
			"belt": Color(0.74, 0.5, 0.66),
			"ambient": [Color(0.66, 0.66, 0.82), Color(0.38, 0.34, 0.62)], "ambient_energy": [0.68, 1.6],
		},
		"dawn": {
			"scatter": Color(0.055, 0.03, 0.045),
			"zenith": [Color(0.3, 0.4, 0.44), Color(0.09, 0.14, 0.18)],
			"horizon": [Color(0.66, 0.72, 0.68), Color(0.24, 0.3, 0.32)],
			"sun_side": [Color(0.82, 0.92, 0.74), Color(0.5, 0.68, 0.64)],
			"belt": Color(0.62, 0.72, 0.72),
			"ambient": [Color(0.62, 0.74, 0.8), Color(0.36, 0.46, 0.6)],
		},
	},
	"fulgora": {
		"zenith": [Color(0.3, 0.26, 0.4), Color(0.015, 0.01, 0.035)],
		"horizon": [Color(0.68, 0.58, 0.7), Color(0.07, 0.04, 0.1)],
		"sun": [Color(0.95, 0.86, 1.0), Color(0.5, 0.45, 0.85)], "sun_energy": [0.95, 0.08],
		"ambient": [Color(0.7, 0.66, 0.8), Color(0.3, 0.25, 0.48)], "ambient_energy": [0.56, 0.1],
		"shadow": 0.25, "cover": 0.4, "clouds": [Color(0.75, 0.7, 0.82), Color(0.3, 0.27, 0.38)],
		"haze": 0.0, "stars": 0.5, "lightning": true,
		"twilight": {
			"scatter": Color(0.022, 0.05, 0.032),
			"zenith": [Color(0.22, 0.18, 0.36), Color(0.08, 0.05, 0.18)],
			"horizon": [Color(0.56, 0.48, 0.64), Color(0.24, 0.17, 0.36)],
			"sun_side": [Color(0.82, 0.68, 0.84), Color(0.52, 0.34, 0.68)],
			"belt": Color(0.6, 0.46, 0.66),
			"ambient": [Color(0.6, 0.56, 0.86), Color(0.4, 0.32, 0.7)], "ambient_energy": [0.62, 2.0],
		},
	},
	"aquilo": {
		"zenith": [Color(0.42, 0.52, 0.66), Color(0.01, 0.015, 0.035)],
		"horizon": [Color(0.75, 0.82, 0.9), Color(0.05, 0.07, 0.11)],
		"sun": [Color(0.85, 0.92, 1.0), Color(0.5, 0.6, 0.9)], "sun_energy": [0.75, 0.08],
		"ambient": [Color(0.72, 0.8, 0.92), Color(0.3, 0.36, 0.55)], "ambient_energy": [0.52, 0.1],
		"shadow": 0.0, "cover": 1.0, "clouds": [Color(0.9, 0.94, 1.0), Color(0.5, 0.56, 0.66)],
		"haze": 0.02, "haze_colors": [Color(0.85, 0.92, 1.0), Color(0.75, 0.85, 1.0)], "stars": 1.0,
		"twilight": {
			"scatter": Color(0.012, 0.035, 0.07),
			"zenith": [Color(0.3, 0.42, 0.62), Color(0.08, 0.13, 0.3)],
			"horizon": [Color(0.72, 0.72, 0.84), Color(0.3, 0.32, 0.54)],
			"sun_side": [Color(1.0, 0.8, 0.66), Color(0.86, 0.56, 0.62)],
			"belt": Color(0.8, 0.62, 0.74),
			"ambient": [Color(0.64, 0.74, 1.0), Color(0.48, 0.54, 0.86)], "ambient_energy": [0.56, 0.5],
		},
	},
}
const CLOUD_HEIGHT := 70.0
## Factorio's day on every planet (planet.lua's comments): darkness is 0 until the sun starts to
## set at daytime 0.25, full (0.85) from 0.45 to 0.55, and back to 0 at 0.75.
const DUSK := 0.25
const EVENING := 0.45
const MORNING := 0.55
const DAWN := 0.75
const FULL_DARKNESS := 0.85
## The sun's elevation in degrees (sun_elevation), and how far down the light follows it: a sun
## lower than LIGHT_FLOOR still lights from there, as a shadow map's texels stretch by 1 / sin of
## the angle and world.gd only gathers shadow casters for 14 degrees and up.
const E_NOON := 60.0
const E_DUSK := 18.0
const E_SET := -8.0
const LIGHT_FLOOR := 14.0
## Where the sun is round the sky (DirectionalLight3D's yaw, 0 south, 90 east): high in the south
## and a little west at noon as the old sun is, setting in the west with a little north: three
## quarters behind what the default view looks at, for the most relief.
const YAW_NOON := -30.0
## On a space platform there is no air to light the shade: the ambient light is this much of the
## planet's by day and turns a cold neutral, while the sun keeps its direction and strength (Factorio
## lights a platform as by day). Space itself is near black (space_sky.gdshader), as Factorio's.
const SPACE_AMBIENT := 0.65
const SPACE_AMBIENT_COLOR := Color(0.7, 0.74, 0.84)
const SPACE_BACKGROUND := Color(0.004, 0.004, 0.009)
const LOW_SUN_ENERGY := 2.1
## How much paler the light is than the sun's disc: a full-strength orange turns the ground into a
## filtered picture of itself.
const LIGHT_PALE := 0.22
const YAW_RISE := 102.0
const YAW_SET := -102.0
## Water's sky tint by day (water.gdshader's default).
const WATER_SKY := Color(0.5, 0.62, 0.72)
## Lightning on Fulgora: seconds between strikes at night.
const LIGHTNING_GAP := Vector2(3.0, 12.0)

## --sun-step=<degrees>, for measuring only (0, the default: smooth): the sun's light holds its pitch
## and yaw until the sun has moved more than this from where it was last put, then jumps there. The
## shadow map is only rasterised anew when the light turns; this measures whether resting it helps
## the shadows' crawl (shadows-bp.md: a step that doesn't pop is as frequent as smooth). The sky's
## sun, `state` and the passes stay smooth.
static var sun_step := _sun_step_arg()
static var _shape_tex: Texture2D
static var _detail_tex: Texture2D
static var _loading := false
## Images read by the background task, made into textures on the main thread.
static var _loaded: Array = []
static var _loaded_lock := Mutex.new()

var planet := "nauvis"
var clouds_on := true
var sky_material := ShaderMaterial.new()
var _shadow_material := ShaderMaterial.new()
var _shadow_quad := MeshInstance3D.new()
var _p: Dictionary = PLANETS["nauvis"]
var _flash := 0.0
var _lightning_wait := 5.0
## From --sky=<planet>@<daytime>: the planet always shown, and the time of day held (-1: the game's).
var _forced_planet := ""
var forced_daytime := -1.0
var _clouds_forced_off := false
## How much of the sunset the look in use wants for the light and for the sky (looks.gd; main.gd
## sets them each frame). A look can have a setting sun in the sky over a light held still.
var twilight := 0.0
var sky_twilight := 0.0
## Where the look in use wants the noon sun (its sun_noon_yaw; main.gd sets it each frame): YAW_NOON unless it says.
var noon_yaw := YAW_NOON
## This frame's sun for looks and add-ons (looks.gd, api.shaders.sun()): elevation (degrees), height
## (its sine), twilight (0-1, as the look asked), morning, direction (towards the sun), color,
## ambient, fog (the sky's colour on the sun's side).
var state := {}
var sky_sun_dir := Vector3(0.0, 0.7, -0.7)
var sky_sun_strength := 1.0
var _cloud_alpha := 0.0
var _haze_now := 0.0
var _water_tint := Color(-1.0, 0.0, 0.0)  # none yet: the shared material may hold the last game's
## The light's rotation last put, with --sun-step (null: none yet).
var _held_sun: Variant = null
var _sky_cache := {}
var _weather_cloud_dirty := false
var _weather_haze_dirty := false


func _set_sky_param(key: String, val: Variant) -> void:
	if _sky_cache.has(key):
		var prev: Variant = _sky_cache[key]
		if val is float and prev is float and absf(float(val) - float(prev)) <= 1e-4:
			return
		if val is Vector3 and prev is Vector3 and (val as Vector3).distance_squared_to(prev as Vector3) <= 1e-8:
			return
		if val is Color and prev is Color:
			var c: Color = val
			var p: Color = prev
			if absf(c.r - p.r) <= 1e-4 and absf(c.g - p.g) <= 1e-4 and absf(c.b - p.b) <= 1e-4 and absf(c.a - p.a) <= 1e-4:
				return
	_sky_cache[key] = val
	sky_material.set_shader_parameter(key, val)


static func _sun_step_arg() -> float:
	for arg in Switches.args():
		if arg.begins_with("--sun-step="):
			return maxf(float(arg.get_slice("=", 1)), 0.0)
	return 0.0


## The light's rotation (degrees) with a step: `held` (null: none yet) until `want` points more than
## `step` degrees away from it, then `want`. Step 0 is `want` always.
static func stepped_sun(held: Variant, want: Vector3, step: float) -> Vector3:
	if step <= 0.0 or held == null:
		return want
	var was: Vector3 = held
	var a := Basis.from_euler(was * (PI / 180.0)).z
	var b := Basis.from_euler(want * (PI / 180.0)).z
	return want if rad_to_deg(a.angle_to(b)) > step else was


func _ready() -> void:
	sky_material.shader = SKY_SHADER
	sky_material.set_shader_parameter("cloud_height", CLOUD_HEIGHT)
	_shadow_material.shader = SHADOW_SHADER
	_shadow_material.set_shader_parameter("cloud_height", CLOUD_HEIGHT)
	_shadow_material.render_priority = -100  # before the other see-through things: ghosts, smoke
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	_shadow_quad.mesh = quad
	_shadow_quad.material_override = _shadow_material
	_shadow_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shadow_quad.extra_cull_margin = 16384.0  # it covers the screen wherever it is
	_shadow_quad.name = "CloudShadows"
	add_child(_shadow_quad)
	for arg in Switches.args():
		if arg.begins_with("--sky="):
			var spec := arg.get_slice("=", 1)
			_forced_planet = spec.get_slice("@", 0)
			if spec.contains("@"):
				forced_daytime = float(spec.get_slice("@", 1))
		elif arg == "--clean-shot" or arg.begins_with("--review-shots="):
			_clouds_forced_off = true
			clouds_on = false
	set_planet(_forced_planet if _forced_planet != "" else "nauvis")
	_load_noise()


func _exit_tree() -> void:
	Visuals.water_material().set_shader_parameter("sky_tint", WATER_SKY)  # the menu's water is by day
	# Textures still held at quit would be reported as leaked; the next game loads them again.
	_shape_tex = null
	_detail_tex = null
	_loading = false
	_sky_cache.clear()
	sky_material.set_shader_parameter("cloud_shape", null)
	sky_material.set_shader_parameter("cloud_detail", null)
	_shadow_material.set_shader_parameter("cloud_shape", null)
	_shadow_material.set_shader_parameter("cloud_detail", null)


## Factorio's darkness at a time of day, for `--sky=<planet>@<daytime>`, which has no game to ask.
static func darkness_at(daytime: float) -> float:
	var d := fposmod(daytime, 1.0)
	if d <= DUSK or d >= DAWN:
		return 0.0
	if d < EVENING:
		return FULL_DARKNESS * (d - DUSK) / (EVENING - DUSK)
	if d <= MORNING:
		return FULL_DARKNESS
	return FULL_DARKNESS * (DAWN - d) / (DAWN - MORNING)


## The sun's elevation in degrees. The high part follows the time of day and the low part the
## game's darkness, so it is continuous whenever a surface's dusk and dawn come. Crosses the horizon
## at night 0.69.
static func sun_elevation(daytime: float, night: float) -> float:
	var high := maxf(cos(TAU * daytime), 0.0)
	return lerpf(lerpf(E_DUSK, E_NOON, high), E_SET, night)


## Which way the sun is (light yaw, degrees): swinging out to the side it rises or sets on as it
## gets lower. The same at noon either way, and at night nobody sees it. `noon`: where it stands at
## noon (a look's sun_noon_yaw); it still rises in the east and sets in the west, each the short way
## round from there (a noon in the north crosses the north).
static func sun_yaw(elevation: float, morning: bool, noon := YAW_NOON) -> float:
	var t := clampf((E_NOON - elevation) / E_NOON, 0.0, 1.0)
	var end := YAW_RISE if morning else YAW_SET
	return lerpf(noon, noon + wrapf(end - noon, -180.0, 180.0), t)


## How much air the sun's light crosses against straight up (Kasten and Young's formula).
static func air_mass(elevation: float) -> float:
	var e := maxf(elevation, 0.0)
	return 1.0 / (sin(deg_to_rad(e)) + 0.50572 * pow(e + 6.07995, -1.6364))


## What the air leaves of the sun's light, the brightest channel 1 and white at noon: gold about 12
## degrees up on Nauvis, orange at 5, deep red at the horizon.
static func sun_tint(scatter: Color, elevation: float) -> Color:
	var m := maxf(air_mass(elevation) - air_mass(E_NOON), 0.0)
	var t := Color(exp(-scatter.r * m), exp(-scatter.g * m), exp(-scatter.b * m))
	var top := maxf(t.r, maxf(t.g, t.b))
	return Color(t.r / top, t.g / top, t.b / top)


## 0 by day and deep night, 1 with the sun at the horizon.
static func twilight_at(elevation: float) -> float:
	return smoothstep(30.0, 8.0, elevation) * smoothstep(-7.0, 1.0, elevation)


## How far into [golden hour, blue hour, night] a sun at this elevation is.
static func _phases(e: float) -> Vector3:
	return Vector3(smoothstep(32.0, 8.0, e), smoothstep(5.0, -3.0, e), smoothstep(-3.0, E_SET, e))


static func _through(day: Color, pair: Array, night: Color, w: Vector3) -> Color:
	return day.lerp(pair[0], w.x).lerp(pair[1], w.y).lerp(night, w.z)


## The whole sun at a moment, for a planet's row of PLANETS, whatever the look: what sky.gd sets when
## a look has a `twilight`. Pure, so it can be checked. The light leaves as the sun reaches the
## horizon and comes back as the moon from the other side of the sky: the swap happens with no light
## at all, so nothing pops.
static func sun_model(p: Dictionary, daytime: float, night: float, noon := YAW_NOON) -> Dictionary:
	var day := fposmod(daytime, 1.0)
	var morning := day > 0.5
	var e := sun_elevation(day, night)
	var yaw := sun_yaw(e, morning, noon)
	var w := _phases(e)
	var tw: Dictionary = p["twilight"]
	if morning and p.has("dawn"):
		tw = tw.merged(p["dawn"], true)
	var sun_day: Color = p["sun"][0]
	var tint := sun_tint(tw["scatter"], e)
	var sun_color := Color(sun_day.r * tint.r, sun_day.g * tint.g, sun_day.b * tint.b)
	var day_energy := float(p["sun_energy"][0])
	var night_energy := float(p["sun_energy"][1])
	var out := {
		"elevation": e, "morning": morning, "twilight": twilight_at(e), "sun_color": sun_color,
		"sky_dir": _towards(e, yaw),
	}
	if e < -1.0:
		# Across the night's sky from east to west, high in the south at midnight.
		var across := clampf((day - 0.3) / 0.4, 0.0, 1.0)
		out["light_pitch"] = 34.0 + 16.0 * sin(PI * across)
		out["light_yaw"] = lerpf(75.0, -75.0, across)
		out["light_color"] = p["sun"][1]
		out["light_energy"] = night_energy * smoothstep(-2.0, -7.0, e)
	else:
		out["light_pitch"] = maxf(e, LIGHT_FLOOR)
		out["light_yaw"] = yaw
		var grey := sun_color.get_luminance()
		out["light_color"] = sun_color.lerp(Color(grey, grey, grey), LIGHT_PALE * w.x)
		# A low sun spreads over more ground: stronger, so what it reaches isn't dim, and fading only
		# in the last few degrees.
		out["light_energy"] = day_energy * smoothstep(0.0, 5.0, e) * lerpf(LOW_SUN_ENERGY, 1.0, smoothstep(8.0, 45.0, e))
	var amb_e: Array = tw["ambient_energy"]
	out["ambient"] = _through(p["ambient"][0], tw["ambient"], p["ambient"][1], w)
	out["ambient_energy"] = lerpf(lerpf(lerpf(float(p["ambient_energy"][0]), float(amb_e[0]), w.x), float(amb_e[1]), w.y), float(p["ambient_energy"][1]), w.z)
	out["zenith"] = _through(p["zenith"][0], tw["zenith"], p["zenith"][1], w)
	out["horizon"] = _through(p["horizon"][0], tw["horizon"], p["horizon"][1], w)
	out["sun_side"] = _through(p["horizon"][0], tw["sun_side"], p["horizon"][1], w)
	out["belt"] = tw["belt"]
	out["belt_strength"] = smoothstep(10.0, 1.0, e) * smoothstep(E_SET, -4.0, e)
	out["sun_strength"] = smoothstep(-6.0, 1.0, e)
	out["stars"] = smoothstep(-2.0, -7.0, e)
	# Clouds stay lit a few degrees longer than the ground.
	out["cloud_lit"] = lerpf(0.12, 1.0, smoothstep(-6.0, 2.0, e))
	out["cloud_shadow"] = smoothstep(1.0, 12.0, e)
	return out


## Towards a sun at this elevation and yaw, as a DirectionalLight3D's basis.z there would be.
static func _towards(elevation: float, yaw: float) -> Vector3:
	var e := deg_to_rad(elevation)
	var y := deg_to_rad(yaw)
	return Vector3(cos(e) * sin(y), sin(e), cos(e) * cos(y))


## Water's sky tint for what the sky is now: as bright as by day (the water is lit, so it darkens
## with the light anyway), its colour following the horizon's change from noon.
static func water_tint(now: Color, noon: Color) -> Color:
	var ratio := Color(now.r / maxf(noon.r, 0.01), now.g / maxf(noon.g, 0.01), now.b / maxf(noon.b, 0.01))
	var t := Color(WATER_SKY.r * ratio.r, WATER_SKY.g * ratio.g, WATER_SKY.b * ratio.b)
	var scale := WATER_SKY.get_luminance() / maxf(t.get_luminance(), 0.001)
	return Color(minf(t.r * scale, 1.0), minf(t.g * scale, 1.0), minf(t.b * scale, 1.0))


## The planet whose sky this is (unknown names, like a modded surface, look like Nauvis).
func set_planet(name: String) -> void:
	if _forced_planet != "":
		name = _forced_planet
	planet = name if PLANETS.has(name) else "nauvis"
	_p = PLANETS[planet]
	_set_sky_param("cloud_cover", float(_p["cover"]))
	_shadow_material.set_shader_parameter("cloud_cover", float(_p["cover"]))
	var hz: Array = _p.get("haze_colors", [Color.WHITE, Color.WHITE])
	_shadow_material.set_shader_parameter("haze_color", hz[0])
	_shadow_material.set_shader_parameter("haze_color2", hz[1])
	_set_sky_param("haze_color", hz[0].lerp(_pair("horizon", 0.0), 0.5))


func set_clouds(on: bool) -> void:
	clouds_on = on and not _clouds_forced_off


## Lights the scene for the time of day: `daytime` 0 is noon, 0.5 midnight; `night` 0 to 1 is how
## dark it is. Sets the sun's angle and colour, the ambient light, the sky and the clouds.
func apply(env: Environment, sun: DirectionalLight3D, daytime: float, night: float, delta: float, space: bool) -> void:
	# No dusk on a platform, whatever the planet below is doing.
	var warm := 0.0 if space else clampf(twilight, 0.0, 1.0)
	var sky_warm := 0.0 if space else clampf(sky_twilight, 0.0, 1.0)
	var m := sun_model(_p, daytime, night, noon_yaw)
	var high := clampf(cos(TAU * daytime) * 0.5 + 0.5, 0.0, 1.0)  # 1 at noon, 0 at midnight
	# The look's noon side here too (a look with no sunset, or its slider at 0); YAW_NOON (-30) without one, as before.
	sun.rotation_degrees = Vector3(-lerpf(20.0, 60.0, high), noon_yaw + 60.0 * sin(TAU * daytime), 0.0)
	sun.light_energy = lerpf(_p["sun_energy"][0], _p["sun_energy"][1], night)
	sun.light_color = _pair("sun", night)
	env.ambient_light_energy = lerpf(_p["ambient_energy"][0], _p["ambient_energy"][1], night)
	env.ambient_light_color = _pair("ambient", night)
	if warm > 0.0:
		# The sun's path and energy whole at any strength (a light moved while it shines would pop);
		# the strength is how warm it gets.
		sun.rotation_degrees = Vector3(-float(m["light_pitch"]), float(m["light_yaw"]), 0.0)
		sun.light_energy = float(m["light_energy"])
		sun.light_color = sun.light_color.lerp(m["light_color"], warm) if float(m["elevation"]) >= -1.0 else m["light_color"]
		env.ambient_light_energy = lerpf(env.ambient_light_energy, float(m["ambient_energy"]), warm)
		env.ambient_light_color = env.ambient_light_color.lerp(m["ambient"], warm)
	var zenith := _pair("zenith", night)
	var horizon := _pair("horizon", night)
	var sun_side := horizon
	if sky_warm > 0.0:
		zenith = zenith.lerp(m["zenith"], sky_warm)
		sun_side = horizon.lerp(m["sun_side"], sky_warm)
		horizon = horizon.lerp(m["horizon"], sky_warm)
	var wx_on := not space and WeatherState.active
	var wx: Dictionary = WeatherState.state if wx_on else {}
	if wx_on:
		sun.light_energy *= float(wx.get("sun_energy_scale", 1.0))
		var st_amt := float(wx.get("sun_tint_amount", 0.0))
		if st_amt > 0.0 and wx.get("sun_color_tint") is Color:
			sun.light_color = sun.light_color.lerp(wx["sun_color_tint"], st_amt)
		env.ambient_light_energy *= float(wx.get("ambient_energy_scale", 1.0))
		var at_amt := float(wx.get("ambient_tint_amount", 0.0))
		if at_amt > 0.0 and wx.get("ambient_tint") is Color:
			env.ambient_light_color = env.ambient_light_color.lerp(wx["ambient_tint"], at_amt)
		var sky_amt := float(wx.get("sky_tint_amount", 0.0))
		if sky_amt > 0.0:
			if wx.get("sky_zenith_tint") is Color:
				zenith = zenith.lerp(wx["sky_zenith_tint"], sky_amt)
			if wx.get("sky_horizon_tint") is Color:
				horizon = horizon.lerp(wx["sky_horizon_tint"], sky_amt)
				sun_side = sun_side.lerp(wx["sky_horizon_tint"], sky_amt * 0.85)
	env.background_color = horizon
	if space:
		env.ambient_light_energy *= SPACE_AMBIENT
		env.ambient_light_color = env.ambient_light_color.lerp(SPACE_AMBIENT_COLOR, 0.6)
		env.background_color = SPACE_BACKGROUND
	var wx_flash := float(wx.get("flash", 0.0)) if wx_on else 0.0
	var eff_flash := _update_lightning(env, delta, night, wx_flash)
	if not _loaded.is_empty():
		_take_loaded()
	var to_sun := sun.global_transform.basis.z.normalized()
	if sun_step > 0.0:
		# The light alone steps; to_sun above (the sky, state, the passes) stays smooth.
		_held_sun = stepped_sun(_held_sun, sun.rotation_degrees, sun_step)
		sun.rotation_degrees = _held_sun
	var sky_sun := to_sun
	var sun_color := sun.light_color
	if sky_warm > 0.0:
		sky_sun = m["sky_dir"]
		sun_color = _pair("sun", 0.0).lerp(m["sun_color"], sky_warm)
		if wx_on:
			var st_amt2 := float(wx.get("sun_tint_amount", 0.0))
			if st_amt2 > 0.0 and wx.get("sun_color_tint") is Color:
				sun_color = sun_color.lerp(wx["sun_color_tint"], st_amt2)
	state = {
		"elevation": float(m["elevation"]), "height": sin(deg_to_rad(float(m["elevation"]))),
		"twilight": float(m["twilight"]) * warm, "morning": bool(m["morning"]),
		"direction": sky_sun if warm > 0.0 else to_sun, "color": sun_color if warm > 0.0 else sun.light_color,
		"ambient": env.ambient_light_color, "fog": sun_side.lerp(horizon, 0.35),
	}
	var w_cov := float(wx.get("cloud_cover", -1.0)) if wx_on else -1.0
	var cloudy := clouds_on and float(_p["cover"]) < 1.0
	if w_cov >= 0.0:
		_weather_cloud_dirty = true
		var cov := clampf(w_cov, 0.0, 1.0)
		var eff_cover := lerpf(1.25, -0.15, cov)
		_set_sky_param("cloud_cover", eff_cover)
		_shadow_material.set_shader_parameter("cloud_cover", eff_cover)
		cloudy = clouds_on and cov > 0.005
	elif _weather_cloud_dirty:
		_weather_cloud_dirty = false
		_set_sky_param("cloud_cover", float(_p["cover"]))
		_shadow_material.set_shader_parameter("cloud_cover", float(_p["cover"]))
	# Shadows fade as the light does; Factorio's clouds shade daylight, not the lamps' light.
	var fades := float(m["cloud_shadow"]) if warm > 0.0 else 1.0 - night
	var shadow_strength := float(_p["shadow"]) * fades if cloudy else 0.0
	var haze_strength := float(_p["haze"]) * (1.0 - 0.6 * night)
	var w_haze := float(wx.get("haze_strength", 0.0)) if wx_on else 0.0
	if w_haze > 0.0001:
		_weather_haze_dirty = true
		haze_strength += w_haze * (1.0 - 0.55 * night)
		var whc: Color = wx.get("haze_color", Color(0.75, 0.8, 0.86))
		var hz: Array = _p.get("haze_colors", [Color.WHITE, Color.WHITE])
		var h_blend := clampf(w_haze / maxf(w_haze + float(_p["haze"]), 0.01), 0.0, 1.0)
		_shadow_material.set_shader_parameter("haze_color", (hz[0] as Color).lerp(whc, h_blend))
		_shadow_material.set_shader_parameter("haze_color2", (hz[1] as Color).lerp(whc, h_blend))
		_set_sky_param("haze_color", ((hz[0] as Color).lerp(_pair("horizon", 0.0), 0.5)).lerp(whc, h_blend))
	elif _weather_haze_dirty:
		_weather_haze_dirty = false
		var hz_base: Array = _p.get("haze_colors", [Color.WHITE, Color.WHITE])
		_shadow_material.set_shader_parameter("haze_color", hz_base[0])
		_shadow_material.set_shader_parameter("haze_color2", hz_base[1])
		_set_sky_param("haze_color", (hz_base[0] as Color).lerp(_pair("horizon", 0.0), 0.5))
	_cloud_alpha = (0.85 - 0.25 * night) if (cloudy and not space) else 0.0
	if wx_on and w_cov >= 0.0:
		var cov_fade := smoothstep(0.0, 0.08, clampf(w_cov, 0.0, 1.0))
		shadow_strength *= float(wx.get("cloud_shadow_scale", 1.0)) * cov_fade
		_cloud_alpha *= float(wx.get("cloud_alpha_scale", 1.0)) * cov_fade
	# Hidden whenever it would draw nothing (at night on a planet without haze): its pixels read the
	# depth and three textures before discarding every one of them.
	_shadow_quad.visible = not space and clouds_on and (shadow_strength > 0.0 or haze_strength > 0.0)
	sky_sun_dir = sky_sun
	var old_strength := clampf(to_sun.y * 4.0, 0.0, 1.0) * (1.0 - night)
	var sky_strength := float(m["sun_strength"]) if sky_warm > 0.0 else old_strength
	if wx_on:
		sky_strength *= float(wx.get("sun_disc_scale", 1.0))
	sky_sun_strength = 0.0 if space else sky_strength
	_haze_now = 0.0 if space else haze_strength
	if space:
		return
	_set_sky_param("zenith_color", zenith)
	_set_sky_param("horizon_color", horizon)
	_set_sky_param("horizon_sun_color", sun_side)
	_set_sky_param("ground_color", horizon * 0.45)
	_set_sky_param("sun_dir", sky_sun)
	_set_sky_param("sun_color", sun_color)
	_set_sky_param("sun_strength", sky_strength)
	_set_sky_param("twilight", float(m["twilight"]) * sky_warm)
	_set_sky_param("belt_color", m["belt"])
	_set_sky_param("belt", float(m["belt_strength"]) * sky_warm)
	var old_stars := smoothstep(0.4, 0.9, night)
	var star_scale := float(wx.get("star_visibility_scale", 1.0)) if wx_on else 1.0
	_set_sky_param("stars", float(_p["stars"]) * (float(m["stars"]) if sky_warm > 0.0 else old_stars) * star_scale)
	_set_sky_param("haze", (float(_p["haze"]) + w_haze) * 6.0)
	# Water follows the sky: its colour only in a look with no sunset, the warm horizon in one with.
	var water_sky := horizon.lerp(sun_side, 0.7 * float(m["twilight"]) * warm)
	var tint := water_tint(water_sky, _p["horizon"][0])
	if not tint.is_equal_approx(_water_tint):
		_water_tint = tint
		Visuals.water_material().set_shader_parameter("sky_tint", tint)
	_set_sky_param("flash", eff_flash)
	_set_sky_param("cloud_alpha", _cloud_alpha)
	# Lit by the sun by day, grey-blue shapes against the night sky.
	var cc: Array = _p["clouds"]
	var lit := lerpf(1.0, 0.12, night)
	var cloud_color := (cc[0] as Color) * lit
	var cloud_shade := (cc[1] as Color) * lit
	if sky_warm > 0.0:
		# Clouds catch the low sun, their shaded sides the sky's colour.
		var low_lit := float(m["cloud_lit"])
		var lit_sun := Color(cc[0].r * sun_color.r, cc[0].g * sun_color.g, cc[0].b * sun_color.b) * low_lit
		cloud_color = cloud_color.lerp(lit_sun, sky_warm)
		cloud_shade = cloud_shade.lerp(zenith.lerp(horizon, 0.5) * lerpf(0.5, 1.0, low_lit), sky_warm)
	if wx_on:
		var ct_amt := float(wx.get("cloud_tint_amount", 0.0))
		if ct_amt > 0.0 and wx.get("cloud_tint") is Color:
			var ct: Color = wx["cloud_tint"]
			cloud_color = cloud_color.lerp(ct * lit, ct_amt)
			cloud_shade = cloud_shade.lerp(ct * lit * 0.72, ct_amt)
		var c_dark := float(wx.get("cloud_darkness", 0.0))
		if c_dark > 0.0:
			cloud_color *= (1.0 - 0.55 * c_dark)
			cloud_shade *= (1.0 - 0.65 * c_dark)
	_set_sky_param("cloud_color", cloud_color)
	_set_sky_param("cloud_shade", cloud_shade)
	if _shadow_quad.visible:
		_shadow_material.set_shader_parameter("sun_dir", to_sun)
		_shadow_material.set_shader_parameter("shadow_strength", shadow_strength)
		_shadow_material.set_shader_parameter("haze_strength", haze_strength)


func _pair(key: String, night: float) -> Color:
	var pair: Array = _p[key]
	return (pair[0] as Color).lerp(pair[1], night)


## A strike the bridge reported (`lt`), `distance` tiles from the character: the sky and the ground
## flash with it, less the further off it is. With or without clouds (a look's own clouds turn
## Zenith's off, and the storm's flashes had gone with them).
func strike_flash(distance: float) -> void:
	_flash = maxf(_flash, clampf(1.0 - distance / 150.0, 0.25, 1.0) * 0.8)


## Fulgora's storms at night (and weather lightning flashes): a flash lights the sky and the ground for a moment.
func _update_lightning(env: Environment, delta: float, night: float, weather_flash := 0.0) -> float:
	_flash = maxf(0.0, _flash - delta * 5.0)
	if _p.get("lightning", false) and night > 0.4 and clouds_on:
		_lightning_wait -= delta
		if _lightning_wait <= 0.0:
			_lightning_wait = randf_range(LIGHTNING_GAP.x, LIGHTNING_GAP.y)
			_flash = randf_range(0.5, 1.0)
	var eff := maxf(_flash, weather_flash)
	if eff > 0.0:
		env.ambient_light_energy += eff * 0.35
		env.ambient_light_color = env.ambient_light_color.lerp(Color(0.75, 0.8, 1.0), clampf(eff, 0.0, 1.0) * 0.5)
	return eff


## Factorio's cloud noise from the player's install, loaded in the background and shared by every
## game; a generated noise stands in until then, or for good without an install.
func _load_noise() -> void:
	if _shape_tex == null:
		_shape_tex = _generated_noise(1)
		_detail_tex = _generated_noise(7)
		var data := ItemIcons.factorio_data_dir()
		if data != "" and not _loading:
			_loading = true
			var shape_path := data.path_join("core/graphics/clouds-noise.png")
			var detail_path := data.path_join("core/graphics/clouds-detail-noise.png")
			if FileAccess.file_exists(shape_path) and FileAccess.file_exists(detail_path):
				WorkerThreadPool.add_task(_load_images.bind(shape_path, detail_path), false, "cloud noise")
	_set_noise()


func _set_noise() -> void:
	for m: ShaderMaterial in [sky_material, _shadow_material]:
		m.set_shader_parameter("cloud_shape", _shape_tex)
		m.set_shader_parameter("cloud_detail", _detail_tex)


static func _load_images(shape_path: String, detail_path: String) -> void:
	var shape := Image.load_from_file(shape_path)
	var detail := Image.load_from_file(detail_path)
	if shape == null or detail == null or shape.is_empty() or detail.is_empty():
		return
	# A quarter of the size is plenty for soft shadows, and quick to sample.
	for img: Image in [shape, detail]:
		img.resize(512, 512, Image.INTERPOLATE_BILINEAR)
		img.generate_mipmaps()
	_loaded_lock.lock()
	_loaded = [shape, detail]
	_loaded_lock.unlock()


func _take_loaded() -> void:
	_loaded_lock.lock()
	var images := _loaded
	_loaded = []
	_loaded_lock.unlock()
	if images.size() == 2:
		_shape_tex = ImageTexture.create_from_image(images[0])
		_detail_tex = ImageTexture.create_from_image(images[1])
		_set_noise()


static func _generated_noise(seed_value: int) -> Texture2D:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 0.012
	noise.fractal_octaves = 3
	var tex := NoiseTexture2D.new()
	tex.width = 256
	tex.height = 256
	tex.seamless = true
	tex.generate_mipmaps = true
	tex.noise = noise
	return tex


## Current sky, sun, cloud, and planet haze snapshot for downstream volumetric passes (smog, god rays).
func atmosphere() -> Dictionary:
	var dir_val: Variant = state.get("direction", Vector3(0.0, 0.7, -0.7))
	var col_val: Variant = state.get("color", Color.WHITE)
	var amb_val: Variant = state.get("ambient", Color(0.75, 0.78, 0.82))
	var hz: Array = _p.get("haze_colors", [Color.WHITE, Color.WHITE])
	var eff_cover := float(_p["cover"])
	var has_clouds := eff_cover < 1.0
	if WeatherState.active and float(WeatherState.state.get("cloud_cover", -1.0)) >= 0.0:
		var cov := clampf(float(WeatherState.state["cloud_cover"]), 0.0, 1.0)
		eff_cover = lerpf(1.25, -0.15, cov)
		has_clouds = cov > 0.005
	var mode := 1 if (clouds_on and has_clouds and _shape_tex != null and _detail_tex != null) else 0
	return {
		"sun_dir": dir_val,
		"sky_sun_dir": sky_sun_dir,
		"sun_color": col_val,
		"ambient_color": amb_val,
		"sun_strength": sky_sun_strength,
		"twilight": float(state.get("twilight", 0.0)),
		"cloud_mode": mode,
		"cloud_shape": _shape_tex,
		"cloud_detail": _detail_tex,
		"cloud_cover": eff_cover,
		"cloud_height": CLOUD_HEIGHT,
		"cloud_alpha": _cloud_alpha,
		"haze": _haze_now,
		"haze_color": hz[0],
		"planet": planet,
		"god_rays_scale": float(WeatherState.state.get("god_rays_scale", 1.0)) if WeatherState.active else 1.0,
	}


static func _set_cached_param(mat: ShaderMaterial, cache: Dictionary, key: String, val: Variant) -> void:
	if cache.has(key):
		var prev: Variant = cache[key]
		if val is float and prev is float and absf(float(val) - float(prev)) <= 1e-4:
			return
		if val is Vector2 and prev is Vector2 and (val as Vector2).distance_squared_to(prev as Vector2) <= 1e-8:
			return
		if typeof(prev) == typeof(val) and prev == val:
			return
	cache[key] = val
	mat.set_shader_parameter(key, val)


## Binds the active cloud layer (0 none, 1 Zenith clouds, 2 look cloud_field) onto `mat`.
static func apply_cloud_uniforms(mat: ShaderMaterial, atmo: Dictionary, cache: Dictionary) -> void:
	var mode := int(atmo.get("cloud_mode", 0))
	var shape_tex: Texture2D = atmo.get("cloud_shape") as Texture2D
	var detail_tex: Texture2D = atmo.get("cloud_detail") as Texture2D
	var field_tex: Texture2D = atmo.get("look_cloud_field") as Texture2D
	if mode == 1 and (shape_tex == null or detail_tex == null):
		mode = 0
	elif mode == 2 and field_tex == null:
		mode = 0
	_set_cached_param(mat, cache, "cloud_mode", float(mode))
	if mode == 1:
		_set_cached_param(mat, cache, "cloud_shape", shape_tex)
		_set_cached_param(mat, cache, "cloud_detail", detail_tex)
		_set_cached_param(mat, cache, "cloud_cover", float(atmo.get("cloud_cover", 0.5)))
		_set_cached_param(mat, cache, "cloud_height", float(atmo.get("cloud_height", CLOUD_HEIGHT)))
		_set_cached_param(mat, cache, "cloud_alpha", float(atmo.get("cloud_alpha", 0.85)))
		if cache.get("look_cloud_field") != null:
			_set_cached_param(mat, cache, "look_cloud_field", null)
	elif mode == 2:
		var wind_val: Variant = atmo.get("look_cloud_wind", Vector2(3.2, 1.1))
		var wind: Vector2 = wind_val if wind_val is Vector2 else Vector2(3.2, 1.1)
		_set_cached_param(mat, cache, "look_cloud_field", field_tex)
		_set_cached_param(mat, cache, "look_cloud_cover", float(atmo.get("look_cloud_cover", 0.58)))
		_set_cached_param(mat, cache, "look_cloud_strength", float(atmo.get("look_cloud_strength", 1.0)))
		_set_cached_param(mat, cache, "look_cloud_low", float(atmo.get("look_cloud_low", 230.0)))
		_set_cached_param(mat, cache, "look_cloud_high", float(atmo.get("look_cloud_high", 300.0)))
		_set_cached_param(mat, cache, "look_cloud_scale", float(atmo.get("look_cloud_scale", 0.009)))
		_set_cached_param(mat, cache, "look_cloud_period", float(atmo.get("look_cloud_period", 16.0)))
		_set_cached_param(mat, cache, "look_cloud_wind", wind)
		if cache.get("cloud_shape") != null:
			_set_cached_param(mat, cache, "cloud_shape", null)
			_set_cached_param(mat, cache, "cloud_detail", null)
	else:
		if cache.get("cloud_shape") != null:
			_set_cached_param(mat, cache, "cloud_shape", null)
			_set_cached_param(mat, cache, "cloud_detail", null)
		if cache.get("look_cloud_field") != null:
			_set_cached_param(mat, cache, "look_cloud_field", null)


## Releases shared cloud textures from `mat` on exit so Godot reports no texture leaks.
static func clear_cloud_uniforms(mat: ShaderMaterial, cache: Dictionary) -> void:
	mat.set_shader_parameter("cloud_shape", null)
	mat.set_shader_parameter("cloud_detail", null)
	mat.set_shader_parameter("look_cloud_field", null)
	cache.clear()

