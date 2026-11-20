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

## On unless --pipe-covers=off.
static var enabled := not ("--pipe-covers=off" in OS.get_cmdline_user_args())
## The model a pack can give for its covers.
const MODEL := "pipe-cover"
## The pipe kit's pieces the end cap is taken from: the ending joined from the south (cap at the north
## edge, vasillo.json) and the straight it is made of.
const ENDING := "pipe-ending-down"
const STRAIGHT := "pipe-straight-vertical"
## Crafting machines: only the connections their recipe uses.
const CRAFTERS := ["assembling-machine", "furnace"]
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


## The model name of a pack's covers ("" none, or while the pack isn't known).
static func model_for(pack: Dictionary) -> String:
	if not enabled or pack.is_empty() or ModelPacks.is_sprite_pack(pack):
		return ""
	var id := str(pack.get("id", ""))
	if ModelPacks.find_in(id, MODEL) != "":
		return MODEL + "@" + id
	if ModelPacks.find_in(id, ENDING) != "" and ModelPacks.find_in(id, STRAIGHT) != "":
		return ENDING + "@" + id
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
	for s in straight.get_surface_count():
		var arrays := _arrays(straight, s)
		var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count := idx.size() if not idx.is_empty() else pos.size()
		for t in range(0, count - 2, 3):
			var key := _triangle_key(pos, idx, t)
			known[key] = int(known.get(key, 0)) + 1
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
		return null
	# Turned so its middle is at the north edge (-z), whichever edge the pack's ending has it at.
	var mid := box.get_center()
	var turn := 0.0
	if absf(mid.x) > absf(mid.z):
		turn = PI / 2.0 if mid.x < 0.0 else -PI / 2.0
	elif mid.z > 0.0:
		turn = PI
	var basis := Basis(Vector3.UP, turn)
	var out := ArrayMesh.new()
	var cpu: Array = []
	for entry: Array in kept:
		var s: int = entry[0]
		var picked: PackedInt32Array = entry[1]
		var arrays := _only(_arrays(ending, s), picked)
		var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for i in pos.size():
			pos[i] = basis * pos[i]
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


## A surface's arrays: the loader's CPU copy when it kept one (ModelLods.ARRAYS_META), else the GPU's.
static func _arrays(mesh: Mesh, s: int) -> Array:
	if mesh.has_meta(ModelLods.ARRAYS_META):
		var kept: Array = mesh.get_meta(ModelLods.ARRAYS_META)
		if s < kept.size() and kept[s] is Array:
			return kept[s]
	return mesh.surface_get_arrays(s)


## A triangle by its corners, wound as it is (started at its least corner): a back face isn't its front.
static func _triangle_key(pos: PackedVector3Array, idx: PackedInt32Array, t: int) -> Array:
	var corners: Array = []
	for k in 3:
		var p := pos[idx[t + k]] if not idx.is_empty() else pos[t + k]
		corners.append(Vector3i(roundi(p.x / SAME), roundi(p.y / SAME), roundi(p.z / SAME)))
	var first := corners.find(corners.min())
	return [corners[first], corners[(first + 1) % 3], corners[(first + 2) % 3]]


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
	if known.size() == 3 and known[0] == ending and known[1] == straight:
		return known[2]
	var cap := cap_from(ending, straight)
	var made: Array = [cap] if cap != null else []
	_covers[name] = [ending, straight, made]
	return made


## Where a record's covers go: one transform a set bit of `covers`, in the space its model is drawn in
## (`base`: the model's transform, facing as the entity does).
static func places(port_list: Array, covers: int, base: Transform3D) -> Array:
	var out: Array = []
	for port: Array in port_list:
		if covers & (1 << int(port[2])) == 0:
			continue
		var at: Vector2 = port[0]
		var local := Transform3D(Basis(Vector3.UP, -float(int(port[1])) / 16.0 * TAU), Vector3(at.x, 0.0, at.y))
		out.append(base * local)
	return out
