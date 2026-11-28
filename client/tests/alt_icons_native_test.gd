extends Node
## AltIconsNative (client/native/belt_sim/src/alt_icons_native.cpp) against alt_overlay.gd's GDScript card
## path (_gpu_fill, _gpu_sort_chunks, _gpu_join): random chunks (0 to 400 icons, equal depths, hover-only
## machines, marks, empty and missing caches, chunks erased and set again), 20 view directions, the joined
## buffer compared byte for byte, plus each path's time for a turned view. Skips (exit 0) when the extension
## isn't loaded.
##
##   godot --headless --audio-driver Dummy --path client --log-file <abs> res://tests/alt_icons_native_test.tscn

const AltOverlay := preload("res://scripts/ui/factorio/alt_overlay.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")

var fails := 0
var rng := RandomNumberGenerator.new()
var texs: Array[Texture2D] = []


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	if not NativeLibrary.ensure() or not ClassDB.class_exists(&"AltIconsNative"):
		print("alt_icons_native_test: AltIconsNative not loaded, skipped")
		get_tree().quit(0)
		return
	rng.seed = 4711
	for i in 24:
		var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		img.fill(Color(rng.randf(), rng.randf(), rng.randf(), 1.0))
		var t := ImageTexture.create_from_image(img)
		t.set_meta(AltOverlay.CPU_IMAGE_META, img)  # no renderer read
		texs.append(t)
	var ga = AltOverlay.new()  # GDScript path
	var na = AltOverlay.new()  # native path
	na._gpu_nat = ClassDB.instantiate(&"AltIconsNative")
	na._gpu_nat_on = true
	var chunks := {}  # Vector2i -> Array of 4 caches
	for _i in 60:
		chunks[Vector2i(rng.randi_range(-8, 8), rng.randi_range(-8, 8))] = _caches()
	var same := 0
	var gd_us := 0
	var nat_us := 0
	var instances := 0
	var sets_changed := 0
	for step in 20:
		var fwd := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, -0.2), rng.randf_range(-1, 1)).normalized()
		if step == 3:
			fwd = Vector3(0, -1, 0)  # straight down: every chunk at one depth, ties by position
		elif step == 4:
			fwd = Vector3(0, -0.6, -0.8).normalized()
		# Chunks erased, new, changed and set again with the same icons.
		if step > 0:
			for _k in 6:
				var keys: Array = chunks.keys()
				var c: Vector2i = keys[rng.randi_range(0, keys.size() - 1)]
				match rng.randi_range(0, 3):
					0:
						chunks.erase(c)
						ga._gpu_chunks.erase(c)
						ga._gpu_order_dirty = true
						na._gpu_nat.call("erase_chunk", c)
					1, 2:
						chunks[Vector2i(rng.randi_range(-10, 10), rng.randi_range(-10, 10))] = _caches()
					3:
						pass  # set again unchanged below
		ga._gpu_fwd = fwd
		na._gpu_fwd = fwd
		var t0 := Time.get_ticks_usec()
		for c: Vector2i in chunks:
			var gc = ga._gpu_chunks.get(c)
			if gc == null:
				gc = AltOverlay.GpuChunk.new()
				ga._gpu_chunks[c] = gc
			gc.data = ga._gpu_fill(chunks[c])
		ga._gpu_sort_chunks()
		var a: PackedFloat32Array = ga._gpu_join()
		gd_us += Time.get_ticks_usec() - t0
		for c: Vector2i in chunks:
			if na._gpu_nat_set(c, chunks[c]):
				sets_changed += 1
		t0 = Time.get_ticks_usec()
		var b: PackedFloat32Array = na._gpu_join()
		nat_us += Time.get_ticks_usec() - t0
		instances += a.size() / AltOverlay.GPU_FLOATS
		if a.to_byte_array() == b.to_byte_array():
			same += 1
		else:
			print("step %d: %d vs %d floats, first difference at %d" % [step, a.size(), b.size(), _first_diff(a, b)])
		# One chunk's block alone, too.
		var one: Vector2i = chunks.keys()[0]
		if ga._gpu_chunks[one].data.to_byte_array() != (na._gpu_chunk_data(one) as PackedFloat32Array).to_byte_array():
			print("step %d: chunk %s's block differs" % [step, one])
			same -= 1
	_check(same == 20, "native buffer byte for byte equal to GDScript's (%d of 20 directions)" % same)
	_check(int(na._gpu_nat.call("chunk_count")) == chunks.size(), "native holds every chunk (%d vs %d)" % [int(na._gpu_nat.call("chunk_count")), chunks.size()])
	# Setting a chunk with the same icons changes nothing; a different one does.
	var c0: Vector2i = chunks.keys()[0]
	_check(not na._gpu_nat_set(c0, chunks[c0]), "set_chunk with the same icons reports no change")
	chunks[c0] = _caches()
	_check(na._gpu_nat_set(c0, chunks[c0]) or (chunks[c0] as Array).all(func(x): return x == null or x.ent_anchor.is_empty()),
		"set_chunk with other icons reports a change")
	print("alt_icons_native_test: %d instances over 20 directions (%d chunks), turned view GDScript %.2f ms, native %.2f ms a direction; %d sets changed" % [instances, chunks.size(), gd_us / 20000.0, nat_us / 20000.0, sets_changed])
	ga.free()
	na.free()
	_test_lift()
	get_tree().quit(1 if fails > 0 else 0)


## --alt-relift: AltIconsNative.lift against alt_overlay.gd's GDScript relift (GroundHeight.at), to the bit, on
## fields of each format, points inside, outside, on texel edges and centres, and a field faded from at mix 0.3.
func _test_lift() -> void:
	if not ClassDB.class_has_method(&"AltIconsNative", &"lift"):
		print("alt_icons_native_test: this library's AltIconsNative has no lift (an older DLL), relift parity skipped")
		return
	var nat: Object = ClassDB.instantiate(&"AltIconsNative")
	var cases := 0
	var equal := 0
	var moved := 0
	for f in 9:
		var fmt: int = [Image.FORMAT_RF, Image.FORMAT_RGF, Image.FORMAT_RGBF][f % 3]
		var img := Image.create(rng.randi_range(2, 19), rng.randi_range(2, 19), false, fmt)
		for y in img.get_height():
			for x in img.get_width():
				img.set_pixel(x, y, Color(rng.randf_range(-3, 6), rng.randf_range(-3, 6), rng.randf(), 1))
		var origin := Vector2(rng.randf_range(-40, 40), rng.randf_range(-40, 40))
		var step := rng.randf_range(0.3, 4.0)
		if f >= 6:
			img.set_meta(&"fade_in", 2.0)  # the field before faded from
		GroundHeight.set_field(img, origin, step)
		if f >= 6:
			GroundHeight._mix = 0.3
		var anchors := PackedVector3Array()
		var flat := PackedFloat64Array()
		var size := Vector2(img.get_width(), img.get_height()) * GroundHeight._step
		for _i in 400:
			var p := Vector2(rng.randf_range(origin.x - 6, origin.x + size.x + 6), rng.randf_range(origin.y - 6, origin.y + size.y + 6))
			match rng.randi_range(0, 3):
				0:  # a texel's edge
					p = origin + Vector2(rng.randi_range(-1, img.get_width() + 1), rng.randi_range(-1, img.get_height() + 1)) * GroundHeight._step
				1:  # a texel's centre
					p = origin + (Vector2(rng.randi_range(0, img.get_width() - 1), rng.randi_range(0, img.get_height() - 1)) + Vector2(0.5, 0.5)) * GroundHeight._step
			anchors.append(Vector3(p.x, rng.randf_range(-5, 5), p.y))
			flat.append(rng.randf_range(0.0, 3.0) if rng.randf() < 0.8 else [0.0, 0.25, 1.0 / 3.0][rng.randi_range(0, 2)])
		nat.call("set_field", GroundHeight.sample_state())
		var a: PackedVector3Array = AltOverlay.relift_anchors(anchors, flat)
		var b: PackedVector3Array = nat.call("lift", anchors, flat, GroundHeight.mix_now())
		cases += 1
		if a.to_byte_array() == b.to_byte_array():
			equal += 1
		else:
			for i in a.size():
				if a[i] != b[i]:
					print("lift field %d point %d: GDScript %s, native %s" % [f, i, a[i], b[i]])
					break
		for i in a.size():
			if a[i].y != anchors[i].y:
				moved += 1
		if f >= 6:
			GroundHeight._end_fade()
	GroundHeight.clear()
	nat.call("set_field", GroundHeight.sample_state())
	var flat0 := PackedFloat64Array([0.5, 1.0 / 3.0])
	var off_a := AltOverlay.relift_anchors(PackedVector3Array([Vector3(1, 9, 2), Vector3(3, 9, 4)]), flat0)
	var off_b: PackedVector3Array = nat.call("lift", PackedVector3Array([Vector3(1, 9, 2), Vector3(3, 9, 4)]), flat0, 1.0)
	_check(equal == cases and moved > 0 and off_a.to_byte_array() == off_b.to_byte_array(),
		"native lift equal to the GDScript relift to the bit (%d of %d fields, RF/RGF/RGBF, 3 faded from at mix 0.3; %d anchors moved; flat ground too)" % [equal, cases, moved])


func _check(ok: bool, what: String) -> void:
	if ok:
		print("PASS ", what)
	else:
		fails += 1
		print("FAIL ", what)


func _first_diff(a: PackedFloat32Array, b: PackedFloat32Array) -> int:
	for i in mini(a.size(), b.size()):
		if a[i] != b[i]:
			return i
	return mini(a.size(), b.size())


## A chunk's four caches (recipe, contents, machines, fluids): some missing or empty, up to 400 cells.
func _caches() -> Array:
	var out: Array = []
	var budget := rng.randi_range(0, 400) if rng.randf() > 0.1 else 0
	var base := Vector2(rng.randi_range(0, 31), rng.randi_range(0, 31))
	for k in 4:
		var r := rng.randf()
		if r < 0.15:
			out.append(null)
			continue
		var cc := AltOverlay.ChunkCache.new()
		var share := budget / 4
		var cells := 0
		while cells < share:
			var count := rng.randi_range(1, 6)
			# Equal depths: anchors on a coarse grid, often repeated.
			var at := Vector3(base.x + rng.randi_range(0, 3) * 2.0, rng.randf_range(0.0, 0.5) if rng.randf() < 0.5 else 0.25, base.y + rng.randi_range(0, 3) * 2.0)
			if rng.randf() < 0.3:
				at = Vector3(base.x + rng.randf_range(-16, 16), rng.randf_range(0, 3), base.y + rng.randf_range(-16, 16))
			cc.ent_anchor.append(at)
			cc.ent_flat_y.append(0.0)
			cc.ent_ref.append(rng.randf_range(0.5, 2.0))
			cc.ent_bound.append(1.0)
			cc.ent_cell_start.append(cc.cell_offset.size())
			cc.ent_cell_count.append(count)
			cc.ent_hover_rec.append(RefCounted.new() if rng.randf() < 0.08 else null)
			for _ci in count:
				cc.cell_offset.append(Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)))
				cc.cell_side.append(rng.randf_range(0.2, 1.2))
				cc.cell_tex.append(texs[rng.randi_range(0, texs.size() - 1)])
				cc.cell_mark.append(texs[rng.randi_range(0, 3)] if rng.randf() < 0.2 else null)
			cells += count
		out.append(cc)
	return out
