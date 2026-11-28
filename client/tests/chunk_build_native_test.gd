extends SceneTree
## ChunkBuildNative (client/native/belt_sim) against chunk_view.gd's GDScript ChunkPrepJob loops:
## pack_buffer and box_bounds on the same random inputs; prints the max difference and each one's time.
## collect_rows (--native-collect) against _walk_rec on random records: the same lists (order aside).
##   godot --headless --audio-driver Dummy --path client -s res://tests/chunk_build_native_test.gd
## Skips (exit 0) when the extension isn't loaded.

const ChunkView := preload("res://scripts/world/chunk_view.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const PipelineWarm := preload("res://scripts/world/pipeline_warm.gd")
const ContactShade := preload("res://scripts/world/contact_shade.gd")
const Probing := preload("res://scripts/debug/probing.gd")


func _init() -> void:
	if not NativeLibrary.ensure() or not ClassDB.class_exists(&"ChunkBuildNative"):
		print("chunk_build_native_test: ChunkBuildNative not loaded, skipped")
		quit(0)
		return
	var nat: Object = ClassDB.instantiate(&"ChunkBuildNative")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var fails := 0
	for n in [1, 40, 500, 5000]:
		var xf: Array = []
		var cols: Array = []
		for i in n:
			var b := Basis(Vector3.UP, rng.randf() * TAU) * Basis.from_scale(Vector3(rng.randf_range(0.5, 2.0), rng.randf_range(0.5, 2.0), rng.randf_range(0.5, 2.0)))
			xf.append(Transform3D(b, Vector3(rng.randf_range(-500, 500), rng.randf_range(0, 4), rng.randf_range(-500, 500))))
			cols.append(Color(rng.randf(), rng.randf(), rng.randf(), rng.randf()))
		var box := AABB(Vector3(-1.5, 0, -1.0), Vector3(3.0, 2.5, 2.0))
		for combo in [[false, false, false], [true, false, false], [false, true, false], [true, true, false], [false, false, true], [true, true, true]]:
			var c: Array = cols if combo[0] else []
			var t0 := Time.get_ticks_usec()
			var g: PackedFloat32Array = ChunkView.ChunkPrepJob.pack_buffer_gd(xf, c, combo[1], combo[2])
			var t1 := Time.get_ticks_usec()
			var r: PackedFloat32Array = nat.pack_buffer(xf, c, combo[1], combo[2])
			var t2 := Time.get_ticks_usec()
			var d := 0.0
			if g.size() != r.size():
				d = INF
			else:
				for i in g.size():
					d = maxf(d, absf(g[i] - r[i]))
			if d != 0.0:
				fails += 1
			if combo == [true, true, false]:
				print("pack n=%d colors+custom: gd %d us, native %d us, max diff %s" % [n, t1 - t0, t2 - t1, d])
			elif d != 0.0:
				print("pack n=%d %s: max diff %s" % [n, combo, d])
		var t3 := Time.get_ticks_usec()
		var gb: AABB = ChunkView.ChunkPrepJob.box_bounds_gd(box, xf)
		var t4 := Time.get_ticks_usec()
		var nb: AABB = nat.box_bounds(box, xf)
		var t5 := Time.get_ticks_usec()
		var bd := maxf(absf(gb.position.x - nb.position.x), maxf(absf(gb.position.y - nb.position.y), absf(gb.position.z - nb.position.z)))
		bd = maxf(bd, maxf(absf(gb.size.x - nb.size.x), maxf(absf(gb.size.y - nb.size.y), absf(gb.size.z - nb.size.z))))
		print("bounds n=%d: gd %d us, native %d us, max diff %s" % [n, t4 - t3, t5 - t4, bd])
		if bd != 0.0:
			fails += 1
	# the empty case
	if nat.pack_buffer([], [], false, false).size() != 0:
		fails += 1
	call_deferred("_collect_all", nat, rng, fails)  # (world.gd needs the autoloads: loaded once they are in)


func _collect_all(nat: Object, rng: RandomNumberGenerator, fails: int) -> void:
	if not nat.has_method(&"collect_rows"):
		print("collect_rows: not in this DLL, skipped")
	else:
		var world_script: GDScript = load("res://scripts/world/world.gd")
		for n in [0, 7, 600, 5000]:
			fails += _collect_parity(nat, rng, n, world_script, false)
		fails += _collect_parity(nat, rng, 5000, world_script, true)  # as a build for a change sees them
		if not nat.has_method(&"shape_key"):
			print("walk shapes: shape_key not in this DLL, skipped")
		else:
			fails += _shape_parity(nat, world_script)
	print("chunk_build_native_test: %d fails" % fails)
	quit(1 if fails > 0 else 0)


## Random records, most of them as the record cache holds them, walked by _walk_records with collect_rows and
## with _walk_rec alone: both sides' lists must hold the same (instances paired with their records).
## `cached`: every record as the record cache holds it, no ghosts, cargo or covers (a build for a change).
func _collect_parity(nat: Object, rng: RandomNumberGenerator, n: int, world_script: GDScript, cached: bool) -> int:
	var protos := ProtoDB.new()
	var kinds := [["transport-belt", "transport-belt"], ["assembling-machine-1", "assembling-machine"], ["inserter", "inserter"],
		["tree-01", "tree"], ["loader", "loader"], ["pipe-to-ground", "pipe-to-ground"], ["electric-mining-drill", "mining-drill"],
		["train-stop", "train-stop"], ["dummy-thing", "simple-entity"], ["iron-ore", "resource"]]
	var rows: Array = []
	for i in kinds.size():
		rows.append([i + 1, kinds[i][0], kinds[i][1], -1, -1, 1, 1, 200, 100, 50, 2, 2])
	protos.add_entities(rows)
	var meshes: Array = []
	var box_arrays := BoxMesh.new().get_mesh_arrays()
	for i in 6:
		var am := ArrayMesh.new()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, box_arrays)
		if i % 2 == 0:
			am.set_meta(ModelLods.ARRAYS_META, [])  # bakeable: what a far merge may draw
		meshes.append(am)
	var part_lists: Array = [[], [], [1, 2]]
	var cv: ChunkView = ChunkView.new()
	var seen := {}
	for i in 5:
		seen[meshes[i]] = true  # meshes[5] not yet known warm: GDScript's model_ready
	var working := {}
	var gen := ModelLibrary.generation
	for i in n:
		var r = world_script.Rec.new()
		r.unit = i + 1
		r.key = r.unit if rng.randf() < 0.8 else "x:%d" % i
		r.proto_id = rng.randi_range(0, kinds.size() + 1)  # 0 and the last: no prototype
		if cached:
			r.proto_id = [1, 2, 3, 4, 5][rng.randi_range(0, 4)]
		r.pos = Vector2(rng.randi_range(-40, 40) + 0.5, rng.randi_range(-40, 40) + 0.5)
		r.dir = rng.randi_range(0, 3) * 4
		var extra := {}
		for k in ["gh", "hid", "r", "g", "cb", "fa", "pc"]:
			if rng.randf() < (0.0 if cached else 0.06):
				extra[k] = rng.randi_range(0, 15)
		r.extra = extra
		r.covers = 1 if rng.randf() < 0.03 and not cached else 0
		r.cache_gen = gen if rng.randf() < 0.9 or cached else gen - 1
		r.cache_mesh = meshes[rng.randi_range(0, 4 if cached else 5)] if rng.randf() < 0.97 or cached else null
		r.cache_parts = part_lists[rng.randi_range(0, 2)]
		r.cache_xform = Transform3D(Basis(Vector3.UP, rng.randi_range(0, 3) * PI / 2), Vector3(r.pos.x, 0.0, r.pos.y))
		r.cache_is_belt = rng.randf() < 0.4
		r.cache_belt_kind = "k%d" % rng.randi_range(0, 2)
		r.cache_rings = [[r.pos.x, r.pos.y, 0.5, 0.5]] if rng.randf() < 0.9 else []
		r.cache_row = [r.cache_mesh, r.cache_parts, r.cache_xform, r.cache_is_belt, r.cache_belt_kind, r.cache_rings]
		if rng.randf() < 0.3:
			working[r.unit] = 5 if rng.randf() < 0.5 else 1
		cv.entities[r.key] = r
	var made: Array = []
	var times: Array = []
	var was := ChunkView.native_collect
	for native in [false, true]:
		ChunkView.native_collect = native
		PipelineWarm._seen_mesh = seen.duplicate()
		var lists := ChunkView.DrawLists.new()
		var t0 := Time.get_ticks_usec()
		cv._walk_records(lists, protos, working, false, true, cv.build_serial)
		times.append(Time.get_ticks_usec() - t0)
		made.append(_lists_rows(lists))
	ChunkView.native_collect = was
	cv.free()
	var bad := 0
	for k in made[0]:
		if made[0][k] != made[1].get(k):
			bad += 1
			print("collect_rows n=%d: %s differs\n  gd     %s\n  native %s" % [n, k, str(made[0][k]).left(400), str(made[1].get(k)).left(400)])
	print("collect_rows n=%d%s: gd %d us, native %d us, %d parts differ" % [n, " cached" if cached else "", times[0], times[1], bad])
	return bad


## A DrawLists' contents as sorted strings per part (order aside, each instance with its record).
func _lists_rows(l: ChunkView.DrawLists) -> Dictionary:
	var out := {}
	for side in [["keep", l.keep], ["merge", l.merge]]:
		var p: ChunkView.DrawPart = side[1]
		var tag: String = side[0]
		var inst: Array = []
		for m in p.by_model:
			var xs: Array = p.by_model[m]
			var rs: Array = p.recs_by_model[m]
			if xs.size() != rs.size():
				inst.append("size mismatch %d" % m.get_instance_id())
			for i in xs.size():
				inst.append("%d %s %s %s" % [m.get_instance_id(), xs[i], rs[i][0].key, rs[i][1]])
			inst.append("parts %d %s" % [m.get_instance_id(), p.parts_by_model[m]])
		inst.sort()
		out[tag + ".inst"] = inst
		var rings: Array = []
		for g in p.rings:
			rings.append(str(g))
		rings.sort()
		out[tag + ".rings"] = rings
		var sw: Array = p.switchable.keys().map(func(k): return str(k))
		sw.sort()
		out[tag + ".switchable"] = sw
		var bk: Array = []
		for m in p.belt_kinds:
			bk.append("%d %s" % [m.get_instance_id(), p.belt_kinds[m]])
		bk.sort()
		out[tag + ".belt_kinds"] = bk
		out[tag + ".belt_box"] = [p.belt_lo, p.belt_hi] if not p.belt_kinds.is_empty() else []
		out[tag + ".waiting"] = p.waiting
	var wo: Array = []
	for u in l.w_off:
		wo.append("%s %s" % [u, l.w_off[u]])
	wo.sort()
	out["w_off"] = wo
	var far: Array = []
	for m in l.far_xf:
		for x in l.far_xf[m]:
			far.append("%d %s %s %s" % [m.get_instance_id(), l.far_type[m], l.far_parts[m], x])
	for r in l.far_slow:
		far.append("slow %s" % r.key)
	far.sort()
	out["far"] = far
	out["waiting"] = l.waiting
	return out


## --walk-shape: a chunk's first build (every record new) with the shape templates a first chunk left, against
## _walk_rec alone on the same records: the same models, transforms exact, the same records, parts, switchable,
## belt kinds and bounds, far lists and record caches; contact rings within 1e-5, and ContactShade.joined the
## same on a belt line. Then a generation bump empties the table. Prints the first walk's us a record.
func _shape_parity(nat: Object, world_script: GDScript) -> int:
	var protos := ProtoDB.new()
	var kinds := [["transport-belt", "transport-belt", 1], ["underground-belt", "underground-belt", 1], ["pipe", "pipe", 1],
		["pipe-to-ground", "pipe-to-ground", 1], ["stone-wall", "wall", 1], ["rail-signal", "rail-signal", 1],
		["assembling-machine-1", "assembling-machine", 3], ["inserter", "inserter", 1], ["tree-01", "tree", 1],
		["train-stop", "train-stop", 2], ["electric-mining-drill", "mining-drill", 3], ["wooden-chest", "container", 1],
		["gate", "gate", 1]]
	var rows: Array = []
	for i in kinds.size():
		var h: float = float(kinds[i][2]) * 0.5
		rows.append([i + 1, kinds[i][0], kinds[i][1], -h, -h, h, h, 200, 100, 50, kinds[i][2], kinds[i][2]])
	protos.add_entities(rows)
	var meshes: Array = []
	var box_arrays := BoxMesh.new().get_mesh_arrays()
	for i in (kinds.size() + 1) * 3:  # three a prototype (its models and variants): a model is one type's
		var am := ArrayMesh.new()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, box_arrays)
		if i % 2 == 0:
			am.set_meta(ModelLods.ARRAYS_META, [])
		if i % 5 == 1 or i % 5 == 4:
			am.set_meta(ContactShade.META, [[Rect2(-0.4, -0.45, 0.8, 0.9), 0.1], [Rect2(0.15, -0.5, 0.3, 0.2), 0.05]])
		if i % 5 == 2:
			am.set_meta(ContactShade.MASK_META, [Rect2(-1.2, -0.9, 2.4, 1.8), 3, -1])
		meshes.append(am)
	var part_lists: Array = [[], [], [1, 2]]
	var seen := {}
	for i in meshes.size():
		if i % 7 != 5:
			seen[meshes[i]] = true  # the others not yet known warm
	# Variants of one model (as a pack with assembling-machine-1-1.glb...): the seed picks one of three.
	if ModelLibrary._variants_version != ModelLibrary.ModelPacks.version:
		ModelLibrary._variants.clear()
		ModelLibrary._variants_version = ModelLibrary.ModelPacks.version
	ModelLibrary._variants["assembling-machine-1"] = ["assembling-machine-1@p", "assembling-machine-1-1@p", "assembling-machine-1-2@p"]
	ModelLibrary._variants["inserter"] = ["inserter@p", "inserter-1@p"]
	var gen := ModelLibrary.generation
	var warm: Array = _shape_recs(world_script, 11, 4000, 0)
	var line: Array = []
	for i in 24:  # a straight belt line east (ContactShade.joined)
		line.append(_shape_rec(world_script, 900000 + i, Vector2(-12.5 + i, 30.5), 1, 4, {}))
	var cold: Array = []
	for copy in 3:
		var recs: Array = _shape_recs(world_script, 23, 5000, 100000)
		for i in 24:
			recs.append(_shape_rec(world_script, 900000 + i, Vector2(-12.5 + i, 30.5), 1, 4, {}))
		cold.append(recs)
	# Every record's model ready (resolve_entity's memo): a mesh and parts per entity_models() names.
	if ModelLibrary._resolved_gen != ModelLibrary.generation:
		ModelLibrary._resolved.clear()
		ModelLibrary._resolved_gen = ModelLibrary.generation
	for list: Array in [warm, line] + cold:
		for r in list:
			var proto: ProtoDB.EntityProto = protos.entity(r.proto_id)
			var names := ModelLibrary.entity_models(proto.name, proto.type, r.extra, r.dir)
			var mkey: String = names[0] if names.size() == 1 else "|".join(names)
			if not ModelLibrary._resolved.has(mkey):
				var hh := absi(hash(mkey))
				var mi: int = int(r.proto_id) * 3 + hh % 3  # (a model's parts are its own: one list a mesh)
				ModelLibrary._resolved[mkey] = [true, meshes[mi], part_lists[mi % part_lists.size()]]
	var probing_was: bool = Probing.on
	Probing.on = true
	var native_was: bool = ChunkView.native_collect
	var shape_was: bool = ChunkView.walk_shape
	var made: Array = []
	var times: Array = []
	var hits := 0
	# [native, shapes]: GDScript alone, collect_rows without shapes, collect_rows with them (after a warm chunk).
	var runs := [[false, false], [true, false], [true, true]]
	for k in runs.size():
		ChunkView.native_collect = runs[k][0]
		ChunkView.walk_shape = runs[k][1]
		ChunkView._shape_nat_tried = false
		ChunkView._shape_nat = null
		ChunkView._shapes.clear()
		ChunkView._shape_counts.clear()
		PipelineWarm._seen_mesh = seen.duplicate()
		if runs[k][1]:
			var wv: ChunkView = ChunkView.new()
			for r in warm + line.duplicate():
				wv.entities[r.key] = r
			wv._walk_records(ChunkView.DrawLists.new(), protos, {}, false, true, wv.build_serial)
			wv.free()
			print("walk shapes: %d templates from the warm chunk" % ChunkView._shapes.size())
		var cv: ChunkView = ChunkView.new()
		for r in cold[k]:
			cv.entities[r.key] = r
		var lists := ChunkView.DrawLists.new()
		ChunkView.counters.erase("walk_shape_hits")
		var t0 := Time.get_ticks_usec()
		cv._walk_records(lists, protos, {}, false, true, cv.build_serial)
		times.append(Time.get_ticks_usec() - t0)
		if runs[k][1]:
			hits = int(ChunkView.counters.get("walk_shape_hits", 0))
		made.append(lists)
		cv.free()
	var bad := 0
	bad += _shape_compare(made[0], made[2], cold[0], cold[2], "shapes")
	bad += _shape_compare(made[0], made[1], cold[0], cold[1], "no shapes")
	var n: int = cold[0].size()
	print("walk shapes: first walk of %d records: gd %.2f us/rec, native no shapes %.2f us/rec, native shapes %.2f us/rec, %d hits, %d parts differ" % [
		n, float(times[0]) / n, float(times[1]) / n, float(times[2]) / n, hits, bad])
	if hits < n / 5:
		print("walk shapes: too few hits (%d)" % hits)
		bad += 1
	# A first walk whose shapes are all known (the warm chunk's records again, new): each record's cost both ways.
	var again: Array = []
	for copy in 2:
		var recs2: Array = _shape_recs(world_script, 11, 4000, 200000).filter(func(r): return _hittable(r))
		for r in recs2:
			var proto2: ProtoDB.EntityProto = protos.entity(r.proto_id)
			var names2 := ModelLibrary.entity_models(proto2.name, proto2.type, r.extra, r.dir)
			var mkey2: String = names2[0] if names2.size() == 1 else "|".join(names2)
			if not ModelLibrary._resolved.has(mkey2):
				var h2 := absi(hash(mkey2))
				var mi2: int = int(r.proto_id) * 3 + h2 % 3
				ModelLibrary._resolved[mkey2] = [true, meshes[mi2], part_lists[mi2 % part_lists.size()]]
		again.append(recs2)
	var t_again: Array = []
	for k in 2:
		ChunkView.walk_shape = k == 1
		ChunkView._shape_nat_tried = false
		ChunkView._shape_nat = null
		PipelineWarm._seen_mesh = seen.duplicate()
		for m in meshes:
			PipelineWarm._seen_mesh[m] = true  # (no pipelines compiled in the timing)
		var av: ChunkView = ChunkView.new()
		for r in again[k]:
			av.entities[r.key] = r
		ChunkView.counters.erase("walk_shape_hits")
		var t1 := Time.get_ticks_usec()
		av._walk_records(ChunkView.DrawLists.new(), protos, {}, false, true, av.build_serial)
		t_again.append(Time.get_ticks_usec() - t1)
		if k == 1:
			hits = int(ChunkView.counters.get("walk_shape_hits", 0))
		av.free()
	var n2: int = again[0].size()
	print("walk shapes: first walk of %d records with their shapes known: shapes off %.2f us/rec, on %.2f us/rec (%d hits)" % [
		n2, float(t_again[0]) / n2, float(t_again[1]) / n2, hits])
	# A record with belt ends (or covers) whose shape is known still goes to _walk_rec, its cache untouched.
	var probe_recs: Array = _shape_recs(world_script, 11, 400, 300000).filter(func(r): return _hittable(r))
	var dl := ChunkView.DrawLists.new()
	var kp: Array = [dl.keep.by_model, dl.keep.recs_by_model, dl.keep.parts_by_model, dl.keep.switchable, dl.keep.belt_kinds, dl.keep.rings, dl.keep.belt_lo, dl.keep.belt_hi]
	var mp: Array = [dl.merge.by_model, dl.merge.recs_by_model, dl.merge.parts_by_model, dl.merge.switchable, dl.merge.belt_kinds, dl.merge.rings, dl.merge.belt_lo, dl.merge.belt_hi]
	var fp: Array = [dl.w_off, dl.far_xf, dl.far_type, dl.far_parts, dl.far_slow]
	var all_seen := {}
	for m in meshes:
		all_seen[m] = true
	var pctx: Array = [ModelLibrary.generation, {}, all_seen, {}, ChunkView._proto_row.bind(protos), Callable(ChunkView.FarChunks, &"merges"), ChunkView._shapes, ChunkView._shape_counts, 0]
	var plain: PackedInt32Array = nat.collect_rows(probe_recs, 0, probe_recs.size(), pctx, kp, mp, fp)
	var taken := probe_recs.size() - plain.size()
	for r in probe_recs:
		r.cache_gen = -1
		r.belt_ends = 1
	var ends: PackedInt32Array = nat.collect_rows(probe_recs, 0, probe_recs.size(), pctx, kp, mp, fp)
	var touched := probe_recs.filter(func(r): return r.cache_gen != -1).size()
	print("walk shapes: belt ends: %d of %d taken plainly, %d of them with belt ends (%d caches written)" % [taken, probe_recs.size(), probe_recs.size() - ends.size(), touched])
	if taken == 0 or ends.size() != probe_recs.size() or touched != 0:
		bad += 1
	# The table emptied when the models change.
	ChunkView._shape_tables(protos)
	var before := ChunkView._shapes.size()
	ModelLibrary.generation += 1
	ChunkView._shape_tables(protos)
	if before == 0 or not ChunkView._shapes.is_empty() or not ChunkView._shape_counts.is_empty():
		print("walk shapes: a generation bump left %d templates (had %d)" % [ChunkView._shapes.size(), before])
		bad += 1
	ModelLibrary.generation = gen
	# A pipe as the bridge sends it (`pc` with world.gd's `pc_mod`) keeps the shape path (perf-w4-fix S1).
	var pipe_rec = _shape_rec(world_script, 950001, Vector2(3.5, 3.5), 3, 0, {"pc": 5, "pc_mod": true})
	if int(nat.shape_base(pipe_rec)) < 0:
		print("walk shapes: a pipe with pc_mod has no shape key")
		bad += 1
	# The table emptied when the prototypes are cleared and added again (one ProtoDB, a new welcome: the same
	# instance, shifted ids) and when the models' layout changes (perf-w4-fix M1).
	ChunkView._shape_tables(protos)
	ChunkView._shapes[-12345] = []
	ChunkView._shape_counts[-12345] = 1
	protos.clear()
	var shifted: Array = []
	for row in rows:
		var row2: Array = row.duplicate()
		row2[0] = int(row[0]) + 7
		shifted.append(row2)
	protos.add_entities(shifted)
	ChunkView._shape_tables(protos)
	if not ChunkView._shapes.is_empty() or not ChunkView._shape_counts.is_empty():
		print("walk shapes: protos.clear() + re-add left %d templates" % ChunkView._shapes.size())
		bad += 1
	ChunkView._shapes[-12345] = []
	var layout_was := ModelLibrary.layout_generation
	ModelLibrary.layout_generation += 1
	ChunkView._shape_tables(protos)
	if not ChunkView._shapes.is_empty():
		print("walk shapes: a layout_generation bump left %d templates" % ChunkView._shapes.size())
		bad += 1
	ModelLibrary.layout_generation = layout_was
	# (The test's meshes out of the static tables before quit.)
	ModelLibrary._resolved.clear()
	ModelLibrary._variants.clear()
	PipelineWarm._seen_mesh = {}
	ChunkView._shapes.clear()
	ChunkView._shape_counts.clear()
	ChunkView.native_collect = native_was
	ChunkView.walk_shape = shape_was
	Probing.on = probing_was
	return bad


## Random records of every kind the shape table sees (and some it must leave to _walk_rec).
func _shape_recs(world_script: GDScript, seed: int, n: int, unit0: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var out: Array = []
	for i in n:
		var pid := rng.randi_range(1, 13)
		var extra := {}
		match pid:
			1:
				var s: Variant = [null, "s", "l", "r"][rng.randi_range(0, 3)]
				if s != null:
					extra["s"] = s
			2:
				extra["u"] = "i" if rng.randf() < 0.5 else "o"
			3:
				extra["pc"] = rng.randi_range(0, 15)
				extra["pc_mod"] = true  # (as world.gd sets it on every bridge record with `pc`)
				if rng.randf() < 0.3:
					extra["pw"] = 1
			4:
				extra["pc"] = rng.randi_range(0, 15)
				extra["pc_mod"] = true
			5, 13:
				extra["wc"] = rng.randi_range(0, 31)
				if rng.randf() < 0.3:
					extra["wg"] = rng.randi_range(0, 15)
			6:
				if rng.randf() < 0.5:
					extra["el"] = 1
				extra["sg"] = rng.randi_range(1, 4)
			7:
				if rng.randf() < 0.3:
					extra["fa"] = 1
				if rng.randf() < 0.2:
					extra["q"] = "rare"
			8:
				if rng.randf() < 0.3:
					extra["r"] = [1, 2]
				if rng.randf() < 0.2:
					extra["ai"] = ["item", "iron-plate"]
			10:
				if rng.randf() < 0.5:
					extra["col"] = [200, 30, 30]
			11:
				if rng.randf() < 0.2:
					extra["fa"] = 1
		if rng.randf() < 0.5:
			extra[ModelLibrary.VARIANT_KEY] = hash([i, seed, "variant"])
		if rng.randf() < 0.03:
			extra["zz"] = 1  # unknown: _walk_rec
		if rng.randf() < 0.02:
			extra[ModelLibrary.PACK_KEY] = "p"
		if rng.randf() < 0.02:
			extra["hid"] = 1
		if rng.randf() < 0.01:
			extra["cb"] = 3
		var pos := Vector2(rng.randi_range(-40, 40) + 0.5, rng.randi_range(-40, 40) + 0.5)
		var dir := rng.randi_range(0, 15) if pid == 6 else rng.randi_range(0, 3) * 4  # (signals: 16 ways)
		var r = _shape_rec(world_script, unit0 + i + 1, pos, pid, dir, extra)
		if rng.randf() < 0.03:
			r.covers = 1
		out.append(r)
	return out


## A record the shape table can take (no tree, paint, own pack, unknown key, cargo or covers).
func _hittable(r) -> bool:
	if int(r.proto_id) == 9 or r.covers != 0:
		return false
	for k in ["col", "zz", ModelLibrary.PACK_KEY, "cb", "hid"]:
		if r.extra.has(k):
			return false
	return not (int(r.proto_id) == 11 and r.extra.has("fa"))


func _shape_rec(world_script: GDScript, unit: int, pos: Vector2, pid: int, dir: int, extra: Dictionary):
	var r = world_script.Rec.new()
	r.unit = unit
	r.key = unit if unit % 5 != 0 else "x:%d" % unit
	r.proto_id = pid
	r.pos = pos
	r.fixed = Vector2i(roundi(pos.x * 256.0), roundi(pos.y * 256.0))
	r.dir = dir
	r.extra = extra
	return r


## Two first walks' lists and record caches compared: exact but for the rings (1e-5).
func _shape_compare(a: ChunkView.DrawLists, b: ChunkView.DrawLists, ra: Array, rb: Array, tag: String) -> int:
	var bad := 0
	for side in ["keep", "merge"]:
		var pa: ChunkView.DrawPart = a.keep if side == "keep" else a.merge
		var pb: ChunkView.DrawPart = b.keep if side == "keep" else b.merge
		var ia := _shape_instances(pa)
		var ib := _shape_instances(pb)
		if ia.size() != ib.size():
			print("walk shapes (%s) %s: %d instances vs %d" % [tag, side, ia.size(), ib.size()])
			bad += 1
		for k in ia:
			var x: Array = ia[k]
			var y: Variant = ib.get(k)
			if y == null or x[0] != y[0] or x[1] != y[1] or x[2] != y[2]:
				bad += 1
				if bad < 6:
					print("walk shapes (%s) %s: %s\n  gd     %s\n  shapes %s" % [tag, side, k, x, y])
		for m in pa.parts_by_model:
			if not pb.parts_by_model.has(m) or pa.parts_by_model[m] != pb.parts_by_model[m]:
				bad += 1
				print("walk shapes (%s) %s: parts of %d" % [tag, side, m.get_instance_id()])
		if pa.parts_by_model.size() != pb.parts_by_model.size():
			bad += 1
		var sa: Array = pa.switchable.keys().map(func(k): return str(k))
		var sb: Array = pb.switchable.keys().map(func(k): return str(k))
		sa.sort()
		sb.sort()
		if sa != sb:
			bad += 1
			print("walk shapes (%s) %s: switchable differ" % [tag, side])
		if pa.belt_kinds != pb.belt_kinds or (not pa.belt_kinds.is_empty() and (pa.belt_lo != pb.belt_lo or pa.belt_hi != pb.belt_hi)):
			bad += 1
			print("walk shapes (%s) %s: belt kinds / bounds differ" % [tag, side])
		if pa.waiting != pb.waiting or pa.painted.size() != pb.painted.size():
			bad += 1
			print("walk shapes (%s) %s: waiting / painted differ" % [tag, side])
		if not _rings_close(pa.rings, pb.rings):
			bad += 1
			print("walk shapes (%s) %s: rings differ (%d vs %d)" % [tag, side, pa.rings.size(), pb.rings.size()])
		if not _rings_close(ContactShade.joined(pa.rings), ContactShade.joined(pb.rings)):
			bad += 1
			print("walk shapes (%s) %s: joined rings differ" % [tag, side])
	if a.w_off != b.w_off or a.waiting != b.waiting:
		bad += 1
		print("walk shapes (%s): w_off / waiting differ" % tag)
	for m in a.far_xf:
		var fa: Array = (a.far_xf[m] as Array).map(func(t): return var_to_str(t))
		var fb: Array = (b.far_xf.get(m, []) as Array).map(func(t): return var_to_str(t))
		fa.sort()
		fb.sort()
		if fa != fb or a.far_type[m] != b.far_type.get(m) or a.far_parts[m] != b.far_parts.get(m):
			bad += 1
			print("walk shapes (%s): far lists of %d differ" % [tag, m.get_instance_id()])
	if a.far_xf.size() != b.far_xf.size():
		bad += 1
	var sla: Array = a.far_slow.map(func(r): return str(r.key))
	var slb: Array = b.far_slow.map(func(r): return str(r.key))
	sla.sort()
	slb.sort()
	if sla != slb:
		bad += 1
		print("walk shapes (%s): far_slow differ (%d vs %d)" % [tag, sla.size(), slb.size()])
	# The record caches as _walk_rec fills them.
	for i in ra.size():
		var x = ra[i]
		var y = rb[i]
		if x.cache_gen != y.cache_gen or x.cache_mesh != y.cache_mesh or x.cache_parts != y.cache_parts or x.cache_xform != y.cache_xform \
				or x.cache_is_belt != y.cache_is_belt or x.cache_belt_kind != y.cache_belt_kind or (x.cache_row == null) != (y.cache_row == null) \
				or (x.cache_rings == null) != (y.cache_rings == null) or (x.cache_rings != null and not _rings_close(x.cache_rings, y.cache_rings)):
			bad += 1
			if bad < 12:
				print("walk shapes (%s): record %s cache differs: gen %d/%d xform %s / %s" % [tag, x.key, x.cache_gen, y.cache_gen, x.cache_xform, y.cache_xform])
		elif x.cache_row != null:
			var cx: Array = x.cache_row
			var cy: Array = y.cache_row
			if cx[0] != cy[0] or cx[1] != cy[1] or cx[2] != cy[2] or cx[3] != cy[3] or cx[4] != cy[4] or not _rings_close(cx[5], cy[5]):
				bad += 1
				print("walk shapes (%s): record %s cache_row differs" % [tag, x.key])
	return bad


## A part's instances: "mesh id / record key" -> [Transform3D, type, parts].
func _shape_instances(p: ChunkView.DrawPart) -> Dictionary:
	var out := {}
	for m in p.by_model:
		var xs: Array = p.by_model[m]
		var rs: Array = p.recs_by_model[m]
		for i in xs.size():
			out["%d %s" % [m.get_instance_id(), rs[i][0].key]] = [xs[i], rs[i][1], p.parts_by_model[m]]
	return out


## Two ring lists the same but for float rounding (1e-5), order aside.
func _rings_close(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	var sb: Array = b.duplicate()
	var by_x := func(x: Array, y: Array) -> bool: return float(x[0]) < float(y[0])
	sb.sort_custom(by_x)
	var xs := PackedFloat64Array()
	for g: Array in sb:
		xs.append(float(g[0]))
	var used := {}
	for x: Array in a:
		var j := xs.bsearch(float(x[0]) - 1e-5)
		var found := false
		while j < sb.size() and xs[j] <= float(x[0]) + 1e-5:
			if not used.has(j) and _ring_close(x, sb[j]):
				used[j] = true
				found = true
				break
			j += 1
		if not found:
			return false
	return true


func _ring_close(x: Array, y: Array) -> bool:
	if x.size() != y.size():
		return false
	for j in x.size():
		var u: Variant = x[j]
		var v: Variant = y[j]
		if u is float or v is float:
			if absf(float(u) - float(v)) > 1e-5:
				return false
		elif u is Transform3D and v is Transform3D:
			var tu: Transform3D = u
			var tv: Transform3D = v
			if tu.basis != tv.basis or tu.origin.distance_to(tv.origin) > 1e-5:
				return false
		elif u != v:
			return false
	return true
