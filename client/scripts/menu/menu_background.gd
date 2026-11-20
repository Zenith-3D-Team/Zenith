extends Node3D
## The main menu's background, like Factorio's live menu simulations: a small factory drawn by the
## client's own world renderer. The default (res://data/menu_world.json) is a snapshot recorded for
## Zenith in a vanilla Space Age game, cleaned for release by tools/make_menu_backdrop.py:
## prototypes, chunks and entities are applied once, and the live updates (moving things, items on
## belts, inserter hands) are replayed in a loop, with the camera held at the view it was taken from.
## No server. Or one of the player's own snapshots (backdrop_recorder.gd; the list in user://backdrops/,
## backdrop_list.gd; Settings interface/backdrop names the one in use): the same kind of file. A file without a camera (the mock's recording the default
## was before 0.2.2, client/tests/data/mock_menu_world.json) gets a camera drifting slowly over it.

const WorldMirror := preload("res://scripts/world/world.gd")
const PipelineWarm := preload("res://scripts/world/pipeline_warm.gd")
const MoverLayer := preload("res://scripts/world/movers.gd")
const BeltItemLayer := preload("res://scripts/world/belt_items.gd")
const GroundItemLayer := preload("res://scripts/world/ground_items.gd")
const InserterArmLayer := preload("res://scripts/world/inserter_arms.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const BackdropRecorder := preload("res://scripts/menu/backdrop_recorder.gd")
const BackdropList := preload("res://scripts/menu/backdrop_list.gd")
const Looks := preload("res://scripts/world/looks.gd")
const Visuals := preload("res://scripts/world/visuals.gd")

const DATA := "res://data/menu_world.json"
const LIVE := ["mv", "bs", "ih", "gi"]
const DRIFT_SPEED := 0.035
## A saved view turns this far either way round the spot it looks at, slowly.
const SWAY_DEGREES := 3.0
const SWAY_SPEED := 0.12
const FACTORY_TYPES := ["assembling-machine", "furnace", "transport-belt", "inserter", "mining-drill",
	"boiler", "generator", "lab", "container", "electric-pole", "splitter", "underground-belt"]

var world: WorldMirror
var camera := Camera3D.new()

var _movers: MoverLayer
var _belt_items: BeltItemLayer
var _arms: InserterArmLayer
var _ground_items: GroundItemLayer
var _live: Array = []  # [seconds, message], in order
var _length := 1.0
var _clock := 0.0
var _next := 0
var _loop := 0
var _tick_span := 0
var _center := Vector2.ZERO
var _time := 0.0
var _env: Environment
var _fill: DirectionalLight3D = null  # the look's fill light (lighting-fixes step 6, Looks.put_noon_fill)
## What is shown: "default" (DATA) or "snapshot".
var source := "default"
## The file's camera (Transform3D), or null: the drift over the world.
var _view: Variant = null

## The file the old setting "snapshot" names: the one snapshot before 0.2.2 (backdrop_list.gd moves it
## into the list; the tests name their own).
static var snapshot_path := BackdropRecorder.PATH
## --menu-backdrop=default: the built-in world whatever the setting says.
static var force_default := Settings.arg_value("--menu-backdrop=") == "default"
## --menu-backdrop-camera=drift: the default's camera drifts over it as before 0.2.2, not at its saved view.
static var camera_drift := Settings.arg_value("--menu-backdrop-camera=") == "drift"


## The snapshot is asked for (the setting, not overruled by --menu-backdrop=default).
static func wants_snapshot() -> bool:
	return chosen_path() != ""


## The file of the snapshot the setting names, "" for the built-in one.
static func chosen_path() -> String:
	if force_default:
		return ""
	var v := BackdropList.in_use()
	if v == BackdropList.DEFAULT:
		return ""
	return snapshot_path if v == BackdropList.OLD_SETTING else BackdropList.path_of(v)


func _ready() -> void:
	_build_environment()
	world = WorldMirror.new()
	world.name = "MenuWorld"
	world.view_radius = 2
	add_child(world)
	_movers = MoverLayer.new()
	_movers.protos = world.protos
	add_child(_movers)
	_belt_items = BeltItemLayer.new()
	_belt_items.protos = world.protos
	add_child(_belt_items)
	_arms = InserterArmLayer.new()
	_arms.protos = world.protos
	_arms.world = world
	_arms.belts = _belt_items
	add_child(_arms)
	_ground_items = GroundItemLayer.new()
	_ground_items.protos = world.protos
	add_child(_ground_items)

	camera.fov = 35.0
	camera.near = 0.5
	camera.far = 1000.0
	add_child(camera)
	camera.make_current()
	_load()


func _load() -> void:
	var parsed = null
	BackdropList.migrate()
	var chosen := chosen_path()
	if chosen != "":
		var snap := BackdropRecorder.read(chosen)
		if snap.is_empty():
			print("menu: the backdrop snapshot %s is missing or can't be read: the built-in backdrop instead" % chosen)
		else:
			parsed = snap
			source = "snapshot"
	if parsed == null:
		parsed = JSON.parse_string(FileAccess.get_file_as_string(DATA)) if FileAccess.file_exists(DATA) else null
	if not (parsed is Dictionary):
		return
	if source == "snapshot" or not camera_drift:
		_view = BackdropRecorder.camera_transform(parsed.get("camera"))
	var cam = parsed.get("camera")
	if _view != null:
		camera.fov = clampf(float(cam.get("fov", camera.fov)), 5.0, 120.0)
		if str(cam.get("proj", "")) == "orthogonal":
			camera.projection = Camera3D.PROJECTION_ORTHOGONAL
			camera.size = maxf(1.0, float(cam.get("size", camera.size)))
	_movers.puppet_unit = int(parsed.get("puppet", 0))
	var center: Array = parsed.get("center", [0, 0])
	_center = Vector2(float(center[0]), float(center[1]))
	world.set_focus(_center)
	world._update_subscription(0.0)  # makes the chunk views; nothing is sent without a server
	var first_tick := -1
	var last_tick := 0
	for msg in parsed.get("messages", []):
		if not (msg is Dictionary):
			continue
		var t := str(msg.get("t", ""))
		if LIVE.has(t):
			_live.append([float(msg.get("dt", 0.0)), msg])
			_length = maxf(_length, float(msg.get("dt", 0.0)))
			var k := int(msg.get("k", 0))
			if first_tick < 0:
				first_tick = k
			last_tick = maxi(last_tick, k)
		else:
			world.handle(msg)
	_tick_span = maxi(1, last_tick - maxi(first_tick, 0) + 6)
	_length += 0.1
	if _view == null:
		_center = _factory_center(_center)
	else:
		_place_camera()


## Where the buildings are: the camera circles them rather than the trees.
func _factory_center(fallback: Vector2) -> Vector2:
	var sum := Vector2.ZERO
	var n := 0
	for r: WorldMirror.Rec in world.entities.values():
		var proto = world.protos.entity(r.proto_id)
		if proto != null and FACTORY_TYPES.has(proto.type):
			sum += r.pos
			n += 1
	return sum / n if n > 0 else fallback


func _process(delta: float) -> void:
	# Models are made on worker threads and a chunk leaves one out until it is ready; world.gd draws
	# them again only while a game runs, so the menu does it here (its buildings were missing).
	var made := ModelLibrary.poll()
	if PipelineWarm.poll():
		made = true  # models whose pipelines were compiling (pipeline_warm.gd)
	if made:
		for c in world.chunks:
			if world.chunks[c].waiting_models:
				world._dirty[c] = true
	world._rebuild_dirty()
	_time += delta
	_clock += delta
	while _next < _live.size() and float(_live[_next][0]) <= _clock:
		_replay(_live[_next][1])
		_next += 1
	if _clock >= _length:
		_clock -= _length
		_next = 0
		_loop += 1
	if _fill != null:
		# The fill follows the camera's turn, as in a game (looks.gd _put_fill_light).
		_fill.rotation.y = camera.rotation.y + deg_to_rad(Looks.FILL_YAW)
	if _view != null:
		_place_camera()
		return
	# A slow drift across the factory, turning a little, like a camera on a long crane.
	var a := _time * DRIFT_SPEED
	var focus := _center + Vector2(sin(a) * 9.0, sin(a * 0.7 + 1.0) * 5.0 - 3.0)
	var yaw := deg_to_rad(35.0 + 20.0 * sin(a * 0.5))
	var turn := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, -deg_to_rad(42.0))
	camera.transform = Transform3D(turn, Vector3(focus.x, 0.0, focus.y) + turn * Vector3(0.0, 0.0, 38.0))
	world.set_focus(focus)


## The saved view, turned a few degrees either way about the upright through the spot it looks at.
func _place_camera() -> void:
	var view: Transform3D = _view
	var pivot := Vector3(_center.x, 0.0, _center.y)
	var turn := Basis(Vector3.UP, deg_to_rad(SWAY_DEGREES * sin(_time * SWAY_SPEED)))
	camera.transform = Transform3D(turn, pivot - turn * pivot) * view
	world.set_focus(_center)


## A live update from the recording, its tick moved on by whole loops so the layers see time pass.
func _replay(msg: Dictionary) -> void:
	var copy := msg.duplicate()
	copy["k"] = int(msg.get("k", 0)) + _loop * _tick_span
	match str(msg.get("t", "")):
		"mv":
			_movers.handle(copy)
		"bs":
			# (Its lanes' read ticks move on with the loop too.)
			var shift := _loop * _tick_span
			if copy.has("sl"):
				var sl: Array = (copy["sl"] as Array).duplicate()
				var i := 0
				while i + 2 < sl.size():
					sl[i + 1] = int(sl[i + 1]) + shift
					i += 3 + int(sl[i + 2]) * 4
				copy["sl"] = sl
			if copy.has("pc"):
				var pc: Array = (copy["pc"] as Array).duplicate()
				for j in range(1, pc.size(), 5):
					pc[j] = int(pc[j]) + shift
				copy["pc"] = pc
			_belt_items.handle(copy)
		"ih":
			_arms.handle(copy)
		"gi":
			_ground_items.handle(copy)


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.62, 0.68)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.78, 0.78, 0.8)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var game_light := Looks.preview_light_switch(OS.get_cmdline_user_args())
	Settings.apply_ssao(env)
	_env = env
	Settings.apply_environment(env)
	Settings.listen(_on_setting)
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
	var sun := DirectionalLight3D.new()
	# Late afternoon: long shadows across the factory.
	sun.rotation_degrees = Vector3(-35.0, -55.0, 0.0)
	sun.light_energy = 1.15
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.shadow_enabled = Settings.shadow_size() > 0
	sun.directional_shadow_max_distance = 120.0
	add_child(sun)
	# lighting-fixes step 6: lit as a game is, the Factorio look at noon on Nauvis (looks.gd noon_rig: its held sun,
	# ambient, the lighting environment in the sky's cubemap, linear tonemapping), so the backdrop's factory looks
	# as it will in a game; --preview-light=studio keeps the late-afternoon light above (0.2.2's).
	var rig := Looks.noon_rig() if game_light else {}
	if game_light:
		Looks.put_noon_rig(env, sun, rig)
		# The look's fill light (none on the ground's layer), from the side the camera looks from.
		_fill = DirectionalLight3D.new()
		_fill.name = "Fill"
		_fill.light_cull_mask = 0xFFFFF & ~Visuals.GROUND_LAYER
		add_child(_fill)
		Looks.put_noon_fill(_fill, rig, camera.rotation.y)
	Looks.put_idle_globals(rig)


## Brightness, contrast and saturation change as they are dragged in Settings.
func _on_setting(section: String, _key: String) -> void:
	if section == "graphics" and _env != null and is_inside_tree():
		Settings.apply_environment(_env)
		Settings.apply_ssao(_env)


func _exit_tree() -> void:
	Settings.unlisten(_on_setting)
