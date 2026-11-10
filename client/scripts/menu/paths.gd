extends RefCounted
## Where things are: factorio.exe (found like server/run-server.ps1 does: every Steam library,
## then the standalone installer's folder; Settings → Factorio overrides it), the repo's mod and
## server folders, the server's write-data folder and saves, and Factorio's own saves.
##
## Command-line options (after `--`): --factorio=<factorio.exe or install folder>
## --server-data=<dir> --saves-dir=<dir>, for tests that must not touch the normal folders.

const Settings := preload("res://scripts/menu/settings.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")

const EXE := "bin/x64/factorio.exe"


## Where the mod and server folders are: the repo checkout the client runs from (client/..), or in
## an exported build (tools/release/package.py) the folder Zenith.exe sits in, which holds `mod/`
## and `server/` beside it.
static func repo_dir() -> String:
	if OS.has_feature("template"):
		var here := OS.get_executable_path().get_base_dir()
		if OS.get_name() == "macOS" and here.ends_with(".app/Contents/MacOS"):
			return here.path_join("../../..").simplify_path()  # beside Zenith.app
		return here
	return ProjectSettings.globalize_path("res://").path_join("..").simplify_path()


static func mod_dir() -> String:
	return repo_dir().path_join("mod/factorio-3d-bridge")


static func server_settings_file() -> String:
	return repo_dir().path_join("server/server-settings.json")


## True in an exported build: its servers' data and saves are kept in Zenith's user folder
## (user://, on Windows %APPDATA%\Godot\app_userdata\Zenith, beside settings.cfg), so they outlive
## an update, which unpacks into a new folder. A checkout keeps them in server/, where
## run-server.ps1 and the tools look. Tests set it.
static var keep_in_user_data := OS.has_feature("template")
## The user folder that keep_in_user_data uses (tests point it elsewhere).
static var user_data_dir := OS.get_user_data_dir()
static var _moved := false


## The server's config, logs, mods link and RCON password, apart from the normal game's.
static func server_data_dir() -> String:
	var dir := Settings.arg_value("--server-data=")
	if dir == "":
		dir = str(Settings.get_value("factorio", "server_data"))
	if dir != "":
		return _absolute(dir)
	if keep_in_user_data:
		_move_once()
	return default_server_data_dir()


## The server data folder when none is set: Zenith's user folder in a download, server/data in a
## checkout.
static func default_server_data_dir() -> String:
	return user_data_dir.path_join("server-data") if keep_in_user_data else repo_dir().path_join("server/data")


static func saves_dir() -> String:
	var dir := Settings.arg_value("--saves-dir=")
	if dir == "":
		dir = str(Settings.get_value("factorio", "saves"))
	if dir != "":
		return _absolute(dir)
	if keep_in_user_data:
		_move_once()
	return default_saves_dir()


## The saves folder when none is set, as default_server_data_dir().
static func default_saves_dir() -> String:
	return user_data_dir.path_join("saves") if keep_in_user_data else repo_dir().path_join("server/saves")


## Once, while the user folder has no saves and no server mod list yet: copies what earlier
## versions kept beside Zenith.exe (server/saves, the server's own mods, their mod-list.json and
## mod settings) into it, so updating in place keeps them. Saves in folders keep their folders.
## The originals stay where they were. The bridge mod's link is made again at each start.
static func _move_once() -> void:
	if not _moved:
		_moved = true
		move_from_install(repo_dir())


## What _move_once does, from the folder `install` (an older Zenith's, holding server/).
static func move_from_install(install: String) -> void:
	var old_saves := install.path_join("server/saves")
	var new_saves := user_data_dir.path_join("saves")
	if DirAccess.dir_exists_absolute(old_saves) and not _has_zip(new_saves):
		_copy_tree(old_saves, new_saves, func(f: String) -> bool: return f.ends_with(".zip"))
	var old_mods := install.path_join("server/data/mods")
	var new_mods := user_data_dir.path_join("server-data/mods")
	if DirAccess.dir_exists_absolute(old_mods) and not FileAccess.file_exists(new_mods.path_join("mod-list.json")):
		DirAccess.make_dir_recursive_absolute(new_mods)
		var dir := DirAccess.open(old_mods)
		if dir != null:
			for f in dir.get_files():
				if f.ends_with(".zip") or f == "mod-list.json" or f == "mod-settings.dat":
					DirAccess.copy_absolute(old_mods.path_join(f), new_mods.path_join(f))


static func _has_zip(dir_path: String) -> bool:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return false
	for f in dir.get_files():
		if f.ends_with(".zip"):
			return true
	for sub in dir.get_directories():
		if _has_zip(dir_path.path_join(sub)):
			return true
	return false


## Copies the files `keep` accepts from `from` into `to`, folders and all, without replacing any.
static func _copy_tree(from: String, to: String, keep: Callable) -> void:
	var dir := DirAccess.open(from)
	if dir == null:
		return
	DirAccess.make_dir_recursive_absolute(to)
	for f in dir.get_files():
		if keep.call(f) and not FileAccess.file_exists(to.path_join(f)):
			DirAccess.copy_absolute(from.path_join(f), to.path_join(f))
	for sub in dir.get_directories():
		_copy_tree(from.path_join(sub), to.path_join(sub), keep)


## The player's own Factorio mods folder (beside Factorio's saves), or "".
static func factorio_mods_dir() -> String:
	var saves := factorio_saves_dir()
	if saves == "":
		return ""
	var mods := saves.get_base_dir().path_join("mods")
	return mods if DirAccess.dir_exists_absolute(mods) else ""


## Factorio's own saves (%APPDATA%\Factorio\saves, ~/.factorio/saves), or "".
static func factorio_saves_dir() -> String:
	var candidates: Array[String] = []
	var appdata := OS.get_environment("APPDATA")
	if appdata != "":
		candidates.append(appdata.replace("\\", "/").path_join("Factorio/saves"))
	var home := OS.get_environment("HOME")
	if home != "":
		candidates.append(home.path_join(".factorio/saves"))
		candidates.append(home.path_join("Library/Application Support/factorio/saves"))
	for dir in candidates:
		if DirAccess.dir_exists_absolute(dir):
			return dir
	return ""


## factorio.exe: the setting or --factorio, else the install the icons come from, else Steam's
## libraries and the standalone folder. "" when there is none.
static func factorio_exe() -> String:
	var configured := Settings.arg_value("--factorio=")
	if configured == "":
		configured = str(Settings.get_value("factorio", "executable"))
	if configured != "":
		return _exe_in(configured)
	return find_factorio_exe()


## factorio.exe from --factorio or the setting alone, "" when neither is set (no searching, so
## ItemIcons can ask while it looks for the data folder).
static func configured_exe() -> String:
	var configured := Settings.arg_value("--factorio=")
	if configured == "":
		configured = str(Settings.get_value("factorio", "executable"))
	return _exe_in(configured) if configured.strip_edges() != "" else ""


## Searching only, without the setting (shown in Settings as what "automatic" finds).
static func find_factorio_exe() -> String:
	var candidates: Array[String] = []
	var data := ItemIcons.factorio_data_dir()
	if data != "":
		candidates.append(data.path_join("..").simplify_path().path_join(EXE))
	for lib in _steam_libraries():
		candidates.append(lib.path_join("steamapps/common/Factorio").path_join(EXE))
		# Linux and macOS (the unsupported downloads): Steam's own folder names there.
		candidates.append(lib.path_join("steamapps/common/Factorio/bin/x64/factorio"))
		candidates.append(lib.path_join("steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio"))
	candidates.append("C:/Program Files/Factorio".path_join(EXE))
	candidates.append(OS.get_environment("HOME").path_join("factorio/bin/x64/factorio"))
	candidates.append("/Applications/factorio.app/Contents/MacOS/factorio")
	for c in candidates:
		if FileAccess.file_exists(c):
			return c
	return ""


## The install's data folder (read-data in config.ini) for a factorio.exe: bin/x64/../../data, or
## on macOS factorio.app/Contents/MacOS/../data.
static func read_data_dir(exe: String) -> String:
	var bin := exe.get_base_dir()
	if bin.ends_with("Contents/MacOS"):
		return bin.path_join("../data").simplify_path()
	return bin.path_join("../../data").simplify_path()


## Factorio's version from the install's base mod, e.g. "2.1.23", or "".
static func factorio_version(exe: String) -> String:
	var info := read_data_dir(exe).path_join("base/info.json")
	if not FileAccess.file_exists(info):
		return ""
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(info))
	return str(parsed.get("version", "")) if parsed is Dictionary else ""


## A path given as the install folder, its bin folder or the exe itself.
static func _exe_in(path: String) -> String:
	path = _absolute(path)
	if FileAccess.file_exists(path):
		return path
	for sub in [EXE, "x64/factorio.exe", "factorio.exe", "bin/x64/factorio", "Contents/MacOS/factorio",
			"factorio.app/Contents/MacOS/factorio"]:
		if FileAccess.file_exists(path.path_join(sub)):
			return path.path_join(sub)
	return path  # missing: the launcher reports it with this path


static func _absolute(path: String) -> String:
	path = path.strip_edges().replace("\\", "/")
	if path.is_relative_path():
		path = repo_dir().path_join(path)
	return path.simplify_path()


## Steam's folder from the registry (HKCU\Software\Valve\Steam SteamPath) or its default, then
## the other libraries listed in libraryfolders.vdf (Linux's and macOS's own folders elsewhere).
static func _steam_libraries() -> Array[String]:
	var out: Array[String] = []
	if OS.get_name() != "Windows":
		var home := OS.get_environment("HOME")
		for steam in [home.path_join(".steam/steam"), home.path_join(".local/share/Steam"),
				home.path_join("Library/Application Support/Steam")]:
			out.append(steam)
			out.append_array(ItemIcons._steam_libraries(steam.path_join("steamapps/libraryfolders.vdf")))
		return out
	var steam := "C:/Program Files (x86)/Steam"
	var output: Array = []
	if OS.execute("reg", ["query", "HKCU\\Software\\Valve\\Steam", "/v", "SteamPath"], output) == 0 and not output.is_empty():
		var m := RegEx.create_from_string("SteamPath\\s+REG_SZ\\s+(.+)").search(str(output[0]))
		if m != null:
			steam = m.get_string(1).strip_edges().replace("\\", "/")
	out.append(steam)
	out.append_array(ItemIcons._steam_libraries(steam.path_join("steamapps/libraryfolders.vdf")))
	return out
