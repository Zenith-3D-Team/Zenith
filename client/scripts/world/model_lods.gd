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
## Textured models: vertices whose normals differ by more than this (degrees) stay apart (hard edges).
const TEXTURED_MERGE_ANGLE := 60.0
## Textured models: the least share of the model's triangles each level keeps (so at most this many
## levels); a surface's simplification under the last share isn't used at all.
const TEXTURED_FLOORS := [0.3, 0.15]
## Textured models: each level is drawn only once the model's longest side is at most this many
## pixels on screen (counted against Level of detail's pixels of error: lod_threshold 1 is High).
const TEXTURED_PIXELS := [64.0, 32.0]
## The custom channel formats in a surface's format, which add_surface_from_arrays needs again.
const CUSTOM_FORMATS := 0xFFF << Mesh.ARRAY_FORMAT_CUSTOM_BASE
## Meta on an ArrayMesh holding its surfaces' arrays on the CPU (model_library.gd keeps them):
## Mesh.surface_get_arrays reads them back from the GPU, which stalls the frame.
const ARRAYS_META := &"f3d_arrays"
## Meta on a model's merged material: its rows' materials (material_rows.gd).
const ROWS_META := &"f3d_rows"
const ROW_EDITED_META := &"f3d_row_edited"


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

	func run() -> void:
		if not proxy:
			for s in surfaces:
				surface_lods.append(ModelLodsMath.surface_lods(s[0], s[1], s[2], s[3]))
			return
		var welded := ModelLodsMath.weld(surfaces)
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
			return
		for s in surfaces:
			var uv: Variant = (s[4] as Array)[Mesh.ARRAY_TEX_UV] if textured and s.size() > 4 else null
			surface_lods.append(ModelLodsMath.surface_lods(s[0], s[1], s[2], s[3], uv))

	## The second step (poll queues it once the stand-in is shown, so shadows don't wait for it):
	## the model's levels, which take longer than the rest (the coplanar checks).
	func run_levels() -> void:
		levels = ModelLodsMath.levels(surfaces, surface_lods, textured)
		levels_done = true


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
	static func surface_lods(src: PackedVector3Array, src_normals, src_idx, rows: Variant = null, uv: Variant = null) -> Dictionary:
		var triangles := (src_idx as PackedInt32Array).size() / 3 if src_idx != null else src.size() / 3
		if triangles < MIN_TRIANGLES:
			return {}
		if uv is PackedVector2Array and (uv as PackedVector2Array).size() == src.size():
			return textured_lods(src, src_normals, src_idx, uv, rows)
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
	static func textured_lods(src: PackedVector3Array, src_normals, src_idx, uv: PackedVector2Array, rows: Variant = null) -> Dictionary:
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
		var im := ImporterMesh.new()
		im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays)
		im.generate_lods(TEXTURED_MERGE_ANGLE, TEXTURED_MERGE_ANGLE, [])
		var welded := weld([[src, src_normals, idx]])
		var remap: PackedInt32Array = welded[2]
		var parts := Parts.new(welded[0], welded[1])
		var least := int(idx.size() * float(TEXTURED_FLOORS[-1]))
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

	## The model's levels from its surfaces' LODs (surface_lods): for each level's error, every
	## surface at its coarsest LOD within it, less the faces lying under others in their plane. A
	## level still with more coplanar faces than the model has those surfaces put back to the level
	## before, and is dropped if that doesn't clear them or leaves too little saved. A textured
	## model's levels keep TEXTURED_FLOORS of its triangles.
	## [[error, [arrays per surface, compacted], tiles a pixel may be at most (0: any)], ...], finest first.
	static func levels(surfaces: Array, per_surface: Array, textured := false) -> Array:
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
		var own_fights := {}  # surface -> the overlap of its own faces in the model (textured only)
		var out: Array = []
		var previous: Array = full.duplicate()
		var previous_count := full_count
		var last_error := 0.0
		for error: float in sizes:
			if out.size() >= (TEXTURED_FLOORS.size() if textured else MAX_LEVELS):
				break
			if last_error > 0.0 and error < last_error * LEVEL_STEP:
				continue
			var chosen := _chosen(previous, per_surface, error)
			if _count(chosen) > previous_count * (1.0 - LEVEL_SAVING):
				continue
			chosen = without_covered(surfaces, chosen)
			var fight := fights(surfaces, chosen)
			if float(fight[0]) > base_fight + COPLANAR_SLACK and textured:
				# A textured surface keeps its UV seams, so its simplifications fold more faces onto
				# others: each surface found takes its coarsest LOD within the error that adds none
				# of its own, before the whole is looked at again.
				for i: int in fight[1]:
					chosen[i] = _without_own_fights(surfaces[i], per_surface[i], previous[i], error, own_fights, i)
				fight = fights(surfaces, chosen)
				if _count(chosen) > previous_count * (1.0 - LEVEL_SAVING):
					continue
			if float(fight[0]) > base_fight + COPLANAR_SLACK:
				for i: int in fight[1]:
					chosen[i] = previous[i]
				if float(fights(surfaces, chosen)[0]) > base_fight + COPLANAR_SLACK or _count(chosen) > previous_count * (1.0 - LEVEL_SAVING):
					continue
			var pixel := 0.0
			if textured:
				# Coarser errors only take more away: the first under its floor ends the levels.
				if _count(chosen) < full_count * float(TEXTURED_FLOORS[out.size()]):
					break
				pixel = longest / float(TEXTURED_PIXELS[out.size()])
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
			own[i] = float(fights([surface], [_indices_of(surface)])[0]) * (1.0 + COPLANAR_SHARE) + COPLANAR_SLACK
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
		for a in Mesh.ARRAY_MAX:
			var src: Variant = arrays[a]
			if a == Mesh.ARRAY_INDEX or src == null:
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
		error = maxf(error, float(level[2]) * lod_threshold)
	return error


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
const QUALITY := {"high": [1.0, 1.0], "medium": [4.0, 2.0], "low": [4.0, 0.5]}
## Before that (--legacy-render, the stutter probe's "legacy render").
const LEGACY_THRESHOLDS := {"high": 1.0, "medium": 2.0, "low": 4.0}
static var _legacy := "--legacy-render" in OS.get_cmdline_user_args()


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
static var part_levels := not ("--no-part-levels" in OS.get_cmdline_user_args())
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


static func _job_for(mesh: ArrayMesh) -> Job:
	if mesh == null:
		return null
	var job := Job.new()
	job.view_lods = view_lods
	job.textured = textured(mesh)
	var triangles := 0
	for i in mesh.get_surface_count():
		var sm := mesh.surface_get_material(i) as ShaderMaterial
		var rig = sm.get_shader_parameter("rig_mode") if sm != null else null
		if rig != null and int(rig) != 0:
			return null
		# A tree's crown is many separate leaf cards, which simplifying merges into other shapes, so
		# each LOD switch as the camera moved relit whole crowns (flicker). Trees keep their own
		# mesh in view; their shadow stand-in still simplifies.
		if sm != null and sm.resource_name.begins_with("leafcard"):
			job.view_lods = false
			job.proxy_lods = false
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
		for a in OS.get_cmdline_user_args():
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
		if proxy != null and job.indices.size() >= 3:
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = job.vertices
			arrays[Mesh.ARRAY_NORMAL] = job.normals
			arrays[Mesh.ARRAY_INDEX] = job.indices
			proxy.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], job.lods)
			proxy.surface_set_material(0, material())
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
		elif job.surface_lods.any(func(l: Dictionary) -> bool: return not l.is_empty()):
			_queue.append([job, null, entry[3]])
			kind += "+queued"
		var ms := (Time.get_ticks_usec() - tf) / 1000.0
		if ms > 2.0 and slowest.size() < 200:
			var m: Mesh = entry[3]
			slowest.append([snappedf(ms, 0.01), m.resource_name if m != null else "", m.get_surface_count() if m != null else 0, kind])
	while _running.size() < JOBS and not _queue.is_empty():
		var next: Array = _queue.pop_front()
		var queued: Job = next[0]
		var step := queued.run if queued.surface_lods.is_empty() or not queued.proxy else queued.run_levels
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
		out.append([lod, float(level[0]), float(level[2]) if level.size() > 2 else 0.0])
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


## Settings > Graphics > Level of detail.
static func apply_quality(quality: String, viewport: Viewport) -> void:
	var q: Array = QUALITY.get(quality, QUALITY["high"])
	if viewport != null:
		viewport.mesh_lod_threshold = float(LEGACY_THRESHOLDS.get(quality, 1.0)) if _legacy else q[0]
		if full_detail:
			viewport.mesh_lod_threshold = 0.0
	lod_bias = q[1]
	lod_threshold = q[0]
