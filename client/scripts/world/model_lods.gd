extends RefCounted
## Levels of detail for the models in chunks (chunk_view.gd), made on worker threads:
##
## - A shadow stand-in per model: the same shape welded to bare positions, with Godot's automatic
##   LODs, drawn only into the sun's shadow map. The shadow pass drew every caster in view about
##   four times (once per shadow split): on a 20,000-entity base 20 million triangles a frame
##   against 0.5 million in the view itself.
## - Levels of the model itself, as shipped games switch them: each surface simplified as welded
##   positions (its faces are split by part colours and hard edges, which left Godot's own
##   simplifier nothing to merge), every corner of a simplified triangle taking the model's own vertex
##   there whose normal fits the triangle best. A simplification is kept only if it keeps the
##   surface's silhouette and every part big enough to see where it would be drawn (thin poles,
##   bands, arms), and a level only if it adds no coplanar faces (z-fighting) to the model. Up to
##   MAX_LEVELS whole meshes come of it, each with its own compact vertex data, and each chunk picks
##   one per model itself (chunk_view.gd update_lods): by the size of a screen pixel at the chunk's
##   nearest point (camera distance, field of view, window height), against Settings > Graphics >
##   Level of detail's pixels of error, with HYSTERESIS so a level doesn't pop back and forth at one
##   distance, and a dithered cross-fade over FADE_SECONDS. Godot's own mesh LODs did none of that
##   (a whole chunk's instances popped at once, at the same distance either way). The chunk's
##   MultiMesh keeps its instances and only its mesh changes, so machines' states and moving parts
##   (instance data, parts drawn whole) stay in step whatever level the body is at.
##
## Modellers' textured models (their own base colour texture: models/ or FUE5's) are simplified
## differently, as engines simplify textured meshes: welding positions alone joined vertices across
## UV seams, so a simplified corner took one side's UV and the texture smeared over the other's
## faces (a modeller's belts and splitters went flat and muddy one level down). Their surfaces go to
## Godot's simplifier as they are, with their UVs: it keeps vertices of different UVs or normals
## (TEXTURED_MERGE_ANGLE) apart, so seams and hard edges stay, and every LOD index is a vertex of the
## model's own, its UV and material with it. They keep more (TEXTURED_FLOORS) and switch only once the
## model is small on screen (TEXTURED_PIXELS) as well as within the error allowed.
##
## Welding and simplifying take up to ~25 ms a model, the checks about as much again; until a
## model's job is done its chunks draw it whole and it casts its own shadow.

const Switches := preload("res://scripts/switches.gd")

## --tree-shadow-decimate=off: keep all non-core leaf cards in tree shadow stand-ins (50% decimation off).
static var tree_shadow_decimate: bool:
	get:
		return Job.decimate_cards
	set(v):
		Job.decimate_cards = v
## Surfaces smaller than this keep their own shadow and get no LODs: they would save next to nothing.
const MIN_TRIANGLES := 200
## Jobs at once (terrain meshing shares the worker pool).
const JOBS := 2
## Simplified versions kept per surface, finest first.
const MAX_LODS := 4
## Levels a model gets (besides itself): each at least LEVEL_STEP times the error of the one before
## and with at least LEVEL_SAVING fewer triangles, so a switch is worth its pop.
const MAX_LEVELS := 3
const LEVEL_STEP := 2.0
const LEVEL_SAVING := 0.2
## A coarser level is taken once its error is this much inside what the view allows, a finer one as
## soon as the coarser's error isn't: about 20% of the distance between switching in and out.
const HYSTERESIS := 1.2
## Seconds a level switch cross-fades (a screen-door dither, factorio_material.gdshaderinc
## f3d_lod_fade).
const FADE_SECONDS := 0.3
## Silhouette and thin parts: a simplification must keep every connected part at least
## KEEP_PARTS times its error long, and each part's (and the surface's) bounds within
## BOUNDS_SLACK times its error.
const KEEP_PARTS := 3.0
const BOUNDS_SLACK := 1.5
## Coplanar faces: within this distance (tiles) of the same plane; a level may have up to
## COPLANAR_SHARE more overlap than the model itself has, plus this (square tiles).
const COPLANAR_EPS := 0.003
const COPLANAR_SLACK := 0.0005
const COPLANAR_SHARE := 0.1
## Textured models: far-only LODs (TEXTURED_PIXELS) keep UV seams locked, so simplifying across
## many UV charts adds tiny sub-pixel seam slivers; allow up to this share of total surface area.
const TEXTURED_COPLANAR_AREA := 0.003
## Textured models: vertices whose normals differ by more than this (degrees) stay apart (hard edges).
const TEXTURED_MERGE_ANGLE := 60.0
## Textured models: the least share of the model's triangles each level keeps (so at most this many
## levels); a surface's simplification under the last share isn't used at all.
const TEXTURED_FLOORS := [0.3, 0.15]
## Textured models: each level is drawn only once the model's longest side is at most this many
## pixels on screen (counted against Level of detail's pixels of error: lod_threshold 1 is High).
const TEXTURED_PIXELS := [64.0, 32.0]
## High-triangle textured models (FUE5's ~10k-tri buildings): allow a third level down to 7%
## and pick switch size from triangle density (~4 sq px per triangle, capped at TEXTURED_MAX_PIXELS
## so close-up models stay whole). --textured-lod=legacy restores fixed [64, 32] px and [0.3, 0.15].
const TEXTURED_DENSE_TRIS := 5000
const TEXTURED_DENSE_FLOORS := [0.3, 0.15, 0.07]
const TEXTURED_DENSE_PIXELS := [64.0, 32.0, 16.0]
const TEXTURED_PX_PER_TRI := 4.0
const TEXTURED_MAX_PIXELS := 256.0
static var textured_density_lod := not (Switches.has("--textured-lod=legacy"))
## Heavy models (assembler 13.9k triangles, beacon 9.9k, roboport 9.8k, medium pole 2.5k): each
## level's switch error is divided by sqrt(triangles / HEAVY_REF_TRIS), at most HEAVY_MAX_SCALE, so
## the model drops to its lighter levels at a smaller size on screen (up close it is unchanged:
## a model under HEAVY_REF_TRIS has no change). --heavy-lods=off keeps the old thresholds.
const HEAVY_REF_TRIS := 1000.0
const HEAVY_MAX_SCALE := 3.5
## Textured models of at least this many triangles get a fourth, coarsest level (3% of the
## triangles, switched in at a sixth of the first level's size, like the others by density).
const HEAVY_EXTRA_TRIS := 8000
const HEAVY_EXTRA_FLOOR := 0.03
const HEAVY_EXTRA_PIXELS := 8.0
static var heavy_lods: bool:
	get:
		return Job.heavy
	set(v):
		Job.heavy = v
## Card-level view LODs for trees: drop whole leaf cards evenly across the crown and scale the
## surviving ones about their own centres so normals and lighting stay steady without flicker.
## Each entry is [keep every Nth card, scale factor, High pixel switch height, Med/Low pixel floor,
## bark/core max error share of longest side].
## --tree-lod=off keeps tree crowns whole in view as before.
const TREE_LOD_TIERS := [
	[2, 1.25, 190.0, 260.0, 0.08],
	[4, 1.45, 100.0, 150.0, 0.15],
	[8, 1.65, 55.0, 85.0, 0.25],
]
const TREE_MIN_CARDS := 8
static var tree_lods := Switches.on("--tree-lod")
## The custom channel formats in a surface's format, which add_surface_from_arrays needs again.
const CUSTOM_FORMATS := 0xFFF << Mesh.ARRAY_FORMAT_CUSTOM_BASE
## Meta on an ArrayMesh holding its surfaces' arrays on the CPU (model_library.gd keeps them):
## Mesh.surface_get_arrays reads them back from the GPU, which stalls the frame.
const ARRAYS_META := &"f3d_arrays"
## Meta on a model's merged material: its rows' materials (material_rows.gd).
const ROWS_META := &"f3d_rows"
const ROW_EDITED_META := &"f3d_row_edited"
## The leaf cards' shader (model_library.gd): a tree's crown, which casts its own stand-in (crown_arrays).
const LeafShader := preload("res://shaders/factorio_material_leaf.gdshader")


## A surface's arrays, from the CPU copy when the mesh has one: a deep copy, safe to change (the
## packed arrays inside an Array are shared, not copied, when it is duplicated shallowly).
static func arrays_of(mesh: Mesh, i: int) -> Array:
	if mesh.has_meta(ARRAYS_META):
		var kept: Array = mesh.get_meta(ARRAYS_META)
		if i < kept.size():
			return (kept[i] as Array).duplicate(true)
	return mesh.surface_get_arrays(i)


static var _uniforms := {}  # Shader -> its uniforms' names


## A copy of a ShaderMaterial, as duplicate() makes it, without duplicate()'s cost: that asks the
## RenderingServer for the shader's parameters and each one's default, which waits for the render
## thread when it runs on its own (seconds over a model's first appearance). The names are asked
## once per shader; unset parameters keep the shader's defaults, as duplicate() copies them.
static func copy_material(source: ShaderMaterial) -> ShaderMaterial:
	var out := ShaderMaterial.new()
	out.resource_name = source.resource_name
	out.shader = source.shader
	out.render_priority = source.render_priority
	out.next_pass = source.next_pass
	# A merged material's rows (a copy of the list: editing the copy's rows leaves the source's),
	# and a row's mark that it was edited (material_rows.gd).
	for meta in [ROWS_META, ROW_EDITED_META]:
		if source.has_meta(meta):
			var value: Variant = source.get_meta(meta)
			out.set_meta(meta, (value as Array).duplicate() if value is Array else value)
	if source.has_meta(&"f3d_belt_reactive_pass"):
		out.set_meta(&"f3d_belt_reactive_pass", source.get_meta(&"f3d_belt_reactive_pass"))
		var ml: GDScript = load("res://scripts/world/model_library.gd")
		if ml != null:
			ml.register_belt_reactive_mat(out)
	if source.shader == null:
		return out
	if not _uniforms.has(source.shader):
		var names := PackedStringArray()
		for u: Dictionary in source.shader.get_shader_uniform_list():
			names.append(str(u["name"]))
		_uniforms[source.shader] = names
	for name: String in _uniforms[source.shader]:
		var value: Variant = source.get_shader_parameter(name)
		if value != null:
			out.set_shader_parameter(name, value)
	return out


class Job:
	## Per surface of the source mesh: [vertices, normals or null, indices or null, material rows or
	## null, all its arrays (for the levels; null for view LODs only)].
	var surfaces: Array = []
	## Whether to make LODs for the source mesh's own surfaces too.
	var view_lods := true
	## Whether to make the shadow stand-in (off: only the view LODs, see request_view_lods).
	var proxy := true
	## The stand-in without LODs of its own: a tree's crown is separate leaf cards, and the first
	## LOD step kept only 13-24% of Nauvis trees' crowns (seen from above), so trees a little way
	## off cast a trunk's shadow and no crown's (owner: "some trees have no shadows").
	var proxy_lods := true
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	## LOD size -> indices (ImporterMesh's LODs, for ArrayMesh.add_surface_from_arrays).
	var lods := {}
	## Per source surface: its LODs in its own vertices (empty: none).
	var surface_lods: Array = []
	## The model's levels, coarser in turn: [error in tiles, [per surface: its arrays, compacted]].
	var levels: Array = []
	var levels_done := false
	## A model with its own textures: its surfaces simplified with their UVs (see the header).
	var textured := false
	var density_lod := true
	## A tree's crown (its surfaces in the leaf cards' shader, by index in `surfaces`; their own
	## leaf_core flag): cast by the stand-in's second surface, which drops what pollution took
	## (crown_arrays, shadow_stand_in_leaf.gdshader). Welded in with the wood, a bare tree cast its
	## whole crown's shadow.
	var crown: Dictionary = {}
	var crown_vertices := PackedVector3Array()
	var crown_uvs := PackedVector2Array()
	## A tree with leaf cards: its view levels drop whole cards instead of welding them (tree_levels).
	var tree_cards := false
	## True once run() finished (poll uses this to dispatch run_levels even when surface_lods are all empty).
	var proxy_done := false

	func run() -> void:
		if not proxy:
			for s in surfaces:
				surface_lods.append(ModelLodsMath.surface_lods(s[0], s[1], s[2], s[3]))
			return
		var wood: Array = []
		for i in surfaces.size():
			if crown.has(i):
				crown_arrays(surfaces[i][4], bool(crown[i]), crown_vertices, crown_uvs)
			else:
				wood.append(surfaces[i])
		if wood.is_empty():
			proxy_done = true
			return
		var welded := ModelLodsMath.weld(wood)
		vertices = welded[0]
		indices = welded[1]
		var sign := 1.0
		for s in surfaces:
			sign = ModelLodsMath.winding(s[0], s[1], s[2])
			break
		normals = ModelLodsMath.smooth_normals(vertices, indices, sign)
		var simplified := ModelLodsMath.simplify(vertices, normals, indices)
		indices = simplified[0]
		lods = simplified[1] if proxy_lods else {}
		if not view_lods:
			proxy_done = true
			return
		var total_tris := 0
		for s in surfaces:
			total_tris += (s[2] as PackedInt32Array).size() / 3 if s[2] != null else (s[0] as PackedVector3Array).size() / 3
		var min_floor := float(TEXTURED_DENSE_FLOORS[-1]) if (textured and density_lod and total_tris >= TEXTURED_DENSE_TRIS) else float(TEXTURED_FLOORS[-1])
		if textured and density_lod and Job.heavy and total_tris >= HEAVY_EXTRA_TRIS:
			min_floor = HEAVY_EXTRA_FLOOR
		for i in surfaces.size():
			var s: Array = surfaces[i]
			if tree_cards and crown.has(i) and not bool(crown[i]):
				surface_lods.append({})
				continue
			var uv: Variant = (s[4] as Array)[Mesh.ARRAY_TEX_UV] if textured and s.size() > 4 else null
			surface_lods.append(ModelLodsMath.surface_lods(s[0], s[1], s[2], s[3], uv, min_floor))
		proxy_done = true

	## The second step (poll queues it once the stand-in is shown, so shadows don't wait for it):
	## the model's levels, which take longer than the rest (the coplanar checks).
	func run_levels() -> void:
		if tree_cards:
			levels = ModelLodsMath.tree_levels(surfaces, surface_lods, crown)
		else:
			levels = ModelLodsMath.levels(surfaces, surface_lods, textured, density_lod)
		levels_done = true

	## How much of a leaf card's square its shadow covers: the round spray leaf_cut casts
	## (factorio_material.gdshaderinc, in the shadow pass: radius 0.78-0.96 of the half side, about
	## 0.59 of the square's area) as a square of the same area.
	const CARD_SHADOW := 0.77
	const CARD_SHADOW_DECIMATED := 0.985
	static var heavy := Switches.on("--heavy-lods")
	static var decimate_cards := Switches.on("--tree-shadow-decimate")

	## A crown surface's triangles for its shadow stand-in (Job.run, on a worker): their positions, a
	## card's corners drawn in to CARD_SHADOW of the way from its middle, and per vertex (the card's
	## seed, its kind) for shadow_stand_in_leaf.gdshader: 0 a leaf card, 1 a crown's core (UV -1, or a
	## surface whose material says leaf_core: `all_core`), 2 solid leaves (UV -2: tree-06's strands).
	static func crown_arrays(arrays: Array, all_core: bool, out_v: PackedVector3Array, out_uv: PackedVector2Array) -> void:
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uvs := PackedVector2Array()
		if arrays[Mesh.ARRAY_TEX_UV] != null:
			uvs = arrays[Mesh.ARRAY_TEX_UV]
		var seeds := PackedVector2Array()
		if arrays[Mesh.ARRAY_TEX_UV2] != null:
			seeds = arrays[Mesh.ARRAY_TEX_UV2]
		var index := PackedInt32Array()
		if arrays[Mesh.ARRAY_INDEX] != null:
			index = arrays[Mesh.ARRAY_INDEX]
		else:
			for i in verts.size():
				index.append(i)
		var card_tri := 0
		var scale := CARD_SHADOW_DECIMATED if decimate_cards else CARD_SHADOW
		for t in range(0, index.size() - 2, 3):
			var k := [index[t], index[t + 1], index[t + 2]]
			var kind := 1.0 if all_core else 0.0
			if not all_core and uvs.size() == verts.size():
				var u0: float = uvs[k[0]].x
				kind = 2.0 if u0 < -1.5 else (1.0 if u0 < -0.5 else 0.0)
			if kind == 0.0:
				var card_id := card_tri / 2
				card_tri += 1
				if decimate_cards and (card_id & 1) == 1:
					continue
			var seed: float = seeds[k[0]].y if seeds.size() == verts.size() else 0.0
			var p := [verts[k[0]], verts[k[1]], verts[k[2]]]
			if kind == 0.0 and uvs.size() == verts.size():
				# The card's middle from the triangle's map of UV to position (p = middle + (u - 0.5) X + (v - 0.5) Y).
				var e1: Vector3 = p[1] - p[0]
				var e2: Vector3 = p[2] - p[0]
				var d1: Vector2 = uvs[k[1]] - uvs[k[0]]
				var d2: Vector2 = uvs[k[2]] - uvs[k[0]]
				var det := d1.x * d2.y - d1.y * d2.x
				if absf(det) > 1e-8:
					var ax := (e1 * d2.y - e2 * d1.y) / det
					var ay := (e2 * d1.x - e1 * d2.x) / det
					var uv0: Vector2 = uvs[k[0]]
					var middle: Vector3 = p[0] - ax * (uv0.x - 0.5) - ay * (uv0.y - 0.5)
					for c in 3:
						p[c] = middle + (p[c] - middle) * scale
			for c in 3:
				out_v.append(p[c])
				out_uv.append(Vector2(seed, kind))


## The arithmetic, apart so the jobs above read plainly. Static: it runs on worker threads.
class ModelLodsMath:
	## [welded vertices, indices into them, original vertex -> welded] for surfaces of
	## [vertices, normals, indices or null]. `rows` (a merged surface's material row per vertex,
	## material_rows.gd) keeps vertices of different materials apart, so simplifying moves no
	## material's border into another's, as when each material was a surface of its own.
	static func weld(surfaces: Array, rows: Variant = null) -> Array:
		var weld_of := {}
		var verts := PackedVector3Array()
		var idx := PackedInt32Array()
		var remap := PackedInt32Array()
		var by_row := rows is PackedFloat32Array and not (rows as PackedFloat32Array).is_empty()
		for s in surfaces:
			var src: PackedVector3Array = s[0]
			var local := PackedInt32Array()
			local.resize(src.size())
			for k in src.size():
				var key: Variant = Vector3i((src[k] * 1024.0).round())
				if by_row:
					var at3: Vector3i = key
					key = Vector4i(at3.x, at3.y, at3.z, int(rows[k]))
				var at: int = weld_of.get(key, -1)
				if at < 0:
					at = verts.size()
					weld_of[key] = at
					verts.append(src[k])
				local[k] = at
			remap.append_array(local)
			if s[2] == null:
				for k in src.size():
					idx.append(local[k])
			else:
				for k in (s[2] as PackedInt32Array):
					idx.append(local[k])
		return [verts, idx, remap]

	## +1 when a triangle's (b - a) x (c - a) points the way its vertices' normals do, -1 when
	## against them (Godot's front faces wind clockwise, so imported models give -1).
	static func winding(verts: PackedVector3Array, normals, idx) -> float:
		if not (normals is PackedVector3Array) or (normals as PackedVector3Array).size() != verts.size():
			return -1.0
		var n: PackedVector3Array = normals
		var count := (idx as PackedInt32Array).size() if idx != null else verts.size()
		var total := 0.0
		for t in range(0, mini(count, 3000) - 2, 3):
			var a := t
			var b := t + 1
			var c := t + 2
			if idx != null:
				a = idx[t]
				b = idx[t + 1]
				c = idx[t + 2]
			total += (verts[b] - verts[a]).cross(verts[c] - verts[a]).dot(n[a] + n[b] + n[c])
		return 1.0 if total >= 0.0 else -1.0

	static func smooth_normals(verts: PackedVector3Array, idx: PackedInt32Array, sign := -1.0) -> PackedVector3Array:
		var sums: Array[Vector3] = []
		sums.resize(verts.size())
		sums.fill(Vector3.ZERO)
		for t in range(0, idx.size() - 2, 3):
			var a := verts[idx[t]]
			var face := (verts[idx[t + 1]] - a).cross(verts[idx[t + 2]] - a) * sign
			for k in 3:
				sums[idx[t + k]] += face
		var out := PackedVector3Array()
		out.resize(verts.size())
		for i in verts.size():
			out[i] = sums[i].normalized() if sums[i].length_squared() > 0.0 else Vector3.UP
		return out

	## [indices, {LOD size: indices}] from Godot's simplifier.
	static func simplify(verts: PackedVector3Array, normals: PackedVector3Array, idx: PackedInt32Array) -> Array:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_INDEX] = idx
		var im := ImporterMesh.new()
		im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays)
		im.generate_lods(180.0, 180.0, [])
		var lods := {}
		for l in mini(im.get_surface_lod_count(0), MAX_LODS):
			lods[im.get_surface_lod_size(0, l)] = im.get_surface_lod_indices(0, l)
		return [im.get_surface_arrays(0)[Mesh.ARRAY_INDEX], lods]

	## LODs of one surface in its own vertices: {LOD size: indices}, empty when it is too small.
	## Only those that keep the surface's shape (Parts.kept_by) are kept. `rows`: a merged surface's
	## material row per vertex (weld). `uv`: a textured surface's UVs, simplified with them
	## (textured_lods).
	static func surface_lods(src: PackedVector3Array, src_normals, src_idx, rows: Variant = null, uv: Variant = null, min_floor := -1.0) -> Dictionary:
		var triangles := (src_idx as PackedInt32Array).size() / 3 if src_idx != null else src.size() / 3
		if triangles < MIN_TRIANGLES:
			return {}
		if uv is PackedVector2Array and (uv as PackedVector2Array).size() == src.size():
			return textured_lods(src, src_normals, src_idx, uv, rows, min_floor)
		var welded := weld([[src, src_normals, src_idx]], rows)
		var verts: PackedVector3Array = welded[0]
		var remap: PackedInt32Array = welded[2]
		# Each welded vertex's own vertices, to pick from.
		var owners: Array = []
		owners.resize(verts.size())
		for k in remap.size():
			if owners[remap[k]] == null:
				owners[remap[k]] = []
			(owners[remap[k]] as Array).append(k)
		var sign := winding(src, src_normals, src_idx)
		var simplified := simplify(verts, smooth_normals(verts, welded[1], sign), welded[1])
		var out := {}
		var has_normals := src_normals is PackedVector3Array and (src_normals as PackedVector3Array).size() == src.size()
		var parts := Parts.new(verts, welded[1])
		for size in simplified[1]:
			var lod: PackedInt32Array = simplified[1][size]
			if not parts.kept_by(lod, float(size)):
				continue
			var mapped := PackedInt32Array()
			mapped.resize(lod.size())
			for t in range(0, lod.size() - 2, 3):
				var face := (verts[lod[t + 1]] - verts[lod[t]]).cross(verts[lod[t + 2]] - verts[lod[t]]) * sign
				for k in 3:
					var choices: Array = owners[lod[t + k]]
					var best: int = choices[0]
					if has_normals and choices.size() > 1:
						var best_fit := -INF
						for v: int in choices:
							var fit: float = (src_normals as PackedVector3Array)[v].dot(face)
							if fit > best_fit:
								best_fit = fit
								best = v
					mapped[t + k] = best
			out[size] = mapped
		return out

	## A textured surface's LODs, {LOD size: indices into its own vertices}: Godot's simplifier on the
	## surface as it is (UVs, normals), which merges only vertices of one place, UV and normal (within
	## TEXTURED_MERGE_ANGLE), so UV seams and hard edges are kept as edges of their own and each
	## simplified corner is one of the surface's vertices, its UV with it. Material rows are kept
	## apart the same way: each row's UVs are moved apart for the merging only. LODs under the last of
	## TEXTURED_FLOORS, or that lose a part or the silhouette (Parts), are left out.
	static func _textured_im_lods(arrays: Array, merge_angle: float, remap: PackedInt32Array, parts: Parts, least: int) -> Dictionary:
		var im := ImporterMesh.new()
		im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays)
		im.generate_lods(merge_angle, merge_angle, [])
		var out := {}
		for l in im.get_surface_lod_count(0):
			if out.size() >= MAX_LODS:
				break
			var lod := im.get_surface_lod_indices(0, l)
			if lod.size() < maxi(least, 3):
				continue
			var as_welded := PackedInt32Array()
			as_welded.resize(lod.size())
			for k in lod.size():
				as_welded[k] = remap[lod[k]]
			var size := im.get_surface_lod_size(0, l)
			if parts.kept_by(as_welded, size):
				out[size] = lod
		return out

	static func _surface_area(surfaces: Array, indices: Array) -> float:
		var area := 0.0
		for i in surfaces.size():
			var v: PackedVector3Array = surfaces[i][0]
			var idx: PackedInt32Array = indices[i]
			for t in range(0, idx.size() - 2, 3):
				area += (v[idx[t + 1]] - v[idx[t]]).cross(v[idx[t + 2]] - v[idx[t]]).length() * 0.5
		return area

	static func _best_clean_size(surface: Array, lods: Dictionary, full_count: int, first_floor: int, own_limit: float) -> float:
		var best := INF
		var max_count := int(full_count * (1.0 - LEVEL_SAVING))
		for sz in lods:
			var li: PackedInt32Array = lods[sz]
			if li.size() < first_floor or li.size() > max_count:
				continue
			var cov: PackedInt32Array = without_covered([surface], [li])[0]
			if cov.size() < first_floor or cov.size() > max_count:
				continue
			if float(fights([surface], [cov])[0]) <= own_limit and float(sz) < best:
				best = float(sz)
		return best

	static func textured_lods(src: PackedVector3Array, src_normals, src_idx, uv: PackedVector2Array, rows: Variant = null, min_floor := -1.0) -> Dictionary:
		var idx: PackedInt32Array = src_idx if src_idx != null else PackedInt32Array(range(src.size()))
		var normals: PackedVector3Array
		if src_normals is PackedVector3Array and (src_normals as PackedVector3Array).size() == src.size():
			normals = src_normals
		else:
			normals = smooth_normals(src, idx)
		var merge_uv := uv
		if rows is PackedFloat32Array and (rows as PackedFloat32Array).size() == src.size():
			merge_uv = uv.duplicate()
			for k in merge_uv.size():
				merge_uv[k] += Vector2(1000.0 * roundf(rows[k]), 0.0)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = src
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TEX_UV] = merge_uv
		arrays[Mesh.ARRAY_INDEX] = idx
		var welded := weld([[src, src_normals, idx]])
		var remap: PackedInt32Array = welded[2]
		var parts := Parts.new(welded[0], welded[1])
		var floor_share := min_floor if min_floor > 0.0 else float(TEXTURED_FLOORS[-1])
		var least := int(idx.size() * floor_share)
		var out := _textured_im_lods(arrays, TEXTURED_MERGE_ANGLE, remap, parts, least)
		var first_floor := maxi(int(idx.size() * float(TEXTURED_FLOORS[0])), 3)
		var surf := [src, src_normals, idx, rows]
		var own_limit := float(fights([surf], [idx])[0]) * (1.0 + COPLANAR_SHARE) + COPLANAR_SLACK + _surface_area([surf], [idx]) * TEXTURED_COPLANAR_AREA
		var best_sz := _best_clean_size(surf, out, idx.size(), first_floor, own_limit)
		if best_sz > 0.5 or out.size() < 2:
			# Hard-edged CAD/STL textured meshes (e.g. Wube3DP, baked Placeholders) can lock
			# most vertices across 90-degree creases at TEXTURED_MERGE_ANGLE; try wider normal
			# merge angles (still keeping UV islands and material rows strictly apart via
			# ARRAY_TEX_UV) and only adopt one that passes the coplanar overlap check cleanly.
			for angle: float in [75.0, 95.0, 120.0, 180.0]:
				var cand := _textured_im_lods(arrays, angle, remap, parts, least)
				var cand_sz := _best_clean_size(surf, cand, idx.size(), first_floor, own_limit)
				if cand_sz < best_sz:
					out = cand
					best_sz = cand_sz
					if best_sz <= 0.25 and out.size() >= 2:
						break
		return out

	## The model's levels from its surfaces' LODs (surface_lods): for each level's error, every
	## surface at its coarsest LOD within it, less the faces lying under others in their plane. A
	## level still with more coplanar faces than the model has those surfaces put back to the level
	## before, and is dropped if that doesn't clear them or leaves too little saved. A textured
	## model's levels keep TEXTURED_FLOORS of its triangles.
	## [[error, [arrays per surface, compacted], tiles a pixel may be at most (0: any)], ...], finest first.
	static func levels(surfaces: Array, per_surface: Array, textured := false, density_lod := true) -> Array:
		var sizes: Array = []
		for lods: Dictionary in per_surface:
			for size in lods:
				sizes.append(float(size))
		if sizes.is_empty():
			return []
		sizes.sort()
		var full: Array = []
		var full_count := 0
		var lo := Vector3(INF, INF, INF)
		var hi := -lo
		for s in surfaces:
			full.append(_indices_of(s))
			full_count += (full[-1] as PackedInt32Array).size()
			for p: Vector3 in (s[0] as PackedVector3Array):
				lo = lo.min(p)
				hi = hi.max(p)
		var longest := maxf((hi - lo)[(hi - lo).max_axis_index()], 0.0) if lo.x <= hi.x else 0.0
		var base: float = fights(surfaces, full)[0]
		# Faces a model already has over each other (most are its own, partly overlapping) are simplified
		# with it, a little more or less: what counts is overlap the level adds beyond that.
		var base_fight := base * (1.0 + COPLANAR_SHARE)
		var coplanar_limit := base_fight + COPLANAR_SLACK + (_surface_area(surfaces, full) * TEXTURED_COPLANAR_AREA if textured else 0.0)
		var own_fights := {}  # surface -> the overlap of its own faces in the model (textured only)
		var dense_tex := textured and density_lod and (full_count / 3) >= TEXTURED_DENSE_TRIS
		var tex_floors: Array = TEXTURED_DENSE_FLOORS if dense_tex else TEXTURED_FLOORS
		var tex_pixels: Array = TEXTURED_DENSE_PIXELS if dense_tex else TEXTURED_PIXELS
		if dense_tex and Job.heavy and (full_count / 3) >= HEAVY_EXTRA_TRIS:
			tex_floors = tex_floors + [HEAVY_EXTRA_FLOOR]
			tex_pixels = tex_pixels + [HEAVY_EXTRA_PIXELS]
		var out: Array = []
		var previous: Array = full.duplicate()
		var previous_count := full_count
		var last_error := 0.0
		for error: float in sizes:
			if out.size() >= (tex_floors.size() if textured else MAX_LEVELS):
				break
			if last_error > 0.0 and error < last_error * LEVEL_STEP:
				continue
			var chosen := _chosen(previous, per_surface, error)
			if _count(chosen) > previous_count * (1.0 - LEVEL_SAVING):
				continue
			chosen = without_covered(surfaces, chosen)
			var fight := fights(surfaces, chosen)
			if float(fight[0]) > coplanar_limit and textured:
				# A textured surface keeps its UV seams, so its simplifications fold more faces onto
				# others: each surface found takes its coarsest LOD within the error that adds none
				# of its own, before the whole is looked at again.
				for i: int in fight[1]:
					chosen[i] = _without_own_fights(surfaces[i], per_surface[i], previous[i], error, own_fights, i)
				fight = fights(surfaces, chosen)
				if _count(chosen) > previous_count * (1.0 - LEVEL_SAVING):
					continue
			if float(fight[0]) > coplanar_limit:
				for i: int in fight[1]:
					chosen[i] = previous[i]
				if float(fights(surfaces, chosen)[0]) > coplanar_limit or _count(chosen) > previous_count * (1.0 - LEVEL_SAVING):
					continue
			var pixel := 0.0
			if textured:
				# Coarser errors only take more away: the first under its floor ends the levels.
				if _count(chosen) < full_count * float(tex_floors[out.size()]):
					break
				var base_px := float(tex_pixels[out.size()])
				var target_px := base_px
				if dense_tex:
					var density_px := sqrt((float(previous_count) / 3.0) * TEXTURED_PX_PER_TRI)
					target_px = clampf(maxf(base_px, density_px), base_px, TEXTURED_MAX_PIXELS)
				pixel = longest / target_px
			var arrays: Array = []
			for i in surfaces.size():
				arrays.append(compact(surfaces[i][4], chosen[i]))
			out.append([error, arrays, pixel])
			previous = chosen
			previous_count = _count(chosen)
			last_error = error
		return out

	## A textured surface's coarsest LOD within `error` whose faces overlap no more among themselves
	## than the model's do (less those lying under others), else `before`. `own` caches each
	## surface's own overlap in the model.
	static func _without_own_fights(surface: Array, lods: Dictionary, before: PackedInt32Array, error: float, own: Dictionary, i: int) -> PackedInt32Array:
		if not own.has(i):
			var full_i := _indices_of(surface)
			own[i] = float(fights([surface], [full_i])[0]) * (1.0 + COPLANAR_SHARE) + COPLANAR_SLACK + _surface_area([surface], [full_i]) * TEXTURED_COPLANAR_AREA
		var sizes: Array = []
		for size in lods:
			if float(size) <= error and (lods[size] as PackedInt32Array).size() < before.size():
				sizes.append(float(size))
		sizes.sort()
		sizes.reverse()
		for size: float in sizes:
			var idx: PackedInt32Array = without_covered([surface], [lods[size]])[0]
			if float(fights([surface], [idx])[0]) <= float(own[i]):
				return idx
		return before

	## Each surface's coarsest LOD within `error`, or what it had before.
	static func _chosen(previous: Array, per_surface: Array, error: float) -> Array:
		var chosen: Array = []
		for i in previous.size():
			var idx: PackedInt32Array = previous[i]
			var best := -1.0
			for size in per_surface[i]:
				if float(size) <= error and float(size) > best:
					best = float(size)
					idx = per_surface[i][size]
			chosen.append(idx)
		return chosen

	static func _count(indices: Array) -> int:
		var n := 0
		for idx: PackedInt32Array in indices:
			n += idx.size()
		return n

	static func _indices_of(s: Array) -> PackedInt32Array:
		if s[2] != null:
			return s[2]
		var idx := PackedInt32Array()
		idx.resize((s[0] as PackedVector3Array).size())
		for k in idx.size():
			idx[k] = k
		return idx

	## `indices` without the faces fights() finds lying wholly under another facing the same way in
	## their plane: the one over them already draws there, and two there z-fight.
	static func without_covered(surfaces: Array, indices: Array) -> Array:
		var covered: Dictionary = fights(surfaces, indices)[2]
		if covered.is_empty():
			return indices
		var out: Array = []
		for i in indices.size():
			var idx: PackedInt32Array = indices[i]
			var drop: Dictionary = covered.get(i, {})
			if drop.is_empty():
				out.append(idx)
				continue
			var kept := PackedInt32Array()
			for t in range(0, idx.size() - 2, 3):
				if not drop.has(t):
					kept.append_array([idx[t], idx[t + 1], idx[t + 2]])
			out.append(kept)
		return out

	## [square tiles of faces overlapping others in their plane (within COPLANAR_EPS, facing either
	## way), {surface index: true} for the surfaces those faces are on, {surface index: {first index
	## of a face: true}} for faces wholly under another facing the same way] for these surfaces drawn
	## with these indices. Faces are bucketed by plane, so only faces in one plane are compared.
	static func fights(surfaces: Array, indices: Array) -> Array:
		var buckets := {}
		var tris: Array = []  # [a, b, c, normal, area, surface, first index, facing flipped]
		for i in surfaces.size():
			var v: PackedVector3Array = surfaces[i][0]
			var idx: PackedInt32Array = indices[i]
			for t in range(0, idx.size() - 2, 3):
				var a := v[idx[t]]
				var b := v[idx[t + 1]]
				var c := v[idx[t + 2]]
				var n := (b - a).cross(c - a)
				var area := n.length() * 0.5
				if area < 1e-6:
					continue
				n = n.normalized()
				# One orientation per plane: a back face fights the front one it lies on too.
				var flipped := n.x < -1e-6 or (absf(n.x) <= 1e-6 and (n.y < -1e-6 or (absf(n.y) <= 1e-6 and n.z < 0.0)))
				if flipped:
					n = -n
				var key := Vector4i(roundi(n.x * 50.0), roundi(n.y * 50.0), roundi(n.z * 50.0), roundi(n.dot(a) / COPLANAR_EPS))
				if not buckets.has(key):
					buckets[key] = []
				(buckets[key] as Array).append(tris.size())
				tris.append([a, b, c, n, area, i, t, flipped])
		var total := 0.0
		var on := {}
		var covered := {}
		for key: Vector4i in buckets:
			var here: Array = buckets[key]
			var next: Variant = buckets.get(Vector4i(key.x, key.y, key.z, key.w + 1))
			var cand: Array = here + (next as Array) if next != null else here
			if cand.size() < 2:
				continue
			# A big flat face cut into many triangles shares no area among them: the pairs looked at
			# are capped.
			for p in mini(here.size(), 256):
				var ti: Array = tris[here[p]]
				for q in range(p + 1, mini(cand.size(), 256)):
					var tj: Array = tris[cand[q]]
					if absf((tj[3] as Vector3).dot(tj[0]) - (ti[3] as Vector3).dot(ti[0])) >= COPLANAR_EPS:
						continue
					if _overlap(ti, tj):
						total += minf(ti[4], tj[4])
						on[ti[5]] = true
						on[tj[5]] = true
						if ti[7] == tj[7]:
							var small: Array = ti if float(ti[4]) <= float(tj[4]) else tj
							var big: Array = tj if small == ti else ti
							if not _is_covered(covered, big) and _within(small, big):
								if not covered.has(small[5]):
									covered[small[5]] = {}
								covered[small[5]][small[6]] = true
		return [total, on, covered]

	static func _is_covered(covered: Dictionary, t: Array) -> bool:
		return covered.has(t[5]) and (covered[t[5]] as Dictionary).has(t[6])

	## Whether face `a` lies wholly inside face `b` (its corners, pulled in a little, and middle).
	static func _within(a: Array, b: Array) -> bool:
		var centre: Vector3 = ((a[0] as Vector3) + (a[1] as Vector3) + (a[2] as Vector3)) / 3.0
		for k in 4:
			var p: Vector3 = centre if k == 3 else (a[k] as Vector3) * 0.9 + centre * 0.1
			if not _inside(p, b[0], b[1], b[2]):
				return false
		return true

	## Whether two faces in one plane overlap (not just touch): a point well inside one is inside the other.
	static func _overlap(ti: Array, tj: Array) -> bool:
		for pair in [[ti, tj], [tj, ti]]:
			var a: Array = pair[0]
			var b: Array = pair[1]
			var centre: Vector3 = ((a[0] as Vector3) + (a[1] as Vector3) + (a[2] as Vector3)) / 3.0
			for k in 4:
				var p: Vector3 = centre if k == 3 else (a[k] as Vector3) * 0.6 + centre * 0.4
				if _inside(p, b[0], b[1], b[2]):
					return true
		return false

	static func _inside(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> bool:
		var v0 := c - a
		var v1 := b - a
		var v2 := p - a
		var d00 := v0.dot(v0)
		var d01 := v0.dot(v1)
		var d11 := v1.dot(v1)
		var den := d00 * d11 - d01 * d01
		if absf(den) < 1e-14:
			return false
		var u := (d11 * v0.dot(v2) - d01 * v1.dot(v2)) / den
		var w := (d00 * v1.dot(v2) - d01 * v0.dot(v2)) / den
		return u > 0.02 and w > 0.02 and u + w < 0.98

	## A surface's arrays with only the vertices `idx` uses, `idx` renumbered to them: a level's own
	## small vertex buffer rather than the whole model's again.
	static func compact(arrays: Array, idx: PackedInt32Array) -> Array:
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
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
		var out := []
		out.resize(Mesh.ARRAY_MAX)
		_copy_attributes(arrays, count, used, out)
		out[Mesh.ARRAY_INDEX] = out_idx
		return out

	static func _copy_attributes(arrays: Array, count: int, used: PackedInt32Array, out: Array) -> void:
		for a in Mesh.ARRAY_MAX:
			var src: Variant = arrays[a]
			if a == Mesh.ARRAY_INDEX or out[a] != null or src == null:
				continue
			var n: int = src.size()
			if count == 0 or n == 0 or n % count != 0:
				out[a] = src
				continue
			var stride := n / count
			var dst: Variant = src.slice(0, 0)
			dst.resize(used.size() * stride)
			for j in used.size():
				var from := used[j] * stride
				for s in stride:
					dst[j * stride + s] = src[from + s]
			out[a] = dst

	## Card-level view LODs for trees (ModelLods.TREE_LOD_TIERS): keep every Nth whole card
	## sorted round horizontal layers of the crown and scale surviving cards about their own
	## centres so lighting stays steady while triangle count drops across distance bands.
	static func tree_levels(surfaces: Array, per_surface: Array, crown: Dictionary) -> Array:
		var lo := Vector3(INF, INF, INF)
		var hi := -lo
		for s: Array in surfaces:
			for p: Vector3 in (s[0] as PackedVector3Array):
				lo = lo.min(p)
				hi = hi.max(p)
		if lo.x > hi.x:
			return []
		var longest := maxf((hi - lo)[(hi - lo).max_axis_index()], 0.0)
		if longest <= 0.0:
			return []
		var parsed := {}
		var base_cards := 0
		for i in surfaces.size():
			if crown.has(i) and not bool(crown[i]):
				var p := _parse_cards(surfaces[i])
				parsed[i] = p
				base_cards += (p[0] as Array).size()
		if base_cards < TREE_MIN_CARDS * 2:
			return []
		var prev_cards := base_cards
		var out: Array = []
		for tier: Array in TREE_LOD_TIERS:
			var step := int(tier[0])
			var scale := float(tier[1])
			var error := longest / float(tier[2])
			var pixel := longest / float(tier[3])
			var part_err := longest * float(tier[4])
			var picks := {}
			var kept_total := 0
			for i in parsed:
				var cards: Array = (parsed[i] as Array)[0]
				var kept := _pick_cards(cards, step)
				picks[i] = kept
				kept_total += kept.size()
			if kept_total >= prev_cards:
				continue
			var arrays: Array = []
			for i in surfaces.size():
				var s: Array = surfaces[i]
				if parsed.has(i):
					var p: Array = parsed[i]
					var non_card: PackedInt32Array = p[1]
					var core_lods: Dictionary = p[2]
					var core_idx := non_card if core_lods.is_empty() else _coarsest_within(core_lods, non_card, part_err)
					arrays.append(_build_card_surface(s[4] as Array, picks[i] as Array, scale, core_idx))
				else:
					var full := _indices_of(s)
					var slods: Dictionary = per_surface[i] if i < per_surface.size() else {}
					var chosen := full if slods.is_empty() else _coarsest_within(slods, full, part_err)
					arrays.append(compact(s[4] as Array, chosen))
			out.append([error, arrays, pixel])
			prev_cards = kept_total
		return out

	static func _coarsest_within(lods: Dictionary, fallback: PackedInt32Array, max_err: float) -> PackedInt32Array:
		var chosen := fallback
		var best := -1.0
		for size in lods:
			var sz := float(size)
			if sz <= max_err and sz > best:
				best = sz
				chosen = lods[size]
		return chosen

	static func _parse_cards(s: Array) -> Array:
		var arrays: Array = s[4]
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var n := verts.size()
		var uvs := PackedVector2Array()
		var uv_src: Variant = arrays[Mesh.ARRAY_TEX_UV]
		if uv_src is PackedVector2Array:
			uvs = uv_src
		var index := _indices_of(s)
		var groups := {}
		var non_card := PackedInt32Array()
		for t in range(0, index.size() - 2, 3):
			var i0 := index[t]
			var i1 := index[t + 1]
			var i2 := index[t + 2]
			if uvs.size() == n and uvs[i0].x < -0.5:
				non_card.append_array([i0, i1, i2])
				continue
			var p0 := verts[i0]
			var p1 := verts[i1]
			var p2 := verts[i2]
			var mid := (p0 + p1 + p2) / 3.0
			if uvs.size() == n:
				var uv0 := uvs[i0]
				var d1 := uvs[i1] - uv0
				var d2 := uvs[i2] - uv0
				var det := d1.x * d2.y - d1.y * d2.x
				if absf(det) > 1e-8:
					var ax := ((p1 - p0) * d2.y - (p2 - p0) * d1.y) / det
					var ay := ((p2 - p0) * d1.x - (p1 - p0) * d2.x) / det
					mid = p0 - ax * (uv0.x - 0.5) - ay * (uv0.y - 0.5)
			var key := Vector3i((mid * 200.0).round())
			if not groups.has(key):
				groups[key] = [mid, 1, [i0, i1, i2]]
			else:
				var g: Array = groups[key]
				g[0] = (g[0] as Vector3) + mid
				g[1] = int(g[1]) + 1
				(g[2] as Array).append_array([i0, i1, i2])
		var ymin := INF
		for key in groups:
			var g: Array = groups[key]
			var c := (g[0] as Vector3) / float(g[1])
			g[0] = c
			ymin = minf(ymin, c.y)
		var cards: Array = []
		for key in groups:
			var g: Array = groups[key]
			var c: Vector3 = g[0]
			cards.append([c, PackedInt32Array(g[2] as Array), int(floor((c.y - ymin) / 0.6)), atan2(c.z, c.x)])
		cards.sort_custom(_card_less)
		var core_lods := surface_lods(verts, s[1], non_card, s[3]) if non_card.size() / 3 >= MIN_TRIANGLES else {}
		return [cards, non_card, core_lods]

	static func _card_less(a: Array, b: Array) -> bool:
		var la := int(a[2])
		var lb := int(b[2])
		if la != lb:
			return la < lb
		var aa := float(a[3])
		var ab := float(b[3])
		if aa != ab:
			return aa < ab
		var ca: Vector3 = a[0]
		var cb: Vector3 = b[0]
		if ca.y != cb.y:
			return ca.y < cb.y
		if ca.x != cb.x:
			return ca.x < cb.x
		return ca.z < cb.z

	static func _pick_cards(cards: Array, step: int) -> Array:
		if cards.size() <= TREE_MIN_CARDS or step <= 1:
			return cards
		var kept: Array = []
		for k in cards.size():
			if k % step == 0:
				kept.append(cards[k])
		if kept.size() >= TREE_MIN_CARDS:
			return kept
		kept = []
		for j in TREE_MIN_CARDS:
			kept.append(cards[int(j * cards.size() / TREE_MIN_CARDS)])
		return kept

	static func _build_card_surface(arrays: Array, kept: Array, scale: float, core_idx: PackedInt32Array) -> Array:
		var src_verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var count := src_verts.size()
		var used := PackedInt32Array()
		var out_pos := PackedVector3Array()
		var out_idx := PackedInt32Array()
		for card: Array in kept:
			var center: Vector3 = card[0]
			var tri_idx: PackedInt32Array = card[1]
			var local_map := {}
			for orig in tri_idx:
				if not local_map.has(orig):
					local_map[orig] = used.size()
					used.append(orig)
					out_pos.append(center + (src_verts[orig] - center) * scale)
				out_idx.append(int(local_map[orig]))
		if not core_idx.is_empty():
			var core_map := {}
			for orig in core_idx:
				if not core_map.has(orig):
					core_map[orig] = used.size()
					used.append(orig)
					out_pos.append(src_verts[orig])
				out_idx.append(int(core_map[orig]))
		var out := []
		out.resize(Mesh.ARRAY_MAX)
		out[Mesh.ARRAY_VERTEX] = out_pos
		_copy_attributes(arrays, count, used, out)
		out[Mesh.ARRAY_INDEX] = out_idx
		return out


## A surface's connected parts (welded), to check a simplification keeps its shape: every part long
## enough to see at the simplification's error keeps faces and its bounds (thin poles, bands, arms
## don't vanish or shrink), and so does the surface as a whole (its silhouette's extent).
class Parts:
	var verts: PackedVector3Array
	var part_of := PackedInt32Array()  # welded vertex -> part (-1: unused)
	var boxes: Array[AABB] = []
	var whole := AABB()

	func _init(v: PackedVector3Array, idx: PackedInt32Array) -> void:
		verts = v
		var up := PackedInt32Array()
		up.resize(v.size())
		for k in v.size():
			up[k] = k
		for t in range(0, idx.size() - 2, 3):
			for k in 2:
				var a := _root(up, idx[t + k])
				var b := _root(up, idx[t + k + 1])
				if a != b:
					up[maxi(a, b)] = mini(a, b)
		part_of.resize(v.size())
		part_of.fill(-1)
		var used := PackedByteArray()
		used.resize(v.size())
		for k in idx:
			used[k] = 1
		var first := true
		for k in v.size():
			if used[k] == 0:
				continue
			var r := _root(up, k)
			if part_of[r] < 0:
				part_of[r] = boxes.size()
				boxes.append(AABB(v[k], Vector3.ZERO))
			part_of[k] = part_of[r]
			boxes[part_of[k]] = boxes[part_of[k]].expand(v[k])
			whole = AABB(v[k], Vector3.ZERO) if first else whole.expand(v[k])
			first = false

	static func _root(up: PackedInt32Array, k: int) -> int:
		while up[k] != k:
			up[k] = up[up[k]]
			k = up[k]
		return k

	## Whether `lod` (welded indices) keeps every part at least KEEP_PARTS times `error` long, with
	## each such part's bounds and the whole surface's within BOUNDS_SLACK times `error`.
	func kept_by(lod: PackedInt32Array, error: float) -> bool:
		var kept: Array[AABB] = []
		kept.resize(boxes.size())
		var seen := PackedByteArray()
		seen.resize(boxes.size())
		var all := AABB()
		var first := true
		for k in lod:
			var p := part_of[k]
			if p < 0:
				continue
			if seen[p] == 0:
				seen[p] = 1
				kept[p] = AABB(verts[k], Vector3.ZERO)
			else:
				kept[p] = kept[p].expand(verts[k])
			all = AABB(verts[k], Vector3.ZERO) if first else all.expand(verts[k])
			first = false
		var slack := BOUNDS_SLACK * error
		if first or not _close(all, whole, slack):
			return false
		for p in boxes.size():
			var box := boxes[p]
			if maxf(box.size.x, maxf(box.size.y, box.size.z)) < KEEP_PARTS * error:
				continue
			if seen[p] == 0 or not _close(kept[p], box, slack):
				return false
		return true

	static func _close(a: AABB, b: AABB, slack: float) -> bool:
		var d1 := (a.position - b.position).abs()
		var d2 := (a.end - b.end).abs()
		return maxf(d1.x, maxf(d1.y, d1.z)) <= slack and maxf(d2.x, maxf(d2.y, d2.z)) <= slack


static var _proxies := {}  # Mesh -> ArrayMesh (empty until its job is done), or null: none
static var _ready := {}  # proxy ArrayMesh -> true once it has its shape
static var _view_only := {}  # Mesh -> true: asked for view LODs only (request_view_lods)
static var _lod_copies := {}  # Mesh -> its copy with view LODs (request_view_lods), once made


## The copy of `mesh` with view LODs that request_view_lods made, or null (not asked, not ready,
## or too small to simplify).
static func lod_copy(mesh: Mesh) -> ArrayMesh:
	return _lod_copies.get(mesh)


static var _levels := {}  # Mesh -> [[ArrayMesh, error in tiles, pixel floor (switch_error)], ...], coarser in turn, once made
## Goes up whenever a model's levels are made, so chunks drawing it look again (chunk_view.gd).
static var level_generation := 0


## The levels made for a model, coarser in turn: [[ArrayMesh, error in tiles, tiles a pixel may be at
## most (textured models, switch_error; 0 for the rest)], ...]; empty until
## its job is done, or when it has none. Each level's materials follow the model's own (a material
## changed on the model after its levels were made, as tiers and edits do, is put on them here).
static func levels(model: Mesh) -> Array:
	var out: Array = _levels.get(model, [])
	for level: Array in out:
		var mesh: ArrayMesh = level[0]
		for i in mini(mesh.get_surface_count(), model.get_surface_count()):
			var m := model.surface_get_material(i)
			if mesh.surface_get_material(i) != m:
				mesh.surface_set_material(i, m)
	return out


## The level (0: the model itself, k: levels[k - 1]) to draw at `current` now, with `allowed`
## tiles of error at that distance: a coarser level once its error is HYSTERESIS inside what is
## allowed, a finer one as soon as the level's own error isn't, so a level doesn't flip back and
## forth at one distance.
static func level_for(model_levels: Array, current: int, allowed: float) -> int:
	var level := mini(current, model_levels.size())
	while level > 0 and switch_error(model_levels[level - 1]) > allowed:
		level -= 1
	while level < model_levels.size() and switch_error(model_levels[level]) * HYSTERESIS <= allowed:
		level += 1
	return level


## The error a level counts as when picking it: its own, or for a textured model's level, at least
## what the view allows where the model is as small on screen as TEXTURED_PIXELS says (the allowed
## error grows with distance as the model shrinks, so the two meet at that size).
static func switch_error(level: Array) -> float:
	var error := float(level[1])
	if level.size() > 2:
		error = maxf(error, float(level[2]) * lod_threshold * distance_scale)
	if level.size() > 3 and heavy_lods:
		error /= maxf(float(level[3]), 1.0)
	return error


## How much sooner (smaller on screen) a heavy model switches to its levels: sqrt(triangles /
## HEAVY_REF_TRIS), 1 to HEAVY_MAX_SCALE. Moving parts' meshes count as they are.
static func heavy_scale(mesh: Mesh) -> float:
	var tris := 0
	var am := mesh as ArrayMesh
	if am == null:
		return 1.0
	for i in am.get_surface_count():
		var n: int = am.surface_get_array_index_len(i)
		if n <= 0:
			n = am.surface_get_array_len(i)
		tris += n / 3
	return clampf(sqrt(float(tris) / HEAVY_REF_TRIS), 1.0, HEAVY_MAX_SCALE)


## Whether a model brings textures of its own (a modeller's, FUE5's): a surface's material, or a row
## of a merged one, samples its base colour texture.
static func textured(mesh: Mesh) -> bool:
	if mesh == null:
		return false
	for i in mesh.get_surface_count():
		var material := mesh.surface_get_material(i)
		var rows: Array = material.get_meta(ROWS_META) if material != null and material.has_meta(ROWS_META) else [material]
		for m in rows:
			if m is ShaderMaterial and (m as ShaderMaterial).get_shader_parameter("use_albedo_tex") == true:
				return true
	return false


static var _queue: Array = []  # [Job, proxy, source mesh] waiting for a worker
static var _running: Array = []  # [task id, Job, proxy, source mesh]
## Goes up whenever proxies become ready, so chunks built before can switch to them.
static var generation := 0
## Models given LODs of their own so far (for tests and probes).
static var lod_models := 0
## Main-thread time spent here (for --stutter-probe).
static var main_usec := 0
static var _material: ShaderMaterial
static var _low_material: ShaderMaterial
static var _leaf_material: ShaderMaterial
## The stand-ins' GeometryInstance3D.lod_bias away from the character (Level of detail setting,
## QUALITY's second value). Godot picks their LOD in the shadow pass by the main camera's distance, in
## screen pixels: the error allowed is mesh_lod_threshold / lod_bias pixels. It was 0.25 and 0.15
## (4 to 27 pixels): from a step out of the closest zoom thin parts (poles, inserter arms, pipes, an
## assembler's frame) and then whole low buildings were simplified out of their shadows.
static var lod_bias := 1.0
## Settings > Graphics > Level of detail: the pixels of error the view allows (QUALITY), for the
## models' levels (chunk_view.gd update_lods); Viewport.mesh_lod_threshold takes the same for
## Godot's own LODs, which only the shadow stand-ins and creatures still have.
static var lod_threshold := 1.0
## Every model at its full level, wherever it is, switched without a fade, and Godot's own LODs off
## (full_detail.gd, for a screenshot).
static var full_detail := false
## Whether models get LODs of their own (off: only shadow stand-ins; for comparisons).
static var view_lods := true

## Settings > Graphics > Level of detail: Viewport.mesh_lod_threshold (pixels of error the view
## allows) and the far shadow stand-ins' lod_bias. Medium (High's preset) was 2 px: on a copy of
## the owner's save 4 px drew 2.0 ms less GPU a frame from the default view (2.6 zoomed out, 3.6
## at the furthest zoom) with no difference to see in screenshots near or far; the stand-ins'
## lod_bias alone was worth 0.04 ms. 6 px (another 0.95 ms) took the dots off green circuits on belts.
## The stand-ins' bias gives their shadows' error on screen: High 1 px, Medium 2 px, Low 8 px (the
## view's threshold over the bias). Their shadows are drawn once a frame and the error still grows with
## distance in tiles, so far chunks and long zooms stay cheap; the Shadows setting decides the rest.
## The third value is max_lines.
const QUALITY := {"high": [1.0, 1.0, 1440.0], "medium": [4.0, 2.0, 1440.0], "low": [7.5, 0.5, 1080.0],
	"ultra": [0.75, 1.0, 2160.0]}
const LOD_DIST_REF := 48.0
const QUALITY_START_DIST := {"low": 24.0, "medium": 48.0, "high": 72.0, "ultra": 96.0}
const QUALITY_DIST_SCALE := {"low": 0.52, "medium": 1.0, "high": 1.35, "ultra": 1.75}
const LEGACY_LOW := [4.0, 0.5, 1080.0]
static var old_low_lod := Switches.has("--lod-low=old")
static var distance_scale := 1.0
static var custom_distance := 0.0
## Before that (--legacy-render, the stutter probe's "legacy render").
const LEGACY_THRESHOLDS := {"high": 1.0, "medium": 2.0, "low": 4.0}
static var _legacy := Switches.has("--legacy-render")


static func _quality_spec(quality: String) -> Array:
	if old_low_lod and quality == "low":
		return LEGACY_LOW
	return QUALITY.get(quality, QUALITY["high"])


## The shadow stand-in for `mesh` (maybe still being made: see is_ready), or null when the model
## casts its own shadow (small, or a creature whose limbs move in the shader). Asking for it also
## starts the model's own LODs.
static func proxy_for(mesh: Mesh) -> ArrayMesh:
	if _proxies.has(mesh):
		return _proxies[mesh]
	var t0 := Time.get_ticks_usec()
	var proxy: ArrayMesh = null
	var job := _job_for(mesh as ArrayMesh)
	main_usec += Time.get_ticks_usec() - t0
	if job != null:
		proxy = ArrayMesh.new()
		_queue.append([job, proxy, mesh])
	_proxies[mesh] = proxy
	return proxy


## --no-part-levels: a modeller's baked moving parts drawn whole everywhere, as before (for comparing).
static var part_levels := not (Switches.has("--no-part-levels"))
static var _part_textured := {}  # part mesh -> whether it gets levels


## Whether a moving part gets the model's kind of levels: a modeller's textured baked part (a belt's
## base and rollers, a splitter's body: on Vasillo's belts two thirds of a tile's 1,332 triangles,
## drawn whole to the edge of the view while the body beside it simplified). Its levels keep its own
## vertices, so the bone data in them (CUSTOM3) still plays the animation, and its materials (the
## part's shader parameters) are shared. Its shadow is a stand-in at rest, as a body's (chunk_view.gd).
static func part_has_levels(part) -> bool:
	if not part_levels or part == null or part.kind != "baked" or not (part.mesh is ArrayMesh):
		return false
	var known: Variant = _part_textured.get(part.mesh)
	if known == null:
		known = textured(part.mesh) and (part.mesh as ArrayMesh).has_meta(ARRAYS_META)
		_part_textured[part.mesh] = known
	return bool(known)


## View LODs only, no shadow stand-in, for a mesh whose shadow must stay its own: creatures, whose
## limbs bend in the shader (a static stand-in's shadow wouldn't walk). The LODs keep the model's
## own vertices, so the rig's data in them still bends what is left. Asked once per mesh; the
## result is a new mesh (lod_copy), which the asker swaps in: rebuilding a mesh in place while it
## is drawn (as _give_lods does) stalled the renderer for 330-600 ms at a fight's first corpses.
static func request_view_lods(mesh: ArrayMesh) -> void:
	if mesh == null or not view_lods or _view_only.has(mesh):
		return
	_view_only[mesh] = true
	var job := Job.new()
	job.proxy = false
	for i in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(i) != Mesh.PRIMITIVE_TRIANGLES:
			return
		var arrays := arrays_of(mesh, i)
		if arrays[Mesh.ARRAY_BONES] != null:
			return
		job.surfaces.append([arrays[Mesh.ARRAY_VERTEX], arrays[Mesh.ARRAY_NORMAL], arrays[Mesh.ARRAY_INDEX], arrays[Mesh.ARRAY_CUSTOM2]])
	_queue.append([job, null, mesh])


static func is_ready(proxy: ArrayMesh) -> bool:
	return _ready.has(proxy)


## The stand-ins' material: lifted by the hills as their models are (shaders/shadow_stand_in.gdshader).
## A plain material cast from y = 0, under hills' ground: low models' shadows were lost there.
static func material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = preload("res://shaders/shadow_stand_in.gdshader")
	return _material


## The stand-ins' material on the low ground: lifted by the ground without its cliffs' terraces, as the
## model it stands in for is (a cliff's rock: ModelLibrary.sits_low).
static func low_material() -> ShaderMaterial:
	if _low_material == null:
		_low_material = ShaderMaterial.new()
		_low_material.shader = preload("res://shaders/shadow_stand_in.gdshader")
		_low_material.set_shader_parameter("ground_low", true)
	return _low_material


## The stand-in material for `model`: low_material() when it sits on the low ground, else material().
static func material_for(model: Mesh) -> ShaderMaterial:
	return low_material() if low_stand_ins and sits_low(model) else material()


## What stands in for a model that sits on the low ground (its materials' ground_low: a cliff's rock,
## model_library.gd _factorio) is lifted the same way: its shadow stand-in (here) and its far merge
## (far_chunks.gd). Lifted by the terraced ground instead, a cliff's stand-in floated up to the terrace's
## height (2.2 tiles with Terrain Elevation) over its rock and shaded all of it and the ground at its
## foot, sunlit faces too. --cliff-low-shadow=old: as before.
static var low_stand_ins := not (Switches.has("--cliff-low-shadow=old"))


## Whether `mesh` sits on the low ground: one of its materials (or a merged one's rows) has ground_low.
static func sits_low(mesh: Mesh) -> bool:
	if mesh == null:
		return false
	for i in mesh.get_surface_count():
		var m := mesh.surface_get_material(i)
		var all: Array = [m]
		if m != null and m.has_meta(ROWS_META):
			all.append_array(m.get_meta(ROWS_META))
		for row in all:
			if row is ShaderMaterial and (row as ShaderMaterial).get_shader_parameter("ground_low") == true:
				return true
	return false


## A tree crown's stand-in material: as material(), dropping the leaves and cores pollution took
## (shaders/shadow_stand_in_leaf.gdshader), as the crown itself drops them.
static func leaf_material() -> ShaderMaterial:
	if _leaf_material == null:
		_leaf_material = ShaderMaterial.new()
		_leaf_material.shader = preload("res://shaders/shadow_stand_in_leaf.gdshader")
	return _leaf_material


## Whether a material draws leaf cards (a merged one: any of its rows).
static func _has_cards(sm: ShaderMaterial) -> bool:
	if sm.resource_name.begins_with("leafcard"):
		return true
	if sm.has_meta(ROWS_META):
		for row: Material in sm.get_meta(ROWS_META):
			if row != null and row.resource_name.begins_with("leafcard"):
				return true
	return false


static func _job_for(mesh: ArrayMesh) -> Job:
	if mesh == null:
		return null
	var job := Job.new()
	job.view_lods = view_lods
	job.textured = textured(mesh)
	job.density_lod = textured_density_lod
	var triangles := 0
	for i in mesh.get_surface_count():
		var sm := mesh.surface_get_material(i) as ShaderMaterial
		var rig = sm.get_shader_parameter("rig_mode") if sm != null else null
		if rig != null and int(rig) != 0:
			return null
		# A tree's crown is many separate leaf cards: keep whole cards in view LODs (decimating
		# cards instead of welding them, which relit crowns as shapes merged) while simplifying
		# bark and cores cleanly; --tree-lod=off keeps crowns whole at every distance.
		if sm != null and _has_cards(sm):
			job.tree_cards = true
			job.proxy_lods = false
			if not tree_lods:
				job.view_lods = false
		if sm != null and sm.shader == LeafShader:
			job.crown[job.surfaces.size()] = sm.get_shader_parameter("leaf_core") == true
		if mesh.surface_get_primitive_type(i) != Mesh.PRIMITIVE_TRIANGLES:
			return null
		var arrays := arrays_of(mesh, i)
		if arrays[Mesh.ARRAY_BONES] != null:
			job.view_lods = false
		var idx = arrays[Mesh.ARRAY_INDEX]
		job.surfaces.append([arrays[Mesh.ARRAY_VERTEX], arrays[Mesh.ARRAY_NORMAL], idx, arrays[Mesh.ARRAY_CUSTOM2], arrays])
		triangles += (idx as PackedInt32Array).size() / 3 if idx != null else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return job if triangles >= MIN_TRIANGLES else null


## Finished jobs are shown (the stand-in's surface made, the model's levels made as meshes of their
## own, or a view-only copy with its LODs) for at most this long a frame, at least one a frame: on the
## owner's save the first poll after joining finished several models in one frame, a second long.
## --lods-finish-usec=N (0: all at once, as before).
static var finish_usec := 2000
## The slowest finishes so far: [ms, model name, surfaces, kind] (--stutter-probe prints them).
static var slowest: Array = []
static var _finish_arg_read := false


## Starts waiting jobs and shows finished ones. True when some proxy became ready.
static func poll() -> bool:
	var t0 := Time.get_ticks_usec()
	if not _finish_arg_read:
		_finish_arg_read = true
		for a in Switches.args():
			if a.begins_with("--lods-finish-usec="):
				finish_usec = maxi(0, int(a.substr(19)))
	var done := false
	var finished := 0
	for i in range(_running.size() - 1, -1, -1):
		var entry: Array = _running[i]
		if int(entry[0]) >= 0:  # -1: finish_all() already waited for it
			if not WorkerThreadPool.is_task_completed(entry[0]):
				continue
			if finish_usec > 0 and finished > 0 and Time.get_ticks_usec() - t0 > finish_usec:
				break  # the rest next frame
			WorkerThreadPool.wait_for_task_completion(entry[0])
		_running.remove_at(i)
		finished += 1
		var tf := Time.get_ticks_usec()
		var job: Job = entry[1]
		var proxy: ArrayMesh = entry[2]
		var kind := ""
		if proxy != null and (job.indices.size() >= 3 or job.crown_vertices.size() >= 3):
			if job.indices.size() >= 3:
				var arrays := []
				arrays.resize(Mesh.ARRAY_MAX)
				arrays[Mesh.ARRAY_VERTEX] = job.vertices
				arrays[Mesh.ARRAY_NORMAL] = job.normals
				arrays[Mesh.ARRAY_INDEX] = job.indices
				proxy.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], job.lods)
				proxy.surface_set_material(proxy.get_surface_count() - 1, material_for(entry[3] as Mesh))
			if job.crown_vertices.size() >= 3:
				var crown := []
				crown.resize(Mesh.ARRAY_MAX)
				crown[Mesh.ARRAY_VERTEX] = job.crown_vertices
				crown[Mesh.ARRAY_TEX_UV] = job.crown_uvs
				proxy.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, crown)
				proxy.surface_set_material(proxy.get_surface_count() - 1, leaf_material())
			_ready[proxy] = true
			done = true
			kind = "proxy"
		if proxy == null and _view_only.has(entry[3]):
			var copy := _copy_with_lods(entry[3] as ArrayMesh, job.surface_lods)
			if copy != null:
				_lod_copies[entry[3]] = copy
			kind += "+copy"
		elif job.levels_done:
			_make_levels(entry[3] as ArrayMesh, job.levels)
			kind += "+levels"
		elif (job.tree_cards and job.view_lods) or job.surface_lods.any(func(l: Dictionary) -> bool: return not l.is_empty()):
			_queue.append([job, null, entry[3]])
			kind += "+queued"
		var ms := (Time.get_ticks_usec() - tf) / 1000.0
		if ms > 2.0 and slowest.size() < 200:
			var m: Mesh = entry[3]
			slowest.append([snappedf(ms, 0.01), m.resource_name if m != null else "", m.get_surface_count() if m != null else 0, kind])
	while _running.size() < JOBS and not _queue.is_empty():
		var next: Array = _queue.pop_front()
		var queued: Job = next[0]
		var step := queued.run_levels if queued.proxy_done and queued.proxy else queued.run
		_running.append([WorkerThreadPool.add_task(step, false, "model lods"), next[0], next[1], next[2]])
	if done:
		generation += 1
	main_usec += Time.get_ticks_usec() - t0
	return done


## The model's levels as meshes of their own (the model itself is left as it is: rebuilding a mesh
## in place while it is drawn stalled the renderer), each with the model's bounds, so a chunk's
## culling doesn't change with its level.
static func _make_levels(mesh: ArrayMesh, made: Array) -> void:
	if mesh == null or made.is_empty():
		return
	var out: Array = []
	var scale := heavy_scale(mesh)
	var box := mesh.get_aabb()
	# A moving part's bounds over its whole motion (anim.gd setup_part, a baked part's bones).
	if mesh.custom_aabb.has_volume():
		box = mesh.custom_aabb
	for level: Array in made:
		var per_surface: Array = level[1]
		if per_surface.size() != mesh.get_surface_count():
			return
		var lod := ArrayMesh.new()
		for i in per_surface.size():
			lod.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, per_surface[i], [], {}, mesh.surface_get_format(i) & CUSTOM_FORMATS)
			lod.surface_set_material(i, mesh.surface_get_material(i))
			lod.surface_set_name(i, mesh.surface_get_name(i))
		lod.custom_aabb = box
		lod.resource_name = mesh.resource_name
		out.append([lod, float(level[0]), float(level[2]) if level.size() > 2 else 0.0, scale])
	_levels[mesh] = out
	level_generation += 1
	lod_models += 1


## A new mesh with `mesh`'s surfaces and these LODs (null when none were made), keeping the CPU
## copy of its arrays.
static func _copy_with_lods(mesh: ArrayMesh, per_surface: Array) -> ArrayMesh:
	if mesh == null or per_surface.size() != mesh.get_surface_count() or per_surface.all(func(l: Dictionary) -> bool: return l.is_empty()):
		return null
	var out := ArrayMesh.new()
	var kept: Array = []
	for i in mesh.get_surface_count():
		var arrays := arrays_of(mesh, i)
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], per_surface[i], mesh.surface_get_format(i) & CUSTOM_FORMATS)
		out.surface_set_material(i, mesh.surface_get_material(i))
		out.surface_set_name(i, mesh.surface_get_name(i))
		kept.append(arrays)
	out.set_meta(ARRAYS_META, kept)
	out.resource_name = mesh.resource_name
	lod_models += 1
	return out


static func busy() -> bool:
	return not _queue.is_empty() or not _running.is_empty()


## Waits for the jobs on worker threads (a world leaving the tree, or the game quitting). What they
## made is still shown by the next poll(), and waiting jobs stay queued for the next world.
static func finish_all() -> void:
	for entry in _running:
		if int(entry[0]) >= 0:
			WorkerThreadPool.wait_for_task_completion(entry[0])
			entry[0] = -1


## Settings > Graphics > Level of detail (and optional custom LOD falloff distance in tiles).
static func apply_quality(quality: String, viewport: Viewport, lod_dist := 0.0) -> void:
	var prev_thresh := lod_threshold
	var prev_scale := distance_scale
	custom_distance = maxf(lod_dist, 0.0)
	_quality = quality
	if custom_distance > 0.0:
		distance_scale = clampf(custom_distance / LOD_DIST_REF, 0.2, 4.0)
		lod_threshold = clampf(4.0 / distance_scale, 0.5, 16.0)
		lod_bias = clampf(2.0 * distance_scale, 0.35, 2.0)
		max_lines = 1080.0 if custom_distance <= 32.0 else (2160.0 if custom_distance >= 88.0 else 1440.0)
	else:
		var q := _quality_spec(quality)
		lod_bias = float(q[1])
		lod_threshold = float(q[0])
		max_lines = float(q[2])
		distance_scale = 1.0 if (old_low_lod and quality == "low") else float(QUALITY_DIST_SCALE.get(quality, 1.0))
	for arg in Switches.args():
		if arg.begins_with("--lod-lines="):
			max_lines = maxf(float(arg.get_slice("=", 1)), 0.0)
	if not is_equal_approx(lod_threshold, prev_thresh) or not is_equal_approx(distance_scale, prev_scale):
		level_generation += 1
	fit_lines(viewport)


## The most lines a picture is counted as when pixels of error become tiles (world.gd _update_lods,
## the shadow stand-ins through Viewport.mesh_lod_threshold) and when ao_zoom.gd measures tiles a
## pixel: a taller one is counted as this tall, so a model switches at the size on screen it does at
## 1440p and 4K doesn't keep detail twice as far (belt_lods.gd's MAX_LINES does the same for belts).
## At 4K the owner's base drew 4.4-4.9 million triangles in a 45-tile view: a pixel of error there is
## half a 1080p one. By Level of detail (QUALITY's third value): High and Medium 1440, Low 1080.
## --lod-lines=<n> sets it whatever the setting (0: every real line, as before 0.2.1).
static var max_lines := 1440.0
static var _quality := "medium"


## `lines` as the levels of detail count them (max_lines), at least 1.
static func counted_lines(lines: float) -> float:
	return maxf(minf(lines, max_lines) if max_lines > 0.0 else lines, 1.0)


## Viewport.mesh_lod_threshold for the Level of detail setting and the window's height: Godot measures
## its error in the viewport's real pixels, so on a picture taller than max_lines it is allowed that
## many times more of them. main.gd calls it again when the window changes size.
static func fit_lines(viewport: Viewport) -> void:
	if viewport == null:
		return
	if full_detail:
		viewport.mesh_lod_threshold = 0.0
	elif _legacy:
		viewport.mesh_lod_threshold = float(LEGACY_THRESHOLDS.get(_quality, 1.0))
	else:
		var lines := float((viewport as Window).size.y) if viewport is Window else viewport.get_visible_rect().size.y
		viewport.mesh_lod_threshold = lod_threshold * maxf(lines, 1.0) / counted_lines(lines)
