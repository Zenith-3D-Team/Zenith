extends SceneTree
## Tests smart shader-hash cache refresh, lock-safe cache deletion, legacy stamp compatibility,
## addon shader hashing/directory discovery, and export plugin hash parity.
## Run headless:
##   godot --headless --audio-driver Dummy --path client --log-file "<abs>/art-src/check-logs/shader_refresh_test.godot.log" -s res://tests/shader_refresh_test.gd

const SafeDelete := preload("res://scripts/safe_delete.gd")
const ShaderRefresh := preload("res://scripts/menu/shader_refresh.gd")
const ShaderHashExport := preload("res://addons/zenith_export/shader_hash_export.gd")

var _fails := 0


func _check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _write_text(path: String, text: String) -> void:
	var parent := path.get_base_dir()
	if parent != "" and not DirAccess.dir_exists_absolute(parent):
		DirAccess.make_dir_recursive_absolute(parent)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


func _reset_overrides() -> void:
	ShaderRefresh.child_pid = 0
	ShaderRefresh.build_file_override = ""
	ShaderRefresh.cache_dirs_override = []
	ShaderRefresh.user_args_override = null
	ShaderRefresh.headless_override = -1
	ShaderRefresh.template_override = -1
	ShaderRefresh.baked_hash_file_override = ""
	ShaderRefresh.addon_roots_override = null
	ShaderRefresh.restart_runner_override = Callable()
	ShaderRefresh.driver_override = ""


func _make_link(at: String, to: String) -> bool:
	DirAccess.make_dir_recursive_absolute(at.get_base_dir())
	var out: Array = []
	if OS.get_name() == "Windows":
		OS.execute("cmd", ["/c", "mklink", "/J", at.replace("/", "\\"), to.replace("/", "\\")], out, true)
	else:
		OS.execute("ln", ["-s", to, at], out, true)
	return SafeDelete.is_link(at)


func _collect_shaders_manual(dir: String, out: Array[String]) -> void:
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with("."):
			_collect_shaders_manual(dir.path_join(d), out)
	for f in DirAccess.get_files_at(dir):
		var lower := f.to_lower()
		if lower.ends_with(".gdshader") or lower.ends_with(".gdshaderinc"):
			out.append(dir.path_join(f))


func _initialize() -> void:
	var base := OS.get_temp_dir().replace("\\", "/").path_join("zenith-tests/shader-refresh-%d" % OS.get_process_id())
	SafeDelete.remove_tree_checked(base)
	DirAccess.make_dir_recursive_absolute(base)

	_test_lightweight_preloads()
	_test_safe_delete_checked(base)
	_test_stamp_and_compile_state(base)
	_test_restart_and_locking(base)
	_test_addon_shader_hash_and_dirs(base)
	_test_export_hash_parity(base)

	_reset_overrides()
	_check(SafeDelete.remove_tree_checked(base), "cleanup removes test temp directory")
	print("SHADER REFRESH FAILS: %d" % _fails)
	quit(1 if _fails > 0 else 0)


func _test_lightweight_preloads() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/menu/shader_refresh.gd")
	var forbidden := ["addon_host.gd", "paths.gd", "settings.gd", "main.gd", ".gdshader"]
	var clean := true
	for raw_line in src.split("\n"):
		var line := raw_line.strip_edges()
		if line.begins_with("#"):
			continue
		if not line.contains("preload(") and not line.contains("load("):
			continue
		for pat in forbidden:
			if line.contains(pat):
				clean = false
	_check(clean, "shader_refresh.gd has no heavy preloads (AddonHost/Paths/Settings/main/.gdshader)")


func _test_safe_delete_checked(base: String) -> void:
	_check(not SafeDelete.remove_tree_checked(""), "remove_tree_checked rejects empty path")
	_check(SafeDelete.remove_tree_checked(base.path_join("does-not-exist")), "remove_tree_checked returns true for missing path")

	var plain_file := base.path_join("plain-file.txt")
	_write_text(plain_file, "keep")
	_check(not SafeDelete.remove_tree_checked(plain_file) and FileAccess.file_exists(plain_file),
		"remove_tree_checked returns false and preserves a plain file path")

	var tree := base.path_join("tree")
	_write_text(tree.path_join("sub/a.txt"), "a")
	_check(SafeDelete.remove_tree_checked(tree) and not DirAccess.dir_exists_absolute(tree),
		"remove_tree_checked deletes nested directory and returns true")

	var target := base.path_join("link-target")
	_write_text(target.path_join("keep.txt"), "safe")
	var direct_link := base.path_join("direct-link")
	if _make_link(direct_link, target):
		_check(SafeDelete.remove_tree_checked(direct_link) and not SafeDelete.is_link(direct_link),
			"remove_tree_checked removes a top-level junction/symlink directly")
		_check(FileAccess.file_exists(target.path_join("keep.txt")),
			"remove_tree_checked on a top-level link preserves target files")
	var holder := base.path_join("holder")
	if _make_link(holder.path_join("linked"), target):
		_check(SafeDelete.remove_tree_checked(holder) and not DirAccess.dir_exists_absolute(holder),
			"remove_tree_checked deletes folder holding junction/symlink")
		_check(FileAccess.file_exists(target.path_join("keep.txt")),
			"remove_tree_checked preserves junction/symlink target files")

	if OS.get_name() == "Windows":
		var locked_dir := base.path_join("locked-dir")
		var locked_file := locked_dir.path_join("lock.bin")
		_write_text(locked_file, "busy")
		var handle := FileAccess.open(locked_file, FileAccess.READ_WRITE)
		_check(handle != null, "test opened locked file handle on Windows")
		_check(not SafeDelete.remove_tree_checked(locked_dir) and DirAccess.dir_exists_absolute(locked_dir),
			"remove_tree_checked returns false when a file inside is locked")
		handle = null
		_check(SafeDelete.remove_tree_checked(locked_dir) and not DirAccess.dir_exists_absolute(locked_dir),
			"remove_tree_checked succeeds once lock handle is released")


func _test_stamp_and_compile_state(base: String) -> void:
	_reset_overrides()
	var build_file := base.path_join("state/build-stamp.txt")
	var cache_shader := base.path_join("state/caches/shader_cache")
	var cache_vk := base.path_join("state/caches/vulkan")
	ShaderRefresh.build_file_override = build_file
	ShaderRefresh.cache_dirs_override = [cache_shader, cache_vk]
	ShaderRefresh.addon_roots_override = []

	# Real headless skips compile & mark_warmed.
	ShaderRefresh.headless_override = -1
	ShaderRefresh.user_args_override = PackedStringArray()
	_check(not ShaderRefresh.needs_compile(), "headless run skips shader compilation")
	ShaderRefresh.mark_warmed()
	_check(not FileAccess.file_exists(build_file), "headless mark_warmed does not write build file")

	# Non-headless simulation with missing build file (drawing with Direct3D 12, the Windows default).
	ShaderRefresh.headless_override = 0
	ShaderRefresh.driver_override = "d3d12"
	var stamp := ShaderRefresh.build_stamp()
	_check(stamp.begins_with(str(Engine.get_version_info().get("string", ""))), "build_stamp starts with Godot version")
	_check(stamp.ends_with(" addons:none"), "build_stamp appends addons:none when no addon shaders")
	_check(ShaderRefresh.needs_compile(), "missing build-stamp.txt triggers needs_compile")

	# Legacy single-line file with matching stamp: treated as warmed=0, does not trigger restart.
	_write_text(build_file, stamp + "\n")
	DirAccess.make_dir_recursive_absolute(cache_shader)
	_check(not ShaderRefresh.restart_if_new_build(), "legacy matching single-line stamp does not restart")
	_check(ShaderRefresh.needs_compile(), "legacy single-line stamp (missing warmed=) triggers one warm-up")

	# mark_warmed writes two-line key=value format and satisfies needs_compile when cache exists.
	ShaderRefresh.mark_warmed()
	var written := FileAccess.get_file_as_string(build_file)
	_check(written == "stamp=%s\nwarmed=1\ndriver=d3d12\n" % stamp, "mark_warmed writes stamp=, warmed=1 and driver= lines")
	_check(not ShaderRefresh.needs_compile(), "needs_compile is false when stamp matches, warmed=1, and shader_cache exists")

	# Each driver has its own pipeline cache: warmed on one, the other warms once (nothing deleted, no restart).
	ShaderRefresh.driver_override = "vulkan"
	_check(ShaderRefresh.needs_compile(), "switching renderer (warmed on d3d12, now vulkan) triggers one warm-up")
	_check(not ShaderRefresh.restart_if_new_build() and DirAccess.dir_exists_absolute(cache_shader),
		"switching renderer neither restarts nor deletes caches")
	ShaderRefresh.mark_warmed()
	_check(not ShaderRefresh.needs_compile(), "after the warm-up on vulkan it is warm")
	# A file written before 0.3.1 (no driver= line) was warmed on Vulkan.
	_write_text(build_file, "stamp=%s\nwarmed=1\n" % stamp)
	_check(not ShaderRefresh.needs_compile(), "a file with no driver= line counts as warmed on vulkan")
	ShaderRefresh.driver_override = "d3d12"
	_check(ShaderRefresh.needs_compile(), "and on d3d12 that old file triggers one warm-up")
	ShaderRefresh.mark_warmed()

	# Missing shader_cache directory still forces compile.
	SafeDelete.remove_tree_checked(cache_shader)
	_check(ShaderRefresh.needs_compile(), "missing shader_cache forces needs_compile even when warmed=1")
	DirAccess.make_dir_recursive_absolute(cache_shader)
	_check(not ShaderRefresh.needs_compile(), "restored shader_cache restores needs_compile=false")

	# Key=value with warmed=0 triggers compile.
	_write_text(build_file, "stamp=%s\nwarmed=0\n" % stamp)
	_check(ShaderRefresh.needs_compile(), "warmed=0 triggers needs_compile")

	# Key=value with different stamp triggers compile.
	_write_text(build_file, "stamp=old-stamp\nwarmed=1\n")
	_check(ShaderRefresh.needs_compile(), "mismatched stamp triggers needs_compile")

	# Flags: --shader-refresh=off, --warm-shaders=off, --settings-file=, --shader-refresh=force.
	_write_text(build_file, "stamp=%s\nwarmed=1\n" % stamp)
	ShaderRefresh.user_args_override = PackedStringArray(["--shader-refresh=off"])
	_check(not ShaderRefresh.needs_compile(), "--shader-refresh=off disables needs_compile")
	_write_text(build_file, "stamp=%s\nwarmed=0\n" % stamp)
	ShaderRefresh.mark_warmed()
	_check(FileAccess.get_file_as_string(build_file).contains("warmed=0"), "--shader-refresh=off skips mark_warmed")

	_write_text(build_file, "stamp=%s\nwarmed=0\n" % stamp)
	ShaderRefresh.user_args_override = PackedStringArray(["--warm-shaders=off"])
	_check(not ShaderRefresh.needs_compile(), "--warm-shaders=off disables needs_compile")

	ShaderRefresh.user_args_override = PackedStringArray(["--settings-file=custom.cfg"])
	_check(not ShaderRefresh.needs_compile(), "--settings-file= disables needs_compile")
	ShaderRefresh.mark_warmed()
	_check(FileAccess.get_file_as_string(build_file).contains("warmed=0"), "--settings-file= skips mark_warmed")

	_write_text(build_file, "stamp=%s\nwarmed=1\n" % stamp)
	ShaderRefresh.user_args_override = PackedStringArray(["--shader-refresh=force"])
	_check(ShaderRefresh.needs_compile(), "--shader-refresh=force forces needs_compile")

	# --shader-refresh=build vs smart stamp.
	ShaderRefresh.user_args_override = PackedStringArray(["--shader-refresh=build"])
	var legacy_build_stamp := ShaderRefresh.build_stamp()
	var game_ver := str(ProjectSettings.get_setting("application/config/version", ""))
	_check(legacy_build_stamp.begins_with(game_ver + " "), "--shader-refresh=build restores game version prefix")
	_check(legacy_build_stamp != stamp, "--shader-refresh=build differs from smart shader-hash stamp")

	# Template baked hash vs fallback.
	ShaderRefresh.user_args_override = PackedStringArray()
	ShaderRefresh.template_override = 1
	var baked_file := base.path_join("state/shader_stamp.txt")
	_write_text(baked_file, "abc123baked\n")
	ShaderRefresh.baked_hash_file_override = baked_file
	var tpl_baked := ShaderRefresh.build_stamp()
	_check(tpl_baked.contains(" abc123baked "), "template build_stamp uses baked shader_stamp.txt hash")
	ShaderRefresh.baked_hash_file_override = base.path_join("state/missing_stamp.txt")
	var tpl_fallback := ShaderRefresh.build_stamp()
	_check(tpl_fallback != tpl_baked, "template build_stamp falls back when baked shader_stamp.txt is missing")


func _test_restart_and_locking(base: String) -> void:
	_reset_overrides()
	var build_file := base.path_join("restart/build-stamp.txt")
	var cache_shader := base.path_join("restart/caches/shader_cache")
	var cache_vk := base.path_join("restart/caches/vulkan")
	ShaderRefresh.build_file_override = build_file
	ShaderRefresh.cache_dirs_override = [cache_shader, cache_vk]
	ShaderRefresh.addon_roots_override = []
	ShaderRefresh.headless_override = 0

	var captured := {"calls": 0, "args": PackedStringArray()}
	var runner := func(_exe: String, args: PackedStringArray) -> bool:
		captured["calls"] = int(captured["calls"]) + 1
		captured["args"] = args
		return true
	ShaderRefresh.restart_runner_override = runner

	# 1. No caches on disk: writes warmed=0 stamp and returns false without spawning.
	ShaderRefresh.user_args_override = PackedStringArray()
	_check(not ShaderRefresh.restart_if_new_build(), "empty caches returns false without restart")
	_check(ShaderRefresh.child_pid == 0, "child_pid remains 0 when empty caches skips restart")
	_check(int(captured["calls"]) == 0, "empty caches does not spawn child")
	var stamp := ShaderRefresh.build_stamp()
	_check(FileAccess.get_file_as_string(build_file) == "stamp=%s\nwarmed=0\n" % stamp,
		"empty caches records stamp= and warmed=0")

	# 2. Force flag with caches present: deletes caches, updates stamp to warmed=0, strips --shader-refresh=force, keeps --shader-refresh=build if present.
	_write_text(cache_shader.path_join("a.bin"), "1")
	_write_text(cache_vk.path_join("b.bin"), "2")
	_write_text(build_file, "stamp=%s\nwarmed=1\n" % stamp)
	ShaderRefresh.user_args_override = PackedStringArray(["--shader-refresh=force", "--foo=bar"])
	ShaderRefresh.driver_override = "vulkan"
	_check(ShaderRefresh.restart_if_new_build(), "force refresh with existing caches triggers restart")
	_check(int(captured["calls"]) == 1, "spawned once")
	_check(not DirAccess.dir_exists_absolute(cache_shader) and not DirAccess.dir_exists_absolute(cache_vk),
		"restart_if_new_build removed cache directories")
	_check(FileAccess.get_file_as_string(build_file) == "stamp=%s\nwarmed=0\n" % stamp,
		"successful cache deletion updates build-stamp to warmed=0")
	var child_args: PackedStringArray = captured["args"]
	_check(not child_args.has("--shader-refresh=force") and child_args.has("--shader-refresh-restarted") and child_args.has("--foo=bar"),
		"child args strip --shader-refresh=force and append --shader-refresh-restarted")
	var driver_at := child_args.find("--rendering-driver")
	_check(driver_at >= 0 and driver_at + 1 < child_args.size() and child_args[driver_at + 1] == "vulkan"
		and driver_at < child_args.find("--"),
		"the restart starts on the driver this run draws with (--rendering-driver vulkan kept, before --)")

	# 3. --shader-refresh-restarted prevents loop.
	_write_text(cache_shader.path_join("a.bin"), "1")
	ShaderRefresh.user_args_override = PackedStringArray(["--shader-refresh-restarted"])
	_check(not ShaderRefresh.restart_if_new_build(), "--shader-refresh-restarted suppresses second restart")
	_check(ShaderRefresh.child_pid == 0, "child_pid stays 0 when restart is suppressed")
	_check(DirAccess.dir_exists_absolute(cache_shader), "suppressed restart leaves caches intact")

	# Hidden wait helper exists and is wired in both boot.gd and main.gd.
	var refresh_script := ShaderRefresh as Script
	var has_wait := false
	for m in refresh_script.get_script_method_list():
		if str(m.get("name", "")) == "wait_for_child":
			has_wait = true
	_check(has_wait, "ShaderRefresh defines wait_for_child")
	var boot_src := FileAccess.get_file_as_string("res://scripts/menu/boot.gd")
	var main_src := FileAccess.get_file_as_string("res://scripts/main.gd")
	_check(boot_src.contains("ShaderRefresh.wait_for_child(self)"), "boot.gd calls ShaderRefresh.wait_for_child(self)")
	_check(main_src.contains("ShaderRefresh.wait_for_child(self)"), "main.gd calls ShaderRefresh.wait_for_child(self)")

	# 4. --shader-refresh=build is preserved across restart (not stripped like =force).
	_write_text(build_file, "old-legacy-stamp\n")
	ShaderRefresh.user_args_override = PackedStringArray(["--shader-refresh=build", "--shader-refresh=force"])
	_check(ShaderRefresh.restart_if_new_build(), "new build with --shader-refresh=build restarts")
	var build_child_args: PackedStringArray = captured["args"]
	_check(build_child_args.has("--shader-refresh=build") and not build_child_args.has("--shader-refresh=force") and build_child_args.has("--shader-refresh-restarted"),
		"--shader-refresh=build is preserved in child args while =force is stripped")

	# 5. Locked cache dir on Windows: keeps old stamp and still passes --shader-refresh-restarted.
	if OS.get_name() == "Windows":
		_write_text(build_file, "stamp=old-stamp\nwarmed=1\n")
		var lock_file := cache_shader.path_join("locked.dat")
		_write_text(lock_file, "locked")
		var handle := FileAccess.open(lock_file, FileAccess.READ_WRITE)
		ShaderRefresh.user_args_override = PackedStringArray()
		_check(ShaderRefresh.restart_if_new_build(), "locked cache still restarts with --shader-refresh-restarted")
		_check(FileAccess.get_file_as_string(build_file) == "stamp=old-stamp\nwarmed=1\n",
			"locked cache deletion keeps old stamp so next launch retries")
		var locked_args: PackedStringArray = captured["args"]
		_check(locked_args.has("--shader-refresh-restarted"), "locked restart appends --shader-refresh-restarted")
		_check(locked_args.has("--shader-refresh-clean-failed"), "locked restart appends --shader-refresh-clean-failed")
		ShaderRefresh.user_args_override = locked_args
		ShaderRefresh.mark_warmed()
		_check(FileAccess.get_file_as_string(build_file) == "stamp=old-stamp\nwarmed=1\n",
			"mark_warmed keeps old stamp when --shader-refresh-clean-failed is set")
		handle = null


func _test_addon_shader_hash_and_dirs(base: String) -> void:
	_reset_overrides()
	var addons_a := base.path_join("addons_a")
	var addons_b := base.path_join("addons_b")
	DirAccess.make_dir_recursive_absolute(addons_a)
	DirAccess.make_dir_recursive_absolute(addons_b)

	ShaderRefresh.addon_roots_override = [addons_a, addons_b]
	_check(ShaderRefresh.addon_shader_hash() == "none", "empty addon roots yield 'none'")
	_check(ShaderRefresh.addon_shader_dirs().is_empty(), "empty addon roots yield empty addon_shader_dirs")

	var inc_only := addons_a.path_join("inc_only")
	_write_text(inc_only.path_join("common.gdshaderinc"), "// inc\n")
	_write_text(addons_a.path_join("scripts_only/entry.gd"), "extends Node\n")
	var hash_inc := ShaderRefresh.addon_shader_hash()
	_check(hash_inc != "none" and hash_inc.length() == 32, "addon .gdshaderinc produces 32-char MD5 hex")
	_check(ShaderRefresh.addon_shader_dirs().is_empty(), "addon_shader_dirs excludes folders with only .gdshaderinc/.gd")

	var shader_dir_z := addons_b.path_join("z_addon/shaders")
	var shader_dir_a := addons_a.path_join("a_addon/shaders")
	_write_text(shader_dir_z.path_join("z.gdshader"), "shader_type spatial;\n")
	_write_text(shader_dir_a.path_join("a.gdshader"), "shader_type canvas_item;\n")
	_write_text(shader_dir_a.path_join("b.gdshader"), "shader_type spatial;\n")
	var h1 := ShaderRefresh.addon_shader_hash()
	var h2 := ShaderRefresh.addon_shader_hash()
	_check(h1 == h2 and h1 != hash_inc, "addon_shader_hash is deterministic and changes when .gdshader added")

	_write_text(inc_only.path_join("common.gdshaderinc"), "// inc v2\n")
	var h3 := ShaderRefresh.addon_shader_hash()
	_check(h3 != h1, "addon_shader_hash changes when .gdshaderinc is edited")

	var dirs := ShaderRefresh.addon_shader_dirs()
	_check(dirs.size() == 2 and dirs[0] == shader_dir_a and dirs[1] == shader_dir_z,
		"addon_shader_dirs returns deduplicated sorted directories containing .gdshader files")

	var extra := base.path_join("extra_addons")
	_write_text(extra.path_join("e.gdshader"), "shader_type spatial;\n")
	var h_extra := ShaderRefresh.addon_shader_hash([extra])
	_check(h_extra != h3, "addon_shader_hash includes extra_dirs")

	# --addons= comma-separated CLI flag discovery.
	ShaderRefresh.addon_roots_override = null
	ShaderRefresh.user_args_override = PackedStringArray(["--addons=%s, %s" % [addons_a, addons_b]])
	var flag_dirs := ShaderRefresh.addon_shader_dirs()
	_check(flag_dirs.has(shader_dir_a) and flag_dirs.has(shader_dir_z),
		"addon_shader_dirs discovers comma-separated --addons= directories")
	ShaderRefresh.user_args_override = null

	# Portable add-on hashing across parent paths / worktrees and container + single-addon overlap.
	var wt_a := base.path_join("wt_main/addons_src")
	var wt_b := base.path_join("wt_branch/addons_src")
	_write_text(wt_a.path_join("sample_fx/addon.json"), "{\"id\":\"sample-fx\"}\n")
	_write_text(wt_a.path_join("sample_fx/shaders/fx.gdshader"), "shader_type spatial;\n")
	_write_text(wt_b.path_join("sample_fx/addon.json"), "{\"id\":\"sample-fx\"}\n")
	_write_text(wt_b.path_join("sample_fx/shaders/fx.gdshader"), "shader_type spatial;\n")
	ShaderRefresh.addon_roots_override = [wt_a]
	var wt_hash_a := ShaderRefresh.addon_shader_hash()
	ShaderRefresh.addon_roots_override = [wt_b]
	var wt_hash_b := ShaderRefresh.addon_shader_hash()
	_check(wt_hash_a == wt_hash_b and wt_hash_a.length() == 32,
		"identical add-on under different parent paths produces same addon_shader_hash")
	ShaderRefresh.addon_roots_override = [wt_a.path_join("sample_fx")]
	var single_hash := ShaderRefresh.addon_shader_hash()
	_check(single_hash == wt_hash_a,
		"explicit single add-on dir produces same addon_shader_hash as container dir")
	var overlap_hash := ShaderRefresh.addon_shader_hash([wt_b])
	_check(overlap_hash == wt_hash_a,
		"overlapping single add-on dir and container dir produce same addon_shader_hash")

	# Real repo roots (addons-src).
	ShaderRefresh.addon_roots_override = null
	var repo_hash := ShaderRefresh.addon_shader_hash()
	var repo_dirs := ShaderRefresh.addon_shader_dirs()
	_check(repo_hash != "none" and repo_hash.length() == 32, "repo addons-src produces valid addon_shader_hash")
	_check(repo_dirs.size() >= 2, "repo addon_shader_dirs discovers bundled shader directories")


func _test_export_hash_parity(base: String) -> void:
	_reset_overrides()
	var export_src := FileAccess.get_file_as_string("res://addons/zenith_export/shader_hash_export.gd")
	_check(export_src.contains("return \"ZenithShaderHash\""), "ShaderHashExport defines _get_name() -> ZenithShaderHash")
	var refresh_hash := ShaderRefresh.source_shader_hash("res://")
	var export_hash := ShaderHashExport.compute_shader_hash("res://")
	_check(refresh_hash.length() == 32 and refresh_hash == export_hash,
		"ShaderHashExport matches ShaderRefresh.source_shader_hash")

	# Cross-check against independent manual sorted MD5 calculation.
	var files: Array[String] = []
	_collect_shaders_manual("res://", files)
	files.sort()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	for p in files:
		ctx.update(p.to_utf8_buffer())
		var b := FileAccess.get_file_as_bytes(p)
		if not b.is_empty():
			ctx.update(b)
	var manual_hash := ctx.finish().hex_encode()
	_check(export_hash == manual_hash, "source_shader_hash matches independent sorted MD5 calculation")

	# Verify build_stamp embeds the exact source hash in source mode.
	ShaderRefresh.headless_override = 0
	ShaderRefresh.template_override = 0
	ShaderRefresh.addon_roots_override = []
	var stamp := ShaderRefresh.build_stamp()
	_check(stamp.contains(" " + export_hash + " "), "source build_stamp contains exact export shader hash")
	_check(base != "", "temp base valid")
