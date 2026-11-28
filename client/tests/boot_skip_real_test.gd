extends SceneTree
## Boot screen Skip against the REAL ShaderWarmup (forced cold compile, temp build file).
## Run headless: godot --headless --audio-driver Dummy --path client --log-file <abs> -s res://tests/boot_skip_real_test.gd -- skip|full
## `skip`: a few frames of real warm-up, Skip -> warning -> Skip again; warmed stays 0.
## `full`: no skip, waits for the real warm-up to finish; warmed becomes 1.
## Prints "BOOT SKIP REAL FAILS: N". RenderWarm.begin_staged returns null headless, so the renderer phase isn't covered.

const Boot := preload("res://scripts/menu/boot.gd")
const ShaderRefresh := preload("res://scripts/menu/shader_refresh.gd")
const SafeDelete := preload("res://scripts/safe_delete.gd")

var _fails := 0
var _mode := "skip"
var _probe: Node = null
var _temp := ""
var _build_file := ""
var _stamp := ""
var _frames := 0
var _phase := 0
var _dropped: Array = []
var _sw_script: Script = null


func _check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if "full" in args:
		_mode = "full"
	_temp = OS.get_temp_dir().replace("\\", "/").path_join("zenith-tests/boot-skip-real-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(_temp.path_join("shader_cache"))
	_build_file = _temp.path_join("build-stamp.txt")
	ShaderRefresh.headless_override = 0
	ShaderRefresh.build_file_override = _build_file
	ShaderRefresh.cache_dirs_override = [_temp.path_join("shader_cache")]
	ShaderRefresh.addon_roots_override = []
	ShaderRefresh.user_args_override = PackedStringArray()
	ShaderRefresh.driver_override = "vulkan"
	_stamp = ShaderRefresh.build_stamp()
	var f := FileAccess.open(_build_file, FileAccess.WRITE)
	f.store_string("stamp=%s\nwarmed=0\n" % _stamp)
	f.close()
	_check(ShaderRefresh.needs_compile(), "forced cold: needs_compile before")

	var ps := GDScript.new()
	ps.source_code = "extends \"res://scripts/menu/boot.gd\"\nfunc _ready() -> void:\n\tpass\n"
	ps.reload()
	var ms := GDScript.new()
	ms.source_code = "extends Node\n"
	ms.reload()
	var dm := Node.new()
	dm.name = "RealMain"
	dm.set_script(ms)
	var packed := PackedScene.new()
	packed.pack(dm)
	dm.free()
	_sw_script = ResourceLoader.load(Boot.SHADER_WARMUP_PATH) as Script
	_probe = ps.new()
	_probe.name = "BootRealProbe"
	root.add_child(_probe)
	_probe.call(&"_setup_3d_rig")
	_probe.call(&"_build_ui")
	_probe.set(&"_safe_compile", true)
	_probe.set(&"_shader_warmup_script", _sw_script)
	_probe.set(&"_render_warm_script", ResourceLoader.load(Boot.RENDER_WARM_PATH))
	_probe.set(&"_main_packed", packed)
	_probe.set(&"_state", Boot.State.WARM_SHADERS)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames > 6000:
		var pr := _probe if (_probe != null and is_instance_valid(_probe)) else null
		print("timeout state=", pr.get(&"_state") if pr else "freed", " done=", (pr.get(&"_shader_warm").get(&"done_count") if pr and pr.get(&"_shader_warm") else "-"), "/", (pr.get(&"_shader_warm").get(&"total_count") if pr and pr.get(&"_shader_warm") else "-"))
		_check(false, "timed out in phase %d" % _phase)
		return _end()
	if _mode == "full":
		if _phase == 0 and not is_instance_valid(_probe):
			_check(FileAccess.get_file_as_string(_build_file).contains("warmed=1"), "full: warmed=1 after normal finish")
			_check(not ShaderRefresh.needs_compile(), "full: needs_compile false after")
			return _end()
		return false
	match _phase:
		0:
			if _frames == 40:
				var w := _probe.get(&"_shader_warm") as Node
				_check(w != null, "real ShaderWarmup node exists")
				_check(w != null and not bool(w.call(&"is_done")), "real warm-up still running after 40 frames")
				_check(int(_probe.get(&"_state")) == Boot.State.WARM_SHADERS, "state WARM_SHADERS")
				var sb := _probe.get(&"_skip_btn") as Button
				_check(sb != null and sb.visible and not sb.disabled, "Skip button enabled while shaders warm")
				print("progress ", w.get(&"done_count"), "/", w.get(&"total_count"), " eta ", _probe.get(&"_eta_sec"))
				_dropped = [w, _probe.get(&"_warm_holder"), _probe.get(&"_boot_cam"), _probe.get(&"_boot_sun")]
				_probe.call(&"_on_skip_pressed")
				var warn := _probe.get(&"_skip_warning") as Control
				_check(warn.visible, "first Skip shows warning")
				_check(sb.disabled, "Skip disabled while warning open")
				_check(not bool(_probe.get(&"_skipped")), "first Skip does not skip")
				_check(w != null and is_instance_valid(w), "warm-up keeps running under the warning")
				_phase = 1
		1:
			if _frames == 60:
				var wb := _probe.get(&"_skip_wait_btn") as Button
				print("wait text: ", wb.text)
				_check(wb.text.begins_with("Wait"), "Wait button text starts with Wait")
				var esc := InputEventKey.new()
				esc.keycode = KEY_ESCAPE
				esc.pressed = true
				_check(bool(_probe.call(&"_handle_skip_key", esc)), "Esc handled")
				_check(not (_probe.get(&"_skip_warning") as Control).visible, "Esc closes warning (= Wait)")
				_check(not bool(_probe.get(&"_skipped")), "Esc did not skip")
				_probe.call(&"_on_skip_pressed")
				_probe.call(&"_on_skip_confirm")
				_check(bool(_probe.get(&"_skipped")), "second Skip skips")
				_check(int(_probe.get(&"_state")) == Boot.State.PRE_HANDOFF, "PRE_HANDOFF")
				var w2 := _dropped[0] as Node
				_check(w2 == null or not is_instance_valid(w2) or w2.is_queued_for_deletion(), "ShaderWarmup node dropped")
				_phase = 2
		2:
			if not is_instance_valid(_probe):
				for n in _dropped:
					_check(not is_instance_valid(n), "dropped after handoff: %s" % str(n))
				_check(current_scene != null and current_scene.name == "RealMain", "handed off to Main")
				_check(FileAccess.get_file_as_string(_build_file) == "stamp=%s\nwarmed=0\n" % _stamp, "build file still warmed=0")
				_check(ShaderRefresh.needs_compile(), "needs_compile true after skip (next start warms again)")
				var left := 0
				for c in root.get_children():
					if c.name.begins_with("ShaderWarmup") or c.name.begins_with("RenderWarm"):
						left += 1
				_check(left == 0, "no ShaderWarmup/RenderWarm nodes left under root")
				return _end()
	return false


func _end() -> bool:
	SafeDelete.remove_tree_checked(_temp)
	print("BOOT SKIP REAL FAILS: %d" % _fails)
	quit(1 if _fails > 0 else 0)
	return true
