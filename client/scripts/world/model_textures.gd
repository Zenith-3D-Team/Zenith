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
static var share := not ("--share-textures=off" in OS.get_cmdline_user_args())
## --opaque-blend=off: Alpha Blend materials stay see-through whatever their picture (for comparing).
static var opaque_blend := not ("--opaque-blend=off" in OS.get_cmdline_user_args())
## --belt-surface-blend=on: a belt surface with a see-through picture stays Alpha Blend, as before 0.2.2.
static var belt_clip := not ("--belt-surface-blend=on" in OS.get_cmdline_user_args())
## The cutoff a blended belt surface is cut out at.
const CLIP_BELT := 0.5
## --blend-clip=off: a modeller's nearly opaque Alpha Blend material stays blended, as before 0.2.2.
static var blend_clip := not ("--blend-clip=off" in OS.get_cmdline_user_args())
## The share of opaque pixels from which a modeller's blended material is drawn cut out (at CLIP_BELT).
const CLIP_SHARE := 0.95
## --emission-strict=off: any emission picture glows, factor or not, as before 0.2.2 (Godot's reading).
static var emission_strict := not ("--emission-strict=off" in OS.get_cmdline_user_args())
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
static func prepare(path: String, state: GLTFState, modeller := false) -> void:
	var materials := state.get_materials()
	if materials.is_empty():
		return
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
		return
	var nearest := {}  # image index -> true when a texture of it samples NEAREST
	var factors: Array = []  # per material of the file: its emissiveFactor, or null
	var images := _images(path, nearest, factors, wanted)
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
static func _images(path: String, nearest: Dictionary, factors: Array, with_pictures := true) -> Dictionary:
	var out := {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_32() != 0x46546C67:
		return out
	f.get_32()
	f.get_32()
	var json_len := f.get_32()
	f.get_32()
	var doc = JSON.parse_string(f.get_buffer(json_len).get_string_from_utf8())
	if not doc is Dictionary:
		return out
	for m in doc.get("materials", []):
		factors.append((m as Dictionary).get("emissiveFactor") if m is Dictionary else null)
	if not with_pictures:
		return out
	var bin := PackedByteArray()
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
		var start := int(view.get("byteOffset", 0))
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
	var crisp := nearest.has(src)
	var pic: Array = images[src]
	var bytes: PackedByteArray = pic[0]
	var file_key := ""
	if share:
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_MD5)
		ctx.update(bytes)
		file_key = "%s %d %s" % [ctx.finish().hex_encode(), bytes.size(), crisp]
		var known := _find(file_key)
		if known != null:
			return known
	var img := _decode(pic)
	if img == null:
		return tex
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
	var opaque: bool = counts[0] >= 1.0
	var small := img.duplicate() as Image
	small.convert(Image.FORMAT_RGBA8)
	small.resize(SMALL, SMALL, Image.INTERPOLATE_BILINEAR)
	img.generate_mipmaps()
	var out := ImageTexture.create_from_image(img)
	out.set_meta(SMALL_META, small)
	out.set_meta(OPAQUE_META, opaque)
	out.set_meta(OPAQUE_SHARE_META, counts[0])
	out.set_meta(BLACK_META, counts[1])
	if crisp:
		out.set_meta(NEAREST_META, true)
	if share:
		# Another worker may have made the same picture meanwhile: the first one kept is everyone's.
		_lock.lock()
		var first: Variant = _shared.get(pixel_key)
		if first == null:
			_shared[pixel_key] = out
			made_count += 1
		else:
			out = first
			shared_count += 1
		_shared[file_key] = out
		_lock.unlock()
	return out


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
