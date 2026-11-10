extends RefCounted
## Textures a model brings in its .glb (base colour, and metallic-roughness), made ready for the
## model shader on the worker thread that reads the model (model_library.gd Load): Godot's glTF
## reader makes them without mipmaps, which shimmer on a model a few tiles away, so each picture is
## decoded again from the file's own bytes, mipmapped and put back on its material. A small copy
## (SMALL px) rides along as meta, for far_chunks.gd to colour a merged far chunk's vertices from.
## Models without textures pass through untouched. A texture whose glTF sampler says NEAREST
## (Blender's Image Texture node set to Closest, which its exporter writes so) is marked
## NEAREST_META, and the model shader draws it crisp, texel by texel, still mipmapped far away
## (modeller's request: hand-painted low-resolution textures read better unblended).

## Meta on a Texture2D: a SMALL x SMALL Image of it (RGBA8, sRGB as stored).
const SMALL_META := &"f3d_small"
const SMALL := 64
## Meta on a Texture2D: true when its glTF sampler filters NEAREST.
const NEAREST_META := &"f3d_nearest"
const GL_NEAREST := 9728
const GL_NEAREST_MIPMAP_NEAREST := 9984
const GL_NEAREST_MIPMAP_LINEAR := 9986


## Mipmapped copies of the base colour and roughness textures of every material in `state`, read
## from the .glb at `path`. Worker-thread safe (Image and ImageTexture work).
static func prepare(path: String, state: GLTFState) -> void:
	var materials := state.get_materials()
	if materials.is_empty():
		return
	var wanted := false
	for m in materials:
		var base := m as BaseMaterial3D
		if base != null and (base.albedo_texture != null or base.roughness_texture != null):
			wanted = true
	if not wanted:
		return
	var nearest := {}  # image index -> true when a texture of it samples NEAREST
	var images := _images(path, nearest)
	var done := {}  # original texture -> mipmapped one
	for m in materials:
		var base := m as BaseMaterial3D
		if base == null:
			continue
		for param in [BaseMaterial3D.TEXTURE_ALBEDO, BaseMaterial3D.TEXTURE_ROUGHNESS, BaseMaterial3D.TEXTURE_METALLIC]:
			var tex := base.get_texture(param)
			if tex == null:
				continue
			if not done.has(tex):
				done[tex] = _mipmapped(tex, state, images, nearest)
			base.set_texture(param, done[tex])


## Image index -> the picture's bytes decoded, from the .glb's JSON and binary chunk; `nearest` gets
## the image indices a NEAREST sampler draws.
static func _images(path: String, nearest: Dictionary) -> Dictionary:
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
		var bytes := bin.slice(start, start + int(view["byteLength"]))
		var img := Image.new()
		var mime := str(pic.get("mimeType", ""))
		var err := img.load_jpg_from_buffer(bytes) if mime == "image/jpeg" else img.load_png_from_buffer(bytes)
		if err == OK:
			out[src] = img
	return out


static func _mipmapped(tex: Texture2D, state: GLTFState, images: Dictionary, nearest: Dictionary) -> Texture2D:
	# GLTFState keeps the file's images in its order: this texture's index there is the file's.
	var img: Image = null
	var crisp := false
	var made := state.get_images()
	for i in made.size():
		if made[i] == tex and images.has(i):
			img = images[i]
			crisp = nearest.has(i)
	if img == null:
		return tex
	if img.get_format() != Image.FORMAT_RGBA8 and img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGBA8)
	var small := img.duplicate() as Image
	small.convert(Image.FORMAT_RGBA8)
	small.resize(SMALL, SMALL, Image.INTERPOLATE_BILINEAR)
	img.generate_mipmaps()
	var out := ImageTexture.create_from_image(img)
	out.set_meta(SMALL_META, small)
	if crisp:
		out.set_meta(NEAREST_META, true)
	return out
