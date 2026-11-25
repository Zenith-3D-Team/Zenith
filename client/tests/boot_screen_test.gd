extends SceneTree
## Tests `boot.tscn` and `boot.gd`:
## - `boot.gd` has zero top-level `preload()` calls for `.gdshader`, `main.gd`, `menu_kit.gd`, `kit.gd`, or `settings.gd`
## - `project.godot` uses `res://scenes/boot.tscn` as `run/main_scene`
## - `boot.gd` bypasses cleanly to `res://scenes/main.tscn` in headless / `--boot-screen=off`
## - UI construction, 3D rig, progress monotonicity, and `Main.booted_from_screen` default
##
## Run headless:
##   godot --headless --audio-driver Dummy --path client --log-file "<abs>/boot_screen_test.godot.log" -s res://tests/boot_screen_test.gd

const TestEnv := preload("res://tests/test_env.gd")
const Boot := preload("res://scripts/menu/boot.gd")
const ShaderRefresh := preload("res://scripts/menu/shader_refresh.gd")
const SafeDelete := preload("res://scripts/safe_delete.gd")

var _fails := 0
var _phase := 0
var _frames := 0
var _saw_main := false
var _handoff_probe: Node = null
var _handoff_dropped: Array[Node] = []
var _handoff_temp := ""


func _check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _initialize() -> void:
	TestEnv.isolate("boot-screen")
	_check_source_preloads()
	_check_project_and_main()
	_check_bypass_logic()
	_check_ui_and_rig()
	_check_staged_state_machine()
	_check_warm_shaders_modes()

	var packed := ResourceLoader.load("res://scenes/boot.tscn") as PackedScene
	_check(packed != null, "boot.tscn loads as PackedScene")
	if packed == null:
		_finish()
		return
	var inst := packed.instantiate()
	_check(inst != null and inst.name == "Boot" and inst is Node3D, "boot.tscn instantiates Node3D named Boot")
	_check(inst != null and inst.get_script() == Boot, "boot.tscn root uses boot.gd")
	if inst != null:
		inst.free()

	var err := change_scene_to_file("res://scenes/boot.tscn")
	_check(err == OK, "change_scene_to_file(boot.tscn) returns OK")
	if err != OK:
		_finish()


func _process(_delta: float) -> bool:
	_frames += 1
	if _phase == 0:
		if current_scene != null and current_scene.scene_file_path == "res://scenes/main.tscn":
			_saw_main = true
			_check(true, "boot.tscn bypasses to main.tscn")
			var main_script := current_scene.get_script() as Script
			_check(main_script != null and not bool(main_script.get(&"booted_from_screen")),
				"bypassed main.tscn keeps booted_from_screen == false")
			unload_current_scene()
			_phase = 1
			_frames = 0
		elif _frames > 180:
			_check(false, "boot.tscn bypasses to main.tscn (timed out)")
			_finish()
			return true
	elif _phase == 1:
		if _frames >= 2:
			_start_handoff_probe()
			_phase = 2
			_frames = 0
	elif _phase == 2:
		if _handoff_probe == null or not is_instance_valid(_handoff_probe):
			_check(true, "Boot frees itself after FINISH frames")
			var all_dropped := true
			for n in _handoff_dropped:
				if is_instance_valid(n):
					all_dropped = false
			_check(all_dropped, "handoff frees BootCamera, BootSun, WarmHolder, and warmup nodes")
			_handoff_dropped.clear()
			_reset_refresh_overrides()
			if _handoff_temp != "":
				SafeDelete.remove_tree_checked(_handoff_temp)
				_handoff_temp = ""
			unload_current_scene()
			_phase = 3
			_frames = 0
		elif _frames > 20:
			_check(false, "Boot frees itself after FINISH frames (timed out)")
			_handoff_dropped.clear()
			_reset_refresh_overrides()
			if _handoff_temp != "":
				SafeDelete.remove_tree_checked(_handoff_temp)
				_handoff_temp = ""
			unload_current_scene()
			_phase = 3
			_frames = 0
	elif _phase == 3:
		if _frames >= 2:
			_finish()
			return true
	return false


func _check_source_preloads() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/menu/boot.gd")
	_check(src != "", "boot.gd source is readable")
	var preloads: Array[String] = []
	for line in src.split("\n"):
		var t := line.strip_edges()
		if t.begins_with("#") or t.begins_with("##"):
			continue
		if "preload(" in t:
			preloads.append(t)
	_check(preloads.size() <= 2, "boot.gd has at most 2 top-level preload() calls (%d)" % preloads.size())
	var forbidden := [".gdshader", "main.gd", "menu_kit.gd", "kit.gd", "settings.gd"]
	for pat in forbidden:
		var found := false
		for p in preloads:
			if pat in p:
				found = true
		_check(not found, "boot.gd has zero preload() calls containing '%s'" % pat)
	var has_refresh := false
	var has_watchdog := false
	for p in preloads:
		if "shader_refresh.gd" in p:
			has_refresh = true
		if "stall_watchdog.gd" in p:
			has_watchdog = true
	_check(has_refresh and has_watchdog, "boot.gd preloads ShaderRefresh and StallWatchdog")


func _check_project_and_main() -> void:
	var entry := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	_check(entry == "res://scenes/boot.tscn", "project.godot run/main_scene is res://scenes/boot.tscn (got '%s')" % entry)
	var main_script := load("res://scripts/main.gd") as Script
	_check(main_script != null, "main.gd loads cleanly")
	if main_script != null:
		_check(main_script.get(&"booted_from_screen") == false, "Main.booted_from_screen defaults to false")


func _check_bypass_logic() -> void:
	_check(Boot.should_bypass_for("headless", PackedStringArray()), "bypass true when DisplayServer is headless")
	_check(Boot.should_bypass_for("Windows", PackedStringArray(["--boot-screen=off"])),
		"bypass true when --boot-screen=off is passed")
	_check(Boot.should_bypass_for("x11", PackedStringArray(["--boot-screen=off", "--port=34201"])),
		"bypass true when --boot-screen=off is among args")
	_check(not Boot.should_bypass_for("Windows", PackedStringArray()),
		"bypass false for normal windowed launch")
	_check(not Boot.should_bypass_for("x11", PackedStringArray(["--shader-refresh=off"])),
		"bypass false without --boot-screen=off")


func _check_ui_and_rig() -> void:
	var probe := Boot.new()
	probe._setup_3d_rig()
	probe._build_ui()
	_check(probe._boot_cam != null and probe._boot_cam.current, "3D rig creates current Camera3D")
	_check(probe._boot_sun != null, "3D rig creates DirectionalLight3D")
	_check(probe._warm_holder != null, "3D rig creates WarmHolder Node3D")
	_check(probe._overlay != null and probe._overlay.layer == 100, "UI overlay CanvasLayer is on layer 100")
	_check(probe._status_label != null and probe._progress_bar != null and probe._detail_label != null,
		"UI builds status label, progress bar, and detail label")
	_check(probe._cancel_btn != null and probe._cancel_btn.text != "", "UI builds Cancel/Quit button")
	probe._set_progress(0.45, "Compiling shaders… (2 / 5)", "terrain.gdshader  •  4 pipelines  •  0.3s")
	_check(is_equal_approx(probe._progress_bar.value, 0.45), "progress bar updates to 0.45")
	probe._set_progress(0.20, "Compiling shaders… (2 / 5)", "terrain.gdshader  •  4 pipelines  •  0.4s")
	_check(is_equal_approx(probe._progress_bar.value, 0.45), "progress bar stays monotonic")
	probe.free()


func _check_staged_state_machine() -> void:
	var sw_script := GDScript.new()
	sw_script.source_code = """extends Node3D
static var handled_by_boot := false
static var mode := "loaded"
var done_count := 0
var total_count := 2
var current_label := "terrain"
func advance() -> void:
	done_count = mini(total_count, done_count + 1)
	current_label = "belt" if done_count >= 2 else "terrain"
func is_done() -> bool:
	return done_count >= total_count
func pipelines_compiled() -> int:
	return done_count * 3
static func begin_staged(parent: Node, _include_all: bool, _extra_dirs: Array = [], _budget_ms: int = 25) -> Node3D:
	var inst: Node3D = new()
	parent.add_child(inst)
	return inst
"""
	_check(sw_script.reload() == OK, "mock ShaderWarmup script compiles")

	var rw_script := GDScript.new()
	rw_script.source_code = """extends Node
static var done := false
var done_count := 0
var total_count := 3
var current_label := "Post-processing effects"
func advance() -> void:
	done_count = total_count
	current_label = "Alt-mode GPU icons"
func is_done() -> bool:
	return done_count >= total_count
static func begin_staged(parent: Node) -> Node:
	var inst: Node = new()
	parent.add_child(inst)
	return inst
"""
	_check(rw_script.reload() == OK, "mock RenderWarm script compiles")

	var probe := Boot.new()
	probe._setup_3d_rig()
	probe._build_ui()
	probe._shader_warmup_script = sw_script
	probe._render_warm_script = rw_script
	probe._state = Boot.State.WARM_SHADERS

	probe._step_warm_shaders()
	_check(probe._shader_warm != null, "WARM_SHADERS starts staged shader node")
	_check(("Compiling shaders…" in probe._status_label.text or "Warming shader cache…" in probe._status_label.text)
		and "(0 / 2)" in probe._status_label.text,
		"WARM_SHADERS updates status label (%s)" % probe._status_label.text)
	_check("terrain" in probe._detail_label.text and "0 pipelines" in probe._detail_label.text,
		"WARM_SHADERS updates detail label (%s)" % probe._detail_label.text)
	_check(is_equal_approx(probe._progress_bar.value, 0.30), "WARM_SHADERS starts bar at 0.30")

	probe._shader_warm.call(&"advance")
	probe._step_warm_shaders()
	_check(is_equal_approx(probe._progress_bar.value, 0.55), "WARM_SHADERS advances bar to 0.55")
	_check(probe._state == Boot.State.WARM_SHADERS, "WARM_SHADERS stays active until is_done()")

	probe._shader_warm.call(&"advance")
	probe._step_warm_shaders()
	_check(is_equal_approx(probe._progress_bar.value, 0.80), "WARM_SHADERS reaches 0.80 when done")
	_check(probe._state == Boot.State.WARM_RENDER, "WARM_SHADERS transitions to WARM_RENDER")

	probe._step_warm_render()
	_check(probe._render_warm != null, "WARM_RENDER starts staged render node")
	_check(probe._status_label.text == "Preparing renderer…", "WARM_RENDER updates status label")
	_check("Post-processing effects" in probe._detail_label.text, "WARM_RENDER updates detail label")

	probe._render_warm.call(&"advance")
	probe._step_warm_render()
	_check(is_equal_approx(probe._progress_bar.value, 0.95), "WARM_RENDER advances bar to 0.95")
	_check(probe._state == Boot.State.PRE_HANDOFF, "WARM_RENDER transitions to PRE_HANDOFF")

	probe._step_pre_handoff()
	_check(is_equal_approx(probe._progress_bar.value, 1.0), "PRE_HANDOFF paints 1.0 before main instantiates")
	_check(probe._status_label.text == "Starting Zenith…", "PRE_HANDOFF sets status to 'Starting Zenith…'")
	_check(probe._cancel_btn.disabled, "PRE_HANDOFF disables Cancel button")
	_check(probe._state == Boot.State.PRE_HANDOFF, "PRE_HANDOFF waits 1 frame to paint before HANDOFF")

	probe._state = Boot.State.APPLY_WINDOW
	probe._apply_window_frames = 0
	probe._step_apply_window()
	_check(probe._state == Boot.State.APPLY_WINDOW, "APPLY_WINDOW waits 2 frames")
	probe._step_apply_window()
	_check(probe._state == Boot.State.WARM_SHADERS, "APPLY_WINDOW transitions to WARM_SHADERS after 2 frames")

	probe._drop_node(probe._shader_warm)
	probe._drop_node(probe._render_warm)
	probe._drop_node(probe._warm_holder)
	probe._drop_node(probe._boot_cam)
	probe._drop_node(probe._boot_sun)
	probe._shader_warm = null
	probe._render_warm = null
	probe._warm_holder = null
	probe._boot_cam = null
	probe._boot_sun = null
	_check(true, "rig and warmup nodes drop cleanly")
	probe.free()


func _reset_refresh_overrides() -> void:
	ShaderRefresh.build_file_override = ""
	ShaderRefresh.cache_dirs_override = []
	ShaderRefresh.user_args_override = null
	ShaderRefresh.headless_override = -1
	ShaderRefresh.template_override = -1
	ShaderRefresh.baked_hash_file_override = ""
	ShaderRefresh.addon_roots_override = null
	ShaderRefresh.restart_runner_override = Callable()


func _write_text(path: String, text: String) -> void:
	var parent := path.get_base_dir()
	if parent != "" and not DirAccess.dir_exists_absolute(parent):
		DirAccess.make_dir_recursive_absolute(parent)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


func _check_warm_shaders_modes() -> void:
	var tmp := OS.get_temp_dir().replace("\\", "/").path_join("zenith-tests/boot-modes-%d" % OS.get_process_id())
	SafeDelete.remove_tree_checked(tmp)
	var build_file := tmp.path_join("build-stamp.txt")
	var cache_dir := tmp.path_join("shader_cache")
	DirAccess.make_dir_recursive_absolute(cache_dir)

	ShaderRefresh.headless_override = 0
	ShaderRefresh.build_file_override = build_file
	ShaderRefresh.cache_dirs_override = [cache_dir]
	ShaderRefresh.addon_roots_override = []
	ShaderRefresh.user_args_override = PackedStringArray()

	var rec_sw := GDScript.new()
	rec_sw.source_code = """extends Node3D
static var handled_by_boot := false
static var mode := "loaded"
static var last_include_all := false
static var calls := 0
var done_count := 0
var total_count := 1
var current_label := "terrain"
func is_done() -> bool:
	return false
func pipelines_compiled() -> int:
	return 0
static func begin_staged(parent: Node, include_all: bool, _extra_dirs: Array = [], _budget_ms: int = 25) -> Node3D:
	last_include_all = include_all
	calls += 1
	var inst: Node3D = new()
	parent.add_child(inst)
	return inst
"""
	_check(rec_sw.reload() == OK, "recording ShaderWarmup mock compiles")

	# 1. Cold compile (missing build-stamp.txt -> needs_compile() == true -> include_all == true, "Compiling shaders…").
	var cold_probe := Boot.new()
	cold_probe._setup_3d_rig()
	cold_probe._build_ui()
	cold_probe._shader_warmup_script = rec_sw
	cold_probe._state = Boot.State.WARM_SHADERS
	cold_probe._step_warm_shaders()
	_check(bool(rec_sw.get(&"last_include_all")), "cold launch passes include_all=true to ShaderWarmup.begin_staged")
	_check(cold_probe._cold_compile and cold_probe._warmup_ran, "cold launch sets _cold_compile and _warmup_ran")
	_check(cold_probe._status_label.text.begins_with("Compiling shaders…"),
		"cold launch shows 'Compiling shaders…' (%s)" % cold_probe._status_label.text)
	cold_probe.free()

	# 2. Warm launch (matching stamp + warmed=1 + cache_dir -> include_all == false, "Warming shader cache…").
	var stamp := ShaderRefresh.build_stamp()
	_write_text(build_file, "stamp=%s\nwarmed=1\n" % stamp)
	rec_sw.set(&"last_include_all", true)
	var warm_probe := Boot.new()
	warm_probe._setup_3d_rig()
	warm_probe._build_ui()
	warm_probe._shader_warmup_script = rec_sw
	warm_probe._state = Boot.State.WARM_SHADERS
	warm_probe._step_warm_shaders()
	_check(not bool(rec_sw.get(&"last_include_all")), "warm launch passes include_all=false to ShaderWarmup.begin_staged")
	_check(not warm_probe._cold_compile and warm_probe._warmup_ran, "warm launch keeps _cold_compile=false and _warmup_ran=true")
	_check(warm_probe._status_label.text.begins_with("Warming shader cache…"),
		"warm launch shows 'Warming shader cache…' (%s)" % warm_probe._status_label.text)
	warm_probe.free()

	# 3. --warm-shaders=off (mode == "off"): skips begin_staged, keeps _warmup_ran=false, leaves warmed=0 on handoff.
	_write_text(build_file, "stamp=%s\nwarmed=0\n" % stamp)
	rec_sw.set(&"mode", "off")
	var calls_before: int = int(rec_sw.get(&"calls"))
	var off_probe := Boot.new()
	off_probe._setup_3d_rig()
	off_probe._build_ui()
	off_probe._shader_warmup_script = rec_sw
	off_probe._state = Boot.State.WARM_SHADERS
	off_probe._step_warm_shaders()
	_check(int(rec_sw.get(&"calls")) == calls_before, "--warm-shaders=off skips ShaderWarmup.begin_staged")
	_check(not off_probe._warmup_ran and off_probe._state == Boot.State.WARM_RENDER,
		"--warm-shaders=off leaves _warmup_ran=false and advances to WARM_RENDER")
	off_probe.free()

	# 4. --warm-shaders=cold (mode == "cold"): skips on warm launch, runs full compile when needs_compile() is true.
	_write_text(build_file, "stamp=%s\nwarmed=1\n" % stamp)
	rec_sw.set(&"mode", "cold")
	var cold_mode_calls: int = int(rec_sw.get(&"calls"))
	var cold_mode_warm := Boot.new()
	cold_mode_warm._setup_3d_rig()
	cold_mode_warm._build_ui()
	cold_mode_warm._shader_warmup_script = rec_sw
	cold_mode_warm._state = Boot.State.WARM_SHADERS
	cold_mode_warm._step_warm_shaders()
	_check(int(rec_sw.get(&"calls")) == cold_mode_calls,
		"--warm-shaders=cold skips ShaderWarmup.begin_staged when needs_compile() is false")
	_check(not cold_mode_warm._cold_compile and not cold_mode_warm._warmup_ran and cold_mode_warm._state == Boot.State.WARM_RENDER,
		"--warm-shaders=cold warm launch advances directly to WARM_RENDER")
	cold_mode_warm.free()

	_write_text(build_file, "stamp=%s\nwarmed=0\n" % stamp)
	rec_sw.set(&"last_include_all", false)
	var cold_mode_cold := Boot.new()
	cold_mode_cold._setup_3d_rig()
	cold_mode_cold._build_ui()
	cold_mode_cold._shader_warmup_script = rec_sw
	cold_mode_cold._state = Boot.State.WARM_SHADERS
	cold_mode_cold._step_warm_shaders()
	_check(int(rec_sw.get(&"calls")) == cold_mode_calls + 1 and bool(rec_sw.get(&"last_include_all")),
		"--warm-shaders=cold runs full include_all compile when needs_compile() is true")
	_check(cold_mode_cold._cold_compile and cold_mode_cold._warmup_ran
		and cold_mode_cold._status_label.text.begins_with("Compiling shaders…"),
		"--warm-shaders=cold cold launch sets _cold_compile, _warmup_ran, and 'Compiling shaders…'")
	cold_mode_cold.free()

	_reset_refresh_overrides()
	SafeDelete.remove_tree_checked(tmp)


func _start_handoff_probe() -> void:
	_handoff_temp = OS.get_temp_dir().replace("\\", "/").path_join("zenith-tests/boot-handoff-%d" % OS.get_process_id())
	SafeDelete.remove_tree_checked(_handoff_temp)
	var build_file := _handoff_temp.path_join("build-stamp.txt")
	var cache_dir := _handoff_temp.path_join("shader_cache")
	DirAccess.make_dir_recursive_absolute(cache_dir)

	ShaderRefresh.headless_override = 0
	ShaderRefresh.build_file_override = build_file
	ShaderRefresh.cache_dirs_override = [cache_dir]
	ShaderRefresh.addon_roots_override = []
	ShaderRefresh.user_args_override = PackedStringArray()
	var stamp := ShaderRefresh.build_stamp()
	_write_text(build_file, "stamp=%s\nwarmed=0\n" % stamp)

	var probe_script := GDScript.new()
	probe_script.source_code = """extends "res://scripts/menu/boot.gd"
func _ready() -> void:
	pass
"""
	_check(probe_script.reload() == OK, "Boot test subclass compiles")

	var sw_script := GDScript.new()
	sw_script.source_code = """extends Node3D
static var handled_by_boot := false
static var mode := "loaded"
static func begin_staged(parent: Node, _include_all: bool, _extra_dirs: Array = [], _budget_ms: int = 25) -> Node3D:
	var inst: Node3D = new()
	parent.add_child(inst)
	return inst
"""
	_check(sw_script.reload() == OK, "handoff mock ShaderWarmup compiles")

	var rw_script := GDScript.new()
	rw_script.source_code = """extends Node
static var done := false
static func begin_staged(parent: Node) -> Node:
	var inst: Node = new()
	parent.add_child(inst)
	return inst
"""
	_check(rw_script.reload() == OK, "handoff mock RenderWarm compiles")

	var mock_main_script := GDScript.new()
	mock_main_script.source_code = """extends Node
static var booted_from_screen := false
var saw_booted_in_ready := false
func _ready() -> void:
	saw_booted_in_ready = booted_from_screen
"""
	_check(mock_main_script.reload() == OK, "handoff mock Main script compiles")

	var dummy_main := Node.new()
	dummy_main.name = "MockMain"
	dummy_main.set_script(mock_main_script)
	var packed_main := PackedScene.new()
	var pack_err := packed_main.pack(dummy_main)
	dummy_main.free()
	_check(pack_err == OK, "mock Main PackedScene packs cleanly")

	# Verify _handoff() when _warmup_ran is false (e.g. --warm-shaders=off): sets handled_by_boot but keeps warmed=0.
	var un_probe: Node = probe_script.new()
	un_probe.name = "BootProbeUnwarmed"
	root.add_child(un_probe)
	un_probe.call(&"_setup_3d_rig")
	un_probe.call(&"_build_ui")
	un_probe.set(&"_shader_warmup_script", sw_script)
	un_probe.set(&"_render_warm_script", rw_script)
	un_probe.set(&"_main_packed", packed_main)
	un_probe.set(&"_warmup_ran", false)
	un_probe.call(&"_handoff")
	_check(bool(sw_script.get(&"handled_by_boot")), "_handoff() sets handled_by_boot=true even when _warmup_ran is false")
	_check(FileAccess.get_file_as_string(build_file) == "stamp=%s\nwarmed=0\n" % stamp,
		"_handoff() skips mark_warmed() when _warmup_ran is false")
	unload_current_scene()
	un_probe.free()
	sw_script.set(&"handled_by_boot", false)
	rw_script.set(&"done", false)
	mock_main_script.set(&"booted_from_screen", false)

	var probe: Node = probe_script.new()
	probe.name = "BootProbe"
	root.add_child(probe)
	probe.call(&"_setup_3d_rig")
	probe.call(&"_build_ui")
	probe.set(&"_shader_warmup_script", sw_script)
	probe.set(&"_render_warm_script", rw_script)
	probe.set(&"_main_packed", packed_main)
	probe.set(&"_warmup_ran", true)

	var warm_holder: Node3D = probe.get(&"_warm_holder") as Node3D
	var sw_node: Node3D = sw_script.call(&"begin_staged", warm_holder, false) as Node3D
	var rw_node: Node = rw_script.call(&"begin_staged", probe) as Node
	probe.set(&"_shader_warm", sw_node)
	probe.set(&"_render_warm", rw_node)

	_handoff_dropped = [
		probe.get(&"_boot_cam") as Node,
		probe.get(&"_boot_sun") as Node,
		warm_holder,
		sw_node,
		rw_node,
	]

	probe.call(&"_handoff")
	_handoff_probe = probe

	_check(bool(probe.get(&"_handed_off")), "_handoff() sets _handed_off = true")
	_check(int(probe.get(&"_state")) == Boot.State.FINISH, "_handoff() transitions to State.FINISH")
	_check(bool(sw_script.get(&"handled_by_boot")), "_handoff() sets ShaderWarmup.handled_by_boot = true")
	_check(bool(rw_script.get(&"done")), "_handoff() sets RenderWarm.done = true")
	_check(FileAccess.get_file_as_string(build_file) == "stamp=%s\nwarmed=1\n" % stamp,
		"_handoff() calls ShaderRefresh.mark_warmed() when _warmup_ran is true")
	var bar_fill: StyleBoxFlat = probe.get(&"_bar_fill_style") as StyleBoxFlat
	var cancel_btn: Button = probe.get(&"_cancel_btn") as Button
	var bar: ProgressBar = probe.get(&"_progress_bar") as ProgressBar
	var status_lbl: Label = probe.get(&"_status_label") as Label
	_check(bar_fill != null and bar_fill.bg_color == Boot.BAR_FILL_GREEN, "_handoff() turns progress bar green")
	_check(cancel_btn != null and cancel_btn.disabled, "_handoff() disables Cancel button")
	_check(bar != null and is_equal_approx(bar.value, 1.0), "_handoff() sets progress bar to 1.0")
	_check(status_lbl != null and status_lbl.text == "Starting Zenith…", "_handoff() sets status to 'Starting Zenith…'")
	_check(current_scene != null and current_scene.name == "MockMain", "_handoff() sets current_scene to instantiated Main")
	_check(current_scene != null and bool(current_scene.get(&"saw_booted_in_ready")),
		"_handoff() sets Main.booted_from_screen = true BEFORE Main._ready() runs")


func _finish() -> void:
	TestEnv.clean()
	print("BOOT SCREEN FAILS: %d" % _fails)
	quit(1 if _fails > 0 or not _saw_main else 0)
