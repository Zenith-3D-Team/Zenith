extends SceneTree
## Tests TextureCompressNative (clean-room BC1/DXT1 & BC3/DXT5 compressor), mipmap chain layout,
## Godot Image.decompress() round-trip accuracy, and integration with terrain_textures.gd /
## decoratives.gd under --native-bc-compress=force and =off.
##   godot --headless --audio-driver Dummy --path client -s res://tests/texture_compress_native_test.gd -- --native-bc-compress=force

const NativeLibrary := preload("res://scripts/native_library.gd")
const Switches := preload("res://scripts/switches.gd")
const TerrainTextures := preload("res://scripts/world/terrain_textures.gd")
const Decoratives := preload("res://scripts/world/decoratives.gd")
const TestEnv := preload("res://tests/test_env.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _initialize() -> void:
	TestEnv.isolate("texture-compress-native-test")
	var loaded: bool = NativeLibrary.ensure()
	check(loaded, "NativeLibrary.ensure() succeeds")
	check(ClassDB.class_exists(&"TextureCompressNative"), "TextureCompressNative class is registered")
	if ClassDB.class_exists(&"TextureCompressNative"):
		var comp: Object = ClassDB.instantiate(&"TextureCompressNative")
		check(comp != null, "TextureCompressNative instantiates")
		if comp != null:
			check(int(comp.call(&"version")) >= 1, "TextureCompressNative.version() >= 1")
			_test_edge_cases(comp)
			_test_bc1_accuracy(comp)
			_test_bc3_accuracy(comp)
			_test_mipmaps_and_sizes(comp)
			_test_integration(comp)
	print("TEXTURE COMPRESS NATIVE FAILS: %d" % fails)
	TestEnv.clean()
	quit(1 if fails > 0 else 0)


func _rgba_bytes(w: int, h: int, pixel_fn: Callable) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(w * h * 4)
	for y in h:
		for x in w:
			var c: Color = pixel_fn.call(x, y)
			var idx := (y * w + x) * 4
			out[idx] = clampi(roundi(c.r * 255.0), 0, 255)
			out[idx + 1] = clampi(roundi(c.g * 255.0), 0, 255)
			out[idx + 2] = clampi(roundi(c.b * 255.0), 0, 255)
			out[idx + 3] = clampi(roundi(c.a * 255.0), 0, 255)
	return out


func _rgba_error(src: PackedByteArray, dec: PackedByteArray, w: int, h: int, check_alpha: bool) -> Dictionary:
	var count := w * h
	var sum_sq_rgb := 0.0
	var sum_sq_a := 0.0
	var max_rgb := 0
	var max_a := 0
	for i in count:
		var o := i * 4
		var dr := absi(int(src[o]) - int(dec[o]))
		var dg := absi(int(src[o + 1]) - int(dec[o + 1]))
		var db := absi(int(src[o + 2]) - int(dec[o + 2]))
		var da := absi(int(src[o + 3]) - int(dec[o + 3]))
		max_rgb = maxi(max_rgb, maxi(dr, maxi(dg, db)))
		sum_sq_rgb += float(dr * dr + dg * dg + db * db)
		if check_alpha:
			max_a = maxi(max_a, da)
			sum_sq_a += float(da * da)
	return {
		"rgb_rmse": sqrt(sum_sq_rgb / float(maxi(count * 3, 1))),
		"alpha_rmse": sqrt(sum_sq_a / float(maxi(count, 1))),
		"max_rgb": max_rgb,
		"max_a": max_a,
	}


func _expected_bc_bytes(w: int, h: int, alpha: bool, mipmaps: bool) -> int:
	var block_bytes := 16 if alpha else 8
	var total := 0
	var mw := w
	var mh := h
	while true:
		var bx := (mw + 3) >> 2
		var by := (mh + 3) >> 2
		total += bx * by * block_bytes
		if not mipmaps or (mw == 1 and mh == 1):
			break
		mw = maxi(1, mw >> 1)
		mh = maxi(1, mh >> 1)
	return total


func _test_edge_cases(comp: Object) -> void:
	var empty := PackedByteArray()
	var bad_bc1: PackedByteArray = comp.call(&"compress_bc1", empty, 0, 0, true)
	var bad_bc3: PackedByteArray = comp.call(&"compress_bc3", empty, 4, 4, false)
	check(bad_bc1.is_empty() and bad_bc3.is_empty(), "invalid/empty inputs return empty bytes")

	var tiny_src := PackedByteArray([200, 100, 50, 255])
	var tiny_bc1: PackedByteArray = comp.call(&"compress_bc1", tiny_src, 1, 1, true)
	var tiny_bc3: PackedByteArray = comp.call(&"compress_bc3", tiny_src, 1, 1, true)
	check(tiny_bc1.size() == 8 and tiny_bc3.size() == 16, "1x1 BC1=8B, BC3=16B")
	var img1 := Image.create_from_data(1, 1, false, Image.FORMAT_DXT1, tiny_bc1)
	check(img1 != null and img1.decompress() == OK, "1x1 DXT1 decompresses via Godot")
	if img1 != null:
		var p := img1.get_pixel(0, 0)
		check(absi(roundi(p.r * 255.0) - 200) <= 8 and absi(roundi(p.g * 255.0) - 100) <= 6 and absi(roundi(p.b * 255.0) - 50) <= 8 and p.a > 0.99,
			"1x1 DXT1 preserves color and opaque alpha")

	# Non-multiple-of-4 dimensions (5x7) with mipmaps down to 1x1.
	var odd_fill := func(x: int, y: int) -> Color:
		return Color(float(x) / 4.0, float(y) / 6.0, 0.5, float(x + y) / 10.0)
	var odd_src := _rgba_bytes(5, 7, odd_fill)
	var odd_bc1: PackedByteArray = comp.call(&"compress_bc1", odd_src, 5, 7, true)
	var odd_bc3: PackedByteArray = comp.call(&"compress_bc3", odd_src, 5, 7, true)
	check(odd_bc1.size() == _expected_bc_bytes(5, 7, false, true), "5x7 mipmapped BC1 byte count matches spec (%d)" % odd_bc1.size())
	check(odd_bc3.size() == _expected_bc_bytes(5, 7, true, true), "5x7 mipmapped BC3 byte count matches spec (%d)" % odd_bc3.size())
	var img_odd1 := Image.create_from_data(5, 7, true, Image.FORMAT_DXT1, odd_bc1)
	var img_odd3 := Image.create_from_data(5, 7, true, Image.FORMAT_DXT5, odd_bc3)
	check(img_odd1 != null and img_odd1.decompress() == OK, "5x7 mipmapped DXT1 decompresses cleanly")
	check(img_odd3 != null and img_odd3.decompress() == OK, "5x7 mipmapped DXT5 decompresses cleanly")


func _test_bc1_accuracy(comp: Object) -> void:
	# 1. Solid colors (RGB565 round-trip).
	var solids: Array[Color] = [
		Color(1.0, 0.0, 0.0, 1.0),
		Color(0.0, 1.0, 0.0, 1.0),
		Color(0.0, 0.0, 1.0, 1.0),
		Color(1.0, 1.0, 1.0, 1.0),
		Color(0.0, 0.0, 0.0, 1.0),
		Color(128.0 / 255.0, 64.0 / 255.0, 192.0 / 255.0, 1.0),
	]
	for c: Color in solids:
		var src := _rgba_bytes(8, 8, func(_x: int, _y: int) -> Color: return c)
		var bc1: PackedByteArray = comp.call(&"compress_bc1", src, 8, 8, false)
		var img := Image.create_from_data(8, 8, false, Image.FORMAT_DXT1, bc1)
		check(img != null and img.decompress() == OK, "solid BC1 decompresses")
		if img != null:
			var err := _rgba_error(src, img.get_data(), 8, 8, true)
			check(int(err["max_rgb"]) <= 8 and int(err["max_a"]) == 0,
				"solid BC1 %s round-trip max_rgb=%d max_a=%d" % [c, int(err["max_rgb"]), int(err["max_a"])])

	# 2. Smooth 2D + anti-correlated gradient (R increases while G decreases).
	var grad_fill := func(x: int, y: int) -> Color:
		return Color(float(x) / 63.0, 1.0 - float(x) / 63.0, float(y) / 63.0, 1.0)
	var grad_src := _rgba_bytes(64, 64, grad_fill)
	var grad_bc1: PackedByteArray = comp.call(&"compress_bc1", grad_src, 64, 64, true)
	var grad_img := Image.create_from_data(64, 64, true, Image.FORMAT_DXT1, grad_bc1)
	check(grad_img != null and grad_img.decompress() == OK, "64x64 gradient DXT1 decompresses")
	if grad_img != null:
		var dec_lvl0 := grad_img.get_data().slice(0, 64 * 64 * 4)
		var gerr := _rgba_error(grad_src, dec_lvl0, 64, 64, true)
		check(float(gerr["rgb_rmse"]) < 6.0 and int(gerr["max_a"]) == 0,
			"64x64 anti-correlated gradient BC1 RMSE=%.2f max_rgb=%d" % [float(gerr["rgb_rmse"]), int(gerr["max_rgb"])])


func _test_bc3_accuracy(comp: Object) -> void:
	# 1. Smooth RGB + smooth alpha ramp.
	var bc3_fill := func(x: int, y: int) -> Color:
		return Color(float(x) / 63.0, float(y) / 63.0, 0.25, float(x + y) / 126.0)
	var src := _rgba_bytes(64, 64, bc3_fill)
	var bc3: PackedByteArray = comp.call(&"compress_bc3", src, 64, 64, true)
	var img := Image.create_from_data(64, 64, true, Image.FORMAT_DXT5, bc3)
	check(img != null and img.decompress() == OK, "64x64 alpha ramp DXT5 decompresses")
	if img != null:
		var dec_lvl0 := img.get_data().slice(0, 64 * 64 * 4)
		var err := _rgba_error(src, dec_lvl0, 64, 64, true)
		check(float(err["rgb_rmse"]) < 6.0 and float(err["alpha_rmse"]) < 4.0,
			"64x64 BC3 rgb_rmse=%.2f alpha_rmse=%.2f" % [float(err["rgb_rmse"]), float(err["alpha_rmse"])])

	# 2. Hard 0/255 alpha + intermediate fringe alpha in the same 4x4 block (exercises 6-alpha mode).
	var fringe_fill := func(x: int, _y: int) -> Color:
		var m := x % 4
		var a := 0.0 if m == 0 else (0.25 if m == 1 else (0.75 if m == 2 else 1.0))
		return Color(0.2, 0.7, 0.3, a)
	var fringe_src := _rgba_bytes(8, 8, fringe_fill)
	var fringe_bc3: PackedByteArray = comp.call(&"compress_bc3", fringe_src, 8, 8, false)
	var fringe_img := Image.create_from_data(8, 8, false, Image.FORMAT_DXT5, fringe_bc3)
	check(fringe_img != null and fringe_img.decompress() == OK, "mixed 0/255+fringe BC3 decompresses")
	if fringe_img != null:
		var ferr := _rgba_error(fringe_src, fringe_img.get_data(), 8, 8, true)
		check(int(ferr["max_a"]) <= 6 and float(ferr["alpha_rmse"]) < 3.0,
			"mixed 0/255+fringe BC3 preserves endpoints (max_a=%d alpha_rmse=%.2f)" % [int(ferr["max_a"]), float(ferr["alpha_rmse"])])


func _test_mipmaps_and_sizes(comp: Object) -> void:
	# 1. Non-square 256x128 mipmap chain down to 1x1.
	var fill_256 := func(x: int, y: int) -> Color:
		return Color(float(x) / 255.0, float(y) / 127.0, 0.4, 0.8)
	var src_256 := _rgba_bytes(256, 128, fill_256)
	var bc1_256: PackedByteArray = comp.call(&"compress_bc1", src_256, 256, 128, true)
	var bc3_256: PackedByteArray = comp.call(&"compress_bc3", src_256, 256, 128, true)
	var exp1_256 := _expected_bc_bytes(256, 128, false, true)
	var exp3_256 := _expected_bc_bytes(256, 128, true, true)
	check(bc1_256.size() == exp1_256 and int(comp.call(&"expected_size", 256, 128, false, true)) == exp1_256,
		"256x128 BC1 mipmap size = %d" % exp1_256)
	check(bc3_256.size() == exp3_256 and int(comp.call(&"expected_size", 256, 128, true, true)) == exp3_256,
		"256x128 BC3 mipmap size = %d" % exp3_256)

	var dxt1_256 := Image.create_from_data(256, 128, true, Image.FORMAT_DXT1, bc1_256)
	var dxt5_256 := Image.create_from_data(256, 128, true, Image.FORMAT_DXT5, bc3_256)
	check(dxt1_256 != null and dxt1_256.has_mipmaps() and dxt1_256.get_mipmap_count() == 8 and dxt1_256.decompress() == OK,
		"256x128 DXT1 has 8 mip levels down to 1x1 and decompresses")
	check(dxt5_256 != null and dxt5_256.has_mipmaps() and dxt5_256.get_mipmap_count() == 8 and dxt5_256.decompress() == OK,
		"256x128 DXT5 has 8 mip levels down to 1x1 and decompresses")

	# 2. Verify 2x2 box-filter mipmap averaging down to 1x1 (4x4 image with 4 quadrants).
	var quad_fill := func(x: int, y: int) -> Color:
		if x < 2 and y < 2:
			return Color(1.0, 0.0, 0.0, 1.0)
		if x >= 2 and y < 2:
			return Color(0.0, 1.0, 0.0, 1.0)
		if x < 2 and y >= 2:
			return Color(0.0, 0.0, 1.0, 1.0)
		return Color(1.0, 1.0, 1.0, 1.0)
	var quad := _rgba_bytes(4, 4, quad_fill)
	var quad_bc1: PackedByteArray = comp.call(&"compress_bc1", quad, 4, 4, true)
	var quad_img := Image.create_from_data(4, 4, true, Image.FORMAT_DXT1, quad_bc1)
	check(quad_img != null and quad_img.decompress() == OK, "4x4 quadrant mip chain decompresses")
	if quad_img != null:
		var mip2_off := quad_img.get_mipmap_offset(2)  # 1x1 mip
		var d := quad_img.get_data()
		# Average of (255,0,0), (0,255,0), (0,0,255), (255,255,255) = (128, 128, 128).
		check(absi(int(d[mip2_off]) - 128) <= 8 and absi(int(d[mip2_off + 1]) - 128) <= 6 and absi(int(d[mip2_off + 2]) - 128) <= 8,
			"1x1 box-filtered mip matches average (%d,%d,%d)" % [int(d[mip2_off]), int(d[mip2_off + 1]), int(d[mip2_off + 2])])

	# 3. 2048x1024 Factorio terrain sheet size reduction (8x for BC1, 4x for BC3 vs RGBA8 mip chain).
	var w := 2048
	var h := 1024
	var rgba_base := PackedByteArray()
	rgba_base.resize(w * h * 4)
	rgba_base.fill(160)
	var bc1_2k: PackedByteArray = comp.call(&"compress_bc1", rgba_base, w, h, true)
	var bc3_2k: PackedByteArray = comp.call(&"compress_bc3", rgba_base, w, h, true)
	var rgba_mip_bytes := 0
	var mw := w
	var mh := h
	while true:
		rgba_mip_bytes += mw * mh * 4
		if mw == 1 and mh == 1:
			break
		mw = maxi(1, mw >> 1)
		mh = maxi(1, mh >> 1)
	check(bc1_2k.size() == _expected_bc_bytes(w, h, false, true), "2048x1024 BC1 mip chain size = %d" % bc1_2k.size())
	check(bc3_2k.size() == _expected_bc_bytes(w, h, true, true), "2048x1024 BC3 mip chain size = %d" % bc3_2k.size())
	check(float(rgba_mip_bytes) / float(bc1_2k.size()) >= 7.9,
		"2048x1024 BC1 achieves ~8x reduction (%d -> %d bytes)" % [rgba_mip_bytes, bc1_2k.size()])
	check(float(rgba_mip_bytes) / float(bc3_2k.size()) >= 3.95,
		"2048x1024 BC3 achieves ~4x reduction (%d -> %d bytes)" % [rgba_mip_bytes, bc3_2k.size()])
	var img_2k := Image.create_from_data(w, h, true, Image.FORMAT_DXT1, bc1_2k)
	check(img_2k != null and img_2k.decompress() == OK, "2048x1024 DXT1 decompresses cleanly")

	# 4. compress_image helper on Image with and without pre-existing mipmaps.
	var ci_fill := func(x: int, y: int) -> Color:
		return Color(float(x) / 31.0, float(y) / 15.0, 0.6, float(x) / 31.0)
	var src_img := Image.create_from_data(32, 16, false, Image.FORMAT_RGBA8, _rgba_bytes(32, 16, ci_fill))
	var out1: Image = comp.call(&"compress_image", src_img, false, true) as Image
	var out3: Image = comp.call(&"compress_image", src_img, true, true) as Image
	check(out1 != null and out1.get_format() == Image.FORMAT_DXT1 and out1.has_mipmaps(), "compress_image(false) returns mipmapped DXT1")
	check(out3 != null and out3.get_format() == Image.FORMAT_DXT5 and out3.has_mipmaps(), "compress_image(true) returns mipmapped DXT5")
	src_img.generate_mipmaps()
	var out_premips: Image = comp.call(&"compress_image", src_img, false, true) as Image
	check(out_premips != null and out_premips.get_format() == Image.FORMAT_DXT1 and out_premips.has_mipmaps() and out_premips.decompress() == OK,
		"compress_image preserves pre-generated mipmaps")


func _test_integration(comp: Object) -> void:
	var saved_args := Switches.args()
	var force_cli := Switches.has("--native-bc-compress=force")
	var off_cli := not Switches.on("--native-bc-compress")

	if force_cli:
		check(TerrainTextures._use_native_bc(), "--native-bc-compress=force enables TerrainTextures._use_native_bc()")
		check(TerrainTextures._compress == 1, "--native-bc-compress=force keeps TerrainTextures._compress == 1")
	elif off_cli:
		check(not TerrainTextures._use_native_bc(), "--native-bc-compress=off disables TerrainTextures._use_native_bc()")
		check(not Decoratives._use_native_bc3(), "--native-bc-compress=off disables Decoratives._use_native_bc3()")
		if not OS.has_feature("editor"):
			check(TerrainTextures._compress == 0 and not Decoratives.sheet_compress, "exported --native-bc-compress=off keeps uncompressed fallback")

	# Verify terrain_textures.gd _finish_layer under force & off.
	var layer_fill := func(x: int, y: int) -> Color:
		return Color(float(x) / 63.0, float(y) / 63.0, 0.3, 1.0)
	var layer := Image.create_from_data(64, 64, false, Image.FORMAT_RGBA8, _rgba_bytes(64, 64, layer_fill))
	var finished := TerrainTextures._finish_layer(layer.duplicate() as Image)
	if force_cli or OS.has_feature("editor"):
		check(finished != null and finished.get_format() == Image.FORMAT_DXT1 and finished.has_mipmaps(),
			"TerrainTextures._finish_layer produces mipmapped DXT1 (%s)" % finished.get_format())
		check(finished != null and (finished.duplicate() as Image).decompress() == OK, "TerrainTextures._finish_layer DXT1 decompresses")

	# Explicit toggle tests using Switches.set_test_args + refresh_compress_mode().
	Switches.set_test_args(PackedStringArray(["--native-bc-compress=force", "--decor-sheet-compress=on"]))
	TerrainTextures.refresh_compress_mode()
	Decoratives.refresh_compress_mode()
	check(TerrainTextures._use_native_bc() and TerrainTextures._compress == 1, "toggle to force enables TerrainTextures native BC1")
	check(Decoratives._use_native_bc3() and Decoratives.sheet_compress, "toggle to force + --decor-sheet-compress=on enables Decoratives.sheet_compress")

	var forced_layer := TerrainTextures._finish_layer(layer.duplicate() as Image)
	check(forced_layer != null and forced_layer.get_format() == Image.FORMAT_DXT1 and forced_layer.has_mipmaps() and (forced_layer.duplicate() as Image).decompress() == OK,
		"TerrainTextures._finish_layer under force routes through TextureCompressNative to DXT1")

	var sheet_fill := func(x: int, _y: int) -> Color:
		return Color(0.4, 0.7, 0.2, float(x) / 63.0)
	var sheet := Image.create_from_data(64, 64, false, Image.FORMAT_RGBA8, _rgba_bytes(64, 64, sheet_fill))
	var comp_sheet := Decoratives.compress_sheet_image(sheet)
	check(comp_sheet != null and comp_sheet.get_format() == Image.FORMAT_DXT5 and comp_sheet.has_mipmaps() and (comp_sheet.duplicate() as Image).decompress() == OK,
		"Decoratives.compress_sheet_image under force produces mipmapped DXT5")
	const Baker := preload("res://scripts/world/decor_sheet_baker.gd")
	var job := Baker.PostJob.new()
	job.chunk = Vector2i(1, 2)
	job.gen = 1
	job.size = 64
	job.width = 64
	job.height = 64
	job.gpu_dilated = true
	job.compress = true
	job.native_compressor = comp
	job.upload_on_worker = false
	job.bytes = _rgba_bytes(64, 64, sheet_fill)
	Baker.post_process(job)
	check(not job.empty and job.image != null and job.image.get_format() == Image.FORMAT_DXT5 and job.image.has_mipmaps() and (job.image.duplicate() as Image).decompress() == OK,
		"DecorSheetBaker.post_process with native_compressor produces mipmapped DXT5")

	# Disk cache (user://tex-cache) round-trip with DXT1 from TextureCompressNative.
	var was_cache := TerrainTextures.disk_cache
	TerrainTextures.disk_cache = true
	var g := TerrainTextures.TileGfx.new()
	g.name = "__test_native_bc1__"
	var cache_key := "test|native_bc1|1"
	TerrainTextures._write_tile_cache(g, cache_key, forced_layer)
	var cached_img := TerrainTextures._read_tile_cache(g, cache_key, 1)
	var cache_file := TerrainTextures._cache_path(g.name, cache_key.sha256_text())
	check(cached_img != null and cached_img.get_format() == Image.FORMAT_DXT1 and cached_img.has_mipmaps(),
		"user://tex-cache round-trips native DXT1 image with mipmaps")
	if FileAccess.file_exists(cache_file):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(cache_file))
	TerrainTextures.disk_cache = was_cache

	# Toggle to off.
	Switches.set_test_args(PackedStringArray(["--native-bc-compress=off", "--decor-sheet-compress=on"]))
	TerrainTextures.refresh_compress_mode()
	Decoratives.refresh_compress_mode()
	check(not TerrainTextures._use_native_bc(), "toggle to off disables TerrainTextures._use_native_bc()")
	check(not Decoratives._use_native_bc3(), "toggle to off disables Decoratives._use_native_bc3()")
	if not OS.has_feature("editor"):
		var off_layer := TerrainTextures._finish_layer(layer.duplicate() as Image)
		check(off_layer != null and off_layer.get_format() == Image.FORMAT_RGBA8, "exported off falls back to RGBA8")

	# Restore original CLI args.
	Switches.set_test_args(saved_args)
	TerrainTextures.refresh_compress_mode()
	Decoratives.refresh_compress_mode()
	ignore_unused_warning(comp)


func ignore_unused_warning(_v: Variant) -> void:
	pass
