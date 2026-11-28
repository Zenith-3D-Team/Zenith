extends SceneTree
## render_reads.gd (perf-w3-render, R1): a mesh's arrays, triangle counts and a texture's picture come from
## the CPU copies the loaders keep, not the renderer (which waits for the render thread when it runs on its
## own); without a copy, or with `--render-reads=old`, from the renderer as before. Also the LOD cross-fade's
## kept paint (chunk_view.gd LodState) and the stage reader's answer headless (render_stats.gd).
##   godot --headless --audio-driver Dummy --path client -s res://tests/render_reads_test.gd

const RenderReads := preload("res://scripts/world/render_reads.gd")
const RenderStats := preload("res://scripts/debug/render_stats.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + what)
	if not ok:
		fails += 1


func _surface(indexed: bool) -> Array:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0),
		Vector3(1, 1, 0), Vector3(0, 2, 0), Vector3(1, 3, 0), Vector3(2, 0, 0), Vector3(2, 1, 0), Vector3(2, 2, 0)])
	if indexed:
		arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 1, 3, 2])
	return arrays


func _initialize() -> void:
	var kept_mesh := ArrayMesh.new()
	var a0 := _surface(true)
	kept_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a0)
	kept_mesh.set_meta(RenderReads.ARRAYS_META, [a0])
	var bare := ArrayMesh.new()
	bare.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _surface(false))

	var before := int(RenderReads.fallbacks["arrays"])
	check(is_same(RenderReads.arrays(kept_mesh, 0), a0), "arrays: the kept CPU copy itself, not the renderer's")
	check(int(RenderReads.fallbacks["arrays"]) == before, "arrays: no fallback with a CPU copy")
	var got := RenderReads.arrays(bare, 0)
	check((got[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() == 9 and int(RenderReads.fallbacks["arrays"]) == before + 1,
		"arrays: without a copy, the renderer's (counted)")
	check(RenderReads.vertices(kept_mesh, 0).size() == 9, "vertices from the copy")

	var n := int(RenderReads.fallbacks["arrays"])
	check(RenderReads.triangles(kept_mesh, 0) == 2, "triangles: an indexed ArrayMesh, from its own counts")
	check(RenderReads.triangles(bare, 0) == 3, "triangles: an unindexed ArrayMesh, from its vertex count")
	check(int(RenderReads.fallbacks["arrays"]) == n, "triangles: no array read for an ArrayMesh")
	var box := BoxMesh.new()
	var box_arrays := box.surface_get_arrays(0)
	check(RenderReads.triangles(box, 0) == (box_arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3,
		"triangles: a PrimitiveMesh by its arrays, as before")

	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color.RED)
	var tex := ImageTexture.create_from_image(img)
	tex.set_meta(RenderReads.IMAGE_META, img)
	var bi := int(RenderReads.fallbacks["image"])
	check(is_same(RenderReads.image(tex), img) and int(RenderReads.fallbacks["image"]) == bi, "image: the kept picture")
	var tex2 := ImageTexture.create_from_image(img)
	RenderReads.image(tex2)
	check(int(RenderReads.fallbacks["image"]) == bi + 1, "image: without a copy, the renderer's (counted)")
	check(RenderReads.image(null) == null, "image: none for no texture")

	RenderReads.old = true  # --render-reads=old
	check(not is_same(RenderReads.arrays(kept_mesh, 0), a0), "--render-reads=old: arrays read from the renderer")
	check(RenderReads.triangles(kept_mesh, 0) == 2, "--render-reads=old: the same triangle count")
	RenderReads.old = false

	var st := ChunkView.LodState.new()
	check(st.paint == Color.WHITE and st.paint_from == 0.0, "LodState keeps the paint for the cross-fade (none at first)")
	check(ChunkView.lod_no_readback, "the cross-fade copies the kept paint by default")

	check(RenderStats.steps().is_empty(), "render stages: none headless")
	print("render_reads_test: %s" % ("PASS" if fails == 0 else "%d FAIL" % fails))
	quit(1 if fails > 0 else 0)
