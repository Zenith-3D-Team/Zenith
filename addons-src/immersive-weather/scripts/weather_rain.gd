extends Node3D
## 3D rain streaks and splashes for the Immersive Weather add-on.
##
## Drops: one MultiMesh of camera-facing quads, placed and moved wholly on the GPU
## (shaders/rain_drops.gdshader); this script only sets how many are drawn and a few uniforms.
## Splashes: a ring buffer of short-lived quads on the ground and on the roofs of buildings near
## the focus (shaders/rain_splashes.gdshader). Dry, or off: both are hidden, so they cost nothing.

const MAX_DROPS := 3200
const MAX_SPLASHES := 600
const BOX := Vector3(48.0, 26.0, 48.0)
const FAR_REF := 34.0                # camera-to-ground distance (tiles) up to which the box keeps its size
const FAR_MAX := 14.0                # the box grows at most this many times (zoomed far out)
const WIND_TO_TILES := 7.0           # spec wind (about 0..1.3) to tiles per second
const WIND_MAX := 14.0
const SPLASHES_PER_SEC := 1700.0     # at splash_rate 1 and splash_density 1 (about 30 a frame at 60 fps)
const SPLASH_RADIUS := 22.0
const ROOF_SHARE := 0.25
const ENTITY_REFRESH := 1.0
const CLOCK_WRAP := 1000.0
const SKIP_TYPES := ["resource", "decorative", "corpse"]

var api
var _drops: MultiMeshInstance3D
var _splashes: MultiMeshInstance3D
var _drop_mat: ShaderMaterial
var _splash_mat: ShaderMaterial
var _drop_mm: MultiMesh
var _splash_mm: MultiMesh

var _clock := 0.0
var _intensity := 0.0        # smoothed rain_intensity
var _wind := Vector2.ZERO    # smoothed wind in tiles/s
var _wind_offset := Vector2.ZERO
var _entity_cache: Array = []
var _entity_age := 999.0
var _spawn_accum := 0.0
var _spawn_head := 0
var _last_spawn := -999.0
var _ready_ok := false
var _far := 1.0              # how many times the rain box has grown for a far camera
var _far_on := not ("--weather-rain-zoom=old" in OS.get_cmdline_user_args())


func setup(a) -> void:
	api = a
	_clear_children()
	var drop_shader := load(str(api.dir).path_join("shaders/rain_drops.gdshader")) as Shader
	var splash_shader := load(str(api.dir).path_join("shaders/rain_splashes.gdshader")) as Shader
	if drop_shader == null or splash_shader == null:
		api.note("rain shaders can't be read: no 3D rain")
		return

	_drop_mat = ShaderMaterial.new()
	_drop_mat.shader = drop_shader
	_drop_mm = _make_multimesh(MAX_DROPS)
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	for i in MAX_DROPS:
		_drop_mm.set_instance_custom_data(i, Color(rng.randf(), rng.randf(), rng.randf(), rng.randf()))
	_drops = _make_instance("RainDrops", _drop_mm, _drop_mat, 64.0, AABB(Vector3(-40, -10, -40), Vector3(80, 44, 80)))
	add_child(_drops)

	_splash_mat = ShaderMaterial.new()
	_splash_mat.shader = splash_shader
	_splash_mm = _make_multimesh(MAX_SPLASHES)
	_splashes = _make_instance("RainSplashes", _splash_mm, _splash_mat, 48.0, AABB(Vector3(-32, -8, -32), Vector3(64, 24, 64)))
	add_child(_splashes)
	_drops.visible = false
	_splashes.visible = false
	_ready_ok = true


func _make_multimesh(count: int) -> MultiMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = count
	mm.visible_instance_count = 0
	return mm


func _make_instance(node_name: String, mm: MultiMesh, mat: ShaderMaterial, margin: float, box: AABB) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.extra_cull_margin = margin
	mmi.custom_aabb = box
	return mmi


func _clear_children() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_drops = null
	_splashes = null
	_ready_ok = false


func _setting(key: String, fallback: Variant) -> Variant:
	var v: Variant = api.settings.value(key)
	return fallback if v == null else v


func update(delta: float, active_on_nauvis: bool, spec: Dictionary) -> void:
	if not _ready_ok:
		return
	if not active_on_nauvis:
		# Another planet, a platform, no game: gone at once (the wetness is zeroed at once too).
		if _intensity > 0.0 or _drops.visible or _splashes.visible:
			clear()
		return
	if bool(api.view.screenshot_busy()):
		return
	var raining := active_on_nauvis and bool(_setting("rain_enabled", true))
	var target := clampf(float(spec.get("rain_intensity", 0.0)), 0.0, 1.0) if raining else 0.0
	# Ease the amount of rain in and out, so a change of weather fades instead of popping.
	_intensity = move_toward(_intensity, target, delta * 0.8)
	_clock = fposmod(_clock + delta, CLOCK_WRAP)

	var wind_target := Vector2.ZERO
	var w: Variant = spec.get("wind", Vector2.ZERO)
	if w is Vector2:
		wind_target = (w as Vector2) * WIND_TO_TILES
	if wind_target.length() > WIND_MAX:
		wind_target = wind_target.normalized() * WIND_MAX
	_wind = _wind.lerp(wind_target, clampf(delta * 1.5, 0.0, 1.0))
	_wind_offset = Vector2(fposmod(_wind_offset.x + _wind.x * delta, BOX.x), fposmod(_wind_offset.y + _wind.y * delta, BOX.z))

	var focus: Vector2 = api.world.focus()
	var ground := float(api.terrain.height_at(focus.x, focus.y))
	var center := Vector3(focus.x, ground, focus.y)
	# Zoomed out, a 48-tile box round the focus is a dot on screen: grow the box with the camera's
	# distance and centre it where the camera looks at the ground, so the rain fills the view.
	_far = 1.0
	var cam: Camera3D = get_viewport().get_camera_3d() if _far_on else null
	if cam != null:
		var o := cam.global_position
		var d := -cam.global_basis.z
		if d.y < -0.05:
			var t := clampf((ground - o.y) / d.y, 0.0, 2000.0)
			if t > FAR_REF:
				_far = minf(t / FAR_REF, FAR_MAX)
				var hit := o + d * t
				center = center.lerp(Vector3(hit.x, ground, hit.z), smoothstep(FAR_REF, FAR_REF * 1.5, t))
	_drops.global_position = center
	var half := 40.0 * _far
	_drops.custom_aabb = AABB(Vector3(-half, -10, -half), Vector3(half * 2.0, 18.0 + BOX.y * minf(_far, 4.0), half * 2.0))
	_splashes.custom_aabb = AABB(center + Vector3(-32, -8, -32), Vector3(64, 24, 64))

	var day := 1.0 - clampf(float(api.world.darkness()) / 0.85, 0.0, 1.0)
	_update_drops(center, ground, day)
	_update_splashes(delta, active_on_nauvis, spec, focus, ground, day)


func _update_drops(center: Vector3, ground: float, day: float) -> void:
	var density := clampf(float(_setting("rain_density", 1.0)), 0.25, 2.0)
	var count := int(MAX_DROPS * clampf(_intensity * density * 0.8, 0.0, 1.0))
	if _intensity <= 0.002 or count <= 0:
		_drop_mm.visible_instance_count = 0
		_drops.visible = false
		return
	_drops.visible = true
	_drop_mm.visible_instance_count = count
	_drop_mat.set_shader_parameter("volume_center", center)
	_drop_mat.set_shader_parameter("box_size", Vector3(BOX.x * _far, BOX.y * minf(_far, 4.0), BOX.z * _far))
	_drop_mat.set_shader_parameter("far_scale", _far)
	_drop_mat.set_shader_parameter("wind", _wind)
	_drop_mat.set_shader_parameter("wind_offset", _wind_offset)
	_drop_mat.set_shader_parameter("ground_y", ground)
	_drop_mat.set_shader_parameter("visibility", clampf(float(_setting("rain_visibility", 1.0)), 0.25, 2.0))
	_drop_mat.set_shader_parameter("intensity", _intensity)
	_drop_mat.set_shader_parameter("day_factor", day)


func _update_splashes(delta: float, active_on_nauvis: bool, spec: Dictionary, focus: Vector2, ground: float, day: float) -> void:
	var on := active_on_nauvis and bool(_setting("rain_enabled", true)) and bool(_setting("splashes_enabled", true))
	var rate := clampf(float(spec.get("splash_rate", 0.0)), 0.0, 1.0) * _intensity if on else 0.0
	var density := clampf(float(_setting("splash_density", 1.0)), 0.25, 2.0)
	if rate > 0.01:
		_entity_age += delta
		if _entity_age >= ENTITY_REFRESH:
			_entity_age = 0.0
			_refresh_entities(focus)
		_spawn_accum += SPLASHES_PER_SEC * rate * density * delta
		var n := mini(int(_spawn_accum), 90)
		_spawn_accum = minf(_spawn_accum - float(int(_spawn_accum)), 1.0)
		for i in n:
			_spawn_one(focus)
		if n > 0:
			_last_spawn = _clock
	else:
		_spawn_accum = 0.0
	# Keep drawing until the last splash has died (life is under 0.5 s), then hide.
	var since := fposmod(_clock - _last_spawn + CLOCK_WRAP, CLOCK_WRAP)
	if since > 0.6:
		_splash_mm.visible_instance_count = 0
		_splashes.visible = false
		return
	_splashes.visible = true
	_splash_mm.visible_instance_count = MAX_SPLASHES
	_splash_mat.set_shader_parameter("now", _clock)
	_splash_mat.set_shader_parameter("visibility", clampf(float(_setting("rain_visibility", 1.0)), 0.25, 2.0))
	_splash_mat.set_shader_parameter("day_factor", day)


func _refresh_entities(focus: Vector2) -> void:
	_entity_cache.clear()
	for e in api.world.entities_near(focus, SPLASH_RADIUS):
		var t := str(e["type"])
		if t in SKIP_TYPES:
			continue
		_entity_cache.append(e)


func _roof_height(type: String) -> float:
	match type:
		"rocket-silo", "lab", "roboport", "radar":
			return 2.4
		"assembling-machine", "furnace", "boiler", "generator", "chemical-plant", "oil-refinery":
			return 1.7
		"container", "wall", "ammo-turret", "electric-turret", "fluid-turret":
			return 1.0
		"transport-belt", "splitter", "underground-belt", "pipe":
			return 0.35
	return 1.4


func _spawn_one(focus: Vector2) -> void:
	var x := 0.0
	var z := 0.0
	var y := 0.0
	if not _entity_cache.is_empty() and randf() < ROOF_SHARE:
		var e: Dictionary = _entity_cache[randi() % _entity_cache.size()]
		var p: Vector2 = e["position"]
		x = p.x + randf_range(-0.8, 0.8)
		z = p.y + randf_range(-0.8, 0.8)
		y = float(api.terrain.height_at(x, z)) + _roof_height(str(e["type"]))
	else:
		var ang := randf() * TAU
		var r := SPLASH_RADIUS * sqrt(randf())
		x = focus.x + cos(ang) * r
		z = focus.y + sin(ang) * r
		y = float(api.terrain.height_at(x, z)) + float(api.world.stand_height_at(Vector2(x, z))) + 0.03
	var i := _spawn_head
	_spawn_head = (_spawn_head + 1) % MAX_SPLASHES
	# The splash node stays at its own origin (its bounds follow the focus), so these are world positions.
	_splash_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(x, y, z) - _splashes.global_position))
	_splash_mm.set_instance_custom_data(i, Color(_clock, randf_range(0.28, 0.42), randf_range(0.16, 0.28), randf()))


func clear() -> void:
	_intensity = 0.0
	_spawn_accum = 0.0
	_last_spawn = -999.0
	_entity_cache.clear()
	_entity_age = 999.0
	if _drops != null:
		_drop_mm.visible_instance_count = 0
		_drops.visible = false
	if _splashes != null:
		_splash_mm.visible_instance_count = 0
		_splashes.visible = false
