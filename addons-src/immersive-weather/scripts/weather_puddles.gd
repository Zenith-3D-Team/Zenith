extends Node3D
## Vehicle puddle splashes, directional wake ripples, wet-ground spray mist,
## positional splash audio triggers, and subtle driver-seat shudder for Immersive Weather.
##
## Samples the exact CPU equivalent of `weather_surface.gdshaderinc`'s puddle depth field
## under car wheels, tank tracks/bow, and spidertron footsteps near the camera focus.

const MAX_SPLASH_PARTICLES := 1600
const CLOCK_WRAP := 1000.0
const ACTIVE_RADIUS := 48.0
const MAX_VEHICLES := 12
const WIND_TO_TILES := 7.0
const WIND_MAX := 14.0

const CAR_EMITTERS: Array[Vector2] = [
	Vector2(-0.745, -0.985),
	Vector2(0.745, -0.985),
	Vector2(-0.745, 0.655),
	Vector2(0.745, 0.655),
]
const TANK_EMITTERS: Array[Vector2] = [
	Vector2(-0.66, -1.20),
	Vector2(0.66, -1.20),
	Vector2(-0.66, 1.00),
	Vector2(0.66, 1.00),
	Vector2(0.0, -1.45),
]
const SPIDER_LEG_ANGLES: Array[float] = [
	0.38, 0.98, 2.16, 2.76,
	-0.38, -0.98, -2.16, -2.76,
]


class VehicleTrack:
	var unit := 0
	var is_tank := false
	var is_spider := false
	var weight := 1.0
	var pos := Vector2.ZERO
	var forward := Vector2(0.0, -1.0)
	var foot_accum := 0.0
	var leg_idx := 0
	var emitter_prev := PackedFloat32Array()
	var emitter_dist := PackedFloat32Array()
	var entry_cd := 0.0
	var ripple_cd := 0.0
	var ripple_side := 0
	var initialized := false


var api
var audio = null

var _splashes: MultiMeshInstance3D
var _splash_mm: MultiMesh
var _splash_mat: ShaderMaterial
var _ready_ok := false
var _clock := 0.0
var _spawn_head := 0
var _last_spawn := -999.0
var _wind := Vector2.ZERO
var _tracks: Dictionary = {}
var _rumble := 0.0
var _rumble_time := 0.0
var _disabled_cli := ("--puddle-splashes=off" in OS.get_cmdline_user_args())

# Per-frame step parameters to keep helper signatures compact.
var _f_puddle_amt := 0.0
var _f_puddle_scale := 0.12
var _f_wetness := 0.0
var _f_strength := 1.0
var _f_audio_on := false
var _f_effects_gain := 0.0
var _f_rumble_on := false
var _f_driven_unit := 0


func setup(a, audio_ctrl = null) -> void:
	api = a
	audio = audio_ctrl
	_clear_children()
	var base_dir := ""
	if api != null and str(api.dir) != "":
		base_dir = str(api.dir)
	else:
		base_dir = (get_script() as Script).resource_path.get_base_dir().get_base_dir()
	var shader_path := base_dir.path_join("shaders/vehicle_splashes.gdshader")
	var splash_shader := load(shader_path) as Shader
	if splash_shader == null:
		if api != null:
			api.note("vehicle_splashes.gdshader can't be read: no vehicle puddle splashes")
		return

	_splash_mat = ShaderMaterial.new()
	_splash_mat.shader = splash_shader

	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	_splash_mm = MultiMesh.new()
	_splash_mm.transform_format = MultiMesh.TRANSFORM_3D
	_splash_mm.use_colors = true
	_splash_mm.use_custom_data = true
	_splash_mm.mesh = quad
	_splash_mm.instance_count = MAX_SPLASH_PARTICLES
	_splash_mm.visible_instance_count = 0
	for i in MAX_SPLASH_PARTICLES:
		_splash_mm.set_instance_transform(i, Transform3D.IDENTITY)
		_splash_mm.set_instance_color(i, Color(0.5, 0.5, 0.5, 0.0))
		_splash_mm.set_instance_custom_data(i, Color(0.0, 0.0, 0.0, 0.0))

	_splashes = MultiMeshInstance3D.new()
	_splashes.name = "VehicleSplashes"
	_splashes.multimesh = _splash_mm
	_splashes.material_override = _splash_mat
	_splashes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_splashes.extra_cull_margin = 64.0
	_splashes.custom_aabb = AABB(Vector3(-64.0, -12.0, -64.0), Vector3(128.0, 32.0, 128.0))
	_splashes.position = Vector3.ZERO
	_splashes.visible = false
	add_child(_splashes)
	_ready_ok = true


func _clear_children() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_splashes = null
	_splash_mm = null
	_splash_mat = null
	_ready_ok = false


func _setting(key: String, fallback: Variant) -> Variant:
	if api == null or api.get("settings") == null or api.settings == null:
		return fallback
	var v: Variant = api.settings.value(key)
	return fallback if v == null else v


static func _fract(x: float) -> float:
	return x - floorf(x)


## Exact CPU mirror of `client/shaders/noise.gdshaderinc` hash12.
static func hash12(p: Vector2) -> float:
	var px := fposmod(p.x, 4096.0)
	var py := fposmod(p.y, 4096.0)
	var p3 := Vector3(_fract(px * 0.1031), _fract(py * 0.1031), _fract(px * 0.1031))
	var d := p3.x * (p3.y + 33.33) + p3.y * (p3.z + 33.33) + p3.z * (p3.x + 33.33)
	p3 += Vector3(d, d, d)
	return _fract((p3.x + p3.y) * p3.z)


## Exact CPU mirror of `client/shaders/noise.gdshaderinc` vnoise.
static func vnoise(x: Vector2) -> float:
	var i := Vector2(floorf(x.x), floorf(x.y))
	var f := Vector2(x.x - i.x, x.y - i.y)
	var ux := f.x * f.x * (3.0 - 2.0 * f.x)
	var uy := f.y * f.y * (3.0 - 2.0 * f.y)
	var a := hash12(i)
	var b := hash12(i + Vector2(1.0, 0.0))
	var c := hash12(i + Vector2(0.0, 1.0))
	var d := hash12(i + Vector2(1.0, 1.0))
	var k1 := b - a
	var k2 := c - a
	var k4 := a - b - c + d
	return a + k1 * ux + k2 * uy + k4 * ux * uy


## Exact CPU mirror of `client/shaders/noise.gdshaderinc` fbm3.
static func fbm3(p: Vector2) -> float:
	var q := p
	var v := 0.5 * vnoise(q)
	q = Vector2(0.8 * q.x - 0.6 * q.y, 0.6 * q.x + 0.8 * q.y) * 2.03
	v += 0.3 * vnoise(q)
	q = Vector2(0.8 * q.x - 0.6 * q.y, 0.6 * q.x + 0.8 * q.y) * 2.01
	v += 0.2 * vnoise(q)
	return v


## Exact CPU mirror of `client/shaders/weather_surface.gdshaderinc` puddle depth sampler.
static func puddle_depth_at(
	x: float,
	z: float,
	puddle_amt: float,
	puddle_scale: float,
	hill_nrm_y := 1.0
) -> float:
	var amt := clampf(puddle_amt, 0.0, 1.0)
	if amt <= 0.001:
		return 0.0
	var flat_mask := smoothstep(0.92, 0.985, hill_nrm_y)
	if flat_mask <= 0.001:
		return 0.0
	var sc := maxf(puddle_scale, 0.02)
	var wxz := Vector2(x, z)
	var base := fbm3(wxz * sc + Vector2(3.7, 11.3))
	var detail := (vnoise(wxz * sc * 2.9 + Vector2(17.1, -9.4)) - 0.5) * 0.14
	var n := base + detail + 0.05
	var thresh := lerpf(0.73, 0.51, amt)
	var cov := smoothstep(thresh, thresh + 0.045, n)
	return cov * flat_mask * smoothstep(0.0, 0.08, amt)


func _ground_y(x: float, z: float) -> float:
	if api == null or api.get("terrain") == null or api.terrain == null:
		return 0.0
	return float(api.terrain.height_at(x, z))


func _sample_puddle(x: float, z: float, puddle_amt: float, puddle_scale: float) -> float:
	if puddle_amt <= 0.001:
		return 0.0
	var nrm_y := 1.0
	if api != null and api.get("terrain") != null and api.terrain != null and api.terrain.is_on():
		var hx := float(api.terrain.height_at(x + 0.5, z))
		hx -= float(api.terrain.height_at(x - 0.5, z))
		var hz := float(api.terrain.height_at(x, z + 0.5))
		hz -= float(api.terrain.height_at(x, z - 0.5))
		nrm_y = 1.0 / sqrt(1.0 + hx * hx + hz * hz)
	return puddle_depth_at(x, z, puddle_amt, puddle_scale, nrm_y)


func _is_disabled() -> bool:
	if _disabled_cli:
		return true
	if api != null and api.get("weather") != null and api.weather != null:
		if api.weather.has_method("disabled") and bool(api.weather.disabled()):
			return true
		if api.weather.has_method("splashes_disabled") and bool(api.weather.splashes_disabled()):
			return true
	return false


func update(delta: float, active_on_nauvis: bool, spec: Dictionary) -> void:
	if not _ready_ok:
		return
	if not active_on_nauvis:
		if _splashes.visible or not _tracks.is_empty() or _rumble > 0.0:
			clear()
		return
	if bool(api.view.screenshot_busy()):
		return

	_clock = fposmod(_clock + delta, CLOCK_WRAP)
	if _rumble > 0.002:
		_rumble = maxf(0.0, _rumble * exp(-delta / 0.075) - delta * 0.4)
		_rumble_time += delta
	else:
		_rumble = 0.0

	var wind_target := Vector2.ZERO
	var w: Variant = spec.get("wind", Vector2.ZERO)
	if w is Vector2:
		wind_target = (w as Vector2) * WIND_TO_TILES
	if wind_target.length() > WIND_MAX:
		wind_target = wind_target.normalized() * WIND_MAX
	_wind = _wind.lerp(wind_target, clampf(delta * 1.5, 0.0, 1.0))

	var spl_on := bool(_setting("vehicle_puddle_splashes_enabled", true))
	var enabled := (not _is_disabled()) and spl_on
	_f_strength = clampf(float(_setting("vehicle_puddle_splash_strength", 1.0)), 0.0, 2.0)
	_f_puddle_amt = clampf(float(spec.get("puddle_amount", 0.0)), 0.0, 1.0)
	_f_puddle_scale = maxf(float(spec.get("puddle_scale", 0.12)), 0.02)
	_f_wetness = clampf(float(spec.get("ground_wetness", 0.0)), 0.0, 1.0)

	if api.weather != null and api.weather.has_method("set_puddle_ripple_strength"):
		var r_str := _f_strength if (enabled and _f_puddle_amt > 0.005) else 0.0
		api.weather.set_puddle_ripple_strength(r_str)

	var focus: Vector2 = api.world.focus()
	var aud_master := bool(_setting("audio_enabled", true))
	var aud_puddle := bool(_setting("vehicle_puddle_audio_enabled", true))
	_f_audio_on = aud_master and aud_puddle
	var vol_base := float(_setting("audio_volume", 0.55))
	_f_effects_gain = clampf(vol_base, 0.0, 1.5)
	_f_rumble_on = bool(_setting("vehicle_puddle_rumble_enabled", true))

	if enabled and _f_strength > 0.005 and (_f_puddle_amt > 0.005 or _f_wetness > 0.40):
		_step_vehicles(delta, focus)
	else:
		_tracks.clear()
		if audio != null:
			audio.update_spray(false, Vector3.ZERO, 0.0, 0.0, false, 0.0)

	var since := fposmod(_clock - _last_spawn + CLOCK_WRAP, CLOCK_WRAP)
	if since > 1.2:
		_splash_mm.visible_instance_count = 0
		_splashes.visible = false
		return

	var ground_focus := _ground_y(focus.x, focus.y)
	if _splashes.is_inside_tree():
		_splashes.global_position = Vector3.ZERO
	else:
		_splashes.position = Vector3.ZERO
	var box_pos := Vector3(focus.x - 64.0, ground_focus - 12.0, focus.y - 64.0)
	_splashes.custom_aabb = AABB(box_pos, Vector3(128.0, 32.0, 128.0))
	_splashes.visible = true
	_splash_mm.visible_instance_count = MAX_SPLASH_PARTICLES

	var day := 1.0 - clampf(float(api.world.darkness()) / 0.85, 0.0, 1.0)
	var vis := clampf(float(_setting("rain_visibility", 1.0)) * _f_strength, 0.25, 2.0)
	_splash_mat.set_shader_parameter("now", _clock)
	_splash_mat.set_shader_parameter("wind", _wind)
	_splash_mat.set_shader_parameter("visibility", vis)
	_splash_mat.set_shader_parameter("day_factor", day)


func _step_vehicles(delta: float, focus: Vector2) -> void:
	var movers: Array = api.world.movers(["car", "spider-vehicle"])
	var radius_sq := ACTIVE_RADIUS * ACTIVE_RADIUS
	var candidates: Array = []
	for m_v: Variant in movers:
		if not m_v is Dictionary:
			continue
		var m: Dictionary = m_v
		var p3: Variant = m.get("position")
		if not p3 is Vector3:
			continue
		var pvec := p3 as Vector3
		var pos2 := Vector2(pvec.x, pvec.z)
		var d2 := pos2.distance_squared_to(focus)
		if d2 <= radius_sq:
			candidates.append({"d2": d2, "m": m, "pos2": pos2})

	if candidates.size() > MAX_VEHICLES:
		var by_dist := func(a: Dictionary, b: Dictionary) -> bool:
			return float(a["d2"]) < float(b["d2"])
		candidates.sort_custom(by_dist)
		candidates.resize(MAX_VEHICLES)

	var seen := {}
	_f_driven_unit = 0
	var ch: Dictionary = api.world.character()
	if not ch.is_empty():
		_f_driven_unit = int(ch.get("vehicle", 0))

	var best_spray_d2 := INF
	var best_spray_pos := Vector3.ZERO
	var best_spray_intensity := 0.0
	var best_spray_speed := 0.0
	var best_spray_heavy := false

	for cand_v: Variant in candidates:
		var cand: Dictionary = cand_v
		var m: Dictionary = cand["m"]
		var unit := int(m.get("unit", 0))
		if unit == 0:
			continue
		seen[unit] = true
		var pos2: Vector2 = cand["pos2"]
		var f3: Variant = m.get("forward", Vector3.FORWARD)
		var fvec := f3 as Vector3 if f3 is Vector3 else Vector3.FORWARD
		var fwd2 := Vector2(fvec.x, fvec.z)
		fwd2 = fwd2.normalized() if fwd2.length_squared() > 1e-6 else Vector2(0.0, -1.0)
		var vtype := str(m.get("type", ""))
		var pname := str(m.get("name", ""))
		var is_spider := vtype == "spider-vehicle"
		var is_tank := (not is_spider) and pname.contains("tank")

		var tr: VehicleTrack = _tracks.get(unit)
		if tr == null:
			tr = _make_track(unit, is_spider, is_tank)
			_tracks[unit] = tr

		var moved := pos2 - tr.pos
		var dist := moved.length()
		if not tr.initialized or dist > 6.0:
			tr.pos = pos2
			tr.forward = fwd2
			tr.foot_accum = 0.0
			tr.emitter_dist.fill(0.0)
			tr.initialized = true
			_seed_emitters(tr, pos2, fwd2)
			continue

		tr.entry_cd = maxf(0.0, tr.entry_cd - delta)
		tr.ripple_cd = maxf(0.0, tr.ripple_cd - delta)

		var dt := maxf(delta, 1e-4)
		var angle_diff := tr.forward.angle_to(fwd2)
		var yaw_rate := angle_diff / dt
		var lin_speed := dist / dt
		var pivot_speed := absf(yaw_rate) * 0.95 if tr.is_tank else 0.0
		var eff_speed := lin_speed + pivot_speed
		var move_dir := (moved / dist) if dist > 0.002 else fwd2

		tr.pos = pos2
		tr.forward = fwd2

		var veh_score := 0.0
		var veh_pos3 := Vector3(pos2.x, _ground_y(pos2.x, pos2.y), pos2.y)
		if tr.is_spider:
			veh_score = _step_spider(tr, pos2, fwd2, dist, eff_speed)
		else:
			veh_score = _step_wheeled(tr, pos2, fwd2, move_dir, dist, angle_diff, eff_speed)

		if veh_score > 0.02:
			var d2 := float(cand["d2"])
			if d2 < best_spray_d2:
				best_spray_d2 = d2
				best_spray_pos = veh_pos3
				best_spray_intensity = clampf(veh_score, 0.0, 1.0)
				best_spray_speed = clampf(eff_speed / 12.0, 0.0, 1.0)
				best_spray_heavy = tr.is_tank or tr.is_spider

	var stale: Array = []
	for u_v: Variant in _tracks.keys():
		var u := int(u_v)
		if not seen.has(u):
			stale.append(u)
	for u: int in stale:
		_tracks.erase(u)

	if audio != null:
		if _f_audio_on and best_spray_intensity > 0.02:
			audio.update_spray(
				true,
				best_spray_pos,
				best_spray_intensity,
				best_spray_speed,
				best_spray_heavy,
				_f_effects_gain
			)
		else:
			audio.update_spray(false, Vector3.ZERO, 0.0, 0.0, false, 0.0)


func _make_track(unit: int, is_spider: bool, is_tank: bool) -> VehicleTrack:
	var tr := VehicleTrack.new()
	tr.unit = unit
	tr.is_spider = is_spider
	tr.is_tank = is_tank
	tr.weight = 1.25 if is_spider else (1.45 if is_tank else 1.0)
	var em_count := 1 if is_spider else (TANK_EMITTERS.size() if is_tank else CAR_EMITTERS.size())
	tr.emitter_prev.resize(em_count)
	tr.emitter_dist.resize(em_count)
	tr.emitter_prev.fill(0.0)
	tr.emitter_dist.fill(0.0)
	return tr


func _seed_emitters(tr: VehicleTrack, pos2: Vector2, fwd2: Vector2) -> void:
	if tr.is_spider:
		tr.emitter_prev[0] = _sample_puddle(pos2.x, pos2.y, _f_puddle_amt, _f_puddle_scale)
		return
	var right2 := Vector2(-fwd2.y, fwd2.x)
	var emitters := TANK_EMITTERS if tr.is_tank else CAR_EMITTERS
	for k in emitters.size():
		var loc := emitters[k]
		var exz := pos2 + right2 * loc.x + fwd2 * (-loc.y)
		tr.emitter_prev[k] = _sample_puddle(exz.x, exz.y, _f_puddle_amt, _f_puddle_scale)


func _step_wheeled(
	tr: VehicleTrack,
	pos2: Vector2,
	fwd2: Vector2,
	move_dir: Vector2,
	dist: float,
	angle_diff: float,
	eff_speed: float
) -> float:
	var right2 := Vector2(-fwd2.y, fwd2.x)
	var emitters := TANK_EMITTERS if tr.is_tank else CAR_EMITTERS
	var best_score := 0.0
	var speed_k := clampf(eff_speed / 7.5, 0.32, 1.45)
	var entry_min_spd := 1.1 if tr.is_tank else 1.6
	var spacing := 0.22 if tr.is_tank else 0.34
	var wake_emitted := false
	var wake_pref_valid := false
	var wake_pref_xz := Vector2.ZERO
	var wake_pref_puddle := 0.0
	var wake_any_valid := false
	var wake_any_xz := Vector2.ZERO
	var wake_any_puddle := 0.0
	var want_right := (tr.ripple_side % 2) == 1

	for k in emitters.size():
		var loc := emitters[k]
		var exz := pos2 + right2 * loc.x + fwd2 * (-loc.y)
		var cur_puddle := _sample_puddle(exz.x, exz.y, _f_puddle_amt, _f_puddle_scale)
		var prev_puddle := tr.emitter_prev[k]
		tr.emitter_prev[k] = cur_puddle

		var em_step := dist + (absf(angle_diff) * loc.length() if tr.is_tank else 0.0)
		var is_bow := tr.is_tank and k == 4
		var lat_sign := signf(loc.x) if absf(loc.x) > 0.05 else (1.0 if randf() > 0.5 else -1.0)
		var out_dir := right2 * lat_sign

		# Puddle entry slam burst.
		if prev_puddle < 0.15 and cur_puddle >= 0.20 and eff_speed > entry_min_spd and tr.entry_cd <= 0.0:
			tr.entry_cd = 0.32
			var gy := _ground_y(exz.x, exz.y)
			var burst_w := clampf(cur_puddle * tr.weight * _f_strength * 1.25, 0.45, 1.0)
			var spawn_pos := Vector3(exz.x, gy + 0.03, exz.y)
			_emit_wheel_burst(spawn_pos, move_dir, out_dir, eff_speed, burst_w, tr.is_tank, is_bow, true)
			_emit_entry_ripple(tr, exz, move_dir, eff_speed, cur_puddle)
			if _f_audio_on and audio != null:
				var imp_str := eff_speed / 9.0 * cur_puddle * tr.weight * _f_strength
				audio.play_impact(
					Vector3(exz.x, gy, exz.y),
					clampf(imp_str, 0.28, 1.5),
					tr.is_tank,
					_f_effects_gain
				)
			if tr.unit == _f_driven_unit and _f_rumble_on:
				var heaviness := 1.25 if tr.is_tank else 0.85
				var thump := clampf(0.48 + eff_speed * 0.055, 0.38, 1.0) * heaviness * _f_strength
				_rumble = maxf(_rumble, thump)
			best_score = maxf(best_score, cur_puddle * speed_k)

		# Continuous distance-driven splash wake while moving through a puddle.
		if cur_puddle >= 0.15 and eff_speed > 0.45:
			var drive_w := cur_puddle * clampf(eff_speed / 8.5, 0.20, 1.0) * tr.weight
			best_score = maxf(best_score, drive_w)
			tr.emitter_dist[k] += em_step
			var emitted := 0
			while tr.emitter_dist[k] >= spacing and emitted < 2:
				tr.emitter_dist[k] -= spacing
				emitted += 1
				var gy := _ground_y(exz.x, exz.y)
				var w_val := clampf(cur_puddle * speed_k * tr.weight * _f_strength * 0.82, 0.28, 1.0)
				var wpos := Vector3(exz.x, gy + 0.03, exz.y)
				_emit_wheel_burst(wpos, move_dir, out_dir, eff_speed, w_val, tr.is_tank, is_bow, false)
			tr.emitter_dist[k] = minf(tr.emitter_dist[k], spacing)
			if emitted > 0:
				wake_emitted = true
				if not wake_any_valid or cur_puddle > wake_any_puddle:
					wake_any_valid = true
					wake_any_xz = exz
					wake_any_puddle = cur_puddle
				var is_side_match := (loc.x > 0.05 and want_right) or (loc.x < -0.05 and not want_right)
				if is_side_match and (not wake_pref_valid or cur_puddle > wake_pref_puddle):
					wake_pref_valid = true
					wake_pref_xz = exz
					wake_pref_puddle = cur_puddle

		# Wet-ground rear spray mist (no puddles, wet terrain, fast driving).
		elif cur_puddle < 0.15 and _f_wetness > 0.40 and eff_speed > 4.5 and loc.y > 0.0:
			var mist_score := _f_wetness * clampf((eff_speed - 4.0) / 10.0, 0.0, 0.45)
			best_score = maxf(best_score, mist_score)
			tr.emitter_dist[k] += em_step
			if tr.emitter_dist[k] >= 0.55:
				tr.emitter_dist[k] = fposmod(tr.emitter_dist[k], 0.55)
				var gy := _ground_y(exz.x, exz.y)
				var mist_k := clampf((eff_speed - 3.5) / 10.0, 0.15, 0.7)
				var mist_w := clampf(_f_wetness * mist_k * _f_strength * 0.65, 0.12, 0.65)
				var back_spd := 1.2 + eff_speed * 0.15
				var rear_v := Vector3(
					-move_dir.x * back_spd + out_dir.x * 0.7,
					randf_range(0.7, 1.5),
					-move_dir.y * back_spd + out_dir.y * 0.7
				)
				_emit_particle(
					Vector3(exz.x, gy + 0.05, exz.y),
					rear_v,
					randf_range(0.38, 0.62),
					randf_range(0.32, 0.52),
					2,
					mist_w
				)
		else:
			tr.emitter_dist[k] = minf(tr.emitter_dist[k], 0.20)

	if wake_emitted and tr.ripple_cd <= 0.0:
		if wake_pref_valid:
			_emit_wake_ripple(tr, wake_pref_xz, move_dir, eff_speed, wake_pref_puddle)
			tr.ripple_side += 1
		elif wake_any_valid:
			_emit_wake_ripple(tr, wake_any_xz, move_dir, eff_speed, wake_any_puddle)
			tr.ripple_side += 1

	return best_score


func _emit_entry_ripple(
	tr: VehicleTrack,
	exz: Vector2,
	move_dir: Vector2,
	eff_speed: float,
	cur_puddle: float
) -> void:
	if api.weather == null or not api.weather.has_method("add_puddle_ripple"):
		return
	var r_rad := randf_range(3.2, 5.0) if tr.is_tank else randf_range(2.0, 3.1)
	var r_life := randf_range(1.9, 2.6) if tr.is_tank else randf_range(1.2, 1.8)
	var r_str := 0.0
	if tr.is_tank:
		var spd := clampf(eff_speed / 5.5, 0.72, 1.35)
		var base_s := clampf(1.52 * clampf(cur_puddle, 0.50, 1.0) * spd, 1.15, 1.80)
		r_str = clampf(base_s * _f_strength, 0.0, 2.4)
		tr.ripple_cd = 0.07
	else:
		var spd := clampf(eff_speed / 7.5, 0.55, 1.30)
		r_str = clampf(0.88 * cur_puddle * _f_strength * spd, 0.30, 1.45)
		tr.ripple_cd = 0.10
	api.weather.add_puddle_ripple(exz + move_dir * 0.45, move_dir, r_rad, r_str, r_life)


func _emit_wake_ripple(
	tr: VehicleTrack,
	exz: Vector2,
	move_dir: Vector2,
	eff_speed: float,
	cur_puddle: float
) -> void:
	if api.weather == null or not api.weather.has_method("add_puddle_ripple"):
		return
	var wake_rad := randf_range(2.2, 3.6) if tr.is_tank else randf_range(1.4, 2.3)
	var wake_life := randf_range(1.8, 2.5) if tr.is_tank else randf_range(1.0, 1.6)
	var wake_str := 0.0
	if tr.is_tank:
		tr.ripple_cd = 0.07
		var spd := clampf(eff_speed / 6.0, 0.65, 1.30)
		var base_s := clampf(1.40 * clampf(cur_puddle, 0.50, 1.0) * spd, 1.10, 1.75)
		wake_str = clampf(base_s * _f_strength, 0.0, 2.2)
	else:
		tr.ripple_cd = 0.10
		var spd := clampf(eff_speed / 8.5, 0.40, 1.20)
		wake_str = clampf(0.68 * cur_puddle * _f_strength * spd, 0.25, 1.25)
	api.weather.add_puddle_ripple(exz, move_dir, wake_rad, wake_str, wake_life)


func _step_spider(
	tr: VehicleTrack,
	pos2: Vector2,
	fwd2: Vector2,
	dist: float,
	eff_speed: float
) -> float:
	if eff_speed <= 0.8:
		return 0.0
	tr.foot_accum += dist
	var yaw := atan2(fwd2.y, fwd2.x)
	var score := 0.0
	var steps := 0
	while tr.foot_accum >= 0.52 and steps < 2:
		tr.foot_accum -= 0.52
		steps += 1
		tr.leg_idx = (tr.leg_idx + 1) % SPIDER_LEG_ANGLES.size()
		var ang := yaw + SPIDER_LEG_ANGLES[tr.leg_idx]
		var out_dir := Vector2(cos(ang), sin(ang))
		var fxz := pos2 + out_dir * 2.3
		var cur_puddle := _sample_puddle(fxz.x, fxz.y, _f_puddle_amt, _f_puddle_scale)
		if cur_puddle >= 0.15:
			var gy := _ground_y(fxz.x, fxz.y)
			var w_val := clampf(cur_puddle * tr.weight * _f_strength * 0.85, 0.25, 1.0)
			for s in 2:
				var jitter := Vector2(randf_range(-0.55, 0.55), randf_range(-0.55, 0.55))
				var fan_dir := (out_dir + jitter).normalized()
				var fh := randf_range(1.6, 3.0)
				var v_sheet := Vector3(fan_dir.x * fh, randf_range(2.2, 3.8), fan_dir.y * fh)
				_emit_particle(
					Vector3(fxz.x, gy + 0.03, fxz.y),
					v_sheet,
					randf_range(0.38, 0.62),
					randf_range(0.32, 0.48),
					0,
					w_val
				)
			for d in 2:
				var dj := Vector2(randf_range(-0.7, 0.7), randf_range(-0.7, 0.7))
				var drop_dir := (out_dir + dj).normalized()
				var dh := randf_range(1.4, 3.4)
				var v_drop := Vector3(drop_dir.x * dh, randf_range(3.2, 5.2), drop_dir.y * dh)
				_emit_particle(
					Vector3(fxz.x, gy + 0.05, fxz.y),
					v_drop,
					randf_range(0.46, 0.72),
					randf_range(0.45, 0.68),
					1,
					w_val
				)
			_emit_particle(
				Vector3(fxz.x, gy + 0.06, fxz.y),
				Vector3(out_dir.x * 0.8, 1.1, out_dir.y * 0.8),
				randf_range(0.45, 0.72),
				randf_range(0.38, 0.58),
				2,
				w_val * 0.75
			)

			if api.weather != null and api.weather.has_method("add_puddle_ripple"):
				var r_rad := randf_range(1.6, 2.5)
				var r_life := randf_range(1.0, 1.5)
				var r_str := clampf(0.65 * cur_puddle * _f_strength, 0.2, 1.2)
				api.weather.add_puddle_ripple(fxz, out_dir, r_rad, r_str, r_life)

			if cur_puddle >= 0.25 and tr.entry_cd <= 0.0:
				tr.entry_cd = 0.28
				if _f_audio_on and audio != null:
					var imp := clampf(cur_puddle * 0.85 * _f_strength, 0.2, 1.2)
					audio.play_impact(Vector3(fxz.x, gy, fxz.y), imp, true, _f_effects_gain)
				if tr.unit == _f_driven_unit and _f_rumble_on:
					_rumble = maxf(_rumble, 0.35 * cur_puddle * _f_strength)
			score = maxf(score, cur_puddle * clampf(eff_speed / 8.0, 0.3, 1.0))
		elif _f_wetness > 0.40 and eff_speed > 4.5:
			var gy := _ground_y(fxz.x, fxz.y)
			var mist_w := clampf(_f_wetness * _f_strength * 0.45, 0.12, 0.50)
			_emit_particle(
				Vector3(fxz.x, gy + 0.04, fxz.y),
				Vector3(out_dir.x * 0.7, 0.9, out_dir.y * 0.7),
				0.42,
				0.36,
				2,
				mist_w
			)
			score = maxf(score, _f_wetness * 0.35)
	return score


func _emit_wheel_burst(
	pos: Vector3,
	move_dir: Vector2,
	out_dir: Vector2,
	eff_speed: float,
	weight: float,
	is_tank: bool,
	is_bow: bool,
	is_entry_slam: bool
) -> void:
	var sp_k := clampf(eff_speed * 0.28, 0.60, 2.6)
	var sheet_count := 1
	var drop_count := 2
	var mist_count := 1
	if is_tank:
		if is_entry_slam:
			sheet_count = randi_range(4, 5)
			drop_count = randi_range(5, 6)
			mist_count = 2
		else:
			sheet_count = 2 if (is_bow or eff_speed > 3.8) else 1
			drop_count = 2
			mist_count = 1
	else:
		if is_entry_slam:
			sheet_count = 3
			drop_count = 5
			mist_count = 2
		else:
			sheet_count = 2 if eff_speed > 5.0 else 1
			drop_count = 2
			mist_count = 1

	var jitter_r := 0.28 if (is_tank and is_entry_slam) else (0.18 if is_tank else 0.12)

	for i in sheet_count:
		var side := out_dir
		if is_bow:
			side = out_dir * (-1.0 if (i % 2 == 1) else 1.0)
		elif is_tank and is_entry_slam and i == sheet_count - 1:
			side = -out_dir * 0.55
		var lat_k := randf_range(0.75, 1.35) if is_tank else randf_range(0.75, 1.15)
		var fwd_k := randf_range(0.30, 1.02) if (is_tank and is_entry_slam) else randf_range(-0.12, 0.68)
		if is_bow and not is_entry_slam:
			fwd_k = randf_range(0.18, 0.78)
		var spray2 := (side * lat_k + move_dir * fwd_k).normalized()
		var h_spd := 0.0
		var v_spd := 0.0
		var sz := 0.0
		var life := 0.0
		if is_tank and is_entry_slam:
			h_spd = randf_range(2.2, 4.4) * (0.78 + sp_k * 0.28)
			v_spd = randf_range(2.8, 5.2) * (0.85 + sp_k * 0.18)
			sz = randf_range(0.58, 1.05)
			life = randf_range(0.34, 0.56)
		elif is_tank:
			h_spd = randf_range(1.7, 3.6) * (0.75 + sp_k * 0.30)
			v_spd = randf_range(2.2, 4.3) * (0.82 + sp_k * 0.22)
			sz = randf_range(0.42, 0.78)
			life = randf_range(0.28, 0.46)
		else:
			h_spd = randf_range(1.6, 3.4) * (1.25 if is_entry_slam else 1.0) * (0.70 + sp_k * 0.35)
			v_spd = randf_range(2.2, 4.2) * (1.35 if is_entry_slam else 1.0)
			sz = randf_range(0.48, 0.82) if is_entry_slam else randf_range(0.38, 0.68)
			life = randf_range(0.32, 0.52) if is_entry_slam else randf_range(0.28, 0.46)
		var j_off := Vector3(
			side.x * randf_range(-jitter_r, jitter_r) + move_dir.x * randf_range(-jitter_r, jitter_r),
			0.0,
			side.y * randf_range(-jitter_r, jitter_r) + move_dir.y * randf_range(-jitter_r, jitter_r)
		)
		var vel := Vector3(spray2.x * h_spd, v_spd, spray2.y * h_spd)
		_emit_particle(pos + j_off, vel, sz, life, 0, clampf(weight, 0.20, 1.0))

	for i in drop_count:
		var side := out_dir
		if is_bow:
			side = out_dir * (-1.0 if (i % 2 == 1) else 1.0)
		elif is_tank and is_entry_slam and i >= drop_count - 2:
			side = -out_dir * randf_range(0.45, 0.95)
		var lat_k := 0.0
		var fwd_k := 0.0
		var h_spd := 0.0
		var v_spd := 0.0
		var sz := 0.0
		var life := 0.0
		if is_tank and is_entry_slam:
			lat_k = randf_range(0.45, 1.35)
			fwd_k = randf_range(-0.65, 1.10)
			var spd_boost := clampf(0.85 + eff_speed * 0.035, 0.85, 1.22)
			h_spd = randf_range(2.4, 5.2) * spd_boost
			v_spd = randf_range(3.2, 6.2) * clampf(0.90 + eff_speed * 0.02, 0.90, 1.15)
			sz = randf_range(0.42, 0.72)
			life = randf_range(0.42, 0.70)
		elif is_tank:
			# Alternate lateral outward curtains and backward-upward track-cleat rooster-tails.
			if (not is_bow) and (i % 2 == 1):
				lat_k = randf_range(0.25, 0.90)
				fwd_k = randf_range(-1.15, -0.35)
				h_spd = randf_range(1.8, 4.2) * (0.78 + sp_k * 0.28)
				v_spd = randf_range(3.2, 5.6)
			else:
				lat_k = randf_range(0.75, 1.35)
				fwd_k = randf_range(-0.15, 0.78)
				h_spd = randf_range(2.1, 4.6) * (0.78 + sp_k * 0.28)
				v_spd = randf_range(2.8, 5.2)
			sz = randf_range(0.36, 0.64)
			life = randf_range(0.36, 0.62)
		else:
			if i % 2 == 1 and not is_entry_slam:
				lat_k = randf_range(0.30, 0.85)
				fwd_k = randf_range(-1.05, -0.25)
			else:
				lat_k = randf_range(0.60, 1.20)
				fwd_k = randf_range(-0.25, 0.75)
			h_spd = randf_range(1.8, 4.2) * (1.25 if is_entry_slam else 1.0) * (0.70 + sp_k * 0.35)
			v_spd = randf_range(3.0, 5.6) * (1.28 if is_entry_slam else 1.0)
			sz = randf_range(0.46, 0.78) if is_entry_slam else randf_range(0.42, 0.72)
			life = randf_range(0.44, 0.74)
		var drop2 := (side * lat_k + move_dir * fwd_k).normalized()
		var d_off := Vector3(
			side.x * randf_range(-jitter_r, jitter_r) + move_dir.x * randf_range(-jitter_r, jitter_r),
			0.03,
			side.y * randf_range(-jitter_r, jitter_r) + move_dir.y * randf_range(-jitter_r, jitter_r)
		)
		var dvel := Vector3(drop2.x * h_spd, v_spd, drop2.y * h_spd)
		_emit_particle(pos + d_off, dvel, sz, life, 1, clampf(weight * 0.96, 0.20, 1.0))

	for i in mist_count:
		if not is_tank and not is_entry_slam and randf() > 0.65:
			continue
		var side := out_dir * (-1.0 if (is_bow and i % 2 == 1) else 1.0)
		var lat_k := randf_range(0.45, 1.05)
		var fwd_k := randf_range(-0.20, 0.65)
		var mist2 := (side * lat_k - move_dir * fwd_k).normalized()
		var h_spd := 0.0
		var v_spd := 0.0
		var sz := 0.0
		var life := 0.0
		if is_tank and is_entry_slam:
			h_spd = randf_range(1.1, 2.5)
			v_spd = randf_range(0.75, 1.65)
			sz = randf_range(0.52, 0.86)
			life = randf_range(0.38, 0.62)
		elif is_tank:
			h_spd = randf_range(0.9, 2.0)
			v_spd = randf_range(0.65, 1.45)
			sz = randf_range(0.58, 0.98)
			life = randf_range(0.38, 0.64)
		else:
			h_spd = randf_range(0.8, 1.8) * (1.15 if is_entry_slam else 1.0)
			v_spd = randf_range(0.85, 1.8)
			sz = randf_range(0.52, 0.88) if is_entry_slam else randf_range(0.45, 0.76)
			life = randf_range(0.38, 0.65)
		var m_off := Vector3(
			side.x * randf_range(-jitter_r, jitter_r),
			0.04,
			side.y * randf_range(-jitter_r, jitter_r)
		)
		var mvel := Vector3(mist2.x * h_spd, v_spd, mist2.y * h_spd)
		_emit_particle(pos + m_off, mvel, sz, life, 2, clampf(weight * 0.82, 0.14, 0.90))


func _emit_particle(
	pos: Vector3,
	vel: Vector3,
	size: float,
	life: float,
	kind: int,
	weight: float
) -> void:
	var vx := clampf(vel.x / 24.0 + 0.5, 0.0, 1.0)
	var vy := clampf(vel.y / 24.0 + 0.5, 0.0, 1.0)
	var vz := clampf(vel.z / 24.0 + 0.5, 0.0, 1.0)
	var w := clampf(weight, 0.0, 1.0)
	var seed := randf() * 0.999
	var i := _spawn_head
	_spawn_head = (_spawn_head + 1) % MAX_SPLASH_PARTICLES
	_splash_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, pos))
	_splash_mm.set_instance_color(i, Color(vx, vy, vz, w))
	_splash_mm.set_instance_custom_data(i, Color(_clock, life, size, float(kind) + seed))
	_last_spawn = _clock


func rumble_offset() -> Vector3:
	if _rumble <= 0.002 or not bool(_setting("vehicle_puddle_rumble_enabled", true)):
		return Vector3.ZERO
	var amp := minf(_rumble, 1.25)
	var ox := clampf(sin(_rumble_time * 52.0) * 0.026 * amp, -0.036, 0.036)
	var oy := clampf(cos(_rumble_time * 43.0) * 0.032 * amp, -0.036, 0.036)
	return Vector3(ox, oy, 0.0)


func rumble_turn() -> Vector3:
	if _rumble <= 0.002 or not bool(_setting("vehicle_puddle_rumble_enabled", true)):
		return Vector3.ZERO
	var amp := minf(_rumble, 1.25)
	var rx := clampf(sin(_rumble_time * 37.0) * 0.0020 * amp, -0.0026, 0.0026)
	var ry := clampf(cos(_rumble_time * 31.0) * 0.0014 * amp, -0.0026, 0.0026)
	var rz := clampf(sin(_rumble_time * 47.0) * 0.0022 * amp, -0.0026, 0.0026)
	return Vector3(rx, ry, rz)


func clear() -> void:
	_tracks.clear()
	_rumble = 0.0
	_rumble_time = 0.0
	_last_spawn = -999.0
	if _splashes != null:
		_splash_mm.visible_instance_count = 0
		_splashes.visible = false
	if api != null and api.get("weather") != null and api.weather != null:
		if api.weather.has_method("clear_puddle_ripples"):
			api.weather.clear_puddle_ripples()
	if audio != null:
		audio.stop_all()
