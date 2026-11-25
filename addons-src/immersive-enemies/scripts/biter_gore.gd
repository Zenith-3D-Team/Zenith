extends RefCounted
## Pooled blood droplets, ground splatter/smear decals, burning corpse flames/ash, and bouncing
## sculpted 3D gib chunks (Phase 2) for the Immersive Enemies add-on (biters, spitters, worms, and nests).
##
## All visuals use five pooled MultiMeshInstance3D nodes mounted under the add-on's world root
## (zero per-particle nodes):
##   1. Ballistic purple-violet ichor droplets (plus buoyant burning-corpse flames/smoke/ash).
##   2. Ground splatter & ragdoll-bounce smear decals aligned to terrain normals.
##   3. Sculpted curved jagged chitin armor shards (closed manifold procedural ArrayMesh).
##   4. Sculpted lumpy glossy organic meat/flesh chunks with vertex-baked crevice AO.
##   5. Sculpted curved tapered horn/fang/claw splinters with bloody root-to-bone gradient.

const MAX_DROPLETS := 512
const MAX_DECALS := 600
const MAX_GIBS := 192

const GIB_CHITIN := 0
const GIB_MEAT := 1
const GIB_SPIKE := 2

const GRAVITY := -16.5
const DROPLET_LIFE := 1.4
const DECAL_LIFE := 35.0
const DECAL_FADE := 4.0
const GIB_LIFE := 12.0
const GIB_FADE := 2.0

const TIER_SCALE := {
	"small-biter": 0.75,
	"medium-biter": 1.0,
	"big-biter": 1.35,
	"behemoth-biter": 1.75,
	"small-spitter": 0.72,
	"medium-spitter": 0.96,
	"big-spitter": 1.30,
	"behemoth-spitter": 1.68,
	"small-worm-turret": 0.95,
	"medium-worm-turret": 1.25,
	"big-worm-turret": 1.55,
	"behemoth-worm-turret": 1.90,
	"biter-spawner": 2.1,
	"spitter-spawner": 2.1,
}
const TIER_CHITIN := {
	"small-biter": Color(0.28, 0.22, 0.18),
	"medium-biter": Color(0.24, 0.16, 0.20),
	"big-biter": Color(0.16, 0.20, 0.28),
	"behemoth-biter": Color(0.15, 0.26, 0.16),
	"small-spitter": Color(0.32, 0.25, 0.14),
	"medium-spitter": Color(0.30, 0.19, 0.21),
	"big-spitter": Color(0.16, 0.22, 0.26),
	"behemoth-spitter": Color(0.18, 0.26, 0.12),
	"small-worm-turret": Color(0.30, 0.21, 0.15),
	"medium-worm-turret": Color(0.32, 0.17, 0.14),
	"big-worm-turret": Color(0.28, 0.20, 0.18),
	"behemoth-worm-turret": Color(0.27, 0.21, 0.13),
	"biter-spawner": Color(0.34, 0.22, 0.20),
	"spitter-spawner": Color(0.38, 0.22, 0.24),
}
const GORE_MULT := {
	"low": 0.45,
	"standard": 1.0,
	"high": 1.75,
}

var api
var _container: Node3D
var _rng := RandomNumberGenerator.new()

var gore_enabled := true
var gibs_enabled := true
var gore_level := "standard"
var blood_amount := 1.0

var _droplets_mmi: MultiMeshInstance3D
var _droplets_mm: MultiMesh
var _droplets: Array = []

var _decals_mmi: MultiMeshInstance3D
var _decals_mm: MultiMesh
var _decals: Array = []
var _decal_head := 0
var _decal_active := 0

var _gibs_chitin_mmi: MultiMeshInstance3D
var _gibs_chitin_mm: MultiMesh
var _gibs_meat_mmi: MultiMeshInstance3D
var _gibs_meat_mm: MultiMesh
var _gibs_spike_mmi: MultiMeshInstance3D
var _gibs_spike_mm: MultiMesh
var _gibs: Array = []

## False = the GDScript loops (main.gd sets it from the add-on setting and --enemies-native=off).
var use_native := true
## (0.1.2) Native decals: set_decal() marks the buffer dirty and step() uploads it once a frame
## (before, every decal re-sent all 600 slots). false = upload per decal (--enemies-burst=old).
var batch_decals := true
var _decals_dirty := false
var _nat: Object = null
var _nat_tried := false


func _init(a, root: Node3D) -> void:
	api = a
	_rng.randomize()
	_container = Node3D.new()
	_container.name = "BiterGore"
	root.add_child(_container)
	_build_pools()


## Test hook: hand in a BiterGoreNative (or null) instead of asking the add-on API.
func set_native(obj: Object) -> void:
	_nat_tried = true
	_nat = obj
	if _nat != null:
		_nat.call("setup", MAX_DROPLETS, MAX_DECALS, MAX_GIBS)


func _native() -> Object:
	if not use_native:
		return null
	if not _nat_tried:
		_nat_tried = true
		if api != null and api.has_method("native_class"):
			var obj: Variant = api.native_class("BiterGoreNative")
			if obj is Object:
				_nat = obj
				_nat.call("setup", MAX_DROPLETS, MAX_DECALS, MAX_GIBS)
	return _nat


## One droplet into whichever store is live (the oldest goes when full).
func _emit_droplet(d: Dictionary) -> void:
	var nat: Object = _native()
	if nat != null:
		nat.call("add_droplet", d["pos"], d["vel"], float(d["size"]), float(d.get("life", DROPLET_LIFE)), d["color"],
			float(d["decal_chance"]), float(d.get("gravity", GRAVITY)), float(d.get("drag", 0.0)), bool(d.get("fade_shrink", false)))
		return
	if _droplets.size() >= MAX_DROPLETS:
		_droplets.pop_front()
	_droplets.append(d)


func _is_supported(proto: String) -> bool:
	return (
		proto.ends_with("-biter")
		or proto.ends_with("-spitter")
		or proto.ends_with("-worm-turret")
		or proto == "biter-spawner"
		or proto == "spitter-spawner"
	)


func _is_spawner(proto: String) -> bool:
	return proto == "biter-spawner" or proto == "spitter-spawner"


func on_damaged(info: Dictionary) -> void:
	if not gore_enabled or blood_amount <= 0.001 or api == null:
		return
	var proto: String = str(info.get("name", ""))
	if not _is_supported(proto):
		return
	var pos: Vector3 = info.get("pos", Vector3.ZERO) as Vector3
	var cause_pos: Variant = info.get("cause_pos", null)
	var damage_type: String = str(info.get("damage_type", "physical")).to_lower()
	var dmg: int = int(info.get("dmg", 0))
	var src: String = str(info.get("src", "")).to_lower()
	var t_scale: float = float(TIER_SCALE.get(proto, 1.0))
	var mult: float = float(GORE_MULT.get(gore_level, 1.0)) * blood_amount

	var dir: Vector3 = _away_dir(pos, cause_pos)
	var base_count: float = 5.0
	if damage_type == "explosion" or damage_type == "impact" or dmg >= 450 or src.contains("shotgun") or src.contains("grenade"):
		base_count = 9.0
	elif dmg >= 200:
		base_count = 7.0
	elif damage_type == "fire" or damage_type == "poison" or damage_type == "acid":
		base_count = 3.0
	var count: int = maxi(1, int(roundf(base_count * mult)))
	var gh: float = float(api.creatures.ground_height(pos.x, pos.z))
	var origin: Vector3 = Vector3(pos.x, maxf(pos.y, gh) + 0.40 * t_scale, pos.z)
	_spawn_droplet_burst(origin, dir, count, 3.2, 6.8, t_scale, 0.65)


func on_died(info: Dictionary) -> void:
	if not gore_enabled or api == null:
		return
	var proto: String = str(info.get("name", ""))
	if not _is_supported(proto):
		return
	var pos: Vector3 = info.get("pos", Vector3.ZERO) as Vector3
	var cause_pos: Variant = info.get("cause_pos", null)
	var damage_type: String = str(info.get("damage_type", "physical")).to_lower()
	var dmg: int = int(info.get("dmg", 0))
	var src: String = str(info.get("src", "")).to_lower()
	var t_scale: float = float(TIER_SCALE.get(proto, 1.0))
	var mult: float = float(GORE_MULT.get(gore_level, 1.0))
	var b_mult: float = mult * blood_amount

	var is_explosive_src: bool = (
		damage_type == "explosion"
		or src.contains("grenade")
		or src.contains("rocket")
		or src.contains("artillery")
		or src.contains("cannon")
	)
	var is_non_dismember: bool = (
		damage_type == "fire"
		or damage_type == "poison"
		or damage_type == "acid"
		or damage_type == "laser"
		or damage_type == "electric"
	)
	var is_spawner: bool = _is_spawner(proto)
	var is_split: bool = is_explosive_src or (not is_non_dismember and dmg >= 850)
	var is_heavy: bool = not is_non_dismember and (damage_type == "impact" or dmg >= 450 or src.contains("shotgun"))

	# A deep burst queue (main.gd) asks for lighter gore: half the droplets and gibs.
	var lite_mul: float = 0.5 if bool(info.get("lite", false)) else 1.0
	var dir: Vector3 = _away_dir(pos, cause_pos)
	var base_drops: float = 14.0
	var speed_hi: float = 8.5
	var splat_mul: float = 0.75
	if is_spawner:
		base_drops = 34.0 if is_split else 28.0
		speed_hi = 12.2
		splat_mul = 1.10
	elif is_split:
		base_drops = 26.0
		speed_hi = 11.8
		splat_mul = 0.95
	elif is_heavy:
		base_drops = 20.0
		speed_hi = 10.5
		splat_mul = 0.85
	elif damage_type == "fire" or damage_type == "poison" or damage_type == "acid":
		base_drops = 8.0
		speed_hi = 4.5
		splat_mul = 0.65
	elif damage_type == "laser" or damage_type == "electric":
		base_drops = 11.0
		speed_hi = 6.5
		splat_mul = 0.70
	elif dmg >= 200:
		base_drops = 16.0
		speed_hi = 9.2

	var gh: float = float(api.creatures.ground_height(pos.x, pos.z))
	var origin: Vector3 = Vector3(pos.x, maxf(pos.y, gh) + 0.45 * t_scale, pos.z)
	if blood_amount > 0.001:
		var count: int = maxi(1, int(roundf(base_drops * b_mult * lite_mul)))
		var spread: float = 1.45 if is_spawner else (0.95 if is_split else 0.85)
		_spawn_droplet_burst(origin, dir, count, 3.0, speed_hi, t_scale, spread)

		# Immediate ground splatter under the kill point (plus radial splatters on nests and explosive splits).
		var decal_scale: float = clampf(0.5 + 0.5 * blood_amount, 0.4, 1.5)
		_add_decal(Vector3(pos.x, gh, pos.z), splat_mul * t_scale * decal_scale, 1.0 + _rng.randf_range(0.0, 0.45), _rng.randf_range(0.0, TAU), _ichor_color(0.85))
		if is_spawner:
			var radial_n: int = _rng.randi_range(3, 4)
			for si in radial_n:
				var sa: float = (TAU * float(si) / float(radial_n)) + _rng.randf_range(-0.35, 0.35)
				var sr: float = _rng.randf_range(0.65, 1.55) * clampf(t_scale, 1.0, 2.2)
				var sx: float = pos.x + cos(sa) * sr
				var sz: float = pos.z + sin(sa) * sr
				var sgh: float = float(api.creatures.ground_height(sx, sz))
				_add_decal(Vector3(sx, sgh, sz), _rng.randf_range(0.55, 0.88) * t_scale * decal_scale, 1.2 + _rng.randf_range(0.0, 0.6), sa, _ichor_color(0.84))
		elif is_split:
			for _si in 2:
				var sa: float = _rng.randf_range(0.0, TAU)
				var sr: float = _rng.randf_range(0.35, 0.95) * t_scale
				var sx: float = pos.x + cos(sa) * sr
				var sz: float = pos.z + sin(sa) * sr
				var sgh: float = float(api.creatures.ground_height(sx, sz))
				_add_decal(Vector3(sx, sgh, sz), _rng.randf_range(0.45, 0.72) * t_scale * decal_scale, 1.2 + _rng.randf_range(0.0, 0.6), sa, _ichor_color(0.82))

	# Explosive / overkill / heavy / spawner gib shards.
	if gibs_enabled and (is_split or is_heavy or is_spawner):
		var base_gibs: float = (14.0 + 3.0 * t_scale) if is_spawner else ((9.0 + 3.0 * t_scale) if is_split else (6.0 + 2.5 * t_scale))
		var gib_count: int = maxi(2, int(roundf(base_gibs * mult * lite_mul)))
		var chitin: Color = TIER_CHITIN.get(proto, Color(0.22, 0.17, 0.16)) as Color
		_spawn_gibs(origin, dir, gib_count, t_scale, chitin, is_split or is_spawner)


func spawn_smear(pos: Vector3, impact_speed: float, scale: float) -> void:
	if not gore_enabled or blood_amount <= 0.001 or api == null:
		return
	var strength: float = clampf(impact_speed / 8.0, 0.35, 1.4)
	var size: float = (0.45 + 0.35 * strength) * clampf(scale, 0.65, 1.8) * clampf(0.5 + 0.5 * blood_amount, 0.4, 1.5)
	var stretch: float = 1.4 + strength * 0.9
	var yaw: float = _rng.randf_range(0.0, TAU)
	_add_decal(pos, size, stretch, yaw, _ichor_color(0.75))


func spawn_decay_dust(pos: Vector3, scale: float) -> void:
	if not gore_enabled or api == null or _droplets_mmi == null:
		return
	var mult: float = float(GORE_MULT.get(gore_level, 1.0))
	var count: int = maxi(1, int(roundf(2.0 * mult)))
	var rad: float = 0.28 * clampf(scale, 0.5, 1.8)
	for _i in count:
		var a: float = _rng.randf_range(0.0, TAU)
		var r: float = _rng.randf_range(0.0, rad)
		var origin := pos + Vector3(cos(a) * r, _rng.randf_range(0.04, 0.20), sin(a) * r)
		var vel := Vector3(_rng.randf_range(-0.35, 0.35), _rng.randf_range(0.28, 0.72), _rng.randf_range(-0.35, 0.35))
		var shade: float = _rng.randf_range(0.11, 0.21)
		_emit_droplet({
			"pos": origin,
			"vel": vel,
			"size": _rng.randf_range(0.45, 0.9) * clampf(scale, 0.6, 1.4),
			"age": 0.0,
			"color": Color(shade * 1.15, shade * 0.92, shade * 0.78, 0.72),
			"decal_chance": 0.0,
			"gravity": -0.6,
			"drag": 1.6,
		})
	_droplets_mmi.visible = true


func spawn_burn_flame(pos: Vector3, scale: float, ash_phase: float) -> void:
	if api == null or _droplets_mmi == null:
		return
	var s: float = clampf(scale, 0.45, 1.8)
	var rad: float = 0.34 * s
	var gh: float = float(api.creatures.ground_height(pos.x, pos.z))
	var base_pos := Vector3(pos.x, maxf(pos.y, gh + 0.04), pos.z)
	var emitted := false

	if ash_phase < 0.75:
		var flame_count: int = _rng.randi_range(2, 3)
		for fi in flame_count:
			var a: float = _rng.randf_range(0.0, TAU)
			var r: float = _rng.randf_range(0.0, rad)
			var origin: Vector3 = base_pos + Vector3(cos(a) * r, _rng.randf_range(0.02, 0.22 * s), sin(a) * r)
			var vel := Vector3(
				_rng.randf_range(-0.55, 0.55),
				_rng.randf_range(0.8, 2.0),
				_rng.randf_range(-0.55, 0.55)
			)
			var col: Color
			if (fi % 2) == 0:
				col = Color(1.0, _rng.randf_range(0.45, 0.72), 0.06, 1.0)
			else:
				col = Color(0.95, 0.22, 0.03, 1.0)
			_emit_droplet({
				"pos": origin,
				"vel": vel,
				"size": _rng.randf_range(0.65, 1.30) * clampf(s, 0.65, 1.5),
				"age": 0.0,
				"life": _rng.randf_range(0.42, 0.75),
				"color": col,
				"decal_chance": 0.0,
				"gravity": 2.8,
				"drag": 2.0,
				"fade_shrink": true,
			})
			emitted = true

		# 1 dark charcoal smoke puff rising above the flames.
		var sa: float = _rng.randf_range(0.0, TAU)
		var sr: float = _rng.randf_range(0.0, rad * 0.85)
		_emit_droplet({
			"pos": base_pos + Vector3(cos(sa) * sr, _rng.randf_range(0.14, 0.34 * s), sin(sa) * sr),
			"vel": Vector3(_rng.randf_range(-0.35, 0.35), _rng.randf_range(0.55, 1.25), _rng.randf_range(-0.35, 0.35)),
			"size": _rng.randf_range(0.95, 1.55) * clampf(s, 0.65, 1.5),
			"age": 0.0,
			"life": _rng.randf_range(0.85, 1.30),
			"color": Color(0.10, 0.09, 0.09, 0.8),
			"decal_chance": 0.0,
			"gravity": 1.4,
			"drag": 1.6,
			"fade_shrink": true,
		})
		emitted = true

	if ash_phase >= 0.35:
		var ash_count: int = _rng.randi_range(1, 2)
		for _ai in ash_count:
			var aa: float = _rng.randf_range(0.0, TAU)
			var ar: float = _rng.randf_range(0.0, rad * 1.1)
			_emit_droplet({
				"pos": base_pos + Vector3(cos(aa) * ar, _rng.randf_range(0.04, 0.24 * s), sin(aa) * ar),
				"vel": Vector3(_rng.randf_range(-0.45, 0.45), _rng.randf_range(0.25, 0.65), _rng.randf_range(-0.45, 0.45)),
				"size": _rng.randf_range(0.42, 0.82) * clampf(s, 0.6, 1.4),
				"age": 0.0,
				"life": _rng.randf_range(0.95, 1.40),
				"color": Color(0.18, 0.17, 0.16, 0.85),
				"decal_chance": 0.0,
				"gravity": 0.5,
				"drag": 1.8,
				"fade_shrink": true,
			})
			emitted = true

	if emitted:
		_droplets_mmi.visible = true


func step(dt: float) -> void:
	if dt <= 0.0 or api == null:
		return
	var nat: Object = _native()
	if nat != null:
		_step_native(nat, dt)
		return
	if not _droplets.is_empty():
		_step_droplets(dt)
	if _decal_active > 0:
		_step_decals(dt)
	if not _gibs.is_empty():
		_step_gibs(dt)


func clear() -> void:
	if _nat != null:
		_nat.call("clear")
	_droplets.clear()
	if _droplets_mm != null:
		_droplets_mm.visible_instance_count = 0
	if _droplets_mmi != null:
		_droplets_mmi.visible = false

	_decals.clear()
	_decal_head = 0
	_decal_active = 0
	_decals_dirty = false
	if _decals_mm != null:
		_decals_mm.visible_instance_count = 0
	if _decals_mmi != null:
		_decals_mmi.visible = false

	_gibs.clear()
	if _gibs_chitin_mm != null:
		_gibs_chitin_mm.visible_instance_count = 0
	if _gibs_chitin_mmi != null:
		_gibs_chitin_mmi.visible = false
	if _gibs_meat_mm != null:
		_gibs_meat_mm.visible_instance_count = 0
	if _gibs_meat_mmi != null:
		_gibs_meat_mmi.visible = false
	if _gibs_spike_mm != null:
		_gibs_spike_mm.visible_instance_count = 0
	if _gibs_spike_mmi != null:
		_gibs_spike_mmi.visible = false


func dispose() -> void:
	clear()
	if _container != null and is_instance_valid(_container):
		var parent: Node = _container.get_parent()
		if parent != null:
			parent.remove_child(_container)
		_container.queue_free()
	_container = null
	_droplets_mmi = null
	_droplets_mm = null
	_decals_mmi = null
	_decals_mm = null
	_gibs_chitin_mmi = null
	_gibs_chitin_mm = null
	_gibs_meat_mmi = null
	_gibs_meat_mm = null
	_gibs_spike_mmi = null
	_gibs_spike_mm = null
	api = null


func _build_pools() -> void:
	var wide_box := AABB(Vector3(-2048.0, -256.0, -2048.0), Vector3(4096.0, 512.0, 4096.0))

	# 1. Blood droplets pool.
	var drop_mesh := SphereMesh.new()
	drop_mesh.radius = 0.055
	drop_mesh.height = 0.11
	drop_mesh.radial_segments = 6
	drop_mesh.rings = 3
	var drop_mat := StandardMaterial3D.new()
	drop_mat.vertex_color_use_as_albedo = true
	drop_mat.vertex_color_is_srgb = true
	drop_mat.roughness = 0.24
	drop_mat.metallic = 0.04
	drop_mesh.material = drop_mat
	_droplets_mm = MultiMesh.new()
	_droplets_mm.transform_format = MultiMesh.TRANSFORM_3D
	_droplets_mm.use_colors = true
	_droplets_mm.mesh = drop_mesh
	_droplets_mm.instance_count = MAX_DROPLETS
	_droplets_mm.visible_instance_count = 0
	_droplets_mmi = MultiMeshInstance3D.new()
	_droplets_mmi.name = "BloodDroplets"
	_droplets_mmi.multimesh = _droplets_mm
	_droplets_mmi.material_override = drop_mat
	_droplets_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_droplets_mmi.extra_cull_margin = 128.0
	_droplets_mmi.custom_aabb = wide_box
	_droplets_mmi.visible = false
	_container.add_child(_droplets_mmi)

	# 2. Ground splatter & bounce smear decals pool.
	var decal_mesh := PlaneMesh.new()
	decal_mesh.size = Vector2(1.0, 1.0)
	var decal_mat := StandardMaterial3D.new()
	decal_mat.albedo_texture = _make_splatter_texture()
	decal_mat.vertex_color_use_as_albedo = true
	decal_mat.vertex_color_is_srgb = true
	decal_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	decal_mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	decal_mat.roughness = 0.26
	decal_mat.metallic = 0.05
	decal_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	decal_mesh.material = decal_mat
	_decals_mm = MultiMesh.new()
	_decals_mm.transform_format = MultiMesh.TRANSFORM_3D
	_decals_mm.use_colors = true
	_decals_mm.mesh = decal_mesh
	_decals_mm.instance_count = MAX_DECALS
	_decals_mm.visible_instance_count = 0
	_decals_mmi = MultiMeshInstance3D.new()
	_decals_mmi.name = "BloodDecals"
	_decals_mmi.multimesh = _decals_mm
	_decals_mmi.material_override = decal_mat
	_decals_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_decals_mmi.extra_cull_margin = 128.0
	_decals_mmi.custom_aabb = wide_box
	_decals_mmi.visible = false
	_container.add_child(_decals_mmi)

	# 3A. Sculpted curved jagged chitin armor shards pool.
	var chitin_mat := _make_gib_material(0.34, 0.14)
	var chitin_mesh: ArrayMesh = _build_chitin_shard_mesh(chitin_mat)
	var chitin_pool: Array = _make_gib_pool("BiterGibsChitin", chitin_mesh, chitin_mat, wide_box)
	_gibs_chitin_mm = chitin_pool[0] as MultiMesh
	_gibs_chitin_mmi = chitin_pool[1] as MultiMeshInstance3D

	# 3B. Sculpted lumpy wet organic meat / flesh chunks pool.
	var meat_mat := _make_gib_material(0.18, 0.02)
	var meat_mesh: ArrayMesh = _build_meat_chunk_mesh(meat_mat)
	var meat_pool: Array = _make_gib_pool("BiterGibsMeat", meat_mesh, meat_mat, wide_box)
	_gibs_meat_mm = meat_pool[0] as MultiMesh
	_gibs_meat_mmi = meat_pool[1] as MultiMeshInstance3D

	# 3C. Sculpted curved tapered horn / fang / claw splinters pool.
	var spike_mat := _make_gib_material(0.30, 0.08)
	var spike_mesh: ArrayMesh = _build_spike_splinter_mesh(spike_mat)
	var spike_pool: Array = _make_gib_pool("BiterGibsSpike", spike_mesh, spike_mat, wide_box)
	_gibs_spike_mm = spike_pool[0] as MultiMesh
	_gibs_spike_mmi = spike_pool[1] as MultiMeshInstance3D


func _make_gib_material(rough: float, metal: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = rough
	mat.metallic = metal
	return mat


func _make_gib_pool(node_name: String, mesh: ArrayMesh, mat: StandardMaterial3D, wide_box: AABB) -> Array:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = MAX_GIBS
	mm.visible_instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.extra_cull_margin = 128.0
	mmi.custom_aabb = wide_box
	mmi.visible = false
	_container.add_child(mmi)
	return [mm, mmi]


func _finalize_gib_mesh(verts: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, mat: StandardMaterial3D) -> ArrayMesh:
	var n_verts: int = verts.size()
	var center := Vector3.ZERO
	for i in n_verts:
		center += verts[i]
	if n_verts > 0:
		center /= float(n_verts)
	var centered := PackedVector3Array()
	centered.resize(n_verts)
	for i in n_verts:
		centered[i] = verts[i] - center
	var normals := _compute_smooth_normals(centered, indices)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = centered
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, mat)
	return mesh


func _compute_smooth_normals(verts: PackedVector3Array, indices: PackedInt32Array) -> PackedVector3Array:
	var n_verts: int = verts.size()
	var normals := PackedVector3Array()
	normals.resize(n_verts)
	for i in n_verts:
		normals[i] = Vector3.ZERO
	# Godot front faces wind clockwise when viewed from outside, so (v2 - v0) x (v1 - v0) points outward.
	var n_idx: int = indices.size()
	for k in range(0, n_idx - 2, 3):
		var i0: int = indices[k]
		var i1: int = indices[k + 1]
		var i2: int = indices[k + 2]
		var fn: Vector3 = (verts[i2] - verts[i0]).cross(verts[i1] - verts[i0])
		normals[i0] += fn
		normals[i1] += fn
		normals[i2] += fn
	for i in n_verts:
		var n: Vector3 = normals[i]
		if n.length_squared() > 1e-12:
			normals[i] = n.normalized()
		else:
			normals[i] = Vector3.UP
	return normals


func _build_chitin_shard_mesh(mat: StandardMaterial3D) -> ArrayMesh:
	# Closed manifold curved carapace plate fragment (50 verts, 96 tris):
	# arched dorsal keel ridge, beveled irregular 6-lobe perimeter with splintered notches,
	# and darker blood-stained concave underside in COLOR_0.
	const SEG := 12
	var angles: PackedFloat32Array = PackedFloat32Array([
		0.00, 0.46, 0.98, 1.50, 2.02, 2.58,
		3.10, 3.64, 4.18, 4.72, 5.24, 5.76,
	])
	var radii: PackedFloat32Array = PackedFloat32Array([
		0.54, 0.36, 0.56, 0.44, 0.48, 0.31,
		0.58, 0.42, 0.50, 0.33, 0.52, 0.41,
	])
	var px := PackedFloat32Array()
	var pz := PackedFloat32Array()
	px.resize(SEG)
	pz.resize(SEG)
	for k in SEG:
		var a: float = angles[k]
		var r: float = radii[k]
		px[k] = cos(a) * r * 0.88
		pz[k] = sin(a) * r * 1.18

	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	verts.resize(50)
	colors.resize(50)

	# Layer 0: dorsal keel apex (idx 0).
	verts[0] = Vector3(0.0, 0.40, 0.0)
	colors[0] = Color(1.00, 0.99, 0.97, 1.0)

	# Layers 1..4: concentric shell rings around the irregular perimeter.
	var r1_base := 1
	var r2_base := 1 + SEG
	var r3_base := 1 + SEG * 2
	var r4_base := 1 + SEG * 3
	for k in SEG:
		var is_notch: bool = (k % 2) == 1
		var ox: float = px[k]
		var oz: float = pz[k]

		# Layer 1: arched dorsal mid-ring (u = 0.52).
		var x1: float = ox * 0.52
		var z1: float = oz * 0.52
		var kw1: float = maxf(0.0, 1.0 - absf(x1) / 0.34)
		var y1: float = 0.21 * (1.0 - 0.52 * 0.52 * 0.95) - 0.05 * z1 * z1 - 0.02 * x1 * z1 + 0.13 * kw1 * kw1 * (1.0 - 0.55 * 0.27) + 0.055
		verts[r1_base + k] = Vector3(x1, y1, z1)
		var ridge_t: float = clampf(kw1, 0.0, 1.0)
		colors[r1_base + k] = Color(lerpf(0.84, 0.98, ridge_t), lerpf(0.82, 0.96, ridge_t), lerpf(0.82, 0.95, ridge_t), 1.0)

		# Layer 2: beveled dorsal shoulder ring (u = 0.89).
		var x2: float = ox * 0.89
		var z2: float = oz * 0.89
		var kw2: float = maxf(0.0, 1.0 - absf(x2) / 0.34)
		var y2: float = 0.21 * (1.0 - 0.89 * 0.89 * 0.95) - 0.05 * z2 * z2 - 0.02 * x2 * z2 + 0.085 * kw2 * kw2 * 0.56 + 0.042
		verts[r2_base + k] = Vector3(x2, y2, z2)
		if is_notch:
			colors[r2_base + k] = Color(0.74, 0.62, 0.66, 1.0)
		else:
			colors[r2_base + k] = Color(0.82, 0.80, 0.79, 1.0)

		# Layer 3: jagged fractured outer rim (u = 1.00).
		var kw3: float = maxf(0.0, 1.0 - absf(ox) / 0.34)
		var notch_dip: float = -0.018 if is_notch else 0.0
		var y3: float = 0.21 * 0.05 - 0.05 * oz * oz - 0.02 * ox * oz + 0.045 * kw3 * kw3 * 0.45 - 0.015 + notch_dip
		verts[r3_base + k] = Vector3(ox, y3, oz)
		colors[r3_base + k] = Color(0.66, 0.32, 0.42, 1.0) if is_notch else Color(0.70, 0.38, 0.46, 1.0)

		# Layer 4: concave bloody underside inner ring (u = 0.58).
		var x4: float = ox * 0.58
		var z4: float = oz * 0.58
		var y4: float = 0.21 * (1.0 - 0.58 * 0.58 * 0.95) - 0.05 * z4 * z4 - 0.02 * x4 * z4 - 0.095
		verts[r4_base + k] = Vector3(x4, y4, z4)
		colors[r4_base + k] = Color(0.54, 0.19, 0.34, 1.0)

	# Layer 5: concave bloody underside center (idx 49).
	var vent_center_idx := 49
	verts[vent_center_idx] = Vector3(0.0, 0.105, 0.0)
	colors[vent_center_idx] = Color(0.44, 0.14, 0.28, 1.0)

	var indices := PackedInt32Array()
	# Dorsal apex fan (12 tris).
	for k in SEG:
		var k1: int = (k + 1) % SEG
		indices.append(0)
		indices.append(r1_base + k)
		indices.append(r1_base + k1)
	# Concentric strips: L1->L2, L2->L3, L3->L4 (3 * 24 = 72 tris).
	var ring_bases: PackedInt32Array = PackedInt32Array([r1_base, r2_base, r3_base, r4_base])
	for r in 3:
		var ra: int = ring_bases[r]
		var rb: int = ring_bases[r + 1]
		for k in SEG:
			var k1: int = (k + 1) % SEG
			indices.append(ra + k)
			indices.append(rb + k)
			indices.append(rb + k1)
			indices.append(ra + k)
			indices.append(rb + k1)
			indices.append(ra + k1)
	# Ventral concave center fan (12 tris).
	for k in SEG:
		var k1: int = (k + 1) % SEG
		indices.append(r4_base + k)
		indices.append(vent_center_idx)
		indices.append(r4_base + k1)

	return _finalize_gib_mesh(verts, colors, indices, mat)


func _build_meat_chunk_mesh(mat: StandardMaterial3D) -> ArrayMesh:
	# Closed 2x-subdivided octahedron (66 verts, 128 tris) sculpted with multi-frequency
	# 3D organic muscle lumps, torn visceral cavities, smooth normals, and vertex-baked crevice AO.
	var dirs: Array = [
		Vector3(0.0, 1.0, 0.0),
		Vector3(0.0, -1.0, 0.0),
		Vector3(1.0, 0.0, 0.0),
		Vector3(0.0, 0.0, 1.0),
		Vector3(-1.0, 0.0, 0.0),
		Vector3(0.0, 0.0, -1.0),
	]
	var tris: PackedInt32Array = PackedInt32Array([
		0, 2, 3,
		0, 3, 4,
		0, 4, 5,
		0, 5, 2,
		1, 3, 2,
		1, 4, 3,
		1, 5, 4,
		1, 2, 5,
	])

	# Two midpoint subdivision passes: 8 -> 32 -> 128 triangles (66 unique vertices).
	for _pass in 2:
		var mid_cache: Dictionary = {}
		var next_tris := PackedInt32Array()
		var n_t: int = tris.size()
		for k in range(0, n_t - 2, 3):
			var a: int = tris[k]
			var b: int = tris[k + 1]
			var c: int = tris[k + 2]
			var ab: int = _subdiv_midpoint(a, b, dirs, mid_cache)
			var bc: int = _subdiv_midpoint(b, c, dirs, mid_cache)
			var ca: int = _subdiv_midpoint(c, a, dirs, mid_cache)
			next_tris.append(a)
			next_tris.append(ab)
			next_tris.append(ca)
			next_tris.append(ab)
			next_tris.append(b)
			next_tris.append(bc)
			next_tris.append(ca)
			next_tris.append(bc)
			next_tris.append(c)
			next_tris.append(ab)
			next_tris.append(bc)
			next_tris.append(ca)
		tris = next_tris

	var n_verts: int = dirs.size()
	var verts := PackedVector3Array()
	verts.resize(n_verts)
	var disp_vals := PackedFloat32Array()
	disp_vals.resize(n_verts)
	var cav_vals := PackedFloat32Array()
	cav_vals.resize(n_verts)

	var cav0: Vector3 = Vector3(0.62, 0.45, -0.64).normalized()
	var cav1: Vector3 = Vector3(-0.74, -0.25, 0.62).normalized()
	var cav2: Vector3 = Vector3(0.15, -0.82, -0.55).normalized()

	for i in n_verts:
		var u: Vector3 = dirs[i] as Vector3
		var f1: float = sin(u.x * 3.1 + 0.6) * cos(u.y * 2.9 - 0.4) * sin(u.z * 3.3 + 1.1)
		var f2: float = cos(u.x * 4.7 - u.z * 3.8 + 0.9) * sin(u.y * 4.2 + u.x * 2.1)
		var f3: float = 0.5 * sin(u.x * 7.3 + u.y * 6.1 - u.z * 5.7) + 0.5 * cos(u.z * 8.1 - u.x * 5.3 + u.y * 4.9)
		var pit0: float = pow(maxf(0.0, u.dot(cav0)), 4.5) * 0.34
		var pit1: float = pow(maxf(0.0, u.dot(cav1)), 4.5) * 0.30
		var pit2: float = pow(maxf(0.0, u.dot(cav2)), 5.0) * 0.26
		var cav: float = pit0 + pit1 + pit2
		var rad: float = 0.49 * clampf(1.0 + 0.26 * f1 + 0.16 * f2 + 0.09 * f3 - cav, 0.52, 1.38)
		verts[i] = Vector3(u.x * 1.06, u.y * 0.78, u.z * 1.18) * rad
		disp_vals[i] = rad
		cav_vals[i] = cav

	# Build 1-ring neighbor lookup + smooth normals for vertex-baked crevice AO (0.55..1.05).
	var neighbors: Array = []
	neighbors.resize(n_verts)
	for i in n_verts:
		neighbors[i] = {}
	var n_idx: int = tris.size()
	for k in range(0, n_idx - 2, 3):
		var i0: int = tris[k]
		var i1: int = tris[k + 1]
		var i2: int = tris[k + 2]
		var d0: Dictionary = neighbors[i0] as Dictionary
		var d1: Dictionary = neighbors[i1] as Dictionary
		var d2: Dictionary = neighbors[i2] as Dictionary
		d0[i1] = true
		d0[i2] = true
		d1[i0] = true
		d1[i2] = true
		d2[i0] = true
		d2[i1] = true

	var raw_normals: PackedVector3Array = _compute_smooth_normals(verts, tris)
	var colors := PackedColorArray()
	colors.resize(n_verts)
	for i in n_verts:
		var nb_dict: Dictionary = neighbors[i] as Dictionary
		var avg_nb := Vector3.ZERO
		var nb_count := 0
		for nb_key in nb_dict:
			avg_nb += verts[int(nb_key)]
			nb_count += 1
		if nb_count > 0:
			avg_nb /= float(nb_count)
		var protrusion: float = (verts[i] - avg_nb).dot(raw_normals[i])
		var r_norm: float = clampf((disp_vals[i] - 0.25) / 0.43, 0.0, 1.0)
		var ao: float = clampf(0.83 + protrusion * 1.85 + (r_norm - 0.5) * 0.20 - cav_vals[i] * 0.55, 0.55, 1.05)
		colors[i] = Color(
			clampf(ao * 1.02, 0.55, 1.05),
			clampf(ao * 0.94, 0.55, 1.05),
			clampf(ao * 0.98, 0.55, 1.05),
			1.0
		)

	return _finalize_gib_mesh(verts, colors, tris, mat)


func _subdiv_midpoint(a: int, b: int, dirs: Array, cache: Dictionary) -> int:
	var key := Vector2i(mini(a, b), maxi(a, b))
	if cache.has(key):
		return int(cache[key])
	var va: Vector3 = dirs[a] as Vector3
	var vb: Vector3 = dirs[b] as Vector3
	var mid: Vector3 = (va + vb).normalized()
	var idx: int = dirs.size()
	dirs.append(mid)
	cache[key] = idx
	return idx


func _spike_spine(t: float) -> Vector3:
	return Vector3(
		0.05 * sin(t * PI),
		-0.15 + 0.46 * t * t,
		lerpf(-0.58, 0.64, t)
	)


func _build_spike_splinter_mesh(mat: StandardMaterial3D) -> ArrayMesh:
	# Closed curved tapered horn / fang / claw splinter (32 verts, 60 tris):
	# jagged blood-soaked torn root base transitioning along a swept scythe blade to a pale bone tip.
	const SIDES := 6
	const RINGS := 5
	var ring_t: PackedFloat32Array = PackedFloat32Array([0.00, 0.22, 0.50, 0.78, 0.94])
	var ring_rx: PackedFloat32Array = PackedFloat32Array([0.19, 0.20, 0.14, 0.08, 0.032])
	var ring_ry: PackedFloat32Array = PackedFloat32Array([0.23, 0.25, 0.19, 0.12, 0.048])
	var root_jagged: PackedFloat32Array = PackedFloat32Array([-0.05, 0.06, -0.03, 0.07, -0.04, 0.03])
	var ring_cols: PackedColorArray = PackedColorArray([
		Color(0.50, 0.17, 0.35, 1.0),
		Color(0.68, 0.42, 0.46, 1.0),
		Color(0.86, 0.78, 0.68, 1.0),
		Color(0.98, 0.93, 0.82, 1.0),
		Color(1.04, 1.00, 0.90, 1.0),
	])

	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	verts.resize(2 + RINGS * SIDES)
	colors.resize(2 + RINGS * SIDES)

	# Vertex 0: recessed torn bloody root center.
	var t0_dir: Vector3 = (_spike_spine(0.05) - _spike_spine(0.0)).normalized()
	verts[0] = _spike_spine(0.0) - t0_dir * 0.04
	colors[0] = Color(0.42, 0.12, 0.30, 1.0)

	# 5 longitudinal rings (6 vertices each).
	for r in RINGS:
		var t: float = ring_t[r]
		var c: Vector3 = _spike_spine(t)
		var t_prev: float = maxf(0.0, t - 0.03)
		var t_next: float = minf(1.0, t + 0.03)
		var tang: Vector3 = (_spike_spine(t_next) - _spike_spine(t_prev)).normalized()
		var right: Vector3 = (Vector3.RIGHT - tang * tang.dot(Vector3.RIGHT)).normalized()
		var up: Vector3 = tang.cross(right).normalized()
		var rx: float = ring_rx[r]
		var ry: float = ring_ry[r]
		var base_col: Color = ring_cols[r]
		for k in SIDES:
			var a: float = TAU * float(k) / float(SIDES)
			var ca: float = cos(a)
			var sa: float = sin(a)
			# Pinch inner concave cutting edge (+up) and subtly ridge dorsal spine (-up).
			var local_x: float = ca * rx * (0.76 if sa > 0.3 else 1.0)
			var local_y: float = sa * ry * (1.08 if sa < -0.3 else 1.0)
			var axial: float = root_jagged[k] if r == 0 else 0.0
			var v_idx: int = 1 + r * SIDES + k
			verts[v_idx] = c + right * local_x + up * local_y + tang * axial
			var edge_shade: float = 1.02 if sa > 0.3 else (0.94 if sa < -0.3 else 0.98)
			colors[v_idx] = Color(
				clampf(base_col.r * edge_shade, 0.0, 1.06),
				clampf(base_col.g * edge_shade, 0.0, 1.06),
				clampf(base_col.b * edge_shade, 0.0, 1.06),
				1.0
			)

	# Final vertex (idx 31): sharp curved claw/horn tip apex.
	var tip_idx: int = 1 + RINGS * SIDES
	verts[tip_idx] = _spike_spine(1.0)
	colors[tip_idx] = Color(1.05, 1.02, 0.94, 1.0)

	var indices := PackedInt32Array()
	# Root cap fan (6 tris).
	for k in SIDES:
		var k1: int = (k + 1) % SIDES
		indices.append(0)
		indices.append(1 + k)
		indices.append(1 + k1)
	# Ring strips (4 * 12 = 48 tris).
	for r in (RINGS - 1):
		var ra: int = 1 + r * SIDES
		var rb: int = 1 + (r + 1) * SIDES
		for k in SIDES:
			var k1: int = (k + 1) % SIDES
			indices.append(ra + k)
			indices.append(rb + k)
			indices.append(ra + k1)
			indices.append(rb + k)
			indices.append(rb + k1)
			indices.append(ra + k1)
	# Tip apex fan (6 tris).
	var last_ring: int = 1 + (RINGS - 1) * SIDES
	for k in SIDES:
		var k1: int = (k + 1) % SIDES
		indices.append(tip_idx)
		indices.append(last_ring + k1)
		indices.append(last_ring + k)

	return _finalize_gib_mesh(verts, colors, indices, mat)


func _make_splatter_texture() -> ImageTexture:
	var sz := 32
	var img := Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	var half := float(sz) * 0.5
	for y in sz:
		for x in sz:
			var dx: float = (float(x) + 0.5 - half) / half
			var dy: float = (float(y) + 0.5 - half) / half
			var r: float = sqrt(dx * dx + dy * dy)
			var ang: float = atan2(dy, dx)
			# Organic multi-lobe silhouette so splatters read as wet ichor blotches.
			var lobe: float = 0.72 + 0.14 * sin(ang * 3.0 + 0.7) + 0.09 * cos(ang * 5.0 - 0.4) + 0.06 * sin(ang * 7.0 + 1.9)
			var alpha: float = clampf((lobe - r) * 4.5, 0.0, 1.0)
			alpha = alpha * alpha * (3.0 - 2.0 * alpha)
			# Slightly darker rim for wet surface tension.
			var shade: float = clampf(0.95 - r * 0.25, 0.65, 0.96)
			img.set_pixel(x, y, Color(shade, shade, shade, alpha * 0.92))
	return ImageTexture.create_from_image(img)


func _spawn_droplet_burst(origin: Vector3, dir: Vector3, count: int, speed_lo: float, speed_hi: float, t_scale: float, spread: float) -> void:
	for _i in count:
		var cone := Vector3(
			dir.x + _rng.randf_range(-spread, spread),
			_rng.randf_range(0.25, 1.15),
			dir.z + _rng.randf_range(-spread, spread)
		)
		if cone.length_squared() < 0.001:
			cone = Vector3.UP
		else:
			cone = cone.normalized()
		var spd: float = _rng.randf_range(speed_lo, speed_hi)
		var sz: float = _rng.randf_range(0.7, 1.45) * clampf(t_scale, 0.7, 1.6)
		_emit_droplet({
			"pos": origin + Vector3(_rng.randf_range(-0.15, 0.15), _rng.randf_range(-0.08, 0.12), _rng.randf_range(-0.15, 0.15)),
			"vel": cone * spd,
			"size": sz,
			"age": 0.0,
			"color": _ichor_color(1.0),
			"decal_chance": 0.45,
		})
	_droplets_mmi.visible = true


func _step_droplets(dt: float) -> void:
	var i: int = _droplets.size() - 1
	while i >= 0:
		var d: Dictionary = _droplets[i] as Dictionary
		var age: float = float(d["age"]) + dt
		var pos: Vector3 = d["pos"] as Vector3
		var vel: Vector3 = d["vel"] as Vector3
		var grav: float = float(d.get("gravity", GRAVITY))
		var drag: float = float(d.get("drag", 0.0))
		vel.y += grav * dt
		if drag > 0.0:
			vel *= maxf(0.0, 1.0 - drag * dt)
		pos += vel * dt
		var gh: float = float(api.creatures.ground_height(pos.x, pos.z))
		var max_life: float = float(d.get("life", DROPLET_LIFE))
		if pos.y <= gh or age >= max_life:
			if pos.y <= gh and _rng.randf() < float(d["decal_chance"]):
				var sz: float = float(d["size"]) * _rng.randf_range(0.28, 0.52)
				var hvel := Vector2(vel.x, vel.z)
				var stretch: float = clampf(1.0 + hvel.length() * 0.14, 1.0, 2.2)
				var yaw: float = atan2(vel.x, vel.z) if hvel.length_squared() > 0.04 else _rng.randf_range(0.0, TAU)
				_add_decal(Vector3(pos.x, gh, pos.z), sz, stretch, yaw, d["color"] as Color)
			_droplets.remove_at(i)
		else:
			d["pos"] = pos
			d["vel"] = vel
			d["age"] = age
		i -= 1

	var count: int = mini(_droplets.size(), MAX_DROPLETS)
	_droplets_mm.visible_instance_count = count
	_droplets_mmi.visible = count > 0
	for k in count:
		var d: Dictionary = _droplets[k] as Dictionary
		var pos: Vector3 = d["pos"] as Vector3
		var vel: Vector3 = d["vel"] as Vector3
		var sz: float = float(d["size"])
		if bool(d.get("fade_shrink", false)):
			var life_frac: float = clampf(float(d["age"]) / maxf(float(d.get("life", DROPLET_LIFE)), 0.05), 0.0, 1.0)
			sz *= (1.0 - life_frac * 0.85)
		var spd: float = vel.length()
		var basis := Basis.IDENTITY
		if spd > 0.25:
			var fwd: Vector3 = vel / spd
			var up: Vector3 = Vector3.UP if absf(fwd.y) < 0.95 else Vector3.RIGHT
			var right: Vector3 = up.cross(fwd).normalized()
			var ortho_up: Vector3 = fwd.cross(right).normalized()
			var stretch: float = clampf(1.0 + spd * 0.18, 1.0, 3.2)
			basis = Basis(right * sz, ortho_up * sz, fwd * (sz * stretch))
		else:
			basis = Basis.IDENTITY.scaled(Vector3.ONE * sz)
		_droplets_mm.set_instance_transform(k, Transform3D(basis, pos))
		_droplets_mm.set_instance_color(k, d["color"] as Color)


func _add_decal(pos: Vector3, size: float, stretch: float, yaw: float, col: Color) -> void:
	if _decals_mm == null:
		return
	var normal: Vector3 = api.creatures.ground_normal(pos.x, pos.z) as Vector3
	if normal.length_squared() < 0.01:
		normal = Vector3.UP
	else:
		normal = normal.normalized()

	var idx: int = _decal_head
	_decal_head = (_decal_head + 1) % MAX_DECALS
	if _decals.size() < MAX_DECALS:
		_decals.append({})
	_decal_active = mini(_decal_active + 1, MAX_DECALS)

	var lift: float = 0.022 + float(idx % 16) * 0.0012
	var basis: Basis = _decal_basis(normal, yaw, size, stretch)
	var xf := Transform3D(basis, pos + normal * lift)
	var nat: Object = _native()
	if nat != null:
		nat.call("set_decal", idx, xf, col)
		if batch_decals:
			_decals_dirty = true
		else:
			var nbuf: PackedFloat32Array = nat.call("decal_buffer")
			_decals_mm.buffer = nbuf
		_decals[idx] = {}
		_decals_mm.visible_instance_count = _decals.size()
		_decals_mmi.visible = true
		return
	_decals[idx] = {
		"xf": xf,
		"pos": pos + normal * lift,
		"basis": basis,
		"color": col,
		"age": 0.0,
		"alive": true,
	}
	_decals_mm.set_instance_transform(idx, xf)
	_decals_mm.set_instance_color(idx, col)
	_decals_mm.visible_instance_count = _decals.size()
	_decals_mmi.visible = true


func _step_decals(dt: float) -> void:
	var any_alive: bool = false
	for idx in _decals.size():
		var rec: Dictionary = _decals[idx] as Dictionary
		if not bool(rec.get("alive", false)):
			continue
		var age: float = float(rec["age"]) + dt
		rec["age"] = age
		if age >= DECAL_LIFE + DECAL_FADE:
			rec["alive"] = false
			_decals_mm.set_instance_transform(idx, Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), Vector3.ZERO))
		elif age > DECAL_LIFE:
			any_alive = true
			var t: float = 1.0 - (age - DECAL_LIFE) / DECAL_FADE
			var c: Color = rec["color"] as Color
			c.a = clampf(t, 0.0, 1.0)
			_decals_mm.set_instance_color(idx, c)
		else:
			any_alive = true
	if not any_alive:
		_decal_active = 0
		_decals_mmi.visible = false


func _spawn_gibs(origin: Vector3, dir: Vector3, count: int, t_scale: float, chitin: Color, explosive: bool) -> void:
	var scale_mul: float = clampf(t_scale, 0.7, 1.75)
	for i in count:
		var spread: float = 1.25 if explosive else 0.75
		var v_dir := Vector3(
			dir.x + _rng.randf_range(-spread, spread),
			_rng.randf_range(0.45, 1.35),
			dir.z + _rng.randf_range(-spread, spread)
		).normalized()
		var spd: float = _rng.randf_range(4.5, 10.5) if explosive else _rng.randf_range(5.5, 11.5)
		var kind: int
		if count >= 3 and i < 3:
			kind = i
		else:
			var roll: float = _rng.randf()
			if roll < 0.40:
				kind = GIB_CHITIN
			elif roll < 0.80:
				kind = GIB_MEAT
			else:
				kind = GIB_SPIKE
		var col: Color
		var sz: Vector3
		if kind == GIB_MEAT:
			col = _meat_color()
			sz = Vector3(
				_rng.randf_range(0.16, 0.28),
				_rng.randf_range(0.14, 0.25),
				_rng.randf_range(0.17, 0.30)
			) * scale_mul
		elif kind == GIB_SPIKE:
			col = _spike_color(chitin)
			sz = Vector3(
				_rng.randf_range(0.14, 0.22),
				_rng.randf_range(0.14, 0.23),
				_rng.randf_range(0.20, 0.32)
			) * scale_mul
		else:
			var jitter: float = _rng.randf_range(0.92, 1.20)
			col = Color(
				clampf(chitin.r * jitter, 0.04, 0.95),
				clampf(chitin.g * jitter, 0.04, 0.95),
				clampf(chitin.b * jitter, 0.04, 0.95),
				1.0
			)
			sz = Vector3(
				_rng.randf_range(0.18, 0.30),
				_rng.randf_range(0.14, 0.24),
				_rng.randf_range(0.20, 0.32)
			) * scale_mul
		var axis := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0))
		if axis.length_squared() < 0.0001:
			axis = Vector3.UP
		else:
			axis = axis.normalized()
		_emit_gib({
			"kind": kind,
			"pos": origin + Vector3(_rng.randf_range(-0.2, 0.2), _rng.randf_range(0.0, 0.25), _rng.randf_range(-0.2, 0.2)),
			"vel": v_dir * spd,
			"quat": Quaternion(axis, _rng.randf_range(0.0, TAU)),
			"ang": Vector3(_rng.randf_range(-12.0, 12.0), _rng.randf_range(-12.0, 12.0), _rng.randf_range(-12.0, 12.0)),
			"size": sz,
			"color": col,
			"age": 0.0,
			"bounces": 0,
			"settled": false,
		})
	_sync_gibs_multimeshes()


func _emit_gib(g: Dictionary) -> void:
	var nat: Object = _native()
	if nat != null:
		nat.call("add_gib", int(g["kind"]), g["pos"], g["vel"], g["quat"], g["ang"], g["size"], g["color"])
		return
	if _gibs.size() >= MAX_GIBS:
		_gibs.pop_front()
	_gibs.append(g)


## The native path of step(): one call integrates, the heights are read here (the height field is
## GDScript's), one call lands, bounces and fills every buffer.
func _step_native(nat: Object, dt: float) -> void:
	var n: int = int(nat.call("begin", dt))
	var heights := PackedFloat32Array()
	if n > 0:
		var xz: PackedFloat32Array = nat.call("sample_xz")
		heights.resize(n)
		var creatures: Object = api.creatures
		for k in n:
			heights[k] = creatures.ground_height(xz[k * 2], xz[k * 2 + 1])
	var ev: PackedFloat32Array = nat.call("finish", heights, blood_amount)
	_apply_native_events(ev)
	_native_to_multimeshes(nat)
	if _decal_active > 0:
		var st: int = int(nat.call("step_decals", dt, DECAL_LIFE, DECAL_FADE, _decals.size()))
		if st >= 2 or _decals_dirty:
			var dbuf: PackedFloat32Array = nat.call("decal_buffer")
			_decals_mm.buffer = dbuf
		_decals_dirty = false
		if st == 0 or st == 3:
			_decal_active = 0
			_decals_mmi.visible = false
	elif _decals_dirty:
		_decals_dirty = false
		var dbuf2: PackedFloat32Array = nat.call("decal_buffer")
		_decals_mm.buffer = dbuf2


func _apply_native_events(ev: PackedFloat32Array) -> void:
	var k: int = 0
	var n: int = ev.size()
	while k + 11 <= n:
		var yaw: float = ev[k + 6]
		if is_nan(yaw):
			yaw = _rng.randf_range(0.0, TAU)
		var pos := Vector3(ev[k + 1], ev[k + 2], ev[k + 3])
		if ev[k] < 0.5:
			_add_decal(pos, ev[k + 4], ev[k + 5], yaw, Color(ev[k + 7], ev[k + 8], ev[k + 9], ev[k + 10]))
		else:
			_add_decal(pos, ev[k + 4], ev[k + 5], yaw, _ichor_color(0.68))
		k += 11


func _native_to_multimeshes(nat: Object) -> void:
	if _droplets_mm == null or _gibs_chitin_mm == null:
		return
	var dn: int = int(nat.call("droplet_visible"))
	if dn > 0 or _droplets_mm.visible_instance_count > 0:
		var dbuf: PackedFloat32Array = nat.call("droplet_buffer")
		_droplets_mm.buffer = dbuf
	_droplets_mm.visible_instance_count = dn
	_droplets_mmi.visible = dn > 0
	_native_gib_kind(nat, 0, _gibs_chitin_mm, _gibs_chitin_mmi)
	_native_gib_kind(nat, 1, _gibs_meat_mm, _gibs_meat_mmi)
	_native_gib_kind(nat, 2, _gibs_spike_mm, _gibs_spike_mmi)


func _native_gib_kind(nat: Object, kind: int, mm: MultiMesh, mmi: MultiMeshInstance3D) -> void:
	var n: int = int(nat.call("gib_visible", kind))
	if n > 0 or mm.visible_instance_count > 0:
		var buf: PackedFloat32Array = nat.call("gib_buffer", kind)
		mm.buffer = buf
	mm.visible_instance_count = n
	mmi.visible = n > 0


func _step_gibs(dt: float) -> void:
	var i: int = _gibs.size() - 1
	while i >= 0:
		var g: Dictionary = _gibs[i] as Dictionary
		var age: float = float(g["age"]) + dt
		if age >= GIB_LIFE + GIB_FADE:
			_gibs.remove_at(i)
			i -= 1
			continue
		g["age"] = age
		if not bool(g["settled"]):
			var pos: Vector3 = g["pos"] as Vector3
			var vel: Vector3 = g["vel"] as Vector3
			var quat: Quaternion = g["quat"] as Quaternion
			var ang: Vector3 = g["ang"] as Vector3
			var sz: Vector3 = g["size"] as Vector3
			var kind: int = int(g.get("kind", GIB_CHITIN))
			vel.y += GRAVITY * dt
			pos += vel * dt
			var gh: float = float(api.creatures.ground_height(pos.x, pos.z))
			var rest_h: float = clampf(minf(sz.x, minf(sz.y, sz.z)) * 0.36, 0.025, 0.14)
			var floor_y: float = gh + rest_h
			if pos.y <= floor_y:
				pos.y = floor_y
				var bounces: int = int(g["bounces"])
				if kind == GIB_MEAT and bounces == 0 and absf(vel.y) > 1.4 and blood_amount > 0.001:
					var smear_sz: float = clampf(maxf(sz.x, sz.z) * 1.45 * clampf(0.5 + 0.5 * blood_amount, 0.4, 1.5), 0.22, 0.52)
					var smear_yaw: float = atan2(vel.x, vel.z) if (vel.x * vel.x + vel.z * vel.z) > 0.04 else _rng.randf_range(0.0, TAU)
					_add_decal(Vector3(pos.x, gh, pos.z), smear_sz, 1.45, smear_yaw, _ichor_color(0.68))
				var bounce_e: float = 0.20 if kind == GIB_MEAT else (0.34 if kind == GIB_SPIKE else 0.30)
				var h_fric: float = 0.42 if kind == GIB_MEAT else (0.54 if kind == GIB_SPIKE else 0.50)
				var a_damp: float = 0.40 if kind == GIB_MEAT else 0.48
				vel.y = -vel.y * bounce_e
				vel.x *= h_fric
				vel.z *= h_fric
				ang *= a_damp
				g["bounces"] = bounces + 1
				if bounces >= 2 or vel.length_squared() < 0.35:
					vel = Vector3.ZERO
					ang = Vector3.ZERO
					g["settled"] = true
			var ang_spd: float = ang.length()
			if ang_spd > 0.001:
				quat = (Quaternion(ang / ang_spd, minf(ang_spd * dt, 0.9)) * quat).normalized()
			g["pos"] = pos
			g["vel"] = vel
			g["quat"] = quat
			g["ang"] = ang
		i -= 1

	_sync_gibs_multimeshes()


func _sync_gibs_multimeshes() -> void:
	var nat: Object = _native()
	if nat != null:
		nat.call("sync_gibs")
		_native_to_multimeshes(nat)
		return
	if _gibs_chitin_mm == null or _gibs_meat_mm == null or _gibs_spike_mm == null:
		return
	var chitin_n := 0
	var meat_n := 0
	var spike_n := 0
	for k in _gibs.size():
		var g: Dictionary = _gibs[k] as Dictionary
		var pos: Vector3 = g["pos"] as Vector3
		var quat: Quaternion = g["quat"] as Quaternion
		var sz: Vector3 = g["size"] as Vector3
		var age: float = float(g["age"])
		var shrink: float = 1.0
		if age > GIB_LIFE:
			var t: float = clampf(1.0 - (age - GIB_LIFE) / GIB_FADE, 0.0, 1.0)
			shrink = t * t * (3.0 - 2.0 * t)
		var xf := Transform3D(Basis(quat).scaled(sz * shrink), pos)
		var col: Color = g["color"] as Color
		var kind: int = int(g.get("kind", GIB_CHITIN))
		if kind == GIB_MEAT:
			if meat_n < MAX_GIBS:
				_gibs_meat_mm.set_instance_transform(meat_n, xf)
				_gibs_meat_mm.set_instance_color(meat_n, col)
				meat_n += 1
		elif kind == GIB_SPIKE:
			if spike_n < MAX_GIBS:
				_gibs_spike_mm.set_instance_transform(spike_n, xf)
				_gibs_spike_mm.set_instance_color(spike_n, col)
				spike_n += 1
		else:
			if chitin_n < MAX_GIBS:
				_gibs_chitin_mm.set_instance_transform(chitin_n, xf)
				_gibs_chitin_mm.set_instance_color(chitin_n, col)
				chitin_n += 1

	_gibs_chitin_mm.visible_instance_count = chitin_n
	_gibs_chitin_mmi.visible = chitin_n > 0
	_gibs_meat_mm.visible_instance_count = meat_n
	_gibs_meat_mmi.visible = meat_n > 0
	_gibs_spike_mm.visible_instance_count = spike_n
	_gibs_spike_mmi.visible = spike_n > 0


func _decal_basis(normal: Vector3, yaw: float, size: float, stretch: float) -> Basis:
	var ref_fwd := Vector3(sin(yaw), 0.0, cos(yaw))
	var right: Vector3 = normal.cross(ref_fwd)
	if right.length_squared() < 0.0001:
		right = Vector3.RIGHT
	else:
		right = right.normalized()
	var fwd: Vector3 = right.cross(normal).normalized()
	return Basis(right * size, normal, fwd * (size * stretch))


func _away_dir(pos: Vector3, cause_pos: Variant) -> Vector3:
	if cause_pos is Vector3:
		var d: Vector3 = pos - (cause_pos as Vector3)
		d.y = 0.0
		if d.length_squared() > 0.0004:
			return d.normalized()
	var a: float = _rng.randf_range(0.0, TAU)
	return Vector3(cos(a), 0.0, sin(a))


func _ichor_color(brightness: float) -> Color:
	# Deep, rich crimson-violet / dark purple biter ichor (sRGB).
	var r: float = clampf((0.38 + _rng.randf_range(-0.07, 0.09)) * brightness, 0.16, 0.52)
	var g: float = clampf((0.055 + _rng.randf_range(-0.02, 0.025)) * brightness, 0.015, 0.10)
	var b: float = clampf((0.30 + _rng.randf_range(-0.08, 0.08)) * brightness, 0.13, 0.44)
	return Color(r, g, b, 1.0)


func _meat_color() -> Color:
	# Wet dark crimson-violet organic flesh chunk tint (multiplied by crevice AO in COLOR_0).
	return Color(
		_rng.randf_range(0.30, 0.46),
		_rng.randf_range(0.035, 0.085),
		_rng.randf_range(0.21, 0.35),
		1.0
	)


func _spike_color(chitin: Color) -> Color:
	# Warm bone/horn tint softly blended with the enemy's carapace hue.
	var bone := Color(
		_rng.randf_range(0.58, 0.72),
		_rng.randf_range(0.49, 0.62),
		_rng.randf_range(0.36, 0.48),
		1.0
	)
	var tier_hint := Color(
		clampf(chitin.r * 1.45, 0.08, 0.85),
		clampf(chitin.g * 1.45, 0.08, 0.85),
		clampf(chitin.b * 1.45, 0.08, 0.85),
		1.0
	)
	return bone.lerp(tier_hint, 0.25)
