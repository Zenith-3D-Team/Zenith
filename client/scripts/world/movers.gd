extends Node3D
## Things that move: biters, cars, trains, robots, asteroids, other characters. The mod sends their
## positions every few ticks within the focus radius. Each is drawn on the game's own clock (the
## messages' tick), a little behind it, between its last two positions: steady motion, where
## chasing each new position made fast movers (robots, asteroids) lurch and stall.
## A mover missing from several frames in a row has left the area (or died) and is removed.
##
## Flying robots and walking creatures, hundreds at a time in a fight or over a busy base, are drawn
## on the GPU instead (mover_records.gd): when a new position of one arrives, its last few positions
## and the clock ticks it is drawn at each go into its record, and the shaders work out where it is
## each frame. Nothing is done for them here per frame; where one is drawn is worked out when
## something asks (position_of, robot_near). The rest (cars, trains, spidertrons, pods, characters),
## few and with parts moved by vehicle_anim.gd, are still moved here every frame on their nodes.

const ProtoDB := preload("res://scripts/world/protos.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const WireDecode := preload("res://scripts/net/wire_decode.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const Creatures := preload("res://scripts/world/creatures.gd")
const CreatureModels := preload("res://scripts/world/creature_models.gd")
const Avatar := preload("res://scripts/player/avatar.gd")
const GameClock := preload("res://scripts/world/game_clock.gd")
const MomentHold := preload("res://scripts/world/moment_hold.gd")
const VehicleAnim := preload("res://scripts/world/vehicle_anim.gd")
const RobotSwarm := preload("res://scripts/world/robot_swarm.gd")
const MoverRecords := preload("res://scripts/world/mover_records.gd")
const SpriteStandins := preload("res://scripts/world/sprite_standins.gd")
const Probing := preload("res://scripts/debug/probing.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const VehicleLights := preload("res://scripts/world/vehicle_lights.gd")
const Switches := preload("res://scripts/switches.gd")

const MISSING_FRAMES := 3
const FOLLOW_RATE := 15.0
## A jump this far (tiles) between two positions is a teleport, not motion: no gliding across.
const TELEPORT := 12.0
## Tiles a tick, a little over the fastest train's (a locomotive's 1.2 with the best fuel's bonus).
const TRAIN_SPEED := 1.6
## Positions kept per mover, enough to cover a burst of late messages, and more while it is drawn
## further back than they reach.
const HISTORY := 8
const HISTORY_MAX := 48
## Longer than this between two positions is standing still, not a coarse update (Factorio moves a
## flying robot's reported position about every 20 ticks).
const STILL_TICKS := 40.0
const ENEMY_TYPES := ["unit", "spider-unit", "segmented-unit", "segment"]
## Flying robots get Factorio's drop shadow instead of a lit one: their model squashed flat on
## the ground, offset as their shadow sprites are (31.75, 19.75 px at scale 0.5 from the robot's
## position: 0.99 tiles east, 0.62 tiles down the screen, which is 0.83 tiles south on the ground).
const ROBOT_TYPES := {"logistic-robot": true, "construction-robot": true, "combat-robot": true, "capture-robot": true}
const SHADOW_OFFSET := Vector3(0.99, 0.0, 0.83)
const SHADOW_COLOR := Color(0.0, 0.0, 0.0, 0.45)
## Cells (tiles) of the grid robot_near and friendly_near look in.
const GRID := 8.0
## Simulated worker robots (`rb`): wire state & flag bits and client blend/sweep tuning.
const RB_FLY_TARGET := 0
const RB_FLY_DIR := 1
const RB_HOVER := 2
const RB_ORBIT := 3
const RB_FOLLOW := 4
const RB_CARGO := 8
const RB_LOW_E := 16
const RB_HAS_NEXT := 32
const RB_NEXT_CARGO := 64
const RB_WORKING := 128
const RB_CHARGING := 256
const RB_SNAP := 512
const SIM_BLEND_DECAY := 8.0
const SIM_BLEND_MAX := 16.0
const SIM_EXPIRE_TICKS := 360.0
const SIM_GRID_SLICE := 128
## Creatures moved here (characters, and creatures whose model can't walk on the GPU) further than
## these from the focus are moved every second and every third frame (their walk is animated in the
## shader, so only their place steps).
const CREATURE_NEAR := 40.0
const CREATURE_FAR := 80.0
## GPU-drawn movers checked against the remote view's fog a frame (a slice of them, round and round).
const FOG_SLICE := 64
## Tiles a GPU-drawn robot can be drawn from its newest position (it is drawn about a step behind).
const DRAWN_SLACK := 3.0
## A card mover moving less than this a frame (tiles) stands still: its picture stops stepping.
const CARD_STILL := 0.002


class Mover:
	var unit := 0
	var node: Node3D
	var target := Vector3.ZERO
	var yaw_goal := 0.0
	var oriented := false
	var last_orient := WireDecode.NO_ORIENTATION
	var missing := 0
	var enemy := false
	var robot := false
	var shadow: Node3D  # robots' drop shadow, or null
	## Drawn with the others of its kind (robot_swarm.gd), its node left empty; or null.
	var bot: RobotSwarm.Bot
	var type := ""  # its prototype's type
	var height := 0.0  # Visuals.flying_height of its type
	var on_rails := false  # rolling stock: drawn at the rails' height under it (elevated, ramps)
	var rail_h := 0.0
	## Wheels (a car's, a train's axles): [MeshInstance3D, AnimPart, radius, steers, turn].
	var wheels: Array = []
	## Front fenders / steering linkages (`anim_steer_front`): [MeshInstance3D, AnimPart].
	var steers: Array = []
	var steer := 0.0
	## Emissive headlight meshes (`anim_headlight`), lit in sync with VehicleLights.
	var headlight_meshes: Array[MeshInstance3D] = []
	## Its model's meshes lifted whole onto the hills from its origin (Creatures.mark_rigid; _lift_at).
	var lift_meshes: Array[MeshInstance3D] = []
	var lift_at := Vector2.INF

	## A locomotive's headlights (Factorio's `front_light`: two cones 0.6 tiles either side).
	var headlights: Array[SpotLight3D] = []
	## A car's, tank's or spidertron's own lights (vehicle_lights.gd), or null.
	var lights: Node3D
	## Where its lights last saw it and when (seconds) it last moved: one driven by anybody lights.
	var light_seen := Vector3.INF
	var light_moved := -1.0e9

	var proto_id := 0
	var fixed := Vector2i.ZERO  # the latest position as sent, for commands that name the mover
	## The last few positions it moved to and their ticks, oldest first (messages can arrive in
	## bursts). Only changes are kept: Factorio moves robots' (and asteroids') reported position
	## about every 20 ticks, a tile at a time (2.1.23), though it draws them gliding.
	var ticks: Array[float] = []
	var spots: Array[Vector3] = []
	## Ticks between its position changes, measured: 2 for a car, about 20 for a robot.
	var key_gap := 2.0
	var lag := -1.0  # ticks behind the clock it is drawn, eased (_process_movers)
	var from := Vector3.ZERO  # the position before the newest (its direction of travel)
	var to_tick := -1.0
	var fogged := false  # hidden by the remote view where no radar sees
	## Drawn by creatures.gd; `stagger` spreads far ones' updates over frames (_process_movers).
	var creature := false
	var stagger := 0
	## Its record (mover_records.gd) when the GPU draws it, else -1: its node isn't moved then.
	var slot := -1
	var rec_flags := 0  # its record's flags (BUILDER, ANIMATED, CARGO; HIDDEN is `fogged`)
	var kind := Vector4.ZERO  # its record's kind values (creatures: gait seed, radians a tile, bob scale)
	var walked := 0.0  # tiles it walked to its newest position (creatures' gait)
	var recorded := false  # its record has been written (it has a position)
	var cell := Vector2i(1 << 30, 0)  # its cell in _robot_grid (GPU-drawn robots)
	## A mod's mover without a model: its own Factorio picture on a card (_update_card), or null.
	var card: MeshInstance3D
	var card_quarter := -1  # the direction (0-3, north first) its picture is of
	var card_generation := -1  # SpriteStandins.generation when it was picked
	var card_run := -1  # 1 while it moves (its frames step), 0 standing still, -1 not set yet
	## Client/GPU simulated worker robot (`rb`) leg state: evaluated without 20-tick limbo stalls.
	var sim := false
	var sim_state := 0
	var sim_flags := 0
	var sim_t0 := 0.0
	var sim_start := Vector2.ZERO
	var sim_end1 := Vector2.ZERO
	var sim_end2 := Vector2.ZERO
	var sim_t_arr1 := 0.0
	var sim_t_arr2 := 0.0
	var sim_speed := 0.05
	var sim_ori := 0.0
	var sim_follow_unit := 0
	var sim_heard_tick := 0.0
	var sim_orbit_r := 2.5
	var sim_orbit_rate := 0.0
	var sim_orbit_phase := 0.0
	var sim_err := Vector2.ZERO
	var sim_t_write := 0.0
	var sim_hover_still := 0.0


## --mover-pick-all: scan GPU-drawn movers too in pick/pick_ray/units_of_type/set_night instead of _node_movers alone.
static var pick_node_movers := not (Switches.has("--mover-pick-all"))

var protos: ProtoDB
## Types that ride rails, drawn at the rails' height (elevated rails, ramps).
const ROLLING_STOCK := {"locomotive": true, "cargo-wagon": true, "fluid-wagon": true, "artillery-wagon": true,
	"infinity-cargo-wagon": true}
## The world mirror (world.gd), for the rails under rolling stock (rail_height). Untyped.
var world
## The character the client controls is drawn by the avatar instead.
var puppet_unit := 0
## The vehicle that character sits in (Avatar.vehicle), or 0: its lights shine at night (N1).
var driven := 0
## Movers carrying vehicle lights: unit -> Mover.
var _lit := {}
## The remote view's coverage (remote_fog.gd), or null: movers where it doesn't see are hidden.
var fog: Node3D = null

var _movers := {}  # unit -> Mover
var _sim_movers := {}  # unit -> Mover (simulated worker robots driven by `rb`)
var _follow_movers := {}  # unit -> Mover (`FOLLOW` targets steered dynamically)
var _sim_sweep_list: Array = []
var _sim_sweep_at := 0
## Entity properties overlay from ui_model.gd (robot flight speeds/energy multipliers).
var eprops := {}
var robot_speed_mult := 1.0
## Live character position updated by main.gd so `FOLLOW` toward puppet_unit tracks smoothly.
var avatar_pos := Vector3.ZERO
## How many movers of each type there are (type -> count), so units_of_type() needn't go through
## every mover when there are none of that type (rockets.gd asks twice a frame).
var _type_counts := {}
var _gpu_type_counts := {}  # type -> count of movers currently on GPU records (m.slot >= 0)
## The movers moved here every frame (not drawn from a record): unit -> Mover.
var _node_movers := {}
## Records of the movers the GPU draws.
var records := MoverRecords.new()
## GPU-drawn robots by GRID cell of their newest position, kept as positions arrive: cell -> {Mover: true}.
var _robot_grid := {}
var _fogging := false
var _fog_list: Array = []  # GPU-drawn movers' units, checked against the fog a slice a frame
var _fog_at := 0
var _beam := 0.0  # how much the headlights show (Avatar.beam of the night)
var _frame_tick := -1
## The game's tick as the client reckons it, run on at the game's measured rate (game_clock.gd).
var clock := GameClock.new()
var _seen := {}
## Movers whose model is still being made on a worker thread (ModelLibrary.ready): unit -> true.
## They move about with nothing drawn and get their model (_dress) once it is ready.
var _waiting := {}
var _model_generation := -1
var _materials := {}  # proto id -> Material
var _shadow_material: ShaderMaterial
## Biters and spitters are drawn and animated together (creatures.gd); their nodes stay empty.
var creatures := Creatures.new()
## Vehicles' and robots' moving parts and glow (spidertron legs, robots, cargo pods, treads).
var vehicles := VehicleAnim.new()
## Flying robots, drawn together.
var robots := RobotSwarm.new()
## Non-enemy movers moved here by GRID cell, built at most once a frame when asked (robot_near, friendly_near).
var _grid := {}
var _grid_frame := -1
var _frame := 0
## The last frame's _process time, microseconds (--robot-probe).
var process_usec := 0
## Movers whose model has arrived (ModelLibrary.generation) are dressed (their meshes, moving parts,
## shadows and cards made, robot batches made again on the new mesh) for at most this long a frame,
## at least one a frame: a join's robots and rolling stock all wait for the same few models, and
## dressing every one in the frame the model came was a 150-180 ms frame at -62,-26.
## --movers-dress-usec=N (1500; 0: all at once, as before).
static var dress_usec := 1500
static var _dress_arg_read := false
var _to_dress := {}  # unit -> true: waiting movers whose model is ready, dressed within dress_usec a frame
var _refresh_due := false  # robots' batches still to be made again on a new mesh (robots.refresh)
var _frame_f := -1.0
var _stale_gap := 60.0


func _ready() -> void:
	creatures.name = "Creatures"
	add_child(creatures)
	vehicles.name = "VehicleAnim"
	add_child(vehicles)
	robots.name = "Robots"
	robots.vehicles = vehicles
	robots.records = records
	add_child(robots)
	creatures.pose_source = records.state
	creatures.records = records


func reset() -> void:
	for m in _movers.values():
		_free(m)
	_movers.clear()
	_sim_movers.clear()
	_follow_movers.clear()
	_sim_sweep_list.clear()
	_sim_sweep_at = 0
	_type_counts.clear()
	_gpu_type_counts.clear()
	_node_movers.clear()
	_robot_grid.clear()
	_fog_list.clear()
	_seen.clear()
	_waiting.clear()
	_lit.clear()
	_to_dress.clear()
	_refresh_due = false
	_frame_tick = -1
	_frame_f = -1.0
	_stale_gap = 60.0
	clock = GameClock.new()
	creatures.clear()
	vehicles.reset()
	robots.clear()
	_grid.clear()


func count() -> int:
	return _movers.size()


func _notification(what: int) -> void:
	# Robots' nodes are kept out of the tree (_dress), so nothing else frees them.
	if what == NOTIFICATION_PREDELETE:
		for m: Mover in _movers.values():
			if is_instance_valid(m.node) and not m.node.is_inside_tree():
				m.node.free()


## Movers still waiting for their model (--robot-probe waits for none).
func waiting() -> int:
	return _waiting.size()


## One part of a frame: {t: "mv", k: tick, part, parts, l: [[unit, proto, x, y, orientation?], ...]}, or
## from a binary frame (wire_decode.gd) `l` packed, WireDecode.MV_STRIDE numbers a record (orientation -1: none).
func handle(msg: Dictionary) -> void:
	var k := int(msg.get("k", 0))
	if k != _frame_tick:
		_end_frame()
		_frame_tick = k
	# p: the ticks until the next update, longer while the mod is slowed down (`rate`).
	clock.heard(k, float(msg.get("p", 0)))
	_frame_f = float(_frame_tick)
	_stale_gap = maxf(60.0, clock.gap * 4.0)
	var list = msg.get("l")
	if WireDecode.packed(list):
		_handle_packed(list)
		return
	if not (list is Array):
		return
	# z = 1: a record's first four numbers are the differences from the record before it.
	var deltas := int(msg.get("z", 0)) == 1
	var unit := 0
	var proto := 0
	var x := 0
	var y := 0
	for rec in list:
		if rec is Array and rec.size() >= 4:
			var r: Array = rec
			if deltas:
				unit += int(r[0])
				proto += int(r[1])
				x += int(r[2])
				y += int(r[3])
			else:
				unit = int(r[0])
				proto = int(r[1])
				x = int(r[2])
				y = int(r[3])
			_update(unit, proto, x, y, int(r[4]) if r.size() >= 5 else WireDecode.NO_ORIENTATION)


## A binary frame's movers: whole records of WireDecode.MV_STRIDE numbers, read straight from the packed list.
func _handle_packed(list: Variant) -> void:
	var stride := WireDecode.MV_STRIDE
	var n: int = list.size() - stride + 1
	var i := 0
	while i < n:
		_update(list[i], list[i + 1], list[i + 2], list[i + 3], list[i + 4])
		i += stride


func _end_frame() -> void:
	if _frame_tick < 0:
		return
	for unit in _movers.keys():
		var m: Mover = _movers[unit]
		if m.sim:
			continue
		if _seen.has(unit):
			m.missing = 0
		else:
			m.missing += 1
			if m.missing >= MISSING_FRAMES:
				creatures.remove(unit)
				_free(m)
				_count_type(m.type, -1)
				_movers.erase(unit)
				_node_movers.erase(unit)
				_lit.erase(unit)
				_waiting.erase(unit)
				vehicles.detach(unit)
	_seen.clear()


## One mover's record: its unit, prototype and place (fixed), and its orientation x 1000
## (WireDecode.NO_ORIENTATION for a mover that has none). The prototype is looked up only for a new mover
## (or one whose prototype changed).
func _update(unit: int, proto_id: int, x: int, y: int, orient: int) -> void:
	if unit == puppet_unit:
		return
	_seen[unit] = true
	var m: Mover = _movers.get(unit)
	var tick := _frame_f if _frame_f >= 0.0 else float(_frame_tick)
	var stale_gap := _stale_gap if _frame_f >= 0.0 else maxf(60.0, clock.gap * 4.0)
	if m != null and m.proto_id == proto_id and m.to_tick >= 0.0 and x == m.fixed.x and y == m.fixed.y \
			and orient == m.last_orient and tick - m.to_tick <= stale_gap:
		if tick > m.to_tick:
			m.from = m.target
		m.to_tick = tick
		return
	if m == null or m.proto_id != proto_id:
		var proto: ProtoDB.EntityProto = protos.entity(proto_id)
		if proto == null:
			return
		if m == null:
			m = Mover.new()
			m.unit = unit
			m.node = Node3D.new()
			m.node.position = Vector3(x / 256.0, Visuals.flying_height(proto.type), y / 256.0)
			if proto.type == "locomotive":
				_add_headlights(m)
			else:
				var light_key := proto.name if VehicleLights.has(proto.name) else proto.type
				if VehicleLights.has(light_key):
					m.lights = VehicleLights.build(light_key)
					m.node.add_child(m.lights)
					_lit[unit] = m
			m.enemy = ENEMY_TYPES.has(proto.type)
			m.robot = ROBOT_TYPES.has(proto.type)
			add_child(m.node)
			_movers[unit] = m
			_node_movers[unit] = m
			m.proto_id = proto_id
			if _model_ready(proto):
				_dress(unit, m, proto)
			else:
				_waiting[unit] = true
		if m.type != proto.type:
			_count_type(m.type, -1)
			_count_type(proto.type, 1)
		m.type = proto.type
		m.height = Visuals.flying_height(proto.type)
		m.on_rails = ROLLING_STOCK.has(proto.type)
	var pos := Vector3(x / 256.0, m.height, y / 256.0)
	# A train at full speed covers 1.4 tiles a tick, and simulated/legacy robots sleep up to 20 ticks:
	# grow the teleport threshold with ticks elapsed since the last actual position movement (`m.ticks[-1]`).
	var move_dt := tick - m.ticks[-1] if not m.ticks.is_empty() else tick - m.to_tick
	var teleport := maxf(TELEPORT, move_dt * TRAIN_SPEED)
	var fresh := m.to_tick < 0.0 or pos.distance_squared_to(m.target) > teleport * teleport or tick - m.to_tick > stale_gap
	var changed := fresh
	if fresh:
		# New, teleported, or not seen for a second: no gliding from where it was.
		m.ticks.clear()
		m.spots.clear()
		m.from = pos
		m.node.position = pos
	elif tick > m.to_tick:
		m.from = m.target
	if m.ticks.is_empty():
		m.ticks.append(tick)
		m.spots.append(pos)
	elif tick > m.ticks[-1] and pos != m.spots[-1]:
		var since := tick - m.ticks[-1]
		if since > maxf(m.key_gap * 3.0, STILL_TICKS):
			# It stood still: it set off about one step's time ago, not at the old position's tick.
			m.ticks.append(tick - m.key_gap)
			m.spots.append(m.spots[-1])
		else:
			m.key_gap = lerpf(m.key_gap, clampf(since, 1.0, STILL_TICKS), 0.5)
		var last_spot: Vector3 = m.spots[-1]
		var wdx := pos.x - last_spot.x
		var wdz := pos.z - last_spot.z
		m.walked += sqrt(wdx * wdx + wdz * wdz)
		m.ticks.append(tick)
		m.spots.append(pos)
		changed = true
		# Kept back as far as it is drawn behind (further while the mod is slowed down, `rate`):
		# drawn before its oldest position it would stand there.
		var keep := maxf(m.lag, clock.gap * GameClock.DELAY_SENDS) + m.key_gap * 2.0
		while m.ticks.size() > HISTORY_MAX or (m.ticks.size() > HISTORY and m.ticks[1] < tick - keep):
			m.ticks.remove_at(0)
			m.spots.remove_at(0)
	elif tick == m.ticks[-1] and pos != m.spots[-1]:
		m.spots[m.spots.size() - 1] = pos
		changed = true
	m.to_tick = tick
	m.target = pos
	m.proto_id = proto_id
	if x != m.fixed.x or y != m.fixed.y:
		m.fixed = Vector2i(x, y)
	m.last_orient = orient
	m.oriented = orient != WireDecode.NO_ORIENTATION
	var goal_was := m.yaw_goal
	if m.oriented:
		m.yaw_goal = Visuals.orientation_yaw(float(orient) / 1000.0)
		if fresh:
			m.node.rotation.y = m.yaw_goal  # appear facing its way, not turning into it (C1)
	else:
		var sx := m.target.x - m.from.x
		var sz := m.target.z - m.from.z
		if sx * sx + sz * sz > 0.0004:
			m.yaw_goal = atan2(-sx, -sz)
	if m.slot >= 0 and (changed or absf(m.yaw_goal - goal_was) > 0.0001):
		_write(m, fresh)


## Writes a GPU-drawn mover's record (mover_records.gd) from its history: its last four positions and
## their ticks, its lag (eased from where it is now towards what this update says, as
## _process_movers eases a node mover's), and what carries on from how it is drawn now (its facing,
## speed, flying, arms), so nothing jumps.
func _write(m: Mover, fresh: bool) -> void:
	var now := clock.tick
	if now < 0.0 or m.ticks.is_empty():
		return  # written once it has a position (a new mover is dressed before its first is kept)
	var want := maxf(clock.gap * GameClock.DELAY_SENDS, m.key_gap + clock.gap)
	var yaw0 := m.node.rotation.y
	var c0 := 0.0
	var c1 := 0.0
	var l0 := m.lag if m.lag >= 0.0 else want
	if m.recorded:
		yaw0 = records.yaw_at(m.slot, now)
		l0 = records.lag_at(m.slot, now)
		if m.bot != null:
			# Robots come every 20 ticks or so: their animation's state is worked out in full.
			var carry := records.robot_carry(m.slot)
			c0 = carry.x
			c1 = carry.y
	if fresh and m.oriented:
		yaw0 = m.yaw_goal
	m.recorded = true
	m.lag = l0
	var flags := m.rec_flags | (MoverRecords.HIDDEN if m.fogged else 0)
	# The lag eases as _process_movers eases a node mover's: towards two of the clock's gaps or a gap
	# and its own spacing, while the clock's gap eases to the one the messages say (`p`). The walked
	# distance is kept below a loop of the gait, where it repeats, so the number stays small.
	records.write(m.slot, m.spots, m.ticks, flags, m.height, m.walked, TAU / m.kind.y if m.kind.y > 0.0 else 0.0,
		now, l0, clock.gap, clock.gap_goal(), m.key_gap, clock.ease,
		yaw0, m.yaw_goal, c0, c1, m.kind.x, m.kind.y, m.kind.z, 1.5 if m.key_gap <= 4.0 else 1.0)
	if m.bot != null:
		_place_in_grid(m)
	elif m.creature:
		creatures.placed(m.unit, m.target)
	if _fogging:
		_fog_check(m)


## Where a mover is drawn now: its node, or for one the GPU draws, its record worked out here.
func _drawn_now(m: Mover) -> Vector3:
	if m.slot < 0 or not m.recorded:
		return m.node.position
	return records.position(m.slot)


func _place_in_grid(m: Mover) -> void:
	var cell := Vector2i(floori(m.target.x / GRID), floori(m.target.z / GRID))
	if cell == m.cell:
		return
	_leave_grid(m)
	m.cell = cell
	var list: Dictionary = _robot_grid.get(cell, {})
	if list.is_empty():
		_robot_grid[cell] = list
	list[m] = true


func _leave_grid(m: Mover) -> void:
	var old: Dictionary = _robot_grid.get(m.cell, {})
	old.erase(m)
	if old.is_empty():
		_robot_grid.erase(m.cell)
	m.cell = Vector2i(1 << 30, 0)


func _fog_check(m: Mover) -> void:
	var hide: bool = _fogging and not fog.seen(Vector2(m.target.x, m.target.z))
	if hide != m.fogged:
		m.fogged = hide
		records.set_flag(m.slot, MoverRecords.HIDDEN, hide)
		if m.bot != null:
			m.bot.hidden = hide


## GPU-drawn movers and the remote view's fog: all of them when it comes or goes, else a slice a
## frame (its coverage changes about once a second), besides each one as its position arrives.
func _fog_records(fogging: bool) -> void:
	if fogging != _fogging:
		_fogging = fogging
		for m: Mover in _movers.values():
			if m.slot >= 0:
				_fog_check(m)
		_fog_list.clear()
		_fog_at = 0
		return
	if not fogging:
		return
	if _fog_at >= _fog_list.size():
		_fog_list.clear()
		_fog_at = 0
		for unit in _movers:
			if (_movers[unit] as Mover).slot >= 0:
				_fog_list.append(unit)
	var end := mini(_fog_at + FOG_SLICE, _fog_list.size())
	for i in range(_fog_at, end):
		var m: Mover = _movers.get(_fog_list[i])
		if m != null and m.slot >= 0:
			_fog_check(m)
	_fog_at = end


## Where a mover is at tick `drawn`: between the two positions around it, or a little past the
## newest (up to half a send) when the next one is late. Coarse movers (robots) aren't run on past
## their newest position: they stop there, or the next one comes.
static func _drawn_at(m: Mover, drawn: float) -> Vector3:
	var n := m.ticks.size()
	if n < 2 or drawn <= m.ticks[0]:
		return m.spots[0] if n > 0 else m.target
	for i in range(1, n):
		if drawn <= m.ticks[i]:
			return m.spots[i - 1].lerp(m.spots[i], (drawn - m.ticks[i - 1]) / (m.ticks[i] - m.ticks[i - 1]))
	var span := m.ticks[n - 1] - m.ticks[n - 2]
	var f := minf((drawn - m.ticks[n - 2]) / span, 1.5 if m.key_gap <= 4.0 else 1.0)
	return m.spots[n - 2].lerp(m.spots[n - 1], f)


## Night from 0 to 1 (main.gd, with the sky): locomotives' headlights come on above 0.3.
func set_night(n: float) -> void:
	_beam = Avatar.beam(n)
	var src: Dictionary = _node_movers if pick_node_movers else _movers
	for m in src.values():
		for h: SpotLight3D in m.headlights:
			h.light_energy = 7.0 * _beam
			h.visible = _beam > 0.01


## Where a locomotive's headlights sit in its model: either side of its nose (models face north, -Z).
const HEADLIGHT_HEIGHT := 1.4
const HEADLIGHT_AHEAD := -3.2


func _add_headlights(m: Mover) -> void:
	for side in [-0.6, 0.6]:
		var h := SpotLight3D.new()
		h.light_color = Color(1.0, 0.9, 0.9)
		h.spot_range = 30.0
		h.spot_angle = 18.0
		h.spot_attenuation = 0.5
		h.position = Vector3(side, HEADLIGHT_HEIGHT, HEADLIGHT_AHEAD)
		h.rotation.x = deg_to_rad(-6.0)
		h.light_energy = 7.0 * _beam
		h.visible = _beam > 0.01
		m.node.add_child(h)
		m.headlights.append(h)


## A locomotive's headlights over the add-on's hills under its nose (ground_height.gd): the model is
## lifted onto them in its shader, the lights are placed here, and at the flat height they sat inside
## raised ground. One height read a frame per locomotive, only while they shine.
func _lift_headlights(m: Mover) -> void:
	var nose := m.node.transform * Vector3(0.0, 0.0, HEADLIGHT_AHEAD)
	var y := HEADLIGHT_HEIGHT + GroundHeight.at(nose.x, nose.z)
	for h: SpotLight3D in m.headlights:
		h.position.y = y


## N1: the vehicle the character is in lights its cones at night, the others stay dark (the bridge
## doesn't say who drives them); over the hills under it (one height read a frame while lit).
## With the glare (vehicle_lights.gd, --headlight-glare=off: only ours), one that moved in the last
## HOLD_S seconds lights too: something drives it.
func _light_vehicles() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var others := 0
	for unit in _lit:
		var m: Mover = _lit[unit]
		if not is_instance_valid(m.node):
			continue
		var on: bool = unit == driven
		if VehicleLights.glare_enabled:
			var p := m.node.position
			if m.light_seen == Vector3.INF:
				m.light_seen = p
			elif Vector2(p.x - m.light_seen.x, p.z - m.light_seen.z).length_squared() > 0.0025:
				m.light_seen = p
				m.light_moved = now
			if not on and now - m.light_moved < VehicleLights.HOLD_S and others < VehicleLights.MAX_OTHERS:
				on = true
				others += 1
		var beam := _beam if on else 0.0
		var ground := 0.0
		if beam > 0.01:
			ground = GroundHeight.at(m.node.position.x, m.node.position.z) - m.node.position.y
		VehicleLights.apply(m.lights, beam, ground)
		var glow := clampf(beam, 0.0, 1.0) if VehicleAnim.enhanced else 0.0
		for hm in m.headlight_meshes:
			if is_instance_valid(hm):
				hm.set_instance_shader_parameter("f3d_glow", glow)


## Drops a mover at once (it died) instead of waiting for it to stop showing up.
func remove(unit: int) -> void:
	var m: Mover = _movers.get(unit)
	if m != null:
		creatures.remove(unit, true)  # first: a GPU-drawn one falls where its record has it
		_free(m)
		_count_type(m.type, -1)
		_movers.erase(unit)
		_sim_movers.erase(unit)
		_follow_movers.erase(unit)
		_node_movers.erase(unit)
		_waiting.erase(unit)
		_lit.erase(unit)
		vehicles.detach(unit)


## Where a mover is drawn, or null.
func position_of(unit: int) -> Variant:
	var m: Mover = _movers.get(unit)
	if m == null:
		return null
	return _drawn_now(m)


## Top of a mover's model above its origin (tiles), or -1 when unknown.
func top_of(unit: int) -> float:
	var m: Mover = _movers.get(unit)
	if m == null:
		return -1.0
	var proto: ProtoDB.EntityProto = protos.entity(m.proto_id) if protos != null else null
	if proto == null:
		return -1.0
	var top := ModelLibrary.top_for(proto.name)
	if top > 0.0:
		return top
	return Visuals.height_for(proto)


## The prototype id of the mover of one of `types` whose latest sent position is nearest `at` (in
## 1/256 tile) within half a tile, or 0: what the bridge's `me` `rx`/`ry` name when it is a vehicle.
func proto_near(at: Vector2i, types: Array) -> int:
	var best := 0
	var best_d := 128 * 128 + 1
	for unit in _movers:
		var m: Mover = _movers[unit]
		if not types.has(m.type):
			continue
		var d := (m.fixed - at).length_squared()
		if d < best_d:
			best_d = d
			best = m.proto_id
	return best


## Which way a mover faces as drawn now (radians about up), or 0 for none.
func yaw_of(unit: int) -> float:
	var m: Mover = _movers.get(unit)
	if m == null:
		return 0.0
	if m.slot < 0 or not m.recorded:
		return m.node.rotation.y
	return records.state(m.slot)["yaw"]


## [[unit, node], ...] of the movers of one prototype type (rockets.gd lifts cargo pods and hides
## a launching rocket).
## A mover's node and prototype name (turrets.gd turns vehicles' turrets), or null / "".
func node_of(unit: int) -> Node3D:
	var m: Mover = _movers.get(unit)
	return m.node if m != null else null


## Its prototype's id, or 0 (alt_overlay.gd: a locomotive's fuel icons, K1).
func proto_id_of(unit: int) -> int:
	var m: Mover = _movers.get(unit)
	return m.proto_id if m != null else 0


func proto_name_of(unit: int) -> String:
	var m: Mover = _movers.get(unit)
	if m == null:
		return ""
	var proto: ProtoDB.EntityProto = protos.entity(m.proto_id)
	return proto.name if proto != null else ""


## Whether the remote view's fog is hiding this mover.
func is_fogged(unit: int) -> bool:
	var m: Mover = _movers.get(unit)
	return m != null and m.fogged


func _has_gpu_type(types: Array) -> bool:
	if _gpu_type_counts.is_empty():
		return false
	for t in types:
		if int(_gpu_type_counts.get(str(t), 0)) > 0:
			return true
	return false


func units_of_type(type: String) -> Array:
	var out: Array = []
	if int(_type_counts.get(type, 0)) <= 0:
		return out
	var src: Dictionary = _node_movers if (pick_node_movers and int(_gpu_type_counts.get(type, 0)) == 0) else _movers
	for unit in src:
		var m: Mover = src[unit]
		if m.type == type:
			out.append([unit, m.node])
	return out


func _count_type(type: String, by: int) -> void:
	if type == "":
		return
	var n := int(_type_counts.get(type, 0)) + by
	if n > 0:
		_type_counts[type] = n
	else:
		_type_counts.erase(type)


func _count_gpu_type(type: String, by: int) -> void:
	if type == "":
		return
	var n := int(_gpu_type_counts.get(type, 0)) + by
	if n > 0:
		_gpu_type_counts[type] = n
	else:
		_gpu_type_counts.erase(type)


## True when a flying robot is drawn within `radius` tiles of `from` (on the ground plane).
func robot_near(from: Vector3, radius: float) -> bool:
	for m: Mover in _near(from, radius):
		if m.robot and _within(m, from, radius):
			return true
	return false


## Whether a mover is drawn within `radius` (on the ground plane) of `from`. A GPU-drawn one is first
## ruled out by its newest position (it is drawn within DRAWN_SLACK of it), its record worked out
## only when it may be.
func _within(m: Mover, from: Vector3, radius: float) -> bool:
	var at := m.node.position
	if m.slot >= 0 and m.recorded:
		if not m.sim and Vector2(m.target.x - from.x, m.target.z - from.z).length() > radius + DRAWN_SLACK:
			return false
		at = records.position(m.slot)
	return Vector2(at.x - from.x, at.z - from.z).length() <= radius


## The non-enemy movers in the grid cells within `radius` (on the ground plane) of `from`: every
## roboport and gate asks, and looking through a thousand robots for each was most of anim.gd's time.
## GPU-drawn robots are kept in their cells as their positions arrive (_robot_grid), the few moved
## here put in theirs at most once a frame.
func _near(from: Vector3, radius: float) -> Array:
	var out: Array = []
	var r := radius + DRAWN_SLACK
	for cx in range(floori((from.x - r) / GRID), floori((from.x + r) / GRID) + 1):
		for cz in range(floori((from.z - r) / GRID), floori((from.z + r) / GRID) + 1):
			var robots_here: Dictionary = _robot_grid.get(Vector2i(cx, cz), {})
			if not robots_here.is_empty():
				out.append_array(robots_here.keys())
	if _grid_frame != _frame:
		_grid_frame = _frame
		_grid.clear()
		for m: Mover in _node_movers.values():
			if not m.enemy:
				var cell := Vector2i(floori(m.node.position.x / GRID), floori(m.node.position.z / GRID))
				var list: Array = _grid.get(cell, [])
				if list.is_empty():
					_grid[cell] = list
				list.append(m)
	for cx in range(floori((from.x - radius) / GRID), floori((from.x + radius) / GRID) + 1):
		for cz in range(floori((from.z - radius) / GRID), floori((from.z + radius) / GRID) + 1):
			var list: Array = _grid.get(Vector2i(cx, cz), [])
			if not list.is_empty():
				out.append_array(list)
	return out

## The mover of one of these types nearest a ground point, within `radius` tiles:
## [unit, proto id, fixed position], or [] (player_input.gd opens vehicles and wagons this way).
func pick(point: Vector2, radius: float, types: Array) -> Array:
	var best: Array = []
	var best_distance := radius
	var src: Dictionary = _node_movers if (pick_node_movers and not _has_gpu_type(types)) else _movers
	for unit in src:
		var m: Mover = src[unit]
		if not types.has(m.type):
			continue
		var d := Vector2(m.node.position.x, m.node.position.z).distance_to(point)
		if d <= best_distance:
			best_distance = d
			best = [unit, m.proto_id, m.fixed]
	return best


## The mover of one of these types that the mouse ray (`from`, `dir`, world space) hits first:
## [unit, proto id, fixed position, centre (Vector2 tiles), half size (Vector2), yaw, distance along
## the ray], or [].
## Each mover is hit within its selection box turned by its orientation, as tall as its model
## (and anywhere on the model, where that sticks out of the box), so a click anywhere on a train,
## car, tank or spidertron opens it, not the rail or ground behind it.
func pick_ray(from: Vector3, dir: Vector3, types: Array) -> Array:
	var best: Array = []
	var best_distance := INF
	var wanted := {}
	for t in types:
		wanted[t] = true
	var src: Dictionary = _node_movers if (pick_node_movers and not _has_gpu_type(types)) else _movers
	for unit in src:
		var m: Mover = src[unit]
		if not wanted.has(m.type):
			continue
		var proto: ProtoDB.EntityProto = protos.entity(m.proto_id)
		if proto == null:
			continue
		var box := pick_box(m.node, proto)
		var inv := m.node.global_transform.affine_inverse()
		var hit = box.intersects_ray(inv * from, inv.basis * dir)
		if hit == null:
			continue
		var d := (m.node.global_transform * (hit as Vector3)).distance_to(from)
		if d < best_distance:
			best_distance = d
			var c := proto.center()
			var at := m.node.global_transform * Vector3(c.x, 0.0, c.y)
			best = [unit, m.proto_id, m.fixed, Vector2(at.x, at.z), proto.size() * 0.5, m.node.rotation.y, d]
	return best


## A mover's box for picking, in its node's space: the selection box (x east, z south when facing
## north), as tall as the model, grown to take in the model where it sticks out.
static func pick_box(node: Node3D, proto: ProtoDB.EntityProto) -> AABB:
	var box := AABB(Vector3(proto.box_min.x, 0.0, proto.box_min.y), Vector3(proto.size().x, Visuals.height_for(proto), proto.size().y))
	for child in node.get_children():
		var mi := child as MeshInstance3D
		if mi != null and mi.mesh != null:
			box = box.merge(mi.transform * mi.mesh.get_aabb())
	return box


## Where the nearest enemy within `max_range` of `from` is drawn, or null.
func nearest_enemy(from: Vector3, max_range: float) -> Variant:
	var found := nearest_enemy_unit(from, max_range)
	return null if found.is_empty() else found[1]


## The enemy nearest `from` within `max_range`: [its unit number, where it is drawn now], or [].
func nearest_enemy_unit(from: Vector3, max_range: float) -> Array:
	var best: Array = []
	var best_distance := max_range
	for m: Mover in _movers.values():
		if m.enemy:
			if m.slot >= 0 and m.recorded and m.target.distance_to(from) > best_distance + DRAWN_SLACK:
				continue
			var at := _drawn_now(m)
			var d := at.distance_to(from)
			if d <= best_distance:
				best_distance = d
				best = [m.unit, at]
	return best


## Where the non-enemy mover (a vehicle, a train, a robot) nearest `from` on the ground plane is
## drawn now, within `radius`, or null (acid lands on the car its spitter attacks, weapon_fx.gd).
func friendly_nearest(from: Vector3, radius: float) -> Variant:
	var best = null
	var best_distance := radius
	for m: Mover in _near(from, radius):
		# Flying robots aren't what acid lands on: one passing over a wall drew the wall's acid under it.
		if m.robot or not _within(m, from, radius):
			continue
		var at := _drawn_now(m)
		var d := Vector2(at.x - from.x, at.z - from.z).length()
		if d <= best_distance:
			best_distance = d
			best = at
	return best


## True when a mover of the player's side (a vehicle, a train, another player's character, and a
## flying robot only when `robots`) is within `max_range` of `from`: gates open for them (anim.gd).
func friendly_near(from: Vector3, max_range: float, robots := true) -> bool:
	for m: Mover in _near(from, max_range):
		if (robots or not m.robot) and _within(m, from, max_range):
			return true
	return false


## As friendly_near, but each mover's reach grows with its speed: max(`max_range`, `lead` seconds of its
## travel at the speed its last two positions show), so a fast vehicle opens a gate before it arrives (anim.gd).
## Speeds are capped at LEAD_SPEED_CAP tiles a second (a teleport isn't a speed).
const LEAD_SPEED_CAP := 60.0
func friendly_near_moving(from: Vector3, max_range: float, lead: float, robots := true) -> bool:
	var outer := maxf(max_range, lead * LEAD_SPEED_CAP)
	for m: Mover in _near(from, outer):
		if robots or not m.robot:
			if _within(m, from, maxf(max_range, lead * speed_of(m))):
				return true
	return false


## A mover's speed in tiles a second from its last two positions as sent (0 with fewer, or standing).
static func speed_of(m: Mover) -> float:
	var n := m.spots.size()
	if n < 2 or m.ticks.size() < 2:
		return 0.0
	var dt := m.ticks[n - 1] - m.ticks[n - 2]
	if dt <= 0.0:
		return 0.0
	return minf(LEAD_SPEED_CAP, Vector2(m.spots[n - 1].x - m.spots[n - 2].x, m.spots[n - 1].z - m.spots[n - 2].z).length() * 60.0 / dt)


func _process(delta: float) -> void:
	var started := Time.get_ticks_usec()
	_process_movers(delta)
	process_usec = Time.get_ticks_usec() - started


func _process_movers(delta: float) -> void:
	_frame += 1
	if not _dress_arg_read:
		_dress_arg_read = true
		for a in Switches.args():
			if a.begins_with("--movers-dress-usec="):
				dress_usec = maxi(0, int(a.substr(20)))
	if _model_generation != ModelLibrary.generation:
		_model_generation = ModelLibrary.generation
		_refresh_due = true
		var t0 := Time.get_ticks_usec()
		for unit in _waiting.keys():
			var m: Mover = _movers.get(unit)
			var proto: ProtoDB.EntityProto = protos.entity(m.proto_id) if m != null else null
			if proto == null:
				_waiting.erase(unit)
				_to_dress.erase(unit)
			elif _model_ready(proto):
				_to_dress[unit] = true
		Probing.add("mv_ready", t0)
	if _refresh_due:
		var t0 := Time.get_ticks_usec()
		_refresh_due = not robots.refresh(dress_usec)
		Probing.add("mv_refresh", t0)
	if not _to_dress.is_empty():
		_dress_some()
	var t0_move := Time.get_ticks_usec()
	var t := 1.0 - exp(-delta * FOLLOW_RATE)
	var drawn := clock.advance(delta)
	records.frame(clock.tick, clock.rate, 0.0 if MomentHold.on else delta)
	var fogging: bool = fog != null and fog.hiding()
	_fog_records(fogging)
	_sim_grid_sweep()
	if _frame % 4 == 0 and not _follow_movers.is_empty():
		_update_follow_movers()
	var behind := clock.gap * GameClock.DELAY_SENDS
	var now := clock.tick
	var focus := Vector2.INF
	if creatures.target != null:
		focus = Vector2(creatures.target.position.x, creatures.target.position.z)
	for m: Mover in _node_movers.values():
		if m.sim:
			if fogging or m.fogged:
				var hide: bool = fogging and not fog.seen(Vector2(m.target.x, m.target.z))
				if hide != m.fogged:
					m.fogged = hide
					m.node.visible = not hide
					if m.shadow != null:
						m.shadow.visible = not hide
			var eval_t := now if now >= 0.0 else m.sim_t0
			var sim_step := _eval_sim_node(m, eval_t, clock.rate, delta, t)
			m.node.position = sim_step[0]
			m.node.rotation.y = sim_step[1]
			if m.card != null:
				_update_card(m, null, float(sim_step[2]) > 0.001)
			if m.shadow != null:
				m.shadow.position = Vector3(m.node.position.x, 0.03, m.node.position.z) + SHADOW_OFFSET
				m.shadow.rotation.y = m.node.rotation.y
			continue
		if m.creature and focus != Vector2.INF and not m.fogged:
			var away := focus.distance_squared_to(Vector2(m.node.position.x, m.node.position.z))
			if away > CREATURE_FAR * CREATURE_FAR:
				if (_frame + m.stagger) % 3 != 0:
					continue
			elif away > CREATURE_NEAR * CREATURE_NEAR and (_frame + m.stagger) % 2 != 0:
				continue
		if fogging or m.fogged:
			var hide: bool = fogging and not fog.seen(Vector2(m.target.x, m.target.z))
			if hide != m.fogged:
				m.fogged = hide
				m.node.visible = not hide
				if m.shadow != null:
					m.shadow.visible = not hide
		# Drawn a step behind its own updates too, so a robot's next position is nearly always in.
		# Eased like the clock's gap: when updates come further apart (the mod's `rate`) the mover
		# learns its new spacing in a few updates, and jumping back that far would step it backwards.
		var want := maxf(behind, m.key_gap + clock.gap)
		if m.lag < 0.0:
			m.lag = want
		else:
			m.lag = move_toward(m.lag, want, delta * clock.rate * (0.5 if want > m.lag else 1.0))
		var lag := m.lag
		var was: Vector3 = m.node.position
		var yaw_was: float = m.node.rotation.y
		m.node.position = _drawn_at(m, now - lag) if drawn >= 0.0 else m.node.position
		m.node.rotation.y = lerp_angle(m.node.rotation.y, m.yaw_goal, t)
		if m.on_rails and world != null:
			_ride_rails(m, delta, t)
		if _beam > 0.01 and not m.headlights.is_empty():
			_lift_headlights(m)
		if m.card != null:
			_update_card(m, null, m.node.position.distance_squared_to(was) > CARD_STILL * CARD_STILL)
		if not m.wheels.is_empty():
			_roll_wheels(m, m.node.position - was, wrapf(m.node.rotation.y - yaw_was, -PI, PI), delta)
		if m.shadow != null:
			m.shadow.position = Vector3(m.node.position.x, 0.03, m.node.position.z) + SHADOW_OFFSET
			m.shadow.rotation.y = m.node.rotation.y
		if not m.lift_meshes.is_empty():
			_lift_at(m)
	_light_vehicles()
	Probing.add("mv_move", t0_move)
	var t0_draw := Time.get_ticks_usec()
	robots.draw(delta)
	Probing.add("mv_robots", t0_draw)


## How far from a wagon's centre its bogies are (tiles; Factorio's wagons are 6 long, joined 4 apart).
const BOGIE := 2.0


## Rolling stock at the rails' height under it (world.gd rail_height): the height under its front and
## back bogies, so up a ramp it climbs and pitches with the slope as Factorio's do. A jump between the
## levels (spawned on a bridge, a level decided anew) eases in at 20 tiles a second; on the rails it
## follows them exactly (easing at 6 a second, as before, left fast trains under a ramp's top).
## --elevated-trains=old: the height under its centre, eased, no pitch.
func _ride_rails(m: Mover, delta: float, t: float) -> void:
	var at := Vector2(m.node.position.x, m.node.position.z)
	if ModelLibrary.elevated_old:
		var goal_old: float = world.rail_height(at, m.rail_h)
		m.rail_h = move_toward(m.rail_h, goal_old, delta * 6.0)
		m.node.position.y = m.rail_h
		return
	var yaw := m.node.rotation.y
	var fwd := Vector2(-sin(yaw), -cos(yaw)) * BOGIE
	var front: float = world.rail_height(at + fwd, m.rail_h)
	var back: float = world.rail_height(at - fwd, m.rail_h)
	var goal := (front + back) * 0.5
	m.rail_h = goal if absf(goal - m.rail_h) <= 1.0 else move_toward(m.rail_h, goal, delta * 20.0)
	m.node.position.y = m.rail_h
	var pitch := atan2(front - back, 2.0 * BOGIE) if absf(goal - m.rail_h) < 0.01 else 0.0
	m.node.rotation.x = lerp_angle(m.node.rotation.x, pitch, t)


## Dresses the waiting movers whose model is ready (_to_dress), within dress_usec (at least one).
func _dress_some() -> void:
	var t0 := Time.get_ticks_usec()
	var done := 0
	for unit in _to_dress.keys():
		if dress_usec > 0 and done > 0 and Time.get_ticks_usec() - t0 > dress_usec:
			break
		_to_dress.erase(unit)
		if not _waiting.has(unit):
			continue  # gone meanwhile (_end_frame), or dressed by a later update
		var m: Mover = _movers.get(unit)
		var proto: ProtoDB.EntityProto = protos.entity(m.proto_id) if m != null else null
		if proto == null:
			_waiting.erase(unit)
			continue
		if not _model_ready(proto):
			continue  # its model changed under it: listed again when the next one is ready
		_waiting.erase(unit)
		var td := Time.get_ticks_usec()
		_dress(unit, m, proto)
		if Probing.on and Time.get_ticks_usec() - td > 5000:
			print("MOVERS slow dress %s (%s): %d ms" % [proto.name, proto.type, (Time.get_ticks_usec() - td) / 1000])
		done += 1
	Probing.add("mv_dress", t0)


## Moves a mover onto its record: the GPU draws it from now on (robots, walking creatures).
func _to_record(m: Mover, kind: Vector4, flags: int) -> void:
	if m.slot < 0:
		_count_gpu_type(m.type, 1)
	m.slot = records.alloc()
	m.kind = kind
	m.rec_flags = flags
	_node_movers.erase(m.unit)
	if m.sim:
		if m.sim_heard_tick > 0.0:
			_write_sim(m, true)
	else:
		_write(m, false)


## Rolling stock wears the colour its player gave it (H21), from its record's extra.col.
func _paint(unit: int, m: Mover) -> void:
	if not m.on_rails or world == null or m.card != null:
		return
	var rec = world.entities.get(unit)
	if rec == null or not (rec.extra is Dictionary) or not rec.extra.has("col"):
		return
	var c: Array = rec.extra["col"]
	var paint := Color(int(c[0]) / 255.0, int(c[1]) / 255.0, int(c[2]) / 255.0)
	for mi in m.node.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).set_instance_shader_parameter("f3d_paint", paint)


## Gives a mover its model: biters and the like go to creatures.gd (their node stays empty), the
## rest get the model's mesh and moving parts under their node, or a mod's picture on a card.
func _dress(unit: int, m: Mover, proto: ProtoDB.EntityProto) -> void:
	if m.robot and RobotSwarm.handles(proto.name, proto.type):
		var tr := Time.get_ticks_usec()
		m.bot = robots.add(unit, proto.name)
		remove_child(m.node)  # nothing under it to draw or move
		_to_record(m, Vector4(m.bot.phase, 0.0, 0.0, 0.0), robots.flags_for(m.bot))
		robots.place(m.bot, m.slot)
		Probing.add("mv_d_robot", tr)
		return
	var creature := CreatureModels.walks(proto.name) and ModelLibrary.mesh_for(proto.name) != null
	if not creature:
		var tn := Time.get_ticks_usec()
		var made := _make_node(proto)
		Probing.add("mv_d_node", tn)
		for child in made.get_children():
			made.remove_child(child)
			m.node.add_child(child)
			if child.has_meta("card"):
				m.card = child
				_update_card(m, proto, false)
		made.free()
		m.wheels = _wheels_of(m.node)
		m.steers = _steers_of(m.node)
		m.headlight_meshes = _headlight_meshes_of(m.node)
		m.lift_meshes = _lift_meshes_of(m.node)
		_lift_at(m)
		for hm in m.headlight_meshes:
			hm.set_instance_shader_parameter("f3d_glow", 0.0)
		if m.lights != null:
			VehicleLights.place_glare(m.lights, m.headlight_meshes)
	if m.robot and m.card == null:  # a card casts its own shadow, as a building's does
		var ts := Time.get_ticks_usec()
		m.shadow = _make_shadow(m.node)
		if m.shadow != null:
			add_child(m.shadow)
		Probing.add("mv_d_shadow", ts)
	if creature:
		m.creature = true
		m.stagger = unit % 6
		# Walking on the GPU from its record where its model can (creatures.gd gait()); else
		# creatures.gd draws it from the node's local transform, moved here every frame. In the tree
		# every move made Godot work out the empty node's global transform: ~4 ms a frame with 500
		# biters attacking on the owner's save. Kept out of the tree, as robots' nodes are.
		remove_child(m.node)
		var gait := creatures.gait(proto.name)
		if gait != Vector2.ZERO:
			var slot := records.alloc()
			creatures.add(unit, proto.name, m.node, slot)
			_to_record_slot(m, slot, Vector4(fposmod(unit * 2.39996, TAU), gait.x, gait.y, 0.0))
		else:
			creatures.add(unit, proto.name, m.node)
	else:
		var ta := Time.get_ticks_usec()
		vehicles.attach(unit, m.node, proto.name)
		Probing.add("mv_d_attach", ta)
	_paint(unit, m)


## Whether the mover's model (or its shared one, mover_model) is ready, asking for it if not.
static func _model_ready(proto: ProtoDB.EntityProto) -> bool:
	if not ModelLibrary.ready(proto.name):
		return false
	if ModelLibrary.mesh_for(proto.name) == null:
		var shared := ModelLibrary.mover_model(proto.name)
		if not shared.is_empty():
			return ModelLibrary.ready(str(shared[0]))
	return true


## A vehicle's meshes drawn with a material lifted whole (Creatures.mark_rigid): the body and its moving
## parts, which all take the ground's height at the vehicle's origin (_lift_at), not their own (a wheel
## turned about its axle has its origin elsewhere), so the parts stay on the body over hills.
static func _lift_meshes_of(node: Node3D) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for child in node.get_children():
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null or mi.has_meta("card"):
			continue
		if mi.mesh.get_surface_count() == 0:
			continue
		var m := mi.mesh.surface_get_material(0) as ShaderMaterial
		if m != null and m.get_shader_parameter("ground_rigid") == true:
			out.append(mi)
	return out


## Where `m`'s meshes take the ground's height from (factorio_material.gdshaderinc f3d_lift_at): its
## origin, sent again only once it has moved.
func _lift_at(m: Mover) -> void:
	var at := Vector2(m.node.position.x, m.node.position.z)
	if at.distance_squared_to(m.lift_at) < 0.0001:
		return
	m.lift_at = at
	var v := Vector3(at.x, 1.0, at.y)
	for mi in m.lift_meshes:
		if is_instance_valid(mi):
			mi.set_instance_shader_parameter(&"f3d_lift_at", v)


func _make_node(proto: ProtoDB.EntityProto) -> Node3D:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	var mesh := ModelLibrary.mesh_for(proto.name)
	var shared := ModelLibrary.mover_model(proto.name) if mesh == null else []
	if not shared.is_empty():
		mesh = ModelLibrary.mesh_for(str(shared[0]))
		if mesh != null:
			mi.scale = Vector3.ONE * float(shared[1])
	# Lifted whole onto the hills (Creatures.mark_rigid); not trains (their length rides the rails' hills)
	# nor spidertrons and pentapods (legs stretched to their feet).
	var rigid := not (ROLLING_STOCK.has(proto.type) or proto.type == "spider-vehicle" or proto.type == "spider-unit")
	if mesh != null:
		mi.mesh = mesh
		if rigid:
			Creatures.mark_rigid(mesh)
		# Moving parts (a car's or tank's turret, the artillery wagon's cannon) drawn at rest:
		# their meshes are in model space, so they sit where the model has them.
		for part: ModelLibrary.AnimPart in ModelLibrary.parts_for(proto.name):
			var part_mi := MeshInstance3D.new()
			part_mi.mesh = part.mesh
			if rigid:
				Creatures.mark_rigid(part.mesh)
			part_mi.set_meta("part", part)  # vehicle_anim.gd moves the rest
			if part.kind.begins_with("wheel"):
				part_mi.set_meta("wheel", part)
			elif part.kind == "steer_front":
				part_mi.set_meta("steer", part)
			elif part.kind == "turret_head":
				part_mi.set_meta("turret_head", part)  # turned by turrets.gd
			elif part.kind == "turret_barrel":
				part_mi.set_meta("turret_barrel", part)
			elif part.kind == "turret_coax":
				part_mi.set_meta("turret_coax", part)
			elif part.kind == "headlight":
				part_mi.set_meta("headlight", part)
			root.add_child(part_mi)
	elif SpriteStandins.in_use():
		# A mod's car, unit or wagon: its own picture (_update_card), as chunk_view.gd draws a mod's
		# building, never a box; nothing while it is composed or when it has neither picture nor icon.
		mi.set_meta("card", true)
	else:
		var height := Visuals.height_for(proto)
		mi.mesh = Visuals.box_mesh()
		mi.transform = Visuals.placeholder_transform(proto, Vector2.ZERO, 0, height)
		mi.material_override = _material_for(proto)
	root.add_child(mi)
	return root


## A card mover's picture: that of the nearest of its four directions (the bridge's list keeps a
## rotated sprite's north, east, south and west), the card kept facing Factorio's camera however the
## mover turns (SpriteStandins.transform), its frames stepping only while it moves (a mod's car
## drives, a mod's biter runs; standing still Factorio holds them on one frame).
func _update_card(m: Mover, proto: ProtoDB.EntityProto, moving: bool) -> void:
	var yaw := m.node.rotation.y
	var quarter := posmod(roundi(-yaw / TAU * 4.0), 4)  # orientation = -yaw / TAU (Visuals.orientation_yaw)
	if quarter != m.card_quarter or m.card_generation != SpriteStandins.generation:
		if proto == null:
			proto = protos.entity(m.proto_id)
		if proto != null:
			var mesh := SpriteStandins.card(proto.name, quarter * 4, proto.size(), proto.type)
			# The picture it has stays while the new direction's is composed (no blink).
			if mesh != null or not SpriteStandins.coming(proto.name, quarter * 4):
				m.card.mesh = mesh
		m.card_quarter = quarter
		m.card_generation = SpriteStandins.generation
	m.card.basis = Basis(Vector3.UP, -yaw) * SpriteStandins.transform(Vector2.ZERO).basis
	var run := 1 if moving else 0
	if run != m.card_run:
		m.card_run = run
		m.card.set_instance_shader_parameter("f3d_card_run", Vector2(run, float(posmod(m.unit * 7919, 1000)) / 1000.0))


## Wheel parts (`anim_wheel_*`) of a mover's model, found under its node.
func _wheels_of(root: Node3D) -> Array:
	var out: Array = []
	for child in root.get_children():
		if child.has_meta("wheel"):
			var part: ModelLibrary.AnimPart = child.get_meta("wheel")
			out.append([child, part, part.wheel_radius(), part.kind == "wheel_front", 0.0])
	return out


func _steers_of(root: Node3D) -> Array:
	var out: Array = []
	for child in root.get_children():
		if child.has_meta("steer"):
			var part: ModelLibrary.AnimPart = child.get_meta("steer")
			out.append([child, part])
	return out


func _headlight_meshes_of(root: Node3D) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for child in root.get_children():
		if child.has_meta("headlight") and child is MeshInstance3D:
			out.append(child as MeshInstance3D)
	return out


## Wheels roll with the distance driven (backwards when reversing) and a car's front wheels
## steer into its turn. Tank tracks roll differentially when turning; front fenders follow `steer`.
func _roll_wheels(m: Mover, moved: Vector3, turned: float, delta: float) -> void:
	var forward := -m.node.global_transform.basis.z
	var distance := moved.dot(forward)
	if absf(distance) > 2.0:
		distance = 0.0  # a jump (teleport, new surface)
	# Steering from how fast it turns for the distance covered (a 1.66-tile wheelbase).
	var goal := 0.0
	if absf(distance) > 0.0005:
		goal = clampf(turned / distance * 1.66, -0.6, 0.6)
	m.steer = lerpf(m.steer, goal, 1.0 - exp(-delta * 6.0))
	for w in m.wheels:
		var mi: MeshInstance3D = w[0]
		var part: ModelLibrary.AnimPart = w[1]
		var wdist := distance
		if VehicleAnim.enhanced and part.kind == "wheel_track":
			wdist = distance + turned * part.pivot.origin.x
		# Each wheel's own turn, the distance over its radius, wrapped at a whole turn of that wheel
		# (one turn for them all, wrapped at TAU, made a wheel of another size jump at each wrap).
		var roll := fposmod(float(w[4]) - wdist / float(w[2]), TAU)
		w[4] = roll
		var turn := Basis(part.axis, roll)  # about its axle (X): the top turns forward going forward
		if w[3]:
			turn = Basis(Vector3.UP, m.steer) * turn
		mi.transform = part.pivot * Transform3D(turn, Vector3.ZERO) * part.pivot.affine_inverse()
	for s in m.steers:
		var smi: MeshInstance3D = s[0]
		var spart: ModelLibrary.AnimPart = s[1]
		if VehicleAnim.enhanced:
			smi.transform = spart.pivot * Transform3D(Basis(Vector3.UP, m.steer), Vector3.ZERO) * spart.pivot.affine_inverse()
		else:
			smi.transform = Transform3D.IDENTITY


## As _to_record, with the slot already handed out (creatures.gd needs it before the first record).
func _to_record_slot(m: Mover, slot: int, kind: Vector4) -> void:
	if m.slot < 0:
		_count_gpu_type(m.type, 1)
	m.slot = slot
	m.kind = kind
	m.rec_flags = 0
	_node_movers.erase(m.unit)
	_write(m, false)


func _free(m: Mover) -> void:
	if m.slot >= 0:
		_count_gpu_type(m.type, -1)
		records.release(m.slot)
		m.slot = -1
	if m.bot != null:
		_leave_grid(m)
	m.node.queue_free()
	if m.bot != null:
		robots.remove(m.bot)
		m.bot = null
	if m.shadow != null:
		m.shadow.queue_free()


## A robot's drop shadow: its meshes flattened onto the ground in a see-through black. The robot
## itself then casts no lit shadow, so there's one shadow, where Factorio draws it. (Robots the swarm
## draws have robot_shadow.gdshader's.) Lifted onto an add-on's hills in its shader, as the robot is.
func _make_shadow(node: Node3D) -> Node3D:
	var root: Node3D = null
	if _shadow_material == null:
		_shadow_material = GroundHeight.mark_material(SHADOW_COLOR, false)
	for child in node.get_children():
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if root == null:
			root = Node3D.new()
		var flat := MeshInstance3D.new()
		flat.mesh = mi.mesh
		flat.transform = Transform3D(Basis.from_scale(Vector3(1.0, 0.01, 1.0)), Vector3.ZERO) * mi.transform
		flat.material_override = _shadow_material
		flat.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(flat)
	return root


func _material_for(proto: ProtoDB.EntityProto) -> Material:
	if not _materials.has(proto.id):
		var color := proto.color
		if ENEMY_TYPES.has(proto.type):
			color = Color(0.75, 0.25, 0.2)  # enemies
		_materials[proto.id] = Visuals.solid_material(color)
	return _materials[proto.id]


## Simulated worker robots (`rb`, WIRE_VERSION >= 4): drives flight legs, transitions and orbits on
## the GPU (`MoverRecords.write_sim`) without waiting for 20-tick Factorio limbo position jumps.
func handle_robots(msg: Dictionary) -> void:
	var k := int(msg.get("k", 0))
	var part := int(msg.get("part", 1))
	var snap := int(msg.get("snap", 0)) == 1
	var sm := int(msg.get("sm", 1000))
	robot_speed_mult = maxf(float(sm) / 1000.0, 0.001)
	clock.tick_heard(float(k))
	var g_list: Variant = msg.get("g")
	if WireDecode.packed(g_list) or g_list is Array:
		for u in g_list:
			_remove_sim(int(u))
	var u_list: Variant = msg.get("u")
	var stride := WireDecode.RB_STRIDE
	var present := {}
	if snap and part == 1:
		if WireDecode.packed(u_list):
			var n_packed: int = u_list.size() - stride + 1
			var i := 0
			while i < n_packed:
				present[int(u_list[i])] = true
				i += stride
		elif u_list is Array:
			var arr: Array = u_list
			var n_arr := arr.size() - stride + 1
			var i := 0
			while i < n_arr:
				present[int(arr[i])] = true
				i += stride
		for unit in _sim_movers.keys():
			if not present.has(unit):
				_remove_sim(int(unit))
	if WireDecode.packed(u_list):
		var n_u: int = u_list.size() - stride + 1
		var i := 0
		while i < n_u:
			_update_sim(int(u_list[i]), int(u_list[i + 1]), int(u_list[i + 2]),
				int(u_list[i + 3]), int(u_list[i + 4]), int(u_list[i + 5]), int(u_list[i + 6]),
				int(u_list[i + 7]), int(u_list[i + 8]), int(u_list[i + 9]), int(u_list[i + 10]), float(k))
			i += stride
	elif u_list is Array:
		var arr_u: Array = u_list
		var n_a := arr_u.size() - stride + 1
		var i := 0
		while i < n_a:
			_update_sim(int(arr_u[i]), int(arr_u[i + 1]), int(arr_u[i + 2]),
				int(arr_u[i + 3]), int(arr_u[i + 4]), int(arr_u[i + 5]), int(arr_u[i + 6]),
				int(arr_u[i + 7]), int(arr_u[i + 8]), int(arr_u[i + 9]), int(arr_u[i + 10]), float(k))
			i += stride


func _remove_sim(unit: int) -> void:
	var m: Mover = _sim_movers.get(unit)
	if m == null:
		return
	remove(unit)


func _sim_speed_for(proto_id: int, proto_type: String, flags: int) -> float:
	var entry: Variant = eprops.get(proto_id)
	var x: Dictionary = entry.get("x", {}) if entry is Dictionary else {}
	var default_spd := 0.06 if proto_type == "construction-robot" else 0.05
	var base_spd := float(x.get("spd", default_spd))
	var low_mult := float(x.get("low", 0.2))
	var mult := low_mult if (flags & RB_LOW_E) != 0 else 1.0
	return maxf(0.001, base_spd * robot_speed_mult * mult)


func _update_sim(unit: int, proto_id: int, t0: int, sx_i: int, sy_i: int,
		tx_i: int, ty_i: int, nx_i: int, ny_i: int, ori_i: int, flags: int, heard_k: float) -> void:
	if unit == puppet_unit:
		return
	var proto: ProtoDB.EntityProto = protos.entity(proto_id) if protos != null else null
	if proto == null:
		return
	var sx := sx_i / 256.0
	var sy := sy_i / 256.0
	var tx := tx_i / 256.0
	var ty := ty_i / 256.0
	var state := flags & 7
	var rec_snap := (flags & RB_SNAP) != 0
	var m: Mover = _movers.get(unit)
	var is_new := m == null
	var now := clock.tick if clock.tick >= 0.0 else heard_k
	var prev_pos := Vector3(sx, Visuals.flying_height(proto.type), sy)
	var had_prev := false
	if m != null and m.recorded and not rec_snap:
		prev_pos = _drawn_now(m)
		had_prev = true
	elif m != null and not is_new and not rec_snap:
		prev_pos = m.node.position
		had_prev = true
	if m == null:
		m = Mover.new()
		m.unit = unit
		m.node = Node3D.new()
		m.node.position = prev_pos
		m.robot = ROBOT_TYPES.has(proto.type)
		m.type = proto.type
		m.height = Visuals.flying_height(proto.type)
		m.proto_id = proto_id
		m.sim = true
		m.yaw_goal = Visuals.orientation_yaw(float(ori_i) / 1000.0)
		m.node.rotation.y = m.yaw_goal
		add_child(m.node)
		_movers[unit] = m
		_sim_movers[unit] = m
		_node_movers[unit] = m
		_count_type(proto.type, 1)
		if _model_ready(proto):
			_dress(unit, m, proto)
		else:
			_waiting[unit] = true
	elif m.proto_id != proto_id:
		_count_type(m.type, -1)
		_count_type(proto.type, 1)
		m.type = proto.type
		m.height = Visuals.flying_height(proto.type)
		m.proto_id = proto_id
	var v := _sim_speed_for(proto_id, m.type, flags)
	var start := Vector2(sx, sy)
	var end1 := Vector2(tx, ty)
	var end2 := Vector2(nx_i / 256.0, ny_i / 256.0)
	var prev_hover := m.sim_hover_still
	var prev_state := m.sim_state
	var prev_start := m.sim_start
	var prev_t_end := maxf(m.sim_t_arr1, m.sim_t_arr2)
	var prev_end1 := m.sim_end1
	var prev_orbit_r := m.sim_orbit_r
	var prev_orbit_rate := m.sim_orbit_rate
	var prev_orbit_phase := m.sim_orbit_phase
	var prev_t0 := m.sim_t0

	m.sim = true
	_sim_movers[unit] = m
	m.sim_state = state
	m.sim_flags = flags
	m.sim_speed = v
	m.sim_ori = Visuals.orientation_yaw(float(ori_i) / 1000.0)
	m.fixed = Vector2i(sx_i, sy_i)
	m.sim_heard_tick = heard_k
	if state == RB_FOLLOW:
		m.sim_follow_unit = nx_i
		_follow_movers[unit] = m
		var follow_tgt := _follow_target_pos(m)
		if follow_tgt != Vector2.INF:
			end1 = follow_tgt
		end2 = end1
	else:
		m.sim_follow_unit = 0
		_follow_movers.erase(unit)

	if state == RB_HOVER:
		m.sim_t0 = float(t0)
		m.sim_start = start
		m.sim_end1 = start
		m.sim_end2 = start
		m.sim_t_arr1 = float(t0)
		m.sim_t_arr2 = float(t0)
		if not is_new and not rec_snap and prev_state == RB_HOVER and start.distance_to(prev_start) < 0.5:
			m.sim_hover_still = minf(maxf(now - prev_t_end, 0.0) + prev_hover, 600.0)
		else:
			m.sim_hover_still = 0.0
	elif state == RB_ORBIT:
		m.sim_hover_still = 0.0
		m.sim_end1 = end1
		m.sim_end2 = end1
		if not is_new and not rec_snap and prev_state == RB_ORBIT and end1.distance_to(prev_end1) < 0.25:
			m.sim_t0 = prev_t0
			m.sim_start = prev_start
			m.sim_t_arr1 = prev_t0
			m.sim_t_arr2 = prev_t0
			m.sim_orbit_r = prev_orbit_r
			m.sim_orbit_rate = prev_orbit_rate
			m.sim_orbit_phase = prev_orbit_phase
		else:
			m.sim_t0 = float(t0)
			m.sim_start = start
			m.sim_t_arr1 = float(t0)
			m.sim_t_arr2 = float(t0)
			var r_orb := clampf(start.distance_to(end1), 1.2, 4.5)
			var d_vec := start - end1
			m.sim_orbit_r = r_orb
			m.sim_orbit_phase = atan2(d_vec.y, d_vec.x) if d_vec.length_squared() > 1e-4 else float(posmod(unit, 64)) * (TAU / 64.0)
			var dir_sgn := 1.0 if (unit & 1) == 0 else -1.0
			m.sim_orbit_rate = clampf(v / r_orb, 0.01, 0.15) * dir_sgn
	else:
		m.sim_hover_still = 0.0
		m.sim_t0 = float(t0)
		m.sim_start = start
		m.sim_end1 = end1
		m.sim_end2 = end2
		var d1 := start.distance_to(end1)
		m.sim_t_arr1 = float(t0) + (d1 / v if d1 > 1e-4 else 0.0)
		if (flags & RB_HAS_NEXT) != 0 and state == RB_FLY_TARGET:
			var d2 := end1.distance_to(end2)
			m.sim_t_arr2 = m.sim_t_arr1 + (d2 / v if d2 > 1e-4 else 0.0)
		else:
			m.sim_t_arr2 = m.sim_t_arr1

	var new_pos2 := _eval_sim_pos_at(m, now)
	var err := Vector2.ZERO
	if had_prev and not is_new and not rec_snap:
		err = Vector2(prev_pos.x - new_pos2.x, prev_pos.z - new_pos2.y)
		if err.length() > SIM_BLEND_MAX:
			err = Vector2.ZERO
	m.sim_err = err
	m.sim_t_write = now
	m.target = Vector3(new_pos2.x + err.x, m.height, new_pos2.y + err.y)
	if m.slot >= 0:
		_write_sim(m, is_new or rec_snap)


func _eval_sim_pos_at(m: Mover, at_tick: float) -> Vector2:
	if m.sim_state == RB_ORBIT:
		var ang := m.sim_orbit_phase + maxf(at_tick - m.sim_t0, 0.0) * m.sim_orbit_rate
		return m.sim_end1 + Vector2(cos(ang), sin(ang)) * m.sim_orbit_r
	if at_tick < m.sim_t_arr1 and m.sim_t_arr1 > m.sim_t0 + 1e-4:
		var f := clampf((at_tick - m.sim_t0) / (m.sim_t_arr1 - m.sim_t0), 0.0, 1.0)
		return m.sim_start.lerp(m.sim_end1, f)
	if m.sim_t_arr2 > m.sim_t_arr1 + 1e-4 and at_tick < m.sim_t_arr2:
		var f := clampf((at_tick - m.sim_t_arr1) / (m.sim_t_arr2 - m.sim_t_arr1), 0.0, 1.0)
		return m.sim_end1.lerp(m.sim_end2, f)
	if m.sim_t_arr2 > m.sim_t_arr1 + 1e-4:
		return m.sim_end2
	return m.sim_end1


func _sim_leg_yaws(m: Mover) -> Vector2:
	var leg1_yaw := m.sim_ori
	var v1 := m.sim_end1 - m.sim_start
	if m.sim_state != RB_HOVER and m.sim_state != RB_ORBIT and v1.length_squared() > 1e-4:
		leg1_yaw = atan2(-v1.x, -v1.y)
	var leg2_yaw := leg1_yaw
	if (m.sim_flags & RB_HAS_NEXT) != 0 and m.sim_t_arr2 > m.sim_t_arr1 + 1e-4:
		var v2 := m.sim_end2 - m.sim_end1
		if v2.length_squared() > 1e-4:
			leg2_yaw = atan2(-v2.x, -v2.y)
	return Vector2(leg1_yaw, leg2_yaw)


func _write_sim(m: Mover, snap_yaw: bool) -> void:
	var now := clock.tick if clock.tick >= 0.0 else m.sim_t0
	var yaw0 := m.node.rotation.y
	var c0 := 0.0
	var c1 := 0.0
	if m.recorded:
		yaw0 = records.yaw_at(m.slot, now)
		if m.bot != null:
			var carry := records.robot_carry(m.slot)
			c0 = carry.x
			c1 = carry.y
	var yaws := _sim_leg_yaws(m)
	var on_leg2 := now >= m.sim_t_arr1 and m.sim_t_arr2 > m.sim_t_arr1 + 1e-4
	if snap_yaw:
		if m.sim_state == RB_ORBIT:
			var ang := m.sim_orbit_phase + maxf(now - m.sim_t0, 0.0) * m.sim_orbit_rate
			var sgn := 1.0 if m.sim_orbit_rate >= 0.0 else -1.0
			yaw0 = atan2(sin(ang) * sgn, -cos(ang) * sgn)
		else:
			yaw0 = yaws.y if on_leg2 else yaws.x
	var leg1_yaw := yaw0 if (not snap_yaw and on_leg2) else yaws.x
	var flags := (m.rec_flags & ~(MoverRecords.CARGO | MoverRecords.SIM_WORKING | MoverRecords.SIM_ORBIT | MoverRecords.SIM_NEXT_CARGO | MoverRecords.HIDDEN)) | MoverRecords.SIMULATED
	var has_cargo := (m.sim_flags & RB_CARGO) != 0
	var next_cargo := (m.sim_flags & RB_NEXT_CARGO) != 0
	if has_cargo:
		flags |= MoverRecords.CARGO
	if next_cargo:
		flags |= MoverRecords.SIM_NEXT_CARGO
	if (m.sim_flags & RB_WORKING) != 0:
		flags |= MoverRecords.SIM_WORKING
	if m.sim_state == RB_ORBIT:
		flags |= MoverRecords.SIM_ORBIT
	if m.fogged:
		flags |= MoverRecords.HIDDEN
	m.rec_flags = flags
	if m.bot != null:
		m.bot.cargo = has_cargo
		m.bot.hidden = m.fogged
	m.recorded = true
	m.yaw_goal = yaws.y if ((m.sim_flags & RB_HAS_NEXT) != 0 and now >= m.sim_t_arr1 and m.sim_t_arr2 > m.sim_t_arr1 + 1e-4) else yaws.x
	var bob_phase := m.bot.phase if m.bot != null else 0.0
	records.write_sim(m.slot, m.sim_start, m.sim_end1, m.sim_end2, m.sim_err,
		m.sim_t0, m.sim_t_arr1, m.sim_t_arr2, flags, m.height, now,
		yaw0, leg1_yaw, yaws.y, c0, c1, bob_phase,
		m.sim_orbit_r, m.sim_orbit_rate, m.sim_orbit_phase, SIM_BLEND_DECAY,
		m.sim_hover_still, m.sim_speed)
	if m.bot != null:
		_place_in_grid(m)
	if _fogging:
		_fog_check(m)


func _eval_sim_node(m: Mover, at_tick: float, rate_val: float, delta: float, turn_t: float) -> Array:
	var r := maxf(rate_val, 1.0)
	var since := maxf(at_tick - m.sim_t_write, 0.0) / r
	var yaws := _sim_leg_yaws(m)
	var target_yaw := yaws.x
	var speed_tpt := 0.0
	if m.sim_state == RB_ORBIT:
		var ang := m.sim_orbit_phase + maxf(at_tick - m.sim_t0, 0.0) * m.sim_orbit_rate
		var sgn := 1.0 if m.sim_orbit_rate >= 0.0 else -1.0
		target_yaw = atan2(sin(ang) * sgn, -cos(ang) * sgn)
		speed_tpt = absf(m.sim_orbit_r * m.sim_orbit_rate)
	elif at_tick < m.sim_t_arr1 and m.sim_t_arr1 > m.sim_t0 + 1e-4:
		speed_tpt = m.sim_speed
	elif m.sim_t_arr2 > m.sim_t_arr1 + 1e-4 and at_tick < m.sim_t_arr2:
		speed_tpt = m.sim_speed
		target_yaw = yaws.y
	elif m.sim_t_arr2 > m.sim_t_arr1 + 1e-4:
		target_yaw = yaws.y
	var p2 := _eval_sim_pos_at(m, at_tick) + m.sim_err * exp(-SIM_BLEND_DECAY * since)
	var pos := Vector3(p2.x, m.height, p2.y)
	m.target = pos
	var yaw := lerp_angle(m.node.rotation.y, target_yaw, turn_t)
	return [pos, yaw, speed_tpt * r * delta]


func _sim_grid_sweep() -> void:
	if _sim_movers.is_empty():
		return
	if _sim_sweep_at >= _sim_sweep_list.size():
		_sim_sweep_list = _sim_movers.keys()
		_sim_sweep_at = 0
	var end := mini(_sim_sweep_at + SIM_GRID_SLICE, _sim_sweep_list.size())
	var latest := clock.newest
	for i in range(_sim_sweep_at, end):
		var unit: int = _sim_sweep_list[i]
		var m: Mover = _sim_movers.get(unit)
		if m == null:
			continue
		if latest > 0.0 and latest - m.sim_heard_tick > SIM_EXPIRE_TICKS:
			_remove_sim(unit)
			continue
		if m.slot >= 0 and m.recorded:
			m.target = records.position(m.slot)
			if m.bot != null:
				_place_in_grid(m)
			if _fogging:
				_fog_check(m)
	_sim_sweep_at = end


func _follow_target_pos(m: Mover) -> Vector2:
	if m.sim_follow_unit == 0:
		return Vector2.INF
	if m.sim_follow_unit == puppet_unit and avatar_pos != Vector3.ZERO:
		return Vector2(avatar_pos.x, avatar_pos.z)
	var tp: Variant = position_of(m.sim_follow_unit)
	if tp is Vector3:
		var v: Vector3 = tp
		return Vector2(v.x, v.z)
	return Vector2.INF


func _update_follow_movers() -> void:
	var now := clock.tick
	if now < 0.0:
		return
	for unit in _follow_movers.keys():
		var m: Mover = _follow_movers[unit]
		if m == null or not m.sim or m.sim_state != RB_FOLLOW:
			_follow_movers.erase(unit)
			continue
		var tgt := _follow_target_pos(m)
		if tgt == Vector2.INF or tgt.distance_to(m.sim_end1) <= 0.5:
			continue
		var cur3 := _drawn_now(m)
		var cur2 := Vector2(cur3.x, cur3.z)
		m.sim_start = cur2
		m.sim_end1 = tgt
		m.sim_end2 = tgt
		m.sim_t0 = now
		var dist := cur2.distance_to(tgt)
		m.sim_t_arr1 = now + (dist / maxf(m.sim_speed, 0.001) if dist > 1e-4 else 0.0)
		m.sim_t_arr2 = m.sim_t_arr1
		m.sim_err = Vector2.ZERO
		m.sim_t_write = now
		m.target = Vector3(cur2.x, m.height, cur2.y)
		if m.slot >= 0:
			_write_sim(m, false)
