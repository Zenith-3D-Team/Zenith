extends Node3D
## High-performance persistent ground tread tracks and GPU-simulated ballistic dirt/mud clods &
## churning dust plumes for cars and tanks. Uses two single-draw-call MultiMeshInstance3D ring
## buffers (zero per-stamp or per-particle nodes) and hides both completely when idle or disabled
## via `--vehicle-tracks=off`.

const Switches := preload("res://scripts/switches.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const WeatherState := preload("res://scripts/world/weather_state.gd")
const TRACK_SHADER := preload("res://shaders/vehicle_tracks.gdshader")
const DIRT_SHADER := preload("res://shaders/vehicle_dirt.gdshader")

static var enabled: bool = Switches.on("--vehicle-tracks")

const MAX_TRACKS := 768
const MAX_DIRT := 800
const CLOCK_WRAP := 10000.0
const TELEPORT_DIST := 6.0
const STALE_TIMEOUT := 5.0

const TRACK_STRIDE := 0.42
const TANK_TRACK_X := 0.66
const TANK_TRACK_W := 0.44
const TANK_TRACK_L := 0.72
const TANK_TRACK_LIFE := 14.0
const CAR_TRACK_X := 0.74
const CAR_TRACK_W := 0.24
const CAR_TRACK_L := 0.60
const CAR_TRACK_LIFE := 10.0

const TANK_DIRT_STRIDE := 0.26
const CAR_DIRT_STRIDE := 0.38
const MAX_STAMPS_PER_STEP := 6
const MAX_DIRT_STEPS_PER_FRAME := 4

## Render priority for ground tracks: above terrain/flat decoratives (-128..-33), below contact
## shadows (-1), dust/smoke sprites (0), and ghosts (1..2).
const TRACK_RENDER_PRIORITY := -28


class TrackState:
	var last_pos := Vector2.ZERO
	var last_yaw := 0.0
	var left_dist := 0.0
	var right_dist := 0.0
	var dirt_dist := 0.0
	var last_seen := 0.0
	var initialized := false


var _tracks_mmi: MultiMeshInstance3D = null
var _tracks_mm: MultiMesh = null
var _tracks_mat: ShaderMaterial = null
var _track_cursor := 0
var _track_used := 0
var _track_active_until := 0.0

var _dirt_mmi: MultiMeshInstance3D = null
var _dirt_mm: MultiMesh = null
var _dirt_mat: ShaderMaterial = null
var _dirt_cursor := 0
var _dirt_used := 0
var _dirt_active_until := 0.0

var _vehicles := {}  # unit: int -> TrackState
var _elapsed := 0.0
var _clock := 0.0
var _prune_timer := 0.0


func _ready() -> void:
	if enabled:
		_ensure_meshes()


func _ensure_meshes() -> void:
	if _tracks_mmi != null:
		return
	var track_quad := QuadMesh.new()
	track_quad.size = Vector2.ONE
	_tracks_mm = MultiMesh.new()
	_tracks_mm.transform_format = MultiMesh.TRANSFORM_3D
	_tracks_mm.use_colors = true
	_tracks_mm.use_custom_data = true
	_tracks_mm.mesh = track_quad
	_tracks_mm.instance_count = MAX_TRACKS
	_tracks_mm.visible_instance_count = 0

	_tracks_mat = ShaderMaterial.new()
	_tracks_mat.shader = TRACK_SHADER
	_tracks_mat.render_priority = TRACK_RENDER_PRIORITY
	_tracks_mat.set_shader_parameter("now", _clock)

	_tracks_mmi = MultiMeshInstance3D.new()
	_tracks_mmi.name = "VehicleTracks"
	_tracks_mmi.multimesh = _tracks_mm
	_tracks_mmi.material_override = _tracks_mat
	_tracks_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_tracks_mmi.extra_cull_margin = 96.0
	_tracks_mmi.visible = false
	add_child(_tracks_mmi)

	var dirt_quad := QuadMesh.new()
	dirt_quad.size = Vector2.ONE
	_dirt_mm = MultiMesh.new()
	_dirt_mm.transform_format = MultiMesh.TRANSFORM_3D
	_dirt_mm.use_colors = true
	_dirt_mm.use_custom_data = true
	_dirt_mm.mesh = dirt_quad
	_dirt_mm.instance_count = MAX_DIRT
	_dirt_mm.visible_instance_count = 0

	_dirt_mat = ShaderMaterial.new()
	_dirt_mat.shader = DIRT_SHADER
	_dirt_mat.render_priority = 0
	_dirt_mat.set_shader_parameter("now", _clock)

	_dirt_mmi = MultiMeshInstance3D.new()
	_dirt_mmi.name = "VehicleDirt"
	_dirt_mmi.multimesh = _dirt_mm
	_dirt_mmi.material_override = _dirt_mat
	_dirt_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dirt_mmi.extra_cull_margin = 64.0
	_dirt_mmi.visible = false
	add_child(_dirt_mmi)


## Fast pre-check so callers can skip ground lookups for completely parked vehicles.
func needs_step(unit: int, pos: Vector2, yaw: float) -> bool:
	if not enabled:
		return false
	var st: TrackState = _vehicles.get(unit)
	if st == null or not st.initialized:
		return true
	return pos.distance_squared_to(st.last_pos) > 1e-5 or absf(wrapf(yaw - st.last_yaw, -PI, PI)) > 0.002


func step_vehicle(unit: int, pos: Vector2, yaw: float, speed: float, is_tank: bool,
		ground_kind: String, ground_color: Color, delta: float) -> void:
	if not enabled or delta <= 0.0:
		return
	var st: TrackState = _vehicles.get(unit)
	if st == null:
		st = TrackState.new()
		_vehicles[unit] = st
	st.last_seen = _elapsed
	if not st.initialized:
		st.last_pos = pos
		st.last_yaw = yaw
		st.initialized = true
		return

	var prev_pos := st.last_pos
	var prev_yaw := st.last_yaw
	var move := pos - prev_pos
	var dist := move.length()
	var turned := wrapf(yaw - prev_yaw, -PI, PI)
	st.last_pos = pos
	st.last_yaw = yaw

	if dist > TELEPORT_DIST:
		st.left_dist = 0.0
		st.right_dist = 0.0
		st.dirt_dist = 0.0
		return
	if ground_kind == "water":
		return

	var track_x := TANK_TRACK_X if is_tank else CAR_TRACK_X
	var turn_travel := absf(turned) * track_x
	var left_step := dist + turn_travel
	var right_step := dist + turn_travel
	if left_step < 0.002 and right_step < 0.002:
		return

	_ensure_meshes()
	var paved := ground_kind == "stone" or ground_kind == "concrete" or ground_kind == "metal"
	var rot := Basis(Vector3.UP, yaw)
	var fwd_v3 := rot * Vector3(0.0, 0.0, -1.0)
	var fwd_2d := Vector2(fwd_v3.x, fwd_v3.z)
	var signed_move := move.dot(fwd_2d)
	var pivoting := is_tank and dist < 0.04 and absf(turned) > 0.004

	# Stamp color & opacity by surface kind.
	var rut_color := _rut_color(ground_kind, ground_color, paved)
	var base_alpha := (0.78 if is_tank else 0.62) * (0.22 if paved else 1.0)
	if pivoting and not paved:
		base_alpha = minf(base_alpha * 1.15, 0.90)
	rut_color.a = base_alpha

	var track_w := TANK_TRACK_W if is_tank else CAR_TRACK_W
	var track_l := TANK_TRACK_L if is_tank else CAR_TRACK_L
	var track_life := TANK_TRACK_LIFE if is_tank else CAR_TRACK_LIFE
	var rear_z := 0.0 if pivoting else ((0.26 if is_tank else 0.42) * (1.0 if signed_move >= 0.0 else -1.0))

	st.left_dist += left_step
	st.right_dist += right_step

	var stamps_l := 0
	while st.left_dist >= TRACK_STRIDE and stamps_l < MAX_STAMPS_PER_STEP:
		st.left_dist -= TRACK_STRIDE
		stamps_l += 1
		var frac := 1.0 - clampf(st.left_dist / maxf(left_step, 0.001), 0.0, 1.0)
		var sp := prev_pos.lerp(pos, frac)
		var sy := prev_yaw + turned * frac
		var z_off := rear_z + (randf_range(-0.22, 0.22) if pivoting else 0.0)
		_emit_track(sp, sy, -track_x, z_off, track_w, track_l, track_life, is_tank, rut_color)
	if st.left_dist >= TRACK_STRIDE:
		st.left_dist = fmod(st.left_dist, TRACK_STRIDE)

	var stamps_r := 0
	while st.right_dist >= TRACK_STRIDE and stamps_r < MAX_STAMPS_PER_STEP:
		st.right_dist -= TRACK_STRIDE
		stamps_r += 1
		var frac := 1.0 - clampf(st.right_dist / maxf(right_step, 0.001), 0.0, 1.0)
		var sp := prev_pos.lerp(pos, frac)
		var sy := prev_yaw + turned * frac
		var z_off := rear_z + (randf_range(-0.22, 0.22) if pivoting else 0.0)
		_emit_track(sp, sy, track_x, z_off, track_w, track_l, track_life, is_tank, rut_color)
	if st.right_dist >= TRACK_STRIDE:
		st.right_dist = fmod(st.right_dist, TRACK_STRIDE)

	# Paved floors leave faint scuff marks only — no kicked-up dirt clods or soil plumes.
	if paved:
		return

	var inst_speed := dist / delta
	var turn_rate := absf(turned) / delta
	var moving_enough := (maxf(speed, inst_speed) > 0.5 or turn_rate > 0.40) if is_tank else (maxf(speed, inst_speed) > 1.5)
	if not moving_enough:
		return

	var dirt_stride := TANK_DIRT_STRIDE if is_tank else CAR_DIRT_STRIDE
	st.dirt_dist += dist + (turn_travel if is_tank else 0.0)
	if st.dirt_dist < dirt_stride:
		return

	var wet := float(WeatherState.state.get("ground_wetness", 0.0)) if WeatherState.active else 0.0
	var clod_color := _clod_color(ground_kind, ground_color, wet)
	var dust_color := ground_color.lerp(Color(0.72, 0.66, 0.56), 0.30)
	var eff_speed := maxf(speed, (dist + turn_travel) / delta)
	var spd_f := clampf(eff_speed / (8.5 if is_tank else 13.0), 0.30, 1.35)
	var gy := GroundHeight.at(pos.x, pos.y)
	var base := Vector3(pos.x, gy, pos.y)

	# Per-side launch direction matches differential tracks when pivoting in place.
	var left_fwd := signed_move - turned * track_x
	var right_fwd := signed_move + turned * track_x
	var left_kick_z := 1.0 if left_fwd >= -0.001 else -1.0
	var right_kick_z := 1.0 if right_fwd >= -0.001 else -1.0

	var steps := 0
	while st.dirt_dist >= dirt_stride and steps < MAX_DIRT_STEPS_PER_FRAME:
		st.dirt_dist -= dirt_stride
		steps += 1
		if is_tank:
			_emit_tank_dirt(base, rot, left_kick_z, right_kick_z, spd_f, wet, clod_color, dust_color)
		else:
			var car_kick_z := 1.0 if signed_move >= -0.001 else -1.0
			_emit_car_dirt(base, rot, car_kick_z, spd_f, wet, clod_color, dust_color)
	if st.dirt_dist >= dirt_stride:
		st.dirt_dist = fmod(st.dirt_dist, dirt_stride)


func _emit_tank_dirt(base: Vector3, rot: Basis, left_kick_z: float, right_kick_z: float,
		spd_f: float, wet: float, clod_color: Color, dust_color: Color) -> void:
	for s_idx in 2:
		var side := -1.0 if s_idx == 0 else 1.0
		var kz := left_kick_z if s_idx == 0 else right_kick_z
		# 2 chunky ballistic dirt/mud clod clusters from the rear track cleats.
		for _c in 2:
			var local_at := Vector3(
				side * (TANK_TRACK_X + randf_range(-0.14, 0.14)),
				randf_range(0.08, 0.16),
				kz * (1.08 + randf_range(-0.12, 0.10))
			)
			var local_vel := Vector3(
				side * randf_range(0.55, 1.75),
				randf_range(2.2, 4.5) * (0.72 + 0.42 * spd_f),
				kz * randf_range(2.2, 5.1) * (0.68 + 0.48 * spd_f)
			)
			var cc := clod_color
			cc.a = randf_range(0.86, 1.0)
			_emit_dirt(base + rot * local_at, rot * local_vel, randf_range(0.18, 0.32),
				randf_range(0.38, 0.64), 0, cc)
		# Occasional mid/front churning cleat spray for heavy tank weight.
		if randf() < 0.48:
			var edge_at := Vector3(
				side * (TANK_TRACK_X + 0.14),
				randf_range(0.06, 0.12),
				kz * randf_range(-0.55, 0.65)
			)
			var edge_vel := Vector3(
				side * randf_range(1.1, 2.3),
				randf_range(1.6, 3.2) * (0.75 + 0.35 * spd_f),
				kz * randf_range(0.8, 2.4)
			)
			var ec := clod_color
			ec.a = randf_range(0.78, 0.96)
			_emit_dirt(base + rot * edge_at, rot * edge_vel, randf_range(0.14, 0.24),
				randf_range(0.32, 0.52), 0, ec)
		# Swirling ground-tinted dust/soil plume behind rear treads (toned down when wet).
		if wet < 0.85 or randf() < 0.45:
			var dust_at := Vector3(
				side * (TANK_TRACK_X + randf_range(-0.12, 0.12)),
				0.16,
				kz * 1.12
			)
			var dust_vel := Vector3(
				side * randf_range(0.35, 1.15),
				randf_range(1.15, 2.25) * (0.70 + 0.35 * spd_f),
				kz * randf_range(1.2, 2.7) * (0.75 + 0.35 * spd_f)
			)
			var dc := dust_color
			dc.a = randf_range(0.34, 0.52) * (1.0 - wet * 0.45)
			_emit_dirt(base + rot * dust_at, rot * dust_vel, randf_range(0.58, 0.96),
				randf_range(0.65, 1.15), 1, dc)


func _emit_car_dirt(base: Vector3, rot: Basis, kick_z: float, spd_f: float,
		wet: float, clod_color: Color, dust_color: Color) -> void:
	for s_idx in 2:
		var side := -1.0 if s_idx == 0 else 1.0
		var local_at := Vector3(
			side * (CAR_TRACK_X + randf_range(-0.08, 0.08)),
			randf_range(0.06, 0.12),
			kick_z * (0.85 + randf_range(-0.10, 0.08))
		)
		var local_vel := Vector3(
			side * randf_range(0.45, 1.35),
			randf_range(1.8, 3.6) * (0.75 + 0.40 * spd_f),
			kick_z * randf_range(2.6, 5.8) * (0.70 + 0.45 * spd_f)
		)
		var cc := clod_color
		cc.a = randf_range(0.80, 0.96)
		_emit_dirt(base + rot * local_at, rot * local_vel, randf_range(0.16, 0.30),
			randf_range(0.36, 0.66), 0, cc)
	if wet < 0.85 or randf() < 0.40:
		var side := -1.0 if randf() < 0.5 else 1.0
		var dust_at := Vector3(side * CAR_TRACK_X, 0.14, kick_z * 0.90)
		var dust_vel := Vector3(
			side * randf_range(0.30, 0.95),
			randf_range(1.0, 2.0) * (0.75 + 0.35 * spd_f),
			kick_z * randf_range(1.4, 3.0)
		)
		var dc := dust_color
		dc.a = randf_range(0.28, 0.44) * (1.0 - wet * 0.45)
		_emit_dirt(base + rot * dust_at, rot * dust_vel, randf_range(0.44, 0.74),
			randf_range(0.55, 0.95), 1, dc)


func _emit_track(pos: Vector2, yaw: float, side_x: float, local_z: float,
		width: float, length_tiles: float, life: float, is_tank: bool, color: Color) -> void:
	var rot := Basis(Vector3.UP, yaw)
	var offset := rot * Vector3(side_x, 0.0, local_z)
	var xf := Transform3D(rot, Vector3(pos.x + offset.x, 0.0, pos.y + offset.z))
	var idx := _track_cursor
	_track_cursor = (_track_cursor + 1) % MAX_TRACKS
	if _track_used < MAX_TRACKS:
		_track_used += 1
		_tracks_mm.visible_instance_count = _track_used
	_tracks_mm.set_instance_transform(idx, xf)
	_tracks_mm.set_instance_color(idx, color)
	_tracks_mm.set_instance_custom_data(idx, Color(_clock, life, width, length_tiles if is_tank else -length_tiles))
	_track_active_until = maxf(_track_active_until, _elapsed + life + 0.1)
	if not _tracks_mmi.visible:
		_tracks_mmi.visible = true


func _emit_dirt(world_pos: Vector3, vel: Vector3, size: float, life: float, kind: int, color: Color) -> void:
	var spd := clampf(vel.length(), 0.1, 30.0)
	var dir := vel / spd if vel.length_squared() > 1e-6 else Vector3(0.0, 1.0, 0.0)
	var up := Vector3.UP if absf(dir.y) < 0.95 else Vector3.FORWARD
	var basis := Basis.looking_at(dir, up)
	var xf := Transform3D(basis, world_pos)
	var idx := _dirt_cursor
	_dirt_cursor = (_dirt_cursor + 1) % MAX_DIRT
	if _dirt_used < MAX_DIRT:
		_dirt_used += 1
		_dirt_mm.visible_instance_count = _dirt_used
	_dirt_mm.set_instance_transform(idx, xf)
	_dirt_mm.set_instance_color(idx, color)
	_dirt_mm.set_instance_custom_data(idx, Color(_clock, life, size, float(kind) * 100.0 + spd))
	_dirt_active_until = maxf(_dirt_active_until, _elapsed + life + 0.1)
	if not _dirt_mmi.visible:
		_dirt_mmi.visible = true


static func _rut_color(ground_kind: String, ground_color: Color, paved: bool) -> Color:
	var c := Color(
		clampf(ground_color.r, 0.08, 0.95),
		clampf(ground_color.g, 0.08, 0.95),
		clampf(ground_color.b, 0.08, 0.95),
		1.0
	)
	if paved:
		return c.lerp(Color(0.18, 0.17, 0.16, 1.0), 0.65)
	if ground_kind == "grass":
		return c.lerp(Color(0.34, 0.25, 0.17, 1.0), 0.50)
	if ground_kind == "mud":
		return c.lerp(Color(0.24, 0.19, 0.14, 1.0), 0.45)
	return c.lerp(Color(0.32, 0.24, 0.17, 1.0), 0.22)


static func _clod_color(ground_kind: String, ground_color: Color, wet: float) -> Color:
	var c := Color(
		clampf(ground_color.r, 0.10, 0.92),
		clampf(ground_color.g, 0.10, 0.92),
		clampf(ground_color.b, 0.10, 0.92),
		1.0
	)
	if ground_kind == "grass":
		c = c.lerp(Color(0.30, 0.22, 0.14, 1.0), 0.62)
	elif ground_kind == "mud":
		c = c.lerp(Color(0.22, 0.17, 0.12, 1.0), 0.50)
	else:
		c = c.lerp(Color(0.28, 0.22, 0.16, 1.0), 0.24)
	if wet > 0.3:
		c = c.lerp(Color(0.16, 0.12, 0.09, 1.0), clampf((wet - 0.3) * 0.78, 0.0, 0.52))
	return c


func tick(delta: float, focus: Vector2) -> void:
	if delta > 0.0:
		_elapsed += delta
		_clock = fposmod(_elapsed, CLOCK_WRAP)
		_prune_timer += delta
		if _prune_timer >= 1.0:
			_prune_timer = 0.0
			for unit in _vehicles.keys():
				var st: TrackState = _vehicles[unit]
				if _elapsed - st.last_seen > STALE_TIMEOUT:
					_vehicles.erase(unit)

	if _tracks_mmi == null:
		return

	var tracks_live := enabled and _track_used > 0 and _elapsed < _track_active_until
	if not tracks_live:
		if _tracks_mmi.visible:
			_tracks_mmi.visible = false
			_tracks_mm.visible_instance_count = 0
			_track_used = 0
			_track_cursor = 0
	else:
		_tracks_mat.set_shader_parameter("now", _clock)
		var fy := GroundHeight.at(focus.x, focus.y)
		_tracks_mmi.custom_aabb = AABB(Vector3(focus.x - 96.0, fy - 32.0, focus.y - 96.0), Vector3(192.0, 64.0, 192.0))

	var dirt_live := enabled and _dirt_used > 0 and _elapsed < _dirt_active_until
	if not dirt_live:
		if _dirt_mmi.visible:
			_dirt_mmi.visible = false
			_dirt_mm.visible_instance_count = 0
			_dirt_used = 0
			_dirt_cursor = 0
	else:
		_dirt_mat.set_shader_parameter("now", _clock)
		var fy2 := GroundHeight.at(focus.x, focus.y)
		_dirt_mmi.custom_aabb = AABB(Vector3(focus.x - 72.0, fy2 - 24.0, focus.y - 72.0), Vector3(144.0, 56.0, 144.0))


func clear() -> void:
	_vehicles.clear()
	_track_cursor = 0
	_track_used = 0
	_track_active_until = 0.0
	_dirt_cursor = 0
	_dirt_used = 0
	_dirt_active_until = 0.0
	if _tracks_mmi != null:
		_tracks_mmi.visible = false
		_tracks_mm.visible_instance_count = 0
	if _dirt_mmi != null:
		_dirt_mmi.visible = false
		_dirt_mm.visible_instance_count = 0
