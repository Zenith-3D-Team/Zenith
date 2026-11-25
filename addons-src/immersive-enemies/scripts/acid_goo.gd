extends RefCounted
## Slimy swamp-green 3D acid spit streams, splash crowns, bubbling ground pools, and acidic vapor
## wisps for Nauvis spitters and worms in the Immersive Enemies add-on.
##
## All visuals use five pooled MultiMeshInstance3D nodes mounted under the add-on's world root
## (zero per-particle nodes):
##   1. Sculpted 3D mucus/slime globs flying along the parabolic spit arc and wobbling in flight.
##   2. Velocity-stretched trailing, impact-splash, and pool-bubble-pop slime droplets.
##   3. Sculpted 3D corrugated liquid splash crowns rising & collapsing on spit impact.
##   4. Translucent murky swamp-green acidic vapor mist wisps drifting off splashes and pools.
##   5. Terrain-aligned, bubbling & oozing custom-shader swamp-green ground pools.

const MAX_GLOBS := 160
const MAX_DROPS := 320
const MAX_RINGS := 32
const MAX_MIST := 96
const MAX_POOLS := 96

const GRAVITY := -15.5
const RING_LIFE := 0.32
const TIER_SCALE := {
	"small": 0.68,
	"medium": 0.92,
	"big": 1.22,
	"behemoth": 1.56,
}

var api
var _container: Node3D
var _rng := RandomNumberGenerator.new()

var enabled := true
## The five particle groups kept and stepped in C++ (AcidGooNative) when the add-on's API offers it;
## null or off = the GDScript arrays below (main.gd sets use_native from the add-on setting and --enemies-native).
var use_native := true
var _n: Object = null
var _n_tried := false
var _n_active := false
var _hills_frames := 0  # frames left to read every drop's ground height (hills seen lately)

var _globs_mmi: MultiMeshInstance3D
var _globs_mm: MultiMesh
var _globs: Array = []

var _drops_mmi: MultiMeshInstance3D
var _drops_mm: MultiMesh
var _drops: Array = []

var _rings_mmi: MultiMeshInstance3D
var _rings_mm: MultiMesh
var _rings: Array = []

var _mist_mmi: MultiMeshInstance3D
var _mist_mm: MultiMesh
var _mist: Array = []

var _pools_mmi: MultiMeshInstance3D
var _pools_mm: MultiMesh
var _pools: Dictionary = {}  # id: int -> Dictionary


func _init(a, root: Node3D) -> void:
	api = a
	_rng.randomize()
	_container = Node3D.new()
	_container.name = "AcidGoo"
	root.add_child(_container)
	_build_pools()


## A native object (or null) for the particle loops; the tests hand one in here.
func set_native(obj: Object) -> void:
	_n = obj
	_n_tried = true
	if _n != null:
		_n.call("set_caps", MAX_GLOBS, MAX_DROPS, MAX_RINGS, MAX_MIST, MAX_POOLS)


func _native_on() -> bool:
	if not _n_tried:
		_n_tried = true
		if api != null and api.has_method("native_class"):
			var obj: Variant = api.native_class("AcidGooNative")
			if obj is Object:
				set_native(obj as Object)
	var on: bool = use_native and _n != null
	if on != _n_active:
		clear()  # the particles live on the other side now
		_n_active = on
	return on


func _is_acid_stream(proto: String) -> bool:
	return proto.begins_with("acid-stream-spitter-") or proto.begins_with("acid-stream-worm-")


func _is_acid_pool(proto: String) -> bool:
	return proto.begins_with("acid-splash-fire-spitter-") or proto.begins_with("acid-splash-fire-worm-")


func _tier_scale(proto: String) -> float:
	for k in TIER_SCALE:
		if proto.ends_with("-" + str(k)):
			return float(TIER_SCALE[k])
	return 1.0


func on_stream_event(info: Dictionary) -> void:
	var ev: String = str(info.get("event", ""))
	if ev == "reset":
		clear()
		return
	if not enabled or api == null or ev != "start":
		return
	var proto: String = str(info.get("name", ""))
	if not _is_acid_stream(proto):
		return

	info["handled"] = true
	var from: Vector3 = info.get("from", Vector3.ZERO) as Vector3
	var to: Vector3 = info.get("to", from + Vector3.FORWARD) as Vector3
	var t_scale: float = _tier_scale(proto)
	var hs: float = maxf(float(info.get("hs", 0.35)), 0.05)
	var va: float = maxf(float(info.get("va", 0.0045)), 0.001)
	var dist: float = Vector2(to.x - from.x, to.z - from.z).length()
	var ticks: float = maxf(dist / hs, 1.0)
	var flight_dur: float = clampf(ticks / 60.0, 0.18, 1.45)
	var arc_h: float = clampf(va * ticks * ticks / 8.0, 0.6, 5.5)

	# Primary thick mucus glob + 2-3 staggered trailing satellite globs.
	var glob_count: int = 1 + _rng.randi_range(2, 3)
	for g_idx in glob_count:
		if _globs.size() >= MAX_GLOBS:
			_globs.pop_front()
		var is_primary: bool = (g_idx == 0)
		var delay: float = 0.0 if is_primary else float(g_idx) * 0.042 + _rng.randf_range(0.0, 0.022)
		var target: Vector3 = to
		if not is_primary:
			var ang: float = _rng.randf_range(0.0, TAU)
			var jitter_r: float = _rng.randf_range(0.08, 0.38) * t_scale
			target += Vector3(cos(ang) * jitter_r, 0.0, sin(ang) * jitter_r)
		var gh: float = float(api.creatures.ground_height(target.x, target.z))
		target.y = maxf(target.y, gh + 0.05)
		var sz_mul: float = t_scale * (1.0 if is_primary else _rng.randf_range(0.54, 0.80))
		var gcol: Color = _slime_color(is_primary)
		var gseed: float = _rng.randf_range(0.0, TAU)
		if _native_on():
			_n.call("add_glob", from, target, flight_dur * (1.0 if is_primary else _rng.randf_range(0.95, 1.12)), -delay,
				arc_h * (1.0 if is_primary else _rng.randf_range(0.88, 1.08)), sz_mul, t_scale, is_primary, gseed, 0.025, gcol)
			continue
		_globs.append({
			"from": from,
			"to": target,
			"dur": flight_dur * (1.0 if is_primary else _rng.randf_range(0.95, 1.12)),
			"age": -delay,
			"arc_h": arc_h * (1.0 if is_primary else _rng.randf_range(0.88, 1.08)),
			"scale": sz_mul,
			"tier_scale": t_scale,
			"primary": is_primary,
			"seed": gseed,
			"trail_cd": 0.025,
			"color": gcol,
		})


func on_ground_fx(info: Dictionary) -> void:
	var ev: String = str(info.get("event", ""))
	if ev == "reset":
		_pools.clear()
		if _n != null:
			_n.call("clear_pools")
		if _pools_mm != null:
			_pools_mm.visible_instance_count = 0
		if _pools_mmi != null:
			_pools_mmi.visible = false
		return
	var id: int = int(info.get("id", 0))
	if ev == "end":
		if _native_on():
			_n.call("end_pool", id)
		elif _pools.has(id):
			var p: Dictionary = _pools[id] as Dictionary
			if float(p["gone"]) < 0.0:
				p["gone"] = 0.0
		return
	if not enabled or api == null or ev != "start":
		return
	var proto: String = str(info.get("name", ""))
	if not _is_acid_pool(proto):
		return

	info["handled"] = true
	if not _native_on() and _pools.size() >= MAX_POOLS and not _pools.has(id):
		var oldest_key: Variant = null
		var max_age: float = -1.0
		for k in _pools:
			var cand: Dictionary = _pools[k] as Dictionary
			var a: float = float(cand["age"])
			if a > max_age:
				max_age = a
				oldest_key = k
		if oldest_key != null:
			_pools.erase(oldest_key)

	var pos: Vector3 = info.get("pos", Vector3.ZERO) as Vector3
	var gh: float = float(api.creatures.ground_height(pos.x, pos.z))
	var nrm: Vector3 = api.creatures.ground_normal(pos.x, pos.z) as Vector3
	if nrm.length_squared() < 0.01:
		nrm = Vector3.UP
	else:
		nrm = nrm.normalized()

	var t_scale: float = _tier_scale(proto)
	var worm_mul: float = 1.15 if proto.contains("worm") else 1.0
	var radius: float = clampf(1.52 * t_scale * worm_mul, 1.15, 2.60)
	var yaw: float = _rng.randf_range(0.0, TAU)
	var aspect: float = _rng.randf_range(0.88, 1.14)
	var basis: Basis = _pool_basis(nrm, yaw, radius, radius * aspect)
	var world_pos := Vector3(pos.x, gh, pos.z) + nrm * (0.028 + float(posmod(id, 13)) * 0.0011)

	if _native_on():
		_n.call("set_pool", id, world_pos, basis, radius, maxf(float(info.get("fade_in", 0.25)), 0.18),
			maxf(float(info.get("fade_out", 0.5)), 0.35), _rng.randf_range(1.0, 97.0), _rng.randf_range(0.85, 1.25),
			_rng.randf_range(0.12, 0.55), _rng.randf_range(0.25, 0.90))
		return
	_pools[id] = {
		"id": id,
		"pos": world_pos,
		"basis": basis,
		"radius": radius,
		"age": 0.0,
		"fade_in": maxf(float(info.get("fade_in", 0.25)), 0.18),
		"fade_out": maxf(float(info.get("fade_out", 0.5)), 0.35),
		"gone": -1.0,
		"seed": _rng.randf_range(1.0, 97.0),
		"pulse": _rng.randf_range(0.85, 1.25),
		"bubble_cd": _rng.randf_range(0.12, 0.55),
		"mist_cd": _rng.randf_range(0.25, 0.90),
	}
	_sync_pools_mm()


func step(dt: float) -> void:
	if dt <= 0.0 or api == null:
		return
	if _native_on():
		_step_native(dt)
		return
	if not _globs.is_empty():
		_step_globs(dt)
	if not _drops.is_empty():
		_step_drops(dt)
	if not _rings.is_empty():
		_step_rings(dt)
	if not _mist.is_empty():
		_step_mist(dt)
	if not _pools.is_empty():
		_step_pools(dt)


func clear() -> void:
	if _n != null:
		_n.call("clear")
	_globs.clear()
	_drops.clear()
	_rings.clear()
	_mist.clear()
	_pools.clear()
	if _globs_mm != null:
		_globs_mm.visible_instance_count = 0
	if _globs_mmi != null:
		_globs_mmi.visible = false
	if _drops_mm != null:
		_drops_mm.visible_instance_count = 0
	if _drops_mmi != null:
		_drops_mmi.visible = false
	if _rings_mm != null:
		_rings_mm.visible_instance_count = 0
	if _rings_mmi != null:
		_rings_mmi.visible = false
	if _mist_mm != null:
		_mist_mm.visible_instance_count = 0
	if _mist_mmi != null:
		_mist_mmi.visible = false
	if _pools_mm != null:
		_pools_mm.visible_instance_count = 0
	if _pools_mmi != null:
		_pools_mmi.visible = false


func dispose() -> void:
	clear()
	if _container != null and is_instance_valid(_container):
		var parent: Node = _container.get_parent()
		if parent != null:
			parent.remove_child(_container)
		_container.queue_free()
	_container = null
	_globs_mmi = null
	_globs_mm = null
	_drops_mmi = null
	_drops_mm = null
	_rings_mmi = null
	_rings_mm = null
	_mist_mmi = null
	_mist_mm = null
	_pools_mmi = null
	_pools_mm = null
	api = null


func _step_globs(dt: float) -> void:
	var vis_n := 0
	var i: int = _globs.size() - 1
	while i >= 0:
		var g: Dictionary = _globs[i] as Dictionary
		var age: float = float(g["age"]) + dt
		g["age"] = age
		if age < 0.0:
			i -= 1
			continue
		var dur: float = maxf(float(g["dur"]), 0.05)
		var t: float = age / dur
		var from: Vector3 = g["from"] as Vector3
		var to: Vector3 = g["to"] as Vector3
		var arc_h: float = float(g["arc_h"])
		if t >= 1.0:
			var gh: float = float(api.creatures.ground_height(to.x, to.z))
			var land_pos := Vector3(to.x, maxf(to.y, gh), to.z)
			_spawn_splash(land_pos, float(g["tier_scale"]), bool(g["primary"]))
			_globs.remove_at(i)
			i -= 1
			continue

		var pos: Vector3 = from.lerp(to, t)
		pos.y += arc_h * 4.0 * t * (1.0 - t)
		var vel: Vector3 = (to - from) / dur
		vel.y += arc_h * 4.0 * (1.0 - 2.0 * t) / dur

		var trail_cd: float = float(g["trail_cd"]) - dt
		if trail_cd <= 0.0:
			g["trail_cd"] = 0.045 if bool(g["primary"]) else 0.075
			_emit_drop(
				pos + Vector3(_rng.randf_range(-0.08, 0.08), _rng.randf_range(-0.08, 0.08), _rng.randf_range(-0.08, 0.08)),
				vel * _rng.randf_range(0.18, 0.35) + Vector3(_rng.randf_range(-0.6, 0.6), _rng.randf_range(-0.3, 0.7), _rng.randf_range(-0.6, 0.6)),
				_rng.randf_range(0.10, 0.18) * float(g["scale"]),
				_rng.randf_range(0.35, 0.65),
				_slime_color(false),
				false
			)
		else:
			g["trail_cd"] = trail_cd

		if vis_n < MAX_GLOBS:
			var spd: float = vel.length()
			var fwd: Vector3 = vel / spd if spd > 0.05 else Vector3.FORWARD
			var up_ref: Vector3 = Vector3.UP if absf(fwd.y) < 0.94 else Vector3.RIGHT
			var right: Vector3 = up_ref.cross(fwd).normalized()
			var up: Vector3 = fwd.cross(right).normalized()
			var sc: float = float(g["scale"])
			var seed_v: float = float(g["seed"])
			var stretch: float = clampf(1.12 + spd * 0.018, 1.12, 1.38)
			var squash: float = 1.0 / sqrt(stretch)
			var wob_x: float = 1.0 + 0.14 * sin(age * 16.0 + seed_v)
			var wob_y: float = 1.0 + 0.14 * cos(age * 14.0 + seed_v * 1.7)
			var xf := Transform3D(
				Basis(right * (sc * squash * wob_x * 0.62), up * (sc * squash * wob_y * 0.62), fwd * (sc * stretch * 0.68)),
				pos
			)
			_globs_mm.set_instance_transform(vis_n, xf)
			_globs_mm.set_instance_color(vis_n, g["color"] as Color)
			vis_n += 1
		i -= 1

	_globs_mm.visible_instance_count = vis_n
	_globs_mmi.visible = vis_n > 0


## One native call steps and draws every group; what needs the script's randomness or the ground (trail
## drops, landings' splashes, a dead drop's mist, a pool's bubble and mist timers) comes back as arrays.
func _step_native(dt: float) -> void:
	var sizes: PackedInt32Array = _n.call("sizes")
	var gh := PackedFloat32Array()
	if sizes[1] > 0:
		# Ground heights for the drops: flat ground is 0 (a few drops probed); where hills show, all are read.
		var xz: PackedFloat32Array = _n.call("drop_xz")
		var count: int = xz.size() / 2
		if _hills_frames > 0:
			_hills_frames -= 1
			gh.resize(count)
			for i in count:
				gh[i] = float(api.creatures.ground_height(xz[i * 2], xz[i * 2 + 1]))
		else:
			var probes: int = mini(count, 3)
			for i in probes:
				var j: int = (i * count) / probes
				if absf(float(api.creatures.ground_height(xz[j * 2], xz[j * 2 + 1]))) > 0.0001:
					_hills_frames = 120
					break
	_n.call("step", dt, gh)
	var counts: PackedInt32Array = _n.call("counts")
	for g in 5:
		var mm: MultiMesh = [_globs_mm, _drops_mm, _rings_mm, _mist_mm, _pools_mm][g]
		var mmi: MultiMeshInstance3D = [_globs_mmi, _drops_mmi, _rings_mmi, _mist_mmi, _pools_mmi][g]
		if mm == null or mmi == null:
			continue
		var c: int = counts[g]
		if c > 0:
			mm.buffer = _n.call("buffer", g)
		mm.visible_instance_count = c
		mmi.visible = c > 0

	var landed: PackedFloat32Array = _n.call("landed")
	for k in landed.size() / 7:
		var o: int = k * 7
		var gy: float = float(api.creatures.ground_height(landed[o], landed[o + 2]))
		_spawn_splash(Vector3(landed[o], maxf(landed[o + 1], gy), landed[o + 2]), landed[o + 3], landed[o + 4] > 0.5)
	var trails: PackedFloat32Array = _n.call("trails")
	for k in trails.size() / 12:
		var o: int = k * 12
		var tp := Vector3(trails[o], trails[o + 1], trails[o + 2])
		var tv := Vector3(trails[o + 3], trails[o + 4], trails[o + 5])
		_emit_drop(
			tp + Vector3(_rng.randf_range(-0.08, 0.08), _rng.randf_range(-0.08, 0.08), _rng.randf_range(-0.08, 0.08)),
			tv * _rng.randf_range(0.18, 0.35) + Vector3(_rng.randf_range(-0.6, 0.6), _rng.randf_range(-0.3, 0.7), _rng.randf_range(-0.6, 0.6)),
			_rng.randf_range(0.10, 0.18) * trails[o + 6],
			_rng.randf_range(0.35, 0.65),
			_slime_color(false),
			false
		)
	var ends: PackedFloat32Array = _n.call("drop_ends")
	for k in ends.size() / 5:
		var o: int = k * 5
		if ends[o + 4] > 0.5 and _rng.randf() < 0.20:
			_emit_mist(
				Vector3(ends[o], ends[o + 1] + 0.06, ends[o + 2]),
				Vector3(_rng.randf_range(-0.18, 0.18), _rng.randf_range(0.35, 0.75), _rng.randf_range(-0.18, 0.18)),
				ends[o + 3] * 1.7,
				_rng.randf_range(0.55, 0.95),
				_mist_color(0.24)
			)
	var fires: PackedFloat32Array = _n.call("pool_fires")
	for k in fires.size() / 6:
		var o: int = k * 6
		var pid: int = int(fires[o])
		var pool_pos := Vector3(fires[o + 2], fires[o + 3], fires[o + 4])
		var rad: float = fires[o + 5]
		if int(fires[o + 1]) == 0:
			_n.call("set_pool_cd", pid, 0, _rng.randf_range(0.35, 1.10))
			for _bi in _rng.randi_range(1, 2):
				var a: float = _rng.randf_range(0.0, TAU)
				var rr: float = sqrt(_rng.randf()) * rad * 0.62
				_emit_drop(
					pool_pos + Vector3(cos(a) * rr, 0.04, sin(a) * rr),
					Vector3(_rng.randf_range(-0.45, 0.45), _rng.randf_range(1.6, 3.2), _rng.randf_range(-0.45, 0.45)),
					_rng.randf_range(0.06, 0.13) * clampf(rad * 0.55, 0.7, 1.4),
					_rng.randf_range(0.30, 0.55),
					_slime_color(_rng.randf() < 0.25),
					false
				)
		else:
			_n.call("set_pool_cd", pid, 1, _rng.randf_range(0.65, 1.50))
			var ma: float = _rng.randf_range(0.0, TAU)
			var mr: float = sqrt(_rng.randf()) * rad * 0.58
			_emit_mist(
				pool_pos + Vector3(cos(ma) * mr, 0.08, sin(ma) * mr),
				Vector3(_rng.randf_range(-0.18, 0.18), _rng.randf_range(0.38, 0.78), _rng.randf_range(-0.18, 0.18)),
				_rng.randf_range(0.28, 0.52) * clampf(rad * 0.55, 0.7, 1.4),
				_rng.randf_range(0.95, 1.65),
				_mist_color(0.38)
			)


func _spawn_splash(pos: Vector3, t_scale: float, primary: bool) -> void:
	var drop_count: int = _rng.randi_range(10, 18) if primary else _rng.randi_range(4, 6)
	for _k in drop_count:
		var ang: float = _rng.randf_range(0.0, TAU)
		var out_spd: float = _rng.randf_range(1.6, 5.2) * sqrt(t_scale)
		var up_spd: float = _rng.randf_range(2.8, 7.2) * sqrt(t_scale)
		_emit_drop(
			pos + Vector3(cos(ang) * 0.08 * t_scale, 0.08, sin(ang) * 0.08 * t_scale),
			Vector3(cos(ang) * out_spd, up_spd, sin(ang) * out_spd),
			_rng.randf_range(0.11, 0.24) * t_scale,
			_rng.randf_range(0.55, 0.95),
			_slime_color(_rng.randf() < 0.4),
			true
		)

	if primary:
		if not _n_active and _rings.size() >= MAX_RINGS:
			_rings.pop_front()
		var gh: float = float(api.creatures.ground_height(pos.x, pos.z))
		var nrm: Vector3 = api.creatures.ground_normal(pos.x, pos.z) as Vector3
		if nrm.length_squared() < 0.01:
			nrm = Vector3.UP
		else:
			nrm = nrm.normalized()
		var basis: Basis = _pool_basis(nrm, _rng.randf_range(0.0, TAU), 1.0, 1.0)
		if _n_active and _n != null:
			_n.call("add_ring", Vector3(pos.x, gh, pos.z) + nrm * 0.04, basis, clampf(t_scale * 0.65, 0.42, 1.10), RING_LIFE, _slime_color(false))
		else:
			_rings.append({
				"pos": Vector3(pos.x, gh, pos.z) + nrm * 0.04,
				"basis": basis,
				"scale": clampf(t_scale * 0.65, 0.42, 1.10),
				"age": 0.0,
				"life": RING_LIFE,
				"color": _slime_color(false),
			})
			_sync_rings_mm()

	var mist_count: int = _rng.randi_range(2, 3) if primary else 1
	for _m in mist_count:
		var ma: float = _rng.randf_range(0.0, TAU)
		var mr: float = _rng.randf_range(0.0, 0.45 * t_scale)
		_emit_mist(
			pos + Vector3(cos(ma) * mr, _rng.randf_range(0.08, 0.26), sin(ma) * mr),
			Vector3(_rng.randf_range(-0.35, 0.35), _rng.randf_range(0.65, 1.35), _rng.randf_range(-0.35, 0.35)),
			_rng.randf_range(0.32, 0.58) * t_scale,
			_rng.randf_range(0.85, 1.45),
			_mist_color(0.48)
		)


func _emit_drop(pos: Vector3, vel: Vector3, size: float, life: float, col: Color, make_mist: bool) -> void:
	if _n_active and _n != null:
		_n.call("add_drop", pos, vel, size, life, col, make_mist)
		return
	if _drops.size() >= MAX_DROPS:
		_drops.pop_front()
	_drops.append({
		"pos": pos,
		"vel": vel,
		"size": size,
		"age": 0.0,
		"life": life,
		"color": col,
		"make_mist": make_mist,
	})


func _step_drops(dt: float) -> void:
	var i: int = _drops.size() - 1
	while i >= 0:
		var d: Dictionary = _drops[i] as Dictionary
		var age: float = float(d["age"]) + dt
		var pos: Vector3 = d["pos"] as Vector3
		var vel: Vector3 = d["vel"] as Vector3
		vel.y += GRAVITY * dt
		pos += vel * dt
		var gh: float = float(api.creatures.ground_height(pos.x, pos.z))
		var max_life: float = float(d["life"])
		if pos.y <= gh + 0.02 or age >= max_life:
			if bool(d["make_mist"]) and pos.y <= gh + 0.05 and _rng.randf() < 0.20:
				_emit_mist(
					Vector3(pos.x, gh + 0.06, pos.z),
					Vector3(_rng.randf_range(-0.18, 0.18), _rng.randf_range(0.35, 0.75), _rng.randf_range(-0.18, 0.18)),
					float(d["size"]) * 1.7,
					_rng.randf_range(0.55, 0.95),
					_mist_color(0.24)
				)
			_drops.remove_at(i)
		else:
			d["pos"] = pos
			d["vel"] = vel
			d["age"] = age
		i -= 1

	var vis_n: int = mini(_drops.size(), MAX_DROPS)
	for k in vis_n:
		var d: Dictionary = _drops[k] as Dictionary
		var pos: Vector3 = d["pos"] as Vector3
		var vel: Vector3 = d["vel"] as Vector3
		var sz: float = float(d["size"])
		var life_t: float = clampf(float(d["age"]) / maxf(float(d["life"]), 0.05), 0.0, 1.0)
		sz *= (1.0 - life_t * 0.45)
		var spd: float = vel.length()
		var basis := Basis.IDENTITY.scaled(Vector3.ONE * sz)
		if spd > 0.25:
			var fwd: Vector3 = vel / spd
			var up_ref: Vector3 = Vector3.UP if absf(fwd.y) < 0.94 else Vector3.RIGHT
			var right: Vector3 = up_ref.cross(fwd).normalized()
			var up: Vector3 = fwd.cross(right).normalized()
			var stretch: float = clampf(1.0 + spd * 0.14, 1.0, 2.5)
			basis = Basis(right * sz, up * sz, fwd * (sz * stretch))
		_drops_mm.set_instance_transform(k, Transform3D(basis, pos))
		_drops_mm.set_instance_color(k, d["color"] as Color)
	_drops_mm.visible_instance_count = vis_n
	_drops_mmi.visible = vis_n > 0


func _step_rings(dt: float) -> void:
	var i: int = _rings.size() - 1
	while i >= 0:
		var r: Dictionary = _rings[i] as Dictionary
		var age: float = float(r["age"]) + dt
		if age >= float(r["life"]):
			_rings.remove_at(i)
		else:
			r["age"] = age
		i -= 1
	_sync_rings_mm()


func _sync_rings_mm() -> void:
	var vis_n: int = mini(_rings.size(), MAX_RINGS)
	for k in vis_n:
		var r: Dictionary = _rings[k] as Dictionary
		var t: float = clampf(float(r["age"]) / maxf(float(r["life"]), 0.05), 0.0, 1.0)
		var sc: float = float(r["scale"])
		var xz_sc: float = sc * lerpf(0.32, 1.32, 1.0 - (1.0 - t) * (1.0 - t))
		var y_sc: float = sc * maxf(0.05, sin(clampf(t / 0.85, 0.0, 1.0) * PI)) * 0.85
		var b: Basis = r["basis"] as Basis
		var xf := Transform3D(Basis(b.x * xz_sc, b.y * y_sc, b.z * xz_sc), r["pos"] as Vector3)
		var c: Color = r["color"] as Color
		c.a = clampf(0.78 * (1.0 - t * t), 0.0, 0.85)
		_rings_mm.set_instance_transform(k, xf)
		_rings_mm.set_instance_color(k, c)
	_rings_mm.visible_instance_count = vis_n
	_rings_mmi.visible = vis_n > 0


func _emit_mist(pos: Vector3, vel: Vector3, size: float, life: float, col: Color) -> void:
	if _n_active and _n != null:
		_n.call("add_mist", pos, vel, size, life, col, _rng.randf_range(0.0, TAU), _rng.randf_range(-1.2, 1.2))
		return
	if _mist.size() >= MAX_MIST:
		_mist.pop_front()
	_mist.append({
		"pos": pos,
		"vel": vel,
		"size": size,
		"age": 0.0,
		"life": life,
		"color": col,
		"base_alpha": col.a,
		"yaw": _rng.randf_range(0.0, TAU),
		"spin": _rng.randf_range(-1.2, 1.2),
	})


func _step_mist(dt: float) -> void:
	var i: int = _mist.size() - 1
	while i >= 0:
		var m: Dictionary = _mist[i] as Dictionary
		var age: float = float(m["age"]) + dt
		var life: float = maxf(float(m["life"]), 0.05)
		if age >= life:
			_mist.remove_at(i)
			i -= 1
			continue
		var vel: Vector3 = m["vel"] as Vector3
		vel.y += 0.4 * dt
		vel *= maxf(0.0, 1.0 - 1.8 * dt)
		m["vel"] = vel
		m["pos"] = (m["pos"] as Vector3) + vel * dt
		m["age"] = age
		m["yaw"] = float(m["yaw"]) + float(m["spin"]) * dt
		i -= 1

	var vis_n: int = mini(_mist.size(), MAX_MIST)
	for k in vis_n:
		var m: Dictionary = _mist[k] as Dictionary
		var t: float = clampf(float(m["age"]) / maxf(float(m["life"]), 0.05), 0.0, 1.0)
		var sz: float = float(m["size"]) * lerpf(0.60, 1.85, t)
		var fade: float = smoothstep(0.0, 0.16, t) * (1.0 - t) * (1.0 - t)
		var c: Color = m["color"] as Color
		c.a = float(m["base_alpha"]) * fade
		var xf := Transform3D(Basis(Vector3.UP, float(m["yaw"])).scaled(Vector3(sz, sz * 0.72, sz)), m["pos"] as Vector3)
		_mist_mm.set_instance_transform(k, xf)
		_mist_mm.set_instance_color(k, c)
	_mist_mm.visible_instance_count = vis_n
	_mist_mmi.visible = vis_n > 0


func _step_pools(dt: float) -> void:
	for id_var in _pools.keys():
		var p: Dictionary = _pools[id_var] as Dictionary
		var age: float = float(p["age"]) + dt
		p["age"] = age
		var gone: float = float(p["gone"])
		if gone >= 0.0:
			gone += dt
			p["gone"] = gone
			if gone >= maxf(float(p["fade_out"]), 0.05):
				_pools.erase(id_var)
			continue

		var rad: float = float(p["radius"])
		var pool_pos: Vector3 = p["pos"] as Vector3
		var b_cd: float = float(p["bubble_cd"]) - dt
		if b_cd <= 0.0:
			p["bubble_cd"] = _rng.randf_range(0.35, 1.10)
			var pop_n: int = _rng.randi_range(1, 2)
			for _bi in pop_n:
				var a: float = _rng.randf_range(0.0, TAU)
				var rr: float = sqrt(_rng.randf()) * rad * 0.62
				_emit_drop(
					pool_pos + Vector3(cos(a) * rr, 0.04, sin(a) * rr),
					Vector3(_rng.randf_range(-0.45, 0.45), _rng.randf_range(1.6, 3.2), _rng.randf_range(-0.45, 0.45)),
					_rng.randf_range(0.06, 0.13) * clampf(rad * 0.55, 0.7, 1.4),
					_rng.randf_range(0.30, 0.55),
					_slime_color(_rng.randf() < 0.25),
					false
				)
		else:
			p["bubble_cd"] = b_cd

		var m_cd: float = float(p["mist_cd"]) - dt
		if m_cd <= 0.0:
			p["mist_cd"] = _rng.randf_range(0.65, 1.50)
			var ma: float = _rng.randf_range(0.0, TAU)
			var mr: float = sqrt(_rng.randf()) * rad * 0.58
			_emit_mist(
				pool_pos + Vector3(cos(ma) * mr, 0.08, sin(ma) * mr),
				Vector3(_rng.randf_range(-0.18, 0.18), _rng.randf_range(0.38, 0.78), _rng.randf_range(-0.18, 0.18)),
				_rng.randf_range(0.28, 0.52) * clampf(rad * 0.55, 0.7, 1.4),
				_rng.randf_range(0.95, 1.65),
				_mist_color(0.38)
			)
		else:
			p["mist_cd"] = m_cd

	_sync_pools_mm()


func _sync_pools_mm() -> void:
	if _pools_mm == null or _pools_mmi == null:
		return
	var vis_n := 0
	for k in _pools:
		if vis_n >= MAX_POOLS:
			break
		var p: Dictionary = _pools[k] as Dictionary
		var age: float = float(p["age"])
		var fade_in: float = maxf(float(p["fade_in"]), 0.18)
		var fi: float = clampf(age / fade_in, 0.0, 1.0)
		var ease_fi: float = 1.0 - (1.0 - fi) * (1.0 - fi)
		var spread: float = lerpf(0.25, 1.0, ease_fi)
		var alpha: float = clampf(fi / 0.35, 0.0, 1.0)
		var gone: float = float(p["gone"])
		if gone >= 0.0:
			var fo: float = clampf(1.0 - gone / maxf(float(p["fade_out"]), 0.05), 0.0, 1.0)
			alpha *= fo
			spread *= lerpf(0.72, 1.0, fo)
		var base_b: Basis = p["basis"] as Basis
		var xf := Transform3D(Basis(base_b.x * spread, base_b.y, base_b.z * spread), p["pos"] as Vector3)
		_pools_mm.set_instance_transform(vis_n, xf)
		_pools_mm.set_instance_custom_data(vis_n, Color(float(p["seed"]), alpha, spread, float(p["pulse"])))
		vis_n += 1
	_pools_mm.visible_instance_count = vis_n
	_pools_mmi.visible = vis_n > 0


func _build_pools() -> void:
	var wide_box := AABB(Vector3(-2048.0, -256.0, -2048.0), Vector3(4096.0, 512.0, 4096.0))

	# 1. Flying sculpted 3D mucus globs pool.
	var glob_mat := _make_slime_material(0.12, 0.04, 0.80, 0.45)
	var glob_mesh: ArrayMesh = _build_slime_glob_mesh(glob_mat)
	var glob_pool: Array = _make_pool("AcidGlobs", glob_mesh, glob_mat, MAX_GLOBS, wide_box, false)
	_globs_mm = glob_pool[0] as MultiMesh
	_globs_mmi = glob_pool[1] as MultiMeshInstance3D

	# 2. Trailing, impact-splash & bubble-pop droplets pool.
	var drop_mat := _make_slime_material(0.12, 0.04, 0.80, 0.38)
	var drop_mesh: ArrayMesh = _build_drop_mesh(drop_mat)
	var drop_pool: Array = _make_pool("AcidDroplets", drop_mesh, drop_mat, MAX_DROPS, wide_box, false)
	_drops_mm = drop_pool[0] as MultiMesh
	_drops_mmi = drop_pool[1] as MultiMeshInstance3D

	# 3. Impact splash crowns pool.
	var ring_mat := _make_slime_material(0.14, 0.03, 0.75, 0.40)
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring_mat.render_priority = 2
	var ring_mesh: ArrayMesh = _build_splash_crown_mesh(ring_mat)
	var ring_pool: Array = _make_pool("AcidSplashCrowns", ring_mesh, ring_mat, MAX_RINGS, wide_box, false)
	_rings_mm = ring_pool[0] as MultiMesh
	_rings_mmi = ring_pool[1] as MultiMeshInstance3D

	# 4. Murky swamp-green soft billboard vapor/mist wisps pool.
	var mist_mat: ShaderMaterial = _make_mist_shader_material()
	var mist_mesh := QuadMesh.new()
	mist_mesh.size = Vector2(1.0, 1.0)
	mist_mesh.material = mist_mat
	var mist_pool: Array = _make_pool("AcidMist", mist_mesh, mist_mat, MAX_MIST, wide_box, false)
	_mist_mm = mist_pool[0] as MultiMesh
	_mist_mmi = mist_pool[1] as MultiMeshInstance3D

	# 5. Slimy swamp-green bubbling ground pools.
	var pool_mat: ShaderMaterial = _make_pool_shader_material()
	var pool_mesh: ArrayMesh = _build_pool_disc_mesh(pool_mat)
	var pool_pair: Array = _make_pool("AcidGroundPools", pool_mesh, pool_mat, MAX_POOLS, wide_box, true)
	_pools_mm = pool_pair[0] as MultiMesh
	_pools_mmi = pool_pair[1] as MultiMeshInstance3D


func _make_slime_material(rough: float, metal: float, clearcoat_amt: float, emit_energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = rough
	mat.metallic = metal
	mat.clearcoat_enabled = true
	mat.clearcoat = clearcoat_amt
	mat.clearcoat_roughness = 0.12
	mat.emission_enabled = true
	mat.emission = Color(0.14, 0.30, 0.04)
	mat.emission_energy_multiplier = emit_energy
	return mat


func _make_pool(node_name: String, mesh: Mesh, mat: Material, capacity: int, wide_box: AABB, use_custom: bool) -> Array:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = not use_custom
	mm.use_custom_data = use_custom
	mm.mesh = mesh
	mm.instance_count = capacity
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


func _finalize_mesh(verts: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, mat: Material) -> ArrayMesh:
	var normals := _compute_smooth_normals(verts, indices)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	if not colors.is_empty():
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
		normals[i] = n.normalized() if n.length_squared() > 1e-12 else Vector3.UP
	return normals


func _build_slime_glob_mesh(mat: Material) -> ArrayMesh:
	# Closed plump organic mucus blob (outward CW winding; head at +Z, bulbous body, rounded tail at -Z).
	const SIDES := 14
	var ring_z: PackedFloat32Array = PackedFloat32Array([-0.44, -0.24, -0.02, 0.18, 0.32])
	var ring_r: PackedFloat32Array = PackedFloat32Array([0.14, 0.30, 0.42, 0.44, 0.28])
	var ring_cols: PackedColorArray = PackedColorArray([
		Color(0.62, 0.85, 0.20, 1.0),
		Color(0.50, 0.74, 0.16, 1.0),
		Color(0.38, 0.62, 0.12, 1.0),
		Color(0.28, 0.50, 0.10, 1.0),
		Color(0.22, 0.42, 0.09, 1.0),
	])
	const RINGS := 5
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	verts.resize(2 + RINGS * SIDES)
	colors.resize(2 + RINGS * SIDES)

	verts[0] = Vector3(0.0, 0.01, -0.54)
	colors[0] = Color(0.62, 0.85, 0.20, 1.0)

	for r in RINGS:
		var z: float = ring_z[r]
		var rad: float = ring_r[r]
		var col: Color = ring_cols[r]
		for k in SIDES:
			var a: float = TAU * float(k) / float(SIDES)
			var lump: float = 1.0 + 0.13 * cos(a * 3.0 + float(r) * 0.7) + 0.07 * sin(a * 2.0 - float(r))
			var v_idx: int = 1 + r * SIDES + k
			verts[v_idx] = Vector3(cos(a) * rad * lump, sin(a) * rad * lump * 0.94, z)
			var shade: float = clampf(0.92 + 0.10 * sin(a), 0.82, 1.06)
			colors[v_idx] = Color(clampf(col.r * shade, 0.0, 1.0), clampf(col.g * shade, 0.0, 1.0), clampf(col.b * shade, 0.0, 1.0), 1.0)

	var head_idx: int = 1 + RINGS * SIDES
	verts[head_idx] = Vector3(0.0, 0.0, 0.40)
	colors[head_idx] = Color(0.22, 0.42, 0.09, 1.0)

	var indices := PackedInt32Array()
	for k in SIDES:
		var k1: int = (k + 1) % SIDES
		indices.append(0)
		indices.append(1 + k)
		indices.append(1 + k1)
	for r in (RINGS - 1):
		var ra: int = 1 + r * SIDES
		var rb: int = 1 + (r + 1) * SIDES
		for k in SIDES:
			var k1: int = (k + 1) % SIDES
			indices.append(ra + k)
			indices.append(rb + k)
			indices.append(rb + k1)
			indices.append(ra + k)
			indices.append(rb + k1)
			indices.append(ra + k1)
	var last_r: int = 1 + (RINGS - 1) * SIDES
	for k in SIDES:
		var k1: int = (k + 1) % SIDES
		indices.append(last_r + k)
		indices.append(head_idx)
		indices.append(last_r + k1)

	return _finalize_mesh(verts, colors, indices, mat)


func _build_drop_mesh(mat: Material) -> ArrayMesh:
	# Closed sculpted glossy teardrop slime droplet (outward CW winding, +Z travel).
	const SIDES := 10
	var ring_z: PackedFloat32Array = PackedFloat32Array([-0.22, -0.02, 0.16])
	var ring_r: PackedFloat32Array = PackedFloat32Array([0.09, 0.18, 0.14])
	var ring_cols: PackedColorArray = PackedColorArray([
		Color(0.62, 0.85, 0.20, 1.0),
		Color(0.38, 0.62, 0.12, 1.0),
		Color(0.22, 0.42, 0.09, 1.0),
	])
	const RINGS := 3
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	verts.resize(2 + RINGS * SIDES)
	colors.resize(2 + RINGS * SIDES)

	verts[0] = Vector3(0.0, 0.0, -0.34)
	colors[0] = Color(0.62, 0.85, 0.20, 1.0)
	for r in RINGS:
		for k in SIDES:
			var a: float = TAU * float(k) / float(SIDES)
			var v_idx: int = 1 + r * SIDES + k
			verts[v_idx] = Vector3(cos(a) * ring_r[r], sin(a) * ring_r[r], ring_z[r])
			colors[v_idx] = ring_cols[r]
	var head_idx: int = 1 + RINGS * SIDES
	verts[head_idx] = Vector3(0.0, 0.0, 0.25)
	colors[head_idx] = Color(0.22, 0.42, 0.09, 1.0)

	var indices := PackedInt32Array()
	for k in SIDES:
		var k1: int = (k + 1) % SIDES
		indices.append(0)
		indices.append(1 + k)
		indices.append(1 + k1)
	for r in (RINGS - 1):
		var ra: int = 1 + r * SIDES
		var rb: int = 1 + (r + 1) * SIDES
		for k in SIDES:
			var k1: int = (k + 1) % SIDES
			indices.append(ra + k)
			indices.append(rb + k)
			indices.append(rb + k1)
			indices.append(ra + k)
			indices.append(rb + k1)
			indices.append(ra + k1)
	var last_r: int = 1 + (RINGS - 1) * SIDES
	for k in SIDES:
		var k1: int = (k + 1) % SIDES
		indices.append(last_r + k)
		indices.append(head_idx)
		indices.append(last_r + k1)
	return _finalize_mesh(verts, colors, indices, mat)


func _build_splash_crown_mesh(mat: Material) -> ArrayMesh:
	# Low, sleek liquid splash crown ring (outward CW winding) with undulating droplet crest.
	const SEGS := 32
	const RINGS := 3
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	verts.resize(RINGS * SEGS)
	colors.resize(RINGS * SEGS)

	for k in SEGS:
		var a: float = TAU * float(k) / float(SEGS)
		var ca: float = cos(a)
		var sa: float = sin(a)
		var wave: float = pow(0.5 + 0.5 * sin(a * 7.0 + 0.4) * cos(a * 3.0 - 0.5), 1.5)
		var r0: float = 0.46 + 0.04 * sin(a * 3.0)
		var r1: float = 0.72 + 0.07 * wave
		var r2: float = 0.96 + 0.12 * wave
		verts[k] = Vector3(ca * r0, 0.0, sa * r0)
		colors[k] = Color(0.28, 0.52, 0.11, 1.0)
		verts[SEGS + k] = Vector3(ca * r1, 0.10 + 0.12 * wave, sa * r1)
		colors[SEGS + k] = Color(0.46, 0.74, 0.16, 1.0)
		verts[SEGS * 2 + k] = Vector3(ca * r2, 0.18 + 0.24 * wave, sa * r2)
		colors[SEGS * 2 + k] = Color(0.68, 0.92, 0.24, 1.0)

	var indices := PackedInt32Array()
	for r in (RINGS - 1):
		var ra: int = r * SEGS
		var rb: int = (r + 1) * SEGS
		for k in SEGS:
			var k1: int = (k + 1) % SEGS
			indices.append(ra + k)
			indices.append(ra + k1)
			indices.append(rb + k)
			indices.append(ra + k1)
			indices.append(rb + k1)
			indices.append(rb + k)
	return _finalize_mesh(verts, colors, indices, mat)


func _make_mist_shader_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode blend_mix, depth_draw_never, unshaded, cull_disabled;

varying vec4 v_col;

void vertex() {
	v_col = COLOR;
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	mat4 mv = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0] * sx,
		INV_VIEW_MATRIX[1] * sy,
		INV_VIEW_MATRIX[2] * sx,
		MODEL_MATRIX[3]
	);
	MODELVIEW_MATRIX = mv;
	MODELVIEW_NORMAL_MATRIX = mat3(mv);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r2 = dot(p, p);
	if (r2 >= 1.0) {
		discard;
	}
	float r = sqrt(r2);
	float ang = atan(p.y, p.x);
	float wisp = 0.85 + 0.15 * sin(ang * 3.0 + v_col.r * 12.0) * cos(ang * 2.0 - r2 * 4.0);
	float soft = exp(-r2 * 3.8) * (1.0 - smoothstep(0.55, 1.0, r)) * wisp;
	ALBEDO = pow(clamp(v_col.rgb, vec3(0.0), vec3(1.0)), vec3(2.2));
	ALPHA = v_col.a * soft;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.render_priority = 2
	return mat


func _build_pool_disc_mesh(mat: Material) -> ArrayMesh:
	# Subdivided radial liquid meniscus disc (+Y upward CW winding, radius 1.0, dome height 0.024 * (1 - r^2)).
	const SEGS := 32
	const RINGS := 5
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(1 + RINGS * SEGS)
	uvs.resize(1 + RINGS * SEGS)

	verts[0] = Vector3(0.0, 0.024, 0.0)
	uvs[0] = Vector2(0.5, 0.5)
	for r in RINGS:
		var frac: float = float(r + 1) / float(RINGS)
		var y: float = 0.024 * (1.0 - frac * frac)
		for k in SEGS:
			var a: float = TAU * float(k) / float(SEGS)
			var vx: float = cos(a) * frac
			var vz: float = sin(a) * frac
			var v_idx: int = 1 + r * SEGS + k
			verts[v_idx] = Vector3(vx, y, vz)
			uvs[v_idx] = Vector2(0.5 + vx * 0.5, 0.5 + vz * 0.5)

	var indices := PackedInt32Array()
	for k in SEGS:
		var k1: int = (k + 1) % SEGS
		indices.append(0)
		indices.append(1 + k)
		indices.append(1 + k1)
	for r in (RINGS - 1):
		var ra: int = 1 + r * SEGS
		var rb: int = 1 + (r + 1) * SEGS
		for k in SEGS:
			var k1: int = (k + 1) % SEGS
			indices.append(ra + k)
			indices.append(rb + k)
			indices.append(rb + k1)
			indices.append(ra + k)
			indices.append(rb + k1)
			indices.append(ra + k1)

	var normals := _compute_smooth_normals(verts, indices)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, mat)
	return mesh


func _make_pool_shader_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_schlick_ggx;

varying vec4 v_pool;
varying vec2 v_uv_p;
varying vec3 v_right_w;
varying vec3 v_fwd_w;

float _hash2(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec2 _hash22(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy) * 2.0 - 1.0;
}

float _vnoise2(vec2 p) {
	const float K1 = 0.366025404;
	const float K2 = 0.211324865;
	vec2 i = floor(p + (p.x + p.y) * K1);
	vec2 a = p - i + (i.x + i.y) * K2;
	float m = step(a.y, a.x);
	vec2 o = vec2(m, 1.0 - m);
	vec2 b = a - o + K2;
	vec2 c = a - 1.0 + 2.0 * K2;
	vec3 h = max(0.5 - vec3(dot(a, a), dot(b, b), dot(c, c)), 0.0);
	vec3 n = h * h * h * h * vec3(
		dot(a, _hash22(i)),
		dot(b, _hash22(i + o)),
		dot(c, _hash22(i + 1.0))
	);
	return clamp(dot(n, vec3(70.0)) * 0.5 + 0.5, 0.0, 1.0);
}

float _fbm2(vec2 p) {
	float v = 0.0;
	float a = 0.55;
	mat2 rot = mat2(vec2(0.8, -0.6), vec2(0.6, 0.8));
	for (int i = 0; i < 3; i++) {
		v += a * _vnoise2(p);
		p = rot * p * 2.03 + vec2(13.1, 7.7);
		a *= 0.48;
	}
	return v;
}

void vertex() {
	v_pool = INSTANCE_CUSTOM;
	v_uv_p = VERTEX.xz;
	v_right_w = normalize((MODEL_MATRIX * vec4(1.0, 0.0, 0.0, 0.0)).xyz);
	v_fwd_w = normalize((MODEL_MATRIX * vec4(0.0, 0.0, 1.0, 0.0)).xyz);
	float r2 = clamp(dot(VERTEX.xz, VERTEX.xz), 0.0, 1.0);
	float fall = 1.0 - r2;
	float wob = sin(TIME * 2.4 * max(v_pool.w, 0.5) + v_pool.x * 5.7 + VERTEX.x * 4.2)
		* cos(TIME * 1.9 * max(v_pool.w, 0.5) + VERTEX.z * 4.6);
	VERTEX.y += fall * wob * 0.008;
}

void fragment() {
	float seed = v_pool.x;
	float pool_alpha = v_pool.y;
	float rate = max(v_pool.w, 0.5);

	float rad = length(v_uv_p);
	float ang = atan(v_uv_p.y, v_uv_p.x);
	vec2 dir_p = vec2(cos(ang), sin(ang));
	float n_edge = _fbm2(dir_p * 1.8 + vec2(seed * 0.37, seed * 0.71) + TIME * 0.035);
	float n_detail = _vnoise2(v_uv_p * 4.2 + vec2(seed * 1.13, -TIME * 0.08));
	float rim_rad = 0.62 + 0.24 * n_edge + 0.07 * n_detail;
	float body_mask = 1.0 - smoothstep(rim_rad - 0.14, rim_rad + 0.03, rad);
	float stain_mask = 1.0 - smoothstep(rim_rad - 0.02, min(rim_rad + 0.14, 0.99), rad);
	float alpha = max(body_mask * 0.94, stain_mask * 0.40) * pool_alpha;
	if (alpha < 0.015) {
		discard;
	}

	// Smooth isotropic 2D simplex ooze flow inside the swamp pool.
	vec2 q = vec2(
		_vnoise2(v_uv_p * 1.5 + vec2(seed * 0.19, TIME * 0.055 * rate)),
		_vnoise2(v_uv_p * 1.5 + vec2(5.2 + seed * 0.31, -TIME * 0.048 * rate))
	);
	float flow = _fbm2(v_uv_p * 2.2 + q * 0.45 + vec2(TIME * 0.04, -TIME * 0.035));

	// Rotated multi-scale cellular swelling & popping acid bubbles (zero grid alignment or clipping).
	float bubble_lift = 0.0;
	float bubble_rim = 0.0;
	float pop_flash = 0.0;
	vec2 b_grad = vec2(0.0);
	mat2 b_rot = mat2(vec2(0.8, -0.6), vec2(0.6, 0.8));
	for (int pass = 0; pass < 2; pass++) {
		float freq = pass == 0 ? 2.6 : 4.2;
		vec2 p_uv = pass == 0 ? v_uv_p : (b_rot * v_uv_p);
		vec2 buv = p_uv * freq + vec2(seed * 0.41 + float(pass) * 19.3);
		vec2 cell = floor(buv);
		vec2 fuv = fract(buv) - 0.5;
		float h0 = _hash2(cell + vec2(seed * 0.17, float(pass) * 7.1));
		float h1 = _hash2(cell + vec2(37.2, 91.7 + float(pass) * 11.3));
		if (h0 > 0.38) {
			vec2 off = vec2(h0 - 0.69, h1 - 0.5) * 0.22;
			float phase = fract(TIME * (0.42 + h1 * 0.45) * rate + h0 * 7.3);
			float swell = sin(min(phase / 0.85, 1.0) * 3.14159265);
			float b_rad = (0.12 + 0.16 * swell) * (pass == 0 ? 1.0 : 0.82);
			vec2 dp = fuv - off;
			float bd = length(dp);
			float dome = 1.0 - smoothstep(b_rad * 0.35, b_rad, bd);
			float b_edge = smoothstep(b_rad * 0.35, b_rad * 0.72, bd) * (1.0 - smoothstep(b_rad * 0.72, b_rad * 1.06, bd));
			float bursting = smoothstep(0.74, 0.88, phase) * (1.0 - smoothstep(0.88, 0.98, phase));
			float fade_b = 1.0 - smoothstep(0.88, 0.98, phase);
			bubble_lift = max(bubble_lift, dome * swell * fade_b);
			bubble_rim = max(bubble_rim, (b_edge * 0.85 + bursting * b_edge * 0.65) * fade_b);
			pop_flash = max(pop_flash, bursting * (b_edge + dome * 0.35) * fade_b);
			if (bd > 0.002 && bd < b_rad * 1.06) {
				b_grad += (dp / bd) * (dome + b_edge * 0.4) * swell * fade_b * 0.20;
			}
		}
	}

	// Slimy swamp-green palette (linear RGB) with darker murky outer border for strong contrast.
	vec3 bog_deep = vec3(0.022, 0.064, 0.010);
	vec3 moss_mid = vec3(0.072, 0.155, 0.019);
	vec3 slime_froth = vec3(0.195, 0.315, 0.036);
	vec3 earth_edge = vec3(0.011, 0.022, 0.005);

	float core_w = 1.0 - smoothstep(0.0, max(rim_rad * 0.92, 0.1), rad);
	vec3 base_col = mix(bog_deep, moss_mid, smoothstep(0.25, 0.75, flow));
	base_col = mix(earth_edge, base_col, smoothstep(0.08, 0.65, body_mask));
	float froth = clamp(smoothstep(0.60, 0.88, flow) * 0.42 + bubble_rim * 0.80 + smoothstep(0.55, 0.95, bubble_lift) * 0.28 + (1.0 - body_mask) * stain_mask * 0.18, 0.0, 1.0);
	vec3 col = mix(base_col, slime_froth, froth * (0.45 + 0.55 * core_w));

	// Wet organic surface normal perturbation transformed into view space (+Y base normal).
	float eps = 0.03;
	float fx = _vnoise2((v_uv_p + vec2(eps, 0.0)) * 5.2 + q) - _vnoise2((v_uv_p - vec2(eps, 0.0)) * 5.2 + q);
	float fz = _vnoise2((v_uv_p + vec2(0.0, eps)) * 5.2 + q) - _vnoise2((v_uv_p - vec2(0.0, eps)) * 5.2 + q);
	vec3 w_off = v_right_w * (-fx * 0.75 - b_grad.x) + v_fwd_w * (-fz * 0.75 - b_grad.y);
	NORMAL = normalize(NORMAL + (VIEW_MATRIX * vec4(w_off, 0.0)).xyz);

	ALBEDO = col;
	ROUGHNESS = mix(0.10, 0.24, froth);
	SPECULAR = 0.70;
	METALLIC = 0.04;
	CLEARCOAT = 0.75;
	CLEARCOAT_ROUGHNESS = 0.16;
	EMISSION = vec3(0.10, 0.19, 0.020) * (0.26 * froth + 0.50 * pop_flash + 0.10) * body_mask;
	ALPHA = alpha;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.render_priority = 1
	return mat


func _pool_basis(normal: Vector3, yaw: float, radius_x: float, radius_z: float) -> Basis:
	var ref_fwd := Vector3(sin(yaw), 0.0, cos(yaw))
	var right: Vector3 = normal.cross(ref_fwd)
	if right.length_squared() < 0.0001:
		right = Vector3.RIGHT
	else:
		right = right.normalized()
	var fwd: Vector3 = right.cross(normal).normalized()
	return Basis(right * radius_x, normal, fwd * radius_z)


func _slime_color(dark_head: bool) -> Color:
	if dark_head:
		return Color(
			_rng.randf_range(0.36, 0.52),
			_rng.randf_range(0.62, 0.82),
			_rng.randf_range(0.12, 0.22),
			1.0
		)
	return Color(
		_rng.randf_range(0.52, 0.70),
		_rng.randf_range(0.78, 0.94),
		_rng.randf_range(0.16, 0.28),
		1.0
	)


func _mist_color(alpha: float) -> Color:
	return Color(
		_rng.randf_range(0.32, 0.42),
		_rng.randf_range(0.54, 0.66),
		_rng.randf_range(0.10, 0.16),
		alpha
	)
