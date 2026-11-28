extends "res://tests/ui_test_base.gd"
## UI test sections: lighting.

func _ih_quick() -> void:
	const Arms := preload("res://scripts/world/inserter_arms.gd")
	var w := WorldMirror.new()
	add_child(w)
	w.protos.add_entities([[7, "inserter", "inserter", -0.15, -0.15, 0.15, 0.15, 200, 200, 50, 1, 1],
		[8, "transport-belt", "transport-belt", -0.4, -0.4, 0.4, 0.4, 200, 200, 50, 1, 1]])
	w.chunks[Vector2i.ZERO] = ChunkView.new()
	w._add([801, 7, 5 * 256 + 128, 5 * 256 + 128, 0])
	# A belt at 801's pickup (a tile north of it), none at 802's; and a crowd of belts further off.
	w._add([803, 8, 5 * 256 + 128, 4 * 256 + 128, 0])
	for j in 20:
		w._add([900 + j, 8, j * 256 + 128, 20 * 256 + 128, 4])
	w._add([802, 7, 9 * 256 + 128, 5 * 256 + 128, 4])
	var was := Arms.quick_apply
	var layers: Array = []
	for quick in [true, false]:
		Arms.quick_apply = quick
		var a: Node3D = Arms.new()
		a.protos = w.protos
		a.world = w
		a.eprops[7] = {"x": {"ip": [0, -1], "id": [0, 1]}}
		add_child(a)
		for step in 6:
			var turn := step * 0.4
			var l: Array = []
			for u in [801, 802]:
				var base: Vector2 = (w.entities[u] as WorldMirror.Rec).pos
				var hand := base + Vector2(cos(turn), sin(turn)) * 0.9
				l.append_array([u, roundi(hand.x * 256.0), roundi(hand.y * 256.0), 3 if step % 2 == 0 else 0])
			a.handle({"t": "ih", "k": 100 + 6 * step, "p": 6, "l": l})
		layers.append(a)
	var same := (layers[0]._preplan as Array).size() == (layers[1]._preplan as Array).size()
	for u in [801, 802]:
		var q = layers[0]._arms[u]
		var o = layers[1]._arms[u]
		same = same and q.ticks == o.ticks and q.angles == o.angles and q.reaches == o.reaches and q.items == o.items \
			and q.placed.is_equal_approx(o.placed) and q.base == o.base and q.dir == o.dir and q.model_name == o.model_name
		same = same and q.belt_pick == o.belt_pick and q.belt_pick == (u == 801) and q.pick == o.pick
	Arms.quick_apply = true
	var quick_layer: Node3D = layers[0]
	var arm = quick_layer._arms[801]
	var marker := Transform3D(Basis.IDENTITY, Vector3(-99, 0, -99))
	arm.placed = marker
	var next := func(k: int) -> void:
		quick_layer.handle({"t": "ih", "k": k, "p": 6, "l": [801, 5 * 256 + 128 + 200, 5 * 256 + 128, 0]})
	next.call(200)
	var kept: bool = arm.placed == marker  # the same record: not looked up again
	# Turned in place as predicted.gd turns one (record_edited), its chunk built again (entities_changed): the
	# native ingest drops that chunk's binds then, the GDScript one sees the new direction.
	var turned_rec: WorldMirror.Rec = w.entities[801]
	turned_rec.dir = 4
	w.record_edited(turned_rec)
	w.entities_changed.emit(turned_rec.chunk)
	next.call(206)
	var turned: bool = arm.placed != marker and arm.dir == 4  # rotated: bound again
	arm.placed = marker
	# The models' stamp a bind is good for: the layout's (--arm-bind-layout), or any model finishing (=off).
	if Arms.bind_layout:
		ModelLibrary.layout_generation += 1
	else:
		ModelLibrary.generation += 1
	next.call(212)
	var models: bool = arm.placed != marker  # models changed: bound again
	Arms.quick_apply = was
	check(same and kept and turned and models,
		"`ih` quick: the arms come out as with --ih-apply=old, an unchanged record isn't bound again, a rotated one or new models are: %s %s %s %s" % [same, kept, turned, models])
	for a in layers:
		a.queue_free()
	w.queue_free()


## A busy base's `st` (1,600 machines' states) took 10-25 ms handled whole, a dropped frame each time: a
## message of more than ST_INLINE states waits and is applied over the next frames within the frame
## budget's `states` slice, in order (a unit ends with the latest state sent), the lamps' colours at once;
## --st-slice=off applies it whole, as before.


func _states_sliced() -> void:
	var w := WorldMirror.new()
	add_child(w)
	w.protos.add_entities([[4, "small-lamp", "lamp", -0.5, -0.5, 0.5, 0.5, 200, 200, 160, 1, 1]])
	w.chunks[Vector2i.ZERO] = ChunkView.new()
	var big: Array = []
	for j in 100:
		w._add([3000 + j, 4, (j % 30) * 256 + 128, (j / 30) * 256 + 128, 0])
		big.append_array([3000 + j, 1])
	var was_sliced := WorldMirror.states_sliced
	WorldMirror.states_sliced = true
	w.handle({"t": "st", "l": big, "lc": [3000, 0x00FF00]})
	var waited := not w.working.has(3000) and w.states_waiting() == 100 and int(w.lamp_colors.get(3000, -1)) == 0x00FF00
	# A small one after it waits behind it (it would otherwise be overwritten by the older state).
	w.handle({"t": "st", "l": [3005, 0, 3099, 0]})
	var behind := not w.working.has(3005) and w.states_waiting() == 102
	w._apply_states_waiting(40)
	var part := w.states_waiting() == 62 and int(w.working.get(3039, -1)) == 1 and not w.working.has(3040)
	var frames := 1
	while w.states_waiting() > 0 and frames < 100:
		w._apply_states_waiting(40)
		frames += 1
	var all_on := true
	for j in 100:
		if int(w.working.get(3000 + j, -1)) != (0 if j == 5 or j == 99 else 1):
			all_on = false
	check(waited and behind and part and frames == 3 and all_on and w._stated_in(Vector2i.ZERO).size() == 100,
		"`st`: a big message's states wait (the lamp's colour at once), a later one behind it, applied a slice a frame in order, the latest winning: %s %s %s %d %s" % [waited, behind, part, frames, all_on])
	# A small message with nothing waiting: at once, as before.
	w.handle({"t": "st", "l": [3001, 0]})
	var small_now := int(w.working.get(3001, -1)) == 0
	# Waiting ones go with the world (a resync, a surface change).
	w.handle({"t": "st", "l": big})
	w.reset(true)
	var gone := w.states_waiting() == 0
	# The switch: whole, as the message is handled.
	WorldMirror.states_sliced = false
	var w2 := WorldMirror.new()
	add_child(w2)
	w2.handle({"t": "st", "l": big})
	var whole := w2.states_waiting() == 0 and int(w2.working.get(3099, -1)) == 1
	WorldMirror.states_sliced = was_sliced
	check(small_now and gone and whole, "`st`: a small one at once, those waiting forgotten with the world, --st-slice=off whole: %s %s %s" % [small_now, gone, whole])
	w.queue_free()
	w2.queue_free()


## Lamps at night (lamp_lights.gd): a lamp the bridge reports working (`st` 1; a real lamp is 0 by
## day, turned_off_during_daytime) gets a glow and a light once it is dark, a lamp it reports off
## none. J19: on an add-on's hills (ground_height.gd) the lamp's model is lifted in its shader, and
## the bulb and light at their flat height sat inside the raised ground, so no lamp on a hill lit up.
## K5: the bulb, a white ball 0.8 tiles up, floated over the model's 0.6-tile head, which stayed dark:
## the glass glows instead (Factorio's lit lamp's picture on a card over it) and the light is just over
## the head.


func _lamps() -> void:
	const LampLights := preload("res://scripts/world/lamp_lights.gd")
	const G := preload("res://scripts/world/ground_height.gd")
	G.clear()
	var holder := Node3D.new()
	add_child(holder)
	var w := WorldMirror.new()
	holder.add_child(w)
	w.protos.add_entities([[4, "small-lamp", "lamp", -0.5, -0.5, 0.5, 0.5, 200, 200, 160, 1, 1]])
	w.chunks[Vector2i.ZERO] = ChunkView.new()
	w._add([961, 4, 5 * 256 + 128, 6 * 256 + 128, 0])
	w._add([962, 4, 9 * 256 + 128, 6 * 256 + 128, 0])
	var lamps := LampLights.new()
	lamps.protos = w.protos
	lamps.world = w
	holder.add_child(lamps)
	lamps._on_entities_changed(Vector2i.ZERO)  # world.gd says so once the chunk is built
	w.handle({"t": "st", "l": [961, 1, 962, 0]})
	lamps.darkness = 0.0
	lamps._process(LampLights.REFRESH)
	var by_day: int = lamps.lit_count()
	lamps.darkness = 0.85
	lamps._process(LampLights.REFRESH)
	# (The glows' MultiMesh keeps no transforms under the headless dummy renderer: where they were put is read.)
	var mm: MultiMesh = lamps._bulbs.multimesh
	var lights: Array = lamps._lights
	var light: OmniLight3D = lights[0]
	var flat_glow: Vector3 = lamps._spots[0] if lamps._spots.size() == 1 else Vector3.ZERO
	check(by_day == 0 and lamps.lit_count() == 1 and mm.visible_instance_count == 1
		and flat_glow.is_equal_approx(Vector3(5.5, LampLights.GLASS_HEIGHT, 6.5)) and light.visible and not (lights[1] as OmniLight3D).visible
		and is_equal_approx(light.position.y, LampLights.LIGHT_HEIGHT),
		"lamps: the working one lit at night with a glow and a light, the one reported off dark, none by day: %d %d %s" % [by_day, lamps.lit_count(), flat_glow])
	# K5: no ball over the lamp: Factorio's lit-lamp picture, added over the lamp facing the camera and
	# drawn in front of its head, centred on the glass inside the model's 0.6-tile head; the light just
	# over the head, so the head's top and the ground round it are lit. (Fails on the old bulb.)
	var glow_mat := lamps._bulbs.material_override as StandardMaterial3D
	var head_top := 0.6
	check(mm.mesh is QuadMesh and glow_mat != null and glow_mat.blend_mode == BaseMaterial3D.BLEND_MODE_ADD
		and glow_mat.billboard_mode == BaseMaterial3D.BILLBOARD_ENABLED and glow_mat.grow and glow_mat.albedo_texture != null
		and flat_glow.y < head_top and flat_glow.y > 0.25 and light.position.y > head_top and light.position.y < head_top + 0.5
		and light.omni_range > 4.0,
		"K5: the lamp's glass glows (Factorio's picture over it, centred %.2f up, under its head's top) and its light is just over the head (%.2f)" % [flat_glow.y, light.position.y])
	# N6: the light reaches about twice as far as before (range 7 at attenuation 1: a tenth of its foot's
	# light at about 5 tiles), with a softer fall-off; coloured lamps keep their share of it (4 of 7).
	var falloff := func(d: float, r: float, k: float) -> float:
		return pow(maxf(1.0 - pow(d / r, 4.0), 0.0), 2.0) * pow(d, -k)
	var tenth := func(r: float, k: float) -> float:
		var d := 1.0
		while d < r and falloff.call(d, r, k) >= 0.1:
			d += 0.05
		return d
	var reach_new: float = tenth.call(light.omni_range, light.omni_attenuation)
	var reach_old: float = tenth.call(LampLights.OLD_LIGHT_RANGE, LampLights.OLD_ATTENUATION)
	check(is_equal_approx(light.omni_range, LampLights.LIGHT_RANGE) and light.omni_range >= 2.0 * LampLights.OLD_LIGHT_RANGE
		and light.omni_attenuation < 1.0 and reach_new > 2.0 * reach_old and reach_new < 3.2 * reach_old and not light.shadow_enabled
		and is_equal_approx(LampLights.COLORED_RANGE / LampLights.LIGHT_RANGE, LampLights.OLD_COLORED_RANGE / LampLights.OLD_LIGHT_RANGE),
		"N6: a lamp's light reaches %.1f tiles (a tenth of its foot's), was %.1f; range %.0f, attenuation %.2f"
		% [reach_new, reach_old, light.omni_range, light.omni_attenuation])
	# K10: a lamp its circuit network (or its window) colours, `st` `lc`: its glow and light take the colour, a
	# white one keeps the warm look. The glow's albedo multiplies its instance colour in linear light, so the
	# drawn glow is the lamp's colour (in linear light) at the white glow's brightest channel.
	var white_tint: Color = lamps._tints[0]
	var white_light := light.light_color
	w.handle({"t": "st", "l": [961, 1], "lc": [961, 0x2060FF]})
	lamps._process(LampLights.REFRESH)
	var want := Color8(0x20, 0x60, 0xFF)
	var g_lin := LampLights.GLOW_COLOR.srgb_to_linear()
	var tint: Color = lamps._tints[0]
	var drawn := Vector3(g_lin.r * tint.r, g_lin.g * tint.g, g_lin.b * tint.b)
	var w_lin := want.srgb_to_linear()
	var expect := Vector3(w_lin.r, w_lin.g, w_lin.b) * g_lin.r
	check(white_tint == Color.WHITE and white_light == LampLights.LIGHT_COLOR and lamps.lit_count() == 1
		and drawn.is_equal_approx(expect) and light.light_color.is_equal_approx(want)
		and is_equal_approx(light.omni_range, LampLights.COLORED_RANGE),
		"K10: a coloured lamp's glow and light take its colour (%s, light %s), a white one is warm (%s)" % [drawn, light.light_color, white_light])
	# A state for it without `lc`: the bridge sends the colour with every state of a coloured lamp, so none is white.
	w.handle({"t": "st", "l": [961, 1]})
	lamps._process(LampLights.REFRESH)
	var back_white: bool = lamps._tints[0] == Color.WHITE and light.light_color == LampLights.LIGHT_COLOR \
		and is_equal_approx(light.omni_range, LampLights.LIGHT_RANGE)
	w.handle({"t": "st", "l": [], "lc": [961, 0xFF0000]})
	lamps._process(LampLights.REFRESH)
	var red: bool = light.light_color.is_equal_approx(Color(1, 0, 0))
	w.handle({"t": "st", "l": [], "lc": [961, -1]})
	lamps._process(LampLights.REFRESH)
	var minus_one: bool = lamps._tints[0] == Color.WHITE and light.light_color == LampLights.LIGHT_COLOR
	w.handle({"t": "st", "l": [], "lc": [961, 0]})
	lamps._process(LampLights.REFRESH)
	var black_dark: bool = lamps.lit_count() == 0 and not light.visible
	w.handle({"t": "st", "l": [961, 1]})
	lamps._process(LampLights.REFRESH)
	check(back_white and red and minus_one and black_dark and lamps.lit_count() == 1,
		"K10: a state without a colour, and -1, are white; a colour alone changes it; black lights nothing: %s %s %s %s"
		% [back_white, red, minus_one, black_dark])
	# Hills 3 tiles high under both: the glow and its light go up with the lamp's model, once.
	var hill := Image.create(16, 16, false, Image.FORMAT_RF)
	hill.fill(Color(3.0, 0.0, 0.0))
	G.set_field(hill, Vector2(-8, -8), 2.0)
	lamps._process(LampLights.REFRESH)
	var ground := G.at(5.5, 6.5)
	var hill_glow: Vector3 = lamps._spots[0]
	var hill_light := light.position
	G.clear()
	check(is_equal_approx(ground, 3.0) and is_equal_approx(hill_glow.y, ground + LampLights.GLASS_HEIGHT)
		and is_equal_approx(hill_light.y, ground + LampLights.LIGHT_HEIGHT) and light.visible,
		"J19: on a hill %.1f tiles high a lit lamp's glow (%.2f) and light (%.2f) stand on its lifted model, not inside the hill"
		% [ground, hill_glow.y, hill_light.y])
	# Flat again: back down.
	lamps._process(LampLights.REFRESH)
	check(is_equal_approx(lamps._spots[0].y, LampLights.GLASS_HEIGHT) and is_equal_approx(light.position.y, LampLights.LIGHT_HEIGHT),
		"lamps: back on flat ground, the glow and light are back down")
	# K20: a lamp set to Always on (`st` `ao`, with its state) shines by day as well: its glow dimmer, added
	# over the sunlit lamp, its light faint. A plain one the bridge says works (a state from the night it no
	# longer hears, or the mock's) waits for the dark. (Fails on the old code: by day nothing was lit.)
	w.handle({"t": "st", "l": [961, 1, 962, 1], "ao": [962, 1]})
	lamps.darkness = 0.0
	lamps._process(LampLights.REFRESH)
	var noon_lit: int = lamps.lit_count()
	var noon_spot: Vector3 = lamps._spots[0] if lamps._spots.size() == 1 else Vector3.ZERO
	var noon_tint: Color = lamps._tints[0] if lamps._tints.size() == 1 else Color.BLACK
	check(noon_lit == 1 and noon_spot.is_equal_approx(Vector3(9.5, LampLights.GLASS_HEIGHT, 6.5)) and light.visible
		and is_equal_approx(noon_tint.r, LampLights.DAY_GLOW) and is_equal_approx(noon_tint.b, LampLights.DAY_GLOW)
		and is_equal_approx(noon_tint.a, 1.0) and is_equal_approx(light.light_energy, LampLights.LIGHT_ENERGY * LampLights.DAY_LIGHT)
		and light.position.is_equal_approx(noon_spot + Vector3(0.0, LampLights.LIGHT_HEIGHT - LampLights.GLASS_HEIGHT, 0.0)),
		"K20: at noon the always-on lamp is lit (glow %.2f of the night's, light %.2f), the plain one reported working isn't: %d lit"
		% [noon_tint.r, light.light_energy, noon_lit])
	# Dusk: the always-on one's glow and light grow with the darkness, full once the plain lamps come on.
	lamps.darkness = LampLights.ON_DARKNESS * 0.5
	lamps._process(LampLights.REFRESH)
	var dusk_tint: Color = lamps._tints[0] if lamps._tints.size() == 1 else Color.BLACK
	var dusk_ok: bool = lamps.lit_count() == 1 and dusk_tint.r > LampLights.DAY_GLOW and dusk_tint.r < 1.0 \
		and light.light_energy > LampLights.LIGHT_ENERGY * LampLights.DAY_LIGHT and light.light_energy < LampLights.LIGHT_ENERGY
	lamps.darkness = 0.85
	lamps._process(LampLights.REFRESH)
	var night_both: bool = lamps.lit_count() == 2 and lamps._tints[0] == Color.WHITE and lamps._tints[1] == Color.WHITE \
		and is_equal_approx(light.light_energy, LampLights.LIGHT_ENERGY)
	# Always on turned off (ao 0), or a state without `ao` (the bridge sends it with every state of such a lamp):
	# a plain lamp again, dark by day.
	w.handle({"t": "st", "l": [], "ao": [962, 0]})
	lamps.darkness = 0.0
	lamps._process(LampLights.REFRESH)
	var off_again: bool = lamps.lit_count() == 0 and not light.visible
	w.handle({"t": "st", "l": [962, 1], "ao": [962, 1]})
	lamps._process(LampLights.REFRESH)
	var on_again: bool = lamps.lit_count() == 1
	w.handle({"t": "st", "l": [962, 1]})
	lamps._process(LampLights.REFRESH)
	var plain_again: bool = lamps.lit_count() == 0
	w.handle({"t": "st", "l": [962, 1], "ao": [962, 1]})
	w._remove(962)
	check(dusk_ok and night_both and off_again and on_again and plain_again and not w.lamp_always.has(962),
		"K20: at dusk it brightens (glow %.2f), at night both lit as before; ao 0, or a state without it, is a plain lamp again (dark by day); a removed lamp is forgotten: %s %s %s %s %s"
		% [dusk_tint.r, dusk_ok, night_both, off_again, on_again, plain_again])

	# Distant chunk-snapshot hints (`extra.lp`, `extra.lc`), LOD-tied real light budget/distance,
	# frustum prioritization, smooth fade, 2D far lightmap, and WorkingGlow LOD/splat integration.
	const FarChunksScript := preload("res://scripts/world/far_chunks.gd")
	const WorkingGlowScript := preload("res://scripts/world/working_glow.gd")
	w.chunks[Vector2i(10, 0)] = ChunkView.new()
	w._add([963, 4, 320 * 256 + 128, 6 * 256 + 128, 0, {"lp": 1}])
	w._add([964, 4, 330 * 256 + 128, 6 * 256 + 128, 0, {"lp": 3, "lc": 0x20FF40}])
	w._add([965, 4, 340 * 256 + 128, 6 * 256 + 128, 0])
	lamps._on_entities_changed(Vector2i(10, 0))
	lamps.darkness = 0.0
	lamps._process(LampLights.REFRESH)
	var hint_day_cnt: int = lamps.lit_count()
	var hint_day_green: bool = lamps._tints.size() == 1 and lamps._tints[0].g > lamps._tints[0].r * 5.0 and lamps._tints[0].g > lamps._tints[0].b * 5.0 and not lamps._lights[0].visible
	lamps.darkness = 0.85
	lamps._process(LampLights.REFRESH)
	var hint_night_cnt: int = lamps.lit_count()
	w.handle({"t": "st", "l": [963, 0, 965, 1]})
	lamps._process(LampLights.REFRESH)
	var hint_override_cnt: int = lamps.lit_count()
	check(hint_day_cnt == 1 and hint_day_green and hint_night_cnt == 3 and hint_override_cnt == 3,
		"far lamps: snapshot hints light distant always-on by day (%d, green %s), powered at night (%d), unpowered dark, live st overrides (%d)"
		% [hint_day_cnt, hint_day_green, hint_night_cnt, hint_override_cnt])
	w.handle({"t": "st", "l": [965, 0]})
	w._remove(963)
	w._remove(964)
	w._remove(965)

	var fc := FarChunksScript.new()
	holder.add_child(fc)
	fc._pass_from = 128.0
	lamps.far_chunks = fc
	lamps.apply_lod_quality("low")
	lamps._process(LampLights.REFRESH)
	var low_ok: bool = lamps.max_lights == 64 and is_equal_approx(lamps._detail_distance, 128.0 * 0.65)
	lamps.apply_lod_quality("high")
	lamps._process(LampLights.REFRESH)
	var high_ok: bool = lamps.max_lights == 224 and is_equal_approx(lamps._detail_distance, 128.0 * 1.35)
	lamps.apply_lod_quality("medium")
	lamps._process(LampLights.REFRESH)
	var med_ok: bool = lamps.max_lights == 128 and is_equal_approx(lamps._detail_distance, 128.0)
	check(low_ok and med_ok and high_ok, "far lamps: LOD tiers set real light budget (64/128/224) and detail distance (%.1f)" % lamps._detail_distance)

	# Fade zone + far 2D lightmap + WorkingGlow LOD integration + shader load checks.
	w.chunks[Vector2i(3, 0)] = ChunkView.new()
	w.chunks[Vector2i(7, 0)] = ChunkView.new()
	w._add([968, 4, 112 * 256 + 128, 128, 0, {"lp": 1}])  # inside 96..128 fade band from origin
	w._add([969, 4, 240 * 256 + 128, 128, 0, {"lp": 1}])  # beyond 128 -> lightmap only
	lamps._on_entities_changed(Vector2i(3, 0))
	lamps._on_entities_changed(Vector2i(7, 0))
	w.protos.add_entities([[5, "stone-furnace", "furnace", -1.0, -1.0, 1.0, 1.0, 200, 120, 60, 2, 2]])
	w.chunks[Vector2i(6, 0)] = ChunkView.new()
	w._add([970, 5, 196 * 256, 128, 0])
	w.handle({"t": "st", "l": [970, 1]})
	var wg := WorkingGlowScript.new()
	wg.world = w
	wg.far_chunks = fc
	holder.add_child(wg)
	fc._pass_from = 40.0
	wg.apply_lod_quality("low")
	var wg_floor_low: bool = is_equal_approx(wg.radius, 28.0) and wg.max_lights == 16
	fc._pass_from = 60.0
	wg.apply_lod_quality("low")
	var wg_scaled_low: bool = is_equal_approx(wg.radius, 30.0) and wg.max_lights == 16
	wg.apply_lod_quality("medium")
	var wg_floor_med: bool = is_equal_approx(wg.radius, 88.0) and wg.max_lights == 32
	fc._pass_from = 128.0
	wg.apply_lod_quality("high")
	var wg_high_ok: bool = is_equal_approx(wg.radius, 128.0) and wg.max_lights == 48
	wg.apply_lod_quality("low")
	var wg_low_ok: bool = is_equal_approx(wg.radius, 64.0) and wg.max_lights == 16
	wg.apply_lod_quality("medium")
	var wg_med_ok: bool = is_equal_approx(wg.radius, 96.0) and wg.max_lights == 32
	w.set_focus(Vector2(120.0, 0.5))  # 76 tiles from 970 -> inside 72..96 WorkingGlow fade band
	wg._process(WorkingGlowScript.REFRESH)
	var wg_glows_ok: bool = not wg.far_glows().is_empty()
	w.set_focus(Vector2.ZERO)
	lamps.working_glow = wg
	lamps.focus = Vector2.ZERO
	lamps._process(LampLights.REFRESH)
	var fade_rw := -1.0
	for i in lamps._lit:
		if is_equal_approx(lamps._spots[i].x, 112.5):
			fade_rw = lamps._real_weights[i]
			break
	var far_rect: Variant = RenderingServer.global_shader_parameter_get(LampLights.GLOBAL_RECT)
	var far_on_ok: bool = lamps._map_active and lamps._map_splat_count >= 3 and (far_rect == null or (far_rect as Vector4).w > 0.5)
	lamps.set_far_lights_enabled(false)
	lamps._process(LampLights.REFRESH)
	var far_off_ok: bool = not lamps._map_active and lamps._map_splat_count == 0
	lamps.set_far_lights_enabled(true)
	lamps._process(LampLights.REFRESH)
	check(fade_rw > 0.01 and fade_rw < 0.99 and wg_glows_ok and far_on_ok and far_off_ok and wg_floor_low and wg_scaled_low and wg_floor_med and wg_low_ok and wg_med_ok and wg_high_ok,
		"far lamps: fade band %.2f, WorkingGlow far_glows %s (%s/%s/%s; %s/%s/%s), lightmap on %s (splats %d), off %s"
		% [fade_rw, wg_glows_ok, wg_floor_low, wg_scaled_low, wg_floor_med, wg_low_ok, wg_med_ok, wg_high_ok, far_on_ok, lamps._map_splat_count, far_off_ok])

	# Frustum priority: an in-view lamp ahead of the camera beats a closer behind-camera lamp when slots are tight.
	var cam := Camera3D.new()
	holder.add_child(cam)
	cam.position = Vector3(0.0, 20.0, 10.0)
	cam.look_at(Vector3(0.0, 0.0, -40.0), Vector3.UP)
	cam.current = true
	w._remove(961)
	w._remove(968)
	w._remove(969)
	w.chunks[Vector2i(0, 1)] = ChunkView.new()
	w.chunks[Vector2i(0, -2)] = ChunkView.new()
	w._add([971, 4, 0 + 128, 45 * 256 + 128, 0, {"lp": 1}])   # closer (45.5), behind camera
	w._add([972, 4, 0 + 128, -50 * 256 + 128, 0, {"lp": 1}])  # further (50.5), inside frustum
	lamps._on_entities_changed(Vector2i(0, 0))
	lamps._on_entities_changed(Vector2i(3, 0))
	lamps._on_entities_changed(Vector2i(7, 0))
	lamps._on_entities_changed(Vector2i(0, 1))
	lamps._on_entities_changed(Vector2i(0, -2))
	lamps.max_lights = 1
	lamps._process(LampLights.REFRESH)
	check(lamps._lights[0].visible and lamps._lights[0].position.z < 0.0,
		"far lamps: frustum priority picks visible ahead lamp (z=%.1f) over closer behind-camera lamp" % lamps._lights[0].position.z)

	# Near lamps also emit outer ground-spread splats into the 2D HDR lightmap for wide ground reach.
	w._remove(971)
	w._remove(972)
	w._remove(970)
	lamps._on_entities_changed(Vector2i(0, 1))
	lamps._on_entities_changed(Vector2i(0, -2))
	wg._refresh()
	wg._process(WorkingGlowScript.REFRESH)
	w._add([973, 4, 2 * 256 + 128, 2 * 256 + 128, 0, {"lp": 1}])
	lamps._on_entities_changed(Vector2i(0, 0))
	lamps.max_lights = 128
	lamps._process(LampLights.REFRESH)
	var near_splat_ok: bool = lamps._lights[0].visible and lamps._map_active and lamps._map_splat_count >= 1
	check(near_splat_ok, "far lamps: near lamp emits outer ground-spread splat into 2D lightmap (splats=%d)" % lamps._map_splat_count)

	var shaders_ok: bool = FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc").contains("lamp_light") \
		and FileAccess.get_file_as_string("res://shaders/lamp_light.gdshaderinc").contains("f3d_lamp_light_rect") \
		and FileAccess.get_file_as_string("res://shaders/lod_common.gdshaderinc").contains("lamp_light")
	for spath: String in ["res://shaders/lamp_lightmap_splat.gdshader", "res://shaders/terrain.gdshader", "res://shaders/terrain_shore.gdshader",
			"res://shaders/far_merged.gdshader", "res://shaders/far_tree_crown.gdshader",
			"res://shaders/factorio_material.gdshader", "res://shaders/factorio_material_alpha.gdshader",
			"res://shaders/factorio_material_clip.gdshader", "res://shaders/factorio_material_leaf.gdshader",
			"res://shaders/factorio_material_mover.gdshader", "res://shaders/factorio_material_ore.gdshader",
			"res://shaders/water.gdshader", "res://shaders/decorative.gdshader",
			"res://shaders/decorative_flat.gdshader", "res://shaders/decorative_sheet.gdshader",
			"res://shaders/decorative_grass.gdshader", "res://shaders/decorative_carpet.gdshader",
			"res://shaders/belt_lane_icon.gdshader", "res://shaders/sprite_card.gdshader",
			"res://shaders/lod_solid.gdshader", "res://shaders/lod_solid_masked.gdshader",
			"res://shaders/lod_water.gdshader", "res://shaders/lod_water_masked.gdshader",
			"res://shaders/signal_glow.gdshader"]:
		var sh := load(spath) as Shader
		if sh == null:
			shaders_ok = false
			break
		# The ground's two shaders keep their lamp light in the shared include (terrain_common.gdshaderinc).
		var scode := sh.code + (FileAccess.get_file_as_string("res://shaders/terrain_common.gdshaderinc") if spath.contains("terrain") else "")
		if not spath.contains("lamp_lightmap_splat") and not spath.contains("factorio_material") \
				and not spath.contains("lod_") and not spath.contains("signal_glow") \
				and not scode.contains("lamp_light"):
			shaders_ok = false
			break
	check(shaders_ok, "far lamps: splat, signal glow, Distant Horizon LOD, and world shaders compile with lamp_light")
	lamps._exit_tree()
	holder.queue_free()


## Rail signal and chain signal distance glows, LOD-tied ground lights, snapshot hints (`extra.sg`),
## hill lift, and integration into `lamp_lights.gd`'s 2D HDR lightmap.


func _signal_lights() -> void:
	const SignalLights := preload("res://scripts/world/signal_lights.gd")
	const LampLights := preload("res://scripts/world/lamp_lights.gd")
	const FarChunksScript := preload("res://scripts/world/far_chunks.gd")
	const G := preload("res://scripts/world/ground_height.gd")
	G.clear()
	var holder := Node3D.new()
	add_child(holder)
	var w := WorldMirror.new()
	holder.add_child(w)
	w.protos.add_entities([
		[6, "rail-signal", "rail-signal", -0.5, -0.5, 0.5, 0.5, 90, 160, 90, 1, 1],
		[7, "rail-chain-signal", "rail-chain-signal", -0.5, -0.5, 0.5, 0.5, 90, 160, 160, 1, 1],
	])
	w.chunks[Vector2i.ZERO] = ChunkView.new()
	w.chunks[Vector2i(2, 0)] = ChunkView.new()
	w.chunks[Vector2i(8, 0)] = ChunkView.new()
	# Near green signal (snapshot sg=1), near red overridden by live st=2 yellow, distant chain blue (sg=4), unlit sg=0.
	w._add([1061, 6, 4 * 256 + 128, 4 * 256 + 128, 0, {"sg": 1}])
	w._add([1062, 6, 8 * 256 + 128, 4 * 256 + 128, 4, {"sg": 3}])
	w._add([1063, 7, 260 * 256 + 128, 4 * 256 + 128, 0, {"sg": 4}])
	w._add([1064, 6, 12 * 256 + 128, 4 * 256 + 128, 0])
	w.handle({"t": "st", "l": [1062, 2]})

	var fc := FarChunksScript.new()
	holder.add_child(fc)
	fc._pass_from = 128.0
	var lamps := LampLights.new()
	lamps.protos = w.protos
	lamps.world = w
	lamps.far_chunks = fc
	holder.add_child(lamps)
	var prev_omni := SignalLights.omni_lights_enabled
	if not prev_omni:
		var default_sigs := SignalLights.new()
		default_sigs.protos = w.protos
		default_sigs.world = w
		default_sigs.far_chunks = fc
		holder.add_child(default_sigs)
		check(default_sigs._lights.is_empty(),
			"rail signals: OmniLight3Ds disabled by default (lights=%d)" % default_sigs._lights.size())
		holder.remove_child(default_sigs)
		default_sigs.free()
	SignalLights.omni_lights_enabled = true
	var sigs := SignalLights.new()
	sigs.protos = w.protos
	sigs.world = w
	sigs.far_chunks = fc
	holder.add_child(sigs)
	lamps.signal_lights = sigs
	sigs._on_entities_changed(Vector2i.ZERO)
	sigs._on_entities_changed(Vector2i(2, 0))
	sigs._on_entities_changed(Vector2i(8, 0))

	# By day: additive glow cards visible at DAY_GLOW, no far_glows() splats emitted.
	sigs.darkness = 0.0
	sigs._process(SignalLights.REFRESH)
	var day_lit: int = sigs.lit_count()
	var day_no_splats: bool = sigs.far_glows().is_empty()
	var day_glow_ratio: float = sigs._tints[0].g / SignalLights.STATE_COLORS[1].srgb_to_linear().g if day_lit > 0 else 0.0
	check(day_lit == 3 and day_no_splats and is_equal_approx(day_glow_ratio, SignalLights.DAY_GLOW * SignalLights.GLOW_INTENSITY),
		"rail signals: daytime glows active (lit=%d, no ground splats=%s, ratio=%.3f)" % [day_lit, day_no_splats, day_glow_ratio])

	# At night: brighter glows, green/yellow real OmniLight3Ds, and distant blue chain signal feeds 2D lightmap.
	sigs.darkness = 0.85
	lamps.darkness = 0.85
	sigs._process(SignalLights.REFRESH)
	lamps._process(LampLights.REFRESH)
	var green_light := sigs._lights[0]
	var yellow_light := sigs._lights[1]
	var night_colors_ok: bool = green_light.visible and green_light.light_color.is_equal_approx(SignalLights.STATE_COLORS[1]) \
		and yellow_light.visible and yellow_light.light_color.is_equal_approx(SignalLights.STATE_COLORS[2]) \
		and not sigs._lights[2].visible
	var blue_glow := sigs.lit_count() >= 3 and sigs.far_glows().is_empty() \
		and sigs._tints[2].b > sigs._tints[2].r * 2.0 and sigs._tints[2].b > sigs._tints[2].g
	check(night_colors_ok and blue_glow,
		"rail signals: night lights match green/yellow st, live overrides sg, distant blue chain uses SignalGlows (%s, %s, far_glows=%d)"
		% [night_colors_ok, blue_glow, sigs.far_glows().size()])

	# LOD tiers (24/48/96 lights since the stronger signal lighting, and scaled detail distance: 0.6/0.95/1.25).
	sigs.apply_lod_quality("low")
	sigs._process(SignalLights.REFRESH)
	var sig_low_ok: bool = sigs.max_lights == 24 and is_equal_approx(sigs._detail_distance, 128.0 * 0.6)
	sigs.apply_lod_quality("high")
	sigs._process(SignalLights.REFRESH)
	var sig_high_ok: bool = sigs.max_lights == 96 and is_equal_approx(sigs._detail_distance, 128.0 * 1.25)
	sigs.apply_lod_quality("medium")
	sigs._process(SignalLights.REFRESH)
	var sig_med_ok: bool = sigs.max_lights == 48 and is_equal_approx(sigs._detail_distance, 128.0 * 0.95)
	check(sig_low_ok and sig_med_ok and sig_high_ok,
		"rail signals: LOD tiers scale budget (24/48/96) and detail distance (%.1f)" % sigs._detail_distance)

	# Smooth fade band inside DETAIL_DIST * 0.85 (108.8 tiles: fade 81.6..108.8).
	# Seen by a camera of its own: a camera another section left current may not have it in view, and with
	# --tight-cull a light out of view has none (bucket 1), whatever its distance.
	var cam_was := get_viewport().get_camera_3d()
	var fade_cam := Camera3D.new()
	fade_cam.far = 2000.0
	add_child(fade_cam)
	fade_cam.look_at_from_position(Vector3(50.0, 80.0, 60.0), Vector3(60.0, 0.0, 4.5))
	fade_cam.make_current()
	w._add([1065, 6, 95 * 256 + 128, 4 * 256 + 128, 0, {"sg": 3}])
	sigs._on_entities_changed(Vector2i(2, 0))
	sigs._process(SignalLights.REFRESH)
	var fade_rw := -1.0
	for i in sigs._lit:
		if sigs._spots[i].x > 80.0 and sigs._spots[i].x < 110.0:
			fade_rw = sigs._real_weights[i]
			break
	fade_cam.queue_free()
	if cam_was != null and is_instance_valid(cam_was):
		cam_was.make_current()
	check(fade_rw > 0.01 and fade_rw < 0.99, "rail signals: smooth 25%% fade across detail boundary (rw=%.2f)" % fade_rw)

	# Hill lift: signal glow & light rise with ground height.
	var hill := Image.create(16, 16, false, Image.FORMAT_RF)
	hill.fill(Color(3.0, 0.0, 0.0))
	G.set_field(hill, Vector2(-8, -8), 2.0)
	sigs._process(SignalLights.REFRESH)
	var lifted_glow_y := sigs._spots[0].y
	var lifted_light_y := sigs._lights[0].position.y
	G.clear()
	sigs._process(SignalLights.REFRESH)
	var flat_glow_y := sigs._spots[0].y
	var flat_light_y := sigs._lights[0].position.y
	check(is_equal_approx(lifted_glow_y - flat_glow_y, 3.0) and is_equal_approx(lifted_light_y - flat_light_y, 3.0),
		"rail signals: hill lifts glow (%.2f->%.2f) and light (%.2f->%.2f)" % [flat_glow_y, lifted_glow_y, flat_light_y, lifted_light_y])

	# Frustum priority: in-view signal ahead beats closer behind-camera signal when max_lights = 1.
	w._remove(1061)
	w._remove(1062)
	w._remove(1063)
	w._remove(1064)
	w._remove(1065)
	sigs._on_entities_changed(Vector2i.ZERO)
	sigs._on_entities_changed(Vector2i(2, 0))
	sigs._on_entities_changed(Vector2i(8, 0))
	w.chunks[Vector2i(0, 1)] = ChunkView.new()
	w.chunks[Vector2i(0, -2)] = ChunkView.new()
	w._add([1066, 6, 128, 40 * 256 + 128, 0, {"sg": 1}])   # closer behind camera
	w._add([1067, 6, 128, -46 * 256 + 128, 0, {"sg": 3}])  # further ahead in view
	sigs._on_entities_changed(Vector2i(0, 1))
	sigs._on_entities_changed(Vector2i(0, -2))
	var cam := Camera3D.new()
	holder.add_child(cam)
	cam.position = Vector3(0.0, 20.0, 10.0)
	cam.look_at(Vector3(0.0, 0.0, -40.0), Vector3.UP)
	cam.current = true
	sigs.max_lights = 1
	sigs._process(SignalLights.REFRESH)
	check(sigs._lights[0].visible and sigs._lights[0].position.z < 0.0 and sigs._lights[0].light_color.is_equal_approx(SignalLights.STATE_COLORS[3]),
		"rail signals: frustum priority picks ahead red signal (z=%.1f) over closer behind-camera signal" % sigs._lights[0].position.z)

	# Disabling Far lamp lighting clears signal glows, lights, and far splats cleanly.
	sigs.set_far_lights_enabled(false)
	sigs._process(SignalLights.REFRESH)
	check(sigs.lit_count() == 0 and not sigs._lights[0].visible and sigs.far_glows().is_empty(),
		"rail signals: turning far lights off clears glows, lights, and splats")
	SignalLights.omni_lights_enabled = prev_omni
	lamps._exit_tree()
	holder.queue_free()


## J19's follow-up: the rest of what is placed on the CPU at the flat height, which sat inside an
## add-on's raised ground (ground_height.gd) while the models, cards and ground round it were lifted
## in their shaders: the character's lantern, flashlight and thrusters, locomotives' headlights,
## furnaces' fires' and labs' lights, a turret's flash, flame and beam, a launch's engine light, the
## ridden pod's flame, explosions', fires' and rockets' lights, lightning, corpses' puddles, and the
## plain-material marks (territory borders, modded robots' shadows, the throw and wire rings, the tile
## brush), which now ride the hills in their shader. Each check fails on the old code.
## N1 (owner: "vehicles need their own headlights pointed in front, brighter and wider than the
## player's, and hide the normal flashlight"): Factorio's car, tank and spidertron light cones (two,
## two and four) turned with the vehicle; on at night in the vehicle the character is in, the
## character's lantern and flashlight out meanwhile.


func _vehicle_lights() -> void:
	const VL := preload("res://scripts/world/vehicle_lights.gd")
	const G := preload("res://scripts/world/ground_height.gd")
	G.clear()
	var holder := Node3D.new()
	add_child(holder)
	var vp := ProtoDB.new()
	vp.add_entities([[8, "car", "car", -0.7, -1.0, 0.7, 1.0, 1, 1, 1, 1, 1],
		[9, "tank", "car", -0.9, -1.3, 0.9, 1.3, 1, 1, 1, 2, 3], [10, "spidertron", "spider-vehicle", -1.0, -1.0, 1.0, 1.0, 1, 1, 1, 2, 2]])
	var cars := MoverLayer.new()
	cars.protos = vp
	holder.add_child(cars)
	# A car at (20, 20) facing north, a tank and a spidertron beside it, nobody of ours in them.
	cars.handle({"t": "mv", "k": 1, "l": [[960, 8, 20 * 256, 20 * 256, 0], [961, 9, 40 * 256, 20 * 256, 0], [962, 10, 60 * 256, 20 * 256, 0]]})
	cars.set_night(1.0)
	cars._process(1.0 / 60.0)
	var car = cars._movers[960]
	var tank = cars._movers[961]
	var spider = cars._movers[962]
	check(car.lights != null and tank.lights != null and spider.lights != null and VL.lights_of(car.lights).size() == 2
		and VL.lights_of(tank.lights).size() == 2 and VL.lights_of(spider.lights).size() == 5,
		"N1: a car and a tank carry two cones, a spidertron four and a round light")
	check(not car.lights.visible and not tank.lights.visible, "N1: at night nobody's vehicle stays dark (the bridge doesn't say who drives it)")
	cars.driven = 960
	cars._process(1.0 / 60.0)
	var cones := VL.lights_of(car.lights)
	var a: SpotLight3D = cones[0]
	var b: SpotLight3D = cones[1]
	var me := Avatar.new()
	holder.add_child(me)
	me.set_night(1.0)
	var flash_energy: float = me._flashlight.light_energy
	var ahead_a := -a.global_transform.basis.z
	var energy := a.light_energy + b.light_energy
	check(car.lights.visible and a.visible and ahead_a.z < -0.5 and absf(ahead_a.x) < 0.01 and a.global_position.z < 20.0
		and absf(a.global_position.x - b.global_position.x) > 1.1,
		"N1: the driven car's cones point ahead of it (north), side by side 1.2 tiles apart: %s %s" % [a.global_position, b.global_position])
	check(energy > flash_energy * 1.5 and a.light_projector != null and a.light_color.b < 0.5,
		"N1: brighter than the character's flashlight (%.2f against %.2f), Factorio's cone picture, its warm yellow" % [energy, flash_energy])
	# The car turns east: the cones turn with it.
	cars.handle({"t": "mv", "k": 3, "l": [[960, 8, 20 * 256, 20 * 256, 250]]})
	for i in 60:
		cars._process(1.0 / 60.0)
	ahead_a = -a.global_transform.basis.z
	check(ahead_a.x > 0.5 and absf(ahead_a.z) < 0.05 and a.global_position.x > 20.0,
		"N1: turned east, the cones point east: %s" % [ahead_a])
	# On the hills the spots stand over the ground under the car.
	var hill := Image.create(32, 32, false, Image.FORMAT_RF)
	hill.fill(Color(3.0, 0.0, 0.0))
	G.set_field(hill, Vector2(-64, -64), 4.0)
	cars._process(1.0 / 60.0)
	check(is_equal_approx(a.position.y, float(a.get_meta("height")) + 3.0), "N1: on a 3-tile hill the cones stand 3 tiles higher (%.2f)" % a.position.y)
	G.clear()
	# The character in it: its lantern and flashlight go out; out again, they're back.
	me.update_from({"t": "me", "u": 5, "v": 960})
	check(not me._flashlight.visible and not me._lantern.visible and me.lights_out(), "N1: in the car the character's flashlight and lantern are out")
	me.update_from({"t": "me", "u": 5, "v": 0})
	check(me._flashlight.visible and me._lantern.visible, "N1: out of the car the character's flashlight and lantern are back")
	cars.driven = 0
	cars._process(1.0 / 60.0)
	check(not car.lights.visible, "N1: left, the car goes dark")
	# By day no headlight.
	cars.driven = 960
	cars.set_night(0.0)
	cars._process(1.0 / 60.0)
	check(not car.lights.visible, "N1: by day the driven car shows no headlight")
	# --vehicle-lights=off: no lights on a new vehicle, the flashlight stays on in it.
	VL.enabled = false
	Avatar.vehicle_lights = false
	cars.handle({"t": "mv", "k": 5, "l": [[963, 8, 80 * 256, 20 * 256, 0]]})
	cars._process(1.0 / 60.0)
	me.update_from({"t": "me", "u": 5, "v": 963})
	check(cars._movers[963].lights == null and me._flashlight.visible, "N1: --vehicle-lights=off: no vehicle lights, the flashlight on in the car as before")
	VL.enabled = true
	Avatar.vehicle_lights = true
	cars.driven = 961
	cars.set_night(1.0)
	cars._process(1.0 / 60.0)
	var tcones := VL.lights_of(tank.lights)
	var t0: SpotLight3D = tcones[0]
	var t1: SpotLight3D = tcones[1]
	var td0 := -t0.global_transform.basis.z
	check(tank.lights.visible and t0.light_color.b > 0.7 and absf(td0.x) > 0.05
		and absf((-t1.global_transform.basis.z).x) > 0.05,
		"N1: driven tank lights are near-white and splayed outward (b=%.2f, dir0=%s)" % [t0.light_color.b, td0])
	_vehicle_fx_checks(holder)
	holder.queue_free()


func _vehicle_fx_checks(holder: Node3D) -> void:
	var w := WorldMirror.new()
	w.pick_build_usec = 1 << 40
	w.protos.add_tiles([[1, "dirt-1", 120, 90, 60], [2, "concrete", 120, 120, 120]])
	w.protos.add_entities([[8, "car", "car", -0.7, -1.0, 0.7, 1.0, 1, 1, 1, 1, 1],
		[9, "tank", "car", -0.9, -1.3, 0.9, 1.3, 1, 1, 1, 2, 3]])
	var cv := ChunkView.new()
	var ids := PackedInt32Array()
	ids.resize(32 * 32)
	ids.fill(1)
	ids[5 * 32 + 5] = 2
	cv.tile_ids = ids
	w.chunks[Vector2i.ZERO] = cv
	var fx := FxScript.new()
	fx.world = w
	holder.add_child(fx.sprites)
	check(FxScript.vehicle_sound_key(w.protos.entity(9)) == "tank"
		and String(FxScript.VEHICLE_SOUNDS["tank"][0]).contains("tank-engine"),
		"vehicle fx: tank proto resolves to tank engine sounds instead of car")
	var t := FxScript.Tracked.new()
	t.proto_id = 9
	t.pos = Vector2(2.5, 2.5)
	t.speed = 6.0
	fx._tracked[961] = t
	var smoke_pool = fx.sprites._pools["smoke"]
	var dust_pool = fx.sprites._pools["dust"]
	smoke_pool.cards.clear()
	dust_pool.cards.clear()
	fx._update_vehicle_fx(1.0)
	check(smoke_pool.cards.size() > 0 and dust_pool.cards.size() > 0,
		"vehicle fx: driving on dirt emits exhaust smoke (%d) and terrain dust (%d)" % [smoke_pool.cards.size(), dust_pool.cards.size()])
	smoke_pool.cards.clear()
	dust_pool.cards.clear()
	t.pos = Vector2(5.5, 5.5)
	fx._update_vehicle_fx(1.0)
	check(smoke_pool.cards.size() > 0 and dust_pool.cards.is_empty(),
		"vehicle fx: driving on concrete emits exhaust (%d) and skips dust (%d)" % [smoke_pool.cards.size(), dust_pool.cards.size()])
	cv.free()
	w.free()
	for n in [fx.sfx, fx.weapons, fx.lightning, fx]:
		n.free()


## Binary frames (wire_decode.gd): movers read from a packed list (whole records, five numbers each, -1 for no
## orientation) end up as the same movers as from JSON's delta-coded records.


func _hill_lights() -> void:
	const G := preload("res://scripts/world/ground_height.gd")
	const WorkingGlow := preload("res://scripts/world/working_glow.gd")
	const MarkShader := preload("res://shaders/ground_mark.gdshader")
	const CapsuleAim := preload("res://scripts/player/capsule_aim.gd")
	const LightningScript := preload("res://scripts/fx/lightning.gd")
	G.clear()
	var holder := Node3D.new()
	add_child(holder)
	# Hills 3 tiles high from -64 to 64 both ways.
	const HILL := 3.0
	var hill := Image.create(32, 32, false, Image.FORMAT_RF)
	hill.fill(Color(HILL, 0.0, 0.0))
	var version_flat := G.version()
	G.set_field(hill, Vector2(-64, -64), 4.0)
	check(G.version() != version_flat and is_equal_approx(G.at(5.5, 6.5), HILL), "hills: a new field counts as a new version (%d -> %d)" % [version_flat, G.version()])
	# The character's lantern and flashlight.
	var me := Avatar.new()
	holder.add_child(me)
	me.snap_to(Vector2(5.5, 6.5))
	me._process(1.0 / 60.0)
	check(is_equal_approx(me._lantern.position.y, Avatar.LANTERN_HEIGHT + HILL) and is_equal_approx(me._flashlight.position.y, Avatar.flashlight_height() + HILL),
		"hills: the character's lantern (%.2f) and flashlight (%.2f) stand over the hill, not inside it" % [me._lantern.position.y, me._flashlight.position.y])
	if me._rig != null:
		me._anim.thrust = 1.0
		me._update_jets()
		var smoke: CPUParticles3D = me._jets[0]["smoke"]
		var flame: MeshInstance3D = me._jets[0]["flame"]
		check(smoke.global_position.y > HILL - 0.5 and flame.global_position.y > HILL - 1.0,
			"hills: the thrusters' smoke (%.2f) and flames (%.2f) come from the feet on the hill" % [smoke.global_position.y, flame.global_position.y])
	# A locomotive's headlights.
	var trains := MoverLayer.new()
	var train_protos := ProtoDB.new()
	train_protos.add_entities([[6, "locomotive", "locomotive", -1.0, -3.0, 1.0, 3.0, 1, 1, 1, 2, 6]])
	trains.protos = train_protos
	holder.add_child(trains)
	trains.handle({"t": "mv", "k": 1, "l": [[903, 6, 0, 10 * 256, 0]]})
	trains.set_night(1.0)
	trains._process(1.0 / 60.0)
	var loco = trains._movers[903]
	var head: SpotLight3D = loco.headlights[0]
	check(head.visible and is_equal_approx(head.position.y, MoverLayer.HEADLIGHT_HEIGHT + HILL),
		"hills: a locomotive's headlights (%.2f) shine from its nose on the hill" % head.position.y)
	# A stone furnace's fire light.
	var w := WorldMirror.new()
	holder.add_child(w)
	w.protos.add_entities([[5, "stone-furnace", "furnace", -1.0, -1.0, 1.0, 1.0, 200, 120, 60, 2, 2]])
	w.chunks[Vector2i.ZERO] = ChunkView.new()
	w._add([971, 5, 6 * 256, 6 * 256, 0])
	w.handle({"t": "st", "l": [971, 1]})
	var glow := WorkingGlow.new()
	glow.world = w
	holder.add_child(glow)
	glow._process(WorkingGlow.REFRESH)
	var fire: OmniLight3D = glow._lights[0]
	var fire_flat: float = (WorkingGlow.MACHINES["stone-furnace"][1] as Vector3).y + 0.3
	check(glow.count() == 1 and fire.visible and is_equal_approx(fire.position.y, fire_flat + HILL),
		"hills: a furnace's fire light (%.2f) is in its mouth on the hill" % fire.position.y)
	# A turret's flash, flame and beam.
	var turrets := TurretLayer.new()
	holder.add_child(turrets)
	var st = turrets._state(7202)
	st.cfg = TurretLayer.TURRETS["flamethrower-turret"]
	st.muzzle = Vector3(4.0, 1.0, 4.0)
	st.target = Vector3(20.0, 0.45, 10.0)
	st.target_seen = turrets._clock
	st.flame_left = 0.2
	turrets._update_effects(st, 1.0 / 60.0)
	turrets._update_effects(st, 1.0 / 60.0)  # the flash's light, made by the first frame's flame, placed by the next
	var ends: Array = turrets.beam_ends(st)
	check(is_equal_approx(st.light.global_position.y, 1.0 + HILL) and is_equal_approx(st.flame_light.global_position.y,
		(TurretLayer.FLAME_LANDING_HEIGHT if WeaponFx.CombatLights.old else TurretLayer.FLAME_LANDING_HEIGHT_NEW) + HILL)
		and is_equal_approx((ends[0] as Vector3).y, 1.0 + HILL) and is_equal_approx((ends[1] as Vector3).y, 0.45 + HILL),
		"hills: a turret's flash (%.2f), its flame's landing light (%.2f) and a beam's ends (%.2f, %.2f) are over the hill"
		% [st.light.global_position.y, st.flame_light.global_position.y, (ends[0] as Vector3).y, (ends[1] as Vector3).y])
	# A launch's engine light (and the stand-in rocket without a model).
	var rockets = RocketsScript.new()
	rockets.model = ChunkModel.new()
	holder.add_child(rockets)
	rockets._on_launch(1, Vector2(10, 10), "")
	rockets._update_launches(1.0)
	var launch: Dictionary = rockets._launches[0]
	var engine: OmniLight3D = launch["light"]
	var body: MeshInstance3D = (launch["node"] as Node3D).get_child(0)
	check(is_equal_approx(engine.position.y, RocketsScript.HATCH_GLOW_HEIGHT + HILL)
		and (not (body.mesh is CylinderMesh) or is_equal_approx(body.position.y, 6.0 + HILL)),
		"hills: a launch's engine light (%.2f) comes up through the hatch of a silo on the hill" % engine.position.y)
	# The ridden pod's flame, coming down onto the hill.
	var ride := Ride.new()
	holder.add_child(ride)
	ride.state = Ride.ARRIVING
	ride._ps = "descending"
	ride._ground = Vector2(8, 8)
	ride._pod_at = Vector2(8, 8)
	ride._height = 10.0
	ride._fly_pod()
	var jet_y: float = ride._pod.position.y + ride._jet.position.y
	check(ride._jet.visible and is_equal_approx(jet_y, 10.0 + Ride.JET_BELOW + HILL),
		"hills: the ridden pod's flame (%.2f) burns under the pod over the hill" % jet_y)
	# Explosions', fires' and rockets' lights.
	var wf := WeaponFx.new()
	holder.add_child(wf)
	wf.explode("big-demolisher-fissure", Vector3(12.0, 0.0, 12.0))
	var fire_ground := WeaponFx.Ground.new()
	fire_ground.fire = true
	fire_ground.pos = Vector3(-12.0, 0.0, 12.0)
	fire_ground.cards = [[SpriteFx.Card.new(), 1.0]]
	wf._ground[991] = fire_ground
	var flyer := WeaponFx.Flyer.new()
	flyer.rec = {"l": [1.0, 4.0, [1.0, 0.6, 0.2]]}
	var flyer_card := SpriteFx.Card.new()
	flyer_card.pos = Vector3(12.0, 0.8, -12.0)
	flyer.cards = [[flyer_card, 1.0, 1.0]]
	wf._flying[992] = flyer
	wf._update_lights(0.0)
	var lit_at := {}
	for l: OmniLight3D in wf._lights:
		if l.visible:
			lit_at[Vector2i(roundi(l.position.x), roundi(l.position.z))] = l.position.y
	# Combat lights (combat_lights.gd): an explosion's light higher the bigger it is (up to 3 more), a fire's at 1.2.
	var ex_y := float(lit_at.get(Vector2i(12, 12), -1.0))
	var ex_ok := is_equal_approx(ex_y, 0.5 + HILL) if WeaponFx.CombatLights.old else (ex_y >= 0.5 + HILL - 0.001 and ex_y <= 3.5 + HILL + 0.001)
	var fire_y := 0.8 if WeaponFx.CombatLights.old else 1.2
	check(ex_ok and is_equal_approx(float(lit_at.get(Vector2i(-12, 12), -1.0)), fire_y + HILL)
		and is_equal_approx(float(lit_at.get(Vector2i(12, -12), -1.0)), 0.8 + HILL),
		"hills: an explosion's, a fire's and a rocket's lights are over the hill: %s" % lit_at)
	if not WeaponFx.CombatLights.old:
		# Combat lights: one muzzle light per shooter, refreshed by its shots; a cannon's brighter.
		wf._flashes.clear()
		wf._muzzle_light(77, Vector3(0.0, 1.0, 0.0), {"k": "instant"})
		wf._muzzle_light(77, Vector3(0.2, 1.0, 0.0), {"k": "instant"})
		wf._muzzle_light(78, Vector3(5.0, 1.0, 0.0), {"k": "projectile"})
		check(wf._flashes.size() == 2 and is_equal_approx(float(wf._flashes[0][2]), WeaponFx.MUZZLE_BULLET[0])
			and is_equal_approx(float(wf._flashes[1][2]), WeaponFx.MUZZLE_HEAVY[0]),
			"combat lights: a burst keeps one muzzle light a shooter (%d flashes)" % wf._flashes.size())
		wf._flashes.clear()
	# Lightning: the bolt down to the hill and its light.
	var storm := LightningScript.new()
	holder.add_child(storm)
	storm.strike(Vector2(10, 20))
	var bolt = storm.bolts[0] if storm.bolts.size() > 0 else null
	var strike: Vector3 = (bolt.paths[0] as PackedVector3Array)[-1] if bolt != null else Vector3.ZERO
	check(bolt != null and strike.is_equal_approx(Vector3(10, HILL, 20)) and bolt.light != null and is_equal_approx(bolt.light.position.y, 3.0 + HILL),
		"hills: lightning strikes the hill (%s), its light over it" % strike)
	# A corpse's puddle lies on the hill.
	check(Creatures._puddle_lift(Vector3(5.5, 0.0, 6.5)) > Creatures.PUDDLE_HEIGHT + HILL - 0.001,
		"hills: a corpse's puddle (%.3f) lies on the hill" % Creatures._puddle_lift(Vector3(5.5, 0.0, 6.5)))
	# Plain-material marks ride the hills in their shader.
	var borders := TerritoryLayer.new()
	holder.add_child(borders)
	var robot_node := Node3D.new()
	var robot_part := MeshInstance3D.new()
	robot_part.mesh = BoxMesh.new()
	robot_node.add_child(robot_part)
	var robot_shadow: Node3D = trains._make_shadow(robot_node)
	var aim := CapsuleAim.new()
	var wires := WireTool.new()
	var brush := TileBrush.new()
	var area_overlay := CursorOverlay.new()
	holder.add_child(brush)
	var marks := [borders.material_override, (robot_shadow.get_child(0) as MeshInstance3D).material_override, aim._ok_mat, aim._bad_mat,
		wires._material, wires._ring_material, brush._mmi.material_override, area_overlay._areas.material_override]
	var lifted := marks.filter(func(m: Material) -> bool: return m is ShaderMaterial and (m as ShaderMaterial).shader == MarkShader)
	var area_mats := [borders.material_override, aim._ok_mat, aim._bad_mat, wires._ring_material, brush._mmi.material_override,
		area_overlay._areas.material_override]
	var area_prios := area_mats.all(func(m: Material) -> bool: return m.render_priority == G.AREA_PRIORITY)
	check(lifted.size() == marks.size() and area_prios,
		"hills: territory borders, robots' drop shadows, the throw and wire rings, tile brush and area overlays ride the hills at AREA_PRIORITY: %d of %d" % [lifted.size(), marks.size()])
	robot_node.free()
	robot_shadow.free()
	aim.free()
	wires.free()
	area_overlay.free()
	# Flat again: the character's lights back down.
	G.clear()
	me._process(1.0 / 60.0)
	check(is_equal_approx(me._lantern.position.y, Avatar.LANTERN_HEIGHT) and G.version() != version_flat,
		"hills: back on flat ground, the character's lantern is back down (%.2f)" % me._lantern.position.y)
	turrets.reset()
	wf._flying.clear()  # (reset() lets their cards go through sprite_fx.gd, which this one has none of)
	wf._ground.clear()
	holder.queue_free()


## L1 (the owner's playtest, 4:50): F6, then the wheel out of Factorio's view left the normal view
## orthographic, and F7's first press said "Normal view: orthographic" and changed nothing. Now zooming,
## turning or tilting out of Factorio's view puts the normal view's own projection back, F7 switches what
## is on screen (in Factorio's view too) and says so, and F6 still snaps back and returns (G5);
## --f6-leave=old is the old behaviour, the bug.


func _f6_projection() -> void:
	var ortho_was = Settings.get_value("camera", "orthographic")
	Settings.set_value("camera", "orthographic", false)
	var vp := SubViewport.new()
	vp.size = Vector2i(1920, 1080)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var me := Node3D.new()
	vp.add_child(me)
	var rig := CameraRig.new()
	rig.target = me
	vp.add_child(rig)
	rig.apply_settings()
	# What is on screen after a frame.
	var ortho_shown := func() -> bool:
		rig._process(1.0 / 60.0)
		return rig.camera.projection == Camera3D.PROJECTION_ORTHOGONAL
	var before := [rig._yaw_goal, rig.pitch_degrees, rig._distance_goal]
	rig.toggle_factorio_view()
	var f6: bool = ortho_shown.call() and rig.in_factorio_view()
	rig.zoom(1.1)
	var zoomed_ortho: bool = ortho_shown.call()
	var said: String = rig.toggle_projection()
	var f7_ortho: bool = ortho_shown.call()
	var said2: String = rig.toggle_projection()
	var f7_back: bool = ortho_shown.call()
	check(f6 and not zoomed_ortho and not rig.in_factorio_view() and not rig._saved_view.is_empty()
		and said == "Normal view: orthographic" and f7_ortho and said2 == "Normal view: perspective" and not f7_back
		and not bool(Settings.get_value("camera", "orthographic")),
		"L1: zoomed out of Factorio's view the normal view is perspective again, and F7's first press switches it (%s, %s)" % [said, said2])
	var nudged := true
	for nudge in ["turn", "tilt"]:
		rig.toggle_factorio_view()
		var snapped: bool = ortho_shown.call() and rig.in_factorio_view()
		match nudge:
			"turn": rig.rotate_free(3.0)
			"tilt": rig.tilt(-2.0)
		nudged = nudged and snapped and not ortho_shown.call() and not rig.in_factorio_view()
	rig.toggle_factorio_view()
	var again: bool = ortho_shown.call() and rig.in_factorio_view()
	rig.toggle_factorio_view()
	check(nudged and again and not ortho_shown.call() and [rig._yaw_goal, rig.pitch_degrees, rig._distance_goal] == before
		and rig._saved_view.is_empty(),
		"L1: turned or tilted out of Factorio's view it is perspective too; F6 snaps back to it and once more returns to the view before (G5)")
	# F7 in Factorio's view itself: what is on screen goes perspective, where it is; F6 snaps back.
	rig.toggle_factorio_view()
	var in_f6: bool = ortho_shown.call()
	var said3: String = rig.toggle_projection()
	var persp_there: bool = not ortho_shown.call() and not rig.in_factorio_view() and rig.pitch_degrees == CameraRig.FACTORIO_PITCH
	rig.toggle_factorio_view()
	var snapped_back: bool = ortho_shown.call() and rig.in_factorio_view()
	rig.toggle_factorio_view()
	check(in_f6 and said3 == "Normal view: perspective" and persp_there and snapped_back and not ortho_shown.call()
		and not bool(Settings.get_value("camera", "orthographic")),
		"L1: F7 in Factorio's view shows perspective where it stands (%s); F6 snaps back to Factorio's view" % said3)
	# A normal view set to orthographic keeps it after Factorio's view, and F7 there goes perspective.
	Settings.set_value("camera", "orthographic", true)
	rig.apply_settings()
	rig.toggle_factorio_view()
	rig.zoom(0.9)
	var own_ortho: bool = ortho_shown.call()
	var said4: String = rig.toggle_projection()
	check(own_ortho and said4 == "Normal view: perspective" and not ortho_shown.call() and not bool(Settings.get_value("camera", "orthographic")),
		"L1: a normal view set orthographic stays so out of Factorio's view, and F7 switches it (%s)" % said4)
	rig.toggle_factorio_view()
	rig.toggle_factorio_view()
	# --f6-leave=old: the bug as the video shows it.
	Settings.set_value("camera", "orthographic", false)
	rig.apply_settings()
	CameraRig.f6_leave_fix = false
	rig.toggle_factorio_view()
	rig.zoom(1.1)
	var old_ortho: bool = ortho_shown.call()
	var old_said: String = rig.toggle_projection()
	var old_still: bool = ortho_shown.call()
	CameraRig.f6_leave_fix = true
	check(old_ortho and old_said == "Normal view: orthographic" and old_still,
		"L1: --f6-leave=old: zoomed out of Factorio's view it stays orthographic, F7's first press changes nothing on screen (%s)" % old_said)
	rig.toggle_factorio_view()
	rig.toggle_factorio_view()
	Settings.set_value("camera", "orthographic", ortho_was)
	vp.queue_free()


## Issue #17 (camera_rig.gd focus_fix; owner: "camera still sags below the character, should just always
## be in the middle"): the character's body is at the screen's centre in every view, on a 3-tile hill and
## on flat ground: zoomed all the way in at the lowest tilt, the default view, far out, looking down,
## orthographic and Factorio's view (F6, at its 48 degrees), with Camera follows the hills off (and an old
## saved value on changing nothing); the camera over the ground in each. The first camera fix kept the
## default view level on hills (the character 13% of the screen low on a 3-tile hill) and centred the feet
## from the default zoom out. A hill behind the camera tilts the view up over it, the character still in
## the middle, and the tilt eases back once it is gone; running over hills the character stays in the
## middle (the old follow trailed it by a sixth of the screen zoomed in) without jumps; a jump glides
## over; flying, the centre rises with the body; the remote view centres on the ground; --camera-focus=off
## is the old camera.


func _camera_focus() -> void:
	CameraRig.GroundHeight.clear()
	var follow_was = Settings.get_value("camera", "follow_hills")
	Settings.set_value("camera", "follow_hills", false)
	var vp := SubViewport.new()
	vp.size = Vector2i(1920, 1080)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var me := Node3D.new()
	vp.add_child(me)
	var rig := CameraRig.new()
	rig.target = me
	vp.add_child(rig)
	var run := func(frames: int) -> void:
		for i in frames:
			rig._process(1.0 / 60.0)
	# A field of heights h(x, z), a texel a tile, round the origin.
	var field := func(h: Callable) -> void:
		var img := Image.create(128, 128, false, Image.FORMAT_RF)
		for j in 128:
			for i in 128:
				img.set_pixel(i, j, Color(float(h.call(-64.0 + i + 0.5, -64.0 + j + 0.5)), 0.0, 0.0))
		CameraRig.GroundHeight.set_field(img, Vector2(-64, -64), 1.0)
	# The 1.7-tile character's middle on the hills (`lift` more up, flying): how far off the screen's
	# centre (a share of its height), and how far the camera is over the ground under it.
	var off_centre := func(lift: float) -> float:
		var body := Vector3(me.position.x, CameraRig.GroundHeight.at(me.position.x, me.position.z) + 0.85 + lift, me.position.z)
		if rig.camera.is_position_behind(body):
			return INF
		return (rig.camera.unproject_position(body) - Vector2(960, 540)).length() / 1080.0
	var over_ground := func() -> float:
		var eye: Vector3 = rig.camera.global_position
		return eye.y - CameraRig.GroundHeight.at(eye.x, eye.z)
	var closest := func(yaw: float) -> void:
		rig._snap(yaw, CameraRig.MIN_PITCH, CameraRig.MIN_DISTANCE, false)
		rig.global_position = me.position  # as main.gd puts it after a jump
	# Every view, settled: "name off% over" for each, and whether all are centred and over the ground.
	var views := func() -> Array:
		var said := []
		var ok := true
		for v in [["closest, lowest tilt", 45.0, CameraRig.MIN_PITCH, CameraRig.MIN_DISTANCE, false], ["default", 45.0, 50.0, 30.0, false],
				["far out", 45.0, 50.0, 140.0, false], ["looking down", 0.0, CameraRig.MAX_PITCH, 12.0, false],
				["orthographic", 45.0, 50.0, 30.0, true], ["Factorio's view", 0.0, 0.0, 0.0, true]]:
			if v[0] == "Factorio's view":
				rig._saved_view = {}
				rig.toggle_factorio_view()
			else:
				rig._snap(v[1], v[2], v[3], v[4])
			rig.global_position = me.position
			run.call(150)
			var off: float = off_centre.call(0.0)
			var over: float = over_ground.call()
			ok = ok and off < 0.01 and over >= 1.0 and is_equal_approx(rig.shown_pitch(), CameraRig.FACTORIO_PITCH if v[0] == "Factorio's view" else rig.pitch_degrees)
			said.append("%s %.1f%% %.1f" % [v[0], minf(off, 9.99) * 100.0, over])
			if v[0] == "Factorio's view":
				rig.toggle_factorio_view()
		return [ok, ", ".join(said)]
	# A 3-tile plateau.
	const HILL := 3.0
	field.call(func(_x: float, _z: float) -> float: return HILL)
	me.position = Vector3(5.5, 0.0, 6.5)
	var on_hill: Array = views.call()
	check(on_hill[0], "issue #17: on a %d-tile hill the character is in the middle in every view, the camera over the ground (off the centre, tiles over the ground): %s" % [int(HILL), on_hill[1]])
	# An old saved Camera follows the hills changes nothing now.
	rig._snap(45.0, 50.0, 30.0, false)
	run.call(150)
	var y_off: float = rig.global_position.y
	Settings.set_value("camera", "follow_hills", true)
	run.call(150)
	var y_on: float = rig.global_position.y
	Settings.set_value("camera", "follow_hills", false)
	check(is_equal_approx(y_off, y_on) and absf(y_off - (HILL + 0.85)) < 0.01,
		"the old Camera follows the hills changes nothing: the centre on the body (%.2f, %.2f) either way" % [y_off, y_on])
	# The switch off: the camera as before, at the flat height inside the hill.
	CameraRig.focus_fix = false
	closest.call(45.0)
	run.call(120)
	var old_above: float = over_ground.call()
	var old_centre: float = off_centre.call(0.0)
	CameraRig.focus_fix = true
	check(old_above < 0.0 and old_centre > 0.3,
		"--camera-focus=off: the old camera, inside the hill (%.2f) with the character off the centre (%.0f%%)" % [old_above, minf(old_centre, 9.99) * 100.0])
	# Flat ground: the body in the middle too, not the feet.
	CameraRig.GroundHeight.clear()
	var flat: Array = views.call()
	check(flat[0], "on flat ground the character's body is in the middle in every view: %s" % flat[1])
	# Flying in mech armour the centre rises with the body as drawn.
	var flyer_gs := GDScript.new()
	flyer_gs.source_code = "extends Node3D\nfunc drawn_lift() -> float:\n\treturn 1.0\n"
	flyer_gs.reload()
	var flyer: Node3D = flyer_gs.new()
	vp.add_child(flyer)
	flyer.position = me.position
	rig.target = flyer
	rig._snap(45.0, 50.0, 30.0, false)
	run.call(150)
	var fly_off: float = off_centre.call(1.0)
	rig.target = me
	flyer.queue_free()
	check(fly_off < 0.01, "flying, the body a tile up is in the middle (%.1f%% off)" % (minf(fly_off, 9.99) * 100.0))
	# The map's remote view centres on the ground it looks at, on the hills.
	field.call(func(_x: float, _z: float) -> float: return HILL)
	rig.in_remote = true
	run.call(150)
	var remote_y: float = rig.global_position.y
	rig.in_remote = false
	check(absf(remote_y - HILL) < 0.01, "the remote view centres on the ground on the hill (%.2f)" % remote_y)
	# A jump (a teleport, another target) glides over instead of cutting.
	run.call(150)
	me.position += Vector3(50.0, 0.0, 0.0)
	run.call(1)
	var gap_after_one: float = Vector2(rig.global_position.x, rig.global_position.z).distance_to(Vector2(me.position.x, me.position.z))
	run.call(180)
	var gap_after: float = Vector2(rig.global_position.x, rig.global_position.z).distance_to(Vector2(me.position.x, me.position.z))
	check(gap_after_one > 40.0 and gap_after < 0.01, "a 50-tile jump glides over (%.1f tiles to go a frame on, %.3f after 3 s)" % [gap_after_one, gap_after])
	# A slope rising behind the camera (south-east of the character at yaw 45) to 6 tiles: the view tilts
	# up over it, round the character.
	field.call(func(x: float, z: float) -> float: return clampf((x + z) / sqrt(2.0) - 2.0, 0.0, 4.0) * 1.5)
	me.position = Vector3(0.5, 0.0, 0.5)
	closest.call(45.0)
	run.call(60)
	var lifted: float = rig.shown_pitch()
	var above_b: float = over_ground.call()
	var centre_b: float = off_centre.call(0.0)
	check(lifted > CameraRig.MIN_PITCH + 5.0 and above_b >= CameraRig.CLEARANCE - 0.01 and centre_b < 0.01,
		"a hill behind the camera tilts the view up (%.1f degrees) over it (%.2f tiles), the character still in the middle (%.1f%% off)"
		% [lifted, above_b, minf(centre_b, 9.99) * 100.0])
	# Gone again: the tilt eases back down to the player's.
	CameraRig.GroundHeight.clear()
	run.call(1)
	var easing: float = rig.shown_pitch()
	run.call(240)
	check(easing > CameraRig.MIN_PITCH + 1.0 and easing < lifted and absf(rig.shown_pitch() - CameraRig.MIN_PITCH) < 0.01,
		"with the hill gone the view eases back (%.1f degrees a frame on) to the player's tilt (%.2f)" % [easing, rig.shown_pitch()])
	# Running (9 tiles a second) along rolling hills, a ridge behind the camera coming and going, zoomed
	# in at the lowest tilt and at the default view: on every frame over the ground, the character in the
	# middle (the height's small glide aside), and no jumps.
	field.call(func(x: float, z: float) -> float:
		return 2.0 + 1.5 * sin(TAU * x / 24.0) + 2.5 * (0.5 + 0.5 * sin(TAU * x / 40.0)) * smoothstep(1.0, 6.0, z))
	for view in ["closest", "default"]:
		me.position = Vector3(-40.0, 0.0, 0.5)
		if view == "closest":
			closest.call(0.0)
		else:
			rig._snap(0.0, 50.0, 30.0, false)
			rig.global_position = me.position
		run.call(60)
		var lowest := INF
		var worst := 0.0
		var jolt := 0.0
		var eyes: Array[Vector3] = []
		var raised := 0
		while me.position.x < 40.0:
			me.position.x += 9.0 / 60.0
			rig._process(1.0 / 60.0)
			lowest = minf(lowest, over_ground.call())
			worst = maxf(worst, off_centre.call(0.0))
			eyes.append(rig.camera.global_position)
			if rig.shown_pitch() > rig.pitch_degrees + 0.5:
				raised += 1
			if eyes.size() > 20:  # past the start, where the test's character is at full speed at once
				jolt = maxf(jolt, (eyes[-1] - 2.0 * eyes[-2] + eyes[-3]).length())
		var ridge_ok := raised > 30 and raised < eyes.size() - 30 if view == "closest" else raised == 0
		check(lowest >= CameraRig.CLEARANCE - 0.01 and worst < 0.02 and jolt < 0.06 and ridge_ok,
			"running over hills (%s view): the camera at least %.2f tiles over the ground, the character at most %.1f%% off the centre, no jumps (%.3f tiles a frame squared), the view raised over the ridge on %d of %d frames"
			% [view, lowest, minf(worst, 9.99) * 100.0, jolt, raised, eyes.size()])
	CameraRig.GroundHeight.clear()
	Settings.set_value("camera", "follow_hills", follow_was)
	vp.queue_free()


## Contact shading (contact_shade.gd): a model's foot from its lowest vertices, the rim's strength by
## type, a side facing a close neighbour halved (no stacking into black), the chunk's one MultiMesh,
## and the setting hiding it.


func _contact_shade() -> void:
	var CS := preload("res://scripts/world/contact_shade.gd")
	var box := func(lo: Vector3, hi: Vector3) -> Array:
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = PackedVector3Array([lo, Vector3(hi.x, lo.y, lo.z), Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z),
			Vector3(lo.x * 0.5, hi.y, lo.z * 0.5), Vector3(hi.x * 0.5, hi.y, hi.z * 0.5)])
		a[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 1, 3, 2, 0, 4, 1, 3, 5, 2])
		return [[], a, 0]
	# A machine's base 2.8 x 2.6 on the ground (one quad) under a narrower top: one foot, the base's box.
	var feet := CS.feet_of([box.call(Vector3(-1.4, 0.0, -1.3), Vector3(1.4, 1.2, 1.3))])
	var foot: Rect2 = feet[0][0] if feet.size() == 1 else Rect2()
	check(feet.size() == 1 and foot.position.is_equal_approx(Vector2(-1.4, -1.3)) and foot.size.is_equal_approx(Vector2(2.8, 2.6))
		and float(feet[0][1]) < 0.05, "contact: a base on the ground is one foot, its box, square-cornered: %s" % [feet])
	check(CS.feet_of([box.call(Vector3(-0.5, 0.4, -0.5), Vector3(0.5, 1.0, 0.5))]).is_empty(), "contact: a model that floats has none")
	# A still body on the ground whose arrays keep a moving part's vertices 0.3 below it, unused by its
	# triangles (model_library.gd _split_baked gives those to anim_baked: a burner drill's bit): the body's feet.
	var body: Array = box.call(Vector3(-0.9, 0.0, -0.9), Vector3(0.9, 1.0, 0.9))
	var bit_verts: PackedVector3Array = (body[1] as Array)[Mesh.ARRAY_VERTEX]
	bit_verts.append_array([Vector3(-0.1, -0.3, -0.1), Vector3(0.1, -0.3, -0.1), Vector3(0.0, -0.3, 0.1)])
	(body[1] as Array)[Mesh.ARRAY_VERTEX] = bit_verts
	var body_feet := CS.feet_of([body])
	check(body_feet.size() == 1 and (body_feet[0][0] as Rect2).is_equal_approx(Rect2(-0.9, -0.9, 1.8, 1.8)),
		"contact: a moving part's vertices below the still body (unused by its triangles) don't make the feet: %s" % [body_feet])
	# A round foot (a dome's rim of 32 vertices, radius 1.4, joined by its edges): its corners rounded to about its radius.
	var ring := []
	ring.resize(Mesh.ARRAY_MAX)
	var circle := PackedVector3Array([Vector3(0, 1.5, 0)])
	var fan := PackedInt32Array()
	for k in 32:
		circle.append(Vector3(cos(k * TAU / 32.0) * 1.4, 0.0, sin(k * TAU / 32.0) * 1.4))
		fan.append_array([0, 1 + k, 1 + (k + 1) % 32])
	ring[Mesh.ARRAY_VERTEX] = circle
	ring[Mesh.ARRAY_INDEX] = fan
	var round_feet := CS.feet_of([[[], ring, 0]])
	check(round_feet.size() == 1 and absf(float(round_feet[0][1]) - 1.4) < 0.1, "contact: a round foot gets round corners: %s" % [round_feet])
	# Four legs 2 tiles apart (a gantry, a lattice pole): a foot each, no rim on the ground between them.
	var legs: Array = []
	for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		legs.append(box.call(Vector3(corner.x - 0.1, 0.0, corner.y - 0.1), Vector3(corner.x + 0.1, 2.0, corner.y + 0.1)))
	var leg_feet := CS.feet_of(legs)
	check(leg_feet.size() == 4 and leg_feet.all(func(f: Array) -> bool: return (f[0] as Rect2).size.x < 0.3),
		"contact: legs standing apart are a foot each: %d" % leg_feet.size())
	check(CS.style_for("straight-rail", "straight-rail").is_empty() and CS.style_for("tree-01", "tree").is_empty()
		and CS.style_for("stone-wall", "wall").size() == 3 and CS.style_for("pipe", "pipe").size() == 3
		and float(CS.style_for("pipe", "pipe")[0]) < 1.0,
		"contact: none under rails and trees, a light joined band under walls and pipes")
	var belt_style := CS.style_for("transport-belt", "transport-belt")
	check(belt_style.size() == 3 and float(belt_style[0]) < 1.0 and bool(belt_style[2]) and CS.style_for("fast-splitter", "splitter").size() == 3,
		"contact: a lighter band along belts and splitters, joined along a run: %s" % [belt_style])
	check(float(CS.style_for("iron-chest", "container")[0]) < 0.5 and float(CS.style_for("inserter", "inserter")[0]) < 1.0
		and float(CS.style_for("lab", "lab")[1]) > 0.0 and float(CS.style_for("centrifuge", "assembling-machine")[1]) > 0.0
		and CS.style_for("some-mod-machine", "furnace") == CS.DEFAULT_STYLE,
		"contact: faint under chests, smaller under inserters, a patch under labs and centrifuges, the full rim under mods' buildings")
	var mesh := ArrayMesh.new()
	mesh.set_meta(CS.META, feet)
	var rings: Array = []
	# Two machines 0.2 tiles apart east-west, a third far away.
	CS.collect(rings, "assembling-machine-1", "assembling-machine", mesh, Transform3D(Basis.IDENTITY, Vector3(1.5, 0, 1.5)), Vector2.ZERO, Vector2.ZERO)
	CS.collect(rings, "assembling-machine-1", "assembling-machine", mesh, Transform3D(Basis.IDENTITY, Vector3(4.5, 0, 1.5)), Vector2.ZERO, Vector2.ZERO)
	CS.collect(rings, "assembling-machine-1", "assembling-machine", mesh, Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(20.5, 0, 20.5)), Vector2.ZERO, Vector2.ZERO)
	check(rings.size() == 3 and is_equal_approx(float(rings[2][2]), 1.3) and is_equal_approx(float(rings[2][3]), 1.4),
		"contact: one ring per building, its foot turned with the model (a quarter turn swaps width and depth)")
	check(CS.joined(rings).size() == 3, "contact: buildings' rings are never joined")
	# A belt's foot as Vasillo's: 0.84 wide, reaching a little past its tile on the way in.
	var belt_mesh := ArrayMesh.new()
	belt_mesh.set_meta(CS.META, [[Rect2(-0.42, -0.62, 0.84, 1.12), 0.02]])
	var belt_rings: Array = []
	for i in 6:  # a run of six going south, and one more two tiles past its end
		CS.collect(belt_rings, "transport-belt", "transport-belt", belt_mesh, Transform3D(Basis.IDENTITY, Vector3(8.5, 0, 8.5 + i)), Vector2.ZERO, Vector2.ZERO)
	CS.collect(belt_rings, "transport-belt", "transport-belt", belt_mesh, Transform3D(Basis.IDENTITY, Vector3(8.5, 0, 16.5)), Vector2.ZERO, Vector2.ZERO)
	for i in 4:  # a run of four going east (turned a quarter)
		CS.collect(belt_rings, "transport-belt", "transport-belt", belt_mesh, Transform3D(Basis(Vector3.UP, -PI / 2.0), Vector3(20.5 + i, 0, 3.5)), Vector2.ZERO, Vector2.ZERO)
	var runs := CS.joined(belt_rings)
	var south: Array = runs.filter(func(g: Array) -> bool: return is_equal_approx(float(g[0]), 8.5) and float(g[3]) > 2.0)
	var east: Array = runs.filter(func(g: Array) -> bool: return is_equal_approx(float(g[1]), 3.5))
	check(belt_rings.size() == 11 and runs.size() == 3 and south.size() == 1 and absf(float(south[0][3]) - 3.06) < 0.01
		and east.size() == 1 and absf(float(east[0][2]) - 2.06) < 0.01 and absf(float(east[0][3]) - 0.42) < 0.01,
		"contact: a straight run of belts is one ring (no darker bead at each joint), either way, a belt apart stays apart: %s" % [runs])
	var sides := CS._sides(rings)
	check(sides[0].r < 0.8 and sides[0].r >= 0.5 and is_equal_approx(sides[0].g, 1.0) and is_equal_approx(sides[0].b, 1.0)
		and sides[1].g < 0.8 and is_equal_approx(sides[1].r, 1.0) and sides[2] == Color(1, 1, 1, 1),
		"contact: the sides facing a neighbour 0.2 tiles away are weakened, so two rims don't stack into black: %s %s" % [sides[0], sides[1]])
	var holder := Node3D.new()
	add_child(holder)
	var node := CS.apply(holder, null, rings)
	check(node != null and node.multimesh.instance_count == 3 and node.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		and node.multimesh.mesh.get_surface_count() == 1 and (node.multimesh.mesh as ArrayMesh).surface_get_array_index_len(0) == 36 * 6,
		"contact: the chunk's rings are one MultiMesh of a shared ring (36 quads round the foot), casting no shadow")
	var fake := {"contact_node": node}
	CS.set_enabled(false, [fake])
	var hidden := not node.visible
	CS.set_enabled(true, [fake])
	check(hidden and node.visible, "contact: the setting hides and shows every chunk's rings")
	check(CS.apply(holder, node, []) == null, "contact: a chunk without buildings frees its rings")
	holder.queue_free()
	# The rim's profile is Factorio's on-screen darkness, multiplied over linear light: unconverted, a 47%
	# rim showed as about 25% and the belts' band as about 15% (owner: "I can't see the contact lighting").
	var gamma := _shader_float(CS.material().shader.code, "profile_gamma")
	check(gamma >= 2.0 and CS.material().shader.code.contains("pow(1.0 - dark, profile_gamma)"),
		"contact: the rim's on-screen darkness is turned into linear light (gamma %.2f)" % gamma)
	check(float(belt_style[0]) * 0.47 >= 0.3, "contact: the belts' band is at least 30%% dark at their side on screen: %.2f" % (float(belt_style[0]) * 0.47))
	# SSAO in sunlight: Godot darkens direct light by SSAO only max(the surface's AO_LIGHT_AFFECT,
	# ssao_light_affect) mixed in by ssao_ao_channel_affect. At 0.5 and 0.5 the sunlit ground took a
	# quarter of it and the models 0.4: in daylight it hardly showed.
	var ssao: Dictionary = Settings.SSAO_FACTORIO
	var direct := func(own: float) -> float:
		return lerpf(own, maxf(own, float(ssao["ssao_light_affect"])), float(ssao["ssao_ao_channel_affect"]))
	var ground := float(direct.call(_shader_float(FileAccess.get_file_as_string("res://shaders/terrain.gdshader"), "ssao_on_sunlight")))
	var model_code := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	var own := float(model_code.get_slice("AO_LIGHT_AFFECT = ", 1).get_slice(";", 0))
	var models := float(direct.call(own))
	check(ground >= 0.75 and models >= 0.5, "ssao: it darkens sunlit ground at least 0.75 of the way and models half way (%.2f, %.2f)" % [ground, models])


## Contact shading under every built-in pack's mining drills (owner: "a dark border around the drills"):
## each ring's patch, from the real model's feet, ends within its footprint plus PATCH_EDGE and a little
## (it reached 0.4-0.6 tiles past a 3x3 drill's tiles before), the shader's own patch fade the same short
## edge, and the ring no wider than the rim's. The old way, --contact-patch=wide, isn't run here.


func _contact_drills() -> void:
	var CS := preload("res://scripts/world/contact_shade.gd")
	const MARGIN := 0.12  # past the tiles, for the patch's fade (PATCH_EDGE) and rounding
	const TILES := {"burner-mining-drill": 2.0, "electric-mining-drill": 3.0, "big-mining-drill": 5.0}
	var fade := float(CS.material().get_shader_parameter("patch_reach"))
	var ring_reach := float(CS.material().get_shader_parameter("ring_patch_reach"))
	check(not CS.wide_patch and fade >= 0.05 and fade <= 0.15 and is_equal_approx(ring_reach, CS.REACH),
		"contact drills: the patch fades over %.2f tiles past its foot (0.05 to 0.15), its ring reaching %.2f, the rim's own" % [fade, ring_reach])
	var seen := 0
	var worst := -INF
	var overhang := -INF
	var bad: Array = []
	var drills: Array = []  # [pack/model, its mesh, its tiles]
	for pack: String in ModelLibrary.ModelPacks.BUILTIN:
		var dir := ModelLibrary.ModelPacks.BUILTIN_DIR + pack + "/"
		if not DirAccess.dir_exists_absolute(dir):
			continue  # "factorio": the sprites' own pack, no files
		for f in DirAccess.get_files_at(dir):
			var model := f.get_basename()
			var proto := ""
			for p: String in TILES:
				if f.ends_with(".glb") and model.begins_with(p) and not model.ends_with("-wet"):
					proto = p
			if proto == "":
				continue
			var load := ModelLibrary.Load.new()
			load.path = dir + f
			load.run()
			var mesh := ArrayMesh.new()
			mesh.set_meta(CS.META, load.contact)
			var tiles := float(TILES[proto])
			drills.append(["%s/%s" % [pack, model], mesh, tiles])
			var rings: Array = []
			# Placed at a tile centre (odd sizes) or a corner (even), and turned a quarter: the clamp follows it.
			var at := Vector3(10.5, 0.0, 20.5) if int(tiles) % 2 == 1 else Vector3(10.0, 0.0, 20.0)
			var turned := Transform3D(Basis(Vector3.UP, PI / 2.0), at)
			CS.collect(rings, proto, "mining-drill", mesh, turned, Vector2.ZERO, Vector2.ZERO, Vector2(tiles, tiles))
			seen += 1
			if rings.is_empty() or not load.ok:
				bad.append("%s/%s: no ring" % [pack, model])
				continue
			var patches := 0
			for g: Array in rings:
				if float(g[5]) <= 0.0:
					continue  # the rim's own ring (below)
				patches += 1
				var past := maxf(absf(float(g[0]) - at.x) + float(g[2]), absf(float(g[1]) - at.z) + float(g[3])) + fade - tiles * 0.5
				worst = maxf(worst, past)
				if past > MARGIN:
					bad.append("%s/%s: the patch %.2f past its tiles (patch %.2f)" % [pack, model, past, float(g[5])])
			if patches == 0:
				bad.append("%s/%s: no patch" % [pack, model])
			# The rim stays round the real feet, an overhang past the tiles included (Wube3DP's drill: 0.11 tiles).
			var free: Array = []
			CS.collect(free, proto, "mining-drill", mesh, turned, Vector2.ZERO, Vector2.ZERO)
			var rim_box := _rings_box(rings.filter(func(g: Array) -> bool: return float(g[4]) > 0.0))
			var feet_box := _rings_box(free)
			var at2 := Vector2(at.x, at.z)
			var far_side: Vector2 = (feet_box.end - at2).max(at2 - feet_box.position)
			overhang = maxf(overhang, maxf(far_side.x, far_side.y) - tiles * 0.5)
			if not rim_box.is_equal_approx(feet_box):
				bad.append("%s/%s: the rim %s, not round its feet %s" % [pack, model, rim_box, feet_box])
	check(seen >= 5 and bad.is_empty() and overhang > 0.05,
		"contact drills: every built-in drill's patch (%d models) ends within its tiles plus %.2f (the furthest %.2f past), its rim round its real feet (an overhang of %.2f): %s" % [seen, MARGIN, worst, overhang, bad])
	_contact_drill_band(drills, fade)
	# Feet that are no rectangle of the tiles at all (a foot outside them) are put on their edge, not dropped.
	var off := ArrayMesh.new()
	off.set_meta(CS.META, [[Rect2(-1.4, -1.9, 2.8, 0.2), 0.02], [Rect2(-1.6, -1.4, 3.2, 2.8), 0.1]])
	var clamped: Array = []
	CS.collect(clamped, "electric-mining-drill", "mining-drill", off, Transform3D.IDENTITY, Vector2.ZERO, Vector2.ZERO, Vector2(3, 3))
	var unclamped: Array = []
	CS.collect(unclamped, "assembling-machine-2", "assembling-machine", off, Transform3D.IDENTITY, Vector2.ZERO, Vector2.ZERO, Vector2(3, 3))
	var patch_rings := clamped.filter(func(g: Array) -> bool: return float(g[5]) > 0.0)
	var rim_rings := clamped.filter(func(g: Array) -> bool: return float(g[4]) > 0.0)
	check(patch_rings.size() == 2 and absf(float(patch_rings[0][1]) + 1.5) < 0.07 and float(patch_rings[0][3]) <= 0.07
		and is_equal_approx(float(patch_rings[1][2]), 1.5) and is_equal_approx(float(unclamped[1][2]), 1.6)
		and patch_rings.all(func(g: Array) -> bool: return float(g[4]) == 0.0),
		"contact drills: a patch's feet are clamped to its tiles (one outside them put on their edge), a rim-only machine's are not: %s" % [patch_rings])
	check(rim_rings.size() == 2 and is_equal_approx(float(rim_rings[1][2]), 1.6) and absf(float(rim_rings[0][1]) + 1.8) < 0.01
		and rim_rings.all(func(g: Array) -> bool: return float(g[5]) == 0.0),
		"contact drills: the rim stays round the real feet past the tiles (owner: the contact shading gone again), the patch alone clamped: %s" % [rim_rings])
	# Its sides aren't halved by its own patch's ring lying under it.
	var sides := CS._sides(clamped)
	var rims_alone := CS._sides(rim_rings)
	check(rim_rings.size() == 2 and sides[clamped.find(rim_rings[0])].is_equal_approx(rims_alone[0])
		and sides[clamped.find(rim_rings[1])].is_equal_approx(rims_alone[1]),
		"contact drills: a patch's own ring doesn't weaken the rims over it: %s, alone %s" % [sides, rims_alone])
	# --contact-rim=clamped: one clamped ring a foot, as the drill-border fix first had it.
	CS.rim_clamped = true
	var old_way: Array = []
	CS.collect(old_way, "electric-mining-drill", "mining-drill", off, Transform3D.IDENTITY, Vector2.ZERO, Vector2.ZERO, Vector2(3, 3))
	CS.rim_clamped = false
	check(old_way.size() == 2 and is_equal_approx(float(old_way[1][2]), 1.5) and float(old_way[1][4]) > 0.0 and float(old_way[1][5]) > 0.0,
		"contact drills: --contact-rim=clamped keeps one clamped ring a foot: %s" % [old_way])


## The box round rings ([centre x, centre z, half x, half z, ...], contact_shade.gd collect()).
## The drill's dark band (owner, after the rim fix: "a dark rectangular band along its right and bottom edges, past
## the body, over the ore"). Every ring of every built-in drill, in all four directions, sits on its feet: a rim ring
## on a foot's own box, a patch ring centred on it within the patch's reach. And no ring is dark at its hole's edge
## (the shader worked through here, as contact_shade.gdshader has it): the band from the foot's box in to the hole
## was drawn at full darkness and cut off there, a hard-edged dark band wherever the ground shows inside the box
## (Wube3DP's drill between its rear legs, 0.38 tiles deep). The rim at the box's own edge is kept full.


func _contact_drill_band(drills: Array, fade: float) -> void:
	var CS := preload("res://scripts/world/contact_shade.gd")
	var code := FileAccess.get_file_as_string("res://shaders/contact_shade.gdshader")
	var u := {}
	for k in ["inset", "rim_dark", "rim_falloff", "rim_end", "inner_fade"]:
		u[k] = _shader_float(code, k)
	var set_fade = CS.material().get_shader_parameter("inner_fade")
	if set_fade != null:
		u["inner_fade"] = float(set_fade)
	u["patch_reach"] = fade
	check(not CS.inner_hard and is_equal_approx(float(u["inner_fade"]), CS.INNER_FADE) and float(u["inner_fade"]) > 0.0
		and float(u["inner_fade"]) <= float(u["inset"]) and code.contains("smoothstep(-fade_in, 0.0, d)"),
		"contact band: the rim and patch fade out under the foot over %.2f tiles, within the inset %.2f" % [float(u["inner_fade"]), float(u["inset"])])
	var off_centre: Array = []
	var edge_worst := 0.0
	var rim_weakest := INF
	var hard_before := INF
	var turns := 0
	for d: Array in drills:
		var mesh: Mesh = d[1]
		var tiles: float = d[2]
		var at := Vector3(10.5, 0.0, 20.5) if int(tiles) % 2 == 1 else Vector3(10.0, 0.0, 20.0)
		for dir in [0, 4, 8, 12]:
			turns += 1
			var xf := Transform3D(Basis(Vector3.UP, -float(dir) / 16.0 * TAU), at)
			var rings: Array = []
			CS.collect(rings, "electric-mining-drill", "mining-drill", mesh, xf, Vector2.ZERO, Vector2.ZERO, Vector2(tiles, tiles))
			var feet: Array = []
			CS.collect(feet, "electric-mining-drill", "mining-drill", mesh, xf, Vector2.ZERO, Vector2.ZERO)
			for g: Array in rings:
				var near := INF
				var same := false
				for f: Array in feet:
					near = minf(near, maxf(absf(float(g[0]) - float(f[0])), absf(float(g[1]) - float(f[1]))))
					same = same or (is_equal_approx(float(g[0]), float(f[0])) and is_equal_approx(float(g[1]), float(f[1]))
						and is_equal_approx(float(g[2]), float(f[2])) and is_equal_approx(float(g[3]), float(f[3])))
				if near > fade + 0.001 or (float(g[4]) > 0.0 and float(g[5]) <= 0.0 and not same):
					off_centre.append("%s dir %d: ring at (%.2f, %.2f) half (%.2f, %.2f), %.2f off its foot" % [d[0], dir,
						float(g[0]) - at.x, float(g[1]) - at.z, g[2], g[3], near])
				for hard in [false, true]:
					var uu := u.duplicate()
					if hard:
						uu["inner_fade"] = 0.0
					var e := _contact_band_edges(g, uu)
					if hard:
						hard_before = minf(hard_before, e[0]) if float(g[4]) > 0.0 else hard_before
					else:
						edge_worst = maxf(edge_worst, e[0])
						if float(g[4]) > 0.0:
							rim_weakest = minf(rim_weakest, e[1] / (float(u["rim_dark"]) * float(g[4])))
	check(turns >= 20 and off_centre.is_empty(),
		"contact band: every ring of the built-in drills (%d drill-directions) sits on its feet, a patch's within %.2f of them: %s" % [turns, fade, off_centre])
	check(edge_worst < 0.02 and rim_weakest > 0.95 and hard_before > 0.3,
		"contact band: no ring is dark at its hole's edge (at most %.3f; %.2f before, under --contact-inner=hard), the rim at the foot's edge kept (%.2f of full)" % [edge_worst, hard_before, rim_weakest])


## A contact ring's darkness (contact_shade.gdshader's fragment, close up, no speckle, its own side strengths) along its
## hole's edge (the most) and at its foot's edge (the least of the rim alone, at the middle of each side): [hole, edge].


static func _contact_band_edges(g: Array, u: Dictionary) -> Array:
	var h := Vector2(maxf(float(g[2]), 0.02), maxf(float(g[3]), 0.02))
	var r := clampf(float(g[6]), 0.0, minf(h.x, h.y))
	var in_h := (h - Vector2.ONE * (float(u["inset"]) + r * 0.2929)).max(h * 0.3)
	var fade_in := minf(float(u["inner_fade"]), minf(h.x - in_h.x, h.y - in_h.y))
	var dark := func(l: Vector2, rim_only: bool) -> float:
		var q := l.abs() - (h - Vector2.ONE * r)
		var d := q.max(Vector2.ZERO).length() + minf(maxf(q.x, q.y), 0.0) - r
		var dd := maxf(d, 0.0)
		var rim := float(u["rim_dark"]) * exp(-dd / float(u["rim_falloff"])) * (1.0 - smoothstep(float(u["rim_end"]) * 0.6, float(u["rim_end"]), dd))
		rim = clampf(rim, 0.0, 0.85) * float(g[4])
		var pa := 0.0 if rim_only else float(g[5]) * (1.0 - smoothstep(-0.05, float(u["patch_reach"]), d))
		var inner := smoothstep(-fade_in, 0.0, d) if fade_in > 0.0 else 1.0
		return 1.0 - (1.0 - rim * inner) * (1.0 - pa * inner)
	var hole := 0.0
	for k in 33:
		var t := -1.0 + float(k) / 16.0
		for l in [Vector2(in_h.x, t * in_h.y), Vector2(-in_h.x, t * in_h.y), Vector2(t * in_h.x, in_h.y), Vector2(t * in_h.x, -in_h.y)]:
			hole = maxf(hole, float(dark.call(l, false)))
	var edge := INF
	for l in [Vector2(h.x, 0.0), Vector2(-h.x, 0.0), Vector2(0.0, h.y), Vector2(0.0, -h.y)]:
		edge = minf(edge, float(dark.call(l, true)))
	return [hole, edge]


static func _rings_box(rings: Array) -> Rect2:
	var lo := Vector2.INF
	var hi := -Vector2.INF
	for g: Array in rings:
		lo = lo.min(Vector2(float(g[0]) - float(g[2]), float(g[1]) - float(g[3])))
		hi = hi.max(Vector2(float(g[0]) + float(g[2]), float(g[1]) + float(g[3])))
	return Rect2(lo, hi - lo)


## Contact shading in a built chunk (owner, 0.2.2: "the dark contact shading under and around buildings is gone
## again"): buildings placed through the world (their variant seeds and all) and the chunk built as a game builds
## it give the chunk a visible ContactShade MultiMesh with a ring for each, drawn with the contact shader over
## the ground (a multiply after the decoratives), none under a tree.


func _contact_chunk() -> void:
	var CS := preload("res://scripts/world/contact_shade.gd")
	var w := WorldMirror.new()
	add_child(w)
	w.protos = ProtoDB.new()
	w.protos.add_entities([[1, "assembling-machine-2", "assembling-machine", -1.2, -1.2, 1.2, 1.2, 200, 180, 0, 3, 3],
		[2, "electric-mining-drill", "mining-drill", -1.4, -1.4, 1.4, 1.4, 200, 180, 0, 3, 3],
		[3, "wooden-chest", "container", -0.35, -0.35, 0.35, 0.35, 200, 180, 0, 1, 1],
		[4, "tree-01", "tree", -0.4, -0.4, 0.4, 0.4, 20, 120, 20, 1, 1]])
	var c := Vector2i(0, 0)
	var cv := ChunkView.new()
	cv.coord = c
	w.chunks[c] = cv
	w.add_child(cv)
	w._add([9601, 1, 4 * 256 + 128, 4 * 256 + 128, 0, {}])
	w._add([9602, 2, 10 * 256 + 128, 4 * 256 + 128, 0, {}])
	w._add([9603, 3, 16 * 256 + 128, 4 * 256 + 128, 0, {}])
	w._add([9604, 4, 20 * 256 + 128, 4 * 256 + 128, 0, {}])
	_make_models(w.protos, cv)
	cv.build_entities(w.protos, {}, null)
	var node: MultiMeshInstance3D = cv.contact_node
	var count := node.multimesh.instance_count if node != null and node.multimesh != null else 0
	# Models with a contact map (CS.mask_of) are drawn by the node's ContactMasks child instead of a ring.
	var masks_node := node.get_node_or_null("ContactMasks") as MultiMeshInstance3D if node != null else null
	var mask_count := masks_node.multimesh.instance_count if masks_node != null else 0
	var mat := node.material_override as ShaderMaterial if node != null else null
	check(node != null and node.is_inside_tree() and node.visible and count + mask_count >= 3
		and (masks_node == null or masks_node.material_override == mat),
		"contact chunk: three buildings built in a chunk get a visible ContactShade with a ring or mask each (%d rings, %d masks)" % [count, mask_count])
	check(mat != null and mat.shader == CS.SHADER and mat.render_priority == -1 and node.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"contact chunk: drawn with the contact shader, a multiply over the ground after the decoratives, no shadow")
	var strong := 0
	for mmi: MultiMeshInstance3D in [node, masks_node]:
		if mmi == null:
			continue
		for i in mmi.multimesh.instance_count:
			var s := mmi.multimesh.get_instance_color(i)
			if maxf(maxf(s.r, s.g), maxf(s.b, s.a)) > 0.2:
				strong += 1
	check(strong >= 3, "contact chunk: every building's rim has strength on its sides (%d of %d)" % [strong, count + mask_count])
	w.queue_free()


## Contact shading shaped by the model (contact_shade.gd mask_of(); owner: "did we not fix the contact shadows to
## match the models?"): an L-shaped foot under a body that overhangs its empty corner gets an L-shaped mask with
## nothing under the corner, a part raised off the ground darkens less and one past MASK_HEIGHT not at all, a belt's
## joined variant is cut at its tile's edge, the quad is placed turned and mirrored as the model is, a chunk draws the
## masks on the rings' node, and --contact-shape=box keeps the rings.


func _contact_mask() -> void:
	var CS := preload("res://scripts/world/contact_shade.gd")
	var quads := func(list: Array) -> Array:  # [lo x, lo z, hi x, hi z, height] each: one flat quad
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		var v := PackedVector3Array()
		var ix := PackedInt32Array()
		for q: Array in list:
			var b := v.size()
			var y := float(q[4])
			v.append_array([Vector3(q[0], y, q[1]), Vector3(q[2], y, q[1]), Vector3(q[0], y, q[3]), Vector3(q[2], y, q[3])])
			ix.append_array([b, b + 1, b + 2, b + 1, b + 3, b + 2])
		a[Mesh.ARRAY_VERTEX] = v
		a[Mesh.ARRAY_INDEX] = ix
		return [[], a, 0]
	# The byte at a model point (x, z) of a mask.
	var at := func(mask: Array, bytes: PackedByteArray, x: float, z: float) -> int:
		var r: Rect2 = mask[0]
		var i := clampi(floori((x - r.position.x) / r.size.x * CS.MASK_SIZE), 0, CS.MASK_SIZE - 1)
		var j := clampi(floori((z - r.position.y) / r.size.y * CS.MASK_SIZE), 0, CS.MASK_SIZE - 1)
		return bytes[j * CS.MASK_SIZE + i]
	# An L: the foot on the ground everywhere but the +x +z quarter, a roof at 0.6 over all of it (overhanging the corner).
	var l_groups := [quads.call([[-1, -1, 1, 0, 0.0], [-1, 0, 0, 1, 0.0], [-1, -1, 1, 1, 0.6]])]
	var l_mask := CS.mask_of(l_groups)
	check(l_mask.size() == 3 and (l_mask[1] as PackedByteArray).size() == CS.MASK_SIZE * CS.MASK_SIZE,
		"contact mask: a model on the ground gets a %d-square mask" % CS.MASK_SIZE)
	if l_mask.size() != 3:
		return
	var lb: PackedByteArray = l_mask[1]
	var corner_dark := 0
	var corner_any := 0
	for j in CS.MASK_SIZE:
		for i in CS.MASK_SIZE:
			var r: Rect2 = l_mask[0]
			var p := r.position + Vector2(i + 0.5, j + 0.5) * r.size / float(CS.MASK_SIZE)
			if p.x > 0.08 and p.y > 0.08 and p.x < 1.0 and p.y < 1.0:
				if lb[j * CS.MASK_SIZE + i] < 0.05 / CS.MASK_RANGE * 255.0:
					corner_dark += 1
			if p.x > 0.3 and p.y > 0.3 and p.x < 1.0 and p.y < 1.0 and lb[j * CS.MASK_SIZE + i] < 0.29 / CS.MASK_RANGE * 255.0:
				corner_any += 1
	var near_inner := float(at.call(l_mask, lb, 0.15, 0.6)) / 255.0 * CS.MASK_RANGE
	check(at.call(l_mask, lb, 0.5, -0.5) == 0 and at.call(l_mask, lb, -0.5, 0.5) == 0 and at.call(l_mask, lb, -0.9, -0.9) == 0
		and corner_dark == 0 and corner_any == 0 and at.call(l_mask, lb, 0.6, 0.6) == 255 and absf(near_inner - 0.15) < 0.03,
		"contact mask: an L-shaped foot is an L, nothing under its empty corner though the roof covers it (%d dark, %d within the rim's reach 0.3 into it), %.3f tiles beside it"
		% [corner_dark, corner_any, near_inner])
	# The far side of the foot: the rim falls off past it, gone by MASK_MARGIN.
	check(at.call(l_mask, lb, 1.12, -0.5) > 0 and at.call(l_mask, lb, 1.12, -0.5) < 255 and at.call(l_mask, lb, -0.5, 1.28) >= 180,
		"contact mask: the distance grows past the foot's edge")
	# A ledge 0.15 up darkens less than the ground (pushed out), one at 0.3 not at all.
	var ledges := CS.mask_of([quads.call([[-0.5, -0.5, 0.5, 0.5, 0.0], [0.5, -0.5, 1.5, 0.5, 0.15], [-1.5, -0.5, -0.5, 0.5, 0.3]])])
	var low_ledge := float(at.call(ledges, ledges[1], 1.2, 0.0)) / 255.0 * CS.MASK_RANGE
	check(low_ledge > 0.06 and low_ledge < 0.2 and (ledges[0] as Rect2).position.x > -0.85,
		"contact mask: a part 0.15 up darkens as if %.3f tiles off (less), one 0.3 up not at all" % low_ledge)
	check(CS.mask_of([quads.call([[-0.5, -0.5, 0.5, 0.5, 0.4]])]).is_empty(), "contact mask: a model that floats has none")
	# A moving part's triangles (Load's parts, rest pose) count: a foot only in a part.
	var with_part := CS.mask_of([quads.call([[-0.5, -0.5, 0.5, 0.5, 0.0]])], [["anim_x", Transform3D.IDENTITY, [quads.call([[0.5, -0.2, 0.9, 0.2, 0.0]])]]])
	check(at.call(with_part, with_part[1], 0.8, 0.0) == 0, "contact mask: a moving part on the ground in its rest pose counts")
	# A belt: two side rails on its whole tile and its plate 0.1 up. Its joined variant is cut at the tile's ends
	# (carried on to them, none past), the plain one rounds past them.
	var belt := CS.mask_of([quads.call([[-0.42, -0.5, -0.36, 0.5, 0.0], [0.36, -0.5, 0.42, 0.5, 0.0], [-0.36, -0.5, 0.36, 0.5, 0.1]])])
	var bj: PackedByteArray = belt[2]
	check(not bj.is_empty() and at.call(belt, bj, 0.47, 0.56) == 255 and at.call(belt, bj, 0.47, -0.56) == 255
		and at.call(belt, bj, 0.47, 0.46) < 60 and at.call(belt, bj, 0.47, 0.46) == at.call(belt, bj, 0.47, 0.0)
		and at.call(belt, belt[1], 0.47, 0.56) < 120,
		"contact mask: a belt's joined variant runs straight to its tile's ends and stops there: %d past, %d before, plain %d past"
		% [at.call(belt, bj, 0.47, 0.56), at.call(belt, bj, 0.47, 0.46), at.call(belt, belt[1], 0.47, 0.56)])
	# Placed: the quad maps the mask's square onto the model as placed, a quarter turn, and a mirror on top.
	var mesh := ArrayMesh.new()
	var committed := CS.commit_mask(l_mask)
	mesh.set_meta(CS.MASK_META, committed)
	var belt_mesh := ArrayMesh.new()
	belt_mesh.set_meta(CS.MASK_META, CS.commit_mask(belt))
	var r: Rect2 = l_mask[0]
	var placed_ok := true
	for xform: Transform3D in [Transform3D(Basis.IDENTITY, Vector3(3.5, 0, 4.5)), Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(10.5, 0, 5.5)),
			Transform3D(Basis(Vector3.UP, PI / 2.0) * Basis.from_scale(Vector3(-1, 1, 1)), Vector3(20.5, 0, 5.5))]:
		var out: Array = []
		CS.collect(out, "assembling-machine-1", "assembling-machine", mesh, xform, Vector2.ZERO, Vector2.ZERO, Vector2(2, 2))
		if out.size() != 1 or (out[0] as Array).size() < 10:
			placed_ok = false
			continue
		var quad: Transform3D = out[0][8]
		for p: Vector2 in [Vector2(0.6, 0.6), Vector2(-0.9, 0.2), Vector2(0.5, -0.5)]:
			var uv := (p - r.position) / r.size
			var w := quad * Vector3(uv.x * 2.0 - 1.0, 0.0, uv.y * 2.0 - 1.0)
			var want := xform * Vector3(p.x, 0.0, p.y)
			if not Vector2(w.x, w.z).is_equal_approx(Vector2(want.x, want.z)):
				placed_ok = false
		if int(out[0][9]) != int(committed[1]) or absf(float(out[0][2]) - 1.0) > 0.01 or absf(float(out[0][3]) - 1.0) > 0.01:
			placed_ok = false
	check(placed_ok, "contact mask: its quad follows the model's turn and mirror, its contact box (for neighbours' halving) the foot's")
	var belt_out: Array = []
	CS.collect(belt_out, "transport-belt", "transport-belt", belt_mesh, Transform3D.IDENTITY, Vector2.ZERO, Vector2.ZERO, Vector2(1, 1))
	CS.collect(belt_out, "assembling-machine-1", "assembling-machine", belt_mesh, Transform3D.IDENTITY, Vector2.ZERO, Vector2.ZERO, Vector2(1, 1))
	var belt_slots: Array = belt_mesh.get_meta(CS.MASK_META)
	check(belt_out.size() == 2 and int(belt_out[0][9]) == int(belt_slots[2]) and int(belt_out[1][9]) == int(belt_slots[1]) and int(belt_slots[2]) >= 0,
		"contact mask: belts, pipes and walls draw the joined variant, other types the plain one")
	# A run of three belts going south: their joined masks don't halve each other's sides (a light notch at each
	# joint); a belt running beside them a tile east halves the sides facing it.
	var run: Array = []
	for i in 3:
		CS.collect(run, "transport-belt", "transport-belt", belt_mesh, Transform3D(Basis.IDENTITY, Vector3(0.5, 0, 0.5 + i)), Vector2.ZERO, Vector2.ZERO, Vector2(1, 1))
	var run_sides := CS._sides(run)
	CS.collect(run, "transport-belt", "transport-belt", belt_mesh, Transform3D(Basis.IDENTITY, Vector3(1.5, 0, 1.5)), Vector2.ZERO, Vector2.ZERO, Vector2(1, 1))
	var beside := CS._sides(run)
	check(run_sides.all(func(c: Color) -> bool: return c.is_equal_approx(Color(0.8, 0.8, 0.8, 0.8)))
		and beside[1].r < 0.6 and beside[3].g < 0.6 and is_equal_approx(beside[1].g, 0.8),
		"contact mask: a belt run's pieces don't halve each other, a belt alongside does: %s / %s" % [run_sides, beside])
	# --contact-shape=box: the rings, as before.
	CS.box_shape = true
	var boxed: Array = []
	var both := ArrayMesh.new()
	both.set_meta(CS.MASK_META, committed)
	both.set_meta(CS.META, [[Rect2(-1, -1, 2, 2), 0.02]])
	CS.collect(boxed, "assembling-machine-1", "assembling-machine", both, Transform3D.IDENTITY, Vector2.ZERO, Vector2.ZERO, Vector2(2, 2))
	CS.box_shape = false
	check(boxed.size() == 1 and (boxed[0] as Array).size() == 8, "contact mask: --contact-shape=box draws the ring round the feet' box")
	# A chunk: rings and masks on one node, the masks on its ContactMasks child with the same material and the atlas.
	var parent := Node3D.new()
	add_child(parent)
	var rings: Array = []
	CS.collect(rings, "assembling-machine-1", "assembling-machine", mesh, Transform3D(Basis.IDENTITY, Vector3(3.5, 0, 4.5)), Vector2.ZERO, Vector2.ZERO, Vector2(2, 2))
	CS.collect(rings, "assembling-machine-1", "assembling-machine", mesh, Transform3D(Basis.IDENTITY, Vector3(6.0, 0, 4.5)), Vector2.ZERO, Vector2.ZERO, Vector2(2, 2))
	CS.collect(rings, "assembling-machine-1", "assembling-machine", null, Transform3D(Basis.IDENTITY, Vector3(12.5, 0, 4.5)), Vector2(-1, -1), Vector2(1, 1))
	var node := CS.apply(parent, null, rings)
	var masks := node.get_node_or_null("ContactMasks") as MultiMeshInstance3D if node != null else null
	var atlas = CS.material().get_shader_parameter("mask_atlas")
	check(node != null and node.multimesh.instance_count == 1 and masks != null and masks.multimesh.instance_count == 2
		and masks.material_override == CS.material() and atlas is ImageTexture and (atlas as ImageTexture).get_height() >= CS.MASK_SIZE,
		"contact mask: a chunk draws one ring and two masks, on the contact node and its ContactMasks child, the atlas on the material")
	# (Read from _sides(): a headless MultiMesh gives no instance colours back.)
	var sides := CS._sides(rings)
	check(sides[0].r < 1.0 and sides[0].g == 1.0 and sides[1].g < 1.0 and sides[2] == Color(1, 1, 1, 1),
		"contact mask: a mask's side facing a close neighbour is halved like a ring's (%s)" % [sides])
	parent.queue_free()


## A float uniform's default in shader code (`uniform float <name> = <value>;`), or -1.


func _shader_float(code: String, uniform_name: String) -> float:
	var at := code.find("uniform float %s = " % uniform_name)
	if at < 0:
		return -1.0
	return float(code.substr(at).get_slice("= ", 1).get_slice(";", 0))


## Ambient occlusion by zoom (ao_zoom.gd): how close the view is measured for each kind of camera,
## SSAO faded and switched off zoomed out (the renderer's copy; the Environment keeps the look's and the
## setting's values), back on with a margin, and the contact rims' fade taken from the same place.


func _ao_zoom() -> void:
	var AoZoom := preload("res://scripts/world/ao_zoom.gd")
	var CS := preload("res://scripts/world/contact_shade.gd")
	var screen := Vector2(1920, 1080)
	var cam := Camera3D.new()
	cam.fov = 35.0
	add_child(cam)
	# The angled view 10 and 180 tiles from the ground it looks at (50 degrees down), then F6's view.
	cam.look_at_from_position(Vector3(0, sin(deg_to_rad(50.0)) * 10.0, cos(deg_to_rad(50.0)) * 10.0), Vector3.ZERO)
	var near := AoZoom.view_tiles_per_pixel(cam, screen)
	cam.look_at_from_position(Vector3(0, sin(deg_to_rad(50.0)) * 180.0, cos(deg_to_rad(50.0)) * 180.0), Vector3.ZERO)
	var far := AoZoom.view_tiles_per_pixel(cam, screen)
	check(absf(near - 10.0 * 2.0 * tan(deg_to_rad(17.5)) / 1080.0) < 1e-4 and near < AoZoom.SSAO_FULL and far > AoZoom.SSAO_GONE,
		"ao zoom: the angled view 10 tiles off is close, 180 tiles off far (%.4f, %.4f tiles a pixel)" % [near, far])
	# First person looking at the horizon: measured NO_GROUND off, not at infinity.
	cam.look_at_from_position(Vector3(0, 1.6, 0), Vector3(0, 1.6, -10))
	var level := AoZoom.view_tiles_per_pixel(cam, screen)
	check(is_equal_approx(level, AoZoom.NO_GROUND * 2.0 * tan(deg_to_rad(17.5)) / 1080.0), "ao zoom: a view that doesn't meet the ground is measured NO_GROUND off")
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 30.0
	check(is_equal_approx(AoZoom.view_tiles_per_pixel(cam, screen), 30.0 / 1080.0), "ao zoom: an orthographic view by its size")
	cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	var env := Environment.new()
	env.ssao_enabled = true
	env.ssao_intensity = 1.6
	var z: Node = AoZoom.new()
	z.env = env
	add_child(z)
	cam.make_current()
	var at := func(d: float) -> void:
		cam.look_at_from_position(Vector3(0, sin(deg_to_rad(50.0)) * d, cos(deg_to_rad(50.0)) * d), Vector3.ZERO)
	# Distances from the test window's own height (headless it is 64 pixels, not 1080): half SSAO_FULL's
	# tiles a pixel up close, twice SSAO_GONE's far.
	var tiles_per_px_per_tile := 2.0 * tan(deg_to_rad(17.5)) / float(get_viewport().get_visible_rect().size.y)
	var close_d := AoZoom.SSAO_FULL * 0.5 / tiles_per_px_per_tile
	var far_d := AoZoom.SSAO_GONE * 2.0 / tiles_per_px_per_tile
	at.call(close_d)
	await get_tree().process_frame
	await get_tree().process_frame
	var close_on: bool = z.ssao_on and is_equal_approx(float(z.ssao_share), 1.0)
	at.call(far_d)
	await get_tree().process_frame
	await get_tree().process_frame
	var far_off: bool = not z.ssao_on and float(z.ssao_share) < 0.01
	check(close_on and far_off and env.ssao_enabled and is_equal_approx(env.ssao_intensity, 1.6),
		"ao zoom: SSAO full up close, off zoomed out, the Environment's own values untouched (%s %s)" % [close_on, far_off])
	# Just inside the off margin coming back: stays off until the share passes SSAO_ON_AGAIN.
	var share_at := func(d: float) -> float:
		return 1.0 - smoothstep(AoZoom.SSAO_FULL, AoZoom.SSAO_GONE, d * tiles_per_px_per_tile)
	var edge := far_d
	while edge > close_d and share_at.call(edge) < (AoZoom.SSAO_OFF + AoZoom.SSAO_ON_AGAIN) * 0.5:
		edge -= far_d / 400.0
	at.call(edge)
	await get_tree().process_frame
	await get_tree().process_frame
	var held_off: bool = not z.ssao_on
	at.call(close_d)
	await get_tree().process_frame
	await get_tree().process_frame
	check(held_off and z.ssao_on, "ao zoom: between the two margins it stays as it was, so it doesn't toggle on the edge")
	env.ssao_enabled = false
	await get_tree().process_frame
	check(not z.ssao_on, "ao zoom: off when the setting and the look have it off, however close")
	var m := CS.material()
	check(is_equal_approx(float(m.get_shader_parameter("fade_from")), AoZoom.RIM_FULL) and is_equal_approx(float(m.get_shader_parameter("fade_to")), AoZoom.RIM_GONE),
		"ao zoom: the contact rims fade by the same file's thresholds")
	z.queue_free()
	cam.queue_free()


## The 0.2.1 performance hotfix's post-processing: the same picture for less. Zenith's cloud shadow
## quad hidden while it would draw nothing, the smog's pass only while smog can show in view, the
## sun's map at most 4096 under soft shadows behind --soft-shadow-atlas, and look passes drawn first
## of their priority (flat ground clutter sharing it was drawn and then covered).


func _post_hotfix() -> void:
	var SkyScript := preload("res://scripts/world/sky.gd")
	var sky: Node = SkyScript.new()
	add_child(sky)
	var env := Environment.new()
	var sun := DirectionalLight3D.new()
	add_child(sun)
	var quad: MeshInstance3D = sky.get_node("CloudShadows")
	sky.set_clouds(true)
	sky.set_planet("nauvis")
	sky.apply(env, sun, 0.0, 0.0, 0.016, false)
	var day: bool = quad.visible
	sky.apply(env, sun, 0.5, 1.0, 0.016, false)
	var night: bool = quad.visible
	sky.set_planet("gleba")
	sky.apply(env, sun, 0.5, 1.0, 0.016, false)
	var hazy: bool = quad.visible
	sky.set_planet("nauvis")
	sky.apply(env, sun, 0.0, 0.0, 0.016, true)
	var space: bool = quad.visible
	check(day and not night and hazy and not space,
		"cloud shadows: drawn by day, hidden at night where they draw nothing, kept for Gleba's haze, none in space (%s %s %s %s)" % [day, night, hazy, space])
	sky.queue_free()
	sun.queue_free()

	# Smog: the chunks the pass can read for the camera, and the pass only while one of them has smog.
	var PollutionScript := preload("res://scripts/world/pollution.gd")
	var cam := Camera3D.new()
	cam.fov = 35.0
	add_child(cam)
	cam.make_current()
	var screen := get_viewport().get_visible_rect().size
	var over := func(x: float, z: float) -> void:
		cam.look_at_from_position(Vector3(x, sin(deg_to_rad(50.0)) * 30.0, z + cos(deg_to_rad(50.0)) * 30.0), Vector3(x, 0.0, z))
	over.call(0.0, 0.0)
	var rect: Variant = PollutionScript.view_chunks(cam, screen, -1.5)
	check(rect is Rect2i and (rect as Rect2i).has_point(Vector2i(0, 0)) and (rect as Rect2i).has_point(Vector2i(-1, -1))
		and not (rect as Rect2i).has_point(Vector2i(10, 0)),
		"smog: the angled view 30 tiles off reads the chunks round where it looks and a chunk beyond, not ten chunks off: %s" % [rect])
	cam.look_at_from_position(Vector3(0, 1.6, 0), Vector3(0, 1.6, -10))
	check(not (PollutionScript.view_chunks(cam, screen, -1.5) is Rect2i), "smog: with the horizon in view, any chunk's smog may show")
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 60.0
	cam.look_at_from_position(Vector3(0, 100, 1), Vector3.ZERO)
	var flat: Variant = PollutionScript.view_chunks(cam, screen, -1.5)
	check(flat is Rect2i and (flat as Rect2i).has_point(Vector2i(0, 0)) and (flat as Rect2i).size.x <= 8,
		"smog: Factorio's flat view reads the chunks under its square: %s" % [flat])
	cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	# Smog is off by default since the settings' new defaults (graphics/smog 0.0: no pass at all); its pass is
	# checked with the player's slider up, then put back.
	var smog_was: Variant = Settings.get_value("graphics", "smog")
	Settings.set_value("graphics", "smog", 0.5)
	var pol: Node3D = PollutionScript.new()
	add_child(pol)
	var smog: MeshInstance3D = pol.get_node("Smog")
	over.call(0.0, 0.0)
	pol.update(Vector2.ZERO, 0.0, 0.05)
	var none: bool = smog.visible
	# A heavily polluted chunk ten chunks east (x 320-352), eased in over EASE seconds.
	pol.handle({"t": "pol", "w": 1, "cx": 10, "cy": 0, "md": 60, "l": [4000]})
	for i in 120:
		pol.update(Vector2.ZERO, 0.0, 0.05)
	var away: bool = smog.visible
	over.call(336.0, 16.0)
	pol.update(Vector2(336.0, 16.0), 0.0, 0.05)
	var on: bool = smog.visible
	# Looking at the chunk before it, the pass may read its texel (the reads blend chunk centres).
	over.call(296.0, 16.0)
	pol.update(Vector2(296.0, 16.0), 0.0, 0.05)
	var near: bool = smog.visible
	pol.clear()
	pol.update(Vector2(336.0, 16.0), 0.0, 0.05)
	var cleared: bool = smog.visible
	check(not none and not away and on and near and not cleared,
		"smog: no pass without pollution, nor with it ten chunks off; drawn over it and over the chunk before it, gone at once on a new surface (%s %s %s %s %s)" % [none, away, on, near, cleared])

	# Volumetric smog & God rays: ground-to-sky smog at priority 3, additive God rays at priority 4
	# (below RemoteFog at 5), synchronised with Zenith's clouds or a look's cloud_field.
	var smog_mat := smog.material_override as ShaderMaterial
	check(pol.is_volumetric() and smog_mat.render_priority == PollutionScript.PRIORITY
		and is_equal_approx(float(smog_mat.get_shader_parameter("volumetric")), 1.0)
		and not smog_mat.shader.code.contains("hint_screen_texture"),
		"smog: volumetric sky-reaching mode enabled by default at priority %d without screen copy" % PollutionScript.PRIORITY)
	pol.set_volumetric(false)
	check(not pol.is_volumetric() and is_equal_approx(float(smog_mat.get_shader_parameter("volumetric")), 0.0),
		"smog: set_volumetric(false) restores legacy 5-tile ground layer (--smog-look=old)")
	pol.set_volumetric(true)
	pol.handle({"t": "pol", "w": 1, "cx": 10, "cy": 0, "md": 60, "l": [4000]})
	for i in 120:
		pol.update(Vector2.ZERO, 0.0, 0.05)
	over.call(336.0, 16.0)
	pol.update(Vector2(336.0, 16.0), 0.0, 0.05, {"space": true})
	var smog_space: bool = smog.visible
	var dummy_tex := ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))
	var day_atmo := {
		"space": false, "sun_dir": Vector3(0.0, 0.7, -0.7), "sky_sun_dir": Vector3(0.0, 0.7, -0.7),
		"sun_color": Color.WHITE, "ambient_color": Color.GRAY, "sun_strength": 1.0, "twilight": 0.25,
		"scene_light": Vector2.ONE, "cloud_mode": 1, "cloud_shape": dummy_tex, "cloud_detail": dummy_tex,
		"cloud_cover": 0.46, "cloud_height": 70.0, "cloud_alpha": 0.85, "haze": 0.0, "haze_color": Color.WHITE,
	}
	pol.update(Vector2(336.0, 16.0), 0.0, 0.05, day_atmo)
	check(not smog_space and smog.visible and is_equal_approx(float(smog_mat.get_shader_parameter("cloud_mode")), 1.0),
		"smog: hidden in space, shown in atmosphere with synced cloud uniforms (%s %s)" % [smog_space, smog.visible])

	var GodRaysScript := preload("res://scripts/world/god_rays.gd")
	var sky_node := PlanetSky.new()
	add_child(sky_node)
	var base_atmo: Dictionary = sky_node.atmosphere()
	check(base_atmo.has("sun_dir") and base_atmo.has("sky_sun_dir") and base_atmo.has("sun_strength")
		and base_atmo.has("cloud_mode") and base_atmo.has("haze") and base_atmo.has("planet"),
		"sky: atmosphere() exposes full snapshot for volumetric passes")
	var gr: Node3D = GodRaysScript.new()
	add_child(gr)
	var gr_quad: MeshInstance3D = gr.get_node("GodRays")
	var gr_mat := gr_quad.material_override as ShaderMaterial
	check(gr_mat.render_priority == GodRaysScript.PRIORITY and gr_mat.render_priority > smog_mat.render_priority
		and gr_mat.render_priority < 5 and not gr_mat.shader.code.contains("hint_screen_texture"),
		"god rays: priority %d sits strictly over Smog (%d) and under RemoteFog (5), no screen copy" % [gr_mat.render_priority, smog_mat.render_priority])
	gr.set_forced_strength(0.6)
	gr.update(day_atmo, pol.strength())
	var gr_day_m1 := gr_quad.visible and is_equal_approx(float(gr_mat.get_shader_parameter("cloud_mode")), 1.0)
	var field_tex := ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))
	var look_atmo := day_atmo.duplicate()
	look_atmo["cloud_mode"] = 2
	look_atmo["look_cloud_field"] = field_tex
	look_atmo["look_cloud_cover"] = 0.45
	gr.update(look_atmo, pol.strength())
	var gr_m2 := gr_quad.visible and is_equal_approx(float(gr_mat.get_shader_parameter("cloud_mode")), 2.0) and is_equal_approx(float(gr_mat.get_shader_parameter("look_cloud_cover")), 0.45)
	var nocloud_atmo := day_atmo.duplicate()
	nocloud_atmo["cloud_mode"] = 0
	gr.update(nocloud_atmo, pol.strength())
	var gr_m0 := gr_quad.visible and is_equal_approx(float(gr_mat.get_shader_parameter("cloud_mode")), 0.0)
	var night_atmo := day_atmo.duplicate()
	night_atmo["sun_strength"] = 0.0
	gr.update(night_atmo, pol.strength())
	var gr_night := gr_quad.visible
	var low_atmo := day_atmo.duplicate()
	low_atmo["sun_dir"] = Vector3(0.0, 0.01, -1.0)
	low_atmo["sky_sun_dir"] = Vector3(0.0, 0.01, -1.0)
	low_atmo["sun_strength"] = 0.5
	gr.update(low_atmo, pol.strength())
	var gr_low := gr_quad.visible
	var nosun_atmo := day_atmo.duplicate()
	nosun_atmo["scene_light"] = Vector2(1.0, 0.0)
	gr.update(nosun_atmo, pol.strength())
	var gr_nosun := gr_quad.visible
	var space_atmo := day_atmo.duplicate()
	space_atmo["space"] = true
	gr.update(space_atmo, pol.strength())
	var gr_space := gr_quad.visible
	gr.set_forced_strength(0.0)
	gr.update(day_atmo, pol.strength())
	var gr_off := gr_quad.visible
	gr.set_forced_strength(-1.0)
	check(gr_day_m1 and gr_m2 and gr_m0 and not gr_night and not gr_low and not gr_nosun and not gr_space and not gr_off,
		"god rays: tracks Zenith/look/cloudless modes cleanly and hides at night, low horizon, sun=0, space, or strength 0")
	gr.update(day_atmo, pol.strength())

	# Distant pollution caching, 128x128 RGBA8 texture with aloft blur, per-surface cache, and
	# baked noise / extended range.
	pol.handle({"t": "pol", "w": 1, "cx": -10, "cy": 0, "md": 60, "l": [4000]})
	for i in 120:
		pol.update(Vector2.ZERO, 0.0, 0.05)
	var both_cached: bool = bool(pol.has_cached_chunk(Vector2i(10, 0))) and bool(pol.has_cached_chunk(Vector2i(-10, 0)))
	# Move focus to chunk (25, 0) while _live_rect is at (-10, 0): w=0 must keep (10, 0) between them.
	pol.update(Vector2(800.0, 0.0), 0.0, 0.05)
	pol.handle({"t": "pol", "w": 0})
	var w0_kept_far: bool = bool(pol.has_cached_chunk(Vector2i(10, 0))) and not bool(pol.has_cached_chunk(Vector2i(-10, 0)))
	pol.update(Vector2.ZERO, 0.0, 0.05)
	pol.handle({"t": "pol", "w": 1, "cx": 10, "cy": 0, "md": 60, "l": [0]})
	var explicit_zero_cleared: bool = not bool(pol.has_cached_chunk(Vector2i(10, 0)))
	check(both_cached and w0_kept_far and explicit_zero_cleared,
		"smog cache: retains distant chunks across moving pol windows and w=0 (including between old live rect and new focus), clears explicit zeros (%s %s %s)" % [both_cached, w0_kept_far, explicit_zero_cleared])

	pol.handle({"t": "pol", "w": 1, "cx": 10, "cy": 0, "md": 60, "l": [4000]})
	pol.ingest_chart_pollution(Vector2i(10, 0), 0.0)
	var live_not_overwritten: bool = bool(pol.has_cached_chunk(Vector2i(10, 0)))
	pol.ingest_chart_pollution(Vector2i(28, 0), 2000.0)
	for i in 120:
		pol.update(Vector2.ZERO, 0.0, 0.05)
	var chart_far_cached: bool = bool(pol.has_cached_chunk(Vector2i(28, 0)))
	var ptex: Texture2D = pol._texture
	var pimg: Image = pol._image
	var porigin: Vector2i = pol._origin
	var p10: Color = pimg.get_pixelv(Vector2i(10, 0) - porigin)
	var p11: Color = pimg.get_pixelv(Vector2i(11, 0) - porigin)
	var p28: Color = pimg.get_pixelv(Vector2i(28, 0) - porigin)
	check(live_not_overwritten and chart_far_cached and ptex.get_width() == 128 and ptex.get_height() == 128
		and pimg.get_format() == Image.FORMAT_RGBA8 and p28.g > 0.0 and p28.b > 0.0
		and p10.r > 0.0 and p10.g > 0.0 and p10.b > 0.0
		and is_zero_approx(p11.r) and is_zero_approx(p11.g) and p11.b > 0.0,
		"smog cache: ingests distant map pollution into 128x128 RGBA8 texture with blurred aloft B channel (%s %s %s %s %s)" % [live_not_overwritten, chart_far_cached, p10, p11, p28])

	pol.set_surface(1, true)
	pol.handle({"t": "pol", "w": 1, "cx": 5, "cy": 5, "md": 60, "l": [2000]})
	var s1_added: bool = bool(pol.has_cached_chunk(Vector2i(5, 5)))
	pol.set_surface(2, true)
	var s2_empty: bool = not bool(pol.has_cached_chunk(Vector2i(5, 5)))
	pol.set_surface(1, true)
	var s1_restored: bool = bool(pol.has_cached_chunk(Vector2i(5, 5)))
	pol.clear()
	var full_wiped: bool = not bool(pol.has_cached_chunk(Vector2i(5, 5)))
	pol.set_surface(2, true)
	pol.set_surface(1, true)
	var cache_wiped: bool = not bool(pol.has_cached_chunk(Vector2i(5, 5)))
	pol.set_cache_enabled(false)
	pol.handle({"t": "pol", "w": 1, "cx": 10, "cy": 0, "md": 60, "l": [4000]})
	pol.handle({"t": "pol", "w": 1, "cx": -10, "cy": 0, "md": 60, "l": [4000]})
	var legacy_wiped: bool = not bool(pol.is_cache_enabled()) and not bool(pol.has_cached_chunk(Vector2i(10, 0))) and bool(pol.has_cached_chunk(Vector2i(-10, 0)))
	pol.set_cache_enabled(true)
	check(s1_added and s2_empty and s1_restored and full_wiped and cache_wiped and legacy_wiped,
		"smog cache: preserves per-surface pollution across switches, clear() wipes all, --smog-cache=off restores legacy wipe (%s %s %s %s %s %s)" % [s1_added, s2_empty, s1_restored, full_wiped, cache_wiped, legacy_wiped])

	var smog_far_def: Variant = RenderingServer.shader_get_parameter_default(smog_mat.shader.get_rid(), &"far")
	var smog_sky_def: Variant = RenderingServer.shader_get_parameter_default(smog_mat.shader.get_rid(), &"sky_height")
	var gr_far_def: Variant = RenderingServer.shader_get_parameter_default(gr_mat.shader.get_rid(), &"far")
	check(smog_mat.get_shader_parameter("smog_noise") != null
		and smog_mat.shader.code.contains("uniform float far = 1600.0;")
		and smog_mat.shader.code.contains("uniform float sky_height = 175.0;")
		and gr_mat.shader.code.contains("uniform float far = 640.0;")
		and (smog_far_def == null or float(smog_far_def) >= 1200.0)
		and (smog_sky_def == null or float(smog_sky_def) >= 150.0)
		and (gr_far_def == null or float(gr_far_def) >= 600.0),
		"smog & god rays: baked billow noise bound and extended sky/far ranges set (%s %s %s)" % [smog_far_def, smog_sky_def, gr_far_def])

	remove_child(gr)
	gr.free()
	remove_child(pol)
	pol.free()
	Settings.set_value("graphics", "smog", smog_was)
	check(gr_mat.get_shader_parameter("cloud_shape") == null and gr_mat.get_shader_parameter("look_cloud_field") == null
		and smog_mat.get_shader_parameter("cloud_shape") == null and smog_mat.get_shader_parameter("look_cloud_field") == null
		and smog_mat.get_shader_parameter("smog_noise") == null,
		"god rays & smog: _exit_tree releases shared cloud textures and baked smog noise")

	# Pollution: immediate snap for unseen chunks (no green-then-grey delay), 256x256 R8 far horizon
	# texture out to +-512 chunks, and persistent Zstd disk cache round-trip + --smog-cache=off opt-out.
	var pol_dir := "user://pol-cache-ui-test"
	var SafeDeleteScript: GDScript = preload("res://scripts/safe_delete.gd")
	SafeDeleteScript.remove_tree(ProjectSettings.globalize_path(pol_dir))
	var pol2: Node3D = PollutionScript.new()
	add_child(pol2)
	pol2.configure("ui-pol-save", 1, pol_dir)
	pol2.handle({"t": "pol", "w": 1, "cx": 0, "cy": 0, "md": 60, "l": [3000]})
	var snap_live: bool = pol2._shown.has(Vector2i(0, 0)) and float(pol2._shown[Vector2i(0, 0)].x) > 0.5
	pol2.ingest_chart_pollution(Vector2i(10, 0), 2500.0)
	var snap_chart: bool = pol2._shown.has(Vector2i(10, 0))
	pol2.handle_sparse({"t": "pols", "si": 1, "md": 60, "l": [200, 0, 3500]})
	var snap_sparse: bool = pol2._shown.has(Vector2i(200, 0))
	pol2.update(Vector2.ZERO, 0.0, 0.016)
	var ftex: ImageTexture = pol2.far_texture()
	var frect: Vector4 = pol2.far_rect()
	var fimg: Image = pol2._far_image
	var fx := floori(float(200 - pol2._far_origin.x) / float(PollutionScript.FAR_CELL_CHUNKS))
	var fy := floori(float(0 - pol2._far_origin.y) / float(PollutionScript.FAR_CELL_CHUNKS))
	var far_px: float = fimg.get_pixel(fx, fy).r if (fx >= 0 and fx < PollutionScript.FAR_SIZE and fy >= 0 and fy < PollutionScript.FAR_SIZE) else 0.0
	pol2.handle({"t": "pol", "w": 1, "cx": 0, "cy": 0, "md": 60, "l": [0]})
	var existing_eases: bool = pol2._shown.has(Vector2i(0, 0))
	check(snap_live and snap_chart and snap_sparse and existing_eases and frect.w > 0.5
		and ftex != null and ftex.get_width() == 256 and ftex.get_height() == 256
		and fimg.get_format() == Image.FORMAT_R8 and far_px > 0.5,
		"pollution: snaps newly seen pol/chart/pols chunks at once, eases existing edits, writes 256x256 far horizon R8 (%s %s %s %s %.2f)" % [snap_live, snap_chart, snap_sparse, existing_eases, far_px])

	pol2.handle({"t": "pol", "w": 1, "cx": 0, "cy": 0, "md": 60, "l": [3000]})
	pol2.flush_cache()
	var pol3: Node3D = PollutionScript.new()
	add_child(pol3)
	pol3.configure("ui-pol-save", 1, pol_dir)
	var disk_restored: bool = pol3._shown.has(Vector2i(0, 0)) and pol3._shown.has(Vector2i(200, 0)) and float(pol3.far_rect().w) > 0.5
	var pol4: Node3D = PollutionScript.new()
	pol4.set_cache_enabled(false)
	add_child(pol4)
	pol4.configure("ui-pol-save", 1, pol_dir)
	var off_skips_disk: bool = not pol4._shown.has(Vector2i(0, 0)) and not pol4._shown.has(Vector2i(200, 0))
	check(disk_restored and off_skips_disk,
		"pollution: Zstd disk cache restores near+far chunks on configure() and --smog-cache=off skips disk load (%s %s)" % [disk_restored, off_skips_disk])
	remove_child(pol2)
	pol2.free()
	remove_child(pol3)
	pol3.free()
	remove_child(pol4)
	pol4.free()
	SafeDeleteScript.remove_tree(ProjectSettings.globalize_path(pol_dir))
	sky_node.queue_free()
	cam.queue_free()

	# The sun's map under soft shadows: the quality's own by default (the owner: 4096 stair-stepped the edges
	# close up), at most 4096 with --soft-shadow-atlas=4096 (measured: 1.5 ms less at Ultra under the look).
	var cap_was := SunShadows.soft_atlas_cap
	SunShadows.soft_atlas_cap = 0
	var off: int = SunShadows.atlas_for(SunShadows.QUALITY["ultra"], 1.4)
	SunShadows.soft_atlas_cap = 4096
	var soft: int = SunShadows.atlas_for(SunShadows.QUALITY["ultra"], 1.4)
	var hard: int = SunShadows.atlas_for(SunShadows.QUALITY["ultra"], 0.0)
	var low: int = SunShadows.atlas_for(SunShadows.QUALITY["low"], 1.4)
	SunShadows.soft_atlas_cap = cap_was
	check(cap_was == 0 and off == 8192 and soft == 4096 and hard == 8192 and low == 2048,
		"sun shadows: Ultra's 8192 map under soft shadows by default, 4096 with --soft-shadow-atlas=4096 (%d; %d %d %d %d)" % [cap_was, off, soft, hard, low])

	# Look passes first among what shares their priority (a Looks node outside the tree: the game's
	# stays the active one).
	var looks: Node3D = LooksScript.new()
	var probe := Shader.new()
	probe.code = "shader_type spatial;\nvoid fragment() {\n\tALBEDO = vec3(1.0);\n}\n"
	var pass_node: MeshInstance3D = looks._make_pass({"shader": probe}, "ui-test")
	check(pass_node != null and pass_node.material_override.render_priority == -128 and pass_node.sorting_offset < -10000.0,
		"look passes: the first at -128, drawn before the ground clutter sharing that priority, wherever the camera is")
	looks.free()


## The sections `--only=` asks for, or none.
