extends RefCounted
## Finds Zenith's add-ons and reads their addon.json (docs/ADDONS.md). An add-on is a folder with
## an addon.json naming its entry script, or a .zip of one (addon.json at the zip's root or one
## folder down, as Factorio's mod zips), unpacked by Zenith into user://addons-cache/ when it starts
## (again only when the zip changes), so relative preloads work as in a folder. Looked for in these
## places; on a duplicate id one given on the command line wins (a development copy), else the
## newer version (a folder on a tie); the one left out is named in the Add-ons menu:
##   --addons=<folder>[,<folder>...]   an add-on's own folder, or a folder of add-ons (development;
##                                     always on while given)
##   user://addons                     Zenith's user data (on Windows %APPDATA%\Godot\app_userdata\Zenith\addons)
##   <Zenith's folder>/addons          beside Zenith.exe in a download (in a checkout: the repo's root)
##
## Whether each is on is kept in the settings file's [addons] section (id -> bool). An add-on is a
## program running with the player's rights (GDScript can't be sandboxed), so until the player sets
## it, one found is off: switching it on is the consent. A download's own add-ons start as it says:
## tools/release/package.py writes <Zenith's folder>/addons/bundled.json, {id: on?} for the add-ons
## it bundles (owner: the Cinematic camera and shaders on, Terrain Elevation off). `--addons-default=on`
## brings back the old rule (every add-on on until switched off). Add-ons found on the first start
## under this rule, in a settings file an earlier Zenith wrote, were on and stay on (_migrate_once).

const Paths := preload("res://scripts/menu/paths.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const SafeDelete := preload("res://scripts/safe_delete.gd")  # never through a link

## The add-on API this Zenith offers (addon_api.gd). An add-on names the one it needs in its
## addon.json as "api"; one that needs a newer API than this is refused with a message.
const API_VERSION := 1
## The exact API level, with what was added within version 1 (1.1: api.settings, the Add-ons
## menu's pages, api.view.keep_drawing; 1.2: api.terrain; 1.3: api.shaders; 1.4: looks' own_clouds, taa, roughness_limiter; 1.5: a look's sunrise and sunset, its passes' sun uniforms, api.shaders.sun(); 1.6: api.world.hold_chunks,
## api.view.full_detail and api.view.screenshot; 1.7: api.character, api.camera.mode, the lift, api.game, addon.json's
## dependencies, api.addons, api.sound, reload and script errors, a look's shadow_edge). An addon.json may ask for 1.1 to 1.7; 1 means any 1.x. (0.2.3 ships one level, 1.7.)
const API_LEVEL := 1.7
const MANIFEST := "addon.json"
## Ids are folder-like names: lower case letters, digits, - and _.
const ID_CHARS := "abcdefghijklmnopqrstuvwxyz0123456789-_"

## Extra folders to look in before the others (tests); when set, the usual places are skipped.
static var test_folders: Array = []
## bundled.json read by bundled_defaults() (tests point it elsewhere; "" the download's own).
static var bundled_file := ""
## Where zipped add-ons are unpacked (tests point it elsewhere).
static var cache_root := "user://addons-cache"


## [[folder, source], ...] in the order they are searched. Source: "command line", "user", "Zenith".
static func folders() -> Array:
	if not test_folders.is_empty():
		return test_folders.map(func(f: String) -> Array: return [f, "test"])
	var out: Array = []
	var given := Settings.arg_value("--addons=")
	if given != "":
		for f in given.split(",", false):
			out.append([f.strip_edges().replace("\\", "/"), "command line"])
	out.append([ProjectSettings.globalize_path("user://addons"), "user"])
	out.append([Paths.repo_dir().path_join("addons"), "Zenith"])
	return out


## Every add-on found, as manifests (see read() and read_zip()), in search order. Of two with one
## id, the one given on the command line is kept, else the newer version (the one found first on a
## tie); the kept one's "also" says what was left out.
static func scan(where: Array = []) -> Array:
	if where.is_empty():
		where = folders()
	var out: Array = []
	var seen := {}  # key -> index in out
	for pair in where:
		var dir := str(pair[0])
		var source := str(pair[1])
		var candidates: Array = []
		if dir.to_lower().ends_with(".zip") and FileAccess.file_exists(dir):
			candidates.append(dir)
		elif FileAccess.file_exists(dir.path_join(MANIFEST)):
			candidates.append(dir)
		elif DirAccess.dir_exists_absolute(dir):
			var subs := DirAccess.get_directories_at(dir)
			subs.sort()
			for sub in subs:
				if FileAccess.file_exists(dir.path_join(sub).path_join(MANIFEST)):
					candidates.append(dir.path_join(sub))
			var files := DirAccess.get_files_at(dir)
			files.sort()
			for f in files:
				if f.to_lower().ends_with(".zip"):
					candidates.append(dir.path_join(f))
		for c in candidates:
			var m := read_zip(c, source) if str(c).to_lower().ends_with(".zip") else read(c, source)
			var key := str(m["id"]).replace("-", "_")
			if not seen.has(key):
				seen[key] = out.size()
				out.append(m)
				continue
			var kept: Dictionary = out[seen[key]]
			var winner := kept
			var loser := m
			if str(kept["source"]) != "command line" and bool(m["ok"]) and (not bool(kept["ok"]) or compare_versions(str(m["version"]), str(kept["version"])) > 0):
				winner = m
				loser = kept
				out[seen[key]] = m
			var also: Array = winner.get("also", [])
			also.append_array(loser.get("also", []))
			also.append("%s %s (%s, %s)" % [where_text(loser), str(loser["version"]), str(loser.get("zip", loser["dir"])),
				"given on the command line instead" if str(winner["source"]) == "command line" else "older" if compare_versions(str(loser["version"]), str(winner["version"])) < 0 else "the same version"])
			winner["also"] = also
	_migrate_once(out)
	return out


## Once, on the first scan under the off-by-default rule: in a settings file an earlier Zenith wrote,
## every add-on found with no saved state was on (the old rule), so it is saved as on and stays on.
## A fresh file is marked done when it is made (Settings.load_settings), so nothing is migrated there,
## and the mark (in [meta], apart from the add-on ids of [addons]) stops a later start from turning
## on an add-on dropped in since. Bundled ones keep bundled.json's state either way, and --addons ones
## aren't saved: they are on only while given, and a download sharing this settings file must still
## start its bundled ones as its bundled.json says (a source build gives Terrain Elevation with --addons).
static func _migrate_once(found: Array) -> void:
	if Settings.has_value("meta", Settings.ADDONS_OFF_BY_DEFAULT):
		return
	for m: Dictionary in found:
		var id := str(m["id"])
		if id == "" or not _valid_id(id) or state_of(m) != "default":
			continue
		Settings.set_value("addons", id, true, false)
		print("addons: %s was on before add-ons came off by default: kept on" % id)
	Settings.set_value("meta", Settings.ADDONS_OFF_BY_DEFAULT, true)


## "A zip" or "a folder", for the Add-ons menu.
static func where_text(m: Dictionary) -> String:
	return "A zip" if m.has("zip") else "A folder"


## -1, 0 or 1: version a older than, the same as or newer than b ("1.10.0" > "1.9.2"; parts that
## aren't numbers count as 0).
static func compare_versions(a: String, b: String) -> int:
	var pa := a.split(".")
	var pb := b.split(".")
	for i in maxi(pa.size(), pb.size()):
		var x := int(pa[i]) if i < pa.size() and pa[i].is_valid_int() else 0
		var y := int(pb[i]) if i < pb.size() and pb[i].is_valid_int() else 0
		if x != y:
			return 1 if x > y else -1
	return 0


## A zipped add-on's manifest, read from inside the zip: as read(), plus "zip" (the zip's path) and
## "inner" (the folder in the zip holding addon.json, "" at its root); "dir" is where it is
## unpacked (unpack() before starting it).
static func read_zip(zip_path: String, source := "") -> Dictionary:
	var base := zip_path.get_file().get_basename()
	var m := {"id": _id_from_zip_name(base), "name": base, "version": "", "api": 0, "entry": "",
		"description": "", "author": "", "dir": cache_root.path_join(base), "zip": zip_path, "inner": "",
		"source": source, "ok": false, "problem": ""}
	var zip := ZIPReader.new()
	if zip.open(zip_path) != OK:
		m["problem"] = "the zip can't be read (broken or not a zip)"
		return m
	var files := zip.get_files()
	var manifest := ""
	for f in files:
		if f == MANIFEST or (f.get_file() == MANIFEST and f.count("/") == 1):
			if manifest == "" or f.length() < manifest.length():
				manifest = f
	if manifest == "":
		zip.close()
		m["problem"] = "the zip has no addon.json at its root or one folder down"
		return m
	m["inner"] = manifest.get_base_dir() + "/" if manifest.contains("/") else ""
	var text := zip.read_file(manifest).get_string_from_utf8()
	_fill(m, text)
	if m["problem"] == "":
		var entry := str(m["inner"]) + str(m["entry"])
		if not files.has(entry):
			m["problem"] = "its entry script %s is missing from the zip" % str(m["entry"])
	m["ok"] = m["problem"] == ""
	zip.close()
	if m["ok"]:
		m["dir"] = cache_root.path_join(str(m["id"]))
	return m


static func _id_from_zip_name(base: String) -> String:
	# Factorio's naming: <name>_<version>.zip
	var cut := base.rfind("_")
	if cut > 0 and base.substr(cut + 1).replace(".", "").is_valid_int():
		return base.left(cut)
	return base


## Unpacks a zipped add-on into its cache folder (only when the zip changed since the last time).
## "" when it's ready, else why not.
static func unpack(m: Dictionary) -> String:
	if not m.has("zip"):
		return ""
	var zip_path := str(m["zip"])
	var dir := str(m["dir"])
	var stamp := "%d %d %s" % [FileAccess.get_modified_time(zip_path), FileAccess.get_file_as_bytes(zip_path).size(), str(m["version"])]
	var stamp_file := dir.path_join(".zenith-unpacked")
	if FileAccess.file_exists(stamp_file) and FileAccess.get_file_as_string(stamp_file) == stamp:
		return ""
	SafeDelete.remove_tree(dir)
	var zip := ZIPReader.new()
	if zip.open(zip_path) != OK:
		return "the zip can't be read"
	var inner := str(m["inner"])
	for f in zip.get_files():
		if not f.begins_with(inner) or f.ends_with("/"):
			continue
		var rel := f.substr(inner.length())
		if rel == "" or rel.contains("..") or rel.begins_with("/"):
			continue
		var target := dir.path_join(rel)
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var out := FileAccess.open(target, FileAccess.WRITE)
		if out == null:
			zip.close()
			return "it can't be unpacked to %s" % ProjectSettings.globalize_path(dir)
		out.store_buffer(zip.read_file(f))
		out.close()
	zip.close()
	var s := FileAccess.open(stamp_file, FileAccess.WRITE)
	if s != null:
		s.store_string(stamp)
		s.close()
	return ""


## Reads an add-on's scripts and shaders from disk again (a reload, docs/ADDONS.md "Testing"): Godot keeps
## every one it loaded, even with no instance left, so a plain load() gives the old code. A script loaded
## with CACHE_MODE_IGNORE is rewritten in place (live instances run the new code) and later load()s get
## it; twice, since a constant one script takes from another is compiled in, whichever came first. A
## script that didn't parse isn't read the second time (its error would be counted twice). Shaders and
## their includes need CACHE_MODE_REPLACE (IGNORE leaves the cached one). The paths read, in order.
static func refresh_scripts(dir: String) -> PackedStringArray:
	var scripts := PackedStringArray()
	var shaders := PackedStringArray()
	_files_under(dir, scripts, shaders)
	for f in shaders:
		ResourceLoader.load(f, "", ResourceLoader.CACHE_MODE_REPLACE)
	var good := PackedStringArray()
	for f in scripts:
		var s := ResourceLoader.load(f, "", ResourceLoader.CACHE_MODE_IGNORE) as Script
		if s != null and s.can_instantiate():
			good.append(f)
	for f in good:
		ResourceLoader.load(f, "", ResourceLoader.CACHE_MODE_IGNORE)
	var out := shaders.duplicate()
	out.append_array(scripts)
	return out


static func _files_under(dir: String, scripts: PackedStringArray, shaders: PackedStringArray) -> void:
	var subs := DirAccess.get_directories_at(dir)
	subs.sort()
	for sub in subs:
		if not sub.begins_with("."):
			_files_under(dir.path_join(sub), scripts, shaders)
	var files := DirAccess.get_files_at(dir)
	files.sort()
	for f in files:
		match f.get_extension().to_lower():
			"gd":
				scripts.append(dir.path_join(f))
			"gdshaderinc":
				shaders.insert(0, dir.path_join(f))  # before the shaders that include them
			"gdshader":
				shaders.append(dir.path_join(f))


## An add-on's manifest: {id, name, version, api, entry, description, author, dir, source,
## ok (bool), problem (why it can't load, "" when it can)}.
static func read(dir: String, source := "") -> Dictionary:
	var m := {"id": dir.get_file(), "name": dir.get_file(), "version": "", "api": 0, "entry": "",
		"description": "", "author": "", "dir": dir, "source": source, "ok": false, "problem": ""}
	var text := FileAccess.get_file_as_string(dir.path_join(MANIFEST))
	_fill(m, text)
	m["ok"] = m["problem"] == ""
	return m


## Reads addon.json's text into a manifest: its fields, and "problem" when it can't load.
static func _fill(m: Dictionary, text: String) -> void:
	var json := JSON.new()  # an instance: a broken file is reported here, not as an engine error
	var parsed = json.data if text != "" and json.parse(text) == OK else null
	if not parsed is Dictionary:
		m["problem"] = "its addon.json isn't valid JSON"
		return
	var j: Dictionary = parsed
	for key in ["id", "name", "version", "entry", "description", "author"]:
		if j.has(key) and j[key] != null:
			m[key] = str(j[key])
	m["api"] = float(j.get("api", 0)) if (j.get("api") is float or j.get("api") is int) else 0.0
	m["dependency_strings"] = j.get("dependencies", [])
	m["dependencies"] = parse_dependencies(m["dependency_strings"])["list"]
	m["problem"] = problem_of(m)


## Why a manifest can't be loaded, or "".
static func problem_of(m: Dictionary) -> String:
	var id := str(m["id"])
	if id == "" or not _valid_id(id):
		return "its id \"%s\" must be lower case letters, digits, - and _" % id
	if str(m["version"]) == "":
		return "its addon.json has no version"
	if float(m["api"]) <= 0.0:
		return "its addon.json doesn't say which add-on API it needs (\"api\": %d)" % API_VERSION
	if float(m["api"]) > API_LEVEL + 0.0001:
		return "it needs a newer Zenith (add-on API %s; this Zenith has %s)" % [_level_text(float(m["api"])), _level_text(API_LEVEL)]
	var deps := dependencies_problem(m)
	if deps != "":
		return deps
	var entry := str(m["entry"])
	if entry == "" or not entry.ends_with(".gd"):
		return "its addon.json has no entry script (a .gd file)"
	if not m.has("zip") and not FileAccess.file_exists(str(m["dir"]).path_join(entry)):  # a zip's is checked inside it
		return "its entry script %s is missing" % entry
	return ""


static func _level_text(v: float) -> String:
	return str(int(v)) if v == floorf(v) else str(snappedf(v, 0.01))


static func _valid_id(id: String) -> bool:
	for c in id:
		if not ID_CHARS.contains(c):
			return false
	return true


## As switched in the Add-ons menu; until then a bundled add-on as the download says (bundled.json)
## and any other off (on with `--addons-default=on`). Add-ons given with --addons are always on.
static func enabled(m: Dictionary) -> bool:
	var decided := state_of(m)
	match decided:
		"command line":
			return true
		"saved":
			return bool(Settings.get_value("addons", str(m["id"])))
		"bundled":
			return bool(bundled_defaults()[str(m["id"])])
	return default_on()


## What decides whether an add-on is on: "command line" (given with --addons: always on), "saved"
## (switched in the Add-ons menu), "bundled" (the download's bundled.json) or "default" (nobody has
## switched it: off, or on with --addons-default=on).
static func state_of(m: Dictionary) -> String:
	if str(m.get("source", "")) == "command line":
		return "command line"
	var id := str(m["id"])
	if Settings.has_value("addons", id):
		return "saved"
	if bundled_defaults().has(id):
		return "bundled"
	return "default"


## Whether an add-on nobody switched is on: off, or on with `--addons-default=on` (the old rule).
## Tests set default_on_override (1 on, 0 off).
static var default_on_override := -1


static func default_on() -> bool:
	if default_on_override >= 0:
		return default_on_override == 1
	return Settings.arg_value("--addons-default=") == "on"


## True for an add-on found that the player hasn't switched yet and the download doesn't bundle:
## off until switched on (unless `--addons-default=on`), and its page says so.
static func is_new(m: Dictionary) -> bool:
	return state_of(m) == "default"


## Where an add-on came from, for its page: "A zip in Zenith's user folder" and so on.
static func origin_text(m: Dictionary) -> String:
	var where := where_text(m)
	match str(m.get("source", "")):
		"user":
			return where + " in your user folder's addons"
		"Zenith":
			return where + " in Zenith's own addons folder"
		"command line":
			return where + " given with --addons"
	return where


## The download's defaults for its bundled add-ons: {id: on?} from <Zenith's folder>/addons/bundled.json
## (none in a checkout, or when it can't be read).
static func bundled_defaults(path := "") -> Dictionary:
	if path == "":
		path = bundled_file if bundled_file != "" else Paths.repo_dir().path_join("addons/bundled.json")
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


static func set_enabled(id: String, on: bool) -> void:
	Settings.set_value("addons", id, on)


# --- dependencies (addon.json's "dependencies", in Factorio's info.json form; docs/ADDONS.md) -------

## Dependencies are checked and order the start (addon_host.gd). `--addon-requires=off`: add-ons load
## without checking, in the order they are found, as before (tests set it).
static var requires_on := not OS.get_cmdline_user_args().has("--addon-requires=off")
## Factorio's prefixes: none required, ? optional, (?) optional and hidden, ! incompatible, ~ required
## without affecting the order, + recommended (Factorio's launcher only suggests it: optional here).
const PREFIXES := ["(?)", "!", "?", "~", "+"]
const OPS := ["<=", ">=", "<", ">", "="]
## A Factorio mod's name: letters, digits, - and _ (mod:<name>).
const MOD_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
const SHAPE := "\"[prefix] <id or mod:name> [<op> <version>]\" (prefixes ! ? (?) ~ +; ops < <= = >= >)"


## addon.json's dependencies read: {list: [{prefix, name, mod (a Factorio mod), op, version, text}],
## problem: "" or why one can't be read}. A list as Factorio's info.json writes it:
## ["cinematic-camera >= 0.3.0", "? terrain-elevation", "mod:space-age >= 2.1.0", "! old-camera"].
static func parse_dependencies(raw: Variant) -> Dictionary:
	var list: Array = []
	if not raw is Array:
		return {"list": list, "problem": "its addon.json's dependencies must be a list of strings"}
	var seen := {}
	for item in raw:
		if not item is String:
			return {"list": list, "problem": "its addon.json's dependencies must be a list of strings (%s isn't one)" % JSON.stringify(item)}
		var d := parse_dependency(item)
		if d.has("problem"):
			return {"list": list, "problem": str(d["problem"])}
		var key := ("mod:" if d["mod"] else "") + str(d["name"]).replace("-", "_")
		if seen.has(key):
			return {"list": list, "problem": "its dependencies name %s twice" % ("the Factorio mod " + str(d["name"]) if d["mod"] else str(d["name"]))}
		seen[key] = true
		list.append(d)
	return {"list": list, "problem": ""}


## One dependency string read, or {problem}.
static func parse_dependency(text: String) -> Dictionary:
	var rest := text.strip_edges()
	var quoted := "\"%s\"" % text
	if rest == "":
		return {"problem": "its dependency %s is empty" % quoted}
	var prefix := ""
	for p: String in PREFIXES:
		if rest.begins_with(p):
			prefix = p
			rest = rest.substr(p.length()).strip_edges()
			break
	var cut := -1
	for c in ["<", ">", "="]:
		var at := rest.find(c)
		if at >= 0 and (cut < 0 or at < cut):
			cut = at
	var name := rest if cut < 0 else rest.left(cut).strip_edges()
	var op := ""
	var version := ""
	if cut >= 0:
		var tail := rest.substr(cut)
		for o: String in OPS:
			if tail.begins_with(o):
				op = o
				break
		version = tail.substr(op.length()).strip_edges()
		if not _is_version(version):
			return {"problem": "its dependency %s must be %s" % [quoted, SHAPE]}
	if name == "":
		return {"problem": "its dependency %s names nothing: it must be %s" % [quoted, SHAPE]}
	if name.contains(" ") or name.contains("\t"):
		return {"problem": "its dependency %s must be %s" % [quoted, SHAPE]}
	var is_mod := name.begins_with("mod:")
	if is_mod:
		name = name.substr(4)
		if name == "" or not _only(name, MOD_CHARS):
			return {"problem": "its dependency %s must name a Factorio mod after mod: (letters, digits, - and _)" % quoted}
	elif not _valid_id(name):
		return {"problem": "its dependency %s names \"%s\": an add-on's id is lower case letters, digits, - and _ (a Factorio mod is mod:<name>)" % [quoted, name]}
	return {"prefix": prefix, "name": name, "mod": is_mod, "op": op, "version": version, "text": text.strip_edges()}


static func _is_version(v: String) -> bool:
	if v == "":
		return false
	for part in v.split("."):
		if part == "" or not part.is_valid_int() or part.begins_with("-") or part.begins_with("+"):
			return false
	return true


static func _only(text: String, chars: String) -> bool:
	for c in text:
		if not chars.contains(c):
			return false
	return true


## Why a manifest's dependencies can't be read, or "" (also when --addon-requires=off: not read then).
static func dependencies_problem(m: Dictionary) -> String:
	if not requires_on:
		return ""
	var parsed := parse_dependencies(m.get("dependency_strings", []))
	if str(parsed["problem"]) != "":
		return str(parsed["problem"])
	for d: Dictionary in parsed["list"]:
		if not d["mod"] and same_id(str(d["name"]), str(m["id"])):
			return "its dependency \"%s\" names the add-on itself" % d["text"]
	return ""


## Ids are compared with - as _ (scan's duplicate rule).
static func same_id(a: String, b: String) -> bool:
	return a.replace("-", "_") == b.replace("-", "_")


## Optional (?, (?) and +): never refuses when absent.
static func is_optional(d: Dictionary) -> bool:
	return ["?", "(?)", "+"].has(str(d["prefix"]))


## Required (none, ~): refuses when absent.
static func is_required(d: Dictionary) -> bool:
	return ["", "~"].has(str(d["prefix"]))


## Whether `installed` fits the dependency's version ("" fits nothing that asks for one).
static func version_fits(d: Dictionary, installed: String) -> bool:
	var op := str(d["op"])
	if op == "":
		return true
	if installed == "":
		return false
	var c := compare_versions(installed, str(d["version"]))
	match op:
		"<":
			return c < 0
		"<=":
			return c <= 0
		"=":
			return c == 0
		">=":
			return c >= 0
		">":
			return c > 0
	return true


## "0.3.0 or newer" and so on; "" without a version.
static func version_text(d: Dictionary) -> String:
	var v := str(d["version"])
	match str(d["op"]):
		"<":
			return "older than " + v
		"<=":
			return v + " or older"
		"=":
			return v
		">=":
			return v + " or newer"
		">":
			return "newer than " + v
	return ""


## The add-ons `m` depends on that set the order: required ones (not ~) found, and optional ones found and
## switched on, as Factorio's chain depth counts them. [manifest...] from `found`.
static func order_deps(m: Dictionary, found: Array) -> Array:
	var out: Array = []
	for d: Dictionary in m.get("dependencies", []):
		if d["mod"] or not (str(d["prefix"]) == "" or is_optional(d)):
			continue
		for other: Dictionary in found:
			if other != m and same_id(str(other["id"]), str(d["name"])):
				if str(d["prefix"]) == "" or (bool(other["ok"]) and enabled(other)):
					out.append(other)
				break
	return out


## Found add-ons in the order they start: by the depth of their dependency chains (none first), as
## Factorio orders its mods; ties keep the order they were found in (Factorio sorts ties by name), so
## without dependencies the order is exactly scan's. Stopping goes the other way. Add-ons in a circle
## count as deep as the circle reaches (they are refused: cycles()).
static func order(found: Array) -> Array:
	var depth := {}  # index in found -> depth
	var by_depth := {}
	var most := 0
	for i in found.size():
		var dd := _depth(found, i, depth, {})
		most = maxi(most, dd)
		var bucket: Array = by_depth.get(dd, [])
		bucket.append(found[i])
		by_depth[dd] = bucket
	var out: Array = []
	for dd in most + 1:
		out.append_array(by_depth.get(dd, []))
	return out


static func _depth(found: Array, i: int, depth: Dictionary, visiting: Dictionary) -> int:
	if depth.has(i):
		return int(depth[i])
	if visiting.has(i):
		return 0  # a circle: cut here
	visiting[i] = true
	var dd := 0
	for other in order_deps(found[i], found):
		dd = maxi(dd, _depth(found, found.find(other), depth, visiting) + 1)
	visiting.erase(i)
	depth[i] = dd
	return dd


## Add-ons in a dependency circle (the order's edges): {id: [the other ids in its circle]}.
static func cycles(found: Array) -> Dictionary:
	var reach := {}  # index -> {index: true} reachable through order_deps
	for i in found.size():
		var seen := {}
		var todo: Array = [i]
		while not todo.is_empty():
			var at: int = todo.pop_back()
			for other in order_deps(found[at], found):
				var j := found.find(other)
				if not seen.has(j):
					seen[j] = true
					todo.append(j)
		reach[i] = seen
	var out := {}
	for i in found.size():
		if not (reach[i] as Dictionary).has(i):
			continue
		var others: Array = []
		for j in found.size():
			if j != i and (reach[i] as Dictionary).has(j) and (reach[j] as Dictionary).has(i):
				others.append(str(found[j]["id"]))
		out[str(found[i]["id"])] = others
	return out


## The add-on page's "Needs:" line, "" without dependencies (hidden optional ones aren't named, as in
## Factorio). `name_of` gives an add-on's name from its id.
static func needs_text(m: Dictionary, name_of := Callable()) -> String:
	var needs := PackedStringArray()
	var optional := PackedStringArray()
	var never := PackedStringArray()
	for d: Dictionary in m.get("dependencies", []):
		if str(d["prefix"]) == "(?)":
			continue
		var who := ("the Factorio mod " + str(d["name"])) if d["mod"] else (str(name_of.call(str(d["name"]))) if name_of.is_valid() else str(d["name"]))
		var v := version_text(d)
		if v != "":
			who += " " + v
		if is_required(d):
			needs.append(who)
		elif is_optional(d):
			optional.append(who)
		else:
			never.append(who)
	var parts := PackedStringArray()
	if not needs.is_empty():
		parts.append(", ".join(needs))
	if not optional.is_empty():
		parts.append("works with " + ", ".join(optional) + " if there")
	if not never.is_empty():
		parts.append("not with " + ", ".join(never))
	return "" if parts.is_empty() else "Needs: " + "; ".join(parts)
