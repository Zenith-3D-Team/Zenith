extends RefCounted
## Distant Horizon 16x16-chunk region memory + Zstd-compressed disk cache (`ZLOD` format).
## Keyed by sanitized save_id, surface_index, and palette proto_hash so stale/mod-mismatched
## caches invalidate cleanly without losing newer or finer-resolution chunks.

const LodData := preload("res://scripts/world/lod_data.gd")
const SafeDelete := preload("res://scripts/safe_delete.gd")
const Switches := preload("res://scripts/switches.gd")

const REGION := 16
const MAGIC := "ZLOD"
const VERSION := 1

const _HEADER_BYTES := 32
const _CHUNK_HEADER_BYTES := 21
const _MAX_REGION_BYTES := 4 * 1024 * 1024
const MAX_READ_JOBS := 4

## --dh-async-io=off: fall back to synchronous main-thread region loads and flush encoding.
static var async_io := Switches.on("--dh-async-io")

var _base_dir := "user://lod-cache"
var _save_id := "default"
var _surface_index := 0
var _proto_hash := 0
var _surface_dir := ""

var _regions := {}  # Vector2i(rx, ry) -> {Vector2i(cx, cy): LodData.LodChunk}
var _region_revs := {}  # Vector2i(rx, ry) -> int
var _min_region_rev := {}  # Vector2i(rx, ry) -> int (from invalidate_region)
var _dirty := {}  # Vector2i(rx, ry) -> true
var _loaded := {}  # Vector2i(rx, ry) -> true
var _read_jobs := {}  # Vector2i(rx, ry) -> [task_id, ReadJob]
var _write_task := -1
var _write_pending: WriteJob = null


class ReadJob:
	var rx := 0
	var ry := 0
	var proto_hash := 0
	var abs_path := ""
	var file_rev := -1
	var chunks := {}
	var valid := false

	func run() -> void:
		var parsed := read_region_file(abs_path, rx, ry, proto_hash)
		if not parsed.is_empty():
			file_rev = int(parsed[0])
			chunks = parsed[1]
			valid = true

	static func open_compressed_read(abs_path_in: String) -> FileAccess:
		var raw := FileAccess.open(abs_path_in, FileAccess.READ)
		if raw == null:
			return null
		var rlen := raw.get_length()
		var hdr := raw.get_buffer(16) if rlen >= 16 else PackedByteArray()
		raw.close()
		if rlen < 16 or hdr.slice(0, 4) != PackedByteArray([0x47, 0x43, 0x50, 0x46]):
			return null
		var unc_len := hdr.decode_u32(12)
		if unc_len < _HEADER_BYTES or unc_len > _MAX_REGION_BYTES:
			return null
		return FileAccess.open_compressed(abs_path_in, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)

	static func read_region_file(abs_path_in: String, expected_rx: int, expected_ry: int, expected_hash: int) -> Array:
		if abs_path_in == "" or not FileAccess.file_exists(abs_path_in) or SafeDelete.is_link(abs_path_in):
			return []
		var f := open_compressed_read(abs_path_in)
		if f == null:
			return []
		var flen := f.get_length()
		if flen < _HEADER_BYTES or flen > _MAX_REGION_BYTES:
			f.close()
			return []
		var bytes := f.get_buffer(flen)
		var ferr := f.get_error()
		f.close()
		if (ferr != OK and ferr != ERR_FILE_EOF) or bytes.size() != flen:
			return []
		return decode_region_bytes_with_hash(bytes, expected_rx, expected_ry, expected_hash)

	static func read_header_with_hash(bytes: PackedByteArray, expected_rx: int, expected_ry: int, expected_hash: int) -> Array:
		if bytes.size() < _HEADER_BYTES:
			return []
		var buf := StreamPeerBuffer.new()
		buf.big_endian = false
		buf.data_array = bytes
		var magic_res: Array = buf.get_data(4)
		if int(magic_res[0]) != OK or magic_res[1] != MAGIC.to_ascii_buffer():
			return []
		var ver := buf.get_u16()
		var rx_in := buf.get_32()
		var ry_in := buf.get_32()
		var phash := buf.get_64()
		var rrev := buf.get_64()
		var count := buf.get_u16()
		if ver != VERSION or rx_in != expected_rx or ry_in != expected_ry:
			return []
		if phash != expected_hash or count > REGION * REGION:
			return []
		return [rrev, count]

	static func decode_region_bytes_with_hash(bytes: PackedByteArray, expected_rx: int, expected_ry: int, expected_hash: int) -> Array:
		var hdr := read_header_with_hash(bytes, expected_rx, expected_ry, expected_hash)
		if hdr.is_empty():
			return []
		var rrev := int(hdr[0])
		var count := int(hdr[1])
		var buf := StreamPeerBuffer.new()
		buf.big_endian = false
		buf.data_array = bytes
		buf.seek(_HEADER_BYTES)

		var out_chunks := {}
		for _i in count:
			if buf.get_available_bytes() < _CHUNK_HEADER_BYTES:
				return []
			var cx := buf.get_32()
			var cy := buf.get_32()
			var res := buf.get_u8()
			var crev := buf.get_64()
			var tl_len := buf.get_u16()
			var el_len := buf.get_u16()
			var reg_coord := Vector2i(floori(float(cx) / float(REGION)), floori(float(cy) / float(REGION)))
			if not LodData.valid_res(res) or reg_coord != Vector2i(expected_rx, expected_ry):
				return []
			var n := LodData.CHUNK / res
			var total := n * n
			if tl_len == 0 or tl_len > total * 2 or el_len == 0 or el_len > total * 3:
				return []
			if buf.get_available_bytes() < (tl_len + el_len) * 4:
				return []
			var tl: Array = []
			tl.resize(tl_len)
			for k in tl_len:
				tl[k] = buf.get_32()
			var el: Array = []
			el.resize(el_len)
			for k in el_len:
				el[k] = buf.get_32()
			var chunk := LodData.LodChunk.from_msg({
				"cx": cx, "cy": cy, "res": res, "rv": crev, "tl": tl, "el": el,
			})
			if chunk == null:
				return []
			out_chunks[Vector2i(cx, cy)] = chunk
		return [rrev, out_chunks]


class WriteJob:
	var abs_dir := ""
	var proto_hash := 0
	var items: Array = []  # [[abs_path, PackedByteArray]]
	var snapshots: Array = []  # [[abs_path, rx, ry, rrev, Array[LodChunk]]]
	var written := 0

	func run() -> void:
		if DirAccess.make_dir_recursive_absolute(abs_dir) != OK:
			return
		for item: Array in items:
			if write_file(str(item[0]), item[1] as PackedByteArray):
				written += 1
		for snap: Array in snapshots:
			var payload := encode_region_chunks(int(snap[1]), int(snap[2]), proto_hash, int(snap[3]), snap[4] as Array)
			if not payload.is_empty() and write_file(str(snap[0]), payload):
				written += 1

	static func encode_region_chunks(rx: int, ry: int, p_hash: int, rrev: int, raw_chunks: Array) -> PackedByteArray:
		var valid_chunks: Array[LodData.LodChunk] = []
		for c_v: Variant in raw_chunks:
			if c_v is LodData.LodChunk:
				var c := c_v as LodData.LodChunk
				var reg_coord := Vector2i(floori(float(c.cx) / float(REGION)), floori(float(c.cy) / float(REGION)))
				if LodData.valid_res(c.res) and reg_coord == Vector2i(rx, ry):
					valid_chunks.append(c)
		if valid_chunks.size() > REGION * REGION:
			return PackedByteArray()

		var buf := StreamPeerBuffer.new()
		buf.big_endian = false
		buf.put_data(MAGIC.to_ascii_buffer())
		buf.put_u16(VERSION)
		buf.put_32(rx)
		buf.put_32(ry)
		buf.put_64(p_hash)
		buf.put_64(rrev)
		buf.put_u16(valid_chunks.size())

		for c in valid_chunks:
			var tl := c.encode_tile_rle()
			var el := c.encode_ent_rle()
			buf.put_32(c.cx)
			buf.put_32(c.cy)
			buf.put_u8(c.res)
			buf.put_64(c.rev)
			buf.put_u16(tl.size())
			buf.put_u16(el.size())
			for v in tl:
				buf.put_32(v)
			for v in el:
				buf.put_32(v)
		return buf.data_array

	static func write_file(abs_path: String, payload: PackedByteArray) -> bool:
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
	return out if out != "" else "default"


func configure(save_id: String, surface_index: int, proto_hash: int, base_dir := "user://lod-cache") -> void:
	wait_write()
	_base_dir = base_dir
	_save_id = _sanitize_save_id(save_id)
	_surface_index = surface_index
	_proto_hash = proto_hash
	_surface_dir = _base_dir.path_join(_save_id).path_join("s%d" % _surface_index)
	clear_memory()


func clear_memory() -> void:
	_discard_reads()
	wait_write()
	_regions.clear()
	_region_revs.clear()
	_min_region_rev.clear()
	_dirty.clear()
	_loaded.clear()


func is_region_loaded(rx: int, ry: int) -> bool:
	return bool(_loaded.get(Vector2i(rx, ry), false))


func request_region(rx: int, ry: int) -> void:
	var r := Vector2i(rx, ry)
	if _loaded.get(r, false) or _read_jobs.has(r):
		return
	if _surface_dir == "":
		_loaded[r] = true
		return
	if _read_jobs.size() >= MAX_READ_JOBS:
		return
	var abs_path := ProjectSettings.globalize_path(_region_path(rx, ry))
	if not FileAccess.file_exists(abs_path) or SafeDelete.is_link(abs_path):
		_loaded[r] = true
		return
	var job := ReadJob.new()
	job.rx = rx
	job.ry = ry
	job.proto_hash = _proto_hash
	job.abs_path = abs_path
	var tid := WorkerThreadPool.add_task(Callable(job, "run"), false, "lod_cache_read")
	_read_jobs[r] = [tid, job]


func poll_reads() -> Array[Vector2i]:
	var ready: Array[Vector2i] = []
	for r: Vector2i in _read_jobs.keys():
		var entry: Array = _read_jobs[r]
		var tid := int(entry[0])
		if not WorkerThreadPool.is_task_completed(tid):
			continue
		WorkerThreadPool.wait_for_task_completion(tid)
		_read_jobs.erase(r)
		if _apply_read_job(r, entry[1] as ReadJob):
			ready.append(r)
	return ready


func wait_reads() -> void:
	for r: Vector2i in _read_jobs.keys():
		var entry: Array = _read_jobs[r]
		WorkerThreadPool.wait_for_task_completion(int(entry[0]))
		_apply_read_job(r, entry[1] as ReadJob)
	_read_jobs.clear()


func _discard_reads() -> void:
	for r: Vector2i in _read_jobs.keys():
		var entry: Array = _read_jobs[r]
		WorkerThreadPool.wait_for_task_completion(int(entry[0]))
	_read_jobs.clear()


func _apply_read_job(r: Vector2i, job: ReadJob) -> bool:
	_loaded[r] = true
	if job == null or not job.valid:
		return false
	if _min_region_rev.has(r) and job.file_rev < int(_min_region_rev[r]):
		return false
	var cur_rev := int(_region_revs.get(r, -1))
	if not _region_revs.has(r) or job.file_rev > cur_rev:
		_region_revs[r] = job.file_rev
	var reg: Dictionary = _regions.get(r, {})
	if not _regions.has(r):
		_regions[r] = reg
	for key: Vector2i in job.chunks:
		var disk_c: LodData.LodChunk = job.chunks[key]
		var mem_c: LodData.LodChunk = reg.get(key)
		if mem_c == null or disk_c.rev > mem_c.rev or (disk_c.rev == mem_c.rev and disk_c.res < mem_c.res):
			reg[key] = disk_c
	return not job.chunks.is_empty()


func get_chunk(cx: int, cy: int) -> LodData.LodChunk:
	var r := region_of(cx, cy)
	if not _loaded.get(r, false):
		if async_io:
			request_region(r.x, r.y)
		else:
			load_region_sync(r.x, r.y)
	var reg: Dictionary = _regions.get(r, {})
	return reg.get(Vector2i(cx, cy))


func put_chunk(chunk: LodData.LodChunk, region_rev := -1) -> void:
	if chunk == null or not LodData.valid_res(chunk.res):
		return
	var r := region_of(chunk.cx, chunk.cy)
	if region_rev >= 0 and _min_region_rev.has(r) and region_rev < int(_min_region_rev[r]):
		return
	if not _loaded.get(r, false):
		if async_io:
			request_region(r.x, r.y)
		else:
			load_region_sync(r.x, r.y)
	var reg: Dictionary = _regions.get(r, {})
	if not _regions.has(r):
		_regions[r] = reg

	var cur_rrev := int(_region_revs.get(r, -1))
	var rrev_advanced := region_rev >= 0 and region_rev > cur_rrev
	if region_rev >= 0 and (not _region_revs.has(r) or region_rev > cur_rrev):
		_region_revs[r] = region_rev

	var key := Vector2i(chunk.cx, chunk.cy)
	var cur: LodData.LodChunk = reg.get(key)
	var replace := cur == null or rrev_advanced or chunk.rev > cur.rev
	if not replace and chunk.rev == cur.rev:
		replace = chunk.res <= cur.res
	if replace:
		reg[key] = chunk
		_dirty[r] = true
	elif rrev_advanced:
		_dirty[r] = true


func region_revs() -> Dictionary:
	wait_reads()
	wait_write()
	var out := {}
	if _surface_dir == "":
		return out
	var abs_dir := ProjectSettings.globalize_path(_surface_dir)
	if not DirAccess.dir_exists_absolute(abs_dir) or SafeDelete.is_link(abs_dir):
		return out
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		return out
	for fname: String in DirAccess.get_files_at(abs_dir):
		if not (fname.begins_with("r_") and fname.ends_with(".zlod")) or dir.is_link(fname):
			continue
		var coords := _parse_region_filename(fname)
		if coords.is_empty():
			continue
		var rx := int(coords[0])
		var ry := int(coords[1])
		var fpath := abs_dir.path_join(fname)
		var f := _open_compressed_read(fpath)
		if f == null:
			continue
		var hdr := f.get_buffer(_HEADER_BYTES)
		f.close()
		if hdr.size() < _HEADER_BYTES:
			continue
		var parsed := _read_header(hdr, rx, ry)
		if not parsed.is_empty():
			out[Vector2i(rx, ry)] = int(parsed[0])
	return out


func invalidate_region(rx: int, ry: int, new_rev: int) -> void:
	wait_write()
	var r := Vector2i(rx, ry)
	if _read_jobs.has(r):
		var r_entry: Array = _read_jobs[r]
		WorkerThreadPool.wait_for_task_completion(int(r_entry[0]))
		_read_jobs.erase(r)
	_regions.erase(r)
	_dirty.erase(r)
	_loaded[r] = true
	_region_revs[r] = new_rev
	_min_region_rev[r] = new_rev
	if _surface_dir == "":
		return
	var abs_path := ProjectSettings.globalize_path(_region_path(rx, ry))
	if FileAccess.file_exists(abs_path) and not SafeDelete.is_link(abs_path):
		DirAccess.remove_absolute(abs_path)


func load_region_sync(rx: int, ry: int) -> Dictionary:
	var r := Vector2i(rx, ry)
	if _read_jobs.has(r):
		var r_entry: Array = _read_jobs[r]
		WorkerThreadPool.wait_for_task_completion(int(r_entry[0]))
		_read_jobs.erase(r)
		var r_job := r_entry[1] as ReadJob
		_apply_read_job(r, r_job)
		return r_job.chunks if r_job != null and r_job.valid else {}
	_loaded[r] = true
	if _surface_dir == "":
		return {}
	var abs_path := ProjectSettings.globalize_path(_region_path(rx, ry))
	var parsed := _read_region_file(abs_path, rx, ry, _proto_hash)
	if parsed.is_empty():
		return {}
	var file_rev := int(parsed[0])
	var chunks: Dictionary = parsed[1]
	var cur_rev := int(_region_revs.get(r, -1))
	if not _region_revs.has(r) or file_rev > cur_rev:
		_region_revs[r] = file_rev
	var reg: Dictionary = _regions.get(r, {})
	if not _regions.has(r):
		_regions[r] = reg
	for key: Vector2i in chunks:
		var disk_c: LodData.LodChunk = chunks[key]
		var mem_c: LodData.LodChunk = reg.get(key)
		if mem_c == null or disk_c.rev > mem_c.rev or (disk_c.rev == mem_c.rev and disk_c.res < mem_c.res):
			reg[key] = disk_c
	return chunks


func poll_write() -> void:
	if _write_task >= 0 and WorkerThreadPool.is_task_completed(_write_task):
		WorkerThreadPool.wait_for_task_completion(_write_task)
		_write_task = -1
		_write_pending = null


func wait_write() -> void:
	if _write_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_write_task)
		_write_task = -1
		_write_pending = null


func flush_dirty_async() -> void:
	if _write_task >= 0:
		poll_write()
	if _write_task >= 0 or _surface_dir == "" or _dirty.is_empty():
		return
	var abs_dir := ProjectSettings.globalize_path(_surface_dir)
	if SafeDelete.is_link(abs_dir):
		return
	var items: Array = []
	var snapshots: Array = []
	for r: Vector2i in _dirty.keys():
		if async_io and not _loaded.get(r, false):
			request_region(r.x, r.y)
			continue
		var reg: Dictionary = _regions.get(r, {})
		var rrev := int(_region_revs.get(r, 0))
		var abs_path := ProjectSettings.globalize_path(_region_path(r.x, r.y))
		if SafeDelete.is_link(abs_path):
			_dirty.erase(r)
			continue
		if async_io:
			var valid_chunks: Array = []
			for c_v: Variant in reg.values():
				if c_v is LodData.LodChunk:
					var c := c_v as LodData.LodChunk
					if LodData.valid_res(c.res) and region_of(c.cx, c.cy) == r:
						valid_chunks.append(c)
			_dirty.erase(r)
			if not valid_chunks.is_empty():
				snapshots.append([abs_path, r.x, r.y, rrev, valid_chunks])
		else:
			var payload := _encode_region_bytes(r.x, r.y, rrev, reg)
			if payload.is_empty():
				continue
			items.append([abs_path, payload])
			_dirty.erase(r)
	if items.is_empty() and snapshots.is_empty():
		return
	var job := WriteJob.new()
	job.abs_dir = abs_dir
	job.proto_hash = _proto_hash
	job.items = items
	job.snapshots = snapshots
	_write_pending = job
	_write_task = WorkerThreadPool.add_task(Callable(job, "run"), false, "lod_cache_write")


func flush_dirty() -> int:
	wait_reads()
	wait_write()
	if _surface_dir == "" or _dirty.is_empty():
		return 0
	var abs_dir := ProjectSettings.globalize_path(_surface_dir)
	if SafeDelete.is_link(abs_dir) or DirAccess.make_dir_recursive_absolute(abs_dir) != OK:
		return 0
	var written := 0
	for r: Vector2i in _dirty.keys():
		if not _loaded.get(r, false):
			load_region_sync(r.x, r.y)
		var reg: Dictionary = _regions.get(r, {})
		var rrev := int(_region_revs.get(r, 0))
		var payload := _encode_region_bytes(r.x, r.y, rrev, reg)
		if payload.is_empty():
			continue
		var abs_path := ProjectSettings.globalize_path(_region_path(r.x, r.y))
		if SafeDelete.is_link(abs_path):
			continue
		if WriteJob.write_file(abs_path, payload):
			_dirty.erase(r)
			written += 1
	return written


func prune_disk(max_bytes := 268435456) -> int:
	wait_reads()
	wait_write()
	var abs_base := ProjectSettings.globalize_path(_base_dir)
	if _base_dir == "" or not DirAccess.dir_exists_absolute(abs_base) or SafeDelete.is_link(abs_base):
		return 0
	var entries: Array = []
	var total := 0
	_collect_zlod_files(abs_base, entries)
	for entry: Array in entries:
		total += int(entry[1])
	if total <= max_bytes:
		return 0
	var by_age := func(a: Array, b: Array) -> bool:
		var ma := int(a[0])
		var mb := int(b[0])
		if ma != mb:
			return ma < mb
		return str(a[2]) < str(b[2])
	entries.sort_custom(by_age)
	var freed := 0
	var idx := 0
	while total > max_bytes and idx < entries.size():
		var entry: Array = entries[idx]
		idx += 1
		var fsize := int(entry[1])
		var fpath := str(entry[2])
		if DirAccess.remove_absolute(fpath) == OK:
			freed += fsize
			total -= fsize
			if _surface_dir != "":
				var abs_sdir := ProjectSettings.globalize_path(_surface_dir).replace("\\", "/")
				var norm_path := fpath.replace("\\", "/")
				if norm_path.get_base_dir() == abs_sdir:
					var coords := _parse_region_filename(norm_path.get_file())
					if not coords.is_empty():
						_loaded.erase(Vector2i(int(coords[0]), int(coords[1])))
	return freed


static func _collect_zlod_files(abs_dir: String, out: Array) -> void:
	if SafeDelete.is_link(abs_dir):
		return
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		return
	for sub: String in DirAccess.get_directories_at(abs_dir):
		if dir.is_link(sub):
			continue
		_collect_zlod_files(abs_dir.path_join(sub), out)
	for fname: String in DirAccess.get_files_at(abs_dir):
		if not fname.ends_with(".zlod") or dir.is_link(fname):
			continue
		var fpath := abs_dir.path_join(fname)
		var f := FileAccess.open(fpath, FileAccess.READ)
		var fsize := f.get_length() if f != null else 0
		if f != null:
			f.close()
		var mtime := FileAccess.get_modified_time(fpath)
		out.append([mtime, fsize, fpath])


func _region_path(rx: int, ry: int) -> String:
	return _surface_dir.path_join("r_%d_%d.zlod" % [rx, ry])


static func _parse_region_filename(fname: String) -> Array:
	if not (fname.begins_with("r_") and fname.ends_with(".zlod")):
		return []
	var stem := fname.substr(2, fname.length() - 7)
	var parts := stem.split("_")
	if parts.size() != 2:
		return []
	if not (parts[0].is_valid_int() and parts[1].is_valid_int()):
		return []
	return [int(parts[0]), int(parts[1])]


static func _open_compressed_read(abs_path: String) -> FileAccess:
	return ReadJob.open_compressed_read(abs_path)


static func _read_region_file(abs_path: String, expected_rx: int, expected_ry: int, expected_hash: int) -> Array:
	return ReadJob.read_region_file(abs_path, expected_rx, expected_ry, expected_hash)


func _read_header(bytes: PackedByteArray, expected_rx: int, expected_ry: int) -> Array:
	return _read_header_with_hash(bytes, expected_rx, expected_ry, _proto_hash)


static func _read_header_with_hash(bytes: PackedByteArray, expected_rx: int, expected_ry: int, expected_hash: int) -> Array:
	return ReadJob.read_header_with_hash(bytes, expected_rx, expected_ry, expected_hash)


func _decode_region_bytes(bytes: PackedByteArray, expected_rx: int, expected_ry: int) -> Array:
	return _decode_region_bytes_with_hash(bytes, expected_rx, expected_ry, _proto_hash)


static func _decode_region_bytes_with_hash(bytes: PackedByteArray, expected_rx: int, expected_ry: int, expected_hash: int) -> Array:
	return ReadJob.decode_region_bytes_with_hash(bytes, expected_rx, expected_ry, expected_hash)


func _encode_region_bytes(rx: int, ry: int, rrev: int, reg: Dictionary) -> PackedByteArray:
	return _encode_region_chunks(rx, ry, _proto_hash, rrev, reg.values())


static func _encode_region_chunks(rx: int, ry: int, proto_hash: int, rrev: int, raw_chunks: Array) -> PackedByteArray:
	return WriteJob.encode_region_chunks(rx, ry, proto_hash, rrev, raw_chunks)
