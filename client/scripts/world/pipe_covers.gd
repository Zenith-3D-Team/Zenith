extends RefCounted
## Factorio's pipe covers: each fluid connection of a machine with nothing connected to it gets a cover
## (FluidBox `pipe_covers`, drawn by drills, assemblers, boilers, pumps...). Vasillo's wet electric mining
## drill has its pipes open at the drill's edge, a hollow end one looks into while no pipe is attached; he
## asked for the caps to be drawn there only when nothing is attached, rather than modelled closed.
##
## Which connections are open is worked out in world.gd (_cover: the record's `covers`, a bit per
## connection), from the prototype's fluid connections (`eprops` fb: [x, y facing north, way, flow]) and
## what stands on the tile each leads onto: a pipe whose `pc` reaches back, a pipe to ground facing it, or
## another machine with a connection back. A mining drill shows its connections only while it takes fluid
## (extra.fa bit 1, as its `-wet` part), a crafting machine only those its recipe uses (fa 1 in, 2 out), as
## Factorio draws them; the rest all theirs.
##
## The cover is the drawing pack's `pipe-cover` model if it has one (a connection facing north, on the
## connection's own tile: origin at that tile's centre, the cover at its north edge), else the end cap of
## its pipe kit: `pipe-ending-down` less `pipe-straight-vertical` (Vasillo's endings are his straight plus
## his pipe-cap, tools/models/fixes/vasillo.json), turned to the north edge. A pack with neither draws no
## covers (the built-in packs). Drawn by chunk_view.gd, one MultiMesh per chunk as every model.
## --pipe-covers=off: none (docs/RUNNING.md).

const ModelPacks := preload("res://scripts/world/model_packs.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const RenderReads := preload("res://scripts/world/render_reads.gd")
const PipeInsides := preload("res://scripts/world/pipe_insides.gd")
const Switches := preload("res://scripts/switches.gd")
const Wire := preload("res://scripts/util/wire.gd")

## On unless --pipe-covers=off.
static var enabled := Switches.on("--pipe-covers")
## --pipe-covers=own: use each entity's own drawing pack ending instead of the active pipe pack's caps.
static var follow_pipe_pack := Switches.value("--pipe-covers", "on") != "own"
## --pipe-cap-edge=old: keep extracted caps at their ending's inset Z instead of flush at -0.505.
static var flush_edge := not (Switches.has("--pipe-cap-edge=old"))
## Closed cap face Z in local cover space (slightly proud of -0.500 so flanges/drills don't bury it).
const CAP_EDGE_Z := -0.505
## The model a pack can give for its covers.
const MODEL := "pipe-cover"
## The pipe kit's pieces the end cap is taken from: the ending joined from the south (cap at the north
## edge, vasillo.json) and the straight it is made of.
const ENDING := "pipe-ending-down"
const STRAIGHT := "pipe-straight-vertical"
## Crafting machines: only the connections their recipe uses.
const CRAFTERS := ["assembling-machine", "furnace"]
## Default north-facing fluid ports of Factorio's electric mining drill (for standalone previews without eprops).
const WET_DRILL_PORTS := [[-1.0, 0.0, 12, "i"], [1.0, 0.0, 4, "i"], [0.0, 1.0, 8, "i"]]
## Vertex positions closer than this (tiles) are the same corner when telling the cap from the straight.
const SAME := 0.0005

## model_for's ending name -> [the ending's mesh, the straight's, [its cap] or []].
static var _covers := {}


## The connections of a prototype's `eprops` fb that are drawn for a record of `type` with `fa`:
## [[offset from the centre facing north (tiles), way (16-way direction its pipe leaves by)], ...], each
## with its index in fb (the bit in a record's `covers`): [[offset, way, index], ...].
static func ports(fb: Variant, type: String, fa: int) -> Array:
	var out: Array = []
	if not (fb is Array):
		return out
	if type == "mining-drill" and fa & 1 == 0:
		return out
	var crafter := CRAFTERS.has(type)
	for i in (fb as Array).size():
		var c = fb[i]
		if not (c is Array) or c.size() < 3:
			continue
		if crafter:
			var flow := str(c[3]) if c.size() > 3 else "b"
			var used := (fa & 1 != 0 and flow != "o") or (fa & 2 != 0 and flow != "i")
			if not used:
				continue
		out.append([Vector2(float(c[0]), float(c[1])), int(c[2]), i])
	return out


## A pipe-to-ground's single open surface connection (at its own tile, facing its dir).
static func ports_for_underground() -> Array:
	return [[Vector2.ZERO, 0, 0]]


static func _pack_cover_model(id: String) -> String:
	if id == "":
		return ""
	if ModelPacks.find_in(id, MODEL) != "":
		return MODEL + "@" + id
	if ModelPacks.find_in(id, ENDING) != "" and ModelPacks.find_in(id, STRAIGHT) != "":
		return ENDING + "@" + id
	return ""


## The model name of a pack's covers ("" none, or while the pack isn't known). Prefers an explicit
## `pipe-cover` in the entity's own drawing pack, otherwise follows the active pipe pack (`choices["pipe"]`
## or top-priority active pack with covers) so machines match the active pipe kit (`--pipe-covers=own`
## restores preferring the entity's own pack ending first).
static func model_for(pack: Dictionary) -> String:
	if not enabled or pack.is_empty() or ModelPacks.is_sprite_pack(pack):
		return ""
	var own_id := str(pack.get("id", ""))
	if own_id != "" and ModelPacks.find_in(own_id, MODEL) != "":
		return MODEL + "@" + own_id
	if not follow_pipe_pack:
		var own := _pack_cover_model(own_id)
		if own != "":
			return own
	var chosen := str(ModelPacks.choices.get("pipe", ""))
	if chosen != "":
		var chosen_pack := ModelPacks.pack(chosen)
		if not chosen_pack.is_empty() and bool(chosen_pack.get("on", false)) and not ModelPacks.is_sprite_pack(chosen_pack):
			var hit := _pack_cover_model(chosen)
			if hit != "":
				return hit
	for p: Dictionary in ModelPacks.active():
		if ModelPacks.is_sprite_pack(p):
			continue
		var hit := _pack_cover_model(str(p.get("id", "")))
		if hit != "":
			return hit
	if follow_pipe_pack:
		var own := _pack_cover_model(own_id)
		if own != "":
			return own
	return ""


## A pack's cover from its `ending` and `straight` meshes (model_for gave the ending): the ending's
## triangles less one of each the straight has (wound as they are), turned so they stand at the tile's north
## edge. null when none are left. Vasillo's straight ends in a band with the cap's very triangles, its plate
## facing into the tube; his ending adds the cap again with its inside (vasillo.json), so what is left is
## one whole cap, drawn from both sides.
static func cap_from(ending: Mesh, straight: Mesh) -> ArrayMesh:
	if ending == null or straight == null:
		return null
	var known := {}
	var straight_dir_set := {}
	var straight_has_rev := false
	for s in straight.get_surface_count():
		var arrays := _arrays(straight, s)
		var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count := idx.size() if not idx.is_empty() else pos.size()
		for t in range(0, count - 2, 3):
			var key := _triangle_key(pos, idx, t)
			known[key] = int(known.get(key, 0)) + 1
			straight_dir_set[key] = true
	for key: Variant in straight_dir_set:
		var k: Array = key
		if straight_dir_set.has(_reverse_key(k)):
			straight_has_rev = true
			break
	# PipeInsides doubles backfaces on `pipe-ending-down` while `pipe-straight-vertical` stays single-sided;
	# subtract both windings of `straight` when `ending` was doubled so reversed barrel faces don't survive.
	var ending_doubled := int(ending.get_meta(PipeInsides.META, 0)) > 0 and int(straight.get_meta(PipeInsides.META, 0)) == 0
	if not ending_doubled and not straight_has_rev and not straight_dir_set.is_empty():
		var ending_dir_set := {}
		for s in ending.get_surface_count():
			var arrays := _arrays(ending, s)
			var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var count := idx.size() if not idx.is_empty() else pos.size()
			for t in range(0, count - 2, 3):
				ending_dir_set[_triangle_key(pos, idx, t)] = true
		var matched_fwd := 0
		var matched_both := 0
		for key: Variant in straight_dir_set:
			var k: Array = key
			if ending_dir_set.has(k):
				matched_fwd += 1
				if ending_dir_set.has(_reverse_key(k)):
					matched_both += 1
		if matched_fwd > 0 and matched_both * 10 >= matched_fwd * 9:
			ending_doubled = true
	if ending_doubled:
		for s in straight.get_surface_count():
			var arrays := _arrays(straight, s)
			var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var count := idx.size() if not idx.is_empty() else pos.size()
			for t in range(0, count - 2, 3):
				var rkey := _reverse_key(_triangle_key(pos, idx, t))
				known[rkey] = int(known.get(rkey, 0)) + 1
	var kept: Array = []  # [surface, PackedInt32Array of its vertices' indices, three a triangle]
	var box := AABB()
	var any := false
	for s in ending.get_surface_count():
		var arrays := _arrays(ending, s)
		var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count := idx.size() if not idx.is_empty() else pos.size()
		var picked := PackedInt32Array()
		for t in range(0, count - 2, 3):
			var key := _triangle_key(pos, idx, t)
			if int(known.get(key, 0)) > 0:
				known[key] = int(known[key]) - 1
				continue
			for k in 3:
				var v := idx[t + k] if not idx.is_empty() else t + k
				picked.append(v)
				if any:
					box = box.expand(pos[v])
				else:
					box = AABB(pos[v], Vector3.ZERO)
					any = true
		if not picked.is_empty():
			kept.append([s, picked])
	if not any:
		var end_box := AABB()
		var end_first := true
		for s in ending.get_surface_count():
			var arrays := _arrays(ending, s)
			var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for p: Vector3 in pos:
				end_box = AABB(p, Vector3.ZERO) if end_first else end_box.expand(p)
				end_first = false
		if not end_first:
			var horiz := end_box.size.x > end_box.size.z
			var lo := end_box.position.x if horiz else end_box.position.z
			var hi := end_box.end.x if horiz else end_box.end.z
			var close_is_lo := absf(hi) >= absf(lo)
			var edge := lo if close_is_lo else hi
			for s in ending.get_surface_count():
				var arrays := _arrays(ending, s)
				var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
				var count := idx.size() if not idx.is_empty() else pos.size()
				var picked := PackedInt32Array()
				for t in range(0, count - 2, 3):
					var vs := [idx[t] if not idx.is_empty() else t,
						idx[t + 1] if not idx.is_empty() else t + 1,
						idx[t + 2] if not idx.is_empty() else t + 2]
					var inside := true
					for k in 3:
						var coord: float = pos[vs[k]].x if horiz else pos[vs[k]].z
						if (close_is_lo and coord > edge + 0.15) or (not close_is_lo and coord < edge - 0.15):
							inside = false
							break
					if not inside:
						continue
					for v: int in vs:
						picked.append(v)
						if any:
							box = box.expand(pos[v])
						else:
							box = AABB(pos[v], Vector3.ZERO)
							any = true
				if not picked.is_empty():
					kept.append([s, picked])
	if not any:
		return _procedural_cap(ending)
	# Turned so the closed cap face is at the north edge (-z), determined by axial-normal cap
	# triangles (or all kept centroids) rather than whole-residual AABB center, which a stray
	# pipe barrel shifts past z = 0.
	var axial_sum := Vector3.ZERO
	var axial_count := 0
	var cent_sum := Vector3.ZERO
	var cent_count := 0
	for entry: Array in kept:
		var s: int = int(entry[0])
		var picked: PackedInt32Array = entry[1]
		var pos: PackedVector3Array = _arrays(ending, s)[Mesh.ARRAY_VERTEX]
		for t in range(0, picked.size() - 2, 3):
			var p0: Vector3 = pos[picked[t]]
			var p1: Vector3 = pos[picked[t + 1]]
			var p2: Vector3 = pos[picked[t + 2]]
			var cent := (p0 + p1 + p2) / 3.0
			cent_sum += cent
			cent_count += 1
			var n := (p1 - p0).cross(p2 - p0)
			var nlen := n.length()
			if nlen > 1e-8 and (absf(n.x) > 0.5 * nlen or absf(n.z) > 0.5 * nlen):
				axial_sum += cent
				axial_count += 1
	var mid := axial_sum / float(axial_count) if axial_count > 0 else (cent_sum / float(cent_count) if cent_count > 0 else box.get_center())
	var turn := 0.0
	if absf(mid.x) > absf(mid.z):
		turn = PI / 2.0 if mid.x < 0.0 else -PI / 2.0
	elif mid.z > 0.0:
		turn = PI
	var basis := Basis(Vector3.UP, turn)
	var rot_min_z := INF
	var rot_max_z := -INF
	for entry: Array in kept:
		var s: int = int(entry[0])
		var picked: PackedInt32Array = entry[1]
		var pos: PackedVector3Array = _arrays(ending, s)[Mesh.ARRAY_VERTEX]
		for v: int in picked:
			var rz: float = (basis * pos[v]).z
			rot_min_z = minf(rot_min_z, rz)
			rot_max_z = maxf(rot_max_z, rz)
	var plate_z := _dominant_plate_z(ending, kept, basis, rot_min_z, rot_min_z + 0.35)
	if rot_max_z - rot_min_z > 0.30:
		var max_cap_z := maxf(rot_min_z + 0.25, plate_z + 0.14)
		var trimmed: Array = []
		var new_min_z := INF
		for entry: Array in kept:
			var s: int = int(entry[0])
			var picked: PackedInt32Array = entry[1]
			var pos: PackedVector3Array = _arrays(ending, s)[Mesh.ARRAY_VERTEX]
			var keep_tris := PackedInt32Array()
			for t in range(0, picked.size() - 2, 3):
				var v0: int = picked[t]
				var v1: int = picked[t + 1]
				var v2: int = picked[t + 2]
				var z0: float = (basis * pos[v0]).z
				var z1: float = (basis * pos[v1]).z
				var z2: float = (basis * pos[v2]).z
				if z0 <= max_cap_z and z1 <= max_cap_z and z2 <= max_cap_z:
					keep_tris.append(v0)
					keep_tris.append(v1)
					keep_tris.append(v2)
					new_min_z = minf(new_min_z, minf(z0, minf(z1, z2)))
			if not keep_tris.is_empty():
				trimmed.append([s, keep_tris])
		kept = trimmed
		rot_min_z = new_min_z
	if kept.is_empty() or is_inf(rot_min_z):
		return _procedural_cap(ending)
	plate_z = _dominant_plate_z(ending, kept, basis, rot_min_z, INF)
	if flush_edge and _cap_detail_inward(ending, kept, basis, plate_z):
		basis = Basis(Vector3.UP, PI) * basis
		var flip_min_z := INF
		for entry: Array in kept:
			var s: int = int(entry[0])
			var picked: PackedInt32Array = entry[1]
			var pos: PackedVector3Array = _arrays(ending, s)[Mesh.ARRAY_VERTEX]
			for v: int in picked:
				flip_min_z = minf(flip_min_z, (basis * pos[v]).z)
		plate_z = _dominant_plate_z(ending, kept, basis, flip_min_z, INF)
	var target_z := CAP_EDGE_Z
	var straight_min_z := INF
	for s in straight.get_surface_count():
		var spos: PackedVector3Array = _arrays(straight, s)[Mesh.ARRAY_VERTEX]
		for sp: Vector3 in spos:
			straight_min_z = minf(straight_min_z, (basis * sp).z)
	if not is_inf(straight_min_z) and straight_min_z < -0.50 and straight_min_z >= -0.60:
		target_z = minf(target_z, straight_min_z - 0.005)
	var shift_z := (target_z - plate_z) if flush_edge else 0.0
	var out := ArrayMesh.new()
	var cpu: Array = []
	for entry: Array in kept:
		var s: int = int(entry[0])
		var picked: PackedInt32Array = entry[1]
		var arrays := _only(_arrays(ending, s), picked)
		var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for i in pos.size():
			var p := basis * pos[i]
			p.z += shift_z
			pos[i] = p
		arrays[Mesh.ARRAY_VERTEX] = pos
		if arrays[Mesh.ARRAY_NORMAL] != null:
			var nor: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			for i in nor.size():
				nor[i] = basis * nor[i]
			arrays[Mesh.ARRAY_NORMAL] = nor
		if arrays[Mesh.ARRAY_TANGENT] != null:
			var tan: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
			for i in range(0, tan.size() - 3, 4):
				var v := basis * Vector3(tan[i], tan[i + 1], tan[i + 2])
				tan[i] = v.x
				tan[i + 1] = v.y
				tan[i + 2] = v.z
			arrays[Mesh.ARRAY_TANGENT] = tan
		PipeInsides.add(arrays)
		var format: int = ending.surface_get_format(s)
		var flags: int = format & (Mesh.ARRAY_FLAG_USE_2D_VERTICES | Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)
		for shift in [Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT, Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT,
				Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT, Mesh.ARRAY_FORMAT_CUSTOM3_SHIFT]:
			flags |= format & (Mesh.ARRAY_FORMAT_CUSTOM_MASK << shift)
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
		out.surface_set_material(out.get_surface_count() - 1, ending.surface_get_material(s))
		cpu.append(arrays)
	# The CPU copy the loader keeps of every model (levels of detail, far chunks read it).
	out.set_meta(ModelLods.ARRAYS_META, cpu)
	return out


## Clean procedural capped-flange fallback at the north edge (-z) when subtraction yields no vertices.
static func _procedural_cap(ref_mesh: Mesh = null) -> ArrayMesh:
	const SIDES := 12
	const CY := 0.378
	const R := 0.39
	var z_front := CAP_EDGE_Z if flush_edge else -0.355
	var z_back := z_front + 0.08
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	# Front disc (facing -Z): centre vertex 0, ring 1..SIDES.
	verts.append(Vector3(0.0, CY, z_front))
	norms.append(Vector3(0.0, 0.0, -1.0))
	uvs.append(Vector2(0.5, 0.5))
	for i in SIDES:
		var a := float(i) / float(SIDES) * TAU
		var x := cos(a) * R
		var y := CY + sin(a) * R
		verts.append(Vector3(x, y, z_front))
		norms.append(Vector3(0.0, 0.0, -1.0))
		uvs.append(Vector2(0.5 + cos(a) * 0.5, 0.5 + sin(a) * 0.5))
	for i in SIDES:
		var nxt := (i + 1) % SIDES
		idx.append(0)
		idx.append(1 + i)
		idx.append(1 + nxt)
	# Outer flange collar (z_front .. z_back).
	var rim_base := verts.size()
	for i in SIDES + 1:
		var a := float(i % SIDES) / float(SIDES) * TAU
		var c := cos(a)
		var s := sin(a)
		var n := Vector3(c, s, 0.0)
		verts.append(Vector3(c * R, CY + s * R, z_front))
		norms.append(n)
		uvs.append(Vector2(float(i) / float(SIDES), 0.0))
		verts.append(Vector3(c * R, CY + s * R, z_back))
		norms.append(n)
		uvs.append(Vector2(float(i) / float(SIDES), 1.0))
	for i in SIDES:
		var a := rim_base + i * 2
		idx.append(a)
		idx.append(a + 1)
		idx.append(a + 2)
		idx.append(a + 2)
		idx.append(a + 1)
		idx.append(a + 3)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	PipeInsides.add(arrays)
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat: Material = null
	if ref_mesh != null and ref_mesh.get_surface_count() > 0:
		mat = ref_mesh.surface_get_material(0)
	if mat == null:
		var sm := StandardMaterial3D.new()
		sm.albedo_color = Color(0.45, 0.47, 0.49)
		sm.metallic = 0.5
		sm.roughness = 0.5
		mat = sm
	out.surface_set_material(0, mat)
	out.set_meta(ModelLods.ARRAYS_META, [arrays])
	return out


## A surface's arrays with only the vertices `picked` (three a triangle) uses, indexed anew: each attribute
## (material rows, UVs, colours, custom data) as the loader made it, so the cap's box is its own.
static func _only(arrays: Array, picked: PackedInt32Array) -> Array:
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var count := pos.size()
	var new_of := {}
	var order := PackedInt32Array()
	var index := PackedInt32Array()
	for v in picked:
		if not new_of.has(v):
			new_of[v] = order.size()
			order.append(v)
		index.append(int(new_of[v]))
	var out := arrays.duplicate()
	for a in Mesh.ARRAY_MAX:
		var values = arrays[a]
		if a == Mesh.ARRAY_INDEX or values == null or count == 0:
			continue
		var size: int = values.size()
		if size == 0 or size % count != 0:
			continue
		var stride := size / count
		var kept = values.slice(0, 0)
		for v in order:
			kept.append_array(values.slice(v * stride, v * stride + stride))
		out[a] = kept
	out[Mesh.ARRAY_INDEX] = index
	return out


## A surface's arrays: the loader's CPU copy when it kept one (ModelLods.ARRAYS_META), else the GPU's
## (render_reads.gd, which counts that fallback; `--render-reads=old` always the GPU's).
static func _arrays(mesh: Mesh, s: int) -> Array:
	return RenderReads.arrays(mesh, s)


## A triangle by its corners, wound as it is (started at its least corner): a back face isn't its front.
static func _triangle_key(pos: PackedVector3Array, idx: PackedInt32Array, t: int) -> Array:
	var corners: Array = []
	for k in 3:
		var p := pos[idx[t + k]] if not idx.is_empty() else pos[t + k]
		corners.append(Vector3i(roundi(p.x / SAME), roundi(p.y / SAME), roundi(p.z / SAME)))
	var first := corners.find(corners.min())
	return [corners[first], corners[(first + 1) % 3], corners[(first + 2) % 3]]


## The opposite-wound triangle key for `_triangle_key`'s canonical `[c0, c1, c2]` (started at its least corner).
static func _reverse_key(key: Array) -> Array:
	return [key[0], key[2], key[1]]


## Z coordinate of the dominant solid axial -Z cap plate (in rotated space), falling back to `fallback_z`.
## Aligning the actual solid disc (instead of an outer collar lip) keeps recessed caps proud of port flanges.
static func _dominant_plate_z(ending: Mesh, kept: Array, basis: Basis, fallback_z: float, max_z: float) -> float:
	const BUCKET := 0.005
	var neg_area := {}
	var any_area := {}
	var z_sum := {}
	var w_sum := {}
	for entry: Array in kept:
		var s: int = int(entry[0])
		var picked: PackedInt32Array = entry[1]
		var arr := _arrays(ending, s)
		var pos: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nor: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var has_nor := nor.size() == pos.size()
		for t in range(0, picked.size() - 2, 3):
			var v0: int = picked[t]
			var v1: int = picked[t + 1]
			var v2: int = picked[t + 2]
			var p0: Vector3 = basis * pos[v0]
			var p1: Vector3 = basis * pos[v1]
			var p2: Vector3 = basis * pos[v2]
			var cz := (p0.z + p1.z + p2.z) / 3.0
			if cz > max_z:
				continue
			var cr := (p1 - p0).cross(p2 - p0)
			var cr_len := cr.length()
			if cr_len <= 1e-8 or absf(cr.z) <= 0.7 * cr_len:
				continue
			var area := 0.5 * cr_len
			var faces_neg := false
			if has_nor:
				var avg_n: Vector3 = basis * (nor[v0] + nor[v1] + nor[v2])
				faces_neg = avg_n.z < 0.0
			else:
				faces_neg = ((p2 - p0).cross(p1 - p0)).z < 0.0
			var b := roundi(cz / BUCKET)
			any_area[b] = float(any_area.get(b, 0.0)) + area
			z_sum[b] = float(z_sum.get(b, 0.0)) + cz * area
			w_sum[b] = float(w_sum.get(b, 0.0)) + area
			if faces_neg:
				neg_area[b] = float(neg_area.get(b, 0.0)) + area
	var table: Dictionary = neg_area if not neg_area.is_empty() else any_area
	if table.is_empty():
		return fallback_z
	var max_a := -1.0
	for b_var: Variant in table:
		max_a = maxf(max_a, float(table[b_var]))
	# Pick the frontmost (most -Z) solid plate with substantial area (>= 50% of peak), so a flange's
	# rear face with coplanar pipe rings never beats its front face while tiny front bosses are skipped.
	var best_b := 0x7fffffff
	for b_var: Variant in table:
		var b := int(b_var)
		if float(table[b_var]) >= max_a * 0.50 and b < best_b:
			best_b = b
	var w := float(w_sum.get(best_b, 0.0))
	return float(z_sum.get(best_b, 0.0)) / w if w > 0.0 else fallback_z


## True when axial cap details (like bolt heads) sit strictly behind `plate_z` (+Z into the pipe) with none
## in front (-Z), as Vasillo's `pipe-cap` inside `pipe-ending-down` does. Rotating 180 deg turns them outward.
static func _cap_detail_inward(ending: Mesh, kept: Array, basis: Basis, plate_z: float) -> bool:
	var plate_area := 0.0
	var out_area := 0.0
	var in_area := 0.0
	for entry: Array in kept:
		var s: int = int(entry[0])
		var picked: PackedInt32Array = entry[1]
		var arr := _arrays(ending, s)
		var pos: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for t in range(0, picked.size() - 2, 3):
			var p0: Vector3 = basis * pos[picked[t]]
			var p1: Vector3 = basis * pos[picked[t + 1]]
			var p2: Vector3 = basis * pos[picked[t + 2]]
			var cr := (p1 - p0).cross(p2 - p0)
			var cr_len := cr.length()
			if cr_len <= 1e-8 or absf(cr.z) <= 0.7 * cr_len:
				continue
			var area := 0.5 * cr_len
			var cz := (p0.z + p1.z + p2.z) / 3.0
			if absf(cz - plate_z) <= 0.005:
				plate_area += area
			elif cz < plate_z - 0.005:
				out_area += area
			else:
				in_area += area
	return out_area < 0.001 and in_area > 0.005 and plate_area > 0.0 and in_area < plate_area * 0.45


## A pack's cover mesh from its loaded `name` (model_for's) and, for an ending, its straight: [Mesh], []
## for none. `mesh_of` gives a loaded model's mesh (ModelLibrary.mesh_for); a cap is made again only when
## those meshes are new ones (the pack loaded again).
static func cover(name: String, mesh_of: Callable) -> Array:
	if name.begins_with(MODEL + "@"):
		var mesh: Mesh = mesh_of.call(name)
		return [mesh] if mesh != null else []
	var ending: Mesh = mesh_of.call(name)
	var straight: Mesh = mesh_of.call(STRAIGHT + "@" + name.substr(name.find("@") + 1))
	var known: Array = _covers.get(name, [])
	if known.size() == 4 and known[0] == ending and known[1] == straight and bool(known[2]) == flush_edge:
		return known[3]
	var cap := cap_from(ending, straight)
	var made: Array = [cap] if cap != null else []
	_covers[name] = [ending, straight, flush_edge, made]
	return made


## Whether the cover model for `pack` (and its straight, when extracted from an ending) is loaded.
## `ready_of`: Callable(name: String) -> bool (ModelLibrary.ready).
static func cover_ready(pack: Dictionary, ready_of: Callable) -> bool:
	var name := model_for(pack)
	if name == "":
		return true
	if not bool(ready_of.call(name)):
		return false
	if name.begins_with(ENDING + "@") and not bool(ready_of.call(STRAIGHT + name.substr(ENDING.length()))):
		return false
	return true


## All [Mesh, Transform3D] pipe-cover pieces for a ghost or standalone preview entity at `pos`, facing `dir`.
## `fb`: prototype's `eprops` fluid connections (ignored for `pipe-to-ground`, which uses `ports_for_underground()`).
## `covers`: open-port bitmask, or `-1` to cap every active port (respecting `extra.pc` on `pipe-to-ground`).
## `pack`: drawing pack (ModelLibrary.drawing_pack); `mesh_of`: Callable(name: String) -> Mesh (ModelLibrary.mesh_for).
static func ghost_cap_pieces(proto_type: String, fb: Variant, extra: Dictionary, dir: int, pos: Vector2,
		pack: Dictionary, mesh_of: Callable, covers := -1, flip := Basis.IDENTITY, y := 0.0) -> Array:
	if not enabled:
		return []
	var port_list: Array = []
	var mask := covers
	if proto_type == "pipe-to-ground":
		if mask == 0:
			return []
		if mask < 0:
			if (int(extra.get("pc", 0)) & (1 << ((dir >> 2) & 3))) != 0:
				return []
			mask = 1
		port_list = ports_for_underground()
	else:
		port_list = ports(fb, proto_type, int(extra.get("fa", 0)))
		if port_list.is_empty():
			return []
		if mask < 0:
			mask = 0
			for p: Array in port_list:
				mask |= 1 << int(p[2])
		if mask == 0:
			return []
	var name := model_for(pack)
	if name == "":
		return []
	var made := cover(name, mesh_of)
	if made.is_empty():
		return []
	var mesh: Mesh = made[0]
	var base := Transform3D(Basis(Vector3.UP, Wire.direction_yaw(dir)) * flip, Vector3(pos.x, y, pos.y))
	var out: Array = []
	for place: Transform3D in places(port_list, mask, base):
		out.append([mesh, place])
	return out


## Where a record's covers go: one transform a set bit of `covers`, in the space its model is drawn in
## (`base`: the model's transform, facing as the entity does).
static func places(port_list: Array, covers: int, base: Transform3D) -> Array:
	var out: Array = []
	for port: Array in port_list:
		if covers & (1 << int(port[2])) == 0:
			continue
		var at: Vector2 = port[0]
		var local := Transform3D(Basis(Vector3.UP, Wire.direction_yaw(int(port[1]))), Vector3(at.x, 0.0, at.y))
		out.append(base * local)
	return out
