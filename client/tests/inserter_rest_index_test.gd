extends SceneTree
## (--rest-arms-index, perf A1) The resting arms worked out from the per-chunk index (and InserterArmsNative)
## against the old walk of every entity in GDScript: a stub world (as inserter_arms_replay.gd's) of chunks with
## inserters drawn all four ways (pictures, a rig, Wube's pieces, boxes) among 1,500 other entities each; the box
## buffers, the 3D buffers per mesh and the picture buffers compared (max difference TOL); _belt_at compared on
## 2,000 random points; an entity change drops a chunk's index; the shadow sync goes 32 chunks a frame; the time
## of 100 _rest_chunk calls and 2,000 _belt_at calls printed both ways.
## Run: godot --headless --audio-driver Dummy --path client --log-file <abs> --script res://tests/inserter_rest_index_test.gd

const Arms := preload("res://scripts/world/inserter_arms.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")

const TOL := 2e-4
const OTHERS := 1500
const CHUNKS := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-1, 2)]
const RIG_CHUNK := Vector2i(3, 3)  # (the bench) every inserter a rig's, as the Zenith pack's

var passes := 0
var fails := 0


class Rec:
	var unit := 0
	var pos := Vector2.ZERO
	var proto_id := 0
	var dir := 0
	var extra := {}


class Chunk:
	var entities := {}
	var content_rev := 0


class StubWorld extends Node3D:
	signal entities_changed(chunk: Vector2i)
	var entities := {}
	var chunks := {}


func check(cond: bool, msg: String) -> void:
	if cond:
		passes += 1
	else:
		fails += 1
		print("FAIL: %s" % msg)


var protos := ProtoDB.new()
var world := StubWorld.new()
var eprops := {}
var pictures := {}
var rig := {}
var model_meshes: Array = []
var _next_unit := 1


func _proto(id: int, name: String, type: String) -> void:
	var p := ProtoDB.EntityProto.new()
	p.id = id
	p.name = name
	p.type = type
	p.color = Color(0.6, 0.5, 0.2)
	protos.entities[id] = p
	protos.entities_by_name[name] = p


func _add(c: Vector2i, proto_id: int, pos: Vector2, dir := 0, pack := "") -> Rec:
	var r := Rec.new()
	r.unit = _next_unit
	_next_unit += 1
	r.pos = pos
	r.proto_id = proto_id
	r.dir = dir
	if pack != "":
		r.extra[ModelLibrary.PACK_KEY] = pack
	(world.chunks[c] as Chunk).entities["e%d" % r.unit] = r
	world.entities[r.unit] = r
	return r


func _initialize() -> void:
	print("--- Running inserter_rest_index_test ---")
	var nat: RefCounted = null
	if NativeLibrary.ensure() and ClassDB.class_exists("InserterArmsNative"):
		nat = ClassDB.instantiate("InserterArmsNative")
	else:
		print("inserter_rest_index_test: InserterArmsNative not built, the native half skipped")
	root.add_child(world)
	_proto(1, "inserter", "inserter")
	_proto(2, "long-handed-inserter", "inserter")
	_proto(3, "fast-inserter", "inserter")
	_proto(4, "bulk-inserter", "inserter")
	_proto(10, "transport-belt", "transport-belt")
	_proto(11, "splitter", "splitter")
	_proto(12, "underground-belt", "underground-belt")
	_proto(20, "assembling-machine-1", "assembling-machine")
	_proto(21, "pipe", "pipe")
	_proto(22, "small-electric-pole", "electric-pole")
	eprops[1] = {"x": {"ip": [0, -1], "id": [0, 1]}}
	eprops[2] = {"x": {"ip": [0, -2], "id": [0, 2]}}
	eprops[3] = {"x": {"ip": [0.05, -1.1], "id": [0, 1.2]}}
	# (bulk-inserter has none: the default pick)
	var quads: Array = []
	for i in 3:
		quads.append(QuadMesh.new())
	pictures = {"meshes": quads, "widths": [0.55, 0.3, 0.34], "files": ["a", "b", "c"]}
	rig = {"hinge": Vector3(1, 0, 0), "pivot": Vector3(0, 0.3, 0), "shoulder": Vector3(0.05, 0.42, 0.0),
		"elbow": Vector3(0.0, 0.55, -0.55), "grip": Vector3(0.02, 0.4, -1.1), "lengths": [1.0, 1.1],
		"heads": [Vector3(0, 0.3, 0), null, null, Vector3(0.05, 0.4, -1.0), Vector3(-0.05, 0.4, -1.0)],
		"axes": [null, null, null, Vector3(0, 1, 0), Vector3(0, 1, 0)],
		"angles": [null, null, null, 0.5, -0.5], "grip_angles": [null, null, null, 0.3, -0.3],
		"meshes": [BoxMesh.new(), BoxMesh.new(), BoxMesh.new(), BoxMesh.new(), BoxMesh.new()]}
	model_meshes = [BoxMesh.new(), BoxMesh.new(), BoxMesh.new()]
	var rng := RandomNumberGenerator.new()
	rng.seed = 47
	var modes := [[1, "spr"], [2, "rig"], [3, "mdl"], [4, "box"]]
	for c: Vector2i in CHUNKS:
		var ch := Chunk.new()
		world.chunks[c] = ch
		var o := Vector2(c.x * 32, c.y * 32)
		for i in OTHERS:
			var pid: int = [20, 21, 22][i % 3]
			_add(c, pid, o + Vector2(rng.randi_range(0, 31) + 0.5, rng.randi_range(0, 31) + 0.5))
		for i in 200:
			var t := rng.randi_range(0, 9)
			if t < 7:
				_add(c, 10, o + Vector2(rng.randi_range(0, 31) + 0.5, rng.randi_range(0, 31) + 0.5), 4 * rng.randi_range(0, 3))
			elif t < 9:
				_add(c, 11, o + Vector2(rng.randi_range(1, 30), rng.randi_range(0, 31) + 0.5), 0)
			else:
				_add(c, 12, o + Vector2(rng.randi_range(0, 31) + 0.5, rng.randi_range(0, 31) + 0.5), 8)
		for i in 80:
			var m: Array = modes[i % 4]
			_add(c, m[0], o + Vector2(rng.randi_range(0, 31) + 0.5, rng.randi_range(0, 31) + 0.5), 4 * rng.randi_range(0, 3), m[1])
	var rc := Chunk.new()
	world.chunks[RIG_CHUNK] = rc
	for i in OTHERS:
		_add(RIG_CHUNK, [20, 21, 22][i % 3], Vector2(RIG_CHUNK.x * 32 + rng.randi_range(0, 31) + 0.5, RIG_CHUNK.y * 32 + rng.randi_range(0, 31) + 0.5))
	for i in 80:
		_add(RIG_CHUNK, [1, 2, 3][i % 3], Vector2(RIG_CHUNK.x * 32 + rng.randi_range(0, 31) + 0.5, RIG_CHUNK.y * 32 + rng.randi_range(0, 31) + 0.5),
			4 * rng.randi_range(0, 3), "rig")
	# One empty chunk and one with inserters only.
	world.chunks[Vector2i(5, 5)] = Chunk.new()
	world.chunks[Vector2i(6, 5)] = Chunk.new()
	for i in 8:
		_add(Vector2i(6, 5), [1, 2, 3, 4][i % 4], Vector2(6 * 32 + 4.5 + i, 5 * 32 + 6.5), 4 * (i % 4), ["spr", "rig", "mdl", "box"][i % 4])

	# (What the first resting arm reads may set the model packs up, moving ModelPacks.version on: done first.)
	ModelLibrary.placed("inserter", "inserter", 0, {}, Vector3.ZERO)
	Arms._platform_lift("inserter", 0)
	var old := _arms(nat)
	var idx_gd := _arms(null)
	var idx_nat := _arms(nat)
	# One live arm in the first chunk: left out of the resting arms.
	for a: Arms in [old, idx_gd, idx_nat]:
		for r: Rec in (world.chunks[CHUNKS[0]] as Chunk).entities.values():
			if r.proto_id == 2:
				a._rest_live[r.unit] = CHUNKS[0]
				break
	var all_chunks: Array = world.chunks.keys()
	for c: Vector2i in all_chunks:
		Arms.rest_index = false
		_inject(old)
		check(old._rest_chunk(c), "old _rest_chunk %s done" % c)
		Arms.rest_index = true
		_inject(idx_gd)
		check(idx_gd._rest_chunk(c), "indexed (GDScript) _rest_chunk %s done" % c)
		if nat != null:
			_inject(idx_nat)
			check(idx_nat._rest_chunk(c), "indexed (native) _rest_chunk %s done" % c)
	_compare("indexed, GDScript", old, idx_gd, all_chunks)
	if nat != null:
		_compare("indexed, native", old, idx_nat, all_chunks)
	check(old.rest_index_builds == 0, "the old path builds no index (%d)" % old.rest_index_builds)
	check(idx_gd.rest_index_builds == all_chunks.size(), "one index a chunk (%d)" % idx_gd.rest_index_builds)

	_test_belt_at(old, idx_gd, rng)
	_test_drop(idx_gd)
	_test_shadows()
	_bench(old, idx_gd, idx_nat if nat != null else null)
	Arms.rest_index = true
	print("inserter_rest_index_test: %d passed, %d failed" % [passes, fails])
	quit(0 if fails == 0 else 1)


func _arms(nat: RefCounted) -> Arms:
	var a := Arms.new()
	root.add_child(a)
	a.set_process(false)
	a.world = world
	a.protos = protos
	a.eprops = eprops
	a._native = nat
	a._native_tried = true
	_inject(a)
	return a


## The stub models put in an arms' caches (again: ModelPacks.version moving on empties them).
func _inject(a: Arms) -> void:
	a._sprite_version = ModelLibrary.ModelPacks.version
	a._rigs_packs = ModelLibrary.ModelPacks.version
	a._rest_pack_ver = ModelLibrary.ModelPacks.version
	for proto: String in ["inserter", "long-handed-inserter", "fast-inserter", "bulk-inserter"]:
		for pack: String in ["spr", "rig", "mdl", "box"]:
			var model := proto + "@" + pack
			a._sprite_known[model] = pictures if pack == "spr" else {}
			a._rest_pack_rigs[model] = rig if pack == "rig" else {}
			a._rest_pack_meshes[model] = model_meshes if pack == "mdl" else []


## The instances (`stride` floats each) of a buffer in sorted order: arms of two prototypes sharing a mesh come
## per model from the native batches, not interleaved in the chunk's order (drawn the same).
static func _sorted(buf: PackedFloat32Array, stride: int) -> PackedFloat32Array:
	var rows: Array = []
	for i in range(0, buf.size(), stride):
		rows.append(buf.slice(i, i + stride))
	var before := func(a: PackedFloat32Array, b: PackedFloat32Array) -> bool:
		for k in a.size():
			if absf(a[k] - b[k]) > 1e-3:
				return a[k] < b[k]
		return false
	rows.sort_custom(before)
	var out := PackedFloat32Array()
	for r: PackedFloat32Array in rows:
		out.append_array(r)
	return out


static func _max_diff(x: PackedFloat32Array, y: PackedFloat32Array) -> float:
	if x.size() != y.size():
		return INF
	var worst := 0.0
	for i in x.size():
		worst = maxf(worst, absf(x[i] - y[i]))
	return worst


func _compare(label: String, a: Arms, b: Arms, chunks: Array) -> void:
	var worst := 0.0
	var boxes := 0
	var meshes := 0
	var sprites := 0
	for c: Vector2i in chunks:
		var ra: PackedFloat32Array = a._rest.get(c, PackedFloat32Array())
		var rb: PackedFloat32Array = b._rest.get(c, PackedFloat32Array())
		check(ra.size() == rb.size(), "%s %s box buffer size %d vs %d" % [label, c, ra.size(), rb.size()])
		worst = maxf(worst, _max_diff(ra, rb))
		boxes += ra.size() / 16
		var pa: Dictionary = a._rest_3d_pending.get(c, {})
		var pb: Dictionary = b._rest_3d_pending.get(c, {})
		check(pa.size() == pb.size(), "%s %s meshes %d vs %d" % [label, c, pa.size(), pb.size()])
		for m: Variant in pa:
			check(pb.has(m), "%s %s mesh missing" % [label, c])
			if pb.has(m):
				# (rel-031-restarms) An arm with no model rests as the live placeholder arm: its parts 16 floats each.
				var basic: bool = a._rest_basic_meshes.has(m)
				var stride := 16 if basic else 12
				var d := _max_diff(pa[m], pb[m])
				if d >= TOL:
					d = _max_diff(_sorted(pa[m], stride), _sorted(pb[m], stride))
				check(d < TOL, "%s %s mesh buffer %d vs %d floats, max diff %s" % [label, c, (pa[m] as PackedFloat32Array).size(), (pb[m] as PackedFloat32Array).size(), d])
				worst = maxf(worst, d)
				if basic:
					boxes += (pa[m] as PackedFloat32Array).size() / 16
				else:
					meshes += (pa[m] as PackedFloat32Array).size() / 12
		check(str(a._rest_3d_counts.get(c)) == str(b._rest_3d_counts.get(c)), "%s %s 3D counts %s vs %s" % [label, c, a._rest_3d_counts.get(c), b._rest_3d_counts.get(c)])
		var sa: Dictionary = a._rest_sprites.get(c, {})
		var sb: Dictionary = b._rest_sprites.get(c, {})
		check(sa.size() == sb.size(), "%s %s picture models %d vs %d" % [label, c, sa.size(), sb.size()])
		for model: String in sa:
			check(sb.has(model), "%s %s picture model %s missing" % [label, c, model])
			if sb.has(model):
				for p in 3:
					var d := _max_diff(sa[model][p], sb[model][p])
					check(d < TOL, "%s %s %s piece %d max diff %s" % [label, c, model, p, d])
					worst = maxf(worst, d)
					sprites += (sa[model][p] as PackedFloat32Array).size() / 12
	check(boxes > 0 and meshes > 0 and sprites > 0, "%s: every way drawn (boxes %d, 3D pieces %d, pictures %d)" % [label, boxes, meshes, sprites])
	print("%s: max diff %s over %d box, %d 3D and %d picture instances" % [label, worst, boxes, meshes, sprites])


func _test_belt_at(old: Arms, idx: Arms, rng: RandomNumberGenerator) -> void:
	var points: Array = []
	for i in 2000:
		var c: Vector2i = CHUNKS[i % CHUNKS.size()]
		points.append(Vector2(c.x * 32 + rng.randf_range(-0.5, 32.5), c.y * 32 + rng.randf_range(-0.5, 32.5)))
	var same := 0
	var hits := 0
	Arms.rest_index = false
	var t0 := Time.get_ticks_usec()
	var want: Array = []
	for p: Vector2 in points:
		want.append(old._belt_at(p))
	var t_old := Time.get_ticks_usec() - t0
	Arms.rest_index = true
	t0 = Time.get_ticks_usec()
	var got: Array = []
	for p: Vector2 in points:
		got.append(idx._belt_at(p))
	var t_new := Time.get_ticks_usec() - t0
	for i in points.size():
		if want[i] == got[i]:
			same += 1
		if want[i]:
			hits += 1
	check(same == points.size(), "_belt_at equal on %d of %d points" % [same, points.size()])
	check(hits > 100 and hits < points.size() - 100, "_belt_at points mixed (%d on a belt)" % hits)
	print("_belt_at: %d of %d equal (%d on a belt); 2000 calls old %.2f ms, indexed %.2f ms" % [same, points.size(), hits, t_old / 1000.0, t_new / 1000.0])


func _test_drop(idx: Arms) -> void:
	var c := Vector2i(5, 5)
	var p := Vector2(5 * 32 + 10.5, 5 * 32 + 10.5)
	Arms.rest_index = true
	check(not idx._belt_at(p), "no belt in the empty chunk")
	check(idx._rest_index.has(c), "the empty chunk's index kept")
	_add(c, 10, p)
	world.entities_changed.emit(c)
	check(not idx._rest_index.has(c), "entities_changed drops the chunk's index")
	check(idx._belt_at(p), "the new belt found")
	# A record added with only the chunk's content_rev moved on (before its entities_changed): made again too.
	var q := p + Vector2(4.0, 0.0)
	check(not idx._belt_at(q), "no belt at the second place yet")
	_add(c, 11, q)
	(world.chunks[c] as Chunk).content_rev += 1
	check(idx._belt_at(q), "content_rev moved on: the new splitter found")
	var builds := idx.rest_index_builds
	idx._belt_at(q)
	check(idx.rest_index_builds == builds, "an unchanged chunk's index reused")
	protos.version += 1
	idx._belt_at(q)
	check(idx.rest_index_builds == builds + 1, "the prototypes' version moving on makes it again")


func _test_shadows() -> void:
	var a := _arms(null)
	Arms.rest_index = true
	for i in 70:
		var c := Vector2i(100 + i, 0)
		world.chunks[c] = Chunk.new()
		var mmi := MultiMeshInstance3D.new()
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		a.add_child(mmi)
		a._rest_3d_mmis[c] = {"m": mmi}
	a._sync_rest_3d_shadows()
	check(a._rest_3d_shadow.size() == 32, "32 chunks' shadows the first frame (%d)" % a._rest_3d_shadow.size())
	a._sync_rest_3d_shadows()
	a._sync_rest_3d_shadows()
	check(a._rest_3d_shadow.size() == 70, "every chunk's shadow in three frames (%d)" % a._rest_3d_shadow.size())
	var on := 0
	for d: Dictionary in a._rest_3d_mmis.values():
		if (d["m"] as MultiMeshInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON:
			on += 1
	check(on == 70, "their shadows set (%d)" % on)
	Arms.rest_index = false
	var b := _arms(null)
	b._rest_3d_mmis = a._rest_3d_mmis
	b._sync_rest_3d_shadows()
	check(b._rest_3d_shadow.size() == 70, "off: every chunk every frame (%d)" % b._rest_3d_shadow.size())
	for c in range(70):
		world.chunks.erase(Vector2i(100 + c, 0))
	Arms.rest_index = true


func _bench(old: Arms, idx_gd: Arms, idx_nat: Arms) -> void:
	for c: Vector2i in [CHUNKS[1], RIG_CHUNK]:
		_bench_chunk(c, "all four ways" if c != RIG_CHUNK else "rigs only", old, idx_gd, idx_nat)


func _bench_chunk(c: Vector2i, what: String, old: Arms, idx_gd: Arms, idx_nat: Arms) -> void:
	var runs := [["old (every entity, GDScript)", old, false], ["indexed, GDScript", idx_gd, true]]
	if idx_nat != null:
		runs.append(["indexed, native", idx_nat, true])
	for run: Array in runs:
		Arms.rest_index = run[2]
		var a: Arms = run[1]
		_inject(a)
		a._rest_chunk(c)
		var t0 := Time.get_ticks_usec()
		for i in 100:
			a._rest_chunk(c)
		var us := Time.get_ticks_usec() - t0
		var cold := ""
		if run[2]:
			# (Its index made again each call too, as after an entity change in it.)
			t0 = Time.get_ticks_usec()
			for i in 100:
				a._rest_index.erase(c)
				a._rest_chunk(c)
			cold = ", %.3f ms with its index made again" % ((Time.get_ticks_usec() - t0) / 100000.0)
		print("_rest_chunk on a chunk of %d entities (80 inserters, %s): %s %.3f ms a call%s" % [(world.chunks[c] as Chunk).entities.size(), what, run[0], us / 100000.0, cold])
