extends RefCounted
## A belt's return run: the belt coming back underneath its rollers, as a real conveyor's does (owner's
## request). A modeller's textured belt surface (Vasillo's) carries its return already: a strip just
## above the ground facing down, its UVs running the other way round the loop, and his start and end
## pieces wrap the belt round their rollers onto it. Models are drawn one side to a face (cull_back), so
## from above that strip was never drawn: between the rollers, through the open frame, the ground
## showed where the belt should come back. The return drawn here is that strip's inner side (the same
## place, facing up at the rollers), so it meets the end pieces' wraps where the modeller put them. A
## surface with no return of its own gets its top run mirrored top to bottom, its lowest point FLOOR
## above the ground (where Vasillo's returns and wraps end), its UVs mirrored along the belt. Either way
## the same scroll (model_library.gd _setup_belt) runs it the other way at the same speed, and no shader
## changes.
##
## Built once per model on the model's worker (model_library.gd Load) and drawn in the surface's own
## draw (no draw call of its own). The CPU copy of the model's arrays (ModelLods.ARRAYS_META) leaves it
## out, so the scroll's fit, the levels of detail (a textured model's first level comes at 64 px on
## screen), the shadow stand-ins and far merged chunks have none: it is only seen close up, and the
## stand-in's shadow of the top run falls on it. Only textured belt surfaces (a modeller's): Zenith's
## own belts are slabs lying in a closed frame with no end pieces, where nothing under them shows.
## The end pieces (`-start`, `-end`) get none: their surface is the wrap round the roller itself.
## --belt-return=off draws none (docs/RUNNING.md). The return's triangles come first in the draw
## (joined), the top run's after: a surface drawn blended (no depth written, the last triangle drawn
## wins) shows its top run over the return, not the return's backward chevrons over it;
## --belt-return-first=off puts them after, as before 0.2.2.

const Switches := preload("res://scripts/switches.gd")

## On unless --belt-return=off.
static var enabled := Switches.on("--belt-return")
## The space under the top run (return strip, rollers) shaded as a covered space, unless --belt-cover=off.
static var cover_on := Switches.on("--belt-cover")
## The return's triangles drawn before the top run's, unless --belt-return-first=off.
static var first := Switches.on("--belt-return-first")
## Meta on a model's ArrayMesh: per surface the return drawn after its arrays (null: none), so a copy
## of the model (model_library.gd _copy: a tier wearing another's model) draws it too.
const META := &"f3d_belt_return"
## A face counts as the top run (or the return) when its normal is this much up (down).
const UP := 0.5
## The model's own return lies at least this far (tiles) under the top run's lowest point: room for
## the rollers (Vasillo's: 0.2). A textured slab's own underside, closer, isn't a return.
const GAP := 0.1
## A mirrored top run's lowest point above the ground (tiles): where Vasillo's returns and his end
## pieces' wraps come down to (0.006), so a line's runs meet the wraps.
const FLOOR := 0.006
## The return's baked occlusion (COLOR.a; textured models square it, TEXTURED_AO): it lies under the
## top run with the rollers between, in the shade. Its own bake (0, facing the ground) drew it black.
const SHADE := 0.7


## The shape a model's return needs (0 straight, 1 left curve, 2 right curve), or -1 when it gets none:
## switched off, or a line's end piece.
static func shape_for(name: String) -> int:
	if not enabled or name.ends_with("-start") or name.ends_with("-end"):
		return -1
	if name.ends_with("-curve-left"):
		return 1
	if name.ends_with("-curve-right"):
		return 2
	return 0


## True for a modeller's textured belt surface (a glTF material named like belt_surface, with a picture).
static func is_surface(material: Material) -> bool:
	var base := material as BaseMaterial3D
	return base != null and base.albedo_texture != null and base.resource_name.to_lower().contains("belt_surface")


## Per group of a Load ([keys, arrays, formats]) the return drawn after it, or null; empty when none has one.
static func for_groups(groups: Array, shape: int) -> Array:
	if shape < 0:
		return []
	var out: Array = []
	var any := false
	for g: Array in groups:
		var keys: Array = g[0]
		var ret: Variant = null
		if keys.size() == 1 and is_surface((keys[0] as Array)[0]):
			ret = build(g[1], shape)
		out.append(ret)
		any = any or ret != null
	return out if any else []


## A belt surface's return as arrays of its own (every per-vertex array the surface has, in step), or
## null when it has no top run to go under.
static func build(arrays: Array, shape: int) -> Variant:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: Variant = arrays[Mesh.ARRAY_NORMAL]
	if verts.is_empty() or not normals is PackedVector3Array or (normals as PackedVector3Array).size() != verts.size():
		return null
	var n: PackedVector3Array = normals
	var idx: PackedInt32Array
	if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array and not (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).is_empty():
		idx = arrays[Mesh.ARRAY_INDEX]
	else:
		idx = PackedInt32Array(range(verts.size()))
	var top := PackedInt32Array()
	var under := PackedInt32Array()
	var top_low := INF
	var top_high := -INF
	for t in range(0, idx.size() - 2, 3):
		var a := idx[t]
		var b := idx[t + 1]
		var c := idx[t + 2]
		var up := (n[a].y + n[b].y + n[c].y) / 3.0
		if up > UP:
			top.append(t)
			top_low = minf(top_low, minf(verts[a].y, minf(verts[b].y, verts[c].y)))
			top_high = maxf(top_high, maxf(verts[a].y, maxf(verts[b].y, verts[c].y)))
		elif up < -UP:
			under.append(t)
	if top.is_empty():
		return null
	var own := PackedInt32Array()
	for t in under:
		if maxf(verts[idx[t]].y, maxf(verts[idx[t + 1]].y, verts[idx[t + 2]].y)) < top_low - GAP:
			own.append(t)
	var out: Array
	if not own.is_empty():
		# Its inner side: the same faces turned to face up (normals flipped, winding reversed).
		out = _subset(arrays, idx, own)
		var on: PackedVector3Array = out[Mesh.ARRAY_NORMAL]
		for i in on.size():
			on[i] = -on[i]
		out[Mesh.ARRAY_NORMAL] = on
		var oi: PackedInt32Array = out[Mesh.ARRAY_INDEX]
		for t in range(0, oi.size() - 2, 3):
			var k := oi[t + 1]
			oi[t + 1] = oi[t + 2]
			oi[t + 2] = k
		out[Mesh.ARRAY_INDEX] = oi
	else:
		out = _mirrored(arrays, idx, top, top_high, shape)
		if out.is_empty():
			return null
	if out[Mesh.ARRAY_COLOR] is PackedColorArray:
		var colors: PackedColorArray = out[Mesh.ARRAY_COLOR]
		for i in colors.size():
			var shaded := colors[i]
			shaded.a = SHADE
			colors[i] = shaded
		out[Mesh.ARRAY_COLOR] = colors
	return out


## The top run mirrored top to bottom, its highest point coming down to FLOOR. Mirroring keeps the
## winding facing up, the normals' up with it (x and z turn over); the UVs are mirrored along the way the
## texture runs (its fit, as the scroll's), so the same scroll runs the return backwards. Empty without
## a fit.
static func _mirrored(arrays: Array, idx: PackedInt32Array, top: PackedInt32Array, top_high: float, shape: int) -> Array:
	var out := _subset(arrays, idx, top)
	if not out[Mesh.ARRAY_TEX_UV] is PackedVector2Array:
		return []
	var along := uv_fit(out, shape)
	if along.length_squared() < 1e-8:
		return []
	var dir := along.normalized()
	var uvs: PackedVector2Array = out[Mesh.ARRAY_TEX_UV]
	var mid := Vector2.ZERO
	for uv in uvs:
		mid += uv
	mid /= float(maxi(uvs.size(), 1))
	for i in uvs.size():
		uvs[i] -= 2.0 * dir * (uvs[i] - mid).dot(dir)
	out[Mesh.ARRAY_TEX_UV] = uvs
	var plane := (top_high + FLOOR) * 0.5
	var verts: PackedVector3Array = out[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = out[Mesh.ARRAY_NORMAL]
	for i in verts.size():
		var p := verts[i]
		verts[i] = Vector3(p.x, 2.0 * plane - p.y, p.z)
		normals[i] = Vector3(-normals[i].x, normals[i].y, -normals[i].z)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = normals
	return out


## The chosen triangles (their first indices) with their own vertices, every per-vertex array taken along.
static func _subset(arrays: Array, idx: PackedInt32Array, tris: PackedInt32Array) -> Array:
	var count := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var remap := PackedInt32Array()
	remap.resize(count)
	remap.fill(-1)
	var order := PackedInt32Array()
	var out_idx := PackedInt32Array()
	for t in tris:
		for k in 3:
			var v := idx[t + k]
			if remap[v] < 0:
				remap[v] = order.size()
				order.append(v)
			out_idx.append(remap[v])
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	for type in Mesh.ARRAY_MAX:
		var src: Variant = arrays[type]
		if type == Mesh.ARRAY_INDEX or src == null:
			continue
		var per: int = src.size() / count
		var dst: Variant = src.duplicate()
		dst.resize(order.size() * per)
		for i in order.size():
			for c in per:
				dst[i * per + c] = src[order[i] * per + c]
		out[type] = dst
	out[Mesh.ARRAY_INDEX] = out_idx
	return out


## A surface's arrays with its return, for drawing (new arrays; neither is changed): the vertices the
## surface's then the return's, the return's triangles drawn first (`first`; after with it off).
static func joined(arrays: Array, ret: Array) -> Array:
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	var base := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	for type in Mesh.ARRAY_MAX:
		if type == Mesh.ARRAY_INDEX or arrays[type] == null:
			continue
		var both: Variant = arrays[type].duplicate()
		both.append_array(ret[type])
		out[type] = both
	var idx: PackedInt32Array
	if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array and not (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).is_empty():
		idx = (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).duplicate()
	else:
		idx = PackedInt32Array(range(base))
	var back := PackedInt32Array()
	for k in (ret[Mesh.ARRAY_INDEX] as PackedInt32Array):
		back.append(base + k)
	if first:
		back.append_array(idx)
		idx = back
	else:
		idx.append_array(back)
	out[Mesh.ARRAY_INDEX] = idx
	return out


## The covered space under a belt's top run, for the shader's belt_cover: (lowest y of the top run, the
## lateral range of its width [|x| on a straight, the distance from a curve's centre on a curve], 1), or
## Vector4.ZERO when switched off (--belt-cover=off) or there is no top run. The rollers and the return
## strip lie below that height and inside that range; the frame's rails lie outside it.
static func cover(arrays: Array, shape: int) -> Vector4:
	if not cover_on:
		return Vector4.ZERO
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: Variant = arrays[Mesh.ARRAY_NORMAL]
	if verts.is_empty() or not normals is PackedVector3Array or (normals as PackedVector3Array).size() != verts.size():
		return Vector4.ZERO
	var low := INF
	var lo := INF
	var hi := -INF
	var side := 1.0 if shape == 1 else -1.0
	for v in verts.size():
		if (normals as PackedVector3Array)[v].y <= UP:
			continue
		var p := verts[v]
		low = minf(low, p.y)
		var lat := absf(p.x)
		if shape > 0:
			lat = (Vector2(p.x, p.z) - Vector2(-0.5 * side, -0.5)).length()
		lo = minf(lo, lat)
		hi = maxf(hi, lat)
	if low == INF:
		return Vector4.ZERO
	if shape == 0:
		lo = 0.0 # the strip is symmetric about the belt's axis; its vertices sit at the edges, not the middle
	return Vector4(low, lo, hi, 1.0)


## How far the return lies under its belt and how its texture runs, for tests: [lowest, highest y of the
## return, its UVs' change per tile along the belt].
static func describe(ret: Array, shape: int) -> Array:
	var low := INF
	var high := -INF
	for v in (ret[Mesh.ARRAY_VERTEX] as PackedVector3Array):
		low = minf(low, v.y)
		high = maxf(high, v.y)
	return [low, high, uv_fit(ret, shape)]


## How a textured belt surface's UVs change per tile along the belt (a least-squares fit of U and V
## against the distance along it: -z, or a curve's arc, as the shader's belt_coords), from the faces
## looking up (model_library.gd _belt_uv_scroll: a surface that wraps round under the belt runs back the
## other way underneath, and fitting both cancelled to nothing). `runs_east`: a line's end piece, modelled
## with the belt running east. Zero without UVs or a spread along the belt.
static func uv_fit(arrays: Array, shape: int, runs_east := false) -> Vector2:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: Variant = arrays[Mesh.ARRAY_TEX_UV]
	if not uvs is PackedVector2Array or verts.is_empty() or (uvs as PackedVector2Array).size() != verts.size():
		return Vector2.ZERO
	var normals: Variant = arrays[Mesh.ARRAY_NORMAL]
	var top: Array[int] = []
	if normals is PackedVector3Array and (normals as PackedVector3Array).size() == verts.size():
		for v in verts.size():
			if (normals as PackedVector3Array)[v].y > UP:
				top.append(v)
	if top.size() < 3:
		top.clear()
		for v in verts.size():
			top.append(v)
	var n := float(top.size())
	var ms := 0.0
	var mu := Vector2.ZERO
	var ss: Array[float] = []
	for v in top:
		var p := verts[v]
		var along := p.x if runs_east else -p.z
		if shape > 0:
			var side := 1.0 if shape == 1 else -1.0
			var d := Vector2(p.x, p.z) - Vector2(-0.5 * side, -0.5)
			along = atan2(-d.y, d.x * side) / (PI * 0.5) + 0.5
		ss.append(along)
		ms += along
		mu += (uvs as PackedVector2Array)[v]
	ms /= n
	mu /= n
	var var_s := 0.0
	var cov := Vector2.ZERO
	for k in top.size():
		var ds := ss[k] - ms
		var_s += ds * ds
		cov += ds * ((uvs as PackedVector2Array)[top[k]] - mu)
	return cov / var_s if var_s > 1e-6 else Vector2.ZERO
