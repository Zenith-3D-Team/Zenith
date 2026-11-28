extends Node3D
## Space Age's travel in 3D: a rocket leaving its silo, cargo pods coming down and going up, and
## asteroid chunks drifting past a platform.
##
## Rockets, as Factorio's silo does it (its prototypes' timings and sprites, from the player's
## install): the silo says where its rocket is (`st`, 2 to 5): the red lights blink and the doors
## open (anim.gd), the rocket rises RISE_DEPTH up the shaft and waits with its nose in the hatch.
## On `rk` (a launch was ordered, ui_model.rocket_launched) the engines start, shaking it, their
## light and steam coming up through the hatch, and at LIFT_AFTER it climbs at the game's pace out
## of the shaft, on the volumetric plume (rocket_vfx.gd), with fire-lit billowing smoke, sparks,
## and rim blast wash (`--rocket-vfx=old` restores legacy sprite cards).
## The rocket mover the mod sends for that silo (rocket-silo-rocket) is hidden meanwhile, so it
## isn't drawn twice. When the character rides that rocket, ride.gd drives it instead (drive()):
## its height comes from the game's own flight.
## Cargo pods: the movers layer draws them where the mod puts them on the ground; this lifts them:
## a pod descending (`cp` state) drops from DESCENT_HEIGHT to the ground over DESCENT_TIME with a
## braking flame, one ascending rises away.
## Asteroid chunks (`ach`): one MultiMesh per chunk kind, each chunk moved on by its velocity
## between messages; one an asteroid collector holds is left to collectors.gd.

const ModelLibrary := preload("res://scripts/world/model_library.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const RocketVfx := preload("res://scripts/world/rocket_vfx.gd")

const SoundBank := preload("res://scripts/fx/sound_bank.gd")
const FxSettings := preload("res://scripts/fx/fx_settings.gd")

## A rocket silo's `st`, past 0 (idle) and 1 (building a rocket): movers.lua's silo_phase.
const SILO_OPENING := 2
const SILO_RISING := 3
const SILO_UP := 4
const SILO_CLOSING := 5
## From Factorio's prototypes: door_opening_speed, rising_speed, engine_starting_speed,
## light_blinking_speed.
const DOOR_TIME := 4.25
const RISE_TIME := 7.0
const ENGINE_START := 5.5
const BLINK_TIME := 3.0
## How much further down the rocket is until it rises: its nose under the shut doors.
const RISE_DEPTH := 7.0
const RISE_DEPTH_3D := 10.5
const ELEVATOR_RETURN_TIME := 3.5
const CLAMP_ENGAGE_TIME := 1.1
const CLAMP_RELEASE_TIME := 0.55
## Seconds after the launch order: the engines start, and the rocket lets go (a pod's
## awaiting_launch took about 8 s in 2.1.23: the engine's start and the arms drawing back).
const IGNITE_AFTER := 0.8
const LIFT_AFTER := 8.0
## Its climb after that, fitted to 2.1.23's (7 tiles by 5 s, 200 by 20 s).
const CLIMB_SCALE := 0.143
const CLIMB_POWER := 2.42
const FLIGHT_HEIGHT := 320.0    # then the rocket is gone
## effects_fade_in_start_distance and _end_distance: how far it has climbed as the smoke comes in.
const SMOKE_FROM := 4.5
const SMOKE_FULL := 7.5
const SMOKE_TINT := Color(0.8, 0.8, 1.0, 0.8)
const SMOKE_FPS := 30.0         # animation_speed 0.5
## How far above the rocket's base (its nozzle) the smoke columns start, wrapping its tail.
const SMOKE_TOP := 1.5
const JET_FPS := 30.0
## Round the hatch: x, the column's width, z (rocket_smoke_top1-3 and bottom1-2's places).
const SMOKE_COLUMNS := [Vector3(-2.1, 3.6, -1.3), Vector3(0.5, 3.6, -2.0), Vector3(1.5, 3.6, -1.5), Vector3(-2.2, 3.6, 1.2), Vector3(1.9, 3.6, 1.3)]
## Factorio's red lights round the hole (red_lights_back and _front_sprites), turned to lie round it.
const RED_LIGHTS := [Vector2(1.5, -3.0), Vector2(2.7, -2.0), Vector2(3.3, 0.0), Vector2(-3.3, 0.0), Vector2(-2.7, -2.0), Vector2(-1.5, -3.0),
	Vector2(2.7, 2.0), Vector2(1.5, 3.0), Vector2(0.0, 3.4), Vector2(-1.5, 3.0), Vector2(-2.7, 2.0)]
const RED_LIGHT_HEIGHT := 1.0
## The shaft's picture lies this high, under the doors, and this wide.
const SHAFT_HEIGHT := 0.06
const SHAFT_WIDTH := 6.4
## How high the engines' light shows while they are down the shaft.
const HATCH_GLOW_HEIGHT := 0.9
## A rocket whose base is this high is out of the shaft: the doors may close.
const CLEAR_OF_SHAFT := 2.0
const HELD_LIFE := 1.0e6
const DESCENT_HEIGHT := 45.0
const DESCENT_TIME := 3.5
const ASCENT_ACCELERATION := 9.0
## A rocket or pod this near a silo's centre is in that silo.
const SILO_REACH := 6.0
const CHUNK_SCALE := 0.45
const CHUNK_HEIGHT := 0.6
## A chunk within this many tiles of where one of its kind was drawn is the same chunk, moved on.
const MATCH_DISTANCE := 1.0
## How fast the gap between a chunk's drawn and sent place closes (per second).
const CHUNK_SETTLE := 6.0
const WIND := Vector3(0.45, 0.0, 0.15)

var movers  # movers.gd
## The surface the world shows (main.gd sets it on `surface`): launches elsewhere aren't drawn here
## (H1: a launch on Nauvis drew a rocket at its silo's place on the platform being watched).
var surface := ""
## Where each of the game's own rockets (rocket-silo-rocket movers) was first seen.
var _rocket_start := {}
## Each rocket: whether a silo stands under it, and when to look again (msec).
var _rocket_silo := {}
var _rocket_hidden := {}  # rockets this file hid for standing off a silo
var model   # ui_model.gd
var fx      # fx.gd: its sprites and sounds; set by main.gd
## The cargo pod the character rides in (ride.gd draws it), left alone here.
var ridden := 0

var _launches: Array = []        # [{"node", "light", "at" (Vector2), "t", "cards", "plume"}]
var _silos := {}                 # silo unit -> {"at", "phase", "since", "keep", "glow", "ember", "shock", "steam_t", "cards"}
var _pods := {}                  # unit -> {"state", "t"}
var _chunk_meshes := {}          # chunk name -> MultiMeshInstance3D
var _chunks_msec := 0            # when the chunks drawn now were sent (Time.get_ticks_msec)
var _vfx: RocketVfx


func _ready() -> void:
	# Asked for now, read on a worker thread: made here at a launch it took 36-48 ms in that frame
	# on the owner's save (its silos launch on their own).
	ModelLibrary.ready("rocket-silo-rocket")
	_ensure_vfx()
	if model != null:
		model.rocket_launched.connect(_on_launch)
		model.asteroid_chunks_changed.connect(_on_chunks)


func _ensure_vfx() -> RocketVfx:
	if not ModelLibrary.rocket_vfx_enhanced:
		return null
	if _vfx == null:
		_vfx = RocketVfx.new()
		_vfx.name = "RocketVfx"
		add_child(_vfx)
	return _vfx


func reset() -> void:
	for l in _launches:
		_drop_cards(l["cards"])
		(l["light"] as Node).queue_free()
		(l["node"] as Node3D).queue_free()
	_launches.clear()
	for s: Dictionary in _silos.values():
		_drop_cards(s["cards"])
	_silos.clear()
	_pods.clear()
	_rocket_start.clear()
	_rocket_hidden.clear()
	if _vfx != null:
		_vfx.reset()
	for mm in _chunk_meshes.values():
		(mm as MultiMeshInstance3D).multimesh.visible_instance_count = 0


## Where the rockets climbing now are drawn (add-ons' api.world.rockets()).
func launch_positions() -> Array:
	var out: Array = []
	for l: Dictionary in _launches:
		var n = l.get("node")
		if n is Node3D and is_instance_valid(n) and (n as Node3D).is_inside_tree():
			out.append((n as Node3D).global_position)
	return out


## The ridden rocket at `at` (silo, tiles): `height` above the silo (tiles) and how far its engine
## has lit (0 to 1), from the game's flight (ride.gd). Starts the launch if `rk` hasn't yet. False
## while there is no silo there to start it from: a save loading mid-ride sends the ride before the
## silo's chunk (the last launch in the list was read, an index error with none, or another silo's
## launch driven); ride.gd asks again each frame, and the rocket comes once the silo has.
func drive(at: Vector2, height: float, ignition: float) -> bool:
	var l := _launch_at(at)
	if l.is_empty():
		l = _start_launch(at, "")
		if l.is_empty():
			return false
	l["driven"] = true
	l["h"] = height
	l["ign"] = ignition
	l["seen"] = 0.0
	return true


func _launch_at(at: Vector2) -> Dictionary:
	for l in _launches:
		if (l["at"] as Vector2).distance_to(at) < 3.0:
			return l
	return {}


func _hole_pos(at: Vector2) -> Vector2:
	if not ModelLibrary.rocket_vfx_enhanced:
		return at
	var spec := ModelLibrary.silo_hole_spec("rocket-silo")
	return at + Vector2(spec.x, spec.y)


func _hole_radius() -> float:
	return ModelLibrary.silo_hole_spec("rocket-silo").z


# --- rockets ----------------------------------------------------------------------------------

## How much of the engine's start is done `t` seconds after the launch was ordered, 0 to 1.
static func ignition_at(t: float) -> float:
	return clampf((t - IGNITE_AFTER) / ENGINE_START, 0.0, 1.0)


## How far a rocket has climbed `t` seconds after it let go (tiles).
static func climb_at(t: float) -> float:
	return CLIMB_SCALE * pow(maxf(t, 0.0), CLIMB_POWER)


## Whether a launch at `at` still has its base inside the shaft: the doors stay open for it, whatever
## the game says (Factorio draws the rocket clear of its silo sooner than a 17-tile model is).
func in_shaft(at: Vector2) -> bool:
	for l in _launches:
		if (l["at"] as Vector2).distance_to(at) < SILO_REACH and (l["node"] as Node3D).position.y < CLEAR_OF_SHAFT:
			return true
	return false


func _on_launch(_silo: int, at: Vector2, launch_surface: String) -> void:
	_start_launch(at, launch_surface)


## A launch out of the silo at `at`, or {} when it isn't drawn here.
func _start_launch(at: Vector2, launch_surface: String) -> Dictionary:
	if surface != "" and launch_surface != "" and launch_surface != surface:
		return {}
	# Only out of a silo the world has: `rk` comes for every silo the force has, wherever it stands.
	if movers != null and movers.world != null and not movers.world.has_near("rocket-silo", at, SILO_REACH):
		return {}
	var hole := _hole_pos(at)
	var root := Node3D.new()
	root.position = Vector3(hole.x, -Visuals.ROCKET_SINK, hole.y)
	var body := MeshInstance3D.new()
	body.mesh = ModelLibrary.mesh_for("rocket-silo-rocket") if ModelLibrary.ready("rocket-silo-rocket") else null
	if body.mesh == null:  # no model (or not read yet): a white rocket of the right size
		var c := CylinderMesh.new()
		c.top_radius = 0.9
		c.bottom_radius = 1.0
		c.height = 12.0
		body.mesh = c
		# Its plain material isn't lifted onto an add-on's hills, as the model's is: lifted here.
		body.position.y = 6.0 + GroundHeight.at(hole.x, hole.y)
	root.add_child(body)
	var vfx := _ensure_vfx()
	var plume: RocketVfx.PlumeRig = vfx.attach_plume(root) if vfx != null else null
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.68, 0.32)
	light.omni_range = 46.0 if vfx != null else 30.0
	light.light_energy = 0.0
	add_child(root)
	add_child(light)
	var l := {"node": root, "light": light, "plume": plume, "at": at, "t": 0.0, "cards": {},
		"steam": 0.0, "billow": 0.0, "trail": 0.0, "sparks": 0.0, "clamps": false, "lifted": false,
		"ground": 0.0, "hills": -1}
	_launches.append(l)
	_sound("base/sound/silo-clamps-off", at, 0.8)
	return l


## The add-on's hills under a launch's silo (ground_height.gd): the rocket's model and the launch's
## cards are lifted onto them in their shaders, the engines' light is placed here. Read when the
## launch starts and again only when the hills change.
func _ground(l: Dictionary) -> float:
	if int(l["hills"]) != GroundHeight.version():
		var at: Vector2 = l["at"]
		l["hills"] = GroundHeight.version()
		l["ground"] = GroundHeight.at(at.x, at.y)
	return float(l["ground"])


## A card held in place by its launch or silo: it lives until kill(), moved and faded here each frame.
func _held(cards: Dictionary, key: String, sheet: String, pos: Vector3, width: float, alpha: float, color := Color.WHITE, fps := 15.0) -> void:
	var sprites: Node = _sprites()
	if sprites == null:
		return
	var c = cards.get(key)
	if c == null:
		c = sprites.call("emit", sheet, pos, width, HELD_LIFE, color)
		if c == null:
			return
		c.fps = fps
		cards[key] = c
	c.pos = pos
	c.size0 = width
	c.size1 = width
	c.color.a = color.a * alpha


func _drop_cards(cards: Dictionary) -> void:
	var sprites: Node = fx.get("sprites") if fx != null else null
	if sprites != null:
		for c in cards.values():
			sprites.call("kill", c)
	cards.clear()


func _sprites() -> Node:
	if fx == null or not FxSettings.effects_enabled:
		return null
	return fx.get("sprites")


func _sound(prefix: String, at: Vector2, volume: float, reach := 3.0) -> void:
	var sfx = fx.get("sfx") if fx != null else null
	if sfx == null:
		return
	var file := SoundBank.pick(prefix)
	if file != "":
		sfx.call("play_at", file, Vector3(at.x, 1.0, at.y), volume, 0.0, reach)


func _update_launches(delta: float) -> void:
	var done: Array = []
	var vfx := _ensure_vfx()
	for l in _launches:
		l["t"] = float(l["t"]) + delta
		var t: float = l["t"]
		var root: Node3D = l["node"]
		var light: OmniLight3D = l["light"]
		var at: Vector2 = l["at"]
		var hole := _hole_pos(at)
		var driven := bool(l.get("driven", false))
		var ignition := ignition_at(t)
		var climbed := climb_at(t - LIFT_AFTER)
		if driven:
			ignition = float(l["ign"])
			climbed = float(l["h"])
			l["seen"] = float(l["seen"]) + delta
		var y := -Visuals.ROCKET_SINK + climbed
		# Mechanical hold-down shudder and liftoff vibration, fading as the rocket clears the tower.
		var shake_amp := (0.045 * ignition + 0.025 * ignition * ignition) * (1.0 - clampf(climbed / 45.0, 0.0, 1.0))
		var sx := (sin(t * 53.0) * 0.7 + cos(t * 19.0) * 0.3) * shake_amp
		var sz := (cos(t * 47.0) * 0.7 + sin(t * 23.0) * 0.3) * shake_amp
		root.position = Vector3(hole.x + sx, y, hole.y + sz)
		var flicker := 0.85 + 0.10 * sin(t * 37.0) + 0.05 * cos(t * 71.0)
		(root.get_child(0) as MeshInstance3D).set_instance_shader_parameter("f3d_glow", ignition)  # rocket-static-emission
		# Until the engines are out of the shaft their light comes up through the hatch.
		var glow_y := maxf(y, HATCH_GLOW_HEIGHT)
		light.position = Vector3(hole.x, glow_y + _ground(l), hole.y)
		var far := 1.0 - clampf((climbed - 120.0) / 140.0, 0.0, 1.0)
		var cards: Dictionary = l["cards"]
		if vfx != null:
			light.light_energy = (14.0 if climbed > 0.1 else 8.0) * ignition * far * flicker
			var plume: RocketVfx.PlumeRig = l.get("plume")
			vfx.update_plume(plume, ignition, climbed, flicker)
			_held(cards, "glare", "rocket-glare", Vector3(hole.x, glow_y, hole.y), lerpf(12.0, 18.0, ignition), 0.55 * ignition * far * flicker)
			_exhaust_vfx(vfx, l, delta, hole, y, ignition, climbed)
		else:
			light.light_energy = 6.0 * ignition * flicker
			_held(cards, "jet", "rocket-jet", Vector3(at.x, y - 2.6, at.y), 6.5 + clampf(climbed / 20.0, 0.0, 2.5), ignition * flicker, Color.WHITE, JET_FPS)
			_held(cards, "glare", "rocket-glare", Vector3(at.x, glow_y, at.y), 15.0, 0.75 * ignition * far * flicker)
			_smoke_columns(cards, at, y, climbed)
			_exhaust_legacy(l, delta, at, y, ignition, climbed)
		var silo := _silo_at(at)
		if not silo.is_empty():
			var shaft_heat := ignition * (1.0 - clampf(climbed / 48.0, 0.0, 1.0))
			silo["glow"] = shaft_heat
			silo["ember"] = maxf(float(silo.get("ember", 0.0)), shaft_heat * 0.9)
			silo["keep"] = DOOR_TIME + 0.5
			if vfx != null and not bool(l.get("lifted", false)) and climbed > 0.05:
				l["lifted"] = true
				silo["shock"] = 0.01
				_liftoff_surge(vfx, hole, y)
		if not bool(l.get("roared", false)) and ignition > 0.4:
			l["roared"] = true
			_sound("base/sound/entity/silo-rocket-takeoff/silo-rocket", at, 1.0, 6.0)  # audible_distance_modifier
		_hide_rocket_mover(l["at"])
		# A driven rocket goes when the ride stops driving it (the pod changed surface).
		if (driven and float(l["seen"]) > 1.5) or (not driven and climbed >= FLIGHT_HEIGHT):
			done.append(l)
	for l in done:
		_drop_cards(l["cards"])
		(l["light"] as Node).queue_free()
		(l["node"] as Node3D).queue_free()
		_launches.erase(l)


## Act 3 & Act 4 volumetric smoke, pyroclastic ground doughnut, sparks, and contrail.
func _exhaust_vfx(vfx: RocketVfx, l: Dictionary, delta: float, hole: Vector2, y: float, ignition: float, climbed: float) -> void:
	if not FxSettings.effects_enabled:
		return
	var t: float = l["t"]
	# Act 3a: Hold-down clamp release steam burst right after launch command.
	if not bool(l.get("clamps", false)) and t >= 0.15:
		l["clamps"] = true
		var r := _hole_radius()
		for k in 14:
			var ang := float(k) / 14.0 * TAU + randf_range(-0.1, 0.1)
			var dir := Vector2.from_angle(ang)
			vfx.emit_smoke(
				Vector3(hole.x + dir.x * r * 0.9, 0.55, hole.y + dir.y * r * 0.9),
				Vector3(dir.x * randf_range(2.2, 4.2), randf_range(3.0, 5.5), dir.y * randf_range(2.2, 4.2)),
				randf_range(1.1, 1.7), randf_range(3.6, 5.2), randf_range(2.0, 3.2),
				Color(0.92, 0.94, 0.98, 0.55), 0.0, 1.3, 0.9, 0.5)
	if ignition <= 0.04:
		return
	# Act 3b: Igniter & engine spark eruption from the shaft and climbing nozzle.
	if y < 90.0:
		var spark_rate := 55.0 * ignition if y < 8.0 else 32.0 * ignition
		l["sparks"] = float(l["sparks"]) + delta * spark_rate
		while float(l["sparks"]) >= 1.0:
			l["sparks"] = float(l["sparks"]) - 1.0
			var ang := randf() * TAU
			var dir := Vector2.from_angle(ang)
			var in_pit := y < 2.0
			var spawn := Vector3(hole.x + dir.x * randf_range(0.2, 1.8), 0.35 if in_pit else maxf(y - 0.6, 0.4), hole.y + dir.y * randf_range(0.2, 1.8))
			var spd := randf_range(7.0, 19.0)
			var vy := randf_range(9.0, 21.0) if in_pit else randf_range(-16.0, -4.0)
			var col := Color(1.0, randf_range(0.55, 0.92), randf_range(0.15, 0.45), 1.0)
			vfx.emit_spark(spawn, Vector3(dir.x * spd, vy, dir.y * spd), randf_range(0.45, 1.1), col, randf_range(0.12, 0.22), 0.65)
	# Act 3c: Pre-liftoff steam + fire-lit shaft exhaust pushing out of the hatch.
	if y < 0.0:
		l["steam"] = float(l["steam"]) + delta * 28.0 * ignition
		while float(l["steam"]) >= 1.0:
			l["steam"] = float(l["steam"]) - 1.0
			var off := Vector2.from_angle(randf() * TAU) * randf_range(0.3, 2.3)
			var heat := clampf((ignition - 0.2) * 1.1, 0.0, 0.95)
			vfx.emit_smoke(
				Vector3(hole.x + off.x, 0.45, hole.y + off.y),
				Vector3(off.x * 1.4, randf_range(3.5, 7.5), off.y * 1.4) + WIND,
				randf_range(1.6, 2.5), randf_range(5.0, 7.8), randf_range(2.4, 3.8),
				Color(0.84, 0.82, 0.80, 0.65), heat, 0.9, 1.1, 0.6)
	# Act 3d / 4a: Massive 360-degree ground-hugging fire-lit pyroclastic smoke doughnut.
	if y > -10.0 and climbed < 75.0:
		var billow_rate := 68.0 * (0.45 + 0.55 * ignition) * (1.0 - clampf((climbed - 45.0) / 30.0, 0.0, 1.0))
		l["billow"] = float(l["billow"]) + delta * billow_rate
		while float(l["billow"]) >= 1.0:
			l["billow"] = float(l["billow"]) - 1.0
			var dir := Vector2.from_angle(randf() * TAU)
			var speed := randf_range(7.5, 19.5) * (0.65 + 0.35 * ignition)
			var heat := clampf(ignition * (1.0 - clampf((climbed - 15.0) / 45.0, 0.0, 1.0)), 0.15, 1.0)
			var tint := Color(0.68, 0.65, 0.62, 0.72)
			vfx.emit_smoke(
				Vector3(hole.x + dir.x * 2.1, 0.65, hole.y + dir.y * 2.1),
				Vector3(dir.x * speed, randf_range(0.6, 3.4), dir.y * speed) + WIND * 1.5,
				randf_range(2.2, 3.4), randf_range(8.5, 13.0), randf_range(3.6, 6.2),
				tint, heat, 1.35, 0.45, 0.5)
	# Act 4b: Towering ascending fire-lit smoke contrail behind the climbing rocket.
	if y > -1.0 and climbed < 220.0:
		var trail_rate := 42.0 * (1.0 - clampf((climbed - 150.0) / 70.0, 0.0, 1.0))
		l["trail"] = float(l["trail"]) + delta * trail_rate
		while float(l["trail"]) >= 1.0:
			l["trail"] = float(l["trail"]) - 1.0
			var jitter := Vector2.from_angle(randf() * TAU) * randf_range(0.0, 1.1)
			var tail_y := maxf(y - randf_range(2.0, 5.5), 0.6)
			var heat := clampf(0.95 - climbed / 190.0, 0.25, 0.95)
			vfx.emit_smoke(
				Vector3(hole.x + jitter.x, tail_y, hole.y + jitter.y),
				Vector3(jitter.x * 2.2, randf_range(-6.5, -2.5), jitter.y * 2.2) + WIND * 2.5,
				randf_range(2.0, 3.2), randf_range(7.5, 12.0), randf_range(5.5, 9.5),
				Color(0.82, 0.80, 0.78, 0.68), heat, 0.75, 0.35, 0.35)


func _liftoff_surge(vfx: RocketVfx, hole: Vector2, y: float) -> void:
	if not FxSettings.effects_enabled:
		return
	var r := _hole_radius()
	for k in 28:
		var ang := float(k) / 28.0 * TAU + randf_range(-0.08, 0.08)
		var dir := Vector2.from_angle(ang)
		var spd := randf_range(12.0, 22.0)
		vfx.emit_smoke(
			Vector3(hole.x + dir.x * r * 0.95, 0.7, hole.y + dir.y * r * 0.95),
			Vector3(dir.x * spd, randf_range(1.2, 4.2), dir.y * spd),
			randf_range(2.4, 3.6), randf_range(9.5, 13.5), randf_range(4.0, 6.4),
			Color(0.75, 0.72, 0.68, 0.78), 0.95, 1.4, 0.55, 0.55)
	for k in 36:
		var ang := randf() * TAU
		var dir := Vector2.from_angle(ang)
		var spd := randf_range(9.0, 24.0)
		vfx.emit_spark(
			Vector3(hole.x + dir.x * 1.4, maxf(y, 0.5), hole.y + dir.y * 1.4),
			Vector3(dir.x * spd, randf_range(8.0, 22.0), dir.y * spd),
			randf_range(0.6, 1.3), Color(1.0, 0.82, 0.38, 1.0), randf_range(0.14, 0.25), 0.55)


## Factorio's smoke columns (rocket_smoke_top1-3, bottom1-2), used only under `--rocket-vfx=old`.
func _smoke_columns(cards: Dictionary, at: Vector2, y: float, climbed: float) -> void:
	var alpha := clampf((climbed - SMOKE_FROM) / (SMOKE_FULL - SMOKE_FROM), 0.0, 1.0) * (1.0 - clampf((climbed - 90.0) / 110.0, 0.0, 1.0))
	if alpha <= 0.0 and cards.is_empty():
		return
	for i in SMOKE_COLUMNS.size():
		var spot: Vector3 = SMOKE_COLUMNS[i]
		var width: float = spot.y
		# The sheet's frames are 3.58 times as tall as wide: the card's middle is 1.79 widths down.
		_held(cards, "smoke%d" % i, "rocket-smoke", Vector3(at.x + spot.x, y + SMOKE_TOP - width * 1.79, at.y + spot.z), width, alpha, SMOKE_TINT, SMOKE_FPS)


## Legacy Factorio sprite smoke under `--rocket-vfx=old`.
func _exhaust_legacy(l: Dictionary, delta: float, at: Vector2, y: float, ignition: float, climbed: float) -> void:
	var sprites: Node = _sprites()
	if sprites == null or ignition <= 0.05:
		return
	if y < 0.0:
		l["steam"] = float(l["steam"]) + delta * 22.0 * ignition
		while float(l["steam"]) >= 1.0:
			l["steam"] = float(l["steam"]) - 1.0
			var off := Vector2.from_angle(randf() * TAU) * randf_range(0.2, 2.4)
			var puff = sprites.call("emit", "smoke", Vector3(at.x + off.x, 0.6, at.y + off.y), randf_range(1.4, 2.2), randf_range(1.8, 3.0), Color(0.86, 0.86, 0.95, 0.5))
			if puff != null:
				puff.vel = Vector3(off.x * 0.5, randf_range(2.5, 5.0), off.y * 0.5)
				puff.size1 = randf_range(4.0, 6.0)
				puff.drag = 0.7
	if y > -8.0 and climbed < 70.0:
		l["billow"] = float(l["billow"]) + delta * 45.0
		while float(l["billow"]) >= 1.0:
			l["billow"] = float(l["billow"]) - 1.0
			var dir := Vector2.from_angle(randf() * TAU)
			var puff = sprites.call("emit", "smoke", Vector3(at.x + dir.x * 2.5, 0.8, at.y + dir.y * 2.5), randf_range(2.0, 3.0), randf_range(3.0, 4.8), Color(0.74, 0.72, 0.7, 0.62))
			if puff != null:
				var speed := randf_range(6.0, 15.0)
				puff.vel = Vector3(dir.x * speed, randf_range(0.5, 2.5), dir.y * speed)
				puff.size1 = randf_range(7.0, 11.0)
				puff.drag = 1.4
	if y > 0.0 and y < 110.0:
		l["trail"] = float(l["trail"]) + delta * 24.0
		while float(l["trail"]) >= 1.0:
			l["trail"] = float(l["trail"]) - 1.0
			var puff = sprites.call("emit", "smoke", Vector3(at.x + randf_range(-0.7, 0.7), y - 4.5, at.y + randf_range(-0.7, 0.7)), randf_range(2.0, 3.0), randf_range(2.0, 3.2), Color(0.82, 0.8, 0.78, 0.55))
			if puff != null:
				puff.vel = Vector3(randf_range(-0.6, 0.6), -2.0, randf_range(-0.6, 0.6))
				puff.size1 = randf_range(5.0, 8.0)
				puff.drag = 0.8


## A soft round puff of smoke facing the camera.
static var _puff: QuadMesh = null
static func _puff_mesh() -> QuadMesh:
	if _puff != null:
		return _puff
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0.55))
	g.set_color(1, Color(1, 1, 1, 0.0))
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_puff = QuadMesh.new()
	_puff.size = Vector2(2.0, 2.0)
	_puff.material = mat
	return _puff


## The silo a launch or rocket stands in, watched here while it is busy (`_silos`), or {}.
func _silo_at(at: Vector2) -> Dictionary:
	for s: Dictionary in _silos.values():
		if (s["at"] as Vector2).distance_to(at) < SILO_REACH:
			return s
	if movers == null or movers.world == null:
		return {}
	var unit: int = movers.world.unit_near("rocket-silo", at, SILO_REACH)
	return _watch(unit, at) if unit != 0 else {}


func _watch(unit: int, at: Vector2) -> Dictionary:
	var s: Dictionary = _silos.get(unit, {})
	if s.is_empty():
		var cur_phase := int(movers.world.working.get(unit, 0)) if movers != null and movers.world != null else 0
		var up_now := cur_phase == SILO_UP
		var launching := _launch_near(at)
		s = {"unit": unit, "at": at, "phase": cur_phase, "since": 0.0, "keep": DOOR_TIME + 0.5,
			"glow": 0.0, "ember": 0.0, "shock": 0.0, "steam_t": 0.0,
			"lift": 1.0 if up_now else 0.0, "clamps": 1.0 if (up_now and not launching) else 0.0,
			"work": 0.0, "rise_p": 1.0 if up_now else 0.0, "cards": {}}
		_silos[unit] = s
	return s


func _sync_world_silos() -> void:
	var vfx := _ensure_vfx()
	if vfx == null or movers == null or movers.world == null:
		return
	var pos_map: Variant = movers.world.get("silo_positions")
	if not (pos_map is Dictionary):
		return
	var map_dict: Dictionary = pos_map
	var wanted := {}
	var spec := ModelLibrary.silo_hole_spec("rocket-silo")
	var off := Vector2(spec.x, spec.y)
	for unit_var: Variant in map_dict:
		var unit := int(unit_var)
		var pos: Vector2 = map_dict[unit_var]
		wanted[unit] = pos + off
		if int(movers.world.working.get(unit, 0)) >= SILO_OPENING and not _silos.has(unit):
			_watch(unit, pos)
	vfx.sync_shafts(wanted, spec.z)


## What a busy silo shows besides its doors (anim.gd): the shaft's walls under them, elevator
## cradle & clamp arms during reload, engine firelight, red alarm lights, and post-launch steam.
func _update_silos(delta: float) -> void:
	var vfx := _ensure_vfx()
	var gone: Array = []
	for unit: int in _silos:
		var s: Dictionary = _silos[unit]
		var at: Vector2 = s["at"]
		var hole := _hole_pos(at)
		var phase := int(movers.world.working.get(unit, 0)) if movers != null and movers.world != null else 0
		var prev_phase := int(s["phase"])
		if phase != prev_phase:
			if phase >= SILO_OPENING or prev_phase >= SILO_OPENING:
				_phase_sound(phase, at)
			if phase == SILO_RISING and prev_phase < SILO_RISING:
				s["rise_p"] = 0.0
			s["phase"] = phase
			s["since"] = 0.0
		s["since"] = float(s["since"]) + delta
		if phase >= SILO_OPENING and phase != SILO_CLOSING:
			s["keep"] = DOOR_TIME + 0.5
		s["keep"] = float(s["keep"]) - delta
		if float(s["keep"]) <= 0.0:
			gone.append(unit)
			continue
		var launching := _launch_near(at)
		if not launching:
			s["glow"] = move_toward(float(s["glow"]), 0.0, delta * 2.5)
		var lift := float(s.get("lift", 0.0))
		var clamps := float(s.get("clamps", 0.0))
		var work_goal := 0.0
		match phase:
			SILO_OPENING:
				lift = move_toward(lift, 0.0, delta / ELEVATOR_RETURN_TIME)
				clamps = move_toward(clamps, 0.0, delta / CLAMP_RELEASE_TIME)
				if float(s["since"]) > 0.6:
					work_goal = 0.55
			SILO_RISING:
				var rp := clampf(float(s.get("rise_p", 0.0)) + delta / RISE_TIME, 0.0, 1.0)
				s["rise_p"] = rp
				lift = rp * rp * (3.0 - 2.0 * rp)
				clamps = move_toward(clamps, 0.0, delta / CLAMP_RELEASE_TIME)
				work_goal = 1.0
			SILO_UP:
				if not launching:
					lift = move_toward(lift, 1.0, delta / 1.5)
					if lift >= 0.96:
						clamps = move_toward(clamps, 1.0, delta / CLAMP_ENGAGE_TIME)
					else:
						clamps = move_toward(clamps, 0.0, delta / CLAMP_RELEASE_TIME)
					if clamps < 0.95:
						work_goal = 0.45
				else:
					clamps = move_toward(clamps, 0.0, delta / CLAMP_RELEASE_TIME)
			SILO_CLOSING:
				lift = move_toward(lift, 0.0, delta / ELEVATOR_RETURN_TIME)
				clamps = move_toward(clamps, 0.0, delta / CLAMP_RELEASE_TIME)
			_:
				if not launching:
					lift = move_toward(lift, 0.0, delta / ELEVATOR_RETURN_TIME)
				clamps = move_toward(clamps, 0.0, delta / CLAMP_RELEASE_TIME)
		s["lift"] = lift
		s["clamps"] = clamps
		var work_glow := move_toward(float(s.get("work", 0.0)), work_goal, delta * 2.2)
		s["work"] = work_glow
		var glow := float(s["glow"])
		var ember := move_toward(float(s.get("ember", 0.0)), 0.0, delta * 0.14)
		s["ember"] = ember
		var shock := float(s.get("shock", 0.0))
		if shock > 0.0 and shock < 1.0:
			shock = minf(shock + delta / 0.65, 1.0)
			if shock >= 1.0:
				shock = 0.0
			s["shock"] = shock
		var blink := 0.0
		if phase == SILO_OPENING or phase == SILO_CLOSING:
			blink = 0.5 + 0.5 * sin(float(s["since"]) * TAU / BLINK_TIME - PI / 2.0)
		elif glow > 0.05:
			blink = 0.5 + 0.5 * sin(float(s["since"]) * TAU / 0.45)
		if vfx != null:
			var shaft := vfx.ensure_shaft(unit, hole, _hole_radius())
			var pit_col := Color(1.0, 0.55, 0.18).lerp(Color(1.0, 0.14, 0.08), clampf((1.0 - glow) * blink, 0.0, 1.0))
			var pit_energy := maxf(glow * 12.0, maxf(ember * 2.5, blink * 1.4))
			if pit_energy < work_glow * 2.4:
				pit_energy = work_glow * 2.4
				pit_col = Color(1.0, 0.76, 0.42)
			vfx.update_shaft(shaft, glow, ember, blink, shock, pit_energy, pit_col, glow * 0.95, lift, clamps, work_glow)
			if FxSettings.effects_enabled:
				for i in RED_LIGHTS.size():
					var spot: Vector2 = RED_LIGHTS[i]
					vfx.queue_beacon(Vector3(hole.x + spot.x, RED_LIGHT_HEIGHT, hole.y + spot.y), blink)
				_silo_ambient_steam(vfx, s, delta, hole, phase, glow, ember)
		else:
			var cards: Dictionary = s["cards"]
			var ground := Vector3(at.x, SHAFT_HEIGHT, at.y)
			_held(cards, "hole", "silo-hole", ground, SHAFT_WIDTH, 1.0)
			_held(cards, "light", "silo-hole-light", ground + Vector3(0.0, 0.01, 0.0), SHAFT_WIDTH, glow)
			for i in RED_LIGHTS.size():
				var spot: Vector2 = RED_LIGHTS[i]
				_held(cards, "red%d" % i, "silo-light", Vector3(at.x + spot.x, RED_LIGHT_HEIGHT, at.y + spot.y), 1.2, blink)
	for unit in gone:
		_drop_cards(_silos[unit]["cards"])
		_silos.erase(unit)
		if vfx != null:
			var s_gone: RocketVfx.SiloShaft = vfx.get_shaft(int(unit))
			if s_gone != null:
				vfx.update_shaft(s_gone, 0.0, 0.0, 0.0, 0.0, 0.0, Color(1.0, 0.55, 0.18), 0.0, 0.0, 0.0, 0.0)


func _silo_ambient_steam(vfx: RocketVfx, s: Dictionary, delta: float, hole: Vector2, phase: int, glow: float, ember: float) -> void:
	if glow > 0.05:
		return
	if phase == SILO_CLOSING and ember > 0.05:
		s["steam_t"] = float(s.get("steam_t", 0.0)) + delta * 4.5 * ember
		while float(s["steam_t"]) >= 1.0:
			s["steam_t"] = float(s["steam_t"]) - 1.0
			var off := Vector2.from_angle(randf() * TAU) * randf_range(0.2, 1.6)
			vfx.emit_smoke(
				Vector3(hole.x + off.x, 0.4, hole.y + off.y),
				Vector3(off.x * 0.4, randf_range(1.8, 3.4), off.y * 0.4) + WIND,
				randf_range(1.1, 1.7), randf_range(3.4, 5.2), randf_range(2.4, 3.6),
				Color(0.86, 0.85, 0.84, 0.42), ember * 0.35, 0.8, 0.55, 0.35)


func _phase_sound(phase: int, at: Vector2) -> void:
	match phase:
		SILO_OPENING:
			_sound("base/sound/silo-alarm", at, 0.8)
			_sound("base/sound/silo-doors", at, 0.8)
		SILO_RISING:
			_sound("base/sound/silo-raise-rocket", at, 1.0)
		SILO_UP:
			_sound("base/sound/silo-clamps-on", at, 1.0)
		SILO_CLOSING:
			_sound("base/sound/silo-doors", at, 0.8)


## The silo's own rocket mover stays hidden while ours flies.
func _hide_rocket_mover(at: Vector2) -> void:
	if movers == null:
		return
	for pair in movers.units_of_type("rocket-silo-rocket"):
		var node: Node3D = pair[1]
		if Vector2(node.position.x, node.position.z).distance_to(at) < 6.0:
			node.visible = false


# --- cargo pods -------------------------------------------------------------------------------

func _update_pods(delta: float) -> void:
	if movers == null:
		return
	var seen := {}
	for pair in movers.units_of_type("cargo-pod"):
		var unit: int = pair[0]
		var node: Node3D = pair[1]
		if unit == ridden:
			node.visible = false
			continue
		seen[unit] = true
		var info = model.cargo_pods.get(unit)
		var state := str(info.get("state", "")) if info is Dictionary else ""
		var p: Dictionary = _pods.get(unit, {})
		if p.is_empty() or p["state"] != state:
			p = {"state": state, "t": 0.0}
			_pods[unit] = p
		p["t"] = float(p["t"]) + delta
		var t: float = p["t"]
		var h := 0.0
		var ground: Vector3 = node.position
		if state == "ascending":
			# Factorio has no height: a rising pod moves north across the map. Its climb is that
			# northward travel, from where it set off (H2: it slid across the ground instead).
			if not p.has("from"):
				p["from"] = Vector3(ground.x, 0.0, ground.z)
			var from: Vector3 = p["from"]
			h = maxf(0.0, from.z - ground.z) + 0.5 * ASCENT_ACCELERATION * t * t
			node.position.x = from.x
			node.position.z = from.z
			# A pod a silo launches rides inside its rocket, which our launch draws: Factorio doesn't
			# show it either. Only a pod leaving a hub or a pad is seen climbing.
			# Looked at again while there is none: the silo's chunk can arrive after the pod does.
			if not bool(p.get("in_rocket", false)) and t >= float(p.get("silo_look", 0.0)):
				p["silo_look"] = t + 0.5
				p["in_rocket"] = movers.world != null and movers.world.has_near("rocket-silo", Vector2(from.x, from.z), SILO_REACH)
		elif state == "descending":
			var to = info.get("to") if info is Dictionary else null
			if to is Vector2:
				# Factorio has no height: a falling pod moves south across the map to where it lands.
				# That travel is its height, straight above the landing spot (it slid across the ground).
				h = maxf(0.0, (to as Vector2).y - ground.z)
				node.position.x = (to as Vector2).x
				node.position.z = (to as Vector2).y
			else:
				var f := clampf(1.0 - t / DESCENT_TIME, 0.0, 1.0)
				h = DESCENT_HEIGHT * f * f
		node.position.y = h
		# A pod waiting in its rocket (cargo_pod_state "awaiting_launch") is Factorio's own entity
		# beside the silo's centre; the rocket waiting in the shaft already carries it, so it isn't
		# drawn on the ground beside the silo (owner: "a rocket pod beside it").
		# With no state yet (`cp` comes every 10 ticks) it isn't known where to draw it: a falling pod
		# would stand on the ground out on its route until then.
		node.visible = h < 200.0 and state != "" and state != "awaiting_launch" and not bool(p.get("in_rocket", false))
	for unit in _pods.keys():
		if not seen.has(unit):
			_pods.erase(unit)


# --- asteroid chunks --------------------------------------------------------------------------

func _on_chunks() -> void:
	# Each update (every 10 ticks) is matched to the chunks already drawn, so a chunk keeps its own
	# tumble and eases off the small gap between where it was drawn and where the game has it,
	# instead of snapping (F5).
	var now := Time.get_ticks_msec()
	var since := (now - _chunks_msec) / 1000.0
	var was := {}  # name -> [[drawn position, phase, sent position, measured velocity or null], ...]
	for name in _chunk_meshes:
		var drawn: Array = []
		for c: Dictionary in (_chunk_meshes[name] as MultiMeshInstance3D).get_meta("chunks", []):
			drawn.append([_chunk_at(c, since), float(c.get("phase", 0.0)), c["position"], c.get("measured")])
		was[name] = drawn
	_chunks_msec = now
	var by_name := {}
	for c: Dictionary in model.asteroid_chunks:
		var phase := fposmod(c["position"].x * 1.7 + c["position"].y * 3.1, TAU)
		var offset := Vector2.ZERO
		var best := MATCH_DISTANCE
		var match_d: Array = []
		for d: Array in was.get(c["name"], []):
			var gap: Vector2 = d[0] - c["position"]
			if gap.length() < best:
				best = gap.length()
				phase = d[1]
				offset = gap
				match_d = d
		# G2: the sent movement assumes 60 UPS and leaves out a travelling platform's own drift, so
		# moving a chunk on by it left a gap at every update, closed six times a second (a stutter).
		# A chunk seen before moves on by how far it really went between updates, smoothed.
		if not match_d.is_empty() and since > 0.05:
			var measured: Vector2 = (c["position"] - (match_d[2] as Vector2)) / since
			if match_d[3] != null:
				measured = (match_d[3] as Vector2).lerp(measured, 0.4)
			c["measured"] = measured
			c["velocity"] = measured
		c["phase"] = phase
		c["offset"] = offset
		var list: Array = by_name.get(c["name"], [])
		list.append(c)
		by_name[c["name"]] = list
	for name in _chunk_meshes:
		if not by_name.has(name):
			(_chunk_meshes[name] as MultiMeshInstance3D).multimesh.visible_instance_count = 0
	for name in by_name:
		var mmi := _chunk_mesh(str(name))
		var list: Array = by_name[name]
		if mmi.multimesh.instance_count < list.size():
			mmi.multimesh.instance_count = maxi(list.size(), mmi.multimesh.instance_count * 2)
		mmi.multimesh.visible_instance_count = list.size()
		mmi.set_meta("chunks", list)
	_place_chunks()


## A chunk's mesh: the small asteroid of its kind ("metallic-asteroid-chunk" -> small-metallic-asteroid),
## scaled down. The model is read on a worker thread (asked for with ready(); mesh_for alone parsed
## the .glb in the frame of the first update), a ball standing in until it is there or if there is none.
func _chunk_mesh(name: String) -> MultiMeshInstance3D:
	var mmi: MultiMeshInstance3D = _chunk_meshes.get(name)
	if mmi == null:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = chunk_ball()
		mm.instance_count = 16
		mm.visible_instance_count = 0
		mmi = MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.set_meta("model", "small-%s-asteroid" % name.trim_suffix("-asteroid-chunk"))
		add_child(mmi)
		_chunk_meshes[name] = mmi
	if mmi.has_meta("model") and ModelLibrary.ready(str(mmi.get_meta("model"))):
		var mesh := ModelLibrary.mesh_for(str(mmi.get_meta("model")))
		if mesh != null:
			mmi.multimesh.mesh = mesh
		mmi.remove_meta("model")
	return mmi


## The ball drawn for an asteroid chunk without its model (here and in collectors.gd's claws).
static var _ball: SphereMesh = null
static func chunk_ball() -> SphereMesh:
	if _ball == null:
		_ball = SphereMesh.new()
		_ball.radius = 0.5
		_ball.height = 0.9
	return _ball


## Where a chunk is drawn `dt` seconds after its update: moved on by its velocity, with the gap to
## where it was drawn before fading out over a fraction of a second.
static func _chunk_at(c: Dictionary, dt: float) -> Vector2:
	var offset: Vector2 = c.get("offset", Vector2.ZERO)
	return c["position"] + c["velocity"] * dt + offset * exp(-dt * CHUNK_SETTLE)


func _place_chunks() -> void:
	var dt := (Time.get_ticks_msec() - _chunks_msec) / 1000.0
	var t := Time.get_ticks_msec() / 1000.0
	for name in _chunk_meshes:
		var mmi: MultiMeshInstance3D = _chunk_meshes[name]
		var list: Array = mmi.get_meta("chunks", [])
		for i in mini(list.size(), mmi.multimesh.visible_instance_count):
			var c: Dictionary = list[i]
			# A chunk an asteroid collector's arm holds is drawn in its claw (collectors.gd).
			if c.get("held", false):
				mmi.multimesh.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3.ONE * 0.0001), Vector3.ZERO))
				continue
			var p := _chunk_at(c, dt)
			var spin := Basis(Vector3(0.3, 1, 0.2).normalized(), t * 0.8 + float(c.get("phase", 0.0)))
			mmi.multimesh.set_instance_transform(i, Transform3D(spin.scaled(Vector3.ONE * CHUNK_SCALE), Vector3(p.x, CHUNK_HEIGHT, p.y)))


func _process(delta: float) -> void:
	_sync_world_silos()
	_update_launches(delta)
	_update_silos(delta)
	_update_pods(delta)
	_hide_flying_rockets()
	_place_chunks()
	if _vfx != null:
		var sprites: Variant = fx.get("sprites") if fx != null else null
		if sprites != null:
			_vfx.night = float(sprites.get("night"))
		_vfx.step(delta)


## The game's own rocket moves north across the map once it lifts off (Factorio draws its height
## that way); our launch draws the flight, so a rocket mover that has moved is hidden (H2: rockets
## slid across the ground away from their silos).
func _silo_pos(silo_unit: int, fallback: Vector2) -> Vector2:
	if silo_unit != 0 and movers != null and movers.world != null:
		var pos_map: Variant = movers.world.get("silo_positions")
		if pos_map is Dictionary and (pos_map as Dictionary).has(silo_unit):
			return (pos_map as Dictionary)[silo_unit] as Vector2
	return fallback


func _hide_flying_rockets() -> void:
	if movers == null:
		return
	var seen := {}
	for pair in movers.units_of_type("rocket-silo-rocket"):
		var unit: int = pair[0]
		var node: Node3D = pair[1]
		seen[unit] = true
		var at := Vector2(node.position.x, node.position.z)
		if not _rocket_start.has(unit):
			_rocket_start[unit] = at
		var on_silo := _on_silo(unit, at)
		var silo_unit := int((_rocket_silo.get(unit, [0, 0]) as Array)[0])
		var silo_at := _silo_pos(silo_unit, at)
		var flying_away := (not on_silo) or _launch_near(silo_at) or at.distance_to(silo_at) > 4.8 or at.y < silo_at.y - 3.6
		if flying_away:
			node.visible = false
			_rocket_hidden[unit] = true
		elif _rocket_hidden.has(unit) and not movers.is_fogged(unit):
			# Its silo's chunk came after it (or reload brought it back inside the silo).
			_rocket_hidden.erase(unit)
			node.visible = true
		if node.visible:
			node.position.y = _waiting_height(silo_unit, silo_at)
			if ModelLibrary.rocket_vfx_enhanced:
				var hole := _hole_pos(silo_at)
				node.position.x = hole.x
				node.position.z = hole.y
	for unit in _rocket_start.keys():
		if not seen.has(unit):
			_rocket_start.erase(unit)
			_rocket_silo.erase(unit)
			_rocket_hidden.erase(unit)


func _launch_near(at: Vector2) -> bool:
	for l in _launches:
		if (l["at"] as Vector2).distance_to(at) < 6.0:
			return true
	return false


## How high a rocket in its silo is drawn: down the shaft until the doors are open, then rising
## smoothly on the elevator cradle to its waiting pad position.
func _waiting_height(silo_unit: int, silo_at: Vector2) -> float:
	if silo_unit == 0:
		return -Visuals.ROCKET_SINK
	var s := _watch(silo_unit, silo_at)
	s["keep"] = DOOR_TIME + 0.5
	if ModelLibrary.rocket_vfx_enhanced:
		return -Visuals.ROCKET_SINK - RISE_DEPTH_3D * (1.0 - float(s.get("lift", 0.0)))
	var risen := 1.0
	match int(s["phase"]):
		SILO_OPENING:
			risen = 0.0
		SILO_RISING:
			risen = clampf(float(s["since"]) / RISE_TIME, 0.0, 1.0)
	return -Visuals.ROCKET_SINK - RISE_DEPTH * (1.0 - risen)


## A rocket is drawn standing only in a silo. Joining a game with rockets already in flight, the
## first place they were seen is out over the map, so they stood on the ground there, silo-less.
func _on_silo(unit: int, at: Vector2) -> bool:
	var now := Time.get_ticks_msec()
	var known: Array = _rocket_silo.get(unit, [0, 0])
	if now >= int(known[1]):
		known = [int(movers.world.unit_near("rocket-silo", at, SILO_REACH)) if movers.world != null else 0, now + 500]
		_rocket_silo[unit] = known
	return int(known[0]) != 0
