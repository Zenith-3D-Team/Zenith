extends Node3D
## Lamps at night. A lamp is lit when the mod reports it working (it has power) and it is dark
## enough, like Factorio's lamps; one the mod reports without power (`pw`) stays dark even if its
## working state is stale, and at low power it glows dimmer. Every lit lamp's glass glows as
## Factorio draws a lit lamp: its light picture (picture_on, small-lamp/lamp-light.png from the
## install) over the lamp, a glow on a card facing the camera (K5: the white ball 0.8 tiles up sat
## over the model's 0.6-tile head, which stayed dark); only the ones nearest the camera get a real
## light, just over the head, so it lights the lamp itself and the ground round it, since each light
## costs rendering time. On an add-on's hills (ground_height.gd) the glows and lights are lifted with
## the ground, as the lamps' models are in their shader. K10: a lamp its circuit network or its window
## colours (the bridge's `st` `lc`, world.lamp_colors) glows and lights in that colour, as Factorio
## tints its picture_on and light; a white one keeps the warm look. K20: a lamp set to Always on (`st`
## `ao`, world.lamp_always) is lit by day too while the game says it works. By day Factorio draws it
## with its picture_on as it is, and its light shows little against the daylight, so the glow is
## dimmer (it is added over a sunlit lamp) and the light faint; from dusk both are as at night. Plain
## lamps keep waiting for the dark: the game turns them off by day, and one whose state isn't heard
## any more (out of the bridge's square) must not stay lit into the day.

const ProtoDB := preload("res://scripts/world/protos.gd")
const FluidsPower := preload("res://scripts/world/fluids_power.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const ViewPriority := preload("res://scripts/world/view_priority.gd")

## Factorio's lamps come on spread between these two (the lamp prototype's
## darkness_for_all_lamps_off and _on): each at its own point.
const ON_DARKNESS := 0.3
const ALL_ON_DARKNESS := 0.5
const MAX_LIGHTS := 48
const MAX_BULBS := 8192
## Full detail (full_detail.gd, a screenshot): every lit lamp up to these, with a real light each.
## FULL_LIGHTS stays under Godot's clustered limit (rendering/limits/cluster_builder/max_clustered_elements,
## 1024 lights, decals and probes in view) with room for the rest.
const FULL_LIGHTS := 448
const FULL_BULBS := 65536
const SPLAT_SHADER := preload("res://shaders/lamp_lightmap_splat.gdshader")
const Switches := preload("res://scripts/switches.gd")
const GLOBAL_TEX := &"f3d_lamp_light"
const GLOBAL_RECT := &"f3d_lamp_light_rect"
const LIGHTMAP_SIZE := 512
const LIGHTMAP_RECENTRE := 64.0
const LIGHTMAP_GAIN := 0.95
const LIGHT_ENERGY := 0.9
const DIM_LIGHT_ENERGY := 0.4
const FAR_LIGHT_RANGE := 22.0
const FAR_COLORED_RANGE := 12.0
const NEAR_GROUND_GAIN := 0.55
## Detail light budget & reach scaled from far_chunks.detail_distance() by Settings > Graphics > Level of detail.
const LOD_TIERS := {"low": [0.65, 64], "medium": [1.0, 128], "high": [1.35, 224], "ultra": [1.65, 288]}
const DETAIL_DIST_MIN := 32.0
const DETAIL_DIST_MAX := 280.0
const FADE_FRAC := 0.25
## `--far-lights=old`: keep the fixed 48 real lights around focus with no LOD scaling or far lightmap.
static var legacy_lights := Switches.has("--far-lights=old")
static var _black_tex: ImageTexture
## The lamp's glass (its models' heads reach 0.6 tiles), where the glow is centred, and the light
## just over the head: the head's top and the ground round the lamp face it.
const GLASS_HEIGHT := 0.45
const LIGHT_HEIGHT := 0.9
## Factorio's lamp-light.png: 90 x 78 pixels at scale 0.5 (1.4 x 1.2 tiles), its glow 9 pixels below
## the picture's middle: the card is raised that much, so the glow is centred on the glass.
const GLOW_SIZE := Vector2(90.0, 78.0) / 64.0
const GLOW_RAISE := 9.0 / 64.0
## The card is drawn this far towards the camera, in front of the lamp's own head, which would hide
## the glow's middle (Factorio draws the picture over the sprite); buildings in front still hide it.
const GLOW_FORWARD := 0.45
## Additive, slightly warm: the glass reads lit without excessive glare.
const GLOW_COLOR := Color(1.05, 0.98, 0.82)
## A lamp at low power, as its light (0.7 of 1.6).
const DIM_GLOW := Color(0.45, 0.45, 0.45)
## An always-on lamp in full daylight (K20): its glow's share (the card adds to the sunlit lamp, where
## Factorio lays its white picture over it: the glass reads lit without blooming) and its light's (it
## shows little by day in Factorio). Both rise to 1 as the darkness reaches ON_DARKNESS.
const DAY_GLOW := 0.3
const DAY_LIGHT := 0.15
const REFRESH := 0.5
## A white lamp's light, warm as Factorio's lit lamps look at night.
const LIGHT_COLOR := Color(1.0, 0.86, 0.6)
## N6 (owner: "a larger radius of light, maybe double"): range 18 with a gentler fall-off
## (attenuation 0.42) lights the ground wider around every lamp, and the 2D lightmap extends the
## outer ground pool out to 22 tiles like Factorio's 40-tile lamp pool. `--lamp-radius=old`: 7 and 1.0.
const LIGHT_RANGE := 18.0
const LIGHT_ATTENUATION := 0.42
const OLD_LIGHT_RANGE := 7.0
const OLD_ATTENUATION := 1.0
## A coloured lamp's light reaches less far: Factorio draws it with light_when_colored (no light in the
## small lamp's prototype) and a coloured glow 6 tiles across, where the white light is 40. The same
## share of the white light's range as before (4 of 7).
const COLORED_RANGE := LIGHT_RANGE * 4.0 / 7.0
const OLD_COLORED_RANGE := 4.0

var protos: ProtoDB
## The world mirror: entities and machine working states.
var world: Node3D
## 0 in daylight, ~0.85 at night. Set by main from the `sky` messages.
var darkness := 0.0
var focus := Vector2.ZERO
## fluids_power.gd, for machines short of power (optional).
var power: Node
## The remote view's fog (remote_fog.gd): lamps no radar sees stay dark under it (G18).
var fog: Node
## LOD detail distance source (world.far_chunks), WorkingGlow layer, and SignalLights layer.
var far_chunks: Node
var working_glow: Node
var signal_lights: Node
var far_lights_enabled := not legacy_lights

var _lights: Array[OmniLight3D] = []
## The lights' reach (N6, or the old one with `--lamp-radius=old`).
var light_range := LIGHT_RANGE
var colored_range := COLORED_RANGE
var attenuation := LIGHT_ATTENUATION
## Lamps given real lights, and glows ("bulbs") drawn (full_detail.gd raises both, then puts them back).
var max_lights := MAX_LIGHTS
var max_bulbs := MAX_BULBS
## Refreshed since full detail came on or off (full_detail.gd's settle check).
var refreshed := true
var _lod_quality := ""
var _custom_lod_distance := 0.0
var _base_max_lights := MAX_LIGHTS
var _full_detail := false
var _detail_distance := DETAIL_DIST_MIN
var _bulbs: MultiMeshInstance3D
## Where each glow drawn is centred (the lamp's glass), nearest the focus first, and its instance
## colour (white, dimmer at low power, or the lamp's own colour).
var _spots := PackedVector3Array()
var _tints := PackedColorArray()
var _real_weights := PackedFloat32Array()
var _height_cache := {}  # Vector2 -> float
var _height_ver := -1
var _bulb_buf := PackedFloat32Array()
var _timer := 0.0
var _lit := 0
## The lamps in each chunk (unit numbers), found again when a chunk's entities change: going
## through every machine's working state for the lamps among them took ~4 ms twice a second at night
## on the owner's save.
var _lamps := {}  # chunk -> Array of units
var _is_lamp := {}  # proto id -> bool
var _hint_always := {}  # unit -> true for loaded distant lamps carrying `(extra.lp & 2) != 0`
var _chunk_always := {}  # chunk -> Array of units in `_hint_always`
var _map_vp: SubViewport
var _map_splats: MultiMeshInstance2D
var _map_origin := Vector2.ZERO
var _map_step := 2.0
var _map_active := false
var _map_splat_count := 0
var _map_tex_bound := false


func _ready() -> void:
	if old_radius():
		light_range = OLD_LIGHT_RANGE
		colored_range = OLD_COLORED_RANGE
		attenuation = OLD_ATTENUATION
	var quad := QuadMesh.new()
	quad.size = GLOW_SIZE
	quad.center_offset = Vector3(0.0, GLOW_RAISE, 0.0)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	# The quad's normal faces the camera once it is a billboard: growing along it brings it forward.
	m.grow = true
	m.grow_amount = GLOW_FORWARD
	m.albedo_color = GLOW_COLOR
	m.albedo_texture = glow_texture()
	m.vertex_color_use_as_albedo = true  # each lamp's instance colour: dimmer at low power
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = quad
	mm.instance_count = 0
	_bulbs = MultiMeshInstance3D.new()
	_bulbs.name = "LampGlows"
	_bulbs.multimesh = mm
	_bulbs.material_override = m
	_bulbs.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_bulbs)
	_setup_lightmap()
	_add_lights(MAX_LIGHTS)
	if world != null and world.has_signal("entities_changed"):
		world.entities_changed.connect(_on_entities_changed)


func _exit_tree() -> void:
	_height_cache.clear()
	_clear_lightmap_global()
	if _map_tex_bound:
		RenderingServer.global_shader_parameter_set(GLOBAL_TEX, _ensure_black_tex())
		_map_tex_bound = false


static func _ensure_black_tex() -> ImageTexture:
	if _black_tex == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.0, 0.0, 0.0, 1.0))
		_black_tex = ImageTexture.create_from_image(img)
	return _black_tex


func _setup_lightmap() -> void:
	_map_vp = SubViewport.new()
	_map_vp.name = "FarLightmap"
	_map_vp.disable_3d = true
	_map_vp.transparent_bg = true
	_map_vp.use_hdr_2d = true
	_map_vp.size = Vector2i(LIGHTMAP_SIZE, LIGHTMAP_SIZE)
	_map_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_map_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_map_vp)
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	var mat := ShaderMaterial.new()
	mat.shader = SPLAT_SHADER
	mat.set_shader_parameter("atten_power", attenuation)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = 0
	_map_splats = MultiMeshInstance2D.new()
	_map_splats.name = "FarSplats"
	_map_splats.multimesh = mm
	_map_splats.material = mat
	_map_vp.add_child(_map_splats)
	RenderingServer.global_shader_parameter_set(GLOBAL_TEX, _map_vp.get_texture())
	_map_tex_bound = true
	_clear_lightmap_global()


func _clear_lightmap_global() -> void:
	_map_active = false
	_map_splat_count = 0
	if _map_splats != null and _map_splats.multimesh != null:
		_map_splats.multimesh.visible_instance_count = 0
	RenderingServer.global_shader_parameter_set(GLOBAL_RECT, Vector4(_map_origin.x, _map_origin.y, _map_step, 0.0))


## `--lamp-radius=old`: the lights' reach before N6.
static func old_radius() -> bool:
	for arg in Switches.args():
		if arg == "--lamp-radius=old":
			return true
	return false


## Factorio's lit lamp's picture (its light in alpha), or without an install a soft round glow of
## its size, brightest on the glass.
static func glow_texture() -> Texture2D:
	var dir := ItemIcons.factorio_data_dir()
	var path := dir.path_join("base/graphics/entity/small-lamp/lamp-light.png")
	var image: Image = null
	if dir != "" and FileAccess.file_exists(path):
		image = Image.load_from_file(path)
	if image == null or image.is_empty():
		image = Image.create(90, 78, false, Image.FORMAT_LA8)
		for y in 78:
			for x in 90:
				var d := Vector2((x - 45.0) / 30.0, (y - 48.0) / 22.0).length()
				var a := clampf(1.0 - d, 0.0, 1.0)
				image.set_pixel(x, y, Color(1.0, 1.0, 1.0, a * a))
	image.convert(Image.FORMAT_RGBA8)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


## 0xRRGGBB (the bridge's `lc`) as a colour.
static func rgb_color(rgb: int) -> Color:
	return Color8((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255)


## The glow card's instance colour for a lamp showing `c`: the card's albedo (GLOW_COLOR) multiplies it
## in linear light, so each channel's share of it is taken out again, and the coloured glow is as bright
## as the white one's brightest channel.
static func glow_tint(c: Color) -> Color:
	var g := GLOW_COLOR.srgb_to_linear()
	var l := c.srgb_to_linear()
	return Color(l.r, l.g * g.r / g.g, l.b * g.r / g.b)


func _add_lights(n: int) -> void:
	while _lights.size() < n:
		var light := OmniLight3D.new()
		light.light_color = LIGHT_COLOR
		light.light_energy = LIGHT_ENERGY
		light.omni_range = light_range
		light.omni_attenuation = attenuation
		light.visible = false
		add_child(light)
		_lights.append(light)


## Smooth 1->0 cross-fade between `lo` and `hi` tiles without edge discontinuities.
static func smooth_fade(lo: float, hi: float, d: float) -> float:
	if d <= lo:
		return 1.0
	if d >= hi or hi <= lo:
		return 0.0
	var t := (d - lo) / (hi - lo)
	return 1.0 - t * t * (3.0 - 2.0 * t)


## Camera frustum planes oriented so `(sign * p.distance_to(pt)) <= margin` holds inside view.
static func frustum_context(cam: Camera3D) -> Dictionary:
	if cam == null or not cam.is_inside_tree():
		return {}
	var raw: Array[Plane] = cam.get_frustum()
	if raw.size() != 6:
		return {}
	var depth := clampf(cam.near + 2.0, 0.5, maxf(cam.far * 0.5, 1.0))
	var xf := cam.global_transform
	var ahead := xf.origin - xf.basis.z * depth
	var planes: Array[Plane] = []
	var signs := PackedFloat32Array()
	for p: Plane in raw:
		if p.normal.length_squared() < 0.0001:
			continue
		planes.append(p)
		signs.append(1.0 if p.distance_to(ahead) <= 0.0 else -1.0)
	return {"planes": planes, "signs": signs}


static func in_frustum(ctx: Dictionary, pt: Vector3, margin: float) -> bool:
	if ctx.is_empty():
		return true
	var planes: Array = ctx["planes"]
	var signs: PackedFloat32Array = ctx["signs"]
	for i in planes.size():
		var p: Plane = planes[i]
		if signs[i] * p.distance_to(pt) > margin:
			return false
	return true


func apply_lod_quality(quality: String, custom_distance := 0.0) -> void:
	_lod_quality = quality
	_custom_lod_distance = maxf(custom_distance, 0.0)
	if legacy_lights:
		_base_max_lights = MAX_LIGHTS
	else:
		var tier: Array = LOD_TIERS.get(quality, LOD_TIERS["medium"])
		_base_max_lights = int(tier[1])
	if not _full_detail:
		max_lights = _base_max_lights
		_add_lights(max_lights)
		_timer = REFRESH


func set_far_lights_enabled(on: bool) -> void:
	far_lights_enabled = on and not legacy_lights
	if not far_lights_enabled:
		_clear_lightmap_global()
	_timer = REFRESH


func _compute_detail_distance() -> float:
	if _full_detail or legacy_lights or _lod_quality == "":
		return DETAIL_DIST_MIN if _lod_quality == "" and not _full_detail and not legacy_lights else INF
	var ref_d := 128.0 * clampf(_custom_lod_distance / 48.0, 0.25, 3.0) if _custom_lod_distance > 0.0 else 128.0
	if far_chunks != null and far_chunks.has_method("detail_distance"):
		var fd := float(far_chunks.call("detail_distance"))
		if fd > 0.0:
			ref_d = fd
	var scale := 1.0
	if _custom_lod_distance <= 0.0:
		var tier: Array = LOD_TIERS.get(_lod_quality, LOD_TIERS["medium"])
		scale = float(tier[0])
	return clampf(ref_d * scale, DETAIL_DIST_MIN, DETAIL_DIST_MAX)


## Every lit lamp lit and with a light (a screenshot), or back to the nearest LOD cap. Refreshed
## on the next frame; the lights made for it stay, hidden, for the next shot.
func set_full_detail(on: bool) -> void:
	_full_detail = on
	max_lights = FULL_LIGHTS if on else _base_max_lights
	max_bulbs = FULL_BULBS if on else MAX_BULBS
	_add_lights(max_lights)
	_timer = REFRESH
	refreshed = false


func _on_entities_changed(c: Vector2i) -> void:
	var old_always: Variant = _chunk_always.get(c)
	if old_always is Array:
		for u in old_always as Array:
			_hint_always.erase(int(u))
	_chunk_always.erase(c)
	var cv = world.chunks.get(c)
	if cv == null:
		_lamps.erase(c)
		return
	var units: Array = []
	var always_units: Array = []
	for rec in cv.entities.values():
		var lamp = _is_lamp.get(rec.proto_id)
		if lamp == null:
			var proto: ProtoDB.EntityProto = protos.entity(rec.proto_id) if protos != null else null
			lamp = proto != null and proto.type == "lamp"
			_is_lamp[rec.proto_id] = lamp
		if lamp:
			units.append(rec.unit)
			if (int(rec.extra.get("lp", 0)) & 2) != 0:
				always_units.append(rec.unit)
				_hint_always[rec.unit] = true
	if units.is_empty():
		_lamps.erase(c)
	else:
		_lamps[c] = units
	if not always_units.is_empty():
		_chunk_always[c] = always_units


func lit_count() -> int:
	return _lit


## How dark it must be before this lamp comes on: a point of its own between ON_DARKNESS and
## ALL_ON_DARKNESS, the same every time (unit numbers run in order; the golden ratio scatters them).
static func on_at(unit: int) -> float:
	return lerpf(ON_DARKNESS, ALL_ON_DARKNESS, fposmod(float(unit) * 0.6180339887, 1.0))


## Adds the lamp to those lit this refresh when the game says it works (or its snapshot hint says
## powered outside `focus.r`), it has power, it is in view of the remote view's radars, and its
## colour isn't black.
func _light_up(unit: int, lit: Array[Vector2], dim: Dictionary, colored: Dictionary, night_ok: bool, check_fog := false) -> void:
	var rec = world.entities.get(unit)
	if rec == null or (check_fog and not fog.seen(rec.pos)):
		return
	if power != null and power.has_no_power(unit):
		return
	var rgb := -1
	if world.working.has(unit):
		if int(world.working[unit]) != 1:
			return
		rgb = int(world.lamp_colors.get(unit, -1))
	else:
		var lp := int(rec.extra.get("lp", 0))
		if lp <= 0 or (not night_ok and (lp & 2) == 0):
			return
		rgb = int(rec.extra.get("lc", -1))
	if rgb == 0:
		return  # black: Factorio's lamp shows nothing
	lit.append(rec.pos)
	if rgb > 0:
		colored[rec.pos] = rgb_color(rgb)
	if power != null and power.power_state(unit) == FluidsPower.LOW_POWER:
		dim[rec.pos] = true


func _process(delta: float) -> void:
	_timer += delta
	if _timer < REFRESH:
		return
	_timer = 0.0
	var lit: Array[Vector2] = []
	var dim := {}  # positions of lamps at low power
	var colored := {}  # positions of lamps showing a colour -> that colour
	var want_far_map := far_lights_enabled and not legacy_lights and darkness > 0.01
	if world != null and protos != null:
		var always: Dictionary = world.lamp_always
		var fogging: bool = fog != null and fog.hiding()
		var work_map: Dictionary = world.working
		if darkness >= ON_DARKNESS:
			var near_only := not _full_detail and (not far_lights_enabled or legacy_lights)
			var near_chunk_d := LIGHT_RANGE + 48.0 + 22.63
			var near_chunk_d2 := near_chunk_d * near_chunk_d
			var all_on := darkness >= ALL_ON_DARKNESS
			for c in _lamps.keys():
				if not world.chunks.has(c):
					_lamps.erase(c)
					var dead_always: Variant = _chunk_always.get(c)
					if dead_always is Array:
						for u in dead_always as Array:
							_hint_always.erase(int(u))
					_chunk_always.erase(c)
					continue
				if near_only or fogging:
					var cc := Vector2(c) * 32.0 + Vector2(16.0, 16.0)
					if near_only and cc.distance_squared_to(focus) > near_chunk_d2:
						continue
					if fogging and not fog.seen(cc):
						continue
				for unit_var in _lamps[c]:
					var unit := int(unit_var)
					var night_ok := all_on or darkness >= on_at(unit)
					if night_ok or always.has(unit) or (not work_map.has(unit) and _hint_always.has(unit)):
						_light_up(unit, lit, dim, colored, night_ok, false)
		else:
			# By day only lamps set to Always on can be lit (K20): live `ao` plus distant snapshot hints.
			var seen_always := {}
			for unit_var in always.keys():
				var u := int(unit_var)
				seen_always[u] = true
				_light_up(u, lit, dim, colored, false, fogging)
			for unit_var in _hint_always.keys():
				var u := int(unit_var)
				if seen_always.has(u) or work_map.has(u):
					continue
				if world.entities.get(u) == null:
					_hint_always.erase(u)
					continue
				_light_up(u, lit, dim, colored, false, fogging)
	# Full from dusk on; an always-on lamp in daylight glows dimmer, its light faint (K20).
	var night := clampf(darkness / ON_DARKNESS, 0.0, 1.0)
	var glow_share := lerpf(DAY_GLOW, 1.0, night)
	var light_share := lerpf(DAY_LIGHT, 1.0, night)
	_detail_distance = _compute_detail_distance()
	var cam := get_viewport().get_camera_3d() if is_inside_tree() and get_viewport() != null else null
	var use_frustum := not legacy_lights and not _full_detail and cam != null
	var fctx := frustum_context(cam) if use_frustum else {}
	var near_ordered: Array = []  # [pos, dist_sq, bucket]
	var far_ordered: Array = []
	var det2 := _detail_distance * _detail_distance
	if use_frustum and not fctx.is_empty():
		var hr := GroundHeight.lift_range()
		var margin := LIGHT_RANGE + absf(hr.y - hr.x) + 4.0
		var near2 := 36.0 if ViewPriority.tight_cull else LIGHT_RANGE * LIGHT_RANGE * 4.0
		for p: Vector2 in lit:
			var d2 := p.distance_squared_to(focus)
			if d2 <= det2:
				var vis := d2 <= near2 or in_frustum(fctx, Vector3(p.x, LIGHT_HEIGHT, p.y), margin)
				near_ordered.append([p, d2, 0 if vis else 1])
			else:
				far_ordered.append([p, d2, 2])
		var cmp_frustum := func(a: Array, b: Array) -> bool:
			var ba: int = int(a[2])
			var bb: int = int(b[2])
			if ba != bb:
				return ba < bb
			return float(a[1]) < float(b[1])
		near_ordered.sort_custom(cmp_frustum)
		if not far_ordered.is_empty() and near_ordered.size() + far_ordered.size() > max_bulbs:
			for fe_var in far_ordered:
				var fe: Array = fe_var
				var fp: Vector2 = fe[0]
				if not in_frustum(fctx, Vector3(fp.x, LIGHT_HEIGHT, fp.y), margin):
					fe[2] = 3
			far_ordered.sort_custom(cmp_frustum)
	else:
		for p: Vector2 in lit:
			var d2 := p.distance_squared_to(focus)
			if d2 <= det2:
				near_ordered.append([p, d2, 0])
			else:
				far_ordered.append([p, d2, 2])
		var cmp_dist := func(a: Array, b: Array) -> bool:
			return float(a[1]) < float(b[1])
		near_ordered.sort_custom(cmp_dist)
		if not far_ordered.is_empty() and near_ordered.size() + far_ordered.size() > max_bulbs:
			far_ordered.sort_custom(cmp_dist)
	var ordered: Array = near_ordered
	if not far_ordered.is_empty():
		ordered.append_array(far_ordered)
	var total := ordered.size()
	lit.resize(total)
	for i in total:
		lit[i] = ordered[i][0]
	_lit = mini(total, max_bulbs)
	var mm := _bulbs.multimesh
	var hills := GroundHeight.version()
	if hills != _height_ver or _height_cache.size() > 16384:
		_height_cache.clear()
		_height_ver = hills
	# The glow and the light are placed here, on the CPU, so the hills' lift (done in the shaders for
	# the lamp's model and the ground) is added here, once: at the flat height they sat inside the
	# raised ground, every lamp on a hill dark at night (J19). Heights read again each refresh when
	# GroundHeight.version() changes (0 at once while the ground is flat).
	_spots.resize(_lit)
	_tints.resize(_lit)
	_real_weights.resize(_lit)
	if _lit > 0:
		if mm.instance_count < _lit:
			mm.instance_count = maxi(_lit, mm.instance_count * 2)
		var need_floats := mm.instance_count * 16
		if _bulb_buf.size() != need_floats:
			_bulb_buf.resize(need_floats)
		var min_v := Vector3(INF, INF, INF)
		var max_v := Vector3(-INF, -INF, -INF)
		for i in _lit:
			var pos := lit[i]
			var gh: float = _height_cache.get(pos, NAN)
			if is_nan(gh):
				gh = GroundHeight.at(pos.x, pos.y)
				_height_cache[pos] = gh
			var wpos := Vector3(pos.x, GLASS_HEIGHT + gh, pos.y)
			_spots[i] = wpos
			var tint: Color = glow_tint(colored[pos]) if colored.has(pos) else Color.WHITE
			if dim.has(pos):
				tint *= DIM_GLOW
			# (Colour only: the card's alpha stays, so the glow is added at the share asked.)
			var c_out := Color(tint.r * glow_share, tint.g * glow_share, tint.b * glow_share, tint.a)
			_tints[i] = c_out
			_real_weights[i] = 0.0
			var o := i * 16
			_bulb_buf[o] = 1.0
			_bulb_buf[o + 1] = 0.0
			_bulb_buf[o + 2] = 0.0
			_bulb_buf[o + 3] = wpos.x
			_bulb_buf[o + 4] = 0.0
			_bulb_buf[o + 5] = 1.0
			_bulb_buf[o + 6] = 0.0
			_bulb_buf[o + 7] = wpos.y
			_bulb_buf[o + 8] = 0.0
			_bulb_buf[o + 9] = 0.0
			_bulb_buf[o + 10] = 1.0
			_bulb_buf[o + 11] = wpos.z
			_bulb_buf[o + 12] = c_out.r
			_bulb_buf[o + 13] = c_out.g
			_bulb_buf[o + 14] = c_out.b
			_bulb_buf[o + 15] = c_out.a
			min_v = min_v.min(wpos)
			max_v = max_v.max(wpos)
		mm.buffer = _bulb_buf
		mm.custom_aabb = AABB(min_v - Vector3(2.0, 2.0, 2.0), (max_v - min_v) + Vector3(4.0, 4.0, 4.0))
	else:
		mm.custom_aabb = AABB()
	mm.visible_instance_count = _lit
	refreshed = true
	# Determine fade cutoff for in-view detailed lights if max_lights saturated inside _detail_distance.
	var in_view_cut := _detail_distance
	if not legacy_lights and not _full_detail and far_lights_enabled and _lit > max_lights and max_lights > 0:
		var last_idx := mini(_lit, max_lights) - 1
		if int((ordered[last_idx] as Array)[2]) == 0 and int((ordered[max_lights] as Array)[2]) == 0:
			in_view_cut = minf(_detail_distance, maxf(sqrt(float((ordered[last_idx] as Array)[1])), 16.0))
	var max_bucket := 0 if (ViewPriority.tight_cull and not _full_detail and not legacy_lights) else 1
	for i in _lights.size():
		var light := _lights[i]
		var eligible := i < _lit and i < max_lights and (_full_detail or legacy_lights or int((ordered[i] as Array)[2]) <= max_bucket)
		if not eligible:
			light.visible = false
			continue
		var pos := lit[i]
		var lamp_energy := DIM_LIGHT_ENERGY if dim.has(pos) else LIGHT_ENERGY
		var base_energy := lamp_energy * light_share
		var real_weight := 1.0
		if far_lights_enabled and not legacy_lights and not _full_detail:
			var dist := sqrt(float((ordered[i] as Array)[1]))
			var cut := in_view_cut if int((ordered[i] as Array)[2]) == 0 else _detail_distance
			real_weight = smooth_fade(cut * (1.0 - FADE_FRAC), cut, dist)
		if real_weight <= 0.01:
			light.visible = false
			_real_weights[i] = 0.0
			continue
		_real_weights[i] = real_weight
		light.visible = true
		light.position = _spots[i] + Vector3(0.0, LIGHT_HEIGHT - GLASS_HEIGHT, 0.0)
		light.light_energy = base_energy * real_weight
		var own: bool = colored.has(pos)
		light.light_color = colored[pos] if own else LIGHT_COLOR
		light.omni_range = colored_range if own else light_range
	if want_far_map:
		_update_lightmap(lit, dim, colored, light_share)
	elif _map_active or _map_splat_count != 0:
		_clear_lightmap_global()


func _update_lightmap(lit: Array[Vector2], dim: Dictionary, colored: Dictionary, light_share: float) -> void:
	if _map_vp == null or _map_splats == null or not far_lights_enabled or legacy_lights or darkness <= 0.01:
		if _map_active or _map_splat_count != 0:
			_clear_lightmap_global()
		return
	var splats: Array = []  # [pos Vector2, lin_rgb Color, signed_range float]
	var white_lin := LIGHT_COLOR.srgb_to_linear()
	var use_old := old_radius()
	var far_white_rng := light_range if use_old else FAR_LIGHT_RANGE
	var far_col_rng := colored_range if use_old else FAR_COLORED_RANGE
	for i in _lit:
		var pos := lit[i]
		var rw: float = _real_weights[i]
		var fw := 1.0 - rw
		var own := colored.has(pos)
		var lin_col := (colored[pos] as Color).srgb_to_linear() if own else white_lin
		var rng := far_col_rng if own else far_white_rng
		var lamp_energy := DIM_LIGHT_ENERGY if dim.has(pos) else LIGHT_ENERGY
		if fw > 0.01:
			var e := lamp_energy * light_share * fw * LIGHTMAP_GAIN
			if e > 0.005:
				splats.append([pos, Color(lin_col.r * e, lin_col.g * e, lin_col.b * e, 1.0), rng])
		if rw > 0.01:
			var near_e := lamp_energy * light_share * rw * NEAR_GROUND_GAIN
			if near_e > 0.005:
				splats.append([pos, Color(lin_col.r * near_e, lin_col.g * near_e, lin_col.b * near_e, 1.0), -rng])
	for src: Node in [working_glow, signal_lights]:
		if src == null or not src.has_method("far_glows"):
			continue
		var extra_glows: Variant = src.call("far_glows")
		if extra_glows is Array:
			for g_var in extra_glows as Array:
				if not (g_var is Array):
					continue
				var g: Array = g_var
				if g.size() < 4:
					continue
				var e := float(g[2]) * LIGHTMAP_GAIN
				if e <= 0.005:
					continue
				var gc := (g[1] as Color).srgb_to_linear()
				splats.append([g[0], Color(gc.r * e, gc.g * e, gc.b * e, 1.0), float(g[3])])
	if splats.is_empty():
		_clear_lightmap_global()
		return
	var vr := int(world.get("view_radius")) if world != null and world.get("view_radius") != null else 10
	var want_step := 2.0 if vr <= 14 else (4.0 if vr <= 30 else 7.0)
	var half := float(LIGHTMAP_SIZE) * want_step * 0.5
	var center := _map_origin + Vector2(half, half)
	if not _map_active or not is_equal_approx(_map_step, want_step) or focus.distance_to(center) > LIGHTMAP_RECENTRE:
		_map_step = want_step
		half = float(LIGHTMAP_SIZE) * _map_step * 0.5
		_map_origin = Vector2(
			floorf((focus.x - half) / 32.0) * 32.0,
			floorf((focus.y - half) / 32.0) * 32.0)
	var sm := _map_splats.multimesh
	var kept: Array = []
	for s_var in splats:
		var s: Array = s_var
		var pos: Vector2 = s[0]
		var signed_rng := float(s[2])
		var center_px := (pos - _map_origin) / _map_step
		var radius_px := absf(signed_rng) / _map_step
		if center_px.x + radius_px < 0.0 or center_px.x - radius_px > float(LIGHTMAP_SIZE) \
				or center_px.y + radius_px < 0.0 or center_px.y - radius_px > float(LIGHTMAP_SIZE):
			continue
		kept.append([center_px, radius_px, s[1], signed_rng])
	var count := kept.size()
	if count == 0:
		_clear_lightmap_global()
		return
	if sm.instance_count < count:
		sm.instance_count = maxi(count, sm.instance_count * 2)
	sm.visible_instance_count = count
	for i in count:
		var k: Array = kept[i]
		var cpx: Vector2 = k[0]
		var rpx: float = k[1]
		var col := k[2] as Color
		sm.set_instance_transform_2d(i, Transform2D(Vector2(rpx, 0.0), Vector2(0.0, rpx), cpx))
		sm.set_instance_custom_data(i, Color(col.r, col.g, col.b, float(k[3])))
	var mat := _map_splats.material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("atten_power", attenuation)
	_map_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	if not _map_tex_bound:
		RenderingServer.global_shader_parameter_set(GLOBAL_TEX, _map_vp.get_texture())
		_map_tex_bound = true
	RenderingServer.global_shader_parameter_set(GLOBAL_RECT, Vector4(_map_origin.x, _map_origin.y, _map_step, 1.0))
	_map_active = true
	_map_splat_count = count
