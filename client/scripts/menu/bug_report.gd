## Report a bug (main menu and Esc menu): the recent logs packed into one zip, GitHub's new issue page
## opened with the versions filled in, and the zip shown in the file manager to drag into the issue
## (a link can't attach a file). In the zip: Zenith's log of this run and of the runs before it
## (a crash ends a run, so the one before is often the one that matters), the server's log
## (factorio-current.log and -previous) and the player's own Factorio log (hybrid single-player),
## and system.txt (versions, OS, graphics card).

const Paths := preload("res://scripts/menu/paths.gd")

const ISSUES := "https://github.com/Zenith-3D-Team/Zenith/issues/new"
const OUT_DIR := "user://bug-reports"
## Zenith's earlier runs' logs taken beside this run's.
const EARLIER_LOGS := 2


## Versions and the machine, one per line. `public`: for the issue's text, without the install's
## path (it may hold the player's user name) or the window.
static func system_text(public := false) -> String:
	var exe := Paths.factorio_exe()
	var factorio := "Factorio %s" % (Paths.factorio_version(exe) if exe != "" else "not found")
	if not public:
		factorio += " (%s)" % (exe if exe != "" else "-")
	var lines := PackedStringArray([
		"Zenith %s" % str(ProjectSettings.get_setting("application/config/version", "?")),
		factorio,
		"%s %s" % [OS.get_name(), OS.get_version()],
		"CPU: %s, %d threads" % [OS.get_processor_name(), OS.get_processor_count()],
		"Graphics: %s (%s), %s" % [RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_vendor(),
			RenderingServer.get_video_adapter_api_version()],
	])
	if Bridge.mod_version != "":
		# The bridge mod the last game ran (its welcome): a client and mod of different releases.
		lines.insert(1, "Zenith Bridge mod %s" % Bridge.mod_version)
	if not public:
		lines.append("Window: %s" % str(DisplayServer.window_get_size()))
	return "\n".join(lines) + "\n"


## Files to pack: [path on disk, name in the zip], those that exist.
static func log_files() -> Array:
	var out: Array = []
	var logs := ProjectSettings.globalize_path("user://logs")
	var current := logs.path_join("godot.log")
	if FileAccess.file_exists(current):
		out.append([current, "zenith/godot.log"])
	# Godot keeps earlier runs as godot<date>.log: the newest ones.
	var earlier: Array[String] = []
	for f in DirAccess.get_files_at(logs):
		if f.begins_with("godot") and f.ends_with(".log") and f != "godot.log":
			earlier.append(f)
	earlier.sort()
	for i in range(maxi(0, earlier.size() - EARLIER_LOGS), earlier.size()):
		out.append([logs.path_join(earlier[i]), "zenith/" + earlier[i]])
	var server := Paths.server_data_dir()
	for f in ["factorio-current.log", "factorio-previous.log"]:
		var p := server.path_join(f)
		if FileAccess.file_exists(p):
			out.append([p, "server/" + f])
	var own := Paths.factorio_saves_dir().get_base_dir()
	if own != "":
		var p := own.path_join("factorio-current.log")
		if FileAccess.file_exists(p):
			out.append([p, "factorio/factorio-current.log"])
	return out


## Packs the logs and system.txt into OUT_DIR; returns the zip's full path ("" when it couldn't).
static func make_bundle() -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var path := ProjectSettings.globalize_path(OUT_DIR).path_join("zenith-bug-report-%s.zip" % stamp)
	var zip := ZIPPacker.new()
	if zip.open(path) != OK:
		return ""
	zip.start_file("system.txt")
	zip.write_file(system_text().to_utf8_buffer())
	zip.close_file()
	for f in log_files():
		# A log being written is still readable; a file that can't be read is left out.
		var bytes := FileAccess.get_file_as_bytes(str(f[0]))
		if bytes.is_empty():
			continue
		zip.start_file(str(f[1]))
		zip.write_file(bytes)
		zip.close_file()
	zip.close()
	return path


## GitHub's new issue page with the bug report template's headings and the versions filled in.
static func issue_url(zip_name: String) -> String:
	var versions := system_text(true).strip_edges().replace("\n", ", ")
	var body := "**What happened**\n\n\n**What you expected**\n\n\n**How to make it happen** (if you know)\n\n\n" \
		+ "**Versions:** %s. Space Age yes/no, other mods:\n\n" % versions \
		+ "**Logs:** drag `%s` here (Zenith opened its folder).\n" % zip_name
	return ISSUES + "?labels=bug&title=&body=" + body.uri_encode()


## The whole thing: the zip, the issue page, the zip's folder. Returns the zip's path.
static func open() -> String:
	var path := make_bundle()
	OS.shell_open(issue_url(path.get_file() if path != "" else "the logs"))
	if path != "":
		OS.shell_show_in_file_manager(path)
	else:
		OS.shell_show_in_file_manager(ProjectSettings.globalize_path("user://logs"))
	return path
