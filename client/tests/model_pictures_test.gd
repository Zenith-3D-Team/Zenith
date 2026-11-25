extends SceneTree
## The model-loading diet changes nothing a model looks like: every .glb read the old way (Godot's reader
## decoding its pictures, the file read three times: --model-pictures=godot, --model-read-once=off) and
## the new (pictures left out of Godot's reader and wired from the JSON, the file read once) gives the
## same materials, property by property, the same textures (the very same shared ones), the same meshes
## and nodes; a picture read back from the disk cache (user://tex-cache) is the one made, pixel for
## pixel, with the same metas; prune_cache keeps the cache under its size. (model_textures.gd,
## model_library.gd Load.read_model)
##   godot --headless --path client -s res://tests/model_pictures_test.gd [-- --dir=<folder of .glb> ...] [--limit=<n>]
## Without --dir: Zenith's built-in packs (FUE5, Wube3DP, Placeholders), the textured ones all, the rest
## every fifth.

const ModelTextures := preload("res://scripts/world/model_textures.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const TestEnv := preload("res://tests/test_env.gd")
const PACKS := "res://assets/models/packs"

var fails := 0
var compared := 0
var wired := 0
var textures_seen := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _initialize() -> void:
	TestEnv.isolate("model-pictures-test")
	var dirs: Array = []
	var limit := 0
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--dir="):
			dirs.append(a.trim_prefix("--dir="))
		elif a.begins_with("--limit="):
			limit = a.trim_prefix("--limit=").to_int()
	var files: Array = []
	if dirs.is_empty():
		for pack in ["fue5", "wube3dp", "placeholders"]:
			var i := 0
			for f in DirAccess.get_files_at(PACKS.path_join(pack)):
				if not f.ends_with(".glb"):
					continue
				var path := ProjectSettings.globalize_path(PACKS.path_join(pack).path_join(f))
				var read := ModelTextures.read_glb(path)
				var textured: bool = not read.is_empty() and not (read["doc"] as Dictionary).get("images", []).is_empty()
				if textured or i % 5 == 0:
					files.append(path)
				i += 1
	else:
		for d: String in dirs:
			for f in DirAccess.get_files_at(d):
				if f.ends_with(".glb"):
					files.append(d.path_join(f))
	if limit > 0 and files.size() > limit:
		files.resize(limit)
	var t_old := 0
	var t_new := 0
	for path: String in files:
		var times := _compare(path)
		t_old += times[0]
		t_new += times[1]
	print("compared %d models (%d wired, %d textures): old %.2f s, new %.2f s" % [compared, wired, textures_seen,
		t_old / 1e6, t_new / 1e6])
	check(compared > 0 and wired > 0, "some models were compared and some wired (%d, %d)" % [compared, wired])
	_disk_cache()
	_fallbacks()
	print("MODEL PICTURES FAILS: %d" % fails)
	TestEnv.clean()
	quit(1 if fails > 0 else 0)


## [old microseconds, new microseconds]
func _compare(path: String) -> Array:
	ModelTextures.disk_cache = false
	var new_first := "--new-first" in OS.get_cmdline_user_args()  # times the new reading unhelped by shared pictures
	var new := {}
	var tn := 0
	if new_first:
		tn = _timed_read(path, true, new)
	var old := {}
	var t_old := _timed_read(path, false, old)
	if not new_first:
		tn = _timed_read(path, true, new)
	var a: GLTFState = old["state"]
	var b: GLTFState = new["state"]
	check(a != null and b != null, "%s read both ways" % path.get_file())
	if a == null or b == null:
		return [t_old, tn]
	compared += 1
	if bool(new["wired"]):
		wired += 1
	var name := path.get_file()
	var ma := a.get_materials()
	var mb := b.get_materials()
	check(ma.size() == mb.size(), "%s: as many materials (%d, %d)" % [name, ma.size(), mb.size()])
	for i in mini(ma.size(), mb.size()):
		_same_material(ma[i], mb[i], "%s material %d" % [name, i])
	var meshes_a := a.get_meshes()
	var meshes_b := b.get_meshes()
	check(meshes_a.size() == meshes_b.size(), "%s: as many meshes" % name)
	for i in mini(meshes_a.size(), meshes_b.size()):
		var ia: ImporterMesh = (meshes_a[i] as GLTFMesh).mesh
		var ib: ImporterMesh = (meshes_b[i] as GLTFMesh).mesh
		check(ia.get_surface_count() == ib.get_surface_count(), "%s mesh %d: as many surfaces" % [name, i])
		for s in mini(ia.get_surface_count(), ib.get_surface_count()):
			check(var_to_bytes(ia.get_surface_arrays(s)) == var_to_bytes(ib.get_surface_arrays(s)),
				"%s mesh %d surface %d: the same arrays" % [name, i, s])
			check(ia.get_surface_material(s) != null or ib.get_surface_material(s) == null, "%s mesh %d surface %d: material kept" % [name, i, s])
	var na := a.get_nodes()
	var nb := b.get_nodes()
	check(na.size() == nb.size(), "%s: as many nodes" % name)
	for i in mini(na.size(), nb.size()):
		var x: GLTFNode = na[i]
		var y: GLTFNode = nb[i]
		check(x.original_name == y.original_name and x.mesh == y.mesh and x.skin == y.skin and x.parent == y.parent
			and x.get_xform() == y.get_xform(), "%s node %d the same" % [name, i])
	check(a.get_skins().size() == b.get_skins().size() and a.get_animations().size() == b.get_animations().size(),
		"%s: the same skins and animations" % name)
	return [t_old, tn]


func _timed_read(path: String, diet: bool, out: Dictionary) -> int:
	ModelTextures.own_pictures = diet
	ModelLibrary.Load.read_once = diet
	var t := Time.get_ticks_usec()
	out.merge(ModelLibrary.Load.read_model(path, true))
	return Time.get_ticks_usec() - t


func _same_material(x: Material, y: Material, what: String) -> void:
	check(x.get_class() == y.get_class(), "%s: the same class (%s, %s)" % [what, x.get_class(), y.get_class()])
	for prop: Dictionary in x.get_property_list():
		if not (int(prop["usage"]) & PROPERTY_USAGE_STORAGE):
			continue
		var key := str(prop["name"])
		var vx: Variant = x.get(key)
		var vy: Variant = y.get(key)
		if vx is Texture2D or vy is Texture2D:
			if vx != null:
				textures_seen += 1
			# Shared pictures: the new reading finds the very texture the old one made. An emission picture on a
			# material that doesn't glow is never drawn (model_library.gd reads it only with emission on): the
			# old reading left Godot's own copy there, the new puts the shared one.
			if key == "emission_texture" and not bool(x.get("emission_enabled")) and not bool(y.get("emission_enabled")):
				check((vx == null) == (vy == null), "%s: %s both set or both not" % [what, key])
				continue
			check(vx == vy, "%s: %s the same texture (%s, %s)" % [what, key, vx, vy])
		elif typeof(vx) == TYPE_OBJECT or typeof(vy) == TYPE_OBJECT:
			check((vx == null) == (vy == null), "%s: %s both set or both not" % [what, key])
		else:
			check(vx == vy, "%s: %s the same (%s, %s)" % [what, key, vx, vy])
	for meta in x.get_meta_list():
		check(y.has_meta(meta) and y.get_meta(meta) == x.get_meta(meta), "%s: meta %s the same" % [what, meta])


## A picture made with the disk cache on is written there; made again with nothing shared in memory, it
## is read back: the same pixels, mipmaps and metas.
func _disk_cache() -> void:
	ModelTextures.share = true
	ModelTextures.disk_cache = true
	ModelTextures._shared.clear()
	var img := Image.create_empty(256, 128, false, Image.FORMAT_RGBA8)
	for y in 128:
		for x in 256:
			img.set_pixel(x, y, Color(x / 255.0, y / 127.0, 0.5, 1.0 if x > 3 else 0.5))
	var pic := [img.save_png_to_buffer(), "image/png"]
	var writes := ModelTextures.cache_writes
	var made := ModelTextures._made(pic, true)
	check(made != null and ModelTextures.cache_writes == writes + 1, "a picture made is written to the disk cache")
	ModelTextures._shared.clear()
	var hits := ModelTextures.cache_hits
	var again := ModelTextures._made(pic, true)
	check(again != null and again != made and ModelTextures.cache_hits == hits + 1, "and read back from it with nothing in memory")
	if made != null and again != null:
		var ia := made.get_image()
		var ib := again.get_image()
		check(ia.has_mipmaps() and ib.has_mipmaps() and ia.get_format() == ib.get_format() and ia.get_data() == ib.get_data(),
			"the same pixels and mipmaps")
		for meta in [ModelTextures.OPAQUE_META, ModelTextures.OPAQUE_SHARE_META, ModelTextures.BLACK_META, ModelTextures.NEAREST_META]:
			check(again.get_meta(meta, null) == made.get_meta(meta, null), "the same %s (%s, %s)" % [meta, made.get_meta(meta, null), again.get_meta(meta, null)])
		var sa: Image = made.get_meta(ModelTextures.SMALL_META)
		var sb: Image = again.get_meta(ModelTextures.SMALL_META)
		check(sa.get_data() == sb.get_data() and sb.get_width() == ModelTextures.SMALL, "the same small copy")
	# A damaged file is not used: the picture decoded again.
	var path := ProjectSettings.globalize_path(ModelTextures._cache_path(_digest(pic[0]), (pic[0] as PackedByteArray).size(), true))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("not a picture")
	f.close()
	ModelTextures._shared.clear()
	hits = ModelTextures.cache_hits
	var third := ModelTextures._made(pic, true)
	check(third != null and ModelTextures.cache_hits == hits and third.get_image().get_data() == made.get_image().get_data(),
		"a damaged cache file is decoded again")
	# --tex-cache=off: nothing written.
	ModelTextures.disk_cache = false
	ModelTextures._shared.clear()
	writes = ModelTextures.cache_writes
	var pic2 := [Image.create_empty(8, 8, false, Image.FORMAT_RGB8).save_png_to_buffer(), "image/png"]
	ModelTextures._made(pic2, false)
	check(ModelTextures.cache_writes == writes, "--tex-cache=off: nothing written")
	# prune_cache: the oldest go once past the limit; half-written files of a stopped Zenith go.
	ModelTextures.prune_cache(1)
	var left := Array(DirAccess.get_files_at(ProjectSettings.globalize_path(ModelTextures.CACHE_DIR))).filter(
		func(n: String) -> bool: return n.begins_with(ModelTextures.CACHE_PREFIX))
	check(left.size() <= 1, "prune_cache keeps the cache under its size: %s" % [left])
	ModelTextures._shared.clear()


## Files the new reading leaves to Godot's reader: a .gltf, a picture without a buffer view, an
## extension that makes its own textures.
func _fallbacks() -> void:
	check(ModelTextures.read_glb("res://nothing.gltf").is_empty(), "a .gltf isn't read once (Godot's reader reads it)")
	var doc := {"images": [{"uri": "a.png"}], "textures": [{"source": 0}]}
	check(not ModelTextures.can_wire({"doc": doc, "bin_at": 28, "bytes": PackedByteArray()}), "an outside picture: not wired")
	doc = {"images": [{"bufferView": 0, "mimeType": "image/png"}], "textures": [{"source": 0}], "extensionsUsed": ["KHR_materials_pbrSpecularGlossiness"]}
	check(not ModelTextures.can_wire({"doc": doc, "bin_at": 28, "bytes": PackedByteArray()}), "spec-gloss: not wired")
	doc = {"images": [{"bufferView": 0, "mimeType": "image/png"}], "textures": [{"source": 0}]}
	check(ModelTextures.can_wire({"doc": doc, "bin_at": 28, "bytes": PackedByteArray()}), "an own PNG: wired")
	doc = {"images": [{"bufferView": 0, "mimeType": "image/png"}], "textures": [{"extensions": {"KHR_texture_basisu": {"source": 0}}}]}
	check(not ModelTextures.can_wire({"doc": doc, "bin_at": 28, "bytes": PackedByteArray()}), "a texture without a source: not wired")


static func _digest(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(bytes)
	return ctx.finish().hex_encode()
