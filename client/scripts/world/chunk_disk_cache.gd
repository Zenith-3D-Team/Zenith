extends RefCounted
## Persistent Zstd-compressed 16x16-chunk disk cache (`ZCHK` v1) under `user://chunk-cache/`.
## Stores complete wire-truth chunk terrain + entity snapshots keyed by sanitized save_id,
## surface_index, and prototype-table hash so revisiting areas or restarting loads instantly
## before the server reconciles (`same` or double-buffered refresh).

const ProtoDB := preload("res://scripts/world/protos.gd")
const SafeDelete := preload("res://scripts/safe_delete.gd")
const WireDecode := preload("res://scripts/net/wire_decode.gd")
const Switches := preload("res://scripts/switches.gd")
const Probing := preload("res://scripts/debug/probing.gd")

const REGION := 16
const MAGIC := "ZCHK"
## 2: copies from v1 dropped once, as the bridge's chunk counts now go by tick (world.lua next_rev): a v1 copy
## may hold another play of the save that matched by count (a mined pole drawn as a stick, inserter-stick).
const VERSION := 2
const HEADER_BYTES := 26
const MAX_REGION_UNCOMPRESSED := 32 * 1024 * 1024
const TILES_COUNT := 1024
const MAX_READ_JOBS := 2
const FLUSH_INTERVAL := 10.0
const DEFAULT_MAX_BYTES := 512 * 1024 * 1024

## --chunk-disk-cache-async=off: stringify entity extras and encode region bytes on the main thread.
static var async_encode := Switches.on("--chunk-disk-cache-async")

var enabled := true
var max_bytes := DEFAULT_MAX_BYTES

var _base_dir := "user://chunk-cache"
var _save_id := ""
var _surface_index := -1
var _proto_hash := 0
var _surface_dir := ""
var _configured := false

var _regions := {}  # Vector2i(rx, ry) -> {Vector2i(cx, cy): Dictionary}
var _loaded := {}  # Vector2i(rx, ry) -> true (loaded from disk or known absent/created)
var _dirty := {}  # Vector2i(rx, ry) -> true
var _read_jobs := {}  # Vector2i(rx, ry) -> [task_id, ReadResult]
var _write_task := -1
var _write_state: WriteResult = null
var _flush_timer := 0.0
var _needs_prune := false
## The flush's region snapshots taken a slice a frame (FLUSH_SLICE_USEC, at least a few chunks) instead
## of every dirty region's chunks copied in one frame (x_disk_cache 11.7 ms in the owner's spike log);
## --disk-flush-sliced=off: all in the frame the flush starts, as before.
static var flush_sliced := Switches.on("--disk-flush-sliced")
const FLUSH_SLICE_USEC := 1000
var _snapping := false
var _snap_regions: Array = []  # the dirty regions when the flush started
var _snap_ri := 0
var _snap_cur: Array = []  # [region, keys, next index, entries] or empty
var _snap_out: Array = []  # finished [abs_path, rx, ry, entries]
## The sliced flush's clock checked after every chunk (it was every 8: a busy region's eight chunks of 500 extras each
## were 12-24 ms, x_disk_cache in the owner's mega base) and a chunk's extras deep-copied FLUSH_XE_BATCH at a time, the
## copy carried on next frame (_snap_xe); the flush's snapshots let go on the write worker (it empties st.snapshots and
## st.items), not in the frame poll() sees it done. `--stutter-probe` parts `dc_snap` (the copies) and `dc_free`.
## --disk-flush-fine=off: the clock every 8 chunks, each chunk's extras in one copy and freed on the main thread, as before.
static var flush_fine := Switches.on("--disk-flush-fine")
const FLUSH_XE_BATCH := 64
var _snap_xe: Array = []  # a chunk's extras part-way copied: [snap, source xe, copied so far] or empty
## For tests: what the last _snap_step did ([chunks, extras copied]).
var snap_last := [0, 0]


class ReadResult:
	var rx := 0
	var ry := 0
	var proto_hash := 0
	var abs_path := ""
	var chunks := {}  # Vector2i -> Dictionary
	var ok := false


class WriteResult:
	var abs_dir := ""
	var proto_hash := 0
	var items: Array = []  # [[abs_path, PackedByteArray]]
	var snapshots: Array = []  # [[abs_path, rx, ry, Array[Dictionary]]]
	var prune := false
	var base_dir := ""
	var max_bytes := DEFAULT_MAX_BYTES
	var written := 0
	var free_here := false  # (flush_fine) the task empties items and snapshots itself


static func from_args() -> int:
	for arg: String in Switches.args():
		if arg.begins_with("--chunk-disk-cache-mb="):
			var mb := clampi(int(arg.get_slice("=", 1)), 16, 4096)
			return mb * 1024 * 1024
	return DEFAULT_MAX_BYTES


static func region_of(cx: int, cy: int) -> Vector2i:
	return Vector2i(floori(float(cx) / float(REGION)), floori(float(cy) / float(REGION)))


static func _sanitize_save_id(save_id: String) -> String:
	var out := ""
	for i in save_id.length():
		var code := save_id.unicode_at(i)
		var ok := (code >= 48 and code <= 57) \
			or (code >= 65 and code <= 90) \
			or (code >= 97 and code <= 122) \
			or code == 95 or code == 45
		if ok:
			out += save_id.substr(i, 1)
	if out.length() > 64:
		out = out.substr(0, 64)
	return out


## Deterministic 64-bit FNV-1a over entity and tile prototype name tables.
static func compute_proto_hash(protos: ProtoDB) -> int:
	if protos == null or (protos.tile_names.is_empty() and protos.entities.is_empty()):
		return 0
	var h: int = -3750763034362895579  # 0xCBF29CE484222325 signed 64-bit
	var prime: int = 1099511628211
	for name_str: String in protos.tile_names:
		var utf := name_str.to_utf8_buffer()
		for b in utf:
			h = (h ^ int(b)) * prime
		h = (h ^ 0xFF) * prime
	h = (h ^ 0xFE) * prime
	var ent_ids: Array = protos.entities.keys()
	ent_ids.sort()
	for eid: Variant in ent_ids:
		var ep: ProtoDB.EntityProto = protos.entities[eid]
		var utf := ("%d:%s" % [int(eid), ep.name]).to_utf8_buffer()
		for b in utf:
			h = (h ^ int(b)) * prime
		h = (h ^ 0xFF) * prime
	h = (h ^ 0xFE) * prime
	if h == 0:
		h = 1
	return h


func configure(save_id: String, surface_index: int, proto_hash: int, base_dir := "user://chunk-cache") -> void:
	wait_all()
	_base_dir = base_dir
	_save_id = _sanitize_save_id(save_id)
	_surface_index = surface_index
	_proto_hash = proto_hash
	clear_memory()
	if not enabled or _save_id == "" or _surface_index < 0 or _proto_hash == 0 or _base_dir == "":
		_surface_dir = ""
		_configured = false
		return
	_surface_dir = _base_dir.path_join(_save_id).path_join("s%d" % _surface_index)
	_configured = true
	_needs_prune = true


func is_configured() -> bool:
	return _configured and enabled


func clear_memory() -> void:
	wait_reads()
	_snap_reset()
	_regions.clear()
	_loaded.clear()
	_dirty.clear()


func has_region_loaded(cx: int, cy: int) -> bool:
	return _loaded.has(region_of(cx, cy))


func get_loaded_chunk(cx: int, cy: int) -> Dictionary:
	var r := region_of(cx, cy)
	if not _loaded.has(r):
		return {}
	var reg: Dictionary = _regions.get(r, {})
	var got: Variant = reg.get(Vector2i(cx, cy))
	return got if got is Dictionary else {}


## Synchronously fetches a chunk, loading its region from disk if needed (tests or immediate paths).
func get_chunk_sync(cx: int, cy: int) -> Dictionary:
	if not is_configured():
		return {}
	var r := region_of(cx, cy)
	if not _loaded.has(r):
		load_region_sync(r.x, r.y)
	return get_loaded_chunk(cx, cy)


## Queues an asynchronous region read if the region isn't in memory or already reading.
func request_chunk(cx: int, cy: int) -> void:
	if not is_configured():
		return
	var r := region_of(cx, cy)
	if _loaded.has(r) or _read_jobs.has(r) or _read_jobs.size() >= MAX_READ_JOBS:
		return
	var abs_path := ProjectSettings.globalize_path(_region_path(r.x, r.y))
	if not FileAccess.file_exists(abs_path) or SafeDelete.is_link(abs_path):
		_loaded[r] = true
		return
	var res := ReadResult.new()
	res.rx = r.x
	res.ry = r.y
	res.proto_hash = _proto_hash
	res.abs_path = abs_path
	var task_fn := func() -> void:
		res.chunks = _read_region_file(res.abs_path, res.rx, res.ry, res.proto_hash)
		res.ok = true
	var tid := WorkerThreadPool.add_task(task_fn, false, "chunk_disk_read")
	_read_jobs[r] = [tid, res]


## Polls finished async read/write tasks and steps periodic background flushing.
## Returns array of Vector2i region coords newly loaded into memory this frame.
func poll(delta: float) -> Array[Vector2i]:
	var ready: Array[Vector2i] = []
	for r: Vector2i in _read_jobs.keys():
		var entry: Array = _read_jobs[r]
		var tid := int(entry[0])
		if not WorkerThreadPool.is_task_completed(tid):
			continue
		WorkerThreadPool.wait_for_task_completion(tid)
		_read_jobs.erase(r)
		var res: ReadResult = entry[1]
		_loaded[r] = true
		if not res.chunks.is_empty():
			var reg: Dictionary = _regions.get(r, {})
			if not _regions.has(r):
				_regions[r] = reg
			for ck: Vector2i in res.chunks:
				if not reg.has(ck):
					reg[ck] = res.chunks[ck]
			ready.append(r)
	if _write_task >= 0 and WorkerThreadPool.is_task_completed(_write_task):
		WorkerThreadPool.wait_for_task_completion(_write_task)
		_write_task = -1
		var tf := Time.get_ticks_usec() if Probing.on else 0
		_write_state = null  # (flush_fine: its snapshots already let go on the worker)
		if tf > 0:
			Probing.add("dc_free", tf)
	if _snapping:
		flush_async()  # the snapshots' next slice
	elif is_configured():
		_flush_timer += delta
		if _flush_timer >= FLUSH_INTERVAL and _write_task < 0 and (not _dirty.is_empty() or _needs_prune):
			_flush_timer = 0.0
			flush_async()
	return ready


func put_chunk(cx: int, cy: int, rv: int, n: int, tiles: PackedInt32Array, e: Variant, xi: PackedInt32Array, xt: String, xe: Array = []) -> void:
	if not is_configured() or tiles.size() != TILES_COUNT:
		return
	var r := region_of(cx, cy)
	var reg: Dictionary = _regions.get(r, {})
	if not _regions.has(r):
		_regions[r] = reg
	var key := Vector2i(cx, cy)
	var cur: Variant = reg.get(key)
	if cur is Dictionary and int((cur as Dictionary).get("rv", -1)) == rv and int((cur as Dictionary).get("n", -1)) == n:
		return
	reg[key] = {
		"cx": cx,
		"cy": cy,
		"rv": rv,
		"n": n,
		"saved": int(Time.get_unix_time_from_system()),
		"tiles": tiles,
		"e": e,
		"xi": xi,
		"xe": xe,
		"xt": xt,
	}
	_dirty[r] = true
	if not _loaded.has(r):
		request_chunk(cx, cy)


func update_counts(cx: int, cy: int, rv: int, n: int) -> void:
	if not is_configured():
		return
	var r := region_of(cx, cy)
	if not _loaded.has(r):
		return
	var reg: Dictionary = _regions.get(r, {})
	var cur: Variant = reg.get(Vector2i(cx, cy))
	if cur is Dictionary:
		var d := cur as Dictionary
		if int(d.get("rv", -1)) != rv or int(d.get("n", -1)) != n:
			d["rv"] = rv
			d["n"] = n
			d["saved"] = int(Time.get_unix_time_from_system())
			_dirty[r] = true


func load_region_sync(rx: int, ry: int) -> Dictionary:
	var r := Vector2i(rx, ry)
	_loaded[r] = true
	if not is_configured():
		return {}
	var abs_path := ProjectSettings.globalize_path(_region_path(rx, ry))
	if not FileAccess.file_exists(abs_path) or SafeDelete.is_link(abs_path):
		return {}
	var disk := _read_region_file(abs_path, rx, ry, _proto_hash)
	if disk.is_empty():
		return {}
	var reg: Dictionary = _regions.get(r, {})
	if not _regions.has(r):
		_regions[r] = reg
	for ck: Vector2i in disk:
		if not reg.has(ck):
			reg[ck] = disk[ck]
	return reg


func _prepare_write_items(sync_load := false) -> Array:
	if not is_configured() or _dirty.is_empty():
		return []
	var abs_dir := ProjectSettings.globalize_path(_surface_dir)
	if DirAccess.make_dir_recursive_absolute(abs_dir) != OK:
		return []
	var items: Array = []
	for r: Vector2i in _dirty.keys():
		if not _loaded.has(r):
			if not sync_load:
				request_chunk(r.x * REGION, r.y * REGION)
				continue
			load_region_sync(r.x, r.y)
		var reg: Dictionary = _regions.get(r, {})
		if reg.is_empty():
			_dirty.erase(r)
			continue
		var payload := _encode_region_bytes(r.x, r.y, _proto_hash, reg)
		if payload.is_empty():
			continue
		var abs_path := ProjectSettings.globalize_path(_region_path(r.x, r.y))
		items.append([abs_path, payload])
		_dirty.erase(r)
	return items


func _prepare_write_snapshots() -> Array:
	if not is_configured() or _dirty.is_empty():
		return []
	var snapshots: Array = []
	for r: Vector2i in _dirty.keys():
		if not _loaded.has(r):
			request_chunk(r.x * REGION, r.y * REGION)
			continue
		var reg: Dictionary = _regions.get(r, {})
		if reg.is_empty():
			_dirty.erase(r)
			continue
		var entries: Array = []
		for d_v: Variant in reg.values():
			if not (d_v is Dictionary):
				continue
			var d := d_v as Dictionary
			var snap := d.duplicate(false)
			var xe_v: Variant = snap.get("xe")
			if str(snap.get("xt", "")) == "" and xe_v is Array and not (xe_v as Array).is_empty():
				snap["xe"] = (xe_v as Array).duplicate(true)
			entries.append(snap)
		if entries.is_empty():
			_dirty.erase(r)
			continue
		var abs_path := ProjectSettings.globalize_path(_region_path(r.x, r.y))
		snapshots.append([abs_path, r.x, r.y, entries])
		_dirty.erase(r)
	return snapshots


## The snapshots' next slice of `usec`; true when every region the flush started with is copied.
func _snap_step(usec: int) -> bool:
	var t0 := Time.get_ticks_usec()
	snap_last = [0, 0]
	if flush_fine and not _snap_xe.is_empty():
		if not _snap_xe_step(t0, usec) or Time.get_ticks_usec() - t0 > usec:
			return false  # (one batch past the slice at most)
	var n := 0
	while true:
		if _snap_cur.is_empty():
			if _snap_ri >= _snap_regions.size():
				return true
			var r: Vector2i = _snap_regions[_snap_ri]
			_snap_ri += 1
			if not _dirty.has(r):
				continue
			if not _loaded.has(r):
				request_chunk(r.x * REGION, r.y * REGION)
				continue
			var reg0: Dictionary = _regions.get(r, {})
			_dirty.erase(r)  # a chunk put from here on dirties it again for the next flush
			if reg0.is_empty():
				continue
			_snap_cur = [r, reg0.keys(), 0, []]
		var r2: Vector2i = _snap_cur[0]
		var keys: Array = _snap_cur[1]
		var entries: Array = _snap_cur[3]
		var reg: Dictionary = _regions.get(r2, {})
		var i := int(_snap_cur[2])
		while i < keys.size():
			var d_v: Variant = reg.get(keys[i])
			i += 1
			n += 1
			snap_last[0] += 1
			if d_v is Dictionary:
				var snap := (d_v as Dictionary).duplicate(false)
				var xe_v: Variant = snap.get("xe")
				var copying := false
				if str(snap.get("xt", "")) == "" and xe_v is Array and not (xe_v as Array).is_empty():
					if flush_fine:
						# Its extras copied FLUSH_XE_BATCH at a time, the clock checked between batches; it joins the
						# entries once copied (_snap_xe_step).
						_snap_xe = [snap, xe_v, []]
						_snap_cur[2] = i
						if not _snap_xe_step(t0, usec):
							return false
						copying = true
					else:
						snap["xe"] = (xe_v as Array).duplicate(true)
				if not copying:
					entries.append(snap)
			if (flush_fine or (n & 7) == 0) and Time.get_ticks_usec() - t0 > usec:
				_snap_cur[2] = i
				return false
		if not entries.is_empty():
			_snap_out.append([ProjectSettings.globalize_path(_region_path(r2.x, r2.y)), r2.x, r2.y, entries])
		_snap_cur = []
	return true


## The chunk whose extras are part-way copied (_snap_xe) carried on; false when the slice ran out first. Done, it joins
## its region's entries. Each extra copied as Array.duplicate(true) copies it (a Dictionary or Array deep, else as is).
func _snap_xe_step(t0: int, usec: int) -> bool:
	var src: Array = _snap_xe[1]
	var out: Array = _snap_xe[2]
	var j := out.size()
	while j < src.size():
		var j0 := j
		var end := mini(j + FLUSH_XE_BATCH, src.size())
		while j < end:
			var v: Variant = src[j]
			if v is Dictionary:
				out.append((v as Dictionary).duplicate(true))
			elif v is Array:
				out.append((v as Array).duplicate(true))
			else:
				out.append(v)
			j += 1
		snap_last[1] += end - j0
		if j < src.size() and Time.get_ticks_usec() - t0 > usec:
			return false
	var snap: Dictionary = _snap_xe[0]
	snap["xe"] = out
	(_snap_cur[3] as Array).append(snap)
	_snap_xe = []
	return true


## A sliced flush given up (a sync flush, a new save): its regions dirty again.
func _snap_abort() -> void:
	if not _snapping:
		return
	for snap: Array in _snap_out:
		_dirty[Vector2i(int(snap[1]), int(snap[2]))] = true
	if not _snap_cur.is_empty():
		_dirty[_snap_cur[0]] = true
	_snap_reset()


func _snap_reset() -> void:
	_snap_xe = []
	_snapping = false
	_snap_regions = []
	_snap_ri = 0
	_snap_cur = []
	_snap_out = []


func flush_async() -> void:
	if _write_task >= 0 or not is_configured():
		return
	var abs_dir := ProjectSettings.globalize_path(_surface_dir)
	var items: Array = []
	var snapshots: Array = []
	if async_encode and flush_sliced:
		if not _snapping:
			_snapping = true
			_snap_regions = _dirty.keys()
			_snap_ri = 0
			_snap_cur = []
			_snap_out = []
		var ts := Time.get_ticks_usec() if Probing.on else 0
		var done := _snap_step(FLUSH_SLICE_USEC)
		if ts > 0:
			Probing.add("dc_snap", ts)
		if not done:
			return
		snapshots = _snap_out
		_snap_reset()
	elif async_encode:
		var ts2 := Time.get_ticks_usec() if Probing.on else 0
		snapshots = _prepare_write_snapshots()
		if ts2 > 0:
			Probing.add("dc_snap", ts2)
	else:
		items = _prepare_write_items(false)
	var do_prune := _needs_prune or not items.is_empty() or not snapshots.is_empty()
	_needs_prune = false
	if items.is_empty() and snapshots.is_empty() and not do_prune:
		return
	var st := WriteResult.new()
	st.abs_dir = abs_dir
	st.proto_hash = _proto_hash
	st.items = items
	st.snapshots = snapshots
	st.prune = do_prune
	st.base_dir = ProjectSettings.globalize_path(_base_dir)
	st.max_bytes = max_bytes
	_write_state = st
	var task_fn := func() -> void:
		if not st.snapshots.is_empty() and not SafeDelete.is_link(st.abs_dir):
			if DirAccess.make_dir_recursive_absolute(st.abs_dir) == OK:
				for snap: Array in st.snapshots:
					var payload := _encode_region_entries(int(snap[1]), int(snap[2]), st.proto_hash, snap[3] as Array)
					if not payload.is_empty() and _write_region_file(str(snap[0]), payload):
						st.written += 1
		for item: Array in st.items:
			if _write_region_file(str(item[0]), item[1] as PackedByteArray):
				st.written += 1
		if st.prune and st.max_bytes > 0:
			prune_disk_dir(st.base_dir, st.max_bytes)
		if st.free_here:
			st.snapshots = []  # the copies let go here, not on the main thread (poll's _write_state = null)
			st.items = []
	st.free_here = flush_fine
	snapshots = []
	items = []
	_write_task = WorkerThreadPool.add_task(task_fn, false, "chunk_disk_write")


func flush_sync() -> int:
	wait_writes()
	_snap_abort()
	if not is_configured():
		return 0
	var items := _prepare_write_items(true)
	var written := 0
	for item: Array in items:
		if _write_region_file(str(item[0]), item[1] as PackedByteArray):
			written += 1
	if (_needs_prune or written > 0) and max_bytes > 0:
		_needs_prune = false
		prune_disk_dir(ProjectSettings.globalize_path(_base_dir), max_bytes)
	return written


func wait_reads() -> void:
	for r: Vector2i in _read_jobs.keys():
		var entry: Array = _read_jobs[r]
		WorkerThreadPool.wait_for_task_completion(int(entry[0]))
		_loaded[r] = true
	_read_jobs.clear()


func wait_writes() -> void:
	if _write_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_write_task)
		_write_task = -1
		_write_state = null


func wait_all() -> void:
	wait_reads()
	wait_writes()


func clear_disk() -> void:
	wait_all()
	_snap_reset()
	_regions.clear()
	_loaded.clear()
	_dirty.clear()
	if _base_dir == "":
		return
	var abs_base := ProjectSettings.globalize_path(_base_dir)
	if DirAccess.dir_exists_absolute(abs_base) and not SafeDelete.is_link(abs_base):
		SafeDelete.remove_tree(abs_base)


static func prune_disk_dir(abs_base: String, limit_bytes: int) -> int:
	if abs_base == "" or limit_bytes <= 0 or not DirAccess.dir_exists_absolute(abs_base) or SafeDelete.is_link(abs_base):
		return 0
	var entries: Array = []
	_collect_zchk_files(abs_base, entries)
	var total := 0
	for entry: Array in entries:
		total += int(entry[1])
	if total <= limit_bytes:
		return 0
	var cmp_age := func(a: Array, b: Array) -> bool:
		var ma := int(a[0])
		var mb := int(b[0])
		if ma != mb:
			return ma < mb
		return str(a[2]) < str(b[2])
	entries.sort_custom(cmp_age)
	var freed := 0
	var idx := 0
	while total > limit_bytes and idx < entries.size():
		var entry: Array = entries[idx]
		idx += 1
		var fsize := int(entry[1])
		var fpath := str(entry[2])
		if DirAccess.remove_absolute(fpath) == OK:
			freed += fsize
			total -= fsize
	return freed


static func _collect_zchk_files(abs_dir: String, out: Array) -> void:
	if SafeDelete.is_link(abs_dir):
		return
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		return
	for sub: String in DirAccess.get_directories_at(abs_dir):
		if dir.is_link(sub):
			continue
		_collect_zchk_files(abs_dir.path_join(sub), out)
	for fname: String in DirAccess.get_files_at(abs_dir):
		if not fname.ends_with(".zchk") or dir.is_link(fname):
			continue
		var fpath := abs_dir.path_join(fname)
		var f := FileAccess.open(fpath, FileAccess.READ)
		var fsize := f.get_length() if f != null else 0
		if f != null:
			f.close()
		var mtime := FileAccess.get_modified_time(fpath)
		out.append([mtime, fsize, fpath])


func _region_path(rx: int, ry: int) -> String:
	return _surface_dir.path_join("r_%d_%d.zchk" % [rx, ry])


static func _write_region_file(abs_path: String, payload: PackedByteArray) -> bool:
	var abs_tmp := abs_path + ".tmp.%d" % OS.get_process_id()
	var ok := false
	var f := FileAccess.open_compressed(abs_tmp, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if f != null:
		f.store_buffer(payload)
		ok = f.get_error() == OK
		f.close()
	if ok:
		var err := DirAccess.rename_absolute(abs_tmp, abs_path)
		if err != OK:
			if FileAccess.file_exists(abs_path) and not SafeDelete.is_link(abs_path):
				DirAccess.remove_absolute(abs_path)
				err = DirAccess.rename_absolute(abs_tmp, abs_path)
			if err != OK:
				ok = false
	if not ok:
		if FileAccess.file_exists(abs_tmp):
			DirAccess.remove_absolute(abs_tmp)
		var fd := FileAccess.open_compressed(abs_path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
		if fd != null:
			fd.store_buffer(payload)
			ok = fd.get_error() == OK
			fd.close()
	return ok


static func _read_region_file(abs_path: String, expected_rx: int, expected_ry: int, expected_hash: int) -> Dictionary:
	var raw := FileAccess.open(abs_path, FileAccess.READ)
	if raw == null:
		return {}
	var rlen := raw.get_length()
	var hdr := raw.get_buffer(16) if rlen >= 16 else PackedByteArray()
	raw.close()
	if rlen < 16 or hdr.slice(0, 4) != PackedByteArray([0x47, 0x43, 0x50, 0x46]):
		return {}
	var unc_len := hdr.decode_u32(12)
	if unc_len < HEADER_BYTES or unc_len > MAX_REGION_UNCOMPRESSED:
		return {}
	var f := FileAccess.open_compressed(abs_path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return {}
	var flen := f.get_length()
	if flen < HEADER_BYTES or flen > MAX_REGION_UNCOMPRESSED:
		f.close()
		return {}
	var bytes := f.get_buffer(flen)
	var ferr := f.get_error()
	f.close()
	if (ferr != OK and ferr != ERR_FILE_EOF) or bytes.size() != flen:
		return {}
	return _decode_region_bytes(bytes, expected_rx, expected_ry, expected_hash)


static func _decode_region_bytes(bytes: PackedByteArray, expected_rx: int, expected_ry: int, expected_hash: int) -> Dictionary:
	if bytes.size() < HEADER_BYTES:
		return {}
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	buf.data_array = bytes
	var magic_res: Array = buf.get_data(4)
	if int(magic_res[0]) != OK or magic_res[1] != MAGIC.to_ascii_buffer():
		return {}
	var ver := buf.get_u16()
	var rx := buf.get_32()
	var ry := buf.get_32()
	var phash := buf.get_64()
	var count := buf.get_u16()
	var _reserved := buf.get_u16()
	if ver != VERSION or rx != expected_rx or ry != expected_ry or phash != expected_hash or count > REGION * REGION:
		return {}
	var out := {}
	for _i in count:
		if buf.get_available_bytes() < 27:
			return {}
		var cx := buf.get_32()
		var cy := buf.get_32()
		var rv := buf.get_u32()
		var n := buf.get_u32()
		var saved := buf.get_u32()
		var tiles_count := buf.get_u16()
		var width := buf.get_u8()
		var ent_ints_count := buf.get_u32()
		var xi_count := buf.get_u32()
		var xt_len := buf.get_u32()
		if tiles_count != TILES_COUNT or (width != 4 and width != 8) or region_of(cx, cy) != Vector2i(expected_rx, expected_ry):
			return {}
		if ent_ints_count % WireDecode.ENT_STRIDE != 0:
			return {}
		var tiles_bytes := tiles_count * 4
		var ent_bytes := ent_ints_count * width
		var xi_bytes := xi_count * 4
		var need := tiles_bytes + ent_bytes + xi_bytes + xt_len
		if need < 0 or buf.get_available_bytes() < need:
			return {}
		var t_res: Array = buf.get_data(tiles_bytes)
		if int(t_res[0]) != OK:
			return {}
		var tiles := (t_res[1] as PackedByteArray).to_int32_array()
		var e: Variant
		if ent_bytes == 0:
			e = PackedInt32Array()
		else:
			var e_res: Array = buf.get_data(ent_bytes)
			if int(e_res[0]) != OK:
				return {}
			var e_raw: PackedByteArray = e_res[1]
			e = e_raw.to_int32_array() if width == 4 else e_raw.to_int64_array()
		var xi := PackedInt32Array()
		if xi_bytes > 0:
			var x_res: Array = buf.get_data(xi_bytes)
			if int(x_res[0]) != OK:
				return {}
			xi = (x_res[1] as PackedByteArray).to_int32_array()
		var xt := ""
		var xe: Array = []
		if xt_len > 0:
			var s_res: Array = buf.get_data(xt_len)
			if int(s_res[0]) != OK:
				return {}
			xt = (s_res[1] as PackedByteArray).get_string_from_utf8()
			var parsed: Variant = JSON.parse_string(xt)
			if not (parsed is Array) or (parsed as Array).size() != xi.size():
				return {}
			xe = parsed as Array
		elif not xi.is_empty():
			return {}
		out[Vector2i(cx, cy)] = {
			"cx": cx,
			"cy": cy,
			"rv": rv,
			"n": n,
			"saved": saved,
			"tiles": tiles,
			"e": e,
			"xi": xi,
			"xe": xe,
			"xt": xt,
		}
	return out


static func _encode_region_bytes(rx: int, ry: int, proto_hash: int, reg: Dictionary) -> PackedByteArray:
	return _encode_region_entries(rx, ry, proto_hash, reg.values())


static func _encode_region_entries(rx: int, ry: int, proto_hash: int, raw_entries: Array) -> PackedByteArray:
	var entries: Array = []
	for d_v: Variant in raw_entries:
		if not (d_v is Dictionary):
			continue
		var d := d_v as Dictionary
		var cx := int(d.get("cx", 0))
		var cy := int(d.get("cy", 0))
		var tiles: Variant = d.get("tiles")
		if not (tiles is PackedInt32Array) or (tiles as PackedInt32Array).size() != TILES_COUNT:
			continue
		if region_of(cx, cy) != Vector2i(rx, ry):
			continue
		entries.append(d)
	if entries.is_empty() or entries.size() > REGION * REGION:
		return PackedByteArray()
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	buf.put_data(MAGIC.to_ascii_buffer())
	buf.put_u16(VERSION)
	buf.put_32(rx)
	buf.put_32(ry)
	buf.put_64(proto_hash)
	buf.put_u16(entries.size())
	buf.put_u16(0)
	for d: Dictionary in entries:
		var tiles: PackedInt32Array = d["tiles"]
		var e: Variant = d.get("e", PackedInt32Array())
		var width := 8 if e is PackedInt64Array else 4
		var e_bytes := (e as PackedInt64Array).to_byte_array() if width == 8 else (e as PackedInt32Array).to_byte_array()
		var ent_ints: int = (e as PackedInt64Array).size() if width == 8 else (e as PackedInt32Array).size()
		var xi: PackedInt32Array = d.get("xi", PackedInt32Array())
		var xt_str := str(d.get("xt", ""))
		if xt_str == "":
			var xe_v: Variant = d.get("xe")
			if xe_v is Array and not (xe_v as Array).is_empty():
				xt_str = JSON.stringify(xe_v)
		var xt_bytes := xt_str.to_utf8_buffer()
		buf.put_32(int(d["cx"]))
		buf.put_32(int(d["cy"]))
		buf.put_u32(int(d["rv"]))
		buf.put_u32(int(d["n"]))
		buf.put_u32(int(d.get("saved", 0)))
		buf.put_u16(tiles.size())
		buf.put_u8(width)
		buf.put_u32(ent_ints)
		buf.put_u32(xi.size())
		buf.put_u32(xt_bytes.size())
		buf.put_data(tiles.to_byte_array())
		if not e_bytes.is_empty():
			buf.put_data(e_bytes)
		if not xi.is_empty():
			buf.put_data(xi.to_byte_array())
		if not xt_bytes.is_empty():
			buf.put_data(xt_bytes)
	return buf.data_array
