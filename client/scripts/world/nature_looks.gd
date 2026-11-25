extends RefCounted
## Nauvis's trees and rocks varied as Factorio varies them (res://data/nature_looks.json, measured
## from Factorio's own sprites by tools/models/nature/tree_looks.py):
##
## - Variations. Each tree prototype has 8 to 12 pictures, the first its tallest, the last ones
##   younger and, for six types, two fallen over; Factorio picks one per tree by the prototype's
##   variation_weights. A tree here picks the same way, by a hash of where it stands, and its one
##   model (variation a's shape) is scaled to that picture, or tipped over and laid on the ground
##   for a fallen one. Rocks take one of their pictures' sizes, evenly.
## - Colours. Factorio tints each tree's leaves with one of the prototype's `colors`: the leaf
##   materials get them all (over their mean, which the models' leaves are already), and the shader
##   picks one per tree (factorio_material.gdshaderinc `leaf_tints`).
## - Leaves. The leaf cards wear patches of the tree's own leaves picture, read from the player's
##   Factorio install on a worker thread: an atlas of ATLAS_CELLS^2 patches whose centres the data
##   lists, each cut to a spray whose edge follows the leaves, coloured as its leaves' light and
##   shade over the crown's (`leaf_atlas`). Without an install the shader cuts leaves itself.
##
## Which variation Factorio itself drew isn't sent (the bridge leaves trees' graphics_variation and
## tree_color_index out), so a tree's picture here and in Factorio may differ; the mix is the same.
## --nature-looks=off draws every tree and rock as before (one shape, +-10%); --leaf-atlas=off keeps
## the shader's own leaves.

const ItemIcons := preload("res://scripts/world/item_icons.gd")
const ModFiles := preload("res://scripts/world/mod_files.gd")
const MaterialRows := preload("res://scripts/world/material_rows.gd")
const LeafShader := preload("res://shaders/factorio_material_leaf.gdshader")
const Switches := preload("res://scripts/switches.gd")
const DATA := "res://data/nature_looks.json"
const CACHE_DIR := "user://tex-cache"
const CACHE_VERSION := 1
## The atlas: patches a side (tools/models/nature/tree_sprites.py ATLAS_CELLS).
const ATLAS_CELLS := 4
## A pixel of the leaves picture counts as a leaf when it is at least this opaque (the picture also
## holds the trunk's shadow on the crown, dark and half see-through).
const LEAF_ALPHA := 0.85
## The patch's light at a few leaves' scale is taken out (a box blur of BLUR texels either way, twice):
## the crown's broad light is the model's own. EDGE: how far bright leaves reach past the spray's
## round edge, and dark gaps fall short of it, in its radius. CONTRAST: the picture's light and shade
## at this power of its linear contrast (1: all of it; the model is lit again on top).
const BLUR := 3
const EDGE := 0.8
const CONTRAST := 0.8
## The grain's own light is taken out the same way, over GRAIN_BLUR texels either way (twice).
const GRAIN_BLUR := 4

static var enabled := true
static var atlas_enabled := true
static var grain_enabled := true
static var disk_cache := Switches.on("--tex-cache")
static var cache_hits := 0
static var _cache_stamp := ""
static var _cache_mutex := Mutex.new()
static var _cache_dir_made := false
static var _read := false
static var _trees := {}
static var _rocks := {}
## file -> Texture2D once made; -> [task id, holder] while its Image is made on a worker.
static var _atlases := {}
static var _jobs := {}
## file -> the leaf card materials waiting for its atlas.
static var _waiting := {}
static var _dressed: Array[ShaderMaterial] = []
## proto name -> [cumulative weights 0-1, shapes: [scale] standing or [basis, back] fallen], or
## false for one without an entry (placed()).
static var _shapes := {}
## The data's "grain": {size, layers: [{file, rect}], materials: {name: [layer, strength]}}.
static var _grain := {}
static var _grain_texture: Texture2DArray = null
static var _grain_job: Array = []  # [task id, holder] while the layers are made
static var _grain_failed := false


static func _load() -> void:
	if _read:
		return
	_read = true
	for a in Switches.args():
		if a == "--nature-looks=off":
			enabled = false
		elif a == "--leaf-atlas=off":
			atlas_enabled = false
		elif a == "--nature-grain=off":
			grain_enabled = false
	var text := FileAccess.get_file_as_string(DATA)
	var data_dir := ItemIcons.factorio_data_dir()
	if data_dir != "" and text != "":
		var info := data_dir.path_join("base/info.json")
		var fi := FileAccess.open(info, FileAccess.READ)
		var info_sz := fi.get_length() if fi != null else 0
		if fi != null:
			fi.close()
		_cache_stamp = "%s|%s|%d|%d" % [text.sha256_text().substr(0, 16), info, info_sz, FileAccess.get_modified_time(info)]
	var parsed = JSON.parse_string(text) if text != "" else null
	if parsed is Dictionary:
		var trees = parsed.get("trees")
		var rocks = parsed.get("rocks")
		var grain = parsed.get("grain")
		_trees = trees if trees is Dictionary else {}
		_rocks = rocks if rocks is Dictionary else {}
		_grain = grain if grain is Dictionary else {}


## A tree prototype's entry ({} if it has none).
static func tree(name: String) -> Dictionary:
	_load()
	var e = _trees.get(name)
	return e if e is Dictionary else {}


## The variation a tree grows as: `pick` (0-1) through the prototype's weights.
static func variation(entry: Dictionary, pick: float) -> int:
	var weights: Array = entry.get("weights", [])
	var total := 0.0
	for w in weights:
		total += float(w)
	var at := pick * total
	for i in weights.size():
		at -= float(weights[i])
		if at < 0.0:
			return i
	return maxi(weights.size() - 1, 0)


## Where a tree's or rock's model goes, or null for anything without an entry. `h` is the hash of
## its position chunk_view.gd turns it by. Runs for every tree in a chunk being built: each
## prototype's weights and shapes are made ready once (_ready_shapes).
static func placed(proto_name: String, h: int, at: Vector3) -> Variant:
	var ready: Variant = _shapes.get(proto_name)
	if ready == null:
		ready = _ready_shapes(proto_name)
	if not ready is Array:
		return null
	var cum: PackedFloat32Array = (ready as Array)[0]
	var shapes: Array = (ready as Array)[1]
	var yaw := float(h & 0xffff) / 65536.0 * TAU
	# A little size of its own on top of its picture's (Factorio's pictures of one variation are one
	# size; here every tree of a variation is one model).
	var jitter := 0.95 + 0.1 * float((h >> 16) & 0xff) / 255.0
	var pick := float(hash(h ^ 0x5bd1e995) & 0xffffff) / 16777216.0
	var s: Array = shapes[mini(cum.bsearch(pick), shapes.size() - 1)]
	var turn := Basis(Vector3.UP, yaw)
	if s.size() == 1:
		return Transform3D(turn * Basis.from_scale((s[0] as Vector3) * jitter), at)
	# Fallen: tipped over about its foot (falling along +x before the turn), squashed onto the ground,
	# its root end `back` tiles behind the entity.
	return Transform3D(turn * (s[0] as Basis) * jitter, at - turn * (s[1] as Vector3))


## Its entry in _shapes, made now; returns it.
static func _ready_shapes(proto_name: String) -> Variant:
	_load()
	var e = _trees.get(proto_name) if enabled else null
	var rock := false
	if not e is Dictionary and enabled:
		e = _rocks.get(proto_name)
		rock = true
	var raw: Array = (e as Dictionary).get("shapes", []) if e is Dictionary else []
	if raw.is_empty():
		_shapes[proto_name] = false
		return false
	var weights: Array = [] if rock else (e as Dictionary).get("weights", [])
	var total := 0.0
	for i in raw.size():
		total += float(weights[i]) if i < weights.size() else 1.0
	var cum := PackedFloat32Array()
	var run := 0.0
	var shapes: Array = []
	for i in raw.size():
		run += float(weights[i]) if i < weights.size() else 1.0
		cum.append(run / total)
		var s: Array = raw[i]
		if rock or s.size() < 5 or float(s[2]) == 0.0:
			shapes.append([Vector3(float(s[0]), float(s[1]), float(s[0]))])
		else:
			var k := float(s[0])
			var tipped := Basis.from_scale(Vector3(1.0, float(s[3]), 1.0)) * Basis(Vector3.BACK, -deg_to_rad(float(s[2])))
			shapes.append([tipped * Basis.from_scale(Vector3(k, k, k)), Vector3(float(s[4]), 0.0, 0.0)])
	cum[cum.size() - 1] = 1.0
	var ready := [cum, shapes]
	_shapes[proto_name] = ready
	return ready


## Called by model_library.gd on a freshly made model: a tree's or rock's bark and stone get their
## grain, a tree's leaf materials its prototype's colours, and its leaf cards the atlas of its leaves
## (now if made, else once it is).
static func prepare(mesh: Mesh, name: String) -> void:
	_load()
	if not enabled or not mesh is ArrayMesh:
		return
	var e := tree(name)
	if e.is_empty() and not _rocks.has(name):
		return
	_give_grain(mesh as ArrayMesh)
	if e.is_empty():
		return
	var tints := PackedVector3Array()
	for t in e.get("tints", []):
		if t is Array and (t as Array).size() >= 3 and tints.size() < 16:
			tints.append(Vector3(float(t[0]), float(t[1]), float(t[2])))
	var is_leaf := func(m: ShaderMaterial) -> bool: return m.shader == LeafShader
	var colour := func(m: ShaderMaterial) -> void:
		m.set_shader_parameter("leaf_tints", tints)
		m.set_shader_parameter("leaf_tint_count", tints.size())
	# Copies of its own (as ModelLibrary.edit_materials): another prototype of the same tree
	# (tree-08-brown) has other colours.
	var am := mesh as ArrayMesh
	for i in am.get_surface_count():
		var material := am.surface_get_material(i)
		var edited := MaterialRows.edit(material, is_leaf, colour)
		if edited != material:
			am.surface_set_material(i, edited)
	var leaves = e.get("leaves")
	if not atlas_enabled or not leaves is Dictionary:
		return
	var cards: Array[ShaderMaterial] = []
	for i in am.get_surface_count():
		var m := am.surface_get_material(i) as ShaderMaterial
		if m != null and m.shader == LeafShader and m.get_shader_parameter("leaf_core") != true:
			cards.append(m)
	if cards.is_empty():
		return
	var file := str((leaves as Dictionary).get("file", ""))
	var made = _atlases.get(file)
	if made is Texture2D:
		_dress(cards, made, leaves)
		return
	if made is bool:
		return  # not in this install
	if made == null and not _jobs.has(file):
		# Where the mods and Factorio's data are, found here first (as decoratives.gd does): workers
		# only read what the main thread found.
		ModFiles.prepare()
		var holder: Array = [null]
		var job := func() -> void: holder[0] = atlas(leaves)
		_jobs[file] = [WorkerThreadPool.add_task(job, false, "leaf atlas " + file.get_file()), holder, leaves]
	var list: Array = _waiting.get(file, [])
	list.append_array(cards)
	_waiting[file] = list


## Makes the atlases finished on their workers and gives them to the leaf cards waiting
## (model_library.gd's poll, every frame).
static func poll() -> void:
	_poll_grain()
	if _jobs.is_empty():
		return
	for file: String in _jobs.keys():
		var job: Array = _jobs[file]
		if not WorkerThreadPool.is_task_completed(job[0]):
			continue
		WorkerThreadPool.wait_for_task_completion(job[0])
		_jobs.erase(file)
		var image: Image = (job[1] as Array)[0]
		if image == null:
			_atlases[file] = false  # not in this install (a mod's own trees): the shader's leaves
			_waiting.erase(file)
			continue
		var tex := ImageTexture.create_from_image(image)
		_atlases[file] = tex
		_dress(_waiting.get(file, []), tex, job[2])
		_waiting.erase(file)


## Waits for the atlases still being made (a world leaving the tree, or the game quitting).
static func finish_all() -> void:
	for file: String in _jobs.keys():
		WorkerThreadPool.wait_for_task_completion((_jobs[file] as Array)[0])
	_jobs.clear()
	_waiting.clear()
	if not _grain_job.is_empty():
		WorkerThreadPool.wait_for_task_completion(_grain_job[0])
		_grain_job = []


## The bark's and rock's materials (rows) take their layer of the grain (factorio_material.gdshaderinc
## `nature_grain`: layer + 1 + strength), set now so every copy made of them later (levels of detail)
## has it; the layers themselves are made once, on a worker, and switched on for all (f3d_nature_grain).
static func _give_grain(mesh: ArrayMesh) -> void:
	if not grain_enabled or _grain_failed:
		return
	var grain = _grain.get("materials")
	if not grain is Dictionary or (grain as Dictionary).is_empty():
		return
	var pick := func(m: ShaderMaterial) -> bool: return (grain as Dictionary).has(m.resource_name)
	var give := func(m: ShaderMaterial) -> void:
		var g: Array = grain[m.resource_name]
		m.set_shader_parameter("nature_grain", float(int(g[0]) + 1) + clampf(float(g[1]), 0.0, 0.999))
	var any := false
	for i in mesh.get_surface_count():
		var material := mesh.surface_get_material(i)
		var edited := MaterialRows.edit(material, pick, give)
		if edited != material:
			mesh.surface_set_material(i, edited)
			any = true
	if any and _grain_texture == null and _grain_job.is_empty():
		ModFiles.prepare()
		var holder: Array = [null]
		var layers: Array = _grain.get("layers", [])
		var size := int(_grain.get("size", 64))
		var job := func() -> void: holder[0] = grain_layers(layers, size)
		_grain_job = [WorkerThreadPool.add_task(job, false, "nature grain"), holder]


static func _poll_grain() -> void:
	if _grain_job.is_empty() or not WorkerThreadPool.is_task_completed(_grain_job[0]):
		return
	WorkerThreadPool.wait_for_task_completion(_grain_job[0])
	var made = (_grain_job[1] as Array)[0]
	_grain_job = []
	if not made is Array or (made as Array).is_empty():
		_grain_failed = true  # no install: the plain materials, as before
		return
	var list: Array[Image] = []
	for im: Image in made:
		list.append(im)
	var tex := Texture2DArray.new()
	if tex.create_from_images(list) != OK:
		_grain_failed = true
		return
	_grain_texture = tex
	RenderingServer.global_shader_parameter_set("f3d_nature_grain", tex)
	RenderingServer.global_shader_parameter_set("f3d_nature_grain_on", 1.0)


static func _image_cache_path(kind: String, key_hash: String) -> String:
	return CACHE_DIR.path_join("%s-%s.bin" % [kind, key_hash.substr(0, 16)])


static func _read_image_cache(path: String, key_hash: String) -> Array:
	if not disk_cache or key_hash == "" or not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var raw: Variant = f.get_var(false)
	f.close()
	if not (raw is Dictionary):
		return []
	var d := raw as Dictionary
	if int(d.get("v", 0)) != CACHE_VERSION or str(d.get("k", "")) != key_hash:
		return []
	var raw_imgs: Variant = d.get("imgs")
	if not (raw_imgs is Array) or (raw_imgs as Array).is_empty():
		return []
	var out: Array = []
	for item in raw_imgs as Array:
		if not (item is Dictionary):
			return []
		var idict := item as Dictionary
		var w := int(idict.get("w", 0))
		var h := int(idict.get("h", 0))
		var fmt := int(idict.get("fmt", -1))
		var raw_data: Variant = idict.get("data")
		if w <= 0 or h <= 0 or fmt < 0 or not (raw_data is PackedByteArray):
			return []
		var bytes: PackedByteArray = raw_data
		var img := Image.create_from_data(w, h, bool(idict.get("mip", true)), fmt as Image.Format, bytes)
		if img == null or img.is_empty():
			return []
		out.append(img)
	_cache_mutex.lock()
	cache_hits += 1
	_cache_mutex.unlock()
	return out


static func _write_image_cache(path: String, key_hash: String, imgs: Array) -> void:
	if not disk_cache or key_hash == "" or imgs.is_empty():
		return
	var encoded: Array = []
	for item in imgs:
		if not (item is Image) or (item as Image).is_empty():
			return
		var im := item as Image
		encoded.append({
			"w": im.get_width(), "h": im.get_height(), "fmt": int(im.get_format()),
			"mip": im.has_mipmaps(), "data": im.get_data(),
		})
	_cache_mutex.lock()
	if not _cache_dir_made:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
		_cache_dir_made = true
	_cache_mutex.unlock()
	var tmp := path + ".tmp." + str(OS.get_thread_caller_id())
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_var({"v": CACHE_VERSION, "k": key_hash, "imgs": encoded}, false)
	var ok := f.get_error() == OK
	f.close()
	var abs_tmp := ProjectSettings.globalize_path(tmp)
	var abs_path := ProjectSettings.globalize_path(path)
	if not ok or DirAccess.rename_absolute(abs_tmp, abs_path) != OK:
		if FileAccess.file_exists(tmp):
			DirAccess.remove_absolute(abs_tmp)


## The grain layers, `size` square each (tree_sprites.py detail_layer does the same in numpy): each
## layer's region of its picture, its colour over its own light a few texels round (only the grain:
## the model is shaded on its own) at CONTRAST, mirrored out to the layer's size, scaled to a mean of
## 1 and halved. All of them or none ([] when a picture is missing). Runs on a worker thread.
## `pictures`: file -> Image instead of reading the files (the tests).
static func grain_layers(layers: Array, size: int, pictures := {}) -> Array:
	var cache_hash := ""
	var cache_path := ""
	if pictures.is_empty() and disk_cache and _cache_stamp != "" and not layers.is_empty():
		cache_hash = ("%d|grain|%d|%s|%s" % [CACHE_VERSION, size, _cache_stamp, JSON.stringify(layers)]).sha256_text()
		cache_path = _image_cache_path("nature-grain", cache_hash)
		var cached := _read_image_cache(cache_path, cache_hash)
		if cached.size() == layers.size() and not cached.is_empty():
			return cached
	var out: Array = []
	for layer: Dictionary in layers:
		var file := str(layer.get("file", ""))
		var src: Image = pictures.get(file)
		if src == null:
			src = ModFiles.load_image(file)
		if src == null:
			return []
		src = src.duplicate()
		src.convert(Image.FORMAT_RGBA8)
		var rect: Array = layer.get("rect", [0, 0, 1, 1])
		var x0 := int(rect[0])
		var y0 := int(rect[1])
		var w := maxi(int(rect[2]), 1)
		var h := maxi(int(rect[3]), 1)
		var data := src.get_data()
		var sw := src.get_width()
		var sh := src.get_height()
		var lin := PackedFloat32Array()
		lin.resize(w * h * 4)
		var mean := Vector3.ZERO
		for y in h:
			for x in w:
				var o := (clampi(y0 + y, 0, sh - 1) * sw + clampi(x0 + x, 0, sw - 1)) * 4
				var c := Color8(data[o], data[o + 1], data[o + 2]).srgb_to_linear()
				var k := (y * w + x) * 4
				lin[k] = c.r
				lin[k + 1] = c.g
				lin[k + 2] = c.b
				mean += Vector3(c.r, c.g, c.b)
		mean /= float(w * h)
		mean = mean.max(Vector3(1e-4, 1e-4, 1e-4))
		for t in w * h:
			lin[t * 4] = pow(lin[t * 4] / mean.x, CONTRAST)
			lin[t * 4 + 1] = pow(lin[t * 4 + 1] / mean.y, CONTRAST)
			lin[t * 4 + 2] = pow(lin[t * 4 + 2] / mean.z, CONTRAST)
		var local := lin.duplicate()
		for _pass in 2:
			_box(local, w, h, GRAIN_BLUR, true)
			_box(local, w, h, GRAIN_BLUR, false)
		var ratio := PackedFloat32Array()
		ratio.resize(size * size * 3)
		var lum := 0.0
		for y in size:
			var my := y % (2 * h)
			my = my if my < h else 2 * h - 1 - my
			for x in size:
				var mx := x % (2 * w)
				mx = mx if mx < w else 2 * w - 1 - mx
				var k := (my * w + mx) * 4
				var l := maxf(0.2126 * local[k] + 0.7152 * local[k + 1] + 0.0722 * local[k + 2], 0.05)
				var t := (y * size + x) * 3
				ratio[t] = lin[k] / l
				ratio[t + 1] = lin[k + 1] / l
				ratio[t + 2] = lin[k + 2] / l
				lum += 0.2126 * ratio[t] + 0.7152 * ratio[t + 1] + 0.0722 * ratio[t + 2]
		var scale := 0.5 / maxf(lum / float(size * size), 1e-3)
		var bytes := PackedByteArray()
		bytes.resize(size * size * 4)
		for t in size * size:
			bytes[t * 4] = clampi(roundi(ratio[t * 3] * scale * 255.0), 0, 255)
			bytes[t * 4 + 1] = clampi(roundi(ratio[t * 3 + 1] * scale * 255.0), 0, 255)
			bytes[t * 4 + 2] = clampi(roundi(ratio[t * 3 + 2] * scale * 255.0), 0, 255)
			bytes[t * 4 + 3] = 255
		var im := Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, bytes)
		im.generate_mipmaps()
		out.append(im)
	if cache_hash != "" and out.size() == layers.size() and not out.is_empty():
		_write_image_cache(cache_path, cache_hash, out)
	return out


static func _dress(cards: Array, tex: Texture2D, leaves: Dictionary) -> void:
	for m: ShaderMaterial in cards:
		m.set_shader_parameter("leaf_atlas", tex)
		m.set_shader_parameter("leaf_atlas_texels", float(int(leaves.get("patch", 36))))
		m.set_shader_parameter("leaf_atlas_cells", float(ATLAS_CELLS))
		_dressed.append(m)


## Every dressed leaf card wearing its atlas, or the shader's own leaves (the stutter probe's
## "leaf atlas off" variant).
static func show_atlas(on: bool) -> void:
	for m: ShaderMaterial in _dressed:
		m.set_shader_parameter("leaf_atlas_cells", float(ATLAS_CELLS) if on else 0.0)


## The leaf atlas for an entry's leaves picture (tree_sprites.py leaf_atlas does the same in numpy,
## for the model tools' previews), or null without the picture. Runs on a worker thread.
static func atlas(leaves: Dictionary, picture: Image = null) -> Image:
	var cache_hash := ""
	var cache_path := ""
	if picture == null and disk_cache and _cache_stamp != "":
		cache_hash = ("%d|atlas|%d|%s|%s" % [CACHE_VERSION, ATLAS_CELLS, _cache_stamp, JSON.stringify(leaves)]).sha256_text()
		cache_path = _image_cache_path("nature-atlas", cache_hash)
		var cached := _read_image_cache(cache_path, cache_hash)
		if cached.size() == 1:
			return cached[0]
	var src := picture if picture != null else ModFiles.load_image(str(leaves.get("file", "")))
	if src == null:
		return null
	src = src.duplicate() if picture != null else src
	src.convert(Image.FORMAT_RGBA8)
	var patch := int(leaves.get("patch", 36))
	var r := patch / 2
	var mean_a: Array = leaves.get("mean", [1.0, 1.0, 1.0])
	var mean := Vector3(maxf(float(mean_a[0]), 1e-4), maxf(float(mean_a[1]), 1e-4), maxf(float(mean_a[2]), 1e-4))
	var centres: Array = leaves.get("patches", [])
	if centres.is_empty():
		return null
	var w := src.get_width()
	var hgt := src.get_height()
	var data := src.get_data()
	var n := patch * patch
	var size := ATLAS_CELLS * patch
	var rgb := PackedFloat32Array()  # the atlas's ratios, 3 a texel
	rgb.resize(size * size * 3)
	var alpha := PackedFloat32Array()
	alpha.resize(size * size)
	var lum_sum := 0.0
	var kept := 0
	for i in ATLAS_CELLS * ATLAS_CELLS:
		var c: Array = centres[i % centres.size()]
		var x0 := int(c[0]) - r
		var y0 := int(c[1]) - r
		# [ratio r, g, b, leaf] per texel, and its blurred copy weighted by the leaves.
		var px := PackedFloat32Array()
		px.resize(n * 4)
		var weighted := PackedFloat32Array()
		weighted.resize(n * 4)
		for y in patch:
			for x in patch:
				var sx := clampi(x0 + x, 0, w - 1)
				var sy := clampi(y0 + y, 0, hgt - 1)
				var o := (sy * w + sx) * 4
				var col := Color8(data[o], data[o + 1], data[o + 2]).srgb_to_linear()
				var leaf := 1.0 if data[o + 3] / 255.0 > LEAF_ALPHA else 0.0
				var k := (y * patch + x) * 4
				px[k] = pow(col.r / mean.x, CONTRAST)
				px[k + 1] = pow(col.g / mean.y, CONTRAST)
				px[k + 2] = pow(col.b / mean.z, CONTRAST)
				px[k + 3] = leaf
				weighted[k] = px[k] * leaf
				weighted[k + 1] = px[k + 1] * leaf
				weighted[k + 2] = px[k + 2] * leaf
				weighted[k + 3] = leaf
		for _pass in 2:
			_box(weighted, patch, patch, BLUR, true)
			_box(weighted, patch, patch, BLUR, false)
		var gx := (i % ATLAS_CELLS) * patch
		var gy := (i / ATLAS_CELLS) * patch
		for y in patch:
			for x in patch:
				var k := (y * patch + x) * 4
				var cover := maxf(weighted[k + 3], 1e-3)
				var local := maxf((0.2126 * weighted[k] + 0.7152 * weighted[k + 1] + 0.0722 * weighted[k + 2]) / cover, 0.05)
				var cr := px[k] / local
				var cg := px[k + 1] / local
				var cb := px[k + 2] / local
				var b := clampf(0.2126 * cr + 0.7152 * cg + 0.0722 * cb, 0.0, 2.0) * 0.5
				var dx := (x + 0.5 - r) / r
				var dy := (y + 0.5 - r) / r
				var edge := clampf((0.92 - sqrt(dx * dx + dy * dy) + EDGE * (b - 0.5)) * 10.0, 0.0, 1.0)
				var a := px[k + 3] * edge
				var t := (gy + y) * size + gx + x
				rgb[t * 3] = cr
				rgb[t * 3 + 1] = cg
				rgb[t * 3 + 2] = cb
				alpha[t] = a
				if a >= 0.5:
					lum_sum += 0.2126 * cr + 0.7152 * cg + 0.0722 * cb
					kept += 1
	# A mean of 1 over the leaves kept, halved for 8 bits (the shader doubles it).
	var scale := 0.5 / maxf(lum_sum / maxi(kept, 1), 1e-3)
	var bytes := PackedByteArray()
	bytes.resize(size * size * 4)
	for t in size * size:
		bytes[t * 4] = clampi(roundi(rgb[t * 3] * scale * 255.0), 0, 255)
		bytes[t * 4 + 1] = clampi(roundi(rgb[t * 3 + 1] * scale * 255.0), 0, 255)
		bytes[t * 4 + 2] = clampi(roundi(rgb[t * 3 + 2] * scale * 255.0), 0, 255)
		bytes[t * 4 + 3] = clampi(roundi(alpha[t] * 255.0), 0, 255)
	var out := Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, bytes)
	out.generate_mipmaps()
	if cache_hash != "" and out != null and not out.is_empty():
		_write_image_cache(cache_path, cache_hash, [out])
	return out


## A box blur of `r` texels either way along the rows (or columns) of a w x h picture, 4 values a
## texel, the edges clamped (as numpy's edge padding), in place.
static func _box(v: PackedFloat32Array, w: int, h: int, r: int, rows: bool) -> void:
	var lines := h if rows else w
	var n := w if rows else h
	var line := PackedFloat32Array()
	line.resize(n * 4)
	var inv := 1.0 / float(2 * r + 1)
	for j in lines:
		for i in n:
			var k := ((j * w + i) if rows else (i * w + j)) * 4
			for ch in 4:
				line[i * 4 + ch] = v[k + ch]
		for ch in 4:
			var s := 0.0
			for d in range(-r, r + 1):
				s += line[clampi(d, 0, n - 1) * 4 + ch]
			for i in n:
				var k := ((j * w + i) if rows else (i * w + j)) * 4
				v[k + ch] = s * inv
				s += line[clampi(i + r + 1, 0, n - 1) * 4 + ch] - line[clampi(i - r, 0, n - 1) * 4 + ch]
