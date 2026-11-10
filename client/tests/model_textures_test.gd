extends SceneTree
## A model's .glb that asks for nearest filtering (Blender's Image Texture set to Closest) is drawn
## from the shader's crisp sampler; one that asks for linear stays as it was (model_textures.gd).
##   godot --headless --path client -s res://tests/model_textures_test.gd

const ModelTextures := preload("res://scripts/world/model_textures.gd")
const SOURCE := "res://assets/models/fue5/wooden-chest.glb"

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _init() -> void:
	for mag in [9729, 9728]:
		var path := "user://model_textures_test_%d.glb" % mag
		check(_rewrite(ProjectSettings.globalize_path(SOURCE), ProjectSettings.globalize_path(path), mag), "rewrote %s" % SOURCE)
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		check(doc.append_from_file(ProjectSettings.globalize_path(path), state) == OK, "read the rewritten .glb")
		ModelTextures.prepare(ProjectSettings.globalize_path(path), state)
		var crisp := 0
		var textured := 0
		for m in state.get_materials():
			var base := m as BaseMaterial3D
			if base != null and base.albedo_texture != null:
				textured += 1
				if base.albedo_texture.has_meta(ModelTextures.NEAREST_META):
					crisp += 1
		check(textured > 0, "the chest has a base colour texture")
		if mag == 9728:
			check(crisp == textured, "NEAREST: every base colour texture marked crisp (%d of %d)" % [crisp, textured])
		else:
			check(crisp == 0, "LINEAR: no texture marked crisp (%d)" % crisp)
	print("MODEL TEXTURES FAILS: %d" % fails)
	quit(1 if fails > 0 else 0)


## The .glb at `src` with every sampler's magFilter and minFilter set to `mag`, written to `dst`.
func _rewrite(src: String, dst: String, mag: int) -> bool:
	var f := FileAccess.open(src, FileAccess.READ)
	if f == null or f.get_32() != 0x46546C67:
		return false
	var version := f.get_32()
	f.get_32()
	var json_len := f.get_32()
	f.get_32()
	var doc = JSON.parse_string(f.get_buffer(json_len).get_string_from_utf8())
	var rest := f.get_buffer(f.get_length() - f.get_position())
	if not doc is Dictionary:
		return false
	var samplers: Array = doc.get("samplers", [])
	if samplers.is_empty():
		samplers.append({})
		doc["samplers"] = samplers
		for t in doc.get("textures", []):
			t["sampler"] = 0
	for s in samplers:
		s["magFilter"] = mag
		s["minFilter"] = 9984 if mag == 9728 else 9987
	var text := JSON.stringify(doc).to_utf8_buffer()
	while text.size() % 4 != 0:
		text.append(0x20)
	var out := FileAccess.open(dst, FileAccess.WRITE)
	out.store_32(0x46546C67)
	out.store_32(version)
	out.store_32(12 + 8 + text.size() + rest.size())
	out.store_32(text.size())
	out.store_32(0x4E4F534A)
	out.store_buffer(text)
	out.store_buffer(rest)
	out.close()
	return true
