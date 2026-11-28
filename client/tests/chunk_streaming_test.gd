extends Node
## Regression & integration tests for fast & seamless world streaming:
## FarChunks urgent priority promotion, atomic reveal / chunk_ready, double-buffered refresh,
## optimistic RAM cache promotion/reconciliation, Zstd ChunkDiskCache persistence/LRU pruning,
## and adaptive sliding window + flight velocity lookahead.

const TestEnv := preload("res://tests/test_env.gd")
const FrameBudget := preload("res://scripts/world/frame_budget.gd")
const FarChunks := preload("res://scripts/world/far_chunks.gd")
const WorldMirror := preload("res://scripts/world/world.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")
const ChunkDiskCache := preload("res://scripts/world/chunk_disk_cache.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const LampLights := preload("res://scripts/world/lamp_lights.gd")
const SignalLights := preload("res://scripts/world/signal_lights.gd")
const RemoteFog := preload("res://scripts/world/remote_fog.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const BeltLods := preload("res://scripts/world/belt_lods.gd")
const BehindCull := preload("res://scripts/world/behind_cull.gd")
const ViewPriority := preload("res://scripts/world/view_priority.gd")
const Probing := preload("res://scripts/debug/probing.gd")

var passes := 0
var fails := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		passes += 1
	else:
		fails += 1
		print("FAIL: %s" % msg)


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	TestEnv.isolate("chunk_streaming_test")
	var cap_was = Bridge.capture
	Bridge.capture = []

	await _test_far_urgent_budget()
	await _test_atomic_reveal_and_far_cover()
	_test_double_buffered_refresh()
	_test_optimistic_ram_cache()
	_test_optimistic_slice()
	_test_ents_slice()
	_test_delta_behind_slices()
	_test_covers_batch()
	_test_queue_order()
	await _test_chunk_disk_cache()
	_test_disk_flush_fine()
	_test_adaptive_window_and_lookahead()
	await _test_far_chunks_freed_queue_safety()
	_test_far_hidden_dropped_mmi()
	await _test_lights_stagger_fog_and_culling()
	await _test_dh_handoff()
	await _test_moving_stutter_fixes()
	await _test_unload_fast()

	Bridge.capture = cap_was
	TestEnv.clean()
	await get_tree().process_frame
	print("chunk_streaming_test: %d passed, %d failed" % [passes, fails])
	print("FAILS: %d" % fails)
	get_tree().quit(1 if fails > 0 else 0)


func _make_world(si := 1) -> WorldMirror:
	var w := WorldMirror.new()
	add_child(w)
	w.set_process(false)
	w.surface_index = si
	w.protos.add_tiles([[0, "grass-1", 80, 120, 60]])
	w.protos.add_entities([[1, "wooden-chest", 1.0, 1.0, 0, "container"]])
	return w


func _test_far_urgent_budget() -> void:
	var shared_was := FrameBudget.shared
	var boost_was := FrameBudget.far_priority_boost
	FrameBudget.shared = true
	FrameBudget.far_priority_boost = true
	FrameBudget.reset()
	FrameBudget.test_no_deadline = true
	FrameBudget.test_other_usec = 6000
	FrameBudget.far_urgent = true
	await get_tree().process_frame
	FrameBudget.waiting(&"messages", 40)
	FrameBudget.waiting(&"build", 10)
	FrameBudget.waiting(&"decoratives", 10)
	FrameBudget.waiting(&"far_collect", 5)
	FrameBudget.waiting(&"far_install", 5)
	var g_collect := FrameBudget.grant(&"far_collect")
	var g_install := FrameBudget.grant(&"far_install")
	var g_dec := FrameBudget.grant(&"decoratives")
	check(g_collect >= 600 and g_install >= 600 and g_dec == 0,
		"far_urgent promotes uncovered far_collect (%d) and far_install (%d) ahead of decoratives (%d)" % [g_collect, g_install, g_dec])

	FrameBudget.far_priority_boost = false
	FrameBudget.reset()
	FrameBudget.test_other_usec = 6000
	await get_tree().process_frame
	var m := FrameBudget.grant(&"messages")
	FrameBudget.spent(&"messages", m, 0)
	var b := FrameBudget.grant(&"build")
	FrameBudget.spent(&"build", b, 10)
	var legacy_collect := FrameBudget.grant(&"far_collect")
	check(legacy_collect == 0, "--far-priority=legacy restores priority-8 yielding while builds wait (%d)" % legacy_collect)

	FrameBudget.far_urgent = false
	FrameBudget.far_priority_boost = boost_was
	FrameBudget.shared = shared_was
	FrameBudget.test_other_usec = -1
	FrameBudget.test_no_deadline = false
	FrameBudget.reset()


func _test_atomic_reveal_and_far_cover() -> void:
	var atomic_was := WorldMirror.atomic_reveal
	WorldMirror.atomic_reveal = true
	var w := _make_world(1)
	var ready_chunks: Array[Vector2i] = []
	var drawn_chunks: Array[Vector2i] = []
	w.chunk_ready.connect(func(c: Vector2i) -> void: ready_chunks.append(c))
	w.chunk_drawn.connect(func(c: Vector2i) -> void: drawn_chunks.append(c))

	# 1. Held until entity build completes.
	var c0 := Vector2i(0, 0)
	var cv0 := ChunkView.new()
	cv0.coord = c0
	w.chunks[c0] = cv0
	w.add_child(cv0)
	w.handle({"t": "chunk", "cx": 0, "cy": 0, "rs": 1, "rv": 1, "n": 1, "parts": 1, "tiles": [0, 1024]})
	cv0.apply_kept_terrain(ArrayMesh.new(), PackedInt32Array(), false)
	w._on_terrain_applied(c0, cv0)
	check(not cv0.revealed and cv0._terrain_held and cv0._terrain != null and not cv0._terrain.visible and ready_chunks.is_empty() and drawn_chunks.is_empty(),
		"atomic reveal holds terrain invisible while initial entity snapshot is incomplete/dirty")
	w.handle({"t": "ents", "cx": 0, "cy": 0, "part": 1, "parts": 1, "e": [[10, 1, 256, 256, 0]]})
	w._dirty.erase(c0)
	w._built(c0, cv0, Time.get_ticks_usec())
	check(cv0.revealed and not cv0._terrain_held and cv0._terrain.visible and ready_chunks == [c0] and drawn_chunks == [c0],
		"atomic reveal flips terrain visible and emits chunk_ready once entities finish building")

	# 2. Far-skipped chunk stays unrevealed until on_far_covered().
	var c1 := Vector2i(5, 0)
	var cv1 := ChunkView.new()
	cv1.coord = c1
	w.chunks[c1] = cv1
	w.add_child(cv1)
	w.handle({"t": "chunk", "cx": 5, "cy": 0, "rs": 1, "rv": 1, "n": 1, "parts": 1, "tiles": [0, 1024]})
	w.handle({"t": "ents", "cx": 5, "cy": 0, "part": 1, "parts": 1, "e": [[11, 1, 5 * 32 * 256 + 128, 128, 0]]})
	cv1.far.far = true
	cv1.far.full = false
	cv1.far.covers = false
	w._dirty.erase(c1)
	cv1.apply_kept_terrain(ArrayMesh.new(), PackedInt32Array(), true)
	w._on_terrain_applied(c1, cv1)
	check(not cv1.revealed and cv1._terrain_held and not w._drawn(c1),
		"atomic reveal holds far-skipped chunk until FarChunks cover is installed")
	cv1.far.covers = true
	w.on_far_covered(c1)
	check(cv1.revealed and not cv1._terrain_held and w._drawn(c1) and ready_chunks.has(c1),
		"on_far_covered immediately reveals far chunk and emits chunk_ready")

	# 3. Timeout fallback reveals even if far cover/parts stall past REVEAL_HOLD_MSEC.
	var c2 := Vector2i(6, 0)
	var cv2 := ChunkView.new()
	cv2.coord = c2
	w.chunks[c2] = cv2
	w.add_child(cv2)
	w.handle({"t": "chunk", "cx": 6, "cy": 0, "rs": 1, "rv": 1, "n": 0, "parts": 1, "tiles": [0, 1024]})
	cv2.apply_kept_terrain(ArrayMesh.new(), PackedInt32Array(), false)
	w._on_terrain_applied(c2, cv2)
	check(not cv2.revealed, "new incomplete chunk held initially")
	cv2.tiles_msec = Time.get_ticks_msec() - WorldMirror.REVEAL_HOLD_MSEC - 50
	w._rebuild_dirty()
	check(cv2.revealed and not cv2._terrain_held and not w._held_reveal.has(c2),
		"atomic reveal timeout fallback guarantees terrain never stays hidden indefinitely")

	# 4. --atomic-chunk-reveal=off shows terrain immediately.
	WorldMirror.atomic_reveal = false
	var c3 := Vector2i(7, 0)
	var cv3 := ChunkView.new()
	cv3.coord = c3
	w.chunks[c3] = cv3
	w.add_child(cv3)
	w.handle({"t": "chunk", "cx": 7, "cy": 0, "rs": 1, "rv": 1, "n": 1, "parts": 1, "tiles": [0, 1024]})
	cv3.apply_kept_terrain(ArrayMesh.new(), PackedInt32Array(), false)
	w._on_terrain_applied(c3, cv3)
	check(cv3.revealed and not cv3._terrain_held and cv3._terrain.visible,
		"--atomic-chunk-reveal=off reveals terrain immediately before entities arrive")

	WorldMirror.atomic_reveal = atomic_was
	w.queue_free()
	await get_tree().process_frame


func _test_double_buffered_refresh() -> void:
	var db_was := WorldMirror.double_buffer_refresh
	WorldMirror.double_buffer_refresh = true
	var w := _make_world(1)
	var c := Vector2i(1, 1)
	var cv := ChunkView.new()
	cv.coord = c
	w.chunks[c] = cv
	w.add_child(cv)
	w.handle({"t": "chunk", "cx": 1, "cy": 1, "rs": 1, "rv": 1, "n": 1, "parts": 1, "tiles": [0, 1024]})
	w.handle({"t": "ents", "cx": 1, "cy": 1, "part": 1, "parts": 1, "e": [[100, 1, 32 * 256 + 128, 32 * 256 + 128, 0]]})
	check(cv.entities.has(100) and w.entities.has(100), "initial entity loaded before double-buffered refresh")

	# Incoming multi-part refresh stages while keeping old entity intact, and preserves live deltas.
	w.handle({"t": "chunk", "cx": 1, "cy": 1, "rs": 1, "rv": 2, "n": 2, "parts": 2, "tiles": [0, 1024]})
	w.handle({"t": "ents", "cx": 1, "cy": 1, "part": 1, "parts": 2, "e": [[200, 1, 32 * 256 + 256, 32 * 256 + 128, 0]]})
	w.handle({"t": "add", "e": [202, 1, 32 * 256 + 512, 32 * 256 + 128, 0]})
	check(w._staged_snap.has(c) and cv.entities.has(100) and not cv.entities.has(200),
		"double-buffered refresh keeps old entities drawn until final ents part arrives")

	w.handle({"t": "ents", "cx": 1, "cy": 1, "part": 2, "parts": 2, "e": [[201, 1, 32 * 256 + 384, 32 * 256 + 128, 0]]})
	check(not w._staged_snap.has(c) and not cv.entities.has(100) and not w.entities.has(100)
		and cv.entities.has(200) and cv.entities.has(201) and cv.entities.has(202),
		"double-buffered refresh swaps atomically on final part and replays buffered live deltas")

	# Timeout commits partial staged refresh cleanly.
	w.handle({"t": "chunk", "cx": 1, "cy": 1, "rs": 1, "rv": 3, "n": 1, "parts": 2, "tiles": [0, 1024]})
	w.handle({"t": "ents", "cx": 1, "cy": 1, "part": 1, "parts": 2, "e": [[300, 1, 32 * 256 + 128, 32 * 256 + 128, 0]]})
	w._staged_snap[c]["msec"] = Time.get_ticks_msec() - WorldMirror.PARTS_WAIT_MSEC - 50
	w._rebuild_dirty()
	check(not w._staged_snap.has(c) and cv.entities.has(300) and not cv.entities.has(200),
		"double-buffered refresh timeout commits partial snapshot after PARTS_WAIT_MSEC")

	WorldMirror.double_buffer_refresh = db_was
	w.queue_free()


func _test_optimistic_ram_cache() -> void:
	var opt_was := WorldMirror.optimistic_cache
	WorldMirror.optimistic_cache = true
	var w := _make_world(1)
	var c := Vector2i(2, 2)
	var cv := ChunkView.new()
	cv.coord = c
	w.chunks[c] = cv
	w.add_child(cv)
	var cx_f := 2 * 32 * 256 + 128
	var cy_f := 2 * 32 * 256 + 128
	w.handle({"t": "chunk", "cx": 2, "cy": 2, "rs": 1, "rv": 5, "n": 1, "parts": 1, "tiles": [0, 1024]})
	w.handle({"t": "ents", "cx": 2, "cy": 2, "part": 1, "parts": 1, "e": [[500, 1, cx_f, cy_f, 0]]})
	w._unload(c)
	w._remove(500)

	# Spawning again hydrates immediately from RAM cache and promotes in place on `same`.
	var have: Array = []
	w._spawn_chunk(c, have)
	w._process_optimistic()
	var cv2: ChunkView = w.chunks.get(c)
	check(have.size() == 1 and have[0] == [1, 2, 2, 5, 1] and cv2 != null and cv2.loaded and cv2.optimistic and cv2.entities.has(500),
		"optimistic cache hydrates unloaded chunk immediately on spawn while offering [1,2,2,5,1]")
	var prev_cache := int(ChunkView.counters.get("cache_hit", 0))
	w.handle({"t": "chunk", "cx": 2, "cy": 2, "rs": 1, "same": 5})
	check(not cv2.optimistic and w._live.get(c, []) == [1, 5, 1] and ChunkView.counters.get("cache_hit", 0) == prev_cache,
		"server `same` promotes optimistic chunk directly without re-parsing/replaying cache messages")

	# Mismatch with new snapshot replaces seamlessly via double buffer.
	w._unload(c)
	w._remove(500)
	have.clear()
	w._spawn_chunk(c, have)
	w._process_optimistic()
	var cv3: ChunkView = w.chunks.get(c)
	check(cv3 != null and cv3.optimistic and cv3.entities.has(500), "re-spawned optimistically before server mismatch")
	w.handle({"t": "chunk", "cx": 2, "cy": 2, "rs": 1, "rv": 6, "n": 1, "parts": 1, "tiles": [0, 1024]})
	w.handle({"t": "ents", "cx": 2, "cy": 2, "part": 1, "parts": 1, "e": [[501, 1, cx_f + 256, cy_f, 0]]})
	check(not cv3.optimistic and cv3.entities.has(501) and not cv3.entities.has(500),
		"fresh server snapshot cleanly replaces mismatched optimistic chunk")

	WorldMirror.optimistic_cache = opt_was
	w.queue_free()


## Spikes part B: a chunk from the cache replayed a step at a time inside the `hydrate` slice (its chunk message, each
## entities message), left part-way to the next frame; dropped when the bridge's own copy comes or the chunk goes;
## --optimistic-slice=off: whole in one call as before.
func _test_optimistic_slice() -> void:
	var opt_was := WorldMirror.optimistic_cache
	var slice_was := WorldMirror.optimistic_slice
	WorldMirror.optimistic_cache = true
	WorldMirror.optimistic_slice = true
	var w := _make_world(1)
	var c := Vector2i(3, 3)
	var cv := ChunkView.new()
	cv.coord = c
	w.chunks[c] = cv
	w.add_child(cv)
	var base := 3 * 32 * 256 + 128
	w.handle({"t": "chunk", "cx": 3, "cy": 3, "rs": 1, "rv": 7, "n": 3, "parts": 3, "tiles": [0, 1024]})
	for part in 3:
		w.handle({"t": "ents", "cx": 3, "cy": 3, "part": part + 1, "parts": 3, "e": [[700 + part, 1, base + part * 256, base, 0]]})
	check(cv.entities.size() == 3, "optimistic slice: the chunk's three parts in")
	var forget := func() -> void:
		w._unload(c)
		for u in [700, 701, 702, 799]:
			w._remove(u)
	forget.call()
	var have: Array = []
	w._spawn_chunk(c, have)
	var cv2: ChunkView = w.chunks.get(c)
	w.hydrate_test_usec = 1  # one step a call
	w._process_optimistic()
	check(cv2 != null and cv2.loaded and cv2.optimistic and cv2.entities.is_empty() and not w._hyd.is_empty(),
		"optimistic slice: a tight slice replays the chunk message alone, the rest left to the next frame")
	w._process_optimistic()
	check(cv2.entities.size() == 1 and not w._optimistic_rv.has(c), "optimistic slice: then one entities message a frame")
	w._process_optimistic()
	w._process_optimistic()
	check(cv2.entities.size() == 3 and w._hyd.is_empty() and cv2.optimistic and w._optimistic_rv.get(c, []) == [1, 7, 3],
		"optimistic slice: done after its last step, as a whole replay leaves it (%s)" % [w._optimistic_rv.get(c, [])])
	# The bridge's own snapshot arriving part-way: the replay is dropped, the cache's entities not added after it.
	forget.call()
	have.clear()
	w._spawn_chunk(c, have)
	var cv3: ChunkView = w.chunks.get(c)
	w._process_optimistic()
	w.handle({"t": "chunk", "cx": 3, "cy": 3, "rs": 1, "rv": 8, "n": 1, "parts": 1, "tiles": [0, 1024]})
	w.handle({"t": "ents", "cx": 3, "cy": 3, "part": 1, "parts": 1, "e": [[799, 1, base, base + 256, 0]]})
	w._process_optimistic()
	w._process_optimistic()
	check(w._hyd.is_empty() and not cv3.optimistic and cv3.entities.has(799) and not cv3.entities.has(700),
		"optimistic slice: the bridge's snapshot part-way through drops the replay")
	# The chunk going part-way.
	forget.call()
	have.clear()
	w._spawn_chunk(c, have)
	w._process_optimistic()
	w._unload(c)
	w._process_optimistic()
	check(w._hyd.is_empty(), "optimistic slice: a chunk unloaded part-way drops the replay")
	# A generous slice: the whole chunk in one call.
	w.hydrate_test_usec = 1000000
	have.clear()
	w._spawn_chunk(c, have)
	w._process_optimistic()
	var cv4: ChunkView = w.chunks.get(c)
	check(cv4 != null and w._hyd.is_empty() and cv4.optimistic and cv4.entities.size() >= 1,
		"optimistic slice: with room the whole chunk in one call")
	# --optimistic-slice=off: whole in one call whatever the slice.
	WorldMirror.optimistic_slice = false
	forget.call()
	have.clear()
	w._spawn_chunk(c, have)
	w.hydrate_test_usec = 1
	w._process_optimistic()
	var cv5: ChunkView = w.chunks.get(c)
	check(cv5 != null and cv5.optimistic and w._hyd.is_empty() and w._optimistic_rv.has(c),
		"--optimistic-slice=off: the whole chunk in one call")
	WorldMirror.optimistic_slice = slice_was
	WorldMirror.optimistic_cache = opt_was
	w.queue_free()


## Perf wave 4 task 1: a packed `ents` message applied ENTS_SLICE records at a time, from the cache (_hydrate_step)
## and live while the bridge drains (Bridge.requeue_front), ends as the whole message leaves it; --ents-slice=off.
const ENTS_C := Vector2i(4, 4)


func _ents_world() -> WorldMirror:
	var w := _make_world(1)
	# [id, name, type, box min x, y, max x, y, r, g, b, tiles w, h]
	w.protos.add_entities([[2, "wooden-chest", "container", -0.4, -0.4, 0.4, 0.4, 1, 1, 1, 1, 1],
		[3, "pipe", "pipe", -0.4, -0.4, 0.4, 0.4, 1, 1, 1, 1, 1],
		[4, "transport-belt", "transport-belt", -0.4, -0.4, 0.4, 0.4, 1, 1, 1, 1, 1],
		[5, "stone-wall", "wall", -0.4, -0.4, 0.4, 0.4, 1, 1, 1, 1, 1],
		[6, "storage-tank", "storage-tank", -0.4, -0.4, 0.4, 0.4, 1, 1, 1, 1, 1],
		[7, "pipe-to-ground", "pipe-to-ground", -0.4, -0.4, 0.4, 0.4, 1, 1, 1, 1, 1]])
	# Connections on the tank's own tile, as a real one's are inside its box: no two records' on one tile.
	w.fluid_ports_from({6: {"x": {"fb": [[0.0, 0.0, 0], [0.0, 0.0, 4], [0.0, 0.0, 8]]}}})
	w._belt_ends_on = 1
	var cv := ChunkView.new()
	cv.coord = ENTS_C
	w.chunks[ENTS_C] = cv
	w.add_child(cv)
	return w


## [packed e, xi, xe] of `n` random records over the chunk's tiles (seeded).
func _ents_records(n: int, seed_v: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var e := PackedInt32Array()
	var xi := PackedInt32Array()
	var xe: Array = []
	for i in n:
		var tx := i % 32
		var ty := (i / 32) % 32
		var proto := rng.randi_range(2, 7)
		e.append_array([10000 + i, proto, (ENTS_C.x * 32 + tx) * 256 + 128, (ENTS_C.y * 32 + ty) * 256 + 128, 4 * rng.randi_range(0, 3)])
		var ex := {}
		if proto == 3 and rng.randf() < 0.5:
			ex["pc"] = rng.randi_range(0, 15)
		elif proto == 6:
			ex["fa"] = 3
		elif proto == 5 and rng.randf() < 0.5:
			ex["wc"] = rng.randi_range(0, 15)
		elif proto == 2 and rng.randf() < 0.3:
			ex["x"] = i
		if not ex.is_empty():
			xi.append(i)
			xe.append(ex)
	return [e, xi, xe]


func _ents_msgs(recs: Array, rv: int) -> Array:
	return [{"t": "chunk", "cx": ENTS_C.x, "cy": ENTS_C.y, "rs": 1, "rv": rv, "n": 1, "parts": 1, "tiles": [0, 1024]},
		{"t": "ents", "cx": ENTS_C.x, "cy": ENTS_C.y, "part": 1, "parts": 1, "e": recs[0], "xi": recs[1], "xe": recs[2]}]


static func _sorted_pairs(d: Dictionary) -> Array:
	var out: Array = []
	for k in d:
		out.append([str(k), str(d[k])])
	out.sort()
	return out


## What the world holds after the records: every record's fields, covers and extras, the join tables, the dirty set.
func _ents_state(w: WorldMirror) -> Array:
	var rows: Array = []
	for key in w.entities:
		var r = w.entities[key]
		rows.append([str(key), r.proto_id, r.fixed, r.dir, r.covers, str(r.cover_ports), r.belt_ends,
			str(r.extra.get("pc", "-")), str(r.extra.get("pw", "-")), str(r.extra.get("wc", "-")), r.extra.size(), r.chunk])
	rows.sort()
	var dirty: Array = []
	for c in w._dirty:
		dirty.append(str(c))
	dirty.sort()
	return [rows, _sorted_pairs(w._pipes), _sorted_pairs(w._belts), _sorted_pairs(w._walls), dirty,
		_sorted_pairs(w._port_tiles), _sorted_pairs(w._port_targets)]


## Hydrates ENTS_C from the RAM cache one step a call: [calls it took, most records one step added, part noted only
## at the end].
func _ents_hydrate(w: WorldMirror, n: int) -> Array:
	var msgs := _ents_msgs(_ents_records(n, 11), 9)
	for m: Dictionary in msgs:
		w.handle(m)
	w._unload(ENTS_C)
	for i in n:
		w._remove(10000 + i)
	w._dirty.clear()
	var have: Array = []
	w._spawn_chunk(ENTS_C, have)
	w.hydrate_test_usec = 1
	var calls := 0
	var most := 0
	var mid_ok := true
	var cv: ChunkView = w.chunks.get(ENTS_C)
	while calls < 200:
		var before := cv.entities.size()
		w._process_optimistic()
		calls += 1
		most = maxi(most, cv.entities.size() - before)
		if not w._hyd.is_empty() and cv.entities.size() > 0 and cv.entities.size() < n and not cv.parts_got.is_empty():
			mid_ok = false
		if w._hyd.is_empty() and w._optimistic_queue.is_empty():
			break
	return [calls, most, mid_ok]


func _test_ents_slice() -> void:
	var opt_was := WorldMirror.optimistic_cache
	var slice_was := WorldMirror.optimistic_slice
	var ents_was := WorldMirror.ents_slice
	WorldMirror.optimistic_cache = true
	WorldMirror.optimistic_slice = true
	var n := 1000
	# A 1,000-record cached chunk replayed one step a call, sliced vs --ents-slice=off.
	WorldMirror.ents_slice = true
	var ws := _ents_world()
	var hs := _ents_hydrate(ws, n)
	var state_s := _ents_state(ws)
	WorldMirror.ents_slice = false
	var wo := _ents_world()
	var ho := _ents_hydrate(wo, n)
	var state_o := _ents_state(wo)
	var expect_calls := 1 + ceili(n / float(WorldMirror.ENTS_SLICE))
	print("ents slice: sliced %d calls (most %d records a step), off %d calls (%d records)" % [hs[0], hs[1], ho[0], ho[1]])
	check(int(hs[0]) == expect_calls and int(hs[1]) <= WorldMirror.ENTS_SLICE and bool(hs[2]),
		"ents slice: a 1,000-record cached chunk replays <= %d records a step (%d calls, most %d a step)" % [WorldMirror.ENTS_SLICE, hs[0], hs[1]])
	check(int(ho[0]) == 2 and int(ho[1]) == n, "--ents-slice=off: the whole message in one step (%d calls)" % ho[0])
	check((state_s[0] as Array).size() == n and state_s == state_o,
		"ents slice: records, covers, extras (pc, pw, wc), pipes/belts/walls, ports and the dirty set as unsliced (%d records)" % (state_s[0] as Array).size())
	var cvs: ChunkView = ws.chunks.get(ENTS_C)
	check(cvs.optimistic and ws._optimistic_rv.get(ENTS_C, []) == [1, 9, 1] and cvs.parts_got.has(1),
		"ents slice: the chunk left as a whole replay leaves it (rv, part noted)")
	ws.queue_free()
	wo.queue_free()
	# A live `ents` while the bridge drains: the first slice now, the rest in front of the waiting messages.
	var head_was: Array = Bridge._replay_head
	var at_was: int = Bridge._replay_at
	var drain_was: bool = Bridge._draining
	Bridge._replay_head = []
	Bridge._replay_at = 0
	WorldMirror.ents_slice = true
	var wl := _ents_world()
	var live_msgs := _ents_msgs(_ents_records(n, 23), 4)
	wl.handle(live_msgs[0])
	Bridge._draining = true
	wl.handle(live_msgs[1])
	Bridge._draining = drain_was
	var cvl: ChunkView = wl.chunks.get(ENTS_C)
	var first := cvl.entities.size()
	var queued: int = Bridge._replay_head.size() - Bridge._replay_at
	while Bridge._replay_at < Bridge._replay_head.size():
		var rp = Bridge._replay_head[Bridge._replay_at]
		Bridge._replay_at += 1
		rp.run()
	Bridge._replay_head = head_was
	Bridge._replay_at = at_was
	WorldMirror.ents_slice = false
	var ww := _ents_world()
	ww.handle(live_msgs[0])
	ww.handle(live_msgs[1])
	check(first == WorldMirror.ENTS_SLICE and queued == expect_calls - 2,
		"ents slice live: %d records at once, %d slices queued in front" % [first, queued])
	check(_ents_state(wl) == _ents_state(ww) and cvl.parts_got.has(1), "ents slice live: ends as the whole message does")
	wl.queue_free()
	ww.queue_free()
	# _xi_cursors as _add_packed's own cursor, also with xi repeated or out of order.
	var odd := {"e": PackedInt32Array(), "xi": PackedInt32Array([3, 70, 70, 200, 130]), "xe": [{}, {}, {}, {}, {}]}
	var cur := WorldMirror._xi_cursors(odd, 300)
	check(cur == PackedInt32Array([0, 1, 2, 2, 2]), "ents slice: xi cursors stop at a repeated or behind index (%s)" % [cur])
	# _pack_cache_entry: parts joined with append_array vs record by record, on random entries.
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var same := true
	for trial in 20:
		var msgs: Array = [{"t": "chunk", "parts": 3}]
		var wide := trial % 5 == 4
		for part in rng.randi_range(2, 5):
			var recs := _ents_records(rng.randi_range(0, 150), trial * 10 + part)
			var e: Variant = recs[0]
			if wide:
				var e64 := PackedInt64Array(Array(recs[0]))
				if part == 0 and e64.size() > 0:
					e64[0] = 1099511627776
				e = e64
			msgs.append({"e": e, "xi": recs[1], "xe": recs[2]})
		WorldMirror.ents_slice = false
		var old_a := WorldMirror._pack_cache_entry({"msgs": msgs})
		var old_b := WorldMirror._pack_cache_entry({"msgs": msgs}, false)
		WorldMirror.ents_slice = true
		var new_a := WorldMirror._pack_cache_entry({"msgs": msgs})
		var new_b := WorldMirror._pack_cache_entry({"msgs": msgs}, false)
		if old_a != new_a or str(old_b) != str(new_b) or typeof(old_a[0]) != typeof(new_a[0]):
			same = false
	check(same, "ents slice: multi-part cache pack joined with append_array equals the record-by-record copy")
	# The optimistic queue sorted by packed keys: the same ranks in order as sort_custom.
	var wq := _make_world(1)
	wq._focus = Vector2(40, -70)
	var center := wq.chunk_of(wq._focus)
	for i in 300:
		wq._optimistic_queue.append(Vector2i(rng.randi_range(-30, 30), rng.randi_range(-30, 30)))
	wq._opt_queue_gen += 1
	var ref: Array = wq._optimistic_queue.duplicate()
	var cmp := func(a: Vector2i, b: Vector2i) -> bool:
		return wq._build_rank(a, center) < wq._build_rank(b, center)
	ref.sort_custom(cmp)
	wq._sort_optimistic_queue()
	var ranks_ok := ref.size() == wq._optimistic_queue.size()
	for i in ref.size():
		if wq._build_rank(ref[i], center) != wq._build_rank(wq._optimistic_queue[i], center):
			ranks_ok = false
	var key_was: Array = wq._opt_sorted_key
	wq._optimistic_queue.pop_front()
	wq._sort_optimistic_queue()
	check(ranks_ok and wq._opt_sorted_key == key_was, "ents slice: optimistic queue ranks as sort_custom's, not sorted again after a pop")
	wq.queue_free()
	WorldMirror.ents_slice = ents_was
	WorldMirror.optimistic_slice = slice_was
	WorldMirror.optimistic_cache = opt_was


## perf-w4-fix M2: a `del` and an `upd` for records in a live `ents` message's unapplied slices (the replay head),
## routed and handled through the real Bridge's _drain: neither takes the priority lane ahead of the slices, so the
## deleted record isn't added back (a ghost) and the update isn't overwritten by the slice's older record.
func _test_delta_behind_slices() -> void:
	var ents_was := WorldMirror.ents_slice
	WorldMirror.ents_slice = true
	var saved := {}
	for k in ["priority_queue", "coalesce_updates", "belt_messages_first", "connected", "world_ready", "_seq_connected",
			"_seq_world_ready", "drain_head_again", "prio_delta_order", "_replay_head", "_replay_at", "_waiting", "_waiting_at",
			"_waiting_len", "_waiting_usec", "_waiting_checked", "_prio_waiting", "_chunk_waiting", "_prio_barriers"]:
		saved[k] = Bridge.get(k)
	Bridge.priority_queue = true
	Bridge.coalesce_updates = true
	Bridge.belt_messages_first = true
	Bridge.connected = true
	Bridge.world_ready = true
	Bridge._seq_connected = true
	Bridge._seq_world_ready = true
	Bridge.drain_head_again = false  # (the slices left in the head after the first drain: the window under test)
	Bridge.prio_delta_order = true
	Bridge._replay_head = []
	Bridge._replay_at = 0
	Bridge._waiting = []
	Bridge._waiting_at = 0
	Bridge._waiting_len = PackedInt32Array()
	Bridge._waiting_usec = PackedInt64Array()
	Bridge._waiting_checked = PackedByteArray()
	Bridge._prio_waiting = []
	Bridge._chunk_waiting = {}
	Bridge._prio_barriers = 0
	var n := 1000
	var recs := _ents_records(n, 23)
	var e: PackedInt32Array = recs[0]
	var gone := 600  # (records in the 10th and 8th slices)
	var turned := 500
	var w := _ents_world()
	Bridge.message_received.connect(w.handle)
	Bridge._route(_ents_msgs(recs, 4), PackedInt32Array(), Time.get_ticks_usec())
	var frames := 0
	while Bridge._replay_head.size() - Bridge._replay_at == 0 and Bridge.waiting_count() > 0 and frames < 50:
		FrameBudget.test_next_frame()
		Bridge._drain()
		frames += 1
	var head_left: int = Bridge._replay_head.size() - Bridge._replay_at
	var b := gone * 5
	var del_msg := {"t": "del", "u": e[b], "p": e[b + 1], "x": e[b + 2], "y": e[b + 3]}
	var t := turned * 5
	var new_dir := (e[t + 4] + 4) % 16
	var upd_msg := {"t": "upd", "e": [e[t], e[t + 1], e[t + 2], e[t + 3], new_dir]}
	Bridge._route([del_msg, upd_msg], PackedInt32Array(), Time.get_ticks_usec())
	var prio_now: int = Bridge._prio_waiting.size()
	frames = 0
	while Bridge.waiting_count() > 0 and frames < 200:
		FrameBudget.test_next_frame()
		Bridge._drain()
		frames += 1
	Bridge.message_received.disconnect(w.handle)
	var ghost: bool = w.entities.has(e[b])
	var r_t = w.entities.get(e[t])
	check(head_left > 0 and prio_now == 0,
		"delta behind slices: the del/upd wait behind %d queued slices, not in the priority lane (%d there)" % [head_left, prio_now])
	check(not ghost, "delta behind slices: a record deleted while its slice waited stays deleted (no ghost)")
	check(r_t != null and int(r_t.dir) == new_dir,
		"delta behind slices: an upd for a record in a waiting slice is not overwritten (dir %s, want %d)" % [str(r_t.dir) if r_t != null else "none", new_dir])
	w.queue_free()
	for k in saved:
		Bridge.set(k, saved[k])
	WorldMirror.ents_slice = ents_was


## Perf wave 4 task 3: pipe covers worked out once a message (_join_covers) with memoised connections, vs
## --covers-batch=off: random machines, pipes and pipes to ground added, moved and added again in one message.
## `n` records of `units` on free tiles of the two chunks (`at`: tile -> unit, unit -> tile, kept across messages): a
## unit sent again leaves its old tile (as _add_fields' _remove does), so no two records ever share a tile.
func _covers_records(rng: RandomNumberGenerator, units: Array, n: int, at: Dictionary) -> Array:
	var e := PackedInt32Array()
	var xi := PackedInt32Array()
	var xe: Array = []
	for i in n:
		var unit: int = units[rng.randi_range(0, units.size() - 1)]
		var tile := Vector2i(rng.randi_range(0, 63), rng.randi_range(0, 31))
		while at.has(tile):
			tile = Vector2i(rng.randi_range(0, 63), rng.randi_range(0, 31))
		if at.has(unit):
			at.erase(at[unit])
		at[unit] = tile
		at[tile] = unit
		var pick := rng.randi_range(0, 9)
		var proto := 3 if pick < 4 else (7 if pick < 6 else (6 if pick < 8 else 8))
		e.append_array([unit, proto, (ENTS_C.x * 32 + tile.x) * 256 + 128, (ENTS_C.y * 32 + tile.y) * 256 + 128, 4 * rng.randi_range(0, 3)])
		var ex := {}
		if proto == 3 and rng.randf() < 0.6:
			ex["pc"] = rng.randi_range(0, 15)
		elif proto == 8:
			ex["fa"] = rng.randi_range(0, 3)
		if not ex.is_empty():
			xi.append(i)
			xe.append(ex)
	return [e, xi, xe]


func _covers_world(batch: bool) -> WorldMirror:
	var was := WorldMirror.covers_batch
	WorldMirror.covers_batch = batch
	var w := _ents_world()
	w.protos.add_entities([[8, "assembling-machine-2", "assembling-machine", -0.4, -0.4, 0.4, 0.4, 1, 1, 1, 1, 1]])
	w.fluid_ports_from({6: {"x": {"fb": [[0.0, 0.0, 0], [0.0, 0.0, 4], [0.0, 0.0, 8]]}},
		8: {"x": {"fb": [[0.0, 0.0, 0, "i"], [0.0, 0.0, 8, "o"], [0.0, 0.0, 12, "b"]]}}})
	var c2 := ENTS_C + Vector2i(1, 0)
	var cv2 := ChunkView.new()
	cv2.coord = c2
	w.chunks[c2] = cv2
	w.add_child(cv2)
	WorldMirror.covers_batch = was
	return w


func _covers_state(w: WorldMirror) -> Array:
	var rows: Array = []
	for key in w.entities:
		var r = w.entities[key]
		rows.append([str(key), r.proto_id, r.fixed, r.dir, r.covers, str(r.cover_ports),
			str(r.extra.get("pc", "-")), str(r.extra.get("pw", "-"))])
	rows.sort()
	var dirty: Array = []
	for c in w._dirty:
		dirty.append(str(c))
	dirty.sort()
	return [rows, dirty, _sorted_pairs(w._pipes), _sorted_pairs(w._port_tiles), _sorted_pairs(w._port_targets)]


func _diff_dbg(a: Array, b: Array) -> void:
	for i in a.size():
		if a[i] != b[i]:
			var x: Array = a[i]
			var y: Array = b[i]
			print("DBG part %d sizes %d %d" % [i, x.size(), y.size()])
			for j in mini(x.size(), y.size()):
				if x[j] != y[j]:
					print("DBG  a ", x[j])
					print("DBG  b ", y[j])
					break
			return


func _test_covers_batch() -> void:
	var was := WorldMirror.covers_batch
	var all_same := true
	var covered := 0
	var cover_checks := 0
	var usec := [0, 0]
	for trial in 6:
		var states: Array = []
		for batch in [true, false]:
			WorldMirror.covers_batch = batch
			var w := _covers_world(batch)
			var rng := RandomNumberGenerator.new()
			rng.seed = 900 + trial
			var first: Array = []
			for u in 500:
				first.append(30000 + u)
			var again: Array = first.slice(0, 250)
			for u in 250:
				again.append(31000 + u)
			w.handle({"t": "chunk", "cx": ENTS_C.x, "cy": ENTS_C.y, "rs": 1, "rv": 1, "n": 1, "parts": 2, "tiles": [0, 1024]})
			w.handle({"t": "chunk", "cx": ENTS_C.x + 1, "cy": ENTS_C.y, "rs": 1, "rv": 1, "n": 1, "parts": 1, "tiles": [0, 1024]})
			var at := {}
			var r1 := _covers_records(rng, first, 500, at)
			w.handle({"t": "ents", "cx": ENTS_C.x, "cy": ENTS_C.y, "part": 1, "parts": 2, "e": r1[0], "xi": r1[1], "xe": r1[2]})
			w._dirty.clear()
			# One message adding new records, moving and adding again old ones (each _remove'd first), some twice.
			var r2 := _covers_records(rng, again, 400, at)
			var t_msg := Time.get_ticks_usec()
			w.handle({"t": "ents", "cx": ENTS_C.x, "cy": ENTS_C.y, "part": 2, "parts": 2, "e": r2[0], "xi": r2[1], "xe": r2[2]})
			usec[0 if batch else 1] += Time.get_ticks_usec() - t_msg
			check(w._join_covers.is_empty(), "covers batch: nothing left to cover after the message")
			states.append(_covers_state(w))
			if batch:
				for key in w.entities:
					var r = w.entities[key]
					if r.proto_id == 6 or r.proto_id == 8:
						cover_checks += 1
						if r.covers != 0:
							covered += 1
			w.queue_free()
		if states[0] != states[1]:
			all_same = false
			_diff_dbg(states[0], states[1])
	check(all_same and cover_checks > 0 and covered > 0 and covered < cover_checks,
		"covers batch: every record's covers, cover_ports, pc/pw, ports and the dirty set as --covers-batch=off (%d machines, %d with covers)" % [cover_checks, covered])
	WorldMirror.covers_batch = was
	print("covers batch: %d machines (%d with covers); 6 messages of 400 records %.1f ms batched vs %.1f ms off" % [cover_checks, covered, usec[0] / 1000.0, usec[1] / 1000.0])


## Perf wave 4 task 5: the build queues put in order by packed keys (_rank_order) as sort_custom(nearer) did, ties
## aside; dirty chunks that can't be built yet left out before ranking; --queue-order=old.
func _test_queue_order() -> void:
	var was := WorldMirror.queue_order_old
	WorldMirror.queue_order_old = false
	var w := _make_world(1)
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var all_ok := true
	for trial in 8:
		w._dirty_live.clear()
		w._live_prep.clear()
		w._wanted_f = [Vector2i.ZERO, Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, -1)][trial % 4]
		var center := Vector2i(rng.randi_range(-20, 20), rng.randi_range(-20, 20))
		var cs: Array = []
		for i in rng.randi_range(1, 600):
			var c := Vector2i(rng.randi_range(-40, 40), rng.randi_range(-40, 40))
			cs.append(c)
			if rng.randf() < 0.1:
				w._dirty_live[c] = true
			elif rng.randf() < 0.05:
				w._live_prep[c] = true
		var nearer := func(a: Vector2i, b: Vector2i) -> bool:
			var a_live := WorldMirror.fast_edit_rebuild and (w._dirty_live.has(a) or w._live_prep.has(a))
			var b_live := WorldMirror.fast_edit_rebuild and (w._dirty_live.has(b) or w._live_prep.has(b))
			if a_live != b_live:
				return a_live
			return w._build_rank(a, center) < w._build_rank(b, center)
		var ref: Array = cs.duplicate()
		ref.sort_custom(nearer)
		var got: Array = w._build_order(cs.duplicate(), center, nearer)
		var key_of := func(c: Vector2i) -> Array:
			return [w._dirty_live.has(c) or w._live_prep.has(c), w._build_rank(c, center)]
		if got.size() != ref.size():
			all_ok = false
			continue
		for i in ref.size():
			if key_of.call(ref[i]) != key_of.call(got[i]):
				all_ok = false
				break
		var sorted_a := cs.duplicate()
		sorted_a.sort()
		var sorted_b := got.duplicate()
		sorted_b.sort()
		if sorted_a != sorted_b:
			all_ok = false
	check(all_ok, "queue order: packed ranks in sort_custom(nearer)'s order (live first, then _build_rank) on random queues")
	# How long each takes on 1,000 chunks waiting (headless, this PC).
	var big: Array = []
	for i in 1000:
		big.append(Vector2i(rng.randi_range(-40, 40), rng.randi_range(-40, 40)))
	var cz := Vector2i.ZERO
	var nearer_t := func(a: Vector2i, b: Vector2i) -> bool:
		var a_live := WorldMirror.fast_edit_rebuild and (w._dirty_live.has(a) or w._live_prep.has(a))
		var b_live := WorldMirror.fast_edit_rebuild and (w._dirty_live.has(b) or w._live_prep.has(b))
		if a_live != b_live:
			return a_live
		return w._build_rank(a, cz) < w._build_rank(b, cz)
	var t_a := Time.get_ticks_usec()
	big.duplicate().sort_custom(nearer_t)
	var t_b := Time.get_ticks_usec()
	w._rank_order(big, cz)
	var t_c := Time.get_ticks_usec()
	print("queue order: 1,000 chunks sort_custom %.2f ms vs packed ranks %.2f ms" % [(t_b - t_a) / 1000.0, (t_c - t_b) / 1000.0])
	# Dirty chunks that would only be passed over aren't ranked: one building, one with a prep job, one gone stays in.
	w._dirty_live.clear()
	w._live_prep.clear()
	w._dirty.clear()
	var ready := ChunkView.new()
	var busy := ChunkView.new()
	busy.building = true
	var prepped := ChunkView.new()
	for pair in [[Vector2i(1, 1), ready], [Vector2i(2, 1), busy], [Vector2i(3, 1), prepped]]:
		w.chunks[pair[0]] = pair[1]
		w.add_child(pair[1])
		w._dirty[pair[0]] = true
	w._prep_jobs[Vector2i(3, 1)] = null
	w._dirty[Vector2i(9, 9)] = true
	var can := w._buildable_dirty(Time.get_ticks_msec())
	can.sort()
	check(can == [Vector2i(1, 1), Vector2i(9, 9)], "queue order: a building chunk and one with a prep job left out of the ranking (%s)" % [can])
	w._prep_jobs.clear()
	busy.building = false
	# --queue-order=old: sort_custom as before.
	WorldMirror.queue_order_old = true
	var cmp_called := [0]
	var nearer_old := func(a: Vector2i, b: Vector2i) -> bool:
		cmp_called[0] += 1
		return a.x < b.x
	var old_order: Array = w._build_order([Vector2i(3, 0), Vector2i(1, 0), Vector2i(2, 0)], Vector2i.ZERO, nearer_old)
	check(cmp_called[0] > 0 and old_order == [Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)], "--queue-order=old: sort_custom(nearer)")
	WorldMirror.queue_order_old = was
	w.queue_free()


## Perf wave 4 task 4: the disk cache's sliced flush checks the clock after every chunk and copies a chunk's extras
## FLUSH_XE_BATCH at a time, its copies let go on the write worker; byte-equal region files to --disk-flush-fine=off.
func _fine_cache(dir: String, ph: int, chunks_n: int, extras: int) -> ChunkDiskCache:
	var dc := ChunkDiskCache.new()
	dc.configure("save_fine", 1, ph, dir)
	dc.clear_disk()
	dc.configure("save_fine", 1, ph, dir)
	var tiles := PackedInt32Array()
	tiles.resize(1024)
	tiles.fill(0)
	for k in chunks_n:
		var e := PackedInt32Array()
		var xi := PackedInt32Array()
		var xe: Array = []
		for i in extras:
			e.append_array([50000 + k * extras + i, 1, (k % 20) * 8192 + i, (k / 20) * 8192, 0])
			xi.append(i)
			xe.append({"pc": (i + k) % 16, "n": "x%d" % i, "l": [i, {"d": k}]})
		dc.put_chunk(k % 20, k / 20, 3, 1, tiles, e, xi, "", xe)
	for r in dc._regions:
		for ck in dc._regions[r]:
			dc._regions[r][ck]["saved"] = 1  # the same on both caches
	return dc


func _test_disk_flush_fine() -> void:
	var fine_was := ChunkDiskCache.flush_fine
	var async_was := ChunkDiskCache.async_encode
	var sliced_was := ChunkDiskCache.flush_sliced
	ChunkDiskCache.async_encode = true
	ChunkDiskCache.flush_sliced = true
	var p := ProtoDB.new()
	p.add_tiles([[0, "grass-1", 80, 120, 60]])
	var ph := ChunkDiskCache.compute_proto_hash(p)
	var results: Array = []
	for fine in [true, false]:
		ChunkDiskCache.flush_fine = fine
		var dc := _fine_cache("user://test-zchk-fine-%s" % ("on" if fine else "off"), ph, 300, 500)
		var steps := 0
		var most_us := 0
		var t := Time.get_ticks_usec()
		dc.flush_async()
		most_us = Time.get_ticks_usec() - t
		steps += 1
		while dc._snapping and steps < 100000:
			t = Time.get_ticks_usec()
			dc.flush_async()
			most_us = maxi(most_us, Time.get_ticks_usec() - t)
			steps += 1
		var st = dc._write_state
		dc.wait_writes()
		var files: Array = []
		var decoded: Array = []
		for r in [Vector2i(0, 0), Vector2i(1, 0)]:
			var abs_path := ProjectSettings.globalize_path(dc._region_path(r.x, r.y))
			files.append(FileAccess.get_file_as_bytes(abs_path))
			decoded.append(str(ChunkDiskCache._read_region_file(abs_path, r.x, r.y, ph)))
		results.append([files, decoded, steps, most_us, st != null and st.snapshots.is_empty() and int(st.written) == 2])
		dc.clear_disk()
	print("disk flush fine: 300 chunks x 500 extras, %d steps (longest %.2f ms) vs =off %d steps (longest %.2f ms)" % [
		results[0][2], results[0][3] / 1000.0, results[1][2], results[1][3] / 1000.0])
	var bytes_ok: bool = (results[0][0] as Array).size() == 2 and not ((results[0][0] as Array)[0] as PackedByteArray).is_empty()
	check(bytes_ok and results[0][0] == results[1][0] and results[0][1] == results[1][1],
		"disk flush fine: byte-equal region files and equal decode vs --disk-flush-fine=off")
	check(bool(results[0][4]), "disk flush fine: the write task let its snapshots go itself (2 regions written)")
	# A step with no time left: at most one chunk begun and one batch of extras copied.
	ChunkDiskCache.flush_fine = true
	var dz := _fine_cache("user://test-zchk-fine-step", ph, 30, 200)
	dz._snapping = true
	dz._snap_regions = dz._dirty.keys()
	dz._snap_ri = 0
	dz._snap_cur = []
	dz._snap_out = []
	var bounded := true
	var n_steps := 0
	while n_steps < 10000:
		var done := dz._snap_step(0)
		n_steps += 1
		if int(dz.snap_last[0]) > 1 or int(dz.snap_last[1]) > ChunkDiskCache.FLUSH_XE_BATCH:
			bounded = false
		if done:
			break
	var copied := 0
	var deep_ok := true
	for snap: Array in dz._snap_out:
		for d: Dictionary in snap[3]:
			copied += 1
			var src: Dictionary = dz._regions[ChunkDiskCache.region_of(int(d["cx"]), int(d["cy"]))][Vector2i(int(d["cx"]), int(d["cy"]))]
			if d["xe"] != src["xe"] or is_same(d["xe"], src["xe"]) or is_same((d["xe"] as Array)[0], (src["xe"] as Array)[0]):
				deep_ok = false
	check(bounded and copied == 30 and deep_ok and n_steps >= 30 * ceili(200.0 / ChunkDiskCache.FLUSH_XE_BATCH),
		"disk flush fine: no step past its slice plus one batch (%d steps), every chunk's extras deep-copied" % n_steps)
	dz._snap_reset()
	dz.clear_disk()
	ChunkDiskCache.flush_fine = fine_was
	ChunkDiskCache.async_encode = async_was
	ChunkDiskCache.flush_sliced = sliced_was


func _test_chunk_disk_cache() -> void:
	var cache_dir := "user://test-zchk-cache"
	var p := ProtoDB.new()
	p.add_tiles([[0, "grass-1", 80, 120, 60]])
	p.add_entities([[1, "wooden-chest", 1.0, 1.0, 0, "container"]])
	var ph := ChunkDiskCache.compute_proto_hash(p)
	var ph_alt := ph ^ 0x1234

	var tiles := PackedInt32Array()
	tiles.resize(1024)
	tiles.fill(0)
	var big_unit: int = 8589934597  # > 32-bit signed
	var ents := PackedInt64Array([big_unit, 1, 512, 512, 4, 99, 1, 768, 512, 0])
	var xi := PackedInt32Array([0])
	var xt := '[{"n":"Big Station"}]'

	var dc := ChunkDiskCache.new()
	dc.max_bytes = 256 * 1024
	dc.configure("save_alpha", 1, ph, cache_dir)
	dc.put_chunk(1, -2, 7, 2, tiles, ents, xi, xt)
	var written := dc.flush_sync()
	check(written == 1, "ChunkDiskCache flush_sync wrote Zstd region (%d)" % written)

	# Async WorkerThreadPool reload in fresh instance.
	var dc2 := ChunkDiskCache.new()
	dc2.configure("save_alpha", 1, ph, cache_dir)
	dc2.request_chunk(1, -2)
	var loaded_regions: Array[Vector2i] = []
	for _i in 60:
		loaded_regions = dc2.poll(0.1)
		if not loaded_regions.is_empty():
			break
		OS.delay_msec(10)
	var got := dc2.get_loaded_chunk(1, -2)
	check(not got.is_empty() and int(got["rv"]) == 7 and int(got["n"]) == 2
		and (got["tiles"] as PackedInt32Array).size() == 1024
		and int(got["e"][0]) == big_unit and got["xe"] == [{"n": "Big Station"}],
		"ChunkDiskCache async load restores 64-bit units, tiles, and parsed extras cleanly")

	# Wrong proto_hash rejects stale cache safely.
	var dc_bad := ChunkDiskCache.new()
	dc_bad.configure("save_alpha", 1, ph_alt, cache_dir)
	check(dc_bad.get_chunk_sync(1, -2).is_empty(), "ChunkDiskCache rejects mismatched proto_hash")

	# LRU disk eviction enforces size cap across multiple region files.
	var dc_lru := ChunkDiskCache.new()
	dc_lru.configure("save_alpha", 1, ph, cache_dir)
	for r_i in 6:
		var t_big := PackedInt32Array()
		t_big.resize(1024)
		for ti in 1024:
			t_big[ti] = (ti * 73 + r_i * 17) & 0xFFFF
		dc_lru.put_chunk(r_i * 16, 0, r_i + 1, 1, t_big, PackedInt32Array([r_i + 1, 1, 256, 256, 0]), PackedInt32Array(), "")
		dc_lru.flush_sync()
	var abs_base := ProjectSettings.globalize_path(cache_dir)
	var entries_before: Array = []
	ChunkDiskCache._collect_zchk_files(abs_base, entries_before)
	var freed := ChunkDiskCache.prune_disk_dir(abs_base, 128)
	var entries_after: Array = []
	ChunkDiskCache._collect_zchk_files(abs_base, entries_after)
	check(entries_before.size() >= 6 and freed > 0 and entries_after.size() <= 1,
		"ChunkDiskCache prune_disk_dir evicts oldest regions under cap (%d -> %d files, freed %d B)" % [entries_before.size(), entries_after.size(), freed])

	# Clean up cache_dir via clear_disk().
	dc_lru.clear_disk()
	check(not DirAccess.dir_exists_absolute(abs_base), "clear_disk removes cache directory cleanly")

	# ProtoDB.version bumps on mutations and World._ensure_disk_cache() skips hashing when unchanged.
	var p_ver_start := p.version
	p.add_tiles([[1, "dirt-1", 100, 90, 70]])
	var p_ver_tile := p.version
	p.add_entities([[2, "iron-chest", "container", -0.5, -0.5, 0.5, 0.5, 160, 160, 160, 1, 1]])
	var p_ver_ent := p.version
	p.clear()
	check(p_ver_tile == p_ver_start + 1 and p_ver_ent == p_ver_tile + 1 and p.version == p_ver_ent + 1,
		"ProtoDB.version increments on tile, entity, and clear updates")
	var w := _make_world(1)
	w.protos.add_entities([[2, "iron-chest", "container", -0.5, -0.5, 0.5, 0.5, 160, 160, 160, 1, 1]])
	var sid_was := Bridge.save_id
	Bridge.save_id = "test_proto_cache_ver"
	w.disk_cache_enabled = true
	w._ensure_disk_cache()
	var h1 := w._disk_cache_hash
	var v1 := w._disk_cache_proto_ver
	w._ensure_disk_cache()
	var same_hash := w._disk_cache_hash == h1 and w._disk_cache_proto_ver == v1 and h1 != 0
	w.protos.add_entities([[3, "steel-chest", "container", -0.5, -0.5, 0.5, 0.5, 120, 140, 160, 1, 1]])
	w._ensure_disk_cache()
	var updated_hash := w._disk_cache_hash != h1 and w._disk_cache_proto_ver == w.protos.version
	check(same_hash and updated_hash,
		"World._ensure_disk_cache caches hash across idle calls and recomputes when ProtoDB updates")
	w._disk_cache.wait_all()
	w._disk_cache.clear_disk()
	Bridge.save_id = sid_was
	w.queue_free()


func _test_adaptive_window_and_lookahead() -> void:
	var leg_was := WorldMirror.stream_window_legacy
	var over_was := WorldMirror.stream_window_override
	var look_was := WorldMirror.stream_lookahead
	WorldMirror.stream_window_legacy = false
	WorldMirror.stream_window_override = -1
	WorldMirror.stream_lookahead = true

	var w := _make_world(1)
	w.view_radius = 12
	check(w._stream_allowance(false, 12) == 48 and w._stream_allowance(true, 12) == 36,
		"adaptive window scales with view_radius (%d still, %d moving)" % [w._stream_allowance(false, 12), w._stream_allowance(true, 12)])

	# High build backlog halves moving allowance safely.
	for i in 18:
		w._dirty[Vector2i(i, 0)] = true
	check(w._stream_allowance(true, 12) == 18, "high build backlog throttles moving window to 18")
	w._dirty.clear()

	# Sliding _all_came() refills once < 75% of moving allowance remain undrawn.
	w._wanted_radius = 12
	w._moved_msec = Time.get_ticks_msec()
	w._stream_timer = WorldMirror.STREAM_STEP_QUICK + 0.01
	w._wanted_lazy = true
	w._wanted_count = 625
	for i in 10:
		var c := Vector2i(i, 0)
		w._coming[c] = true
	check(w._all_came(), "moving sliding window triggers early refill at STREAM_STEP_QUICK when <= 75% waiting")
	for i in range(10, 30):
		w._coming[Vector2i(i, 0)] = true
	check(not w._all_came(), "moving sliding window pauses refill when > 75% of allowance wait")

	# Flight velocity lookahead shifts priority toward travel direction while keeping player's immediate circle first.
	w.queue_free()

	var w2 := _make_world(1)
	w2.view_radius = 10
	w2._focus = Vector2.ZERO
	w2._view_sector(0.1)
	w2._focus = Vector2(3.0, 0.0)  # 30 tiles/s east (< 120 jump threshold)
	w2._view_sector(0.1)
	w2._focus = Vector2(6.0, 0.0)
	var sec := w2._view_sector(0.1)
	var lead := w2._lookahead_lead(10)
	check(w2._focus_vel.x > 1.0 and lead.x >= 1 and lead.y == 0 and sec == 0,
		"fast flight east updates _focus_vel (%s), sector (%d), and forward lead (%s)" % [w2._focus_vel, sec, lead])
	var ord := WorldMirror.prio_order_lead(10, sec, lead)
	var idx_ahead := ord.find(Vector2i(5, 0))
	var idx_behind := ord.find(Vector2i(-5, 0))
	check(ord.size() == 21 * 21 and ord[0] == Vector2i.ZERO and idx_ahead < idx_behind,
		"prio_order_lead keeps focus chunk first and prioritizes ahead (%d) over behind (%d)" % [idx_ahead, idx_behind])

	w2.queue_free()
	WorldMirror.stream_window_legacy = leg_was
	WorldMirror.stream_window_override = over_was
	WorldMirror.stream_lookahead = look_was


func _test_far_chunks_freed_queue_safety() -> void:
	var asked_was: Array = FarChunks._asked.duplicate()
	FarChunks._asked.clear()
	var no_dead_was := FrameBudget.test_no_deadline
	FrameBudget.test_no_deadline = true
	FrameBudget.reset()

	var w := _make_world(1)
	var fc := FarChunks.new()
	fc.world = w
	fc.set_process(false)
	w.add_child(fc)

	# Freed ChunkViews left in _collecting and _waiting must be pruned before sorting or promoting.
	var stale_col := ChunkView.new()
	stale_col.coord = Vector2i(20, 0)
	fc._collecting.append([stale_col, 1])
	stale_col.free()

	var stale_wait := ChunkView.new()
	stale_wait.coord = Vector2i(21, 0)
	fc._waiting.append([stale_wait, 1])
	stale_wait.free()

	var live_fresh := ChunkView.new()
	live_fresh.coord = Vector2i(10, 0)
	w.chunks[live_fresh.coord] = live_fresh
	w.add_child(live_fresh)
	live_fresh.far.far = true
	live_fresh.far.covers = false
	live_fresh.far.full = false
	live_fresh.far.phase = FarChunks.ASKED
	live_fresh.far.serial = 2
	FarChunks._asked.append(live_fresh)

	var live_wait := ChunkView.new()
	live_wait.coord = Vector2i(12, 0)
	w.chunks[live_wait.coord] = live_wait
	w.add_child(live_wait)
	live_wait.far.far = true
	live_wait.far.covers = false
	live_wait.far.full = false
	live_wait.far.phase = FarChunks.WAITING
	live_wait.far.serial = 2
	fc._waiting.append([live_wait, 2])

	fc._collect()
	var collected_ok: bool = fc._collecting.is_empty() and live_fresh.far.phase == FarChunks.WAITING
	fc._start_merges()
	var merges_ok: bool = fc._waiting.is_empty() and live_fresh.far.phase == FarChunks.MERGING and live_wait.far.phase == FarChunks.MERGING

	for m_entry: Array in fc._merging:
		WorkerThreadPool.wait_for_task_completion(int(m_entry[0]))
	fc._merging.clear()

	check(collected_ok and merges_ok,
		"FarChunks prunes freed ChunkViews in _collecting and _waiting safely (%s, %s)" % [collected_ok, merges_ok])

	w.queue_free()
	await get_tree().process_frame
	FrameBudget.test_no_deadline = no_dead_was
	FrameBudget.reset()
	FarChunks._asked = asked_was


## A MultiMesh freed by the chunk (`_drop`) while far_chunks.gd holds it in `far.hidden` must leave that list, or the
## decide pass's loop over it hits a freed instance ("Trying to assign invalid previously freed instance").
func _test_far_hidden_dropped_mmi() -> void:
	var cv := ChunkView.new()
	var gone := MultiMeshInstance3D.new()
	var kept := MultiMeshInstance3D.new()
	cv.add_child(gone)
	cv.add_child(kept)
	cv._nodes["gone"] = gone
	cv._nodes["kept"] = kept
	gone.visible = false
	kept.visible = false
	cv.far.hidden = [gone, kept]
	cv._drop("gone")
	check(cv.far.hidden.size() == 1 and cv.far.hidden[0] == kept and FarChunks.hides(cv, kept),
		"a dropped MultiMesh leaves far.hidden (%d left)" % cv.far.hidden.size())
	# Freed from elsewhere (not through _drop): the near-again loop still shows the others, with no error.
	var other := MultiMeshInstance3D.new()
	cv.add_child(other)
	other.visible = false
	cv.far.hidden.append(other)
	kept.free()
	var shown := 0
	for hm in cv.far.hidden:
		if is_instance_valid(hm):
			(hm as MultiMeshInstance3D).visible = true
			shown += 1
	check(shown == 1 and other.visible, "freed entry skipped, the other shown")
	cv.far.hidden = []
	cv.free()


func _test_lights_stagger_fog_and_culling() -> void:
	var w := _make_world(1)
	w.protos.add_entities([
		[4, "small-lamp", "lamp", -0.5, -0.5, 0.5, 0.5, 200, 200, 180, 1, 1],
		[6, "rail-signal", "rail-signal", -0.5, -0.5, 0.5, 0.5, 90, 160, 90, 1, 1],
	])
	for c in [Vector2i(0, 0), Vector2i(2, 0), Vector2i(6, 0)]:
		var cv := ChunkView.new()
		cv.coord = c
		w.chunks[c] = cv
		w.add_child(cv)
	w._add([3001, 4, 4 * 256 + 128, 4 * 256 + 128, 0, {"lp": 1}])
	w._add([3002, 4, 68 * 256 + 128, 4 * 256 + 128, 0, {"lp": 1}])
	w._add([3003, 4, 196 * 256 + 128, 4 * 256 + 128, 0, {"lp": 1}])
	w._add([3011, 6, 6 * 256 + 128, 4 * 256 + 128, 0, {"sg": 1}])
	w._add([3012, 6, 70 * 256 + 128, 4 * 256 + 128, 0, {"sg": 2}])

	var lamps := LampLights.new()
	lamps.protos = w.protos
	lamps.world = w
	lamps.set_process(false)
	add_child(lamps)
	var sigs := SignalLights.new()
	sigs.protos = w.protos
	sigs.world = w
	sigs.set_process(false)
	add_child(sigs)
	lamps.signal_lights = sigs

	for c in [Vector2i(0, 0), Vector2i(2, 0), Vector2i(6, 0)]:
		lamps._on_entities_changed(c)
	for c in [Vector2i(0, 0), Vector2i(2, 0)]:
		sigs._on_entities_changed(c)

	var init_stagger := is_equal_approx(SignalLights.REFRESH, 0.5) and is_equal_approx(sigs._timer, 0.25) and is_equal_approx(lamps._timer, 0.0)
	lamps.darkness = 0.85
	sigs.darkness = 0.85

	# Staggered 0.25s steps: SignalLights fires at 0.25s while LampLights waits; LampLights fires at 0.50s while SignalLights waits.
	lamps._process(0.25)
	sigs._process(0.25)
	var step1_ok := lamps.lit_count() == 0 and sigs.lit_count() == 2
	lamps._process(0.25)
	sigs._process(0.25)
	var step2_ok := lamps.lit_count() == 3 and sigs.lit_count() == 2 and is_equal_approx(lamps._timer, 0.0) and is_equal_approx(sigs._timer, 0.25)
	lamps.apply_lod_quality("medium")
	sigs.apply_lod_quality("medium")
	var lod_stagger := is_equal_approx(lamps._timer, LampLights.REFRESH) and is_equal_approx(sigs._timer, 0.25)

	var sig_mm: MultiMesh = sigs._glows.multimesh
	var sig_mm_ok := sig_mm.visible_instance_count == 2 and sig_mm.custom_aabb.has_volume()

	# Day skips far lightmap work completely.
	lamps.darkness = 0.0
	lamps._process(LampLights.REFRESH)
	var day_skip_ok := lamps.lit_count() == 0 and not lamps._map_active

	# Night with far_lights enabled builds far lightmap; disabling far_lights keeps near chunks only and skips lightmap.
	lamps.darkness = 0.85
	lamps._process(LampLights.REFRESH)
	var far_on_ok := lamps.lit_count() == 3 and lamps._map_active
	lamps.set_far_lights_enabled(false)
	lamps._process(LampLights.REFRESH)
	var near_only_ok := lamps.lit_count() == 2 and not lamps._map_active
	lamps.set_far_lights_enabled(true)
	lamps._process(LampLights.REFRESH)

	# Hoisted fog check skips hidden chunks cleanly at chunk level.
	var fog := RemoteFog.new()
	add_child(fog)
	fog.handle({"t": "cov", "si": 1, "l": [0, 0, 1]})
	fog.update(true, Vector2.ZERO)
	lamps.fog = fog
	sigs.fog = fog
	lamps._process(LampLights.REFRESH)
	sigs._process(SignalLights.REFRESH)
	var fog_hide_ok := fog.hiding() and lamps.lit_count() == 1 and sigs.lit_count() == 1
	fog.update(false, Vector2.ZERO)
	lamps._process(LampLights.REFRESH)
	sigs._process(SignalLights.REFRESH)
	var fog_clear_ok := not fog.hiding() and lamps.lit_count() == 3 and sigs.lit_count() == 2

	check(init_stagger and step1_ok and step2_ok and lod_stagger and sig_mm_ok \
		and day_skip_ok and far_on_ok and near_only_ok and fog_hide_ok and fog_clear_ok,
		"lights stagger/fog/culling (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)"
		% [init_stagger, step1_ok, step2_ok, lod_stagger, sig_mm_ok, day_skip_ok, far_on_ok, near_only_ok, fog_hide_ok, fog_clear_ok])

	lamps._exit_tree()
	fog.queue_free()
	lamps.queue_free()
	sigs.queue_free()
	w.queue_free()
	await get_tree().process_frame


func _test_dh_handoff() -> void:
	var atomic_was := WorldMirror.atomic_reveal
	var handoff_was := WorldMirror.dh_handoff
	var db_was := WorldMirror.double_buffer_refresh
	WorldMirror.atomic_reveal = true
	WorldMirror.dh_handoff = true

	var w := _make_world(1)
	var ready_chunks: Array[Vector2i] = []
	var drawn_chunks: Array[Vector2i] = []
	w.chunk_ready.connect(func(c: Vector2i) -> void: ready_chunks.append(c))
	w.chunk_drawn.connect(func(c: Vector2i) -> void: drawn_chunks.append(c))

	# 1. dh_covers_chunk extends reveal hold past REVEAL_HOLD_MSEC and reveals once waiting_models clears.
	var c0 := Vector2i(0, 0)
	var cv0 := ChunkView.new()
	cv0.coord = c0
	w.chunks[c0] = cv0
	w.add_child(cv0)
	var covers_cb := func(c: Vector2i) -> bool:
		return c == c0
	w.dh_covers_chunk = covers_cb
	w.handle({"t": "chunk", "cx": 0, "cy": 0, "rs": 1, "rv": 1, "n": 1, "parts": 1, "tiles": [0, 1024]})
	w.handle({"t": "ents", "cx": 0, "cy": 0, "part": 1, "parts": 1, "e": [[10, 1, 256, 256, 0]]})
	w._dirty.erase(c0)
	cv0.waiting_models = true
	cv0.apply_kept_terrain(ArrayMesh.new(), PackedInt32Array(), false)
	w._on_terrain_applied(c0, cv0)
	cv0.tiles_msec = Time.get_ticks_msec() - WorldMirror.REVEAL_HOLD_MSEC - 50
	w._rebuild_dirty()
	var held_past_600 := not cv0.revealed and cv0._terrain_held and ready_chunks.is_empty()
	cv0.waiting_models = false
	w._built(c0, cv0, Time.get_ticks_usec())
	check(held_past_600 and cv0.revealed and not cv0._terrain_held and drawn_chunks.has(c0),
		"dh_covers_chunk extends reveal hold past 600ms while waiting_models and reveals once ready (%s, %s)" % [held_past_600, cv0.revealed])

	# 2. Unchanged-tile resend while unrevealed must NOT reveal bare ground immediately after clear_entities.
	WorldMirror.double_buffer_refresh = false
	var c1 := Vector2i(1, 0)
	var cv1 := ChunkView.new()
	cv1.coord = c1
	w.chunks[c1] = cv1
	w.add_child(cv1)
	w.handle({"t": "chunk", "cx": 1, "cy": 0, "rs": 1, "rv": 1, "n": 1, "parts": 1, "tiles": [0, 1024]})
	w.handle({"t": "ents", "cx": 1, "cy": 0, "part": 1, "parts": 1, "e": [[11, 1, 32 * 256 + 128, 128, 0]]})
	cv1.apply_kept_terrain(ArrayMesh.new(), PackedInt32Array(), false)
	w._on_terrain_applied(c1, cv1)
	check(not cv1.revealed and cv1._terrain_held, "unbuilt chunk starts held before resend")
	w.handle({"t": "chunk", "cx": 1, "cy": 0, "rs": 1, "rv": 2, "n": 1, "parts": 1, "tiles": [0, 1024]})
	check(not cv1.revealed and cv1._terrain_held and w._held_reveal.has(c1),
		"unchanged-tile resend while unrevealed keeps terrain held instead of revealing empty ground")
	WorldMirror.double_buffer_refresh = db_was

	# 3. _unload holds visible revealed chunk in _dh_unloading until dh_handoff_ready turns true.
	var dh_ready := [false]
	var ready_handoff_cb := func(_c: Vector2i) -> bool:
		return bool(dh_ready[0])
	w.dh_handoff_ready = ready_handoff_cb
	var c2 := Vector2i(2, 0)
	var cv2 := ChunkView.new()
	cv2.coord = c2
	w.chunks[c2] = cv2
	w.add_child(cv2)
	w.handle({"t": "chunk", "cx": 2, "cy": 0, "rs": 1, "rv": 1, "n": 0, "parts": 1, "tiles": [0, 1024]})
	w.handle({"t": "ents", "cx": 2, "cy": 0, "part": 1, "parts": 1, "e": []})
	w._dirty.erase(c2)
	cv2.apply_kept_terrain(ArrayMesh.new(), PackedInt32Array(), false)
	w._on_terrain_applied(c2, cv2)
	w._unload(c2)
	var held_on_unload := cv2.visible and w._dh_unloading.has(cv2) and w.unloaded_drawn() >= 1
	w._free_unloaded()
	var still_held := is_instance_valid(cv2) and cv2.visible and w._dh_unloading.has(cv2)
	dh_ready[0] = true
	w._free_unloaded()
	var freed_after_ready := w._dh_unloading.is_empty() and not is_instance_valid(cv2)
	check(held_on_unload and still_held and freed_after_ready,
		"unload holds visible revealed chunk until dh_handoff_ready then hides/frees cleanly (%s, %s, %s)" % [
			held_on_unload, still_held, freed_after_ready])

	# 4. Timeout fallback & replacement reveal release _dh_unloading cleanly.
	dh_ready[0] = false
	var c3 := Vector2i(3, 0)
	var cv3 := ChunkView.new()
	cv3.coord = c3
	w.chunks[c3] = cv3
	w.add_child(cv3)
	w.handle({"t": "chunk", "cx": 3, "cy": 0, "rs": 1, "rv": 1, "n": 0, "parts": 1, "tiles": [0, 1024]})
	w.handle({"t": "ents", "cx": 3, "cy": 0, "part": 1, "parts": 1, "e": []})
	w._dirty.erase(c3)
	cv3.apply_kept_terrain(ArrayMesh.new(), PackedInt32Array(), false)
	w._on_terrain_applied(c3, cv3)
	w._unload(c3)
	(w._dh_unloading[cv3] as Array)[1] = Time.get_ticks_msec() - WorldMirror.DH_UNLOAD_HOLD_MSEC - 50
	w._free_unloaded()
	var timeout_freed := w._dh_unloading.is_empty() and not is_instance_valid(cv3)

	var c4 := Vector2i(4, 0)
	var cv4 := ChunkView.new()
	cv4.coord = c4
	w.chunks[c4] = cv4
	w.add_child(cv4)
	w.handle({"t": "chunk", "cx": 4, "cy": 0, "rs": 1, "rv": 1, "n": 0, "parts": 1, "tiles": [0, 1024]})
	w.handle({"t": "ents", "cx": 4, "cy": 0, "part": 1, "parts": 1, "e": []})
	w._dirty.erase(c4)
	cv4.apply_kept_terrain(ArrayMesh.new(), PackedInt32Array(), false)
	w._on_terrain_applied(c4, cv4)
	w._unload(c4)
	var cv4_rep := ChunkView.new()
	cv4_rep.coord = c4
	w.chunks[c4] = cv4_rep
	w.add_child(cv4_rep)
	cv4_rep.apply_kept_terrain(ArrayMesh.new(), PackedInt32Array(), false)
	w._reveal_chunk(c4, cv4_rep)
	var rep_hidden := not is_instance_valid(cv4) or not cv4.visible
	var rep_released := not w._dh_unloading.has(cv4)
	check(timeout_freed and rep_hidden and rep_released,
		"DH_UNLOAD_HOLD_MSEC timeout and replacement reveal release held chunks (%s, %s, %s)" % [
			timeout_freed, rep_hidden, rep_released])

	# 5. dh_handoff=false bypasses holding; reset() clears remaining held chunks.
	WorldMirror.dh_handoff = false
	var c5 := Vector2i(5, 0)
	var cv5 := ChunkView.new()
	cv5.coord = c5
	w.chunks[c5] = cv5
	w.add_child(cv5)
	w.handle({"t": "chunk", "cx": 5, "cy": 0, "rs": 1, "rv": 1, "n": 0, "parts": 1, "tiles": [0, 1024]})
	w.handle({"t": "ents", "cx": 5, "cy": 0, "part": 1, "parts": 1, "e": []})
	w._dirty.erase(c5)
	cv5.apply_kept_terrain(ArrayMesh.new(), PackedInt32Array(), false)
	w._on_terrain_applied(c5, cv5)
	w._unload(c5)
	var off_bypass := not w._dh_unloading.has(cv5)
	w._free_unloaded()

	WorldMirror.dh_handoff = true
	var c6 := Vector2i(6, 0)
	var cv6 := ChunkView.new()
	cv6.coord = c6
	w.chunks[c6] = cv6
	w.add_child(cv6)
	w.handle({"t": "chunk", "cx": 6, "cy": 0, "rs": 1, "rv": 1, "n": 0, "parts": 1, "tiles": [0, 1024]})
	w.handle({"t": "ents", "cx": 6, "cy": 0, "part": 1, "parts": 1, "e": []})
	w._dirty.erase(c6)
	cv6.apply_kept_terrain(ArrayMesh.new(), PackedInt32Array(), false)
	w._on_terrain_applied(c6, cv6)
	w._unload(c6)
	w.reset(true)
	var reset_cleared := w._dh_unloading.is_empty() and w._dh_unloading_by_coord.is_empty() and (not is_instance_valid(cv6) or not cv6.visible)
	check(off_bypass and reset_cleared,
		"dh_handoff=false skips holding and reset() cleans _dh_unloading (%s, %s)" % [off_bypass, reset_cleared])

	# 6. FarChunks.note_added immediately marks distant spawned chunk as far=true.
	var fc := FarChunks.new()
	fc.world = w
	fc.enabled = true
	fc._decide_prev_valid = true
	fc._pass_at = Vector3.ZERO
	fc._pass_focus = Vector2.ZERO
	fc._pass_from = 128.0
	fc._pass_coarse_from = 350.0
	fc._pass_ortho = false
	var cv_far := ChunkView.new()
	cv_far.coord = Vector2i(10, 0)
	w.chunks[Vector2i(10, 0)] = cv_far
	w.add_child(cv_far)
	fc.note_added(Vector2i(10, 0))
	check(cv_far.far.far, "FarChunks.note_added immediately classifies newly spawned distant chunk as far=true")

	fc.free()
	w.queue_free()
	WorldMirror.atomic_reveal = atomic_was
	WorldMirror.dh_handoff = handoff_was
	WorldMirror.double_buffer_refresh = db_was
	await get_tree().process_frame


func _test_moving_stutter_fixes() -> void:
	# 1. Async ChunkDiskCache encode/JSON stringify round-trip + --chunk-disk-cache-async=off fallback.
	var async_cache_was := ChunkDiskCache.async_encode
	var dc_dir := "user://test-zchk-async-encode"
	var p := ProtoDB.new()
	p.add_tiles([[0, "grass-1", 80, 120, 60]])
	p.add_entities([[1, "assembling-machine-1", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 80, 140, 180, 3, 3]])
	var ph := ChunkDiskCache.compute_proto_hash(p)
	var tiles := PackedInt32Array()
	tiles.resize(1024)
	tiles.fill(0)

	ChunkDiskCache.async_encode = true
	var dc_a := ChunkDiskCache.new()
	dc_a.configure("save_async", 1, ph, dc_dir)
	dc_a.put_chunk(2, 1, 9, 1, tiles, PackedInt32Array([501, 1, 512, 512, 0]), PackedInt32Array([0]), "", [{"f": 1, "rcp": "iron-gear-wheel"}])
	dc_a.flush_async()
	dc_a.wait_all()
	var dc_a_read := ChunkDiskCache.new()
	dc_a_read.configure("save_async", 1, ph, dc_dir)
	var got_a := dc_a_read.get_chunk_sync(2, 1)
	var xe_a: Array = got_a.get("xe", [])
	check(not got_a.is_empty() and xe_a.size() == 1 and int(xe_a[0].get("f", 0)) == 1
		and str(xe_a[0].get("rcp", "")) == "iron-gear-wheel",
		"ChunkDiskCache async worker encodes xe + Zstd region round-trip cleanly (%s)" % [xe_a])

	ChunkDiskCache.async_encode = false
	dc_a.put_chunk(3, 1, 10, 1, tiles, PackedInt32Array([502, 1, 768, 512, 0]), PackedInt32Array([0]), '[{"n":"Sync"}]')
	dc_a.flush_async()
	dc_a.wait_all()
	var dc_b_read := ChunkDiskCache.new()
	dc_b_read.configure("save_async", 1, ph, dc_dir)
	var got_b := dc_b_read.get_chunk_sync(3, 1)
	check(not got_b.is_empty() and got_b.get("xe", []) == [{"n": "Sync"}],
		"ChunkDiskCache async_encode=false fallback still encodes and restores cleanly (%s)" % [got_b.get("xe", [])])
	dc_a.clear_disk()
	var pack_entry := {"msgs": [{}, {"e": PackedInt32Array([1, 1, 0, 0, 0]), "xi": PackedInt32Array([0]), "xe": [{"n": "M"}]}]}
	var packed_raw := WorldMirror._pack_cache_entry(pack_entry, false)
	var packed_str := WorldMirror._pack_cache_entry(pack_entry, true)
	check(packed_raw[2] is Array and packed_str[2] is String and str(packed_str[2]).contains('"M"'),
		"WorldMirror._pack_cache_entry defers JSON.stringify when stringify_xe=false (%s, %s)" % [typeof(packed_raw[2]), packed_str[2]])
	ChunkDiskCache.async_encode = async_cache_was

	# 2. ChunkView ChunkPrepJob packs st.buffer for static LOD-enabled wants (keeping use_buf=false)
	#    and --lod-fade-moving snaps above 12 tiles/s.
	var fade_moving_was := ChunkView.lod_fade_moving
	var base_mesh := ArrayMesh.new()
	var st_arr := []
	st_arr.resize(Mesh.ARRAY_MAX)
	st_arr[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)])
	st_arr[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	base_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st_arr)
	var lod1_mesh := ArrayMesh.new()
	lod1_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st_arr)
	ModelLods._levels[base_mesh] = [[lod1_mesh, 0.2, 0.2]]

	var cv_lod := ChunkView.new()
	cv_lod.coord = Vector2i.ZERO
	add_child(cv_lod)
	var xfs: Array = [Transform3D.IDENTITY, Transform3D(Basis.IDENTITY, Vector3(2, 0, 0))]
	var w_lod := cv_lod._want(base_mesh, base_mesh, xfs, [], null, false, [], null, false)
	var has_lods_want := cv_lod._want_has_lods(w_lod)
	w_lod.use_buf = not w_lod.group and w_lod.switches.is_empty() and not has_lods_want
	w_lod.pack_lod_buf = not w_lod.group and w_lod.switches.is_empty() and has_lods_want
	w_lod.stride = 12
	w_lod.mesh_box = ChunkView._mesh_box(w_lod.mesh)
	var prep := ChunkView.ChunkPrepJob.new()
	prep.coord = Vector2i.ZERO
	prep.serial = cv_lod.build_serial
	prep.wants = [w_lod]
	prep.wanted = {base_mesh: true}
	prep.run()
	cv_lod.apply_prepared(prep, {})
	var mmi_lod: MultiMeshInstance3D = cv_lod._nodes.get(base_mesh)
	var lst: ChunkView.LodState = cv_lod._lods.get(mmi_lod)
	var probing_was := Probing.on
	Probing.on = true
	ChunkView.counters.clear()
	cv_lod.update_lods(Vector3(16, ChunkView.LOD_HEIGHT + 1.0, 16), 1.0, -1.0, 0.0)
	var cpu_copies := int(ChunkView.counters.get("lod_cpu_copies", 0))
	var buf_readbacks := int(ChunkView.counters.get("lod_buffer_readbacks", 0))
	Probing.on = probing_was
	check(has_lods_want and not w_lod.use_buf and w_lod.pack_lod_buf
		and lst != null and not lst.buffer.is_empty() and lst.buffer == w_lod.buf
		and mmi_lod.multimesh.mesh == lod1_mesh and lst.fade != null
		and cpu_copies == 1 and buf_readbacks == 0,
		"ChunkView populates st.buffer for static LOD-enabled wants without setting use_buf (%s, %s, buf=%d, copy=%d, rb=%d)"
		% [not w_lod.use_buf, w_lod.pack_lod_buf, lst.buffer.size() if lst != null else 0, cpu_copies, buf_readbacks])

	ChunkView.lod_fade_moving = true
	var snap_fast_on := ChunkView.should_snap_for_speed(15.0) and not ChunkView.should_snap_for_speed(5.0)
	var w_snap := _make_world(1)
	w_snap.lod_by_camera = true
	var snap_cam := Camera3D.new()
	snap_cam.position = Vector3(16.0, ChunkView.LOD_HEIGHT + 1.0, 16.0)
	add_child(snap_cam)
	snap_cam.look_at(Vector3(16.0, 0.0, 0.0), Vector3.UP)
	snap_cam.current = true
	cv_lod.reparent(w_snap)
	w_snap.chunks[Vector2i.ZERO] = cv_lod
	cv_lod.update_lods(Vector3(16, ChunkView.LOD_HEIGHT + 0.05, 16), 1.0, -1.0, 1.0)
	w_snap._focus_vel = Vector2(18.0, 0.0)
	w_snap._lod_prev_at = Vector3(16.0, ChunkView.LOD_HEIGHT + 1.0, 16.0)
	w_snap._update_lods(0.016)
	var snap_world_fast := w_snap._lod_fast_moving
	ChunkView.lod_fade_moving = false
	var snap_fast_off := not ChunkView.should_snap_for_speed(18.0)
	w_snap._update_lods(0.016)
	var snap_world_off := not w_snap._lod_fast_moving
	check(snap_fast_on and snap_world_fast and snap_fast_off and snap_world_off,
		"ChunkView --lod-fade-moving snaps above 12 tiles/s and respects =off fallback (%s, %s, %s, %s)"
		% [snap_fast_on, snap_world_fast, snap_fast_off, snap_world_off])
	ModelLods._levels.erase(base_mesh)
	ChunkView.lod_fade_moving = fade_moving_was
	snap_cam.queue_free()
	w_snap.queue_free()

	# 3. FrameBudget hard combined ceiling + --budget-hard-cap=off fallback.
	var fb_shared_was := FrameBudget.shared
	var fb_hard_was := FrameBudget.hard_cap
	var fb_nd_was := FrameBudget.test_no_deadline
	var fb_ou_was := FrameBudget.test_other_usec
	var fb_rf_was := FrameBudget.reduce_floors
	FrameBudget.reduce_floors = false  # (the hard cap as before; _test_unload_fast has the reducers' floors)
	FrameBudget.reset()
	FrameBudget.shared = true
	FrameBudget.test_no_deadline = true
	FrameBudget.test_other_usec = 0
	FrameBudget.hard_cap = true
	FrameBudget.grant(&"messages")
	FrameBudget.spent(&"build", FrameBudget.pool, 10)
	FrameBudget.queued[&"lods"] = 10
	FrameBudget.queued[&"unload"] = 10
	FrameBudget.queued[&"shadows"] = 10
	FrameBudget.queued[&"pipelines"] = 10
	FrameBudget.queued[&"wires"] = 10
	FrameBudget.queued[&"far_collect"] = 10
	FrameBudget.queued[&"belt_lods"] = 70
	var cap_unload := FrameBudget.grant(&"unload")
	var cap_lods := FrameBudget.grant(&"lods")
	var cap_shadows := FrameBudget.grant(&"shadows")
	var cap_pipelines := FrameBudget.grant(&"pipelines")
	var cap_wires := FrameBudget.grant(&"wires")
	var cap_fc := FrameBudget.grant(&"far_collect")
	var cap_bl := FrameBudget.grant(&"belt_lods")
	var cap_build := FrameBudget.grant(&"build")
	FrameBudget.hard_cap = false
	var off_lods := FrameBudget.grant(&"lods")
	var off_shadows := FrameBudget.grant(&"shadows")
	check(cap_unload >= int(FrameBudget.SYSTEMS[&"unload"][2])
		and cap_pipelines >= int(FrameBudget.SYSTEMS[&"pipelines"][2])
		and cap_lods == 0 and cap_shadows == 0 and cap_wires == 0 and cap_fc == 0 and cap_bl == 0
		and cap_build >= int(FrameBudget.SYSTEMS[&"build"][2])
		and off_shadows == int(FrameBudget.SYSTEMS[&"shadows"][2])
		and off_lods == int(FrameBudget.SYSTEMS[&"lods"][2]),
		"FrameBudget hard ceiling keeps unload/pipelines floors while capping prio>=5 when pool spent (%d/%d, %d/%d/%d/%d/%d, build=%d, off=%d/%d)"
		% [cap_unload, cap_pipelines, cap_lods, cap_shadows, cap_wires, cap_fc, cap_bl, cap_build, off_shadows, off_lods])
	FrameBudget.reset()
	FrameBudget.shared = fb_shared_was
	FrameBudget.hard_cap = fb_hard_was
	FrameBudget.test_no_deadline = fb_nd_was
	FrameBudget.test_other_usec = fb_ou_was
	FrameBudget.reduce_floors = fb_rf_was

	# 4. BeltLods 4-tile deadband & FrameBudget time slicing (--belt-lods-slice=off fallback).
	var bl_dead_was := BeltLods.move_deadband
	var bl_slice_was := BeltLods.slice_enabled
	BeltLods._chunks.clear()
	BeltLods._last_view = []
	BeltLods._pass_todo = []
	BeltLods._pass_next = 0
	var bl_host := Node3D.new()
	add_child(bl_host)
	var bl_cam := Camera3D.new()
	bl_cam.position = Vector3(10.0, 20.0, 10.0)
	bl_host.add_child(bl_cam)
	bl_cam.look_at(Vector3(10.0, 0.0, 0.0), Vector3.UP)
	bl_cam.current = true
	var bl_cvs: Array = []
	for i in 70:
		var bcv := ChunkView.new()
		bcv.coord = Vector2i(i % 10, i / 10)
		bcv.belt_bounds = AABB(Vector3(float(bcv.coord.x * 32), 0.0, float(bcv.coord.y * 32)), Vector3(32.0, 2.0, 32.0))
		bl_host.add_child(bcv)
		BeltLods._chunks[bcv] = true
		bl_cvs.append(bcv)
	BeltLods.move_deadband = true
	BeltLods.slice_enabled = true
	BeltLods._dirty = true
	var bl_rf_was := FrameBudget.reduce_floors
	FrameBudget.reduce_floors = false  # (deferred under the hard cap as before; _test_unload_fast has the floors)
	FrameBudget.reset()
	FrameBudget.shared = true
	FrameBudget.test_no_deadline = true
	FrameBudget.test_other_usec = 0
	BeltLods.update(null, bl_cam, 0.0)
	BeltLods._timer = 0.01
	bl_cam.global_position = Vector3(11.4, 20.0, 10.0)
	BeltLods.update(null, bl_cam, 0.01)
	var bl_skip_4 := BeltLods._timer > 0.015
	bl_cam.global_position = Vector3(15.0, 20.0, 10.0)
	BeltLods.update(null, bl_cam, 0.01)
	var bl_moved_4 := is_zero_approx(BeltLods._timer)
	FrameBudget.hard_cap = true
	FrameBudget.grant(&"messages")
	FrameBudget.spent(&"build", FrameBudget.pool, 0)
	BeltLods._dirty = true
	BeltLods.update(null, bl_cam, 0.016)
	var bl_deferred := BeltLods._pass_next == 0 and BeltLods._pass_todo.size() == 70
	BeltLods._pass_next = 20
	BeltLods._timer = BeltLods.CHECK_INTERVAL
	BeltLods.update(null, bl_cam, 0.30)
	var bl_resumed_keeps_cursor := BeltLods._pass_next == 20 and BeltLods._pass_todo.size() == 70
	FrameBudget.reset()
	FrameBudget.shared = true
	FrameBudget.test_no_deadline = true
	FrameBudget.test_other_usec = 0
	BeltLods.update(null, bl_cam, 0.016)
	var bl_resumed_done := BeltLods._pass_todo.is_empty()
	BeltLods.slice_enabled = false
	BeltLods._dirty = true
	BeltLods.update(null, bl_cam, 0.016)
	var bl_off_done := BeltLods._pass_todo.is_empty()
	FrameBudget.reduce_floors = bl_rf_was
	check(bl_skip_4 and bl_moved_4 and bl_deferred and bl_resumed_keeps_cursor and bl_resumed_done and bl_off_done,
		"BeltLods 4-tile deadband and FrameBudget slicing (%s, %s, %s, %s, %s, %s)" % [
			bl_skip_4, bl_moved_4, bl_deferred, bl_resumed_keeps_cursor, bl_resumed_done, bl_off_done])
	BeltLods._chunks.clear()
	BeltLods._last_view = []
	BeltLods._pass_todo = []
	BeltLods._pass_next = 0
	BeltLods.move_deadband = bl_dead_was
	BeltLods.slice_enabled = bl_slice_was
	FrameBudget.reset()
	FrameBudget.shared = fb_shared_was
	FrameBudget.hard_cap = fb_hard_was
	FrameBudget.test_no_deadline = fb_nd_was
	FrameBudget.test_other_usec = fb_ou_was
	bl_host.queue_free()

	# 5. BehindCull tight move_step >= 4.0 floor, collar + sliced reveal & deferred visibility signals,
	#    plus FarChunks _waiting unchanged skip.
	var vp_tight_was := ViewPriority.tight_cull
	var bc_slice_was := BehindCull.slice_show
	ViewPriority.tight_cull = true
	BehindCull.slice_show = true
	var bcw := _make_world(1)
	var bcam := Camera3D.new()
	bcam.fov = 40.0
	bcam.far = 600.0
	add_child(bcam)
	bcam.current = true
	for y in range(-10, 8):
		for x in range(-4, 5):
			var c := Vector2i(x, y)
			var bcv := ChunkView.new()
			bcv.coord = c
			bcv.loaded = true
			bcw.chunks[c] = bcv
			bcw.add_child(bcv)
			bcw.behind_cull.added(c, bcv)
	bcam.look_at_from_position(Vector3(16.0, 6.0, 0.0), Vector3(16.0, 0.0, 120.0))
	for _i in 20:
		bcw.behind_cull._process(0.016)
	var passes_before := bcw.behind_cull.passes
	bcam.look_at_from_position(Vector3(18.5, 6.0, 0.0), Vector3(18.5, 0.0, 120.0))
	bcw.behind_cull._process(0.016)
	var move_floor_ok := bcw.behind_cull.passes == passes_before
	bcam.look_at_from_position(Vector3(16.0, 20.0, 0.0), Vector3(16.0, 0.0, 120.0))
	for _i in 20:
		bcw.behind_cull._process(0.016)
	var vis_emits := 0
	var vis_cb := func(_c: Vector2i, drawn: bool) -> void:
		if drawn:
			vis_emits += 1
	bcw.behind_cull.chunk_visibility_changed.connect(vis_cb)
	bcam.look_at_from_position(Vector3(16.0, 20.0, 0.0), Vector3(16.0, 0.0, -120.0))
	bcw.behind_cull._process(0.016)
	var collar_vis := (bcw.chunks[Vector2i(0, -1)] as ChunkView).visible
	var turn_far_vis := (bcw.chunks[Vector2i(0, -9)] as ChunkView).visible
	var queued_vis := bcw.behind_cull._vis_show_queue.size()
	var emits_turn := vis_emits
	for _i in 10:
		bcw.behind_cull._process(0.016)
	var show_drained := bcw.behind_cull._to_show.is_empty() and bcw.behind_cull._vis_show_queue.is_empty()
	# Non-turn reveal (far plane increase with no camera rotation) slices far reveals across frames.
	bcam.far = 120.0
	bcam.look_at_from_position(Vector3(16.0, 20.0, -64.0), Vector3(16.0, 0.0, 120.0))
	for _i in 20:
		bcw.behind_cull._process(0.016)
	bcam.far = 600.0
	bcw.behind_cull._process(0.016)
	var pan_sliced := bcw.behind_cull._to_show.size() > 0 or not bcw.behind_cull._vis_show_queue.is_empty()
	for _i in 10:
		bcw.behind_cull._process(0.016)
	bcw.behind_cull.chunk_visibility_changed.disconnect(vis_cb)

	BehindCull.slice_show = false
	bcam.look_at_from_position(Vector3(16.0, 20.0, 0.0), Vector3(16.0, 0.0, 120.0))
	for _i in 20:
		bcw.behind_cull._process(0.016)
	bcam.look_at_from_position(Vector3(16.0, 20.0, 0.0), Vector3(16.0, 0.0, -120.0))
	bcw.behind_cull._process(0.016)
	var show_off_immediate := bcw.behind_cull._to_show.is_empty() and bcw.behind_cull._vis_show_queue.is_empty() and (bcw.chunks[Vector2i(0, -9)] as ChunkView).visible
	check(move_floor_ok and collar_vis and turn_far_vis and queued_vis > 0 and emits_turn <= BehindCull.VIS_SIGNALS_PER_FRAME + 20
		and show_drained and pan_sliced and show_off_immediate,
		"BehindCull move_step>=4 floor, >15deg _turn_reveal + sliced vis/pan & =off fallback (%s, collar=%s, far=%s, vis_q=%d, pan=%s, off=%s)"
		% [move_floor_ok, collar_vis, turn_far_vis, queued_vis, pan_sliced, show_off_immediate])

	var fc_skip := FarChunks.new()
	fc_skip.world = bcw
	var c_w1 := Vector2i(0, 0)
	var c_w2 := Vector2i(1, 0)
	var cv_w1: ChunkView = bcw.chunks[c_w1]
	var cv_w2: ChunkView = bcw.chunks[c_w2]
	cv_w1.far.far = true
	cv_w1.far.phase = FarChunks.WAITING
	cv_w1.far.checked = true
	cv_w1.far.serial = 1
	cv_w2.far.far = true
	cv_w2.far.phase = FarChunks.WAITING
	cv_w2.far.checked = true
	cv_w2.far.serial = 1
	fc_skip._waiting = [[cv_w2, 1], [cv_w1, 1]]
	fc_skip._progress = 5
	fc_skip._stamp = 5
	fc_skip._waiting_last_len = 2
	fc_skip._start_merges()
	var kept_order: bool = fc_skip._waiting.size() == 2 and fc_skip._waiting[0][0] == cv_w2
	check(kept_order, "FarChunks._start_merges skips unnecessary sort/prune when nothing changed")

	fc_skip.free()
	bcam.queue_free()
	bcw.queue_free()
	ViewPriority.tight_cull = vp_tight_was
	BehindCull.slice_show = bc_slice_was
	await get_tree().process_frame


## P4 (`--unload-fast`): what leaves the view or the render distance is hidden at once and freed later.
## 1. In a frame already past its deadline with the pool used up, the systems that take drawing away (levels of
##    detail, far merging...) still get their floors (FrameBudget.REDUCERS), within REDUCE_TOTAL; off: nothing.
## 2. A half turn hides every chunk that left the outline that frame (off: HIDE_PER_FRAME_TIGHT a frame).
## 3. Chunks kept built past the square (world.gd WARM_RINGS) aren't drawn, Distant Horizon is told, and they are
##    shown again (the same nodes, nothing rebuilt) when the square comes back over them; off: drawn.
func _test_unload_fast() -> void:
	var shared_was := FrameBudget.shared
	var cap_was := FrameBudget.hard_cap
	var rf_was := FrameBudget.reduce_floors
	var other_was := FrameBudget.test_other_usec
	var nodl_was := FrameBudget.test_no_deadline
	FrameBudget.shared = true
	FrameBudget.hard_cap = true
	FrameBudget.test_no_deadline = false
	FrameBudget.test_other_usec = 15000  # a slow frame: the pool at POOL_MIN
	var grants := {}
	for on in [true, false]:
		FrameBudget.reduce_floors = on
		FrameBudget.reset()
		FrameBudget.spent(&"build", 6000, 5)  # the near work used the pool up
		var sum := 0
		var got := {}
		for sys: StringName in [&"lods", &"far_decide", &"far_collect", &"far_install", &"shadows", &"belt_lods"]:
			FrameBudget.waiting(sys, 40)
			var g := FrameBudget.grant(sys)
			got[sys] = g
			sum += g
		# One more grant (scale 3) runs into REDUCE_TOTAL: clipped to what is left.
		FrameBudget.waiting(&"far_collect", 40)
		var last := FrameBudget.grant(&"far_collect", 3)
		sum += last
		grants[on] = [got, sum, last]
	FrameBudget.reset()
	FrameBudget.shared = shared_was
	FrameBudget.hard_cap = cap_was
	FrameBudget.reduce_floors = rf_was
	FrameBudget.test_other_usec = other_was
	FrameBudget.test_no_deadline = nodl_was
	var on_got: Dictionary = grants[true][0]
	var off_got: Dictionary = grants[false][0]
	check(int(on_got[&"lods"]) >= 600 and int(on_got[&"far_decide"]) >= 400 and int(grants[true][1]) <= FrameBudget.REDUCE_TOTAL
		and int(off_got[&"lods"]) == 0 and int(off_got[&"far_decide"]) == 0,
		"unload_fast: reducers keep their floors past the deadline and the hard cap (on %s, off %s)" % [str(grants[true]), str(grants[false])])
	check(int(grants[true][1]) <= FrameBudget.REDUCE_TOTAL and int(grants[true][2]) <= 100 and int(grants[true][2]) < 1200,
		"unload_fast: the reducers' total is capped and the last grant clipped (%s)" % str(grants[true]))

	# The raise never gives less than the old floors: urgent far merging at scale 3, and the hard cap off.
	var far_boost_was := FrameBudget.far_priority_boost
	var urgent_was := FrameBudget.far_urgent
	FrameBudget.shared = true
	FrameBudget.test_no_deadline = false
	FrameBudget.test_other_usec = 15000
	FrameBudget.far_priority_boost = true
	var floors := {}
	for cap in [true, false]:
		FrameBudget.hard_cap = cap
		FrameBudget.reduce_floors = true
		FrameBudget.reset()
		FrameBudget.far_urgent = true
		FrameBudget.spent(&"build", 6000, 5)
		FrameBudget.waiting(&"far_collect", 40)
		FrameBudget.waiting(&"far_install", 40)
		var fc := FrameBudget.grant(&"far_collect", 3)
		var fi := FrameBudget.grant(&"far_install", 3)
		FrameBudget.waiting(&"lods", 40)
		FrameBudget.waiting(&"shadows", 40)
		var ls := FrameBudget.grant(&"lods")
		var sh := FrameBudget.grant(&"shadows")
		floors[cap] = [fc, fi, ls, sh]
	FrameBudget.reset()
	FrameBudget.far_priority_boost = far_boost_was
	FrameBudget.far_urgent = urgent_was
	FrameBudget.shared = shared_was
	FrameBudget.hard_cap = cap_was
	FrameBudget.reduce_floors = rf_was
	FrameBudget.test_other_usec = other_was
	FrameBudget.test_no_deadline = nodl_was
	check(int(floors[true][0]) >= 1800 and int(floors[true][1]) >= 600,
		"unload_fast: urgent far_collect/far_install at scale 3 get at least the old floors (%s)" % str(floors[true]))
	check(int(floors[false][2]) >= 600 and int(floors[false][3]) >= 300,
		"unload_fast: --budget-hard-cap=off keeps lods/shadows' full SYSTEMS floor (%s)" % str(floors[false]))

	var vp_tight_was := ViewPriority.tight_cull
	var fast_was := BehindCull.unload_fast
	var slice_was := BehindCull.slice_hide
	var subs_was := Bridge.square_subs
	ViewPriority.tight_cull = true
	BehindCull.slice_hide = true
	var cam := Camera3D.new()
	cam.fov = 40.0
	cam.far = 900.0
	add_child(cam)
	cam.current = true
	var left_after := {}
	for on in [true, false]:
		BehindCull.unload_fast = on
		Bridge.square_subs = 0
		var w := _make_world(1)
		for y in range(-16, 17):
			for x in range(-6, 7):
				var c := Vector2i(x, y)
				var cv := ChunkView.new()
				cv.coord = c
				cv.loaded = true
				w.chunks[c] = cv
				w.add_child(cv)
				w.behind_cull.added(c, cv)
		cam.look_at_from_position(Vector3(16.0, 20.0, 0.0), Vector3(16.0, 0.0, 400.0))
		for _i in 20:
			w.behind_cull._process(0.016)
		cam.look_at_from_position(Vector3(16.0, 20.0, 0.0), Vector3(16.0, 0.0, -400.0))
		w.behind_cull._process(0.016)
		left_after[on] = w.behind_cull._to_hide.size()
		if on:
			# 3. The square at the origin, radius 3: (0, -9) is past it though in view.
			var hid := []
			var cb := func(c: Vector2i, drawn: bool) -> void:
				if not drawn:
					hid.append(c)
			w.behind_cull.chunk_visibility_changed.connect(cb)
			Bridge.square_subs = 8
			w._sq_center = Vector2i.ZERO
			w._sq_radius = 3
			var warm_cv: ChunkView = w.chunks[Vector2i(0, -9)]
			for _i in 5:
				w.behind_cull._process(0.016)
			var past_hidden: bool = not warm_cv.visible and hid.has(Vector2i(0, -9))
			var inside_drawn: bool = (w.chunks[Vector2i(0, -2)] as ChunkView).visible
			w._sq_center = Vector2i(0, -7)
			for _i in 20:
				w.behind_cull._process(0.016)
			var back: bool = warm_cv.visible and w.chunks[Vector2i(0, -9)] == warm_cv
			w.behind_cull.chunk_visibility_changed.disconnect(cb)
			check(past_hidden and inside_drawn and back,
				"unload_fast: a chunk kept past the square is hidden (DH told) and shown again unrebuilt when the square returns (hidden %s, inside %s, back %s)"
				% [past_hidden, inside_drawn, back])
		else:
			Bridge.square_subs = 8
			w._sq_center = Vector2i.ZERO
			w._sq_radius = 3
			for _i in 5:
				w.behind_cull._process(0.016)
			check((w.chunks[Vector2i(0, -9)] as ChunkView).visible, "--unload-fast=off: a chunk kept past the square stays drawn")
		w.queue_free()
		await get_tree().process_frame
	check(int(left_after[true]) == 0 and int(left_after[false]) > 0,
		"unload_fast: a half turn hides every chunk that left the outline that frame (left to hide: on %d, off %d)" % [left_after[true], left_after[false]])
	cam.queue_free()
	ViewPriority.tight_cull = vp_tight_was
	BehindCull.unload_fast = fast_was
	BehindCull.slice_hide = slice_was
	Bridge.square_subs = subs_was
	await get_tree().process_frame
