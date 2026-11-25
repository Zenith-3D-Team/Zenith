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
const ItemOwnCutShader := preload("res://shaders/item_own_cut.gdshader")
## The see-through (glTF BLEND) surfaces' twins of the own-look shaders: blended in the transparent pass
## (dressed), the item's other surfaces staying opaque.
const ItemOwnBlendShader := preload("res://shaders/item_own_blend.gdshader")
const LaneModelShader := preload("res://shaders/belt_lane_model.gdshader")
const LaneModelCutShader := preload("res://shaders/belt_lane_model_cut.gdshader")
const LaneModelBlendShader := preload("res://shaders/belt_lane_model_blend.gdshader")
const ItemShadowShader := preload("res://shaders/item_shadow.gdshader")
const BLEND_TWINS := {ItemOwnShader: ItemOwnBlendShader, LaneModelShader: LaneModelBlendShader, LaneModelCutShader: LaneModelBlendShader}
const CUT_TWINS := {ItemOwnShader: ItemOwnCutShader, LaneModelShader: LaneModelCutShader, LaneModelCutShader: LaneModelCutShader}
const ModelTextures := preload("res://scripts/world/model_textures.gd")
const Probing := preload("res://scripts/debug/probing.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const Looks := preload("res://scripts/world/looks.gd")
const Switches := preload("res://scripts/switches.gd")
## Placeholders' item models (the old res://assets/models/items/ moved there).
const DIR := "res://assets/models/packs/placeholders/items/"
## Item colours are picked from icons that are drawn lit already; under the sun they'd read
## brighter than the icon (compared side by side with the icon cards).
const EXPOSURE := 0.75

static var _cache := {}  # item name -> Mesh, or null when it has no model
static var _paths := {}  # item name -> the file its cached mesh was read from
static var _pbrs := {}  # item name -> whether its cached mesh was built with PBR shading
static var _packs_version := -1  # ModelPacks.version the cache was checked against
## Bumped when some item's file changed with the packs (_follow_packs): item_cards.gd's kinds (items on
## the ground, near belts, in hands) and belt_lanes.gd's far chunks are made again with the new model.
static var generation := 0
## `--item-kinds-follow=off`: items already drawn keep the model they were first drawn with until a
## restart or a surface change (as before 0.2.2).
static var kinds_follow := Switches.on("--item-kinds-follow")
static var _material: ShaderMaterial
## `--item-pictures=off`: a modeller's item model drawn by its colours alone, its picture left out.
static var pictures := Switches.on("--item-pictures")
## The mesh metadata holding an item model's base-colour picture, and the material drawing it.
const PICTURE_META := &"item_picture"
const MATERIAL_META := &"item_material"
## A pictured item model from a pack whose pack.json says "shading": "pbr" (model_packs.gd shading()): its
## file's material, whose roughness, metal and normal pictures it is drawn with too (set_pbr).
const PBR_META := &"item_pbr"
## `--item-materials=old`: a modeller's item model drawn by its colours and one shared picture alone, as
## before 0.2.2 (own_look off).
static var own_materials := not Switches.has("--item-materials=old")
## `--item-glass=dither`: an own-look item's see-through surfaces dithered in the opaque pass (stippled, more
## see-through than the file says), as the first 0.2.2 drawing did, not blended (dressed).
static var glass_blend := not Switches.has("--item-glass=dither")
## `--item-lod=off`: keep multi-surface own-material items (transparent glass, multi-pass) at all distances
## instead of switching to a merged single-surface opaque mesh at mid/far range.
static var item_lod := Switches.on("--item-lod")
## `--item-geom-lod=off`: disable automatic ImporterMesh geometric LOD1 simplification for items.
static var item_geom_lod := Switches.on("--item-geom-lod")
## `--item-lod2=icon`: use 2D Factorio icon cards at LOD2 and past --far-belt-3d-dist instead of
## 10-triangle model-matched proxy boxes (`"proxy"`, default).
static var lod2_mode := _lod2_mode_arg()
## `--item-tangents=off`: compute normal-map tangent frames from screen derivatives instead of precomputed vertex tangents.
static var item_tangents := Switches.on("--item-tangents")
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
## Precomputed MikkTSpace tangents flag, geometric LOD1, LOD1 material, LOD2 proxy, LOD stats, and AABB shadow box metadata.
const TANGENTS_META := &"item_tangents"
const LOD1_META := &"item_lod1"
const LOD1_NO_UV_META := &"item_lod1_no_uv"
const LOD1_MAT_META := &"item_lod1_mat"
const LOD2_META := &"item_lod2"
const LOD2_MAT_META := &"item_lod2_mat"
const LOD2_FLAG_META := &"item_lod2_mesh"
const LOD_STATS_META := &"item_lod_stats"
const SHADOW_BOX_META := &"item_shadow_box"
## Meta on a mesh holding its surfaces' arrays on the CPU, the same name and meaning as ModelLods.ARRAYS_META
## (model_library.gd keeps them on buildings): Mesh.surface_get_arrays and ArrayMesh.duplicate() read a
## surface back from the RenderingServer, which waits for the render thread when it runs on its own (a frame or
## more each time). Kept when a mesh is made here or read from its file, else read once and kept (_kept).
const ARRAYS_META := &"f3d_arrays"
## A Texture2D's picture read back once (_readable_image): get_image() is a renderer read too.
const IMAGE_META := &"f3d_cpu_image"
## `--render-reads=old`: item models read their surfaces and pictures from the renderer each time, as before.
static var cpu_arrays := not Switches.has("--render-reads=old")


## Every surface's arrays of `mesh`, from its CPU copy (ARRAYS_META), read from the renderer and kept the first
## time when it has none. Shared: read-only (use _arrays for a copy to change).
static func _kept(mesh: Mesh) -> Array:
	if mesh.has_meta(ARRAYS_META):
		var kept: Array = mesh.get_meta(ARRAYS_META)
		if kept.size() == mesh.get_surface_count():
			return kept
	var out: Array = []
	for i in mesh.get_surface_count():
		out.append(mesh.surface_get_arrays(i))
	if cpu_arrays:
		mesh.set_meta(ARRAYS_META, out)
	return out


## Surface `i`'s arrays, read-only (shared with the mesh's CPU copy).
static func _peek(mesh: Mesh, i: int) -> Array:
	if not cpu_arrays:
		return mesh.surface_get_arrays(i)
	return _kept(mesh)[i]


## Surface `i`'s arrays, a deep copy safe to change.
static func _arrays(mesh: Mesh, i: int) -> Array:
	if not cpu_arrays:
		return mesh.surface_get_arrays(i)
	return (_kept(mesh)[i] as Array).duplicate(true)


## Adds a surface to `out` and keeps its arrays with it (ARRAYS_META), so nothing reads it back later.
static func _add(out: ArrayMesh, arrays: Array, flags := -1) -> void:
	if flags < 0:
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	else:
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
	if not cpu_arrays:
		return
	var kept: Array = out.get_meta(ARRAYS_META, [])
	if kept.size() != out.get_surface_count() - 1:
		out.remove_meta(ARRAYS_META)
		return
	kept.append(arrays)
	out.set_meta(ARRAYS_META, kept)


## A copy of `mesh` as duplicate() makes it (surfaces, materials, names, metadata), built from its CPU copy:
## ArrayMesh.duplicate() reads every surface back from the renderer.
static func copy_mesh(mesh: Mesh) -> Mesh:
	# Only from a copy kept already (made here, or read by _read_gltf): an imported scene's mesh may carry
	# the importer's LODs, which only duplicate() keeps.
	if not cpu_arrays or not (mesh is ArrayMesh) or not mesh.has_meta(ARRAYS_META):
		return mesh.duplicate() as Mesh
	var src := mesh as ArrayMesh
	var kept := _kept(src)
	var out := ArrayMesh.new()
	out.resource_name = src.resource_name
	for key: StringName in src.get_meta_list():
		if key != ARRAYS_META:
			out.set_meta(key, src.get_meta(key))
	for i in kept.size():
		_add(out, kept[i])
		out.surface_set_material(i, src.surface_get_material(i))
		out.surface_set_name(i, src.surface_get_name(i))
	out.custom_aabb = src.custom_aabb
	return out


## Keeps the CPU arrays of a mesh made by generate_scene (_read_gltf) from its ImporterMesh, which holds them
## on the CPU already: ImporterMesh.get_mesh() hands out the mesh it made, so the one drawn is found by identity.
static func _keep_from_state(mesh: Mesh, state: GLTFState) -> void:
	if not cpu_arrays or mesh == null:
		return
	for gm: GLTFMesh in state.get_meshes():
		var im := gm.mesh
		if im == null or im.get_surface_count() != mesh.get_surface_count():
			continue
		if im.get_mesh() != mesh:
			continue
		var kept: Array = []
		for i in im.get_surface_count():
			kept.append(im.get_surface_arrays(i))
		mesh.set_meta(ARRAYS_META, kept)
		return


const LOD1_MIN_TRIS := 32
const LOD1_TARGET_TRIS := 28
const LOD1_MAX_TRIS := 64
const LOD1_UV_MAX_TRIS := 96
const LOD1_HARD_CAP_TRIS := 160
const LOD1_FLOOR_TRIS := 12


static func _lod2_mode_arg() -> String:
	var mode := "proxy"
	for arg in Switches.args():
		if arg.begins_with("--item-lod2="):
			var v := arg.get_slice("=", 1)
			if v == "icon" or v == "proxy":
				mode = v
	return mode


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
	if _jobs.has(key):
		if WorkerThreadPool.is_task_completed(int((_jobs[key] as Array)[0])):
			_finish_job(key)
			if _cache.has(key):
				return _cache[key]
		else:
			# A read still running on a worker is not waited for: read here as before, its result dropped
			# (ready() waits for the finished task later).
			_orphans.append(int((_jobs[key] as Array)[0]))
			_jobs.erase(key)
	var path := ModelPacks.item_model_path(item, maxi(variant, 0)) if item != "" else ""
	var mesh: Mesh = null
	if path != "":
		var t0 := Time.get_ticks_usec()
		mesh = read(path)
		Probing.add("gi_model_load", t0)
		Probing.count("item_models")
	_cache[key] = mesh
	_paths[key] = path
	_pbrs[key] = ModelPacks.pbr(path) if path != "" else false
	return mesh


## How many variants item `item`'s model has (0 or 1: none to pick from); 0 with --model-variants=off
## (every item its first, as before: on the ground, on belts near and far, in hands).
static func variant_count(item: String) -> int:
	return ModelPacks.item_variant_count(item) if item != "" and variants_on else 0


## --model-variants=off: items keep their first model too (model_library.gd model_variants, for entities).
static var variants_on := Switches.on("--model-variants")


## The packs' order, switches, choices or PBR overrides changed: the items whose file or PBR mode
## changed are read again when next asked for, and `generation` is bumped so what was drawn with
## the old mesh is made again.
static func _follow_packs() -> void:
	_packs_version = ModelPacks.version
	var changed := false
	for key: String in _cache.keys():
		var at := key.rfind("#")
		var path := ModelPacks.item_model_path(key, 0) if at < 0 else ModelPacks.item_model_path(key.substr(0, at), int(key.substr(at + 1)))
		var pbr_now := ModelPacks.pbr(path) if path != "" else false
		if path != str(_paths.get(key, "")) or pbr_now != bool(_pbrs.get(key, false)):
			_cache.erase(key)
			_paths.erase(key)
			_pbrs.erase(key)
			changed = true
	_all_ready.clear()
	if changed:
		generation += 1


## The item models' generation, the packs looked at first if they changed since (an int compare
## otherwise: called every frame by every ItemCards owner and by belt_lanes.gd, unless kinds_follow
## is off).
static func current_generation() -> int:
	if _packs_version != ModelPacks.version:
		_follow_packs()
	return generation


## An item model's mesh from its file: Zenith's own imported scene (res://) unless a built-in pack
## asks for PBR and its .glb is readable directly (so ModelTextures.prepare adds mipmaps), else the
## .glb or .gltf read as it is, its colours made vertex colours where it has none. Null when it can't be read.
static func read(path: String) -> Mesh:
	var is_pbr := ModelPacks.pbr(path)
	if _main_only(path, is_pbr):
		if not ResourceLoader.exists(path):
			return null
		var packed := _mesh_of(load(path) as PackedScene)
		return _finish_mesh(packed, path, is_pbr) if packed != null and is_pbr else packed
	return _read_gltf(path, is_pbr, ModelPacks.owns(path))


## Whether read() takes `path` through ResourceLoader (an imported scene): the main thread's only.
static func _main_only(path: String, is_pbr: bool) -> bool:
	return path.begins_with("res://") and not (is_pbr and FileAccess.file_exists(path))


## A .glb or .gltf read as it is (read()); touches nothing shared, so it also runs on a worker thread (ready()).
static func _read_gltf(path: String, is_pbr: bool, owns: bool) -> Mesh:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		push_warning("[models] item model %s can't be read" % path)
		return null
	if own_materials and pictures:
		ModelTextures.prepare(path, state, owns)
	var has_file_tan := _gltf_has_tangents(state)
	var root := doc.generate_scene(state)
	if root == null:
		return null
	var mesh: Mesh = null
	for node in root.find_children("*", "MeshInstance3D", true, false):
		_keep_from_state((node as MeshInstance3D).mesh, state)
		mesh = _finish_mesh((node as MeshInstance3D).mesh, path, is_pbr, has_file_tan)
		break
	root.free()
	return mesh


static func _gltf_has_tangents(state: GLTFState) -> bool:
	var meshes := state.get_meshes()
	if meshes.is_empty():
		return false
	var im := meshes[0].mesh
	if im == null or im.get_surface_count() == 0:
		return false
	for i in im.get_surface_count():
		if im.get_surface_arrays(i)[Mesh.ARRAY_TANGENT] == null:
			return false
	return true


## Attaches item-model metadata (own-look surfaces, shared picture, PBR material, tangents) onto `source`.
static func _finish_mesh(source: Mesh, path: String, is_pbr: bool, trusted_tangents := false) -> Mesh:
	var mesh := _coloured(source)
	var own := mesh != null and own_materials and pictures and own_look(source) \
			and not _picture_enough(source, is_pbr)
	var tex: Texture2D = picture_of(source) if pictures and not own else null
	var has_norm := false
	if own:
		for i in source.get_surface_count():
			var sm := source.surface_get_material(i) as BaseMaterial3D
			if sm != null and sm.normal_enabled and sm.normal_texture != null and sm.normal_texture != sm.albedo_texture:
				has_norm = true
				break
	elif tex != null and is_pbr:
		var pm := source.surface_get_material(0) as BaseMaterial3D
		has_norm = pm != null and pm.normal_enabled and pm.normal_texture != null
	mesh = _ensure_tangents(mesh, has_norm, trusted_tangents)
	if own:
		var surfaces: Array = []
		for i in source.get_surface_count():
			surfaces.append([source.surface_get_material(i), _peek(source, i)[Mesh.ARRAY_COLOR] != null])
		if mesh == source:
			mesh = copy_mesh(source)
		mesh.set_meta(SURFACES_META, surfaces)
		if is_pbr:
			mesh.set_meta(PBR_META, source.surface_get_material(0))
		return mesh
	if mesh != null and tex != null:
		if mesh == source:
			mesh = copy_mesh(source)  # its own, for the picture kept with it
		mesh.set_meta(PICTURE_META, tex)
		if is_pbr:
			mesh.set_meta(PBR_META, source.surface_get_material(0))
	return mesh


## Whether `mesh` carries precomputed vertex tangents (and --item-tangents isn't off).
static func has_tangents(mesh: Mesh) -> bool:
	return item_tangents and mesh != null and bool(mesh.get_meta(TANGENTS_META, false))


## Ensures surfaces of a normal-mapped mesh carry MikkTSpace ARRAY_TANGENT so fragment shaders can
## avoid per-pixel dFdx/dFdy cotangent construction. `trusted_tangents` is true only when the source
## (e.g. GLTFState ImporterMesh) verified real tangents were present, because ArrayMesh compressed
## surfaces synthesize dummy fallback tangents automatically.
static func _ensure_tangents(mesh: Mesh, has_normal_map: bool, trusted_tangents := false) -> Mesh:
	if mesh == null or not item_tangents or not has_normal_map:
		return mesh
	var n := mesh.get_surface_count()
	if n == 0:
		return mesh
	if trusted_tangents:
		var all_have := true
		for i in n:
			if _peek(mesh, i)[Mesh.ARRAY_TANGENT] == null:
				all_have = false
				break
		if all_have:
			var dup := copy_mesh(mesh)
			dup.set_meta(TANGENTS_META, true)
			return dup
	var out := ArrayMesh.new()
	var out_all := true
	for i in n:
		var arrays := _peek(mesh, i)
		var mat := mesh.surface_get_material(i)
		if trusted_tangents and arrays[Mesh.ARRAY_TANGENT] != null:
			_add(out, arrays)
			out.surface_set_material(i, mat)
		elif arrays[Mesh.ARRAY_VERTEX] != null and arrays[Mesh.ARRAY_NORMAL] != null \
				and arrays[Mesh.ARRAY_TEX_UV] != null:
			var st := SurfaceTool.new()
			if cpu_arrays:
				# From the CPU copy: create_from(mesh, i) reads the surface back from the renderer.
				st.create_from_arrays(arrays)
			else:
				st.create_from(mesh, i)
			st.generate_tangents()
			var tangent_arrays := st.commit_to_arrays()
			_add(out, tangent_arrays)
			out.surface_set_material(i, mat)
			if tangent_arrays[Mesh.ARRAY_TANGENT] == null:
				out_all = false
		else:
			_add(out, arrays)
			out.surface_set_material(i, mat)
			out_all = false
	if out_all:
		out.set_meta(TANGENTS_META, true)
	return out


## The base-colour picture a modeller's mesh is drawn with: the one every surface's material has
## (with UVs to read it by); null when it has none, or its surfaces have different ones or none.
static func picture_of(mesh: Mesh) -> Texture2D:
	if mesh == null or mesh.get_surface_count() == 0:
		return null
	var tex: Texture2D = null
	for i in mesh.get_surface_count():
		var mat := mesh.surface_get_material(i) as BaseMaterial3D
		if mat == null or mat.albedo_texture == null or _peek(mesh, i)[Mesh.ARRAY_TEX_UV] == null:
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


## Whether `mesh` is a 10-triangle LOD2 bounding-box proxy produced by lod2_mesh().
static func is_lod2(mesh: Mesh) -> bool:
	return mesh != null and mesh.has_meta(LOD2_FLAG_META)


static func _readable_image(tex: Texture2D) -> Image:
	if tex == null:
		return null
	if tex.has_meta(ModelTextures.SMALL_META):
		var small: Variant = tex.get_meta(ModelTextures.SMALL_META)
		if small is Image and not (small as Image).is_empty():
			return small as Image
	if cpu_arrays and tex.has_meta(IMAGE_META):
		return tex.get_meta(IMAGE_META) as Image
	var img := tex.get_image()
	if img == null or img.is_empty():
		img = null
	elif img.is_compressed():
		img = img.duplicate() as Image
		if img.decompress() != OK:
			img = null
	if cpu_arrays and (img == null or img.get_width() * img.get_height() <= 512 * 512):
		tex.set_meta(IMAGE_META, img)  # read from the renderer once per picture (null kept too; big ones not kept)
	return img


static func _sample_image(img: Image, uv: Vector2) -> Color:
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0:
		return Color.WHITE
	var u := fposmod(uv.x, 1.0)
	var v := fposmod(uv.y, 1.0)
	var px := clampi(int(u * float(w)), 0, w - 1)
	var py := clampi(int(v * float(h)), 0, h - 1)
	return img.get_pixel(px, py)


## Average linear RGB of a texture (4x4 sample), used once per multi-surface item to tint merged opaque LOD vertices.
static func _mean_texture_color(tex: Texture2D) -> Color:
	var img := _readable_image(tex)
	if img == null:
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


static func _surface_enclosure(mesh: Mesh) -> Dictionary:
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
	var raw_emits: Array[Vector3] = []
	for i in n:
		var arrays := _peek(mesh, i)
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
		var raw_em := Vector3.ZERO
		if src != null and src.emission_enabled:
			var elin := src.emission.srgb_to_linear()
			var gain := minf(src.emission_energy_multiplier * 0.35, 0.75)
			em = Color(elin.r * gain, elin.g * gain, elin.b * gain, 0.0)
			raw_em = Vector3(elin.r, elin.g, elin.b) * src.emission_energy_multiplier
			if src.emission_texture != null:
				var etex := _mean_texture_color(src.emission_texture)
				raw_em = Vector3(raw_em.x * etex.r, raw_em.y * etex.g, raw_em.z * etex.b)
		emits.append(em)
		raw_emits.append(raw_em)
	var skip: Array[bool] = []
	var override_col: Array = []
	var override_albedo: Array = []
	var override_em: Array = []
	skip.resize(n)
	override_col.resize(n)
	override_albedo.resize(n)
	override_em.resize(n)
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
			var t := clampf(alphas[i], 0.0, 0.85)
			var inner_c := Color(rep_cols[best_j].r + emits[best_j].r, rep_cols[best_j].g + emits[best_j].g,
				rep_cols[best_j].b + emits[best_j].b, 1.0)
			var outer_c := Color(rep_cols[i].r + emits[i].r, rep_cols[i].g + emits[i].g, rep_cols[i].b + emits[i].b, 1.0)
			var blended := inner_c.lerp(outer_c, t)
			blended.a = 1.0
			override_col[i] = blended
			var al_blended := rep_cols[best_j].lerp(rep_cols[i], t)
			al_blended.a = 1.0
			override_albedo[i] = al_blended
			override_em[i] = raw_emits[best_j].lerp(raw_emits[i], t)
			skip[best_j] = true
	return {
		"n": n,
		"surf_arrays": surf_arrays,
		"vert_mults": vert_mults,
		"emits": emits,
		"skip": skip,
		"override_col": override_col,
		"override_albedo": override_albedo,
		"override_em": override_em,
	}


## Area-weighted surface statistics for LOD1/LOD2 shading & box proxy colors (cached on LOD_STATS_META).
static func lod_stats(mesh: Mesh) -> Dictionary:
	if mesh == null:
		return {
			"mean_color": Color.WHITE, "top_color": Color.WHITE, "side_color": Color.WHITE,
			"tex_mean": Color.WHITE, "surf_tex_means": [], "eff_roughness": 0.8, "eff_metallic": 0.0,
			"eff_emission": Color.BLACK, "eff_emission_energy": 0.0, "has_emission": false,
		}
	if mesh.has_meta(LOD_STATS_META):
		return mesh.get_meta(LOD_STATS_META) as Dictionary
	var own := has_own(mesh)
	var surfaces: Array = mesh.get_meta(SURFACES_META) if own else []
	var enc: Dictionary = _surface_enclosure(mesh) if needs_lod(mesh) else {}
	var skip: Array = enc.get("skip", [])
	var override_albedo: Array = enc.get("override_albedo", [])
	var override_em: Array = enc.get("override_em", [])
	var enc_arrays: Array = enc.get("surf_arrays", [])
	var n := mesh.get_surface_count()
	var sum_col := Vector3.ZERO
	var sum_area := 0.0
	var sum_top := Vector3.ZERO
	var sum_top_w := 0.0
	var sum_side := Vector3.ZERO
	var sum_side_w := 0.0
	var sum_r := 0.0
	var sum_m := 0.0
	var sum_rm_w := 0.0
	var sum_tn := Vector3.ZERO
	var sum_tn_w := 0.0
	var sum_em := Vector3.ZERO
	var sum_tex := Vector3.ZERO
	var sum_tex_w := 0.0
	var surf_tex_means: Array[Color] = []
	surf_tex_means.resize(n)
	surf_tex_means.fill(Color.WHITE)
	var shared_pbr := pbr_material(mesh)
	var shared_pic := picture(mesh)
	var use_pbr_maps := own or shared_pbr != null
	for i in n:
		if i < skip.size() and bool(skip[i]):
			continue
		var arrays: Array = enc_arrays[i] if i < enc_arrays.size() else _peek(mesh, i)
		var verts: Variant = arrays[Mesh.ARRAY_VERTEX]
		if not (verts is PackedVector3Array) or (verts as PackedVector3Array).is_empty():
			continue
		var v_arr := verts as PackedVector3Array
		var norms: Variant = arrays[Mesh.ARRAY_NORMAL]
		var has_n := norms is PackedVector3Array and (norms as PackedVector3Array).size() == v_arr.size()
		var n_arr := norms as PackedVector3Array if has_n else PackedVector3Array()
		var vcols: Variant = arrays[Mesh.ARRAY_COLOR]
		var has_vc := vcols is PackedColorArray and (vcols as PackedColorArray).size() == v_arr.size()
		var vc_arr := vcols as PackedColorArray if has_vc else PackedColorArray()
		var uvs: Variant = arrays[Mesh.ARRAY_TEX_UV]
		var has_uv := uvs is PackedVector2Array and (uvs as PackedVector2Array).size() == v_arr.size()
		var uv_arr := uvs as PackedVector2Array if has_uv else PackedVector2Array()
		var idx_v: Variant = arrays[Mesh.ARRAY_INDEX]
		var has_idx := idx_v is PackedInt32Array and not (idx_v as PackedInt32Array).is_empty()
		var idx := idx_v as PackedInt32Array if has_idx else PackedInt32Array()
		var tri_count := idx.size() / 3 if has_idx else v_arr.size() / 3
		if tri_count <= 0:
			continue
		var src: BaseMaterial3D = null
		var file_cols := false
		if own and i < surfaces.size() and surfaces[i] is Array and not (surfaces[i] as Array).is_empty():
			src = (surfaces[i] as Array)[0] as BaseMaterial3D
			file_cols = (surfaces[i] as Array).size() > 1 and bool((surfaces[i] as Array)[1])
		elif shared_pbr != null:
			src = shared_pbr
		else:
			src = mesh.surface_get_material(i) as BaseMaterial3D
		var albedo_tex: Texture2D = null
		if pictures:
			if own:
				albedo_tex = src.albedo_texture if src != null else null
			else:
				albedo_tex = shared_pic if shared_pic != null else (src.albedo_texture if src != null else null)
		var fallback_tex := _mean_texture_color(albedo_tex) if albedo_tex != null else Color.WHITE
		var albedo_img := _readable_image(albedo_tex) if (albedo_tex != null and has_uv) else null
		var mat_mult := src.albedo_color.srgb_to_linear() if (own and file_cols and src != null) else Color.WHITE
		var fallback_vc := src.albedo_color.srgb_to_linear() if (not own and src != null) else Color.WHITE
		var ov_col: Variant = override_albedo[i] if i < override_albedo.size() else null
		var ov_em: Variant = override_em[i] if i < override_em.size() else null
		var base_r := src.roughness if (use_pbr_maps and src != null) else 0.8
		var base_m := src.metallic if (use_pbr_maps and src != null) else 0.0
		var orm_tex: Texture2D = (src.metallic_texture if src.metallic_texture != null else src.roughness_texture) if (use_pbr_maps and src != null) else null
		var orm_img := _readable_image(orm_tex) if (orm_tex != null and has_uv) else null
		var norm_tex: Texture2D = src.normal_texture if (use_pbr_maps and src != null and src.normal_enabled and src.normal_texture != null and src.normal_texture != src.albedo_texture) else null
		var norm_img := _readable_image(norm_tex) if (norm_tex != null and has_uv) else null
		var norm_scale := src.normal_scale if src != null else 1.0
		var em_enabled := src != null and src.emission_enabled
		var em_base := Vector3.ZERO
		if em_enabled:
			var elin := src.emission.srgb_to_linear()
			em_base = Vector3(elin.r, elin.g, elin.b) * src.emission_energy_multiplier
		var em_tex: Texture2D = src.emission_texture if (em_enabled and src.emission_texture != null) else null
		var em_img := _readable_image(em_tex) if (em_tex != null and has_uv) else null
		var em_tex_fallback := _mean_texture_color(em_tex) if (em_tex != null and em_img == null) else Color.WHITE
		var surf_tex_sum := Vector3.ZERO
		var surf_tex_w := 0.0
		var step := maxi(1, tri_count / 500)
		for t in range(0, tri_count, step):
			var ia := idx[t * 3] if has_idx else t * 3
			var ib := idx[t * 3 + 1] if has_idx else t * 3 + 1
			var ic := idx[t * 3 + 2] if has_idx else t * 3 + 2
			var p0 := v_arr[ia]
			var p1 := v_arr[ib]
			var p2 := v_arr[ic]
			var cr := (p1 - p0).cross(p2 - p0)
			var area := maxf(0.5 * cr.length(), 1e-7)
			var fn := Vector3.UP
			if has_n:
				var ns := n_arr[ia] + n_arr[ib] + n_arr[ic]
				fn = ns.normalized() if ns.length_squared() > 1e-12 else Vector3.UP
			else:
				var fc := (p2 - p0).cross(p1 - p0)
				fn = fc.normalized() if fc.length_squared() > 1e-12 else Vector3.UP
			var uv_c := (uv_arr[ia] + uv_arr[ib] + uv_arr[ic]) / 3.0 if has_uv else Vector2.ZERO
			var tex_c := fallback_tex
			if albedo_img != null:
				var px := _sample_image(albedo_img, uv_c)
				if px.a > 0.05:
					tex_c = px.srgb_to_linear()
			if albedo_tex != null:
				surf_tex_sum += Vector3(tex_c.r, tex_c.g, tex_c.b) * area
				surf_tex_w += area
			var tri_v := Vector3.ZERO
			if ov_col is Color:
				var oc := ov_col as Color
				tri_v = Vector3(oc.r, oc.g, oc.b)
			else:
				var vc := Color(
					(vc_arr[ia].r + vc_arr[ib].r + vc_arr[ic].r) / 3.0,
					(vc_arr[ia].g + vc_arr[ib].g + vc_arr[ic].g) / 3.0,
					(vc_arr[ia].b + vc_arr[ib].b + vc_arr[ic].b) / 3.0, 1.0
				) if has_vc else fallback_vc
				tri_v = Vector3(vc.r * mat_mult.r * tex_c.r, vc.g * mat_mult.g * tex_c.g, vc.b * mat_mult.b * tex_c.b)
			sum_col += tri_v * area
			sum_area += area
			if fn.y > 0.35:
				sum_top += tri_v * area
				sum_top_w += area
			elif absf(fn.y) <= 0.35:
				sum_side += tri_v * area
				sum_side_w += area
			var w_up := area * (0.25 + 0.75 * maxf(fn.y, 0.0))
			var tri_r := base_r
			var tri_m := base_m
			if orm_img != null:
				var orm_px := _sample_image(orm_img, uv_c)
				tri_r = clampf(base_r * orm_px.g, 0.0, 1.0)
				tri_m = clampf(base_m * orm_px.b, 0.0, 1.0)
			sum_r += tri_r * w_up
			sum_m += tri_m * w_up
			sum_rm_w += w_up
			if norm_img != null:
				var np := _sample_image(norm_img, uv_c)
				var nv := Vector3((np.r * 2.0 - 1.0) * norm_scale, (np.g * 2.0 - 1.0) * norm_scale, maxf(np.b * 2.0 - 1.0, 0.05)).normalized()
				sum_tn += nv * w_up
				sum_tn_w += w_up
			if ov_em is Vector3:
				sum_em += (ov_em as Vector3) * area
			elif em_enabled:
				var ec := em_tex_fallback
				if em_img != null:
					var ep := _sample_image(em_img, uv_c)
					ec = ep.srgb_to_linear()
				sum_em += Vector3(em_base.x * ec.r, em_base.y * ec.g, em_base.z * ec.b) * area
		if surf_tex_w > 0.0:
			var tv := surf_tex_sum / surf_tex_w
			surf_tex_means[i] = Color(tv.x, tv.y, tv.z, 1.0)
			sum_tex += tv * surf_tex_w
			sum_tex_w += surf_tex_w
		elif albedo_tex != null:
			surf_tex_means[i] = fallback_tex
			sum_tex += Vector3(fallback_tex.r, fallback_tex.g, fallback_tex.b) * 1e-4
			sum_tex_w += 1e-4
	var mean_v := sum_col / sum_area if sum_area > 0.0 else Vector3.ONE
	var top_v := sum_top / sum_top_w if sum_top_w > 0.0 else mean_v
	var side_v := sum_side / sum_side_w if sum_side_w > 0.0 else mean_v
	var tex_v := sum_tex / sum_tex_w if sum_tex_w > 0.0 else Vector3.ONE
	var eff_r := clampf(sum_r / sum_rm_w, 0.0, 1.0) if sum_rm_w > 0.0 else 0.8
	var eff_m := clampf(sum_m / sum_rm_w, 0.0, 1.0) if sum_rm_w > 0.0 else 0.0
	if sum_tn_w > 0.0:
		var avg_len := (sum_tn / sum_tn_w).length()
		var norm_var := clampf((1.0 - minf(avg_len, 1.0)) / maxf(avg_len, 0.2), 0.0, 0.35)
		eff_r = clampf(sqrt(eff_r * eff_r + norm_var * 0.5), eff_r, 1.0)
	var avg_em := sum_em / sum_area if sum_area > 0.0 else Vector3.ZERO
	var max_em := maxf(avg_em.x, maxf(avg_em.y, avg_em.z))
	var has_em := max_em > 0.001
	var eff_em := Color.BLACK
	if has_em:
		eff_em = Color(avg_em.x / max_em, avg_em.y / max_em, avg_em.z / max_em, 1.0).linear_to_srgb()
	var stats := {
		"mean_color": Color(mean_v.x, mean_v.y, mean_v.z, 1.0),
		"top_color": Color(top_v.x, top_v.y, top_v.z, 1.0),
		"side_color": Color(side_v.x, side_v.y, side_v.z, 1.0),
		"tex_mean": Color(tex_v.x, tex_v.y, tex_v.z, 1.0),
		"surf_tex_means": surf_tex_means,
		"eff_roughness": eff_r,
		"eff_metallic": eff_m,
		"eff_emission": eff_em,
		"eff_emission_energy": max_em if has_em else 0.0,
		"has_emission": has_em,
	}
	mesh.set_meta(LOD_STATS_META, stats)
	return stats


## Merges a multi-surface or see-through own-look item into a single opaque surface with baked linear vertex
## colours (outer glass shells blend the colour of any enclosed liquid and drop its occluded triangles).
static func simple_mesh(mesh: Mesh) -> Mesh:
	if not needs_lod(mesh):
		return mesh
	if mesh.has_meta(SIMPLE_META):
		return mesh.get_meta(SIMPLE_META) as Mesh
	var enc := _surface_enclosure(mesh)
	var n := int(enc["n"])
	var surf_arrays: Array = enc["surf_arrays"]
	var vert_mults: Array = enc["vert_mults"]
	var emits: Array = enc["emits"]
	var skip: Array = enc["skip"]
	var override_col: Array = enc["override_col"]
	var out_verts := PackedVector3Array()
	var out_norms := PackedVector3Array()
	var out_cols := PackedColorArray()
	var out_idx := PackedInt32Array()
	for i in n:
		if bool(skip[i]):
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
			var mult: Color = vert_mults[i]
			var em: Color = emits[i]
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
	_add(out, merged)
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
		_add(out, _peek(detailed, i))
		var m := detailed.surface_get_material(i) as ShaderMaterial
		if m != null:
			var dup := m.duplicate() as ShaderMaterial
			dup.set_shader_parameter("lod_max_sq", dist_sq)
			out.surface_set_material(i, dup)
	_add(out, _peek(simple, 0))
	var smat := ShaderMaterial.new()
	smat.shader = Looks.shader_for(ItemShader)
	smat.set_shader_parameter("exposure", 1.0)
	smat.set_shader_parameter("lod_min_sq", dist_sq)
	_apply_lod_shading_params(smat, mesh, true, false)
	out.surface_set_material(out.get_surface_count() - 1, smat)
	copies[key] = out
	mesh.set_meta(DRESSED_LOD_META, copies)
	return out


## Base-colour picture used by geometric LOD1 / far lane materials for `mesh`, including single-surface
## opaque own-look items that carry an albedo_texture instead of PICTURE_META.
static func lod_picture(mesh: Mesh) -> Texture2D:
	var tex := picture(mesh)
	if tex != null:
		return tex
	if has_own(mesh) and not needs_lod(mesh) and pictures:
		var surfaces: Array = mesh.get_meta(SURFACES_META)
		if surfaces.size() == 1 and surfaces[0] is Array and (surfaces[0] as Array).size() > 0:
			var src := (surfaces[0] as Array)[0] as BaseMaterial3D
			if src != null:
				return src.albedo_texture
	return null


static func _mesh_tri_count(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var total := 0
	for i in mesh.get_surface_count():
		var arrays := _peek(mesh, i)
		var idx: Variant = arrays[Mesh.ARRAY_INDEX]
		if idx is PackedInt32Array and not (idx as PackedInt32Array).is_empty():
			total += (idx as PackedInt32Array).size() / 3
		else:
			var verts: Variant = arrays[Mesh.ARRAY_VERTEX]
			if verts is PackedVector3Array:
				total += (verts as PackedVector3Array).size() / 3
	return total


static func _merge_for_lod(base: Mesh, orig: Mesh, tex: Texture2D) -> Array:
	var n := base.get_surface_count()
	if n == 0:
		return []
	var keep_uv := tex != null
	if keep_uv:
		for i in n:
			var a := _peek(base, i)
			var v: Variant = a[Mesh.ARRAY_VERTEX]
			var u: Variant = a[Mesh.ARRAY_TEX_UV]
			if not (v is PackedVector3Array) or not (u is PackedVector2Array) \
					or (u as PackedVector2Array).size() != (v as PackedVector3Array).size():
				keep_uv = false
				break
	if n == 1:
		var arrays := _arrays(base, 0)
		var verts: Variant = arrays[Mesh.ARRAY_VERTEX]
		if not (verts is PackedVector3Array) or (verts as PackedVector3Array).is_empty():
			return []
		var v_arr := verts as PackedVector3Array
		var out := []
		out.resize(Mesh.ARRAY_MAX)
		out[Mesh.ARRAY_VERTEX] = v_arr
		var norms: Variant = arrays[Mesh.ARRAY_NORMAL]
		if norms is PackedVector3Array and (norms as PackedVector3Array).size() == v_arr.size():
			out[Mesh.ARRAY_NORMAL] = norms as PackedVector3Array
		else:
			var up := PackedVector3Array()
			up.resize(v_arr.size())
			up.fill(Vector3.UP)
			out[Mesh.ARRAY_NORMAL] = up
		var cols: Variant = arrays[Mesh.ARRAY_COLOR]
		if cols is PackedColorArray and (cols as PackedColorArray).size() == v_arr.size():
			var c_arr := cols as PackedColorArray
			if base == orig and has_own(orig):
				var surfaces: Array = orig.get_meta(SURFACES_META)
				if surfaces.size() == 1 and surfaces[0] is Array and bool((surfaces[0] as Array)[1]):
					var src := (surfaces[0] as Array)[0] as BaseMaterial3D
					if src != null and src.albedo_color != Color.WHITE:
						var mult := src.albedo_color.srgb_to_linear()
						var tinted := PackedColorArray()
						tinted.resize(v_arr.size())
						for k in v_arr.size():
							tinted[k] = Color(c_arr[k].r * mult.r, c_arr[k].g * mult.g, c_arr[k].b * mult.b, 1.0)
						c_arr = tinted
			out[Mesh.ARRAY_COLOR] = c_arr
		if keep_uv:
			out[Mesh.ARRAY_TEX_UV] = arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array
		var idx: Variant = arrays[Mesh.ARRAY_INDEX]
		if idx is PackedInt32Array and not (idx as PackedInt32Array).is_empty():
			out[Mesh.ARRAY_INDEX] = idx as PackedInt32Array
		else:
			var gen := PackedInt32Array()
			gen.resize(v_arr.size())
			for k in v_arr.size():
				gen[k] = k
			out[Mesh.ARRAY_INDEX] = gen
		return out
	var out_verts := PackedVector3Array()
	var out_norms := PackedVector3Array()
	var out_cols := PackedColorArray()
	var out_uvs := PackedVector2Array()
	var out_idx := PackedInt32Array()
	for i in n:
		var arrays := _peek(base, i)
		var verts: Variant = arrays[Mesh.ARRAY_VERTEX]
		if not (verts is PackedVector3Array) or (verts as PackedVector3Array).is_empty():
			continue
		var v_arr := verts as PackedVector3Array
		var base_v := out_verts.size()
		out_verts.append_array(v_arr)
		var norms: Variant = arrays[Mesh.ARRAY_NORMAL]
		if norms is PackedVector3Array and (norms as PackedVector3Array).size() == v_arr.size():
			out_norms.append_array(norms as PackedVector3Array)
		else:
			var up := PackedVector3Array()
			up.resize(v_arr.size())
			up.fill(Vector3.UP)
			out_norms.append_array(up)
		var cols: Variant = arrays[Mesh.ARRAY_COLOR]
		if cols is PackedColorArray and (cols as PackedColorArray).size() == v_arr.size():
			out_cols.append_array(cols as PackedColorArray)
		else:
			var mat := base.surface_get_material(i) as BaseMaterial3D
			var c := mat.albedo_color.srgb_to_linear() if mat != null else Color.WHITE
			var fill := PackedColorArray()
			fill.resize(v_arr.size())
			fill.fill(Color(c.r, c.g, c.b, 1.0))
			out_cols.append_array(fill)
		if keep_uv:
			out_uvs.append_array(arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array)
		var idx: Variant = arrays[Mesh.ARRAY_INDEX]
		if idx is PackedInt32Array and not (idx as PackedInt32Array).is_empty():
			for t in (idx as PackedInt32Array):
				out_idx.append(base_v + t)
		else:
			for k in v_arr.size():
				out_idx.append(base_v + k)
	if out_verts.is_empty():
		return []
	var merged := []
	merged.resize(Mesh.ARRAY_MAX)
	merged[Mesh.ARRAY_VERTEX] = out_verts
	merged[Mesh.ARRAY_NORMAL] = out_norms
	merged[Mesh.ARRAY_COLOR] = out_cols
	if keep_uv:
		merged[Mesh.ARRAY_TEX_UV] = out_uvs
	merged[Mesh.ARRAY_INDEX] = out_idx
	return merged


static func _compact_lod_arrays(arrays: Array, idx: PackedInt32Array) -> Array:
	var verts := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var count := verts.size()
	var new_of := PackedInt32Array()
	new_of.resize(count)
	new_of.fill(-1)
	var used := PackedInt32Array()
	var out_idx := PackedInt32Array()
	out_idx.resize(idx.size())
	for k in idx.size():
		var v := idx[k]
		if new_of[v] < 0:
			new_of[v] = used.size()
			used.append(v)
		out_idx[k] = new_of[v]
	var out_verts := PackedVector3Array()
	out_verts.resize(used.size())
	for k in used.size():
		out_verts[k] = verts[used[k]]
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = out_verts
	var norms: Variant = arrays[Mesh.ARRAY_NORMAL]
	if norms is PackedVector3Array and (norms as PackedVector3Array).size() == count:
		var sn := norms as PackedVector3Array
		var out_norms := PackedVector3Array()
		out_norms.resize(used.size())
		for k in used.size():
			out_norms[k] = sn[used[k]]
		out[Mesh.ARRAY_NORMAL] = out_norms
	var cols: Variant = arrays[Mesh.ARRAY_COLOR]
	if cols is PackedColorArray and (cols as PackedColorArray).size() == count:
		var sc := cols as PackedColorArray
		var out_cols := PackedColorArray()
		out_cols.resize(used.size())
		for k in used.size():
			out_cols[k] = sc[used[k]]
		out[Mesh.ARRAY_COLOR] = out_cols
	var uvs: Variant = arrays[Mesh.ARRAY_TEX_UV]
	if uvs is PackedVector2Array and (uvs as PackedVector2Array).size() == count:
		var su := uvs as PackedVector2Array
		var out_uvs := PackedVector2Array()
		out_uvs.resize(used.size())
		for k in used.size():
			out_uvs[k] = su[used[k]]
		out[Mesh.ARRAY_TEX_UV] = out_uvs
	out[Mesh.ARRAY_INDEX] = out_idx
	return out


static func _bake_uv_colors(arrays: Array, tex: Texture2D) -> PackedColorArray:
	var v_arr := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var uv_arr := arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array
	var idx := arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
	var cols: Variant = arrays[Mesh.ARRAY_COLOR]
	var verts_count := v_arr.size()
	var mean := _mean_texture_color(tex)
	var img := _readable_image(tex)
	var has_img := img != null and not img.is_empty()
	var has_cols := cols is PackedColorArray and (cols as PackedColorArray).size() == verts_count
	var src_cols := cols as PackedColorArray if has_cols else PackedColorArray()
	var sum_r := PackedFloat32Array()
	var sum_g := PackedFloat32Array()
	var sum_b := PackedFloat32Array()
	var sum_w := PackedFloat32Array()
	sum_r.resize(verts_count)
	sum_g.resize(verts_count)
	sum_b.resize(verts_count)
	sum_w.resize(verts_count)
	if has_img and idx.size() >= 3:
		for t in range(0, idx.size() - 2, 3):
			var ia := idx[t]
			var ib := idx[t + 1]
			var ic := idx[t + 2]
			var area := maxf(0.5 * (v_arr[ib] - v_arr[ia]).cross(v_arr[ic] - v_arr[ia]).length(), 1e-6)
			var uvc := (uv_arr[ia] + uv_arr[ib] + uv_arr[ic]) / 3.0
			for vi: int in [ia, ib, ic]:
				var px_c := _sample_image(img, uv_arr[vi] * 0.5 + uvc * 0.5)
				if px_c.a > 0.05:
					var tc := px_c.srgb_to_linear()
					sum_r[vi] += tc.r * area
					sum_g[vi] += tc.g * area
					sum_b[vi] += tc.b * area
					sum_w[vi] += area
	var out := PackedColorArray()
	out.resize(verts_count)
	for k in verts_count:
		var tc := mean
		if sum_w[k] > 0.0:
			var inv := 1.0 / sum_w[k]
			tc = Color(sum_r[k] * inv, sum_g[k] * inv, sum_b[k] * inv, 1.0)
		elif has_img:
			var c := _sample_image(img, uv_arr[k])
			if c.a > 0.05:
				tc = c.srgb_to_linear()
		if has_cols:
			var vc := src_cols[k]
			out[k] = Color(vc.r * tc.r, vc.g * tc.g, vc.b * tc.b, 1.0)
		else:
			out[k] = Color(tc.r, tc.g, tc.b, 1.0)
	return out


static func _weld_for_lod(arrays: Array, cols_override: PackedColorArray, split_normals := true) -> Array:
	var verts := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var norms := arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array
	var idx := arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
	var has_cols := not cols_override.is_empty()
	var src_cols := cols_override
	if not has_cols:
		var c_var: Variant = arrays[Mesh.ARRAY_COLOR]
		if c_var is PackedColorArray and (c_var as PackedColorArray).size() == verts.size():
			has_cols = true
			src_cols = c_var as PackedColorArray
	var weld := {}
	var w_verts := PackedVector3Array()
	var w_norms := PackedVector3Array()
	var w_cols := PackedColorArray()
	var counts := PackedInt32Array()
	var remap := PackedInt32Array()
	remap.resize(verts.size())
	for i in verts.size():
		var p := verts[i]
		var n := norms[i]
		var sector := 0
		if split_normals:
			sector = 1 if n.y > 0.5 else (-1 if n.y < -0.5 else 0)
		var key := Vector4i(roundi(p.x * 10000.0), roundi(p.y * 10000.0), roundi(p.z * 10000.0), sector)
		var at: int = weld.get(key, -1)
		if at < 0:
			at = w_verts.size()
			weld[key] = at
			w_verts.append(p)
			w_norms.append(n)
			counts.append(1)
			if has_cols:
				var c := src_cols[i]
				w_cols.append(Color(c.r, c.g, c.b, 1.0))
		else:
			w_norms[at] += n
			counts[at] += 1
			if has_cols:
				var c := src_cols[i]
				w_cols[at] = Color(w_cols[at].r + c.r, w_cols[at].g + c.g, w_cols[at].b + c.b, 1.0)
		remap[i] = at
	for i in w_verts.size():
		w_norms[i] = w_norms[i].normalized() if w_norms[i].length_squared() > 1e-12 else Vector3.UP
		if has_cols and counts[i] > 1:
			var inv := 1.0 / float(counts[i])
			w_cols[i] = Color(w_cols[i].r * inv, w_cols[i].g * inv, w_cols[i].b * inv, 1.0)
	var w_idx := PackedInt32Array()
	for t in range(0, idx.size() - 2, 3):
		var ia := remap[idx[t]]
		var ib := remap[idx[t + 1]]
		var ic := remap[idx[t + 2]]
		if ia != ib and ib != ic and ic != ia:
			w_idx.append_array([ia, ib, ic])
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = w_verts
	out[Mesh.ARRAY_NORMAL] = w_norms
	if has_cols:
		out[Mesh.ARRAY_COLOR] = w_cols
	out[Mesh.ARRAY_INDEX] = w_idx
	return out


static func _append_box_quad(p: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray, idx: PackedInt32Array,
		p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: Vector3, col: Color) -> void:
	var base := p.size()
	p.append_array([p0, p1, p2, p3])
	norms.append_array([n, n, n, n])
	cols.append_array([col, col, col, col])
	idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])


static func _build_colored_box_mesh(box: AABB, top_col: Color, side_col: Color, bottom_col: Color,
		include_bottom: bool, min_y := 0.015) -> ArrayMesh:
	var c := box.get_center()
	var hx := maxf(box.size.x, 0.01) * 0.5
	var hz := maxf(box.size.z, 0.01) * 0.5
	var lo := Vector3(c.x - hx, box.position.y, c.z - hz)
	var hi := Vector3(c.x + hx, maxf(box.end.y, box.position.y + min_y), c.z + hz)
	var p := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	# Top (+Y)
	_append_box_quad(p, norms, cols, idx,
		Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z),
		Vector3.UP, top_col)
	# Sides (-Z, +X, +Z, -X) with outward clockwise winding
	_append_box_quad(p, norms, cols, idx,
		Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(lo.x, hi.y, lo.z),
		Vector3.FORWARD, side_col)
	_append_box_quad(p, norms, cols, idx,
		Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, hi.y, lo.z),
		Vector3.RIGHT, side_col)
	_append_box_quad(p, norms, cols, idx,
		Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z), Vector3(lo.x, hi.y, hi.z), Vector3(hi.x, hi.y, hi.z),
		Vector3.BACK, side_col)
	_append_box_quad(p, norms, cols, idx,
		Vector3(lo.x, lo.y, hi.z), Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, hi.y, lo.z), Vector3(lo.x, hi.y, hi.z),
		Vector3.LEFT, side_col)
	if include_bottom:
		_append_box_quad(p, norms, cols, idx,
			Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, lo.y, lo.z),
			Vector3.DOWN, bottom_col)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = p
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var out := ArrayMesh.new()
	_add(out, arrays)
	return out


static func _lod_box_mesh(base: Mesh, orig: Mesh) -> ArrayMesh:
	var stats := lod_stats(orig)
	var top_c: Color = stats["top_color"]
	var side_c: Color = stats["side_color"]
	var bot_c := Color(side_c.r * 0.75, side_c.g * 0.75, side_c.b * 0.75, 1.0)
	var out := _build_colored_box_mesh(base.get_aabb(), top_c, side_c, bot_c, true)
	out.set_meta(LOD1_NO_UV_META, true)
	if is_simple(base):
		out.set_meta(SIMPLE_FLAG_META, true)
	return out


static func _decimate_welded(src_arrays: Array, baked_cols: PackedColorArray, orig_tris: int,
		cap_tris: int, max_keep_tris: int, split_normals: bool) -> Array:
	var welded := _weld_for_lod(src_arrays, baked_cols, split_normals)
	var welded_idx := welded[Mesh.ARRAY_INDEX] as PackedInt32Array
	if welded_idx.size() < 3:
		return []
	var welded_tris := welded_idx.size() / 3
	var im_w := ImporterMesh.new()
	im_w.add_surface(Mesh.PRIMITIVE_TRIANGLES, welded)
	im_w.generate_lods(180.0, 180.0, [])
	var w_idx := PackedInt32Array()
	var w_tris := orig_tris
	for l in im_w.get_surface_lod_count(0):
		var li := im_w.get_surface_lod_indices(0, l)
		var t := li.size() / 3
		if t < LOD1_FLOOR_TRIS:
			continue
		if t <= cap_tris:
			if w_idx.is_empty() or w_tris > cap_tris \
					or absf(float(t - LOD1_TARGET_TRIS)) < absf(float(w_tris - LOD1_TARGET_TRIS)) \
					or (absf(float(t - LOD1_TARGET_TRIS)) == absf(float(w_tris - LOD1_TARGET_TRIS)) and t < w_tris):
				w_idx = li
				w_tris = t
		elif t <= max_keep_tris and (w_idx.is_empty() or (w_tris > cap_tris and t < w_tris)):
			w_idx = li
			w_tris = t
	if w_idx.is_empty() and welded_tris <= LOD1_MAX_TRIS and welded_tris >= LOD1_FLOOR_TRIS:
		w_idx = welded_idx
		w_tris = welded_tris
	return [w_idx, w_tris, welded] if not w_idx.is_empty() else []


## Automatic geometric LOD1 for item models (mid/far belts and cards): merges multi-surface/glass
## own-look items via simple_mesh() first, simplifies meshes over LOD1_MIN_TRIS via ImporterMesh,
## compacts vertex arrays, drops UVs into baked vertex colors if UV seams block decimation, and
## caps output at LOD1_HARD_CAP_TRIS via a 12-triangle bounding box fallback.
static func lod_mesh(mesh: Mesh) -> Mesh:
	if mesh == null:
		return null
	if not item_geom_lod:
		return simple_mesh(mesh) if needs_lod(mesh) else mesh
	if mesh.has_meta(LOD1_META):
		return mesh.get_meta(LOD1_META) as Mesh
	var base := simple_mesh(mesh) if needs_lod(mesh) else mesh
	var orig_tris := _mesh_tri_count(base)
	if orig_tris <= LOD1_MIN_TRIS:
		mesh.set_meta(LOD1_META, base)
		return base
	var tex := lod_picture(mesh) if base == mesh else null
	var src_arrays := _merge_for_lod(base, mesh, tex)
	if src_arrays.is_empty():
		mesh.set_meta(LOD1_META, base)
		return base
	var has_uv := src_arrays[Mesh.ARRAY_TEX_UV] != null
	var cap_tris := mini(LOD1_MAX_TRIS, maxi(LOD1_TARGET_TRIS, int(orig_tris * 0.35)))
	var max_keep_tris := int(orig_tris * 0.80)
	var target_idx := PackedInt32Array()
	var target_tris := 0
	var best_idx := PackedInt32Array()
	var best_tris := orig_tris
	for angle: float in [60.0, 120.0, 180.0]:
		var im := ImporterMesh.new()
		im.add_surface(Mesh.PRIMITIVE_TRIANGLES, src_arrays)
		im.generate_lods(angle, angle, [])
		for l in im.get_surface_lod_count(0):
			var li := im.get_surface_lod_indices(0, l)
			var t := li.size() / 3
			if t < LOD1_FLOOR_TRIS:
				continue
			if t <= cap_tris:
				if target_idx.is_empty() or absf(float(t - LOD1_TARGET_TRIS)) < absf(float(target_tris - LOD1_TARGET_TRIS)) \
						or (absf(float(t - LOD1_TARGET_TRIS)) == absf(float(target_tris - LOD1_TARGET_TRIS)) and t < target_tris):
					target_idx = li
					target_tris = t
			elif t <= max_keep_tris and (best_idx.is_empty() or t < best_tris):
				best_idx = li
				best_tris = t
		if not target_idx.is_empty():
			break
	var chosen_idx := target_idx if not target_idx.is_empty() else best_idx
	var chosen_tris := target_tris if not target_idx.is_empty() else best_tris
	var use_arrays := src_arrays
	var dropped_uv := false
	var uv_accept_cap := mini(LOD1_UV_MAX_TRIS if has_uv else LOD1_MAX_TRIS, int(orig_tris * 0.60))
	if chosen_idx.is_empty() or chosen_tris > uv_accept_cap:
		var baked_cols := PackedColorArray()
		if has_uv and tex != null:
			baked_cols = _bake_uv_colors(src_arrays, tex)
		var res := _decimate_welded(src_arrays, baked_cols, orig_tris, cap_tris, max_keep_tris, true)
		if res.is_empty() or int(res[1]) > LOD1_MAX_TRIS:
			var res_smooth := _decimate_welded(src_arrays, baked_cols, orig_tris, cap_tris, max_keep_tris, false)
			if not res_smooth.is_empty() and (res.is_empty() or int(res_smooth[1]) < int(res[1])):
				res = res_smooth
		if not res.is_empty():
			var w_idx: PackedInt32Array = res[0]
			var w_tris := int(res[1])
			var welded: Array = res[2]
			if chosen_idx.is_empty() or w_tris < chosen_tris:
				use_arrays = welded
				chosen_idx = w_idx
				chosen_tris = w_tris
				dropped_uv = has_uv
	if chosen_idx.is_empty() or chosen_tris > LOD1_HARD_CAP_TRIS:
		var box_mesh := _lod_box_mesh(base, mesh)
		mesh.set_meta(LOD1_META, box_mesh)
		return box_mesh
	var compacted := _compact_lod_arrays(use_arrays, chosen_idx)
	var out := ArrayMesh.new()
	_add(out, compacted)
	if dropped_uv:
		out.set_meta(LOD1_NO_UV_META, true)
		out.set_meta(SIMPLE_FLAG_META, true)
	elif is_simple(base):
		out.set_meta(SIMPLE_FLAG_META, true)
	mesh.set_meta(LOD1_META, out)
	return out


## 10-triangle model-matched proxy box (top + 4 sides, flat outward normals, distinct top/side
## vertex colors) used at far LOD2 and past --far-belt-3d-dist.
static func lod2_mesh(mesh: Mesh) -> Mesh:
	if mesh == null:
		return null
	if mesh.has_meta(LOD2_META):
		return mesh.get_meta(LOD2_META) as Mesh
	var stats := lod_stats(mesh)
	var top_c: Color = stats["top_color"]
	var side_c: Color = stats["side_color"]
	var out := _build_colored_box_mesh(mesh.get_aabb(), top_c, side_c, side_c, false)
	out.set_meta(LOD1_NO_UV_META, true)
	out.set_meta(LOD2_FLAG_META, true)
	if has_own(mesh) or picture(mesh) != null or pbr_material(mesh) != null:
		out.set_meta(SIMPLE_FLAG_META, true)
	mesh.set_meta(LOD2_META, out)
	return out


static func _lod_exposure(mesh: Mesh, drawn: Mesh) -> float:
	if is_simple(drawn) or lod_picture(mesh) != null or has_own(mesh) or pbr_material(mesh) != null:
		return 1.0
	return EXPOSURE


static func _apply_lod_shading_params(m: ShaderMaterial, mesh: Mesh, is_simple_drawn: bool, allow_emission := true) -> void:
	var stats := lod_stats(mesh)
	var src := pbr_material(mesh)
	var own := has_own(mesh)
	var has_em := allow_emission and bool(stats["has_emission"]) and not is_simple_drawn
	if src != null or own:
		if src != null:
			m.set_shader_parameter("pbr", true)
		if own or has_em:
			m.set_shader_parameter("use_own_rm", true)
		m.set_shader_parameter("pbr_roughness", float(stats["eff_roughness"]))
		m.set_shader_parameter("pbr_metallic", float(stats["eff_metallic"]))
		if has_em:
			m.set_shader_parameter("emission", stats["eff_emission"])
			m.set_shader_parameter("emission_energy", float(stats["eff_emission_energy"]))


## Lightweight opaque ShaderMaterial for geometric LOD1 (`mesh` is the original mesh): skips
## normal maps, ORM textures, and precomputed tangents; folds effective PBR roughness/metallic & emission.
static func lod_material_for(mesh: Mesh) -> ShaderMaterial:
	if mesh == null:
		return material()
	if mesh.has_meta(LOD1_MAT_META):
		return mesh.get_meta(LOD1_MAT_META) as ShaderMaterial
	var lod := lod_mesh(mesh)
	var arrays := _peek(lod, 0) if lod != null and lod.get_surface_count() > 0 else []
	var has_uv := arrays.size() > Mesh.ARRAY_TEX_UV and arrays[Mesh.ARRAY_TEX_UV] != null \
		and not lod.has_meta(LOD1_NO_UV_META)
	var tex := lod_picture(mesh)
	var use_pic := has_uv and not is_simple(lod) and tex != null
	var src := pbr_material(mesh)
	if not use_pic and not is_simple(lod) and tex == null and not has_own(mesh) and src == null:
		var plain := material()
		mesh.set_meta(LOD1_MAT_META, plain)
		return plain
	var m := ShaderMaterial.new()
	m.shader = Looks.shader_for(ItemShader)
	if use_pic:
		m.set_shader_parameter("picture", tex)
		m.set_shader_parameter("use_picture", true)
	m.set_shader_parameter("exposure", _lod_exposure(mesh, lod))
	if lod == mesh and has_own(mesh) and not needs_lod(mesh):
		var surfaces: Array = mesh.get_meta(SURFACES_META)
		if surfaces.size() == 1 and surfaces[0] is Array and bool((surfaces[0] as Array)[1]):
			var s_mat := (surfaces[0] as Array)[0] as BaseMaterial3D
			if s_mat != null:
				m.set_shader_parameter("color", s_mat.albedo_color)
				m.set_shader_parameter("exposure", 1.0)
	_apply_lod_shading_params(m, mesh, is_simple(lod), true)
	mesh.set_meta(LOD1_MAT_META, m)
	return m


## Lightweight opaque ShaderMaterial matching `lod2_mesh(mesh)`: untextured, keeps effective PBR
## roughness/metallic and emission, or returns shared `material()` for plain Placeholders.
static func lod2_material_for(mesh: Mesh) -> ShaderMaterial:
	if mesh == null:
		return material()
	if mesh.has_meta(LOD2_MAT_META):
		return mesh.get_meta(LOD2_MAT_META) as ShaderMaterial
	var src := pbr_material(mesh)
	var own := has_own(mesh)
	if not own and src == null and picture(mesh) == null:
		var plain := material()
		mesh.set_meta(LOD2_MAT_META, plain)
		return plain
	var m := ShaderMaterial.new()
	m.shader = Looks.shader_for(ItemShader)
	m.set_shader_parameter("exposure", 1.0)
	_apply_lod_shading_params(m, mesh, false, true)
	mesh.set_meta(LOD2_MAT_META, m)
	return m


## Closed 8-vertex, 12-triangle AABB shadow proxy matching `mesh.get_aabb()`, clamped to >= 0.02
## on each axis so flat items don't collapse to zero thickness.
static func shadow_box_mesh(mesh: Mesh) -> ArrayMesh:
	if mesh != null and mesh.has_meta(SHADOW_BOX_META):
		return mesh.get_meta(SHADOW_BOX_META) as ArrayMesh
	var box := mesh.get_aabb() if mesh != null else AABB(Vector3(-0.16, 0.0, -0.16), Vector3(0.32, 0.02, 0.32))
	var c := box.get_center()
	var half := Vector3(maxf(box.size.x, 0.02), maxf(box.size.y, 0.02), maxf(box.size.z, 0.02)) * 0.5
	var lo := c - half
	var hi := c + half
	var p := PackedVector3Array()
	for y: float in [lo.y, hi.y]:
		p.append(Vector3(lo.x, y, lo.z))
		p.append(Vector3(hi.x, y, lo.z))
		p.append(Vector3(hi.x, y, hi.z))
		p.append(Vector3(lo.x, y, hi.z))
	var idx := PackedInt32Array([4, 5, 6, 4, 6, 7, 0, 2, 1, 0, 3, 2])
	for i in 4:
		var j := (i + 1) % 4
		idx.append_array([i, j, j + 4, i, j + 4, i + 4])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = p
	arrays[Mesh.ARRAY_INDEX] = idx
	var out := ArrayMesh.new()
	_add(out, arrays, 0)
	if mesh != null:
		mesh.set_meta(SHADOW_BOX_META, out)
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
	var out := copy_mesh(mesh)
	var surfaces: Array = mesh.get_meta(SURFACES_META)
	var blend: Shader = BLEND_TWINS.get(shader) if glass_blend else null
	var cut: Shader = CUT_TWINS.get(shader)
	var has_tan := has_tangents(mesh)
	var see_through: Array[int] = []
	for i in mini(out.get_surface_count(), surfaces.size()):
		var s: Array = surfaces[i]
		var src := s[0] as BaseMaterial3D
		var glass := blend != null and is_see_through(src)
		var use_cut := not glass and cut != null and src != null and (
			src.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			or (is_see_through(src) and not glass_blend))
		var target_shader: Shader = blend if glass else (cut if use_cut else shader)
		out.surface_set_material(i, own_material(src, bool(s[1]), Looks.shader_for(target_shader), pbr_material(mesh) != null, has_tan))
		if glass:
			see_through.append(i)
	_order_glass(out, see_through)
	out.remove_meta(DRESSED_META)
	out.remove_meta(DRESSED_LOD_META)
	out.remove_meta(SIMPLE_META)
	out.remove_meta(LOD1_META)
	out.remove_meta(LOD1_MAT_META)
	out.remove_meta(LOD2_META)
	out.remove_meta(LOD2_MAT_META)
	out.remove_meta(LOD_STATS_META)
	out.remove_meta(SHADOW_BOX_META)
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
		var verts: PackedVector3Array = _peek(mesh, i)[Mesh.ARRAY_VERTEX]
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
static func own_material(src: BaseMaterial3D, file_colours: bool, shader: Shader, pbr := false, has_tan := false) -> ShaderMaterial:
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
		if has_tan and item_tangents:
			m.set_shader_parameter("use_tangent", true)
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
	var out := copy_mesh(mesh)
	out.remove_meta(DRESSED_META)
	out.remove_meta(DRESSED_LOD_META)
	out.remove_meta(SIMPLE_META)
	out.remove_meta(LOD1_META)
	out.remove_meta(LOD1_MAT_META)
	out.remove_meta(LOD2_META)
	out.remove_meta(LOD2_MAT_META)
	out.remove_meta(LOD_STATS_META)
	out.remove_meta(SHADOW_BOX_META)
	var surfaces: Array = mesh.get_meta(SURFACES_META)
	var share := Looks.pbr_metal_arg(Switches.args())
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
		if _peek(mesh, i)[Mesh.ARRAY_COLOR] == null:
			all_have = false
	if all_have:
		return mesh
	var out := ArrayMesh.new()
	for i in mesh.get_surface_count():
		var arrays := _peek(mesh, i).duplicate()  # (only the colour slot is set: a shallow copy)
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
		_add(out, arrays)
		var mat := mesh.surface_get_material(i)
		if mat != null:
			out.surface_set_material(i, mat)
	return out


## Whether mesh_for(item) answers at once (its model and its variants' read, or it has none). With `later` a .glb
## or .gltf not read yet is read on a worker thread (GLTFDocument, as model_library.gd's Load reads buildings, not
## ResourceLoader's threaded loads, which deadlocked at start: see mesh_for) and this says no until it is in;
## the callers (item_cards.gd, belt_lanes.gd) draw the item meanwhile without its model and look again each frame.
## Zenith's own imported scenes (res://, ResourceLoader) are still read here. 4-14 ms on the main thread each time a
## new item kind came into view on Zenith Test, 24-35 ms on a megabase (R&D run-spikes).
## `--item-models-later=off`: read here at once, as before.
static func ready(item: String) -> bool:
	if not later:
		mesh_for(item)
		return true
	if _packs_version != ModelPacks.version:
		_follow_packs()
	if not _orphans.is_empty():
		for i in range(_orphans.size() - 1, -1, -1):
			if WorkerThreadPool.is_task_completed(_orphans[i]):
				WorkerThreadPool.wait_for_task_completion(_orphans[i])
				_orphans.remove_at(i)
	if _all_ready.has(item):
		return true
	var all := true
	for v in maxi(variant_count(item), 1):
		if not _ready_key(item, v):
			all = false
	if all:
		_all_ready[item] = true
	return all


## --item-models-later=off: item models read on the main thread when first asked for (ready, mesh_for).
static var later := Switches.on("--item-models-later")
## Reads on worker threads: key -> [task id, [mesh], path, is_pbr].
static var _jobs := {}
## Models read on a worker so far (for tests and probes).
static var reads_later := 0
## Items whose model and variants are all in (ready()'s answer without asking the packs again); emptied with the cache.
static var _all_ready := {}
## Worker reads overtaken by a read on the main thread (mesh_for): their tasks, waited for once finished.
static var _orphans: Array[int] = []


static func _ready_key(item: String, v: int) -> bool:
	var key := item if v <= 0 else "%s#%d" % [item, v]
	if _cache.has(key):
		return true
	var path := ModelPacks.item_model_path(item, v) if item != "" else ""
	var is_pbr := ModelPacks.pbr(path) if path != "" else false
	if path == "" or _main_only(path, is_pbr):
		mesh_for(item, v)
		return true
	var job: Array = _jobs.get(key, [])
	if job.is_empty():
		var holder := [null]
		var owns := ModelPacks.owns(path)
		var fn := func() -> void: holder[0] = _read_gltf(path, is_pbr, owns)
		_jobs[key] = [WorkerThreadPool.add_task(fn, false, "item model " + key), holder, path, is_pbr]
		return false
	if not WorkerThreadPool.is_task_completed(int(job[0])):
		return false
	_finish_job(key)
	return _cache.has(key)


## Waits for every read still on a worker (quit: Godot crashes on its way out with a task still running,
## as main.gd's _exit_tree says of the packs' unpacking). Their results are dropped. A read's mesh calls
## wait for the main thread's rendering server to sync (a frame), so it is synced while waiting: a plain
## wait_for_task_completion here would never return.
static func wait_all() -> void:
	var tasks: Array[int] = []
	for key: String in _jobs.keys():
		tasks.append(int((_jobs[key] as Array)[0]))
	tasks.append_array(_orphans)
	_jobs.clear()
	_orphans.clear()
	var t0 := Time.get_ticks_msec()
	for task in tasks:
		while not WorkerThreadPool.is_task_completed(task) and Time.get_ticks_msec() - t0 < 10000:
			RenderingServer.force_sync()
			OS.delay_msec(1)
		if WorkerThreadPool.is_task_completed(task):
			WorkerThreadPool.wait_for_task_completion(task)
		else:
			push_warning("[items] an item model's read still running at quit: not waited for")


## A worker's read is done: its mesh cached, unless the packs gave the item another file meanwhile (read again then,
## when next asked for) or it was read on the main thread meanwhile.
static func _finish_job(key: String) -> void:
	var job: Array = _jobs[key]
	_jobs.erase(key)
	WorkerThreadPool.wait_for_task_completion(int(job[0]))
	if _cache.has(key):
		return
	var at := key.rfind("#")
	var path := ModelPacks.item_model_path(key, 0) if at < 0 else ModelPacks.item_model_path(key.substr(0, at), int(key.substr(at + 1)))
	if path != str(job[2]) or (ModelPacks.pbr(path) if path != "" else false) != bool(job[3]):
		return
	_cache[key] = job[1][0]
	_paths[key] = path
	_pbrs[key] = bool(job[3])
	reads_later += 1
	print_verbose("[items] %s read on a worker" % key)



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
		if has_tangents(mesh):
			m.set_shader_parameter("use_tangent", true)


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
		var share := Looks.pbr_metal_arg(Switches.args())
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
