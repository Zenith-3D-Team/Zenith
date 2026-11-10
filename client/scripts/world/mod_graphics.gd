extends RefCounted
## The bridge's graphics list (docs/MOD-GRAPHICS-PLAN.md): which file is each prototype's icon,
## tile picture, decorative picture and building picture, for every mod of the game being played,
## read from the running game's data stage (mod/.../scripts/gfx_extract.lua) and drawn from the
## mods' own files (mod_files.gd).
##
## The welcome names the list's fingerprint (`gf`) and parts (`gn`). A copy is kept per fingerprint
## in user://mod-graphics/<gf>.json, so a second game with the same mods sends nothing; without
## one the client asks (`gfx` {fp}), keeps the parts as they come and, every RETRY_MSEC with parts
## still missing, asks for those again (`need`): the parts are sent unreliably. An old bridge sends
## no `gf`, and then item_icons.gd, terrain_textures.gd and decoratives.gd use their own indexes.
##
## Readers (icons, tiles, decoratives on worker threads) only ever see a whole table: apply()
## swaps the new ones in on the main thread.

const ModFiles := preload("res://scripts/world/mod_files.gd")

const CACHE_DIR := "user://mod-graphics"
const RETRY_MSEC := 2500
## How many caches to keep (oldest dropped): one per modpack played.
const KEEP := 12

static var icons := {}  # kind -> name -> layers ([file, size, tint, scale, shift], as icons.json)
static var tiles := {}  # name -> tile record (gfx_extract.lua)
static var decor := {}  # name -> decoratives.json-style record
## name -> {"n"|"e"|"s"|"w": [[file, x, y, w, h, scale, sx, sy, tint, anim?], ...], and "kn".."kw":
## what a machine adds while working} (gfx_extract.lua entity_pictures)
static var ents := {}
## name -> [[file, x, y, w, h, scale, sx, sy], ...]: `sprite` prototypes (mods' GUI pictures), bottom first
static var sprites := {}
static var _sprite_textures := {}  # name -> Texture2D (or null when it can't be read), this list's
static var _sheets := {}  # file -> Image read for sprites
## Goes up whenever a new list is applied (users drop what they made from the old one).
static var generation := 0
## The list in use: its fingerprint, "" for none.
static var fingerprint := ""
## Functions called (on the main thread) after a list is applied or dropped.
static var listeners: Array[Callable] = []

static var _want := ""  # fingerprint being fetched
static var _parts := {}  # part number -> d
static var _total := 0
static var _asked_msec := 0
static var _started_msec := 0
static var _send: Callable
static var _load_task := -1
static var _loaded = null  # what the cache read on a worker thread found
static var _loaded_mutex := Mutex.new()
static var _ready_list = null  # [fp, merged] whole, waiting for mod_files.gd to find the mods


## The welcome: the game's mods, and the list to use. `send` sends a command to the bridge.
static func on_welcome(msg: Dictionary, send: Callable) -> void:
	var mods = msg.get("mods")
	ModFiles.set_mods(mods if mods is Dictionary else {})
	_send = send
	var fp := str(msg.get("gf", ""))
	var n := int(msg.get("gn", 0))
	if fp == "" or n <= 0:
		_want = ""
		if fingerprint != "":
			clear()  # a game without a list: the last game's isn't this one's
			_tell()
		return
	if fp == fingerprint or fp == _want:
		# The same list again (every handshake starts with a welcome: a full resync, a lost one):
		# kept if in use or being read from the cache; asked for again only while still arriving.
		if fp != fingerprint and _load_task < 0:
			_ask(true)
		return
	_want = fp
	_total = n
	_parts = {}
	_started_msec = Time.get_ticks_msec()
	_asked_msec = 0
	var path := _cache_path(fp)
	if FileAccess.file_exists(path):
		# Read and parsed on a worker thread (a big modpack's list is megabytes).
		_load_task = WorkerThreadPool.add_task(_read_cache.bind(path, fp))
	else:
		_ask(true)


## A `gfx` part.
static func on_part(msg: Dictionary) -> void:
	if str(msg.get("fp", "")) != _want or _want == "":
		return
	var part := int(msg.get("part", 0))
	var d = msg.get("d")
	if part < 1 or part > _total or not d is Dictionary or _want == fingerprint or _parts.has(part):
		return  # in use already, or a part sent twice
	_parts[part] = d
	if _parts.size() == _total:
		var merged := _merge(_parts.values())
		print("Mod graphics: graphics list from the bridge: %d parts in %d ms" % [_total, Time.get_ticks_msec() - _started_msec])
		_save(_want, merged)
		_apply_soon(_want, merged)


## Once a frame: asks again for missing parts, and applies a cache read meanwhile.
static func poll() -> void:
	ModFiles.poll()
	if _ready_list != null and ModFiles.is_ready():
		var l: Array = _ready_list
		_ready_list = null
		if l[0] == _want:
			_apply(l[0], l[1])
	if _load_task >= 0 and WorkerThreadPool.is_task_completed(_load_task):
		WorkerThreadPool.wait_for_task_completion(_load_task)
		_load_task = -1
		_loaded_mutex.lock()
		var got = _loaded
		_loaded = null
		_loaded_mutex.unlock()
		if got is Array and got[0] == _want:
			print("Mod graphics: graphics list from the cache in %d ms" % (Time.get_ticks_msec() - _started_msec))
			_apply_soon(got[0], got[1])
		elif _want != "":
			_ask(true)
	if _want != "" and _want != fingerprint and _load_task < 0 and _asked_msec > 0 and _parts.size() < _total \
			and Time.get_ticks_msec() - _asked_msec > RETRY_MSEC:
		_ask(false)


## How many parts have arrived of how many (0, 0 when nothing is being fetched).
static func progress() -> Vector2i:
	if _want == "" or _want == fingerprint:
		return Vector2i.ZERO
	return Vector2i(_parts.size(), _total)


static func icon_layers(kind: String, name: String):
	return (icons.get(kind, {}) as Dictionary).get(name)


## A `sprite` prototype's picture (a mod's GUI sprite: Space Exploration's "se-...", Factory
## Planner's "fp_..."), read from the mod's files the first time it is asked for; null when the list
## has no such sprite or its file can't be read. Main thread (GUI pictures are small; sheets kept).
static func sprite_texture(name: String) -> Texture2D:
	if _sprite_textures.has(name):
		return _sprite_textures[name]
	var tex: Texture2D = null
	var layers = sprites.get(name)
	if layers is Array and not (layers as Array).is_empty():
		var out: Image = null
		for l in layers:
			if not (l is Array and (l as Array).size() >= 5):
				continue
			var file := str(l[0])
			if not _sheets.has(file):
				_sheets[file] = ModFiles.load_image(file)
			var sheet: Image = _sheets[file]
			if sheet == null:
				continue
			var rect := Rect2i(int(l[1]), int(l[2]), int(l[3]), int(l[4])).intersection(Rect2i(Vector2i.ZERO, sheet.get_size()))
			if rect.size.x <= 0 or rect.size.y <= 0:
				continue
			var part := sheet.get_region(rect)
			part.convert(Image.FORMAT_RGBA8)
			if out == null:
				out = part
			else:
				if part.get_size() != out.get_size():
					part.resize(out.get_width(), out.get_height())
				out.blend_rect(part, Rect2i(Vector2i.ZERO, part.get_size()), Vector2i.ZERO)
		if out != null:
			out.generate_mipmaps()
			tex = ImageTexture.create_from_image(out)
	_sprite_textures[name] = tex
	return tex


## Forgets the list (tests).
static func clear() -> void:
	icons = {}
	tiles = {}
	decor = {}
	ents = {}
	sprites = {}
	_sprite_textures = {}
	_sheets = {}
	fingerprint = ""
	_want = ""
	_parts = {}
	_ready_list = null
	generation += 1


## Applies a whole list once the mods are found (mod_files.gd scans them on a worker after the
## welcome), so nothing made from it misses a mod's files.
static func _apply_soon(fp: String, merged: Dictionary) -> void:
	if ModFiles.is_ready():
		_apply(fp, merged)
	else:
		_ready_list = [fp, merged]


static func _ask(all: bool) -> void:
	if not _send.is_valid():
		return
	_asked_msec = Time.get_ticks_msec()
	var cmd := {"t": "gfx", "fp": _want}
	if not all and not _parts.is_empty():
		var need: Array[int] = []
		for i in range(1, _total + 1):
			if not _parts.has(i):
				need.append(i)
		if need.is_empty():
			return  # nothing missing (an empty `need` asks the bridge for every part)
		cmd["need"] = need
	_send.call(cmd)


static func _merge(parts: Array) -> Dictionary:
	var out := {"icons": {}, "tiles": {}, "decor": {}, "ents": {}, "sprites": {}}
	for d: Dictionary in parts:
		for sec in d:
			var v = d[sec]
			if not v is Dictionary or not out.has(sec):
				continue
			if sec == "icons":
				for kind in v:
					if v[kind] is Dictionary:
						if not out.icons.has(kind):
							out.icons[kind] = {}
						(out.icons[kind] as Dictionary).merge(v[kind], true)
			else:
				(out[sec] as Dictionary).merge(v, true)
	return out


static func _apply(fp: String, merged: Dictionary) -> void:
	icons = merged.get("icons", {})
	tiles = merged.get("tiles", {})
	decor = merged.get("decor", {})
	ents = merged.get("ents", {})
	sprites = merged.get("sprites", {})
	_sprite_textures = {}
	_sheets = {}
	fingerprint = fp
	_want = fp
	_parts = {}
	generation += 1
	_tell()


static func _tell() -> void:
	for f in listeners:
		if f.is_valid():
			f.call()


static func _cache_path(fp: String) -> String:
	return CACHE_DIR.path_join(fp.validate_filename() + ".json")


static func _save(fp: String, merged: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	var file := FileAccess.open(_cache_path(fp), FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"fp": fp, "mods": ModFiles.active_mods(), "list": merged}))
	file.close()
	var files := []
	for f in DirAccess.get_files_at(CACHE_DIR):
		if f.ends_with(".json"):
			files.append([FileAccess.get_modified_time(CACHE_DIR.path_join(f)), f])
	files.sort()
	while files.size() > KEEP:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CACHE_DIR.path_join(files.pop_front()[1])))


static func _read_cache(path: String, fp: String) -> void:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	var got = null
	if parsed is Dictionary and str(parsed.get("fp", "")) == fp and parsed.get("list") is Dictionary:
		got = [fp, parsed.list]
	_loaded_mutex.lock()
	_loaded = got
	_loaded_mutex.unlock()
