extends Node3D
## Entity ghosts and planner marks, drawn like Factorio's: a ghost (a record with `extra.gh`, the
## prototype it stands for) is that entity's model, or its picture card when it has none (a mod's
## building, as chunk_view.gd draws it built: sprite_standins.gd), else the placeholder box, in a
## translucent blue-white; an entity marked for deconstruction (`extra.d`) gets Factorio's red cross over
## it, one marked for upgrade (`extra.up`) the green upgrade arrow. Per chunk, rebuilt when the
## world redraws the chunk (chunk_view.gd leaves ghosts out).
##
## A ghost is drawn in two passes (owner's I11, "ghost models look rough"): ghost_depth.gdshader
## lays down every ghost's depth, then ghost.gdshader colours only the nearest surface, so a ghost
## is one clean translucent layer instead of its inner faces and the ghosts behind it showing through
## in whatever order they were drawn. Always the full model (a ghost has no levels of detail).

const WorldMirror := preload("res://scripts/world/world.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const PipeCovers := preload("res://scripts/world/pipe_covers.gd")
const InserterArms := preload("res://scripts/world/inserter_arms.gd")
const FluidsPower := preload("res://scripts/world/fluids_power.gd")
const SpriteStandins := preload("res://scripts/world/sprite_standins.gd")
const Turrets := preload("res://scripts/world/turrets.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const RenderReads := preload("res://scripts/world/render_reads.gd")
const GhostShader := preload("res://shaders/ghost.gdshader")
const GhostDepthShader := preload("res://shaders/ghost_depth.gdshader")
const IconShader := preload("res://shaders/billboard_icon.gdshader")
const Switches := preload("res://scripts/switches.gd")
const Wire := preload("res://scripts/util/wire.gd")

## --ghost-lod=off: keep full-detail meshes for far entity ghosts instead of using coarse LODs.
static var ghost_lod := Switches.on("--ghost-lod")
const GHOST_LOD_DIST := 96.0

const MARK_SIZE := 0.9
const GHOST_TINT := Color(0.58, 0.68, 1.0, 0.42)  # ghost.gdshader's
const REBUILDS_PER_FRAME := 4
## Every ghost's depth first, then their colour: both among the see-through things (up to 2), before
## the smog (pollution.gd, 4) and the remote view's fog (5).
const DEPTH_PRIORITY := 1
const COLOR_PRIORITY := 2
## ghost.gdshader's slow band of light rising through a ghost: faint, as Factorio's ghosts are still.
const SHIMMER := 0.5

var world: WorldMirror

var _nodes := {}  # Vector2i chunk -> Node3D holding that chunk's ghosts and marks
var _dirty := {}
var _ghost_material: ShaderMaterial
var _mark_materials := {}  # "d" / "up" -> ShaderMaterial
var _quad := QuadMesh.new()
var _ghosts := 0

static var _baked_meshes := {}  # [Mesh, Image] -> ArrayMesh
static var _baked_gen := -1


func _ready() -> void:
	var colour := ShaderMaterial.new()
	colour.shader = GhostShader
	colour.render_priority = COLOR_PRIORITY
	colour.set_shader_parameter("shimmer", SHIMMER)
	_ghost_material = ShaderMaterial.new()
	_ghost_material.shader = GhostDepthShader
	_ghost_material.render_priority = DEPTH_PRIORITY
	_ghost_material.next_pass = colour
	var marks := {
		"d": ["core/graphics/cancel.png", Color(0.85, 0.1, 0.1)],
		"up": ["core/graphics/icons/upgrade-symbol.png", Color(0.2, 0.75, 0.2)],
	}
	for key in marks:
		var m := ShaderMaterial.new()
		m.shader = IconShader
		var texture := FluidsPower.core_texture(marks[key][0])
		m.set_shader_parameter("icon", texture if texture != null else FluidsPower._fallback_texture(marks[key][1]))
		_mark_materials[key] = m
	_quad.size = Vector2.ONE
	if world != null:
		world.entities_changed.connect(_on_entities_changed)
		world.ghost_hidden.connect(_on_entities_changed)


func reset() -> void:
	for n in _nodes.values():
		n.queue_free()
	_nodes.clear()
	_dirty.clear()
	_ghosts = 0


func ghost_count() -> int:
	return _ghosts


func _on_entities_changed(c: Vector2i) -> void:
	_dirty[c] = true


func _process(_delta: float) -> void:
	if world == null or _dirty.is_empty():
		return
	var budget := REBUILDS_PER_FRAME
	for c in _dirty.keys():
		if budget <= 0:
			break
		_dirty.erase(c)
		_rebuild(c)
		budget -= 1


func _rebuild(c: Vector2i) -> void:
	var old: Node3D = _nodes.get(c)
	if old != null:
		_ghosts -= int(old.get_meta("ghosts", 0))
		old.queue_free()
		_nodes.erase(c)
	var cv = world.chunks.get(c)
	if cv == null:
		return
	var by_model := {}  # Mesh -> Array of Transform3D
	var boxes: Array = []
	var cards := {}  # card Mesh -> Array of Transform3D
	var marks := {"d": [], "up": []}
	var ghosts := 0
	var tiles: Array = []
	var has_capped_belt := false
	var has_pipe_ghost := false
	var belt_check := ModelLibrary.has_belt_ends()
	for rec: WorldMirror.Rec in cv.entities.values():
		if rec.extra.has("hid") or not rec.extra.has("gh"):
			continue
		var gp: ProtoDB.EntityProto = world.protos.entity(int(rec.extra["gh"]))
		if gp == null:
			continue
		if belt_check and WorldMirror.CAPPED_TYPES.has(gp.type):
			has_capped_belt = true
		elif gp.type == "pipe" or gp.type == "infinity-pipe" or gp.type == "heat-pipe":
			has_pipe_ghost = true
	var belt_map := _local_belt_map(c) if has_capped_belt else {}
	var pipe_map := _local_pipe_map(c) if has_pipe_ghost else {}

	for rec: WorldMirror.Rec in cv.entities.values():
		if rec.extra.has("hid"):
			continue  # removed by the player, the game's `del` on its way (predicted.gd)
		if rec.extra.has("tg"):
			# A tile ghost: a flat translucent square on its tile, like Factorio's blue tile ghosts.
			tiles.append(Transform3D(Basis.from_scale(Vector3(0.96, 0.02, 0.96)), Vector3(floorf(rec.pos.x) + 0.5, 0.04, floorf(rec.pos.y) + 0.5)))
			ghosts += 1
			continue
		var shown: ProtoDB.EntityProto = world.protos.entity(rec.proto_id)
		if rec.extra.has("gh"):
			shown = world.protos.entity(int(rec.extra["gh"]))
			if shown == null:
				continue
			ghosts += 1
			var g_extra := rec.extra
			if (shown.type == "pipe" or shown.type == "infinity-pipe" or shown.type == "heat-pipe" or shown.type == "pipe-to-ground") \
					and int(rec.extra.get("pc", 0)) == 0 and not pipe_map.is_empty():
				var pm := _ghost_pipe_mask(rec.pos, shown.type == "heat-pipe", pipe_map)
				if pm != 0:
					g_extra = rec.extra.duplicate()
					g_extra["pc"] = pm
			var b_ends := _ghost_belt_ends(shown.type, rec.dir, rec.pos, g_extra, belt_map) if not belt_map.is_empty() else 0
			var cb := world.cargo_mask(WorldMirror.cargo_rect(shown, rec.pos), true) if shown.type == "cargo-bay" else -1
			var fb: Variant = world._fluid_ports.get(shown.id)
			if not ModelLibrary.entity_ready(shown.name, shown.type, g_extra, rec.dir):
				cv.waiting_models = true  # drawn again with the chunk once the model is made
				continue
			var pieces := ghost_pieces(shown.name, shown.type, g_extra, rec.dir, rec.pos, b_ends, Basis.IDENTITY, cb, fb)
			if not pieces.is_empty():
				if not ghost_pieces_ready(shown.name, shown.type, g_extra, rec.dir, rec.pos, b_ends, cb, fb):
					cv.waiting_models = true
				for piece: Array in pieces:
					var pm: Mesh = piece[0]
					if not by_model.has(pm):
						by_model[pm] = []
					(by_model[pm] as Array).append(piece[1])
			else:
				# No model: its picture card, as the built one (no box while it is composed, and none
				# at all with a graphics list, as chunk_view.gd).
				var lift := Visuals.flight_lift(shown.type)
				var card := SpriteStandins.card(shown.name, rec.dir, shown.size(), shown.type) if shown.type != "resource" else null
				if card != null:
					if not cards.has(card):
						cards[card] = []
					(cards[card] as Array).append(SpriteStandins.transform(rec.pos, lift))
				elif SpriteStandins.coming(shown.name, rec.dir):
					cv.waiting_models = true
				elif not SpriteStandins.in_use():
					boxes.append(Visuals.placeholder_transform(shown, rec.pos, rec.dir, Visuals.height_for(shown), lift))
		if shown == null:
			continue
		for key in marks:
			if rec.extra.has(key):
				var top := _top(shown, rec)
				# Over the middle of the entity as seen from the camera, like Factorio's marks.
				var at := Vector3(rec.pos.x, Visuals.flight_lift(shown.type) + top * 0.6 + 0.2, rec.pos.y)
				(marks[key] as Array).append(Transform3D(Basis.from_scale(Vector3.ONE * MARK_SIZE), at))
	if ghosts == 0 and (marks["d"] as Array).is_empty() and (marks["up"] as Array).is_empty():
		return
	var node := Node3D.new()
	node.set_meta("ghosts", ghosts)
	add_child(node)
	_nodes[c] = node
	_ghosts += ghosts
	var far_ghost := ghost_lod and world != null and (Vector2(c) * 32.0 + Vector2(16.0, 16.0)).distance_to(world.focus()) > GHOST_LOD_DIST
	for mesh in by_model:
		var draw_mesh: Mesh = mesh
		if far_ghost:
			var lvls := ModelLods.levels(mesh)
			if not lvls.is_empty():
				draw_mesh = lvls[0][0]
		_add(node, draw_mesh, by_model[mesh], _ghost_material)
	for card in cards:
		_add(node, card, cards[card], SpriteStandins.ghost_material(card, GHOST_TINT))
	_add(node, Visuals.box_mesh(), boxes, _ghost_material)
	_add(node, Visuals.box_mesh(), tiles, _ghost_material)
	for key in marks:
		_add(node, _quad, marks[key], _mark_materials[key])


## CPU-skinned frame-0 mesh for a `baked` AnimPart (ghost.gdshader has no bone skinning pass).
static func skinned_part_mesh(part: ModelLibrary.AnimPart) -> Mesh:
	if part.mesh == null or part.kind != "baked" or part.bake.is_empty():
		return part.mesh
	if _baked_gen != ModelLibrary.generation:
		_baked_meshes.clear()
		_baked_gen = ModelLibrary.generation
	var image: Image = part.bake.get("image")
	if image == null:
		return part.mesh
	var key := [part.mesh, image]
	if _baked_meshes.has(key):
		return _baked_meshes[key]
	var out := ArrayMesh.new()
	for s in part.mesh.get_surface_count():
		var arrays := RenderReads.arrays(part.mesh, s).duplicate()  # the CPU copy: no renderer read
		var verts: PackedVector3Array = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).duplicate()
		var norms: PackedVector3Array = (arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array).duplicate() if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var tangs: PackedFloat32Array = (arrays[Mesh.ARRAY_TANGENT] as PackedFloat32Array).duplicate() if arrays[Mesh.ARRAY_TANGENT] != null else PackedFloat32Array()
		var skin: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM3] if arrays[Mesh.ARRAY_CUSTOM3] != null else PackedFloat32Array()
		var has_norms := norms.size() == verts.size()
		var has_tangs := tangs.size() == verts.size() * 4
		for v in verts.size():
			var m := Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO)
			var total := 0.0
			for k in 4:
				if v * 4 + k >= skin.size():
					break
				var code := skin[v * 4 + k]
				var w := fposmod(code, 1.0) / 0.999
				if w <= 0.0:
					continue
				var j := int(floor(code))
				var r0 := image.get_pixel(j * 3, 0)
				var r1 := image.get_pixel(j * 3 + 1, 0)
				var r2 := image.get_pixel(j * 3 + 2, 0)
				m.basis.x += w * Vector3(r0.r, r1.r, r2.r)
				m.basis.y += w * Vector3(r0.g, r1.g, r2.g)
				m.basis.z += w * Vector3(r0.b, r1.b, r2.b)
				m.origin += w * Vector3(r0.a, r1.a, r2.a)
				total += w
			if total > 0.0:
				verts[v] = (m * verts[v]) / total
				if has_norms:
					var n := (m.basis * norms[v]) / total
					if n.length_squared() > 1e-10:
						norms[v] = n.normalized()
				if has_tangs:
					var tb := v * 4
					var tv := (m.basis * Vector3(tangs[tb], tangs[tb + 1], tangs[tb + 2])) / total
					if tv.length_squared() > 1e-10:
						tv = tv.normalized()
						tangs[tb] = tv.x
						tangs[tb + 1] = tv.y
						tangs[tb + 2] = tv.z
		arrays[Mesh.ARRAY_VERTEX] = verts
		if has_norms:
			arrays[Mesh.ARRAY_NORMAL] = norms
		if has_tangs:
			arrays[Mesh.ARRAY_TANGENT] = tangs
		var format: int = part.mesh.surface_get_format(s)
		var flags: int = format & (Mesh.ARRAY_FLAG_USE_2D_VERTICES | Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)
		for shift in [Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT, Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT,
				Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT, Mesh.ARRAY_FORMAT_CUSTOM3_SHIFT]:
			flags |= format & (Mesh.ARRAY_FORMAT_CUSTOM_MASK << shift)
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
		out.surface_set_material(out.get_surface_count() - 1, part.mesh.surface_get_material(s))
	_baked_meshes[key] = out
	return out


## Default end-cap bitmask for a lone belt-like entity standing alone.
static func lone_belt_ends(proto_type: String, extra: Dictionary) -> int:
	match proto_type:
		"transport-belt":
			return 3 if str(extra.get("s", "s")) == "s" else 0
		"underground-belt", "linked-belt":
			return 2 if str(extra.get("u", "i")) == "o" else 1
		"lane-splitter":
			return 3
		"splitter":
			return 15
	return 0


static func _resolved_entity_model(proto_name: String, proto_type: String, extra: Dictionary, dir := 0) -> Array:
	for name: String in ModelLibrary.entity_models(proto_name, proto_type, extra, dir):
		var mesh := ModelLibrary.mesh_for(name)
		if mesh != null:
			return [name, mesh]
	return ["", null]


## Whether the base model and every attachment/sub-piece for a ghost entity are ready.
static func ghost_pieces_ready(proto_name: String, proto_type: String, extra: Dictionary, dir: int, pos: Vector2,
		belt_ends: int = 0, cargo_mask := 0, fb: Variant = null, _covers := -1) -> bool:
	if not ModelLibrary.entity_ready(proto_name, proto_type, extra, dir):
		return false
	var res := _resolved_entity_model(proto_name, proto_type, extra, dir)
	var resolved: String = res[0]
	if resolved == "":
		return true
	if proto_type == "inserter":
		var at := resolved.find("@")
		var arm_name := proto_name + (resolved.substr(at) if at >= 0 else "")
		if InserterArms.resting_pieces(arm_name) == null:
			return false
	if WorldMirror.CAPPED_TYPES.has(proto_type):
		if belt_ends > 0:
			var pack := ModelLibrary.entity_pack(extra)
			for place: Array in ModelLibrary.belt_end_places(proto_name, proto_type, dir, pos, belt_ends, 0.0, pack):
				if not ModelLibrary.ready(str(place[0])):
					return false
		elif belt_ends < 0:
			if ModelLibrary.lone_belt_pieces(resolved) == null:
				return false
	if proto_type == "mining-drill":
		var wet_name := ModelLibrary.wet_model(proto_name, proto_type, extra, dir)
		if wet_name != "" and not ModelLibrary.ready(wet_name):
			return false
	if PipeCovers.enabled and proto_type != "pipe" and proto_type != "infinity-pipe" and proto_type != "heat-pipe" \
			and (proto_type == "pipe-to-ground" or not PipeCovers.ports(fb, proto_type, int(extra.get("fa", 0))).is_empty()):
		var cap_ready := func(n: String) -> bool:
			return ModelLibrary.ready(n)
		if not PipeCovers.cover_ready(ModelLibrary.drawing_pack(proto_name, proto_type, extra, dir), cap_ready):
			return false
	if proto_type == "cargo-bay" and cargo_mask >= 0:
		for place: Array in ModelLibrary.cargo_places(cargo_mask, Vector3(pos.x, 0.0, pos.y)):
			if not ModelLibrary.ready(str(place[0])):
				return false
	return true


## All [Mesh, Transform3D] pieces that make up a full ghost building at `pos`, facing `dir`:
## base mesh, non-lit moving parts (CPU-skinned if baked), resting inserter arms, belt end caps,
## wet drill attachments, pipe cover caps, and cargo bay edges. Returns [] when the entity has no model.
static func ghost_pieces(proto_name: String, proto_type: String, extra: Dictionary, dir: int, pos: Vector2,
		belt_ends: int = 0, flip := Basis.IDENTITY, cargo_mask := 0, fb: Variant = null, covers := -1) -> Array:
	var res := _resolved_entity_model(proto_name, proto_type, extra, dir)
	var resolved: String = res[0]
	var mesh: Mesh = res[1]
	if mesh == null:
		return []
	var out: Array = []
	var lift := Visuals.flight_lift(proto_type)
	var base_xf := ModelLibrary.placed(proto_name, proto_type, dir, extra, Vector3(pos.x, lift, pos.y), flip)
	out.append([mesh, base_xf])
	var host_parts := ModelLibrary.parts_for(resolved)
	for part: ModelLibrary.AnimPart in host_parts:
		if part.mesh == null or part.lit:
			continue
		var part_xf := base_xf
		if part.kind == "turret_head" and Turrets.head_front(part) == Vector3.LEFT:
			var align := part.pivot * Transform3D(Basis(Vector3.UP, -PI / 2.0), Vector3.ZERO) * part.pivot.affine_inverse()
			part_xf = base_xf * align
		out.append([skinned_part_mesh(part), part_xf])
	if proto_type == "inserter":
		var at := resolved.find("@")
		var arm_name := proto_name + (resolved.substr(at) if at >= 0 else "")
		var arm: Variant = InserterArms.resting_pieces(arm_name)
		if arm is Array:
			var arm_base := Transform3D(Basis(Vector3.UP, Wire.direction_yaw(dir)) * flip, Vector3(pos.x, 0.0, pos.y))
			for p: Array in (arm as Array):
				out.append([p[0], arm_base * (p[1] as Transform3D)])
	if WorldMirror.CAPPED_TYPES.has(proto_type):
		if belt_ends > 0:
			var inverse := base_xf.affine_inverse()
			var pack := ModelLibrary.entity_pack(extra)
			for place: Array in ModelLibrary.belt_end_places(proto_name, proto_type, dir, pos, belt_ends, 0.0, pack):
				var piece: String = place[0]
				if not ModelLibrary.ready(piece):
					continue
				var pm := ModelLibrary.mesh_for(piece)
				if pm == null:
					continue
				var at_xf: Transform3D = place[1]
				out.append([pm, at_xf])
				for part: ModelLibrary.AnimPart in ModelLibrary.parts_for(piece):
					if part.mesh != null and not part.lit and not ModelLibrary.part_doubled(part, inverse * at_xf, host_parts):
						out.append([skinned_part_mesh(part), at_xf])
		elif belt_ends < 0:
			var lone: Variant = ModelLibrary.lone_belt_pieces(resolved)
			if lone is Array:
				for p: Array in (lone as Array):
					var pm: Mesh = skinned_part_mesh(p[2]) if p.size() > 2 and p[2] is ModelLibrary.AnimPart else p[0]
					out.append([pm, base_xf * (p[1] as Transform3D)])
	if proto_type == "mining-drill":
		var wet_name := ModelLibrary.wet_model(proto_name, proto_type, extra, dir)
		if wet_name != "" and ModelLibrary.ready(wet_name):
			var wm := ModelLibrary.mesh_for(wet_name)
			if wm != null:
				out.append([wm, base_xf])
				for part: ModelLibrary.AnimPart in ModelLibrary.parts_for(wet_name):
					if part.mesh != null and not part.lit:
						out.append([skinned_part_mesh(part), base_xf])
	if PipeCovers.enabled and proto_type != "pipe" and proto_type != "infinity-pipe" and proto_type != "heat-pipe" \
			and (proto_type == "pipe-to-ground" or not PipeCovers.ports(fb, proto_type, int(extra.get("fa", 0))).is_empty()):
		var cap_mesh := func(n: String) -> Mesh:
			return ModelLibrary.mesh_for(n)
		out.append_array(PipeCovers.ghost_cap_pieces(proto_type, fb, extra, dir, pos,
			ModelLibrary.drawing_pack(proto_name, proto_type, extra, dir), cap_mesh, covers, flip, lift))
	if proto_type == "cargo-bay" and cargo_mask >= 0:
		for place: Array in ModelLibrary.cargo_places(cargo_mask, Vector3(pos.x, 0.0, pos.y)):
			var cname: String = str(place[0])
			if not ModelLibrary.ready(cname):
				continue
			var cm := ModelLibrary.mesh_for(cname)
			if cm != null:
				out.append([cm, Transform3D(Basis(), place[1])])
	return out


func _local_belt_map(c: Vector2i) -> Dictionary:
	var out := {}
	var lo := Vector2(c) * 32.0 - Vector2(2.0, 2.0)
	var hi := Vector2(c + Vector2i.ONE) * 32.0 + Vector2(2.0, 2.0)
	var area := Rect2(lo, hi - lo)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var other = world.chunks.get(c + Vector2i(dx, dy))
			if other == null:
				continue
			for r: WorldMirror.Rec in other.entities.values():
				if r.extra.has("hid"):
					continue
				if (dx != 0 or dy != 0) and not area.has_point(r.pos):
					continue
				var p: ProtoDB.EntityProto = world.protos.entity(int(r.extra["gh"])) if r.extra.has("gh") else world.protos.entity(r.proto_id)
				if p == null or not WorldMirror.BELT_TYPES.has(p.type):
					continue
				var row := [p.type, r.dir, str(r.extra.get("u", "")), str(r.extra.get("s", "s"))]
				for t: Vector2i in ModelLibrary.belt_tiles(r.pos):
					out[t] = row
	return out


static func _ghost_belt_ends(proto_type: String, dir: int, pos: Vector2, extra: Dictionary, belt_map: Dictionary) -> int:
	if not WorldMirror.CAPPED_TYPES.has(proto_type):
		return 0
	var step: Vector2i = WorldMirror.PIPE_STEPS[(dir >> 2) & 3]
	var under := str(extra.get("u", "i")) if (proto_type == "underground-belt" or proto_type == "linked-belt") else ""
	var starts := under != "o" and str(extra.get("s", "s")) == "s"
	var ends := under != "i"
	var mask := 0
	var tiles := ModelLibrary.belt_tiles(pos)
	for i in tiles.size():
		var t: Vector2i = tiles[i]
		if starts:
			var back = belt_map.get(t - step)
			if back == null or not WorldMirror.belt_feeds(dir, str(back[0]), int(back[1]), str(back[2])):
				mask |= 1 << (2 * i)
		if ends:
			var front = belt_map.get(t + step)
			if front == null or not WorldMirror.belt_continues(dir, str(front[0]), int(front[1]), str(front[2]), str(front[3])):
				mask |= 2 << (2 * i)
	return mask


func _local_pipe_map(c: Vector2i) -> Dictionary:
	var out := {}
	var lo := Vector2(c) * 32.0 - Vector2(2.0, 2.0)
	var hi := Vector2(c + Vector2i.ONE) * 32.0 + Vector2(2.0, 2.0)
	var area := Rect2(lo, hi - lo)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var other = world.chunks.get(c + Vector2i(dx, dy))
			if other == null:
				continue
			for r: WorldMirror.Rec in other.entities.values():
				if r.extra.has("hid"):
					continue
				if (dx != 0 or dy != 0) and not area.has_point(r.pos):
					continue
				var p: ProtoDB.EntityProto = world.protos.entity(int(r.extra["gh"])) if r.extra.has("gh") else world.protos.entity(r.proto_id)
				if p == null:
					continue
				if p.type == "pipe" or p.type == "infinity-pipe" or p.type == "heat-pipe" or p.type == "pipe-to-ground":
					out[Vector2i(floori(r.pos.x), floori(r.pos.y))] = [p.type, r.dir]
	return out


static func _ghost_pipe_mask(pos: Vector2, heat: bool, pipe_map: Dictionary) -> int:
	var tile := Vector2i(floori(pos.x), floori(pos.y))
	var mask := 0
	for i in 4:
		var other = pipe_map.get(tile + WorldMirror.PIPE_STEPS[i])
		if other == null:
			continue
		var ot := str(other[0])
		if heat != (ot == "heat-pipe"):
			continue
		if ot == "pipe-to-ground" and int(other[1]) != ((i + 2) % 4) * 4:
			continue
		mask |= 1 << i
	return mask


func _top(proto: ProtoDB.EntityProto, rec: WorldMirror.Rec) -> float:
	var mesh := world.ready_mesh(proto, rec)
	if mesh != null:
		return mesh.get_aabb().end.y
	return Visuals.height_for(proto)


static func _add(parent: Node3D, mesh: Mesh, xforms: Array, material: Material) -> void:
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.lod_bias = 1.0 if ghost_lod else 8.0  # coarse levels save far ghosts when enabled; old keeps full mesh
	parent.add_child(mmi)
