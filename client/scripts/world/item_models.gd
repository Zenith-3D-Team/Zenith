extends RefCounted
## Small 3D models for items on belts, on the ground and in inserter hands, from the model packs
## (model_packs.gd item_model_path: a pack's items/<item>.glb, by the packs' order and the item's
## choice). Zenith's own are Placeholders' (res://assets/models/packs/placeholders/items/, made by
## tools/models/items.py): a few dozen triangles with their colours (picked once from Factorio's
## item icon) in the vertices, so every item type shares one plain material and draws as one
## MultiMesh (item_cards.gd). A modeller's item is drawn the same way: by its vertex colours, or
## where it has none by each surface's material colour; one with a base-colour picture (every surface
## the same picture, and UVs) is drawn with it: one material per item model (material_for), shared by
## all its instances in the same MultiMeshes. `--item-pictures=off`: pictures left out (plain colours).
##
## A modeller's item model whose file's materials have more than that one picture draws (own_look and not
## _picture_enough: pictures differing between surfaces, glow, see-through parts) is drawn with those materials, one per surface, as its buildings keep theirs: base colour and its picture,
## roughness and metal, normal map, emission and alpha (dressed: item_own.gdshader, and on far belts
## belt_lane_model.gdshader's `own`), whatever its pack's shading and with no pack.json. The pictures are
## made ready as a building's are (model_textures.gd prepare: mipmaps, glTF's emission, opaque Alpha Blend
## turned solid). Only one base-colour picture on every surface was drawn before, the rest plain grey
## (Vasillo's science pack); `--item-materials=old` draws them so again.

const ItemShader := preload("res://shaders/item.gdshader")
const ItemOwnShader := preload("res://shaders/item_own.gdshader")
## The see-through (glTF BLEND) surfaces' twins of the own-look shaders: blended in the transparent pass
## (dressed), the item's other surfaces staying opaque.
const ItemOwnBlendShader := preload("res://shaders/item_own_blend.gdshader")
const LaneModelShader := preload("res://shaders/belt_lane_model.gdshader")
const LaneModelBlendShader := preload("res://shaders/belt_lane_model_blend.gdshader")
const BLEND_TWINS := {ItemOwnShader: ItemOwnBlendShader, LaneModelShader: LaneModelBlendShader}
const ModelTextures := preload("res://scripts/world/model_textures.gd")
const Probing := preload("res://scripts/debug/probing.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const Looks := preload("res://scripts/world/looks.gd")
## Placeholders' item models (the old res://assets/models/items/ moved there).
const DIR := "res://assets/models/packs/placeholders/items/"
## Item colours are picked from icons that are drawn lit already; under the sun they'd read
## brighter than the icon (compared side by side with the icon cards).
const EXPOSURE := 0.75

static var _cache := {}  # item name -> Mesh, or null when it has no model
static var _paths := {}  # item name -> the file its cached mesh was read from
static var _packs_version := -1  # ModelPacks.version the cache was checked against
## Bumped when some item's file changed with the packs (_follow_packs): item_cards.gd's kinds (items on
## the ground, near belts, in hands) and belt_lanes.gd's far chunks are made again with the new model.
static var generation := 0
## `--item-kinds-follow=off`: items already drawn keep the model they were first drawn with until a
## restart or a surface change (as before 0.2.2).
static var kinds_follow := not OS.get_cmdline_user_args().has("--item-kinds-follow=off")
static var _material: ShaderMaterial
## `--item-pictures=off`: a modeller's item model drawn by its colours alone, its picture left out.
static var pictures := not OS.get_cmdline_user_args().has("--item-pictures=off")
## The mesh metadata holding an item model's base-colour picture, and the material drawing it.
const PICTURE_META := &"item_picture"
const MATERIAL_META := &"item_material"
## A pictured item model from a pack whose pack.json says "shading": "pbr" (model_packs.gd shading()): its
## file's material, whose roughness, metal and normal pictures it is drawn with too (set_pbr).
const PBR_META := &"item_pbr"
## `--item-materials=old`: a modeller's item model drawn by its colours and one shared picture alone, as
## before 0.2.2 (own_look off).
static var own_materials := not OS.get_cmdline_user_args().has("--item-materials=old")
## `--item-glass=dither`: an own-look item's see-through surfaces dithered in the opaque pass (stippled, more
## see-through than the file says), as the first 0.2.2 drawing did, not blended (dressed).
static var glass_blend := not OS.get_cmdline_user_args().has("--item-glass=dither")
## `--item-lod=off`: keep multi-surface own-material items (transparent glass, multi-pass) at all distances
## instead of switching to a merged single-surface opaque mesh at mid/far range.
static var item_lod := not OS.get_cmdline_user_args().has("--item-lod=off")
## An item model drawn with its file's own materials (own_look): an Array, per surface,
## [its file's BaseMaterial3D, whether the surface's colours came with the file].
const SURFACES_META := &"item_surfaces"
## A dressed item model's copies: shader -> the mesh drawn with it (dressed).
const DRESSED_META := &"item_dressed"
## A multi-surface / see-through own-look item's merged single-surface opaque LOD mesh (simple_mesh).
const SIMPLE_META := &"item_simple"
const SIMPLE_FLAG_META := &"item_simple_mesh"
## Near+mid LOD dressed copies: [shader, lod_dist] -> Mesh (dressed_lod).
const DRESSED_LOD_META := &"item_dressed_lod"


## The item's model, or null (the item keeps its icon card). Read on the main thread, once per item (10-40 ms
## the first time an item came into view while walking; the probe's `gi_model_load`). They were read on
## worker threads (ResourceLoader.load_threaded_request), but those reads could deadlock against the main
## thread at start: with Factorio's own folder in reach, the menu's belts asked for four item models at once,
## their four worker threads stood on a lock while the main thread waited for a worker (Zenith
## froze before the main menu on most starts; read here, 5 starts in 5 came up).
## `variant`: which of the item's variants (ModelPacks.item_variant_count; `<item>-1.glb`, ...), 0 its
## first (the plain one when the pack has it), as everything without a place of its own draws it.
static func mesh_for(item: String, variant := 0) -> Mesh:
	if _packs_version != ModelPacks.version:
		_follow_packs()
	var key := item if variant <= 0 else "%s#%d" % [item, variant]
	if _cache.has(key):
		return _cache[key]
	var path := ModelPacks.item_model_path(item, maxi(variant, 0)) if item != "" else ""
	var mesh: Mesh = null
	if path != "":
		var t0 := Time.get_ticks_usec()
		mesh = read(path)
		Probing.add("gi_model_load", t0)
	_cache[key] = mesh
	_paths[key] = path
	return mesh


## How many variants item `item`'s model has (0 or 1: none to pick from); 0 with --model-variants=off
## (every item its first, as before: on the ground, on belts near and far, in hands).
static func variant_count(item: String) -> int:
	return ModelPacks.item_variant_count(item) if item != "" and variants_on else 0


## --model-variants=off: items keep their first model too (model_library.gd model_variants, for entities).
static var variants_on := not OS.get_cmdline_user_args().has("--model-variants=off")


## The packs' order, switches or choices changed: the items whose file changed are read again when
## next asked for, and `generation` is bumped so what was drawn with the old mesh is made again.
static func _follow_packs() -> void:
	_packs_version = ModelPacks.version
	var changed := false
	for key: String in _cache.keys():
		var at := key.rfind("#")
		var path := ModelPacks.item_model_path(key, 0) if at < 0 else ModelPacks.item_model_path(key.substr(0, at), int(key.substr(at + 1)))
		if path != str(_paths.get(key, "")):
			_cache.erase(key)
			_paths.erase(key)
			changed = true
	if changed:
		generation += 1


## The item models' generation, the packs looked at first if they changed since (an int compare
## otherwise: called every frame by every ItemCards owner and by belt_lanes.gd, unless kinds_follow
## is off).
static func current_generation() -> int:
	if _packs_version != ModelPacks.version:
		_follow_packs()
	return generation


## An item model's mesh from its file: Zenith's own imported scene (res://), else the .glb or .gltf
## read as it is, its colours made vertex colours where it has none. Null when it can't be read.
static func read(path: String) -> Mesh:
	if path.begins_with("res://"):
		return _mesh_of(load(path) as PackedScene) if ResourceLoader.exists(path) else null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		push_warning("[models] item model %s can't be read" % path)
		return null
	if own_materials and pictures:
		ModelTextures.prepare(path, state, ModelPacks.owns(path))
	var root := doc.generate_scene(state)
	if root == null:
		return null
	var mesh: Mesh = null
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var source := (node as MeshInstance3D).mesh
		mesh = _coloured(source)
		if mesh != null and own_materials and pictures and own_look(source) 				and not _picture_enough(source, ModelPacks.pbr(path)):
			var surfaces: Array = []
			for i in source.get_surface_count():
				surfaces.append([source.surface_get_material(i), source.surface_get_arrays(i)[Mesh.ARRAY_COLOR] != null])
			if mesh == source:
				mesh = source.duplicate() as Mesh
			mesh.set_meta(SURFACES_META, surfaces)
			if ModelPacks.pbr(path):
				mesh.set_meta(PBR_META, source.surface_get_material(0))
			break
		var tex: Texture2D = picture_of(source) if pictures else null
		if mesh != null and tex != null:
			if mesh == source:
				mesh = source.duplicate() as Mesh  # its own, for the picture kept with it
			mesh.set_meta(PICTURE_META, tex)
			if ModelPacks.pbr(path):
				mesh.set_meta(PBR_META, source.surface_get_material(0))
		break
	root.free()
	return mesh


## The base-colour picture a modeller's mesh is drawn with: the one every surface's material has
## (with UVs to read it by); null when it has none, or its surfaces have different ones or none.
static func picture_of(mesh: Mesh) -> Texture2D:
	if mesh == null or mesh.get_surface_count() == 0:
		return null
	var tex: Texture2D = null
	for i in mesh.get_surface_count():
		var mat := mesh.surface_get_material(i) as BaseMaterial3D
		if mat == null or mat.albedo_texture == null or mesh.surface_get_arrays(i)[Mesh.ARRAY_TEX_UV] == null:
			return null
		if tex != null and mat.albedo_texture != tex:
			return null
		tex = mat.albedo_texture
	return tex


## Whether a modeller's mesh has more to it than its colours: some surface's material with a picture, a
## glow or see-through parts. Drawn with its file's own materials then (SURFACES_META).
static func own_look(mesh: Mesh) -> bool:
	if mesh == null:
		return false
	for i in mesh.get_surface_count():
		var mat := mesh.surface_get_material(i) as BaseMaterial3D
		if mat == null:
			continue
		if mat.albedo_texture != null or mat.normal_texture != null or mat.roughness_texture != null \
				or mat.metallic_texture != null or mat.emission_enabled \
				or mat.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			return true
	return false


## Whether the one shared picture (picture_of, material_for) draws all a mesh's materials have: every
## surface the same picture, nothing glowing or see-through, and roughness, metal and normal pictures only
## where a "pbr" pack's set_pbr draws them. Such an item keeps that one material (as in 0.2.2).
static func _picture_enough(mesh: Mesh, pbr_pack: bool) -> bool:
	if picture_of(mesh) == null:
		return false
	for i in mesh.get_surface_count():
		var mat := mesh.surface_get_material(i) as BaseMaterial3D
		if mat.emission_enabled or mat.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			return false
		if not pbr_pack and (mat.normal_texture != null or mat.roughness_texture != null or mat.metallic_texture != null):
			return false
		if i > 0 and mat != mesh.surface_get_material(0):
			return false  # (another material: its own roughness and metal, which set_pbr doesn't carry)
	return true


## Whether an item model is drawn with its file's own materials (read() found own_look).
static func has_own(mesh: Mesh) -> bool:
	return mesh != null and mesh.has_meta(SURFACES_META)


## Whether an own-look item benefits from a single-surface opaque LOD (multiple surfaces or see-through glass).
static func needs_lod(mesh: Mesh) -> bool:
	if not has_own(mesh):
		return false
	if mesh.get_surface_count() > 1:
		return true
	var surfaces: Array = mesh.get_meta(SURFACES_META)
	for s in surfaces:
		if s is Array and (s as Array).size() > 0 and is_see_through((s as Array)[0] as BaseMaterial3D):
			return true
	return false


## Whether `mesh` is a merged single-surface LOD produced by simple_mesh() (linear glTF colours: exposure 1.0).
static func is_simple(mesh: Mesh) -> bool:
	return mesh != null and mesh.has_meta(SIMPLE_FLAG_META)


## Average linear RGB of a texture (4x4 sample), used once per multi-surface item to tint merged opaque LOD vertices.
static func _mean_texture_color(tex: Texture2D) -> Color:
	if tex == null:
		return Color.WHITE
	var img := tex.get_image()
	if img == null or img.is_empty():
		return Color.WHITE
	if img.is_compressed():
		img = img.duplicate() as Image
		if img.decompress() != OK:
			return Color.WHITE
	var w := img.get_width()
	var h := img.get_height()
	var sum := Color(0.0, 0.0, 0.0, 0.0)
	var weight := 0.0
	for gy in 4:
		var y := mini(h - 1, int((gy + 0.5) * h / 4.0))
		for gx in 4:
			var x := mini(w - 1, int((gx + 0.5) * w / 4.0))
			var c := img.get_pixel(x, y)
			if c.a > 0.05:
				var lin := c.srgb_to_linear()
				sum.r += lin.r * c.a
				sum.g += lin.g * c.a
				sum.b += lin.b * c.a
				weight += c.a
	if weight <= 0.0:
		return Color.WHITE
	return Color(sum.r / weight, sum.g / weight, sum.b / weight, 1.0)


## Merges a multi-surface or see-through own-look item into a single opaque surface with baked linear vertex
## colours (outer glass shells blend the colour of any enclosed liquid and drop its occluded triangles).
static func simple_mesh(mesh: Mesh) -> Mesh:
	if not needs_lod(mesh):
		return mesh
	if mesh.has_meta(SIMPLE_META):
		return mesh.get_meta(SIMPLE_META) as Mesh
	var surfaces: Array = mesh.get_meta(SURFACES_META)
	var n := mini(mesh.get_surface_count(), surfaces.size())
	var surf_arrays: Array = []
	var boxes: Array[AABB] = []
	var vols: Array[float] = []
	var glasses: Array[bool] = []
	var alphas: Array[float] = []
	var rep_cols: Array[Color] = []
	var vert_mults: Array[Color] = []
	var emits: Array[Color] = []
	for i in n:
		var arrays := mesh.surface_get_arrays(i)
		surf_arrays.append(arrays)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var box := AABB(verts[0], Vector3.ZERO) if not verts.is_empty() else AABB()
		for v in verts:
			box = box.expand(v)
		boxes.append(box)
		vols.append(box.get_volume())
		var s: Array = surfaces[i]
		var src := s[0] as BaseMaterial3D
		var file_cols := bool(s[1])
		var glass := is_see_through(src)
		glasses.append(glass)
		alphas.append(src.albedo_color.a if src != null else 1.0)
		var tex_col := _mean_texture_color(src.albedo_texture) if src != null and src.albedo_texture != null else Color.WHITE
		var mat_lin := src.albedo_color.srgb_to_linear() if src != null else Color.WHITE
		var rep := Color(mat_lin.r * tex_col.r, mat_lin.g * tex_col.g, mat_lin.b * tex_col.b, 1.0)
		rep_cols.append(rep)
		vert_mults.append(rep if file_cols else tex_col)
		var em := Color(0.0, 0.0, 0.0, 0.0)
		if src != null and src.emission_enabled:
			var elin := src.emission.srgb_to_linear()
			var gain := minf(src.emission_energy_multiplier * 0.35, 0.75)
			em = Color(elin.r * gain, elin.g * gain, elin.b * gain, 0.0)
		emits.append(em)
	var skip: Array[bool] = []
	var override_col: Array = []
	skip.resize(n)
	override_col.resize(n)
	for i in n:
		if not glasses[i]:
			continue
		var best_j := -1
		var best_vol := -1.0
		var outer := boxes[i].grow(0.015)
		for j in n:
			if j == i or skip[j]:
				continue
			if vols[j] < vols[i] * 0.95 and outer.encloses(boxes[j]) and vols[j] > best_vol:
				best_j = j
				best_vol = vols[j]
		if best_j >= 0:
			var inner_c := Color(rep_cols[best_j].r + emits[best_j].r, rep_cols[best_j].g + emits[best_j].g,
				rep_cols[best_j].b + emits[best_j].b, 1.0)
			var outer_c := Color(rep_cols[i].r + emits[i].r, rep_cols[i].g + emits[i].g, rep_cols[i].b + emits[i].b, 1.0)
			var blended := inner_c.lerp(outer_c, clampf(alphas[i], 0.0, 0.85))
			blended.a = 1.0
			override_col[i] = blended
			skip[best_j] = true
	var out_verts := PackedVector3Array()
	var out_norms := PackedVector3Array()
	var out_cols := PackedColorArray()
	var out_idx := PackedInt32Array()
	for i in n:
		if skip[i]:
			continue
		var arrays: Array = surf_arrays[i]
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			continue
		var base_v := out_verts.size()
		out_verts.append_array(verts)
		var norms: Variant = arrays[Mesh.ARRAY_NORMAL]
		if norms is PackedVector3Array and (norms as PackedVector3Array).size() == verts.size():
			out_norms.append_array(norms as PackedVector3Array)
		else:
			var up := PackedVector3Array()
			up.resize(verts.size())
			up.fill(Vector3.UP)
			out_norms.append_array(up)
		var vcols: Variant = arrays[Mesh.ARRAY_COLOR]
		var ov: Variant = override_col[i]
		if ov is Color:
			var fill := PackedColorArray()
			fill.resize(verts.size())
			fill.fill(ov as Color)
			out_cols.append_array(fill)
		else:
			var mult := vert_mults[i]
			var em := emits[i]
			var has_vc := vcols is PackedColorArray and (vcols as PackedColorArray).size() == verts.size()
			var src_vc: PackedColorArray = vcols as PackedColorArray if has_vc else PackedColorArray()
			var cols := PackedColorArray()
			cols.resize(verts.size())
			for k in verts.size():
				var vc := src_vc[k] if has_vc else Color.WHITE
				cols[k] = Color(vc.r * mult.r + em.r, vc.g * mult.g + em.g, vc.b * mult.b + em.b, 1.0)
			out_cols.append_array(cols)
		var idx: Variant = arrays[Mesh.ARRAY_INDEX]
		if idx is PackedInt32Array and not (idx as PackedInt32Array).is_empty():
			for t in (idx as PackedInt32Array):
				out_idx.append(base_v + t)
		else:
			for k in verts.size():
				out_idx.append(base_v + k)
	if out_verts.is_empty():
		return mesh
	var merged := []
	merged.resize(Mesh.ARRAY_MAX)
	merged[Mesh.ARRAY_VERTEX] = out_verts
	merged[Mesh.ARRAY_NORMAL] = out_norms
	merged[Mesh.ARRAY_COLOR] = out_cols
	merged[Mesh.ARRAY_INDEX] = out_idx
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, merged)
	out.set_meta(SIMPLE_FLAG_META, true)
	mesh.set_meta(SIMPLE_META, out)
	return out


## A multi-surface own-look item mesh with distance-banded LOD surfaces: full own-material surfaces within
## `lod_dist` tiles of the camera, and one merged opaque simple_mesh() surface at/beyond `lod_dist`.
static func dressed_lod(mesh: Mesh, shader: Shader, lod_dist: float) -> Mesh:
	if not item_lod or not needs_lod(mesh) or lod_dist <= 0.0:
		return dressed(mesh, shader)
	var copies: Dictionary = mesh.get_meta(DRESSED_LOD_META, {})
	var key := [shader, lod_dist]
	if copies.has(key):
		return copies[key]
	var detailed := dressed(mesh, shader)
	var simple := simple_mesh(mesh)
	if simple == mesh or simple.get_surface_count() == 0:
		return detailed
	var out := ArrayMesh.new()
	var dist_sq := lod_dist * lod_dist
	for i in detailed.get_surface_count():
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, detailed.surface_get_arrays(i))
		var m := detailed.surface_get_material(i) as ShaderMaterial
		if m != null:
			var dup := m.duplicate() as ShaderMaterial
			dup.set_shader_parameter("lod_max_sq", dist_sq)
			out.surface_set_material(i, dup)
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, simple.surface_get_arrays(0))
	var smat := ShaderMaterial.new()
	smat.shader = Looks.shader_for(ItemShader)
	smat.set_shader_parameter("exposure", 1.0)
	smat.set_shader_parameter("lod_min_sq", dist_sq)
	out.surface_set_material(out.get_surface_count() - 1, smat)
	copies[key] = out
	mesh.set_meta(DRESSED_LOD_META, copies)
	return out


## An own-look item model (has_own) as drawn with `shader` (item_own.gdshader for the loose items,
## belt_lane_model.gdshader for far belts): a copy whose every surface has a material of `shader` with
## that surface's file material (own_material); made once per shader and kept with the mesh, so every
## instance shares it. The mesh itself for any other.
static func dressed(mesh: Mesh, shader: Shader) -> Mesh:
	if not has_own(mesh):
		return mesh
	var copies: Dictionary = mesh.get_meta(DRESSED_META, {})
	if copies.has(shader):
		return copies[shader]
	var out := mesh.duplicate() as Mesh
	var surfaces: Array = mesh.get_meta(SURFACES_META)
	var blend: Shader = BLEND_TWINS.get(shader) if glass_blend else null
	var see_through: Array[int] = []
	for i in mini(out.get_surface_count(), surfaces.size()):
		var s: Array = surfaces[i]
		var src := s[0] as BaseMaterial3D
		var glass := blend != null and is_see_through(src)
		out.surface_set_material(i, own_material(src, bool(s[1]), Looks.shader_for(blend if glass else shader), pbr_material(mesh) != null))
		if glass:
			see_through.append(i)
	_order_glass(out, see_through)
	out.remove_meta(DRESSED_META)
	out.remove_meta(DRESSED_LOD_META)
	out.remove_meta(SIMPLE_META)
	copies[shader] = out
	mesh.set_meta(DRESSED_META, copies)
	return out


## Whether a file material is see-through by blending (glTF BLEND), not opaque or cut out.
static func is_see_through(src: BaseMaterial3D) -> bool:
	return src != null and not (src.transparency in [BaseMaterial3D.TRANSPARENCY_DISABLED,
		BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR])


## The order an item's see-through surfaces blend in: the surfaces of one instance sit at the same depth in
## Godot's transparent sort, so a lower render_priority draws first. The smallest (a liquid inside a flask)
## first, the outermost (the glass) last at 0, the priority buildings' glass has; one alone stays at 0.
static func _order_glass(mesh: Mesh, surfaces: Array[int]) -> void:
	if surfaces.size() < 2:
		return
	var sizes := {}
	for i in surfaces:
		var verts: PackedVector3Array = mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX]
		var box := AABB(verts[0], Vector3.ZERO) if not verts.is_empty() else AABB()
		for v in verts:
			box = box.expand(v)
		sizes[i] = box.get_volume()
	surfaces.sort_custom(func(a: int, b: int) -> bool: return float(sizes[a]) > float(sizes[b]))
	for rank in surfaces.size():
		(mesh.surface_get_material(surfaces[rank]) as ShaderMaterial).render_priority = -mini(rank, 100)


## A dressed mesh's surface materials (to set their shader parameters).
static func surface_materials(mesh: Mesh) -> Array:
	var out: Array = []
	for i in mesh.get_surface_count():
		var m := mesh.surface_get_material(i) as ShaderMaterial
		if m != null:
			out.append(m)
	return out


## A ShaderMaterial of `shader` drawing one surface with its file material `src`: its colour (on top of
## vertex colours that came with the file; read() put it in the vertices otherwise), picture, roughness
## and metal with their picture, normal map, emission and alpha. A "pbr" pack's look on top (`pbr`).
static func own_material(src: BaseMaterial3D, file_colours: bool, shader: Shader, pbr := false) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	m.set_shader_parameter("own", true)
	m.set_shader_parameter("exposure", 1.0)
	if src == null:
		return m
	# (Colour and alpha both in the vertices already when read() put them there.)
	m.set_shader_parameter("color", src.albedo_color if file_colours else Color.WHITE)
	if src.albedo_texture != null:
		m.set_shader_parameter("picture", src.albedo_texture)
		m.set_shader_parameter("use_picture", true)
	m.set_shader_parameter("pbr_roughness", src.roughness)
	m.set_shader_parameter("pbr_metallic", src.metallic)
	# Godot's glTF reader puts the metallic-roughness picture in both slots (B metal, G roughness).
	var orm: Texture2D = src.metallic_texture if src.metallic_texture != null else src.roughness_texture
	if orm != null:
		m.set_shader_parameter("orm_picture", orm)
		m.set_shader_parameter("use_orm", true)
	if src.normal_enabled and src.normal_texture != null and src.normal_texture != src.albedo_texture:
		m.set_shader_parameter("normal_picture", src.normal_texture)
		m.set_shader_parameter("normal_scale", src.normal_scale)
		m.set_shader_parameter("use_normal", true)
	if src.emission_enabled:
		m.set_shader_parameter("emission", src.emission)
		m.set_shader_parameter("emission_energy", src.emission_energy_multiplier)
		if src.emission_texture != null:
			m.set_shader_parameter("emission_picture", src.emission_texture)
			m.set_shader_parameter("use_emission_picture", true)
	match src.transparency:
		BaseMaterial3D.TRANSPARENCY_DISABLED:
			pass
		BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			m.set_shader_parameter("alpha_mode", 1)
			m.set_shader_parameter("alpha_clip", src.alpha_scissor_threshold)
		_:
			m.set_shader_parameter("alpha_mode", 2)
	m.set_shader_parameter("pbr", pbr)
	return m


## An own-look item model (has_own) for one model on its own (the Model packs preview, the menu's
## inserter): a copy with its file's materials as Godot draws them, metal at the world's share
## (plain_material's "pbr" path); drawn with no material_override (plain_material gives null). The mesh
## itself for any other.
static func preview_mesh(mesh: Mesh) -> Mesh:
	if not has_own(mesh):
		return mesh
	var out := mesh.duplicate() as Mesh
	out.remove_meta(DRESSED_META)
	out.remove_meta(DRESSED_LOD_META)
	out.remove_meta(SIMPLE_META)
	var surfaces: Array = mesh.get_meta(SURFACES_META)
	var share := Looks.pbr_metal_arg(OS.get_cmdline_user_args())
	for i in mini(out.get_surface_count(), surfaces.size()):
		var s: Array = surfaces[i]
		var src := s[0] as BaseMaterial3D
		if src == null:
			continue
		var own := src.duplicate() as BaseMaterial3D
		own.metallic = src.metallic * (share if share >= 0.0 else Looks.PBR_METAL)
		own.vertex_color_use_as_albedo = bool(s[1]) and src.vertex_color_use_as_albedo
		out.surface_set_material(i, own)
	return out


## An item model's picture (read() kept it), null for none.
static func picture(mesh: Mesh) -> Texture2D:
	return mesh.get_meta(PICTURE_META) as Texture2D if mesh != null and mesh.has_meta(PICTURE_META) else null


## A mesh whose surfaces all carry vertex colours (item.gdshader draws them): a surface without
## them takes its material's albedo colour.
static func _coloured(mesh: Mesh) -> Mesh:
	if mesh == null:
		return null
	var all_have := true
	for i in mesh.get_surface_count():
		if mesh.surface_get_arrays(i)[Mesh.ARRAY_COLOR] == null:
			all_have = false
	if all_have:
		return mesh
	var out := ArrayMesh.new()
	for i in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(i)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if arrays[Mesh.ARRAY_COLOR] == null:
			var colour := Color.WHITE
			var mat := mesh.surface_get_material(i)
			if mat is BaseMaterial3D:
				colour = (mat as BaseMaterial3D).albedo_color
			var colours := PackedColorArray()
			colours.resize(verts.size())
			colours.fill(colour.srgb_to_linear())
			arrays[Mesh.ARRAY_COLOR] = colours
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return out


## Whether mesh_for(item) answers at once: always now (it reads the model there and then, see above).
## Kept for its callers, which leave an item its icon card while this says no.
static func ready(item: String) -> bool:
	mesh_for(item)
	return true



static func _mesh_of(packed: PackedScene) -> Mesh:
	if packed == null:
		return null
	var mesh: Mesh = null
	var root := packed.instantiate()
	for node in root.find_children("*", "MeshInstance3D", true, false):
		mesh = (node as MeshInstance3D).mesh
		break
	root.free()
	return mesh


## One material for every item model: the vertex colours are the albedo (linear, as glTF
## stores them).
static func material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = Looks.shader_for(ItemShader)
		_material.set_shader_parameter("exposure", EXPOSURE)
	return _material


## The material an item model is drawn with: its own (one per model, kept with the mesh and shared
## by every instance of it) when it has a picture, drawn as the modeller made it (no exposure: the
## picture is a colour, not an icon lit already); else the one material every item shares.
static func material_for(mesh: Mesh) -> ShaderMaterial:
	var tex := picture(mesh)
	if tex == null:
		return material()
	if mesh.has_meta(MATERIAL_META):
		return mesh.get_meta(MATERIAL_META) as ShaderMaterial
	var m := ShaderMaterial.new()
	m.shader = Looks.shader_for(ItemShader)
	m.set_shader_parameter("exposure", 1.0)
	m.set_shader_parameter("picture", tex)
	m.set_shader_parameter("use_picture", true)
	set_pbr(m, mesh)
	mesh.set_meta(MATERIAL_META, m)
	return m


## The file's material of a "pbr" pack's pictured item (PBR_META), null for any other.
static func pbr_material(mesh: Mesh) -> BaseMaterial3D:
	return mesh.get_meta(PBR_META) as BaseMaterial3D if mesh != null and mesh.has_meta(PBR_META) else null


## A "pbr" pack's pictured item drawn by item_pbr.gdshaderinc (item.gdshader, belt_lane_model.gdshader):
## its file's roughness, metal and normal pictures and factors. Nothing for any other item.
static func set_pbr(m: ShaderMaterial, mesh: Mesh) -> void:
	var src := pbr_material(mesh)
	if src == null:
		return
	m.set_shader_parameter("pbr", true)
	m.set_shader_parameter("pbr_roughness", src.roughness)
	m.set_shader_parameter("pbr_metallic", src.metallic)
	# Godot's glTF reader puts the metallic-roughness picture in both slots (B metal, G roughness).
	var orm: Texture2D = src.metallic_texture if src.metallic_texture != null else src.roughness_texture
	if orm != null:
		m.set_shader_parameter("orm_picture", orm)
		m.set_shader_parameter("use_orm", true)
	if src.normal_enabled and src.normal_texture != null:
		m.set_shader_parameter("normal_picture", src.normal_texture)
		m.set_shader_parameter("normal_scale", src.normal_scale)
		m.set_shader_parameter("use_normal", true)


## A StandardMaterial3D drawing an item model as the world does, for one model on its own (the
## Model packs preview, the menu's inserter): its vertex colours, and its picture when it has one.
static func plain_material(mesh: Mesh) -> StandardMaterial3D:
	if has_own(mesh):
		return null  # preview_mesh's surfaces carry their own
	var src := pbr_material(mesh) if Looks.pack_shading() else null
	if src is StandardMaterial3D:
		# A "pbr" pack's item: its file's own material, as Godot draws it, its metal at the share the world
		# draws it at (looks.gd PBR_METAL, --pbr-metal), reflecting the preview's own sky. Its colour is that
		# material's (no vertex colours on top).
		var own := (src as StandardMaterial3D).duplicate() as StandardMaterial3D
		var share := Looks.pbr_metal_arg(OS.get_cmdline_user_args())
		own.metallic = src.metallic * (share if share >= 0.0 else Looks.PBR_METAL)
		own.vertex_color_use_as_albedo = false
		return own
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	var tex := picture(mesh)
	if tex != null:
		m.albedo_texture = tex
	else:
		m.albedo_color = Color(EXPOSURE, EXPOSURE, EXPOSURE)
	m.roughness = 0.8
	return m


## A plain block for an item with neither a model nor an icon.
static func block_material(color: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = Looks.shader_for(ItemShader)
	m.set_shader_parameter("color", color)
	return m
