extends SceneTree
## A far chunk's merge puts trees' and plants' solid parts in a surface of their own (the matte one) and
## buildings' in another: surface count, triangle counts and materials.
##   godot --headless --path client -s res://tests/far_nature_merge_test.gd

const FarChunks := preload("res://scripts/world/far_chunks.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _bake() -> Variant:
	var b := FarChunks.Bake.new()
	b.verts = PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)])
	b.colors = PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE])
	b.indices = PackedInt32Array([0, 1, 2])
	return b


func _init() -> void:
	var xf := [Transform3D(Basis(), Vector3(2, 0, 0)), Transform3D(Basis(), Vector3(5, 0, 0))]
	var m := FarChunks.Merge.new()
	m.material = FarChunks.material()
	m.nature_material = FarChunks.nature_material()
	m.crown_material = FarChunks.crown_material()
	m.groups = [[_bake(), xf, null, false], [_bake(), [xf[0]], null, true]]
	m.run()
	check(m.mesh != null and m.mesh.get_surface_count() == 2, "buildings and trees: two surfaces")
	check(m.triangles == 3, "three triangles in all")
	check(m.mesh.surface_get_material(0) == FarChunks.material(), "surface 0 is the buildings'")
	check(m.mesh.surface_get_material(1) == FarChunks.nature_material(), "surface 1 is the trees'")
	var n := FarChunks.Merge.new()
	n.nature_material = FarChunks.nature_material()
	n.groups = [[_bake(), xf, null, true]]
	n.run()
	check(n.mesh.get_surface_count() == 1 and n.mesh.surface_get_material(0) == FarChunks.nature_material(), "trees only: one matte surface")
	print("far_nature_merge_test: %s" % ("PASS" if fails == 0 else "FAILS %d" % fails))
	quit(1 if fails else 0)
