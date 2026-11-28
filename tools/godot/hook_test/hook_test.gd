extends Node3D
## The upscaler hook's window test (FSR 4 plan step 2), run by tools/godot/hook_window_test.ps1 in an export
## of this project made with Zenith's patched Godot template. Draws a small lit scene, then:
##   A: Bilinear at scale 1.0 (Godot's own path, the reference);
##   B: ZenithHookUpscaler (the do-nothing native copy through the hook) at scale 1.0: must match A;
##   C: the same at scale 0.5: the top-left quarter of the output gets the picture;
##   D: back to Bilinear, a few frames (letting go of the hook cleanly).
## Writes result.json and A/B/C pictures to --out=<dir>, quits 0 when every check passed, 1 otherwise.
## Headless (no rendering device) it only reports whether the hook is in the build (hook_in_build).
##   <exe> --rendering-driver d3d12 --gpu-validation --log-file <dir>/godot.log -- --out=<dir> --frames=120

var frames := 120
var out_dir := "user://"
var result := {}
var failed: Array[String] = []


func _ready() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--frames="):
			frames = maxi(10, a.get_slice("=", 1).to_int())
		elif a.begins_with("--out="):
			out_dir = a.get_slice("=", 1)
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
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 20)
	ground.mesh = plane
	add_child(ground)


func _wait(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame


func _shot(name: String) -> Image:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(out_dir.path_join("hook_%s.png" % name))
	return img


## Mean brightness (0..1) of a region, sampled on an 8-pixel grid.
static func mean_brightness(img: Image, region: Rect2i) -> float:
	var total := 0.0
	var n := 0
	for y in range(region.position.y, region.end.y, 8):
		for x in range(region.position.x, region.end.x, 8):
			var c := img.get_pixel(x, y)
			total += (c.r + c.g + c.b) / 3.0
			n += 1
	return total / maxf(1.0, n)


## Mean absolute difference (0..1) of two same-size pictures, on an 8-pixel grid.
static func mean_difference(a: Image, b: Image) -> float:
	if a.get_size() != b.get_size():
		return 1.0
	var total := 0.0
	var n := 0
	for y in range(0, a.get_height(), 8):
		for x in range(0, a.get_width(), 8):
			var p := a.get_pixel(x, y)
			var q := b.get_pixel(x, y)
			total += (absf(p.r - q.r) + absf(p.g - q.g) + absf(p.b - q.b)) / 3.0
			n += 1
	return total / maxf(1.0, n)


func _check(ok: bool, what: String) -> void:
	if not ok:
		failed.append(what)


func _run() -> void:
	result["driver"] = RenderingServer.get_current_rendering_driver_name()
	result["adapter"] = RenderingServer.get_video_adapter_name()
	result["validation"] = OS.get_cmdline_args().has("--gpu-validation")
	result["extension"] = ClassDB.class_exists("ZenithHookUpscaler")
	if not result["extension"]:
		failed.append("ZenithHookUpscaler not loaded (bin/upscalers DLL missing?)")
		_finish()
		return
	var hook: Object = ClassDB.instantiate("ZenithHookUpscaler")
	result["hook_in_build"] = bool(hook.call("hook_in_build"))
	result["hook_active"] = bool(hook.call("hook_active"))
	_check(result["hook_in_build"], "hook not in this Godot build")
	if DisplayServer.get_name() == "headless" or RenderingServer.get_rendering_device() == null:
		result["headless"] = true
		_finish()
		return
	_check(result["driver"] == "d3d12", "not running on Direct3D 12")
	_check(result["hook_active"], "hook not active on this renderer")
	if not failed.is_empty():
		_finish()
		return

	var vp := get_viewport()
	var full := Rect2i(Vector2i.ZERO, vp.get_texture().get_size())
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = 1.0
	await _wait(frames)
	var a := await _shot("a_bilinear")

	_check(bool(hook.call("attach", vp)), "attach failed")
	vp.scaling_3d_scale = 1.0
	await _wait(frames)
	var b := await _shot("b_hook_1.0")
	var stats_b: Dictionary = hook.call("stats")

	vp.scaling_3d_scale = 0.5
	await _wait(frames)
	var c := await _shot("c_hook_0.5")
	var stats_c: Dictionary = hook.call("stats")

	hook.call("detach")
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = 1.0
	await _wait(10)

	result["stats_1_0"] = stats_b
	result["stats_0_5"] = stats_c
	result["brightness_a"] = mean_brightness(a, full)
	result["brightness_b"] = mean_brightness(b, full)
	var quarter := Rect2i(Vector2i.ZERO, full.size / 2)
	result["brightness_c_top_left"] = mean_brightness(c, quarter)
	result["difference_a_b"] = mean_difference(a, b)
	_check(float(result["brightness_a"]) > 0.05, "reference picture is black")
	_check(float(result["brightness_b"]) > 0.05, "hook picture (1.0) is black")
	_check(float(result["brightness_c_top_left"]) > 0.05, "hook picture (0.5) top-left is black")
	_check(float(result["difference_a_b"]) < 0.02, "hook picture (1.0) differs from Bilinear")
	_check(int(stats_b.get("recorded", 0)) >= frames / 2, "native callback ran too few times")
	_check(int(stats_c.get("failures", 0)) == 0, "render callbacks failed")
	_check(int(stats_c.get("null_resources", 0)) == 0, "null D3D12 resources handed over")
	_check(int(stats_c.get("api", 0)) == 1, "native API is not Direct3D 12")
	_check(int(stats_c.get("resource_count", 0)) >= 3, "depth/velocity not handed over")
	_check(stats_c.get("output_size", Vector2i.ZERO) == Vector2i(full.size), "output size is not the window's")
	_finish()


func _finish() -> void:
	result["failed"] = failed
	result["passed"] = failed.is_empty()
	var f := FileAccess.open(out_dir.path_join("result.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(result, "\t"))
		f.close()
	print("hook_test: ", JSON.stringify(result))
	get_tree().quit(0 if failed.is_empty() else 1)
