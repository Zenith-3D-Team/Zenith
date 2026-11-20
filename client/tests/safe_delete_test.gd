extends SceneTree
## safe_delete.gd never deletes through a link: a temp folder holding a junction (a symlink off Windows) to a
## temp target, the link at the top and deeper down, is removed and the target keeps its files. The way
## tools/test_safe_delete.py builds its links (cmd /c mklink /J). Also proves the setup is real: the
## old recursive delete (addon_loader.gd's and model_packs.gd's copies before) empties a target through it.
## All in a temp folder of this run's. Run headless:
##   godot --headless --path client -s res://tests/safe_delete_test.gd
## Prints "SAFE DELETE FAILS: 0" when all pass (or skips without a way to make links); quits with 1 otherwise.

const SafeDelete := preload("res://scripts/safe_delete.gd")

var _fails := 0


func _check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _initialize() -> void:
	var base := OS.get_temp_dir().replace("\\", "/").path_join("zenith-tests/safe-delete-%d" % OS.get_process_id())
	SafeDelete.remove_tree(base)  # a killed run's, by this PID
	DirAccess.make_dir_recursive_absolute(base)
	if not _link(base.path_join("probe-link"), _target(base, "probe")):
		print("skipped: links can't be made here")
		print("SAFE DELETE FAILS: 0")
		SafeDelete.remove_tree(base)
		quit(0)
		return
	DirAccess.remove_absolute(base.path_join("probe-link"))

	# 1. A folder with a link inside it (and one deeper down), removed whole.
	var t1 := _target(base, "t1")
	var data := base.path_join("data1")
	DirAccess.make_dir_recursive_absolute(data.path_join("saves"))
	_write(data.path_join("saves/a.zip"), "zip")
	_link(data.path_join("mods/factorio-3d-bridge"), t1)
	_link(data.path_join("deep/er/again"), t1)
	_check(SafeDelete.is_link(data.path_join("mods/factorio-3d-bridge")), "a junction counts as a link")
	_check(not SafeDelete.is_link(data.path_join("saves")), "a folder doesn't")
	SafeDelete.remove_tree(data)
	_check(not DirAccess.dir_exists_absolute(data), "the folder holding links is gone")
	_check(_intact(t1), "the links' target keeps its files")

	# 2. The path itself a link: the link goes, the target stays.
	var t2 := _target(base, "t2")
	var top := base.path_join("top-link")
	_link(top, t2)
	SafeDelete.remove_tree(top)
	_check(not DirAccess.dir_exists_absolute(top) and not SafeDelete.is_link(top), "a link given itself is removed")
	_check(_intact(t2), "its target keeps its files")

	# 3. A plain folder is still removed whole; a missing one is fine; a trailing slash too.
	var plain := base.path_join("plain")
	DirAccess.make_dir_recursive_absolute(plain.path_join("a/b"))
	_write(plain.path_join("a/b/c.txt"), "c")
	SafeDelete.remove_tree(plain + "/")
	_check(not DirAccess.dir_exists_absolute(plain), "a plain folder is removed")
	SafeDelete.remove_tree(base.path_join("not-there"))

	# 4. The setup is real: the old recursive delete empties a target through the same kind of link.
	var t3 := _target(base, "t3")
	var data3 := base.path_join("data3")
	_link(data3.path_join("mods/linked"), t3)
	_old_remove_tree(data3)
	_check(not _intact(t3), "the old delete empties a link's target (the bug this guards)")

	SafeDelete.remove_tree(base)
	_check(not DirAccess.dir_exists_absolute(base), "the run's temp folder is gone")
	print("SAFE DELETE FAILS: %d" % _fails)
	quit(1 if _fails > 0 else 0)


func _target(base: String, name: String) -> String:
	var t := base.path_join(name)
	DirAccess.make_dir_recursive_absolute(t.path_join("scripts"))
	_write(t.path_join("control.lua"), "-- control\n")
	_write(t.path_join("scripts/belt_sim.lua"), "-- belts\n")
	return t


func _intact(t: String) -> bool:
	return FileAccess.file_exists(t.path_join("control.lua")) and FileAccess.file_exists(t.path_join("scripts/belt_sim.lua"))


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## A junction at `at` to `to` (Windows), else a symlink; whether it is one now.
func _link(at: String, to: String) -> bool:
	DirAccess.make_dir_recursive_absolute(at.get_base_dir())
	var out: Array = []
	if OS.get_name() == "Windows":
		OS.execute("cmd", ["/c", "mklink", "/J", at.replace("/", "\\"), to.replace("/", "\\")], out, true)
	else:
		OS.execute("ln", ["-s", to, at], out, true)
	return SafeDelete.is_link(at)


## The delete addon_loader.gd and model_packs.gd had: it recurses into a link as into a folder.
static func _old_remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for d in DirAccess.get_directories_at(path):
		_old_remove_tree(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)
