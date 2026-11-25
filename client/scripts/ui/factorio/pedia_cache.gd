extends RefCounted
## Disk cache for Factoriopedia's static prototype index and pages (`user://pedia-cache/<gf>.bin`),
## keyed by the mod graphics fingerprint so repeated sessions skip `pedia_index` and static `pedia`
## bridge round-trips. Force-dependent pages (`recipe`, `technology`) are never saved to disk.

const Switches := preload("res://scripts/switches.gd")

const CACHE_DIR := "user://pedia-cache"
const VERSION := 1
const KEEP := 12
const SAVE_DELAY_MSEC := 3000
## Matches mod/factorio-3d-bridge/scripts/pedia.lua FORCE_PAGES: depends on force research state.
const FORCE_KINDS := {"recipe": true, "technology": true}

static var enabled := Switches.on("--pedia-cache")


## Whether a Factoriopedia entry kind is pure prototype data safe to persist across sessions.
static func is_cacheable_kind(kind: String) -> bool:
	return kind != "" and not FORCE_KINDS.has(kind)


static func cache_path(fp: String) -> String:
	return CACHE_DIR.path_join(fp.validate_filename() + ".bin")


## Loads cached groups, index, and static pages for fingerprint `fp`, or `{}` on miss/disabled.
static func load_for(fp: String) -> Dictionary:
	if not enabled or fp == "":
		return {}
	var path := cache_path(fp)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var raw: Variant = f.get_var(false)
	f.close()
	if not (raw is Dictionary):
		return {}
	var d := raw as Dictionary
	if int(d.get("v", 0)) != VERSION or str(d.get("fp", "")) != fp:
		return {}
	var raw_groups: Variant = d.get("groups")
	var raw_index: Variant = d.get("index")
	var raw_pages: Variant = d.get("pages")
	var groups: Array = raw_groups if raw_groups is Array else []
	var index: Array = raw_index if raw_index is Array else []
	var kept_pages := {}
	if raw_pages is Dictionary:
		for k in raw_pages as Dictionary:
			var key := str(k)
			var kind := key.get_slice("/", 0)
			if not is_cacheable_kind(kind):
				continue
			var entry: Variant = (raw_pages as Dictionary)[k]
			if entry is Dictionary and bool((entry as Dictionary).get("found", false)):
				kept_pages[key] = entry
	return {"groups": groups, "index": index, "pages": kept_pages}


## Atomically writes Factoriopedia's groups, index, and static pages for `fp`, pruning old caches.
static func save_for(fp: String, groups: Array, index: Array, pages: Dictionary) -> void:
	if not enabled or fp == "":
		return
	var kept := {}
	for k in pages:
		var key := str(k)
		var kind := key.get_slice("/", 0)
		if not is_cacheable_kind(kind):
			continue
		var entry: Variant = pages[k]
		if entry is Dictionary and bool((entry as Dictionary).get("found", false)):
			kept[key] = entry
	if index.is_empty() and kept.is_empty():
		return
	var abs_dir := ProjectSettings.globalize_path(CACHE_DIR)
	DirAccess.make_dir_recursive_absolute(abs_dir)
	var path := cache_path(fp)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	var payload := {"v": VERSION, "fp": fp, "groups": groups, "index": index, "pages": kept}
	f.store_var(payload, false)
	var ok := f.get_error() == OK
	f.close()
	var abs_tmp := ProjectSettings.globalize_path(tmp)
	var abs_path := ProjectSettings.globalize_path(path)
	if not ok or DirAccess.rename_absolute(abs_tmp, abs_path) != OK:
		if FileAccess.file_exists(tmp):
			DirAccess.remove_absolute(abs_tmp)
		return
	_prune()


static func _prune() -> void:
	var files: Array = []
	for f in DirAccess.get_files_at(CACHE_DIR):
		if f.ends_with(".bin"):
			files.append([FileAccess.get_modified_time(CACHE_DIR.path_join(f)), f])
	if files.size() <= KEEP:
		return
	files.sort()
	while files.size() > KEEP:
		var oldest: String = str(files.pop_front()[1])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CACHE_DIR.path_join(oldest)))
