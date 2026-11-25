extends RefCounted
## Textures a model brings in its .glb (base colour, metallic-roughness, occlusion), made ready for the
## model shader on the worker thread that reads the model (model_library.gd Load): Godot's glTF
## reader makes them without mipmaps, which shimmer on a model a few tiles away, so each picture is
## decoded again from the file's own bytes, mipmapped and put back on its material. A small copy
## (SMALL px) rides along as meta, for far_chunks.gd to colour a merged far chunk's vertices from.
## Models without textures pass through untouched. A texture whose glTF sampler says NEAREST
## (Blender's Image Texture node set to Closest, which its exporter writes so) is marked
## NEAREST_META, and the model shader draws it crisp, texel by texel, still mipmapped far away
## (modeller's request: hand-painted low-resolution textures read better unblended).
##
## Pictures are shared between models (share): a modeller's files each carry their own copy of the
## pictures they use (Vasillo's 39 models bring 188 textures of 48 different pictures, about 1.7 GB of
## video memory mipmapped against 0.5 GB shared), so each is made once, found by a hash of its bytes
## as stored in the file, or failing that of its pixels once decoded.
##
## A material marked Alpha Blend whose base colour is fully opaque, colour and picture alike (no alpha
## channel, or every pixel's alpha 255), is drawn as the solid thing it is (opaque_blend): Vasillo's
## belt surface is marked BLEND with a picture that has no alpha, and the see-through shader put the
## top of every belt, splitter and underground in the transparent pass (sorted, blended, left out of
## the depth pre-pass and so of SSAO and contact shading).
##
## A belt surface (belt_return.gd is_surface) still Alpha Blend after that, its picture having
## see-through pixels (Vasillo's new belt picture: notched plate corners), is drawn cut out (Alpha Clip
## at CLIP_BELT, belt_clip): blended, it wrote no depth, and the return run drawn in the same draw
## (belt_return.gd) painted its backward chevrons over the top run. A belt is never meant to be
## translucent; cut out, the notches still show and the depth test hides the return.
##
## A modeller's Alpha Blend material whose picture is opaque on CLIP_SHARE or more of its pixels (Vasillo's
## drill: 0.1-0.3% of its pixels a little see-through) is drawn cut out at CLIP_BELT too (clip_blend,
## --blend-clip=off): blended it can't sort its own parts; real glass (alpha 0.6 everywhere) stays blended.
## The belt surface is that rule's special case: cut out whatever share of its picture is see-through.
##
## Emission as glTF says (emission_strict): a material glows only by emissiveFactor (absent: black, glTF's
## default), so an emission picture wired with no factor, or a factor of zero, is no glow. Godot's reader
## turns emission on, white, for any emission picture, and Zenith read that as "lights up while working"
## (a see-through one as a plume that fades out at rest): Vasillo's export preset wires a black emission
## picture into 30 of his see-through materials, which vanished whenever their machine was idle. An
## emission picture black on every pixel (BLACK_META) is no glow either.

const BeltReturn := preload("res://scripts/world/belt_return.gd")
const Switches := preload("res://scripts/switches.gd")

## Meta on a Texture2D: a SMALL x SMALL Image of it (RGBA8, sRGB as stored).
const SMALL_META := &"f3d_small"
const SMALL := 64
## Meta on a Texture2D: true when its glTF sampler filters NEAREST.
const NEAREST_META := &"f3d_nearest"
## Meta on a Texture2D: true when every pixel of its picture is opaque (no alpha channel, or all 255).
const OPAQUE_META := &"f3d_opaque"
## Meta on a Texture2D: the share of its picture's pixels that are opaque (alpha 255), 0-1. OPAQUE_META is
## this share being 1 (the same count, made when the picture is decoded).
const OPAQUE_SHARE_META := &"f3d_opaque_share"
## Meta on a Texture2D: true when its picture is black on every pixel (red, green and blue all 0).
const BLACK_META := &"f3d_black"
## Meta on a material read from a modeller's pack (model_library.gd Load.modeller): its own glow never
## dims its base colour at rest (model_library.gd _factorio, glow_keeps_albedo).
const MODELLER_META := &"f3d_modeller"
const GL_NEAREST := 9728
const GL_NEAREST_MIPMAP_NEAREST := 9984
const GL_NEAREST_MIPMAP_LINEAR := 9986

## --share-textures=off: every model's pictures its own, as before 0.2.1 (for comparing).
static var share := Switches.on("--share-textures")
## --opaque-blend=off: Alpha Blend materials stay see-through whatever their picture (for comparing).
static var opaque_blend := Switches.on("--opaque-blend")
## --belt-surface-blend=on: a belt surface with a see-through picture stays Alpha Blend, as before 0.2.2.
static var belt_clip := not (Switches.has("--belt-surface-blend=on"))
## The cutoff a blended belt surface is cut out at.
const CLIP_BELT := 0.5
## --blend-clip=off: a modeller's nearly opaque Alpha Blend material stays blended, as before 0.2.2.
static var blend_clip := Switches.on("--blend-clip")
## The share of opaque pixels from which a modeller's blended material is drawn cut out (at CLIP_BELT).
const CLIP_SHARE := 0.95
## --emission-strict=off: any emission picture glows, factor or not, as before 0.2.2 (Godot's reading).
static var emission_strict := Switches.on("--emission-strict")
## --model-pictures=godot: Godot's glTF reader decodes every picture a .glb holds (every copy, each
## made a texture and thrown away) before prepare() decodes the ones it keeps again, as before. By
## default a .glb whose pictures are all its own PNG or JPEG (can_wire) is read with its pictures
## left out of Godot's reader (strip_pictures, and HANDLE_BINARY_DISCARD_TEXTURES) and prepare() puts on each material the textures the
## file's JSON gives it, each picture decoded once for all models (or read from the disk cache).
static var own_pictures := not (Switches.has("--model-pictures=godot"))
## --tex-cache=off (shared with the ground's textures): each picture decoded and mipmapped at every
## start. On, a picture made once is kept in user://tex-cache (CACHE_DIR, by the hash of its bytes as
## stored), mipmapped as the renderer takes it, with its small copy and its counts; up to CACHE_BYTES,
## the oldest going first (prune_cache).
static var disk_cache := Switches.on("--tex-cache")
const CACHE_DIR := "user://tex-cache"
const CACHE_PREFIX := "model-"
const CACHE_VERSION := 1
const CACHE_BYTES := 2 << 30
## Pictures read from the disk cache, and written to it (tests and probes).
static var cache_hits := 0
static var cache_writes := 0
static var _cache_dir_made := false
## The glTF material slots a texture goes in, as Godot's reader puts them (gltf_document.cpp
## _parse_materials): [path in the material's JSON, texture params].
const SLOTS := [
	[["pbrMetallicRoughness", "baseColorTexture"], [BaseMaterial3D.TEXTURE_ALBEDO]],
	[["pbrMetallicRoughness", "metallicRoughnessTexture"], [BaseMaterial3D.TEXTURE_METALLIC, BaseMaterial3D.TEXTURE_ROUGHNESS]],
	[["normalTexture"], [BaseMaterial3D.TEXTURE_NORMAL]],
	[["occlusionTexture"], [BaseMaterial3D.TEXTURE_AMBIENT_OCCLUSION]],
	[["emissiveTexture"], [BaseMaterial3D.TEXTURE_EMISSION]],
]
## Extensions that make Godot's reader build textures from the pictures themselves: such a file is
## read the old way.
const PICTURE_EXTENSIONS := ["KHR_materials_pbrSpecularGlossiness", "KHR_texture_basisu", "EXT_texture_webp", "MSFT_texture_dds"]
## Shared pictures: "<md5 of the file's bytes> <crisp>" or "px <hash of the pixels> <size> <crisp>" ->
## the mipmapped texture. Read and written by the workers that load models, under _lock.
static var _shared := {}
static var _lock := Mutex.new()
## Pictures made, and those found already made (for tests and probes).
static var made_count := 0
static var shared_count := 0


## Mipmapped copies of the base colour and roughness textures of every material in `state`, read
## from the .glb at `path`; Alpha Blend materials whose base colour is opaque turned solid, emission
## that the file doesn't give turned off. `modeller`: from a modeller's pack (Load.modeller).
## Worker-thread safe (Image and ImageTexture work; the shared table is locked).
## `glb`: the file as read_glb() read it ({}: read here). `wired`: the state was read with its pictures
## left out (can_wire): each material gets its textures from the JSON here. False when a picture can't
## be decoded (the caller reads the file the old way then).
static func prepare(path: String, state: GLTFState, modeller := false, glb := {}, wired := false) -> bool:
	var materials := state.get_materials()
	if materials.is_empty():
		return true
	if wired and not _wire(state, glb):
		return false
	var wanted := false
	var glows := false
	for m in materials:
		var base := m as BaseMaterial3D
		if base == null:
			continue
		if modeller:
			base.set_meta(MODELLER_META, true)
		glows = glows or base.emission_enabled
		if (base.albedo_texture != null or base.roughness_texture != null
				or base.emission_texture != null or base.normal_texture != null or base.ao_texture != null):
			wanted = true
	if not wanted and not (glows and emission_strict):
		return true
	var nearest := {}  # image index -> true when a texture of it samples NEAREST
	var factors: Array = []  # per material of the file: its emissiveFactor, or null
	var images := _images(path, nearest, factors, wanted and not wired, glb)
	if glows and emission_strict:
		# GLTFState keeps the file's materials in its order.
		for i in mini(materials.size(), factors.size()):
			var base := materials[i] as BaseMaterial3D
			if base != null and base.emission_enabled and not _emits(factors[i]):
				base.emission_enabled = false
	var done := {}  # original texture -> mipmapped one
	for m in materials:
		var base := m as BaseMaterial3D
		if base == null:
			continue
		for param in [BaseMaterial3D.TEXTURE_ALBEDO, BaseMaterial3D.TEXTURE_ROUGHNESS, BaseMaterial3D.TEXTURE_METALLIC,
				BaseMaterial3D.TEXTURE_EMISSION, BaseMaterial3D.TEXTURE_NORMAL, BaseMaterial3D.TEXTURE_AMBIENT_OCCLUSION]:
			var tex := base.get_texture(param)
			if tex == null or (param == BaseMaterial3D.TEXTURE_EMISSION and not base.emission_enabled):
				continue
			if wired:
				continue  # made already (_wire)
			if not done.has(tex):
				done[tex] = _mipmapped(tex, state, images, nearest)
			base.set_texture(param, done[tex])
		if emission_strict and base.emission_enabled and base.emission_texture != null \
				and bool(base.emission_texture.get_meta(BLACK_META, false)):
			base.emission_enabled = false
		if opaque_blend and solid_blend(base):
			base.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		elif (belt_clip and clip_belt(base)) or (blend_clip and modeller and clip_blend(base)):
			base.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			base.alpha_scissor_threshold = CLIP_BELT
	return true


## A .glb read once, for both Godot's reader and prepare(): {"bytes", "doc" (its JSON), "bin_at",
## "bin_len" (its binary chunk; bin_at -1 without one)}; {} when `path` isn't a readable .glb (a
## .gltf is read the old way).
static func read_glb(path: String) -> Dictionary:
	if path.get_extension().to_lower() != "glb":
		return {}
	return parse_glb(FileAccess.get_file_as_bytes(path))


static func parse_glb(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 20 or bytes.decode_u32(0) != 0x46546C67:
		return {}
	var json_len := bytes.decode_u32(12)
	if 20 + json_len > bytes.size():
		return {}
	var doc = JSON.parse_string(bytes.slice(20, 20 + json_len).get_string_from_utf8())
	if not doc is Dictionary:
		return {}
	var at := 20 + json_len
	var bin_at := -1
	var bin_len := 0
	if at + 8 <= bytes.size():
		bin_len = mini(bytes.decode_u32(at), bytes.size() - at - 8)
		bin_at = at + 8
	return {"bytes": bytes, "doc": doc, "bin_at": bin_at, "bin_len": bin_len}


## A 1 x 1 PNG as a data URI: what strip_pictures gives Godot's reader in place of each picture. Made
## when the script loads (on the main thread): strip_pictures runs on the model readers' workers, and a
## static filled there lazily raced between them.
static var _dot_uri := _make_dot_uri()


static func _make_dot_uri() -> String:
	var dot := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	dot.fill(Color.WHITE)
	return "data:image/png;base64," + Marshalls.raw_to_base64(dot.save_png_to_buffer())


## The .glb's bytes for Godot's reader with every picture a 1 x 1 PNG (data URI): Godot 4.7's reader
## decodes every picture even when told to discard them (HANDLE_BINARY_DISCARD_TEXTURES only skips
## making textures), 0.3-0.5 s a model of Vasillo's. The rest of the JSON goes through unchanged in
## value (Godot reads its numbers as floats either way; written back at full precision), the binary
## chunk as it is. Empty when it can't be made.
static func strip_pictures(glb: Dictionary) -> PackedByteArray:
	var doc: Dictionary = (glb["doc"] as Dictionary).duplicate()
	var pictures: Array = doc.get("images", [])
	if pictures.is_empty():
		return glb["bytes"]
	var stripped: Array = []
	for pic in pictures:
		var keep := {"uri": _dot_uri, "mimeType": "image/png"}
		if pic is Dictionary and (pic as Dictionary).has("name"):
			keep["name"] = pic["name"]
		stripped.append(keep)
	doc["images"] = stripped
	var json := JSON.stringify(doc, "", false, true).to_utf8_buffer()
	while json.size() % 4 != 0:
		json.append(0x20)
	var bytes: PackedByteArray = glb["bytes"]
	var bin_at := int(glb["bin_at"])
	var bin_chunk := bytes.slice(bin_at - 8, bin_at + int(glb["bin_len"])) if bin_at >= 8 else PackedByteArray()
	var out := PackedByteArray()
	out.resize(20)
	out.encode_u32(0, 0x46546C67)
	out.encode_u32(4, 2)
	out.encode_u32(8, 20 + json.size() + bin_chunk.size())
	out.encode_u32(12, json.size())
	out.encode_u32(16, 0x4E4F534A)
	out.append_array(json)
	out.append_array(bin_chunk)
	return out


## True when every picture of the file is its own PNG or JPEG in its binary chunk, every texture one
## of them, and no extension makes textures of its own: its materials can be wired from the JSON
## (_wire) with the pictures left out of Godot's reader (strip_pictures).
static func can_wire(glb: Dictionary) -> bool:
	if glb.is_empty() or int(glb["bin_at"]) < 0:
		return false
	var doc: Dictionary = glb["doc"]
	for e in doc.get("extensionsUsed", []):
		if str(e) in PICTURE_EXTENSIONS:
			return false
	var pictures: Array = doc.get("images", [])
	for pic in pictures:
		if not pic is Dictionary or not (pic as Dictionary).has("bufferView") \
				or not str((pic as Dictionary).get("mimeType", "")) in ["image/png", "image/jpeg"]:
			return false
	for t in doc.get("textures", []):
		if not t is Dictionary or not (t as Dictionary).has("source") or int(t["source"]) < 0 or int(t["source"]) >= pictures.size():
			return false
	return true


## Puts on each material of a state read without its pictures the textures its JSON names, made as
## _mipmapped makes them (shared, from the disk cache, else decoded). False when one can't be.
static func _wire(state: GLTFState, glb: Dictionary) -> bool:
	var doc: Dictionary = glb["doc"]
	var nearest := {}
	var factors: Array = []
	var images := _images("", nearest, factors, true, glb)
	var textures: Array = doc.get("textures", [])
	var made := {}  # image index -> texture
	var mats: Array = doc.get("materials", [])
	var materials := state.get_materials()
	for i in mini(mats.size(), materials.size()):
		var base := materials[i] as BaseMaterial3D
		if base == null or not mats[i] is Dictionary:
			continue
		for slot: Array in SLOTS:
			var info: Variant = mats[i]
			for key: String in slot[0]:
				info = (info as Dictionary).get(key) if info is Dictionary else null
			if not info is Dictionary or not (info as Dictionary).has("index"):
				continue
			var ti := int(info["index"])
			if ti < 0 or ti >= textures.size():
				continue
			var src := int(textures[ti]["source"])
			if not made.has(src):
				if not images.has(src):
					return false
				var tex := _made(images[src], nearest.has(src))
				if tex == null:
					return false
				made[src] = tex
			for param: int in slot[1]:
				base.set_texture(param, made[src])
	return true


## True when a material's emissiveFactor (null: absent) makes it glow: some channel above 0.
static func _emits(factor: Variant) -> bool:
	if not factor is Array:
		return false
	for c in factor:
		if (c is float or c is int) and float(c) > 0.0:
			return true
	return false


## True for an Alpha Blend material (glTF BLEND) that can't be see-through anywhere: its base colour's
## alpha is 1 and its picture is opaque (OPAQUE_META, set when the picture is decoded). Emissive ones
## stay see-through: a glowing plume fades out with its machine (factorio_material's glow_fades).
static func solid_blend(base: BaseMaterial3D) -> bool:
	if base == null or base.emission_enabled:
		return false
	# Godot's glTF reader makes BLEND alpha with a depth pre-pass.
	if base.transparency != BaseMaterial3D.TRANSPARENCY_ALPHA and base.transparency != BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS:
		return false
	if base.albedo_color.a < 0.999 or base.albedo_texture == null:
		return false
	return bool(base.albedo_texture.get_meta(OPAQUE_META, false))


## True for an Alpha Blend belt surface (belt_return.gd is_surface) whose picture has see-through
## pixels, any share of them: drawn cut out instead (belt_clip). clip_blend's special case.
static func clip_belt(base: BaseMaterial3D) -> bool:
	return _blended_picture(base) and BeltReturn.is_surface(base)


## True for an Alpha Blend material whose picture is opaque on CLIP_SHARE or more of its pixels, but not
## all (that one is solid_blend's): drawn cut out at CLIP_BELT (blend_clip; a modeller's only, prepare()).
static func clip_blend(base: BaseMaterial3D) -> bool:
	return _blended_picture(base) and opaque_share(base.albedo_texture) >= CLIP_SHARE


## An Alpha Blend material, its colour fully opaque, not glowing, its picture with see-through pixels:
## what clip_belt and clip_blend cut out.
static func _blended_picture(base: BaseMaterial3D) -> bool:
	if base == null or base.emission_enabled or base.albedo_texture == null:
		return false
	if base.transparency != BaseMaterial3D.TRANSPARENCY_ALPHA and base.transparency != BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS:
		return false
	return base.albedo_color.a >= 0.999 and opaque_share(base.albedo_texture) < 1.0


## The share of a texture's pixels that are opaque (OPAQUE_SHARE_META; a texture marked only with
## OPAQUE_META, 1 or 0; neither, 0).
static func opaque_share(tex: Texture2D) -> float:
	if tex == null:
		return 0.0
	if tex.has_meta(OPAQUE_SHARE_META):
		return float(tex.get_meta(OPAQUE_SHARE_META))
	return 1.0 if bool(tex.get_meta(OPAQUE_META, false)) else 0.0


## Image index -> [the picture's bytes as stored, its mime type], from the .glb's JSON and binary
## chunk; `nearest` gets the image indices a NEAREST sampler draws, `factors` each material's
## emissiveFactor (null when absent). Decoded only when no model made the same picture before
## (_mipmapped). Without `with_pictures`, only the JSON is read.
## `glb`: the file read already (read_glb), else it is read here.
static func _images(path: String, nearest: Dictionary, factors: Array, with_pictures := true, glb := {}) -> Dictionary:
	var out := {}
	var doc: Variant = null
	var bin := PackedByteArray()
	var bin_at := 0
	if not glb.is_empty():
		doc = glb["doc"]
		for m in (doc as Dictionary).get("materials", []):
			factors.append((m as Dictionary).get("emissiveFactor") if m is Dictionary else null)
		if not with_pictures:
			return out
		if int(glb["bin_at"]) >= 0:
			bin = glb["bytes"]
			bin_at = int(glb["bin_at"])
	else:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null or f.get_32() != 0x46546C67:
			return out
		f.get_32()
		f.get_32()
		var json_len := f.get_32()
		f.get_32()
		doc = JSON.parse_string(f.get_buffer(json_len).get_string_from_utf8())
		if not doc is Dictionary:
			return out
		for m in doc.get("materials", []):
			factors.append((m as Dictionary).get("emissiveFactor") if m is Dictionary else null)
		if not with_pictures:
			return out
		if f.get_position() + 8 <= f.get_length():
			var bin_len := f.get_32()
			f.get_32()
			bin = f.get_buffer(bin_len)
	var samplers: Array = doc.get("samplers", [])
	for t in doc.get("textures", []):
		if not t is Dictionary or not t.has("source") or not t.has("sampler"):
			continue
		var si := int(t["sampler"])
		if si >= 0 and si < samplers.size() and samplers[si] is Dictionary:
			var mag := int((samplers[si] as Dictionary).get("magFilter", 0))
			if mag == GL_NEAREST or mag == GL_NEAREST_MIPMAP_NEAREST or mag == GL_NEAREST_MIPMAP_LINEAR:
				nearest[int(t["source"])] = true
	var views: Array = doc.get("bufferViews", [])
	var pictures: Array = doc.get("images", [])
	for src in pictures.size():
		var pic: Dictionary = pictures[src]
		if not pic.has("bufferView"):
			continue
		var view: Dictionary = views[int(pic["bufferView"])]
		var start := bin_at + int(view.get("byteOffset", 0))
		out[src] = [bin.slice(start, start + int(view["byteLength"])), str(pic.get("mimeType", ""))]
	return out


static func _decode(pic: Array) -> Image:
	var img := Image.new()
	var bytes: PackedByteArray = pic[0]
	var err := img.load_jpg_from_buffer(bytes) if str(pic[1]) == "image/jpeg" else img.load_png_from_buffer(bytes)
	return img if err == OK else null


static func _mipmapped(tex: Texture2D, state: GLTFState, images: Dictionary, nearest: Dictionary) -> Texture2D:
	# GLTFState keeps the file's images in its order: this texture's index there is the file's.
	var src := -1
	var made := state.get_images()
	for i in made.size():
		if made[i] == tex and images.has(i):
			src = i
	if src < 0:
		return tex
	var out := _made(images[src], nearest.has(src))
	return out if out != null else tex


## The mipmapped texture of a picture ([its bytes as stored, its mime type]): one made before (share),
## else from the disk cache, else decoded; null when it can't be decoded.
static func _made(pic: Array, crisp: bool) -> Texture2D:
	var bytes: PackedByteArray = pic[0]
	var file_key := ""
	var digest := ""
	if share or disk_cache:
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_MD5)
		ctx.update(bytes)
		digest = ctx.finish().hex_encode()
	if share:
		file_key = "%s %d %s" % [digest, bytes.size(), crisp]
		var known := _find(file_key)
		if known != null:
			return known
	if disk_cache:
		var cached := _read_cache(digest, bytes.size(), crisp)
		if cached != null:
			return _keep_first(cached, file_key, file_key)
	var img := _decode(pic)
	if img == null:
		return null
	if img.get_format() != Image.FORMAT_RGBA8 and img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGBA8)
	var pixel_key := ""
	if share:
		# The same picture written to another file with other bytes (another exporter's PNG settings).
		pixel_key = "px %d %d %dx%d %d %s" % [hash(img.get_data()), img.get_data().size(), img.get_width(), img.get_height(),
			img.get_format(), crisp]
		var known := _find(pixel_key)
		if known != null:
			_keep(file_key, known)
			return known
	var counts := _pixel_counts(img)
	var small := img.duplicate() as Image
	small.convert(Image.FORMAT_RGBA8)
	small.resize(SMALL, SMALL, Image.INTERPOLATE_BILINEAR)
	img.generate_mipmaps()
	if disk_cache:
		_write_cache(digest, bytes.size(), crisp, img, small, counts)
	return _keep_first(_texture(img, small, counts, crisp), pixel_key, file_key)


## A texture of a mipmapped picture, with its metas.
static func _texture(img: Image, small: Image, counts: Array, crisp: bool) -> Texture2D:
	var out := ImageTexture.create_from_image(img)
	out.set_meta(SMALL_META, small)
	out.set_meta(OPAQUE_META, float(counts[0]) >= 1.0)
	out.set_meta(OPAQUE_SHARE_META, counts[0])
	out.set_meta(BLACK_META, counts[1])
	if crisp:
		out.set_meta(NEAREST_META, true)
	return out


## The texture kept for a picture made here (share): another worker may have made the same picture
## meanwhile, and the first one kept is everyone's (under `key`, and `file_key` too).
static func _keep_first(out: Texture2D, key: String, file_key: String) -> Texture2D:
	if not share:
		return out
	_lock.lock()
	var first: Variant = _shared.get(key)
	if first == null:
		_shared[key] = out
		made_count += 1
	else:
		out = first
		shared_count += 1
	_shared[file_key] = out
	_lock.unlock()
	return out


static func _cache_path(digest: String, size: int, crisp: bool) -> String:
	return CACHE_DIR.path_join("%s%s-%d%s.bin" % [CACHE_PREFIX, digest, size, "-n" if crisp else ""])


## A picture made before, read from the disk cache (null: not there, or not as this version writes).
static func _read_cache(digest: String, size: int, crisp: bool) -> Texture2D:
	var path := _cache_path(digest, size, crisp)
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	# (store_var's length word first: a damaged file's must fit in it, or get_var tries to allocate it.)
	var n := f.get_32()
	if n == 0 or n > f.get_length() - 4:
		f.close()
		return null
	f.seek(0)
	var raw: Variant = f.get_var(false)
	f.close()
	if not raw is Dictionary:
		return null
	var d := raw as Dictionary
	if int(d.get("v", 0)) != CACHE_VERSION or str(d.get("k", "")) != digest:
		return null
	var raw_len := int(d.get("raw_len", 0))
	var data: Variant = d.get("data")
	var small_data: Variant = d.get("small")
	if raw_len <= 0 or not data is PackedByteArray or not small_data is PackedByteArray:
		return null
	var packed: PackedByteArray = data
	var bytes: PackedByteArray = packed.decompress(raw_len, FileAccess.COMPRESSION_FASTLZ) if bool(d.get("z", false)) else packed
	var w := int(d.get("w", 0))
	var h := int(d.get("h", 0))
	var fmt := int(d.get("fmt", -1))
	if bytes.size() != raw_len or w <= 0 or h <= 0 or (fmt != Image.FORMAT_RGBA8 and fmt != Image.FORMAT_RGB8) \
			or (small_data as PackedByteArray).size() != SMALL * SMALL * 4 \
			or _mip_bytes(w, h, 4 if fmt == Image.FORMAT_RGBA8 else 3) != raw_len:
		return null
	var img := Image.create_from_data(w, h, true, fmt as Image.Format, bytes)
	var small := Image.create_from_data(SMALL, SMALL, false, Image.FORMAT_RGBA8, small_data)
	if img == null or img.is_empty() or small == null or small.is_empty():
		return null
	_lock.lock()
	cache_hits += 1
	_lock.unlock()
	return _texture(img, small, [float(d.get("opaque", 0.0)), bool(d.get("black", false))], crisp)


## The bytes of a picture with all its mipmaps, `bpp` bytes a pixel.
static func _mip_bytes(w: int, h: int, bpp: int) -> int:
	var total := 0
	while true:
		total += w * h * bpp
		if w == 1 and h == 1:
			return total
		w = maxi(w >> 1, 1)
		h = maxi(h >> 1, 1)
	return total


## Keeps a picture made here in the disk cache (written whole under another name, then renamed).
static func _write_cache(digest: String, size: int, crisp: bool, img: Image, small: Image, counts: Array) -> void:
	_lock.lock()
	if not _cache_dir_made:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
		_cache_dir_made = true
	_lock.unlock()
	var path := _cache_path(digest, size, crisp)
	var raw := img.get_data()
	var payload := raw.compress(FileAccess.COMPRESSION_FASTLZ)
	var z := not payload.is_empty() and payload.size() < raw.size()
	if not z:
		payload = raw
	var tmp := "%s.tmp.%d" % [path, OS.get_thread_caller_id()]
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_var({"v": CACHE_VERSION, "k": digest, "w": img.get_width(), "h": img.get_height(), "fmt": int(img.get_format()),
		"raw_len": raw.size(), "z": z, "data": payload, "small": small.get_data(), "opaque": float(counts[0]),
		"black": bool(counts[1])}, false)
	var ok := f.get_error() == OK
	f.close()
	if not ok or DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(path)) != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
		return
	_lock.lock()
	cache_writes += 1
	_lock.unlock()


## Removes the oldest pictures of the disk cache past `limit` bytes, and half-written ones left by a
## Zenith that stopped (model_library.gd, once the models settle).
static func prune_cache(limit := CACHE_BYTES) -> void:
	var dir := ProjectSettings.globalize_path(CACHE_DIR)
	if not DirAccess.dir_exists_absolute(dir):
		return
	var files: Array = []
	var total := 0
	var hour_ago := int(Time.get_unix_time_from_system()) - 3600
	for name in DirAccess.get_files_at(dir):
		if not name.begins_with(CACHE_PREFIX):
			continue
		var path := dir.path_join(name)
		if name.contains(".tmp."):
			if FileAccess.get_modified_time(path) < hour_ago:
				DirAccess.remove_absolute(path)
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var length := f.get_length()
		f.close()
		files.append([FileAccess.get_modified_time(path), name, length])
		total += length
	files.sort()
	while total > limit and not files.is_empty():
		var oldest: Array = files.pop_front()
		DirAccess.remove_absolute(dir.path_join(str(oldest[1])))
		total -= int(oldest[2])


## [the share of pixels with alpha 255 (0-1), whether red, green and blue are 0 on every pixel] of an
## RGBA8 or RGB8 picture, counted natively: a byte count of 255 in RGBA less that in its RGB copy is the
## alpha bytes at 255.
static func _pixel_counts(img: Image) -> Array:
	var pixels := img.get_width() * img.get_height()
	if pixels <= 0:
		return [1.0, false]
	if img.get_format() != Image.FORMAT_RGBA8:
		var data := img.get_data()
		return [1.0, data.count(0) == data.size()]
	var rgb := img.duplicate() as Image
	rgb.convert(Image.FORMAT_RGB8)
	var rgb_data := rgb.get_data()
	var opaque := img.get_data().count(255) - rgb_data.count(255)
	return [clampf(float(opaque) / pixels, 0.0, 1.0), rgb_data.count(0) == rgb_data.size()]


static func _find(key: String) -> Texture2D:
	_lock.lock()
	var known: Texture2D = _shared.get(key)
	if known != null:
		shared_count += 1
	_lock.unlock()
	return known


static func _keep(key: String, tex: Texture2D) -> void:
	_lock.lock()
	_shared[key] = tex
	_lock.unlock()
