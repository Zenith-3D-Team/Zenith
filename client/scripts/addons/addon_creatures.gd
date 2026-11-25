extends RefCounted
## api.creatures (1.9): client-only enemy damage/death hooks, ragdoll node, per-limb & split-body
## shader helpers (rig_mode 5, blood/bullet wounds), blood puddle decals, live creature animation
## overrides, transient pack overrides, and terrain/solid collision queries. Cleared automatically
## on addon_stop() and game_ended().

const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const CreatureModels := preload("res://scripts/world/creature_models.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const WorldMirror := preload("res://scripts/world/world.gd")
const RagdollShader := preload("res://shaders/factorio_material_ragdoll.gdshader")

## Fired when a combat hit/burn effect (`afx`) arrives for a unit.
## Keys: unit (int), name (String), pos (Vector3), cause_pos (Vector3 or null),
## damage_type (String), fx (String), dmg (int), hp (int), src (String).
signal damaged(info: Dictionary)

## Fired when a creature dies (`died`).
## Keys: unit (int), name (String), pos (Vector3), yaw (float), vel (Vector3), scale (float),
## phase (float), cause_pos (Vector3 or null), damage_type (String), dmg (int), src (String),
## handled (bool). Setting info["handled"] = true skips Zenith's default collapse and corpse.
signal died(info: Dictionary)

## Fired when a flying stream effect (`pj` stream, such as acid spit) starts, ends, or resets.
## For `"start"`, keys: event, id, name, pos, from, to, hs, va, pst, psi, handled.
## Setting info["handled"] = true lets an add-on render the 3D stream instead of WeaponFx cards.
signal stream_event(info: Dictionary)

## Fired when a ground fire/acid pool (`gf`) starts, ends, or resets.
## For `"start"`, keys: event, id, name, pos, fade_in, fade_out, handled.
## Setting info["handled"] = true lets an add-on render the 3D pool instead of WeaponFx cards.
signal ground_fx(info: Dictionary)

const NON_SOLID_TYPES := {
	"resource": true,
	"transport-belt": true,
	"underground-belt": true,
	"splitter": true,
	"straight-rail": true,
	"curved-rail-a": true,
	"curved-rail-b": true,
	"half-diagonal-rail": true,
	"elevated-straight-rail": true,
	"elevated-curved-rail-a": true,
	"elevated-curved-rail-b": true,
	"elevated-half-diagonal-rail": true,
	"item-entity": true,
	"fish": true,
	"corpse": true,
	"entity-ghost": true,
	"tile-ghost": true,
	"rail-signal": true,
	"rail-chain-signal": true,
	"land-mine": true,
}

const PART_IDS := {"head": 0, "thorax": 1, "abdomen": 2}
const SPLIT_HEAD_Z := -0.42
const SPLIT_ABDOMEN_Z := 0.36
const WORM_HEAD_Y := 2.55
const WORM_ABDOMEN_Y := 1.25

var _host
var _api
var _anim_enabled := false
var _wounded_units := {}  # unit -> true (live wounds set by this add-on)
var _pack_overrides := {}  # family -> pack_id (transient overrides set by this add-on)
## "proto:limb" or "proto:part:<part>" -> {"mesh", "mats", "centroid", "src"} or {"none", "src"}. An entry
## stays good while ModelLibrary still gives `src` for the proto. (Before, the whole cache went whenever
## ModelLibrary.generation rose, which is each time any model finishes loading, so the next explosive
## kill re-cut every tier's legs and parts in one frame: ~30 ms per tier.) --enemies-burst=old: as before.
static var _leg_cache := {}
static var _leg_gen := -1
static var _precut_jobs := {}  # proto -> [task id, its model's mesh, key -> plan]


func _init(host, api) -> void:
	_host = host
	_api = api


## Creates an unparented MeshInstance3D for `proto` with cloned ShaderMaterials set to
## rig_mode = 5 (per-limb ragdoll posing) and the ragdoll/decay/wounds shader, keeping all rig_*
## and skin tint uniforms. Returns null if the model is not ready.
func make_ragdoll_node(proto: String) -> MeshInstance3D:
	if proto == "" or not ModelLibrary.ready(proto):
		return null
	var mesh := ModelLibrary.mesh_for(proto)
	if mesh == null:
		return null
	var node := MeshInstance3D.new()
	node.mesh = mesh
	var zeros: Array[Vector4] = []
	zeros.resize(12)
	zeros.fill(Vector4.ZERO)
	var zero_holes := _zero_holes()
	for i in mesh.get_surface_count():
		var mat := mesh.surface_get_material(i) as ShaderMaterial
		if mat == null:
			continue
		var copy := ModelLods.copy_material(mat)
		copy.shader = RagdollShader
		copy.set_shader_parameter("rig_mode", 5)
		copy.set_shader_parameter("rig_ragdoll", zeros)
		copy.set_shader_parameter("rig_decay", 0.0)
		copy.set_shader_parameter("rig_decay_floor", 0.0)
		copy.set_shader_parameter("rig_blood", 0.0)
		copy.set_shader_parameter("rig_burn", 0.0)
		copy.set_shader_parameter("rig_holes", zero_holes)
		node.set_surface_override_material(i, copy)
	return node


## Extracts and caches an unparented single-limb MeshInstance3D for limb index `limb_idx` of
## `proto`, centred around its bounding centroid so it can fly/spin independently with rig_decay
## and rig_blood support. Returns null if the model isn't ready or has no vertices for `limb_idx`.
func make_ragdoll_leg_node(proto: String, limb_idx: int) -> MeshInstance3D:
	if proto == "" or limb_idx < 0 or limb_idx >= 12 or not ModelLibrary.ready(proto):
		return null
	var key := "%s:%d" % [proto, limb_idx]
	var cached: Variant = _slice_cached(key, proto, _extract_leg_entry.bind(proto, limb_idx))
	if cached == null:
		return null
	var entry: Dictionary = cached
	var leg_mesh := entry["mesh"] as ArrayMesh
	var mats: Array = entry["mats"] as Array
	var node := MeshInstance3D.new()
	node.mesh = leg_mesh
	node.set_meta(&"leg_centroid", entry.get("centroid", Vector3.ZERO))
	var zero_holes := _zero_holes()
	for i in mats.size():
		var mat := mats[i] as ShaderMaterial
		if mat != null:
			var copy := ModelLods.copy_material(mat)
			copy.set_shader_parameter("rig_decay", 0.0)
			copy.set_shader_parameter("rig_decay_floor", 0.0)
			copy.set_shader_parameter("rig_blood", 0.0)
			copy.set_shader_parameter("rig_burn", 0.0)
			copy.set_shader_parameter("rig_holes", zero_holes)
			node.set_surface_override_material(i, copy)
	return node


## Extracts and caches an unparented solid body-chunk MeshInstance3D for `part` ("head", "thorax",
## or "abdomen") of `proto`, partitioned along Z relative to tier scale with a closed bloody
## purple-violet inner-meat cross-section cap fan along cut boundaries. Sets `"part_centroid"`
## metadata. Returns null if the model isn't ready or has no triangles for `part`.
func make_ragdoll_part_node(proto: String, part: String) -> MeshInstance3D:
	if proto == "" or not PART_IDS.has(part) or not ModelLibrary.ready(proto):
		return null
	var key := "%s:part:%s" % [proto, part]
	var cached: Variant = _slice_cached(key, proto, _extract_part_entry.bind(proto, part))
	if cached == null:
		return null
	var entry: Dictionary = cached
	var part_mesh := entry["mesh"] as ArrayMesh
	var mats: Array = entry["mats"] as Array
	var node := MeshInstance3D.new()
	node.mesh = part_mesh
	node.set_meta(&"part_centroid", entry.get("centroid", Vector3.ZERO))
	var zero_holes := _zero_holes()
	for i in mats.size():
		var mat := mats[i] as ShaderMaterial
		if mat != null:
			var copy := ModelLods.copy_material(mat)
			copy.set_shader_parameter("rig_decay", 0.0)
			copy.set_shader_parameter("rig_decay_floor", 0.0)
			copy.set_shader_parameter("rig_blood", 0.0)
			copy.set_shader_parameter("rig_burn", 0.0)
			copy.set_shader_parameter("rig_holes", zero_holes)
			node.set_surface_override_material(i, copy)
	return node


## Sets the per-limb ragdoll pose uniform array `rig_ragdoll[12]` on all ShaderMaterial surfaces
## of `node`. Each Vector3 is (swing, lift, knee) in radians; optional `twists` sets `.w` per limb
## (pass > 50.0 to collapse a severed leg into its hip socket).
func set_ragdoll_limbs(node: MeshInstance3D, limbs: PackedVector3Array, twists := PackedFloat32Array()) -> void:
	if node == null or not is_instance_valid(node) or node.mesh == null:
		return
	var arr: Array[Vector4] = []
	arr.resize(12)
	var n := mini(limbs.size(), 12)
	for i in n:
		var v := limbs[i]
		var tw: float = float(twists[i]) if i < twists.size() else 0.0
		arr[i] = Vector4(v.x, v.y, v.z, tw)
	for i in range(n, 12):
		arr[i] = Vector4.ZERO
	for i in node.mesh.get_surface_count():
		var mat := node.get_surface_override_material(i) as ShaderMaterial
		if mat != null:
			mat.set_shader_parameter("rig_ragdoll", arr)


## Sets `rig_decay` (0..1) and optional world `rig_decay_floor` on all ShaderMaterial surfaces of `node`.
func set_ragdoll_decay(node: MeshInstance3D, decay: float, floor_y := NAN) -> void:
	if node == null or not is_instance_valid(node) or node.mesh == null:
		return
	var d := clampf(decay, 0.0, 1.0)
	var has_floor := not is_nan(floor_y)
	for i in node.mesh.get_surface_count():
		var mat := node.get_surface_override_material(i) as ShaderMaterial
		if mat != null:
			mat.set_shader_parameter("rig_decay", d)
			if has_floor:
				mat.set_shader_parameter("rig_decay_floor", floor_y)


## Sets bloodiness `rig_blood` (0..1) and up to 6 model-space bullet/shrapnel holes `rig_holes[6]`
## (`Vector4(x, y, z, radius)` in the node's local mesh space) on all ShaderMaterial surfaces of `node`.
func set_ragdoll_wounds(node: MeshInstance3D, blood: float, holes: Array) -> void:
	if node == null or not is_instance_valid(node) or node.mesh == null:
		return
	var b := clampf(blood, 0.0, 1.0)
	var h_arr := _zero_holes()
	var n := mini(holes.size(), 6)
	for i in n:
		var item: Variant = holes[i]
		if item is Vector4:
			h_arr[i] = item as Vector4
	for i in node.mesh.get_surface_count():
		var mat := node.get_surface_override_material(i) as ShaderMaterial
		if mat != null:
			mat.set_shader_parameter("rig_blood", b)
			mat.set_shader_parameter("rig_holes", h_arr)


## Sets `rig_burn` (0..1) charring & glowing ember state on all ShaderMaterial surfaces of `node`.
func set_ragdoll_burn(node: MeshInstance3D, burn: float) -> void:
	if node == null or not is_instance_valid(node) or node.mesh == null:
		return
	var b := clampf(burn, 0.0, 1.0)
	for i in node.mesh.get_surface_count():
		var mat := node.get_surface_override_material(i) as ShaderMaterial
		if mat != null:
			mat.set_shader_parameter("rig_burn", b)


## Sets live bloodiness (0..1) and bullet-hit count (0..8) on a living creature `unit` (walker in
## Creatures or static worm/spawner in Anim), promoting walkers out of GPU-walker mode while
## wounded; pass 0.0, 0 to clear. Cleared on death and teardown.
func set_unit_wounds(unit: int, blood: float, hits: int) -> void:
	var b := clampf(blood, 0.0, 1.0)
	var h := clampi(hits, 0, 8)
	if b <= 0.001 and h <= 0:
		_wounded_units.erase(unit)
	else:
		_wounded_units[unit] = true
	var c = _creatures()
	if c != null:
		c.set_unit_wounds(unit, b, h)
	var anim = _animator()
	if anim != null and anim.has_method("set_unit_wounds"):
		anim.set_unit_wounds(unit, b, h)


## Sets a transient runtime model-pack override for `family` (e.g. "big-biter" ->
## "builtin:placeholders"). Applies only when the player has no explicit pack choice for `family`
## and never modifies settings.cfg. Pass `""` to clear; automatically cleared on clear()/stop.
func set_pack_override(family: String, pack_id: String) -> void:
	var fam := family.strip_edges().to_lower()
	if fam == "":
		return
	var pid := pack_id.strip_edges()
	if pid == "":
		_pack_overrides.erase(fam)
	else:
		_pack_overrides[fam] = pid
	if _host != null and _host.has_method("_sync_creature_pack_overrides"):
		_host._sync_creature_pack_overrides([fam])
	else:
		var prev := str(ModelLibrary.addon_pack_overrides.get(fam, ""))
		if pid == "":
			ModelLibrary.addon_pack_overrides.erase(fam)
		else:
			ModelLibrary.addon_pack_overrides[fam] = pid
		if prev != pid:
			ModelLibrary.choices_changed([fam])


## Returns the scaled rig dictionary from CreatureModels.rig for `proto`, plus `"scale": float`.
func rig_info(proto: String) -> Dictionary:
	var alias: Variant = CreatureModels.ALIASES.get(proto)
	var base := str(alias[0]) if alias is Array else CreatureModels.base_model(proto)
	var model := base if base != "" else proto
	var scale := float(alias[1]) if alias is Array else 1.0
	var raw := CreatureModels.rig(model)
	if raw.is_empty():
		return {}
	var out: Dictionary = raw.duplicate(true)
	out["scale"] = scale
	if out.has("limbs") and out["limbs"] is Array:
		var limbs: Array = out["limbs"]
		for limb in limbs:
			if not (limb is Dictionary):
				continue
			var ld: Dictionary = limb
			if ld.has("joint") and ld["joint"] is Array:
				var j: Array = ld["joint"]
				if j.size() >= 3:
					ld["joint"] = [float(j[0]) * scale, float(j[1]) * scale, float(j[2]) * scale]
			if ld.has("knee") and ld["knee"] is Array:
				var k: Array = ld["knee"]
				if k.size() >= 3:
					ld["knee"] = [float(k[0]) * scale, float(k[1]) * scale, float(k[2]) * scale]
			if ld.has("reach"):
				ld["reach"] = float(ld["reach"]) * scale
	if out.has("body") and out["body"] is Array:
		var b: Array = out["body"]
		if b.size() >= 3:
			out["body"] = [float(b[0]) * scale, float(b[1]), float(b[2]) * scale]
	return out


## Places a Factorio blood puddle decal at `pos` via Creatures.
func add_blood_puddle(pos: Vector3, scale := 1.0) -> void:
	var c = _creatures()
	if c != null:
		c.add_blood_puddle(pos, scale)


## Enables or disables live creature animation overrides for this add-on.
func set_anim_enabled(on: bool) -> void:
	_anim_enabled = on
	if _host != null:
		_host._update_creatures_anim()


## Sets a temporary animation override for a live creature `unit`.
## Keys: pitch, roll, yaw_offset, offset (Vector3), gait_mul, bite_mul, ttl (float).
func set_unit_override(unit: int, data: Dictionary) -> void:
	var c = _creatures()
	if c != null:
		c.set_unit_override(unit, data)


## Lists live creatures whose prototype name contains `prefix` (or all when `prefix == ""`).
## Each item: {unit, name, pos, yaw, speed, attacking, scale}.
func list_live(prefix := "") -> Array:
	var c = _creatures()
	if c == null:
		return []
	return c.list_live(prefix)


## Ground elevation (tiles) at world (x, z), from GroundHeight.at.
func ground_height(x: float, z: float) -> float:
	return GroundHeight.at(x, z)


## Upward ground surface normal at world (x, z); Vector3.UP when flat.
func ground_normal(x: float, z: float) -> Vector3:
	if not GroundHeight.is_on():
		return Vector3.UP
	const STEP := 0.5
	var dx := GroundHeight.at(x + STEP, z) - GroundHeight.at(x - STEP, z)
	var dz := GroundHeight.at(x, z + STEP) - GroundHeight.at(x, z - STEP)
	return Vector3(-dx, 2.0 * STEP, -dz).normalized()


## True when a solid static entity (wall, turret, building, rock, cliff, tree, spawner) occupies
## tile (floor(x), floor(z)).
func solid_at(x: float, z: float) -> bool:
	if _host == null:
		return false
	var world = _host.game_node("world")
	if world == null or not world.has_method("pick") or world.get("protos") == null:
		return false
	var rec: WorldMirror.Rec = world.pick(Vector2(floorf(x) + 0.5, floorf(z) + 0.5))
	if rec == null or rec.extra.has("gh"):
		return false
	var proto: ProtoDB.EntityProto = world.protos.entity(rec.proto_id)
	if proto == null:
		return false
	return not NON_SOLID_TYPES.has(proto.type)


## Clears this add-on's creature animation state, live wounds, and transient pack overrides.
func clear() -> void:
	_anim_enabled = false
	var c = _creatures()
	var anim = _animator()
	if not _wounded_units.is_empty():
		for unit in _wounded_units.keys():
			if c != null:
				c.set_unit_wounds(int(unit), 0.0, 0)
			if anim != null and anim.has_method("set_unit_wounds"):
				anim.set_unit_wounds(int(unit), 0.0, 0)
	_wounded_units.clear()
	var fams: Array = _pack_overrides.keys()
	_pack_overrides.clear()
	if _host != null:
		_host._update_creatures_anim()
		if not fams.is_empty() and _host.has_method("_sync_creature_pack_overrides"):
			_host._sync_creature_pack_overrides(fams)
	elif not fams.is_empty():
		for fam: String in fams:
			ModelLibrary.addon_pack_overrides.erase(fam)
		ModelLibrary.choices_changed(fams)


func _creatures():
	return _host.creatures_node() if _host != null else null


func _animator():
	if _host == null:
		return null
	var w = _host.game_node("world") if _host.has_method("game_node") else null
	if w == null and not _host.has_method("game_node"):
		var main_node = _host.get("main")
		if main_node is Object and is_instance_valid(main_node):
			w = main_node.get("world")
	if not (w is Object) or not is_instance_valid(w):
		return null
	var anim = w.get("animator")
	return anim if anim is Object and is_instance_valid(anim) else null


static func _zero_holes() -> Array[Vector4]:
	var arr: Array[Vector4] = []
	arr.resize(6)
	arr.fill(Vector4.ZERO)
	return arr


## (Zenith 0.3.0; optional, check has_method) Cuts `proto`'s three split parts and its first `limbs`
## legs (0-12) on a worker thread, ahead of its first explosive death (each cut is 7-25 ms of GDScript;
## a horde's first grenade cut a few tiers' worth in one frame). Call it again later: true once they
## are cut (or the model has none), false while the model loads or the cutting runs.
func precut(proto: String, limbs := 0) -> bool:
	if proto == "" or not ModelLibrary.ready(proto):
		return false
	var mesh := ModelLibrary.mesh_for(proto)
	if mesh == null:
		return true
	if _precut_jobs.has(proto):
		if not WorkerThreadPool.is_task_completed(int((_precut_jobs[proto] as Array)[0])):
			return false
		_finish_precut(proto)
		return true
	var wanted: Array = []  # [key, part name or limb index]
	for part: String in PART_IDS:
		wanted.append(["%s:part:%s" % [proto, part], part])
	for li in clampi(limbs, 0, 12):
		wanted.append(["%s:%d" % [proto, li], li])
	var todo: Array = []
	for w: Array in wanted:
		var rec: Variant = _leg_cache.get(str(w[0]))
		if not (rec is Dictionary) or (rec as Dictionary).get("src") != mesh:
			todo.append(w)
	if todo.is_empty():
		return true
	var plans := {}
	var task := WorkerThreadPool.add_task(_precut_plans.bind(_surfaces_info(mesh), todo, _split_scale(proto),
		proto.contains("worm"), plans), false, "ragdoll cuts " + proto)
	_precut_jobs[proto] = [task, mesh, plans]
	return false


## The worker's part of precut(): every wanted cut as arrays (pure arithmetic).
static func _precut_plans(surfaces: Array, todo: Array, scale: float, is_worm: bool, out: Dictionary) -> void:
	for w: Array in todo:
		if w[1] is String:
			out[w[0]] = _part_plan(surfaces, int(PART_IDS[w[1]]), scale, is_worm)
		else:
			out[w[0]] = _leg_plan(surfaces, int(w[1]))


## Waits for `proto`'s precut job and turns its plans into cached meshes (main thread).
static func _finish_precut(proto: String) -> void:
	var job: Array = _precut_jobs[proto]
	_precut_jobs.erase(proto)
	WorkerThreadPool.wait_for_task_completion(int(job[0]))
	var mesh: Mesh = job[1]
	if ModelLibrary.mesh_for(proto) != mesh:
		return  # the model changed meanwhile: these cuts are of the old one
	var plans: Dictionary = job[2]
	for key: String in plans:
		var made: Variant = _assemble(mesh, plans[key])
		var rec: Dictionary = made if made is Dictionary else {"none": true}
		rec["src"] = mesh
		_leg_cache[key] = rec


## A cut leg/part of `proto` from the cache, cut again (by `maker`) only when the proto's model changed;
## null when the model has none.
func _slice_cached(key: String, proto: String, maker: Callable) -> Variant:
	if "--enemies-burst=old" in OS.get_cmdline_user_args():
		if _leg_gen != ModelLibrary.generation:
			_leg_cache.clear()
			_leg_gen = ModelLibrary.generation
		if not _leg_cache.has(key):
			var made_old: Variant = maker.call()
			_leg_cache[key] = made_old if made_old is Dictionary else {"none": true}
		var old_rec: Dictionary = _leg_cache[key]
		return null if old_rec.has("none") else old_rec
	var src: Mesh = ModelLibrary.mesh_for(proto)
	var rec: Variant = _leg_cache.get(key)
	if _precut_jobs.has(proto) and (not (rec is Dictionary) or (rec as Dictionary).get("src") != src):
		_finish_precut(proto)  # being cut on a worker: wait for it rather than cut it twice
		rec = _leg_cache.get(key)
	if not (rec is Dictionary) or (rec as Dictionary).get("src") != src:
		var made: Variant = maker.call()
		var fresh: Dictionary = made if made is Dictionary else {"none": true}
		fresh["src"] = src
		_leg_cache[key] = fresh
		rec = fresh
	var d: Dictionary = rec
	return null if d.has("none") else d


func _extract_leg_entry(proto: String, limb_idx: int) -> Variant:
	var mesh := ModelLibrary.mesh_for(proto)
	if mesh == null:
		return null
	return _assemble(mesh, _leg_plan(_surfaces_info(mesh), limb_idx))


## The model's triangle surfaces' arrays, read once (main thread): [{s, fmt, src}].
static func _surfaces_info(mesh: Mesh) -> Array:
	var out: Array = []
	for s in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var src := ModelLods.arrays_of(mesh, s)
		if src.is_empty():
			continue
		out.append({"s": s, "fmt": mesh.surface_get_format(s), "src": src})
	return out


## A leg's cut, as arrays only (pure arithmetic, safe on a worker thread); null when it has none.
static func _leg_plan(surfaces: Array, limb_idx: int) -> Variant:
	var per_surface := []
	var vmin := Vector3(INF, INF, INF)
	var vmax := Vector3(-INF, -INF, -INF)
	var total_verts := 0

	for info_obj in surfaces:
		var info: Dictionary = info_obj
		var src: Array = info["src"]
		var verts: Variant = src[Mesh.ARRAY_VERTEX]
		var uvs: Variant = src[Mesh.ARRAY_TEX_UV]
		if not (verts is PackedVector3Array) or not (uvs is PackedVector2Array):
			continue
		var v_arr: PackedVector3Array = verts
		var uv_arr: PackedVector2Array = uvs
		var raw_idx: Variant = src[Mesh.ARRAY_INDEX]
		var idx_arr: PackedInt32Array = raw_idx if raw_idx is PackedInt32Array else PackedInt32Array()
		var n_idx: int = idx_arr.size() if not idx_arr.is_empty() else v_arr.size()
		var picked := PackedInt32Array()
		for k in range(0, n_idx - 2, 3):
			var i0: int = idx_arr[k] if not idx_arr.is_empty() else k
			var i1: int = idx_arr[k + 1] if not idx_arr.is_empty() else k + 1
			var i2: int = idx_arr[k + 2] if not idx_arr.is_empty() else k + 2
			if int(roundf(uv_arr[i0].x)) - 1 == limb_idx and int(roundf(uv_arr[i1].x)) - 1 == limb_idx and int(roundf(uv_arr[i2].x)) - 1 == limb_idx:
				picked.append(i0)
				picked.append(i1)
				picked.append(i2)
				for vi in [i0, i1, i2]:
					var p := v_arr[vi]
					vmin = vmin.min(p)
					vmax = vmax.max(p)
				total_verts += 3
		if not picked.is_empty():
			per_surface.append({"s": info["s"], "fmt": info["fmt"], "src": src, "v": v_arr, "uv": uv_arr, "picked": picked})

	if total_verts == 0 or per_surface.is_empty():
		return null

	var centroid := (vmin + vmax) * 0.5
	return {"centroid": centroid, "pieces": _sliced_arrays(per_surface, centroid), "cap": null}


func _extract_part_entry(proto: String, part: String) -> Variant:
	var mesh := ModelLibrary.mesh_for(proto)
	if mesh == null:
		return null
	var target_part := int(PART_IDS.get(part, -1))
	if target_part < 0:
		return null
	return _assemble(mesh, _part_plan(_surfaces_info(mesh), target_part, _split_scale(proto), proto.contains("worm")))


static func _split_scale(proto: String) -> float:
	var alias: Variant = CreatureModels.ALIASES.get(proto)
	return float(alias[1]) if alias is Array else 1.0


## A body part's cut and its cap, as arrays only (pure arithmetic, safe on a worker thread); null when
## it has none.
static func _part_plan(surfaces: Array, target_part: int, scale: float, is_worm: bool) -> Variant:
	var head_cut := (WORM_HEAD_Y if is_worm else SPLIT_HEAD_Z) * scale
	var abd_cut := (WORM_ABDOMEN_Y if is_worm else SPLIT_ABDOMEN_Z) * scale
	var inv_weld := 500.0 / maxf(scale, 0.1)

	var per_surface := []
	var vmin := Vector3(INF, INF, INF)
	var vmax := Vector3(-INF, -INF, -INF)
	var total_verts := 0
	var weld_map := {}  # Vector3i -> int
	var weld_pos := PackedVector3Array()
	var part_edges: Array = [{}, {}, {}]  # per part_id: Vector2i(a, b) -> true

	for info_obj in surfaces:
		var info: Dictionary = info_obj
		var src: Array = info["src"]
		var verts: Variant = src[Mesh.ARRAY_VERTEX]
		var uvs: Variant = src[Mesh.ARRAY_TEX_UV]
		if not (verts is PackedVector3Array) or not (uvs is PackedVector2Array):
			continue
		var v_arr: PackedVector3Array = verts
		var uv_arr: PackedVector2Array = uvs
		var raw_idx: Variant = src[Mesh.ARRAY_INDEX]
		var idx_arr: PackedInt32Array = raw_idx if raw_idx is PackedInt32Array else PackedInt32Array()
		var n_idx: int = idx_arr.size() if not idx_arr.is_empty() else v_arr.size()
		var picked := PackedInt32Array()
		for k in range(0, n_idx - 2, 3):
			var i0: int = idx_arr[k] if not idx_arr.is_empty() else k
			var i1: int = idx_arr[k + 1] if not idx_arr.is_empty() else k + 1
			var i2: int = idx_arr[k + 2] if not idx_arr.is_empty() else k + 2
			if int(roundf(uv_arr[i0].x)) != 0 or int(roundf(uv_arr[i1].x)) != 0 or int(roundf(uv_arr[i2].x)) != 0:
				continue
			var p0 := v_arr[i0]
			var p1 := v_arr[i1]
			var p2 := v_arr[i2]
			var tri_part: int
			if is_worm:
				var cy := (p0.y + p1.y + p2.y) / 3.0
				tri_part = 0 if cy >= head_cut else (1 if cy > abd_cut else 2)
			else:
				var cz := (p0.z + p1.z + p2.z) / 3.0
				tri_part = 0 if cz <= head_cut else (1 if cz < abd_cut else 2)
			var w0 := _weld_point(p0, inv_weld, weld_map, weld_pos)
			var w1 := _weld_point(p1, inv_weld, weld_map, weld_pos)
			var w2 := _weld_point(p2, inv_weld, weld_map, weld_pos)
			var edges_dict: Dictionary = part_edges[tri_part]
			if w0 != w1:
				edges_dict[Vector2i(w0, w1)] = true
			if w1 != w2:
				edges_dict[Vector2i(w1, w2)] = true
			if w2 != w0:
				edges_dict[Vector2i(w2, w0)] = true
			if tri_part == target_part:
				picked.append(i0)
				picked.append(i1)
				picked.append(i2)
				vmin = vmin.min(p0).min(p1).min(p2)
				vmax = vmax.max(p0).max(p1).max(p2)
				total_verts += 3
		if not picked.is_empty():
			per_surface.append({"s": info["s"], "fmt": info["fmt"], "src": src, "v": v_arr, "uv": uv_arr, "picked": picked})

	if total_verts == 0 or per_surface.is_empty():
		return null

	var centroid := (vmin + vmax) * 0.5
	return {"centroid": centroid, "pieces": _sliced_arrays(per_surface, centroid),
		"cap": _cut_cap_arrays(target_part, part_edges, weld_pos, centroid, scale, head_cut, abd_cut, is_worm)}


static func _weld_point(p: Vector3, inv_weld: float, weld_map: Dictionary, weld_pos: PackedVector3Array) -> int:
	var key := Vector3i(roundi(p.x * inv_weld), roundi(p.y * inv_weld), roundi(p.z * inv_weld))
	var existing: Variant = weld_map.get(key)
	if existing != null:
		return int(existing)
	var id := weld_pos.size()
	weld_map[key] = id
	weld_pos.append(p)
	return id


## The picked triangles of each surface as new arrays (pure arithmetic): [{s, fmt, arrays}].
static func _sliced_arrays(per_surface: Array, centroid: Vector3) -> Array:
	var out: Array = []
	for entry_obj in per_surface:
		var entry: Dictionary = entry_obj
		var s: int = int(entry["s"])
		var src: Array = entry["src"]
		var v_arr: PackedVector3Array = entry["v"]
		var uv_arr: PackedVector2Array = entry["uv"]
		var picked: PackedInt32Array = entry["picked"]

		var dst := []
		dst.resize(Mesh.ARRAY_MAX)
		var out_v := PackedVector3Array()
		out_v.resize(picked.size())
		for i in picked.size():
			out_v[i] = v_arr[picked[i]] - centroid
		dst[Mesh.ARRAY_VERTEX] = out_v

		if src[Mesh.ARRAY_NORMAL] is PackedVector3Array:
			var sn: PackedVector3Array = src[Mesh.ARRAY_NORMAL]
			var out_n := PackedVector3Array()
			out_n.resize(picked.size())
			for i in picked.size():
				out_n[i] = sn[picked[i]]
			dst[Mesh.ARRAY_NORMAL] = out_n

		if src[Mesh.ARRAY_TANGENT] is PackedFloat32Array:
			var st: PackedFloat32Array = src[Mesh.ARRAY_TANGENT]
			if st.size() == v_arr.size() * 4:
				var out_t := PackedFloat32Array()
				out_t.resize(picked.size() * 4)
				for i in picked.size():
					var si := picked[i] * 4
					var di := i * 4
					out_t[di] = st[si]
					out_t[di + 1] = st[si + 1]
					out_t[di + 2] = st[si + 2]
					out_t[di + 3] = st[si + 3]
				dst[Mesh.ARRAY_TANGENT] = out_t

		if src[Mesh.ARRAY_COLOR] is PackedColorArray:
			var sc: PackedColorArray = src[Mesh.ARRAY_COLOR]
			var out_c := PackedColorArray()
			out_c.resize(picked.size())
			for i in picked.size():
				out_c[i] = sc[picked[i]]
			dst[Mesh.ARRAY_COLOR] = out_c

		var out_uv := PackedVector2Array()
		out_uv.resize(picked.size())
		for i in picked.size():
			out_uv[i] = uv_arr[picked[i]]
		dst[Mesh.ARRAY_TEX_UV] = out_uv

		if src[Mesh.ARRAY_TEX_UV2] is PackedVector2Array:
			var suv2: PackedVector2Array = src[Mesh.ARRAY_TEX_UV2]
			var out_uv2 := PackedVector2Array()
			out_uv2.resize(picked.size())
			for i in picked.size():
				out_uv2[i] = suv2[picked[i]]
			dst[Mesh.ARRAY_TEX_UV2] = out_uv2

		for ci in [Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_CUSTOM2, Mesh.ARRAY_CUSTOM3]:
			var ca: Variant = src[ci]
			var copied: Variant = _slice_vertex_array(ca, picked, v_arr.size())
			if copied != null:
				dst[ci] = copied

		var fmt: int = int(entry["fmt"]) & ~Mesh.ARRAY_FORMAT_INDEX
		out.append({"s": s, "fmt": fmt, "arrays": dst})
	return out


## A cut's mesh and material copies from its plan (main thread); null when it has no surfaces.
static func _assemble(mesh: Mesh, plan: Variant) -> Variant:
	if not (plan is Dictionary):
		return null
	var pd: Dictionary = plan
	var out_mesh := ArrayMesh.new()
	var mats: Array = []
	var zero_holes := _zero_holes()
	for piece_obj in pd["pieces"]:
		var piece: Dictionary = piece_obj
		var s: int = int(piece["s"])
		out_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, piece["arrays"], [], {}, int(piece["fmt"]))
		var mat := mesh.surface_get_material(s) as ShaderMaterial
		var m_copy: ShaderMaterial = null
		if mat != null:
			m_copy = ModelLods.copy_material(mat)
			m_copy.shader = RagdollShader
			m_copy.set_shader_parameter("rig_mode", 0)
			m_copy.set_shader_parameter("rig_decay", 0.0)
			m_copy.set_shader_parameter("rig_decay_floor", 0.0)
			m_copy.set_shader_parameter("rig_blood", 0.0)
			m_copy.set_shader_parameter("rig_burn", 0.0)
			m_copy.set_shader_parameter("rig_holes", zero_holes)
			out_mesh.surface_set_material(out_mesh.get_surface_count() - 1, m_copy)
		mats.append(m_copy)
	var cap: Variant = pd.get("cap")
	if cap is Array:
		out_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, cap)
		var meat_mat := _make_meat_cap_material()
		out_mesh.surface_set_material(out_mesh.get_surface_count() - 1, meat_mat)
		mats.append(meat_mat)
	if out_mesh.get_surface_count() == 0:
		return null
	return {"mesh": out_mesh, "mats": mats, "centroid": pd["centroid"]}


## The cut faces' cap of a body part as arrays (pure arithmetic); null when there is none.
static func _cut_cap_arrays(target_part: int, part_edges: Array,
		weld_pos: PackedVector3Array, centroid: Vector3, scale: float, head_cut: float, abd_cut: float,
		y_axis := false) -> Variant:
	var cuts: Array = []
	if y_axis:
		if target_part == 0:
			cuts = [[1, head_cut, Vector3(0.0, -1.0, 0.0)]]
		elif target_part == 1:
			cuts = [[0, head_cut, Vector3(0.0, 1.0, 0.0)], [2, abd_cut, Vector3(0.0, -1.0, 0.0)]]
		elif target_part == 2:
			cuts = [[1, abd_cut, Vector3(0.0, 1.0, 0.0)]]
	else:
		if target_part == 0:
			cuts = [[1, head_cut, Vector3(0.0, 0.0, 1.0)]]
		elif target_part == 1:
			cuts = [[0, head_cut, Vector3(0.0, 0.0, -1.0)], [2, abd_cut, Vector3(0.0, 0.0, 1.0)]]
		elif target_part == 2:
			cuts = [[1, abd_cut, Vector3(0.0, 0.0, -1.0)]]

	var cap_v := PackedVector3Array()
	var cap_n := PackedVector3Array()
	var cap_c := PackedColorArray()
	var cap_uv := PackedVector2Array()
	var mine: Dictionary = part_edges[target_part]

	for cut_spec in cuts:
		var spec: Array = cut_spec
		var other_part := int(spec[0])
		var cut_pos := float(spec[1])
		var outward: Vector3 = spec[2] as Vector3
		var theirs: Dictionary = part_edges[other_part]
		var cut_edges: Array[Vector2i] = []
		for e_obj in mine:
			var e: Vector2i = e_obj as Vector2i
			if theirs.has(Vector2i(e.y, e.x)):
				cut_edges.append(e)
		if cut_edges.is_empty():
			var cut_tol := 0.18 * scale
			for e_obj in mine:
				var e: Vector2i = e_obj as Vector2i
				if not mine.has(Vector2i(e.y, e.x)):
					var mid_coord := ((weld_pos[e.x].y + weld_pos[e.y].y) if y_axis else (weld_pos[e.x].z + weld_pos[e.y].z)) * 0.5
					if absf(mid_coord - cut_pos) <= cut_tol:
						cut_edges.append(e)
		if cut_edges.is_empty():
			continue
		_cap_cut_loops(cut_edges, weld_pos, centroid, outward, scale, cap_v, cap_n, cap_c, cap_uv)

	if cap_v.is_empty():
		return null
	var dst := []
	dst.resize(Mesh.ARRAY_MAX)
	dst[Mesh.ARRAY_VERTEX] = cap_v
	dst[Mesh.ARRAY_NORMAL] = cap_n
	dst[Mesh.ARRAY_COLOR] = cap_c
	dst[Mesh.ARRAY_TEX_UV] = cap_uv
	return dst


static func _cap_cut_loops(cut_edges: Array[Vector2i], weld_pos: PackedVector3Array, centroid: Vector3,
		outward: Vector3, scale: float, cap_v: PackedVector3Array, cap_n: PackedVector3Array,
		cap_c: PackedColorArray, cap_uv: PackedVector2Array) -> void:
	var adj := {}  # int -> Array[int]
	var indeg := {}
	var outdeg := {}
	for e: Vector2i in cut_edges:
		if not adj.has(e.x):
			adj[e.x] = []
		(adj[e.x] as Array).append(e.y)
		outdeg[e.x] = int(outdeg.get(e.x, 0)) + 1
		indeg[e.y] = int(indeg.get(e.y, 0)) + 1

	var used := {}  # Vector2i -> true
	var closed_loops: Array = []
	var open_chains: Array = []
	var max_steps := cut_edges.size() + 2

	# Trace open chains first (vertices with more outgoing than incoming cut edges).
	for v_obj in outdeg:
		var start_v := int(v_obj)
		while int(outdeg.get(start_v, 0)) > int(indeg.get(start_v, 0)):
			var chain := _trace_chain(start_v, adj, used, max_steps)
			if chain.size() < 2:
				break
			outdeg[start_v] = int(outdeg[start_v]) - 1
			if chain.size() >= 4 and chain[0] == chain[chain.size() - 1]:
				closed_loops.append(chain)
			else:
				open_chains.append(chain)

	# Trace remaining closed loops.
	for e: Vector2i in cut_edges:
		if used.has(e):
			continue
		var chain := _trace_chain(e.x, adj, used, max_steps)
		if chain.size() >= 4 and chain[0] == chain[chain.size() - 1]:
			closed_loops.append(chain)
		elif chain.size() >= 2:
			open_chains.append(chain)

	var bulge := outward * (0.006 * scale)
	for loop_obj in closed_loops:
		var loop: Array = loop_obj
		var n := loop.size() - 1
		var center := Vector3.ZERO
		for j in n:
			center += weld_pos[int(loop[j])]
		center = center / float(n) + bulge - centroid
		for j in n:
			var pa := weld_pos[int(loop[j])] - centroid
			var pb := weld_pos[int(loop[j + 1])] - centroid
			_emit_cap_tri(center, pa, pb, outward, cap_v, cap_n, cap_c, cap_uv)

	if not open_chains.is_empty():
		var center := Vector3.ZERO
		var count := 0
		for ch_obj in open_chains:
			var ch: Array = ch_obj
			for v_id in ch:
				center += weld_pos[int(v_id)]
				count += 1
		center = center / float(maxi(count, 1)) + bulge - centroid
		for ch_obj in open_chains:
			var ch: Array = ch_obj
			for j in range(ch.size() - 1):
				var pa := weld_pos[int(ch[j])] - centroid
				var pb := weld_pos[int(ch[j + 1])] - centroid
				_emit_cap_tri(center, pa, pb, outward, cap_v, cap_n, cap_c, cap_uv)
		# Bridge each open chain end to the nearest unused open chain start so the cross-section closes.
		var used_starts := {}
		for ci in open_chains.size():
			var ch_end: Array = open_chains[ci]
			var end_p := weld_pos[int(ch_end[ch_end.size() - 1])]
			var best_j := -1
			var best_d := INF
			for cj in open_chains.size():
				if used_starts.has(cj):
					continue
				var ch_start: Array = open_chains[cj]
				var d := end_p.distance_squared_to(weld_pos[int(ch_start[0])])
				if d < best_d:
					best_d = d
					best_j = cj
			if best_j >= 0:
				used_starts[best_j] = true
				var ch_next: Array = open_chains[best_j]
				var pa := end_p - centroid
				var pb := weld_pos[int(ch_next[0])] - centroid
				_emit_cap_tri(center, pa, pb, outward, cap_v, cap_n, cap_c, cap_uv)


static func _trace_chain(start_v: int, adj: Dictionary, used: Dictionary, max_steps: int) -> Array:
	var chain: Array = [start_v]
	var cur := start_v
	for _step in max_steps:
		if not adj.has(cur):
			break
		var nexts: Array = adj[cur]
		var picked := -1
		for n_obj in nexts:
			var nxt := int(n_obj)
			var ek := Vector2i(cur, nxt)
			if not used.has(ek):
				used[ek] = true
				picked = nxt
				break
		if picked < 0:
			break
		chain.append(picked)
		cur = picked
		if cur == start_v:
			break
	return chain


static func _emit_cap_tri(center: Vector3, pa: Vector3, pb: Vector3, outward: Vector3,
		cap_v: PackedVector3Array, cap_n: PackedVector3Array,
		cap_c: PackedColorArray, cap_uv: PackedVector2Array) -> void:
	var v1 := pa
	var v2 := pb
	var cr := (v1 - center).cross(v2 - center)
	if cr.length_squared() < 1e-12:
		return
	# Godot front faces wind clockwise when viewed from +outward, so (v1-v0)x(v2-v0) faces -outward.
	if cr.dot(outward) > 0.0:
		v1 = pb
		v2 = pa
	cap_v.append(center)
	cap_v.append(v1)
	cap_v.append(v2)
	cap_n.append(outward)
	cap_n.append(outward)
	cap_n.append(outward)
	cap_c.append(Color(0.72, 0.72, 0.72, 0.70))
	cap_c.append(Color(1.0, 1.0, 1.0, 0.95))
	cap_c.append(Color(1.0, 1.0, 1.0, 0.95))
	cap_uv.append(Vector2.ZERO)
	cap_uv.append(Vector2.ZERO)
	cap_uv.append(Vector2.ZERO)


static func _make_meat_cap_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.resource_name = "biter_inner_meat"
	mat.shader = RagdollShader
	mat.set_shader_parameter("albedo", Color(0.24, 0.035, 0.19, 1.0))
	mat.set_shader_parameter("roughness", 0.22)
	mat.set_shader_parameter("metallic", 0.0)
	mat.set_shader_parameter("vertex_data", 1.0)
	mat.set_shader_parameter("edge_data", 0.0)
	mat.set_shader_parameter("view_data", 0.0)
	mat.set_shader_parameter("part_data", 0.0)
	mat.set_shader_parameter("part_colors", false)
	mat.set_shader_parameter("skin_mode", 0)
	mat.set_shader_parameter("rust", 0.0)
	mat.set_shader_parameter("streaks", 0.0)
	mat.set_shader_parameter("edge_wear", 0.0)
	mat.set_shader_parameter("grime", 0.25)
	mat.set_shader_parameter("dust", 0.0)
	mat.set_shader_parameter("desaturate", 0.0)
	mat.set_shader_parameter("value", 1.0)
	mat.set_shader_parameter("grain", 0.25)
	mat.set_shader_parameter("rig_mode", 0)
	mat.set_shader_parameter("rig_decay", 0.0)
	mat.set_shader_parameter("rig_decay_floor", 0.0)
	mat.set_shader_parameter("rig_blood", 0.0)
	mat.set_shader_parameter("rig_burn", 0.0)
	mat.set_shader_parameter("rig_holes", _zero_holes())
	return mat


static func _slice_vertex_array(src: Variant, picked: PackedInt32Array, vert_count: int) -> Variant:
	if vert_count <= 0:
		return null
	if src is PackedFloat32Array:
		var arr: PackedFloat32Array = src
		var stride := arr.size() / vert_count
		if stride <= 0 or stride * vert_count != arr.size():
			return null
		var out := PackedFloat32Array()
		out.resize(picked.size() * stride)
		for i in picked.size():
			var si := picked[i] * stride
			var di := i * stride
			for k in stride:
				out[di + k] = arr[si + k]
		return out
	if src is PackedByteArray:
		var barr: PackedByteArray = src
		var bstride := barr.size() / vert_count
		if bstride <= 0 or bstride * vert_count != barr.size():
			return null
		var bout := PackedByteArray()
		bout.resize(picked.size() * bstride)
		for i in picked.size():
			var si := picked[i] * bstride
			var di := i * bstride
			for k in bstride:
				bout[di + k] = barr[si + k]
		return bout
	return null
