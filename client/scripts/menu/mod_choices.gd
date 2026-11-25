extends RefCounted
## The mods the player turned on in Zenith's Mods window (mods_window.gd), kept apart from the
## server's mods/mod-list.json, which the launcher (server_launcher.gd) writes before each start: a
## new game gets these mods; a loaded save gets its own mods (Factorio's --sync-mods) with these
## added, as Factorio adds the mods turned on to a save it loads; Load game's "Sync mods with save"
## leaves them out. (Each load used to rewrite mod-list.json to the save's mods, so the Mods window's
## choices were lost at the next load.)
##
## Kept in <server data>/zenith-mods.json, mod-list.json's shape ({"mods": [{"name", "enabled"}]}),
## beside the mods folder, where Factorio doesn't look. A mod not listed is off: every load links the
## player's own Factorio mods into the folder, so a mod found there isn't on by itself as in Factorio.
## Wube's own mods (Space Age and the DLC it needs) are on unless turned off, and only new games take
## them from here: a loaded save keeps its own (Space Exploration refuses Space Age, say).

const Paths := preload("res://scripts/menu/paths.gd")

const FILE := "zenith-mods.json"
const BRIDGE := "factorio-3d-bridge"
## Wube's mods in the install's data folder; "recycler" came with 2.1.
const GAME := ["base", "elevated-rails", "quality", "recycler", "space-age"]


static func path(data_dir := "") -> String:
	return (data_dir if data_dir != "" else Paths.server_data_dir()).path_join(FILE)


## The choices as name -> on. Before the file exists (a server folder of an earlier Zenith), they
## come from the server's mod-list.json. Each load rewrote it to the save's mods with --sync-mods,
## which gives every mod it turns on its version and the Mods window never does: from a list a load
## wrote only the mods turned on without a version count (ticked in the Mods window since), so the
## last save's mods and DLC aren't taken for the player's; a list only the Mods window wrote counts
## as it is.
static func states(data_dir := "") -> Dictionary:
	var out := {}
	var file := path(data_dir)
	if FileAccess.file_exists(file):
		for m in _entries(file):
			out[str(m.get("name", ""))] = bool(m.get("enabled", false))
		return out
	var list := _entries((data_dir if data_dir != "" else Paths.server_data_dir()).path_join("mods/mod-list.json"))
	var synced := list.any(func(m: Dictionary) -> bool: return m.has("version"))
	for m in list:
		var name := str(m.get("name", ""))
		var on := bool(m.get("enabled", true))
		if not synced and (on or GAME.has(name)):
			out[name] = on
		elif synced and on and not m.has("version"):
			out[name] = true
	return out


## Whether a mod is on in `choices` (states()): the base game and the bridge always, Wube's other
## mods unless turned off, the rest only when turned on.
static func is_on(name: String, choices: Dictionary) -> bool:
	if name == "base" or name == BRIDGE:
		return true
	if GAME.has(name) and not installed(name):
		return false  # issue #28: no Space Age bought, so no Space Age map controls Factorio refuses
	return bool(choices.get(name, GAME.has(name)))


static var _installed_cache := {}

## Whether one of Wube's mods is in the install's data folder (a copy without Space Age has none of
## its DLC). True when no Factorio is found, as before; `--dlc-detect=off` always says true.
static func installed(name: String) -> bool:
	if name == "base" or "--dlc-detect=off" in OS.get_cmdline_user_args():
		return true
	var exe := Paths.factorio_exe()
	if exe == "":
		return true
	var dir := Paths.read_data_dir(exe)
	if not DirAccess.dir_exists_absolute(dir.path_join("base")):
		return true
	var key := dir + "|" + name
	if not _installed_cache.has(key):
		_installed_cache[key] = DirAccess.dir_exists_absolute(dir.path_join(name))
	return bool(_installed_cache[key])


## The mods other than Wube's and the bridge turned on: what a loaded save gets added.
static func added(choices: Dictionary) -> Array:
	var out: Array = []
	for name in choices:
		if not GAME.has(name) and name != BRIDGE and bool(choices[name]):
			out.append(name)
	out.sort()
	return out


static func write(choices: Dictionary, data_dir := "") -> void:
	var list: Array = []
	for name in choices:
		if name != "" and name != BRIDGE:
			list.append({"name": name, "enabled": bool(choices[name])})
	var file := path(data_dir)
	DirAccess.make_dir_recursive_absolute(file.get_base_dir())
	var f := FileAccess.open(file, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"mods": list}, "  "))
		f.close()


static func _entries(file: String) -> Array:
	if not FileAccess.file_exists(file):
		return []
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(file))
	var mods = parsed.get("mods", []) if parsed is Dictionary else []
	return (mods as Array).filter(func(m: Variant) -> bool: return m is Dictionary) if mods is Array else []


# --- what a mods folder holds ------------------------------------------------------------------

## The mods in a mods folder as name -> {version -> path} (zips, and folders with an info.json),
## the bridge's link and the lists left out.
static func folder(mods_dir: String) -> Dictionary:
	var out := {}
	if not DirAccess.dir_exists_absolute(mods_dir):
		return out
	var re := RegEx.create_from_string("^(.+)_(\\d+\\.\\d+\\.\\d+)(\\.zip)?$")
	for f in DirAccess.get_files_at(mods_dir):
		var m := re.search(f)
		if m != null and f.to_lower().ends_with(".zip"):
			_put(out, m.get_string(1), m.get_string(2), mods_dir.path_join(f))
	for d in DirAccess.get_directories_at(mods_dir):
		var m := re.search(d)
		if m != null:
			_put(out, m.get_string(1), m.get_string(2), mods_dir.path_join(d))
		else:
			var info := info_at(mods_dir.path_join(d))
			if not info.is_empty():
				_put(out, str(info.get("name", d)), str(info.get("version", "0.0.0")), mods_dir.path_join(d))
	out.erase(BRIDGE)
	return out


static func _put(out: Dictionary, name: String, version: String, at: String) -> void:
	if not out.has(name):
		out[name] = {}
	out[name][version] = at


## The highest of a mod's versions ("1.10.0" over "1.9.3").
static func highest(versions: Array) -> String:
	var best := ""
	for v in versions:
		if best == "" or newer(str(v), best):
			best = str(v)
	return best


static func newer(a: String, b: String) -> bool:
	var pa := a.split(".")
	var pb := b.split(".")
	for i in maxi(pa.size(), pb.size()):
		var x := int(pa[i]) if i < pa.size() else 0
		var y := int(pb[i]) if i < pb.size() else 0
		if x != y:
			return x > y
	return false


static func info_at(dir: String) -> Dictionary:
	var file := dir.path_join("info.json")
	if not FileAccess.file_exists(file):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(file))
	return parsed if parsed is Dictionary else {}


static func info_in_zip(zip_path: String) -> Dictionary:
	var zip := ZIPReader.new()
	if zip.open(zip_path) != OK:
		return {}
	var info := {}
	for f in zip.get_files():
		if f.get_file() == "info.json" and f.count("/") <= 1:
			var parsed = JSON.parse_string(zip.read_file(f).get_string_from_utf8())
			if parsed is Dictionary:
				info = parsed
			break
	zip.close()
	return info


static func info_of(at: String) -> Dictionary:
	return info_in_zip(at) if at.to_lower().ends_with(".zip") else info_at(at)


## A mod's dependencies split as Factorio writes them ("! name", "? name >= 1.0", "~ name") into
## [prefix, name]: "" and "~" required, "!" incompatible, "?" and "(?)" optional, "+" recommended
## (2.1: on with the mod unless turned off).
static func dependencies(info: Dictionary) -> Array:
	var out: Array = []
	var deps = info.get("dependencies", [])
	if not deps is Array:
		return out
	var re := RegEx.create_from_string("^\\s*(!|\\?|\\(\\?\\)|~|\\+)?\\s*(.+?)\\s*(?:(?:<=|>=|=|<|>)\\s*\\S+)?\\s*$")
	for d in deps:
		var m := re.search(str(d))
		if m != null:
			out.append([m.get_string(1), m.get_string(2)])
	return out


## Adds the mods in `wanted` to `running` (name -> version, "" for the highest the folder has), each
## with the mods it needs and recommends ("+") that the folder has, as Factorio's Mods window turns
## those on with it. A mod is left out, with why, when it or one it needs clashes with a mod running
## ("!" either way), or needs a mod the folder doesn't have (Wube's own too: a save keeps its own
## DLC), since the server would refuse to start. {"added": [names], "left_out": ["name: why"]};
## `running` grows.
static func add_to(running: Dictionary, wanted: Array, mods_dir: String) -> Dictionary:
	var have := folder(mods_dir)
	var infos := {}
	var info := func(name: String) -> Dictionary:
		if not infos.has(name):
			var versions: Dictionary = have.get(name, {})
			var v := str(running.get(name, ""))
			if not versions.has(v):
				v = highest(versions.keys())
			infos[name] = info_of(str(versions[v])) if v != "" else {}
		return infos[name]
	var added: Array = []
	var left_out: Array = []
	for want in wanted:
		var name := str(want)
		if running.has(name):
			continue
		# The mod and every mod it needs that isn't running yet.
		var closure: Array = []
		var queue: Array = [[name, true]]  # [mod, required]
		var why := ""
		while not queue.is_empty() and why == "":
			var next: Array = queue.pop_front()
			var n: String = next[0]
			if closure.has(n) or running.has(n) or n == "base" or n == "core":
				continue
			if GAME.has(n) or not have.has(n):
				if not next[1]:
					pass
				elif not GAME.has(n):
					why = "needs %s, which isn't in the mods folder" % n
				elif n == name:
					why = "Wube's mods follow the save"
				else:
					why = "needs %s, which isn't on" % n
				continue
			closure.append(n)
			for d in dependencies(info.call(n)):
				if d[0] == "" or d[0] == "~" or d[0] == "+":
					queue.append([d[1], d[0] != "+"])
		if why == "":
			for n in closure:
				for d in dependencies(info.call(n)):
					if d[0] == "!" and (running.has(d[1]) or closure.has(d[1])):
						why = "%s can't run with %s" % [n, d[1]]
			for r in running:
				for d in dependencies(info.call(str(r))):
					if d[0] == "!" and closure.has(d[1]):
						why = "%s can't run with %s" % [r, d[1]]
		if why != "":
			left_out.append("%s: %s" % [name, why])
			continue
		for n in closure:
			running[n] = ""
			added.append(n)
	return {"added": added, "left_out": left_out}
