extends Node3D
## Nauvis thunderstorm lightning & thunder controller for Immersive Weather (Phase 3).
## Visual-only: jagged 3D bolts (ImmediateMesh + pooled OmniLight3D, ground elevation aware),
## cloud/sky sheet flashes via api.weather `flash`, speed-of-sound delayed thunder via
## api.sound.play, and optional gentle camera rumble via api.camera.set_modifier. Zero Factorio damage.
##
## A strike list (`--weather-strikes=<file>` or the Strike list setting; README "Timed strikes") times
## strikes on the game's tick for filmed scenes: each fires when the tick reaches the cue tick
## (`--cue-tick`, api.world.cue_tick, API 1.91) plus its offset, at its tile, with a bolt seeded from
## the entry, so every run looks the same. While a list is loaded the random strikes are off.

const LIFE := 0.55
const HEIGHT_MIN := 65.0
const HEIGHT_MAX := 95.0
const DETAIL := 5
const JITTER := 0.30
const FORKS := Vector2i(2, 4)
const FORK_LENGTH := 0.38
const CORE_WIDTH := 0.20
const GLOW_WIDTH := 1.45
const CORE_COLOR := Color(0.88, 0.95, 1.0)
const GLOW_COLOR := Color(0.32, 0.62, 1.0)
const LIGHT_ENERGY := 10.0
const LIGHT_RANGE := 52.0
const LIGHTS := 4
const MAX_BOLTS := 8
## A listed strike more than this many ticks late (a jump: a save loaded, the list loaded mid-scene)
## is skipped instead of fired; within it (a slow frame) it fires late.
const LATE_TICKS := 120


class Bolt:
	var paths: Array = []
	var age := 0.0
	var phase := 0.0
	var light: OmniLight3D = null
	var ground := Vector3.ZERO


class PendingThunder:
	var delay := 0.0
	var distance := 60.0
	var strength := 1.0


var api
var audio
var bolts: Array[Bolt] = []
var external_offset := Vector3.ZERO
var external_turn := Vector3.ZERO

var _mesh := ImmediateMesh.new()
var _node := MeshInstance3D.new()
var _material := ShaderMaterial.new()
var _lights: Array[OmniLight3D] = []
var _pending_thunder: Array[PendingThunder] = []
var _rng := RandomNumberGenerator.new()

var _raw_flash := 0.0
var _restrike_t := -1.0
var _restrike_amp := 0.0
var _next_strike := 4.0
var _rumble := 0.0
var _rumble_time := 0.0
var _rumble_active := false

## The strike list: entries sorted by `at` (the game tick each fires on, cue + offset), each
## {at, index, x, y, kind, strength, seed}. Empty: no list, the random storm.
var strikes: Array = []
## The file the list came from ("" none), and why it didn't load ("" it did, or none asked for).
var strikes_path := ""
var strikes_error := ""
## The cue tick the list counts from (-1 until known), and what the list fired (index -> times; tests).
var strikes_cue := -1
var strikes_fired: Array = []
var _strike_next := -1  # the next entry to fire; -1: not placed yet (waiting for a game tick)
var _strike_last_tick := -1
var _strikes_offsets: Array = []  # the entries as read: offsets from the cue, before a cue is known
var _strikes_file_cue := -1
## (1.92) No cue yet: wait for one rather than count from the first tick (a weather timeline is loaded).
var wait_for_cue := false


func setup(a, audio_ctrl) -> void:
	api = a
	audio = audio_ctrl
	_rng.randomize()
	var base_dir := str(api.dir) if api != null and str(api.dir) != "" else (get_script() as Script).resource_path.get_base_dir().get_base_dir()
	var bolt_shader := load(base_dir.path_join("shaders/lightning_bolt.gdshader")) as Shader
	if bolt_shader != null:
		_material.shader = bolt_shader
	if _node.get_parent() == null:
		_node.name = "LightningBolts"
		_node.mesh = _mesh
		_node.material_override = _material
		_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_node.custom_aabb = AABB(Vector3(-1e5, -20.0, -1e5), Vector3(2e5, 220.0, 2e5))
		add_child(_node)
	if _lights.is_empty():
		for i in LIGHTS:
			var l := OmniLight3D.new()
			l.name = "LightningLight_%d" % i
			l.light_color = Color(0.68, 0.84, 1.0)
			l.omni_range = LIGHT_RANGE
			l.shadow_enabled = false
			l.visible = false
			add_child(l)
			_lights.append(l)


func _setting_bool(key: String, fallback: bool) -> bool:
	if api == null or api.settings == null:
		return fallback
	var v: Variant = api.settings.value(key)
	return fallback if v == null else bool(v)


func _setting_float(key: String, fallback: float) -> float:
	if api == null or api.settings == null:
		return fallback
	var v: Variant = api.settings.value(key)
	return fallback if v == null else float(v)


func current_flash() -> float:
	if not _setting_bool("lightning_enabled", true):
		return 0.0
	var bright := clampf(_setting_float("flash_brightness", 0.75), 0.0, 1.5)
	return clampf(_raw_flash * bright, 0.0, 2.0)


func pending_thunder_count() -> int:
	return _pending_thunder.size()


func active_light_count() -> int:
	var c := 0
	for l: OmniLight3D in _lights:
		if l.visible:
			c += 1
	return c


## A strike now: `kind` "bolt", "sheet" or "auto"; `at_offset` from the focus (tiles) or random;
## `strength` scales its flash and thunder; `at_tile` a map tile (x, y) instead of an offset, with
## thunder timed by the distance to the camera.
func trigger_strike(kind := "auto", at_offset := Vector2.INF, strength_k := 1.0, at_tile := Vector2.INF) -> Dictionary:
	if api == null or not api.in_game() or not _setting_bool("lightning_enabled", true):
		return {}
	var bolts_on := _setting_bool("lightning_bolts_enabled", true)
	var actual_kind := kind
	if actual_kind == "auto":
		actual_kind = "bolt" if (bolts_on and _rng.randf() < 0.58) else "sheet"
	elif actual_kind == "bolt" and not bolts_on:
		actual_kind = "sheet"

	var focus: Vector2 = api.world.focus()
	var offset := at_offset
	if at_tile.is_finite():
		offset = at_tile - focus
	elif not offset.is_finite():
		var ang := _rng.randf() * TAU
		var d_rand := _rng.randf_range(28.0, 88.0) if actual_kind == "bolt" else _rng.randf_range(45.0, 135.0)
		offset = Vector2(cos(ang) * d_rand, sin(ang) * d_rand)
	var dist := maxf(offset.length(), 1.0)
	var wx := focus.x + offset.x
	var wz := focus.y + offset.y
	var ground_y := float(api.terrain.height_at(wx, wz))
	var ground := Vector3(wx, ground_y, wz)
	if at_tile.is_finite():
		var eye := _camera_eye()
		if eye.is_finite():
			dist = maxf(eye.distance_to(ground), 1.0)
	var sk := clampf(strength_k, 0.0, 2.0)

	if actual_kind == "bolt":
		_spawn_bolt(ground)
		_raw_flash = maxf(_raw_flash, clampf(1.25 - dist / 140.0, 0.45, 1.35) * sk)
		_restrike_t = 0.14
		_restrike_amp = maxf(_restrike_amp, _raw_flash * 0.72)
	else:
		_raw_flash = maxf(_raw_flash, clampf(1.05 - dist / 180.0, 0.35, 1.0) * sk)
		_restrike_t = 0.12
		_restrike_amp = maxf(_restrike_amp, _raw_flash * 0.55)

	var delay := clampf(dist / 32.0, 0.15, 5.5)
	var strength := clampf(1.15 - dist / 160.0, 0.35, 1.15) * sk
	var pt := PendingThunder.new()
	pt.delay = delay
	pt.distance = dist
	pt.strength = strength
	_pending_thunder.append(pt)

	return {
		"kind": actual_kind,
		"pos": ground,
		"distance": dist,
		"thunder_delay": delay,
		"bolts": bolts.size(),
	}


func _camera_eye() -> Vector3:
	var vp := get_viewport() if is_inside_tree() else null
	var cam := vp.get_camera_3d() if vp != null else null
	return cam.global_position if cam != null else Vector3.INF


# --- The strike list ---------------------------------------------------------------------------

## The list's file from the command line (`--weather-strikes=<file>`), else `setting` (the Strike
## list setting); "" none.
static func strikes_arg(args: PackedStringArray, setting: String) -> String:
	for a: String in args:
		if a.begins_with("--weather-strikes="):
			return a.substr(18).strip_edges()
	return setting.strip_edges()


## Loads the strike list from `path` (relative paths from the add-on's folder); "" unloads it (the
## random storm again). Returns why it didn't load, "" when it did (or when unloading).
func load_strikes(path: String) -> String:
	clear_strikes()
	strikes_path = path
	if path == "":
		return ""
	var full := path
	if path.is_relative_path() and not path.begins_with("res://") and not path.begins_with("user://") and api != null:
		full = str(api.dir).path_join(path)
	var text := FileAccess.get_file_as_string(full)
	if text == "":
		strikes_error = "can't read the strike list %s" % full
		return strikes_error
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		strikes_error = "the strike list %s isn't JSON" % full
		return strikes_error
	return set_strikes(parsed)


## The list itself: an Array of entries, or {"cue_tick": n (optional, when Zenith has no
## --cue-tick), "strikes": [...]}. Each entry: {"tick": ticks after the cue, "x", "y": the map tile,
## "kind": "bolt" or "sheet" (default bolt), "strength": 0-2 (default 1), "seed": a number (default
## its place in the list)}. Entries without a tick or place are left out (the log says how many).
func set_strikes(data: Variant) -> String:
	clear_strikes()
	var list: Variant = data
	if data is Dictionary:
		list = data.get("strikes", [])
		var c: Variant = data.get("cue_tick")
		_strikes_file_cue = int(c) if (c is float or c is int) and int(c) >= 0 else -1
	if not list is Array:
		strikes_error = "the strike list has no list of strikes"
		return strikes_error
	var bad := 0
	var i := -1
	for e: Variant in list:
		i += 1
		if not e is Dictionary or not _num(e.get("tick")) or not _num(e.get("x")) or not _num(e.get("y")):
			bad += 1
			continue
		var kind := str(e.get("kind", "bolt"))
		if kind != "bolt" and kind != "sheet":
			kind = "bolt"
		_strikes_offsets.append({"offset": int(e["tick"]), "index": i, "x": float(e["x"]), "y": float(e["y"]), "kind": kind,
			"strength": clampf(float(e["strength"]), 0.0, 2.0) if _num(e.get("strength")) else 1.0,
			"seed": int(e["seed"]) if _num(e.get("seed")) else i})
	if _strikes_offsets.is_empty():
		strikes_error = "the strike list has no strikes (%d without a tick, x and y)" % bad
		return strikes_error
	if bad > 0 and api != null:
		api.note("strike list: %d entries without a tick, x and y left out" % bad)
	return ""


static func _num(v: Variant) -> bool:
	return v is float or v is int


## A list is loaded: random strikes are off.
func has_strikes() -> bool:
	return not _strikes_offsets.is_empty()


func clear_strikes() -> void:
	strikes.clear()
	_strikes_offsets.clear()
	strikes_fired.clear()
	strikes_error = ""
	strikes_cue = -1
	_strikes_file_cue = -1
	_strike_next = -1
	_strike_last_tick = -1


## Fires the listed strikes the game tick `tick` has reached. The first tick seen places the list
## (entries already past are skipped); a tick going back (a save loaded again for another take)
## places it again from there.
func run_strikes(tick: int) -> void:
	if _strikes_offsets.is_empty() or tick < 0:
		return
	var cue := int(api.world.cue_tick()) if api != null and api.world.has_method("cue_tick") else -1
	if cue < 0:
		cue = _strikes_file_cue
	if wait_for_cue and cue < 0:
		if strikes_cue >= 0:
			strikes_cue = -1
			strikes.clear()
			strikes_fired.clear()
			_strike_next = -1
		return  # a weather timeline is loaded: the strikes wait for the scene's cue too
	# (API 1.92) A cue the game sets while running places the list again from it.
	if strikes_cue < 0 or (cue >= 0 and cue != strikes_cue):
		if cue < 0:
			cue = tick  # no cue given: the list counts from when it first sees the game
			if api != null:
				api.note("strike list: no --cue-tick, counting from tick %d" % tick)
		strikes_cue = cue
		_strike_next = -1
		strikes.clear()
		for o: Dictionary in _strikes_offsets:
			var e := o.duplicate()
			e["at"] = cue + int(o["offset"])
			strikes.append(e)
		var by_at := func(a: Dictionary, b: Dictionary) -> bool:
			return int(a["at"]) < int(b["at"]) or (int(a["at"]) == int(b["at"]) and int(a["index"]) < int(b["index"]))
		strikes.sort_custom(by_at)
	if _strike_next < 0 or tick < _strike_last_tick:
		_strike_next = 0
		while _strike_next < strikes.size() and int(strikes[_strike_next]["at"]) < tick:
			_strike_next += 1
	_strike_last_tick = tick
	while _strike_next < strikes.size() and int(strikes[_strike_next]["at"]) <= tick:
		var e: Dictionary = strikes[_strike_next]
		_strike_next += 1
		if tick - int(e["at"]) > LATE_TICKS:
			continue
		fire_listed(e)


## One listed strike, its bolt's shape seeded from the entry: the same every run.
func fire_listed(e: Dictionary) -> Dictionary:
	_rng.seed = hash([int(e.get("seed", 0)), "immersive-weather-strike"])
	var res := trigger_strike(str(e.get("kind", "bolt")), Vector2.INF, float(e.get("strength", 1.0)), Vector2(float(e["x"]), float(e["y"])))
	strikes_fired.append(int(e.get("index", -1)))
	return res


func _spawn_bolt(ground: Vector3) -> void:
	if bolts.size() >= MAX_BOLTS:
		var dropped: Bolt = bolts.pop_front()
		if dropped.light != null:
			dropped.light.visible = false
	var b := Bolt.new()
	b.phase = _rng.randf() * 100.0
	b.ground = ground
	var h := _rng.randf_range(HEIGHT_MIN, HEIGHT_MAX)
	var top := ground + Vector3(_rng.randf_range(-8.0, 8.0), h, _rng.randf_range(-6.0, 6.0))
	var main := _jagged(top, ground, DETAIL)
	b.paths.append(main)
	var forks_n := _rng.randi_range(FORKS.x, FORKS.y)
	for _f in forks_n:
		var from_idx := _rng.randi_range(maxi(1, int(main.size() * 0.18)), maxi(1, int(main.size() * 0.62)))
		var start: Vector3 = main[mini(from_idx, main.size() - 1)]
		var left_h := maxf(start.y - ground.y, 12.0)
		var dir := Vector3(_rng.randf_range(-1.0, 1.0), -1.25, _rng.randf_range(-1.0, 1.0)).normalized()
		b.paths.append(_jagged(start, start + dir * left_h * FORK_LENGTH * _rng.randf_range(0.65, 1.35), DETAIL - 2))
	for l: OmniLight3D in _lights:
		if not l.visible:
			b.light = l
			l.position = ground + Vector3(0.0, 4.0, 0.0)
			l.light_energy = 0.0
			l.visible = true
			break
	bolts.append(b)


func _jagged(a: Vector3, b: Vector3, levels: int) -> PackedVector3Array:
	var pts := PackedVector3Array([a, b])
	for _level in levels:
		var out := PackedVector3Array()
		for i in pts.size() - 1:
			var p: Vector3 = pts[i]
			var q: Vector3 = pts[i + 1]
			var reach := p.distance_to(q) * JITTER
			out.append(p)
			out.append((p + q) * 0.5 + Vector3(
				_rng.randf_range(-reach, reach),
				_rng.randf_range(-reach, reach) * 0.28,
				_rng.randf_range(-reach, reach)
			))
		out.append(pts[pts.size() - 1])
		pts = out
	return pts


static func bolt_strength(age: float, phase: float) -> float:
	if age >= LIFE:
		return 0.0
	var t := age / LIFE
	var flicker := 0.55 + 0.45 * sin(age * 72.0 + phase) * sin(age * 31.0 + phase * 2.0)
	return clampf((1.0 - t * t) * flicker, 0.0, 1.0)


func update(delta: float, active_on_nauvis: bool, spec: Dictionary) -> float:
	if not active_on_nauvis:
		var has_ext := (
			external_offset.length_squared() > 1e-10
			or external_turn.length_squared() > 1e-10
		)
		if (
			not bolts.is_empty()
			or not _pending_thunder.is_empty()
			or _raw_flash > 0.0
			or _rumble_active
			or has_ext
		):
			clear()
		return 0.0

	if api.view != null and bool(api.view.screenshot_busy()):
		_redraw_bolts()
		return current_flash()

	var dt := maxf(delta, 0.0)
	_raw_flash = maxf(0.0, _raw_flash * exp(-dt * 7.2) - dt * 0.25)
	if _restrike_t >= 0.0:
		_restrike_t -= dt
		if _restrike_t <= 0.0:
			_raw_flash = maxf(_raw_flash, _restrike_amp)
			_restrike_t = -1.0
			_restrike_amp = 0.0

	_advance_bolts(dt)
	_redraw_bolts()
	_advance_thunder(dt)
	_update_rumble(dt)

	var lightning_on := _setting_bool("lightning_enabled", true)
	var rate := clampf(float(spec.get("lightning_rate", 0.0)), 0.0, 2.0)
	var freq := clampf(_setting_float("lightning_frequency", 1.0), 0.1, 3.0)
	if has_strikes():
		# The list times every strike (on the game's tick, whatever the weather); no random ones.
		if api.world.has_method("tick"):
			run_strikes(int(api.world.tick()))
	elif lightning_on and rate > 0.02:
		var mult := maxf(rate * freq, 0.05)
		_next_strike -= dt * mult
		if _next_strike <= 0.0:
			trigger_strike("auto")
			_next_strike = _rng.randf_range(6.0, 14.0)
	else:
		_next_strike = minf(_next_strike, 3.5)

	return current_flash()


func _advance_bolts(dt: float) -> void:
	var kept: Array[Bolt] = []
	for b: Bolt in bolts:
		b.age += dt
		if b.age < LIFE:
			kept.append(b)
		elif b.light != null:
			b.light.visible = false
	bolts = kept
	var bright := _setting_float("flash_brightness", 0.75)
	var light_k := clampf(bright, 0.25, 1.5) if bright > 0.0 else 0.35
	for b: Bolt in bolts:
		var s := bolt_strength(b.age, b.phase)
		if b.light != null:
			b.light.light_energy = LIGHT_ENERGY * s * light_k


func _redraw_bolts() -> void:
	_mesh.clear_surfaces()
	if bolts.is_empty():
		return
	var vp := get_viewport() if is_inside_tree() else null
	var cam := vp.get_camera_3d() if vp != null else null
	var eye := cam.global_position if cam != null else Vector3(0.0, 80.0, 40.0)
	var bright := _setting_float("flash_brightness", 0.75)
	var vis_k := clampf(bright, 0.35, 1.4)
	var tris := 0
	for b: Bolt in bolts:
		var s := maxf(bolt_strength(b.age, b.phase), 0.01) * vis_k
		for i in b.paths.size():
			var thin := 1.0 if i == 0 else 0.52
			var path: PackedVector3Array = b.paths[i]
			for j in path.size() - 1:
				var p: Vector3 = path[j]
				var q: Vector3 = path[j + 1]
				if (q - p).cross(eye - (p + q) * 0.5).length_squared() >= 1e-8:
					if tris == 0:
						_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
					tris += 1
					_add_ribbon_seg(p, q, GLOW_WIDTH * thin, Color(GLOW_COLOR, clampf(0.38 * s * thin, 0.0, 1.0)), eye)
					_add_ribbon_seg(p, q, CORE_WIDTH * thin, Color(CORE_COLOR, clampf(s * thin, 0.0, 1.0)), eye)
	if tris > 0:
		_mesh.surface_end()


func _add_ribbon_seg(p: Vector3, q: Vector3, width: float, color: Color, eye: Vector3) -> void:
	var side := (q - p).cross(eye - (p + q) * 0.5).normalized() * (width * 0.5)
	_mesh.surface_set_color(color)
	_mesh.surface_set_uv(Vector2(0.0, 0.0))
	_mesh.surface_add_vertex(p - side)
	_mesh.surface_set_uv(Vector2(1.0, 0.0))
	_mesh.surface_add_vertex(p + side)
	_mesh.surface_set_uv(Vector2(1.0, 1.0))
	_mesh.surface_add_vertex(q + side)
	_mesh.surface_set_uv(Vector2(0.0, 0.0))
	_mesh.surface_add_vertex(p - side)
	_mesh.surface_set_uv(Vector2(1.0, 1.0))
	_mesh.surface_add_vertex(q + side)
	_mesh.surface_set_uv(Vector2(0.0, 1.0))
	_mesh.surface_add_vertex(q - side)


func _advance_thunder(dt: float) -> void:
	if _pending_thunder.is_empty():
		return
	var remain: Array[PendingThunder] = []
	var rumble_on := _setting_bool("camera_rumble_enabled", true)
	for pt: PendingThunder in _pending_thunder:
		pt.delay -= dt
		if pt.delay <= 0.0:
			if audio != null:
				audio.play_thunder(pt.distance, pt.strength)
			if rumble_on and pt.distance < 70.0:
				var r := clampf(1.0 - pt.distance / 70.0, 0.15, 1.0) * pt.strength
				_rumble = maxf(_rumble, r)
		else:
			remain.append(pt)
	_pending_thunder = remain


func _update_rumble(dt: float) -> void:
	var enabled := _setting_bool("camera_rumble_enabled", true)
	var strength := clampf(_setting_float("camera_rumble_strength", 0.45), 0.0, 1.5)
	var cam_mode := str(api.camera.mode()) if api.camera != null else ""
	var mode_ok := cam_mode in ["angled", "factorio", "first_person"]
	if not mode_ok:
		_rumble = 0.0
		if _rumble_active:
			api.camera.clear_modifier()
			_rumble_active = false
		return

	var off := Vector3.ZERO
	var turn := Vector3.ZERO
	if enabled and strength > 0.001 and _rumble > 0.005:
		_rumble = maxf(0.0, _rumble * exp(-dt * 2.8) - dt * 0.08)
		_rumble_time += dt
		var amp := _rumble * strength
		off = Vector3(
			sin(_rumble_time * 47.0) * 0.045 * amp,
			cos(_rumble_time * 39.0) * 0.045 * amp,
			0.0
		)
		turn = Vector3(
			sin(_rumble_time * 31.0) * 0.0028 * amp,
			cos(_rumble_time * 27.0) * 0.0020 * amp,
			sin(_rumble_time * 41.0) * 0.0030 * amp
		)
	else:
		_rumble = 0.0

	var total_off := off + external_offset
	var total_turn := turn + external_turn
	var any_active := total_off.length_squared() > 1e-10 or total_turn.length_squared() > 1e-10
	if any_active:
		api.camera.set_modifier(total_off, total_turn, 0.0)
		_rumble_active = true
	elif _rumble_active:
		api.camera.clear_modifier()
		_rumble_active = false


func clear() -> void:
	bolts.clear()
	_mesh.clear_surfaces()
	for l: OmniLight3D in _lights:
		l.visible = false
		l.light_energy = 0.0
	_pending_thunder.clear()
	_raw_flash = 0.0
	_restrike_t = -1.0
	_restrike_amp = 0.0
	_rumble = 0.0
	external_offset = Vector3.ZERO
	external_turn = Vector3.ZERO
	_next_strike = 4.0
	_strike_next = -1  # the list (kept) is placed again from the next tick seen
	if _rumble_active and api != null and api.get("camera") != null:
		api.camera.clear_modifier()
	_rumble_active = false
