extends RefCounted
## Keeps a test run apart from the rest of the PC. user:// and the folders Zenith looks for
## Factorio's config and mods in follow APPDATA and its Linux and macOS equivalents, read each time
## they are used, so a test pointing them at a fresh folder of its own stops sharing a settings
## file with the real game and every other worktree's runs, and stops reading the player's
## config.ini and mods folder (246 zips once broke 63 checks).
##
## The Factorio install itself is still found (Steam's, through the registry): some checks read its
## real pictures when there is one, and all of them pass without one, as in CI.

const Paths := preload("res://scripts/menu/paths.gd")

## A run's folder older than this (seconds) is left over: runs stop themselves long before.
const LEFT_BEHIND := 3600

static var _root := ""


## Moves user:// to a new folder of this run's, and clears any left by runs that were killed. (By
## age: on Windows OS.is_process_running only knows this process's own children.)
static func isolate(test_name: String) -> void:
	var base := OS.get_temp_dir().path_join("zenith-tests")
	if DirAccess.dir_exists_absolute(base):
		var old := int(Time.get_unix_time_from_system()) - LEFT_BEHIND
		for dir in DirAccess.get_directories_at(base):
			if FileAccess.get_modified_time(base.path_join(dir)) < old:
				_remove_tree(base.path_join(dir))
	_root = base.path_join("%s-%d" % [test_name, OS.get_process_id()])
	_remove_tree(_root)
	DirAccess.make_dir_recursive_absolute(_root)
	for variable in ["APPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "HOME"]:
		OS.set_environment(variable, _root)
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir().path_join("logs"))
	Paths.user_data_dir = OS.get_user_data_dir()
	# Godot's own log stays where it was opened: a stand-in for what reads user://logs (bug_report.gd).
	FileAccess.open("user://logs/godot.log", FileAccess.WRITE).store_string("a test run\n")


## Removes the run's folder when the test ends.
static func clean() -> void:
	if _root != "":
		_remove_tree(_root)


static func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for dir in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(dir))
	for file in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)
