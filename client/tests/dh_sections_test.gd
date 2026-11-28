extends SceneTree
## Distant Horizon section bookkeeping (perf-w4-dh), each new way against the old one kept behind its switch:
## - --dh-retire-index: a retiring node's indexed lookup (_retiree_ready_indexed, last blocker first) frees it
##   exactly when the old scan of every section would (_retiree_ready_scan), on random layouts and flags;
##   has_mesh_for_chunk finds the same retiring nodes by key as by walking them all.
## - --dh-retire-index + --dh-vis-incremental: two instances (switches on / off) driven through the same moves,
##   chunk loads/unloads/fades, set_chunk, builds and installs hold the same retiring nodes and the same node
##   `visible` after every update step.
## - --dh-sub-scan: the row scan (_collect_want_batch_rows) asks for the same chunks and leaves the same section
##   flags as the old scan once drained, with a fake disk cache and charted runs; with its budget at 0 (one
##   block row a call, resumed from the section's cursor) too.
## Prints the old and new µs of the retire lookup at ~1000 sections / 80 retiring nodes.
## Run: godot --headless --audio-driver Dummy --path client --log-file <abs> --script res://tests/dh_sections_test.gd

const DistantHorizon := preload("res://scripts/world/distant_horizon.gd")
const LodMesher := preload("res://scripts/world/lod_mesher.gd")
const LodCache := preload("res://scripts/world/lod_cache.gd")
const TestEnv := preload("res://tests/test_env.gd")


class FakeChunk extends RefCounted:
	var cx := 0
	var cy := 0
	var res := 4


class FakeCache extends RefCounted:
	var loaded := {}  # Vector2i region -> true
	var disk := {}  # Vector2i chunk -> FakeChunk

	func is_region_loaded(rx: int, ry: int) -> bool:
		return loaded.has(Vector2i(rx, ry))

	func request_region(_rx: int, _ry: int) -> void:
		pass

	func get_chunk(cx: int, cy: int) -> Variant:
		return disk.get(Vector2i(cx, cy))


var fails := 0
var _free_nodes: Array = []


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _init() -> void:
	TestEnv.isolate("dh-sections-test")
	call_deferred("_run")


func _run() -> void:
	_test_retire_lookup()
	_test_sequence()
	_test_sub_scan()
	for n: Variant in _free_nodes:
		if is_instance_valid(n):
			(n as Node).free()
	print("dh_sections_test: %s" % ("PASS" if fails == 0 else "FAILS %d" % fails))
	quit(0 if fails == 0 else 1)


func _node(vis := true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.visible = vis
	_free_nodes.append(mi)
	return mi


func _new_dh() -> Node3D:
	var dh: Node3D = DistantHorizon.new()
	dh.enabled = true
	_free_nodes.append(dh)
	return dh


## Sections of ring_sections(center, radius) with random build flags.
func _fill_sections(dh: Node3D, rng: RandomNumberGenerator, center: Vector2i, radius: int) -> void:
	for spec: Dictionary in DistantHorizon.ring_sections(center, radius, 0, "medium", "balanced"):
		var st := DistantHorizon.SectionState.new()
		st.key = spec["key"]
		st.level = int(spec["level"])
		st.sx = int(spec["sx"])
		st.sy = int(spec["sy"])
		st.sec_chunks = int(spec["sec_chunks"])
		st.cell_tiles = float(spec["cell_tiles"])
		_rand_flags(st, rng)
		dh._sections[st.key] = st


func _rand_flags(st: Object, rng: RandomNumberGenerator) -> void:
	st.node = _node() if rng.randf() < 0.6 else null
	st.has_data = rng.randf() < 0.7
	st.built_empty = rng.randf() < 0.3
	st.dirty = rng.randf() < 0.4
	st.building = rng.randf() < 0.2


## Retiring nodes from another layout's sections.
func _add_retirees(dh: Node3D, rng: RandomNumberGenerator, center: Vector2i, radius: int, n: int) -> void:
	var specs := DistantHorizon.ring_sections(center, radius, 0, "medium", "balanced")
	for i in n:
		var spec: Dictionary = specs[rng.randi_range(0, specs.size() - 1)]
		var sec := int(spec["sec_chunks"])
		dh._retire_add({
			"node": _node(rng.randf() < 0.85),
			"rect": Rect2i(int(spec["sx"]) * sec, int(spec["sy"]) * sec, sec, sec),
			"level": int(spec["level"]),
			"chunk_mask": rng.randi() & 0xffff,
			"key": spec["key"],
		})


func _test_retire_lookup() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7001
	var cases := 0
	var mesh_cases := 0
	for layout in 12:
		var dh := _new_dh()
		var center := Vector2i(rng.randi_range(-200, 200), rng.randi_range(-200, 200))
		var radius := rng.randi_range(30, 160)
		dh.radius_chunks = radius
		_fill_sections(dh, rng, center, radius)
		_add_retirees(dh, rng, center + Vector2i(rng.randi_range(-12, 12), rng.randi_range(-12, 12)), radius, 60)
		for i in 300:
			var c := center + Vector2i(rng.randi_range(-radius, radius), rng.randi_range(-radius, radius))
			if rng.randf() < 0.6:
				var ch := FakeChunk.new()
				ch.cx = c.x
				ch.cy = c.y
				dh._mem_chunks[c] = ch
		for round_i in 4:
			for entry: Dictionary in dh._retiring:
				var old_r: bool = dh._retiree_ready_scan(entry["rect"])
				var new_r: bool = dh._retiree_ready_indexed(entry)
				var new_again: bool = dh._retiree_ready_indexed(entry)  # with the remembered blocker
				cases += 1
				if old_r != new_r or new_r != new_again:
					check(false, "retire lookup layout %d round %d key %s: old %s new %s again %s" % [layout, round_i, entry["key"], old_r, new_r, new_again])
			for i in 400:
				var c := center + Vector2i(rng.randi_range(-radius, radius), rng.randi_range(-radius, radius))
				dh.retire_index = true
				var a: bool = dh.has_mesh_for_chunk(c)
				dh.retire_index = false
				var b: bool = dh.has_mesh_for_chunk(c)
				mesh_cases += 1
				if a != b:
					check(false, "has_mesh_for_chunk %s layout %d: index %s walk %s" % [c, layout, a, b])
			# Flags change between rounds (builds finish, sections start building).
			for k: Variant in dh._sections:
				if rng.randf() < 0.3:
					_rand_flags(dh._sections[k], rng)
	print("dh_sections_test: retire lookup %d cases, has_mesh_for_chunk %d chunks" % [cases, mesh_cases])

	# µs at ~1000 sections / 80 retiring nodes: the old per-frame scan vs the indexed one (first and again).
	var dhb := _new_dh()
	var r := 160
	while DistantHorizon.ring_sections(Vector2i.ZERO, r, 0, "medium", "balanced").size() < 1000 and r < 512:
		r += 16
	dhb.radius_chunks = r
	var rngb := RandomNumberGenerator.new()
	rngb.seed = 99
	_fill_sections(dhb, rngb, Vector2i.ZERO, r)
	for k: Variant in dhb._sections:  # mostly built, as a real base: few blockers
		var st: Object = dhb._sections[k]
		if rngb.randf() < 0.9:
			st.node = _node()
	_add_retirees(dhb, rngb, Vector2i(10, -6), r, 80)
	var t0 := Time.get_ticks_usec()
	for entry: Dictionary in dhb._retiring:
		dhb._retiree_ready_scan(entry["rect"])
	var us_old := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	for entry: Dictionary in dhb._retiring:
		dhb._retiree_ready_indexed(entry)
	var us_new := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	for entry: Dictionary in dhb._retiring:
		dhb._retiree_ready_indexed(entry)
	var us_again := Time.get_ticks_usec() - t0
	dhb._gc_pending = false
	t0 = Time.get_ticks_usec()
	dhb._gc_retiring()
	var us_idle := Time.get_ticks_usec() - t0
	print("dh_sections_test: %d sections / %d retiring: old scan %d µs a frame, indexed %d µs (again %d, idle frame %d)"
		% [dhb._sections.size(), dhb._retiring.size(), us_old, us_new, us_again, us_idle])


# --- the two instances driven alike ---

func _snapshot(dh: Node3D) -> String:
	var parts: Array = []
	for e: Dictionary in dh._retiring:
		parts.append("R%s:%s" % [e["key"], (e["node"] as MeshInstance3D).visible])
	parts.sort()
	var keys: Array = dh._sections.keys()
	keys.sort()
	for k: Variant in keys:
		var st: Object = dh._sections[k]
		var nd: Variant = st.node
		parts.append("S%s:%s" % [k, "-" if nd == null else str((nd as MeshInstance3D).visible)])
	return ",".join(parts)


func _frame(dh: Node3D) -> void:
	dh._tick_pending_masks()
	dh._tick_mask_fades(0.1)
	dh._update_lod0_visibility()
	dh._poll_and_install_meshes(false)
	dh._gc_retiring()
	if dh._lod0_vis_dirty:
		dh._update_lod0_visibility()


func _test_sequence() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 31337
	var a := _new_dh()  # new ways
	var b := _new_dh()  # old ways
	b.retire_index = false
	b.vis_incremental = false
	for dh: Node3D in [a, b]:
		dh.radius_chunks = 64
	var center := Vector2i(3, -2)
	var pending: Array = []  # [key, serial_a, serial_b, with_mesh, mask]
	var steps := 600
	var freed_any := 0
	var hidden_seen := 0
	var mesh_checks := 0
	for dh: Node3D in [a, b]:
		dh._sync_sections(center)
	for s in steps:
		var r := rng.randf()
		if r < 0.08:
			center += Vector2i(rng.randi_range(-12, 12), rng.randi_range(-12, 12))
			for dh: Node3D in [a, b]:
				dh._sync_sections(center)
		elif r < 0.30:
			# A level-0 section's chunks loaded or unloaded together, or one chunk.
			var c0 := center + Vector2i(rng.randi_range(-20, 20), rng.randi_range(-20, 20))
			var do_load := rng.randf() < 0.65
			var instant := rng.randf() < 0.3
			var whole := rng.randf() < 0.6
			var base := Vector2i(c0.x >> 2 << 2, c0.y >> 2 << 2)
			for dy in (4 if whole else 1):
				for dx in (4 if whole else 1):
					var c := (base + Vector2i(dx, dy)) if whole else c0
					for dh: Node3D in [a, b]:
						dh.set_chunk_loaded(c, do_load, instant)
		elif r < 0.42:
			var c := center + Vector2i(rng.randi_range(-60, 60), rng.randi_range(-60, 60))
			for dh: Node3D in [a, b]:
				var ch := FakeChunk.new()
				ch.cx = c.x
				ch.cy = c.y
				dh.set_chunk(ch)
		elif r < 0.70:
			# A build dispatched (as _dispatch_sections leaves it).
			var keys: Array = a._sections.keys()
			keys.sort()
			var cands: Array = []
			for k: Variant in keys:
				var st: Object = a._sections[k]
				if st.dirty and st.has_data and not st.building:
					cands.append(k)
			if not cands.is_empty():
				var k: Vector3i = cands[rng.randi_range(0, cands.size() - 1)]
				var sb: Object = b._sections.get(k)
				check(sb != null and sb.dirty and sb.has_data and not sb.building, "step %d: section %s alike in both" % [s, k])
				if sb != null:
					var sa: Object = a._sections[k]
					sa.dirty = false
					sa.building = true
					sb.dirty = false
					sb.building = true
					pending.append([k, sa.serial, sb.serial, rng.randf() < 0.85, rng.randi() & 0xffff])
		elif r < 0.97:
			if not pending.is_empty():
				var p: Array = pending.pop_at(rng.randi_range(0, pending.size() - 1))
				for i in 2:
					var dh: Node3D = [a, b][i]
					var job := LodMesher.new()
					job.key = p[0]
					job.serial = int(p[1 + i])
					job.chunk_mask = int(p[4])
					if bool(p[3]):
						job.mesh = ArrayMesh.new()
						job.tri_count = 12
					dh._ready_meshes.append(job)
		else:
			for dh: Node3D in [a, b]:
				dh.finish_mask_fades()
		var n_ret_before: int = a._retiring.size()
		for dh: Node3D in [a, b]:
			_frame(dh)
		if a._retiring.size() < n_ret_before:
			freed_any += 1
		var sa_txt := _snapshot(a)
		var sb_txt := _snapshot(b)
		if sa_txt != sb_txt:
			check(false, "step %d: instances differ\n new: %s\n old: %s" % [s, sa_txt.left(600), sb_txt.left(600)])
			break
		check(not a._lod0_vis_dirty and not b._lod0_vis_dirty, "step %d: visibility pass done" % s)
		hidden_seen += sa_txt.count(":false")
		for i in 20:
			var c := center + Vector2i(rng.randi_range(-70, 70), rng.randi_range(-70, 70))
			mesh_checks += 1
			if a.has_mesh_for_chunk(c) != b.has_mesh_for_chunk(c):
				check(false, "step %d: has_mesh_for_chunk %s differs" % [s, c])
	check(freed_any > 0 and hidden_seen > 0, "sequence exercised freeing (%d) and hidden nodes (%d)" % [freed_any, hidden_seen])
	print("dh_sections_test: sequence %d steps alike (retirees freed in %d, hidden node-steps %d, %d has_mesh checks)"
		% [steps, freed_any, hidden_seen, mesh_checks])


# --- want scan ---

## A Distant Horizon with `n` random sections over random chunks, charted runs, stale/missing/requested chunks
## and a fake disk cache; the same for the same seed.
func _scan_state(sd: int, n: int, map_old: bool) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = sd
	var dh := _new_dh()
	dh.map_old = map_old
	dh.sub_scan_old_budget_usec = 1000000000  # the reference: the old scan never cut short by its clock
	var cache := FakeCache.new()
	dh._cache = cache
	dh._cache_configured = true
	for ry in range(-2, 2):
		for rx in range(-2, 2):
			var rg := Vector2i(rx, ry)
			if rng.randf() < 0.5:
				dh._cached_region_revs[rg] = 1
				if rng.randf() < 0.6:
					cache.loaded[rg] = true
	var sts: Array = []
	var used := {}
	while sts.size() < n:
		var level := rng.randi_range(0, 2)
		var sec := int(DistantHorizon.SECTION_CHUNKS[level])
		var span := 24 / sec + 1
		var k := Vector3i(level, rng.randi_range(-span, span - 1), rng.randi_range(-span, span - 1))
		if used.has(k):
			continue
		used[k] = true
		var st := DistantHorizon.SectionState.new()
		st.key = k
		st.level = level
		st.sx = k.y
		st.sy = k.z
		st.sec_chunks = sec
		st.cell_tiles = [4.0, 8.0, 32.0, 64.0, 128.0][rng.randi_range(0, 4)]
		st.complete = false
		st.needs_missing_scan = true
		sts.append(st)
		dh._sections[k] = st
	dh._charted_known = rng.randf() < 0.85
	for cy in range(-30, 30):
		var runs := PackedInt32Array()
		var x := -30
		while x < 30:
			var a := x + rng.randi_range(0, 6)
			var b := a + rng.randi_range(1, 12)
			runs.append_array([a, b])
			x = b + 1
		if rng.randf() < 0.9:
			dh._charted_rows[cy] = runs
		for i in 3:
			var c := Vector2i(rng.randi_range(-30, 29), cy)
			dh._charted_extra[c] = true
			if map_old:
				dh._charted[c] = true
		if map_old:
			for i in range(0, runs.size(), 2):
				for cx in range(runs[i], runs[i + 1]):
					dh._charted[Vector2i(cx, cy)] = true
	for cy in range(-30, 30):
		for cx in range(-30, 30):
			var c := Vector2i(cx, cy)
			var rr := rng.randf()
			if rr < 0.35:
				var ch := FakeChunk.new()
				ch.cx = cx
				ch.cy = cy
				ch.res = [1, 4, 8, 16, 32, 64][rng.randi_range(0, 5)]
				dh._mem_chunks[c] = ch
			elif rr < 0.45:
				var ch2 := FakeChunk.new()
				ch2.cx = cx
				ch2.cy = cy
				ch2.res = [4, 32][rng.randi_range(0, 1)]
				cache.disk[c] = ch2
			if rng.randf() < 0.04:
				dh._stale_chunks[c] = true
			if rng.randf() < 0.04:
				dh._missing_chunks[c] = true
			if rng.randf() < 0.03:
				dh._requested_chunks[c] = 1000 if rng.randf() < 0.5 else 100000  # one in cooldown, one long ago
	return [dh, sts]


## Calls the scan until it asks for nothing and no section waits half-scanned; the chunks asked for (with
## their res) and every section's flags after.
func _drain(dh: Node3D, sts: Array, missing_only: bool, fixed_res: int) -> Array:
	var now := 105000
	var picks: Array = []
	var calls := 0
	var round_added := 0
	for it in 3000:
		var bucket: Array = []
		for st: Object in sts:
			if st.complete:
				continue
			bucket.append([true, false, st.level, DistantHorizon._snap_res(st.cell_tiles), 0.0, st])
		var res: Array = dh._collect_want_batch(bucket, missing_only, fixed_res, now)
		calls += 1
		var batch: Array = res[1]
		for p: Variant in batch:
			picks.append("%d:%d,%d" % [int(res[0]), int(p[0]), int(p[1])])
		round_added += batch.size()
		# A round: from no section half-scanned and no resume point to the same again (each call of the
		# old scan is one); drained when a whole round asks for nothing.
		var cursor: bool = not (dh._scan_resume as Dictionary).is_empty()
		for st: Object in sts:
			if st.scan_row > 0:
				cursor = true
		if not cursor:
			if round_added == 0:
				break
			round_added = 0
	picks.sort()
	var flags: Array = []
	for st: Object in sts:
		flags.append("%s:%s/%s/%d" % [st.key, st.complete, st.needs_missing_scan, st.next_sub_msec])
	return [picks, flags, calls]


func _test_sub_scan() -> void:
	var cases := 0
	var picks_n := 0
	var resumed_calls := 0
	for sd in 10:
		var map_old := sd % 3 == 2
		for mode in 3:
			var missing_only := mode < 2
			var fixed_res: int = [16, 32, -1][mode]
			var o: Array = _scan_state(1000 + sd, 18, map_old)
			(o[0] as Node3D).sub_scan_old = true
			var ro := _drain(o[0], o[1], missing_only, fixed_res)
			for budget: int in [1000000000, DistantHorizon.SUB_SCAN_ROW_BUDGET_USEC]:
				var nw: Array = _scan_state(1000 + sd, 18, map_old)
				(nw[0] as Node3D).sub_scan_budget_usec = budget
				var rn := _drain(nw[0], nw[1], missing_only, fixed_res)
				cases += 1
				check(ro[0] == rn[0], "sub scan sd %d mode %d budget %d: asks differ (%d vs %d)" % [sd, mode, budget, (ro[0] as Array).size(), (rn[0] as Array).size()])
				check(ro[1] == rn[1], "sub scan sd %d mode %d budget %d: flags differ\n old %s\n new %s" % [sd, mode, budget, ro[1], rn[1]])
			picks_n += (ro[0] as Array).size()
			# One section at a time, budget 0: one block row a call, resumed from the cursor.
			for si in 4:
				var o1: Array = _scan_state(2000 + sd * 10 + si, 1, map_old)
				(o1[0] as Node3D).sub_scan_old = true
				var r1o := _drain(o1[0], o1[1], missing_only, fixed_res)
				var n1: Array = _scan_state(2000 + sd * 10 + si, 1, map_old)
				(n1[0] as Node3D).sub_scan_budget_usec = 0
				var r1n := _drain(n1[0], n1[1], missing_only, fixed_res)
				resumed_calls += int(r1n[2])
				cases += 1
				check(r1o[0] == r1n[0] and r1o[1] == r1n[1], "resumed scan sd %d/%d mode %d: old %s %s new %s %s" % [sd, si, mode, r1o[0], r1o[1], r1n[0], r1n[1]])
	print("dh_sections_test: want scan %d cases alike (%d chunks asked in the old drains, %d calls one row at a time)" % [cases, picks_n, resumed_calls])

	# µs of one full scan both ways (no budget stop), 18 sections.
	var o2: Array = _scan_state(77, 18, false)
	(o2[0] as Node3D).sub_scan_old = true
	var n2: Array = _scan_state(77, 18, false)
	(n2[0] as Node3D).sub_scan_budget_usec = 1000000000
	var t0 := Time.get_ticks_usec()
	_drain(o2[0], o2[1], false, -1)
	var us_old := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	_drain(n2[0], n2[1], false, -1)
	var us_new := Time.get_ticks_usec() - t0
	print("dh_sections_test: want scan drain (18 sections) old %d µs, new %d µs" % [us_old, us_new])
