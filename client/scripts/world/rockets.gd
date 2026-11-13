extends Node3D
## Space Age's travel in 3D: a rocket leaving its silo, cargo pods coming down and going up, and
## asteroid chunks drifting past a platform.
##
## Rockets, as Factorio's silo does it (its prototypes' timings and sprites, from the player's
## install): the silo says where its rocket is (`st`, 2 to 5): the red lights blink and the doors
## open (anim.gd), the rocket rises RISE_DEPTH up the shaft and waits with its nose in the hatch.
## On `rk` (a launch was ordered, ui_model.rocket_launched) the engines start, shaking it, their
## light and steam coming up through the hatch, and at LIFT_AFTER it climbs at the game's pace out
## of the shaft, on the jet, with the smoke columns round the hatch and a billow across the ground.
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

var _launches: Array = []        # [{"node", "light", "at" (Vector2), "t", "cards"}]
var _silos := {}                 # silo unit -> {"at", "phase", "since", "keep", "glow", "cards"}, while busy
var _pods := {}                  # unit -> {"state", "t"}
var _chunk_meshes := {}          # chunk name -> MultiMeshInstance3D
var _chunks_msec := 0            # when the chunks drawn now were sent (Time.get_ticks_msec)


func _ready() -> void:
	# Asked for now, read on a worker thread: made here at a launch it took 36-48 ms in that frame
	# on the owner's save (its silos launch on their own).
	ModelLibrary.ready("rocket-silo-rocket")
	model.rocket_launched.connect(_on_launch)
	model.asteroid_chunks_changed.connect(_on_chunks)


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
## has lit (0 to 1), from the game's flight (ride.gd). Starts the launch if `rk` hasn't yet.
func drive(at: Vector2, height: float, ignition: float) -> void:
	var l := _launch_at(at)
	if l.is_empty():
		_on_launch(0, at, "")
		l = _launches[-1]
	l["driven"] = true
	l["h"] = height
	l["ign"] = ignition
	l["seen"] = 0.0


func _launch_at(at: Vector2) -> Dictionary:
	for l in _launches:
		if (l["at"] as Vector2).distance_to(at) < 3.0:
			return l
	return {}


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
	if surface != "" and launch_surface != "" and launch_surface != surface:
		return
	# Only out of a silo the world has: `rk` comes for every silo the force has, wherever it stands.
	if movers != null and movers.world != null and not movers.world.has_near("rocket-silo", at, SILO_REACH):
		return
	var root := Node3D.new()
	root.position = Vector3(at.x, -Visuals.ROCKET_SINK, at.y)
	var body := MeshInstance3D.new()
	body.mesh = ModelLibrary.mesh_for("rocket-silo-rocket") if ModelLibrary.ready("rocket-silo-rocket") else null
	if body.mesh == null:  # no model (or not read yet): a white rocket of the right size
		var c := CylinderMesh.new()
		c.top_radius = 0.9
		c.bottom_radius = 1.0
		c.height = 12.0
		body.mesh = c
		body.position.y = 6.0
	root.add_child(body)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.65, 0.3)
	light.omni_range = 30.0  # base_engine_light's and glow_light's size
	light.light_energy = 0.0
	add_child(root)
	add_child(light)
	_launches.append({"node": root, "light": light, "at": at, "t": 0.0, "cards": {}, "steam": 0.0, "billow": 0.0, "trail": 0.0})
	_sound("base/sound/silo-clamps-off", at, 0.8)


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
	for l in _launches:
		l["t"] = float(l["t"]) + delta
		var t: float = l["t"]
		var root: Node3D = l["node"]
		var light: OmniLight3D = l["light"]
		var at: Vector2 = l["at"]
		var driven := bool(l.get("driven", false))
		var ignition := ignition_at(t)
		var climbed := climb_at(t - LIFT_AFTER)
		if driven:
			ignition = float(l["ign"])
			climbed = float(l["h"])
			l["seen"] = float(l["seen"]) + delta
		var y := -Visuals.ROCKET_SINK + climbed
		# The engines shake it in its clamps, less as it gets away.
		var shake := 0.04 * ignition * (1.0 - clampf(climbed / 40.0, 0.0, 1.0))
		root.position = Vector3(at.x + sin(t * 53.0) * shake, y, at.y + cos(t * 47.0) * shake)
		var flicker := 0.85 + 0.15 * sin(t * 37.0)
		(root.get_child(0) as MeshInstance3D).set_instance_shader_parameter("f3d_glow", ignition)  # rocket-static-emission
		# Until the engines are out of the shaft their light comes up through the hatch.
		var glow_y := maxf(y, HATCH_GLOW_HEIGHT)
		light.position = Vector3(at.x, glow_y, at.y)
		light.light_energy = 6.0 * ignition * flicker
		var far := 1.0 - clampf((climbed - 120.0) / 120.0, 0.0, 1.0)
		var cards: Dictionary = l["cards"]
		_held(cards, "jet", "rocket-jet", Vector3(at.x, y - 2.6, at.y), 6.5 + clampf(climbed / 20.0, 0.0, 2.5), ignition * flicker, Color.WHITE, JET_FPS)
		_held(cards, "glare", "rocket-glare", Vector3(at.x, glow_y, at.y), 15.0, 0.75 * ignition * far * flicker)
		_smoke_columns(cards, at, climbed)
		_exhaust(l, delta, at, y, ignition, climbed)
		var silo := _silo_at(at)
		if not silo.is_empty():
			silo["glow"] = ignition * (1.0 - clampf(climbed / 60.0, 0.0, 1.0))
			silo["keep"] = DOOR_TIME + 0.5
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


## Factorio's smoke columns round the hatch (rocket_smoke_top1-3, bottom1-2), which come in once the
## rocket is 4.5 to 7.5 tiles on its way and thin out as it goes.
func _smoke_columns(cards: Dictionary, at: Vector2, climbed: float) -> void:
	var alpha := clampf((climbed - SMOKE_FROM) / (SMOKE_FULL - SMOKE_FROM), 0.0, 1.0) * (1.0 - clampf((climbed - 90.0) / 110.0, 0.0, 1.0))
	if alpha <= 0.0 and cards.is_empty():
		return
	for i in SMOKE_COLUMNS.size():
		var spot: Vector3 = SMOKE_COLUMNS[i]
		var width: float = spot.y
		_held(cards, "smoke%d" % i, "rocket-smoke", Vector3(at.x + spot.x, width * 1.79 - 0.5, at.y + spot.z), width, alpha, SMOKE_TINT, SMOKE_FPS)


## Steam out of the hatch while the engines start, a billow across the ground as the exhaust comes
## out of the shaft, then a trail behind the rocket. Factorio's smoke sheet on each.
func _exhaust(l: Dictionary, delta: float, at: Vector2, y: float, ignition: float, climbed: float) -> void:
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
		s = {"unit": unit, "at": at, "phase": 0, "since": 0.0, "keep": DOOR_TIME + 0.5, "glow": 0.0, "cards": {}}
		_silos[unit] = s
	return s


## What a busy silo shows besides its doors (anim.gd): the shaft's walls under them, lit by the
## engines, and the red lights blinking round the hatch before the doors move.
func _update_silos(delta: float) -> void:
	var gone: Array = []
	for unit: int in _silos:
		var s: Dictionary = _silos[unit]
		var at: Vector2 = s["at"]
		var phase := int(movers.world.working.get(unit, 0)) if movers != null and movers.world != null else 0
		if phase != int(s["phase"]):
			if phase >= SILO_OPENING or int(s["phase"]) >= SILO_OPENING:
				_phase_sound(phase, at)
			s["phase"] = phase
			s["since"] = 0.0
		s["since"] = float(s["since"]) + delta
		if phase >= SILO_OPENING and phase != SILO_CLOSING:
			s["keep"] = DOOR_TIME + 0.5
		s["keep"] = float(s["keep"]) - delta
		if float(s["keep"]) <= 0.0:
			gone.append(unit)
			continue
		var cards: Dictionary = s["cards"]
		var ground := Vector3(at.x, SHAFT_HEIGHT, at.y)
		_held(cards, "hole", "silo-hole", ground, SHAFT_WIDTH, 1.0)
		_held(cards, "light", "silo-hole-light", ground + Vector3(0.0, 0.01, 0.0), SHAFT_WIDTH, float(s["glow"]))
		var blink := 0.0
		if phase == SILO_OPENING or phase == SILO_CLOSING:
			blink = 0.5 + 0.5 * sin(float(s["since"]) * TAU / BLINK_TIME - PI / 2.0)
		for i in RED_LIGHTS.size():
			var spot: Vector2 = RED_LIGHTS[i]
			_held(cards, "red%d" % i, "silo-light", Vector3(at.x + spot.x, RED_LIGHT_HEIGHT, at.y + spot.y), 1.2, blink)
	for unit in gone:
		_drop_cards(_silos[unit]["cards"])
		_silos.erase(unit)


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
		# The sent movement assumes 60 UPS and leaves out a travelling platform's own drift, so
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
	_update_launches(delta)
	_update_silos(delta)
	_update_pods(delta)
	_hide_flying_rockets()
	_place_chunks()


## The game's own rocket moves north across the map once it lifts off (Factorio draws its height
## that way); our launch draws the flight, so a rocket mover that has moved is hidden (H2: rockets
## slid across the ground away from their silos).
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
		if at.distance_to(_rocket_start[unit]) > 0.5 or not _on_silo(unit, at):
			node.visible = false
			_rocket_hidden[unit] = true
		elif _rocket_hidden.has(unit) and not _launch_near(at) and not movers.is_fogged(unit):
			# Its silo's chunk came after it: the rocket was standing in a silo all along.
			_rocket_hidden.erase(unit)
			node.visible = true
		if node.visible:
			node.position.y = _waiting_height(unit, at)
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


## How high a rocket in its silo is drawn: down the shaft until the doors are open, then rising to
## where it waits.
func _waiting_height(unit: int, at: Vector2) -> float:
	var silo_unit := int((_rocket_silo.get(unit, [0, 0]) as Array)[0])
	if silo_unit == 0:
		return -Visuals.ROCKET_SINK
	var s := _watch(silo_unit, at)
	s["keep"] = DOOR_TIME + 0.5
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
