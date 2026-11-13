extends RefCounted
## A modeller's rigged inserter, drawn by Zenith's own arm (inserter_arms.gd) instead of Wube's pieces.
##
## The model is one skinned mesh whose skin names its joints Base, Rotation, Lower Arm, Upper Arm,
## Pincer1 and Pincer2 (Vasillo's inserters; spaces, case and underscores don't matter). It has no
## action to play: the arm has to reach wherever the game's hand is, so the mesh is cut, on the
## loader's worker, into rigid parts by each vertex's strongest bone, and the arm solves its own IK.
##   base       every bone outside the arm (Base): drawn as the entity's static model, as before
##   turntable  the bone the lower arm hangs from (Rotation), unless that is the skin's root: it yaws
##              about its joint towards the hand
##   lower, upper  shoulder to elbow and elbow to wrist (two-bone IK in the arm's vertical plane)
##   pincers    Pincer1 and Pincer2, riding the upper arm; each turns about its own joint to close
## Bones below one of these (a hand bone under the upper arm) go with it. Each part's vertices are
## kept in the rest pose (the bind pose the inverse bind matrices describe), relative to its joint.
## The joints, lengths, hinge and pincers' closing come from the skin, nothing is assumed about the
## sizes. Worker-thread safe: arrays only.

enum Part { TURNTABLE, LOWER, UPPER, PINCER_A, PINCER_B }
const BASE := -1
## Factorio's inserter platform has one leg at its back reaching furthest: a rig whose platform
## reaches furthest another way round (by more than this, in tiles) is turned so that leg points
## north, as Zenith's models face (Vasillo's point west).
const FACING_MARGIN := 0.03
## The pincers close until their outer halves reach the plane between them, at most this far (radians).
const MAX_CLOSE := 1.2
const CLOSE_STEP := 0.01


## Each joint's part (Part, or BASE), or empty when the skin isn't an inserter rig (no Lower Arm,
## Upper Arm and at least one Pincer joint).
static func roles(bake: Dictionary) -> PackedInt32Array:
	var names: PackedStringArray = bake.get("names", PackedStringArray())
	var parents: PackedInt32Array = bake.get("joint_parents", PackedInt32Array())
	if names.size() != parents.size():
		return PackedInt32Array()
	var lower := -1
	var upper := -1
	var pincers: Array = []
	for j in names.size():
		var n := _plain(names[j])
		if n == "lowerarm":
			lower = j
		elif n == "upperarm":
			upper = j
		elif n.begins_with("pincer"):
			pincers.append([n, j])
	if lower < 0 or upper < 0 or pincers.is_empty():
		return PackedInt32Array()
	pincers.sort_custom(func(a: Array, b: Array) -> bool: return str(a[0]) < str(b[0]))
	var own := {lower: Part.LOWER, upper: Part.UPPER, int(pincers[0][1]): Part.PINCER_A}
	if pincers.size() > 1:
		own[int(pincers[1][1])] = Part.PINCER_B
	var table := parents[lower]
	if table >= 0 and parents[table] >= 0 and not own.has(table):
		own[table] = Part.TURNTABLE
	var out := PackedInt32Array()
	out.resize(names.size())
	for j in names.size():
		var role := BASE
		var k := j
		while k >= 0:
			if own.has(k):
				role = own[k]
				break
			k = parents[k]
		out[j] = role
	return out


static func _plain(name: String) -> String:
	return name.to_lower().replace(" ", "").replace("_", "").replace("-", "").replace(".", "")


## A skinned surface cut by `roles`: {"base": the static triangles' arrays (in the mesh's space, no
## skin) or null, "parts": per Part its arrays (in the model's space: `xform` applied) or null}.
## A triangle goes where two of its corners' strongest bones go (else its first corner's).
static func split(arrays: Array, xform: Transform3D, bake: Dictionary, roles: PackedInt32Array) -> Dictionary:
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var count := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var per := bones.size() / maxi(count, 1)
	var role := PackedInt32Array()
	role.resize(count)
	for v in count:
		var best := -1.0
		var bone := 0
		for k in per:
			if weights[v * per + k] > best:
				best = weights[v * per + k]
				bone = bones[v * per + k]
		role[v] = roles[bone] if bone >= 0 and bone < roles.size() else BASE
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if idx.is_empty():
		idx = PackedInt32Array(range(count))
	var tris := {}  # role -> Array of corners (an Array: a packed one in a Dictionary is copied on write)
	for t in range(0, idx.size() - 2, 3):
		var a := role[idx[t]]
		var b := role[idx[t + 1]]
		var c := role[idx[t + 2]]
		var r := a if a == b or a == c else (b if b == c else a)
		if not tris.has(r):
			tris[r] = []
		(tris[r] as Array).append_array([idx[t], idx[t + 1], idx[t + 2]])
	for r in tris:
		tris[r] = PackedInt32Array(tris[r])
	var parts: Array = []
	parts.resize(Part.size())
	for p in Part.size():
		if tris.has(p):
			parts[p] = _placed(_subset(arrays, tris[p]), xform)
	return {"base": _subset(arrays, tris[BASE]) if tris.has(BASE) else null, "parts": parts}


## The vertices `corners` use, renumbered, without the skin's bones and weights.
static func _subset(arrays: Array, corners: PackedInt32Array) -> Array:
	var count := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var remap := PackedInt32Array()
	remap.resize(count)
	remap.fill(-1)
	var order := PackedInt32Array()
	var index := PackedInt32Array()
	index.resize(corners.size())
	for i in corners.size():
		var v := corners[i]
		if remap[v] < 0:
			remap[v] = order.size()
			order.append(v)
		index[i] = remap[v]
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	for t in Mesh.ARRAY_MAX:
		if t == Mesh.ARRAY_INDEX or t == Mesh.ARRAY_BONES or t == Mesh.ARRAY_WEIGHTS or arrays[t] == null:
			continue
		var src = arrays[t]
		var width: int = src.size() / maxi(count, 1)
		var dst = src.duplicate()
		dst.resize(order.size() * width)
		for i in order.size():
			for k in width:
				dst[i * width + k] = src[order[i] * width + k]
		out[t] = dst
	out[Mesh.ARRAY_INDEX] = index
	return out


## Arrays moved by `xform` (vertices, normals), in place; returns them.
static func _placed(arrays: Array, xform: Transform3D) -> Array:
	arrays[Mesh.ARRAY_VERTEX] = xform * (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array)
	if arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array:
		var normal_basis := xform.basis.inverse().transposed()
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for v in normals.size():
			normals[v] = (normal_basis * normals[v]).normalized()
		arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = null
	return arrays


## The rig's numbers, everything in the model's space (`xform`, the skinned node's) turned by the
## facing found from the platform (`base_points`, its vertices in the model's space), and the parts'
## arrays moved, in place, to be relative to their joints (turned the same way):
##   turn     the yaw applied (radians, about +Y); the loader turns the static base by it too
##   pivot    the turntable's joint (the shoulder's when there is no turntable)
##   shoulder, elbow, wrist (the pincers' joints' middle), grip (between the pincers, half way
##            along them: where the held item goes)
##   lengths  [shoulder to elbow, elbow to grip]
##   hinge    the axis the arm bends about at rest (across the arm, from pincer A towards B)
##   heads    per Part its joint; axes and angles per pincer: the axis it closes about and how far
static func build(parts: Array, base_points: PackedVector3Array, xform: Transform3D, bake: Dictionary,
		roles: PackedInt32Array) -> Dictionary:
	var binds: Array = bake.get("binds", [])
	var parents: PackedInt32Array = bake.get("joint_parents", PackedInt32Array())
	var heads: Array = []
	heads.resize(Part.size())
	for j in roles.size():
		var r := roles[j]
		if r == BASE or j >= binds.size() or j >= parents.size():
			continue
		# The joint that owns the part is the first of its role (its parent isn't in it).
		var up := parents[j]
		if up >= 0 and roles[up] == r:
			continue
		heads[r] = xform * (binds[j] as Transform3D).affine_inverse().origin
	var turn := facing(base_points)
	var yaw := Basis(Vector3.UP, turn)
	for p in Part.size():
		if heads[p] == null:
			parts[p] = null
			continue
		var head: Vector3 = heads[p]
		heads[p] = yaw * head
		if parts[p] != null:
			var verts: PackedVector3Array = parts[p][Mesh.ARRAY_VERTEX]
			for v in verts.size():
				verts[v] = yaw * (verts[v] - head)
			parts[p][Mesh.ARRAY_VERTEX] = verts
			if parts[p][Mesh.ARRAY_NORMAL] is PackedVector3Array:
				var normals: PackedVector3Array = parts[p][Mesh.ARRAY_NORMAL]
				for v in normals.size():
					normals[v] = yaw * normals[v]
				parts[p][Mesh.ARRAY_NORMAL] = normals
	if heads[Part.LOWER] == null or heads[Part.UPPER] == null:
		return {}
	var shoulder: Vector3 = heads[Part.LOWER]
	var elbow: Vector3 = heads[Part.UPPER]
	var pincers: Array = []
	for p in [Part.PINCER_A, Part.PINCER_B]:
		if heads[p] != null and parts[p] != null:
			pincers.append(p)
	if pincers.is_empty():
		return {}
	var wrist := Vector3.ZERO
	for p: int in pincers:
		wrist += heads[p] as Vector3
	wrist /= float(pincers.size())
	var along := (wrist - elbow).normalized()
	if along.length() < 0.5:
		return {}
	# Each pincer's middle, off the arm's line: the way it opens.
	var sides := {}
	for p: int in pincers:
		var mid := Vector3.ZERO
		var verts: PackedVector3Array = parts[p][Mesh.ARRAY_VERTEX]
		for v in verts:
			mid += v
		mid = mid / maxf(verts.size(), 1.0) + (heads[p] as Vector3)
		var off := mid - wrist
		sides[p] = off - along * off.dot(along)
	var hinge: Vector3
	if pincers.size() > 1:
		hinge = (sides[pincers[1]] as Vector3) - (sides[pincers[0]] as Vector3)
	else:
		hinge = sides[pincers[0]]
	hinge = hinge - along * hinge.dot(along)
	if hinge.length() < 0.001:
		hinge = yaw * Vector3.BACK
	hinge = hinge.normalized()
	# The grip: half way along the pincers past the wrist.
	var reach := 0.0
	for p: int in pincers:
		for v in (parts[p][Mesh.ARRAY_VERTEX] as PackedVector3Array):
			reach = maxf(reach, (v + (heads[p] as Vector3) - wrist).dot(along))
	var grip := wrist + along * (reach * 0.5)
	var axes: Array = []
	var angles: Array = []
	axes.resize(Part.size())
	angles.resize(Part.size())
	for p: int in pincers:
		var side: Vector3 = sides[p]
		if side.length() < 0.001:
			side = hinge if p == pincers[pincers.size() - 1] and pincers.size() > 1 else -hinge
		side = side.normalized()
		# Turning about side x along swings the pincer's side towards the arm's line: it closes.
		var axis := side.cross(along).normalized()
		axes[p] = axis
		angles[p] = _close_angle(parts[p][Mesh.ARRAY_VERTEX], (heads[p] as Vector3) - wrist, axis, side)
	var pivot: Vector3 = heads[Part.TURNTABLE] if heads[Part.TURNTABLE] != null and parts[Part.TURNTABLE] != null else shoulder
	return {"turn": turn, "pivot": pivot, "shoulder": shoulder, "elbow": elbow, "wrist": wrist, "grip": grip,
		"lengths": [shoulder.distance_to(elbow), elbow.distance_to(grip)], "hinge": hinge,
		"heads": heads, "axes": axes, "angles": angles}


## The yaw (radians, a quarter turn's multiple) that turns the platform's furthest-reaching side to
## the north (-Z); 0 when no side stands out by FACING_MARGIN.
static func facing(points: PackedVector3Array) -> float:
	if points.is_empty():
		return 0.0
	var dirs := [Vector3.FORWARD, Vector3.RIGHT, Vector3.BACK, Vector3.LEFT]  # north, east, south, west
	var reach := [-INF, -INF, -INF, -INF]
	for v in points:
		for k in 4:
			reach[k] = maxf(reach[k], v.dot(dirs[k]))
	var best := 0
	for k in 4:
		if reach[k] > reach[best]:
			best = k
	var second := -INF
	for k in 4:
		if k != best:
			second = maxf(second, reach[k])
	if best == 0 or reach[best] - second < FACING_MARGIN:
		return 0.0
	# Basis(UP, a) turns east (+X) to north by +PI/2, south by PI, west by -PI/2.
	return [0.0, PI / 2.0, PI, -PI / 2.0][best]


## How far a pincer turns about `axis` (through its joint) before its outer half reaches the plane
## between the pincers. `verts` are relative to the joint, `joint` is the joint relative to the
## wrist, `side` points from that plane towards this pincer.
static func _close_angle(verts: PackedVector3Array, joint: Vector3, axis: Vector3, side: Vector3) -> float:
	var far := 0.0
	for v in verts:
		far = maxf(far, v.length())
	var outer := PackedVector3Array()
	for v in verts:
		if v.length() >= far * 0.5:
			outer.append(v)
	var a := 0.0
	while a + CLOSE_STEP <= MAX_CLOSE:
		var turned := Basis(axis, a + CLOSE_STEP)
		var met := false
		for v in outer:
			if (turned * v + joint).dot(side) <= 0.0:
				met = true
				break
		if met:
			break
		a += CLOSE_STEP
	return a
