@tool
extends RefCounted
## Rebuilds the GPU caches when shaders or the Godot version change: the first start of a new shader
## stamp deletes Godot's shader cache (user://shader_cache) and pipeline cache (user://vulkan,
## user://d3d12) and restarts cleanly, so every shader and pipeline is compiled fresh instead of read
## from an older build.
##
## Stamp composition (build_stamp()):
##   - Default (smart shader-hash): Godot version string + shader MD5 + "addons:" + addon_shader_hash().
##     In exported builds, reads the baked MD5 from res://data/shader_stamp.txt (written at export by
##     ZenithShaderHash) and falls back to exe/.pck size+mtime only if that file is missing. From source,
##     computes the MD5 directly over sorted res://**/*.gdshader and .gdshaderinc files.
##   - Legacy mode (--shader-refresh=build): game version + Godot version + exe/.pck size/mtime in
##     templates (or source shader MD5 from source) + "addons:" + addon_shader_hash().
##
## State file (user://build-stamp.txt):
##   stamp=<value>
##   warmed=<0|1>
##   driver=<rendering driver the warm-up ran on: d3d12, vulkan...>
## Each driver keeps its own pipeline cache (user://d3d12, user://vulkan), so a warm-up on one doesn't
## warm the other: switching Settings > Graphics > Renderer (or --rendering-driver) runs the staged
## warm-up once on the new driver without deleting anything. A file with no driver= line was warmed on
## Vulkan (every build before 0.3.1).
## Backward compatibility: an older single-line stamp file ("<stamp>\n", with no "warmed=" line) is
## read as that stamp with warmed=0, so upgrading triggers one staged warm-up and records warmed=1.
##
## The caches are read when the renderer starts, before any script, and the pipeline cache is written
## again when Godot shuts down normally, so deleting them in this run would do nothing: they are deleted,
## the same command line is started again, and this process waits for it hidden (wait_for_child): a
## launcher that waits on the process it started (launch.bat's start /wait, the editor's Run) would
## otherwise read the restart as the game closing. It draws, connects and loads nothing meanwhile, and
## when the new process ends it ends too with its exit code: OS.kill on 0 (no shutdown save of the
## pipeline cache it loaded at start over the new one's), quit(code) otherwise.
##
## Lock-safe deletion: each cache directory is deleted via SafeDelete.remove_tree_checked(). If any
## directory remains (e.g. a file locked by another process), a warning is printed and BUILD_FILE is
## NOT updated so the next launch retries cleanup, while passing --shader-refresh-restarted to the
## spawned child to prevent a restart loop in this session.
##
## Ultra-lightweight by design: NEVER preloads AddonHost, Paths, Settings, main.gd, or any .gdshader.
## Skips restarts/compilation in headless, web, --settings-file=, or --shader-refresh=off runs.

const SafeDelete := preload("res://scripts/safe_delete.gd")
const Switches := preload("res://scripts/switches.gd")

const BUILD_FILE := "user://build-stamp.txt"
const BAKED_HASH_FILE := "res://data/shader_stamp.txt"
const CACHE_DIRS := ["user://shader_cache", "user://vulkan", "user://d3d12"]

## Test overrides (leave at defaults in normal runs).
static var build_file_override := ""
static var cache_dirs_override: Array[String] = []
static var user_args_override: Variant = null
static var headless_override := -1
static var template_override := -1
static var baked_hash_file_override := ""
static var addon_roots_override: Variant = null
static var restart_runner_override: Callable = Callable()
static var driver_override := ""

## The restarted process this one waits for (0: none).
static var child_pid := 0


## Called early during startup (boot.gd / main.gd). True when a new process was started: this one
## then only waits for it (wait_for_child).
static func restart_if_new_build() -> bool:
	child_pid = 0
	var arg := _shader_refresh_arg()
	if arg == "off" or not _own_settings() or _is_headless() or OS.has_feature("web") or _has_user_arg("--shader-refresh-restarted"):
		return false
	var stamp := build_stamp()
	var build_file := _build_file()
	var info: Dictionary = _read_build_file(build_file)
	var had: String = str(info.get("stamp", ""))
	if had == stamp and arg != "force":
		return false
	var caches: Array[String] = []
	for d in _cache_dirs():
		if DirAccess.dir_exists_absolute(d) or SafeDelete.is_link(_globalize(d)):
			caches.append(d)
	if caches.is_empty():
		_write_build_file(build_file, stamp, 0)
		return false
	print("[shader-refresh] new build (%s, was %s): deleting %s and starting again" % [stamp, had if had != "" else "none", ", ".join(caches)])
	var failed: Array[String] = []
	for d in caches:
		if not SafeDelete.remove_tree_checked(_globalize(d)):
			failed.append(d)
	if failed.is_empty():
		_write_build_file(build_file, stamp, 0)
	else:
		printerr("[shader-refresh] couldn't delete cache dir(s) (%s); keeping old stamp so next start retries" % ", ".join(failed))
	var args := OS.get_cmdline_args()
	# Godot keeps engine options such as --path out of get_cmdline_args(): from source (the editor's
	# Godot running this project), the restart is told the project again, or it opens the project manager.
	if not OS.has_feature("template") and not args.has("--path"):
		var with_path := PackedStringArray(["--path", ProjectSettings.globalize_path("res://")])
		with_path.append_array(args)
		args = with_path
	# The same driver again: Godot keeps --rendering-driver (`--rendering-driver vulkan`, the way back to
	# Vulkan without the setting) out of get_cmdline_args() too, and the restart would otherwise start on
	# project.godot's / the Renderer setting's driver, not the one asked for.
	if not args.has("--rendering-driver") and current_driver() != "" and current_driver() != "dummy":
		var with_driver := PackedStringArray(["--rendering-driver", current_driver()])
		with_driver.append_array(args)
		args = with_driver
	var user := PackedStringArray()
	for a in _user_args():
		if a != "--shader-refresh=force" and a != "--shader-refresh-restarted" and a != "--shader-refresh-clean-failed":
			user.append(a)
	user.append("--shader-refresh-restarted")
	if not failed.is_empty():
		user.append("--shader-refresh-clean-failed")
	args.append("--")
	args.append_array(user)
	if restart_runner_override.is_valid():
		return bool(restart_runner_override.call(OS.get_executable_path(), args))
	var pid := OS.create_process(OS.get_executable_path(), args)
	if pid == -1:
		# No restart: this run goes on with whatever was cleared; the next start retries/rebuilds.
		printerr("[shader-refresh] couldn't start again; the next start rebuilds")
		return false
	child_pid = pid
	return true


## This process after the restart: its window hidden, nothing drawn or processed (the Bridge autoload
## included; it binds nothing until connect_to), polling the new process every 0.25 s and ending with
## its exit code when it ends. `host` is boot.gd's or main.gd's node.
static func wait_for_child(host: Node) -> void:
	# Default: this process ends at once, so no second window is left frozen on Godot's start screen
	# (hiding it didn't always work on Windows). `--shader-refresh-parent=wait` keeps the old waiting
	# parent for launchers that follow the first process id and want the game's exit code.
	if _arg_value("--shader-refresh-parent=") != "wait":
		print("[shader-refresh] started again as process %d; this one ends now" % child_pid)
		OS.kill(OS.get_process_id())
		return
	print("[shader-refresh] started again as process %d; this one waits for it" % child_pid)
	var win := host.get_window()
	win.mode = Window.MODE_MINIMIZED
	win.visible = false
	RenderingServer.render_loop_enabled = false
	OS.low_processor_usage_mode = true
	Engine.max_fps = 4
	var bridge := host.get_node_or_null("/root/Bridge")
	if bridge != null:
		bridge.set_process(false)
		bridge.set_physics_process(false)
	host.set_process(false)
	var timer := Timer.new()
	timer.wait_time = 0.25
	var poll := func() -> void:
		if OS.is_process_running(child_pid):
			return
		var code := 0
		if OS.has_method("get_process_exit_code"):  # Godot 4.4+
			code = int(OS.call("get_process_exit_code", child_pid))
		if code < 0:
			code = 0
		print("[shader-refresh] the restarted process ended (exit code %d)" % code)
		if code == 0:
			OS.kill(OS.get_process_id())
		else:
			host.get_tree().quit(code)
	timer.timeout.connect(poll)
	host.add_child(timer)
	timer.start()


## True when the startup warm-up should compile all shaders rather than skipping or loading cached only.
static func needs_compile() -> bool:
	if _is_headless() or OS.has_feature("web") or not _own_settings():
		return false
	var arg := _shader_refresh_arg()
	if arg == "off" or _warm_shaders_arg() == "off":
		return false
	if arg == "force":
		return true
	var info: Dictionary = _read_build_file(_build_file())
	if str(info.get("stamp", "")) != build_stamp():
		return true
	if int(info.get("warmed", 0)) != 1:
		return true
	if str(info.get("driver", "")) != current_driver():
		return true
	return not DirAccess.dir_exists_absolute(_shader_cache_dir())


## Records that the current build stamp finished shader warm-up (warmed=1), unless cache cleanup failed.
static func mark_warmed() -> void:
	if _is_headless() or OS.has_feature("web") or not _own_settings() or _shader_refresh_arg() == "off":
		return
	if _has_user_arg("--shader-refresh-clean-failed"):
		return
	_write_build_file(_build_file(), build_stamp(), 1, current_driver())


## The rendering driver this run draws with ("d3d12", "vulkan", ...).
static func current_driver() -> String:
	if driver_override != "":
		return driver_override
	return RenderingServer.get_current_rendering_driver_name()


## Returns the build stamp string (see header).
static func build_stamp() -> String:
	var godot_ver: String = str(Engine.get_version_info().get("string", ""))
	var parts: Array[String] = []
	if _shader_refresh_arg() == "build":
		parts.append(str(ProjectSettings.get_setting("application/config/version", "")))
		parts.append(godot_ver)
		if _is_template():
			_append_exe_pck_parts(parts)
		else:
			parts.append(source_shader_hash())
	else:
		parts.append(godot_ver)
		if _is_template():
			var baked := _read_baked_hash()
			if baked != "":
				parts.append(baked)
			else:
				_append_exe_pck_parts(parts)
		else:
			parts.append(source_shader_hash())
	parts.append("addons:" + addon_shader_hash())
	return " ".join(parts)


## Deterministic MD5 hex over sorted .gdshader and .gdshaderinc files under `root` (shared with export).
static func source_shader_hash(root: String = "res://") -> String:
	var files: Array[String] = []
	_shader_files(root, files)
	files.sort()
	return _md5_for_files(files)


## Deterministic MD5 hex over .gdshader and .gdshaderinc files across add-on directories, or "none".
## Uses canonical add-on-relative keys so switching worktrees or passing explicit --addons= paths
## keeps the same stamp when shader contents match.
static func addon_shader_hash(extra_dirs: Array = []) -> String:
	var entries := _collect_addon_shader_entries(extra_dirs)
	if entries.is_empty():
		return "none"
	return _md5_for_entries(entries)


## Returns existing add-on directories containing .gdshader files (deduplicated, sorted).
static func addon_shader_dirs() -> Array[String]:
	var entries := _collect_addon_shader_entries([])
	var seen := {}
	var dirs: Array[String] = []
	for entry in entries:
		var p: String = str(entry.get("path", ""))
		if not p.to_lower().ends_with(".gdshader"):
			continue
		var dir := p.get_base_dir()
		if dir != "" and DirAccess.dir_exists_absolute(dir) and not seen.has(dir):
			seen[dir] = true
			dirs.append(dir)
	dirs.sort()
	return dirs


static func _collect_addon_shader_entries(extra_dirs: Array = []) -> Array[Dictionary]:
	var by_key := {}
	for root in _addon_roots(extra_dirs):
		var found: Array[String] = []
		_shader_files(root, found)
		var is_single_addon := FileAccess.file_exists(root.path_join("addon.json"))
		var addon_name := root.get_file()
		for p in found:
			var norm := p.replace("\\", "/").simplify_path()
			var rel := norm.substr(root.length()).trim_prefix("/") if norm.begins_with(root) else norm
			var key: String = addon_name + "/" + rel if is_single_addon and addon_name != "" else rel
			if not by_key.has(key):
				by_key[key] = norm
	var keys: Array[String] = []
	for raw_key in by_key.keys():
		keys.append(str(raw_key))
	keys.sort()
	var entries: Array[Dictionary] = []
	for k in keys:
		entries.append({"key": k, "path": str(by_key[k])})
	return entries


static func _addon_roots(extra_dirs: Array = []) -> Array[String]:
	var raw: Array[String] = []
	if addon_roots_override is Array:
		var override_list: Array = addon_roots_override
		for d in override_list:
			raw.append(str(d))
	else:
		var given := _arg_value("--addons=")
		if given != "":
			for part in given.split(",", false):
				raw.append(part.strip_edges())
		raw.append("user://addons")
		raw.append("user://addons-cache")
		if _is_template():
			var exe_dir := OS.get_executable_path().get_base_dir()
			raw.append(exe_dir.path_join("addons"))
			if OS.get_name() == "macOS" and exe_dir.ends_with(".app/Contents/MacOS"):
				raw.append(exe_dir.path_join("../../..").simplify_path().path_join("addons"))
		else:
			var repo := ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()
			raw.append(repo.path_join("addons"))
			raw.append(repo.path_join("addons-src"))
	for d in extra_dirs:
		raw.append(str(d))
	var seen := {}
	var out: Array[String] = []
	for r in raw:
		var p := _normalize_dir(r)
		if p != "" and DirAccess.dir_exists_absolute(p) and not seen.has(p):
			seen[p] = true
			out.append(p)
	return out


static func _normalize_dir(path: String) -> String:
	var p := path.strip_edges()
	if p == "":
		return ""
	if p.begins_with("user://") or p.begins_with("res://"):
		p = ProjectSettings.globalize_path(p)
	return p.replace("\\", "/").trim_suffix("/").simplify_path()


static func _md5_for_entries(entries: Array[Dictionary]) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	for entry in entries:
		var key: String = str(entry.get("key", ""))
		var p: String = str(entry.get("path", ""))
		ctx.update(key.to_utf8_buffer())
		var bytes := FileAccess.get_file_as_bytes(p)
		if not bytes.is_empty():
			ctx.update(bytes)
	return ctx.finish().hex_encode()


static func _md5_for_files(files: Array[String]) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	for p in files:
		ctx.update(p.to_utf8_buffer())
		var bytes := FileAccess.get_file_as_bytes(p)
		if not bytes.is_empty():
			ctx.update(bytes)
	return ctx.finish().hex_encode()


static func _shader_files(dir: String, out: Array[String]) -> void:
	var subs := DirAccess.get_directories_at(dir)
	subs.sort()
	for d in subs:
		if not d.begins_with("."):
			_shader_files(dir.path_join(d), out)
	var files := DirAccess.get_files_at(dir)
	files.sort()
	for f in files:
		var lower := f.to_lower()
		if lower.ends_with(".gdshader") or lower.ends_with(".gdshaderinc"):
			out.append(dir.path_join(f))


static func _append_exe_pck_parts(parts: Array[String]) -> void:
	var exe := OS.get_executable_path()
	for p in [exe, exe.get_basename() + ".pck"]:
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			parts.append("%s:%d:%d" % [p.get_file(), f.get_length(), FileAccess.get_modified_time(p)])
			f.close()


static func _read_baked_hash() -> String:
	var path := baked_hash_file_override if baked_hash_file_override != "" else BAKED_HASH_FILE
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path).strip_edges()


static func _read_build_file(path: String) -> Dictionary:
	var out := {"stamp": "", "warmed": 0, "driver": "vulkan"}
	if not FileAccess.file_exists(path):
		return out
	var text := FileAccess.get_file_as_string(path)
	var has_kv := false
	var legacy_line := ""
	for raw_line in text.split("\n"):
		var line := raw_line.replace("\r", "").strip_edges()
		if line == "":
			continue
		if line.begins_with("stamp="):
			out["stamp"] = line.substr("stamp=".length()).strip_edges()
			has_kv = true
		elif line.begins_with("warmed="):
			out["warmed"] = 1 if line.substr("warmed=".length()).strip_edges() == "1" else 0
			has_kv = true
		elif line.begins_with("driver="):
			out["driver"] = line.substr("driver=".length()).strip_edges()
		elif legacy_line == "":
			legacy_line = line
	if not has_kv and legacy_line != "":
		out["stamp"] = legacy_line
		out["warmed"] = 0
	return out


static func _write_build_file(path: String, stamp: String, warmed: int, driver := "") -> void:
	var parent := _globalize(path).get_base_dir()
	if parent != "" and not parent.ends_with("://") and not DirAccess.dir_exists_absolute(parent):
		DirAccess.make_dir_recursive_absolute(parent)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		var text := "stamp=%s\nwarmed=%d\n" % [stamp, 1 if warmed == 1 else 0]
		if driver != "":
			text += "driver=%s\n" % driver
		f.store_string(text)
		f.close()


static func _build_file() -> String:
	return build_file_override if build_file_override != "" else BUILD_FILE


static func _cache_dirs() -> Array[String]:
	if not cache_dirs_override.is_empty():
		return cache_dirs_override
	var out: Array[String] = []
	for d in CACHE_DIRS:
		out.append(d)
	return out


static func _shader_cache_dir() -> String:
	if not cache_dirs_override.is_empty():
		for d in cache_dirs_override:
			if d.replace("\\", "/").trim_suffix("/").get_file() == "shader_cache":
				return d
		return cache_dirs_override[0]
	return CACHE_DIRS[0]


static func _globalize(d: String) -> String:
	if d.begins_with("user://") or d.begins_with("res://"):
		return ProjectSettings.globalize_path(d)
	return d


static func _user_args() -> PackedStringArray:
	if user_args_override is PackedStringArray:
		return user_args_override
	if user_args_override is Array:
		var out := PackedStringArray()
		var list: Array = user_args_override
		for a in list:
			out.append(str(a))
		return out
	return OS.get_cmdline_user_args()


static func _has_user_arg(flag: String) -> bool:
	for a in _user_args():
		if a == flag:
			return true
	return false


static func _arg_value(prefix: String) -> String:
	for a in _user_args():
		if a.begins_with(prefix):
			return a.substr(prefix.length())
	return ""


static func _shader_refresh_arg() -> String:
	return _arg_value("--shader-refresh=")


static func _warm_shaders_arg() -> String:
	return _arg_value("--warm-shaders=")


static func _own_settings() -> bool:
	for a in _user_args():
		if a.begins_with("--settings-file="):
			return false
	return true


static func _is_headless() -> bool:
	if headless_override != -1:
		return headless_override == 1
	return DisplayServer.get_name() == "headless"


static func _is_template() -> bool:
	if template_override != -1:
		return template_override == 1
	return OS.has_feature("template")
