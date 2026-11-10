extends RefCounted
## Factorio's files by Factorio's own paths, for every mod of the game being played: the one place
## that turns "__name__/graphics/icons/x.png" (or "name/graphics/...", as res://data/icons.json
## writes them) into bytes. Wube's graphics and other mods' are read from the player's own files at
## runtime, never copied.
##
## - The built-in mods (core, base, space-age, quality, elevated-rails, recycler: every folder of
##   Factorio's `data` with an info.json) come from there (ItemIcons.factorio_data_dir()).
## - Every other mod from a mods folder: --factorio-mods=<folder>[;<folder>...], the server's
##   (Paths.server_data_dir()/mods, which the menu's servers use), the player's own
##   (%APPDATA%/Factorio/mods, ~/.factorio/mods, macOS' Application Support) and a portable
##   install's (<data>/../mods), in that order.
## - A mod is a folder (`name` or `name_version`) or a zip (`name_version.zip`, its files under
##   one top folder of any name). When the bridge said which version runs (set_mods(), from the
##   welcome) that version is picked; else the newest found.
##
## set_mods() finds the mods on a worker thread; prepare() finds them at once. Safe on worker threads
## once either has finished: each thread opens its own
## file handle per zip (one isn't safe to share). Zips are read through their own index (_zip_index).

const BUILT_IN := ["core", "base", "space-age", "quality", "elevated-rails", "recycler"]

static var extra_dirs: Array[String] = []
static var _mods := {}  # name -> version the game runs (the bridge's welcome); empty: unknown
static var _found := {}  # name -> {version, dir} or {version, zip, root, files}
static var _scanned := false
static var _data_dir := ""
static var _mutex := Mutex.new()
static var _readers := {}  # thread id -> {zip path: FileAccess}
## The scan set_mods() started on a worker thread (opening a big modpack's zips takes a few hundred
## milliseconds); -1 when none runs. Meanwhile only the built-in mods are found, and is_ready() is false.
static var _task := -1
## Goes up each time a scan finishes (users of the mods' files read them again).
static var generation := 0


static func configure_from_command_line() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--factorio-mods="):
			for dir in arg.get_slice("=", 1).split(";", false):
				extra_dirs.append(dir.replace("\\", "/"))


## The game's active mods and their versions (the welcome's `mods`), so the right copy of each is
## read when a mods folder holds several.
static func set_mods(mods: Dictionary) -> void:
	poll()
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_mutex.lock()
	var changed := mods.hash() != _mods.hash() or not _scanned
	_mods = mods.duplicate()
	if changed:
		_scanned = false
		_found = _built_in()
	_mutex.unlock()
	if changed:
		_task = WorkerThreadPool.add_task(_scan_locked)


## Whether every mod has been found (no scan running).
static func is_ready() -> bool:
	poll()
	return _task < 0 and _scanned


## Once a frame (mod_graphics.gd): finishes the scan's task once it is done.
static func poll() -> void:
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


static func active_mods() -> Dictionary:
	return _mods


## Finds the data folder and every mod, so reads on worker threads only look things up.
static func prepare() -> void:
	if _task >= 0:
		return  # set_mods()'s worker is at it: never wait for it here (the main thread would stall)
	_mutex.lock()
	if not _scanned:
		_scan()
	_mutex.unlock()


## The folders mods are looked for in, first first.
static func mods_dirs() -> Array[String]:
	var out: Array[String] = []
	out.append_array(extra_dirs)
	var paths = load("res://scripts/menu/paths.gd")
	out.append(paths.server_data_dir().path_join("mods"))
	var appdata := OS.get_environment("APPDATA")
	if appdata != "":
		out.append(appdata.replace("\\", "/").path_join("Factorio/mods"))
	var home := OS.get_environment("HOME")
	if home != "":
		out.append(home.path_join(".factorio/mods"))
		out.append(home.path_join("Library/Application Support/factorio/mods"))
	if _data_dir != "":
		out.append(_data_dir.path_join("../mods").simplify_path())
	var seen := {}
	var unique: Array[String] = []
	for dir in out:
		if not seen.has(dir) and DirAccess.dir_exists_absolute(dir):
			seen[dir] = true
			unique.append(dir)
	return unique


## "__base__/graphics/x.png" or "base/graphics/x.png" -> ["base", "graphics/x.png"]; ["", path]
## for anything else.
static func split(path: String) -> PackedStringArray:
	if path.begins_with("__"):
		var end := path.find("__/", 2)
		if end > 2:
			return PackedStringArray([path.substr(2, end - 2), path.substr(end + 3)])
	var slash := path.find("/")
	if slash > 0:
		return PackedStringArray([path.substr(0, slash), path.substr(slash + 1)])
	return PackedStringArray(["", path])


## Where a mod was found: {"version", "dir"} or {"version", "zip", "root", "files"}; {} if nowhere.
static func locate(mod: String) -> Dictionary:
	if _task >= 0 and not _scanned:
		return _found.get(mod, {})  # the built-in mods, while the rest are being found
	prepare()
	return _found.get(mod, {})


static func exists(path: String) -> bool:
	var parts := split(path)
	var at := locate(parts[0])
	if at.has("dir"):
		return FileAccess.file_exists(str(at.dir).path_join(parts[1]))
	if at.has("zip"):
		return (at.files as Dictionary).has(str(at.root) + parts[1])
	return false


## A file's bytes, or an empty array when it isn't there.
static func read(path: String) -> PackedByteArray:
	var parts := split(path)
	var at := locate(parts[0])
	if at.has("dir"):
		var file := str(at.dir).path_join(parts[1])
		return FileAccess.get_file_as_bytes(file) if FileAccess.file_exists(file) else PackedByteArray()
	if at.has("zip"):
		var inner := str(at.root) + parts[1]
		if not (at.files as Dictionary).has(inner):
			return PackedByteArray()
		return _zip_read(str(at.zip), (at.files as Dictionary)[inner])
	return PackedByteArray()


## A picture, or null. Files in folders load straight from disk.
static func load_image(path: String) -> Image:
	var parts := split(path)
	var at := locate(parts[0])
	if at.has("dir"):
		var file := str(at.dir).path_join(parts[1])
		if not FileAccess.file_exists(file):
			return null
		var image := Image.load_from_file(file)
		return image if image != null and not image.is_empty() else null
	var bytes := read(path)
	if bytes.is_empty():
		return null
	var out := Image.new()
	var ext := path.get_extension().to_lower()
	var err := out.load_jpg_from_buffer(bytes) if ext == "jpg" or ext == "jpeg" else out.load_png_from_buffer(bytes)
	return out if err == OK and not out.is_empty() else null


## The files directly in a mod's folder `dir` ("locale/en"), as full paths ("__mod__/locale/en/x.cfg").
static func files_in(mod: String, dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var at := locate(mod)
	if at.has("dir"):
		var full := str(at.dir).path_join(dir)
		if DirAccess.dir_exists_absolute(full):
			for f in DirAccess.get_files_at(full):
				out.append("__%s__/%s/%s" % [mod, dir, f])
	elif at.has("zip"):
		var prefix := str(at.root) + dir.trim_suffix("/") + "/"
		for f: String in (at.files as Dictionary):
			if f.begins_with(prefix) and not f.substr(prefix.length()).contains("/") and f.length() > prefix.length():
				out.append("__%s__/%s" % [mod, f.substr(str(at.root).length())])
	return out


static func _scan_locked() -> void:
	_mutex.lock()
	_scan()
	_mutex.unlock()


## Builds a new table and swaps it in, so a worker reading the old one meanwhile is unharmed. With
## the game's mods known, only zips named after one of them are opened (a player's mods folder can
## hold hundreds).
static func _scan() -> void:
	var found := _built_in()
	for mods_dir in mods_dirs():
		for name in DirAccess.get_directories_at(mods_dir):
			if _mods.is_empty() or _mods.has(name) or _mods.has(name.substr(0, name.rfind("_"))):
				_consider(found, _folder_mod(mods_dir.path_join(name)))
		for name in DirAccess.get_files_at(mods_dir):
			if name.get_extension().to_lower() != "zip":
				continue
			var stem := name.get_basename()
			var mod := stem.substr(0, stem.rfind("_"))
			if _mods.is_empty() or (_mods.has(mod) and (not found.has(mod) or str(_mods[mod]) == stem.substr(stem.rfind("_") + 1))):
				_consider(found, _zip_mod(mods_dir.path_join(name)))
	_found = found
	_scanned = true
	generation += 1


## Every mod folder of the install (one with an info.json, as 2.1's `recycler`, even if not listed).
static func _built_in() -> Dictionary:
	var found := {}
	_data_dir = load("res://scripts/world/item_icons.gd").factorio_data_dir()
	if _data_dir != "":
		for mod in DirAccess.get_directories_at(_data_dir):
			if mod in BUILT_IN or FileAccess.file_exists(_data_dir.path_join(mod).path_join("info.json")):
				found[mod] = {"name": mod, "version": "", "dir": _data_dir.path_join(mod), "built_in": true}
	return found


## Keeps a mod found unless one already kept is a better match: the version the game runs, else
## the first folder's, else the newest.
static func _consider(found: Dictionary, entry: Dictionary) -> void:
	if entry.is_empty():
		return
	var name := str(entry.name)
	if found.has(name) and (found[name] as Dictionary).has("built_in"):
		return
	var want := str(_mods.get(name, ""))
	var have: Dictionary = found.get(name, {})
	if have.is_empty():
		found[name] = entry
		return
	if want != "":
		if str(have.version) != want and str(entry.version) == want:
			found[name] = entry
		return
	if _newer(str(entry.version), str(have.version)):
		found[name] = entry


static func _newer(a: String, b: String) -> bool:
	var pa := a.split(".")
	var pb := b.split(".")
	for i in maxi(pa.size(), pb.size()):
		var x := int(pa[i]) if i < pa.size() else 0
		var y := int(pb[i]) if i < pb.size() else 0
		if x != y:
			return x > y
	return false


static func _folder_mod(dir: String) -> Dictionary:
	var info_path := dir.path_join("info.json")
	if not FileAccess.file_exists(info_path):
		return {}
	var info = JSON.parse_string(FileAccess.get_file_as_string(info_path))
	if not info is Dictionary or not info.has("name"):
		return {}
	return {"name": str(info.name), "version": str(info.get("version", "")), "dir": dir}


static func _zip_mod(path: String) -> Dictionary:
	var files := _zip_index(path)
	var root := ""
	for f: String in files:
		if f.ends_with("info.json") and f.count("/") <= 1 and (root == "" or f.length() < root.length() + 9):
			root = f.substr(0, f.length() - "info.json".length())
	if not files.has(root + "info.json"):
		return {}
	var info = JSON.parse_string(_zip_read(path, files[root + "info.json"]).get_string_from_utf8())
	if not info is Dictionary or not info.has("name"):
		return {}
	return {"name": str(info.name), "version": str(info.get("version", "")), "zip": path, "root": root, "files": files}


## A zip's central directory: name -> [method, crc32, compressed size, size, local header offset].
## Read once: ZIPReader looks a name up by walking every entry, 2.5 ms a file in Space
## Exploration's graphics zips (thousands of files), where this index and a seek take 0.1.
static func _zip_index(path: String) -> Dictionary:
	var out := {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var length := f.get_length()
	var tail_len := mini(length, 65557)
	f.seek(length - tail_len)
	var tail := f.get_buffer(tail_len)
	var eocd := -1
	for i in range(tail_len - 22, -1, -1):
		if tail.decode_u32(i) == 0x06054b50:
			eocd = i
			break
	if eocd < 0:
		return out
	var count := tail.decode_u16(eocd + 10)
	var cd_size := tail.decode_u32(eocd + 12)
	var cd_at := tail.decode_u32(eocd + 16)
	if cd_at + cd_size > length:
		return out
	f.seek(cd_at)
	var cd := f.get_buffer(cd_size)
	var at := 0
	for _i in count:
		if at + 46 > cd.size() or cd.decode_u32(at) != 0x02014b50:
			break
		var name_len := cd.decode_u16(at + 28)
		var skip := name_len + cd.decode_u16(at + 30) + cd.decode_u16(at + 32)
		var name := cd.slice(at + 46, at + 46 + name_len).get_string_from_utf8()
		out[name] = PackedInt64Array([cd.decode_u16(at + 10), cd.decode_u32(at + 16), cd.decode_u32(at + 20),
			cd.decode_u32(at + 24), cd.decode_u32(at + 42)])
		at += 46 + skip
	return out


## One entry's bytes: stored, or deflated (inflated through Godot's gzip reader, the zip's raw
## deflate data wrapped in a gzip header and its CRC and size from the directory).
static func _zip_read(path: String, entry: PackedInt64Array) -> PackedByteArray:
	var f := _file(path)
	if f == null:
		return PackedByteArray()
	f.seek(entry[4])
	var head := f.get_buffer(30)
	if head.size() < 30 or head.decode_u32(0) != 0x04034b50:
		return PackedByteArray()
	f.seek(entry[4] + 30 + head.decode_u16(26) + head.decode_u16(28))
	var data := f.get_buffer(entry[2])
	if entry[0] == 0:
		return data
	if entry[0] != 8:
		return PackedByteArray()
	var gz := PackedByteArray([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff])
	gz.append_array(data)
	var trailer := PackedByteArray()
	trailer.resize(8)
	trailer.encode_u32(0, entry[1])
	trailer.encode_u32(4, entry[3] & 0xffffffff)
	gz.append_array(trailer)
	return gz.decompress(entry[3], FileAccess.COMPRESSION_GZIP)


## This thread's open file for a zip (a FileAccess isn't safe to share between threads).
static func _file(path: String) -> FileAccess:
	var id := OS.get_thread_caller_id()
	_mutex.lock()
	var mine: Dictionary = _readers.get(id, {})
	_readers[id] = mine
	_mutex.unlock()
	var f: FileAccess = mine.get(path)
	if f == null:
		f = FileAccess.open(path, FileAccess.READ)
		if f == null:
			return null
		mine[path] = f
	return f


## Closes every thread's zips. Only with nothing reading (tests): a worker's open file closed under
## it would fail mid-read.
static func close_all() -> void:
	_mutex.lock()
	for mine: Dictionary in _readers.values():
		for f: FileAccess in mine.values():
			f.close()
	_readers.clear()
	_mutex.unlock()
