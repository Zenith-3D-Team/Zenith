extends Node
## Cinematic shaders: a look for Zenith (add-on API 1.5, api.shaders) that trades Factorio's flat,
## even picture for a filmic one with more depth and detail. The add-on is the look: while it is on,
## the world is drawn with it, and switching the add-on off (Settings > Add-ons) brings back Zenith's
## Factorio look, which has no settings of its own. Its sliders are on its page of the Add-ons menu.
##
## What it adds over Zenith's Factorio look, each at the GPU's cost:
##   - AgX tonemapping and a little more exposure: highlights roll off instead of clipping
##   - bloom: lamps, fire, lasers and molten metal glow
##   - soft shadows from a sun that crosses the sky (from the north-west at noon, Factorio's side): wider, even edges by default (Zenith fits the blur to
##     the shadow map), or, as an option, shadows that soften with distance (the sun's size; Godot's PCSS,
##     costlier and grainy below Shadows: High)
##   - a real sunrise and sunset: the sun reddening as it sinks and setting in the west, long shadows,
##     a blue hour, exposure, haze, shadows and the grade following the sun's height, dawn mist
##   - ambient occlusion (SSAO) in corners and under machines, on the shade's light (the sun's nearly untouched),
##     and indirect bounce light (SSIL) as its own
##     option, off by default (it costs about as much again: for Ultra-class graphics cards)
##   - reflections of the sky on metal
##   - depth haze that grows with distance
##   - clouds: a layer of soft, shaded clouds in the sky and their shadows drifting over the factory, from
##     the same pattern, drawn once into a texture (shaders/cloud_field.gdshader; Zenith's own flat
##     clouds are off while the look is on)
##   - against sparkle: no model shinier than roughness 0.55, the roughness limiter and a cap on bloom,
##     so small shiny parts don't flash highlights smaller than a pixel; temporal anti-aliasing as an
##     option (off: Zenith's shader-animated parts, inserter arms and belts, flicker under it)
##   - a grade pass: a film contrast curve, local contrast and sharpening on what the camera looks at
##     (faded out with distance, where they made fine detail shimmer), the far distance softened a
##     little, vibrance, cool shadows and warm highlights, a soft vignette, a touch of chromatic
##     aberration and fine film grain (shaders/cinematic_grade.gdshader)
## Factorio's own colour lookup per planet and time of day stays on. On a space platform Zenith turns
## the haze off (looks.gd's SPACE_ENV) and the grade leaves the black backdrop and its stars alone.

const LOOK := "cinematic-shaders/cinematic"
## How much of SSAO darkens the sun's light (Godot's ssao_light_affect) unless "Occlusion in sunlight too" is on.
const AO_SUNLIGHT := 0.15
## The clouds' pattern, drawn once into a texture the grade reads (shaders/cloud_field.gdshader): it
## repeats every FIELD_PERIOD of the pattern (about 1,800 tiles at the grade's cloud_scale), on
## FIELD_SIZE texels a side (about 1.7 tiles a texel; 8 MB of video memory at 16 bits a channel).
const FIELD_SIZE := 1024
const FIELD_PERIOD := 16.0
## Where the sun that crosses the sky stands at noon (a DirectionalLight3D's yaw): north-west, the side Factorio's
## sprites are lit from, so a model shows the camera a lit side and a shaded one. Zenith's own noon sun (-30, high
## behind the default view) lit every face the camera sees: Vasillo's rocks drew flat.
const NOON_YAW := -135.0
## Resolution per axis of the seamless 3D Worley shape and detail textures (32^3 = 32 KB each).
const VOL_SIZE := 32
const CLOUD_LOW_OLD := 230.0
const CLOUD_HIGH_OLD := 300.0
const CLOUD_LOW_VOL := 210.0
const CLOUD_HIGH_VOL := 390.0
const QUALITY_STEPS := {"low": 18.0, "medium": 28.0, "high": 40.0}
static var volumetric_arg_off: bool = "--volumetric-clouds=off" in OS.get_cmdline_user_args()
## --cinematic-flash=old: lightning adds a fixed 0.75-0.8 to the clouds (and Zenith's sky its own), as
## before 0.6.2: under this look's exposure, AgX and film curve a strike at night turned the sky white.
static var flash_arg_old: bool = "--cinematic-flash=old" in OS.get_cmdline_user_args()
## The grade's lightning on a cloud (cinematic_grade.gdshader's flash_light, its defaults): in proportion
## to the cloud's own brightness `base`, plus a little, capped.
const FLASH_LIFT := 1.6
const FLASH_ADD := 0.05
const FLASH_CAP := 0.25


## How much brighter a cloud of brightness `base` is at `flash` (the weather's, after its Flash
## brightness setting): the grade's sum, for tests and for anyone tuning it. `old`: before 0.6.2.
static func flash_ratio(base: float, flash: float, old := false) -> float:
	var add := 0.8 * flash if old else flash * minf(FLASH_LIFT * base + FLASH_ADD, FLASH_CAP)
	return (base + add) / maxf(base, 1e-4)

var api
## The viewport the pattern is drawn in, once (its texture lives as long as it does); null until the
## clouds are first on.
var _field: SubViewport
var _shape_3d: ImageTexture3D
var _detail_3d: ImageTexture3D


func addon_start(a) -> void:
	api = a
	if api.get("level") == null or float(api.level) < 1.5:
		api.note("needs Zenith's add-on API 1.5 (api.shaders, a look's sunrise and sunset)")
		return
	var s = api.settings
	s.add("grade", "number", 1.0, "Grade strength", {"min": 0.0, "max": 1.5, "step": 0.05, "section": "Picture",
		"note": "Local contrast, sharpening, colour and split toning together."})
	s.add("bloom", "number", 0.6, "Bloom", {"min": 0.0, "max": 1.5, "step": 0.05, "section": "Picture",
		"note": "How much lamps, fire and lasers glow."})
	s.add("haze", "number", 0.5, "Depth haze", {"min": 0.0, "max": 1.5, "step": 0.05, "section": "Picture",
		"note": "Haze in the sun's colour that grows with distance (most visible in the angled and first-person views)."})
	s.add("soften", "number", 0.5, "Soften the far distance", {"min": 0.0, "max": 1.0, "step": 0.05, "section": "Picture",
		"note": "Far beyond what the camera looks at, the picture is softened a little, as a lens focused on the factory would."})
	s.add("clouds", "number", 1.0, "Clouds", {"min": 0.0, "max": 1.0, "step": 0.05, "section": "Picture",
		"note": "Soft, shaded clouds in the sky and their shadows drifting over the ground (in place of Zenith's own clouds while this look is on)."})
	s.add("cloud_cover", "number", 0.58, "Cloud cover", {"min": 0.1, "max": 0.9, "step": 0.05, "section": "Picture"})
	s.add("volumetric_clouds", "bool", true, "Volumetric clouds", {"section": "Picture",
		"note": "3D sculpted cumulus clouds with billowing tops, eroded edges, sunlit silver linings, and curved-horizon depth. Off keeps the lighter flat layer from 0.5.3."})
	s.add("cloud_quality", "choice", "high", "Cloud quality", {"section": "Picture",
		"choices": [["Low", "low"], ["Medium", "medium"], ["High", "high"]],
		"note": "Raymarch steps for volumetric clouds (18 / 28 / 40 steps with empty-space skipping). Lower saves GPU time when the sky fills the screen."})
	s.add("vignette", "number", 0.35, "Vignette", {"min": 0.0, "max": 1.0, "step": 0.05, "section": "Picture"})
	s.add("grain", "number", 0.02, "Film grain", {"min": 0.0, "max": 0.15, "step": 0.005, "section": "Picture"})
	s.add("taa", "bool", false, "Temporal anti-aliasing", {"section": "Picture",
		"note": "Steadier far detail as the camera moves, but it softens moving belts and makes other moving parts (inserter arms) smear or flicker: Godot doesn't know they move. For a sharp picture leave this off and pick SMAA in Settings > Graphics > Anti-aliasing. Your own anti-aliasing setting comes back when the add-on is off."})
	s.add("ao", "bool", true, "Ambient occlusion", {"section": "Lighting",
		"note": "SSAO: shading in corners and under machines. About 1-1.5 ms of GPU a frame on a desktop graphics card at a busy base."})
	s.add("ao_sun", "bool", false, "Occlusion in sunlight too", {"section": "Lighting",
		"note": "Ambient occlusion darkens the sunlit sides as well, not only the shade."})
	s.add("ssil", "bool", false, "Bounce light", {"section": "Lighting",
		"note": "SSIL: light bounced off the ground into the shade. Costs about as much again as ambient occlusion: for Ultra-class graphics cards."})
	s.add("soft_shadows", "bool", true, "Soft shadows", {"section": "Lighting",
		"note": "Wider, even shadow edges."})
	s.add("pcss", "bool", false, "Shadows soften with distance", {"section": "Lighting",
		"note": "Sharp where things touch the ground, softer further off (the sun's size). Costs more and looks grainy below Shadows: High; smoothest with temporal anti-aliasing."})
	s.add("sun_size", "number", 0.5, "Sun size", {"min": 0.1, "max": 1.4, "step": 0.1, "section": "Lighting",
		"note": "In degrees, when shadows soften with distance: bigger is softer (0.5 is the real sun's; 1.4 was this look's before 0.5.0)."})
	s.add("sun_moves", "bool", true, "The sun crosses the sky", {"section": "Lighting",
		"note": "Off: the sun stays where Factorio's shadows fall, as in the Factorio look."})
	s.add("sun_side", "bool", true, "Noon sun from the north-west", {"section": "Lighting",
		"note": "Lights models from Factorio's side, so they show a lit side and a shaded one. Off: the noon sun high behind the view, as before 0.5.1 (every side the camera sees lit, models flat)."})
	s.add("sunset", "number", 1.0, "Sunrise and sunset", {"min": 0.0, "max": 1.0, "step": 0.05, "section": "Lighting",
		"note": "How warm and dramatic dawn and dusk get. 0: a sun that fades without setting, as Zenith's others."})
	var on_change := func(_id: String, _v: Variant) -> void:
		_register()
	s.changed.connect(on_change)
	_register()
	api.shaders.use_look(LOOK)


## Switched off, Zenith takes the look away and puts back the one it replaced.
func addon_stop() -> void:
	_shape_3d = null
	_detail_3d = null


func _exit_tree() -> void:
	_shape_3d = null
	_detail_3d = null


## The look from the settings now (registered again when one changes; Zenith puts it on again if
## it is in use).
func _register() -> void:
	var s = api.settings
	var grade := float(s.value("grade"))
	var ao := bool(s.value("ao"))
	var ssil := bool(s.value("ssil"))
	var ao_sun := bool(s.value("ao_sun"))
	var haze := float(s.value("haze"))
	var bloom := float(s.value("bloom"))
	var clouds_amt := float(s.value("clouds"))
	var vol_on := bool(s.value("volumetric_clouds")) and not volumetric_arg_off
	var qual := str(s.value("cloud_quality"))
	var steps := float(QUALITY_STEPS.get(qual, 40.0))
	var look := {
		"name": "Cinematic",
		"description": "Filmic colour, bloom, soft shadows, ambient occlusion and bounce light, depth haze, local contrast, vignette and grain (the Cinematic shaders add-on).",
		"tonemap": Environment.TONE_MAPPER_AGX, "exposure": 1.25, "white": 1.0,
		"sun_energy": 1.55, "ambient_energy": 0.42,
		# By day under Zenith's lighting environment (0.2.3): about 6:1 between the noon sun and the shade on flat
		# ground in scene light (0.42 gave about 13:1); nights keep 0.42.
		"ambient_energy_lit": 0.9,
		"ambient_tint": Color(0.62, 0.72, 0.9), "ambient_tint_amount": 0.35,
		"factorio_lut": true,
		"twilight": float(s.value("sunset")),
		# As the sun nears the horizon (each blended by its height, every frame): the picture keeps
		# golden hour as readable as day and warmer, the haze takes the sky's colour and the sun's
		# glow, the sky lights the shade (warm on the side facing the sunset, blue on the other) and
		# softens shadows that would otherwise run black across the ground.
		"at_twilight": {
			"environment": {
				"tonemap_exposure": 1.25 * 1.45, "ambient_light_sky_contribution": 0.5,
				"background_energy_multiplier": 0.42,
				"fog_sun_scatter": 0.45, "fog_density": 0.0011 * haze * 1.5,
			},
			"sun": {"shadow_opacity": 0.55},
			"params": {"split_tone": 0.8 * grade, "saturation": 1.0 + 0.32 * grade},
		},
		# Dawn is pinker and mistier: mist lying round the buildings' feet (by height, so it reads in
		# Factorio's flat view too), gone by mid-morning.
		"at_dawn": {
			"environment": {"fog_height": 1.8, "fog_height_density": 0.2 * minf(haze * 2.0, 1.5), "fog_density": 0.0011 * haze * 2.0},
		},
		"fog_from_sky": 1.0,
		# Models' and the ground's own occlusion shares on the sun's light (looks.gd ao_direct): none, so the
		# environment's ssao_light_affect below is all that reaches it.
		"ao_direct": 1.0 if ao_sun else 0.0,
		# No model shinier than this: small shiny parts (bolts, inserter arms, belt rollers) flashed
		# highlights smaller than a pixel as they moved, under the lamps most. Built-in packs only: a "pbr" pack
		# keeps its files' roughness (looks.gd; the roughness limiter below and bloom's luminance cap keep its sparkle down).
		"roughness_min": 0.55,
		# Godot's limiter too: it widens highlights on surfaces that turn faster than a pixel.
		"roughness_limiter": Vector2(0.6, 0.25),
		"taa": bool(s.value("taa")),
		"own_clouds": float(s.value("clouds")) <= 0.0,
		"environment": {
			"glow_enabled": bloom > 0.0, "glow_intensity": 0.55 * bloom, "glow_strength": 1.0, "glow_bloom": 0.04 * bloom,
			"glow_hdr_threshold": 1.25, "glow_blend_mode": Environment.GLOW_BLEND_MODE_SOFTLIGHT,
			# One pixel's light counts at most this much in the bloom: a lamp's highlight on a bolt
			# bloomed into a spark that came and went with TAA's jitter (Godot's default is 12).
			"glow_hdr_luminance_cap": 2.5,
			# 0.5.3: tuned SSAO defaults (radius 1.7, intensity 2.45, power 2.0; 1.75 / 1.75 / 1.6 in 0.5.2,
			# 1.4 / 1.5 / 1.6 before), still acting on indirect light by default unless "Occlusion in sunlight too" is on.
			"ssao_enabled": ao, "ssao_radius": 1.7, "ssao_intensity": 2.45,
			"ssao_power": 2.0, "ssao_detail": 0.6,
			"ssil_enabled": ssil, "ssil_radius": 6.0, "ssil_intensity": 0.5, "ssil_normal_rejection": 1.0,
			"fog_enabled": haze > 0.0, "fog_light_color": Color(0.66, 0.74, 0.86), "fog_light_energy": 0.75,
			"fog_sun_scatter": 0.3, "fog_density": 0.0011 * haze, "fog_aerial_perspective": 0.5, "fog_sky_affect": 0.3,
			"fog_height": 0.0, "fog_height_density": 0.0,
			"reflected_light_source": Environment.REFLECTION_SOURCE_BG,
			"ambient_light_source": Environment.AMBIENT_SOURCE_SKY, "ambient_light_sky_contribution": 0.0,
		},
		# Zenith's Factorio edge is 0.02 tiles (its sprites'); "Soft shadows" doubles it.
		"shadow_edge": 0.04 if bool(s.value("soft_shadows")) else 0.02,
		"sun": {
			"light_angular_distance": float(s.value("sun_size")) if bool(s.value("pcss")) else 0.0,
			# Godot's full highlight (0.6 before 0.2.3): metal's sun is this term alone.
			"shadow_opacity": 1.0, "light_specular": 1.0,
		},
		"passes": [{"shader": "shaders/cinematic_grade.gdshader", "params": {
			"clarity": 0.32 * grade, "sharpen": 0.22 * grade, "vibrance": 0.35 * grade, "split_tone": 0.45 * grade,
			"contrast": 1.0 + 0.2 * grade, "saturation": 1.0 + 0.22 * grade,
			"vignette": float(s.value("vignette")), "grain": float(s.value("grain")),
			"aberration": 0.0015 * grade, "soften": float(s.value("soften")),
			"night_cool": float(s.value("sunset")),
			"clouds": clouds_amt, "cloud_cover": float(s.value("cloud_cover")),
			"cloud_volumetric": 1.0 if vol_on else 0.0,
			"cloud_steps": steps,
			"cloud_low": CLOUD_LOW_VOL if vol_on else CLOUD_LOW_OLD,
			"cloud_high": CLOUD_HIGH_VOL if vol_on else CLOUD_HIGH_OLD,
			"flash_old": 1.0 if flash_arg_old else 0.0,
			"flash_lift": FLASH_LIFT, "flash_add": FLASH_ADD, "flash_cap": FLASH_CAP,
		}}],
	}
	if not ao_sun:
		# A little of SSAO still on the sun's light, so contact shadow at a building's foot reads in full sun
		# (Zenith's own looks: 0.85).
		look["environment"]["ssao_light_affect"] = AO_SUNLIGHT
	if not bool(s.value("sun_moves")):
		look["sun_angle"] = Vector2(-42.0, -112.0)
	elif bool(s.value("sun_side")):
		look["sun_noon_yaw"] = NOON_YAW
	var field: Texture2D = _cloud_field() if clouds_amt > 0.0 else null
	if field != null:
		var params: Dictionary = look["passes"][0]["params"]
		params["cloud_field"] = field
		params["cloud_period"] = FIELD_PERIOD
		if vol_on and _ensure_cloud_volumes():
			params["cloud_shape_3d"] = _shape_3d
			params["cloud_detail_3d"] = _detail_3d
	api.shaders.add_look(LOOK, look)


static func _make_volume_3d(freq: float, octaves: int, seed_val: int) -> ImageTexture3D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.frequency = freq
	noise.seed = seed_val
	var slices: Array[Image] = noise.get_seamless_image_3d(VOL_SIZE, VOL_SIZE, VOL_SIZE, true, 0.25)
	if slices.size() != VOL_SIZE or slices[0] == null or slices[0].is_empty():
		return null
	var tex := ImageTexture3D.new()
	if tex.create(slices[0].get_format(), VOL_SIZE, VOL_SIZE, VOL_SIZE, false, slices) != OK:
		return null
	return tex


func _ensure_cloud_volumes() -> bool:
	if _shape_3d == null:
		_shape_3d = _make_volume_3d(0.065, 3, 31)
	if _detail_3d == null:
		_detail_3d = _make_volume_3d(0.13, 2, 109)
	return _shape_3d != null and _detail_3d != null


## The clouds' pattern as a texture: drawn by the GPU in a viewport of its own the first time it is
## asked for, once, and kept. The grade worked the noise out in its place before (0.4.4), on every
## pixel of the ground and every step of its march through the sky. null (no clouds: the grade reads
## black) if its shader can't be read.
func _cloud_field() -> Texture2D:
	if _field == null:
		var shader := load(str(api.dir).path_join("shaders/cloud_field.gdshader")) as Shader
		if shader == null:
			api.note("shaders/cloud_field.gdshader can't be read: no clouds")
			return null
		_field = SubViewport.new()
		_field.name = "CloudField"
		_field.size = Vector2i(FIELD_SIZE, FIELD_SIZE)
		_field.disable_3d = true
		# 16-bit floats: the pattern's fine steps for the clouds' soft edges, and values a little
		# outside 0-1 kept as they are.
		_field.use_hdr_2d = true
		_field.render_target_update_mode = SubViewport.UPDATE_ONCE
		var m := ShaderMaterial.new()
		m.shader = shader
		m.set_shader_parameter("period", FIELD_PERIOD)
		var rect := ColorRect.new()
		rect.size = Vector2(FIELD_SIZE, FIELD_SIZE)
		rect.material = m
		_field.add_child(rect)
		add_child(_field)
	return _field.get_texture()
