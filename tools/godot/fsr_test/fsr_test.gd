extends Node3D
## AMD FSR's window test (FSR 4 plan step 4), run by tools/godot/fsr_window_test.ps1 in an export of hook_test's
## project with this scene, made with Zenith's patched Godot template, vendor/amd beside the program. Draws
## hook_test's lit scene, then:
##   A: Bilinear at scale 1.0 (Godot's own path, the reference);
##   B: AMD FSR (--version, 3.1 by default) at 1.0 (native AA): must look like A;
##   C: the same at 0.5 (a new AMD context): the whole output upscaled, not black, close to A;
##   M: at 0.5 with the boxes moving (motion vectors, jitter), no failures;
##   D: back to Bilinear, a few frames (AMD's context freed after the GPU is done).
## Writes result.json and fsr_*.png to --out=<dir>, quits 0 when every check passed, 1 otherwise. Headless (no
## rendering device) it only reports whether the class, the SDK and AMD's runtime are there.
##   <exe> --rendering-driver d3d12 --gpu-validation --log-file <dir>/godot.log -- --out=<dir> --frames=120
##       [--version=4.1] [--fsr-debug] [--fsr-barriers=direct] [--fsr-driver-version=on]

const HookTest := preload("res://hook_test.gd")

var frames := 120
var out_dir := "user://"
var version := "3.1"
var debug_checking := false
var barrier_mode := 0
var driver_version := false
var result := {}
var failed: Array[String] = []
var movers: Array[Node3D] = []
var moving := false


func _ready() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--frames="):
			frames = maxi(10, a.get_slice("=", 1).to_int())
		elif a.begins_with("--out="):
			out_dir = a.get_slice("=", 1)
		elif a.begins_with("--version="):
			version = a.get_slice("=", 1)
		elif a == "--fsr-debug":
			debug_checking = true
		elif a == "--fsr-barriers=direct":
			barrier_mode = 1
		elif a == "--fsr-driver-version=on":
			driver_version = true
	# hook_test's scene, with half the boxes able to move (phase M).
	_build_scene()
	_run.call_deferred()


func _build_scene() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.25, 0.35, 0.5)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.4, 0.4)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 4, 8)
	add_child(cam)
	cam.look_at(Vector3.ZERO)
	var colours := [Color(0.8, 0.3, 0.2), Color(0.3, 0.7, 0.3), Color(0.9, 0.8, 0.2), Color(0.6, 0.6, 0.65)]
	for i in range(8):
		var m := MeshInstance3D.new()
		m.mesh = BoxMesh.new() if i % 2 == 0 else SphereMesh.new()
		var mat := StandardMaterial3D.new()
		mat.albedo_color = colours[i % colours.size()]
		m.material_override = mat
		m.position = Vector3((i % 4) * 2.2 - 3.3, 0.5, float(i / 4) * 2.2 - 1.1)
		add_child(m)
		if i % 2 == 0:
			movers.append(m)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 20)
	ground.mesh = plane
	add_child(ground)


func _process(delta: float) -> void:
	if moving:
		for m: Node3D in movers:
			m.rotate_y(delta * 2.0)
			m.position.x += sin(Time.get_ticks_msec() * 0.003) * delta


func _wait(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame


func _shot(name: String) -> Image:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(out_dir.path_join("fsr_%s.png" % name))
	return img


func _check(ok: bool, what: String) -> void:
	if not ok:
		failed.append(what)


func _run() -> void:
	var amd_dir := OS.get_executable_path().get_base_dir().path_join("vendor/amd")
	result["driver"] = RenderingServer.get_current_rendering_driver_name()
	result["adapter"] = RenderingServer.get_video_adapter_name()
	result["validation"] = OS.get_cmdline_args().has("--gpu-validation")
	result["extension"] = ClassDB.class_exists("ZenithFsrUpscaler")
	if not result["extension"]:
		failed.append("ZenithFsrUpscaler not loaded (bin/upscalers DLL missing or older than step 4?)")
		_finish()
		return
	result["built_with_sdk"] = bool(ClassDB.class_call_static("ZenithFsrUpscaler", "built_with_sdk"))
	result["runtime_problem"] = str(ClassDB.class_call_static("ZenithFsrUpscaler", "runtime_problem", amd_dir))
	result["runtime_file_version"] = str(ClassDB.class_call_static("ZenithFsrUpscaler", "runtime_file_version", amd_dir))
	result["available"] = bool(ClassDB.class_call_static("ZenithFsrUpscaler", "available"))
	_check(bool(result["built_with_sdk"]), "the upscalers DLL was built without AMD's SDK headers")
	_check(str(result["runtime_problem"]) == "", "AMD's runtime doesn't load: %s" % result["runtime_problem"])
	if DisplayServer.get_name() == "headless" or RenderingServer.get_rendering_device() == null:
		result["headless"] = true
		_finish()
		return
	_check(result["driver"] == "d3d12", "not running on Direct3D 12")
	_check(bool(result["available"]), "the engine hook isn't active on this renderer")
	if not failed.is_empty():
		_finish()
		return

	var vp := get_viewport()
	var full := Rect2i(Vector2i.ZERO, vp.get_texture().get_size())
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = 1.0
	await _wait(frames)
	var a := await _shot("a_bilinear")

	var fsr: Object = ClassDB.instantiate("ZenithFsrUpscaler")
	fsr.call("set_version", version)
	fsr.call("set_sharpness", 0.5)
	fsr.call("set_debug_checking", debug_checking)
	fsr.call("set_barrier_mode", barrier_mode)
	fsr.call("set_driver_version", driver_version)
	vp.scaling_3d_scale = 1.0
	_check(bool(fsr.call("attach", vp, amd_dir)), "attach failed")
	await _wait(frames)
	var b := await _shot("b_fsr_1.0")
	var stats_b: Dictionary = fsr.call("stats")

	fsr.call("set_render_scale", 0.5)
	vp.scaling_3d_scale = 0.5
	await _wait(frames)
	var c := await _shot("c_fsr_0.5")
	var stats_c: Dictionary = fsr.call("stats")

	moving = true
	await _wait(frames)
	var m := await _shot("m_fsr_0.5_moving")
	moving = false
	var stats_m: Dictionary = fsr.call("stats")

	fsr.call("detach")
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = 1.0
	await _wait(10)
	var stats_d: Dictionary = fsr.call("stats")

	result["stats_1_0"] = stats_b
	result["stats_0_5"] = stats_c
	result["stats_moving"] = stats_m
	result["stats_after_detach"] = stats_d
	result["brightness_a"] = HookTest.mean_brightness(a, full)
	result["brightness_b"] = HookTest.mean_brightness(b, full)
	result["brightness_c"] = HookTest.mean_brightness(c, full)
	result["brightness_m"] = HookTest.mean_brightness(m, full)
	result["difference_a_b"] = HookTest.mean_difference(a, b)
	result["difference_a_c"] = HookTest.mean_difference(a, c)
	_check(float(result["brightness_a"]) > 0.05, "reference picture is black")
	_check(float(result["brightness_b"]) > 0.05, "FSR picture (1.0) is black")
	_check(float(result["brightness_c"]) > 0.05, "FSR picture (0.5) is black")
	_check(float(result["brightness_m"]) > 0.05, "FSR picture (moving) is black")
	# Native AA smooths edges and sharpens a little: close to Bilinear, not equal.
	_check(float(result["difference_a_b"]) < 0.06, "FSR picture (1.0) differs from Bilinear")
	_check(float(result["difference_a_c"]) < 0.10, "FSR picture (0.5) differs from Bilinear (not the whole picture upscaled?)")
	_check(int(stats_b.get("dispatched", 0)) >= frames / 2, "AMD's dispatch ran too few times")
	_check(int(stats_m.get("failures", 0)) == 0, "failures: %s" % str(stats_m.get("problem", "")))
	_check(int(stats_m.get("creates", 0)) >= 2, "no new AMD context for the new render size")
	_check(int(stats_m.get("api", 0)) == 1, "native API is not Direct3D 12")
	_check(str(stats_b.get("version_created", "")).contains(version), "AMD made %s, not %s" % [stats_b.get("version_created", "?"), version])
	_check(stats_m.get("output_size", Vector2i.ZERO) == Vector2i(full.size), "output size is not the window's")
	_check(stats_c.get("render_size", Vector2i.ZERO) == Vector2i(full.size / 2), "render size at 0.5 is not half the window")
	_finish()


func _finish() -> void:
	result["failed"] = failed
	result["passed"] = failed.is_empty()
	var f := FileAccess.open(out_dir.path_join("result.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(result, "\t"))
		f.close()
	print("fsr_test: ", JSON.stringify(result))
	get_tree().quit(0 if failed.is_empty() else 1)
