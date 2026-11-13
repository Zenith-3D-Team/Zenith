extends Node
## Cinematic shaders: a look for Zenith (add-on API 1.5, api.shaders) that trades Factorio's flat,
## even picture for a filmic one with more depth and detail. The add-on is the look: while it is on,
## the world is drawn with it, and switching the add-on off (Settings > Add-ons) brings back Zenith's
## Factorio look, which has no settings of its own. Its sliders are on its page of the Add-ons menu.
##
## What it adds over Zenith's Factorio look, each at the GPU's cost:
##   - AgX tonemapping and a little more exposure: highlights roll off instead of clipping
##   - bloom: lamps, fire, lasers and molten metal glow
##   - soft shadows (the sun's angular size) from a sun that crosses the sky
##   - a real sunrise and sunset: the sun reddening as it sinks and setting in the west, long shadows,
##     a blue hour, exposure, haze, shadows and the grade following the sun's height, dawn mist
##   - ambient occlusion (SSAO) in corners and under machines, and indirect bounce light (SSIL) as its own
##     option, off by default (it costs about as much again: for Ultra-class graphics cards)
##   - reflections of the sky on metal
##   - depth haze that grows with distance
##   - clouds: a layer of soft, shaded clouds in the sky and their shadows drifting over the factory, from
##     the same pattern (Zenith's own flat clouds are off while the look is on)
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

var api


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
	s.add("vignette", "number", 0.35, "Vignette", {"min": 0.0, "max": 1.0, "step": 0.05, "section": "Picture"})
	s.add("grain", "number", 0.02, "Film grain", {"min": 0.0, "max": 0.15, "step": 0.005, "section": "Picture"})
	s.add("taa", "bool", false, "Temporal anti-aliasing", {"section": "Picture",
		"note": "Steadier far detail as the camera moves, but it softens moving belts and makes other moving parts (inserter arms) smear or flicker: Godot doesn't know they move. For a sharp picture leave this off and pick SMAA in Settings > Graphics > Anti-aliasing. Your own anti-aliasing setting comes back when the add-on is off."})
	s.add("ao", "bool", true, "Ambient occlusion", {"section": "Lighting",
		"note": "SSAO: shading in corners and under machines. About 1-1.5 ms of GPU a frame on a desktop graphics card at a busy base."})
	s.add("ssil", "bool", false, "Bounce light", {"section": "Lighting",
		"note": "SSIL: light bounced off the ground into the shade. Costs about as much again as ambient occlusion: for Ultra-class graphics cards."})
	s.add("soft_shadows", "bool", true, "Soft shadows", {"section": "Lighting",
		"note": "Shadows that soften with distance from what casts them (the sun's size)."})
	s.add("sun_moves", "bool", true, "The sun crosses the sky", {"section": "Lighting",
		"note": "Off: the sun stays where Factorio's shadows fall, as in the Factorio look."})
	s.add("sunset", "number", 1.0, "Sunrise and sunset", {"min": 0.0, "max": 1.0, "step": 0.05, "section": "Lighting",
		"note": "How warm and dramatic dawn and dusk get. 0: a sun that fades without setting, as Zenith's others."})
	var on_change := func(_id: String, _v: Variant) -> void:
		_register()
	s.changed.connect(on_change)
	_register()
	api.shaders.use_look(LOOK)


## Switched off, Zenith takes the look away and puts back the one it replaced.
func addon_stop() -> void:
	pass


## The look from the settings now (registered again when one changes; Zenith puts it on again if
## it is in use).
func _register() -> void:
	var s = api.settings
	var grade := float(s.value("grade"))
	var ao := bool(s.value("ao"))
	var ssil := bool(s.value("ssil"))
	var haze := float(s.value("haze"))
	var bloom := float(s.value("bloom"))
	var look := {
		"name": "Cinematic",
		"description": "Filmic colour, bloom, soft shadows, ambient occlusion and bounce light, depth haze, local contrast, vignette and grain (the Cinematic shaders add-on).",
		"tonemap": Environment.TONE_MAPPER_AGX, "exposure": 1.25, "white": 1.0,
		"sun_energy": 1.55, "ambient_energy": 0.42,
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
		# No model shinier than this: small shiny parts (bolts, inserter arms, belt rollers) flashed
		# highlights smaller than a pixel as they moved, under the lamps most.
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
			# Intensity 1.5 (was 2.2): corners as dark as Factorio's sprites paint them, not darker.
			"ssao_enabled": ao, "ssao_radius": 1.4, "ssao_intensity": 1.5, "ssao_power": 1.6, "ssao_detail": 0.6,
			"ssil_enabled": ssil, "ssil_radius": 6.0, "ssil_intensity": 0.5, "ssil_normal_rejection": 1.0,
			"fog_enabled": haze > 0.0, "fog_light_color": Color(0.66, 0.74, 0.86), "fog_light_energy": 0.75,
			"fog_sun_scatter": 0.3, "fog_density": 0.0011 * haze, "fog_aerial_perspective": 0.5, "fog_sky_affect": 0.3,
			"fog_height": 0.0, "fog_height_density": 0.0,
			"reflected_light_source": Environment.REFLECTION_SOURCE_BG,
			"ambient_light_source": Environment.AMBIENT_SOURCE_SKY, "ambient_light_sky_contribution": 0.0,
		},
		"sun": {
			"light_angular_distance": 1.4 if bool(s.value("soft_shadows")) else 0.0,
			"shadow_opacity": 1.0, "light_specular": 0.6,
		},
		"passes": [{"shader": "shaders/cinematic_grade.gdshader", "params": {
			"clarity": 0.32 * grade, "sharpen": 0.22 * grade, "vibrance": 0.35 * grade, "split_tone": 0.45 * grade,
			"contrast": 1.0 + 0.2 * grade, "saturation": 1.0 + 0.22 * grade,
			"vignette": float(s.value("vignette")), "grain": float(s.value("grain")),
			"aberration": 0.0015 * grade, "soften": float(s.value("soften")),
			"night_cool": float(s.value("sunset")),
			"clouds": float(s.value("clouds")), "cloud_cover": float(s.value("cloud_cover")),
		}}],
	}
	if not bool(s.value("sun_moves")):
		look["sun_angle"] = Vector2(-42.0, -112.0)
	api.shaders.add_look(LOOK, look)
