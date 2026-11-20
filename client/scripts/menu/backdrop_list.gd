extends RefCounted
## The player's saved menu backdrops: each "Use this view as the menu backdrop" (Esc menu) writes a new
## snapshot (backdrop_recorder.gd's file) into user://backdrops/, and the Menu backdrop window lists them.
## A file is named by when it was taken (backdrop-YYYYMMDD-HHMMSS.json.gz: nothing the player typed goes
## into a file name); the name shown (its save and the date and time, which the player can change) is
## in the snapshot itself and in backdrops.cfg beside the files, so the window lists them without
## reading each one (a file dropped into the folder by hand is read once and named from its own
## `name`, else its `save`). Settings interface/backdrop holds the id in use: "default" is Zenith's
## built-in backdrop; "snapshot" (before 0.2.2) the one file user://menu-backdrop.json.gz, which
## migrate() moves into the folder once.
##
## --menu-backdrop-save=overwrite: a new recording replaces the one in use instead of adding one (one
## file, overwritten, as before 0.2.2; with Default in use it still adds one).

const Settings := preload("res://scripts/menu/settings.gd")
const BackdropRecorder := preload("res://scripts/menu/backdrop_recorder.gd")

const EXT := ".json.gz"
const INDEX := "backdrops.cfg"
const DEFAULT := "default"
const OLD_SETTING := "snapshot"
const OLD_NAME := "Saved backdrop"
const NAME_MAX := 80
## The index's own section (a space: never an id).
const MIGRATED := "old file"

## The folder (the tests use their own).
static var dir := "user://backdrops"
## The one file before 0.2.2, moved into the folder by migrate() (the tests use their own).
static var old_path := BackdropRecorder.PATH
## --menu-backdrop-save=overwrite (see above).
static var overwrite := Settings.arg_value("--menu-backdrop-save=") == "overwrite"
## How Open folder opens it (the tests put a stand-in here).
static var shell_open := Callable(OS, "shell_open")


## An id is a file's name without EXT: letters, digits, - and _ only (nothing else reaches a path).
static func valid_id(id: String) -> bool:
	if id == "" or id == DEFAULT or id == OLD_SETTING:
		return false
	for c in id:
		if not (c == "-" or c == "_" or (c >= "0" and c <= "9") or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z")):
			return false
	return true


static func path_of(id: String) -> String:
	return dir.path_join(id + EXT) if valid_id(id) else ""


## The setting's choice: "default", "snapshot" (the old file, not moved yet) or an id.
static func in_use() -> String:
	var v := str(Settings.get_value("interface", "backdrop"))
	return DEFAULT if v == "" else v


static func use(id: String) -> void:
	Settings.set_value("interface", "backdrop", id if id == DEFAULT or valid_id(id) else DEFAULT)


## A new id from the time (local), with -2, -3... when one of that second is there already.
static func new_id(unix := -1) -> String:
	var t := unix if unix >= 0 else int(Time.get_unix_time_from_system())
	var d := Time.get_datetime_dict_from_unix_time(t + _bias_seconds())
	var base := "backdrop-%04d%02d%02d-%02d%02d%02d" % [d["year"], d["month"], d["day"], d["hour"], d["minute"], d["second"]]
	var id := base
	var n := 1
	while FileAccess.file_exists(path_of(id)):
		n += 1
		id = "%s-%d" % [base, n]
	return id


## The name a new recording gets: the save it came from and when (local time).
static func default_name(save: String, unix: int) -> String:
	var when := Time.get_datetime_string_from_unix_time(unix + _bias_seconds(), true).substr(0, 16) if unix > 0 else ""
	var s := save.strip_edges()
	if s == "":
		return OLD_NAME + (", " + when if when != "" else "")
	return s + (", " + when if when != "" else "")


static func _bias_seconds() -> int:
	return int(Time.get_time_zone_from_system().get("bias", 0)) * 60


static func _index() -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.load(dir.path_join(INDEX))
	return cfg


static func _save_index(cfg: ConfigFile) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	cfg.save(dir.path_join(INDEX))


## A finished recording into the list (its file is at path_of(id) already).
static func add(id: String, name: String, unix: int) -> void:
	if not valid_id(id):
		return
	var cfg := _index()
	cfg.set_value(id, "name", _clean_name(name, OLD_NAME))
	cfg.set_value(id, "taken", unix)
	_save_index(cfg)


static func _clean_name(name: String, fallback: String) -> String:
	var s := name.strip_edges().replace("\n", " ").replace("\r", " ").left(NAME_MAX)
	return s if s != "" else fallback


## The saved backdrops, newest first: [{"id", "name", "path", "taken"}]. Files the index doesn't know
## yet are read once for their names; names of files gone are dropped from it.
static func entries() -> Array:
	migrate()
	var cfg := _index()
	var changed := false
	var out: Array = []
	var seen := {}
	var d := DirAccess.open(dir)
	if d != null:
		for f in d.get_files():
			if not f.ends_with(EXT):
				continue
			var id := f.trim_suffix(EXT)
			if not valid_id(id):
				continue
			seen[id] = true
			if not cfg.has_section(id):
				var snap := BackdropRecorder.read(path_of(id))
				var taken := int(snap.get("taken", 0))
				var name := str(snap.get("name", ""))
				if name == "":
					name = default_name(str(snap.get("save", "")), taken) if snap.has("save") else OLD_NAME
				cfg.set_value(id, "name", _clean_name(name, OLD_NAME))
				cfg.set_value(id, "taken", taken if taken > 0 else int(FileAccess.get_modified_time(path_of(id))))
				changed = true
			out.append({"id": id, "name": str(cfg.get_value(id, "name", OLD_NAME)), "path": path_of(id), "taken": int(cfg.get_value(id, "taken", 0))})
	for id in cfg.get_sections():
		if valid_id(id) and not seen.has(id):
			cfg.erase_section(id)
			changed = true
	if changed:
		_save_index(cfg)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["taken"]) > int(b["taken"]) or (int(a["taken"]) == int(b["taken"]) and str(a["id"]) > str(b["id"])))
	return out


static func name_of(id: String) -> String:
	for e: Dictionary in entries():
		if e["id"] == id:
			return str(e["name"])
	return ""


## A new name (empty: kept as it was). Only the index changes: the snapshot keeps the name it was
## recorded with, which is used only if the index is lost.
static func rename(id: String, name: String) -> bool:
	if not valid_id(id) or not FileAccess.file_exists(path_of(id)):
		return false
	var cfg := _index()
	cfg.set_value(id, "name", _clean_name(name, str(cfg.get_value(id, "name", OLD_NAME))))
	_save_index(cfg)
	return true


## Deletes the file (for good) and its name; the one in use goes back to Default.
static func delete(id: String) -> bool:
	if not valid_id(id):
		return false
	var path := path_of(id)
	if FileAccess.file_exists(path) and DirAccess.remove_absolute(path) != OK:
		return false
	var cfg := _index()
	if cfg.has_section(id):
		cfg.erase_section(id)
		_save_index(cfg)
	if in_use() == id:
		use(DEFAULT)
	return true


## Opens the folder in the file manager (made first, so there is one to open).
static func open_folder() -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	shell_open.call(ProjectSettings.globalize_path(dir))


## The one file before 0.2.2 (old_path) moved into the folder, once: named from its `save` (with when it
## was taken), "Saved backdrop" without one; in use if it was ("snapshot"). Moved, so it is gone after;
## when it could only be copied (the old file held open), its time and size are noted and that file
## isn't copied again. Returns the new id, or "".
static func migrate() -> String:
	if not FileAccess.file_exists(old_path):
		return ""
	var mtime := int(FileAccess.get_modified_time(old_path))
	var cfg := _index()
	if str(cfg.get_value(MIGRATED, "stamp", "")) == _stamp(old_path):
		return ""
	var snap := BackdropRecorder.read(old_path)
	var taken := int(snap.get("taken", 0))
	var id := new_id(taken if taken > 0 else mtime)
	DirAccess.make_dir_recursive_absolute(dir)
	var path := path_of(id)
	if DirAccess.rename_absolute(old_path, path) != OK:
		if DirAccess.copy_absolute(old_path, path) != OK:
			return ""
		DirAccess.remove_absolute(old_path)
	var save := str(snap.get("save", ""))
	cfg.set_value(id, "name", default_name(save, taken) if save != "" else OLD_NAME)
	cfg.set_value(id, "taken", taken if taken > 0 else mtime)
	if FileAccess.file_exists(old_path):
		cfg.set_value(MIGRATED, "stamp", _stamp(old_path))
	elif cfg.has_section(MIGRATED):
		cfg.erase_section(MIGRATED)
	_save_index(cfg)
	if in_use() == OLD_SETTING:
		use(id)
	print("backdrop: the old snapshot moved into %s as %s" % [dir, id])
	return id


## A file's time and size, which say it is the same file as before.
static func _stamp(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return "%d:%d" % [FileAccess.get_modified_time(path), f.get_length() if f != null else -1]
