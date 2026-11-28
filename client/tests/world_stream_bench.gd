extends SceneTree
## World streaming replay bench (perf-rd-world task 1): a recorded session's `protos`/`chunk`/`ents`
## messages (tools/bench/world_stream.py records the mock's busy base) through world.gd `handle` and the
## chunk builds with no server; prints µs per entity for add, collect (first build, a build for the view
## alone, a build for a change), apply and the far gather, and hashes of every chunk's wants and far groups:
## the parity check for --collect-cache (task 2), equal with the switch on and off.
##   godot --headless --audio-driver Dummy --path client --log-file <abs-log> -s res://tests/world_stream_bench.gd \
##       -- --input=<abs .jsonl> [--json=<abs out>] [--loops=3] [--collect-cache=off]

const ChunkView := preload("res://scripts/world/chunk_view.gd")
const FarChunks := preload("res://scripts/world/far_chunks.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")

var _input := ""
var _json_out := ""
var _loops := 3
var _ms := {}
var _hashes := {}
var _entities := 0
var _dump := ""  # --dump=<abs dir>: every hash's rows written there (a parity failure's diff)
var _dump_rows := {}


func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--input="):
			_input = a.get_slice("=", 1)
		elif a.begins_with("--json="):
			_json_out = a.get_slice("=", 1)
		elif a.begins_with("--dump="):
			_dump = a.get_slice("=", 1)
		elif a.begins_with("--loops="):
			_loops = maxi(1, int(a.get_slice("=", 1)))
	call_deferred("_run")


func _run() -> void:
	var msgs: Array = []
	var f := FileAccess.open(_input, FileAccess.READ)
	if f == null:
		print("WORLD_STREAM_BENCH FAIL: no input ", _input)
		quit(1)
		return
	while not f.eof_reached():
		var line := f.get_line()
		if line.is_empty():
			continue
		var m: Variant = JSON.parse_string(line)
		if m is Dictionary:
			msgs.append(m)
	f.close()
	var host := Node3D.new()
	root.add_child(host)
	var w: Node3D = load("res://scripts/world/world.gd").new()
	host.add_child(w)
	w.set_process(false)
	var far: FarChunks = w.far_chunks
	# No camera here: left running, the far merge would count every chunk far and merge it, and the
	# builds below would be merged ones. Each phase says near or far itself.
	far.set_process(false)
	print("collect_cache=", FarChunks.collect_cache, " messages=", msgs.size())

	# The chunks asked for (world.gd makes a ChunkView when it subscribes), then every message through
	# handle, as the bridge hands them over (timed: add).
	for m: Dictionary in msgs:
		if str(m.get("t", "")) == "chunk":
			w._spawn_chunk(Vector2i(int(m.get("cx", 0)), int(m.get("cy", 0))), [])
	var t0 := Time.get_ticks_usec()
	for m: Dictionary in msgs:
		w.handle(m)
	_ms["add"] = (Time.get_ticks_usec() - t0) / 1000.0
	var cvs: Array = []
	for c: Vector2i in w.chunks:
		var cv: ChunkView = w.chunks[c]
		if not cv.entities.is_empty():
			cvs.append(cv)
			_entities += cv.entities.size()
	cvs.sort_custom(func(a: ChunkView, b: ChunkView) -> bool: return a.coord.y < b.coord.y or (a.coord.y == b.coord.y and a.coord.x < b.coord.x))
	print("chunks=", cvs.size(), " entities=", _entities)

	# Models made (untimed): builds and far gathers until none waits for one, or 30 s. The far gather and
	# the belts' end pieces ask for models a near build may not have asked for yet (a model finishing
	# part-way through the phases would make the two settings' hashes differ by timing alone).
	var until := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < until:
		ModelLibrary.poll()
		var waiting := false
		for cv: ChunkView in cvs:
			await cv.collect_entities(w.protos, w.working, 0, false)
			waiting = waiting or cv.waiting_models or cv.belt_waiting
			var ws := FarChunks.State.new()
			for rec in cv.entities.values():
				far._gather(cv, ws, rec)
				if rec.belt_ends != 0:
					var pr = w.protos.entity(rec.proto_id)
					if pr != null:
						for place: Array in ModelLibrary.belt_end_places(pr.name, pr.type, rec.dir, rec.pos, rec.belt_ends):
							waiting = (not ModelLibrary.ready(place[0])) or waiting
		if not waiting:
			break
		await process_frame
	w._dirty.clear()
	w._dirty_live.clear()

	# First build: the records' caches empty.
	for cv: ChunkView in cvs:
		for rec in cv.entities.values():
			rec.cache_gen = -1
	_ms["collect_first"] = 0.0
	_ms["apply"] = 0.0
	for cv: ChunkView in cvs:
		cv.draw_rev += 1
		t0 = Time.get_ticks_usec()
		await cv.collect_entities(w.protos, w.working, 0, false)
		_ms["collect_first"] += (Time.get_ticks_usec() - t0) / 1000.0
		t0 = Time.get_ticks_usec()
		var job: ChunkView.ChunkPrepJob = cv._prep_pending
		cv._prep_pending = null
		job.run()
		await cv.apply_prepared(job, w.working, null, null, 0)
		_ms["apply"] += (Time.get_ticks_usec() - t0) / 1000.0
	# More first builds (the records' caches emptied each time), averaged with the one above.
	for _l in _loops - 1:
		_ms["collect_first"] += await _first_builds(w, cvs)
	_ms["collect_first"] /= _loops
	_dump_phase = "first"
	_hashes["first"] = await _wants_hash(w, cvs, false, false)

	# A build for the view alone (far <-> near swap, stand-ins ready), then one for a change.
	_ms["collect_view"] = await _timed_builds(w, cvs, true)
	_dump_phase = "view"
	_hashes["view"] = await _wants_hash(w, cvs, true, false)
	_ms["collect_change"] = await _timed_builds(w, cvs, false)
	_dump_phase = "change"
	_hashes["change"] = await _wants_hash(w, cvs, false, false)

	# Far gather.
	_dump_phase = "far"
	var tf := 0
	var far_hash := 0
	for _l in _loops:
		for cv: ChunkView in cvs:
			var s := FarChunks.State.new()
			t0 = Time.get_ticks_usec()
			var recs: Array = cv.entities.values()
			if FarChunks.collect_cache and far.fill_from_lists(cv, s):
				recs = cv.draw_lists.far_slow
			for rec in recs:
				far._gather(cv, s, rec)
			tf += Time.get_ticks_usec() - t0
			if _l == 0:
				far_hash = hash([far_hash, _groups_hash(s.groups, "far %s" % cv.coord)])
	_ms["far_gather"] = tf / 1000.0 / _loops
	_dump_phase = "far"
	_hashes["far"] = far_hash

	# A far chunk's first build (merged: the merge draws what it leaves out), with its far gather after:
	# what a chunk that streams in far costs (off: the build skips the merged records, the gather reads
	# every record; on: the build reads them all, the gather the lists).
	for cv: ChunkView in cvs:
		cv.far.far = true
		cv.far.covers = true
	var t_ff := 0.0
	var t_fg := 0
	for _l in _loops:
		t_ff += await _first_builds(w, cvs)
		for cv: ChunkView in cvs:
			var s := FarChunks.State.new()
			t0 = Time.get_ticks_usec()
			var recs: Array = cv.entities.values()
			if FarChunks.collect_cache and far.fill_from_lists(cv, s):
				recs = cv.draw_lists.far_slow
			for rec in recs:
				far._gather(cv, s, rec)
			t_fg += Time.get_ticks_usec() - t0
	_ms["collect_first_far"] = t_ff / _loops
	_ms["far_first_total"] = t_ff / _loops + t_fg / 1000.0 / _loops
	for cv: ChunkView in cvs:
		cv.far.far = false
		cv.far.covers = false
	await _timed_builds(w, cvs, false)  # near again, lists made near (as the phases below expect)

	# Near -> far -> near: merged builds leave out what the merge draws, built again for the view alone.
	for cv: ChunkView in cvs:
		cv.far.far = true
		cv.far.covers = true
	_dump_phase = "merged"
	_hashes["merged"] = await _wants_hash(w, cvs, true, false)
	for cv: ChunkView in cvs:
		cv.far.far = false
		cv.far.covers = false
	_dump_phase = "unmerged"
	_hashes["unmerged"] = await _wants_hash(w, cvs, true, false)

	# A state change: every other unit working (placeholders lighter, cards running, switched-off belts).
	var n := 0
	for cv: ChunkView in cvs:
		for rec in cv.entities.values():
			n += 1
			w.working[rec.unit] = 1 if (n % 2) == 0 else (2 if (n % 7) == 0 else 0)
	_dump_phase = "state"
	_hashes["state"] = await _wants_hash(w, cvs, true, false)

	# Models arriving late (ModelLibrary.generation goes up).
	ModelLibrary.generation += 1
	_dump_phase = "generation"
	_hashes["generation"] = await _wants_hash(w, cvs, true, false)

	# Live edits: one record per chunk rotated, one removed and added back.
	for cv: ChunkView in cvs:
		var keys: Array = cv.entities.keys()
		keys.sort()
		var rec = cv.entities[keys[keys.size() / 2]]
		rec.dir = (int(rec.dir) + 4) % 16
		rec.cache_gen = -1
	_dump_phase = "rotate"
	_hashes["rotate"] = await _wants_hash(w, cvs, false, true)
	var removed := {}
	for cv: ChunkView in cvs:
		var keys: Array = cv.entities.keys()
		keys.sort()
		removed[cv] = cv.entities[keys[0]]
		cv.entities.erase(keys[0])
	_dump_phase = "remove"
	_hashes["remove"] = await _wants_hash(w, cvs, false, true)
	for cv: ChunkView in cvs:
		var rec = removed[cv]
		cv.entities[rec.key] = rec
	_dump_phase = "add_back"
	_hashes["add_back"] = await _wants_hash(w, cvs, false, true)

	var per := {}
	for k: String in _ms:
		per[k] = 1000.0 * float(_ms[k]) / maxf(1.0, float(_entities))
	print("ms: ", JSON.stringify(_ms))
	print("us_per_entity: ", JSON.stringify(per))
	print("hashes: ", JSON.stringify(_hashes))
	print("counters: lists_kept=%d lists_walked=%d far_from_lists=%d" % [int(ChunkView.counters.get("lists_kept", 0)),
		int(ChunkView.counters.get("lists_walked", 0)), int(ChunkView.counters.get("far_from_lists", 0))])
	if not _json_out.is_empty():
		var o := FileAccess.open(_json_out, FileAccess.WRITE)
		o.store_string(JSON.stringify({"collect_cache": FarChunks.collect_cache, "entities": _entities, "chunks": cvs.size(),
			"ms": _ms, "us_per_entity": per, "hashes": _hashes}, "\t"))
		o.close()
	if not _dump.is_empty():
		DirAccess.make_dir_recursive_absolute(_dump)
		for ph: String in _dump_rows:
			var d := FileAccess.open(_dump.path_join(ph + ".txt"), FileAccess.WRITE)
			d.store_string("\n".join(_dump_rows[ph]))
			d.close()
	print("WORLD_STREAM_BENCH PASS")
	w.set_process(false)
	host.queue_free()
	await process_frame
	quit(0)


## ms for every chunk's first build (the records' caches emptied, a change: lists made again).
func _first_builds(w, cvs: Array) -> float:
	var t := 0
	for cv: ChunkView in cvs:
		for rec in cv.entities.values():
			rec.cache_gen = -1
		cv.draw_rev += 1
		var t0 := Time.get_ticks_usec()
		await cv.collect_entities(w.protos, w.working, 0, false)
		t += Time.get_ticks_usec() - t0
		cv._prep_pending = null
	return t / 1000.0


## ms per pass over every chunk's records' pass (averaged over the loops): `reuse` a build for the view alone,
## else one for a change in what it holds (ChunkView.draw_rev up, as world.gd _build_for_view).
func _timed_builds(w, cvs: Array, reuse: bool) -> float:
	var t := 0
	for _l in _loops:
		for cv: ChunkView in cvs:
			if not reuse:
				cv.draw_rev += 1
			var t0 := Time.get_ticks_usec()
			await cv.collect_entities(w.protos, w.working, 0, reuse)
			t += Time.get_ticks_usec() - t0
			cv._prep_pending = null
	return t / 1000.0 / _loops


## Every chunk built once more (`reuse` as world.gd would pass it; `change` bumps draw_rev first): a hash of
## its wants (key, instance count, the transforms and colours, order aside).
func _wants_hash(w, cvs: Array, reuse: bool, change: bool) -> int:
	var h := 0
	for cv: ChunkView in cvs:
		if change or not reuse:
			cv.draw_rev += 1
		await cv.collect_entities(w.protos, w.working, 0, reuse and not change)
		var job: ChunkView.ChunkPrepJob = cv._prep_pending
		cv._prep_pending = null
		var rows: Array[String] = []
		if job != null:
			for want: ChunkView.Want in job.wants:
				var xs := 0
				for x: Transform3D in want.xforms:
					xs += hash(str(x))
				var cs := 0
				for col in want.colors:
					cs += hash(str(col))
				rows.append("%s|%s|%d|%d|%d|%d" % [_key_str(want.key), _key_str(want.mesh), want.xforms.size(), xs, cs, want.switches.size()])
			rows.append("ph%d|ore%d|belt%s" % [job.placeholder_keys.size(), job.ore_near.size(), str(job.belt_models.size())])
		rows.sort()
		h = hash([h, cv.coord, "\n".join(rows)])
		_note_rows("wants %s" % cv.coord, rows)
	return h


func _note_rows(tag: String, rows: Array[String]) -> void:
	if not _dump.is_empty():
		var a: Array = _dump_rows.get_or_add(_dump_phase, [])
		a.append(tag)
		a.append_array(rows)


var _dump_phase := ""


func _groups_hash(groups: Dictionary, tag: String) -> int:
	var rows: Array[String] = []
	for mesh in groups:
		var xs := 0
		for x in groups[mesh]:
			xs += hash(str(x))
		rows.append("%s|%d|%d" % [_key_str(mesh), (groups[mesh] as Array).size(), xs])
	rows.sort()
	_note_rows(tag, rows)
	return hash("\n".join(rows))


## A stable name for a want's key across runs (no instance ids).
static func _key_str(k) -> String:
	if k is Array:
		var parts: Array[String] = []
		for e in k:
			parts.append(_key_str(e))
		return "[" + ",".join(parts) + "]"
	if k is Mesh:
		var m: Mesh = k
		if not m.resource_path.is_empty():
			return m.resource_path
		return "%s:%s:%d:%s" % [m.get_class(), m.resource_name, m.get_surface_count(), str(m.get_aabb())]
	return str(k)
