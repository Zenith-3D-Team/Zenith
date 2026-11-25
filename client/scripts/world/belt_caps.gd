extends RefCounted
## Closing the open ends of a belt model's side plates (L3). Vasillo's belts, curves, `-start` pieces,
## splitters and undergrounds build each side plate of the frame as a box open at both ends: a hole
## 0.035 x 0.131 tiles at each plate end. Along a line each open end meets the next piece's, but where a
## line ends (the `-end` piece is the belt's wrap round its roller, no frame) or starts, and at a
## splitter's or underground's open side, the hole shows: models are drawn one side to a face
## (cull_back), so through it the plate's inner faces are culled and the ground shows.
##
## Each such hole is a small closed loop of boundary edges (edges only one triangle uses, vertices
## welded by position), flat, with the plate's faces round it standing across its plane. It gets a cap:
## a fan of triangles wound against the loop's edges (so it faces out as the plate's faces do), each
## vertex a copy of the plate's vertex there (its material's row, UVs, colour, weights), with the cap's
## normal. Loops that are large, not flat, not upright (holes in a splitter's top, under its bolts), or
## whose faces lie in their own plane (a lone card, a belt surface's edge) are left open. Done once per model on its worker (model_library.gd Load), into the
## arrays themselves, so the levels of detail, shadow stand-ins and far chunks have the caps too and a
## frame costs nothing more. Zenith's own belts, Wube's and FUE5's are closed: nothing is found there.
## --belt-caps=off leaves the holes (docs/RUNNING.md).

const Switches := preload("res://scripts/switches.gd")

## On unless --belt-caps=off.
static var enabled := Switches.on("--belt-caps")
## Meta on a model's ArrayMesh: how many caps its load added (for tests and the log).
const META := &"f3d_belt_caps"
## A hole is capped only when no side of its box is longer than this (tiles): Vasillo's are 0.131.
const MAX_SIZE := 0.25
## ...its loop has at most this many corners...
const MAX_CORNERS := 12
## ...every corner lies within this of the loop's plane...
const FLAT := 0.004
## ...it stands upright, as a plate's end does (|its normal's y| under this: holes in a splitter's top
## are where its bolts and pipes go in)...
const UPRIGHT := 0.1
## ...and no face along its edge lies in its plane (|normal . plane's normal| under this; Vasillo's
## front plate ends are bevelled, 0.74).
const ACROSS := 0.9
## Vertices closer than this (tiles) are one corner.
const WELD := 0.0001


## Whether a model of this file name is one of the belt family whose holes are looked for.
static func wanted(name: String) -> bool:
	return enabled and (name.contains("transport-belt") or name.ends_with("splitter") or name.contains("underground-belt"))


## Caps every small flat hole in `arrays` (a surface's, changed in place: vertices and triangles added
## at the end). Returns how many holes were capped. `log` gets a line per boundary loop found (tests).
static func cap(arrays: Array, log = null) -> int:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var count := verts.size()
	if count < 3:
		return 0
	var idx: PackedInt32Array
	if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array and not (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).is_empty():
		idx = arrays[Mesh.ARRAY_INDEX]
	else:
		idx = PackedInt32Array(range(count))
	# Weld by position.
	var weld := PackedInt32Array()
	weld.resize(count)
	var at := {}
	var corner := PackedVector3Array()
	for v in count:
		var p := verts[v]
		var key := Vector3i(roundi(p.x / WELD), roundi(p.y / WELD), roundi(p.z / WELD))
		var w: Variant = at.get(key)
		if w == null:
			w = corner.size()
			at[key] = w
			corner.append(p)
		weld[v] = int(w)
	# Each undirected edge's uses; its first directed use (from, to, the triangle's vertex at `from`).
	var uses := {}
	var first := {}
	for t in range(0, idx.size() - 2, 3):
		for k in 3:
			var va := idx[t + k]
			var vb := idx[t + (k + 1) % 3]
			var a := weld[va]
			var b := weld[vb]
			if a == b:
				continue
			var e := Vector2i(mini(a, b), maxi(a, b))
			uses[e] = int(uses.get(e, 0)) + 1
			if not first.has(e):
				first[e] = [a, b, va, vb, t]
	# A cap goes round its hole against the boundary edges: an edge a -> b of the plate is b -> a in it.
	var next := {}  # welded b -> [a, vertex at b, vertex at a, triangle]
	var forked := {}
	for e: Vector2i in uses:
		if int(uses[e]) != 1:
			continue
		var f: Array = first[e]
		var b: int = f[1]
		if next.has(b):
			forked[b] = true
		next[b] = [f[0], f[3], f[2], f[4]]
	if next.is_empty():
		return 0
	var n: Variant = arrays[Mesh.ARRAY_NORMAL]
	var normals: PackedVector3Array = n if n is PackedVector3Array and (n as PackedVector3Array).size() == count else PackedVector3Array()
	var seen := {}
	var caps: Array = []  # [corners' source vertices, the cap's normal]
	for start: int in next:
		if seen.has(start):
			continue
		var loop: Array[int] = []
		var src: Array[int] = []
		var tris: Array[int] = []
		var cur := start
		var closed := false
		while loop.size() <= MAX_CORNERS + 1:
			if seen.has(cur) or forked.has(cur) or not next.has(cur):
				closed = cur == start and not loop.is_empty()
				break
			seen[cur] = true
			var step: Array = next[cur]
			loop.append(cur)
			src.append(int(step[1]))
			tris.append(int(step[3]))
			cur = int(step[0])
		if log is Array:
			(log as Array).append(_describe(corner, loop, closed))
		if not closed or loop.size() < 3 or loop.size() > MAX_CORNERS:
			continue
		var normal := _loop_normal(corner, loop)
		if normal == Vector3.ZERO or absf(normal.y) >= UPRIGHT or not _small_flat(corner, loop, normal):
			continue
		var stands := true
		# The way the plate's own normals face against its winding (Godot's front faces wind clockwise,
		# so normally the opposite of the right-hand rule's): the cap's is made to face the same way.
		var facing := 0.0
		var worst := 0.0
		for t in tris:
			var fn := (verts[idx[t + 1]] - verts[idx[t]]).cross(verts[idx[t + 2]] - verts[idx[t]])
			if fn.length_squared() < 1e-14:
				continue
			worst = maxf(worst, absf(fn.normalized().dot(normal)))
			if absf(fn.normalized().dot(normal)) >= ACROSS:
				stands = false
			if not normals.is_empty():
				facing += fn.normalized().dot(normals[idx[t]] + normals[idx[t + 1]] + normals[idx[t + 2]])
		if log is Array:
			(log as Array).append("   normal %s, faces across: %s (%.3f)" % [normal, stands, worst])
		if stands:
			caps.append([src, normal * (1.0 if facing > 0.0 else -1.0)])
	if caps.is_empty():
		return 0
	_append(arrays, idx, caps, count)
	return caps.size()


## The loop's plane normal (Newell's), by the right-hand rule round the loop as it winds.
static func _loop_normal(corner: PackedVector3Array, loop: Array[int]) -> Vector3:
	var s := Vector3.ZERO
	for i in loop.size():
		var p := corner[loop[i]]
		var q := corner[loop[(i + 1) % loop.size()]]
		s += Vector3((p.y - q.y) * (p.z + q.z), (p.z - q.z) * (p.x + q.x), (p.x - q.x) * (p.y + q.y))
	return s.normalized() if s.length_squared() > 1e-14 else Vector3.ZERO


static func _describe(corner: PackedVector3Array, loop: Array[int], closed: bool) -> String:
	var lo := corner[loop[0]]
	var hi := lo
	for w in loop:
		lo = lo.min(corner[w])
		hi = hi.max(corner[w])
	return "loop of %d%s, from %s to %s" % [loop.size(), "" if closed else " (open)", lo, hi]


static func _small_flat(corner: PackedVector3Array, loop: Array[int], normal: Vector3) -> bool:
	var lo := corner[loop[0]]
	var hi := lo
	var mid := Vector3.ZERO
	for w in loop:
		lo = lo.min(corner[w])
		hi = hi.max(corner[w])
		mid += corner[w]
	mid /= float(loop.size())
	var size := hi - lo
	if maxf(size.x, maxf(size.y, size.z)) > MAX_SIZE:
		return false
	for w in loop:
		if absf((corner[w] - mid).dot(normal)) > FLAT:
			return false
	return true


## The caps' vertices (copies of the plate's corners, the cap's normal and tangent) and fans of
## triangles added to `arrays`.
static func _append(arrays: Array, idx: PackedInt32Array, caps: Array, count: int) -> void:
	var order := PackedInt32Array()
	var new_normals := PackedVector3Array()
	var out_idx := idx.duplicate()
	for c: Array in caps:
		var src: Array[int] = c[0]
		var base := count + order.size()
		for v in src:
			order.append(v)
			new_normals.append(c[1])
		for i in range(1, src.size() - 1):
			out_idx.append(base)
			out_idx.append(base + i)
			out_idx.append(base + i + 1)
	for type in Mesh.ARRAY_MAX:
		var data: Variant = arrays[type]
		if type == Mesh.ARRAY_INDEX or data == null:
			continue
		var per: int = data.size() / count
		var grown: Variant = data.duplicate()
		for i in order.size():
			for k in per:
				grown.append(data[order[i] * per + k])
		arrays[type] = grown
	if arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array:
		var nn: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for i in order.size():
			nn[count + i] = new_normals[i]
		arrays[Mesh.ARRAY_NORMAL] = nn
	if arrays[Mesh.ARRAY_TANGENT] is PackedFloat32Array:
		var tn: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
		for i in order.size():
			var nrm := new_normals[i]
			var tan := nrm.cross(Vector3.UP if absf(nrm.y) < 0.9 else Vector3.RIGHT).normalized()
			for k in 3:
				tn[(count + i) * 4 + k] = tan[k]
			tn[(count + i) * 4 + 3] = 1.0
		arrays[Mesh.ARRAY_TANGENT] = tn
	arrays[Mesh.ARRAY_INDEX] = out_idx
