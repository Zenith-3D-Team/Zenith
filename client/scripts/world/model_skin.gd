extends RefCounted
## A model's baked (skeletal) animation, played by the model shader while the machine works.
##
## A modeller's .glb may carry one skinned mesh and an action that moves its bones (Blender: an
## armature, exported with its animation). Zenith draws models instanced and flattened, so nothing
## plays the skeleton: instead each bone's matrix at each frame of the action is worked out here
## (from the glTF itself: nodes, skin, animation samplers) into a texture, every vertex keeps its four
## bones and weights in CUSTOM3, and the shader (factorio_material.gdshaderinc, anim_mode 8) blends
## them at the frame the machine's own clock has reached: running while it works, coasting to a
## stop when it stops, as every other moving part. Triangles only on bones that never move stay in
## the model's body; the rest become one moving part, "baked" (model_library.gd Load).
## Worker-thread safe: plain arrays and an ImageTexture.

## Frames a second the action is sampled at (between frames the shader blends).
const FPS := 30.0
const MAX_FRAMES := 512
## Bones whose matrix changes less than this over the action count as still.
const STILL := 0.0005


## What a .glb's skeleton and actions need (or {} when it has neither a skin nor animated objects):
##   rest       per skin joint, the matrix that puts a stored vertex in the skin's rest pose, before
##              the mesh object's transform (glTF skins ignore that transform; Zenith then applies it)
##   node_joints  glTF node -> joint: objects with a mesh that the actions move (a roller, a lid),
##              each played as a bone of its own after the skin's joints
##   animated   true when something moves; then also frames, duration (s), tex (ImageTexture RGBAF:
##              3 texels a joint, a row a frame), image, moving (PackedByteArray: 1 a joint that moves)
## Every action is played at once (Blender exports one per object), each looping on its own length.
static func bake(path: String) -> Dictionary:
	var glb := _read(path)
	if glb.is_empty():
		return {}
	var doc: Dictionary = glb["doc"]
	var skins: Array = doc.get("skins", [])
	var anims: Array = doc.get("animations", [])
	var nodes: Array = doc.get("nodes", [])
	var parent := {}
	for i in nodes.size():
		for c in (nodes[i] as Dictionary).get("children", []):
			parent[int(c)] = i
	# Every action's channels by node, each with its action's length.
	var tracks := {}  # node -> {path -> [times, values, interpolation, length]}
	var duration := 0.0
	for anim: Dictionary in anims:
		var samplers: Array = anim.get("samplers", [])
		var length := 0.0
		var chans: Array = []
		for ch: Dictionary in anim.get("channels", []):
			var target: Dictionary = ch.get("target", {})
			if not target.has("node"):
				continue
			var smp: Dictionary = samplers[int(ch["sampler"])]
			var times := _floats(glb, int(smp["input"]))
			var values := _floats(glb, int(smp["output"]))
			if times.is_empty():
				continue
			length = maxf(length, times[times.size() - 1])
			chans.append([int(target["node"]), str(target["path"]), times, values, str(smp.get("interpolation", "LINEAR"))])
		for c: Array in chans:
			if not tracks.has(c[0]):
				tracks[c[0]] = {}
			tracks[c[0]][c[1]] = [c[2], c[3], c[4], length]
		duration = maxf(duration, length)
	var joints: Array = []
	var inv_binds: Array = []
	var mesh_xform := Transform3D.IDENTITY
	if not skins.is_empty():
		var skin: Dictionary = skins[0]
		joints = skin.get("joints", [])
		var m := _floats(glb, int(skin["inverseBindMatrices"])) if skin.has("inverseBindMatrices") else PackedFloat32Array()
		for j in joints.size():
			inv_binds.append(_mat(m, j * 16) if m.size() >= (j + 1) * 16 else Transform3D.IDENTITY)
		for i in nodes.size():
			if (nodes[i] as Dictionary).has("skin") and (nodes[i] as Dictionary).has("mesh"):
				mesh_xform = _global(nodes, parent, {}, i, 0.0)
				break
	var unmesh := mesh_xform.affine_inverse()
	var animated := duration >= 1.5 / FPS
	# Objects with a mesh (not skinned) whose place the actions change.
	var node_joints := {}
	var node_list: Array = []
	if animated:
		for i in nodes.size():
			var n: Dictionary = nodes[i]
			if n.has("mesh") and not n.has("skin") and _animated_chain(i, parent, tracks):
				node_joints[i] = joints.size() + node_list.size()
				node_list.append(i)
	if joints.is_empty() and node_list.is_empty():
		return {}
	var rest: Array = []
	var rest_cache := {}
	for j in joints.size():
		# Applied before the loader moves the vertices by the mesh object's transform (merged()), so
		# that transform is undone first: drawn, the vertex lands where glTF's skin puts it.
		rest.append(unmesh * _global(nodes, parent, {}, int(joints[j]), 0.0, rest_cache) * inv_binds[j])
	# The skeleton as built, for a rig drawn by Zenith (model_rig.gd): each joint's name, inverse bind
	# matrix and parent joint (-1 at the root).
	var names := PackedStringArray()
	var joint_of := {}
	for j in joints.size():
		joint_of[int(joints[j])] = j
		names.append(str((nodes[int(joints[j])] as Dictionary).get("name", "")))
	var joint_parents := PackedInt32Array()
	for j in joints.size():
		var up := -1
		var n := int(joints[j])
		while parent.has(n):
			n = parent[n]
			if joint_of.has(n):
				up = joint_of[n]
				break
		joint_parents.append(up)
	var out := {"rest": rest, "node_joints": node_joints, "animated": false, "joints": joints.size() + node_list.size(),
		"names": names, "binds": inv_binds, "joint_parents": joint_parents, "mesh_xform": mesh_xform}
	if not animated:
		return out
	var count := joints.size() + node_list.size()
	var node_rest: Array = []
	for i: int in node_list:
		node_rest.append(_global(nodes, parent, {}, i, 0.0, rest_cache).affine_inverse())
	var frames := clampi(int(ceil(duration * FPS)) + 1, 2, MAX_FRAMES)
	var image := Image.create_empty(count * 3, frames, false, Image.FORMAT_RGBAF)
	var first: Array = []
	var moving := PackedByteArray()
	moving.resize(count)
	for f in frames:
		var t := duration * float(f) / float(frames - 1)
		var cache := {}
		for j in count:
			var m: Transform3D
			if j < joints.size():
				# The skin as glTF poses it (the joint's place by its inverse bind), from the drawn vertex.
				m = _global(nodes, parent, tracks, int(joints[j]), t, cache) * inv_binds[j] * unmesh
			else:
				var k := j - joints.size()
				m = _global(nodes, parent, tracks, int(node_list[k]), t, cache) * node_rest[k]
			for r in 3:
				image.set_pixel(j * 3 + r, f, Color(m.basis.x[r], m.basis.y[r], m.basis.z[r], m.origin[r]))
			if f == 0:
				first.append(m)
			elif not moving[j] and not _same(m, first[j]):
				moving[j] = 1
	var any := false
	for j in moving.size():
		any = any or moving[j] == 1
	if not any:
		return out
	out.merge({"animated": true, "frames": frames, "duration": duration,
		"tex": ImageTexture.create_from_image(image), "image": image, "moving": moving}, true)
	return out


## Drawn positions and normals of a skinned surface put in the skin's rest pose (bones and weights
## per vertex, 4 each), as Blender shows the model.
static func pose(arrays: Array, rest: Array) -> void:
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: Variant = arrays[Mesh.ARRAY_NORMAL]
	if bones.size() != verts.size() * 4:
		return
	for v in verts.size():
		var p := Vector3.ZERO
		var n := Vector3.ZERO
		var total := 0.0
		for k in 4:
			var w := weights[v * 4 + k]
			var b := bones[v * 4 + k]
			if w <= 0.0 or b >= rest.size():
				continue
			var m: Transform3D = rest[b]
			p += w * (m * verts[v])
			if normals is PackedVector3Array:
				n += w * (m.basis * (normals as PackedVector3Array)[v])
			total += w
		if total > 0.0:
			verts[v] = p / total
			if normals is PackedVector3Array:
				(normals as PackedVector3Array)[v] = n.normalized()
	arrays[Mesh.ARRAY_VERTEX] = verts
	if normals is PackedVector3Array:
		arrays[Mesh.ARRAY_NORMAL] = normals


## True when node i or one of its parents is moved by an action.
static func _animated_chain(i: int, parent: Dictionary, tracks: Dictionary) -> bool:
	while true:
		if tracks.has(i):
			return true
		if not parent.has(i):
			return false
		i = parent[i]
	return false


## The box a baked part's vertices may reach: its rest box carried by every moving bone at every frame.
static func box_of(bake: Dictionary, rest: AABB) -> AABB:
	var image: Image = bake["image"]
	var moving: PackedByteArray = bake["moving"]
	var box := rest
	for f in int(bake["frames"]):
		for j in moving.size():
			if moving[j] == 0:
				continue
			var r0 := image.get_pixel(j * 3, f)
			var r1 := image.get_pixel(j * 3 + 1, f)
			var r2 := image.get_pixel(j * 3 + 2, f)
			var m := Transform3D(Basis(Vector3(r0.r, r1.r, r2.r), Vector3(r0.g, r1.g, r2.g), Vector3(r0.b, r1.b, r2.b)),
				Vector3(r0.a, r1.a, r2.a))
			box = box.merge(m * rest)
	return box


## Each vertex's four bones and weights for CUSTOM3: bone + weight * 0.999 per channel, so the shader
## reads the bone with floor() and the weight with fract() (renormalised there). Weights are bones of
## the skin's joint list, as glTF's JOINTS_0.
static func pack(bones: PackedInt32Array, weights: PackedFloat32Array, count: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(count * 4)
	var per := bones.size() / maxi(count, 1)
	for v in count:
		for k in 4:
			if k < per:
				out[v * 4 + k] = float(bones[v * per + k]) + clampf(weights[v * per + k], 0.0, 1.0) * 0.999
	return out


## True when any of the vertex's bones with weight moves.
static func moves(bake: Dictionary, bones: PackedInt32Array, weights: PackedFloat32Array, v: int) -> bool:
	var moving: PackedByteArray = bake["moving"]
	for k in 4:
		var i := v * 4 + k
		if i < weights.size() and weights[i] > 0.01 and bones[i] < moving.size() and moving[bones[i]] == 1:
			return true
	return false


static func _same(a: Transform3D, b: Transform3D) -> bool:
	return (a.origin - b.origin).length() < STILL and (a.basis.x - b.basis.x).length() < STILL \
		and (a.basis.y - b.basis.y).length() < STILL and (a.basis.z - b.basis.z).length() < STILL


## Node i's transform in the scene at time t (its animated or rest TRS, times its parents').
static func _global(nodes: Array, parent: Dictionary, tracks: Dictionary, i: int, t: float, cache := {}) -> Transform3D:
	if i < 0 or i >= nodes.size():
		return Transform3D.IDENTITY
	if cache.has(i):
		return cache[i]
	var local := _local(nodes[i], tracks.get(i, {}), t)
	var out := local
	if parent.has(i):
		out = _global(nodes, parent, tracks, int(parent[i]), t, cache) * local
	cache[i] = out
	return out


static func _local(node: Dictionary, track: Dictionary, t: float) -> Transform3D:
	if node.has("matrix") and track.is_empty():
		var m: Array = node["matrix"]
		var f := PackedFloat32Array()
		for x in m:
			f.append(float(x))
		return _mat(f, 0)
	var tr: Array = node.get("translation", [0, 0, 0])
	var ro: Array = node.get("rotation", [0, 0, 0, 1])
	var sc: Array = node.get("scale", [1, 1, 1])
	var pos := Vector3(tr[0], tr[1], tr[2])
	var rot := Quaternion(ro[0], ro[1], ro[2], ro[3])
	var scl := Vector3(sc[0], sc[1], sc[2])
	if track.has("translation"):
		var v := _sample(track["translation"], t, 3)
		pos = Vector3(v[0], v[1], v[2])
	if track.has("rotation"):
		var q := _sample(track["rotation"], t, 4, true)
		rot = Quaternion(q[0], q[1], q[2], q[3]).normalized()
	if track.has("scale"):
		var s := _sample(track["scale"], t, 3)
		scl = Vector3(s[0], s[1], s[2])
	return Transform3D(Basis(rot).scaled(scl), pos)


## A channel's value at t: LINEAR (slerp for rotations), STEP, or CUBICSPLINE's values (no tangents).
static func _sample(ch: Array, t: float, width: int, quat := false) -> PackedFloat32Array:
	if ch.size() > 3 and float(ch[3]) > 0.0 and t > float(ch[3]):
		t = fmod(t, float(ch[3]))
	var times: PackedFloat32Array = ch[0]
	var values: PackedFloat32Array = ch[1]
	var cubic: bool = ch[2] == "CUBICSPLINE"
	var stride := width * (3 if cubic else 1)
	var off := width if cubic else 0
	var n := times.size()
	var k := 0
	while k + 1 < n and times[k + 1] <= t:
		k += 1
	var a := PackedFloat32Array()
	a.resize(width)
	for c in width:
		a[c] = values[k * stride + off + c]
	if k + 1 >= n or ch[2] == "STEP" or t <= times[k]:
		return a
	var u := clampf((t - times[k]) / maxf(times[k + 1] - times[k], 1e-6), 0.0, 1.0)
	var b := PackedFloat32Array()
	b.resize(width)
	for c in width:
		b[c] = values[(k + 1) * stride + off + c]
	if quat:
		var q := Quaternion(a[0], a[1], a[2], a[3]).normalized().slerp(Quaternion(b[0], b[1], b[2], b[3]).normalized(), u)
		return PackedFloat32Array([q.x, q.y, q.z, q.w])
	for c in width:
		a[c] = lerpf(a[c], b[c], u)
	return a


## A column-major glTF 4x4 at offset o.
static func _mat(m: PackedFloat32Array, o: int) -> Transform3D:
	return Transform3D(Basis(Vector3(m[o], m[o + 1], m[o + 2]), Vector3(m[o + 4], m[o + 5], m[o + 6]),
		Vector3(m[o + 8], m[o + 9], m[o + 10])), Vector3(m[o + 12], m[o + 13], m[o + 14]))


## The .glb's JSON and binary chunk, or {}.
static func _read(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() < 20 or f.get_32() != 0x46546C67:
		return {}
	f.get_32()
	f.get_32()
	var json_len := f.get_32()
	f.get_32()
	var doc = JSON.parse_string(f.get_buffer(json_len).get_string_from_utf8())
	if not doc is Dictionary:
		return {}
	var bin := PackedByteArray()
	if f.get_position() + 8 <= f.get_length():
		var bin_len := f.get_32()
		f.get_32()
		bin = f.get_buffer(bin_len)
	return {"doc": doc, "bin": bin}


## An accessor's floats (FLOAT components only, as animation and matrix data are).
static func _floats(glb: Dictionary, index: int) -> PackedFloat32Array:
	var doc: Dictionary = glb["doc"]
	var acc: Dictionary = doc["accessors"][index]
	if int(acc.get("componentType", 5126)) != 5126 or not acc.has("bufferView"):
		return PackedFloat32Array()
	var view: Dictionary = doc["bufferViews"][int(acc["bufferView"])]
	var widths := {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}
	var width: int = widths.get(str(acc.get("type", "SCALAR")), 1)
	var count := int(acc["count"]) * width
	var start := int(view.get("byteOffset", 0)) + int(acc.get("byteOffset", 0))
	var stride := int(view.get("byteStride", 0))
	var bin: PackedByteArray = glb["bin"]
	if stride == 0 or stride == width * 4:
		return bin.slice(start, start + count * 4).to_float32_array()
	var out := PackedFloat32Array()
	for e in int(acc["count"]):
		out.append_array(bin.slice(start + e * stride, start + e * stride + width * 4).to_float32_array())
	return out
