extends SceneTree
## BeltItemsNative (ItemCards.put_mv's steady-state fast path) against the GDScript path: the same
## put_mv calls on two ItemCards, one with --native-belt-items=off's behaviour (_fast = null); the
## MultiMesh buffers, visible counts, records' counts and upload counts must match, and the time of each.
##   godot --headless --audio-driver Dummy --path client --log-file <abs>/godot.log -s res://tests/belt_items_native_test.gd

const ItemCards := preload("res://scripts/world/item_cards.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _make(native: bool) -> Node3D:
	var c := ItemCards.new()
	c.mv_mode = true
	c.mv_buf_getter = func(_id: int) -> PackedFloat32Array: return PackedFloat32Array()
	if not native:
		c._fast = null
	root.add_child(c)
	return c


func _buf(cap: int, seed_v: float) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(cap * ItemCards.STRIDE)
	for i in b.size():
		b[i] = seed_v + float(i) * 0.25
	return b


func _initialize() -> void:
	if not NativeLibrary.ensure() or not ClassDB.class_exists(&"BeltItemsNative"):
		print("SKIP: BeltItemsNative not in the loaded library (the GDScript path is the only one)")
		quit(0)
		return
	var a := _make(true)
	var b := _make(false)
	check(a._fast != null and b._fast == null, "native instance on one side only")
	var bounds := AABB(Vector3(-32.0, -4.0, -32.0), Vector3(64.0, 16.0, 64.0))
	var cap := 600
	for c: Node3D in [a, b]:
		c.put_records(21, 0, 10, cap, bounds)
	var frames := 400
	var max_diff := 0.0
	var t_native := 0
	var t_gd := 0
	for f in frames:
		var vis := 1 + (f * 7) % (cap - 1)
		if f == 150:
			vis = 0  # (a hide: the slow path)
		var buf := _buf(cap, float(f))
		var t0 := Time.get_ticks_usec()
		a.put_mv(21, buf, vis, cap, bounds)
		t_native += Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		b.put_mv(21, buf, vis, cap, bounds)
		t_gd += Time.get_ticks_usec() - t0
		var ma: MultiMesh = (a._kinds[21] as MultiMeshInstance3D).multimesh
		var mb: MultiMesh = (b._kinds[21] as MultiMeshInstance3D).multimesh
		if ma.visible_instance_count != mb.visible_instance_count:
			check(false, "frame %d visible count %d vs %d" % [f, ma.visible_instance_count, mb.visible_instance_count])
		if vis > 0 and f % 20 == 0:
			var ba := RenderingServer.multimesh_get_buffer(ma.get_rid())
			var bb := RenderingServer.multimesh_get_buffer(mb.get_rid())
			check(ba.size() == bb.size(), "buffer sizes")
			for i in mini(ba.size(), bb.size()):
				max_diff = maxf(max_diff, absf(ba[i] - bb[i]))
		check(int(a._record_counts.get(21, -1)) == int(b._record_counts.get(21, -1)), "frame %d record counts" % f)
		check(int((a._mv_buffers[21] as Array)[1]) == int((b._mv_buffers[21] as Array)[1]), "frame %d mv entry vis" % f)
		check(a.mv_uploads == b.mv_uploads, "frame %d uploads %d vs %d" % [f, a.mv_uploads, b.mv_uploads])
	# A hidden kind must not upload on the fast path (it defers), then flush as before.
	(a._kinds[21] as MultiMeshInstance3D).visible = false
	(b._kinds[21] as MultiMeshInstance3D).visible = false
	var ua: int = a.mv_uploads
	a.put_mv(21, _buf(cap, 1.0), 5, cap, bounds)
	b.put_mv(21, _buf(cap, 1.0), 5, cap, bounds)
	check(a.mv_uploads == ua and a._mv_deferred.has(21) == b._mv_deferred.has(21), "hidden kind defers on both")
	# New bounds and a new cap go the slow path and agree.
	var bounds2 := AABB(Vector3(-16.0, -4.0, -16.0), Vector3(32.0, 16.0, 32.0))
	(a._kinds[21] as MultiMeshInstance3D).visible = true
	(b._kinds[21] as MultiMeshInstance3D).visible = true
	a._mv_deferred.erase(21)
	b._mv_deferred.erase(21)
	a.put_mv(21, _buf(cap, 2.0), 7, cap, bounds2)
	b.put_mv(21, _buf(cap, 2.0), 7, cap, bounds2)
	check((a._kinds[21] as MultiMeshInstance3D).multimesh.custom_aabb == (b._kinds[21] as MultiMeshInstance3D).multimesh.custom_aabb, "bounds change agrees")
	print("belt_items_native_test: %d frames, max buffer diff %.6f, put_mv native %.3f ms total (%.1f us/call), GDScript %.3f ms total (%.1f us/call)" % [
		frames, max_diff, t_native / 1000.0, float(t_native) / frames, t_gd / 1000.0, float(t_gd) / frames])
	check(max_diff == 0.0, "buffers identical")
	a.queue_free()
	b.queue_free()
	print("belt_items_native_test: %s" % ("PASS" if fails == 0 else "%d FAIL" % fails))
	quit(1 if fails > 0 else 0)
