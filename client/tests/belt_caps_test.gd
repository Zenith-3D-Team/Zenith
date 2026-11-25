extends SceneTree
## A belt model's side plates' open ends capped on load (belt_caps.gd, L3): a plate open at both ends gets
## two caps facing out, with its vertices' UVs and colours; a large opening, a closed box and a lone card
## get none. The built-in packs' belts have nothing capped; Vasillo's pieces, when his files are on this
## PC and named (-- --models-dir=<dir>, or the ZENITH_TEST_MODELS environment variable), are counted.
##   godot --headless --path client -s res://tests/belt_caps_test.gd [-- --models-dir=<folder>]

const BeltCaps := preload("res://scripts/world/belt_caps.gd")
const BeltLattice := preload("res://scripts/world/belt_lattice.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const BeltReturn := preload("res://scripts/world/belt_return.gd")
const TestEnv := preload("res://tests/test_env.gd")
const PACKS := "res://assets/models/packs/"

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _init() -> void:
	TestEnv.isolate("belt-caps-test")
	_fixtures()
	_model_caps()
	_built_in()
	_vasillo()
	print("BELT CAPS FAILS: %d" % fails)
	TestEnv.clean()
	quit(1 if fails > 0 else 0)


## Arrays of quads, each wound as Godot's front faces (clockwise seen from the front of `normal`).
class Builder:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var idx := PackedInt32Array()

	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, normal: Vector3, uv := Vector2(0.3, 0.6)) -> void:
		var base := verts.size()
		for p in [a, b, c, d]:
			verts.append(p)
			normals.append(normal)
			uvs.append(uv)
			colors.append(Color(0.2, 0.4, 0.6, 0.8))
		var tris := [0, 1, 2, 0, 2, 3]
		if (b - a).cross(c - a).dot(normal) > 0.0:
			tris = [0, 2, 1, 0, 3, 2]
		for k in tris:
			idx.append(base + k)

	## A box from `lo` to `hi`, its faces facing out; `open_z` leaves its two ends (across z) open.
	func box(lo: Vector3, hi: Vector3, open_z: bool) -> void:
		var x0 := lo.x
		var x1 := hi.x
		var y0 := lo.y
		var y1 := hi.y
		var z0 := lo.z
		var z1 := hi.z
		quad(Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3.UP)
		quad(Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1), Vector3.DOWN)
		quad(Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x0, y1, z1), Vector3(x0, y0, z1), Vector3.LEFT)
		quad(Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x1, y0, z1), Vector3.RIGHT)
		if not open_z:
			quad(Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x0, y1, z0), Vector3.FORWARD)
			quad(Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3.BACK)

	func arrays() -> Array:
		var out := []
		out.resize(Mesh.ARRAY_MAX)
		out[Mesh.ARRAY_VERTEX] = verts.duplicate()
		out[Mesh.ARRAY_NORMAL] = normals.duplicate()
		out[Mesh.ARRAY_TEX_UV] = uvs.duplicate()
		out[Mesh.ARRAY_COLOR] = colors.duplicate()
		out[Mesh.ARRAY_INDEX] = idx.duplicate()
		return out


func _fixtures() -> void:
	# A side plate as Vasillo's: 0.035 wide, 0.131 tall, a tile long, open at both ends.
	var plate := Builder.new()
	plate.box(Vector3(0.45, 0.05, -0.6), Vector3(0.485, 0.181, 0.4), true)
	var arrays := plate.arrays()
	var before := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var tris_before := (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
	check(BeltCaps.cap(arrays) == 2, "an open plate gets a cap at each end")
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	check(verts.size() == before + 8 and idx.size() == tris_before + 12, "two quads' worth added (%d vertices, %d indices)" % [verts.size() - before, idx.size() - tris_before])
	check((arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array).size() == verts.size()
		and (arrays[Mesh.ARRAY_COLOR] as PackedColorArray).size() == verts.size(), "every per-vertex array kept in step")
	var out_front := 0
	var out_back := 0
	for t in range(tris_before, idx.size(), 3):
		var a := verts[idx[t]]
		var n := normals[idx[t]]
		var geometric := (verts[idx[t + 1]] - a).cross(verts[idx[t + 2]] - a)
		check(geometric.dot(n) < 0.0, "a cap's triangle winds as Godot's front faces round its normal")
		if a.z < -0.59 and n.dot(Vector3.FORWARD) > 0.99:
			out_front += 1
		elif a.z > 0.39 and n.dot(Vector3.BACK) > 0.99:
			out_back += 1
	check(out_front == 2 and out_back == 2, "the caps face out of the plate's ends (%d, %d)" % [out_front, out_back])
	var uv: Vector2 = (arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array)[verts.size() - 1]
	var color: Color = (arrays[Mesh.ARRAY_COLOR] as PackedColorArray)[verts.size() - 1]
	check(uv.is_equal_approx(Vector2(0.3, 0.6)) and color.is_equal_approx(Color(0.2, 0.4, 0.6, 0.8)), "a cap wears the plate's UVs and colour")
	check(BeltCaps.cap(arrays) == 0, "capped once, nothing left to cap")

	# Unindexed arrays (a surface without an index) are capped too.
	var flat := plate.arrays()
	var unrolled := PackedVector3Array()
	var unrolled_n := PackedVector3Array()
	for k in (flat[Mesh.ARRAY_INDEX] as PackedInt32Array):
		unrolled.append((flat[Mesh.ARRAY_VERTEX] as PackedVector3Array)[k])
		unrolled_n.append((flat[Mesh.ARRAY_NORMAL] as PackedVector3Array)[k])
	var loose := []
	loose.resize(Mesh.ARRAY_MAX)
	loose[Mesh.ARRAY_VERTEX] = unrolled
	loose[Mesh.ARRAY_NORMAL] = unrolled_n
	check(BeltCaps.cap(loose) == 2, "an unindexed plate is capped too")

	# A large opening (the frame's own mouth, a belt surface's): left open.
	var wide := Builder.new()
	wide.box(Vector3(-0.4, 0.0, -0.5), Vector3(0.4, 0.3, 0.5), true)
	var wide_arrays := wide.arrays()
	check(BeltCaps.cap(wide_arrays) == 0, "a 0.8 x 0.3 opening isn't capped")
	check((wide_arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() == wide.idx.size(), "...and its arrays are unchanged")

	# A closed box: unchanged.
	var shut := Builder.new()
	shut.box(Vector3(0.45, 0.05, -0.6), Vector3(0.485, 0.181, 0.4), false)
	var shut_arrays := shut.arrays()
	check(BeltCaps.cap(shut_arrays) == 0 and (shut_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() == shut.verts.size(), "a closed box is unchanged")

	# A lone small card: its edge is a small flat loop, but its face lies in that plane (no hole).
	var card := Builder.new()
	card.quad(Vector3(0, 0.1, 0), Vector3(0.1, 0.1, 0), Vector3(0.1, 0.1, 0.1), Vector3(0, 0.1, 0.1), Vector3.UP)
	check(BeltCaps.cap(card.arrays()) == 0, "a lone card isn't capped from behind")

	# The switch, and which models are looked at.
	check(BeltCaps.wanted("transport-belt") and BeltCaps.wanted("fast-transport-belt-curve-left") and BeltCaps.wanted("express-transport-belt-start")
		and BeltCaps.wanted("splitter") and BeltCaps.wanted("turbo-underground-belt-input") and not BeltCaps.wanted("inserter")
		and not BeltCaps.wanted("splitter-remnants"), "belts, curves, starts, splitters and undergrounds are looked at; others not")
	var was := BeltCaps.enabled
	BeltCaps.enabled = false
	check(not BeltCaps.wanted("transport-belt"), "--belt-caps=off: nothing is looked at")
	BeltCaps.enabled = was


## A .glb read as the model library reads it, with the caps looked for: [caps, triangles].
func _load(path: String, modeller: bool) -> Array:
	var load := ModelLibrary.Load.new()
	load.path = path
	load.combine = true
	load.modeller = modeller
	var file := path.get_file().get_basename()
	load.belt_shape = BeltReturn.shape_for(file)
	load.belt_caps = BeltCaps.wanted(file)
	load.run()
	return [load.caps, load.ok]


func _belt_files(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".glb") and BeltCaps.wanted(f.get_basename()):
			out.append(dir.path_join(f))
	return out


func _model_caps() -> void:
	var was_cap := ItemCards.model_cap
	var was_cap_near := BeltLattice.model_cap_near
	var lat := BeltLattice.new()
	lat.model_cap_near = true
	check(BeltLattice._look_key(-2) == -2 and BeltLattice._look_key(5 + 2 * ItemCards.BAND_STEP) == 5,
		"_look_key strips distance band while preserving icon keys")
	var k := ItemCards.band_key(5 + 2 * ItemCards.VARIANT_STEP, 2)
	check(ItemCards.band_of(k) == 2 and ItemCards.variant_of(k) == 2 and ItemCards.item_of(k) == 5,
		"band_key encodes band, variant, and item id losslessly")
	check(BeltLattice.band_for_dist(7, 10.0, 28.0, 56.0, Vector2.ZERO, -1) == 0
		and BeltLattice.band_for_dist(7, 40.0, 28.0, 56.0, Vector2.ZERO, -1) == 1
		and BeltLattice.band_for_dist(7, 70.0, 28.0, 56.0, Vector2.ZERO, -1) == 2,
		"band_for_dist separates near/mid/far tiers accurately")
	check(BeltLattice.band_for_dist(7, 29.0, 28.0, 56.0, Vector2.ZERO, 0) == 0
		and BeltLattice.band_for_dist(7, 30.0, 28.0, 56.0, Vector2.ZERO, 0) == 1,
		"band_for_dist applies BAND_HYST=1.5 hysteresis at band 0->1 boundary")
	BeltLattice.model_cap_near = was_cap_near
	ItemCards.model_cap = was_cap


func _built_in() -> void:
	var looked := 0
	for pack in ["placeholders", "wube3dp", "fue5"]:
		for path in _belt_files(ProjectSettings.globalize_path(PACKS + pack)):
			var got := _load(path, false)
			looked += 1
			check(bool(got[1]), "read %s" % path)
			check(int(got[0]) == 0, "built-in %s/%s: nothing capped (%d)" % [pack, path.get_file(), int(got[0])])
	check(looked >= 5, "the built-in packs' belts were looked at (%d)" % looked)
	print("built-in belt models looked at: %d, none capped" % looked)


func _vasillo() -> void:
	var dir := TestEnv.models_dir(["--vasillo="])
	if dir == "":
		print("SKIP: Vasillo's models: no folder given (-- --models-dir=<folder> or ZENITH_TEST_MODELS)")
		return
	var files := _belt_files(dir)
	if files.is_empty():
		print("Vasillo's models not on this PC (%s): skipped" % dir)
		return
	var total := 0
	for path in files:
		var got := _load(path, true)
		total += int(got[0])
		print("  %s: %d cap(s)" % [path.get_file().get_basename(), int(got[0])])
		var name := path.get_file().get_basename()
		if name.ends_with("-end"):
			check(int(got[0]) == 0, "%s: a line's end piece has no frame to cap" % name)
		elif not name.contains("underground"):
			check(int(got[0]) > 0, "%s: its plates' ends capped" % name)
	print("Vasillo's belt pieces: %d caps in %d files" % [total, files.size()])
