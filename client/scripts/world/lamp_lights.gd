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

## Factorio's lamps come on spread between these two (the lamp prototype's
## darkness_for_all_lamps_off and _on): each at its own point.
const ON_DARKNESS := 0.3
const ALL_ON_DARKNESS := 0.5
const MAX_LIGHTS := 48
const MAX_BULBS := 4096
## Full detail (full_detail.gd, a screenshot): every lit lamp up to these, with a real light each.
## FULL_LIGHTS stays under Godot's clustered limit (rendering/limits/cluster_builder/max_clustered_elements,
## 512 lights, decals and probes in view) with room for the rest.
const FULL_LIGHTS := 448
const FULL_BULBS := 65536
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
## Additive, a little over white: the glass reads lit and the glow blooms a little.
const GLOW_COLOR := Color(1.5, 1.4, 1.15)
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
## N6 (owner: "a larger radius of light, maybe double"): range 14 with a gentler fall-off
## (attenuation 0.5) lights the ground to about 11 tiles at a tenth of the lamp's foot, twice the old
## 7 at Godot's inverse-distance fall-off (about 5 tiles). Factorio's small lamp (light size 40,
## light-medium.png) is near full to 8 tiles, half at 11, a tenth at 16: ours keeps nearer the lamp
## brighter than the far edge, as a 3D light seen up close should. `--lamp-radius=old`: 7 and 1.0.
const LIGHT_RANGE := 14.0
const LIGHT_ATTENUATION := 0.5
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
var _bulbs: MultiMeshInstance3D
## Where each glow drawn is centred (the lamp's glass), nearest the focus first, and its instance
## colour (white, dimmer at low power, or the lamp's own colour).
var _spots := PackedVector3Array()
var _tints := PackedColorArray()
var _timer := 0.0
var _lit := 0
## The lamps in each chunk (unit numbers), found again when a chunk's entities change: going
## through every machine's working state for the lamps among them took ~4 ms twice a second at night
## on the owner's save.
var _lamps := {}  # chunk -> Array of units
var _is_lamp := {}  # proto id -> bool


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
	_add_lights(MAX_LIGHTS)
	if world != null and world.has_signal("entities_changed"):
		world.entities_changed.connect(_on_entities_changed)


## `--lamp-radius=old`: the lights' reach before N6.
static func old_radius() -> bool:
	for arg in OS.get_cmdline_user_args():
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
		light.light_energy = 1.6
		light.omni_range = light_range
		light.omni_attenuation = attenuation
		light.visible = false
		add_child(light)
		_lights.append(light)


## Every lit lamp lit and with a light (a screenshot), or back to the nearest MAX_LIGHTS. Refreshed
## on the next frame; the lights made for it stay, hidden, for the next shot.
func set_full_detail(on: bool) -> void:
	max_lights = FULL_LIGHTS if on else MAX_LIGHTS
	max_bulbs = FULL_BULBS if on else MAX_BULBS
	_add_lights(max_lights)
	_timer = REFRESH
	refreshed = false


func _on_entities_changed(c: Vector2i) -> void:
	var cv = world.chunks.get(c)
	if cv == null:
		_lamps.erase(c)
		return
	var units: Array = []
	for rec in cv.entities.values():
		var lamp = _is_lamp.get(rec.proto_id)
		if lamp == null:
			var proto: ProtoDB.EntityProto = protos.entity(rec.proto_id) if protos != null else null
			lamp = proto != null and proto.type == "lamp"
			_is_lamp[rec.proto_id] = lamp
		if lamp:
			units.append(rec.unit)
	if units.is_empty():
		_lamps.erase(c)
	else:
		_lamps[c] = units


func lit_count() -> int:
	return _lit


## How dark it must be before this lamp comes on: a point of its own between ON_DARKNESS and
## ALL_ON_DARKNESS, the same every time (unit numbers run in order; the golden ratio scatters them).
static func on_at(unit: int) -> float:
	return lerpf(ON_DARKNESS, ALL_ON_DARKNESS, fposmod(float(unit) * 0.6180339887, 1.0))


## Adds the lamp to those lit this refresh when the game says it works, it has power, it is in view of
## the remote view's radars, and its colour isn't black.
func _light_up(unit: int, lit: Array[Vector2], dim: Dictionary, colored: Dictionary) -> void:
	if int(world.working.get(unit, 0)) != 1:
		return
	var rec = world.entities.get(unit)
	if rec == null or (fog != null and not fog.seen(rec.pos)):
		return
	if power != null and power.has_no_power(unit):
		return
	var rgb := int(world.lamp_colors.get(unit, -1))
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
	if world != null and protos != null:
		var always: Dictionary = world.lamp_always
		if darkness >= ON_DARKNESS:
			for c in _lamps.keys():
				if not world.chunks.has(c):
					_lamps.erase(c)
					continue
				for unit in _lamps[c]:
					if darkness >= on_at(unit) or always.has(unit):
						_light_up(unit, lit, dim, colored)
		else:
			# By day only lamps set to Always on can be lit (K20): just those, not every lamp.
			for unit in always.keys():
				_light_up(unit, lit, dim, colored)
	# Full from dusk on; an always-on lamp in daylight glows dimmer, its light faint (K20).
	var night := clampf(darkness / ON_DARKNESS, 0.0, 1.0)
	var glow_share := lerpf(DAY_GLOW, 1.0, night)
	var light_share := lerpf(DAY_LIGHT, 1.0, night)
	var near := func(a: Vector2, b: Vector2) -> bool:
		return a.distance_squared_to(focus) < b.distance_squared_to(focus)
	lit.sort_custom(near)
	_lit = mini(lit.size(), max_bulbs)
	var mm := _bulbs.multimesh
	if mm.instance_count < _lit:
		mm.instance_count = maxi(_lit, mm.instance_count * 2)
	mm.visible_instance_count = _lit
	# The glow and the light are placed here, on the CPU, so the hills' lift (done in the shaders for
	# the lamp's model and the ground) is added here, once: at the flat height they sat inside the
	# raised ground, every lamp on a hill dark at night (J19). Heights read again each refresh, as
	# the add-on's field changes (0 at once while the ground is flat).
	_spots.resize(_lit)
	_tints.resize(_lit)
	for i in _lit:
		_spots[i] = Vector3(lit[i].x, GLASS_HEIGHT + GroundHeight.at(lit[i].x, lit[i].y), lit[i].y)
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, _spots[i]))
		var tint: Color = glow_tint(colored[lit[i]]) if colored.has(lit[i]) else Color.WHITE
		if dim.has(lit[i]):
			tint *= DIM_GLOW
		# (Colour only: the card's alpha stays, so the glow is added at the share asked.)
		_tints[i] = Color(tint.r * glow_share, tint.g * glow_share, tint.b * glow_share, tint.a)
		mm.set_instance_color(i, _tints[i])
	refreshed = true
	for i in _lights.size():
		var light := _lights[i]
		light.visible = i < _lit and i < max_lights
		if light.visible:
			light.position = _spots[i] + Vector3(0.0, LIGHT_HEIGHT - GLASS_HEIGHT, 0.0)
			light.light_energy = (0.7 if dim.has(lit[i]) else 1.6) * light_share
			var own: bool = colored.has(lit[i])
			light.light_color = colored[lit[i]] if own else LIGHT_COLOR
			light.omni_range = colored_range if own else light_range
