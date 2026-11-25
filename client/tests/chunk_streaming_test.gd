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
	await _test_chunk_disk_cache()
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
