extends RefCounted
## Model packs that pass on Factorio's own files are refused whole (the owner's rule: "if any model pack
## is redistributing Factorio's work we won't load any of it and make it red explaining why"). A pack
## holding a file that is a byte-for-byte copy of one in the player's install (a sound, a picture,
## anything) gives nothing: no model, item, icon or sound. Factorio's graphics and sounds are Wube's;
## Zenith reads them from the player's own install and never takes them from a pack.
##
## One place for every pack source (model_packs.gd: loose models, folders, zips, --models, the
## built-in ones; packs in a Factorio mod's zenith/ folder later): find_copies() takes a pack's files
## and the install's data folder. Not checked (SKIPPED): the Factorio pack (it is the install) and
## Wube3DP (Wube's own CC BY-NC release). There is no switch to turn it off: it is a bound, not a look.
##
## Cheap: files under MIN_SIZE are left alone (a blank 1x1 picture matches by chance). A pack's file
## is compared first with the install's file at the same Factorio path when its layout gives one
## (sounds/<mod>/..., icons/..., a <mod>/ or __mod__/ folder in its path), size then bytes; then with
## the install's files of the same size, by hash. The install's sizes are listed once, on a worker,
## and kept in user://pack-check/install.json until the install changes (its base version, the
## modified time of base/info.json and its folder: install_stamp()); only files whose size matches
## are hashed. Each pack's answer is kept in user://pack-check/packs.json by its id, its own stamp
## (a zip's size and modified time, a folder's file list with modified times) and the install's, so
## an unchanged pack costs nothing at start-up.

## Files smaller than this (bytes) are never compared.
const MIN_SIZE := 1024
const CACHE_DIR := "user://pack-check"
const INSTALL_FILE := "install.json"
const PACKS_FILE := "packs.json"
## Packs not checked: the Factorio pack (the install itself) and Wube's own printable models.
const SKIPPED := ["builtin:factorio", "builtin:wube3dp"]
## How deep a pack's folders are listed (model_packs.gd MAX_DEPTH and a few for its icons and sounds).
const MAX_DEPTH := 16

## The card's words (the manager approved them; model_packs_window.gd shows them, the log says them).
const REFUSED := "Not loaded: this pack contains Factorio's own files"
const CHECKING := "Checking for copies of Factorio's files…"
const UNCHECKED := "Not checked for copies of Factorio's files: no Factorio install was found."

## Tests: the data folder to compare with instead of the player's install (a folder the test made;
## "" for none). null: the player's own.
static var test_install: Variant = null
## Files hashed this run (tests: an unchanged pack costs none).
static var hashed := 0
## Files a check looked at this run (over MIN_SIZE).
static var looked_at := 0
## The install's size list as read or made: {stamp, sizes: {"<size>": [path in data/]}, hashes:
## {path: sha256}}. Only the worker that checks touches it.
static var _index := {}
static var _index_changed := false
static var _mods: Dictionary = {}  # the install's mod folders (lower case -> folder name), for same-path guesses
## The packs' answers (packs.json): id -> {stamp, install, copies}. Main thread only.
static var _answers := {}
static var _answers_read := false


## Whether pack `id` is checked at all.
static func checks(id: String) -> bool:
	return not SKIPPED.has(id)


## The data folder to compare packs with, "" without an install.
static func install_dir() -> String:
	if test_install != null:
		return str(test_install)
	# Loaded, not preloaded: item_icons.gd preloads model_packs.gd, which preloads this script.
	return load("res://scripts/world/item_icons.gd").factorio_data_dir()


## What identifies the install's files: base's version, base/info.json's and the folder's modified
## times, and the folder itself. "" without one.
static func install_stamp(data: String) -> String:
	if data == "" or not DirAccess.dir_exists_absolute(data):
		return ""
	var info := data.path_join("base/info.json")
	var version := ""
	if FileAccess.file_exists(info):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(info))
		if parsed is Dictionary:
			version = str((parsed as Dictionary).get("version", ""))
	return "%s|%d|%d|%s" % [version, FileAccess.get_modified_time(info), FileAccess.get_modified_time(data), data.sha256_text().left(16)]


## Every file of a pack, as path in the pack -> file (find_copies leaves out those under MIN_SIZE). `loose`: the models folder's
## top (its loose models' pack): its files there and its icons/, items/ and sounds/ folders, not the
## other packs (folders and zips) beside them.
static func pack_files(root: String, loose := false) -> Dictionary:
	var out := {}
	if root == "" or not (root.begins_with("res://") or DirAccess.dir_exists_absolute(root)):
		return out
	if not loose:
		_list(root, "", 0, out)
		return out
	for f in DirAccess.get_files_at(root):
		if f.get_extension().to_lower() != "zip":
			out[f] = root.path_join(f)
	for sub in DirAccess.get_directories_at(root):
		if sub.to_lower() in ["icons", "items", "sounds"]:
			_list(root.path_join(sub), sub + "/", 1, out)
	return out


static func _list(dir: String, rel: String, d: int, out: Dictionary) -> void:
	for f in DirAccess.get_files_at(dir):
		out[rel + f] = dir.path_join(f)
	if d >= MAX_DEPTH:
		return
	for sub in DirAccess.get_directories_at(dir):
		if sub != "." and sub != "..":
			_list(dir.path_join(sub), rel + sub + "/", d + 1, out)


## A folder pack's stamp: its files' paths and modified times (a file changed, added or removed
## changes it). A zip's is its unpacked copy's folder name (its size and modified time) instead.
## `version`: a built-in pack's, Zenith's version and its paths alone (it changes only with Zenith,
## an exported game's files have no times, and reading 1,400 files' times cost 25 ms a start).
static func folder_stamp(files: Dictionary, version := "") -> String:
	var names := files.keys()
	names.sort()
	var text := PackedStringArray()
	for rel: String in names:
		text.append(rel if version != "" else "%s|%d" % [rel, FileAccess.get_modified_time(str(files[rel]))])
	return "%d:%s%s" % [names.size(), "\n".join(text).sha256_text(), "|" + version if version != "" else ""]


## The answer kept for pack `id` with this stamp against this install: the copies' paths (empty: a
## clean pack), or null when it has to be checked.
static func known(id: String, stamp: String, install: String) -> Variant:
	_read_answers()
	var a: Variant = _answers.get(id)
	if not a is Dictionary or str((a as Dictionary).get("stamp", "")) != stamp or str((a as Dictionary).get("install", "")) != install:
		return null
	var copies: Variant = (a as Dictionary).get("copies", [])
	return (copies as Array).duplicate() if copies is Array else null


## Keeps a pack's answer (main thread).
static func remember(id: String, stamp: String, install: String, copies: Array) -> void:
	_read_answers()
	_answers[id] = {"stamp": stamp, "install": install, "copies": copies}
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	var f := FileAccess.open(CACHE_DIR.path_join(PACKS_FILE), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_answers))
		f.close()


static func _read_answers() -> void:
	if _answers_read:
		return
	_answers_read = true
	var path := CACHE_DIR.path_join(PACKS_FILE)
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary:
			_answers = parsed


## Forgets every kept answer and the install's list (tests).
static func forget() -> void:
	_answers = {}
	_answers_read = true
	_index = {}
	_mods = {}
	_remove(CACHE_DIR.path_join(PACKS_FILE))
	_remove(CACHE_DIR.path_join(INSTALL_FILE))


static func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## On a worker: the paths of `files` (path in the pack -> file) that are copies of the install's
## files in `data`, sorted. Only real copies: the same bytes.
static func find_copies(files: Dictionary, data: String) -> Array:
	var out: Array = []
	if data == "" or files.is_empty():
		return out
	_load_index(data)
	var sizes: Dictionary = _index["sizes"]
	for rel: String in files:
		var file := str(files[rel])
		var size := FileAccess.get_size(file)
		if size < MIN_SIZE:
			continue
		looked_at += 1
		if _same_path_copy(rel, file, size, data) or _same_size_copy(file, size, sizes, data):
			out.append(rel)
	if _index_changed:
		_save_index()
	out.sort()
	return out


## The install's file at the Factorio path the pack's layout gives, compared: size, then bytes.
static func _same_path_copy(rel: String, file: String, size: int, data: String) -> bool:
	for guess: String in _guesses(rel):
		var there := data.path_join(guess)
		if FileAccess.file_exists(there) and FileAccess.get_size(there) == size:
			if _hash(file) == _install_hash(guess, data):
				return true
	return false


## Install paths (in data/) a pack's file would be at if laid out as Factorio's: a folder named as
## one of the install's mods, or as __mod__, starts its path (sounds/<mod>/... is one); icons/<name>.png
## and icons/<kind>/<name>.png are a mod's graphics/icons/ (graphics/technology/ for technologies).
static func _guesses(rel: String) -> Array:
	var out: Array = []
	var parts := rel.split("/")
	for i in parts.size() - 1:
		var piece := parts[i].to_lower()
		if piece.length() > 4 and piece.begins_with("__") and piece.ends_with("__"):
			piece = piece.substr(2, piece.length() - 4)
		if _mods.has(piece):
			out.append(str(_mods[piece]) + "/" + "/".join(parts.slice(i + 1)))
	for i in mini(2, parts.size() - 1):
		if parts[i].to_lower() == "icons" and parts.size() - i in [2, 3]:
			var name := parts[parts.size() - 1]
			var kind := parts[i + 1].to_lower() if parts.size() - i == 3 else ""
			for mod: String in _mods.values():
				out.append("%s/graphics/%s/%s" % [mod, "technology" if kind == "technology" else "icons", name])
			break
	return out


## The install's files of the same size, by hash.
static func _same_size_copy(file: String, size: int, sizes: Dictionary, data: String) -> bool:
	var same: Variant = sizes.get(str(size))
	if not same is Array:
		return false
	var mine := _hash(file)
	for rel: String in same:
		if _install_hash(rel, data) == mine:
			return true
	return false


static func _hash(file: String) -> String:
	hashed += 1
	return FileAccess.get_sha256(file)


static func _install_hash(rel: String, data: String) -> String:
	var hashes: Dictionary = _index["hashes"]
	if hashes.has(rel):
		return str(hashes[rel])
	var h := _hash(data.path_join(rel))
	hashes[rel] = h
	_index_changed = true
	return h


## The install's size list: kept on disk, made again when the install changed.
static func _load_index(data: String) -> void:
	var stamp := install_stamp(data)
	if _mods.is_empty() or str(_index.get("stamp", "")) != stamp:
		_mods = {}
		for d in DirAccess.get_directories_at(data):
			_mods[d.to_lower()] = d
	if str(_index.get("stamp", "")) == stamp:
		return
	var path := CACHE_DIR.path_join(INSTALL_FILE)
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary and str((parsed as Dictionary).get("stamp", "")) == stamp \
				and (parsed as Dictionary).get("sizes") is Dictionary and (parsed as Dictionary).get("hashes") is Dictionary:
			_index = parsed
			_index_changed = false
			return
	var sizes := {}
	_size_walk(data, "", sizes)
	_index = {"stamp": stamp, "sizes": sizes, "hashes": {}}
	_index_changed = true


static func _size_walk(dir: String, rel: String, sizes: Dictionary) -> void:
	for f in DirAccess.get_files_at(dir):
		var size := FileAccess.get_size(dir.path_join(f))
		if size >= MIN_SIZE:
			var key := str(size)
			if not sizes.has(key):
				sizes[key] = []
			(sizes[key] as Array).append(rel + f)
	for sub in DirAccess.get_directories_at(dir):
		_size_walk(dir.path_join(sub), rel + sub + "/", sizes)


static func _save_index() -> void:
	_index_changed = false
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	var f := FileAccess.open(CACHE_DIR.path_join(INSTALL_FILE), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_index))
		f.close()


## The card's and the log's sentence for a refused pack's copies (paths in the pack).
static func detail(copies: Array) -> String:
	var n := copies.size()
	var lead := "1 of its files is a copy of a file" if n == 1 else "%d of its files are copies of files" % n
	return ("%s from your Factorio install, for example %s. Factorio's graphics and sounds are Wube Software's, "
		+ "and Zenith doesn't load packs that pass them on, so none of this pack is used. Zenith already reads them from "
		+ "your own install. Ask the pack's author for a version without them.") % [lead, copies[0] if n > 0 else ""]
