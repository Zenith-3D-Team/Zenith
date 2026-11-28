extends RefCounted
## A mesh's arrays and a texture's picture from the CPU copies the loaders keep, without asking the
## RenderingServer: `Mesh.surface_get_arrays` and `Texture2D.get_image` read them back from the renderer,
## and with "Render on a separate thread" every such read makes the main thread wait for the render thread's
## whole frame (10-15 ms, perf-rd-render). Falls back to the renderer's copy when no CPU copy was kept.
## `--render-reads=old`: always read from the renderer, as before.

const Switches := preload("res://scripts/switches.gd")
## Meta on an ArrayMesh with its surfaces' arrays (ModelLods.ARRAYS_META, item_models.gd's too).
const ARRAYS_META := &"f3d_arrays"
## Meta on a texture with its picture (ItemIcons.CPU_IMAGE_META, item_models.gd's IMAGE_META).
const IMAGE_META := &"f3d_cpu_image"

static var old := Switches.has("--render-reads=old")
## How often each fell back to the renderer (tests; counted only when not `old`).
static var fallbacks := {"arrays": 0, "image": 0}


## Surface `i`'s arrays, read-only: shared with the mesh's CPU copy (duplicate what you change, the
## packed arrays inside too).
static func arrays(mesh: Mesh, i: int) -> Array:
	if not old and mesh.has_meta(ARRAYS_META):
		var kept: Variant = mesh.get_meta(ARRAYS_META)
		if kept is Array and i < (kept as Array).size() and (kept as Array)[i] is Array:
			return (kept as Array)[i]
	if not old:
		fallbacks["arrays"] = int(fallbacks["arrays"]) + 1
	return mesh.surface_get_arrays(i)


## Surface `i`'s vertex positions (read-only, shared like arrays()).
static func vertices(mesh: Mesh, i: int) -> PackedVector3Array:
	var a := arrays(mesh, i)
	return a[Mesh.ARRAY_VERTEX] if a.size() > Mesh.ARRAY_VERTEX and a[Mesh.ARRAY_VERTEX] is PackedVector3Array else PackedVector3Array()


## Surface `i`'s triangle count. An ArrayMesh knows its index and vertex counts on the scene side (no
## renderer read); other meshes read their arrays.
static func triangles(mesh: Mesh, i: int) -> int:
	if not old and mesh is ArrayMesh:
		var am := mesh as ArrayMesh
		if am.surface_get_primitive_type(i) == Mesh.PRIMITIVE_TRIANGLES:
			var n := am.surface_get_array_index_len(i)
			return (n if n > 0 else am.surface_get_array_len(i)) / 3
	var a := arrays(mesh, i)
	var idx: Variant = a[Mesh.ARRAY_INDEX]
	if idx is PackedInt32Array and not (idx as PackedInt32Array).is_empty():
		return (idx as PackedInt32Array).size() / 3
	if a[Mesh.ARRAY_VERTEX] is PackedVector3Array:
		return (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return 0


## A texture's picture: its kept CPU copy (shared: duplicate before changing it), else the renderer's.
static func image(tex: Texture2D) -> Image:
	if tex == null:
		return null
	if not old and tex.has_meta(IMAGE_META):
		var kept: Variant = tex.get_meta(IMAGE_META)
		if kept is Image:
			return kept
	if not old:
		fallbacks["image"] = int(fallbacks["image"]) + 1
	return tex.get_image()
