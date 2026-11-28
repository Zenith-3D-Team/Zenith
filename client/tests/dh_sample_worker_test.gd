extends SceneTree
## --dh-sample-worker parity (perf-w3-bridge): a Distant Horizon section's grid sampled on the worker
## (distant_horizon.gd `_gather_section_rows` + LodMesher.sample_grid) equals the main-thread sampler kept
## for =off (`_sample_section_grid`), on random chunks for every level and quality's cell size, with missing
## chunks, low-resolution chunks and entities; a palette change while the worker samples dirties the section.
## Also prints the main thread's µs a section both ways (gather vs old sampler).
## Run: godot --headless --audio-driver Dummy --path client --log-file <abs> --script res://tests/dh_sample_worker_test.gd

const DistantHorizon := preload("res://scripts/world/distant_horizon.gd")
const LodMesher := preload("res://scripts/world/lod_mesher.gd")
const TestEnv := preload("res://tests/test_env.gd")


class Pal extends RefCounted:
	var tile_colors := PackedColorArray()
	var tile_kind := PackedByteArray()
	var tile_rough := PackedFloat32Array()
	var ent_top_colors := PackedColorArray()
	var ent_side_colors := PackedColorArray()
	var ent_heights := PackedFloat32Array()
	var ent_metal := PackedFloat32Array()
	var ent_rough := PackedFloat32Array()
	var ent_cat := PackedByteArray()
	var ent_glow := PackedByteArray()

	func _init() -> void:
		tile_colors.resize(16)
		tile_colors.fill(Color(0.3, 0.4, 0.2))
		tile_kind.resize(16)
		tile_rough.resize(16)
		ent_top_colors.resize(31)
		ent_side_colors.resize(31)
		ent_heights.resize(31)
		ent_heights.fill(1.0)
		ent_metal.resize(31)
		ent_rough.resize(31)
		ent_glow.resize(31)


class Chunk extends RefCounted:
	var tiles := PackedInt32Array()
	var protos := PackedInt32Array()
	var flags := PackedByteArray()


var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _init() -> void:
	TestEnv.isolate("dh-sample-worker-test")
	call_deferred("_run")


func _rand_chunk(rng: RandomNumberGenerator, side: int, ents: bool) -> Chunk:
	var c := Chunk.new()
	var n := side * side
	c.tiles.resize(n)
	c.protos.resize(n)
	c.flags.resize(n)
	var base := rng.randi_range(0, 6)
	for i in n:
		var r := rng.randf()
		c.tiles[i] = base if r < 0.6 else (-1 if r < 0.65 else rng.randi_range(0, 9))
		if ents and rng.randf() < 0.15:
			c.protos[i] = rng.randi_range(1, 30)
			c.flags[i] = rng.randi_range(0, 15)
	if rng.randf() < 0.2:  # short protos/flags rows (older caches)
		c.protos.resize(n / 2)
		c.flags.resize(n / 3)
	return c


func _run() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var dh: Node3D = DistantHorizon.new()
	var pal := Pal.new()
	pal.ent_cat.resize(31)
	for i in 31:
		pal.ent_cat[i] = rng.randi_range(0, 6)
	dh._palette = pal
	var cases := 0
	var us_old := 0
	var us_new := 0
	var us_worker := 0
	for level in 5:
		var sec_chunks: int = int(DistantHorizon.SECTION_CHUNKS[level])
		for cell_tiles: float in [1.0, 2.0, 4.0, 8.0, 32.0, 64.0, 128.0]:
			var grid_n := maxi(1, roundi(float(sec_chunks * 32) / cell_tiles))
			if grid_n > 256 or grid_n < 1:
				continue
			for rep in 2:
				dh._mem_chunks.clear()
				var sx := rng.randi_range(-3, 3)
				var sy := rng.randi_range(-3, 3)
				var side := sec_chunks
				if cell_tiles > 32.0:
					side = maxi(side, grid_n * roundi(cell_tiles / 32.0))
				for oy in side:
					for ox in side:
						if rng.randf() < 0.15:
							continue  # missing chunk
						var res: int = [32, 32, 16, 8, 1][rng.randi_range(0, 4)]
						dh._mem_chunks[Vector2i(sx * sec_chunks + ox, sy * sec_chunks + oy)] = _rand_chunk(rng, res, rep == 0 or rng.randf() < 0.5)
				var st := DistantHorizon.SectionState.new()
				st.level = level
				st.sx = sx
				st.sy = sy
				st.sec_chunks = sec_chunks
				st.cell_tiles = cell_tiles
				st.grid_n = grid_n
				var t0 := Time.get_ticks_usec()
				var old: Array = dh._sample_section_grid(st)
				us_old += Time.get_ticks_usec() - t0
				var job := LodMesher.new()
				job.grid_n = grid_n
				job.cell_tiles = cell_tiles
				job.palette = pal
				t0 = Time.get_ticks_usec()
				dh._gather_section_rows(st, job)
				us_new += Time.get_ticks_usec() - t0
				var got: Array
				if job.sample_src.is_empty():
					got = [job.tiles, job.protos, job.flags, job.chunk_mask]
				else:
					t0 = Time.get_ticks_usec()
					got = LodMesher.sample_grid(grid_n, sec_chunks, cell_tiles, level, pal.ent_cat, job.sample_src, job.sample_side)
					us_worker += Time.get_ticks_usec() - t0
				var what := "level %d cell %s rep %d" % [level, cell_tiles, rep]
				check(got[0] == old[0], what + ": tiles equal")
				check(got[1] == old[1], what + ": protos equal")
				check(got[2] == old[2], what + ": flags equal")
				check(int(got[3]) == int(old[3]), what + ": chunk mask equal")
				cases += 1
	# An empty section (no chunk): the same empty grid without a worker pass.
	dh._mem_chunks.clear()
	var st0 := DistantHorizon.SectionState.new()
	st0.grid_n = 32
	var job0 := LodMesher.new()
	dh._gather_section_rows(st0, job0)
	var old0: Array = dh._sample_section_grid(st0)
	check(job0.sample_src.is_empty() and job0.tiles == old0[0] and job0.protos == old0[1], "empty section: same grid, no rows")
	# run() samples first: the job's grid matches the old sampler's after a run on this thread.
	dh._mem_chunks[Vector2i(0, 0)] = _rand_chunk(rng, 32, true)
	var st1 := DistantHorizon.SectionState.new()
	st1.grid_n = 32
	st1.cell_tiles = 4.0
	var job1 := LodMesher.new()
	job1.grid_n = 32
	job1.cell_tiles = 4.0
	job1.palette = pal
	dh._gather_section_rows(st1, job1)
	job1.run()
	var old1: Array = dh._sample_section_grid(st1)
	check(job1.tiles == old1[0] and job1.protos == old1[1] and job1.flags == old1[2] and job1.chunk_mask == int(old1[3]),
		"run(): samples its grid before meshing")
	check(job1.sample_src.is_empty(), "run(): drops the rows once sampled")
	# Palette recheck while the worker's grid is unknown: dirtied (the in-flight grid can't be checked).
	var key := Vector3i(0, 0, 0)
	var st2 := DistantHorizon.SectionState.new()
	st2.key = key
	st2.has_data = true
	st2.building = true
	st2.dirty = false
	st2.grid_pending = true
	st2.grid_pal = Pal.new()  # an older palette
	dh._sections[key] = st2
	dh._pal_recheck = [key]
	dh._pal_changed_tiles = PackedInt32Array([999])
	dh._pal_changed_ents = PackedInt32Array()
	dh._recheck_palette_sections(1000000)
	check(st2.dirty, "palette change while sampling on the worker: the section is rebuilt")
	# Once the job returns its grid, the recheck reads it again (an unused id: not dirtied).
	var job2 := LodMesher.new()
	job2.key = key
	job2.serial = st2.serial
	job2.tiles = PackedInt32Array([1, 2])
	job2.protos = PackedInt32Array([3])
	dh._note_sampled_grid(job2)
	check(not st2.grid_pending and st2.grid_tiles == job2.tiles, "finished job: its grid is the section's")
	st2.dirty = false
	dh._pal_recheck = [key]
	dh._pal_changed_tiles = PackedInt32Array([999])
	dh._recheck_palette_sections(1000000)
	check(not st2.dirty, "palette change on ids the returned grid lacks: not rebuilt")
	# The switch.
	var ov: Dictionary = DistantHorizon.cli_override(PackedStringArray(["--dh-sample-worker=off"]))
	check(ov.get("sample_worker", true) == false, "--dh-sample-worker=off parsed")
	check(dh.sample_worker, "on by default")
	print("dh_sample_worker_test: %d sections, main thread µs old sampler %d, gather %d (worker's sampling %d)" % [cases, us_old, us_new, us_worker])
	dh.free()
	TestEnv.clean()
	print("dh_sample_worker_test: %s" % ("PASS" if fails == 0 else "FAILS %d" % fails))
	quit(1 if fails else 0)
