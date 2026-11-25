extends Node3D
## The character the client controls, drawn from the mod's "me" messages. In a vehicle it is
## hidden and follows the vehicle (the camera follows it), and the vehicle is drawn as a mover.

const Visuals := preload("res://scripts/world/visuals.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const CharacterPose := preload("res://scripts/player/character_pose.gd")
const CharacterAnim := preload("res://scripts/player/character_anim.gd")
const GameClock := preload("res://scripts/world/game_clock.gd")
const Rockets := preload("res://scripts/world/rockets.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const CharacterPoints := preload("res://scripts/player/character_points.gd")
const Switches := preload("res://scripts/switches.gd")

const FOLLOW_RATE := 18.0

var unit := 0
var walking := false
var health := 0
var max_health := 250
## The mod says the character is firing (its ammo went down a moment ago).
var firing := false
var craft_queue := 0
## Mining progress 0..100, or -1 when not mining.
var mining := -1
var mining_at := Vector2.ZERO
## K13: the character repairs something with a repair pack (`me` `rp`), and where: it swings its tool as
## it mines, and fx.gd plays the repair sound there.
var repairing := false
var repair_at := Vector2.ZERO
## I20: the right button went down on something to mine (player_input.gd), before the bridge's
## mining progress comes back: fx.gd starts the swing's sound from this, as Factorio does on the
## click. -1 msec when there is none.
var mine_hint_at := Vector2.ZERO
var mine_hint_msec := -1
## The vehicle the character sits in (its unit number), or 0, and its speed in km/h.
var vehicle := 0
var vehicle_speed := 0.0
## The shield in the armour and its most (`me` `sd`, `msd`; 0 without shields), for add-ons
## (api.character); the HUD takes them from the message itself.
var shield := 0
var max_shield := 0
## A `me` was heard since the last handshake (main.gd's _on_welcome clears it): the character's
## state is known.
var heard_me := false

var _target := Vector3.ZERO
## The last few positions the mod sent and their ticks (`me`'s k): the avatar is drawn between them
## GameClock.DELAY_SENDS behind the game's clock, so it moves at an even speed and the run cycle
## steps evenly (owner's #19: chasing each position made it surge and sag, worst at exoskeleton
## speed). The clock runs at the game's measured tick rate, so a slow server doesn't make it lurch.
var _ticks: Array[float] = []
var _spots: Array[Vector3] = []
var _clock := GameClock.new()
## Each sent position's walk angle (`me`'s a, in turns), or -1 when not walking at an angle.
var _angles: Array[float] = []
## The angle of the stretch drawn now (-1: none); how far the avatar is drawn from the real
## position to keep it on the line, and the last real position drawn.
var _drawn_angle := -1.0
var _offset := Vector3.ZERO
var _last_goal := Vector3.ZERO
var _smooth_set := false
## B7: walking at an angle, Factorio's character zig-zags between two of its 8 directions about the
## line (puppet.lua). The avatar is drawn along the line: movement along it is followed exactly,
## sideways movement only through a slow filter, and never more than MAX_OFF from the real position,
## so sliding along a wall still shows. Without an angle it catches up at once.
const SIDE_RATE := 3.0
const MAX_OFF := 0.2
var _yaw_goal := 0.0
## The last angled walk's facing (NAN: none) and its tick, kept through the zig-zag's steps.
var _line_yaw := NAN
var _line_tick := -1.0
const ANGLE_HOLD := 10.0
## The character's own render layer: its lights cast no shadows of it (F7: running, its head and
## swinging arms passed in front of the flashlight, so the cone flickered with every stride).
const SELF_LAYER := 1 << 19
const NOT_SELF := 0xFFFFFFFF & ~SELF_LAYER
## Nor do they cast belt items' shadows (ItemCards.BELT_LAYER): an item kind is one MultiMesh over the
## whole square round the character, so at night every 3D item went through the flashlight's pass and
## each lantern cube face it touched, for shadows a few pixels long. --item-light-shadows=on keeps them.
static var item_light_shadows := Switches.has("--item-light-shadows=on")
## --lantern-shadow=cube: render all 6 cube faces instead of dual-paraboloid for the character lantern.
static var lantern_dual_paraboloid := not (Switches.has("--lantern-shadow=cube"))
var _lantern := OmniLight3D.new()
## Factorio's character also lights a cone ahead of it at night (its `light`'s oriented cone,
## shifted 13 tiles forward): a flashlight.
var _flashlight := SpotLight3D.new()
## How high the lantern and the flashlight are over the ground under the character (the old
## flashlight's; the new one stands BEAM_HEIGHT up: flashlight_height()).
const LANTERN_HEIGHT := 2.5
const FLASHLIGHT_HEIGHT := 3.0
## The flashlight (V27; owner: "seems to be no flashlight"). Factorio's is a light picture drawn
## over the world (core/graphics/light-cone.png: a triangle from the character's feet some 25 tiles
## ahead, fading out), which no building stops. "new" (the default) draws it so: a spot BEAM_HEIGHT
## over the character with nothing casting its shadow, the picture projected through it so that it
## lands on the ground at Factorio's size and fade (beam_texture()). "old" (--flashlight=old) is
## 0.2.1's: a spot 3 tiles up casting the buildings' shadows, so its beam stopped at the next
## building. The Compatibility renderer draws no projectors: the old one there.
static var flashlight_mode := _flashlight_mode()
## Factorio's cone (the character's oriented light in entities.lua): a 200-pixel picture at scale 2,
## the light's size 2, so 25 tiles square, its middle 13 tiles ahead (shift {0, -13}).
const CONE_TILES := 25.0
const CONE_AHEAD := 13.0
## The new flashlight's spot: high enough that the ground far ahead isn't lit at a graze (its light
## falls off as Factorio's picture does, so the picture has little to make up), pitched to put the
## cone's far end and its point at the same angle off its axis, wide enough to hold them both, its
## edge sharp (the picture is dark there anyway), its range past the cone's far corners.
const BEAM_HEIGHT := 10.0
const BEAM_PITCH := 50.0
const BEAM_ANGLE := 45.0
const BEAM_EDGE := 6.0
const BEAM_RANGE := 40.0
## The ground's light at the cone's brightest (light energy on a surface facing it): the old beam's
## brightest was about 1.1, 5 to 8 tiles ahead, and 0.14 at 20; this one is 1.2 at 8 and 0.3 at 20.
const BEAM_PEAK := 1.6
## Its picture's texels a side.
const BEAM_MASK_SIZE := 96
## Nothing is lit this close ahead: the cone's point is a tile ahead, and the body stays dark.
const BEAM_NEAREST := 1.0
static var _beam_texture: ImageTexture
static var _beam_image: Image
## The spot's energy for BEAM_PEAK on the ground: the picture's lift for the spot's own falloff.
static var _beam_gain := 1.0
## The add-on's hills under the character (ground_height.gd), read each frame: its model is lifted
## onto them in its shader, but its lights, the thrusters' smoke and flames are placed here, so they
## are lifted by this (at the flat height the lantern sat inside ground more than 2.5 tiles up and
## lit nothing, J19). 0 on flat ground.
var lift := 0.0
## (Add-on API 1.7) The add-ons' lift (api.character.set_lift, summed by addon_host.gd): the body is
## drawn this far up (y) and across (x, z) from the game's place, through the pose's root, and its
## lantern, bar and flames follow it (the eye only for the camera part, _view_lifted). `position` never moves with it: reach, picking and every
## command stay on the game's position. Capped by cap_lift.
var _lifted := Vector3.ZERO
## The most an add-on lift draws the body up, and across (tiles): above every tree and model with room
## for a flight, but never further across than beside where the game has the character.
const LIFT_MAX := 16.0
const OFFSET_MAX := 1.0
## The camera's part of the add-ons' lift: only lifts set with `camera` true (set_lift's third
## argument) move the first-person eye and the angled view's centre. Capped as the body's is.
var _view_lifted := Vector3.ZERO
## The belt step-up (owner: "on by default but doesn't move camera or actual player position, just a
## visual thing"): on a belt, underground, splitter, loader or linked belt (stand_height.gd BELTS) the
## body is drawn on its top, at most STAND_MAX, eased, beside the add-ons' lift. Never the camera, never `position`. Looked up only
## when the drawn position moves (at most once a frame), nothing while standing still.
var world  # WorldMirror (main.gd sets it); none: no step-up
var _stand := 0.0  # the step-up as drawn, eased
var _stand_goal := 0.0
var _stand_at := Vector2.INF  # the drawn place _stand_goal was looked up at
var _box_for := Vector3.INF  # the lift _rig's culling box was last grown for (_fit_box)
## stand_height.gd, loaded on first use: a preload would pull in aim_pick.gd and world.gd, which names the
## Bridge autoload, and `-s` scripts that load avatar.gd (no autoloads) would fail to compile.
static var _stand_height: GDScript
var stand_lookups := 0  # counted for the tests' cost check
## The most the belt step-up draws the body up (tiles): a belt's height, so a splitter's or a model
## pack's tall loader frame doesn't stand the character on its hood (api.world.stand_height_at keeps
## the model's whole top for add-ons).
const STAND_MAX := 0.3
const STEP_UP_RATE := 30.0  # most of the way up in about 0.1 s,
const STEP_DOWN_RATE := 20.0  # down a touch slower
## `--belt-step=off`: walking through belts, as before, whatever the setting says (docs/RUNNING.md).
static var belt_step_switch := Switches.on("--belt-step")
static var _belt_step := -1  # Settings > Graphics > Step onto belts: -1 unread, then 0 or 1
var _body: Array = []  # the nodes hidden while in a vehicle or seen from inside (first person)
var _body_at: Array = []  # their own positions, for the capsule stand-in's lift
var _first_person := false
## The character model (Wube's, skinned: character_pose.gd), drawn as a one-instance MultiMesh
## with its own copy of the materials, which carry the pose.
var _rig: MultiMeshInstance3D
var _pose: CharacterPose
var _anim := CharacterAnim.new()
var _materials: Array[ShaderMaterial] = []
var _pickaxe: Node3D
var _gun: Node3D
var _last := Vector3.ZERO
var _has_state := false
## Where the character is shooting (world position), or null: set by combat.gd.
var aim_target = null
## --anim-pose=<run|idle|mine|aim|ready|runaim|runready|dead|walk|exo|back|stop|hover|fly|flyloop>: hold one
## animation (walk and exo: half and three times running speed; back: running backwards; stop: runs
## and stops every 2 s; hover and fly: in the air, still and moving; flyloop: takes off, hovers and
## lands every 4 s). --anim-rate=<x> plays it at x times its speed (0.1 for screenshots, which take
## longer than a frame each).
var _demo := ""
var _demo_rate := 1.0
var _demo_t := 0.0
## The item in the armour slot (set_armor), the look drawn for it, and whether that is the mech's.
var armor := ""
var look := BODY_MODEL
var _mech := false
## Flying in mech armour (`me` fl, fh): the mod's height in tiles, and the height drawn, eased
## towards it so a jump in the mod's number doesn't jerk the body.
var flying := false
var _fly_goal := 0.0
var _fly_h := 0.0
var _fly_down := false  # the mod's height is falling (landing)
const FLY_RATE := 6.0
## Thruster smoke and flames under the feet while flying (Factorio's mech-armor-smoke puffs: grey,
## growing from 0.1 to 0.3 over 50 ticks).
var _jets: Array = []

const BODY_MODEL := "character"
const MECH_ARMOR := "mech-armor"
const MECH_MODEL := "character-mech-armor"
## Factorio's look per armour (entities.lua's character animations): heavy and modular armour add
## the level 2 layer, power armour the level 3 one; light armour (and modded armour) keeps the plain
## look. The looks share the character's skeleton and animations (tools/models/armour_looks.py).
const LOOKS := {"heavy-armor": "character-armor-2", "modular-armor": "character-armor-2",
	"power-armor": "character-armor-3", "power-armor-mk2": "character-armor-3", MECH_ARMOR: MECH_MODEL}

## The hand's grip in the rest pose (right hand, the model's frame), where tools are held.
const GRIP := Vector3(0.26, 0.73, -0.04)
## The pickaxe's handle: turned this far from pointing forwards (-Z) towards down.
const PICK_ANGLE := -0.97
## Gun muzzle in the gun's own frame (barrel along -Z).
const MUZZLE := Vector3(0.0, 0.08, -0.64)
## Factorio's running_speed 0.15 tiles a tick, for --anim-pose.
const DEMO_SPEED := 9.0


func _ready() -> void:
	# Factorio's character carries a light at night, so the player is never in the dark.
	# I22: warm white, as the owner sees Factorio's (its light is {1, 1, 1}, but drawn into a warm
	# night it reads as an incandescent torch); the near-white before read blue-white against the
	# night's blue ambient. About 3,300 K.
	_lantern.light_color = Color(1.0, 0.86, 0.68)
	_lantern.omni_range = 11.0
	_lantern.position = Vector3(0, LANTERN_HEIGHT, 0)
	_lantern.light_energy = 0.0
	_lantern.shadow_enabled = true
	_lantern.omni_shadow_mode = OmniLight3D.SHADOW_DUAL_PARABOLOID if lantern_dual_paraboloid else OmniLight3D.SHADOW_CUBE
	add_child(_lantern)
	_flashlight.light_color = Color(1.0, 0.83, 0.62)
	var casters := NOT_SELF if item_light_shadows else NOT_SELF & ~ItemCards.BELT_LAYER
	_lantern.shadow_caster_mask = casters
	if flashlight_mode == "old":
		# From the hand (1.6 tiles up, 8 degrees down) the beam met the matte ground at a graze and lit a
		# faint patch two or three tiles long; from 3 tiles up, 14 degrees down, a wider cone that fades
		# slower lights the ground some 12 tiles ahead, but the next building's shadow ends it.
		_flashlight.spot_range = 26.0
		_flashlight.spot_angle = 28.0
		_flashlight.spot_attenuation = 0.3
		_flashlight.position = Vector3(0, FLASHLIGHT_HEIGHT, 0.0)
		_flashlight.rotation.x = deg_to_rad(-14.0)  # down onto the ground ahead (forward is -Z)
		_flashlight.shadow_caster_mask = casters
	else:
		_flashlight.spot_range = BEAM_RANGE
		_flashlight.spot_angle = BEAM_ANGLE
		_flashlight.spot_angle_attenuation = BEAM_EDGE
		_flashlight.spot_attenuation = 0.0  # no fall-off with distance but the range's: the picture fades it
		_flashlight.position = Vector3(0, BEAM_HEIGHT, 0.0)
		_flashlight.rotation.x = deg_to_rad(-BEAM_PITCH)
		_flashlight.light_projector = beam_texture()
		# Godot's scene shader projects a spot's picture through the spot's shadow matrix, so the shadow
		# stays on, with nothing casting into it: no building stops the beam, as none stops Factorio's,
		# and the character's own swinging arms can't flicker it (F7).
		_flashlight.shadow_caster_mask = 0
		_flashlight.light_specular = 0.25  # Factorio's light is a picture: no highlights to speak of
	_flashlight.shadow_enabled = true
	_flashlight.light_energy = 0.0
	_flashlight.visible = false
	add_child(_flashlight)
	for arg in Switches.args():
		if arg.begins_with("--anim-pose="):
			_demo = arg.get_slice("=", 1)
		elif arg.begins_with("--anim-rate="):
			_demo_rate = clampf(float(arg.get_slice("=", 1)), 0.01, 10.0)
	var body: GeometryInstance3D = MeshInstance3D.new()
	var rigged := _make_rig(BODY_MODEL)
	if rigged != null:
		body = rigged
		_pickaxe = _make_pickaxe()
		_gun = _make_gun()
		for tool in [_pickaxe, _gun]:
			tool.visible = false
			add_child(tool)
	else:
		var capsule := CapsuleMesh.new()
		capsule.radius = 0.3
		capsule.height = 1.7
		(body as MeshInstance3D).mesh = capsule
		body.position.y = 0.85
		body.material_override = Visuals.solid_material(Color(0.95, 0.6, 0.15))
		# A nose, so you can see which way the character faces.
		var nose := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.15, 0.15, 0.3)
		nose.mesh = box
		nose.position = Vector3(0, 1.35, -0.3)
		nose.material_override = Visuals.solid_material(Color(0.2, 0.2, 0.2))
		add_child(nose)
		_body.append(nose)
	add_child(body)
	_body.append(body)
	for node in _body:
		_body_at.append((node as Node3D).position)
	_own_layer(self)


## Puts the character's meshes (body, tools) on SELF_LAYER, so its own lights don't shadow them.
static func _own_layer(node: Node) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).layers = SELF_LAYER
	for child in node.get_children():
		_own_layer(child)


## The skinned body drawn with `model` (character.glb, or the mech's), as a one-instance
## MultiMesh with its own materials; sets _rig, _pose and _materials. Null (and nothing
## changed) without the model or its rig.
func _make_rig(model_name: String) -> MultiMeshInstance3D:
	var model := ModelLibrary.mesh_for(model_name)
	var pose := CharacterPose.new()
	if not (model is ArrayMesh and pose.load_rig(model_name)):
		return null
	_pose = pose
	_materials.clear()
	_rig = MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _own_copy(model as ArrayMesh)
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D.IDENTITY)
	mm.set_instance_custom_data(0, Color(0, 0, 0, 1))
	_rig.multimesh = mm
	# The pose moves vertices outside the mesh's own box (a raised pickaxe, lying dead).
	# Flying lifts it a few tiles more; an add-on's lift and the belt step-up grow it (_fit_box).
	_box_for = Vector3.INF
	_fit_box()
	return _rig


## The armour in the character's armour slot (item name, "" for none): the body swaps to that
## armour's look (LOOKS; in mech armour a walking suit with a rig of its own).
func set_armor(item: String) -> void:
	armor = item
	var want := look_for(item)
	if want == look or _rig == null:
		return
	var old := _rig
	var fresh := _make_rig(want)
	if fresh == null:
		return  # no model or rig for that look in this build: keep the one drawn
	look = want
	_mech = want == MECH_MODEL
	_anim.mech = _mech
	_body.erase(old)
	old.queue_free()
	add_child(fresh)
	_own_layer(fresh)
	_body.append(fresh)
	_update_body()
	if not _attached.is_empty() or not _layer_src.is_empty():
		_refit_attached()  # (1.7) the new look's rest places
		set_pose_layer(_layer_src)


## The model Factorio's look for armour `item` is drawn with.
static func look_for(item: String) -> String:
	return str(LOOKS.get(item, BODY_MODEL))


func is_mech() -> bool:
	return _mech


## The model with its own materials, so this character's pose doesn't move other characters.
func _own_copy(model: ArrayMesh) -> ArrayMesh:
	# Built surface by surface: a duplicate() of an imported mesh doesn't draw.
	var out := ArrayMesh.new()
	for i in model.get_surface_count():
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ModelLibrary.ModelLods.arrays_of(model, i), [], {},
			model.surface_get_format(i) & ~Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES)
		out.surface_set_name(i, model.surface_get_name(i))
		var m := model.surface_get_material(i) as ShaderMaterial
		if m != null:
			m = ModelLibrary.ModelLods.copy_material(m)
			_materials.append(m)
			m.set_shader_parameter("ground_rigid", true)  # lifted whole onto hills: no bend at a cliff
		out.surface_set_material(i, m)
	return out


## Factorio's pickaxe: a wooden handle with an iron head, the handle along -Z from the grip.
func _make_pickaxe() -> Node3D:
	var root := Node3D.new()
	var wood := Visuals.solid_material(Color(0.45, 0.29, 0.16))
	var iron := Visuals.solid_material(Color(0.42, 0.43, 0.45))
	iron.metallic = 0.6
	iron.roughness = 0.5
	var handle := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.022
	cyl.bottom_radius = 0.026
	cyl.height = 0.58
	handle.mesh = cyl
	handle.material_override = wood
	handle.rotation.x = PI / 2.0
	handle.position.z = -0.2
	root.add_child(handle)
	# The head: two tapering spikes, curving a little back towards the hand.
	for side in [-1.0, 1.0]:
		var spike := MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.top_radius = 0.006
		cone.bottom_radius = 0.034
		cone.height = 0.2
		cone.radial_segments = 6
		spike.mesh = cone
		spike.material_override = iron
		spike.position = Vector3(0.0, side * 0.1, -0.45)
		spike.rotation.x = (0.0 if side > 0 else PI) + side * 0.25
		root.add_child(spike)
	var collar := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.06, 0.07, 0.07)
	collar.mesh = box
	collar.material_override = iron
	collar.position.z = -0.47
	root.add_child(collar)
	return root


## The character's gun (Factorio's submachine gun as its sprites show it: a dark steel body,
## a magazine under it, a wooden stock), barrel along -Z from the grip.
func _make_gun() -> Node3D:
	var root := Node3D.new()
	var steel := Visuals.solid_material(Color(0.2, 0.21, 0.22))
	steel.metallic = 0.7
	steel.roughness = 0.45
	var wood := Visuals.solid_material(Color(0.38, 0.24, 0.13))
	var parts := [
		[Vector3(0.07, 0.09, 0.42), Vector3(0.0, 0.07, -0.14), steel],  # receiver
		[Vector3(0.035, 0.035, 0.3), Vector3(0.0, 0.08, -0.48), steel],  # barrel
		[Vector3(0.05, 0.12, 0.05), Vector3(0.0, 0.0, 0.0), steel],  # grip
		[Vector3(0.06, 0.08, 0.2), Vector3(0.0, 0.05, 0.16), wood],  # stock
		[Vector3(0.05, 0.14, 0.07), Vector3(0.0, -0.02, -0.24), steel],  # magazine
	]
	for p in parts:
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = p[0]
		mi.mesh = box
		mi.position = p[1]
		mi.material_override = p[2]
		root.add_child(mi)
	return root


func snap_to(pos: Vector2) -> void:
	_target = Vector3(pos.x, 0, pos.y)
	position = _target
	_ticks.clear()
	_spots.clear()
	_angles.clear()
	_smooth_set = false


## {t: "me", u, x, y, d, w, hp, q, mhp?, sh?, m?, mx?, my?, rp?, rx?, ry?, v?, vs?}
func update_from(msg: Dictionary) -> void:
	unit = int(msg.get("u", unit))
	_target = Vector3(int(msg.get("x", 0)) / 256.0, 0.0, int(msg.get("y", 0)) / 256.0)
	_sample(float(msg.get("k", -1)), _target, float(msg["a"]) / 1000.0 if msg.has("a") else -1.0)
	walking = int(msg.get("w", 0)) == 1
	_yaw_goal = _facing_yaw(msg)
	health = int(msg.get("hp", 0))
	_has_state = msg.has("hp")
	heard_me = true
	shield = int(msg.get("sd", 0))
	max_shield = int(msg.get("msd", 0))
	max_health = maxi(1, int(msg.get("mhp", max_health)))
	firing = int(msg.get("sh", 0)) == 1
	craft_queue = int(msg.get("q", 0))
	flying = int(msg.get("fl", 0)) == 1
	var goal := int(msg.get("fh", 0)) / 1000.0 if flying else 0.0
	if goal != _fly_goal:
		_fly_down = goal < _fly_goal
	_fly_goal = goal
	vehicle = int(msg.get("v", 0))
	# Thousandths of a tile per tick; a tile is a metre.
	vehicle_speed = int(msg.get("vs", 0)) / 1000.0 * 60.0 * 3.6
	_update_body()
	_apply_night()
	if msg.has("m"):
		mining = int(msg["m"])
		mining_at = Vector2(int(msg.get("mx", 0)), int(msg.get("my", 0))) / 256.0
	else:
		mining = -1
	repairing = int(msg.get("rp", 0)) == 1
	if repairing:
		repair_at = Vector2(int(msg.get("rx", 0)), int(msg.get("ry", 0))) / 256.0


## The client asks the bridge to mine at `at` (the right button held on it).
func mine_hint(at: Vector2) -> void:
	if mine_hint_msec < 0 or at.distance_to(mine_hint_at) > 0.01:
		mine_hint_msec = Time.get_ticks_msec()
	mine_hint_at = at


func mine_hint_clear() -> void:
	mine_hint_msec = -1


## Where the character is mining for its sounds: the bridge's place while it reports mining, else
## the client's click for up to `window_msec` after it (the bridge's answer is on its way; a click
## out of reach gets no answer and goes quiet). Vector2(INF, INF) when not mining.
func mining_for_sound(window_msec := 800) -> Vector2:
	if mining >= 0:
		return mining_at
	if mine_hint_msec >= 0 and Time.get_ticks_msec() - mine_hint_msec < window_msec:
		return mine_hint_at
	return Vector2(INF, INF)


## Footfalls of the run cycle so far (character_anim.gd), for the steps' sounds.
func footfalls() -> int:
	return _anim.footfalls


# Read-only views of the drawn character for add-ons (api.character): nothing here changes what is
# drawn, and nothing is worked out until asked.

## The foot of the last footfall was the right one.
func foot_right() -> bool:
	return _anim.right_foot


## Where the run loop is, 0 to 1: 0 as the right foot comes down, 0.5 the left (0 without the rig).
func stride() -> float:
	return _anim._run_phase / TAU if _rig != null else 0.0


## The drawn body is off the ground, from the start of the take-off to the end of the landing (the
## game's flag without the rig, which draws no flight).
func in_air() -> bool:
	if _rig == null:
		return flying and vehicle == 0
	return _anim.air_state != CharacterAnim.Air.GROUND


## The body is drawn now: not in a vehicle, first person or on another surface's view.
func body_shown() -> bool:
	return visible and vehicle == 0 and not _first_person


## How fast the drawn character moves over the ground, in tiles a tick (Factorio's unit: plain running
## is 0.15), negative moving against its facing: the two `me`s it is drawn between, unsmoothed. 0
## standing, in a vehicle, or with fewer than two of them.
func drawn_speed() -> float:
	var n := _ticks.size()
	if vehicle != 0 or n < 2 or _clock.tick < 0.0:
		return 0.0
	var drawn := _clock.tick - _clock.gap * GameClock.DELAY_SENDS
	for i in range(1, n):
		if drawn <= _ticks[i]:
			if drawn < _ticks[i - 1]:
				return 0.0
			var step := _spots[i] - _spots[i - 1]
			var facing := -global_transform.basis.z
			return step.length() / (_ticks[i] - _ticks[i - 1]) * (-1.0 if step.dot(facing) < 0.0 else 1.0)
	return 0.0


## Which way the body faces for a `me`: an angled walk's line (`a`); else the 8-way direction,
## except that the line is kept while that direction is one of the two the zig-zag steps between
## (a message without `a` mid-walk, or stopping after one): otherwise the body, and the
## flashlight with it, would swing 22 degrees back and forth (owner's F7). A walk without an angle
## for ANGLE_HOLD ticks, or a direction off the line, ends it.
func _facing_yaw(msg: Dictionary) -> float:
	var k := float(msg.get("k", -1))
	if msg.has("a"):
		_line_yaw = -float(msg["a"]) / 1000.0 * TAU
		_line_tick = k
		return _line_yaw
	var d_yaw := Visuals.direction_yaw(int(msg.get("d", 0)))
	if is_nan(_line_yaw):
		return d_yaw
	var stale := walking and k >= 0.0 and _line_tick >= 0.0 and k - _line_tick > ANGLE_HOLD
	if stale or absf(wrapf(d_yaw - _line_yaw, -PI, PI)) > PI / 4.0 + 0.01:
		_line_yaw = NAN
		return d_yaw
	return _line_yaw


## Hides the body while the camera is inside it.
func set_first_person(on: bool) -> void:
	_first_person = on
	_update_body()


func _update_body() -> void:
	for node in _body:
		(node as Node3D).visible = vehicle == 0 and not _first_person
	if _holder != null:
		_holder.visible = vehicle == 0 and not _first_person


## N1: in a vehicle the character's lights go out, as Factorio draws nothing of a character in a
## vehicle, its lights neither; the vehicle's own lights shine instead (vehicle_lights.gd).
## --vehicle-lights=off keeps them on, as before.
static var vehicle_lights := Switches.on("--vehicle-lights")
var _night := 0.0


## `night`: 0 in daylight, 1 at full darkness.
func set_night(night: float) -> void:
	_night = night
	_apply_night()


## True while the character's own lights are out (in a vehicle, N1).
func lights_out() -> bool:
	return vehicle_lights and vehicle != 0


func _apply_night() -> void:
	var night := 0.0 if lights_out() else _night
	_lantern.light_energy = 1.8 * night
	_lantern.visible = night > 0.01
	var cone := beam(night)
	_flashlight.light_energy = (6.0 if flashlight_mode == "old" else BEAM_PEAK * _beam_gain) * cone
	_flashlight.visible = cone > 0.01


## How much of a cone light (the flashlight, locomotives' headlights) shows: Factorio switches them
## on above darkness 0.3 (`minimum_darkness`), faded in here instead of popping.
static func beam(night: float) -> float:
	return smoothstep(0.3, 0.5, night)


## The spot's energy for BEAM_PEAK on the ground (beam_texture() makes it): vehicle_lights.gd's cones.
static func beam_gain() -> float:
	beam_texture()
	return _beam_gain


## The flashlight's height over the ground under the character.
static func flashlight_height() -> float:
	return FLASHLIGHT_HEIGHT if flashlight_mode == "old" else BEAM_HEIGHT


static func _flashlight_mode() -> String:
	var mode := "new"
	for arg in Switches.args():
		if arg.begins_with("--flashlight="):
			mode = "old" if arg.get_slice("=", 1) == "old" else "new"
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		mode = "old"
	return mode


## The new flashlight's axes in the character's frame (forward is -Z): across, the spot's up, and
## where it points (rotation.x = -BEAM_PITCH).
static func _beam_axes() -> Array[Vector3]:
	var p := deg_to_rad(BEAM_PITCH)
	return [Vector3.RIGHT, Vector3(0.0, cos(p), -sin(p)), Vector3(0.0, -sin(p), -cos(p))]


## Where a point in the character's frame (x across, y up from the ground under it, -z ahead) falls in
## the new flashlight's picture, as Godot's scene shader projects a spot's picture: through the
## spot's perspective, BEAM_ANGLE each way, the picture's top towards the spot's up. (-1, -1) behind it.
static func beam_uv(p: Vector3) -> Vector2:
	var axes := _beam_axes()
	var v := p - Vector3(0.0, BEAM_HEIGHT, 0.0)
	var along := v.dot(axes[2])
	if along <= 0.001:
		return Vector2(-1.0, -1.0)
	var t := tan(deg_to_rad(BEAM_ANGLE)) * along
	return Vector2(0.5 + 0.5 * v.dot(axes[0]) / t, 0.5 - 0.5 * v.dot(axes[1]) / t)


## The light the new flashlight's spot itself puts on a surface at `p` (the character's frame) facing
## `normal`, per unit of energy and before its picture: Godot's fall-off (the range's window, no decay,
## the cone's edge to the power BEAM_EDGE) and the surface's slant to the spot.
static func beam_spot_light(p: Vector3, normal := Vector3.UP) -> float:
	var to := p - Vector3(0.0, BEAM_HEIGHT, 0.0)
	var d := to.length()
	if d < 0.001:
		return 0.0
	var window := pow(maxf(1.0 - pow(d / BEAM_RANGE, 4.0), 0.0), 2.0)
	var edge := cos(deg_to_rad(BEAM_ANGLE))
	var scos := maxf(to.dot(_beam_axes()[2]) / d, edge)
	var rim := maxf(1e-4, (1.0 - scos) / (1.0 - edge))
	return window * (1.0 - pow(rim, BEAM_EDGE)) * maxf(0.0, normal.dot(-to / d))


## Factorio's flashlight picture, core/graphics/light-cone.png from the install (LA8, its light in
## alpha), or without one a cone drawn to its measure: the point 0.2 tiles ahead, the sides 25 degrees
## off the middle with half a tile of blur, the light 1.07 less 0.043 a tile ahead (its rows).
static func cone_picture() -> Image:
	var dir := ItemIcons.factorio_data_dir()
	var path := dir.path_join("core/graphics/light-cone.png")
	if dir != "" and FileAccess.file_exists(path):
		var image := Image.load_from_file(path)
		if image != null and not image.is_empty() and image.get_width() == image.get_height():
			image.convert(Image.FORMAT_LA8)
			return image
	var side := 200
	var px := side / CONE_TILES
	var data := PackedByteArray()
	data.resize(side * side * 2)
	for y in side:
		var ahead := CONE_AHEAD + CONE_TILES * 0.5 - (y + 0.5) / px
		var light := clampf(1.07 - 0.043 * ahead, 0.0, 1.0)
		var half := 0.466 * (ahead - 0.2)
		for x in side:
			var across := absf((x + 0.5) / px - CONE_TILES * 0.5)
			var b := 0 if half <= 0.0 else roundi(light * clampf((half - across) / 0.5 + 0.5, 0.0, 1.0) * 255.0)
			data[(y * side + x) * 2] = b
			data[(y * side + x) * 2 + 1] = b
	return Image.create_from_data(side, side, false, Image.FORMAT_LA8, data)


## Factorio's light at a ground point `ahead` tiles in front of the character and `across` to its
## side, 0 to 1, from the picture's alpha (`data`: an LA8 picture `side` pixels square).
static func cone_at(data: PackedByteArray, side: int, ahead: float, across: float) -> float:
	if ahead < BEAM_NEAREST:
		return 0.0
	var px := side / CONE_TILES
	var u := (across + CONE_TILES * 0.5) * px - 0.5
	var v := (CONE_AHEAD + CONE_TILES * 0.5 - ahead) * px - 0.5
	var x0 := floori(u)
	var y0 := floori(v)
	if x0 < -1 or y0 < -1 or x0 >= side or y0 >= side:
		return 0.0
	var a := [0.0, 0.0, 0.0, 0.0]
	for k in 4:
		var x := x0 + (k & 1)
		var y := y0 + (k >> 1)
		if x >= 0 and y >= 0 and x < side and y < side:
			a[k] = data[(y * side + x) * 2 + 1] / 255.0
	var fx := u - x0
	var fy := v - y0
	return lerpf(lerpf(a[0], a[1], fx), lerpf(a[2], a[3], fx), fy)


## The new flashlight's picture: for each texel, the ground point its ray from the spot meets,
## Factorio's light there over the light the spot itself puts there (beam_spot_light), so that the
## ground gets the picture's own fade; 1 at its brightest (_beam_gain puts that back in the spot's
## energy), stored as sRGB, as Godot reads a projector. The picture is the same either side: half is
## worked out and mirrored. Made once (about 9,000 rays).
static func beam_texture() -> ImageTexture:
	if _beam_texture != null:
		return _beam_texture
	var picture := cone_picture()
	var side := picture.get_width()
	var data := picture.get_data()
	var n := BEAM_MASK_SIZE
	var ratio := PackedFloat32Array()
	ratio.resize(n * n)
	var axes := _beam_axes()
	var t := tan(deg_to_rad(BEAM_ANGLE))
	var from := Vector3(0.0, BEAM_HEIGHT, 0.0)
	var most := 0.0
	for j in n:
		var up := (1.0 - 2.0 * (j + 0.5) / n) * t
		for i in range(n >> 1, n):
			var ray: Vector3 = axes[0] * ((2.0 * (i + 0.5) / n - 1.0) * t) + axes[1] * up + axes[2]
			if ray.y > -0.001:
				continue
			var ground := from + ray * (BEAM_HEIGHT / -ray.y)
			var want := cone_at(data, side, -ground.z, ground.x)
			if want <= 0.0:
				continue
			var own := beam_spot_light(ground)
			if own < 0.001:
				continue
			var r := want / own
			ratio[j * n + i] = r
			ratio[j * n + n - 1 - i] = r
			if want > 0.05:
				most = maxf(most, r)
	most = maxf(most, 0.001)
	var out := PackedByteArray()
	out.resize(n * n * 3)
	for k in n * n:
		var lin := clampf(ratio[k] / most, 0.0, 1.0)
		var s := lin * 12.92 if lin <= 0.0031308 else 1.055 * pow(lin, 1.0 / 2.4) - 0.055
		var b := roundi(s * 255.0)
		out[k * 3] = b
		out[k * 3 + 1] = b
		out[k * 3 + 2] = b
	_beam_image = Image.create_from_data(n, n, false, Image.FORMAT_RGB8, out)
	var mipped := _beam_image.duplicate() as Image
	mipped.generate_mipmaps()  # Godot's projector reads mipmaps (rendering/textures/light_projectors/filter)
	_beam_texture = ImageTexture.create_from_image(mipped)
	_beam_gain = most
	return _beam_texture


## The light the new flashlight puts on a surface at `p` (the character's frame) facing `normal`, as
## Godot would draw it at full darkness: its energy, the picture's texel there (bilinear, read as
## sRGB) and the spot's own fall-off. For the tests.
static func beam_light_at(p: Vector3, normal := Vector3.UP) -> float:
	beam_texture()
	var uv := beam_uv(p)
	if uv.x < 0.0 or uv.y < 0.0 or uv.x > 1.0 or uv.y > 1.0:
		return 0.0
	var n := _beam_image.get_width()
	var u := uv.x * n - 0.5
	var v := uv.y * n - 0.5
	var x0 := clampi(floori(u), 0, n - 1)
	var y0 := clampi(floori(v), 0, n - 1)
	var x1 := mini(x0 + 1, n - 1)
	var y1 := mini(y0 + 1, n - 1)
	var fx := clampf(u - x0, 0.0, 1.0)
	var fy := clampf(v - y0, 0.0, 1.0)
	var top := lerpf(_beam_image.get_pixel(x0, y0).srgb_to_linear().r, _beam_image.get_pixel(x1, y0).srgb_to_linear().r, fx)
	var bottom := lerpf(_beam_image.get_pixel(x0, y1).srgb_to_linear().r, _beam_image.get_pixel(x1, y1).srgb_to_linear().r, fx)
	return BEAM_PEAK * _beam_gain * lerpf(top, bottom, fy) * beam_spot_light(p, normal)


func ground_position() -> Vector2:
	return Vector2(position.x, position.z)


## How far the body is drawn over the ground under it, flying in mech armour (tiles; 0 otherwise).
## (1.7) Plus the add-ons' lift and the belt step-up (lifted().y). The camera follows view_lift().
func drawn_lift() -> float:
	return _flight_lift() + lifted().y


## How far the camera's centre rises over the ground (camera_rig.gd): flight, and only the add-ons'
## lifts set with `camera` (camera_lift()); the belt step-up never moves it.
func view_lift() -> float:
	return _flight_lift() + camera_lift().y


func _flight_lift() -> float:
	return _anim.drawn_lift() if _rig != null and vehicle == 0 else 0.0


## (1.7) The add-ons' lift (addon_host.gd), capped, and its camera part. Drawn only: nothing reads
## them to act.
func set_lifted(v: Vector3, view := Vector3.ZERO) -> void:
	_lifted = cap_lift(v)
	_view_lifted = cap_lift(view)
	_fit_box()


## The body's lift as drawn now: the add-ons' and the belt step-up together, capped; zero in a
## vehicle or dead (the add-ons' kept, and drawn again after).
func lifted() -> Vector3:
	if vehicle != 0 or (_has_state and health <= 0):
		return Vector3.ZERO
	return lift_total()


## The add-ons' lift and the belt step-up together, capped, as lifted() draws them on foot (kept in a
## vehicle or dead): api.character.state()'s `lift`.
func lift_total() -> Vector3:
	return cap_lift(_lifted + Vector3(0.0, _stand, 0.0)) if _stand > 0.0 else _lifted


## The camera's part of lifted(): the add-ons' lifts set with `camera`, never the belt step-up.
func camera_lift() -> Vector3:
	if vehicle != 0 or (_has_state and health <= 0):
		return Vector3.ZERO
	return _view_lifted


## The belt step-up as drawn now (tiles), 0 off a belt.
func stand_lift() -> float:
	return _stand


## Settings > Graphics > Step onto belts, unless `--belt-step=off`. Read once and again when a graphics
## setting changes, not each frame.
static func belt_step() -> bool:
	if not belt_step_switch:
		return false
	if _belt_step < 0:
		_read_belt_step("graphics", "belt_step")
		Settings.listen(_read_belt_step)
	return _belt_step == 1


static func _read_belt_step(section: String, _key: String) -> void:
	if section == "graphics":
		_belt_step = 1 if bool(Settings.get_value("graphics", "belt_step")) else 0


## The belt step-up eased towards the top of what the drawn body stands on: looked up only when the
## drawn place moved since the last look. None flying (mech armour), in a vehicle or dead.
func _step_onto(delta: float) -> void:
	var goal := 0.0
	if belt_step() and world != null and vehicle == 0 and not flying and not (_has_state and health <= 0):
		var at := Vector2(position.x, position.z)
		if at != _stand_at:
			_stand_at = at
			if _stand_height == null:
				_stand_height = load("res://scripts/world/stand_height.gd")
			_stand_goal = minf(_stand_height.at(world, at, _stand_height.BELTS), STAND_MAX)
			stand_lookups += 1
		goal = _stand_goal
	else:
		_stand_at = Vector2.INF  # looked up again when it is back on
	if _stand == goal:
		return
	var was_up := _stand > 0.0
	_stand = lerpf(_stand, goal, 1.0 - exp(-delta * (STEP_UP_RATE if goal > _stand else STEP_DOWN_RATE)))
	if absf(_stand - goal) < 0.002:
		_stand = goal
	if (_stand > 0.0) != was_up:
		_fit_box()


## The body's culling box: the pose's room (a raised pickaxe, lying dead, flying), grown by the lift
## only while one is set (the add-ons' and the step-up's most), written only when that changes.
func _fit_box() -> void:
	if _rig == null:
		return
	# The offset turns with the body (_own_frame), so the box grows by its length every way across.
	var across := Vector2(_lifted.x, _lifted.z).length()
	var up := Vector3(across, _lifted.y + (STAND_MAX if _stand > 0.0 else 0.0), across)
	if up == _box_for:
		return
	_box_for = up
	_rig.custom_aabb = AABB(Vector3(-2 - across, -1, -2 - across), Vector3(4 + 2 * across, 8.0 + up.y, 4 + 2 * across))


## A lift within the caps: height 0 to LIFT_MAX, across at most OFFSET_MAX; not-a-number counts as 0.
static func cap_lift(v: Vector3) -> Vector3:
	var up := 0.0 if is_nan(v.y) else clampf(v.y, 0.0, LIFT_MAX)
	var across := Vector2(0.0 if is_nan(v.x) else v.x, 0.0 if is_nan(v.z) else v.z)
	# Clamped first: an infinite offset would make limit_length's answer not-a-number.
	across = across.clamp(-Vector2.ONE * OFFSET_MAX, Vector2.ONE * OFFSET_MAX).limit_length(OFFSET_MAX)
	return Vector3(across.x, up, across.y)


## A world-space lift in the avatar's own (turned) frame, where its lights and pose are placed.
func _own_frame(v: Vector3) -> Vector3:
	return v.rotated(Vector3.UP, -rotation.y)


## Remembers a sent position at game tick `k` (none when the message has no tick: then the avatar
## just follows the newest).
func _sample(k: float, at: Vector3, angle := -1.0) -> void:
	if k < 0.0:
		_ticks.clear()
		_spots.clear()
		_angles.clear()
		return
	var n := _ticks.size()
	if n > 0 and k < _ticks[n - 1]:
		_clock = GameClock.new()  # the game went back (a save loaded)
	if n > 0 and (at.distance_to(_spots[n - 1]) > 8.0 or k - _ticks[n - 1] > 60.0 or k < _ticks[n - 1]):
		_ticks.clear()  # a teleport, a new surface or a long gap: start again from here
		_spots.clear()
		_angles.clear()
		_smooth_set = false
		n = 0
	if n > 0 and k == _ticks[n - 1]:
		_spots[n - 1] = at
		_angles[n - 1] = angle
		return
	_clock.heard(k)
	_ticks.append(k)
	_spots.append(at)
	_angles.append(angle)
	if _ticks.size() > 8:
		_ticks.remove_at(0)
		_spots.remove_at(0)
		_angles.remove_at(0)


## Where the avatar is drawn now: between the sent positions around the clock's drawn tick, else
## the newest.
func _drawn_target(delta: float) -> Vector3:
	var drawn := _clock.advance(delta)
	var n := _ticks.size()
	_drawn_angle = -1.0
	if n < 2:
		return _target
	if drawn <= _ticks[0]:
		return _spots[0]
	for i in range(1, n):
		if drawn <= _ticks[i]:
			# The stretch walks at an angle only when both ends do (a stop or start draws as it is).
			if _angles[i - 1] >= 0.0 and _angles[i] >= 0.0:
				_drawn_angle = _angles[i]
			return _spots[i - 1].lerp(_spots[i], (drawn - _ticks[i - 1]) / (_ticks[i] - _ticks[i - 1]))
	return _spots[n - 1]


## The drawn position `goal` with the sideways zig-zag of an angled walk taken out: each frame's
## sideways step goes into an offset that fades at SIDE_RATE (FOLLOW_RATE without an angle).
func _along_line(goal: Vector3, delta: float) -> Vector3:
	if not _smooth_set or goal.distance_to(_last_goal) > 2.0:
		_offset = Vector3.ZERO
		_last_goal = goal
		_smooth_set = true
		return goal
	var moved := goal - _last_goal
	_last_goal = goal
	if _drawn_angle >= 0.0:
		var rad := _drawn_angle * TAU
		var heading := Vector3(sin(rad), 0.0, -cos(rad))
		_offset -= moved - heading * moved.dot(heading)
		_offset -= heading * _offset.dot(heading)
		_offset *= exp(-delta * SIDE_RATE)
	else:
		_offset *= exp(-delta * FOLLOW_RATE)
	_offset = _offset.limit_length(MAX_OFF)
	return goal + _offset


func _process(delta: float) -> void:
	var t := 1.0 - exp(-delta * FOLLOW_RATE)
	var goal := _along_line(_drawn_target(delta), delta)
	position = goal if _ticks.size() >= 2 and position.distance_to(goal) < 2.0 else position.lerp(goal, t)
	rotation.y = lerp_angle(rotation.y, _body_yaw(), t)
	_aim_flashlight()
	_step_onto(delta)
	_lift_lights()
	if _rig != null:
		_animate(delta)
	if not _attached.is_empty():
		_place_attached()


## K3 (owner: "flashlight should follow the mouse in first person"): in first person the flashlight
## turns to where the crosshair looks (the camera's heading; the mouse turns the camera there), not
## where the body faces; the cone stays Factorio's, on the ground ahead of that heading. Otherwise
## it faces with the body. What the crosshair picks (player_input.gd) isn't touched.
func _aim_flashlight() -> void:
	var yaw := 0.0
	if _first_person and is_inside_tree():
		var cam := get_viewport().get_camera_3d()
		if cam != null:
			var ahead := -cam.global_transform.basis.z
			if Vector2(ahead.x, ahead.z).length() > 0.01:
				yaw = wrapf(atan2(-ahead.x, -ahead.z) - global_rotation.y, -PI, PI)
	_flashlight.rotation.y = yaw


## The lantern and flashlight over the hills under the character (one height read a frame), and with
## an add-on's lift (1.7): the lantern and the old flashlight rise with the body; the new flashlight is
## Factorio's picture cast from BEAM_HEIGHT, so it only moves across (raised, it would stretch).
func _lift_lights() -> void:
	var up := lifted()
	lift = GroundHeight.at(position.x + up.x, position.z + up.z)
	var across := _own_frame(Vector3(up.x, 0.0, up.z))
	_lantern.position = Vector3(across.x, LANTERN_HEIGHT + lift + up.y, across.z)
	var beam_up := up.y if flashlight_mode == "old" else 0.0
	_flashlight.position = Vector3(across.x, flashlight_height() + lift + beam_up, across.z)
	if _rig == null:
		var own := _own_frame(up)
		for i in _body.size():
			(_body[i] as Node3D).position = _body_at[i] + own


## Which way the legs face: where the character walks, except while shooting, when it faces
## the target standing, and runs backwards rather than twist round further than its waist can.
func _body_yaw() -> float:
	if not (firing and aim_target != null):
		return _yaw_goal
	var to: Vector3 = aim_target - position
	var aim_yaw := atan2(-to.x, -to.z)
	if not walking:
		return aim_yaw
	if absf(wrapf(aim_yaw - _yaw_goal, -PI, PI)) > CharacterAnim.MAX_TWIST + 0.35:
		return _yaw_goal + PI
	return _yaw_goal


## The skeleton's pose for this frame (character_anim.gd), and the tool in the hand.
func _animate(delta: float) -> void:
	var moved := Vector3(position.x - _last.x, 0.0, position.z - _last.z)
	_last = position
	if moved.length() > 1.0:
		moved = Vector3.ZERO  # a teleport (snap_to, a new surface)
	var facing := -global_transform.basis.z
	var distance := moved.dot(facing.normalized())
	_anim.running = walking
	_anim.mining = mining >= 0 or repairing
	_anim.firing = firing
	_anim.aiming = firing and aim_target != null
	_anim.dead = _has_state and health <= 0
	_anim.aim_twist = 0.0
	if aim_target != null:
		var to: Vector3 = aim_target - position
		_anim.aim_twist = wrapf(atan2(-to.x, -to.z) - rotation.y, -PI, PI)
	if _demo != "":
		delta *= _demo_rate
		distance = _demo_state(delta)
	_fly_h += (_fly_goal - _fly_h) * (1.0 - exp(-delta * FLY_RATE))
	if _fly_goal <= 0.0 and _fly_h < 0.002:
		_fly_h = 0.0
	_anim.flying = flying and vehicle == 0
	_anim.flight_height = _fly_h
	_anim.descending = _fly_down
	_anim.extra_offset = _own_frame(lifted())
	_anim.step(_pose, delta, distance)
	_update_jets()
	var rows := _pose.rows()
	for m in _materials:
		m.set_shader_parameter("rig_bone", rows)
	var shown := vehicle == 0 and not _first_person
	_pickaxe.visible = _anim.pickaxe_shown and shown and not tools_hidden
	_gun.visible = _anim.gun_shown and shown and not tools_hidden
	var grip := Transform3D(Basis.IDENTITY, GRIP)
	if _pickaxe.visible:
		# The handle carries on from the forearm, angled forwards: down past the knee at rest,
		# behind the head with the arm raised, into the ground at the strike.
		_pickaxe.transform = _pose.frame("forearm_r", grip * Transform3D(Basis(Vector3.RIGHT, PICK_ANGLE), Vector3.ZERO))
	if _gun.visible:
		# The barrel along the forearm (pointing down at rest), its top facing forwards.
		_gun.transform = _pose.frame("forearm_r", grip * Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3.ZERO))


## A shot going off (weapon_fx.gd, on each `shot`): the gun kicks back.
func kick(strength := 1.0) -> void:
	_anim.kick(strength)


## Where shots leave the gun (world): muzzle flashes, beams, projectiles' first height.
func muzzle_position() -> Vector3:
	if not _addon_muzzle.is_empty():
		var n = _addon_muzzle[0]
		if is_instance_valid(n) and (n as Node3D).is_inside_tree():
			return (n as Node3D).global_transform * (_addon_muzzle[1] as Vector3)
	return _own_muzzle()


## Zenith's own muzzle, without an add-on's (set_addon_muzzle).
func _own_muzzle() -> Vector3:
	if _mech and _pose != null:
		# The mech's right forearm is its gun: its bone ends at the muzzle.
		return global_transform * _pose.point("forearm_r", _pose.tail_of("forearm_r"))
	if _gun != null and _gun.visible:
		return _gun.global_transform * MUZZLE
	return position + Vector3(0, 1.1, 0) + lifted()


# --- (Add-on API 1.7) attachments, frames, the pose layer, the muzzle and tools (api.character) ---

## Zenith's own pickaxe and gun not drawn (api.character.hide_tools: the add-on draws its own).
var tools_hidden := false
## An add-on's muzzle (api.character.set_muzzle): [node, point in the node's frame]; [] for Zenith's.
var _addon_muzzle: Array = []
## Add-ons' nodes kept at a bone or point (attach_node): [node, name, offset, rig bone ("" for none),
## rest frame]. Drawn from a holder made on the first attach, hidden with the body.
var _attached: Array = []
var _holder: Node3D
## The add-ons' pose layer as the host gave it (API bone names), kept to map it again on a new rig.
var _layer_src: Array = []
## The plain look's rig at rest, for the capsule stand-in (no character model in this build).
static var _plain_rest: CharacterPose = null


## Keeps `node` at the bone or point `name` (CharacterPoints), `offset` in its frame, drawn from this
## frame on. False for an unknown name (`view` is the camera's: addon_host.gd).
func attach_node(node: Node3D, name: String, offset := Transform3D.IDENTITY) -> bool:
	if not CharacterPoints.is_name(name) or name == "view" or node == null:
		return false
	detach_node(node)
	if _holder == null:
		_holder = Node3D.new()
		_holder.name = "AddonAttached"
		add_child(_holder)
		_update_body()
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	_holder.add_child(node)
	_own_layer(node)  # (F7) the lantern's shadows don't see it, as they don't see the body
	_attached.append([node, name, offset, "", Transform3D.IDENTITY])
	_refit_attached()
	_place_attached()
	return true


## Hands `node` back out of the tree, not freed.
func detach_node(node: Node3D) -> void:
	for i in range(_attached.size() - 1, -1, -1):
		if _attached[i][0] == node:
			_attached.remove_at(i)
	if node != null and is_instance_valid(node) and _holder != null and node.get_parent() == _holder:
		_holder.remove_child(node)


## The rig bone and rest frame of every attached name, for the look drawn now (on attach and when
## set_armor swaps the rig).
func _refit_attached() -> void:
	var pose := _rest_pose()
	for e: Array in _attached:
		var r := CharacterPoints.rest(pose, look, str(e[1])) if pose != null else []
		e[3] = str(r[0]) if r.size() == 2 else ""
		e[4] = (r[1] as Transform3D) if r.size() == 2 else Transform3D.IDENTITY


## The pose the rest places come from: the drawn rig's, or the plain look's for the capsule.
func _rest_pose() -> CharacterPose:
	if _pose != null:
		return _pose
	if _plain_rest == null:
		var p := CharacterPose.new()
		if p.load_rig(BODY_MODEL):
			p.compute()
			_plain_rest = p
	return _plain_rest


## A name's frame in the avatar's own frame as drawn now: the pose (the lift is in its root), and
## the hills under the character, which the body gets in its shader and an add-on's node doesn't.
func _local_frame(name: String, rig_bone: String, rest: Transform3D) -> Transform3D:
	var hill := Transform3D(Basis.IDENTITY, Vector3(0.0, lift, 0.0))
	if name == "muzzle":
		return hill * Transform3D(Basis.IDENTITY, global_transform.affine_inverse() * _own_muzzle())
	if rig_bone == "":
		return hill * Transform3D(Basis.IDENTITY, _own_frame(lifted()))
	if _pose != null and _rig != null:
		return hill * _pose.frame(rig_bone, rest)
	return hill * Transform3D(Basis.IDENTITY, _own_frame(lifted())) * rest


func _place_attached() -> void:
	for e: Array in _attached:
		var n = e[0]
		if is_instance_valid(n):
			(n as Node3D).transform = _local_frame(str(e[1]), str(e[3]), e[4]) * (e[2] as Transform3D)


## A bone's or point's frame in the world as drawn now; null for an unknown name (and `view`, the
## camera's).
func frame_of(name: String):
	if not CharacterPoints.is_name(name) or name == "view":
		return null
	var pose := _rest_pose()
	var r := CharacterPoints.rest(pose, look, name) if pose != null else []
	var bone := str(r[0]) if r.size() == 2 else ""
	var rest: Transform3D = r[1] if r.size() == 2 else Transform3D.IDENTITY
	return global_transform * _local_frame(name, bone, rest)


## What the rig is: mech or not, head_top's height at rest (for scaling), the names.
func rig_info() -> Dictionary:
	var pose := _rest_pose()
	var r := CharacterPoints.rest(pose, look, "head_top") if pose != null else []
	return {"mech": _mech, "height": (r[1] as Transform3D).origin.y if r.size() == 2 else 0.0,
		"bones": CharacterPoints.BONES.keys(), "points": CharacterPoints.POINTS.duplicate()}


## The add-ons' pose layer (addon_host.gd, start order): [API bone name, turn, weight, replace], mapped
## to the rig's bone indices here, when set and when the rig is swapped, never per frame.
func set_pose_layer(entries: Array) -> void:
	_layer_src = entries
	var out: Array = []
	for e: Array in entries:
		var bone: String = CharacterPoints.BONES.get(str(e[0]), "")
		if _pose != null and _pose.index.has(bone):
			out.append([int(_pose.index[bone]), e[1], e[2], e[3]])
	_anim.layer = out


## An add-on's muzzle: shots start at `at` in `node`'s frame while it is in the tree; null: Zenith's.
func set_addon_muzzle(node: Node3D, at := Vector3.ZERO) -> void:
	_addon_muzzle = [node, at] if node != null else []


## Thruster smoke and a small flame under each foot while the thrusters burn (CharacterAnim.thrust).
func _update_jets() -> void:
	var burn := _anim.thrust if vehicle == 0 and visible else 0.0
	if burn <= 0.01 and _jets.is_empty():
		return
	if _jets.is_empty():
		for side in ["_r", "_l"]:
			_jets.append(_make_jet(side))
	for jet in _jets:
		var side: String = jet["side"]
		var foot := _pose.point("shin" + side, _pose.tail_of("shin" + side))
		var at := global_transform * foot + Vector3(0.0, lift, 0.0)
		var smoke: CPUParticles3D = jet["smoke"]
		smoke.global_position = at
		smoke.emitting = burn > 0.05
		var flame: MeshInstance3D = jet["flame"]
		flame.visible = burn > 0.05 and not _first_person
		var flicker := 0.85 + 0.15 * sin(Time.get_ticks_msec() * 0.047 + (0.0 if side == "_r" else 2.0))
		flame.scale = Vector3(1.0, burn * flicker, 1.0)
		# The cone's mesh is centred: hang it from the sole.
		flame.global_position = at - Vector3(0.0, 0.225 * burn * flicker, 0.0)


static var _puff: QuadMesh = null
static func _jet_puff() -> QuadMesh:
	if _puff == null:
		_puff = QuadMesh.new()
		_puff.size = Vector2(0.22, 0.22)
		_puff.material = Rockets._puff_mesh().material
	return _puff


func _make_jet(side: String) -> Dictionary:
	var smoke := CPUParticles3D.new()
	smoke.amount = 24
	smoke.lifetime = 50.0 / 60.0
	smoke.local_coords = false
	smoke.emitting = false
	smoke.direction = Vector3(0, -1, 0)
	smoke.spread = 25.0
	smoke.initial_velocity_min = 1.5
	smoke.initial_velocity_max = 3.0
	smoke.gravity = Vector3(0, 0.6, 0)
	smoke.damping_min = 3.0
	smoke.damping_max = 4.0
	# Factorio's puff grows from 0.1 to 0.3 of its picture; a small quad of its own, growing.
	smoke.scale_amount_min = 0.8
	smoke.scale_amount_max = 1.2
	var grow := Curve.new()
	grow.max_value = 3.0
	grow.add_point(Vector2(0.0, 1.0))
	grow.add_point(Vector2(1.0, 3.0))
	smoke.scale_amount_curve = grow
	smoke.mesh = _jet_puff()
	var fade := Gradient.new()
	fade.set_color(0, Color(0.6, 0.6, 0.6, 0.55))
	fade.set_color(1, Color(0.5, 0.5, 0.5, 0.0))
	smoke.color_ramp = fade
	smoke.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(smoke)
	# The flame: a short glowing cone pointing down, its length the thrust.
	var flame := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.09
	cone.bottom_radius = 0.0
	cone.height = 0.45
	cone.radial_segments = 8
	cone.rings = 1
	flame.mesh = cone
	var hot := StandardMaterial3D.new()
	hot.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hot.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	hot.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	hot.albedo_color = Color(1.0, 0.62, 0.25, 0.8)
	hot.cull_mode = BaseMaterial3D.CULL_DISABLED
	flame.material_override = hot
	flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(flame)
	return {"side": side, "smoke": smoke, "flame": flame}


func _demo_state(delta: float) -> float:
	_demo_t += delta
	var t := _demo_t
	if _demo in ["hover", "fly", "flyloop"]:
		# Factorio's own rates (measured): up 1/32 tile a tick, down 3/64, flying until it touches down.
		var up := _demo != "flyloop" or (fposmod(t, 4.0) > 1.0 and fposmod(t, 4.0) < 3.0)
		_fly_down = not up
		_fly_goal = clampf(_fly_goal + (1.0 / 32.0 if up else -3.0 / 64.0) * delta * 60.0, 0.0, 1.0)
		flying = up or _fly_goal > 0.0
		_anim.running = _demo == "fly"
		return DEMO_SPEED * delta if _demo == "fly" else 0.0
	if _demo == "stop":
		_anim.running = fposmod(t, 2.0) < 1.2
		return DEMO_SPEED * delta if _anim.running else 0.0
	if _demo in ["walk", "exo", "back"]:
		_anim.running = true
		var speeds := {"walk": 0.5, "exo": 3.0, "back": -0.7}
		return DEMO_SPEED * float(speeds[_demo]) * delta
	_anim.running = _demo in ["run", "runaim", "runready"]
	_anim.mining = _demo == "mine"
	_anim.aiming = _demo in ["aim", "runaim"]
	_anim.firing = _anim.aiming or (_demo in ["ready", "runready"] and Time.get_ticks_msec() < 2000)
	_anim.aim_twist = 0.6 if _demo == "runaim" else 0.0
	_anim.dead = _demo == "dead"
	return DEMO_SPEED * delta if _anim.running else 0.0
