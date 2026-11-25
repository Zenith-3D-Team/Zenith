extends SceneTree
## Controlled paired benchmarks (Before = rollback flag vs After = opt enabled) across Track 2
## CPU/streaming and Track 3 geometry/decimation optimizations.
##   godot --headless --audio-driver Dummy --path client --log-file <abs-log> -s res://tests/perf_suite_bench.gd
##   godot --headless --audio-driver Dummy --path client --log-file <abs-log> -s res://tests/perf_suite_bench.gd -- --runs=3 --json=../art-src/check-logs/perf_suite_results.json

const ChunkView := preload("res://scripts/world/chunk_view.gd")
const FarChunks := preload("res://scripts/world/far_chunks.gd")
const ContactShade := preload("res://scripts/world/contact_shade.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const BeltLods := preload("res://scripts/world/belt_lods.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const PipelineWarm := preload("res://scripts/world/pipeline_warm.gd")

var WorldMirror: Script
var _runs := 3
var _json_out := ""
var _results: Array = []


func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--runs="):
			_runs = maxi(1, int(a.get_slice("=", 1)))
		elif a.begins_with("--json="):
			_json_out = a.get_slice("=", 1)
	call_deferred("_run")


func _run() -> void:
	WorldMirror = load("res://scripts/world/world.gd")
	var saved_fast_add: bool = WorldMirror.fast_add
	var saved_shadow_runs: bool = WorldMirror.shadow_row_runs
	var saved_sub_inc: bool = WorldMirror.sub_incremental
	var saved_warm_rings: int = WorldMirror.warm_rings
	var saved_decide_runs := FarChunks.decide_row_runs
	var saved_far_coarse := FarChunks.far_coarse
	var saved_rec_cache := ChunkView.build_rec_cache
	var saved_mm_worker := ChunkView.chunk_mm_worker
	var saved_decimate := ModelLods.tree_shadow_decimate
	var saved_belt_deadband := BeltLods.move_deadband
	var bridge: Node = root.get_node_or_null("Bridge")
	var saved_sq_subs: int = bridge.square_subs if bridge != null else 0

	print("=== Zenith Controlled Benchmark Suite (runs=%d + 1 warmup each) ===" % _runs)
	_results.append(await _bench_fast_add())
	_results.append(await _bench_shadow_row_runs())
	_results.append(await _bench_far_decide_runs())
	_results.append(await _bench_sub_incremental())
	_results.append(_bench_square_rows_grid())
	_results.append(await _bench_build_rec_cache())
	_results.append(await _bench_mm_buffer_prep())
	_results.append(_bench_far_coarse_tris())
	_results.append(_bench_tree_shadow_decimate_tris())
	_results.append(await _bench_belt_lods_deadband())

	WorldMirror.fast_add = saved_fast_add
	WorldMirror.shadow_row_runs = saved_shadow_runs
	WorldMirror.sub_incremental = saved_sub_inc
	WorldMirror.warm_rings = saved_warm_rings
	FarChunks.decide_row_runs = saved_decide_runs
	FarChunks.far_coarse = saved_far_coarse
	ChunkView.build_rec_cache = saved_rec_cache
	ChunkView.chunk_mm_worker = saved_mm_worker
	ModelLods.tree_shadow_decimate = saved_decimate
	BeltLods.move_deadband = saved_belt_deadband
	if bridge != null:
		bridge.square_subs = saved_sq_subs

	_print_table()
	if not _json_out.is_empty():
		_write_json(_json_out)

	await process_frame
	await process_frame
	quit(0)


static func _median(vals: Array) -> float:
	var copy: Array = vals.duplicate()
	copy.sort()
	var n := copy.size()
	if n == 0:
		return 0.0
	if (n & 1) == 1:
		return float(copy[n / 2])
	return (float(copy[n / 2 - 1]) + float(copy[n / 2])) * 0.5


static func _round2(v: float) -> float:
	return snappedf(v, 0.01)


static func _make_entry(id: String, track: String, title: String, unit: String, workload: String,
		before: float, after: float, flag: String, notes: String, main_thread_after := -1.0) -> Dictionary:
	var speedup := before / after if after > 0.0 else 0.0
	var reduction_pct := ((before - after) / before) * 100.0 if before > 0.0 else 0.0
	return {
		"id": id,
		"track": track,
		"name": title,
		"unit": unit,
		"workload": workload,
		"before": _round2(before),
		"after": _round2(after),
		"speedup": _round2(speedup),
		"reduction_pct": _round2(reduction_pct),
		"main_thread_after": _round2(main_thread_after) if main_thread_after >= 0.0 else null,
		"flag": flag,
		"notes": notes,
	}


static func _add_sample_protos(protos: ProtoDB) -> void:
	protos.add_entities([
		[1, "transport-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 0.8, 0.7, 0.2, 1.0, 1.0],
		[2, "inserter", "inserter", -0.4, -0.4, 0.4, 0.4, 0.8, 0.6, 0.2, 1.0, 1.0],
		[3, "stone-wall", "wall", -0.5, -0.5, 0.5, 0.5, 0.6, 0.6, 0.6, 1.0, 1.0],
		[4, "assembling-machine-1", "assembling-machine", -1.4, -1.4, 1.4, 1.4, 0.4, 0.5, 0.7, 3.0, 3.0],
	])


func _cleanup_world(host: Node3D, w: Node) -> void:
	w.set_process(false)
	w._unloaded.clear()
	w._unload_keys.clear()
	w._hide_queue.clear()
	w._shadow_todo = []
	w._shadow_fresh.clear()
	host.queue_free()
	await process_frame
	await process_frame


## 1. WorldMirror entity ingestion & batched join resolution (--world-fast-add=off vs default).
func _bench_fast_add() -> Dictionary:
	var packets: Array = []
	var unit := 1
	for cx in 10:
		for cy in 10:
			var recs: Array = []
			for i in 200:
				var row := i / 20
				var pid := 1 if row < 5 else (3 if row < 8 else (2 if (i % 3) != 0 else 4))
				var fx := (cx * 32 + (i % 20)) * 256 + 128
				var fy := (cy * 32 + row) * 256 + 128
				recs.append([unit, pid, fx, fy, 0 if pid == 1 else (i * 4) % 16])
				unit += 1
			packets.append({"t": "ents", "cx": cx, "cy": cy, "part": 1, "e": recs})

	var run_once := func(use_fast: bool) -> float:
		var host := Node3D.new()
		root.add_child(host)
		var w: Node3D = WorldMirror.new()
		host.add_child(w)
		w.set_process(false)
		_add_sample_protos(w.protos)
		for cx in 10:
			for cy in 10:
				var c := Vector2i(cx, cy)
				var cv := ChunkView.new()
				cv.coord = c
				cv.loaded = true
				w.add_child(cv)
				w.chunks[c] = cv
				w._row_add(c, cv)
		WorldMirror.fast_add = use_fast
		var t0 := Time.get_ticks_usec()
		for p: Dictionary in packets:
			w.handle(p)
		var elapsed := float(Time.get_ticks_usec() - t0) / 1000.0
		await _cleanup_world(host, w)
		return elapsed

	await run_once.call(false)
	var before_runs: Array = []
	var after_runs: Array = []
	for _r in _runs:
		before_runs.append(await run_once.call(false))
		after_runs.append(await run_once.call(true))
	return _make_entry("fast_add", "Track 2", "WorldMirror entity ingestion (fast_add)", "ms",
		"20,000 entities across 100 chunk packets (belts, inserters, walls, assemblers)",
		_median(before_runs), _median(after_runs), "--world-fast-add=off",
		"Integer prototype flags, static-key bypass for connectable/belt sets, batched wall/belt/pipe/cargo joins.")


## 2. Shadow caster update using row-run boundary diffs (--shadow-runs=off vs default).
func _bench_shadow_row_runs() -> Dictionary:
	var run_once := func(use_runs: bool) -> float:
		var host := Node3D.new()
		root.add_child(host)
		var cam := Camera3D.new()
		cam.fov = 55.0
		cam.position = Vector3(0.0, 48.0, 42.0)
		host.add_child(cam)
		cam.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)
		cam.current = true
		var sun := DirectionalLight3D.new()
		sun.shadow_enabled = true
		sun.directional_shadow_max_distance = 180.0
		sun.rotation_degrees = Vector3(-48.0, 32.0, 0.0)
		host.add_child(sun)
		var w: Node3D = WorldMirror.new()
		host.add_child(w)
		w.set_process(false)
		w.sun = sun
		w.shadow_usec = 1000000
		WorldMirror.shadow_row_runs = use_runs
		for cy in range(-12, 13):
			for cx in range(-12, 13):
				var c := Vector2i(cx, cy)
				var cv := ChunkView.new()
				cv.coord = c
				cv.loaded = true
				w.add_child(cv)
				w.chunks[c] = cv
				w._row_add(c, cv)
		w.set_focus(Vector2.ZERO)
		w._update_shadow_casters()

		var t0 := Time.get_ticks_usec()
		for step in 50:
			var x := float(step + 1) * 3.0
			cam.position = Vector3(x, 48.0, 42.0)
			w.set_focus(Vector2(x, 0.0))
			w._update_shadow_casters()
		var elapsed := float(Time.get_ticks_usec() - t0) / 1000.0
		await _cleanup_world(host, w)
		return elapsed

	await run_once.call(false)
	var before_runs: Array = []
	var after_runs: Array = []
	for _r in _runs:
		before_runs.append(await run_once.call(false))
		after_runs.append(await run_once.call(true))
	return _make_entry("shadow_row_runs", "Track 2", "Shadow caster visibility diff (row runs)", "ms",
		"625 chunks (25x25 grid), 50 camera pan steps (3.0 tiles/step)",
		_median(before_runs), _median(after_runs), "--shadow-runs=off",
		"Maintains per-row shadow hull chunk spans and only updates boundary symmetric difference + ring square.")


## 3. FarChunks annulus visibility check (--far-decide-runs=off vs default, with far_coarse=true).
func _bench_far_decide_runs() -> Dictionary:
	var run_once := func(use_runs: bool) -> float:
		var host := Node3D.new()
		root.add_child(host)
		var cam := Camera3D.new()
		cam.fov = 55.0
		cam.position = Vector3(0.0, 65.0, 60.0)
		host.add_child(cam)
		cam.look_at(Vector3(0.0, 0.0, 0.0), Vector3.UP)
		cam.current = true
		var sun := DirectionalLight3D.new()
		sun.directional_shadow_max_distance = 220.0
		host.add_child(sun)
		var w: Node3D = WorldMirror.new()
		host.add_child(w)
		w.set_process(false)
		w.sun = sun
		FarChunks.decide_row_runs = use_runs
		FarChunks.far_coarse = true
		w.far_chunks.enabled = true
		for cy in range(-12, 13):
			for cx in range(-12, 13):
				var c := Vector2i(cx, cy)
				var cv := ChunkView.new()
				cv.coord = c
				cv.loaded = true
				w.add_child(cv)
				w.chunks[c] = cv
				w._row_add(c, cv)
		w.far_chunks.reset_decide()
		cam.position = Vector3(-160.0, 95.0, 80.0)
		cam.look_at(Vector3(-160.0, 0.0, 0.0), Vector3.UP)
		w.set_focus(Vector2(-160.0, 0.0))
		w.far_chunks._decide(1.0)
		while w.far_chunks._pass_next < w.far_chunks._pass_todo.size():
			w.far_chunks._decide_slice()

		var t0 := Time.get_ticks_usec()
		for step in 50:
			var x := -160.0 + float(step + 1) * 8.0
			cam.position = Vector3(x, 95.0, 80.0)
			w.set_focus(Vector2(x, 0.0))
			w.far_chunks._decide(1.0)
			while w.far_chunks._pass_next < w.far_chunks._pass_todo.size():
				w.far_chunks._decide_slice()
		var elapsed := float(Time.get_ticks_usec() - t0) / 1000.0
		await _cleanup_world(host, w)
		return elapsed

	await run_once.call(false)
	var before_runs: Array = []
	var after_runs: Array = []
	for _r in _runs:
		before_runs.append(await run_once.call(false))
		after_runs.append(await run_once.call(true))
	return _make_entry("far_decide_runs", "Track 2", "FarChunks annulus decide (row runs + far_coarse)", "ms",
		"625 chunks (25x25 grid), 50 camera pan steps (4.0 tiles/step), draining slices per step",
		_median(before_runs), _median(after_runs), "--far-decide-runs=off",
		"Compares per-row far/coarse chunk interval runs against prior frame rather than scanning all loaded chunks.")


## 4. Incremental subscription window shift (--sub-incremental=off vs default).
func _bench_sub_incremental() -> Dictionary:
	var radius := 45
	var bridge: Node = root.get_node_or_null("Bridge")
	if bridge != null:
		bridge.square_subs = 50
	WorldMirror.warm_rings = 0

	var run_once := func(use_inc: bool) -> float:
		var host := Node3D.new()
		root.add_child(host)
		var w: Node3D = WorldMirror.new()
		host.add_child(w)
		w.set_process(false)
		w.view_radius = radius
		WorldMirror.sub_incremental = use_inc
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var c := Vector2i(dx, dy)
				var cv := ChunkView.new()
				cv.coord = c
				cv.loaded = true
				w.add_child(cv)
				w.chunks[c] = cv
				w._row_add(c, cv)
				w._asked[c] = true
		w.set_focus(Vector2(16.0, 16.0))
		w._stream_timer = WorldMirror.STREAM_STEP
		w._update_subscription(0.2)

		var t0 := Time.get_ticks_usec()
		for step in 30:
			w.set_focus(Vector2(float(step + 1) * 32.0 + 16.0, 16.0))
			w._stream_timer = WorldMirror.STREAM_STEP
			w._update_subscription(0.2)
		var elapsed := float(Time.get_ticks_usec() - t0) / 1000.0
		await _cleanup_world(host, w)
		return elapsed

	await run_once.call(false)
	var before_runs: Array = []
	var after_runs: Array = []
	for _r in _runs:
		before_runs.append(await run_once.call(false))
		after_runs.append(await run_once.call(true))
	return _make_entry("sub_incremental", "Track 2", "Incremental chunk subscription update", "ms",
		"view_radius=45 (91x91 = 8,281 chunks pre-loaded), 30 chunk-border walk steps",
		_median(before_runs), _median(after_runs), "--sub-incremental=off",
		"O(side) row shift, cursor walk for newly exposed cells, lazy wanted/subscribed materialization.")


## 5. Subscription RLE encoder: Vector2i list vs row-grid PackedByteArray.
func _bench_square_rows_grid() -> Dictionary:
	var radius := 50
	var side := radius * 2 + 1
	var center := Vector2i(10, -5)
	var list: Array = []
	var grid: Array[PackedByteArray] = []
	for dy in side:
		var row := PackedByteArray()
		row.resize(side)
		for dx in side:
			if ((dx * 7 + dy * 13) % 11) != 0:
				row[dx] = 1
				list.append(center + Vector2i(dx - radius, dy - radius))
		grid.append(row)

	var expected_list: Array = WorldMirror.square_rows(center, radius, list)
	var expected_grid: Array = WorldMirror.square_rows_from_rows(center, radius, grid)
	assert(expected_list == expected_grid, "square_rows parity mismatch")

	var measure := func(use_grid: bool) -> float:
		var t0 := Time.get_ticks_usec()
		var sink := 0
		for _i in 100:
			var r: Array = WorldMirror.square_rows_from_rows(center, radius, grid) if use_grid else WorldMirror.square_rows(center, radius, list)
			sink += r.size()
		if sink < 0:
			print(sink)
		return float(Time.get_ticks_usec() - t0) / 1000.0

	measure.call(false)
	var before_runs: Array = []
	var after_runs: Array = []
	for _r in _runs:
		before_runs.append(measure.call(false))
		after_runs.append(measure.call(true))
	return _make_entry("square_rows_grid", "Track 2", "Subscription RLE encoding (row grid vs list)", "ms",
		"radius=50 (101x101 = 10,201 chunks), 100 encode iterations",
		_median(before_runs), _median(after_runs), "--sub-incremental=off",
		"Contiguous PackedByteArray row scans remove per-cell Dictionary/Vector2i hashing.")


## 6. Per-record model/transform/parts cache during chunk rebuilds (--build-rec-cache=off vs default).
func _bench_build_rec_cache() -> Dictionary:
	var protos := ProtoDB.new()
	_add_sample_protos(protos)
	# Warm one real entity model synchronously so ModelLibrary.mesh_for_entity returns a non-null Mesh.
	for _f in 180:
		ModelLibrary.poll()
		if ModelLibrary.entity_ready("assembling-machine-1", "assembling-machine", {}, 0):
			break
		await process_frame
	var loaded_mesh := ModelLibrary.mesh_for_entity("assembling-machine-1", "assembling-machine", {}, 0)
	if loaded_mesh != null:
		PipelineWarm.model_ready(loaded_mesh, "assembling-machine-1", "assembling-machine", {}, 0)

	var recs: Array = []
	for i in 200:
		var r: Object = WorldMirror.Rec.new()
		r.key = i + 1
		r.unit = i + 1
		r.proto_id = 4 if loaded_mesh != null else 1
		r.pos = Vector2(float(i % 10) * 3.0, float(i / 10) * 3.0)
		r.dir = (i * 4) % 16
		r.chunk = Vector2i.ZERO
		recs.append(r)

	var make_cv := func() -> ChunkView:
		var cv := ChunkView.new()
		cv.coord = Vector2i.ZERO
		cv.loaded = true
		for r in recs:
			cv.entities[r.key] = r
		return cv

	var run_once := func(use_cache: bool) -> Dictionary:
		for r in recs:
			r.cache_gen = -1
			r.cache_mesh = null
		ChunkView.build_rec_cache = use_cache
		var cv: ChunkView = make_cv.call()
		# Warm pass builds rec.cache_* when use_cache == true.
		await cv.collect_entities(protos, {}, 0)
		var hits := 0
		for r in recs:
			if int(r.cache_gen) == ModelLibrary.generation and r.cache_mesh != null:
				hits += 1
		var t0 := Time.get_ticks_usec()
		for _i in 50:
			await cv.collect_entities(protos, {}, 0)
		var elapsed := float(Time.get_ticks_usec() - t0) / 1000.0
		cv.free()
		return {"ms": elapsed, "hits": hits}

	await run_once.call(false)
	var before_runs: Array = []
	var after_runs: Array = []
	var cache_hits := 0
	for _r in _runs:
		var rb: Dictionary = await run_once.call(false)
		var ra: Dictionary = await run_once.call(true)
		before_runs.append(rb["ms"])
		after_runs.append(ra["ms"])
		cache_hits = int(ra["hits"])
	var note := "Reuses cached mesh, parts, xform, and belt flags across rebuilds when ModelLibrary.generation matches (hits=%d/200)." % cache_hits
	return _make_entry("build_rec_cache", "Track 2", "ChunkView record lookup cache (collect_entities)", "ms",
		"200 entities/chunk x 50 rebuilds (post warm-up cache hit pass)",
		_median(before_runs), _median(after_runs), "--build-rec-cache=off", note)


## 7. MultiMesh PackedFloat32Array buffer + ContactShade worker preparation (--chunk-mm-worker=off vs default).
func _bench_mm_buffer_prep() -> Dictionary:
	var chunks_n := 10
	var per_chunk := 500
	var box := BoxMesh.new()
	var xforms: Array = []
	var colors: Array = []
	var rings: Array = []
	for i in per_chunk:
		var xf := Transform3D(Basis(), Vector3(float(i % 25) * 1.2, 0.0, float(i / 25) * 1.5))
		xforms.append(xf)
		colors.append(Color(0.8, 0.5, 0.3, 1.0))
		if i < 100:
			ContactShade.collect(rings, "assembling-machine-1", "assembling-machine", box, xf,
				Vector2(-0.4, -0.4), Vector2(0.4, 0.4), Vector2(1.0, 1.0))

	var run_before := func() -> float:
		var host := Node3D.new()
		root.add_child(host)
		var cv := ChunkView.new()
		host.add_child(cv)
		var t0 := Time.get_ticks_usec()
		for _c in chunks_n:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			ChunkView._fill(mm, box, xforms, colors, false)
			var cnode := ContactShade.apply(cv, null, rings)
			if cnode != null:
				cv.remove_child(cnode)
				cnode.free()
		var elapsed := float(Time.get_ticks_usec() - t0) / 1000.0
		host.queue_free()
		await process_frame
		return elapsed

	var run_after := func() -> Dictionary:
		var host := Node3D.new()
		root.add_child(host)
		var cv := ChunkView.new()
		host.add_child(cv)
		var jobs: Array = []
		for _c in chunks_n:
			var j := ChunkView.ChunkPrepJob.new()
			var w := ChunkView.Want.new()
			w.mesh = box
			w.xforms = xforms
			w.colors = colors
			w.with_colors = true
			w.compute_bounds = true
			w.mesh_box = box.get_aabb()
			j.wants = [w]
			j.rings = rings
			j.patch_reach = ContactShade.patch_ring_reach()
			jobs.append(j)
		var t0 := Time.get_ticks_usec()
		var tids := PackedInt32Array()
		for j: ChunkView.ChunkPrepJob in jobs:
			var call_run := func() -> void:
				j.run()
			tids.append(WorkerThreadPool.add_task(call_run))
		for tid: int in tids:
			WorkerThreadPool.wait_for_task_completion(tid)
		var t_main0 := Time.get_ticks_usec()
		for j: ChunkView.ChunkPrepJob in jobs:
			var w0: ChunkView.Want = j.wants[0]
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			cv._fill_buffer(mm, box, w0.xforms.size(), true, false, w0.buf)
			var cnode := ContactShade.apply_prepared(cv, null, j.contact_prep)
			if cnode != null:
				cv.remove_child(cnode)
				cnode.free()
		var main_ms := float(Time.get_ticks_usec() - t_main0) / 1000.0
		var total_ms := float(Time.get_ticks_usec() - t0) / 1000.0
		host.queue_free()
		await process_frame
		return {"total": total_ms, "main": main_ms}

	await run_before.call()
	await run_after.call()
	var before_runs: Array = []
	var after_runs: Array = []
	var main_runs: Array = []
	for _r in _runs:
		before_runs.append(await run_before.call())
		var ra: Dictionary = await run_after.call()
		after_runs.append(ra["total"])
		main_runs.append(ra["main"])
	return _make_entry("mm_buffer_prep", "Track 2", "MultiMesh + ContactShade prep (worker offload)", "ms",
		"10 chunks x 500 instances + 100 contact rings/chunk (5,000 instances total)",
		_median(before_runs), _median(after_runs), "--chunk-mm-worker=off",
		"Main-thread time drops further once packing + ContactShade.prepare() run on WorkerThreadPool.",
		_median(main_runs))


## 8. FarChunks 2nd coarse HLOD tier triangle count & merge cost (--far-coarse=off vs default).
func _bench_far_coarse_tris() -> Dictionary:
	var sphere := SphereMesh.new()
	sphere.radius = 2.0
	sphere.height = 4.0
	sphere.radial_segments = 24
	sphere.rings = 12
	var s_arrs := sphere.get_mesh_arrays()
	var sbake := FarChunks.Bake.new()
	sbake.surfaces = [[s_arrs[Mesh.ARRAY_VERTEX], s_arrs[Mesh.ARRAY_NORMAL], null, null,
		s_arrs[Mesh.ARRAY_INDEX], [FarChunks._surface_params(StandardMaterial3D.new())], null]]
	sbake.run()

	var xforms: Array = []
	for i in 20:
		xforms.append(Transform3D(Basis(), Vector3(float(i % 5) * 4.5, 0.0, float(i / 5) * 4.5)))
	var mat_main := FarChunks.material()
	var mat_nat := FarChunks.nature_material()
	var mat_crown := FarChunks.crown_material()

	var merge_once := func(use_coarse: bool) -> Dictionary:
		var t0 := Time.get_ticks_usec()
		var m := FarChunks.Merge.new()
		m.coarse = use_coarse
		m.groups = [[sbake, xforms, sphere, false]]
		m.material = mat_main
		m.nature_material = mat_nat
		m.crown_material = mat_crown
		m.run()
		var elapsed := float(Time.get_ticks_usec() - t0) / 1000.0
		return {"tris": m.triangles, "ms": elapsed}

	var r_b: Dictionary = merge_once.call(false)
	var r_a: Dictionary = merge_once.call(true)
	return _make_entry("far_coarse_tris", "Track 3", "FarChunks coarse 0.8m HLOD triangle budget", "tris",
		"20 merged SphereMesh buildings (24x12 segments)",
		float(r_b["tris"]), float(r_a["tris"]), "--far-coarse=off",
		"Coarse merge time %.2f ms -> %.2f ms; second tier voxelizes at CELL_COARSE=0.8m below %.1f px/tile." % [
			float(r_b["ms"]), float(r_a["ms"]), FarChunks.COARSE_BELOW_PX])


## 9. Tree leaf-card shadow stand-in 50% decimation (--tree-shadow-decimate=off vs default).
func _bench_tree_shadow_decimate_tris() -> Dictionary:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var seeds := PackedVector2Array()
	# 250 two-triangle leaf cards (500 leaf-card tris) + 100 core triangles = 600 tris.
	for i in 250:
		var base := Vector3(float(i % 10), float(i / 25) * 0.5, float((i / 10) % 10))
		for k in 6:
			verts.append(base + Vector3(0.1 * float(k % 3), 0.1 * float(k / 3), 0.0))
			uvs.append(Vector2(0.5, 0.5))
			seeds.append(Vector2(float(i) * 0.13, float(k)))
	for i in 100:
		var base := Vector3(0.0, 2.0 + float(i) * 0.01, 0.0)
		for k in 3:
			verts.append(base + Vector3(0.1 * float(k), 0.1, 0.0))
			uvs.append(Vector2(-1.0, 0.0))
			seeds.append(Vector2.ZERO)
	var arrs: Array = []
	arrs.resize(Mesh.ARRAY_MAX)
	arrs[Mesh.ARRAY_VERTEX] = verts
	arrs[Mesh.ARRAY_TEX_UV] = uvs
	arrs[Mesh.ARRAY_TEX_UV2] = seeds

	var measure := func(use_dec: bool) -> Dictionary:
		ModelLods.tree_shadow_decimate = use_dec
		var total_tris := 0
		var t0 := Time.get_ticks_usec()
		for _c in 20:
			var out_v := PackedVector3Array()
			var out_uv := PackedVector2Array()
			ModelLods.Job.crown_arrays(arrs, false, out_v, out_uv)
			total_tris += out_v.size() / 3
		var elapsed := float(Time.get_ticks_usec() - t0) / 1000.0
		return {"tris": total_tris, "ms": elapsed}

	var b: Dictionary = measure.call(false)
	var a: Dictionary = measure.call(true)
	return _make_entry("tree_shadow_decimate_tris", "Track 3", "Tree crown shadow stand-in triangle count", "tris",
		"20 tree crowns x (500 leaf-card tris + 100 core tris)",
		float(b["tris"]), float(a["tris"]), "--tree-shadow-decimate=off",
		"Drops odd leaf cards in shadow stand-ins while retaining 100%% of core/strand geometry (bake %.2f ms -> %.2f ms)." % [
			float(b["ms"]), float(a["ms"])])


## 10. BeltLods camera movement deadband (--belt-lods-every-frame vs default).
func _bench_belt_lods_deadband() -> Dictionary:
	var run_once := func(use_deadband: bool) -> float:
		var host := Node3D.new()
		root.add_child(host)
		var cam := Camera3D.new()
		cam.fov = 55.0
		cam.position = Vector3(40.0, 35.0, 35.0)
		host.add_child(cam)
		cam.look_at(Vector3(40.0, 0.0, 0.0), Vector3.UP)
		cam.current = true
		var cvs: Array = []
		for i in 80:
			var cv := ChunkView.new()
			cv.coord = Vector2i(i % 10, i / 10)
			cv.belt_bounds = AABB(Vector3(float(cv.coord.x * 32), 0.0, float(cv.coord.y * 32)), Vector3(32.0, 2.0, 32.0))
			host.add_child(cv)
			BeltLods._chunks[cv] = true
			cvs.append(cv)
		BeltLods.move_deadband = use_deadband
		BeltLods._last_view = []
		BeltLods._timer = 1.0
		BeltLods.update(null, cam, 0.016)

		var t0 := Time.get_ticks_usec()
		for step in 500:
			cam.position = Vector3(40.0 + sin(float(step) * 0.25) * 0.25, 35.0, 35.0)
			BeltLods.update(null, cam, 0.008)
		var elapsed := float(Time.get_ticks_usec() - t0) / 1000.0
		BeltLods._chunks.clear()
		BeltLods._last_view = []
		host.queue_free()
		await process_frame
		return elapsed

	await run_once.call(false)
	var before_runs: Array = []
	var after_runs: Array = []
	for _r in _runs:
		before_runs.append(await run_once.call(false))
		after_runs.append(await run_once.call(true))
	return _make_entry("belt_lods_deadband", "Track 2", "BeltLods sub-4m camera jitter skip", "ms",
		"80 belt chunks, 500 frames with 0.25m sub-deadband camera sway",
		_median(before_runs), _median(after_runs), "--belt-lods-every-frame",
		"Quantizes camera position to distance-scaled >=4.0m grid and angles to 0.1 deg steps before scanning chunk AABBs.")


func _print_table() -> void:
	print("")
	print("%-28s %-8s %-12s %-12s %-9s %-9s" % ["Benchmark", "Unit", "Before", "After", "Speedup", "Delta%"])
	print("-".repeat(82))
	for row: Dictionary in _results:
		var line := "%-28s %-8s %-12.2f %-12.2f %-8.2fx %-8.1f%%" % [
			str(row["id"]), str(row["unit"]), float(row["before"]), float(row["after"]),
			float(row["speedup"]), -float(row["reduction_pct"])]
		print(line)
		if row["main_thread_after"] != null:
			print("  -> main-thread apply slice only: %.2f %s" % [float(row["main_thread_after"]), str(row["unit"])])
	print("")


func _write_json(path: String) -> void:
	var resolved := path
	if not resolved.is_absolute_path() and not resolved.begins_with("res://") and not resolved.begins_with("user://"):
		resolved = ProjectSettings.globalize_path("res://" + resolved)
	else:
		resolved = ProjectSettings.globalize_path(resolved)
	DirAccess.make_dir_recursive_absolute(resolved.get_base_dir())
	var payload := {
		"meta": {
			"runs_per_bench": _runs,
			"engine": Engine.get_version_info().get("string", "Godot"),
			"renderer": RenderingServer.get_video_adapter_name(),
			"cpu_count": OS.get_processor_count(),
		},
		"benchmarks": _results,
	}
	var f := FileAccess.open(resolved, FileAccess.WRITE)
	if f == null:
		push_error("perf_suite_bench: cannot write JSON to %s (err %d)" % [resolved, FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify(payload, "\t") + "\n")
	f.close()
	print("Wrote benchmark JSON: ", resolved)
