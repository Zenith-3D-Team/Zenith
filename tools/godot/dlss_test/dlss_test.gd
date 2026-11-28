extends "res://hook_test.gd"
## NVIDIA DLSS's window test (FSR 4 plan step 7), run by tools/godot/dlss_window_test.ps1 in an export of hook_test's
## project with this scene, made with Zenith's patched Godot template, with vendor/nvidia beside the program (Zenith's
## Streamline build and the owner's own nvngx_dlss.dll). Draws hook_test's scene, then:
##   A: Bilinear at scale 1.0 (Godot's own path, the reference);
##   B: ZenithDlssUpscaler at 1.0 (DLAA): close to A;
##   C: at 0.67 (Quality) with the boxes turning (motion vectors);
##   D: at 0.5 (Performance), still turning;
##   E: back to Bilinear, a few frames (DLSS let go), then Streamline shut down.
## Writes result.json and the pictures (dlss_*.png) to --out=<dir>, quits 0 when every check passed, 1 otherwise.
## Headless it only reports whether the build and the runtime are there (built_with_sl, runtime_problem).
##   <exe> --rendering-driver d3d12 --gpu-validation --log-file <dir>/godot.log -- --out=<dir> --frames=120
##       [--dlss-jitter=flip|flip-y] [--dlss-barriers=direct]

const DLSS := "ZenithDlssUpscaler"

var _turning := false
var _jitter := 0
var _barriers := 0


func _process(delta: float) -> void:
	if not _turning:
		return
	for c in get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh is BoxMesh:
			(c as Node3D).rotate_y(delta * 1.5)


func _shot(name: String) -> Image:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(out_dir.path_join("dlss_%s.png" % name))
	return img


func _nvidia_dir() -> String:
	return OS.get_executable_path().get_base_dir().path_join("vendor/nvidia")


func _run() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a == "--dlss-jitter=flip":
			_jitter = 1
		elif a == "--dlss-jitter=flip-y":
			_jitter = 2
		elif a == "--dlss-barriers=direct":
			_barriers = 1
	result["driver"] = RenderingServer.get_current_rendering_driver_name()
	result["adapter"] = RenderingServer.get_video_adapter_name()
	result["validation"] = OS.get_cmdline_args().has("--gpu-validation")
	result["extension"] = ClassDB.class_exists(DLSS)
	if not result["extension"]:
		failed.append("ZenithDlssUpscaler not loaded (bin/upscalers DLL missing?)")
		_finish()
		return
	var nvidia := _nvidia_dir()
	result["built_with_sl"] = bool(ClassDB.class_call_static(DLSS, "built_with_sl"))
	result["runtime_problem"] = str(ClassDB.class_call_static(DLSS, "runtime_problem", nvidia))
	result["dlss_file_version"] = str(ClassDB.class_call_static(DLSS, "dlss_file_version", nvidia))
	result["available"] = bool(ClassDB.class_call_static(DLSS, "available"))
	_check(result["built_with_sl"], "the upscalers DLL was built without Streamline's headers")
	_check(result["runtime_problem"] == "", "DLSS's runtime doesn't load: %s" % result["runtime_problem"])
	if DisplayServer.get_name() == "headless" or RenderingServer.get_rendering_device() == null:
		result["headless"] = true
		_finish()
		return
	_check(result["driver"] == "d3d12", "not running on Direct3D 12")
	_check(result["available"], "DLSS not available (engine hook inactive?)")
	if not failed.is_empty():
		_finish()
		return

	var vp := get_viewport()
	var full := Rect2i(Vector2i.ZERO, vp.get_texture().get_size())
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = 1.0
	await _wait(frames)
	var a := await _shot("a_bilinear")

	var dlss: Object = ClassDB.instantiate(DLSS)
	dlss.call("set_jitter_sign", _jitter)
	dlss.call("set_barrier_mode", _barriers)
	dlss.call("set_quality", "native")
	_check(bool(dlss.call("attach", vp, nvidia)), "attach failed")
	vp.scaling_3d_scale = 1.0
	await _wait(frames)
	var b := await _shot("b_dlaa_1.0")
	var stats_b: Dictionary = dlss.call("stats")

	_turning = true
	dlss.call("set_quality", "quality")
	dlss.call("set_render_scale", 0.67)
	vp.scaling_3d_scale = 0.67
	await _wait(frames)
	var c := await _shot("c_quality_0.67")
	var stats_c: Dictionary = dlss.call("stats")

	dlss.call("set_quality", "performance")
	dlss.call("set_render_scale", 0.5)
	vp.scaling_3d_scale = 0.5
	await _wait(frames)
	var d := await _shot("d_performance_0.5")
	var stats_d: Dictionary = dlss.call("stats")
	_turning = false

	dlss.call("detach")
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = 1.0
	await _wait(10)
	ClassDB.class_call_static(DLSS, "shutdown")
	await _wait(5)

	result["stats_1_0"] = stats_b
	result["stats_0_67"] = stats_c
	result["stats_0_5"] = stats_d
	result["brightness_a"] = mean_brightness(a, full)
	result["brightness_b"] = mean_brightness(b, full)
	result["brightness_c"] = mean_brightness(c, full)
	result["brightness_d"] = mean_brightness(d, full)
	result["difference_a_b"] = mean_difference(a, b)
	_check(float(result["brightness_a"]) > 0.05, "reference picture is black")
	_check(float(result["brightness_b"]) > 0.05, "DLSS picture (DLAA 1.0) is black")
	_check(float(result["brightness_c"]) > 0.05, "DLSS picture (Quality 0.67) is black")
	_check(float(result["brightness_d"]) > 0.05, "DLSS picture (Performance 0.5) is black")
	_check(float(result["difference_a_b"]) < 0.08, "DLAA picture differs a lot from Bilinear (%.3f)" % float(result["difference_a_b"]))
	for s: Dictionary in [stats_b, stats_c, stats_d]:
		_check(bool(s.get("sl_ready", false)), "Streamline didn't start: %s" % str(s.get("problem", "")))
		_check(str(s.get("problem", "")) == "", "DLSS reported: %s" % str(s.get("problem", "")))
		_check(int(s.get("failures", 0)) == 0, "failed frames: %d" % int(s.get("failures", 0)))
		_check(int(s.get("api", 0)) == 1, "native API is not Direct3D 12")
		_check(s.get("output_size", Vector2i.ZERO) == Vector2i(full.size), "output size is not the window's")
	_check(int(stats_b.get("evaluated", 0)) >= frames / 2, "DLSS evaluated too few times at 1.0")
	_check(int(stats_d.get("evaluated", 0)) >= int(stats_c.get("evaluated", 0)) + frames / 2, "DLSS evaluated too few times at 0.5")
	_check(int(stats_d.get("presents", 0)) >= int(stats_d.get("evaluated", 1)), "Streamline's per-frame bookkeeping (slHookPresent) not run each frame")
	_check(stats_d.get("render_size", Vector2i.ZERO) == Vector2i(full.size / 2), "render size at 0.5 is not half the window")
	_check(stats_d.get("optimal_size", Vector2i.ZERO) != Vector2i.ZERO, "DLSS's optimal render size not read")
	_finish()
