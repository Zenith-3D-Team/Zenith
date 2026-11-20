extends RefCounted
## Deletes a folder and everything in it without ever going through a link. DirAccess.get_directories_at
## lists a junction or symlink as a plain folder, so a delete that recursed into one emptied its target
## (a mod folder, the player's Factorio folder). Here a link, the folder itself or one inside it, is
## removed alone: DirAccess.remove_absolute removes the link (RemoveDirectory on Windows), never what it
## points at. The same rule as tools/safe_delete.py. Used by addon_loader.gd and model_packs.gd.


## Removes `path` and what it holds; a link there (or under it) loses the link only.
static func remove_tree(path: String) -> void:
	path = path.replace("\\", "/").trim_suffix("/")
	if path == "":
		return
	if is_link(path):
		DirAccess.remove_absolute(path)
		return
	if not DirAccess.dir_exists_absolute(path):
		return
	var dir := DirAccess.open(path)
	if dir != null:
		for d in DirAccess.get_directories_at(path):
			var child := path.path_join(d)
			if dir.is_link(d):
				DirAccess.remove_absolute(child)
			else:
				remove_tree(child)
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


## Whether `path` is a junction or symlink (asked of the folder holding it).
static func is_link(path: String) -> bool:
	path = path.replace("\\", "/").trim_suffix("/")
	var parent := DirAccess.open(path.get_base_dir())
	return parent != null and parent.is_link(path.get_file())
