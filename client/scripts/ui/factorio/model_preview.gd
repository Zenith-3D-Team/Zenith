extends SubViewportContainer
## A model turning slowly in a world of its own (the Model packs window and the in-game model
## chooser, M7 and M8): model_library.gd's mesh and moving parts at rest, with its materials, lit
## from the upper left as Factorio's sprites are, seen from about Factorio's angle on a dark floor.
## show_model(name) takes a model name, `name@pack` for a pack's own (model_library.gd); the model
## is read on a worker like any other (ModelLibrary.ready) and shown when it is. `turning` false
## holds it still (a thumbnail).
##
## The model's shaders are the world's (factorio_material), and some of what they read is global to
## every viewport: the hills' height field (f3d_ground, Terrain Elevation) lifts each vertex by the
## height under its world position, and pollution strips trees' leaves by theirs. In this world of
## its own the model stood at the world's origin, so in a game with hills it was drawn lifted by the
## height at the spawn, over the floor and above or behind the camera (a dark shape at the top of
## the picture, seen from under it), and a small model (a belt, ore) was out of view altogether.
## Everything here stands off to one side of both fields instead (place_apart), where nothing is lifted.
##
## The light is the game's (lighting-fixes step 6): the Factorio look at noon on Nauvis (looks.gd noon_rig: its sun,
## held where Factorio's shadows fall, its ambient, the lighting environment in the sky's cubemap for ambient and
## reflections, linear tonemapping at its exposure), so a model looks here as it will in a game. `studio` (the Model
## packs window's light button; --preview-light=studio its default) gives the studio light before: a key from the
## upper left, a soft fill from the other side, a grey-blue sky in reflections, filmic tonemapping.
##
## Steady light: a fixed key light (and the studio's fill), the key's shadow one orthogonal map fitted to the
## model (not the default four cascades out to 100 tiles, whose coarse texels crawled over a small
## model as it turned), no automatic levels of detail (a level switched as the model turned popped),
## fixed exposure, and no TAA, SSAO or SSIL in this viewport. Drawn at twice the picture's size each way
## with MSAA (its shiny metal and fine edges shimmered at a thumbnail's size), each piece's weathering
## seeded at the turning point (_pin_seeds), and the floor the backdrop's own colour with the model's
## shadow on it, so no tilt shows a horizon.
##
## With `interactive` (the Model packs window's big preview): a left drag orbits the camera round the
## model's middle (across turns it, up and down tilts it, TILT_MIN to TILT_MAX), the wheel zooms
## (ZOOM_MIN to ZOOM_MAX of the fitted distance), a double click puts the view back. Once dragged the
## model stays where it was put, not turning by itself, until another model is shown or the view reset.
##
## The Factorio pack (model_packs.gd FACTORIO_ID) has pictures, not models: show_sprite draws an
## entity's own Factorio picture on its card (sprite_standins.gd), seen face on from Factorio's pitch as
## the world's cards face Factorio's camera, held still (a drag still turns it, to see it is a cutout);
## show_item_card an item's icon card lying face up, as an item without a model lies on a belt.
## A picture is drawn as Factorio's screen draws it: unshaded (sprite_card_unlit.gdshader, the cards' own
## pictures, every layer composed: sprite_standins.gd), blended by its alpha, through linear tone mapping so the
## file's colours come back unchanged (the models keep filmic), and framed no larger than PICTURE_ZOOM screen
## pixels a picture pixel (a 1x1 inserter's 105-pixel platform filled the big preview at 4 to 8 times,
## magnified soft). An inserter's picture has Factorio's arm in front of it (inserter_arms.gd
## sprite_arm_pose: its hand base and open hand over the pickup, as the world's resting arm), and Play swings it
## (preview_anim.gd, through posed_pieces as a model's arm).

const ModelLibrary := preload("res://scripts/world/model_library.gd")
const Looks := preload("res://scripts/world/looks.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const InserterArms := preload("res://scripts/world/inserter_arms.gd")
const AnimLayer := preload("res://scripts/world/anim.gd")

## A timed moving part at rest, as anim.gd writes an idle instance's custom data: its clock at 0, no
## loops gone, no flags (the shader's `timed`, INSTANCE_CUSTOM.b < -0.5), full glow.
const PART_AT_REST := preload("res://scripts/ui/factorio/preview_anim.gd").PART_AT_REST

const BeltBlur := preload("res://scripts/world/belt_blur.gd")

const PreviewAnim := preload("res://scripts/ui/factorio/preview_anim.gd")
const PreviewSound := preload("res://scripts/ui/factorio/preview_sound.gd")
const PreviewTurret := preload("res://scripts/ui/factorio/preview_turret.gd")
const ItemModels := preload("res://scripts/world/item_models.gd")
## `model` for an item (show_item): "item:<name>", "item:<name>@<file>" for a pack's version.
const ITEM_PREFIX := "item:"
const SpriteStandins := preload("res://scripts/world/sprite_standins.gd")
## `model` for a Factorio picture (show_sprite): "sprite:<entity>|<16-way direction>".
const SPRITE_PREFIX := "sprite:"
## `model` for an item's icon card (show_item_card): "card:<item>".
const CARD_PREFIX := "card:"
## A picture's pixel at most this many of the preview's pixels when fitted (the wheel still zooms in).
const PICTURE_ZOOM := 3.0

const BurnerFx := preload("res://scripts/fx/burner_fx.gd")
const SpriteFx := preload("res://scripts/fx/sprite_fx.gd")

## Radians a second the model turns.
const TURN_SPEED := 0.5
## How long it waits for a model to be read before saying so (ms).
const WAIT_MSEC := 20000
## The share of the picture the model's widest side takes, from the middle out.
const FILL := 0.9
## Turns looked at when fitting the camera.
const TURN_SAMPLES := 16
## How far east of the hills' field and of the focus the preview's world stands (tiles): past the
## pollution texture's reach (pollution.gd, 64 chunks round the focus) with room for the model.
const APART := 1200.0
## The camera's height over the model, in degrees (about Factorio's), and how far a drag may tilt it.
const TILT := 40.0
const TILT_MIN := 5.0
const TILT_MAX := 85.0
## Degrees a pixel of drag turns or tilts.
const DRAG_DEGREES := 0.4
## The wheel's zoom: a notch's factor, and the nearest and furthest share of the fitted distance.
const ZOOM_STEP := 1.15
const ZOOM_MIN := 0.35
const ZOOM_MAX := 3.0
## How far a pan may take the model's middle from the picture's: its share of the half-picture
## (0.9: within the middle 90%, so the model can't be dragged out of view).
const PAN_LIMIT := 0.9
## The backdrop: one colour behind the model and on the floor under it, so no tilt shows a horizon
## (a grey floor seen edge-on against a darker clear colour was a band across the middle).
const BACKDROP := Color(0.15, 0.145, 0.14)
## The floor's render layer: lit by the key light alone (its shadow), not the fill.
const FLOOR_LAYER := 1 << 19
## How dark the key light's shadow makes the floor, at most.
const FLOOR_SHADOW := 0.6
## The pixels drawn per picture pixel each way (the turning model's fine edges and shiny metal
## shimmered with MSAA alone, which smooths only edges).
const SUPERSAMPLE := 2.0
## The floor: exactly the backdrop's colour wherever the key light reaches it (no ambient, sky or
## specular, its emission the backdrop), darkened only by the key light's shadow, which fades out
## round the model (fade_from to fade_to tiles from the turning point) before the floor ends.
const FLOOR_SHADER := """
shader_type spatial;
render_mode ambient_light_disabled, specular_disabled, cull_back;
uniform vec3 backdrop : source_color;
uniform float shadow = 0.6;
uniform float fade_from = 2.0;
uniform float fade_to = 6.0;
varying vec2 at;
void vertex() {
	at = VERTEX.xz;
}
void fragment() {
	ALBEDO = vec3(1.0);
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.0;
	EMISSION = backdrop;
}
void light() {
	float reach = 1.0 - smoothstep(fade_from, fade_to, length(at));
	DIFFUSE_LIGHT -= backdrop * shadow * reach * (1.0 - ATTENUATION);
}
"""
static var _floor_shader: Shader = null

var turning := true
## Mouse drag, wheel and double click move the view (the window's big preview; thumbnails don't).
var interactive := false:
	set(value):
		interactive = value
		mouse_filter = Control.MOUSE_FILTER_STOP if value else Control.MOUSE_FILTER_IGNORE
## The view: the camera's tilt (degrees), its distance as a share of the fitted one, and whether the
## player has moved it (then it doesn't turn by itself).
var tilt := TILT
var zoom := 1.0
var user_moved := false
var _dragging := false
## A right (or middle) drag's pan: the camera and the point it looks at moved across the picture,
## along the camera's right and up, in the preview's units (the model stays put).
var pan := Vector2.ZERO
var _panning := false
var _fit_centre := Vector3.ZERO
var _fit_dist := 1.0
var _fit_radius := 1.0
var _sun := DirectionalLight3D.new()
## The studio light before lighting-fixes step 6 in place of the game's (set_studio).
var studio := false
var _fill := DirectionalLight3D.new()
## The model shown ("" none), and its mesh once it is in (null while it is read, or none).
var model := ""
var shown_mesh: Mesh = null
var viewport := SubViewport.new()
## Where the preview's world stands (place_apart): its floor, model and camera all move with it.
var _world := Node3D.new()
var _apart_version := -1
var _spin := Node3D.new()  # turns about the model's middle
var _holder := Node3D.new()  # the model, its middle moved over the turning point
var _camera := Camera3D.new()
var _ground := MeshInstance3D.new()  # a dark floor, under the model's lowest point
var _waiting_since := 0
var _note := Label.new()
## Play animation and the speaker (the Model packs window): the model's moving parts as in the game
## (preview_anim.gd), the entity's working sound (preview_sound.gd). `entity` is the prototype whose
## sound it is ("" the model's own name).
var entity := ""
var _item_path := ""  # show_item's file ("" the one in use)
var _play := PreviewAnim.new()
## A turret's firing at a target while it plays (preview_turret.gd: the world's turrets.gd and weapon_fx.gd).
var _turret := PreviewTurret.new()
var _env: Environment = null
var _sound := PreviewSound.new()
var _sound_on := false
var _played_mesh: Mesh = null
var _can_play := false
## A burning burner inserter's wisps while it plays (burner_fx.gd, as the world's): the smoke cards,
## made the first time one burns here (a thumbnail never does), and the burner's beat.
var _smoke: SpriteFx = null
var _burner := BurnerFx.new()
## Frames still to render after a static (turning = false) preview settles or changes, before
## pausing its SubViewport (UPDATE_DISABLED) so thumbnails don't re-render a 3D scene every frame.
var _still_renders := 0
var _rendered_size := Vector2i.ZERO


static func _get_floor_shader() -> Shader:
	if _floor_shader == null:
		_floor_shader = Shader.new()
		_floor_shader.code = FLOOR_SHADER
	return _floor_shader


func _init() -> void:
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.use_taa = false
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	viewport.mesh_lod_threshold = 0.0
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	viewport.scaling_3d_scale = SUPERSAMPLE
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	add_child(viewport)
	viewport.add_child(_world)
	_world.add_child(_spin)
	_spin.add_child(_holder)
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	_ground.mesh = plane
	var ground_material := ShaderMaterial.new()
	ground_material.shader = _get_floor_shader()
	ground_material.set_shader_parameter("backdrop", BACKDROP)
	ground_material.set_shader_parameter("shadow", FLOOR_SHADOW)
	_ground.material_override = ground_material
	_ground.layers = FLOOR_LAYER
	_ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ground.position.y = -0.01
	_world.add_child(_ground)
	var sun := _sun
	sun.name = "Sun"
	sun.shadow_enabled = true
	sun.shadow_bias = 0.05  # as the game's sun (main.gd): a belt's thin shadow kept
	sun.shadow_normal_bias = 1.5
	sun.shadow_blur = 1.5
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_fade_start = 1.0
	viewport.add_child(sun)
	# The studio's soft fill from the other side, so faces turned from the key light aren't flat black.
	_fill.name = "Fill"
	_fill.shadow_enabled = false
	_fill.light_cull_mask = 0xFFFFF & ~FLOOR_LAYER  # the floor is the backdrop's colour, shaded by the key alone
	viewport.add_child(_fill)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	_env = env.environment
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = BACKDROP
	env.environment.ssao_enabled = false
	env.environment.ssil_enabled = false
	env.environment.sdfgi_enabled = false
	env.environment.glow_enabled = false
	viewport.add_child(env)
	_camera.fov = 30.0
	_camera.current = true
	_world.add_child(_camera)
	_note.name = "Note"
	_note.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_note.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_note)
	add_child(_sound)
	set_process(false)
	studio = not Looks.preview_light_switch(OS.get_cmdline_user_args())
	_put_light()


## Whether this preview changes from frame to frame (turning, interactive, playing, or awaiting a model).
func _needs_live_render() -> bool:
	return turning or interactive or _play.playing or _turret.playing or (model != "" and not settled())


## Wakes the SubViewport to draw at least `frames` visible frames (static thumbnails freeze after).
func _wake_render(frames := 2) -> void:
	_still_renders = maxi(_still_renders, frames)
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	if model != "" or shown_mesh != null or not _needs_live_render():
		set_process(true)


func _finish_empty_try() -> void:
	if _needs_live_render() or _sound.wanted:
		set_process(false)
	else:
		_still_renders = mini(_still_renders, 1)


## The studio light before lighting-fixes step 6 (true) or the game's (false), at once.
func set_studio(on: bool) -> void:
	if on == studio:
		return
	studio = on
	_put_light()


## The game's light (Looks.noon_rig) or the studio's on the key light, the fill and the environment, the shader
## globals a game's look puts with them when no game is on (Looks.put_idle_globals), and the tonemapping.
func _put_light() -> void:
	if studio:
		_sun.light_energy = 1.4
		_sun.light_color = Color.WHITE
		_sun.light_specular = 0.5
		# From the upper left, as the game's sprites are lit (their shadows fall to the right).
		_sun.rotation_degrees = Vector3(-50, -40, 0)
		_fill.visible = true
		_fill.light_energy = 0.35
		_fill.light_color = Color.WHITE
		_fill.light_specular = 0.0
		_fill.rotation_degrees = Vector3(-30, 140, 0)
		_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		_env.ambient_light_color = Color(0.55, 0.55, 0.6)
		_env.ambient_light_energy = 1.1
		_env.ambient_light_sky_contribution = 1.0
		# Metal reflects a sky, as in the game (main.gd's). Reflecting the dark background instead, a
		# modeller's metal (Vasillo's belts' frames, metallic about 0.98) was drawn nearly black.
		var sky_material := ProceduralSkyMaterial.new()
		sky_material.sky_top_color = Color(0.42, 0.5, 0.6)
		sky_material.sky_horizon_color = Color(0.62, 0.66, 0.7)
		sky_material.ground_horizon_color = Color(0.4, 0.38, 0.35)
		sky_material.ground_bottom_color = Color(0.16, 0.15, 0.14)
		var sky := Sky.new()
		sky.sky_material = sky_material
		sky.radiance_size = Sky.RADIANCE_SIZE_32
		_env.sky = sky
		_env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
		_env.tonemap_white = 1.0
		Looks.put_idle_globals({})
	else:
		var rig := Looks.noon_rig()
		Looks.put_noon_rig(_env, _sun, rig)
		# The look's fill light from the camera's side as in a game (the camera looks north here; the model turns).
		Looks.put_noon_fill(_fill, rig)
		Looks.put_idle_globals(rig)
	_put_tonemap()
	if is_inside_tree() or shown_mesh != null:
		_wake_render(2)


## A picture linear at exposure 1 (its file's colours back unchanged); a model as its light says (the game's look's
## tonemap and exposure, or the studio's filmic).
func _put_tonemap() -> void:
	if _env == null:
		return
	if is_picture():
		_env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		_env.tonemap_exposure = 1.0
	elif studio:
		_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
		_env.tonemap_exposure = 1.0
	else:
		var rig := Looks.noon_rig()
		_env.tonemap_mode = int(rig["tonemap"]) as Environment.ToneMapper
		_env.tonemap_exposure = float(rig["exposure"])


## Shows model `name` (`name@pack`: that pack's), "" nothing.
func show_model(name: String) -> void:
	if name == model:
		return
	model = name
	shown_mesh = null
	_stop_playing()
	for c in _holder.get_children():
		_holder.remove_child(c)
		c.queue_free()
	_spin.rotation = Vector3.ZERO
	tilt = _default_tilt()
	zoom = 1.0
	pan = Vector2.ZERO
	user_moved = false
	_dragging = false
	_panning = false
	_waiting_since = Time.get_ticks_msec()
	_note.text = "" if name == "" else ("Reading the picture..." if is_picture() else "Reading the model...")
	_put_tonemap()
	place_apart()
	if name != "":
		_wake_render(2)
	elif not _needs_live_render():
		_wake_render(1)
	else:
		viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
		set_process(false)
	_try()


## Shows item `item`'s model (items on belts, the ground, hands): the one in use, or with `path` that
## file's (a pack's version). Framed as any model: its box fills the picture, however small it is.
func show_item(item: String, path := "") -> void:
	_item_path = path
	entity = ""
	show_model(ITEM_PREFIX + item + ("@" + path if path != "" else "") if item != "" else "")


## Shows entity `name`'s own Factorio picture on its card, facing 16-way `direction` ("" nothing).
func show_sprite(name: String, direction := 0) -> void:
	entity = name
	show_model(SPRITE_PREFIX + name + "|" + str(direction) if name != "" else "")


## Shows item `item`'s icon card lying face up (the Factorio pack's item).
func show_item_card(item: String) -> void:
	entity = ""
	show_model(CARD_PREFIX + item if item != "" else "")


## Whether a picture is shown (a sprite card or an icon card), not a model: nothing to play.
func is_picture() -> bool:
	return model.begins_with(SPRITE_PREFIX) or model.begins_with(CARD_PREFIX)


## The entity whose picture is shown and its direction (["", 0] for a model).
func shown_sprite() -> Array:
	if not model.begins_with(SPRITE_PREFIX):
		return ["", 0]
	var rest := model.trim_prefix(SPRITE_PREFIX)
	return [rest.get_slice("|", 0), int(rest.get_slice("|", 1))]


## The camera's tilt a model is first seen from: a picture face on, at Factorio's pitch.
func _default_tilt() -> float:
	return SpriteStandins.FACTORIO_PITCH if model.begins_with(SPRITE_PREFIX) else TILT


## The picture's card once composed (on a worker: asked again each frame), drawn as the world draws
## it at the entity's centre; its animation held at rest.
func _try_sprite() -> void:
	var at := shown_sprite()
	SpriteStandins.poll()
	var pic := SpriteStandins.picture(str(at[0]), int(at[1]))
	if pic.is_empty():
		if not SpriteStandins.has_picture(str(at[0])):
			_note.text = "No picture"
			_finish_empty_try()
		elif Time.get_ticks_msec() - _waiting_since > WAIT_MSEC:
			_note.text = "Still reading the picture"
		return
	shown_mesh = pic["card"]
	_note.text = ""
	var body := _picture_node(pic["card"], SpriteStandins.transform(Vector2.ZERO))
	body.name = "Body"
	_holder.add_child(body)
	# An inserter's arm at rest in front of its platform, as the world's resting arm (Play swings it).
	var arm := InserterArms.sprite_arm_pose(arm_model(), InserterArms._turn(InserterArms.cycle_of(str(at[0]))["pick"], int(at[1])),
		false, int(at[1]))
	var pieces: Array = arm.get("pieces", [])
	for i in pieces.size():
		var piece := _picture_node(pieces[i][0], pieces[i][1])
		piece.name = "Arm%d" % i
		piece.set_meta("arm_piece", i)
		_holder.add_child(piece)
	place_apart()
	_frame()


## A card of the picture drawn unshaded with its own alpha, casting nothing (the floor is the backdrop).
func _picture_node(mesh: Mesh, xf: Transform3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.transform = xf
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.material_override = SpriteStandins.unlit_material((mesh as PrimitiveMesh).material) if mesh is PrimitiveMesh else null
	mi.set_meta("card_unlit", true)
	mi.set_instance_shader_parameter(&"f3d_card_run", Vector2(0.0, 0.0))
	return mi


## What Play animates: for a Factorio picture the name its inserter's arm is posed by
## ("<entity>@builtin:factorio"), else the model shown.
func arm_model() -> String:
	if not model.begins_with(SPRITE_PREFIX):
		return model
	return str(shown_sprite()[0]) + "@" + ModelLibrary.ModelPacks.FACTORIO_ID


## An item's icon card lying face up on the floor.
func _try_card() -> void:
	var mesh := SpriteStandins.item_card(model.trim_prefix(CARD_PREFIX))
	if mesh == null:
		_note.text = "No icon"
		_finish_empty_try()
		return
	_show_card(mesh, Transform3D.IDENTITY)


func _show_card(mesh: Mesh, xf: Transform3D) -> void:
	shown_mesh = mesh
	_note.text = ""
	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = mesh
	body.transform = xf
	_holder.add_child(body)
	place_apart()
	_frame()


## The item shown ("" for a model of an entity).
func shown_item() -> String:
	return model.trim_prefix(ITEM_PREFIX).get_slice("@", 0) if model.begins_with(ITEM_PREFIX) else ""


## An item's mesh drawn as the world draws it, by its vertex colours and its picture when it has one
## (item_models.gd), without the world's belt placement.
func _try_item() -> void:
	var item := shown_item()
	var mesh: Mesh = ItemModels.read(_item_path) if _item_path != "" else ItemModels.mesh_for(item)
	if mesh == null:
		_note.text = "No model"
		_finish_empty_try()
		return
	shown_mesh = mesh
	_note.text = ""
	var material := ItemModels.plain_material(mesh)  # (null for an own-look model: preview_mesh's own)
	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = ItemModels.preview_mesh(mesh)
	body.material_override = material
	_holder.add_child(body)
	place_apart()
	_frame()


## Whether the model is in (or there is none): the window's tests wait on it.
func settled() -> bool:
	return model == "" or shown_mesh != null or _note.text in ["No model", "No picture", "No icon"]


func _process(delta: float) -> void:
	if _apart_version != GroundHeight.version():
		place_apart()
	# In the main menu no world gives the shaders the frame's length (world.gd does in a game), so a
	# fast belt's surface stepped unsmeared and strobed as it ran.
	if ModelLibrary.polled_frame < Engine.get_process_frames() - 1:
		BeltBlur.frame(delta)
	if shown_mesh != null and not is_picture():
		_pin_seeds()
	if shown_mesh == null:
		_try()
	elif turning and not user_moved and not model.begins_with(SPRITE_PREFIX):
		if not _dragging:
			_spin.rotate_y(TURN_SPEED * delta)
	elif not _needs_live_render() and not _sound.wanted:
		pass
	elif not interactive and not _play.playing and not _sound.wanted:
		set_process(false)
	_drive(delta)
	if not _needs_live_render() and not _sound.wanted:
		if not is_visible_in_tree():
			viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
			set_process(false)
			return
		if _still_renders > 0:
			_still_renders -= 1
			_rendered_size = viewport.size
			viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
		else:
			_rendered_size = viewport.size
			viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
			set_process(false)


## Whether the model has moving parts, glow or a belt to play (once it is in).
func can_play() -> bool:
	return _can_play


func is_playing() -> bool:
	return _play.playing


## Plays the model's moving parts as the world does while it works, or stops them (back at rest).
func set_playing(on: bool) -> void:
	on = on and _can_play
	if on == _play.playing:
		return
	_play.arm_dir = int(shown_sprite()[1])
	_play.build(_holder, arm_model(), on)
	if not is_picture():
		_turret.build(viewport, _holder, model, on)
	_pin_seeds()
	_wake_render(2)


## Why the entity can't sound ("" it can): no install, the sounds being read, none for it.
func sound_reason() -> String:
	if is_picture():
		var why := PreviewSound.reason(sound_entity())
		return "" if why == "" else "A picture, not a model: " + why.substr(0, 1).to_lower() + why.substr(1)
	if PreviewTurret.can_play(model):
		return PreviewTurret.sound_reason()  # its firing sounds
	return PreviewSound.reason(sound_entity(), _crackles())


## A burning burner inserter (burner_fx.gd): its crackle is its sound.
func _crackles() -> bool:
	return not is_picture() and BurnerFx.enabled() and BurnerFx.burns(shown_mesh)


## Whether its burner smokes now (Play animation on a burning burner inserter), and the wisps made (tests).
func burner_smoking() -> bool:
	return not _burner.burning.is_empty()


func burner_wisps() -> int:
	return _burner.wisps


## The speaker: the entity's working sound while the animation plays (or, with nothing to play, on its own).
func set_sounding(on: bool) -> void:
	_sound_on = on
	set_process(true)
	_drive(0.0)


func sounding_on() -> bool:
	return _sound_on


## Whether its sound is playing now (the tests).
func sound_playing() -> bool:
	return _sound.sounding()


func sound_entity() -> String:
	if entity != "":
		return entity
	if model.begins_with(CARD_PREFIX):
		return ""
	var base := model.get_slice("@", 0)
	for side in ["-north", "-east", "-south", "-west"]:
		if base.ends_with(side):
			return base.trim_suffix(side)
	return base


## The animator's copies and clock (the tests).
func play_state() -> PreviewAnim:
	return _play


## The turret's driver (the tests).
func turret_state() -> PreviewTurret:
	return _turret


func _stop_playing() -> void:
	_play.clear()
	_turret.clear()
	_played_mesh = null
	_can_play = false
	_sound_on = false
	_sound.set_wanted("", false)
	_burner.clear()
	if _smoke != null:
		_smoke.clear()


## A frame of Play animation and the speaker: the model drawn at rest or playing once it is in.
func _drive(delta: float) -> void:
	if shown_mesh != _played_mesh:
		_played_mesh = shown_mesh
		if model.begins_with(SPRITE_PREFIX):
			# A picture plays only its inserter's arm.
			_can_play = shown_mesh != null and _holder.get_children().any(func(c: Node) -> bool: return c.has_meta("arm_piece"))
			_play.arm_dir = int(shown_sprite()[1])
			_play.build(_holder, arm_model(), false)
		elif is_picture():
			_can_play = false
		else:
			_can_play = shown_mesh != null and not model.begins_with(ITEM_PREFIX) 				and (PreviewAnim.can_play(_holder, model) or PreviewTurret.can_play(model))
			_play.build(_holder, model, false)
			_turret.build(viewport, _holder, model, false)
			_pin_seeds()
	_play.process(_holder, delta)
	_turret.sound_on = _sound_on
	_turret.process(delta)
	_sound.set_wanted(sound_entity(), _sound_on and shown_mesh != null and (_play.playing or not _can_play), _crackles())
	_drive_burner(delta)


## A burning burner inserter playing: its wisps from its vent, where the model stands now (the world's
## beat and smoke, burner_fx.gd); none at rest.
func _drive_burner(delta: float) -> void:
	if not (_play.playing and _crackles()):
		if not _burner.burning.is_empty():
			_burner.clear()
		return
	if _smoke == null:
		_smoke = SpriteFx.new()
		_smoke.name = "Smoke"
		_world.add_child(_smoke)
	var vent := (_spin.transform * _holder.transform) * BurnerFx.VENT
	var was: Array = _burner.burning.get(0, [])
	_burner.burning = {0: [vent, float(was[1]) if was.size() > 1 else 0.5 / BurnerFx.SMOKE_RATE]}
	_burner.step(_smoke, delta)


## The player's drag, wheel and double click (interactive only).
func _gui_input(event: InputEvent) -> void:
	if not interactive or shown_mesh == null:
		return
	var button := event as InputEventMouseButton
	if button != null:
		if button.button_index == MOUSE_BUTTON_LEFT:
			if button.double_click:
				reset_view()
			else:
				_dragging = button.pressed
			accept_event()
		elif button.button_index == MOUSE_BUTTON_RIGHT or button.button_index == MOUSE_BUTTON_MIDDLE:
			# Taken whole, press and release: no menu, nothing reaches the window behind.
			_panning = button.pressed
			accept_event()
		elif button.pressed and (button.button_index == MOUSE_BUTTON_WHEEL_UP or button.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var notches := button.factor if button.factor > 0.0 else 1.0
			var by := pow(ZOOM_STEP, notches)
			zoom_by(1.0 / by if button.button_index == MOUSE_BUTTON_WHEEL_UP else by)
			accept_event()
		return
	var motion := event as InputEventMouseMotion
	if motion != null and _dragging and (motion.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		orbit(motion.relative)
		accept_event()
	elif motion != null and _panning and (motion.button_mask & (MOUSE_BUTTON_MASK_RIGHT | MOUSE_BUTTON_MASK_MIDDLE)) != 0:
		pan_by(motion.relative)
		accept_event()


## Moves the view by a drag of `pixels` (the control's): the point under the cursor at the looked-at
## depth stays under it. Kept so the model's middle stays in the picture's middle 90% (_place).
func pan_by(pixels: Vector2) -> void:
	var h := size.y if size.y > 0.0 else float(viewport.size.y)
	if h <= 0.0:
		return
	user_moved = true
	var per_pixel := 2.0 * _fit_dist * zoom * tan(deg_to_rad(_camera.fov * 0.5)) / h
	pan += Vector2(-pixels.x, pixels.y) * per_pixel
	_place(_fit_centre, _fit_dist * zoom, _fit_radius)


## Turns the model by a drag of `pixels`: across spins it round the middle, up and down tilts the camera.
func orbit(pixels: Vector2) -> void:
	user_moved = true
	_spin.rotate_y(deg_to_rad(pixels.x * DRAG_DEGREES))
	tilt = clampf(tilt + pixels.y * DRAG_DEGREES, TILT_MIN, TILT_MAX)
	_place(_fit_centre, _fit_dist * zoom, _fit_radius)


## Zooms in (factor under 1) or out, within ZOOM_MIN and ZOOM_MAX of the fitted distance.
func zoom_by(factor: float) -> void:
	user_moved = true
	zoom = clampf(zoom * factor, ZOOM_MIN, ZOOM_MAX)
	_place(_fit_centre, _fit_dist * zoom, _fit_radius)


## The view as it was fitted, turning by itself again.
func reset_view() -> void:
	user_moved = false
	_dragging = false
	_panning = false
	tilt = _default_tilt()
	zoom = 1.0
	pan = Vector2.ZERO
	_spin.rotation = Vector3.ZERO
	_frame()


## Where the camera stands in the preview's world, and the key light (the tests).
func camera_position() -> Vector3:
	return _camera.position


func key_light() -> DirectionalLight3D:
	return _sun


func _try() -> void:
	if model == "" or shown_mesh != null:
		return
	if model.begins_with(ITEM_PREFIX):
		_try_item()
		return
	if model.begins_with(SPRITE_PREFIX):
		_try_sprite()
		return
	if model.begins_with(CARD_PREFIX):
		_try_card()
		return
	# In the main menu no world polls the library: its worker jobs are started and finished here then.
	if ModelLibrary.polled_frame < Engine.get_process_frames() - 1:
		ModelLibrary.poll()
	if not ModelLibrary.ready(model):
		if Time.get_ticks_msec() - _waiting_since > WAIT_MSEC:
			_note.text = "Still reading the model"
		return
	var mesh := ModelLibrary.mesh_for(model)
	if mesh == null:
		_note.text = "No model"
		_finish_empty_try()
		return
	# A lone belt's, underground's or splitter's end pieces, as the world puts them on a lone one.
	var pieces: Variant = ModelLibrary.lone_belt_pieces(model)
	if pieces == null:
		return
	# A pipe shape's connected ends closed by the kit's endings one tile over, as a short line shows it.
	var stubs: Variant = ModelLibrary.lone_pipe_pieces(model)
	if stubs == null:
		return
	# An inserter's arm at rest, as the world draws an idle one (its base model has none).
	var arm: Variant = InserterArms.resting_pieces(model)
	if arm == null:
		return
	shown_mesh = mesh
	_note.text = ""
	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = mesh
	_holder.add_child(body)
	# The moving parts (a drill's head, a radar's dish) are meshes of their own, at rest in model space.
	for part: ModelLibrary.AnimPart in ModelLibrary.parts_for(model):
		if part.mesh == null or part.lit:
			continue
		_holder.add_child(part_node(part.mesh, Transform3D.IDENTITY, part))
	for p: Array in pieces:
		var end_piece := part_node(p[0], p[1], p[2] if p.size() > 2 else null)
		end_piece.name = "BeltEnd%d" % _holder.get_child_count()
		_holder.add_child(end_piece)
	for p: Array in stubs:
		var stub := part_node(p[0], p[1], null)
		stub.name = "PipeStub%d" % _holder.get_child_count()
		_holder.add_child(stub)
	# (Play animation swings it: preview_anim.gd poses each piece by its index.)
	for i in (arm as Array).size():
		var p: Array = arm[i]
		var arm_piece := part_node(p[0], p[1], null)
		arm_piece.name = "Arm%d" % i
		arm_piece.set_meta("arm_piece", i)
		_holder.add_child(arm_piece)
	place_apart()
	_frame()


## A body or moving part at `xf` drawn as the world draws it at rest. A modeller's baked part
## (model_skin.gd: a splitter's gears and belt surfaces, a belt's rollers) is stored unskinned and
## put in place by its bones in the shader (anim_mode 8), only for an instance whose custom data
## says it is timed; as a plain mesh it lay as stored (Vasillo's splitter's gears and belts turned a
## quarter, a strip down its middle). So it is a MultiMesh of one, its materials set up as anim.gd's.
func part_node(mesh: Mesh, xf: Transform3D, part: ModelLibrary.AnimPart) -> GeometryInstance3D:
	if part == null or part.kind != "baked" or part.bake.is_empty():
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.transform = xf
		return mi
	AnimLayer.setup_part(part)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = 1
	# A new instance's transform is zeros (Godot's buffer starts empty): left so, the part was drawn
	# collapsed to a point and vanished (Vasillo's burner drill's whole vibrating body, a belt's base
	# and rollers). The world sets every instance's; so does this. The meta lets the tests see it, as
	# the dummy renderer keeps no instance data to read back.
	mm.set_instance_transform(0, Transform3D.IDENTITY)
	mm.set_instance_custom_data(0, PART_AT_REST)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.transform = xf
	mmi.set_meta("instance_xf", Transform3D.IDENTITY)
	mmi.set_meta("rest_box", baked_rest_box(part))
	mmi.set_meta("anim_part", part)  # Play animation times this instance in place (preview_anim.gd)
	return mmi


## A baked part's box at rest, its vertices skinned by their bones at frame 0 as the shader does.
static func baked_rest_box(part: ModelLibrary.AnimPart) -> AABB:
	var image: Image = part.bake.get("image")
	if image == null or part.mesh == null:
		return part.mesh.get_aabb() if part.mesh != null else AABB()
	var box := AABB()
	var first := true
	for s in part.mesh.get_surface_count():
		var arrays := part.mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var skin: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM3] if arrays[Mesh.ARRAY_CUSTOM3] != null else PackedFloat32Array()
		for v in verts.size():
			var m := Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO)
			var total := 0.0
			for k in 4:
				if v * 4 + k >= skin.size():
					break
				var code := skin[v * 4 + k]
				var w := fposmod(code, 1.0) / 0.999
				if w <= 0.0:
					continue
				var j := int(floor(code))
				var r0 := image.get_pixel(j * 3, 0)
				var r1 := image.get_pixel(j * 3 + 1, 0)
				var r2 := image.get_pixel(j * 3 + 2, 0)
				m.basis.x += w * Vector3(r0.r, r1.r, r2.r)
				m.basis.y += w * Vector3(r0.g, r1.g, r2.g)
				m.basis.z += w * Vector3(r0.b, r1.b, r2.b)
				m.origin += w * Vector3(r0.a, r1.a, r2.a)
				total += w
			var p := verts[v] if total <= 0.0 else (m * verts[v]) / total
			box = AABB(p, Vector3.ZERO) if first else box.expand(p)
			first = false
	return box


## Stands the preview's world east of the hills' field and of the main camera's focus (APART), so the
## world's shaders lift nothing here and find no pollution; near enough to the game's own
## coordinates that floats are as precise as there. Again whenever the hills' field changes.
func place_apart() -> void:
	_apart_version = GroundHeight.version()
	var at := Vector2.ZERO
	var main_camera: Camera3D = get_tree().root.get_camera_3d() if is_inside_tree() else null
	if main_camera != null:
		at = Vector2(main_camera.global_position.x, main_camera.global_position.z)
	var x := at.x + APART
	var field := GroundHeight.area()
	if field.has_area():
		x = maxf(x, field.end.x + APART)
	_world.position = Vector3(roundf(x), 0.0, roundf(at.y))


## The model's world position (the tests): where the world's shaders read the hills and pollution.
func model_origin() -> Vector3:
	return _world.position + _spin.position + _holder.position


## The model's whole box (its body and every part), in model space.
func model_box() -> AABB:
	var box := AABB()
	var first := true
	for c in _holder.get_children():
		var b: AABB
		var mi := c as MeshInstance3D
		if mi != null and mi.mesh != null:
			b = mi.transform * mi.mesh.get_aabb()
		elif c is MultiMeshInstance3D and c.has_meta("rest_box"):
			b = (c as Node3D).transform * (c.get_meta("rest_box") as AABB)
		else:
			continue
		box = b if first else box.merge(b)
		first = false
	return box


## The camera looks down at about Factorio's angle at the middle of the model's box (its body and
## every part), the same angle for every model, and stands back so the whole model stays in view
## as it turns with a small margin: first far enough for the sphere round the box (against the
## narrower of the view's two angles), then nearer by how much of the picture the turning box
## really takes, so wide, flat, tall, tiny and off-centre models (a resource's or a cliff's box is
## nowhere near the tile's middle) all fill it alike.
func _frame() -> void:
	if shown_mesh == null:
		return
	var box := model_box()
	var mid := box.get_center()
	_holder.position = Vector3(-mid.x, 0.0, -mid.z)
	var centre := Vector3(0.0, mid.y, 0.0)
	var radius := maxf(box.size.length() * 0.5, 0.15)
	var half_v := deg_to_rad(_camera.fov * 0.5)
	var size := Vector2(viewport.size)
	var aspect := size.x / size.y if size.y > 0.0 else 1.0
	var half := minf(half_v, atan(tan(half_v) * aspect))
	var dist := radius / sin(half) * 1.05
	var panned := pan  # fitted unpanned, the pan put back after
	pan = Vector2.ZERO
	_place(centre, dist, radius)
	if is_inside_tree() and size.x > 0.0 and size.y > 0.0:
		# A picture held still is fitted as it stands; a model as it turns.
		var samples := 1 if model.begins_with(SPRITE_PREFIX) else TURN_SAMPLES
		for i in 3:
			var took := 0.0  # the share of the picture the turning box takes, from its middle out
			for k in samples:
				var r := box_on_screen(k * TAU / samples)
				var reach := Vector2(maxf(size.x * 0.5 - r.position.x, r.end.x - size.x * 0.5) / (size.x * 0.5),
					maxf(size.y * 0.5 - r.position.y, r.end.y - size.y * 0.5) / (size.y * 0.5))
				took = maxf(took, maxf(reach.x, reach.y))
			if took <= 0.0:
				break
			# Nearer or further so it takes FILL of the picture: sizes on screen go as 1 / distance
			# (near enough once the camera is a few radii away; a second pass finishes it).
			dist = maxf(dist * took / FILL, radius * 1.2)
			_place(centre, dist, radius)
	if model.begins_with(SPRITE_PREFIX) and is_inside_tree() and size.y > 0.0:
		# No larger than PICTURE_ZOOM of the preview's pixels a picture pixel: a tile is `px` picture pixels.
		var pic := SpriteStandins.picture(str(shown_sprite()[0]), int(shown_sprite()[1]))
		var px: float = pic.get("px_per_tile", 0.0)
		if px > 0.0:
			# Screen pixels a tile at distance d: size.y / (2 d tan(half_v)).
			dist = maxf(dist, size.y / (2.0 * tan(half_v) * PICTURE_ZOOM * px))
			_place(centre, dist, radius)
	_fit_centre = centre
	_fit_dist = dist
	_fit_radius = radius
	pan = panned
	if tilt != TILT or zoom != 1.0 or pan != Vector2.ZERO:
		_place(centre, dist * zoom, radius)
	_ground.position.y = minf(box.position.y, 0.0) - 0.01
	# The shadow fades out round the model, past where a model this size casts one.
	var floor_material := _ground.material_override as ShaderMaterial
	floor_material.set_shader_parameter("fade_from", radius * 1.5)
	floor_material.set_shader_parameter("fade_to", radius * 4.0)
	if not is_picture():
		_pin_seeds()
	if not _needs_live_render():
		_wake_render(2)


## Every drawn piece of the model reads its seed (weathering, dirt, a belt's parity) at the turning
## point, which holds still, not at its own origin, which circles it as it turns (an off-centre
## model's seed, a hash of where it stands, changed every frame: the flicker). Each frame, so pieces
## added later (moving parts, arms) take it too.
func _pin_seeds() -> void:
	var at := _world.position + _spin.position
	var pin := Vector3(at.x, 1.0, at.z)
	for mi: Node in _holder.find_children("*", "GeometryInstance3D", true, false):
		var g := mi as GeometryInstance3D
		if g.get_instance_shader_parameter(&"f3d_seed_at") != pin:
			g.set_instance_shader_parameter(&"f3d_seed_at", pin)


func _place(centre: Vector3, dist: float, radius: float) -> void:
	var up := deg_to_rad(tilt)
	var eye := centre + Vector3(0.0, sin(up), cos(up)) * dist
	var look := Basis.looking_at(centre - eye, Vector3.UP)
	# The pan slides camera and target together across the picture, so the model's middle sits at
	# -pan from the picture's middle at depth `dist`: kept within PAN_LIMIT of the half-picture.
	var half_y := dist * tan(deg_to_rad(_camera.fov * 0.5))
	var vs := Vector2(viewport.size)
	var half_x := half_y * (vs.x / vs.y if vs.y > 0.0 else 1.0)
	pan = Vector2(clampf(pan.x, -half_x * PAN_LIMIT, half_x * PAN_LIMIT), clampf(pan.y, -half_y * PAN_LIMIT, half_y * PAN_LIMIT))
	eye += look.x * pan.x + look.y * pan.y
	_camera.transform = Transform3D(look, eye)
	_camera.near = maxf(dist - radius * 1.5, 0.05)
	_camera.far = dist + radius * 2.0 + 50.0
	# One shadow map over the model and the floor round it: fine texels that hold still as it turns.
	_sun.directional_shadow_max_distance = dist + radius * 3.0
	if not _needs_live_render() and (shown_mesh != null or model != ""):
		_wake_render(2)


## Where the model's box lands in the picture at turn `angle`, in its pixels.
func box_on_screen(angle: float) -> Rect2:
	var box := model_box()
	var turn := _world.transform * Transform3D(Basis(Vector3.UP, angle), Vector3.ZERO) * Transform3D(Basis.IDENTITY, _holder.position)
	var r := Rect2()
	for i in 8:
		var at := _camera.unproject_position(turn * box.get_endpoint(i))
		r = Rect2(at, Vector2.ZERO) if i == 0 else r.expand(at)
	return r


## Whether every corner of the model's box is inside the picture at turn `angle` (the tests).
func box_in_view(angle: float) -> bool:
	var r := box_on_screen(angle)
	return Rect2(Vector2.ZERO, Vector2(viewport.size)).encloses(r)


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		place_apart()
	elif what == NOTIFICATION_RESIZED:
		_frame.call_deferred()
		if not _needs_live_render() and is_visible_in_tree():
			_wake_render(2)
	elif what == NOTIFICATION_VISIBILITY_CHANGED:
		if is_visible_in_tree():
			if _needs_live_render() or _still_renders > 0 or (shown_mesh != null and _rendered_size != viewport.size):
				_wake_render(2 if _rendered_size != viewport.size else maxi(_still_renders, 1))
			else:
				# SubViewportContainer resets child SubViewports to UPDATE_WHEN_VISIBLE on show.
				viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	elif what == NOTIFICATION_EXIT_TREE and studio != (not Looks.preview_light_switch(OS.get_cmdline_user_args())):
		# The globals back to what the menu's backdrop and the other previews draw with.
		Looks.put_idle_globals({} if studio else Looks.noon_rig())
	elif what == NOTIFICATION_PREDELETE:
		_play.clear()  # its animator is a Node of its own
		_turret.clear()
