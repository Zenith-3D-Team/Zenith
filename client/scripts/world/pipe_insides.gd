extends RefCounted
## Adds inward-facing back faces to hollow windowed pipe shells (like Vasillo's
## `pipe-straight-*-window.glb` in existing `Zenith.zip` or third-party packs exported from
## Blender with `doubleSided: true`). `factorio_material.gdshader` draws one side only
## (`cull_back`), so looking through the glass window on a single-walled tube sees straight
## through the far wall to the ground below.
##
## Done once per model on its worker thread (model_library.gd Load), into the CPU arrays so levels
## of detail and previews get it too. Skips the transparent glass surface itself, models whose solid
## material asks for `CULL_BACK`, models already given back faces (`fix_pack.py` `"inside": true`),
## and models that already have a real inward-facing inner wall.
## `--pipe-insides=off` leaves models untouched (docs/RUNNING.md).

const Switches := preload("res://scripts/switches.gd")

static var enabled := Switches.on("--pipe-insides")
const META := &"f3d_pipe_insides"
const WELD := 0.0005


## Whether a model of this file name is a windowed, capped, or wet-drill pipe piece to check.
static func wanted(file_name: String) -> bool:
	if not enabled:
		return false
	if file_name == "electric-mining-drill-wet" or file_name.ends_with("-mining-drill-wet"):
		return true
	if not file_name.contains("pipe"):
		return false
	return file_name.ends_with("-window") \
		or file_name.contains("pipe-ending-") \
		or file_name.ends_with("pipe-straight-vertical-single") \
		or file_name.contains("pipe-to-ground") \
		or file_name.ends_with("pipe-cover")


## Adds inward faces to every double-sided opaque surface in `groups` (when a transparent window
## surface is present, skips the inner cylinder wall inside `glass_box`). Returns total back-face
## triangles added.
static func add_to_groups(groups: Array) -> int:
	var glass_box := AABB()
	var any_glass_vert := false
	for g: Array in groups:
		var keys: Array = g[0]
		if not _has_see_through(keys):
			continue
		var arrays: Array = g[1]
		var verts: Variant = arrays[Mesh.ARRAY_VERTEX]
		if verts is PackedVector3Array:
			for v: Vector3 in (verts as PackedVector3Array):
				if any_glass_vert:
					glass_box = glass_box.expand(v)
				else:
					glass_box = AABB(v, Vector3.ZERO)
					any_glass_vert = true
	var total := 0
	for g: Array in groups:
		var keys: Array = g[0]
		if not _wants_inside(keys):
			continue
		total += add(g[1], glass_box)
	return total


static func _is_see_through(material: Variant) -> bool:
	var base := material as BaseMaterial3D
	if base == null:
		return false
	var t := base.transparency
	return t != BaseMaterial3D.TRANSPARENCY_DISABLED \
		and t != BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR \
		and t != BaseMaterial3D.TRANSPARENCY_ALPHA_HASH


static func _has_see_through(keys: Array) -> bool:
	for k: Array in keys:
		if _is_see_through(k[0]):
			return true
	return false


static func _wants_inside(keys: Array) -> bool:
	var any_opaque_double := false
	for k: Array in keys:
		var base := k[0] as BaseMaterial3D
		if base == null:
			return false
		if _is_see_through(base):
			return false
		var t := base.transparency
		if t != BaseMaterial3D.TRANSPARENCY_DISABLED and t != BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			return false
		var name := base.resource_name.to_lower()
		if name.begins_with("leafcard") or name.begins_with("leaf-shadow") or name.begins_with("leaf-0"):
			return false
		if base.cull_mode == BaseMaterial3D.CULL_DISABLED:
			any_opaque_double = true
	return any_opaque_double


## Adds reversed back-face copies of every triangle in `arrays` in place unless the surface already
## has paired opposite faces or an inward-facing inner cylinder wall inside `glass_box`. Returns the
## number of back-face triangles added (0 if skipped).
static func add(arrays: Array, glass_box := AABB()) -> int:
	var v_var: Variant = arrays[Mesh.ARRAY_VERTEX]
	if not (v_var is PackedVector3Array):
		return 0
	var verts: PackedVector3Array = v_var
	var count := verts.size()
	if count < 3:
		return 0
	var idx: PackedInt32Array
	if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array and not (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).is_empty():
		idx = arrays[Mesh.ARRAY_INDEX]
	else:
		idx = PackedInt32Array(range(count))
	var tri_count := idx.size() / 3
	if tri_count <= 0:
		return 0

	# Check 1: idempotency when opposite-wound twin triangles already exist (fix_pack "inside": true).
	var qverts: Array[Vector3i] = []
	qverts.resize(count)
	for v in count:
		var p := verts[v]
		qverts[v] = Vector3i(roundi(p.x / WELD), roundi(p.y / WELD), roundi(p.z / WELD))
	var seen := {}
	for t in tri_count:
		var qa := qverts[idx[t * 3]]
		var qb := qverts[idx[t * 3 + 1]]
		var qc := qverts[idx[t * 3 + 2]]
		if qa == qb or qb == qc or qa == qc:
			continue
		seen[_tri_key(qa, qb, qc)] = true
	var pairs := 0
	for t in tri_count:
		var qa := qverts[idx[t * 3]]
		var qb := qverts[idx[t * 3 + 1]]
		var qc := qverts[idx[t * 3 + 2]]
		if qa == qb or qb == qc or qa == qc:
			continue
		if seen.has(_tri_key(qa, qc, qb)):
			pairs += 1
	if pairs * 4 >= tri_count:
		return 0

	# Check 2: skip meshes that already model an actual inward-facing inner cylinder wall (Solidify).
	if glass_box.size != Vector3.ZERO:
		var mesh_box := AABB(verts[0], Vector3.ZERO)
		for v in range(1, count):
			mesh_box = mesh_box.expand(verts[v])
		var horizontal := mesh_box.size.x >= mesh_box.size.z
		var span_lo := (glass_box.position.x if horizontal else glass_box.position.z) - 0.02
		var span_hi := (glass_box.end.x if horizontal else glass_box.end.z) + 0.02
		var cy := maxf(glass_box.end.y - 0.36, 0.0)
		var inward_tris := 0
		for t in tri_count:
			var a := verts[idx[t * 3]]
			var b := verts[idx[t * 3 + 1]]
			var c := verts[idx[t * 3 + 2]]
			var cent := (a + b + c) / 3.0
			var along := cent.x if horizontal else cent.z
			if along < span_lo or along > span_hi or cent.y > glass_box.end.y:
				continue
			# Godot front faces wind clockwise, so outward front-face normal is (c - a) x (b - a).
			var fn := (c - a).cross(b - a)
			var len_sq := fn.length_squared()
			if len_sq < 1e-14:
				continue
			fn /= sqrt(len_sq)
			var rad := Vector2(cent.z if horizontal else cent.x, cent.y - cy)
			var r := rad.length()
			if r <= 0.05:
				continue
			var n2 := Vector2(fn.z if horizontal else fn.x, fn.y)
			if n2.dot(rad / r) < -0.35:
				inward_tris += 1
				if inward_tris >= 4:
					return 0

	# Double every vertex attribute array and append reversed triangles with negated normals.
	for t in Mesh.ARRAY_MAX:
		if t == Mesh.ARRAY_INDEX or arrays[t] == null:
			continue
		var data: Variant = arrays[t]
		if t == Mesh.ARRAY_NORMAL and data is PackedVector3Array:
			var nsrc: PackedVector3Array = data
			var ndst := PackedVector3Array()
			ndst.resize(count * 2)
			for i in count:
				ndst[i] = nsrc[i]
				ndst[count + i] = -nsrc[i]
			arrays[Mesh.ARRAY_NORMAL] = ndst
		elif t == Mesh.ARRAY_TANGENT and data is PackedFloat32Array and (data as PackedFloat32Array).size() == count * 4:
			var tsrc: PackedFloat32Array = data
			var tdst := PackedFloat32Array()
			tdst.resize(count * 8)
			for i in count:
				var base := i * 4
				var b2 := (count + i) * 4
				tdst[base] = tsrc[base]
				tdst[base + 1] = tsrc[base + 1]
				tdst[base + 2] = tsrc[base + 2]
				tdst[base + 3] = tsrc[base + 3]
				tdst[b2] = -tsrc[base]
				tdst[b2 + 1] = -tsrc[base + 1]
				tdst[b2 + 2] = -tsrc[base + 2]
				tdst[b2 + 3] = tsrc[base + 3]
			arrays[Mesh.ARRAY_TANGENT] = tdst
		else:
			var copy: Variant = data.duplicate()
			copy.append_array(data)
			arrays[t] = copy

	var out_idx := PackedInt32Array()
	out_idx.resize(tri_count * 6)
	for t in tri_count:
		var s := t * 3
		var d := tri_count * 3 + s
		var a := idx[s]
		var b := idx[s + 1]
		var c := idx[s + 2]
		out_idx[s] = a
		out_idx[s + 1] = b
		out_idx[s + 2] = c
		out_idx[d] = a + count
		out_idx[d + 1] = c + count
		out_idx[d + 2] = b + count
	arrays[Mesh.ARRAY_INDEX] = out_idx
	return tri_count


static func _vec_lt(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x:
		return a.x < b.x
	if a.y != b.y:
		return a.y < b.y
	return a.z < b.z


static func _tri_key(a: Vector3i, b: Vector3i, c: Vector3i) -> Array[Vector3i]:
	if _vec_lt(b, a) and _vec_lt(b, c):
		return [b, c, a]
	if _vec_lt(c, a) and _vec_lt(c, b):
		return [c, a, b]
	return [a, b, c]
